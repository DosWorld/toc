(*$D-,O-*)
MODULE PExpr;
IMPORT Scan, Syms, Cgen, Rdoff, Strings, LogErr, StrTab;

(* ---- CondBpNode linked list for &/OR chain backpatches ----
   Mirrors PSTMT.MOD's BpNode exactly (same reason: a &/OR chain of N links
   emits N separate conditional-jump instructions that must all eventually
   be patched to the SAME final target — a single shared Cgen.Backpatch
   variable can only describe one pending jump, so every link but the last
   silently loses its own patch (a real bug found and fixed in "full
   &/OR/~ fusion", see SIZE-REPORT.MD 2.1: the abandoned jump's rel16
   stayed 0, a self-referencing no-op, since only the LAST CgCondNear call's
   Backpatch survived in the shared variable).  Can't reuse PSTMT.BpNode
   directly: PSTMT imports PExpr, not the other way around. *)
TYPE
  CondBpNode* = POINTER TO CondBpNodeDesc;
  CondBpNodeDesc* = RECORD
    bp*:   Cgen.Backpatch;
    next*: CondBpNode
  END;
  (* ParseFactorProc: PExpr2's own ParseFactor signature (PExpr2.MOD split
     out 2026-08-21, OVR-BUG.MD follow-up -- PExpr's own compiled code
     exceeded the overlay buffer's hard architectural ceiling).  Oberon
     forbids circular module imports, so PExpr cannot IMPORT PExpr2 (which
     itself IMPORTs PExpr, for ParseExpression) to call ParseFactor
     directly -- every call site below calls the EXTERNAL ParseFactorExt
     below instead (see that declaration's own comment for why, replacing
     the former ParseFactorHook PROCEDURE-variable design, OVR-BUG.MD
     "Bug 5"). *)
  ParseFactorProc* = PROCEDURE(VAR item: Cgen.Item);

