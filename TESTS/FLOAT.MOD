MODULE FLOAT;
IMPORT Test, Math;

TYPE
  ReHeapReal  = POINTER TO RECORD value: REAL END;
  ReRealBlock = POINTER TO ARRAY 50 OF REAL;
  RePoint     = RECORD x, y: REAL END;
  ReRectangle = RECORD topLeft, bottomRight: RePoint END;
  ReMixed     = RECORD a: BYTE; b: REAL; c: BYTE; d: REAL END;
  ReRealArr10  = ARRAY 10 OF REAL;
  ReRealArr100 = ARRAY 100 OF REAL;
  ReMatRow    = ARRAY 5 OF REAL;
  ReMatrix    = ARRAY 5 OF ReMatRow;
  LrHeapLongReal  = POINTER TO RECORD value: LONGREAL END;
  LrLongRealBlock = POINTER TO ARRAY 50 OF LONGREAL;
  LrPoint     = RECORD x, y: LONGREAL END;
  LrRectangle = RECORD topLeft, bottomRight: LrPoint END;
  LrMixed     = RECORD a: BYTE; b: LONGREAL; c: BYTE; d: LONGREAL END;
  LrLRArr10  = ARRAY 10 OF LONGREAL;
  LrLRArr100 = ARRAY 100 OF LONGREAL;
  LrMatRow = ARRAY 5 OF LONGREAL;
  LrMatrix = ARRAY 5 OF LrMatRow;

PROCEDURE ReTRealArithmetic*;
VAR a, b, c: REAL;
BEGIN
  a := 100.0; b := 200.0; c := a + b; Test.AssertReal(300.0,  c, "100+200");
  a := 500.0; b := 300.0; c := a - b; Test.AssertReal(200.0,  c, "500-300");
  a := 50.0;  b := 20.0;  c := a * b; Test.AssertReal(1000.0, c, "50*20");
  a := 100.0; b := 3.0;   c := a / b; Test.AssertReal(33.333333, c, "100/3");
  a := 10.0; b := 20.0; c := 30.0;
  a := (a + b) * c - 50.0; Test.AssertReal(850.0, a, "(10+20)*30-50")
END ReTRealArithmetic;

PROCEDURE ReTRealBoundaries*;
VAR a, b: REAL;
BEGIN
  a := 3.40282347E+38; Test.AssertTrue(a > 1.0E38, "ReMaxReal > 1.0E38");
  a := 1.17549435E-38; Test.AssertTrue(a > 0.0,    "ReMinReal > 0");
  b := a;       Test.AssertTrue(b > 0.0,    "copy > 0")
END ReTRealBoundaries;

PROCEDURE ReTRealAssignment*;
VAR a, b: REAL; const1, const2: REAL;
BEGIN
  a := 12345.6789;
  b := -9876.54321;
  Test.AssertReal(12345.6789,   a, "12345.6789");
  Test.AssertReal(-9876.54321,  b, "-9876.54321");
  const1 := 777.777; const2 := 888.888;
  a := const1; b := const2;
  Test.AssertReal(777.777,  a, "const1");
  Test.AssertReal(888.888,  b, "const2");
  a := (const1 + const2) * 2.0;
  Test.AssertReal(3333.33,  a, "(c1+c2)*2")
END ReTRealAssignment;

PROCEDURE ReTRealConversion*;
VAR i: INTEGER; r: REAL;
BEGIN
  i := 42; r := REAL(i);     Test.AssertReal(42.0, r, "REAL(42)");
  r := 123.456; i := FLOOR(r);  Test.AssertInt(123,  i, "FLOOR(123.456)");
  r := -123.456; i := FLOOR(r); Test.AssertInt(-124, i, "FLOOR(-123.456)");
  i := FLOOR(3.999);            Test.AssertInt(3,    i, "FLOOR(3.999)")
END ReTRealConversion;

