MODULE CTRL;
IMPORT Test;

CONST
  CeA = 10;
  CeB = 3;
  CeSum    = CeA + CeB;
  CeDiff   = CeA - CeB;
  CeProd   = CeA * CeB;
  CeQuot   = CeA DIV CeB;
  CeRem    = CeA MOD CeB;
  CeNeg    = -CeA;
  CeNegDiv = -7 DIV 2;
  CeNegMod = -7 MOD 2;
  CeFlrDiv = (-7) DIV 2;
  CeFlrMod = (-7) MOD 2;
  CeParen  = (CeA + CeB) * 2;
  CeChain  = CeA + CeB * 2;
  CeBig    = 1000 * 200;
  CeZero   = CeA - CeA;
  CeMaxDiv = 32767 DIV 1;

PROCEDURE CfTIfSimple*;
VAR a, b, c: INTEGER;
BEGIN
  a := 10; b := 20; c := 0;
  IF a < b THEN c := 100 END;
  Test.AssertInt(100, c, "IF then");

  c := 0;
  IF a > b THEN c := 100 ELSE c := 200 END;
  Test.AssertInt(200, c, "IF else");

  c := 0;
  IF a = b THEN c := 100
  ELSIF a < b THEN c := 200
  ELSE c := 300 END;
  Test.AssertInt(200, c, "IF elsif first");

  c := 0;
  IF a > b THEN c := 100
  ELSIF a = b THEN c := 200
  ELSIF a < b THEN c := 300 END;
  Test.AssertInt(300, c, "IF elsif last")
END CfTIfSimple;

PROCEDURE CfTIfComplex*;
VAR a, b, c, d, result: INTEGER;
BEGIN
  a := 5; b := 10; c := 15; d := 20;
  result := 0;
  IF (a < b) & (c < d) THEN result := 1 END;
  Test.AssertInt(1, result, "AND condition");

  result := 0;
  IF (a > b) OR (c < d) THEN result := 2 END;
  Test.AssertInt(2, result, "OR condition");

  result := 0;
  IF (a > b) OR (c > d) THEN result := 3 ELSE result := 4 END;
  Test.AssertInt(4, result, "OR false");

  result := 0;
  IF ~(a < b) THEN result := 5 ELSE result := 6 END;
  Test.AssertInt(6, result, "NOT");

  result := 0;
  IF (a < b) & ~(c > d) THEN result := 7 END;
  Test.AssertInt(7, result, "AND with NOT")
END CfTIfComplex;

PROCEDURE CfTIfNested*;
VAR a, b, c, result: INTEGER;
BEGIN
  a := 10; b := 20; c := 30;
  result := 0;
  IF a < b THEN
    IF b < c THEN result := 100 ELSE result := 200 END
  ELSE result := 300 END;
  Test.AssertInt(100, result, "nested IF 1");

  result := 0;
  IF a > b THEN result := 400
  ELSE
    IF b > c THEN result := 500
    ELSE IF a < c THEN result := 600 END END
  END;
  Test.AssertInt(600, result, "nested IF 2");

  result := 0;
  IF a < b THEN
    IF a < c THEN
      IF b < c THEN result := 1 ELSE result := 2 END
    ELSE result := 3 END
  ELSE result := 4 END;
  Test.AssertInt(1, result, "nested IF 3")
END CfTIfNested;

PROCEDURE CfTElsifChain*;
VAR x, result: INTEGER;
BEGIN
  result := 0; x := 5;
  IF x < 0 THEN result := -1
  ELSIF x = 0 THEN result := 0
  ELSIF x < 10 THEN result := 1
  ELSIF x < 20 THEN result := 2
  ELSE result := 3 END;
  Test.AssertInt(1, result, "elsif x=5");

  x := 15;
  IF x < 0 THEN result := -1
  ELSIF x = 0 THEN result := 0
  ELSIF x < 10 THEN result := 1
  ELSIF x < 20 THEN result := 2
  ELSE result := 3 END;
  Test.AssertInt(2, result, "elsif x=15");

  x := 25;
  IF x < 0 THEN result := -1
  ELSIF x = 0 THEN result := 0
  ELSIF x < 10 THEN result := 1
  ELSIF x < 20 THEN result := 2
  ELSE result := 3 END;
  Test.AssertInt(3, result, "elsif x=25")
END CfTElsifChain;

