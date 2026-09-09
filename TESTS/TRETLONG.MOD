MODULE TRETLONG;
(* Regression test: RETURN of a value narrower than the function's declared
   LONGINT result type.

   Bug reported + fixed 2026-09-09.  PStmt.ParseReturn called CgLoadItem on
   the returned expression but never widened it to the declared result type,
   unlike the assignment path (ParseAssign's TFLongint branch, which both
   retypes an MConst and emits CWD/XOR DX,DX).  A LONGINT function returning
   anything 16-bit therefore loaded AX and left DX holding junk:

     RETURN -1  ->  65535       (0000FFFF -- high half never written)
     RETURN 1   ->  655361      (000A0001 -- DX held unrelated garbage)

   `x := -1; RETURN x` was correct, which is why the fault looked specific to
   the literal.  It was not: it affected every narrower-than-LONGINT RETURN,
   constant or not, negative or positive.  -100000 escaped only because it
   genuinely needs 32 bits and so was already loaded as a 32-bit constant.

   IMPORTANT for anyone extending this test: each result is captured into a
   LONGINT variable and the VARIABLE is asserted.  Passing the call directly
   as an actual parameter (`Test.AssertLong(-1, RNeg1(), ...)`) MASKS the bug
   -- the actual-parameter path widens the value on its way onto the stack, so
   the assertion sees a correct -1 even when the RETURN itself was broken.
   An earlier draft of this test did exactly that and passed against the
   unfixed compiler, i.e. tested nothing. *)

IMPORT Test;

VAR gw: WORD; gb: BYTE; gi: INTEGER;

(* --- negative literals: the reported shape --- *)
PROCEDURE RNeg1():      LONGINT; BEGIN RETURN -1 END RNeg1;
PROCEDURE RNeg2():      LONGINT; BEGIN RETURN -2 END RNeg2;
PROCEDURE RNeg32767():  LONGINT; BEGIN RETURN -32767 END RNeg32767;
PROCEDURE RNeg32768():  LONGINT; BEGIN RETURN -32768 END RNeg32768;
(* genuinely 32-bit: already worked, kept as a control *)
PROCEDURE RNegBig():    LONGINT; BEGIN RETURN -100000 END RNegBig;

(* --- positive literals: broken too, though the report only saw negatives --- *)
PROCEDURE RPos0():      LONGINT; BEGIN RETURN 0 END RPos0;
PROCEDURE RPos1():      LONGINT; BEGIN RETURN 1 END RPos1;
PROCEDURE RPos32767():  LONGINT; BEGIN RETURN 32767 END RPos32767;
PROCEDURE RPosBig():    LONGINT; BEGIN RETURN 100000 END RPosBig;

(* --- non-constant expressions --- *)
PROCEDURE RExpr():      LONGINT; BEGIN RETURN 0 - 1 END RExpr;
PROCEDURE RFromInt():   LONGINT; BEGIN RETURN gi END RFromInt;

(* --- unsigned sources must ZERO-extend, not sign-extend --- *)
PROCEDURE RFromWord():  LONGINT; BEGIN RETURN gw END RFromWord;
PROCEDURE RFromByte():  LONGINT; BEGIN RETURN gb END RFromByte;
PROCEDURE RWordLit():   LONGINT; BEGIN RETURN 0FFFFH END RWordLit;

(* --- RETURN from inside nested control flow (different emit context) --- *)
PROCEDURE RInIf(n: INTEGER): LONGINT;
BEGIN
  IF n > 0 THEN RETURN -1 ELSE RETURN -2 END
END RInIf;

PROCEDURE RInWhile(): LONGINT;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < 3 DO
    IF k = 1 THEN RETURN -7 END;
    INC(k)
  END;
  RETURN 0
END RInWhile;

PROCEDURE RInCase(n: INTEGER): LONGINT;
BEGIN
  CASE n OF
    1: RETURN -1
  | 2: RETURN -2
  ELSE RETURN -3
  END
