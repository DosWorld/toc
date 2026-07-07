MODULE DEEP;
(* Deep composite-type access coverage tests.

   Stretches the codegen for designator chains beyond the cases already in
   RECARR.Mod / PTR.Mod:
   - record-of-array-of-record
   - array-of-record-of-array (with mixed element types)
   - pointer-to-array-of-record
   - pointer-to-record holding pointer-to-array fields
   - multi-dim arrays of CHAR / BYTE / REAL / SET / POINTER
   - SET-valued fields inside arrays/records
   - LONGINT fields inside arrays/records
   - REAL fields inside arrays/records
   - 5+ selector designator chains
   - CASE on a record/array field
   - FOR loop assigning to composite-indexed targets
   - open arrays of composite-typed parameters (VAR records & pointer arrays). *)

IMPORT Test;

CONST
  N = 4;
  M = 3;

TYPE
  (* Tier 1 leaf records *)
  Cell    = RECORD x, y: INTEGER; ch: CHAR; flag: BOOLEAN END;
  Vec3    = RECORD x, y, z: REAL END;
  CellArr = ARRAY M OF Cell;

  (* Tier 2: record of arrays + array of records *)
  Block   = RECORD id: INTEGER; cells: CellArr; tag: CHAR END;
  Grid    = ARRAY N OF Block;

  (* Tier 3: array of records of arrays of records — deep enough to stress
     the designator chain length and segment register usage in codegen. *)
  Layer       = RECORD seed: INTEGER; row: ARRAY M OF Cell END;
  LayerStack  = ARRAY N OF Layer;

  (* Pointers to composites *)
  PCell    = POINTER TO Cell;
  PBlock   = POINTER TO Block;
  PGrid    = POINTER TO Grid;
  PCellArr = POINTER TO CellArr;

  (* Record holding pointer-typed array — pointer fields exercise far-pointer
     stores into record memory. *)
  Bag = RECORD count: INTEGER; items: ARRAY N OF PCell END;

  (* SET inside record inside array — bit ops through composite chain. *)
  Flagged = RECORD id: INTEGER; bits: SET END;

  (* LONGINT in record inside array — exercises 32-bit load/store through
     selectors. *)
  Big = RECORD lo, hi: LONGINT; tag: INTEGER END;

(* --- Tier 1: record-of-array (cells inside Block) ----------------- *)

PROCEDURE T1RecordOfArray*;
VAR b: Block; i: INTEGER;
BEGIN
  b.id := 7; b.tag := "X";
  FOR i := 0 TO M - 1 DO
    b.cells[i].x := i * 10;
    b.cells[i].y := i * 10 + 1;
    b.cells[i].ch := CHR(ORD("a") + i);
    b.cells[i].flag := ODD(i)
  END;
  Test.AssertInt(7, b.id, "block.id");
  Test.AssertInt(0,  b.cells[0].x, "b.cells[0].x");
  Test.AssertInt(11, b.cells[1].y, "b.cells[1].y");
  Test.AssertInt(20, b.cells[2].x, "b.cells[2].x");
  Test.AssertInt(ORD("c"), ORD(b.cells[2].ch), "b.cells[2].ch");
  Test.AssertTrue(b.cells[1].flag, "b.cells[1].flag=TRUE");
  Test.AssertFalse(b.cells[2].flag, "b.cells[2].flag=FALSE")
END T1RecordOfArray;

(* --- Tier 1: array-of-record (Grid is array of Block) ------------- *)

PROCEDURE T2ArrayOfRecord*;
VAR g: Grid; i, j: INTEGER;
BEGIN
  FOR i := 0 TO N - 1 DO
    g[i].id := i + 100;
    g[i].tag := CHR(ORD("A") + i);
    FOR j := 0 TO M - 1 DO
      g[i].cells[j].x := i * M + j;
      g[i].cells[j].y := -(i * M + j)
    END
  END;
  Test.AssertInt(100, g[0].id, "g[0].id");
  Test.AssertInt(103, g[3].id, "g[3].id");
  Test.AssertInt(ORD("B"), ORD(g[1].tag), "g[1].tag");
  Test.AssertInt(0,  g[0].cells[0].x, "g[0].cells[0].x");
  Test.AssertInt(7,  g[2].cells[1].x, "g[2].cells[1].x");
  Test.AssertInt(-7, g[2].cells[1].y, "g[2].cells[1].y")
