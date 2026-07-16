MODULE TDEF;
(* Unit tests for Def — Oberon port of tests/test_def.c.  Tests assert that
   DefWrite produces the expected text patterns and that DefRead round-trips
   symbols correctly. *)

IMPORT Test, Files, Strings, Syms, Def, StrTab;

VAR
  TmpDef: ARRAY 8 OF CHAR;
  Txt: ARRAY 4096 OF CHAR;
  TxtLen: INTEGER;

(* ---- helpers ---- *)

PROCEDURE slurp;
  VAR f: Files.File; n: WORD; size: LONGINT; i: INTEGER;
BEGIN
  IF Files.Reset(f, TmpDef) THEN
    size := Files.Size(f);
    IF size > LONGINT(LEN(Txt) - 1) THEN size := LONGINT(LEN(Txt) - 1) END;
    TxtLen := INTEGER(size);
    Files.Seek(f, 0);
    n := Files.BlockRead(f, Txt, WORD(size));
    Txt[TxtLen] := 0X;
    Files.Close(f)
  ELSE TxtLen := 0; Txt[0] := 0X END
END slurp;

PROCEDURE doWrite(modName: ARRAY OF CHAR);
  VAR f: Files.File; ok: BOOLEAN;
BEGIN
  ok := Files.ReWrite(f, TmpDef);
  Def.DefWrite(f, modName);
  Files.Close(f);
  slurp
END doWrite;

PROCEDURE doRead(alias: ARRAY OF CHAR);
  VAR f: Files.File;
BEGIN
  IF Files.Reset(f, TmpDef) THEN
    Def.DefRead(f, alias);
    Files.Close(f)
  END
END doRead;

PROCEDURE cleanup;
  VAR ok: BOOLEAN;
BEGIN Syms.SymsFree(); ok := Files.Delete(TmpDef) END cleanup;

PROCEDURE has(pat: ARRAY OF CHAR): BOOLEAN;
  VAR p: WORD;
BEGIN p := 0; RETURN Strings.Pos(pat, Txt, p) END has;

(* posOf: like Strings.Pos, but folds the "not found" case down to -1 so
   callers can keep using ordinary signed comparisons (pConst < pType etc.)
   on the result. *)
PROCEDURE posOf(pat: ARRAY OF CHAR): INTEGER;
  VAR p: WORD;
BEGIN
  p := 0;
  IF Strings.Pos(pat, Txt, p) THEN RETURN INTEGER(p) ELSE RETURN -1 END
END posOf;

(* ---- module line ---- *)

PROCEDURE TModuleLine*;
BEGIN
  Syms.SymInit();
  doWrite("Foo");
  Test.AssertTrue(has("MODULE Foo"), "module/MODULE Foo present");
  cleanup
END TModuleLine;

(* ---- CONST line ---- *)

PROCEDURE TConstWrite*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("bar", Syms.KConst);
  s^.type := Syms.TypeInteger;
  s^.val := 42;
  s^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue(has("CONST Foo_bar 42"), "const/CONST line");
  cleanup
END TConstWrite;

(* ---- VAR line ---- *)

PROCEDURE TVarWrite*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("x", Syms.KVar);
  s^.type := Syms.TypeInteger;
  s^.level := 0;
  s^.adr := 4;
  s^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue(has("VAR Foo_x INTEGER 1 4"), "var/VAR line seg=1");
  cleanup
END TVarWrite;

(* ---- TYPE line ---- *)

PROCEDURE TTypeWrite*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("T", Syms.KType);
  s^.type := Syms.TypeNewRecord(NIL);
  s^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue(has("TYPE Foo_T"), "type/TYPE line");
  cleanup
END TTypeWrite;

(* ---- PROC line ---- *)

PROCEDURE TProcWrite*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("Calc", Syms.KProc);
  s^.type := Syms.TypeNewProc(Syms.TypeNotype);
  s^.codeOfs := 16;
  s^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue(has("PROC Foo_Calc"), "proc/PROC line");
  cleanup
