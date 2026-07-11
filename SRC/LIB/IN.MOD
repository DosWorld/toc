(*$R-*)(*$D-*)
MODULE In;

VAR
  Done*: BOOLEAN;
  ch: CHAR;

PROCEDURE ReadChar(VAR c: CHAR);
VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 0100H;
  SYSTEM.Intr(21H, r);
  c := CHR(r.AX MOD 100H);
END ReadChar;

PROCEDURE Skip;
BEGIN
  WHILE Done & (ch <= " ") DO
    IF ch = 0X THEN
      Done := FALSE
    ELSE
      ReadChar(ch)
    END
  END
END Skip;

(* Open: initialize the In module and prime the lookahead character
   from standard input; sets Done to TRUE. *)
PROCEDURE Open*;
BEGIN
  Done := TRUE;
  ReadChar(ch)
END Open;

(* Char: read the next character from standard input.
   Parameters: c — receives the character read.
   Result: none directly; sets Done to FALSE at end of input (via c). *)
PROCEDURE Char*(VAR c: CHAR);
BEGIN
  IF Done THEN
    c := ch;
    IF c = 0X THEN Done := FALSE ELSE ReadChar(ch) END
  END
END Char;

(* Int: skip leading whitespace and read a signed decimal INTEGER.
   Parameters: i — receives the parsed value.
   Result: none directly; sets Done to FALSE if no valid integer is found. *)
PROCEDURE Int*(VAR i: INTEGER);
VAR 
  sgn, val: INTEGER;
BEGIN
  Skip;
  IF Done THEN
    IF ch = "-" THEN
      sgn := -1; ReadChar(ch)
    ELSIF ch = "+" THEN
      sgn := 1; ReadChar(ch)
    ELSE
      sgn := 1
    END;
    
    IF (ch >= "0") & (ch <= "9") THEN
      val := 0;
      REPEAT
        val := val * 10 + (ORD(ch) - ORD("0"));
        ReadChar(ch)
      UNTIL ~(Done & (ch >= "0") & (ch <= "9"));
      i := sgn * val
    ELSE
      Done := FALSE
    END
  END
END Int;

(* LongInt: skip leading whitespace and read a signed decimal LONGINT.
   Parameters: l — receives the parsed value.
   Result: none directly; sets Done to FALSE if no valid integer is found. *)
PROCEDURE LongInt*(VAR l: LONGINT);
VAR 
  sgn: LONGINT;
  val: LONGINT;
BEGIN
  Skip;
  IF Done THEN
    IF ch = "-" THEN
      sgn := -1; ReadChar(ch)
    ELSE
      sgn := 1
    END;
    
    IF (ch >= "0") & (ch <= "9") THEN
      val := 0;
      REPEAT
        val := val * 10 + (ORD(ch) - ORD("0"));
        ReadChar(ch)
      UNTIL ~(Done & (ch >= "0") & (ch <= "9"));
      l := sgn * val
    ELSE
      Done := FALSE
    END
  END
END LongInt;

(* String: skip leading whitespace and read a whitespace-delimited token.
   Parameters: s — receives the NUL-terminated token (truncated to fit).
   Result: none directly; sets Done to FALSE if no token is found. *)
PROCEDURE String*(VAR s: ARRAY OF CHAR);
VAR i: INTEGER;
BEGIN
  Skip;
  i := 0;
  IF Done THEN
    WHILE Done & (ch > " ") & (i < LEN(s) - 1) DO
      s[i] := ch; INC(i);
      ReadChar(ch)
    END;
    s[i] := 0X;
    IF i = 0 THEN Done := FALSE END
  END
END String;

BEGIN
  Done := FALSE;
  ch := 0X
END In.