PROCEDURE ReTBooleanOperations*;
VAR a, b, c: BOOLEAN; x, y, z: REAL;
BEGIN
  a := TRUE; b := FALSE;
  c := a & b;  Test.AssertFalse(c, "T&F");
  c := a & a;  Test.AssertTrue(c,  "T&T");
  c := b & b;  Test.AssertFalse(c, "F&F");
  c := a OR b; Test.AssertTrue(c,  "T|F");
  c := b OR b; Test.AssertFalse(c, "F|F");
  c := a OR a; Test.AssertTrue(c,  "T|T");
  c := ~a;     Test.AssertFalse(c, "~T");
  c := ~b;     Test.AssertTrue(c,  "~F");
  x := 10.0; y := 20.0; z := 0.0;
  IF (x < y) & (x > 0.0) THEN z := 100.0 END;
  Test.AssertReal(100.0, z, "combined")
END ReTBooleanOperations;

PROCEDURE ReTBooleanComparisons*;
VAR a, b, c: REAL;
BEGIN
  a := 10.0; b := 20.0; c := 10.0;
  Test.AssertTrue(a = c,  "a=c");
  Test.AssertFalse(a = b, "a=b false");
  Test.AssertTrue(a # b,  "a#b");
  Test.AssertTrue(a < b,  "a<b");
  Test.AssertFalse(b < a, "b<a false");
  Test.AssertTrue(a <= c, "a<=c");
  Test.AssertTrue(b > a,  "b>a")
END ReTBooleanComparisons;

PROCEDURE ReTStaticArray*;
VAR arr: ReRealArr10; mat: ReMatrix;
    i, j: INTEGER;
    sum, step: REAL;
BEGIN
  step := 0.0;
  FOR i := 0 TO 9 DO arr[i] := step; step := step + 1.5 END;
  Test.AssertReal(0.0,  arr[0], "arr[0]");
  Test.AssertReal(7.5,  arr[5], "arr[5]");
  Test.AssertReal(13.5, arr[9], "arr[9]");
  sum := 0.0;
  FOR i := 0 TO 9 DO sum := sum + arr[i] END;
  Test.AssertReal(67.5, sum, "sum");

  FOR i := 0 TO 4 DO
    FOR j := 0 TO 4 DO mat[i][j] := REAL(i * 10 + j) + 0.5 END
  END;
  Test.AssertReal(0.5,  mat[0][0], "mat[0][0]");
  Test.AssertReal(23.5, mat[2][3], "mat[2][3]");
  Test.AssertReal(44.5, mat[4][4], "mat[4][4]");
  i := 3; j := 4;
  Test.AssertReal(34.5, mat[i][j], "mat[3][4] var idx")
END ReTStaticArray;

PROCEDURE ReTArrayIndexing*;
VAR arr: ReRealArr100; i: INTEGER; step: REAL;
BEGIN
  step := 0.0;
  FOR i := 0 TO 99 DO arr[i] := step; step := step + 0.5 END;
  Test.AssertReal(12.5, arr[25], "arr[25]");
  Test.AssertReal(25.0, arr[50], "arr[50]");
  Test.AssertReal(49.5, arr[99], "arr[99]")
END ReTArrayIndexing;

PROCEDURE ReTRecordAccess*;
VAR p: RePoint; r: ReRectangle;
BEGIN
  p.x := 100.5; p.y := 200.75;
  Test.AssertReal(100.5,  p.x, "p.x");
  Test.AssertReal(200.75, p.y, "p.y");
  r.topLeft.x := 10.25; r.topLeft.y := 20.5;
  r.bottomRight.x := 100.0; r.bottomRight.y := 200.0;
  Test.AssertReal(10.25,  r.topLeft.x,     "tl.x");
  Test.AssertReal(20.5,   r.topLeft.y,     "tl.y");
  Test.AssertReal(100.0,  r.bottomRight.x, "br.x");
  Test.AssertReal(200.0,  r.bottomRight.y, "br.y");
  r.topLeft.x := r.bottomRight.x - r.topLeft.x;
  Test.AssertReal(89.75,  r.topLeft.x, "tl.x updated")
END ReTRecordAccess;

PROCEDURE ReTRecordAlignment*;
VAR m: ReMixed;
BEGIN
  m.a := 1; m.b := 1000.5; m.c := 2; m.d := 2000.75;
  Test.AssertInt(1,        ORD(m.a), "m.a=1");
  Test.AssertReal(1000.5,   m.b,      "m.b");
  Test.AssertInt(2,        ORD(m.c), "m.c=2");
  Test.AssertReal(2000.75,  m.d,      "m.d")
END ReTRecordAlignment;

PROCEDURE ReTHeapAllocation*;
VAR p: ReHeapReal; q: ReRealBlock; i: INTEGER; sum, step: REAL;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "NEW p");
  p^.value := 42.5;
  Test.AssertReal(42.5, p^.value, "p^.value");
  DISPOSE(p);
  NEW(q);
  Test.AssertNotNil(q, "NEW q");
  step := 0.0;
  FOR i := 0 TO 49 DO q^[i] := step; step := step + 1.5 END;
  sum := 0.0;
  FOR i := 0 TO 49 DO sum := sum + q^[i] END;
  Test.AssertReal(1837.5, sum, "sum heap");
  DISPOSE(q)
