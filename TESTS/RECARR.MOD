MODULE RECARR;
IMPORT Test;

TYPE
  RcPoint = RECORD x, y: INTEGER END;
  RcRect  = RECORD topLeft, bottomRight: RcPoint END;
  RcMixed = RECORD a: BYTE; b: INTEGER; c: BYTE; d: INTEGER END;
  RcTagged = RECORD id: INTEGER; tag: CHAR; val: INTEGER END;
  RcNamed = RECORD id: INTEGER; tag: CHAR; name: ARRAY 8 OF CHAR END;
  RcAnimal = RECORD legs, sound: INTEGER END;
  RcDog    = RECORD (RcAnimal) tricks: INTEGER END;
  RcCat    = RECORD (RcAnimal) indoor: INTEGER END;
  RcVehicle      = RECORD wheels, speed: INTEGER END;
  RcMotorVehicle = RECORD (RcVehicle) hp: INTEGER END;
  RcCar          = RECORD (RcMotorVehicle) doors: INTEGER END;
  RcPVehicle      = POINTER TO RcVehicle;
  RcPMotorVehicle = POINTER TO RcMotorVehicle;
  RcPCar          = POINTER TO RcCar;
  RcPNode = POINTER TO RcPNodeDesc;
  RcPNodeDesc = RECORD val: INTEGER; next: RcPNode END;
  RcPDog  = POINTER TO RcDog;
  TtAnimal   = RECORD legs: INTEGER END;
  TtDog      = RECORD (TtAnimal) tricks: INTEGER END;
  TtCat      = RECORD (TtAnimal) indoor: BOOLEAN END;
  TtPAnimal  = POINTER TO TtAnimal;
  TtPDog     = POINTER TO TtDog;
  TtPCat     = POINTER TO TtCat;
  IsAnimal = RECORD END;
  IsDog    = RECORD (IsAnimal) END;
  NfHolder = POINTER TO NfHolderDesc;
  NfHolderDesc = RECORD
    a, b: SYSTEM.ADDRESS;
  Nfsz:   WORD
  END;

VAR
  RcgPoint: RcPoint;
  RcgNamed: RcNamed;
  Mdgmat: ARRAY 5, 5 OF INTEGER;
  Ispd: POINTER TO IsDog;
  Ispa: POINTER TO IsAnimal;

PROCEDURE RcTBasicFields*;
VAR p: RcPoint;
BEGIN
  p.x := 10; p.y := 20;
  Test.AssertInt(10, p.x, "p.x");
  Test.AssertInt(20, p.y, "p.y");
  p.x := p.x + p.y;
  Test.AssertInt(30, p.x, "p.x+p.y")
END RcTBasicFields;

PROCEDURE RcTGlobalRecord*;
BEGIN
  RcgPoint.x := 100; RcgPoint.y := 200;
  Test.AssertInt(100, RcgPoint.x, "RcgPoint.x");
  Test.AssertInt(200, RcgPoint.y, "RcgPoint.y");
  RcgPoint.y := RcgPoint.x - RcgPoint.y;
  Test.AssertInt(-100, RcgPoint.y, "RcgPoint.x-RcgPoint.y")
END RcTGlobalRecord;

PROCEDURE RcSetPoint(VAR p: RcPoint; ax, ay: INTEGER);
BEGIN p.x := ax; p.y := ay END RcSetPoint;

PROCEDURE RcSumPoint(VAR p: RcPoint): INTEGER;
BEGIN RETURN p.x + p.y END RcSumPoint;

PROCEDURE RcTVarParam*;
VAR p: RcPoint;
BEGIN
  RcSetPoint(p, 3, 4);
  Test.AssertInt(3, p.x, "x after RcSetPoint");
  Test.AssertInt(4, p.y, "y after RcSetPoint");
  Test.AssertInt(7, RcSumPoint(p), "RcSumPoint");
  RcSetPoint(p, -5, 5);
  Test.AssertInt(0, RcSumPoint(p), "RcSumPoint zero")
