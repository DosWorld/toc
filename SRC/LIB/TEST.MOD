(*$D-*)
MODULE Test;

IMPORT Out := Out87, Math;

CONST
MaxTests = 128;

TYPE
(* All registered tests live in OTHER modules — must be FAR-callable.
   The FAR modifier is explicit (matches the language default but documents
   the cross-module calling-convention requirement). *)

TestProc* = PROCEDURE;

VAR
    failureCount: INTEGER;
    tests: ARRAY MaxTests OF TestProc;
    testsNames : ARRAY MaxTests OF WORD;
    names : ARRAY 4096 OF CHAR;
    namesPtr : WORD;
    numTests: INTEGER;
    testName : POINTER TO CHAR;

PROCEDURE StrEq(a, b: ARRAY OF CHAR): BOOLEAN;
VAR i, len: INTEGER;
BEGIN
  i := 0;
  len := SYSTEM.MIN(LEN(a), LEN(b));
  WHILE (i < len) & (a[i] = b[i]) & (a[i] # 0X) DO
    INC(i)
  END;
  RETURN a[i] = b[i]
END StrEq;

PROCEDURE OutTestName;
VAR
    tn : POINTER TO CHAR;
BEGIN
      tn := testName;
      WHILE tn^ # 0X DO
         Out.Char(tn^);
         tn := SYSTEM.PTR(SYSTEM.SEG(tn^), SYSTEM.OFS(tn^) + 1)
      END
END OutTestName;

PROCEDURE Fail(msg: ARRAY OF CHAR);
BEGIN
    OutTestName;
    Out.String(" FAIL: "); Out.String(msg); Out.Ln;
    INC(failureCount)
END Fail;

(* AssertTrue: record a test failure for the current test if cond is FALSE.
   Parameters: cond — condition expected to be TRUE; msg — message reported
   on failure. *)
PROCEDURE AssertTrue*(cond: BOOLEAN; msg: ARRAY OF CHAR);
BEGIN
    IF ~cond THEN Fail(msg) END
END AssertTrue;

(* AssertFalse: record a test failure for the current test if cond is TRUE.
   Parameters: cond — condition expected to be FALSE; msg — message reported
   on failure. *)
PROCEDURE AssertFalse*(cond: BOOLEAN; msg: ARRAY OF CHAR);
BEGIN
    IF cond THEN Fail(msg) END
END AssertFalse;

(* AssertNil: record a test failure for the current test if p is not NIL.
   Parameters: p — pointer expected to be NIL; msg — message reported on
   failure. *)
PROCEDURE AssertNil*(p : SYSTEM.ADDRESS; msg: ARRAY OF CHAR);
BEGIN
    IF p # NIL THEN
      OutTestName;
      Out.String(" Expected NIL");
      Out.String(", got "); Out.Adr(p);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertNil;

(* AssertNotNil: record a test failure for the current test if p is NIL.
   Parameters: p — pointer expected to be non-NIL; msg — message reported on
   failure. *)
PROCEDURE AssertNotNil*(p : SYSTEM.ADDRESS; msg: ARRAY OF CHAR);
BEGIN
    IF p = NIL THEN
      OutTestName;
      Out.String(" Expected not NIL");
      Out.String(", got "); Out.Adr(p);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertNotNil;

(* AssertByte: record a test failure for the current test if expected and
   actual differ.
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertByte*(expected, actual: BYTE; msg: ARRAY OF CHAR);
BEGIN
    IF expected # actual THEN
      OutTestName;
      Out.String(" Expected "); Out.Int(expected, 0);
      Out.String(", got "); Out.Int(actual, 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertByte;

(* AssertInt: record a test failure for the current test if expected and
   actual differ.
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertInt*(expected, actual: INTEGER; msg: ARRAY OF CHAR);
BEGIN
    IF expected # actual THEN
      OutTestName;
      Out.String(" Expected "); Out.Int(expected, 0);
      Out.String(", got "); Out.Int(actual, 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertInt;

(* AssertWord: record a test failure for the current test if expected and
   actual differ.
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertWord*(expected, actual: WORD; msg: ARRAY OF CHAR);
BEGIN
    IF expected # actual THEN
      OutTestName;
      Out.String(" Expected "); Out.Int(LONGINT(expected), 0);
      Out.String(", got "); Out.Int(LONGINT(actual), 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertWord;

(* AssertLong: record a test failure for the current test if expected and
   actual differ.
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertLong*(expected, actual: LONGINT; msg: ARRAY OF CHAR);
BEGIN
    IF expected # actual THEN
      OutTestName;
      Out.String(" Expected "); Out.Int(expected, 0);
      Out.String(", got "); Out.Int(actual, 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertLong;

(* AssertReal: record a test failure for the current test if expected and
   actual differ by more than a small epsilon (1.0E-6).
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertReal*(expected, actual: REAL; msg: ARRAY OF CHAR);
BEGIN
    IF Math.Abs(expected - actual) > 1.0E-6 THEN
      OutTestName;
      Out.String(" Expected "); Out.Real(expected, 0);
      Out.String(", got "); Out.Real(actual, 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertReal;

(* AssertLongReal: record a test failure for the current test if expected and
   actual differ by more than a small epsilon (1.0E-6).
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertLongReal*(expected, actual: LONGREAL; msg: ARRAY OF CHAR);
  VAR diff: LONGREAL;
BEGIN
    diff := expected - actual;
    IF diff < LONGREAL(0.0) THEN diff := -diff END;
    IF diff > LONGREAL(1.0E-6) THEN
      OutTestName;
      Out.String(" Expected "); Out.LongReal(expected, 0);
      Out.String(", got "); Out.LongReal(actual, 0);
      Out.String(" : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertLongReal;

(* AssertStr: record a test failure for the current test if expected and
   actual differ as strings.
   Parameters: expected — value the test expects; actual — value produced by
   the code under test; msg — message reported on failure. *)
PROCEDURE AssertStr*(expected, actual: ARRAY OF CHAR; msg: ARRAY OF CHAR);
BEGIN
    IF ~StrEq(expected, actual) THEN
      OutTestName;
      Out.String(" Expected '"); Out.String(expected);
      Out.String("', got '"); Out.String(actual);
      Out.String("' : "); Out.String(msg); Out.Ln;
      INC(failureCount)
    END
END AssertStr;

(* AddTest: register a test procedure to be run by RunTests.
   Parameters: t — FAR-callable test procedure to register; name — display
   name for the test (truncated to 24 characters). *)
PROCEDURE AddTest*(t: TestProc; name : ARRAY OF CHAR);
VAR i : WORD;
BEGIN
    IF numTests < MaxTests THEN
      tests[numTests] := t;
      testsNames[numTests] := namesPtr;
      i := 0;
      WHILE (name[i] # 0X) & (i < 24) DO
          names[namesPtr] := name[i];
          INC(namesPtr);
          INC(i)
      END;
      names[namesPtr] := 0X;
      INC(namesPtr);
      INC(numTests)
    ELSE
      Out.String("Tests: Too many tests (max "); Out.Int(MaxTests, 0);
      Out.String(")"); Out.Ln
    END
END AddTest;

(* RunTests: run every test registered via AddTest, printing a PASSED/FAIL
   line per test and a summary, then halt the process with exit code 0 if
   all tests passed or 1 otherwise. *)
PROCEDURE RunTests*;
VAR i, total, passed : INTEGER;
BEGIN
    total := 0; passed := 0;
    Out.String("--------------------------------------"); Out.Ln;
    Out.String("Run "); Out.Int(numTests, 0); Out.String(" test(s):"); Out.Ln;
    FOR i := 0 TO numTests-1 DO
      failureCount := 0;
      testName := SYSTEM.ADR(names[testsNames[i]]);
      tests[i]();
      IF failureCount = 0 THEN
        OutTestName; Out.String(" PASSED"); Out.Ln;
        INC(passed)
      END;
      INC(total)
    END;
    Out.String("--------------------------------------"); Out.Ln;
    Out.String("Total: "); Out.Int(total, 0); Out.Ln;
    Out.String("Passed: "); Out.Int(passed, 0); Out.Ln;
    (* `Failed: N` on its own line — test_src.sh greps `^Failed:` to decide
       pass/fail and to report the count. *)
    Out.String("Failed: "); Out.Int(total - passed, 0); Out.Ln;
    IF total = passed THEN
      SYSTEM.Halt(0)
    ELSE
      SYSTEM.Halt(1)
    END
END RunTests;

BEGIN
  namesPtr := 0;
  numTests := 0
END Test.
