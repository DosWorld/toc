MODULE Rorcl;
(* Runtime regression for the variable-count (CL) 32-bit shift emitters,
   rewritten JCXZ/LOOP-free 2026-07-17 — including the CgRor32Cl fix (the
   old sequence tested the wrong flag and jumped mid-instruction) — plus
   the deterministic-FALSE guard for `x IN s` with x >= 16.
   All counts live in a VAR so the compiler takes the CL paths, not the
   constant-immediate paths. *)
VAR n, k: INTEGER; v: LONGINT; s: SET;

PROCEDURE Run*;
BEGIN
  n := 1;
  v := SYSTEM.ROR(LONGINT(80000001H), n);
  ASSERT(v = LONGINT(0C0000000H));
  n := 4;
  v := SYSTEM.ROR(LONGINT(10H), n);
  ASSERT(v = LONGINT(1));
  n := 3;
  v := SYSTEM.LSL(LONGINT(1), n);
  ASSERT(v = LONGINT(8));
  n := 33;   (* count masked mod 32 -> 1, matching the constant path *)
  v := SYSTEM.LSL(LONGINT(1), n);
  ASSERT(v = LONGINT(2));
  n := 4;
  v := SYSTEM.LSR(LONGINT(80H), n);
  ASSERT(v = LONGINT(8));
  n := 1;
  v := SYSTEM.ASR(LONGINT(-2), n);
  ASSERT(v = LONGINT(-1));
  s := {0, 5, 15};
  k := 5;
  ASSERT(k IN s);
  k := 20;
  ASSERT(~(k IN s))   (* x >= 16: deterministic FALSE on every CPU *)
END Run;

END Rorcl.
