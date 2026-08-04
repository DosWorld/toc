(*$R-*)(*$D-*)
MODULE RdfExe;

(* RdfExe: convert a single self-contained RDOFF2 (.rdf) object file into a
   flat 32-bit LE (Linear Executable) or PE (Portable Executable) image.

   Scope, by design: no imports/exports/resources/relocation directories are
   emitted or consumed -- only CODE (segType=1) and DATA (segType=2)
   segments plus BSS (RDFREC_BSS), merged into one code block and one
   data+bss block.  RELOC and SEGRELOC records ARE resolved (they are
   fixups BETWEEN this module's own code/data/bss segments, per
   DOCS/RDOFF2.MD sec 3.3/5) -- what is not supported is any RDFREC_IMPORT
   (RSEG >= 3, a symbol from ANOTHER module): a module with unresolved
   imports is rejected, since RdfExe never links more than one .rdf.

   The module's GLOBAL (export) table must contain "start"; its segment+
   offset becomes the image entry point.

   No dedicated stack object/section: stackSize (RdfToLe/RdfToPe's last
   parameter) simply enlarges the data object/section's in-memory
   footprint beyond its file-backed data+bss content (same idea as
   growing BSS) -- for LE, ESP is set to the top of that enlarged object;
   for PE, the loader zero-fills a section's VirtualSize beyond its
   SizeOfRawData the same way, so this reserves stack space above data+bss
   without writing extra file bytes in either format.

   No dependency outside SYSTEM/Files/Strings (see DOCS/RDOFF2.MD, EXEFMT.HTM
   sec "le"/"pe").

   The .rdf's CODE segment bytes are copied through verbatim -- RdfExe is a
   container-format transcoder, not a recompiler/retargeter.  LE and PE32
   are flat 32-bit protected-mode formats (32-bit registers, rel32
   call/jmp); the .rdf must already carry 32-bit machine code (e.g. from a
   32-bit-targeting assembler) for the resulting image to run.  RDOFF2
   objects produced by THIS project's own toc.exe are 16-bit real-mode
   code and are NOT suitable input here. *)

IMPORT Files, Strings;

CONST
  RecReloc    = 1;
  RecImport   = 2;
  RecGlobal   = 3;
  RecBss      = 5;
  RecSegReloc = 6;

  MaxSeg = 64;   (* RDOFF2 physical segment index is 6 bits: 0..63 *)
  SegCode = 0;
  SegData = 1;
  SegBss  = 2;

  MaxImageSize = 4 * 1024 * 1024;  (* sanity cap: 4 MB code+data+bss *)

  PageLE = 4096;     (* LE object page size *)
  SecAlignPE = 4096;  (* PE section alignment (in-memory) *)
  FileAlignPE = 512;  (* PE file alignment (on-disk) *)
  ImageBasePE = 400000H;

TYPE
  Buf = SYSTEM.ADDRESS;   (* heap block, indexed as ARRAY OF BYTE *)

  RdfHeader = RECORD
    sign:     ARRAY 6 OF CHAR;
    modSize:  LONGINT;
    headSize: LONGINT
  END;

  SegHeaderRec = RECORD
    segType:  INTEGER;
    segNum:   INTEGER;
    reserved: INTEGER;
    length:   LONGINT
  END;

  RecHeaderRec = RECORD
    recType: BYTE;
    recLen:  BYTE
  END;

  (* Per physical segment: which merged buffer it lands in (code or data)
     and its byte offset within that buffer. *)
  SegSlot = RECORD
    used:    BOOLEAN;
    isCode:  BOOLEAN;      (* TRUE -> code buffer, FALSE -> data buffer *)
    ofs:     LONGINT;      (* offset within its merged buffer *)
    rawSize: LONGINT
  END;

  Image = RECORD
    seg:          ARRAY MaxSeg OF SegSlot;
    nSeg:         INTEGER;
    codeBuf:      Buf;
    dataBuf:      Buf;         (* data followed by BSS, zero-filled *)
    codeLen:      LONGINT;
    dataLen:      LONGINT;     (* file-backed data only *)
    bssLen:       LONGINT;
    haveImport:   BOOLEAN;     (* any RDFREC_IMPORT present -> reject *)
    haveStart:    BOOLEAN;
    startIsCode:  BOOLEAN;
    startOfs:     LONGINT      (* offset within its merged buffer *)
  END;

PROCEDURE Align(v, n: LONGINT): LONGINT;
BEGIN
  RETURN ((v + n - LONGINT(1)) DIV n) * n
END Align;

