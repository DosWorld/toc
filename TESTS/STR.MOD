MODULE STR;
IMPORT Test, Strings;

VAR
  Stgbuf: ARRAY 32 OF CHAR;
  Stgdst: ARRAY 16 OF CHAR;

PROCEDURE StTLength*;
BEGIN
  Test.AssertInt(0, Strings.Length(""),         "len ''");
  Test.AssertInt(1, Strings.Length("a"),        "len 'a'");
  Test.AssertInt(5, Strings.Length("hello"),    "len 'hello'");
  Test.AssertInt(7, Strings.Length("abcdefg"),  "len 'abcdefg'")
END StTLength;

PROCEDURE StTPos*;
  VAR p: WORD;
BEGIN
  p := 0; Test.AssertTrue(Strings.Pos("lo",  "hello", p) & (p = WORD(3)), "Pos lo");
  p := 0; Test.AssertTrue(Strings.Pos("he",  "hello", p) & (p = WORD(0)), "Pos he");
  p := 0; Test.AssertTrue(~Strings.Pos("xyz", "hello", p), "Pos xyz");
  p := 0; Test.AssertTrue(Strings.Pos("l",   "hello", p) & (p = WORD(2)), "Pos l@0");
  p := 3; Test.AssertTrue(Strings.Pos("l",   "hello", p) & (p = WORD(3)), "Pos l@3");
  p := 2; Test.AssertTrue(Strings.Pos("",    "hello", p) & (p = WORD(2)), "Pos empty");
  p := 0; Test.AssertTrue(Strings.Pos("llo", "hello", p) & (p = WORD(2)), "Pos llo")
END StTPos;

PROCEDURE StTAppend*;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  buf := "hello"; Strings.Append(" world", buf);
  Test.AssertStr("hello world", buf, "append 'world'");
  buf := "";      Strings.Append("abc", buf);
  Test.AssertStr("abc", buf, "append empty base");
  buf := "abc";   Strings.Append("", buf);
  Test.AssertStr("abc", buf, "append empty tail")
END StTAppend;

PROCEDURE StTInsert*;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  buf := "helo";  Strings.Insert("l", 2, buf);
  Test.AssertStr("hello", buf, "insert mid");
  buf := "world"; Strings.Insert("hello ", 0, buf);
  Test.AssertStr("hello world", buf, "insert prefix");
  buf := "hello"; Strings.Insert("!", 5, buf);
  Test.AssertStr("hello!", buf, "insert end")
END StTInsert;

PROCEDURE StTDelete*;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  buf := "hello world"; Strings.Delete(buf, 5, 6);
  Test.AssertStr("hello", buf, "delete tail");
  buf := "abcdef"; Strings.Delete(buf, 0, 3);
  Test.AssertStr("def", buf, "delete head");
  buf := "hello"; Strings.Delete(buf, 2, 0);
  Test.AssertStr("hello", buf, "delete zero")
END StTDelete;

PROCEDURE StTReplace*;
VAR buf: ARRAY 32 OF CHAR;
BEGIN
  buf := "hello world"; Strings.Replace("there", 6, buf);
  Test.AssertStr("hello there", buf, "replace tail");
  buf := "abcdef"; Strings.Replace("XY", 0, buf);
  Test.AssertStr("XYcdef", buf, "replace head")
END StTReplace;

PROCEDURE StTExtract*;
VAR dst: ARRAY 16 OF CHAR; src: ARRAY 16 OF CHAR;
BEGIN
  (* Extract takes src as VAR (an l-value), so string literals must first be
     copied into a local buffer -- they cannot be passed directly. *)
  src := "hello world"; Strings.Extract(src, 6, 5, dst);
  Test.AssertStr("world", dst, "extract world");
  src := "hello"; Strings.Extract(src, 0, 3, dst);
  Test.AssertStr("hel", dst, "extract head");
  src := "hello"; Strings.Extract(src, 0, 0, dst);
  Test.AssertStr("", dst, "extract zero");
  src := "hello"; Strings.Extract(src, 5, 3, dst);
  Test.AssertStr("", dst, "extract past end")
END StTExtract;

