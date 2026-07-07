MODULE Scopa;
(* Companion library for SCOPB.Mod scope-coverage tests.
   Exports composite types, global instances, and procedures that read/write
   them via local/param/global access patterns so that SCOPB can drive each
   pattern from across the import boundary. *)

(* Exported composite types *)
TYPE
  Point*    = RECORD x*, y*: INTEGER END;
  Rect*     = RECORD tl*, br*: Point END;       (* nested record *)
  IntArr5*  = ARRAY 5 OF INTEGER;
  RecArr*   = ARRAY 3 OF Point;                 (* array of record *)
  Grid*     = ARRAY 3, 3 OF INTEGER;            (* 2D matrix *)
  PPoint*   = POINTER TO Point;
  PRect*    = POINTER TO Rect;
  PRecArr*  = POINTER TO RecArr;

VAR
  (* Exported globals of every composite shape — clients write/read these. *)
  gPoint*  : Point;
  gRect*   : Rect;
  gArr*    : IntArr5;
  gRecArr* : RecArr;
  gGrid*   : Grid;
  gPP*     : PPoint;
  gPR*     : PRect;

(* Set a Point via VAR param — caller passes a Point lvalue. *)
PROCEDURE SetPoint* (VAR p: Point; x, y: INTEGER);
BEGIN
  p.x := x; p.y := y
END SetPoint;

(* Sum a Point via VAR param — read-only access through the reference. *)
PROCEDURE SumPoint* (VAR p: Point): INTEGER;
BEGIN
  RETURN p.x + p.y
END SumPoint;

(* Set Rect through nested record VAR param. *)
PROCEDURE SetRect* (VAR r: Rect; x1, y1, x2, y2: INTEGER);
BEGIN
  r.tl.x := x1; r.tl.y := y1;
  r.br.x := x2; r.br.y := y2
END SetRect;

(* Open array of INTEGER as VAR param. *)
PROCEDURE FillInts* (VAR a: ARRAY OF INTEGER; base: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO LEN(a) - 1 DO a[i] := base + i END
END FillInts;

PROCEDURE SumInts* (VAR a: ARRAY OF INTEGER): INTEGER;
VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO s := s + a[i] END;
  RETURN s
END SumInts;

(* Open array of records as VAR param. *)
PROCEDURE FillPoints* (VAR a: ARRAY OF Point; baseX, baseY: INTEGER);
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO LEN(a) - 1 DO
    a[i].x := baseX + i; a[i].y := baseY - i
  END
END FillPoints;

(* Initialise the module's own globals to known values.  Clients call this
   to put gPoint/gRect/... into a known state. *)
PROCEDURE InitGlobals*;
VAR i, j: INTEGER;
BEGIN
  gPoint.x := 11; gPoint.y := 22;
  gRect.tl.x := 1; gRect.tl.y := 2;
  gRect.br.x := 3; gRect.br.y := 4;
  FOR i := 0 TO 4 DO gArr[i] := i * 10 END;
  FOR i := 0 TO 2 DO
    gRecArr[i].x := i + 100;
    gRecArr[i].y := i + 200
  END;
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO gGrid[i, j] := i * 10 + j END
  END;
  NEW(gPP);
  gPP^.x := 7; gPP^.y := 8;
  NEW(gPR);
  gPR^.tl.x := 100; gPR^.tl.y := 200;
  gPR^.br.x := 300; gPR^.br.y := 400
END InitGlobals;

END Scopa.
