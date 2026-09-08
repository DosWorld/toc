MODULE Retfnok;
(* Companion to NORETFN: a function that does return, and a proper procedure
   with no RETURN at all, must both still compile. *)
VAR i: INTEGER;
PROCEDURE F(n: INTEGER): INTEGER;
BEGIN
  IF n > 0 THEN RETURN 1 ELSE RETURN 2 END
END F;
PROCEDURE P;
BEGIN
  i := 0
END P;
BEGIN
  P; i := F(1)
END Retfnok.
