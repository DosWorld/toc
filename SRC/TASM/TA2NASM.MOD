(*$M 32000,192000,650000*)
MODULE TA2NASM;
(*
  ta2nasm -- standalone preprocessor: converts one or more Borland Turbo
  Assembler 5.0 (MASM/Ideal-mode) .asm source files into NASM-subset
  syntax.

  usage: ta2nasm SRCFILE.ASM [SRCFILE2.ASM ...]

  Exactly like TASM.EXE's own output-path convention: each SRCFILE.ASM's
  output path is auto-derived by replacing its extension with .NAS
  (Files.ReplaceExt) -- there is no destination-filename argument.  Every
  positional argument given is processed in turn; the first failure stops
  the run and is reported via the process exit code (matching TASM.EXE's
  own "first error is fatal" convention), but does not itself skip
  processing files already queued before it in the same invocation call
  -- see RunBody's own loop.

  Moved out of TASM.EXE 2026-08-11: TASM.MOD's own /LNG=turbo mode used
  to call Turbo.Convert (TURBO.MOD/TURBODIR.MOD) directly, in-process.
  Turbo/TurboDir's own conversion logic is large enough that keeping it
  IN-process with TASM's own NASM-subset assembler pipeline (Scan/Sym/
  Parse/Enc) meant either (a) TASM.EXE's own combined code exceeding
  practical single-.EXE size, or (b) needing $O+ overlays to keep any one
  piece under the 64K RDOFF2 code-segment limit (Rdoff.SegLimit) -- overlay
  machinery this conversion step has no real need for, since it is a
  wholly separate, one-shot preprocessing pass with no interaction with
  TASM's own assembler state at all.  As its own standalone .EXE, Turbo/
  TurboDir's code gets its own full program budget, and can be split into
  as many ordinary (non-overlay) modules as needed to stay under
  Rdoff.SegLimit per module -- see TURBODIR.MOD's own header comment for
  that split.  TASM.EXE no longer accepts Turbo-dialect source at all
  (dropped its own /LNG= switch entirely) -- run ta2nasm first, then feed
  its own SRCFILE.NAS output into TASM.exe like any other NASM-subset
  file.

  Mirrors SRC/TOOLS/*.MOD's RunBody/LogErr-routed-diagnostics shape:
  LogErr.Open first in Run, a single Halt(code) wrapper that calls
  LogErr.Close then SYSTEM.Halt (the only SYSTEM.Halt call site here).
*)
IMPORT Dos, Files, LogErr, Turbo, Out;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitFail  = 3;

PROCEDURE Usage;
BEGIN
  Out.String("Turbo-to-NASM converter, 2026 (c) DosWorld, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("Usage: TA2NASM file.asm [file2.asm ...]"); Out.Ln;
  Out.Ln;
  Out.String("  Converts each file.asm (Borland Turbo Assembler 5.0, MASM/Ideal"); Out.Ln;
  Out.String("  mode source) to file.nas (NASM-subset syntax) -- feed that into"); Out.Ln;
  Out.String("  TASM.EXE like any other .asm file. May repeat to convert several"); Out.Ln;
  Out.String("  files in one run."); Out.Ln
END Usage;

PROCEDURE RunBody(): INTEGER;
  VAR srcPath, dstPath: ARRAY 128 OF CHAR;
      argc, i: INTEGER;
      ok: BOOLEAN;
BEGIN
  argc := Dos.ParamCount();
  IF argc < 1 THEN Usage; RETURN ExitUsage END;
  ok := TRUE;
  i := 1;
  WHILE ok & (i <= argc) DO
    Dos.ParamStr(i, srcPath);
    Files.ReplaceExt(srcPath, ".NAS", dstPath);
    ok := Turbo.Convert(srcPath, dstPath);
    INC(i)
  END;
  IF ok THEN RETURN ExitOk END;
  RETURN ExitFail
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  LogErr.Close;
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in ta2nasm *)
END Run;

END TA2NASM.
