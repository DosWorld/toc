MODULE SYS1;
IMPORT Test;

CONST
  SzIntC  = SIZE(INTEGER);    (* compile-time *)

TYPE
  SiPInt = POINTER TO INTEGER;
  SzPoint  = RECORD x, y: INTEGER END;            (* 4 bytes *)
  SzMixed  = RECORD a: BYTE; b: LONGINT END;      (* BYTE pad + LONGINT = 6 bytes *)
  SzVec10  = ARRAY 10 OF INTEGER;                 (* 20 bytes *)
  SzMat3x4 = ARRAY 3, 4 OF BYTE;                  (* 12 bytes *)
  SzPNode  = POINTER TO SzNode;                   (* 4 bytes — far pointer *)
  SzNode   = RECORD val: INTEGER; next: SzPNode END;
  SzArrFromSize = ARRAY SIZE(SzPoint) OF INTEGER;  (* 4 INTEGERs *)

VAR
  SigA, SigB:   INTEGER;
  SigSrc:     ARRAY 4 OF INTEGER;
  SigDst:     ARRAY 4 OF INTEGER;
  SigFill:    ARRAY 6 OF INTEGER;
  SagInt:  INTEGER;
  SagArr:  ARRAY 8 OF INTEGER;
  SagRec:  RECORD a, b: INTEGER END;

PROCEDURE SyTConstants*;
VAR x: INTEGER;
BEGIN
  x := SYSTEM.FZero;  Test.AssertInt(64,  x, "SYSTEM.FZero = 64");
  x := SYSTEM.FSign;  Test.AssertInt(128, x, "SYSTEM.FSign = 128");
  x := SYSTEM.FCarry; Test.AssertInt(1,   x, "SYSTEM.FCarry = 1")
END SyTConstants;

PROCEDURE SyTRegisters*;
VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 42;   Test.AssertInt(42,   r.AX, "Registers.AX assignment");
  r.BX := 1000; Test.AssertInt(1000, r.BX, "Registers.BX assignment");
  r.AX := 0;    Test.AssertInt(0,    r.AX, "Registers.AX zero")
END SyTRegisters;

PROCEDURE SyTIntr*;
VAR r: SYSTEM.Registers;
BEGIN
                                                                       
  r.AX := 0200H;                    
  r.DX := 42;             
  SYSTEM.Intr(21H, r);
  Test.AssertTrue(TRUE, "SYSTEM.Intr no crash")
END SyTIntr;

PROCEDURE SyTNewDispose*;
VAR addr: SYSTEM.ADDRESS; n: INTEGER;
BEGIN
  n := 8;
  NEW(addr, n);
  Test.AssertNotNil(addr, "NEW(addr,8) non-NIL");
  DISPOSE(addr);
  Test.AssertTrue(TRUE, "DISPOSE(addr) no crash");

  n := 4;
  NEW(addr, n); Test.AssertNotNil(addr, "NEW addr cycle 1"); DISPOSE(addr);
  NEW(addr, n); Test.AssertNotNil(addr, "NEW addr cycle 2"); DISPOSE(addr)
END SyTNewDispose;

PROCEDURE SiTSegGlobal*;
BEGIN
  SigA := 1; SigB := 2;
  Test.AssertInt(SYSTEM.SEG(SigA), SYSTEM.SEG(SigB), "two globals same segment")
END SiTSegGlobal;

