MODULE Divmodfl;
(* Runtime test: DIV/MOD must be floored (Oberon-07 spec) consistently across
   all three codegen paths -- const-folded, power-of-two strength-reduced,
   and generic runtime division -- for INTEGER, WORD, and LONGINT.  Floored:
   quotient rounds toward -infinity; remainder takes the divisor's sign.
   Each check exits via SYSTEM.Halt(N) on failure (errorlevel N). *)
IMPORT Strings;

VAR
  vi, wi: INTEGER;
  vl, wl: LONGINT;

PROCEDURE Check(n: LONGINT; expect: ARRAY OF CHAR; haltId: INTEGER);
  VAR buf: ARRAY 16 OF CHAR; i: INTEGER; eq: BOOLEAN;
BEGIN
  Strings.Str(n, buf);
  i := 0; eq := TRUE;
  WHILE (buf[i] # 0X) OR (expect[i] # 0X) DO
    IF buf[i] # expect[i] THEN eq := FALSE END;
    INC(i)
  END;
  IF ~eq THEN SYSTEM.Halt(haltId) END
END Check;

PROCEDURE Run*;
BEGIN
  (* ---- CONST-folded (compile-time), generic divisor ---- *)
  IF (-7) DIV 3 # -3 THEN SYSTEM.Halt(1) END;
  IF (-7) MOD 3 # 2 THEN SYSTEM.Halt(2) END;
  IF 7 DIV (-3) # -3 THEN SYSTEM.Halt(3) END;
  IF 7 MOD (-3) # -2 THEN SYSTEM.Halt(4) END;
  IF (-7) DIV (-3) # 2 THEN SYSTEM.Halt(5) END;
  IF (-7) MOD (-3) # -1 THEN SYSTEM.Halt(6) END;

  (* ---- CONST-folded, power-of-two divisor (strength-reduction shape) ---- *)
  IF (-7) DIV 2 # -4 THEN SYSTEM.Halt(7) END;
  IF (-7) MOD 2 # 1 THEN SYSTEM.Halt(8) END;

  (* ---- runtime INTEGER, generic divisor (loaded into a var, not const) ---- *)
  vi := -7; wi := 3;
  IF vi DIV wi # -3 THEN SYSTEM.Halt(9) END;
  IF vi MOD wi # 2 THEN SYSTEM.Halt(10) END;
  vi := 7; wi := -3;
  IF vi DIV wi # -3 THEN SYSTEM.Halt(11) END;
  IF vi MOD wi # -2 THEN SYSTEM.Halt(12) END;
  vi := -7; wi := -3;
  IF vi DIV wi # 2 THEN SYSTEM.Halt(13) END;
  IF vi MOD wi # -1 THEN SYSTEM.Halt(14) END;

  (* ---- runtime INTEGER, power-of-two divisor (SAR/AND-mask path) ---- *)
  vi := -7; wi := 2;
  IF vi DIV wi # -4 THEN SYSTEM.Halt(15) END;
  IF vi MOD wi # 1 THEN SYSTEM.Halt(16) END;

  (* ---- runtime LONGINT, generic divisor (SYSTEM_S32DIV/S32MOD) ---- *)
  vl := LONGINT(-7); wl := LONGINT(3);
  IF vl DIV wl # LONGINT(-3) THEN SYSTEM.Halt(17) END;
  IF vl MOD wl # LONGINT(2) THEN SYSTEM.Halt(18) END;
  vl := LONGINT(7); wl := LONGINT(-3);
  IF vl DIV wl # LONGINT(-3) THEN SYSTEM.Halt(19) END;
  IF vl MOD wl # LONGINT(-2) THEN SYSTEM.Halt(20) END;
  vl := LONGINT(-7); wl := LONGINT(-3);
  IF vl DIV wl # LONGINT(2) THEN SYSTEM.Halt(21) END;
  IF vl MOD wl # LONGINT(-1) THEN SYSTEM.Halt(22) END;

  (* ---- runtime LONGINT, exact division (remainder == 0, no fixup needed) ---- *)
  vl := LONGINT(-9); wl := LONGINT(3);
  IF vl DIV wl # LONGINT(-3) THEN SYSTEM.Halt(23) END;
  IF vl MOD wl # LONGINT(0) THEN SYSTEM.Halt(24) END;

  (* ---- runtime LONGINT, both positive (must match truncating) ---- *)
  vl := LONGINT(7); wl := LONGINT(3);
  IF vl DIV wl # LONGINT(2) THEN SYSTEM.Halt(25) END;
  IF vl MOD wl # LONGINT(1) THEN SYSTEM.Halt(26) END;

  (* ---- Strings.Str with negative LONGINT (regression for the Str rewrite) ---- *)
  Check(LONGINT(-123), "-123", 27);
  Check(LONGINT(-1), "-1", 28);
  Check(LONGINT(0), "0", 29);
  Check(LONGINT(123), "123", 30);
  Check(LONGINT(-2147483647) - LONGINT(1), "-2147483648", 31)

  (* fall through: errorlevel 0 means all tests passed *)
END Run;

END Divmodfl.
