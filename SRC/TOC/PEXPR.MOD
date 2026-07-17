(*D-*)
MODULE PExpr;
IMPORT Scan, Syms, Cgen, Rdoff, Strings, LogErr, StrTab;

VAR
  sc*:         Scan.Scanner;
  modUsesFpu*: BOOLEAN;
  boundsChk*:  BOOLEAN;
  modName*:    ARRAY 33 OF CHAR;

(* ---- error helpers ----
   All diagnostics carry the source position via LogErr.ErrorInFile
   (filename(line): message).  LogErr latches on the first error and the whole
   compile shuts down — there is no error counter any more; callers test
   LogErr.HaveErr(). *)

PROCEDURE Error*(msg: ARRAY OF CHAR);
BEGIN
  LogErr.ErrorInFile(sc.filename, LONGINT(sc.line), msg)
END Error;

PROCEDURE Error2*(msg, name: ARRAY OF CHAR);
  VAR buf: ARRAY 128 OF CHAR;
BEGIN
  Strings.Copy(msg, buf); Strings.Append(" '", buf);
  Strings.Append(name, buf); Strings.Append("'", buf);
  Error(buf)
END Error2;

PROCEDURE Expect*(t: INTEGER);
  VAR buf: ARRAY 64 OF CHAR; num: ARRAY 16 OF CHAR;
BEGIN
  IF sc.sym = t THEN Scan.Next(sc)
  ELSE
    Strings.Copy("syntax error: expected ", buf);
    Strings.Str(LONGINT(t), num); Strings.Append(num, buf);
    Strings.Append(" got ", buf);
    Strings.Str(LONGINT(sc.sym), num); Strings.Append(num, buf);
    Error(buf)
  END
END Expect;

(* ---- system import helper ---- *)

PROCEDURE GetSystemImport*(name: ARRAY OF CHAR): INTEGER;
  VAR id: INTEGER;
BEGIN
  id := Rdoff.RdfFindImport(Cgen.CgObj, name);
  IF id < 0 THEN id := Rdoff.RdfAddImport(Cgen.CgObj, name) END;
  RETURN id
END GetSystemImport;

PROCEDURE MarkRead*(VAR item: Cgen.Item);
BEGIN
  IF item.rootSym # Syms.NoSym THEN
    IF item.rootSym.readCount < WORD(0FFFFH) THEN INC(item.rootSym.readCount) END
  END
END MarkRead;

(* ---- forward declarations ---- *)
PROCEDURE ParseExpression*(VAR item: Cgen.Item); FORWARD;
PROCEDURE ParseDesignator*(VAR item: Cgen.Item); FORWARD;

(* ---- type helpers ---- *)

PROCEDURE IsIntConst(VAR item: Cgen.Item): BOOLEAN;
  VAR f: INTEGER;
