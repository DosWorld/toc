(*D+*)
MODULE Rdoff;
(*
  RDOFF2 read/write module for the compiler and linker.

  Writer side: ObjFile record, Emit*, Patch*, RdfInit/Free/Write/Load.
  Reader side: ScanHeader, ScanRelocs, ReadCode, ReadData (callback-based).
*)
IMPORT Files, LogErr, Strings;

CONST
  SegCode* = 0;
  SegData* = 1;
  SegBss*  = 2;

  MaxName*     = 34;      (* link symbol = module(<=8) + "_" + ident(<=24) + 0X *)
  SegLimit*    = 65000;

  RecReloc*    = 1;
  RecImport*   = 2;
  RecGlobal*   = 3;
  RecBss*      = 5;
  RecSegreloc* = 6;

CONST
  RelocChunk = 256;   (* relocations per chunk node (amortizes 16-byte heap header) *)

TYPE
  (* Chunked relocation list: each node carries up to RelocChunk relocations in
     parallel arrays (count tracks how many used).  Parser emits ~1700 relocs;
     one node per reloc would waste ~27 KB in heap-block headers alone. *)
  RelocNode* = POINTER TO RelocNodeDesc;
  RelocNodeDesc* = RECORD
    physSeg*: ARRAY RelocChunk OF BYTE;
    offset*:  ARRAY RelocChunk OF LONGINT;
    width*:   ARRAY RelocChunk OF BYTE;
    rseg*:    ARRAY RelocChunk OF INTEGER;
    count*:   INTEGER;
    next*:    RelocNode
  END;

  ImportNode* = POINTER TO ImportNodeDesc;
  ImportNodeDesc* = RECORD
    flags*:  BYTE;
    segId*:  INTEGER;
    name*:   ARRAY MaxName OF CHAR;
    next*:   ImportNode
  END;

  GlobalNode* = POINTER TO GlobalNodeDesc;
  GlobalNodeDesc* = RECORD
    flags*:  BYTE;
    segId*:  BYTE;
    offset*: LONGINT;
    name*:   ARRAY MaxName OF CHAR;
    next*:   GlobalNode
  END;

  ObjFileRec* = RECORD
    codeFile*: Files.File;
    (* bigopt QW1: codeLen/dataLen are bounded by SegLimit (65000, checked in
       RdfWriteTo) so they fit in a WORD (max 65535).  Keeping them WORD makes the per-byte
       INC in EmitByte a 16-bit increment instead of a 32-bit add.  Every reader
       that needs LONGINT (wire writes via Wd, the CodeLen/DataLen accessors,
       BlockCopy counts) wraps with LONGINT() so the on-disk format and the
       LONGINT-returning API are byte-for-byte unchanged. *)
    codeLen*:  WORD;
    dataFile*: Files.File;
    dataLen*:  WORD;
    bssSize*:  LONGINT;
    relocHead*, relocTail*: RelocNode;
    nRelocs*:  INTEGER;
    importHead*, importTail*: ImportNode;
    nImports*: INTEGER;
    globalHead*, globalTail*: GlobalNode;
    nGlobals*: INTEGER;
    nextImportId*: INTEGER
  END;

  ObjFile* = POINTER TO ObjFileRec;

  (* 64KB segment buffer — used by the linker for code/data buffers.
     SYSTEM.ADDRESS (a raw far pointer), not POINTER TO ARRAY: callers in
     LINK.MOD must be updated to use SYSTEM.PUT/GET or ADR-based addressing
     and a raw allocation mechanism instead of NEW/array-index/BlockWrite
     syntax — that follow-up rewrite is NOT done as part of this change. *)
  SegBuf* = SYSTEM.ADDRESS;

  (* Callbacks for ScanHeader and ScanRelocs. *)
  GlobalProc* = PROCEDURE(name: ARRAY OF CHAR; seg: INTEGER; ofs: LONGINT);
  ImportProc* = PROCEDURE(flag: INTEGER; segId: INTEGER; name: ARRAY OF CHAR);
  RelocProc*  = PROCEDURE(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                           rrefSeg: INTEGER; rrel: INTEGER);

(* Error reporting goes through module LogErr (the single error state for the whole
   toolchain).  A failure inside a hot per-byte path (EmitByte, RdfSetBss) or a
   reader cannot abort the process — the only SYSTEM.Halt lives in TOC.Run.
   LogErr.Error/Error2 latch the error; callers check LogErr.HaveErr() at a boundary. *)

(* ---- write helpers ---- *)

PROCEDURE Ws(VAR f: Files.File; VAR s: ARRAY OF CHAR);
BEGIN
  Files.BlockWrite(f, s[0], Strings.Length(s) + 1)
END Ws;

(* ---- read helpers ---- *)

