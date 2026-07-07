MODULE TPRSR;
(* End-to-end parser tests for Parser (no C counterpart).
   Each test opens a fixture from tests/FIX/, runs Parser.ParseModule,
   then verifies the parse error count and inspects the produced .def
   file to assert expected behavior.  ParseModule frees the symbol table
   before returning, so post-parse checks must use the artefacts on disk.
   Fixtures live in tests/FIX/ with DOS 8.3 filenames; the test runner
   (test_src.sh Section 18) copies each fixture into the workdir before
   running the test. *)

IMPORT Test, Files, Scan, Parser;

VAR
  defText: ARRAY 4096 OF CHAR;
  defLen:  INTEGER;

(* Byte-level substring search.  Cannot use Strings.Pos: the .om archive
   is binary with embedded NUL bytes inside ustar headers, and Strings.Pos
   relies on SYSTEM.LENGTH which stops at the first NUL. *)
PROCEDURE findBytes(pat: ARRAY OF CHAR): BOOLEAN;
  VAR i, j, lp: INTEGER; match: BOOLEAN;
BEGIN
  lp := 0;
  WHILE (lp < LEN(pat)) & (pat[lp] # 0X) DO INC(lp) END;
  IF lp = 0 THEN RETURN TRUE END;
  i := 0;
  WHILE i + lp <= defLen DO
    j := 0;
    WHILE (j < lp) & (defText[i + j] = pat[j]) DO INC(j) END;
    IF j = lp THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END findBytes;

PROCEDURE parseFixture(VAR s: Scan.Scanner; fname: ARRAY OF CHAR): BOOLEAN;
BEGIN
  Scan.Open(s, fname);   (* Open primes the first token via Next *)
  IF s.sym = Scan.TEof THEN Scan.Close(s); RETURN FALSE END;
  Parser.ParseModule(s);
  Scan.Close(s);
  RETURN Parser.parserErrors = 0
END parseFixture;

(* Slurp file contents into defText.  ParseModule's .om archive contains
   <MODNAME>.DEF; for inspection we instead read the .def directly off
   disk — but ParseModule deletes it after tar-packing.  Instead, parse
   the .om archive's USTAR header lookup is complex, so this test reads
   the .def in a separate compile: we deliberately leave the .def by
   compiling with the C-side `oc` test path... but that's not how
   ParseModule works.  Simpler: just verify parserErrors==0 + .om exists. *)
PROCEDURE slurp(name: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File; size: LONGINT; n: WORD; ok: BOOLEAN;
BEGIN
  ok := Files.Reset(f, name);
  IF ~ok THEN defLen := 0; defText[0] := 0X; RETURN FALSE END;
  size := Files.Size(f);
  IF size > LONGINT(LEN(defText) - 1) THEN size := LONGINT(LEN(defText) - 1) END;
  defLen := INTEGER(size);
  Files.Seek(f, 0);
  n := Files.BlockRead(f, defText, WORD(size));
  defText[defLen] := 0X;
  Files.Close(f);
  RETURN TRUE
END slurp;

(* ---- PRSR01.MOD: simple module with CONST/VAR/PROC ---- *)

PROCEDURE TSimpleModule*;
  VAR sc: Scan.Scanner; ok: BOOLEAN;
BEGIN
  ok := parseFixture(sc, "PRSR01.MOD");
  Test.AssertTrue(ok, "PRSR01 parses without errors");
  Test.AssertTrue(Parser.parserModName = "Prsr01", "PRSR01 module name");
  (* ParseModule writes Prsr01.om and removes Prsr01.rdf / Prsr01.def. *)
  Test.AssertTrue(slurp("Prsr01.om"), "PRSR01 produced .om");
  Test.AssertTrue(findBytes("PRSR01.DEF"), "PRSR01.om contains PRSR01.DEF entry");
  Test.AssertTrue(findBytes("PRSR01.RDF"), "PRSR01.om contains PRSR01.RDF entry");
  Test.AssertTrue(findBytes("PROC Prsr01_Add"),
                  "PRSR01 .def declares PROC Prsr01_Add")
END TSimpleModule;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TSimpleModule, "Prsr/simple-module");
  Test.RunTests
END RunAllTests;

END TPRSR.
