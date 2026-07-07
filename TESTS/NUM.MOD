MODULE NUM;
IMPORT Test;

CONST
  TyMaxInt = 7FFFH;
  TyMinInt = -32768;
  LiMaxLong = 7FFFFFFFH;
  LiMinLong = 80000000H;
  LgMaxLong = 7FFFFFFFH;
  LgMinLong = 80000000H;

TYPE
  TyHeapRec = POINTER TO RECORD value: INTEGER; extra: INTEGER END;
  TyDataBlock = POINTER TO ARRAY 100 OF INTEGER;
  TyLargeArray = POINTER TO ARRAY 50 OF INTEGER;
  LgLongRecord = POINTER TO RECORD a, b, c: LONGINT END;
  LgDataBlock  = POINTER TO ARRAY 100 OF LONGINT;
  LgPoint      = RECORD x, y: LONGINT END;
  LgRectangle  = RECORD topLeft, bottomRight: LgPoint END;
  LgMixed      = RECORD a: BYTE; b: LONGINT; c: BYTE; d: LONGINT END;
  LgLongArray10 = ARRAY 10 OF LONGINT;
  LgLongArray100 = ARRAY 100 OF LONGINT;

PROCEDURE TyTestIntegerArithmetic*;
VAR a, b, c: INTEGER;
BEGIN
  a := 100; b := 200;  c := a + b;     Test.AssertInt(300,  c, "100+200");
  a := 100; b := -200; c := a + b;     Test.AssertInt(-100, c, "100+-200");
  a := 500; b := 300;  c := a - b;     Test.AssertInt(200,  c, "500-300");
  a := 50;  b := 20;   c := a * b;     Test.AssertInt(1000, c, "50*20");
  a := -50; b := 20;   c := a * b;     Test.AssertInt(-1000, c, "-50*20");
  a := 100; b := 3;    c := a DIV b;   Test.AssertInt(33,   c, "100 DIV 3");
  a := -100; b := 3;   c := a DIV b;   Test.AssertInt(-33,  c, "-100 DIV 3");
  a := 100; b := 3;    c := a MOD b;   Test.AssertInt(1,    c, "100 MOD 3");
  a := 10; b := 20; c := 30;
  a := (a + b) * c - 50;               Test.AssertInt(850,  a, "(10+20)*30-50")
END TyTestIntegerArithmetic;

PROCEDURE TyTestIntegerBoundaries*;
VAR a, b, c: INTEGER; overflow: BOOLEAN;
BEGIN
  a := TyMaxInt; Test.AssertInt(32767,  a, "TyMaxInt");
  a := TyMinInt; Test.AssertInt(-32768, a, "TyMinInt");
  overflow := FALSE;
  a := TyMaxInt; b := 1; c := a + b;
  IF (a > 0) & (b > 0) & (c < 0) THEN overflow := TRUE END;
  Test.AssertTrue(overflow, "TyMaxInt+1 overflow")
END TyTestIntegerBoundaries;

PROCEDURE TyTestIntegerAssignment*;
VAR a, b: INTEGER; const1, const2: INTEGER;
BEGIN
  a := 12345;  b := -12345;
  Test.AssertInt(12345,  a, "12345");
  Test.AssertInt(-12345, b, "-12345");
  const1 := 777; const2 := 888;
  a := const1; b := const2;
  Test.AssertInt(777, a, "const1");
  Test.AssertInt(888, b, "const2");
  a := (const1 + const2) * 2;
  Test.AssertInt(3330, a, "(c1+c2)*2")
END TyTestIntegerAssignment;

PROCEDURE TyTestShiftLSL*;
VAR a, result: INTEGER;
BEGIN
  a := 1;     result := SYSTEM.LSL(a, 1); Test.AssertInt(2,     result, "LSL 1,1");
  a := 3;     result := SYSTEM.LSL(a, 2); Test.AssertInt(12,    result, "LSL 3,2");
  a := 255;   result := SYSTEM.LSL(a, 4); Test.AssertInt(4080,  result, "LSL 255,4");
  a := 1;     result := SYSTEM.LSL(a, 8); Test.AssertInt(256,   result, "LSL 1,8");
  a := 5;     result := SYSTEM.LSL(a, 5); Test.AssertInt(160,   result, "LSL 5,5");
  a := 32767; result := SYSTEM.LSL(a, 1); Test.AssertInt(-2,    result, "LSL 32767,1");
  a := 16384; result := SYSTEM.LSL(a, 1); Test.AssertInt(-32768, result, "LSL 16384,1")
END TyTestShiftLSL;

PROCEDURE TyTestShiftLSR*;
VAR a, result: INTEGER;
BEGIN
  a := 2;     result := SYSTEM.LSR(a, 1); Test.AssertInt(1,     result, "LSR 2,1");
  a := 12;    result := SYSTEM.LSR(a, 2); Test.AssertInt(3,     result, "LSR 12,2");
  a := 4080;  result := SYSTEM.LSR(a, 4); Test.AssertInt(255,   result, "LSR 4080,4");
  a := 256;   result := SYSTEM.LSR(a, 8); Test.AssertInt(1,     result, "LSR 256,8");
  a := 160;   result := SYSTEM.LSR(a, 5); Test.AssertInt(5,     result, "LSR 160,5");
  a := -2;    result := SYSTEM.LSR(a, 1); Test.AssertInt(32767, result, "LSR -2,1");
  a := -32768; result := SYSTEM.LSR(a, 1); Test.AssertInt(16384, result, "LSR Min,1")
END TyTestShiftLSR;

PROCEDURE TyTestShiftASR*;
VAR a, result: INTEGER;
BEGIN
  a := 2;     result := SYSTEM.ASR(a, 1); Test.AssertInt(1,    result, "ASR 2,1");
  a := 12;    result := SYSTEM.ASR(a, 2); Test.AssertInt(3,    result, "ASR 12,2");
  a := 4080;  result := SYSTEM.ASR(a, 4); Test.AssertInt(255,  result, "ASR 4080,4");
  a := 256;   result := SYSTEM.ASR(a, 8); Test.AssertInt(1,    result, "ASR 256,8");
  a := 160;   result := SYSTEM.ASR(a, 5); Test.AssertInt(5,    result, "ASR 160,5");
  a := -2;    result := SYSTEM.ASR(a, 1); Test.AssertInt(-1,   result, "ASR -2,1");
  a := -4;    result := SYSTEM.ASR(a, 1); Test.AssertInt(-2,   result, "ASR -4,1");
  a := -16;   result := SYSTEM.ASR(a, 2); Test.AssertInt(-4,   result, "ASR -16,2");
  a := -1;    result := SYSTEM.ASR(a, 5); Test.AssertInt(-1,   result, "ASR -1,5");
  a := -32768; result := SYSTEM.ASR(a, 1); Test.AssertInt(-16384, result, "ASR Min,1")
END TyTestShiftASR;

PROCEDURE TyTestShiftROR*;
VAR a, result: INTEGER;
BEGIN
  a := 1;     result := SYSTEM.ROR(a, 1); Test.AssertInt(-32768, result, "ROR 1,1");
  a := 2;     result := SYSTEM.ROR(a, 1); Test.AssertInt(1,      result, "ROR 2,1");
  a := 4;     result := SYSTEM.ROR(a, 1); Test.AssertInt(2,      result, "ROR 4,1");
  a := 8;     result := SYSTEM.ROR(a, 1); Test.AssertInt(4,      result, "ROR 8,1");
  a := -32768; result := SYSTEM.ROR(a, 1); Test.AssertInt(16384, result, "ROR Min,1");
  a := 1;     result := SYSTEM.ROR(a, 2); Test.AssertInt(16384,  result, "ROR 1,2");
  a := 3;     result := SYSTEM.ROR(a, 1); Test.AssertInt(-32767, result, "ROR 3,1");
  a := -1;    result := SYSTEM.ROR(a, 8); Test.AssertInt(-1,     result, "ROR -1,8")
