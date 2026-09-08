MODULE Noretfn;
(* A function with no RETURN falls off the end into the epilogue and the
   caller reads whatever is in DX:AX.  Must be rejected. *)
VAR i: INTEGER;
PROCEDURE F(): INTEGER;
  VAR x: INTEGER;
BEGIN
  x := 1
END F;
BEGIN
  i := F()
END Noretfn.
