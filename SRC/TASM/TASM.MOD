(*$M 32000, 262144, 650000*)
MODULE TASM;
(*
  tasm -- self-hosted 8086 assembler: reads a NASM-subset .asm source file
  and writes an RDOFF2 .rdf object file.  No other output format.

  usage: tasm [/LOG=level] file.asm

  Exactly one positional argument: the input .asm path.  The output path
  is always auto-derived from the input by replacing its extension with
  .RDF (uppercase 8.3, matching the rest of this toolchain's naming
  convention; see Files.ReplaceExt) -- there is no -o/-OUT= override in
  v1, per the maintainer's explicit CLI choice.

  /LOG=level  sets diagnostic verbosity (debug/info/warn/error,
  case-insensitive) -- the exact same switch toc.exe accepts
  (TOC.MOD's MatchSwitchVal/SetLevel pattern, duplicated here since it's
  a small CLI-parsing helper, not something LogErr itself exports).

  Mirrors SRC/TOOLS/*.MOD's RunBody/LogErr-routed-diagnostics shape exactly:
  LogErr.Open first in Run, a single Halt(code) wrapper that calls
  LogErr.Close then SYSTEM.Halt (the only SYSTEM.Halt call site in TASM),
  and its own outer LeakGuard window around the whole assemble-one-file
  operation (TOC.MOD's private LeakGuard helper, duplicated here as TASM's
  own private copy of the same ~15-line pattern -- see DOCS/TASM_PLAN.MD).
*)
IMPORT Out, Dos, Files, Strings, LogErr, Rdoff, Parse;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;
  ExitAsm   = 4;

PROCEDURE Usage;
BEGIN
  Out.String("usage: tasm [/LOG=level] file.asm"); Out.Ln;
  Out.String("  Assembles file.asm (NASM subset) to file.rdf (RDOFF2)."); Out.Ln;
  Out.String("  /LOG=level   set diagnostic verbosity: debug, info, warn"); Out.Ln;
  Out.String("               (default), or error. Case-insensitive."); Out.Ln
END Usage;

(* MatchSwitchVal: copy of TOC.MOD's private helper (not exported, so
   duplicated here -- same small CLI-parsing idiom every tool in this repo
   uses for its own /SWITCH= arguments). *)
PROCEDURE MatchSwitchVal(arg, pfx: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (pfx[i] # 0X) & (SYSTEM.UCASE(arg[i]) = SYSTEM.UCASE(pfx[i])) DO INC(i) END;
  IF pfx[i] # 0X THEN RETURN FALSE END;   (* prefix did not fully match *)
  j := 0;
  WHILE arg[i] # 0X DO val[j] := arg[i]; INC(i); INC(j) END;
  val[j] := 0X;
  RETURN TRUE
END MatchSwitchVal;

(* LeakGuard: copy of TOC.MOD's private helper (not exported by TOC, so
   duplicated here per DOCS/TASM_PLAN.MD -- same ~15-line shape).  Reports
   via LogErr.Debug (gated on LogErr.IsDebug(), silent unless /LOG=debug)
   whenever free memory shrank across the guarded window. *)
PROCEDURE LeakGuard(memBefore: WORD; subPart: ARRAY OF CHAR);
  VAR memAfter: WORD; msg: ARRAY 256 OF CHAR;
BEGIN
  memAfter := SYSTEM.MemAvail();
  IF memAfter < memBefore THEN
    IF LogErr.IsDebug() THEN
      Strings.Copy("Heap leak detected ", msg);
      Strings.Append(subPart, msg);
      Strings.Append(" (", msg);
      Strings.AppendInt(LONGINT(memBefore - memAfter), msg);
      Strings.Append(" paragraphs)", msg);
      LogErr.Debug(msg)
    END
  END
END LeakGuard;

PROCEDURE RunBody(): INTEGER;
  VAR srcPath, outPath: ARRAY 128 OF CHAR;
      leakMsg: ARRAY 160 OF CHAR;
      logLevel: ARRAY 32 OF CHAR;
      arg: ARRAY 128 OF CHAR;
      obj: Rdoff.ObjFile;
      f: Files.File;
      ok: BOOLEAN;
      memBefore: WORD;
      argc, i: INTEGER;
BEGIN
  Out.String("Trubo Assembler, 2026 (c) DosWorld, Public Domain (unlicense)"); Out.Ln;
  LogErr.SetLevel(LogErr.LINFO);
  argc := Dos.ParamCount();
  IF argc < 1 THEN Usage; RETURN ExitUsage END;
  srcPath[0] := 0X;
  i := 1;
  WHILE i <= argc DO
    Dos.ParamStr(i, arg);
    IF MatchSwitchVal(arg, "/LOG=", logLevel) THEN
      IF Strings.EqualICase(logLevel, "debug") THEN LogErr.SetLevel(LogErr.LDEBUG)
      ELSIF Strings.EqualICase(logLevel, "info") THEN LogErr.SetLevel(LogErr.LINFO)
      ELSIF Strings.EqualICase(logLevel, "warn") THEN LogErr.SetLevel(LogErr.LWARN)
      ELSIF Strings.EqualICase(logLevel, "error") THEN LogErr.SetLevel(LogErr.LERROR)
      ELSE
        LogErr.Error2("tasm: /LOG=: unknown level (want debug/info/warn/error) ", logLevel);
        RETURN ExitUsage
      END
    ELSIF (arg[0] # "/") & (arg[0] # "-") THEN
      IF srcPath[0] = 0X THEN Strings.Copy(arg, srcPath) END
    ELSE
      LogErr.Error2("tasm: unknown option ", arg); RETURN ExitUsage
    END;
    INC(i)
  END;
  IF srcPath[0] = 0X THEN Usage; RETURN ExitUsage END;
  IF ~Files.FileExists(srcPath) THEN
    LogErr.Error2("tasm: no such file: ", srcPath); RETURN ExitIo
  END;

  Files.ReplaceExt(srcPath, ".RDF", outPath);

  memBefore := SYSTEM.MemAvail();

  NEW(obj);
  IF obj = NIL THEN LogErr.Error("tasm: out of memory"); RETURN ExitIo END;
  Rdoff.RdfInit(obj);
  IF LogErr.HaveErr() THEN DISPOSE(obj); RETURN ExitIo END;

  ok := Parse.Assemble(srcPath, obj);

  IF ok & ~LogErr.HaveErr() THEN
    IF ~Files.ReWrite(f, outPath) THEN
      LogErr.Error2("tasm: cannot write ", outPath);
      Rdoff.RdfFree(obj); DISPOSE(obj); RETURN ExitIo
    END;
    Rdoff.RdfWriteTo(obj, f);
    Files.Close(f);
    IF ~LogErr.HaveErr() THEN
      Out.String("tasm: wrote "); Out.String(outPath); Out.Ln
    END
  END;

  Rdoff.RdfFree(obj);
  DISPOSE(obj);

  Strings.Copy("assembling ", leakMsg); Strings.Append(srcPath, leakMsg);
  LeakGuard(memBefore, leakMsg);

  IF ~ok OR LogErr.HaveErr() THEN RETURN ExitAsm END;
  RETURN ExitOk
END RunBody;

PROCEDURE Halt(code: INTEGER);
BEGIN
  LogErr.Close;
  SYSTEM.Halt(BYTE(code))          (* the ONE and ONLY SYSTEM.Halt in tasm *)
END Halt;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  Halt(rc)
END Run;

END TASM.
