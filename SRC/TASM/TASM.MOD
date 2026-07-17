(*$M 32000, 262144, 650000*)
MODULE TASM;
(*
  tasm -- self-hosted 8086 assembler: reads a NASM-subset .asm source file
  and writes an RDOFF2 .rdf object file.  No other output format.

  usage: tasm [/LOG=level] file.asm
     or: tasm /BIN=code|data /NAME=GlobalName [/LOG=level] file.bin

  Exactly one positional argument: the input .asm (or, in bin2obj mode,
  .bin) path.  The output path is always auto-derived from the input by
  replacing its extension with .RDF (uppercase 8.3, matching the rest of
  this toolchain's naming convention; see Files.ReplaceExt) -- there is
  no -o/-OUT= override in v1, per the maintainer's explicit CLI choice.

  /LOG=level  sets diagnostic verbosity (debug/info/warn/error,
  case-insensitive) -- the exact same switch toc.exe accepts
  (TOC.MOD's MatchSwitchVal/SetLevel pattern, duplicated here since it's
  a small CLI-parsing helper, not something LogErr itself exports).

  /BIN=code|data /NAME=GlobalName  (§J, 2026-07-16): bin2obj mode --
  converts any binary file (< 64 KB) into an RDOFF2 object with the
  blob as the named segment's entire content and ONE GLOBAL record
  naming its start (offset 0); no RELOC/IMPORT/BSS records. The
  Scan/Sym/Parse/Enc assembler pipeline is not touched at all -- this is
  a separate ~60-line branch in RunBody that builds the ObjFile directly
  via Rdoff and reuses the existing write/cleanup/LeakGuard/exit-code
  tail. /BIN= both selects the mode and names the target segment;
  /NAME= is required in this mode (a usage error in assemble mode).

  -Dname[=value]  (§I.2, 2026-07-16): CLI predefine, applied as if
  "%define name value" appeared before line 1 of the source. May repeat.
  A later source-level %define of the same name overwrites it silently
  (matches %define's own overwrite semantics; "source wins" is
  documented behavior, not a bug).

  Assemble mode also supports %include "FILE.INC" (textual inclusion,
  up to Parse.MaxSrcDepth=8 levels, cycle-checked) and %macro NAME
  NPARAMS ... %endmacro (%1..%9 parameter substitution, %%ident local-
  label uniquing) -- see DOCS/PORTING.MD §1.7 and DOCS/IMPLRULE.MD's
  TASM section for the full feature writeup (TASM.MD §I is the design/
  implementation log).

  Mirrors SRC/TOOLS/*.MOD's RunBody/LogErr-routed-diagnostics shape exactly:
  LogErr.Open first in Run, a single Halt(code) wrapper that calls
  LogErr.Close then SYSTEM.Halt (the only SYSTEM.Halt call site in TASM),
  and its own outer LeakGuard window around the whole assemble-one-file
  operation (TOC.MOD's private LeakGuard helper, duplicated here as TASM's
  own private copy of the same ~15-line pattern).
*)
IMPORT Out, Dos, Files, Strings, LogErr, Rdoff, Parse, Sym;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;
  ExitAsm   = 4;

  (* one 16-bit segment, same bound Rdoff itself enforces -- RdfWriteTo's
     own check is `codeLen/dataLen >= SegLimit` (see RDOFF.MOD), so the
     real max is SegLimit-1, not SegLimit. *)
  MaxBlobSize = Rdoff.SegLimit - 1;

PROCEDURE Usage;
BEGIN
  Out.String("Trubo Assembler, 2026 (c) DosWorld, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("Usage: TASM [/LOG=level] [-Dname[=value]]... file.asm"); Out.Ln;
  Out.String("  or:  TASM /BIN=code|data /NAME=GlobalName [/LOG=level] file.bin"); Out.Ln;
  Out.Ln;
  Out.String("  Assembles file.asm (NASM subset) to file.rdf (RDOFF2)."); Out.Ln;
  Out.String("  -Dname[=value]  predefine name (as if %define name value had"); Out.Ln;
  Out.String("                  appeared before line 1); may repeat. A later"); Out.Ln;
  Out.String("                  %define of the same name in source wins."); Out.Ln;
  Out.Ln;
  Out.String("  Or 'bin2obj' mode (no parser/assembler pipeline):"); Out.Ln;
  Out.Ln;
  Out.String("  /BIN=seg /NAME=name converts file.bin to file.rdf instead: the"); Out.Ln;
  Out.String("  blob becomes seg's content, with one GLOBAL record named 'name'"); Out.Ln;
  Out.String("  at offset 0."); Out.Ln;
  Out.Ln;
  Out.String("  /LOG=level  set diagnostic verbosity: debug, info, warn"); Out.Ln;
  Out.String("              (default), or error. Case-insensitive."); Out.Ln
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
   duplicated here -- same ~15-line shape).  Reports via LogErr.Debug
   (gated on LogErr.IsDebug(), silent unless /LOG=debug) whenever free
   memory shrank across the guarded window. *)
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

(* IsIdentStartCh / IsIdentCh: private 10-line copy of Scan.IsAlpha/
   IsIdentChar's character classes (§J.2 -- exporting Scan's helpers just
   for /NAME= validation is not worth the coupling; this mode never
   touches the Scan/Parse pipeline at all). *)
PROCEDURE IsIdentStartCh(c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= "A") & (c <= "Z")) OR ((c >= "a") & (c <= "z"))
         OR (c = "_") OR (c = "$") OR (c = "?") OR (c = "@")
END IsIdentStartCh;

PROCEDURE IsIdentCh(c: CHAR): BOOLEAN;
BEGIN RETURN IsIdentStartCh(c) OR ((c >= "0") & (c <= "9"))
END IsIdentCh;

(* MatchDPrefix: §I.2's -D/-Dname[=value] recognizer -- distinct from
   MatchSwitchVal (which matches one fixed literal prefix like "/LOG="):
   -D takes no "=" itself, just a 2-char case-insensitive prefix
   ("-D" or "/D") followed directly by the predefine text. Returns the
   text after the prefix (possibly empty, e.g. bare "-D") via `rest`. *)
PROCEDURE MatchDPrefix(arg: ARRAY OF CHAR; VAR rest: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
BEGIN
  IF (arg[0] # "/") & (arg[0] # "-") THEN RETURN FALSE END;
  IF SYSTEM.UCASE(arg[1]) # "D" THEN RETURN FALSE END;
  j := 0; i := 2;
  WHILE arg[i] # 0X DO rest[j] := arg[i]; INC(i); INC(j) END;
  rest[j] := 0X;
  RETURN TRUE
END MatchDPrefix;

(* SplitPredef: split "name" or "name=value" (already past the -D/-Dname
   prefix) at the first '='. No '=' means an empty value -- a bare
   %ifdef flag, exactly NASM's `-Dname`. Uppercases name to match
   %define's own uppercase-keying convention (TASM.MD §I.0); value is
   copied verbatim (its case is data, not an identifier). Rejects an
   empty name (a bare "-D" or "-D=value" with nothing before '='). *)
PROCEDURE SplitPredef(text: ARRAY OF CHAR; VAR name, value: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE (text[i] # 0X) & (text[i] # "=") DO
    name[j] := SYSTEM.UCASE(text[i]); INC(i); INC(j)
  END;
  name[j] := 0X;
  IF j = 0 THEN RETURN FALSE END;
  IF ~IsIdentStartCh(name[0]) THEN RETURN FALSE END;
  j := 1;
  WHILE name[j] # 0X DO
    IF ~IsIdentCh(name[j]) THEN RETURN FALSE END;
    INC(j)
  END;
  IF text[i] = "=" THEN
    INC(i); j := 0;
    WHILE text[i] # 0X DO value[j] := text[i]; INC(i); INC(j) END;
    value[j] := 0X
  ELSE
    value[0] := 0X
  END;
  RETURN TRUE
END SplitPredef;

(* ValidGlobalName: §J.2's /NAME= validation -- the name lands in a
   GLOBAL record that Sym-side consumers (linker .def matching, EXTERN
   in other .ASM modules) treat as an identifier; a bad one must be a
   fatal error, never silently accepted or truncated (B3's lesson: the
   length check mirrors Sym.MaxName exactly instead of using a separate
   unconnected bound). *)
PROCEDURE ValidGlobalName(name: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  IF name[0] = 0X THEN RETURN FALSE END;
  IF Strings.Length(name) > Sym.MaxName - 1 THEN RETURN FALSE END;
  IF ~IsIdentStartCh(name[0]) THEN RETURN FALSE END;
  i := 1;
  WHILE name[i] # 0X DO
    IF ~IsIdentCh(name[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END ValidGlobalName;

(* RunBin2Obj: §J's bin2obj mode -- srcPath (a binary file, already
   confirmed to exist by the caller) becomes segId's entire content in
   outObj, with one GLOBAL record named `name` at offset 0. No RELOC/
   IMPORT/BSS records are ever created on this path; the other segment
   simply stays empty (TASM already emits modules with an empty data
   segment -- e.g. DETECT.ASM has no SECTION .data -- so downstream
   linker/rdfgrep handling of that shape is proven). Returns FALSE (with
   a LogErr diagnostic already latched) on any failure. *)
PROCEDURE RunBin2Obj(srcPath, name: ARRAY OF CHAR; segId: INTEGER; outObj: Rdoff.ObjFile): BOOLEAN;
  VAR f: Files.File; size: LONGINT; ok: BOOLEAN;
BEGIN
  IF ~Files.Reset(f, srcPath) THEN
    LogErr.Error2("tasm: cannot open ", srcPath); RETURN FALSE
  END;
  size := Files.Size(f);
  IF size = 0 THEN
    (* a 0-byte blob global is almost certainly a wrong path -- loud
       beats silent here, since the resulting .rdf would otherwise look
       plausible (one GLOBAL record, empty segment) with no diagnostic. *)
    LogErr.Error2("tasm: empty input file: ", srcPath); Files.Close(f); RETURN FALSE
  END;
  (* LONGINT() cast is generation-proof: MaxBlobSize (= SegLimit-1 = 64999)
     may fold as INTEGER or WORD depending on which compiler generation
     built this binary; a bare const here sign-extended to -537 under the
     INTEGER folding and rejected every input.  The cast always loads the
     constant's true value. *)
  IF size > LONGINT(MaxBlobSize) THEN
    LogErr.Error2("tasm: input exceeds 64K segment limit: ", srcPath);
    Files.Close(f); RETURN FALSE
  END;
  Rdoff.RdfAddGlobal(outObj, name, BYTE(segId), LONGINT(0));
  (* Use the standard Files.BlockCopy primitive (already audited: its
     1024-byte CopyChunk staging buffer is the fixed version of the 2026-
     07-11 8 KB-stack-buffer incident, see DOCS/IMPLRULE.MD's STRONG
     RULE) straight into the ObjFile's own code/data temp file, exactly
     the same pattern Rdoff.RdfLoad itself uses to load a segment back
     from a .rdf -- no hand-rolled read/emit loop needed. *)
  IF segId = Rdoff.SegCode THEN
    Files.Seek(outObj^.codeFile, LONGINT(0));
    ok := Files.BlockCopy(f, outObj^.codeFile, size);
    outObj^.codeLen := WORD(size)
  ELSE
    Files.Seek(outObj^.dataFile, LONGINT(0));
    ok := Files.BlockCopy(f, outObj^.dataFile, size);
    outObj^.dataLen := WORD(size)
  END;
  Files.Close(f);
  IF ~ok THEN LogErr.Error2("tasm: error reading ", srcPath) END;
  RETURN ok
END RunBin2Obj;

PROCEDURE RunBody(): INTEGER;
  VAR srcPath, outPath: ARRAY 128 OF CHAR;
      leakMsg: ARRAY 160 OF CHAR;
      logLevel: ARRAY 32 OF CHAR;
      binVal, nameVal: ARRAY 128 OF CHAR;
      arg: ARRAY 128 OF CHAR;
      dRest: ARRAY 128 OF CHAR;
      dName: ARRAY Sym.MaxName OF CHAR; dValue: ARRAY 128 OF CHAR;
      obj: Rdoff.ObjFile;
      f: Files.File;
      ok, binMode: BOOLEAN;
      binSeg: INTEGER;
      memBefore: WORD;
      argc, i: INTEGER;
BEGIN
  LogErr.SetLevel(LogErr.LINFO);
  argc := Dos.ParamCount();
  IF argc < 1 THEN Usage; RETURN ExitUsage END;
  srcPath[0] := 0X; binMode := FALSE; nameVal[0] := 0X;
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
        Parse.FreePredefs; RETURN ExitUsage
      END
    ELSIF MatchSwitchVal(arg, "/BIN=", binVal) THEN
      (* §J.2: /BIN= both selects bin2obj mode and names the target
         segment; BSS is deliberately not offered (a blob has CONTENT,
         BSS is contentless by definition). *)
      IF Strings.EqualICase(binVal, "code") THEN binMode := TRUE; binSeg := Rdoff.SegCode
      ELSIF Strings.EqualICase(binVal, "data") THEN binMode := TRUE; binSeg := Rdoff.SegData
      ELSE
        LogErr.Error2("tasm: /BIN=: unknown segment (want code or data) ", binVal);
        Parse.FreePredefs; RETURN ExitUsage
      END
    ELSIF MatchSwitchVal(arg, "/NAME=", nameVal) THEN
      (* validated below, once binMode is fully known -- see the note at
         the usage-error check *)
    ELSIF MatchDPrefix(arg, dRest) THEN
      (* §I.2: -D/-Dname[=value] CLI predefine -- applied once per
         Assemble via Parse.ApplyPredefs, exactly like a source-level
         %define seen before line 1. *)
      IF ~SplitPredef(dRest, dName, dValue) THEN
        LogErr.Error2("tasm: invalid -D (want -Dname or -Dname=value): ", arg);
        Parse.FreePredefs; RETURN ExitUsage
      END;
      Parse.AddPredef(dName, dValue)
    ELSIF (arg[0] # "/") & (arg[0] # "-") THEN
      (* C11 fix: a second positional argument used to be silently
         ignored (e.g. a typo'd switch like "x.asm y.asm" half-working) --
         reject it loudly instead. *)
      IF srcPath[0] = 0X THEN Strings.Copy(arg, srcPath)
      ELSE
        LogErr.Error2("tasm: unexpected extra argument ", arg); Parse.FreePredefs; RETURN ExitUsage
      END
    ELSE
      LogErr.Error2("tasm: unknown option ", arg); Parse.FreePredefs; RETURN ExitUsage
    END;
    INC(i)
  END;
  IF srcPath[0] = 0X THEN Usage; Parse.FreePredefs; RETURN ExitUsage END;
  IF ~Files.FileExists(srcPath) THEN
    LogErr.Error2("tasm: no such file: ", srcPath); Parse.FreePredefs; RETURN ExitIo
  END;
  (* §J.2: /NAME= is REQUIRED in bin mode, and a usage error (not silent
     ignoring, per C11's lesson) in assemble mode. *)
  IF binMode & (nameVal[0] = 0X) THEN
    LogErr.Error("tasm: /BIN= mode requires /NAME=GlobalName"); Parse.FreePredefs; RETURN ExitUsage
  END;
  IF ~binMode & (nameVal[0] # 0X) THEN
    LogErr.Error("tasm: /NAME= is only valid with /BIN="); Parse.FreePredefs; RETURN ExitUsage
  END;
  IF binMode & ~ValidGlobalName(nameVal) THEN
    LogErr.Error2("tasm: invalid global name: ", nameVal); Parse.FreePredefs; RETURN ExitUsage
  END;

  Files.ReplaceExt(srcPath, ".RDF", outPath);

  memBefore := SYSTEM.MemAvail();

  NEW(obj);
  IF obj = NIL THEN LogErr.Error("tasm: out of memory"); Parse.FreePredefs; RETURN ExitIo END;
  Rdoff.RdfInit(obj);
  IF LogErr.HaveErr() THEN DISPOSE(obj); Parse.FreePredefs; RETURN ExitIo END;

  IF binMode THEN ok := RunBin2Obj(srcPath, nameVal, binSeg, obj)
  ELSE ok := Parse.Assemble(srcPath, obj)
  END;

  IF ok & ~LogErr.HaveErr() THEN
    IF ~Files.ReWrite(f, outPath) THEN
      LogErr.Error2("tasm: cannot write ", outPath);
      Rdoff.RdfFree(obj); DISPOSE(obj); Parse.FreePredefs; RETURN ExitIo
    END;
    Rdoff.RdfWriteTo(obj, f);
    (* C10 fix: if RdfWriteTo latched an error partway through, the
       partially-written .RDF was closed but left on disk -- a later
       `make` could pick up the corrupt object with no diagnostic.
       Mirror TOC's own delete-intermediates-on-error behavior. *)
    IF LogErr.HaveErr() THEN Files.SetDeleteOnClose(f, TRUE) END;
    Files.Close(f);
    IF ~LogErr.HaveErr() THEN
      LogErr.Info2("tasm: wrote ", outPath)
    END
  END;

  Rdoff.RdfFree(obj);
  DISPOSE(obj);
  Parse.FreePredefs;

  IF binMode THEN Strings.Copy("converting ", leakMsg) ELSE Strings.Copy("assembling ", leakMsg) END;
  Strings.Append(srcPath, leakMsg);
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
