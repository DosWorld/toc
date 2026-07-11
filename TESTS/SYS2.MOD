MODULE SYS2;
IMPORT Test, Out;

TYPE
  (* Proc-typed VARs are always FAR (see DOCS/OBERLANG.MD §"Procedural
     variables") — PROCEDURE NEAR is not a valid type for a VAR/field, even
     though the underlying procedure it refers to may itself be NEAR. *)
  NfFarBinop    = PROCEDURE FAR  (a, b: INTEGER): INTEGER;
  NfFarBinopDef = PROCEDURE      (a, b: INTEGER): INTEGER;
  AdAllocFn = PROCEDURE FAR (n: WORD): SYSTEM.ADDRESS;
  GlPoint  = RECORD x, y: INTEGER END;
  GlNamed  = RECORD id: INTEGER; tag: CHAR; score: INTEGER END;
  GlMixed  = RECORD b1: BYTE; i1: INTEGER; b2: BYTE; i2: INTEGER END;

VAR
  NfnearFn:   PROCEDURE FAR  (a, b: INTEGER): INTEGER;
  NffarFn:    PROCEDURE FAR  (a, b: INTEGER): INTEGER;
  NfdefFn:    PROCEDURE      (a, b: INTEGER): INTEGER;
  NfnearFn2:  NfFarBinop;
  NffarFn2:   NfFarBinop;
  IngA, IngB: INTEGER;
  GlgI1, GlgI2, GlgI3 : INTEGER;
  GlgB1            : BOOLEAN;
  GlgC1            : CHAR;
  GlgArr10         : ARRAY 10 OF INTEGER;
  GlgStr16         : ARRAY 16 OF CHAR;
  GlgCharArr8      : ARRAY 8 OF CHAR;
  GlgPt1, GlgPt2     : GlPoint;
  GlgNamed         : GlNamed;
  GlgMixed         : GlMixed;
  GlgAccum         : INTEGER;
  GlgCounter       : ARRAY 4 OF INTEGER;
  Rapass, Rafail: INTEGER;

PROCEDURE NfAddNear(a, b: INTEGER): INTEGER; NEAR;
BEGIN RETURN a + b END NfAddNear;

PROCEDURE NfMulNear(a, b: INTEGER): INTEGER; NEAR;
BEGIN RETURN a * b END NfMulNear;

PROCEDURE NfNopNear; NEAR;
BEGIN END NfNopNear;

PROCEDURE NfAddFar(a, b: INTEGER): INTEGER; FAR;
BEGIN RETURN a + b END NfAddFar;

PROCEDURE NfSubFar(a, b: INTEGER): INTEGER; FAR;
BEGIN RETURN a - b END NfSubFar;

PROCEDURE NfTDirectCalls*;
VAR r: INTEGER;
BEGIN
  r := NfAddNear(3, 4); Test.AssertInt(7,  r, "NfAddNear direct");
  r := NfMulNear(5, 6); Test.AssertInt(30, r, "NfMulNear direct");
  NfNopNear;
  Test.AssertTrue(TRUE, "NfNopNear no crash");
  r := NfAddFar(10, 20); Test.AssertInt(30, r, "NfAddFar direct");
  r := NfSubFar(15, 5);  Test.AssertInt(10, r, "NfSubFar direct")
END NfTDirectCalls;

(* A FAR-typed proc VAR can hold the address of a NEAR-declared procedure
   (only the VAR's own storage/call-through-variable codegen must be FAR —
   see DOCS/OBERLANG.MD §"Procedural variables"); this covers that case. *)
PROCEDURE NfTNearProcVar*;
VAR r: INTEGER;
BEGIN
  NfnearFn := NfAddNear; r := NfnearFn(7, 8); Test.AssertInt(15, r, "FAR var holding NfAddNear");
  NfnearFn := NfMulNear; r := NfnearFn(3, 5); Test.AssertInt(15, r, "FAR var holding NfMulNear");
  NfnearFn2 := NfAddNear; r := NfnearFn2(11, 4); Test.AssertInt(15, r, "named NfFarBinop holding NfAddNear");
  NfnearFn2 := NfMulNear; r := NfnearFn2(4, 5);  Test.AssertInt(20, r, "named NfFarBinop holding NfMulNear");

  NfnearFn := NfAddNear;
  Test.AssertInt(3,  NfnearFn(1, 2), "swap before");
  NfnearFn := NfMulNear;
  Test.AssertInt(12, NfnearFn(3, 4), "swap after")
END NfTNearProcVar;

PROCEDURE NfTFarProcVar*;
VAR r: INTEGER;
BEGIN
  NffarFn := NfAddFar; r := NffarFn(6, 4); Test.AssertInt(10, r, "FAR var NfAddFar");
  NffarFn := NfSubFar; r := NffarFn(9, 3); Test.AssertInt(6,  r, "FAR var NfSubFar");
  NfdefFn := NfAddFar; r := NfdefFn(2, 3); Test.AssertInt(5,  r, "default (FAR) var NfAddFar");
  NffarFn2 := NfAddFar; r := NffarFn2(100, 23); Test.AssertInt(123, r, "named NfFarBinop NfAddFar")
END NfTFarProcVar;

PROCEDURE InNop*;
  INLINE(090H);

PROCEDURE InLit42*(): INTEGER;
  INLINE(0B8H, 02AH, 000H);

PROCEDURE InLoadGlobal*(VAR x: INTEGER): INTEGER;
  INLINE(08BH, 006H, x);

PROCEDURE InStoreGlobal*(VAR x: INTEGER);
  INLINE(089H, 006H, x);

PROCEDURE InRun*;
VAR n: INTEGER;
BEGIN
                                         
  InNop();
  Out.String("T1: NOP OK"); Out.Ln;

                                  
  n := InLit42();
  Out.String("T2: InLit42="); Out.Int(n, 0); Out.Ln;

                               
  IngA := 77;
  n := InLoadGlobal(IngA);
  Out.String("T3: InLoadGlobal(IngA)="); Out.Int(n, 0); Out.Ln;

                                 
  IngB := 0;
  n := 99;                                                                      
                                                                 
                                                                               
                                          
  IngA := 55;
  InStoreGlobal(IngB);                                                          
                                                               
                                                                      
  Out.String("T4: InStoreGlobal OK (IngB="); Out.Int(IngB, 0); Out.String(")"); Out.Ln;

  Out.String("DONE"); Out.Ln;
END InRun;

PROCEDURE AdNearOne(): INTEGER;     BEGIN RETURN 11 END AdNearOne;

PROCEDURE AdFarTwo*(): INTEGER;     BEGIN RETURN 22 END AdFarTwo;

PROCEDURE AdTLocalNear*;
VAR a: SYSTEM.ADDRESS;
BEGIN
  a := SYSTEM.ADR(AdNearOne);
  Test.AssertNotNil(a, "ADR(AdNearOne)")
END AdTLocalNear;

PROCEDURE AdTLocalFar*;
VAR a: SYSTEM.ADDRESS;
BEGIN
  a := SYSTEM.ADR(AdFarTwo);
  Test.AssertNotNil(a, "ADR(AdFarTwo)")
END AdTLocalFar;

PROCEDURE AdTImportedFar*;
VAR a, p: SYSTEM.ADDRESS;
    pair: ARRAY 2 OF INTEGER;
    alloc: AdAllocFn;
BEGIN
  a := SYSTEM.ADR(SYSTEM.Alloc);
  Test.AssertNotNil(a, "ADR(SYSTEM.Alloc)");
  SYSTEM.MOVE(a, pair[0], 4);
  Test.AssertTrue(pair[1] # 0, "ADR(SYSTEM.Alloc).seg # 0");
  alloc := a;
  p := alloc(16);
  Test.AssertNotNil(p, "alloc(16) returns non-NIL")
END AdTImportedFar;

PROCEDURE GlSetGI(a, b, c: INTEGER);
BEGIN GlgI1 := a; GlgI2 := b; GlgI3 := c END GlSetGI;

PROCEDURE GlSumGI(): INTEGER;
BEGIN RETURN GlgI1 + GlgI2 + GlgI3 END GlSumGI;

PROCEDURE GlTGlobalIntegers*;
BEGIN
  GlSetGI(10, 20, 30);
  Test.AssertInt(10, GlgI1, "GlgI1");
  Test.AssertInt(20, GlgI2, "GlgI2");
  Test.AssertInt(30, GlgI3, "GlgI3");
  Test.AssertInt(60, GlSumGI(), "sum");
  GlSetGI(-1, -2, -3);
  Test.AssertInt(-6, GlSumGI(), "sum neg")
END GlTGlobalIntegers;

PROCEDURE GlTGlobalScalars*;
BEGIN
  GlgB1 := TRUE;  Test.AssertTrue(GlgB1, "GlgB1 TRUE");
  GlgB1 := FALSE; Test.AssertFalse(GlgB1, "GlgB1 FALSE");
  GlgB1 := ~GlgB1;  Test.AssertTrue(GlgB1, "~FALSE = TRUE");
  GlgC1 := "Z";   Test.AssertTrue(GlgC1 = "Z", "GlgC1='Z'");
  GlgC1 := CHR(ORD(GlgC1) - 25);                
  Test.AssertTrue(GlgC1 = "A", "GlgC1='A'");
  Test.AssertInt(65, ORD(GlgC1), "ORD('A')")
END GlTGlobalScalars;

PROCEDURE GlFillArr(val: INTEGER);
VAR i: INTEGER;
BEGIN FOR i := 0 TO 9 DO GlgArr10[i] := val END END GlFillArr;

PROCEDURE GlSumArr(): INTEGER;
VAR i, s: INTEGER;
BEGIN s := 0; FOR i := 0 TO 9 DO s := s + GlgArr10[i] END; RETURN s END GlSumArr;

PROCEDURE GlTGlobalIntArray*;
VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 9 DO GlgArr10[i] := i * i END;
  Test.AssertInt(0,  GlgArr10[0], "arr[0]");
  Test.AssertInt(9,  GlgArr10[3], "arr[3]");
  Test.AssertInt(81, GlgArr10[9], "arr[9]");
  Test.AssertInt(285, GlSumArr(), "sum squares 0..9");
  GlFillArr(5);
  Test.AssertInt(50, GlSumArr(), "10*5");
  GlgArr10[4] := 100;
  Test.AssertInt(5,   GlgArr10[3], "arr[3] unchanged");
  Test.AssertInt(100, GlgArr10[4], "arr[4]");
  Test.AssertInt(5,   GlgArr10[5], "arr[5] unchanged")
END GlTGlobalIntArray;

PROCEDURE GlTGlobalCharArray*;
BEGIN
  GlgStr16 := "hello";
  Test.AssertTrue(GlgStr16[0] = "h",    "str[0]='h'");
  Test.AssertTrue(GlgStr16[4] = "o",    "str[4]='o'");
  Test.AssertInt(0, ORD(GlgStr16[5]),    "str[5]=NUL");
  GlgStr16 := "hi";
  Test.AssertTrue(GlgStr16[0] = "h",    "hi[0]='h'");
  Test.AssertTrue(GlgStr16[1] = "i",    "hi[1]='i'");
  Test.AssertInt(0, ORD(GlgStr16[2]),    "hi[2]=NUL");
  GlgStr16[0] := "H";
  Test.AssertTrue(GlgStr16[0] = "H",    "str[0]='H'");
  Test.AssertTrue(GlgStr16[1] = "i",    "str[1]='i' unchanged")
END GlTGlobalCharArray;

PROCEDURE GlTGlobalCharElemWrite*;
VAR i: INTEGER;
BEGIN
  GlgCharArr8 := "abcdefg";
  Test.AssertTrue(GlgCharArr8[0] = "a", "orig[0]='a'");
  FOR i := 0 TO 6 DO
    GlgCharArr8[i] := CHR(ORD(GlgCharArr8[i]) - 32)
  END;
  Test.AssertTrue(GlgCharArr8[0] = "A", "[0]='A'");
  Test.AssertTrue(GlgCharArr8[3] = "D", "[3]='D'");
  Test.AssertTrue(GlgCharArr8[6] = "G", "[6]='G'");
  Test.AssertInt(0, ORD(GlgCharArr8[7]),"[7]=NUL")
END GlTGlobalCharElemWrite;

PROCEDURE GlTGlobalRecord*;
BEGIN
  GlgPt1.x := 100; GlgPt1.y := 200;
  Test.AssertInt(100, GlgPt1.x, "x");
  Test.AssertInt(200, GlgPt1.y, "y");
  GlgPt1.x := GlgPt1.x + GlgPt1.y;
  Test.AssertInt(300, GlgPt1.x, "x+y")
END GlTGlobalRecord;

PROCEDURE GlTTwoGlobalRecords*;
BEGIN
  GlgPt1.x := 1; GlgPt1.y := 2;
  GlgPt2.x := 3; GlgPt2.y := 4;
  Test.AssertInt(1, GlgPt1.x, "pt1.x");
  Test.AssertInt(3, GlgPt2.x, "pt2.x");
  GlgPt2.x := 99;
  Test.AssertInt(1,  GlgPt1.x, "pt1.x unaffected");
  Test.AssertInt(99, GlgPt2.x, "pt2.x updated")
END GlTTwoGlobalRecords;

PROCEDURE GlTGlobalRecordChar*;
BEGIN
  GlgNamed.id    := 42;
  GlgNamed.tag   := "X";
  GlgNamed.score := 100;
  Test.AssertInt(42,  GlgNamed.id,        "id");
  Test.AssertInt(88,  ORD(GlgNamed.tag),  "tag 'X'=88");
  Test.AssertInt(100, GlgNamed.score,     "score");
  GlgNamed.tag := "Y";
  Test.AssertInt(42,  GlgNamed.id,        "id after tag chg");
  Test.AssertInt(89,  ORD(GlgNamed.tag),  "tag 'Y'=89");
  Test.AssertInt(100, GlgNamed.score,     "score after tag chg")
END GlTGlobalRecordChar;

PROCEDURE GlTGlobalMixedRecord*;
BEGIN
  GlgMixed.b1 := 1; GlgMixed.i1 := 1000;
  GlgMixed.b2 := 2; GlgMixed.i2 := 2000;
  Test.AssertInt(1,    ORD(GlgMixed.b1), "b1=1");
  Test.AssertInt(1000, GlgMixed.i1,      "i1");
  Test.AssertInt(2,    ORD(GlgMixed.b2), "b2=2");
  Test.AssertInt(2000, GlgMixed.i2,      "i2");
  GlgMixed.i1 := GlgMixed.i1 + GlgMixed.i2;
  Test.AssertInt(3000, GlgMixed.i1,      "i1+i2");
  Test.AssertInt(1,    ORD(GlgMixed.b1), "b1 unchanged");
  Test.AssertInt(2,    ORD(GlgMixed.b2), "b2 unchanged");
  Test.AssertInt(2000, GlgMixed.i2,      "i2 unchanged")
END GlTGlobalMixedRecord;

PROCEDURE GlResetAccum;   BEGIN GlgAccum := 0 END GlResetAccum;

PROCEDURE GlAddToAccum(v: INTEGER); BEGIN GlgAccum := GlgAccum + v END GlAddToAccum;

PROCEDURE GlGetAccum(): INTEGER; BEGIN RETURN GlgAccum END GlGetAccum;

PROCEDURE GlTGlobalSharing*;
BEGIN
  GlResetAccum;
  Test.AssertInt(0, GlGetAccum(), "initial 0");
  GlAddToAccum(5); GlAddToAccum(10); GlAddToAccum(15);
  Test.AssertInt(30, GlGetAccum(), "sum 5+10+15");
  GlAddToAccum(-30);
  Test.AssertInt(0, GlGetAccum(), "back to 0")
END GlTGlobalSharing;

PROCEDURE GlResetCounters;
VAR i: INTEGER;
BEGIN FOR i := 0 TO 3 DO GlgCounter[i] := 0 END END GlResetCounters;

PROCEDURE GlBumpCounter(i: INTEGER);
BEGIN
  IF (i >= 0) & (i < 4) THEN INC(GlgCounter[i]) END
END GlBumpCounter;

PROCEDURE GlCounterSum(): INTEGER;
VAR i, s: INTEGER;
BEGIN s := 0; FOR i := 0 TO 3 DO s := s + GlgCounter[i] END; RETURN s END GlCounterSum;

PROCEDURE GlTGlobalArraySharing*;
VAR i: INTEGER;
BEGIN
  GlResetCounters;
  Test.AssertInt(0, GlCounterSum(), "initial sum");
  FOR i := 0 TO 3 DO GlBumpCounter(i) END;
  Test.AssertInt(4, GlCounterSum(), "4 bumps sum");
  GlBumpCounter(0); GlBumpCounter(0); GlBumpCounter(3);
  Test.AssertInt(3, GlgCounter[0], "counter[0]");
  Test.AssertInt(1, GlgCounter[1], "counter[1]");
  Test.AssertInt(2, GlgCounter[3], "counter[3]")
END GlTGlobalArraySharing;

PROCEDURE RaCheck(name: ARRAY OF CHAR; got, expected: INTEGER);
BEGIN
  IF got = expected THEN
    Out.String("  PASS "); Out.String(name); Out.Ln; INC(Rapass)
  ELSE
    Out.String("  FAIL "); Out.String(name);
    Out.String(" got="); Out.Int(got, 0);
    Out.String(" expected="); Out.Int(expected, 0); Out.Ln;
    INC(Rafail)
  END
END RaCheck;

PROCEDURE RaMakeAddr(): SYSTEM.ADDRESS;
BEGIN
  RETURN SYSTEM.PTR(1234H, 5678H)
END RaMakeAddr;

PROCEDURE RaMakeNil(): SYSTEM.ADDRESS;
BEGIN
  RETURN NIL
END RaMakeNil;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(NfTDirectCalls, "Nf/directCalls");
  Test.AddTest(NfTNearProcVar, "Nf/nearProcVar");
  Test.AddTest(NfTFarProcVar, "Nf/farProcVar");
  Test.AddTest(AdTLocalNear, "Ad/localNear");
  Test.AddTest(AdTLocalFar, "Ad/localFar");
  Test.AddTest(AdTImportedFar, "Ad/importedFar");
  Test.AddTest(GlTGlobalIntegers, "Gl/integers");
  Test.AddTest(GlTGlobalScalars, "Gl/scalars");
  Test.AddTest(GlTGlobalIntArray, "Gl/intArray");
  Test.AddTest(GlTGlobalCharArray, "Gl/charArray");
  Test.AddTest(GlTGlobalCharElemWrite, "Gl/charElemWrite");
  Test.AddTest(GlTGlobalRecord, "Gl/record");
  Test.AddTest(GlTTwoGlobalRecords, "Gl/twoRecords");
  Test.AddTest(GlTGlobalRecordChar, "Gl/recordChar");
  Test.AddTest(GlTGlobalMixedRecord, "Gl/mixedRecord");
  Test.AddTest(GlTGlobalSharing, "Gl/sharing");
  Test.AddTest(GlTGlobalArraySharing, "Gl/arraySharing");
  Test.RunTests
END RunAllTests;

END SYS2.