END RcTVarParam;

PROCEDURE RcTNestedRecord*;
VAR r: RcRect;
BEGIN
  r.topLeft.x := 0;     r.topLeft.y := 0;
  r.bottomRight.x := 80; r.bottomRight.y := 25;
  Test.AssertInt(0,  r.topLeft.x,     "tl.x");
  Test.AssertInt(0,  r.topLeft.y,     "tl.y");
  Test.AssertInt(80, r.bottomRight.x, "br.x");
  Test.AssertInt(25, r.bottomRight.y, "br.y");
  r.topLeft.x := r.bottomRight.x - 10;
  Test.AssertInt(70, r.topLeft.x, "tl.x updated")
END RcTNestedRecord;

PROCEDURE RcTAlignment*;
VAR m: RcMixed;
BEGIN
  m.a := 1; m.b := 1000; m.c := 2; m.d := 2000;
  Test.AssertInt(1,    ORD(m.a), "m.a");
  Test.AssertInt(1000, m.b,      "m.b");
  Test.AssertInt(2,    ORD(m.c), "m.c");
  Test.AssertInt(2000, m.d,      "m.d");
  m.b := m.b + m.d;
  Test.AssertInt(3000, m.b,      "m.b after add");
  Test.AssertInt(1,    ORD(m.a), "m.a unchanged");
  Test.AssertInt(2,    ORD(m.c), "m.c unchanged")
END RcTAlignment;

PROCEDURE RcTMultipleRecords*;
VAR p1, p2, p3: RcPoint;
BEGIN
  p1.x := 1; p1.y := 2;
  p2.x := 3; p2.y := 4;
  p3.x := p1.x + p2.x;
  p3.y := p1.y + p2.y;
  Test.AssertInt(4, p3.x, "p3.x");
  Test.AssertInt(6, p3.y, "p3.y");
  p1.x := 99;
  Test.AssertInt(4, p3.x, "p3.x unchanged")
END RcTMultipleRecords;

PROCEDURE RcTCharField*;
VAR t: RcTagged;
BEGIN
  t.id := 42; t.tag := "Z"; t.val := 100;
  Test.AssertInt(42,  t.id,      "id");
  Test.AssertInt(90,  ORD(t.tag),"tag 'Z'");
  Test.AssertInt(100, t.val,     "val");
  t.tag := CHR(65);
  Test.AssertInt(65,  ORD(t.tag),"tag 'A'");
  Test.AssertInt(42,  t.id,      "id unchanged");
  Test.AssertInt(100, t.val,     "val unchanged")
END RcTCharField;

PROCEDURE RcTCharAdjacentArray*;
                                                                 
                                                                   
VAR n: RcNamed;
BEGIN
  n.id := 99; n.tag := "A"; n.name := "hello";
  Test.AssertInt(99, n.id,        "id after name assign");
  Test.AssertInt(65, ORD(n.tag),  "tag after name assign");
  Test.AssertTrue(n.name[0] = "h","name[0]");
  Test.AssertTrue(n.name[4] = "o","name[4]");

  RcgNamed.id := 7; RcgNamed.tag := "X"; RcgNamed.name := "world";
  Test.AssertInt(7,  RcgNamed.id,        "global id");
  Test.AssertInt(88, ORD(RcgNamed.tag),  "global tag after name assign");
  Test.AssertTrue(RcgNamed.name[0] = "w","global name[0]");
  Test.AssertTrue(RcgNamed.name[4] = "d","global name[4]")
END RcTCharAdjacentArray;

