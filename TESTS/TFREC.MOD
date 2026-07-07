MODULE TFREC;
(* Regression test for the imported-record-size / embedded Files.File bug
   (gr_bug, 2026-06-23).

   When a module embeds a `Files.File` as a field of its own RECORD and places
   another field IMMEDIATELY AFTER it, the offset of that trailing field is
   `offset(file) + SIZE(Files.File)`.  SIZE(Files.File) must be the size the
   `Files` .def reports (it is an opaque `RECORD <n> END` to importers).  If the
   importing module is compiled against a STALE Files (e.g. the size before the
   EMS backend added `backend`/`emsHandle`/`emsCap`), the trailing field aliases
   a real field inside the File record — so writing the trailing field silently
   corrupts the file's internal state.

   The original symptom: SCAN.MOD's `Scanner` record has `file: Files.File`
   followed by `fileOpen: BOOLEAN`.  A stale (278-byte) Files.File put `fileOpen`
   on top of `file.backend`; `s.fileOpen := Files.Reset(...)` then flipped the
   backend to BkEms, so the next BlockRead took the (absent) EMS path and read 0
   bytes → every source read came back empty.

   This test reproduces that shape: a `File` embedded in a record, a trailing
   BOOLEAN written right after Reset, then a real read.  If the imported size is
   wrong the trailing-field write corrupts the file and the read returns 0 / wrong
   bytes. *)

IMPORT Test, Files;

CONST N = 64;

TYPE
  (* mirror the Scanner-style layout: an embedded File followed by a BOOLEAN
     and an INTEGER, exactly the situation that broke. *)
  Wrap = RECORD
    f:     Files.File;
    open:  BOOLEAN;
    extra: INTEGER
  END;

VAR
  Name: ARRAY 12 OF CHAR;

PROCEDURE Pat(p: LONGINT): BYTE;
BEGIN
  RETURN BYTE((p * LONGINT(13) + LONGINT(5)) MOD LONGINT(251))
END Pat;

(* Write a small file through an embedded-File record, then read it back while
   setting the trailing fields right after Reset (the corruption trigger). *)
PROCEDURE TEmbeddedFileReadback*;
  VAR w: Wrap; i: LONGINT; buf: ARRAY 1 OF BYTE; nw, nr: WORD; ok, allOk: BOOLEAN;
BEGIN
  w.open := FALSE; w.extra := 0;
  ok := Files.ReWrite(w.f, Name);
  Test.AssertTrue(ok, "frec/rewrite");
  IF ~ok THEN RETURN END;

  i := 0;
  WHILE i < N DO
    buf[0] := Pat(i);
    nw := Files.BlockWrite(w.f, buf[0], 1);
    Test.AssertWord(WORD(1), nw, "frec/write count");
    INC(i)
  END;
  Files.Close(w.f);

  (* This is the exact shape of the bug: assign a BOOLEAN field that sits right
     after the embedded File, right after Reset.  With a wrong imported File size
     this write lands inside the File record and corrupts its backend/handle. *)
  w.open := Files.Reset(w.f, Name);
  w.extra := 12345;
  Test.AssertTrue(w.open, "frec/reset (trailing field must not alias File)");
  IF ~w.open THEN RETURN END;

  i := 0; allOk := TRUE;
  WHILE (i < N) & allOk DO
    nr := Files.BlockRead(w.f, buf[0], 1);
    IF nr # WORD(1) THEN allOk := FALSE
    ELSIF buf[0] # Pat(i) THEN allOk := FALSE
    END;
    INC(i)
  END;
  Test.AssertTrue(allOk, "frec/readback all bytes match");

  (* trailing fields must still hold what we stored (not be clobbered by I/O) *)
  Test.AssertTrue(w.open, "frec/open field intact after reads");
  Test.AssertInt(12345, w.extra, "frec/extra field intact after reads");
  Files.Close(w.f);

  ok := Files.Delete(Name);
  Test.AssertTrue(ok, "frec/delete tmp")
END TEmbeddedFileReadback;

PROCEDURE RunAllTests*;
BEGIN
  Name := "TFREC.TMP";
  Test.AddTest(TEmbeddedFileReadback, "TFREC/embeddedFileReadback");
  Test.RunTests
END RunAllTests;

END TFREC.