END TyTestShiftROR;

PROCEDURE TyTestShiftCombinations*;
VAR a, result: INTEGER;
BEGIN
  a := 1;
  result := SYSTEM.LSL(a, 3);
  result := SYSTEM.LSR(result, 1);
  Test.AssertInt(4, result, "LSL3 LSR1");
  a := 100;
  result := SYSTEM.LSL(a, 2);
  result := SYSTEM.ASR(result, 1);
  Test.AssertInt(200, result, "LSL2 ASR1");
  a := -100;
  result := SYSTEM.ASR(a, 2);
  result := SYSTEM.LSL(result, 1);
  Test.AssertInt(-50, result, "ASR2 LSL1");
  a := 1;
  result := SYSTEM.ROR(a, 1);
  result := SYSTEM.LSL(result, 1);
  Test.AssertInt(0, result, "ROR1 LSL1");
  a := 255;
  result := SYSTEM.LSL(a, 8);
  result := SYSTEM.LSR(result, 8);
  Test.AssertInt(255, result, "LSL8 LSR8");
  a := 12345;
  result := SYSTEM.LSL(a, 4);
  result := SYSTEM.LSR(result, 4);
  Test.AssertInt(57, result, "12345 LSL4 LSR4")
END TyTestShiftCombinations;

PROCEDURE TyTestShiftWithVariables*;
VAR value, shift, result: INTEGER;
BEGIN
  value := 1;     shift := 5;  result := SYSTEM.LSL(value, shift); Test.AssertInt(32,    result, "LSL 1,5 var");
  value := 128;   shift := 3;  result := SYSTEM.LSR(value, shift); Test.AssertInt(16,    result, "LSR 128,3 var");
  value := -64;   shift := 2;  result := SYSTEM.ASR(value, shift); Test.AssertInt(-16,   result, "ASR -64,2 var");
  value := 1;     shift := 15; result := SYSTEM.LSL(value, shift); Test.AssertInt(-32768, result, "LSL 1,15 var");
  value := -32768; shift := 1; result := SYSTEM.LSR(value, shift); Test.AssertInt(16384, result, "LSR Min,1 var")
END TyTestShiftWithVariables;

PROCEDURE TyTestShiftBoundaries*;
VAR a, result: INTEGER;
BEGIN
  a := 12345;
  result := SYSTEM.LSL(a, 0); Test.AssertInt(12345, result, "LSL 0");
  result := SYSTEM.LSR(a, 0); Test.AssertInt(12345, result, "LSR 0");
  result := SYSTEM.ASR(a, 0); Test.AssertInt(12345, result, "ASR 0");
  result := SYSTEM.ROR(a, 0); Test.AssertInt(12345, result, "ROR 0");
  a := 1;
  result := SYSTEM.LSL(a, 15); Test.AssertInt(-32768, result, "LSL 1,15");
  result := SYSTEM.LSL(a, 16); Test.AssertInt(0,      result, "LSL 1,16");
  a := -1;
  result := SYSTEM.LSR(a, 1);  Test.AssertInt(32767,  result, "LSR -1,1");
  result := SYSTEM.ASR(a, 16); Test.AssertInt(-1,     result, "ASR -1,16");
  a := 1;
  result := SYSTEM.ROR(a, 16); Test.AssertInt(1,      result, "ROR 1,16")
END TyTestShiftBoundaries;

PROCEDURE TyTestBooleanOperations*;
VAR a, b, c: BOOLEAN; x, y, z: INTEGER;
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
  a := TRUE; b := FALSE;
  c := (a & ~b) OR (~a & b); Test.AssertTrue(c, "xor TRUE");
  x := 10; y := 20; z := 0;
  IF (x < y) & (x > 0) THEN z := 100 END;
  Test.AssertInt(100, z, "combined")
END TyTestBooleanOperations;

PROCEDURE TyReturnFalse(): BOOLEAN;
BEGIN RETURN FALSE END TyReturnFalse;

PROCEDURE TyTestBoolNot*;
VAR t, f, a, b: BOOLEAN; x: INTEGER;
BEGIN
  t := TRUE; f := FALSE;
  Test.AssertTrue(~TyReturnFalse(), "~TyReturnFalse");
  Test.AssertFalse(~t, "~t");
  Test.AssertTrue(~f, "~f");
  Test.AssertTrue(~~t, "~~t");
  Test.AssertFalse(~~f, "~~f");
  x := 0; IF ~f THEN x := 1 END; Test.AssertInt(1, x, "IF ~f");
  x := 0; IF ~t THEN x := 1 END; Test.AssertInt(0, x, "IF ~t");
  a := TRUE; b := FALSE;
  Test.AssertTrue(~b & a, "~F & T");
  Test.AssertFalse(~a & a, "~T & T");
  Test.AssertTrue(~b OR f, "~F OR F");
  Test.AssertFalse(~a OR f, "~T OR F");
  x := 0; a := FALSE;
  WHILE ~a DO INC(x); a := TRUE END;
  Test.AssertInt(1, x, "WHILE ~a");
  x := 0; a := FALSE;
  REPEAT INC(x); a := TRUE UNTIL ~a = FALSE;
  Test.AssertInt(1, x, "REPEAT ~a");
  a := TRUE; b := TRUE;
  Test.AssertTrue((~(a & b)) = (~a OR ~b), "De Morgan TT");
  a := TRUE; b := FALSE;
  Test.AssertTrue((~(a & b)) = (~a OR ~b), "De Morgan TF");
  a := FALSE; b := FALSE;
  Test.AssertTrue((~(a & b)) = (~a OR ~b), "De Morgan FF")
END TyTestBoolNot;

