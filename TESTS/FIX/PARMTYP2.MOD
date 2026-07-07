MODULE Parmtyp2;
(* Passing INTEGER where REAL formal is expected must be rejected. *)
PROCEDURE F(x: REAL); BEGIN END F;
PROCEDURE Run*;
  VAR i: INTEGER;
BEGIN
  i := 5;
  F(i)
END Run;
END Parmtyp2.
