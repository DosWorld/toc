MODULE Inlexit;
(* Runtime test of INLINE statement: execute a benign byte sequence
   (NOPs) inside a procedure body, then exit normally.  Errorlevel 0
   confirms the procedure body executed past the INLINE bytes without
   crashing — i.e. the bytes were emitted in a way the CPU accepts AND
   the surrounding prologue/epilogue still balances the stack.

   No CD20 / no manual INT 21h AH=4Ch — exit happens through the standard
   entry-stub path (RETF → SYSTEM_DONE → INT 21h AH=49h free heap then
   AH=4Ch with err_code=0). *)
PROCEDURE Run*;
BEGIN
  INLINE(090H, 090H, 090H, 090H, 090H)
END Run;
END Inlexit.
