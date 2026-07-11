MODULE Longbool;
(* Regression: short-circuit `&`/`OR` must use NEAR jumps over the RHS emit.
   The RHS of one `&`/`OR` can emit arbitrarily much code; with a short Jcc
   the rel8 displacement wraps past a 127-byte span and jumps backward into
   the middle of an instruction (this broke self-hosting — the compiler's own
   PSTMT assignment type-check chain spans 142 bytes; see opt.md §8).
   Each `&`/`OR` RHS below is a long call chain, so every arm's skip jump
   spans several hundred bytes.  Exits via SYSTEM.Halt(N) on failure. *)

VAR calls: INTEGER;

PROCEDURE Eq(a, b: INTEGER): BOOLEAN;
BEGIN INC(calls); RETURN a = b END Eq;

PROCEDURE Run*;
  VAR r: BOOLEAN;
BEGIN
  (* & with a huge RHS (long OR chain): LHS TRUE -> RHS must run and win *)
  calls := 0;
  r := Eq(1, 1) & (Eq(2, 99) OR Eq(3, 99) OR Eq(4, 99) OR Eq(5, 99) OR
                   Eq(6, 99) OR Eq(7, 99) OR Eq(8, 99) OR Eq(9, 99) OR
                   Eq(10, 99) OR Eq(11, 99) OR Eq(12, 99) OR Eq(13, 13));
  IF ~r THEN SYSTEM.Halt(1) END;
  IF calls # 13 THEN SYSTEM.Halt(2) END;

  (* & with a huge RHS: LHS FALSE -> the whole RHS chain must be skipped
     (the false-jump spans the entire OR chain's code) *)
  calls := 0;
  r := Eq(1, 2) & (Eq(2, 99) OR Eq(3, 99) OR Eq(4, 99) OR Eq(5, 99) OR
                   Eq(6, 99) OR Eq(7, 99) OR Eq(8, 99) OR Eq(9, 99) OR
                   Eq(10, 99) OR Eq(11, 99) OR Eq(12, 99) OR Eq(13, 13));
  IF r THEN SYSTEM.Halt(3) END;
  IF calls # 1 THEN SYSTEM.Halt(4) END;

  (* OR with a huge RHS (long & chain): LHS TRUE -> RHS fully skipped *)
  calls := 0;
  r := Eq(1, 1) OR (Eq(2, 2) & Eq(3, 3) & Eq(4, 4) & Eq(5, 5) &
                    Eq(6, 6) & Eq(7, 7) & Eq(8, 8) & Eq(9, 9) &
                    Eq(10, 10) & Eq(11, 11) & Eq(12, 12) & Eq(13, 13));
  IF ~r THEN SYSTEM.Halt(5) END;
  IF calls # 1 THEN SYSTEM.Halt(6) END;

  (* OR with a huge RHS: LHS FALSE -> RHS chain must run to completion *)
  calls := 0;
  r := Eq(1, 2) OR (Eq(2, 2) & Eq(3, 3) & Eq(4, 4) & Eq(5, 5) &
                    Eq(6, 6) & Eq(7, 7) & Eq(8, 8) & Eq(9, 9) &
                    Eq(10, 10) & Eq(11, 11) & Eq(12, 12) & Eq(13, 13));
  IF ~r THEN SYSTEM.Halt(7) END;
  IF calls # 13 THEN SYSTEM.Halt(8) END
END Run;

END Longbool.
