MODULE TOPT;
(* Runtime correctness tests for the strength-reduction / peephole optimizer
   (opt.md Phase 1: A multiply->SHL, B div->SAR/SHR, C mod->AND, E array-index
   scaling, G x+/-0 identity, H 0-x->NEG).

   The optimizer only fires when ONE operand is a compile-time constant power of
   two (0, 1, 2, 4, 8, ...).  To exercise it we keep the other operand in a
   VARIABLE (so it is not constant-folded away) and compare the result against
   the value computed the slow way.  The tricky cases are NEGATIVE dividends:
   Oberon DIV floors toward -infinity (matches 8086 SAR) and Oberon MOD is the
   non-negative remainder (matches AND for power-of-two divisors). *)

IMPORT Test;

(* ---- multiply by power of two (both operand orders) ---- *)

PROCEDURE TMulInt*;
  VAR x: INTEGER;
BEGIN
  x := 7;
  Test.AssertInt(14,  x * 2,   "int 7*2");
  Test.AssertInt(14,  2 * x,   "int 2*7");
  Test.AssertInt(56,  x * 8,   "int 7*8");
  Test.AssertInt(56,  8 * x,   "int 8*7");
  Test.AssertInt(7168, x * 1024, "int 7*1024");
  Test.AssertInt(7,   x * 1,   "int 7*1 identity");
  Test.AssertInt(0,   x * 0,   "int 7*0");
  Test.AssertInt(0,   0 * x,   "int 0*7");
  x := -5;
  Test.AssertInt(-20, x * 4,   "int -5*4");
  Test.AssertInt(-20, 4 * x,   "int 4*-5")
END TMulInt;

(* ---- shift+add multipliers (opt.md D): 3,5,6,7,9,10,12,15 ---- *)

PROCEDURE TMulSmall*;
  VAR x: INTEGER;
BEGIN
  x := 11;
  Test.AssertInt(33,  x * 3,  "int 11*3");
  Test.AssertInt(55,  x * 5,  "int 11*5");
  Test.AssertInt(66,  x * 6,  "int 11*6");
  Test.AssertInt(77,  x * 7,  "int 11*7");
  Test.AssertInt(99,  x * 9,  "int 11*9");
  Test.AssertInt(110, x * 10, "int 11*10");
  Test.AssertInt(132, x * 12, "int 11*12");
  Test.AssertInt(165, x * 15, "int 11*15");
  Test.AssertInt(33,  3 * x,  "int 3*11 (commutative)");
  Test.AssertInt(77,  7 * x,  "int 7*11 (commutative)");
  x := -4;
  Test.AssertInt(-12, x * 3,  "int -4*3");
  Test.AssertInt(-28, x * 7,  "int -4*7");
  Test.AssertInt(-36, x * 9,  "int -4*9")
END TMulSmall;

(* ---- WORD (unsigned) multiply / divide / modulo ---- *)

PROCEDURE TWord*;
  VAR w: WORD;
BEGIN
  w := WORD(40000);                              (* > 32767: unsigned-only *)
  Test.AssertWord(WORD(20000), w DIV 2,  "word 40000 DIV 2 (unsigned SHR)");
  Test.AssertWord(WORD(5000),  w DIV 8,  "word 40000 DIV 8");
  Test.AssertWord(WORD(0),     w MOD 8,  "word 40000 MOD 8");
  Test.AssertWord(WORD(64),    w MOD 128, "word 40000 MOD 128");
  w := WORD(1000);
  Test.AssertWord(WORD(4000),  w * 4,    "word 1000*4")
END TWord;

(* ---- divide by power of two ---- *)

PROCEDURE TDivInt*;
  VAR x: INTEGER;
BEGIN
  x := 100;
  Test.AssertInt(50, x DIV 2, "int 100 DIV 2");
  Test.AssertInt(25, x DIV 4, "int 100 DIV 4");
  Test.AssertInt(6,  x DIV 16, "int 100 DIV 16");
  Test.AssertInt(100, x DIV 1, "int 100 DIV 1 identity");
  (* NEGATIVE dividend: Oberon DIV floors toward -inf, 8086 SAR matches. *)
  x := -7;
  Test.AssertInt(-4, x DIV 2, "int -7 DIV 2 (floor)");
  x := -8;
  Test.AssertInt(-4, x DIV 2, "int -8 DIV 2");
  x := -1;
  Test.AssertInt(-1, x DIV 2, "int -1 DIV 2 (floor -> -1)");
  x := -16;
  Test.AssertInt(-2, x DIV 8, "int -16 DIV 8")
END TDivInt;

(* ---- modulo by power of two ---- *)

PROCEDURE TModInt*;
  VAR x: INTEGER;
