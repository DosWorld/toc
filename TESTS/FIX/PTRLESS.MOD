MODULE Ptrless;
TYPE P = POINTER TO RECORD x: INTEGER END;
VAR a, b: P; r: BOOLEAN;
BEGIN
  NEW(a); NEW(b);
  r := a < b
END Ptrless.
