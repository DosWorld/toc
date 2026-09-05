(*$D-,O-*)
MODULE PExpr2;
(* PExpr2: designator/actual-parameter/factor parsing, split out of PExpr
   2026-08-21 (OVR-BUG.MD follow-up) -- PExpr's own compiled code (~76KB)
   exceeded the overlay buffer's hard architectural ceiling (SYSTEM.Alloc
   allocates a single DOS block, capped near 64KB -- see Overlay.OvrSetBuf's
   own header comment), so a single $O+ module could never hold ALL of
   PExpr's code no matter how the buffer was sized: LoadModule's own
   fast-fail "needParas > buffer size" check failed on the very first
   dispatch, surfacing as SYSTEM.Halt(209) immediately.

   Split boundary: PExpr keeps the OUTER expression grammar
   (ParseExpression/ParseSimpleExpression/ParseTerm/ParseCondExpr and
   friends, const-folding, shared Error/Expect/IsLex infra, and every
   module-level VAR PARSER.MOD/PSTMT.MOD read directly -- sc, modName,
   modUsesFpu, boundsChk, overlayMode, targetCP).  This module holds the
   INNER designator/actual-parameter/factor grammar (ParseDesignator,
   ParseActualParameters, EmitInlineCall, ParseSystemIntrinsic,
   ParseFactor) -- everything reachable only through ParseFactor's own
   TIdent/TLparen/etc. cases, which recursion-wise is the larger half.

   Mutual recursion (ParseFactor -> ParseDesignator -> ParseExpression,
   and ParseTerm/ParseCondFactor -> ParseFactor) cannot cross a module
   import edge directly -- Oberon forbids circular imports.  Broken via
   PExpr.ParseFactorExt, an EXTERNAL procedure declared in PEXPR.MOD
   against this module's own real export name ("PExpr2_ParseFactor")
   instead of a real IMPORT PExpr2 -- see PExpr.MOD's own
   ParseFactorExt comment for the full story, including why this
   replaced an earlier PROCEDURE-variable hook design (OVR-BUG.MD
   "Bug 5": the old hook cached a raw code address across overlay
   evictions and went stale). Because EXTERNAL resolves via the
   linker's own normal RDOFF import mechanism, no runtime wiring call
   (the old WireHook) is needed at all -- every call site compiles
   straight to a real, linker-recognized CALL FAR, safe under $O+ by
   construction.

   $O+ here, not on PExpr: PExpr stays resident (it is the module PARSER.
   MOD/PSTMT.MOD call directly, at nearly every statement/declaration
   boundary -- keeping it resident avoids paying a trap+possible-load on
   every one of those calls); PExpr2 is reached far less often per call
   site (mostly from inside PExpr's own recursive descent, a handful of
   resident call sites from PSTMT.MOD/PARSER.MOD) and is the piece that
   was actually too large to fit resident. *)
IMPORT Scan, Syms, Cgen, Rdoff, Strings, StrTab, PExpr;


(* IsLex pattern (CLAUDE.md/IMPLRULE.MD): each module keeps its own private,
   non-exported copy rather than sharing PExpr's -- called at nearly every
   token boundary in this module's own designator/actual-parameter/factor
   parsing. *)
PROCEDURE IsLex(t: INTEGER): BOOLEAN;
BEGIN
  IF PExpr.sc.sym = t THEN
    Scan.Next(PExpr.sc);
    RETURN TRUE
  END;
  RETURN FALSE
END IsLex;

(* ---- forward declarations ----
   ParseDesignator's own body is defined later in this file (after
   ParseActualParameters/EmitInlineCall, which both call it for a
   designator-shaped actual parameter) -- in the original single-file
   PEXPR.MOD this worked via a FORWARD declared once near the top; that
   declaration stays needed here for the same reason, now local to this
   module instead of spanning what is now PExpr/PExpr2's own boundary. *)
PROCEDURE ParseDesignator*(VAR item: Cgen.Item); FORWARD;

(* ---- bounds check ---- *)

PROCEDURE EmitBoundsCheck(len, openLenBpOfs: LONGINT);
  VAR errId: INTEGER; ok1, ok2: Cgen.Backpatch;
BEGIN
  IF ~PExpr.boundsChk THEN RETURN END;
  errId := PExpr.GetSystemImport("SYSTEM_ErrIndexOutOfBounds");
  IF len < 0 THEN
    Cgen.Emit1(050H);
    Cgen.CgLoadBp(openLenBpOfs);
    Cgen.EmitCodeStr("89,C1,58")  (* MOV CX,AX; POP AX *)
  END;
  Cgen.CgTestAx();
  Cgen.CgCondShort(Cgen.OpJge, ok1);
  Cgen.CgCallFar(errId);
  Cgen.CgPatchShort(ok1);
  IF len >= 0 THEN
    Cgen.Emit1(03DH); Cgen.EmitW(INTEGER(len))
  ELSE
    Cgen.Emit2(03BH, 0C1H)
  END;
  (* UNSIGNED below: len may legally exceed 32767 (arrays up to 64000 bytes);
     a signed JL would treat such a len as negative and flag every index as
     out of bounds.  The JGE sign check above already handled negative
     indices, so JB here is exact. *)
  Cgen.CgCondShort(Cgen.OpJb, ok2);
  Cgen.CgCallFar(errId);
  Cgen.CgPatchShort(ok2)
END EmitBoundsCheck;

(* ---- forward call patch ---- *)

PROCEDURE FwdEmitCall*(sym: Syms.Symbol; isFar: BOOLEAN);
  VAR patchAt: LONGINT;
BEGIN
  IF isFar THEN Cgen.Emit1(BYTE(Cgen.OpPushCs)) END;
  Cgen.Emit1(BYTE(Cgen.OpCallNear));
  patchAt := Cgen.CgPc();
  Cgen.EmitW(0);
  Syms.FwdAppend(sym.fwdPatches, patchAt)   (* chunked: append, alloc only when full *)
END FwdEmitCall;

PROCEDURE FwdPatchCalls*(sym: Syms.Symbol; targetOfs: LONGINT);
  VAR n: Syms.FwdNode; rel, pAt: LONGINT; i: INTEGER;
BEGIN
  n := sym.fwdPatches;
  WHILE n # NIL DO
    i := 0;
    WHILE i < n^.count DO
      pAt := n^.ofs[i];
      rel := targetOfs - (pAt + LONGINT(2));
      Rdoff.PatchCodeByte(Cgen.CgObj, pAt,              BYTE(SYSTEM.AND(INTEGER(rel), 0FFH)));
      Rdoff.PatchCodeByte(Cgen.CgObj, pAt + LONGINT(1), BYTE(SYSTEM.AND(SYSTEM.LSR(INTEGER(rel), 8), 0FFH)));
      INC(i)
    END;
    n := n^.next   (* nodes freed en masse by Syms.SymsFree via the allFwd chain *)
  END;
  sym.fwdPatches := NIL
END FwdPatchCalls;

(* ---- actual parameters ---- *)

(* Param-passing compatibility check.  Skipped when: no formal, formal is
   typeless VAR, single-char string -> CHAR/BYTE, string -> ARRAY OF CHAR/BYTE,
   or implicit INTEGER->LONGINT / REAL->LONGREAL widening (handled at codegen). *)
PROCEDURE CheckParamCompat(formal: Syms.Symbol; VAR arg: Cgen.Item);
  VAR ft, at: Syms.TypeDesc; isVar: BOOLEAN;
      nbuf: ARRAY Syms.NameLen OF CHAR;
