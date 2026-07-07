MODULE Link;
(*
  RDOFF2 smart linker core for MS-DOS.
  Phase 1: scan modules, build symbol table, calculate layout, load code/data
           into heap buffers, apply all relocations, build MZ reloc list.
  Phase 2: write MZ EXE from heap buffers.

  Memory strategy (DOS-safe):
  - Each code group <= 64KB: one CodeBuf per group, allocated with NEW.
  - All data combined into one DataBuf <= 64KB.
  - All MZ relocs collected as a linked list before writing.
*)
IMPORT Dos, Files, Err, Rdoff, Tar, Strings;

CONST
  SymHash*   = 256;      (* symbol hash table size, power of 2 *)
  MaxPath*   = 128;
  MaxName*   = 34;      (* link symbol = module(<=8) + "_" + ident(<=24) + 0X *)
  StackDef   = 8192;     (* default stack size *)
  MzHdrBytes = 28;       (* fixed MZ header size *)
  MZChunk    = 256;      (* MZ relocations per chunk node (small-record rule) *)
  ImpChunk   = 128;      (* IMPORT entries per chunk node (small-record rule) *)
  GrpChunk   = 128;      (* group descriptors per chunk node (small-record rule) *)
  SymChunk   = 128;      (* symbols per chunk node (small-record rule) — MUST be a
                            power of two: index->(chunk,slot) uses LSR/AND, not
                            DIV/MOD, to stay off the slow path in the reloc loop *)
  SymShift   = 7;        (* LOG2(SymChunk): i DIV SymChunk = LSR(i, SymShift) *)
  SymMask    = 127;      (* SymChunk - 1: i MOD SymChunk = AND(i, SymMask) *)
  MaxSymChunk= 128;      (* directory size: up to MaxSymChunk*SymChunk symbols *)
  NoSym*     = 0FFFFH;    (* null symbol handle (WORD sentinel; valid idx 0..65534) *)
  DbgScopeChunk = 64;    (* SCOPE_RECORD entries per chunk node (small-record rule) *)
  DbgMaxProcDepth = 8;   (* max nested-procedure depth for scope tracking (matches Syms.MaxLevel) *)

