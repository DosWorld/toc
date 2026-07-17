MODULE RFile;

IMPORT Files, Out;

PROCEDURE Run*;
VAR str: ARRAY 512 OF CHAR;
    f  : Files.File;
BEGIN
  IF ~Files.Reset(f, 'RFILE.MOD') THEN
    Out.String("Could not read RFILE.MOD !"); Out.Ln;
    SYSTEM.Halt(1)
  END;
  WHILE ~Files.Eof(f) DO
    IF Files.ReadLine(f, str, LEN(str)) # 0 THEN Out.String(str) END;
    Out.Ln
  END;
  Files.Close(f)
END Run;

END RFile.