PROCEDURE TyTestBooleanComparisons*;
VAR a, b, c: INTEGER;
BEGIN
  a := 10; b := 20; c := 10;
  Test.AssertTrue(a = c,  "a=c");
  Test.AssertFalse(a = b, "a=b");
  Test.AssertTrue(a # b,  "a#b");
  Test.AssertTrue(a < b,  "a<b");
  Test.AssertFalse(b < a, "b<a");
  Test.AssertTrue(a <= c, "a<=c");
  Test.AssertTrue(b > a,  "b>a")
END TyTestBooleanComparisons;

PROCEDURE TyTestStaticArray*;
TYPE
  IntArray = ARRAY 10 OF INTEGER;
  Matrix = ARRAY 25 OF INTEGER;
VAR arr: IntArray; mat: Matrix; i, j, sum: INTEGER;
BEGIN
  FOR i := 0 TO 9 DO arr[i] := i * i END;
  Test.AssertInt(0,  arr[0], "arr[0]");
  Test.AssertInt(25, arr[5], "arr[5]");
  Test.AssertInt(81, arr[9], "arr[9]");
  sum := 0;
  FOR i := 0 TO 9 DO sum := sum + arr[i] END;
  Test.AssertInt(285, sum, "sum");
  FOR i := 0 TO 4 DO
    FOR j := 0 TO 4 DO mat[i * 5 + j] := i * 10 + j END
  END;
  Test.AssertInt(0,  mat[0],  "mat[0]");
  Test.AssertInt(23, mat[13], "mat[13]");
  Test.AssertInt(44, mat[24], "mat[24]");
  i := 3; j := 4;
  Test.AssertInt(34, mat[i * 5 + j], "mat[3,4] var")
END TyTestStaticArray;

PROCEDURE TyTestArrayIndexing*;
TYPE
  ByteArray = ARRAY 100 OF BYTE;
  WordArray = ARRAY 100 OF INTEGER;
VAR bytes: ByteArray; words: WordArray; i: INTEGER;
BEGIN
  FOR i := 0 TO 99 DO bytes[i] := CHR(i MOD 256) END;
  Test.AssertInt(50, ORD(bytes[50]), "bytes[50]");
  FOR i := 0 TO 99 DO words[i] := i * 100 END;
  Test.AssertInt(2500, words[25], "words[25]");
  Test.AssertInt(5000, words[50], "words[50]")
END TyTestArrayIndexing;

PROCEDURE TyTestRecordAccess*;
TYPE
  Point = RECORD x, y: INTEGER END;
  Rectangle = RECORD topLeft, bottomRight: Point END;
VAR p: Point; r: Rectangle;
BEGIN
  p.x := 100; p.y := 200;
  Test.AssertInt(100, p.x, "p.x");
  Test.AssertInt(200, p.y, "p.y");
  r.topLeft.x := 10; r.topLeft.y := 20;
  r.bottomRight.x := 100; r.bottomRight.y := 200;
  Test.AssertInt(10,  r.topLeft.x,     "tl.x");
  Test.AssertInt(20,  r.topLeft.y,     "tl.y");
  Test.AssertInt(100, r.bottomRight.x, "br.x");
  Test.AssertInt(200, r.bottomRight.y, "br.y");
  r.topLeft.x := r.bottomRight.x - r.topLeft.x;
  Test.AssertInt(90, r.topLeft.x, "tl.x upd")
END TyTestRecordAccess;

PROCEDURE TyTestRecordAlignment*;
TYPE
  Mixed = RECORD a: BYTE; b: INTEGER; c: BYTE; d: INTEGER END;
VAR m: Mixed;
BEGIN
  m.a := 1; m.b := 1000; m.c := 2; m.d := 2000;
  Test.AssertInt(1,    ORD(m.a), "m.a");
  Test.AssertInt(1000, m.b,      "m.b");
  Test.AssertInt(2,    ORD(m.c), "m.c");
  Test.AssertInt(2000, m.d,      "m.d")
END TyTestRecordAlignment;

PROCEDURE TyTestHeapAllocation*;
VAR p: TyHeapRec; q: TyDataBlock; i, sum: INTEGER;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "NEW p");
  p^.value := 42; p^.extra := 0;
  Test.AssertInt(42, p^.value, "p^.value");
  DISPOSE(p);
  NEW(q);
  Test.AssertNotNil(q, "NEW q");
  FOR i := 0 TO 49 DO q^[i] := i * 2 END;
  sum := 0;
  FOR i := 0 TO 49 DO sum := sum + q^[i] END;
  Test.AssertInt(2450, sum, "sum");
  DISPOSE(q)
END TyTestHeapAllocation;

PROCEDURE TyTestHeapMultiAlloc*;
VAR p1, p2, p3: TyHeapRec;
BEGIN
  NEW(p1); NEW(p2); NEW(p3);
  Test.AssertNotNil(p1, "NEW p1");
  Test.AssertNotNil(p2, "NEW p2");
  Test.AssertNotNil(p3, "NEW p3");
  p1^.value := 100; p2^.value := 200; p3^.value := 300;
  Test.AssertInt(100, p1^.value, "p1");
  Test.AssertInt(200, p2^.value, "p2");
  Test.AssertInt(300, p3^.value, "p3");
  DISPOSE(p1); DISPOSE(p2); DISPOSE(p3)
END TyTestHeapMultiAlloc;

PROCEDURE TyTestFarPointers*;
VAR p: TyLargeArray;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "NEW TyLargeArray");
  p^[5] := 12345;
  Test.AssertInt(12345, p^[5], "p^[5]");
  DISPOSE(p)
END TyTestFarPointers;

PROCEDURE LiTBasicArith*;
VAR a, b, c: LONGINT;
BEGIN
  a := LONGINT(10); b := LONGINT(20);
  c := a + b;             Test.AssertLong(LONGINT(30), c, "a+b");
  c := b - a;             Test.AssertLong(LONGINT(10), c, "b-a");
  c := a + b + LONGINT(5); Test.AssertLong(LONGINT(35), c, "a+b+5")
END LiTBasicArith;

PROCEDURE LiTMultiply*;
VAR a, b, c: LONGINT;
BEGIN
  a := LONGINT(7); b := LONGINT(6);   c := a * b; Test.AssertLong(LONGINT(42), c, "7*6");
  a := LONGINT(100); b := LONGINT(300); c := a * b; Test.AssertLong(LONGINT(30000), c, "100*300")
END LiTMultiply;

PROCEDURE LiTDivMod*;
VAR a, b, c: LONGINT;
BEGIN
  a := LONGINT(100); b := LONGINT(7);
  c := a DIV b; Test.AssertLong(LONGINT(14), c, "100 DIV 7");
  c := a MOD b; Test.AssertLong(LONGINT(2),  c, "100 MOD 7");
  a := LONGINT(42); b := LONGINT(6);
  c := a DIV b; Test.AssertLong(LONGINT(7),  c, "42 DIV 6");
  c := a MOD b; Test.AssertLong(LONGINT(0),  c, "42 MOD 6")
END LiTDivMod;

PROCEDURE LiTNegate*;
VAR a, b: LONGINT;
BEGIN
  a := LONGINT(42); b := -a;        Test.AssertLong(LONGINT(-42), b, "-42");
  b := -LONGINT(1);                 Test.AssertLong(LONGINT(-1),  b, "-1")
END LiTNegate;

