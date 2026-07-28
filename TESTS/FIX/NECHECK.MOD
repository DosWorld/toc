MODULE NECHECK;
(* NE (/CP) output smoke fixture: a trivial program with one global (a DATA
   reference from CODE, so the DS-reload produces at least one NE BASE reloc)
   and an exported entry procedure.  Linked with /CP it yields a New
   Executable whose header/segment table rdfgrep inspects. *)
VAR counter: INTEGER;

PROCEDURE Run*;
BEGIN
  counter := 1;
  WHILE counter < 10 DO counter := counter + 1 END
END Run;

END NECHECK.
