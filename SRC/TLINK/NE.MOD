MODULE NE;
(*
  NE: Windows/OS-2 1.x New Executable (NE) writer for tlink.exe's /T=ne
  mode.  Produces the SAME NE shape SRC/TOC/LINKNE.MOD writes for TOC.EXE's
  own /CP target (DOCS/NE.MD, DOCS/NE-BP.MD) -- verbatim MZ stab (NESTAB.BIN,
  embedded the same way LINKNE.MOD embeds it), same header field values/
  layout, same BPC placeholder relocation model (the loader WRITES every
  reloc'd site from the reloc record; the file word is an FFFF placeholder,
  never baked) -- but adapted to tlink.exe's own SMALL-MODEL layout instead
  of LINKNE.MOD's per-module Link.State: exactly TWO NE segments (one CODE,
  one DATA covering data+bss+stack together), matching TLINK.MOD's existing
  CalculateLayoutSmall/ModeSExe layout, not one CODE+DATA pair per input
  module.  TLINK.MOD drives this module's OnReloc/OnSegReloc in place of its
  own baking OnReloc/OnSegReloc when mode = ModeNe (see TLINK.MOD's own
  PerformLinking).

  Relocation model (mirrors LinkNE.MOD's own header comment):
    - an absolute RELOC (rrel = 0) -> NE OFFS (05h) reloc, site stamped FFFF.
    - a SEGRELOC (segment-VALUE fixup) -> NE BASE (02h) reloc, site FFFF.
    - a far-pointer site (OFFS at X immediately followed by SEGRELOC at X+2)
      coalesces into one NE PTR (03h) reloc.
    - an IP-relative RELOC (rrel # 0) is position-independent and stays
      baked into the buffer with no NE reloc at all (same as LinkNE.MOD).
  Since tlink.exe's own model has no cross-module EXTERNAL import concept
  (every symbol a RELOC/SEGRELOC can reference is either self-CODE/DATA/BSS
  or another linked module's own export -- TLINK.MOD's ResolveTarget has no
  "unresolved import" case the way LinkNE.MOD's KERNEL.INITTASK sentinel
  does), there is no external-import reloc case here at all: every
  relocation this module emits is INTERNALREF.
*)
IMPORT Files, LogErr, Rdoff, Strings;

CONST
  NeHdrBytes = 64;
  RelChunk   = 128;   (* NE relocs per chunk node (small-record rule) *)
  StabBytes  = 512;   (* size of NESTAB.BIN (embedded via $L) -> e_lfanew = 0E3EH *)

  (* Segment attributes (Table 6) -- matches LinkNE.MOD exactly. *)
  SegAttrData     = 0001H;
  SegAttrMoveable = 0010H;
  SegAttrPreload  = 0040H;
  SegAttrHasRel   = 0100H;
  SegAttrDiscard  = 1000H;
  SegAttrDpl      = 0C00H;

  (* NE relocation-item types (Table 10) *)
  RelBASE = 02H;
  RelPTR  = 03H;
  RelOFFS = 05H;

  (* Program/Application flags (matches LinkNE.MOD / the reference NE). *)
  PfDGroupMultiple = 02H;
  PfProtMode       = 08H;
  AfPmApi          = 03H;

  SegCode = 1;   (* 1-based NE segment index: this module's single CODE seg *)
  SegData = 2;   (*                            ...and single DATA/BSS/stack seg *)

(*$A-*)
TYPE
  (* Chunked per-segment NE relocation list -- identical shape to LinkNE.MOD's
     own NeRelocRec (8 bytes/entry: <count WORD><8*count bytes> on disk). *)
  NeReloc = POINTER TO NeRelocRec;
  NeRelocRec = RECORD
    typ:    ARRAY RelChunk OF BYTE;
    flg:    ARRAY RelChunk OF BYTE;
    ofs:    ARRAY RelChunk OF WORD;
    tgtSeg: ARRAY RelChunk OF WORD;
    tgtOfs: ARRAY RelChunk OF WORD;
    count:  INTEGER;
    next:   NeReloc
  END;

VAR
  codeRelHead, codeRelTail: NeReloc;
  codeRelCnt: INTEGER;
  dataRelHead, dataRelTail: NeReloc;
  dataRelCnt: INTEGER;

(*$L NESTAB.RDF*)
PROCEDURE NESTAB;FAR;EXTERNAL;

PROCEDURE ResetRelocs*;
BEGIN
  codeRelHead := NIL; codeRelTail := NIL; codeRelCnt := 0;
  dataRelHead := NIL; dataRelTail := NIL; dataRelCnt := 0
END ResetRelocs;

PROCEDURE AddReloc(VAR head, tail: NeReloc; VAR cnt: INTEGER;
                    typ, flg: BYTE; ofs, tgtSeg, tgtOfs: WORD);
  VAR r: NeReloc; j: INTEGER;
BEGIN
  IF (tail = NIL) OR (tail^.count >= RelChunk) THEN
    NEW(r);
    IF r = NIL THEN LogErr.Error("ne: out of memory (reloc chunk)"); RETURN END;
    r^.count := 0; r^.next := NIL;
    IF head = NIL THEN head := r ELSE tail^.next := r END;
    tail := r
  END;
  r := tail; j := r^.count;
  r^.typ[j] := typ; r^.flg[j] := flg; r^.ofs[j] := ofs;
  r^.tgtSeg[j] := tgtSeg; r^.tgtOfs[j] := tgtOfs;
  INC(r^.count);
  INC(cnt)
END AddReloc;

(* Coalesce a far-pointer pair: a preceding OFFS reloc at `ofs` (the offset
   word) plus a SEGRELOC fixup at `ofs`+2 become one PTR reloc.  Mirrors
   LinkNE.MOD's own CoalesceToPtr exactly. *)
PROCEDURE CoalesceToPtr(VAR head: NeReloc; ofs, tgtSeg: WORD): BOOLEAN;
  VAR r: NeReloc; j: INTEGER;
BEGIN
  r := head;
  WHILE r # NIL DO
    j := 0;
    WHILE j < r^.count DO
      IF (r^.typ[j] = RelOFFS) & (r^.ofs[j] = ofs) THEN
        r^.typ[j] := RelPTR;
        r^.tgtSeg[j] := tgtSeg;
        r^.flg[j] := BYTE(0);
        RETURN TRUE
      END;
      INC(j)
    END;
    r := r^.next
  END;
  RETURN FALSE
END CoalesceToPtr;

(* ---- site read/write (raw buffer, not Link.MOD's own) ---- *)

PROCEDURE ReadSiteWord(buf: Rdoff.SegBuf; ofs: WORD): WORD;
BEGIN RETURN WORD(INTEGER(buf^[ofs]) + SYSTEM.LSL(INTEGER(buf^[ofs+1]), 8))
END ReadSiteWord;

PROCEDURE WriteSiteWord(buf: Rdoff.SegBuf; ofs: WORD; val: WORD);
BEGIN
  buf^[ofs]   := BYTE(SYSTEM.AND(val, 0FFH));
  buf^[ofs+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH))
END WriteSiteWord;

(* ---- OnReloc / OnSegReloc: called by TLINK.MOD in place of its own
   baking versions when mode = ModeNe.  isCode/codeBuf/dataBuf/patchOfs
   identify the patch site the SAME way TLINK.MOD's own PatchMem does for
   ModeSExe (two independent buffers, offset already relative to its own
   buffer's start); tgtIsCode/tgtOfs (already resolved by the caller via
   ResolveTarget/SymSegId, exactly as TLINK.MOD's own OnReloc/OnSegReloc do)
   identify the RELOC/SEGRELOC's own target. ---- *)

(* OnReloc: absolute offset fixup (rrel = 0 case only -- caller keeps baking
   an IP-relative fixup itself, unchanged, exactly as LinkNE.MOD does for
   near call/branch fixups; this procedure is not called for that case). *)
PROCEDURE OnReloc*(codeBuf, dataBuf: Rdoff.SegBuf; isCode: BOOLEAN; patchOfs: WORD;
                    tgtIsCode: BOOLEAN; tgtOfs: WORD);
  VAR buf: Rdoff.SegBuf; tgtSeg: WORD;
BEGIN
  IF isCode THEN buf := codeBuf ELSE buf := dataBuf END;
  IF tgtIsCode THEN tgtSeg := WORD(SegCode) ELSE tgtSeg := WORD(SegData) END;
  WriteSiteWord(buf, patchOfs, WORD(0FFFFH));
  IF isCode THEN AddReloc(codeRelHead, codeRelTail, codeRelCnt, BYTE(RelOFFS), BYTE(0), patchOfs, tgtSeg, tgtOfs)
  ELSE AddReloc(dataRelHead, dataRelTail, dataRelCnt, BYTE(RelOFFS), BYTE(0), patchOfs, tgtSeg, tgtOfs) END
END OnReloc;

(* OnSegReloc: a segment-VALUE fixup (the word at patchOfs carries a
   segment/selector, not an offset).  tgtIsCode says which NE segment the
   fixup targets (TLINK.MOD's ResolveTarget/SymSegId already resolved this
   the same way OnReloc's own tgtIsCode is resolved -- CODE targets don't
   occur in practice for a SEGRELOC in this toolchain, but the parameter is
   accepted symmetrically with OnReloc for a uniform call convention). *)
PROCEDURE OnSegReloc*(codeBuf, dataBuf: Rdoff.SegBuf; isCode: BOOLEAN; patchOfs: WORD;
                       tgtIsCode: BOOLEAN);
  VAR buf: Rdoff.SegBuf; head: NeReloc; tgtSeg, baseOfs: WORD;
BEGIN
  IF isCode THEN buf := codeBuf; head := codeRelHead
  ELSE buf := dataBuf; head := dataRelHead END;
  IF tgtIsCode THEN tgtSeg := WORD(SegCode) ELSE tgtSeg := WORD(SegData) END;
  baseOfs := ReadSiteWord(buf, patchOfs);
  IF (patchOfs >= WORD(2)) & CoalesceToPtr(head, patchOfs - WORD(2), tgtSeg) THEN
    WriteSiteWord(buf, patchOfs, WORD(0))
  ELSE
    WriteSiteWord(buf, patchOfs, WORD(0FFFFH));
    IF isCode THEN AddReloc(codeRelHead, codeRelTail, codeRelCnt, BYTE(RelBASE), BYTE(0), patchOfs, tgtSeg, baseOfs)
    ELSE AddReloc(dataRelHead, dataRelTail, dataRelCnt, BYTE(RelBASE), BYTE(0), patchOfs, tgtSeg, baseOfs) END
  END
END OnSegReloc;

(* ---- write NE EXE ---- *)

(* MZ stab: verbatim, same technique as LinkNE.MOD's own WriteStab -- always
   overwrites e_lfanew (offset 3Ch) explicitly rather than trusting whatever
   the embedded NESTAB.BIN already contains there. *)
PROCEDURE WriteStab(VAR fout: Files.File);
  VAR p: Rdoff.SegBuf; savedPos: LONGINT;
BEGIN
  p := SYSTEM.ADR(NESTAB);
  Files.BlockWrite(fout, p^[0], StabBytes);
  savedPos := Files.Position(fout);
  Files.Seek(fout, LONGINT(3CH));
  Files.WriteDWord(fout, LONGINT(StabBytes));
  Files.Seek(fout, savedPos)
END WriteStab;

(* WriteZeros: pad fout with n zero bytes, 128 at a time (matches
   SRC/TOC/LINK.MOD's own WriteZeros exactly -- a byte-at-a-time loop is
   both needlessly slow for a real sector-alignment gap (hundreds of
   bytes) and, more importantly, the SAME negative-n guard that module's
   own header comment documents is needed here too: n<=0 means "nothing
   to pad", must return before ever reaching a WORD/BYTE cast that would
   reinterpret a negative n as a huge unsigned count. *)
PROCEDURE WriteZeros(VAR fout: Files.File; n: LONGINT);
  VAR buf: ARRAY 128 OF BYTE; chunk: WORD;
BEGIN
  IF n <= LONGINT(0) THEN RETURN END;
  SYSTEM.FILL(buf, 128, 0);
  WHILE n > LONGINT(128) DO
    IF Files.BlockWrite(fout, buf, 128) # 128 THEN LogErr.Error("ne: write error") END;
    DEC(n, LONGINT(128))
  END;
  chunk := WORD(n);
  IF chunk > 0 THEN
    IF Files.BlockWrite(fout, buf, chunk) # chunk THEN LogErr.Error("ne: write error") END
  END
END WriteZeros;

PROCEDURE WriteRelocBlock(VAR fout: Files.File; head: NeReloc; cnt: INTEGER);
  VAR r: NeReloc; j: INTEGER;
BEGIN
  IF cnt = 0 THEN RETURN END;
  Files.WriteWord(fout, cnt);
  r := head;
  WHILE r # NIL DO
    j := 0;
    WHILE j < r^.count DO
      Files.WriteByte(fout, r^.typ[j]);
      Files.WriteByte(fout, r^.flg[j]);
      Files.WriteWord(fout, INTEGER(r^.ofs[j]));
      Files.WriteWord(fout, INTEGER(r^.tgtSeg[j]));
      Files.WriteWord(fout, INTEGER(r^.tgtOfs[j]));
      INC(j)
    END;
    r := r^.next
  END
END WriteRelocBlock;

PROCEDURE RelocBlockLen(cnt: INTEGER): LONGINT;
BEGIN
  IF cnt = 0 THEN RETURN LONGINT(0) END;
  RETURN LONGINT(2) + LONGINT(cnt) * LONGINT(8)
END RelocBlockLen;

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, start: INTEGER;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = "\") OR (path[i] = "/") OR (path[i] = ":") THEN start := i + 1 END;
    INC(i)
  END;
  Strings.Extract(path, start, i - start, dst)
END BaseName;

PROCEDURE UpcaseInPlace(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO s[i] := SYSTEM.UCASE(s[i]); INC(i) END
END UpcaseInPlace;

(* ModName: the resident-names-table module name -- the .exe stem,
   uppercased, max 8 chars (matches LinkNE.MOD's own SetModName). *)
PROCEDURE ModName(outFileName: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR base: ARRAY 128 OF CHAR; i: INTEGER;
BEGIN
  BaseName(outFileName, base);
  i := 0;
  WHILE (base[i] # 0X) & (base[i] # ".") & (i < 8) DO out[i] := base[i]; INC(i) END;
  out[i] := 0X;
  UpcaseInPlace(out)
END ModName;

(* NonresName: the nonresident-names entry -- stem + ".EXE", uppercase
   (matches LinkNE.MOD's own BuildNonresName). *)
PROCEDURE NonresName(outFileName: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  ModName(outFileName, out);
  i := 0; WHILE out[i] # 0X DO INC(i) END;
  out[i] := "."; INC(i);
  out[i] := "E"; INC(i); out[i] := "X"; INC(i); out[i] := "E"; INC(i);
  out[i] := 0X
END NonresName;

(* Write: emit a New Executable matching LinkNE.MOD's own header/table shape
   (DOCS/NE-BP.MD), with exactly two NE segments: CODE (totalCodeLen bytes)
   and DATA (covering data+bss+stack together, allocLen = totalDataLen +
   totalBssLen + stackSize -- same reasoning as LinkNE.MOD's BuildSegTable:
   SP must sit at the TOP of the combined DATA segment so a growing stack
   never aliases live BSS data at low offsets).
   Parameters: codeBuf/dataBuf -- the two ModeSExe-style independent
   buffers (see TLINK.MOD's own PatchMem ModeSExe branch); totalCodeLen/
   totalDataLen/totalBssLen/stackSize -- layout sizes; entryIp -- offset of
   'start' within codeBuf; outFileName -- path to write.  Relocations are
   read from this module's own codeRelHead/dataRelHead (populated via
   OnReloc/OnSegReloc during PerformLinking, by the caller). *)
PROCEDURE Write*(codeBuf, dataBuf: Rdoff.SegBuf;
                  totalCodeLen, totalDataLen, totalBssLen, stackSize: LONGINT;
                  entryIp: INTEGER; outFileName: ARRAY OF CHAR);
  VAR fout: Files.File;
      w, k, nlen, nrLen, nrTabLen: INTEGER;
      modNm, nrName: ARRAY 16 OF CHAR;
      segTblOfs, resTblOfs, resNamesOfs, modRefOfs, impNamesOfs, entryTblOfs: INTEGER;
      entryTblLen, resNamesLen: INTEGER;
      nonresOfs: LONGINT;
      alignShift, sectorSize: INTEGER;
      filePos, codeFilePos, dataFilePos: LONGINT;
      dataAllocLen: LONGINT;
      attr: INTEGER;
      summary: ARRAY 160 OF CHAR;
BEGIN
  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("ne: cannot write ", outFileName); RETURN END;

  alignShift := 8; sectorSize := 256;

  dataAllocLen := totalDataLen + totalBssLen + stackSize;
  IF dataAllocLen > LONGINT(0FFFFH) THEN
    LogErr.Error("ne: combined data+bss+stack exceeds 64K (single shared data segment)");
    Files.Close(fout); RETURN
  END;
  IF totalCodeLen > LONGINT(0FFFFH) THEN
    LogErr.Error("ne: code exceeds 64K (single code segment)");
    Files.Close(fout); RETURN
  END;

  ModName(outFileName, modNm);
  NonresName(outFileName, nrName);

  (* ---- table layout (offsets from NE header start), matches LinkNE.MOD ---- *)
  segTblOfs := NeHdrBytes;
  resTblOfs := segTblOfs + 2 * 8;   (* two segments, 8 bytes/entry *)
  resNamesOfs := resTblOfs + 4;

  nlen := 0; WHILE modNm[nlen] # 0X DO INC(nlen) END;
  resNamesLen := (1 + nlen + 2) + 1;
  modRefOfs := resNamesOfs + resNamesLen;
  impNamesOfs := modRefOfs + 2;
  entryTblOfs := impNamesOfs + (1 + 1 + 6);   (* "00 06 KERNEL" *)
  entryTblLen := 4;

  nrLen := 0; WHILE nrName[nrLen] # 0X DO INC(nrLen) END;
  nrTabLen := 1 + nrLen + 2 + 1;
  nonresOfs := LONGINT(StabBytes) + LONGINT(entryTblOfs) + LONGINT(entryTblLen);

  WriteStab(fout);
  IF LogErr.HaveErr() THEN Files.Close(fout); RETURN END;

  (* ---- NE header (64 bytes) ---- *)
  w := Files.WriteWord(fout, 454EH);
  w := Files.WriteByte(fout, BYTE(6));
  w := Files.WriteByte(fout, BYTE(1));
  w := Files.WriteWord(fout, entryTblOfs);
  w := Files.WriteWord(fout, entryTblLen);
  w := Files.WriteDWord(fout, LONGINT(0));
  w := Files.WriteByte(fout, BYTE(PfDGroupMultiple + PfProtMode));
  w := Files.WriteByte(fout, BYTE(AfPmApi));
  w := Files.WriteWord(fout, SegData);          (* auto data seg *)
  w := Files.WriteWord(fout, 0);                (* initial local heap *)
  w := Files.WriteWord(fout, 0);                (* initial stack size (SP set explicitly) *)
  w := Files.WriteWord(fout, entryIp);
  w := Files.WriteWord(fout, SegCode);
  w := Files.WriteWord(fout, INTEGER(dataAllocLen) - 2);   (* SP: top of DATA seg *)
  w := Files.WriteWord(fout, SegData);          (* SS = DATA seg *)
  w := Files.WriteWord(fout, 2);                (* segment count *)
  w := Files.WriteWord(fout, 1);                (* module ref count (KERNEL) *)
  w := Files.WriteWord(fout, nrTabLen);
  w := Files.WriteWord(fout, segTblOfs);
  w := Files.WriteWord(fout, resTblOfs);
  w := Files.WriteWord(fout, resNamesOfs);
  w := Files.WriteWord(fout, modRefOfs);
  w := Files.WriteWord(fout, impNamesOfs);
  w := Files.WriteDWord(fout, nonresOfs);
  w := Files.WriteWord(fout, 0);                (* moveable entry count *)
  w := Files.WriteWord(fout, alignShift);
  w := Files.WriteWord(fout, 0);                (* resource table entries *)
  w := Files.WriteByte(fout, BYTE(1));          (* target OS = OS/2 *)
  w := Files.WriteByte(fout, BYTE(0));
  w := Files.WriteWord(fout, 0);
  w := Files.WriteWord(fout, 0);
  w := Files.WriteWord(fout, 0);
  w := Files.WriteWord(fout, 0300H);
  (* ---- segment table: pass A, compute sector-aligned file offsets ---- *)
  filePos := nonresOfs + LONGINT(nrTabLen);
  filePos := ((filePos + LONGINT(sectorSize) - LONGINT(1)) DIV LONGINT(sectorSize)) * LONGINT(sectorSize);
  codeFilePos := filePos;
  dataFilePos := codeFilePos + totalCodeLen + RelocBlockLen(codeRelCnt);
  dataFilePos := ((dataFilePos + LONGINT(sectorSize) - LONGINT(1)) DIV LONGINT(sectorSize)) * LONGINT(sectorSize);

  (* CODE segment entry *)
  w := Files.WriteWord(fout, INTEGER(codeFilePos DIV LONGINT(sectorSize)));
  w := Files.WriteWord(fout, INTEGER(totalCodeLen));
  attr := SegAttrMoveable + SegAttrDiscard + SegAttrDpl;
  IF codeRelCnt > 0 THEN attr := attr + SegAttrHasRel END;
  w := Files.WriteWord(fout, attr);
  w := Files.WriteWord(fout, INTEGER(totalCodeLen));

  (* DATA segment entry *)
  w := Files.WriteWord(fout, INTEGER(dataFilePos DIV LONGINT(sectorSize)));
  w := Files.WriteWord(fout, INTEGER(totalDataLen));
  attr := SegAttrData + SegAttrPreload + SegAttrDpl;
  IF dataRelCnt > 0 THEN attr := attr + SegAttrHasRel END;
  w := Files.WriteWord(fout, attr);
  w := Files.WriteWord(fout, INTEGER(dataAllocLen));

  (* ---- resource table (empty) ---- *)
  w := Files.WriteWord(fout, alignShift);
  w := Files.WriteWord(fout, 0);

  (* ---- resident names: module name + ordinal 0, then terminator ---- *)
  w := Files.WriteByte(fout, BYTE(nlen));
  k := 0; WHILE k < nlen DO w := Files.WriteByte(fout, BYTE(ORD(modNm[k]))); INC(k) END;
  w := Files.WriteWord(fout, 0);
  w := Files.WriteByte(fout, BYTE(0));

  (* ---- module reference table: 1 entry -> imported-names offset of KERNEL ---- *)
  w := Files.WriteWord(fout, 1);

  (* ---- imported names table: 00 06 "KERNEL" ---- *)
  w := Files.WriteByte(fout, BYTE(0));
  w := Files.WriteByte(fout, BYTE(6));
  w := Files.WriteByte(fout, BYTE(ORD("K"))); w := Files.WriteByte(fout, BYTE(ORD("E")));
  w := Files.WriteByte(fout, BYTE(ORD("R"))); w := Files.WriteByte(fout, BYTE(ORD("N")));
  w := Files.WriteByte(fout, BYTE(ORD("E"))); w := Files.WriteByte(fout, BYTE(ORD("L")));

  (* ---- entry table: EMPTY (4 zero bytes) ---- *)
  w := Files.WriteByte(fout, BYTE(0)); w := Files.WriteByte(fout, BYTE(0));
  w := Files.WriteByte(fout, BYTE(0)); w := Files.WriteByte(fout, BYTE(0));

  (* ---- nonresident names: .exe filename (ord 0), then terminator ---- *)
  w := Files.WriteByte(fout, BYTE(nrLen));
  k := 0; WHILE k < nrLen DO w := Files.WriteByte(fout, BYTE(ORD(nrName[k]))); INC(k) END;
  w := Files.WriteWord(fout, 0);
  w := Files.WriteByte(fout, BYTE(0));

  WriteZeros(fout, filePos - Files.Position(fout));

  (* ---- CODE segment data + reloc block ---- *)
  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("ne: write error (code)")
  END;
  WriteRelocBlock(fout, codeRelHead, codeRelCnt);
  WriteZeros(fout, dataFilePos - Files.Position(fout));

  (* ---- DATA segment data (bss/stack contribute no file bytes) + reloc block ---- *)
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("ne: write error (data)")
    END
  END;
  WriteRelocBlock(fout, dataRelHead, dataRelCnt);

  Files.Close(fout);
  IF ~Files.Ok(fout) THEN
    LogErr.Error2("ne: write error (disk full?): ", outFileName); RETURN
  END;

  Strings.Copy(outFileName, summary);
  Strings.Append(": NE Code=", summary); Strings.AppendInt(totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(totalBssLen,  summary);
  Strings.Append(", Stack=", summary); Strings.AppendInt(stackSize, summary);
  LogErr.Info(summary)
END Write;

END NE.
