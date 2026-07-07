MODULE SCOPB;
(* Composite-type access in every scope: local, parameter, module-global,
   imported global.  Exercises read AND write through each scope.

   Symbol scopes covered:
     L  — local var (declared inside the test proc)
     P  — VAR/value parameter passed in by caller
     G  — module-level global (declared in this module)
     I  — imported global (Scopa.gPoint, Scopa.gRect, ...)

   Imported ARRAY type aliases (Scopa.IntArr5, Scopa.RecArr, Scopa.Grid) are
   used directly in VAR/parameter declarations to exercise bug #35's fix. *)

IMPORT Scopa, Test;

VAR
  (* Module-level globals of every composite shape (scope G). *)
  gPoint  : Scopa.Point;
  gRect   : Scopa.Rect;
  gArr    : Scopa.IntArr5;
  gRecArr : Scopa.RecArr;
  gGrid   : Scopa.Grid;
  gPP     : Scopa.PPoint;
  gPR     : Scopa.PRect;

(* ===== Scope L: local var ============================================ *)

PROCEDURE TLocalPoint*;
VAR p: Scopa.Point;
BEGIN
  p.x := 5; p.y := 7;
  Test.AssertInt(5, p.x, "L: local Point.x write+read");
  Test.AssertInt(7, p.y, "L: local Point.y");
  p.x := p.x + p.y;
  Test.AssertInt(12, p.x, "L: local Point in-place update")
END TLocalPoint;

PROCEDURE TLocalRectNested*;
VAR r: Scopa.Rect;
BEGIN
  r.tl.x := 1; r.tl.y := 2;
  r.br.x := 30; r.br.y := 40;
  Test.AssertInt(1,  r.tl.x, "L: r.tl.x");
  Test.AssertInt(40, r.br.y, "L: r.br.y");
  Test.AssertInt(29, (r.br.x - r.tl.x), "L: r.br.x - r.tl.x")
END TLocalRectNested;

PROCEDURE TLocalArr*;
VAR a: Scopa.IntArr5; i, s: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO a[i] := i * 3 END;
  s := 0;
  FOR i := 0 TO 4 DO s := s + a[i] END;
  Test.AssertInt(30, s, "L: sum local IntArr5 = 30")
END TLocalArr;

PROCEDURE TLocalRecArr*;
VAR ra: Scopa.RecArr; i: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO ra[i].x := i + 10; ra[i].y := i - 5 END;
  Test.AssertInt(10, ra[0].x, "L: ra[0].x");
  Test.AssertInt(-3, ra[2].y, "L: ra[2].y");
  Test.AssertInt(11, ra[1].x, "L: ra[1].x")
END TLocalRecArr;

PROCEDURE TLocalGrid*;
VAR g: Scopa.Grid; i, j, s: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO g[i, j] := i + j END
  END;
  s := 0;
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO s := s + g[i, j] END
  END;
  (* sum_{i,j=0..2} (i+j) = 18 *)
  Test.AssertInt(18, s, "L: sum local Grid = 18")
END TLocalGrid;

PROCEDURE TLocalPtrRec*;
VAR p: Scopa.PPoint;
BEGIN
  NEW(p);
  p^.x := 99; p^.y := -1;
  Test.AssertInt(99, p^.x, "L: local PPoint^.x");
  Test.AssertInt(-1, p^.y, "L: local PPoint^.y");
  p^.x := p^.x * 2;
  Test.AssertInt(198, p^.x, "L: local PPoint in-place doubling");
  DISPOSE(p)
END TLocalPtrRec;

(* ===== Scope P: VAR / value parameters =============================== *)

PROCEDURE AddTo (VAR p: Scopa.Point; dx, dy: INTEGER);
BEGIN p.x := p.x + dx; p.y := p.y + dy END AddTo;

PROCEDURE ReadX (p: Scopa.Point): INTEGER;
BEGIN RETURN p.x END ReadX;

PROCEDURE TParamPoint*;
VAR p: Scopa.Point;
BEGIN
  p.x := 10; p.y := 20;
  AddTo(p, 5, -3);          (* VAR param write *)
  Test.AssertInt(15, p.x, "P: VAR param write to .x");
  Test.AssertInt(17, p.y, "P: VAR param write to .y");
  Test.AssertInt(15, ReadX(p), "P: value-copy param read (.x)")
END TParamPoint;

PROCEDURE FillOpenArr (VAR a: ARRAY OF INTEGER; base: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO LEN(a) - 1 DO a[i] := base + i END
END FillOpenArr;

PROCEDURE SumOpenArr (VAR a: ARRAY OF INTEGER): INTEGER;
VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO s := s + a[i] END;
  RETURN s
END SumOpenArr;

PROCEDURE TParamOpenArr*;
VAR a: Scopa.IntArr5;
BEGIN
  FillOpenArr(a, 100);
  Test.AssertInt(100, a[0], "P: open-array param a[0]");
  Test.AssertInt(104, a[4], "P: open-array param a[4]");
  Test.AssertInt(510, SumOpenArr(a), "P: open-array sum = 100+101+102+103+104")
END TParamOpenArr;

(* ===== Scope G: module-level globals ================================ *)

PROCEDURE TGlobalPoint*;
BEGIN
  gPoint.x := 31; gPoint.y := 41;
  Test.AssertInt(31, gPoint.x, "G: gPoint.x");
  Test.AssertInt(41, gPoint.y, "G: gPoint.y");
  AddTo(gPoint, 9, -1);
  Test.AssertInt(40, gPoint.x, "G: gPoint.x after AddTo");
  Test.AssertInt(40, gPoint.y, "G: gPoint.y after AddTo")
END TGlobalPoint;

PROCEDURE TGlobalRect*;
BEGIN
  gRect.tl.x := 0; gRect.tl.y := 0;
  gRect.br.x := 100; gRect.br.y := 200;
  Test.AssertInt(0,   gRect.tl.x, "G: gRect.tl.x");
  Test.AssertInt(100, gRect.br.x, "G: gRect.br.x");
  Test.AssertInt(200, gRect.br.y, "G: gRect.br.y")
END TGlobalRect;

PROCEDURE TGlobalArr*;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO gArr[i] := i + 50 END;
  Test.AssertInt(50, gArr[0], "G: gArr[0]");
  Test.AssertInt(54, gArr[4], "G: gArr[4]");
  Test.AssertInt(260, SumOpenArr(gArr), "G: sum(gArr) = 260")
END TGlobalArr;

PROCEDURE TGlobalRecArr*;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    gRecArr[i].x := i * 10;
    gRecArr[i].y := i * 100
  END;
  Test.AssertInt(0,   gRecArr[0].x, "G: gRecArr[0].x");
  Test.AssertInt(20,  gRecArr[2].x, "G: gRecArr[2].x");
  Test.AssertInt(200, gRecArr[2].y, "G: gRecArr[2].y");
  (* Update through VAR param into a global record element *)
  AddTo(gRecArr[1], 5, 5);
  Test.AssertInt(15,  gRecArr[1].x, "G: gRecArr[1].x after AddTo(+5)");
  Test.AssertInt(105, gRecArr[1].y, "G: gRecArr[1].y after AddTo(+5)")
END TGlobalRecArr;

PROCEDURE TGlobalGrid*;
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO gGrid[i, j] := i * 100 + j END
  END;
  Test.AssertInt(0,   gGrid[0, 0], "G: gGrid[0,0]");
  Test.AssertInt(202, gGrid[2, 2], "G: gGrid[2,2]");
  Test.AssertInt(101, gGrid[1, 1], "G: gGrid[1,1]")
END TGlobalGrid;

PROCEDURE TGlobalPtr*;
BEGIN
  NEW(gPP);
  gPP^.x := 13; gPP^.y := 31;
  Test.AssertInt(13, gPP^.x, "G: gPP^.x");
  Test.AssertInt(31, gPP^.y, "G: gPP^.y");
  AddTo(gPP^, 10, -20);
  Test.AssertInt(23, gPP^.x, "G: gPP^.x after AddTo");
  Test.AssertInt(11, gPP^.y, "G: gPP^.y after AddTo");
  DISPOSE(gPP); gPP := NIL
END TGlobalPtr;

(* ===== Scope I: imported globals ==================================== *)

PROCEDURE TImportedPoint*;
BEGIN
  Scopa.InitGlobals;
  Test.AssertInt(11, Scopa.gPoint.x, "I: imported gPoint.x default");
  Test.AssertInt(22, Scopa.gPoint.y, "I: imported gPoint.y default");
  Scopa.gPoint.x := 500;
  Scopa.gPoint.y := -77;
  Test.AssertInt(500, Scopa.gPoint.x, "I: write to imported gPoint.x");
  Test.AssertInt(-77, Scopa.gPoint.y, "I: write to imported gPoint.y")
END TImportedPoint;

PROCEDURE TImportedRectNested*;
BEGIN
  Scopa.InitGlobals;
  Test.AssertInt(1, Scopa.gRect.tl.x, "I: gRect.tl.x default");
  Test.AssertInt(4, Scopa.gRect.br.y, "I: gRect.br.y default");
  Scopa.gRect.tl.x := -1;
  Scopa.gRect.br.y := 999;
  Test.AssertInt(-1,  Scopa.gRect.tl.x, "I: gRect.tl.x written");
  Test.AssertInt(999, Scopa.gRect.br.y, "I: gRect.br.y written")
END TImportedRectNested;

PROCEDURE TImportedPtr*;
BEGIN
  Scopa.InitGlobals;
  Test.AssertInt(7, Scopa.gPP^.x, "I: gPP^.x default");
  Test.AssertInt(8, Scopa.gPP^.y, "I: gPP^.y default");
  Scopa.gPP^.x := 70;
  Scopa.gPP^.y := 80;
  Test.AssertInt(70, Scopa.gPP^.x, "I: gPP^.x written");
  Test.AssertInt(80, Scopa.gPP^.y, "I: gPP^.y written")
END TImportedPtr;

PROCEDURE TImportedPtrRect*;
BEGIN
  Scopa.InitGlobals;
  Test.AssertInt(100, Scopa.gPR^.tl.x, "I: gPR^.tl.x");
  Test.AssertInt(400, Scopa.gPR^.br.y, "I: gPR^.br.y");
  Scopa.gPR^.tl.x := 1; Scopa.gPR^.tl.y := 2;
  Scopa.gPR^.br.x := 3; Scopa.gPR^.br.y := 4;
  Test.AssertInt(1, Scopa.gPR^.tl.x, "I: gPR^.tl.x written");
  Test.AssertInt(4, Scopa.gPR^.br.y, "I: gPR^.br.y written")
END TImportedPtrRect;

(* ===== Cross-scope: pass globals to imported procs =================== *)

PROCEDURE TImportedProcOnGlobal*;
BEGIN
  gPoint.x := 100; gPoint.y := 200;
  Scopa.SetPoint(gPoint, 5, 7);    (* imported proc writes our global *)
  Test.AssertInt(5, gPoint.x, "X: Scopa.SetPoint set local-module global .x");
  Test.AssertInt(7, gPoint.y, "X: Scopa.SetPoint set local-module global .y");
  Test.AssertInt(12, Scopa.SumPoint(gPoint), "X: Scopa.SumPoint(gPoint)")
END TImportedProcOnGlobal;

PROCEDURE TImportedProcOnLocal*;
VAR p: Scopa.Point;
BEGIN
  Scopa.SetPoint(p, 33, 44);
  Test.AssertInt(33, p.x, "X: Scopa.SetPoint set local .x");
  Test.AssertInt(44, p.y, "X: Scopa.SetPoint set local .y")
END TImportedProcOnLocal;

PROCEDURE TImportedPtrChain*;
VAR p: Scopa.PRect;
BEGIN
  NEW(p);
  p^.tl.x := -1; p^.tl.y := -2;
  p^.br.x := 99; p^.br.y := 88;
  Test.AssertInt(-1, p^.tl.x, "X: local PRect tl.x");
  Test.AssertInt(88, p^.br.y, "X: local PRect br.y");
  Scopa.SetRect(p^, 11, 22, 33, 44);
  Test.AssertInt(11, p^.tl.x, "X: SetRect through deref tl.x");
  Test.AssertInt(33, p^.br.x, "X: SetRect through deref br.x");
  DISPOSE(p)
END TImportedPtrChain;

(* ===== Bug #35 regression: imported ARRAY type aliases =============== *)
(* Direct use of imported ARRAY aliases in VAR/PARAM positions.  Prior to
   the .def writer/reader extension that serialises element type, declaring
   a variable of Scopa.IntArr5/RecArr/Grid was rejected because the alias
   was deserialised as opaque INTEGER. *)

PROCEDURE TBug35IntArr5Local*;
VAR a: Scopa.IntArr5; i, s: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO a[i] := i * 7 END;
  s := 0;
  FOR i := 0 TO 4 DO s := s + a[i] END;
  Test.AssertInt(70, s, "bug35: local Scopa.IntArr5 sum = 70");
  Test.AssertInt(28, a[4], "bug35: a[4] = 28")
END TBug35IntArr5Local;

PROCEDURE TBug35RecArrLocal*;
VAR ra: Scopa.RecArr; i: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO ra[i].x := 50 + i; ra[i].y := 60 - i END;
  Test.AssertInt(50, ra[0].x, "bug35: local Scopa.RecArr[0].x");
  Test.AssertInt(52, ra[2].x, "bug35: local Scopa.RecArr[2].x");
  Test.AssertInt(58, ra[2].y, "bug35: local Scopa.RecArr[2].y")
END TBug35RecArrLocal;

PROCEDURE TBug35GridLocal*;
VAR g: Scopa.Grid; i, j, s: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO g[i, j] := i * 10 + j END
  END;
  s := 0;
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO s := s + g[i, j] END
  END;
  Test.AssertInt(99, s, "bug35: local Scopa.Grid sum = 99");
  Test.AssertInt(22, g[2, 2], "bug35: g[2,2] = 22")
END TBug35GridLocal;

PROCEDURE TBug35IntArr5Param*;
VAR a: Scopa.IntArr5;
BEGIN
  Scopa.FillInts(a, 200);
  Test.AssertInt(200, a[0], "bug35: param IntArr5 a[0]");
  Test.AssertInt(204, a[4], "bug35: param IntArr5 a[4]");
  Test.AssertInt(1010, Scopa.SumInts(a), "bug35: SumInts = 1010")
END TBug35IntArr5Param;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TLocalPoint,           "Sc/L-point");
  Test.AddTest(TLocalRectNested,      "Sc/L-rectNested");
  Test.AddTest(TLocalArr,             "Sc/L-arr");
  Test.AddTest(TLocalRecArr,          "Sc/L-recArr");
  Test.AddTest(TLocalGrid,            "Sc/L-grid");
  Test.AddTest(TLocalPtrRec,          "Sc/L-ptrRec");
  Test.AddTest(TParamPoint,           "Sc/P-point");
  Test.AddTest(TParamOpenArr,         "Sc/P-openArr");
  Test.AddTest(TGlobalPoint,          "Sc/G-point");
  Test.AddTest(TGlobalRect,           "Sc/G-rect");
  Test.AddTest(TGlobalArr,            "Sc/G-arr");
  Test.AddTest(TGlobalRecArr,         "Sc/G-recArr");
  Test.AddTest(TGlobalGrid,           "Sc/G-grid");
  Test.AddTest(TGlobalPtr,            "Sc/G-ptr");
  Test.AddTest(TImportedPoint,        "Sc/I-point");
  Test.AddTest(TImportedRectNested,   "Sc/I-rectNested");
  Test.AddTest(TImportedPtr,          "Sc/I-ptr");
  Test.AddTest(TImportedPtrRect,      "Sc/I-ptrRect");
  Test.AddTest(TImportedProcOnGlobal, "Sc/X-procGlobal");
  Test.AddTest(TImportedProcOnLocal,  "Sc/X-procLocal");
  Test.AddTest(TImportedPtrChain,     "Sc/X-ptrChain");
  Test.AddTest(TBug35IntArr5Local,    "Sc/B35-intArr5L");
  Test.AddTest(TBug35RecArrLocal,     "Sc/B35-recArrL");
  Test.AddTest(TBug35GridLocal,       "Sc/B35-gridL");
  Test.AddTest(TBug35IntArr5Param,    "Sc/B35-intArr5P");
  Test.RunTests
END RunAllTests;

END SCOPB.