PROCEDURE RcTRecordExtension*;
VAR d: RcDog; c: RcCat;
BEGIN
  d.legs := 4; d.sound := 0; d.tricks := 3;
  Test.AssertInt(4, d.legs,   "dog.legs");
  Test.AssertInt(0, d.sound,  "dog.sound");
  Test.AssertInt(3, d.tricks, "dog.tricks");
  c.legs := 4; c.sound := 1; c.indoor := 1;
  Test.AssertInt(4, c.legs,   "cat.legs");
  Test.AssertInt(1, c.sound,  "cat.sound");
  Test.AssertInt(1, c.indoor, "cat.indoor");
  d.legs := d.legs * 2;
  Test.AssertInt(8, d.legs,   "dog.legs*2");
  Test.AssertInt(3, d.tricks, "dog.tricks unchanged")
END RcTRecordExtension;

PROCEDURE RcAddLegs(VAR a: RcAnimal; extra: INTEGER);
BEGIN a.legs := a.legs + extra END RcAddLegs;

PROCEDURE RcTExtensionVarParam*;
VAR d: RcDog;
BEGIN
  d.legs := 4; d.sound := 0; d.tricks := 5;
  RcAddLegs(d, 2);
  Test.AssertInt(6, d.legs,   "legs after RcAddLegs");
  Test.AssertInt(5, d.tricks, "tricks unchanged")
END RcTExtensionVarParam;

PROCEDURE RcTTwoLevelExtension*;
VAR car: RcCar;
BEGIN
  car.wheels := 4; car.speed := 120; car.hp := 150; car.doors := 4;
  Test.AssertInt(4,   car.wheels, "car.wheels");
  Test.AssertInt(120, car.speed,  "car.speed");
  Test.AssertInt(150, car.hp,     "car.hp");
  Test.AssertInt(4,   car.doors,  "car.doors");
  car.speed := car.speed + car.hp;
  Test.AssertInt(270, car.speed,  "car.speed+hp");
  Test.AssertInt(4,   car.wheels, "car.wheels unchanged")
END RcTTwoLevelExtension;

PROCEDURE RcTHeapRecord*;
VAR p, q: RcPNode;
BEGIN
  NEW(p);
  Test.AssertNotNil(p, "p not nil");
  p^.val := 42; p^.next := NIL;
  Test.AssertInt(42, p^.val, "p.val");
  Test.AssertNil(p^.next, "p.next nil");

  NEW(q);
  Test.AssertNotNil(q, "q not nil");
  q^.val := 99; q^.next := p;
  Test.AssertInt(99, q^.val,      "q.val");
  Test.AssertInt(42, q^.next^.val,"q.next.val");

  DISPOSE(q); DISPOSE(p)
END RcTHeapRecord;

PROCEDURE RcTHeapExtension*;
VAR pd: RcPDog;
BEGIN
  NEW(pd);
  Test.AssertNotNil(pd, "pd not nil");
  pd^.legs := 4; pd^.sound := 0; pd^.tricks := 7;
  Test.AssertInt(4, pd^.legs,   "pd.legs");
  Test.AssertInt(0, pd^.sound,  "pd.sound");
  Test.AssertInt(7, pd^.tricks, "pd.tricks");
  pd^.legs := pd^.legs - 1;
  Test.AssertInt(3, pd^.legs,   "pd.legs dec");
  DISPOSE(pd)
END RcTHeapExtension;

PROCEDURE RcTLinkedList*;
VAR a, b, c, cur: RcPNode;
    sum, count: INTEGER;
BEGIN
  NEW(a); NEW(b); NEW(c);
  a^.val := 10; a^.next := b;
  b^.val := 20; b^.next := c;
  c^.val := 30; c^.next := NIL;

  sum := 0; count := 0;
  cur := a;
  WHILE cur # NIL DO
    sum := sum + cur^.val;
    count := count + 1;
    cur := cur^.next
  END;
  Test.AssertInt(3,  count, "list length");
  Test.AssertInt(60, sum,   "list sum");

  DISPOSE(a); DISPOSE(b); DISPOSE(c)
END RcTLinkedList;

