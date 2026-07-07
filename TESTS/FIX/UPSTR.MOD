MODULE Upstr;
(* Verify SYSTEM.UPSTR is stack-balanced and correct.  If UPSTR unbalanced the
   stack, the call sequence around it (a second call + locals) would corrupt
   and crash; reaching errorlevel 0 proves balance. *)
VAR s: ARRAY 16 OF CHAR; t: ARRAY 8 OF CHAR; n: INTEGER;
PROCEDURE Bump(VAR x: INTEGER); BEGIN x := x + 1 END Bump;
PROCEDURE Run*;
BEGIN
  s := "hello.mod";
  SYSTEM.UPSTR(s);
  IF s # "HELLO.MOD" THEN SYSTEM.Halt(1) END;
  (* stack must be balanced: a call right after UPSTR must work *)
  n := 41; Bump(n);
  IF n # 42 THEN SYSTEM.Halt(2) END;
  (* UPSTR on a short buffer with mixed case + non-alpha *)
  t := "aB3z";
  SYSTEM.UPSTR(t);
  IF t # "AB3Z" THEN SYSTEM.Halt(3) END;
  (* call UPSTR twice in a row (each must self-balance) *)
  s := "abc"; SYSTEM.UPSTR(s); SYSTEM.UPSTR(s);
  IF s # "ABC" THEN SYSTEM.Halt(4) END
END Run;
END Upstr.
