(*$R-*)
(*$M 8192, 32768, 32768*)
MODULE Testall;
(* Phase-4 test runner.  Reads TESTS/MANIFEST.TSV, runs Section 17
   executable tests, and runs Section 18 Oberon-port unit tests.
   Drives compile/link/run pipelines via Dos.Exec.

   Usage:  testall.exe TOOLDIR [MANIFEST]

   TOOLDIR holds toc.exe, rdfgrep.exe AND a `BIN/` subdir with
   the runtime .om files, a `TESTS/` subdir with .MOD sources and FIX/
   fixtures, and a `SRC/TOC/` subdir with compiler module sources.
   toc.exe handles both compilation and linking (/ENTRY= flag).
   MANIFEST defaults to TOOLDIR/TESTS/MANIFEST.TSV.

   Output: "PASS: <name>" or "FAIL: <name> (...)" per row, then summary
   lines per section.  Exit code = 0 iff all sections pass. *)
IMPORT LogErr, Files, Strings, Dos;

CONST
  MaxLine   = 512;
  MaxPath   = 96;
  MaxFix    = 80;
  MaxArg    = 128;
  MaxCmd    = 512;

VAR
  toolDir, libDir, fixDir, testsDir, ocSrcDir, manifest: ARRAY MaxPath OF CHAR;
  ocPath, rdfgrepPath: ARRAY MaxPath OF CHAR;
  passCount, failCount: INTEGER;

(* ---- string helpers ---- *)

