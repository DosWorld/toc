(*$M 4000, 2000, 8000*)
(*$D-,R-,A-,O-*)
MODULE TOC;
(*
  DRIVER of the compile/link process split.

  This is the piece that must stay tiny: it holds NO compiler and NO linker
  code, only argument handling and two Dos.Exec calls.  Its whole resident
  cost is charged against every build, so the $M above is deliberately
  minimal (stack 4000 + min-heap 2000 = 6000 bytes reserved, well under the
  10 KB budget) and it imports only Dos/Strings/Out.

  Neither this driver nor the two children use $O+ overlays: overlays exist
  to squeeze a single oversized image, and the entire point of the split is
  that each half is small enough not to need them.  Dropping them also drops
  Overlay.OvrSetBuf2's unconditional 87 KB heap buffer -- a cost the current
  all-in-one TOC.EXE pays at startup on EVERY run, including pure links.

    TOC [switches] <file.Mod>
      1. exec TOCC  -- compile <file.Mod> + imports, emit .om files and,
                       with /ENTRY=, a <stem>.LNK control file listing them
                       in topological order
      2. exec TOCL <stem>.LNK  -- link those .om files into the .exe

  Without /ENTRY= there is nothing to link, so step 2 is skipped and this
  costs exactly one child process.
*)
(* Deliberately does NOT import Files: the driver needs it only for a single
   existence check, and Files costs ~11 KB of code -- more than everything
   else here combined.  Dos.FindFirst answers the same question for free
   (Dos is imported anyway for Exec/ParamStr/FSplit). *)
IMPORT Dos, Strings, Out;

CONST
  MaxPath = 128;

VAR
  args:    ARRAY 128 OF CHAR;   (* switches + source, forwarded to TOCC *)
  srcFile: ARRAY MaxPath OF CHAR;
  lnkFile: ARRAY MaxPath OF CHAR;
  exeDir:  ARRAY MaxPath OF CHAR;
  child:   ARRAY MaxPath OF CHAR;
  tail:    ARRAY 128 OF CHAR;   (* TOCL command line: <lnk> [OBERON_LIB] *)
  libEnv:  ARRAY 128 OF CHAR;
  hasEntry: BOOLEAN;

(* Locate a child binary: same directory as this driver, and carrying this
   driver's OWN name prefix.
   `suffix` is "C" or "L", giving <prefix>TOCC.EXE / <prefix>TOCL.EXE where
   <prefix> is whatever precedes "TOC" in our own filename.

   The prefix matters during a build.  SRC/TOC/Makefile stages the bootstrap
   toolchain as _TOC.EXE/_TOCC.EXE/_TOCL.EXE precisely because the plain
   names are the binaries being BUILT in that same directory -- staging them
   unrenamed would have the running compiler overwritten mid-build.  Deriving
   the children from our own basename keeps a staged _TOC.EXE talking to
   _TOCC.EXE/_TOCL.EXE, never to the half-written outputs beside them. *)