PROCEDURE MdTBasic2D*;
VAR a: ARRAY 3, 4 OF INTEGER; i, j: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 3 DO a[i][j] := i * 10 + j END
  END;
  Test.AssertInt(0,  a[0][0], "a[0][0]");
  Test.AssertInt(3,  a[0][3], "a[0][3]");
  Test.AssertInt(10, a[1][0], "a[1][0]");
  Test.AssertInt(23, a[2][3], "a[2][3]")
END MdTBasic2D;

PROCEDURE MdTVarIndex2D*;
VAR m: ARRAY 4, 4 OF INTEGER; r, c, sum: INTEGER;
BEGIN
  FOR r := 0 TO 3 DO
    FOR c := 0 TO 3 DO m[r][c] := r * 4 + c + 1 END
  END;
  sum := 0;
  FOR c := 0 TO 3 DO sum := sum + m[0][c] END;
  Test.AssertInt(10, sum, "row0 sum");
  sum := 0;
  FOR r := 0 TO 3 DO sum := sum + m[r][r] END;
  Test.AssertInt(34, sum, "diagonal sum")
END MdTVarIndex2D;

PROCEDURE MdTBasic3D*;
VAR b: ARRAY 2, 3, 4 OF INTEGER; x, y, z: INTEGER;
BEGIN
  FOR x := 0 TO 1 DO
    FOR y := 0 TO 2 DO
      FOR z := 0 TO 3 DO b[x][y][z] := x * 100 + y * 10 + z END
    END
  END;
  Test.AssertInt(0,   b[0][0][0], "b[0][0][0]");
  Test.AssertInt(123, b[1][2][3], "b[1][2][3]");
  Test.AssertInt(12,  b[0][1][2], "b[0][1][2]");
  Test.AssertInt(103, b[1][0][3], "b[1][0][3]")
END MdTBasic3D;

PROCEDURE MdTGlobal2D*;
VAR i, j: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO
    FOR j := 0 TO 4 DO Mdgmat[i][j] := i * 5 + j END
  END;
  Test.AssertInt(0,  Mdgmat[0][0], "Mdgmat[0][0]");
  Test.AssertInt(24, Mdgmat[4][4], "Mdgmat[4][4]");
  Test.AssertInt(13, Mdgmat[2][3], "Mdgmat[2][3]");
  Test.AssertInt(19, Mdgmat[3][4], "Mdgmat[3][4]")
END MdTGlobal2D;

PROCEDURE MdTAccum2D*;
VAR a: ARRAY 4, 4 OF INTEGER; i, j, total: INTEGER;
BEGIN
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 3 DO a[i][j] := i * 4 + j + 1 END
  END;
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 3 DO a[i][j] := a[i][j] * 2 END
  END;
  total := 0;
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 3 DO total := total + a[i][j] END
  END;
  Test.AssertInt(272, total,    "total after doubling");
  Test.AssertInt(2,   a[0][0],  "a[0][0]");
  Test.AssertInt(32,  a[3][3],  "a[3][3]")
END MdTAccum2D;

PROCEDURE MdTByte2D*;
VAR b: ARRAY 4, 8 OF BYTE; i, j, sum: INTEGER;
BEGIN
  FOR i := 0 TO 3 DO
    FOR j := 0 TO 7 DO b[i][j] := i * 8 + j END
  END;
  sum := 0;
  FOR j := 0 TO 7 DO sum := sum + ORD(b[1][j]) END;
  Test.AssertInt(92, sum, "row1 sum");
  Test.AssertInt(31, ORD(b[3][7]), "b[3][7]")
END MdTByte2D;

PROCEDURE MdTChar2D*;
VAR table: ARRAY 3, 8 OF CHAR;
BEGIN
  table[0][0] := "A"; table[0][1] := "B"; table[0][2] := "C"; table[0][3] := 0X;
  table[1][0] := "X"; table[1][1] := "Y"; table[1][2] := "Z"; table[1][3] := 0X;
  table[2][0] := "1"; table[2][1] := "2"; table[2][2] := "3"; table[2][3] := 0X;
  Test.AssertTrue(table[0][0] = "A", "table[0][0]='A'");
  Test.AssertTrue(table[1][2] = "Z", "table[1][2]='Z'");
  Test.AssertTrue(table[2][0] = "1", "table[2][0]='1'");
  Test.AssertTrue(table[0][3] = 0X,  "table[0][3]=0X")
