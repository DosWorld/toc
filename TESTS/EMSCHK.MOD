MODULE EMSCHK;
(* Standalone diagnostic: exercises EMS.mod primitives directly, then
   Files.ReWriteTemp end-to-end.  Prints PASS/FAIL lines; no Test framework,
   no manifest wiring - just run the .exe and read the output. *)

IMPORT Out, EMS, Files;

CONST N = 256;

VAR
  pass, fail: INTEGER;

PROCEDURE Check(cond: BOOLEAN; msg: ARRAY OF CHAR);
BEGIN
  IF cond THEN
    Out.String("PASS "); Out.String(msg); Out.Ln; INC(pass)
  ELSE
    Out.String("FAIL "); Out.String(msg); Out.Ln; INC(fail)
  END
END Check;

PROCEDURE Pat(i: WORD): BYTE;
BEGIN
  RETURN BYTE((i * WORD(7) + WORD(3)) MOD WORD(251))
END Pat;

PROCEDURE CheckEMS;
  VAR handle: WORD; ok: BOOLEAN; i: WORD;
      src, dst: ARRAY N OF BYTE; allMatch: BOOLEAN;
BEGIN
  Out.String("EMS.Present() = "); Out.Int(ORD(EMS.Present()), 0); Out.Ln;
  IF ~EMS.Present() THEN
    Out.String("EMS driver not detected, skipping EMS.mod checks"); Out.Ln;
    RETURN
  END;

  ok := EMS.Alloc(16, handle);
  Check(ok, "EMS.Alloc(16KB)");
  IF ~ok THEN RETURN END;

  FOR i := 0 TO N - 1 DO src[i] := Pat(i); dst[i] := 0 END;

  ok := EMS.CopyToEMS(src[0], handle, 0, N);
  Check(ok, "EMS.CopyToEMS");
  IF ok THEN
    ok := EMS.CopyToDos(handle, 0, dst[0], N);
    Check(ok, "EMS.CopyToDos")
  END;

  allMatch := TRUE;
  FOR i := 0 TO N - 1 DO
    IF dst[i] # src[i] THEN allMatch := FALSE END
  END;
  Check(allMatch, "EMS copy roundtrip bytes match");

  ok := EMS.Free(handle);
  Check(ok, "EMS.Free")
END CheckEMS;

PROCEDURE CheckFilesTemp;
  VAR f: Files.File; ok: BOOLEAN; i: WORD; nw, nr: WORD;
      buf: ARRAY 1 OF BYTE; allMatch: BOOLEAN;
BEGIN
  ok := Files.ReWriteTemp(f);
  Check(ok, "Files.ReWriteTemp");
  IF ~ok THEN RETURN END;

  i := 0;
  WHILE i < N DO
    buf[0] := Pat(i);
    nw := Files.BlockWrite(f, buf[0], 1);
    IF nw # WORD(1) THEN i := N + 1 ELSE INC(i) END
  END;
  Check(i = N, "Files temp write loop completed");
  Check(Files.Position(f) = LONGINT(N), "Files temp position after write");

  Files.Seek(f, 0);
  Check(Files.Position(f) = LONGINT(0), "Files temp seek to 0");

  i := 0; allMatch := TRUE;
  WHILE i < N DO
    nr := Files.BlockRead(f, buf[0], 1);
    IF nr # WORD(1) THEN allMatch := FALSE
    ELSIF buf[0] # Pat(i) THEN allMatch := FALSE
    END;
    INC(i)
  END;
  Check(allMatch, "Files temp readback bytes match");

  Files.Close(f)
END CheckFilesTemp;

PROCEDURE Run*;
BEGIN
  pass := 0; fail := 0;
  CheckEMS;
  CheckFilesTemp;
  Out.String("TOTAL pass="); Out.Int(pass, 0);
  Out.String(" fail="); Out.Int(fail, 0); Out.Ln
END Run;

END EMSCHK.
