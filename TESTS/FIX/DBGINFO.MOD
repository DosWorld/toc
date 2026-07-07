(*$D+*)
MODULE DbgInfo;
(* Debug-info fixture: $D+ module — its .om must carry a non-empty
   DBGINFO.DBG member (module/source/symbol/line records), and linking with
   /G must produce a working .exe with a TDS block (round-trip checked by
   tests/test_dbg.sh via tdinfo). *)

TYPE
  Point = RECORD x, y: INTEGER END;

VAR counter: INTEGER;
    flag:    BOOLEAN;
    origin:  Point;

PROCEDURE Bump;
BEGIN
  counter := counter + 1;
  flag := counter > 0
END Bump;

PROCEDURE Run*;
  VAR fails: INTEGER;

  (* Nested procedure with its own local: exercises SCOPE_RECORD nesting —
     Inner's own P..A..E must not clobber Run's outer scope tracking in the
     linker (a real bug once: the linker tracked "most recent P" as a flat
     scalar, so a nested proc's context overwrote the enclosing proc's
     before the enclosing proc's own scope-end was reached). *)
  PROCEDURE Inner(x: INTEGER): INTEGER;
    VAR doubled: INTEGER;
  BEGIN
    doubled := x * 2;
    RETURN doubled
  END Inner;

BEGIN
  fails := 0;
  counter := 0;
  origin.x := 0; origin.y := 0;
  Bump;
  Bump;
  IF Inner(5) # 10 THEN fails := fails + 1 END;
  IF counter # 2 THEN fails := fails + 1 END;
  IF ~flag THEN fails := fails + 1 END;
  IF (origin.x # 0) OR (origin.y # 0) THEN fails := fails + 1 END;
  SYSTEM.Halt(fails)
END Run;

END DbgInfo.
