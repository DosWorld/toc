MODULE Caseok;
(* Companion to CASEDUP/CASEOVL: distinct labels and non-overlapping ranges
   must still compile, so the duplicate check cannot be over-eager. *)
VAR x, y: INTEGER;
BEGIN
  CASE x OF
    1: y := 1
  | 2..5: y := 2
  | 6, 8, 10: y := 3
  ELSE y := 4
  END
END Caseok.
