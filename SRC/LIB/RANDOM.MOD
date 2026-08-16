(*$R-,D-,A-*)
MODULE Random;

(* Pseudo-random generator via Marsaglia's 32-bit xorshift.
   The xorshift32 recurrence (shifts 13/17/5) has full period
   2^32-1 over all non-zero states;
   Init seeds from the BIOS tick counter. *)

VAR myseed : LONGINT;

PROCEDURE Next(VAR seed : LONGINT);
BEGIN
    seed := SYSTEM.XOR(seed, SYSTEM.LSL(seed, 13));
    seed := SYSTEM.XOR(seed, SYSTEM.LSR(seed, 17));
    seed := SYSTEM.XOR(seed, SYSTEM.LSL(seed, 5))
END Next;

PROCEDURE SeedValue*(VAR seed : LONGINT; max : WORD) : WORD;
BEGIN
    IF max = 0 THEN RETURN 0 END;
    Next(seed); RETURN WORD(seed) MOD max
END SeedValue;

PROCEDURE SeedByte*(VAR seed : LONGINT) : BYTE;
BEGIN
    Next(seed); RETURN BYTE(seed)
END SeedByte;

PROCEDURE Value*(max : WORD) : WORD;
BEGIN
    RETURN SeedValue(myseed, max)
END Value;

PROCEDURE Byte* : BYTE;
BEGIN
    RETURN SeedByte(myseed)
END Byte;

PROCEDURE Seed* : LONGINT;
BEGIN
    RETURN myseed
END Seed;

PROCEDURE Init;
TYPE PLONGINT = POINTER TO LONGINT;
VAR t : PLONGINT;
BEGIN
    t := SYSTEM.PTR(SYSTEM.Seg0040(), 006CH);
    myseed := t^
END Init;

BEGIN
    Init
END Random.