END MdTChar2D;

PROCEDURE MdTLayout2D*;
VAR a: ARRAY 3, 4 OF INTEGER; i, j: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 3 DO a[i][j] := i * 4 + j END
  END;
  Test.AssertTrue(a[1][0] > a[0][3],     "a[1][0] > a[0][3] (row-major)");
  Test.AssertTrue(a[0][1] = a[0][0] + 1, "a[0][1] = a[0][0]+1");
  Test.AssertInt(11, a[2][3], "a[2][3]")
END MdTLayout2D;

PROCEDURE TtTStaticTypeTest*;
VAR pd: TtPDog;
BEGIN
  NEW(pd); pd^.legs := 4; pd^.tricks := 3;
  Test.AssertTrue(pd IS TtAnimal, "TtPDog IS TtAnimal (TRUE)");
  Test.AssertTrue(pd IS TtDog,    "TtPDog IS TtDog (TRUE)")
END TtTStaticTypeTest;

PROCEDURE TtTRuntimeDog*;
VAR pd: TtPDog; pa: TtPAnimal;
BEGIN
  NEW(pd); pd^.legs := 4; pd^.tricks := 3;
  pa := pd;
  Test.AssertTrue(pa IS TtDog,  "pa->TtDog IS TtDog (TRUE)");
  Test.AssertFalse(pa IS TtCat, "pa->TtDog IS TtCat (FALSE)")
END TtTRuntimeDog;

PROCEDURE TtTRuntimeAnimal*;
VAR pa: TtPAnimal;
BEGIN
  NEW(pa); pa^.legs := 2;
  Test.AssertFalse(pa IS TtDog, "pa->TtAnimal IS TtDog (FALSE)")
END TtTRuntimeAnimal;

PROCEDURE TtTRuntimeCat*;
VAR pc: TtPCat; pa: TtPAnimal;
BEGIN
  NEW(pc); pc^.legs := 4; pc^.indoor := TRUE;
  pa := pc;
  Test.AssertTrue(pa IS TtCat,  "pa->TtCat IS TtCat (TRUE)");
  Test.AssertFalse(pa IS TtDog, "pa->TtCat IS TtDog (FALSE)")
END TtTRuntimeCat;

(* 3-level extension chain: RcVehicle <- RcMotorVehicle <- RcCar.
   Verifies the type-tag scanner walks the full ancestor list correctly. *)
PROCEDURE TtT3LevelChain*;
  VAR pc: RcPCar; pm: RcPMotorVehicle; pv: RcPVehicle;
BEGIN
  NEW(pc); pc^.wheels := 4; pc^.speed := 0; pc^.hp := 200; pc^.doors := 4;
  (* Static / compile-time extension tests *)
  Test.AssertTrue(pc IS RcVehicle,      "RcPCar IS RcVehicle (static)");
  Test.AssertTrue(pc IS RcMotorVehicle, "RcPCar IS RcMotorVehicle (static)");
  Test.AssertTrue(pc IS RcCar,          "RcPCar IS RcCar (static)");

  (* Runtime through grandparent pointer: must still recognize RcCar *)
  pv := pc;
  Test.AssertTrue(pv IS RcCar,          "pv->RcCar IS RcCar (3-level runtime)");
  Test.AssertTrue(pv IS RcMotorVehicle, "pv->RcCar IS RcMotorVehicle (2-level runtime)");

  (* Through middle parent *)
  pm := pc;
  Test.AssertTrue(pm IS RcCar,          "pm->RcCar IS RcCar (1-level runtime)");

  (* Negative: a bare RcMotorVehicle is NOT a RcCar *)
  NEW(pm); pm^.wheels := 2; pm^.speed := 0; pm^.hp := 100;
  pv := pm;
  Test.AssertFalse(pv IS RcCar,         "pv->RcMotorVehicle IS RcCar (FALSE)");
  Test.AssertTrue(pv  IS RcMotorVehicle,"pv->RcMotorVehicle IS RcMotorVehicle (TRUE)")
