MODULE TSYMS;
(* Unit tests for Syms — Oberon port of tests/test_symbols.c. *)

IMPORT Test, Syms;

(* ---- predeclared universe symbols ---- *)

PROCEDURE checkSysProc(name: ARRAY OF CHAR);
  VAR t: Syms.Symbol;
BEGIN
  t := Syms.SymFind(name);
  Test.AssertNotNil(t, "pre/sysproc lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KSysProc, t^.kind, "pre/sysproc kind")
  END
END checkSysProc;

PROCEDURE TPredeclared*;
  VAR t: Syms.Symbol;
BEGIN
  Syms.SymInit();

  t := Syms.SymFind("INTEGER");
  Test.AssertNotNil(t, "pre/INTEGER lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KType,      t^.kind,        "pre/INTEGER kind");
    Test.AssertInt(Syms.TFInteger,  t^.type^.form,  "pre/INTEGER form");
    Test.AssertLong(Syms.SzInteger, t^.type^.size,  "pre/INTEGER size")
  END;

  t := Syms.SymFind("BOOLEAN");
  Test.AssertNotNil(t, "pre/BOOLEAN lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KType,     t^.kind,       "pre/BOOLEAN kind");
    Test.AssertInt(Syms.TFBoolean, t^.type^.form, "pre/BOOLEAN form")
  END;

  t := Syms.SymFind("CHAR");
  Test.AssertNotNil(t, "pre/CHAR lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KType,  t^.kind,       "pre/CHAR kind");
    Test.AssertInt(Syms.TFChar, t^.type^.form, "pre/CHAR form")
  END;

  t := Syms.SymFind("BYTE");
  Test.AssertNotNil(t, "pre/BYTE lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KType,  t^.kind,       "pre/BYTE kind");
    Test.AssertInt(Syms.TFByte, t^.type^.form, "pre/BYTE form")
  END;

  t := Syms.SymFind("SET");
  Test.AssertNotNil(t, "pre/SET lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KType, t^.kind,       "pre/SET kind");
    Test.AssertInt(Syms.TFSet, t^.type^.form, "pre/SET form")
  END;

  (* predeclared constants *)
  t := Syms.SymFind("TRUE");
  Test.AssertNotNil(t, "pre/TRUE lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KConst, t^.kind, "pre/TRUE kind");
    Test.AssertLong(1, t^.val, "pre/TRUE val")
  END;

  t := Syms.SymFind("FALSE");
  Test.AssertNotNil(t, "pre/FALSE lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KConst, t^.kind, "pre/FALSE kind");
    Test.AssertLong(0, t^.val, "pre/FALSE val")
  END;

  t := Syms.SymFind("NIL");
  Test.AssertNotNil(t, "pre/NIL lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KConst, t^.kind, "pre/NIL kind");
    Test.AssertLong(0, t^.val, "pre/NIL val")
  END;

  (* predeclared system procedures *)
  checkSysProc("NEW"); checkSysProc("INC"); checkSysProc("DEC");
  checkSysProc("LEN"); checkSysProc("ODD"); checkSysProc("ABS");
  checkSysProc("ASSERT"); checkSysProc("ORD"); checkSysProc("CHR");
  checkSysProc("FLOOR");

  (* SYSTEM is implicitly imported *)
  t := Syms.SymFind("SYSTEM");
  Test.AssertNotNil(t, "pre/SYSTEM lookup");
  IF t # NIL THEN
    Test.AssertInt(Syms.KImport, t^.kind, "pre/SYSTEM kind")
  END;

  Test.AssertLong(4, Syms.SzPointer, "pre/SzPointer = 4")
END TPredeclared;

(* ---- scope open / close / find ---- *)

PROCEDURE TScopes*;
  VAR outer, inner: Syms.Symbol;
BEGIN
  Syms.SymInit();

  outer := Syms.SymNew("x", Syms.KVar);
  outer^.type := Syms.TypeInteger;
  Test.AssertTrue(Syms.SymFind("x") = outer, "scope/find outer");

  Syms.SymOpenScope();
  inner := Syms.SymNew("x", Syms.KVar);
  inner^.type := Syms.TypeInteger;
  Test.AssertTrue(Syms.SymFind("x") = inner,      "scope/shadow");
  Test.AssertTrue(Syms.SymFindLocal("x") = inner, "scope/find local inner");
  Test.AssertNil(Syms.SymFind("y"), "scope/find miss");

  Syms.SymCloseScope();
  Test.AssertTrue(Syms.SymFind("x") = outer,      "scope/close restore");
  Test.AssertTrue(Syms.SymFindLocal("x") = outer, "scope/find local outer")
END TScopes;

(* ---- AllocLocal ---- *)

PROCEDURE TAllocLocal*;
  VAR v1, v2, b, v3: Syms.Symbol;
  VAR rem: INTEGER;
BEGIN
  Syms.SymInit();
  Syms.SymOpenScope();

  v1 := Syms.SymNew("v1", Syms.KVar);
  v1^.type := Syms.TypeInteger;
  Syms.SymAllocLocal(v1);
  Test.AssertLong(-2, v1^.adr, "local/first INT adr");
  Test.AssertInt(2, Syms.SymLocalSize(), "local/first INT frame size");

  v2 := Syms.SymNew("v2", Syms.KVar);
  v2^.type := Syms.TypeInteger;
  Syms.SymAllocLocal(v2);
  Test.AssertLong(-4, v2^.adr, "local/second INT adr");
  Test.AssertInt(4, Syms.SymLocalSize(), "local/second INT frame size");

  Syms.SymCloseScope();
  Syms.SymOpenScope();

  b := Syms.SymNew("b", Syms.KVar);
  b^.type := Syms.TypeBoolean;
  Syms.SymAllocLocal(b);
  Test.AssertLong(-2, b^.adr, "local/BOOLEAN adr");
  Test.AssertInt(2, Syms.SymLocalSize(), "local/BOOLEAN aligned to word");

  v3 := Syms.SymNew("v3", Syms.KVar);
  v3^.type := Syms.TypeInteger;
  Syms.SymAllocLocal(v3);
  rem := INTEGER(v3^.adr) MOD 2;
  IF rem < 0 THEN rem := rem + 2 END;
  Test.AssertInt(0, rem, "local/after BOOLEAN word-aligned")
END TAllocLocal;

(* ---- CalcArgSize (Pascal calling convention) ---- *)

PROCEDURE TCalcArgSize*;
  VAR pt, pt2: Syms.TypeDesc; a, b, va: Syms.Symbol;
BEGIN
  Syms.SymInit();

  pt := Syms.TypeNewProc(Syms.TypeNotype);
  a := Syms.TypeAddParam(pt, "a", Syms.TypeInteger, FALSE);
  b := Syms.TypeAddParam(pt, "b", Syms.TypeInteger, FALSE);
  Syms.TypeCalcArgSize(pt);
  Test.AssertLong(4, pt^.argSize, "argsize/two INT total");
  Test.AssertLong(6, a^.adr, "argsize/a at 6");
  Test.AssertLong(4, b^.adr, "argsize/b at 4");

  pt2 := Syms.TypeNewProc(Syms.TypeNotype);
  va := Syms.TypeAddParam(pt2, "a", Syms.TypeInteger, TRUE);
  Syms.TypeCalcArgSize(pt2);
  Test.AssertLong(4, pt2^.argSize, "argsize/VAR param total");
  Test.AssertLong(4, va^.adr, "argsize/VAR param at 4");
  Test.AssertInt(Syms.KVarParam, va^.kind, "argsize/VAR param kind")
END TCalcArgSize;

(* ---- RECORD fields ---- *)

PROCEDURE TRecords*;
  VAR rec, ext: Syms.TypeDesc; f1, f2, f3: Syms.Symbol;
BEGIN
  Syms.SymInit();

  rec := Syms.TypeNewRecord(NIL);
  Test.AssertLong(0, rec^.size, "rec/root initial size");

  f1 := Syms.TypeAddField(rec, "x", Syms.TypeInteger);
  Test.AssertLong(0, f1^.offset, "rec/first field offset 0");
  Test.AssertLong(Syms.SzInteger, rec^.size, "rec/size after first");

  f2 := Syms.TypeAddField(rec, "y", Syms.TypeInteger);
  Test.AssertLong(Syms.SzInteger, f2^.offset, "rec/second field offset");

  Test.AssertTrue(Syms.SymFindField(rec, "x") = f1, "rec/find x");
  Test.AssertTrue(Syms.SymFindField(rec, "y") = f2, "rec/find y");
  Test.AssertNil(Syms.SymFindField(rec, "z"), "rec/find miss");

  ext := Syms.TypeNewRecord(rec);
  Test.AssertTrue(ext^.base = rec, "rec/ext base");
  Test.AssertTrue(Syms.SymFindField(ext, "x") = f1, "rec/ext inherits x");

  f3 := Syms.TypeAddField(ext, "z", Syms.TypeInteger);
  Test.AssertTrue(Syms.SymFindField(ext, "z") = f3, "rec/ext own field")
END TRecords;

(* ---- TypeIsExtension ---- *)

PROCEDURE TIsExtension*;
  VAR base, ext, ext2: Syms.TypeDesc;
BEGIN
  Syms.SymInit();

  base := Syms.TypeNewRecord(NIL);
  ext  := Syms.TypeNewRecord(base);
  ext2 := Syms.TypeNewRecord(ext);

  Test.AssertTrue (Syms.TypeIsExtension(ext,  base), "isext/direct");
  Test.AssertTrue (Syms.TypeIsExtension(ext2, base), "isext/transitive");
  Test.AssertFalse(Syms.TypeIsExtension(base, ext),  "isext/not reverse");
  Test.AssertTrue (Syms.TypeIsExtension(base, base), "isext/self")
END TIsExtension;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TPredeclared, "Syms/predeclared");
  Test.AddTest(TScopes,      "Syms/scopes");
  Test.AddTest(TAllocLocal,  "Syms/allocLocal");
  Test.AddTest(TCalcArgSize, "Syms/calcArgSize");
  Test.AddTest(TRecords,     "Syms/records");
  Test.AddTest(TIsExtension, "Syms/isExtension");
  Test.RunTests
END RunAllTests;

END TSYMS.