END T2ArrayOfRecord;

(* --- Tier 2: array-of-record-of-array (Grid → Block.cells → Cell) - *)

PROCEDURE T3DeepIndexChain*;
VAR g: Grid; sum: INTEGER; i, j: INTEGER;
BEGIN
  FOR i := 0 TO N - 1 DO
    FOR j := 0 TO M - 1 DO
      g[i].cells[j].x := (i + 1) * (j + 1)
    END
  END;
  sum := 0;
  FOR i := 0 TO N - 1 DO
    FOR j := 0 TO M - 1 DO
      sum := sum + g[i].cells[j].x
    END
  END;
  (* sum of (i+1)*(j+1) for i in 1..4, j in 1..3 = (1+2+3+4)*(1+2+3) = 10*6 = 60 *)
  Test.AssertInt(60, sum, "deep-chain accumulated sum")
END T3DeepIndexChain;

(* --- Tier 3: array-of-record-of-array (LayerStack → Layer → row → Cell) *)

PROCEDURE T4TripleNesting*;
VAR ls: LayerStack; i, j: INTEGER;
BEGIN
  FOR i := 0 TO N - 1 DO
    ls[i].seed := i * 100;
    FOR j := 0 TO M - 1 DO
      ls[i].row[j].x := i;
      ls[i].row[j].y := j;
      ls[i].row[j].ch := CHR(ORD("0") + (i + j) MOD 10)
    END
  END;
  Test.AssertInt(0,   ls[0].seed,           "ls[0].seed");
  Test.AssertInt(300, ls[3].seed,           "ls[3].seed");
  Test.AssertInt(2,   ls[2].row[0].x,       "ls[2].row[0].x");
  Test.AssertInt(2,   ls[1].row[2].y,       "ls[1].row[2].y");
  Test.AssertInt(ORD("4"), ORD(ls[2].row[2].ch), "ls[2].row[2].ch='4'")
END T4TripleNesting;

(* --- Pointer to array of records ---------------------------------- *)

PROCEDURE T5PointerArrayOfRecord*;
VAR pg: PGrid; i, j: INTEGER;
BEGIN
  NEW(pg);
  FOR i := 0 TO N - 1 DO
    pg^[i].id := i + 1;
    FOR j := 0 TO M - 1 DO
      pg^[i].cells[j].x := i * 10 + j
    END
  END;
  Test.AssertInt(1, pg^[0].id, "pg^[0].id");
  Test.AssertInt(4, pg^[3].id, "pg^[3].id");
  Test.AssertInt(21, pg^[2].cells[1].x, "pg^[2].cells[1].x");
  Test.AssertInt(32, pg^[3].cells[2].x, "pg^[3].cells[2].x");
  DISPOSE(pg)
END T5PointerArrayOfRecord;

(* --- Record with array of pointers -------------------------------- *)

PROCEDURE T6BagOfPointers*;
VAR bag: Bag; i: INTEGER; p: PCell;
BEGIN
  bag.count := 0;
  FOR i := 0 TO N - 1 DO
    NEW(p);
    p^.x := i * 5;
    p^.y := -i;
    p^.ch := CHR(ORD("a") + i);
    bag.items[i] := p;
    bag.count := bag.count + 1
  END;
  Test.AssertInt(N, bag.count, "bag.count");
  Test.AssertInt(0,  bag.items[0]^.x, "bag.items[0]^.x");
  Test.AssertInt(15, bag.items[3]^.x, "bag.items[3]^.x");
  Test.AssertInt(-2, bag.items[2]^.y, "bag.items[2]^.y");
  Test.AssertInt(ORD("c"), ORD(bag.items[2]^.ch), "bag.items[2]^.ch='c'");
  (* dispose all *)
  FOR i := 0 TO N - 1 DO
    p := bag.items[i];
    DISPOSE(p);
    bag.items[i] := NIL
  END;
  Test.AssertNil(bag.items[0], "bag.items[0]=NIL after dispose")
END T6BagOfPointers;