END TtT3LevelChain;

PROCEDURE IsTIsType*;
BEGIN
                                           
  Test.AssertTrue(Ispd IS IsAnimal, "Ispd IS IsAnimal (compile-time)");
                                                
  NEW(Ispd);
  Ispa := Ispd;
  Test.AssertTrue(Ispa IS IsDog, "Ispa IS IsDog (runtime)")
END IsTIsType;

PROCEDURE NfTNewFieldVarSize*;
VAR h: NfHolder;
BEGIN
  NEW(h);
  h^.a := NIL; h^.b := NIL; h^.Nfsz := 16;

                                                                      
                                                                        
                                                                     
                                                      
  NEW(h^.a, h^.Nfsz);
  Test.AssertNotNil(h^.a, "h^.a after NEW(h^.a, h^.Nfsz)");

  h^.Nfsz := 32;
  NEW(h^.b, h^.Nfsz);
  Test.AssertNotNil(h^.b, "h^.b after NEW(h^.b, h^.Nfsz)");
  Test.AssertNotNil(h^.a, "h^.a still set");
  Test.AssertTrue(h^.a # h^.b, "h^.a # h^.b")
END NfTNewFieldVarSize;

PROCEDURE BdSumArray(a: ARRAY OF INTEGER): INTEGER;
VAR i, s: INTEGER;
BEGIN
  s := 0;
  FOR i := 0 TO LEN(a) - 1 DO s := s + a[i] END;
  RETURN s
END BdSumArray;

PROCEDURE BdTInBounds*;
VAR a: ARRAY 5 OF INTEGER;
    i, s: INTEGER;
BEGIN
  FOR i := 0 TO 4 DO a[i] := i * 10 END;
  Test.AssertInt(0,  a[0], "a[0]=0");
  Test.AssertInt(40, a[4], "a[4]=40");

  s := BdSumArray(a);
  Test.AssertInt(100, s, "BdSumArray=100");

  a[0] := 999; Test.AssertInt(999, a[0], "a[0] write/read");
  a[4] := -1;  Test.AssertInt(-1,  a[4], "a[4] write/read");

  i := 0; Test.AssertInt(999, a[i], "a[i=0]");
  i := 4; Test.AssertInt(-1,  a[i], "a[i=4]")
END BdTInBounds;

PROCEDURE CaTByteFold*;
CONST OpCallFar = BYTE(9AH);
VAR b: INTEGER;
BEGIN
  b := INTEGER(OpCallFar);
  Test.AssertInt(154, b, "BYTE(9AH)");
  Test.AssertInt(255, INTEGER(BYTE(0FFH)), "BYTE(0FFH)");
  Test.AssertInt(0,   INTEGER(BYTE(256)),  "BYTE(256)");
  Test.AssertInt(255, INTEGER(BYTE(255)),  "BYTE(255)")
END CaTByteFold;

PROCEDURE CaTIntegerFold*;
BEGIN
  Test.AssertInt(0,     INTEGER(0),     "INTEGER(0)");
  Test.AssertInt(3,     INTEGER(3),     "INTEGER(3)");
  Test.AssertInt(32767, INTEGER(32767), "INTEGER(32767)");
  Test.AssertInt(-1,    INTEGER(-1),    "INTEGER(-1)")
END CaTIntegerFold;

PROCEDURE CaTLongintFold*;
CONST Big = LONGINT(100000);
BEGIN
  Test.AssertLong(0,      LONGINT(0),  "LONGINT(0)");
  Test.AssertLong(3,      LONGINT(3),  "LONGINT(3)");
  Test.AssertLong(100000, Big,         "LONGINT(100000)");
  Test.AssertLong(-1,     LONGINT(-1), "LONGINT(-1)")
END CaTLongintFold;

PROCEDURE CaAccumulate(x: LONGINT): LONGINT;
BEGIN RETURN x * 2 + 1 END CaAccumulate;

PROCEDURE CaLongSum(a, b: LONGINT): LONGINT;
BEGIN RETURN a + b END CaLongSum;

PROCEDURE CaTIntToLongParam*;
VAR n: INTEGER; r: LONGINT;
BEGIN
  n := 3;  r := CaAccumulate(n); Test.AssertLong(7,  r, "int->longint param 3");
  n := 0;  r := CaAccumulate(n); Test.AssertLong(1,  r, "int->longint param 0");
  n := -1; r := CaAccumulate(n); Test.AssertLong(-1, r, "int->longint param -1")
END CaTIntToLongParam;

PROCEDURE CaTZeroToLongParam*;
BEGIN
  Test.AssertLong(0, CaLongSum(0, 0), "0+0 as LONGINT");
  Test.AssertLong(1, CaLongSum(1, 0), "1+0 as LONGINT");
  Test.AssertLong(1, CaLongSum(0, 1), "0+1 as LONGINT")
END CaTZeroToLongParam;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(RcTBasicFields, "Rc/basicFields");
  Test.AddTest(RcTGlobalRecord, "Rc/globalRecord");
  Test.AddTest(RcTVarParam, "Rc/varParam");
  Test.AddTest(RcTNestedRecord, "Rc/nestedRecord");
  Test.AddTest(RcTAlignment, "Rc/alignment");
  Test.AddTest(RcTMultipleRecords, "Rc/multipleRecords");
  Test.AddTest(RcTCharField, "Rc/charField");
  Test.AddTest(RcTCharAdjacentArray, "Rc/charAdjacentArray");
  Test.AddTest(RcTRecordExtension, "Rc/extension");
  Test.AddTest(RcTExtensionVarParam, "Rc/extensionVar");
  Test.AddTest(RcTTwoLevelExtension, "Rc/twoLevelExt");
  Test.AddTest(RcTHeapRecord, "Rc/heapRecord");
  Test.AddTest(RcTHeapExtension, "Rc/heapExtension");
  Test.AddTest(RcTLinkedList, "Rc/linkedList");
  Test.AddTest(MdTBasic2D, "Md/basic2D");
  Test.AddTest(MdTVarIndex2D, "Md/varIndex2D");
  Test.AddTest(MdTBasic3D, "Md/basic3D");
  Test.AddTest(MdTGlobal2D, "Md/global2D");
  Test.AddTest(MdTAccum2D, "Md/accum2D");
  Test.AddTest(MdTByte2D, "Md/byte2D");
  Test.AddTest(MdTChar2D, "Md/char2D");
  Test.AddTest(MdTLayout2D, "Md/layout2D");
  Test.AddTest(TtTStaticTypeTest, "Tt/staticTest");
  Test.AddTest(TtTRuntimeDog, "Tt/runtimeDog");
  Test.AddTest(TtTRuntimeAnimal, "Tt/runtimeAnimal");
  Test.AddTest(TtTRuntimeCat, "Tt/runtimeCat");
  Test.AddTest(TtT3LevelChain, "Tt/3levelChain");
  Test.AddTest(IsTIsType, "Is/isType");
  Test.AddTest(NfTNewFieldVarSize, "Nf/varSize");
  Test.AddTest(BdTInBounds, "Bd/inBounds");
  Test.AddTest(CaTByteFold, "Ca/byteFold");
  Test.AddTest(CaTIntegerFold, "Ca/intFold");
  Test.AddTest(CaTLongintFold, "Ca/longintFold");
  Test.AddTest(CaTIntToLongParam, "Ca/intToLongParam");
  Test.AddTest(CaTZeroToLongParam, "Ca/zeroToLongParam");
  Test.RunTests
END RunAllTests;

END RECARR.
