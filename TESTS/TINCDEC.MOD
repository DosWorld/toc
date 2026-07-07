MODULE TINCDEC;
(* Regression test for the INC/DEC memory-destination codegen optimization.

   When the INC/DEC target is a plain near variable at a fixed compile-time
   address (MGlobal in DS / MLocal on BP, not a far ref) OR a far ref whose
   pointer lives in a fixed slot (p^, VAR param), the compiler now emits an
   op directly on memory (INC WORD [x], ADD [x],N, 26 FF 07 for [ES:BX], ...)
   instead of the LOAD+op+STORE round-trip.

   This test verifies the *values* are still correct across every type / mode /
   step combination — a bad opcode/modrm/carry would corrupt them. *)

IMPORT Test;

TYPE
  IntPtr  = POINTER TO INTEGER;
  ByteRec = RECORD b: BYTE END;

VAR
  gI: INTEGER;  gW: WORD;  gB: BYTE;  gC: CHAR;  gL: LONGINT;
  gA: SYSTEM.ADDRESS;

(* --------- globals (MGlobal), step 1 --------- *)
PROCEDURE TGlobalStep1*;
BEGIN
  gI := 10; INC(gI); Test.AssertInt(11, gI, "gI INC");
  gI := 10; DEC(gI); Test.AssertInt(9, gI, "gI DEC");
  gW := 0FFFEH; INC(gW); Test.AssertWord(0FFFFH, gW, "gW INC");
  gW := 1; DEC(gW); Test.AssertWord(0, gW, "gW DEC");
  gB := 5; INC(gB); Test.AssertByte(6, gB, "gB INC");
  gB := 5; DEC(gB); Test.AssertByte(4, gB, "gB DEC");
  gC := "A"; INC(gC); Test.AssertInt(ORD("B"), ORD(gC), "gC INC");
  gC := "B"; DEC(gC); Test.AssertInt(ORD("A"), ORD(gC), "gC DEC");
  (* LONGINT with carry across the 16-bit boundary *)
  gL := 0FFFFH; INC(gL); Test.AssertLong(10000H, gL, "gL INC carry");
  gL := 10000H; DEC(gL); Test.AssertLong(0FFFFH, gL, "gL DEC borrow")
END TGlobalStep1;

(* --------- globals, constant step --------- *)
PROCEDURE TGlobalStepConst*;
BEGIN
  gI := 100; INC(gI, 5);  Test.AssertInt(105, gI, "gI INC 5");
  gI := 100; DEC(gI, 30); Test.AssertInt(70, gI, "gI DEC 30");
  (* step wider than a signed byte -> imm16 form *)
  gI := 0; INC(gI, 1000); Test.AssertInt(1000, gI, "gI INC 1000");
  gB := 10; INC(gB, 20); Test.AssertByte(30, gB, "gB INC 20");
  gB := 50; DEC(gB, 8);  Test.AssertByte(42, gB, "gB DEC 8");
  gL := 0; INC(gL, 100000); Test.AssertLong(100000, gL, "gL INC 100000 (>16b)");
  gL := 100000; DEC(gL, 100000); Test.AssertLong(0, gL, "gL DEC 100000")
END TGlobalStepConst;

(* --------- globals, runtime step --------- *)
PROCEDURE TGlobalStepVar*;
  VAR s: INTEGER; sl: LONGINT;
BEGIN
  s := 7; gI := 3; INC(gI, s); Test.AssertInt(10, gI, "gI INC var");
  s := 4; gI := 10; DEC(gI, s); Test.AssertInt(6, gI, "gI DEC var");
  sl := 70000; gL := 0; INC(gL, sl); Test.AssertLong(70000, gL, "gL INC var")
END TGlobalStepVar;

(* --------- locals (MLocal on BP) --------- *)
PROCEDURE TLocal*;
  VAR i: INTEGER; b: BYTE; l: LONGINT; s: INTEGER;
BEGIN
  i := 10; INC(i); Test.AssertInt(11, i, "loc i INC");
  i := 10; DEC(i, 4); Test.AssertInt(6, i, "loc i DEC 4");
  b := 1; INC(b, 250); Test.AssertByte(251, b, "loc b INC 250");
  l := 0FFFFH; INC(l); Test.AssertLong(10000H, l, "loc l INC carry");
  s := 5; i := 0; INC(i, s); Test.AssertInt(5, i, "loc i INC var")
END TLocal;

(* --------- far ref via pointer (p^, isRef) --------- *)
PROCEDURE TPtrDeref*;
  VAR p: IntPtr;
BEGIN
  NEW(p);
  p^ := 10; INC(p^);        Test.AssertInt(11, p^, "p^ INC");
  p^ := 10; DEC(p^);        Test.AssertInt(9,  p^, "p^ DEC");
  p^ := 100; INC(p^, 5);    Test.AssertInt(105, p^, "p^ INC 5");
  p^ := 100; DEC(p^, 40);   Test.AssertInt(60,  p^, "p^ DEC 40");
  p^ := 0; INC(p^, 2000);   Test.AssertInt(2000, p^, "p^ INC 2000 (imm16)");
  DISPOSE(p)
END TPtrDeref;

(* --------- far ref via VAR param (isRef) --------- *)
PROCEDURE BumpVar(VAR x: INTEGER; n: INTEGER);
BEGIN
  INC(x);        (* step 1 on a VAR param -> [ES:BX] *)
  INC(x, 10);    (* const step on a VAR param *)
  INC(x, n)      (* runtime step on a VAR param -> fallback path *)
END BumpVar;

PROCEDURE TVarParam*;
  VAR v: INTEGER;
BEGIN
  v := 0; BumpVar(v, 100);
  Test.AssertInt(111, v, "VAR param INC 1+10+100")
END TVarParam;

(* --------- SYSTEM.ADDRESS (offset math, no carry into segment) --------- *)
PROCEDURE TAddr*;
  VAR a: SYSTEM.ADDRESS; base: SYSTEM.ADDRESS;
BEGIN
  gA := SYSTEM.ADR(gI);
  base := gA;
  INC(gA, 4);
  Test.AssertTrue(gA = base + 4, "gA INC 4 offset");
  DEC(gA, 4);
  Test.AssertTrue(gA = base, "gA DEC 4 offset");
  a := SYSTEM.ADR(gI);   (* local ADDRESS *)
  base := a;
  INC(a, 2);
  Test.AssertTrue(a = base + 2, "loc a INC 2 offset")
END TAddr;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TGlobalStep1,     "TINCDEC/globalStep1");
  Test.AddTest(TGlobalStepConst, "TINCDEC/globalStepConst");
  Test.AddTest(TGlobalStepVar,   "TINCDEC/globalStepVar");
  Test.AddTest(TLocal,           "TINCDEC/local");
  Test.AddTest(TPtrDeref,        "TINCDEC/ptrDeref");
  Test.AddTest(TVarParam,        "TINCDEC/varParam");
  Test.AddTest(TAddr,            "TINCDEC/addr");
  Test.RunTests
END RunAllTests;

END TINCDEC.