END ReTHeapAllocation;

PROCEDURE LrTArith*;
VAR a, b, c: LONGREAL;
BEGIN
  a := 100.0; b := 200.0; c := a + b; Test.AssertReal(300.0,  REAL(c), "100+200");
  a := 500.0; b := 300.0; c := a - b; Test.AssertReal(200.0,  REAL(c), "500-300");
  a := 50.0;  b := 20.0;  c := a * b; Test.AssertReal(1000.0, REAL(c), "50*20");
  a := 100.0; b := 3.0;   c := a / b; Test.AssertReal(33.333332, REAL(c), "100/3");
  a := 10.0; b := 20.0; c := 30.0;
  a := (a + b) * c - 50.0; Test.AssertReal(850.0, REAL(a), "(10+20)*30-50")
END LrTArith;

PROCEDURE LrTBoundaries*;
VAR a, b: LONGREAL;
BEGIN
  a := 1.0E38;  Test.AssertTrue(a > 1.0E37, "1E38 > 1E37");
  a := 1.0E-37; Test.AssertTrue(a > 0.0,    "1E-37 > 0");
  b := a;       Test.AssertTrue(b > 0.0,    "copy > 0")
END LrTBoundaries;

PROCEDURE LrTAssignment*;
VAR a, b: LONGREAL; const1, const2: LONGREAL;
BEGIN
  a := 12345.6789; b := -9876.54321;
  Test.AssertReal(12345.6789,   REAL(a), "12345.6789");
  Test.AssertReal(-9876.54321,  REAL(b), "-9876.54321");
  const1 := 100.5; const2 := 200.25;
  a := const1; b := const2;
  Test.AssertReal(100.5,  REAL(a), "const1");
  Test.AssertReal(200.25, REAL(b), "const2");
  a := (const1 + const2) * 2.0;
  Test.AssertReal(601.5, REAL(a), "(c1+c2)*2")
END LrTAssignment;

PROCEDURE LrTConversion*;
VAR i: INTEGER; r: LONGREAL;
BEGIN
  i := 42; r := LONGREAL(i);  Test.AssertReal(42.0, REAL(r), "LONGREAL(42)");
  r := 123.789; i := FLOOR(r);  Test.AssertInt(123,  i, "FLOOR(123.789)");
  r := -123.789; i := FLOOR(r); Test.AssertInt(-124, i, "FLOOR(-123.789)");
  i := FLOOR(3.5);              Test.AssertInt(3,    i, "FLOOR(3.5)")
END LrTConversion;