VAR
  sc*:         Scan.Scanner;
  modUsesFpu*: BOOLEAN;
  boundsChk*:  BOOLEAN;
  overlayMode*: BOOLEAN;  (* $O+/$O- : module compiled overlay-eligible (DOCS/OVR.MD §4). *)
  modName*:    ARRAY 33 OF CHAR;
  condBpOomNode: CondBpNode;  (* OOM fallback, mirrors PSTMT.bpOomNode *)
  (* condBpList: the CURRENT condition's pending-jump list, threaded through
     ParseAndTail/ParseOrTail (called from ParseTerm/ParseSimpleExpression's
     fixed, single call sites with no room in their signature for an extra
     VAR parameter without touching the surrounding arithmetic dispatch —
     see SIZE-REPORT.MD 2.1 "full &/OR/~ fusion" for why ParseTerm/
     ParseSimpleExpression's own signatures were deliberately left alone).
     Set by ParseCondExpr immediately before parsing, read back immediately
     after — never held live across any OTHER top-level condition's parse,
     so no save/restore discipline is needed here (unlike Cgen.condArmed,
     which DOES need save/restore because it is read from many unrelated
     recursive descents, not just this one fixed relay point). *)
  condBpList: CondBpNode;
(* ParseFactorExt: OVR-BUG.MD "Bug 5" root-cause fix (2026-08-24).  Used to
   be a PROCEDURE-typed VARIABLE (ParseFactorHook), assigned once at
   startup (PExpr2.WireHook) to PExpr2.ParseFactor's address and called
   indirectly ever after.  That is UNSAFE once PExpr2.MOD's owning
   segment can be evicted and reloaded elsewhere by the $O+ overlay
   manager (as PSTMT.MOD joining the overlay pool exposed, TESTS/FIX/
   PSTHANG.MOD): the cached address goes stale across an eviction, and
   the indirect CALL FAR through it (Cgen.CgCallProcVarBp) bypasses the
   linker's overlay-trap rewrite entirely (that rewrite only ever
   applies to a real CALL FAR RELOC against a known import symbol,
   Link.OnReloc's isOverlayCall check -- never to an indirect call
   through a stored pointer).
   Fixed by declaring ParseFactorExt EXTERNAL against PExpr2's own real
   mangled export name ("PExpr2_ParseFactor") instead: the compiler
   treats an EXTERNAL proc exactly like a real cross-module import
   (Cgen.MImport, PEXPR2.MOD's own designator-resolution comment "EXTERNAL
   proc already has import id"), so every call site below compiles to an
   ordinary Cgen.CgCallFar -- a real CALL FAR RELOC the linker recognizes
   and rewrites into the INT 3Fh overlay trampoline (DOCS/OVR.MD §5) the
   SAME way it already does for every other resident-module call into
   PExpr2.MOD (PARSER.MOD/PSTMT.MOD's own calls into PExpr2, which have
   worked safely since PExpr2.MOD shipped $O+, use exactly this path).
   Every call now re-resolves through the trap on every use -- no
   caching, so no staleness is possible.  The "EXTERNAL <string>" syntax
   (an explicit import-name override, rather than the usual
   <thisModule>_<name> mangling EXTERNAL normally uses) was added to
   PARSER.MOD for this fix; see DOCS/OBERON07.EBN. *)
PROCEDURE ParseFactorExt*(VAR item: Cgen.Item); EXTERNAL "PExpr2_ParseFactor";

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

PROCEDURE IsLex(t: INTEGER):BOOLEAN;
BEGIN
  IF sc.sym = t THEN
    Scan.Next(sc);
    RETURN TRUE
  END;
  RETURN FALSE
END IsLex;

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
  IF item.rootSym # Syms.NoSym THEN item.rootSym.wasRead := TRUE END
END MarkRead;

(* ---- CondBpNode push/patch (mirrors PSTMT.BpPush/BpPatchFree) ---- *)

PROCEDURE CondBpPush(head: CondBpNode): CondBpNode;
  VAR n: CondBpNode;
BEGIN
  NEW(n);
  IF n = NIL THEN
    LogErr.Error("out of memory (backpatch node)");
    RETURN condBpOomNode
  END;
  n^.next := head; RETURN n
END CondBpPush;

(* Patches every pending jump in the list to the CURRENT code position
   (Cgen.CgPatchNear resolves relative to Cgen.CgPc() at the moment it is
   called) — call this exactly where the single `CgPatchNear(jf)` used to
   be called, i.e. once the IF/WHILE body has been fully parsed and we're
   sitting at the "skip body" / "loop exit" address. *)
PROCEDURE CondBpPatchFree*(VAR head: CondBpNode);
  VAR n, nx: CondBpNode;
BEGIN
  n := head;
  WHILE n # NIL DO nx := n^.next; Cgen.CgPatchNear(n^.bp); DISPOSE(n); n := nx END;
  head := NIL
END CondBpPatchFree;

(* ---- forward declarations ---- *)
PROCEDURE ParseExpression*(VAR item: Cgen.Item); FORWARD;
(* ParseCondExpr/ParseCondFactor: branch-mode condition parsing (2.1 "full
   &/OR/~ fusion", see SIZE-REPORT.MD).  Forward-declared here because
   ParseAndTail/ParseOrTail (which appear earlier in this file) call
   ParseCondFactor for a &/OR operand when Cgen.condArmed is set.
   `bpList` accumulates every pending jump that must end up at the SAME
   final target (the IF/WHILE "skip body"/"loop exit" address) — a &/OR
   chain of N links emits N separate conditional jumps, and a single
   Cgen.Backpatch can only describe ONE of them, so every link pushes its
   own node onto this list; the caller (ultimately ParseIf/ParseWhile in
   PSTMT.MOD) patches+frees the whole list once, in place of the single
   Cgen.CgPatchNear(jf) call this replaces. *)
PROCEDURE ParseCondExpr*(VAR item: Cgen.Item; wantTrue: BOOLEAN; VAR bpList: CondBpNode); FORWARD;
PROCEDURE ParseCondFactor(VAR item: Cgen.Item; wantTrue: BOOLEAN; VAR bpList: CondBpNode); FORWARD;

(* ---- type helpers ---- *)

PROCEDURE IsIntConst*(VAR item: Cgen.Item): BOOLEAN;
  VAR f: INTEGER;
BEGIN
  IF (item.mode # Cgen.MConst) OR (item.type = Syms.NoType) THEN RETURN FALSE END;
  f := item.type.form;   (* read the form once *)
  RETURN (f = Syms.TFInteger) OR (f = Syms.TFLongint) OR (f = Syms.TFWord)
END IsIntConst;

(* NearRootMode — §4.1: for an item.nearBase MReg item, the implicit
   segment (DS or SS) is never re-derived from the item itself (adr/mode
   were already overwritten by the indexing/chaining that produced it) --
   it comes from rootSym.level, set once at the designator's root and
   never touched again by any subsequent "." or "[" step (see Cgen.Item's
   own nearBase comment).  level=0 (module-level global) -> DS -> MGlobal;
   level>0 (local/param) -> SS -> MLocal.  Every nearBase consumer site
   calls this instead of inspecting item.mode/adr directly. *)
PROCEDURE NearRootMode*(VAR item: Cgen.Item): INTEGER;
BEGIN
  IF item.rootSym.level = 0 THEN RETURN Cgen.MGlobal ELSE RETURN Cgen.MLocal END
END NearRootMode;

(* IsPow2 — TRUE iff v is a positive power of two (1, 2, 4, 8, ...). *)
PROCEDURE IsPow2*(v: LONGINT): BOOLEAN;
BEGIN
  RETURN (v > LONGINT(0)) & (SYSTEM.AND(v, v - LONGINT(1)) = LONGINT(0))
END IsPow2;

(* Log2 — exponent n for a known positive power of two v (= 2^n). *)
PROCEDURE Log2*(v: LONGINT): INTEGER;
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

PROCEDURE IsFpuType*(VAR it: Cgen.Item): BOOLEAN;
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
PROCEDURE ParseSizeArg*(VAR item: Cgen.Item);
  VAR sym, tsym: Syms.Symbol;
      tkey: ARRAY 66 OF CHAR;
BEGIN
  item.mode := Cgen.MConst;
  item.type := Syms.TypeWord;
  item.val  := 0;
  IF sc.sym # Scan.TIdent THEN Error("type name expected in SIZE"); RETURN END;
  sym := Syms.SymFind(sc.id);
  Scan.Next(sc);
  IF (sym # Syms.NoSym) & (sym.kind = Syms.KImport) & IsLex(Scan.TDot) THEN
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
      Cgen.CgZeroAx();                            (* XOR AX,AX *)
      IF isLong THEN Cgen.CgZeroDx() END;         (* XOR DX,DX *)
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
      Cgen.CgZeroAx();
      IF isLong THEN Cgen.CgZeroDx() END;
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
PROCEDURE CoerceAxToFpu*;
BEGIN
  Cgen.EmitCodeStr("83,EC,02,89,E3,36,89,07,36,DF,07,83,C4,02");
  modUsesFpu := TRUE
END CoerceAxToFpu;

(* SUB SP,4 / MOV BX,SP / SS: MOV [BX],AX / SS: MOV [BX+2],DX / SS: FILD qword [BX] / ADD SP,4 *)
PROCEDURE CoerceDxaxToFpu*;
BEGIN
  Cgen.EmitCodeStr("83,EC,04,89,E3,36,89,07,36,89,57,02,36,DB,07,83,C4,04");
  modUsesFpu := TRUE
END CoerceDxaxToFpu;

PROCEDURE ParseCondAndChain(VAR item: Cgen.Item; wantTrue: BOOLEAN; VAR bpList: CondBpNode);
  VAR rhs: Cgen.Item; chainFalseList: CondBpNode; n: CondBpNode;
BEGIN
  (* chainFalseList is only used as CondBpPush's initial `head` in the
     ~wantTrue branch below; this runtime does NOT zero-init locals (see
     DOCS/IMPLRULE.MD "no zero-init"), so leaving it unset means
     CondBpPush's `n^.next := head` captures garbage, and the later
     CondBpPatchFree(chainFalseList) walk dereferences that garbage as a
     CondBpNode — corrupting an unrelated code address with a bogus patch
     (this was bug 8: a stray patch landing at code offset 0, clobbering an
     earlier procedure's prologue). *)
  chainFalseList := NIL;
  Cgen.CgLoadItem(item); Cgen.CgTestAx();
  IF wantTrue THEN
    n := CondBpPush(bpList); Cgen.CgCondNear(Cgen.OpJz, n^.bp); bpList := n;
    ParseCondFactor(rhs, TRUE, bpList);
    WHILE IsLex(Scan.TAnd) DO
      ParseCondFactor(rhs, TRUE, bpList)
    END
  ELSE
    n := CondBpPush(chainFalseList); Cgen.CgCondNear(Cgen.OpJz, n^.bp); chainFalseList := n;
    ParseCondFactor(rhs, TRUE, chainFalseList);
    WHILE IsLex(Scan.TAnd) DO
      ParseCondFactor(rhs, TRUE, chainFalseList)
    END;
    (* every operand true (fell through) -> chain is TRUE -> branch to bpList's target *)
    n := CondBpPush(bpList); Cgen.CgJmpNear(n^.bp); bpList := n;
    CondBpPatchFree(chainFalseList)
  END;
  item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
END ParseCondAndChain;

(* ParseCondTerm: branch-mode "term" — parses ITS OWN first factor, then
   delegates to ParseCondAndChain if a `&` follows.  Used where a full term
   (not just one factor) is needed in branch mode: ParseOrTail's RHS below,
   since `OR`'s operand is a term per the grammar
   (SimpleExpr = term {addOp term}) and so may itself be a `&`-chain, e.g.
   `(a>b) OR (c<d) & (e<f)`.
   The first factor is parsed via plain ParseFactor (disarmed), NOT
   ParseCondFactor: we don't yet know whether `&` follows (single-token
   lookahead, same reasoning as ParseTerm's own first-factor handling — see
   its comment), so it must always materialize normally first; if no `&`
   follows we then branch on that materialized value ourselves (mirroring
   ParseCondFactor's own bare-boolean fallback exactly); if `&` DOES
   follow, ParseCondAndChain re-tests that same materialized value as its
   first operand, exactly as it expects. *)
PROCEDURE ParseCondTerm(VAR item: Cgen.Item; wantTrue: BOOLEAN; VAR bpList: CondBpNode);
  VAR savedArmed: BOOLEAN; n: CondBpNode;
BEGIN
  savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
  ParseFactorExt(item);
  Cgen.condArmed := savedArmed;
  IF IsLex(Scan.TAnd) THEN
    ParseCondAndChain(item, wantTrue, bpList)
  ELSE
    Cgen.CgLoadItem(item); Cgen.CgTestAx();
    n := CondBpPush(bpList);
    IF wantTrue THEN Cgen.CgCondNear(Cgen.OpJz, n^.bp) ELSE Cgen.CgCondNear(Cgen.OpJnz, n^.bp) END;
    bpList := n;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  END
END ParseCondTerm;

(* Short-circuit AND: `p & q` == `IF p THEN q ELSE FALSE` (Oberon-07 §9.1).
   Only the LHS is unconditionally evaluated; the RHS's parse+emit happens
   only on the path where it's reachable, so a side-effecting or unsafe RHS
   (function call, a divisor guarded by `(n#0) & (x DIV n>0)`) is never
   evaluated when the LHS is already FALSE.
   Two codegen modes:
   - Cgen.condArmed=FALSE (ordinary value context — assignment, actual
     parameter, nested boolean expr, ...): result materializes 0/1 in AX
     exactly as the bitwise-AND path did — UNCHANGED from before 2.1.
   - Cgen.condArmed=TRUE (this whole condition is an IF/WHILE test, reached
     via PExpr.ParseCondExpr): delegates to ParseCondAndChain, which
     branches straight to Cgen.condBp instead of materializing, so a chain
     `p & q & r` compiles to a flat run of "if false, jump to the same
     final target" tests with no intermediate 0/1 anywhere — see
     SIZE-REPORT.MD 2.1 "full &/OR/~ fusion". *)
PROCEDURE ParseAndTail(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; falseBp, joinBp: Cgen.Backpatch;
BEGIN
  IF Cgen.condArmed THEN
    (* condBpList (module-level, see its declaration) accumulates every
       pending jump for the CURRENT condition being parsed by the outermost
       ParseCondExpr call; ParseCondAndChain pushes onto it directly. *)
    ParseCondAndChain(item, Cgen.condWantTrue, condBpList);
    Cgen.condHit := TRUE
  ELSE
    Cgen.CgLoadItem(item);
    Cgen.CgTestAx();
    (* MUST be a near jump: it spans the whole RHS emit (ParseFactor may emit
       an arbitrarily long expression — a >127-byte span in a short Jcc wraps
       the rel8 and jumps backward into mid-instruction; this exact overflow
       broke self-hosting, see opt.md §8). *)
    Cgen.CgCondNear(Cgen.OpJz, falseBp);    (* LHS false -> skip RHS, result FALSE *)
    ParseFactorExt(rhs); Cgen.CgLoadItem(rhs); (* BOOLEAN is always a clean 0/1 -> AX *)
    Cgen.CgJmpNear(joinBp);
    Cgen.CgPatchNear(falseBp);
    Cgen.CgZeroAx();                 (* XOR AX,AX *)
    Cgen.CgPatchNear(joinBp);
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  END
END ParseAndTail;

PROCEDURE ParseTerm(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; op: INTEGER; isLong, isFpu, isWord: BOOLEAN;
      rhsLoaded: BOOLEAN; savedArmed: BOOLEAN;
BEGIN
  (* The FIRST factor must be disarmed too, exactly like every other operand
     parsed via plain ParseFactor in this procedure: at this point we don't
     yet know whether `&` follows (single-token lookahead — the WHILE test
     below hasn't run yet), so if `item` turns out to be a paren'd relop
     and condArmed were left live, ParseFactor's TLparen case would fuse it
     standalone (branch away) via the ordinary CgSetcc relay BEFORE we can
     tell whether a `&` chain continues — leaving `item` in a "already
     branched" state that ParseAndTail's CgLoadItem/CgTestAx would then
     wrongly re-test on stale AX (this was a real, caught-by-testing bug:
     `(a<b) & (c>d)` miscompiled to unconditionally-true).  Disarming here
     means the first operand always materializes normally; if no `&`
     follows, ParseCondExpr's own fallback (CgLoadItem+CgTestAx+CgCondNear)
     handles the "bare boolean" case correctly, exactly as it already did
     for 2.1; if `&` DOES follow, ParseAndTail's armed branch re-tests that
     freshly materialized value, which is exactly what it expects. *)
  savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
  ParseFactorExt(item);
  Cgen.condArmed := savedArmed;
  WHILE (sc.sym = Scan.TStar) OR (sc.sym = Scan.TDiv) OR
        (sc.sym = Scan.TMod)  OR (sc.sym = Scan.TAnd) OR (sc.sym = Scan.TSlash) DO
    op := sc.sym; Scan.Next(sc);
    IF op = Scan.TAnd THEN
      ParseAndTail(item); rhsLoaded := FALSE
    ELSIF IsIntConst(item) & ((op = Scan.TStar) OR (op = Scan.TDiv) OR (op = Scan.TMod)) THEN
      savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
      ParseFactorExt(rhs); Cgen.condArmed := savedArmed;
      IF IsIntConst(rhs) THEN ConstFoldInt(item, op, rhs); rhsLoaded := FALSE
      ELSE
        isLong := Syms.IsForm(item.type, Syms.TFLongint);
        isWord := ~isLong & (Syms.IsForm(item.type, Syms.TFWord) OR
                             Syms.IsForm(rhs.type, Syms.TFWord));
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
      isLong := Syms.IsForm(item.type, Syms.TFLongint);
      isWord := ~isLong & ~isFpu & Syms.IsForm(item.type, Syms.TFWord);
      IF Syms.IsForm(item.type, Syms.TFSet) THEN
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseFactorExt(rhs); Cgen.condArmed := savedArmed;
        Cgen.CgLoadItem(rhs);
        Cgen.Emit1(BYTE(Cgen.OpPopCx));
        IF      op = Scan.TStar  THEN Cgen.CgAnd()
        ELSIF   op = Scan.TSlash THEN Cgen.CgXor()
        ELSE Error("operator not supported for SET") END;
        item.type := Syms.TypeSet; item.mode := Cgen.MReg;
        rhsLoaded := FALSE
      ELSIF isFpu THEN
        Cgen.CgFpush();
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseFactorExt(rhs); Cgen.condArmed := savedArmed;
        Cgen.CgLoadItem(rhs);
        IF IsIntType(rhs) THEN
          IF Syms.IsForm(rhs.type, Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
        END;
        Cgen.CgFpop();
        CASE op OF
          Scan.TStar:  Cgen.CgFmul()
        | Scan.TSlash: Cgen.Emit2(0DEH, 0F1H)
        ELSE Error("operator not supported for REAL") END;
        IF Syms.IsForm(item.type, Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
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
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseFactorExt(rhs); Cgen.condArmed := savedArmed;
        IF ~isLong & Syms.IsForm(rhs.type, Syms.TFWord) THEN isWord := TRUE END;
        IF IsIntConst(rhs) &
           ((op = Scan.TStar) OR (op = Scan.TDiv) OR (op = Scan.TMod)) &
           StrengthReducible(op, rhs.val, isLong) THEN
          IF isLong THEN Cgen.CgPopAxdx()   (* POP AX; POP DX *)
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
          Cgen.CgPopAxdx(); CoerceDxaxToFpu()  (* POP AX; POP DX *)
        ELSE Cgen.Emit1(BYTE(Cgen.OpPopAx)); CoerceAxToFpu() END;
        CASE op OF
          Scan.TStar:  Cgen.CgFmul()
        | Scan.TSlash: Cgen.Emit2(0DEH, 0F1H)
        ELSE Error("operator not supported for mixed int/REAL") END;
        IF Syms.IsForm(rhs.type, Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
        ELSE item.type := Syms.TypeReal END;
        item.mode := Cgen.MFreg
      ELSIF isLong THEN
        IF (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
          (* widen rhs to 32-bit: WORD/BYTE/CHAR/BOOLEAN are unsigned → zero-extend
             (XOR DX,DX); only signed INTEGER sign-extends (CWD). *)
          IF (rhs.type.form = Syms.TFWord) OR (rhs.type.form = Syms.TFByte)
              OR (rhs.type.form = Syms.TFChar) OR (rhs.type.form = Syms.TFBoolean) THEN
            Cgen.CgZeroDx()
          ELSE Cgen.CgCwd() END
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
      chainTrueList: CondBpNode; n: CondBpNode;
BEGIN
  (* chainTrueList must start NIL for the same reason as ParseCondAndChain's
     chainFalseList (see its comment) — an uninitialized local here fed
     garbage into CondBpPush/CondBpPatchFree and was bug 8's root cause. *)
  chainTrueList := NIL;
  IF Cgen.condArmed THEN
    (* Mirrors ParseAndTail's armed branch with OR's opposite short-circuit
       polarity ("one true operand makes the whole chain true"), and
       likewise consumes the WHOLE `OR`-chain here (not just the one link
       that made ParseSimpleExpression's loop call us) for the same reason:
       the fused path never leaves a reloadable value in `item` between
       links.  Each operand's jump goes onto a CondBpNode list (module-level
       condBpList, same relay ParseAndTail uses) rather than a single
       Backpatch — see ParseCondAndChain's history note for why a shared
       single Backpatch loses every link but the last.
       - condWantTrue=FALSE (branch to condBpList when the chain is TRUE):
         each link can branch straight there the moment it's true — no
         accumulator needed, this is OR's natural short-circuit direction.
       - condWantTrue=TRUE (branch to condBpList when the chain is FALSE,
         i.e. only once EVERY operand is false): a single false operand
         does NOT prove the chain false (a later operand could still be
         true), so each link is evaluated against a LOCAL "some operand
         true" list instead, and only once every operand has fallen
         through (all false) do we branch to condBpList. *)
    Cgen.CgLoadItem(item); Cgen.CgTestAx();
    IF ~Cgen.condWantTrue THEN
      n := CondBpPush(condBpList); Cgen.CgCondNear(Cgen.OpJnz, n^.bp); condBpList := n;
      ParseCondTerm(rhs, FALSE, condBpList);
      WHILE IsLex(Scan.TOr) DO
        ParseCondTerm(rhs, FALSE, condBpList)
      END
    ELSE
      n := CondBpPush(chainTrueList); Cgen.CgCondNear(Cgen.OpJnz, n^.bp); chainTrueList := n;
      ParseCondTerm(rhs, FALSE, chainTrueList);
      WHILE IsLex(Scan.TOr) DO
        ParseCondTerm(rhs, FALSE, chainTrueList)
      END;
      (* every operand false (fell through) -> chain is FALSE -> branch to condBpList *)
      n := CondBpPush(condBpList); Cgen.CgJmpNear(n^.bp); condBpList := n;
      CondBpPatchFree(chainTrueList)
    END;
    Cgen.condHit := TRUE;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  ELSE
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
  END
END ParseOrTail;

PROCEDURE ParseSimpleExpression(VAR item: Cgen.Item);
  VAR rhs: Cgen.Item; op: INTEGER; negate, isFpu, isLong, isWord, isAddr: BOOLEAN;
      rhsLoaded: BOOLEAN; savedArmed: BOOLEAN;
BEGIN
  (* condArmed (see PExpr.ParseCondExpr / CGEN.MOD "condition-fusion
     single-frame relay") is deliberately left LIVE across the call to
     ParseTerm(item) below: `item` here is either the whole condition's
     SimpleExpr (when this is ParseExpression's LHS call with no relop
     following) or the LHS of a relop (never boolean, so any `&`/`OR` seen
     inside ParseTerm can only belong to the FIRST case) — so ParseTerm's
     own `&` dispatch (ParseAndTail) and this procedure's `OR` dispatch
     (ParseOrTail) below correctly see condArmed exactly when they are the
     condition's own top-level chain link, with no explicit re-arming
     needed.  A unary `-`/`+` prefix never precedes a boolean SimpleExpr in
     valid Oberon (negation isn't defined on BOOLEAN), so `negate` and
     condArmed are mutually exclusive in practice; disarming isn't needed
     for the negate path either.  Every OTHER recursive descent from this
     procedure — the arithmetic RHS operand of `+`/`-` below — is
     explicitly disarmed at its own call site instead (never a boolean
     chain operand), narrower and more precise than the previous blanket
     disarm-for-the-whole-body (see SIZE-REPORT.MD 2.1 "full &/OR/~
     fusion" for the history: the blanket disarm was correct for single-
     comparison fusion but starved the chain fusion of the armed state it
     needs to reach ParseAndTail/ParseOrTail). *)
  negate := FALSE;
  IF IsLex(Scan.TMinus) THEN negate := TRUE ELSE IsLex(Scan.TPlus) END;
  ParseTerm(item);
  IF negate THEN
    IF (item.mode = Cgen.MConst) & ~IsFpuType(item) THEN
      item.val := -item.val;
      (* Negation is a SIGNED operation: `-40000` etc. must not stay
         WORD-typed (WORD operands force unsigned comparisons).  A negated
         WORD constant becomes INTEGER when it fits, else LONGINT. *)
      IF Syms.IsForm(item.type, Syms.TFWord) THEN
        IF (item.val >= LONGINT(-32768)) & (item.val <= LONGINT(32767)) THEN
          item.type := Syms.TypeInteger
        ELSE
          item.type := Syms.TypeLongint
        END
      END
    ELSE
      Cgen.CgLoadItem(item);
      IF Syms.IsForm(item.type, Syms.TFLongint) THEN Cgen.CgNeg32(); item.mode := Cgen.MReg
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
      (* arithmetic RHS: never a boolean chain operand — disarm so a nested
         paren'd condition inside rhs can't steal the outer branch target. *)
      savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
      ParseTerm(rhs);
      Cgen.condArmed := savedArmed;
      IF IsIntConst(rhs) THEN ConstFoldInt(item, op, rhs); rhsLoaded := FALSE
      ELSE
        isLong := Syms.IsForm(item.type, Syms.TFLongint);
        isWord := ~isLong & (Syms.IsForm(item.type, Syms.TFWord) OR
                             Syms.IsForm(rhs.type, Syms.TFWord));
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
      isLong := Syms.IsForm(item.type, Syms.TFLongint);
      isWord := ~isLong & ~isFpu & Syms.IsForm(item.type, Syms.TFWord);
      isAddr := Syms.IsForm(item.type, Syms.TFAddress);
      IF isAddr & ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
        (* SYSTEM.ADDRESS +/- offset: offset-only 16-bit math, segment (DX)
           preserved across the rhs evaluation.  PUSH DX (seg), PUSH AX (ofs);
           eval rhs → AX = step.lo; POP CX = old ofs; ADD/SUB AX,CX; POP DX =
           saved seg.  Result keeps the ADDRESS type (DX:AX). *)
        Cgen.Emit1(BYTE(Cgen.OpPushDx));
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseTerm(rhs); Cgen.condArmed := savedArmed;
        Cgen.CgLoadItem(rhs);
        Cgen.Emit1(BYTE(Cgen.OpPopCx));        (* CX = old ofs *)
        IF op = Scan.TPlus THEN Cgen.CgAdd() ELSE Cgen.CgSub() END;
        Cgen.Emit1(BYTE(Cgen.OpPopDx));        (* DX = saved seg *)
        item.type := Syms.TypeAddress; item.mode := Cgen.MReg; rhsLoaded := FALSE
      ELSIF Syms.IsForm(item.type, Syms.TFSet) THEN
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseTerm(rhs); Cgen.condArmed := savedArmed;
        Cgen.CgLoadItem(rhs); Cgen.Emit1(BYTE(Cgen.OpPopCx));
        IF op = Scan.TPlus THEN Cgen.CgOr()
        ELSIF op = Scan.TMinus THEN Cgen.Emit2(0F7H, 0D0H); Cgen.CgAnd()
        ELSE Error("operator not supported for SET in expr") END;
        item.type := Syms.TypeSet; item.mode := Cgen.MReg; rhsLoaded := FALSE
      ELSIF isFpu THEN
        Cgen.CgFpush();
        savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
        ParseTerm(rhs); Cgen.condArmed := savedArmed;
        Cgen.CgLoadItem(rhs);
        IF IsIntType(rhs) THEN
          IF Syms.IsForm(rhs.type, Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
        END;
        Cgen.CgFpop();
        IF op = Scan.TPlus THEN Cgen.CgFadd() ELSE Cgen.Emit2(0DEH, 0E1H) END;
        item.mode := Cgen.MFreg; rhsLoaded := FALSE
      ELSE
        IF isLong THEN
          Cgen.CgPushDxax();
          savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
          ParseTerm(rhs); Cgen.condArmed := savedArmed;
          (* x + 0 / x - 0 = x : pop the variable back and emit nothing. *)
          IF IsIntConst(rhs) & (rhs.val = LONGINT(0)) &
             ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
            Cgen.CgPopAxdx();   (* POP AX; POP DX *)
            item.type := Syms.TypeLongint;
            item.mode := Cgen.MReg; rhsLoaded := FALSE
          ELSE
            Cgen.CgLoadItem(rhs);
            rhsLoaded := TRUE
          END
        ELSE
          (* Fast path (DOCS/CODEGEN-SIZE.MD §3/§6b): LHS is pushed
             UNCONDITIONALLY, exactly as before this change — parsing rhs
             (e.g. array-index arithmetic for `ga[i]`, still ending in
             MReg) can clobber AX along the way even when the FINAL rhs
             item looks like a safe MGlobal/MLocal operand at first
             glance, so the push cannot be safely deferred past
             ParseTerm.  (Found by a real test failure, not reasoned out
             on paper — see this comment's own history.)  What phase 1
             actually saves is the LOAD+POP-into-CX/register-shuffle
             step: when rhs turns out to be a plain, unloaded
             MGlobal/MLocal item (no isRef), LHS is popped straight back
             into AX and combined directly against rhs's memory location
             — no CgLoadItem(rhs), no second register, no `mov bx,ax`
             shuffle — instead of the full push/load-into-AX/pop-into-CX/
             combine-in-CX shape every other case still uses. *)
          Cgen.Emit1(BYTE(Cgen.OpPushAx));
          savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
          ParseTerm(rhs); Cgen.condArmed := savedArmed;
          IF Syms.IsForm(rhs.type, Syms.TFWord) THEN isWord := TRUE END;
          IF ((rhs.mode = Cgen.MGlobal) OR (rhs.mode = Cgen.MLocal)) & ~rhs.isRef &
             ~IsFpuType(rhs) &
             ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
            (* memory-source ADD/SUB: POP LHS back into AX (undoing
               whatever rhs's own parse did to AX), then combine straight
               from rhs's memory location — no CgLoadItem(rhs) needed.
               ~IsFpuType(rhs) excludes "INTEGER + REAL" (item.type drove
               isFpu above, so an INTEGER LHS with a REAL rhs — a real,
               live case, TESTS/FIX/COE49G.MOD — would otherwise wrongly
               take this integer-only path against a REAL's memory
               location; that case is handled below by the existing
               rhsLoaded + IsFpuType(rhs) fallback, unchanged). *)
            Cgen.Emit1(BYTE(Cgen.OpPopAx));
            IF rhs.mode = Cgen.MLocal THEN
              IF op = Scan.TPlus THEN Cgen.CgAddMemBp(rhs.adr) ELSE Cgen.CgSubMemBp(rhs.adr) END
            ELSE
              IF op = Scan.TPlus THEN Cgen.CgAddMemGlobal(WORD(rhs.adr)) ELSE Cgen.CgSubMemGlobal(WORD(rhs.adr)) END
            END;
            IF isWord THEN item.type := Syms.TypeWord ELSE item.type := Syms.TypeInteger END;
            item.mode := Cgen.MReg; rhsLoaded := FALSE
          (* x + 0 / x - 0 = x : pop the variable back and emit nothing. *)
          ELSIF IsIntConst(rhs) & (rhs.val = LONGINT(0)) &
             ((op = Scan.TPlus) OR (op = Scan.TMinus)) THEN
            Cgen.Emit1(BYTE(Cgen.OpPopAx));
            IF isWord THEN item.type := Syms.TypeWord ELSE item.type := Syms.TypeInteger END;
            item.mode := Cgen.MReg; rhsLoaded := FALSE
          ELSE
            Cgen.CgLoadItem(rhs);
            rhsLoaded := TRUE
          END
        END
      END
    END;
    IF rhsLoaded THEN
      IF IsFpuType(rhs) THEN
        IF isLong THEN
          Cgen.CgPopAxdx(); CoerceDxaxToFpu()  (* POP AX; POP DX *)
        ELSE Cgen.Emit1(BYTE(Cgen.OpPopAx)); CoerceAxToFpu() END;
        IF op = Scan.TPlus THEN Cgen.CgFadd() ELSE Cgen.Emit2(0DEH, 0E1H) END;
        IF Syms.IsForm(rhs.type, Syms.TFLongreal) THEN item.type := Syms.TypeLongreal
        ELSE item.type := Syms.TypeReal END;
        item.mode := Cgen.MFreg
      ELSE
        IF ~isLong & Syms.IsForm(rhs.type, Syms.TFLongint) THEN
          Error("mixed INTEGER/LONGINT: use LONGINT() cast")
        END;
        IF isLong & (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
          (* widen rhs to 32-bit: WORD/BYTE/CHAR/BOOLEAN unsigned → zero-extend
             (XOR DX,DX); signed INTEGER → sign-extend (CWD).  A WORD >= 32768
             (e.g. a 37 KB code-group length) must NOT sign-extend. *)
          IF (rhs.type.form = Syms.TFWord) OR (rhs.type.form = Syms.TFByte)
              OR (rhs.type.form = Syms.TFChar) OR (rhs.type.form = Syms.TFBoolean) THEN
            Cgen.CgZeroDx()
          ELSE Cgen.CgCwd() END
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

(* ParseCondFactor: branch-mode counterpart of ParseFactor, used ONLY as the
   RHS operand of a `&`/`OR` link when Cgen.condArmed is set (called from
   ParseAndTail/ParseOrTail below).  A `factor` never directly contains a
   relop (relops exist only at the `expr` level, reachable from a factor
   solely via `"(" expr ")"` — see DOCS/OBERON07.EBN), so the only two
   recursable boolean shapes at this level are `~x` and `(expr)`; anything
   else (bare BOOLEAN variable/call) has nothing further to fuse and falls
   back to plain ParseFactor + materialize + branch — identical codegen to
   the pre-2.1 path for that shape. *)
PROCEDURE ParseCondFactor;
  VAR n: CondBpNode; savedArmed: BOOLEAN;
BEGIN
  IF IsLex(Scan.TNot) THEN
    ParseCondFactor(item, ~wantTrue, bpList);
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  ELSIF IsLex(Scan.TLparen) THEN
    ParseCondExpr(item, wantTrue, bpList);
    Expect(Scan.TRparen)
  ELSE
    (* Bare boolean (variable/call): may itself contain nested parenthesized
       sub-expressions (e.g. an index or actual-parameter expression reached
       through ParseFactor->ParseDesignator/ParseActualParameters) that pass
       back through ParseFactor's own TLparen branch.  condArmed must be
       disarmed here exactly like ParseTerm's first-factor call, else such a
       nested paren'd relop would wrongly self-fuse as if IT were the
       condition, corrupting this call's own bpList/AX bookkeeping (same bug
       class as bug 2 / bug 7). *)
    savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
    ParseFactorExt(item);
    Cgen.condArmed := savedArmed;
    Cgen.CgLoadItem(item); Cgen.CgTestAx();
    n := CondBpPush(bpList);
    IF wantTrue THEN Cgen.CgCondNear(Cgen.OpJz, n^.bp) ELSE Cgen.CgCondNear(Cgen.OpJnz, n^.bp) END;
    bpList := n;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  END
END ParseCondFactor;

(* ---- condition-fused expression entry (2.1 condition-context fusion) ----
   Used only by IF/WHILE conditions: parses a full boolean expression,
   branching straight to `bp` when the condition is not `wantTrue`, WITHOUT
   materializing an intermediate 0/1 in AX, for both shapes a condition can
   take:
     - a single relational/IN/IS comparison (e.g. `a<b`) funnels through
       Cgen.CgSetcc's single-frame relay (the original 2.1 slice);
     - a `&`/`OR`/`~` chain (e.g. `(a<b) & ~c`) is walked by ParseAndTail/
       ParseOrTail themselves, which check Cgen.condArmed and branch each
       link straight to Cgen.condBp instead of materializing, when armed
       (see "full &/OR/~ fusion" below) — reached via ParseExpression's
       normal call into ParseSimpleExpression/ParseTerm, no separate
       grammar-layer parser needed.
   Only a bare BOOLEAN variable/call (nothing left to fuse) still
   materializes-then-tests, exactly as before 2.1. *)
PROCEDURE ParseCondExpr;
  VAR savedArmed, savedWantTrue: BOOLEAN; savedCondBp: Cgen.Backpatch;
      savedBpList, result: CondBpNode; n: CondBpNode; hit: BOOLEAN;
      mark: Scan.Scanner; markPos: LONGINT; wholeNegation: BOOLEAN;
BEGIN
  (* §2.2 (DOCS/CODEGEN-SIZE.MD): `IF ~x THEN`/`WHILE ~x DO` — a leading
     `~` whose operand is THIS CALL'S ENTIRE condition (nothing else
     follows: the next token is a genuine condition terminator, never an
     operator that could extend the expression) — compiles directly by
     flipping wantTrue and recursing on the un-negated operand, instead of
     materializing the negation into AX and then re-testing it (the
     original §4.5/2.2 finding).  Deliberately narrow and self-contained:
     this does NOT touch `~` used mid-chain (`~a & b`, `a & ~b`) or as a
     plain boolean VALUE (`y := ~x`) — Oberon's grammar binds `~` at the
     tightest (factor) level, so `~a & b` parses as `(~a) & b`, and
     naively treating a leading `~` as negating the WHOLE condition would
     silently miscompile that shape.

     Two sub-shapes, handled differently:
     - `~(expr)`: the paren is self-delimiting (matched by Expect(TRparen)
       below) — no lookahead ambiguity at all about what the `~` applies
       to, so this recurses straight into the ARMED ParseCondFactor-style
       path (the exact machinery ParseCondFactor's own TLparen case
       already uses correctly, see its header comment) with wantTrue
       flipped, letting any nested relop/`&`/`OR` inside the parens fuse
       normally.  Verified by disassembly (2026-08-19 CGPAT spot-check)
       that omitting this case left `IF ~(x > 0) THEN` fully
       materializing — `~(expr)` is common enough (e.g. `NegatedCond` in
       TET/CGPAT.MOD) that skipping it left the fix's biggest single
       target essentially unfixed for this shape.
     - `~x` (bare factor, no parens): marked lookahead (Scan.Mark/Restore)
       checks whether the next token is a genuine condition terminator
       (`THEN`/`DO`/`UNTIL`/`ELSIF`) — if the guess is wrong, the token
       stream is rewound and the original materialize-then-test path runs
       completely unchanged, so there is no way this fast path can
       produce different code from the slow path except in the exact case
       it was designed for. *)
  wholeNegation := FALSE;
  IF sc.sym = Scan.TNot THEN
    Scan.Mark(sc, mark, markPos);
    Scan.Next(sc);
    IF sc.sym = Scan.TLparen THEN
      Scan.Next(sc);
      ParseCondExpr(item, ~wantTrue, bpList);
      Expect(Scan.TRparen);
      RETURN
    END;
    savedArmed := Cgen.condArmed; Cgen.condArmed := FALSE;
    ParseFactorExt(item);
    Cgen.condArmed := savedArmed;
    wholeNegation := (sc.sym = Scan.TThen) OR (sc.sym = Scan.TDo) OR
                     (sc.sym = Scan.TUntil) OR (sc.sym = Scan.TElsif);
    IF ~wholeNegation THEN Scan.Restore(sc, mark, markPos) END
  END;
  IF wholeNegation THEN
    (* The negated operand is already parsed into `item` (disarmed, so any
       nested paren'd relop inside it materialized normally — safe).  Emit
       a normal materialize-then-test on the UN-negated item, but with the
       branch sense flipped, which is exactly what "branch on NOT x" means
       and needs no CgBoolNot at all. *)
    Cgen.CgLoadItem(item); Cgen.CgTestAx();
    n := CondBpPush(bpList);
    IF wantTrue THEN Cgen.CgCondNear(Cgen.OpJnz, n^.bp)
    ELSE Cgen.CgCondNear(Cgen.OpJz, n^.bp)
    END;
    bpList := n;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg;
    RETURN
  END;
  (* condBpList (module-level relay, see its declaration) is how
     ParseAndTail/ParseOrTail reach back to THIS call's `bpList` without
     ParseTerm/ParseSimpleExpression needing an extra parameter — save/
     restore it exactly like Cgen.condArmed, since a NESTED ParseCondExpr
     call (ParseCondFactor's TLparen case) reuses the same module storage
     for its own, unrelated chain. *)
  savedArmed := Cgen.condArmed; savedWantTrue := Cgen.condWantTrue;
  savedCondBp := Cgen.condBp; savedBpList := condBpList;
  Cgen.condArmed := TRUE; Cgen.condWantTrue := wantTrue; Cgen.condHit := FALSE;
  condBpList := NIL;
  ParseExpression(item);
  Cgen.condArmed := FALSE;   (* disarm unconditionally: catches the case where the
                                 expression never reached a CgSetcc/chain-branch
                                 (bare BOOLEAN variable/call) *)
  hit := Cgen.condHit;
  IF hit THEN
    IF condBpList # NIL THEN
      result := condBpList   (* &/OR chain: ParseAndTail/ParseOrTail already built this list *)
    ELSE
      (* single relop/IN/IS: CgSetcc wrote exactly one Backpatch into
         Cgen.condBp (it doesn't know about lists) — wrap it as a
         one-node list so the caller's patch-the-whole-list step still
         works uniformly regardless of which shape this condition took. *)
      n := CondBpPush(NIL); n^.bp := Cgen.condBp; result := n
    END
  ELSE
    Cgen.CgLoadItem(item); Cgen.CgTestAx();
    n := CondBpPush(NIL);
    (* CgCondNear(Y,bp) branches when Y true.  Branch to bp when condition #
       wantTrue: wantTrue=TRUE -> branch on AX=0 (OpJz); wantTrue=FALSE ->
       branch on AX#0 (OpJnz).  Matches the original ParseIf/ParseWhile
       CgCondNear(Cgen.OpJz, jf) call this replaces. *)
    IF wantTrue THEN Cgen.CgCondNear(Cgen.OpJz, n^.bp)
    ELSE Cgen.CgCondNear(Cgen.OpJnz, n^.bp)
    END;
    result := n
  END;
  Cgen.condArmed := savedArmed; Cgen.condWantTrue := savedWantTrue;
  Cgen.condBp := savedCondBp; condBpList := savedBpList;
  (* append `result` (this call's node(s)) onto the CALLER's list, which may
     already hold earlier links (e.g. ParseCondAndChain's chainFalseList
     recursion) — splice by walking to result's tail, since CondBpPush only
     prepends. `result` is always non-NIL (every branch above sets it). *)
  n := result;
  WHILE n^.next # NIL DO n := n^.next END;
  n^.next := bpList; bpList := result
END ParseCondExpr;


PROCEDURE ParseExpression;
  VAR rhs: Cgen.Item; op: INTEGER; tsym: Syms.Symbol;
      lhsRec, rhsRec: Syms.TypeDesc;
      isFastCmpEligible: BOOLEAN;
BEGIN
  ParseSimpleExpression(item);
  IF (sc.sym >= Scan.TEql) & (sc.sym <= Scan.TGeq) THEN
    op := sc.sym; Scan.Next(sc);
    Cgen.CgLoadItem(item);
    IF IsFpuType(item) THEN
      Cgen.CgFpush();
      ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
      IF IsIntType(rhs) THEN
        IF Syms.IsForm(rhs.type, Syms.TFLongint) THEN CoerceDxaxToFpu() ELSE CoerceAxToFpu() END
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
    ELSIF Syms.IsForm(item.type, Syms.TFLongint) THEN
      Cgen.CgPushDxax();
      ParseSimpleExpression(rhs); Cgen.CgLoadItem(rhs);
      IF IsFpuType(rhs) THEN
        Cgen.Emit1(BYTE(Cgen.OpPopAx)); Cgen.Emit1(BYTE(Cgen.OpPopDx)); CoerceDxaxToFpu();
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
          Cgen.CgZeroDx()   (* XOR DX,DX *)
        ELSE
          Cgen.CgCwd()         (* CWD *)
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
      (* Fast path (DOCS/CODEGEN-SIZE.MD §6b): LHS is pushed
         UNCONDITIONALLY, exactly as before this change — parsing rhs can
         clobber AX along the way (array-index arithmetic, etc.) even
         when the FINAL rhs item looks like a plain MGlobal/MLocal
         operand, so the push cannot be safely deferred past
         ParseSimpleExpression (found by a real test failure in the +/-
         path above, same root cause applies here).  The
         ARRAY-OF-CHAR/string-literal special-casing below can only
         trigger when item.type or rhs.type is TFChar/TFArray — when
         item's type is a plain scalar, none of those branches can ever
         fire, so it's safe to skip straight to the memory-source CMP
         fast path in that case: POP LHS back into AX (undoing whatever
         rhs's own parse did to it), then compare directly against rhs's
         memory location with no CgLoadItem(rhs) and no second register. *)
      isFastCmpEligible := (item.type # Syms.NoType) &
        ((item.type.form = Syms.TFInteger) OR (item.type.form = Syms.TFWord) OR
         (item.type.form = Syms.TFByte) OR (item.type.form = Syms.TFBoolean));
      Cgen.Emit1(BYTE(Cgen.OpPushAx));
      ParseSimpleExpression(rhs);
      (* §4.3 (DOCS/CODEGEN-SIZE.MD): compare-against-constant.  rhs parsed
         to a bare MConst (integer/word literal, or a named CONST of one of
         those types folded at parse time) needs no register at all on the
         rhs side — CMP AX,imm16 replaces the load-into-register dance the
         memory-operand branch below still needs.  Excludes LONGINT (that
         type never reaches this ELSE branch at all — it's handled by its
         own dedicated 32-bit branch above) and generalizes to any integer
         constant value, not just 0. *)
      IF isFastCmpEligible & IsIntConst(rhs) & (rhs.type # Syms.NoType) &
         (rhs.type.form # Syms.TFLongint) THEN
        Cgen.Emit1(BYTE(Cgen.OpPopAx));
        IF (Syms.IsForm(item.type, Syms.TFWord)) OR
           (Syms.IsForm(rhs.type, Syms.TFWord)) THEN
          Cgen.CgCmpAxImmUnsigned(INTEGER(rhs.val));
          Cgen.CgSetcc(RelopJccU(op))
        ELSE
          Cgen.CgCmpAxImm(INTEGER(rhs.val));
          Cgen.CgSetcc(RelopJcc(op))
        END;
        item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
      ELSIF isFastCmpEligible &
         ((rhs.mode = Cgen.MGlobal) OR (rhs.mode = Cgen.MLocal)) & ~rhs.isRef &
         ~IsFpuType(rhs) THEN
        Cgen.Emit1(BYTE(Cgen.OpPopAx));
        IF rhs.mode = Cgen.MLocal THEN Cgen.CgCmpAxBp(rhs.adr)
        ELSE Cgen.CgCmpMemGlobal(WORD(rhs.adr)) END;
        IF (Syms.IsForm(item.type, Syms.TFWord)) OR
           (Syms.IsForm(rhs.type, Syms.TFWord)) THEN
          Cgen.CgSetcc(RelopJccU(op))
        ELSE
          Cgen.CgSetcc(RelopJcc(op))
        END;
        item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
      ELSE
      (* ARRAY OF CHAR vs "" (empty, size=1): mask LHS low byte, load RHS as byte. *)
      IF Syms.IsForm(item.type, Syms.TFArray) &
         (item.type.elemOrRet # NIL) & (item.type.elemOrRet.form = Syms.TFChar) &
         Syms.IsForm(rhs.type, Syms.TFArray) &
         (rhs.type.elemOrRet # NIL) & (rhs.type.elemOrRet.form = Syms.TFChar) &
         (rhs.type.size = 1) THEN
        (* POP AX; AND AX,00FFh; PUSH AX -- mask pushed LHS to low byte *)
        Cgen.Emit1(BYTE(Cgen.OpPopAx));
        Cgen.Emit3(025H, 0FFH, 000H);
        Cgen.Emit1(BYTE(Cgen.OpPushAx));
        rhs.type := Syms.TypeChar
      (* CHAR vs single-char string literal (e.g. `c >= "0"`, c: CHAR): the
         string side is really a char in disguise (LEN 2 = one char + NUL),
         a common idiom, and this compiles correctly as-is since CgLoadItem
         below loads the string's first byte address / the char's byte value
         and CgCmp compares words — no array-vs-array string-compare codegen
         is needed because one side isn't actually array-shaped at runtime. *)
      ELSIF (Syms.IsForm(item.type, Syms.TFChar) &
             Syms.IsForm(rhs.type, Syms.TFArray) &
             (rhs.type.elemOrRet # NIL) & (rhs.type.elemOrRet.form = Syms.TFChar) &
             (rhs.type.size = 2)) OR
            (Syms.IsForm(rhs.type, Syms.TFChar) &
             Syms.IsForm(item.type, Syms.TFArray) &
             (item.type.elemOrRet # NIL) & (item.type.elemOrRet.form = Syms.TFChar) &
             (item.type.size = 2)) THEN
        (* fall through unchanged — same codegen as before this fix *)
      (* Any other ARRAY OF CHAR relop operand: this dialect has no
         string-compare codegen (only the s="" byte-mask case above), so a
         generic array falls through to a 2-byte word compare of just the
         first two characters — silently wrong for s1=s2, s1<s2, etc.  Reject
         at compile time rather than emit a codegen path that computes the
         wrong answer; use Strings.Equal or a manual char-by-char loop. *)
      ELSIF (Syms.IsForm(item.type, Syms.TFArray) &
             (item.type.elemOrRet # NIL) & (item.type.elemOrRet.form = Syms.TFChar)) OR
            (Syms.IsForm(rhs.type, Syms.TFArray) &
             (rhs.type.elemOrRet # NIL) & (rhs.type.elemOrRet.form = Syms.TFChar)) THEN
        Error("relational operators on ARRAY OF CHAR are not supported (except comparing to an empty string literal); use Strings.Equal")
      END;
      Cgen.CgLoadItem(rhs);
      IF IsFpuType(rhs) THEN
        Cgen.Emit1(BYTE(Cgen.OpPopAx)); CoerceAxToFpu();
        Cgen.CgFcmp(FrelopJcc(op));
        item.type := Syms.TypeBoolean; item.mode := Cgen.MReg; RETURN
      END;
      Cgen.Emit1(BYTE(Cgen.OpPopCx)); Cgen.CgCmp();
      IF (Syms.IsForm(item.type, Syms.TFWord)) OR
         (Syms.IsForm(rhs.type, Syms.TFWord)) THEN
        Cgen.CgSetcc(RelopJccU(op))
      ELSE
        Cgen.CgSetcc(RelopJcc(op))
      END
      END
    END;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  ELSIF IsLex(Scan.TIn) THEN
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
  ELSIF IsLex(Scan.TIs) THEN
    (* IS type test *)
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
      Cgen.CgIsTagCheck(item, rhsRec.tagIdOrNParams)
    END;
    item.type := Syms.TypeBoolean; item.mode := Cgen.MReg
  END
END ParseExpression;

END PExpr.
