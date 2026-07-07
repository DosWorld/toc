(*$R-*)(*$D-*)
MODULE Out;

CONST
  STDOUT = 1;

PROCEDURE Open*;
BEGIN
END Open;

PROCEDURE Char*(ch: CHAR);
BEGIN
  SYSTEM.DOSCHAR(ch)
END Char;

PROCEDURE Ln*;
BEGIN
  Char(0DX); Char(0AX)
END Ln;

PROCEDURE String*(s: ARRAY OF CHAR);
BEGIN
  SYSTEM.BLOCKWRITE(STDOUT, s, SYSTEM.LENGTH(s))
END String;

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

PROCEDURE Hex*(i: INTEGER; w: INTEGER);
VAR
  n: INTEGER;
  buf: ARRAY 4 OF CHAR;
BEGIN
  n := 0;
  WHILE n < 4 DO
    buf[n] := HexDigit(SYSTEM.AND(i, 0FH));
    i := SYSTEM.LSR(i, 4);
    INC(n)
  END;
  WHILE w > 4 DO Char(" "); DEC(w) END;
  WHILE n > 0 DO
    DEC(n);
    Char(buf[n])
  END
END Hex;

PROCEDURE Adr*(p: SYSTEM.ADDRESS);
VAR n : POINTER TO CHAR;
BEGIN
  n := p;
  Hex(SYSTEM.SEG(n^), 0);
  Char(":");
  Hex(SYSTEM.OFS(n^), 0)
END Adr;

PROCEDURE Boolean*(val: BOOLEAN);
BEGIN
  IF val THEN String("TRUE") ELSE String("FALSE") END
END Boolean;

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
