MODULE Size67a;
CONST
  IntS  = SIZE(INTEGER);
  ByteS = SIZE(BYTE);
  LngS  = SIZE(LONGINT);
  RlS   = SIZE(REAL);
  PtrS  = SIZE(SET);
VAR x: INTEGER;
BEGIN x := IntS; x := ByteS; x := LngS; x := RlS; x := PtrS
END Size67a.
