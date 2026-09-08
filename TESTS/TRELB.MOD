MODULE TRELB;
(* Regression test: relational operators on 1-byte variables (BYTE, BOOLEAN).

   Bug reported + fixed 2026-09-08.  PEXPR's memory-operand fast path for
   relops emitted CMP AX,[mem] (opcode 3B) -- a 16-BIT read -- whenever the
   right-hand side was a plain global/local variable of an
   isFastCmpEligible type.  BYTE and BOOLEAN are in that set but occupy a
   single byte, so the compare read the variable's byte PLUS the adjacent
   byte and answered against unrelated memory.

   Two things make this worth a dedicated test rather than a manifest row:

   1. It is a WRONG-ANSWER bug, not a compile failure -- the module compiles
      cleanly either way, so only running it detects the fault.
   2. It is sensitive to what sits NEXT TO the operands in memory, so the
      layout here matters.  `guard` is declared between/around the byte
      pairs on purpose: pre-fix, writing 0FFFFH vs 0 into guard alone
      flipped the result of an unchanged `gb1 = gb2`.

   CHAR and INTEGER were never affected (CHAR is not in isFastCmpEligible,
   INTEGER is genuinely 2 bytes) and are covered too, so a fix that broke
   the already-working paths would fail here as well. *)

IMPORT Test;

VAR
  gb1, gb2: BYTE;
  guard:    INTEGER;      (* deliberately adjacent to the byte pair *)
  gp, gq:   BOOLEAN;
  guard2:   INTEGER;

(* --------- BYTE, locals --------- *)
PROCEDURE TByteLocal*;
  VAR b1, b2: BYTE;
BEGIN
  b1 := 5; b2 := 5;
  Test.AssertTrue (b1 = b2,  "loc BYTE 5=5");
  Test.AssertFalse(b1 # b2,  "loc BYTE 5#5");
  b2 := 6;
  Test.AssertFalse(b1 = b2,  "loc BYTE 5=6");
  Test.AssertTrue (b1 # b2,  "loc BYTE 5#6");
  Test.AssertTrue (b1 < b2,  "loc BYTE 5<6");
  Test.AssertFalse(b1 > b2,  "loc BYTE 5>6");
  Test.AssertTrue (b1 <= b2, "loc BYTE 5<=6");
  Test.AssertTrue (b2 >= b1, "loc BYTE 6>=5");
  (* BYTE is unsigned 0..255: 255 must not compare as a negative number *)
  b1 := 255; b2 := 255;
  Test.AssertTrue (b1 = b2,  "loc BYTE 255=255");
  b2 := 0;
  Test.AssertFalse(b1 = b2,  "loc BYTE 255=0");
  Test.AssertTrue (b1 > b2,  "loc BYTE 255>0");
  Test.AssertTrue (b2 < b1,  "loc BYTE 0<255")
END TByteLocal;

(* --------- BYTE, globals: CgCmpMemGlobal, a different addressing mode --------- *)
PROCEDURE TByteGlobal*;
BEGIN
  gb1 := 9; gb2 := 9;
  Test.AssertTrue (gb1 = gb2, "glob BYTE 9=9");
  Test.AssertFalse(gb1 # gb2, "glob BYTE 9#9");
  gb2 := 10;
  Test.AssertFalse(gb1 = gb2, "glob BYTE 9=10");
  Test.AssertTrue (gb1 # gb2, "glob BYTE 9#10");
  Test.AssertTrue (gb1 < gb2, "glob BYTE 9<10")
END TByteGlobal;

(* --------- BOOLEAN --------- *)
PROCEDURE TBoolCompare*;
  VAR p, q: BOOLEAN;
BEGIN
  p := TRUE; q := TRUE;
  Test.AssertTrue (p = q, "loc BOOL T=T");
  Test.AssertFalse(p # q, "loc BOOL T#T");
  q := FALSE;
  Test.AssertFalse(p = q, "loc BOOL T=F");
  Test.AssertTrue (p # q, "loc BOOL T#F");
  p := FALSE;
  Test.AssertTrue (p = q, "loc BOOL F=F");
  Test.AssertFalse(p # q, "loc BOOL F#F");
  gp := TRUE; gq := TRUE;
  Test.AssertTrue (gp = gq, "glob BOOL T=T");
  Test.AssertFalse(gp # gq, "glob BOOL T#T");
  gq := FALSE;
  Test.AssertFalse(gp = gq, "glob BOOL T=F");
  Test.AssertTrue (gp # gq, "glob BOOL T#F")
END TBoolCompare;

(* --------- the decisive case: adjacent memory must not matter ---------
   Identical comparison, different neighbouring bytes.  Pre-fix these two
   assertions disagreed with each other. *)
PROCEDURE TAdjacentMemory*;
BEGIN
  gb1 := 5; gb2 := 5;
  guard := 0FFFFH; guard2 := 0FFFFH;
  Test.AssertTrue(gb1 = gb2, "BYTE = with neighbours FFFF");
  guard := 0; guard2 := 0;
  Test.AssertTrue(gb1 = gb2, "BYTE = with neighbours 0000");
  gp := TRUE; gq := TRUE;
  guard := 0FFFFH; guard2 := 0FFFFH;
  Test.AssertTrue(gp = gq, "BOOL = with neighbours FFFF");
  guard := 0; guard2 := 0;
  Test.AssertTrue(gp = gq, "BOOL = with neighbours 0000")
END TAdjacentMemory;

(* --------- against a literal: the constant branch, always worked --------- *)
PROCEDURE TAgainstLiteral*;
  VAR b: BYTE; p: BOOLEAN;
BEGIN
  b := 7;
  Test.AssertTrue (b = 7, "BYTE b=7");
  Test.AssertFalse(b # 7, "BYTE b#7");
  Test.AssertTrue (b < 8, "BYTE b<8");
  p := TRUE;
  Test.AssertTrue (p = TRUE,  "BOOL p=TRUE");
  Test.AssertFalse(p # TRUE,  "BOOL p#TRUE");
  Test.AssertFalse(p = FALSE, "BOOL p=FALSE")
END TAgainstLiteral;

(* --------- CHAR / INTEGER: never affected, must stay correct --------- *)
PROCEDURE TUnaffectedTypes*;
  VAR c1, c2: CHAR; i1, i2: INTEGER;
BEGIN
  c1 := "A"; c2 := "A";
  Test.AssertTrue (c1 = c2, "CHAR A=A");
  Test.AssertFalse(c1 # c2, "CHAR A#A");
  c2 := "B";
  Test.AssertFalse(c1 = c2, "CHAR A=B");
  Test.AssertTrue (c1 < c2, "CHAR A<B");
  i1 := 7; i2 := 7;
  Test.AssertTrue (i1 = i2, "INT 7=7");
  i2 := -7;
  Test.AssertFalse(i1 = i2, "INT 7=-7");
  Test.AssertTrue (i1 > i2, "INT 7>-7")
END TUnaffectedTypes;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TByteLocal,       "TRELB/byteLocal");
  Test.AddTest(TByteGlobal,      "TRELB/byteGlobal");
  Test.AddTest(TBoolCompare,     "TRELB/boolCompare");
  Test.AddTest(TAdjacentMemory,  "TRELB/adjacentMemory");
  Test.AddTest(TAgainstLiteral,  "TRELB/againstLiteral");
  Test.AddTest(TUnaffectedTypes, "TRELB/unaffectedTypes");
  Test.RunTests
END RunAllTests;

END TRELB.
