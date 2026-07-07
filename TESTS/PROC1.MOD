MODULE PROC1;
IMPORT Test;

TYPE
  PaRec  = RECORD x, y: INTEGER END;
  PaRec3 = RECORD a, b, c: INTEGER END;
  PaSmallArr = ARRAY 5 OF INTEGER;
  PaBigArr   = ARRAY 20 OF INTEGER;

VAR
  PrglobalCounter: INTEGER;
  (* PrTestProcedureNoParams / PrTestLocalVariables / PrTestStackFrameIsolation
     used outer-proc locals to share state with their nested helpers.  With the
     uplevel feature removed, that state lives at module level. *)
  Pra, Prb: INTEGER;
  PrlocalsGlobal: INTEGER;
  Prglobal1, Prglobal2: INTEGER;
  PrcallCount: INTEGER;
  PrdepthReached: INTEGER;
  PagArr5:  PaSmallArr;
  PagArr20: PaBigArr;
  PagStr:   ARRAY 32 OF CHAR;

PROCEDURE PrAddGlobal;
BEGIN PrglobalCounter := PrglobalCounter + 10 END PrAddGlobal;

PROCEDURE PrSetValues;
BEGIN Pra := 100; Prb := 200 END PrSetValues;

PROCEDURE PrTestProcedureNoParams*;
BEGIN
  PrglobalCounter := 0;
  PrAddGlobal;
  Test.AssertInt(10, PrglobalCounter, "AddGlobal");
  Pra := 0; Prb := 0;
  PrSetValues;
  Test.AssertInt(100, Pra, "SetValues a");
  Test.AssertInt(200, Prb, "SetValues b")
END PrTestProcedureNoParams;

PROCEDURE PrMultiply(a, b: INTEGER; VAR res: INTEGER);
BEGIN res := a * b END PrMultiply;

PROCEDURE PrSumAndSquare(x, y: INTEGER): INTEGER;
VAR s: INTEGER;
BEGIN s := x + y; RETURN s * s END PrSumAndSquare;

PROCEDURE PrNestedCalls(a, b, c: INTEGER): INTEGER;
VAR temp: INTEGER;
BEGIN temp := PrSumAndSquare(a, b); RETURN temp + c END PrNestedCalls;

PROCEDURE PrTestProcedureValueParams*;
VAR result: INTEGER;
BEGIN
  PrMultiply(15, 20, result);
  Test.AssertInt(300, result, "Multiply");
  result := PrSumAndSquare(5, 3);
  Test.AssertInt(64, result, "SumAndSquare");
  result := PrNestedCalls(2, 3, 10);
  Test.AssertInt(35, result, "NestedCalls")
END PrTestProcedureValueParams;

PROCEDURE PrIncrement(VAR x: INTEGER);
BEGIN x := x + 1 END PrIncrement;

PROCEDURE PrSwap(VAR x, y: INTEGER);
VAR temp: INTEGER;
BEGIN temp := x; x := y; y := temp END PrSwap;

PROCEDURE PrMultiplyByFactor(VAR value: INTEGER; factor: INTEGER);
BEGIN value := value * factor END PrMultiplyByFactor;

PROCEDURE PrSetToZero(VAR a, b, c: INTEGER);
BEGIN a := 0; b := 0; c := 0 END PrSetToZero;

PROCEDURE PrTestVarParameters*;
VAR a, b, c: INTEGER;
BEGIN
  a := 10; PrIncrement(a); Test.AssertInt(11, a, "Increment");
  a := 5; b := 15; PrSwap(a, b);
  Test.AssertInt(15, a, "Swap a"); Test.AssertInt(5, b, "Swap b");
  a := 7; PrMultiplyByFactor(a, 6); Test.AssertInt(42, a, "MulByFactor");
  a := 100; b := 200; c := 300; PrSetToZero(a, b, c);
  Test.AssertInt(0, a, "Zero a");
  Test.AssertInt(0, b, "Zero b");
  Test.AssertInt(0, c, "Zero c")
END PrTestVarParameters;

PROCEDURE PrComplexOp(VAR x: INTEGER; y, z: INTEGER; VAR w: INTEGER);
BEGIN x := x + y; w := x * z END PrComplexOp;

