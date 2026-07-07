MODULE TRDOF;
(* Unit tests for Rdoff — Oberon port of tests/test_rdoff.c.
   Each test builds an ObjFile, writes it to a temp .rdf, reads the bytes
   back and asserts the binary layout. *)

IMPORT Test, Files, Rdoff;

VAR
  TmpRdf: ARRAY 8 OF CHAR;
  Buf: ARRAY 1024 OF BYTE;
  BufLen: LONGINT;

PROCEDURE writeAndSlurp(obj: Rdoff.ObjFile);
  VAR f: Files.File; n: WORD; size: LONGINT;
BEGIN
  Rdoff.RdfWrite(obj, TmpRdf);
  IF Files.Reset(f, TmpRdf) THEN
    size := Files.Size(f);
    IF size > LONGINT(LEN(Buf)) THEN size := LONGINT(LEN(Buf)) END;
    BufLen := size;
    Files.Seek(f, 0);
    n := Files.BlockRead(f, Buf, WORD(size));
    Files.Close(f)
  ELSE
    BufLen := 0
  END
END writeAndSlurp;

PROCEDURE cleanup;
  VAR ok: BOOLEAN;
BEGIN
  ok := Files.Delete(TmpRdf)
END cleanup;

PROCEDURE b(off: INTEGER): INTEGER;
BEGIN RETURN INTEGER(Buf[off]) END b;

PROCEDURE r16(off: INTEGER): INTEGER;
BEGIN
  RETURN INTEGER(Buf[off]) + INTEGER(Buf[off + 1]) * 256
END r16;

PROCEDURE r32(off: INTEGER): LONGINT;
BEGIN
  RETURN LONGINT(Buf[off]) + LONGINT(Buf[off + 1]) * 100H
       + LONGINT(Buf[off + 2]) * 10000H
       + LONGINT(Buf[off + 3]) * 1000000H
END r32;

PROCEDURE nthImport(obj: Rdoff.ObjFile; n: INTEGER): Rdoff.ImportNode;
  VAR p: Rdoff.ImportNode;
