MODULE IMPPB;
(* Direct deref of an imported pointer-typed global VAR (see self.md 5p). *)
IMPORT IMPPA, Test;

PROCEDURE TDirectDeref*;
VAR v: INTEGER;
BEGIN
  IMPPA.Init;
  v := IMPPA.Head^.value;
  Test.AssertInt(42, v, "Head^.value=42 (read)");
  Test.AssertNil(IMPPA.Head^.next, "Head^.next initially NIL")
END TDirectDeref;

PROCEDURE TWriteThroughDeref*;
VAR v: INTEGER;
BEGIN
  IMPPA.Init;
  IMPPA.Head^.value := 7;
  v := IMPPA.Head^.value;
  Test.AssertInt(7, v, "Head^.value:=7 round-trip")
END TWriteThroughDeref;

PROCEDURE TChainedDeref*;
VAR v: INTEGER; newn: IMPPA.Node;
BEGIN
  IMPPA.Init;
  NEW(newn);
  newn^.value := 99;
  newn^.next  := NIL;
  IMPPA.Head^.next := newn;
  v := IMPPA.Head^.next^.value;
  Test.AssertInt(99, v, "Head^.next^.value=99 (chained)")
END TChainedDeref;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TDirectDeref,       "ImportPtr/directDeref");
  Test.AddTest(TWriteThroughDeref, "ImportPtr/writeThrough");
  Test.AddTest(TChainedDeref,      "ImportPtr/chained");
  Test.RunTests
END RunAllTests;

END IMPPB.
