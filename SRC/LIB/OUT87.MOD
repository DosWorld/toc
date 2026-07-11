(*$D-*)
MODULE Out87;

IMPORT Out;

(* Open: initialize the Out87 module for output (delegates to Out.Open). *)
PROCEDURE Open*;
BEGIN
    Out.Open
END Open;

(* Char: write a single character to standard output.
   Parameters: ch — the character to write. *)
PROCEDURE Char*(ch: CHAR);
BEGIN
    Out.Char(ch)
END Char;

(* Ln: write a CR/LF line terminator to standard output. *)
PROCEDURE Ln*;
BEGIN
    Out.Ln
END Ln;

(* String: write a NUL-terminated string to standard output.
   Parameters: s — the character array to write (up to the NUL terminator). *)
PROCEDURE String*(s: ARRAY OF CHAR);
BEGIN
    Out.String(s)
END String;

(* Boolean: write "TRUE" or "FALSE" to standard output.
   Parameters: val — the BOOLEAN value to write. *)
PROCEDURE Boolean*(val: BOOLEAN);
BEGIN
    Out.Boolean(val)
END Boolean;

(* Int: write a LONGINT value in decimal, right-justified in a field.
   Parameters: l — the value to write; w — minimum field width (padded with spaces). *)
PROCEDURE Int*(l: LONGINT; w: INTEGER);
BEGIN
    Out.Int(l, w)
END Int;

(* Hex: write an INTEGER value as 4 hex digits, right-justified in a field.
   Parameters: i — the value to write; w — minimum field width (padded with spaces). *)
PROCEDURE Hex*(i: INTEGER; w: INTEGER);
BEGIN
    Out.Hex(i, w)
END Hex;

(* Adr: write a SYSTEM.ADDRESS as segment:offset hex.
   Parameters: p — the address to write. *)
PROCEDURE Adr*(p: SYSTEM.ADDRESS);
BEGIN
  Out.Adr(p);
END Adr;

PROCEDURE Real*(x: REAL; w: INTEGER);
(* Print a REAL value in simple decimal format.
   Uses sign + integer part (via FLOOR) + 6 fractional digits.
   Limited to values whose integer part fits in INTEGER (-32768..32767).
   Parameters: x — the REAL value to write; w — minimum field width (padded with spaces). *)
VAR
  neg: BOOLEAN;
  ipart: INTEGER;
  frac: REAL;
  digits: ARRAY 7 OF INTEGER;
  i: INTEGER;
  d: INTEGER;
  needed: INTEGER;
BEGIN
  neg := FALSE;
  IF x < 0.0 THEN
    neg := TRUE;
    x := -x
  END;
  ipart := FLOOR(x);
  frac := x - REAL(ipart);  (* fractional part *)
  (* Collect 6 fractional digits *)
  i := 0;
  WHILE i < 6 DO
    frac := frac * 10.0;
    d := FLOOR(frac);
    digits[i] := d;
    frac := frac - REAL(d);
    INC(i)
  END;
  (* Count chars needed: sign + ipart + '.' + 6 digits *)
  needed := 8;  (* '.', 6 digits, at least 1 for ipart *)
  IF neg THEN INC(needed) END;
  IF ipart >= 10000 THEN INC(needed, 4)
  ELSIF ipart >= 1000 THEN INC(needed, 3)
  ELSIF ipart >= 100 THEN INC(needed, 2)
  ELSIF ipart >= 10 THEN INC(needed)
  END;
  (* Pad with spaces *)
  WHILE w > needed DO Char(" "); DEC(w) END;
  IF neg THEN Char("-") END;
  Int(ipart, 0);
  Char(".");
  i := 0;
  WHILE i < 6 DO
    Char(CHR(ORD("0") + digits[i]));
    INC(i)
  END
END Real;

PROCEDURE LongReal*(x: LONGREAL; w: INTEGER);
(* Print a LONGREAL value — delegates to REAL for now.
   Parameters: x — the LONGREAL value to write; w — minimum field width (padded with spaces). *)
VAR r: REAL;
BEGIN
  r := REAL(x);
  Real(r, w)
END LongReal;

(* HexDump: write a classic hex+ASCII dump of a memory block, 16 bytes per line.
   Parameters: buf — the memory block to dump; len — number of bytes to dump. *)
PROCEDURE HexDump*(VAR buf; len: WORD);
BEGIN
  Out.HexDump(buf, len)
END HexDump;

END Out87.