PROCEDURE PrCalculate(VAR out1: INTEGER; in1, in2: INTEGER; VAR out2: INTEGER): INTEGER;
VAR temp: INTEGER;
BEGIN temp := in1 + in2; out1 := temp * 2; out2 := temp * 3; RETURN temp END PrCalculate;

PROCEDURE PrTestMixedParameters*;
VAR a, b, result: INTEGER;
BEGIN
  a := 10; b := 5; result := 0;
  PrComplexOp(a, 3, 4, result);
  Test.AssertInt(13, a, "ComplexOp a");
  Test.AssertInt(52, result, "ComplexOp result");
  a := 0; b := 0; result := 0;
  a := PrCalculate(b, 4, 6, result);
  Test.AssertInt(10, a, "Calculate ret");
  Test.AssertInt(20, b, "Calculate b");
  Test.AssertInt(30, result, "Calculate result")
END PrTestMixedParameters;

(* PrTestLocalVariables: was using outer-proc local `global` and `b`. Lift to
   module globals (PrlocalsGlobal, Prb). *)

PROCEDURE PrNestedWithLocals(x: INTEGER): INTEGER;
VAR local1, local2, local3: INTEGER;
BEGIN
  local1 := x * 2;
  local2 := local1 + 5;
  local3 := local2 * 3;
  PrlocalsGlobal := PrlocalsGlobal + local3;
  RETURN local3
END PrNestedWithLocals;

PROCEDURE PrInnerDeep(c: INTEGER): INTEGER;
VAR d: INTEGER;
BEGIN d := c * 4; Prb := Prb + d; RETURN d END PrInnerDeep;

PROCEDURE PrDeepNested(a: INTEGER): INTEGER;
BEGIN Prb := a * 2; RETURN PrInnerDeep(Prb) END PrDeepNested;

PROCEDURE PrManyLocals(x, y, z: INTEGER): INTEGER;
VAR l1, l2, l3, l4, l5: INTEGER;
BEGIN
  l1 := x + y; l2 := y + z; l3 := l1 * l2;
  l4 := l3 DIV 10; l5 := l4 - x; RETURN l5
END PrManyLocals;

PROCEDURE PrTestLocalVariables*;
VAR res: INTEGER;
BEGIN
  PrlocalsGlobal := 0;
  res := PrNestedWithLocals(10);
  Test.AssertInt(75, res, "NestedWithLocals ret");
  Test.AssertInt(75, PrlocalsGlobal, "NestedWithLocals global");
  res := PrDeepNested(3);
  Test.AssertInt(24, res, "DeepNested");
  res := PrManyLocals(5, 10, 15);
  Test.AssertInt(32, res, "ManyLocals")
END PrTestLocalVariables;

(* PrTestRecursionFactorial: callCount lifted to module-level PrcallCount. *)

PROCEDURE PrFactorial(n: INTEGER): INTEGER;
BEGIN
  INC(PrcallCount);
  IF n <= 1 THEN RETURN 1 ELSE RETURN n * PrFactorial(n - 1) END
END PrFactorial;

PROCEDURE PrTailFactorial(n, acc: INTEGER): INTEGER;
BEGIN
  INC(PrcallCount);
  IF n <= 1 THEN RETURN acc ELSE RETURN PrTailFactorial(n - 1, n * acc) END
END PrTailFactorial;

PROCEDURE PrTestRecursionFactorial*;
VAR result: INTEGER;
BEGIN
  PrcallCount := 0; result := PrFactorial(5);
  Test.AssertInt(120, result, "fact(5)");
  Test.AssertInt(5, PrcallCount, "fact(5) calls");
  PrcallCount := 0; result := PrFactorial(1);
  Test.AssertInt(1, result, "fact(1)");
  Test.AssertInt(1, PrcallCount, "fact(1) calls");
  PrcallCount := 0; result := PrTailFactorial(5, 1);
  Test.AssertInt(120, result, "tail fact(5)");
  Test.AssertInt(5, PrcallCount, "tail fact(5) calls")
END PrTestRecursionFactorial;

PROCEDURE PrFibonacci(n: INTEGER): INTEGER;
BEGIN
  INC(PrcallCount);
  IF n <= 1 THEN RETURN n ELSE RETURN PrFibonacci(n - 1) + PrFibonacci(n - 2) END
END PrFibonacci;

