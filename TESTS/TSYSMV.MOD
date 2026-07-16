MODULE TSYSMV;
(* Regression test for the word-op SYSTEM string INLINE patterns:
   MOVE/FILL (SHR CX,1; REP MOVSW/STOSW; ADC CX,CX; REP MOVSB/STOSB),
   COMPARE (REPE CMPSW + odd byte via CMPSB, odd bit parked in DX because
   CMPSW clobbers CF), and Strings.Equal built on COMPARE+LENGTH.

   Verifies byte-exact copies/fills for even and odd lengths (the odd trailing
   byte is the risky path), n=0/1 edge cases, odd (unaligned) src/dst offsets,
   bytes beyond n staying untouched, and compare mismatches in the word part
   vs at the final odd byte. *)

IMPORT Test, Strings;

VAR
  src, dst: ARRAY 40 OF BYTE;

PROCEDURE InitBufs;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < 40 DO
    src[i] := BYTE(i + 1);      (* 1..40, no zeros *)
    dst[i] := BYTE(0AAH);       (* sentinel *)
    INC(i)
  END
END InitBufs;

PROCEDURE CheckMove(n: INTEGER; msg: ARRAY OF CHAR);
  VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  InitBufs;
  SYSTEM.MOVE(src[0], dst[0], WORD(n));
  ok := TRUE;
  i := 0;
  WHILE i < n DO
    IF INTEGER(dst[i]) # i + 1 THEN ok := FALSE END;
    INC(i)
  END;
  WHILE i < 40 DO                       (* bytes past n untouched *)
    IF dst[i] # BYTE(0AAH) THEN ok := FALSE END;
    INC(i)
  END;
  Test.AssertTrue(ok, msg)
END CheckMove;

PROCEDURE TMove*;
BEGIN
  CheckMove(0,  "MOVE n=0");
  CheckMove(1,  "MOVE n=1 (odd)");
  CheckMove(2,  "MOVE n=2 (even)");
  CheckMove(7,  "MOVE n=7 (odd)");
  CheckMove(8,  "MOVE n=8 (even)");
  CheckMove(33, "MOVE n=33 (odd)");
  CheckMove(40, "MOVE n=40 (full)")
END TMove;

PROCEDURE TMoveOddOfs*;
  VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  InitBufs;
  SYSTEM.MOVE(src[1], dst[3], WORD(9));   (* odd src ofs, odd dst ofs, odd n *)
  ok := TRUE;
  i := 0;
  WHILE i < 9 DO
    IF INTEGER(dst[3 + i]) # i + 2 THEN ok := FALSE END;
    INC(i)
  END;
  Test.AssertTrue(ok, "MOVE odd src/dst offsets");
  Test.AssertTrue(dst[2] = BYTE(0AAH), "MOVE dst[2] untouched");
  Test.AssertTrue(dst[12] = BYTE(0AAH), "MOVE dst[12] untouched")
END TMoveOddOfs;

PROCEDURE CheckFill(n, b: INTEGER; msg: ARRAY OF CHAR);
  VAR i: INTEGER; ok: BOOLEAN;
BEGIN
  InitBufs;
  SYSTEM.FILL(dst[0], WORD(n), BYTE(b));
  ok := TRUE;
  i := 0;
  WHILE i < n DO
    IF INTEGER(dst[i]) # b THEN ok := FALSE END;
    INC(i)
  END;
  WHILE i < 40 DO
    IF dst[i] # BYTE(0AAH) THEN ok := FALSE END;
    INC(i)
  END;
  Test.AssertTrue(ok, msg)
END CheckFill;

PROCEDURE TFill*;
BEGIN
  CheckFill(0,  05EH, "FILL n=0");
  CheckFill(1,  05EH, "FILL n=1 (odd)");
  CheckFill(2,  05EH, "FILL n=2 (even)");
  CheckFill(7,  0,    "FILL n=7 zero (odd)");
  CheckFill(8,  0FFH, "FILL n=8 (even)");
  CheckFill(33, 05EH, "FILL n=33 (odd)");
  CheckFill(40, 1,    "FILL n=40 (full)")
END TFill;

PROCEDURE TEqual*;
  VAR a, b: ARRAY 16 OF CHAR;
BEGIN
  Strings.Copy("Parser", a); Strings.Copy("Parser", b);
  Test.AssertTrue(Strings.Equal(a, b), "Equal same");
  Strings.Copy("Parsex", b);
  Test.AssertTrue(~Strings.Equal(a, b), "Equal differ last char");
  Strings.Copy("Xarser", b);
  Test.AssertTrue(~Strings.Equal(a, b), "Equal differ first char");
  Strings.Copy("parser", b);
  Test.AssertTrue(~Strings.Equal(a, b), "Equal case-sensitive");
  Strings.Copy("Parse", b);
  Test.AssertTrue(~Strings.Equal(a, b), "Equal a longer");
  Test.AssertTrue(~Strings.Equal(b, a), "Equal b longer");
  a[0] := 0X; b[0] := 0X;
  Test.AssertTrue(Strings.Equal(a, b), "Equal both empty");
  Strings.Copy("X", b);
  Test.AssertTrue(~Strings.Equal(a, b), "Equal empty vs nonempty")