BEGIN
  x := 100;
  Test.AssertInt(0, x MOD 2,  "int 100 MOD 2");
  Test.AssertInt(0, x MOD 4,  "int 100 MOD 4");
  Test.AssertInt(4, x MOD 16, "int 100 MOD 16");
  x := 7;
  Test.AssertInt(1, x MOD 2,  "int 7 MOD 2");
  Test.AssertInt(3, x MOD 4,  "int 7 MOD 4");
  Test.AssertInt(7, x MOD 8,  "int 7 MOD 8");
  (* NEGATIVE dividend: Oberon MOD is non-negative for positive divisor;
     AND mask gives the low bits which equal that. *)
  x := -5;
  Test.AssertInt(3, x MOD 4,  "int -5 MOD 4 (= 3)");
  x := -1;
  Test.AssertInt(1, x MOD 2,  "int -1 MOD 2 (= 1)");
  x := -8;
  Test.AssertInt(0, x MOD 8,  "int -8 MOD 8 (= 0)");
  x := -7;
  Test.AssertInt(9, x MOD 16, "int -7 MOD 16 (= 9)")
END TModInt;

(* ---- LONGINT multiply / divide / modulo ---- *)

PROCEDURE TLong*;
  VAR x: LONGINT;
BEGIN
  x := LONGINT(1000);
  Test.AssertLong(LONGINT(2000),   x * 2,    "long 1000*2");
  Test.AssertLong(LONGINT(8000),   x * 8,    "long 1000*8");
  Test.AssertLong(LONGINT(65536000), x * 65536, "long 1000*65536");
  Test.AssertLong(LONGINT(500),    x DIV 2,  "long 1000 DIV 2");
  Test.AssertLong(LONGINT(62),     x DIV 16, "long 1000 DIV 16");
  Test.AssertLong(LONGINT(0),      x MOD 8,  "long 1000 MOD 8");
  Test.AssertLong(LONGINT(40),     x MOD 64, "long 1000 MOD 64");
  (* negative LONGINT dividend *)
  x := -LONGINT(7);
  Test.AssertLong(-LONGINT(4),     x DIV 2,  "long -7 DIV 2 (floor)");
  Test.AssertLong(LONGINT(1),      x MOD 2,  "long -7 MOD 2 (= 1)");
  (* MOD by a power > 2^16 to exercise CgAndImm32 hi-word path.
     1000000 = 7*131072 + 82496, so 1000000 MOD 131072 = 82496. *)
  x := LONGINT(1000000);
  Test.AssertLong(LONGINT(82496), x MOD 131072, "long 1000000 MOD 131072")
END TLong;

(* ---- add/sub identity and 0-x -> NEG ---- *)

PROCEDURE TAddSub*;
  VAR x: INTEGER; l: LONGINT;
BEGIN
  x := 42;
  Test.AssertInt(42,  x + 0,  "int x+0");
  Test.AssertInt(42,  x - 0,  "int x-0");
  Test.AssertInt(42,  0 + x,  "int 0+x");
  Test.AssertInt(-42, 0 - x,  "int 0-x -> NEG");
  x := -13;
  Test.AssertInt(13,  0 - x,  "int 0 - (-13) -> 13");
  l := LONGINT(100000);
  Test.AssertLong(LONGINT(100000),  l + 0, "long l+0");
  Test.AssertLong(LONGINT(100000),  l - 0, "long l-0");
  Test.AssertLong(-LONGINT(100000), -l,    "long -l (unary)")
END TAddSub;

(* ---- array index scaling (Opt E): element sizes 4, 8 are powers of two ---- *)

PROCEDURE TArrayIndex*;
  VAR la: ARRAY 8 OF LONGINT;     (* elem size 4 -> SHL AX,2 *)
      i: INTEGER;
BEGIN
  i := 0; WHILE i < 8 DO la[i] := LONGINT(i) * LONGINT(1000) + LONGINT(7); INC(i) END;
  (* read back via a variable index so the scaling code path runs *)
  i := 5;
  Test.AssertLong(LONGINT(5007), la[i], "arr[LONGINT] index*4 scaling");
  i := 0;
  Test.AssertLong(LONGINT(7),    la[i], "arr[LONGINT] index 0");
  i := 7;
  Test.AssertLong(LONGINT(7007), la[i], "arr[LONGINT] index 7");
  (* write through a variable index too *)
  i := 3; la[i] := LONGINT(424242);
  Test.AssertLong(LONGINT(424242), la[3], "arr[LONGINT] write via var index")
END TArrayIndex;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TMulInt,     "TOPT/mul-int");
  Test.AddTest(TMulSmall,   "TOPT/mul-small");
  Test.AddTest(TWord,       "TOPT/word");
  Test.AddTest(TDivInt,     "TOPT/div-int");
  Test.AddTest(TModInt,     "TOPT/mod-int");
  Test.AddTest(TLong,       "TOPT/longint");
  Test.AddTest(TAddSub,     "TOPT/addsub-identity");
  Test.AddTest(TArrayIndex, "TOPT/array-index");
  Test.RunTests
END RunAllTests;

END TOPT.
