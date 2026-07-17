(*$D-*)
MODULE LogErr;

IMPORT IO, Files, Strings;

CONST
(* Verbosity levels, ordered by increasing verbosity: a message of level lvl
   is emitted when the current level >= lvl.  Errors always print (and latch)
   regardless of level.  Note: LWARN < LINFO so that the default (LINFO)
   shows warnings AND info; /LOG=warn shows warnings but hides info. *)
LERROR* = 100;
LWARN*  = 200;
LINFO*  = 300;
LDEBUG* = 400;

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
   skip: if not opened, messages still go to the console riders.
   Parameters: none.  Result: none. *)
PROCEDURE Open*;
BEGIN
  logOpen := Files.ReWrite(outLog, "OUTPUT.LOG");
  IF logOpen THEN
    IF ~Files.ReWrite(errLog, "ERROR.LOG") THEN
      Files.Close(outLog); logOpen := FALSE
    END
  END
END Open;

(* Close*: close the log files opened by Open (if any), deleting error.log if
   no error was ever latched (HaveErr() = FALSE).  Call at the end of each
   tool's Run, right before SYSTEM.Halt.
   Parameters: none.  Result: none. *)
PROCEDURE Close*;
BEGIN
  IF logOpen THEN
    IF ~err THEN Files.SetDeleteOnClose(errLog, TRUE) END;
    Files.Close(outLog); Files.Close(errLog); logOpen := FALSE
  END
END Close;

PROCEDURE CheckLevel(lvl : INTEGER) : BOOLEAN;
BEGIN
  (* Plain threshold.  The old form `(level = LERROR) OR (level >= lvl)` made
     /LOG=error (the quietest setting) print EVERYTHING — inverted. *)
  RETURN level >= lvl
END CheckLevel;

(* IsDebug*: test whether the current verbosity level would emit DEBUG messages.
   Parameters: none.  Result: TRUE if level >= LDEBUG. *)
PROCEDURE IsDebug*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LDEBUG)
END IsDebug;

(* IsInfo*: test whether the current verbosity level would emit INFO messages.
   Parameters: none.  Result: TRUE if level >= LINFO. *)
PROCEDURE IsInfo*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LINFO)
END IsInfo;

(* IsWarn*: test whether the current verbosity level would emit WARN messages.
   Parameters: none.  Result: TRUE if level >= LWARN. *)
PROCEDURE IsWarn*() : BOOLEAN;
BEGIN
  RETURN CheckLevel(LWARN)
END IsWarn;

(* SetLevel*: set the diagnostic verbosity level (see LERROR/LINFO/LWARN/
   LDEBUG constants).  Only called from a tool's CLI argument-parsing branch
   (e.g. /LOG=) — never anywhere else, per project rule.
   Parameters: value — the new level (one of LERROR/LINFO/LWARN/LDEBUG).
   Result: none. *)
PROCEDURE SetLevel*(value : INTEGER);
BEGIN
  level := value
END SetLevel;

(* HaveErr*: test whether an error has been latched (via Error/Error2/
   ErrorInFile) since the process started.  There is no reset — the
   toolchain is fail-fast, so this only ever transitions FALSE -> TRUE once.
   Parameters: none.  Result: TRUE if an error has been latched. *)
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

(* Error*: report a fatal error.  Prints to stderr (and output.log/error.log
   if Open was called), and latches HaveErr() to TRUE — the toolchain is
   fail-fast, so every later message (of any level) is silently swallowed.
   Parameters: msg — the error message text.  Result: none. *)
PROCEDURE Error*(msg: ARRAY OF CHAR);
BEGIN
  Message(LERROR, msg)
END Error;

(* Warn*: report a non-fatal warning.  Prints to stdout (and output.log) if
   the current level is >= LWARN; otherwise silently dropped.
   Parameters: msg — the warning message text.  Result: none. *)
PROCEDURE Warn*(msg: ARRAY OF CHAR);
BEGIN
  Message(LWARN, msg)
END Warn;

(* Info*: report an informational message.  Prints to stdout (and
   output.log) if the current level is >= LINFO; otherwise
   silently dropped.
   Parameters: msg — the informational message text.  Result: none. *)
PROCEDURE Info*(msg: ARRAY OF CHAR);
BEGIN
  Message(LINFO, msg)
END Info;

(* Debug*: report a debug-level message.  Prints to stdout (and output.log)
   only if the current level is >= LDEBUG (widened via
   /LOG=debug); otherwise silently dropped.
   Parameters: msg — the debug message text.  Result: none. *)
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

(* Error2*: report a fatal error built from two concatenated parts (avoids
   the caller needing its own Strings.Copy/Append scratch buffer).
   Parameters: msg — leading message text; arg — text appended after msg
   (typically a filename, symbol name, or other single piece of context).
   Result: none. *)
PROCEDURE Error2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LERROR, msg, arg)
END Error2;

(* Info2*: report an informational message built from two concatenated parts.
   Parameters: msg — leading message text; arg — text appended after msg.
   Result: none. *)
PROCEDURE Info2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LINFO, msg, arg)
END Info2;

(* Warn2*: report a warning built from two concatenated parts.
   Parameters: msg — leading message text; arg — text appended after msg.
   Result: none. *)
PROCEDURE Warn2*(msg, arg: ARRAY OF CHAR);
BEGIN
  Message2(LWARN, msg, arg)
END Warn2;

(* Debug2*: report a debug-level message built from two concatenated parts.
   Parameters: msg — leading message text; arg — text appended after msg.
   Result: none. *)
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

(* ErrorInFile*: report a fatal error at a source position.  The scanner,
   parser, and code generator MUST use this (not plain Error) so every
   diagnostic carries `filename(line):` — the format the manifest harness
   and human readers both expect.
   Parameters: fname — source file path; line — 1-based line number;
   message — the error text.  Result: none. *)
PROCEDURE ErrorInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LERROR, fname, line, message)
END ErrorInFile;

(* InfoInFile*: report an informational message at a source position.
   Parameters: fname — source file path; line — 1-based line number;
   message — the info text.  Result: none. *)
PROCEDURE InfoInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LINFO, fname, line, message)
END InfoInFile;

(* WarnInFile*: report a warning at a source position (e.g. dead-code/
   unused-symbol warnings).
   Parameters: fname — source file path; line — 1-based line number;
   message — the warning text.  Result: none. *)
PROCEDURE WarnInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LWARN, fname, line, message)
END WarnInFile;

(* DebugInFile*: report a debug-level message at a source position.
   Parameters: fname — source file path; line — 1-based line number;
   message — the debug text.  Result: none. *)
PROCEDURE DebugInFile*(VAR fname: ARRAY OF CHAR; line : LONGINT; message: ARRAY OF CHAR);
BEGIN
  MessageInFile(LDEBUG, fname, line, message)
END DebugInFile;

BEGIN
  IO.StdErr(errRider);
  IO.StdOut(outRider);
  SetLevel(LINFO);
  logOpen := FALSE;
  err := FALSE
END LogErr.