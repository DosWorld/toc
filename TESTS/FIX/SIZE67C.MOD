MODULE Size67c;
TYPE
  Pt = RECORD x, y: INTEGER END;
  Buf = ARRAY SIZE(Pt) OF INTEGER;
VAR b: Buf;
BEGIN b[0] := 0; b[3] := 0
END Size67c.