BEGIN
  p := obj^.importHead;
  WHILE (p # NIL) & (n > 0) DO p := p^.next; DEC(n) END;
  RETURN p
END nthImport;

PROCEDURE nthGlobal(obj: Rdoff.ObjFile; n: INTEGER): Rdoff.GlobalNode;
  VAR p: Rdoff.GlobalNode;
BEGIN
  p := obj^.globalHead;
  WHILE (p # NIL) & (n > 0) DO p := p^.next; DEC(n) END;
  RETURN p
END nthGlobal;

(* ---- init state ---- *)

PROCEDURE TInitState*;
  VAR obj: Rdoff.ObjFile;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Test.AssertInt(3, obj^.nextImportId, "init/nextImportId=3");
  Test.AssertInt(0, obj^.nImports,     "init/nImports=0");
  Test.AssertInt(0, obj^.nGlobals,     "init/nGlobals=0");
  Test.AssertInt(0, obj^.nRelocs,      "init/nRelocs=0");
  Test.AssertWord(0, obj^.codeLen,     "init/codeLen=0");
  Test.AssertWord(0, obj^.dataLen,     "init/dataLen=0");
  Test.AssertLong(0, obj^.bssSize,     "init/bssSize=0");
  Rdoff.RdfFree(obj)
END TInitState;

(* ---- import id assignment ---- *)

PROCEDURE TImportId*;
  VAR obj: Rdoff.ObjFile; id1, id2, id3: INTEGER;
      imp: Rdoff.ImportNode;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  id1 := Rdoff.RdfAddImport(obj, "Foo");
  id2 := Rdoff.RdfAddImport(obj, "Bar");
  id3 := Rdoff.RdfAddImport(obj, "Baz");
  Test.AssertInt(3, id1, "import-id/first=3");
  Test.AssertInt(4, id2, "import-id/second=4");
  Test.AssertInt(5, id3, "import-id/third=5");
  Test.AssertInt(3, obj^.nImports, "import-id/count=3");
  imp := nthImport(obj, 0);
  Test.AssertStr("Foo", imp^.name, "import-id/name[0]=Foo");
  Test.AssertInt(3, imp^.segId,    "import-id/segid[0]=3");
  Test.AssertInt(0, INTEGER(imp^.flags), "import-id/flags=0");
  imp := nthImport(obj, 1);
  Test.AssertStr("Bar", imp^.name, "import-id/name[1]=Bar");
  Test.AssertInt(4, imp^.segId,    "import-id/segid[1]=4");
  Rdoff.RdfFree(obj)
END TImportId;

(* ---- global add ---- *)

PROCEDURE TGlobalAdd*;
  VAR obj: Rdoff.ObjFile; g: Rdoff.GlobalNode;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.RdfAddGlobal(obj, "MyMod__init", BYTE(Rdoff.SegCode), 42);
  Rdoff.RdfAddGlobal(obj, "MyMod_Var",   BYTE(Rdoff.SegData), 0);
  Test.AssertInt(2, obj^.nGlobals, "global/count=2");
  g := nthGlobal(obj, 0);
  Test.AssertInt(1, INTEGER(g^.flags),  "global/flags=exported");
  Test.AssertInt(Rdoff.SegCode, INTEGER(g^.segId), "global/seg=code");
  Test.AssertLong(42, g^.offset, "global/offset=42");
  Test.AssertStr("MyMod__init", g^.name, "global/name");
  g := nthGlobal(obj, 1);
  Test.AssertInt(Rdoff.SegData, INTEGER(g^.segId), "global/seg=data");
  Test.AssertLong(0, g^.offset, "global/offset=0");
  Rdoff.RdfFree(obj)
END TGlobalAdd;

(* ---- signature ---- *)

PROCEDURE TSignature*;
  VAR obj: Rdoff.ObjFile;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertInt(ORD("R"), b(0), "sig/[0]=R");
  Test.AssertInt(ORD("D"), b(1), "sig/[1]=D");
  Test.AssertInt(ORD("O"), b(2), "sig/[2]=O");
  Test.AssertInt(ORD("F"), b(3), "sig/[3]=F");
  Test.AssertInt(ORD("F"), b(4), "sig/[4]=F");
  Test.AssertInt(ORD("2"), b(5), "sig/[5]=2");
  Rdoff.RdfFree(obj); cleanup
END TSignature;

(* ---- file size field ---- *)

PROCEDURE TFileSize*;
  VAR obj: Rdoff.ObjFile;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertLong(35, BufLen, "filesize/empty-hdr+1-code=35");
  Test.AssertLong(BufLen, r32(6), "filesize/field-matches-actual");
  Rdoff.RdfFree(obj); cleanup
END TFileSize;

(* ---- header size ---- *)

PROCEDURE THeaderSize*;
  VAR obj: Rdoff.ObjFile;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  BufLen := LONGINT(Rdoff.RdfAddImport(obj, "Foo"));
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertLong(9, r32(10), "hdr-size/one-import-Foo=9");
  Rdoff.RdfFree(obj); cleanup
END THeaderSize;

(* ---- import 2-byte seg_id ---- *)

PROCEDURE TImport2byte*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER; id: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  id := Rdoff.RdfAddImport(obj, "Foo");
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.RecImport, b(hdr + 0), "import/type=2");
  Test.AssertInt(7,                 b(hdr + 1), "import/length=7");
  Test.AssertInt(0,                 b(hdr + 2), "import/flags=0");
  Test.AssertInt(3,                 r16(hdr + 3), "import/segid LE16=3");
  Test.AssertInt(0,                 b(hdr + 4), "import/segid hi byte=0");
  Test.AssertInt(ORD("F"),          b(hdr + 5), "import/name starts after 2-byte segid");
  Test.AssertInt(ORD("F"), b(hdr + 5), "import/name[0]=F");
  Test.AssertInt(ORD("o"), b(hdr + 6), "import/name[1]=o");
  Test.AssertInt(ORD("o"), b(hdr + 7), "import/name[2]=o");
  Test.AssertInt(0,        b(hdr + 8), "import/name[3]=NUL");
  Rdoff.RdfFree(obj); cleanup
END TImport2byte;

(* ---- global 1-byte seg_id ---- *)

PROCEDURE TGlobal1byte*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.RdfAddGlobal(obj, "Baz", BYTE(Rdoff.SegCode), 0);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.RecGlobal, b(hdr + 0), "global/type=3");
  Test.AssertInt(10,                b(hdr + 1), "global/length=10");
  Test.AssertInt(1,                 b(hdr + 2), "global/flags=exported");
  Test.AssertInt(Rdoff.SegCode,   b(hdr + 3), "global/segid 1-byte=code");
  Test.AssertLong(0,                r32(hdr + 4), "global/offset=0");
  Test.AssertInt(ORD("B"), b(hdr + 8),  "global/name[0]=B");
  Test.AssertInt(ORD("a"), b(hdr + 9),  "global/name[1]=a");
  Test.AssertInt(ORD("z"), b(hdr + 10), "global/name[2]=z");
  Test.AssertInt(0,        b(hdr + 11), "global/name[3]=NUL");
  Rdoff.RdfFree(obj); cleanup
