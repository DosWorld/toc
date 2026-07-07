MODULE DbgOff;
(* Debug-info fixture: NO $D directive (default off) — its .om must still
   carry a DBGOFF.DBG member, but as a 0-byte file (uniform archive layout;
   emptiness = "no debug info").  om-no-file passes because a 0-byte member
   has no extractable content; the size-0 presence is asserted by
   tests/test_dbg.sh via olib list. *)

VAR x: INTEGER;

PROCEDURE Run*;
BEGIN
  x := 1;
  SYSTEM.Halt(0)
END Run;

END DbgOff.