(* --- 5-level designator chain ------------------------------------- *)
(* pg^.[i] . cells [j] . ch  → 5 selectors. *)

PROCEDURE T7FiveLevelChain*;
VAR pg: PGrid;
BEGIN
  NEW(pg);
  pg^[0].cells[0].ch := "Q";
  pg^[1].cells[2].ch := "Z";
  pg^[3].cells[1].ch := "M";
  Test.AssertInt(ORD("Q"), ORD(pg^[0].cells[0].ch), "5-chain 'Q'");
  Test.AssertInt(ORD("Z"), ORD(pg^[1].cells[2].ch), "5-chain 'Z'");
  Test.AssertInt(ORD("M"), ORD(pg^[3].cells[1].ch), "5-chain 'M'");
  DISPOSE(pg)
END T7FiveLevelChain;

(* --- Multi-dim arrays of various scalar types --------------------- *)

PROCEDURE T8Mat2DByte*;
VAR mb: ARRAY 4, 4 OF BYTE; i, j: INTEGER; s: INTEGER;
BEGIN
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 3 DO
      mb[i, j] := BYTE((i * 4 + j) MOD 256)
    END
  END;
  s := 0;
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 3 DO
      s := s + INTEGER(mb[i, j])
    END
  END;
  (* sum 0+1+...+15 = 120 *)
  Test.AssertInt(120, s, "byte 2D sum")
END T8Mat2DByte;

PROCEDURE T9Mat2DChar*;
VAR mc: ARRAY 3, 4 OF CHAR; i, j: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 3 DO
      mc[i, j] := CHR(ORD("a") + i * 4 + j)
    END
  END;
  Test.AssertInt(ORD("a"), ORD(mc[0, 0]), "mc[0,0]='a'");
  Test.AssertInt(ORD("e"), ORD(mc[1, 0]), "mc[1,0]='e'");
  Test.AssertInt(ORD("l"), ORD(mc[2, 3]), "mc[2,3]='l'")
END T9Mat2DChar;

PROCEDURE T10Mat2DSet*;
VAR ms: ARRAY 3, 3 OF SET; i, j: INTEGER; combined: SET;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      ms[i, j] := {i, j + 3}
    END
  END;
  Test.AssertTrue(0 IN ms[0, 0], "0 in ms[0,0]");
  Test.AssertTrue(3 IN ms[0, 0], "3 in ms[0,0]");
  Test.AssertTrue(5 IN ms[1, 2], "5 in ms[1,2]");
  Test.AssertFalse(0 IN ms[2, 2], "0 not in ms[2,2]");
  (* union of all *)
  combined := {};
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      combined := combined + ms[i, j]
    END
  END;
  Test.AssertTrue(0 IN combined, "0 in union");
  Test.AssertTrue(2 IN combined, "2 in union");
  Test.AssertTrue(5 IN combined, "5 in union")
END T10Mat2DSet;

(* --- SET-valued fields inside record-of-array --------------------- *)

PROCEDURE T11FlagsInArrayOfRecord*;
VAR farr: ARRAY 4 OF Flagged; i: INTEGER; b: BOOLEAN;
BEGIN
  FOR i := 0 TO 3 DO
    farr[i].id := i + 1;
    farr[i].bits := {i, i + 4, i + 8}
  END;
  Test.AssertInt(1, farr[0].id, "farr[0].id");
  Test.AssertTrue(0 IN farr[0].bits, "bit 0 in farr[0].bits");
  Test.AssertTrue(8 IN farr[0].bits, "bit 8 in farr[0].bits");
  Test.AssertTrue(11 IN farr[3].bits, "bit 11 in farr[3].bits");
  b := 3 IN farr[3].bits;
  Test.AssertTrue(b, "bit 3 in farr[3].bits");
  (* SET intersection through array selector *)
  farr[0].bits := farr[0].bits * {0, 1, 2};
  Test.AssertTrue(0 IN farr[0].bits, "post-intersect bit 0");
  Test.AssertFalse(4 IN farr[0].bits, "post-intersect not bit 4")
END T11FlagsInArrayOfRecord;

(* --- LONGINT in record inside array ------------------------------- *)