BEGIN
  IF (item.mode # Cgen.MConst) OR (item.type = Syms.NoType) THEN RETURN FALSE END;
  f := item.type.form;   (* read the form once *)
  RETURN (f = Syms.TFInteger) OR (f = Syms.TFLongint) OR (f = Syms.TFWord)
END IsIntConst;

(* IsPow2 — TRUE iff v is a positive power of two (1, 2, 4, 8, ...). *)
PROCEDURE IsPow2(v: LONGINT): BOOLEAN;
BEGIN
  RETURN (v > LONGINT(0)) & (SYSTEM.AND(v, v - LONGINT(1)) = LONGINT(0))
END IsPow2;

(* Log2 — exponent n for a known positive power of two v (= 2^n). *)
PROCEDURE Log2(v: LONGINT): INTEGER;
  VAR n: INTEGER;
BEGIN
  n := 0;
  WHILE v > LONGINT(1) DO v := SYSTEM.LSR(v, 1); INC(n) END;
  RETURN n
END Log2;

PROCEDURE IsIntType(VAR it: Cgen.Item): BOOLEAN;
  VAR f: INTEGER;
BEGIN
  IF it.type = NIL THEN RETURN FALSE END;
  f := it.type.form;
  RETURN (f = Syms.TFInteger) OR (f = Syms.TFByte) OR
         (f = Syms.TFLongint) OR (f = Syms.TFWord)
END IsIntType;

PROCEDURE IsFpuType(VAR it: Cgen.Item): BOOLEAN;
  VAR f: INTEGER;
BEGIN
  IF it.type = NIL THEN RETURN FALSE END;
  f := it.type.form;
  RETURN (f = Syms.TFReal) OR (f = Syms.TFLongreal)
END IsFpuType;

(* ParseSizeArg — resolve a (possibly qualified) type name to its byte size
   and emit it as a WORD constant Item.  Called by SIZE() handling.  Does
   not call Parser.ParseType because Parser depends on PExpr; instead
   we inline the small "ident [. ident]" parser sufficient for type names. *)
PROCEDURE ParseSizeArg(VAR item: Cgen.Item);
  VAR sym, tsym: Syms.Symbol;
      tkey: ARRAY 66 OF CHAR;
BEGIN
  item.mode := Cgen.MConst;
  item.type := Syms.TypeWord;
  item.val  := 0;
  IF sc.sym # Scan.TIdent THEN Error("type name expected in SIZE"); RETURN END;
  sym := Syms.SymFind(sc.id);
  Scan.Next(sc);
  IF (sym # Syms.NoSym) & (sym.kind = Syms.KImport) & (sc.sym = Scan.TDot) THEN
    Scan.Next(sc);
    IF sc.sym # Scan.TIdent THEN Error("type name expected after '.'"); RETURN END;
    (* build "Alias.Name" *)
    StrTab.Get(sym.nameId, tkey); Strings.Append(".", tkey);
    Strings.Append(sc.id, tkey);
    tsym := Syms.SymFind(tkey);
    IF tsym = Syms.NoSym THEN tsym := Syms.SymFind(sc.id) END;
    Scan.Next(sc);
    sym := tsym
  END;
  IF (sym = Syms.NoSym) OR (sym.kind # Syms.KType) OR (sym.type = Syms.NoType) THEN
    Error("type name expected in SIZE"); RETURN
  END;
  item.val := sym.type.size
END ParseSizeArg;

(* ---- const folding ---- *)

(* The host compiler's own LONGINT DIV/MOD (via SYSTEM_S32DIV/S32MOD in
   SYSTEM.ASM) are already floored per Oberon-07 semantics, so no fixup is
   needed here -- applying one would double-correct (see the DEC(q)/INC(r)
   history this replaced: it corrected a truncating DIV/MOD that no longer
   exists). *)
PROCEDURE ConstDiv(a, b: LONGINT): LONGINT;
BEGIN
  RETURN a DIV b
END ConstDiv;

PROCEDURE ConstMod(a, b: LONGINT): LONGINT;
BEGIN
  RETURN a MOD b
END ConstMod;

PROCEDURE ConstFoldInt(VAR item: Cgen.Item; op: INTEGER; VAR rhs: Cgen.Item);
  VAR isLong, isWord: BOOLEAN; a, b: LONGINT; ua, ub: LONGINT; itf, rhf: INTEGER;
BEGIN
  itf := item.type.form; rhf := rhs.type.form;   (* read once *)
  isLong := (itf = Syms.TFLongint) OR (rhf = Syms.TFLongint);
  isWord := ~isLong & ((itf = Syms.TFWord) OR (rhf = Syms.TFWord));
  a := item.val; b := rhs.val;
  IF isWord THEN
    ua := SYSTEM.AND(a, 0FFFFH); ub := SYSTEM.AND(b, 0FFFFH);
    CASE op OF
      Scan.TPlus:  item.val := SYSTEM.AND(ua + ub, 0FFFFH)
    | Scan.TMinus: item.val := SYSTEM.AND(ua - ub, 0FFFFH)
    | Scan.TStar:  item.val := SYSTEM.AND(ua * ub, 0FFFFH)
    | Scan.TDiv:
        IF ub # 0 THEN item.val := ua DIV ub
        ELSE Error("division by zero"); item.val := 0 END
    | Scan.TMod:
        IF ub # 0 THEN item.val := ua MOD ub
        ELSE Error("division by zero"); item.val := 0 END
    ELSE RETURN
    END;
    item.type := Syms.TypeWord; item.mode := Cgen.MConst; RETURN
  END;
  CASE op OF
    Scan.TPlus:  item.val := a + b
  | Scan.TMinus: item.val := a - b
  | Scan.TStar:  item.val := a * b
  | Scan.TDiv:
      IF b # 0 THEN item.val := ConstDiv(a, b)
      ELSE Error("division by zero"); item.val := 0 END
  | Scan.TMod:
      IF b # 0 THEN item.val := ConstMod(a, b)
      ELSE Error("division by zero"); item.val := 0 END
  ELSE RETURN
  END;
  IF isLong THEN item.type := Syms.TypeLongint ELSE item.type := Syms.TypeInteger END;
  item.mode := Cgen.MConst
END ConstFoldInt;

(* CanShiftAddMul — TRUE if a 16-bit multiply by m is worth doing with the
   shift+add/sub scheme (opt.md D): small m (3..64) that is either 2^a-1 or has
   exactly two set bits.  Powers of two are excluded (handled by SHL). *)
PROCEDURE CanShiftAddMul(m: LONGINT): BOOLEAN;
  VAR v: INTEGER;
BEGIN
  IF (m < LONGINT(3)) OR (m > LONGINT(64)) OR IsPow2(m) THEN RETURN FALSE END;
  v := INTEGER(m);
  RETURN (Cgen.PopCount16(v + 1) = 1) OR (Cgen.PopCount16(v) = 2)
END CanShiftAddMul;

(* StrengthReducible — TRUE if `op` by this constant can be turned into a
   shift/AND/add/identity instead of IMUL/IDIV.  For `*` (only) this also
   accepts the shift+add multipliers (opt.md D) when the result is 16-bit. *)
PROCEDURE StrengthReducible(op: INTEGER; cval: LONGINT; isLong: BOOLEAN): BOOLEAN;
BEGIN
  IF (cval = LONGINT(0)) OR (cval = LONGINT(1)) OR IsPow2(cval) THEN RETURN TRUE END;
  RETURN (op = Scan.TStar) & ~isLong & CanShiftAddMul(cval)
END StrengthReducible;

(* StrengthReduce — the variable operand is already loaded (AX, or DX:AX for
   LONGINT).  `cval` is the constant operand's value, `op` the operator,
   `isLong`/`isWord` the result-type flags.  Emits the optimized instruction
   sequence and returns TRUE if it handled the case; FALSE means the caller
   must fall back to the generic multiply/divide path.

   Multiply: cval may be on either side (commutative) — handled by caller.
   Divide / Modulo: cval is the divisor (right operand only) — caller ensures.

   Powers of two:
     x * 2^n  -> SHL  (CgShlImm / CgLsl32Imm)
     x DIV 2^n-> SAR (signed) / SHR (WORD)   -- floored division == SAR on 8086
     x MOD 2^n-> AND mask                      -- low n bits == Oberon MOD
   Identities:
     x * 1 -> nothing ;  x * 0 -> 0
     x DIV 1 -> nothing ;  x MOD 1 -> 0 *)
PROCEDURE StrengthReduce(op: INTEGER; cval: LONGINT; isLong, isWord: BOOLEAN): BOOLEAN;
  VAR n: INTEGER;
BEGIN
  IF op = Scan.TStar THEN
    IF cval = LONGINT(1) THEN RETURN TRUE END;          (* x*1 = x, AX already holds x *)
    IF cval = LONGINT(0) THEN                            (* x*0 = 0 *)
      Cgen.Emit2(033H, 0C0H);                            (* XOR AX,AX *)
      IF isLong THEN Cgen.Emit2(033H, 0D2H) END;         (* XOR DX,DX *)
      RETURN TRUE
    END;
    IF IsPow2(cval) THEN
      n := Log2(cval);
      IF isLong THEN Cgen.CgLsl32Imm(n) ELSE Cgen.CgShlImm(n) END;
      RETURN TRUE
    END;
    (* opt.md D: small non-power-of-two multiplier via shift+add/sub (16-bit). *)
    IF ~isLong & CanShiftAddMul(cval) THEN
      RETURN Cgen.CgMulConst16(INTEGER(cval))
    END
  ELSIF op = Scan.TDiv THEN
    IF cval = LONGINT(1) THEN RETURN TRUE END;           (* x DIV 1 = x *)
    IF IsPow2(cval) THEN
      n := Log2(cval);
      IF isLong THEN
        IF isWord THEN Cgen.CgLsr32Imm(n) ELSE Cgen.CgAsr32Imm(n) END
      ELSIF isWord THEN Cgen.CgShrImm(n)
      ELSE Cgen.CgSarImm(n)
      END;
      RETURN TRUE
    END
  ELSIF op = Scan.TMod THEN
    IF cval = LONGINT(1) THEN                            (* x MOD 1 = 0 *)
      Cgen.Emit2(033H, 0C0H);
      IF isLong THEN Cgen.Emit2(033H, 0D2H) END;
      RETURN TRUE
    END;
    IF IsPow2(cval) THEN
      IF isLong THEN Cgen.CgAndImm32(cval - LONGINT(1))
      ELSE Cgen.CgAndImm16(INTEGER(SYSTEM.AND(cval - LONGINT(1), LONGINT(0FFFFH))))
      END;
      RETURN TRUE
    END
  END;
  RETURN FALSE
END StrengthReduce;

(* ---- FPU coerce helpers ---- *)

(* SUB SP,2 / MOV BX,SP / SS: MOV [BX],AX / SS: FILD word [BX] / ADD SP,2 *)
PROCEDURE CoerceAxToFpu;
BEGIN
  Cgen.EmitCodeStr("83,EC,02,89,E3,36,89,07,36,DF,07,83,C4,02");
  modUsesFpu := TRUE
END CoerceAxToFpu;

(* SUB SP,4 / MOV BX,SP / SS: MOV [BX],AX / SS: MOV [BX+2],DX / SS: FILD qword [BX] / ADD SP,4 *)
PROCEDURE CoerceDxaxToFpu;
BEGIN
  Cgen.EmitCodeStr("83,EC,04,89,E3,36,89,07,36,89,57,02,36,DB,07,83,C4,04");
  modUsesFpu := TRUE
END CoerceDxaxToFpu;

(* ---- bounds check ---- *)

PROCEDURE EmitBoundsCheck(len, openLenBpOfs: LONGINT);
  VAR errId: INTEGER; ok1, ok2: Cgen.Backpatch;
BEGIN
  IF ~boundsChk THEN RETURN END;
  errId := GetSystemImport("SYSTEM_ErrIndexOutOfBounds");
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
      Error2("VAR parameter requires a variable (not a literal, constant, or expression)", nbuf);
      RETURN
    END
  END;
  IF (formal.type = Syms.NoType) OR (arg.type = Syms.NoType) THEN RETURN END;
  IF formal.typeless THEN RETURN END;
  ft := formal.type; at := arg.type;
  (* .elem is NIL (= Syms.NoType) for every non-ARRAY type: it may only be
     dereferenced AFTER the form/NIL guards below.  (An earlier version read
     both elem forms up front "once" — a NIL far read through 0000:0000 on
     virtually every checked call.) *)
  (* Single-char string -> CHAR / BYTE *)
  IF (at.form = Syms.TFArray) & (at.len = 2) & (at.elem # Syms.NoType) &
     (at.elem.form = Syms.TFChar) &
     ((ft.form = Syms.TFChar) OR (ft.form = Syms.TFByte)) THEN RETURN END;
  (* String -> ARRAY OF CHAR / BYTE *)
  IF (at.form = Syms.TFArray) & (at.elem # Syms.NoType) &
     (at.elem.form = Syms.TFChar) &
     (ft.form = Syms.TFArray) & (ft.elem # Syms.NoType) &
     ((ft.elem.form = Syms.TFChar) OR (ft.elem.form = Syms.TFByte)) THEN
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
    Error2("type mismatch in actual parameter", nbuf)
  END
END CheckParamCompat;

(* Push a far pointer held in a local BP slot {ofs:2, seg:2}: segment then
   offset (Pascal l-to-r push order, segment deepest). *)
PROCEDURE PushFarSlotBp(adr: LONGINT);
BEGIN
  Cgen.CgLoadBp(adr + 2); Cgen.Emit1(BYTE(Cgen.OpPushAx));   (* PUSH segment *)
  Cgen.CgLoadBp(adr);     Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH offset *)
END PushFarSlotBp;

(* Push a far pointer held in a global data slot {ofs:2, seg:2}. *)
PROCEDURE PushFarSlotMem(adr: LONGINT);
BEGIN
  Cgen.CgLoadMem(WORD(adr + 2)); Cgen.Emit1(BYTE(Cgen.OpPushAx));  (* PUSH segment *)
  Cgen.CgLoadMem(WORD(adr));     Cgen.Emit1(BYTE(Cgen.OpPushAx))   (* PUSH offset *)
END PushFarSlotMem;

(* Push the far address currently in ES:BX (pointer deref / indexed element). *)
PROCEDURE PushFarEsBx;
BEGIN
  Cgen.Emit1(BYTE(Cgen.OpPushEs));   (* PUSH ES (segment) *)
  Cgen.Emit2(08BH, 0C3H);            (* MOV AX, BX *)
  Cgen.Emit1(BYTE(Cgen.OpPushAx))    (* PUSH AX (offset) *)
END PushFarEsBx;

PROCEDURE ParseActualParameters*(pt: Syms.TypeDesc);
  VAR arg: Cgen.Item; p: Syms.Symbol; bad: BOOLEAN;
      isOpenFormal: BOOLEAN;
      pty: Syms.TypeDesc;
BEGIN
  Expect(Scan.TLparen);
  p := pt.params; bad := FALSE;
  WHILE ~bad & (sc.sym # Scan.TRparen) & (sc.sym # Scan.TEof) DO
    IF p = Syms.NoSym THEN Error("too many parameters"); ParseExpression(arg)
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
           of a designator through ParseExpression instead, purely so the
           actual gets consumed and CheckParamCompat can give its intended
           clean rejection message. *)
        IF sc.sym = Scan.TIdent THEN ParseDesignator(arg) ELSE ParseExpression(arg) END;
        MarkRead(arg);
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
            Error("cannot determine LEN of open-array actual parameter");
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
        ParseExpression(arg);
        CheckParamCompat(p, arg);
        IF (p.type # Syms.NoType) & (pty.form = Syms.TFRecord) THEN
          (* By-value RECORD: caller copies the whole record onto the stack,
             rounded up to an even byte count (2-byte aligned).  The callee reads
             it in place at [BP+ofs]; argSize reserves the same evenSize so the
             post-call SP cleanup balances.  See Cgen.CgPushAggrValue. *)
          Cgen.CgLoadFarAddrEsBx(arg.mode, arg.adr, arg.isRef);
          Cgen.CgPushAggrValue(INTEGER((pty.size + LONGINT(1)) DIV LONGINT(2) * LONGINT(2)))
        ELSIF (p.type # Syms.NoType) & (pty.form = Syms.TFArray) & (pty.len >= 0) THEN
          (* By-value FIXED array: same caller-copy as a value record (the formal
             is a fixed-size array, not an open array). *)
          Cgen.CgLoadFarAddrEsBx(arg.mode, arg.adr, arg.isRef);
          Cgen.CgPushAggrValue(INTEGER((pty.size + LONGINT(1)) DIV LONGINT(2) * LONGINT(2)))
        ELSIF (arg.type # Syms.NoType) & (arg.type.form = Syms.TFArray) &
            (p.type # Syms.NoType) &
            ((pty.form = Syms.TFChar) OR (pty.form = Syms.TFByte)) THEN
          (* Single-char string "X" passed to CHAR/BYTE formal *)
          IF arg.mode = Cgen.MGlobal THEN Cgen.CgLoadMem(WORD(arg.adr))
          ELSE Cgen.CgLoadItem(arg)
          END;
          Cgen.Emit3(025H, 0FFH, 000H);        (* AND AX, 00FFh *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx))
        ELSIF (arg.type # Syms.NoType) & (arg.type.form = Syms.TFArray) THEN
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
            Error("cannot determine LEN of open-array actual parameter");
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
          ELSIF (arg.mode = Cgen.MLocal) & (arg.type.len >= 0) THEN
            Cgen.Emit1(BYTE(Cgen.OpPushSs));             (* PUSH SS *)
            Cgen.CgLoadAddrBp(arg.adr);
            Cgen.Emit1(BYTE(Cgen.OpPushAx))             (* PUSH offset *)
          ELSIF arg.mode = Cgen.MLocal THEN
            (* open-array formal forwarded: far ptr at [BP+adr] *)
            PushFarSlotBp(arg.adr)
          ELSIF (arg.mode = Cgen.MReg) & arg.isRef THEN
            (* ES:BX already holds far address (record field, indexed elem) *)
            PushFarEsBx
          ELSE
            Cgen.CgLoadItem(arg);
            Cgen.Emit1(BYTE(Cgen.OpPushDx));            (* PUSH DX (segment) *)
            Cgen.Emit1(BYTE(Cgen.OpPushAx))             (* PUSH AX (offset) *)
          END
        ELSIF (arg.type # Syms.NoType) & (arg.type.form = Syms.TFLongint) THEN
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
              ~IsFpuType(arg) THEN
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
              Cgen.Emit2(033H, 0D2H)  (* XOR DX,DX — zero-extend (WORD/BYTE/CHAR are unsigned) *)
            ELSE
              Cgen.Emit1(099H)        (* CWD — sign-extend INTEGER *)
            END
          END;
          Cgen.CgPushDxax()
        ELSIF IsFpuType(arg) THEN
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
          Cgen.CgLoadItem(arg);
          (* For POINTER/ADDRESS/NILTYPE/far-PROC: 4-byte far pointer arg.
             Push DX (segment) first, then AX (offset). *)
          IF (arg.type # Syms.NoType) &
             ((arg.type.form = Syms.TFPointer) OR
              (arg.type.form = Syms.TFNiltype) OR
              (arg.type.form = Syms.TFAddress) OR
              ((arg.type.form = Syms.TFProc) & arg.type.isFar)) &
             ((p.type = Syms.NoType) OR
              (pty.form = Syms.TFPointer) OR
              (pty.form = Syms.TFAddress) OR
              (pty.form = Syms.TFNiltype) OR
              ((pty.form = Syms.TFProc) & p.type.isFar)) THEN
            Cgen.Emit1(BYTE(Cgen.OpPushDx))   (* PUSH DX (segment) *)
          END;
          Cgen.Emit1(BYTE(Cgen.OpPushAx))
        END
      END;
      p := p.next
    END;
    IF sc.sym = Scan.TComma THEN Scan.Next(sc)
    ELSIF sc.sym # Scan.TRparen THEN
      (* Malformed list: after an argument the next token must be ',' or ')'.
         Anything else (e.g. a missing ')' that lets a statement terminator leak
         in) would make the loop spin without consuming a token — stop here. *)
      bad := TRUE
    END
  END;
  IF bad THEN Error("syntax error") ELSE Expect(Scan.TRparen) END;
  IF p # NIL THEN Error("too few parameters") END
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
    nArgs := 0; f := pt.params;
    Expect(Scan.TLparen);
    WHILE (sc.sym # Scan.TRparen) & (sc.sym # Scan.TEof) DO
      ParseDesignator(arg);
      MarkRead(arg);
      IF nArgs < 32 THEN
        argAdr[nArgs] := arg.adr; argGlobal[nArgs] := (arg.mode = Cgen.MGlobal)
      ELSE
        Error("too many INLINE call arguments (max 32)")
      END;
      INC(nArgs);
      IF f # Syms.NoSym THEN f := f.next END;
      IF sc.sym = Scan.TComma THEN Scan.Next(sc) END
    END;
    Expect(Scan.TRparen);
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
    IF (pt.nParams > 0) OR (sc.sym = Scan.TLparen) THEN ParseActualParameters(pt) END;
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
  Expect(Scan.TLparen);
  CASE id OF
    Syms.SpLsl, Syms.SpLsr, Syms.SpAsr, Syms.SpRor:
      ParseExpression(xItem);
      isLong := 0; isWord := 0;
      ClassLongWord(xItem.type, isLong, isWord);
      Cgen.CgLoadItem(xItem);
      IF isLong = 1 THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
      Expect(Scan.TComma);
      ParseExpression(arg);
      nConst := (arg.mode = Cgen.MConst);
      nVal := INTEGER(arg.val MOD 32);
      Cgen.CgLoadItem(arg);
      IF nConst THEN
        nVal := nVal MOD 32;
        IF isLong = 1 THEN
          Cgen.EmitCodeStr("58,5A");  (* POP AX; POP DX *)
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
              Cgen.Emit2(033H, 0C0H)
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
          Cgen.EmitCodeStr("58,5A");  (* POP AX; POP DX *)
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
      ParseExpression(xItem);
      isLong := 0; isWord := 0;
      ClassLongWord(xItem.type, isLong, isWord);
      Cgen.CgLoadItem(xItem);
      IF isLong = 1 THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
      Expect(Scan.TComma);
      ParseExpression(arg);
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
    Error("SYSTEM intrinsic not usable as expression");
    item.type := Syms.TypeInteger; item.mode := Cgen.MConst; item.val := 0
  END;
  Expect(Scan.TRparen)
END ParseSystemIntrinsic;

(* ---- designator ---- *)

PROCEDURE ParseDesignator;
  VAR sym, sym2, fld: Syms.Symbol;
      qname: ARRAY 66 OF CHAR;
      impName: ARRAY 66 OF CHAR;
      index: Cgen.Item;
      elem: Syms.TypeDesc;
      ts: Syms.Scope;
      more, wasConst: BOOLEAN;
BEGIN
  IF sc.sym # Scan.TIdent THEN Error("identifier expected"); RETURN END;
  sym := Syms.SymFind(sc.id);
  IF sym = Syms.NoSym THEN Error2("undefined identifier", sc.id); Scan.Next(sc); RETURN END;
  Scan.Next(sc);

  item.type := sym.type; item.isRef := FALSE; item.isFar := FALSE;
  item.typeless := FALSE; item.addrDeref := FALSE;
  item.rdoffId := sym.rdoffId; item.fwdSym := Syms.NoSym;
  item.rootSym := sym;

  ts := Syms.TopScope;
  (* Visibility rule: a procedure can read/write only module-level (global)
     variables, imported names, and its OWN locals and parameters.  Reading
     a variable or parameter declared in an enclosing procedure is illegal. *)
  IF ((sym.kind = Syms.KVar) OR (sym.kind = Syms.KParam)
      OR (sym.kind = Syms.KVarParam))
     & (sym.level > 0) & (sym.level < ts^.level) THEN
    Error("uplevel access not allowed (variable belongs to enclosing procedure)")
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
      item.mode := Cgen.MProc; item.adr := sym.codeOfs;
      item.isFar := (sym.type # Syms.NoType) & sym.type.isFar;
      IF sym.rdoffId # -1 THEN item.mode := Cgen.MImport END;
      IF sym.fwdDecl THEN item.fwdSym := sym END
  | Syms.KSysProc:
      item.mode := Cgen.MSysProc; item.val := LONGINT(sym.sysId)
  | Syms.KImport:
      item.mode := Cgen.MImport; item.adr := 0; item.rdoffId := -1
  ELSE
    Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
  END;

  WHILE (sc.sym = Scan.TDot) OR (sc.sym = Scan.TLbrak) OR (sc.sym = Scan.TArrow) DO
    IF sc.sym = Scan.TDot THEN
      Scan.Next(sc);
      IF sc.sym # Scan.TIdent THEN Error("identifier expected after '.'"); RETURN END;
      IF sym.kind = Syms.KImport THEN
        StrTab.Get(sym.nameId, qname); Strings.Append(".", qname); Strings.Append(sc.id, qname);
        (* Linker-visible import name uses underscore, not dot.
           full_name = "<real_mod>_<short>" — modId when set, else
           the alias's own name. *)
        IF sym.modId # 0 THEN StrTab.Get(sym.modId, impName)
        ELSE StrTab.Get(sym.nameId, impName) END;
        Strings.Append("_", impName); Strings.Append(sc.id, impName);
        sym2 := Syms.SymFind(qname);
        IF sym2 = Syms.NoSym THEN sym2 := Syms.SymFind(sc.id) END;
        IF sym2 = Syms.NoSym THEN Error2("undefined in module", sc.id); Scan.Next(sc); RETURN END;
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
                sym2.rdoffId := GetSystemImport(impName);
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
              (* cross-module proc: allocate RDOFF import entry now
                 (modId holds the full link name for imported procs) *)
              StrTab.Get(sym2.modId, impName);
              item.rdoffId := GetSystemImport(impName);
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
            IF (item.type # Syms.NoType) & (item.type.form = Syms.TFAddress) THEN
              Scan.Next(sc);   (* consume ADDRESS *)
              IF sc.sym # Scan.TLparen THEN
                Error("ADDRESS cast requires (expr)"); item.mode := Cgen.MConst; item.val := 0;
                item.type := Syms.TypeAddress; RETURN
              END;
              Scan.Next(sc); ParseExpression(index); Expect(Scan.TRparen);
              Cgen.CgLoadItem(index);
              IF (index.type # Syms.NoType) &
                 ((index.type.form = Syms.TFLongint) OR
                  (index.type.form = Syms.TFAddress) OR
                  (index.type.form = Syms.TFPointer) OR
                  (index.type.form = Syms.TFProc)) THEN
                (* already 4-byte DX:AX *)
              ELSE
                Error("ADDRESS() accepts only LONGINT (or pointer/address)")
              END;
              item.mode := Cgen.MReg; item.type := Syms.TypeAddress;
              item.isRef := FALSE; item.addrDeref := FALSE; RETURN
            ELSE
              Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
            END
        ELSE
          Error("variable or constant expected"); item.mode := Cgen.MConst; item.val := 0
        END;
        sym := sym2
      ELSE
        (* Auto-dereference: a field selector "." applied to a POINTER-to-record
           implicitly dereferences it (Oberon-07 p.f == p^.f).  Emit the same
           far-ptr load as T_ARROW, then access the field of the base record. *)
        IF (item.type # Syms.NoType) & (item.type.form = Syms.TFPointer) THEN
          IF (item.mode = Cgen.MLocal) & ~item.isRef THEN
            Cgen.CgLesBxBp(item.adr)
          ELSIF (item.mode = Cgen.MGlobal) & ~item.isRef THEN
            Cgen.CgLesBxMem(WORD(item.adr))
          ELSE
            Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
          END;
          item.mode := Cgen.MReg; item.isRef := TRUE;
          item.type := item.type.base; item.adr := 0
        END;
        IF (item.type = Syms.NoType) OR (item.type.form # Syms.TFRecord) THEN
          Error("not a record"); Scan.Next(sc); RETURN
        END;
        fld := Syms.SymFindField(item.type, sc.id);
        IF fld = Syms.NoSym THEN Error2("undefined field", sc.id); Scan.Next(sc); RETURN END;
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
          Cgen.CgAddBxImm(INTEGER(fld.offset));
          item.mode := Cgen.MReg
          (* isRef stays TRUE *)
        ELSE
          INC(item.adr, fld.offset)
        END
      END;
      Scan.Next(sc)
    ELSIF sc.sym = Scan.TLbrak THEN
      more := TRUE;
      WHILE more DO
        Scan.Next(sc);
        (* SYSTEM.ADDRESS deref byte indexing: `p^[i]` where p: ADDRESS.  The
           preceding `^` left a CHAR ref in ES:BX (mode=MReg, isRef, type CHAR).
           Index it as a byte: BX := BX + i (element size 1, no bounds check),
           keep the CHAR ref.  Math is offset-only; ES (segment) is untouched. *)
        IF item.addrDeref THEN
          Cgen.Emit1(006H);                  (* PUSH ES *)
          Cgen.Emit1(BYTE(Cgen.OpPushBx));   (* PUSH BX *)
          ParseExpression(index);
          Cgen.CgLoadItem(index);
          Cgen.Emit1(05BH);                  (* POP BX (base offset) *)
          Cgen.Emit2(003H, 0D8H);            (* ADD BX, AX *)
          Cgen.Emit1(007H);                  (* POP ES *)
          item.mode := Cgen.MReg; item.isRef := TRUE; item.type := Syms.TypeChar;
          item.addrDeref := FALSE;
          IF sc.sym # Scan.TComma THEN more := FALSE END;
          IF more THEN Error("too many index dimensions for ADDRESS") END
        ELSE
        (* Auto-dereference: an index selector "[" applied to a POINTER-to-array
           implicitly dereferences it (Oberon-07 p[i] == p^[i]). *)
        IF (item.type # Syms.NoType) & (item.type.form = Syms.TFPointer) THEN
          IF (item.mode = Cgen.MLocal) & ~item.isRef THEN
            Cgen.CgLesBxBp(item.adr)
          ELSIF (item.mode = Cgen.MGlobal) & ~item.isRef THEN
            Cgen.CgLesBxMem(WORD(item.adr))
          ELSE
            Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
          END;
          item.mode := Cgen.MReg; item.isRef := TRUE;
          item.type := item.type.base; item.adr := 0
        END;
        IF (item.type = Syms.NoType) OR (item.type.form # Syms.TFArray) THEN
          Error("not an array"); ParseExpression(index); more := FALSE
        ELSE
          (* Always emit full ES:BX setup + PUSH/POP wrapping and indexed
             write, regardless of whether the index is a compile-time constant.
             Compile-time bounds check still fires on constant indices, but it
             does NOT replace the runtime codegen path. *)
          elem := item.type.elem;
          IF (item.mode = Cgen.MReg) & item.isRef THEN
            (* ES:BX points to array base (through far pointer).
               PUSH ES to preserve array segment across index expression. *)
            Cgen.Emit1(006H);                 (* PUSH ES *)
            Cgen.Emit1(BYTE(Cgen.OpPushBx));(* PUSH BX *)
            ParseExpression(index);
            (* Capture const-ness BEFORE CgLoadItem (which changes mode to MReg). *)
            wasConst := IsIntConst(index);
            IF boundsChk & wasConst &
               (item.type.len >= 0) &
               ((index.val < 0) OR (index.val >= item.type.len)) THEN
              Error("index out of bounds")
            END;
            Cgen.CgLoadItem(index);
            IF ~wasConst & (item.type.len >= 0) THEN
              EmitBoundsCheck(item.type.len, 0)
            END;
            IF elem.size = 2 THEN Cgen.Emit2(0D1H, 0E0H)            (* SHL AX,1 *)
            ELSIF (elem.size > 2) & IsPow2(elem.size) THEN
              Cgen.CgShlImm(Log2(elem.size))                       (* SHL AX, log2(size) *)
            ELSIF elem.size > 2 THEN
              Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
            END;
            Cgen.Emit1(05BH);                (* POP BX (base offset) *)
            Cgen.Emit2(003H, 0D8H);            (* ADD BX, AX *)
            Cgen.Emit1(007H);                  (* POP ES *)
          ELSE
            (* Load array base into ES:BX *)
            IF (item.mode = Cgen.MLocal) & (item.isRef OR (item.type.len < 0)) THEN
              Cgen.CgLesBxBp(item.adr)
            ELSIF ((item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal)) & item.isRef THEN
              Cgen.CgLesBxItem(item.mode, item.adr)
            ELSIF (item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal) THEN
              Cgen.CgLoadAddrItem(item.mode, item.adr);
              Cgen.CgEsFromMode(item.mode);
              Cgen.Emit2(08BH, 0D8H)   (* MOV BX, AX *)
            ELSE
              Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx()
            END;
            (* PUSH ES,BX to preserve array segment across index eval. *)
            Cgen.Emit1(006H);                 (* PUSH ES *)
            Cgen.Emit1(053H);                 (* PUSH BX *)
            ParseExpression(index);
            wasConst := IsIntConst(index);
            IF boundsChk & wasConst THEN
              IF index.val < 0 THEN Error("index out of bounds") END;
              IF (item.type.len >= 0) & (index.val >= item.type.len) THEN
                Error("index out of bounds")
              END
            END;
            Cgen.CgLoadItem(index);
            IF ~wasConst THEN
              IF item.type.len < 0 THEN EmitBoundsCheck(-1, item.adr + 4)
              ELSE EmitBoundsCheck(item.type.len, 0) END
            END;
            IF elem.size = 2 THEN Cgen.Emit2(0D1H, 0E0H)
            ELSIF (elem.size > 2) & IsPow2(elem.size) THEN
              Cgen.CgShlImm(Log2(elem.size))                       (* SHL AX, log2(size) *)
            ELSIF elem.size > 2 THEN
              Cgen.CgLoadImmCx(INTEGER(elem.size)); Cgen.CgMul()
            END;
            Cgen.Emit1(05BH);        (* POP BX (base offset) *)
            Cgen.Emit2(003H, 0D8H);  (* ADD BX, AX *)
            Cgen.Emit1(007H);        (* POP ES *)
            item.mode := Cgen.MReg; item.isRef := TRUE
          END;
          item.type := elem;
          IF sc.sym # Scan.TComma THEN more := FALSE END
        END
        END
      END;
      Expect(Scan.TRbrak)
    ELSE  (* TArrow *)
      Scan.Next(sc);
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFAddress) THEN
        (* SYSTEM.ADDRESS deref: ADDRESS behaves as POINTER TO CHAR.  Load the
           4-byte address value into DX:AX (CgLoadItem handles local/global/
           VAR-param/MReg uniformly), move it to ES:BX, and make the item a CHAR
           ref.  Standalone `p^` reads the byte; a following `[i]` (handled in the
           TLbrak branch) advances BX by i. *)
        Cgen.CgLoadItem(item); Cgen.CgDxaxToEsbx();
        item.mode := Cgen.MReg; item.isRef := TRUE; item.type := Syms.TypeChar;
        item.adr := 0; item.addrDeref := TRUE
      ELSIF (item.type = Syms.NoType) OR (item.type.form # Syms.TFPointer) THEN Error("not a pointer")
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
        item.mode := Cgen.MReg; item.isRef := TRUE; item.type := item.type.base; item.adr := 0
      END
    END
  END
END ParseDesignator;

(* ---- factor ---- *)

PROCEDURE ParseFactor(VAR item: Cgen.Item);
  VAR sym: Syms.Symbol; arg: Cgen.Item; form, srcForm, id: INTEGER;
      pt: Syms.TypeDesc; varAdr: LONGINT; varGlobal, varRef: BOOLEAN;
      rdId: INTEGER; codeOfs: LONGINT; isImp, isFr: BOOLEAN; pt2: Syms.TypeDesc;
      skipBp: Cgen.Backpatch; loopTop: LONGINT;
      lo, hi: Cgen.Item; skip2: Cgen.Backpatch;
      realVar: REAL; realBytes: ARRAY 4 OF BYTE;
BEGIN
  item.isRef := FALSE; item.isFar := FALSE; item.fwdSym := Syms.NoSym;
  item.rootSym := Syms.NoSym; item.addrDeref := FALSE;
  CASE sc.sym OF
    Scan.TInt:
      item.mode := Cgen.MConst; item.val := sc.ival;
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
      IF sc.ival >= LONGINT(65536) THEN
        item.type := Syms.TypeLongint
      ELSIF sc.ival >= LONGINT(32768) THEN
        item.type := Syms.TypeWord
      ELSE item.type := Syms.TypeInteger END;
      Scan.Next(sc)

  | Scan.TReal:
      modUsesFpu := TRUE;
      item.mode := Cgen.MConst; item.adr := Cgen.CgDpc();
      item.type := Syms.TypeReal;
      realVar := sc.rval;
      SYSTEM.MOVE(realVar, realBytes, 4);
      Cgen.EmitDataByte(realBytes[0]); Cgen.EmitDataByte(realBytes[1]);
      Cgen.EmitDataByte(realBytes[2]); Cgen.EmitDataByte(realBytes[3]);
      Scan.Next(sc)

  | Scan.TChar:
      item.mode := Cgen.MConst; item.val := sc.ival;
      item.type := Syms.TypeChar; Scan.Next(sc)

  | Scan.TString:
      item.mode := Cgen.MGlobal; item.adr := Cgen.CgDpc();
      item.type := Syms.TypeNewArray(Syms.TypeChar, LONGINT(Strings.Length(sc.sval) + 1));
      Cgen.EmitDataString(sc.sval); Scan.Next(sc)

  | Scan.TTrue:
      item.mode := Cgen.MConst; item.val := 1; item.type := Syms.TypeBoolean; Scan.Next(sc)

  | Scan.TFalse:
      item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeBoolean; Scan.Next(sc)

  | Scan.TNil:
      item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeNiltype; Scan.Next(sc)

  | Scan.TLbrace:
      (* SET literal *)
      Scan.Next(sc);
      Cgen.EmitCodeStr("33,C0,50");   (* XOR AX,AX; PUSH AX *)
      WHILE sc.sym # Scan.TRbrace DO
        IF sc.sym = Scan.TComma THEN Scan.Next(sc) END;
        ParseExpression(lo); Cgen.CgLoadItem(lo);
        IF sc.sym = Scan.TDotdot THEN
          Scan.Next(sc);
          Cgen.Emit1(BYTE(Cgen.OpPushAx));
          ParseExpression(hi); Cgen.CgLoadItem(hi);
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
      Expect(Scan.TRbrace);
      Cgen.Emit1(BYTE(Cgen.OpPopAx));
      item.mode := Cgen.MReg; item.type := Syms.TypeSet

  | Scan.TLparen:
      Scan.Next(sc); ParseExpression(item); Expect(Scan.TRparen)

  | Scan.TNot:
      Scan.Next(sc); ParseFactor(item);
      Cgen.CgLoadItem(item); Cgen.CgBoolNot();
      item.type := Syms.TypeBoolean; item.mode := Cgen.MReg

  | Scan.TIdent:
      sym := Syms.SymFind(sc.id);
      (* Type cast built-ins *)
      IF (sym # Syms.NoSym) & (sym.kind = Syms.KType) THEN
        form := -1;
        IF sym.type # Syms.NoType THEN form := sym.type.form END;
        IF (form = Syms.TFInteger) OR (form = Syms.TFByte) OR (form = Syms.TFLongint)
            OR (form = Syms.TFWord) OR (form = Syms.TFAddress)
            OR (form = Syms.TFReal) OR (form = Syms.TFLongreal) THEN
          Scan.Next(sc);
          IF sc.sym = Scan.TLparen THEN
            Scan.Next(sc); ParseExpression(arg);
            Expect(Scan.TRparen);
            srcForm := Syms.TFInteger;
            IF arg.type # NIL THEN srcForm := arg.type.form END;
            (* SYSTEM.ADDRESS converts only with LONGINT.  Casting an ADDRESS to
               a 2-byte INTEGER/WORD/BYTE would silently drop the segment — reject
               it (LONGINT(addr) is the supported widening). *)
            IF (srcForm = Syms.TFAddress) &
               ((form = Syms.TFInteger) OR (form = Syms.TFWord) OR (form = Syms.TFByte)) THEN
              Error("ADDRESS converts only to LONGINT")
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
                    Cgen.Emit2(033H, 0D2H)   (* XOR DX,DX — zero-extend unsigned source *)
                  ELSIF (srcForm = Syms.TFAddress) OR (srcForm = Syms.TFPointer)
                      OR (srcForm = Syms.TFProc) THEN
                    (* already a 4-byte far value in DX:AX — no extension *)
                  ELSIF srcForm # Syms.TFLongint THEN Cgen.Emit1(099H)  (* CWD — sign-extend INTEGER *)
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
                  Error("ADDRESS() accepts only LONGINT (or pointer/address)")
                END;
                item.type := Syms.TypeAddress; item.mode := Cgen.MReg
            | Syms.TFReal:
                Cgen.CgLoadItem(arg);
                IF srcForm = Syms.TFLongint THEN CoerceDxaxToFpu()
                ELSIF srcForm # Syms.TFReal THEN CoerceAxToFpu()
                END;
                modUsesFpu := TRUE; item.type := Syms.TypeReal; item.mode := Cgen.MFreg
            | Syms.TFLongreal:
                Cgen.CgLoadItem(arg);
                IF srcForm = Syms.TFLongint THEN CoerceDxaxToFpu()
                ELSIF (srcForm # Syms.TFReal) & (srcForm # Syms.TFLongreal) THEN CoerceAxToFpu()
                END;
                modUsesFpu := TRUE; item.type := Syms.TypeLongreal; item.mode := Cgen.MFreg
            ELSE Cgen.CgLoadItem(arg); Error("unsupported type cast"); item.type := Syms.TypeInteger; item.mode := Cgen.MReg
            END;
            RETURN
          END;
          Error("type name not valid in expression");
          item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeInteger; RETURN
        END
      END;
      (* Built-in sys procs as expressions *)
      IF (sym # Syms.NoSym) & (sym.kind = Syms.KSysProc) THEN
        id := sym.sysId; Scan.Next(sc);
        Expect(Scan.TLparen);
        IF id = Syms.SpSize THEN
          (* SIZE(T): compile-time byte size of type T as a WORD constant.
             Accepts a (possibly qualified) type name.  No inline ARRAY/
             RECORD type expressions — users should declare a named type. *)
          ParseSizeArg(item);
          Expect(Scan.TRparen); RETURN
        END;
        IF id = Syms.SpLen THEN
          ParseExpression(arg); Expect(Scan.TRparen);
          IF (arg.type # Syms.NoType) & (arg.type.form = Syms.TFArray) &
             (arg.type.len >= 0) THEN
            (* Fixed-size array: LEN is a compile-time WORD constant.  Usable
               in CONST decls, ARRAY dimensions, and CASE labels. *)
            item.mode := Cgen.MConst;
            item.val  := arg.type.len;
            item.type := Syms.TypeWord; RETURN
          END;
          IF (arg.type # Syms.NoType) & (arg.type.form = Syms.TFArray) &
             (arg.mode = Cgen.MLocal) THEN
            Cgen.CgLoadBp(arg.adr + 4)
          ELSE Cgen.CgLoadImm(0) END;
          item.type := Syms.TypeWord; item.mode := Cgen.MReg; RETURN
        END;
        ParseExpression(arg); Cgen.CgLoadItem(arg); Expect(Scan.TRparen);
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
        ELSE Error("built-in not usable as expression"); item.type := Syms.TypeInteger
        END;
        item.mode := Cgen.MReg; RETURN
      END;
      (* General designator *)
      ParseDesignator(item);
      MarkRead(item);

      IF (item.mode = Cgen.MSysProc) & (sc.sym = Scan.TLparen) THEN
        ParseSystemIntrinsic(item, INTEGER(item.val))
      ELSIF (item.type # Syms.NoType) & (item.type.form = Syms.TFProc) &
            ((item.mode = Cgen.MLocal) OR (item.mode = Cgen.MGlobal) OR
             ((item.mode = Cgen.MReg) & item.isRef)) & (sc.sym = Scan.TLparen) THEN
        pt := item.type; varAdr := item.adr;
        varGlobal := (item.mode = Cgen.MGlobal); varRef := (item.mode = Cgen.MReg) & item.isRef;
        IF varRef THEN
          Cgen.EmitCodeStr("53,06");  (* PUSH BX; PUSH ES (save slot addr) *)
          ParseActualParameters(pt);
          Cgen.CgCallProcVarRefTail(pt.argSize)
        ELSE
          ParseActualParameters(pt);
          (* Proc-typed VARs are always FAR (see PARSER.MOD ParseType). *)
          IF varGlobal THEN Cgen.CgCallProcVarMem(WORD(varAdr))
          ELSE Cgen.CgCallProcVarBp(varAdr) END
        END;
        item.type := pt.retType; item.isRef := FALSE;
        IF (pt.retType # Syms.NoType) & ((pt.retType.form = Syms.TFReal) OR (pt.retType.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE item.mode := Cgen.MReg END
      ELSIF (item.mode = Cgen.MProc) & (item.type # Syms.NoType) & item.type.isInline & (sc.sym = Scan.TLparen) THEN
        pt2 := item.type;
        EmitInlineCall(pt2);
        item.type := pt2.retType;
        IF item.type = Syms.NoType THEN item.type := Syms.TypeInteger END;
        (* Result lives in ST(0) when ret type is REAL/LONGREAL, AX otherwise. *)
        IF (item.type # Syms.NoType) & ((item.type.form = Syms.TFReal) OR (item.type.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE
          item.mode := Cgen.MReg
        END
      ELSIF ((item.mode = Cgen.MProc) OR (item.mode = Cgen.MImport)) & (sc.sym = Scan.TLparen) THEN
        rdId := item.rdoffId; codeOfs := item.adr;
        isImp := (item.mode = Cgen.MImport); isFr := item.isFar;
        pt2 := item.type;
        IF pt2 = NIL THEN pt2 := Syms.TypeNewProc(Syms.TypeNotype) END;
        ParseActualParameters(pt2);
        IF isImp & isFr THEN Cgen.CgCallFar(rdId)
        ELSIF isImp THEN Cgen.CgCallNear(rdId)
        ELSIF item.fwdSym # Syms.NoSym THEN FwdEmitCall(item.fwdSym, isFr)
        ELSIF isFr THEN Cgen.CgCallLocalFar(codeOfs)
        ELSE Cgen.CgCallLocal(codeOfs)
        END;
        item.type := pt2.retType;
        IF (pt2.retType # Syms.NoType) & ((pt2.retType.form = Syms.TFReal) OR (pt2.retType.form = Syms.TFLongreal)) THEN
          item.mode := Cgen.MFreg
        ELSE item.mode := Cgen.MReg END
      END
  ELSE
    Error("factor expected"); item.mode := Cgen.MConst; item.val := 0; item.type := Syms.TypeInteger
  END
END ParseFactor;

(* ---- term ---- *)

(* Short-circuit AND: `p & q` == `IF p THEN q ELSE FALSE` (Oberon-07 §9.1).
   Only the LHS is unconditionally evaluated; the RHS's parse+emit happens
   only on the path where it's reachable, so a side-effecting or unsafe RHS
   (function call, a divisor guarded by `(n#0) & (x DIV n>0)`) is never
   evaluated when the LHS is already FALSE.  Result is materialized 0/1 in AX
   exactly as the bitwise-AND path did, so every caller (IF/WHILE/REPEAT
   conditions, nested boolean exprs) sees the same Item shape as before. *)
PROCEDURE ParseAndTail(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; falseBp, joinBp: Cgen.Backpatch;
BEGIN
  Cgen.CgLoadItem(item);
  Cgen.CgTestAx();
  (* MUST be a near jump: it spans the whole RHS emit (ParseFactor may emit
     an arbitrarily long expression — a >127-byte span in a short Jcc wraps
     the rel8 and jumps backward into mid-instruction; this exact overflow
     broke self-hosting, see opt.md §8). *)
  Cgen.CgCondNear(Cgen.OpJz, falseBp);    (* LHS false -> skip RHS, result FALSE *)
  ParseFactor(rhs); Cgen.CgLoadItem(rhs); (* BOOLEAN is always a clean 0/1 -> AX *)
  Cgen.CgJmpNear(joinBp);
  Cgen.CgPatchNear(falseBp);
  Cgen.Emit2(033H, 0C0H);                 (* XOR AX,AX *)
  Cgen.CgPatchNear(joinBp);
  item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
END ParseAndTail;

PROCEDURE ParseTerm(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; op: INTEGER; isLong, isFpu, isWord: BOOLEAN;
      rhsLoaded: BOOLEAN;
BEGIN
  ParseFactor(item);
  WHILE (sc.sym = Scan.TStar) OR (sc.sym = Scan.TDiv) OR
        (sc.sym = Scan.TMod)  OR (sc.sym = Scan.TAnd) OR (sc.sym = Scan.TSlash) DO
    op := sc.sym; Scan.Next(sc);
    IF op = Scan.TAnd THEN
      ParseAndTail(item); rhsLoaded := FALSE
    ELSIF IsIntConst(item) & ((op = Scan.TStar) OR (op = Scan.TDiv) OR (op = Scan.TMod)) THEN
      ParseFactor(rhs);
      IF IsIntConst(rhs) THEN ConstFoldInt(item, op, rhs); rhsLoaded := FALSE
      ELSE
        isLong := (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint);
        isWord := ~isLong & ((item.type # Syms.NoType) & (item.type.form = Syms.TFWord) OR
                             (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFWord));
        (* const * x : multiply is commutative, so strength-reduce on the
           variable operand.  DIV/MOD are NOT commutative (const is the
           dividend here) — fall through to the generic path for those. *)
        IF (op = Scan.TStar) & StrengthReducible(op, item.val, isLong) THEN
          Cgen.CgLoadItem(rhs);
          IF StrengthReduce(op, item.val, isLong, isWord) THEN
            IF isLong THEN item.type := Syms.TypeLongint
            ELSIF isWord THEN item.type := Syms.TypeWord
            ELSE item.type := Syms.TypeInteger END;
            item.mode := Cgen.MReg; rhsLoaded := FALSE
          ELSE rhsLoaded := TRUE  (* never happens: StrengthReducible vetted it *)
          END
        ELSE
          Cgen.CgLoadItem(rhs);
          IF isLong THEN
            Cgen.EmitCodeStr("8B,C8,8B,DA");  (* MOV CX,AX; MOV BX,DX *)
            Cgen.CgLoadItem(item); Cgen.CgPushDxax();
            Cgen.EmitCodeStr("8B,C1,8B,D3")   (* MOV AX,CX; MOV DX,BX *)
          ELSE
            Cgen.Emit1(BYTE(Cgen.OpPushAx));
            Cgen.CgLoadItem(item);
            Cgen.EmitCodeStr("59,50,8B,C1")  (* POP CX; PUSH AX; MOV AX,CX *)
          END;
          rhsLoaded := TRUE
        END
      END
    ELSE
      Cgen.CgLoadItem(item);
      isFpu  := (item.type # Syms.NoType) & ((item.type.form = Syms.TFReal) OR (item.type.form = Syms.TFLongreal));
      isLong := (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint);
      isWord := ~isLong & ~isFpu & (item.type # Syms.NoType) & (item.type.form = Syms.TFWord);
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFSet) THEN
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        ParseFactor(rhs); Cgen.CgLoadItem(rhs);
        Cgen.Emit1(BYTE(Cgen.OpPopCx));
        IF      op = Scan.TStar  THEN Cgen.CgAnd()
        ELSIF   op = Scan.TSlash THEN Cgen.CgXor()
        ELSE Error("operator not supported for SET") END;
        item.type := Syms.TypeSet; item.mode := Cgen.MReg;
        rhsLoaded := FALSE
      ELSIF isFpu THEN
        Cgen.CgFpush();
        ParseFactor(rhs); Cgen.CgLoadItem(rhs);
        IF IsIntType(rhs) THEN
          IF (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
        END;
        Cgen.CgFpop();
        CASE op OF
          Scan.TStar:  Cgen.CgFmul()
        | Scan.TSlash: Cgen.Emit2(0DEH, 0F1H)
        ELSE Error("operator not supported for REAL") END;
        IF (item.type # Syms.NoType) & (item.type.form = Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
        ELSE item.type := Syms.TypeReal END;
        item.mode := Cgen.MFreg; rhsLoaded := FALSE
      ELSE
        (* x op const : strength-reduce `*`/`DIV`/`MOD` by a constant 0/1/2^n.
           Push the variable first (this preserves it across rhs evaluation for
           the general non-const case), then parse rhs.  If rhs is a reducible
           constant, pop the variable back and emit a shift/AND instead of
           IMUL/IDIV (costs one redundant PUSH/POP but saves a 70-cycle multiply
           or divide).  Otherwise load rhs and fall through to the dispatch. *)
        IF isLong THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
        ParseFactor(rhs);
        IF ~isLong & (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFWord) THEN isWord := TRUE END;
        IF IsIntConst(rhs) &
           ((op = Scan.TStar) OR (op = Scan.TDiv) OR (op = Scan.TMod)) &
           StrengthReducible(op, rhs.val, isLong) THEN
          IF isLong THEN Cgen.EmitCodeStr("58,5A")   (* POP AX; POP DX *)
          ELSE Cgen.Emit1(BYTE(Cgen.OpPopAx)) END;
          IF StrengthReduce(op, rhs.val, isLong, isWord) THEN
            IF isLong THEN item.type := Syms.TypeLongint
            ELSIF isWord THEN item.type := Syms.TypeWord
            ELSE item.type := Syms.TypeInteger END;
            item.mode := Cgen.MReg; rhsLoaded := FALSE
          ELSE rhsLoaded := TRUE   (* unreachable: StrengthReducible vetted it *)
          END
        ELSE
          Cgen.CgLoadItem(rhs);
          rhsLoaded := TRUE
        END
      END
    END;
    IF rhsLoaded THEN
      IF IsFpuType(rhs) THEN
        IF isLong THEN
          Cgen.EmitCodeStr("58,5A"); CoerceDxaxToFpu()  (* POP AX; POP DX *)
        ELSE Cgen.Emit1(058H); CoerceAxToFpu() END;
        CASE op OF
          Scan.TStar:  Cgen.CgFmul()
        | Scan.TSlash: Cgen.Emit2(0DEH, 0F1H)
        ELSE Error("operator not supported for mixed int/REAL") END;
        IF (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
        ELSE item.type := Syms.TypeReal END;
        item.mode := Cgen.MFreg
      ELSIF isLong THEN
        IF (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
          (* widen rhs to 32-bit: WORD/BYTE/CHAR/BOOLEAN are unsigned → zero-extend
             (XOR DX,DX); only signed INTEGER sign-extends (CWD). *)
          IF (rhs.type.form = Syms.TFWord) OR (rhs.type.form = Syms.TFByte)
              OR (rhs.type.form = Syms.TFChar) OR (rhs.type.form = Syms.TFBoolean) THEN
            Cgen.Emit2(033H, 0D2H)
          ELSE Cgen.Emit1(099H) END
        END;
        (* NOTE: op = TAnd never reaches this dispatch — `&` is always consumed
           by the short-circuit ParseAndTail above (rhsLoaded = FALSE).  The
           former TAnd arms here were dead code from the pre-short-circuit
           implementation and have been removed. *)
        CASE op OF
          Scan.TStar: Cgen.CgPushDxax(); Cgen.CgCallFar(GetSystemImport("SYSTEM_S32MUL"))
        | Scan.TDiv:  Cgen.CgPushDxax(); Cgen.CgCallFar(GetSystemImport("SYSTEM_S32DIV"))
        | Scan.TMod:  Cgen.CgPushDxax(); Cgen.CgCallFar(GetSystemImport("SYSTEM_S32MOD"))
        ELSE Error("operator not supported for LONGINT") END;
        item.type := Syms.TypeLongint; item.mode := Cgen.MReg
      ELSIF isWord THEN
        Cgen.Emit1(BYTE(Cgen.OpPopCx));
        CASE op OF
          Scan.TStar: Cgen.CgMulU()
        | Scan.TDiv:  Cgen.CgDivU()
        | Scan.TMod:  Cgen.CgModU()
        ELSE Error("operator not supported for WORD") END;
        item.type := Syms.TypeWord;
        item.mode := Cgen.MReg
      ELSE
        Cgen.Emit1(BYTE(Cgen.OpPopCx));
        CASE op OF
          Scan.TStar: Cgen.CgMul()
        | Scan.TDiv:  Cgen.CgDiv()
        | Scan.TMod:  Cgen.CgMod()
        ELSE Error("operator not supported") END;
        item.mode := Cgen.MReg
      END
    END
  END
END ParseTerm;

(* ---- simple expression ---- *)

(* Short-circuit OR: `p OR q` == `IF p THEN TRUE ELSE q` (Oberon-07 §9.1).
   Mirrors ParseAndTail: the RHS's parse+emit is skipped entirely once the LHS
   already makes the result TRUE. *)
PROCEDURE ParseOrTail(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; trueBp, joinBp: Cgen.Backpatch;
BEGIN
  Cgen.CgLoadItem(item);
  Cgen.CgTestAx();
  (* MUST be a near jump: spans the whole RHS emit — see ParseAndTail. *)
  Cgen.CgCondNear(Cgen.OpJnz, trueBp);    (* LHS true -> skip RHS, result TRUE *)
  ParseTerm(rhs); Cgen.CgLoadItem(rhs);   (* BOOLEAN is always a clean 0/1 -> AX *)
  Cgen.CgJmpNear(joinBp);
  Cgen.CgPatchNear(trueBp);
  Cgen.CgLoadImm(1);
  Cgen.CgPatchNear(joinBp);
  item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
END ParseOrTail;

PROCEDURE ParseSimpleExpression(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; op: INTEGER; negate, isFpu, isLong, isWord, isAddr: BOOLEAN;
      rhsLoaded: BOOLEAN;
BEGIN
  negate := FALSE;
  IF    sc.sym = Scan.TMinus THEN negate := TRUE; Scan.Next(sc)
  ELSIF sc.sym = Scan.TPlus  THEN Scan.Next(sc)
  END;
  ParseTerm(item);
  IF negate THEN
    IF (item.mode = Cgen.MConst) & ~IsFpuType(item) THEN
      item.val := -item.val;
      (* Negation is a SIGNED operation: `-40000` etc. must not stay
         WORD-typed (WORD operands force unsigned comparisons).  A negated
         WORD constant becomes INTEGER when it fits, else LONGINT. *)
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFWord) THEN
        IF (item.val >= LONGINT(-32768)) & (item.val <= LONGINT(32767)) THEN
          item.type := Syms.TypeInteger
        ELSE
          item.type := Syms.TypeLongint
        END
      END
    ELSE
      Cgen.CgLoadItem(item);
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint) THEN Cgen.CgNeg32(); item.mode := Cgen.MReg
      ELSIF IsFpuType(item) THEN Cgen.CgFchs(); item.mode := Cgen.MFreg
      ELSE Cgen.CgNeg(); item.mode := Cgen.MReg
      END
    END
  END;
  WHILE (sc.sym = Scan.TPlus) OR (sc.sym = Scan.TMinus) OR (sc.sym = Scan.TOr) DO
    op := sc.sym; Scan.Next(sc);
    IF op = Scan.TOr THEN
      ParseOrTail(item); rhsLoaded := FALSE
    ELSIF IsIntConst(item) & ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
      ParseTerm(rhs);
      IF IsIntConst(rhs) THEN ConstFoldInt(item, op, rhs); rhsLoaded := FALSE
      ELSE
        isLong := (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint);
        isWord := ~isLong & ((item.type # Syms.NoType) & (item.type.form = Syms.TFWord) OR
                             (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFWord));
        (* 0 - x = -x and 0 + x = x identity folds.  Restrict to the case where
           the constant 0 and the variable share the simple INTEGER/WORD form
           (item is INTEGER 0 here); a LONGINT variable must keep the generic
           path so DX:AX is handled (CgNeg vs CgNeg32, hi-word load). *)
        IF (item.val = LONGINT(0)) & (op = Scan.TMinus) &
           (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) & ~isLong THEN
          Cgen.CgLoadItem(rhs);
          Cgen.CgNeg();
          IF isWord THEN item.type := Syms.TypeWord ELSE item.type := Syms.TypeInteger END;
          item.mode := Cgen.MReg; rhsLoaded := FALSE
        ELSIF (item.val = LONGINT(0)) & (op = Scan.TPlus) &
              (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) & ~isLong THEN
          Cgen.CgLoadItem(rhs);
          IF isWord THEN item.type := Syms.TypeWord ELSE item.type := Syms.TypeInteger END;
          item.mode := Cgen.MReg; rhsLoaded := FALSE
        ELSE
          Cgen.CgLoadItem(rhs);
          IF isLong THEN
            Cgen.EmitCodeStr("8B,C8,8B,DA");  (* MOV CX,AX; MOV BX,DX *)
            Cgen.CgLoadItem(item); Cgen.CgPushDxax();
            Cgen.EmitCodeStr("8B,C1,8B,D3")   (* MOV AX,CX; MOV DX,BX *)
          ELSE
            Cgen.Emit1(BYTE(Cgen.OpPushAx));
            Cgen.CgLoadItem(item);
            Cgen.EmitCodeStr("59,50,8B,C1")  (* POP CX; PUSH AX; MOV AX,CX *)
          END;
          rhsLoaded := TRUE
        END
      END
    ELSE
      Cgen.CgLoadItem(item);
      isFpu  := (item.type # Syms.NoType) & ((item.type.form = Syms.TFReal) OR (item.type.form = Syms.TFLongreal));
      isLong := (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint);
      isWord := ~isLong & ~isFpu & (item.type # Syms.NoType) & (item.type.form = Syms.TFWord);
      isAddr := (item.type # Syms.NoType) & (item.type.form = Syms.TFAddress);
      IF isAddr & ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
        (* SYSTEM.ADDRESS +/- offset: offset-only 16-bit math, segment (DX)
           preserved across the rhs evaluation.  PUSH DX (seg), PUSH AX (ofs);
           eval rhs → AX = step.lo; POP CX = old ofs; ADD/SUB AX,CX; POP DX =
           saved seg.  Result keeps the ADDRESS type (DX:AX). *)
        Cgen.Emit1(BYTE(Cgen.OpPushDx));
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        ParseTerm(rhs); Cgen.CgLoadItem(rhs);
        Cgen.Emit1(BYTE(Cgen.OpPopCx));        (* CX = old ofs *)
        IF op = Scan.TPlus THEN Cgen.CgAdd() ELSE Cgen.CgSub() END;
        Cgen.Emit1(BYTE(Cgen.OpPopDx));        (* DX = saved seg *)
        item.type := Syms.TypeAddress; item.mode := Cgen.MReg; rhsLoaded := FALSE
      ELSIF (item.type # Syms.NoType) & (item.type.form = Syms.TFSet) THEN
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        ParseTerm(rhs); Cgen.CgLoadItem(rhs); Cgen.Emit1(BYTE(Cgen.OpPopCx));
        IF op = Scan.TPlus THEN Cgen.CgOr()
        ELSIF op = Scan.TMinus THEN Cgen.Emit2(0F7H, 0D0H); Cgen.CgAnd()
        ELSE Error("operator not supported for SET in expr") END;
        item.type := Syms.TypeSet; item.mode := Cgen.MReg; rhsLoaded := FALSE
      ELSIF isFpu THEN
        Cgen.CgFpush();
        ParseTerm(rhs); Cgen.CgLoadItem(rhs);
        IF IsIntType(rhs) THEN
          IF (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
        END;
        Cgen.CgFpop();
        IF op = Scan.TPlus THEN Cgen.CgFadd() ELSE Cgen.Emit2(0DEH, 0E1H) END;
        item.mode := Cgen.MFreg; rhsLoaded := FALSE
      ELSE
        IF isLong THEN Cgen.CgPushDxax() ELSE Cgen.Emit1(BYTE(Cgen.OpPushAx)) END;
        ParseTerm(rhs);
        IF ~isLong & (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFWord) THEN isWord := TRUE END;
        (* x + 0 / x - 0 = x : pop the variable back and emit nothing. *)
        IF IsIntConst(rhs) & (rhs.val = LONGINT(0)) &
           ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
          IF isLong THEN Cgen.EmitCodeStr("58,5A")   (* POP AX; POP DX *)
          ELSE Cgen.Emit1(BYTE(Cgen.OpPopAx)) END;
          IF isLong THEN item.type := Syms.TypeLongint
          ELSIF isWord THEN item.type := Syms.TypeWord
          ELSE item.type := Syms.TypeInteger END;
          item.mode := Cgen.MReg; rhsLoaded := FALSE
        ELSE
          Cgen.CgLoadItem(rhs);
          rhsLoaded := TRUE
        END
      END
    END;
    IF rhsLoaded THEN
      IF IsFpuType(rhs) THEN
        IF isLong THEN
          Cgen.EmitCodeStr("58,5A"); CoerceDxaxToFpu()  (* POP AX; POP DX *)
        ELSE Cgen.Emit1(058H); CoerceAxToFpu() END;
        IF op = Scan.TPlus THEN Cgen.CgFadd() ELSE Cgen.Emit2(0DEH, 0E1H) END;
        IF (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
        ELSE item.type := Syms.TypeReal END;
        item.mode := Cgen.MFreg
      ELSE
        IF ~isLong & (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongint) THEN
          Error("mixed INTEGER/LONGINT: use LONGINT() cast")
        END;
        IF isLong & (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
          (* widen rhs to 32-bit: WORD/BYTE/CHAR/BOOLEAN unsigned → zero-extend
             (XOR DX,DX); signed INTEGER → sign-extend (CWD).  A WORD >= 32768
             (e.g. a 37 KB code-group length) must NOT sign-extend. *)
          IF (rhs.type.form = Syms.TFWord) OR (rhs.type.form = Syms.TFByte)
              OR (rhs.type.form = Syms.TFChar) OR (rhs.type.form = Syms.TFBoolean) THEN
            Cgen.Emit2(033H, 0D2H)
          ELSE Cgen.Emit1(099H) END
        END;
        IF isLong THEN
          Cgen.CgPopCxbx();
          CASE op OF
            Scan.TPlus:  Cgen.CgAdd32()
          | Scan.TMinus: Cgen.CgSub32()
          | Scan.TOr:    Cgen.CgOr32(); item.type := Syms.TypeBoolean
          ELSE END
        ELSE
          Cgen.Emit1(BYTE(Cgen.OpPopCx));
          CASE op OF
            Scan.TPlus:  Cgen.CgAdd()
          | Scan.TMinus: Cgen.CgSub()
          | Scan.TOr:    Cgen.CgOr(); item.type := Syms.TypeBoolean
          ELSE END;
          IF isWord & (op # Scan.TOr) THEN item.type := Syms.TypeWord END
        END;
        item.mode := Cgen.MReg
      END
    END
  END
END ParseSimpleExpression;

(* ---- relop helpers ---- *)

PROCEDURE RelopJcc(op: INTEGER): INTEGER;
BEGIN
  CASE op OF
    Scan.TEql: RETURN Cgen.OpJz
  | Scan.TNeq: RETURN Cgen.OpJnz
  | Scan.TLss: RETURN Cgen.OpJl
  | Scan.TLeq: RETURN Cgen.OpJle
  | Scan.TGtr: RETURN Cgen.OpJg
  | Scan.TGeq: RETURN Cgen.OpJge
  ELSE RETURN Cgen.OpJz
  END
END RelopJcc;

PROCEDURE FrelopJcc(op: INTEGER): INTEGER;
BEGIN
  CASE op OF
    Scan.TEql: RETURN 074H
  | Scan.TNeq: RETURN 075H
  | Scan.TLss: RETURN 072H
  | Scan.TLeq: RETURN 076H
  | Scan.TGtr: RETURN 077H
  | Scan.TGeq: RETURN 073H
  ELSE RETURN 074H
  END
END FrelopJcc;

PROCEDURE RelopJccU(op: INTEGER): INTEGER;
BEGIN
  CASE op OF
    Scan.TEql: RETURN Cgen.OpJz
  | Scan.TNeq: RETURN Cgen.OpJnz
  | Scan.TLss: RETURN 072H  (* JB  unsigned below *)
  | Scan.TLeq: RETURN 076H  (* JBE unsigned below or equal *)
  | Scan.TGtr: RETURN 077H  (* JA  unsigned above *)
  | Scan.TGeq: RETURN 073H  (* JAE unsigned above or equal *)
  ELSE RETURN Cgen.OpJz
  END
END RelopJccU;

(* ---- expression ---- *)

PROCEDURE ParseExpression;
  VAR rhs: Cgen.Item; op: INTEGER; tsym: Syms.Symbol;
      lhsRec, rhsRec: Syms.TypeDesc;
BEGIN
  ParseSimpleExpression(item);
  IF (sc.sym >= Scan.TEql) & (sc.sym <= Scan.TGeq) THEN
    op := sc.sym; Scan.Next(sc);
    Cgen.CgLoadItem(item);
    IF IsFpuType(item) THEN
      Cgen.CgFpush();
      ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
      IF IsIntType(rhs) THEN
        IF (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
      END;
      Cgen.CgFpop(); Cgen.CgFcmp(FrelopJcc(op));
      item.type := Syms.TypeBoolean; item.mode := Cgen.MReg; RETURN
    END;
    IF (item.type # Syms.NoType) & ((item.type.form = Syms.TFPointer) OR
        (item.type.form = Syms.TFAddress) OR (item.type.form = Syms.TFNiltype) OR
        ((item.type.form = Syms.TFProc) & item.type.isFar)) THEN
      (* Only equality is defined for pointers/procedures.  An ordered relop
         used to fall through silently to the # codegen — wrong runtime
         behaviour with no diagnostic. *)
      IF (op # Scan.TEql) & (op # Scan.TNeq) THEN
        Error("only = and # are defined for pointer/procedure operands")
      END;
      Cgen.EmitCodeStr("52,50");  (* PUSH DX; PUSH AX *)
      ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
      Cgen.CgPtrCmpEq();
      IF op = Scan.TEql THEN Cgen.CgSetcc(Cgen.OpJz) ELSE Cgen.CgSetcc(Cgen.OpJnz) END
    ELSIF (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint) THEN
      Cgen.CgPushDxax();
      ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
      IF IsFpuType(rhs) THEN
        Cgen.Emit1(058H); Cgen.Emit1(05AH); CoerceDxaxToFpu();
        Cgen.CgFcmp(FrelopJcc(op));
        item.type := Syms.TypeBoolean; item.mode := Cgen.MReg; RETURN
      END;
      IF (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
        (* Widen rhs to 32 bits with the SAME rule as the +/- path: WORD/BYTE/
           CHAR/BOOLEAN are unsigned -> zero-extend; only signed INTEGER gets
           CWD.  (CWD on a WORD >= 32768 made it negative and the LONGINT
           comparison wrong.) *)
        IF (rhs.type.form = Syms.TFWord) OR (rhs.type.form = Syms.TFByte)
            OR (rhs.type.form = Syms.TFChar) OR (rhs.type.form = Syms.TFBoolean) THEN
          Cgen.Emit2(033H, 0D2H)   (* XOR DX,DX *)
        ELSE
          Cgen.Emit1(099H)         (* CWD *)
        END
      END;
      Cgen.CgPopCxbx();
      CASE op OF
        Scan.TEql: Cgen.CgCmp32Eq()
      | Scan.TNeq: Cgen.CgCmp32Neq()
      | Scan.TLss: Cgen.CgCmp32Bool(07CH, 07FH, 072H)
      | Scan.TGtr: Cgen.CgCmp32Bool(07FH, 07CH, 077H)
      | Scan.TLeq: Cgen.CgCmp32Bool(07CH, 07FH, 076H)
      | Scan.TGeq: Cgen.CgCmp32Bool(07FH, 07CH, 073H)
      ELSE Cgen.CgCmp32Eq()
      END
    ELSE
      Cgen.Emit1(BYTE(Cgen.OpPushAx));
      ParseSimpleExpression(rhs);
      (* ARRAY OF CHAR vs "" (empty, size=1): mask LHS low byte, load RHS as byte. *)
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFArray) &
         (item.type.elem # NIL) & (item.type.elem.form = Syms.TFChar) &
         (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFArray) &
         (rhs.type.elem # NIL) & (rhs.type.elem.form = Syms.TFChar) &
         (rhs.type.size = 1) THEN
        (* POP AX; AND AX,00FFh; PUSH AX -- mask pushed LHS to low byte *)
        Cgen.Emit1(058H);
        Cgen.Emit3(025H, 0FFH, 000H);
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        rhs.type := Syms.TypeChar
      (* CHAR vs single-char string literal (e.g. `c >= "0"`, c: CHAR): the
         string side is really a char in disguise (LEN 2 = one char + NUL),
         a common idiom, and this compiles correctly as-is since CgLoadItem
         below loads the string's first byte address / the char's byte value
         and CgCmp compares words — no array-vs-array string-compare codegen
         is needed because one side isn't actually array-shaped at runtime. *)
      ELSIF ((item.type # Syms.NoType) & (item.type.form = Syms.TFChar) &
             (rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFArray) &
             (rhs.type.elem # NIL) & (rhs.type.elem.form = Syms.TFChar) &
             (rhs.type.size = 2)) OR
            ((rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFChar) &
             (item.type # Syms.NoType) & (item.type.form = Syms.TFArray) &
             (item.type.elem # NIL) & (item.type.elem.form = Syms.TFChar) &
             (item.type.size = 2)) THEN
        (* fall through unchanged — same codegen as before this fix *)
      (* Any other ARRAY OF CHAR relop operand: this dialect has no
         string-compare codegen (only the s="" byte-mask case above), so a
         generic array falls through to a 2-byte word compare of just the
         first two characters — silently wrong for s1=s2, s1<s2, etc.  Reject
         at compile time rather than emit a codegen path that computes the
         wrong answer; use Strings.Equal or a manual char-by-char loop. *)
      ELSIF ((item.type # Syms.NoType) & (item.type.form = Syms.TFArray) &
             (item.type.elem # NIL) & (item.type.elem.form = Syms.TFChar)) OR
            ((rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFArray) &
             (rhs.type.elem # NIL) & (rhs.type.elem.form = Syms.TFChar)) THEN
        Error("relational operators on ARRAY OF CHAR are not supported (except comparing to an empty string literal); use Strings.Equal")
      END;
      Cgen.CgLoadItem(rhs);
      IF IsFpuType(rhs) THEN
        Cgen.Emit1(058H); CoerceAxToFpu();
        Cgen.CgFcmp(FrelopJcc(op));
        item.type := Syms.TypeBoolean; item.mode := Cgen.MReg; RETURN
      END;
      Cgen.Emit1(BYTE(Cgen.OpPopCx)); Cgen.CgCmp();
      IF ((item.type # Syms.NoType) & (item.type.form = Syms.TFWord)) OR
         ((rhs.type # Syms.NoType) & (rhs.type.form = Syms.TFWord)) THEN
        Cgen.CgSetcc(RelopJccU(op))
      ELSE
        Cgen.CgSetcc(RelopJcc(op))
      END
    END;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  ELSIF sc.sym = Scan.TIn THEN
    Scan.Next(sc);
    Cgen.CgLoadItem(item); Cgen.Emit1(BYTE(Cgen.OpPushAx));
    ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
    Cgen.EmitCodeStr("89,C3,58,8A,C8");   (* MOV BX,AX; POP AX; MOV CL,AL *)
    Cgen.Emit1(0B8H); Cgen.EmitW(0001H);  (* MOV AX,1 *)
    (* `x IN s` with x >= 16 must be deterministically FALSE: without this
       guard the raw `SHL AX,CL` result was CPU-dependent (8086 shifts by the
       full CL and yields 0; 286+ masks CL mod 32, so `33 IN s` behaved like
       `1 IN s`).  CMP CL,16; JB +2; XOR AX,AX — AX=0 shifted is still 0. *)
    Cgen.EmitCodeStr("80,F9,10,72,02,33,C0");
    Cgen.CgShlCl();
    Cgen.Emit2(085H, 0C3H);
    Cgen.CgSetcc(Cgen.OpJnz);
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  ELSIF sc.sym = Scan.TIs THEN
    (* IS type test *)
    Scan.Next(sc);
    IF (item.type = Syms.NoType) OR (item.type.form # Syms.TFPointer) THEN
      Error("IS: left operand must be a POINTER");
      item.type := Syms.TypeBoolean; item.mode := Cgen.MConst; item.val := 0; RETURN
    END;
    lhsRec := item.type.base;
    IF sc.sym # Scan.TIdent THEN
      Error("IS: right operand must be a type name");
      item.type := Syms.TypeBoolean; item.mode := Cgen.MConst; item.val := 0; RETURN
    END;
    tsym := Syms.SymFind(sc.id); Scan.Next(sc);
    IF (tsym = Syms.NoSym) OR (tsym.kind # Syms.KType) OR (tsym.type = Syms.NoType) THEN
      Error("IS: right operand must be a type name");
      item.type := Syms.TypeBoolean; item.mode := Cgen.MConst; item.val := 0; RETURN
    END;
    rhsRec := tsym.type;
    IF rhsRec.form = Syms.TFPointer THEN rhsRec := rhsRec.base END;
    IF (rhsRec = Syms.NoType) OR (rhsRec.form # Syms.TFRecord) OR
       (lhsRec = Syms.NoType) OR (lhsRec.form # Syms.TFRecord) THEN
      Error("IS: both operands must resolve to RECORD types");
      item.type := Syms.TypeBoolean; item.mode := Cgen.MConst; item.val := 0; RETURN
    END;
    IF Syms.TypeIsExtension(lhsRec, rhsRec) THEN
      Cgen.CgLoadImm(1)
    ELSIF ~Syms.TypeIsExtension(rhsRec, lhsRec) THEN
      Cgen.CgLoadImm(0)
    ELSE
      Cgen.CgIsTagCheck(item, rhsRec.tagId)
    END;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  END
END ParseExpression;

END PExpr.
