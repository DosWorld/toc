MODULE Tdispadr;
VAR addr: SYSTEM.ADDRESS; n: INTEGER;
BEGIN n := 4; NEW(addr, n); DISPOSE(addr) END Tdispadr.
