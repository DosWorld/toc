MODULE TRDOF;
(* Unit tests for Rdoff — Oberon port of tests/test_rdoff.c.
   Each test builds an ObjFile, writes it to a temp .rdf, reads the bytes
   back and asserts the binary layout. *)

IMPORT Test, Files, Rdoff, Strings;

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
  Test.AssertInt(0, INTEGER(g^.flags),  "global/flags=0 (matches real NASM)");
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
  (* 14 (RDOFF2 header) + 0 (hlen: no imports/globals/relocs/bss) +
     10 (code seg header) + 1 (code byte) + 10 (data seg header, always
     emitted even when empty -- matches real NASM, see RdfWriteTo) +
     10 (EOF marker) = 45 actual bytes on disk.  The modSize FIELD itself
     under-reports by exactly 10 (real NASM's own writer does the same --
     see RdfWriteTo's comment on this bug-compatibility quirk), so the
     field reads BufLen-10, not BufLen. *)
  Test.AssertLong(45, BufLen, "filesize/empty-hdr+1-code+empty-data=45");
  Test.AssertLong(BufLen - LONGINT(10), r32(6), "filesize/field-under-reports-by-10");
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
  Test.AssertInt(0,                 b(hdr + 2), "global/flags=0 (matches real NASM)");
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

(* "No data segment" here means dataLen=0 -- RdfWriteTo still emits the
   data segment's 10-byte header unconditionally (matches real NASM's own
   writer, see RdfWriteTo), so the segment TABLE always has code+data+EOF
   entries; only the data segment's own byte PAYLOAD is empty. *)
PROCEDURE TNoDataSegment*;
  VAR obj: Rdoff.ObjFile; dataHdr: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertLong(45, BufLen, "no-data/total=45");
  dataHdr := 14 + 10 + 1;
  Test.AssertInt(2, b(dataHdr), "no-data/data seg header type=2");
  Test.AssertLong(0, r32(dataHdr + 6), "no-data/data seg length=0");
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

(* Current writer order: GLOBAL, then IMPORT, then RELOC/SEGRELOC --
   matches real NASM's own RDOFF2 writer (see RdfWriteTo). *)
PROCEDURE TRecordOrder*;
  VAR obj: Rdoff.ObjFile; nameLen: INTEGER;
BEGIN
  NEW(obj); Rdoff.RdfInit(obj);
  Rdoff.RdfAddGlobal(obj, "G", BYTE(Rdoff.SegCode), 0);
  nameLen := Rdoff.RdfAddImport(obj, "I");
  Rdoff.RdfAddReloc(obj, Rdoff.SegCode, 0, 2, 3, TRUE);
  Rdoff.EmitByte(obj, Rdoff.SegCode, 0CBH);
  writeAndSlurp(obj);
  Test.AssertInt(Rdoff.RecGlobal, b(14),      "order/first=global");
  nameLen := b(14 + 1) - 6;                    (* global len - fixed part *)
  Test.AssertInt(Rdoff.RecImport, b(14 + 2 + 6 + nameLen),
                 "order/second=import");
  Rdoff.RdfFree(obj); cleanup
END TRecordOrder;

(* ---- MergeRdf ($L / MAIN.RDF compile-time folding) ----
   Regression coverage for the 2026-07-23/24 bug: a cross-object import
   resolved by MergeRdf must survive as an ordinary SegCode/SegData reloc
   (offset = target's in-object offset only), NEVER patched with an
   absolute address and dropped.  The real linker's own OnReloc/OnSegReloc
   still add the owning module's GroupOfs/group-paragraph on top at final
   link time (DOCS/RDOFF2.MD Sec 6.4) -- that addition depends on the whole
   program's module layout, which MergeRdf cannot know.  Dropping the
   reloc after patching only worked by accident when the merged object
   happened to land at group-offset 0; the first minimal counter-example
   (a tiny module importing a helper module, both put in one code group
   with the helper NOT first) reproduced wrong runtime behaviour instantly
   even though every unit-level byte check on the merged .rdf in isolation
   looked correct -- this suite exists so that regression is caught here,
   at the object-structure level, without needing a full compile+link+run
   cycle to notice it again. *)

PROCEDURE writeObj(obj: Rdoff.ObjFile; name: ARRAY OF CHAR; VAR f: Files.File);
BEGIN
  Rdoff.RdfWrite(obj, name);
  IF ~Files.Reset(f, name) THEN Test.AssertTrue(FALSE, "merge/fixture write failed") END
END writeObj;

PROCEDURE findGlobalOfs(obj: Rdoff.ObjFile; name: ARRAY OF CHAR): LONGINT;
  VAR g: Rdoff.GlobalNode;
BEGIN
  g := obj^.globalHead;
  WHILE g # NIL DO
    IF Strings.Equal(g^.name, name) THEN RETURN g^.offset END;
    g := g^.next
  END;
  RETURN -1
END findGlobalOfs;

(* Host imports a symbol that donor exports as its first (offset 0) code
   global -- mirrors Simple.MOD importing HelperA.DoA in the original
   repro.  After merge, that reloc must become rseg=SegCode with offset =
   host's own reloc-site offset (unshifted -- host never moves), and a
   plain SegCode entry must exist whose target math resolves within the
   donor's code region -- NOT patched to an absolute address, NOT removed. *)
PROCEDURE TMergeResolvedImportSurvives*;
  VAR host, donor, merged: Rdoff.ObjFile;
      hf, df, mf: Files.File;
      ok: BOOLEAN;
      importId: INTEGER;
      r: Rdoff.RelocNode;
      foundCode, foundSeg: BOOLEAN;
      k: INTEGER;
BEGIN
  NEW(host); Rdoff.RdfInit(host);
  importId := Rdoff.RdfAddImport(host, "Donor_Do");
  Rdoff.EmitByte(host, Rdoff.SegCode, 09AH);   (* CALL FAR opcode *)
  Rdoff.RdfAddReloc(host, Rdoff.SegCode, Rdoff.CodeLen(host), 2, importId, FALSE);
  Rdoff.EmitByte(host, Rdoff.SegCode, 0); Rdoff.EmitByte(host, Rdoff.SegCode, 0);
  Rdoff.RdfAddSegReloc(host, Rdoff.SegCode, Rdoff.CodeLen(host), importId);
  Rdoff.EmitByte(host, Rdoff.SegCode, 0); Rdoff.EmitByte(host, Rdoff.SegCode, 0);
  writeObj(host, "_th1.RDF", hf); Rdoff.RdfFree(host);

  NEW(donor); Rdoff.RdfInit(donor);
  Rdoff.RdfAddGlobal(donor, "Donor_Do", BYTE(Rdoff.SegCode), 0);
  Rdoff.EmitByte(donor, Rdoff.SegCode, 0C3H);  (* RET *)
  writeObj(donor, "_th2.RDF", df); Rdoff.RdfFree(donor);

  IF ~Files.ReWrite(mf, "_thd.RDF") THEN Test.AssertTrue(FALSE, "merge/dst create failed") END;
  ok := Rdoff.MergeRdf(hf, df, mf);
  Files.Close(hf); Files.Close(df); Files.Close(mf);
  Test.AssertTrue(ok, "merge/MergeRdf succeeds");

  NEW(merged); Rdoff.RdfInit(merged);
  ok := Rdoff.RdfLoad(merged, "_thd.RDF");
  Test.AssertTrue(ok, "merge/RdfLoad reads back merged file");

  foundCode := FALSE; foundSeg := FALSE;
  r := merged^.relocHead;
  WHILE r # NIL DO
    k := 0;
    WHILE k < r^.count DO
      IF (r^.rseg[k] = Rdoff.SegCode) & (r^.width[k] = 2) THEN
        IF INTEGER(r^.physSeg[k]) >= 80H THEN foundSeg := TRUE ELSE foundCode := TRUE END
      END;
      INC(k)
    END;
    r := r^.next
  END;
  Test.AssertTrue(foundCode, "merge/resolved RELOC becomes plain SegCode reloc");
  Test.AssertTrue(foundSeg, "merge/resolved SEGRELOC becomes plain SegCode reloc");
  Test.AssertInt(-1, Rdoff.RdfFindImport(merged, "Donor_Do"),
                 "merge/resolved import removed from import list");
  Rdoff.RdfFree(merged);
  ok := Files.Delete("_th1.RDF"); ok := Files.Delete("_th2.RDF"); ok := Files.Delete("_thd.RDF")
END TMergeResolvedImportSurvives;

(* An import neither side can resolve (genuinely external) must survive,
   renumbered so it does not collide with the host's own import ids. *)
PROCEDURE TMergeSurvivingImportRenumbered*;
  VAR host, donor, merged: Rdoff.ObjFile;
      hf, df, mf: Files.File;
      ok: BOOLEAN;
BEGIN
  NEW(host); Rdoff.RdfInit(host);
  ok := Rdoff.RdfAddImport(host, "Ext_HostOnly") >= 0;
  Rdoff.EmitByte(host, Rdoff.SegCode, 0C3H);
  writeObj(host, "_ts1.RDF", hf); Rdoff.RdfFree(host);

  NEW(donor); Rdoff.RdfInit(donor);
  ok := Rdoff.RdfAddImport(donor, "Ext_DonorOnly") >= 0;
  Rdoff.EmitByte(donor, Rdoff.SegCode, 0C3H);
  writeObj(donor, "_ts2.RDF", df); Rdoff.RdfFree(donor);

  IF ~Files.ReWrite(mf, "_tsd.RDF") THEN Test.AssertTrue(FALSE, "merge/dst create failed") END;
  ok := Rdoff.MergeRdf(hf, df, mf);
  Files.Close(hf); Files.Close(df); Files.Close(mf);
  Test.AssertTrue(ok, "merge/surviving-import MergeRdf succeeds");

  NEW(merged); Rdoff.RdfInit(merged);
  ok := Rdoff.RdfLoad(merged, "_tsd.RDF");
  Test.AssertTrue(Rdoff.RdfFindImport(merged, "Ext_HostOnly") >= 3,
                  "merge/host's own external import survives");
  Test.AssertTrue(Rdoff.RdfFindImport(merged, "Ext_DonorOnly") >= 3,
                  "merge/donor's own external import survives");
  Test.AssertTrue(Rdoff.RdfFindImport(merged, "Ext_HostOnly") #
                   Rdoff.RdfFindImport(merged, "Ext_DonorOnly"),
                  "merge/surviving imports get distinct ids");
  Rdoff.RdfFree(merged);
  ok := Files.Delete("_ts1.RDF"); ok := Files.Delete("_ts2.RDF"); ok := Files.Delete("_tsd.RDF")
END TMergeSurvivingImportRenumbered;

(* Donor's code is 2-byte aligned when appended after an odd-length host
   code segment (DOCS/RDOFF2.MD Sec 6.3: code sections within a group are
   word-aligned). *)
PROCEDURE TMergeCodeAlignment*;
  VAR host, donor, merged: Rdoff.ObjFile;
      hf, df, mf: Files.File;
      ok: BOOLEAN;
BEGIN
  NEW(host); Rdoff.RdfInit(host);
  Rdoff.EmitByte(host, Rdoff.SegCode, 0C3H);  (* 1 byte -- odd length *)
  writeObj(host, "_ta1.RDF", hf); Rdoff.RdfFree(host);

  NEW(donor); Rdoff.RdfInit(donor);
  Rdoff.RdfAddGlobal(donor, "Donor_Entry", BYTE(Rdoff.SegCode), 0);
  Rdoff.EmitByte(donor, Rdoff.SegCode, 0C3H);
  writeObj(donor, "_ta2.RDF", df); Rdoff.RdfFree(donor);

  IF ~Files.ReWrite(mf, "_tad.RDF") THEN Test.AssertTrue(FALSE, "merge/align dst create failed") END;
  ok := Rdoff.MergeRdf(hf, df, mf);
  Files.Close(hf); Files.Close(df); Files.Close(mf);
  Test.AssertTrue(ok, "merge/align MergeRdf succeeds");

  NEW(merged); Rdoff.RdfInit(merged);
  ok := Rdoff.RdfLoad(merged, "_tad.RDF");
  Test.AssertLong(2, findGlobalOfs(merged, "Donor_Entry"),
                  "merge/donor code padded to even offset");
  Rdoff.RdfFree(merged);
  ok := Files.Delete("_ta1.RDF"); ok := Files.Delete("_ta2.RDF"); ok := Files.Delete("_tad.RDF")
END TMergeCodeAlignment;

(* Regression for the 2026-07-24 bug: a donor reloc that is NOT an import
   (rseg already SegCode/SegData/SegBss, e.g. SYSTEM.RDF's SYSTEM_Intr
   self-modifying-code patch of its own INT-number byte) targets the
   DONOR'S OWN code.  When donor's code is appended after host's, the
   patch SITE is shifted by AppendShiftedRelocs (already covered elsewhere)
   but the ADDEND stored at that site -- which encodes the target's offset
   from the donor's OWN (pre-merge) code start -- must ALSO gain codeBase,
   since the target moved by exactly the same amount.  Missing this shift
   left the addend pointing at the target's stale pre-merge offset, so the
   final linker's GroupOfs(module) addition landed on the wrong byte
   entirely (confirmed via SYSTEM.RDF: merged int_ins moved to a new code
   offset but the RELOC's stored addend still held its original standalone
   offset). *)
PROCEDURE TMergeSelfTargetAddendShifts*;
  VAR host, donor, merged: Rdoff.ObjFile;
      hf, df, mf: Files.File;
      ok: BOOLEAN;
      siteOfs: LONGINT;
      lo, hi: BYTE;
      addend: INTEGER;
BEGIN
  NEW(host); Rdoff.RdfInit(host);
  Rdoff.EmitByte(host, Rdoff.SegCode, 0C3H); Rdoff.EmitByte(host, Rdoff.SegCode, 0C3H);
  writeObj(host, "_ts3.RDF", hf); Rdoff.RdfFree(host);

  (* donor: byte0..1 = target instruction; byte2 = 'mov [addr],al' site whose
     addend (bytes 3..4) already holds the target's own PRE-merge offset (0),
     i.e. donor's own code offset 0 -- a plain self-referencing RELOC,
     exactly like SYSTEM_Intr's `mov [cs:int_ins+1], al` patch. *)
  NEW(donor); Rdoff.RdfInit(donor);
  Rdoff.EmitByte(donor, Rdoff.SegCode, 0C3H); Rdoff.EmitByte(donor, Rdoff.SegCode, 0C3H);
  siteOfs := Rdoff.CodeLen(donor);
  Rdoff.RdfAddReloc(donor, Rdoff.SegCode, siteOfs, 2, Rdoff.SegCode, FALSE);
  Rdoff.EmitByte(donor, Rdoff.SegCode, 0); Rdoff.EmitByte(donor, Rdoff.SegCode, 0); (* addend=0 *)
  writeObj(donor, "_ts4.RDF", df); Rdoff.RdfFree(donor);

  IF ~Files.ReWrite(mf, "_tsed.RDF") THEN Test.AssertTrue(FALSE, "merge/selftarget dst create failed") END;
  ok := Rdoff.MergeRdf(hf, df, mf);
  Files.Close(hf); Files.Close(df); Files.Close(mf);
  Test.AssertTrue(ok, "merge/selftarget MergeRdf succeeds");

  NEW(merged); Rdoff.RdfInit(merged);
  ok := Rdoff.RdfLoad(merged, "_tsed.RDF");
  Test.AssertTrue(ok, "merge/selftarget RdfLoad reads back merged file");

  (* host contributed 2 bytes of code (even -> no padding), so donor's code
     starts at merged offset 2; the reloc's patch site is host's 2 bytes +
     donor's own siteOfs. *)
  lo := Rdoff.PeekCodeByte(merged, LONGINT(2) + siteOfs);
  hi := Rdoff.PeekCodeByte(merged, LONGINT(2) + siteOfs + LONGINT(1));
  addend := INTEGER(lo) + SYSTEM.LSL(INTEGER(hi), 8);
  Test.AssertInt(2, addend, "merge/self-targeting reloc addend shifted by codeBase");

  Rdoff.RdfFree(merged);
  ok := Files.Delete("_ts3.RDF"); ok := Files.Delete("_ts4.RDF"); ok := Files.Delete("_tsed.RDF")
END TMergeSelfTargetAddendShifts;

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
  Test.AddTest(TMergeResolvedImportSurvives,    "Rdoff/merge-resolved-import-survives");
  Test.AddTest(TMergeSurvivingImportRenumbered, "Rdoff/merge-surviving-import-renumbered");
  Test.AddTest(TMergeCodeAlignment,             "Rdoff/merge-code-alignment");
  Test.AddTest(TMergeSelfTargetAddendShifts,    "Rdoff/merge-self-target-addend-shifts");
  Test.RunTests
END RunAllTests;

END TRDOF.
