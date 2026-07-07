MODULE Parmtypk;
(* Open-array formal accepts any same-element-type fixed-array (positive control). *)
PROCEDURE F(a: ARRAY OF INTEGER): INTEGER;
BEGIN
  RETURN LEN(a)
END F;
PROCEDURE Run*;
  VAR a5: ARRAY 5 OF INTEGER;
      a20: ARRAY 20 OF INTEGER;
BEGIN
  IF F(a5) # 5 THEN END;
  IF F(a20) # 20 THEN END
END Run;
END Parmtypk.
