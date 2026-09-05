(*$D-,A-,O-*)
MODULE Syms;
(*
  Symbol table: types, symbols, scopes, predeclared universe.

  Storage model (RAM, pointer-based — opt.md §12 final form): Symbol and
  TypeDesc are POINTERS to records that live inside chunked RAM arenas
  (SymPer/TypePer records per chunk, bump-allocated, never moved).  There is
  no handle indirection and no Get/Set copy API: callers read and write
  record fields directly through the pointer (auto-deref: s.kind == s^.kind).

  The arena keeps zero-leak trivial: SymsFree DISPOSEs whole chunks — no
  per-record heap headers, no record walking.  NewSymRec/NewTypeDesc fully
  initialise every field before the pointer escapes (the runtime does NOT
  zero NEW'd chunks).

  NoSym / NoType are exported VARs holding NIL (CONSTs are integer-only in
  this dialect).  Chunk-allocation failure latches LogErr ("out of memory …")
  and returns the last valid record so no NIL deref occurs before the compile
  dies at the next boundary — fail-fast, single Halt in TOC.Run.

  Names are NOT stored in records: nameId/modId are StrTab.TStrTabId ids
  (Layer 1) — name equality is id equality, so SymFind is a single id
  compare per candidate.

  Scope records stay individual heap records: they are few (one per nesting
  level plus popped procedure scopes).

  Inline-proc byte patterns (InlineNode) and FORWARD patch lists (FwdNode)
  stay as heap lists hung off a TypeDesc / Symbol via a pointer field.
*)
IMPORT LogErr, StrTab, Strings;

CONST
  (* symbol kinds *)
  KConst*    = 0;
  KType*     = 1;
  KVar*      = 2;
  KParam*    = 3;
  KVarParam* = 4;
  KProc*     = 5;
  KField*    = 6;
  KImport*   = 7;
  KSysProc*  = 8;

  (* type forms *)
  TFInteger*  =  0;
  TFBoolean*  =  1;
  TFChar*     =  2;
  TFByte*     =  3;
  TFSet*      =  4;
  TFNiltype*  =  5;
  TFNotype*   =  6;
  TFArray*    =  7;
  TFRecord*   =  8;
  TFPointer*  =  9;
  TFProc*     = 10;
  TFAddress*  = 11;
  TFLongint*  = 12;
  TFWord*     = 13;
  TFReal*     = 14;
  TFLongreal* = 15;

  (* system procedure IDs *)
  SpNew*     =  0;
  SpInc*     =  1;
  SpDec*     =  2;
  SpLen*     =  3;
  SpOdd*     =  4;
  SpAbs*     =  5;
  SpAssert*  =  6;
  SpCopy*    =  7;
  SpOrd*     =  8;
  SpChr*     =  9;
  SpFloor*   = 10;
  SpDispose* = 11;
  SpLsl*     = 21;
  SpLsr*     = 24;
  SpAsr*     = 22;
  SpRor*     = 23;
  SpToInt*   = 25;
  SpToByte*  = 26;
  SpToLong*  = 27;
  SpToWord*  = 31;
  SpSize*    = 32;
  SpAnd*     = 28;
  SpIor*     = 29;
  SpXor*     = 30;

  (* sizes in bytes *)
  SzInteger*  = 2;
  SzBoolean*  = 1;
  SzChar*     = 1;
  SzByte*     = 1;
  SzSet*      = 2;
  SzWord*     = 2;
  SzPointer*  = 4;
  SzLongint*  = 4;
  SzReal*     = 4;
  SzLongreal* = 8;

  MaxLevel* = 8;
  NameLen*  = 40;

  (* Arena geometry (maintainer directive 2026-07-19: size each chunk's
     total node allocation, payload + 16-byte heap header, to just under a
     4 KB boundary — see DOCS/IMPLRULE.MD "Chunk-size rule for future
     arenas").  SymbolRec (37 B) and TypeDescRec (42 B) don't divide evenly
     into a power-of-2 count near 4 KB, so SymPer/TypePer use plain
     DIV/MOD indexing (SymIdxChunk/SymIdxSlot etc. below) instead of the
     former LSR/AND bit-shift trick, which required a power-of-2 ChunkPer
     shared by both arenas. This is not a hot path (one chunk-boundary
     check per SymPer/TypePer allocations, not per access), so the
     division cost is negligible.
     SymPer=110 (110*37+16=4086 B), TypePer=97 (97*42+16=4090 B).
     MaxSymChunks/MaxTypeChunks sized to preserve the historical 8192-
     record cap (matches StrTab's MaxEnt*EntPer cap) with the new,
     smaller per-chunk counts.  Peak self-host need measured 2026-07-04:
     1,673 syms / 817 types. *)
  SymPer  = 110;
  TypePer = 97;
  MaxSymChunks  = 74;   (* 74*110 = 8140, just under the 8192 cap *)
  MaxTypeChunks = 84;   (* 84*97  = 8148, just under the 8192 cap *)

  (* small-record chunking: elements per chunk node (amortizes the 16-byte
     heap-block header over many entries instead of one) *)
  FwdChunk*    = 32;
  InlineChunk* = 32;

  (* Structural-type dedup index (see typeHash in the VAR block).  Power of
     two so the bucket is a mask, not a MOD.  1024 entries = 2 KB of BSS.
     Only TFArray/TFPointer are indexed, and dedup collapses them hard: the
     heaviest module measured (TOCMAIN, 20 imports) keeps just 70 arrays + 24
     pointers after interning, so 1024 buckets is a load factor under 0.1 --
     and an over-full table costs a missed dedup, never correctness. *)
  TypeHashSize = 1024;
  TypeHashMask = 1023;
  TypeNoSlot   = -1;    (* empty bucket marker *)

TYPE
  Symbol*   = POINTER TO SymbolRec;
  TypeDesc* = POINTER TO TypeDescRec;

  (* Inline procedure byte pattern node — heap list hung off a TypeDesc.
     SYSTEM (implicitly imported by nearly every module) has many INLINE procs,
     so these are allocated heavily; chunk InlineChunk entries per node
     (small-record rule).  allNext chains every node ever created so SymsFree can
     release them. *)
  InlineNode* = POINTER TO InlineNodeDesc;
  InlineNodeDesc* = RECORD
    isParam*:  ARRAY InlineChunk OF BOOLEAN;
    rawByte*:  ARRAY InlineChunk OF BYTE;
    paramIdx*: ARRAY InlineChunk OF INTEGER;
    count*:    INTEGER;
    next*:     InlineNode;
    allNext:   InlineNode
  END;

  (* Forward-call patch list node — heap list hung off a Symbol.
     Small-record optimization (CLAUDE.md §"Small-record chunking"). *)
  FwdNode* = POINTER TO FwdNodeDesc;
  FwdNodeDesc* = RECORD
    ofs*:    ARRAY FwdChunk OF LONGINT;
    count*:  INTEGER;
    next*:   FwdNode;
    allNext: FwdNode
  END;

  Scope*    = POINTER TO ScopeRec;

  TypeDescRec* = RECORD
    form*:       INTEGER;
    size*:       LONGINT;
    align*:      INTEGER;
    (* TFArray: element count (-1 = open array). TFArray-only; TFRecord and
       TFProc do not use this field (they use lenOrDescOrArg below). *)
    len*:        LONGINT;
    (* TFArray: element type. TFProc: return type.
       Mutually exclusive by `form`. *)
    elemOrRet*:  TypeDesc;
    (* TFRecord: field-chain head. TFProc: param-chain head.
       Mutually exclusive by `form`. *)
    symList*:     Symbol;
    (* TFRecord: field-chain tail. TFProc: param-chain tail.
       Mutually exclusive by `form`. *)
    symListTail*: Symbol;
    base*:       TypeDesc;  (* TFRecord: extension base type. TFPointer: pointee type. *)
    (* TFRecord: this record's unique runtime type tag id.
       TFProc: parameter count.
       Mutually exclusive by `form`. *)
    tagIdOrNParams*: INTEGER;
    (* TFRecord: byte offset of the runtime type-tag word / descriptor.
       TFProc: total argument-block size in bytes.
       TFArray does not use this field (it uses `len` above).
       Mutually exclusive by `form`. *)
    lenOrDescOrArg*: LONGINT;
    isFar*:      BOOLEAN;
    isInline*:   BOOLEAN;
    inlineList*: InlineNode;
    nInline*:    INTEGER
  END;

  (* Names are StrTab ids (nameId/modId) — name equality is id equality. *)
  SymbolRec* = RECORD
    nameId*:     StrTab.TStrTabId;    (* StrTab id of the symbol's name *)
    kind*:       INTEGER;
    exported*:   BOOLEAN;
    type*:       TypeDesc;
    level*:      INTEGER;
    val*:        LONGINT;
    (* KVar/KParam/KVarParam: variable's runtime address/frame offset.
       KConst: for consts whose initializer is Cgen.MGlobal-mode, the aliased
       global address (secondary to `val`).
       KProc: procedure's code offset (former `codeOfs`).
       KField: field's byte offset within its record (former `offset`).
       All uses mutually exclusive by `kind` — shares one physical slot. *)
    adr*:        LONGINT;
    rdoffId*:    INTEGER;
    fwdDecl*:    BOOLEAN;
    fwdPatches*: FwdNode;
    typeless*:   BOOLEAN;
    modId*:      StrTab.TStrTabId;    (* StrTab id: import's real module name /
                             imported proc's full link name; 0 = none *)
    sysId*:      BYTE;    (* SysProc id: max value 32 (SpSize), fits BYTE *)
    wasRead*:    BOOLEAN;
    declLine*:   INTEGER;
    next*:       Symbol
  END;

  ScopeRec* = RECORD
    symbols*:  Symbol;
    nSyms*:    INTEGER;
    outer*:    Scope;
    level*:    INTEGER;
    localTop*: LONGINT;
    paramBot*: LONGINT;
    allNext:   Scope    (* chain of every scope created, for SymsFree *)
  END;

  (* Arena chunks: records are bump-allocated inside; chunks never move, so
     the record pointers handed out stay valid until SymsFree. *)
  SymChunk = POINTER TO SymChunkDesc;
  SymChunkDesc = RECORD
    s: ARRAY SymPer OF SymbolRec
  END;

  TypeChunk = POINTER TO TypeChunkDesc;
  TypeChunkDesc = RECORD
    t: ARRAY TypePer OF TypeDescRec
  END;

VAR
  NoSym*:  Symbol;    (* = NIL; VAR because CONSTs are integer-only *)
  NoType*: TypeDesc;  (* = NIL *)

  TypeInteger*,  TypeBoolean*, TypeChar*,
  TypeByte*,     TypeSet*,     TypeNiltype*,
  TypeNotype*,   TypeAddress*, TypeLongint*,
  TypeWord*,     TypeReal*,    TypeLongreal*: TypeDesc;

  TopScope*: Scope;
  Universe*: Scope;
  NextTagId*: INTEGER;

  (* (*$A+*)/(*$A-*) directive: word-alignment of RECORD fields.  Default
     OFF (packed, no padding) so RECORDs match wire/hardware-call layouts
     (e.g. EMS.mod's MoveDesc, a LIM EMS 4.0 struct) without special-casing.
     (*$A+*) re-enables WORD/LONGINT field alignment for records that want
     it; (*$A-*) returns to packed.  May be toggled multiple times per file. *)
  AlignFields*: BOOLEAN;

  (* ---- arenas ---- *)
  symDir:  ARRAY MaxSymChunks OF SymChunk;
  typeDir: ARRAY MaxTypeChunks OF TypeChunk;
  symCount:  WORD;    (* records allocated (also drives bump position) *)
  typeCount: WORD;

  (* ---- structural type dedup (TFArray / TFPointer) ----
     Every imported module's .def is parsed into freshly allocated TypeDescs
     (DEF.MOD holds 18 of the ~30 TypeNew* call sites), so the same shape --
     POINTER TO Foo, ARRAY 32 OF CHAR -- is rebuilt once per import path that
     mentions it.  Type count therefore tracks IMPORT COUNT, not module
     complexity: measured across a self-host, ~0.55 types per symbol in every
     module, peaking at 1156 types (arr=378 ptr=193) for the 20-import
     TOCMAIN.  Interning the two structurally-keyed forms collapses those
     duplicates, the same way StrTab already interns names.

     ONLY TFArray and TFPointer are interned, and only when fully determined
     at construction:
       - TFRecord  must NOT be: TypeNewRecord stamps a UNIQUE NextTagId
         (the runtime type tag) and fields are appended afterwards by
         TypeAddField, so two records with identical shape are still
         distinct types.
       - TFProc    must NOT be: TypeNewProc creates an empty signature that
         TypeAddParam fills in later, so its identity is not known yet at
         construction time.
       - a TFPointer whose base is still unresolved must NOT be: the forward
         reference patchers (PARSER.MOD's fwdRefs loop, DEF.MOD's derived-base
         loop) mutate `.base` in place afterwards, and sharing such a node
         would splice one module's resolution into another's type.
         DedupPointer is therefore only consulted for an already-resolved
         base (see TypeNewPointer).

     Index: open-addressed hash over arena slot indices; TypeNoSlot = empty.
     It holds indices rather than pointers so it survives nothing -- it is
     reset with the arenas in FreeChunks/SymInit.  Sized a power of two for
     a mask instead of a MOD, and generously (load factor < 0.5 at the
     measured 1156-type peak). *)
  typeHash: ARRAY TypeHashSize OF INTEGER;
  bodyI: INTEGER;     (* module-body init loop counter *)

  (* Fallback OOM targets for AllocSym/AllocType: "return the most recent
     record" underflows when the very FIRST allocation fails (symCount/
     typeCount = 0, so `symCount - 1` wraps a WORD to 65535 -> symDir[255],
     8x past the 32-entry directory -> wild pointer).  These static nodes
     (allocated once at module init, outside the arena) are the safe target
     for that specific case. *)
  symOom:  Symbol;
  typeOom: TypeDesc;

  (* allocation chains for the heap nodes hung off arena records, so
     SymsFree can release them (the records are freed wholesale by chunk). *)
  allInline: InlineNode;
  allFwd:    FwdNode;
  allScopes: Scope;

  (* interned ids of the predeclared type names (set in SymInit) *)
  idInteger, idBoolean, idChar, idByte, idWord, idLongint,
  idReal, idLongreal, idSet, idAddress: StrTab.TStrTabId;

(* Allocate + register a heap node so SymsFree frees it.  Callers use these
   instead of NEW for InlineNode / FwdNode. *)
PROCEDURE NewInline(): InlineNode;
  VAR n: InlineNode;
BEGIN
  NEW(n); n^.count := 0; n^.next := NIL;
  n^.allNext := allInline; allInline := n; RETURN n
END NewInline;

(* Append one inline element to the END of the chunked list (order-preserving):
   head is the first chunk, tail the last.  Allocates a fresh tail chunk only
   when the current one fills. *)
PROCEDURE InlineAppend*(VAR head, tail: InlineNode; isParam: BOOLEAN; rawByte: BYTE; paramIdx: INTEGER);
  VAR n: InlineNode;
BEGIN
  IF (tail = NIL) OR (tail^.count >= InlineChunk) THEN
    n := NewInline();
    IF tail # NIL THEN tail^.next := n ELSE head := n END;
    tail := n
  END;
  tail^.isParam[tail^.count] := isParam;
  tail^.rawByte[tail^.count] := rawByte;
  tail^.paramIdx[tail^.count] := paramIdx;
  INC(tail^.count)
END InlineAppend;

PROCEDURE NewFwd(): FwdNode;
  VAR n: FwdNode;
BEGIN
  NEW(n); n^.count := 0; n^.next := NIL;
  n^.allNext := allFwd; allFwd := n; RETURN n
END NewFwd;

(* Append a forward-call patch offset to sym's chunked patch list (head node).
   Allocates a fresh chunk only when the current head is full. *)
PROCEDURE FwdAppend*(VAR head: FwdNode; ofs: LONGINT);
  VAR n: FwdNode;
BEGIN
  IF (head = NIL) OR (head^.count >= FwdChunk) THEN
    n := NewFwd(); n^.next := head; head := n
  END;
  head^.ofs[head^.count] := ofs; INC(head^.count)
END FwdAppend;

(* ---- arena allocators ----
   Bump-allocate the next record slot; the pointer stays valid until SymsFree
   (chunks never move).  On chunk exhaustion / OOM: latch LogErr and return the
   most recent record (never NIL once SymInit ran) so callers cannot NIL-deref
   before the compile dies at the next LogErr boundary.  Special case: if the
   very FIRST allocation fails (count = 0), "most recent record" has no
   meaning (`count - 1` would wrap a WORD to 65535, indexing 8x past the
   32-entry symDir/typeDir) — fall back to the static symOom/typeOom node
   instead. *)

PROCEDURE SymSlotPtr(idx: WORD): Symbol;
  VAR p: Symbol;
BEGIN
  p := SYSTEM.ADR(symDir[idx DIV WORD(SymPer)]^.s[idx MOD WORD(SymPer)]);
  RETURN p
END SymSlotPtr;

PROCEDURE TypeSlotPtr(idx: WORD): TypeDesc;
  VAR p: TypeDesc;
BEGIN
  p := SYSTEM.ADR(typeDir[idx DIV WORD(TypePer)]^.t[idx MOD WORD(TypePer)]);
  RETURN p
END TypeSlotPtr;

PROCEDURE AllocSym(): Symbol;
  VAR c: WORD;
BEGIN
  IF symCount MOD WORD(SymPer) = 0 THEN   (* next slot opens a chunk *)
    c := symCount DIV WORD(SymPer);
    IF c >= WORD(MaxSymChunks) THEN
      LogErr.Error("too many symbols");
      IF symCount = 0 THEN RETURN symOom END;
      RETURN SymSlotPtr(symCount - 1)
    END;
    IF symDir[c] = NIL THEN
      NEW(symDir[c]);
      IF symDir[c] = NIL THEN
        LogErr.Error("out of memory (symbol table)");
        IF symCount = 0 THEN RETURN symOom END;
        RETURN SymSlotPtr(symCount - 1)
      END
    END
  END;
  INC(symCount);
  RETURN SymSlotPtr(symCount - 1)
END AllocSym;

PROCEDURE AllocType(): TypeDesc;
  VAR c: WORD;
BEGIN
  IF typeCount MOD WORD(TypePer) = 0 THEN
    c := typeCount DIV WORD(TypePer);
    IF c >= WORD(MaxTypeChunks) THEN
      LogErr.Error("too many types");
      IF typeCount = 0 THEN RETURN typeOom END;
      RETURN TypeSlotPtr(typeCount - 1)
    END;
    IF typeDir[c] = NIL THEN
      NEW(typeDir[c]);
      IF typeDir[c] = NIL THEN
        LogErr.Error("out of memory (type table)");
        IF typeCount = 0 THEN RETURN typeOom END;
        RETURN TypeSlotPtr(typeCount - 1)
      END
    END
  END;
  INC(typeCount);
  RETURN TypeSlotPtr(typeCount - 1)
END AllocType;

(* ---- structural type dedup (see typeHash's comment in the VAR block) ---- *)

(* TypeHashReset — empty every bucket.  Must run whenever the type arena is
   emptied, since buckets hold arena slot indices. *)
PROCEDURE TypeHashReset;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < TypeHashSize DO typeHash[i] := TypeNoSlot; INC(i) END
END TypeHashReset;

(* TypeKey — bucket for a structural type, from the operand's POINTER VALUE
   (seg XOR ofs) rather than its arena index: identity is what we compare, and
   a pointer needs no arena search, keeping both lookup and insert O(1).
   An earlier draft keyed on the slot index and had to scan the arena to find
   it -- that reintroduced the O(n^2) this index exists to avoid. *)
PROCEDURE TypeKey(form: INTEGER; operand: TypeDesc; len: LONGINT): INTEGER;
  VAR h: WORD;
BEGIN
  IF operand = NIL THEN h := 0
  ELSE h := SYSTEM.XOR(SYSTEM.SEG(operand^), SYSTEM.OFS(operand^))
  END;
  h := SYSTEM.XOR(h * WORD(131), WORD(form) * WORD(31));
  h := SYSTEM.XOR(h, WORD(len) * WORD(7));
  RETURN INTEGER(SYSTEM.AND(h, WORD(TypeHashMask)))
END TypeKey;

(* TypeIntern — return an existing structurally identical TFArray/TFPointer,
   or NIL if none is indexed yet.  Comparison is exact: same form, same len,
   and the SAME operand node (pointer identity). *)
PROCEDURE TypeIntern(form: INTEGER; operand: TypeDesc; len: LONGINT): TypeDesc;
  VAR b, probes, slot: INTEGER; c: TypeDesc;
BEGIN
  b := TypeKey(form, operand, len);
  probes := 0;
  WHILE probes < TypeHashSize DO
    slot := typeHash[b];
    IF slot = TypeNoSlot THEN RETURN NIL END;
    c := TypeSlotPtr(WORD(slot));
    IF (c.form = form) & (c.len = len) THEN
      IF form = TFArray THEN
        IF c.elemOrRet = operand THEN RETURN c END
      ELSE
        IF c.base = operand THEN RETURN c END
      END
    END;
    b := INTEGER(SYSTEM.AND(WORD(b + 1), WORD(TypeHashMask)));
    INC(probes)
  END;
  RETURN NIL
END TypeIntern;

(* TypeIndexAdd — record a newly built structural type in the index.  `slot` is
   the arena index the caller just allocated (typeCount-1).  Silently does
   nothing when the table is full: dedup is an optimization, so a missed entry
   costs a duplicate, never correctness. *)
PROCEDURE TypeIndexAdd(form: INTEGER; operand: TypeDesc; len: LONGINT;
                       slot: INTEGER);
  VAR b, probes: INTEGER;
BEGIN
  b := TypeKey(form, operand, len);
  probes := 0;
  WHILE probes < TypeHashSize DO
    IF typeHash[b] = TypeNoSlot THEN typeHash[b] := slot; RETURN END;
    b := INTEGER(SYSTEM.AND(WORD(b + 1), WORD(TypeHashMask)));
    INC(probes)
  END
END TypeIndexAdd;



(* FreeChunks — DISPOSE every arena chunk (zero-leak rule) and empty both
   arenas.  All Symbol/TypeDesc pointers become invalid. *)
PROCEDURE FreeChunks;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < MaxSymChunks DO
    IF symDir[i] # NIL THEN DISPOSE(symDir[i]); symDir[i] := NIL END;
    INC(i)
  END;
  i := 0;
  WHILE i < MaxTypeChunks DO
    IF typeDir[i] # NIL THEN DISPOSE(typeDir[i]); typeDir[i] := NIL END;
    INC(i)
  END;
  symCount := 0; typeCount := 0;
  (* buckets hold arena slot indices — they die with the arena *)
  TypeHashReset
END FreeChunks;

(* ---- private allocators (fully initialise before the pointer escapes) ---- *)

PROCEDURE NewTypeDesc(form: INTEGER; size: LONGINT): TypeDesc;
  VAR t: TypeDesc;
BEGIN
  t := AllocType();
  t.form        := form;
  t.size        := size;
  IF size > 2 THEN t.align := 2
  ELSIF size > 0 THEN t.align := INTEGER(size)
  ELSE t.align := 0
  END;
  t.len         := 0;
  t.elemOrRet   := NIL;
  t.symList     := NIL;
  t.symListTail := NIL;
  t.base        := NIL;
  t.tagIdOrNParams := 0;
  t.lenOrDescOrArg := 0;
  t.isFar       := FALSE;
  t.isInline    := FALSE;
  t.inlineList  := NIL;
  t.nInline     := 0;
  RETURN t
END NewTypeDesc;

PROCEDURE NewSymRec(nameId: StrTab.TStrTabId; kind: INTEGER): Symbol;
  VAR s: Symbol;
BEGIN
  s := AllocSym();
  s.nameId      := nameId;
  s.kind        := kind;
  s.exported    := FALSE;
  s.type        := NIL;
  s.level       := 0;
  s.val         := 0;
  s.adr         := 0;
  s.rdoffId     := -1;
  s.fwdDecl     := FALSE;
  s.fwdPatches  := NIL;
  s.typeless    := FALSE;
  s.modId       := 0;
  s.sysId       := BYTE(0);
  s.wasRead     := FALSE;
  s.declLine    := 0;
  s.next        := NIL;
  RETURN s
END NewSymRec;

(* ---- public type constructors ---- *)

PROCEDURE TypeNew*(form: INTEGER; size: LONGINT): TypeDesc;
BEGIN
  RETURN NewTypeDesc(form, size)
END TypeNew;

PROCEDURE TypeNewArray*(elem: TypeDesc; len: LONGINT): TypeDesc;
  VAR t: TypeDesc;
BEGIN
  (* Interned: an ARRAY is fully determined by (element type, length) and is
     never mutated afterwards, so every "ARRAY n OF Elem" can share one node
     (see typeHash's comment). *)
  t := TypeIntern(TFArray, elem, len);
  IF t # NIL THEN RETURN t END;
  t := NewTypeDesc(TFArray, 0);
  t.elemOrRet := elem;
  t.len  := len;
  IF len >= 0 THEN t.size := len * elem.size
  ELSE t.size := SzPointer
  END;
  TypeIndexAdd(TFArray, elem, len, INTEGER(typeCount) - 1);
  RETURN t
END TypeNewArray;

PROCEDURE TypeNewRecord*(base: TypeDesc): TypeDesc;
  VAR t: TypeDesc;
BEGIN
  t := NewTypeDesc(TFRecord, 0);
  t.base  := base;
  t.tagIdOrNParams := NextTagId;
  INC(NextTagId);
  IF base # NIL THEN t.size := base.size END;
  RETURN t
END TypeNewRecord;

PROCEDURE TypeAddField*(rec: TypeDesc; name: ARRAY OF CHAR; ftype: TypeDesc): Symbol;
  VAR f: Symbol; align, off: LONGINT;
BEGIN
  f := NewSymRec(StrTab.Intern(name), KField);
  f.type := ftype;
  IF AlignFields THEN align := ftype.align; IF align < 1 THEN align := 1 END
  ELSE align := 1
  END;
  off := rec.size;
  IF (align > 1) & (off MOD align # 0) THEN off := off + align - (off MOD align) END;
  f.adr := off;
  rec.size := off + ftype.size;
  IF rec.symListTail # NIL THEN rec.symListTail.next := f
  ELSE rec.symList := f
  END;
  rec.symListTail := f;
  RETURN f
END TypeAddField;

PROCEDURE TypeNewPointer*(base: TypeDesc): TypeDesc;
  VAR t: TypeDesc;
BEGIN
  (* Interned ONLY for a resolved base.  A pointer created with an unresolved
     base (NIL / NoType) is a forward reference whose `.base` is patched in
     place later -- PARSER.MOD's fwdRefs loop and DEF.MOD's derived-base loop
     both do exactly that -- and sharing such a node would splice one
     module's resolution into another's type.  Those stay unique. *)
  IF (base # NIL) & (base # NoType) THEN
    t := TypeIntern(TFPointer, base, 0);
    IF t # NIL THEN RETURN t END
  END;
  t := NewTypeDesc(TFPointer, SzPointer);
  t.base := base;
  IF (base # NIL) & (base # NoType) THEN
    TypeIndexAdd(TFPointer, base, 0, INTEGER(typeCount) - 1)
  END;
  RETURN t
END TypeNewPointer;

(* Copy all TypeDesc fields from src into dst (pointer links copied verbatim). *)
PROCEDURE TypeCopyFields*(dst, src: TypeDesc);
BEGIN
  SYSTEM.MOVE(src^, dst^, WORD(SIZE(TypeDescRec)))
END TypeCopyFields;

PROCEDURE TypeNewProc*(ret: TypeDesc): TypeDesc;
  VAR t: TypeDesc;
BEGIN
  t := NewTypeDesc(TFProc, SzPointer);
  IF ret # NIL THEN t.elemOrRet := ret ELSE t.elemOrRet := TypeNotype END;
  RETURN t
END TypeNewProc;

PROCEDURE TypeAddParam*(pt: TypeDesc; name: ARRAY OF CHAR;
                        ptype: TypeDesc; isVar: BOOLEAN): Symbol;
  VAR p: Symbol;
BEGIN
  p := NewSymRec(StrTab.Intern(name), 0);
  IF isVar THEN p.kind := KVarParam ELSE p.kind := KParam END;
  p.type := ptype;
  INC(pt.tagIdOrNParams);
  IF pt.symListTail # NIL THEN pt.symListTail.next := p
  ELSE pt.symList := p
  END;
  pt.symListTail := p;
  RETURN p
END TypeAddParam;

PROCEDURE ParamSlotSize(p: Symbol): LONGINT;
  VAR t: TypeDesc;
BEGIN
  t := p.type;
  IF p.kind = KVarParam THEN
    IF (t.form = TFArray) & (t.len < 0) THEN RETURN 6 END;
    RETURN SzPointer
  END;
  IF (t.form = TFArray) & (t.len < 0) THEN RETURN 6 END;
  (* By-value RECORD or fixed ARRAY: caller copies the whole aggregate onto the
     stack, 2-byte aligned (Cgen.CgPushAggrValue), so the slot is SIZE rounded up
     to an even byte count. *)
  IF (t.form = TFRecord) OR (t.form = TFArray) THEN
    RETURN (t.size + LONGINT(1)) DIV LONGINT(2) * LONGINT(2)
  END;
  IF t.size < 2 THEN RETURN 2 END;
  RETURN t.size
END ParamSlotSize;

PROCEDURE TypeCalcArgSize*(pt: TypeDesc);
  VAR p: Symbol; total, ofs: LONGINT;
BEGIN
  total := 0;
  p := pt.symList;
  WHILE p # NIL DO
    total := total + ParamSlotSize(p);
    p := p.next
  END;
  pt.lenOrDescOrArg := total;
  IF pt.isFar THEN ofs := LONGINT(6) + total
  ELSE ofs := LONGINT(4) + total
  END;
  p := pt.symList;
  WHILE p # NIL DO
    ofs := ofs - ParamSlotSize(p);
    p.adr := ofs;
    p := p.next
  END
END TypeCalcArgSize;

(* IsForm — NIL-safe "is t of this type form?".  The parsers asked this
   question 59 times as the hand-written pair
   `(x.type # Syms.NoType) & (x.type.form = Syms.TFxxx)`; writing it once
   here removes that repetition and, more importantly, makes the NoType
   guard impossible to forget — omitting it dereferences NIL and crashes
   the compiler, rather than merely giving a wrong answer (code review,
   2026-09-04). *)
PROCEDURE IsForm*(t: TypeDesc; form: INTEGER): BOOLEAN;
BEGIN
  RETURN (t # NoType) & (t # NIL) & (t.form = form)
END IsForm;

PROCEDURE TypeIsExtension*(ext, base: TypeDesc): BOOLEAN;
BEGIN
  WHILE (ext # NIL) & (ext # base) DO ext := ext.base END;
  RETURN ext = base
END TypeIsExtension;

(* Structural equality for type binding across independently elaborated type
   descriptors (once in the defining module, once again in an importing module
   via .def).  Mirrors the RECORD structural fallback but for ARRAY element
   types, recursing through nested arrays and pointer bases so a
   POINTER TO ARRAY N OF T (any T) gets the same cross-module fallback
   POINTER TO RECORD already has (used by both TypeAssignCompat's by-value
   pointer path and TypeParamCompat's VAR path).  See PTR.MD. *)
PROCEDURE TypeStructEq(a, b: TypeDesc): BOOLEAN;
BEGIN
  IF a = b THEN RETURN TRUE END;
  IF a.form # b.form THEN RETURN FALSE END;
  IF a.form = TFArray THEN
    RETURN (a.len = b.len) & TypeStructEq(a.elemOrRet, b.elemOrRet)
  END;
  IF a.form = TFRecord THEN
    IF (a.symList = b.symList) & (a.size = b.size) THEN RETURN TRUE END;
    RETURN TypeIsExtension(b, a) OR TypeIsExtension(a, b)
  END;
  IF a.form = TFPointer THEN
    IF (a.base = NIL) OR (b.base = NIL) THEN RETURN a.base = b.base END;
    RETURN TypeStructEq(a.base, b.base)
  END;
  RETURN TRUE
END TypeStructEq;

PROCEDURE TypeAssignCompat*(dst, src: TypeDesc): BOOLEAN;
BEGIN
  IF dst = src THEN RETURN TRUE END;
  (* Two distinct TypeDesc records of the same PRIMITIVE (non-structured) form
     denote the same type (e.g. TYPE Foo = LONGINT is just another name for
     LONGINT) — they must be compatible even though they are not pointer-
     identical.  Without this, a named alias of a primitive type silently
     mismatches its own underlying type at call sites/assignments. *)
  IF (dst.form = src.form) &
     ((dst.form = TFInteger) OR (dst.form = TFBoolean) OR (dst.form = TFChar) OR
      (dst.form = TFByte) OR (dst.form = TFWord) OR (dst.form = TFLongint) OR
      (dst.form = TFReal) OR (dst.form = TFLongreal) OR (dst.form = TFSet)) THEN
    RETURN TRUE
  END;
  IF (dst.form = TFInteger) & (src.form = TFByte)    THEN RETURN TRUE END;
  IF (dst.form = TFByte)    & (src.form = TFInteger) THEN RETURN TRUE END;
  IF (dst.form = TFChar)    & (src.form = TFByte)    THEN RETURN TRUE END;
  IF (dst.form = TFWord)    & (src.form = TFByte)    THEN RETURN TRUE END;
  IF (dst.form = TFWord)    & (src.form = TFInteger) THEN RETURN TRUE END;
  IF (dst.form = TFInteger) & (src.form = TFWord)    THEN RETURN TRUE END;
  IF (dst.form = TFLongint) & (src.form = TFWord)    THEN RETURN TRUE END;
  IF (dst.form = TFLongint) &
     ((src.form = TFInteger) OR (src.form = TFByte))  THEN RETURN TRUE END;
  IF (dst.form = TFPointer) & (src.form = TFNiltype)  THEN RETURN TRUE END;
  IF (dst.form = TFProc)    & (src.form = TFNiltype)  THEN RETURN TRUE END;
  IF (dst.form = TFPointer) & (src.form = TFPointer) THEN
    IF (dst.base # NIL) & (dst.base.form = TFNotype) THEN RETURN TRUE END;
    IF TypeIsExtension(src.base, dst.base) THEN RETURN TRUE END;
    (* Cross-module structural fallback: two independently-elaborated
       POINTER TO ARRAY (or nested pointer-to-array) descriptors for the same
       type — same fix TypeParamCompat's VAR path has, needed for a by-value
       POINTER-TO-ARRAY parameter passed across a .def boundary (e.g. TASM's
       Scan.MemText handed by value to Scan.InitMem from Parse.MOD). *)
    IF (dst.base # NIL) & (src.base # NIL) &
       (dst.base.form = TFArray) & (src.base.form = TFArray) THEN
      RETURN TypeStructEq(dst.base, src.base)
    END;
    RETURN FALSE
  END;
  IF (dst.form = TFRecord) & (src.form = TFRecord) THEN
    RETURN TypeIsExtension(src, dst)
  END;
  IF (dst.form = TFAddress) &
     ((src.form = TFPointer) OR (src.form = TFInteger) OR
      (src.form = TFAddress) OR (src.form = TFProc) OR
      (src.form = TFNiltype)) THEN RETURN TRUE END;
  IF (src.form = TFAddress) &
     ((dst.form = TFPointer) OR (dst.form = TFInteger) OR
      (dst.form = TFAddress) OR (dst.form = TFProc)) THEN RETURN TRUE END;
  IF (dst.form = TFProc) & (src.form = TFProc) THEN
    RETURN dst.isFar = src.isFar
  END;
  RETURN FALSE
END TypeAssignCompat;

PROCEDURE TypeParamCompat*(formal, actual: TypeDesc; isVar: BOOLEAN): BOOLEAN;
BEGIN
  IF formal = actual THEN RETURN TRUE END;
  (* Element types compare STRUCTURALLY (TypeStructEq), not by pointer
     identity: a record element type elaborated independently on both sides
     of a .def boundary is two TypeDesc records for the same type — pointer
     identity spuriously rejected it for value params while the VAR path
     already used TypeStructEq. *)
  IF (formal.form = TFArray) & (formal.len < 0) & (actual.form = TFArray) THEN
    RETURN TypeStructEq(formal.elemOrRet, actual.elemOrRet)
  END;
  IF (formal.form = TFArray) & (actual.form = TFArray) &
     (formal.len >= 0) & (formal.len = actual.len) &
     TypeStructEq(formal.elemOrRet, actual.elemOrRet) THEN RETURN TRUE END;
  IF isVar THEN
    IF (formal.form = TFArray) & (actual.form = TFArray) &
       (formal.len >= 0) & (formal.len = actual.len) &
       TypeStructEq(formal.elemOrRet, actual.elemOrRet) THEN
      RETURN TRUE
    END;
    IF (formal.form = TFRecord) & (actual.form = TFRecord) THEN
      IF (formal.symList = actual.symList) & (formal.size = actual.size) THEN
        RETURN TRUE
      END;
      RETURN TypeIsExtension(actual, formal)
    END;
    IF (formal.form = TFPointer) & (actual.form = TFPointer) THEN
      IF formal.base = actual.base THEN RETURN TRUE END;
      IF (formal.base # NIL) & (actual.base # NIL) &
         (formal.base.form = TFRecord) & (actual.base.form = TFRecord) THEN
        IF (formal.base.symList = actual.base.symList) &
           (formal.base.size = actual.base.size) THEN
          RETURN TRUE
        END;
        RETURN TypeIsExtension(actual.base, formal.base)
      END;
      IF (formal.base # NIL) & (actual.base # NIL) &
         (formal.base.form = TFArray) & (actual.base.form = TFArray) &
         (formal.base.len = actual.base.len) &
         TypeStructEq(formal.base.elemOrRet, actual.base.elemOrRet) THEN
        RETURN TRUE
      END;
      RETURN FALSE
    END;
    (* A named alias of a primitive scalar (e.g. TYPE Foo = LONGINT) is the
       same type as its underlying built-in for VAR-parameter purposes too —
       required so a VAR formal/actual pair that differ only by which alias
       name was used still binds (same rule as TypeAssignCompat above). *)
    IF (formal.form = actual.form) &
       ((formal.form = TFInteger) OR (formal.form = TFBoolean) OR
        (formal.form = TFChar) OR (formal.form = TFByte) OR
        (formal.form = TFWord) OR (formal.form = TFLongint) OR
        (formal.form = TFReal) OR (formal.form = TFLongreal) OR
        (formal.form = TFSet)) THEN
      RETURN TRUE
    END;
    RETURN FALSE
  END;
  RETURN TypeAssignCompat(formal, actual)
END TypeParamCompat;

(* ---- scope management ---- *)

PROCEDURE SymOpenScope*();
  VAR sc: Scope;
BEGIN
  NEW(sc);
  IF sc = NIL THEN
    (* Fatal: continuing with a NIL scope silently redirects every following
       declaration (NIL far writes land in the IVT under xt) and produces
       "undefined identifier" cascades much later.  See DOCS/IMPLRULE.MD
       §"Allocation failure is FATAL". *)
    LogErr.Error("out of memory (scope)");
    RETURN
  END;
  sc^.symbols  := NIL;
  sc^.nSyms    := 0;
  sc^.outer    := TopScope;
  IF TopScope # NIL THEN sc^.level := TopScope^.level + 1
  ELSE sc^.level := 0
  END;
  sc^.localTop := 0;
  sc^.paramBot := 4;
  sc^.allNext  := allScopes; allScopes := sc;
  TopScope     := sc
END SymOpenScope;

PROCEDURE SymCloseScope*();
BEGIN
  IF TopScope^.outer # NIL THEN TopScope := TopScope^.outer END
END SymCloseScope;

(* SymNewId — declare a symbol whose name is already interned (id known). *)
PROCEDURE SymNewId*(nameId: StrTab.TStrTabId; kind: INTEGER): Symbol;
  VAR s: Symbol;
BEGIN
  s := NewSymRec(nameId, kind);
  s.level := TopScope^.level;
  s.next  := TopScope^.symbols;
  TopScope^.symbols := s;
  INC(TopScope^.nSyms);
  RETURN s
END SymNewId;

(* `name` is BY VALUE (not VAR) on purpose: SymNew is called with string
   LITERALS ("FLOAT", "SYSTEM", "$lim", "$case").  A literal is not an l-value,
   so it cannot be passed to a VAR open-array formal — and SymNew is a once-per-
   declaration cold path, so the copy is irrelevant.  The hot lookup procs
   (SymFind/SymFindLocal/SymFindField) keep VAR — every caller there passes an
   l-value (sc.id, qname, a local name buffer). *)
PROCEDURE SymNew*(name: ARRAY OF CHAR; kind: INTEGER): Symbol;
BEGIN
  RETURN SymNewId(StrTab.Intern(name), kind)
END SymNew;

PROCEDURE SymAllocLocal*(sym: Symbol);
  VAR sz: LONGINT;
BEGIN
  sz := sym.type.size;
  IF sz < 2 THEN sz := 2 END;
  IF TopScope^.localTop MOD 2 # 0 THEN DEC(TopScope^.localTop) END;
  TopScope^.localTop := TopScope^.localTop - sz;
  sym.adr := TopScope^.localTop
END SymAllocLocal;

PROCEDURE SymLocalSize*(): INTEGER;
BEGIN
  RETURN INTEGER(-TopScope^.localTop)
END SymLocalSize;

(* The find family compares StrTab ids: a name never interned cannot be any
   symbol's name (id 0 matches nothing), and an id hit IS the symbol.
   The result pointer gives direct field access — there is no out-param. *)

PROCEDURE SymFindLocalId*(id: StrTab.TStrTabId): Symbol;
  VAR s: Symbol;
BEGIN
  IF id = 0 THEN RETURN NIL END;
  s := TopScope^.symbols;
  WHILE s # NIL DO
    IF s.nameId = id THEN RETURN s END;
    s := s.next
  END;
  RETURN NIL
END SymFindLocalId;

PROCEDURE SymFindLocal*(VAR name: ARRAY OF CHAR): Symbol;
BEGIN
  RETURN SymFindLocalId(StrTab.Find(name))
END SymFindLocal;

PROCEDURE SymFindId(id: StrTab.TStrTabId): Symbol;
  VAR sc: Scope; s: Symbol;
BEGIN
  IF id = 0 THEN RETURN NIL END;
  sc := TopScope;
  WHILE sc # NIL DO
    s := sc^.symbols;
    WHILE s # NIL DO
      IF s.nameId = id THEN RETURN s END;
      s := s.next
    END;
    sc := sc^.outer
  END;
  RETURN NIL
END SymFindId;

PROCEDURE SymFind*(VAR name: ARRAY OF CHAR): Symbol;
BEGIN
  RETURN SymFindId(StrTab.Find(name))
END SymFind;

PROCEDURE SymFindFieldId*(rec: TypeDesc; id: StrTab.TStrTabId): Symbol;
  VAR f: Symbol;
BEGIN
  IF id = 0 THEN RETURN NIL END;
  WHILE rec # NIL DO
    f := rec.symList;
    WHILE f # NIL DO
      IF f.nameId = id THEN RETURN f END;
      f := f.next
    END;
    rec := rec.base
  END;
  RETURN NIL
END SymFindFieldId;

PROCEDURE SymFindField*(rec: TypeDesc; VAR name: ARRAY OF CHAR): Symbol;
BEGIN
  RETURN SymFindFieldId(rec, StrTab.Find(name))
END SymFindField;

(* ---- universe initialisation ---- *)

PROCEDURE PredefType(name: ARRAY OF CHAR; form: INTEGER; size: LONGINT): TypeDesc;
  VAR s: Symbol; t: TypeDesc;
BEGIN
  t := NewTypeDesc(form, size);
  s := SymNew(name, KType);
  s.type := t;
  RETURN t
END PredefType;

(* Predeclared-type resolution by interned id — pure StrTab.TStrTabId
   compares.  The id VARs are captured in SymInit right after the universe
   names are interned. *)
PROCEDURE PredeclTypeId*(id: StrTab.TStrTabId): TypeDesc;
BEGIN
  IF id = 0          THEN RETURN NIL          END;
  IF id = idInteger  THEN RETURN TypeInteger  END;
  IF id = idBoolean  THEN RETURN TypeBoolean  END;
  IF id = idChar     THEN RETURN TypeChar     END;
  IF id = idByte     THEN RETURN TypeByte     END;
  IF id = idWord     THEN RETURN TypeWord     END;
  IF id = idLongint  THEN RETURN TypeLongint  END;
  IF id = idReal     THEN RETURN TypeReal     END;
  IF id = idLongreal THEN RETURN TypeLongreal END;
  IF id = idSet      THEN RETURN TypeSet      END;
  IF id = idAddress  THEN RETURN TypeAddress  END;
  RETURN NIL
END PredeclTypeId;

PROCEDURE PredeclType*(VAR name: ARRAY OF CHAR): TypeDesc;
BEGIN
  RETURN PredeclTypeId(StrTab.Find(name))
END PredeclType;

PROCEDURE PredefConst(name: ARRAY OF CHAR; val: LONGINT; t: TypeDesc);
  VAR s: Symbol;
BEGIN
  s := SymNew(name, KConst);
  s.val := val; s.type := t
END PredefConst;

PROCEDURE PredefSysProc(name: ARRAY OF CHAR; id: INTEGER);
  VAR s: Symbol;
BEGIN
  s := SymNew(name, KSysProc);
  s.sysId := BYTE(id)
END PredefSysProc;

(* Reset the arenas for a fresh compile. *)
PROCEDURE OpenStores(): BOOLEAN;
BEGIN
  (* nothing can fail here — chunks are NEW'd lazily by the allocators (an
     allocation failure latches LogErr there).  BOOLEAN kept for the SymInit
     call shape. *)
  FreeChunks;
  allInline := NIL; allFwd := NIL; allScopes := NIL;
  StrTab.Reset;   (* fresh interning table — ids restart per compile *)
  RETURN TRUE
END OpenStores;

PROCEDURE SymInit*;
  VAR u: Scope; s: Symbol;
BEGIN
  IF ~OpenStores() THEN RETURN END;
  NextTagId := 1;
  AlignFields := FALSE;  (* (*$A-*) default: packed RECORD fields *)

  NEW(u);
  IF u = NIL THEN
    (* Fatal: a NIL universe scope would send every following declaration
       through a NIL far write (IVT corruption).  Latch; ParseModule checks
       LogErr.HaveErr() right after SymInit. *)
    LogErr.Error("out of memory (universe scope)");
    RETURN
  END;
  u^.symbols  := NIL;
  u^.nSyms    := 0;
  u^.outer    := NIL;
  u^.level    := -1;
  u^.localTop := 0;
  u^.paramBot := 4;
  u^.allNext  := allScopes; allScopes := u;
  TopScope    := u;
  Universe    := u;

  TypeNotype  := NewTypeDesc(TFNotype,  0);
  TypeNiltype := NewTypeDesc(TFNiltype, 0);

  TypeInteger  := PredefType("INTEGER",  TFInteger,  SzInteger);
  TypeBoolean  := PredefType("BOOLEAN",  TFBoolean,  SzBoolean);
  TypeChar     := PredefType("CHAR",     TFChar,     SzChar);
  TypeByte     := PredefType("BYTE",     TFByte,     SzByte);
  TypeSet      := PredefType("SET",      TFSet,      SzSet);
  TypeAddress  := PredefType("ADDRESS",  TFAddress,  SzPointer);
  TypeWord     := PredefType("WORD",     TFWord,     SzWord);
  TypeLongint  := PredefType("LONGINT",  TFLongint,  SzLongint);
  TypeReal     := PredefType("REAL",     TFReal,     SzReal);
  TypeLongreal := PredefType("LONGREAL", TFLongreal, SzLongreal);

  (* capture the interned ids for PredeclTypeId (Intern is idempotent — these
     names were just interned by the PredefType SymNew calls above) *)
  idInteger  := StrTab.Intern("INTEGER");
  idBoolean  := StrTab.Intern("BOOLEAN");
  idChar     := StrTab.Intern("CHAR");
  idByte     := StrTab.Intern("BYTE");
  idWord     := StrTab.Intern("WORD");
  idLongint  := StrTab.Intern("LONGINT");
  idReal     := StrTab.Intern("REAL");
  idLongreal := StrTab.Intern("LONGREAL");
  idSet      := StrTab.Intern("SET");
  idAddress  := StrTab.Intern("ADDRESS");

  (* FLOAT is a synonym for REAL *)
  s := SymNew("FLOAT", KType);
  s.type := TypeReal;

  PredefConst("TRUE",  1, TypeBoolean);
  PredefConst("FALSE", 0, TypeBoolean);
  PredefConst("NIL",   0, TypeNiltype);

  PredefSysProc("NEW",     SpNew);
  PredefSysProc("INC",     SpInc);
  PredefSysProc("DEC",     SpDec);
  PredefSysProc("LEN",     SpLen);
  PredefSysProc("ODD",     SpOdd);
  PredefSysProc("ABS",     SpAbs);
  PredefSysProc("ASSERT",  SpAssert);
  PredefSysProc("COPY",    SpCopy);
  PredefSysProc("ORD",     SpOrd);
  PredefSysProc("CHR",     SpChr);
  PredefSysProc("FLOOR",   SpFloor);
  PredefSysProc("ENTIER",  SpFloor);
  PredefSysProc("DISPOSE", SpDispose);
  PredefSysProc("SIZE",    SpSize);

  PredefSysProc("SYSTEM.LSL",  SpLsl);
  PredefSysProc("SYSTEM.LSR",  SpLsr);
  PredefSysProc("SYSTEM.ASR",  SpAsr);
  PredefSysProc("SYSTEM.ROR",  SpRor);
  PredefSysProc("SYSTEM.AND",  SpAnd);
  PredefSysProc("SYSTEM.IOR",  SpIor);
  PredefSysProc("SYSTEM.XOR",  SpXor);

  s := SymNew("SYSTEM", KImport);
  s.modId := StrTab.Intern("SYSTEM");

  SymOpenScope()   (* open module scope, level 0 *)
END SymInit;

(* Persistent instrumentation: per-module peak arena sizes and type-form
   histogram, printed once per compile at SymsFree (DEBUG level). *)
PROCEDURE StatsDump;
  VAR i: WORD; t: TypeDesc; m: ARRAY 160 OF CHAR;
      nArr, nProc, nRec, nPtr, nOther: INTEGER;
BEGIN
  IF ~LogErr.IsDebug() THEN RETURN END;
  IF typeCount = 0 THEN RETURN END;
  nArr := 0; nProc := 0; nRec := 0; nPtr := 0; nOther := 0;
  i := 0;
  WHILE i < typeCount DO
    t := TypeSlotPtr(i);
    IF t.form = TFArray THEN INC(nArr)
    ELSIF t.form = TFProc THEN INC(nProc)
    ELSIF t.form = TFRecord THEN INC(nRec)
    ELSIF t.form = TFPointer THEN INC(nPtr)
    ELSE INC(nOther) END;
    INC(i)
  END;
  m := "SYMSTAT syms=";
  Strings.AppendInt(LONGINT(symCount), m);
  Strings.Append(" types=", m);  Strings.AppendInt(LONGINT(typeCount), m);
  Strings.Append(" arr=", m);    Strings.AppendInt(LONGINT(nArr), m);
  Strings.Append(" proc=", m);   Strings.AppendInt(LONGINT(nProc), m);
  Strings.Append(" rec=", m);    Strings.AppendInt(LONGINT(nRec), m);
  Strings.Append(" ptr=", m);    Strings.AppendInt(LONGINT(nPtr), m);
  Strings.Append(" other=", m);  Strings.AppendInt(LONGINT(nOther), m);
  Strings.Append(" strtab=", m); Strings.AppendInt(LONGINT(StrTab.Count()), m);
  Strings.Append(" strtabKB=", m);
  Strings.AppendInt((StrTab.MemBytes() + LONGINT(1023)) DIV LONGINT(1024), m);
  (* allocated vs actually-used text: the difference is per-chunk tail waste *)
  Strings.Append(" strtabTextUsed=", m);
  Strings.AppendInt(StrTab.TextUsed(), m);
  LogErr.Debug(m)
END StatsDump;

(* Release the symbol table: DISPOSE all arena chunks plus the heap nodes hung
   off records (InlineNode / FwdNode lists) and every scope ever opened.
   Every Symbol/TypeDesc pointer becomes invalid. *)
PROCEDURE SymsFree*;
  VAR il, iln: InlineNode; fp, fpn: FwdNode; sc, scn: Scope;
BEGIN
  StatsDump;
  FreeChunks;
  TopScope := NIL; Universe := NIL;
  il := allInline; WHILE il # NIL DO iln := il^.allNext; DISPOSE(il); il := iln END;
  allInline := NIL;
  fp := allFwd; WHILE fp # NIL DO fpn := fp^.allNext; DISPOSE(fp); fp := fpn END;
  allFwd := NIL;
  sc := allScopes; WHILE sc # NIL DO scn := sc^.allNext; DISPOSE(sc); sc := scn END;
  allScopes := NIL;
  StrTab.Reset   (* release the interning table (zero-leak) *)
END SymsFree;

(* RawInit: the module's own one-time init, moved out of a BEGIN block so
   this module can be $O+ (DOCS/OVR.MD §4 forbids a BEGIN block on an
   overlay-eligible module -- same move as PStmt.RawInit/Parser.RawInit).
   NoSym/NoType/symDir/typeDir/symCount/typeCount are all genuinely
   one-time: every real per-compile reset of the chunk directories and
   counts already happens in FreeChunks (called from SymsFree, once per
   compile), which zeroes exactly these same fields back to their BEGIN-
   block starting state -- this call exists only to give them THAT
   starting state before the very first SymInit/FreeChunks cycle ever
   runs (the runtime does not zero module globals).  symOom/typeOom are
   the one genuinely load-bearing one-time allocation (the OOM fallback
   nodes AllocSym/AllocType hand out), same shape as PStmt's own
   bpOomNode.  Called once from TocMain.Run, mirroring PStmt.RawInit's
   own call site (before any real parsing starts). *)
BEGIN
  NoSym := NIL; NoType := NIL;
  symCount := 0; typeCount := 0;
  bodyI := 0; WHILE bodyI < MaxSymChunks  DO symDir[bodyI]  := NIL; INC(bodyI) END;
  bodyI := 0; WHILE bodyI < MaxTypeChunks DO typeDir[bodyI] := NIL; INC(bodyI) END;
  (* the runtime does NOT zero globals — the dedup index must be emptied
     explicitly before the first TypeNewArray/TypeNewPointer can probe it *)
  TypeHashReset;
  NEW(symOom); NEW(typeOom);
  IF (symOom = NIL) OR (typeOom = NIL) THEN
    (* The OOM fallback nodes themselves failed to allocate at startup: latch
       now so the first compile dies cleanly instead of NIL-dereferencing the
       fallback later.  (LogErr's body has already run — Syms imports it.) *)
    LogErr.Error("out of memory (symbol-table init)")
  END
END Syms.
