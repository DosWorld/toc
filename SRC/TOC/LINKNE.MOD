(*$D-*)
MODULE LinkNE;
(*
  NE-specific consumer of Link's target-agnostic core: writes a Windows/OS-2
  1.x New Executable (NE) file (DOCS/NE.MD), the /CP target.  Sits beside
  LinkMZ as a second, mutually-exclusive consumer of Link's generic core —
  same seam (a segRelocProc callback on Link.PerformLinking), different output
  format.

  Segment model (DOCS/NE-BP.MD Part 2 §2.2): one NE CODE segment per used module's
  own CODE segment, one NE DATA segment per used module's own DATA segment, and
  ONE final NE DATA segment for the shared BSS.  1-based NE segment indices are
  assigned by walking ls^.modHead in order (CODE then DATA per module), then the
  shared BSS last.

  Relocation model (DOCS/NE-BP.MD §1.4 and Part 2 §2.1) — the Borland-Pascal
  /CP PLACEHOLDER model: the file word at every reloc site is a placeholder and
  the NE LOADER writes the real value from the reloc record (LinkNE does NOT bake
  for /CP, unlike LinkMZ).
    - an absolute RELOC (offset fixup, rrel = 0) → NE OFFS (05h) reloc
      {targetSegIdx, targetOffset}, flags = INTERNALREF (0); the site word is
      stamped FFFF;
    - a SEGRELOC (segment-VALUE fixup) → NE BASE (02h) reloc {segIdx, offset},
      flags = 0; the site word is stamped FFFF;
    - a far-pointer site (an OFFS at X immediately followed by a SEGRELOC at
      X+2) is COALESCED into one NE PTR (03h) reloc; the offset word keeps FFFF
      and the segment word is stamped 0000;
    - an IP-relative RELOC (rrel # 0: near call/branch) is position-independent,
      stays BAKED (via Link.OnReloc), and gets NO NE reloc (BPC omits these too).
  Each reloc is appended to the OUTPUT segment the patch site lives in.

  KERNEL.INITTASK (the one external import): the /CP entry stab's first
  instruction is a far call to KERNEL.INITTASK (ordinal 91), emitted by
  TOC.GenEntryStab as an unresolvable import "KERNEL_INITTASK".  It surfaces here
  as the only import FindImport can't resolve (IsExternalImport); OnSegReloc
  emits ONE external PTR (03h) reloc with flags = IMPORTORDINAL (01h), target-seg
  = the KERNEL module-ref index (1), target-offset = the ordinal (91).  Every
  other reloc is internal.

  Scope (§1): entry point, relocations, heap/stack, the fixed KERNEL module
  reference + name tables.  No general imports/exports, no resources.

  NE output cannot be run under xt (MZ-only); it is validated by structural
  byte inspection only against the BPC reference (§6, DOCS/NE-BP.MD).
*)
IMPORT Files, LogErr, Rdoff, Strings, Link;

CONST
  NeHdrBytes  = 64;      (* fixed NE header size *)
  SegChunk    = 32;      (* NE segments per mapping/reloc chunk node *)
  NeRelChunk  = 128;     (* NE relocs per chunk node (small-record rule) *)
  StabBytes   = 512;     (* size of NESTAB.BIN (embedded via $L) -> e_lfanew = 0E3EH *)
  KernelLen   = 6;       (* length of the imported module name "KERNEL" *)

  (* Segment attributes (Table 6) — measured from the reference NE
     (DOCS/NE-BP.MD Part 2 §2.2): every segment carries the 80286 DPL bits (0C00H,
     bits 10-11).  CODE = MOVEABLE + DISCARD + DPL (no PRELOAD, matching the
     reference user-code segment); DATA/BSS = DATA + PRELOAD + DPL.  Either kind
     adds HASRELOC when it owns a non-empty reloc block. *)
  SegAttrData     = 0001H;  (* bit 0: data segment *)
  SegAttrMoveable = 0010H;  (* bit 4: loader may move the segment *)
  SegAttrPreload  = 0040H;  (* bit 6: load immediately, not demand-loaded *)
  SegAttrHasRel   = 0100H;  (* bit 8: relocation block follows the segment *)
  SegAttrDiscard  = 1000H;  (* bit 12: discardable (reloadable from disk) *)
  SegAttrDpl      = 0C00H;  (* bits 10-11: 80286 DPL = 3 (matches reference) *)

  (* NE relocation-item types (Table 10) *)
  RelBASE = 02H;         (* 16-bit segment value (segment-only fixup) *)
  RelPTR  = 03H;         (* 16:16 far pointer (offset word THEN segment word) *)
  RelOFFS = 05H;         (* 16-bit offset within a target segment *)

  (* Relocation flag byte (Table 10) — target-type bits 0-1: internal fixups use
     INTERNALREF (0); the single KERNEL.INITTASK entry-stab call uses
     IMPORTORDINAL (target-seg = module-ref index, target-offset = ordinal). *)
  RelTypeImportOrd = 01H;

  (* The one external import this toolchain emits: KERNEL.INITTASK (the OS/2
     kernel task-init the program's first far call targets under /CP).  The
     KERNEL module reference is modref index 1 (see WriteExe).
     TODO(ordinal): set to the real KERNEL/DOSCALLS INITTASK ordinal. *)
  KernelModRefIdx  = 1;
  InitTaskOrdinal  = 91;   (* KERNEL.INITTASK ordinal (0x5B) — measured in the
                              BPC /CP reference H/T/NEBIG.EXE, see DOCS/NE-BP.MD *)

  (* Program Flags (NE header offset 0Ch) — matches the reference NE (0Ah). *)
  PfDGroupMultiple = 02H; (* bits 0-1 = 10: multiple (unshared) automatic-data
                             groups — each module has its OWN data segment
                             (per-module DS reload), so groups are not shared *)
  PfProtMode       = 08H; (* bit 3: protected-mode only (the /CP target) *)

  (* Application Flags (NE header offset 0Dh) — matches the reference NE (03h). *)
  AfPmApi          = 03H; (* bits 0-2 = 011: uses the Windows/P.M. API *)

(*$A-*)
TYPE
  (* Chunked per-segment NE relocation list (small-record rule): each record is
     8 bytes; the on-disk block is <count WORD><8*count bytes>. *)
  NeReloc = POINTER TO NeRelocRec;
  NeRelocRec = RECORD
    typ:    ARRAY NeRelChunk OF BYTE;    (* reloc source type (RelBASE/PTR/OFFS) *)
    flg:    ARRAY NeRelChunk OF BYTE;    (* reloc flag byte (0 internal / RelTypeImportOrd) *)
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

(*$L NESTAB.RDF*)
PROCEDURE NESTAB;FAR;EXTERNAL;

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
  VAR m: Link.Module; dummy: INTEGER; bssStackLen: LONGINT;
BEGIN
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & ~m^.dup THEN
      dummy := AddSeg(ns, m, Rdoff.SegCode, m^.codeSize, m^.codeSize, FALSE);
      dummy := AddSeg(ns, m, Rdoff.SegData, m^.dataSize, m^.dataSize, TRUE)
    END;
    m := m^.next
  END;
  (* One shared BSS+stack data segment (no file bytes).  allocLen must cover
     BOTH the compiler's BSS globals AND the run-time stack — SS and the auto
     data segment are the same NE segment index (WriteExe), so the stack
     (growing down from SP, set below the BSS globals which sit at offset 0
     upward) would otherwise alias live BSS data the moment real stack depth
     is used.  Mirrors LinkMZ's minAlloc = totalBssLen + stackPara
     (LINKMZ.MOD ~702-704); NE has no >64K segments, so this is a hard error
     rather than MZ's silent 0FFFFH clamp. *)
  bssStackLen := ls^.totalBssLen + ls^.stackSize;
  IF bssStackLen > LONGINT(0FFFFH) THEN
    LogErr.Error("NE: combined BSS+stack exceeds 64K (single shared data segment)");
    RETURN
  END;
  ns^.bssIdx := AddSeg(ns, NIL, Rdoff.SegBss, LONGINT(0), bssStackLen, TRUE)
END BuildSegTable;

(* ---- per-segment reloc list ---- *)

PROCEDURE AddReloc(sn: SegNode; k: INTEGER; typ, flg: BYTE; ofs, tgtSeg, tgtOfs: WORD);
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
  r^.typ[j] := typ; r^.flg[j] := flg; r^.ofs[j] := ofs;
  r^.tgtSeg[j] := tgtSeg; r^.tgtOfs[j] := tgtOfs;
  INC(r^.count);
  INC(sn^.e[k].relCnt)
END AddReloc;

(* Coalesce a far-pointer pair: a preceding OFFS reloc at `ofs` (the offset
   word of an offset:segment far pointer) plus this segment fixup at `ofs`+2
   become a single PTR reloc covering both words.  Searches segment (sn,k)'s
   reloc list for an OFFS at exactly `ofs`; if found, upgrades it in place to
   PTR with the segment target and returns TRUE (caller then emits nothing
   more).  Returns FALSE if there is no such OFFS (a standalone segment fixup
   → caller emits BASE). *)
PROCEDURE CoalesceToPtr(sn: SegNode; k: INTEGER; ofs, tgtSeg: WORD): BOOLEAN;
  VAR r: NeReloc; j: INTEGER;
BEGIN
  r := sn^.e[k].relHead;
  WHILE r # NIL DO
    j := 0;
    WHILE j < r^.count DO
      IF (r^.typ[j] = RelOFFS) & (r^.ofs[j] = ofs) THEN
        r^.typ[j] := RelPTR;
        r^.tgtSeg[j] := tgtSeg;   (* segment part of the far pointer *)
        (* tgtOfs already holds the offset part (from the OFFS record) *)
        r^.flg[j] := BYTE(0);     (* internal fixup (INTERNALREF) *)
        RETURN TRUE
      END;
      INC(j)
    END;
    r := r^.next
  END;
  RETURN FALSE
END CoalesceToPtr;

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

(* Resolve a RELOC's target OFFSET within its own segment (mirrors the fixup
   math in Link.OnReloc): self-CODE/DATA references start at 0; a BSS reference
   adds the module's BSS slice; an import adds the symbol's own in-segment
   offset (+ its BSS slice for a BSS symbol). *)
PROCEDURE TargetOffset(ls: Link.State; m: Link.Module; rrefSeg: INTEGER): WORD;
  VAR sym: Link.Symbol; so: Link.Module;
BEGIN
  IF (rrefSeg = Rdoff.SegCode) OR (rrefSeg = Rdoff.SegData) THEN RETURN 0
  ELSIF rrefSeg = Rdoff.SegBss THEN RETURN WORD(m^.bssOfs)
  ELSE
    sym := Link.FindImport(rrefSeg);
    IF sym = Link.NoSym THEN RETURN 0 END;
    IF Link.SymSegId(ls, sym) = 2 THEN
      so := Link.SymOwner(ls, sym);
      RETURN WORD(Link.SymOffset(ls, sym)) + WORD(so^.bssOfs)
    END;
    RETURN WORD(Link.SymOffset(ls, sym))
  END
END TargetOffset;

(* Locate the output NE segment (index + chunk-node/slot) that a patch site in
   rseg of the current module belongs to. *)
PROCEDURE OutSeg(m: Link.Module; rseg: INTEGER; VAR sn: SegNode; VAR k: INTEGER): INTEGER;
  VAR outIdx: INTEGER;
BEGIN
  IF rseg = Rdoff.SegCode THEN outIdx := SegIndexOf(curNs, m, Rdoff.SegCode)
  ELSE outIdx := SegIndexOf(curNs, m, Rdoff.SegData) END;
  sn := SegOf(curNs, outIdx); k := (outIdx - 1) MOD SegChunk;
  RETURN outIdx
END OutSeg;

(* TRUE when rrefSeg names an import that does NOT resolve to any linked symbol.
   In this no-import model the only such import is the entry stab's
   KERNEL.INITTASK sentinel — a genuine OS/2 external fixup (see GenEntryStab /
   NE-BP.MD §1.4).  Every real IMPORT resolves; anything unresolved here is
   INITTASK. *)
PROCEDURE IsExternalImport(rrefSeg: INTEGER): BOOLEAN;
BEGIN
  RETURN (rrefSeg # Rdoff.SegCode) & (rrefSeg # Rdoff.SegData) &
         (rrefSeg # Rdoff.SegBss) & (Link.FindImport(rrefSeg) = Link.NoSym)
END IsExternalImport;

(* onRelocProc for Link.PerformLinking (BPC-reference placeholder model,
   NE-BP.MD §1.4).  A real NE loader WRITES each reloc'd site from the reloc
   record at load time; the file word is an FFFF placeholder.  So for an ABSOLUTE
   offset fixup (rrel = 0) we do NOT bake — we compute the target offset, stamp
   the site with FFFF, and record an NE OFFS reloc (flags = INTERNALREF 0) for
   the loader.  IP-relative fixups (rrel # 0, near call/branch) are
   position-independent, get NO NE reloc, and DO need the byte patch — those
   still go through Link.OnReloc. *)
PROCEDURE OnReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                  rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR ls: Link.State; m: Link.Module;
      tgtIdx: INTEGER; tgtOfs: WORD;
      sn: SegNode; k, dummy: INTEGER;
BEGIN
  (* The KERNEL.INITTASK external far call: its offset word carries no internal
     reloc — the paired SEGRELOC (segment word) emits ONE external PTR covering
     both words.  Leave this word to OnSegReloc. *)
  IF IsExternalImport(rrefSeg) THEN RETURN END;

  IF rrel # 0 THEN
    (* IP-relative near call/branch: bake it, no NE reloc (BPC omits these). *)
    Link.OnReloc(rseg, rofs, rwidth, rrefSeg, rrel);
    RETURN
  END;

  ls := Link.CurrentState();
  m  := Link.CurrentModule();
  tgtIdx := TargetSegIndex(ls, m, rrefSeg);
  IF LogErr.HaveErr() THEN RETURN END;

  (* target offset the loader will write.  For a SELF CODE/DATA reference the
     compiler already baked the real in-segment offset into the operand — read it
     before overwriting.  For an import/BSS reference use TargetOffset. *)
  IF (rrefSeg = Rdoff.SegCode) OR (rrefSeg = Rdoff.SegData) THEN
    tgtOfs := Link.ReadSiteWord(rseg, rofs)
  ELSE
    tgtOfs := TargetOffset(ls, m, rrefSeg)
  END;

  (* stamp the FFFF placeholder (the loader writes tgtOfs) *)
  Link.WriteSiteWord(rseg, rofs, WORD(0FFFFH));

  dummy := OutSeg(m, rseg, sn, k);
  (* internal fixup: flags = INTERNALREF (0).  The import-ordinal bit (01H) is
     reserved for the KERNEL.INITTASK external reloc — using it here would make a
     real NE loader mis-read an internal OFFS as an external import. *)
  AddReloc(sn, k, RelOFFS, BYTE(0), WORD(rofs), WORD(tgtIdx), tgtOfs)
END OnReloc;

(* segRelocProc for Link.PerformLinking (BPC-reference placeholder model,
   NE-BP.MD §1.4).  A SEGRELOC targets a segment VALUE.  The loader writes the
   selector from the reloc record; the file word is a placeholder we do NOT bake.
   If the immediately-preceding word (rofs-2) already carries an OFFS reloc, the
   two are one far pointer → coalesce into a single PTR and stamp the SEGMENT word
   0000 (the paired offset word already holds FFFF).  Otherwise emit a standalone
   BASE (segment-only) reloc and stamp the word FFFF; a self-segment BASE keeps
   the compiler-baked offset as the reloc's target-offset. *)
PROCEDURE OnSegReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                     rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR ls: Link.State; m: Link.Module;
      tgtIdx, k, dummy: INTEGER;
      sn: SegNode; baseOfs: WORD;
BEGIN
  ls := Link.CurrentState();
  m  := Link.CurrentModule();

  (* KERNEL.INITTASK external far call: emit ONE external-import PTR covering the
     whole far pointer (offset word at rofs-2, segment word at rofs).  The loader
     resolves it via the module-reference table — flags = IMPORTORDINAL,
     target-seg = KERNEL module-ref index, target-offset = INITTASK ordinal.
     Stamp the BPC placeholder: offset word FFFF, segment word 0000. *)
  IF IsExternalImport(rrefSeg) THEN
    Link.WriteSiteWord(rseg, rofs - LONGINT(2), WORD(0FFFFH));
    Link.WriteSiteWord(rseg, rofs, WORD(0));
    dummy := OutSeg(m, rseg, sn, k);
    AddReloc(sn, k, RelPTR, RelTypeImportOrd, WORD(rofs - LONGINT(2)),
             WORD(KernelModRefIdx), WORD(InitTaskOrdinal));
    RETURN
  END;

  tgtIdx := TargetSegIndex(ls, m, rrefSeg);
  IF LogErr.HaveErr() THEN RETURN END;

  (* a standalone self-segment site may hold a compiler-baked offset (e.g.
     `mov ax, offset X`) — capture it before stamping the placeholder *)
  baseOfs := Link.ReadSiteWord(rseg, rofs);

  dummy := OutSeg(m, rseg, sn, k);
  (* far pointer?  the offset word sits at rofs-2 in the SAME output segment. *)
  IF (rofs >= LONGINT(2)) &
     CoalesceToPtr(sn, k, WORD(rofs - LONGINT(2)), WORD(tgtIdx)) THEN
    (* upgraded the preceding OFFS to PTR — stamp the segment word 0000 *)
    Link.WriteSiteWord(rseg, rofs, WORD(0))
  ELSE
    (* standalone segment value — placeholder FFFF, keep the baked offset *)
    Link.WriteSiteWord(rseg, rofs, WORD(0FFFFH));
    AddReloc(sn, k, RelBASE, BYTE(0), WORD(rofs), WORD(tgtIdx), baseOfs)
  END
END OnSegReloc;

(* Drives the generic core with NE's onReloc + segRelocProc.  BuildSegTable
   must have run first (both callbacks resolve target indices through curNs). *)
PROCEDURE PerformLinking*(ls: Link.State; ns: State);
BEGIN
  curNs := ns;
  Link.PerformLinking(ls, OnReloc, OnSegReloc)
END PerformLinking;

(* ---- write NE EXE ---- *)

(* MZ stab: the verbatim Borland-Pascal /CP DOS stab, embedded in the linker
   binary via `(*$L NESTAB.RDF*)` (assembled from SRC/TOC/NESTAB.BIN by TASM)
   and written byte-for-byte (DOCS/NE-BP.MD §1).  Its own e_lfanew field (at
   MZ offset 3Ch) is NOT trusted to already equal StabBytes -- NESTAB.BIN has
   been swapped before without every generation baking a correct e_lfanew
   (one such swap shipped with e_lfanew=0, silently pointing the NE header
   lookup back at the MZ header itself and corrupting every downstream file
   offset) -- so this always overwrites offset 3Ch with StabBytes explicitly
   after writing the stab bytes, rather than trusting whatever the embedded
   stab happens to already contain there.  Embedding it (vs reading a file at
   link time) means /CP needs no external NESTAB.BIN on the search path. *)
PROCEDURE WriteStab(VAR fout: Files.File);
  VAR p: SYSTEM.ADDRESS; savedPos: LONGINT;
BEGIN
  p := SYSTEM.ADR(NESTAB);
  Files.BlockWrite(fout, p^, StabBytes);
  savedPos := Files.Position(fout);
  Files.Seek(fout, LONGINT(3CH));
  Files.WriteDWord(fout, LONGINT(StabBytes));
  Files.Seek(fout, savedPos)
END WriteStab;

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
      w := Files.WriteByte(fout, r^.flg[j]);         (* flag byte (additive?) *)
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

(* Build the nonresident-names entry: the .exe filename (stem + ".EXE",
   uppercase), matching the reference NE (its nonresident name is "H.EXE"). *)
PROCEDURE BuildNonresName(ns: State; VAR out: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE ns^.modName[i] # 0X DO out[i] := ns^.modName[i]; INC(i) END;
  out[i] := "."; INC(i);
  out[i] := "E"; INC(i); out[i] := "X"; INC(i); out[i] := "E"; INC(i);
  out[i] := 0X
END BuildNonresName;

PROCEDURE WriteExe*(ls: Link.State; ns: State; outPath: ARRAY OF CHAR);
  VAR fout: Files.File;
      neOfs: LONGINT;
      i, k, w, nlen, attr: INTEGER;
      sn: SegNode;
      entryIdx: INTEGER;      (* NE seg idx of entry proc's CODE segment *)
      entrySeg: Link.Module;
      esym: Link.Symbol;
      (* table offsets (from NE header start) *)
      segTblOfs, resTblOfs, resNamesOfs, modRefOfs, impNamesOfs, entryTblOfs: INTEGER;
      nonresOfs: LONGINT;
      entryTblLen, resNamesLen: INTEGER;
      nrName: ARRAY 16 OF CHAR;
      nrLen, nrTabLen: INTEGER;
      alignShift, sectorSize: INTEGER;
      filePos, segFilePos: LONGINT;
      summary: ARRAY 128 OF CHAR;
      m: Link.Module;
      bssSeg: SegNode; bssStackLen: LONGINT;
BEGIN
  IF ~Files.ReWrite(fout, outPath) THEN LogErr.Error2("Cannot write: ", outPath); RETURN END;

  neOfs := LONGINT(StabBytes);
  alignShift := 8; sectorSize := 256;   (* 256-byte sectors (matches reference) *)

  (* SP must point at the TOP of the shared BSS+stack segment (BuildSegTable
     sized allocLen = totalBssLen + stackSize, BSS globals occupy the low
     offsets from 0 upward) — not at a fixed low offset that ignores where
     the compiler's own BSS data ends, or the descending stack aliases live
     globals the first time real call depth is used. *)
  bssSeg := SegOf(ns, ns^.bssIdx);
  bssStackLen := bssSeg^.e[(ns^.bssIdx - 1) MOD SegChunk].allocLen;

  (* resolve entry point: "start" symbol's own module CODE segment *)
  esym := Link.FindSymbol(ls, "start");
  entryIdx := 0;
  IF esym # Link.NoSym THEN
    entrySeg := Link.SymOwner(ls, esym);
    entryIdx := SegIndexOf(ns, entrySeg, Rdoff.SegCode)
  END;

  (* ---- table layout (offsets from NE header start) ----
     Order in the header area (matches the reference NE, DOCS/NE-BP.MD §1.2/§1.3):
     [NE header 64B][segment table][resource table (empty)][resident names]
     [module ref table (1 KERNEL entry)][imported names ("KERNEL")][entry table].
     Nonresident names table is at a file offset after the entry table. *)
  segTblOfs := NeHdrBytes;
  resTblOfs := segTblOfs + ns^.segCount * 8;
  (* resource table present but empty: align shift WORD + terminating type 0 WORD *)
  resNamesOfs := resTblOfs + 4;

  (* resident names: [len][NAME][ordinal WORD] then terminating [0] *)
  nlen := 0; WHILE ns^.modName[nlen] # 0X DO INC(nlen) END;
  resNamesLen := (1 + nlen + 2) + 1;
  modRefOfs := resNamesOfs + resNamesLen;
  (* module reference table: 1 entry (2 bytes) -> imported-names offset of KERNEL *)
  impNamesOfs := modRefOfs + 2;
  (* imported names table: 00 06 "KERNEL"  = 8 bytes.  The leading length-0 byte
     at offset 0 is the terminator convention; the counted "KERNEL" at offset 1
     is what the module-ref entry names (matches the reference — no trailing 0). *)
  entryTblOfs := impNamesOfs + (1 + 1 + KernelLen);
  (* entry table: EMPTY, like the reference NE (Turbo).  The program entry
     point is given solely by the NE header's CS:IP (a movable/exported entry
     is not needed — no exports).  Turbo writes a 4-byte all-zero table (an
     empty terminating bundle + padding); we match that width. *)
  entryTblLen := 4;

  (* nonresident names: one entry (the .exe filename, ord 0) then terminating
     length-0, placed right after the header area, before segment data.
     Length field = 1(len) + nrLen + 2(ord) + 1(term). *)
  BuildNonresName(ns, nrName); nrLen := 0;
  WHILE nrName[nrLen] # 0X DO INC(nrLen) END;
  nrTabLen := 1 + nrLen + 2 + 1;
  nonresOfs := neOfs + LONGINT(entryTblOfs) + LONGINT(entryTblLen);

  (* ---- MZ stab (verbatim NESTAB.BIN; its own e_lfanew = StabBytes) ---- *)
  WriteStab(fout);
  IF LogErr.HaveErr() THEN Files.Close(fout); RETURN END;

  (* ---- NE header (64 bytes) ---- *)
  w := Files.WriteWord(fout, 454EH);                 (* "NE" *)
  w := Files.WriteByte(fout, BYTE(6));               (* linker ver major *)
  w := Files.WriteByte(fout, BYTE(1));               (* linker ver minor *)
  w := Files.WriteWord(fout, entryTblOfs);           (* entry table offset *)
  w := Files.WriteWord(fout, entryTblLen);           (* entry table length *)
  w := Files.WriteDWord(fout, LONGINT(0));           (* file load CRC *)
  (* program flags: DGROUP multiple (unshared) + protected-mode-only (0Ah),
     matching the reference NE.  8086/8087 bits left clear as the reference
     does. *)
  w := Files.WriteByte(fout, BYTE(PfDGroupMultiple + PfProtMode));
  (* application flags: uses the Windows/P.M. API (011), matching the reference. *)
  w := Files.WriteByte(fout, BYTE(AfPmApi));
  w := Files.WriteWord(fout, ns^.bssIdx);            (* auto data seg = shared BSS *)
  w := Files.WriteWord(fout, 0);                     (* initial local heap = 0
                                                        (matches reference) *)
  w := Files.WriteWord(fout, 0);                     (* initial stack size = 0
                                                        (SP set explicitly below) *)
  w := Files.WriteWord(fout, ls^.entryIp);           (* entry IP *)
  w := Files.WriteWord(fout, entryIdx);              (* entry CS = NE seg idx *)
  w := Files.WriteWord(fout, INTEGER(bssStackLen) - 2); (* SP: top of BSS+stack seg *)
  w := Files.WriteWord(fout, ns^.bssIdx);            (* SS = shared BSS (DGROUP) *)
  w := Files.WriteWord(fout, ns^.segCount);          (* segment count *)
  w := Files.WriteWord(fout, 1);                     (* module ref count (KERNEL) *)
  w := Files.WriteWord(fout, nrTabLen);              (* nonresident names len *)
  w := Files.WriteWord(fout, segTblOfs);             (* segment table offset *)
  w := Files.WriteWord(fout, resTblOfs);             (* resource table offset *)
  w := Files.WriteWord(fout, resNamesOfs);           (* resident names offset *)
  w := Files.WriteWord(fout, modRefOfs);             (* module ref table offset *)
  w := Files.WriteWord(fout, impNamesOfs);           (* imported names offset *)
  w := Files.WriteDWord(fout, nonresOfs);            (* nonresident names offset (file) *)
  w := Files.WriteWord(fout, 0);                     (* moveable entry count *)
  w := Files.WriteWord(fout, alignShift);            (* file align shift count *)
  w := Files.WriteWord(fout, 0);                     (* resource table entries *)
  w := Files.WriteByte(fout, BYTE(1));               (* target OS = OS/2 (matches reference) *)
  w := Files.WriteByte(fout, BYTE(0));               (* other exe flags *)
  w := Files.WriteWord(fout, 0);                     (* return thunks *)
  w := Files.WriteWord(fout, 0);                     (* seg ref thunks *)
  w := Files.WriteWord(fout, 0);                     (* min code swap area *)
  w := Files.WriteWord(fout, 0300H);                 (* expected version 3.0 (matches reference) *)

  (* ---- segment table (filled after segment file offsets are known) ---- *)
  (* The segment table's File Offset field is in sectors; segment data starts
     after the whole header area (which ends at nonresOfs + nrTabLen -- the
     nonresident-names table is NOT empty, it always carries the .EXE
     filename entry built above).  Round each segment start up to a sector
     boundary.  We first compute each segment's sector, then stream the
     table, then the data.  Two-pass: pass A assigns sectors; pass B writes
     table + data. *)

  (* pass A: assign each segment a sector-aligned file offset *)
  filePos := nonresOfs + LONGINT(nrTabLen);   (* end of header area *)
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
    (* attributes (matches the reference NE, DOCS/NE-BP.MD §1.2/§1.3): every segment
       carries DPL bits (0C00H).  DATA/BSS = DATA + PRELOAD + DPL (0C41H); CODE
       = MOVEABLE + DISCARD + DPL (1C10H, no PRELOAD, matching the reference
       user-code segment).  Either kind gets the HASRELOC bit when it owns a
       non-empty reloc block. *)
    IF sn^.e[k].isData THEN
      attr := SegAttrData + SegAttrPreload + SegAttrDpl
    ELSE
      attr := SegAttrMoveable + SegAttrDiscard + SegAttrDpl
    END;
    IF sn^.e[k].relCnt > 0 THEN attr := attr + SegAttrHasRel END;
    w := Files.WriteWord(fout, attr);
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

  (* ---- module reference table: 1 entry = imported-names offset of KERNEL ---- *)
  w := Files.WriteWord(fout, 1);        (* offset 1 into imported names -> "KERNEL" *)

  (* ---- imported names table: 00 06 "KERNEL"  (matches reference; the leading
     length-0 byte is the terminator convention, "KERNEL" at offset 1) ---- *)
  w := Files.WriteByte(fout, BYTE(0));  (* offset 0: terminating length-0 *)
  w := Files.WriteByte(fout, BYTE(KernelLen));
  w := Files.WriteByte(fout, BYTE(ORD("K"))); w := Files.WriteByte(fout, BYTE(ORD("E")));
  w := Files.WriteByte(fout, BYTE(ORD("R"))); w := Files.WriteByte(fout, BYTE(ORD("N")));
  w := Files.WriteByte(fout, BYTE(ORD("E"))); w := Files.WriteByte(fout, BYTE(ORD("L")));

  (* ---- entry table: EMPTY (matches reference NE) — 4 zero bytes.  The entry
     point is the NE header's CS:IP; no entry-table bundle is needed. ---- *)
  w := Files.WriteByte(fout, BYTE(0)); w := Files.WriteByte(fout, BYTE(0));
  w := Files.WriteByte(fout, BYTE(0)); w := Files.WriteByte(fout, BYTE(0));

  (* ---- nonresident names table: .exe filename (ord 0) then terminator ---- *)
  w := Files.WriteByte(fout, BYTE(nrLen));
  i := 0; WHILE i < nrLen DO w := Files.WriteByte(fout, BYTE(ORD(nrName[i]))); INC(i) END;
  w := Files.WriteWord(fout, 0);        (* ordinal *)
  w := Files.WriteByte(fout, BYTE(0));  (* terminating length-0 *)

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
        Files.BlockCopy(ls^.spillFile, fout, sn^.e[k].dataLen)
      ELSE
        Files.Seek(ls^.dataFile, Link.DataFileOffsetOf(ls, m, LONGINT(0)));
        Files.BlockCopy(ls^.dataFile, fout, sn^.e[k].dataLen)
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