END TProcWrite;

(* ---- non-exported excluded ---- *)

PROCEDURE TNonExported*;
  VAR p, q: Syms.Symbol;
BEGIN
  Syms.SymInit();
  p := Syms.SymNew("priv", Syms.KConst);
  p^.type := Syms.TypeInteger; p^.val := 99; p^.exported := FALSE;
  q := Syms.SymNew("pub", Syms.KConst);
  q^.type := Syms.TypeInteger; q^.val := 1;  q^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue (has("pub"),  "non-export/exported present");
  Test.AssertFalse(has("priv"), "non-export/non-exported absent");
  cleanup
END TNonExported;

(* ---- round-trip all ---- *)

PROCEDURE TRoundtripAll*;
  VAR s: Syms.Symbol; nameBuf: ARRAY Syms.NameLen OF CHAR;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("bar", Syms.KConst);
  s^.type := Syms.TypeInteger; s^.val := 42; s^.exported := TRUE;
  s := Syms.SymNew("x", Syms.KVar);
  s^.type := Syms.TypeInteger; s^.level := 0; s^.adr := 8; s^.exported := TRUE;
  s := Syms.SymNew("T", Syms.KType);
  s^.type := Syms.TypeNewRecord(NIL); s^.exported := TRUE;
  s := Syms.SymNew("Calc", Syms.KProc);
  s^.type := Syms.TypeNewProc(Syms.TypeNotype);
  s^.codeOfs := 16; s^.exported := TRUE;
  doWrite("Foo");

  Syms.SymsFree(); Syms.SymInit();
  doRead("F");

  s := Syms.SymFindLocalId(StrTab.Intern("F.bar"));
  Test.AssertNotNil(s, "rt/bar found");
  IF s # NIL THEN
    Test.AssertInt(Syms.KConst, s^.kind, "rt/bar kind");
    Test.AssertLong(42, s^.val, "rt/bar val")
  END;

  s := Syms.SymFindLocalId(StrTab.Intern("F.x"));
  Test.AssertNotNil(s, "rt/x found");
  IF s # NIL THEN
    Test.AssertInt(Syms.KVar, s^.kind, "rt/x kind");
    Test.AssertLong(8, s^.adr, "rt/x adr");
    Test.AssertInt(0, INTEGER(s^.level), "rt/x level")
  END;

  s := Syms.SymFindLocalId(StrTab.Intern("F.T"));
  Test.AssertNotNil(s, "rt/T found");
  IF s # NIL THEN Test.AssertInt(Syms.KType, s^.kind, "rt/T kind") END;

  s := Syms.SymFindLocalId(StrTab.Intern("F.Calc"));
  Test.AssertNotNil(s, "rt/Calc found");
  IF s # NIL THEN
    Test.AssertInt(Syms.KProc, s^.kind, "rt/Calc kind");
    StrTab.Get(s^.nameId, nameBuf);
    Test.AssertStr("F.Calc", nameBuf, "rt/Calc nameId")
  END;
  cleanup
END TRoundtripAll;

(* ---- empty module ---- *)

PROCEDURE TEmptyModule*;
BEGIN
  Syms.SymInit();
  doWrite("Empty");
  Test.AssertTrue(has("MODULE Empty"), "empty/MODULE line");

  Syms.SymsFree(); Syms.SymInit();
  doRead("E");
  Test.AssertNil(Syms.SymFindLocalId(StrTab.Intern("nothing")), "empty/no symbols");
  cleanup
END TEmptyModule;

(* ---- multiple consts ---- *)

