MODULE PStmt;
(*
  Statement parser: IF, WHILE, REPEAT, FOR, CASE, RETURN, procedure calls,
  assignment, sysproc calls (NEW/DISPOSE/INC/DEC/ASSERT).
  Uses shared state from PExpr.
*)
IMPORT Scan, Syms, Cgen, Rdoff, PExpr, TDbg, Strings;

(* ---- BpNode linked list for backpatch chains ---- *)

TYPE
  BpNode* = POINTER TO BpNodeDesc;
  BpNodeDesc* = RECORD
    bp*:   Cgen.Backpatch;
    next*: BpNode
  END;

PROCEDURE BpPush(head: BpNode): BpNode;
  VAR n: BpNode;
BEGIN
  NEW(n); n^.next := head; RETURN n
END BpPush;

PROCEDURE BpPatchFree*(VAR head: BpNode);
  VAR n, nx: BpNode;
BEGIN
  n := head;
  WHILE n # NIL DO nx := n^.next; Cgen.CgPatchNear(n^.bp); DISPOSE(n); n := nx END;
  head := NIL
END BpPatchFree;

(* ---- forward declarations ---- *)
PROCEDURE ParseStatementSequence*(retType: Syms.TypeDesc); FORWARD;

(* ---- parse constant CASE label ---- *)

PROCEDURE ParseConstLabel(): INTEGER;
  (* Accept any constant expression (constant folding applies), allowing
     `I.N`, `I.N-1`, `N+1`, etc.  Must reduce to a compile-time INTEGER or
     CHAR constant.  Also accepts a single-character string literal as a
     CHAR constant (Oberon-07: a string of length 1 is type-compatible
     with CHAR). *)
  VAR val: INTEGER; it: Cgen.Item; tt: Syms.TypeDesc;
