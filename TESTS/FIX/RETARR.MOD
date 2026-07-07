MODULE Retarr;
(* A procedure may not return an array — must be a fatal compile error. *)
TYPE Vec = ARRAY 3 OF INTEGER;
PROCEDURE F(): Vec;
  VAR v: Vec;
BEGIN RETURN v END F;
END Retarr.