PROCEDURE CfTWhile*;
VAR i, sum, product: INTEGER;
BEGIN
  i := 1; sum := 0;
  WHILE i <= 10 DO sum := sum + i; i := i + 1 END;
  Test.AssertInt(55, sum, "WHILE ascending");

  i := 10; sum := 0;
  WHILE i > 0 DO sum := sum + i; i := i - 1 END;
  Test.AssertInt(55, sum, "WHILE descending");

  i := 1; product := 1;
  WHILE i < 5 DO product := product * i; i := i + 1 END;
  Test.AssertInt(24, product, "WHILE product")
END CfTWhile;

PROCEDURE CfTRepeat*;
VAR i, sum, count: INTEGER;
BEGIN
  i := 1; sum := 0;
  REPEAT sum := sum + i; i := i + 1 UNTIL i > 10;
  Test.AssertInt(55, sum, "REPEAT ascending");

  i := 10; sum := 0;
  REPEAT sum := sum + i; i := i - 1 UNTIL i = 0;
  Test.AssertInt(55, sum, "REPEAT descending");

  count := 0;
  REPEAT INC(count) UNTIL count >= 5;
  Test.AssertInt(5, count, "REPEAT count")
END CfTRepeat;

PROCEDURE CfTForAsc*;
VAR i, sum, product: INTEGER;
BEGIN
  sum := 0; FOR i := 1 TO 10 DO sum := sum + i END;
  Test.AssertInt(55, sum, "FOR 1..10");

  product := 1; FOR i := 1 TO 5 DO product := product * i END;
  Test.AssertInt(120, product, "FOR product");

  sum := 0; FOR i := 0 TO 100 BY 10 DO sum := sum + i END;
  Test.AssertInt(550, sum, "FOR BY 10")
END CfTForAsc;

PROCEDURE CfTForDesc*;
VAR i, sum, product: INTEGER;
BEGIN
  sum := 0; FOR i := 10 TO 1 BY -1 DO sum := sum + i END;
  Test.AssertInt(55, sum, "FOR 10..1 BY -1");

  product := 1; FOR i := 5 TO 1 BY -1 DO product := product * i END;
  Test.AssertInt(120, product, "FOR desc product");

  sum := 0; FOR i := 100 TO 0 BY -10 DO sum := sum + i END;
  Test.AssertInt(550, sum, "FOR desc BY -10")
END CfTForDesc;

PROCEDURE CfTForNested*;
VAR i, j, sum: INTEGER;
BEGIN
  sum := 0;
  FOR i := 1 TO 5 DO
    FOR j := 1 TO 5 DO sum := sum + i * j END
  END;
  Test.AssertInt(225, sum, "nested FOR 5x5");

  sum := 0;
  FOR i := 1 TO 3 DO
    FOR j := 1 TO i DO sum := sum + j END
  END;
  Test.AssertInt(10, sum, "triangular nested FOR")
END CfTForNested;

PROCEDURE CfTForScope*;
VAR i, j, counter: INTEGER;
    loopVar: INTEGER;
BEGIN
  counter := 0;
  FOR i := 1 TO 10 DO
    counter := counter + i;
    loopVar := i * 2
  END;
  Test.AssertInt(55, counter, "FOR accumulator");

  i := 100;
  Test.AssertInt(100, i, "i scope after FOR");

  counter := 0;
  FOR i := 1 TO 5 DO
    FOR j := 1 TO 5 DO counter := counter + 1 END
  END;
  Test.AssertInt(25, counter, "nested FOR count")
END CfTForScope;

PROCEDURE CfTLoopComplex*;
VAR i, sum, count: INTEGER;
    found: BOOLEAN;
BEGIN
  i := 1; sum := 0;
  WHILE (i <= 20) & (sum < 50) DO sum := sum + i; i := i + 1 END;
  Test.AssertInt(55, sum, "WHILE & condition");
  Test.AssertInt(11, i,   "WHILE & i final");

  i := 1; found := FALSE;
  REPEAT
    IF i * i = 36 THEN found := TRUE END;
    i := i + 1
  UNTIL found OR (i > 10);
  Test.AssertTrue(found, "REPEAT OR found");
  Test.AssertInt(7, i, "REPEAT OR i final");

  count := 0;
  FOR i := 1 TO 20 DO
    IF (i MOD 2 = 0) & (i MOD 3 = 0) THEN count := count + 1 END
  END;
  Test.AssertInt(3, count, "FOR with filter")
END CfTLoopComplex;

PROCEDURE CfTCaseSimple*;
VAR value, result: INTEGER;
BEGIN
  value := 2;
  CASE value OF
    1: result := 10
  | 2: result := 20
  | 3: result := 30
  ELSE result := 99 END;
  Test.AssertInt(20, result, "CASE match");

  value := 5;
  CASE value OF
    1: result := 10
  | 2: result := 20
  | 3: result := 30
  ELSE result := 99 END;
  Test.AssertInt(99, result, "CASE ELSE");

  value := 1;
  CASE value OF
    1: result := 100
  | 2, 3, 4: result := 200
  | 5 .. 9: result := 300
  ELSE result := 400 END;
  Test.AssertInt(100, result, "CASE first")
