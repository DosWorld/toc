MODULE Assrtcd;
PROCEDURE Run*;
VAR x: INTEGER;
BEGIN
  x := 1;
  ASSERT(x = 1, 5)
END Run;
END Assrtcd.
