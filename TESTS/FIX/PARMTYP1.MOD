MODULE Parmtyp1;
(* Passing REAL where INTEGER formal is expected must be rejected. *)
PROCEDURE F(x: INTEGER); BEGIN END F;
PROCEDURE Run*;
  VAR r: REAL;
BEGIN
  r := 3.5;
  F(r)
END Run;
END Parmtyp1.
