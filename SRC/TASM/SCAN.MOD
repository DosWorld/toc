MODULE Scan;
(*
  TASM tokenizer.  Reads assembly source text from a Files.File handle,
  produces one token at a time via Next.  No global state: all state lives
  in the Scanner record passed by VAR (mirrors SRC/TOC/SCAN.MOD's shape).
*)
IMPORT Files, LogErr, Strings;

CONST
  TIdent*  = 0;   (* identifier / mnemonic / register / directive name *)
  TInt*    = 1;   (* numeric literal (decimal, hex, binary) *)
  TString* = 2;   (* "..." or '...' string literal *)
  TEol*    = 3;   (* end of logical line (before comment/CR/LF) *)
  TEof*    = 4;

  TComma*   = 10;
  TColon*   = 11;
  TLbrak*   = 12;
  TRbrak*   = 13;
  TPlus*    = 14;
  TMinus*   = 15;
  TStar*    = 16;
  TDot*     = 17;    (* leading '.' of a local label .name *)
  TPercent* = 18;    (* leading '%' of a preprocessor directive *)
  TLparen*  = 19;
  TRparen*  = 20;

  TError*   = 99;

  MaxIdent* = 64;
  MaxStr*   = 256;

  ChEof = -1;

CONST
  BUFLEN = 512;

TYPE
  Scanner* = RECORD
    f*:      Files.File;
    fname*:  ARRAY 128 OF CHAR;
    line*:   LONGINT;
    ch:      INTEGER;       (* current lookahead char, or ChEof *)
    atBol:   BOOLEAN;       (* TRUE if ch is the first char of a new line *)

    sym*:    INTEGER;       (* token kind, one of T* consts *)
    id*:     ARRAY MaxIdent OF CHAR;   (* TIdent text (uppercased) *)
    idOrig*: ARRAY MaxIdent OF CHAR;   (* TIdent text, original case *)
    ival*:   LONGINT;       (* TInt value *)
    sval*:   ARRAY MaxStr OF CHAR;     (* TString value *)
    tokLine*: LONGINT        (* source line the current token started on *)
  END;

PROCEDURE IsAlpha(c: INTEGER): BOOLEAN;
BEGIN
  (* Note: '.' is deliberately NOT included here.  A leading '.' is handled
     as a special case in Next (local label .name); a '.' appearing mid-
     identifier (e.g. TRegisters._AX, MEMHEADER.Prev) must end the current
     identifier token so Parse.MOD sees separate IDENT DOT IDENT tokens and
     can resolve "STRUCT.field" via Dir.TryResolveField. *)
  RETURN SYSTEM.ISALPHA(CHR(c)) OR (c = 95) (* _ *)
         OR (c = 36)  (* $ -- NASM "current address" / allowed in some idents *)
         OR (c = 63)  (* ? *)
         OR (c = 64)  (* @ *)
END IsAlpha;

PROCEDURE IsIdentChar(c: INTEGER): BOOLEAN;
BEGIN RETURN IsAlpha(c) OR SYSTEM.ISDIGIT(CHR(c))
END IsIdentChar;

(* NextCh: read one raw char from the source file into s.ch, tracking line
   numbers.  A CR is silently skipped (never surfaces as s.ch); LF advances
   the line counter and is returned as ch=10 so the line-oriented parts of
   the scanner (comment handling, EOL synthesis) can see it. *)
PROCEDURE NextCh(VAR s: Scanner);
  VAR b: BYTE;
BEGIN
  IF ~Files.ReadByte(s.f, b) THEN
    s.ch := ChEof
  ELSIF INTEGER(b) = 13 THEN
    NextCh(s)   (* skip CR, recurse for the next real char *)
  ELSE
    s.ch := INTEGER(b);
    IF s.ch = 10 THEN INC(s.line) END
  END
END NextCh;

PROCEDURE Init*(VAR s: Scanner; VAR f: Files.File; fname: ARRAY OF CHAR);
BEGIN
  s.f := f;
  Strings.Copy(fname, s.fname);
  s.line := 1;
  s.atBol := TRUE;
  NextCh(s)
END Init;

(* Mark/Restore: rewind the scanner to a previously recorded file position.
   Used by Sym's %define text-substitution to re-lex the substituted text
   as if it were a fresh token stream is NOT needed here -- kept minimal:
   TASM instead lexes to an intermediate line-token buffer (see Sym.MOD).
   Provided as a low-level primitive in case Parse needs source rewinding
   for a second pass. *)
PROCEDURE Mark*(VAR s: Scanner): LONGINT;
BEGIN RETURN Files.Position(s.f)
END Mark;

PROCEDURE Restore*(VAR s: Scanner; pos: LONGINT; atLine: LONGINT);
BEGIN
  Files.Seek(s.f, pos);
  s.line := atLine;
  NextCh(s)
END Restore;

PROCEDURE SkipBlanks(VAR s: Scanner);
BEGIN
  WHILE (s.ch = 32) OR (s.ch = 9) DO NextCh(s) END
END SkipBlanks;

PROCEDURE SkipLineComment(VAR s: Scanner);
BEGIN
  WHILE (s.ch # 10) & (s.ch # ChEof) DO NextCh(s) END
END SkipLineComment;

PROCEDURE ScanIdent(VAR s: Scanner);
  VAR i: INTEGER; c: INTEGER;
BEGIN
  i := 0;
  WHILE IsIdentChar(s.ch) DO
    c := s.ch;
    IF i < MaxIdent - 1 THEN
      s.idOrig[i] := CHR(c);
      s.id[i] := SYSTEM.UCASE(CHR(c));
      INC(i)
    END;
    NextCh(s)
  END;
  s.idOrig[i] := 0X; s.id[i] := 0X;
  s.sym := TIdent
END ScanIdent;

(* ScanNumber: decimal (123), hex (0x1F / 1Fh / 0FFFFh), or binary (101b). *)
PROCEDURE ScanNumber(VAR s: Scanner);
  VAR buf: ARRAY 32 OF CHAR; i: INTEGER;
      v: LONGINT; c: INTEGER; isHexPfx: BOOLEAN;
BEGIN
  i := 0;
  WHILE SYSTEM.ISHEX(CHR(s.ch)) OR (s.ch = 120) (* x *) OR (s.ch = 88) (* X *) DO
    IF i < LEN(buf) - 1 THEN buf[i] := CHR(s.ch); INC(i) END;
    NextCh(s)
  END;
  isHexPfx := FALSE;
  (* trailing radix suffix: h/H = hex, b/B = binary (only if all digits 0/1) *)
  IF (s.ch = 104) OR (s.ch = 72) THEN  (* h / H *)
    NextCh(s);
    buf[i] := 0X;
    v := 0;
    c := 0;
    WHILE c < i DO
      v := v * 16;
      IF (buf[c] >= "0") & (buf[c] <= "9") THEN v := v + LONGINT(ORD(buf[c]) - ORD("0"))
      ELSIF (buf[c] >= "A") & (buf[c] <= "F") THEN v := v + LONGINT(ORD(buf[c]) - ORD("A") + 10)
      ELSIF (buf[c] >= "a") & (buf[c] <= "f") THEN v := v + LONGINT(ORD(buf[c]) - ORD("a") + 10)
      ELSE LogErr.ErrorInFile(s.fname, s.line, "bad hex literal")
      END;
      INC(c)
    END;
    s.ival := v; s.sym := TInt; RETURN
  ELSIF (s.ch = 98) OR (s.ch = 66) THEN  (* b / B: binary suffix *)
    NextCh(s);
    buf[i] := 0X;
    v := 0;
    c := 0;
    WHILE c < i DO
      IF buf[c] = "0" THEN v := v * 2
      ELSIF buf[c] = "1" THEN v := v * 2 + 1
      ELSE LogErr.ErrorInFile(s.fname, s.line, "bad binary literal")
      END;
      INC(c)
    END;
    s.ival := v; s.sym := TInt; RETURN
  END;
  buf[i] := 0X;
  (* 0x.. / 0X.. prefix form *)
  IF (i >= 2) & (buf[0] = "0") & ((buf[1] = "x") OR (buf[1] = "X")) THEN
    isHexPfx := TRUE
  END;
  v := 0; c := 0;
  IF isHexPfx THEN
    c := 2;
    WHILE c < i DO
      v := v * 16;
      IF (buf[c] >= "0") & (buf[c] <= "9") THEN v := v + LONGINT(ORD(buf[c]) - ORD("0"))
      ELSIF (buf[c] >= "A") & (buf[c] <= "F") THEN v := v + LONGINT(ORD(buf[c]) - ORD("A") + 10)
      ELSIF (buf[c] >= "a") & (buf[c] <= "f") THEN v := v + LONGINT(ORD(buf[c]) - ORD("a") + 10)
      ELSE LogErr.ErrorInFile(s.fname, s.line, "bad hex literal")
      END;
      INC(c)
    END
  ELSE
    WHILE c < i DO
      IF (buf[c] >= "0") & (buf[c] <= "9") THEN
        v := v * 10 + LONGINT(ORD(buf[c]) - ORD("0"))
      ELSE
        LogErr.ErrorInFile(s.fname, s.line, "bad decimal literal")
      END;
      INC(c)
    END
  END;
  s.ival := v; s.sym := TInt
END ScanNumber;

PROCEDURE ScanString(VAR s: Scanner; quote: INTEGER);
  VAR i: INTEGER;
BEGIN
  NextCh(s);  (* skip opening quote *)
  i := 0;
  WHILE (s.ch # quote) & (s.ch # ChEof) & (s.ch # 10) DO
    IF i < MaxStr - 1 THEN s.sval[i] := CHR(s.ch); INC(i) END;
    NextCh(s)
  END;
  s.sval[i] := 0X;
  IF s.ch = quote THEN NextCh(s)
  ELSE LogErr.ErrorInFile(s.fname, s.line, "unterminated string literal")
  END;
  s.sym := TString
END ScanString;

(* Next: fetch the next token into s.sym/s.id/s.ival/s.sval.  Whitespace
   and comments are skipped; a line-comment (;) runs to end of line.  Each
   physical newline yields exactly one TEol token (blank lines and
   comment-only lines produce no token at all -- they're skipped silently,
   matching how a directive/instruction parser wants one TEol per non-empty
   source line, not per raw '\n'). *)
PROCEDURE Next*(VAR s: Scanner);
  VAR more: BOOLEAN;
BEGIN
  more := TRUE;
  WHILE more DO
    SkipBlanks(s);
    IF s.ch = ChEof THEN s.tokLine := s.line; s.sym := TEof; RETURN
    ELSIF s.ch = 10 THEN
      s.tokLine := s.line; NextCh(s); s.sym := TEol; RETURN
    ELSIF s.ch = 59 THEN  (* ; comment *)
      SkipLineComment(s)
    ELSE
      more := FALSE
    END
  END;
  s.tokLine := s.line;
  IF SYSTEM.ISDIGIT(CHR(s.ch)) THEN ScanNumber(s)
  ELSIF IsAlpha(s.ch) & (s.ch # 46) THEN ScanIdent(s)
  ELSIF s.ch = 46 THEN
    (* Always a standalone TDot -- never merged with a following identifier.
       Both the local-label form (".name") and the struct-field-access form
       (mid-expression "STRUCT.field", no surrounding whitespace) are
       syntactically just TDot followed by TIdent; Parse.MOD disambiguates
       by context (leading token on a line vs. following another
       identifier), not by whether whitespace preceded the dot. Merging the
       dot into the identifier here (an earlier version of this scanner did)
       made "STRUCT.field" impossible to tell apart from "STRUCT" followed
       by a separate local label ".field", since NASM source has no
       whitespace in either case. *)
    NextCh(s); s.sym := TDot
  ELSIF s.ch = 37 THEN NextCh(s); s.sym := TPercent
  ELSIF s.ch = 44 THEN NextCh(s); s.sym := TComma
  ELSIF s.ch = 58 THEN NextCh(s); s.sym := TColon
  ELSIF s.ch = 91 THEN NextCh(s); s.sym := TLbrak
  ELSIF s.ch = 93 THEN NextCh(s); s.sym := TRbrak
  ELSIF s.ch = 43 THEN NextCh(s); s.sym := TPlus
  ELSIF s.ch = 45 THEN NextCh(s); s.sym := TMinus
  ELSIF s.ch = 42 THEN NextCh(s); s.sym := TStar
  ELSIF s.ch = 40 THEN NextCh(s); s.sym := TLparen
  ELSIF s.ch = 41 THEN NextCh(s); s.sym := TRparen
  ELSIF s.ch = 34 THEN ScanString(s, 34)   (* " *)
  ELSIF s.ch = 39 THEN ScanString(s, 39)   (* ' *)
  ELSE
    LogErr.ErrorInFile(s.fname, s.line, "unexpected character");
    NextCh(s); s.sym := TError
  END
END Next;

END Scan.