END TGlobal1byte;

(* ---- global data seg ---- *)

PROCEDURE TGlobalDataSeg*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.RdfAddGlobal(obj, "Dat", BYTE(Rdoff.SegData), 8);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.SegData, b(hdr + 3), "global/data segid=1");
  Test.AssertLong(8, r32(hdr + 4), "global/data offset=8");
  Rdoff.RdfFree(obj); cleanup
END TGlobalDataSeg;

(* ---- reloc records ---- *)

PROCEDURE TRelocRecord*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  Rdoff.RdfAddReloc(obj, Rdoff.SegCode, 5, 2, 3, TRUE);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.RecReloc, b(hdr + 0), "reloc/type=1");
  Test.AssertInt(8,                b(hdr + 1), "reloc/length=8");
  Test.AssertInt(Rdoff.SegCode + 40H, b(hdr + 2), "reloc/phys relative bit");
  Test.AssertLong(5, r32(hdr + 3), "reloc/offset=5");
  Test.AssertInt(2,  b(hdr + 7),   "reloc/width=2");
  Test.AssertInt(3,  r16(hdr + 8), "reloc/rseg=3");
  Rdoff.RdfFree(obj); cleanup
END TRelocRecord;

PROCEDURE TRelocAbsolute*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  Rdoff.RdfAddReloc(obj, Rdoff.SegCode, 0, 2, Rdoff.SegData, FALSE);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.SegCode, b(hdr + 2),
                 "reloc/abs no relative bit");
  Test.AssertInt(Rdoff.SegData, r16(hdr + 8),
                 "reloc/abs rseg=data");
  Rdoff.RdfFree(obj); cleanup
END TRelocAbsolute;

(* ---- segreloc ---- *)

PROCEDURE TSegRelocRecord*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, 7, 4);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.RecSegreloc, b(hdr + 0), "segreloc/type=6");
  Test.AssertInt(8,                   b(hdr + 1), "segreloc/length=8");
  Test.AssertInt(Rdoff.SegCode,     b(hdr + 2),
                 "segreloc/phys-seg bit7 stripped");
  Test.AssertLong(7, r32(hdr + 3), "segreloc/offset=7");
  Test.AssertInt(4,  r16(hdr + 8), "segreloc/rseg=4");
  Rdoff.RdfFree(obj); cleanup
END TSegRelocRecord;

(* ---- BSS ---- *)

PROCEDURE TBssRecord*;
  VAR obj: Rdoff.ObjFile; hdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  Rdoff.RdfSetBss(obj, 256);
  writeAndSlurp(obj);
  hdr := 14;
  Test.AssertInt(Rdoff.RecBss, b(hdr + 0), "bss/type=5");
  Test.AssertInt(4,              b(hdr + 1), "bss/length=4");
  Test.AssertLong(256, r32(hdr + 2), "bss/amount=256");
  Rdoff.RdfFree(obj); cleanup
END TBssRecord;

(* ---- code segment header ---- *)

PROCEDURE TCodeSegHeader*;
  VAR obj: Rdoff.ObjFile; seg: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0ABH);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CDH);
  writeAndSlurp(obj);
  seg := 14;
  Test.AssertInt(1, r16(seg + 0), "code-seg/type=1");
  Test.AssertInt(0, r16(seg + 2), "code-seg/number=0");
  Test.AssertInt(0, r16(seg + 4), "code-seg/reserved=0");
  Test.AssertLong(2, r32(seg + 6), "code-seg/length=2");
  Test.AssertInt(0ABH, b(seg + 10), "code-seg/byte[0]=AB");
  Test.AssertInt(0CDH, b(seg + 11), "code-seg/byte[1]=CD");
  Rdoff.RdfFree(obj); cleanup
END TCodeSegHeader;

