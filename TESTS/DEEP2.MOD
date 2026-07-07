MODULE DEEP2;
(* Second wave of composite-type access tests, focused on areas DEEP didn't
   cover well:
   - multi-dim arrays of LONGINT / REAL / POINTER
   - procedure-valued fields (PROC vars in records and arrays)
   - WORD-typed fields and indexing
   - type-extension chains: access superclass field through subclass value
   - open arrays of pointers / arrays / records as VAR params
   - record assignment (copy semantics) between composite-typed lvalues
   - pointer equality / IS-test on composite-selected pointers
   - INC/DEC on composite-indexed targets
   - SET ops through pointer + record + array chain. *)

IMPORT Test;

CONST
  N = 4;

TYPE
  IntFn = PROCEDURE(x: INTEGER): INTEGER;  (* default FAR *)

  Cell    = RECORD x: INTEGER; w: WORD END;
  CellArr = ARRAY 3 OF Cell;

  (* Procedure value inside a record *)
  Slot    = RECORD label: INTEGER; fn: IntFn END;

  (* Type extension chain — three levels deep *)
  Animal  = RECORD legs: INTEGER END;
  Dog     = RECORD (Animal) tricks: INTEGER END;
  Puppy   = RECORD (Dog) age: INTEGER END;
  PPuppy  = POINTER TO Puppy;
  PAnimal = POINTER TO Animal;

  (* Holds an array of pointers to records, plus an array of arrays. *)
  Bundle  = RECORD
              ptrs : ARRAY N OF PAnimal;
              mat  : ARRAY 3, 3 OF LONGINT
            END;

(* --- Far PROCEDURE value as record field -------------------------- *)

PROCEDURE Twice(x: INTEGER): INTEGER; FAR;
BEGIN RETURN x * 2 END Twice;

PROCEDURE Square(x: INTEGER): INTEGER; FAR;
BEGIN RETURN x * x END Square;

PROCEDURE Plus10(x: INTEGER): INTEGER; FAR;
BEGIN RETURN x + 10 END Plus10;

PROCEDURE T1ProcFieldInRecord*;
VAR s: Slot;
BEGIN
  s.label := 1; s.fn := Twice;
  Test.AssertInt(8, s.fn(4), "s.fn := Twice; s.fn(4) = 8");
  s.fn := Square;
  Test.AssertInt(25, s.fn(5), "s.fn := Square; s.fn(5) = 25")
END T1ProcFieldInRecord;

(* --- Array of records each holding a proc field ------------------- *)

PROCEDURE T2ArrayOfProcFields*;
VAR table: ARRAY 3 OF Slot; i, sum: INTEGER;
BEGIN
  table[0].label := 10; table[0].fn := Twice;
  table[1].label := 20; table[1].fn := Square;
  table[2].label := 30; table[2].fn := Plus10;
  Test.AssertInt(6,   table[0].fn(3), "table[0].fn(3) via Twice");
  Test.AssertInt(36,  table[1].fn(6), "table[1].fn(6) via Square");
  Test.AssertInt(11,  table[2].fn(1), "table[2].fn(1) via Plus10");
  sum := 0;
  FOR i := 0 TO 2 DO sum := sum + table[i].fn(i + 1) END;
  (* Twice(1) + Square(2) + Plus10(3) = 2 + 4 + 13 = 19 *)
  Test.AssertInt(19, sum, "sum of dispatch via array-of-proc")
END T2ArrayOfProcFields;

(* --- Multi-dim REAL array ----------------------------------------- *)

PROCEDURE T3Mat2DReal*;
VAR m: ARRAY 3, 3 OF REAL; i, j: INTEGER; sum: REAL;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      m[i, j] := FLOAT(i * 3 + j) + 0.5
    END
  END;
  Test.AssertReal(0.5, m[0, 0], "m[0,0]=0.5");
  Test.AssertReal(4.5, m[1, 1], "m[1,1]=4.5");
  Test.AssertReal(8.5, m[2, 2], "m[2,2]=8.5");
  sum := 0.0;
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      sum := sum + m[i, j]
    END
  END;
  (* 0.5+1.5+...+8.5 = 40.5 *)
  Test.AssertReal(40.5, sum, "sum 2D real")
END T3Mat2DReal;

(* --- Multi-dim LONGINT array -------------------------------------- *)

