MODULE Arrcmp2;
(* ARRAY OF CHAR = "" (empty-string literal) IS still accepted: the one
   special-cased array-of-char relop (byte-mask compare).  Regression guard
   for the general-case rejection in Arrcmp1.Mod. *)
VAR
  a: ARRAY 8 OF CHAR;
  ok: BOOLEAN;
BEGIN
  a[0] := 0X;
  ok := a = ""
END Arrcmp2.