END CfTCaseSimple;

PROCEDURE CfTCaseRanges*;
VAR value, result: INTEGER;
BEGIN
  value := 3;
  CASE value OF
    1 .. 5: result := 10
  | 6 .. 10: result := 20
  | 11 .. 15: result := 30
  ELSE result := 99 END;
  Test.AssertInt(10, result, "range 3");

  value := 8;
  CASE value OF
    1 .. 5: result := 10
  | 6 .. 10: result := 20
  | 11 .. 15: result := 30
  ELSE result := 99 END;
  Test.AssertInt(20, result, "range 8");

  value := 12;
  CASE value OF
    1 .. 5: result := 10
  | 6 .. 10: result := 20
  | 11 .. 15: result := 30
  ELSE result := 99 END;
  Test.AssertInt(30, result, "range 12");

  value := 20;
  CASE value OF
    1 .. 5: result := 10
  | 6 .. 10: result := 20
  | 11 .. 15: result := 30
  ELSE result := 99 END;
  Test.AssertInt(99, result, "range else")
END CfTCaseRanges;

PROCEDURE CfTCaseMixed*;
VAR value, result: INTEGER;
BEGIN
  value := 2;
  CASE value OF
    1, 3, 5, 7, 9:    result := 10
  | 2, 4, 6, 8, 10:   result := 20
  | 11 .. 20:         result := 30
  ELSE result := 99 END;
  Test.AssertInt(20, result, "mixed even");

  value := 5;
  CASE value OF
    1, 3, 5, 7, 9:    result := 10
  | 2, 4, 6, 8, 10:   result := 20
  | 11 .. 20:         result := 30
  ELSE result := 99 END;
  Test.AssertInt(10, result, "mixed odd");

  value := 15;
  CASE value OF
    1, 3, 5, 7, 9:    result := 10
  | 2, 4, 6, 8, 10:   result := 20
  | 11 .. 20:         result := 30
  ELSE result := 99 END;
  Test.AssertInt(30, result, "mixed range")
END CfTCaseMixed;

PROCEDURE CfTCaseNested*;
VAR x, y, result: INTEGER;
BEGIN
  x := 2; y := 3;
  CASE x OF
    1: CASE y OF
         1: result := 11
       | 2: result := 12
       ELSE result := 19 END
  | 2: CASE y OF
         1: result := 21
       | 2: result := 22
       | 3: result := 23
       ELSE result := 29 END
  | 3: result := 30
  ELSE result := 99 END;
  Test.AssertInt(23, result, "nested CASE 2,3");

  x := 1; y := 2;
  CASE x OF
    1: CASE y OF
         1: result := 11
       | 2: result := 12
       ELSE result := 19 END
  | 2: result := 20
  ELSE result := 99 END;
  Test.AssertInt(12, result, "nested CASE 1,2")
END CfTCaseNested;

(* CHAR-typed CASE selector with single-character string-literal labels.
   Single-char strings are type-compatible with CHAR per Oberon-07. *)
PROCEDURE CfTCaseChar*;
  VAR c: CHAR; result: INTEGER;
BEGIN
  c := "b"; result := 0;
  CASE c OF
    "a": result := 1
  | "b": result := 2
  | "c": result := 3
  ELSE result := 99 END;
  Test.AssertInt(2, result, "CASE CHAR match 'b'");

  c := "z";
  CASE c OF
    "a": result := 1
  | "b": result := 2
  | "c": result := 3
  ELSE result := 99 END;
  Test.AssertInt(99, result, "CASE CHAR ELSE");

  c := "g";
  CASE c OF
    "0" .. "9": result := 1
  | "a" .. "f", "A" .. "F": result := 2
  ELSE result := 3 END;
  Test.AssertInt(3, result, "CASE CHAR range else");

  c := "C";
  CASE c OF
    "0" .. "9": result := 1
  | "a" .. "f", "A" .. "F": result := 2
  ELSE result := 3 END;
  Test.AssertInt(2, result, "CASE CHAR range hex-upper")
END CfTCaseChar;