PROCEDURE PrFibIterative(n: INTEGER): INTEGER;
VAR a, b, c, i: INTEGER;
BEGIN
  IF n <= 1 THEN RETURN n
  ELSE
    a := 0; b := 1;
    FOR i := 2 TO n DO c := a + b; a := b; b := c END;
    RETURN b
  END
END PrFibIterative;

PROCEDURE PrTestRecursionFibonacci*;
VAR result: INTEGER;
BEGIN
  PrcallCount := 0; result := PrFibonacci(0); Test.AssertInt(0, result, "fib(0)");
  PrcallCount := 0; result := PrFibonacci(1); Test.AssertInt(1, result, "fib(1)");
  PrcallCount := 0; result := PrFibonacci(6); Test.AssertInt(8, result, "fib(6)");
  result := PrFibIterative(10); Test.AssertInt(55, result, "fibIter(10)")
END PrTestRecursionFibonacci;

PROCEDURE PrRecursiveDepth(depth, limit: INTEGER);
VAR local: INTEGER;
BEGIN
  local := depth;
  IF depth >= limit THEN PrdepthReached := depth
  ELSE PrRecursiveDepth(depth + 1, limit) END
END PrRecursiveDepth;

PROCEDURE PrBinaryTreeDepth(n: INTEGER): INTEGER;
VAR left, right: INTEGER;
BEGIN
  IF n <= 0 THEN RETURN 0
  ELSE
    left := PrBinaryTreeDepth(n - 1);
    right := PrBinaryTreeDepth(n - 1);
    IF left > right THEN RETURN left + 1 ELSE RETURN right + 1 END
  END
END PrBinaryTreeDepth;

PROCEDURE PrTestDeepRecursion*;
VAR result: INTEGER;
BEGIN
  PrdepthReached := 0;
  PrRecursiveDepth(1, 100);
  Test.AssertInt(100, PrdepthReached, "depth 100");
  result := PrBinaryTreeDepth(4);
  Test.AssertInt(4, result, "tree depth 4")
END PrTestDeepRecursion;

PROCEDURE PrReturnEarly(flag: BOOLEAN; value: INTEGER): INTEGER;
BEGIN
  IF flag THEN RETURN value * 2 END;
  RETURN value * 3
END PrReturnEarly;

PROCEDURE PrMultipleReturns(x: INTEGER): INTEGER;
BEGIN
  IF x < 0 THEN RETURN -1
  ELSIF x = 0 THEN RETURN 0
  ELSIF x < 10 THEN RETURN 1
  ELSE RETURN 2 END
END PrMultipleReturns;

PROCEDURE PrInnerNR(c: INTEGER): INTEGER;
BEGIN
  IF c > 10 THEN RETURN c - 10 ELSE RETURN c * 2 END
END PrInnerNR;

PROCEDURE PrNestedReturns(a, b: INTEGER): INTEGER;
BEGIN RETURN PrInnerNR(a) + PrInnerNR(b) END PrNestedReturns;

PROCEDURE PrTestProcedureFunctionReturn*;
VAR result: INTEGER;
BEGIN
  result := PrReturnEarly(TRUE, 5);  Test.AssertInt(10, result, "early T");
  result := PrReturnEarly(FALSE, 5); Test.AssertInt(15, result, "early F");
  result := PrMultipleReturns(-5);   Test.AssertInt(-1, result, "mret -5");
  result := PrMultipleReturns(0);    Test.AssertInt(0,  result, "mret 0");
  result := PrMultipleReturns(5);    Test.AssertInt(1,  result, "mret 5");
  result := PrMultipleReturns(20);   Test.AssertInt(2,  result, "mret 20");
  result := PrNestedReturns(5, 15);  Test.AssertInt(15, result, "nested ret")
END PrTestProcedureFunctionReturn;

PROCEDURE PrModifyLocals(a, b: INTEGER): INTEGER;
VAR x, y: INTEGER;
BEGIN
  x := a * 2; y := b * 3;
  Prglobal1 := x; Prglobal2 := y;
  RETURN x + y
END PrModifyLocals;

PROCEDURE PrTestStackFrameIsolation*;
VAR res: INTEGER;
BEGIN
  Prglobal1 := 0; Prglobal2 := 0;
  res := PrModifyLocals(10, 20);
  Test.AssertInt(80, res, "ModifyLocals ret");
  Test.AssertInt(20, Prglobal1, "ModifyLocals g1");
  Test.AssertInt(60, Prglobal2, "ModifyLocals g2")
