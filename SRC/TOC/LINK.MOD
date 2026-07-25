(*$D-*)
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

TYPE
  Module* = POINTER TO ModRec;
  ModRec* = RECORD
    path*:         ARRAY MaxPath OF CHAR;
    stem*:         ARRAY 10 OF CHAR;  (* member basename w/o ".RDF" (<=8) — "" when
                                         no MODNAME.DBG can exist ($L extras etc.) —
                                         used only by LinkMZ's TDS/TDINFO debug writer *)
    hasDbg*:       BOOLEAN;   (* non-empty MODNAME.DBG found (debug pass 1) — LinkMZ-only *)
    dbgModName*:   INTEGER;   (* pool ordinal of the module ident (M line) — LinkMZ-only *)
    dbgSrcName*:   INTEGER;   (* pool ordinal of the source file name (F line) — LinkMZ-only *)
    dbgTypeBase*:  WORD;      (* this module's local TYPE indices are offset by this — LinkMZ-only *)
    dbgMembBase*:  WORD;      (* this module's local MEMBER indices are offset by this — LinkMZ-only *)
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
                                 see DOCS/NE-PLAN.MD §0). *)
    dataPara*:     WORD;      (* this module's own DATA segment paragraph *)
    bssOfs*:       LONGINT;   (* this module's own byte offset WITHIN the one
                                 shared BSS segment (State.bssPara) — all
                                 modules share ONE BSS segment (unlike CODE/
                                 DATA, which are per-module); this is just
                                 this module's own slice of it. Carries NO
                                 file bytes at all (DOS zero-fills the whole
                                 shared BSS region via min_alloc at load) —
                                 see WriteExe. *)
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
    stackSize*:   LONGINT
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
  ls^.stackSize    := LONGINT(StackDef)
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
   complete, self-contained unit by the time it reaches Link; see
   DOCS/NE-PLAN.MD §0).  Image order (fixed, see WriteExe):
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

  (* Pass 1: every USED module's own CODE segment, back-to-back, 16-aligned. *)
  codeBase := LONGINT(0);
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used THEN
      codeBase := Align16(codeBase);
      m^.codePara := WORD(codeBase DIV LONGINT(16));
      codeBase := codeBase + Align2(m^.codeSize)
    END;
    m := m^.next
  END;
  ls^.totalCodeLen := Align16(codeBase);

  (* Pass 2: every USED module's own DATA segment, immediately after all
     CODE segments, back-to-back, 16-aligned. *)
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
     BSS stays a single combined segment — see NE-PLAN discussion) — each
     module gets its own byte OFFSET within that one segment, 2-byte
     aligned (matches the pre-per-module-CODE/DATA combined-segment
     behaviour).  Placed after all CODE+DATA; memory-only, no file bytes
     (WriteExe relies on min_alloc to get this span zero-filled by DOS at
     load — that only works because nothing with real file bytes follows
     it in the image). *)
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
PROCEDURE OnReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                  rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR sym: Symbol; so: Module;
      fixup: WORD;      (* an absolute in-segment offset: 0..65535 -> WORD, not INTEGER *)
      patchAddr: LONGINT;  (* code: <=64KB in-module offset; data: absolute
                              dataFile byte offset (can exceed 64KB total
                              across all modules) *)
BEGIN
  IF rseg = Rdoff.SegCode THEN patchAddr := LONGINT(PatchCodeAddrOf(rofs))
  ELSE patchAddr := DataFileOffsetOf(lnkLs, lnkMod, rofs) END;

  fixup := 0;
  IF (rrefSeg = Rdoff.SegCode) OR (rrefSeg = Rdoff.SegData) THEN
    (* self-reference: base is 0 (see comment above) — fixup stays 0 *)
  ELSIF rrefSeg = Rdoff.SegBss THEN
    fixup := WORD(lnkMod^.bssOfs)
  ELSE
    sym := FindImport(rrefSeg);
    IF sym = NoSym THEN LogErr.Error("Relocation to missing import"); RETURN END;
    fixup := WORD(SymOffset(lnkLs, sym));
    IF SymSegId(lnkLs, sym) = 2 THEN
      so := SymOwner(lnkLs, sym);
      fixup := fixup + WORD(so^.bssOfs)
    END
  END;

  IF rrel # 0 THEN
    (* IP-relative self-reference: subtract the absolute offset of the byte
       after the patch field (both patch site and target are in this
       module's own segment — see the comment above). *)
    fixup := fixup - (WORD(rofs) + WORD(rwidth))
  END;

  IF rseg = Rdoff.SegCode THEN PatchBuf(patchAddr, fixup, rwidth)
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
                        VAR pos: LONGINT; segRelocProc: Rdoff.RelocProc);
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
  (* Pass 2: apply RELOC and SEGRELOC records. *)
  Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, NIL, OnReloc, segRelocProc);
  FreeImports;   (* release this module's IMPORT chain *)

  (* spill the relocated module sequentially *)
  IF Files.BlockWrite(ftmp, ls^.codeBuf^[0], sz) # sz THEN
    LogErr.Error("Write error (code spill)")
  END;
  pos := pos + LONGINT(sz)
END ProcessModule;

PROCEDURE PerformLinking*(ls: State; segRelocProc: Rdoff.RelocProc);
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
    IF m^.used THEN ProcessModule(ls, m, ls^.spillFile, pos, segRelocProc) END;
    m := m^.next
  END;
  (* Rewind for reading — keep the file open; closing now would destroy its
     content (delete-on-close) before CopyCodeImage can read it. *)
  Files.Seek(ls^.spillFile, LONGINT(0));

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
PROCEDURE LinkFree*(ls: State);
  VAR m, mNext: Module; sn, snNext: SymNode; i: INTEGER;
BEGIN
  sn := ls^.symNodes;
  WHILE sn # NIL DO snNext := sn^.next; DISPOSE(sn); sn := snNext END;
  ls^.symNodes := NIL; ls^.symHead := NoSym; ls^.symCount := 0;
  i := 0; WHILE i < MaxSymChunk DO ls^.symDir[i] := NIL; INC(i) END;
  i := 0; WHILE i < SymHash DO ls^.symHash[i] := NoSym; INC(i) END;

  m := ls^.modHead;
  WHILE m # NIL DO mNext := m^.next; DISPOSE(m); m := mNext END;
  ls^.modHead := NIL; ls^.modTail := NIL;

  IF ls^.codeBuf # NIL THEN DISPOSE(ls^.codeBuf); ls^.codeBuf := NIL END
END LinkFree;

END Link.
