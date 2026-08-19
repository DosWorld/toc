MODULE Negparen;
(* Regression for the 2026-08-19 §2.2 condition-fusion fix's paren'd-negation
   extension (see DOCS/CODEGEN-SIZE.MD §2.2): `IF ~(expr) THEN` initially only
   fused a BARE `~x` operand; `~(x > 0)` (the negated operand parenthesized)
   fell through to the disarmed ParseFactor path and fully materialized the
   inner comparison before re-testing it — still correct, just not fused.
   The fix recurses through the ARMED ParseCondExpr for the `~(` shape.
   This test exercises correctness (not codegen shape) for every combination
   that could plausibly break if the armed/disarmed handoff were wrong:
   standalone `~(relop)`, `~(a & b)`, `~(a OR b)` inside the parens, WHILE
   with the same shape, and non-branch use (`y := ~(x > 0)`, must still
   materialize a plain BOOLEAN value) to guard against the fast path firing
   somewhere it must not.  Each check SYSTEM.Halt(N)s on failure;
   fall-through = errorlevel 0. *)

PROCEDURE NegParenIf(x: INTEGER): INTEGER;
BEGIN
  IF ~(x > 0) THEN RETURN 1 ELSE RETURN 2 END
END NegParenIf;

PROCEDURE NegParenAnd(a, b: INTEGER): INTEGER;
BEGIN
  IF ~((a > 0) & (b > 0)) THEN RETURN 1 ELSE RETURN 2 END
END NegParenAnd;

PROCEDURE NegParenOr(a, b: INTEGER): INTEGER;
BEGIN
  IF ~((a > 0) OR (b > 0)) THEN RETURN 1 ELSE RETURN 2 END
END NegParenOr;

PROCEDURE NegParenWhile(n: INTEGER): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE ~(i >= n) DO INC(i) END;
  RETURN i
END NegParenWhile;

PROCEDURE NegParenValue(x: INTEGER): BOOLEAN;
  VAR y: BOOLEAN;
BEGIN
  y := ~(x > 0);   (* non-branch use: must still materialize a plain BOOLEAN *)
  RETURN y
END NegParenValue;

PROCEDURE Run*;
BEGIN
  (* standalone ~(relop) *)
  IF NegParenIf(5) # 2 THEN SYSTEM.Halt(1) END;    (* x>0 true, ~true=false -> ELSE *)
  IF NegParenIf(-5) # 1 THEN SYSTEM.Halt(2) END;    (* x>0 false, ~false=true -> THEN *)
  IF NegParenIf(0) # 1 THEN SYSTEM.Halt(3) END;

  (* ~(a & b) *)
  IF NegParenAnd(1, 1) # 2 THEN SYSTEM.Halt(4) END;
  IF NegParenAnd(1, 0) # 1 THEN SYSTEM.Halt(5) END;
  IF NegParenAnd(0, 0) # 1 THEN SYSTEM.Halt(6) END;

  (* ~(a OR b) *)
  IF NegParenOr(0, 0) # 1 THEN SYSTEM.Halt(7) END;
  IF NegParenOr(1, 0) # 2 THEN SYSTEM.Halt(8) END;
  IF NegParenOr(0, 1) # 2 THEN SYSTEM.Halt(9) END;

  (* WHILE ~(relop) DO *)
  IF NegParenWhile(5) # 5 THEN SYSTEM.Halt(10) END;
  IF NegParenWhile(0) # 0 THEN SYSTEM.Halt(11) END;

  (* non-branch value use, must not be affected by the fusion fast path *)
  IF NegParenValue(5) # FALSE THEN SYSTEM.Halt(12) END;
  IF NegParenValue(-5) # TRUE THEN SYSTEM.Halt(13) END

  (* fall through: errorlevel 0 = all passed *)
END Run;

END Negparen.