PROCEDURE ExtractString(VAR buf: ARRAY OF BYTE; offset, maxLen: WORD;
                        VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (offset + i < maxLen) & (buf[offset + i] # 0) & (i < 32) DO
    s[i] := CHR(buf[offset + i]); INC(i)
  END;
  s[i] := 0X
END ExtractString;

(* ---- pass 1: scan header records + segments ---- *)

PROCEDURE ScanSegments(VAR f: Files.File; segStart: LONGINT; VAR img: Image): BOOLEAN;
  VAR sh: SegHeaderRec; n: INTEGER;
BEGIN
  Files.Seek(f, segStart);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF sh.segType # 0 THEN
      n := sh.segNum;
      IF (n < 0) OR (n >= MaxSeg) THEN RETURN FALSE END;
      IF (sh.segType # 1) & (sh.segType # 2) THEN RETURN FALSE END;
      img.seg[n].used    := TRUE;
      img.seg[n].isCode  := sh.segType = 1;
      img.seg[n].rawSize := sh.length;
      IF sh.segType = 1 THEN
        img.seg[n].ofs := img.codeLen;
        img.codeLen := img.codeLen + Align(sh.length, LONGINT(2))
      ELSE
        img.seg[n].ofs := img.dataLen;
        img.dataLen := img.dataLen + Align(sh.length, LONGINT(2))
      END;
      IF n + 1 > img.nSeg THEN img.nSeg := n + 1 END
    END;
    IF sh.length > 0 THEN Files.Seek(f, Files.Position(f) + sh.length) END
  UNTIL sh.segType = 0;
  RETURN (img.codeLen <= LONGINT(MaxImageSize)) & (img.dataLen <= LONGINT(MaxImageSize))
END ScanSegments;

PROCEDURE ScanRecords(VAR f: Files.File; recStart, recEnd: LONGINT; VAR img: Image): BOOLEAN;
  VAR h: RecHeaderRec;
      buf: ARRAY 256 OF BYTE;
      bssAmount: LONGINT;
      gSegId: BYTE;
      gOfs: LONGINT;
      name: ARRAY 33 OF CHAR;
      ok: BOOLEAN;
BEGIN
  ok := TRUE;
  Files.Seek(f, recStart);
  WHILE Files.Position(f) < recEnd DO
    Files.BlockRead(f, h, 2);
    IF h.recLen > 0 THEN Files.BlockRead(f, buf, ORD(h.recLen)) END;
    IF h.recType = RecImport THEN
      img.haveImport := TRUE
    ELSIF h.recType = RecBss THEN
      SYSTEM.MOVE(buf[0], bssAmount, 4);
      img.bssLen := img.bssLen + bssAmount
    ELSIF h.recType = RecGlobal THEN
      gSegId := buf[1];
      SYSTEM.MOVE(buf[2], gOfs, 4);
      ExtractString(buf, 6, ORD(h.recLen), name);
      IF Strings.Equal(name, "start") THEN
        IF (INTEGER(gSegId) < 0) OR (INTEGER(gSegId) >= MaxSeg) OR
           ~img.seg[INTEGER(gSegId)].used THEN
          ok := FALSE
        ELSE
          img.haveStart   := TRUE;
          img.startIsCode := img.seg[INTEGER(gSegId)].isCode;
          img.startOfs    := img.seg[INTEGER(gSegId)].ofs + gOfs
        END
      END
    END
  END;
  RETURN ok
END ScanRecords;

PROCEDURE LoadSegmentData(VAR f: Files.File; segStart: LONGINT; VAR img: Image);
  VAR sh: SegHeaderRec; n: INTEGER; dst: Buf;
BEGIN
  Files.Seek(f, segStart);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF sh.length > 0 THEN
      n := sh.segNum;
      IF (sh.segType # 0) & (n >= 0) & (n < MaxSeg) & img.seg[n].used THEN
        IF img.seg[n].isCode THEN dst := img.codeBuf + WORD(img.seg[n].ofs)
        ELSE dst := img.dataBuf + WORD(img.seg[n].ofs)
        END;
        Files.BlockRead(f, dst^, WORD(sh.length))
      ELSE
        Files.Seek(f, Files.Position(f) + sh.length)
      END
    END
  UNTIL sh.segType = 0
END LoadSegmentData;

(* ---- pass 2: apply RELOC / SEGRELOC fixups (references between this
   module's own code/data/bss segments; RSEG 0=code 1=data 2=bss) ---- *)

PROCEDURE TargetOfs(rseg: INTEGER; img: Image; VAR isCode: BOOLEAN): LONGINT;
BEGIN
  isCode := TRUE;
  IF rseg = SegCode THEN RETURN LONGINT(0)
  ELSIF rseg = SegData THEN isCode := FALSE; RETURN LONGINT(0)
  ELSIF rseg = SegBss THEN isCode := FALSE; RETURN img.dataLen
  ELSE RETURN LONGINT(-1)  (* import: unresolvable, caller already rejected file *)
  END
END TargetOfs;

PROCEDURE PatchBuf(buf: Buf; ofs: LONGINT; val: LONGINT; width: BYTE);
  VAR o: WORD;
BEGIN
  o := WORD(ofs);
  IF width = 1 THEN
    buf^[o] := BYTE(SYSTEM.AND(INTEGER(val), 0FFH))
  ELSIF width = 2 THEN
    buf^[o]     := BYTE(SYSTEM.AND(val, 0FFH));
    buf^[o + 1] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH))
  ELSIF width = 4 THEN
    buf^[o]     := BYTE(SYSTEM.AND(val, 0FFH));
    buf^[o + 1] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH));
    buf^[o + 2] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 16), 0FFH));
    buf^[o + 3] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 24), 0FFH))
  END
END PatchBuf;

PROCEDURE ReadBufWord(buf: Buf; ofs: LONGINT): INTEGER;
  VAR o: WORD; b0, b1: BYTE;
BEGIN
  o := WORD(ofs);
  b0 := buf^[o];
  b1 := buf^[o + 1];
  RETURN INTEGER(WORD(b0) + SYSTEM.LSL(WORD(b1), 8))
END ReadBufWord;

PROCEDURE ReadBufDWord(buf: Buf; ofs: LONGINT): LONGINT;
  VAR lo, hi: INTEGER;
BEGIN
  lo := ReadBufWord(buf, ofs);
  hi := ReadBufWord(buf, ofs + LONGINT(2));
  RETURN LONGINT(WORD(lo)) + SYSTEM.S32MUL(LONGINT(WORD(hi)), LONGINT(65536))
END ReadBufDWord;

