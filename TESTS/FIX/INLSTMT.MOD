MODULE Inlstmt;
PROCEDURE Run*;
VAR x: INTEGER;
BEGIN
  x := 1;
  INLINE(0FAH, 0FBH);
  x := x + 2
END Run;
END Inlstmt.
