MODULE Main;

IMPORT RdfLoad, Out;

VAR
  Module: RdfLoad.RDFModule;
  p: SYSTEM.ADDRESS;
  testProc: PROCEDURE;

PROCEDURE Run*();
VAR h : INTEGER;
BEGIN
  h := 1;
  Module := RdfLoad.LoadLibrary("TEST.RDF");
  IF Module # NIL THEN
    p := RdfLoad.GetProcAddress(Module, "print_msg");
    IF p = NIL THEN
      Out.String("Exported function not found"); Out.Ln
    ELSE
      h := 0;
      testProc := p;
      testProc
    END;
    RdfLoad.FreeLibrary(Module)
  ELSE
    Out.String("Error while load library!"); Out.Ln
  END;
  SYSTEM.Halt(h)
END Run;

END Main.