PROCEDURE LiTCompare*;
VAR a, b: LONGINT;
BEGIN
  a := LONGINT(10); b := LONGINT(20);
  Test.AssertTrue(a < b,  "a<b");
  Test.AssertTrue(b > a,  "b>a");
  Test.AssertTrue(a # b,  "a#b");
  a := LONGINT(42); b := LONGINT(42);
  Test.AssertTrue(a = b,  "a=b");
  Test.AssertTrue(a <= b, "a<=b");
  Test.AssertTrue(a >= b, "a>=b")
END LiTCompare;

PROCEDURE LiTCastToLong*;
VAR i: INTEGER; l: LONGINT;
BEGIN
  i := 1000; l := LONGINT(i); Test.AssertLong(LONGINT(1000), l, "1000");
  i := -500; l := LONGINT(i); Test.AssertLong(LONGINT(-500), l, "-500")
END LiTCastToLong;

PROCEDURE LiTCastToInt*;
VAR l: LONGINT; i: INTEGER;
BEGIN
  l := LONGINT(12345); i := INTEGER(l); Test.AssertInt(12345, i, "12345");
  l := LONGINT(-999);  i := INTEGER(l); Test.AssertInt(-999,  i, "-999")
END LiTCastToInt;

PROCEDURE LiDouble(VAR x: LONGINT);
BEGIN x := x + x END LiDouble;

PROCEDURE LiTVarParam*;
VAR a: LONGINT;
BEGIN
  a := LONGINT(21);
  LiDouble(a);
  Test.AssertLong(LONGINT(42), a, "double 21")
END LiTVarParam;

PROCEDURE LiTLoop*;
VAR sum: LONGINT; i: INTEGER;
BEGIN
  sum := LONGINT(0);
  FOR i := 1 TO 10 DO sum := sum + LONGINT(i) END;
  Test.AssertLong(LONGINT(55), sum, "sum 1..10 LONGINT")
END LiTLoop;

PROCEDURE LiTNegMul*;
VAR a, b, c: LONGINT;
BEGIN
  a := LONGINT(-3); b := LONGINT(7); c := a * b; Test.AssertLong(LONGINT(-21), c, "-3*7");
  a := LONGINT(-4); b := LONGINT(-5); c := a * b; Test.AssertLong(LONGINT(20),  c, "-4*-5")
END LiTNegMul;

PROCEDURE LiTBoolOps*;
VAR a, b: LONGINT;
BEGIN
  a := LONGINT(10); b := LONGINT(20);
  Test.AssertTrue((a > 0) & (b > 0),    "both pos");
  Test.AssertTrue((a < b) & (b > a),    "a<b AND b>a");
  Test.AssertTrue(~((a > b) & (b > 0)), "NOT ((a>b) AND (b>0))");
  Test.AssertTrue((a > b) OR (b > a),   "a>b OR b>a");
  Test.AssertTrue(~((a > b) OR (a = b)),"NOT ((a>b) OR a=b)");
  a := LONGINT(-1);
  Test.AssertTrue((a < 0) & (a # 0),    "negative & non-zero");
  Test.AssertTrue((a > 0) OR (a < 0),   "pos OR neg")
END LiTBoolOps;

PROCEDURE LiTLSL*;
VAR a, r: LONGINT;
BEGIN
  a := LONGINT(1);  r := SYSTEM.LSL(a, 1);  Test.AssertLong(LONGINT(2),   r, "LSL 1,1");
  a := LONGINT(3);  r := SYSTEM.LSL(a, 2);  Test.AssertLong(LONGINT(12),  r, "LSL 3,2");
  a := LONGINT(1);  r := SYSTEM.LSL(a, 8);  Test.AssertLong(LONGINT(256), r, "LSL 1,8");
  a := LONGINT(1);  r := SYSTEM.LSL(a, 31); Test.AssertLong(LiMinLong,      r, "LSL 1,31");
  a := LiMaxLong;     r := SYSTEM.LSL(a, 1);  Test.AssertLong(LONGINT(-2),  r, "LSL Max,1");
  a := 40000000H;   r := SYSTEM.LSL(a, 1);  Test.AssertLong(LiMinLong,      r, "LSL 40000000H,1");
  a := LONGINT(1);  r := SYSTEM.LSL(a, 0);  Test.AssertLong(LONGINT(1),   r, "LSL 1,0")
END LiTLSL;

PROCEDURE LiTLSR*;
VAR a, r: LONGINT;
BEGIN
  a := LONGINT(2);   r := SYSTEM.LSR(a, 1);  Test.AssertLong(LONGINT(1), r, "LSR 2,1");
  a := LONGINT(12);  r := SYSTEM.LSR(a, 2);  Test.AssertLong(LONGINT(3), r, "LSR 12,2");
  a := LONGINT(256); r := SYSTEM.LSR(a, 8);  Test.AssertLong(LONGINT(1), r, "LSR 256,8");
  a := LONGINT(-2);  r := SYSTEM.LSR(a, 1);  Test.AssertLong(LiMaxLong,    r, "LSR -2,1");
  a := LiMinLong;      r := SYSTEM.LSR(a, 1);  Test.AssertLong(40000000H,  r, "LSR Min,1");
  a := LONGINT(-1);  r := SYSTEM.LSR(a, 1);  Test.AssertLong(LiMaxLong,    r, "LSR -1,1");
  a := LONGINT(1);   r := SYSTEM.LSR(a, 0);  Test.AssertLong(LONGINT(1), r, "LSR 1,0")
END LiTLSR;

PROCEDURE LiTASR*;
VAR a, r: LONGINT;
BEGIN
  a := LONGINT(2);   r := SYSTEM.ASR(a, 1);  Test.AssertLong(LONGINT(1),  r, "ASR 2,1");
  a := LONGINT(12);  r := SYSTEM.ASR(a, 2);  Test.AssertLong(LONGINT(3),  r, "ASR 12,2");
  a := LONGINT(-2);  r := SYSTEM.ASR(a, 1);  Test.AssertLong(LONGINT(-1), r, "ASR -2,1");
  a := LONGINT(-4);  r := SYSTEM.ASR(a, 1);  Test.AssertLong(LONGINT(-2), r, "ASR -4,1");
  a := LONGINT(-16); r := SYSTEM.ASR(a, 2);  Test.AssertLong(LONGINT(-4), r, "ASR -16,2");
  a := LONGINT(-1);  r := SYSTEM.ASR(a, 5);  Test.AssertLong(LONGINT(-1), r, "ASR -1,5");
  a := LiMinLong;      r := SYSTEM.ASR(a, 1);  Test.AssertLong(-40000000H,  r, "ASR Min,1");
  a := LONGINT(1);   r := SYSTEM.ASR(a, 0);  Test.AssertLong(LONGINT(1),  r, "ASR 1,0")
END LiTASR;

PROCEDURE LiTROR*;
VAR a, r: LONGINT;
BEGIN
  a := LONGINT(1);   r := SYSTEM.ROR(a, 1);  Test.AssertLong(LiMinLong,      r, "ROR 1,1");
  a := LONGINT(2);   r := SYSTEM.ROR(a, 1);  Test.AssertLong(LONGINT(1),   r, "ROR 2,1");
  a := LONGINT(4);   r := SYSTEM.ROR(a, 1);  Test.AssertLong(LONGINT(2),   r, "ROR 4,1");
  a := 40000000H;    r := SYSTEM.ROR(a, 1);  Test.AssertLong(20000000H,    r, "ROR 40000000H,1");
  a := LONGINT(1);   r := SYSTEM.ROR(a, 2);  Test.AssertLong(40000000H,    r, "ROR 1,2");
  a := LONGINT(3);   r := SYSTEM.ROR(a, 1);  Test.AssertLong(LiMinLong + 1,  r, "ROR 3,1");
  a := LONGINT(1);   r := SYSTEM.ROR(a, 0);  Test.AssertLong(LONGINT(1),   r, "ROR 1,0")
END LiTROR;

PROCEDURE LgTLongArithmetic*;
VAR a, b, c: LONGINT;
BEGIN
  a := 100; b := 200;  c := a + b; Test.AssertLong(300,  c, "100+200");
  a := 100; b := -200; c := a + b; Test.AssertLong(-100, c, "100+-200");
  a := 500; b := 300;  c := a - b; Test.AssertLong(200,  c, "500-300");
  a := 500; b := -300; c := a - b; Test.AssertLong(800,  c, "500--300");
  a := 50;  b := 20;   c := a * b; Test.AssertLong(1000, c, "50*20");
  a := 50;  b := -20;  c := a * b; Test.AssertLong(-1000,c, "50*-20");
  a := 100; b := 3;    c := a DIV b; Test.AssertLong(33, c, "100 DIV 3");
  a := 100; b := -3;   c := a DIV b; Test.AssertLong(-33,c, "100 DIV -3");
  a := 100; b := 3;    c := a MOD b; Test.AssertLong(1,  c, "100 MOD 3");
  a := 10; b := 20; c := 30;
  a := (a + b) * c - 50; Test.AssertLong(850, a, "(10+20)*30-50")
END LgTLongArithmetic;

PROCEDURE LgTLongBoundaries*;
VAR a, b, c: LONGINT; overflow: BOOLEAN;
BEGIN
  a := LgMaxLong;
  Test.AssertLong(7FFFFFFFH, a, "LgMaxLong");
  a := LgMinLong; b := -1; c := a - b;
  Test.AssertLong(-7FFFFFFFH, c, "Min - -1 = -LgMaxLong");
  overflow := FALSE;
  a := LgMaxLong; b := 1; c := a + b;
  IF (a > 0) & (b > 0) & (c < 0) THEN overflow := TRUE END;
  Test.AssertTrue(overflow, "LgMaxLong + 1 overflow")
END LgTLongBoundaries;

PROCEDURE LgTLongAssignment*;
VAR a, b: LONGINT; const1, const2: LONGINT;
BEGIN
  a := 75BCD15H;
  b := -3ADE68B1H;
  Test.AssertLong(75BCD15H,    a, "75BCD15H");
  Test.AssertLong(-3ADE68B1H,  b, "-3ADE68B1H");
  const1 := 0BDBF1H; const2 := 0D9038H;
  a := const1; b := const2;
  Test.AssertLong(0BDBF1H, a, "BDBF1H");
  Test.AssertLong(0D9038H, b, "D9038H");
  a := (const1 + const2) * 2;
  Test.AssertLong(32D852H, a, "(c1+c2)*2")
END LgTLongAssignment;

(* Regression: PStmt.ParseSysprocCall's two-arg INC/DEC for a LONGINT target
   used to unconditionally CWD (sign-extend) the loaded step value into DX,
   even when the step was itself LONGINT (whose true high word CgLoadItem had
   already placed in DX -- CWD then clobbered it) or WORD (unsigned 16-bit,
   wrongly sign-extended once bit 15 was set).  Fixed in PStmt.Mod: zero-extend
   WORD steps, skip the extend entirely for LONGINT steps, CWD only for
   INTEGER/BYTE. *)
PROCEDURE LgTIncDecStep*;
VAR v: LONGINT; wstep: WORD; bstep: BYTE; istep: INTEGER; lstep: LONGINT;
BEGIN
  v := 0; lstep := 65536; INC(v, lstep);
  Test.AssertLong(65536, v, "INC LONGINT v, LONGINT(65536)");

  v := 0; wstep := 40000; INC(v, wstep);  (* 9C40H: bit 15 set *)
  Test.AssertLong(40000, v, "INC LONGINT v, WORD(40000) bit15");

  v := 1000000; DEC(v, wstep);
  Test.AssertLong(960000, v, "DEC LONGINT v, WORD(40000) bit15");

  v := 0; bstep := 200; INC(v, bstep);
  Test.AssertLong(200, v, "INC LONGINT v, BYTE(200)");

  v := 0; istep := -5; INC(v, istep);
  Test.AssertLong(-5, v, "INC LONGINT v, INTEGER(-5)");

  v := 5; INC(v); Test.AssertLong(6, v, "INC LONGINT v (1-arg)");
  v := 5; DEC(v); Test.AssertLong(4, v, "DEC LONGINT v (1-arg)")
END LgTIncDecStep;

PROCEDURE LgTShiftLSL*;
VAR a, r: LONGINT;
BEGIN
  a := 1;   r := SYSTEM.LSL(a, 1); Test.AssertLong(2,        r, "LSL 1,1");
  a := 3;   r := SYSTEM.LSL(a, 2); Test.AssertLong(12,       r, "LSL 3,2");
  a := 0FFH; r := SYSTEM.LSL(a, 4); Test.AssertLong(0FF0H,    r, "LSL FF,4");
  a := 1;   r := SYSTEM.LSL(a, 8); Test.AssertLong(100H,     r, "LSL 1,8");
  a := 5;   r := SYSTEM.LSL(a, 5); Test.AssertLong(0A0H,     r, "LSL 5,5");
  a := LgMaxLong;   r := SYSTEM.LSL(a, 1); Test.AssertLong(-2,        r, "LSL Max,1");
  a := 40000000H; r := SYSTEM.LSL(a, 1); Test.AssertLong(LgMinLong,   r, "LSL 4..,1")
END LgTShiftLSL;

PROCEDURE LgTShiftLSR*;
VAR a, r: LONGINT;
BEGIN
  a := 2;     r := SYSTEM.LSR(a, 1); Test.AssertLong(1,        r, "LSR 2,1");
  a := 12;    r := SYSTEM.LSR(a, 2); Test.AssertLong(3,        r, "LSR 12,2");
  a := 0FF0H; r := SYSTEM.LSR(a, 4); Test.AssertLong(0FFH,     r, "LSR FF0,4");
  a := 100H;  r := SYSTEM.LSR(a, 8); Test.AssertLong(1,        r, "LSR 100,8");
  a := 0A0H;  r := SYSTEM.LSR(a, 5); Test.AssertLong(5,        r, "LSR A0,5");
  a := -2;    r := SYSTEM.LSR(a, 1); Test.AssertLong(LgMaxLong,  r, "LSR -2,1");
  a := LgMinLong; r := SYSTEM.LSR(a, 1); Test.AssertLong(40000000H, r, "LSR Min,1")
END LgTShiftLSR;

PROCEDURE LgTShiftASR*;
VAR a, r: LONGINT;
BEGIN
  a := 2;     r := SYSTEM.ASR(a, 1); Test.AssertLong(1,    r, "ASR 2,1");
  a := 12;    r := SYSTEM.ASR(a, 2); Test.AssertLong(3,    r, "ASR 12,2");
  a := 0FF0H; r := SYSTEM.ASR(a, 4); Test.AssertLong(0FFH, r, "ASR FF0,4");
  a := 100H;  r := SYSTEM.ASR(a, 8); Test.AssertLong(1,    r, "ASR 100,8");
  a := 0A0H;  r := SYSTEM.ASR(a, 5); Test.AssertLong(5,    r, "ASR A0,5");
  a := -2;    r := SYSTEM.ASR(a, 1); Test.AssertLong(-1,   r, "ASR -2,1");
  a := -4;    r := SYSTEM.ASR(a, 1); Test.AssertLong(-2,   r, "ASR -4,1");
  a := -16;   r := SYSTEM.ASR(a, 2); Test.AssertLong(-4,   r, "ASR -16,2");
  a := -1;    r := SYSTEM.ASR(a, 5); Test.AssertLong(-1,   r, "ASR -1,5");
  a := LgMinLong; r := SYSTEM.ASR(a, 1); Test.AssertLong(-40000000H, r, "ASR Min,1")
END LgTShiftASR;

PROCEDURE LgTShiftROR*;
VAR a, r: LONGINT;
BEGIN
  a := 1;   r := SYSTEM.ROR(a, 1); Test.AssertLong(LgMinLong,    r, "ROR 1,1");
  a := 2;   r := SYSTEM.ROR(a, 1); Test.AssertLong(1,          r, "ROR 2,1");
  a := 4;   r := SYSTEM.ROR(a, 1); Test.AssertLong(2,          r, "ROR 4,1");
  a := 8;   r := SYSTEM.ROR(a, 1); Test.AssertLong(4,          r, "ROR 8,1");
  a := 40000000H; r := SYSTEM.ROR(a, 1); Test.AssertLong(20000000H, r, "ROR 4..,1");
  a := 1;   r := SYSTEM.ROR(a, 2); Test.AssertLong(40000000H,  r, "ROR 1,2");
  a := 3;   r := SYSTEM.ROR(a, 1); Test.AssertLong(LgMinLong + 1,r, "ROR 3,1")
END LgTShiftROR;

PROCEDURE LgTShiftCombinations*;
VAR a, r: LONGINT;
BEGIN
  a := 1;        r := SYSTEM.LSL(a, 3); r := SYSTEM.LSR(r, 1); Test.AssertLong(4,    r, "1<<3 >>1");
  a := 100;      r := SYSTEM.LSL(a, 2); r := SYSTEM.ASR(r, 1); Test.AssertLong(200,  r, "100<<2 ASR 1");
  a := -100;     r := SYSTEM.ASR(a, 2); r := SYSTEM.LSL(r, 1); Test.AssertLong(-50,  r, "-100 ASR2 <<1");
  a := 1;        r := SYSTEM.ROR(a, 1); r := SYSTEM.LSL(r, 1); Test.AssertLong(0,    r, "ROR<<");
  a := 0FFH;     r := SYSTEM.LSL(a, 8); r := SYSTEM.LSR(r, 8); Test.AssertLong(0FFH, r, "FF<<8>>8");
  a := 75BCD15H; r := SYSTEM.LSL(a, 4); r := SYSTEM.LSR(r, 4); Test.AssertLong(75BCD15H, r, "round-trip")
END LgTShiftCombinations;

PROCEDURE LgTShiftWithVariables*;
VAR value, shift, r: LONGINT;
BEGIN
  value := 1;       shift := 5;  r := SYSTEM.LSL(value, shift); Test.AssertLong(20H,         r, "1<<5");
  value := 80H;     shift := 3;  r := SYSTEM.LSR(value, shift); Test.AssertLong(10H,         r, "80>>3");
  value := -40H;    shift := 2;  r := SYSTEM.ASR(value, shift); Test.AssertLong(-10H,        r, "-40 ASR2");
  value := 1;       shift := 31; r := SYSTEM.LSL(value, shift); Test.AssertLong(LgMinLong,     r, "1<<31");
  value := LgMinLong; shift := 1;  r := SYSTEM.LSR(value, shift); Test.AssertLong(40000000H,   r, "Min>>1")
END LgTShiftWithVariables;

PROCEDURE LgTShiftBoundaries*;
VAR a, r: LONGINT;
BEGIN
  a := 75BCD15H;
  r := SYSTEM.LSL(a, 0); Test.AssertLong(75BCD15H, r, "LSL 0");
  r := SYSTEM.LSR(a, 0); Test.AssertLong(75BCD15H, r, "LSR 0");
  r := SYSTEM.ASR(a, 0); Test.AssertLong(75BCD15H, r, "ASR 0");
  r := SYSTEM.ROR(a, 0); Test.AssertLong(75BCD15H, r, "ROR 0");
  a := 1;  r := SYSTEM.LSL(a, 31); Test.AssertLong(LgMinLong, r, "1<<31");
  a := 1;  r := SYSTEM.LSL(a, 32); Test.AssertLong(1,       r, "1<<32 wraps");
  a := -1; r := SYSTEM.LSR(a, 1);  Test.AssertLong(LgMaxLong, r, "-1>>1");
  a := -1; r := SYSTEM.ASR(a, 32); Test.AssertLong(-1,      r, "-1 ASR32");
  a := 1;  r := SYSTEM.ROR(a, 32); Test.AssertLong(1,       r, "1 ROR32")
END LgTShiftBoundaries;

PROCEDURE LgTBooleanOperations*;
VAR a, b, c: BOOLEAN; x, y, z: LONGINT;
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
  c := (a & ~b) OR (~a & b);
  Test.AssertTrue(c, "xor T,F");
  x := 10; y := 20; z := 0;
  IF (x < y) & (x > 0) THEN z := 100 END;
  Test.AssertLong(100, z, "combined cond")
END LgTBooleanOperations;

PROCEDURE LgTBooleanComparisons*;
VAR a, b, c: LONGINT;
BEGIN
  a := 10; b := 20; c := 10;
  Test.AssertTrue(a = c,   "a=c");
  Test.AssertFalse(a = b,  "a=b false");
  Test.AssertTrue(a # b,   "a#b");
  Test.AssertTrue(a < b,   "a<b");
  Test.AssertFalse(b < a,  "b<a false");
  Test.AssertTrue(a <= c,  "a<=c");
  Test.AssertTrue(b > a,   "b>a")
END LgTBooleanComparisons;

PROCEDURE LgTStaticArray*;
VAR arr: LgLongArray10; i: INTEGER; sum: LONGINT;
BEGIN
  FOR i := 0 TO 9 DO arr[i] := i * i END;
  Test.AssertLong(0,  arr[0], "arr[0]");
  Test.AssertLong(25, arr[5], "arr[5]");
  Test.AssertLong(81, arr[9], "arr[9]");
  sum := 0;
  FOR i := 0 TO 9 DO sum := sum + arr[i] END;
  Test.AssertLong(285, sum, "sum 0..9 squared")
END LgTStaticArray;

PROCEDURE LgTArrayIndexing*;
VAR arr: LgLongArray100; i: INTEGER;
BEGIN
  FOR i := 0 TO 99 DO arr[i] := LONGINT(i) * 1000 END;
  Test.AssertLong(61A8H,  arr[25], "arr[25]");
  Test.AssertLong(0C350H, arr[50], "arr[50]");
  Test.AssertLong(182B8H, arr[99], "arr[99]")
END LgTArrayIndexing;

PROCEDURE LgTRecordAccess*;
VAR p: LgPoint; r: LgRectangle;
BEGIN
  p.x := 186A0H; p.y := 30D40H;
  Test.AssertLong(186A0H, p.x, "p.x");
  Test.AssertLong(30D40H, p.y, "p.y");
  r.topLeft.x := 2710H;
  r.topLeft.y := 4E20H;
  r.bottomRight.x := 186A0H;
  r.bottomRight.y := 30D40H;
  Test.AssertLong(2710H,  r.topLeft.x,     "tl.x");
  Test.AssertLong(4E20H,  r.topLeft.y,     "tl.y");
  Test.AssertLong(186A0H, r.bottomRight.x, "br.x");
  Test.AssertLong(30D40H, r.bottomRight.y, "br.y");
  r.topLeft.x := r.bottomRight.x - r.topLeft.x;
  Test.AssertLong(15F90H, r.topLeft.x, "br.x - tl.x")
END LgTRecordAccess;

PROCEDURE LgTRecordAlignment*;
VAR m: LgMixed;
BEGIN
  m.a := 1X; m.b := 0F4240H; m.c := 2X; m.d := 1E8480H;
  Test.AssertTrue(m.a = 1X,           "m.a=1X");
  Test.AssertLong(0F4240H, m.b,        "m.b");
  Test.AssertTrue(m.c = 2X,           "m.c=2X");
  Test.AssertLong(1E8480H, m.d,        "m.d")
END LgTRecordAlignment;

PROCEDURE LgTHeapAllocation*;
VAR p: LgLongRecord; q: LgDataBlock; i: INTEGER; sum: LONGINT;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "NEW p");
  p^.a := 67932H; p^.b := -1; p^.c := LgMaxLong;
  Test.AssertLong(67932H,   p^.a, "p^.a");
  Test.AssertLong(-1,       p^.b, "p^.b");
  Test.AssertLong(LgMaxLong,  p^.c, "p^.c");
  DISPOSE(p);
  NEW(q);
  Test.AssertNotNil(q, "NEW q");
  FOR i := 0 TO 99 DO q^[i] := LONGINT(i) * 1000 END;
  sum := 0;
  FOR i := 0 TO 99 DO sum := sum + q^[i] END;
  Test.AssertLong(4B87F0H, sum, "sum heap array");
  DISPOSE(q)
END LgTHeapAllocation;

PROCEDURE LgTHeapMultiple*;
VAR p1, p2, p3: LgLongRecord;
BEGIN
  NEW(p1); NEW(p2); NEW(p3);
  Test.AssertNotNil(p1, "NEW p1");
  Test.AssertNotNil(p2, "NEW p2");
  Test.AssertNotNil(p3, "NEW p3");
  p1^.a := 1;   p1^.b := 2;   p1^.c := 3;
  p2^.a := 10;  p2^.b := 20;  p2^.c := 30;
  p3^.a := 100; p3^.b := 200; p3^.c := 300;
  Test.AssertLong(111, p1^.a + p2^.a + p3^.a, "sum a");
  Test.AssertLong(222, p1^.b + p2^.b + p3^.b, "sum b");
  Test.AssertLong(333, p1^.c + p2^.c + p3^.c, "sum c");
  DISPOSE(p1); DISPOSE(p2); DISPOSE(p3)
END LgTHeapMultiple;

PROCEDURE BoTAndInt*;
VAR a, b, r: INTEGER;
BEGIN
  a := 0FFH;   b := 0F0H;   r := SYSTEM.AND(a, b); Test.AssertInt(0F0H, r,   "AND 0FFH,0F0H");
  a := 55H;    b := 0AAH;   r := SYSTEM.AND(a, b); Test.AssertInt(0,    r,   "AND 55H,0AAH");
  a := 0FFFFH; b := 1234H;  r := SYSTEM.AND(a, b); Test.AssertInt(1234H,r,   "AND -1,1234H");
  a := 0;      b := 0FFFFH; r := SYSTEM.AND(a, b); Test.AssertInt(0,    r,   "AND 0,-1")
END BoTAndInt;

PROCEDURE BoTIorInt*;
VAR a, b, r: INTEGER;
BEGIN
  a := 0F0H;   b := 0FH;    r := SYSTEM.IOR(a, b); Test.AssertInt(0FFH,  r, "IOR 0F0H,0FH");
  a := 55H;    b := 0AAH;   r := SYSTEM.IOR(a, b); Test.AssertInt(0FFH,  r, "IOR 55H,0AAH");
  a := 0;      b := 1234H;  r := SYSTEM.IOR(a, b); Test.AssertInt(1234H, r, "IOR 0,1234H");
  a := 0FFFFH; b := 0;      r := SYSTEM.IOR(a, b); Test.AssertInt(0FFFFH,r, "IOR -1,0")
END BoTIorInt;

PROCEDURE BoTXorInt*;
VAR a, b, r: INTEGER;
BEGIN
  a := 0FFH;   b := 0F0H;   r := SYSTEM.XOR(a, b); Test.AssertInt(0FH,  r, "XOR 0FFH,0F0H");
  a := 0FFFFH; b := 0FFFFH; r := SYSTEM.XOR(a, b); Test.AssertInt(0,    r, "XOR -1,-1");
  a := 0;      b := 5A5AH;  r := SYSTEM.XOR(a, b); Test.AssertInt(5A5AH,r, "XOR 0,5A5AH");
  a := 55H;    b := 0AAH;   r := SYSTEM.XOR(a, b); Test.AssertInt(0FFH, r, "XOR 55H,0AAH")
END BoTXorInt;

PROCEDURE BoTAndByte*;
VAR a, b: BYTE; r: INTEGER;
BEGIN
  a := BYTE(0FFH); b := BYTE(0F0H); r := SYSTEM.AND(a, b); Test.AssertInt(0F0H, r, "AND BYTE 0FFH,0F0H");
  a := BYTE(55H);  b := BYTE(0AAH); r := SYSTEM.AND(a, b); Test.AssertInt(0,    r, "AND BYTE 55H,0AAH")
END BoTAndByte;

PROCEDURE BoTIorByte*;
VAR a, b: BYTE; r: INTEGER;
BEGIN
  a := BYTE(0F0H); b := BYTE(0FH);  r := SYSTEM.IOR(a, b); Test.AssertInt(0FFH, r, "IOR BYTE 0F0H,0FH");
  a := BYTE(55H);  b := BYTE(0AAH); r := SYSTEM.IOR(a, b); Test.AssertInt(0FFH, r, "IOR BYTE 55H,0AAH")
END BoTIorByte;

PROCEDURE BoTXorByte*;
VAR a, b: BYTE; r: INTEGER;
BEGIN
  a := BYTE(0FFH); b := BYTE(0F0H); r := SYSTEM.XOR(a, b); Test.AssertInt(0FH, r, "XOR BYTE 0FFH,0F0H");
  a := BYTE(0AAH); b := BYTE(0AAH); r := SYSTEM.XOR(a, b); Test.AssertInt(0,   r, "XOR BYTE 0AAH,0AAH")
END BoTXorByte;

PROCEDURE BoTAndLong*;
VAR a, b, r: LONGINT;
BEGIN
  a := LONGINT(0FFFF00FFH); b := LONGINT(0FFFF0F0FH);
  r := SYSTEM.AND(a, b); Test.AssertLong(LONGINT(0FFFF000FH), r, "AND LONGINT 1");
  a := LONGINT(7FFFFFFFH); b := LONGINT(80000000H);
  r := SYSTEM.AND(a, b); Test.AssertLong(LONGINT(0),           r, "AND LONGINT 2");
  a := LONGINT(-1);        b := LONGINT(12345678H);
  r := SYSTEM.AND(a, b); Test.AssertLong(LONGINT(12345678H),   r, "AND LONGINT 3")
END BoTAndLong;

PROCEDURE BoTIorLong*;
VAR a, b, r: LONGINT;
BEGIN
  a := LONGINT(7FFFFFFFH); b := LONGINT(80000000H);
  r := SYSTEM.IOR(a, b); Test.AssertLong(LONGINT(-1),         r, "IOR LONGINT 1");
  a := LONGINT(0);         b := LONGINT(12345678H);
  r := SYSTEM.IOR(a, b); Test.AssertLong(LONGINT(12345678H),  r, "IOR LONGINT 2");
  a := LONGINT(0F0F0F0F0H); b := LONGINT(0F0F0F0FH);
  r := SYSTEM.IOR(a, b); Test.AssertLong(LONGINT(-1),         r, "IOR LONGINT 3")
END BoTIorLong;

PROCEDURE BoTXorLong*;
VAR a, b, r: LONGINT;
BEGIN
  a := LONGINT(-1); b := LONGINT(-1);
  r := SYSTEM.XOR(a, b); Test.AssertLong(LONGINT(0),          r, "XOR LONGINT 1");
  a := LONGINT(0);  b := LONGINT(12345678H);
  r := SYSTEM.XOR(a, b); Test.AssertLong(LONGINT(12345678H),  r, "XOR LONGINT 2");
  a := LONGINT(0AAAAAAAH); b := LONGINT(55555555H);
  r := SYSTEM.XOR(a, b); Test.AssertLong(LONGINT(5FFFFFFFH),  r, "XOR LONGINT 3")
END BoTXorLong;

PROCEDURE BoTAndConst*;
VAR r: INTEGER;
BEGIN
  r := SYSTEM.AND(0FFFFH, 0F0F0H); Test.AssertInt(0F0F0H, r, "AND const 1");
  r := SYSTEM.AND(0ABH,   0FH);    Test.AssertInt(0BH,    r, "AND const 2")
END BoTAndConst;

PROCEDURE WdTCastHex*;
VAR w: WORD;
BEGIN
  w := WORD(0FFFFH);
  Test.AssertWord(WORD(65535), w, "WORD(0FFFFH)")
END WdTCastHex;

PROCEDURE WdTCastNeg*;
VAR w: WORD; i: INTEGER;
BEGIN
  i := -1; w := WORD(i);
  Test.AssertWord(WORD(65535), w, "WORD(-1)")
END WdTCastNeg;

PROCEDURE WdTAddWrap*;
VAR w: WORD;
BEGIN
  w := WORD(60000) + WORD(10000);
  Test.AssertWord(WORD(4464), w, "60000+10000")
END WdTAddWrap;

PROCEDURE WdTMul*;
VAR w: WORD;
BEGIN
  w := WORD(200) * WORD(300);
  Test.AssertWord(WORD(60000), w, "200*300")
END WdTMul;

PROCEDURE WdTDiv*;
VAR w: WORD;
BEGIN
  w := WORD(50000) DIV WORD(100);
  Test.AssertWord(WORD(500), w, "50000 DIV 100")
END WdTDiv;

PROCEDURE WdTMod*;
VAR w: WORD;
BEGIN
  w := WORD(50007) MOD WORD(100);
  Test.AssertWord(WORD(7), w, "50007 MOD 100")
END WdTMod;

PROCEDURE WdTCmpUnsigned*;
BEGIN
  Test.AssertTrue(WORD(60000) > WORD(1000), "60000 > 1000")
END WdTCmpUnsigned;

PROCEDURE WdTCmpNegCast*;
VAR w: WORD;
BEGIN
  w := WORD(-1);
  Test.AssertTrue(w > WORD(1000), "WORD(-1) > 1000")
END WdTCmpNegCast;

PROCEDURE WdTMixedAdd*;
VAR w: WORD;
BEGIN
  w := WORD(100) + 50;
  Test.AssertWord(WORD(150), w, "WORD(100)+50")
END WdTMixedAdd;

PROCEDURE WdTFromByte*;
VAR w: WORD; b: BYTE;
BEGIN
  b := 200; w := WORD(b);
  Test.AssertWord(WORD(200), w, "WORD(BYTE 200)")
END WdTFromByte;

PROCEDURE WdTZero*;
VAR w: WORD;
BEGIN
  w := WORD(0);
  Test.AssertWord(WORD(0), w, "WORD(0)")
END WdTZero;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TyTestIntegerArithmetic, "Ty/intArith");
  Test.AddTest(TyTestIntegerBoundaries, "Ty/intBound");
  Test.AddTest(TyTestIntegerAssignment, "Ty/intAssign");
  Test.AddTest(TyTestShiftLSL, "Ty/lsl");
  Test.AddTest(TyTestShiftLSR, "Ty/lsr");
  Test.AddTest(TyTestShiftASR, "Ty/asr");
  Test.AddTest(TyTestShiftROR, "Ty/ror");
  Test.AddTest(TyTestShiftCombinations, "Ty/shiftCombo");
  Test.AddTest(TyTestShiftWithVariables, "Ty/shiftVar");
  Test.AddTest(TyTestShiftBoundaries, "Ty/shiftBound");
  Test.AddTest(TyTestBooleanOperations, "Ty/boolOps");
  Test.AddTest(TyTestBoolNot, "Ty/boolNot");
  Test.AddTest(TyTestBooleanComparisons, "Ty/boolCmp");
  Test.AddTest(TyTestStaticArray, "Ty/staticArr");
  Test.AddTest(TyTestArrayIndexing, "Ty/arrayIdx");
  Test.AddTest(TyTestRecordAccess, "Ty/recAccess");
  Test.AddTest(TyTestRecordAlignment, "Ty/recAlign");
  Test.AddTest(TyTestHeapAllocation, "Ty/heap");
  Test.AddTest(TyTestHeapMultiAlloc, "Ty/heapMulti");
  Test.AddTest(TyTestFarPointers, "Ty/farPtr");
  Test.AddTest(LiTBasicArith, "Li/basicArith");
  Test.AddTest(LiTMultiply, "Li/multiply");
  Test.AddTest(LiTDivMod, "Li/divMod");
  Test.AddTest(LiTNegate, "Li/negate");
  Test.AddTest(LiTCompare, "Li/compare");
  Test.AddTest(LiTCastToLong, "Li/castToLong");
  Test.AddTest(LiTCastToInt, "Li/castToInt");
  Test.AddTest(LiTVarParam, "Li/varParam");
  Test.AddTest(LiTLoop, "Li/loop");
  Test.AddTest(LiTNegMul, "Li/negMul");
  Test.AddTest(LiTBoolOps, "Li/boolOps");
  Test.AddTest(LiTLSL, "Li/lsl");
  Test.AddTest(LiTLSR, "Li/lsr");
  Test.AddTest(LiTASR, "Li/asr");
  Test.AddTest(LiTROR, "Li/ror");
  Test.AddTest(LgTLongArithmetic, "Lg/arithmetic");
  Test.AddTest(LgTLongBoundaries, "Lg/boundaries");
  Test.AddTest(LgTLongAssignment, "Lg/assignment");
  Test.AddTest(LgTIncDecStep, "Lg/incDecStep");
  Test.AddTest(LgTShiftLSL, "Lg/lsl");
  Test.AddTest(LgTShiftLSR, "Lg/lsr");
  Test.AddTest(LgTShiftASR, "Lg/asr");
  Test.AddTest(LgTShiftROR, "Lg/ror");
  Test.AddTest(LgTShiftCombinations, "Lg/shiftCombos");
  Test.AddTest(LgTShiftWithVariables, "Lg/shiftVars");
  Test.AddTest(LgTShiftBoundaries, "Lg/shiftBoundaries");
  Test.AddTest(LgTBooleanOperations, "Lg/boolOps");
  Test.AddTest(LgTBooleanComparisons, "Lg/boolCompares");
  Test.AddTest(LgTStaticArray, "Lg/staticArray");
  Test.AddTest(LgTArrayIndexing, "Lg/arrayIndexing");
  Test.AddTest(LgTRecordAccess, "Lg/recordAccess");
  Test.AddTest(LgTRecordAlignment, "Lg/recordAlignment");
  Test.AddTest(LgTHeapAllocation, "Lg/heapAlloc");
  Test.AddTest(LgTHeapMultiple, "Lg/heapMultiple");
  Test.AddTest(BoTAndInt, "Bo/and-int");
  Test.AddTest(BoTIorInt, "Bo/ior-int");
  Test.AddTest(BoTXorInt, "Bo/xor-int");
  Test.AddTest(BoTAndByte, "Bo/and-byte");
  Test.AddTest(BoTIorByte, "Bo/ior-byte");
  Test.AddTest(BoTXorByte, "Bo/xor-byte");
  Test.AddTest(BoTAndLong, "Bo/and-long");
  Test.AddTest(BoTIorLong, "Bo/ior-long");
  Test.AddTest(BoTXorLong, "Bo/xor-long");
  Test.AddTest(BoTAndConst, "Bo/and-const");
  Test.AddTest(WdTCastHex, "Wd/castHex");
  Test.AddTest(WdTCastNeg, "Wd/castNeg");
  Test.AddTest(WdTAddWrap, "Wd/addWrap");
  Test.AddTest(WdTMul, "Wd/mul");
  Test.AddTest(WdTDiv, "Wd/div");
  Test.AddTest(WdTMod, "Wd/mod");
  Test.AddTest(WdTCmpUnsigned, "Wd/cmpUns");
  Test.AddTest(WdTCmpNegCast, "Wd/cmpNeg");
  Test.AddTest(WdTMixedAdd, "Wd/mixedAdd");
  Test.AddTest(WdTFromByte, "Wd/fromByte");
  Test.AddTest(WdTZero, "Wd/zero");
  Test.RunTests
END RunAllTests;

END NUM.