(* ---- no data segment ---- *)

PROCEDURE TNoDataSegment*;
  VAR obj: Rdoff.ObjFile; codeEnd: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertLong(35, BufLen, "no-data/total=35");
  codeEnd := 14 + 10 + 1;
  Test.AssertInt(0, b(codeEnd), "no-data/eof at code end");
  Rdoff.RdfFree(obj); cleanup
END TNoDataSegment;

(* ---- data segment present ---- *)

PROCEDURE TDataSegmentPresent*;
  VAR obj: Rdoff.ObjFile; dseg: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  Rdoff.EmitByte(obj, Rdoff.SegData, 042H);
  Rdoff.EmitByte(obj, Rdoff.SegData, 043H);
  writeAndSlurp(obj);
  dseg := 14 + 10 + 1;
  Test.AssertInt(2, r16(dseg + 0), "data-seg/type=2");
  Test.AssertInt(1, r16(dseg + 2), "data-seg/number=1");
  Test.AssertLong(2, r32(dseg + 6), "data-seg/length=2");
  Test.AssertInt(042H, b(dseg + 10), "data-seg/byte[0]=42");
  Test.AssertInt(043H, b(dseg + 11), "data-seg/byte[1]=43");
  Rdoff.RdfFree(obj); cleanup
END TDataSegmentPresent;

(* ---- EOF segment ---- *)

PROCEDURE TEofSegment*;
  VAR obj: Rdoff.ObjFile; ok: BOOLEAN; i: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertTrue(BufLen >= 10, "eof/file >=10 bytes");
  ok := TRUE;
  FOR i := INTEGER(BufLen) - 10 TO INTEGER(BufLen) - 1 DO
    IF b(i) # 0 THEN ok := FALSE END
  END;
  Test.AssertTrue(ok, "eof/last 10 bytes zero");
  Rdoff.RdfFree(obj); cleanup
END TEofSegment;

(* ---- header record order ---- *)

PROCEDURE TRecordOrder*;
  VAR obj: Rdoff.ObjFile; impLen: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.RdfAddGlobal(obj, "G", BYTE(Rdoff.SegCode), 0);
  impLen := Rdoff.RdfAddImport(obj, "I");
  Rdoff.RdfAddReloc(obj, Rdoff.SegCode, 0, 2, 3, TRUE);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertInt(Rdoff.RecReloc,  b(14),           "order/first=reloc");
  Test.AssertInt(Rdoff.RecImport, b(14 + 10),      "order/second=import");
  impLen := b(14 + 10 + 1);
  Test.AssertInt(Rdoff.RecGlobal, b(14 + 10 + 2 + impLen),
                 "order/third=global");
  Rdoff.RdfFree(obj); cleanup
END TRecordOrder;

PROCEDURE RunAllTests*;
BEGIN
  TmpRdf := "_t.RDF";
  Test.AddTest(TInitState,          "Rdoff/init-state");
  Test.AddTest(TImportId,           "Rdoff/import-id");
  Test.AddTest(TGlobalAdd,          "Rdoff/global-add");
  Test.AddTest(TSignature,          "Rdoff/signature");
  Test.AddTest(TFileSize,           "Rdoff/file-size");
  Test.AddTest(THeaderSize,         "Rdoff/header-size");
  Test.AddTest(TImport2byte,        "Rdoff/import-2byte");
  Test.AddTest(TGlobal1byte,        "Rdoff/global-1byte");
  Test.AddTest(TGlobalDataSeg,      "Rdoff/global-data-seg");
  Test.AddTest(TRelocRecord,        "Rdoff/reloc-record");
  Test.AddTest(TRelocAbsolute,      "Rdoff/reloc-absolute");
  Test.AddTest(TSegRelocRecord,     "Rdoff/segreloc-record");
  Test.AddTest(TBssRecord,          "Rdoff/bss-record");
  Test.AddTest(TCodeSegHeader,      "Rdoff/code-seg-header");
  Test.AddTest(TNoDataSegment,      "Rdoff/no-data-segment");
  Test.AddTest(TDataSegmentPresent, "Rdoff/data-segment-present");
  Test.AddTest(TEofSegment,         "Rdoff/eof-segment");
  Test.AddTest(TRecordOrder,        "Rdoff/record-order");
  Test.RunTests
END RunAllTests;

END TRDOF.
