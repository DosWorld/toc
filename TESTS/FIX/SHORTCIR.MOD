MODULE Shortcir;
(* Runtime test: `&` and `OR` must short-circuit (Oberon-07 spec): `p & q` ==
   `IF p THEN q ELSE FALSE`; `p OR q` == `IF p THEN TRUE ELSE q`.  RhsCalls
   counts actual evaluations of the RHS side-effecting function so each check
   can assert whether it ran.  A guarded-divide check also confirms a
   short-circuited unsafe RHS (division by a guarded-zero divisor) never
   traps.  Each check exits via SYSTEM.Halt(N) on failure (errorlevel N). *)

VAR rhsCalls: INTEGER;

PROCEDURE TrueRhs(): BOOLEAN;
BEGIN INC(rhsCalls); RETURN TRUE END TrueRhs;

PROCEDURE FalseRhs(): BOOLEAN;
BEGIN INC(rhsCalls); RETURN FALSE END FalseRhs;

PROCEDURE Run*;
  VAR n, x: INTEGER; r: BOOLEAN;
BEGIN
  (* ---- & : LHS FALSE must skip RHS entirely ---- *)
  rhsCalls := 0;
  r := FALSE & TrueRhs();
  IF rhsCalls # 0 THEN SYSTEM.Halt(1) END;
  IF r THEN SYSTEM.Halt(2) END;

  (* ---- & : LHS TRUE must evaluate RHS and use its value ---- *)
  rhsCalls := 0;
  r := TRUE & TrueRhs();
  IF rhsCalls # 1 THEN SYSTEM.Halt(3) END;
  IF ~r THEN SYSTEM.Halt(4) END;

  rhsCalls := 0;
  r := TRUE & FalseRhs();
  IF rhsCalls # 1 THEN SYSTEM.Halt(5) END;
  IF r THEN SYSTEM.Halt(6) END;

  (* ---- OR : LHS TRUE must skip RHS entirely ---- *)
  rhsCalls := 0;
  r := TRUE OR FalseRhs();
  IF rhsCalls # 0 THEN SYSTEM.Halt(7) END;
  IF ~r THEN SYSTEM.Halt(8) END;

  (* ---- OR : LHS FALSE must evaluate RHS and use its value ---- *)
  rhsCalls := 0;
  r := FALSE OR TrueRhs();
  IF rhsCalls # 1 THEN SYSTEM.Halt(9) END;
  IF ~r THEN SYSTEM.Halt(10) END;

  rhsCalls := 0;
  r := FALSE OR FalseRhs();
  IF rhsCalls # 1 THEN SYSTEM.Halt(11) END;
  IF r THEN SYSTEM.Halt(12) END;

  (* ---- classic guarded-divide idiom: must never trap ---- *)
  n := 0;
  IF (n # 0) & (100 DIV n > 0) THEN SYSTEM.Halt(13) END;

  n := 0;
  x := 5;
  IF (n = 0) OR (x DIV n > 0) THEN
    (* n=0 short-circuits OR to TRUE without evaluating x DIV n *)
  ELSE
    SYSTEM.Halt(14)
  END;

  (* ---- chained & : short-circuits at the first FALSE ---- *)
  rhsCalls := 0;
  r := FALSE & TrueRhs() & TrueRhs();
  IF rhsCalls # 0 THEN SYSTEM.Halt(15) END;

  (* ---- chained OR : short-circuits at the first TRUE ---- *)
  rhsCalls := 0;
  r := TRUE OR FalseRhs() OR FalseRhs();
  IF rhsCalls # 0 THEN SYSTEM.Halt(16) END;

  (* ---- non-short-circuit sanity: both operands variable, no early exit ---- *)
  rhsCalls := 0;
  r := TrueRhs() & TrueRhs();
  IF rhsCalls # 2 THEN SYSTEM.Halt(17) END;
  IF ~r THEN SYSTEM.Halt(18) END

  (* fall through: errorlevel 0 means all tests passed *)
END Run;

END Shortcir.