PROCEDURE SiTSegLocal*;
VAR x, y: INTEGER;
BEGIN
  x := 10; y := 20;
  Test.AssertInt(SYSTEM.SEG(x), SYSTEM.SEG(y), "two locals same segment");
  Test.AssertTrue(SYSTEM.SEG(x) # SYSTEM.SEG(SigA), "local<>global segment")
END SiTSegLocal;

PROCEDURE SiGetSeg(VAR v: INTEGER): INTEGER;
BEGIN RETURN SYSTEM.SEG(v) END SiGetSeg;

PROCEDURE SiTSegVarParam*;
VAR loc: INTEGER;
BEGIN
  loc := 0;
  Test.AssertInt(SYSTEM.SEG(SigA),  SiGetSeg(SigA),  "VAR param global=DS");
  Test.AssertInt(SYSTEM.SEG(loc), SiGetSeg(loc), "VAR param local=SS")
END SiTSegVarParam;

PROCEDURE SiGetSegVal(v: INTEGER): INTEGER;
BEGIN RETURN SYSTEM.SEG(v) END SiGetSegVal;

PROCEDURE SiTSegNonVarParam*;
VAR loc: INTEGER;
BEGIN
  loc := 0;
  Test.AssertInt(SYSTEM.SEG(loc), SiGetSegVal(42), "non-VAR param = SS")
END SiTSegNonVarParam;

PROCEDURE SiTSegDeref*;
VAR p: SiPInt;
BEGIN
  NEW(p);
  p^ := 77;
  Test.AssertInt(SYSTEM.SEG(p^), SYSTEM.SEG(p^), "SEG(p^) consistent");
  DISPOSE(p)
END SiTSegDeref;

PROCEDURE SiTOfsGlobal*;
VAR o1, o2: INTEGER;
BEGIN
  o1 := SYSTEM.OFS(SigA);
  o2 := SYSTEM.OFS(SigB);
  Test.AssertTrue((o2 - o1 = 2) OR (o1 - o2 = 2), "adjacent globals differ by 2")
END SiTOfsGlobal;

PROCEDURE SiTOfsLocal*;
VAR x, y: INTEGER;
BEGIN
  x := 1; y := 2;
  Test.AssertTrue(SYSTEM.OFS(x) # SYSTEM.OFS(y), "two locals differ")
END SiTOfsLocal;

PROCEDURE SiGetOfs(VAR v: INTEGER): INTEGER;
BEGIN RETURN SYSTEM.OFS(v) END SiGetOfs;

PROCEDURE SiTOfsVarParam*;
BEGIN
  Test.AssertInt(SYSTEM.OFS(SigA), SiGetOfs(SigA), "VAR param matches caller OFS")
END SiTOfsVarParam;

PROCEDURE SiGetOfsVal(v: INTEGER): INTEGER;
BEGIN RETURN SYSTEM.OFS(v) END SiGetOfsVal;

PROCEDURE SiTOfsNonVarParam*;
VAR o1, o2: INTEGER;
BEGIN
                                                                  
  o1 := SiGetOfsVal(10);
  o2 := SiGetOfsVal(20);
  Test.AssertInt(o1, o2, "non-VAR param OFS stable")
END SiTOfsNonVarParam;

PROCEDURE SiTOfsDeref*;
VAR p: SiPInt;
BEGIN
  NEW(p);
  p^ := 333;
  Test.AssertInt(SYSTEM.OFS(p^), SYSTEM.OFS(p^), "OFS(p^) stable");
  Test.AssertInt(SYSTEM.SEG(p^), SYSTEM.SEG(p^), "SEG(p^) stable");
  p^ := 777;
  Test.AssertInt(777, p^, "p^ write stable after SEG/OFS");
  DISPOSE(p)
END SiTOfsDeref;

PROCEDURE SiTMoveGlobal*;
BEGIN
  SigSrc[0] := 11; SigSrc[1] := 22; SigSrc[2] := 33; SigSrc[3] := 44;
  SigDst[0] :=  0; SigDst[1] :=  0; SigDst[2] :=  0; SigDst[3] :=  0;
  SYSTEM.MOVE(SigSrc, SigDst, 8);
  Test.AssertInt(11, SigDst[0], "MOVE global[0]");
  Test.AssertInt(22, SigDst[1], "MOVE global[1]");
  Test.AssertInt(33, SigDst[2], "MOVE global[2]");
  Test.AssertInt(44, SigDst[3], "MOVE global[3]")
END SiTMoveGlobal;

PROCEDURE SiMoveIntoVarParam(VAR dst: ARRAY 4 OF INTEGER;
                           VAR src: ARRAY 4 OF INTEGER; n: INTEGER);
BEGIN SYSTEM.MOVE(src, dst, n) END SiMoveIntoVarParam;

PROCEDURE SiTMoveVarParam*;
BEGIN
  SigSrc[0] := 5; SigSrc[1] := 6; SigSrc[2] := 7; SigSrc[3] := 8;
  SigDst[0] := 0; SigDst[1] := 0; SigDst[2] := 0; SigDst[3] := 0;
  SiMoveIntoVarParam(SigDst, SigSrc, 8);
  Test.AssertInt(5, SigDst[0], "MOVE VAR param dst[0]");
  Test.AssertInt(6, SigDst[1], "MOVE VAR param dst[1]");
  Test.AssertInt(7, SigDst[2], "MOVE VAR param dst[2]");
  Test.AssertInt(8, SigDst[3], "MOVE VAR param dst[3]")
END SiTMoveVarParam;

PROCEDURE SiTFillGlobal*;
VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  FOR i := 0 TO 5 DO SigFill[i] := i + 1 END;
  SYSTEM.FILL(SigFill, 12, 0);
  ok := TRUE;
  FOR i := 0 TO 5 DO IF SigFill[i] # 0 THEN ok := FALSE END END;
  Test.AssertTrue(ok, "FILL global zeros 6 INTEGERs")
END SiTFillGlobal;

PROCEDURE SiTFillGlobalByte*;
BEGIN
  SigFill[0] := 0;
  SYSTEM.FILL(SigFill, 2, 0ABH);
  Test.AssertInt(0ABABH, SigFill[0], "FILL global non-zero byte")
END SiTFillGlobalByte;

PROCEDURE SiFillVarParam(VAR arr: ARRAY 6 OF INTEGER; n, b: INTEGER);
BEGIN SYSTEM.FILL(arr, n, b) END SiFillVarParam;

PROCEDURE SiTFillVarParam*;
VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  FOR i := 0 TO 5 DO SigFill[i] := 99 END;
  SiFillVarParam(SigFill, 12, 0);
  ok := TRUE;
  FOR i := 0 TO 5 DO IF SigFill[i] # 0 THEN ok := FALSE END END;
  Test.AssertTrue(ok, "FILL VAR param zeros array")
END SiTFillVarParam;

PROCEDURE SiTPtrDeref*;
VAR adr: SYSTEM.ADDRESS;
    ip:  POINTER TO INTEGER;
BEGIN
  SigA := 0;
  adr := SYSTEM.PTR(SYSTEM.SEG(SigA), SYSTEM.OFS(SigA));
  ip  := adr;
  ip^ := 1234;
  Test.AssertInt(1234, SigA, "PTR+deref write global");
  SigA := 0;
  Test.AssertInt(0, SigA, "PTR+deref clear")
END SiTPtrDeref;

PROCEDURE SiTPtrDerefHeap*;
VAR p: SiPInt; s: INTEGER;
BEGIN
  NEW(p);
  p^ := 5678;
  s := SYSTEM.SEG(p^);
  Test.AssertInt(5678, p^,    "p^ readable after SEG/OFS calls");
  Test.AssertTrue(s # 0,       "SEG(p^) non-zero");
  DISPOSE(p)
END SiTPtrDerefHeap;

PROCEDURE SaTargetProc*(): INTEGER;
BEGIN RETURN 42 END SaTargetProc;

PROCEDURE SaTGlobalVar*;
VAR adr: SYSTEM.ADDRESS;
BEGIN
  SagInt := 0;
  adr := SYSTEM.ADR(SagInt);
  Test.AssertTrue(adr # 0, "adr non-zero");
  SagInt := 1234;
  Test.AssertInt(1234, SagInt, "global write-back")
END SaTGlobalVar;

PROCEDURE SaTGlobalArray*;
VAR base, e0, e1, e3: SYSTEM.ADDRESS;
    i: INTEGER;
BEGIN
  FOR i := 0 TO 7 DO SagArr[i] := i * 10 END;
  base := SYSTEM.ADR(SagArr);
  e0 := SYSTEM.ADR(SagArr[0]);
  e1 := SYSTEM.ADR(SagArr[1]);
  e3 := SYSTEM.ADR(SagArr[3]);
  Test.AssertInt(e0, base,    "base = ADR(arr[0])");
  Test.AssertInt(2,  e1 - e0, "e1 - e0 = 2");
  Test.AssertInt(6,  e3 - e0, "e3 - e0 = 6");
  SagArr[3] := 999;
  Test.AssertInt(999, SagArr[3], "arr[3] write")
END SaTGlobalArray;

PROCEDURE SaTGlobalRecord*;
VAR adrRec, adrA, adrB: SYSTEM.ADDRESS;
BEGIN
  SagRec.a := 10; SagRec.b := 20;
  adrRec := SYSTEM.ADR(SagRec);
  adrA := SYSTEM.ADR(SagRec.a);
  adrB := SYSTEM.ADR(SagRec.b);
  Test.AssertTrue(adrRec # 0,    "adrRec non-zero");
  Test.AssertInt(0, adrA - adrRec, "a at offset 0");
  Test.AssertInt(2, adrB - adrA,   "b - a = 2");
  SagRec.a := 100; SagRec.b := 200;
  Test.AssertInt(100, SagRec.a, "rec.a write");
  Test.AssertInt(200, SagRec.b, "rec.b write")
END SaTGlobalRecord;

PROCEDURE SaTLocalVar*;
VAR x, y: INTEGER;
    adrX, adrY: SYSTEM.ADDRESS;
    dx, dy: LONGINT;
BEGIN
  x := 55;
  adrX := SYSTEM.ADR(x);
  Test.AssertNotNil(adrX, "local adr non-nil");
  y := 77;
  adrY := SYSTEM.ADR(y);
  Test.AssertTrue(adrX # adrY, "x and y have different adr");
                                                             
  dx := SYSTEM.OFS(x);  dy := SYSTEM.OFS(y);
  IF dx >= dy THEN
    Test.AssertTrue(dx - dy >= 2, "x-y >= 2 (offsets)")
  ELSE
    Test.AssertTrue(dy - dx >= 2, "y-x >= 2 (offsets)")
  END
END SaTLocalVar;

PROCEDURE SaTLocalArray*;
VAR a: ARRAY 6 OF INTEGER;
    base, e0, e2: SYSTEM.ADDRESS;
    i: INTEGER;
BEGIN
  FOR i := 0 TO 5 DO a[i] := i + 1 END;
  base := SYSTEM.ADR(a);
  e0 := SYSTEM.ADR(a[0]);
  e2 := SYSTEM.ADR(a[2]);
  Test.AssertInt(e0, base,    "base = ADR(a[0])");
  Test.AssertInt(4,  e2 - e0, "e2 - e0 = 4")
END SaTLocalArray;

PROCEDURE SaTLocalRecord*;
VAR r: RECORD p, q: INTEGER END;
    adrR, adrP, adrQ: SYSTEM.ADDRESS;
BEGIN
  r.p := 11; r.q := 22;
  adrR := SYSTEM.ADR(r);
  adrP := SYSTEM.ADR(r.p);
  adrQ := SYSTEM.ADR(r.q);
  Test.AssertTrue(adrR # 0,    "adrR non-zero");
  Test.AssertInt(0, adrP - adrR, "p at offset 0");
  Test.AssertInt(2, adrQ - adrP, "q - p = 2")
END SaTLocalRecord;

PROCEDURE SaTProcAddr*;
VAR adr: SYSTEM.ADDRESS;
    fn:  PROCEDURE(): INTEGER;
BEGIN
  adr := SYSTEM.ADR(SaTargetProc);
  Test.AssertNotNil(adr, "proc adr non-nil");
  fn := SaTargetProc;
  Test.AssertInt(42, fn(), "call via procvar")
END SaTProcAddr;

PROCEDURE SaGetParamAdr(p: INTEGER): SYSTEM.ADDRESS;
BEGIN RETURN SYSTEM.ADR(p) END SaGetParamAdr;

PROCEDURE SaTNonVarParam*;
VAR a1, a2: SYSTEM.ADDRESS;
BEGIN
  a1 := SaGetParamAdr(10);
  a2 := SaGetParamAdr(20);
  Test.AssertTrue(a1 # 0, "param adr non-zero");
  Test.AssertInt(a1, a2,  "frame-stable param adr")
END SaTNonVarParam;

PROCEDURE SaGetVarParamAdr(VAR v: INTEGER): SYSTEM.ADDRESS;
BEGIN RETURN SYSTEM.ADR(v) END SaGetVarParamAdr;

PROCEDURE SaGetVarParamAdrAndWrite(VAR v: INTEGER; val: INTEGER): SYSTEM.ADDRESS;
BEGIN v := val; RETURN SYSTEM.ADR(v) END SaGetVarParamAdrAndWrite;

PROCEDURE SaTVarParam*;
VAR x: INTEGER;
    directAdr, viaAdr: SYSTEM.ADDRESS;
BEGIN
  x := 0;
  directAdr := SYSTEM.ADR(x);
  viaAdr := SaGetVarParamAdr(x);
  Test.AssertInt(directAdr, viaAdr, "var-param adr = direct adr");
  SagInt := 0;
  viaAdr := SaGetVarParamAdrAndWrite(SagInt, 5555);
  Test.AssertInt(5555,             SagInt,   "write via var-param ADR");
  Test.AssertInt(SYSTEM.ADR(SagInt), viaAdr, "var-param adr = global adr")
END SaTVarParam;

PROCEDURE StTLiterals*;
VAR s: SET;
BEGIN
  s := {};
  Test.AssertTrue(s = {}, "empty set = {}");
  s := {0};
  Test.AssertTrue(0 IN s,  "{0}: bit 0 set");
  Test.AssertFalse(1 IN s, "{0}: bit 1 not set");
  s := {3, 5, 7};
  Test.AssertTrue(3 IN s,  "{3,5,7}: bit 3 set");
  Test.AssertTrue(5 IN s,  "{3,5,7}: bit 5 set");
  Test.AssertTrue(7 IN s,  "{3,5,7}: bit 7 set");
  Test.AssertFalse(4 IN s, "{3,5,7}: bit 4 not set");
  s := {0..7};
  Test.AssertTrue(0 IN s,  "{0..7}: bit 0 set");
  Test.AssertTrue(7 IN s,  "{0..7}: bit 7 set");
  Test.AssertFalse(8 IN s, "{0..7}: bit 8 not set");

  (* SET is a 16-bit WORD on this target; bit 15 is the high bit. *)
  s := {15};
  Test.AssertTrue(15 IN s,  "{15}: bit 15 set");
  Test.AssertFalse(14 IN s, "{15}: bit 14 not set");
  Test.AssertFalse(0  IN s, "{15}: bit 0 not set");

  s := {0..15};
  Test.AssertTrue(0  IN s,  "{0..15}: bit 0 set");
  Test.AssertTrue(8  IN s,  "{0..15}: bit 8 set");
  Test.AssertTrue(15 IN s,  "{0..15}: bit 15 set");

  (* SET difference at the boundary *)
  s := {0..15} - {15};
  Test.AssertFalse(15 IN s, "{0..15}-{15}: bit 15 cleared");
  Test.AssertTrue(14 IN s,  "{0..15}-{15}: bit 14 retained")
END StTLiterals;

PROCEDURE StTOperators*;
VAR a, b, c: SET;
BEGIN
  a := {1, 3, 5}; b := {3, 5, 7};
  c := a + b;
  Test.AssertTrue(1 IN c,  "union: 1");
  Test.AssertTrue(3 IN c,  "union: 3");
  Test.AssertTrue(5 IN c,  "union: 5");
  Test.AssertTrue(7 IN c,  "union: 7");
  Test.AssertFalse(2 IN c, "union: 2 not set");
  c := a * b;
  Test.AssertTrue(3 IN c,  "intersect: 3");
  Test.AssertTrue(5 IN c,  "intersect: 5");
  Test.AssertFalse(1 IN c, "intersect: 1 not set");
  Test.AssertFalse(7 IN c, "intersect: 7 not set");
  c := a - b;
  Test.AssertTrue(1 IN c,  "diff: 1");
  Test.AssertFalse(3 IN c, "diff: 3 removed");
  Test.AssertFalse(5 IN c, "diff: 5 removed");
  c := a / b;
  Test.AssertTrue(1 IN c,  "symdiff: 1");
  Test.AssertTrue(7 IN c,  "symdiff: 7");
  Test.AssertFalse(3 IN c, "symdiff: 3 cancelled");
  Test.AssertFalse(5 IN c, "symdiff: 5 cancelled")
END StTOperators;

PROCEDURE StTMembership*;
VAR s: SET; i: INTEGER;
BEGIN
  s := {2, 4, 6, 8};
  i := 4; Test.AssertTrue(i IN s,  "IN var index 4");
  i := 3; Test.AssertFalse(i IN s, "IN var index 3");
  Test.AssertFalse(0 IN s, "IN literal 0");
  Test.AssertTrue(8 IN s,  "IN literal 8")
END StTMembership;

(* SIZE(T) — compile-time byte size of a type, returned as WORD.
   Verifies primitive types, RECORD layout, ARRAY (1D + multi-dim), POINTER,
   and that SIZE() is a const expression usable in array dimensions. *)
PROCEDURE SzTPrimitives*;
BEGIN
  Test.AssertInt(2, SIZE(INTEGER),  "SIZE(INTEGER) = 2");
  Test.AssertInt(1, SIZE(BYTE),     "SIZE(BYTE) = 1");
  Test.AssertInt(1, SIZE(BOOLEAN),  "SIZE(BOOLEAN) = 1");
  Test.AssertInt(1, SIZE(CHAR),     "SIZE(CHAR) = 1");
  Test.AssertInt(2, SIZE(WORD),     "SIZE(WORD) = 2");
  Test.AssertInt(4, SIZE(LONGINT),  "SIZE(LONGINT) = 4");
  Test.AssertInt(4, SIZE(REAL),     "SIZE(REAL) = 4");
  Test.AssertInt(8, SIZE(LONGREAL), "SIZE(LONGREAL) = 8");
  Test.AssertInt(2, SIZE(SET),      "SIZE(SET) = 2")
END SzTPrimitives;

PROCEDURE SzTComposite*;
BEGIN
  Test.AssertInt(4,  SIZE(SzPoint),  "SIZE(SzPoint) = 4 (two INTEGERs)");
  Test.AssertInt(6,  SIZE(SzMixed),  "SIZE(SzMixed) = 6 (BYTE + pad + LONGINT)");
  Test.AssertInt(20, SIZE(SzVec10),  "SIZE(SzVec10) = 20 (10 * INTEGER)");
  Test.AssertInt(12, SIZE(SzMat3x4), "SIZE(SzMat3x4) = 12 (3*4 BYTE)");
  Test.AssertInt(4,  SIZE(SzPNode),  "SIZE(SzPNode) = 4 (far pointer)");
  Test.AssertInt(6,  SIZE(SzNode),   "SIZE(SzNode) = 6 (INTEGER + far pointer)")
END SzTComposite;

(* SIZE is a compile-time constant — usable in CASE labels, array dims,
   and CONST expressions. *)
PROCEDURE SzTConstExpr*;
  VAR a: SzArrFromSize; sel: INTEGER; r: INTEGER;
BEGIN
  Test.AssertInt(2, SzIntC,        "CONST = SIZE(INTEGER) = 2");
  Test.AssertInt(4, LEN(a),        "ARRAY SIZE(SzPoint) OF INTEGER has 4 elems");

  sel := 4; r := 0;
  CASE sel OF
    SIZE(BYTE):    r := 1
  | SIZE(INTEGER): r := 2
  | SIZE(SzPoint): r := 4
  ELSE r := 99 END;
  Test.AssertInt(4, r, "CASE label = SIZE(SzPoint)")
END SzTConstExpr;

(* LEN(fixed-array) is a compile-time WORD constant — usable like SIZE.
   Open-array LEN (inside a procedure body with VAR p: ARRAY OF T) stays
   a runtime load; this test only covers the fixed-size constant path. *)
PROCEDURE SzTLenConst*;
  VAR sel: INTEGER; r: INTEGER;
      v: ARRAY LEN(SagArr) OF INTEGER;
BEGIN
  (* LEN(SagArr) is a constant 8, usable as an array dimension. *)
  Test.AssertInt(8, LEN(SagArr), "LEN(SagArr) runtime = 8");
  Test.AssertInt(8, LEN(v),      "ARRAY LEN(SagArr) OF INTEGER has 8 elems");

  sel := 8; r := 0;
  CASE sel OF
    LEN(SigSrc):  r := 4   (* LEN(SigSrc)=4 *)
  | LEN(SagArr):  r := 8   (* LEN(SagArr)=8 — match *)
  | LEN(SigFill): r := 6   (* LEN(SigFill)=6 *)
  ELSE r := 99 END;
  Test.AssertInt(8, r, "CASE label = LEN(SagArr)")
END SzTLenConst;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(SyTConstants, "Sy/constants");
  Test.AddTest(SyTRegisters, "Sy/registers");
  Test.AddTest(SyTIntr, "Sy/intr");
  Test.AddTest(SyTNewDispose, "Sy/newDispose");
  Test.AddTest(SiTSegGlobal, "Si/segGlobal");
  Test.AddTest(SiTSegLocal, "Si/segLocal");
  Test.AddTest(SiTSegVarParam, "Si/segVarParam");
  Test.AddTest(SiTSegNonVarParam, "Si/segNonVarParam");
  Test.AddTest(SiTSegDeref, "Si/segDeref");
  Test.AddTest(SiTOfsGlobal, "Si/ofsGlobal");
  Test.AddTest(SiTOfsLocal, "Si/ofsLocal");
  Test.AddTest(SiTOfsVarParam, "Si/ofsVarParam");
  Test.AddTest(SiTOfsNonVarParam, "Si/ofsNonVarParam");
  Test.AddTest(SiTOfsDeref, "Si/ofsDeref");
  Test.AddTest(SiTMoveGlobal, "Si/moveGlobal");
  Test.AddTest(SiTMoveVarParam, "Si/moveVarParam");
  Test.AddTest(SiTFillGlobal, "Si/fillGlobal");
  Test.AddTest(SiTFillGlobalByte, "Si/fillGlobalByte");
  Test.AddTest(SiTFillVarParam, "Si/fillVarParam");
  Test.AddTest(SiTPtrDeref, "Si/ptrDeref");
  Test.AddTest(SiTPtrDerefHeap, "Si/ptrDerefHeap");
  Test.AddTest(SaTGlobalVar, "Sa/globalVar");
  Test.AddTest(SaTGlobalArray, "Sa/globalArray");
  Test.AddTest(SaTGlobalRecord, "Sa/globalRecord");
  Test.AddTest(SaTLocalVar, "Sa/localVar");
  Test.AddTest(SaTLocalArray, "Sa/localArray");
  Test.AddTest(SaTLocalRecord, "Sa/localRecord");
  Test.AddTest(SaTProcAddr, "Sa/procAddr");
  Test.AddTest(SaTNonVarParam, "Sa/nonVarParam");
  Test.AddTest(SaTVarParam, "Sa/varParam");
  Test.AddTest(StTLiterals, "St/literals");
  Test.AddTest(StTOperators, "St/operators");
  Test.AddTest(StTMembership, "St/membership");
  Test.AddTest(SzTPrimitives, "Sz/primitives");
  Test.AddTest(SzTComposite, "Sz/composite");
  Test.AddTest(SzTConstExpr, "Sz/constExpr");
  Test.AddTest(SzTLenConst, "Sz/lenConst");
  Test.RunTests
END RunAllTests;

END SYS1.