PROCEDURE CfFindFirst(start, limit: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  FOR i := start TO limit DO
    IF i * i > 100 THEN RETURN i END
  END;
  RETURN -1
END CfFindFirst;

PROCEDURE CfTBreakReturn*;
VAR i, sum: INTEGER;
BEGIN
  i := 1; sum := 0;
  WHILE i <= 20 DO
    sum := sum + i; i := i + 1;
    IF sum >= 55 THEN i := 21 END
  END;
  Test.AssertInt(55, sum, "WHILE early-exit via flag");

  Test.AssertInt(11, CfFindFirst(1, 20),  "CfFindFirst start=1");
  Test.AssertInt(15, CfFindFirst(15, 20), "CfFindFirst start=15")
END CfTBreakReturn;

PROCEDURE RpLargeBody(n: INTEGER): INTEGER;
VAR a, b, c, d, e, f, g, h: INTEGER;
    i, result: INTEGER;
BEGIN
  result := 0; i := 0;
  REPEAT
    a := i * 2; b := a + 1; c := b - a; d := c * 3;
    e := d + i; f := e - 1; g := f + 2; h := g * 1;
    a := h + i; b := a - 1; c := b + 2; d := c * 1;
    e := d + 1; f := e - 1; g := f + 1; h := g - 1;
    INC(result, h); INC(i)
  UNTIL i >= n;
  RETURN result
END RpLargeBody;

PROCEDURE RpTLargeRepeatBody*;
BEGIN
  Test.AssertInt(5,   RpLargeBody(1),  "RpLargeBody(1)");
  Test.AssertInt(21,  RpLargeBody(3),  "RpLargeBody(3)");
  Test.AssertInt(140, RpLargeBody(10), "RpLargeBody(10)")
END RpTLargeRepeatBody;

PROCEDURE BnBoolToInt(b: BOOLEAN): INTEGER;
BEGIN IF b THEN RETURN 1 ELSE RETURN 0 END
END BnBoolToInt;

PROCEDURE BnTLiteralNot*;
VAR t, f: BOOLEAN;
BEGIN
  t := TRUE; f := FALSE;
  Test.AssertInt(0, BnBoolToInt(~t), "~TRUE");
  Test.AssertInt(1, BnBoolToInt(~f), "~FALSE");
  Test.AssertInt(1, BnBoolToInt(~~t), "~~TRUE");
  Test.AssertInt(0, BnBoolToInt(~~f), "~~FALSE")
END BnTLiteralNot;

PROCEDURE BnTIfNot*;
VAR t, f: BOOLEAN; x: INTEGER;
BEGIN
  t := TRUE; f := FALSE;
  x := 0; IF ~f THEN x := 1 END;
  Test.AssertInt(1, x, "IF ~FALSE");
  x := 0; IF ~t THEN x := 1 END;
  Test.AssertInt(0, x, "IF ~TRUE")
END BnTIfNot;

PROCEDURE BnTCombinedBool*;
VAR a, b, f: BOOLEAN;
BEGIN
  a := TRUE; b := FALSE; f := FALSE;
  Test.AssertInt(1, BnBoolToInt(~b & a),  "~FALSE & TRUE");
  Test.AssertInt(0, BnBoolToInt(~a & a),  "~TRUE & TRUE");
  Test.AssertInt(1, BnBoolToInt(~b OR f), "~FALSE OR FALSE");
  Test.AssertInt(0, BnBoolToInt(~a OR f), "~TRUE OR FALSE")
END BnTCombinedBool;

PROCEDURE BnTNotInLoops*;
VAR a: BOOLEAN; x: INTEGER;
BEGIN
            
  x := 0; a := FALSE;
  WHILE ~a DO INC(x); a := TRUE END;
  Test.AssertInt(1, x, "WHILE ~a");
          
  x := 0; a := FALSE;
  REPEAT INC(x); a := TRUE UNTIL ~a = FALSE;
  Test.AssertInt(1, x, "REPEAT ~a")
END BnTNotInLoops;

PROCEDURE CeTBasicArith*;
BEGIN
  Test.AssertInt(13, CeSum,  "CeA+CeB=13");
  Test.AssertInt(7,  CeDiff, "CeA-CeB=7");
  Test.AssertInt(30, CeProd, "CeA*CeB=30");
  Test.AssertInt(3,  CeQuot, "CeA DIV CeB=3");
  Test.AssertInt(1,  CeRem,  "CeA MOD CeB=1");
  Test.AssertInt(-10, CeNeg, "-CeA=-10")
END CeTBasicArith;

PROCEDURE CeTDivMod*;
BEGIN
  Test.AssertInt(-3, CeNegDiv, "-7 DIV 2=-3");
  Test.AssertInt(-1, CeNegMod, "-7 MOD 2=-1");
  Test.AssertInt(-4, CeFlrDiv, "(-7) DIV 2=-4");
  Test.AssertInt( 1, CeFlrMod, "(-7) MOD 2=1")
END CeTDivMod;

PROCEDURE CeTPrecedence*;
BEGIN
  Test.AssertInt(26,    CeParen,  "(CeA+CeB)*2=26");
  Test.AssertInt(16,    CeChain,  "CeA+CeB*2=16");
  Test.AssertInt(0,     CeZero,   "CeA-CeA=0");
  Test.AssertInt(32767, CeMaxDiv, "32767 DIV 1");
  Test.AssertLong(200000, CeBig,  "1000*200=200000 (LONGINT)")
END CeTPrecedence;

PROCEDURE FwEven(n: INTEGER): BOOLEAN; FORWARD;

PROCEDURE FwOdd(n: INTEGER): BOOLEAN; FORWARD;

PROCEDURE FwEven;
BEGIN
  IF n = 0 THEN RETURN TRUE END;
  RETURN FwOdd(n - 1)
END FwEven;

PROCEDURE FwOdd;
BEGIN
  IF n = 0 THEN RETURN FALSE END;
  RETURN FwEven(n - 1)
END FwOdd;

PROCEDURE FwCompute(a, b: INTEGER): INTEGER; FAR; FORWARD;

PROCEDURE FwCompute;
BEGIN RETURN a * b + a END FwCompute;

PROCEDURE FwHelper(x: INTEGER): INTEGER; FORWARD;

PROCEDURE FwHelper;
BEGIN RETURN x + 1 END FwHelper;

PROCEDURE FwTMutualRecursion*;
BEGIN
  Test.AssertTrue(FwEven(4),  "FwEven(4)");
  Test.AssertFalse(FwEven(3), "FwEven(3) false");
  Test.AssertTrue(FwOdd(5),   "FwOdd(5)");
  Test.AssertFalse(FwOdd(6),  "FwOdd(6) false");
  Test.AssertTrue(FwEven(0),  "FwEven(0)");
  Test.AssertFalse(FwOdd(0),  "FwOdd(0) false")
END FwTMutualRecursion;

PROCEDURE FwTForwardFar*;
BEGIN
  Test.AssertInt(15, FwCompute(3, 4), "FwCompute(3,4)=15")
END FwTForwardFar;

PROCEDURE FwTForwardCallBeforeDef*;
BEGIN
  Test.AssertInt(11, FwHelper(10), "FwHelper(10)=11")
END FwTForwardCallBeforeDef;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(CfTIfSimple, "Cf/ifSimple");
  Test.AddTest(CfTIfComplex, "Cf/ifComplex");
  Test.AddTest(CfTIfNested, "Cf/ifNested");
  Test.AddTest(CfTElsifChain, "Cf/elsifChain");
  Test.AddTest(CfTWhile, "Cf/while");
  Test.AddTest(CfTRepeat, "Cf/repeat");
  Test.AddTest(CfTForAsc, "Cf/forAsc");
  Test.AddTest(CfTForDesc, "Cf/forDesc");
  Test.AddTest(CfTForNested, "Cf/forNested");
  Test.AddTest(CfTForScope, "Cf/forScope");
  Test.AddTest(CfTLoopComplex, "Cf/loopComplex");
  Test.AddTest(CfTCaseSimple, "Cf/caseSimple");
  Test.AddTest(CfTCaseRanges, "Cf/caseRanges");
  Test.AddTest(CfTCaseMixed, "Cf/caseMixed");
  Test.AddTest(CfTCaseNested, "Cf/caseNested");
  Test.AddTest(CfTCaseChar, "Cf/caseChar");
  Test.AddTest(CfTBreakReturn, "Cf/breakReturn");
  Test.AddTest(RpTLargeRepeatBody, "Rp/largeBody");
  Test.AddTest(BnTLiteralNot, "Bn/literal");
  Test.AddTest(BnTIfNot, "Bn/if");
  Test.AddTest(BnTCombinedBool, "Bn/combined");
  Test.AddTest(BnTNotInLoops, "Bn/loops");
  Test.AddTest(CeTBasicArith, "Ce/basicArith");
  Test.AddTest(CeTDivMod, "Ce/divMod");
  Test.AddTest(CeTPrecedence, "Ce/precedence");
  Test.AddTest(FwTMutualRecursion, "Fw/mutualRecursion");
  Test.AddTest(FwTForwardFar, "Fw/farForward");
  Test.AddTest(FwTForwardCallBeforeDef, "Fw/callBeforeDef");
  Test.RunTests
END RunAllTests;

END CTRL.
