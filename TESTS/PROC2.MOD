MODULE PROC2;
IMPORT Test;

TYPE
  PvProcIntInt = PROCEDURE(a,b: INTEGER): INTEGER;
  PvProcInt    = PROCEDURE(x: INTEGER): INTEGER;
  PvPProcInt   = POINTER TO PvProcInt;
  PvRecWithProc = RECORD
    name: ARRAY 16 OF CHAR;
  Pvfunc: PROCEDURE(a,b: INTEGER): INTEGER
  END;
  PtCallbackProc* = PROCEDURE(x: INTEGER);

VAR
  ApgX: INTEGER;
  Pvfn:     PROCEDURE(a,b: INTEGER): INTEGER;
  Pvfn1:    PROCEDURE(x: INTEGER): INTEGER;
  PvprocArr: ARRAY 4 OF PROCEDURE(x: INTEGER): INTEGER;
  Pvrec:    PvRecWithProc;
  Pvpproc:  PvPProcInt;
  PvnilProc: PROCEDURE;
  Ptrecorded: INTEGER;
  TvgInt, TvgInt2, TvgInt3: INTEGER;

PROCEDURE ApAdrOfNonVar(p: INTEGER): SYSTEM.ADDRESS;
BEGIN RETURN SYSTEM.ADR(p) END ApAdrOfNonVar;

PROCEDURE ApAdrOfVarParam(VAR v: INTEGER): SYSTEM.ADDRESS;
BEGIN RETURN SYSTEM.ADR(v) END ApAdrOfVarParam;

PROCEDURE ApWriteViaAdr(VAR v: INTEGER; val: INTEGER);
VAR ip: POINTER TO INTEGER;
BEGIN
  ip := SYSTEM.ADR(v);
  ip^ := val
END ApWriteViaAdr;

PROCEDURE ApTNonVarParam*;
VAR a1: SYSTEM.ADDRESS; p: INTEGER;
BEGIN
  p := 0;
  a1 := ApAdrOfNonVar(p);
  Test.AssertNotNil(a1, "adr non-nil")
END ApTNonVarParam;

PROCEDURE ApTVarParam*;
VAR x: INTEGER;
    adrX, adrVia: SYSTEM.ADDRESS;
BEGIN
  x := 0;
  adrX := SYSTEM.ADR(x);
  adrVia := ApAdrOfVarParam(x);
  Test.AssertInt(adrX, adrVia, "adr via VAR = direct adr")
END ApTVarParam;

PROCEDURE ApTWriteViaVarParamAdr*;
BEGIN
  ApgX := 0;
  ApWriteViaAdr(ApgX, 7777);
  Test.AssertInt(7777, ApgX, "write-back via VAR ADR")
END ApTWriteViaVarParamAdr;

PROCEDURE ApTGlobalVarParam*;
VAR adrVia: SYSTEM.ADDRESS;
BEGIN
  ApgX := 0;
  adrVia := ApAdrOfVarParam(ApgX);
  Test.AssertNotNil(adrVia, "adr non-nil");
  ApWriteViaAdr(ApgX, 4321);
  Test.AssertInt(4321, ApgX, "global write via VAR ADR")
END ApTGlobalVarParam;

PROCEDURE PvAdd(a, b: INTEGER): INTEGER; FAR;
BEGIN RETURN a + b END PvAdd;

PROCEDURE PvSub(a, b: INTEGER): INTEGER; FAR;
BEGIN RETURN a - b END PvSub;

PROCEDURE PvDouble(x: INTEGER): INTEGER; FAR;
BEGIN RETURN x + x END PvDouble;

PROCEDURE PvFactorialRec(n: INTEGER): INTEGER; FAR;
BEGIN
  IF n <= 1 THEN RETURN 1 ELSE RETURN n * Pvfn1(n-1) END
END PvFactorialRec;

PROCEDURE PvApplyTwice(f: PROCEDURE(x: INTEGER): INTEGER; val: INTEGER): INTEGER; FAR;
BEGIN RETURN f(f(val)) END PvApplyTwice;

PROCEDURE PvChooseOperation(op: INTEGER): PROCEDURE(a,b: INTEGER): INTEGER; FAR;
VAR res: PROCEDURE(a,b: INTEGER): INTEGER;
BEGIN
  IF op = 1 THEN res := PvAdd ELSE res := PvSub END;
  RETURN res