PROCEDURE T12LongintInArrayOfRecord*;
VAR ba: ARRAY 3 OF Big; i: INTEGER; sum: LONGINT;
BEGIN
  ba[0].lo := LONGINT(100000); ba[0].hi := LONGINT(200000); ba[0].tag := 0;
  ba[1].lo := LONGINT(-50000); ba[1].hi := LONGINT(150000); ba[1].tag := 1;
  ba[2].lo := LONGINT(7);      ba[2].hi := LONGINT(-3);     ba[2].tag := 2;
  Test.AssertLong(LONGINT(100000), ba[0].lo, "ba[0].lo");
  Test.AssertLong(LONGINT(150000), ba[1].hi, "ba[1].hi");
  Test.AssertLong(LONGINT(-3),     ba[2].hi, "ba[2].hi");
  sum := LONGINT(0);
  FOR i := 0 TO 2 DO
    sum := sum + ba[i].lo + ba[i].hi
  END;
  (* 100000+200000 + -50000+150000 + 7+-3 = 400004 *)
  Test.AssertLong(LONGINT(400004), sum, "sum lo+hi over array")
END T12LongintInArrayOfRecord;

(* --- REAL field in record-of-array -------------------------------- *)

PROCEDURE T13RealInArrayOfRecord*;
VAR va: ARRAY 3 OF Vec3; i: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    va[i].x := FLOAT(i);
    va[i].y := FLOAT(i + 1);
    va[i].z := FLOAT(i * 2)
  END;
  Test.AssertReal(0.0, va[0].x, "va[0].x");
  Test.AssertReal(2.0, va[1].y, "va[1].y");
  Test.AssertReal(4.0, va[2].z, "va[2].z")
END T13RealInArrayOfRecord;

(* --- CASE on a record field --------------------------------------- *)

PROCEDURE T14CaseOnRecordField*;
VAR cells: CellArr; i: INTEGER; tag: INTEGER;
BEGIN
  cells[0].ch := "A";
  cells[1].ch := "B";
  cells[2].ch := "Z";
  FOR i := 0 TO M - 1 DO
    CASE cells[i].ch OF
      "A": tag := 1
    | "B": tag := 2
    | "C".."Y": tag := 3
    | "Z": tag := 9
    ELSE tag := 0
    END;
    IF i = 0 THEN Test.AssertInt(1, tag, "case ch='A'")
    ELSIF i = 1 THEN Test.AssertInt(2, tag, "case ch='B'")
    ELSE Test.AssertInt(9, tag, "case ch='Z'")
    END
  END
END T14CaseOnRecordField;

(* --- FOR loop writing into a composite-indexed target ------------- *)

PROCEDURE T15ForWritesIntoComposite*;
VAR g: Grid; i, j: INTEGER;
BEGIN
  FOR i := 0 TO N - 1 DO
    FOR j := 0 TO M - 1 DO
      g[i].cells[j].x := i * M + j
    END
  END;
  (* spot-check *)
  Test.AssertInt(0,  g[0].cells[0].x, "g[0][0].x = 0");
  Test.AssertInt(5,  g[1].cells[2].x, "g[1][2].x = 5");
  Test.AssertInt(11, g[3].cells[2].x, "g[3][2].x = 11")
END T15ForWritesIntoComposite;

(* --- Open array of records as VAR parameter ----------------------- *)

PROCEDURE SumIds(VAR a: ARRAY OF Cell): INTEGER;
VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO
    s := s + a[i].x
  END;
  RETURN s
END SumIds;

PROCEDURE T16OpenArrayOfRecord*;
VAR cells: CellArr; i: INTEGER;
BEGIN
  FOR i := 0 TO M - 1 DO cells[i].x := i + 1 END;
  Test.AssertInt(6, SumIds(cells), "sum-ids open-array")
END T16OpenArrayOfRecord;

(* --- VAR record param: caller modifies through callee ------------- *)

PROCEDURE WriteBlock(VAR b: Block; baseId: INTEGER; baseX: INTEGER);
VAR j: INTEGER;
BEGIN
  b.id := baseId;
  FOR j := 0 TO M - 1 DO
    b.cells[j].x := baseX + j;
    b.cells[j].y := baseX - j
  END
END WriteBlock;

