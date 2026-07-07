MODULE Dead7;
(* RETURN value counts variable as read. *)
PROCEDURE F(): INTEGER;
VAR
  used: INTEGER;
BEGIN
  used := 42;
  RETURN used
END F;
PROCEDURE Run*;
BEGIN
  IF F() = 42 THEN END
END Run;
END Dead7.