PROCEDURE ChildPath(suffix: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR self, ext, base: ARRAY MaxPath OF CHAR;
      nm: ARRAY MaxPath OF CHAR;
      i, n: INTEGER;
BEGIN
  Dos.ParamStr(0, self);
  IF self[0] = 0X THEN
    Strings.Copy("TOC", nm); Strings.Append(suffix, nm);
    Strings.Append(".EXE", nm); Strings.Copy(nm, dst); RETURN
  END;
  Dos.FSplit(self, exeDir, base, ext);
  (* base is our own stem, e.g. "TOC" or "_TOC"; drop its trailing "TOC"
     to recover the prefix, then rebuild <prefix>TOC<suffix>.EXE. *)
  n := 0; WHILE base[n] # 0X DO INC(n) END;
  IF (n >= 3) & (SYSTEM.UCASE(base[n-3]) = "T")
             & (SYSTEM.UCASE(base[n-2]) = "O")
             & (SYSTEM.UCASE(base[n-1]) = "C") THEN
    i := 0;
    WHILE i < n - 3 DO nm[i] := base[i]; INC(i) END;
    nm[i] := 0X
  ELSE
    nm[0] := 0X          (* unrecognised name: fall back to bare TOCC/TOCL *)
  END;
  Strings.Append("TOC", nm); Strings.Append(suffix, nm);
  Strings.Append(".EXE", nm);
  Dos.PathJoin(dst, exeDir, nm)
END ChildPath;

(* Existence check without pulling in Files (see the IMPORT comment). *)
PROCEDURE Exists(path: ARRAY OF CHAR): BOOLEAN;
  VAR s: Dos.SearchRec;
BEGIN
  Dos.FindFirst(path, 0, s);
  RETURN Dos.DosError = 0
END Exists;

(* <stem>.LNK in the CURRENT directory: TOCC writes it, TOCL reads it.

   NOT beside the source.  TOCC names the link file after its output image
   (TocMain.WriteLinkFile splits `outExe`), and outExe defaults to the root
   module's own name with no directory part -- so for `toc /ENTRY=Run
   SUB/FOO.MOD` the compiler writes FOO.LNK, FOO.OM and FOO.EXE in the CWD,
   not in SUB/.  Deriving the name with FSplit+PathJoin kept the "SUB/"
   prefix, so the driver looked for SUB/FOO.LNK, never found it, and aborted
   with "compiler produced no link file" before ever running the linker --
   i.e. any source passed with a directory path failed to link (fixed
   2026-09-05).  Strip the directory here the same way TocMain.BaseStem
   does, so both halves agree on the name. *)
PROCEDURE LnkName(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, start, dot, k: INTEGER;
BEGIN
  (* Own basename scan rather than Dos.FSplit: FSplit only treats "\" and
     ":" as separators, so for a forward-slash path like SUB/FOO.MOD it
     returns Name = "SUB/FOO" and the directory would survive.  TocMain's
     BaseStem -- the code that actually decides the output name -- accepts
     "/", "\" and ":" alike, and this must match it exactly. *)
  (* Bound the scan by LEN(src), not just the NUL: src is a by-value open
     array, and an unterminated copy ran the loop off the end and corrupted
     the caller's stack frame.  The symptom was remote and baffling -- the
     driver returned 0 for a compile that had already FAILED, losing rc from
     step 1, even though LnkName is only reached in step 2 (2026-09-05). *)
  start := 0; dot := -1; i := 0;
  WHILE (i < LEN(src)) & (src[i] # 0X) DO
    IF (src[i] = "/") OR (src[i] = "\") OR (src[i] = ":") THEN
      start := i + 1; dot := -1
    END;
    IF src[i] = "." THEN dot := i END;
    INC(i)
  END;
  IF dot < start THEN dot := i END;
  i := start; k := 0;
  WHILE (i < dot) & (k < LEN(dst) - 5) DO dst[k] := src[i]; INC(i); INC(k) END;
  dst[k] := 0X;
  Strings.Append(".LNK", dst)
END LnkName;

PROCEDURE RunBody(): INTEGER;
  VAR i, argc, rc: INTEGER;
      a: ARRAY MaxPath OF CHAR;
BEGIN
  argc := Dos.ParamCount();
  IF argc < 1 THEN
    Out.String("toc: compile/link split driver"); Out.Ln;
    Out.String("usage: TOC [/ENTRY=Proc] [/SYSTEM] [/M] [/G] [/CD|/CP] <file.Mod>");
    Out.Ln;
    RETURN 2
  END;

  args[0] := 0X; srcFile[0] := 0X; hasEntry := FALSE;
  (* Snapshot OBERON_LIB FIRST, before any Dos.Exec or file probe.
     ENV-BUG.MD: a Files.Reset/Close cycle corrupts the next Dos.GetEnv, and
     running a child process is at least as disruptive -- read here, while
     the environment is still pristine, and use the copy later. *)
  Dos.GetEnv("OBERON_LIB", libEnv);
  i := 1;
  WHILE i <= argc DO
    Dos.ParamStr(i, a);
    IF a[0] # 0X THEN
      IF args[0] # 0X THEN Strings.Append(" ", args) END;
      Strings.Append(a, args);
      IF a[0] = "/" THEN
        IF Strings.StartsWith(a, "/ENTRY=", TRUE) THEN hasEntry := TRUE END
      ELSE
        Strings.Copy(a, srcFile)
      END
    END;
    INC(i)
  END;
  IF srcFile[0] = 0X THEN
    Out.String("toc: no source file given"); Out.Ln; RETURN 2
  END;

  (* 1. compile.  Dos.Exec reports through DosError (spawn failure) and
     DosExitCode (the child's own exit code) -- same idiom as TESTALL.MOD. *)
  ChildPath("C", child);
  Dos.Exec(child, args);
  IF Dos.DosError # 0 THEN
    Out.String("toc: cannot exec "); Out.String(child); Out.Ln; RETURN 1
  END;
  rc := INTEGER(SYSTEM.AND(INTEGER(Dos.DosExitCode), 0FFH));
  IF rc # 0 THEN RETURN rc END;
  IF ~hasEntry THEN RETURN 0 END;   (* compile-only: nothing to link *)

  (* 2. link *)
  LnkName(srcFile, lnkFile);
  IF ~Exists(lnkFile) THEN
    Out.String("toc: compiler produced no link file "); Out.String(lnkFile);
    Out.Ln; RETURN 1
  END;
  (* Pass OBERON_LIB to the linker on its command line.
     Only THIS process can read it: xt injects -e variables into the program
     it launches directly, and a Dos.Exec'd child does not inherit the DOS
     environment block -- so neither TOCC nor TOCL can see OBERON_LIB, yet
     TRUBO.OM (LogErr/StrTab) is reachable only through it.  TOCC's own
     imports still resolve via its OBERON.OM fallback, which is why only the
     LINK step failed ("Unresolved external: LogErr_Error"). *)
  Strings.Copy(lnkFile, tail);
  IF libEnv[0] # 0X THEN
    Strings.Append(" ", tail); Strings.Append(libEnv, tail)
  END;

  ChildPath("L", child);
  Dos.Exec(child, tail);
  IF Dos.DosError # 0 THEN
    Out.String("toc: cannot exec "); Out.String(child); Out.Ln; RETURN 1
  END;
  RETURN INTEGER(SYSTEM.AND(INTEGER(Dos.DosExitCode), 0FFH))
END RunBody;

PROCEDURE Run*;
BEGIN
  SYSTEM.Halt(BYTE(RunBody()))
END Run;

END TOC.
