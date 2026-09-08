MODULE Bytebool;
(* Regression: comparing two 1-byte variables (BYTE or BOOLEAN) with a
   relational operator.

   Bug (reported + fixed 2026-09-08): PEXPR's memory-operand fast path for
   relops emitted CMP AX,[mem] -- opcode 3B, a 16-BIT read -- for operands
   whose storage is a single byte.  It therefore compared the variable's byte
   PLUS whatever byte happened to sit next to it, so `b1 = b2` on two equal
   BYTEs answered according to unrelated adjacent memory, and `p = q` and
   `p # q` on the same BOOLEAN pair could BOTH report "differ".  CHAR was
   unaffected only because it is not in isFastCmpEligible.

   Every check below writes "ok" when correct.  A failure prints "BAD".
   Note the deliberate mix of locals and globals, and the `guard` variable
   sitting next to the byte pair: with the bug, changing guard alone flipped
   the answer. *)
IMPORT Out;

VAR gb1, gb2: BYTE;
    gp, gq: BOOLEAN;
    guard: INTEGER;

PROCEDURE Chk(got, want: BOOLEAN);
BEGIN
  IF got = want THEN Out.String("ok ") ELSE Out.String("BAD ") END
END Chk;

PROCEDURE Run*;
  VAR b1, b2: BYTE; p, q: BOOLEAN; c1, c2: CHAR; i1, i2: INTEGER;
BEGIN
  (* BYTE, locals, equal and unequal *)
  b1 := 5; b2 := 5;
  Chk(b1 = b2, TRUE); Chk(b1 # b2, FALSE);
  b2 := 6;
  Chk(b1 = b2, FALSE); Chk(b1 # b2, TRUE);
  Chk(b1 < b2, TRUE);  Chk(b1 > b2, FALSE);
  Chk(b1 <= b2, TRUE); Chk(b2 >= b1, TRUE);

  (* BYTE is unsigned 0..255: 255 must not compare as negative *)
  b1 := 255; b2 := 255;
  Chk(b1 = b2, TRUE);
  b2 := 0;
  Chk(b1 = b2, FALSE); Chk(b1 > b2, TRUE);

  (* BOOLEAN, locals *)
  p := TRUE; q := TRUE;
  Chk(p = q, TRUE);  Chk(p # q, FALSE);
  q := FALSE;
  Chk(p = q, FALSE); Chk(p # q, TRUE);
  p := FALSE;
  Chk(p = q, TRUE);  Chk(p # q, FALSE);

  (* Globals: a different addressing mode (CgCmpMemGlobal, not CgCmpAxBp) *)
  gb1 := 9; gb2 := 9;
  Chk(gb1 = gb2, TRUE); Chk(gb1 # gb2, FALSE);
  gb2 := 10;
  Chk(gb1 = gb2, FALSE); Chk(gb1 # gb2, TRUE);
  gp := TRUE; gq := TRUE;
  Chk(gp = gq, TRUE); Chk(gp # gq, FALSE);
  gq := FALSE;
  Chk(gp = gq, FALSE); Chk(gp # gq, TRUE);

  (* The decisive case: identical comparison, different adjacent memory.
     With the bug these two lines disagreed. *)
  gb1 := 5; gb2 := 5;
  guard := 0FFFFH; Chk(gb1 = gb2, TRUE);
  guard := 0;      Chk(gb1 = gb2, TRUE);

  (* Comparison against a literal used the constant branch and always
     worked -- kept so a regression there would also be caught. *)
  p := TRUE;
  Chk(p = TRUE, TRUE); Chk(p # TRUE, FALSE);
  b1 := 7;
  Chk(b1 = 7, TRUE);   Chk(b1 # 7, FALSE);

  (* CHAR and INTEGER were never affected; checked so a fix that breaks the
     paths which already worked would also be caught here. *)
  c1 := "A"; c2 := "A";
  Chk(c1 = c2, TRUE); Chk(c1 # c2, FALSE);
  c2 := "B";
  Chk(c1 = c2, FALSE); Chk(c1 < c2, TRUE);
  i1 := 7; i2 := 7;
  Chk(i1 = i2, TRUE); Chk(i1 # i2, FALSE);
  i2 := -7;
  Chk(i1 = i2, FALSE); Chk(i1 > i2, TRUE);
  Out.Ln
END Run;

END Bytebool.
