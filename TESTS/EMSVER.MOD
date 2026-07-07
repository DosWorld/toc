MODULE EmsVer;
(* STANDALONE verification of the SYSTEM2-style buffered Files port and the EMS
   temp-file backend (Files.ReWriteTemp / BkEms).  No Test framework, no
   testall harness: it drives itself and prints PASS/FAIL lines, so it can be
   built with a single  oc /ENTRY=Run EMSVER.MOD  and run under xt.

   It mirrors the compiler's real usage of the SYSTEM2 page mechanism:
     - three concurrent temp files (3 independent 8 KB paged buffers),
     - an ODD record size (277) so writes never align to the 8192 BUFSIZE
       boundary -> exercises NextPage / SwitchPage mid-record,
     - 400 records (277*400 = 110800 > 64 KB) -> forces EMS growth and many
       page reloads,
     - interleaved random-access read-back WHILE the files are still growing
       (exercises BufFetch of an already-written page: the partial-page
       overwrite path that SYSTEM2's SwitchPage must read-before-write).

   With an EMS driver present (xt default) ReWriteTemp uses BkEms; with
   --noems it transparently falls back to a disk temp, and every assertion
   below still holds. *)

IMPORT Out, Files;

CONST
  RecSize = 277;
  NRecs   = 400;

VAR
  buf, rbuf: ARRAY RecSize OF CHAR;
  failed: INTEGER;

PROCEDURE Check(cond: BOOLEAN; msg: ARRAY OF CHAR);
BEGIN
  IF cond THEN
    Out.String("  ok   "); Out.String(msg); Out.Ln
  ELSE
    Out.String("  FAIL "); Out.String(msg); Out.Ln;
    INC(failed)
  END
END Check;

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

PROCEDURE Run*;
  VAR f1, f2, f3: Files.File;
      idx, seed: INTEGER; ok, allW, allR: BOOLEAN;
BEGIN
  failed := 0;
  Out.String("EmsVer: SYSTEM2-port + EMS temp backend"); Out.Ln;

  ok := Files.ReWriteTemp(f1); Check(ok, "rewritetemp f1");
  IF ~ok THEN RETURN END;
  ok := Files.ReWriteTemp(f2); Check(ok, "rewritetemp f2");
  IF ~ok THEN Files.Close(f1); RETURN END;
  ok := Files.ReWriteTemp(f3); Check(ok, "rewritetemp f3");
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
  Check(allW, "all writes full length");
  Check(allR, "interleaved random readback matches");

  (* full sequential verify of every record on every handle *)
  allR := TRUE;
  FOR idx := 0 TO NRecs - 1 DO
    IF ~Rd(f1, 1, idx) THEN allR := FALSE END;
    IF ~Rd(f2, 2, idx) THEN allR := FALSE END;
    IF ~Rd(f3, 3, idx) THEN allR := FALSE END
  END;
  Check(allR, "sequential readback matches");

  Check(Files.Size(f1) = LONGINT(NRecs) * LONGINT(RecSize), "size f1");
  Check(Files.Size(f2) = LONGINT(NRecs) * LONGINT(RecSize), "size f2");
  Check(Files.Size(f3) = LONGINT(NRecs) * LONGINT(RecSize), "size f3");

  Files.Close(f1); Files.Close(f2); Files.Close(f3);

  Out.Ln;
  IF failed = 0 THEN
    Out.String("EmsVer: ALL PASS"); Out.Ln
  ELSE
    Out.String("EmsVer: "); Out.Int(failed, 0); Out.String(" FAILED"); Out.Ln
  END
END Run;

END EmsVer.
