MODULE Divdbg1;
VAR x: INTEGER;
PROCEDURE Run*;
BEGIN
  x := (-7) DIV 3;
  SYSTEM.Halt(x)
END Run;
END Divdbg1.
