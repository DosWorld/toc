MODULE Usebig;
(* Regression for finding 2.2: DefRead retyped every imported CONST as
   INTEGER regardless of magnitude.  Cstbig.Big = 100000 does not fit a
   signed 16-bit INTEGER (max 32767); loading it as INTEGER silently
   truncates to 34464.  Exit code = failures (0 = pass). *)
IMPORT Cstbig;
VAR fails: INTEGER;

PROCEDURE Run*;
BEGIN
  fails := 0;
  IF LONGINT(Cstbig.Big) # 100000 THEN fails := fails + 1 END;
  IF Cstbig.Big <= 32767 THEN fails := fails + 1 END;
  SYSTEM.Halt(fails)
END Run;

END Usebig.