END RInCase;

(* --- INTEGER-returning functions must stay unaffected --- *)
PROCEDURE IntNeg1(): INTEGER; BEGIN RETURN -1 END IntNeg1;

PROCEDURE TNegLiterals*;
  VAR v: LONGINT;
BEGIN
  v := RNeg1();     Test.AssertLong(-1,      v, "RETURN -1");
  v := RNeg2();     Test.AssertLong(-2,      v, "RETURN -2");
  v := RNeg32767(); Test.AssertLong(-32767,  v, "RETURN -32767");
  v := RNeg32768(); Test.AssertLong(-32768,  v, "RETURN -32768");
  v := RNegBig();   Test.AssertLong(-100000, v, "RETURN -100000")
END TNegLiterals;

PROCEDURE TPosLiterals*;
  VAR v: LONGINT;
BEGIN
  v := RPos0();     Test.AssertLong(0,      v, "RETURN 0");
  v := RPos1();     Test.AssertLong(1,      v, "RETURN 1");
  v := RPos32767(); Test.AssertLong(32767,  v, "RETURN 32767");
  v := RPosBig();   Test.AssertLong(100000, v, "RETURN 100000")
END TPosLiterals;

PROCEDURE TExpressions*;
  VAR v: LONGINT;
BEGIN
  gi := -1;
  v := RExpr();    Test.AssertLong(-1, v, "RETURN 0-1");
  v := RFromInt(); Test.AssertLong(-1, v, "RETURN <INTEGER var> = -1");
  gi := 12345;
  v := RFromInt(); Test.AssertLong(12345, v, "RETURN <INTEGER var> = 12345")
END TExpressions;

PROCEDURE TUnsignedSources*;
  VAR v: LONGINT;
BEGIN
  gw := 0FFFFH; gb := 255;
  v := RFromWord(); Test.AssertLong(65535, v, "RETURN <WORD var> 0FFFFH zero-extends");
  v := RFromByte(); Test.AssertLong(255,   v, "RETURN <BYTE var> 255 zero-extends");
  v := RWordLit();  Test.AssertLong(65535, v, "RETURN 0FFFFH literal");
  gw := 0; gb := 0;
  v := RFromWord(); Test.AssertLong(0, v, "RETURN <WORD var> 0");
  v := RFromByte(); Test.AssertLong(0, v, "RETURN <BYTE var> 0")
END TUnsignedSources;

PROCEDURE TControlFlow*;
  VAR v: LONGINT;
BEGIN
  v := RInIf(1);   Test.AssertLong(-1, v, "RETURN -1 inside IF-THEN");
  v := RInIf(0);   Test.AssertLong(-2, v, "RETURN -2 inside IF-ELSE");
  v := RInWhile(); Test.AssertLong(-7, v, "RETURN -7 inside WHILE");
  v := RInCase(1); Test.AssertLong(-1, v, "RETURN -1 inside CASE arm");
  v := RInCase(2); Test.AssertLong(-2, v, "RETURN -2 inside CASE arm");
  v := RInCase(9); Test.AssertLong(-3, v, "RETURN -3 inside CASE ELSE")
END TControlFlow;

PROCEDURE TIntegerUnaffected*;
  VAR i: INTEGER;
BEGIN
  i := IntNeg1(); Test.AssertInt(-1, i, "INTEGER RETURN -1")
END TIntegerUnaffected;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TNegLiterals,      "TRETLONG/negLiterals");
  Test.AddTest(TPosLiterals,      "TRETLONG/posLiterals");
  Test.AddTest(TExpressions,      "TRETLONG/expressions");
  Test.AddTest(TUnsignedSources,  "TRETLONG/unsignedSources");
  Test.AddTest(TControlFlow,      "TRETLONG/controlFlow");
  Test.AddTest(TIntegerUnaffected,"TRETLONG/integerUnaffected");
  Test.RunTests
END RunAllTests;

END TRETLONG.