(* ApplyRecords: fix up every RELOC/SEGRELOC in the header records against
   final flat-image offsets.  patchBase/relBase are added by the caller
   (LE: object-relative RVA i.e. 0 for both, code and data are separate
   objects each based at 0; PE: section-relative RVA likewise 0) --
   RdfExe always resolves fully within its own single module, so both
   patch site and target live in codeBuf/dataBuf at the offsets computed
   in pass 1; the caller places codeBuf at codeRva and dataBuf at dataRva
   in the final file, so pass 2 must add those RVAs once patch values are
   written, which it does directly since codeRva=0 within each object/
   section header (RVA is section-relative in both formats: see
   DOCS/EXEFMT.HTM sec "le" Object Table / sec "pe" section VirtualAddress),
   EXCEPT when data references code or vice-versa across the two separate
   LE objects / PE sections -- there the target offset must be biased by
   the OTHER section's final RVA, so callers pass codeRvaInImage/
   dataRvaInImage explicitly. *)
PROCEDURE ApplyRecords(VAR f: Files.File; recStart, recEnd: LONGINT; VAR img: Image;
                       codeRva, dataRva: LONGINT): BOOLEAN;
  VAR h: RecHeaderRec;
      buf: ARRAY 256 OF BYTE;
      relFlags, relWidth: BYTE;
      relOfs: LONGINT;
      relRSeg: INTEGER;
      physSeg: INTEGER;
      patchIsCode, targetIsCode: BOOLEAN;
      patchBuf: Buf;
      patchOfs, patchFinal: LONGINT;
      targetOfs, targetFinal: LONGINT;
      addend: LONGINT;
      ok: BOOLEAN;
BEGIN
  ok := TRUE;
  Files.Seek(f, recStart);
  WHILE Files.Position(f) < recEnd DO
    Files.BlockRead(f, h, 2);
    IF h.recLen > 0 THEN Files.BlockRead(f, buf, ORD(h.recLen)) END;
    IF (h.recType = RecReloc) OR (h.recType = RecSegReloc) THEN
      relFlags := buf[0];
      SYSTEM.MOVE(buf[1], relOfs, 4);
      relWidth := buf[5];
      SYSTEM.MOVE(buf[6], relRSeg, 2);
      physSeg := INTEGER(SYSTEM.AND(relFlags, 3FH));
      IF (physSeg < 0) OR (physSeg >= MaxSeg) OR ~img.seg[physSeg].used THEN
        ok := FALSE
      ELSE
        patchIsCode := img.seg[physSeg].isCode;
        IF patchIsCode THEN patchBuf := img.codeBuf ELSE patchBuf := img.dataBuf END;
        patchOfs := img.seg[physSeg].ofs + relOfs;
        IF patchIsCode THEN patchFinal := codeRva + patchOfs
        ELSE patchFinal := dataRva + patchOfs
        END;

        targetOfs := TargetOfs(relRSeg, img, targetIsCode);
        IF targetOfs = LONGINT(-1) THEN
          ok := FALSE  (* import id: not supported *)
        ELSE
          IF targetIsCode THEN targetFinal := codeRva + targetOfs
          ELSE targetFinal := dataRva + targetOfs
          END;

          IF h.recType = RecReloc THEN
            (* addend already stored at patch site (RDOFF2 sec 3.3) *)
            IF relWidth = 2 THEN addend := LONGINT(ReadBufWord(patchBuf, patchOfs))
            ELSE addend := ReadBufDWord(patchBuf, patchOfs)
            END;
            IF SYSTEM.AND(relFlags, 40H) # 0 THEN  (* PC-relative *)
              PatchBuf(patchBuf, patchOfs, targetFinal + addend - (patchFinal + LONGINT(relWidth)), relWidth)
            ELSE
              PatchBuf(patchBuf, patchOfs, targetFinal + addend, relWidth)
            END
          ELSE
            (* SEGRELOC: flat 32-bit image has no real segment bases; the
               "segment value" degenerates to the target's own final RVA
               (matches a flat-model interpretation of RDOFF2 sec 3.3 Type 6:
               callers needing `seg X` under a flat memory model want the
               base address of X, which here IS its RVA). *)
            PatchBuf(patchBuf, patchOfs, targetFinal, relWidth)
          END
        END
      END
    END
  END;
  RETURN ok
END ApplyRecords;

(* ---- shared front end: parse + relocate, leaving img.codeBuf/dataBuf
   ready and img.startOfs resolved.  codeRva/dataRva are supplied by the
   caller (format-specific layout) so ApplyRecords can bias cross-segment
   references correctly. *)
PROCEDURE Parse(VAR src: Files.File; codeRva, dataRva: LONGINT; VAR img: Image): BOOLEAN;
  VAR hdr: RdfHeader;
      recStart, segStart: LONGINT;
      i: INTEGER;
      total: LONGINT;
