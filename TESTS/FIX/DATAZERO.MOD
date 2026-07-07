MODULE DATAZERO;
(* Regression: RDOFF.EmitZero must count the 2-byte module-init guard it
   reserves at data offset 0, so the first string constant lands at data
   offset 2 (not 0) and is not truncated.  Before the fix, EmitZero wrote
   the guard bytes to the data tempfile without advancing dataLen, so
   RdfWrite's BlockCopy(dataLen) dropped the guard and truncated the
   trailing data — every data-segment program (e.g. Out.String) broke. *)
VAR s: ARRAY 16 OF CHAR;
PROCEDURE Run*;
BEGIN s := "HELLO WORLD" END Run;
END DATAZERO.