PROCEDURE LrTBooleanOps*;
VAR a, b, c: BOOLEAN; x, y, z: LONGREAL;
BEGIN
  a := TRUE; b := FALSE;
  c := a & b;  Test.AssertFalse(c, "T&F");
  c := a & a;  Test.AssertTrue(c,  "T&T");
  c := b & b;  Test.AssertFalse(c, "F&F");
  c := a OR b; Test.AssertTrue(c,  "T|F");
  c := b OR b; Test.AssertFalse(c, "F|F");
  c := a OR a; Test.AssertTrue(c,  "T|T");
  c := ~a;     Test.AssertFalse(c, "~T");
  c := ~b;     Test.AssertTrue(c,  "~F");
  x := 10.0; y := 20.0; z := 0.0;
  IF (x < y) & (x > 0.0) THEN z := 100.0 END;
  Test.AssertReal(100.0, REAL(z), "combined")
END LrTBooleanOps;

PROCEDURE LrTBooleanCompares*;
VAR a, b, c: LONGREAL;
BEGIN
  a := 10.0; b := 20.0; c := 10.0;
  Test.AssertTrue(a = c,  "a=c");
  Test.AssertFalse(a = b, "a=b false");
  Test.AssertTrue(a # b,  "a#b");
  Test.AssertTrue(a < b,  "a<b");
  Test.AssertFalse(b < a, "b<a false");
  Test.AssertTrue(a <= c, "a<=c");
  Test.AssertTrue(b > a,  "b>a")
END LrTBooleanCompares;

PROCEDURE LrTStaticArray*;
VAR arr: LrLRArr10; mat: LrMatrix; i, j: INTEGER;
    sum, step: LONGREAL;
BEGIN
  step := 0.0;
  FOR i := 0 TO 9 DO arr[i] := step; step := step + 1.5 END;
  Test.AssertReal(0.0,  REAL(arr[0]), "arr[0]");
  Test.AssertReal(7.5,  REAL(arr[5]), "arr[5]");
  Test.AssertReal(13.5, REAL(arr[9]), "arr[9]");
  sum := 0.0;
  FOR i := 0 TO 9 DO sum := sum + arr[i] END;
  Test.AssertReal(67.5, REAL(sum), "sum");
  FOR i := 0 TO 4 DO
    FOR j := 0 TO 4 DO mat[i][j] := LONGREAL(i * 10 + j) + 0.5 END
  END;
  Test.AssertReal(0.5,  REAL(mat[0][0]), "mat[0][0]");
  Test.AssertReal(23.5, REAL(mat[2][3]), "mat[2][3]");
  Test.AssertReal(44.5, REAL(mat[4][4]), "mat[4][4]");
  i := 3; j := 4;
  Test.AssertReal(34.5, REAL(mat[i][j]), "mat[3][4] var idx")
END LrTStaticArray;

PROCEDURE LrTArrayIndexing*;
VAR arr: LrLRArr100; i: INTEGER; step: LONGREAL;
BEGIN
  step := 0.0;
  FOR i := 0 TO 99 DO arr[i] := step; step := step + 0.5 END;
  Test.AssertReal(12.5, REAL(arr[25]), "arr[25]");
  Test.AssertReal(25.0, REAL(arr[50]), "arr[50]");
  Test.AssertReal(49.5, REAL(arr[99]), "arr[99]")
END LrTArrayIndexing;

PROCEDURE LrTRecordAccess*;
VAR p: LrPoint; r: LrRectangle;
BEGIN
  p.x := 100.5; p.y := 200.75;
  Test.AssertReal(100.5,  REAL(p.x), "p.x");
  Test.AssertReal(200.75, REAL(p.y), "p.y");
  r.topLeft.x := 10.25;  r.topLeft.y := 20.5;
  r.bottomRight.x := 100.0; r.bottomRight.y := 200.0;
  Test.AssertReal(10.25, REAL(r.topLeft.x),     "tl.x");
  Test.AssertReal(20.5,  REAL(r.topLeft.y),     "tl.y");
  Test.AssertReal(100.0, REAL(r.bottomRight.x), "br.x");
  Test.AssertReal(200.0, REAL(r.bottomRight.y), "br.y");
  r.topLeft.x := r.bottomRight.x - r.topLeft.x;
  Test.AssertReal(89.75, REAL(r.topLeft.x), "tl.x updated")
END LrTRecordAccess;

PROCEDURE LrTRecordAlignment*;
VAR m: LrMixed;
BEGIN
  m.a := 1; m.b := 1000.5; m.c := 2; m.d := 2000.75;
  Test.AssertInt(1,        ORD(m.a), "m.a=1");
  Test.AssertReal(1000.5,   REAL(m.b), "m.b");
  Test.AssertInt(2,        ORD(m.c), "m.c=2");
  Test.AssertReal(2000.75,  REAL(m.d), "m.d")
END LrTRecordAlignment;

PROCEDURE LrTHeap*;
VAR p: LrHeapLongReal; q: LrLongRealBlock; i: INTEGER; sum, step: LONGREAL;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "NEW p");
  p^.value := 42.5;
  Test.AssertReal(42.5, REAL(p^.value), "p^.value");
  DISPOSE(p);
  NEW(q);
  Test.AssertNotNil(q, "NEW q");
  step := 0.0;
  FOR i := 0 TO 49 DO q^[i] := step; step := step + 1.5 END;
  sum := 0.0;
  FOR i := 0 TO 49 DO sum := sum + q^[i] END;
  Test.AssertReal(1837.5, REAL(sum), "sum heap");
  DISPOSE(q)
