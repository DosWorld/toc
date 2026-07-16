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
  TSlash*   = 21;    (* '/' -- integer division in a constant expression,
                         e.g. RESW's count operand *)

  TError*   = 99;

  MaxIdent* = 64;
  MaxStr*   = 256;

  ChEof = -1;

CONST
  BUFLEN = 512;
  MaxMemText* = 4096;   (* §I.4: matches Parse.MOD's macro-body/expansion
                            staging-buffer cap. *)

TYPE
  (* MemText wraps its buffer in a one-field RECORD rather than being a
     bare `POINTER TO ARRAY MaxMemText OF CHAR` -- SRC/TOC/SYMS.MOD's
     TypeParamCompat (VAR-parameter type compatibility) has a structural-
     equality fallback for POINTER-TO-RECORD across module boundaries
     but none for POINTER-TO-ARRAY, so a bare array pointer used as a
     VAR parameter in a THIRD module (Parse.MOD calling Sym.MOD's
     GetMacro/DefineMacro, both declared against Scan.MemText) fails
     with a spurious "type mismatch in actual parameter" even though
     both sides import the identical Scan.MemText -- each module's
     compile re-parses SCAN.def into its own TypeDesc instance, and only
     the RECORD-base branch of TypeParamCompat treats those as
     compatible. Routing through a RECORD sidesteps the missing
     compiler branch entirely (found and confirmed 2026-07-16; the real
     fix would be a TFArray-base branch in TypeParamCompat, out of scope
     for this TASM feature). *)
  MemTextRec* = RECORD buf*: ARRAY MaxMemText OF CHAR END;
  MemText* = POINTER TO MemTextRec;

  Scanner* = RECORD
    f*:      Files.File;
    fname*:  ARRAY 128 OF CHAR;
    line*:   LONGINT;
    ch:      INTEGER;       (* current lookahead char, or ChEof *)
    atBol:   BOOLEAN;       (* TRUE if ch is the first char of a new line *)

    (* §I.4: memory-source mode -- retires McNextTok (smell C8). When
       memSrc is TRUE, NextCh pulls from mem^[memPos] instead of the file
       f/Files.ReadByte; a %macro expansion (and future %define bodies)
       is then lexed by this ONE real tokenizer instead of a second,
       independently-diverging ad-hoc re-lexer. mem is NOT owned/freed
       here -- the caller (Parse.MOD's macro-invocation machinery) owns
       the buffer's lifetime and must outlive this Scanner's use of it. *)
    memSrc:  BOOLEAN;
    mem*:    MemText;   (* N1 fix: exported so Parse.MOD can DISPOSE the
                            expansion buffer it owns when popping the slot *)
    memPos:  INTEGER;

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

(* NextChMem: §I.4's memory-source read -- pulls one char from
   s.mem^.buf[s.memPos] instead of the file, sharing the same CR-skip/LF-
   count semantics as the file path below so callers (Next, ScanNumber,
   ScanString, ...) never need to know which source is active. A NUL
   byte in the buffer ends the virtual "file" (mem is a NUL-terminated
   text buffer, matching every other C-string-shaped buffer in this
   module already, e.g. Strings.Copy's own convention). *)
PROCEDURE NextChMem(VAR s: Scanner);
  VAR c: CHAR; done: BOOLEAN;
BEGIN
  done := FALSE;
  WHILE ~done DO
    IF s.memPos >= MaxMemText THEN
      s.ch := ChEof; done := TRUE
    ELSE
      c := s.mem^.buf[s.memPos]; INC(s.memPos);
      IF c = 0X THEN
        s.ch := ChEof; done := TRUE
      ELSIF ORD(c) = 13 THEN
        (* skip CR, loop for the next real char *)
      ELSE
        s.ch := ORD(c);
        IF s.ch = 10 THEN INC(s.line) END;
        done := TRUE
      END
    END
  END
END NextChMem;

(* NextCh: read one raw char from the source file into s.ch, tracking line
   numbers.  A CR is silently skipped (never surfaces as s.ch); LF advances
   the line counter and is returned as ch=10 so the line-oriented parts of
   the scanner (comment handling, EOL synthesis) can see it. *)
PROCEDURE NextCh(VAR s: Scanner);
  VAR b: BYTE; done: BOOLEAN;
BEGIN
  IF s.memSrc THEN NextChMem(s); RETURN END;
  (* C1 fix: loop instead of recursing to skip CRs -- a pathological file
     of N consecutive bare CRs used to recurse N deep, an unguarded stack
     overflow on an 8-32 KB DOS stack. *)
  done := FALSE;
  WHILE ~done DO
    IF ~Files.ReadByte(s.f, b) THEN
      s.ch := ChEof; done := TRUE
    ELSIF INTEGER(b) = 13 THEN
      (* skip CR, loop for the next real char *)
    ELSE
      s.ch := INTEGER(b);
      IF s.ch = 10 THEN INC(s.line) END;
      done := TRUE
    END
  END
END NextCh;

PROCEDURE Init*(VAR s: Scanner; VAR f: Files.File; fname: ARRAY OF CHAR);
BEGIN
  s.memSrc := FALSE;
  s.f := f;
  Strings.Copy(fname, s.fname);
  s.line := 1;
  s.atBol := TRUE;
  NextCh(s)
END Init;

(* InitMem: §I.4 -- initialize a Scanner to read from an in-memory NUL-
   terminated text buffer instead of a file (a %macro invocation's
   expansion). virtFname/virtLine give diagnostics a sensible
   file:line to report even though there is no real file -- NASM itself
   reports macro-expansion errors against the invocation site's own
   file/line, which is exactly what the caller (Parse.MOD) passes here
   (the includer's current fname/tLine at the point of invocation). text
   is NOT copied or owned by the Scanner -- the caller must keep it
   alive for as long as this Scanner is in use (Parse.MOD's macro
   expansion buffers are heap-allocated with the same lifetime as the
   source-stack slot that holds this Scanner, see the input-source
   stack's isFile=FALSE slots). *)
PROCEDURE InitMem*(VAR s: Scanner; text: MemText; virtFname: ARRAY OF CHAR; virtLine: LONGINT);
BEGIN
  s.memSrc := TRUE;
  s.mem := text;
  s.memPos := 0;
  Strings.Copy(virtFname, s.fname);
  s.line := virtLine;
  s.atBol := TRUE;
  NextCh(s)
END InitMem;

PROCEDURE SkipBlanks(VAR s: Scanner);
BEGIN
  WHILE (s.ch = 32) OR (s.ch = 9) DO NextCh(s) END
END SkipBlanks;

PROCEDURE SkipLineComment(VAR s: Scanner);
BEGIN
  WHILE (s.ch # 10) & (s.ch # ChEof) DO NextCh(s) END
END SkipLineComment;

PROCEDURE ScanIdent(VAR s: Scanner);
  VAR i: INTEGER; c: INTEGER; overLong: BOOLEAN;
BEGIN
  i := 0; overLong := FALSE;
  WHILE IsIdentChar(s.ch) DO
    c := s.ch;
    IF i < MaxIdent - 1 THEN
      s.idOrig[i] := CHR(c);
      s.id[i] := SYSTEM.UCASE(CHR(c));
      INC(i)
    ELSE
      overLong := TRUE
    END;
    NextCh(s)
  END;
  s.idOrig[i] := 0X; s.id[i] := 0X;
  s.sym := TIdent;
  (* BUG B3: silently truncating an over-length identifier let two long
     labels sharing a common prefix collide (bogus "duplicate label", or
     worse, both references silently resolving to the first one) --
     make it a loud scan error instead, at the point the name is first
     read, rather than manifesting later as a mysterious lookup failure. *)
  IF overLong THEN
    LogErr.ErrorInFile(s.fname, s.tokLine, "identifier too long")
  END
END ScanIdent;

(* ParseHexDigits: sum buf[from..to) as hex digits into v (accumulator,
   caller pre-zeroes). Shared by both suffix (h/H) and prefix (0x/0X)
   hex forms, and by the decimal digit sum below via a separate branch --
   factored out so there is exactly one hex-digit-value table in the
   whole module (E3 fix, closes the "4 duplicated hex/decimal parsers"
   smell: this + the decimal loop below are now the ONE copy ScanNumber
   uses, and Parse.MOD's McNextTok, the second of the four historical
   copies, calls this same exported ParseNumBuf instead of maintaining
   its own -- BUG A7 lived in exactly this kind of divergence). *)
PROCEDURE ParseHexDigits(buf: ARRAY OF CHAR; from, to0: INTEGER; VAR v: LONGINT; VAR bad: BOOLEAN);
  VAR c: INTEGER;
BEGIN
  c := from;
  WHILE c < to0 DO
    v := v * 16;
    IF (buf[c] >= "0") & (buf[c] <= "9") THEN v := v + LONGINT(ORD(buf[c]) - ORD("0"))
    ELSIF (buf[c] >= "A") & (buf[c] <= "F") THEN v := v + LONGINT(ORD(buf[c]) - ORD("A") + 10)
    ELSIF (buf[c] >= "a") & (buf[c] <= "f") THEN v := v + LONGINT(ORD(buf[c]) - ORD("a") + 10)
    ELSE bad := TRUE
    END;
    INC(c)
  END
END ParseHexDigits;

(* ParseNumBuf: classify and compute the value of an already-gathered
   numeric lexeme (E3 fix -- the shared core both ScanNumber, below, and
   Parse.MOD's McNextTok call, instead of each maintaining its own
   hex/decimal/prefix/suffix logic). `buf`/`len` is the raw lexeme text
   exactly as gathered by the digit loop, INCLUDING any trailing h/H/b/B
   radix suffix (McNextTok's own digit-gathering loop already admits
   those into its buffer the same way ScanNumber's does -- see BUG A7's
   history). `overLong` is TRUE if the caller's gather loop hit its
   buffer bound before the lexeme ended. Returns the numeric value via
   `v` and TRUE on success; on failure returns FALSE and `errMsg` names
   the problem (caller reports it against its own line-number source,
   since ScanNumber and McNextTok use different diagnostic paths). *)
PROCEDURE ParseNumBuf*(buf: ARRAY OF CHAR; len: INTEGER; overLong: BOOLEAN; VAR v: LONGINT; VAR errMsg: ARRAY OF CHAR): BOOLEAN;
  VAR isHexPfx: BOOLEAN; isHexSfx: BOOLEAN; bad: BOOLEAN; c: INTEGER;
BEGIN
  v := LONGINT(0);
  IF overLong THEN Strings.Copy("numeric literal too long", errMsg); RETURN FALSE END;
  isHexSfx := (len >= 1) & ((buf[len-1] = "h") OR (buf[len-1] = "H"));
  isHexPfx := ~isHexSfx & (len >= 2) & (buf[0] = "0") & ((buf[1] = "x") OR (buf[1] = "X"));
  IF isHexSfx THEN
    IF len - 1 > 8 THEN Strings.Copy("hex literal too large", errMsg); RETURN FALSE END;
    bad := FALSE; ParseHexDigits(buf, 0, len - 1, v, bad);
    IF bad THEN Strings.Copy("bad hex literal", errMsg); RETURN FALSE END;
    RETURN TRUE
  END;
  IF isHexPfx THEN
    IF len - 2 > 8 THEN Strings.Copy("hex literal too large", errMsg); RETURN FALSE END;
    bad := FALSE; ParseHexDigits(buf, 2, len, v, bad);
    IF bad THEN Strings.Copy("bad hex literal", errMsg); RETURN FALSE END;
    RETURN TRUE
  END;
  (* trailing b/B binary suffix (e.g. "101b", "11111111b"): unlike the h/H
     hex suffix above, this can never be reached by testing the lookahead
     char during gathering -- the digit loop already admits 'b'/'B' as hex
     digits (SYSTEM.ISHEX), so it's always inside buf by the time this
     runs (BUG A7's root cause). Detect it after the fact: the lexeme is
     binary iff it ends in b/B and every preceding char is '0' or '1'. *)
  IF (len >= 2) & ((buf[len-1] = "b") OR (buf[len-1] = "B")) THEN
    IF len - 1 > 32 THEN Strings.Copy("binary literal too large", errMsg); RETURN FALSE END;
    c := 0;
    WHILE c < len - 1 DO
      IF buf[c] = "0" THEN v := v * 2
      ELSIF buf[c] = "1" THEN v := v * 2 + 1
      ELSE Strings.Copy("bad binary literal", errMsg); RETURN FALSE
      END;
      INC(c)
    END;
    RETURN TRUE
  END;
  IF len > 10 THEN Strings.Copy("decimal literal too large", errMsg); RETURN FALSE END;
  c := 0;
  WHILE c < len DO
    IF (buf[c] >= "0") & (buf[c] <= "9") THEN
      v := v * 10 + LONGINT(ORD(buf[c]) - ORD("0"))
    ELSE
      Strings.Copy("bad decimal literal", errMsg); RETURN FALSE
    END;
    INC(c)
  END;
  RETURN TRUE
END ParseNumBuf;

(* ScanNumber: decimal (123), hex (0x1F / 1Fh / 0FFFFh), or binary (101b). *)
PROCEDURE ScanNumber(VAR s: Scanner);
  VAR buf: ARRAY 32 OF CHAR; i: INTEGER;
      v: LONGINT; overLong: BOOLEAN;
      tokLine: LONGINT; errMsg: ARRAY 40 OF CHAR;
BEGIN
  (* C4 fix: capture the token's start line before NextCh (called below)
     can advance s.line past a literal spanning into the next line (e.g.
     EOF reached mid-token) -- error reports tokLine, not s.line, to
     avoid an off-by-one. *)
  tokLine := s.tokLine;
  i := 0; overLong := FALSE;
  WHILE SYSTEM.ISHEX(CHR(s.ch)) OR (s.ch = 120) (* x *) OR (s.ch = 88) (* X *) DO
    IF i < LEN(buf) - 1 THEN buf[i] := CHR(s.ch); INC(i) ELSE overLong := TRUE END;
    NextCh(s)
  END;
  (* trailing radix suffix: h/H = hex (only char not admitted by the hex
     digit-gathering loop above, so it's read here as the lookahead, not
     already inside buf) -- append it so ParseNumBuf's own hex-suffix
     detection (buf[len-1] = h/H) sees the same lexeme shape McNextTok's
     gather loop already produces for 'b'/'B'. *)
  IF (s.ch = 104) OR (s.ch = 72) THEN  (* h / H *)
    IF i < LEN(buf) - 1 THEN buf[i] := CHR(s.ch); INC(i) ELSE overLong := TRUE END;
    NextCh(s)
  END;
  buf[i] := 0X;
  IF ParseNumBuf(buf, i, overLong, v, errMsg) THEN
    s.ival := v; s.sym := TInt
  ELSE
    LogErr.ErrorInFile(s.fname, tokLine, errMsg)
  END
END ScanNumber;

PROCEDURE ScanString(VAR s: Scanner; quote: INTEGER);
  VAR i: INTEGER; tokLine: LONGINT; overLong: BOOLEAN;
BEGIN
  (* C4 fix: capture the start line before the scan loop's NextCh calls can
     advance s.line -- an unterminated string ends at EOL, where s.line has
     already been incremented once the LF became the lookahead char, so
     reporting s.line was off by one. *)
  tokLine := s.tokLine;
  NextCh(s);  (* skip opening quote *)
  i := 0; overLong := FALSE;
  WHILE (s.ch # quote) & (s.ch # ChEof) & (s.ch # 10) DO
    IF i < MaxStr - 1 THEN s.sval[i] := CHR(s.ch); INC(i) ELSE overLong := TRUE END;
    NextCh(s)
  END;
  s.sval[i] := 0X;
  IF s.ch = quote THEN NextCh(s)
  ELSE LogErr.ErrorInFile(s.fname, tokLine, "unterminated string literal")
  END;
  (* N6 fix: excess characters past MaxStr-1 used to be dropped silently --
     same silent-truncation class B3/C3 eliminated for identifiers and
     numbers. *)
  IF overLong THEN LogErr.ErrorInFile(s.fname, tokLine, "string literal too long") END;
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
  ELSIF s.ch = 47 THEN NextCh(s); s.sym := TSlash   (* / *)
  ELSIF s.ch = 40 THEN NextCh(s); s.sym := TLparen
  ELSIF s.ch = 41 THEN NextCh(s); s.sym := TRparen
  ELSIF s.ch = 34 THEN ScanString(s, 34)   (* " *)
  ELSIF s.ch = 39 THEN ScanString(s, 39)   (* ' *)
  ELSE
    LogErr.ErrorInFile(s.fname, s.line, "unexpected character");
    NextCh(s); s.sym := TError
  END
END Next;

(* ReadRawLine: §I.4's %macro body capture -- reads raw chars verbatim
   (no tokenizing) up to and including the terminating LF (not stored),
   or up to EOF. Bypasses SkipBlanks/comment-handling/token
   classification entirely so a macro body's strings, comments, and
   spacing are preserved byte-for-byte -- re-serializing via the
   %define-body token-to-text path (TokToText) would reopen exactly the
   B5 lossy-serializer trap this design note warns about. buf is NOT
   NUL-appended by this call (the line may legitimately end in any
   byte); the caller null-terminates once the whole multi-line body has
   been staged. Sets eof TRUE if EOF was hit before any LF (the caller's
   %endmacro search then reports "missing %endmacro"). Works from
   EITHER a file or memory source transparently, like every other
   Scan procedure -- NextCh already dispatches on s.memSrc. *)
(* N7 fix: overLong reports when the physical line exceeded LEN(buf) --
   without it, a pathological long macro-body line was captured silently
   truncated, violating §I.0's own "every fixed buffer overflows with a
   loud fatal error" ground rule. Callers that don't care (none currently)
   may still pass a throwaway VAR. *)
PROCEDURE ReadRawLine*(VAR s: Scanner; VAR buf: ARRAY OF CHAR; VAR n: INTEGER; VAR eof, overLong: BOOLEAN);
BEGIN
  n := 0; eof := FALSE; overLong := FALSE;
  WHILE (s.ch # 10) & (s.ch # ChEof) DO
    IF n < LEN(buf) THEN buf[n] := CHR(s.ch); INC(n) ELSE overLong := TRUE END;
    NextCh(s)
  END;
  IF s.ch = ChEof THEN eof := TRUE
  ELSE NextCh(s)   (* consume the LF itself *)
  END
END ReadRawLine;

END Scan.
