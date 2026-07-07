MODULE Typlssok;
VAR g: INTEGER;
PROCEDURE SetViaAddr(VAR p; val: INTEGER);
VAR ip: POINTER TO INTEGER;
BEGIN ip := p; ip^ := val END SetViaAddr;
PROCEDURE Test;
BEGIN SetViaAddr(g, 42) END Test;
END Typlssok.
