(*$M 8192, 65536, 131072*)
MODULE Dosarg;

(* Regression test for Dos.ParamStr(0, p) — argv[0] from PSP environment.

   Pre-fix (2026-05-22) the 2-byte program-count WORD past the env strings
   was being skipped by double-incrementing the offset (an explicit INC
   after each byte plus a final INC(ofs, 2)), so ofs landed one past the
   first char of the program name.  Effect: ParamStr(0) returned the
   program path with its first character dropped — e.g. "OSARG.EXE"
   instead of "DOSARG.EXE", or "arprint.exe" instead of "parprint.exe".

   When the linker writes this fixture's .EXE it uppercases the basename
   to "DOSARG.EXE" and xt loads it that way; PSP argv[0] is exactly
   "DOSARG.EXE".  We compare ParamStr(0) byte by byte against that
   literal; the truncated form would be "OSARG.EXE" (9 chars) and the
   length check alone catches it.

   Exit codes:
     0  argv[0] == "DOSARG.EXE" — PASS
     1  ParamStr returned an empty string
     2  argv[0] has wrong length (not 10 chars)
     3  argv[0] content does NOT match "DOSARG.EXE"
*)
IMPORT Dos;

PROCEDURE Run*;
VAR p: ARRAY 80 OF CHAR;
    expected: ARRAY 11 OF CHAR;
    n, i: INTEGER;
BEGIN
    expected[0] := "D"; expected[1] := "O"; expected[2] := "S";
    expected[3] := "A"; expected[4] := "R"; expected[5] := "G";
    expected[6] := "."; expected[7] := "E"; expected[8] := "X";
    expected[9] := "E"; expected[10] := 0X;

    Dos.ParamStr(0, p);
    IF p[0] = 0X THEN SYSTEM.Halt(1); RETURN END;
    n := 0;
    WHILE (n < LEN(p)) & (p[n] # 0X) DO INC(n) END;
    IF n # 10 THEN SYSTEM.Halt(2); RETURN END;
    i := 0;
    WHILE i < 10 DO
      IF p[i] # expected[i] THEN SYSTEM.Halt(3); RETURN END;
      INC(i)
    END
END Run;

END Dosarg.
