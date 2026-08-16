(*$D-,O-*)
MODULE Link;
(*
  RDOFF2 smart linker core for MS-DOS — target-agnostic (scan, symbol table,
  mark, layout, patch/relocate, buffer/group management).  Output-format
  writers (LinkMZ for DOS real-mode .EXE, LinkNE for NE) sit on top of this
  module's public surface; segment-VALUE fixups (MZ relocs / NE per-segment
  reloc records) are supplied by the caller as a segRelocProc callback to
  PerformLinking, never hardcoded here.

  Phase 1: scan modules, build symbol table, calculate layout.
  Phase 2: load code/data into heap buffers, apply all relocations (via
           PerformLinking's segRelocProc callback for segment-value fixups).
  Phase 3 (writer-specific, NOT here): serialize the linked image to an
           output executable format — see LinkMZ.WriteExe / LinkNE.WriteExe.

  Memory strategy (DOS-safe):
  - Each code group <= 64KB: one CodeBuf per group, allocated with NEW.
  - All data combined into one DataBuf <= 64KB.
*)
IMPORT Dos, Files, LogErr, Rdoff, Tar, Strings, StrTab;

CONST
  SymHash*   = 256;      (* symbol hash table size, power of 2 *)
  MaxPath*   = 128;
  (* Default stack size when the entry module has no `$M` directive.  Raising
     this blanket default was tried on 2026-07-10 (to paper over TOC.MOD's
     `$M` directive not reaching the linker) and reverted: every program
     with no `$M` of its own (e.g. SRC/TOOLS/*.MOD) inherited the bigger
     stack too, shrinking the DOS minAlloc headroom left for its runtime
     heap and causing unrelated "StrTab: out of memory" failures in small
     tools that never needed a big stack.  The real fix is making sure each
     entry module's own `$M` directive (or lack of one, when 8192 is
     genuinely enough) reaches the linker correctly — see
     TESTS/FIX/SYSCOMMENT_STACK_BUG.md for the syscomment-queue fix that
     makes TOC.MOD's own `$M 32000,...` propagate now. *)
  StackDef   = 8192;     (* default stack size *)
  ImpChunk   = 128;      (* IMPORT entries per chunk node (small-record rule) *)
  SymChunk   = 128;      (* symbols per chunk node (small-record rule) — MUST be a
                            power of two: index->(chunk,slot) uses LSR/AND, not
                            DIV/MOD, to stay off the slow path in the reloc loop *)
  SymShift   = 7;        (* LOG2(SymChunk): i DIV SymChunk = LSR(i, SymShift) *)
  SymMask    = 127;      (* SymChunk - 1: i MOD SymChunk = AND(i, SymMask) *)
  MaxSymChunk= 128;      (* directory size: up to MaxSymChunk*SymChunk symbols *)
  NoSym*     = 0FFFFH;    (* null symbol handle (WORD sentinel; valid idx 0..65534) *)

CONST
  OvrEntryChunk = 16;   (* overlay entry-point names per chunk node (small-record rule) *)
  OvrFixupChunk = 64;   (* internal fixup-table WORD offsets per chunk node *)
  OvrSiteChunk  = 32;    (* call-site patch-table entries per chunk node *)
  OvrNoOwner    = 0FFFFH; (* OvrSiteNodeRec.ownerGlobalId sentinel: this site
                             lives in the MAIN IMAGE, not inside another
                             overlay module's own code (cross-overlay calls,
                             DOCS/OVR.MD §9) -- the ordinary, pre-existing case. *)

TYPE
  (* Local copy of Rdoff.RelocProc's own signature, used ONLY for
     lnkSegRelocProc below (a module-level VAR, not a parameter).  A
     PROC-typed VALUE crossing the .def boundary (Rdoff.RelocProc as seen
     from THIS file, a separate compilation unit from RDOFF.MOD) loses its
     formal parameter list -- .def's own PROC-type record carries no
     signature (confirmed 2026-08-15: RDFGREP om-extract on TRUBO.OM's own
     RDOFF.DEF shows bare "TYPE Rdoff_RelocProc PROC", no params) -- so a
     VAR declared straight as Rdoff.RelocProc rejects a real 5-argument
     call ("too many parameters") even though the exact same shape works
     fine as an ordinary PARAMETER (segRelocProc: Rdoff.RelocProc in
     PerformLinking's own signature below), since a parameter's type comes
     from THIS file's own fresh parse, never round-tripped through a
     .def.  This local type dodges the round-trip entirely. *)
  LocalRelocProc = PROCEDURE(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                              rrefSeg: INTEGER; rrel: INTEGER);

  (* Chunked overlay entry-point name list (DOCS/OVR.MD §11.2), read from
     the module's own MODNAME.OVR member (ENTRYn=name lines, in declaration
     order -- that declaration order IS the entry id assigned to each
     trampoline's id byte, matching the .OVR file's own per-module table). *)
  OvrEntryNode* = POINTER TO OvrEntryNodeRec;
  OvrEntryNodeRec* = RECORD
    name*:  ARRAY OvrEntryChunk OF ARRAY 33 OF CHAR;
    count*: INTEGER;
    next*:  OvrEntryNode
  END;

  (* Chunked internal fixup table (DOCS/OVR.MD §7): byte
     offsets WITHIN this overlay module's own code where a self-referencing
     SegCode/SegData/SegBss RELOC or SEGRELOC needs a runtime, load-segment-
     dependent adjustment -- collected during this module's own reloc scan
     (OnReloc/OnSegRelocForOverlay), deferred instead of baked, since the
     real load segment is chosen at OVERLAY.MOD's runtime, not at link time. *)
  OvrFixupNode* = POINTER TO OvrFixupNodeRec;
  OvrFixupNodeRec* = RECORD
    ofs*:   ARRAY OvrFixupChunk OF WORD;
    count*: INTEGER;
    next*:  OvrFixupNode
  END;

  (* Chunked call-site patch table (DOCS/OVR.MD §8): one entry
     per external call site that targets one of THIS module's entry points --
     recorded as a byproduct of OnReloc's opcode-rewrite path (the call site
     is already being visited there).  siteFileOfs is the site's byte offset,
     meaning depends on ownerGlobalId:
       ownerGlobalId = OvrNoOwner (0FFFFH): site lives in the MAIN IMAGE --
         siteFileOfs is absolute within the FINAL .exe's CODE region
         (paragraph*16 + in-module offset), unchanged from the original
         (pre-cross-overlay-calls) scheme.
       ownerGlobalId = some overlay module's own ovrEntryIdBase (cross-overlay
         calls, DOCS/OVR.MD §9): the CALLING code itself
         lives inside another $O+ module's own code, which has no fixed
         runtime address at all until THAT module is next loaded -- siteFileOfs
         is instead relative to the owning module's own code blob (its
         ovrCodeOfs origin), and the runtime resolves ownerGlobalId back to
         a ModuleHeader (Overlay.DirEntry/RegisterModule, the SAME machinery an
         ordinary trampoline hit already uses) to find its current destParas
         before adding siteOfs. *)
  OvrSiteNode* = POINTER TO OvrSiteNodeRec;
  OvrSiteNodeRec* = RECORD
    siteFileOfs*:   ARRAY OvrSiteChunk OF LONGINT;
    entryId*:       ARRAY OvrSiteChunk OF WORD;
    ownerGlobalId*: ARRAY OvrSiteChunk OF WORD;
    count*:         INTEGER;
    next*:          OvrSiteNode
  END;

  (* Chunked return-address-trampoline table (DOCS/OVR.MD §9): one entry per call site INSIDE this
     module's own code that itself calls into another overlay module.  Unlike
     an ordinary OvrEntryNode name (a real, source-declared public
     PROCEDURE), a resume point is purely a link-time artifact -- it has
     no name, exists only so the call's own return address is
     independently reloadable if this module gets evicted while the callee
     is still running.  ofs is the in-module code offset the resume point's
     own trampoline lives at (the return address itself, i.e. patchAddr+5
     of the call site being rewritten); globalId is its own fresh entry
     id (Link.State.ovrNextEntryId, same counter ordinary entries use);
     calleeGlobalId is the entry id of the module whose call THIS resume
     point returns from -- OvrDispatch needs it to know whose inUse to
     decrement on resume (Overlay.OvrDispatch's own resume-point branch). *)
  OvrResumeNode* = POINTER TO OvrResumeNodeRec;
  OvrResumeNodeRec* = RECORD
    ofs*:            ARRAY OvrFixupChunk OF WORD;
    globalId*:       ARRAY OvrFixupChunk OF WORD;
    calleeGlobalId*: ARRAY OvrFixupChunk OF WORD;
    count*:          INTEGER;
    next*:           OvrResumeNode
  END;

  Module* = POINTER TO ModRec;
  ModRec* = RECORD
    path*:         ARRAY MaxPath OF CHAR;
    stem*:         ARRAY 10 OF CHAR;  (* member basename w/o ".RDF" (<=8) — "" when
                                         no MODNAME.DBG can exist ($L extras etc.) —
                                         used by both LinkMZ's and LinkNE's
                                         TDS/TDINFO debug writers *)
    hasDbg*:       BOOLEAN;   (* non-empty MODNAME.DBG found (debug pass 1) — LinkMZ/LinkNE *)
    dbgModName*:   INTEGER;   (* pool ordinal of the module ident (M line) — LinkMZ/LinkNE *)
    dbgSrcName*:   INTEGER;   (* pool ordinal of the source file name (F line) — LinkMZ/LinkNE *)
    dbgTypeBase*:  WORD;      (* this module's local TYPE indices are offset by this — LinkMZ/LinkNE *)
    dbgMembBase*:  WORD;      (* this module's local MEMBER indices are offset by this — LinkMZ/LinkNE *)
    libOfs*:       LONGINT;
    rawSize:       LONGINT;
    hdrSize*:      LONGINT;
    codeSize*:     LONGINT;
    dataSize*:     LONGINT;
    bssSize*:      LONGINT;
    codePara*:     WORD;      (* this module's own CODE segment paragraph,
                                 0-based from image start — WORD, not INTEGER:
                                 paragraphs exceed 32767 once the image passes
                                 512 KB. One module = one CODE segment: no more
                                 grouping (each module's .rdf is already
                                 self-contained by the time it reaches Link —
                                 see DOCS/NE-BP.MD Part 2 §2.2). *)
    dataPara*:     WORD;      (* this module's own DATA segment paragraph *)
    bssOfs*:       LONGINT;   (* this module's own byte offset WITHIN the one
                                 shared BSS segment (State.bssPara) — all
                                 modules share ONE BSS segment (unlike CODE/
                                 DATA, which are per-module); this is just
                                 this module's own slice of it. Carries NO
                                 file bytes at all (DOS zero-fills the whole
                                 shared BSS region via min_alloc at load) —
                                 see WriteExe. *)
    isOverlay*:    BOOLEAN;   (* TRUE iff MODNAME.OVR exists and starts "OVERLAY=1"
                                 (DOCS/OVR.MD §4) -- set once, at scan time,
                                 by ScanRdf.  Real replacement for the prototype's
                                 hardcoded module-name check in OnReloc. *)
    ovrEntries*:   OvrEntryNode;  (* head chunk: this module's own entry-point
                                     name list, in declaration order == LOCAL
                                     entry index within this module (add
                                     ovrEntryIdBase for the GLOBAL id); NIL
                                     when isOverlay is FALSE *)
    ovrNEntries*:  INTEGER;
    ovrEntryIdBase*: WORD;    (* DOCS/OVR.MD §11.1: this module's first
                                 entry's GLOBAL id.  DOCS/OVR.MD §5's trampoline
                                 id byte must be globally unique across every
                                 overlay module in the program -- the trap
                                 handler has no other way to know WHICH module a
                                 trapped call site targets.  Assigned once, as
                                 a running counter across all used isOverlay
                                 modules, by CalculateLayout (same pass that
                                 already walks them for codePara exclusion).
                                 Module M's own entry k (0-based, declaration
                                 order) has global id M^.ovrEntryIdBase + k. *)
    ovrFixups*:    OvrFixupNode;  (* head chunk: internal fixup table (§5) --
                                     self-referencing SegCode targets only;
                                     runtime adds THIS module's own load segment
                                     (destParas) to each *)
    ovrNFixups*:   INTEGER;
    ovrXFixups*:   OvrFixupNode;  (* head chunk: cross-module fixup table --
                                     targets a RESIDENT module's own CODE/DATA/
                                     BSS (so^.codePara/dataPara/bssPara), baked
                                     load-segment-relative same as any main-
                                     image reloc, but with no MZ loader entry
                                     to add the real load segment at load time
                                     (.OVR content is never touched by the DOS
                                     MZ loader) -- runtime adds the PROGRAM's
                                     own load segment (Overlay.LoadSegment())
                                     to each, a different base than ovrFixups'
                                     own destParas addend. *)
    ovrNXFixups*:  INTEGER;
    ovrSites*:     OvrSiteNode;   (* head chunk: call-site patch table (§6) --
                                     sites elsewhere in the image that target
                                     one of THIS module's entry points *)
    ovrNSites*:    INTEGER;
    ovrResumes*:   OvrResumeNode; (* head chunk: return-address-trampoline
                                     table -- call sites INSIDE this
                                     module's own code that call into
                                     another overlay module (cross-overlay
                                     calls, DOCS/OVR.MD §9); NIL unless this
                                     module itself makes such a call *)
    ovrNResumes*:  INTEGER;
    ovrCodeOfs*:   LONGINT;   (* this module's own code's byte offset within
                                 the .OVR file's data region, once laid out
                                 (LinkOvr.CalculateOvrLayout) *)
    used*:         BOOLEAN;
    dup*:          BOOLEAN;   (* TRUE if this .rdf was already linked from another .om *)
    nGlob:         INTEGER;   (* count of globals seen so far (for dup detection) *)
    next*:         Module
  END;

  (* A Symbol is a WORD handle (index into the chunked symbol store), NOT a
     pointer — chunking requires index handles (Oberon can't point into an array).
     WORD is the fast unsigned type; NoSym (0FFFFH) is the null handle.  SymRec.owner
     stays a Module POINTER (modules are not chunked); next/hNext are index handles. *)
  Symbol* = WORD;
  (* name is a StrTab-interned id, not raw text (was ARRAY MaxName OF CHAR +
     a separately-cached Strings.HashCode) — StrTab already de-duplicates
     and hashes every name once; comparing two symbols is now a single
     StrTab.TStrTabId compare (nameId equality) instead of Strings.Equal on
     34-byte arrays, and each SymRec drops from name(34)+hashCode(2)=36 B
     to nameId(2) B.
     SAFETY INVARIANT: every nameId stored here is Intern'd/Find'd within
     the SAME LinkAll() call that reads it back — Syms.OpenStores (one per
     Phase-2 module compile) resets StrTab per-compile, but Phase 2 always
     fully finishes before Phase 3 (LinkAll) starts, and TOC.MOD calls
     StrTab.Reset again right after LinkAll returns (see TOC.MOD's
     RunBody) — so no nameId here is ever read after a Reset that
     postdates its Intern. Do NOT cache a nameId across a StrTab.Reset
     boundary; if you need a value that outlives one, resolve it to
     something StrTab-independent first (MarkModule's MarkNode list does
     this: it stores resolved Module POINTERs from SymOwner, never the
     nameId or raw name text, specifically so its deferred recursion
     can't be invalidated by an intervening reset). *)
  SymRec = RECORD
    nameId:   StrTab.TStrTabId;
    owner:    Module;
    segId:    INTEGER; (* 0=code, 1=data, 2=bss *)
    offset:   LONGINT;
    next:     Symbol;  (* index, NoSym-terminated *)
    hNext:    Symbol   (* index, NoSym-terminated *)
  END;
  SymNode = POINTER TO SymNodeRec;
  SymNodeRec = RECORD
    s:    ARRAY SymChunk OF SymRec;
    next: SymNode
  END;

  (* Chunked per-module IMPORT list (small-record rule, ImpChunk entries/node).
     Rebuilt for every module during the reloc scan (inside ScanRelocs' open file
     buffer), so one node per import used to strand the arena; packing them keeps
     the transient list to a handful of nodes. *)
  ImportNode = POINTER TO ImportNodeRec;
  ImportNodeRec = RECORD
    id:    ARRAY ImpChunk OF WORD;
    sym:   ARRAY ImpChunk OF Symbol;
    count: INTEGER;
    next:  ImportNode
  END;

  State* = POINTER TO StateRec;
  StateRec* = RECORD
    modHead*:     Module;
    modTail:      Module;
    (* Chunked symbol store.  symDir[i DIV SymChunk] is the chunk node holding
       symbol i; symNodes is the chunk-list head (for freeing); symCount is the
       next free index.  symHash[] and the SymRec next/hNext chains hold WORD
       index handles (NoSym-terminated). *)
    symDir:       ARRAY MaxSymChunk OF SymNode;
    symNodes:     SymNode;
    symCount:     Symbol;   (* next free symbol index *)
    symHead:      Symbol;
    symHash:      ARRAY SymHash OF Symbol;
    dataFile*:    Files.File;   (* file-backed image of every module's DATA
                                   segment, back-to-back in module order
                                   (LINKBUF-REPORT.MD §4.1) — CalculateLayout
                                   already fixes every module's dataPara
                                   before any byte is read or patched, so a
                                   Files.Seek-capable temp file gives the same
                                   random-access guarantee a RAM buffer did.
                                   Written then rewound + read; content is
                                   destroyed on close, so it is never reopened
                                   by name. *)
    codeBuf:      Rdoff.SegBuf;  (* one reusable per-module code buffer,
                                    reserved up front so the fixed 65000-byte
                                    block is grabbed while the arena is still
                                    contiguous — one module's own .rdf code is
                                    always <= 64KB (RDOFF2's own segment
                                    limit), so this one buffer serves every
                                    module in turn *)
    spillFile*:   Files.File;   (* code spill: written then rewound + read; kept
                                   open the whole time (its content is destroyed
                                   on close, so it is never reopened by name) *)
    totalCodeLen*:LONGINT;      (* sum of every module's own CODE segment,
                                   16-aligned per module — NOT one combined
                                   segment anymore, just the running byte
                                   total used for image-size math *)
    totalDataLen*:LONGINT;      (* sum of every module's own DATA segment,
                                   16-aligned per module *)
    totalBssLen*: LONGINT;      (* size of the ONE shared BSS segment (every
                                   module's bssSize summed) — carries NO file
                                   bytes (see WriteExe); this is memory-only *)
    bssPara*:     WORD;        (* paragraph of the one shared BSS segment,
                                   relative to image start *)
    entryIp*:     WORD;
    entryCSPara*: INTEGER;
    stackSize*:   LONGINT;
    ovrSpillFile*: Files.File;  (* DOCS/OVR.MD §11.1: every overlay module's own
                                   relocated code, appended sequentially during
                                   PerformLinking (reuses ls^.codeBuf the same
                                   way the main spillFile does) -- each module's
                                   own byte offset within this file is recorded
                                   in Module.ovrCodeOfs.  Rewound + kept open for
                                   LinkOvr.WriteOvrFile to read from afterward,
                                   same lifetime discipline as spillFile. *)
    anyOverlay*:   BOOLEAN;    (* TRUE iff at least one used module has
                                   isOverlay=TRUE -- lets TOC.MOD skip the whole
                                   LinkOvr pass (and .OVR file creation) for the
                                   common case of no overlays at all. *)
    targetCP*:     BOOLEAN     (* TRUE for /CP (NE/DPMI16).  DOCS/OVR.MD §2:
                                   overlays are /CD-only, unconditionally --
                                   every isOverlay-aware branch in this module
                                   (CalculateLayout, OnReloc, PerformLinking)
                                   must behave as if isOverlay were always
                                   FALSE when this is TRUE, so a /CP link is
                                   BYTE-IDENTICAL to what it was before this
                                   feature existed, regardless of any $O+ in
                                   the source.  Set once by TOC.MOD, alongside
                                   its own gTargetCP, before CalculateLayout
                                   runs. *)
    ovrNextEntryId*: WORD     (* running counter for Module.ovrEntryIdBase
                                 assignment (see that field's comment) --
                                 0-based, incremented by each overlay
                                 module's own ovrNEntries as CalculateLayout
                                 walks the module list. *)
  END;

(* Errors here are reached from deep helpers and FAR callbacks (OnImportForMark,
   OnReloc, ...) whose signatures are fixed.  They latch in module LogErr
   (LogErr.Error/Error2 — the single error state); the public link phases (called
   from TOC.LinkAll) check LogErr.HaveErr() after each step and TOC.Run is the sole
   SYSTEM.Halt. *)

(* ---- string helpers ---- *)

PROCEDURE PathJoin(VAR dst: ARRAY OF CHAR; dir, file: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(dst) - 1) & (dir[i] # 0X) DO
    dst[i] := dir[i]; INC(i)
  END;
  IF (i > 0) & (dst[i-1] # "\") & (dst[i-1] # "/") & (i < LEN(dst) - 1) THEN
    dst[i] := "\"; INC(i)
  END;
  j := 0;
  WHILE (i < LEN(dst) - 1) & (file[j] # 0X) DO
    dst[i] := file[j]; INC(i); INC(j)
  END;
  dst[i] := 0X
END PathJoin;

PROCEDURE FileExists(path: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File; ok: BOOLEAN;
BEGIN
  ok := Files.Reset(f, path);
  IF ok THEN Files.Close(f) END;
  RETURN ok
END FileExists;

(* Find a .om file by name: search CWD, then the directory containing oc.exe. *)
PROCEDURE FindFile*(name: ARRAY OF CHAR; VAR result: ARRAY OF CHAR);
  VAR tmp: ARRAY MaxPath OF CHAR;
      exePath: ARRAY MaxPath OF CHAR;
      exeDir: ARRAY MaxPath OF CHAR;
      n1, n2: ARRAY MaxPath OF CHAR;
      found: BOOLEAN;
BEGIN
  found := FALSE;
  (* 1. CWD *)
  IF FileExists(name) THEN Strings.Copy(name, result); found := TRUE END;
  (* 2. directory of the running oc.exe *)
  IF ~found THEN
    Dos.ParamStr(0, exePath);
    IF exePath[0] # 0X THEN
      Dos.FSplit(exePath, exeDir, n1, n2);
      IF exeDir[0] # 0X THEN
        PathJoin(tmp, exeDir, name);
        IF FileExists(tmp) THEN Strings.Copy(tmp, result); found := TRUE END
      END
    END
  END;
  IF ~found THEN Strings.Copy(name, result) END
END FindFile;

(* ---- symbol table (chunked store, WORD index handles) ----
   Symbol handle i addresses ls^.symDir[LSR(i,SymShift)]^.s[AND(i,SymMask)].
   SymChunk is a power of two so this is shift+mask, not DIV/MOD (the reloc loop
   dereferences symbols per relocation).  Read a field with e.g.
   ls^.symDir[SYSTEM.LSR(i,SymShift)]^.s[SYSTEM.AND(i,SymMask)].owner . *)

(* Allocate a fresh symbol slot, growing the chunk list + directory as needed,
   and return its WORD index.  Latches LogErr.HaveErr() and returns NoSym if the store or
   directory is full. *)
PROCEDURE SymAlloc(ls: State): Symbol;
  VAR idx: Symbol; chunk, slot: WORD; node: SymNode;
BEGIN
  idx   := ls^.symCount;
  chunk := SYSTEM.LSR(idx, SymShift);
  slot  := SYSTEM.AND(idx, SymMask);
  IF chunk >= MaxSymChunk THEN LogErr.Error("Too many symbols"); RETURN NoSym END;
  IF slot = 0 THEN                       (* start of a new chunk — allocate it *)
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (symbol chunk)"); RETURN NoSym END;
    node^.next := ls^.symNodes; ls^.symNodes := node;
    ls^.symDir[chunk] := node
  END;
  INC(ls^.symCount);
  RETURN idx
END SymAlloc;

(* Return the chunk node holding symbol i (its slot is AND(i,SymMask)).  Binding
   this pointer to a local lets call sites read/write fields as node^.s[slot].f
   without repeating the directory index. *)
PROCEDURE SymNodeOf(ls: State; i: Symbol): SymNode;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)] END SymNodeOf;

(* Scalar field accessors (i must be a valid handle, not NoSym). *)
PROCEDURE SymOwner*(ls: State; i: Symbol): Module;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].owner END SymOwner;

PROCEDURE SymSegId*(ls: State; i: Symbol): INTEGER;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].segId END SymSegId;

PROCEDURE SymOffset*(ls: State; i: Symbol): LONGINT;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].offset END SymOffset;

PROCEDURE SymNameId*(ls: State; i: Symbol): StrTab.TStrTabId;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].nameId END SymNameId;

PROCEDURE AddSymbol(ls: State; name: ARRAY OF CHAR; owner: Module;
                    segId: INTEGER; ofs: LONGINT);
  VAR sym: Symbol; slot: WORD; nid: StrTab.TStrTabId; node: SymNode;
BEGIN
  sym := SymAlloc(ls);
  IF sym = NoSym THEN RETURN END;
  nid := StrTab.Intern(name);
  node := SymNodeOf(ls, sym); slot := SYSTEM.AND(sym, SymMask);
  node^.s[slot].nameId   := nid;
  node^.s[slot].owner    := owner;
  node^.s[slot].segId    := segId;
  node^.s[slot].offset   := ofs;
  node^.s[slot].next     := ls^.symHead; ls^.symHead := sym;
  slot := SYSTEM.AND(nid, SymHash - 1);   (* reuse `slot` as the hash bucket *)
  node^.s[SYSTEM.AND(sym, SymMask)].hNext := ls^.symHash[slot];
  ls^.symHash[slot] := sym
END AddSymbol;

PROCEDURE FindSymbol*(ls: State; name: ARRAY OF CHAR): Symbol;
  VAR sym: Symbol; nid: StrTab.TStrTabId; node: SymNode; slot: WORD;
BEGIN
  nid := StrTab.Find(name);
  IF nid = 0 THEN RETURN NoSym END;   (* never interned => can't be any symbol's name *)
  sym := ls^.symHash[SYSTEM.AND(nid, SymHash - 1)];
  WHILE sym # NoSym DO
    node := SymNodeOf(ls, sym); slot := SYSTEM.AND(sym, SymMask);
    IF node^.s[slot].nameId = nid THEN RETURN sym END;
    sym := node^.s[slot].hNext
  END;
  RETURN NoSym
END FindSymbol;

(* ---- module list ---- *)

PROCEDURE NewModule(ls: State; path: ARRAY OF CHAR; libOfs: LONGINT): Module;
  VAR m: Module;
BEGIN
  NEW(m);
  IF m = NIL THEN
    LogErr.Error("Out of memory (module record)"); RETURN NIL
  END;
  (* ModRec is a plain near-heap record (not a far SegBuf array — see the
     "Reusing one shared code buffer" FILL hazard note, which is specific to
     POINTER TO ARRAY 65000 OF BYTE far-heap buffers), so a bulk zero-fill is
     safe here; only the non-zero fields need an explicit assignment after.
     codePara/dataPara/bssPara are all assigned later, in CalculateLayout. *)
  SYSTEM.FILL(m^, SIZE(ModRec), 0);
  Strings.Copy(path, m^.path);
  m^.libOfs  := libOfs;
  IF ls^.modTail = NIL THEN ls^.modHead := m
  ELSE ls^.modTail^.next := m
  END;
  ls^.modTail := m;
  RETURN m
END NewModule;

(* Unlink m from ls^.modHead/next chain (m is known to be present).  Used
   only by CalculateLayout to move the entry module to the front. *)
PROCEDURE RemoveFromModList(ls: State; m: Module);
  VAR prev, cur: Module;
BEGIN
  IF ls^.modHead = m THEN
    ls^.modHead := m^.next;
    IF ls^.modTail = m THEN ls^.modTail := NIL END;
    RETURN
  END;
  prev := ls^.modHead; cur := ls^.modHead^.next;
  WHILE (cur # NIL) & (cur # m) DO prev := cur; cur := cur^.next END;
  IF cur = m THEN
    prev^.next := cur^.next;
    IF ls^.modTail = m THEN ls^.modTail := prev END
  END
END RemoveFromModList;

(* ---- state init ---- *)

PROCEDURE InitState*(ls: State);
  VAR i: INTEGER;
BEGIN
  ls^.modHead    := NIL; ls^.modTail    := NIL;
  ls^.symHead    := NoSym;
  ls^.symNodes   := NIL; ls^.symCount := 0;
  i := 0; WHILE i < MaxSymChunk DO ls^.symDir[i] := NIL; INC(i) END;
  i := 0; WHILE i < SymHash DO ls^.symHash[i] := NoSym; INC(i) END;
  ls^.codeBuf    := NIL;
  ls^.totalCodeLen := LONGINT(0);
  ls^.totalDataLen := LONGINT(0);
  ls^.totalBssLen  := LONGINT(0);
  ls^.bssPara      := 0;
  ls^.entryIp      := 0;
  ls^.entryCSPara  := 0;
  ls^.stackSize    := LONGINT(StackDef);
  ls^.anyOverlay   := FALSE;
  ls^.targetCP     := FALSE;
  ls^.ovrNextEntryId := 0
END InitState;

(* Reserve the one remaining large link buffer (the reusable per-group code
   buffer) BEFORE any module is scanned.  SegBuf is a fixed 65000-byte block;
   the symbol/module scan (each .rdf opened through an 8 KB Files buffer)
   fragments the arena so that no 65000-byte hole survives by link time.
   Grabbing it here — while the arena is still one contiguous block —
   guarantees the fixed buffer exists; the later small allocations fill the
   remaining space and never need a large contiguous run.  The combined data
   segment no longer needs an equivalent RAM reservation — it is file-backed
   (ls^.dataFile, opened on first use in PerformLinking) — see LINKBUF-
   REPORT.MD §4.1.  Returns FALSE (latching LogErr.HaveErr()) if the
   allocation fails. *)
PROCEDURE ReserveBuffers*(ls: State): BOOLEAN;
BEGIN
  NEW(ls^.codeBuf, Rdoff.SegLimit);
  IF ls^.codeBuf = NIL THEN LogErr.Error("Out of memory (code buffer)"); RETURN FALSE END;
  RETURN TRUE
END ReserveBuffers;

(* ---- scan callbacks ---- *)

VAR
  curLs:  State;
  curMod: Module;

(* Callbacks passed as proc-typed values to other modules (Tar, Rdoff)
   must be FAR — cross-module proc values are always 4-byte CS:offset, and
   our import declares MemberProc/GlobalProc/ImportProc as FAR. *)
PROCEDURE OnGlobal(name: ARRAY OF CHAR; seg: INTEGER; ofs: LONGINT); FAR;
BEGIN
  (* Duplicate-.rdf guard: the same .rdf can appear in more than one .om on the
     search path (e.g. SYSTEM.RDF lives both in SYSTEM.om and inside OBERON.OM).
     It must be linked exactly once.  On the FIRST global of a module, if that
     symbol already exists, the whole .rdf is a duplicate already linked from an
     earlier .om — mark it dup and add none of its symbols, so it is never used. *)
  IF curMod^.dup THEN RETURN END;
  IF (curMod^.nGlob = 0) & (FindSymbol(curLs, name) # NoSym) THEN
    (* Log which member was skipped: duplicates are NORMAL (SYSTEM.RDF lives
       in both SYSTEM.OM and OBERON.OM), so this is Debug-level — but a
       genuinely different module whose first global collides is silently
       dropped by this heuristic, and the trace is the only way to see it. *)
    LogErr.Debug2("linker: duplicate module skipped, first global: ", name);
    curMod^.dup := TRUE; RETURN
  END;
  INC(curMod^.nGlob);
  AddSymbol(curLs, name, curMod, seg, ofs)
END OnGlobal;

(* Append one entry-point name to m^.ovrEntries (small-record rule chunking,
   mirrors PARSER.MOD's own AddOvrEntry that WROTE this same list). *)
PROCEDURE AddOvrEntryName(m: Module; name: ARRAY OF CHAR);
  VAR node: OvrEntryNode; k: INTEGER;
BEGIN
  IF (m^.ovrEntries = NIL) OR (m^.ovrEntries^.count >= OvrEntryChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (overlay entry chunk)"); RETURN END;
    node^.count := 0; node^.next := m^.ovrEntries; m^.ovrEntries := node
  END;
  k := m^.ovrEntries^.count;
  Strings.Copy(name, m^.ovrEntries^.name[k]);
  INC(m^.ovrEntries^.count); INC(m^.ovrNEntries)
END AddOvrEntryName;

(* Find name's GLOBAL entry id: m^.ovrEntryIdBase plus its 0-based
   declaration-order index within m's own entry list (matching ENTRYn= in
   the .OVR member) -- globally unique across every overlay module in the
   program, since DOCS/OVR.MD §5's trampoline id byte is the runtime trap
   handler's ONLY way to identify which module a trapped call site targets
   (there is no second "which module" byte).  Returns -1 if not found
   (should not happen for a valid isOverlay module -- every exported $O+
   procedure that is ever the target of an import IS one of its own
   entries by construction, see PARSER.MOD's AddOvrEntry). Chunks are
   stored head-first (LIFO, like every other chunk list in this codebase),
   so index-from-declaration-order requires walking chunks oldest-to-
   newest; simplest correct approach: reverse-count from the tail by
   first counting total chunks. *)
PROCEDURE OvrEntryId*(m: Module; name: ARRAY OF CHAR): INTEGER;
  VAR node: OvrEntryNode; k, idx: INTEGER; found: BOOLEAN;
      chunkStarts: ARRAY 64 OF OvrEntryNode; nChunks, i: INTEGER;
BEGIN
  (* Collect chunk pointers head(newest)->tail(oldest), then walk oldest
     first so idx counts up in true declaration order. *)
  nChunks := 0; node := m^.ovrEntries;
  WHILE (node # NIL) & (nChunks < 64) DO
    chunkStarts[nChunks] := node; INC(nChunks); node := node^.next
  END;
  idx := 0; found := FALSE;
  i := nChunks - 1;
  WHILE (i >= 0) & ~found DO
    node := chunkStarts[i];
    k := 0;
    WHILE (k < node^.count) & ~found DO
      IF Strings.Equal(node^.name[k], name) THEN found := TRUE
      ELSE INC(idx); INC(k) END
    END;
    DEC(i)
  END;
  IF found THEN RETURN idx + INTEGER(m^.ovrEntryIdBase) ELSE RETURN -1 END
END OvrEntryId;

(* Read m's own MODNAME.OVR member (if any), set m^.isOverlay, and collect
   its entry-point name list (DOCS/OVR.MD §11.2) -- real
   replacement for the prototype's hardcoded module-name check in OnReloc.
   Called once per module, at scan time, from ScanRdf, right after
   m^.stem is computed.  A module with no .OVR member, or whose stem is
   empty ($L extras etc., matching the .DBG precedent above), is simply
   not overlay-eligible -- isOverlay stays the FALSE that NewModule's
   SYSTEM.FILL already left in place. *)
PROCEDURE ScanOverlayMember(m: Module);
  VAR f: Files.File; memb: ARRAY 14 OF CHAR; line: ARRAY 40 OF CHAR;
      name: ARRAY 33 OF CHAR;
      i, j, eqAt: INTEGER;
BEGIN
  IF m^.stem[0] = 0X THEN RETURN END;
  Strings.Copy(m^.stem, memb); Strings.Append(".OVR", memb);
  IF ~Tar.TarExtract(m^.path, memb, f) THEN RETURN END;
  IF Files.ReadLine(f, line, WORD(LEN(line))) > 0 THEN
    m^.isOverlay := Strings.Equal(line, "OVERLAY=1")
  END;
  IF m^.isOverlay THEN
    WHILE Files.ReadLine(f, line, WORD(LEN(line))) > 0 DO
      (* "ENTRYn=name" -- if the prefix starts with "ENTRY" but is NOT the
         "ENTRYCOUNT=" line, find '=' and append everything after it. *)
      IF (line[0]="E")&(line[1]="N")&(line[2]="T")&(line[3]="R")&(line[4]="Y")&
         ~((line[5]="C")&(line[6]="O")&(line[7]="U")&(line[8]="N")&(line[9]="T")) THEN
        eqAt := -1; i := 0;
        WHILE line[i] # 0X DO
          IF line[i] = "=" THEN eqAt := i END;
          INC(i)
        END;
        IF eqAt >= 0 THEN
          j := 0; i := eqAt + 1;
          WHILE (line[i] # 0X) & (j < LEN(name) - 1) DO
            name[j] := line[i]; INC(i); INC(j)
          END;
          name[j] := 0X;
          AddOvrEntryName(m, name)
        END
      END
    END
  END;
  Files.Close(f)
END ScanOverlayMember;

(* ---- scan a single .rdf inside an archive ---- *)

PROCEDURE ScanRdf(ls: State; path: ARRAY OF CHAR; libOfs: LONGINT;
                  member: ARRAY OF CHAR);
  VAR m: Module; i, dot: INTEGER; plain: BOOLEAN;
BEGIN
  m := NewModule(ls, path, libOfs);
  IF m = NIL THEN RETURN END;   (* OOM latched by NewModule *)
  (* Debug-info stem: "MODNAME.RDF" -> "MODNAME" (so MODNAME.DBG can be
     extracted later).  $L extras carry a "MODNAME/" prefix and never have a
     .DBG member — leave stem empty for those (and for any stem > 8 chars). *)
  i := 0; dot := -1; plain := TRUE;
  WHILE member[i] # 0X DO
    IF (member[i] = "/") OR (member[i] = "\") THEN plain := FALSE END;
    IF member[i] = "." THEN dot := i END;
    INC(i)
  END;
  IF plain & (dot > 0) & (dot <= 8) THEN
    i := 0;
    WHILE i < dot DO m^.stem[i] := member[i]; INC(i) END;
    m^.stem[i] := 0X
  END;
  ScanOverlayMember(m);
  curMod := m; curLs := ls;
  Rdoff.ScanHeader(path, libOfs,
    m^.rawSize, m^.hdrSize, m^.codeSize, m^.dataSize, m^.bssSize,
    OnGlobal, NIL)
END ScanRdf;

(* ---- tar member callback ---- *)

VAR
  scanPath: ARRAY MaxPath OF CHAR;
  scanLs:   State;

(* rawSize is unused but fixed by the Tar callback signature — do not remove. *)
PROCEDURE OnMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
BEGIN
  ScanRdf(scanLs, scanPath, libOfs, name)
END OnMember;

(* ---- process one input file ---- *)

PROCEDURE ProcessFile*(ls: State; rawName: ARRAY OF CHAR);
  VAR path: ARRAY MaxPath OF CHAR;
      dummy: LONGINT;
BEGIN
  FindFile(rawName, path);
  IF Tar.IsOmFile(path) THEN
    scanLs := ls;
    Strings.Copy(path, scanPath);
    dummy := LONGINT(0);
    Tar.ScanTar(scanPath, OnMember, dummy, FALSE)
  ELSE
    LogErr.Error2("Unknown file format (must be .om): ", path)
  END
END ProcessFile;

(* ---- smart linking ---- *)

CONST
  MarkChunk = 64;   (* dependency-module entries per chunk node (small-record rule) *)

TYPE
  (* Chunked list of dependency Modules found while scanning ONE module's
     imports — collected while that module's .rdf is open, then the file is
     closed, and only THEN do we recurse to mark each dependency (see
     MarkModule below). Without this, MarkModule's recursion held its
     Rdoff.ScanRelocs file (and its 8 KB Files.MOD read buffer) open across
     the whole recursive descent into every dependency: a deep, real import
     chain (Link->Parser->PStmt->PExpr->Cgen->Syms->StrTab, ~7 levels in
     this compiler's own self-host) stacked up that many concurrent 8 KB
     buffers, which — combined with the tight free-heap window already
     measured at this point in a self-host — could fail the buffer's own
     NEW. Files.Reset's NEW-failure path returns FALSE exactly like a
     genuine open failure, so this surfaced as a confusing "Cannot open:
     STRTAB.OM" instead of an out-of-memory message. Fixed by making
     MarkModule single-file-open-at-a-time: only one Rdoff.ScanRelocs call
     is ever on the stack at once, regardless of import-graph depth. *)
  MarkNode = POINTER TO MarkNodeRec;
  MarkNodeRec = RECORD
    m:     ARRAY MarkChunk OF Module;
    count: INTEGER;
    next:  MarkNode
  END;

VAR
  markLs:     State;
  markErrbuf: ARRAY 256 OF CHAR;
  markDeps:   MarkNode;   (* this call's collected dependencies (see MarkModule) *)

PROCEDURE MarkModule(m: Module); FORWARD;

(* flag is unused but fixed by the Import-scan callback signature — do not remove. *)
PROCEDURE OnImportForMark(flag: INTEGER; segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR sym: Symbol; n: MarkNode;
BEGIN
  (* KERNEL_INITTASK is the /CP entry stub's genuine OS/2 external import (the
     kernel task-init far call); it is resolved by the OS/2 loader via the NE
     module-reference table, NOT by us — LinkNE emits an external NE reloc for
     it (see LINKNE.OnSegReloc).  It has no linked symbol, so it is not an
     "unresolved external" error and pulls in no dependency module. *)
  IF Strings.Equal(name, "KERNEL_INITTASK") THEN RETURN END;
  sym := FindSymbol(markLs, name);
  IF sym = NoSym THEN
    Strings.Copy("Unresolved external: ", markErrbuf);
    Strings.Append(name, markErrbuf);
    LogErr.Error(markErrbuf); RETURN
  END;
  (* Collect only — do NOT recurse here, the caller's .rdf file is still
     open (see MarkModule's comment). *)
  IF (markDeps = NIL) OR (markDeps^.count >= MarkChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (mark-pass dependency list)"); RETURN END;
    n^.count := 0; n^.next := markDeps; markDeps := n
  END;
  markDeps^.m[markDeps^.count] := SymOwner(markLs, sym);
  INC(markDeps^.count)
END OnImportForMark;

PROCEDURE MarkModule;
  VAR savedDeps, n, nNext: MarkNode; i: INTEGER;
BEGIN
  IF m^.used THEN RETURN END;
  m^.used := TRUE;
  (* Save/restore markDeps: this call's collection must not be clobbered by
     a nested MarkModule call sharing the same module-level relay (mirrors
     the save/restore discipline used elsewhere in this codebase for
     single ambient-relay globals reused across recursive descents). *)
  savedDeps := markDeps; markDeps := NIL;
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, OnImportForMark, NIL, NIL);
  (* File is closed now (ScanRelocs closes it before returning) — safe to
     recurse: at most one file is open at any point in the whole mark
     pass, regardless of import-graph depth. *)
  n := markDeps; markDeps := savedDeps;
  WHILE n # NIL DO
    nNext := n^.next;
    i := 0;
    WHILE i < n^.count DO MarkModule(n^.m[i]); INC(i) END;
    DISPOSE(n);
    n := nNext
  END
END MarkModule;

PROCEDURE SmartLink*(ls: State);
  VAR sym: Symbol;
BEGIN
  markLs := ls;
  sym := FindSymbol(ls, "start");
  IF sym = NoSym THEN LogErr.Error("Entry point 'start' not found!"); RETURN END;
  MarkModule(SymOwner(ls, sym))
END SmartLink;

(* ---- layout ---- *)

PROCEDURE Align2(v: LONGINT): LONGINT;
BEGIN RETURN (v + LONGINT(1)) DIV LONGINT(2) * LONGINT(2) END Align2;

PROCEDURE Align16(v: LONGINT): LONGINT;
BEGIN RETURN (v + LONGINT(15)) DIV LONGINT(16) * LONGINT(16) END Align16;

(* CalculateLayout: one module = one CODE segment = one DATA segment = one
   BSS segment — no more grouping (each module's own .rdf is already a
   complete, self-contained module by the time it reaches Link; see
   DOCS/NE-BP.MD Part 2 §2.2).  Image order (fixed, see WriteExe):
     [mod1 CODE][mod1 DATA] ... [modN CODE][modN DATA]
     [mod1 BSS] ... [modN BSS]           <- memory-only, no file bytes
     [stack]                             <- also memory-only
   CODE+DATA pairs carry real file bytes and are laid out first, in module
   order; BSS segments are grouped at the very end (after every module's
   CODE+DATA) because only a TRAILING region of the image can skip file
   bytes and still be zero-filled by DOS at load (via min_alloc) — see
   WriteExe's minAlloc computation.  Each of the three per-module spans is
   its own <=64KB segment (RDOFF2's own per-segment limit already bounds
   codeSize/dataSize/bssSize to that, so no group-packing/overflow check is
   needed here anymore — a single module's own segment can never overflow
   64KB on its own). *)
PROCEDURE CalculateLayout*(ls: State);
  VAR m: Module;
      codeBase, dataBase, bssBase: LONGINT;
      entrySym: Symbol;
      entryOwner: Module;
BEGIN
  (* DOCS/OVR.MD §2: overlays are /CD-only, unconditionally.  Clearing
     isOverlay HERE, in one place, before any of the three layout passes
     below ever look at it, guarantees a /CP link behaves exactly as if no
     module were ever $O+ eligible -- byte-identical to before this
     feature existed -- without threading a ~ls^.targetCP check through
     every downstream isOverlay call site (OnReloc, PerformLinking,
     LinkOvr). *)
  IF ls^.targetCP THEN
    m := ls^.modHead;
    WHILE m # NIL DO m^.isOverlay := FALSE; m := m^.next END
  END;

  (* Move the entry module to the front of the list so its CODE segment
     lands first in the image — cosmetic (any order links correctly), but
     matches the previous behaviour of putting the entry group first. *)
  entrySym := FindSymbol(ls, "start");
  IF entrySym # NoSym THEN entryOwner := SymOwner(ls, entrySym) ELSE entryOwner := NIL END;
  IF (entryOwner # NIL) & (entryOwner # ls^.modHead) THEN
    RemoveFromModList(ls, entryOwner);
    entryOwner^.next := ls^.modHead;
    ls^.modHead := entryOwner;
    IF ls^.modTail = NIL THEN ls^.modTail := entryOwner END
  END;

  (* Pass 1: every USED, NON-OVERLAY module's own CODE segment, back-to-
     back, 16-aligned (DOCS/OVR.MD §11.1: an $O+ module actually routed to the
     .OVR file contributes NO bytes to the main image's CODE region at
     all -- its own code is laid out separately, by LinkOvr.CalculateOvrLayout,
     after this returns).  An overlay module's codePara is left at its
     SYSTEM.FILL zero value; nothing in the main image ever reads it. *)
  codeBase := LONGINT(0);
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & ~m^.isOverlay THEN
      codeBase := Align16(codeBase);
      m^.codePara := WORD(codeBase DIV LONGINT(16));
      codeBase := codeBase + Align2(m^.codeSize)
    ELSIF m^.used & m^.isOverlay THEN
      ls^.anyOverlay := TRUE;
      (* assign this module's GLOBAL entry-id base (see ovrEntryIdBase's own
         comment) -- a running counter across every used overlay module,
         in list order (order doesn't matter for correctness, only that
         it's consistent between this assignment and OvrEntryId's later
         lookup, which it is: both read the same m^.ovrEntryIdBase). *)
      (* Ceiling check moved HERE, at allocation time, from the two former
         use-site-only checks (PatchOverlayCallSite/AddOvrReturnTrampoline)
         -- those only ever fire if the over-255th id is actually PATCHED
         at a call site; an entry point that exists but is never called
         from anywhere previously slipped past both checks, letting
         CalculateLayout silently hand out ids the 1-byte trampoline id
         (PatchOverlayCallSite's own BYTE(entryId) truncation) can never
         correctly represent, and LinkOvr.WriteOvrFile would then emit a
         directory sized past what any trampoline could ever index into.
         Code review, found 2026-08-08. *)
      IF LONGINT(ls^.ovrNextEntryId) + LONGINT(m^.ovrNEntries) > LONGINT(256) THEN
        LogErr.Error("overlay: more than 256 overlay entry points in one program (trampoline id is 1 byte)")
      END;
      m^.ovrEntryIdBase := ls^.ovrNextEntryId;
      ls^.ovrNextEntryId := ls^.ovrNextEntryId + WORD(m^.ovrNEntries)
    END;
    m := m^.next
  END;
  ls^.totalCodeLen := Align16(codeBase);

  (* Pass 2: every USED, NON-OVERLAY module's own DATA segment, immediately
     after all CODE segments, back-to-back, 16-aligned.  An overlay
     module's own DATA (if it has any beyond BSS -- initialized globals)
     is NOT excluded here on purpose: only CODE is ever swapped by the
     overlay manager (DOCS/OVR.MD §3), so DATA stays resident in the main
     image exactly like a non-overlay module's, for the same reason BSS
     does (DOCS/OVR.MD §3 -- module data already survives a code swap,
     for free). *)
  dataBase := ls^.totalCodeLen;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used THEN
      dataBase := Align16(dataBase);
      m^.dataPara := WORD(dataBase DIV LONGINT(16));
      dataBase := dataBase + Align16(m^.dataSize)
    END;
    m := m^.next
  END;
  ls^.totalDataLen := dataBase - ls^.totalCodeLen;

  (* Pass 3: ONE shared BSS segment for every used module (unlike CODE/DATA,
     BSS stays a single combined segment — see NE-BP.MD Part 2 §2.2 discussion) — each
     module gets its own byte OFFSET within that one segment, 2-byte
     aligned (matches the pre-per-module-CODE/DATA combined-segment
     behaviour).  Placed after all CODE+DATA; memory-only, no file bytes
     (WriteExe relies on min_alloc to get this span zero-filled by DOS at
     load — that only works because nothing with real file bytes follows
     it in the image).  Overlay modules are NOT excluded here either, same
     reasoning as DATA above. *)
  ls^.bssPara := WORD(dataBase DIV LONGINT(16));
  bssBase := LONGINT(0);
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used THEN
      m^.bssOfs := bssBase;
      bssBase := Align2(bssBase + m^.bssSize)
    END;
    m := m^.next
  END;
  ls^.totalBssLen := Align16(bssBase)
END CalculateLayout;

(* ---- relocation ---- *)

VAR
  lnkLs:      State;
  lnkMod:     Module;
  lnkImports: ImportNode;
  lnkCodeBuf: Rdoff.SegBuf;
  lnkSegRelocProc: LocalRelocProc; (* the REAL target's segRelocProc
    (LinkMZ.OnSegReloc for /CD -- overlays are /CD-only, DOCS/OVR.MD §2),
    set for ProcessOverlayModule's duration -- see OnSegRelocOverlay's own
    comment on why a DATA-segment patch site needs to reach it.  Typed
    LocalRelocProc, not Rdoff.RelocProc -- see that type's own comment. *)

PROCEDURE FindImport*(id: INTEGER): Symbol;
  VAR p: ImportNode; k: INTEGER;
BEGIN
  p := lnkImports;
  WHILE p # NIL DO
    k := 0;
    WHILE k < p^.count DO
      IF p^.id[k] = WORD(id) THEN RETURN p^.sym[k] END;
      INC(k)
    END;
    p := p^.next
  END;
  RETURN NoSym
END FindImport;

(* Free the current module's IMPORT-node chain (rebuilt per module). *)
PROCEDURE FreeImports;
  VAR p, q: ImportNode;
BEGIN
  p := lnkImports;
  WHILE p # NIL DO q := p^.next; DISPOSE(p); p := q END;
  lnkImports := NIL
END FreeImports;

(* TRUE iff sym's own name ends in "__init" (DOCS/OVR.MD §5: __init
   is never a call-site target reached through the overlay trampoline
   mechanism -- nothing outside the compiler-generated dep-init chain ever
   calls it, and that chain always uses a plain CgCallFar, identically for
   overlay and non-overlay modules alike). *)
PROCEDURE IsInitTarget(ls: State; sym: Symbol): BOOLEAN;
  VAR name: ARRAY 40 OF CHAR; nl: INTEGER;
BEGIN
  StrTab.Get(SymNameId(ls, sym), name);
  nl := 0; WHILE name[nl] # 0X DO INC(nl) END;
  RETURN (nl >= 6) &
         (name[nl-6] = "_") & (name[nl-5] = "_") & (name[nl-4] = "i") &
         (name[nl-3] = "n") & (name[nl-2] = "i") & (name[nl-1] = "t")
END IsInitTarget;

(* IsOverlayImport: TRUE iff rrefSeg names an import whose owning module is
   .OVR-eligible and the import is not that module's own __init (same test
   OnReloc applies at its CALL FAR/isOverlayCall branch below).  Exported so
   LinkMZ.OnSegReloc (a SEPARATE callback, for the paired SEGRELOC record
   CgCallFar always emits alongside a CALL FAR's RELOC, CGEN.MOD:396-397)
   can recognise and skip the segment-operand half of an overlay call site
   instead of patching over the bytes OnReloc's own PatchOverlayCallSite
   already wrote there (found 2026-08-07: an unsuppressed SEGRELOC clobbered
   the trampoline's own entryOfs bytes at [opAddr+3..+4] with the target
   module's -- or whichever module TargetSegPara resolved -- codePara,
   corrupting the resident-jump offset silently past link time). *)
PROCEDURE IsOverlayImport*(ls: State; rrefSeg: INTEGER): BOOLEAN;
  VAR sym: Symbol; so: Module;
BEGIN
  sym := FindImport(rrefSeg);
  IF sym = NoSym THEN RETURN FALSE END;
  so := SymOwner(ls, sym);
  RETURN so^.isOverlay & ~IsInitTarget(ls, sym)
END IsOverlayImport;

(* IsOverlayCallSiteSegReloc: TRUE iff this SEGRELOC is the paired
   segment-operand half of an overlay call site's own CALL FAR (the RELOC
   half of which OnReloc already rewrote into a trampoline) -- the full
   suppression condition BOTH LinkMZ.OnSegReloc and Link.OnSegRelocOverlay
   must apply, factored into one place so the two copies (found once
   already, 2026-08-07, then found missing on the overlay-caller path
   again 2026-08-08 -- see IsOverlayImport's own comment) cannot silently
   diverge a third time.  rwidth=2 selects the segment-word half
   specifically (as opposed to a width=4 far-pointer slot or similar);
   rseg=SegCode restricts this to a CODE-segment SEGRELOC, matching
   exactly what CgCallFar emits. *)
PROCEDURE IsOverlayCallSiteSegReloc*(ls: State; rseg: INTEGER; rwidth: INTEGER; rrefSeg: INTEGER): BOOLEAN;
BEGIN
  RETURN (rseg = Rdoff.SegCode) & (rwidth = 2) & IsOverlayImport(ls, rrefSeg)
END IsOverlayCallSiteSegReloc;

(* Overwrite a 5-byte CALL FAR call site's OPCODE, not just its operand,
   rewriting it from `9A imm16 imm16` to `CD 3F id 00 00` (the overlay
   trampoline's swappable form, DOCS/OVR.MD §5).  opAddr is the reloc's
   own patchAddr MINUS 1 (the byte before the operand, i.e. the opcode
   byte) -- see OnReloc's call site below for why -1 is always correct
   here.  This is the one piece of the overlay plan with no existing
   precedent in this linker (every other patch here only ever touches
   operand bytes, never an opcode) -- see LINK.MOD's own comment at
   PatchBuf for why that's normally true.  entryId is the target's own
   0-based index into its module's .OVR entry list (OvrEntryId, DOCS/OVR.MD
   §11.1) -- the id byte the runtime trap handler reads to know which module/
   entry-point was requested (DOCS/OVR.MD §5). *)
PROCEDURE PatchOverlayCallSite(opAddr: LONGINT; entryId: INTEGER; entryOfs: WORD);
  VAR o: WORD;
BEGIN
  o := WORD(opAddr);
  lnkCodeBuf^[o]   := 0CDH;   (* INT opcode *)
  lnkCodeBuf^[o+1] := 03FH;   (* interrupt number 3Fh, DOCS/OVR.MD §5 *)
  lnkCodeBuf^[o+2] := BYTE(entryId);
  (* bytes o+3,o+4: DOCS/OVR.MD §5: a module's
     code blob is written as ONE contiguous region, and different exported
     entry points do NOT all start at offset 0 within it (only __init does,
     by construction) -- LoadModule needs each entry's own in-module code
     offset to jump to the right place.  These two bytes carry exactly
     that (entryOfs, little-endian WORD) instead of being left as
     CgCallFar's leftover operand bytes.  Overlay_PatchTrampoline reads
     them back (via the ASM's own [es:bx+3] access) before overwriting the
     whole 5-byte slot with the resident JMP FAR form. *)
  lnkCodeBuf^[o+3] := BYTE(SYSTEM.AND(entryOfs, 0FFH));
  lnkCodeBuf^[o+4] := BYTE(SYSTEM.LSR(entryOfs, 8))
END PatchOverlayCallSite;

(* Append one call-site patch-table entry to target module so^ (DOCS/OVR.MD
   §8).  Two cases, distinguished by whether caller itself is
   overlay code (cross-overlay calls, DOCS/OVR.MD §9):

   caller is RESIDENT (the ordinary, pre-existing case): siteFileOfs is the
   opcode byte's offset WITHIN THE FINAL .exe's LOAD IMAGE, relative to the
   start of the CODE region -- caller^.codePara*16 + opAddr, NOT counting
   the MZ header's own bytes (a DOS loader strips the MZ header at load
   time; the CODE region starts at CS=<load segment>+0, so this value plus
   the load segment IS the runtime CS:offset the overlay loader patches --
   verified against a real linked .exe).  ownerGlobalId := OvrNoOwner.

   caller is itself OVERLAY: the call site lives inside caller's own code
   blob, which has no fixed runtime address until caller is next loaded --
   siteFileOfs is instead relative to caller's OWN code origin (opAddr
   alone: LinkOvr.WriteOvrFile streams each module's code starting fresh at
   its own header, so an in-module offset needs no further base at write
   time -- the runtime adds the module's own CURRENT destParas once it knows
   it, exactly as ApplyFixups already does for the internal fixup table).
   ownerGlobalId := caller^.ovrEntryIdBase, letting the runtime
   (Overlay.PatchSitesForModule) resolve caller's own ModuleHeader via the same
   DirEntry/RegisterModule machinery an ordinary trampoline hit already uses,
   and read ITS current residentSeg/destParas rather than assuming the main
   image's own load segment. *)
PROCEDURE AddOvrSite(so: Module; caller: Module; opAddr: LONGINT; entryId: INTEGER);
  VAR node: OvrSiteNode; k: INTEGER; fileOfs: LONGINT; ownerGlobalId: WORD;
BEGIN
  IF (so^.ovrSites = NIL) OR (so^.ovrSites^.count >= OvrSiteChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (overlay site chunk)"); RETURN END;
    node^.count := 0; node^.next := so^.ovrSites; so^.ovrSites := node
  END;
  IF caller^.isOverlay THEN
    fileOfs := opAddr;
    ownerGlobalId := caller^.ovrEntryIdBase
  ELSE
    fileOfs := LONGINT(caller^.codePara) * LONGINT(16) + opAddr;
    ownerGlobalId := WORD(OvrNoOwner)
  END;
  k := so^.ovrSites^.count;
  so^.ovrSites^.siteFileOfs[k] := fileOfs;
  so^.ovrSites^.entryId[k] := WORD(entryId);
  so^.ovrSites^.ownerGlobalId[k] := ownerGlobalId;
  INC(so^.ovrSites^.count); INC(so^.ovrNSites)
END AddOvrSite;

(* Install a return-address trampoline (DOCS/OVR.MD §9): writes the
   swappable INT 3Fh form (DOCS/OVR.MD §5) at retOfs
   (an in-module offset within caller's own lnkCodeBuf -- caller is always
   lnkMod here, the module OnReloc is currently processing, so this reuses
   the SAME scratch buffer PatchOverlayCallSite already writes the
   original call site into) under a FRESH global entry id, and records the
   resume point in caller^.ovrResumes so LinkOvr.WriteOvrFile emits it
   alongside caller's own ordinary entries.  calleeEntryId is the entry id
   of the module whose call this resume point returns from -- carried
   through so Overlay.OvrDispatch's resume-point branch knows whose inUse
   to decrement on resume. *)
(* BUG FIX (found 2026-08-08, Solution 2 / "inUse and eviction-pressure
   testing" regression): this procedure used to ALSO patch a physical
   INT 3Fh trampoline into retOfs..retOfs+4 of caller's own code (the 5
   bytes of padding Cgen.CgCallFarOvr reserves there).  That trampoline's
   own SEGMENT half, once baked as the real hardware return address by
   Ovr_TrapEntry (site_seg : site_ofs+5 -- site_seg being CALLER's own
   resident segment AT THE MOMENT OF THE CALL), goes stale the instant
   caller itself is evicted and reloaded to a DIFFERENT segment before
   the callee returns -- exactly the case Solution 2 finally makes
   reachable (confirmed via a 3-module A->B->C regression: A evicted while
   idle, C loaded into A's OLD segment, B's eventual return to A landed
   inside C's code instead).  Fixed by moving the physical INT 3Fh bytes
   for EVERY resume point into a small, NEVER-SWAPPED resident table
   (Overlay.ResumeTrapTable, OVERLAY.MOD/OVERLAY.ASM) instead of into
   overlay code at all -- Ovr_TrapEntry now bakes the return address as
   residentTableSeg:slot(globalId) for a cross-overlay call, which can
   never go stale (that segment never moves), and OvrDispatch re-resolves
   caller's CURRENT resident segment fresh every time the resume trap
   fires, exactly as it already does for an ordinary entry.  retOfs is
   still recorded (as the resume table's own "ofs" field) -- it is still
   needed as the JUMP TARGET once resumed (caller's own in-module code
   offset the resident redirect eventually jumps to), just no longer as
   a physical patch site; Cgen.CgCallFarOvr's 5-byte padding reservation
   is consequently now unused dead space (kept for now -- removing it
   would be a separate codegen change; 5 bytes/cross-overlay-call-site is
   not worth the churn to reclaim immediately). *)
PROCEDURE AddOvrReturnTrampoline(caller: Module; retOfs: LONGINT; calleeEntryId: INTEGER);
  VAR node: OvrResumeNode; k: INTEGER; globalId: WORD;
BEGIN
  globalId := lnkLs^.ovrNextEntryId;
  IF LONGINT(globalId) > LONGINT(255) THEN
    LogErr.Error("overlay: more than 256 overlay entry points in one program (trampoline id is 1 byte)");
    RETURN
  END;
  INC(lnkLs^.ovrNextEntryId);

  IF (caller^.ovrResumes = NIL) OR (caller^.ovrResumes^.count >= OvrFixupChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (overlay resume chunk)"); RETURN END;
    node^.count := 0; node^.next := caller^.ovrResumes; caller^.ovrResumes := node
  END;
  k := caller^.ovrResumes^.count;
  caller^.ovrResumes^.ofs[k] := WORD(retOfs);
  caller^.ovrResumes^.globalId[k] := globalId;
  caller^.ovrResumes^.calleeGlobalId[k] := WORD(calleeEntryId);
  INC(caller^.ovrResumes^.count); INC(caller^.ovrNResumes)
END AddOvrReturnTrampoline;

(* Patch the resident per-module code buffer at an in-module offset.
   (Data-segment patches go through PatchDataFile below — see LINKBUF-
   REPORT.MD §4.1 for why the two diverged: code stays a RAM scratch
   buffer per module, data is file-backed.) *)
PROCEDURE PatchBuf*(bufOfs: LONGINT; addend: WORD; width: INTEGER);
  VAR o: WORD; cur: WORD;
BEGIN
  (* WORD, not INTEGER: buffer offsets are 0..64999 and an offset >= 32768
     carried as a negative INTEGER indexed correctly only via 16-bit
     wraparound — exactly the trap this module's own comments warn about. *)
  o := WORD(bufOfs);
  IF width = 2 THEN
    cur := WORD(INTEGER(lnkCodeBuf^[o]) + SYSTEM.LSL(INTEGER(lnkCodeBuf^[o+1]), 8));
    cur := cur + addend;   (* 16-bit WORD arithmetic wraps mod 65536 *)
    lnkCodeBuf^[o]   := BYTE(SYSTEM.AND(cur, 0FFH));
    lnkCodeBuf^[o+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(cur, 8), 0FFH))
  ELSE
    cur := WORD(SYSTEM.AND(INTEGER(lnkCodeBuf^[o]) + INTEGER(addend), 0FFH));
    lnkCodeBuf^[o] := BYTE(cur)
  END
END PatchBuf;

(* Patch the file-backed combined data image (ls^.dataFile, every used
   module's own DATA segment back-to-back) at an absolute file offset — the
   file-backed counterpart of PatchBuf.  bufOfs is DataFileBase(m) + rofs,
   a stable, already-final byte offset; this is a plain seek+read+seek+
   write, exactly as PatchBuf's array read-modify-write, just against a
   file instead of a RAM array. One extra seek pair per relocation (not per
   byte) — see LINKBUF-REPORT.MD §4.1's risk assessment (~1,700 relocations
   for this compiler's own self-host image; Files.MOD's own 8 KB internal
   buffering absorbs most of the actual disk cost when nearby offsets are
   patched repeatedly). *)
PROCEDURE PatchDataFile*(bufOfs: LONGINT; addend: WORD; width: INTEGER);
  VAR lo, hi: BYTE; cur: WORD;
BEGIN
  Files.Seek(lnkLs^.dataFile, bufOfs);
  Files.ReadByte(lnkLs^.dataFile, lo);
  IF width = 2 THEN
    Files.ReadByte(lnkLs^.dataFile, hi);
    cur := WORD(INTEGER(lo) + SYSTEM.LSL(INTEGER(hi), 8));
    cur := cur + addend;
    Files.Seek(lnkLs^.dataFile, bufOfs);
    Files.WriteByte(lnkLs^.dataFile, BYTE(SYSTEM.AND(cur, 0FFH)));
    Files.WriteByte(lnkLs^.dataFile, BYTE(SYSTEM.AND(SYSTEM.LSR(cur, 8), 0FFH)))
  ELSE
    cur := WORD(SYSTEM.AND(INTEGER(lo) + INTEGER(addend), 0FFH));
    Files.Seek(lnkLs^.dataFile, bufOfs);
    Files.WriteByte(lnkLs^.dataFile, BYTE(cur))
  END
END PatchDataFile;

(* flag is unused but fixed by the Import-scan callback signature — do not remove. *)
PROCEDURE OnImportForLink(flag: INTEGER; segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR sym: Symbol; node: ImportNode; k: INTEGER;
BEGIN
  sym := FindSymbol(lnkLs, name);
  (* append to head chunk; new chunk only when the current head is full *)
  IF (lnkImports = NIL) OR (lnkImports^.count >= ImpChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (import chunk)"); RETURN END;
    node^.count := 0; node^.next := lnkImports; lnkImports := node
  END;
  k := lnkImports^.count;
  lnkImports^.id[k]  := WORD(segId);
  lnkImports^.sym[k] := sym;
  INC(lnkImports^.count)
END OnImportForLink;

(* Absolute byte offset of module m's own DATA segment within the
   file-backed ls^.dataFile (which holds every used module's DATA bytes
   back-to-back, in the same order CalculateLayout assigned dataPara —
   see PerformLinking).  m^.dataPara is a paragraph number relative to the
   WHOLE image (code region comes first), so subtracting the code region's
   paragraph count rebases it to a dataFile-relative paragraph. *)
PROCEDURE DataFileBase(ls: State; m: Module): LONGINT;
BEGIN
  RETURN (LONGINT(m^.dataPara) - ls^.totalCodeLen DIV LONGINT(16)) * LONGINT(16)
END DataFileBase;

(* In-buffer patch address for a reloc at (rseg, rofs) inside module m: an
   in-module code offset (rseg=SegCode, <=64KB, fits WORD) or an absolute
   ls^.dataFile byte offset (rseg=SegData, needs LONGINT — the file holds
   every module's data, not just m's own <=64KB span). *)
PROCEDURE PatchCodeAddrOf(rofs: LONGINT): WORD;
BEGIN RETURN WORD(rofs) END PatchCodeAddrOf;

PROCEDURE DataFileOffsetOf*(ls: State; m: Module; rofs: LONGINT): LONGINT;
BEGIN RETURN DataFileBase(ls, m) + rofs END DataFileOffsetOf;

(* Read the WORD currently at a reloc site (rseg, rofs).  For a self-CODE/DATA
   reference the compiler already baked the real in-segment offset into the
   operand; LinkNE reads it (for the NE reloc's target-offset) before stamping
   the FFFF placeholder over it (see LINKNE / NE-BP.MD §1.4). *)
PROCEDURE ReadSiteWord*(rseg: INTEGER; rofs: LONGINT): WORD;
  VAR o: WORD; lo, hi: BYTE; addr: LONGINT;
BEGIN
  IF rseg = Rdoff.SegCode THEN
    o := WORD(rofs);
    RETURN WORD(INTEGER(lnkCodeBuf^[o]) + SYSTEM.LSL(INTEGER(lnkCodeBuf^[o+1]), 8))
  ELSE
    addr := DataFileOffsetOf(lnkLs, lnkMod, rofs);
    Files.Seek(lnkLs^.dataFile, addr);
    Files.ReadByte(lnkLs^.dataFile, lo); Files.ReadByte(lnkLs^.dataFile, hi);
    RETURN WORD(INTEGER(lo) + SYSTEM.LSL(INTEGER(hi), 8))
  END
END ReadSiteWord;

(* Force-write a WORD at a reloc site (rseg, rofs), REPLACING (not adding).
   LinkNE stamps the BPC-reference FFFF / 0000 reloc placeholder for /CP so the
   loader writes the real value at load time (NE-BP.MD §1.4). *)
PROCEDURE WriteSiteWord*(rseg: INTEGER; rofs: LONGINT; val: WORD);
  VAR o: WORD; addr: LONGINT;
BEGIN
  IF rseg = Rdoff.SegCode THEN
    o := WORD(rofs);
    lnkCodeBuf^[o]   := BYTE(SYSTEM.AND(val, 0FFH));
    lnkCodeBuf^[o+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH))
  ELSE
    addr := DataFileOffsetOf(lnkLs, lnkMod, rofs);
    Files.Seek(lnkLs^.dataFile, addr);
    Files.WriteByte(lnkLs^.dataFile, BYTE(SYSTEM.AND(val, 0FFH)));
    Files.WriteByte(lnkLs^.dataFile, BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH)))
  END
END WriteSiteWord;

(* RDOFF2's RELOC record carries only the PATCH SITE's own offset (rofs) —
   the target's location is never a second field; the assembler/codegen
   pre-bakes the addend (target's own in-segment offset, or a negative
   IP-relative addend) into the bytes already sitting at the patch site
   (RDOFF2.MD §3.3).  The linker's only job is to ADD the resolved target
   segment's BASE on top of that existing addend:
     - self-reference to CODE/DATA (target inside THIS module's own
       segment): base = 0 — one module = one CODE/DATA segment, so "this
       module's own segment" starts at offset 0 by construction; no
       group/module shift is needed at all (this used to be GroupOfs(m)/
       m^.dataFinalOfs/etc. when multiple modules shared one combined
       segment — that sharing no longer exists for CODE/DATA).
     - self-reference to BSS: base = m^.bssOfs — BSS stays ONE segment
       shared by every module (see Link.CalculateLayout), so a module's own
       BSS byte still needs its own slice's offset added, same as the old
       combined-segment model.
     - import reference (rrefSeg = import id): base = the resolved symbol's
       own in-segment offset (SymOffset), PLUS so^.bssOfs if the import is
       itself a BSS variable (its offset is relative to ITS OWN module's
       BSS slice, i.e. its own .rdf's local BSS numbering, same reasoning
       as the self-reference case above) — imports still cross a module
       boundary, so the target's offset within ITS OWN module's segment
       must be added; per DOCS/OBERLANG.MD's NEAR/export visibility rule, a
       relative (rrel<>0) reloc can only ever target a same-module self-
       reference (an exported, cross-module-callable proc is always FAR =
       absolute), never an import — so the import branch below is always
       absolute. *)
(* Compute the in-segment fixup value a RELOC resolves to (the value OnReloc
   bakes into the site), WITHOUT patching anything.  LinkNE uses this to obtain
   the real target offset for an NE OFFS/PTR reloc record while leaving the file
   site as its placeholder (the NE loader writes the value at load time — see
   NE-BP.MD §1.4).  Absolute fixups (rrel = 0) return the target's in-segment
   offset; IP-relative fixups (rrel # 0) return the PC-relative displacement. *)
PROCEDURE OnReloc*(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                  rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR sym: Symbol; so: Module;
      fixup: WORD;      (* an absolute in-segment offset: 0..65535 -> WORD, not INTEGER *)
      patchAddr: LONGINT;  (* code: <=64KB in-module offset; data: absolute
                              dataFile byte offset (can exceed 64KB total
                              across all modules) *)
      isOverlayCall: BOOLEAN;
      overlayTarget: Module;
      entryId: INTEGER;
      symName: ARRAY 40 OF CHAR;
BEGIN
  IF rseg = Rdoff.SegCode THEN patchAddr := LONGINT(PatchCodeAddrOf(rofs))
  ELSE patchAddr := DataFileOffsetOf(lnkLs, lnkMod, rofs) END;

  isOverlayCall := FALSE;
  fixup := 0;
  IF (rrefSeg = Rdoff.SegCode) OR (rrefSeg = Rdoff.SegData) THEN
    (* self-reference: base is 0 (see comment above) — fixup stays 0.
       Confirmed still correct for an OVERLAY module's DATA self-reference
       too (checked 2026-08-12 while chasing the two-overlay-module bug,
       EXAMPLES/OVRDEMO/repro4_defplus_linkne): OnSegRelocOverlay's own
       SegData branch bakes lnkMod^.dataPara as the DS-reload's link-time
       base AND registers it as an ovrXFixups entry, so at runtime that
       reload becomes dataPara+LoadSegment() -- i.e. DS already points
       exactly at THIS module's own data start, not the whole image's.
       An in-module data offset of 0 under that reload is correct as-is;
       adding dataPara*16 again here (tried and reverted) double-counts
       it. *)
  ELSIF rrefSeg = Rdoff.SegBss THEN
    fixup := WORD(lnkMod^.bssOfs)
  ELSE
    sym := FindImport(rrefSeg);
    IF sym = NoSym THEN LogErr.Error("Relocation to missing import"); RETURN END;
    fixup := WORD(SymOffset(lnkLs, sym));
    IF SymSegId(lnkLs, sym) = 2 THEN
      so := SymOwner(lnkLs, sym);
      fixup := fixup + WORD(so^.bssOfs)
    END;
    (* DOCS/OVR.MD §5: a CALL FAR (rseg=SegCode, rwidth=2,
       rrel=0 -- absolute, matching CgCallFar's own
       RdfAddReloc(...,2,importId,FALSE) at CGEN.MOD:396) whose target's
       owning module is .OVR-eligible is an overlay call, UNLESS the
       target is that module's own __init (always resident, never
       reached through the trampoline). *)
    IF (rseg = Rdoff.SegCode) & (rwidth = 2) & (rrel = 0) THEN
      so := SymOwner(lnkLs, sym);
      IF so^.isOverlay & ~IsInitTarget(lnkLs, sym) THEN
        isOverlayCall := TRUE; overlayTarget := so
      END
    END
  END;

  IF rrel # 0 THEN
    (* IP-relative self-reference: subtract the absolute offset of the byte
       after the patch field (both patch site and target are in this
       module's own segment — see the comment above). *)
    fixup := fixup - (WORD(rofs) + WORD(rwidth))
  END;

  IF isOverlayCall THEN
    (* patchAddr is the reloc's OPERAND offset (1 byte past CgCallFar's own
       opcode emission, CGEN.MOD:390-397); the opcode byte is always
       exactly 1 byte before it (DOCS/OVR.MD §5). *)
    StrTab.Get(SymNameId(lnkLs, sym), symName);
    entryId := OvrEntryId(overlayTarget, symName);
    IF entryId < 0 THEN
      LogErr.Error2("overlay: target has no .OVR entry id: ", symName); RETURN
    END;
    (* DOCS/OVR.MD §11.1: the trampoline id is ONE byte -- a hard 256-entry-point
       ceiling across the WHOLE program (global ids, see ovrEntryIdBase),
       a direct consequence of this project's own 5-byte INT-3Fh trampoline
       encoding (1 opcode + 1 interrupt number + 1 id byte + 2 offset
       bytes). *)
    IF entryId > 255 THEN
      LogErr.Error("overlay: more than 256 overlay entry points in one program (trampoline id is 1 byte)");
      RETURN
    END;
    PatchOverlayCallSite(patchAddr - 1, entryId, fixup);
    AddOvrSite(overlayTarget, lnkMod, patchAddr - 1, entryId);

    (* Cross-overlay calls (DOCS/OVR.MD §9): if the
       CALLING code is itself inside an overlay module, the return address
       (patchAddr - 1 + 5, one past this 5-byte trampoline) needs its OWN
       trampoline too: when the callee returns, if the
       CALLER's own module was evicted in the meantime (to make room for a
       nested call), the return address is no longer valid resident
       memory, so it must be independently loadable exactly like any
       other overlay entry point -- a DIFFERENT global entry id than the
       caller's own public entry points, physically living inside the
       CALLER's own code (so the caller module, lnkMod, owns this site's
       directory/call-site bookkeeping, not overlayTarget). A resident
       (non-overlay) caller needs none of this: its own code never moves,
       so the plain return address it already has is always valid --
       gated on lnkMod^.isOverlay. *)
    IF lnkMod^.isOverlay THEN
      AddOvrReturnTrampoline(lnkMod, patchAddr - 1 + LONGINT(5), entryId)
    END
  ELSIF rseg = Rdoff.SegCode THEN PatchBuf(patchAddr, fixup, rwidth)
  ELSE PatchDataFile(patchAddr, fixup, rwidth) END
END OnReloc;

(* ---- accessors for target-specific segRelocProc callbacks (LinkMZ/LinkNE) ----
   lnkLs/lnkMod are set by ProcessModule for the duration of one module's
   relocation scan; a segRelocProc callback (FAR, fixed Rdoff.RelocProc
   signature — no ls/m params of its own) needs these to compute its own
   segment-value fixup, exactly as OnReloc does above. *)
PROCEDURE CurrentState*(): State;
BEGIN RETURN lnkLs END CurrentState;

PROCEDURE CurrentModule*(): Module;
BEGIN RETURN lnkMod END CurrentModule;

(* ---- perform all linking (fill buffers, apply relocs, build MZ reloc list) ---- *)

PROCEDURE WriteZeros*(VAR f: Files.File; n: LONGINT);
  VAR buf: ARRAY 128 OF BYTE; chunk: WORD;
BEGIN
  (* n<=0 means "nothing to pad" -- must return here, not fall through to
     chunk:=WORD(n): a negative n reinterprets as a huge unsigned WORD
     (e.g. -2 -> 65534), driving Files.BlockWrite to read far past this
     128-byte buf and silently desyncing every file offset computed after
     this call.  A caller passing negative n is itself a bug (its own
     offset arithmetic is wrong) -- this guard turns that into a clean
     no-op instead of file corruption; it does not paper over the caller's
     bug, which must still be fixed at the source. *)
  IF n <= LONGINT(0) THEN RETURN END;
  SYSTEM.FILL(buf, 128, 0);
  WHILE n > LONGINT(128) DO
    IF Files.BlockWrite(f, buf, 128) # 128 THEN LogErr.Error("Write error") END;
    DEC(n, LONGINT(128))
  END;
  chunk := WORD(n);
  IF chunk > 0 THEN
    IF Files.BlockWrite(f, buf, chunk) # chunk THEN LogErr.Error("Write error") END
  END
END WriteZeros;

(* Process one module's own CODE segment: load its code into the reusable
   scratch buffer, apply its relocations (RELOC + SEGRELOC, via the
   target-specific segRelocProc callback), spill the relocated bytes to the
   code temp file at the module's own image offset, then move on.  Only one
   module's code buffer is ever resident, so peak code heap is <= one
   module's own .rdf code size (<= 64KB, RDOFF2's own per-segment limit)
   regardless of total program size. *)
(* ftmp is written strictly sequentially; pos is the next byte offset.  Pads
   the gap from pos up to the module's own codePara*16 with zeros (inter-
   module 16-byte alignment) before writing it, so we never rely on
   seek-past-EOF zero-filling (which xt's DOS does not do).  pos is advanced
   past the module afterward. *)
PROCEDURE ProcessModule(ls: State; m: Module; VAR ftmp: Files.File;
                        VAR pos: LONGINT; onRelocProc, segRelocProc: Rdoff.RelocProc);
  VAR sz, k: WORD; codeStart: LONGINT;
      padBuf: ARRAY 16 OF BYTE; padLen: WORD;
BEGIN
  codeStart := LONGINT(m^.codePara) * LONGINT(16);
  sz := WORD(m^.codeSize);
  IF sz < 1 THEN RETURN END;
  (* pad to the module's image offset: at most 15 bytes (16-byte alignment),
     so one small block write replaces a former 1-byte-at-a-time loop. *)
  IF pos < codeStart THEN
    padLen := WORD(codeStart - pos);
    SYSTEM.FILL(padBuf, 16, 0);
    IF Files.BlockWrite(ftmp, padBuf, padLen) # padLen THEN
      LogErr.Error("Write error (code pad)")
    END;
    pos := codeStart
  END;
  (* explicit indexed loop, NOT SYSTEM.FILL: a far-heap SegBuf zeroed via
     SYSTEM.FILL previously mis-addressed (see implementation-rules.md
     §"Reusing one shared code buffer") — reverted, do not retry. *)
  k := 0; WHILE k < sz DO ls^.codeBuf^[k] := BYTE(0); INC(k) END;

  Rdoff.ReadCode(m^.path, m^.libOfs, m^.hdrSize, ls^.codeBuf, 0, sz);

  (* apply this module's relocations (data-segment relocs go through
     ls^.dataFile inside PatchDataFile, not a RAM alias) *)
  lnkCodeBuf := ls^.codeBuf;
  lnkMod := m;
  FreeImports;
  (* Pass 1: collect IMPORT records first (RELOCs may precede them). *)
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, OnImportForLink, NIL, NIL);
  (* Pass 2: apply RELOC and SEGRELOC records.  onRelocProc handles RELOC
     (offset) fixups — LinkMZ passes Link.OnReloc (pre-bake only); LinkNE
     passes its own (pre-bake + record an NE OFFS/PTR reloc). *)
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, NIL, onRelocProc, segRelocProc);
  FreeImports;   (* release this module's IMPORT chain *)

  (* spill the relocated module sequentially *)
  IF Files.BlockWrite(ftmp, ls^.codeBuf^[0], sz) # sz THEN
    LogErr.Error("Write error (code spill)")
  END;
  pos := pos + LONGINT(sz)
END ProcessModule;

(* Append one WORD offset to m^.ovrFixups (DOCS/OVR.MD §7). *)
PROCEDURE AddOvrFixup(m: Module; ofs: WORD);
  VAR node: OvrFixupNode; k: INTEGER;
BEGIN
  IF (m^.ovrFixups = NIL) OR (m^.ovrFixups^.count >= OvrFixupChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (overlay fixup chunk)"); RETURN END;
    node^.count := 0; node^.next := m^.ovrFixups; m^.ovrFixups := node
  END;
  k := m^.ovrFixups^.count;
  m^.ovrFixups^.ofs[k] := ofs;
  INC(m^.ovrFixups^.count); INC(m^.ovrNFixups)
END AddOvrFixup;

(* Append one WORD offset to m^.ovrXFixups -- the cross-module counterpart
   of AddOvrFixup (see ovrXFixups' own comment: needs the PROGRAM's load
   segment added at runtime, not this module's own destParas). *)
PROCEDURE AddOvrXFixup(m: Module; ofs: WORD);
  VAR node: OvrFixupNode; k: INTEGER;
BEGIN
  IF (m^.ovrXFixups = NIL) OR (m^.ovrXFixups^.count >= OvrFixupChunk) THEN
    NEW(node);
    IF node = NIL THEN LogErr.Error("Out of memory (overlay xfixup chunk)"); RETURN END;
    node^.count := 0; node^.next := m^.ovrXFixups; m^.ovrXFixups := node
  END;
  k := m^.ovrXFixups^.count;
  m^.ovrXFixups^.ofs[k] := ofs;
  INC(m^.ovrXFixups^.count); INC(m^.ovrNXFixups)
END AddOvrXFixup;

(* Overlay-aware counterpart of Link.OnReloc: a pure pass-through.
   OnReloc's own isOverlayCall branch already handles cross-overlay calls
   correctly regardless of which module is currently being scanned
   (lnkMod^.isOverlay gates the AddOvrReturnTrampoline call, DOCS/OVR.MD
   §9, done 2026-08-08) -- there is nothing left for
   this wrapper to do differently.  It exists only so ProcessOverlayModule
   can pass a named, symmetric callback pair (OnRelocOverlay/
   OnSegRelocOverlay) matching ProcessModule's own (OnReloc/segRelocProc)
   shape; OnSegRelocOverlay (below) is NOT a pure pass-through (it needs
   the SEGRELOC-suppression guard), which is the only reason this sibling
   procedure exists at all rather than passing Link.OnReloc directly. *)
PROCEDURE OnRelocOverlay*(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                         rrefSeg: INTEGER; rrel: INTEGER); FAR;
BEGIN
  OnReloc(rseg, rofs, rwidth, rrefSeg, rrel)
END OnRelocOverlay;

(* Overlay-aware counterpart of LinkMZ.OnSegReloc: a SEGRELOC bakes a
   segment PARAGRAPH value, which for every target EXCEPT this overlay
   module's own CODE/DATA is a link-time constant exactly as for a
   resident module (a resident target's segment never moves; BSS is one
   shared segment fixed at link time too).  Only a self-reference to
   THIS overlay module's own CODE (assumed load segment = 0, per
   DOCS/OVR.MD §7's "compiled assuming SOME load segment" framing) needs
   the internal fixup table: the baked 0 is a placeholder the runtime
   loader must ADD the real load segment to once one is chosen.  A
   self-reference to this module's own DATA needs no fixup at all -- DATA
   stays in the main image, at its real, link-time-fixed dataPara,
   regardless of where the module's CODE is loaded (§1 foundation: module
   data already survives a code swap, for free). *)
(* Resolve an IMPORT-referenced SEGRELOC target's own segment paragraph,
   for an overlay module's own outgoing SEGRELOC.  Mirrors LinkMZ's
   TargetSegPara import branch exactly.  The target reaching here is
   ALWAYS a resident module (main image) in practice, NOT because
   cross-overlay calls don't exist (they do, DOCS/OVR.MD §9,
   done 2026-08-08) but because OnSegRelocOverlay's own
   IsOverlayImport guard (below) already RETURNs before reaching this
   procedure for the one case that could target overlay code (rseg=
   SegCode, rwidth=2, i.e. the paired SEGRELOC half of a CgCallFar site
   the RELOC half already rewrote into a trampoline).  so^.codePara for
   an overlay module is otherwise left at CalculateLayout's SYSTEM.FILL
   zero value (never assigned, see CalculateLayout's own comment) and
   would silently bake 0 here if that guard were ever narrowed or
   bypassed -- e.g. a non-call SEGRELOC to overlay code, such as
   SYSTEM.ADR(OverlayProc) via Cgen.CgLoadImportAddr, is NOT a CALL FAR
   site and is not currently exercised/guarded against here. *)
PROCEDURE TargetSegParaOverlay(ls: State; rrefSeg: INTEGER): WORD;
  VAR so: Module; sym: Symbol; segId: INTEGER;
BEGIN
  sym := FindImport(rrefSeg);
  IF sym = NoSym THEN RETURN 0 END;
  so := SymOwner(ls, sym);
  segId := SymSegId(ls, sym);
  IF segId = 0 THEN RETURN so^.codePara
  ELSIF segId = 1 THEN RETURN so^.dataPara
  ELSE RETURN ls^.bssPara END
END TargetSegParaOverlay;

PROCEDURE OnSegRelocOverlay*(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                            rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR fixup: WORD; patchAddr: LONGINT;
BEGIN
  IF rseg = Rdoff.SegCode THEN patchAddr := rofs
  ELSE patchAddr := DataFileOffsetOf(lnkLs, lnkMod, rofs) END;

  (* Cross-overlay calls (DOCS/OVR.MD §9): mirrors
     LinkMZ.OnSegReloc's own SEGRELOC-suppression guard exactly (see that
     procedure's own comment for the full story -- found there
     2026-08-07, missed here at first when cross-overlay calls were
     added, found again the same way: xt trace showed this SEGRELOC
     clobbering the trampoline's own entryOfs bytes at [opAddr+3..+4]
     with a resolved segment paragraph, the SAME bug class, just on the
     OVERLAY-CALLER's own outgoing SEGRELOC instead of a resident
     caller's).  CgCallFar always emits a RELOC (offset word) AND a
     SEGRELOC (segment word) for the same CALL FAR site; when OnReloc
     (called first, via Rdoff.ScanRelocs's own ordering) rewrites that
     RELOC's site into the overlay trampoline form, this SEGRELOC arrives
     separately, unaware of the rewrite, and must not patch over the
     entryOfs bytes the rewrite just wrote. *)
  IF IsOverlayCallSiteSegReloc(lnkLs, rseg, rwidth, rrefSeg) THEN
    RETURN
  END;

  (* Patch site in THIS module's own DATA (rseg#SegCode), target NOT this
     module's own overlay CODE (rrefSeg#SegCode): both sides of the patch
     are resident/main-image (module DATA never moves with an overlay's
     CODE, DOCS/OVR.MD §3's foundation; the target -- self-DATA, self-BSS,
     or any external import -- is, by construction, either this same
     module's own DATA or a module that isn't overlay CODE either, since
     IsOverlayCallSiteSegReloc above already returned for the one case
     that COULD target overlay code, the paired half of an overlay CALL
     FAR site).  This is therefore EXACTLY the same shape as a resident
     module's own identical SEGRELOC, which LinkMZ.OnSegReloc (called via
     segRelocProc here, the real target's callback) already handles
     correctly INCLUDING the MZ loader-relocation entry (AddReloc) a
     link-time-fixed-but-still-load-segment-relative paragraph value
     needs.  Bug found 2026-08-15: this branch used to duplicate
     LinkMZ.OnSegReloc's own patch logic (TargetSegParaOverlay + PatchBuf/
     PatchDataFile below) WITHOUT ever registering that MZ reloc entry --
     ovrXFixups (the correction the .OVR payload's own CODE fixups use)
     is the WRONG mechanism for a DATA-segment patch site, since main-
     image DATA IS covered by the ordinary MZ loader relocation table,
     unlike .OVR payload bytes, which the loader never touches at all.
     Silently missing that entry left the baked value permanently
     image-relative (never getting the load segment added), so any
     cross-module reference from an overlay module's DATA to a resident
     module's own exported VAR (e.g. Def.DefWrite's "sym # Syms.NoSym"
     loop guard) read a garbage segment at runtime -- confirmed via
     Overlay.DbgCounts-style instrumentation showing Syms.NoSym resolving
     to a non-NIL, unstable value from Def's own compiled code, turning
     the loop's own termination check into an infinite scan over garbage
     memory (TESTS/FIX/OVRDATAX*.MOD reproduces this exactly). *)
  IF (rseg # Rdoff.SegCode) & (rrefSeg # Rdoff.SegCode) THEN
    lnkSegRelocProc(rseg, rofs, rwidth, rrefSeg, rrel);
    RETURN
  END;

  (* Every branch below bakes a paragraph number that is relative to the
     WHOLE PROGRAM's own load segment (codePara/dataPara/bssPara, exactly
     like any main-image SEGRELOC's target) -- for a main-image site, the
     DOS MZ loader adds the real load segment automatically via the MZ
     relocation table (LinkMZ.OnSegReloc's own AddReloc); .OVR file content
     is never touched by that loader at all, so nothing else will ever add
     it here.  ovrFixups (destParas addend, this module's OWN load segment --
     used only for a genuine self-reference to this module's own CODE, which
     moves with each load/evict cycle) is therefore the wrong table for
     these: every case here needs the PROGRAM's load segment
     (Overlay.LoadSegment()) added instead, via the separate ovrXFixups
     table applied by the SAME ApplyFixups runtime pass with a different
     addend.  Reached ONLY when rseg=SegCode (patch site in this module's
     OWN overlay code -- the branch above already returned for every
     rseg#SegCode/DATA-patch case, which is now delegated to the real
     segRelocProc instead) OR rrefSeg=SegCode (target is this module's own
     overlay CODE, which has no real link-time segment at all -- see
     TargetSegParaOverlay's own comment). *)
  (* The runtime fixup tables (ovrFixups/ovrXFixups) are read back by
     ApplyFixups/ApplyXFixups and ALWAYS interpreted as offsets into this
     module's own loaded CODE segment (destParas) -- see ApplyFixupsAt.
     A patch site with rseg=SegData lives in the module's DATA image
     instead (ls^.dataFile, patched below via PatchDataFile), which is
     link-time-fixed and never reloaded, so it needs no runtime fixup at
     all (matching this procedure's own header comment: "A self-reference
     to this module's own DATA needs no fixup at all").  Recording such a
     site's rofs into ovrFixups/ovrXFixups anyway (missing rseg=SegCode
     guard, found chasing bug #4) made the runtime pass reinterpret a
     DATA-segment byte offset as a CODE-segment one and stomp two
     unrelated code bytes at that offset with a segment-paragraph value --
     see EXAMPLES/OVRDEMO/repro7_loop_call/README.md. *)
  IF rrefSeg = Rdoff.SegCode THEN
    fixup := 0;   (* assumed load segment placeholder -- see comment above *)
    IF rseg = Rdoff.SegCode THEN AddOvrFixup(lnkMod, WORD(rofs)) END
  ELSIF rrefSeg = Rdoff.SegData THEN
    fixup := lnkMod^.dataPara;
    IF rseg = Rdoff.SegCode THEN AddOvrXFixup(lnkMod, WORD(rofs)) END
  ELSIF rrefSeg = Rdoff.SegBss THEN
    fixup := lnkLs^.bssPara;
    IF rseg = Rdoff.SegCode THEN AddOvrXFixup(lnkMod, WORD(rofs)) END
  ELSE
    fixup := TargetSegParaOverlay(lnkLs, rrefSeg);
    IF rseg = Rdoff.SegCode THEN AddOvrXFixup(lnkMod, WORD(rofs)) END
  END;

  IF rseg = Rdoff.SegCode THEN PatchBuf(patchAddr, fixup, 2)
  ELSE PatchDataFile(patchAddr, fixup, 2) END
END OnSegRelocOverlay;

(* Process one overlay module's own CODE: load it into the shared scratch
   buffer, apply its relocations via the overlay-aware callbacks above,
   append the relocated bytes to ls^.ovrSpillFile (sequential, like
   ProcessModule's main-image spill), and record where they landed
   (m^.ovrCodeOfs) for LinkOvr.WriteOvrFile to find later.  ovrPos tracks
   the next free byte in ovrSpillFile, mirroring ProcessModule's pos. *)
PROCEDURE ProcessOverlayModule(ls: State; m: Module; VAR ovrPos: LONGINT;
                               segRelocProc: Rdoff.RelocProc);
  VAR sz, k: WORD;
BEGIN
  sz := WORD(m^.codeSize);
  m^.ovrCodeOfs := ovrPos;
  IF sz < 1 THEN RETURN END;
  k := 0; WHILE k < sz DO ls^.codeBuf^[k] := BYTE(0); INC(k) END;
  Rdoff.ReadCode(m^.path, m^.libOfs, m^.hdrSize, ls^.codeBuf, 0, sz);

  lnkCodeBuf := ls^.codeBuf;
  lnkMod := m;
  lnkSegRelocProc := segRelocProc;
  FreeImports;
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, OnImportForLink, NIL, NIL);
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, NIL, OnRelocOverlay, OnSegRelocOverlay);
  FreeImports;

  IF Files.BlockWrite(ls^.ovrSpillFile, ls^.codeBuf^[0], sz) # sz THEN
    LogErr.Error("Write error (overlay code spill)")
  END;
  ovrPos := ovrPos + LONGINT(sz)
END ProcessOverlayModule;

PROCEDURE PerformLinking*(ls: State; onRelocProc, segRelocProc: Rdoff.RelocProc);
  VAR m, eso: Module; esym: Symbol; sz, pos: LONGINT;
BEGIN
  (* Combined DATA image (every used module's own DATA segment, back-to-
     back in module order — see CalculateLayout) — file-backed instead of a
     resident RAM buffer (LINKBUF-REPORT.MD §4.1: CalculateLayout already
     fixed every module's dataPara, so a Files.Seek-capable temp file gives
     the same random-access guarantee a RAM buffer did). Pre-zero the whole
     span first (WriteZeros, sequential — same technique as WriteExe's
     header padding) so any gap no module's data covers (e.g. alignment
     padding between modules) reads back as zero, matching the old buffer's
     explicit zero-fill.  BSS is NOT included here — it carries no file
     bytes at all (see WriteExe). *)
  IF ~Files.ReWriteTemp(ls^.dataFile) THEN LogErr.Error("Cannot create data temp"); RETURN END;
  sz := ls^.totalDataLen;
  IF sz < LONGINT(1) THEN sz := LONGINT(1) END;
  WriteZeros(ls^.dataFile, sz);

  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & (m^.dataSize > LONGINT(0)) THEN
      Rdoff.ReadDataToFile(m^.path, m^.libOfs, m^.hdrSize,
                       ls^.dataFile, DataFileBase(ls, m), WORD(m^.dataSize))
    END;
    m := m^.next
  END;

  (* Stream the code: process each module transiently into the spill file,
     writing strictly sequentially (pos tracks the next byte). *)
  lnkLs := ls;
  IF ~Files.ReWriteTemp(ls^.spillFile) THEN LogErr.Error("Cannot create code temp"); RETURN END;
  pos := LONGINT(0);
  m := ls^.modHead;
  WHILE (m # NIL) & ~LogErr.HaveErr() DO
    (* Overlay modules contribute no bytes to the main image's CODE region
       (CalculateLayout left codePara at 0, which would otherwise collide
       with the real module living at paragraph 0) -- their own code+reloc
       processing happens separately, via LinkOvr, after this returns
       (DOCS/OVR.MD §11.1). *)
    IF m^.used & ~m^.isOverlay THEN ProcessModule(ls, m, ls^.spillFile, pos, onRelocProc, segRelocProc) END;
    m := m^.next
  END;
  (* Pad the spill up to totalCodeLen: the last module's code ends at `pos`
     (its own bytes, NOT rounded up), but totalCodeLen = Align16(codeBase)
     includes the final 16-alignment gap.  CopyCodeImage copies exactly
     totalCodeLen bytes, and the MZ header (pageCnt/partPage) is computed from
     totalCodeLen+totalDataLen — so without this pad the file is up to 15 bytes
     SHORT of the size the header declares, and the program reads past its own
     loaded image at startup (xt "arraycopy out of bounds"). *)
  IF pos < ls^.totalCodeLen THEN WriteZeros(ls^.spillFile, ls^.totalCodeLen - pos) END;
  (* Rewind for reading — keep the file open; closing now would destroy its
     content (delete-on-close) before CopyCodeImage can read it. *)
  Files.Seek(ls^.spillFile, LONGINT(0));

  (* Overlay modules: same reusable ls^.codeBuf, a separate spill file, no
     alignment/padding needed (LinkOvr.WriteOvrFile streams each module's
     own bytes by its own recorded length, never by fixed image offsets --
     unlike the main image, nothing here needs 16-byte segment alignment
     between modules). Must run BEFORE ls^.codeBuf is disposed below. *)
  IF ls^.anyOverlay & ~LogErr.HaveErr() THEN
    IF ~Files.ReWriteTemp(ls^.ovrSpillFile) THEN
      LogErr.Error("Cannot create overlay code temp"); RETURN
    END;
    pos := LONGINT(0);
    m := ls^.modHead;
    WHILE (m # NIL) & ~LogErr.HaveErr() DO
      IF m^.used & m^.isOverlay THEN ProcessOverlayModule(ls, m, pos, segRelocProc) END;
      m := m^.next
    END;
    Files.Seek(ls^.ovrSpillFile, LONGINT(0))
  END;

  (* The 65000-byte per-module code buffer is finished the moment the streaming
     loop above ends — WriteExe/CopyCodeImage read only the spill file, never
     codeBuf.  Release it NOW (not in LinkFree) so its 65 KB is free during the
     .exe write, which is the link's tightest memory point (LinkFree's NIL
     guard makes the later dispose a no-op). *)
  IF ls^.codeBuf # NIL THEN DISPOSE(ls^.codeBuf); ls^.codeBuf := NIL END;

  (* Resolve entry point: "start" lives at offset SymOffset within its own
     module's own CODE segment (codePara), no group-relative math needed. *)
  esym := FindSymbol(ls, "start");
  IF esym # NoSym THEN
    eso := SymOwner(ls, esym);
    ls^.entryIp      := WORD(SymOffset(ls, esym));
    ls^.entryCSPara  := INTEGER(eso^.codePara)
  END
END PerformLinking;

(* Read META-INF/STACK.TXT from the entry .om *)
PROCEDURE ReadStackSize*(ls: State);
  VAR sym: Symbol; so: Module;
BEGIN
  sym := FindSymbol(ls, "start");
  IF sym # NoSym THEN
    so := SymOwner(ls, sym);
    IF so # NIL THEN Tar.ScanTar(so^.path, NIL, ls^.stackSize, TRUE) END
  END
END ReadStackSize;

(* Release the entire link-State graph: modules, symbols,
   group descriptors, and the data buffer.  Symbols live in the chunk-node list
   (ls^.symNodes); the WORD handle chains (symHead/next, symHash/hNext) index into
   those chunks and need no per-symbol free. *)
(* Free one module's three chunked overlay lists (DOCS/OVR.MD §11.1)
   -- DISPOSE(m) alone only frees the ModRec itself, not what it
   points to; without this every $O+ module link leaked one chunk node
   per list (found via the zero-heap-leaks check on the real
   EXAMPLES/OVRDEMO/ fixtures, CLAUDE.md "ZERO HEAP LEAKS — KEY RULE"). *)
PROCEDURE FreeOverlayLists(m: Module);
  VAR en, enNext: OvrEntryNode;
      fn, fnNext: OvrFixupNode;
      xn, xnNext: OvrFixupNode;
      sn, snNext: OvrSiteNode;
      rn, rnNext: OvrResumeNode;
BEGIN
  en := m^.ovrEntries;
  WHILE en # NIL DO enNext := en^.next; DISPOSE(en); en := enNext END;
  fn := m^.ovrFixups;
  WHILE fn # NIL DO fnNext := fn^.next; DISPOSE(fn); fn := fnNext END;
  xn := m^.ovrXFixups;
  WHILE xn # NIL DO xnNext := xn^.next; DISPOSE(xn); xn := xnNext END;
  sn := m^.ovrSites;
  WHILE sn # NIL DO snNext := sn^.next; DISPOSE(sn); sn := snNext END;
  rn := m^.ovrResumes;
  WHILE rn # NIL DO rnNext := rn^.next; DISPOSE(rn); rn := rnNext END
END FreeOverlayLists;

PROCEDURE LinkFree*(ls: State);
  VAR m, mNext: Module; sn, snNext: SymNode; i: INTEGER;
BEGIN
  sn := ls^.symNodes;
  WHILE sn # NIL DO snNext := sn^.next; DISPOSE(sn); sn := snNext END;
  ls^.symNodes := NIL; ls^.symHead := NoSym; ls^.symCount := 0;
  i := 0; WHILE i < MaxSymChunk DO ls^.symDir[i] := NIL; INC(i) END;
  i := 0; WHILE i < SymHash DO ls^.symHash[i] := NoSym; INC(i) END;

  m := ls^.modHead;
  WHILE m # NIL DO
    mNext := m^.next;
    FreeOverlayLists(m);
    DISPOSE(m);
    m := mNext
  END;
  ls^.modHead := NIL; ls^.modTail := NIL;

  IF ls^.codeBuf # NIL THEN DISPOSE(ls^.codeBuf); ls^.codeBuf := NIL END
END LinkFree;

END Link.