END PrTestStackFrameIsolation;

PROCEDURE PrSquare(x: INTEGER): INTEGER; BEGIN RETURN x * x END PrSquare;
PROCEDURE PrDouble(x: INTEGER): INTEGER; BEGIN RETURN x * 2 END PrDouble;
PROCEDURE PrAdd(x, y: INTEGER): INTEGER; BEGIN RETURN x + y END PrAdd;

PROCEDURE PrCompose(x, y, z: INTEGER): INTEGER;
BEGIN RETURN PrAdd(PrSquare(PrDouble(x)), PrAdd(PrSquare(y), PrDouble(z))) END PrCompose;

PROCEDURE PrChainCall(a, b, c: INTEGER): INTEGER;
BEGIN RETURN PrDouble(PrAdd(PrSquare(a), PrSquare(b))) + c END PrChainCall;

PROCEDURE PrTestFunctionComposition*;
VAR result: INTEGER;
BEGIN
  result := PrCompose(2, 3, 4);
  Test.AssertInt(33, result, "Compose");
  result := PrChainCall(2, 3, 5);
  Test.AssertInt(31, result, "ChainCall")
END PrTestFunctionComposition;

PROCEDURE PaArraySum(a: ARRAY OF INTEGER): INTEGER;
VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO s := s + a[i] END;
  RETURN s
END PaArraySum;

PROCEDURE PaArrayFill(VAR a: ARRAY OF INTEGER; val: INTEGER);
VAR i: INTEGER;
BEGIN FOR i := 0 TO LEN(a) - 1 DO a[i] := val END END PaArrayFill;

PROCEDURE PaArrayLen(a: ARRAY OF INTEGER): INTEGER;
BEGIN RETURN LEN(a) END PaArrayLen;

