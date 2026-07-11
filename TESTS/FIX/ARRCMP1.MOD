MODULE Arrcmp1;
(* ARRAY OF CHAR = ARRAY OF CHAR (general case, not "") must be rejected:
   this compiler has no string-compare codegen and would otherwise silently
   compare only the first two bytes.  See DOCS/OBERLANG.MD
   §"Known limitations". *)
VAR
  a, b: ARRAY 8 OF CHAR;
  ok: BOOLEAN;
BEGIN
  a[0] := "x"; a[1] := 0X;
  b[0] := "x"; b[1] := 0X;
  ok := a = b
END Arrcmp1.
