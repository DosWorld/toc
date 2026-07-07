MODULE Intreal3;
(* LONGREAL := LONGINT must be rejected. *)
VAR
  lr: LONGREAL;
  l: LONGINT;
BEGIN
  l := LONGINT(5);
  lr := l
END Intreal3.
