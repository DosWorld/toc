(*$D-*)
MODULE IO;

CONST
  STDIN*  = 0;
  STDOUT* = 1;
  STDERR* = 2;

TYPE
  Rider* = RECORD
    handle*: INTEGER;
    pos*:    LONGINT;
    eof*:    BOOLEAN
  END;

(* OpenHandle: initialize a Rider to read/write through an already-open
   file handle.
   Parameters: r — rider to initialize; h — file handle to attach. *)
PROCEDURE OpenHandle*(VAR r: Rider; h: INTEGER);
BEGIN
  r.handle := h;
  r.pos    := 0;
  r.eof    := FALSE
END OpenHandle;

(* StdOut: initialize a Rider bound to the standard output handle.
   Parameters: r — rider to initialize. *)
PROCEDURE StdOut*(VAR r: Rider);
BEGIN
  OpenHandle(r, STDOUT)
END StdOut;

(* StdErr: initialize a Rider bound to the standard error handle.
   Parameters: r — rider to initialize. *)
PROCEDURE StdErr*(VAR r: Rider);
BEGIN
  OpenHandle(r, STDERR)
END StdErr;

(* ReadChar: read one character through r's handle, advancing r's position.
   Parameters: r — rider to read from, updated (pos advanced, eof set on
   end-of-file); ch — set to the character read, or 0X at end-of-file. *)
PROCEDURE ReadChar*(VAR r: Rider; VAR ch: CHAR);
BEGIN
  IF SYSTEM.BLOCKREAD(r.handle, ch, 1) = 0 THEN
    r.eof := TRUE;
    ch := 0X
  ELSE
    INC(r.pos)
  END
END ReadChar;

(* WriteChar: write one character through r's handle, advancing r's position.
   Parameters: r — rider to write to, updated (pos advanced on success);
   ch — character to write. *)
PROCEDURE WriteChar*(VAR r: Rider; ch: CHAR);
BEGIN
  IF SYSTEM.BLOCKWRITE(r.handle, ch, 1) = 1 THEN INC(r.pos) END
END WriteChar;

(* WriteLn: write a CR/LF line terminator through r's handle.
   Parameters: r — rider to write to, updated. *)
PROCEDURE WriteLn*(VAR r: Rider);
BEGIN
  WriteChar(r, 0DX); WriteChar(r, 0AX)
END WriteLn;

(* WriteStr: write the characters of s (excluding its terminator) through
   r's handle.
   Parameters: r — rider to write to, updated; s — string to write. *)
PROCEDURE WriteStr*(VAR r: Rider; s: ARRAY OF CHAR);
BEGIN
  INC(r.pos, SYSTEM.BLOCKWRITE(r.handle, s, SYSTEM.LENGTH(s)))
END WriteStr;

(* WriteInt: write the decimal representation of n through r's handle.
   Parameters: r — rider to write to, updated; n — value to write. *)
PROCEDURE WriteInt*(VAR r: Rider; n: LONGINT);
  VAR buf: ARRAY 12 OF CHAR;
      i, k, rem: INTEGER;
      neg: BOOLEAN;
BEGIN
  IF n = 0 THEN
    WriteChar(r, "0");
    RETURN
  END;
  neg := n < 0;
  IF neg THEN n := -n END;
  i := 11;
  buf[i] := 0X;
  WHILE n > 0 DO
    DEC(i);
    rem := n MOD 10;
    buf[i] := CHR(ORD("0") + rem);
    n := n DIV 10;
  END;
  IF neg THEN DEC(i); buf[i] := "-" END;
  k := 0;
  WHILE buf[i] # 0X DO
    buf[k] := buf[i];
    INC(k);
    INC(i);
  END;
  buf[k] := buf[i];
  WriteStr(r, buf)
END WriteInt;

(* WriteBoolean: write "TRUE" or "FALSE" through r's handle.
   Parameters: r — rider to write to, updated; n — value to write. *)
PROCEDURE WriteBoolean*(VAR r: Rider; n: BOOLEAN);
BEGIN
  IF n THEN WriteStr(r, "TRUE") ELSE WriteStr(r, "FALSE") END;
END WriteBoolean;

PROCEDURE HexDigit(d: INTEGER): CHAR;
BEGIN
  IF d < 10 THEN RETURN CHR(ORD("0") + d)
  ELSE RETURN CHR(ORD("A") + d - 10)
  END
END HexDigit;

(* HexDump: write a classic hex-dump listing (offset, hex bytes, ASCII
   sidebar) of a memory block through r's handle, 16 bytes per line.
   Parameters: r — rider to write to, updated; buf — start of the memory
   block to dump; len — number of bytes to dump. *)
PROCEDURE HexDump*(VAR r: Rider; VAR buf; len: WORD);
  VAR
      offset, lenL: WORD;
      i, lineLen, lp: INTEGER;
      b: BYTE;
      ascii: ARRAY 16 OF CHAR;
      p : POINTER TO BYTE;
      m : ARRAY 16 OF BYTE;
      line : ARRAY 90 OF CHAR;
BEGIN
  lenL := len;
  offset := 0;
  WHILE offset < lenL DO
    p := SYSTEM.PTR(SYSTEM.SEG(buf), SYSTEM.OFS(buf) + offset);
    SYSTEM.MOVE(p^, m, 16);
    IF offset + 16 <= lenL THEN lineLen := 16
    ELSE lineLen := lenL - offset END;
    lp := 0;
    line[lp] := HexDigit((offset DIV 4096) MOD 16); INC(lp);
    line[lp] := HexDigit((offset DIV 256) MOD 16); INC(lp);
    line[lp] := HexDigit((offset DIV 16) MOD 16); INC(lp);
    line[lp] := HexDigit(offset MOD 16); INC(lp);
    line[lp] := ":"; INC(lp);
    FOR i := 0 TO 15 DO
      IF i < lineLen THEN
        b := m[i];
        IF (b >= 20H) & (b <= 7EH) THEN ascii[i] := CHR(b)
        ELSE ascii[i] := "." END;
        line[lp] := " "; INC(lp);
        IF i = 8 THEN
          line[lp] := "-"; INC(lp);
          line[lp] := " "; INC(lp)
        END;
        line[lp] := HexDigit(b DIV 16); INC(lp);
        line[lp] := HexDigit(b MOD 16); INC(lp)
      ELSE
        line[lp] := " "; INC(lp);
        line[lp] := " "; INC(lp);
        line[lp] := " "; INC(lp)
      END
    END;
    line[lp] := " "; INC(lp);
    FOR i := 0 TO lineLen - 1 DO
      line[lp] := ascii[i]; INC(lp)
    END;
    INC(offset, 16);
    line[lp] := 0DX; INC(lp);
    line[lp] := 0AX; INC(lp);
    line[lp] := 0X;
    WriteStr(r, line)
  END
END HexDump;

END IO.
