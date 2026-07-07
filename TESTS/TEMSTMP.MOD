MODULE TEMSTMP;
(* Regression test for the EMS temp-file backend (Files.ReWriteTemp / BkEms),
   unified into the buffered BufFetch/BufFlush path (2026-06-26).

   Before the fix, BkEms had its own parallel staging path in BlockRead/
   BlockWrite (a separate 1024-byte global + per-call EMM moves with manual
   odd-tail padding), distinct from the disk path's 8 KB F.buf.  Under the
   compiler's concurrent multi-handle, interleaved random-access usage that
   path diverged: a compile under EMS produced no output.  The fix routes EMS
   through the SAME F.buf and BufFetch/BufFlush as disk.

   This test mirrors the compiler's usage: three concurrent EMS temp files,
   odd record size, writes that cross the 8192-byte BUFSIZE boundary, and
   interleaved random-access reads while the files grow.

   When no EMS driver is present (e.g. xt run --noems) ReWriteTemp transparently
   falls back to a disk temp, so the SAME assertions still hold and the test
   passes on both configurations. *)

IMPORT Test, Files;

CONST
  RecSize = 277;        (* odd: exercises the even-rounding of EMM moves *)
  NRecs   = 400;        (* 277*400 = 110800 bytes > 64 KB: forces EMS growth
                           and several BUFSIZE reloads *)

VAR
  buf, rbuf: ARRAY RecSize OF CHAR;

(* deterministic per-(tag,idx,byte) pattern *)
PROCEDURE Fill(VAR b: ARRAY OF CHAR; tag, idx: INTEGER);
  VAR k: INTEGER;
BEGIN
  FOR k := 0 TO RecSize - 1 DO
    b[k] := CHR((tag * 131 + idx * 7 + k) MOD 256)
  END
END Fill;

PROCEDURE Wr(VAR f: Files.File; tag, idx: INTEGER): BOOLEAN;
  VAR n: WORD;
BEGIN
  Fill(buf, tag, idx);
  Files.Seek(f, LONGINT(idx) * LONGINT(RecSize));
  n := Files.BlockWrite(f, buf, RecSize);
  RETURN n = WORD(RecSize)
END Wr;

PROCEDURE Rd(VAR f: Files.File; tag, idx: INTEGER): BOOLEAN;
  VAR n: WORD; k: INTEGER; ok: BOOLEAN;
BEGIN
  Files.Seek(f, LONGINT(idx) * LONGINT(RecSize));
  n := Files.BlockRead(f, rbuf, RecSize);
  IF n # WORD(RecSize) THEN RETURN FALSE END;
  Fill(buf, tag, idx);
  ok := TRUE;
  FOR k := 0 TO RecSize - 1 DO
    IF rbuf[k] # buf[k] THEN ok := FALSE END
  END;
  RETURN ok
END Rd;

PROCEDURE TConcurrentInterleaved*;
  VAR f1, f2, f3: Files.File;
      idx, seed: INTEGER; ok, allW, allR: BOOLEAN;
BEGIN
  ok := Files.ReWriteTemp(f1); Test.AssertTrue(ok, "emstmp/rewritetemp f1");
  IF ~ok THEN RETURN END;
  ok := Files.ReWriteTemp(f2); Test.AssertTrue(ok, "emstmp/rewritetemp f2");
  IF ~ok THEN Files.Close(f1); RETURN END;
  ok := Files.ReWriteTemp(f3); Test.AssertTrue(ok, "emstmp/rewritetemp f3");
  IF ~ok THEN Files.Close(f1); Files.Close(f2); RETURN END;

  (* interleaved write across 3 handles + immediate random-access read-back *)
  allW := TRUE; allR := TRUE; seed := 12345;
  FOR idx := 0 TO NRecs - 1 DO
    IF ~Wr(f1, 1, idx) THEN allW := FALSE END;
    IF ~Wr(f2, 2, idx) THEN allW := FALSE END;
    IF ~Wr(f3, 3, idx) THEN allW := FALSE END;
    seed := (seed * 1103 + 12345) MOD 32768;
    IF ~Rd(f1, 1, seed MOD (idx + 1)) THEN allR := FALSE END;
    IF ~Rd(f2, 2, seed MOD (idx + 1)) THEN allR := FALSE END;
    IF ~Rd(f3, 3, seed MOD (idx + 1)) THEN allR := FALSE END
  END;
  Test.AssertTrue(allW, "emstmp/all writes full length");
  Test.AssertTrue(allR, "emstmp/interleaved readback matches");

  (* full sequential verify of every record on every handle *)
  allR := TRUE;
  FOR idx := 0 TO NRecs - 1 DO
    IF ~Rd(f1, 1, idx) THEN allR := FALSE END;
    IF ~Rd(f2, 2, idx) THEN allR := FALSE END;
    IF ~Rd(f3, 3, idx) THEN allR := FALSE END
  END;
  Test.AssertTrue(allR, "emstmp/sequential readback matches");

  Test.AssertLong(LONGINT(NRecs) * LONGINT(RecSize), Files.Size(f1),
                  "emstmp/size f1");

  Files.Close(f1); Files.Close(f2); Files.Close(f3)
END TConcurrentInterleaved;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TConcurrentInterleaved, "TEMSTMP/concurrentInterleaved");
  Test.RunTests
END RunAllTests;

END TEMSTMP.
