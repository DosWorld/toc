(*$D-*)
MODULE Out87;

IMPORT Out;

PROCEDURE Open*;
BEGIN
    Out.Open
END Open;

PROCEDURE Char*(ch: CHAR);
BEGIN
    Out.Char(ch)
END Char;

PROCEDURE Ln*;
BEGIN
    Out.Ln
END Ln;

PROCEDURE String*(s: ARRAY OF CHAR);
BEGIN
    Out.String(s)
END String;

PROCEDURE Boolean*(val: BOOLEAN);
BEGIN
    Out.Boolean(val)
END Boolean;

PROCEDURE Int*(l: LONGINT; w: INTEGER);
BEGIN
    Out.Int(l, w)
END Int;

PROCEDURE Hex*(i: INTEGER; w: INTEGER);
BEGIN
    Out.Hex(i, w)
END Hex;

PROCEDURE Adr*(p: SYSTEM.ADDRESS);
BEGIN
  Out.Adr(p);
END Adr;

PROCEDURE Real*(x: REAL; w: INTEGER);
(* Print a REAL value in simple decimal format.
   Uses sign + integer part (via FLOOR) + 6 fractional digits.
   Limited to values whose integer part fits in INTEGER (-32768..32767). *)
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
(* Print a LONGREAL value — delegates to REAL for now. *)
VAR r: REAL;
BEGIN
  r := REAL(x);
  Real(r, w)
END LongReal;

PROCEDURE HexDump*(VAR buf; len: WORD);
BEGIN
  Out.HexDump(buf, len)
END HexDump;

END Out87.