PROCEDURE TMultipleConsts*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("A", Syms.KConst);
  s^.type := Syms.TypeInteger; s^.val := 1; s^.exported := TRUE;
  s := Syms.SymNew("B", Syms.KConst);
  s^.type := Syms.TypeInteger; s^.val := 2; s^.exported := TRUE;
  s := Syms.SymNew("C", Syms.KConst);
  s^.type := Syms.TypeInteger; s^.val := 3; s^.exported := TRUE;
  doWrite("M");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");

  s := Syms.SymFindLocalId(StrTab.Intern("M.A"));
  Test.AssertNotNil(s, "multi/A found");
  IF s # NIL THEN Test.AssertLong(1, s^.val, "multi/A=1") END;

  s := Syms.SymFindLocalId(StrTab.Intern("M.B"));
  Test.AssertNotNil(s, "multi/B found");
  IF s # NIL THEN Test.AssertLong(2, s^.val, "multi/B=2") END;

  s := Syms.SymFindLocalId(StrTab.Intern("M.C"));
  Test.AssertNotNil(s, "multi/C found");
  IF s # NIL THEN Test.AssertLong(3, s^.val, "multi/C=3") END;
  cleanup
END TMultipleConsts;

(* ---- VAR with level != 0 → SEG_CODE ---- *)

PROCEDURE TVarCodeSeg*;
  VAR s: Syms.Symbol;
BEGIN
  Syms.SymInit();
  Syms.SymOpenScope();
  s := Syms.SymNew("local_var", Syms.KVar);
  s^.type := Syms.TypeInteger;
  s^.adr := -2;
  s^.exported := TRUE;
  doWrite("Foo");
  Test.AssertTrue(has("VAR Foo_local_var INTEGER 0 -2"),
                  "var-code-seg/seg=0");
  cleanup
END TVarCodeSeg;

(* ---- record with fields ---- *)

PROCEDURE TRecordWithFields*;
  VAR s: Syms.Symbol; rec: Syms.TypeDesc; fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  rec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(rec, "x", Syms.TypeInteger);
  fld^.exported := TRUE;
  fld := Syms.TypeAddField(rec, "y", Syms.TypeInteger);
  fld^.exported := TRUE;
  s := Syms.SymNew("Point", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  doWrite("M");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");

  s := Syms.SymFindLocalId(StrTab.Intern("M.Point"));
  Test.AssertNotNil(s, "rec-fields/Point found");
  IF s # NIL THEN
    Test.AssertInt(Syms.TFRecord, s^.type^.form, "rec-fields/Point is record");
    Test.AssertLong(4, s^.type^.size, "rec-fields/size=4");
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("x"));
    Test.AssertNotNil(fld, "rec-fields/x found");
    IF fld # NIL THEN
      Test.AssertLong(0, fld^.offset, "rec-fields/x offset=0");
      Test.AssertTrue(fld^.type = Syms.TypeInteger,
                      "rec-fields/x type=INTEGER")
    END;
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("y"));
    Test.AssertNotNil(fld, "rec-fields/y found");
    IF fld # NIL THEN
      Test.AssertLong(2, fld^.offset, "rec-fields/y offset=2")
    END
  END;
  cleanup
END TRecordWithFields;

(* ---- record extension ---- *)

PROCEDURE TRecordExtension*;
  VAR s: Syms.Symbol; base, ext: Syms.TypeDesc; fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  base := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(base, "x", Syms.TypeInteger);
  fld^.exported := TRUE;
  s := Syms.SymNew("Point", Syms.KType);
  s^.type := base; s^.exported := TRUE;

  ext := Syms.TypeNewRecord(base);
  fld := Syms.TypeAddField(ext, "z", Syms.TypeInteger);
  fld^.exported := TRUE;
  s := Syms.SymNew("Point3D", Syms.KType);
  s^.type := ext; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("BASE M_Point"), "rec-ext/BASE line emitted");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Point3D"));
  Test.AssertNotNil(s, "rec-ext/Point3D found");
  IF s # NIL THEN
    Test.AssertInt(Syms.TFRecord, s^.type^.form, "rec-ext/is record");
    Test.AssertNotNil(s^.type^.base, "rec-ext/has base");
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("z"));
    Test.AssertNotNil(fld, "rec-ext/z found")
  END;
  cleanup
