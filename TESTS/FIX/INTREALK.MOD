MODULE Intrealk;
(* Explicit cast REAL(i) is accepted (positive control). *)
VAR
  r: REAL;
  i: INTEGER;
BEGIN
  i := 5;
  r := REAL(i);
  IF r > 0.0 THEN END
END Intrealk.