END PvChooseOperation;

PROCEDURE PvCallWithTwo(f: PROCEDURE(a,b: INTEGER): INTEGER; a,b: INTEGER): INTEGER; FAR;
BEGIN RETURN f(a,b) END PvCallWithTwo;

PROCEDURE PvTBasicFarProcVar*;
VAR r: INTEGER;
BEGIN
  Pvfn := PvAdd; r := Pvfn(3,4); Test.AssertInt(7, r, "FAR PvAdd(3,4)");
  Pvfn := PvSub; r := Pvfn(10,3); Test.AssertInt(7, r, "FAR PvSub(10,3)");
  Pvfn := PvAdd; r := Pvfn(Pvfn(1,2), Pvfn(3,4)); Test.AssertInt(10, r, "nested PvAdd")
END PvTBasicFarProcVar;

PROCEDURE PvTUnaryProcVar*;
VAR r: INTEGER;
BEGIN
  Pvfn1 := PvDouble; r := Pvfn1(5);           Test.AssertInt(10, r, "PvDouble(5)");
  r := Pvfn1(Pvfn1(3));                      Test.AssertInt(12, r, "PvDouble(PvDouble(3))")
END PvTUnaryProcVar;

PROCEDURE PvTProcAsArg*;
VAR r: INTEGER;
BEGIN
  r := PvCallWithTwo(PvAdd, 5, 6);  Test.AssertInt(11, r, "PvCallWithTwo(PvAdd)");
  r := PvCallWithTwo(PvSub, 20, 7); Test.AssertInt(13, r, "PvCallWithTwo(PvSub)");
  r := PvApplyTwice(PvDouble, 3);   Test.AssertInt(12, r, "PvApplyTwice(PvDouble,3)")
END PvTProcAsArg;

PROCEDURE PvTProcAsReturn*;
VAR p: PvProcIntInt; r: INTEGER;
BEGIN
  p := PvChooseOperation(1); r := p(100, 200); Test.AssertInt(300,  r, "Choose(1)=PvAdd");
  p := PvChooseOperation(2); r := p(100, 200); Test.AssertInt(-100, r, "Choose(2)=PvSub")
END PvTProcAsReturn;

PROCEDURE PvTProcArray*;
VAR r: INTEGER;
BEGIN
  PvprocArr[0] := PvDouble; PvprocArr[1] := PvDouble;
  PvprocArr[2] := PvDouble; PvprocArr[3] := PvDouble;
  r := PvprocArr[0](5) + PvprocArr[1](5) + PvprocArr[2](5) + PvprocArr[3](5);
  Test.AssertInt(40, r, "Array of proc vars: 4*PvDouble(5)")
END PvTProcArray;

PROCEDURE PvTProcInRecord*;
VAR r: INTEGER;
BEGIN
  Pvrec.Pvfunc := PvAdd; r := Pvrec.Pvfunc(7,8);  Test.AssertInt(15, r, "Pvrec.Pvfunc=PvAdd(7,8)");
  Pvrec.Pvfunc := PvSub; r := Pvrec.Pvfunc(15,3); Test.AssertInt(12, r, "Pvrec.Pvfunc=PvSub(15,3)")
END PvTProcInRecord;

PROCEDURE PvTPointerToProc*;
VAR r: INTEGER;
BEGIN
  NEW(Pvpproc);
  Pvpproc^ := PvDouble;
  r := Pvpproc^(9);
  Test.AssertInt(18, r, "Pvpproc^=PvDouble(9)")
END PvTPointerToProc;

PROCEDURE PvTNilProcVar*;
BEGIN
  PvnilProc := NIL;
  Test.AssertNil(PvnilProc, "NIL assignment");
  Pvfn := NIL;
  Test.AssertNil(Pvfn, "FAR proc var assigned NIL")
END PvTNilProcVar;

PROCEDURE PvTReassign*;
VAR r: INTEGER;
BEGIN
  Pvfn := PvAdd; r := Pvfn(1,2);  Test.AssertInt(3, r, "After PvAdd 1");
  Pvfn := PvSub; r := Pvfn(5,2);  Test.AssertInt(3, r, "After PvSub 1");
  Pvfn := PvAdd; r := Pvfn(2,3);  Test.AssertInt(5, r, "After PvAdd 2");
  Pvfn := PvSub; r := Pvfn(10,4); Test.AssertInt(6, r, "After PvSub 2")