END TRecordExtension;

(* ---- pointer to record field ---- *)

PROCEDURE TPointerToRecord*;
  VAR s: Syms.Symbol; rec, ptr: Syms.TypeDesc; fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  rec := Syms.TypeNewRecord(NIL);
  ptr := Syms.TypeNewPointer(rec);
  fld := Syms.TypeAddField(rec, "val",  Syms.TypeInteger);
  fld^.exported := TRUE;
  fld := Syms.TypeAddField(rec, "next", ptr);
  fld^.exported := TRUE;
  s := Syms.SymNew("Node", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("POINTER Node"),
                  "ptr-rec/POINTER Node emitted");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Node"));
  Test.AssertNotNil(s, "ptr-rec/Node found");
  IF s # NIL THEN
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("next"));
    Test.AssertNotNil(fld, "ptr-rec/next found");
    IF fld # NIL THEN
      Test.AssertInt(Syms.TFPointer, fld^.type^.form,
                     "ptr-rec/next is POINTER")
    END
  END;
  cleanup
END TPointerToRecord;

(* ---- float/set field types ---- *)

PROCEDURE TFloatSetFields*;
  VAR s: Syms.Symbol; rec: Syms.TypeDesc; fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  rec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(rec, "r",  Syms.TypeReal);     fld^.exported := TRUE;
  fld := Syms.TypeAddField(rec, "lr", Syms.TypeLongreal); fld^.exported := TRUE;
  fld := Syms.TypeAddField(rec, "st", Syms.TypeSet);      fld^.exported := TRUE;
  s := Syms.SymNew("Floats", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("FIELD r REAL"),     "float-set/REAL emitted");
  Test.AssertTrue(has("FIELD lr LONGREAL"), "float-set/LONGREAL emitted");
  Test.AssertTrue(has("FIELD st SET"),     "float-set/SET emitted");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Floats"));
  Test.AssertNotNil(s, "float-set/Floats found");
  IF s # NIL THEN
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("r"));
    Test.AssertNotNil(fld, "float-set/r found");
    IF fld # NIL THEN
      Test.AssertInt(Syms.TFReal, fld^.type^.form, "float-set/r=REAL")
    END;
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("lr"));
    IF fld # NIL THEN
      Test.AssertInt(Syms.TFLongreal, fld^.type^.form,
                     "float-set/lr=LONGREAL")
    END;
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("st"));
    IF fld # NIL THEN
      Test.AssertInt(Syms.TFSet, fld^.type^.form, "float-set/st=SET")
    END
  END;
  cleanup
END TFloatSetFields;

(* ---- PROC with REAL param + LONGREAL return ---- *)

PROCEDURE TProcFloatParams*;
  VAR s: Syms.Symbol; pt: Syms.TypeDesc; p: Syms.Symbol;
BEGIN
  Syms.SymInit();
  pt := Syms.TypeNewProc(Syms.TypeLongreal);
  p := Syms.TypeAddParam(pt, "x", Syms.TypeReal, FALSE);
  pt^.isFar := TRUE;
  s := Syms.SymNew("Calc", Syms.KProc);
  s^.type := pt; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("PROC M_Calc FAR LONGREAL"),
                  "proc-float/LONGREAL rettype");
  Test.AssertTrue(has("PARAM x REAL"), "proc-float/REAL param");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Calc"));
  Test.AssertNotNil(s, "proc-float/Calc found");
  IF s # NIL THEN
    Test.AssertInt(Syms.TFLongreal, s^.type^.retType^.form,
                   "proc-float/rettype=LONGREAL");
    p := s^.type^.params;
    Test.AssertNotNil(p, "proc-float/has params");
    IF p # NIL THEN
      Test.AssertInt(Syms.TFReal, p^.type^.form,
                     "proc-float/param type=REAL")
    END
  END;
  cleanup
