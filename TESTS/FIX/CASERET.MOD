MODULE CaseRet;
(* Regression: valueless RETURN as the trailing statement of a non-final
   CASE arm must compile cleanly (see EXAMPLES/TETRIS/BUG.MD). *)
PROCEDURE P(s: INTEGER);
BEGIN
  CASE s OF
    1: RETURN
  | 2:
  ELSE
  END
END P;
BEGIN
  P(1)
END CaseRet.
