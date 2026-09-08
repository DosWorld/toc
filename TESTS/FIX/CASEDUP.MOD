MODULE Casedup;
(* Oberon-07 requires CASE labels to be distinct: a duplicate single label
   must be rejected.  Before 2026-09-08 this compiled silently and the first
   matching arm simply won. *)
VAR x, y: INTEGER;
BEGIN
  CASE x OF
    1: y := 1
  | 1: y := 2
  ELSE y := 3
  END
END Casedup.