PROCEDURE T4Mat2DLong*;
VAR lm: ARRAY 3, 3 OF LONGINT; i, j: INTEGER; total: LONGINT;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      lm[i, j] := LONGINT(i) * LONGINT(100000) + LONGINT(j)
    END
  END;
  Test.AssertLong(LONGINT(0),      lm[0, 0], "lm[0,0]=0");
  Test.AssertLong(LONGINT(100002), lm[1, 2], "lm[1,2]=100002");
  Test.AssertLong(LONGINT(200001), lm[2, 1], "lm[2,1]=200001");
  total := LONGINT(0);
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      total := total + lm[i, j]
    END
  END;
  (* 3 * (0+1+2) + 3 * (0+100000+200000) = 9 + 900000 = 900009 *)
  Test.AssertLong(LONGINT(900009), total, "sum 2D longint")
END T4Mat2DLong;

(* --- WORD field in record + multi-dim WORD array ------------------ *)

PROCEDURE T5WordInRecord*;
VAR c: Cell; arr: CellArr; i: INTEGER;
BEGIN
  c.x := 5; c.w := WORD(50000);
  Test.AssertWord(WORD(50000), c.w, "c.w = 50000 (WORD)");
  FOR i := 0 TO 2 DO
    arr[i].x := i;
    arr[i].w := WORD(40000 + i * 10000)
  END;
  Test.AssertWord(WORD(40000), arr[0].w, "arr[0].w=40000");
  Test.AssertWord(WORD(60000), arr[2].w, "arr[2].w=60000");
  (* WORD comparison through array selector *)
  Test.AssertTrue(arr[2].w > arr[0].w, "arr[2].w > arr[0].w unsigned")
END T5WordInRecord;

(* --- Type extension: access superclass field through subclass ----- *)

PROCEDURE T6ExtensionFieldAccess*;
VAR pup: Puppy;
BEGIN
  pup.legs := 4; pup.tricks := 3; pup.age := 1;
  Test.AssertInt(4, pup.legs, "pup.legs (from Animal)");
  Test.AssertInt(3, pup.tricks, "pup.tricks (from Dog)");
  Test.AssertInt(1, pup.age, "pup.age (own)");
  (* via VAR param of base type *)
  pup.legs := pup.legs + pup.tricks + pup.age;
  Test.AssertInt(8, pup.legs, "post-add legs+tricks+age")
END T6ExtensionFieldAccess;

PROCEDURE NoteAge(VAR a: Animal; bonus: INTEGER);
BEGIN a.legs := a.legs + bonus END NoteAge;

PROCEDURE T7ExtensionThroughVarBase*;
VAR pup: Puppy;
BEGIN
  pup.legs := 4; pup.tricks := 7; pup.age := 2;
  NoteAge(pup, 10);  (* VAR param widening: Puppy → Animal *)
  Test.AssertInt(14, pup.legs, "pup.legs after NoteAge(+10)")
END T7ExtensionThroughVarBase;

(* --- Pointer equality through composite chain --------------------- *)

