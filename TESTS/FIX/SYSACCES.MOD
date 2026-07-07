MODULE Sysacces;
VAR x: INTEGER; p: POINTER TO INTEGER;
BEGIN
  p := SYSTEM.ADR(x); p^ := 42
END Sysacces.