END LrTHeap;

PROCEDURE MaTAbs*;
BEGIN
  Test.AssertReal(3.5, Math.Abs(3.5),  "Abs(3.5)");
  Test.AssertReal(3.5, Math.Abs(-3.5), "Abs(-3.5)");
  Test.AssertReal(0.0, Math.Abs(0.0),  "Abs(0.0)")
END MaTAbs;

PROCEDURE MaTSqr*;
BEGIN
  Test.AssertReal(16.0,  Math.Sqr(4.0),  "Sqr(4.0)");
  Test.AssertReal(6.25,  Math.Sqr(-2.5), "Sqr(-2.5)")
END MaTSqr;

PROCEDURE MaTSqrt*;
BEGIN
  Test.AssertReal(3.0,        Math.Sqrt(9.0), "Sqrt(9.0)");
  Test.AssertReal(1.41421356, Math.Sqrt(2.0), "Sqrt(2.0)")
END MaTSqrt;

PROCEDURE MaTRound*;
BEGIN
  Test.AssertInt(3,  Math.Round(3.4),  "Round(3.4)");
  Test.AssertInt(4,  Math.Round(3.6),  "Round(3.6)");
  Test.AssertInt(-3, Math.Round(-3.4), "Round(-3.4)");
  Test.AssertInt(-4, Math.Round(-3.6), "Round(-3.6)");
  Test.AssertInt(0,  Math.Round(0.0),  "Round(0.0)")
END MaTRound;

PROCEDURE MaTTrunc*;
BEGIN
  Test.AssertInt(3,  Math.Trunc(3.7),  "Trunc(3.7)");
  Test.AssertInt(-3, Math.Trunc(-3.7), "Trunc(-3.7)");
  Test.AssertInt(5,  Math.Trunc(5.0),  "Trunc(5.0)");
  Test.AssertInt(-5, Math.Trunc(-5.0), "Trunc(-5.0)")
END MaTTrunc;

PROCEDURE MaTInt*;
BEGIN
  Test.AssertReal( 3.0, Math.Int( 3.7), "Int(3.7)");
  Test.AssertReal(-3.0, Math.Int(-3.7), "Int(-3.7)")
END MaTInt;

PROCEDURE MaTTan*;
BEGIN
  Test.AssertReal(0.0,        Math.Tan(0.0), "Tan(0.0)");
  Test.AssertReal(0.54630249, Math.Tan(0.5), "Tan(0.5)")
END MaTTan;

