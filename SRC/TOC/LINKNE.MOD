(*$D-*)
MODULE LinkNE;
(*
  NE-specific consumer of Link's target-agnostic core: writes a Windows/OS-2
  1.x New Executable (NE) file (DOCS/NE.MD), the /CP target.  Sits beside
  LinkMZ as a second, mutually-exclusive consumer of Link's generic core —
  same seam (a segRelocProc callback on Link.PerformLinking), different output
  format.

  Segment model (DOCS/NE-PLAN.MD §0/§2): one NE CODE segment per used module's
  own CODE segment, one NE DATA segment per used module's own DATA segment, and
  ONE final NE DATA segment for the shared BSS.  1-based NE segment indices are
  assigned by walking ls^.modHead in order (CODE then DATA per module), then the
  shared BSS last.

  Relocation model (§4): only SEGRELOC (segment-VALUE) fixups produce NE
  relocation records — one NE BASE (02h) reloc per SEGRELOC, appended to the
  reloc list of the OUTPUT segment the patch site lives in (the current
  module's CODE or DATA NE segment).  Pure in-segment OFFSET fixups (Link's own
  OnReloc) need no NE reloc: each module's own segment starts at offset 0, so
  a self-reference offset is already final and the loader never touches it.
  Cross-module imports are out of scope and rejected at link time (§1/§4).

  Scope (§1): entry point, relocations, heap/stack only.  No imports/exports
  (Module Reference Table / Imported Names Table empty), no resources.

  NE output cannot be run under xt (MZ-only); it is validated by structural
  byte inspection only (§6).
*)
IMPORT Files, LogErr, Rdoff, Strings, Link;

CONST
  NeHdrBytes  = 64;      (* fixed NE header size *)
  SegChunk    = 32;      (* NE segments per mapping/reloc chunk node *)
  NeRelChunk  = 128;     (* NE relocs per chunk node (small-record rule) *)
  StubBytes   = 64;      (* the MZ stub LinkNE writes (matches STUB.BIN) *)

  SegAttrData = 0001H;   (* bit 0: data segment *)
  SegAttrReal = 0004H;   (* bit 2: real-mode accessible *)
  SegAttrHasRel = 0100H; (* bit 8: has relocations *)

  RelBASE = 02H;         (* NE reloc type: 16-bit segment (BASE) *)

  (* Program Flags (NE header offset 0Ch) *)
  PfDGroupNone   = 00H;  (* bits 0-1 = 00: no automatic-data group — this
                            toolchain never addresses data DGROUP-relative
                            (every module reloads DS to its OWN data segment),
                            so there is no single shared automatic-data group *)
  Pf8086         = 10H;  (* bit 4: contains 8086 instructions *)
  PfProtMode     = 08H;  (* bit 3: protected-mode only (the /CP target) *)
  Pf8087         = 80H;  (* bit 7: contains 80x87 (FPU) instructions *)

  (* Application Flags (NE header offset 0Dh) *)
  AfFullScreen   = 01H;  (* bits 0-2 = 001: full-screen, NOT a Windows/P.M.-API
                            (GUI) app — i.e. a plain console application *)