PROCEDURE Rs(VAR f: Files.File; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER; c: BYTE;
BEGIN
  i := 0;
  REPEAT
    Files.ReadByte(f, c);
    IF i < LEN(s) - 1 THEN s[i] := CHR(c) END;
    INC(i)
  UNTIL c = 0;
  IF i - 1 < LEN(s) THEN s[i - 1] := 0X ELSE s[LEN(s) - 1] := 0X END;
  RETURN TRUE
END Rs;

(* Copy n bytes from src (positioned at start) to dst using a stack buffer. *)
PROCEDURE AddRelocNode(obj: ObjFile; physSeg: BYTE; offset: LONGINT;
                       width: BYTE; rseg: INTEGER);
  VAR r: RelocNode; k: INTEGER;
BEGIN
  (* append to the tail chunk; allocate a fresh chunk only when it fills *)
  IF (obj^.relocTail = NIL) OR (obj^.relocTail^.count >= RelocChunk) THEN
    NEW(r);
    IF r = NIL THEN
      (* Fatal-NEW rule: a NIL far write lands in the IVT.  Latch and drop the
         reloc; the compile dies at the next LogErr boundary. *)
      LogErr.Error("out of memory (reloc chunk)"); RETURN
    END;
    r^.count := 0; r^.next := NIL;
    IF obj^.relocTail # NIL THEN obj^.relocTail^.next := r ELSE obj^.relocHead := r END;
    obj^.relocTail := r
  END;
  r := obj^.relocTail; k := r^.count;
  r^.physSeg[k] := physSeg; r^.offset[k] := offset;
  r^.width[k] := width; r^.rseg[k] := rseg;
  INC(r^.count);
  INC(obj^.nRelocs)
END AddRelocNode;

(* ---- public writer procedures ---- *)

(* RdfInit: prepare an ObjFile for writing — opens temp files for the code
   and data segments and resets all counters/lists to empty.
   Parameters: obj — the object file to initialize.
   Result: none. *)
PROCEDURE RdfInit*(obj: ObjFile);
BEGIN
  IF ~Files.ReWriteTemp(obj^.codeFile) THEN
    LogErr.Error("cannot create temp buffer for code"); RETURN
  END;
  IF ~Files.ReWriteTemp(obj^.dataFile) THEN
    Files.Close(obj^.codeFile); LogErr.Error("cannot create temp buffer for data"); RETURN
  END;
  obj^.codeLen := 0; obj^.dataLen := 0; obj^.bssSize := 0;
  obj^.relocHead := NIL; obj^.relocTail := NIL; obj^.nRelocs := 0;
  obj^.importHead := NIL; obj^.importTail := NIL; obj^.nImports := 0;
  obj^.globalHead := NIL; obj^.globalTail := NIL; obj^.nGlobals := 0;
  obj^.nextImportId := 3
END RdfInit;

(* RdfFree: release all resources held by an ObjFile — closes the code/data
   temp files and disposes the relocation, import and global node chains.
   Parameters: obj — the object file to release.
   Result: none. *)
PROCEDURE RdfFree*(obj: ObjFile);
  VAR r, rn: RelocNode; imp, in: ImportNode; g, gn: GlobalNode;
BEGIN
  Files.Close(obj^.codeFile);
  Files.Close(obj^.dataFile);
  r := obj^.relocHead;
  WHILE r # NIL DO rn := r^.next; DISPOSE(r); r := rn END;
  obj^.relocHead := NIL; obj^.relocTail := NIL;
  imp := obj^.importHead;
  WHILE imp # NIL DO in := imp^.next; DISPOSE(imp); imp := in END;
  obj^.importHead := NIL; obj^.importTail := NIL;
  g := obj^.globalHead;
  WHILE g # NIL DO gn := g^.next; DISPOSE(g); g := gn END;
  obj^.globalHead := NIL; obj^.globalTail := NIL
END RdfFree;

(* CodeLen: current length of the code segment being built.
   Parameters: obj — the object file.
   Result: number of bytes emitted to the code segment so far. *)
PROCEDURE CodeLen*(obj: ObjFile): LONGINT;
BEGIN RETURN LONGINT(obj^.codeLen) END CodeLen;

(* DataLen: current length of the data segment being built.
   Parameters: obj — the object file.
   Result: number of bytes emitted to the data segment so far. *)
PROCEDURE DataLen*(obj: ObjFile): LONGINT;
BEGIN RETURN LONGINT(obj^.dataLen) END DataLen;

(* EmitByte is the hottest path in codegen (one call per emitted byte).
   bigopt I1: the code/data files are always at their append position (codeLen/
   dataLen) when EmitByte runs — PatchCodeByte and Peek*Byte both seek back to
   the append position after touching the file (see below).  So EmitByte just
   Files.WriteByte at the current position: no per-byte Files.Seek, no
   BlockWrite(…,1) chunk machinery, and the in-buffer offset math is WORD.
   The per-byte SegLimit overflow check stays out (RdfWrite validates once).
   Parameters: obj — the object file being built; seg — target segment
   (SegCode or SegData); b — the byte to emit.
   Result: none. *)
PROCEDURE EmitByte*(obj: ObjFile; seg: INTEGER; b: BYTE);
BEGIN
  (* The WORD counters must not wrap silently: a module emitting > 64 KB of
     code purely through EmitByte would wrap codeLen past 65535 and sneak a
     falsely-small value past RdfWriteTo's one-shot >= SegLimit check,
     producing a corrupt .rdf instead of an error.  The guard is a WORD
     compare + INC — cheap even on this hottest path. *)
  IF seg = SegCode THEN
    Files.WriteByte(obj^.codeFile, b);
    IF obj^.codeLen >= WORD(SegLimit) THEN
      LogErr.Error("error: code segment exceeds limit")
    ELSE INC(obj^.codeLen) END
  ELSE
    Files.WriteByte(obj^.dataFile, b);
    IF obj^.dataLen >= WORD(SegLimit) THEN
      LogErr.Error("error: data segment exceeds limit")
    ELSE INC(obj^.dataLen) END
  END
END EmitByte;

PROCEDURE emitN(obj: ObjFile; seg: INTEGER; b1, b2, b3, b4: BYTE; n: INTEGER);
BEGIN
  IF seg = SegCode THEN
    Files.WriteByte(obj^.codeFile, b1);
    Files.WriteByte(obj^.codeFile, b2);
    IF n >= 3 THEN Files.WriteByte(obj^.codeFile, b3) END;
    IF n >= 4 THEN Files.WriteByte(obj^.codeFile, b4) END;
    (* Guard the WORD counter against silent wrap before it happens (a wrap
       here would let a >64K-byte segment sneak past RdfWriteTo's one-shot
       >= SegLimit check with a falsely-small wrapped value). *)
    IF LONGINT(obj^.codeLen) + LONGINT(n) > LONGINT(SegLimit) THEN
      LogErr.Error("error: code segment exceeds limit")
    ELSE INC(obj^.codeLen, n) END
  ELSE
    Files.WriteByte(obj^.dataFile, b1);
    Files.WriteByte(obj^.dataFile, b2);
    IF n >= 3 THEN Files.WriteByte(obj^.dataFile, b3) END;
    IF n >= 4 THEN Files.WriteByte(obj^.dataFile, b4) END;
    IF LONGINT(obj^.dataLen) + LONGINT(n) > LONGINT(SegLimit) THEN
      LogErr.Error("error: data segment exceeds limit")
    ELSE INC(obj^.dataLen, n) END
  END
END emitN;

(* EmitByte2: emit two bytes in sequence to a segment.
   Parameters: obj — the object file being built; seg — target segment
   (SegCode or SegData); b1, b2 — the bytes to emit, in order.
   Result: none. *)
PROCEDURE EmitByte2*(obj: ObjFile; seg: INTEGER; b1, b2: BYTE);
BEGIN
  emitN(obj, seg, b1, b2, 0, 0, 2)
END EmitByte2;

(* EmitByte3: emit three bytes in sequence to a segment.
   Parameters: obj — the object file being built; seg — target segment
   (SegCode or SegData); b1, b2, b3 — the bytes to emit, in order.
   Result: none. *)
PROCEDURE EmitByte3*(obj: ObjFile; seg: INTEGER; b1, b2, b3: BYTE);
BEGIN
  emitN(obj, seg, b1, b2, b3, 0, 3)
END EmitByte3;

(* EmitWord: emit a 16-bit word to a segment, updating the segment's length
   counter (with SegLimit overflow check).
   Parameters: obj — the object file being built; seg — target segment
   (SegCode or SegData); w — the word value to emit.
   Result: none. *)
PROCEDURE EmitWord*(obj: ObjFile; seg: INTEGER; w: INTEGER);
BEGIN
  IF seg = SegCode THEN
    Files.WriteWord(obj^.codeFile, w);
    IF LONGINT(obj^.codeLen) + LONGINT(2) > LONGINT(SegLimit) THEN
      LogErr.Error("error: code segment exceeds limit")
    ELSE INC(obj^.codeLen, 2) END
  ELSE
    Files.WriteWord(obj^.dataFile, w);
    IF LONGINT(obj^.dataLen) + LONGINT(2) > LONGINT(SegLimit) THEN
      LogErr.Error("error: data segment exceeds limit")
    ELSE INC(obj^.dataLen, 2) END
  END
END EmitWord;

(* EmitBlock: emit a block of raw bytes to a segment in one write, updating
   the segment's length counter (with SegLimit overflow check).
   Parameters: obj — the object file being built; seg — target segment
   (SegCode or SegData); buf — the source buffer; len — number of bytes to
   copy from buf.
   Result: none. *)
PROCEDURE EmitBlock*(obj: ObjFile; seg: INTEGER; VAR buf; len : WORD);
BEGIN
  IF seg = SegCode THEN
    Files.BlockWrite(obj^.codeFile, buf^, len);
    IF LONGINT(obj^.codeLen) + LONGINT(len) > LONGINT(SegLimit) THEN
      LogErr.Error("error: code segment exceeds limit")
    ELSE INC(obj^.codeLen, len) END
  ELSE
    Files.BlockWrite(obj^.dataFile, buf^, len);
    IF LONGINT(obj^.dataLen) + LONGINT(len) > LONGINT(SegLimit) THEN
      LogErr.Error("error: data segment exceeds limit")
    ELSE INC(obj^.dataLen, len) END
  END
END EmitBlock;

(* EmitZero: emit n zero bytes to the data segment (used to zero-fill global
   array/record storage), updating the data length counter.
   Parameters: obj — the object file being built; n — number of zero bytes
   to emit.
   Result: none. *)
PROCEDURE EmitZero*(obj: ObjFile; n: LONGINT);
  VAR buf : ARRAY 128 OF BYTE;
BEGIN
  SYSTEM.FILL(buf, 128, 0);
  (* Guard against the WORD counter wrapping silently past SegLimit before
     truncating n into it (n can be large: this zero-fills a whole global
     array's worth of data-segment bytes in one call). *)
  IF LONGINT(obj^.dataLen) + n > LONGINT(SegLimit) THEN
    LogErr.Error("error: data segment exceeds limit"); RETURN
  END;
  INC(obj^.dataLen, WORD(n));   (* count the zero-fill bytes so RdfWrite copies them *)
  WHILE n > 128 DO
    Files.BlockWrite(obj^.dataFile, buf, 128);
    DEC(n, 128)
  END;
  Files.BlockWrite(obj^.dataFile, buf, WORD(n))
END EmitZero;

(* PatchCodeByte: overwrite a single byte at an earlier offset in the code
   segment (e.g. backpatching a jump target), then restore the file position
   so the next EmitByte still appends correctly.
   Parameters: obj — the object file being built; offset — byte offset
   within the code segment to overwrite; b — the new byte value.
   Result: none. *)
PROCEDURE PatchCodeByte*(obj: ObjFile; offset: LONGINT; b: BYTE);
  VAR tmp: BYTE; save: LONGINT;
BEGIN
  tmp := b;
  (* bigopt I1: EmitByte writes at the current position with no per-byte Seek,
     so any out-of-sequence write must save the current position and restore it
     on exit (do not assume it is codeLen — a patch may run mid-Peek). *)
  save := Files.Position(obj^.codeFile);
  Files.Seek(obj^.codeFile, offset);
  Files.BlockWrite(obj^.codeFile, tmp, 1);
  Files.Seek(obj^.codeFile, save)
END PatchCodeByte;

(* PeekCodeByte: read back a single byte previously written to the code
   segment, without disturbing the current append position.
   Parameters: obj — the object file being built; offset — byte offset
   within the code segment to read.
   Result: the byte at offset, or 0 if offset is out of range. *)
PROCEDURE PeekCodeByte*(obj: ObjFile; offset: LONGINT): BYTE;
  VAR tmp: BYTE; save: LONGINT;
BEGIN
  tmp := 0;
  IF (offset >= 0) & (offset < LONGINT(obj^.codeLen)) THEN
    save := Files.Position(obj^.codeFile);
    Files.Seek(obj^.codeFile, offset);
    Files.BlockRead(obj^.codeFile, tmp, 1);
    Files.Seek(obj^.codeFile, save)
  END;
  RETURN tmp
END PeekCodeByte;

(* PeekDataByte: read back a single byte previously written to the data
   segment, without disturbing the current append position.
   Parameters: obj — the object file being built; offset — byte offset
   within the data segment to read.
   Result: the byte at offset, or 0 if offset is out of range. *)
PROCEDURE PeekDataByte*(obj: ObjFile; offset: LONGINT): BYTE;
  VAR tmp: BYTE; save: LONGINT;
BEGIN
  tmp := 0;
  IF (offset >= 0) & (offset < LONGINT(obj^.dataLen)) THEN
    save := Files.Position(obj^.dataFile);
    Files.Seek(obj^.dataFile, offset);
    Files.ReadByte(obj^.dataFile, tmp);
    Files.Seek(obj^.dataFile, save)
  END;
  RETURN tmp
END PeekDataByte;

(* RdfFindImport: look up an existing import entry by name.
   Parameters: obj — the object file being built; name — the imported
   symbol's link name to search for.
   Result: the import's RDOFF2 segment ID if found, otherwise -1. *)
PROCEDURE RdfFindImport*(obj: ObjFile; name: ARRAY OF CHAR): INTEGER;
  VAR imp: ImportNode;
BEGIN
  imp := obj^.importHead;
  WHILE imp # NIL DO
    IF Strings.Equal(imp^.name, name) THEN RETURN imp^.segId END;
    imp := imp^.next
  END;
  RETURN -1
END RdfFindImport;

(* RdfAddImport: add a new import entry, allocating it the next free
   RDOFF2 segment ID.
   Parameters: obj — the object file being built; name — the imported
   symbol's link name.
   Result: the newly assigned segment ID for this import. *)
PROCEDURE RdfAddImport*(obj: ObjFile; name: ARRAY OF CHAR): INTEGER;
  VAR imp: ImportNode;
BEGIN
  NEW(imp);
  IF imp = NIL THEN
    LogErr.Error("out of memory (import record)"); RETURN -1
  END;
  imp^.flags := BYTE(0);
  imp^.segId := obj^.nextImportId; INC(obj^.nextImportId);
  Strings.Copy(name, imp^.name);
  imp^.next := NIL;
  IF obj^.importTail # NIL THEN obj^.importTail^.next := imp
  ELSE obj^.importHead := imp
  END;
  obj^.importTail := imp;
  INC(obj^.nImports);
  RETURN imp^.segId
END RdfAddImport;

(* RdfAddGlobal: add a new exported-symbol (global) entry.
   Parameters: obj — the object file being built; name — the exported
   symbol's link name; segId — which physical segment the symbol lives in
   (SegCode/SegData/SegBss); offset — the symbol's byte offset within that
   segment.
   Result: none. *)
PROCEDURE RdfAddGlobal*(obj: ObjFile; name: ARRAY OF CHAR; segId: BYTE; offset: LONGINT);
  VAR g: GlobalNode;
BEGIN
  NEW(g);
  IF g = NIL THEN
    LogErr.Error("out of memory (global record)"); RETURN
  END;
  (* flags=0 matches real NASM's RDOFF2 writer (verified against
     SRC/LIB/SYSTEM.RDF); LINK.MOD never reads this byte (grep found zero
     references), so the value has no linking effect either way -- kept at
     0 purely so a TASM-produced .rdf can byte-diff against a NASM oracle. *)
  g^.flags := BYTE(0);
  g^.segId := segId; g^.offset := offset;
  Strings.Copy(name, g^.name);
  g^.next := NIL;
  IF obj^.globalTail # NIL THEN obj^.globalTail^.next := g
  ELSE obj^.globalHead := g
  END;
  obj^.globalTail := g;
  INC(obj^.nGlobals)
END RdfAddGlobal;

(* RdfAddReloc: record a relocation against a symbol/import (RecReloc).
   Parameters: obj — the object file being built; physSeg — which physical
   segment the relocation site is in; offset — byte offset of the
   relocation site within that segment; width — size in bytes of the field
   to patch; rseg — the RDOFF2 import/segment ID being referenced;
   relative — TRUE if the reference is PC-relative (sets the high relative
   flag bit on the stored physical-segment byte).
   Result: none. *)
PROCEDURE RdfAddReloc*(obj: ObjFile; physSeg: INTEGER; offset: LONGINT;
                       width: INTEGER; rseg: INTEGER; relative: BOOLEAN);
  VAR ps: BYTE;
BEGIN
  ps := BYTE(physSeg);
  IF relative THEN ps := BYTE(INTEGER(ps) + 40H) END;
  AddRelocNode(obj, ps, offset, BYTE(width), rseg)
END RdfAddReloc;

(* RdfAddSegReloc: record a segment-relocation (RecSegreloc) — a fixup that
   patches a segment/paragraph value rather than an offset.
   Parameters: obj — the object file being built; physSeg — which physical
   segment the relocation site is in; offset — byte offset of the
   relocation site within that segment; rseg — the RDOFF2 import/segment ID
   being referenced.
   Result: none. *)
PROCEDURE RdfAddSegReloc*(obj: ObjFile; physSeg: INTEGER; offset: LONGINT;
                          rseg: INTEGER);
  VAR ps: BYTE;
BEGIN
  ps := BYTE(INTEGER(BYTE(physSeg)) + 80H);
  AddRelocNode(obj, ps, offset, BYTE(2), rseg)
END RdfAddSegReloc;

(* RdfSetBss: set the size of the module's uninitialized (BSS) data area.
   Parameters: obj — the object file being built; size — number of bytes
   of zero-initialized storage to reserve.
   Result: none. *)
PROCEDURE RdfSetBss*(obj: ObjFile; size: LONGINT);
BEGIN
  (* Overflow sets the latch (surfaced at the RdfWrite boundary); cannot Halt. *)
  IF size > LONGINT(SegLimit) THEN LogErr.Error("error: bss segment exceeds limit") END;
  obj^.bssSize := size
END RdfSetBss;

(* RdfWriteTo: serialise the object into an already-open, rewound file `f`.
   The caller owns `f` (it is NOT closed here).  Used for both the named-file
   path (RdfWrite) and the temp-file path (Parser streams the temp into the .om
   without ever naming it on disk).
   Parameters: obj — the object file to serialise; f — an already-open,
   rewound file to write the RDOFF2 image into.
   Result: none (failures latch via LogErr; check LogErr.HaveErr()). *)
PROCEDURE RdfWriteTo*(obj: ObjFile; VAR f: Files.File);
  VAR r: RelocNode; imp: ImportNode; g: GlobalNode;
      hlen, modSize: LONGINT;
      nlen, k: INTEGER;
      cpOk: BOOLEAN;
BEGIN
  (* Segment-limit check (moved out of the per-byte EmitByte path).  An overflow
     here means codegen produced a >SegLimit segment; latch and bail. *)
  IF obj^.codeLen >= WORD(SegLimit) THEN
    LogErr.Error("error: code segment exceeds limit"); RETURN
  END;
  IF obj^.dataLen >= WORD(SegLimit) THEN
    LogErr.Error("error: data segment exceeds limit"); RETURN
  END;
  (* A failure latched during code emission (e.g. a write error in EmitByte's
     BlockWrite path) must not produce a truncated .rdf. *)
  IF LogErr.HaveErr() THEN RETURN END;

  hlen := 0;
  r := obj^.relocHead;
  WHILE r # NIL DO INC(hlen, LONGINT(r^.count) * LONGINT(10)); r := r^.next END;
  imp := obj^.importHead;
  WHILE imp # NIL DO
    nlen := Strings.Length(imp^.name);
    INC(hlen, LONGINT(5 + nlen + 1));
    imp := imp^.next
  END;
  g := obj^.globalHead;
  WHILE g # NIL DO
    nlen := Strings.Length(g^.name);
    INC(hlen, LONGINT(8 + nlen + 1));
    g := g^.next
  END;
  IF obj^.bssSize > 0 THEN INC(hlen, 6) END;

  modSize := LONGINT(14) + hlen + LONGINT(10) + LONGINT(obj^.codeLen) + LONGINT(10);
  INC(modSize, LONGINT(10) + LONGINT(obj^.dataLen));
  (* Real NASM's own RDOFF2 writer under-reports modSize by exactly 10
     bytes (the trailing type=0 EOF segment marker's own 10-byte header is
     always present on disk but excluded from the recorded module size) --
     verified against SYSTEM.RDF: both a NASM-built file and a from-scratch
     byte-count agree the real file is 10 bytes longer than its own
     modSize field claims.  DOCS/RDOFF2.MD doesn't document this as
     intentional, and no reader in this codebase (RdfLoad/ScanHeader) uses
     modSize for anything but bounding a header-record scan that already
     stops earlier at hlen, so it's inert either way -- kept bug-compatible
     purely so a TASM-produced .rdf can byte-diff against a NASM oracle. *)
  DEC(modSize, LONGINT(10));

  Files.Write(f, "RDOFF2");
  Files.WriteDWord(f, modSize);
  Files.WriteDWord(f, hlen);

  (* Record order: GLOBAL, then IMPORT, then RELOC/SEGRELOC (interleaved in
     original emission order), then BSS -- matches real NASM's own RDOFF2
     writer (verified against SRC/LIB/SYSTEM.RDF, an oracle built by real NASM:
     all GLOBAL records first, then the RELOC/SEGRELOC stream in emission
     order). The linker (ScanHeader/ScanRelocs) reads records by type, not
     position, so this ordering has no effect on linking -- it exists purely
     so a TASM-produced .rdf can byte-diff against a NASM-produced oracle. *)
  g := obj^.globalHead;
  WHILE g # NIL DO
    nlen := Strings.Length(g^.name);
    Files.WriteByte(f, BYTE(RecGlobal));
    Files.WriteByte(f, BYTE(6 + nlen + 1));
    Files.WriteByte(f, g^.flags);
    Files.WriteByte(f, g^.segId);
    Files.WriteDWord(f, g^.offset);
    Ws(f, g^.name);
    g := g^.next
  END;

  imp := obj^.importHead;
  WHILE imp # NIL DO
    nlen := Strings.Length(imp^.name);
    Files.WriteByte(f, BYTE(RecImport));
    Files.WriteByte(f, BYTE(3 + nlen + 1));
    Files.WriteByte(f, imp^.flags);
    Files.WriteWord(f, imp^.segId);
    Ws(f, imp^.name);
    imp := imp^.next
  END;

  r := obj^.relocHead;
  WHILE r # NIL DO
    k := 0;
    WHILE k < r^.count DO
      IF INTEGER(r^.physSeg[k]) >= 80H THEN
        Files.WriteByte(f, BYTE(RecSegreloc));
        Files.WriteByte(f, BYTE(8));
        Files.WriteByte(f, BYTE(INTEGER(r^.physSeg[k]) MOD 80H));
        Files.WriteDWord(f, r^.offset[k]);
        Files.WriteByte(f, r^.width[k]);
        Files.WriteWord(f, r^.rseg[k])
      ELSE
        Files.WriteByte(f, BYTE(RecReloc));
        Files.WriteByte(f, BYTE(8));
        Files.WriteByte(f, r^.physSeg[k]);
        Files.WriteDWord(f, r^.offset[k]);
        Files.WriteByte(f, r^.width[k]);
        Files.WriteWord(f, r^.rseg[k])
      END;
      INC(k)
    END;
    r := r^.next
  END;

  IF obj^.bssSize > 0 THEN
    Files.WriteByte(f, BYTE(RecBss));
    Files.WriteByte(f, BYTE(4));
    Files.WriteDWord(f, obj^.bssSize)
  END;

  Files.WriteWord(f, 1);
  Files.WriteWord(f, 0);
  Files.WriteWord(f, 0);
  Files.WriteDWord(f, LONGINT(obj^.codeLen));
  Files.Seek(obj^.codeFile, LONGINT(0));
  cpOk := Files.BlockCopy(obj^.codeFile, f, LONGINT(obj^.codeLen));

  (* real NASM always emits the .data segment header, even when dataLen=0
     (verified against DETECT.RDF, a real-NASM-built .text-only oracle) --
     the BlockCopy of zero bytes is a correct no-op either way. *)
  Files.WriteWord(f, 2);
  Files.WriteWord(f, 1);
  Files.WriteWord(f, 0);
  Files.WriteDWord(f, LONGINT(obj^.dataLen));
  IF obj^.dataLen > 0 THEN
    Files.Seek(obj^.dataFile, LONGINT(0));
    cpOk := cpOk & Files.BlockCopy(obj^.dataFile, f, LONGINT(obj^.dataLen))
  END;

  Files.WriteWord(f, 0);
  Files.WriteWord(f, 0);
  Files.WriteWord(f, 0);
  Files.WriteDWord(f, 0);
  IF ~cpOk THEN LogErr.Error("error: write failed serialising object") END
END RdfWriteTo;

(* Named-file wrapper: open `filename`, serialise, close.  Keeps OC's MAIN.RDF
   path (and any other by-name caller) unchanged.
   Parameters: obj — the object file to serialise; filename — path of the
   .rdf file to create.
   Result: none (failures latch via LogErr). *)
PROCEDURE RdfWrite*(obj: ObjFile; filename: ARRAY OF CHAR);
  VAR f: Files.File;
BEGIN
  IF LogErr.HaveErr() THEN RETURN END;
  IF ~Files.ReWrite(f, filename) THEN
    LogErr.Error2("error: cannot write ", filename); RETURN
  END;
  RdfWriteTo(obj, f);
  Files.Close(f)
END RdfWrite;

PROCEDURE CheckSign(VAR f : Files.File) : BOOLEAN;
  VAR sig: ARRAY 6 OF BYTE;
BEGIN
  IF Files.BlockRead(f, sig[0], 6) # WORD(6) THEN
    RETURN FALSE
  END;
  IF (sig[0] # BYTE(ORD("R"))) OR (sig[1] # BYTE(ORD("D"))) OR (sig[2] # BYTE(ORD("O"))) OR
     (sig[3] # BYTE(ORD("F"))) OR (sig[4] # BYTE(ORD("F"))) OR (sig[5] # BYTE(ORD("2"))) THEN
    RETURN FALSE
  END;
  RETURN TRUE
END CheckSign;

(* RdfLoad: read an entire RDOFF2 file into obj — resets obj, verifies the
   signature, replays the header records (relocations, imports, globals,
   bss) into obj's lists, and copies the code/data segment bodies into
   obj's code/data temp files.
   Parameters: obj — the object file to load into (re-initialised first);
   filename — path of the .rdf file to read.
   Result: TRUE if the file was opened, signed correctly, and fully copied;
   FALSE otherwise. *)
PROCEDURE RdfLoad*(obj: ObjFile; filename: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File;
      n: INTEGER;
      hlen, hdrConsumed, segLen: LONGINT;
      recType, recLen: BYTE;
      bodyStart: LONGINT;
      flags, segIdByte: BYTE;
      segIdWord: INTEGER;
      offset: LONGINT;
      name: ARRAY MaxName OF CHAR;
      imp: ImportNode;
      g: GlobalNode;
      physSeg, width: BYTE; rseg: INTEGER;
      ok, cpOk: BOOLEAN;
      segType: INTEGER;
      bssBytes: LONGINT;
BEGIN
  IF ~Files.Reset(f, filename) THEN RETURN FALSE END;
  RdfFree(obj); RdfInit(obj);
  IF LogErr.HaveErr() THEN Files.Close(f); RETURN FALSE END;

  IF ~CheckSign(f) THEN Files.Close(f); RETURN FALSE END;

  Files.ReadDWord(f, hlen);
  Files.ReadDWord(f, hlen);

  hdrConsumed := LONGINT(0);
  WHILE hdrConsumed < hlen DO
    Files.ReadByte(f, recType);
    Files.ReadByte(f, recLen);
    INC(hdrConsumed, LONGINT(2));
    bodyStart := Files.Position(f);

    IF INTEGER(recType) = RecReloc THEN
      Files.ReadByte(f, physSeg);
      Files.ReadDWord(f, offset);
      Files.ReadByte(f, width);
      Files.ReadWord(f, rseg);
      AddRelocNode(obj, physSeg, offset, width, rseg)
    ELSIF INTEGER(recType) = RecSegreloc THEN
      Files.ReadByte(f, physSeg);
      Files.ReadDWord(f, offset);
      Files.ReadByte(f, width);
      Files.ReadWord(f, rseg);
      AddRelocNode(obj, BYTE(SYSTEM.IOR(INTEGER(physSeg), 080H)), offset, width, rseg)
    ELSIF INTEGER(recType) = RecImport THEN
      Files.ReadByte(f, flags);
      Files.ReadWord(f, segIdWord);
      ok := Rs(f, name);
      NEW(imp);
      IF imp = NIL THEN
        LogErr.Error("out of memory (import record)");
        Files.Close(f); RETURN FALSE
      END;
      imp^.flags := flags; imp^.segId := segIdWord; imp^.next := NIL;
      n := 0;
      WHILE (n < MaxName - 1) & (name[n] # 0X) DO imp^.name[n] := name[n]; INC(n) END;
      imp^.name[n] := 0X;
      IF obj^.importHead = NIL THEN obj^.importHead := imp
      ELSE obj^.importTail^.next := imp END;
      obj^.importTail := imp; INC(obj^.nImports);
      IF segIdWord >= obj^.nextImportId THEN obj^.nextImportId := segIdWord + 1 END
    ELSIF INTEGER(recType) = RecGlobal THEN
      Files.ReadByte(f, flags);
      Files.ReadByte(f, segIdByte);
      Files.ReadDWord(f, offset);
      ok := Rs(f, name);
      NEW(g);
      IF g = NIL THEN
        LogErr.Error("out of memory (global record)");
        Files.Close(f); RETURN FALSE
      END;
      g^.flags := flags; g^.segId := segIdByte; g^.offset := offset; g^.next := NIL;
      n := 0;
      WHILE (n < MaxName - 1) & (name[n] # 0X) DO g^.name[n] := name[n]; INC(n) END;
      g^.name[n] := 0X;
      IF obj^.globalHead = NIL THEN obj^.globalHead := g
      ELSE obj^.globalTail^.next := g END;
      obj^.globalTail := g; INC(obj^.nGlobals)
    ELSIF INTEGER(recType) = RecBss THEN
      Files.ReadDWord(f, bssBytes);
      obj^.bssSize := bssBytes
    END;
    Files.Seek(f, bodyStart + LONGINT(recLen));
    INC(hdrConsumed, LONGINT(recLen))
  END;

  ok := TRUE; cpOk := TRUE;
  WHILE ok DO
    Files.ReadWord(f, segType);
    Files.ReadWord(f, n);
    Files.ReadWord(f, n);
    Files.ReadDWord(f, segLen);
    IF segType = 0 THEN ok := FALSE
    ELSIF segType = 1 THEN
      Files.Seek(obj^.codeFile, LONGINT(0));
      cpOk := Files.BlockCopy(f, obj^.codeFile, segLen);
      obj^.codeLen := WORD(segLen); ok := cpOk
    ELSIF segType = 2 THEN
      Files.Seek(obj^.dataFile, LONGINT(0));
      cpOk := Files.BlockCopy(f, obj^.dataFile, segLen);
      obj^.dataLen := WORD(segLen); ok := cpOk
    ELSE
      Files.Seek(f, Files.Position(f) + segLen)
    END
  END;

  Files.Close(f);
  RETURN cpOk
END RdfLoad;

(* ---- public reader/scanner procedures (linker side) ---- *)

(* The readers below use Files.mod's buffered ReadByte/ReadWord/ReadDWord
   directly.  The old Sr* reader (raw INT 21h + a hand-rolled 512-byte
   WORD-indexed buffer, UNBUFFERED relative to Files) was removed: it duplicated
   the buffering Files already provides and its WORD buffer arithmetic was a
   self-host miscompile hazard. *)

(*
  Scan the RDOFF2 header at 'path'+'libOfs'.
  Fills rawSize, hdrSize, codeSize, dataSize, bssSize.
  Calls onGlobal/onImport for each record (either may be NIL).

  Parameters: path — file to read; libOfs — byte offset within path where
  the RDOFF2 image starts (an .om archive member); rawSize — OUT: total
  module size from the header; hdrSize — OUT: size of the header-record
  area; codeSize, dataSize — OUT: code/data segment lengths found in the
  segment table; bssSize — OUT: total BSS bytes requested (summed over all
  RecBss records); onGlobal — callback invoked for each RecGlobal record
  (may be NIL); onImport — callback invoked for each RecImport record (may
  be NIL).
  Result: none (failures latch via LogErr).
*)

PROCEDURE ScanHeader*(VAR path: ARRAY OF CHAR; libOfs: LONGINT;
                      VAR rawSize, hdrSize, codeSize, dataSize, bssSize: LONGINT;
                      onGlobal: GlobalProc; onImport: ImportProc);
  VAR f: Files.File;
      recType, recLen: INTEGER;
      endHdr, nextRec: LONGINT;
      bssAmt: LONGINT;
      symSeg: INTEGER;
      symOfs: LONGINT;
      symName: ARRAY 128 OF CHAR;
      impFlg, impSeg: INTEGER;
      stype, dummy: INTEGER;
      slen, filePos: LONGINT;
      tb: BYTE;
BEGIN
  IF ~Files.Reset(f, path) THEN LogErr.Error2("Cannot open: ", path); RETURN END;
  Files.Seek(f, libOfs);
  IF ~CheckSign(f) THEN
    Files.Close(f); LogErr.Error2("Invalid RDOFF2 signature in ", path); RETURN
  END;

  Files.ReadDWord(f, rawSize);
  Files.ReadDWord(f, hdrSize);
  codeSize := 0; dataSize := 0; bssSize := 0;

  endHdr  := libOfs + LONGINT(14) + hdrSize;
  nextRec := libOfs + LONGINT(14);
  (* f is already positioned at nextRec (right after the 14-byte RDOFF2 header) *)

  WHILE nextRec < endHdr DO
    IF ~Files.ReadByte(f, tb) THEN nextRec := endHdr
    ELSE
      recType := INTEGER(tb);
      Files.ReadByte(f, tb); recLen := INTEGER(tb);
      nextRec := nextRec + LONGINT(2) + LONGINT(recLen);
      IF recType = RecGlobal THEN
        Files.ReadByte(f, tb);                       (* flags byte, unused *)
        Files.ReadByte(f, tb); symSeg := INTEGER(tb);
        Files.ReadDWord(f, symOfs);
        Files.ReadAsciizString(f, symName);
        IF onGlobal # NIL THEN onGlobal(symName, symSeg, symOfs) END
      ELSIF recType = RecBss THEN
        Files.ReadDWord(f, bssAmt); bssSize := bssSize + bssAmt
      ELSIF recType = RecImport THEN
        Files.ReadByte(f, tb); impFlg := INTEGER(tb);
        Files.ReadWord(f, impSeg);
        Files.ReadAsciizString(f, symName);
        IF onImport # NIL THEN onImport(impFlg, impSeg, symName) END
      END;
      Files.Seek(f, nextRec)
    END
  END;

  (* Segment table: each entry is type(2) num(2) reserved(2) length(4) = 10
     bytes, followed by `length` bytes of segment data. *)
  filePos := endHdr;
  Files.Seek(f, filePos);
  WHILE filePos < libOfs + rawSize DO
    Files.ReadWord(f, stype);              (* type *)
    IF stype <= 0 THEN filePos := libOfs + rawSize
    ELSE
      Files.ReadWord(f, dummy);            (* num (unused) *)
      Files.ReadWord(f, dummy);            (* reserved (unused) *)
      Files.ReadDWord(f, slen);            (* length *)
      IF stype = 1 THEN codeSize := slen
      ELSIF stype = 2 THEN dataSize := slen
      END;
      IF slen < LONGINT(0) THEN filePos := libOfs + rawSize
      ELSE
        filePos := filePos + LONGINT(10) + slen;
        Files.Seek(f, filePos)
      END
    END
  END;
  Files.Close(f)
END ScanHeader;

(*
  Walk all RDOFF2 header records at 'path'+'libOfs'.
  Calls onImport, onReloc, onSegReloc as appropriate (any may be NIL).

  Parameters: path — file to read; libOfs — byte offset within path where
  the RDOFF2 image starts; hdrSize — size of the header-record area (as
  filled by ScanHeader); onImport — callback invoked for each RecImport
  record (may be NIL); onReloc — callback invoked for each RecReloc record
  (may be NIL); onSegReloc — callback invoked for each RecSegreloc record
  (may be NIL).
  Result: none (failures latch via LogErr).
*)
PROCEDURE ScanRelocs*(VAR path: ARRAY OF CHAR; libOfs, hdrSize: LONGINT;
                      onImport: ImportProc;
                      onReloc: RelocProc; onSegReloc: RelocProc);
  VAR f: Files.File;
      recType, recLen: INTEGER;
      endHdr, nextRec: LONGINT;
      rseg, rwidth, rrel: INTEGER;
      rofs: LONGINT;
      rrefSeg: INTEGER;
      impFlg, impSeg: INTEGER;
      impName: ARRAY 128 OF CHAR;
      tb: BYTE;
BEGIN
  IF ~Files.Reset(f, path) THEN LogErr.Error2("Cannot open: ", path); RETURN END;
  endHdr  := libOfs + LONGINT(14) + hdrSize;
  nextRec := libOfs + LONGINT(14);
  Files.Seek(f, nextRec);

  WHILE nextRec < endHdr DO
    IF ~Files.ReadByte(f, tb) THEN nextRec := endHdr
    ELSE
      recType := INTEGER(tb);
      Files.ReadByte(f, tb); recLen := INTEGER(tb);
      nextRec := nextRec + LONGINT(2) + LONGINT(recLen);

      IF recType = RecImport THEN
        Files.ReadByte(f, tb); impFlg := INTEGER(tb);
        Files.ReadWord(f, impSeg);
        Files.ReadAsciizString(f, impName);
        IF onImport # NIL THEN onImport(impFlg, impSeg, impName) END
      ELSIF recType = RecReloc THEN
        Files.ReadByte(f, tb); rseg := INTEGER(tb);
        Files.ReadDWord(f, rofs);
        Files.ReadByte(f, tb); rwidth := INTEGER(tb);
        Files.ReadWord(f, rrefSeg);
        rrel := SYSTEM.AND(rseg, 40H);
        rseg := SYSTEM.AND(rseg, 3FH);
        IF onReloc # NIL THEN onReloc(rseg, rofs, rwidth, rrefSeg, rrel) END
      ELSIF recType = RecSegreloc THEN
        Files.ReadByte(f, tb); rseg := INTEGER(tb);
        Files.ReadDWord(f, rofs);
        Files.ReadByte(f, tb); rwidth := INTEGER(tb);
        Files.ReadWord(f, rrefSeg);
        IF onSegReloc # NIL THEN onSegReloc(rseg, rofs, rwidth, rrefSeg, 0) END
      END;

      Files.Seek(f, nextRec)
    END
  END;
  Files.Close(f)
END ScanRelocs;

(*
  Read segment bytes (wantType: 1=code, 2=data) into buf at offset dstOfs.
*)
PROCEDURE ReadSeg(VAR path: ARRAY OF CHAR; libOfs, hdrSize: LONGINT;
                  buf: SegBuf; dstOfs, size: WORD; wantType: INTEGER);
  VAR f: Files.File;
      dataStart: LONGINT;
      stype, dummy: INTEGER;
      slen: LONGINT;
      done: BOOLEAN;
      segPos: LONGINT;
BEGIN
  IF ~Files.Reset(f, path) THEN LogErr.Error2("Cannot open: ", path); RETURN END;
  dataStart := libOfs + LONGINT(14) + hdrSize;
  Files.Seek(f, dataStart);
  done := FALSE; segPos := dataStart;
  WHILE ~done DO
    Files.ReadWord(f, stype);
    IF stype <= 0 THEN done := TRUE
    ELSE
      Files.ReadWord(f, dummy);           (* num *)
      Files.ReadWord(f, dummy);           (* reserved *)
      Files.ReadDWord(f, slen);           (* length *)
      segPos := segPos + LONGINT(10);
      IF stype = wantType THEN
        Files.Seek(f, segPos);
        IF Files.BlockRead(f, buf^[dstOfs], size) # size THEN
          Files.Close(f); LogErr.Error2("Read error in ", path); RETURN
        END;
        done := TRUE
      ELSIF slen > LONGINT(0) THEN
        segPos := segPos + slen;
        Files.Seek(f, segPos)
      ELSE
        done := TRUE
      END
    END
  END;
  Files.Close(f)
END ReadSeg;

(*
  Read code segment bytes into buf at offset dstOfs.

  Parameters: path — file to read; libOfs — byte offset within path where
  the RDOFF2 image starts; hdrSize — size of the header-record area (as
  filled by ScanHeader); buf — destination far buffer; dstOfs — byte offset
  within buf to start writing; codeSize — number of code bytes to copy.
  Result: none (failures latch via LogErr).
*)
PROCEDURE ReadCode*(VAR path: ARRAY OF CHAR; libOfs, hdrSize: LONGINT;
                    buf: SegBuf; dstOfs, codeSize: WORD);
BEGIN
  ReadSeg(path, libOfs, hdrSize, buf, dstOfs, codeSize, 1)
END ReadCode;

(*
  Read data segment bytes into buf at offset dstOfs.

  Parameters: path — file to read; libOfs — byte offset within path where
  the RDOFF2 image starts; hdrSize — size of the header-record area (as
  filled by ScanHeader); buf — destination far buffer; dstOfs — byte offset
  within buf to start writing; dataSize — number of data bytes to copy.
  Result: none (failures latch via LogErr).
*)
PROCEDURE ReadData*(VAR path: ARRAY OF CHAR; libOfs, hdrSize: LONGINT;
                    buf: SegBuf; dstOfs, dataSize: WORD);
BEGIN
  ReadSeg(path, libOfs, hdrSize, buf, dstOfs, dataSize, 2)
END ReadData;

END Rdoff.
