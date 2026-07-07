MODULE TFBUF;
(* Regression test for the Files buffered-I/O power-of-two MOD fix (P0, 2026-06-13).

   Files.BlockRead/BlockWrite compute the buffer tag/offset from F.pos.  The fix
   replaced `F.pos MOD BUFSIZE` (a slow 32-bit software-division, the compile-time
   slowdown) with `SYSTEM.AND(F.pos, BUFSIZE-1)` (a bit mask, BUFSIZE = 8192 is a
   power of two).  This test exercises reads/writes that *cross* the 8192-byte
   buffer boundary, so a wrong tag/offset mask shows up as corrupted bytes.

   It is a pure functional test (does not depend on the compiler internals): it
   catches any miscompiled or mismasked buffer arithmetic. *)

IMPORT Test, Files;

CONST
  N = 20000;            (* > 2*BUFSIZE(8192): forces several buffer reloads *)

VAR
  Name: ARRAY 10 OF CHAR;

(* deterministic byte pattern so position p maps to a known value *)
PROCEDURE Pat(p: LONGINT): BYTE;
BEGIN
  RETURN BYTE((p * LONGINT(7) + LONGINT(3)) MOD LONGINT(251))
END Pat;

PROCEDURE TWriteReadCrossBoundary*;
  VAR f: Files.File; i: LONGINT; b: BYTE; nw, nr: WORD; ok: BOOLEAN;
      buf: ARRAY 1 OF BYTE;
BEGIN
  ok := Files.ReWrite(f, Name);
  Test.AssertTrue(ok, "fbuf/rewrite");
  IF ~ok THEN RETURN END;

  i := 0;
  WHILE i < N DO
    buf[0] := Pat(i);
    nw := Files.BlockWrite(f, buf[0], 1);
    Test.AssertWord(WORD(1), nw, "fbuf/write count");
    INC(i)
  END;
  Files.Close(f);

  ok := Files.Reset(f, Name);
  Test.AssertTrue(ok, "fbuf/reset");
  IF ~ok THEN RETURN END;

  (* read back sequentially, verifying every byte across all buffer boundaries *)
  i := 0; ok := TRUE;
  WHILE (i < N) & ok DO
    nr := Files.BlockRead(f, buf[0], 1);
    IF nr # WORD(1) THEN ok := FALSE
    ELSIF buf[0] # Pat(i) THEN ok := FALSE
    END;
    INC(i)
  END;
  Test.AssertTrue(ok, "fbuf/readback all bytes match");
  Files.Close(f);

  (* random-access spot checks straddling the 8192 boundary *)
  ok := Files.Reset(f, Name);
  IF ok THEN
    Files.Seek(f, LONGINT(8191)); nr := Files.BlockRead(f, b, 1);
    Test.AssertByte(Pat(LONGINT(8191)), b, "fbuf/seek 8191");
    Files.Seek(f, LONGINT(8192)); nr := Files.BlockRead(f, b, 1);
    Test.AssertByte(Pat(LONGINT(8192)), b, "fbuf/seek 8192 (boundary)");
    Files.Seek(f, LONGINT(8193)); nr := Files.BlockRead(f, b, 1);
    Test.AssertByte(Pat(LONGINT(8193)), b, "fbuf/seek 8193");
    Files.Seek(f, LONGINT(16384)); nr := Files.BlockRead(f, b, 1);
    Test.AssertByte(Pat(LONGINT(16384)), b, "fbuf/seek 16384 (2x boundary)");
    Files.Close(f)
  END;

  ok := Files.Delete(Name);
  Test.AssertTrue(ok, "fbuf/delete tmp")
END TWriteReadCrossBoundary;

PROCEDURE RunAllTests*;
BEGIN
  Name := "TFBUF.TMP";
  Test.AddTest(TWriteReadCrossBoundary, "TFBUF/writeReadCrossBoundary");
  Test.RunTests
END RunAllTests;

END TFBUF.