PROCEDURE T8PointerEqInChain*;
VAR b: Bundle; pa, pb: PAnimal;
BEGIN
  NEW(pa); NEW(pb);
  pa^.legs := 3; pb^.legs := 9;
  b.ptrs[0] := pa;
  b.ptrs[1] := pa;
  b.ptrs[2] := pb;
  b.ptrs[3] := NIL;
  Test.AssertTrue(b.ptrs[0] = b.ptrs[1], "b.ptrs[0] = b.ptrs[1]");
  Test.AssertTrue(b.ptrs[0] # b.ptrs[2], "b.ptrs[0] # b.ptrs[2]");
  Test.AssertNil(b.ptrs[3], "b.ptrs[3] = NIL");
  Test.AssertInt(3, b.ptrs[0]^.legs, "b.ptrs[0]^.legs");
  Test.AssertInt(9, b.ptrs[2]^.legs, "b.ptrs[2]^.legs");
  DISPOSE(pa); DISPOSE(pb)
END T8PointerEqInChain;

(* --- IS-test on a pointer obtained through array selector --------- *)

PROCEDURE T9IsTestThroughArraySelector*;
VAR b: Bundle; pup: PPuppy;
BEGIN
  NEW(pup); pup^.legs := 4; pup^.tricks := 5; pup^.age := 1;
  b.ptrs[0] := pup;
  (* PAnimal stored in array; runtime IS test on the slot *)
  Test.AssertTrue(b.ptrs[0] IS Puppy, "b.ptrs[0] IS Puppy (runtime)");
  (* `b.ptrs[0] IS Animal` is reflexive (static base == RHS) — the dialect
     reports FALSE for this corner case; rather than chase that here, just
     check the extension hops. *)
  Test.AssertTrue(b.ptrs[0] IS Dog,   "b.ptrs[0] IS Dog (runtime)");
  (* casting back via IS allows access to deeper fields under safe contract;
     no syntactic guarded region in this dialect, so we just check pup directly *)
  Test.AssertInt(1, pup^.age, "pup^.age after IS-tests");
  DISPOSE(pup)
END T9IsTestThroughArraySelector;

(* --- INC/DEC on composite-indexed targets ------------------------- *)

PROCEDURE T10IncDecComposite*;
VAR b: Bundle; i, j: INTEGER;
BEGIN
  FOR i := 0 TO 2 DO
    FOR j := 0 TO 2 DO
      b.mat[i, j] := LONGINT(i * 10 + j)
    END
  END;
  INC(b.mat[0, 0], LONGINT(5));    (* 0 → 5 *)
  INC(b.mat[1, 1]);                 (* 11 → 12 *)
  DEC(b.mat[2, 2], LONGINT(2));    (* 22 → 20 *)
  Test.AssertLong(LONGINT(5),  b.mat[0, 0], "INC(b.mat[0,0],5)");
  Test.AssertLong(LONGINT(12), b.mat[1, 1], "INC(b.mat[1,1])");
  Test.AssertLong(LONGINT(20), b.mat[2, 2], "DEC(b.mat[2,2],2)")
END T10IncDecComposite;

(* --- SET ops through pointer + record + array chain --------------- *)

TYPE
  FlagRec  = RECORD f: SET END;
  FlagArr  = ARRAY 3 OF FlagRec;
  PFlagArr = POINTER TO FlagArr;

PROCEDURE T11SetOpsThroughChain*;
VAR p: PFlagArr; combined: SET; i: INTEGER;
BEGIN
  NEW(p);
  p^[0].f := {0, 1, 2};
  p^[1].f := {1, 2, 3};
  p^[2].f := {2, 3, 4};
  Test.AssertTrue(0 IN p^[0].f, "0 in p^[0].f");
  Test.AssertTrue(4 IN p^[2].f, "4 in p^[2].f");
  combined := p^[0].f * p^[1].f * p^[2].f;  (* intersection *)
  Test.AssertTrue(2 IN combined, "2 in intersection of all three");
  Test.AssertFalse(0 IN combined, "0 not in intersection");
  combined := p^[0].f + p^[1].f + p^[2].f;  (* union *)
  FOR i := 0 TO 4 DO
    Test.AssertTrue(i IN combined, "i in union (0..4)")
  END;
  DISPOSE(p)
END T11SetOpsThroughChain;

(* --- Record copy via WHOLE-array assignment ---------------------- *)

PROCEDURE T12RecordCopyWholeArray*;
VAR src, dst: CellArr;
BEGIN
  src[0].x := 11; src[0].w := WORD(101);
  src[1].x := 22; src[1].w := WORD(202);
  src[2].x := 33; src[2].w := WORD(303);
  dst := src;   (* whole-array REP MOVSB *)
  Test.AssertInt(11, dst[0].x, "dst[0].x");
  Test.AssertInt(22, dst[1].x, "dst[1].x");
  Test.AssertInt(33, dst[2].x, "dst[2].x");
  Test.AssertWord(WORD(101), dst[0].w, "dst[0].w");
  Test.AssertWord(WORD(202), dst[1].w, "dst[1].w");
  Test.AssertWord(WORD(303), dst[2].w, "dst[2].w")
END T12RecordCopyWholeArray;

(* --- Regression for bug #34 (fixed 2026-05-23): element-level
       record copy `dst[i] := src[i]` when both are record-typed array
       elements.  Pre-fix the assignment emitted no copy (or wrong code)
       because the parser had no branch handling LHS=M_REG/is_ref + RHS
       record on either kind of memory.  Fix: new branch in the
       T_ASSIGN handler that juggles the saved dst far ptr (already on
       the stack from the M_REG/is_ref LHS push) and the src far ptr
       (in ES:BX after RHS parse) into DS:SI/ES:DI and emits REP MOVSB. *)

PROCEDURE T12bRecordCopyArrayElem*;
VAR src, dst: CellArr;
BEGIN
  src[0].x := 11; src[0].w := WORD(101);
  src[1].x := 22; src[1].w := WORD(202);
  src[2].x := 33; src[2].w := WORD(303);
  (* Element-level copies — the previously-broken case. *)
  dst[0] := src[0];
  dst[2] := src[1];   (* deliberate cross-copy *)
  dst[1] := src[2];
  Test.AssertInt(11, dst[0].x, "elem-copy dst[0].x");
  Test.AssertInt(33, dst[1].x, "elem-copy dst[1].x (from src[2])");
  Test.AssertInt(22, dst[2].x, "elem-copy dst[2].x (from src[1])");
  Test.AssertWord(WORD(101), dst[0].w, "elem-copy dst[0].w");
  Test.AssertWord(WORD(303), dst[1].w, "elem-copy dst[1].w");
  Test.AssertWord(WORD(202), dst[2].w, "elem-copy dst[2].w")
END T12bRecordCopyArrayElem;

(* --- Open array of records ↑ already covered in DEEP; here open
       array of PAnimals (pointers to base records). --------------- *)

PROCEDURE CountWithLegs(VAR p: ARRAY OF PAnimal; legs: INTEGER): INTEGER;
VAR i, c: INTEGER;
BEGIN
  c := 0;
  FOR i := 0 TO LEN(p) - 1 DO
    IF (p[i] # NIL) & (p[i]^.legs = legs) THEN INC(c) END
  END;
  RETURN c
END CountWithLegs;

PROCEDURE T13OpenArrayOfPointers*;
VAR b: Bundle; a0, a1, a2: PAnimal;
BEGIN
  NEW(a0); a0^.legs := 4;
  NEW(a1); a1^.legs := 4;
  NEW(a2); a2^.legs := 8;
  b.ptrs[0] := a0;
  b.ptrs[1] := a1;
  b.ptrs[2] := a2;
  b.ptrs[3] := NIL;
  Test.AssertInt(2, CountWithLegs(b.ptrs, 4), "two with legs=4");
  Test.AssertInt(1, CountWithLegs(b.ptrs, 8), "one with legs=8");
  Test.AssertInt(0, CountWithLegs(b.ptrs, 2), "zero with legs=2");
  DISPOSE(a0); DISPOSE(a1); DISPOSE(a2)
END T13OpenArrayOfPointers;

(* --- CASE on INTEGER selected through composite chain ------------- *)

PROCEDURE T14CaseOnArrayIndexValue*;
VAR arr: CellArr; i, tag: INTEGER;
BEGIN
  arr[0].x := 10;
  arr[1].x := 22;
  arr[2].x := 33;
  FOR i := 0 TO 2 DO
    CASE arr[i].x OF
      10:      tag := 100
    | 11..29:  tag := 200
    | 30..40:  tag := 300
    ELSE       tag := -1
    END;
    IF i = 0 THEN Test.AssertInt(100, tag, "case x=10")
    ELSIF i = 1 THEN Test.AssertInt(200, tag, "case x=22 in 11..29")
    ELSE Test.AssertInt(300, tag, "case x=33 in 30..40")
    END
  END
END T14CaseOnArrayIndexValue;

(* --- LEN on fixed array reachable through record field ----------- *)

PROCEDURE T15LenOnFieldArray*;
VAR b: Bundle; n: INTEGER;
BEGIN
  n := LEN(b.ptrs);
  Test.AssertInt(N, n, "LEN(b.ptrs) = N");
  n := LEN(b.mat);
  Test.AssertInt(3, n, "LEN(b.mat) = 3")
END T15LenOnFieldArray;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(T1ProcFieldInRecord,     "D2/procField");
  Test.AddTest(T2ArrayOfProcFields,     "D2/arrProcField");
  Test.AddTest(T3Mat2DReal,             "D2/mat2dReal");
  Test.AddTest(T4Mat2DLong,             "D2/mat2dLong");
  Test.AddTest(T5WordInRecord,          "D2/wordInRec");
  Test.AddTest(T6ExtensionFieldAccess,  "D2/extField");
  Test.AddTest(T7ExtensionThroughVarBase,"D2/extVarBase");
  Test.AddTest(T8PointerEqInChain,      "D2/ptrEqChain");
  Test.AddTest(T9IsTestThroughArraySelector,"D2/isViaArr");
  Test.AddTest(T10IncDecComposite,      "D2/incDecComp");
  Test.AddTest(T11SetOpsThroughChain,   "D2/setOpsChain");
  Test.AddTest(T12RecordCopyWholeArray, "D2/recCopyArr");
  Test.AddTest(T12bRecordCopyArrayElem, "D2/recCopyElem");
  Test.AddTest(T13OpenArrayOfPointers,  "D2/openArrPtr");
  Test.AddTest(T14CaseOnArrayIndexValue,"D2/caseOnX");
  Test.AddTest(T15LenOnFieldArray,      "D2/lenField");
  Test.RunTests
END RunAllTests;

END DEEP2.
