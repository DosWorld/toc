MODULE Inclong;
(* Runtime test: INC(LONGINT_var) must carry into the high word so that
   incrementing past 65535 produces 65536, not 0.  Likewise for DEC.
   Each test exits via SYSTEM.Halt(N) on failure (errorlevel N). *)

PROCEDURE Run*;
  VAR x: LONGINT;
BEGIN
  (* INC: low-word overflow must carry into high word. *)
  x := LONGINT(65535);
  INC(x);
  IF x # LONGINT(65536) THEN SYSTEM.Halt(1) END;

  (* INC past 65536+ stays correct. *)
  INC(x);
  IF x # LONGINT(65537) THEN SYSTEM.Halt(2) END;

  (* INC at boundary 131071 -> 131072 (next high-word increment). *)
  x := LONGINT(131071);
  INC(x);
  IF x # LONGINT(131072) THEN SYSTEM.Halt(3) END;

  (* DEC: low-word underflow must borrow from high word. *)
  x := LONGINT(65536);
  DEC(x);
  IF x # LONGINT(65535) THEN SYSTEM.Halt(4) END;

  (* DEC past 65535 stays correct. *)
  DEC(x);
  IF x # LONGINT(65534) THEN SYSTEM.Halt(5) END;

  (* DEC at boundary 131072 -> 131071. *)
  x := LONGINT(131072);
  DEC(x);
  IF x # LONGINT(131071) THEN SYSTEM.Halt(6) END

  (* fall through: errorlevel 0 means all tests passed *)
END Run;
END Inclong.
