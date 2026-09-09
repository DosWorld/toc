MODULE Retlong;
(* Compile-level companion to TESTS/TRETLONG.MOD: RETURN of a value narrower
   than the declared LONGINT result type must widen into DX:AX.

   Bug 2026-09-09: PStmt.ParseReturn loaded the value but never widened it, so
   `RETURN -1` from a LONGINT function yielded 65535 (0000FFFF) and even
   `RETURN 1` yielded 000A0001 -- DX was never written.  The runtime answer is
   what matters, so the real assertions live in TRETLONG.MOD; this fixture just
   keeps the shapes compiling. *)
VAR r: LONGINT; w: WORD; b: BYTE; i: INTEGER;
PROCEDURE NegLit(): LONGINT;  BEGIN RETURN -1 END NegLit;
PROCEDURE PosLit(): LONGINT;  BEGIN RETURN 1 END PosLit;
PROCEDURE BigLit(): LONGINT;  BEGIN RETURN -100000 END BigLit;
PROCEDURE FromInt(): LONGINT; BEGIN RETURN i END FromInt;
PROCEDURE FromWord(): LONGINT;BEGIN RETURN w END FromWord;
PROCEDURE FromByte(): LONGINT;BEGIN RETURN b END FromByte;
PROCEDURE InIf(n: INTEGER): LONGINT;
BEGIN IF n > 0 THEN RETURN -1 ELSE RETURN -2 END
END InIf;
BEGIN
  i := -1; w := 0FFFFH; b := 255;
  r := NegLit(); r := PosLit(); r := BigLit();
  r := FromInt(); r := FromWord(); r := FromByte(); r := InIf(1)
END Retlong.
