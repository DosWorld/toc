MODULE Idxcomp;
(* Regression for the 2026-08-19 §2.7 constant-index-fold bug (see
   DOCS/CODEGEN-SIZE.MD): a non-constant COMPOUND array index expression
   (e.g. buf[i+j], as opposed to a bare variable index buf[i]) was
   corrupted by the fold's "parse index first, decide constant-ness"
   ordering -- ParseExpression for a compound expression like i+j emits
   real code eagerly and leaves the result in AX, which the immediately
   following CgLoadAddrItem call then clobbered before the index value
   was ever consumed.  A bare-variable index (buf[i]) did NOT trigger
   this, since a plain local/global reference stays lazily unmaterialized
   until CgLoadItem -- only a compound expression that forces early
   materialization exposed the bug.  Each check SYSTEM.Halt(N)s on
   failure; fall-through = errorlevel 0. *)

VAR
  buf: ARRAY 64 OF BYTE;
  words: ARRAY 16 OF INTEGER;

PROCEDURE Run*;
  VAR i, j: INTEGER;
BEGIN
  (* --- BYTE array, compound index i+j --- *)
  FOR i := 0 TO 63 DO buf[i] := BYTE(0) END;
  buf[10] := BYTE(42);
  buf[20] := BYTE(99);

  i := 7; j := 3;
  IF INTEGER(buf[i+j]) # 42 THEN SYSTEM.Halt(1) END;   (* i+j = 10 *)

  i := 15; j := 5;
  IF INTEGER(buf[i+j]) # 99 THEN SYSTEM.Halt(2) END;   (* i+j = 20 *)

  i := 0; j := 0;
  IF INTEGER(buf[i+j]) # 0 THEN SYSTEM.Halt(3) END;    (* i+j = 0 *)

  (* store through a compound index too *)
  i := 4; j := 4;
  buf[i+j] := BYTE(77);
  IF INTEGER(buf[8]) # 77 THEN SYSTEM.Halt(4) END;

  (* neighbours must stay untouched *)
  IF INTEGER(buf[9]) # 0 THEN SYSTEM.Halt(5) END;
  IF INTEGER(buf[7]) # 0 THEN SYSTEM.Halt(6) END;

  (* --- INTEGER (2-byte) array, compound index i+j*2 --- *)
  FOR i := 0 TO 15 DO words[i] := 0 END;
  words[5] := 555;
  words[11] := 1111;

  i := 2; j := 3;
  IF words[i+j] # 555 THEN SYSTEM.Halt(7) END;         (* i+j = 5 *)

  i := 6; j := 5;
  IF words[i+j] # 1111 THEN SYSTEM.Halt(8) END;        (* i+j = 11 *)

  i := 1; j := 2;
  words[i+j] := 333;                                    (* i+j = 3 *)
  IF words[3] # 333 THEN SYSTEM.Halt(9) END;
  IF words[2] # 0 THEN SYSTEM.Halt(10) END;
  IF words[4] # 0 THEN SYSTEM.Halt(11) END

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Idxcomp.