BEGIN
  i := 0;
  WHILE i < MaxSeg DO
    img.seg[i].used := FALSE;
    img.seg[i].isCode := FALSE;
    img.seg[i].ofs := LONGINT(0);
    img.seg[i].rawSize := LONGINT(0);
    INC(i)
  END;
  img.nSeg := 0;
  img.codeBuf := NIL; img.dataBuf := NIL;
  img.codeLen := LONGINT(0); img.dataLen := LONGINT(0); img.bssLen := LONGINT(0);
  img.haveImport := FALSE; img.haveStart := FALSE;
  img.startIsCode := TRUE; img.startOfs := LONGINT(0);

  Files.Seek(src, LONGINT(0));
  IF Files.BlockRead(src, hdr, 14) # 14 THEN RETURN FALSE END;
  IF (hdr.sign[0] # "R") OR (hdr.sign[1] # "D") OR (hdr.sign[2] # "O") OR
     (hdr.sign[3] # "F") OR (hdr.sign[4] # "F") OR (hdr.sign[5] # "2") THEN
    RETURN FALSE
  END;
  recStart := Files.Position(src);
  segStart := recStart + hdr.headSize;

  IF ~ScanSegments(src, segStart, img) THEN RETURN FALSE END;
  IF ~ScanRecords(src, recStart, segStart, img) THEN RETURN FALSE END;
  IF img.haveImport THEN RETURN FALSE END;     (* no cross-module linking supported *)
  IF ~img.haveStart THEN RETURN FALSE END;     (* module must export "start" *)

  total := img.codeLen + img.dataLen + img.bssLen;
  IF total > LONGINT(MaxImageSize) THEN RETURN FALSE END;

  IF img.codeLen > LONGINT(0) THEN
    NEW(img.codeBuf, WORD(img.codeLen));
    IF img.codeBuf = NIL THEN RETURN FALSE END;
    SYSTEM.FILL(img.codeBuf^, WORD(img.codeLen), 0)
  END;
  IF img.dataLen + img.bssLen > LONGINT(0) THEN
    NEW(img.dataBuf, WORD(img.dataLen + img.bssLen));
    IF img.dataBuf = NIL THEN RETURN FALSE END;
    SYSTEM.FILL(img.dataBuf^, WORD(img.dataLen + img.bssLen), 0)
  END;

  LoadSegmentData(src, segStart, img);
  RETURN ApplyRecords(src, recStart, segStart, img, codeRva, dataRva)
END Parse;

PROCEDURE FreeImage(VAR img: Image);
BEGIN
  IF img.codeBuf # NIL THEN DISPOSE(img.codeBuf); img.codeBuf := NIL END;
  IF img.dataBuf # NIL THEN DISPOSE(img.dataBuf); img.dataBuf := NIL END
END FreeImage;

(* =====================================================================
   LE (Linear Executable) writer
   Layout: MZ stub (32 bytes, minimal) -> LE header -> Object Table (2
   entries: code, data+bss) -> Object Page Table -> data pages (one page
   per object, page size = object size, <= PageLE assumed for this
   minimal writer) -> Entry Table (single 32-bit entry) -> Resident Name
   Table (empty, 0-terminated).
   No fixups/imports/resources: internal references were already resolved
   to flat RVAs by Parse/ApplyRecords, so no Fixup Section is written
   (object's "internal fixups applied" bit set, sec 3 x10 bit 4). ===== *)

PROCEDURE WriteMzStubLE(VAR dst: Files.File; leHdrOfs: LONGINT);
  VAR i: INTEGER;
BEGIN
  Files.WriteWord(dst, 5A4DH);      (* 'MZ' *)
  Files.WriteWord(dst, 0);          (* bytes on last page *)
  Files.WriteWord(dst, 2);          (* pages *)
  Files.WriteWord(dst, 0);          (* relocations *)
  Files.WriteWord(dst, 2);          (* header size, paragraphs *)
  Files.WriteWord(dst, 0);          (* min alloc *)
  Files.WriteWord(dst, 0FFFFH);     (* max alloc *)
  Files.WriteWord(dst, 0);          (* SS *)
  Files.WriteWord(dst, 0);          (* SP *)
  Files.WriteWord(dst, 0);          (* checksum *)
  Files.WriteWord(dst, 0);          (* IP *)
  Files.WriteWord(dst, 0);          (* CS *)
  Files.WriteWord(dst, 40H);        (* reloc table offset: 0x40, per sec "le" x18 *)
  Files.WriteWord(dst, 0);          (* overlay *)
  i := 0;
  WHILE i < 4 DO Files.WriteWord(dst, 0); INC(i) END;  (* x1C..x23 reserved *)
  Files.WriteWord(dst, 0);          (* OEM id, x24 *)
  Files.WriteWord(dst, 0);          (* OEM info, x26 *)
  i := 0;
  WHILE i < 10 DO Files.WriteWord(dst, 0); INC(i) END;  (* x28..x3B reserved *)
  Files.WriteDWord(dst, leHdrOfs)   (* x3C: offset to LE header *)
END WriteMzStubLE;

PROCEDURE RdfToLe*(VAR src, dst: Files.File; stackSize: LONGINT): BOOLEAN;
  VAR img: Image;
      leHdrOfs: LONGINT;
      objTblOfs, objPgTblOfs, dataPageOfs, entTblOfs, rntOfs, loaderSize: LONGINT;
      codeObjSize, dataObjSize, dataObjMemSize: LONGINT;
      entryObj, entryOfs: LONGINT;
      stackObj: LONGINT;
      totalPages: LONGINT;
      nObjects: INTEGER;
BEGIN
  IF stackSize < LONGINT(0) THEN RETURN FALSE END;
  IF ~Parse(src, LONGINT(0), LONGINT(0), img) THEN RETURN FALSE END;

  codeObjSize := img.codeLen;
  dataObjSize := img.dataLen + img.bssLen;
  (* Stack lives at the top of the data object's in-memory image: the
     Object Page Table only carries FILE-BACKED pages (dataObjSize), but
     the object's x00 "size loaded into memory" may exceed that -- the LE
     loader zero-fills the gap (sec "le" Object Page Table: "any remaining
     pages are zero filled"), which is exactly what an initial stack needs. *)
  dataObjMemSize := dataObjSize + stackSize;
  nObjects := 0;
  IF codeObjSize > LONGINT(0) THEN INC(nObjects) END;
  IF dataObjMemSize > LONGINT(0) THEN INC(nObjects) END;
  IF nObjects = 0 THEN FreeImage(img); RETURN FALSE END;
  IF codeObjSize > LONGINT(PageLE) THEN FreeImage(img); RETURN FALSE END;  (* minimal writer: 1 page/object *)
  IF dataObjSize > LONGINT(PageLE) THEN FreeImage(img); RETURN FALSE END;

  IF img.startIsCode THEN entryObj := 1 ELSE entryObj := 2 END;
  IF (entryObj = 2) & (codeObjSize = LONGINT(0)) THEN entryObj := 1 END;
  entryOfs := img.startOfs;

  leHdrOfs   := LONGINT(40H);  (* 64-byte MZ stub, matches x3C reloc-table-at-x40 convention *)
  objTblOfs  := LONGINT(0B0H); (* LE header is 0xB0 bytes (through x_AC + pad to xB0) *)
  objPgTblOfs := objTblOfs + LONGINT(nObjects) * LONGINT(24);
  loaderSize := objPgTblOfs + LONGINT(nObjects) * LONGINT(4) - objTblOfs;
  entTblOfs  := objPgTblOfs + LONGINT(nObjects) * LONGINT(4);
  rntOfs     := entTblOfs + LONGINT(6);  (* one 32-bit-entry bundle: 4-byte header + 6-byte entry *)
  loaderSize := rntOfs + LONGINT(1) - objTblOfs;  (* through resident-name-table terminator *)
  dataPageOfs := leHdrOfs + rntOfs + LONGINT(1);
  dataPageOfs := Align(dataPageOfs, LONGINT(4));

  totalPages := LONGINT(0);
  IF codeObjSize > LONGINT(0) THEN INC(totalPages) END;
  IF dataObjSize > LONGINT(0) THEN INC(totalPages) END;   (* stack pages are not file-backed *)

  IF dataObjMemSize > LONGINT(0) THEN stackObj := LONGINT(nObjects) ELSE stackObj := LONGINT(1) END;

  WriteMzStubLE(dst, leHdrOfs);

  (* ---- LE header (module header), sec "le" x00.. ---- *)
  Files.Write(dst, "LE");                    (* x00 magic *)
  Files.WriteByte(dst, 0);                   (* x02 byte order: LE *)
  Files.WriteByte(dst, 0);                   (* x03 word order: LE *)
  Files.WriteDWord(dst, LONGINT(0));         (* x04 format level *)
  Files.WriteWord(dst, 2);                   (* x08 CPU: 80386+ *)
  Files.WriteWord(dst, 0);                   (* x0A OS type: unknown *)
  Files.WriteDWord(dst, LONGINT(0));         (* x0C module version *)
  Files.WriteDWord(dst, LONGINT(10H));       (* x10 module type: internal fixups applied (bit 4) *)
  Files.WriteDWord(dst, totalPages);         (* x14 page count *)
  Files.WriteDWord(dst, entryObj);           (* x18 EIP object *)
  Files.WriteDWord(dst, entryOfs);           (* x1C EIP offset *)
  Files.WriteDWord(dst, stackObj);           (* x20 ESP object: last object (data+stack, or code if no data) *)
  Files.WriteDWord(dst, dataObjMemSize);     (* x24 ESP: top of the data+stack object *)
  Files.WriteDWord(dst, LONGINT(PageLE));    (* x28 page size *)
  Files.WriteDWord(dst, dataObjSize MOD LONGINT(PageLE)); (* x2C byte count of final page (LE) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x30 fixup section size (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x34 fixup section checksum *)
  Files.WriteDWord(dst, loaderSize);         (* x38 loader section size *)
  Files.WriteDWord(dst, LONGINT(0));         (* x3C loader section checksum *)
  Files.WriteDWord(dst, objTblOfs);          (* x40 loader section offset (rel. to LE header) *)
  Files.WriteDWord(dst, LONGINT(nObjects));  (* x44 object count *)
  Files.WriteDWord(dst, objPgTblOfs);        (* x48 object page table offset (rel. to LE header) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x4C object iter page table offset (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x50 resource table offset (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x54 resource table count *)
  Files.WriteDWord(dst, rntOfs);             (* x58 resident name table offset (rel. to LE header) *)
  Files.WriteDWord(dst, entTblOfs);          (* x5C entry table offset (rel. to LE header) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x60 module format directives table (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x64 module format directives count *)
  Files.WriteDWord(dst, LONGINT(0));         (* x68 fixup page table offset (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x6C fixup record table offset (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x70 import module name table (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x74 import module name table count *)
  Files.WriteDWord(dst, LONGINT(0));         (* x78 import procedure name table (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x7C per-page checksum table (none) *)
  Files.WriteDWord(dst, dataPageOfs);        (* x80 data pages offset (from file start) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x84 preload page count *)
  Files.WriteDWord(dst, LONGINT(0));         (* x88 non-resident name table offset *)
  Files.WriteDWord(dst, LONGINT(0));         (* x8C non-resident name table size *)
  Files.WriteDWord(dst, LONGINT(0));         (* x90 non-resident name table checksum *)
  Files.WriteDWord(dst, LONGINT(0));         (* x94 automatic DS object *)
  Files.WriteDWord(dst, LONGINT(0));         (* x98 debug section offset (none) *)
  Files.WriteDWord(dst, LONGINT(0));         (* x9C debug section size *)
  Files.WriteDWord(dst, LONGINT(0));         (* xA0 instance pages preload *)
  Files.WriteDWord(dst, LONGINT(0));         (* xA4 instance pages demand *)
  Files.WriteDWord(dst, LONGINT(0));         (* xA8 heap size *)
  Files.WriteDWord(dst, LONGINT(0));         (* xAC stack size *)

  (* ---- Object Table: one entry per object, 24 bytes each ---- *)
  IF codeObjSize > LONGINT(0) THEN
    Files.WriteDWord(dst, codeObjSize);      (* size in memory *)
    Files.WriteDWord(dst, LONGINT(0));       (* base address (RVA 0, relocatable) *)
    Files.WriteDWord(dst, LONGINT(05H));     (* flags: readable(bit0)+executable(bit2) *)
    Files.WriteDWord(dst, LONGINT(1));       (* object page table index (1-based) *)
    Files.WriteDWord(dst, LONGINT(1));       (* page count *)
    Files.WriteDWord(dst, LONGINT(0))        (* reserved *)
  END;
  IF dataObjMemSize > LONGINT(0) THEN
    Files.WriteDWord(dst, dataObjMemSize);   (* size in memory: file-backed data+bss, plus the stack beyond it *)
    Files.WriteDWord(dst, LONGINT(0));
    Files.WriteDWord(dst, LONGINT(03H));     (* flags: readable(bit0)+writable(bit1) *)
    IF codeObjSize > LONGINT(0) THEN Files.WriteDWord(dst, LONGINT(2)) ELSE Files.WriteDWord(dst, LONGINT(1)) END;
    IF dataObjSize > LONGINT(0) THEN Files.WriteDWord(dst, LONGINT(1)) ELSE Files.WriteDWord(dst, LONGINT(0)) END;  (* page count: 0 file-backed pages if pure BSS+stack *)
    Files.WriteDWord(dst, LONGINT(0))
  END;

  (* ---- Object Page Table: 4 bytes/entry, one page per object ---- *)
  IF codeObjSize > LONGINT(0) THEN
    Files.WriteDWord(dst, LONGINT(1))          (* page 1 (1-based page number into data pages) *)
  END;
  IF dataObjSize > LONGINT(0) THEN
    IF codeObjSize > LONGINT(0) THEN Files.WriteDWord(dst, LONGINT(2))
    ELSE Files.WriteDWord(dst, LONGINT(1))
    END
  END;

  (* ---- Entry Table: single bundle, one 32-bit entry named "start" is
     NOT required (Resident Name Table below carries the module name, not
     per-entry names) -- emit a single unnamed 32-bit entry so EIP object
     is valid, then terminate. ---- *)
  Files.WriteByte(dst, 1);                   (* bundle: 1 entry *)
  Files.WriteByte(dst, 3);                   (* type: 32-bit entry *)
  Files.WriteWord(dst, INTEGER(entryObj));   (* object number *)
  Files.WriteByte(dst, 1);                   (* flags: exported *)
  Files.WriteDWord(dst, entryOfs);           (* offset in object *)
  Files.WriteByte(dst, 0);                   (* terminating bundle: count=0 *)

  (* ---- Resident Name Table: empty (length-0 terminator only) ---- *)
  Files.WriteByte(dst, 0);

  (* ---- data pages: pad to dataPageOfs, then one page per object ---- *)
  WHILE Files.Position(dst) < dataPageOfs DO Files.WriteByte(dst, 0) END;
  IF codeObjSize > LONGINT(0) THEN
    Files.BlockWrite(dst, img.codeBuf^, WORD(codeObjSize))
  END;
  IF dataObjSize > LONGINT(0) THEN
    Files.BlockWrite(dst, img.dataBuf^, WORD(dataObjSize))
  END;

  FreeImage(img);
  RETURN TRUE
END RdfToLe;

(* =====================================================================
   PE (Portable Executable, PE32) writer
   Layout: MZ stub (64 bytes) -> "PE\0\0" -> COFF header -> Optional
   header (standard + Windows-specific + 16 data directories, all zero)
   -> section headers (.text, .data) -> section data.
   No .reloc/.idata/.edata sections: internal references were already
   resolved to final RVAs by Parse/ApplyRecords under a fixed
   ImageBasePE, so the image carries IMAGE_FILE_RELOCS_STRIPPED and an
   empty base-relocation data directory. ===== *)

PROCEDURE RdfToPe*(VAR src, dst: Files.File; stackSize: LONGINT): BOOLEAN;
  VAR img: Image;
      codeRva, dataRva: LONGINT;
      codeVSize, dataVSize: LONGINT;   (* virtual (unaligned) sizes; dataVSize includes stackSize *)
      codeRawSize, dataRawSize: LONGINT; (* file-aligned sizes (stack is not file-backed) *)
      dataRawVSize: LONGINT;           (* file-backed data+bss virtual size, excluding stack *)
      codeFileOfs, dataFileOfs: LONGINT;
      peHdrOfs, optHdrOfs, sectHdrOfs: LONGINT;
      sizeOfHeaders: LONGINT;
      sizeOfImage: LONGINT;
      nSections: INTEGER;
      entryRva: LONGINT;
      i: INTEGER;
BEGIN
  IF stackSize < LONGINT(0) THEN RETURN FALSE END;
  codeRva := Align(LONGINT(0), LONGINT(SecAlignPE)); (* placeholder, real value set after sizes known *)

  (* First pass just to get sizes: parse with codeRva=dataRva=0, then
     re-resolve final RVAs once the layout is fixed (two-pass keeps
     ApplyRecords ignorant of layout order). *)
  IF ~Parse(src, LONGINT(0), LONGINT(0), img) THEN RETURN FALSE END;

  codeVSize := img.codeLen;
  dataRawVSize := img.dataLen + img.bssLen;
  (* Per user direction: no dedicated stack -- extend the data section's
     in-memory (virtual) size by stackSize, same as growing BSS; the PE
     loader zero-fills VirtualSize beyond SizeOfRawData (sec "pe" Section
     header: raw data on disk may be smaller than the section's memory
     footprint), so this reserves stack space above the module's own
     data+bss without writing extra file bytes. *)
  dataVSize := dataRawVSize + stackSize;
  nSections := 0;
  IF codeVSize > LONGINT(0) THEN INC(nSections) END;
  IF dataVSize > LONGINT(0) THEN INC(nSections) END;
  IF nSections = 0 THEN FreeImage(img); RETURN FALSE END;

  peHdrOfs   := LONGINT(40H);   (* 64-byte MZ stub *)
  optHdrOfs  := peHdrOfs + LONGINT(24);      (* 4 (sig) + 20 (COFF header) *)
  sectHdrOfs := optHdrOfs + LONGINT(224);    (* opt header: 28+68+128 = 224 bytes (16 data dirs) *)
  sizeOfHeaders := Align(sectHdrOfs + LONGINT(nSections) * LONGINT(40), LONGINT(FileAlignPE));

  codeRva := LONGINT(0);
  dataRva := LONGINT(0);
  codeFileOfs := LONGINT(0);
  dataFileOfs := LONGINT(0);
  IF codeVSize > LONGINT(0) THEN
    codeRva := Align(LONGINT(SecAlignPE), LONGINT(SecAlignPE));  (* first section starts at 1*alignment *)
    codeFileOfs := sizeOfHeaders;
    codeRawSize := Align(codeVSize, LONGINT(FileAlignPE))
  ELSE
    codeRawSize := LONGINT(0)
  END;
  IF dataVSize > LONGINT(0) THEN
    IF codeVSize > LONGINT(0) THEN
      dataRva := codeRva + Align(codeVSize, LONGINT(SecAlignPE));
      dataFileOfs := codeFileOfs + codeRawSize
    ELSE
      dataRva := Align(LONGINT(SecAlignPE), LONGINT(SecAlignPE));
      dataFileOfs := sizeOfHeaders
    END;
    dataRawSize := Align(dataRawVSize, LONGINT(FileAlignPE))
  ELSE
    dataRawSize := LONGINT(0)
  END;

  (* Re-resolve fixups against the real section RVAs (pass 1 above used
     codeRva=dataRva=0; redo ApplyRecords now that layout is fixed).  The
     segment/global scan is deterministic given the same file, so simply
     re-run Parse fully rather than special-casing a second relocation
     pass over already-patched buffers. *)
  FreeImage(img);
  IF ~Parse(src, codeRva, dataRva, img) THEN RETURN FALSE END;

  IF img.startIsCode THEN entryRva := codeRva + img.startOfs
  ELSE entryRva := dataRva + img.startOfs
  END;

  IF codeVSize > LONGINT(0) THEN
    sizeOfImage := Align(codeRva + Align(codeVSize, LONGINT(SecAlignPE)), LONGINT(SecAlignPE))
  ELSE
    sizeOfImage := Align(dataRva, LONGINT(SecAlignPE))
  END;
  IF dataVSize > LONGINT(0) THEN
    sizeOfImage := Align(dataRva + Align(dataVSize, LONGINT(SecAlignPE)), LONGINT(SecAlignPE))
  END;

  (* ---- MZ stub (64 bytes, x00..x3F) ---- *)
  Files.WriteWord(dst, 5A4DH);      (* x00 'MZ' *)
  Files.WriteWord(dst, 0);          (* x02 bytes on last page *)
  Files.WriteWord(dst, 2);          (* x04 pages *)
  Files.WriteWord(dst, 0);          (* x06 relocations *)
  Files.WriteWord(dst, 2);          (* x08 header size, paragraphs *)
  Files.WriteWord(dst, 0);          (* x0A min alloc *)
  Files.WriteWord(dst, 0FFFFH);     (* x0C max alloc *)
  Files.WriteWord(dst, 0);          (* x0E SS *)
  Files.WriteWord(dst, 0);          (* x10 SP *)
  Files.WriteWord(dst, 0);          (* x12 checksum *)
  Files.WriteWord(dst, 0);          (* x14 IP *)
  Files.WriteWord(dst, 0);          (* x16 CS *)
  Files.WriteWord(dst, 40H);        (* x18 reloc table offset: should be 0x0040 *)
  Files.WriteWord(dst, 0);          (* x1A overlay *)
  i := 0;
  WHILE i < 4 DO Files.WriteWord(dst, 0); INC(i) END;  (* x1C..x23 reserved *)
  Files.WriteWord(dst, 0);          (* x24 OEM id *)
  Files.WriteWord(dst, 0);          (* x26 OEM info *)
  i := 0;
  WHILE i < 10 DO Files.WriteWord(dst, 0); INC(i) END;  (* x28..x3B reserved *)
  Files.WriteDWord(dst, peHdrOfs);  (* x3C: e_lfanew, offset to "PE\0\0" signature *)

  (* ---- Signature ---- *)
  Files.WriteByte(dst, ORD("P")); Files.WriteByte(dst, ORD("E"));
  Files.WriteByte(dst, 0); Files.WriteByte(dst, 0);

  (* ---- COFF File Header ---- *)
  Files.WriteWord(dst, 014CH);               (* machine: Intel 386 *)
  Files.WriteWord(dst, INTEGER(nSections));  (* number of sections *)
  Files.WriteDWord(dst, LONGINT(0));         (* timestamp *)
  Files.WriteDWord(dst, LONGINT(0));         (* symbol table offset *)
  Files.WriteDWord(dst, LONGINT(0));         (* number of symbols *)
  Files.WriteWord(dst, 224);                 (* size of optional header *)
  Files.WriteWord(dst, INTEGER(SYSTEM.LSL(1, 1) + SYSTEM.LSL(1, 2) + SYSTEM.LSL(1, 8) + SYSTEM.LSL(1, 0)));
                                              (* characteristics: EXECUTABLE_IMAGE(2)+LINE_NUMS_STRIPPED(4)+32BIT(0x100)+RELOCS_STRIPPED(1) *)

  (* ---- Optional Header: standard fields ---- *)
  Files.WriteWord(dst, 010BH);               (* magic: PE32 *)
  Files.WriteByte(dst, 1);                   (* major linker version *)
  Files.WriteByte(dst, 0);                   (* minor linker version *)
  Files.WriteDWord(dst, codeVSize);          (* size of code *)
  Files.WriteDWord(dst, dataVSize);          (* size of initialized data *)
  Files.WriteDWord(dst, LONGINT(0));         (* size of uninitialized data (bss folded into data section above) *)
  Files.WriteDWord(dst, entryRva);           (* entry point RVA *)
  IF codeVSize > LONGINT(0) THEN Files.WriteDWord(dst, codeRva) ELSE Files.WriteDWord(dst, LONGINT(0)) END; (* base of code *)
  IF dataVSize > LONGINT(0) THEN Files.WriteDWord(dst, dataRva) ELSE Files.WriteDWord(dst, LONGINT(0)) END; (* base of data *)

  (* ---- Optional Header: Windows-specific fields ---- *)
  Files.WriteDWord(dst, LONGINT(ImageBasePE));
  Files.WriteDWord(dst, LONGINT(SecAlignPE));
  Files.WriteDWord(dst, LONGINT(FileAlignPE));
  Files.WriteWord(dst, 4);                   (* OS major *)
  Files.WriteWord(dst, 0);                   (* OS minor *)
  Files.WriteWord(dst, 0);                   (* image major *)
  Files.WriteWord(dst, 0);                   (* image minor *)
  Files.WriteWord(dst, 4);                   (* subsystem major *)
  Files.WriteWord(dst, 0);                   (* subsystem minor *)
  Files.WriteDWord(dst, LONGINT(0));         (* Win32 version *)
  Files.WriteDWord(dst, sizeOfImage);        (* size of image *)
  Files.WriteDWord(dst, sizeOfHeaders);      (* size of headers *)
  Files.WriteDWord(dst, LONGINT(0));         (* checksum *)
  Files.WriteWord(dst, 3);                   (* subsystem: character mode *)
  Files.WriteWord(dst, 0);                   (* DLL characteristics *)
  IF stackSize > LONGINT(0) THEN Files.WriteDWord(dst, stackSize) ELSE Files.WriteDWord(dst, LONGINT(100000H)) END; (* stack reserve *)
  Files.WriteDWord(dst, LONGINT(1000H));     (* stack commit *)
  Files.WriteDWord(dst, LONGINT(100000H));   (* heap reserve *)
  Files.WriteDWord(dst, LONGINT(1000H));     (* heap commit *)
  Files.WriteDWord(dst, LONGINT(0));         (* loader flags *)
  Files.WriteDWord(dst, LONGINT(16));        (* number of data directories *)

  (* ---- Optional Header: data directories (16 * 8 bytes, all empty) ---- *)
  i := 0;
  WHILE i < 16 DO
    Files.WriteDWord(dst, LONGINT(0));
    Files.WriteDWord(dst, LONGINT(0));
    INC(i)
  END;

  (* ---- Section headers ---- *)
  IF codeVSize > LONGINT(0) THEN
    Files.Write(dst, ".text");
    Files.WriteByte(dst, 0); Files.WriteByte(dst, 0); Files.WriteByte(dst, 0);  (* pad name to 8 *)
    Files.WriteDWord(dst, codeVSize);        (* virtual size *)
    Files.WriteDWord(dst, codeRva);          (* virtual address *)
    Files.WriteDWord(dst, codeRawSize);      (* size of raw data *)
    Files.WriteDWord(dst, codeFileOfs);      (* pointer to raw data *)
    Files.WriteDWord(dst, LONGINT(0));       (* relocations ptr *)
    Files.WriteDWord(dst, LONGINT(0));       (* line numbers ptr *)
    Files.WriteWord(dst, 0);                 (* number of relocations *)
    Files.WriteWord(dst, 0);                 (* number of line numbers *)
    Files.WriteDWord(dst, LONGINT(60000020H)) (* CNT_CODE + MEM_EXECUTE + MEM_READ *)
  END;
  IF dataVSize > LONGINT(0) THEN
    Files.Write(dst, ".data");
    Files.WriteByte(dst, 0); Files.WriteByte(dst, 0); Files.WriteByte(dst, 0);
    Files.WriteDWord(dst, dataVSize);
    Files.WriteDWord(dst, dataRva);
    Files.WriteDWord(dst, dataRawSize);
    Files.WriteDWord(dst, dataFileOfs);
    Files.WriteDWord(dst, LONGINT(0));
    Files.WriteDWord(dst, LONGINT(0));
    Files.WriteWord(dst, 0);
    Files.WriteWord(dst, 0);
    Files.WriteDWord(dst, LONGINT(0C0000040H)) (* CNT_INITIALIZED_DATA + MEM_READ + MEM_WRITE *)
  END;

  (* ---- section data, file-aligned ---- *)
  WHILE Files.Position(dst) < sizeOfHeaders DO Files.WriteByte(dst, 0) END;
  IF codeVSize > LONGINT(0) THEN
    Files.BlockWrite(dst, img.codeBuf^, WORD(codeVSize));
    WHILE Files.Position(dst) < codeFileOfs + codeRawSize DO Files.WriteByte(dst, 0) END
  END;
  IF dataVSize > LONGINT(0) THEN
    IF dataRawVSize > LONGINT(0) THEN
      Files.BlockWrite(dst, img.dataBuf^, WORD(dataRawVSize))
    END;
    WHILE Files.Position(dst) < dataFileOfs + dataRawSize DO Files.WriteByte(dst, 0) END
  END;

  FreeImage(img);
  RETURN TRUE
END RdfToPe;

END RdfExe.