PROCEDURE StTAppendGlobal*;
BEGIN
  Stgbuf := "hello"; Strings.Append(" world", Stgbuf);
  Test.AssertStr("hello world", Stgbuf, "append global");
  Stgbuf := "";      Strings.Append("abc", Stgbuf);
  Test.AssertStr("abc", Stgbuf, "append empty global");
  Stgbuf := "abc";   Strings.Append("", Stgbuf);
  Test.AssertStr("abc", Stgbuf, "append empty tail global")
END StTAppendGlobal;

PROCEDURE StTInsertGlobal*;
BEGIN
  Stgbuf := "helo";  Strings.Insert("l", 2, Stgbuf);
  Test.AssertStr("hello", Stgbuf, "insert global mid");
  Stgbuf := "world"; Strings.Insert("hello ", 0, Stgbuf);
  Test.AssertStr("hello world", Stgbuf, "insert global prefix");
  Stgbuf := "hello"; Strings.Insert("!", 5, Stgbuf);
  Test.AssertStr("hello!", Stgbuf, "insert global end")
END StTInsertGlobal;

PROCEDURE StTDeleteGlobal*;
BEGIN
  Stgbuf := "hello world"; Strings.Delete(Stgbuf, 5, 6);
  Test.AssertStr("hello", Stgbuf, "delete global tail");
  Stgbuf := "abcdef"; Strings.Delete(Stgbuf, 0, 3);
  Test.AssertStr("def", Stgbuf, "delete global head");
  Stgbuf := "hello"; Strings.Delete(Stgbuf, 2, 0);
  Test.AssertStr("hello", Stgbuf, "delete global zero")
END StTDeleteGlobal;

PROCEDURE StTReplaceGlobal*;
BEGIN
  Stgbuf := "hello world"; Strings.Replace("there", 6, Stgbuf);
  Test.AssertStr("hello there", Stgbuf, "replace global tail");
  Stgbuf := "abcdef"; Strings.Replace("XY", 0, Stgbuf);
  Test.AssertStr("XYcdef", Stgbuf, "replace global head")
END StTReplaceGlobal;

PROCEDURE StTExtractGlobal*;
VAR src: ARRAY 16 OF CHAR;
BEGIN
  src := "hello world"; Strings.Extract(src, 6, 5, Stgdst);
  Test.AssertStr("world", Stgdst, "extract global world");
  src := "hello"; Strings.Extract(src, 0, 3, Stgdst);
  Test.AssertStr("hel", Stgdst, "extract global head");
  src := "hello"; Strings.Extract(src, 0, 0, Stgdst);
  Test.AssertStr("", Stgdst, "extract global zero");
  src := "hello"; Strings.Extract(src, 5, 3, Stgdst);
  Test.AssertStr("", Stgdst, "extract global past end")
END StTExtractGlobal;

PROCEDURE AsTAssertTrueCases*;
VAR x, y: INTEGER;
BEGIN
  ASSERT(TRUE);
  Test.AssertTrue(TRUE, "ASSERT(TRUE) continues");

  x := 5; y := 3;
  ASSERT(x > y);
  Test.AssertTrue(TRUE, "ASSERT(x>y) continues");

                                       
  ASSERT(x = 5, 99);
  Test.AssertTrue(TRUE, "ASSERT(x=5,99) continues");

  x := 42;
  ASSERT(x # 0);
  Test.AssertTrue(TRUE, "ASSERT(x#0) continues");

  x := 10; y := x * 2;
  ASSERT(y = 20);
  Test.AssertTrue(TRUE, "ASSERT(y=20) continues")
END AsTAssertTrueCases;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(StTLength, "St/length");
  Test.AddTest(StTPos, "St/pos");
  Test.AddTest(StTAppend, "St/append");
  Test.AddTest(StTInsert, "St/insert");
  Test.AddTest(StTDelete, "St/delete");
  Test.AddTest(StTReplace, "St/replace");
  Test.AddTest(StTExtract, "St/extract");
  Test.AddTest(StTAppendGlobal, "St/appendGlobal");
  Test.AddTest(StTInsertGlobal, "St/insertGlobal");
  Test.AddTest(StTDeleteGlobal, "St/deleteGlobal");
  Test.AddTest(StTReplaceGlobal, "St/replaceGlobal");
  Test.AddTest(StTExtractGlobal, "St/extractGlobal");
  Test.AddTest(AsTAssertTrueCases, "As/trueCases");
  Test.RunTests
END RunAllTests;

END STR.
