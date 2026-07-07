MODULE Dead8;
(* CASE label referencing a constant counts the constant as read. *)
CONST
  K = 5;
PROCEDURE Run*;
VAR
  i: INTEGER;
BEGIN
  i := 5;
  CASE i OF
    K: i := 1
  | 6: i := 2
  END
END Run;
END Dead8.
