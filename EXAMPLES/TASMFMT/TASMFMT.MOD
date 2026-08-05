MODULE TasmFmt;
(*
  tasmfmt — reformat a NASM-subset .asm source file (see DOCS/PORTING.MD
  §1.6 for the dialect TASM.EXE accepts) to a consistent layout:
  column-0 labels, tab-stop-aligned mnemonic/directive and operands, and
  optionally-stripped ";" comments.

  usage: tasmfmt FILE.ASM [/NOCOMMENT]
    FILE.ASM     rewritten in place (original kept as FILE.BAK)
    /NOCOMMENT   drop every ";" comment (line-comment or trailing) instead
                 of re-emitting it

  Each source line is classified before reformatting, not just split on
  whitespace: a ";" inside a '...'/"..." string literal (NASM's DB-string
  syntax, matched to the same closing quote per DOCS/PORTING.MD -- TASM's
  own SCAN.MOD accepts both) does not start a comment, so `db ';', 0` is
  never truncated mid-line.  Recognizes, but does not otherwise
  special-case, the constructs the dialect uses: bare-label lines
  ("foo:"), instructions/pseudo-ops (DB/DW/DD/TIMES/EQU/RESB/RESW/RESD),
  and preprocessor/section directives ("%..." -- %DEFINE/%MACRO/%INCLUDE/
  %IFDEF/etc, and bare-word directives -- BITS/CPU/SECTION/GLOBAL/EXTERN/
  IMPORT/STRUC/ENDSTRUC) -- all of these are just "first word, rest of
  line" as far as column alignment is concerned, so one code path formats
  them all.

  All error/exit paths funnel through RunBody's result code; the single
  SYSTEM.Halt lives in Run, matching TOSTRIP.MOD's shape.
*)
IMPORT Out, Dos, Files, Strings;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;

  MaxLine   = 512;

  TabStep   = 8;    (* grid step PadTo advances to on overflow *)
  MnemCol   = 8;    (* column the mnemonic/directive starts at *)
  OperGap   = 8;    (* columns between a mnemonic's own start and its operands *)
  CommCol   = 40;   (* column a trailing ";" comment is aligned to *)

VAR
  stripComments: BOOLEAN;

PROCEDURE Usage;
BEGIN
  Out.String("TasmFmt (c) 2026 DosWorld, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("usage: TASMFMT file.asm [/NOCOMMENT]"); Out.Ln;
  Out.String("  Reformats a NASM-subset .asm source file (label/mnemonic/"); Out.Ln;
  Out.String("  operand/comment columns).  /NOCOMMENT drops all ';' comments."); Out.Ln
END Usage;

(* AppendSpaces: pad dst with n blanks. *)
PROCEDURE AppendSpaces(n: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
  WHILE n > 0 DO Strings.Append(" ", dst); DEC(n) END
END AppendSpaces;

(* AppendChar: Strings.Append takes ARRAY OF CHAR, not a bare CHAR. *)
PROCEDURE AppendChar(ch: CHAR; VAR dst: ARRAY OF CHAR);
  VAR one: ARRAY 2 OF CHAR;
BEGIN
  one[0] := ch; one[1] := 0X;
  Strings.Append(one, dst)
END AppendChar;

(* PadTo: append spaces to dst until its length reaches col.  If dst has
   already overflowed col (a name longer than MnemCol, say), advance to
   the next multiple of TabStep instead of gluing the next field on with
   a single space -- keeps every field landing on the same fixed grid
   (MnemCol/OperCol/CommCol are themselves multiples of TabStep) rather
   than losing alignment on the one long line. *)
PROCEDURE PadTo(col: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR n, len, target: INTEGER;
BEGIN
  len := INTEGER(Strings.Length(dst));
  target := col;
  WHILE target <= len DO INC(target, TabStep) END;
  n := target - len;
  AppendSpaces(n, dst)
END PadTo;

(* FindCommentStart: index of the ';' that starts a comment, honoring
   '...'/"..." string literals (a ';' inside one is data, not a comment
   marker -- see the module header comment).  Returns len(line) if none. *)
PROCEDURE FindCommentStart(line: ARRAY OF CHAR): INTEGER;
  VAR i, len: INTEGER; inStr: BOOLEAN; q: CHAR;
BEGIN
  len := INTEGER(Strings.Length(line));
  i := 0; inStr := FALSE; q := 0X;
  WHILE i < len DO
    IF inStr THEN
      IF line[i] = q THEN inStr := FALSE END
    ELSIF (line[i] = 22X) OR (line[i] = 27X) THEN  (* " or ' *)
      inStr := TRUE; q := line[i]
    ELSIF line[i] = ";" THEN
      RETURN i
    END;
    INC(i)
  END;
  RETURN len
END FindCommentStart;

PROCEDURE IsIdentChar(ch: CHAR): BOOLEAN;
BEGIN
  RETURN (ch >= "A") & (ch <= "Z") OR (ch >= "a") & (ch <= "z")
       OR (ch >= "0") & (ch <= "9") OR (ch = "_") OR (ch = "$")
       OR (ch = "?") OR (ch = "@") OR (ch = ".")
END IsIdentChar;

(* SplitFirstWord: code[0..codeLen) is code with any comment already cut
   off and trimmed.  Extracts the leading run of ident chars into word,
   and returns the index in code where the rest (operands) begins (first
   non-blank after word, or codeLen if word runs to the end). A leading
   '%' (preprocessor directive) or trailing ':' (label) is treated as
   part of the word so "%define", "%endif", and "start:" each come back
   as one token. *)
PROCEDURE SplitFirstWord(code: ARRAY OF CHAR; codeLen: INTEGER; VAR word: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN
  word[0] := 0X;
  i := 0;
  IF (i < codeLen) & (code[i] = "%") THEN
    Strings.Append("%", word); INC(i)
  END;
  WHILE (i < codeLen) & IsIdentChar(code[i]) DO
    AppendChar(code[i], word); INC(i)
  END;
  IF (i < codeLen) & (code[i] = ":") THEN
    Strings.Append(":", word); INC(i)
  END;
  WHILE (i < codeLen) & SYSTEM.ISSPACE(code[i]) DO INC(i) END;
  RETURN i
END SplitFirstWord;

(* FormatLine: reformat one source line into out. *)
PROCEDURE FormatLine(line: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR commentAt, codeLen: INTEGER;
      code: ARRAY MaxLine OF CHAR;
      comment: ARRAY MaxLine OF CHAR;
      word: ARRAY MaxLine OF CHAR;
      rest: ARRAY MaxLine OF CHAR;
      peekWord: ARRAY MaxLine OF CHAR;
      restStart, peekStart, mnemStart: INTEGER;
      isLabel: BOOLEAN;
BEGIN
  out[0] := 0X;
  commentAt := FindCommentStart(line);
  Strings.Extract(line, 0, commentAt, code);
  Strings.Trim(code);

  comment[0] := 0X;
  IF ~stripComments THEN
    Strings.Extract(line, commentAt, INTEGER(Strings.Length(line)) - commentAt, comment);
    Strings.RTrim(comment)
  END;

  codeLen := INTEGER(Strings.Length(code));
  IF codeLen = 0 THEN
    (* comment-only or blank line: emit just the comment (left-aligned), or nothing *)
    IF comment[0] # 0X THEN Strings.Copy(comment, out) END;
    RETURN
  END;

  restStart := SplitFirstWord(code, codeLen, word);
  isLabel := (word[0] # 0X) & (word[INTEGER(Strings.Length(word)) - 1] = ":");

  Strings.Extract(code, restStart, codeLen - restStart, rest);
  Strings.RTrim(rest);
  peekWord[0] := 0X; peekStart := 0;
  IF rest[0] # 0X THEN
    peekStart := SplitFirstWord(rest, INTEGER(Strings.Length(rest)), peekWord)
  END;

  (* "NAME EQU expr", "NAME DB/DW/DD value...", and "NAME RESB/RESW/RESD
     count" each define a symbol at NAME, exactly like a label -- keep
     NAME at column 0 rather than indenting it as if it were a mnemonic
     (a label ends in ':', but these never do). rest/peekWord/restStart
     were already split above for the label case's own lookahead, so the
     EQU/DB/DW/DD/RES* check just inspects that same peek instead of
     re-splitting. *)
  IF (~isLabel) & (word[0] # 0X) & (word[0] # "%") THEN
    isLabel := Strings.EqualICase(peekWord, "EQU")
               OR Strings.EqualICase(peekWord, "DB")
               OR Strings.EqualICase(peekWord, "DW")
               OR Strings.EqualICase(peekWord, "DD")
               OR Strings.EqualICase(peekWord, "RESB")
               OR Strings.EqualICase(peekWord, "RESW")
               OR Strings.EqualICase(peekWord, "RESD")
               OR Strings.EqualICase(peekWord, "TIMES")
  END;

  IF isLabel THEN
    Strings.Copy(word, out);
    (* a bare label/EQU-name may be followed by a mnemonic/value on the
       same line ("start: mov ax,1", "FOO equ 8"); rest/peekWord/
       peekStart (split above) are exactly that remainder -- splice it
       onto the same output line. *)
    IF peekWord[0] # 0X THEN
      PadTo(MnemCol, out);
      mnemStart := INTEGER(Strings.Length(out));
      Strings.Append(peekWord, out);
      IF peekStart < INTEGER(Strings.Length(rest)) THEN
        Strings.Extract(rest, peekStart, INTEGER(Strings.Length(rest)) - peekStart, rest);
        PadTo(mnemStart + OperGap, out);
        Strings.Append(rest, out)
      END
    END
  ELSE
    AppendSpaces(MnemCol, out);
    mnemStart := MnemCol;
    Strings.Append(word, out);
    IF restStart < codeLen THEN
      Strings.Extract(code, restStart, codeLen - restStart, rest);
      PadTo(mnemStart + OperGap, out);
      Strings.Append(rest, out)
    END
  END;

  IF comment[0] # 0X THEN
    PadTo(CommCol, out);
    Strings.Append(comment, out)
  END
END FormatLine;

PROCEDURE RunBody(): INTEGER;
  VAR path, bakPath, arg: ARRAY 128 OF CHAR;
      src, dst: Files.File;
      line, out: ARRAY MaxLine OF CHAR;
      rc: INTEGER;
BEGIN
  stripComments := FALSE;
  IF Dos.ParamCount() < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, path);
  IF Dos.ParamCount() >= 2 THEN
    Dos.ParamStr(2, arg);
    IF Strings.EqualICase(arg, "/NOCOMMENT") THEN stripComments := TRUE
    ELSE
      Out.String("tasmfmt: unknown option "); Out.String(arg); Out.Ln;
      Usage; RETURN ExitUsage
    END
  END;

  IF ~Files.FileExists(path) THEN
    Out.String("tasmfmt: no such file: "); Out.String(path); Out.Ln;
    RETURN ExitIo
  END;
  IF ~Files.Reset(src, path) THEN
    Out.String("tasmfmt: cannot open "); Out.String(path); Out.Ln;
    RETURN ExitIo
  END;
  IF ~Files.ReWriteTemp(dst) THEN
    Out.String("tasmfmt: cannot create temp file"); Out.Ln;
    Files.Close(src); RETURN ExitIo
  END;

  WHILE ~Files.Eof(src) DO
    IF (Files.ReadLine(src, line, LEN(line)) # 0) OR (line[0] # 0X) THEN
      FormatLine(line, out);
      Files.WriteLine(dst, out)
    ELSIF ~Files.Eof(src) THEN
      Files.WriteLine(dst, "")
    END
  END;
  Files.Close(src);

  Files.ReplaceExt(path, ".BAK", bakPath);
  IF Files.FileExists(bakPath) THEN
    IF ~Files.Delete(bakPath) THEN
      Out.String("tasmfmt: cannot remove stale "); Out.String(bakPath); Out.Ln;
      Files.Close(dst); RETURN ExitIo
    END
  END;
  IF ~Files.Copy(path, bakPath) THEN
    Out.String("tasmfmt: cannot back up "); Out.String(path); Out.Ln;
    Files.Close(dst); RETURN ExitIo
  END;

  rc := ExitOk;
  Files.Seek(dst, LONGINT(0));
  IF ~Files.ReWrite(src, path) THEN
    Out.String("tasmfmt: cannot write "); Out.String(path); Out.Ln;
    Files.Close(dst); RETURN ExitIo
  END;
  IF ~Files.BlockCopy(dst, src, Files.Size(dst)) THEN
    Out.String("tasmfmt: short write to "); Out.String(path); Out.Ln;
    rc := ExitIo
  END;
  Files.Close(src);
  Files.Close(dst);

  IF rc = ExitOk THEN
    Out.String("tasmfmt: reformatted "); Out.String(path);
    Out.String(" (original kept as "); Out.String(bakPath); Out.String(")"); Out.Ln
  END;
  RETURN rc
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  rc := RunBody();
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in tasmfmt *)
END Run;

END TasmFmt.