PROCEDURE PaStringLen(s: ARRAY OF CHAR): INTEGER;
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(s)) & (s[i] # CHR(0)) DO INC(i) END;
  RETURN i
END PaStringLen;

PROCEDURE PaStringCopyUpper(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR i, c: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(src)) & (i < LEN(dst)) & (src[i] # CHR(0)) DO
    c := ORD(src[i]);
    IF (c >= ORD("a")) & (c <= ORD("z")) THEN c := c - 32 END;
    dst[i] := CHR(c);
    INC(i)
  END;
  IF i < LEN(dst) THEN dst[i] := CHR(0) END
END PaStringCopyUpper;

PROCEDURE PaTOpenArrayLen*;
BEGIN
  Test.AssertInt(5,  PaArrayLen(PagArr5),  "len PagArr5");
  Test.AssertInt(20, PaArrayLen(PagArr20), "len PagArr20")
END PaTOpenArrayLen;

PROCEDURE PaTOpenArraySum*;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 4  DO PagArr5[i]  := i + 1 END;
  FOR i := 0 TO 19 DO PagArr20[i] := i + 1 END;
  Test.AssertInt(15,  PaArraySum(PagArr5),  "sum PagArr5");
  Test.AssertInt(210, PaArraySum(PagArr20), "sum PagArr20")
END PaTOpenArraySum;

PROCEDURE PaTVarOpenArrayFill*;
VAR i: INTEGER;
BEGIN
  PaArrayFill(PagArr5, 7);
  FOR i := 0 TO 4 DO Test.AssertInt(7, PagArr5[i], "fill5[i]") END;
  PaArrayFill(PagArr20, 3);
  FOR i := 0 TO 19 DO Test.AssertInt(3, PagArr20[i], "fill20[i]") END
END PaTVarOpenArrayFill;

PROCEDURE PaTCharOpenArray*;
VAR upper: ARRAY 32 OF CHAR;
BEGIN
  PagStr := "hello";
  Test.AssertInt(5, PaStringLen(PagStr), "len 'hello'");
  PaStringCopyUpper(PagStr, upper);
  Test.AssertTrue(upper[0] = "H", "upper[0]='H'");
  Test.AssertTrue(upper[1] = "E", "upper[1]='E'");
  Test.AssertTrue(upper[4] = "O", "upper[4]='O'");
  Test.AssertInt(0, ORD(upper[5]), "upper[5]=NUL");
  PagStr := "";
  Test.AssertInt(0, PaStringLen(PagStr), "len empty")
END PaTCharOpenArray;

PROCEDURE PaSumRec(VAR r: PaRec): INTEGER;
BEGIN RETURN r.x + r.y END PaSumRec;

PROCEDURE PaScaleAndSum(VAR r: PaRec; factor: INTEGER): INTEGER;
BEGIN
  r.x := r.x * factor; r.y := r.y * factor;
  RETURN r.x + r.y
END PaScaleAndSum;

PROCEDURE PaTRecordReadVarParam*;
VAR r: PaRec; s: INTEGER;
BEGIN
  r.x := 10; r.y := 20;
  s := PaSumRec(r);
  Test.AssertInt(30, s, "sum");
  Test.AssertInt(10, r.x, "r.x unchanged by read");
  Test.AssertInt(20, r.y, "r.y unchanged by read");
  s := PaScaleAndSum(r, 3);
  Test.AssertInt(90, s, "scale sum")
END PaTRecordReadVarParam;

PROCEDURE PaScaleRec(VAR r: PaRec; factor: INTEGER);
BEGIN r.x := r.x * factor; r.y := r.y * factor END PaScaleRec;

PROCEDURE PaSwapFields(VAR r: PaRec);
VAR t: INTEGER;
BEGIN t := r.x; r.x := r.y; r.y := t END PaSwapFields;

PROCEDURE PaTRecordVarParam*;
VAR r: PaRec;
BEGIN
  r.x := 3; r.y := 4;
  PaScaleRec(r, 10);
  Test.AssertInt(30, r.x, "r.x*10");
  Test.AssertInt(40, r.y, "r.y*10");
  PaSwapFields(r);
  Test.AssertInt(40, r.x, "swap r.x");
  Test.AssertInt(30, r.y, "swap r.y")
END PaTRecordVarParam;

PROCEDURE PaMinMax(a, b: INTEGER; VAR lo, hi: INTEGER);
BEGIN
  IF a < b THEN lo := a; hi := b ELSE lo := b; hi := a END
END PaMinMax;

PROCEDURE PaDivmod(a, b: INTEGER; VAR q, r: INTEGER);
BEGIN q := a DIV b; r := a MOD b END PaDivmod;

PROCEDURE PaTMultiVarParam*;
VAR lo, hi, q, r: INTEGER;
BEGIN
  PaMinMax(7, 3, lo, hi);
  Test.AssertInt(3, lo, "lo");
  Test.AssertInt(7, hi, "hi");
  PaMinMax(-5, 2, lo, hi);
  Test.AssertInt(-5, lo, "lo neg");
  Test.AssertInt(2,  hi, "hi neg");
  PaDivmod(17, 5, q, r);
  Test.AssertInt(3, q, "q=17 div 5");
  Test.AssertInt(2, r, "r=17 mod 5")
END PaTMultiVarParam;

PROCEDURE PaDoubleAll(VAR a: ARRAY OF INTEGER);
VAR i: INTEGER;
BEGIN FOR i := 0 TO LEN(a) - 1 DO a[i] := a[i] * 2 END END PaDoubleAll;

PROCEDURE PaTArrayModifyViaVar*;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO PagArr5[i] := i + 1 END;
  PaDoubleAll(PagArr5);
  Test.AssertInt(2,  PagArr5[0], "arr[0]*2");
  Test.AssertInt(6,  PagArr5[2], "arr[2]*2");
  Test.AssertInt(10, PagArr5[4], "arr[4]*2")
END PaTArrayModifyViaVar;

PROCEDURE PaScaleField(VAR r: PaRec3; factor: INTEGER);
BEGIN r.b := r.b * factor END PaScaleField;

PROCEDURE PaTRecordFieldModify*;
VAR r: PaRec3;
BEGIN
  r.a := 10; r.b := 20; r.c := 30;
  PaScaleField(r, 2);
  Test.AssertInt(10, r.a, "r.a unchanged");
  Test.AssertInt(40, r.b, "r.b doubled");
  Test.AssertInt(30, r.c, "r.c unchanged")
END PaTRecordFieldModify;

PROCEDURE PaTOpenArraySizes*;
BEGIN
  PaArrayFill(PagArr5, 4);
  Test.AssertInt(20, PaArraySum(PagArr5), "5*4");
  PaArrayFill(PagArr20, 2);
  Test.AssertInt(40, PaArraySum(PagArr20), "20*2");
  PaArrayFill(PagArr5, 0);
  Test.AssertInt(0, PaArraySum(PagArr5), "sum after zero");
  Test.AssertInt(40, PaArraySum(PagArr20), "PagArr20 unchanged")
END PaTOpenArraySizes;

PROCEDURE PaBothDouble(VAR a, b: INTEGER);
BEGIN a := a * 2; b := b * 2 END PaBothDouble;

PROCEDURE PaTIndependentVarParams*;
VAR a, b: INTEGER;
BEGIN
  a := 3; b := 7;
  PaBothDouble(a, b);
  Test.AssertInt(6,  a, "a*2");
  Test.AssertInt(14, b, "b*2")
END PaTIndependentVarParams;

PROCEDURE PaTryModify(p: INTEGER);
BEGIN p := 9999 END PaTryModify;

PROCEDURE PaTValueParamIsolation*;
VAR x: INTEGER;
BEGIN
  x := 42;
  PaTryModify(x);
  Test.AssertInt(42, x, "x unchanged after PaTryModify")
END PaTValueParamIsolation;

PROCEDURE PaFillChar(VAR s: ARRAY OF CHAR; c: CHAR; n: INTEGER);
VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < n) & (i < LEN(s)) DO s[i] := c; INC(i) END;
  IF i < LEN(s) THEN s[i] := CHR(0) END
END PaFillChar;

PROCEDURE PaTCharArrayVarParam*;
BEGIN
  PagStr := "xxxxxxxxxx";
  PaFillChar(PagStr, "A", 3);
  Test.AssertTrue(PagStr[0] = "A",  "PagStr[0]='A'");
  Test.AssertTrue(PagStr[1] = "A",  "PagStr[1]='A'");
  Test.AssertTrue(PagStr[2] = "A",  "PagStr[2]='A'");
  Test.AssertInt(0, ORD(PagStr[3]), "PagStr[3]=NUL")
END PaTCharArrayVarParam;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(PrTestProcedureNoParams, "Pr/noParams");
  Test.AddTest(PrTestProcedureValueParams, "Pr/valueParams");
  Test.AddTest(PrTestVarParameters, "Pr/varParams");
  Test.AddTest(PrTestMixedParameters, "Pr/mixedParams");
  Test.AddTest(PrTestLocalVariables, "Pr/locals");
  Test.AddTest(PrTestRecursionFactorial, "Pr/recFact");
  Test.AddTest(PrTestRecursionFibonacci, "Pr/recFib");
  Test.AddTest(PrTestDeepRecursion, "Pr/deepRec");
  Test.AddTest(PrTestProcedureFunctionReturn, "Pr/funcRet");
  Test.AddTest(PrTestStackFrameIsolation, "Pr/stackIso");
  Test.AddTest(PrTestFunctionComposition, "Pr/compose");
  Test.AddTest(PaTOpenArrayLen, "Pa/openArrayLen");
  Test.AddTest(PaTOpenArraySum, "Pa/openArraySum");
  Test.AddTest(PaTVarOpenArrayFill, "Pa/varOpenArrayFill");
  Test.AddTest(PaTCharOpenArray, "Pa/charOpenArray");
  Test.AddTest(PaTRecordReadVarParam, "Pa/recordReadVar");
  Test.AddTest(PaTRecordVarParam, "Pa/recordVar");
  Test.AddTest(PaTMultiVarParam, "Pa/multiVar");
  Test.AddTest(PaTArrayModifyViaVar, "Pa/arrayModifyVar");
  Test.AddTest(PaTRecordFieldModify, "Pa/recordFieldModify");
  Test.AddTest(PaTOpenArraySizes, "Pa/openArraySizes");
  Test.AddTest(PaTIndependentVarParams, "Pa/independentVar");
  Test.AddTest(PaTValueParamIsolation, "Pa/valueParamIsolation");
  Test.AddTest(PaTCharArrayVarParam, "Pa/charArrayVar");
  Test.RunTests
END RunAllTests;

END PROC1.
