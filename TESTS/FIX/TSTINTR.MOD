MODULE Tstintr;
VAR r: SYSTEM.Registers;
BEGIN SYSTEM.Intr(21H, r) END Tstintr.
