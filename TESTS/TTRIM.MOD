MODULE TTRIM;
(* Regression test for Strings.LTrim/RTrim/Trim.
   Covers: leading-only, trailing-only, both-sides, all-whitespace (collapses
   to empty), no-whitespace (untouched), empty-string (no-op), and a mix of
   space + control-character whitespace (SYSTEM.ISSPACE accepts ORD 1..32). *)

IMPORT Test, Strings;

PROCEDURE CheckLTrim(in, want: ARRAY OF CHAR; msg: ARRAY OF CHAR);
  VAR s: ARRAY 32 OF CHAR;
BEGIN
  Strings.Copy(in, s);
  Strings.LTrim(s);
  Test.AssertTrue(Strings.Equal(s, want), msg)
END CheckLTrim;

PROCEDURE CheckRTrim(in, want: ARRAY OF CHAR; msg: ARRAY OF CHAR);
  VAR s: ARRAY 32 OF CHAR;
BEGIN
  Strings.Copy(in, s);
  Strings.RTrim(s);
  Test.AssertTrue(Strings.Equal(s, want), msg)
END CheckRTrim;

PROCEDURE CheckTrim(in, want: ARRAY OF CHAR; msg: ARRAY OF CHAR);
  VAR s: ARRAY 32 OF CHAR;
BEGIN
  Strings.Copy(in, s);
  Strings.Trim(s);
  Test.AssertTrue(Strings.Equal(s, want), msg)
END CheckTrim;

PROCEDURE TLTrim*;
BEGIN
  CheckLTrim("  hello", "hello", "LTrim leading spaces");
  CheckLTrim("hello", "hello", "LTrim no leading whitespace");
  CheckLTrim("hello  ", "hello  ", "LTrim leaves trailing spaces");
  CheckLTrim("   ", "", "LTrim all-whitespace collapses to empty");
  CheckLTrim("", "", "LTrim empty string is no-op");
  CheckLTrim(" a", "a", "LTrim single leading space")
END TLTrim;

PROCEDURE TRTrim*;
BEGIN
  CheckRTrim("hello  ", "hello", "RTrim trailing spaces");
  CheckRTrim("hello", "hello", "RTrim no trailing whitespace");
  CheckRTrim("  hello", "  hello", "RTrim leaves leading spaces");
  CheckRTrim("   ", "", "RTrim all-whitespace collapses to empty");
  CheckRTrim("", "", "RTrim empty string is no-op");
  CheckRTrim("a ", "a", "RTrim single trailing space")
END TRTrim;

PROCEDURE TTrim*;
  VAR mixed: ARRAY 16 OF CHAR;
BEGIN
  CheckTrim("  hello  ", "hello", "Trim both sides");
  CheckTrim("hello", "hello", "Trim no whitespace");
  CheckTrim("   ", "", "Trim all-whitespace collapses to empty");
  CheckTrim("", "", "Trim empty string is no-op");
  CheckTrim("  a  b  ", "a  b", "Trim preserves internal whitespace");

  (* mix of space + control-char whitespace (ORD 1..32) on both ends; no
     string-concatenation operator exists in this dialect, so build it
     character by character instead. *)
  mixed[0] := 09X;  mixed[1] := 020X; mixed[2] := "m"; mixed[3] := "i";
  mixed[4] := "d";  mixed[5] := 00DX; mixed[6] := 00AX; mixed[7] := 0X;
  Strings.Trim(mixed);
  Test.AssertTrue(Strings.Equal(mixed, "mid"), "Trim mixed tab/space/CR/LF")
END TTrim;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TLTrim, "TTRIM/ltrim");
  Test.AddTest(TRTrim, "TTRIM/rtrim");
  Test.AddTest(TTrim,  "TTRIM/trim");
  Test.RunTests
END RunAllTests;

END TTRIM.