TYPE
  (* Chunked per-segment NE relocation list (small-record rule): each record is
     8 bytes; the on-disk block is <count WORD><8*count bytes>. *)
  NeReloc = POINTER TO NeRelocRec;
  NeRelocRec = RECORD
    typ:    ARRAY NeRelChunk OF BYTE;    (* reloc type (RelBASE) *)
    ofs:    ARRAY NeRelChunk OF WORD;    (* offset within segment to patch *)
    tgtSeg: ARRAY NeRelChunk OF WORD;    (* target 1-based NE segment index *)
    tgtOfs: ARRAY NeRelChunk OF WORD;    (* target offset (0 for a pure BASE) *)
    count:  INTEGER;
    next:   NeReloc
  END;

  (* One NE segment table entry, built during PerformLinking. *)
  SegEntry = RECORD
    owner:   Link.Module;  (* NIL for the shared BSS segment *)
    seg:     INTEGER;      (* Rdoff.SegCode / SegData / SegBss *)
    dataLen: LONGINT;      (* bytes present in the file (0 for BSS) *)
    allocLen:LONGINT;      (* min allocation in memory *)
    isData:  BOOLEAN;      (* Data-Segment attr bit *)
    relHead: NeReloc;      (* per-segment reloc list (this segment's own) *)
    relTail: NeReloc;
    relCnt:  INTEGER
  END;
  SegNode = POINTER TO SegNodeRec;
  SegNodeRec = RECORD
    e:    ARRAY SegChunk OF SegEntry;
    next: SegNode
  END;

  State* = POINTER TO StateRec;
  StateRec* = RECORD
    segHead:  SegNode;   (* NE segment table chunks *)
    segTail:  SegNode;
    segCount: INTEGER;   (* number of NE segments (1-based indices 1..segCount) *)
    bssIdx:   INTEGER;   (* 1-based NE index of the shared BSS segment *)
    modName:  ARRAY 10 OF CHAR   (* resident-names-table module name (upper) *)
  END;

PROCEDURE InitState*(ns: State);
BEGIN
  ns^.segHead := NIL; ns^.segTail := NIL;
  ns^.segCount := 0; ns^.bssIdx := 0;
  ns^.modName[0] := 0X
END InitState;

(* ---- NE segment table ---- *)

(* Append an NE segment entry; returns its 1-based index. *)
PROCEDURE AddSeg(ns: State; owner: Link.Module; seg: INTEGER;
                 dataLen, allocLen: LONGINT; isData: BOOLEAN): INTEGER;
  VAR n: SegNode; k: INTEGER;
BEGIN
  IF (ns^.segTail = NIL) OR ((ns^.segCount MOD SegChunk) = 0) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("Out of memory (NE seg chunk)"); RETURN 0 END;
    n^.next := NIL;
    IF ns^.segHead = NIL THEN ns^.segHead := n ELSE ns^.segTail^.next := n END;
    ns^.segTail := n
  END;
  k := ns^.segCount MOD SegChunk;
  ns^.segTail^.e[k].owner    := owner;
  ns^.segTail^.e[k].seg      := seg;
  ns^.segTail^.e[k].dataLen  := dataLen;
  ns^.segTail^.e[k].allocLen := allocLen;
  ns^.segTail^.e[k].isData   := isData;
  ns^.segTail^.e[k].relHead  := NIL;
  ns^.segTail^.e[k].relTail  := NIL;
  ns^.segTail^.e[k].relCnt   := 0;
  INC(ns^.segCount);
  RETURN ns^.segCount
END AddSeg;

(* Return a pointer-free accessor to NE segment entry idx (1-based). *)
PROCEDURE SegOf(ns: State; idx: INTEGER): SegNode;
  VAR n: SegNode; c: INTEGER;
BEGIN
  n := ns^.segHead; c := (idx - 1) DIV SegChunk;
  WHILE c > 0 DO n := n^.next; DEC(c) END;
  RETURN n
END SegOf;

(* Locate the NE segment index of (module m, seg) — walks the segment table.
   For the shared BSS, m is NIL and seg is Rdoff.SegBss. *)
PROCEDURE SegIndexOf(ns: State; m: Link.Module; seg: INTEGER): INTEGER;
  VAR n: SegNode; i, k: INTEGER;
BEGIN
  n := ns^.segHead; i := 0;
  WHILE n # NIL DO
    k := 0;
    WHILE (k < SegChunk) & (i < ns^.segCount) DO
      IF (n^.e[k].seg = seg) &
         ((seg = Rdoff.SegBss) OR (n^.e[k].owner = m)) THEN RETURN i + 1 END;
      INC(k); INC(i)
    END;
    n := n^.next
  END;
  RETURN 0
END SegIndexOf;

(* Build the NE segment table + BSS index.  Called before PerformLinking so
   OnSegReloc can resolve target indices. *)
PROCEDURE BuildSegTable*(ls: Link.State; ns: State);
  VAR m: Link.Module; dummy: INTEGER;
BEGIN
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & ~m^.dup THEN
      dummy := AddSeg(ns, m, Rdoff.SegCode, m^.codeSize, m^.codeSize, FALSE);
      dummy := AddSeg(ns, m, Rdoff.SegData, m^.dataSize, m^.dataSize, TRUE)
    END;
    m := m^.next
  END;
  (* one shared BSS data segment (no file bytes; allocLen = total shared BSS) *)
  ns^.bssIdx := AddSeg(ns, NIL, Rdoff.SegBss, LONGINT(0), ls^.totalBssLen, TRUE)
END BuildSegTable;

(* ---- per-segment reloc list ---- *)

PROCEDURE AddReloc(sn: SegNode; k: INTEGER; typ: BYTE; ofs, tgtSeg, tgtOfs: WORD);
  VAR r: NeReloc; j: INTEGER;
BEGIN
  IF (sn^.e[k].relTail = NIL) OR (sn^.e[k].relTail^.count >= NeRelChunk) THEN
    NEW(r);
    IF r = NIL THEN LogErr.Error("Out of memory (NE reloc chunk)"); RETURN END;
    r^.count := 0; r^.next := NIL;
    IF sn^.e[k].relHead = NIL THEN sn^.e[k].relHead := r
    ELSE sn^.e[k].relTail^.next := r END;
    sn^.e[k].relTail := r
  END;
  r := sn^.e[k].relTail; j := r^.count;
  r^.typ[j] := typ; r^.ofs[j] := ofs;
  r^.tgtSeg[j] := tgtSeg; r^.tgtOfs[j] := tgtOfs;
  INC(r^.count);
  INC(sn^.e[k].relCnt)
END AddReloc;

(* ---- SEGRELOC callback ---- *)

VAR curNs: State;

(* Resolve a SEGRELOC's rrefSeg to the target's 1-based NE segment index. *)
PROCEDURE TargetSegIndex(ls: Link.State; m: Link.Module; rrefSeg: INTEGER): INTEGER;
  VAR so: Link.Module; sym: Link.Symbol; segId: INTEGER;
BEGIN
  IF rrefSeg = Rdoff.SegCode THEN RETURN SegIndexOf(curNs, m, Rdoff.SegCode)
  ELSIF rrefSeg = Rdoff.SegData THEN RETURN SegIndexOf(curNs, m, Rdoff.SegData)
  ELSIF rrefSeg = Rdoff.SegBss THEN RETURN curNs^.bssIdx
  ELSE
    sym := Link.FindImport(rrefSeg);
    IF sym = Link.NoSym THEN
      LogErr.Error("NE target does not support cross-module imports"); RETURN 0
    END;
    so := Link.SymOwner(ls, sym);
    segId := Link.SymSegId(ls, sym);
    IF segId = 0 THEN RETURN SegIndexOf(curNs, so, Rdoff.SegCode)
    ELSIF segId = 1 THEN RETURN SegIndexOf(curNs, so, Rdoff.SegData)
    ELSE RETURN curNs^.bssIdx END
  END
END TargetSegIndex;

(* segRelocProc for Link.PerformLinking.  A SEGRELOC patches a segment-VALUE
   into the image (the NE loader replaces the patched WORD with the target
   segment's real load address); we bake the 1-based NE segment INDEX at the
   patch site (BASE reloc, non-additive, so the loader overwrites it) and
   record one NE BASE reloc on the OUTPUT segment the patch site lives in. *)
PROCEDURE OnSegReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                     rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR ls: Link.State; m: Link.Module;
      tgtIdx, outIdx: INTEGER;
      patchAddr: LONGINT;
      sn: SegNode; k: INTEGER;
BEGIN
  ls := Link.CurrentState();
  m  := Link.CurrentModule();

  tgtIdx := TargetSegIndex(ls, m, rrefSeg);
  IF LogErr.HaveErr() THEN RETURN END;

  (* bake the NE segment index at the patch site (loader replaces it) *)
  IF rseg = Rdoff.SegCode THEN
    patchAddr := rofs;
    Link.PatchBuf(patchAddr, WORD(tgtIdx), 2);
    outIdx := SegIndexOf(curNs, m, Rdoff.SegCode)
  ELSE
    patchAddr := Link.DataFileOffsetOf(ls, m, rofs);
    Link.PatchDataFile(patchAddr, WORD(tgtIdx), 2);
    outIdx := SegIndexOf(curNs, m, Rdoff.SegData)
  END;

  (* the reloc's offset is WITHIN the output segment: for CODE/DATA that is
     rofs (each module = one segment, base 0) *)
  sn := SegOf(curNs, outIdx);
  k  := (outIdx - 1) MOD SegChunk;
  AddReloc(sn, k, RelBASE, WORD(rofs), WORD(tgtIdx), 0)
END OnSegReloc;

(* Drives the generic core with NE's segRelocProc.  BuildSegTable must have
   run first (OnSegReloc resolves target indices through curNs). *)
PROCEDURE PerformLinking*(ls: Link.State; ns: State);
BEGIN
  curNs := ns;
  Link.PerformLinking(ls, OnSegReloc)
END PerformLinking;

(* ---- write NE EXE ---- *)

(* MZ stub: minimal real-mode shell that prints a message and exits.  An NE
   file's outer envelope IS an MZ file (DOCS/NE.MD §1); e_lfanew (offset 3Ch)
   points at the NE header, which we place right after this StubBytes stub. *)
PROCEDURE WriteStub(VAR fout: Files.File; neOfs: LONGINT);
  VAR w, i: INTEGER;
BEGIN
  (* 28-byte MZ header + a tiny code/message body, padded to StubBytes. *)
  w := Files.WriteWord(fout, 5A4DH);        (* "MZ" *)
  w := Files.WriteWord(fout, StubBytes MOD 512);   (* bytes on last page *)
  w := Files.WriteWord(fout, 1);            (* page count *)
  w := Files.WriteWord(fout, 0);            (* reloc count *)
  w := Files.WriteWord(fout, 4);            (* header paragraphs (64 bytes) *)
  w := Files.WriteWord(fout, 0);            (* min alloc *)
  w := Files.WriteWord(fout, 0);            (* max alloc *)
  w := Files.WriteWord(fout, 0);            (* SS *)
  w := Files.WriteWord(fout, 0);            (* SP *)
  w := Files.WriteWord(fout, 0);            (* checksum *)
  w := Files.WriteWord(fout, 0);            (* IP *)
  w := Files.WriteWord(fout, 0);            (* CS *)
  w := Files.WriteWord(fout, 40H);          (* reloc table offset (none) *)
  w := Files.WriteWord(fout, 0);            (* overlay *)
  (* The 14-word MZ header above ends at offset 1Ch (28).  e_lfanew is a fixed
     field at offset 3Ch (60) — pad the gap (28..60) with zeros first, THEN
     write the DWORD so it lands exactly at 3Ch. *)
  i := Files.Position(fout);
  WHILE i < 3CH DO w := Files.WriteByte(fout, BYTE(0)); INC(i) END;
  w := Files.WriteDWord(fout, neOfs);       (* e_lfanew (at MZ offset 3Ch) *)
  (* pad remainder of the stub with zeros *)
  i := Files.Position(fout);
  WHILE i < StubBytes DO w := Files.WriteByte(fout, BYTE(0)); INC(i) END
END WriteStub;

(* Write one segment's reloc block (count WORD + 8*count bytes) after its data. *)
PROCEDURE WriteRelocBlock(VAR fout: Files.File; sn: SegNode; k: INTEGER);
  VAR r: NeReloc; j, w: INTEGER;
BEGIN
  IF sn^.e[k].relCnt = 0 THEN RETURN END;
  w := Files.WriteWord(fout, sn^.e[k].relCnt);
  r := sn^.e[k].relHead;
  WHILE r # NIL DO
    j := 0;
    WHILE j < r^.count DO
      w := Files.WriteByte(fout, r^.typ[j]);        (* reloc type *)
      w := Files.WriteByte(fout, BYTE(0));           (* flags (not additive) *)
      w := Files.WriteWord(fout, INTEGER(r^.ofs[j]));    (* offset in seg *)
      w := Files.WriteWord(fout, INTEGER(r^.tgtSeg[j])); (* target NE seg idx *)
      w := Files.WriteWord(fout, INTEGER(r^.tgtOfs[j])); (* target offset *)
      INC(j)
    END;
    r := r^.next
  END
END WriteRelocBlock;

(* Length in bytes of a segment's reloc block on disk (0 if none). *)
PROCEDURE RelocBlockLen(sn: SegNode; k: INTEGER): LONGINT;
BEGIN
  IF sn^.e[k].relCnt = 0 THEN RETURN LONGINT(0) END;
  RETURN LONGINT(2) + LONGINT(sn^.e[k].relCnt) * LONGINT(8)
END RelocBlockLen;

PROCEDURE WriteExe*(ls: Link.State; ns: State; outPath: ARRAY OF CHAR);
  VAR fout: Files.File;
      neOfs: LONGINT;
      i, k, w, nlen: INTEGER;
      sn: SegNode;
      entryIdx: INTEGER;      (* NE seg idx of entry proc's CODE segment *)
      entrySeg: Link.Module;
      esym: Link.Symbol;
      (* table offsets (from NE header start) *)
      segTblOfs, resTblOfs, resNamesOfs, modRefOfs, impNamesOfs, entryTblOfs: INTEGER;
      nonresOfs: LONGINT;
      entryTblLen, resNamesLen: INTEGER;
      alignShift, sectorSize: INTEGER;
      filePos, segFilePos: LONGINT;
      heapSize: LONGINT;
      summary: ARRAY 128 OF CHAR;
      m: Link.Module;
BEGIN
  IF ~Files.ReWrite(fout, outPath) THEN LogErr.Error2("Cannot write: ", outPath); RETURN END;

  neOfs := LONGINT(StubBytes);
  alignShift := 9; sectorSize := 512;

  (* resolve entry point: "start" symbol's own module CODE segment *)
  esym := Link.FindSymbol(ls, "start");
  entryIdx := 0;
  IF esym # Link.NoSym THEN
    entrySeg := Link.SymOwner(ls, esym);
    entryIdx := SegIndexOf(ns, entrySeg, Rdoff.SegCode)
  END;

  (* ---- table layout (offsets from NE header start) ----
     Order in the header area: [NE header 64B][segment table][resource table
     (count 0)][resident names][module ref (empty)][imported names (empty)]
     [entry table].  Nonresident names table is at a file offset. *)
  segTblOfs := NeHdrBytes;
  resTblOfs := segTblOfs + ns^.segCount * 8;
  (* resource table present but empty: align shift WORD + terminating type 0 WORD *)
  resNamesOfs := resTblOfs + 4;

  (* resident names: [len][NAME][ordinal WORD] then terminating [0] *)
  nlen := 0; WHILE ns^.modName[nlen] # 0X DO INC(nlen) END;
  resNamesLen := (1 + nlen + 2) + 1;
  modRefOfs := resNamesOfs + resNamesLen;
  (* module reference table: empty (0 entries) — no bytes *)
  impNamesOfs := modRefOfs;
  (* imported names table: one terminating length-0 byte *)
  entryTblOfs := impNamesOfs + 1;
  (* entry table: one bundle (count=1, seg=entryIdx, [flags,ofs WORD]) + terminator *)
  entryTblLen := (2 + 3) + 1;

  (* nonresident names: empty (one terminating length-0 byte), placed right
     after the header area, before segment data *)
  nonresOfs := neOfs + LONGINT(entryTblOfs) + LONGINT(entryTblLen);

  heapSize := ls^.totalBssLen + ls^.stackSize;
  IF heapSize > LONGINT(0FFFFH) THEN heapSize := LONGINT(0FFFFH) END;

  (* ---- MZ stub ---- *)
  WriteStub(fout, neOfs);

  (* ---- NE header (64 bytes) ---- *)
  w := Files.WriteWord(fout, 454EH);                 (* "NE" *)
  w := Files.WriteByte(fout, BYTE(2));               (* linker ver major *)
  w := Files.WriteByte(fout, BYTE(8));               (* linker ver minor *)
  w := Files.WriteWord(fout, entryTblOfs);           (* entry table offset *)
  w := Files.WriteWord(fout, entryTblLen);           (* entry table length *)
  w := Files.WriteDWord(fout, LONGINT(0));           (* file load CRC *)
  (* program flags: DGROUP none + 8086 + protected-mode-only + 80x87.
     The 80x87 bit is set because this toolchain's runtime and generated code
     use the FPU (SYSTEM_REQUIRE87 / REAL/LONGREAL arithmetic). *)
  w := Files.WriteByte(fout, BYTE(PfDGroupNone + Pf8086 + PfProtMode + Pf8087));
  (* application flags: full-screen console app (001) — not a GUI/P.M.-API app *)
  w := Files.WriteByte(fout, BYTE(AfFullScreen));
  w := Files.WriteWord(fout, 0);                     (* auto data seg index = 0
                                                        (no DGROUP — see flags) *)
  w := Files.WriteWord(fout, INTEGER(heapSize));     (* initial local heap size *)
  w := Files.WriteWord(fout, INTEGER(ls^.stackSize));(* initial stack size *)
  w := Files.WriteWord(fout, ls^.entryIp);           (* entry IP *)
  w := Files.WriteWord(fout, entryIdx);              (* entry CS = NE seg idx *)
  w := Files.WriteWord(fout, INTEGER(ls^.stackSize) - 2); (* SP *)
  w := Files.WriteWord(fout, ns^.bssIdx);            (* SS = shared BSS (DGROUP) *)
  w := Files.WriteWord(fout, ns^.segCount);          (* segment count *)
  w := Files.WriteWord(fout, 0);                     (* module ref count *)
  w := Files.WriteWord(fout, 1);                     (* nonresident names len *)
  w := Files.WriteWord(fout, segTblOfs);             (* segment table offset *)
  w := Files.WriteWord(fout, resTblOfs);             (* resource table offset *)
  w := Files.WriteWord(fout, resNamesOfs);           (* resident names offset *)
  w := Files.WriteWord(fout, modRefOfs);             (* module ref table offset *)
  w := Files.WriteWord(fout, impNamesOfs);           (* imported names offset *)
  w := Files.WriteDWord(fout, nonresOfs);            (* nonresident names offset (file) *)
  w := Files.WriteWord(fout, 0);                     (* moveable entry count *)
  w := Files.WriteWord(fout, alignShift);            (* file align shift count *)
  w := Files.WriteWord(fout, 0);                     (* resource table entries *)
  w := Files.WriteByte(fout, BYTE(2));               (* target OS = Windows *)
  w := Files.WriteByte(fout, BYTE(0));               (* other exe flags *)
  w := Files.WriteWord(fout, 0);                     (* return thunks *)
  w := Files.WriteWord(fout, 0);                     (* seg ref thunks *)
  w := Files.WriteWord(fout, 0);                     (* min code swap area *)
  w := Files.WriteWord(fout, 0);                     (* expected Windows ver *)

  (* ---- segment table (filled after segment file offsets are known) ---- *)
  (* The segment table's File Offset field is in sectors; segment data starts
     after the whole header area (which ends at nonresOfs + 1 for the empty
     nonresident table).  Round each segment start up to a sector boundary.
     We first compute each segment's sector, then stream the table, then the
     data.  Two-pass: pass A assigns sectors; pass B writes table + data. *)

  (* pass A: assign each segment a sector-aligned file offset *)
  filePos := nonresOfs + LONGINT(1);   (* end of header area *)
  (* round up to sector *)
  filePos := ((filePos + LONGINT(sectorSize) - LONGINT(1)) DIV LONGINT(sectorSize)) * LONGINT(sectorSize);

  (* write segment table entries *)
  segFilePos := filePos;
  sn := ns^.segHead; i := 0;
  WHILE i < ns^.segCount DO
    k := i MOD SegChunk;
    IF k = 0 THEN IF i > 0 THEN sn := sn^.next END END;
    (* File Offset in sectors (0 => no file data, used for BSS) *)
    IF sn^.e[k].dataLen > LONGINT(0) THEN
      w := Files.WriteWord(fout, INTEGER(segFilePos DIV LONGINT(sectorSize)))
    ELSE
      w := Files.WriteWord(fout, 0)
    END;
    w := Files.WriteWord(fout, INTEGER(sn^.e[k].dataLen));   (* length in file *)
    (* attributes *)
    IF sn^.e[k].isData THEN
      IF sn^.e[k].relCnt > 0 THEN w := Files.WriteWord(fout, SegAttrData + SegAttrReal + SegAttrHasRel)
      ELSE w := Files.WriteWord(fout, SegAttrData + SegAttrReal) END
    ELSE
      IF sn^.e[k].relCnt > 0 THEN w := Files.WriteWord(fout, SegAttrReal + SegAttrHasRel)
      ELSE w := Files.WriteWord(fout, SegAttrReal) END
    END;
    (* min allocation *)
    w := Files.WriteWord(fout, INTEGER(sn^.e[k].allocLen));
    (* advance file offset past this segment's data + reloc block, sector-align *)
    IF sn^.e[k].dataLen > LONGINT(0) THEN
      segFilePos := segFilePos + sn^.e[k].dataLen + RelocBlockLen(sn, k);
      segFilePos := ((segFilePos + LONGINT(sectorSize) - LONGINT(1)) DIV LONGINT(sectorSize)) * LONGINT(sectorSize)
    END;
    INC(i)
  END;

  (* ---- resource table (empty): align shift + terminating type 0 ---- *)
  w := Files.WriteWord(fout, alignShift);
  w := Files.WriteWord(fout, 0);

  (* ---- resident names table: module name + ordinal 0, then terminator ---- *)
  w := Files.WriteByte(fout, BYTE(nlen));
  i := 0; WHILE i < nlen DO w := Files.WriteByte(fout, BYTE(ORD(ns^.modName[i]))); INC(i) END;
  w := Files.WriteWord(fout, 0);        (* ordinal (module name exports nothing) *)
  w := Files.WriteByte(fout, BYTE(0));  (* terminating length-0 *)

  (* ---- module reference table: empty ---- *)
  (* ---- imported names table: terminating length-0 ---- *)
  w := Files.WriteByte(fout, BYTE(0));

  (* ---- entry table: one bundle for the entry segment ---- *)
  w := Files.WriteByte(fout, BYTE(1));            (* entry count *)
  w := Files.WriteByte(fout, BYTE(entryIdx));     (* segment number *)
  w := Files.WriteByte(fout, BYTE(0));            (* flags (not exported) *)
  w := Files.WriteWord(fout, INTEGER(ls^.entryIp)); (* offset *)
  w := Files.WriteByte(fout, BYTE(0));            (* terminating bundle *)

  (* ---- nonresident names table: terminating length-0 ---- *)
  w := Files.WriteByte(fout, BYTE(0));

  (* pad to first segment's sector boundary *)
  Link.WriteZeros(fout, filePos - Files.Position(fout));

  (* ---- segment data + per-segment reloc blocks ---- *)
  (* rewind the code spill / data temp for reading; each module's CODE sits at
     spill offset codePara*16, its DATA at DataFileOffsetOf(m,0). *)
  segFilePos := filePos;
  sn := ns^.segHead; i := 0;
  WHILE (i < ns^.segCount) & ~LogErr.HaveErr() DO
    k := i MOD SegChunk;
    IF k = 0 THEN IF i > 0 THEN sn := sn^.next END END;
    IF sn^.e[k].dataLen > LONGINT(0) THEN
      m := sn^.e[k].owner;
      IF sn^.e[k].seg = Rdoff.SegCode THEN
        Files.Seek(ls^.spillFile, LONGINT(m^.codePara) * LONGINT(16));
        Link.CopySpan(ls^.spillFile, fout, sn^.e[k].dataLen)
      ELSE
        Files.Seek(ls^.dataFile, Link.DataFileOffsetOf(ls, m, LONGINT(0)));
        Link.CopySpan(ls^.dataFile, fout, sn^.e[k].dataLen)
      END;
      WriteRelocBlock(fout, sn, k);
      (* sector-align to the next segment's start *)
      segFilePos := segFilePos + sn^.e[k].dataLen + RelocBlockLen(sn, k);
      segFilePos := ((segFilePos + LONGINT(sectorSize) - LONGINT(1)) DIV LONGINT(sectorSize)) * LONGINT(sectorSize);
      Link.WriteZeros(fout, segFilePos - Files.Position(fout))
    END;
    INC(i)
  END;

  Files.Close(ls^.spillFile);
  Files.Close(ls^.dataFile);

  Files.Close(fout);
  IF ~Files.Ok(fout) THEN
    LogErr.Error2("Write error (disk full?): ", outPath); RETURN
  END;

  Strings.Copy(outPath, summary);
  Strings.Append(": NE segs=", summary); Strings.AppendInt(LONGINT(ns^.segCount), summary);
  Strings.Append(", Code=", summary); Strings.AppendInt(ls^.totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(ls^.totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(ls^.totalBssLen,  summary);
  Strings.Append(", Stack=", summary); Strings.AppendInt(ls^.stackSize,   summary);
  LogErr.Info(summary)
END WriteExe;

(* Set the resident-names-table module name (the .exe stem, uppercased). *)
PROCEDURE SetModName*(ns: State; name: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (name[i] # 0X) & (name[i] # ".") & (i < 8) DO
    ns^.modName[i] := name[i]; INC(i)
  END;
  ns^.modName[i] := 0X;
  SYSTEM.UPSTR(ns^.modName)
END SetModName;

(* Release ns's own chains (NE segment table + per-segment reloc lists). *)
PROCEDURE LinkFree*(ns: State);
  VAR sn, snNext: SegNode; r, rNext: NeReloc; i, k: INTEGER;
BEGIN
  sn := ns^.segHead; i := 0;
  WHILE sn # NIL DO
    k := 0;
    WHILE (k < SegChunk) & (i < ns^.segCount) DO
      r := sn^.e[k].relHead;
      WHILE r # NIL DO rNext := r^.next; DISPOSE(r); r := rNext END;
      sn^.e[k].relHead := NIL; sn^.e[k].relTail := NIL;
      INC(k); INC(i)
    END;
    snNext := sn^.next; DISPOSE(sn); sn := snNext
  END;
  ns^.segHead := NIL; ns^.segTail := NIL; ns^.segCount := 0
END LinkFree;

END LinkNE.