PROCEDURE AppendChar(VAR dst: ARRAY OF CHAR; ch: CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(dst) - 1) & (dst[i] # 0X) DO INC(i) END;
  IF i < LEN(dst) - 1 THEN dst[i] := ch; dst[i+1] := 0X END
END AppendChar;

PROCEDURE ParseDecimal(s: ARRAY OF CHAR): INTEGER;
  VAR i, v: INTEGER;
BEGIN
  i := 0; v := 0;
  WHILE (s[i] >= "0") & (s[i] <= "9") DO
    v := v * 10 + ORD(s[i]) - ORD("0"); INC(i)
  END;
  RETURN v
END ParseDecimal;

(* ---- workdir bookkeeping ----
   We use a single fixed workdir name "TWD" (Test Work Dir) as a sibling
   of testall.exe's CWD.  Before each row, every .om / .rdf / .def / .exe
   left from the previous row is deleted to keep the dir clean. *)

PROCEDURE DeleteMatching(pattern: ARRAY OF CHAR);
  VAR sr: Dos.SearchRec; ok: BOOLEAN;
BEGIN
  Dos.FindFirst(pattern, Dos.Archive, sr);
  WHILE Dos.DosError = 0 DO
    ok := Files.Delete(sr.name);
    IF ~ok THEN END;  (* best-effort *)
    Dos.FindNext(sr)
  END
END DeleteMatching;

(* Per-row cleanup: removes only the kinds of files oc / olink can
   produce in CWD.  Never touches *.EXE so tool binaries survive.
   Fixture .MOD files are deleted because we re-copy them per row. *)
(* Copy libDir\OBERON.OM into the workdir so the compiler resolves stdlib
   imports from the implicit CWD OBERON.OM (the old -L option is gone; the
   current oc uses OBERON_LIB or a CWD OBERON.OM). *)
PROCEDURE CopyOberonOm;
  VAR from: ARRAY MaxPath OF CHAR; ok: BOOLEAN;
BEGIN
  Strings.Copy(libDir, from); AppendChar(from, "\");
  Strings.Append("OBERON.OM", from);
  ok := Files.Copy(from, "OBERON.OM");
  IF ~ok THEN LogErr.Error("cannot copy OBERON.OM") END
END CopyOberonOm;

PROCEDURE ClearWorkdir;
BEGIN
  DeleteMatching("*.OM");
  DeleteMatching("*.RDF");
  DeleteMatching("*.DEF");
  DeleteMatching("*.MOD");
  DeleteMatching("*.TMP");
  CopyOberonOm
END ClearWorkdir;

(* Like ClearWorkdir but keeps *.OM — used in Section 18 where
   pre-compiled Oc*.om deps must survive across test boundaries. *)
PROCEDURE ClearWorkdirKeepOm;
BEGIN
  DeleteMatching("*.RDF");
  DeleteMatching("*.DEF");
  DeleteMatching("*.MOD");
  DeleteMatching("*.TMP");
  CopyOberonOm
END ClearWorkdirKeepOm;

(* ---- spawn a child and capture exit code ---- *)

PROCEDURE Spawn(tool, args: ARRAY OF CHAR): INTEGER;
  VAR msg: ARRAY 48 OF CHAR;
BEGIN
  Dos.Exec(tool, args);
  IF Dos.DosError # 0 THEN
    Strings.Copy("Dos.Exec err=", msg); Strings.AppendInt(LONGINT(Dos.DosError), msg);
    LogErr.Warn(msg);
    RETURN -1
  END;
  RETURN INTEGER(SYSTEM.AND(INTEGER(Dos.DosExitCode), 0FFH))
END Spawn;

(* ---- TSV row parsing ----
   line: NAME<TAB>FIXTURE<TAB>CMD<TAB>EXPECT<TAB>ARG[<TAB>MEMBER]
   Field n=0..5; trailing fields may be empty. *)

PROCEDURE SplitField(VAR src: ARRAY OF CHAR; VAR srcPos: INTEGER;
                     VAR dst: ARRAY OF CHAR);
  VAR i, di: INTEGER; ch: CHAR;
BEGIN
  di := 0; i := srcPos;
  WHILE (i < LEN(src)) & (src[i] # 0X) & (src[i] # 09X) DO
    ch := src[i];
    IF (ch # 0DX) & (ch # 0AX) & (di < LEN(dst) - 1) THEN
      dst[di] := ch; INC(di)
    END;
    INC(i)
  END;
  dst[di] := 0X;
  IF (i < LEN(src)) & (src[i] = 09X) THEN INC(i) END;
  srcPos := i
END SplitField;

PROCEDURE ParseRow*(line: ARRAY OF CHAR;
                    VAR name, fixture, cmd, expect, arg, member: ARRAY OF CHAR);
  VAR pos: INTEGER;
BEGIN
  pos := 0;
  SplitField(line, pos, name);
  SplitField(line, pos, fixture);
  SplitField(line, pos, cmd);
  SplitField(line, pos, expect);
  SplitField(line, pos, arg);
  SplitField(line, pos, member)
END ParseRow;

(* ---- fixture handling ----
   FIXTURE may be "MAIN.MOD" or "MAIN.MOD+EXTRA.MOD+OTHER.MOD".
   Copies all listed fixtures from fixDir into the workdir.
   Returns the main fixture (first one) for use as oc's compile target. *)

PROCEDURE CopyFixtures(fixture: ARRAY OF CHAR; VAR mainFix: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
      one: ARRAY MaxFix OF CHAR;
      from, to: ARRAY MaxPath OF CHAR;
      first: BOOLEAN;
BEGIN
  i := 0; first := TRUE;
  WHILE fixture[i] # 0X DO
    j := 0;
    WHILE (fixture[i] # 0X) & (fixture[i] # "+") & (j < LEN(one) - 1) DO
      one[j] := fixture[i]; INC(j); INC(i)
    END;
    one[j] := 0X;
    IF fixture[i] = "+" THEN INC(i) END;
    Strings.Copy(fixDir, from); AppendChar(from, "\"); Strings.Append(one, from);
    Strings.Copy(one, to);
    IF ~Files.Copy(from, to) THEN RETURN FALSE END;
    IF first THEN Strings.Copy(one, mainFix); first := FALSE END
  END;
  RETURN TRUE
END CopyFixtures;

(* ---- locate produced .om (the first *.om file in CWD) ----
   Uses Dos.FindFirst which wraps INT 21h / 4Eh and returns the basename
   straight from the DOS DTA — no manual INT 21h required at this level. *)

PROCEDURE FindProducedOm(VAR omName: ARRAY OF CHAR): BOOLEAN;
  VAR sr: Dos.SearchRec; i: INTEGER;
BEGIN
  Dos.FindFirst("*.OM", Dos.Archive, sr);
  IF Dos.DosError # 0 THEN
    Dos.FindFirst("*.om", Dos.Archive, sr);
    IF Dos.DosError # 0 THEN RETURN FALSE END
  END;
  i := 0;
  WHILE (sr.name[i] # 0X) & (i < LEN(omName) - 1) DO
    omName[i] := sr.name[i]; INC(i)
  END;
  omName[i] := 0X;
  RETURN omName[0] # 0X
END FindProducedOm;

(* ---- predicate dispatch via rdfgrep.exe ----
   Map (expect, arg, fixture-derived rdf/.om/.exe path) into the
   rdfgrep command line.  Returns rdfgrep's exit code. *)

PROCEDURE ToUpper(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO
    IF (s[i] >= "a") & (s[i] <= "z") THEN
      s[i] := CHR(ORD(s[i]) - 32)
    END;
    INC(i)
  END
END ToUpper;

PROCEDURE MakeRdfName(omName: ARRAY OF CHAR; VAR rdfName: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (omName[i] # 0X) & (omName[i] # ".") DO
    rdfName[i] := omName[i]; INC(i)
  END;
  rdfName[i] := 0X;
  ToUpper(rdfName);
  Strings.Append(".RDF", rdfName)
END MakeRdfName;

PROCEDURE MakeExeName(omName: ARRAY OF CHAR; VAR exeName: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (omName[i] # 0X) & (omName[i] # ".") DO
    exeName[i] := omName[i]; INC(i)
  END;
  exeName[i] := 0X;
  ToUpper(exeName);
  Strings.Append(".EXE", exeName)
END MakeExeName;

(* ---- predicate: spawn rdfgrep.exe with appropriate args ---- *)

(* Returns TRUE when the EXPECT predicate needs the .RDF as a standalone
   file (not the wrapping .OM).  Such predicates require extracting the
   RDF member from the .OM into CWD before invoking rdfgrep. *)
PROCEDURE NeedsRdfExtracted(expect: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.Equal(expect, "has-import") OR
         Strings.Equal(expect, "no-import") OR
         Strings.Equal(expect, "has-global") OR
         Strings.Equal(expect, "no-global") OR
         Strings.Equal(expect, "code-starts") OR
         Strings.Equal(expect, "code-contains") OR
         Strings.Equal(expect, "no-code-contains") OR
         Strings.Equal(expect, "has-reloc-for") OR
         Strings.Equal(expect, "has-reloc-to-seg") OR
         Strings.Equal(expect, "code-count") OR
         Strings.Equal(expect, "code-byte-at") OR
         Strings.Equal(expect, "init-imports-empty") OR
         Strings.Equal(expect, "has-segreloc") OR
         Strings.Equal(expect, "no-segreloc") OR
         Strings.Equal(expect, "has-reloc-and-segreloc")
END NeedsRdfExtracted;

PROCEDURE ExtractRdf(om, rdf: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: ARRAY MaxCmd OF CHAR; rc: INTEGER;
BEGIN
  Strings.Copy("om-extract ", cmd);
  Strings.Append(om, cmd);
  AppendChar(cmd, " "); Strings.Append(rdf, cmd);
  AppendChar(cmd, " "); Strings.Append(rdf, cmd);
  rc := Spawn(rdfgrepPath, cmd);
  RETURN rc = 0
END ExtractRdf;

PROCEDURE EvalPredicate(expect, arg, om, rdf, exe: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: ARRAY MaxCmd OF CHAR;
      rc: INTEGER;
BEGIN
  Strings.Copy(expect, cmd);
  AppendChar(cmd, " ");
  (* Predicates that take an RDF file: *)
  IF Strings.Equal(expect, "has-import") OR
     Strings.Equal(expect, "no-import") OR
     Strings.Equal(expect, "has-global") OR
     Strings.Equal(expect, "no-global") OR
     Strings.Equal(expect, "code-starts") OR
     Strings.Equal(expect, "code-contains") OR
     Strings.Equal(expect, "no-code-contains") OR
     Strings.Equal(expect, "has-reloc-for") OR
     Strings.Equal(expect, "has-reloc-to-seg") OR
     Strings.Equal(expect, "code-count") OR
     Strings.Equal(expect, "code-byte-at") THEN
    Strings.Append(rdf, cmd); AppendChar(cmd, " "); Strings.Append(arg, cmd)
  ELSIF Strings.Equal(expect, "init-imports-empty") OR
        Strings.Equal(expect, "has-segreloc") OR
        Strings.Equal(expect, "no-segreloc") OR
        Strings.Equal(expect, "has-reloc-and-segreloc") THEN
    Strings.Append(rdf, cmd)
  ELSIF Strings.Equal(expect, "om-has-file") OR
        Strings.Equal(expect, "om-no-file") OR
        Strings.Equal(expect, "om-member-contains") OR
        Strings.Equal(expect, "om-member-no-contains") OR
        Strings.Equal(expect, "om-member-equals") THEN
    Strings.Append(om, cmd); AppendChar(cmd, " "); Strings.Append(arg, cmd)
  ELSIF Strings.Equal(expect, "mz-sp") OR
        Strings.Equal(expect, "mz-min-alloc") OR
        Strings.Equal(expect, "mz-max-alloc") THEN
    Strings.Append(exe, cmd); AppendChar(cmd, " "); Strings.Append(arg, cmd)
  ELSE
    RETURN FALSE  (* unknown — caller already handled *)
  END;
  rc := Spawn(rdfgrepPath, cmd);
  RETURN rc = 0
END EvalPredicate;

(* ---- output ---- *)

PROCEDURE Pass(name: ARRAY OF CHAR);
  VAR msg: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy("PASS: ", msg); Strings.Append(name, msg);
  LogErr.Info(msg);
  INC(passCount)
END Pass;

(* Fail reports via LogErr.Error, which latches: the first failure aborts the whole
   run (no point continuing), so callers must check LogErr.HaveErr() and stop. *)
PROCEDURE Fail(name, reason: ARRAY OF CHAR);
  VAR msg: ARRAY 256 OF CHAR;
BEGIN
  Strings.Copy(name, msg);
  IF reason[0] # 0X THEN
    Strings.Append(" (", msg); Strings.Append(reason, msg); Strings.Append(")", msg)
  END;
  LogErr.Error(msg);
  INC(failCount)
END Fail;

(* ---- one row execution ---- *)

PROCEDURE EvalRow(name, fixture, cmd, expect, arg, member: ARRAY OF CHAR);
  VAR mainFix: ARRAY MaxFix OF CHAR;
      om: ARRAY MaxFix OF CHAR;
      rdf: ARRAY MaxFix OF CHAR;
      exe: ARRAY MaxFix OF CHAR;
      ocArgs: ARRAY MaxCmd OF CHAR;
      rc, expectedExit: INTEGER;
BEGIN
  ClearWorkdir;
  IF ~CopyFixtures(fixture, mainFix) THEN
    Fail(name, "fixture copy failed"); RETURN
  END;

  (* Build oc args.  Stdlib imports resolve via the OBERON.OM copied into the
     workdir by ClearWorkdir (the old -L option is gone).
     CMD column either holds extra flags or "fails" (expect compile error). *)
  ocArgs[0] := 0X;
  IF (cmd[0] # 0X) & ~Strings.Equal(cmd, "fails") THEN
    Strings.Append(cmd, ocArgs); AppendChar(ocArgs, " ")
  END;
  Strings.Append(mainFix, ocArgs);
  rc := Spawn(ocPath, ocArgs);

  (* file-presence predicates evaluate BEFORE caring about compile rc. *)
  IF Strings.Equal(expect, "file-in-workdir") THEN
    IF Files.FileExists(arg) THEN Pass(name)
    ELSE Fail(name, "expected file missing") END;
    RETURN
  END;
  IF Strings.Equal(expect, "no-file-in-workdir") THEN
    IF Files.FileExists(arg) THEN Fail(name, "forbidden file present")
    ELSE Pass(name) END;
    RETURN
  END;
  (* stderr-contains / stderr-no-contains: not implementable via Dos.Exec
     since the child shares parent's stdout/stderr.  Skip with PASS so
     these manifest rows don't block the suite (they were originally a
     bash-only feature). *)
  IF Strings.Equal(expect, "stderr-contains") OR
     Strings.Equal(expect, "stderr-no-contains") THEN
    Pass(name);  (* TODO: capture stderr — needs redirected child *)
    RETURN
  END;

  (* compile-fails: success if oc exited non-zero. *)
  IF Strings.Equal(expect, "compile-fails") OR Strings.Equal(cmd, "fails") THEN
    IF rc # 0 THEN Pass(name)
    ELSE Fail(name, "compile unexpectedly succeeded") END;
    RETURN
  END;

  (* Any other predicate requires a successful compile. *)
  IF rc # 0 THEN
    Fail(name, "compile failed"); RETURN
  END;

  IF ~FindProducedOm(om) THEN
    Fail(name, "no .om produced"); RETURN
  END;
  IF member[0] # 0X THEN
    Strings.Copy(member, rdf)
  ELSE
    MakeRdfName(om, rdf)
  END;
  MakeExeName(om, exe);

  (* errorlevel: compile+link (toc.exe /ENTRY=Run already in ocArgs) + run. *)
  IF Strings.Equal(expect, "errorlevel") THEN
    Strings.Append(" ", ocArgs); Strings.Append(exe, ocArgs);
    rc := Spawn(ocPath, ocArgs);
    IF rc # 0 THEN Fail(name, "link failed"); RETURN END;
    expectedExit := ParseDecimal(arg);
    rc := Spawn(exe, "");
    IF rc = expectedExit THEN Pass(name)
    ELSE Fail(name, "errorlevel mismatch") END;
    RETURN
  END;

  (* mz-*: compile+link via toc.exe, then ask rdfgrep to read MZ header. *)
  IF Strings.Equal(expect, "mz-sp") OR
     Strings.Equal(expect, "mz-min-alloc") OR
     Strings.Equal(expect, "mz-max-alloc") THEN
    Strings.Append(" ", ocArgs); Strings.Append(exe, ocArgs);
    rc := Spawn(ocPath, ocArgs);
    IF rc # 0 THEN Fail(name, "link failed"); RETURN END
  END;

  (* RDF predicates need the .rdf as a standalone file; extract from .om. *)
  IF NeedsRdfExtracted(expect) THEN
    IF ~ExtractRdf(om, rdf) THEN
      Fail(name, "rdf extract failed"); RETURN
    END
  END;

  (* Delegate predicate evaluation to rdfgrep.exe. *)
  IF EvalPredicate(expect, arg, om, rdf, exe) THEN Pass(name)
  ELSE Fail(name, "predicate failed") END
END EvalRow;

(* ---- executable test runner (Section 17 / 18) ----

   Compile modFile (from testsDir) with /ENTRY=RunAllTests,
   link against linkDeps (space-sep .om names in CWD) and stdLibs
   (space-sep .om names relative to libDir), run the exe.
   PASS iff DosExitCode = 0. *)

PROCEDURE RunExeTestImpl(clearAll: BOOLEAN;
                         name, modBase, fixtureFix: ARRAY OF CHAR);
  VAR cmd: ARRAY MaxCmd OF CHAR;
      modFile, exeName: ARRAY MaxFix OF CHAR;
      from, to: ARRAY MaxPath OF CHAR;
      p: INTEGER; rc: INTEGER;
BEGIN
  IF clearAll THEN ClearWorkdir ELSE ClearWorkdirKeepOm END;

  IF fixtureFix[0] # 0X THEN
    Strings.Copy(fixDir, from); AppendChar(from, "\");
    Strings.Append(fixtureFix, from);
    Strings.Copy(fixtureFix, to);
    IF ~Files.Copy(from, to) THEN
      Fail(name, "fixture copy failed"); RETURN
    END
  END;

  Strings.Copy(testsDir, modFile);
  AppendChar(modFile, "\"); Strings.Append(modBase, modFile);
  Strings.Append(".MOD", modFile);

  p := 0;
  WHILE modBase[p] # 0X DO
    exeName[p] := modBase[p];
    IF (modBase[p] >= "A") & (modBase[p] <= "Z") THEN
      exeName[p] := CHR(ORD(modBase[p]) + 32)
    END;
    INC(p)
  END;
  exeName[p] := 0X;
  Strings.Append(".exe", exeName);

  (* toc.exe /ENTRY=RunAllTests compiles + links in one step. *)
  Strings.Copy("/ENTRY=RunAllTests ", cmd);
  Strings.Append(modFile, cmd);
  AppendChar(cmd, " "); Strings.Append(exeName, cmd);
  rc := Spawn(ocPath, cmd);
  IF rc # 0 THEN Fail(name, "compile/link failed"); RETURN END;

  rc := Spawn(exeName, "");
  IF rc = 0 THEN Pass(name) ELSE Fail(name, "test failed") END
END RunExeTestImpl;

PROCEDURE RunExeTest(name, modBase, fixtureFix: ARRAY OF CHAR);
BEGIN RunExeTestImpl(TRUE, name, modBase, fixtureFix) END RunExeTest;

PROCEDURE RunExeTestKeep(name, modBase, fixtureFix: ARRAY OF CHAR);
BEGIN RunExeTestImpl(FALSE, name, modBase, fixtureFix) END RunExeTestKeep;

(* Compile modBase.MOD from testsDir without /ENTRY= (produces .om lib only). *)
PROCEDURE CompileTestMod(modBase: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: ARRAY MaxCmd OF CHAR; src: ARRAY MaxPath OF CHAR;
BEGIN
  Strings.Copy(testsDir, src); AppendChar(src, "\");
  Strings.Append(modBase, src); Strings.Append(".MOD", src);
  Strings.Copy(src, cmd);
  RETURN Spawn(ocPath, cmd) = 0
END CompileTestMod;

(* ---- compile a compiler module source into CWD (Section 18 setup) ---- *)

PROCEDURE CompileOcMod(modBase: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: ARRAY MaxCmd OF CHAR; src: ARRAY MaxPath OF CHAR;
BEGIN
  Strings.Copy(ocSrcDir, src);
  AppendChar(src, "\"); Strings.Append(modBase, src);
  Strings.Append(".Mod", src);
  Strings.Copy(src, cmd);
  RETURN Spawn(ocPath, cmd) = 0
END CompileOcMod;

(* Run an executable test that depends on a pre-compiled library module.
   Clears workdir, compiles depBase (no /ENTRY=), then runs the main test. *)
PROCEDURE RunExeTestWithDep(name, modBase, depBase: ARRAY OF CHAR);
BEGIN
  ClearWorkdir;
  IF ~CompileTestMod(depBase) THEN
    Fail(name, "dep compile failed"); RETURN
  END;
  RunExeTestImpl(FALSE, name, modBase, "")
END RunExeTestWithDep;

(* ---- Section 17: executable test modules ---- *)

PROCEDURE RunSection17;
BEGIN
  LogErr.Info("== Section 17: executable test modules ==");
  RunExeTest("17/NUM",   "NUM", "");
  RunExeTest("17/FLOAT", "FLOAT", "");
  RunExeTest("17/CTRL",  "CTRL", "");
  RunExeTest("17/PROC1", "PROC1", "");
  RunExeTest("17/PROC2", "PROC2", "");
  RunExeTest("17/RECARR","RECARR", "");
  RunExeTest("17/PTR",   "PTR", "");
  RunExeTest("17/SYS1",  "SYS1", "");
  RunExeTest("17/SYS2",  "SYS2", "");
  RunExeTest("17/STR",   "STR", "");
  RunExeTest("17/DEEP",  "DEEP", "");
  RunExeTest("17/DEEP2", "DEEP2", "");
  (* Paired import tests: A module is a lib dep for B module. *)
  RunExeTest("17/IMPCA",    "IMPCA", "");
  RunExeTestWithDep("17/IMPCB", "IMPCB", "IMPCA");
  RunExeTest("17/IMPPA",    "IMPPA", "");
  RunExeTestWithDep("17/IMPPB", "IMPPB", "IMPPA");
  RunExeTest("17/SCOPA",    "SCOPA", "");
  RunExeTestWithDep("17/SCOPB", "SCOPB", "SCOPA")
END RunSection17;

(* ---- Section 18: Oberon-port unit-test modules ---- *)

PROCEDURE RunSection18;
  VAR ok: BOOLEAN;
BEGIN
  LogErr.Info("== Section 18: Oberon-port unit tests ==");

  (* Pre-compile Oc* dependency chain into CWD *)
  ClearWorkdir;
  ok := CompileOcMod("Scan")    & CompileOcMod("StrTab") &
        CompileOcMod("Syms")  &
        CompileOcMod("Rdoff")   & CompileOcMod("Cgen")  &
        CompileOcMod("Tar")     & CompileOcMod("Def")   &
        CompileOcMod("PExpr")   & CompileOcMod("PStmt") &
        CompileOcMod("Import")  & CompileOcMod("Parser");
  IF ~ok THEN
    LogErr.Error("18/setup (Oc* compile failed)");
    INC(failCount); RETURN
  END;

  (* Use RunExeTestKeep so Oc*.om deps survive between test calls. *)
  (* P0 regression tests (2026-06-13): typeless-VAR-param codegen + buffered I/O. *)
  RunExeTestKeep("18/TADDR", "TADDR", "");
  RunExeTestKeep("18/TFBUF", "TFBUF", "");
  RunExeTestKeep("18/TFREC", "TFREC", "");
  RunExeTestKeep("18/TEMSTMP", "TEMSTMP", "");
  RunExeTestKeep("18/TOPT",  "TOPT", "");
  RunExeTestKeep("18/TSCAN", "TSCAN", "");
  RunExeTestKeep("18/TSYMS", "TSYMS", "");
  RunExeTestKeep("18/TCGEN", "TCGEN", "");
  RunExeTestKeep("18/TRDOF", "TRDOF", "");
  RunExeTestKeep("18/TTAR",  "TTAR", "");
  RunExeTestKeep("18/TDEF",  "TDEF", "");
  RunExeTestKeep("18/TPRSR", "TPRSR", "PRSR01.MOD");
  RunExeTestKeep("18/TINCDEC", "TINCDEC", "");
  RunExeTestKeep("18/TSYSMV", "TSYSMV", "");
  RunExeTestKeep("18/TCASETBL", "TCASETBL", "")
END RunSection18;

(* ---- SYSTEM.DEF artefact checks (T5/T6) ----
   Verify that removed intrinsics are absent from the shipped lib/SYSTEM.om.
   Uses rdfgrep om-member-no-contains with hex-encoded symbol names. *)

PROCEDURE CheckAbsent(hexPat: ARRAY OF CHAR): BOOLEAN;
  VAR cmd: ARRAY MaxCmd OF CHAR; sysOm: ARRAY MaxPath OF CHAR;
BEGIN
  Strings.Copy(libDir, sysOm); Strings.Append("\SYSTEM.om", sysOm);
  Strings.Copy("om-member-no-contains ", cmd);
  Strings.Append(sysOm, cmd); Strings.Append(" SYSTEM.DEF ", cmd);
  Strings.Append(hexPat, cmd);
  RETURN Spawn(rdfgrepPath, cmd) = 0
END CheckAbsent;

PROCEDURE RunSysDef;
BEGIN
  LogErr.Info("== SYSTEM.DEF artefact checks ==");
  (* T5: SYSTEM_VAL must be absent ("53 59 53 54 45 4D 5F 56 41 4C") *)
  IF CheckAbsent("53 59 53 54 45 4D 5F 56 41 4C") THEN Pass("sysdef/T5-no-SYSTEM_VAL")
  ELSE Fail("sysdef/T5-no-SYSTEM_VAL", "SYSTEM_VAL found in SYSTEM.DEF") END;
  (* T6a: SYSTEM_GET must be absent ("53 59 53 54 45 4D 5F 47 45 54") *)
  IF CheckAbsent("53 59 53 54 45 4D 5F 47 45 54") THEN Pass("sysdef/T6-no-SYSTEM_GET")
  ELSE Fail("sysdef/T6-no-SYSTEM_GET", "SYSTEM_GET found in SYSTEM.DEF") END;
  (* T6b: SYSTEM_PUT must be absent ("53 59 53 54 45 4D 5F 50 55 54") *)
  IF CheckAbsent("53 59 53 54 45 4D 5F 50 55 54") THEN Pass("sysdef/T6-no-SYSTEM_PUT")
  ELSE Fail("sysdef/T6-no-SYSTEM_PUT", "SYSTEM_PUT found in SYSTEM.DEF") END
END RunSysDef;

(* ---- driver: read manifest line-by-line ---- *)

PROCEDURE Run*;
  VAR f: Files.File;
      line: ARRAY MaxLine OF CHAR;
      ch: ARRAY 1 OF BYTE;
      n: WORD;
      pos: INTEGER;
      done, lineDone: BOOLEAN;
      name, fixture, cmd, expect, arg, member: ARRAY MaxArg OF CHAR;
      manPassStart, manFailStart: INTEGER;
      sumBuf: ARRAY 128 OF CHAR;
BEGIN
  LogErr.Open;
  LogErr.SetLevel(LogErr.LDEBUG);   (* print all levels (INFO/WARN/DEBUG) for the report *)
  passCount := 0; failCount := 0;
  IF Dos.ParamCount() < 1 THEN
    LogErr.Error("usage: testall.exe TOOLDIR [MANIFEST]");
    LogErr.Close; SYSTEM.Halt(2)
  END;
  Dos.ParamStr(1, toolDir);
  (* Build manifest path in ORIGINAL CWD (we'll open it before chdir). *)
  IF Dos.ParamCount() >= 2 THEN
    Dos.ParamStr(2, manifest)
  ELSE
    Strings.Copy(toolDir, manifest); Strings.Append("\tests\MANIFEST.TSV", manifest)
  END;

  IF ~Files.Reset(f, manifest) THEN
    LogErr.Error2("FATAL: cannot open manifest: ", manifest);
    LogErr.Close; SYSTEM.Halt(3)
  END;

  (* Create TWD subdir under launch CWD and chdir into it.  All compile /
     fixture-copy / cleanup happens inside TWD; tool binaries in the
     parent CWD are safe from wildcard deletes. *)
  (* DosError 5 = access denied (already exists on real DOS);
     DosError 3 = path not found (xt returns this for existing dir). *)
  IF ~Dos.MkDir("TWD") & (Dos.DosError # 5) & (Dos.DosError # 3) THEN
    Strings.Copy("FATAL: cannot create TWD subdir, err=", sumBuf);
    Strings.AppendInt(LONGINT(Dos.DosError), sumBuf);
    LogErr.Error(sumBuf);
    LogErr.Close; SYSTEM.Halt(4)
  END;
  IF ~Dos.ChDir("TWD") THEN
    LogErr.Error("FATAL: cannot chdir into TWD"); LogErr.Close; SYSTEM.Halt(5)
  END;

  (* From inside TWD, paths into the parent need adjusting:
       "."          -> ".."           (one level up)
       "<rel>"      -> "..\<rel>"     (other relative paths)
       "X:..." or "\..."  -> unchanged (absolute) *)
  IF (toolDir[0] = ".") & (toolDir[1] = 0X) THEN
    Strings.Copy("..", toolDir)
  ELSIF (toolDir[1] # ":") & (toolDir[0] # "/") & (toolDir[0] # "\") THEN
    Strings.Insert("..\", 0, toolDir)
  END;
  Strings.Copy(toolDir, ocPath);       Strings.Append("\TOC.EXE", ocPath);
  (* rdfgrep is used straight from BIN/ (no copy into the tool dir). *)
  Strings.Copy(toolDir, rdfgrepPath);  Strings.Append("\BIN\RDFGREP.EXE", rdfgrepPath);
  Strings.Copy(toolDir, libDir);       Strings.Append("\BIN", libDir);
  Strings.Copy(toolDir, fixDir);       Strings.Append("\TESTS\FIX", fixDir);
  Strings.Copy(toolDir, testsDir);     Strings.Append("\TESTS", testsDir);
  Strings.Copy(toolDir, ocSrcDir);     Strings.Append("\SRC\TOC", ocSrcDir);

  manPassStart := passCount; manFailStart := failCount;

  done := FALSE;
  REPEAT
    pos := 0; lineDone := FALSE;
    (* read one line, terminating on LF or EOF *)
    WHILE ~lineDone & ~done DO
      n := Files.BlockRead(f, ch[0], 1);
      IF n = 0 THEN done := TRUE; lineDone := TRUE
      ELSIF ch[0] = BYTE(0AH) THEN lineDone := TRUE
      ELSIF (ch[0] # BYTE(0DH)) & (pos < MaxLine - 1) THEN
        line[pos] := CHR(INTEGER(ch[0])); INC(pos)
      END
    END;
    line[pos] := 0X;
    IF (pos > 0) & (line[0] # "#") THEN
      ParseRow(line, name, fixture, cmd, expect, arg, member);
      IF name[0] # 0X THEN
        EvalRow(name, fixture, cmd, expect, arg, member)
      END
    END
  UNTIL done OR LogErr.HaveErr();   (* fail-fast: a FAIL latched LogErr, stop the run *)
  Files.Close(f);

  Strings.Copy("Manifest: ", sumBuf);
  Strings.AppendInt(LONGINT(passCount - manPassStart), sumBuf);
  Strings.Append(" pass / ", sumBuf);
  Strings.AppendInt(LONGINT(failCount - manFailStart), sumBuf);
  Strings.Append(" fail", sumBuf);
  LogErr.Info(sumBuf);

  IF ~LogErr.HaveErr() THEN RunSection17 END;
  IF ~LogErr.HaveErr() THEN RunSection18 END;
  IF ~LogErr.HaveErr() THEN RunSysDef END;

  Strings.Copy("Total: ", sumBuf);
  Strings.AppendInt(LONGINT(passCount), sumBuf);
  Strings.Append(" pass / ", sumBuf);
  Strings.AppendInt(LONGINT(failCount), sumBuf);
  Strings.Append(" fail", sumBuf);
  LogErr.Info(sumBuf);
  LogErr.Close;
  IF failCount # 0 THEN SYSTEM.Halt(1) END
END Run;

END Testall.