PROCEDURE MaTArcTan*;
BEGIN
  Test.AssertReal( 0.0,        Math.ArcTan( 0.0),   "ArcTan(0.0)");
  Test.AssertReal( 0.78539816, Math.ArcTan( 1.0),   "ArcTan(1.0)");
  Test.AssertReal(-0.78539816, Math.ArcTan(-1.0),   "ArcTan(-1.0)");
  Test.AssertReal( 0.46364761, Math.ArcTan( 0.5),   "ArcTan(0.5)");
  Test.AssertReal( 1.10714872, Math.ArcTan( 2.0),   "ArcTan(2.0)");
  Test.AssertReal(-1.10714872, Math.ArcTan(-2.0),   "ArcTan(-2.0)");
  Test.AssertReal( 1.47112767, Math.ArcTan( 10.0),  "ArcTan(10.0)");
  Test.AssertReal( 1.56079666, Math.ArcTan( 100.0), "ArcTan(100.0)");
  Test.AssertReal( 0.6,        Math.Tan(Math.ArcTan(0.6)), "Tan(ArcTan(0.6))")
END MaTArcTan;

PROCEDURE MaTNestedINLINE*;
BEGIN
  Test.AssertInt(7,    Math.Trunc(Math.Abs(-7.5)),  "Trunc(Abs(-7.5))");
  Test.AssertInt(7,    Math.Trunc(Math.Abs( 7.5)),  "Trunc(Abs( 7.5))");
  Test.AssertInt(6,    Math.Round(Math.Sqr(2.5)),   "Round(Sqr(2.5))");
  Test.AssertReal(3.0, Math.Sqrt(Math.Sqr(3.0)),    "Sqrt(Sqr(3.0))");
  Test.AssertReal(5.0, Math.Abs(Math.Int(-5.7)),    "Abs(Int(-5.7))")
END MaTNestedINLINE;

PROCEDURE MaTMixed*;
VAR x, y: REAL; n: INTEGER;
BEGIN
  x := Math.Sqrt(16.0);
  Test.AssertReal(4.0,  x, "x := Sqrt(16)");
  y := Math.Sqr(x);
  Test.AssertReal(16.0, y, "y := Sqr(x)");
  n := Math.Trunc(y + 0.4);
  Test.AssertInt(16, n, "Trunc(y+0.4)")
END MaTMixed;

