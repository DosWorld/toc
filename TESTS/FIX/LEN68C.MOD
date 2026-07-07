MODULE Len68c;
VAR a: ARRAY 8 OF INTEGER;
VAR sel, r: INTEGER;
BEGIN
  sel := 8; r := 0;
  CASE sel OF
    LEN(a):   r := 1
  ELSE r := 99 END
END Len68c.