BEGIN
  IF formal = Syms.NoSym THEN RETURN END;
  (* A VAR parameter binds to caller storage, so the actual MUST be a variable
     (an l-value): MLocal/MGlobal, or a far-addressed element (MReg & isRef,
     i.e. pointer-deref or indexed element).  A string literal, a constant
     (scalar or array), a computed value, or a procedure has no caller storage
     to bind and is rejected.  (Passing a string literal to a VAR ARRAY formal
     used to be miscompiled into a far ref with a bad length, hanging the
     compiler in the INLINE name scan — now a clean compile error.)
     A string literal's item also has mode = MGlobal (it lives in the data
     segment like any other global), so mode alone can't tell it apart from a
     real global variable — rootSym is NoSym for a literal (ParseFactor's
     Scan.TString case never sets it) but always set for a designator, so it
     is the actual l-value discriminant for the MGlobal/MLocal cases. *)
  IF formal.kind = Syms.KVarParam THEN
    (* A typeless VAR formal (SYSTEM.ADR/MOVE/FILL/...) additionally accepts
       a procedure value — its far address is a legal "address of" source
       (the documented SYSTEM.ADR(SomeProc) / ADR(SYSTEM.Alloc) idiom).
       Everything else follows the same l-value rule as a typed VAR formal:
       a literal, constant, or computed expression has no caller storage to
       bind (SYSTEM.ADR(42) used to slip through the old typeless
       exemption and yielded a garbage DS:42 far pointer). *)
    IF ~(((arg.mode = Cgen.MLocal) & (arg.rootSym # Syms.NoSym)) OR
         ((arg.mode = Cgen.MGlobal) & (arg.rootSym # Syms.NoSym)) OR
         ((arg.mode = Cgen.MReg) & arg.isRef) OR
         (formal.typeless &
          ((arg.mode = Cgen.MProc) OR (arg.mode = Cgen.MImport)))) THEN
      StrTab.Get(formal.nameId, nbuf);
      PExpr.Error2("VAR parameter requires a variable (not a literal, constant, or expression)", nbuf);
      RETURN
    END
  END;
  IF (formal.type = Syms.NoType) OR (arg.type = Syms.NoType) THEN RETURN END;
  IF formal.typeless THEN RETURN END;
  ft := formal.type; at := arg.type;
  (* .elemOrRet is NIL (= Syms.NoType) for every non-ARRAY type: it may only be
     dereferenced AFTER the form/NIL guards below.  (An earlier version read
     both elem forms up front "once" — a NIL far read through 0000:0000 on
     virtually every checked call.) *)
  (* Single-char string -> CHAR / BYTE *)
  IF (at.form = Syms.TFArray) & (at.len = 2) & (at.elemOrRet # Syms.NoType) &
     (at.elemOrRet.form = Syms.TFChar) &
     ((ft.form = Syms.TFChar) OR (ft.form = Syms.TFByte)) THEN RETURN END;
  (* String -> ARRAY OF CHAR / BYTE *)
  IF (at.form = Syms.TFArray) & (at.elemOrRet # Syms.NoType) &
     (at.elemOrRet.form = Syms.TFChar) &
     (ft.form = Syms.TFArray) & (ft.elemOrRet # Syms.NoType) &
     ((ft.elemOrRet.form = Syms.TFChar) OR (ft.elemOrRet.form = Syms.TFByte)) THEN
    RETURN
  END;
  (* INTEGER/BYTE/WORD -> LONGINT widening *)
  IF (ft.form = Syms.TFLongint) &
     ((at.form = Syms.TFInteger) OR (at.form = Syms.TFByte) OR
      (at.form = Syms.TFWord)) THEN RETURN END;
  (* REAL -> LONGREAL widening *)
  IF (ft.form = Syms.TFLongreal) & (at.form = Syms.TFReal) THEN RETURN END;
  isVar := formal.kind = Syms.KVarParam;
  IF ~Syms.TypeParamCompat(ft, at, isVar) THEN
    StrTab.Get(formal.nameId, nbuf);
    PExpr.Error2("type mismatch in actual parameter", nbuf)
  END
END CheckParamCompat;

(* Push a far pointer held in a local BP slot {ofs:2, seg:2}: segment then
   offset (Pascal l-to-r push order, segment deepest).  LES loads both words
   in one instruction (ES:BX := seg:ofs) instead of two separate MOV AX,[..]
   loads. *)
PROCEDURE PushFarSlotBp(adr: LONGINT);
BEGIN
  Cgen.CgLesBxBp(adr);
  Cgen.Emit1(BYTE(Cgen.OpPushEs));                  (* PUSH ES (segment) *)
  Cgen.Emit1(BYTE(Cgen.OpPushBx))    (* PUSH BX (offset) *)
END PushFarSlotBp;

(* Push a far pointer held in a global data slot {ofs:2, seg:2}. *)
PROCEDURE PushFarSlotMem(adr: LONGINT);
BEGIN
  Cgen.CgLesBxMem(WORD(adr));
  Cgen.Emit1(BYTE(Cgen.OpPushEs));                  (* PUSH ES (segment) *)
  Cgen.Emit1(BYTE(Cgen.OpPushBx))    (* PUSH BX (offset) *)
END PushFarSlotMem;

(* Push the far address currently in ES:BX (pointer deref / indexed element). *)
PROCEDURE PushFarEsBx;
BEGIN
  Cgen.Emit1(BYTE(Cgen.OpPushEs));   (* PUSH ES (segment) *)
  Cgen.Emit2(08BH, 0C3H);            (* MOV AX, BX *)
  Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH AX (offset) *)
END PushFarEsBx;

(* LoadFarAddrEsBxForAggr — ES:BX := far address of a by-value RECORD/fixed-
   array actual, for Cgen.CgPushAggrValue's source.  Cgen.CgLoadFarAddrEsBx
   only knows MGlobal/MLocal (each with its own isRef flag); it was never
   correct for arg.mode=MReg (an already-indexed/dereferenced element),
   silently misreading `adr` as a BP offset via CgLesBxItem's MGlobal/MLocal
   dispatch -- a pre-existing bug, not introduced by §4.1, just newly
   reachable now that plain array-of-record indexing takes the MReg path
   more often (near or far).  For MReg, ES:BX (or, if arg.nearBase, just
   BX with the implicit segment synthesized here) is already the address —
   the preceding PExpr.ParseExpression's own indexing/deref codegen loaded it;
   nothing more to do beyond making sure ES is set for the near case. *)
PROCEDURE LoadFarAddrEsBxForAggr(VAR arg: Cgen.Item);
BEGIN
  (* arg.type.form is RECORD/ARRAY here (caller's own guard) -- Oberon has
     no record/array-valued expression, so an MReg arg here is always an
     already-dereferenced designator result (isRef=TRUE), never a bare
     computed value.  Guard on isRef anyway to stay explicit. *)
  IF (arg.mode = Cgen.MReg) & arg.isRef THEN
    IF arg.nearBase THEN Cgen.CgEsFromMode(PExpr.NearRootMode(arg)) END
    (* else: ES:BX already loaded by the indexing/deref that produced arg. *)
  ELSE
    Cgen.CgLoadFarAddrEsBx(arg.mode, arg.adr, arg.isRef)
  END
END LoadFarAddrEsBxForAggr;

PROCEDURE ParseActualParameters*(pt: Syms.TypeDesc);
  VAR arg: Cgen.Item; p: Syms.Symbol; bad: BOOLEAN;
      isOpenFormal: BOOLEAN;
      pty: Syms.TypeDesc;
      isFarPtrArg: BOOLEAN;
BEGIN
  PExpr.Expect(Scan.TLparen);
  p := pt.symList; bad := FALSE;
  WHILE ~bad & (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
    IF p = Syms.NoSym THEN PExpr.Error("too many parameters"); PExpr.ParseExpression(arg)
    ELSE
      pty := p.type;
      IF p.kind = Syms.KVarParam THEN
        (* VAR param: pass far address {segment:2, offset:2}.
           VAR open-array formal also needs LEN pushed first (deepest).
           Pascal l-to-r push order (first push = deepest = highest BP offset):
             VAR open-array: PUSH LEN, PUSH segment, PUSH offset
             other VAR:                PUSH segment, PUSH offset
           A non-l-value actual (string literal, constant expression, ...)
           is rejected by CheckParamCompat below — but ParseDesignator itself
           demands an identifier and would abort the parse with a harsher
           "identifier expected" first.  Route anything that isn't the start
           of a designator through PExpr.ParseExpression instead, purely so the
           actual gets consumed and CheckParamCompat can give its intended
           clean rejection message. *)
        IF PExpr.sc.sym = Scan.TIdent THEN ParseDesignator(arg) ELSE PExpr.ParseExpression(arg) END;
        PExpr.MarkRead(arg);
        CheckParamCompat(p, arg);
        isOpenFormal := (p.type # Syms.NoType) & (pty.form = Syms.TFArray) & (pty.len < 0);
        IF isOpenFormal THEN
          (* Push LEN first (deepest) *)
          IF (arg.type # Syms.NoType) & (arg.type.len >= 0) THEN
            Cgen.CgLoadImm(INTEGER(arg.type.len))   (* fixed-size actual: compile-time LEN *)
          ELSIF (arg.mode = Cgen.MLocal) & (arg.type # Syms.NoType) & (arg.type.len < 0) THEN
            Cgen.CgLoadBp(arg.adr + 4)               (* forward open-array formal's LEN *)
          ELSE
            (* No compile-time length and no runtime LEN slot: silently
               passing LEN=0 handed the callee an "empty" array with a live
               pointer — reject instead. *)
            PExpr.Error("cannot determine LEN of open-array actual parameter");
            Cgen.CgLoadImm(0)
          END;
          Cgen.Emit1(BYTE(Cgen.OpPushAx))  (* PUSH LEN *)
        END;
        (* Push far address: segment then offset *)
        IF (arg.typeless OR arg.isRef) & (arg.mode = Cgen.MLocal) THEN
          (* Forwarding a typeless or VAR param: slot already holds far addr {ofs:2, seg:2} *)
          PushFarSlotBp(arg.adr)
        ELSIF (arg.mode = Cgen.MLocal) & (arg.type # Syms.NoType) & (arg.type.len < 0) THEN
          (* Non-VAR open-array formal passed as VAR: 6-byte slot {ofs:2, seg:2, LEN:2}; forward far ptr *)
          PushFarSlotBp(arg.adr)
        ELSIF arg.mode = Cgen.MLocal THEN
          Cgen.CgLoadAddrBp(arg.adr);
          Cgen.Emit1(BYTE(Cgen.OpPushSs));   (* PUSH SS *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH AX *)
        ELSIF (arg.mode = Cgen.MGlobal) & arg.isRef THEN
          (* Imported VAR: data slot holds {ofs:2, seg:2}; forward as-is. *)
          PushFarSlotMem(arg.adr)
        ELSIF arg.mode = Cgen.MGlobal THEN
          Cgen.CgLoadAddrMem(WORD(arg.adr));
          Cgen.Emit1(BYTE(Cgen.OpPushDs));   (* PUSH DS *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH AX *)
        ELSIF (arg.mode = Cgen.MReg) & arg.isRef & arg.nearBase THEN
          (* §4.1 near array/record element: BX alone holds the offset, no
             ES was ever loaded -- synthesize the implicit segment (DS/SS,
             from rootSym.level) before forwarding it as a genuine far
             {seg,ofs} pair; the VAR-param callee always expects one. *)
          Cgen.CgEsFromMode(PExpr.NearRootMode(arg));
          PushFarEsBx
        ELSIF (arg.mode = Cgen.MReg) & arg.isRef THEN
          (* Pointer deref or indexed element: ES:BX holds far address *)
          PushFarEsBx
        ELSIF arg.mode = Cgen.MProc THEN
          (* Procedure name: far address is CS:code_offset. *)
          Cgen.Emit1(BYTE(Cgen.OpPushCs));   (* PUSH CS *)
          Cgen.CgLoadCodeAddr(WORD(arg.adr));  (* MOV AX, ofs + CODE reloc *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH AX (offset) *)
        ELSIF arg.mode = Cgen.MImport THEN
          (* Imported FAR procedure (e.g. SYSTEM.ADR(SYSTEM.Alloc)).
             Linker patches both placeholder words against the import id. *)
          Cgen.CgLoadImportAddr(arg.rdoffId);   (* DX:AX = far addr *)
          Cgen.Emit1(BYTE(Cgen.OpPushDx));    (* PUSH segment *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))     (* PUSH offset  *)
        ELSE
          Cgen.CgLoadItem(arg);
          Cgen.Emit1(BYTE(Cgen.OpPushDs));
          Cgen.Emit1(BYTE(Cgen.OpPushAx))
        END
      ELSE
        (* Non-VAR param *)
        PExpr.ParseExpression(arg);
        CheckParamCompat(p, arg);
        IF (p.type # Syms.NoType) & (pty.form = Syms.TFRecord) THEN
          (* By-value RECORD: caller copies the whole record onto the stack,
             rounded up to an even byte count (2-byte aligned).  The callee reads
             it in place at [BP+ofs]; argSize reserves the same evenSize so the
             post-call SP cleanup balances.  See Cgen.CgPushAggrValue. *)
          LoadFarAddrEsBxForAggr(arg);
          Cgen.CgPushAggrValue(INTEGER((pty.size + LONGINT(1)) DIV LONGINT(2) * LONGINT(2)))
        ELSIF (p.type # Syms.NoType) & (pty.form = Syms.TFArray) & (pty.len >= 0) THEN
          (* By-value FIXED array: same caller-copy as a value record (the formal
             is a fixed-size array, not an open array). *)
          LoadFarAddrEsBxForAggr(arg);
          Cgen.CgPushAggrValue(INTEGER((pty.size + LONGINT(1)) DIV LONGINT(2) * LONGINT(2)))
        ELSIF Syms.IsForm(arg.type, Syms.TFArray) &
            (p.type # Syms.NoType) &
            ((pty.form = Syms.TFChar) OR (pty.form = Syms.TFByte)) THEN
          (* Single-char string "X" passed to CHAR/BYTE formal *)
          IF arg.mode = Cgen.MGlobal THEN Cgen.CgLoadMem(WORD(arg.adr))
          ELSE Cgen.CgLoadItem(arg)
          END;
          Cgen.Emit3(025H, 0FFH, 000H);        (* AND AX, 00FFh *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))
        ELSIF Syms.IsForm(arg.type, Syms.TFArray) THEN
          (* Non-VAR open-array param: pass {LEN:2, seg:2, ofs:2} = 6 bytes.
             Push order (first push = deepest = highest BP offset):
               1. PUSH LEN
               2. PUSH segment
               3. PUSH offset *)
          IF (arg.type.len >= 0) THEN
            Cgen.CgLoadImm(INTEGER(arg.type.len))    (* fixed-size *)
          ELSIF arg.mode = Cgen.MLocal THEN
            Cgen.CgLoadBp(arg.adr + 4)               (* forward open-array formal's LEN *)
          ELSE
            (* Same rule as the VAR path above: no LEN source -> reject. *)
            PExpr.Error("cannot determine LEN of open-array actual parameter");
            Cgen.CgLoadImm(0)
          END;
          Cgen.Emit1(BYTE(Cgen.OpPushAx));  (* PUSH LEN *)
          (* Now push far pointer: segment then offset *)
          IF (arg.mode = Cgen.MGlobal) & arg.isRef THEN
            (* Imported array VAR: slot holds {ofs:2, seg:2} *)
            PushFarSlotMem(arg.adr)
          ELSIF (arg.mode = Cgen.MGlobal) OR (arg.mode = Cgen.MConst) THEN
            Cgen.Emit1(BYTE(Cgen.OpPushDs));             (* PUSH DS *)
            Cgen.CgLoadAddrMem(WORD(arg.adr));
            Cgen.Emit1(BYTE(Cgen.OpPushAx))             (* PUSH offset *)
          ELSIF (arg.mode = Cgen.MLocal) & (arg.type.len >= 0) & ~arg.isRef THEN
            (* genuine local fixed-size array by value: its bytes live in the
               stack slot, so its address is SS:[BP+adr]. *)
            Cgen.Emit1(BYTE(Cgen.OpPushSs));             (* PUSH SS *)
            Cgen.CgLoadAddrBp(arg.adr);
            Cgen.Emit1(BYTE(Cgen.OpPushAx))             (* PUSH offset *)
          ELSIF arg.mode = Cgen.MLocal THEN
            (* far ptr already in the slot at [BP+adr]: either an open-array
               formal, or a VAR fixed-array-alias param (arg.isRef) whose slot
               holds {ofs:2,seg:2} — forward the pointer, do NOT take the slot's
               own address. *)
            PushFarSlotBp(arg.adr)
          ELSIF (arg.mode = Cgen.MReg) & arg.isRef & arg.nearBase THEN
            (* §4.1 near element: synthesize the implicit segment first. *)
            Cgen.CgEsFromMode(PExpr.NearRootMode(arg));
            PushFarEsBx
          ELSIF (arg.mode = Cgen.MReg) & arg.isRef THEN
            (* ES:BX already holds far address (record field, indexed elem) *)
            PushFarEsBx
          ELSE
            Cgen.CgLoadItem(arg);
            Cgen.Emit1(BYTE(Cgen.OpPushDx));            (* PUSH DX (segment) *)
            Cgen.Emit1(BYTE(Cgen.OpPushAx))             (* PUSH AX (offset) *)
          END
        ELSIF Syms.IsForm(arg.type, Syms.TFLongint) THEN
          Cgen.CgLoadItem(arg);
          (* Narrow to formal's slot size: a LONGINT actual passed to an
             INTEGER/WORD/BYTE formal pushes only AX; PUSH DX is emitted
             only when the formal is also 32-bit (LONGINT). *)
          IF (p.type # Syms.NoType) & (pty.form = Syms.TFLongint) THEN
            Cgen.CgPushDxax()
          ELSE
            Cgen.Emit1(BYTE(Cgen.OpPushAx))
          END
        ELSIF (p.type # Syms.NoType) & (pty.form = Syms.TFLongint) &
              (arg.type # Syms.NoType) & (arg.type.form # Syms.TFLongint) &
              ~PExpr.IsFpuType(arg) THEN
          (* When actual is a CONST and formal is LONGINT, promote
             arg.type to LONGINT before CgLoadItem so the constant is loaded
             via cg_load_long_imm (which uses XOR DX,DX when hi=0).  Otherwise
             load AX then sign-/zero-extend at runtime. *)
          IF arg.mode = Cgen.MConst THEN
            arg.type := Syms.TypeLongint;
            Cgen.CgLoadItem(arg)
          ELSE
            Cgen.CgLoadItem(arg);
            IF (arg.type.form = Syms.TFByte) OR (arg.type.form = Syms.TFChar) OR
               (arg.type.form = Syms.TFBoolean) OR (arg.type.form = Syms.TFWord) THEN
              Cgen.CgZeroDx()  (* XOR DX,DX — zero-extend (WORD/BYTE/CHAR are unsigned) *)
            ELSE
              Cgen.CgCwd()        (* CWD — sign-extend INTEGER *)
            END
          END;
          Cgen.CgPushDxax()
        ELSIF PExpr.IsFpuType(arg) THEN
          Cgen.CgLoadItem(arg);
          (* Push 4 bytes if arg AND formal are plain REAL;
             push 8 bytes if either is LONGREAL. *)
          IF (arg.type.form = Syms.TFLongreal) OR
             ((p.type # Syms.NoType) & (pty.form = Syms.TFLongreal)) THEN
            Cgen.CgFpush()                              (* 8-byte qword *)
          ELSE
            Cgen.EmitCodeStr("83,EC,04,89,E3,36,D9,1F") (* 4-byte dword *)
          END
        ELSE
          (* For POINTER/ADDRESS/NILTYPE/far-PROC: 4-byte far pointer arg,
             needs both DX (segment) and AX (offset) — not eligible for the
             single-word memory-push fast path below. *)
          isFarPtrArg := (arg.type # Syms.NoType) &
             ((arg.type.form = Syms.TFPointer) OR
              (arg.type.form = Syms.TFNiltype) OR
              (arg.type.form = Syms.TFAddress) OR
              ((arg.type.form = Syms.TFProc) & arg.type.isFar)) &
             ((p.type = Syms.NoType) OR
              (pty.form = Syms.TFPointer) OR
              (pty.form = Syms.TFAddress) OR
              (pty.form = Syms.TFNiltype) OR
              ((pty.form = Syms.TFProc) & p.type.isFar));
          (* Fast path: a plain scalar actual (INTEGER/WORD/CHAR/BYTE/
             BOOLEAN — isFarPtrArg excludes the 4-byte case above) that is
             still a bare, unloaded MGlobal/MLocal item (no isRef — see
             DOCS/CODEGEN-SIZE.MD §2/§3) can be pushed straight from
             memory with no load at all: `PUSH [mem]` instead of
             `MOV AX,[mem]` + `PUSH AX`. *)
          IF ~isFarPtrArg & ~arg.isRef &
             ((arg.mode = Cgen.MGlobal) OR (arg.mode = Cgen.MLocal)) THEN
            IF arg.mode = Cgen.MLocal THEN Cgen.CgPushMemBp(arg.adr)
            ELSE Cgen.CgPushMemGlobal(WORD(arg.adr)) END
          ELSE
            Cgen.CgLoadItem(arg);
            IF isFarPtrArg THEN
              Cgen.Emit1(BYTE(Cgen.OpPushDx))   (* PUSH DX (segment) *)
            END;
            Cgen.Emit1(BYTE(Cgen.OpPushAx))
          END
        END
      END;
      p := p.next
    END;
    IF IsLex(Scan.TComma) THEN
    ELSIF PExpr.sc.sym # Scan.TRparen THEN
      (* Malformed list: after an argument the next token must be ',' or ')'.
         Anything else (e.g. a missing ')' that lets a statement terminator leak
         in) would make the loop spin without consuming a token — stop here. *)
      bad := TRUE
    END
  END;
  IF bad THEN PExpr.Error("syntax error") ELSE PExpr.Expect(Scan.TRparen) END;
  IF p # NIL THEN PExpr.Error("too few parameters") END
END ParseActualParameters;

(* ---- inline call ---- *)

PROCEDURE EmitInlineCall*(pt: Syms.TypeDesc);
  VAR n: Syms.InlineNode; hasParam: BOOLEAN;
      argAdr: ARRAY 32 OF LONGINT; argGlobal: ARRAY 32 OF BOOLEAN;
      nArgs, idx: INTEGER; arg: Cgen.Item; f: Syms.Symbol; k: INTEGER;
BEGIN
  hasParam := FALSE;
  n := pt.inlineList;
  WHILE n # NIL DO
    k := 0; WHILE k < n^.count DO IF n^.isParam[k] THEN hasParam := TRUE END; INC(k) END;
    n := n^.next
  END;
  IF hasParam THEN
    nArgs := 0; f := pt.symList;
    PExpr.Expect(Scan.TLparen);
    WHILE (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
      ParseDesignator(arg);
      PExpr.MarkRead(arg);
      IF nArgs < 32 THEN
        argAdr[nArgs] := arg.adr; argGlobal[nArgs] := (arg.mode = Cgen.MGlobal)
      ELSE
        PExpr.Error("too many INLINE call arguments (max 32)")
      END;
      INC(nArgs);
      IF f # Syms.NoSym THEN f := f.next END;
      IsLex(Scan.TComma)
    END;
    PExpr.Expect(Scan.TRparen);
    n := pt.inlineList;
    WHILE n # NIL DO
      k := 0;
      WHILE k < n^.count DO
        IF ~n^.isParam[k] THEN
          Cgen.Emit1(n^.rawByte[k])
        ELSE
          idx := n^.paramIdx[k];
          IF (idx >= 0) & (idx < nArgs) & (idx < 32) THEN
            IF argGlobal[idx] THEN
              Rdoff.RdfAddReloc(Cgen.CgObj, Rdoff.SegCode, Cgen.CgPc(), 2, Rdoff.SegData, FALSE)
            END;
            Cgen.EmitW(INTEGER(argAdr[idx] MOD 65536))
          ELSE Cgen.EmitW(0)
          END
        END;
        INC(k)
      END;
      n := n^.next
    END
  ELSE
    IF (pt.tagIdOrNParams > 0) OR (PExpr.sc.sym = Scan.TLparen) THEN ParseActualParameters(pt) END;
    n := pt.inlineList;
    WHILE n # NIL DO
      k := 0; WHILE k < n^.count DO Cgen.Emit1(n^.rawByte[k]); INC(k) END;
      n := n^.next
    END
  END
END EmitInlineCall;

(* ---- SYSTEM intrinsic ---- *)

(* SetIntResultType — the LSL/LSR/ASR/ROR and AND/IOR/XOR arms both finish by
   picking the result type from the same isLong/isWord flags and setting mode
   to MReg; factor that identical tail once. *)
PROCEDURE SetIntResultType(VAR item: Cgen.Item; isLong, isWord: INTEGER);
BEGIN
  IF isLong = 1 THEN item.type := Syms.TypeLongint
  ELSIF isWord = 1 THEN item.type := Syms.TypeWord
  ELSE item.type := Syms.TypeInteger END;
  item.mode := Cgen.MReg
END SetIntResultType;

(* ClassLongWord — widen isLong/isWord (already-set, e.g. from a prior
   operand) to account for type t: LONGINT wins outright; WORD only applies
   if not already LONGINT.  Called once per operand; the first call passes
   isLong=isWord=0 to get a fresh classification, the second (for a
   two-operand SYSTEM intrinsic like AND/IOR/XOR) accumulates onto the
   first operand's result. *)
PROCEDURE ClassLongWord(t: Syms.TypeDesc; VAR isLong, isWord: INTEGER);
BEGIN
  IF (isLong = 0) & (t # Syms.NoType) & (t.form = Syms.TFLongint) THEN isLong := 1 END;
  IF (isLong = 0) & (isWord = 0) & (t # Syms.NoType) & (t.form = Syms.TFWord) THEN isWord := 1 END
END ClassLongWord;

PROCEDURE ParseSystemIntrinsic(VAR item: Cgen.Item; id: INTEGER);
  VAR arg, xItem: Cgen.Item; nConst: BOOLEAN; nVal, isLong, isWord: INTEGER;
BEGIN
  PExpr.Expect(Scan.TLparen);
  CASE id OF
    Syms.SpLsl, Syms.SpLsr, Syms.SpAsr, Syms.SpRor:
      PExpr.ParseExpression(xItem);
      isLong := 0; isWord := 0;
      ClassLongWord(xItem.type, isLong, isWord);
      Cgen.CgLoadItem(xItem);
      IF isLong = 1 THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
      PExpr.Expect(Scan.TComma);
      PExpr.ParseExpression(arg);
      nConst := (arg.mode = Cgen.MConst);
      nVal := INTEGER(arg.val MOD 32);
      Cgen.CgLoadItem(arg);
      IF nConst THEN
        nVal := nVal MOD 32;
        IF isLong = 1 THEN
          Cgen.CgPopAxdx();  (* POP AX; POP DX *)
          CASE id OF
            Syms.SpLsl: Cgen.CgLsl32Imm(nVal)
          | Syms.SpLsr: Cgen.CgLsr32Imm(nVal)
          | Syms.SpAsr: Cgen.CgAsr32Imm(nVal)
          ELSE Cgen.CgRor32Imm(nVal)
          END
        ELSE
          Cgen.Emit1(BYTE(Cgen.OpPopAx));
          IF nVal = 0 THEN (* no-op *)
          ELSIF nVal >= 16 THEN
            IF (id = Syms.SpLsl) OR (id = Syms.SpLsr) THEN
              Cgen.CgZeroAx()
            ELSIF id = Syms.SpAsr THEN Cgen.CgSarImm(15)
            ELSE nVal := nVal MOD 16; IF nVal > 0 THEN Cgen.CgRorImm(nVal) END
            END
          ELSE
            CASE id OF
              Syms.SpLsl: Cgen.CgShlImm(nVal)
            | Syms.SpLsr: Cgen.CgShrImm(nVal)
            | Syms.SpAsr: Cgen.CgSarImm(nVal)
            ELSE Cgen.CgRorImm(nVal)
            END
          END
        END
      ELSE
        Cgen.Emit2(08AH, 0C8H);  (* MOV CL, AL *)
        IF isLong = 1 THEN
          Cgen.CgPopAxdx();  (* POP AX; POP DX *)
          CASE id OF
            Syms.SpLsl: Cgen.CgLsl32Cl()
          | Syms.SpLsr: Cgen.CgLsr32Cl()
          | Syms.SpAsr: Cgen.CgAsr32Cl()
          ELSE Cgen.CgRor32Cl()
          END
        ELSE
          Cgen.Emit3(080H, 0E1H, 00FH);  (* AND CL, 0Fh *)
          Cgen.Emit1(BYTE(Cgen.OpPopAx));
          CASE id OF
            Syms.SpLsl: Cgen.CgShlCl()
          | Syms.SpLsr: Cgen.CgShrCl()
          | Syms.SpAsr: Cgen.CgSarCl()
          ELSE Cgen.CgRorCl()
          END
        END
      END;
      SetIntResultType(item, isLong, isWord)

  | Syms.SpAnd, Syms.SpIor, Syms.SpXor:
      PExpr.ParseExpression(xItem);
      isLong := 0; isWord := 0;
      ClassLongWord(xItem.type, isLong, isWord);
      Cgen.CgLoadItem(xItem);
      IF isLong = 1 THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
      PExpr.Expect(Scan.TComma);
      PExpr.ParseExpression(arg);
      ClassLongWord(arg.type, isLong, isWord);
      Cgen.CgLoadItem(arg);
      IF isLong = 1 THEN
        Cgen.CgPopCxbx();
        CASE id OF
          Syms.SpAnd: Cgen.CgAnd32()
        | Syms.SpIor: Cgen.CgOr32()
        ELSE Cgen.CgXor32()
        END
      ELSE
        Cgen.Emit2(089H, 0C1H);  (* MOV CX, AX *)
        Cgen.Emit1(BYTE(Cgen.OpPopAx));
        CASE id OF
          Syms.SpAnd: Cgen.CgAnd()
        | Syms.SpIor: Cgen.CgOr()
        ELSE Cgen.CgXor()
        END
      END;
      SetIntResultType(item, isLong, isWord)
  ELSE
    PExpr.Error("SYSTEM intrinsic not usable as expression");
    item.type := Syms.TypeInteger; item.mode := Cgen.MConst; item.val := 0
  END;
  PExpr.Expect(Scan.TRparen)
END ParseSystemIntrinsic;

(* ---- designator ---- *)

PROCEDURE ParseDesignator;
  VAR sym, sym2, fld: Syms.Symbol;
      qname: ARRAY 66 OF CHAR;
      impName: ARRAY 66 OF CHAR;
      index: Cgen.Item;
      elem: Syms.TypeDesc;
      ts: Syms.Scope;
      more, wasConst, negConst: BOOLEAN;
      mark: Scan.Scanner; markPos: LONGINT;
BEGIN
  IF PExpr.sc.sym # Scan.TIdent THEN PExpr.Error("identifier expected"); RETURN END;
  sym := Syms.SymFind(PExpr.sc.id);
  IF sym = Syms.NoSym THEN PExpr.Error2("undefined identifier", PExpr.sc.id); Scan.Next(PExpr.sc); RETURN END;
  Scan.Next(PExpr.sc);

  item.type := sym.type; item.isRef := FALSE; item.isFar := FALSE;
  item.typeless := FALSE; item.addrDeref := FALSE; item.nearBase := FALSE;
  item.rdoffId := sym.rdoffId; item.fwdSym := Syms.NoSym;
  item.rootSym := sym;

  ts := Syms.TopScope;
  (* Visibility rule: a procedure can read/write only module-level (global)
     variables, imported names, and its OWN locals and parameters.  Reading
     a variable or parameter declared in an enclosing procedure is illegal. *)
  IF ((sym.kind = Syms.KVar) OR (sym.kind = Syms.KParam)
      OR (sym.kind = Syms.KVarParam))
     & (sym.level > 0) & (sym.level < ts^.level) THEN
    PExpr.Error("uplevel access not allowed (variable belongs to enclosing procedure)")
  END;

  CASE sym.kind OF
    Syms.KConst:
      item.mode := Cgen.MConst; item.val := sym.val; item.adr := sym.adr
  | Syms.KVar:
      IF sym.level = 0 THEN item.mode := Cgen.MGlobal
      ELSE item.mode := Cgen.MLocal END;
      item.adr := sym.adr
  | Syms.KParam:
      item.mode := Cgen.MLocal; item.adr := sym.adr
  | Syms.KVarParam:
      item.mode := Cgen.MLocal; item.adr := sym.adr; item.isRef := TRUE;
      item.typeless := sym.typeless
  | Syms.KProc:
      item.mode := Cgen.MProc; item.adr := sym.adr;
      item.isFar := (sym.type # Syms.NoType) & sym.type.isFar;
      IF sym.rdoffId # -1 THEN item.mode := Cgen.MImport END;
      IF sym.fwdDecl THEN item.fwdSym := sym END
  | Syms.KSysProc:
      item.mode := Cgen.MSysProc; item.val := LONGINT(sym.sysId)
  | Syms.KImport:
      item.mode := Cgen.MImport; item.adr := 0; item.rdoffId := -1
  ELSE
    PExpr.Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
  END;

  WHILE (PExpr.sc.sym = Scan.TDot) OR (PExpr.sc.sym = Scan.TLbrak) OR (PExpr.sc.sym = Scan.TArrow) DO
    IF IsLex(Scan.TDot) THEN
      IF PExpr.sc.sym # Scan.TIdent THEN PExpr.Error("identifier expected after '.'"); RETURN END;
      IF sym.kind = Syms.KImport THEN
        StrTab.Get(sym.nameId, qname); Strings.Append(".", qname); Strings.Append(PExpr.sc.id, qname);
        (* Linker-visible import name uses underscore, not dot.
           full_name = "<real_mod>_<short>" — modId when set, else
           the alias's own name. *)
        IF sym.modId # 0 THEN StrTab.Get(sym.modId, impName)
        ELSE StrTab.Get(sym.nameId, impName) END;
        Strings.Append("_", impName); Strings.Append(PExpr.sc.id, impName);
        sym2 := Syms.SymFind(qname);
        IF sym2 = Syms.NoSym THEN sym2 := Syms.SymFind(PExpr.sc.id) END;
        IF sym2 = Syms.NoSym THEN PExpr.Error2("undefined in module", PExpr.sc.id); Scan.Next(PExpr.sc); RETURN END;
        item.type := sym2.type; item.rdoffId := sym2.rdoffId;
        item.val := sym2.val; item.adr := sym2.adr; item.fwdSym := Syms.NoSym;
        CASE sym2.kind OF
          Syms.KConst:  item.mode := Cgen.MConst
        | Syms.KVar:
            IF sym2.level = 0 THEN
              (* Cross-module imported VAR: a 4-byte far-pointer slot in this
                 module's data segment, patched by the linker with the address
                 of the imported symbol.  The slot is emitted ONCE per
                 imported symbol and cached in sym2 (rdoffId/adr) — emitting a
                 fresh slot per *use* wasted 4 data bytes + 2 relocs for every
                 source reference.  (sym2.adr's .def-supplied remote offset is
                 never used for VAR imports — the linker patches by name.) *)
              IF sym2.rdoffId = -1 THEN
                sym2.rdoffId := PExpr.GetSystemImport(impName);
                sym2.adr     := Cgen.CgImportVarSlot(sym2.rdoffId)
              END;
              item.rdoffId := sym2.rdoffId;
              item.mode    := Cgen.MGlobal;
              item.adr     := sym2.adr;
              item.isRef   := TRUE;
              item.isFar   := FALSE
            ELSE item.mode := Cgen.MLocal END
        | Syms.KProc:
            item.isFar := (item.type # Syms.NoType) & item.type.isFar;
            IF (item.type # Syms.NoType) & item.type.isInline THEN
              item.mode := Cgen.MProc  (* inline: no RDOFF import *)
            ELSIF sym2.rdoffId # -1 THEN
              item.mode := Cgen.MImport  (* EXTERNAL proc already has import id *)
            ELSE
              (* cross-module proc: allocate RDOFF import entry now.
                 impName was already built above as
                 "<real module>_<ident>" from the IMPORT symbol's own
                 modId (the alias's real module name) -- identical to the
                 link name the .def carries, since every .def PROC entry
                 is "<MODULE>_<short>" (verified across the whole stdlib:
                 159 procs, zero exceptions).  The KVar branch above
                 already relies on exactly this reconstruction; re-reading
                 sym2.modId here only re-fetched a separately interned
                 copy of the same text.  Not re-reading it lets DEF.MOD
                 stop interning that per-proc string at all -- see the
                 modId comment in DEF.MOD's PROC/INLINE handling. *)
              item.rdoffId := PExpr.GetSystemImport(impName);
              item.mode := Cgen.MImport
            END
        | Syms.KSysProc:
            item.mode := Cgen.MSysProc; item.val := LONGINT(sym2.sysId)
        | Syms.KType:
            (* SYSTEM.ADDRESS(x): qualified type-cast to ADDRESS.  Only a 4-byte
               source (LONGINT — the documented conversion — or pointer/address/
               far PROC) is valid; the segment is preserved.  Handled inline here
               because the unqualified-cast path (ParseFactor TIdent) only sees a
               plain type name, not the SYSTEM.-qualified form. *)
            IF Syms.IsForm(item.type, Syms.TFAddress) THEN
              Scan.Next(PExpr.sc);   (* consume ADDRESS *)
              IF PExpr.sc.sym # Scan.TLparen THEN
                PExpr.Error("ADDRESS cast requires (expr)"); item.mode := Cgen.MConst; item.val := 0;
                item.type := Syms.TypeAddress; RETURN
              END;
              Scan.Next(PExpr.sc); PExpr.ParseExpression(index); PExpr.Expect(Scan.TRparen);
              Cgen.CgLoadItem(index);
              IF (index.type # Syms.NoType) &
                 ((index.type.form = Syms.TFLongint) OR
                  (index.type.form = Syms.TFAddress) OR
                  (index.type.form = Syms.TFPointer) OR
                  (index.type.form = Syms.TFProc)) THEN
                (* already 4-byte DX:AX *)
              ELSE
                PExpr.Error("ADDRESS() accepts only LONGINT (or pointer/address)")
              END;
              item.mode := Cgen.MReg; item.type := Syms.TypeAddress;
              item.isRef := FALSE; item.addrDeref := FALSE; item.nearBase := FALSE; RETURN
            ELSE
              PExpr.Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
            END
        ELSE
          PExpr.Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
        END;
        sym := sym2
      ELSE
        (* Auto-dereference: a field selector "." applied to a POINTER-to-record
           implicitly dereferences it (Oberon-07 p.f == p^.f).  Emit the same
           far-ptr load as T_ARROW, then access the field of the base record. *)
        IF Syms.IsForm(item.type, Syms.TFPointer) THEN
          IF (item.mode = Cgen.MLocal) & ~item.isRef THEN
            Cgen.CgLesBxBp(item.adr)
          ELSIF (item.mode = Cgen.MGlobal) & ~item.isRef THEN
            Cgen.CgLesBxMem(WORD(item.adr))
          ELSE
            Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
          END;
          item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE;
          item.type := item.type.base; item.adr := 0
        END;
        IF (item.type = Syms.NoType) OR (item.type.form # Syms.TFRecord) THEN
          PExpr.Error("not a record"); Scan.Next(PExpr.sc); RETURN
        END;
        fld := Syms.SymFindField(item.type, PExpr.sc.id);
        IF fld = Syms.NoSym THEN PExpr.Error2("undefined field", PExpr.sc.id); Scan.Next(PExpr.sc); RETURN END;
        item.type := fld.type;
        (* TDOT field access: when item is_ref, load the far ptr into ES:BX
           (LES if local/global, else MOV) and advance BX by the field offset.
           Do NOT CgLoadItem — that would DEREF the pointer when we just want
           the address. *)
        IF item.isRef THEN
          IF item.mode = Cgen.MLocal THEN Cgen.CgLesBxBp(item.adr)
          ELSIF item.mode = Cgen.MGlobal THEN Cgen.CgLesBxMem(WORD(item.adr))
          (* else MReg: ES:BX already set *)
          END;
          Cgen.CgAddBxImm(INTEGER(fld.adr));
          item.mode := Cgen.MReg
          (* isRef stays TRUE *)
        ELSE
          INC(item.adr, fld.adr)
        END
      END;
      Scan.Next(PExpr.sc)
    ELSIF PExpr.sc.sym = Scan.TLbrak THEN
      more := TRUE;
      WHILE more DO
        Scan.Next(PExpr.sc);
        (* SYSTEM.ADDRESS deref byte indexing: `p^[i]` where p: ADDRESS.  The
           preceding `^` left a CHAR ref in ES:BX (mode=MReg, isRef, type CHAR).
           Index it as a byte: BX := BX + i (element size 1, no bounds check),
           keep the CHAR ref.  Math is offset-only; ES (segment) is untouched. *)
        IF item.addrDeref THEN
          Cgen.Emit1(BYTE(Cgen.OpPushEs));                  (* PUSH ES *)
          Cgen.Emit1(BYTE(Cgen.OpPushBx));   (* PUSH BX *)
          PExpr.ParseExpression(index);
          Cgen.CgLoadItem(index);
          Cgen.Emit1(BYTE(Cgen.OpPopBx));                  (* POP BX (base offset) *)
          Cgen.CgAddBxAx();            (* ADD BX, AX *)
          Cgen.Emit1(BYTE(Cgen.OpPopEs));                  (* POP ES *)
          item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE;
          item.type := Syms.TypeChar;
          item.addrDeref := FALSE;
          IF PExpr.sc.sym # Scan.TComma THEN more := FALSE END;
          IF more THEN PExpr.Error("too many index dimensions for ADDRESS") END
        ELSE
        (* Auto-dereference: an index selector "[" applied to a POINTER-to-array
           implicitly dereferences it (Oberon-07 p[i] == p^[i]). *)
        IF Syms.IsForm(item.type, Syms.TFPointer) THEN
          IF (item.mode = Cgen.MLocal) & ~item.isRef THEN
            Cgen.CgLesBxBp(item.adr)
          ELSIF (item.mode = Cgen.MGlobal) & ~item.isRef THEN
            Cgen.CgLesBxMem(WORD(item.adr))
          ELSE
            Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
          END;
          item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE;
          item.type := item.type.base; item.adr := 0
        END;
        IF (item.type = Syms.NoType) OR (item.type.form # Syms.TFArray) THEN
          PExpr.Error("not an array"); PExpr.ParseExpression(index); more := FALSE
        ELSE
          (* §4.1 (DOCS/CODEGEN-SIZE.MD): a module-level/local fixed array,
             never a VAR-param alias and never behind a pointer deref
             anywhere in this designator's chain so far, is provably
             DS/SS-relative at runtime -- no far ES:BX pair is needed, just
             a plain offset in BX (near := TRUE below).  Every other case
             (VAR-param array, open array, pointer-to-array, or continuing
             a chain that already went far at an earlier step) keeps the
             original far ES:BX path unchanged (near := FALSE). *)
          elem := item.type.elemOrRet;
          IF (item.mode = Cgen.MReg) & item.isRef & item.nearBase THEN
            (* Continuing an already-near chain (e.g. a[i][j]): BX alone
               already holds the base offset, implicit segment unchanged. *)
            Cgen.Emit1(BYTE(Cgen.OpPushBx));(* PUSH BX *)
            PExpr.ParseExpression(index);
            wasConst := PExpr.IsIntConst(index);
            IF PExpr.boundsChk & wasConst &
               (item.type.len >= 0) &
               ((index.val < 0) OR (index.val >= item.type.len)) THEN
              PExpr.Error("index out of bounds")
            END;
            Cgen.CgLoadItem(index);
            IF ~wasConst & (item.type.len >= 0) THEN
              EmitBoundsCheck(item.type.len, 0)
            END;
            IF elem.size = 2 THEN Cgen.CgShlAx1()            (* SHL AX,1 *)
            ELSIF (elem.size > 2) & PExpr.IsPow2(elem.size) THEN
              Cgen.CgShlImm(PExpr.Log2(elem.size))                       (* SHL AX, log2(size) *)
            ELSIF elem.size > 2 THEN
              Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
            END;
            Cgen.Emit1(BYTE(Cgen.OpPopBx));                (* POP BX (base offset) *)
            Cgen.CgAddBxAx()             (* ADD BX, AX *)
            (* nearBase stays TRUE; no ES to restore. *)
          ELSIF (item.mode = Cgen.MReg) & item.isRef THEN
            (* ES:BX points to array base (through far pointer).
               PUSH ES to preserve array segment across index expression. *)
            Cgen.Emit1(BYTE(Cgen.OpPushEs));                 (* PUSH ES *)
            Cgen.Emit1(BYTE(Cgen.OpPushBx));(* PUSH BX *)
            PExpr.ParseExpression(index);
            (* Capture const-ness BEFORE CgLoadItem (which changes mode to MReg). *)
            wasConst := PExpr.IsIntConst(index);
            IF PExpr.boundsChk & wasConst &
               (item.type.len >= 0) &
               ((index.val < 0) OR (index.val >= item.type.len)) THEN
              PExpr.Error("index out of bounds")
            END;
            Cgen.CgLoadItem(index);
            IF ~wasConst & (item.type.len >= 0) THEN
              EmitBoundsCheck(item.type.len, 0)
            END;
            IF elem.size = 2 THEN Cgen.CgShlAx1()            (* SHL AX,1 *)
            ELSIF (elem.size > 2) & PExpr.IsPow2(elem.size) THEN
              Cgen.CgShlImm(PExpr.Log2(elem.size))                       (* SHL AX, log2(size) *)
            ELSIF elem.size > 2 THEN
              Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
            END;
            Cgen.Emit1(BYTE(Cgen.OpPopBx));                (* POP BX (base offset) *)
            Cgen.CgAddBxAx();            (* ADD BX, AX *)
            Cgen.Emit1(BYTE(Cgen.OpPopEs));                  (* POP ES *)
          ELSIF ((item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal)) &
                ~item.isRef & (item.type.len >= 0) THEN
            (* §4.1 near path: plain fixed array, first dimension.
               §2.7 (DOCS/CODEGEN-SIZE.MD): recognize a plain integer-
               literal index (optionally negated) WITHOUT emitting any
               code first -- PExpr.ParseExpression itself cannot be called
               before deciding, because for a compound index expression
               (e.g. i+j) it emits real code eagerly (single-pass, no
               AST) and materializes the result into AX, which
               CgLoadAddrItem would then clobber.  A bare TInt, or TMinus
               immediately followed by TInt (peeked via Scan.Mark/Restore,
               matching ParseSimpleExpression's own unary-minus constant
               fold), is recognized as "constant" here; anything else --
               including a named CONST or a foldable sub-expression --
               falls through to the original runtime address-math path,
               unchanged, with PExpr.ParseExpression called at its original spot
               (after the base address is already in BX). *)
            negConst := FALSE;
            IF PExpr.sc.sym = Scan.TMinus THEN
              Scan.Mark(PExpr.sc, mark, markPos);
              Scan.Next(PExpr.sc);
              IF PExpr.sc.sym = Scan.TInt THEN negConst := TRUE
              ELSE Scan.Restore(PExpr.sc, mark, markPos)
              END
            END;
            wasConst := negConst OR (PExpr.sc.sym = Scan.TInt);
            IF wasConst THEN
              index.val := PExpr.sc.ival;
              IF negConst THEN index.val := -index.val END;
              IF PExpr.boundsChk THEN
                IF index.val < 0 THEN PExpr.Error("index out of bounds") END;
                IF index.val >= item.type.len THEN PExpr.Error("index out of bounds") END
              END;
              Scan.Next(PExpr.sc);
              INC(item.adr, index.val * LONGINT(elem.size))
              (* item stays MGlobal/MLocal, adr now points straight at the
                 element -- every existing CgLoadItem/CgStoreItem branch
                 already handles this optimally, no MReg/nearBase needed. *)
            ELSE
              Cgen.CgLoadAddrItem(item.mode, item.adr);
              Cgen.CgMovBxAx();   (* MOV BX, AX *)
              Cgen.Emit1(BYTE(Cgen.OpPushBx));(* PUSH BX *)
              PExpr.ParseExpression(index);
              Cgen.CgLoadItem(index);
              EmitBoundsCheck(item.type.len, 0);
              IF elem.size = 2 THEN Cgen.CgShlAx1()
              ELSIF (elem.size > 2) & PExpr.IsPow2(elem.size) THEN
                Cgen.CgShlImm(PExpr.Log2(elem.size))
              ELSIF elem.size > 2 THEN
                Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
              END;
              Cgen.Emit1(BYTE(Cgen.OpPopBx));        (* POP BX (base offset) *)
              Cgen.CgAddBxAx();  (* ADD BX, AX *)
              item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := TRUE
            END
          ELSE
            (* Load array base into ES:BX (far path: VAR-param array,
               open array, or pointer-to-array target). *)
            IF (item.mode = Cgen.MLocal) & (item.isRef OR (item.type.len < 0)) THEN
              Cgen.CgLesBxBp(item.adr)
            ELSIF ((item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal)) & item.isRef THEN
              Cgen.CgLesBxItem(item.mode, item.adr)
            ELSIF (item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal) THEN
              Cgen.CgLoadAddrItem(item.mode, item.adr);
              Cgen.CgEsFromMode(item.mode);
              Cgen.CgMovBxAx()   (* MOV BX, AX *)
            ELSE
              Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
            END;
            (* PUSH ES,BX to preserve array segment across index eval. *)
            Cgen.Emit1(BYTE(Cgen.OpPushEs));                 (* PUSH ES *)
            Cgen.Emit1(BYTE(Cgen.OpPushBx));                 (* PUSH BX *)
            PExpr.ParseExpression(index);
            wasConst := PExpr.IsIntConst(index);
            IF PExpr.boundsChk & wasConst THEN
              IF index.val < 0 THEN PExpr.Error("index out of bounds") END;
              IF (item.type.len >= 0) & (index.val >= item.type.len) THEN
                PExpr.Error("index out of bounds")
              END
            END;
            Cgen.CgLoadItem(index);
            IF ~wasConst THEN
              IF item.type.len < 0 THEN EmitBoundsCheck(-1, item.adr + 4)
              ELSE EmitBoundsCheck(item.type.len, 0) END
            END;
            IF elem.size = 2 THEN Cgen.CgShlAx1()
            ELSIF (elem.size > 2) & PExpr.IsPow2(elem.size) THEN
              Cgen.CgShlImm(PExpr.Log2(elem.size))                       (* SHL AX, log2(size) *)
            ELSIF elem.size > 2 THEN
              Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
            END;
            Cgen.Emit1(BYTE(Cgen.OpPopBx));        (* POP BX (base offset) *)
            Cgen.CgAddBxAx();  (* ADD BX, AX *)
            Cgen.Emit1(BYTE(Cgen.OpPopEs));        (* POP ES *)
            item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE
          END;
          item.type := elem;
          IF PExpr.sc.sym # Scan.TComma THEN more := FALSE END
        END
        END
      END;
      PExpr.Expect(Scan.TRbrak)
    ELSE  (* TArrow *)
      Scan.Next(PExpr.sc);
      IF Syms.IsForm(item.type, Syms.TFAddress) THEN
        (* SYSTEM.ADDRESS deref: ADDRESS behaves as POINTER TO CHAR.  Load the
           4-byte address value into DX:AX (CgLoadItem handles local/global/
           VAR-param/MReg uniformly), move it to ES:BX, and make the item a CHAR
           ref.  Standalone `p^` reads the byte; a following `[i]` (handled in the
           TLbrak branch) advances BX by i. *)
        Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx();
        item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE;
        item.type := Syms.TypeChar;
        item.adr := 0; item.addrDeref := TRUE
      ELSIF (item.type = Syms.NoType) OR (item.type.form # Syms.TFPointer) THEN PExpr.Error("not a pointer")
      ELSE
        (* T_ARROW: load far ptr into ES:BX using LES when source mode is
           local/global; otherwise CgLoadItem + CgDxaxToEsbx.
           No NIL check emitted (runtime behaviour). *)
        IF (item.mode = Cgen.MLocal) & ~item.isRef THEN
          Cgen.CgLesBxBp(item.adr)
        ELSIF (item.mode = Cgen.MGlobal) & ~item.isRef THEN
          Cgen.CgLesBxMem(WORD(item.adr))
        ELSE
          (* CgDxaxToEsbx emits `8B D8 8E C2`. *)
          Cgen.CgLoadItem(item);
          Cgen.CgDxaxToEsbx()
        END;
        item.mode := Cgen.MReg; item.isRef := TRUE; item.nearBase := FALSE;
        item.type := item.type.base; item.adr := 0
      END
    END
  END
END ParseDesignator;

(* ---- factor ---- *)

PROCEDURE ParseFactor*(VAR item: Cgen.Item);
  VAR sym: Syms.Symbol; arg: Cgen.Item; form, srcForm, id: INTEGER;
      pt: Syms.TypeDesc; varAdr: LONGINT; varGlobal, varRef: BOOLEAN;
      rdId: INTEGER; codeOfs: LONGINT; isImp, isFr: BOOLEAN; pt2: Syms.TypeDesc;
      skipBp: Cgen.Backpatch; loopTop: LONGINT;
      lo, hi: Cgen.Item; skip2: Cgen.Backpatch;
      realVar: REAL; realBytes: ARRAY 4 OF BYTE;
BEGIN
  item.isRef := FALSE; item.isFar := FALSE; item.fwdSym := Syms.NoSym;
  item.rootSym := Syms.NoSym; item.addrDeref := FALSE; item.nearBase := FALSE;
  CASE PExpr.sc.sym OF
    Scan.TInt:
      item.mode := Cgen.MConst; item.val := PExpr.sc.ival;
      (* Literal typing: 0..32767 INTEGER; 32768..65535 WORD (the value's
         actual nature — unsigned 16-bit); >= 65536 LONGINT.
         History: typing 32768..65535 as LONGINT was tried and reverted
         2026-07-11 (self-host regression).  The root cause turned out to be
         the .def CONST format, which carried no type: the value-only reader
         re-derived LONGINT by range, so `Rdoff.SegLimit = 65000` was
         INTEGER in its defining module but LONGINT in every importer — two
         different types for one constant.  With typed .def CONST lines
         (2026-07-17) the declared type round-trips exactly, and with the
         LONGINT-comparison zero-extension fix (same date) a WORD constant
         compares correctly against LONGINT operands — so the WORD typing
         is now sound end-to-end (verified by full make test + gen2==gen3
         self-host).  Note ParseSimpleExpression retypes a negated WORD
         constant back to INTEGER/LONGINT (negation is a signed operation). *)
      (* GENERATION-PROOF thresholds: the bounds MUST be written as
         LONGINT(...) casts.  A bare `32768` here is itself a literal typed
         by the PREVIOUS compiler generation: under the old rule it is
         INTEGER, gets CWD-sign-extended to -32768 in this LONGINT
         comparison, and the test degenerates to always-TRUE — every
         literal became WORD.  This exact self-referential trap is what
         sank the 2026-07-11 attempt.  A cast is immune: the constant's
         .val always holds the true value and LONGINT(c) loads it via
         CgLoadLongImm under every generation. *)
      IF PExpr.sc.ival >= LONGINT(65536) THEN
        item.type := Syms.TypeLongint
      ELSIF PExpr.sc.ival >= LONGINT(32768) THEN
        item.type := Syms.TypeWord
      ELSE item.type := Syms.TypeInteger END;
      Scan.Next(PExpr.sc)

  | Scan.TReal:
      PExpr.modUsesFpu := TRUE;
      item.mode := Cgen.MConst; item.adr := Cgen.CgDpc();
      item.type := Syms.TypeReal;
      realVar := PExpr.sc.rval;
      SYSTEM.MOVE(realVar, realBytes, 4);
      Cgen.EmitDataByte(realBytes[0]); Cgen.EmitDataByte(realBytes[1]);
      Cgen.EmitDataByte(realBytes[2]); Cgen.EmitDataByte(realBytes[3]);
      Scan.Next(PExpr.sc)

  | Scan.TChar:
      item.mode := Cgen.MConst; item.val := PExpr.sc.ival;
      item.type := Syms.TypeChar; Scan.Next(PExpr.sc)

  | Scan.TString:
      item.mode := Cgen.MGlobal; item.adr := Cgen.CgDpc();
      item.type := Syms.TypeNewArray(Syms.TypeChar, LONGINT(Strings.Length(PExpr.sc.sval) + 1));
      Cgen.EmitDataString(PExpr.sc.sval); Scan.Next(PExpr.sc)

  | Scan.TTrue:
      item.mode := Cgen.MConst; item.val := 1; item.type := Syms.TypeBoolean; Scan.Next(PExpr.sc)

  | Scan.TFalse:
      item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeBoolean; Scan.Next(PExpr.sc)

  | Scan.TNil:
      item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeNiltype; Scan.Next(PExpr.sc)

  | Scan.TLbrace:
      (* SET literal *)
      Scan.Next(PExpr.sc);
      Cgen.EmitCodeStr("33,C0,50");   (* XOR AX,AX; PUSH AX *)
      WHILE PExpr.sc.sym # Scan.TRbrace DO
        IsLex(Scan.TComma);
        PExpr.ParseExpression(lo); Cgen.CgLoadItem(lo);
        IF IsLex(Scan.TDotdot) THEN
          Cgen.Emit1(BYTE(Cgen.OpPushAx));
          PExpr.ParseExpression(hi); Cgen.CgLoadItem(hi);
          Cgen.Emit2(089H, 0C2H);
          Cgen.Emit1(BYTE(Cgen.OpPopBx));
          Cgen.Emit2(03BH, 0DAH);
          Cgen.CgCondNear(Cgen.OpJg, skip2);
          loopTop := Cgen.CgPc();
          Cgen.Emit2(08AH, 0CBH);
          Cgen.Emit1(0B8H); Cgen.EmitW(0001H);
          Cgen.CgShlCl();
          Cgen.Emit1(BYTE(Cgen.OpPopCx)); Cgen.CgOr(); Cgen.Emit1(BYTE(Cgen.OpPushAx));
          Cgen.Emit1(043H);
          Cgen.Emit2(03BH, 0DAH);
          Cgen.CgCondBack(Cgen.OpJle, loopTop);
          Cgen.CgPatchNear(skip2)
        ELSE
          Cgen.Emit2(08AH, 0C8H);
          Cgen.Emit1(0B8H); Cgen.EmitW(0001H);
          Cgen.CgShlCl();
          Cgen.Emit1(BYTE(Cgen.OpPopCx)); Cgen.CgOr(); Cgen.Emit1(BYTE(Cgen.OpPushAx))
        END
      END;
      PExpr.Expect(Scan.TRbrace);
      Cgen.Emit1(BYTE(Cgen.OpPopAx));
      item.mode := Cgen.MReg; item.type := Syms.TypeSet

  | Scan.TLparen:
      Scan.Next(PExpr.sc); PExpr.ParseExpression(item); PExpr.Expect(Scan.TRparen)

  | Scan.TNot:
      (* DOCS/CODEGEN-SIZE.MD §4.5 ("IF ~x THEN materializes the negation")
         was attempted and reverted: a standalone `~x` as the WHOLE
         condition is parsed as ParseTerm's OWN first factor, which
         ParseTerm deliberately disarms Cgen.condArmed around (see
         ParseTerm's own header comment — a real, previously-caught bug,
         `(a<b) & (c>d)` miscompiling, if the first factor's own internal
         fusion commits to a branch before the parser knows whether `&`
         follows).  A correct fix needs to thread the "still-pending
         negation" state through ParseTerm's own first-factor handling
         (decide fuse-vs-materialize only once it's known whether `&`/`OR`
         follows), not a self-contained change inside ParseFactor's TNot
         case alone — left as a scoped follow-up, not attempted here. *)
      Scan.Next(PExpr.sc); ParseFactor(item);
      Cgen.CgLoadItem(item); Cgen.CgBoolNot();
      item.type := Syms.TypeBoolean; item.mode := Cgen.MReg

  | Scan.TIdent:
      sym := Syms.SymFind(PExpr.sc.id);
      (* Type cast built-ins *)
      IF (sym # Syms.NoSym) & (sym.kind = Syms.KType) THEN
        form := -1;
        IF sym.type # Syms.NoType THEN form := sym.type.form END;
        IF (form = Syms.TFInteger) OR (form = Syms.TFByte) OR (form = Syms.TFLongint)
            OR (form = Syms.TFWord) OR (form = Syms.TFAddress)
            OR (form = Syms.TFReal) OR (form = Syms.TFLongreal) THEN
          Scan.Next(PExpr.sc);
          IF IsLex(Scan.TLparen) THEN
            PExpr.ParseExpression(arg);
            PExpr.Expect(Scan.TRparen);
            srcForm := Syms.TFInteger;
            IF arg.type # NIL THEN srcForm := arg.type.form END;
            (* SYSTEM.ADDRESS converts only with LONGINT.  Casting an ADDRESS to
               a 2-byte INTEGER/WORD/BYTE would silently drop the segment — reject
               it (LONGINT(addr) is the supported widening). *)
            IF (srcForm = Syms.TFAddress) &
               ((form = Syms.TFInteger) OR (form = Syms.TFWord) OR (form = Syms.TFByte)) THEN
              PExpr.Error("ADDRESS converts only to LONGINT")
            END;
            CASE form OF
              Syms.TFInteger:
                IF (arg.mode = Cgen.MConst) & (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN
                  item.mode := Cgen.MConst;
                  item.val := SYSTEM.AND(arg.val, 0FFFFH);
                  (* LONGINT() casts: bare 08000H/010000H in a LONGINT
                     comparison/subtraction are generation-sensitive (see
                     the TInt threshold comment above). *)
                  IF item.val >= LONGINT(08000H) THEN
                    item.val := item.val - LONGINT(010000H)
                  END;
                  item.type := Syms.TypeInteger
                ELSE
                  Cgen.CgLoadItem(arg);
                  IF (srcForm = Syms.TFReal) OR (srcForm = Syms.TFLongreal) THEN Cgen.CgFistAx() END;
                  item.type := Syms.TypeInteger; item.mode := Cgen.MReg
                END
            | Syms.TFByte:
                IF (arg.mode = Cgen.MConst) & (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN
                  item.mode := Cgen.MConst; item.val := SYSTEM.AND(arg.val, 0FFH);
                  item.type := Syms.TypeByte
                ELSE
                  Cgen.CgLoadItem(arg);
                  IF (srcForm = Syms.TFReal) OR (srcForm = Syms.TFLongreal) THEN Cgen.CgFistAx() END;
                  Cgen.Emit2(025H, 0FFH); Cgen.Emit1(000H);
                  item.type := Syms.TypeByte; item.mode := Cgen.MReg
                END
            | Syms.TFWord:
                IF (arg.mode = Cgen.MConst) & (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN
                  item.mode := Cgen.MConst;
                  item.val := SYSTEM.AND(arg.val, 0FFFFH);
                  item.type := Syms.TypeWord
                ELSE
                  Cgen.CgLoadItem(arg);
                  IF (srcForm = Syms.TFReal) OR (srcForm = Syms.TFLongreal) THEN Cgen.CgFistAx() END;
                  item.type := Syms.TypeWord; item.mode := Cgen.MReg
                END
            | Syms.TFLongint:
                IF (arg.mode = Cgen.MConst) & (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN
                  item.mode := Cgen.MConst; item.val := arg.val;
                  item.type := Syms.TypeLongint
                ELSE
                  Cgen.CgLoadItem(arg);
                  IF (srcForm = Syms.TFReal) OR (srcForm = Syms.TFLongreal) THEN
                    (* SUB SP,4/MOV BX,SP/store AX,DX/FISTP qword[BX]/reload AX,DX/ADD SP,4 *)
                    Cgen.EmitCodeStr("83,EC,04,89,E3,36,89,07,36,89,57,02,36,DB,07,36,8B,07,36,8B,57,02,83,C4,04")
                  ELSIF (srcForm = Syms.TFWord) OR (srcForm = Syms.TFByte)
                      OR (srcForm = Syms.TFChar) OR (srcForm = Syms.TFBoolean) THEN
                    Cgen.CgZeroDx()   (* XOR DX,DX — zero-extend unsigned source *)
                  ELSIF (srcForm = Syms.TFAddress) OR (srcForm = Syms.TFPointer)
                      OR (srcForm = Syms.TFProc) THEN
                    (* already a 4-byte far value in DX:AX — no extension *)
                  ELSIF srcForm # Syms.TFLongint THEN Cgen.CgCwd()  (* CWD — sign-extend INTEGER *)
                  END;
                  item.type := Syms.TypeLongint; item.mode := Cgen.MReg
                END
            | Syms.TFAddress:
                (* SYSTEM.ADDRESS(x): reinterpret x as a 4-byte far address in
                   DX:AX (DX=segment, AX=offset).  Only a 4-byte source is
                   allowed — LONGINT (the documented conversion), or another
                   ADDRESS / POINTER / far PROC (already DX:AX, no change).
                   INTEGER/WORD/BYTE/CHAR are 2-byte and rejected (no segment). *)
                Cgen.CgLoadItem(arg);
                IF (srcForm = Syms.TFLongint) OR (srcForm = Syms.TFAddress)
                    OR (srcForm = Syms.TFPointer) OR (srcForm = Syms.TFProc) THEN
                  (* already 4-byte DX:AX *)
                ELSE
                  PExpr.Error("ADDRESS() accepts only LONGINT (or pointer/address)")
                END;
                item.type := Syms.TypeAddress; item.mode := Cgen.MReg
            | Syms.TFReal:
                Cgen.CgLoadItem(arg);
                IF srcForm = Syms.TFLongint THEN PExpr.CoerceDxaxToFpu()
                ELSIF srcForm # Syms.TFReal THEN PExpr.CoerceAxToFpu()
                END;
                PExpr.modUsesFpu := TRUE; item.type := Syms.TypeReal; item.mode := Cgen.MFreg
            | Syms.TFLongreal:
                Cgen.CgLoadItem(arg);
                IF srcForm = Syms.TFLongint THEN PExpr.CoerceDxaxToFpu()
                ELSIF (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN PExpr.CoerceAxToFpu()
                END;
                PExpr.modUsesFpu := TRUE; item.type := Syms.TypeLongreal; item.mode := Cgen.MFreg
            ELSE Cgen.CgLoadItem(arg); PExpr.Error("unsupported type cast"); item.type := Syms.TypeInteger; item.mode := Cgen.MReg
            END;
            RETURN
          END;
          PExpr.Error("type name not valid in expression");
          item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeInteger; RETURN
        END
      END;
      (* Built-in sys procs as expressions *)
      IF (sym # Syms.NoSym) & (sym.kind = Syms.KSysProc) THEN
        id := sym.sysId; Scan.Next(PExpr.sc);
        PExpr.Expect(Scan.TLparen);
        IF id = Syms.SpSize THEN
          (* SIZE(T): compile-time byte size of type T as a WORD constant.
             Accepts a (possibly qualified) type name.  No inline ARRAY/
             RECORD type expressions — users should declare a named type. *)
          PExpr.ParseSizeArg(item);
          PExpr.Expect(Scan.TRparen); RETURN
        END;
        IF id = Syms.SpLen THEN
          PExpr.ParseExpression(arg); PExpr.Expect(Scan.TRparen);
          IF Syms.IsForm(arg.type, Syms.TFArray) &
             (arg.type.len >= 0) THEN
            (* Fixed-size array: LEN is a compile-time WORD constant.  Usable
               in CONST decls, ARRAY dimensions, and CASE labels. *)
            item.mode := Cgen.MConst;
            item.val  := arg.type.len;
            item.type := Syms.TypeWord; RETURN
          END;
          IF Syms.IsForm(arg.type, Syms.TFArray) &
             (arg.mode = Cgen.MLocal) THEN
            Cgen.CgLoadBp(arg.adr + 4)
          ELSE Cgen.CgLoadImm(0) END;
          item.type := Syms.TypeWord; item.mode := Cgen.MReg; RETURN
        END;
        PExpr.ParseExpression(arg); Cgen.CgLoadItem(arg); PExpr.Expect(Scan.TRparen);
        CASE id OF
          Syms.SpOdd:
            Cgen.Emit2(083H, 0E0H); Cgen.Emit1(001H);
            item.type := Syms.TypeBoolean
        | Syms.SpAbs:
            Cgen.CgTestAx();
            Cgen.CgCondShort(079H, skipBp);  (* JNS — skip NEG *)
            Cgen.CgNeg();
            Cgen.CgPatchShort(skipBp);
            item.type := Syms.TypeInteger
        | Syms.SpOrd:  item.type := Syms.TypeInteger
        | Syms.SpChr:  item.type := Syms.TypeChar
        | Syms.SpFloor:
            IF (arg.type # Syms.NoType) & ((arg.type.form = Syms.TFReal) OR (arg.type.form = Syms.TFLongreal)) THEN
              Cgen.CgFloorAx()
            END;
            item.type := Syms.TypeInteger
        ELSE PExpr.Error("built-in not usable as expression"); item.type := Syms.TypeInteger
        END;
        item.mode := Cgen.MReg; RETURN
      END;
      (* General designator *)
      ParseDesignator(item);
      PExpr.MarkRead(item);

      IF (item.mode = Cgen.MSysProc) & (PExpr.sc.sym = Scan.TLparen) THEN
        ParseSystemIntrinsic(item, INTEGER(item.val))
      ELSIF Syms.IsForm(item.type, Syms.TFProc) &
            ((item.mode = Cgen.MLocal) OR (item.mode = Cgen.MGlobal) OR
             ((item.mode = Cgen.MReg) & item.isRef)) & (PExpr.sc.sym = Scan.TLparen) THEN
        pt := item.type; varAdr := item.adr;
        varGlobal := (item.mode = Cgen.MGlobal); varRef := (item.mode = Cgen.MReg) & item.isRef;
        IF varRef THEN
          (* §4.1 near array/record elements (item.nearBase) hold only an
             offset in BX -- no ES was ever loaded.  Materialize the correct
             implicit segment (DS/SS, from rootSym.level) into ES first, so
             the "PUSH BX; PUSH ES (save slot addr)" below always saves a
             genuine far {ofs,seg} pair either way. *)
          IF item.nearBase THEN Cgen.CgEsFromMode(PExpr.NearRootMode(item)) END;
          Cgen.EmitCodeStr("53,06");  (* PUSH BX; PUSH ES (save slot addr) *)
          ParseActualParameters(pt);
          Cgen.CgCallProcVarRefTail(pt.lenOrDescOrArg)
        ELSE
          ParseActualParameters(pt);
          (* Proc-typed VARs are always FAR (see PARSER.MOD ParseType). *)
          IF varGlobal THEN Cgen.CgCallProcVarMem(WORD(varAdr))
          ELSE Cgen.CgCallProcVarBp(varAdr) END
        END;
        item.type := pt.elemOrRet; item.isRef := FALSE; item.nearBase := FALSE;
        IF (pt.elemOrRet # Syms.NoType) & ((pt.elemOrRet.form = Syms.TFReal) OR (pt.elemOrRet.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE item.mode := Cgen.MReg END
      ELSIF (item.mode = Cgen.MProc) & (item.type # Syms.NoType) & item.type.isInline & (PExpr.sc.sym = Scan.TLparen) THEN
        pt2 := item.type;
        EmitInlineCall(pt2);
        item.type := pt2.elemOrRet;
        IF item.type = Syms.NoType THEN item.type := Syms.TypeInteger END;
        (* Result lives in ST(0) when ret type is REAL/LONGREAL, AX otherwise. *)
        IF (item.type # Syms.NoType) & ((item.type.form = Syms.TFReal) OR (item.type.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE
          item.mode := Cgen.MReg
        END
      ELSIF ((item.mode = Cgen.MProc) OR (item.mode = Cgen.MImport)) & (PExpr.sc.sym = Scan.TLparen) THEN
        rdId := item.rdoffId; codeOfs := item.adr;
        isImp := (item.mode = Cgen.MImport); isFr := item.isFar;
        pt2 := item.type;
        IF pt2 = NIL THEN pt2 := Syms.TypeNewProc(Syms.TypeNotype) END;
        ParseActualParameters(pt2);
        (* DOCS/OVR.MD §9: an imported far call made from
           inside $O+ code MIGHT be rewritten by the linker into an overlay
           trampoline whose call site later needs a return-address resume
           trampoline installed right after it (Link.AddOvrReturnTrampoline)
           -- reserve the 5 spare bytes now, since codegen doesn't yet know
           whether this call's target will resolve to an overlay unit. *)
        IF isImp & isFr & PExpr.overlayMode & ~PExpr.targetCP THEN Cgen.CgCallFarOvr(rdId)
        ELSIF isImp & isFr THEN Cgen.CgCallFar(rdId)
        ELSIF isImp THEN Cgen.CgCallNear(rdId)
        ELSIF item.fwdSym # Syms.NoSym THEN FwdEmitCall(item.fwdSym, isFr)
        ELSIF isFr THEN Cgen.CgCallLocalFar(codeOfs)
        ELSE Cgen.CgCallLocal(codeOfs)
        END;
        item.type := pt2.elemOrRet;
        IF (pt2.elemOrRet # Syms.NoType) & ((pt2.elemOrRet.form = Syms.TFReal) OR (pt2.elemOrRet.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE item.mode := Cgen.MReg END
      END
  ELSE
    PExpr.Error("factor expected"); item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeInteger
  END
END ParseFactor;

END PExpr2.
