MODULE TSCAN;
(* Unit tests for Scan.
   Each test writes a small source to a temp file then opens a Scan.Scanner
   on it and asserts the recognised token/value. *)

IMPORT Test, Files, Scan;

VAR
  TmpFile: ARRAY 8 OF CHAR;

(* Helper: write `src` (zero-terminated) into TmpFile and Open a Scanner on it.
   Returns TRUE on success, FALSE if file write/open failed.  After Open the
   first token is already primed in s. *)
PROCEDURE setup(VAR s: Scan.Scanner; src: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File; i, n: INTEGER; ok: BOOLEAN; w: WORD;
BEGIN
  IF ~Files.ReWrite(f, TmpFile) THEN RETURN FALSE END;
  i := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) DO INC(i) END;
  n := i;
  IF n > 0 THEN
    w := Files.BlockWrite(f, src, WORD(n));
    IF INTEGER(w) # n THEN Files.Close(f); RETURN FALSE END
  END;
  Files.Close(f);
  Scan.Open(s, TmpFile);
  RETURN TRUE
END setup;

PROCEDURE teardown(VAR s: Scan.Scanner);
  VAR ok: BOOLEAN;
BEGIN
  Scan.Close(s);
  ok := Files.Delete(TmpFile)
END teardown;

(* ---- keywords ---- *)

PROCEDURE checkKw(src: ARRAY OF CHAR; expected: INTEGER; msg: ARRAY OF CHAR);
  VAR s: Scan.Scanner;
BEGIN
  Test.AssertTrue(setup(s, src), msg);
  Test.AssertInt(expected, s.sym, msg);
  teardown(s)
END checkKw;

PROCEDURE TKeywords*;
BEGIN
  checkKw("ARRAY",     Scan.TArray,     "kw/ARRAY");
  checkKw("BEGIN",     Scan.TBegin,     "kw/BEGIN");
  checkKw("BY",        Scan.TBy,        "kw/BY");
  checkKw("CASE",      Scan.TCase,      "kw/CASE");
  checkKw("CONST",     Scan.TConst,     "kw/CONST");
  checkKw("DIV",       Scan.TDiv,       "kw/DIV");
  checkKw("DO",        Scan.TDo,        "kw/DO");
  checkKw("ELSE",      Scan.TElse,      "kw/ELSE");
  checkKw("ELSIF",     Scan.TElsif,     "kw/ELSIF");
  checkKw("END",       Scan.TEnd,       "kw/END");
  checkKw("FALSE",     Scan.TFalse,     "kw/FALSE");
  checkKw("FOR",       Scan.TFor,       "kw/FOR");
  checkKw("IF",        Scan.TIf,        "kw/IF");
  checkKw("IMPORT",    Scan.TImport,    "kw/IMPORT");
  checkKw("IN",        Scan.TIn,        "kw/IN");
  checkKw("IS",        Scan.TIs,        "kw/IS");
  checkKw("MOD",       Scan.TMod,       "kw/MOD");
  checkKw("MODULE",    Scan.TModule,    "kw/MODULE");
  checkKw("NIL",       Scan.TNil,       "kw/NIL");
  checkKw("OF",        Scan.TOf,        "kw/OF");
  checkKw("OR",        Scan.TOr,        "kw/OR");
  checkKw("POINTER",   Scan.TPointer,   "kw/POINTER");
  checkKw("PROCEDURE", Scan.TProcedure, "kw/PROCEDURE");
  checkKw("RECORD",    Scan.TRecord,    "kw/RECORD");
  checkKw("REPEAT",    Scan.TRepeat,    "kw/REPEAT");
  checkKw("RETURN",    Scan.TReturn,    "kw/RETURN");
  checkKw("THEN",      Scan.TThen,      "kw/THEN");
  checkKw("TO",        Scan.TTo,        "kw/TO");
  checkKw("TRUE",      Scan.TTrue,      "kw/TRUE");
  checkKw("TYPE",      Scan.TType,      "kw/TYPE");
  checkKw("UNTIL",     Scan.TUntil,     "kw/UNTIL");
  checkKw("VAR",       Scan.TVar,       "kw/VAR");
  checkKw("WHILE",     Scan.TWhile,     "kw/WHILE")
END TKeywords;

(* ---- identifiers ---- *)

PROCEDURE TIdents*;
  VAR s: Scan.Scanner; len: INTEGER;
