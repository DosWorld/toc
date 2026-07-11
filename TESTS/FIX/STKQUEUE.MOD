(*$M 32768, 0, 0*)(*$D+*)
MODULE Stkqueue;
(* Regression: STACKED system comments must ALL apply.  The scanner once kept
   only a single pending syscomment, so `(*$M ...*)` immediately followed by
   `(*$D+*)` silently lost the $M — every self-hosted TOC.EXE shipped with
   the 8192-byte default stack and 256 KB default heap for months (opt.md §8).
   The mz-sp expectation below fails if the $M is dropped (SP would be 8190). *)
PROCEDURE Run*;
BEGIN
END Run;
END Stkqueue.
