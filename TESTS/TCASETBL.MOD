MODULE TCASETBL;
(* Regression test for the CASE jump-table dispatch codegen (G7, opt.md).

   A dense CASE (>= 6 single-value integer/CHAR labels, span <= 2x label
   count) now dispatches via an indexed jump table instead of the linear
   compare chain.  This exercises the table path specifically: correct
   dispatch to each arm, correct fallthrough on out-of-range values (both
   below lo and above hi), correct ELSE handling, negative labels, CHAR
   labels, and first-arm-wins on a duplicate label (matching the chain
   path's pre-existing behavior) — a bad bounds check, scaling, or table
   patch would misdispatch or crash. *)

IMPORT Test;

(* Six dense single-value INTEGER labels, no ELSE: exercises the basic
   table path plus the default (no-match) fallthrough. *)
PROCEDURE TDenseNoElse*;
  VAR x, r: INTEGER;
BEGIN
  x := 1; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  END;
  Test.AssertInt(10, r, "label 1");

  x := 6; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  END;
  Test.AssertInt(60, r, "label 6 (last slot)");

  (* out of range below lo *)
  x := 0; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  END;
  Test.AssertInt(-1, r, "below range: no match, falls through");

  (* out of range above hi *)
  x := 7; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  END;
  Test.AssertInt(-1, r, "above range: no match, falls through");

  (* far out of range (still must not crash / must not mis-scale) *)
  x := 30000; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  END;
  Test.AssertInt(-1, r, "far above range: no match, falls through")
END TDenseNoElse;

(* Same shape but with an ELSE clause: out-of-range values must hit ELSE,
   not the "fall through past the CASE" default. *)
PROCEDURE TDenseWithElse*;
  VAR x, r: INTEGER;
BEGIN
  x := 3; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  ELSE r := 999
  END;
  Test.AssertInt(30, r, "matched label with ELSE present");

  x := 0; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  ELSE r := 999
  END;
  Test.AssertInt(999, r, "below range hits ELSE");

  x := 100; r := -1;
  CASE x OF
    1: r := 10 | 2: r := 20 | 3: r := 30
  | 4: r := 40 | 5: r := 50 | 6: r := 60
  ELSE r := 999
  END;
  Test.AssertInt(999, r, "above range hits ELSE")
END TDenseWithElse;

(* Negative labels spanning zero — exercises the SUB AX,lo underflow-to-huge-
   unsigned bounds check with lo itself negative. *)
PROCEDURE TDenseNegative*;
  VAR x, r: INTEGER;
BEGIN
  x := -3; r := -1;
  CASE x OF
    -3: r := 100 | -2: r := 200 | -1: r := 300
  |  0: r := 400 |  1: r := 500 |  2: r := 600
  END;
  Test.AssertInt(100, r, "negative lo label");

  x := 2; r := -1;
  CASE x OF
    -3: r := 100 | -2: r := 200 | -1: r := 300
  |  0: r := 400 |  1: r := 500 |  2: r := 600
  END;
  Test.AssertInt(600, r, "positive hi label");

  x := -4; r := -1;
  CASE x OF
    -3: r := 100 | -2: r := 200 | -1: r := 300
  |  0: r := 400 |  1: r := 500 |  2: r := 600
  END;
  Test.AssertInt(-1, r, "below negative range: no match");

  x := 3; r := -1;
  CASE x OF
    -3: r := 100 | -2: r := 200 | -1: r := 300
  |  0: r := 400 |  1: r := 500 |  2: r := 600
  END;
  Test.AssertInt(-1, r, "above range (positive side): no match")
END TDenseNegative;

(* CHAR selector, dense — table path also applies to CHAR per PreScanLabel. *)
PROCEDURE TDenseChar*;
  VAR c: CHAR; r: INTEGER;
BEGIN
  c := "c"; r := -1;
  CASE c OF
    "a": r := 1 | "b": r := 2 | "c": r := 3
  | "d": r := 4 | "e": r := 5 | "f": r := 6
  END;
  Test.AssertInt(3, r, "CHAR label match");

  c := "z"; r := -1;
  CASE c OF
    "a": r := 1 | "b": r := 2 | "c": r := 3
  | "d": r := 4 | "e": r := 5 | "f": r := 6
  END;
  Test.AssertInt(-1, r, "CHAR out of range: no match")
END TDenseChar;

(* A comma-separated label list within one arm: label->slot mapping must
   handle multiple labels claiming the SAME arm's body offset. *)
PROCEDURE TDenseCommaList*;
  VAR x, r: INTEGER;
BEGIN
  x := 2; r := -1;
  CASE x OF
    1, 2, 3: r := 111
  | 4: r := 4 | 5: r := 5 | 6: r := 6 | 7: r := 7
  END;
  Test.AssertInt(111, r, "comma-list label 2 -> shared arm");

  x := 1; r := -1;
  CASE x OF
    1, 2, 3: r := 111
  | 4: r := 4 | 5: r := 5 | 6: r := 6 | 7: r := 7
  END;
  Test.AssertInt(111, r, "comma-list label 1 -> shared arm");

  x := 3; r := -1;
  CASE x OF
    1, 2, 3: r := 111
  | 4: r := 4 | 5: r := 5 | 6: r := 6 | 7: r := 7
  END;
  Test.AssertInt(111, r, "comma-list label 3 -> shared arm")
END TDenseCommaList;

(* A range label anywhere in the CASE must force the WHOLE case onto the
   chain path (PreScanCase bails on TDotdot) — still must work correctly,
   just not via the table. *)
PROCEDURE TDenseWithRangeFallsBackToChain*;
  VAR x, r: INTEGER;
BEGIN
  x := 4; r := -1;
  CASE x OF
    1: r := 1 | 2: r := 2 | 3..5: r := 345
  | 6: r := 6 | 7: r := 7 | 8: r := 8
  END;
  Test.AssertInt(345, r, "range label still matches (chain fallback)");

  x := 7; r := -1;
  CASE x OF
    1: r := 1 | 2: r := 2 | 3..5: r := 345
  | 6: r := 6 | 7: r := 7 | 8: r := 8
  END;
  Test.AssertInt(7, r, "single label after a range still matches")
END TDenseWithRangeFallsBackToChain;

(* Nested control flow inside a table-dispatched arm's body — exercises
   SkipArmBody's nesting-depth tracking (IF/WHILE/FOR/CASE -> END,
   REPEAT -> UNTIL) during the pre-scan. *)
PROCEDURE TDenseNestedBody*;
  VAR x, r, i: INTEGER;
BEGIN
  x := 3; r := 0;
  CASE x OF
    1: r := 1
  | 2: r := 2
  | 3:
      i := 0;
      WHILE i < 5 DO
        IF i = 2 THEN r := r + 100 END;
        INC(i)
      END;
      REPEAT r := r + 1 UNTIL r >= 105
  | 4: r := 4 | 5: r := 5 | 6: r := 6
  END;
  Test.AssertInt(105, r, "nested WHILE/IF/REPEAT inside a table arm body");

  x := 6; r := -1;
  CASE x OF
    1: r := 1
  | 2: r := 2
  | 3:
      i := 0;
      WHILE i < 5 DO
        IF i = 2 THEN r := r + 100 END;
        INC(i)
      END;
      REPEAT r := r + 1 UNTIL r >= 105
  | 4: r := 4 | 5: r := 5 | 6: r := 6
  END;
  Test.AssertInt(6, r, "later arm still dispatches correctly after nested-body arm")
END TDenseNestedBody;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TDenseNoElse,                     "TCASETBL/denseNoElse");
  Test.AddTest(TDenseWithElse,                   "TCASETBL/denseWithElse");
  Test.AddTest(TDenseNegative,                   "TCASETBL/denseNegative");
  Test.AddTest(TDenseChar,                       "TCASETBL/denseChar");
  Test.AddTest(TDenseCommaList,                  "TCASETBL/denseCommaList");
  Test.AddTest(TDenseWithRangeFallsBackToChain,  "TCASETBL/denseWithRangeFallsBackToChain");
  Test.AddTest(TDenseNestedBody,                 "TCASETBL/denseNestedBody");
  Test.RunTests
END RunAllTests;

END TCASETBL.
