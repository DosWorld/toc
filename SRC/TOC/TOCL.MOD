(*$M 8000, 16000, 650000*)
(*$D-,R-,A-*)
MODULE TOCL;
(*
  Standalone LINK phase of the compile/link process split (TOCL.EXE).

  The compiler used to be one binary holding compile-side (SCAN/SYMS/CGEN/
  PARSER/PEXPR/PEXPR2/PSTMT/DEF/TDBG/IMPORT) AND link-side (LINK/LINKMZ/
  LINKNE/LINKOVR) resident at once, though neither phase ever needs the
  other's code.  This binary imports ONLY the link half; TOCC.EXE has only
  the compile half; TOC.EXE is a small driver that runs them in turn.

  $M: linking needs no symbol-table arena, no StrTab of source identifiers
  and no Cgen object -- its heap is the linker's own symbol table plus the
  per-module code/data streaming buffers -- so it asks for far less stack
  and min-heap than the old combined `$M 26000, 160000, 650000`.

  Input contract (deliberately file-based, no shared RAM with the compiler):
      TOCL <linkfile>
  where <linkfile> is a plain text control file, one directive per line:
      EXE <output.exe>      output image name
      CD | CP               target: MZ real-mode (default) or NE DPMI16
      DBG                   emit /G debug info
      OM <path.om>          one input .om, in topological order (repeatable)
  Everything the compile phase knows and the linker needs is exactly this;
  TocMain.WriteLinkFile produces it; this module consumes it.
*)
IMPORT Dos, Files, Strings, Rdoff, Tar, Link, LinkMZ, LinkNE, LinkOvr,
       LogErr, Out, StrTab;

CONST
  MaxPath = 128;

VAR
  gOutExe:   ARRAY MaxPath OF CHAR;
  gTargetCP: BOOLEAN;
  gGenDbg:   BOOLEAN;
  gLibArg:   ARRAY 512 OF CHAR;   (* OBERON_LIB from argv[2], if given *)
  gLib:      ARRAY 512 OF CHAR;   (* OBERON_LIB, snapshot before any file I/O *)

(* ---- control-file parsing ---- *)

PROCEDURE Token(VAR line: ARRAY OF CHAR; VAR i: INTEGER;
                VAR out: ARRAY OF CHAR);
  VAR j: INTEGER;