END TEqual;

PROCEDURE TCompare*;
  VAR i: INTEGER;
BEGIN
  InitBufs;
  i := 0;
  WHILE i < 40 DO dst[i] := src[i]; INC(i) END;   (* identical buffers *)
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 0),  "COMPARE n=0");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 1),  "COMPARE n=1 equal");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 2),  "COMPARE n=2 equal");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 9),  "COMPARE n=9 equal (odd)");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 40), "COMPARE n=40 equal (even)");
  Test.AssertTrue(SYSTEM.COMPARE(src[1], dst[1], 7),  "COMPARE odd ofs equal");
  dst[4] := BYTE(0);                       (* mismatch inside the word part *)
  Test.AssertTrue(~SYSTEM.COMPARE(src[0], dst[0], 9), "COMPARE word-part mismatch");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 4),  "COMPARE stops before mismatch");
  dst[4] := src[4];
  dst[8] := BYTE(0);                       (* mismatch at the final odd byte *)
  Test.AssertTrue(~SYSTEM.COMPARE(src[0], dst[0], 9), "COMPARE odd-byte mismatch");
  Test.AssertTrue(SYSTEM.COMPARE(src[0], dst[0], 8),  "COMPARE n=8 before odd byte");
  dst[0] := BYTE(0);
  Test.AssertTrue(~SYSTEM.COMPARE(src[0], dst[0], 1), "COMPARE n=1 mismatch")
END TCompare;

PROCEDURE TFindByte*;
  VAR r: WORD;
BEGIN
  InitBufs;                                 (* src[i] = i+1, i.e. bytes 1..40 *)
  r := SYSTEM.FINDBYTE(src[0], BYTE(1), WORD(40));
  Test.AssertTrue(r = WORD(0), "FINDBYTE found at start");
  r := SYSTEM.FINDBYTE(src[0], BYTE(40), WORD(40));
  Test.AssertTrue(r = WORD(39), "FINDBYTE found at end");
  r := SYSTEM.FINDBYTE(src[0], BYTE(21), WORD(40));
  Test.AssertTrue(r = WORD(20), "FINDBYTE found in middle");
  r := SYSTEM.FINDBYTE(src[0], BYTE(99), WORD(40));
  Test.AssertTrue(r = WORD(40), "FINDBYTE not found returns maxLen");
  r := SYSTEM.FINDBYTE(src[0], BYTE(1), WORD(0));
  Test.AssertTrue(r = WORD(0), "FINDBYTE maxLen=0 returns 0");
  r := SYSTEM.FINDBYTE(src[5], BYTE(10), WORD(35));  (* odd start ofs *)
  Test.AssertTrue(r = WORD(4), "FINDBYTE odd start offset");
  r := SYSTEM.FINDBYTE(src[0], BYTE(5), WORD(3));    (* match past scan window *)
  Test.AssertTrue(r = WORD(3), "FINDBYTE match beyond maxLen not found")
END TFindByte;

PROCEDURE TStringsPos*;
  VAR s: ARRAY 16 OF CHAR; p: WORD; found: BOOLEAN;
BEGIN
  Strings.Copy("hello,world", s);
  p := 0; found := Strings.Pos(",", s, p);
  Test.AssertTrue(found & (p = WORD(5)), "Pos single-char found");
  p := 0; found := Strings.Pos("x", s, p);
  Test.AssertTrue(~found, "Pos single-char not found");
  p := 0; found := Strings.Pos("d", s, p);
  Test.AssertTrue(found & (p = WORD(10)), "Pos single-char at end");
  p := 6; found := Strings.Pos(",", s, p);
  Test.AssertTrue(~found, "Pos single-char start past match")
END TStringsPos;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TMove,       "TSYSMV/move");
  Test.AddTest(TMoveOddOfs, "TSYSMV/moveOddOfs");
  Test.AddTest(TFill,       "TSYSMV/fill");
  Test.AddTest(TCompare,    "TSYSMV/compare");
  Test.AddTest(TEqual,      "TSYSMV/equal");
  Test.AddTest(TFindByte,   "TSYSMV/findByte");
  Test.AddTest(TStringsPos, "TSYSMV/stringsPos");
  Test.RunTests
END RunAllTests;

END TSYSMV.