PROCEDURE IcTArith*;
VAR n: INTEGER; r: REAL;
BEGIN
  n := 3;
  r := 1.5;
  Test.AssertReal(4.5, 1.5 * n, "1.5*n");
  Test.AssertReal(4.5, r * n,   "r*n");
  Test.AssertReal(4.5, n * 1.5, "n*1.5");
  Test.AssertReal(4.5, n * r,   "n*r");
  Test.AssertReal(3.0, 9.0 / n, "9.0/n");
  Test.AssertReal(1.5, r / 1,   "r/1");
  Test.AssertReal(2.0, 3 / r,   "3/r");
  Test.AssertReal(2.5, r + 1,   "r+1");
  Test.AssertReal(4.5, r + n,   "r+n");
  Test.AssertReal(2.5, 1 + r,   "1+r");
  Test.AssertReal(4.5, n + r,   "n+r");
  Test.AssertReal(0.5, r - 1,   "r-1");
  Test.AssertReal(0.5, 2 - r,   "2-r");
  r := -0.5;
  Test.AssertTrue (r < 0,  "r<0 neg");
  r := 0.0;
  Test.AssertTrue (r = 0,  "r=0 zero");
  r := 0.5;
  Test.AssertFalse(r < 0,  "~(r<0) pos");
  Test.AssertFalse(r = 0,  "~(r=0) pos");
  r := 3.0;
  Test.AssertTrue(r > 2,   "r>2");
  Test.AssertTrue(r >= 3,  "r>=3");
  Test.AssertTrue(r # 2,   "r#2");
  n := 2;
  Test.AssertTrue(n < r,   "n<r");
  Test.AssertTrue(n # r,   "n#r")
END IcTArith;

PROCEDURE IcTLongreal*;
VAR n: INTEGER; lr: LONGREAL;
BEGIN
  n := 4;
  lr := 2.5;
  Test.AssertTrue(lr * n = 10.0, "lr*n");
  Test.AssertTrue(n * lr = 10.0, "n*lr");
  Test.AssertTrue(lr + n = 6.5,  "lr+n");
  Test.AssertTrue(n + lr = 6.5,  "n+lr");
  Test.AssertTrue(lr - n = -1.5, "lr-n");
  Test.AssertTrue(lr / 2 = 1.25, "lr/2");
  Test.AssertFalse(lr < 0, "lr<0 false");
  lr := -1.0;
  Test.AssertTrue(lr < 0, "lr<0 true");
  lr := 0.0;
  Test.AssertTrue(lr = 0, "lr=0 true")
END IcTLongreal;

PROCEDURE IcTLiteral*;
VAR r: REAL;
BEGIN
  r := 2.0;
  Test.AssertReal(6.0, 2.0 * 3, "2.0*3");
  Test.AssertReal(6.0, 3 * 2.0, "3*2.0");
  Test.AssertReal(3.0, 1.0 + 2, "1.0+2");
  Test.AssertReal(3.0, 2 + 1.0, "2+1.0");
  Test.AssertReal(2.0, 3.0 - 1, "3.0-1");
  Test.AssertReal(2.0, 3 - 1.0, "3-1.0");
  Test.AssertReal(3.0, 6.0 / 2, "6.0/2");
  Test.AssertTrue(r < 3, "r<3");
  Test.AssertTrue(r = 2, "r=2");
  Test.AssertTrue(r > 1, "r>1");
  Test.AssertTrue(r # 3, "r#3");
  Test.AssertTrue(3 > r, "3>r");
  Test.AssertTrue(1 < r, "1<r")
END IcTLiteral;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(ReTRealArithmetic, "Re/arith");
  Test.AddTest(ReTRealBoundaries, "Re/boundaries");
  Test.AddTest(ReTRealAssignment, "Re/assignment");
  Test.AddTest(ReTRealConversion, "Re/conversion");
  Test.AddTest(ReTBooleanOperations, "Re/boolOps");
  Test.AddTest(ReTBooleanComparisons, "Re/boolCompares");
  Test.AddTest(ReTStaticArray, "Re/staticArray");
  Test.AddTest(ReTArrayIndexing, "Re/arrayIndex");
  Test.AddTest(ReTRecordAccess, "Re/recordAccess");
  Test.AddTest(ReTRecordAlignment, "Re/recordAlign");
  Test.AddTest(ReTHeapAllocation, "Re/heap");
  Test.AddTest(LrTArith, "Lr/arith");
  Test.AddTest(LrTBoundaries, "Lr/boundaries");
  Test.AddTest(LrTAssignment, "Lr/assignment");
  Test.AddTest(LrTConversion, "Lr/conversion");
  Test.AddTest(LrTBooleanOps, "Lr/boolOps");
  Test.AddTest(LrTBooleanCompares, "Lr/boolCompares");
  Test.AddTest(LrTStaticArray, "Lr/staticArray");
  Test.AddTest(LrTArrayIndexing, "Lr/arrayIndex");
  Test.AddTest(LrTRecordAccess, "Lr/recordAccess");
  Test.AddTest(LrTRecordAlignment, "Lr/recordAlign");
  Test.AddTest(LrTHeap, "Lr/heap");
  Test.AddTest(MaTAbs, "Ma/abs");
  Test.AddTest(MaTSqr, "Ma/sqr");
  Test.AddTest(MaTSqrt, "Ma/sqrt");
  Test.AddTest(MaTRound, "Ma/round");
  Test.AddTest(MaTTrunc, "Ma/trunc");
  Test.AddTest(MaTInt, "Ma/int");
  Test.AddTest(MaTTan, "Ma/tan");
  Test.AddTest(MaTArcTan, "Ma/arctan");
  Test.AddTest(MaTNestedINLINE, "Ma/nestedInline");
  Test.AddTest(MaTMixed, "Ma/mixed");
  Test.AddTest(IcTArith, "Ic/arith");
  Test.AddTest(IcTLongreal, "Ic/longreal");
  Test.AddTest(IcTLiteral, "Ic/literal");
  Test.RunTests
END RunAllTests;

END FLOAT.