END PvTReassign;

PROCEDURE PvTOverflow*;
VAR r: INTEGER;
BEGIN
  Pvfn := PvAdd;
  r := Pvfn(32767, 1);     Test.AssertInt(-32768, r, "Overflow 32767+1");
  r := Pvfn(-32768, -1);   Test.AssertInt(32767,  r, "Underflow -32768-1");
  Pvfn1 := PvDouble;
  r := Pvfn1(16384);       Test.AssertInt(-32768, r, "PvDouble overflow 2*16384")
END PvTOverflow;

PROCEDURE PvTRecursionViaProcVar*;
VAR r: INTEGER;
BEGIN
  Pvfn1 := PvFactorialRec;
  r := Pvfn1(5);
  Test.AssertInt(120, r, "factorial(5) via proc var")
END PvTRecursionViaProcVar;

PROCEDURE PtRecorder(x: INTEGER); FAR;
BEGIN Ptrecorded := x END PtRecorder;

PROCEDURE PtInvokeViaProcParam(cb: PtCallbackProc; v: INTEGER);
BEGIN cb(v) END PtInvokeViaProcParam;

PROCEDURE PtCallTwice(cb: PtCallbackProc; a, b: INTEGER);
BEGIN cb(a); cb(b) END PtCallTwice;

PROCEDURE PtTakeInt(x: INTEGER): INTEGER;
BEGIN RETURN x + 1 END PtTakeInt;

PROCEDURE PtLongToInt(): LONGINT;
BEGIN RETURN LONGINT(41) END PtLongToInt;

PROCEDURE PtTDirectCall*;
BEGIN
  PtRecorder(7);
  Test.AssertInt(7, Ptrecorded, "direct FAR call")
END PtTDirectCall;

PROCEDURE PtTProcParam*;
BEGIN
  Ptrecorded := 0;
  PtInvokeViaProcParam(PtRecorder, 42);
  Test.AssertInt(42, Ptrecorded, "PtInvokeViaProcParam")
END PtTProcParam;

PROCEDURE PtTCallTwice*;
BEGIN
  Ptrecorded := 0;
  PtCallTwice(PtRecorder, 11, 99);
  Test.AssertInt(99, Ptrecorded, "PtCallTwice last wins")
END PtTCallTwice;

PROCEDURE PtTNarrowing*;
VAR n: INTEGER;
BEGIN
  n := PtTakeInt(INTEGER(PtLongToInt()));
  Test.AssertInt(42, n, "PtTakeInt(LONGINT(41))")
END PtTNarrowing;

PROCEDURE TvGetAddr(VAR p): SYSTEM.ADDRESS;
BEGIN RETURN p END TvGetAddr;

PROCEDURE TvWriteInt(VAR p; val: INTEGER);
VAR ip: POINTER TO INTEGER;
BEGIN ip := p; ip^ := val END TvWriteInt;

PROCEDURE TvReadInt(VAR p): INTEGER;
VAR ip: POINTER TO INTEGER;
BEGIN ip := p; RETURN ip^ END TvReadInt;

PROCEDURE TvSwapInt(VAR a; VAR b);
VAR tmp: INTEGER;
BEGIN
  tmp := TvReadInt(a);
  TvWriteInt(a, TvReadInt(b));
  TvWriteInt(b, tmp)
END TvSwapInt;

PROCEDURE TvBump(VAR counter);
VAR ip: POINTER TO INTEGER;
BEGIN ip := counter; INC(ip^) END TvBump;

PROCEDURE TvTGetAddrGlobal*;
VAR addr: SYSTEM.ADDRESS;
BEGIN
  TvgInt := 42;
  addr := TvGetAddr(TvgInt);
  Test.AssertNotNil(addr, "TvGetAddr global # 0")
END TvTGetAddrGlobal;

