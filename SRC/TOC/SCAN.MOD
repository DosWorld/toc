MODULE Scan;
(*
  Oberon compiler scanner.
  Reads source text from a Files.File handle byte-by-byte, produces tokens.
  No global state: all state lives in the Scanner record passed by VAR.
*)
IMPORT Files, Err, Strings;

CONST
  (* Token kinds -- match scanner.h values exactly *)
  TIdent*     =  0;
  TInt*       =  1;
  TChar*      =  2;
  TString*    =  3;
  TReal*      =  5;

  TPlus*      = 10;
  TMinus*     = 11;
  TStar*      = 12;
  TSlash*     = 13;
  TEql*       = 14;
  TNeq*       = 15;
  TLss*       = 16;
  TLeq*       = 17;
  TGtr*       = 18;
  TGeq*       = 19;
  TAnd*       = 20;
  TNot*       = 22;
  TArrow*     = 23;
  TAssign*    = 24;
  TDotdot*    = 25;

  TLparen*    = 30;
  TRparen*    = 31;
  TLbrak*     = 32;
  TRbrak*     = 33;
  TLbrace*    = 34;
  TRbrace*    = 35;
  TDot*       = 36;
  TComma*     = 37;
  TSemi*      = 38;
  TColon*     = 39;
  TBar*       = 40;

  TArray*     = 50;
  TBegin*     = 51;
  TBy*        = 52;
  TCase*      = 53;
  TConst*     = 54;
  TDiv*       = 55;
  TDo*        = 56;
  TElse*      = 57;
  TElsif*     = 58;
  TEnd*       = 59;
  TFalse*     = 60;
  TFor*       = 61;
  TIf*        = 62;
  TImport*    = 63;
  TIn*        = 64;
  TIs*        = 65;
  TMod*       = 66;
  TModule*    = 67;
  TNil*       = 68;
  TOf*        = 69;
  TOr*        = 70;
  TPointer*   = 71;
  TProcedure* = 72;
  TRecord*    = 73;
  TRepeat*    = 74;
  TReturn*    = 75;
  TThen*      = 76;
  TTo*        = 77;
  TTrue*      = 78;
  TType*      = 79;
  TUntil*     = 80;
  TVar*       = 81;
  TWhile*     = 82;

  TEof*       = 99;
  TError*     = 100;

  MaxIdent  = 33;
  MaxStr    = 257;
  MaxSyscom = 256;

  ChEof = -1;   (* sentinel for end-of-file *)

  (* ASCII codes for single-character tokens used in CASE labels *)
  ChPlus   = 43;   (* + *)
  ChMinus  = 45;   (* - *)
  ChStar   = 42;   (* * *)
  ChSlash  = 47;   (* / *)
  ChEq     = 61;   (* = *)
  ChHash   = 35;   (* # *)
  ChAmp    = 38;   (* & *)
  ChTilde  = 126;  (* ~ *)
  ChCaret  = 94;   (* ^ *)
  ChBar    = 124;  (* | *)
  ChComma  = 44;   (* , *)
  ChSemi   = 59;   (* ; *)
  ChLbrak  = 91;   (* [ *)
  ChRbrak  = 93;   (* ] *)
  ChLbrace = 123;  (* { *)
  ChRbrace = 125;  (* } *)
  ChRparen = 41;   (* ) *)
  ChLt     = 60;   (* < *)
  ChGt     = 62;   (* > *)
  ChColon  = 58;   (* : *)
  ChDot    = 46;   (* . *)
  ChLparen = 40;   (* ( *)
  ChDquote = 34;   (* " *)
  ChSquote = 39;   (* ' *)
  ChLf     = 10;   (* line feed *)
  ChCr     = 13;   (* carriage return *)
  ChSp     = 32;   (* space *)
  ChTab    =  9;   (* tab *)
  ChDollar = 36;   (* $ *)

TYPE
  Scanner* = RECORD
    sym*:      INTEGER;
    id*:       ARRAY MaxIdent OF CHAR;
    ival*:     LONGINT;
    rval*:     LONGREAL;
    sval*:     ARRAY MaxStr OF CHAR;
    line*:     INTEGER;
    filename*: ARRAY 256 OF CHAR;
    (* syscomment: set when (*$X arg*) or //$X arg is scanned; cleared by caller *)
    sysDir*:   CHAR;
    sysArg*:   ARRAY MaxSyscom OF CHAR;
    (* private fields *)
    file:      Files.File;
    fileOpen:  BOOLEAN;
    ch:        INTEGER;   (* lookahead char; ChEof at end *)
    pendSym:   INTEGER    (* >= 0: return this token next call *)
  END;

(* ---- character helpers ---- *)

PROCEDURE HexVal(c: INTEGER): INTEGER;
BEGIN
  IF SYSTEM.ISDIGIT(CHR(c)) THEN RETURN c - ORD("0")
  ELSE RETURN SYSTEM.UCASE(CHR(c)) - ORD("A") + 10
  END
END HexVal;

(* ---- low-level char reader ---- *)

PROCEDURE ReadCh(VAR s: Scanner);
  VAR b: BYTE; n: BOOLEAN;
BEGIN
  (* ReadByte reads straight from the file buffer (~5 inline instructions),
     not the heavyweight BlockRead block path.  Loop past CRs instead of
     recursing so DOS CRLF files cost no extra call per line. *)
  REPEAT n := Files.ReadByte(s.file, b) UNTIL ~n OR (INTEGER(b) # ChCr);
  IF ~n THEN
    s.ch := ChEof
  ELSE
    s.ch := INTEGER(b);
    IF INTEGER(b) = ChLf THEN INC(s.line) END
  END
END ReadCh;

(* ---- error report ---- *)

PROCEDURE ScanError(VAR s: Scanner; msg: ARRAY OF CHAR);
BEGIN
  Err.ErrorInFile(s.filename, LONGINT(s.line), msg)
END ScanError;

(* ---- keyword lookup -- linear search over 33 keywords ---- *)

PROCEDURE LookupKeyword(VAR id: ARRAY OF CHAR): INTEGER;
BEGIN
  (* Dispatch on the first character first: keywords cluster under a few
     initials, so a non-keyword identifier (the common case) rejects after a
     single CHAR compare instead of up to 33 by-value Strings.Equal calls. *)
  CASE id[0] OF
    "A":
      IF Strings.Equal(id, "ARRAY") THEN RETURN TArray END
  | "B":
      IF    Strings.Equal(id, "BEGIN") THEN RETURN TBegin
      ELSIF Strings.Equal(id, "BY")    THEN RETURN TBy END
  | "C":
      IF    Strings.Equal(id, "CASE")  THEN RETURN TCase
      ELSIF Strings.Equal(id, "CONST") THEN RETURN TConst END
  | "D":
      IF    Strings.Equal(id, "DIV") THEN RETURN TDiv
      ELSIF Strings.Equal(id, "DO")  THEN RETURN TDo END
  | "E":
      IF    Strings.Equal(id, "ELSE")  THEN RETURN TElse
      ELSIF Strings.Equal(id, "ELSIF") THEN RETURN TElsif
      ELSIF Strings.Equal(id, "END")   THEN RETURN TEnd END
  | "F":
      IF    Strings.Equal(id, "FALSE") THEN RETURN TFalse
      ELSIF Strings.Equal(id, "FOR")   THEN RETURN TFor END
  | "I":
      IF    Strings.Equal(id, "IF")     THEN RETURN TIf
      ELSIF Strings.Equal(id, "IMPORT") THEN RETURN TImport
      ELSIF Strings.Equal(id, "IN")     THEN RETURN TIn
      ELSIF Strings.Equal(id, "IS")     THEN RETURN TIs END
  | "M":
      IF    Strings.Equal(id, "MOD")    THEN RETURN TMod
      ELSIF Strings.Equal(id, "MODULE") THEN RETURN TModule END
  | "N":
      IF Strings.Equal(id, "NIL") THEN RETURN TNil END
  | "O":
      IF    Strings.Equal(id, "OF") THEN RETURN TOf
      ELSIF Strings.Equal(id, "OR") THEN RETURN TOr END
  | "P":
      IF    Strings.Equal(id, "POINTER")   THEN RETURN TPointer
      ELSIF Strings.Equal(id, "PROCEDURE") THEN RETURN TProcedure END
  | "R":
      IF    Strings.Equal(id, "RECORD") THEN RETURN TRecord
      ELSIF Strings.Equal(id, "REPEAT") THEN RETURN TRepeat
      ELSIF Strings.Equal(id, "RETURN") THEN RETURN TReturn END
  | "T":
      IF    Strings.Equal(id, "THEN") THEN RETURN TThen
      ELSIF Strings.Equal(id, "TO")   THEN RETURN TTo
      ELSIF Strings.Equal(id, "TRUE") THEN RETURN TTrue
      ELSIF Strings.Equal(id, "TYPE") THEN RETURN TType END
  | "U":
      IF Strings.Equal(id, "UNTIL") THEN RETURN TUntil END
  | "V":
      IF Strings.Equal(id, "VAR") THEN RETURN TVar END
  | "W":
      IF Strings.Equal(id, "WHILE") THEN RETURN TWhile END
  ELSE
  END;
  RETURN TIdent
END LookupKeyword;

(* ---- scan helpers ---- *)

PROCEDURE ScanIdent(VAR s: Scanner);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE SYSTEM.ISALPHA(CHR(s.ch)) OR SYSTEM.ISDIGIT(CHR(s.ch)) DO
    IF i < MaxIdent - 1 THEN
      s.id[i] := CHR(s.ch);
      INC(i)
    END;
    ReadCh(s)
  END;
  s.id[i] := 0X;
  s.sym   := LookupKeyword(s.id)
END ScanIdent;

(* Parse a real literal from rbuf[0..rn-1] and store result in s.rval. *)
PROCEDURE ParseReal(VAR s: Scanner; VAR rbuf: ARRAY OF CHAR; rn: INTEGER);
  VAR
    i:        INTEGER;
    result:   LONGREAL;       (* integer part, accumulating *)
    fraction: LONGREAL;       (* fractional contribution *)
    divisor:  LONGREAL;       (* 10, 100, 1000, ... per fractional digit *)
    isFrac:   BOOLEAN;
    exp:      LONGINT;
    eNeg:     BOOLEAN;
BEGIN
  (* Algorithm — MUST produce bit-identical doubles or TestReals /
     TestLongReals diverge in the last mantissa bit:
       result   = integer-part digits, accumulated as `* 10.0`
       fraction = sum of `digit / divisor` where divisor *= 10.0
                  per fractional digit (10, 100, 1000 …)
       value    = result + fraction
     Division `digit / divisor` (instead of the earlier
     `digit * (0.1 * 0.1 * …)` recurrence) gives exact 1/10^n
     for small n and a single rounding for each fractional digit,
     so total error is bounded by 1 ulp regardless of x87 vs SSE2
     intermediate width.  Exponent handling: linear `* 10.0` or
     `* 0.1` loop, same as before. *)
  result := 0.0; fraction := 0.0; divisor := 1.0; isFrac := FALSE;
  i := 0;
  WHILE (i < rn) & (SYSTEM.ISDIGIT(rbuf[i]) OR (rbuf[i] = ".")) DO
    IF rbuf[i] = "." THEN
      IF isFrac THEN i := rn  (* unexpected second '.' — stop *)
      ELSE isFrac := TRUE
      END
    ELSIF ~isFrac THEN
      result := result * 10.0 + LONGREAL(ORD(rbuf[i]) - ORD("0"))
    ELSE
      divisor := divisor * 10.0;
      fraction := fraction + LONGREAL(ORD(rbuf[i]) - ORD("0")) / divisor
    END;
    INC(i)
  END;
  result := result + fraction;

  IF (i < rn) & ((rbuf[i] = "E") OR (rbuf[i] = "e")) THEN
    INC(i);
    eNeg := FALSE;
    IF (i < rn) & (rbuf[i] = "-") THEN eNeg := TRUE; INC(i)
    ELSIF (i < rn) & (rbuf[i] = "+") THEN INC(i)
    END;
    exp := 0;
    WHILE (i < rn) & SYSTEM.ISDIGIT(rbuf[i]) DO
      exp := exp * 10 + LONGINT(ORD(rbuf[i]) - ORD("0"));
      INC(i)
    END;
    (* Apply exponent.  For negative exp we divide by 10^|exp| (built
       up as `divisor := divisor * 10.0` in a loop, then a single
       `result := result / divisor`) instead of `result := result * 0.1`
       repeated — division by an exactly-representable power of 10 is
       bit-stable across x87 vs SSE2 intermediates.  For positive exp
       the iterative `* 10.0` is already exact (10.0 is exact in IEEE
       754, multiplication is well-defined per step). *)
    IF eNeg THEN
      divisor := 1.0;
      WHILE exp > 0 DO divisor := divisor * 10.0; DEC(exp) END;
      result := result / divisor
    ELSE
      WHILE exp > 0 DO result := result * 10.0; DEC(exp) END
    END
  END;
  s.rval := result
END ParseReal;

PROCEDURE ScanReal(VAR s: Scanner; VAR buf: ARRAY OF CHAR; n: INTEGER;
                   hasHex: BOOLEAN);
  VAR
    rbuf: ARRAY 64 OF CHAR;
    rn, i: INTEGER;
    v: LONGINT;
BEGIN
  IF hasHex THEN ScanError(s, "hex digit in real literal") END;
  rn := 0; i := 0;
  WHILE (i < n) & (rn < 63) DO rbuf[rn] := buf[i]; INC(rn); INC(i) END;
  ReadCh(s);   (* consume first '.' *)
  IF s.ch = ChDot THEN
    (* "n.." -- emit TInt, schedule TDotdot *)
    v := 0; i := 0;
    WHILE i < n DO
      v := v * 10 + LONGINT(ORD(buf[i]) - ORD("0"));
      INC(i)
    END;
    s.ival    := v;
    s.sym     := TInt;
    ReadCh(s);    (* consume second '.' *)
    s.pendSym := TDotdot;
    RETURN
  END;
  (* dot separator then fractional digits *)
  IF rn < 63 THEN rbuf[rn] := "."; INC(rn) END;
  WHILE SYSTEM.ISDIGIT(CHR(s.ch)) & (rn < 63) DO
    rbuf[rn] := CHR(s.ch); INC(rn); ReadCh(s)
  END;
  (* optional exponent: 'E'=69 or 'e'=101 *)
  IF ((s.ch = 69) OR (s.ch = 101)) & (rn < 62) THEN
    rbuf[rn] := "E"; INC(rn); ReadCh(s);
    IF ((s.ch = ChPlus) OR (s.ch = ChMinus)) & (rn < 62) THEN
      rbuf[rn] := CHR(s.ch); INC(rn); ReadCh(s)
    END;
    WHILE SYSTEM.ISDIGIT(CHR(s.ch)) & (rn < 63) DO
      rbuf[rn] := CHR(s.ch); INC(rn); ReadCh(s)
    END
  END;
  rbuf[rn] := 0X;
  ParseReal(s, rbuf, rn);
  s.sym := TReal
END ScanReal;

PROCEDURE ScanNumber(VAR s: Scanner);
  VAR
    buf:           ARRAY 64 OF CHAR;
    n, i:          INTEGER;
    hasHex, oflow: BOOLEAN;
    v:             LONGINT;
BEGIN
  n := 0; hasHex := FALSE; oflow := FALSE;
  WHILE SYSTEM.ISHEX(CHR(s.ch)) DO
    IF s.ch >= ORD("A") THEN hasHex := TRUE END;
    IF n < 63 THEN buf[n] := CHR(s.ch); INC(n)
    ELSE oflow := TRUE
    END;
    ReadCh(s)
  END;
  buf[n] := 0X;
  IF oflow THEN ScanError(s, "numeric literal too long"); RETURN END;

  IF s.ch = 72 THEN                 (* 'H' = 72: hex integer *)
    v := 0; ReadCh(s);
    i := 0;
    WHILE i < n DO
      v := v * 16 + LONGINT(HexVal(ORD(buf[i])));
      INC(i)
    END;
    s.ival := v;
    s.sym  := TInt

  ELSIF s.ch = 88 THEN              (* 'X' = 88: char literal *)
    v := 0; ReadCh(s);
    i := 0;
    WHILE i < n DO
      v := v * 16 + LONGINT(HexVal(ORD(buf[i])));
      INC(i)
    END;
    IF v > 255 THEN ScanError(s, "char literal out of range") END;
    s.ival := v;
    s.sym  := TChar
  ELSIF s.ch = ChDot THEN
    ScanReal(s, buf, n, hasHex)
  ELSE                              (* decimal integer *)
    IF hasHex THEN ScanError(s, "hex digit in decimal literal") END;
    v := 0; i := 0;
    WHILE i < n DO
      v := v * 10 + LONGINT(ORD(buf[i]) - ORD("0"));
      INC(i)
    END;
    s.ival := v;
    s.sym  := TInt
  END
END ScanNumber;

PROCEDURE ScanString(VAR s: Scanner; delim: INTEGER);
  VAR i: INTEGER;
BEGIN
  i := 0;
  ReadCh(s);  (* skip opening delimiter *)
  WHILE (s.ch # delim) & (s.ch # ChLf) & (s.ch # ChEof) DO
    IF i < MaxStr - 1 THEN s.sval[i] := CHR(s.ch); INC(i) END;
    ReadCh(s)
  END;
  s.sval[i] := 0X;
  IF s.ch = delim THEN ReadCh(s)
  ELSE ScanError(s, "unterminated string")
  END;
  s.sym := TString
END ScanString;

PROCEDURE DispatchSyscomment(VAR s: Scanner; VAR buf: ARRAY OF CHAR; n: INTEGER);
  VAR i, j: INTEGER;
BEGIN
  IF n = 0 THEN RETURN END;
  s.sysDir := buf[0];
  i := 1;
  WHILE (i < n) & ((buf[i] = " ") OR (buf[i] = 09X)) DO INC(i) END;
  j := 0;
  WHILE (i < n) & (j < MaxSyscom - 1) DO
    s.sysArg[j] := buf[i]; INC(j); INC(i)
  END;
  s.sysArg[j] := 0X
END DispatchSyscomment;

PROCEDURE SkipComment(VAR s: Scanner);
  VAR
    depth: INTEGER;
    buf:   ARRAY MaxSyscom OF CHAR;
    n:     INTEGER;
BEGIN
  IF s.ch = ChDollar THEN  (* system comment (*$...*) -- collect and dispatch *)
    ReadCh(s);
    n := 0;
    WHILE s.ch # ChEof DO
      IF s.ch = ChStar THEN
        ReadCh(s);
        IF s.ch = ChRparen THEN ReadCh(s);
          buf[n] := 0X;
          DispatchSyscomment(s, buf, n);
          RETURN
        END;
        IF n < MaxSyscom - 1 THEN buf[n] := "*"; INC(n) END
      ELSE
        IF n < MaxSyscom - 1 THEN buf[n] := CHR(s.ch); INC(n) END;
        ReadCh(s)
      END
    END;
    RETURN
  END;
  depth := 1;
  WHILE (depth > 0) & (s.ch # ChEof) DO
    IF s.ch = ChLparen THEN
      ReadCh(s);
      IF s.ch = ChStar THEN INC(depth); ReadCh(s) END
    ELSIF s.ch = ChStar THEN
      ReadCh(s);
      IF s.ch = ChRparen THEN DEC(depth); ReadCh(s) END
    ELSE
      ReadCh(s)
    END
  END;
  IF depth > 0 THEN ScanError(s, "unterminated comment") END
END SkipComment;

PROCEDURE SkipLineComment(VAR s: Scanner; isSys: BOOLEAN);
  VAR
    buf: ARRAY MaxSyscom OF CHAR;
    n:   INTEGER;
BEGIN
  IF isSys THEN
    n := 0;
    WHILE (s.ch # ChLf) & (s.ch # ChEof) DO
      IF n < MaxSyscom - 1 THEN buf[n] := CHR(s.ch); INC(n) END;
      ReadCh(s)
    END;
    buf[n] := 0X;
    DispatchSyscomment(s, buf, n)
  ELSE
    WHILE (s.ch # ChLf) & (s.ch # ChEof) DO ReadCh(s) END
  END
END SkipLineComment;

(* ---- public interface ---- *)
(* Next must be declared before Open because Open calls Next *)

PROCEDURE Next*(VAR s: Scanner);
  VAR c: INTEGER;
BEGIN
  (* pending token from "n.." lookahead *)
  IF s.pendSym >= 0 THEN
    s.sym     := s.pendSym;
    s.pendSym := -1;
    RETURN
  END;
  (* skip whitespace (CR already filtered by ReadCh) *)
  WHILE (s.ch = ChSp) OR (s.ch = ChTab) OR (s.ch = ChLf) DO
    ReadCh(s)
  END;
  IF s.ch = ChEof THEN s.sym := TEof; RETURN END;

  IF SYSTEM.ISALPHA(CHR(s.ch))      THEN ScanIdent(s);           RETURN END;
  IF SYSTEM.ISDIGIT(CHR(s.ch))      THEN ScanNumber(s);          RETURN END;
  IF (s.ch = ChDquote) OR (s.ch = ChSquote) THEN ScanString(s, s.ch); RETURN END;

  c := s.ch; ReadCh(s);
  CASE c OF
    ChPlus:   s.sym := TPlus
  | ChMinus:  s.sym := TMinus
  | ChStar:   s.sym := TStar
  | ChSlash:
      IF s.ch = ChSlash THEN
        ReadCh(s);  (* consume second '/' *)
        IF s.ch = ChDollar THEN
          ReadCh(s);  (* consume '$' *)
          SkipLineComment(s, TRUE)
        ELSE
          SkipLineComment(s, FALSE)
        END;
        Next(s)
      ELSE s.sym := TSlash
      END
  | ChEq:    s.sym := TEql
  | ChHash:  s.sym := TNeq
  | ChAmp:   s.sym := TAnd
  | ChTilde: s.sym := TNot
  | ChCaret: s.sym := TArrow
  | ChBar:   s.sym := TBar
  | ChComma: s.sym := TComma
  | ChSemi:  s.sym := TSemi
  | ChLbrak: s.sym := TLbrak
  | ChRbrak: s.sym := TRbrak
  | ChLbrace: s.sym := TLbrace
  | ChRbrace: s.sym := TRbrace
  | ChRparen: s.sym := TRparen
  | ChLt:
      IF s.ch = ChEq THEN ReadCh(s); s.sym := TLeq
      ELSE s.sym := TLss
      END
  | ChGt:
      IF s.ch = ChEq THEN ReadCh(s); s.sym := TGeq
      ELSE s.sym := TGtr
      END
  | ChColon:
      IF s.ch = ChEq THEN ReadCh(s); s.sym := TAssign
      ELSE s.sym := TColon
      END
  | ChDot:
      IF s.ch = ChDot THEN ReadCh(s); s.sym := TDotdot
      ELSE s.sym := TDot
      END
  | ChLparen:
      IF s.ch = ChStar THEN ReadCh(s); SkipComment(s); Next(s)
      ELSE s.sym := TLparen
      END
  ELSE
    ScanError(s, "illegal character");
    s.sym := TError
  END
END Next;

PROCEDURE Close*(VAR s: Scanner);
BEGIN
  IF s.fileOpen THEN
    Files.Close(s.file);
    s.fileOpen := FALSE
  END;
  s.sym := TEof
END Close;

(* Mark/Restore — save and rewind lexer position for a bounded lookahead
   pre-scan (used by CASE's label-density pre-pass, see PStmt.MOD).  Restore
   does NOT reuse the saved copy's `file` value (its buffer window has moved
   on by the time Restore runs); it re-seeks the LIVE file to the saved byte
   position instead, which reloads the buffer, then copies back every other
   field verbatim.  The saved byte position is Files.Position at the moment
   Mark is called: since s.ch already holds the next lookahead character (it
   was read but not yet consumed as part of a token), position == "next byte
   the file will read", so after Seek + field restore, resuming Next(s) or
   ReadCh(s) behaves exactly as if no pre-scan had happened. *)
PROCEDURE Mark*(VAR s: Scanner; VAR m: Scanner; VAR filePos: LONGINT);
BEGIN
  m := s;
  filePos := Files.Position(s.file)
END Mark;

PROCEDURE Restore*(VAR s: Scanner; VAR m: Scanner; filePos: LONGINT);
BEGIN
  Files.Seek(s.file, filePos);
  m.file := s.file;   (* keep the freshly-seeked file state; discard the stale copy *)
  s := m
END Restore;

PROCEDURE Open*(VAR s: Scanner; filename: ARRAY OF CHAR);
BEGIN
  s.sym      := TEof;
  s.ival     := 0;
  s.rval     := 0.0;
  s.line     := 1;
  s.pendSym  := -1;
  s.id[0]    := 0X;
  s.sval[0]  := 0X;
  s.sysDir   := 0X;
  s.sysArg[0] := 0X;
  s.fileOpen := FALSE;
  Strings.Copy(filename, s.filename);
  s.fileOpen := Files.Reset(s.file, filename);
  IF ~s.fileOpen THEN
    Err.Error2("cannot open ", filename);
    RETURN
  END;
  ReadCh(s);
  Next(s)   (* prime first token *)
END Open;

END Scan.
