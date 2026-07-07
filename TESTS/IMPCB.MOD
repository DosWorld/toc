MODULE IMPCB;
IMPORT I := IMPCA, Test;

CONST
  C = I.N + 1;
  D = I.N;
  E = D * 2;

PROCEDURE TConsts*;
VAR x: INTEGER;
    arr: ARRAY I.N OF INTEGER;
    arr2: ARRAY D, E OF INTEGER;
BEGIN
  x := 0;
  CASE I.N OF
    1: x := 1
  | 2: x := 2
  | D-1: x := 3
  | I.N: x := 4
  ELSE x := 99
  END;
  Test.AssertInt(4,   x,                "CASE I.N");
  Test.AssertInt(5,   C,                "C=5");
  arr2[D-1][E-1] := 123;
  Test.AssertInt(123, arr2[D-1][E-1],   "arr2[D-1][E-1]");
  Test.AssertInt(4,   D,                "D=4");
  Test.AssertInt(8,   E,                "E=8");
  arr[I.N-1] := 7;
  Test.AssertInt(7,   arr[I.N-1],   "arr[I.N-1]")
END TConsts;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TConsts, "ImportConst/consts");
  Test.RunTests
END RunAllTests;

END IMPCB.