END TProcFloatParams;

(* ---- write order ---- *)

PROCEDURE TWriteOrder*;
  VAR s: Syms.Symbol; rec: Syms.TypeDesc; fld: Syms.Symbol;
      pConst, pType, pVar, pProc: INTEGER;
BEGIN
  Syms.SymInit();
  s := Syms.SymNew("K", Syms.KConst);
  s^.type := Syms.TypeInteger; s^.val := 1; s^.exported := TRUE;
  rec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(rec, "x", Syms.TypeInteger);
  fld^.exported := TRUE;
  s := Syms.SymNew("T", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  s := Syms.SymNew("v", Syms.KVar);
  s^.type := Syms.TypeInteger; s^.level := 0; s^.adr := 2;
  s^.exported := TRUE;
  s := Syms.SymNew("P", Syms.KProc);
  s^.type := Syms.TypeNewProc(Syms.TypeNotype);
  s^.exported := TRUE;
  doWrite("M");
  pConst := posOf("CONST");
  pType  := posOf("TYPE");
  pVar   := posOf("VAR");
  pProc  := posOf("PROC");
  Test.AssertTrue((pConst >= 0) & (pType >= 0) & (pVar >= 0) & (pProc >= 0),
                  "order/all present");
  Test.AssertTrue(pConst < pType,  "order/CONST before TYPE");
  Test.AssertTrue(pType  < pVar,   "order/TYPE before VAR");
  Test.AssertTrue(pVar   < pProc,  "order/VAR before PROC");
  cleanup
END TWriteOrder;

(* ---- REAL/LONGREAL are primitive base types ---- *)

PROCEDURE TRealBaseTypes*;
  VAR s: Syms.Symbol; rec: Syms.TypeDesc; fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  rec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(rec, "a", Syms.TypeReal);     fld^.exported := TRUE;
  fld := Syms.TypeAddField(rec, "b", Syms.TypeLongreal); fld^.exported := TRUE;
  s := Syms.SymNew("R", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  doWrite("M");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.R"));
  Test.AssertNotNil(s, "real-base/R found");
  IF s # NIL THEN
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("a"));
    Test.AssertTrue((fld # NIL) & (fld^.type = Syms.TypeReal),
                    "real-base/a resolves to TypeReal");
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("b"));
    Test.AssertTrue((fld # NIL) & (fld^.type = Syms.TypeLongreal),
                    "real-base/b resolves to TypeLongreal")
  END;
  cleanup
END TRealBaseTypes;

(* ---- typed VAR param round-trip ---- *)

PROCEDURE TTypedVarParam*;
  VAR s: Syms.Symbol; pt: Syms.TypeDesc; p: Syms.Symbol;
BEGIN
  Syms.SymInit();
  pt := Syms.TypeNewProc(Syms.TypeNotype);
  p := Syms.TypeAddParam(pt, "buf", Syms.TypeInteger, TRUE);
  pt^.isFar := TRUE;
  s := Syms.SymNew("ReadInt", Syms.KProc);
  s^.type := pt; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue (has("PARAM VAR buf INTEGER"),
                   "typed-varparam/write PARAM VAR");
  Test.AssertFalse(has("TYPELESSVAR"),
                   "typed-varparam/no TYPELESSVAR");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.ReadInt"));
  Test.AssertNotNil(s, "typed-varparam/found");
  IF s # NIL THEN
    p := s^.type^.params;
    Test.AssertNotNil(p, "typed-varparam/param exists");
    IF p # NIL THEN
      Test.AssertInt(Syms.KVarParam, p^.kind, "typed-varparam/kind");
      Test.AssertFalse(p^.typeless, "typed-varparam/typeless=FALSE");
      Test.AssertInt(Syms.TFInteger, p^.type^.form,
                     "typed-varparam/type=INTEGER")
    END
  END;
  cleanup
END TTypedVarParam;

(* ---- FORWARD proc in .def ---- *)

PROCEDURE TForwardProc*;
  VAR s: Syms.Symbol; pt: Syms.TypeDesc;
BEGIN
  Syms.SymInit();
  pt := Syms.TypeNewProc(Syms.TypeNotype);
  pt^.isFar := TRUE;
  s := Syms.SymNew("DoIt", Syms.KProc);
  s^.type := pt;
  s^.fwdDecl := TRUE;
  s^.exported := TRUE;
  doWrite("Mod");
  (* exported flag set, fwdDecl flag does not exclude from .def *)
  Test.AssertTrue(has("PROC Mod_DoIt"), "fwd/PROC line emitted");
  cleanup
END TForwardProc;

(* ---- FORWARD proc round-trip ---- *)

PROCEDURE TForwardProcRT*;
  VAR s: Syms.Symbol; pt: Syms.TypeDesc;
BEGIN
  Syms.SymInit();
  pt := Syms.TypeNewProc(Syms.TypeInteger);
  Syms.TypeAddParam(pt, "n", Syms.TypeInteger, FALSE);
  pt^.isFar := TRUE;
  Syms.TypeCalcArgSize(pt);
  s := Syms.SymNew("Add", Syms.KProc);
  s^.type := pt;
  s^.exported := TRUE;
  doWrite("Mod");

  Syms.SymsFree(); Syms.SymInit();
  doRead("Mod");
  s := Syms.SymFindLocalId(StrTab.Intern("Mod.Add"));
  Test.AssertTrue(s # NIL, "fwd-rt/Add found");
  IF s # NIL THEN
    Test.AssertInt(Syms.KProc, s^.kind, "fwd-rt/kind=PROC");
    Test.AssertTrue(s^.type^.isFar, "fwd-rt/is_far");
    Test.AssertInt(Syms.TFInteger, s^.type^.retType^.form, "fwd-rt/rettype=INTEGER");
    Test.AssertInt(1, s^.type^.nParams, "fwd-rt/n_params=1");
    IF s^.type^.params # NIL THEN
      Test.AssertInt(Syms.TFInteger, s^.type^.params^.type^.form,
                     "fwd-rt/param-type=INTEGER")
    END
  END;
  cleanup
END TForwardProcRT;

(* ---- imported type as POINTER base ---- *)

PROCEDURE TImportedTypePtr*;
  VAR bRec, ptrB, mRec: Syms.TypeDesc;
      bSym, s, fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  bRec := Syms.TypeNewRecord(NIL);
  bSym := Syms.SymNew("B.BRec", Syms.KType);
  bSym^.type := bRec; bSym^.exported := TRUE;

  ptrB := Syms.TypeNewPointer(bRec);
  mRec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(mRec, "p", ptrB);
  fld^.exported := TRUE;
  s := Syms.SymNew("Container", Syms.KType);
  s^.type := mRec; s^.exported := TRUE;
  doWrite("M");

  Syms.SymsFree(); Syms.SymInit();
  bRec := Syms.TypeNewRecord(NIL);
  bSym := Syms.SymNew("B.BRec", Syms.KType);
  bSym^.type := bRec; bSym^.exported := TRUE;

  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Container"));
  Test.AssertTrue(s # NIL, "imp-ptr/Container found");
  IF s # NIL THEN
    fld := Syms.SymFindFieldId(s^.type, StrTab.Intern("p"));
    Test.AssertTrue(fld # NIL, "imp-ptr/field p found");
    IF fld # NIL THEN
      Test.AssertInt(Syms.TFPointer, fld^.type^.form, "imp-ptr/p is POINTER");
      Test.AssertTrue(fld^.type^.base = bRec, "imp-ptr/p base=B.BRec")
    END
  END;
  cleanup
END TImportedTypePtr;

(* ---- cross-module record extension ---- *)

PROCEDURE TCrossModuleExt*;
  VAR base, ext: Syms.TypeDesc; baseSym, extSym, fld: Syms.Symbol;
BEGIN
  Syms.SymInit();
  base := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(base, "weight", Syms.TypeInteger);
  fld^.exported := TRUE;
  baseSym := Syms.SymNew("B.Animal", Syms.KType);
  baseSym^.type := base; baseSym^.exported := TRUE;

  ext := Syms.TypeNewRecord(base);
  fld := Syms.TypeAddField(ext, "legs", Syms.TypeInteger);
  fld^.exported := TRUE;
  extSym := Syms.SymNew("Dog", Syms.KType);
  extSym^.type := ext; extSym^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("BASE"), "cross-ext/BASE emitted");

  Syms.SymsFree(); Syms.SymInit();
  base := Syms.TypeNewRecord(NIL);
  baseSym := Syms.SymNew("B.Animal", Syms.KType);
  baseSym^.type := base; baseSym^.exported := TRUE;
  doRead("M");
  extSym := Syms.SymFindLocalId(StrTab.Intern("M.Dog"));
  Test.AssertNotNil(extSym, "cross-ext/Dog found");
  IF extSym # NIL THEN
    Test.AssertInt(Syms.TFRecord, extSym^.type^.form,
                   "cross-ext/Dog is record");
    Test.AssertNotNil(extSym^.type^.base, "cross-ext/Dog has base");
    fld := Syms.SymFindFieldId(extSym^.type, StrTab.Intern("legs"));
    Test.AssertNotNil(fld, "cross-ext/legs found")
  END;
  cleanup
END TCrossModuleExt;

(* ---- typeless VAR param round-trip ---- *)

PROCEDURE TTypelessVarParam*;
  VAR s: Syms.Symbol; pt: Syms.TypeDesc; p: Syms.Symbol;
BEGIN
  Syms.SymInit();
  pt := Syms.TypeNewProc(Syms.TypeAddress);
  p := Syms.TypeAddParam(pt, "v", Syms.TypeAddress, TRUE);
  p^.typeless := TRUE;
  pt^.isInline := TRUE;
  s := Syms.SymNew("ADR", Syms.KProc);
  s^.type := pt; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue (has("PARAM TYPELESSVAR v"),
                   "typeless/write TYPELESSVAR");
  Test.AssertFalse(has("PARAM VAR v"),
                   "typeless/no PARAM VAR");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.ADR"));
  Test.AssertNotNil(s, "typeless/found");
  IF s # NIL THEN
    p := s^.type^.params;
    Test.AssertNotNil(p, "typeless/param exists");
    IF p # NIL THEN
      Test.AssertInt(Syms.KVarParam, p^.kind, "typeless/kind");
      Test.AssertTrue(p^.typeless, "typeless/typeless=TRUE");
      Test.AssertInt(Syms.TFAddress, p^.type^.form,
                     "typeless/type=ADDRESS")
    END
  END;
  cleanup
END TTypelessVarParam;

(* ---- VAR param of POINTER TO ARRAY (anonymous array base) round-trip ----
   Regression for PTR.MD: WriteType's POINTER branch used to find no symbol
   name for the array base (an anonymous ARRAY N OF T, never itself given a
   TYPE alias) and fell back to writing "POINTER VOID", losing the array
   shape across module boundaries.  Every VAR param whose formal type is a
   bare POINTER TO ARRAY hit this — see the TRec.Fill/TUse repro in PTR.MD. *)
PROCEDURE TVarParamPtrArray*;
  VAR s: Syms.Symbol; rec, arr, ptr, pt: Syms.TypeDesc; fld, p: Syms.Symbol;
BEGIN
  Syms.SymInit();
  rec := Syms.TypeNewRecord(NIL);
  fld := Syms.TypeAddField(rec, "a", Syms.TypeInteger);
  fld^.exported := TRUE;
  s := Syms.SymNew("Item", Syms.KType);
  s^.type := rec; s^.exported := TRUE;
  arr := Syms.TypeNewArray(rec, 10);
  ptr := Syms.TypeNewPointer(arr);
  pt := Syms.TypeNewProc(Syms.TypeNotype);
  pt^.isFar := TRUE;
  p := Syms.TypeAddParam(pt, "arr", ptr, TRUE);
  s := Syms.SymNew("Fill", Syms.KProc);
  s^.type := pt; s^.exported := TRUE;
  doWrite("M");
  Test.AssertTrue(has("PARAM VAR arr POINTER ARRAY 10 OF Item"),
                  "varparam-ptrarr/write PARAM VAR ... POINTER ARRAY 10 OF Item");
  Test.AssertFalse(has("POINTER VOID"),
                    "varparam-ptrarr/no POINTER VOID fallback");

  Syms.SymsFree(); Syms.SymInit();
  doRead("M");
  s := Syms.SymFindLocalId(StrTab.Intern("M.Fill"));
  Test.AssertNotNil(s, "varparam-ptrarr/Fill found");
  IF s # NIL THEN
    p := s^.type^.params;
    Test.AssertNotNil(p, "varparam-ptrarr/param exists");
    IF p # NIL THEN
      Test.AssertInt(Syms.KVarParam, p^.kind, "varparam-ptrarr/kind=VarParam");
      Test.AssertInt(Syms.TFPointer, p^.type^.form,
                     "varparam-ptrarr/type=POINTER");
      IF p^.type^.form = Syms.TFPointer THEN
        Test.AssertNotNil(p^.type^.base, "varparam-ptrarr/base exists");
        IF p^.type^.base # NIL THEN
          Test.AssertInt(Syms.TFArray, p^.type^.base^.form,
                         "varparam-ptrarr/base=ARRAY");
          Test.AssertInt(10, INTEGER(p^.type^.base^.len),
                         "varparam-ptrarr/base len=10")
        END
      END
    END
  END;
  cleanup
END TVarParamPtrArray;

PROCEDURE RunAllTests*;
BEGIN
  TmpDef := "_t.DEF";
  Test.AddTest(TModuleLine,        "Def/module-line");
  Test.AddTest(TConstWrite,        "Def/const-write");
  Test.AddTest(TVarWrite,          "Def/var-write");
  Test.AddTest(TTypeWrite,         "Def/type-write");
  Test.AddTest(TProcWrite,         "Def/proc-write");
  Test.AddTest(TNonExported,       "Def/non-exported-excluded");
  Test.AddTest(TRoundtripAll,      "Def/roundtrip-all");
  Test.AddTest(TEmptyModule,       "Def/empty-module");
  Test.AddTest(TMultipleConsts,    "Def/multiple-consts");
  Test.AddTest(TVarCodeSeg,        "Def/var-code-seg");
  Test.AddTest(TRecordWithFields,  "Def/record-with-fields");
  Test.AddTest(TRecordExtension,   "Def/record-extension");
  Test.AddTest(TPointerToRecord,   "Def/pointer-to-record");
  Test.AddTest(TFloatSetFields,    "Def/float-set-fields");
  Test.AddTest(TProcFloatParams,   "Def/proc-float-params");
  Test.AddTest(TWriteOrder,        "Def/write-order");
  Test.AddTest(TRealBaseTypes,     "Def/real-base-types");
  Test.AddTest(TTypedVarParam,     "Def/typed-var-param");
  Test.AddTest(TTypelessVarParam,  "Def/typeless-var-param");
  Test.AddTest(TForwardProc,       "Def/forward-proc");
  Test.AddTest(TForwardProcRT,     "Def/forward-proc-rt");
  Test.AddTest(TImportedTypePtr,   "Def/imported-type-ptr");
  Test.AddTest(TCrossModuleExt,    "Def/cross-module-ext");
  Test.AddTest(TVarParamPtrArray,  "Def/var-param-ptr-array");
  Test.RunTests
END RunAllTests;

END TDEF.
