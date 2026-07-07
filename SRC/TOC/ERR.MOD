MODULE Err;

IMPORT IO, Files, Strings;

CONST
LERROR* = 1;
LINFO*  = 2;
LWARN*  = 3;
LDEBUG* = 4;

VAR
err      : BOOLEAN;
level    : INTEGER;
errRider : IO.Rider;
outRider : IO.Rider;
outLog   : Files.File;   (* every message (incl. errors) is logged here *)
errLog   : Files.File;   (* errors only *)
logOpen  : BOOLEAN;      (* TRUE between Open and Close *)

(* Open* opens the two log files (output.log = all messages, error.log = errors
   only).  Call once at the start of each tool's Run; Close* at the end.  Safe to
   skip: if not opened, messages still go to the console riders. *)
PROCEDURE Open*;
BEGIN
  logOpen := Files.ReWrite(outLog, "output.log");
  IF logOpen THEN
    IF ~Files.ReWrite(errLog, "error.log") THEN
      Files.Close(outLog); logOpen := FALSE
    END
  END
END Open;

PROCEDURE Close*;
BEGIN
  IF logOpen THEN
    IF ~err THEN Files.SetDeleteOnClose(errLog, TRUE) END;
    Files.Close(outLog); Files.Close(errLog); logOpen := FALSE
  END
END Close;

PROCEDURE CheckLevel(lvl : INTEGER) : BOOLEAN;
BEGIN
  RETURN (level = LERROR) OR (level >= lvl)
END CheckLevel;

PROCEDURE IsDebug*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LDEBUG)
END IsDebug;

PROCEDURE IsInfo*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LINFO)
END IsInfo;

PROCEDURE IsWarn*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LWARN)
END IsWarn;

PROCEDURE SetLevel*(value : INTEGER);
BEGIN
  level := value
END SetLevel;

PROCEDURE HaveErr*():BOOLEAN;
BEGIN
  RETURN err
END HaveErr;

(* ERROR goes to STDERR (and latches); WARN/INFO/DEBUG go to STDOUT.  Every
   emitted message is also appended to output.log; errors also to error.log. *)
PROCEDURE Emit(prefix : ARRAY OF CHAR; VAR msg: ARRAY OF CHAR; toErr: BOOLEAN);
  VAR line: ARRAY 544 OF CHAR;
      rider : POINTER TO IO.Rider;
BEGIN
  Strings.Copy(prefix, line); Strings.Append(msg, line);
  IF toErr THEN rider := SYSTEM.ADR(errRider)
  ELSE rider := SYSTEM.ADR(outRider) END;
  IO.WriteStr(rider^, line); IO.WriteLn(rider^);
  IF logOpen THEN
    Files.WriteLine(outLog, line);
    IF toErr THEN Files.WriteLine(errLog, line) END
  END
END Emit;

PROCEDURE Message(lvl : INTEGER; VAR msg: ARRAY OF CHAR);
BEGIN
  IF err THEN RETURN END;
  IF lvl = LERROR THEN
    Emit("ERROR:", msg, TRUE);
    err := TRUE
  ELSIF (lvl = LINFO) & CheckLevel(LINFO)  THEN
    Emit("INFO:", msg, FALSE)
  ELSIF (lvl = LWARN) & CheckLevel(LWARN) THEN
    Emit("WARN:", msg, FALSE)
  ELSIF (lvl = LDEBUG) & CheckLevel(LDEBUG) THEN
    Emit("DEBUG:", msg, FALSE)
  END
END Message;

PROCEDURE Error*(msg: ARRAY OF CHAR);
BEGIN
  Message(LERROR, msg)
END Error;

PROCEDURE Warn*(msg: ARRAY OF CHAR);
BEGIN
  Message(LWARN, msg)
END Warn;

PROCEDURE Info*(msg: ARRAY OF CHAR);
BEGIN
  Message(LINFO, msg)
END Info;

PROCEDURE Debug*(msg : ARRAY OF CHAR);
BEGIN
  Message(LDEBUG, msg)
END Debug;

PROCEDURE Message2(lvl : INTEGER; VAR msg, arg: ARRAY OF CHAR);
VAR m : ARRAY 512 OF CHAR;
BEGIN
  Strings.Copy(msg, m);
  Strings.Append(arg, m);
  Message(lvl, m)
END Message2;

PROCEDURE Error2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LERROR, msg, arg)
END Error2;

PROCEDURE Info2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LINFO, msg, arg)
END Info2;

PROCEDURE Warn2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LWARN, msg, arg)
END Warn2;

PROCEDURE Debug2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LDEBUG, msg, arg)
END Debug2;

PROCEDURE MessageInFile*(lvl : INTEGER; VAR fname: ARRAY OF CHAR; line : LONGINT; VAR message: ARRAY OF CHAR);
VAR m : ARRAY 512 OF CHAR; lBuf : ARRAY 16 OF CHAR;
BEGIN
  IF err THEN RETURN END;
  IF ~CheckLevel(lvl) THEN RETURN END;
  Strings.Copy(fname, m);
  Strings.Append("(", m);
  Strings.Str(line, lBuf);
  Strings.Append(lBuf, m);
  Strings.Append("): ", m);
  Strings.Append(message, m);
  Message(lvl, m)
END MessageInFile;

PROCEDURE ErrorInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LERROR, fname, line, message)
END ErrorInFile;

PROCEDURE InfoInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LINFO, fname, line, message)
END InfoInFile;

PROCEDURE WarnInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LWARN, fname, line, message)
END WarnInFile;

PROCEDURE DebugInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LDEBUG, fname, line, message)
END DebugInFile;

BEGIN
  IO.StdErr(errRider);
  IO.StdOut(outRider);
  SetLevel(LWARN);
  logOpen := FALSE;
  err := FALSE
END Err.