BEGIN
  Test.AssertTrue(setup(s, "hello"), "ident/simple setup");
  Test.AssertInt(Scan.TIdent, s.sym, "ident/simple tok");
  Test.AssertStr("hello", s.id, "ident/simple value");
  teardown(s);

  Test.AssertTrue(setup(s, "mixedCase123"), "ident/mixed setup");
  Test.AssertInt(Scan.TIdent, s.sym, "ident/mixed tok");
  Test.AssertStr("mixedCase123", s.id, "ident/mixed value");
  teardown(s);

  (* lowercase keyword is a normal identifier *)
  Test.AssertTrue(setup(s, "module"), "ident/lc-kw setup");
  Test.AssertInt(Scan.TIdent, s.sym, "ident/lowercase keyword");
  teardown(s);

  (* 32-char identifier stored intact *)
  Test.AssertTrue(setup(s, "A2345678901234567890123456789012"),
                  "ident/32 setup");
  Test.AssertInt(Scan.TIdent, s.sym, "ident/32 tok");
  len := 0;
  WHILE (len < LEN(s.id)) & (s.id[len] # 0X) DO INC(len) END;
  Test.AssertInt(32, len, "ident/32 stored full length");
  teardown(s);

  (* 33-char identifier truncated to 32 *)
  Test.AssertTrue(setup(s, "A23456789012345678901234567890123"),
                  "ident/33 setup");
  Test.AssertInt(Scan.TIdent, s.sym, "ident/33 tok");
  len := 0;
  WHILE (len < LEN(s.id)) & (s.id[len] # 0X) DO INC(len) END;
  Test.AssertInt(32, len, "ident/33 truncated to 32");
  teardown(s)
END TIdents;

(* ---- integer literals ---- *)

PROCEDURE TIntegers*;
  VAR s: Scan.Scanner;
BEGIN
  Test.AssertTrue(setup(s, "0"), "int/0 setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/0 tok");
  Test.AssertLong(0, s.ival, "int/0 value");
  teardown(s);

  Test.AssertTrue(setup(s, "1"), "int/1 setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/1 tok");
  Test.AssertLong(1, s.ival, "int/1 value");
  teardown(s);

  Test.AssertTrue(setup(s, "32767"), "int/32767 setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/32767 tok");
  Test.AssertLong(32767, s.ival, "int/32767 value");
  teardown(s);

  Test.AssertTrue(setup(s, "32768"), "int/32768 setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/32768 tok");
  Test.AssertLong(32768, s.ival, "int/32768 value");
  Test.AssertInt(0, s.errCount, "int/32768 no error");
  teardown(s);

  (* hex literals *)
  Test.AssertTrue(setup(s, "0FFH"), "int/0FFH setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/0FFH tok");
  Test.AssertLong(255, s.ival, "int/0FFH value");
  teardown(s);

  Test.AssertTrue(setup(s, "0FFFFH"), "int/0FFFFH setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/0FFFFH tok");
  Test.AssertLong(65535, s.ival, "int/0FFFFH value");
  teardown(s);

  Test.AssertTrue(setup(s, "0H"), "int/0H setup");
  Test.AssertInt(Scan.TInt, s.sym, "int/0H tok");
  Test.AssertLong(0, s.ival, "int/0H value");
  teardown(s);

  (* char literals *)
  Test.AssertTrue(setup(s, "41X"), "char/41X setup");
  Test.AssertInt(Scan.TChar, s.sym, "char/41X tok");
  Test.AssertLong(65, s.ival, "char/41X value");
  teardown(s);

  Test.AssertTrue(setup(s, "0X"), "char/0X setup");
  Test.AssertInt(Scan.TChar, s.sym, "char/0X tok");
  Test.AssertLong(0, s.ival, "char/0X value");
  teardown(s);

  Test.AssertTrue(setup(s, "0FFX"), "char/0FFX setup");
  Test.AssertInt(Scan.TChar, s.sym, "char/0FFX tok");
  Test.AssertLong(255, s.ival, "char/0FFX value");
  teardown(s)
END TIntegers;

(* ---- strings ---- *)

PROCEDURE TStrings*;
  VAR s: Scan.Scanner;
BEGIN
  Test.AssertTrue(setup(s, '"hello"'), "str/dq setup");
  Test.AssertInt(Scan.TString, s.sym, "str/dq tok");
  Test.AssertStr("hello", s.sval, "str/dq value");
  teardown(s);

  Test.AssertTrue(setup(s, "'world'"), "str/sq setup");
  Test.AssertInt(Scan.TString, s.sym, "str/sq tok");
  Test.AssertStr("world", s.sval, "str/sq value");
  teardown(s);

  Test.AssertTrue(setup(s, '""'), "str/empty setup");
  Test.AssertInt(Scan.TString, s.sym, "str/empty tok");
  Test.AssertTrue(s.sval[0] = 0X, "str/empty value zero");
  teardown(s);

  Test.AssertTrue(setup(s, '"unterm'), "str/unterm setup");
  Test.AssertInt(Scan.TString, s.sym, "str/unterm tok");
  Test.AssertTrue(s.errCount > 0, "str/unterm error");
  teardown(s)
END TStrings;

(* ---- operators ---- *)

PROCEDURE checkOp(src: ARRAY OF CHAR; expected: INTEGER; msg: ARRAY OF CHAR);
  VAR s: Scan.Scanner;
BEGIN
  Test.AssertTrue(setup(s, src), msg);
  Test.AssertInt(expected, s.sym, msg);
  teardown(s)
END checkOp;

PROCEDURE TOperators*;
BEGIN
  checkOp(":=", Scan.TAssign, "op/:=");
  checkOp(":",  Scan.TColon,  "op/:");
  checkOp("..", Scan.TDotdot, "op/..");
  checkOp(".",  Scan.TDot,    "op/.");
  checkOp("<=", Scan.TLeq,    "op/<=");
  checkOp("<",  Scan.TLss,    "op/<");
  checkOp(">=", Scan.TGeq,    "op/>=");
  checkOp(">",  Scan.TGtr,    "op/>");
  checkOp("+",  Scan.TPlus,   "op/+");
  checkOp("-",  Scan.TMinus,  "op/-");
  checkOp("*",  Scan.TStar,   "op/*");
  checkOp("/",  Scan.TSlash,  "op/slash");
  checkOp("=",  Scan.TEql,    "op/=");
  checkOp("#",  Scan.TNeq,    "op/#");
  checkOp("&",  Scan.TAnd,    "op/&");
  checkOp("~",  Scan.TNot,    "op/~");
  checkOp("^",  Scan.TArrow,  "op/^");
  checkOp("|",  Scan.TBar,    "op/|");
  checkOp(",",  Scan.TComma,  "op/,");
  checkOp(";",  Scan.TSemi,   "op/;");
  checkOp("(",  Scan.TLparen, "op/(");
  checkOp(")",  Scan.TRparen, "op/)");
  checkOp("[",  Scan.TLbrak,  "op/[");
  checkOp("]",  Scan.TRbrak,  "op/]");
  checkOp("{",  Scan.TLbrace, "op/{");
  checkOp("}",  Scan.TRbrace, "op/}")
END TOperators;

(* ---- comments ---- *)

PROCEDURE TComments*;
  VAR s: Scan.Scanner;
BEGIN
  Test.AssertTrue(setup(s, "(* (* nested *) *) END"), "comment/nested setup");
  Test.AssertInt(Scan.TEnd, s.sym, "comment/nested skipped");
  teardown(s);

  Test.AssertTrue(setup(s, "(* unclosed"), "comment/unterm setup");
  Test.AssertInt(Scan.TEof, s.sym, "comment/unterm hits EOF");
  Test.AssertTrue(s.errCount > 0, "comment/unterm error");
  teardown(s)
END TComments;

(* ---- whitespace ---- *)

PROCEDURE TWhitespace*;
  VAR s: Scan.Scanner; src: ARRAY 10 OF CHAR;
BEGIN
  src[0] := " "; src[1] := " "; src[2] := 9X; src[3] := 0DX; src[4] := 0AX;
  src[5] := " "; src[6] := " "; src[7] := "E"; src[8] := "N"; src[9] := "D";
  (* Build "  \t\r\n  END" plus NUL *)
  Test.AssertTrue(setup(s, src), "ws/all-forms setup");
  Test.AssertInt(Scan.TEnd, s.sym, "ws/all-forms ignored");
  teardown(s)
END TWhitespace;

(* ---- line tracking ---- *)

PROCEDURE TLines*;
  VAR s: Scan.Scanner; src: ARRAY 8 OF CHAR;
BEGIN
  src[0] := "x"; src[1] := 0AX;
  src[2] := "y"; src[3] := 0AX;
  src[4] := "z"; src[5] := 0X;
  Test.AssertTrue(setup(s, src), "lines/setup");
  Test.AssertInt(Scan.TIdent, s.sym, "lines/first token");
  Test.AssertInt(2, s.line, "lines/after first newline");
  Scan.Next(s);
  Test.AssertInt(3, s.line, "lines/after second newline");
  Scan.Next(s);
  Test.AssertInt(3, s.line, "lines/no more newlines");
  teardown(s)
END TLines;

PROCEDURE RunAllTests*;
BEGIN
  TmpFile := "_ts.Mod";
  Test.AddTest(TKeywords,   "Scan/keywords");
  Test.AddTest(TIdents,     "Scan/idents");
  Test.AddTest(TIntegers,   "Scan/integers");
  Test.AddTest(TStrings,    "Scan/strings");
  Test.AddTest(TOperators,  "Scan/operators");
  Test.AddTest(TComments,   "Scan/comments");
  Test.AddTest(TWhitespace, "Scan/whitespace");
  Test.AddTest(TLines,      "Scan/lines");
  Test.RunTests
END RunAllTests;

END TSCAN.
