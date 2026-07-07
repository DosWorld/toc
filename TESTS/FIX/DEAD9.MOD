MODULE Dead9;
(* SYSTEM.ADR(proc) and SYSTEM.ADR(var) count the target as read. *)
PROCEDURE Used;
BEGIN END Used;
PROCEDURE Run*;
VAR
  v: INTEGER;
  a: SYSTEM.ADDRESS;
BEGIN
  v := 1;
  a := SYSTEM.ADR(v);
  a := SYSTEM.ADR(Used);
  IF a = a THEN END
END Run;
END Dead9.