PROCEDURE T17VarRecordParam*;
VAR g: Grid; i: INTEGER;
BEGIN
  FOR i := 0 TO N - 1 DO
    WriteBlock(g[i], i * 100, i * 1000)
  END;
  Test.AssertInt(0,    g[0].id, "g[0].id from WriteBlock");
  Test.AssertInt(300,  g[3].id, "g[3].id");
  Test.AssertInt(1000, g[1].cells[0].x, "g[1].cells[0].x");
  Test.AssertInt(2002, g[2].cells[2].x, "g[2].cells[2].x");
  Test.AssertInt(998,  g[1].cells[2].y, "g[1].cells[2].y = 1000-2")
END T17VarRecordParam;

(* --- Pointer dereference chain inside arithmetic ------------------ *)

PROCEDURE T18PtrChainInArith*;
VAR pg: PGrid; n: INTEGER;
BEGIN
  NEW(pg);
  pg^[0].cells[0].x := 4;
  pg^[1].cells[1].x := 6;
  pg^[2].cells[2].x := -2;
  n := pg^[0].cells[0].x + pg^[1].cells[1].x * 2 - pg^[2].cells[2].x;
  Test.AssertInt(18, n, "4 + 6*2 - (-2) = 18");
  DISPOSE(pg)
END T18PtrChainInArith;

(* --- Heap allocation of inner CellArr via PCellArr ---------------- *)

PROCEDURE T19PointerToArray*;
VAR p: PCellArr; i: INTEGER;
BEGIN
  NEW(p);
  FOR i := 0 TO M - 1 DO
    p^[i].x := i * 7;
    p^[i].ch := CHR(ORD("a") + i)
  END;
  Test.AssertInt(0,  p^[0].x, "p^[0].x");
  Test.AssertInt(14, p^[2].x, "p^[2].x");
  Test.AssertInt(ORD("b"), ORD(p^[1].ch), "p^[1].ch='b'");
  DISPOSE(p)
END T19PointerToArray;

(* --- Mixed scalar + composite chain in single expression ---------- *)

PROCEDURE T20MixedChainExpr*;
VAR g: Grid; ok: BOOLEAN;
BEGIN
  g[0].id := 10;
  g[0].cells[0].x := 7;
  g[0].cells[0].flag := TRUE;
  ok := (g[0].id + g[0].cells[0].x = 17) & g[0].cells[0].flag;
  Test.AssertTrue(ok, "composite-chain boolean expr")
END T20MixedChainExpr;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(T1RecordOfArray,        "Dp/recOfArr");
  Test.AddTest(T2ArrayOfRecord,        "Dp/arrOfRec");
  Test.AddTest(T3DeepIndexChain,       "Dp/deepChain");
  Test.AddTest(T4TripleNesting,        "Dp/tripleNest");
  Test.AddTest(T5PointerArrayOfRecord, "Dp/ptrArrRec");
  Test.AddTest(T6BagOfPointers,        "Dp/bagOfPtr");
  Test.AddTest(T7FiveLevelChain,       "Dp/5levelChain");
  Test.AddTest(T8Mat2DByte,            "Dp/mat2dByte");
  Test.AddTest(T9Mat2DChar,            "Dp/mat2dChar");
  Test.AddTest(T10Mat2DSet,            "Dp/mat2dSet");
  Test.AddTest(T11FlagsInArrayOfRecord,"Dp/flagsArrRec");
  Test.AddTest(T12LongintInArrayOfRecord,"Dp/longInArrRec");
  Test.AddTest(T13RealInArrayOfRecord, "Dp/realInArrRec");
  Test.AddTest(T14CaseOnRecordField,   "Dp/caseOnField");
  Test.AddTest(T15ForWritesIntoComposite,"Dp/forWrite");
  Test.AddTest(T16OpenArrayOfRecord,   "Dp/openArrRec");
  Test.AddTest(T17VarRecordParam,      "Dp/varRecParam");
  Test.AddTest(T18PtrChainInArith,     "Dp/ptrChainArith");
  Test.AddTest(T19PointerToArray,      "Dp/ptrToArray");
  Test.AddTest(T20MixedChainExpr,      "Dp/mixedChainExpr");
  Test.RunTests
END RunAllTests;

END DEEP.