PROCEDURE TvTDistinctAddrs*;
VAR a1, a2: SYSTEM.ADDRESS;
BEGIN
  TvgInt2 := 0;
  a1 := TvGetAddr(TvgInt);
  a2 := TvGetAddr(TvgInt2);
  Test.AssertTrue(a1 # a2, "globals have distinct addrs")
END TvTDistinctAddrs;

PROCEDURE TvTReadInt*;
BEGIN
  TvgInt := 99;
  Test.AssertInt(99, TvReadInt(TvgInt), "TvReadInt 99")
END TvTReadInt;

PROCEDURE TvTWriteInt*;
BEGIN
  TvWriteInt(TvgInt, 77);
  Test.AssertInt(77, TvgInt, "TvWriteInt 77")
END TvTWriteInt;

PROCEDURE TvTLocalAddr*;
VAR lInt: INTEGER; addr: SYSTEM.ADDRESS;
BEGIN
  lInt := 55;
  addr := TvGetAddr(lInt);
  Test.AssertNotNil(addr, "TvGetAddr local # 0")
END TvTLocalAddr;

PROCEDURE TvTStableAddr*;
VAR a1, a2: SYSTEM.ADDRESS;
BEGIN
  TvgInt := 5;
  a1 := TvGetAddr(TvgInt);
  a2 := TvGetAddr(TvgInt);
  Test.AssertTrue(a1 = a2, "stable addr")
END TvTStableAddr;

PROCEDURE TvTSwapInt*;
BEGIN
  TvgInt := 10; TvgInt2 := 20;
  TvSwapInt(TvgInt, TvgInt2);
  Test.AssertInt(20, TvgInt,  "swapped TvgInt");
  Test.AssertInt(10, TvgInt2, "swapped TvgInt2")
END TvTSwapInt;

PROCEDURE TvTBump*;
BEGIN
  TvgInt3 := 0;
  TvBump(TvgInt3); TvBump(TvgInt3); TvBump(TvgInt3);
  Test.AssertInt(3, TvgInt3, "TvBump x3")
END TvTBump;

PROCEDURE TvTMixedParams*;
BEGIN
  TvgInt := 5; TvgInt2 := 7;
  TvWriteInt(TvgInt, TvReadInt(TvgInt2));
  Test.AssertInt(7, TvgInt, "TvWriteInt via TvReadInt")
END TvTMixedParams;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(ApTNonVarParam, "Ap/nonVar");
  Test.AddTest(ApTVarParam, "Ap/var");
  Test.AddTest(ApTWriteViaVarParamAdr, "Ap/writeVia");
  Test.AddTest(ApTGlobalVarParam, "Ap/globalVar");
  Test.AddTest(PvTBasicFarProcVar, "Pv/basic");
  Test.AddTest(PvTUnaryProcVar, "Pv/unary");
  Test.AddTest(PvTProcAsArg, "Pv/asArg");
  Test.AddTest(PvTProcAsReturn, "Pv/asReturn");
  Test.AddTest(PvTProcArray, "Pv/array");
  Test.AddTest(PvTProcInRecord, "Pv/inRecord");
  Test.AddTest(PvTPointerToProc, "Pv/pointerTo");
  Test.AddTest(PvTNilProcVar, "Pv/nil");
  Test.AddTest(PvTReassign, "Pv/reassign");
  Test.AddTest(PvTOverflow, "Pv/overflow");
  Test.AddTest(PvTRecursionViaProcVar, "Pv/recursion");
  Test.AddTest(PtTDirectCall, "Pt/direct");
  Test.AddTest(PtTProcParam, "Pt/procParam");
  Test.AddTest(PtTCallTwice, "Pt/callTwice");
  Test.AddTest(PtTNarrowing, "Pt/narrowing");
  Test.AddTest(TvTGetAddrGlobal, "Tv/getAddrG");
  Test.AddTest(TvTDistinctAddrs, "Tv/distinct");
  Test.AddTest(TvTReadInt, "Tv/readInt");
  Test.AddTest(TvTWriteInt, "Tv/writeInt");
  Test.AddTest(TvTLocalAddr, "Tv/getAddrL");
  Test.AddTest(TvTStableAddr, "Tv/stableAddr");
  Test.AddTest(TvTSwapInt, "Tv/swap");
  Test.AddTest(TvTBump, "Tv/bump");
  Test.AddTest(TvTMixedParams, "Tv/mixed");
  Test.RunTests
END RunAllTests;

END PROC2.