TYPE
  Module* = POINTER TO ModRec;
  ModRec* = RECORD
    path:          ARRAY MaxPath OF CHAR;
    stem:          ARRAY 10 OF CHAR;  (* member basename w/o ".RDF" (<=8) — "" when
                                         no MODNAME.DBG can exist ($L extras etc.) *)
    hasDbg:        BOOLEAN;   (* non-empty MODNAME.DBG found (debug pass 1) *)
    dbgModName:    INTEGER;   (* pool ordinal of the module ident (M line) *)
    dbgSrcName:    INTEGER;   (* pool ordinal of the source file name (F line) *)
    dbgTypeBase:   WORD;      (* this module's local TYPE indices are offset by this *)
    dbgMembBase:   WORD;      (* this module's local MEMBER indices are offset by this *)
    libOfs:        LONGINT;
    rawSize:       LONGINT;
    hdrSize:       LONGINT;
    codeSize:      LONGINT;
    dataSize:      LONGINT;
    bssSize:       LONGINT;
    groupId:       INTEGER;
    codeFinalOfs:  LONGINT;   (* absolute byte offset in combined code space *)
    groupCodePara: INTEGER;   (* CS paragraph of the group (0-based from image start) *)
    groupCodeStart:LONGINT;   (* absolute byte offset of group start in code space *)
    dataFinalOfs:  LONGINT;
    bssFinalOfs:   LONGINT;
    used:          BOOLEAN;
    dup:           BOOLEAN;   (* TRUE if this .rdf was already linked from another .om *)
    nGlob:         INTEGER;   (* count of globals seen so far (for dup detection) *)
    next:          Module
  END;

  (* A Symbol is a WORD handle (index into the chunked symbol store), NOT a
     pointer — chunking requires index handles (Oberon can't point into an array).
     WORD is the fast unsigned type; NoSym (0FFFFH) is the null handle.  SymRec.owner
     stays a Module POINTER (modules are not chunked); next/hNext are index handles. *)
  Symbol* = WORD;
  SymRec = RECORD
    name:     ARRAY MaxName OF CHAR;
    hashCode: WORD;    (* Strings.HashCode(name), cached to speed FindSymbol *)
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

  (* Chunked MZ relocation list (small-record rule): seg/ofs are 2 bytes each,
     so one node per reloc would waste 16-byte headers; pack MZChunk per node.
     `w` stores the relocs already in MZ wire order — {ofs, seg} per reloc, i.e.
     w[2i]=ofs, w[2i+1]=seg — so the whole chunk spills to the .exe with a SINGLE
     BlockWrite (the in-memory WORD array is little-endian, matching the format). *)
  MZReloc* = POINTER TO MZRelocRec;
  MZRelocRec* = RECORD
    w:     ARRAY MZChunk * 2 OF WORD;
    count: INTEGER;     (* number of relocs (each uses 2 words of w) *)
    next:  MZReloc
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

  (* Group descriptor — one per .om group.  Chunked (small-record rule, GrpChunk
     per node): the fields are small and there is one per input group.  buf is a
     transient alias of ls^.codeBuf, live only while a group is processed. *)
  GrpEntry = RECORD
    groupId:    INTEGER;
    codePara:   WORD;
    codeStart:  LONGINT;
    codeLen:    LONGINT;
    buf:        Rdoff.SegBuf
  END;
  GroupNode = POINTER TO GroupNodeRec;
  GroupNodeRec = RECORD
    g:     ARRAY GrpChunk OF GrpEntry;
    count: INTEGER;
    next:  GroupNode
  END;

  (* Chunked TDS string pool (small-record rule).  Strings never span a chunk;
     on disk the chunks are written back-to-back, so the reader sees one
     contiguous NUL-separated pool.  Ordinals are 1-based string indices. *)
  PoolNode = POINTER TO PoolNodeRec;
  PoolNodeRec = RECORD
    bytes: ARRAY 2048 OF CHAR;
    used:  INTEGER;
    next:  PoolNode
  END;

  (* SCOPE_RECORD, built while pass 2 streams SYMBOL_RECORDs (a scope's
     sym_first/function are only known once those symbols are actually
     written), then emitted as array [5] after LINE_NUMBER records.  Chunked
     (small-record rule): one scope per procedure that has params/locals. *)
  ScopeNode = POINTER TO ScopeNodeDesc;
  ScopeNodeDesc = RECORD
    symFirst: ARRAY DbgScopeChunk OF WORD;
    symCnt:   ARRAY DbgScopeChunk OF WORD;
    func:     ARRAY DbgScopeChunk OF WORD;
    offset:   ARRAY DbgScopeChunk OF WORD;
    length:   ARRAY DbgScopeChunk OF WORD;
    count:    INTEGER;
    next:     ScopeNode
  END;

  State* = POINTER TO StateRec;
  StateRec* = RECORD
    genDebug*:    BOOLEAN;    (* /G: append the TDS debug block to the .exe *)
    dbgPool:      PoolNode;   (* TDS string pool chunks (head) *)
    dbgPoolTail:  PoolNode;
    dbgPoolBytes: LONGINT;    (* total pool bytes (names_pool_size) *)
    dbgNames:     INTEGER;    (* pool string count (names_count) *)
    dbgModCnt:    INTEGER;    (* modules contributing debug info *)
    dbgSymCnt:    WORD;       (* total S records *)
    dbgLineCnt:   WORD;       (* total L records *)
    dbgTypeCnt:   WORD;       (* total T records *)
    dbgMembCnt:   WORD;       (* total B records *)
    dbgScopeCnt:  WORD;       (* total scopes (one per proc with locals) *)
    dbgSymWritten:WORD;       (* running count of SYMBOL_RECORDs written so
                                 far in pass 2 — 1-based index of the NEXT
                                 symbol is dbgSymWritten+1 *)
    dbgScopeHead: ScopeNode;
    dbgScopeTail: ScopeNode;
    (* Procedure-nesting stack (small-record rule doesn't apply — fixed size,
       bounded by DbgMaxProcDepth, matches Syms.MaxLevel): a nested procedure's
       own 'P'/'A'/'E' lines appear INSIDE its enclosing procedure's stream
       (between the outer 'P' and the outer 'E'), so tracking "the most
       recent P" as flat scalars breaks as soon as any nesting occurs — the
       inner proc's context must be pushed/popped, not overwritten. *)
    dbgProcTop:     INTEGER;                        (* -1 = empty *)
    dbgProcSym:     ARRAY DbgMaxProcDepth OF WORD;   (* global 1-based sym index *)
    dbgProcOfs:     ARRAY DbgMaxProcDepth OF WORD;   (* rebased code offset *)
    dbgProcLocFirst:ARRAY DbgMaxProcDepth OF WORD;   (* first 'A' global idx for this level *)
    dbgProcLocCnt:  ARRAY DbgMaxProcDepth OF WORD;   (* 'A' count for this level *)
    dbgLocalTotal:  WORD;     (* running total of ALL 'A' symbols (header locals_count) *)
    modHead:      Module;
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
    relocHead:    MZReloc;
    relocTail:    MZReloc;
    mzRelocCnt:   WORD;
    groupHead:    GroupNode;
    groupTail:    GroupNode;
    dataBuf:      Rdoff.SegBuf;
    codeBuf:      Rdoff.SegBuf;  (* one reusable per-group code buffer, reserved
                                    up front so the fixed 65000-byte block is
                                    grabbed while the arena is still contiguous *)
    spillFile:    Files.File;   (* code spill: written then rewound + read; kept
                                   open the whole time (its content is destroyed
                                   on close, so it is never reopened by name) *)
    totalCodeLen: LONGINT;
    totalDataLen: LONGINT;
    totalBssLen:  LONGINT;
    entryIp:      INTEGER;
    entryCSPara:  INTEGER;
    stackSize:    LONGINT;
    nextGroupId:  INTEGER
  END;

(* Errors here are reached from deep helpers and FAR callbacks (OnImportForMark,
   OnReloc, ...) whose signatures are fixed.  They latch in module Err
   (Err.Error/Error2 — the single error state); the public link phases (called
   from TOC.LinkAll) check Err.HaveErr() after each step and TOC.Run is the sole
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
   and return its WORD index.  Latches Err.HaveErr() and returns NoSym if the store or
   directory is full. *)
PROCEDURE SymAlloc(ls: State): Symbol;
  VAR idx: Symbol; chunk, slot: WORD; node: SymNode;
BEGIN
  idx   := ls^.symCount;
  chunk := SYSTEM.LSR(idx, SymShift);
  slot  := SYSTEM.AND(idx, SymMask);
  IF chunk >= MaxSymChunk THEN Err.Error("Too many symbols"); RETURN NoSym END;
  IF slot = 0 THEN                       (* start of a new chunk — allocate it *)
    NEW(node);
    IF node = NIL THEN Err.Error("Out of memory (symbol chunk)"); RETURN NoSym END;
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
PROCEDURE SymOwner(ls: State; i: Symbol): Module;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].owner END SymOwner;

PROCEDURE SymSegId(ls: State; i: Symbol): INTEGER;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].segId END SymSegId;

PROCEDURE SymOffset(ls: State; i: Symbol): LONGINT;
BEGIN RETURN ls^.symDir[SYSTEM.LSR(i, SymShift)]^.s[SYSTEM.AND(i, SymMask)].offset END SymOffset;

PROCEDURE AddSymbol(ls: State; name: ARRAY OF CHAR; owner: Module;
                    segId: INTEGER; ofs: LONGINT);
  VAR sym: Symbol; slot, hc: WORD; node: SymNode;
BEGIN
  sym := SymAlloc(ls);
  IF sym = NoSym THEN RETURN END;
  hc := Strings.HashCode(name);
  node := SymNodeOf(ls, sym); slot := SYSTEM.AND(sym, SymMask);
  Strings.Copy(name, node^.s[slot].name);
  node^.s[slot].owner    := owner;
  node^.s[slot].segId    := segId;
  node^.s[slot].offset   := ofs;
  node^.s[slot].hashCode := hc;
  node^.s[slot].next     := ls^.symHead; ls^.symHead := sym;
  slot := SYSTEM.AND(hc, SymHash - 1);   (* reuse `slot` as the hash bucket *)
  node^.s[SYSTEM.AND(sym, SymMask)].hNext := ls^.symHash[slot];
  ls^.symHash[slot] := sym
END AddSymbol;

PROCEDURE FindSymbol*(ls: State; name: ARRAY OF CHAR): Symbol;
  VAR sym: Symbol; hc: WORD; node: SymNode; slot: WORD;
BEGIN
  hc := Strings.HashCode(name);
  sym := ls^.symHash[SYSTEM.AND(hc, SymHash - 1)];
  WHILE sym # NoSym DO
    node := SymNodeOf(ls, sym); slot := SYSTEM.AND(sym, SymMask);
    (* compare the cheap WORD hash first; only do the full Strings.Equal on a hash hit *)
    IF (node^.s[slot].hashCode = hc) & Strings.Equal(node^.s[slot].name, name) THEN
      RETURN sym
    END;
    sym := node^.s[slot].hNext
  END;
  RETURN NoSym
END FindSymbol;

(* ---- module list ---- *)

PROCEDURE NewModule(ls: State; path: ARRAY OF CHAR; libOfs: LONGINT;
                    groupId: INTEGER): Module;
  VAR m: Module;
BEGIN
  NEW(m);
  Strings.Copy(path, m^.path);
  m^.libOfs        := libOfs;
  m^.rawSize       := LONGINT(0);
  m^.hdrSize       := LONGINT(0);
  m^.codeSize      := LONGINT(0);
  m^.dataSize      := LONGINT(0);
  m^.bssSize       := LONGINT(0);
  m^.groupId       := groupId;
  m^.codeFinalOfs  := LONGINT(0);
  m^.groupCodePara := 0;
  m^.groupCodeStart:= LONGINT(0);
  m^.dataFinalOfs  := LONGINT(0);
  m^.bssFinalOfs   := LONGINT(0);
  m^.used          := FALSE;
  m^.dup           := FALSE;
  m^.nGlob         := 0;
  m^.stem[0]       := 0X;
  m^.hasDbg        := FALSE;
  m^.dbgModName    := 0;
  m^.dbgSrcName    := 0;
  m^.dbgTypeBase   := 0;
  m^.dbgMembBase   := 0;
  m^.next          := NIL;
  IF ls^.modTail = NIL THEN ls^.modHead := m
  ELSE ls^.modTail^.next := m
  END;
  ls^.modTail := m;
  RETURN m
END NewModule;

(* ---- MZ reloc list ---- *)

PROCEDURE AddReloc(ls: State; seg, ofs: WORD);
  VAR r: MZReloc; k: INTEGER;
BEGIN
  (* append to tail chunk; new chunk only when full *)
  IF (ls^.relocTail = NIL) OR (ls^.relocTail^.count >= MZChunk) THEN
    NEW(r); r^.count := 0; r^.next := NIL;
    IF ls^.relocHead = NIL THEN ls^.relocHead := r ELSE ls^.relocTail^.next := r END;
    ls^.relocTail := r
  END;
  r := ls^.relocTail; k := r^.count;
  r^.w[2*k] := ofs; r^.w[2*k + 1] := seg;   (* MZ wire order: ofs then seg *)
  INC(r^.count);
  INC(ls^.mzRelocCnt)
END AddReloc;

(* ---- state init ---- *)

PROCEDURE InitState*(ls: State);
  VAR i: INTEGER;
BEGIN
  ls^.modHead    := NIL; ls^.modTail    := NIL;
  ls^.symHead    := NoSym;
  ls^.symNodes   := NIL; ls^.symCount := 0;
  i := 0; WHILE i < MaxSymChunk DO ls^.symDir[i] := NIL; INC(i) END;
  i := 0; WHILE i < SymHash DO ls^.symHash[i] := NoSym; INC(i) END;
  ls^.relocHead  := NIL; ls^.relocTail  := NIL;
  ls^.mzRelocCnt := 0;
  ls^.groupHead  := NIL; ls^.groupTail  := NIL;
  ls^.dataBuf    := NIL;
  ls^.codeBuf    := NIL;
  ls^.totalCodeLen := LONGINT(0);
  ls^.totalDataLen := LONGINT(0);
  ls^.totalBssLen  := LONGINT(0);
  ls^.entryIp      := 0;
  ls^.entryCSPara  := 0;
  ls^.stackSize    := LONGINT(StackDef);
  ls^.nextGroupId  := 0;
  ls^.genDebug     := FALSE;
  ls^.dbgPool      := NIL; ls^.dbgPoolTail := NIL;
  ls^.dbgPoolBytes := LONGINT(0);
  ls^.dbgNames     := 0;  ls^.dbgModCnt := 0;
  ls^.dbgSymCnt    := 0;  ls^.dbgLineCnt := 0;
  ls^.dbgTypeCnt   := 0;  ls^.dbgMembCnt := 0;
  ls^.dbgScopeCnt  := 0;  ls^.dbgSymWritten := 0;
  ls^.dbgScopeHead := NIL; ls^.dbgScopeTail := NIL;
  ls^.dbgProcTop := -1; ls^.dbgLocalTotal := 0
END InitState;

(* Reserve the two large link buffers (data + one reusable per-group code
   buffer) BEFORE any module is scanned.  SegBuf is a fixed 65000-byte block; the
   symbol/module scan (each .rdf opened through an 8 KB Files buffer) fragments
   the arena so that no 65000-byte hole survives by link time.  Grabbing both
   here — while the arena is still one contiguous block — guarantees the fixed
   buffers exist; the later small allocations fill the remaining space and never
   need a large contiguous run.  Returns FALSE (latching Err.HaveErr()) if either
   allocation fails. *)
PROCEDURE ReserveBuffers*(ls: State): BOOLEAN;
BEGIN
  NEW(ls^.dataBuf);
  IF ls^.dataBuf = NIL THEN Err.Error("Out of memory (data buffer)"); RETURN FALSE END;
  NEW(ls^.codeBuf);
  IF ls^.codeBuf = NIL THEN Err.Error("Out of memory (code buffer)"); RETURN FALSE END;
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
    curMod^.dup := TRUE; RETURN
  END;
  INC(curMod^.nGlob);
  AddSymbol(curLs, name, curMod, seg, ofs)
END OnGlobal;

(* ---- scan a single .rdf inside an archive ---- *)

PROCEDURE ScanRdf(ls: State; path: ARRAY OF CHAR; libOfs: LONGINT; groupId: INTEGER;
                  member: ARRAY OF CHAR);
  VAR m: Module; i, dot: INTEGER; plain: BOOLEAN;
BEGIN
  m := NewModule(ls, path, libOfs, groupId);
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
  scanGrp:  INTEGER;
  scanLs:   State;

PROCEDURE OnMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
BEGIN
  ScanRdf(scanLs, scanPath, libOfs, scanGrp, name)
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
    scanGrp := ls^.nextGroupId;
    dummy := LONGINT(0);
    Tar.ScanTar(scanPath, OnMember, dummy, FALSE);
    INC(ls^.nextGroupId)
  ELSE
    Err.Error2("Unknown file format (must be .om): ", path)
  END
END ProcessFile;

(* ---- smart linking ---- *)

VAR
  markLs:     State;
  markErrbuf: ARRAY 256 OF CHAR;

PROCEDURE MarkModule(m: Module); FORWARD;

PROCEDURE OnImportForMark(flag: INTEGER; segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR sym: Symbol;
BEGIN
  sym := FindSymbol(markLs, name);
  IF sym = NoSym THEN
    Strings.Copy("Unresolved external: ", markErrbuf);
    Strings.Append(name, markErrbuf);
    Err.Error(markErrbuf); RETURN
  END;
  MarkModule(SymOwner(markLs, sym))
END OnImportForMark;

PROCEDURE MarkModule;
BEGIN
  IF ~m^.used THEN
    m^.used := TRUE;
    Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize,
                       OnImportForMark, NIL, NIL)
  END
END MarkModule;

PROCEDURE SmartLink*(ls: State);
  VAR sym: Symbol;
BEGIN
  markLs := ls;
  sym := FindSymbol(ls, "start");
  IF sym = NoSym THEN Err.Error("Entry point 'start' not found!"); RETURN END;
  MarkModule(SymOwner(ls, sym))
END SmartLink;

(* ---- layout ---- *)

PROCEDURE Align2(v: LONGINT): LONGINT;
BEGIN RETURN (v + LONGINT(1)) DIV LONGINT(2) * LONGINT(2) END Align2;

PROCEDURE Align16(v: LONGINT): LONGINT;
BEGIN RETURN (v + LONGINT(15)) DIV LONGINT(16) * LONGINT(16) END Align16;

PROCEDURE CalculateLayout*(ls: State);
  VAR m, n, prev, cur2, rHead, rTail: Module;
      codeBase, dataBase, bssBase: LONGINT;
      groupCodeStart: LONGINT;
      groupPara: INTEGER;
      curGroup: INTEGER;
      groupEnd: LONGINT;
      entrySym: Symbol;
      entryOwner: Module;
      entryGroup: INTEGER;
BEGIN
  (* Move entry group to front *)
  entrySym := FindSymbol(ls, "start");
  IF entrySym # NoSym THEN entryOwner := SymOwner(ls, entrySym) ELSE entryOwner := NIL END;
  IF entryOwner # NIL THEN
    entryGroup := entryOwner^.groupId;
    prev := NIL; cur2 := ls^.modHead;
    WHILE (cur2 # NIL) & (cur2^.groupId # entryGroup) DO
      prev := cur2; cur2 := cur2^.next
    END;
    IF (cur2 # NIL) & (prev # NIL) THEN
      rHead := cur2; rTail := cur2;
      WHILE (rTail^.next # NIL) & (rTail^.next^.groupId = entryGroup) DO
        rTail := rTail^.next
      END;
      prev^.next   := rTail^.next;
      rTail^.next  := ls^.modHead;
      ls^.modHead  := rHead
    END
  END;

  codeBase := LONGINT(0); dataBase := LONGINT(0); bssBase := LONGINT(0);
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used THEN
      codeBase       := Align16(codeBase);
      groupCodeStart := codeBase;
      groupPara      := INTEGER(groupCodeStart DIV LONGINT(16));
      curGroup       := m^.groupId;

      n := m;
      WHILE (n # NIL) & (n^.groupId = curGroup) DO
        IF n^.used THEN
          n^.codeFinalOfs   := codeBase;
          n^.groupCodePara  := groupPara;
          n^.groupCodeStart := groupCodeStart;
          codeBase := Align2(codeBase + n^.codeSize)
        END;
        n := n^.next
      END;
      groupEnd := codeBase;
      IF groupEnd - groupCodeStart > LONGINT(65000) THEN
        Err.Error("Code group exceeds 64KB")
      END;

      n := m;
      WHILE (n # NIL) & (n^.groupId = curGroup) DO
        IF n^.used THEN
          n^.dataFinalOfs := dataBase;
          n^.bssFinalOfs  := bssBase;
          dataBase := Align16(dataBase + n^.dataSize);
          bssBase  := Align16(bssBase  + n^.bssSize)
        END;
        n := n^.next
      END;

      WHILE (m # NIL) & (m^.groupId = curGroup) DO m := m^.next END
    ELSE
      m := m^.next
    END
  END;

  ls^.totalCodeLen := Align16(codeBase);
  ls^.totalDataLen := dataBase;
  ls^.totalBssLen  := bssBase;

  IF ls^.totalDataLen + ls^.totalBssLen > LONGINT(65520) THEN
    Err.Error("Data+BSS segment exceeds 64KB")
  END
END CalculateLayout;

(* ---- relocation ---- *)

VAR
  lnkLs:      State;
  lnkMod:     Module;
  lnkImports: ImportNode;
  lnkCodeBuf: Rdoff.SegBuf;
  lnkDataBuf: Rdoff.SegBuf;

PROCEDURE FindImport(id: INTEGER): Symbol;
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

(* Group-relative offset of m's code start within its group *)
PROCEDURE GroupOfs(m: Module): LONGINT;
BEGIN
  RETURN m^.codeFinalOfs - m^.groupCodeStart
END GroupOfs;

PROCEDURE PatchU16(buf: Rdoff.SegBuf; ofs: LONGINT; addend: WORD);
  VAR cur: WORD;
BEGIN
  cur := WORD(INTEGER(buf^[INTEGER(ofs)]) + SYSTEM.LSL(INTEGER(buf^[INTEGER(ofs)+1]), 8));
  cur := cur + addend;   (* 16-bit WORD arithmetic wraps mod 65536 *)
  buf^[INTEGER(ofs)]   := BYTE(SYSTEM.AND(cur, 0FFH));
  buf^[INTEGER(ofs)+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(cur, 8), 0FFH))
END PatchU16;

PROCEDURE PatchU8(buf: Rdoff.SegBuf; ofs: LONGINT; addend: WORD);
  VAR cur: WORD;
BEGIN
  cur := WORD(SYSTEM.AND(INTEGER(buf^[INTEGER(ofs)]) + INTEGER(addend), 0FFH));
  buf^[INTEGER(ofs)] := BYTE(cur)
END PatchU8;

(* Patch code or data buffer at group-relative/data offset. *)
PROCEDURE PatchBuf(rseg: INTEGER; bufOfs: LONGINT; addend: WORD; width: INTEGER);
BEGIN
  IF width = 2 THEN
    IF rseg = Rdoff.SegCode THEN PatchU16(lnkCodeBuf, bufOfs, addend)
    ELSE PatchU16(lnkDataBuf, bufOfs, addend)
    END
  ELSE
    IF rseg = Rdoff.SegCode THEN PatchU8(lnkCodeBuf, bufOfs, addend)
    ELSE PatchU8(lnkDataBuf, bufOfs, addend)
    END
  END
END PatchBuf;

PROCEDURE OnImportForLink(flag: INTEGER; segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR sym: Symbol; node: ImportNode; k: INTEGER;
BEGIN
  sym := FindSymbol(lnkLs, name);
  (* append to head chunk; new chunk only when the current head is full *)
  IF (lnkImports = NIL) OR (lnkImports^.count >= ImpChunk) THEN
    NEW(node); node^.count := 0; node^.next := lnkImports; lnkImports := node
  END;
  k := lnkImports^.count;
  lnkImports^.id[k]  := WORD(segId);
  lnkImports^.sym[k] := sym;
  INC(lnkImports^.count)
END OnImportForLink;

PROCEDURE OnReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                  rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR m, so: Module;
      sym: Symbol;
      fixup: WORD;      (* an absolute in-segment offset: 0..65535 -> WORD, not INTEGER *)
      patchAddr: WORD;  (* buffer offset — WORD to handle code offsets up to 64KB *)
BEGIN
  m := lnkMod;
  (* buffer-relative patch address *)
  IF rseg = Rdoff.SegCode THEN
    patchAddr := WORD(GroupOfs(m)) + WORD(rofs)
  ELSE
    patchAddr := WORD(m^.dataFinalOfs + rofs)
  END;

  (* Compute fixup addend.  All segment offsets are absolute positions inside a
     <= 64 KB segment, so they are WORD (0..65535); carrying them as INTEGER
     mis-handles any offset >= 32768 (negative) once it is sign-extended for the
     IP-relative subtraction below.  Differences (o1 - o2) are signed and done in
     WORD arithmetic (16-bit wraparound is exactly relative-addressing semantics). *)
  fixup := 0;
  IF rrefSeg = Rdoff.SegCode THEN
    IF rrel # 0 THEN
      (* IP-relative: absolute code offset of m within the combined code space,
         truncated to its 16-bit in-segment part. *)
      fixup := WORD(m^.codeFinalOfs)
    ELSE
      (* Non-relative FAR offset: group-relative offset *)
      fixup := WORD(GroupOfs(m))
    END
  ELSIF rrefSeg = Rdoff.SegData THEN
    fixup := WORD(m^.dataFinalOfs)
  ELSIF rrefSeg = Rdoff.SegBss THEN
    fixup := WORD(lnkLs^.totalDataLen + m^.bssFinalOfs)
  ELSE
    sym := FindImport(rrefSeg);
    IF sym = NoSym THEN Err.Error("Relocation to missing import"); RETURN END;
    so := SymOwner(lnkLs, sym);
    fixup := WORD(SymOffset(lnkLs, sym));
    IF SymSegId(lnkLs, sym) = 0 THEN
      IF rrel # 0 THEN
        fixup := fixup + WORD(so^.codeFinalOfs)
      ELSE
        fixup := fixup + WORD(GroupOfs(so))
      END
    ELSIF SymSegId(lnkLs, sym) = 1 THEN
      fixup := fixup + WORD(so^.dataFinalOfs)
    ELSE
      fixup := WORD(lnkLs^.totalDataLen + so^.bssFinalOfs + SymOffset(lnkLs, sym))
    END
  END;

  IF rrel # 0 THEN
    (* IP-relative: subtract absolute offset of the byte after the patch field.
       For code: absolute = groupCodeStart + patchAddr; for data: patchAddr is
       absolute.  Done in WORD: the result is a signed disp held in 16 bits. *)
    IF rseg = Rdoff.SegCode THEN
      fixup := fixup - (WORD(m^.groupCodeStart) + patchAddr + WORD(rwidth))
    ELSE
      fixup := fixup - (patchAddr + WORD(rwidth))
    END
  END;

  PatchBuf(rseg, patchAddr, fixup, rwidth)
END OnReloc;

PROCEDURE OnSegReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                     rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR m, so: Module;
      sym: Symbol;
      fixup: WORD;      (* a segment paragraph value: WORD, not INTEGER *)
      patchAddr: WORD;
      mzSeg, mzOfs: WORD;   (* MZ reloc seg:ofs — absolute values -> WORD *)
BEGIN
  m := lnkMod;
  IF rseg = Rdoff.SegCode THEN
    patchAddr := WORD(GroupOfs(m)) + WORD(rofs)
  ELSE
    patchAddr := WORD(m^.dataFinalOfs + rofs)
  END;

  fixup := 0;
  IF rrefSeg = Rdoff.SegCode THEN
    fixup := m^.groupCodePara
  ELSIF (rrefSeg = Rdoff.SegData) OR (rrefSeg = Rdoff.SegBss) THEN
    fixup := WORD(lnkLs^.totalCodeLen DIV LONGINT(16))
  ELSE
    sym := FindImport(rrefSeg);
    IF sym # NoSym THEN
      IF SymSegId(lnkLs, sym) = 0 THEN
        so := SymOwner(lnkLs, sym); fixup := so^.groupCodePara
      ELSE fixup := WORD(lnkLs^.totalCodeLen DIV LONGINT(16))
      END
    END
  END;

  PatchBuf(rseg, patchAddr, fixup, 2);

  (* add MZ reloc entry (offset in load image, 0-based from image start) *)
  IF rseg = Rdoff.SegCode THEN
    mzSeg := m^.groupCodePara;
    mzOfs := WORD(GroupOfs(m)) + WORD(rofs)
  ELSE
    mzSeg := WORD(lnkLs^.totalCodeLen DIV LONGINT(16));
    mzOfs := WORD(m^.dataFinalOfs + rofs)
  END;
  AddReloc(lnkLs, mzSeg, mzOfs)
END OnSegReloc;

(* ---- find or create group node ---- *)

(* Compute the exact byte length of the code group with groupId=gid.
   Walks every used Module in the link with that id and takes the maximum
   of (GroupOfs(m) + m.codeSize).  Used to size the group's code buffer
   so we don't reserve 65 KB per group on small programs. *)
PROCEDURE ComputeGroupCodeLen(ls: State; gid: INTEGER): LONGINT;
  VAR m: Module; ofs, codeLen: LONGINT;
BEGIN
  codeLen := LONGINT(0);
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & (m^.groupId = gid) & (m^.codeSize > LONGINT(0)) THEN
      ofs := m^.codeFinalOfs - m^.groupCodeStart + m^.codeSize;
      IF ofs > codeLen THEN codeLen := ofs END
    END;
    m := m^.next
  END;
  RETURN codeLen
END ComputeGroupCodeLen;

(* Find or create the group descriptor for m's groupId, returned as (node, slot)
   into the chunked group store.  No code buffer is set here — buffers are the
   single reusable ls^.codeBuf, aliased transiently in ProcessGroup. *)
PROCEDURE FindOrCreateGroup(ls: State; m: Module; VAR node: GroupNode; VAR slot: INTEGER);
  VAR p: GroupNode; k: INTEGER;
BEGIN
  p := ls^.groupHead;
  WHILE p # NIL DO
    k := 0;
    WHILE k < p^.count DO
      IF p^.g[k].groupId = m^.groupId THEN node := p; slot := k; RETURN END;
      INC(k)
    END;
    p := p^.next
  END;
  (* not found — append a fresh entry to the tail chunk *)
  IF (ls^.groupTail = NIL) OR (ls^.groupTail^.count >= GrpChunk) THEN
    NEW(p); p^.count := 0; p^.next := NIL;
    IF ls^.groupHead = NIL THEN ls^.groupHead := p ELSE ls^.groupTail^.next := p END;
    ls^.groupTail := p
  END;
  p := ls^.groupTail; k := p^.count;
  p^.g[k].groupId   := m^.groupId;
  p^.g[k].codePara  := m^.groupCodePara;
  p^.g[k].codeStart := m^.groupCodeStart;
  p^.g[k].codeLen   := ComputeGroupCodeLen(ls, m^.groupId);
  p^.g[k].buf       := NIL;
  INC(p^.count);
  node := p; slot := k
END FindOrCreateGroup;

(* ---- perform all linking (fill buffers, apply relocs, build MZ reloc list) ---- *)

(* Process one code group: allocate a transient buffer sized to the group,
   load every member module's code into it, apply that group's relocations
   (RELOC + SEGRELOC, building the MZ reloc list), spill the relocated bytes to
   the temp code file at the group's image offset, then free the buffer.
   Only one group buffer is ever resident, so peak code heap is <= one group
   (<= 64 KB) regardless of total program size. *)
(* ftmp is written strictly sequentially; pos is the next byte offset.  Pads
   the gap from pos up to the group's codeStart with zeros (inter-group 16-byte
   alignment) before writing the group, so we never rely on seek-past-EOF
   zero-filling (which xt's DOS does not do).  pos is advanced past the group. *)
PROCEDURE ProcessGroup(ls: State; node: GroupNode; slot: INTEGER;
                       VAR ftmp: Files.File; VAR pos: LONGINT);
  VAR m: Module; sz, k: WORD; gid: INTEGER; codeStart, codeLen: LONGINT;
      padBuf: ARRAY 16 OF BYTE; padLen: WORD;
BEGIN
  gid       := node^.g[slot].groupId;
  codeStart := node^.g[slot].codeStart;
  codeLen   := node^.g[slot].codeLen;
  sz := codeLen;
  IF sz < LONGINT(1) THEN RETURN END;
  (* pad to the group's image offset: at most 15 bytes (16-byte alignment),
     so one small block write replaces the former 1-byte-at-a-time loop. *)
  IF pos < codeStart THEN
    padLen := WORD(codeStart - pos);
    SYSTEM.FILL(padBuf, 16, 0);
    IF Files.BlockWrite(ftmp, padBuf, padLen) # padLen THEN
      Err.Error("Write error (code pad)")
    END;
    pos := codeStart
  END;
  (* Reuse the single pre-reserved code buffer (ReserveBuffers) — groups are
     processed one at a time, so one 65000-byte buffer serves them all and no
     large contiguous allocation is needed at this fragmented point. *)
  node^.g[slot].buf := ls^.codeBuf;
  (* explicit indexed loop, NOT SYSTEM.FILL: a far-heap SegBuf zeroed via
     SYSTEM.FILL previously mis-addressed (see implementation-rules.md
     §"Reusing one shared code buffer") — reverted, do not retry. *)
  k := 0; WHILE k < sz DO ls^.codeBuf^[k] := BYTE(0); INC(k) END;

  (* load member code into the group buffer *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & (m^.groupId = gid) & (m^.codeSize > LONGINT(0)) THEN
      Rdoff.ReadCode(m^.path, m^.libOfs, m^.hdrSize,
                       ls^.codeBuf, WORD(GroupOfs(m)), WORD(m^.codeSize))
    END;
    m := m^.next
  END;

  (* apply this group's relocations *)
  lnkCodeBuf := ls^.codeBuf;
  lnkDataBuf := ls^.dataBuf;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & (m^.groupId = gid) THEN
      lnkMod      := m;
      FreeImports;
      (* Pass 1: collect IMPORT records first (RELOCs may precede them). *)
      Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, OnImportForLink, NIL, NIL);
      (* Pass 2: apply RELOC and SEGRELOC records. *)
      Rdoff.ScanRelocs(m^.path, m^.libOfs, m^.hdrSize, NIL, OnReloc, OnSegReloc)
    END;
    m := m^.next
  END;

  FreeImports;   (* release this group's last module IMPORT chain *)

  (* spill the relocated group sequentially *)
  IF Files.BlockWrite(ftmp, ls^.codeBuf^[0], WORD(sz)) # WORD(sz) THEN
    Err.Error("Write error (code spill)")
  END;
  (* advance pos by the group's LONGINT codeLen — NOT `pos + sz`: sz is a WORD
     and WORD->LONGINT widening sign-extends (a 37 KB group reads as negative),
     which corrupted the spilled layout for any group >= 32 KB (e.g. the
     compiler's own largest code group). *)
  pos := pos + codeLen;
  node^.g[slot].buf := NIL   (* drop the alias; ls^.codeBuf is freed in LinkFree *)
END ProcessGroup;

PROCEDURE PerformLinking*(ls: State);
  VAR m, eso: Module; g: GroupNode; gslot: INTEGER;
      esym: Symbol; sz, k, pos: LONGINT;
BEGIN
  (* Data buffer (one resident segment, <= 64 KB) — reserved up front by
     ReserveBuffers while the arena was contiguous; here we only zero the used
     span. *)
  sz := ls^.totalDataLen;
  IF sz < LONGINT(1) THEN sz := LONGINT(1) END;
  (* explicit indexed loop, NOT SYSTEM.FILL: dataBuf is the same far-heap
     SegBuf type that mis-addressed under SYSTEM.FILL before (see
     implementation-rules.md §"Reusing one shared code buffer"). *)
  k := LONGINT(0); WHILE k < sz DO ls^.dataBuf^[INTEGER(k)] := BYTE(0); INC(k) END;

  (* Load all data segments (data is one combined <= 64 KB buffer). *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used THEN
      FindOrCreateGroup(ls, m, g, gslot);   (* build group descriptors *)
      IF m^.dataSize > LONGINT(0) THEN
        Rdoff.ReadData(m^.path, m^.libOfs, m^.hdrSize,
                         ls^.dataBuf, WORD(m^.dataFinalOfs), WORD(m^.dataSize))
      END
    END;
    m := m^.next
  END;

  (* Stream the code: process each group transiently into the spill file,
     writing strictly sequentially (pos tracks the next byte). *)
  lnkLs := ls;
  IF ~Files.ReWriteTemp(ls^.spillFile) THEN Err.Error("Cannot create code temp"); RETURN END;
  pos := LONGINT(0);
  g := ls^.groupHead;
  WHILE (g # NIL) & ~Err.HaveErr() DO
    gslot := 0;
    WHILE (gslot < g^.count) & ~Err.HaveErr() DO
      ProcessGroup(ls, g, gslot, ls^.spillFile, pos); INC(gslot)
    END;
    g := g^.next
  END;
  (* Rewind for reading — keep the file open; closing now would destroy its
     content (delete-on-close) before CopyCodeImage can read it. *)
  Files.Seek(ls^.spillFile, LONGINT(0));

  (* Resolve entry point. *)
  esym := FindSymbol(ls, "start");
  IF esym # NoSym THEN
    eso := SymOwner(ls, esym);
    ls^.entryIp      := GroupOfs(eso) + INTEGER(SymOffset(ls, esym));
    ls^.entryCSPara  := eso^.groupCodePara
  END
END PerformLinking;

(* ---- TDS/TDINFO debug block (/G) ----

   Merges the MODNAME.DBG text members of the used modules into one binary
   TDS v2.08 block appended after the data image (dbg.md §5; layouts per
   docs/td-spec.md §EMPIRICAL: 48-byte header w/ reserved[14],
   SOURCE_FILE = name+time+date, LINE = (line, offset) — line word FIRST,
   one CORRELATION per module).  No MZ header field changes and no MZ relocs
   (model B) — without /G the .exe is byte-identical.

   Memory strategy: NO record tables are built.  Each module's .DBG is
   extracted (TarExtract → temp) once per pass — pass 1 counts records and
   interns names into the chunked string pool; passes 2/3 stream the symbol
   and line arrays straight to the output file.  Only the string pool lives
   in the heap (chunked, deduplicated, freed in LinkFree). *)

(* Find name in the chunked pool or append it; returns the 1-based string
   ordinal (TDS pool indices are ordinals, not byte offsets). *)
PROCEDURE DbgIntern(ls: State; VAR name: ARRAY OF CHAR): INTEGER;
  VAR p: PoolNode; i, j, k, ord, len: INTEGER; match: BOOLEAN;
BEGIN
  ord := 1;
  p := ls^.dbgPool;
  WHILE p # NIL DO
    i := 0;
    WHILE i < p^.used DO
      k := i; j := 0; match := TRUE;
      WHILE match & (p^.bytes[k] # 0X) & (name[j] # 0X) DO
        IF p^.bytes[k] # name[j] THEN match := FALSE ELSE INC(k); INC(j) END
      END;
      IF match & (p^.bytes[k] = 0X) & (name[j] = 0X) THEN RETURN ord END;
      WHILE p^.bytes[k] # 0X DO INC(k) END;   (* skip to end of pool string *)
      i := k + 1; INC(ord)
    END;
    p := p^.next
  END;
  (* not found: append (strings never span a chunk) *)
  len := 0; WHILE name[len] # 0X DO INC(len) END;
  IF (ls^.dbgPoolTail = NIL) OR (ls^.dbgPoolTail^.used + len + 1 > 2048) THEN
    NEW(p); p^.used := 0; p^.next := NIL;
    IF ls^.dbgPoolTail = NIL THEN ls^.dbgPool := p ELSE ls^.dbgPoolTail^.next := p END;
    ls^.dbgPoolTail := p
  END;
  p := ls^.dbgPoolTail;
  k := 0;
  WHILE k <= len DO p^.bytes[p^.used] := name[k]; INC(p^.used); INC(k) END;
  ls^.dbgPoolBytes := ls^.dbgPoolBytes + LONGINT(len + 1);
  INC(ls^.dbgNames);
  RETURN ls^.dbgNames
END DbgIntern;

(* Read one CRLF/LF-terminated line from f; FALSE at EOF. *)
PROCEDURE DbgReadLine(VAR f: Files.File; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR b: BYTE; k: INTEGER; more: BOOLEAN;
BEGIN
  k := 0;
  more := Files.ReadByte(f, b);
  IF ~more THEN s[0] := 0X; RETURN FALSE END;
  WHILE more & (b # BYTE(10)) DO
    IF (b # BYTE(13)) & (k < LEN(s) - 1) THEN s[k] := CHR(b); INC(k) END;
    more := Files.ReadByte(f, b)
  END;
  s[k] := 0X;
  RETURN TRUE
END DbgReadLine;

(* Fixed-width 4-digit uppercase hex at s[p] (TDbg offset format). *)
PROCEDURE DbgHex4(VAR s: ARRAY OF CHAR; p: INTEGER): WORD;
  VAR v: WORD; k, d: INTEGER; c: CHAR;
BEGIN
  v := 0; k := 0;
  WHILE k < 4 DO
    c := s[p + k];
    IF (c >= "0") & (c <= "9") THEN d := ORD(c) - ORD("0")
    ELSE d := ORD(c) - ORD("A") + 10 END;
    v := v * 16 + WORD(d);
    INC(k)
  END;
  RETURN v
END DbgHex4;

(* Decimal number at s[p]. *)
PROCEDURE DbgDec(VAR s: ARRAY OF CHAR; p: INTEGER): INTEGER;
  VAR v: INTEGER;
BEGIN
  v := 0;
  WHILE (s[p] >= "0") & (s[p] <= "9") DO
    v := v * 10 + (ORD(s[p]) - ORD("0"));
    INC(p)
  END;
  RETURN v
END DbgDec;

PROCEDURE DbgNameAt(VAR s: ARRAY OF CHAR; p: INTEGER; VAR nm: ARRAY OF CHAR);
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE (s[p] # 0X) & (k < LEN(nm) - 1) DO nm[k] := s[p]; INC(k); INC(p) END;
  nm[k] := 0X
END DbgNameAt;

(* Append one SCOPE_RECORD (small-record chunked table, flushed as array [5]
   after LINE_NUMBER records in WriteDebugInfo). *)
PROCEDURE AddScope(ls: State; symFirst, symCnt, func, offset, length: WORD);
  VAR n: ScopeNode;
BEGIN
  IF (ls^.dbgScopeTail = NIL) OR (ls^.dbgScopeTail^.count = DbgScopeChunk) THEN
    NEW(n); n^.count := 0; n^.next := NIL;
    IF ls^.dbgScopeTail # NIL THEN ls^.dbgScopeTail^.next := n ELSE ls^.dbgScopeHead := n END;
    ls^.dbgScopeTail := n
  END;
  ls^.dbgScopeTail^.symFirst[ls^.dbgScopeTail^.count] := symFirst;
  ls^.dbgScopeTail^.symCnt[ls^.dbgScopeTail^.count]   := symCnt;
  ls^.dbgScopeTail^.func[ls^.dbgScopeTail^.count]     := func;
  ls^.dbgScopeTail^.offset[ls^.dbgScopeTail^.count]   := offset;
  ls^.dbgScopeTail^.length[ls^.dbgScopeTail^.count]   := length;
  INC(ls^.dbgScopeTail^.count);
  INC(ls^.dbgScopeCnt)
END AddScope;

(* One streaming pass over module m's MODNAME.DBG member (absent or 0-byte
   member = module contributes nothing).  .DBG line columns are fixed:
     S c XXXX s YYYY name  (c: P/V/Y/A; XXXX: hex4 offset (signed bit-pattern
                            for A); s: C/D/-; YYYY: hex4 local TYPE index)
     S E LLLL - 0000       (scope-end marker, NOT a real symbol; LLLL = the
                            most recent P's own code length)
     T II SSSS CC MMMM name|-  (II: hex4 TD type-id; SSSS: hex4 size;
                                 CC: hex4 class_type; MMMM: hex4 member_type)
     B II TTTT name            (II: hex4 info; TTTT: hex4 field TYPE index)
     L XXXX nnn        (hex4 code offset; decimal line)
     M name / F name / C nnn / D 1
   pass 1: count records + intern names + set m^.hasDbg/dbgModName/dbgSrcName/
           dbgTypeBase/dbgMembBase (bases are running totals BEFORE this
           module's own T/B records, so pass 1 must run in module order and
           read the previous totals before adding this module's counts).
           'E' lines do not count as symbols.
   pass 2: write SYMBOL_RECORDs (rebased) to fout; build SCOPE_RECORDs (needs
           the just-written global index of each 'P'/'A' symbol, and the
           preceding 'P' to close on 'E' — so scopes can only be built here,
           not in a later pass).
   pass 3: write LINE_NUMBER_RECORDs — (line, offset), line word FIRST.
   pass 4: write TYPE_RECORDs (rebased member_type).
   pass 5: write MEMBER_RECORDs (rebased type). *)
PROCEDURE DbgPass(ls: State; m: Module; pass: INTEGER; VAR fout: Files.File);
  VAR f: Files.File;
      s: ARRAY 96 OF CHAR;
      memb: ARRAY 14 OF CHAR;
      nm: ARRAY 40 OF CHAR;
      offw, segw, typw: WORD;
      any: BOOLEAN;
BEGIN
  IF m^.stem[0] = 0X THEN RETURN END;
  Strings.Copy(m^.stem, memb); Strings.Append(".DBG", memb);
  IF ~Tar.TarExtract(m^.path, memb, f) THEN RETURN END;
  any := FALSE;
  IF pass = 1 THEN m^.dbgTypeBase := ls^.dbgTypeCnt; m^.dbgMembBase := ls^.dbgMembCnt END;
  IF (pass = 1) OR (pass = 2) THEN ls^.dbgProcTop := -1 END;
  WHILE DbgReadLine(f, s) DO
    IF (s[0] = "S") & (s[2] = "E") THEN
      (* close the innermost open 'P' scope (nested procedures push/pop a
         stack frame — a nested proc's own P..E fully nests inside its
         enclosing proc's P..E in the .DBG stream, so "the most recent P"
         must be a stack top, not a flat scalar, or an inner proc's context
         clobbers the outer one's before the outer 'E' is reached).
         A SCOPE_RECORD is only produced if the frame collected at least one
         local/param (matches how real TLINK skips empty scopes — verified:
         probe has no zero-local scope entries).  Counted in pass 1 (header
         needs scopes_count before pass 2 runs); built in pass 2 once symbol
         indices are known. *)
      IF ls^.dbgProcTop >= 0 THEN
        IF pass = 1 THEN
          IF ls^.dbgProcLocCnt[ls^.dbgProcTop] > 0 THEN INC(ls^.dbgScopeCnt) END
        ELSIF pass = 2 THEN
          IF ls^.dbgProcLocCnt[ls^.dbgProcTop] > 0 THEN
            AddScope(ls, ls^.dbgProcLocFirst[ls^.dbgProcTop], ls^.dbgProcLocCnt[ls^.dbgProcTop],
                     ls^.dbgProcSym[ls^.dbgProcTop], ls^.dbgProcOfs[ls^.dbgProcTop], DbgHex4(s, 4))
          END
        END;
        DEC(ls^.dbgProcTop)
      END
    ELSIF s[0] = "S" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 16, nm);
        DbgIntern(ls, nm);          (* result discarded: intern only *)
        INC(ls^.dbgSymCnt); any := TRUE;
        IF s[2] = "P" THEN
          IF ls^.dbgProcTop < DbgMaxProcDepth - 1 THEN INC(ls^.dbgProcTop) END;
          ls^.dbgProcLocCnt[ls^.dbgProcTop] := 0
        ELSIF s[2] = "A" THEN
          INC(ls^.dbgLocalTotal);
          IF ls^.dbgProcTop >= 0 THEN INC(ls^.dbgProcLocCnt[ls^.dbgProcTop]) END
        END
      ELSIF pass = 2 THEN
        DbgNameAt(s, 16, nm);
        Files.WriteWord(fout, DbgIntern(ls, nm));       (* name index (hit) *)
        typw := DbgHex4(s, 11);
        IF typw # 0 THEN typw := typw + m^.dbgTypeBase END;
        Files.WriteWord(fout, INTEGER(typw));
        offw := DbgHex4(s, 4);
        IF s[2] = "P" THEN                              (* proc: code seg *)
          offw := WORD(GroupOfs(m) + LONGINT(offw));
          segw := WORD(m^.groupCodePara)
        ELSIF (s[2] = "Y") OR (s[2] = "A") THEN
          (* typedef: no location.  local/param: offw is a signed BP offset,
             already correct as-is — no code/data rebasing. *)
          IF s[2] = "Y" THEN offw := 0 END;
          segw := 0
        ELSE                                            (* global VAR: data *)
          offw := WORD(m^.dataFinalOfs + LONGINT(offw));
          segw := WORD(ls^.totalCodeLen DIV LONGINT(16))
        END;
        Files.WriteWord(fout, INTEGER(offw));
        Files.WriteWord(fout, INTEGER(segw));
        INC(ls^.dbgSymWritten);
        IF s[2] = "Y" THEN Files.WriteByte(fout, BYTE(6))     (* TYPEDEF *)
        ELSIF s[2] = "A" THEN
          Files.WriteByte(fout, BYTE(2));                     (* AUTO *)
          IF ls^.dbgProcTop >= 0 THEN
            IF ls^.dbgProcLocCnt[ls^.dbgProcTop] = 0 THEN
              ls^.dbgProcLocFirst[ls^.dbgProcTop] := ls^.dbgSymWritten
            END;
            INC(ls^.dbgProcLocCnt[ls^.dbgProcTop])
          END
        ELSE
          Files.WriteByte(fout, BYTE(0));                     (* STATIC *)
          IF s[2] = "P" THEN
            IF ls^.dbgProcTop < DbgMaxProcDepth - 1 THEN INC(ls^.dbgProcTop) END;
            ls^.dbgProcSym[ls^.dbgProcTop] := ls^.dbgSymWritten;
            ls^.dbgProcOfs[ls^.dbgProcTop] := offw;
            ls^.dbgProcLocCnt[ls^.dbgProcTop] := 0
          END
        END
      END
    ELSIF s[0] = "L" THEN
      IF pass = 1 THEN INC(ls^.dbgLineCnt); any := TRUE
      ELSIF pass = 3 THEN
        Files.WriteWord(fout, DbgDec(s, 7));            (* line FIRST *)
        offw := WORD(GroupOfs(m) + LONGINT(DbgHex4(s, 2)));
        Files.WriteWord(fout, INTEGER(offw))
      END
    ELSIF s[0] = "T" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 22, nm);
        IF nm[0] # "-" THEN DbgIntern(ls, nm) END;   (* intern now: header pool size is snapshotted right after pass 1 *)
        INC(ls^.dbgTypeCnt); any := TRUE
      ELSIF pass = 4 THEN
        (* TYPE_RECORD wire order (docs/tdinfo.c, packed 8 bytes):
           id(1), name(2), size(2), class_type(1), member_type(2). *)
        DbgNameAt(s, 22, nm);
        Files.WriteByte(fout, BYTE(DbgHex4(s, 2)));       (* id *)
        IF nm[0] = "-" THEN Files.WriteWord(fout, 0)
        ELSE Files.WriteWord(fout, DbgIntern(ls, nm)) END; (* name *)
        Files.WriteWord(fout, INTEGER(DbgHex4(s, 7)));    (* size *)
        Files.WriteByte(fout, BYTE(DbgHex4(s, 12)));       (* class_type *)
        typw := DbgHex4(s, 17);                            (* member_type *)
        IF typw # 0 THEN
          (* STRUCT's member_type indexes MEMBER_RECORD; everything else
             (ARRAY elem / POINTER target) indexes TYPE_RECORD.  id 30=STRUCT. *)
          IF DbgHex4(s, 2) = WORD(30) THEN typw := typw + m^.dbgMembBase
          ELSE typw := typw + m^.dbgTypeBase END
        END;
        Files.WriteWord(fout, INTEGER(typw))
      END
    ELSIF s[0] = "B" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 12, nm);
        DbgIntern(ls, nm);          (* result discarded: intern only *)
        INC(ls^.dbgMembCnt); any := TRUE
      ELSIF pass = 5 THEN
        (* MEMBER_RECORD wire order (docs/tdinfo.c, packed 5 bytes):
           info(1), name(2), type(2). *)
        DbgNameAt(s, 12, nm);
        Files.WriteByte(fout, BYTE(DbgHex4(s, 2)));       (* info *)
        Files.WriteWord(fout, DbgIntern(ls, nm));          (* name *)
        typw := DbgHex4(s, 7);
        IF typw # 0 THEN typw := typw + m^.dbgTypeBase END;
        Files.WriteWord(fout, INTEGER(typw))               (* type *)
      END
    ELSIF s[0] = "M" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 2, nm); m^.dbgModName := DbgIntern(ls, nm); any := TRUE
      END
    ELSIF s[0] = "F" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 2, nm); m^.dbgSrcName := DbgIntern(ls, nm); any := TRUE
      END
    END
    (* "D" (version) and "C" (code length) lines are ignored: m^.codeSize from
       the RDOFF header is authoritative for the SEGMENT record. *)
  END;
  Files.Close(f);
  IF (pass = 1) & any THEN m^.hasDbg := TRUE; INC(ls^.dbgModCnt) END
END DbgPass;

(* Append the merged TDS block to fout (which is positioned right after the
   data image).  Pure append: no MZ header field and no relocation changes, so
   without /G the output is byte-identical (immediate RETURN). *)
PROCEDURE WriteDebugInfo(ls: State; VAR fout: Files.File);
  VAR m: Module; p: PoolNode; i, k, j: INTEGER; scNode: ScopeNode;
BEGIN
  IF ~ls^.genDebug THEN RETURN END;

  (* pass 1: counts + string pool + per-module name ordinals *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & ~m^.dup THEN DbgPass(ls, m, 1, fout) END;
    m := m^.next
  END;
  IF ls^.dbgModCnt = 0 THEN RETURN END;    (* no $D+ module linked: no block *)

  (* TDINFO_HEADER — 48 bytes: magic, ver 2.08, pool size, 12 counts,
     reserved[14], extension_size=0 *)
  Files.WriteWord(fout, 052FBH);
  Files.WriteByte(fout, BYTE(8));                  (* minor *)
  Files.WriteByte(fout, BYTE(2));                  (* major *)
  Files.WriteDWord(fout, ls^.dbgPoolBytes);
  Files.WriteWord(fout, ls^.dbgNames);             (* names_count *)
  Files.WriteWord(fout, INTEGER(ls^.dbgTypeCnt));  (* types *)
  Files.WriteWord(fout, INTEGER(ls^.dbgMembCnt));  (* members *)
  Files.WriteWord(fout, INTEGER(ls^.dbgSymCnt));   (* symbols *)
  Files.WriteWord(fout, 0);                        (* globals *)
  Files.WriteWord(fout, ls^.dbgModCnt);            (* modules *)
  Files.WriteWord(fout, INTEGER(ls^.dbgLocalTotal));(* locals (informational) *)
  Files.WriteWord(fout, INTEGER(ls^.dbgScopeCnt)); (* scopes *)
  Files.WriteWord(fout, INTEGER(ls^.dbgLineCnt));  (* line numbers *)
  Files.WriteWord(fout, ls^.dbgModCnt);            (* source files *)
  Files.WriteWord(fout, ls^.dbgModCnt);            (* segments *)
  Files.WriteWord(fout, ls^.dbgModCnt);            (* correlations *)
  k := 0; WHILE k < 14 DO Files.WriteByte(fout, BYTE(0)); INC(k) END;
  Files.WriteWord(fout, 0);                        (* extension_size *)

  (* [1] SYMBOL_RECORDs *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ls, m, 2, fout) END;
    m := m^.next
  END;

  (* [2] MODULE_RECORDs: name + 14 zero bytes *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, m^.dbgModName);
      k := 0; WHILE k < 14 DO Files.WriteByte(fout, BYTE(0)); INC(k) END
    END;
    m := m^.next
  END;

  (* [3] SOURCE_FILE records: name index + DOS time/date (0 in Phase 1) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, m^.dbgSrcName);
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0)
    END;
    m := m^.next
  END;

  (* [4] LINE_NUMBER records *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ls, m, 3, fout) END;
    m := m^.next
  END;

  (* [5] SCOPE_RECORDs — built in RAM during pass 2 (small: one per procedure
     with locals/params), so just stream the chunk list; no extra DbgPass. *)
  scNode := ls^.dbgScopeHead;
  WHILE scNode # NIL DO
    j := 0;
    WHILE j < scNode^.count DO
      Files.WriteWord(fout, INTEGER(scNode^.symFirst[j]));
      Files.WriteWord(fout, INTEGER(scNode^.symCnt[j]));
      Files.WriteWord(fout, 0);                        (* parent: none (flat scopes) *)
      Files.WriteWord(fout, INTEGER(scNode^.func[j]));
      Files.WriteWord(fout, INTEGER(scNode^.offset[j]));
      Files.WriteWord(fout, INTEGER(scNode^.length[j]));
      INC(j)
    END;
    scNode := scNode^.next
  END;

  (* [6] SEGMENT records: one per module — the module's slice of its group *)
  i := 1;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, i);                          (* module (1-based) *)
      Files.WriteWord(fout, m^.groupCodePara);           (* code_segment *)
      Files.WriteWord(fout, INTEGER(GroupOfs(m)));       (* code_offset *)
      Files.WriteWord(fout, INTEGER(m^.codeSize));       (* code_length *)
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0);(* scope idx/cnt *)
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0);(* 4 pad bytes *)
      INC(i)
    END;
    m := m^.next
  END;

  (* [7] CORRELATION records: srcfile i <-> segment i <-> module i *)
  i := 1;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, i); Files.WriteWord(fout, i);
      Files.WriteWord(fout, i); Files.WriteWord(fout, 0007H);
      INC(i)
    END;
    m := m^.next
  END;

  (* [8] TYPE_RECORDs (rebased member_type) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ls, m, 4, fout) END;
    m := m^.next
  END;

  (* [9] MEMBER_RECORDs (rebased type) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ls, m, 5, fout) END;
    m := m^.next
  END;

  (* [10] string pool — chunks written back-to-back *)
  p := ls^.dbgPool;
  WHILE p # NIL DO
    IF p^.used > 0 THEN
      IF Files.BlockWrite(fout, p^.bytes[0], WORD(p^.used)) # WORD(p^.used) THEN
        Err.Error("Write error (debug pool)")
      END
    END;
    p := p^.next
  END
END WriteDebugInfo;

(* ---- write MZ EXE ---- *)

PROCEDURE WriteZeros(VAR f: Files.File; n: LONGINT);
  VAR buf: ARRAY 128 OF BYTE; chunk: WORD;
BEGIN
  SYSTEM.FILL(buf, 128, 0);
  WHILE n > LONGINT(128) DO
    IF Files.BlockWrite(f, buf, 128) # 128 THEN Err.Error("Write error") END;
    DEC(n, LONGINT(128))
  END;
  chunk := WORD(n);
  IF chunk > 0 THEN
    IF Files.BlockWrite(f, buf, chunk) # chunk THEN Err.Error("Write error") END
  END
END WriteZeros;

(* Copy n bytes of the linked code image from the spill file into fout, then
   close (and so delete) the spill file.  The spill file is the one opened in
   PerformLinking and left open + rewound; it is never reopened by name.
   Uses a fixed 512-byte stack buffer — no large heap. *)
PROCEDURE CopyCodeImage(ls: State; VAR fout: Files.File; n: LONGINT);
  VAR buf: ARRAY 512 OF BYTE;
      left: LONGINT; chunk, got, i: WORD;
BEGIN
  IF n <= LONGINT(0) THEN Files.Close(ls^.spillFile); RETURN END;
  left := n;
  WHILE left > LONGINT(0) DO
    IF left > LONGINT(512) THEN chunk := 512 ELSE chunk := WORD(left) END;
    got := Files.BlockRead(ls^.spillFile, buf[0], chunk);
    (* The spill file may be a few bytes short of the 16-aligned code image
       (final group's trailing alignment).  Zero-fill any tail beyond EOF. *)
    i := got; WHILE i < chunk DO buf[i] := BYTE(0); INC(i) END;
    IF Files.BlockWrite(fout, buf[0], chunk) # chunk THEN
      Files.Close(ls^.spillFile); Err.Error("Write error (code)")
    END;
    left := left - LONGINT(chunk)
  END;
  Files.Close(ls^.spillFile)   (* delete-on-close removes LNKCODE.TMP *)
END CopyCodeImage;

PROCEDURE WriteExe*(ls: State; outPath: ARRAY OF CHAR);
  VAR fout: Files.File;
      codePara, dataBssPara, hdrPara: INTEGER;
      exeSize: LONGINT;
      partPage, pageCnt: INTEGER;
      hdrBytes: LONGINT;
      gapBytes: LONGINT;
      rel: MZReloc; k: INTEGER;
      dataInPara, bssGapPara, stackPara, minAlloc: LONGINT;
      summary: ARRAY 128 OF CHAR;
BEGIN
  IF ~Files.ReWrite(fout, outPath) THEN Err.Error2("Cannot write: ", outPath); RETURN END;

  codePara    := INTEGER((ls^.totalCodeLen + LONGINT(15)) DIV LONGINT(16));
  dataBssPara := INTEGER((ls^.totalDataLen + ls^.totalBssLen + LONGINT(15)) DIV LONGINT(16));
  hdrBytes    := LONGINT(MzHdrBytes) + LONGINT(ls^.mzRelocCnt) * LONGINT(4);
  hdrPara     := INTEGER((hdrBytes + LONGINT(15)) DIV LONGINT(16)) + 1;

  exeSize  := LONGINT(hdrPara) * LONGINT(16) + ls^.totalCodeLen + ls^.totalDataLen;
  pageCnt  := INTEGER(exeSize DIV LONGINT(512));
  partPage := INTEGER(exeSize MOD LONGINT(512));
  IF partPage # 0 THEN INC(pageCnt) END;

  (* Compute MZ min/max_alloc.
     Static layout above the loaded image = code_para + data_bss_para + stack_para.
     File image above hdr = code_para + ceil(data_in_file/16).
     min_alloc must cover the gap: BSS that didn't fit in data_in_file paragraphs,
     plus the stack.  We set min = max so DOS gives us exactly what we need and
     leaves the rest free for the runtime heap (INT 21h/48h in SYSTEM_INIT)
     and for Dos.Exec child processes.  Using 0/0FFFFH (old behaviour) hogs
     all free memory and breaks both. *)
  dataInPara := (ls^.totalDataLen + LONGINT(15)) DIV LONGINT(16);
  bssGapPara := LONGINT(dataBssPara) - dataInPara;
  stackPara  := (ls^.stackSize + LONGINT(15)) DIV LONGINT(16);
  minAlloc   := bssGapPara + stackPara;
  IF minAlloc > LONGINT(0FFFFH) THEN minAlloc := LONGINT(0FFFFH) END;

  (* write MZ header *)
  Files.WriteWord(fout, 5A4DH);
  Files.WriteWord(fout, partPage);
  Files.WriteWord(fout, pageCnt);
  Files.WriteWord(fout, INTEGER(ls^.mzRelocCnt));
  Files.WriteWord(fout, hdrPara);
  Files.WriteWord(fout, INTEGER(minAlloc));
  Files.WriteWord(fout, INTEGER(minAlloc));
  Files.WriteWord(fout, codePara + dataBssPara);    (* SS *)
  Files.WriteWord(fout, INTEGER(ls^.stackSize) - 2);(* SP *)
  Files.WriteWord(fout, 0);                          (* checksum *)
  Files.WriteWord(fout, ls^.entryIp);               (* IP *)
  Files.WriteWord(fout, ls^.entryCSPara);           (* CS *)
  Files.WriteWord(fout, MzHdrBytes);                (* reloc table offset *)
  Files.WriteWord(fout, 0);                          (* overlay *)

  (* write MZ relocation table — one BlockWrite per chunk (w already holds the
     relocs in MZ wire order: count*2 little-endian WORDs). *)
  rel := ls^.relocHead;
  WHILE rel # NIL DO
    IF rel^.count > 0 THEN
      IF Files.BlockWrite(fout, rel^.w[0], WORD(rel^.count * 2 * 2)) # WORD(rel^.count * 2 * 2) THEN
        Err.Error("Write error (MZ reloc)")
      END
    END;
    rel := rel^.next
  END;

  (* pad header to hdrPara * 16 *)
  gapBytes := LONGINT(hdrPara) * LONGINT(16) - Files.Position(fout);
  WriteZeros(fout, gapBytes);

  (* copy the linked code image (totalCodeLen bytes) from the spill file *)
  CopyCodeImage(ls, fout, ls^.totalCodeLen);

  (* write data segment *)
  IF ls^.totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, ls^.dataBuf^[0], WORD(ls^.totalDataLen))
       # WORD(ls^.totalDataLen) THEN
      Err.Error("Write error (data)")
    END
  END;

  (* /G: append the TDS debug block after the data image (debugger-only tail —
     DOS loads only header+code+data; no header field above changes). *)
  WriteDebugInfo(ls, fout);

  Files.Close(fout);

  Strings.Copy(outPath, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(ls^.totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(ls^.totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(ls^.totalBssLen,  summary);
  Strings.Append(", Stack=", summary); Strings.AppendInt(ls^.stackSize,   summary);
  Err.Info(summary)
END WriteExe;

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

(* Release the entire link-State graph: modules, symbols, MZ relocs,
   group descriptors, and the data buffer.  Symbols live in the chunk-node list
   (ls^.symNodes); the WORD handle chains (symHead/next, symHash/hNext) index into
   those chunks and need no per-symbol free. *)
PROCEDURE LinkFree*(ls: State);
  VAR m, mNext: Module; sn, snNext: SymNode; r, rNext: MZReloc;
      g, gNext: GroupNode; i: INTEGER;
      p, pNext: PoolNode; sc, scNext: ScopeNode;
BEGIN
  p := ls^.dbgPool;
  WHILE p # NIL DO pNext := p^.next; DISPOSE(p); p := pNext END;
  ls^.dbgPool := NIL; ls^.dbgPoolTail := NIL;
  ls^.dbgPoolBytes := LONGINT(0);
  ls^.dbgNames := 0; ls^.dbgModCnt := 0;
  ls^.dbgSymCnt := 0; ls^.dbgLineCnt := 0;

  sc := ls^.dbgScopeHead;
  WHILE sc # NIL DO scNext := sc^.next; DISPOSE(sc); sc := scNext END;
  ls^.dbgScopeHead := NIL; ls^.dbgScopeTail := NIL; ls^.dbgScopeCnt := 0;

  r := ls^.relocHead;
  WHILE r # NIL DO rNext := r^.next; DISPOSE(r); r := rNext END;
  ls^.relocHead := NIL; ls^.relocTail := NIL;

  sn := ls^.symNodes;
  WHILE sn # NIL DO snNext := sn^.next; DISPOSE(sn); sn := snNext END;
  ls^.symNodes := NIL; ls^.symHead := NoSym; ls^.symCount := 0;
  i := 0; WHILE i < MaxSymChunk DO ls^.symDir[i] := NIL; INC(i) END;
  i := 0; WHILE i < SymHash DO ls^.symHash[i] := NoSym; INC(i) END;

  g := ls^.groupHead;
  WHILE g # NIL DO
    gNext := g^.next;   (* g^.g[*].buf are aliases of ls^.codeBuf, freed once below *)
    DISPOSE(g); g := gNext
  END;
  ls^.groupHead := NIL; ls^.groupTail := NIL;

  m := ls^.modHead;
  WHILE m # NIL DO mNext := m^.next; DISPOSE(m); m := mNext END;
  ls^.modHead := NIL; ls^.modTail := NIL;

  IF ls^.dataBuf # NIL THEN DISPOSE(ls^.dataBuf); ls^.dataBuf := NIL END;
  IF ls^.codeBuf # NIL THEN DISPOSE(ls^.codeBuf); ls^.codeBuf := NIL END
END LinkFree;

END Link.
