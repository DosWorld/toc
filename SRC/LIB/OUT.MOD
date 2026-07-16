(*$R-*)(*$D-*)
MODULE Out;

CONST
  STDOUT = 1;

(* Open: initialize the Out module for output. *)
PROCEDURE Open*;
BEGIN
END Open;

(* Char: write a single character to standard output.
   Parameters: ch — the character to write. *)
PROCEDURE Char*(ch: CHAR);
BEGIN
  SYSTEM.DOSCHAR(ch)
END Char;

(* Ln: write a CR/LF line terminator to standard output. *)
PROCEDURE Ln*;
BEGIN
  Char(0DX); Char(0AX)
END Ln;

(* String: write a NUL-terminated string to standard output.
   Parameters: s — the character array to write (up to the NUL terminator). *)
PROCEDURE String*(s: ARRAY OF CHAR);
BEGIN
  SYSTEM.BLOCKWRITE(STDOUT, s, SYSTEM.LENGTH(s))
END String;

(* Int: write a LONGINT value in decimal, right-justified in a field.
   Parameters: l — the value to write; w — minimum field width (padded with spaces). *)
PROCEDURE Int*(l: LONGINT; w: INTEGER);
VAR
  n: INTEGER;
  neg: BOOLEAN;
  s: ARRAY 32 OF CHAR;
BEGIN
  IF l = 0 THEN
    WHILE w > 1 DO Char(" "); DEC(w) END;
    Char("0")
  ELSE
    IF l < 0 THEN
      neg := TRUE;
      l := -l
    ELSE
      neg := FALSE
    END;
    s[31] := 0X;
    n := 30;
    WHILE l > 0 DO
      s[n] := CHR(ORD("0") + BYTE(l MOD 10));
      l := l DIV 10;
      DEC(n); DEC(w)
    END;
    IF neg THEN
      s[n] := "-";
      DEC(n); DEC(w)
    END;
    INC(n);
    WHILE w > 0 DO Char(" "); DEC(w) END;
    SYSTEM.BLOCKWRITE(STDOUT, s[n], LEN(s) - n - 1)
  END
END Int;

PROCEDURE HexDigit(d: INTEGER): CHAR;
BEGIN
  IF d < 10 THEN RETURN CHR(ORD("0") + d)
  ELSE RETURN CHR(ORD("A") + d - 10)
  END
END HexDigit;

(* Hex: write an INTEGER value as 4 hex digits, right-justified in a field.
   Parameters: i — the value to write; w — minimum field width (padded with spaces). *)
PROCEDURE Hex*(i: INTEGER; w: INTEGER);
VAR
  n: INTEGER;
  buf: ARRAY 5 OF CHAR;
BEGIN
  n := 3;
  WHILE n >= 0 DO
    buf[n] := HexDigit(SYSTEM.AND(i, 0FH));
    i := SYSTEM.LSR(i, 4);
    DEC(n)
  END;
  WHILE w > 4 DO Char(" "); DEC(w) END;
  buf[4] := 0X;
  String(buf);
END Hex;

(* Adr: write a SYSTEM.ADDRESS as segment:offset hex.
   Parameters: p — the address to write. *)
PROCEDURE Adr*(p: SYSTEM.ADDRESS);
VAR n : POINTER TO CHAR;
BEGIN
  n := p;
  Hex(SYSTEM.SEG(n^), 0);
  Char(":");
  Hex(SYSTEM.OFS(n^), 0)
END Adr;

(* Boolean: write "TRUE" or "FALSE" to standard output.
   Parameters: val — the BOOLEAN value to write. *)
PROCEDURE Boolean*(val: BOOLEAN);
BEGIN
  IF val THEN String("TRUE") ELSE String("FALSE") END
END Boolean;

(* HexDump: write a classic hex+ASCII dump of a memory block, 16 bytes per line.
   Parameters: buf — the memory block to dump; len — number of bytes to dump. *)
PROCEDURE HexDump*(VAR buf; len: WORD);
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
    String(line)
  END
END HexDump;


END Out.
