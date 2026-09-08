MODULE Caseovl;
(* Overlapping CASE ranges are duplicates too: 3..7 re-uses 3,4,5 from 1..5. *)
VAR x, y: INTEGER;
BEGIN
  CASE x OF
    1..5: y := 1
  | 3..7: y := 2
  ELSE y := 3
  END
END Caseovl.