BEGIN
  PExpr.ParseExpression(it);
  tt := it.type;
  IF (it.mode = Cgen.MConst) & (tt # Syms.NoType) &
     ((tt.form = Syms.TFInteger) OR (tt.form = Syms.TFChar) OR
      (tt.form = Syms.TFWord)) THEN
    val := INTEGER(it.val)
  ELSIF (it.mode = Cgen.MGlobal) & (tt # Syms.NoType) &
        (tt.form = Syms.TFArray) & (tt.len = 2) &
        (tt.elem # Syms.NoType) & (tt.elem.form = Syms.TFChar) THEN
    val := INTEGER(Rdoff.PeekDataByte(Cgen.CgObj, it.adr))
  ELSE
    PExpr.Error("constant expected in CASE label"); val := 0
  END;
  RETURN val
END ParseConstLabel;

(* ---- IF ---- *)

PROCEDURE ParseIf(retType: Syms.TypeDesc);
  VAR cond: Cgen.Item; jf: Cgen.Backpatch; endList: BpNode; more: BOOLEAN;
BEGIN
  Scan.Next(PExpr.sc);  (* consume IF *)
  endList := NIL; more := TRUE;
  WHILE more DO
    PExpr.ParseExpression(cond); Cgen.CgLoadItem(cond);
    Cgen.CgTestAx();
    Cgen.CgCondNear(Cgen.OpJz, jf);
    PExpr.Expect(Scan.TThen);
    ParseStatementSequence(retType);
    endList := BpPush(endList); Cgen.CgJmpNear(endList^.bp);
    Cgen.CgPatchNear(jf);
    IF PExpr.sc.sym = Scan.TElsif THEN Scan.Next(PExpr.sc)
    ELSE more := FALSE
    END
  END;
  IF PExpr.sc.sym = Scan.TElse THEN
    Scan.Next(PExpr.sc); ParseStatementSequence(retType)
  END;
  PExpr.Expect(Scan.TEnd);
  BpPatchFree(endList)
END ParseIf;

(* ---- WHILE ---- *)

PROCEDURE ParseWhile(retType: Syms.TypeDesc);
  VAR cond: Cgen.Item; jf: Cgen.Backpatch; loopTop: LONGINT; more: BOOLEAN;
BEGIN
  Scan.Next(PExpr.sc);
  loopTop := Cgen.CgPc(); more := TRUE;
  WHILE more DO
    PExpr.ParseExpression(cond); Cgen.CgLoadItem(cond);
    Cgen.CgTestAx();
    Cgen.CgCondNear(Cgen.OpJz, jf);
    PExpr.Expect(Scan.TDo);
    ParseStatementSequence(retType);
    Cgen.CgJmpBack(loopTop);
    Cgen.CgPatchNear(jf);
    IF PExpr.sc.sym = Scan.TElsif THEN Scan.Next(PExpr.sc)
    ELSE more := FALSE
    END
  END;
  PExpr.Expect(Scan.TEnd)
END ParseWhile;

(* ---- REPEAT ---- *)

PROCEDURE ParseRepeat(retType: Syms.TypeDesc);
  VAR cond: Cgen.Item; loopTop: LONGINT;
BEGIN
  Scan.Next(PExpr.sc);
  loopTop := Cgen.CgPc();
  ParseStatementSequence(retType);
  PExpr.Expect(Scan.TUntil);
  PExpr.ParseExpression(cond); Cgen.CgLoadItem(cond);
  Cgen.CgTestAx();
  Cgen.CgCondBack(Cgen.OpJz, loopTop)
END ParseRepeat;

(* ---- FOR ---- *)

VAR retPatchList*: BpNode;  (* per-proc RETURN backpatch chain *)
    curProloguePatch*: LONGINT;  (* offset of frame-size word in SUB SP,imm16 *)
    curProcDepth*: INTEGER;

(* Patch the frame-size word (the imm16 of `SUB SP,imm16`) at curProloguePatch
   with the current scope's local size, little-endian.  Called whenever a hidden
   local is allocated after the prologue was already emitted (FOR/CASE
   temporaries) and once at the end of declaration parsing. *)
PROCEDURE PatchFrameSize*;
  VAR sz: INTEGER;
BEGIN
  sz := Syms.SymLocalSize();
  Rdoff.PatchCodeByte(Cgen.CgObj, curProloguePatch,
                      BYTE(SYSTEM.AND(sz, 0FFH)));
  Rdoff.PatchCodeByte(Cgen.CgObj, curProloguePatch + LONGINT(1),
                      BYTE(SYSTEM.AND(SYSTEM.LSR(sz, 8), 0FFH)))
END PatchFrameSize;

PROCEDURE ParseFor(retType: Syms.TypeDesc);
  VAR varSym, limSym: Syms.Symbol; init, dst, v, limItem: Cgen.Item;
      step: LONGINT; loopTop: LONGINT; jend: Cgen.Backpatch; neg: BOOLEAN;
BEGIN
  Scan.Next(PExpr.sc);
  IF PExpr.sc.sym # Scan.TIdent THEN PExpr.Error("identifier expected"); RETURN END;
  varSym := Syms.SymFind(PExpr.sc.id); Scan.Next(PExpr.sc);
  IF (varSym = Syms.NoSym) OR (varSym.type # Syms.TypeInteger) THEN
    PExpr.Error("INTEGER var expected"); RETURN
  END;
  PExpr.Expect(Scan.TAssign);
  PExpr.ParseExpression(init); Cgen.CgLoadItem(init);
  IF varSym.level = 0 THEN dst.mode := Cgen.MGlobal ELSE dst.mode := Cgen.MLocal END;
  dst.adr := varSym.adr; dst.type := Syms.TypeInteger; dst.isRef := FALSE;
  Cgen.CgStoreItem(dst);
  PExpr.Expect(Scan.TTo);
  limSym := Syms.SymNew("$lim", Syms.KVar);
  limSym.type := Syms.TypeInteger;
  Syms.SymAllocLocal(limSym);
  PExpr.ParseExpression(limItem); Cgen.CgLoadItem(limItem);
  v.mode := Cgen.MLocal; v.adr := limSym.adr; v.type := Syms.TypeInteger;
  v.isRef := FALSE;
  Cgen.CgStoreItem(v);
  step := 1; neg := FALSE;
  IF PExpr.sc.sym = Scan.TBy THEN
    Scan.Next(PExpr.sc);
    IF PExpr.sc.sym = Scan.TMinus THEN neg := TRUE; Scan.Next(PExpr.sc) END;
    IF PExpr.sc.sym # Scan.TInt THEN PExpr.Error("constant expected")
    ELSE step := PExpr.sc.ival; IF neg THEN step := -step END END;
    Scan.Next(PExpr.sc)
  END;
  PatchFrameSize;
  PExpr.Expect(Scan.TDo);
  loopTop := Cgen.CgPc();
  v.mode := dst.mode; v.adr := dst.adr; v.type := Syms.TypeInteger; v.isRef := FALSE;
  Cgen.CgLoadItem(v); Cgen.Emit1(BYTE(Cgen.OpPushAx));
  v.mode := Cgen.MLocal; v.adr := limSym.adr;
  Cgen.CgLoadItem(v);
  Cgen.Emit1(BYTE(Cgen.OpPopCx));
  Cgen.CgCmp();
  IF step >= 0 THEN Cgen.CgCondNear(Cgen.OpJg, jend)
  ELSE Cgen.CgCondNear(Cgen.OpJl, jend) END;
  ParseStatementSequence(Syms.TypeNotype);
  v.mode := dst.mode; v.adr := dst.adr; v.isRef := FALSE;
  Cgen.CgLoadItem(v);
  IF step = 1 THEN Cgen.CgIncAx()
  ELSIF step = -1 THEN Cgen.CgDecAx()
  ELSE Cgen.CgLoadImmCx(INTEGER(step)); Cgen.CgAdd() END;
  Cgen.CgStoreItem(dst);
  Cgen.CgJmpBack(loopTop);
  Cgen.CgPatchNear(jend);
  PExpr.Expect(Scan.TEnd)
END ParseFor;

(* ---- CASE ---- *)

(* Reload the hidden $case local into AX.  Re-points `item` at the local each
   call so CgLoadItem emits a fresh MOV AX,[BP+ofs] — every CASE arm reloads
   the selector before comparing. *)
PROCEDURE ReloadCase(VAR item: Cgen.Item; caseSym: Syms.Symbol);
BEGIN
  item.mode := Cgen.MLocal; item.adr := caseSym.adr;
  item.type := Syms.TypeInteger; item.isRef := FALSE;
  Cgen.CgLoadItem(item)
END ReloadCase;

PROCEDURE ParseCase(retType: Syms.TypeDesc);
  VAR caseSym: Syms.Symbol; caseLoad, expr: Cgen.Item; endList: BpNode;
      bodyList: BpNode; skipArm, skipLo: Cgen.Backpatch;
      lo, hi: INTEGER; n: BpNode; more: BOOLEAN;
BEGIN
  Scan.Next(PExpr.sc);
  endList := NIL;
  PExpr.ParseExpression(expr); Cgen.CgLoadItem(expr);
  caseSym := Syms.SymNew("$case", Syms.KVar);
  caseSym.type := Syms.TypeInteger;
  Syms.SymAllocLocal(caseSym);
  caseLoad.mode := Cgen.MLocal; caseLoad.adr := caseSym.adr;
  caseLoad.type := Syms.TypeInteger; caseLoad.isRef := FALSE;
  Cgen.CgStoreItem(caseLoad);
  PatchFrameSize;
  PExpr.Expect(Scan.TOf);

  WHILE (PExpr.sc.sym # Scan.TElse) & (PExpr.sc.sym # Scan.TEnd) &
        (PExpr.sc.sym # Scan.TEof) DO
    bodyList := NIL; more := TRUE;
    WHILE more DO
      lo := ParseConstLabel();
      IF PExpr.sc.sym = Scan.TDotdot THEN
        Scan.Next(PExpr.sc); hi := ParseConstLabel();
        ReloadCase(caseLoad, caseSym);
        Cgen.CgCmpAxImm(lo);
        Cgen.CgCondNear(Cgen.OpJl, skipLo);
        Cgen.CgCmpAxImm(hi);
        n := BpPush(bodyList); Cgen.CgCondNear(Cgen.OpJle, n^.bp); bodyList := n;
        Cgen.CgPatchNear(skipLo)
      ELSE
        ReloadCase(caseLoad, caseSym);
        Cgen.CgCmpAxImm(lo);
        n := BpPush(bodyList); Cgen.CgCondNear(Cgen.OpJz, n^.bp); bodyList := n
      END;
      IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc)
      ELSE more := FALSE
      END
    END;
    Cgen.CgJmpNear(skipArm);
    BpPatchFree(bodyList);
    PExpr.Expect(Scan.TColon);
    ParseStatementSequence(retType);
    n := BpPush(endList); Cgen.CgJmpNear(n^.bp); endList := n;
    Cgen.CgPatchNear(skipArm);
    IF PExpr.sc.sym = Scan.TBar THEN Scan.Next(PExpr.sc) END
  END;
  IF PExpr.sc.sym = Scan.TElse THEN
    Scan.Next(PExpr.sc); ParseStatementSequence(retType)
  END;
  PExpr.Expect(Scan.TEnd);
  BpPatchFree(endList)
END ParseCase;

(* ---- RETURN ---- *)

PROCEDURE ParseReturn(retType: Syms.TypeDesc);
  VAR val: Cgen.Item; n: BpNode;
BEGIN
  Scan.Next(PExpr.sc);
  IF (PExpr.sc.sym # Scan.TSemi) & (PExpr.sc.sym # Scan.TEnd) &
     (PExpr.sc.sym # Scan.TElse) & (PExpr.sc.sym # Scan.TElsif) THEN
    PExpr.ParseExpression(val); Cgen.CgLoadItem(val)
  ELSIF (retType # Syms.NoType) & (retType.form # Syms.TFNotype) THEN
    PExpr.Error("RETURN value required")
  END;
  n := BpPush(retPatchList); Cgen.CgJmpNear(n^.bp); retPatchList := n
END ParseReturn;

(* ---- sysproc call ---- *)

PROCEDURE ParseSysprocCall(id: INTEGER);
  VAR ptr, vitem, vstep, cond, szItem: Cgen.Item; vstore: Cgen.Item;
      errCode: LONGINT; haltId, mAllocId, mFreeId: INTEGER;
      ok, bpNil: Cgen.Backpatch; isTaggedRec: BOOLEAN; sz: LONGINT;
      isLongV, isLongStep, isWordStep, needSaveAddr, saveEsbx: BOOLEAN;
      isAddrV, isByteV, isGlobalV, fastAddr, refFast: BOOLEAN;
      ptt: Syms.TypeDesc;
BEGIN
  PExpr.Expect(Scan.TLparen);
  CASE id OF
    Syms.SpNew:
      PExpr.ParseDesignator(ptr);
      ptt := ptr.type;
      IF (ptt # Syms.NoType) &
         ((ptt.form = Syms.TFPointer) OR (ptt.form = Syms.TFAddress)) THEN
        isTaggedRec := (ptt.form = Syms.TFPointer) & (ptt.base # Syms.NoType) &
                       (ptt.base.form = Syms.TFRecord)
      ELSE PExpr.Error("NEW requires pointer"); isTaggedRec := FALSE END;
      (* If ptr is MReg/isRef (field through pointer, indexed element, etc.)
         ES:BX holds the destination slot's far address.  The size expression
         and CALL FAR SYSTEM_Alloc below will clobber both — save them now,
         restore just before CgStoreItem. *)
      saveEsbx := (ptr.mode = Cgen.MReg) & ptr.isRef;
      IF saveEsbx THEN Cgen.EmitCodeStr("06,53") END;  (* PUSH ES; PUSH BX *)
      mAllocId := PExpr.GetSystemImport("SYSTEM_Alloc");
      IF PExpr.sc.sym = Scan.TComma THEN
        Scan.Next(PExpr.sc);
        PExpr.ParseExpression(szItem); Cgen.CgLoadItem(szItem)
      ELSE
        IF (ptt # Syms.NoType) & (ptt.form = Syms.TFPointer) & (ptt.base # Syms.NoType) THEN
          sz := ptt.base.size
        ELSE sz := 1 END;
        Cgen.CgLoadImm(INTEGER(sz))
      END;
      IF isTaggedRec THEN Cgen.Emit3(083H, 0C0H, 002H) END;
      Cgen.Emit1(BYTE(Cgen.OpPushAx));
      Cgen.CgCallFar(mAllocId);
      IF isTaggedRec THEN
        (* NIL guard: if SYSTEM_Alloc returned NIL (DX:AX = 0:0), skip the
           tag store + INC AX,AX so we don't dereference NIL. *)
        Cgen.Emit2(085H, 0D2H);                 (* TEST DX, DX *)
        Cgen.CgCondShort(074H, bpNil);          (* JZ .skip *)
        Cgen.CgDxaxToEsbx();
        Cgen.CgStoreWordEsbxImm(INTEGER(ptt.base.descOfs));
        Cgen.Emit2(040H, 040H);                 (* INC AX / INC AX *)
        Cgen.CgPatchShort(bpNil)
      END;
      IF saveEsbx THEN Cgen.EmitCodeStr("5B,07") END;  (* POP BX; POP ES *)
      Cgen.CgStoreItem(ptr)

  | Syms.SpDispose:
      PExpr.ParseDesignator(ptr);
      ptt := ptr.type;
      IF (ptt # Syms.NoType) &
         ((ptt.form = Syms.TFPointer) OR (ptt.form = Syms.TFAddress)) THEN
        isTaggedRec := (ptt.form = Syms.TFPointer) & (ptt.base # Syms.NoType) &
                       (ptt.base.form = Syms.TFRecord)
      ELSE PExpr.Error("DISPOSE requires pointer"); isTaggedRec := FALSE END;
      mFreeId := PExpr.GetSystemImport("SYSTEM_Free");
      Cgen.CgLoadItem(ptr);
      IF isTaggedRec THEN
        (* NIL guard: if ptr is NIL (DX:AX = 0:0), skip the SUB AX,2 so we
           don't pass a wrap-around offset to SYSTEM_Free. *)
        Cgen.Emit2(085H, 0D2H);            (* TEST DX, DX *)
        Cgen.CgCondShort(074H, bpNil);     (* JZ .skip *)
        Cgen.Emit3(083H, 0E8H, 002H);      (* SUB AX, 2 *)
        Cgen.CgPatchShort(bpNil)
      END;
      Cgen.Emit1(BYTE(Cgen.OpPushDx));
      Cgen.Emit1(BYTE(Cgen.OpPushAx));
      Cgen.CgCallFar(mFreeId)

  | Syms.SpInc, Syms.SpDec:
      PExpr.ParseDesignator(vitem); vstore := vitem;
      isLongV := (vstore.type # Syms.NoType) & (vstore.type.form = Syms.TFLongint);
      isAddrV := (vstore.type # Syms.NoType) & (vstore.type.form = Syms.TFAddress);
      isByteV := (vstore.type # Syms.NoType) &
                 ((vstore.type.form = Syms.TFChar) OR
                  (vstore.type.form = Syms.TFByte) OR
                  (vstore.type.form = Syms.TFBoolean));
      isGlobalV := vstore.mode = Cgen.MGlobal;
      (* Fast path: a plain near variable at a fixed compile-time displacement
         (MGlobal in DS, or MLocal on BP) that is NOT accessed via a far ref.
         We can emit an INC/DEC/ADD/SUB directly on memory, skipping the
         LOAD+op+STORE round-trip.  isRef (far VAR param, typeless ADDRESS VAR
         param, dereferenced pointer/array element) is excluded — its address
         is not a fixed displacement. *)
      fastAddr := ~vstore.isRef &
                  ((vstore.mode = Cgen.MGlobal) OR (vstore.mode = Cgen.MLocal));
      (* refFast: destination is [ES:BX] — a far VAR param / dereferenced
         pointer / far array element whose far pointer lives in a fixed slot
         (MGlobal/MLocal).  For a constant / implicit-1 step (no step-expr parse
         to clobber ES:BX) we load ES:BX once and emit an ES-override memory-dest
         op.  ADDRESS-isRef is excluded: its slot value IS the address, handled
         by the near path on the slot, not via a deref. *)
      refFast := vstore.isRef & ~isAddrV &
                 ((vstore.mode = Cgen.MGlobal) OR (vstore.mode = Cgen.MLocal));
      IF PExpr.sc.sym = Scan.TComma THEN
        IF refFast THEN
          Scan.Next(PExpr.sc); PExpr.ParseExpression(vstep);
          IF vstep.mode = Cgen.MConst THEN
            (* --- far-ref memory-dest ADD/SUB by a compile-time constant --- *)
            Cgen.CgLesBxItem(vstore.mode, vstore.adr);
            IF isByteV THEN Cgen.CgAddSubEsbxB(id = Syms.SpInc, INTEGER(vstep.val))
            ELSIF isLongV THEN Cgen.CgAddSubEsbxL(id = Syms.SpInc, vstep.val)
            ELSE Cgen.CgAddSubEsbxW(id = Syms.SpInc, INTEGER(vstep.val)) END
          ELSE
            (* far-ref, runtime step: fall back to the general isRef path.
               Reload the dest item and run the original load/save/combine. *)
            vitem := vstore; Cgen.CgLoadItem(vitem);
            Cgen.Emit1(BYTE(Cgen.OpPushEs)); Cgen.Emit1(BYTE(Cgen.OpPushBx));
            IF isLongV THEN Cgen.Emit1(BYTE(Cgen.OpPushDx)) END;
            Cgen.Emit1(BYTE(Cgen.OpPushAx));
            Cgen.CgLoadItem(vstep);
            IF isLongV THEN
              isLongStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFLongint);
              isWordStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFWord);
              IF isWordStep THEN Cgen.Emit2(BYTE(031H), BYTE(0D2H))
              ELSIF ~isLongStep THEN Cgen.Emit1(BYTE(099H)) END;
              Cgen.Emit2(BYTE(089H), BYTE(0C3H)); Cgen.Emit2(BYTE(089H), BYTE(0D1H));
              Cgen.Emit1(BYTE(Cgen.OpPopAx)); Cgen.Emit1(BYTE(Cgen.OpPopDx));
              IF id = Syms.SpInc THEN Cgen.Emit2(BYTE(003H), BYTE(0C3H)); Cgen.Emit2(BYTE(013H), BYTE(0D1H))
              ELSE Cgen.Emit2(BYTE(02BH), BYTE(0C3H)); Cgen.Emit2(BYTE(01BH), BYTE(0D1H)) END;
              Cgen.Emit1(BYTE(Cgen.OpPopBx)); Cgen.Emit1(BYTE(Cgen.OpPopEs))
            ELSE
              Cgen.Emit1(BYTE(Cgen.OpPopCx));
              Cgen.Emit1(BYTE(091H)); Cgen.Emit1(BYTE(Cgen.OpPopBx));
              Cgen.Emit1(BYTE(Cgen.OpPopEs)); Cgen.Emit1(BYTE(091H));
              IF id = Syms.SpInc THEN Cgen.CgAdd() ELSE Cgen.CgSub() END
            END;
            Cgen.CgStoreItem(vstore)
          END
        ELSIF fastAddr THEN
          Scan.Next(PExpr.sc); PExpr.ParseExpression(vstep);
          IF vstep.mode = Cgen.MConst THEN
            (* --- fast memory-dest ADD/SUB by a compile-time constant --- *)
            IF isByteV THEN
              Cgen.CgAddSubMemB(isGlobalV, id = Syms.SpInc, vstore.adr, INTEGER(vstep.val))
            ELSIF isLongV THEN
              Cgen.CgAddSubMemL(isGlobalV, id = Syms.SpInc, vstore.adr, vstep.val)
            ELSE
              (* INTEGER / WORD / SYSTEM.ADDRESS: 16-bit offset-word add/sub
                 (ADDRESS has no carry into its segment word — CgAddSubMemW
                 touches only the low offset word). *)
              Cgen.CgAddSubMemW(isGlobalV, id = Syms.SpInc, vstore.adr, INTEGER(vstep.val))
            END
          ELSE
            (* fast address, runtime step: dest is a stable memory var, so we
               need no save-across-parse.  Load step, save it, load dest,
               combine, store.  Handles INTEGER/WORD/ADDRESS/LONGINT/BYTE. *)
            Cgen.CgLoadItem(vstep);
            IF isLongV THEN
              isLongStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFLongint);
              isWordStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFWord);
              IF isWordStep THEN Cgen.Emit2(BYTE(031H), BYTE(0D2H))  (* XOR DX,DX *)
              ELSIF ~isLongStep THEN Cgen.Emit1(BYTE(099H)) END;     (* CWD *)
              Cgen.Emit2(BYTE(089H), BYTE(0C3H));   (* MOV BX, AX *)
              Cgen.Emit2(BYTE(089H), BYTE(0D1H));   (* MOV CX, DX *)
              vitem := vstore; Cgen.CgLoadItem(vitem);  (* AX/DX:AX = old value *)
              IF id = Syms.SpInc THEN
                Cgen.Emit2(BYTE(003H), BYTE(0C3H)); Cgen.Emit2(BYTE(013H), BYTE(0D1H))  (* ADD/ADC *)
              ELSE
                Cgen.Emit2(BYTE(02BH), BYTE(0C3H)); Cgen.Emit2(BYTE(01BH), BYTE(0D1H))  (* SUB/SBB *)
              END
            ELSIF isAddrV THEN
              Cgen.Emit2(BYTE(089H), BYTE(0C3H));   (* MOV BX, AX (step.lo) *)
              vitem := vstore; Cgen.CgLoadItem(vitem);  (* DX:AX = old addr *)
              IF id = Syms.SpInc THEN Cgen.Emit2(BYTE(003H), BYTE(0C3H))  (* ADD AX,BX *)
              ELSE Cgen.Emit2(BYTE(02BH), BYTE(0C3H)) END                 (* SUB AX,BX *)
            ELSE
              Cgen.Emit1(BYTE(Cgen.OpPushAx));      (* save step *)
              vitem := vstore; Cgen.CgLoadItem(vitem);  (* AX = old value *)
              Cgen.Emit1(BYTE(Cgen.OpPopCx));       (* CX = step *)
              (* AX = old, CX = step -> ADD/SUB AX,CX gives old +/- step *)
              IF id = Syms.SpInc THEN Cgen.Emit2(BYTE(003H), BYTE(0C1H))  (* ADD AX,CX *)
              ELSE Cgen.Emit2(BYTE(02BH), BYTE(0C1H)) END                 (* SUB AX,CX *)
            END;
            Cgen.CgStoreItem(vstore)
          END
        ELSE
        Cgen.CgLoadItem(vitem);
        (* Save destination address + current value across parse_expr, which
           may clobber AX/DX/ES/BX (e.g. via inline procs).
           Push order (popped reverse): [need_save_addr]: PUSH ES, PUSH BX;
           [is_long_v]: PUSH DX; always PUSH AX. *)
        needSaveAddr  := (vstore.mode = Cgen.MReg) & vstore.isRef;
        IF needSaveAddr THEN
          Cgen.Emit1(BYTE(Cgen.OpPushEs));
          Cgen.Emit1(BYTE(Cgen.OpPushBx))
        END;
        IF isLongV OR isAddrV THEN Cgen.Emit1(BYTE(Cgen.OpPushDx)) END;
        Cgen.Emit1(BYTE(Cgen.OpPushAx));

        Scan.Next(PExpr.sc); PExpr.ParseExpression(vstep);
        Cgen.CgLoadItem(vstep);

        IF isAddrV THEN
          (* SYSTEM.ADDRESS INC/DEC by step: offset-only math.  AX = step low
             word (only the low 16 bits matter for an offset).  Restore the saved
             segment into DX and the old offset into AX, then ADD/SUB the step to
             the offset.  The segment word (DX) is never modified — no carry. *)
          Cgen.Emit2(BYTE(089H), BYTE(0C3H));       (* MOV BX, AX  (step.lo) *)
          Cgen.Emit1(BYTE(Cgen.OpPopAx));         (* AX = old.ofs *)
          Cgen.Emit1(BYTE(Cgen.OpPopDx));         (* DX = saved seg *)
          IF id = Syms.SpInc THEN
            Cgen.Emit2(BYTE(003H), BYTE(0C3H))      (* ADD AX, BX *)
          ELSE
            Cgen.Emit2(BYTE(02BH), BYTE(0C3H))      (* SUB AX, BX *)
          END
          (* needSaveAddr cannot occur for ADDRESS: vstore is a plain variable
             (MLocal/MGlobal), never an MReg/isRef element. *)
        ELSIF isLongV THEN
          (* Step already 32-bit in DX:AX if vstep is itself LONGINT (CgLoadItem
             loaded the true high word).  Otherwise extend the 16-bit step to
             32 bits: WORD is unsigned, so zero-extend (XOR DX,DX) -- CWD would
             wrongly treat a step with bit 15 set as negative.  BYTE/INTEGER
             are signed-range-safe under CWD (BYTE's AH is always 0 after
             CgLoadItem, so CWD yields DX=0 for it too). *)
          isLongStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFLongint);
          isWordStep := (vstep.type # Syms.NoType) & (vstep.type.form = Syms.TFWord);
          IF isWordStep THEN
            Cgen.Emit1(BYTE(031H)); Cgen.Emit1(BYTE(0D2H))  (* XOR DX, DX *)
          ELSIF ~isLongStep THEN
            Cgen.Emit1(BYTE(099H))                  (* CWD *)
          END;
          Cgen.Emit2(BYTE(089H), BYTE(0C3H));       (* MOV BX, AX *)
          Cgen.Emit2(BYTE(089H), BYTE(0D1H));       (* MOV CX, DX *)
          Cgen.Emit1(BYTE(Cgen.OpPopAx));         (* AX = old.lo *)
          Cgen.Emit1(BYTE(Cgen.OpPopDx));         (* DX = old.hi *)
          IF id = Syms.SpInc THEN
            Cgen.Emit2(BYTE(003H), BYTE(0C3H));     (* ADD AX, BX *)
            Cgen.Emit2(BYTE(013H), BYTE(0D1H))      (* ADC DX, CX *)
          ELSE
            Cgen.Emit2(BYTE(02BH), BYTE(0C3H));     (* SUB AX, BX *)
            Cgen.Emit2(BYTE(01BH), BYTE(0D1H))      (* SBB DX, CX *)
          END;
          IF needSaveAddr THEN
            Cgen.Emit1(BYTE(Cgen.OpPopBx));       (* BX = addr.ofs *)
            Cgen.Emit1(BYTE(Cgen.OpPopEs))        (* ES = addr.seg *)
          END
        ELSE
          Cgen.Emit1(BYTE(Cgen.OpPopCx));         (* CX = old value *)
          IF needSaveAddr THEN
            Cgen.Emit1(BYTE(091H));                 (* XCHG AX, CX *)
            Cgen.Emit1(BYTE(Cgen.OpPopBx));
            Cgen.Emit1(BYTE(Cgen.OpPopEs));
            Cgen.Emit1(BYTE(091H))                  (* XCHG AX, CX *)
          END;
          IF id = Syms.SpInc THEN Cgen.CgAdd() ELSE Cgen.CgSub() END
        END;
        Cgen.CgStoreItem(vstore)
        END  (* IF fastAddr *)
      ELSE
        (* implicit step 1 *)
        IF fastAddr THEN
          (* --- fast memory-dest INC/DEC by 1 --- *)
          IF isLongV THEN
            (* 32-bit needs carry: ADD/SUB [lo],1 then ADC/SBB [hi],0 *)
            Cgen.CgAddSubMemL(isGlobalV, id = Syms.SpInc, vstore.adr, LONGINT(1))
          ELSIF isByteV THEN
            Cgen.CgIncDecMem(isGlobalV, id = Syms.SpInc, TRUE, vstore.adr)
          ELSE
            (* INTEGER / WORD / SYSTEM.ADDRESS: 16-bit INC/DEC (offset word only
               for ADDRESS — no carry into the segment word). *)
            Cgen.CgIncDecMem(isGlobalV, id = Syms.SpInc, FALSE, vstore.adr)
          END
        ELSE
        Cgen.CgLoadItem(vitem);
        IF isLongV THEN
          (* LONGINT INC/DEC by 1: must carry into DX.
             INC: ADD AX,1 / ADC DX,0; DEC: SUB AX,1 / SBB DX,0. *)
          IF id = Syms.SpInc THEN
            Cgen.Emit1(005H); Cgen.Emit1(001H); Cgen.Emit1(000H);
            Cgen.Emit1(083H); Cgen.Emit1(0D2H); Cgen.Emit1(000H)
          ELSE
            Cgen.Emit1(02DH); Cgen.Emit1(001H); Cgen.Emit1(000H);
            Cgen.Emit1(083H); Cgen.Emit1(0DAH); Cgen.Emit1(000H)
          END
        ELSE
          IF id = Syms.SpInc THEN Cgen.CgIncAx() ELSE Cgen.CgDecAx() END
        END;
        Cgen.CgStoreItem(vstore)
        END  (* IF fastAddr *)
      END

  | Syms.SpAssert:
      errCode := 1;
      haltId := PExpr.GetSystemImport("SYSTEM_Halt");
      PExpr.ParseExpression(cond); Cgen.CgLoadItem(cond);
      IF PExpr.sc.sym = Scan.TComma THEN
        Scan.Next(PExpr.sc);
        IF PExpr.sc.sym = Scan.TInt THEN errCode := PExpr.sc.ival; Scan.Next(PExpr.sc)
        ELSE PExpr.Error("integer constant expected") END
      END;
      Cgen.CgTestAx();
      Cgen.CgCondNear(Cgen.OpJnz, ok);
      Cgen.CgLoadImm(INTEGER(errCode));
      Cgen.Emit1(BYTE(Cgen.OpPushAx));
      Cgen.CgCallFar(haltId);
      Cgen.CgPatchNear(ok)
  ELSE
    PExpr.Error("unsupported built-in statement")
  END;
  PExpr.Expect(Scan.TRparen)
END ParseSysprocCall;

(* ---- statement ---- *)

PROCEDURE ItemInline(VAR item: Cgen.Item): BOOLEAN;
BEGIN
  IF item.type = Syms.NoType THEN RETURN FALSE END;
  RETURN item.type.isInline
END ItemInline;

PROCEDURE ParseStatement(retType: Syms.TypeDesc);
  VAR sym: Syms.Symbol; item, rhs: Cgen.Item;
      pt: Syms.TypeDesc; varAdr: LONGINT; varGlobal, varRef: BOOLEAN;
      rdId: INTEGER; codeOfs: LONGINT; isImp, isFr: BOOLEAN; pt2: Syms.TypeDesc;
      count: LONGINT;
      iform, rform: INTEGER;
BEGIN
  (* debug info: one line record at the first code of each new source line *)
  TDbg.AddLine(WORD(Cgen.CgPc()), PExpr.sc.line);
  IF PExpr.sc.sym = Scan.TIdent THEN
    sym := Syms.SymFind(PExpr.sc.id);
    (* INLINE statement form — INLINE(b0, b1, ...) emits the listed bytes
       into the current procedure body.  Constants only (no Pn refs);
       the proc-declarator INLINE form handles the with-Pn variant. *)
    IF (sym = NIL) & Strings.Equal(PExpr.sc.id, "INLINE") THEN
      Scan.Next(PExpr.sc);
      PExpr.Expect(Scan.TLparen);
      WHILE (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
        IF PExpr.sc.sym # Scan.TInt THEN
          PExpr.Error("byte literal expected in INLINE statement");
        ELSE
          Cgen.Emit1(BYTE(PExpr.sc.ival MOD LONGINT(256)));
          Scan.Next(PExpr.sc);
          IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END
        END
      END;
      PExpr.Expect(Scan.TRparen);
      RETURN
    END;
    IF (sym # Syms.NoSym) & (sym.kind = Syms.KSysProc) THEN
      Scan.Next(PExpr.sc); ParseSysprocCall(sym.sysId); RETURN
    END;
    PExpr.ParseDesignator(item);
    IF (item.mode = Cgen.MSysProc) THEN
      ParseSysprocCall(INTEGER(item.val)); RETURN
    END;
    IF PExpr.sc.sym = Scan.TAssign THEN
      Scan.Next(PExpr.sc);
      (* VAR-param assignment counts as use — VAR is an out-parameter.
         Also: `s^.f := x` / `a[i] := x` reads the root (the deref/index
         requires loading its value), so item.isRef means root was read. *)
      IF item.rootSym # Syms.NoSym THEN
        IF (item.rootSym.kind = Syms.KVarParam) &
           (item.rootSym.readCount < WORD(0FFFFH)) THEN
          INC(item.rootSym.readCount)
        END;
        IF item.isRef & (item.rootSym.readCount < WORD(0FFFFH)) THEN
          INC(item.rootSym.readCount)
        END
      END;
      IF (item.mode = Cgen.MReg) & item.isRef THEN
        Cgen.EmitCodeStr("06,53")  (* PUSH ES; PUSH BX *)
      END;
      PExpr.ParseExpression(rhs);
      (* Read dest/src .form ONCE; reuse iform/rform below instead of
         re-reading item.type.form/rhs.type.form per check. *)
      iform := -1; rform := -1;
      IF item.type # Syms.NoType THEN iform := item.type.form END;
      IF rhs.type  # Syms.NoType THEN rform := rhs.type.form END;
      (* Reject bare procedure designator (no parens) when destination is not
         a procedure variable.  Without this check the compiler would silently
         emit the proc's code-segment offset (an address) into an INTEGER
         destination — caller almost certainly meant to CALL the proc. *)
      IF (rform = Syms.TFProc) &
         ((rhs.mode = Cgen.MProc) OR (rhs.mode = Cgen.MImport)) &
         (item.type # Syms.NoType) & (iform # Syms.TFProc) THEN
        PExpr.Error("missing '()' on parameterless procedure call (or proc value assigned to non-procedure variable)")
      END;
      (* Cross-family numeric assignment: int<->float requires explicit cast.
         Without this check `r := i` and `i := r` silently
         store integer bytes as IEEE-float bit patterns (or vice-versa). *)
      IF (item.type # Syms.NoType) & (rhs.type # Syms.NoType) THEN
        IF (((iform = Syms.TFReal) OR (iform = Syms.TFLongreal)) &
            ((rform = Syms.TFInteger) OR (rform = Syms.TFLongint) OR
             (rform = Syms.TFByte) OR (rform = Syms.TFWord) OR
             (rform = Syms.TFChar))) OR
           (((rform = Syms.TFReal) OR (rform = Syms.TFLongreal)) &
            ((iform = Syms.TFInteger) OR (iform = Syms.TFLongint) OR
             (iform = Syms.TFByte) OR (iform = Syms.TFWord) OR
             (iform = Syms.TFChar))) THEN
          PExpr.Error("type mismatch in assignment: int/float require explicit cast (REAL(x), LONGREAL(x), FLOOR(x), ENTIER(x))")
        END
      END;
      (* array-to-array, both plain near vars (no isRef): fast REP MOVSB *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFArray) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFArray) &
         ((item.mode = Cgen.MGlobal) OR (item.mode = Cgen.MLocal)) & ~item.isRef &
         ((rhs.mode = Cgen.MGlobal) OR (rhs.mode = Cgen.MLocal)) & ~rhs.isRef THEN
        IF rhs.type.size < item.type.size THEN count := rhs.type.size
        ELSE count := item.type.size END;
        Cgen.CgLoadAddrItem(rhs.mode, rhs.adr);
        Cgen.Emit2(08BH, 0F0H);  (* MOV SI, AX *)
        Cgen.CgLoadAddrItem(item.mode, item.adr);
        Cgen.Emit2(08BH, 0F8H);  (* MOV DI, AX *)
        Cgen.CgEsFromMode(item.mode);    (* ES = SS or DS *)
        Cgen.CgRepMovsb(INTEGER(count), rhs.mode = Cgen.MLocal);
        RETURN
      END;
      (* General array assignment where either side is a far reference:
           dest = VAR-record array field / open-array param / VAR-array param /
                  pointer-deref array (any isRef or MReg destination);
           src  = open-array param, VAR-array param, fixed array, or far elem.
         Strategy: load src far addr into DS:SI, dest far addr into ES:DI,
         byte count into CX (min(dst.size, src LEN/size)), then REP MOVSB,
         preserving DS.  The destination must be a fixed array (open-array
         destinations are read-only as assignment targets in practice). *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFArray) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFArray) &
         (item.type.len >= 0) THEN
        (* Unified path: leave the destination far ptr on the stack as
           [seg][ofs] (ofs on top), push the source far ptr the same way,
           then pop both into registers and REP MOVSB preserving DS. *)
        IF (item.mode = Cgen.MReg) & item.isRef THEN
          (* dst far ptr already pushed [seg][ofs] before ParseExpression *)
        ELSE
          Cgen.CgPushFarAddrItem(item.mode, item.adr, item.isRef)
        END;
        (* push src far ptr [seg][ofs] *)
        IF (rhs.mode = Cgen.MReg) & rhs.isRef THEN
          Cgen.EmitCodeStr("06,53")                 (* PUSH ES; PUSH BX *)
        ELSIF rhs.isRef OR (rhs.type.len < 0) THEN
          Cgen.CgLesBxItem(rhs.mode, rhs.adr);
          Cgen.EmitCodeStr("06,53")                 (* PUSH ES; PUSH BX *)
        ELSE
          Cgen.CgPushFarAddrItem(rhs.mode, rhs.adr, FALSE)
        END;
        (* byte count -> CX (min(dst.size, src LEN/size)); uses AX only *)
        Cgen.CgArrCount(item.type.size,
                        rhs.type.len < 0, rhs.adr, rhs.type.size);
        (* stack top->: srcOfs, srcSeg, dstOfs, dstSeg *)
        Cgen.Emit1(05EH);            (* POP SI  (src ofs) *)
        Cgen.Emit1(058H);            (* POP AX  (src seg) *)
        Cgen.Emit1(05FH);            (* POP DI  (dst ofs) *)
        Cgen.Emit1(05AH);            (* POP DX  (dst seg) *)
        Cgen.Emit1(01EH);            (* PUSH DS *)
        Cgen.EmitCodeStr("8E,D8");   (* MOV DS, AX   (DS = src seg) *)
        Cgen.EmitCodeStr("8E,C2");   (* MOV ES, DX   (ES = dst seg) *)
        Cgen.Emit1(BYTE(Cgen.OpCld));
        Cgen.Emit2(0F3H, 0A4H);      (* REP MOVSB *)
        Cgen.Emit1(01FH);            (* POP DS *)
        RETURN
      END;
      (* Record assign: both sides plain (non-ref) local/global vars. *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFRecord) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFRecord) &
         ~item.isRef & ~rhs.isRef &
         ((item.mode = Cgen.MLocal) OR (item.mode = Cgen.MGlobal)) &
         ((rhs.mode = Cgen.MLocal) OR (rhs.mode = Cgen.MGlobal)) THEN
        count := item.type.size;
        Cgen.CgLoadAddrItem(rhs.mode, rhs.adr);
        Cgen.Emit2(08BH, 0F0H);  (* MOV SI, AX *)
        Cgen.CgLoadAddrItem(item.mode, item.adr);
        Cgen.Emit2(08BH, 0F8H);  (* MOV DI, AX *)
        Cgen.CgEsFromMode(item.mode);
        Cgen.CgRepMovsb(INTEGER(count), rhs.mode = Cgen.MLocal);
        RETURN
      END;
      (* Record assign: VAR-param dest (isRef), local/global source (plain).
         SI = src addr; ES:DI = dest far ptr; DS=SS if src is local. *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFRecord) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFRecord) &
         item.isRef & ~rhs.isRef &
         ((item.mode = Cgen.MLocal) OR (item.mode = Cgen.MGlobal)) &
         ((rhs.mode = Cgen.MLocal) OR (rhs.mode = Cgen.MGlobal)) THEN
        count := item.type.size;
        IF rhs.mode = Cgen.MLocal THEN Cgen.Emit1(01EH) END;  (* PUSH DS *)
        Cgen.CgLoadAddrItem(rhs.mode, rhs.adr);
        Cgen.Emit2(08BH, 0F0H);   (* MOV SI, AX *)
        Cgen.CgLesBxItem(item.mode, item.adr);
        Cgen.Emit2(08BH, 0FBH);   (* MOV DI, BX *)
        Cgen.CgLoadImm(INTEGER(count)); Cgen.Emit2(08BH, 0C8H);  (* MOV CX, AX *)
        Cgen.Emit1(BYTE(Cgen.OpCld));
        IF rhs.mode = Cgen.MLocal THEN
          Cgen.EmitCodeStr("8C,D2,8E,DA")  (* MOV DX,SS; MOV DS,DX *)
        END;
        Cgen.Emit2(0F3H, 0A4H);   (* REP MOVSB: DS:SI -> ES:DI *)
        IF rhs.mode = Cgen.MLocal THEN Cgen.Emit1(01FH) END;  (* POP DS *)
        RETURN
      END;
      (* Record-through-far-pointer assignment: REP MOVSB with DS-swap.
         Load dest FIRST while DS still points at the data segment; only
         then swap DS for the src segment.
         Excludes LHS=MReg/isRef (handled by the next branch). *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFRecord) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFRecord) &
         item.isRef & rhs.isRef &
         (item.mode # Cgen.MReg) THEN
        count := item.type.size;
        Cgen.Emit1(01EH);             (* PUSH DS *)
        Cgen.CgLesBxItem(item.mode, item.adr);
        Cgen.Emit2(08BH, 0FBH);       (* MOV DI, BX *)
        Cgen.Emit1(006H);             (* PUSH ES *)
        Cgen.CgLesBxItem(rhs.mode, rhs.adr);
        Cgen.Emit2(08BH, 0F3H);       (* MOV SI, BX *)
        Cgen.EmitCodeStr("06,1F,07"); (* PUSH ES; POP DS; POP ES (DS=src, ES=dst) *)
        Cgen.CgRepMovsb(INTEGER(count), FALSE);
        Cgen.Emit1(01FH);             (* POP DS  (restore data segment) *)
        RETURN
      END;

      (* Record assignment: LHS MReg/isRef (array element / pointer deref).
         LHS's ES:BX was already saved on the stack as [BX][ES] before
         ParseExpression.  RHS may be MReg/isRef or MLocal/MGlobal with or
         without isRef.  Plan:
           In:  ES:BX = src far addr (after normalising RHS forms below);
                stack: [dst_BX][dst_ES].
           MOV  SI, BX
           MOV  CX, ES                ; CX = src segment
           POP  DI                    ; DI = dst offset
           POP  DX                    ; DX = dst segment
           PUSH DS
           MOV  DS, CX                ; DS = src segment
           MOV  ES, DX                ; ES = dst segment
           MOV  CX, count
           CLD
           REP MOVSB
           POP  DS                    ; restore DS                       *)
      IF (item.type # Syms.NoType) & (iform = Syms.TFRecord) &
         (rhs.type # Syms.NoType) & (rform = Syms.TFRecord) &
         (item.mode = Cgen.MReg) & item.isRef THEN
        count := item.type.size;
        (* Normalise RHS so ES:BX holds src far address. *)
        IF ~rhs.isRef &
           ((rhs.mode = Cgen.MLocal) OR (rhs.mode = Cgen.MGlobal)) THEN
          Cgen.CgLoadAddrItem(rhs.mode, rhs.adr);    (* AX = src ofs *)
          Cgen.Emit2(08BH, 0D8H);                    (* MOV BX, AX *)
          Cgen.CgEsFromMode(rhs.mode)                (* ES = SS or DS *)
        ELSIF rhs.isRef &
              ((rhs.mode = Cgen.MLocal) OR (rhs.mode = Cgen.MGlobal)) THEN
          Cgen.CgLesBxItem(rhs.mode, rhs.adr)
        END;
        (* else rhs.mode = MReg/isRef: ES:BX already holds src addr. *)
        Cgen.EmitCodeStr("8B,F3");                  (* MOV SI, BX *)
        Cgen.EmitCodeStr("8C,C1");                  (* MOV CX, ES *)
        Cgen.Emit1(05FH);                            (* POP DI (dst ofs) *)
        Cgen.Emit1(05AH);                            (* POP DX (dst seg) *)
        Cgen.Emit1(01EH);                            (* PUSH DS *)
        Cgen.EmitCodeStr("8E,D9");                  (* MOV DS, CX *)
        Cgen.EmitCodeStr("8E,C2");                  (* MOV ES, DX *)
        Cgen.Emit1(0B9H);
        Cgen.Emit1(BYTE(count MOD LONGINT(256)));
        Cgen.Emit1(BYTE((count DIV LONGINT(256)) MOD LONGINT(256)));
        Cgen.Emit1(BYTE(Cgen.OpCld));
        Cgen.Emit2(0F3H, 0A4H);                      (* REP MOVSB *)
        Cgen.Emit1(01FH);                            (* POP DS *)
        RETURN
      END;
      IF (item.type # Syms.NoType) & (iform = Syms.TFLongint) &
         (rhs.type # Syms.NoType) & (rform # Syms.TFLongint) &
         (rhs.mode = Cgen.MConst) THEN
        rhs.type := Syms.TypeLongint
      END;
      Cgen.CgLoadItem(rhs);
      IF (item.type # Syms.NoType) & (item.type.form = Syms.TFLongint) &
         (rhs.type # Syms.NoType) & (rhs.type.form # Syms.TFLongint) THEN
        Cgen.Emit1(099H)
      END;
      IF (item.mode = Cgen.MReg) & item.isRef THEN
        Cgen.EmitCodeStr("5B,07")  (* POP BX; POP ES *)
      END;
      Cgen.CgStoreItem(item)
    ELSIF (item.type # Syms.NoType) & (item.type.form = Syms.TFProc) &
          ((item.mode = Cgen.MLocal) OR (item.mode = Cgen.MGlobal) OR
           ((item.mode = Cgen.MReg) & item.isRef)) THEN
      PExpr.MarkRead(item);
      varAdr := item.adr; varGlobal := (item.mode = Cgen.MGlobal);
      varRef := (item.mode = Cgen.MReg) & item.isRef;
      pt := item.type;
      IF varRef THEN
        Cgen.EmitCodeStr("53,06");  (* PUSH BX; PUSH ES *)
        IF (PExpr.sc.sym = Scan.TLparen) OR (pt.nParams > 0) THEN
          PExpr.ParseActualParameters(pt) END;
        Cgen.Emit2(089H, 0E3H);
        IF pt.argSize > 0 THEN
          IF pt.argSize <= 127 THEN
            Cgen.Emit2(083H, 0C3H); Cgen.Emit1(BYTE(INTEGER(pt.argSize) MOD 256))
          ELSE
            Cgen.Emit2(081H, 0C3H); Cgen.EmitW(INTEGER(SYSTEM.AND(pt.argSize, LONGINT(0FFFFH))))
          END
        END;
        Cgen.Emit3(036H, 08BH, 00FH);
        Cgen.Emit4(036H, 08BH, 05FH, 002H);
        Cgen.Emit2(08EH, 0C1H);
        Cgen.CgCallProcVarEsbx();
        Cgen.Emit2(083H, 0C4H); Cgen.Emit1(004H)
      ELSE
        IF (PExpr.sc.sym = Scan.TLparen) OR (pt.nParams > 0) THEN
          PExpr.ParseActualParameters(pt) END;
        IF pt.isFar THEN
          IF varGlobal THEN Cgen.CgCallProcVarMem(WORD(varAdr))
          ELSE Cgen.CgCallProcVarBp(varAdr) END
        ELSE
          IF varGlobal THEN Cgen.CgCallProcVarNearMem(WORD(varAdr))
          ELSE Cgen.CgCallProcVarNearBp(varAdr) END
        END
      END
    ELSIF (item.mode = Cgen.MProc) & (item.type # Syms.NoType) & ItemInline(item) THEN
      PExpr.MarkRead(item);
      IF (PExpr.sc.sym = Scan.TLparen) OR (item.type.nParams > 0) THEN
        PExpr.EmitInlineCall(item.type) END
    ELSIF (item.mode = Cgen.MProc) OR (item.mode = Cgen.MImport) THEN
      PExpr.MarkRead(item);
      rdId := item.rdoffId; codeOfs := item.adr;
      isImp := (item.mode = Cgen.MImport); isFr := item.isFar;
      pt2 := item.type;
      IF pt2 = Syms.NoType THEN pt2 := Syms.TypeNewProc(Syms.TypeNotype) END;
      IF (PExpr.sc.sym = Scan.TLparen) OR (pt2.nParams > 0) THEN
        PExpr.ParseActualParameters(pt2) END;
      IF isImp & isFr THEN Cgen.CgCallFar(rdId)
      ELSIF isImp THEN Cgen.CgCallNear(rdId)
      ELSIF item.fwdSym # Syms.NoSym THEN PExpr.FwdEmitCall(item.fwdSym, isFr)
      ELSIF isFr THEN Cgen.CgCallLocalFar(codeOfs)
      ELSE Cgen.CgCallLocal(codeOfs) END
    END
  ELSIF PExpr.sc.sym = Scan.TIf     THEN ParseIf(retType)
  ELSIF PExpr.sc.sym = Scan.TWhile  THEN ParseWhile(retType)
  ELSIF PExpr.sc.sym = Scan.TRepeat THEN ParseRepeat(retType)
  ELSIF PExpr.sc.sym = Scan.TFor    THEN ParseFor(retType)
  ELSIF PExpr.sc.sym = Scan.TCase   THEN ParseCase(retType)
  ELSIF PExpr.sc.sym = Scan.TReturn THEN ParseReturn(retType)
  END
  (* empty statement: do nothing *)
END ParseStatement;

PROCEDURE ParseStatementSequence;
BEGIN
  ParseStatement(retType);
  WHILE PExpr.sc.sym = Scan.TSemi DO
    Scan.Next(PExpr.sc); ParseStatement(retType)
  END
END ParseStatementSequence;

BEGIN
  retPatchList := NIL; curProloguePatch := 0; curProcDepth := 0
END PStmt.