BEGIN
  WHILE (line[i] = " ") OR (line[i] = 09X) DO INC(i) END;
  j := 0;
  WHILE (line[i] # 0X) & (line[i] # " ") & (line[i] # 09X) &
        (j < LEN(out) - 1) DO
    out[j] := line[i]; INC(j); INC(i)
  END;
  out[j] := 0X
END Token;

(* Real MS-DOS file APIs never accept '/' as a path separator -- only '\\'
   and backslash-colon.  A forward-slash OBERON_LIB entry would
   silently fail to resolve.  Same normalisation Import.NormalizeSlashes
   does; duplicated here rather than importing Import, which would drag the
   whole compiler front end (Def -> Syms) into the linker. *)
PROCEDURE NormalizeSlashes(VAR path: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = "/" THEN path[i] := "\" END;
    INC(i)
  END
END NormalizeSlashes;

(* Pass 1: settings only.  OM lines are skipped here (see RunBody). *)
PROCEDURE Setting(VAR line: ARRAY OF CHAR);
  VAR i: INTEGER;
      kw:  ARRAY 16 OF CHAR;
      arg: ARRAY MaxPath OF CHAR;
BEGIN
  i := 0;
  Token(line, i, kw);
  IF kw[0] = 0X THEN RETURN END;
  IF Strings.Equal(kw, "EXE") THEN
    Token(line, i, arg); Strings.Copy(arg, gOutExe)
  ELSIF Strings.Equal(kw, "CP")  THEN gTargetCP := TRUE
  ELSIF Strings.Equal(kw, "CD")  THEN gTargetCP := FALSE
  ELSIF Strings.Equal(kw, "DBG") THEN gGenDbg := TRUE
  ELSIF Strings.Equal(kw, "LIB") THEN
    (* OBERON_LIB, forwarded by whoever wrote this file.  Needed because an
       exec'd child does not reliably inherit the DOS environment block (xt
       does not propagate it through INT 21h/4B00h at all), so a linker
       started as a child process cannot read OBERON_LIB itself -- and
       TRUBO.OM, holding LogErr/StrTab, is reachable ONLY through it.
       A LIB line here overrides whatever the environment said. *)
    Token(line, i, arg); Strings.Copy(arg, gLib)
  ELSIF Strings.Equal(kw, "OM")  THEN (* pass 2 *)
  ELSE LogErr.Error2("tocl: unknown directive: ", kw)
  END
END Setting;

(* Pass 2: OM lines only, in the order given (topological, as the compile
   phase emitted them). *)
PROCEDURE OmLine(ls: Link.State; VAR line: ARRAY OF CHAR);
  VAR i: INTEGER;
      kw:  ARRAY 16 OF CHAR;
      arg: ARRAY MaxPath OF CHAR;
BEGIN
  i := 0;
  Token(line, i, kw);
  IF ~Strings.Equal(kw, "OM") THEN RETURN END;
  Token(line, i, arg);
  IF (arg[0] # 0X) & Files.FileExists(arg) & Tar.IsOmFile(arg) THEN
    Link.ProcessFile(ls, arg)
  ELSE
    LogErr.Error2("tocl: bad or missing .om: ", arg)
  END
END OmLine;

(* LinkFromFile -- the whole link phase, driven by a .LNK control file.
   Exported so BOTH shapes of the toolchain share ONE linker driver:
   Run passes its argv[1] here.  Returns a process exit code (0 = ok). *)
PROCEDURE LinkFromFile*(ctl: ARRAY OF CHAR): INTEGER;
  VAR ls: Link.State; ms: LinkMZ.State; ns: LinkNE.State;
      f: Files.File;
      line: ARRAY 512 OF CHAR;
      omExe: ARRAY MaxPath OF CHAR;
      ovrPath: ARRAY MaxPath OF CHAR;
      dir: ARRAY MaxPath OF CHAR;
      pos, dlen: INTEGER;
BEGIN
  gOutExe[0] := 0X; gTargetCP := FALSE; gGenDbg := FALSE;

  (* Snapshot OBERON_LIB BEFORE any file is opened.  ENV-BUG.MD: a bare
     Files.Reset + Files.Close pair reliably corrupts the very next
     Dos.GetEnv read, and this procedure opens the .LNK control file twice
     below -- reading the variable afterwards returned garbage and every
     link failed with "Unresolved external: LogErr_Error". *)
  Dos.GetEnv("OBERON_LIB", gLib);
  IF gLibArg[0] # 0X THEN Strings.Copy(gLibArg, gLib) END;

  (* Pass 1 -- settings only (EXE/CD/CP/DBG).  These must be known BEFORE the
     link states are allocated (the target picks MZ vs NE, and LinkNE wants
     the module name at init), while the OM lines must be processed AFTER
     ReserveBuffers.  Hence two passes over a tiny control file. *)
  IF ~Files.Reset(f, ctl) THEN
    LogErr.Error2("tocl: cannot open link file ", ctl); RETURN 1
  END;
  WHILE (Files.ReadLine(f, line, 512) > 0) & ~LogErr.HaveErr() DO
    Setting(line)
  END;
  Files.Close(f);
  IF LogErr.HaveErr() THEN RETURN 1 END;
  IF gOutExe[0] = 0X THEN
    LogErr.Error("tocl: link file has no EXE line"); RETURN 1
  END;

  (* Same order as TOCMAIN.LinkAll: allocate the states, init, then reserve
     the fixed link buffers BEFORE any .om is opened -- an 8 KB Files buffer
     per scanned .rdf would otherwise fragment the arena so no large hole
     survives (LinkAll's own comment). *)
  NEW(ls);
  IF ls = NIL THEN LogErr.Error("tocl: out of memory (link state)"); RETURN 1 END;
  IF gTargetCP THEN NEW(ns); ms := NIL ELSE NEW(ms); ns := NIL END;
  Link.InitState(ls);
  ls^.targetCP := gTargetCP;
  IF gTargetCP THEN
    IF ns = NIL THEN LogErr.Error("tocl: out of memory (NE state)"); RETURN 1 END;
    LinkNE.InitState(ns); LinkNE.SetModName(ns, gOutExe); ns^.genDebug := gGenDbg
  ELSE
    IF ms = NIL THEN LogErr.Error("tocl: out of memory (MZ state)"); RETURN 1 END;
    LinkMZ.InitState(ms); ms^.genDebug := gGenDbg
  END;
  IF ~Link.ReserveBuffers() THEN Link.LinkFree(ls); DISPOSE(ls); RETURN 1 END;

  (* Pass 2 -- the OM inputs, now that the buffers are reserved. *)
  IF ~Files.Reset(f, ctl) THEN
    LogErr.Error2("tocl: cannot reopen link file ", ctl);
    Link.LinkFree(ls); DISPOSE(ls); RETURN 1
  END;
  WHILE (Files.ReadLine(f, line, 512) > 0) & ~LogErr.HaveErr() DO
    OmLine(ls, line)
  END;
  Files.Close(f);

  (* OBERON_LIB archives next, then OBERON.OM last -- the same order the
     old in-process LinkAll used.  This is NOT optional: LogErr and StrTab
     live in TRUBO.OM, which is reached only through OBERON_LIB, so without
     this walk every link fails with "Unresolved external: LogErr_Error".
     Snapshotted into gLib at entry (see there).  A plain Dos.GetEnv, NOT
     Import.GetCachedOberonLib: module
     Import pulls in Def, which pulls in Syms -- i.e. the compiler front end
     this binary exists to leave out.  The ENV-BUG.MD workaround that made
     the cached read necessary was only needed because overlay bring-up
     (SetupOvr) corrupted a later Dos.GetEnv; nothing here uses overlays, and
     this read happens before any Files.Reset/Close cycle of our own. *)
  IF ~LogErr.HaveErr() THEN
    pos := 0;
    WHILE gLib[pos] # 0X DO
      dlen := 0;
      WHILE (gLib[pos] # 0X) & (gLib[pos] # ";") & (dlen < MaxPath - 1) DO
        dir[dlen] := gLib[pos]; INC(dlen); INC(pos)
      END;
      dir[dlen] := 0X;
      IF gLib[pos] = ";" THEN INC(pos) END;
      NormalizeSlashes(dir);
      IF (dlen > 0) & Files.FileExists(dir) & Tar.IsOmFile(dir) THEN
        Link.ProcessFile(ls, dir)
      END
    END
  END;

  (* OBERON.OM last, exactly as LinkAll does -- same search (CWD, then the
     running exe's own directory). *)
  IF ~LogErr.HaveErr() THEN
    Link.FindFile("OBERON.OM", omExe);
    IF Files.FileExists(omExe) & Tar.IsOmFile(omExe) THEN
      Link.ProcessOberonOm(ls, omExe)
    END
  END;

  IF ~LogErr.HaveErr() THEN Link.SmartLink(ls) END;
  IF ~LogErr.HaveErr() THEN Link.ReadStackSize(ls) END;
  IF ~LogErr.HaveErr() THEN Link.CalculateLayout(ls) END;

  IF gTargetCP THEN
    (* BuildSegTable MUST run before PerformLinking: it creates the NE
       per-module segment table.  Omitting it silently produced an NE image
       with "NE segs=0" -- the file still carried a valid NE signature, so
       only the segment-count check caught it. *)
    IF ~LogErr.HaveErr() THEN LinkNE.BuildSegTable(ls, ns) END;
    IF ~LogErr.HaveErr() THEN LinkNE.PerformLinking(ls, ns) END;
    IF ~LogErr.HaveErr() THEN LinkNE.WriteExe(ls, ns, gOutExe) END;
    LinkNE.LinkFree(ns)
  ELSE
    IF ~LogErr.HaveErr() THEN LinkMZ.PerformLinking(ls, ms) END;
    IF ~LogErr.HaveErr() THEN LinkMZ.WriteExe(ls, ms, gOutExe) END;
    LinkMZ.LinkFree(ms)
  END;

  (* Overlay payload, if the program being linked used $O+.  None of the
     compiler's own modules do any more, but a USER program still can, and
     LinkAll emitted this -- so the split must too or such a program links
     to trampolines with no .OVR behind them.  /CD-only (DOCS/OVR.MD §2). *)
  IF ls^.anyOverlay & ~gTargetCP & ~LogErr.HaveErr() THEN
    Files.ReplaceExt(gOutExe, ".OVR", ovrPath); SYSTEM.UPSTR(ovrPath);
    LinkOvr.WriteOvrFile(ls, ovrPath)
  END;

  Link.LinkFree(ls); DISPOSE(ls);
  IF LogErr.HaveErr() THEN RETURN 1 END;
  RETURN 0
END LinkFromFile;

PROCEDURE Run*;
  VAR exitCode: INTEGER;
      ctl: ARRAY MaxPath OF CHAR;
BEGIN
  LogErr.SetLevel(LogErr.LINFO);
  IF Dos.ParamCount() < 1 THEN
    Out.String("tocl: link phase of the split toolchain"); Out.Ln;
    Out.String("usage: TOCL <linkfile>"); Out.Ln;
    Out.String("  linkfile lines: EXE <out.exe> | CD | CP | DBG | OM <in.om>");
    Out.Ln;
    SYSTEM.Halt(2)
  END;
  Dos.ParamStr(1, ctl);
  (* Optional 2nd argument: OBERON_LIB, forwarded by the driver.  A
     Dos.Exec'd child does not inherit the DOS environment block (xt does
     not propagate it at all), so this is the only way a linker started as
     a child can learn where TRUBO.OM -- holding LogErr/StrTab -- lives.
     Overrides the environment read inside LinkFromFile when present. *)
  IF Dos.ParamCount() >= 2 THEN
    Dos.ParamStr(2, gLibArg)
  ELSE
    gLibArg[0] := 0X
  END;
  LogErr.Open;
  exitCode := LinkFromFile(ctl);
  LogErr.Close;
  SYSTEM.Halt(BYTE(exitCode))
END Run;

END TOCL.
