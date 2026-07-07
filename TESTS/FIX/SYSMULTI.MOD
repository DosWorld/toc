MODULE Sysmulti;
VAR x, y: INTEGER; p: POINTER TO INTEGER;
BEGIN
  p := SYSTEM.ADR(x); p^ := 1;
  p := SYSTEM.ADR(y); p^ := 2
END Sysmulti.
