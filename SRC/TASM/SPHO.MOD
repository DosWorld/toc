(*$M 32000,192000,650000*)
MODULE SPHO;
(* spho -- SPHINX Oberon dialect translator: SRCFILE.SMD -> SRCFILE.ASM
   (NASM-subset, feed into TASM.EXE). Single recursive-descent pass, no
   AST: each Parse* procedure both parses its construct and emits its
   NASM text before returning. Full design notes: DOCS/SPHO.MD. *)
IMPORT Out, Dos, Files, Strings, LogErr, Lex, Scan, StrTab;

CONST
  ExitOk = 0; ExitUsage = 2; ExitIo = 3; ExitAsm = 4;

  MaxTok = 64; MaxLine = 256;
  (* MaxName: every identifier-name storage buffer uses this, not a
     disconnected literal 32 -- BUG B3's lesson (SYM.MOD's own header
     comment): a smaller separate bound than the scanner's own MaxTok-1
     silently truncates a long identifier, letting two distinct names
     sharing a common prefix alias to the same stored/interned symbol. *)
  MaxName = MaxTok;
  (* MaxStrLit: tokText/outerTokText's own declared size -- wider than
     MaxTok on purpose. A double-quoted string literal (DOCS/SPHINX.MD
     §3.3: "any length") is scanned into tokText the same as any other
     token, but identifiers/numbers have their own legitimate reason to
     stay bounded at MaxTok (matching SCAN.MOD's own MaxIdent) -- only
     the buffer's declared capacity grows here, the identifier/number
     scan loops in Next still bound themselves at MaxTok-1 exactly as
     before (harmless: tokText has room to spare for them), so this
     doesn't relax any other token kind's own length limit, only a
     string literal's. Previously tokText was ARRAY MaxTok (64) OF CHAR
     for every token kind including TStr, silently truncating any
     literal past 63 characters with no error at all -- reproduced
     directly with a literal longer than that. *)
  MaxStrLit = MaxLine;

  (* token kinds -- TStr (double-quoted "...", any length including 0/1
     chars) is a genuine string literal, needing a .data label; TChar
     (single-quoted '...', always exactly one character) is a plain
     numeric CHAR immediate (its ORD value), the same distinction NASM
     itself makes between a quoted string operand and a character
     literal. Previously both quote styles scanned identically into one
     TStr kind with no way to tell them apart. *)
  TEof = 0; TIdent = 1; TNum = 2; TStr = 3; TSym = 4; TChar = 5;

  (* type kinds *)
  TyByte = 0; TyBool = 1; TyWord = 2; TyInt = 3; TyLong = 4; TyRec = 5;

  (* symbol-table entry kinds -- VAR and CONST share one identifier
     namespace (both are referenced as a bare operand name), so they
     share one table; TYPE is a separate namespace in real Oberon
     (TYPE Point and VAR Point don't collide) and stays its own table. *)
  SymVar = 0; SymConst = 1;

  (* LexemeArray kinds -- see the "unified lexeme table" block below.
     Every keyword, symbol, register, TYPE, PROCEDURE, CONST, and VAR
     name in the whole file lives in ONE chunked list (lexHead), each row
     uniform (nameId/kind/ref); `kind` picks which of these seven this
     row is, `ref` means something different per kind (see LexAppend's
     own header comment). *)
  LexKw = 0; LexSym = 1; LexReg = 2; LexType = 3; LexProc = 4;
  LexConst = 5; LexVar = 6;

  (* Kw* -- hand-numbered id for every keyword SPHO recognizes (LexKw rows'
     own `ref`). Alphabetical, arbitrary numbering -- nothing outside
     RegisterBuiltins/tokLex dispatch ever needs a particular value, only
     identity (kind=LexKw & ref=KwXxx). *)
  KwAsm = 0; KwBegin = 1; KwBoolean = 2; KwBreak = 3; KwByte = 4;
  KwConst = 5; KwContinue = 6; KwDec = 7; KwDo = 8; KwElse = 9;
  KwElsif = 10; KwEnd = 11; KwFar = 12; KwForward = 13; KwIf = 14;
  KwImport = 15; KwInc = 16; KwInt = 17; KwInteger = 18; KwInterrupt = 19;
  KwLongint = 20; KwModule = 21; KwNear = 22; KwPop = 23; KwProcedure = 24;
  KwPush = 25; KwRecord = 26; KwReg = 27; KwReturn = 28; KwShl = 29;
  KwShr = 30; KwThen = 31; KwType = 32; KwUses = 33;
  KwVar = 34; KwWhile = 35; KwWord = 36; KwXor = 37;

  (* Sy* -- hand-numbered id for every symbol (LexSym rows' own `ref`),
     including the five relational symbols (#,<,>,<=,>=) which are given
     ids for uniformity but are never looked up via tokLex -- IsRelSym/
     RelJumps/OpInstr keep reading tokText directly, unchanged. *)
  SyAmp = 0; SyLParen = 1; SyRParen = 2; SyStar = 3; SyPlus = 4;
  SyComma = 5; SyMinus = 6; SyDot = 7; SyColon = 8; SyAssign = 9;
  SySemi = 10; SyEq = 11; SyLBrack = 12; SyRBrack = 13; SyBar = 14;
  SyTilde = 15; SyNe = 16; SyLt = 17; SyGt = 18; SyLe = 19; SyGe = 20;

  (* NKw/NSy: keyword/symbol counts -- one past the last Kw*/Sy* id above.
     kwSpellings/sySpellings (below) hold exactly this many entries,
     index i <-> id i; adding a new keyword/symbol means appending one
     more Kw*/Sy* CONST, bumping this count, and adding its spelling to
     the matching InitKwSyTables assignment -- ONE place, not the old
     two-place (KwIdOf's own dispatch chain + RegisterBuiltins' seeding
     call) duplication. *)
  NKw = 38; NSy = 21;

  (* global VAR section: an initialized declaration ("= value", a real
     stored value) belongs in .data; every uninitialized global -- a
     plain scalar (no "= value"), an array, or a RECORD instance -- is
     zero-filled reserved space and must be in .bss (TASM also rejects
     RESB/RESW/RESD outside .bss: "only valid in SECTION .bss"; a plain
     uninitialized scalar could still be written as "dw 0" in .data, but
     that wastes a stored zero byte/word/dword in the image for no
     benefit over .bss's own reservation). SectCode is .text, where
     every PROCEDURE body belongs. SectNone (-1, curSect's own initial
     value) is not a real section id, only EnsureSection's "nothing
     emitted yet" sentinel -- no code assumes an implicit default
     section anymore; every section-dependent emission site calls
     EnsureSection first. *)
  SectNone = -1; SectData = 0; SectBss = 1; SectCode = 2;

  MaxFields = 24; MaxParams = 16; MaxUses = 8;

  (* symbols/types are unbounded (CLAUDE.md "Chunk small records"):
     chunked linked lists of Chunk-sized parallel-array nodes, names
     StrTab-interned (CLAUDE.md "StrTab adoption pattern") instead of a
     fixed-size flat array of ARRAY OF CHAR records. MaxFields/MaxParams/
     MaxUses stay fixed-size: each bounds a single declaration's own
     field/param/register list, not an accumulate-over-the-whole-file
     count. *)
  Chunk = 64;

  (* MaxDetailChunks: the four small LexemeArray detail tables (Type/
     Proc/Const/Var) are a fixed-size DIRECTORY of Chunk-sized blocks
     (ARRAY MaxDetailChunks OF pointer-to-block), not a linked list --
     same shape StrTab.MOD's own textDir/entDir already use (CLAUDE.md
     "StrTab adoption pattern"). A directory slot is O(1) to reach
     (ref DIV Chunk indexes straight into it) instead of an O(n/Chunk)
     next-pointer hop, and it collapses what would otherwise be four
     near-identical "walk the linked list" navigator procedures into
     one shared DetailBlock/DetailChunkFor pattern. 64 blocks * 64
     entries/block = 4096 TYPE/PROCEDURE/CONST/VAR declarations per
     kind, far past any real SPHINX Oberon source file's scale. *)
  MaxDetailChunks = 64;

  (* LexBuckets: FindLexeme (called once per token, from Next) used to be
     an O(nLex) backward linear scan over the WHOLE LexemeArray -- every
     keyword/symbol/register lookup paid for walking past every user
     CONST/TYPE/PROCEDURE/VAR declared so far, not just the ~80 built-ins.
     lexBuckets[nameId MOD LexBuckets] heads a most-recent-first chain
     (each row's own hnext field, mirroring StrTab.MOD's own bucket-chain
     shape) of every lexeme row sharing that nameId -- FindLexeme now
     walks one bucket's chain (typically 0-1 entries; a genuine shadow
     redeclaration is the only way a chain has 2+) instead of the entire
     array. nameId is already a dense small StrTab.TStrTabId, so a plain
     MOD is a fine hash with no separate hash-code computation needed. *)
  LexBuckets = 64;

TYPE
  (* fixed-size (not open) array-of-strings: an open ARRAY OF ARRAY OF CHAR
     element has no statically-known LEN, so Strings.Copy's VAR dst can't
     be resolved through it -- pass this concrete type instead. *)
  RegList = ARRAY MaxUses OF ARRAY 32 OF CHAR;
  FieldDef = RECORD nameId: StrTab.TStrTabId; ty: INTEGER; recIdx: INTEGER END;

  (* LexChunk: ONE unified chunked table for every lexeme in the file --
     keyword, symbol, register, TYPE name, PROCEDURE name, CONST name, VAR
     name -- each row uniform (nameId/kind/ref). `kind` is one of
     LexKw/LexSym/LexReg/LexType/LexProc/LexConst/LexVar; `ref`'s meaning
     depends on kind:
       LexKw/LexSym  -- the hand-numbered Kw*/Sy* id (identity only,
                        nothing else is ever asked of a keyword/symbol row)
       LexReg        -- Lex.RegAX..Lex.RegDS directly, no separate
                        numbering of its own
       LexType       -- index into typeDir (TypeChunk, below)
       LexProc       -- index into procDir (ProcChunk, below)
       LexConst      -- index into constDir (ConstChunk, below)
       LexVar        -- index into varDir (VarChunk, below)
     This replaces the four separate SymChunk(VAR/CONST)/TypeChunk/
     ProcChunk lookup tables plus the ad-hoc string-literal IsKw/IsSym/
     IsRegName checks with one lookup shape: FindLexeme searches this list
     backward (most-recent wins, same shadowing semantics FindSym/FindType/
     ProcFindIsFar always had), and every other kind of identity check
     (IsKw/IsSym/IsRegName) becomes a comparison against tokLex's already-
     resolved kind/ref instead of a fresh string compare. hnext chains
     this row into lexBuckets[nameId MOD LexBuckets] (LexBuckets's own
     header comment) -- -1 marks the end of a chain (0 is a valid
     LexemeArray index, so it can't double as the sentinel the way
     StrTab.MOD's own 1-based ids let hnext=0 mean "end"). *)
  LexChunk = POINTER TO LexChunkDesc;
  LexChunkDesc = RECORD
    nameId: ARRAY Chunk OF StrTab.TStrTabId;
    kind:   ARRAY Chunk OF INTEGER;
    ref:    ARRAY Chunk OF INTEGER;
    hnext:  ARRAY Chunk OF INTEGER;
    count:  INTEGER;
    next:   LexChunk
  END;

  (* TypeChunk: LexType detail table -- one block of Chunk TYPE entries,
     addressed via typeDir[ref DIV Chunk] (see MaxDetailChunks). nameId
     is kept here too (as well as on the LexemeArray row) purely so
     TypeName can do the same O(1) "block index, then array index"
     lookup every other *Name accessor already does, instead of a linear
     scan over the whole LexemeArray to find the one row whose
     kind=LexType & ref=ti. *)
  TypeChunk = POINTER TO TypeChunkDesc;
  TypeChunkDesc = RECORD
    nameId:  ARRAY Chunk OF StrTab.TStrTabId;
    aliasTy: ARRAY Chunk OF INTEGER;   (* TyRec for a real RECORD type (see
                                          fields/nFields below); otherwise
                                          the scalar base type of a non-
                                          RECORD alias (TYPE Foo = LONGINT;
                                          SPHINX.MD has no other TYPE form),
                                          which has no fields of its own. *)
    nFields: ARRAY Chunk OF INTEGER;
    fields: ARRAY Chunk OF ARRAY MaxFields OF FieldDef  (* per-type field list stays fixed-size *)
  END;

  (* ProcChunk: LexProc detail table -- one block of Chunk PROCEDURE
     entries, addressed via procDir[ref DIV Chunk]. EmitCall needs isFar
     to pick `call` vs `call far` (SPHINX.MD §6.3) -- a bare `call`
     always assembles as a same-module NEAR call regardless of the
     callee's own FAR-ness (DOCS/TASM.MD §3), so guessing wrong corrupts
     the stack on return either direction (near call + far ret pops 2
     bytes too many; far call + near ret leaves a stale segment word
     behind). *)
  ProcChunk = POINTER TO ProcChunkDesc;
  ProcChunkDesc = RECORD
    isFar: ARRAY Chunk OF BOOLEAN;
    valid: ARRAY Chunk OF BOOLEAN;  (* FALSE for an INTERRUPT procedure's
                                       own reserved row -- ProcFindIsFar
                                       must still report "not found" for
                                       it, exactly matching the old
                                       behavior of never adding an
                                       INTERRUPT procedure to procDir at
                                       all (its name isn't a valid
                                       `call`/`call far` target). ALSO
                                       FALSE for a FORWARD-declared row
                                       until its real body is parsed --
                                       but unlike INTERRUPT, isFar[] IS
                                       already trustworthy for a FORWARD
                                       row (see isFwdKnown below), so
                                       ProcFindIsFar's own valid-only gate
                                       does not apply to it. *)
    isFwdKnown: ARRAY Chunk OF BOOLEAN  (* TRUE only for a FORWARD-
                                       declared row whose isFar[] is
                                       already known and safe for a call
                                       site to trust, even though valid[]
                                       is still FALSE (no body yet).
                                       ProcFindAny's own isValid result
                                       (duplicate-definition detection)
                                       reads valid[], never this -- the
                                       two questions ("can a call site
                                       trust isFar[] right now" vs. "is
                                       this a real, callable definition
                                       yet") are answered independently. *)
  END;

  (* LitChunk: every distinct string literal seen so far, in first-
     occurrence order -- StrTab itself is shared with every identifier
     name in this file (LexChunk's own nameId field), so it has no notion
     of "which ids are literals" on its own; this is the separate list
     that tracks exactly that, letting RunBody emit one ".data" line per
     distinct literal at the very end (the user's own requested
     "_literalNNNN: db 'literal', 0" table). No SPHINX construct ever
     references a literal's own text back by name, so literals stay OUT
     of the unified LexemeArray entirely -- LitChunk is not a `kind` of
     lexeme, it's a separate append-only list. StrTab.Intern/Find already
     dedups by exact content (never case-folded, unlike the identifier
     tables that share the same underlying store -- literal bytes are
     stored and compared exactly as written), so EmitStringLiteral only
     appends an id here the first time it's seen; a repeated literal
     reuses the same id and therefore the same label. *)
  LitChunk = POINTER TO LitChunkDesc;
  LitChunkDesc = RECORD
    id:    ARRAY Chunk OF StrTab.TStrTabId;
    count: INTEGER;
    next:  LitChunk
  END;

  (* PendingChunk: every call site emitted against a procedure name not
     yet resolvable (ProcFindIsFar returned FALSE -- no PROCEDURE with
     this name parsed so far, and no FORWARD declaration for it either),
     in first-occurrence order. EmitCall/EmitCallNoArgs record one entry
     per such call (name + source line, for a useful error message) and
     default to a FAR call exactly as before -- unchanged for the common
     case where the name IS defined later in the file without a FORWARD
     (e.g. calling a procedure that will turn out to be FAR anyway, or
     one whose caller comes after it in file order and never hits this
     path at all). CheckPendingCalls (end of RunBody, after every
     PROCEDURE has been parsed) re-resolves each recorded name: still
     unresolved AND never FORWARD-declared is now a hard translator
     error (a forward call to a NEAR procedure with no FORWARD line
     silently corrupts the stack via a wrong FAR call -- reproduced
     directly, see DOCS/SPHO.MD "FORWARD declarations"), instead of the
     old silent FAR-call guess. *)
  PendingChunk = POINTER TO PendingChunkDesc;
  PendingChunkDesc = RECORD
    id:    ARRAY Chunk OF StrTab.TStrTabId;
    line:  ARRAY Chunk OF INTEGER;
    count: INTEGER;
    next:  PendingChunk
  END;

  (* ConstChunk: LexConst detail table -- one block of Chunk CONST
     entries (just the value; CONST/VAR no longer share a table now that
     LexConst/LexVar are simply different LexemeArray row kinds),
     addressed via constDir[ref DIV Chunk]. *)
  ConstChunk = POINTER TO ConstChunkDesc;
  ConstChunkDesc = RECORD
    val: ARRAY Chunk OF LONGINT
  END;

  (* VarChunk: LexVar detail table -- one block of Chunk VAR/param
     entries (everything about one except its own name/kind, which live
     on the LexemeArray row instead), addressed via varDir[ref DIV Chunk]. *)
  VarChunk = POINTER TO VarChunkDesc;
  VarChunkDesc = RECORD
    ty:      ARRAY Chunk OF INTEGER;        (* TyByte..TyRec *)
    recIdx:  ARRAY Chunk OF INTEGER;        (* index into types[], if ty = TyRec *)
    isLocal: ARRAY Chunk OF BOOLEAN;
    ofs:     ARRAY Chunk OF INTEGER;        (* [bp-ofs] if local, meaningless if isReg *)
    isParam: ARRAY Chunk OF BOOLEAN;
    isReg:   ARRAY Chunk OF BOOLEAN         (* a register-named param (SPHINX.MD §6.2):
                                                accessed by register name directly, no
                                                frame slot at all -- ofs=0 alone can't
                                                distinguish this from a genuine [bp-0]
                                                (which never legitimately occurs, since
                                                the first real local starts at offset 2,
                                                but the ambiguity is exactly the bug this
                                                flag fixes). *)
  END;

VAR
  (* kwSpellings/sySpellings: the ONE enumeration of every keyword's/
     symbol's spelling <-> Kw*/Sy* id, filled once by InitKwSyTables.
     KwIdOf/SyIdOf (linear search) and RegisterBuiltins (seeding) both
     read these instead of each separately hand-listing all 39+21 names
     -- see NKw/NSy's own header comment. *)
  kwSpellings: ARRAY NKw OF ARRAY 16 OF CHAR;
  sySpellings: ARRAY NSy OF ARRAY 4 OF CHAR;

  (* Streamed source (mirrors SCAN.MOD's own NextCh): no whole-file RAM
     buffer, so files aren't size-limited. IMPORT switches srcF to the
     included file; outerF/outerCh/outerLine resume the includer after
     (single level only, see DOCS/SPHO.MD). *)
  srcF: Files.File;
  ch, ch2: CHAR;    (* ch2 is one-char-further lookahead, for := / <= / >= / comment-open *)
  line: INTEGER;
  srcPath: ARRAY 128 OF CHAR;

  outerF: Files.File;
  outerCh, outerCh2: CHAR;
  outerLine: INTEGER;
  (* the already-fetched current token at the IMPORT site (e.g. ";")
     must also be saved/restored -- ch/ch2 are always one token ahead of
     it in the raw stream, so re-Next-ing after CloseInclude would skip
     past it instead of re-seeing it. *)
  outerTokKind: INTEGER;
  outerTokText: ARRAY MaxStrLit OF CHAR;
  outerTokLex: INTEGER;

  tokKind: INTEGER;
  tokText: ARRAY MaxStrLit OF CHAR;
  tokVal: LONGINT;
  tokLex: INTEGER;         (* resolved LexemeArray index of the current
                               token, for TIdent/TSym only (-1 for
                               TNum/TStr/TChar/TEof, which never name a
                               lexeme) -- set by Next via FindLexeme. *)

  outF: Files.File;

  lexHead, lexTail: LexChunk;
  nLex: INTEGER;           (* CONST/TYPE/PROCEDURE/keyword/symbol/register
                               entries (module-global, added before any
                               PROCEDURE, or once at startup for kw/sym/reg)
                               followed by VAR globals, then each
                               procedure's own locals/params appended and
                               truncated back off via LexTruncate *)
  lexBuckets: ARRAY LexBuckets OF INTEGER;  (* LexBuckets's own header
                               comment -- lexBuckets[nameId MOD LexBuckets]
                               heads a most-recent-first hnext chain; -1 =
                               empty bucket *)

  (* typeDir/procDir/constDir/varDir: fixed-size directories of Chunk-
     sized detail blocks (MaxDetailChunks's own header comment) -- a
     fresh block is NEW'd into typeDir[nTypes DIV Chunk] etc. only when
     the running count crosses a Chunk boundary; nTypes/nProcs/nConsts/
     nVars is both "how many entries exist" and (via DIV/MOD Chunk)
     "where the next one goes". Array elements not yet reached stay NIL
     (module-body init below) -- FreeChunks DISPOSEs exactly the ones
     that were ever allocated. *)
  typeDir: ARRAY MaxDetailChunks OF TypeChunk;
  nTypes: INTEGER;

  procDir: ARRAY MaxDetailChunks OF ProcChunk;
  nProcs: INTEGER;

  constDir: ARRAY MaxDetailChunks OF ConstChunk;
  nConsts: INTEGER;

  varDir: ARRAY MaxDetailChunks OF VarChunk;
  nVars: INTEGER;

  litHead, litTail: LitChunk;
  nLits: INTEGER;

  pendingHead, pendingTail: PendingChunk;
  nPending: INTEGER;

  labelCnt: INTEGER;
  loopExitStack: ARRAY 16 OF INTEGER;  (* label ids for BREAK targets *)
  loopContStack: ARRAY 16 OF INTEGER;  (* label ids for CONTINUE targets *)
  loopDepth: INTEGER;
  procExitLbl: INTEGER;    (* current procedure's single epilogue label --
                               RETURN jumps here instead of falling through
                               the rest of the body (see ParseReturn's own
                               header comment). No save/restore stack needed:
                               SPHINX has no nested PROCEDURE declarations,
                               so only one procedure body is ever mid-parse
                               at a time. *)

  frameOfs: INTEGER;       (* running local-frame byte offset while parsing VAR of a proc *)
  ok: BOOLEAN;             (* sticky success flag *)
  curSect: INTEGER;        (* SectData/SectBss/SectCode -- which section was
                               emitted last, so EnsureSection only switches
                               when it actually changes (SECTION is freely
                               re-enterable in TASM, but re-emitting an
                               unchanged one is just noise). Starts (and is
                               reset per file, RunBody) at SectNone: there is
                               no default/assumed section -- every emission
                               site that needs one calls EnsureSection first,
                               so the very first "section .xxx" line in the
                               output always comes from an explicit call,
                               never a hardcoded top-of-file emission. *)

(* ---------------- unified lexeme table + its small detail tables ---------------- *)

(* LexChunkFor: navigate li (a slot index into the whole lexHead list,
   0-based, dense) to its owning chunk node + in-chunk offset. li is
   always < nLex, and nLex never exceeds Chunk*(chunks allocated), so
   this always finds a node. *)
PROCEDURE LexChunkFor(li: INTEGER; VAR c: LexChunk; VAR k: INTEGER);
BEGIN
  c := lexHead;
  WHILE li >= Chunk DO c := c^.next; DEC(li, Chunk) END;
  k := li
END LexChunkFor;

(* LexAppendRaw: intern nm and add a fresh (kind,ref) row at the end of
   lexHead (growing it if the tail chunk is full or absent), returning its
   li. Shared by every LexAppend* wrapper below -- the one place that
   knows how to grow the chunked list itself. Also links the new row onto
   the HEAD of its own nameId's bucket chain (LexBuckets's own header
   comment) -- pushing onto the head, not the tail, is what gives
   FindLexeme its most-recent-wins shadowing order for free: walking a
   bucket chain from its head visits the innermost (most recently
   appended) declaration of that spelling first, exactly matching the
   old whole-array backward scan's own order. *)
PROCEDURE LexAppendRaw(nm: ARRAY OF CHAR; kind, ref: INTEGER): INTEGER;
  VAR last: LexChunk; li, k: INTEGER; id: StrTab.TStrTabId; b: INTEGER;
BEGIN
  IF (lexTail = NIL) OR (lexTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("spho: out of memory (lexeme table)"); ok := FALSE; RETURN nLex END;
    last^.count := 0; last^.next := NIL;
    IF lexHead = NIL THEN lexHead := last ELSE lexTail^.next := last END;
    lexTail := last
  END;
  li := nLex; INC(nLex);
  LexChunkFor(li, last, k);
  id := StrTab.Intern(nm);
  last^.nameId[k] := id;
  last^.kind[k] := kind;
  last^.ref[k] := ref;
  last^.count := k + 1;
  b := INTEGER(id) MOD LexBuckets;
  last^.hnext[k] := lexBuckets[b];
  lexBuckets[b] := li;
  RETURN li
END LexAppendRaw;

(* LexTruncate: shrink nLex back to savedLex after a procedure's own
   locals/params go out of scope (ParseProcedure's save/restore
   watermark), AND unlink every row in [savedLex,nLex) from its own
   bucket chain -- without this, FindLexeme's bucket walk would still
   find a truncated (logically gone) row by id, even though the old
   whole-array scan naturally stopped seeing it once it was past nLex-1.
   Cheap: the truncated range is always one procedure's own locals/
   params, never the whole file, and each row's chain position is found
   by walking from its bucket head (no back-pointer is kept, same
   trade-off StrTab.MOD's own singly-linked hnext chains make). Trailing
   LexChunk nodes are kept allocated (not DISPOSEd) -- LexAppendRaw will
   simply overwrite their slots on the next procedure, exactly matching
   the old flat-array's truncate-in-place behavior. CONST/TYPE/PROCEDURE
   entries (and the seeded keyword/symbol/register rows) are always
   added at module scope before any PROCEDURE, so they're never inside a
   truncated range. *)
PROCEDURE LexTruncate(savedLex: INTEGER);
  VAR li, b, cur, prevLi: INTEGER; c, pc: LexChunk; k, pk: INTEGER;
BEGIN
  li := savedLex;
  WHILE li < nLex DO
    LexChunkFor(li, c, k);
    b := INTEGER(c^.nameId[k]) MOD LexBuckets;
    IF lexBuckets[b] = li THEN
      lexBuckets[b] := c^.hnext[k]
    ELSE
      prevLi := lexBuckets[b];
      LexChunkFor(prevLi, pc, pk);
      cur := pc^.hnext[pk];
      WHILE cur # li DO
        prevLi := cur; LexChunkFor(prevLi, pc, pk); cur := pc^.hnext[pk]
      END;
      pc^.hnext[pk] := c^.hnext[k]
    END;
    INC(li)
  END;
  nLex := savedLex
END LexTruncate;

(* FindLexeme: walk nm's own bucket chain (LexBuckets's own header
   comment) from its head -- most-recent-appended-first, so shadowing
   (a local hiding an earlier global/outer declaration of the same
   spelling) resolves correctly with no explicit backward search needed;
   the bucket chain's own head-insertion order already IS that order.
   Every kind shares this one lookup (keyword, symbol, register, TYPE,
   PROCEDURE, CONST, VAR). *)
PROCEDURE FindLexeme(nm: ARRAY OF CHAR): INTEGER;
  VAR id: StrTab.TStrTabId; c: LexChunk; k, li: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  IF id = 0 THEN RETURN -1 END;
  li := lexBuckets[INTEGER(id) MOD LexBuckets];
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF c^.nameId[k] = id THEN RETURN li END;
    li := c^.hnext[k]
  END;
  RETURN -1
END FindLexeme;

PROCEDURE LexKind(li: INTEGER): INTEGER;
  VAR c: LexChunk; k: INTEGER;
BEGIN LexChunkFor(li, c, k); RETURN c^.kind[k]
END LexKind;

PROCEDURE LexRef(li: INTEGER): INTEGER;
  VAR c: LexChunk; k: INTEGER;
BEGIN LexChunkFor(li, c, k); RETURN c^.ref[k]
END LexRef;

PROCEDURE LexName(li: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR c: LexChunk; k: INTEGER;
BEGIN LexChunkFor(li, c, k); StrTab.Get(c^.nameId[k], dst)
END LexName;

(* ---- CONST detail table (LexConst rows) ---- *)

(* ConstChunkFor: ci's owning directory block + in-block offset -- a
   plain DIV/MOD Chunk index into constDir (MaxDetailChunks's own header
   comment), O(1) instead of the old linked-list next-hop. *)
PROCEDURE ConstChunkFor(ci: INTEGER; VAR c: ConstChunk; VAR k: INTEGER);
BEGIN c := constDir[ci DIV Chunk]; k := ci MOD Chunk
END ConstChunkFor;

(* ConstAppend: intern nm as a fresh LexConst lexeme row (ref = its own
   ConstChunk slot index) and return the LexemeArray index (si), the same
   contract SymAppend(nm, SymConst) used to have. Caller fills val
   afterward via SymSetVal. NEWs a fresh constDir block only when ci is
   about to cross into one that hasn't been allocated yet. *)
PROCEDURE ConstAppend(nm: ARRAY OF CHAR): INTEGER;
  VAR ci, bi, si: INTEGER;
BEGIN
  ci := nConsts; INC(nConsts);
  bi := ci DIV Chunk;
  IF constDir[bi] = NIL THEN
    NEW(constDir[bi]);
    IF constDir[bi] = NIL THEN LogErr.Error("spho: out of memory (const table)"); ok := FALSE; RETURN LexAppendRaw(nm, LexConst, 0) END
  END;
  si := LexAppendRaw(nm, LexConst, ci);
  RETURN si
END ConstAppend;

(* ---- VAR detail table (LexVar rows) ---- *)

(* VarChunkFor: vi's owning directory block + in-block offset -- same
   O(1) DIV/MOD Chunk index as ConstChunkFor, into varDir. *)
PROCEDURE VarChunkFor(vi: INTEGER; VAR c: VarChunk; VAR k: INTEGER);
BEGIN c := varDir[vi DIV Chunk]; k := vi MOD Chunk
END VarChunkFor;

(* VarAppend: intern nm as a fresh LexVar lexeme row (ref = its own
   VarChunk slot index) and return the LexemeArray index (si), the same
   contract SymAppend(nm, SymVar) used to have. Caller fills the rest
   (ty/recIdx/isLocal/ofs/isParam) afterward. *)
PROCEDURE VarAppend(nm: ARRAY OF CHAR): INTEGER;
  VAR vi, bi, k, si: INTEGER; last: VarChunk;
BEGIN
  vi := nVars; INC(nVars);
  bi := vi DIV Chunk;
  IF varDir[bi] = NIL THEN
    NEW(varDir[bi]);
    IF varDir[bi] = NIL THEN LogErr.Error("spho: out of memory (var table)"); ok := FALSE; RETURN LexAppendRaw(nm, LexVar, 0) END
  END;
  si := LexAppendRaw(nm, LexVar, vi);
  VarChunkFor(vi, last, k);
  last^.isReg[k] := FALSE;   (* NEW'd chunks are not zeroed -- explicit default *)
  RETURN si
END VarAppend;

(* ---- SymXxx accessors: si is a LexemeArray index whose row kind is
   LexConst or LexVar (never checked here -- callers only ever pass an si
   that FindSym/SymAppend variants already established as one of those two
   kinds, exactly like the old shared-SymChunk API's own contract). Kept
   as the same-named wrapper procedures every existing call site already
   uses, now routed through LexRef into the small ConstChunk/VarChunk
   detail tables instead of a shared SymChunk row. ---- *)

PROCEDURE SymName(si: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN LexName(si, dst)
END SymName;

PROCEDURE SymKind(si: INTEGER): INTEGER;
  VAR k: INTEGER;
BEGIN
  k := LexKind(si);
  IF k = LexConst THEN RETURN SymConst ELSE RETURN SymVar END
END SymKind;

PROCEDURE SymTy(si: INTEGER): INTEGER;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.ty[k]
END SymTy;

PROCEDURE SymSetTy(si, ty, recIdx: INTEGER);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.ty[k] := ty; c^.recIdx[k] := recIdx
END SymSetTy;

PROCEDURE SymIsLocal(si: INTEGER): BOOLEAN;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.isLocal[k]
END SymIsLocal;

PROCEDURE SymSetIsLocal(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isLocal[k] := v
END SymSetIsLocal;

PROCEDURE SymOfs(si: INTEGER): INTEGER;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.ofs[k]
END SymOfs;

PROCEDURE SymSetOfs(si, ofs: INTEGER);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.ofs[k] := ofs
END SymSetOfs;

PROCEDURE SymSetIsParam(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isParam[k] := v
END SymSetIsParam;

PROCEDURE SymIsReg(si: INTEGER): BOOLEAN;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.isReg[k]
END SymIsReg;

PROCEDURE SymSetIsReg(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isReg[k] := v
END SymSetIsReg;

PROCEDURE SymVal(si: INTEGER): LONGINT;
  VAR c: ConstChunk; k: INTEGER;
BEGIN ConstChunkFor(LexRef(si), c, k); RETURN c^.val[k]
END SymVal;

PROCEDURE SymSetVal(si: INTEGER; val: LONGINT);
  VAR c: ConstChunk; k: INTEGER;
BEGIN ConstChunkFor(LexRef(si), c, k); c^.val[k] := val
END SymSetVal;

(* SymAppend: intern nm and add a fresh lexeme row of the given kind
   (SymVar/SymConst) at the end of the LexemeArray, returning its si.
   Caller fills the kind-specific fields (ty/recIdx/isLocal/ofs/isParam
   for SymVar, val for SymConst) afterward -- same contract the old
   shared-SymChunk SymAppend had, now dispatching to VarAppend/
   ConstAppend instead of a single table. *)
PROCEDURE SymAppend(nm: ARRAY OF CHAR; kind: INTEGER): INTEGER;
BEGIN
  IF kind = SymConst THEN RETURN ConstAppend(nm) ELSE RETURN VarAppend(nm) END
END SymAppend;

(* FindSym: search backward for the most-recent LexConst or LexVar row
   named nm (most-recent/innermost shadowing wins) -- VAR and CONST share
   one identifier namespace (both are referenced as a bare operand name),
   so this one lookup covers both, exactly like the old shared-SymChunk
   FindSym. A row of any other kind (LexKw/LexSym/LexReg/LexType/LexProc)
   sharing the same spelling is skipped rather than matched -- in practice
   this never happens (a CONST/VAR name is never also a keyword, register,
   or already-declared TYPE/PROCEDURE name: SPHINX reserves those
   namespaces, and the scanner-level IsKw/IsRegName-equivalent checks
   already run before an identifier ever reaches FindSym), but skipping
   instead of blindly matching the nearest row of ANY kind keeps that
   invariant enforced rather than assumed. *)
PROCEDURE FindSym(nm: ARRAY OF CHAR): INTEGER;
  VAR id: StrTab.TStrTabId; c: LexChunk; li, k: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  IF id = 0 THEN RETURN -1 END;
  li := nLex - 1;
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF (c^.nameId[k] = id) & ((c^.kind[k] = LexConst) OR (c^.kind[k] = LexVar)) THEN RETURN li END;
    DEC(li)
  END;
  RETURN -1
END FindSym;

(* ---- TYPE detail table (LexType rows) ---- *)

(* TypeChunkFor: ti's owning directory block + in-block offset -- a
   plain DIV/MOD Chunk index into typeDir (MaxDetailChunks's own header
   comment), O(1) instead of the old linked-list next-hop. *)
PROCEDURE TypeChunkFor(ti: INTEGER; VAR c: TypeChunk; VAR k: INTEGER);
BEGIN c := typeDir[ti DIV Chunk]; k := ti MOD Chunk
END TypeChunkFor;

(* TypeAppend: aliasTy = TyRec for a real RECORD type (fields are added
   afterward via TypeAddField); any other TyByte..TyLong value declares a
   non-RECORD alias (TYPE Foo = LONGINT;) with no fields of its own.
   Interns nm as a fresh LexType lexeme row (ref = its own TypeChunk slot
   index, ti) and returns ti -- callers navigate types by ti exactly as
   before (TypeChunkFor(ti,...) is unaffected: ti is still a dense
   0-based TypeChunk slot index, just now discovered via FindType's
   lexeme-row ref instead of being the row index itself). NEWs a fresh
   typeDir block only when ti is about to cross into one that hasn't
   been allocated yet. nm is also stored directly on this row (nameId)
   so TypeName can look it up in O(1), same as every other *Name
   accessor. *)
PROCEDURE TypeAppend(nm: ARRAY OF CHAR; aliasTy: INTEGER): INTEGER;
  VAR last: TypeChunk; ti, bi, k: INTEGER;
BEGIN
  ti := nTypes; INC(nTypes);
  bi := ti DIV Chunk;
  IF typeDir[bi] = NIL THEN
    NEW(typeDir[bi]);
    IF typeDir[bi] = NIL THEN LogErr.Error("spho: out of memory (type table)"); ok := FALSE; RETURN ti END
  END;
  TypeChunkFor(ti, last, k);
  last^.nameId[k] := StrTab.Intern(nm);
  last^.aliasTy[k] := aliasTy;
  last^.nFields[k] := 0;
  LexAppendRaw(nm, LexType, ti);
  RETURN ti
END TypeAppend;

(* FindType: search backward for the most-recent LexType row named nm,
   returning its own ti (LexRef) -- same contract (a TypeChunk slot index)
   every TypeChunkFor/TypeName/TypeNFields/... caller already expects. *)
PROCEDURE FindType(nm: ARRAY OF CHAR): INTEGER;
  VAR id: StrTab.TStrTabId; c: LexChunk; li, k: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  IF id = 0 THEN RETURN -1 END;
  li := nLex - 1;
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF (c^.nameId[k] = id) & (c^.kind[k] = LexType) THEN RETURN c^.ref[k] END;
    DEC(li)
  END;
  RETURN -1
END FindType;

PROCEDURE TypeName(ti: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); StrTab.Get(c^.nameId[k], dst)
END TypeName;

PROCEDURE TypeNFields(ti: INTEGER): INTEGER;
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); RETURN c^.nFields[k]
END TypeNFields;

PROCEDURE TypeAliasTy(ti: INTEGER): INTEGER;
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); RETURN c^.aliasTy[k]
END TypeAliasTy;

(* TypeAddField: append a field to type ti's own (fixed-size, MaxFields-
   bounded) field list -- a single record's field count is not the kind
   of unbounded whole-file accumulation the chunk rule targets. *)
PROCEDURE TypeAddField(ti: INTEGER; nm: ARRAY OF CHAR; ty, recIdx: INTEGER);
  VAR c: TypeChunk; k, fi: INTEGER;
BEGIN
  TypeChunkFor(ti, c, k);
  fi := c^.nFields[k];
  IF fi >= MaxFields THEN
    LogErr.Error("spho: too many fields in RECORD"); ok := FALSE; RETURN
  END;
  c^.fields[k][fi].nameId := StrTab.Intern(nm);
  c^.fields[k][fi].ty := ty; c^.fields[k][fi].recIdx := recIdx;
  c^.nFields[k] := fi + 1
END TypeAddField;

PROCEDURE TypeField(ti, fi: INTEGER; VAR nm: ARRAY OF CHAR; VAR ty, recIdx: INTEGER);
  VAR c: TypeChunk; k: INTEGER;
BEGIN
  TypeChunkFor(ti, c, k);
  StrTab.Get(c^.fields[k][fi].nameId, nm);
  ty := c^.fields[k][fi].ty; recIdx := c^.fields[k][fi].recIdx
END TypeField;

(* TypeFindFieldTy: linear scan of ti's own field list for fieldName --
   used by ParseMemOperand to resolve a '.RecordType.field' access's own
   declared type, so its later assignment can be sized correctly (a BYTE
   field, e.g. StructXmsRec.src_high in SPHINX.MD §13's own worked
   example, must not get a word-sized store). FALSE (ty left TyWord) if
   ti < 0 or fieldName isn't found -- matches ParseMemOperand's own
   existing "field not found" tolerance (it still emits the bare field
   name as NASM text on that path). *)
PROCEDURE TypeFindFieldTy(ti: INTEGER; fieldName: ARRAY OF CHAR; VAR ty, recIdx: INTEGER): BOOLEAN;
  VAR i: INTEGER; fnm: ARRAY MaxName OF CHAR; fty, frecIdx: INTEGER;
BEGIN
  ty := TyWord; recIdx := -1;
  IF ti < 0 THEN RETURN FALSE END;
  i := 0;
  WHILE i < TypeNFields(ti) DO
    TypeField(ti, i, fnm, fty, frecIdx);
    IF Strings.Equal(fnm, fieldName) THEN ty := fty; recIdx := frecIdx; RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END TypeFindFieldTy;

(* ---- PROCEDURE detail table (LexProc rows) ---- *)

(* ProcChunkFor: pi's owning directory block + in-block offset -- a
   plain DIV/MOD Chunk index into procDir (MaxDetailChunks's own header
   comment), O(1) instead of the old linked-list next-hop. *)
PROCEDURE ProcChunkFor(pi: INTEGER; VAR c: ProcChunk; VAR k: INTEGER);
BEGIN c := procDir[pi DIV Chunk]; k := pi MOD Chunk
END ProcChunkFor;

(* ProcReserve: intern nm as a fresh LexProc lexeme row (ref = its own
   ProcChunk slot index) with isFar not yet known -- called by
   ParseProcedure BEFORE its own savedLex watermark (see ParseProcedure's
   own header comment on why), same textual position the procedure's name
   is read at. A duplicate name (re-declaration) just overwrites via a
   fresh append -- ProcFindIsFar finds the most-recent (last) match, same
   shadowing order as FindSym. Returns pi, so ParseProcedure can pass it
   back to ProcSetIsFar once isFar is finally known (after the NEAR/FAR
   keyword, if any -- see ParseParams's own header comment on the same
   isFar-not-known-until-later constraint). NEWs a fresh procDir block
   only when pi is about to cross into one that hasn't been allocated
   yet. *)
PROCEDURE ProcReserve(nm: ARRAY OF CHAR): INTEGER;
  VAR last: ProcChunk; pi, bi, k: INTEGER;
BEGIN
  pi := nProcs; INC(nProcs);
  bi := pi DIV Chunk;
  IF procDir[bi] = NIL THEN
    NEW(procDir[bi]);
    IF procDir[bi] = NIL THEN LogErr.Error("spho: out of memory (proc table)"); ok := FALSE; RETURN -1 END
  END;
  ProcChunkFor(pi, last, k);
  last^.valid[k] := FALSE;   (* NEW'd chunks are not zeroed -- explicit default;
                                 ParseProcedure calls ProcSetIsFar to flip this
                                 TRUE once isFar is known, UNLESS the procedure
                                 turns out to be INTERRUPT (never a valid call
                                 target, see ProcChunkDesc's own comment). *)
  last^.isFwdKnown[k] := FALSE;   (* NEW'd chunks are not zeroed -- explicit
                                 default; ProcSetForward flips this TRUE for a
                                 FORWARD declaration only. *)
  LexAppendRaw(nm, LexProc, pi);
  RETURN pi
END ProcReserve;

(* ProcSetIsFar: fills in the isFar ProcReserve left pending, and marks
   the row valid (a real callable PROCEDURE, not an INTERRUPT one) --
   called by ParseProcedure only when ~isInterrupt, mirroring the old
   conditional "IF ~isInterrupt THEN ProcAppend(nm, isFar) END". Also
   used for the REAL definition matching an earlier FORWARD declaration
   (ParseProcedure reuses that same pi) -- isFwdKnown is left untouched
   (it only ever matters while valid[] is still FALSE; ProcFindIsFar
   checks valid[] first, isFwdKnown[] second, so once valid[] is TRUE
   here isFwdKnown[]'s own value stops being read at all). *)
PROCEDURE ProcSetIsFar(pi: INTEGER; isFar: BOOLEAN);
  VAR c: ProcChunk; k: INTEGER;
BEGIN ProcChunkFor(pi, c, k); c^.isFar[k] := isFar; c^.valid[k] := TRUE
END ProcSetIsFar;

(* ProcSetForward: like ProcSetIsFar, but leaves valid[] FALSE and sets
   isFwdKnown[] TRUE instead -- a FORWARD declaration (SPHINX.MD "FORWARD
   declarations") records isFar immediately (ProcFindIsFar can now safely
   resolve a call site that textually precedes the real definition,
   EmitCall's whole reason for needing isFar at all), but is NOT yet a
   real definition: valid[] stays FALSE until ParseProcedure reaches the
   matching real body later and calls ProcSetIsFar (not this) on the very
   same pi -- see ProcChunkDesc's own header comment for why valid[] and
   isFwdKnown[] answer two independent questions (real-definition-or-not
   for ParseProcedure's own duplicate-definition check, vs. isFar[]-is-
   trustworthy-right-now for ProcFindIsFar's call-site codegen). *)
PROCEDURE ProcSetForward(pi: INTEGER; isFar: BOOLEAN);
  VAR c: ProcChunk; k: INTEGER;
BEGIN ProcChunkFor(pi, c, k); c^.isFar[k] := isFar; c^.valid[k] := FALSE; c^.isFwdKnown[k] := TRUE
END ProcSetForward;

(* ProcFindIsFar: TRUE/set isFar if nm names a PROCEDURE parsed so far
   (searched backward, most-recent wins, mirrors FindSym) OR a FORWARD-
   declared one (isFwdKnown[], SPHINX.MD "FORWARD declarations" -- a
   FORWARD declaration's own isFar is already trustworthy for a call site
   even though the real body hasn't been parsed yet); result FALSE (not
   found) for a genuine forward reference with no FORWARD declaration, or
   a symbol defined only externally (e.g. via ASM/IMPORT-spliced source
   not yet reached, or a genuinely external label) -- EmitCall's caller
   decides the fallback for that case (PendingAppend + CheckPendingCalls,
   now a hard error at end-of-file instead of a silent FAR-call guess). *)
PROCEDURE ProcFindIsFar(nm: ARRAY OF CHAR; VAR isFar: BOOLEAN): BOOLEAN;
  VAR id: StrTab.TStrTabId; c: LexChunk; pc: ProcChunk; li, k, pk: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  IF id = 0 THEN RETURN FALSE END;
  li := nLex - 1;
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF (c^.nameId[k] = id) & (c^.kind[k] = LexProc) THEN
      ProcChunkFor(c^.ref[k], pc, pk);
      IF pc^.valid[pk] OR pc^.isFwdKnown[pk] THEN isFar := pc^.isFar[pk]; RETURN TRUE END
      (* an INTERRUPT procedure's own reserved-but-never-finalized row --
         not a valid call target (see ProcChunkDesc's own comment); keep
         searching backward past it instead of stopping here, same as any
         other non-matching row. *)
    END;
    DEC(li)
  END;
  RETURN FALSE
END ProcFindIsFar;

(* ProcFindAny: like ProcFindIsFar, but returns the proc-table index (pi)
   of ANY existing row for nm (found via isValid, regardless of its
   valid[]) -- unlike ProcFindIsFar, which only ever reports a row valid
   for use as a call target. Two distinct existing-row states matter to
   ParseProcedure's own caller: valid[k]=FALSE is a FORWARD-pending
   declaration (isFar already recorded, no body yet -- a FORWARD
   declaration reserves the row and records isFar immediately but never
   marks it valid, mirroring the pre-existing INTERRUPT convention this
   file already uses valid[] for); valid[k]=TRUE is an already-fully-
   defined procedure, so a second PROCEDURE with the same name is a
   genuine duplicate-definition error, not a forward-declaration fill-in.
   -1 (isFound=FALSE) means nm has never been seen as a PROCEDURE at all,
   so ProcReserve should proceed exactly as before. *)
PROCEDURE ProcFindAny(nm: ARRAY OF CHAR; VAR isValid: BOOLEAN): INTEGER;
  VAR id: StrTab.TStrTabId; c: LexChunk; pc: ProcChunk; li, k, pk: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  IF id = 0 THEN RETURN -1 END;
  li := nLex - 1;
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF (c^.nameId[k] = id) & (c^.kind[k] = LexProc) THEN
      ProcChunkFor(c^.ref[k], pc, pk);
      isValid := pc^.valid[pk];
      RETURN c^.ref[k]
    END;
    DEC(li)
  END;
  RETURN -1
END ProcFindAny;

(* CheckPendingCalls: called once, after the whole top-level file (and
   every file it IMPORTs) has been fully parsed. Every entry PendingAppend
   ever recorded is, by construction, a call site where EmitCall/
   EmitCallNoArgs could not resolve the target's real NEAR/FAR-ness at
   the time (ProcFindIsFar found neither a real definition nor a FORWARD
   declaration) and silently fell back to a guessed `call far` -- correct
   only when the callee later turns out to genuinely be FAR, and a
   stack-corrupting wrong call otherwise (reproduced directly: a forward
   call to a same-file NEAR procedure with no FORWARD declaration hung
   the resulting .COM at runtime, see DOCS/SPHO.MD "FORWARD
   declarations"). This is now unconditionally a hard translator error
   for EVERY recorded entry -- not a re-resolution check: whether the
   name eventually turned out to be defined by end of file makes no
   difference, since the .ASM text for that call site was ALREADY
   emitted with the guessed (and possibly wrong) call type by the time
   this runs, and there is no cheap way for this single-pass/no-AST
   translator to go back and patch already-written output. A FORWARD
   declaration is the only way to make a same-file forward call
   resolvable AT THE CALL SITE ITSELF (ProcFindIsFar succeeds immediately
   via isFwdKnown[]), which is exactly why using one means the call site
   never reaches PendingAppend in the first place -- so it never appears
   here at all, and the common case (caller textually AFTER callee, no
   FORWARD needed) is completely unaffected. *)
PROCEDURE CheckPendingCalls;
  VAR pc: PendingChunk; k: INTEGER; nm, msg: ARRAY MaxLine OF CHAR;
BEGIN
  pc := pendingHead;
  WHILE pc # NIL DO
    k := 0;
    WHILE k < pc^.count DO
      StrTab.Get(pc^.id[k], nm);
      Strings.Copy("spho: call to '", msg);
      Strings.Append(nm, msg);
      Strings.Append("' near line ", msg); Strings.AppendInt(LONGINT(pc^.line[k]), msg);
      Strings.Append(" precedes its own definition with no FORWARD declaration", msg);
      LogErr.Error(msg); ok := FALSE;
      INC(k)
    END;
    pc := pc^.next
  END
END CheckPendingCalls;

(* LitLabelName: NASM label text for the n-th distinct string literal
   (0-based, in first-occurrence order, matching a LitChunk slot index
   -- see LitAppend/LitIndexOf below). *)
PROCEDURE LitLabelName(n: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
  Strings.Copy("_literal", dst); Strings.AppendInt(LONGINT(n), dst)
END LitLabelName;

(* LitIndexOf: 0-based slot index of id within litHead's own list, or -1
   if id was never appended (id is always a valid StrTab id from
   StrTab.Intern by the time this is called, but "never appended here
   yet" is the normal not-yet-seen case EmitStringLiteral checks for). *)
PROCEDURE LitIndexOf(id: StrTab.TStrTabId): INTEGER;
  VAR c: LitChunk; i, k: INTEGER;
BEGIN
  c := litHead; i := 0;
  WHILE c # NIL DO
    k := 0;
    WHILE k < c^.count DO
      IF c^.id[k] = id THEN RETURN i END;
      INC(k); INC(i)
    END;
    c := c^.next
  END;
  RETURN -1
END LitIndexOf;

(* LitAppend: record a newly-seen literal's StrTab id at the end of the
   list (growing it if the tail chunk is full or absent), returning its
   0-based slot index (== its label's own number, LitLabelName). Caller
   (EmitStringLiteral) has already checked LitIndexOf returned -1, so
   this never checks for an existing id itself -- same append-only
   contract as VarAppend/ConstAppend/TypeAppend/ProcAppend. *)
PROCEDURE LitAppend(id: StrTab.TStrTabId): INTEGER;
  VAR last: LitChunk; li, k: INTEGER;
BEGIN
  IF (litTail = NIL) OR (litTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("spho: out of memory (literal table)"); ok := FALSE; RETURN nLits END;
    last^.count := 0; last^.next := NIL;
    IF litHead = NIL THEN litHead := last ELSE litTail^.next := last END;
    litTail := last
  END;
  li := nLits; INC(nLits);
  last := litTail;
  WHILE li >= Chunk DO last := last^.next; DEC(li, Chunk) END;
  k := li;
  last^.id[k] := id;
  last^.count := k + 1;
  RETURN nLits - 1
END LitAppend;

(* PendingAppend: record a call site's target name (as an already-
   interned StrTab id) and source line, for CheckPendingCalls to
   re-resolve once the whole file has been parsed -- see PendingChunk's
   own header comment. Same append-only chunk-growth shape as LitAppend. *)
PROCEDURE PendingAppend(id: StrTab.TStrTabId; ln: INTEGER);
  VAR last: PendingChunk; pi, k: INTEGER;
BEGIN
  IF (pendingTail = NIL) OR (pendingTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("spho: out of memory (pending-call table)"); ok := FALSE; RETURN END;
    last^.count := 0; last^.next := NIL;
    IF pendingHead = NIL THEN pendingHead := last ELSE pendingTail^.next := last END;
    pendingTail := last
  END;
  pi := nPending; INC(nPending);
  last := pendingTail;
  WHILE pi >= Chunk DO last := last^.next; DEC(pi, Chunk) END;
  k := pi;
  last^.id[k] := id; last^.line[k] := ln;
  last^.count := k + 1
END PendingAppend;

(* InternStringLiteral: text is a double-quoted string literal's
   already-scanned content (tokText, no quotes). Interns it via StrTab
   (exact byte content, dedup for free -- a repeated literal reuses the
   same StrTab id and therefore the same label) and returns its NASM
   label text -- the literal's own address, which is all a caller ever
   needs (SPHINX has no string-VALUE operations, only pass-by-offset:
   "literal possible pass to procedure call (pass offset) and assign
   (offset) to 16-bit regs", the user's own words) -- callers use dst
   as a bare operand, exactly like a global VAR's own name resolves to
   its address as an immediate elsewhere in this file. *)
PROCEDURE InternStringLiteral(text: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR id: StrTab.TStrTabId; li: INTEGER;
BEGIN
  id := StrTab.Intern(text);
  li := LitIndexOf(id);
  IF li < 0 THEN li := LitAppend(id) END;
  LitLabelName(li, dst)
END InternStringLiteral;

(* FreeChunks: DISPOSE every allocated node/block (zero-leak rule --
   CLAUDE.md "ZERO HEAP LEAKS"). Called once at the very end of RunBody.
   lexHead/litHead are still linked lists (walked next-pointer style);
   typeDir/procDir/constDir/varDir are fixed-size directories (Max-
   DetailChunks's own header comment) -- DISPOSE only the slots that were
   ever NEW'd (non-NIL), leaving the rest NIL for the next RunBody call. *)
PROCEDURE FreeChunks;
  VAR xc, xn: LexChunk; lc, ln: LitChunk; pc, pn: PendingChunk; i: INTEGER;
BEGIN
  xc := lexHead;
  WHILE xc # NIL DO xn := xc^.next; DISPOSE(xc); xc := xn END;
  lexHead := NIL; lexTail := NIL;
  i := 0;
  WHILE i < MaxDetailChunks DO
    IF typeDir[i] # NIL THEN DISPOSE(typeDir[i]) END;
    IF procDir[i] # NIL THEN DISPOSE(procDir[i]) END;
    IF constDir[i] # NIL THEN DISPOSE(constDir[i]) END;
    IF varDir[i] # NIL THEN DISPOSE(varDir[i]) END;
    INC(i)
  END;
  lc := litHead;
  WHILE lc # NIL DO ln := lc^.next; DISPOSE(lc); lc := ln END;
  litHead := NIL; litTail := NIL;
  pc := pendingHead;
  WHILE pc # NIL DO pn := pc^.next; DISPOSE(pc); pc := pn END;
  pendingHead := NIL; pendingTail := NIL
END FreeChunks;


(* ---------------- low-level scanning ---------------- *)

(* SYSTEM.ISALPHA plus '_' (SPHINX idents allow underscore, e.g. 'src_hnd'). *)
PROCEDURE IsIdentStart(c: CHAR): BOOLEAN;
BEGIN RETURN SYSTEM.ISALPHA(c) OR (c = "_")
END IsIdentStart;

PROCEDURE IsIdentCh(c: CHAR): BOOLEAN;
BEGIN RETURN IsIdentStart(c) OR SYSTEM.ISDIGIT(c)
END IsIdentCh;

(* NextCh: advance ch/ch2 by one raw byte from srcF; CR is skipped. *)
PROCEDURE NextCh;
  VAR b: BYTE; done: BOOLEAN;
BEGIN
  ch := ch2;
  done := FALSE;
  WHILE ~done DO
    IF ~Files.ReadByte(srcF, b) THEN
      ch2 := 0X; done := TRUE
    ELSIF CHR(b) = 0DX THEN
      (* skip CR, loop for the next real byte *)
    ELSE
      ch2 := CHR(b); done := TRUE
    END
  END
END NextCh;

PROCEDURE SkipBlanks;
  VAR more: BOOLEAN;
BEGIN
  more := TRUE;
  WHILE more & (ch # 0X) DO
    IF ch = 0AX THEN INC(line); NextCh
    ELSIF (ch = " ") OR (ch = 9X) THEN NextCh
    ELSIF (ch = "(") & (ch2 = "*") THEN
      NextCh; NextCh;
      WHILE (ch # 0X) & ~((ch = "*") & (ch2 = ")")) DO
        IF ch = 0AX THEN INC(line) END;
        NextCh
      END;
      IF ch # 0X THEN NextCh; NextCh END
    ELSE more := FALSE
    END
  END
END SkipBlanks;

(* ParseNumText: decimal, C-style hex ("0x1A"), trailing-H hex ("1AH"), or
   trailing-B binary -- delegates to Scan.ParseNumBuf (the canonical
   parser; SCAN.MOD's own ScanNumber feeds it the identical gathered-text
   shape, see its header comment re: bug A7's duplicate-parser lesson). *)
PROCEDURE ParseNumText(text: ARRAY OF CHAR): LONGINT;
  VAR v: LONGINT; errMsg: ARRAY 40 OF CHAR; msg: ARRAY 96 OF CHAR;
BEGIN
  IF ~Scan.ParseNumBuf(text, INTEGER(Strings.Length(text)), FALSE, v, errMsg) THEN
    Strings.Copy("spho: ", msg); Strings.Append(errMsg, msg);
    Strings.Append(" near line ", msg); Strings.AppendInt(LONGINT(line), msg);
    LogErr.Error(msg); ok := FALSE
  END;
  RETURN v
END ParseNumText;

(* Next: fetch the next token into tokKind/tokText/tokVal/tokLex. tokLex
   is the resolved LexemeArray index of this token's own spelling
   (FindLexeme, most-recent-wins shadowing) for TIdent/TSym -- the only
   two kinds that ever name a lexeme -- and -1 for TNum/TStr/TChar/TEof. *)
PROCEDURE Next;
  VAR i: INTEGER; q: CHAR; msg: ARRAY 96 OF CHAR;
BEGIN
  SkipBlanks;
  tokText[0] := 0X; tokVal := 0; tokLex := -1;
  IF ch = 0X THEN tokKind := TEof; RETURN END;
  IF IsIdentStart(ch) THEN
    i := 0;
    WHILE IsIdentCh(ch) & (i < MaxTok-1) DO tokText[i] := ch; INC(i); NextCh END;
    tokText[i] := 0X; tokKind := TIdent
  ELSIF SYSTEM.ISDIGIT(ch) THEN
    i := 0;
    WHILE (SYSTEM.ISHEX(ch) OR (ch = "H") OR (ch = "h") OR (ch = "x") OR (ch = "X"))
          & (i < MaxTok-1) DO
      tokText[i] := ch; INC(i); NextCh
    END;
    tokText[i] := 0X; tokKind := TNum;
    tokVal := ParseNumText(tokText)
  ELSIF (ch = '"') OR (ch = "'") THEN
    q := ch; NextCh; i := 0;
    WHILE (ch # q) & (ch # 0X) & (i < MaxStrLit-1) DO tokText[i] := ch; INC(i); NextCh END;
    IF (ch # q) & (ch # 0X) THEN
      (* the closing quote wasn't reached within MaxStrLit-1 chars --
         report it instead of silently truncating (this used to bound
         itself at MaxTok-1 = 63 chars for every quoted literal, with no
         error at all, contradicting DOCS/SPHINX.MD §3.3's own "any
         length" claim for a double-quoted string) -- then keep
         advancing raw characters (discarding them, tokText is already
         full) until the real closing quote or EOF is actually reached,
         so ch doesn't get left sitting mid-literal: leaving it there
         would make the very next Next() call resume scanning from
         inside the same literal's leftover bytes as if they were brand
         new tokens, the same "must consume, not just report" class of
         bug documented throughout this file (e.g. ParseAssignOrCall's
         own CONST-assignment error path). Reaching EOF instead without
         ever finding the closing quote is a separate, pre-existing
         "unterminated literal" case this scanner already tolerated
         silently; unaffected here. *)
      Strings.Copy("spho: string/char literal too long (max ", msg);
      Strings.AppendInt(LONGINT(MaxStrLit - 1), msg);
      Strings.Append(" chars) near line ", msg); Strings.AppendInt(LONGINT(line), msg);
      LogErr.Error(msg); ok := FALSE;
      WHILE (ch # q) & (ch # 0X) DO NextCh END
    END;
    IF ch = q THEN NextCh END;
    tokText[i] := 0X;
    IF q = '"' THEN
      tokKind := TStr
    ELSE
      tokKind := TChar;
      IF i = 0 THEN
        (* '' (empty single-quoted literal) -- DOCS/SPHINX.MD §3.3
           defines a char literal as "always exactly one character";
           an empty one is malformed input, not silently CHR(0) (i was
           never incremented by the scan loop above, so tokText[0] is
           just the 0X terminator this line just wrote -- ORD of that
           previously passed through as a plausible-looking value with
           no diagnostic at all, e.g. a stray "AL := '';" typo silently
           compiled to "mov ax, 0"). *)
        Strings.Copy("spho: empty char literal '' near line ", msg);
        Strings.AppendInt(LONGINT(line), msg); LogErr.Error(msg); ok := FALSE;
        tokVal := 0
      ELSE
        tokVal := LONGINT(ORD(tokText[0]))
      END
    END
  ELSIF (ch = ":") & (ch2 = "=") THEN
    tokText[0] := ":"; tokText[1] := "="; tokText[2] := 0X; tokKind := TSym; NextCh; NextCh
  ELSIF (ch = "#") THEN
    tokText[0] := "#"; tokText[1] := 0X; tokKind := TSym; NextCh
  ELSIF (ch = "<") & (ch2 = "=") THEN
    tokText[0] := "<"; tokText[1] := "="; tokText[2] := 0X; tokKind := TSym; NextCh; NextCh
  ELSIF (ch = ">") & (ch2 = "=") THEN
    tokText[0] := ">"; tokText[1] := "="; tokText[2] := 0X; tokKind := TSym; NextCh; NextCh
  ELSE
    tokText[0] := ch; tokText[1] := 0X; tokKind := TSym; NextCh
  END;
  IF (tokKind = TIdent) OR (tokKind = TSym) THEN tokLex := FindLexeme(tokText) END
END Next;

(* InitKwSyTables: fill kwSpellings/sySpellings, index i <-> id i -- the
   ONE enumeration of every keyword's/symbol's spelling. Called once per
   RunBody (RunBody's own explicit-init convention: the runtime does not
   zero module globals), before RegisterBuiltins/KwIdOf/SyIdOf can use
   either table. *)
PROCEDURE InitKwSyTables;
BEGIN
  kwSpellings[KwAsm] := "ASM"; kwSpellings[KwBegin] := "BEGIN";
  kwSpellings[KwBoolean] := "BOOLEAN"; kwSpellings[KwBreak] := "BREAK";
  kwSpellings[KwByte] := "BYTE"; kwSpellings[KwConst] := "CONST";
  kwSpellings[KwContinue] := "CONTINUE"; kwSpellings[KwDec] := "DEC";
  kwSpellings[KwDo] := "DO"; kwSpellings[KwElse] := "ELSE";
  kwSpellings[KwElsif] := "ELSIF"; kwSpellings[KwEnd] := "END";
  kwSpellings[KwFar] := "FAR"; kwSpellings[KwForward] := "FORWARD";
  kwSpellings[KwIf] := "IF";
  kwSpellings[KwImport] := "IMPORT"; kwSpellings[KwInc] := "INC";
  kwSpellings[KwInt] := "INT"; kwSpellings[KwInteger] := "INTEGER";
  kwSpellings[KwInterrupt] := "INTERRUPT"; kwSpellings[KwLongint] := "LONGINT";
  kwSpellings[KwModule] := "MODULE"; kwSpellings[KwNear] := "NEAR";
  kwSpellings[KwPop] := "POP"; kwSpellings[KwProcedure] := "PROCEDURE";
  kwSpellings[KwPush] := "PUSH"; kwSpellings[KwRecord] := "RECORD";
  kwSpellings[KwReg] := "REG";
  kwSpellings[KwReturn] := "RETURN"; kwSpellings[KwShl] := "SHL";
  kwSpellings[KwShr] := "SHR"; kwSpellings[KwThen] := "THEN";
  kwSpellings[KwType] := "TYPE";
  kwSpellings[KwUses] := "USES"; kwSpellings[KwVar] := "VAR";
  kwSpellings[KwWhile] := "WHILE"; kwSpellings[KwWord] := "WORD";
  kwSpellings[KwXor] := "XOR";

  sySpellings[SyAmp] := "&"; sySpellings[SyLParen] := "(";
  sySpellings[SyRParen] := ")"; sySpellings[SyStar] := "*";
  sySpellings[SyPlus] := "+"; sySpellings[SyComma] := ",";
  sySpellings[SyMinus] := "-"; sySpellings[SyDot] := ".";
  sySpellings[SyColon] := ":"; sySpellings[SyAssign] := ":=";
  sySpellings[SySemi] := ";"; sySpellings[SyEq] := "=";
  sySpellings[SyLBrack] := "["; sySpellings[SyRBrack] := "]";
  sySpellings[SyBar] := "|"; sySpellings[SyTilde] := "~";
  sySpellings[SyNe] := "#"; sySpellings[SyLt] := "<";
  sySpellings[SyGt] := ">"; sySpellings[SyLe] := "<=";
  sySpellings[SyGe] := ">="
END InitKwSyTables;

(* KwIdOf: spelling -> Kw* id, or -1 if kw doesn't name one of the
   kwSpellings entries InitKwSyTables filled in. Every IsKw/IsLexKw/
   ExpectKw call site in this file passes a literal keyword spelling, so
   this linear search's own table is exhaustive by construction -- adding
   a new keyword anywhere in this file means adding one more Kw* CONST, a
   matching kwSpellings assignment in InitKwSyTables, and bumping NKw --
   ONE place, not separately updating a dispatch chain here AND
   RegisterBuiltins' own seeding call. *)
PROCEDURE KwIdOf(kw: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < NKw DO
    IF Strings.EqualICase(kw, kwSpellings[i]) THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END KwIdOf;

(* SyIdOf: spelling -> Sy* id, or -1 if s doesn't name one of the
   sySpellings entries InitKwSyTables filled in. Same exhaustive-search
   contract as KwIdOf. *)
PROCEDURE SyIdOf(s: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < NSy DO
    IF Strings.Equal(s, sySpellings[i]) THEN RETURN i END;
    INC(i)
  END;
  RETURN -1
END SyIdOf;

(* IsKw: TRUE if the CURRENT token is the identifier spelling kw --
   tokLex was already resolved by Next (FindLexeme, most-recent-wins
   shadowing), so this is a kind=LexKw & ref=KwIdOf(kw) comparison
   instead of a fresh Strings.EqualICase scan; tokKind=TIdent is implied
   by tokLex only ever being resolved for TIdent/TSym, but is checked
   explicitly too since KwIdOf(kw) could otherwise coincidentally match a
   TSym row from a differently-spelled symbol (never actually possible,
   Kw*/Sy* id spaces are independent CONSTs starting at 0 each, but the
   explicit tokKind check keeps this from ever silently depending on
   that). *)
PROCEDURE IsKw(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (tokKind = TIdent) & (tokLex >= 0) & (LexKind(tokLex) = LexKw) & (LexRef(tokLex) = KwIdOf(kw))
END IsKw;

(* IsSym: TRUE if the CURRENT token is the symbol spelling s -- same
   tokLex-based comparison as IsKw, for LexSym rows. *)
PROCEDURE IsSym(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (tokKind = TSym) & (tokLex >= 0) & (LexKind(tokLex) = LexSym) & (LexRef(tokLex) = SyIdOf(s))
END IsSym;


(* IsLex pattern (DOCS/IMPLRULE.MD): peek + consume-on-match, kw form *)
PROCEDURE IsLexKw(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF IsKw(kw) THEN Next; RETURN TRUE END;
  RETURN FALSE
END IsLexKw;

PROCEDURE IsLexSym(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF IsSym(s) THEN Next; RETURN TRUE END;
  RETURN FALSE
END IsLexSym;

PROCEDURE Expect(s: ARRAY OF CHAR);
  VAR msg: ARRAY 96 OF CHAR;
BEGIN
  IF ~IsLexSym(s) THEN
    Strings.Copy("spho: expected '", msg); Strings.Append(s, msg);
    Strings.Append("' near line ", msg); Strings.AppendInt(LONGINT(line), msg);
    Strings.Append(" got '", msg); Strings.Append(tokText, msg); Strings.Append("'", msg);
    LogErr.Error(msg); ok := FALSE
  END
END Expect;

PROCEDURE ExpectKw(kw: ARRAY OF CHAR);
  VAR msg: ARRAY 96 OF CHAR;
BEGIN
  IF ~IsLexKw(kw) THEN
    Strings.Copy("spho: expected '", msg); Strings.Append(kw, msg);
    Strings.Append("' near line ", msg); Strings.AppendInt(LONGINT(line), msg);
    LogErr.Error(msg); ok := FALSE
  END
END ExpectKw;

(* ---------------- output ---------------- *)

PROCEDURE Emit(s: ARRAY OF CHAR);
BEGIN Files.WriteLine(outF, s)
END Emit;

PROCEDURE Emit2(a, b: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR;
BEGIN Strings.Copy(a, buf); Strings.Append(b, buf); Emit(buf)
END Emit2;

(* EnsureSection: switch to sect (SectData/SectBss) only if it isn't
   already the last one emitted -- SECTION is freely re-enterable in
   TASM, but ParseVarSection may interleave initialized/uninitialized
   declarations in any source order, so this keeps the .ASM from
   re-emitting an unchanged "section .data"/"section .bss" line between
   every single declaration. *)
PROCEDURE EnsureSection(sect: INTEGER);
BEGIN
  IF sect # curSect THEN
    IF sect = SectBss THEN Emit("section .bss")
    ELSIF sect = SectCode THEN Emit("section .text")
    ELSE Emit("section .data")
    END;
    curSect := sect
  END
END EnsureSection;

PROCEDURE EmitInd(s: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR;
BEGIN Strings.Copy("    ", buf); Strings.Append(s, buf); Emit(buf)
END EmitInd;

PROCEDURE NewLabel(): INTEGER;
BEGIN INC(labelCnt); RETURN labelCnt
END NewLabel;

PROCEDURE LabelName(id: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN Strings.Copy(".L", dst); Strings.AppendInt(LONGINT(id), dst)
END LabelName;

PROCEDURE EmitLabel(id: INTEGER);
  VAR nm: ARRAY 16 OF CHAR;
BEGIN LabelName(id, nm); Strings.Append(":", nm); Emit(nm)
END EmitLabel;

PROCEDURE EmitInd2(mnemonic: ARRAY OF CHAR; toLabel: INTEGER);
  VAR buf, nm: ARRAY MaxLine OF CHAR;
BEGIN
  LabelName(toLabel, nm);
  Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(nm, buf);
  EmitInd(buf)
END EmitInd2;

(* ---------------- symbol table ---------------- *)

(* IsRegName: delegates to Lex.LookupReg (the register-name source of
   truth TASM.EXE itself uses) instead of a hand-written OR-chain, so
   SPHO can never silently drift from what TASM.EXE actually accepts. *)
PROCEDURE IsRegName(s: ARRAY OF CHAR): BOOLEAN;
  VAR up: ARRAY 32 OF CHAR; li: INTEGER;
BEGIN
  Strings.Copy(s, up); SYSTEM.UPSTR(up);
  li := FindLexeme(up);
  RETURN (li >= 0) & (LexKind(li) = LexReg)
END IsRegName;

PROCEDURE TySize(ty, recIdx: INTEGER): INTEGER;
  VAR i, sum, fty, frecIdx: INTEGER; fnm: ARRAY MaxName OF CHAR;
BEGIN
  CASE ty OF
    TyByte, TyBool: RETURN 1
   |TyWord, TyInt:   RETURN 2
   |TyLong:          RETURN 4
   |TyRec:
     IF recIdx < 0 THEN RETURN 2 END;
     (* sum each field's own size -- a flat 2*nFields undercounts any
        record with a BYTE/LONGINT field (this path is live: local
        RECORD variables via ParseVarSection, not dead code). *)
     sum := 0; i := 0;
     WHILE i < TypeNFields(recIdx) DO
       TypeField(recIdx, i, fnm, fty, frecIdx);
       sum := sum + TySize(fty, frecIdx);
       INC(i)
     END;
     RETURN sum
  ELSE RETURN 2
  END
END TySize;

(* SizeHintFor: "byte"/"word" size-prefix hint for ty, used to size a
   memory-destination assignment store (see EmitExprAssign's own header
   comment) -- "" for TyRec (a struct-valued store isn't a single mov at
   all) or LONGINT (a 4-byte store needs its own two-mov handling, not a
   byte/word prefix; not attempted here). *)
PROCEDURE SizeHintFor(ty: INTEGER; VAR hint: ARRAY OF CHAR);
BEGIN
  CASE ty OF
    TyByte, TyBool: Strings.Copy("byte", hint)
   |TyWord, TyInt:   Strings.Copy("word", hint)
  ELSE hint[0] := 0X
  END
END SizeHintFor;

(* ---------------- type parsing (TYPE section: RECORD) ---------------- *)

(* ParseBaseType: a bare TYPE-section identifier can name either a real
   RECORD type (ty := TyRec, recIdx set) or a non-RECORD alias (TYPE Foo =
   LONGINT;) -- resolved via TypeAliasTy so a VAR of an aliased LONGINT
   gets the real 4-byte sizing instead of always falling back to WORD. *)
PROCEDURE ParseBaseType(VAR ty: INTEGER; VAR recIdx: INTEGER);
  VAR ti, aliasTy: INTEGER;
BEGIN
  recIdx := -1;
  IF IsLexKw("BYTE") THEN ty := TyByte
  ELSIF IsLexKw("BOOLEAN") THEN ty := TyBool
  ELSIF IsLexKw("WORD") THEN ty := TyWord
  ELSIF IsLexKw("INTEGER") THEN ty := TyInt
  ELSIF IsLexKw("LONGINT") THEN ty := TyLong
  ELSIF tokKind = TIdent THEN
    ti := FindType(tokText);
    IF ti >= 0 THEN
      aliasTy := TypeAliasTy(ti);
      IF aliasTy = TyRec THEN ty := TyRec; recIdx := ti
      ELSE ty := aliasTy   (* non-RECORD alias: use its real scalar type *)
      END
    ELSE
      ty := TyWord
    END;
    Next
  ELSE
    ty := TyWord; Next
  END
END ParseBaseType;

(* ParseBaseTypeName: like ParseBaseType's own scalar-keyword matching,
   but resolves an already-read name string (nm) instead of consuming the
   current token itself -- used by SIZE(T) (SPHINX.MD §9), where the type
   name has already been copied out and Next-ed past by the caller before
   TySize's result is known. A name matching neither a scalar keyword nor
   a declared TYPE is a translator error (unlike ParseBaseType's silent
   TyWord fallback for the unrelated "declared inline, no such type"
   VAR-section case), since SIZE(UnknownName) means the caller wrote a
   typo, not "just size it as a WORD". *)
PROCEDURE ParseBaseTypeName(nm: ARRAY OF CHAR; VAR ty: INTEGER; VAR recIdx: INTEGER);
  VAR msg: ARRAY MaxLine OF CHAR;
BEGIN
  recIdx := -1;
  IF Strings.EqualICase(nm, "BYTE") THEN ty := TyByte
  ELSIF Strings.EqualICase(nm, "BOOLEAN") THEN ty := TyBool
  ELSIF Strings.EqualICase(nm, "WORD") THEN ty := TyWord
  ELSIF Strings.EqualICase(nm, "INTEGER") THEN ty := TyInt
  ELSIF Strings.EqualICase(nm, "WORD") THEN ty := TyInt
  ELSIF Strings.EqualICase(nm, "LONGINT") THEN ty := TyLong
  ELSIF Strings.EqualICase(nm, "POINTER") THEN ty := TyLong
  ELSE
    Strings.Copy("spho: unknown type name in SIZE(): ", msg); Strings.Append(nm, msg);
    LogErr.Error(msg); ok := FALSE; ty := TyWord
  END
END ParseBaseTypeName;

PROCEDURE ResSuffix(ty: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
  CASE ty OF
    TyByte, TyBool: Strings.Copy("resb", dst)
   |TyWord, TyInt:   Strings.Copy("resw", dst)
   |TyLong:          Strings.Copy("resd", dst)
  ELSE Strings.Copy("resw", dst)
  END
END ResSuffix;

(* DeclMnemonic: db/dw/dd for ty -- same ty-to-mnemonic shape as
   ResSuffix above, for an initialized (not reserved-space) declaration. *)
PROCEDURE DeclMnemonic(ty: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN
  CASE ty OF
    TyByte, TyBool: Strings.Copy("db", dst)
   |TyWord, TyInt:   Strings.Copy("dw", dst)
   |TyLong:          Strings.Copy("dd", dst)
  ELSE Strings.Copy("dw", dst)
  END
END DeclMnemonic;

(* ParseRecordType: 'RECORD' already consumed by caller. Emits struc..endstruc. *)
PROCEDURE ParseRecordType(nm: ARRAY OF CHAR);
  VAR ti, ty, recIdx: INTEGER; fieldName: ARRAY MaxName OF CHAR;
      buf, sfx: ARRAY MaxLine OF CHAR; more: BOOLEAN;
BEGIN
  ti := TypeAppend(nm, TyRec);
  Emit2("struc ", nm);
  more := TRUE;
  WHILE more & (tokKind = TIdent) DO
    Strings.Copy(tokText, fieldName); Next;
    Expect(":");
    ParseBaseType(ty, recIdx);
    TypeAddField(ti, fieldName, ty, recIdx);
    ResSuffix(ty, sfx);
    Strings.Copy("    .", buf); Strings.Append(fieldName, buf);
    Strings.Append(": ", buf); Strings.Append(sfx, buf); Strings.Append(" 1", buf);
    Emit(buf);
    more := IsLexSym(";")
  END;
  ExpectKw("END");
  Emit("endstruc")
END ParseRecordType;

PROCEDURE ParseTypeSection;
  VAR nm: ARRAY MaxName OF CHAR; msg: ARRAY 128 OF CHAR; ty, recIdx: INTEGER;
BEGIN
  WHILE (tokKind = TIdent) & ~IsKw("VAR") & ~IsKw("PROCEDURE") & ~IsKw("BEGIN") & ~IsKw("END") DO
    Strings.Copy(tokText, nm); Next;
    Expect("=");
    IF IsLexKw("RECORD") THEN ParseRecordType(nm)
    ELSE
      (* non-RECORD alias (TYPE Foo = LONGINT;): registered with its real
         base type (via ParseBaseType, which also resolves Foo = AnotherType
         scalar-alias chains) so a later VAR of this type gets correctly
         sized -- previously this was parsed and discarded, silently
         mis-sizing any VAR declared with it as a 2-byte WORD. Aliasing
         one RECORD type under a second name (TYPE Bar = SomeRecordType;)
         isn't a documented SPHINX.MD form and isn't supported here. *)
      ParseBaseType(ty, recIdx);
      IF ty = TyRec THEN
        Strings.Copy("spho: TYPE alias of a RECORD type not supported: ", msg);
        Strings.Append(nm, msg); LogErr.Error(msg); ok := FALSE
      ELSE
        TypeAppend(nm, ty)
      END
    END;
    Expect(";")
  END
END ParseTypeSection;

(* ParseConstDecl: 'name = numericLiteral;' -- SPHINX.MD §4: named INTEGER/
   WORD/BYTE/LONGINT values, no storage allocated. Recorded so later
   references (IdentOperandText) emit the literal value instead of a
   bogus [name] memory read. *)
PROCEDURE ParseConstDecl;
  VAR nm, msg: ARRAY MaxLine OF CHAR; val: LONGINT; neg: BOOLEAN; si: INTEGER;
BEGIN
  Strings.Copy(tokText, nm); Next;
  Expect("=");
  neg := IsLexSym("-");   (* CONST Foo = -5; -- tokVal is only ever set for
                              a TNum token, so the '-' must be consumed
                              separately before reading it, or val silently
                              reads the '-' TSym's own (unset) tokVal. *)
  IF tokKind = TNum THEN
    val := tokVal; Next
  ELSE
    Strings.Copy("spho: expected numeric literal in CONST near line ", msg);
    Strings.AppendInt(LONGINT(line), msg); LogErr.Error(msg); ok := FALSE; val := 0
  END;
  IF neg THEN val := -val END;
  si := SymAppend(nm, SymConst);
  SymSetVal(si, val);
  Expect(";")
END ParseConstDecl;

(* ---------------- VAR section (global) ---------------- *)

(* EmitVarDecl: a global scalar VAR. hasInit=TRUE ("= value" given, a
   real stored value, SPHINX.MD §5.1's own "VAR version: WORD = 0x1700;")
   belongs in .data; hasInit=FALSE (the common case, no initializer) is
   zero-filled reserved space and belongs in .bss instead, exactly like
   an array or RECORD instance with no values written into it -- there
   is no reason to spend a stored zero byte/word/dword in the image
   over .bss's own reservation. Picks its own section (EnsureSection)
   rather than trusting the caller to have already chosen the right one,
   since the two cases now need different sections. *)
PROCEDURE EmitVarDecl(si: INTEGER; hasInit: BOOLEAN; initVal: LONGINT);
  VAR buf, nm, mn, rsfx: ARRAY MaxLine OF CHAR; ty: INTEGER;
BEGIN
  SymName(si, nm); ty := SymTy(si);
  IF hasInit THEN
    EnsureSection(SectData);
    DeclMnemonic(ty, mn);
    Strings.Copy(nm, buf); Strings.Append(" ", buf); Strings.Append(mn, buf); Strings.Append(" ", buf);
    Strings.AppendInt(initVal, buf);
    Emit(buf)
  ELSE
    EnsureSection(SectBss);
    ResSuffix(ty, rsfx);
    Strings.Copy(nm, buf); Strings.Append(": ", buf); Strings.Append(rsfx, buf); Strings.Append(" 1", buf);
    Emit(buf)
  END
END EmitVarDecl;

(* ParseArrayBound: 'N' in 'NAME: T[N]' (SPHINX.MD §3.1) -- a numeric
   literal, or (SPHINX.MD §4: constants "can be used wherever a literal
   is allowed") a CONST identifier. tokVal is only ever populated by the
   scanner for a TNum token, so a bare `cnt := INTEGER(tokVal)` silently
   read 0/stale for a CONST name -- resolve through the symbol table
   instead, and report a translator error for anything else (an
   undeclared name, or a VAR used where a constant bound is required)
   rather than silently emitting a wrong-sized reservation. *)
PROCEDURE ParseArrayBound(): INTEGER;
  VAR si: INTEGER; nm, msg: ARRAY MaxLine OF CHAR;
BEGIN
  IF tokKind = TNum THEN
    si := INTEGER(tokVal); Next; RETURN si
  ELSIF tokKind = TIdent THEN
    Strings.Copy(tokText, nm); Next;
    si := FindSym(nm);
    IF (si >= 0) & (SymKind(si) = SymConst) THEN RETURN INTEGER(SymVal(si)) END;
    Strings.Copy("spho: array bound is not a numeric literal or CONST: ", msg);
    Strings.Append(nm, msg); LogErr.Error(msg); ok := FALSE; RETURN 1
  ELSE
    Strings.Copy("spho: expected array bound near line ", msg);
    Strings.AppendInt(LONGINT(line), msg); LogErr.Error(msg); ok := FALSE; RETURN 1
  END
END ParseArrayBound;

(* 'NAME: T[N]' -- array of N elements of T (SPHINX.MD §3.1). *)
PROCEDURE ParseVarSection(isGlobal: BOOLEAN);
  VAR nm: ARRAY MaxName OF CHAR; ty, recIdx, si, cnt, elemSz: INTEGER;
      hasInit: BOOLEAN; initVal: LONGINT; buf, rsfx: ARRAY MaxLine OF CHAR;
      isArr: BOOLEAN;
BEGIN
  WHILE (tokKind = TIdent) & ~IsKw("PROCEDURE") & ~IsKw("BEGIN") & ~IsKw("END") DO
    Strings.Copy(tokText, nm); Next;
    Expect(":");
    ParseBaseType(ty, recIdx);
    isArr := FALSE; cnt := 1;
    IF IsLexSym("[") THEN
      isArr := TRUE;
      cnt := ParseArrayBound();
      Expect("]")
    END;
    hasInit := FALSE; initVal := 0;
    IF IsLexSym("=") THEN
      hasInit := TRUE; initVal := tokVal; Next
    END;
    si := SymAppend(nm, SymVar);
    SymSetTy(si, ty, recIdx); SymSetIsLocal(si, ~isGlobal); SymSetIsParam(si, FALSE);
    IF isGlobal THEN
      IF isArr & (ty = TyRec) THEN
        (* array of RECORD (SPHINX.MD §3.1's own 'items: StructXmsRec[4]'
           example): ResSuffix's resb/resw/resd only sizes one scalar
           element, not a whole record -- reserve the true byte count
           directly instead (no per-element istruc labeling needed for a
           plain reservation). RESB/RESW/RESD are only legal in .bss
           (TASM: "only valid in SECTION .bss"). *)
        EnsureSection(SectBss);
        (* RESB/RESW/RESD require a colon after the label (unlike DW/DB/DD,
           which TASM also accepts label-first with no colon) -- TASM:
           "unknown directive or mnemonic" without it. *)
        Strings.Copy(nm, buf); Strings.Append(": resb ", buf);
        Strings.AppendInt(LONGINT(TySize(ty, recIdx)) * LONGINT(cnt), buf); Emit(buf)
      ELSIF isArr THEN
        EnsureSection(SectBss);
        ResSuffix(ty, rsfx);
        Strings.Copy(nm, buf); Strings.Append(": ", buf); Strings.Append(rsfx, buf);
        Strings.Append(" ", buf); Strings.AppendInt(LONGINT(cnt), buf); Emit(buf)
      ELSIF ty = TyRec THEN
        (* a single RECORD instance, no field values ever written into it
           at declaration time -- zero-filled reserved space like any
           other uninitialized global, so .bss, a plain byte-count
           reservation, same shape as the array-of-RECORD case just
           above (not istruc/iend: TASM has no support for that NASM
           directive at all, a separate pre-existing gap this sidesteps
           entirely rather than works around). *)
        EnsureSection(SectBss);
        Strings.Copy(nm, buf); Strings.Append(": resb ", buf);
        Strings.AppendInt(LONGINT(TySize(ty, recIdx)), buf); Emit(buf)
      ELSE
        EmitVarDecl(si, hasInit, initVal)
      END
    ELSE
      (* local: reserve frame space, offset assigned by caller via frameOfs *)
      elemSz := TySize(ty, recIdx);
      IF isArr THEN elemSz := elemSz * cnt END;
      frameOfs := frameOfs + elemSz;
      SymSetOfs(si, frameOfs)
    END;
    Expect(";")
  END
END ParseVarSection;

(* ---------------- expression translation ---------------- *)
(* SPHINX has no operator precedence -- left to right (SPHINX.MD §7). *)

(* IdentOperandText: resolve a (non-register) identifier already read into
   `nm` to its NASM operand text -- the literal value for a CONST, a
   local/param's [bp+-N] frame slot for a local VAR, or a bare [name] for
   a global VAR (also the fallback for a name never declared at all).
   One FindSym lookup covers both CONST and VAR, since they share one
   identifier namespace. Shared by OperandText (which reads nm itself)
   and EmitAssignRhs's call-vs-plain-operand fallback (which already
   consumed nm while probing for a following '('). *)
(* SymOperandText: like IdentOperandText, but takes an already-resolved
   si (FindSym(nm), or -1 if never declared) instead of looking it up
   again -- shared by IdentOperandText itself and by callers that already
   had to resolve si for their own purposes (e.g. to reject a CONST
   target, or to check SymIsReg), so nm's symbol is looked up at most
   once per reference. *)
PROCEDURE SymOperandText(si: INTEGER; nm: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR ofs: INTEGER;
BEGIN
  IF (si >= 0) & (SymKind(si) = SymConst) THEN
    dst[0] := 0X; Strings.AppendInt(SymVal(si), dst); RETURN
  END;
  IF (si >= 0) & SymIsReg(si) THEN
    (* register-named param (SPHINX.MD §6.2): the actual formal-parameter
       identifier IS the register name -- reuse it verbatim, no [bp+N]
       frame slot exists for it at all. *)
    Strings.Copy(nm, dst); RETURN
  END;
  IF (si >= 0) & SymIsLocal(si) THEN
    ofs := SymOfs(si);
    Strings.Copy("[bp", dst);
    IF ofs >= 0 THEN Strings.Append("-", dst) ELSE Strings.Append("+", dst) END;
    Strings.AppendInt(LONGINT(ABS(ofs)), dst); Strings.Append("]", dst)
  ELSE
    Strings.Copy("[", dst); Strings.Append(nm, dst); Strings.Append("]", dst)
  END
END SymOperandText;

(* IdentOperandText: resolve a (non-register) identifier already read into
   `nm` to its NASM operand text. Wrapper over SymOperandText for callers
   that haven't already resolved si themselves. *)
PROCEDURE IdentOperandText(nm: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
BEGIN SymOperandText(FindSym(nm), nm, dst)
END IdentOperandText;

(* ParseMemOperand: '[' already consumed. SPHINX.MD §10 direct memory
   access: '[seg:base]' or '[offset]' (DS implied), optionally followed
   by '.RecordType.field' for structured access. Produces NASM text like
   '[es:bx]' or '[ds:si + StructXmsRec.len]'. sizeHint (see
   EmitExprAssign's own header comment) is set to the resolved field's
   own "byte"/"word" size for a '.RecordType.field' access (so e.g.
   StructXmsRec.src_high, a BYTE field, gets a correctly-sized store
   rather than the always-word default) or "" for a plain '[seg:base]'
   with no field access, where no declared type is known at all. *)
PROCEDURE ParseMemOperand(VAR dst: ARRAY OF CHAR; VAR sizeHint: ARRAY OF CHAR);
  VAR seg, base: ARRAY 32 OF CHAR; fieldName, recTyName: ARRAY MaxName OF CHAR;
      ti, fty, frecIdx: INTEGER; haveSeg: BOOLEAN;
BEGIN
  sizeHint[0] := 0X;
  seg[0] := 0X; Strings.Copy(tokText, base); Next;
  haveSeg := FALSE;
  IF IsLexSym(":") THEN
    haveSeg := TRUE; Strings.Copy(base, seg); Strings.Copy(tokText, base); Next
  END;
  Expect("]");
  Strings.Copy("[", dst);
  IF haveSeg THEN Strings.Append(seg, dst); Strings.Append(":", dst); Strings.Append(base, dst)
  ELSE Strings.Append(base, dst)
  END;
  IF IsLexSym(".") THEN
    Strings.Copy(tokText, fieldName); Next;   (* RecordType name *)
    ti := FindType(fieldName);
    Expect(".");
    Strings.Copy(tokText, fieldName); Next;   (* field name *)
    Strings.Append(" + ", dst);
    IF ti >= 0 THEN
      TypeName(ti, recTyName);
      Strings.Append(recTyName, dst); Strings.Append(".", dst); Strings.Append(fieldName, dst);
      IF TypeFindFieldTy(ti, fieldName, fty, frecIdx) THEN SizeHintFor(fty, sizeHint) END
    ELSE Strings.Append(fieldName, dst)
    END
  END;
  Strings.Append("]", dst)
END ParseMemOperand;

(* IsBuiltinName: TRUE for a value built-in (ADR/SEG/SIZE/ODD, SPHINX.MD
   §9) name -- used by EmitAssignRhs to route 'dst := NAME(...)' through
   OperandText/EmitExpr (where TryBuiltinOperand/TryEmitOdd handle them)
   instead of its own generic call-or-plain-var dispatch, which would
   otherwise treat e.g. "SIZE" as an ordinary undeclared variable/call. *)
PROCEDURE IsBuiltinName(nm: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EqualICase(nm, "ADR") OR Strings.EqualICase(nm, "SEG")
       OR Strings.EqualICase(nm, "SIZE") OR Strings.EqualICase(nm, "ODD")
END IsBuiltinName;

(* TryBuiltinOperand: SPHINX.MD §9 value built-ins ADR/SEG/SIZE, each
   'NAME(arg)' -- must be checked before the plain-identifier path in
   OperandText (which would otherwise treat e.g. "SIZE" as an ordinary,
   never-declared variable name). ODD(x) is handled separately by
   EmitExpr/TryEmitOdd below (it needs `test`+`setne`, a multi-instruction
   boolean result, not a single operand-text substitution like these
   three). PUSH/POP are statement-level (see ParseStmt), not value-
   producing. Returns FALSE (nothing consumed) if tokText doesn't name
   one of these three. *)
(* IsGlobalVarName: TRUE if arg names a declared, non-local, non-register
   VAR -- SEG()'s own validity check (a local/param has no separate
   segment override to report; it is always SS-relative, and SPHINX
   gives no syntax for expressing "SS" as SEG's own result). *)
PROCEDURE IsGlobalVarName(arg: ARRAY OF CHAR): BOOLEAN;
  VAR si: INTEGER;
BEGIN
  IF IsRegName(arg) THEN RETURN FALSE END;
  si := FindSym(arg);
  RETURN (si >= 0) & ~SymIsLocal(si)
END IsGlobalVarName;

(* EmitAdrOperand: resolves arg (already known to be a declared,
   non-register VAR/param -- global or local) to an ADR() operand text.
   A global's bare label name already IS its own offset as a NASM
   immediate ("mov si, xmsRec") -- unchanged, no instruction needed. A
   local/param has no compile-time-constant offset (its address is only
   known relative to BP at runtime), so ADR(local) instead emits
   `lea ax, [bp±N]` and yields "ax" as the operand text, the same
   emit-then-substitute-a-register-name convention a call's own result
   already uses elsewhere in OperandText (EmitCall -> "ax"). A register-
   named param (SPHINX.MD §6.2, SymIsReg) has no frame slot and no
   address at all -- ADR() on one is a translator error, not merely
   disallowed like SEG(). *)
PROCEDURE EmitAdrOperand(arg: ARRAY OF CHAR; si: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR mem, buf: ARRAY MaxLine OF CHAR; msg: ARRAY MaxLine OF CHAR;
BEGIN
  IF ~SymIsLocal(si) THEN
    Strings.Copy(arg, dst); RETURN
  END;
  IF SymIsReg(si) THEN
    Strings.Copy("spho: ADR() of a register-named param has no address: ", msg);
    Strings.Append(arg, msg); LogErr.Error(msg); ok := FALSE; Strings.Copy("0", dst); RETURN
  END;
  SymOperandText(si, arg, mem);
  Strings.Copy("lea ax, ", buf); Strings.Append(mem, buf); EmitInd(buf);
  Strings.Copy("ax", dst)
END EmitAdrOperand;

PROCEDURE TryBuiltinOperand(VAR dst: ARRAY OF CHAR): BOOLEAN;
  VAR nm, arg, msg: ARRAY MaxLine OF CHAR; ty, recIdx, ti, si: INTEGER;
BEGIN
  IF Strings.EqualICase(tokText, "ADR") THEN
    Next; Expect("(");
    IF tokKind = TIdent THEN
      Strings.Copy(tokText, arg); Next;
      si := FindSym(arg);
      IF (si < 0) OR IsRegName(arg) THEN
        Strings.Copy("spho: ADR() requires a declared VAR or param name: ", msg);
        Strings.Append(arg, msg); LogErr.Error(msg); ok := FALSE; Strings.Copy("0", dst)
      ELSE
        EmitAdrOperand(arg, si, dst)
      END
    ELSE
      LogErr.Error("spho: expected variable name in ADR()"); ok := FALSE; Next; Strings.Copy("0", dst)
    END;
    Expect(")"); RETURN TRUE
  ELSIF Strings.EqualICase(tokText, "SEG") THEN
    Next; Expect("(");
    IF tokKind = TIdent THEN
      Strings.Copy(tokText, arg); Next;
      IF ~IsGlobalVarName(arg) THEN
        Strings.Copy("spho: SEG() requires a global VAR name: ", msg);
        Strings.Append(arg, msg); LogErr.Error(msg); ok := FALSE; Strings.Copy("0", dst)
      ELSE
        Strings.Copy("seg ", dst); Strings.Append(arg, dst)
      END
    ELSE
      LogErr.Error("spho: expected variable name in SEG()"); ok := FALSE; Next; Strings.Copy("0", dst)
    END;
    Expect(")"); RETURN TRUE
  ELSIF Strings.EqualICase(tokText, "SIZE") THEN
    Next; Expect("(");
    IF tokKind = TIdent THEN
      Strings.Copy(tokText, nm); Next;
      ti := FindType(nm);
      IF ti >= 0 THEN ty := TyRec; recIdx := ti
      ELSE ParseBaseTypeName(nm, ty, recIdx) END;
      dst[0] := 0X; Strings.AppendInt(LONGINT(TySize(ty, recIdx)), dst)
    ELSE
      LogErr.Error("spho: expected a type name in SIZE()"); ok := FALSE; Next; Strings.Copy("0", dst)
    END;
    Expect(")"); RETURN TRUE
  END;
  RETURN FALSE
END TryBuiltinOperand;

PROCEDURE EmitCall(name: ARRAY OF CHAR); FORWARD;

(* OperandText: one primary operand (register/ident/number/[mem]) as NASM
   text; does not consume a following operator. VAR refs resolve via
   vars[]. A plain identifier immediately followed by '(' is a call
   (SPHINX.MD §6.4: result lands in AX) -- emitted here (a genuine side
   effect, unlike every other branch's pure text-production) so a call
   can appear as any expression operand, not only as a bespoke top-level
   assignment RHS shape (EmitAssignRhs's own call handling predates this
   and is unaffected, but every OTHER context that reads an operand via
   OperandText -- RETURN's expression, an IF/WHILE condition, the second
   operand of a chained '+', a call's own actual-parameter expressions --
   used to treat "Name(" as the plain variable "Name" followed by a
   stray, totally unconsumed "(args)": OperandText advanced past "Name"
   only, EmitExprTail found no operator it recognized at the dangling
   '(', and ParseStmtList's caller looped forever re-parsing the same
   never-consumed "(args)" -- a hang, not merely a wrong translation
   (reproduced directly by "RETURN Helper(x, y)"). *)
PROCEDURE OperandText(VAR dst: ARRAY OF CHAR);
  VAR msg, discardSize, nm: ARRAY MaxLine OF CHAR;
BEGIN
  IF tokKind = TNum THEN
    Strings.Copy(tokText, dst); Next
  ELSIF tokKind = TChar THEN
    (* single-quoted 'x' (SPHINX.MD gives no worked example, but this
       mirrors NASM's own character-literal immediate) -- a plain
       numeric operand, tokVal already holds ORD(the one character). *)
    dst[0] := 0X; Strings.AppendInt(tokVal, dst); Next
  ELSIF tokKind = TStr THEN
    (* double-quoted "..." string literal -- pass-by-offset only
       (SPHINX has no string-value operations): resolves to its own
       .data label, the same as a global VAR's bare name already
       resolves to its address elsewhere in this file (ADR()'s own
       operand text, or a bare global reference in a register-pair
       move). *)
    InternStringLiteral(tokText, dst); Next
  ELSIF (tokKind = TIdent) & TryBuiltinOperand(dst) THEN
    (* handled *)
  ELSIF tokKind = TIdent THEN
    IF IsRegName(tokText) THEN Strings.Copy(tokText, dst); Next
    ELSE
      Strings.Copy(tokText, nm); Next;
      IF IsLexSym("(") THEN
        EmitCall(nm); Strings.Copy("ax", dst)
      ELSE
        IdentOperandText(nm, dst)
      END
    END
  ELSIF IsSym("[") THEN
    (* read context: the field's own declared size doesn't matter here --
       ParseMemOperand's size hint is only meaningful when *storing*
       through this operand (see ParseAssignOrCall's own use of it). *)
    Next; ParseMemOperand(dst, discardSize)
  ELSIF IsSym("-") THEN
    (* unary minus on a numeric literal (SPHINX.MD gives no example, but
       "AX := -1;" must be expressible) -- NASM accepts a negative
       immediate written as "-N" directly. Nothing else may follow '-'. *)
    Next;
    IF tokKind = TNum THEN
      Strings.Copy("-", dst); Strings.Append(tokText, dst); Next
    ELSE
      Strings.Copy("spho: expected numeric literal after unary '-' near line ", msg);
      Strings.AppendInt(LONGINT(line), msg); LogErr.Error(msg); ok := FALSE;
      Strings.Copy("0", dst)
    END
  ELSE
    Strings.Copy(tokText, dst); Next
  END
END OperandText;

PROCEDURE OpInstr(sym: ARRAY OF CHAR; VAR instr: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Strings.Equal(sym, "+") THEN Strings.Copy("add", instr)
  ELSIF Strings.Equal(sym, "-") THEN Strings.Copy("sub", instr)
  ELSIF Strings.Equal(sym, "&") THEN Strings.Copy("and", instr)
  ELSIF Strings.Equal(sym, "|") THEN Strings.Copy("or", instr)
  ELSIF Strings.EqualICase(sym, "XOR") THEN Strings.Copy("xor", instr)
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END OpInstr;

(* IsCallOperand: TRUE if the CURRENT (not yet consumed) token is going
   to be read by OperandText as a call ('Name(...)', SPHINX.MD §6.4)
   rather than a register/const/VAR/builtin -- without consuming
   anything (the scanner has no token-level backtrack, DOCS/SPHO.MD's
   own design note, so this must decide from tokText alone, the same
   read-only peek TryParseRegPair's own header comment describes doing
   elsewhere). A bare identifier reaching an operand position is only
   ever valid as one of: a register, a builtin (ADR/SEG/SIZE/ODD), an
   already-declared CONST/VAR, or a call -- so ruling out the first
   three leaves "must be a call" as the only remaining possibility for
   any other identifier (including one not yet declared at all, e.g. a
   forward reference to a NEAR proc later in the same file -- FindSym
   only ever matches CONST/VAR rows, never a proc name, so it correctly
   returns FALSE for those too, same as the genuine-call case). *)
PROCEDURE IsCallOperand(): BOOLEAN;
BEGIN
  IF tokKind # TIdent THEN RETURN FALSE END;
  IF IsRegName(tokText) THEN RETURN FALSE END;
  IF IsBuiltinName(tokText) THEN RETURN FALSE END;
  RETURN FindSym(tokText) < 0
END IsCallOperand;

(* EmitTailOperand: reads the next chain operand into opnd, exactly like
   a bare OperandText call -- EXCEPT when IsCallOperand says the operand
   about to be read is itself a call: evaluating it would otherwise
   silently clobber destReg (SPHINX.MD §6.4's own call-result-in-AX
   convention) before the instruction combining destReg's OWN prior
   value with the call's result ever runs. Reproduced directly:
   "dstEnd := dstEnd + Strings_Length(dst)" (EXAMPLES/SPHO/STRINGS.SMD's
   own Strings_Cat) compiled to "add ax, ax" instead of "add ax, cx" --
   Strings_Length's own call overwrote AX (dstEnd's running value) with
   its result, and a call's own operand text is always just "ax" again,
   so the add ended up doubling the call's result instead of adding it
   to dstEnd.

   Guarded ONLY for the actual call case (checked via IsCallOperand
   BEFORE OperandText ever runs, not after): destReg is pushed, the call
   evaluated, its result stashed in a scratch register (CX -- always
   safe to clobber here, calls never guarantee CX survives them either),
   then destReg is popped back to its pre-call value so the caller's own
   "instr destReg, opnd" combines the ORIGINAL destReg value with the
   call's result, not the call's result with itself. Every non-call
   operand (immediate, register, memory, builtin) takes the exact same
   single OperandText call this always used, zero bytes of overhead --
   this is what keeps every existing non-call chain (e.g. "RETURN
   AX+BX") byte-for-byte unchanged from before this fix. *)
PROCEDURE EmitTailOperand(destReg: ARRAY OF CHAR; VAR opnd: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR; isCall: BOOLEAN;
BEGIN
  isCall := IsCallOperand();
  IF isCall THEN
    Strings.Copy("push ", buf); Strings.Append(destReg, buf); EmitInd(buf)
  END;
  OperandText(opnd);
  IF isCall THEN
    Strings.Copy("mov cx, ", buf); Strings.Append(destReg, buf); EmitInd(buf);
    Strings.Copy("pop ", buf); Strings.Append(destReg, buf); EmitInd(buf);
    Strings.Copy("cx", opnd)
  END
END EmitTailOperand;

(* EmitExprTail: destReg already holds the first operand's value; consume
   left-to-right +,-,&,|,XOR,SHL,SHR chains per SPHINX.MD §7.1/7.2. *)
PROCEDURE EmitExprTail(destReg: ARRAY OF CHAR);
  VAR opnd, instr, buf, sym: ARRAY MaxLine OF CHAR; matched: BOOLEAN;
BEGIN
  REPEAT
    matched := FALSE;
    IF tokKind = TSym THEN
      Strings.Copy(tokText, sym);
      IF Strings.Equal(sym,"+") OR Strings.Equal(sym,"-") OR Strings.Equal(sym,"&") OR Strings.Equal(sym,"|") THEN
        Next; matched := OpInstr(sym, instr);
        EmitTailOperand(destReg, opnd);
        Strings.Copy(instr, buf); Strings.Append(" ", buf); Strings.Append(destReg, buf);
        Strings.Append(", ", buf); Strings.Append(opnd, buf); EmitInd(buf)
      END
    ELSIF IsKw("SHL") THEN
      Next; EmitTailOperand(destReg, opnd);
      Strings.Copy("shl ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf); matched := TRUE
    ELSIF IsKw("SHR") THEN
      Next; EmitTailOperand(destReg, opnd);
      Strings.Copy("shr ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf); matched := TRUE
    ELSIF IsKw("XOR") THEN
      Next; EmitTailOperand(destReg, opnd);
      Strings.Copy("xor ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf); matched := TRUE
    END
  UNTIL ~matched
END EmitExprTail;

PROCEDURE IsRelSym(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.Equal(s,"=") OR Strings.Equal(s,"#") OR Strings.Equal(s,"<")
       OR Strings.Equal(s,">") OR Strings.Equal(s,"<=") OR Strings.Equal(s,">=")
END IsRelSym;

(* RelJumps: single source of truth for the relational-symbol-to-
   condition-code mapping (=,#,<,>,<=,>=) -- both SetccFor (value context,
   SPHINX.MD §7.3) and EmitCondJump (jump context, IF/WHILE)
   derive their mnemonics from here, so a future relational operator can't
   be added to one and forgotten in the other. jt/jf are the "j"-prefixed
   jump mnemonics for TRUE/FALSE. *)
PROCEDURE RelJumps(rel: ARRAY OF CHAR; VAR jt, jf: ARRAY OF CHAR);
BEGIN
  IF Strings.Equal(rel, "=") THEN Strings.Copy("je", jt); Strings.Copy("jne", jf)
  ELSIF Strings.Equal(rel, "#") THEN Strings.Copy("jne", jt); Strings.Copy("je", jf)
  ELSIF Strings.Equal(rel, "<") THEN Strings.Copy("jl", jt); Strings.Copy("jge", jf)
  ELSIF Strings.Equal(rel, ">") THEN Strings.Copy("jg", jt); Strings.Copy("jle", jf)
  ELSIF Strings.Equal(rel, "<=") THEN Strings.Copy("jle", jt); Strings.Copy("jg", jf)
  ELSIF Strings.Equal(rel, ">=") THEN Strings.Copy("jge", jt); Strings.Copy("jl", jf)
  ELSE Strings.Copy("je", jt); Strings.Copy("jne", jf)
  END
END RelJumps;

PROCEDURE LoadIfMem(opnd, scratchReg: ARRAY OF CHAR; isByteVar: BOOLEAN; VAR dst: ARRAY OF CHAR); FORWARD;

(* EmitRelational: 'a REL' already scanned into firstOpnd/rel; destReg is
   the boolean-result destination (a BYTE register per SPHINX.MD §7.3's
   own "AL := AX > BX" example). Emits xor/cmp/Jcc -- terminal: SPHINX
   gives no example chaining a relational result into a further operator,
   so this always ends the expression (no EmitExprTail call). 8086 has no
   SETcc (that's 386+), so the boolean result is built with a conditional
   jump instead (mirrors TryEmitOdd's own idiom). *)
PROCEDURE EmitRelational(firstOpnd, rel, destReg: ARRAY OF CHAR);
  VAR opnd, a, buf: ARRAY MaxLine OF CHAR; jt, jf: ARRAY MaxLine OF CHAR;
      trueLbl, endLbl: INTEGER;
BEGIN
  OperandText(opnd);
  (* isByteVar hardcoded FALSE here (unlike EmitCondJump's own call
     below): firstOpnd arrives already flattened to text by this
     procedure's own caller (EmitExprFrom), which is itself often
     several calls removed from the original identifier token -- there
     is no cheap way to recover "was this originally a BYTE/BOOLEAN
     variable" at this point without threading a new parameter through
     that whole chain. Same known gap LoadIfMem's own header comment
     describes (a raw memory operand's true declared size isn't tracked
     through this path) -- not fixed here, keeping this call's behavior
     identical to before LoadIfMem grew its isByteVar parameter. *)
  LoadIfMem(firstOpnd, "ax", FALSE, a);
  Strings.Copy("cmp ", buf); Strings.Append(a, buf); Strings.Append(", ", buf);
  Strings.Append(opnd, buf); EmitInd(buf);
  RelJumps(rel, jt, jf);
  trueLbl := NewLabel(); endLbl := NewLabel();
  EmitInd2(jt, trueLbl);
  Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", 0", buf); EmitInd(buf);
  EmitInd2("jmp", endLbl);
  EmitLabel(trueLbl);
  Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", 1", buf); EmitInd(buf);
  EmitLabel(endLbl)
END EmitRelational;

(* WordHalves: destReg's own byte halves (AX->AL/AH, BX->BL/BH, CX->CL/CH,
   DX->DL/DH) -- FALSE if destReg has no byte halves (SI/DI/BP/SP/segregs),
   in which case widening must route through AX instead. *)
PROCEDURE WordHalves(destReg: ARRAY OF CHAR; VAR lo, hi: ARRAY OF CHAR): BOOLEAN;
  VAR up: ARRAY 8 OF CHAR;
BEGIN
  Strings.Copy(destReg, up); SYSTEM.UPSTR(up);
  IF Strings.Equal(up, "AX") THEN Strings.Copy("AL", lo); Strings.Copy("AH", hi); RETURN TRUE
  ELSIF Strings.Equal(up, "BX") THEN Strings.Copy("BL", lo); Strings.Copy("BH", hi); RETURN TRUE
  ELSIF Strings.Equal(up, "CX") THEN Strings.Copy("CL", lo); Strings.Copy("CH", hi); RETURN TRUE
  ELSIF Strings.Equal(up, "DX") THEN Strings.Copy("DL", lo); Strings.Copy("DH", hi); RETURN TRUE
  END;
  RETURN FALSE
END WordHalves;

(* EmitWidenByteToWord: destReg := ZeroExtend(srcByteReg) -- 8086 has no
   move-with-zero-extend, so this is the plain-8086 idiom: load the byte
   into destReg's own low half (or AL, if destReg has no byte halves of
   its own), then clear the high half. BYTE/BOOLEAN are documented
   unsigned (SPHINX.MD §3.1), so zero- not sign-extension is correct;
   CBW (sign-extend AL into AX) would be wrong here. *)
PROCEDURE EmitWidenByteToWord(srcByteReg, destReg: ARRAY OF CHAR);
  VAR lo, hi, buf: ARRAY MaxLine OF CHAR;
BEGIN
  IF WordHalves(destReg, lo, hi) THEN
    IF ~Strings.EqualICase(srcByteReg, lo) THEN
      Strings.Copy("mov ", buf); Strings.Append(lo, buf); Strings.Append(", ", buf);
      Strings.Append(srcByteReg, buf); EmitInd(buf)
    END;
    Strings.Copy("mov ", buf); Strings.Append(hi, buf); Strings.Append(", 0", buf); EmitInd(buf)
  ELSE
    (* destReg has no byte halves (SI/DI/BP/SP/segreg) -- widen through
       AX, then move the full word across. *)
    IF ~Strings.EqualICase(srcByteReg, "AL") THEN
      Strings.Copy("mov al, ", buf); Strings.Append(srcByteReg, buf); EmitInd(buf)
    END;
    Emit("    mov ah, 0");
    Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", ax", buf); EmitInd(buf)
  END
END EmitWidenByteToWord;

(* LoadIfMem: cmp's two operands can't both be bare memory, and a bare
   memory operand compared against an immediate is ambiguous in size
   (TASM: "operation size not specified") -- if opnd is a raw "[...]"
   memory operand (as OperandText/SymOperandText produce for any global
   or local with no further chained operator), load it into scratchReg
   first and return that register's name instead. A register or a
   numeric-literal operand is returned unchanged.

   isByteVar is TRUE when the caller already determined (by peeking the
   identifier BEFORE OperandText flattened it to memory text, the same
   way EmitCall's own byte-arg check works) that opnd is a BYTE/BOOLEAN-
   sized variable -- the word-wide "mov ax/reg, opnd" path below would
   otherwise read one byte past a 1-byte frame slot/global into the
   scratch register's high half as garbage (reproduced directly via
   EXAMPLES/SPHO/LCOUNT.SMD's own "WHILE gotByte = TRUE DO",
   gotByte:BOOLEAN -- the loop read a garbage high byte alongside
   gotByte's own TRUE/FALSE low byte and stopped after one iteration
   instead of running until EOF). FALSE (the default at every existing
   caller before this fix) keeps the previous always-word behavior. *)
PROCEDURE LoadIfMem;
  VAR buf, byteLo, byteHi: ARRAY MaxLine OF CHAR;
BEGIN
  IF opnd[0] = "[" THEN
    IF isByteVar THEN
      IF ~WordHalves(scratchReg, byteLo, byteHi) THEN Strings.Copy("AL", byteLo) END;
      Strings.Copy("mov ", buf); Strings.Append(byteLo, buf); Strings.Append(", byte ", buf);
      Strings.Append(opnd, buf); EmitInd(buf);
      EmitWidenByteToWord(byteLo, scratchReg)
    ELSE
      Strings.Copy("mov ", buf); Strings.Append(scratchReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf)
    END;
    Strings.Copy(scratchReg, dst)
  ELSE
    Strings.Copy(opnd, dst)
  END
END LoadIfMem;

(* EmitExprFrom: like EmitExpr, but the first operand's text was already
   scanned by the caller (e.g. while checking for a call) instead of via
   OperandText. A relational operator (SPHINX.MD §7.3, "used as value")
   diverts to EmitRelational instead of the ordinary arithmetic mov+chain. *)
PROCEDURE EmitExprFrom(firstOpnd, destReg: ARRAY OF CHAR);
  VAR rel, buf: ARRAY MaxLine OF CHAR;
BEGIN
  IF (tokKind = TSym) & IsRelSym(tokText) THEN
    Strings.Copy(tokText, rel); Next;
    EmitRelational(firstOpnd, rel, destReg); RETURN
  END;
  (* firstOpnd a byte register (AL/BL/CL/DL/AH/BH/CH/DH) landing in a
     word-sized destReg is a size mismatch TASM rejects ("operand size
     mismatch") -- widen instead of a bare mov. When destReg is itself a
     byte register too (e.g. EmitAssignRhs's LHS register fallback,
     "AL := BL;"), the plain same-size mov below is correct as-is. *)
  IF IsRegName(firstOpnd) & Lex.IsByteReg(Lex.LookupReg(firstOpnd))
     & (~IsRegName(destReg) OR ~Lex.IsByteReg(Lex.LookupReg(destReg))) THEN
    EmitWidenByteToWord(firstOpnd, destReg)
  ELSIF Strings.EqualICase(firstOpnd, destReg) THEN
    (* firstOpnd already names the same register as destReg (case-
       insensitively, e.g. "RETURN AX+BX;" calls EmitExprFrom("AX","ax"))
       -- the value is already sitting where it needs to be, so skip the
       no-op "mov ax, AX" self-move entirely instead of emitting it. *)
  ELSE
    Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
    Strings.Append(firstOpnd, buf); EmitInd(buf)
  END;
  EmitExprTail(destReg)
END EmitExprFrom;

(* TryEmitOdd: 'ODD(x)' (SPHINX.MD §9: "test x,1 / setne al") -- a
   terminal boolean expression like a relational (SPHINX.MD §7.3), so
   handled where EmitExpr already knows the final destReg, not inside
   OperandText's single-operand-text contract. Returns FALSE (nothing
   consumed) if the current token isn't "ODD". *)
(* 8086 has no SETcc (that's 386+) -- test/jz/mov-0/jmp/mov-1, the same
   plain-8086 idiom every other boolean result in this translator would
   need. *)
PROCEDURE TryEmitOdd(destReg: ARRAY OF CHAR): BOOLEAN;
  VAR arg, buf: ARRAY MaxLine OF CHAR; zeroLbl, endLbl: INTEGER;
BEGIN
  IF ~((tokKind = TIdent) & Strings.EqualICase(tokText, "ODD")) THEN RETURN FALSE END;
  Next; Expect("(");
  OperandText(arg);
  Expect(")");
  zeroLbl := NewLabel(); endLbl := NewLabel();
  (* route through AX first -- arg may be a bare memory operand like
     "[bp-2]" with no size prefix, which TASM rejects on `test` (size
     ambiguous between a byte and word immediate); a register operand is
     never ambiguous. *)
  Strings.Copy("mov ax, ", buf); Strings.Append(arg, buf); EmitInd(buf);
  Strings.Copy("test ax, 1", buf); EmitInd(buf);
  EmitInd2("jz", zeroLbl);
  Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", 1", buf); EmitInd(buf);
  EmitInd2("jmp", endLbl);
  EmitLabel(zeroLbl);
  Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", 0", buf); EmitInd(buf);
  EmitLabel(endLbl);
  RETURN TRUE
END TryEmitOdd;

(* EmitExpr: parse an expression (via OperandText for its first operand)
   and leave its value in destReg (a valid instruction operand, e.g. "ax"). *)
PROCEDURE EmitExpr(destReg: ARRAY OF CHAR);
  VAR opnd: ARRAY MaxLine OF CHAR;
BEGIN
  IF TryEmitOdd(destReg) THEN RETURN END;
  OperandText(opnd);
  EmitExprFrom(opnd, destReg)
END EmitExpr;

(* EmitCondJump: parse a relational condition (a REL b) and emit `cmp`
   followed by a conditional jump to label `toLabel` when the condition is
   TRUE if `onTrue` else when FALSE. Supports =,#,<,>,<=,>=. *)
(* FlagJumps: CFLAG/ZFLAG (SPHINX.MD §7.5) tested directly, no `cmp`
   needed -- jt/jf mirror RelJumps's own shape (the "j"-prefixed mnemonic
   for TRUE/FALSE) so EmitCondJump's onTrue dispatch is identical either
   way. *)
PROCEDURE FlagJumps(flagName: ARRAY OF CHAR; VAR jt, jf: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Strings.EqualICase(flagName, "CFLAG") THEN Strings.Copy("jc", jt); Strings.Copy("jnc", jf); RETURN TRUE
  ELSIF Strings.EqualICase(flagName, "ZFLAG") THEN Strings.Copy("jz", jt); Strings.Copy("jnz", jf); RETURN TRUE
  END;
  RETURN FALSE
END FlagJumps;

(* EmitCondJump: parses either a full relational condition ('a REL b') or
   a bare BOOLEAN condition -- a plain variable/register/call used
   directly ('IF sss THEN', 'IF SomeCall() THEN'), optionally preceded by
   '~' ('IF ~sss THEN'), with no '= TRUE'/'= FALSE' comparison needed.
   Which one this is can only be told AFTER 'a' itself is fully parsed
   (OperandText already handles a bare var/register/call uniformly, per
   its own header comment) -- IsRelSym peeks the token that follows
   without consuming it, so a REL operator continues into the full
   'a REL b' path and anything else (THEN/DO, end of condition) falls
   into the bare-boolean path instead, testing 'a' against zero. *)
PROCEDURE EmitCondJump(toLabel: INTEGER; onTrue: BOOLEAN);
  VAR a, aLoaded, b, rel, jt, jf, buf, nm: ARRAY MaxLine OF CHAR; negated: BOOLEAN;
      si, ty: INTEGER; aIsByteVar: BOOLEAN;
BEGIN
  (* '~CFLAG'/'~ZFLAG'/'CFLAG'/'ZFLAG' (SPHINX.MD §7.5): tested directly
     via the matching Jcc, skipping `cmp` entirely -- must be checked
     before the ordinary 'a REL b'/bare-boolean path below, since
     CFLAG/ZFLAG are plain identifiers that OperandText would otherwise
     treat as an ordinary (undeclared) operand. '~' in front of any other
     bare condition (not CFLAG/ZFLAG) is handled by the bare-boolean path
     further down, not here. *)
  negated := IsSym("~");
  IF negated THEN Next END;
  IF (tokKind = TIdent) & FlagJumps(tokText, jt, jf) THEN
    Next;
    LabelName(toLabel, nm);
    IF onTrue # negated THEN Strings.Copy(jt, buf) ELSE Strings.Copy(jf, buf) END;
    Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf); RETURN
  END;
  (* Peek a's own identifier BEFORE OperandText flattens it to memory
     text ("[bp-N]"/"[name]"), the same way EmitCall's own byte-arg
     check works -- LoadIfMem needs to know if a is a BYTE/BOOLEAN
     variable to load it correctly (see LoadIfMem's own header comment;
     reproduced directly via "WHILE gotByte = TRUE DO", gotByte:BOOLEAN,
     EXAMPLES/SPHO/LCOUNT.SMD). Never true for a plain numeric literal
     or register operand, so FindSym/SymKind/SymTy only run for a bare
     identifier that isn't a register name. *)
  aIsByteVar := FALSE;
  IF (tokKind = TIdent) & ~IsRegName(tokText) THEN
    si := FindSym(tokText);
    IF (si >= 0) & (SymKind(si) = SymVar) THEN
      ty := SymTy(si);
      aIsByteVar := (ty = TyByte) OR (ty = TyBool)
    END
  END;
  OperandText(a);
  IF (tokKind = TSym) & IsRelSym(tokText) THEN
    Strings.Copy(tokText, rel); Next;
    OperandText(b);
    (* a bare "[...]" memory operand compared directly against an
       immediate is size-ambiguous to TASM (see LoadIfMem's own header
       comment) -- load through AX first when needed. *)
    LoadIfMem(a, "ax", aIsByteVar, aLoaded);
    Strings.Copy("cmp ", buf); Strings.Append(aLoaded, buf); Strings.Append(", ", buf);
    Strings.Append(b, buf); EmitInd(buf);
    RelJumps(rel, jt, jf);
    LabelName(toLabel, nm);
    IF onTrue # negated THEN Strings.Copy(jt, buf) ELSE Strings.Copy(jf, buf) END;
    Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
  ELSE
    (* Bare BOOLEAN condition -- 'a' alone (var, register, or call result,
       always TRUE=1/FALSE=0 per SPHINX.MD §3.1), no REL operator
       followed it. Test against zero instead of comparing to TRUE/FALSE
       explicitly. *)
    LoadIfMem(a, "ax", aIsByteVar, aLoaded);
    Strings.Copy("cmp ", buf); Strings.Append(aLoaded, buf); Strings.Append(", 0", buf); EmitInd(buf);
    LabelName(toLabel, nm);
    IF onTrue # negated THEN Strings.Copy("jne", buf) ELSE Strings.Copy("je", buf) END;
    Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
  END
END EmitCondJump;

(* ---------------- statement translation ---------------- *)

PROCEDURE ParseStmtList; FORWARD;

(* MoveAxToDest: after an AX-valued result (a call's return, or a plain
   expression evaluated through EmitExprFrom(..,"ax")), move it into
   destReg -- unless destReg already IS ax and isn't a memory operand, in
   which case the value is already sitting where it needs to be. Shared
   by every "route the RHS through AX, then land it in destReg" site
   (EmitAssignRhs and EmitExprAssign below), so the move's own shape
   lives in exactly one place. destSize (see EmitExprAssign's own header
   comment) sizes a memory destination's store -- irrelevant for a
   register destReg, which is always its own fixed size. *)
PROCEDURE MoveAxToDest(destReg: ARRAY OF CHAR; destIsMem: BOOLEAN; destSize: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR;
BEGIN
  IF destIsMem & Strings.EqualICase(destSize, "byte") THEN
    Strings.Copy("mov byte ", buf); Strings.Append(destReg, buf); Strings.Append(", al", buf);
    EmitInd(buf)
  ELSIF destIsMem OR ~Strings.EqualICase(destReg, "AX") THEN
    Strings.Copy("mov ", buf); Strings.Append(destReg, buf); Strings.Append(", ax", buf);
    EmitInd(buf)
  END
END MoveAxToDest;

(* EmitExprAssign: like EmitExpr but the destination is a memory operand
   text (already formatted, e.g. "[bp-4]") rather than a register -- loads
   through AX first since x86 has no mem,mem forms, then stores via the
   same byte/word-sized move MoveAxToDest already gives every other
   "land an AX-valued result in a destination" site (destIsMem=TRUE here
   always takes its "mov destReg, ax"/"mov byte destReg, al" branches,
   never its destReg-already-AX skip, which only applies to a register
   destination). destSize is "byte" or "word" when the destination's
   declared storage size is known (e.g. a BYTE/BOOLEAN VAR is only 1
   byte); a bare `mov destMem, ax` would then write 2 bytes into 1-byte
   storage, clobbering whatever byte follows it in memory -- "byte"
   routes the store through AL instead. destSize="" (unknown, e.g. a raw
   [seg:base] with no declared VAR behind it) keeps the previous always-
   word behavior, since there's nothing better to do. *)
PROCEDURE EmitExprAssign(destMem, destSize: ARRAY OF CHAR);
BEGIN
  EmitExpr("ax");
  MoveAxToDest(destMem, TRUE, destSize)
END EmitExprAssign;

(* IsChainOp: TRUE if tok is an operator EmitExprTail would consume (so
   the expression continues past a single operand). *)
PROCEDURE IsChainOp(): BOOLEAN;
BEGIN
  RETURN (tokKind = TSym) & (IsSym("+") OR IsSym("-") OR IsSym("&") OR IsSym("|"))
       OR IsKw("SHL") OR IsKw("SHR") OR IsKw("XOR")
END IsChainOp;

(* EmitCall: 'Name(' already consumed. Pushes actual params left to
   right (Pascal convention, SPHINX.MD §6.1), then `call`/`call far
   Name` depending on the callee's own FAR-ness (SPHINX.MD §6.3). A bare
   `call` always assembles as a same-module NEAR call regardless of the
   target label's own kind (DOCS/TASM.MD §3), so a FAR callee's `retf`
   would pop 2 bytes too many; a name not found in the proc table (a
   forward reference within this file, or a name resolved only
   externally/via ASM) defaults to FAR, matching both SPHINX.MD's own
   default-FAR rule for exported procs and DOCS/TASM.MD §3's requirement
   that any cross-module reference be `CALL FAR`. Each argument may be a
   full expression (SPHINX.MD §7's own left-to-right chain), not just a
   single operand -- see the IsChainOp check inside the argument loop
   below. *)
PROCEDURE EmitCall;
  VAR opnd, buf: ARRAY MaxLine OF CHAR; isFar: BOOLEAN; si, ty: INTEGER;
      isByteVar: BOOLEAN;
BEGIN
  IF ~IsLexSym(")") THEN
    REPEAT
      (* A plain identifier naming a BYTE/BOOLEAN VAR/param must be
         detected BEFORE OperandText flattens it to memory text
         ("[bp-N]"/"[name]") -- that text alone no longer carries its
         own declared size, and a plain "mov ax, [bp-N]" word-read from
         a 1-byte frame slot picks up whatever adjacent byte happens to
         sit at [bp-N+1] into AH as high-byte garbage (reproduced
         directly: EXAMPLES/SPHO/LCOUNT.SMD's own "Out_Int(c)" with
         c:BYTE printed a large garbage value instead of c's real 0..255
         content). Peeking tokText/FindSym here, before OperandText
         consumes the token, is safe: it never advances the scanner, so
         OperandText's own subsequent call-vs-plain-var dispatch on the
         same token is completely unaffected. *)
      isByteVar := FALSE;
      IF (tokKind = TIdent) & ~IsRegName(tokText) THEN
        si := FindSym(tokText);
        IF (si >= 0) & (SymKind(si) = SymVar) THEN
          ty := SymTy(si);
          isByteVar := (ty = TyByte) OR (ty = TyBool)
        END
      END;
      OperandText(opnd);
      IF IsChainOp() THEN
        (* A genuine expression argument ('SomeCall(x + 1)', SPHINX.MD
           §7 -- SPHO's own left-to-right expression chain), not a bare
           single operand -- none of the fast paths below apply (each
           only handles opnd as-is, with no further operator). Evaluate
           the whole chain through EmitExprFrom/EmitExprTail (the same
           machinery every other expression context in this file already
           uses) into AX, then push that -- byte-widening for a leading
           byte-register/byte-var operand is still handled correctly
           inside EmitExprFrom itself, exactly as it already is for
           RETURN/assignment-RHS/condition expressions. Previously
           nothing here consumed a trailing operator at all: OperandText
           only ever reads ONE primary operand, so "x + 1" left the '+
           1' completely unconsumed after this argument's own comma/')'
           check, hanging the same "hasn't consumed a token, loop spins
           forever re-parsing it" way every other under-consuming gap in
           this file already does (reproduced directly). *)
        EmitExprFrom(opnd, "ax");
        Strings.Copy("push ax", buf)
      ELSIF IsRegName(opnd) & Lex.IsByteReg(Lex.LookupReg(opnd)) THEN
        (* 8086 has no `push` for a byte register (AL/BL/CL/DL/AH/BH/CH/
           DH) -- "push al" is not a legal instruction (TASM: "operand
           size mismatch"). Zero-extend into AX first (BYTE/BOOLEAN are
           documented unsigned, SPHINX.MD §3.1, same reasoning
           EmitWidenByteToWord's own header comment already gives), then
           push that. *)
        EmitWidenByteToWord(opnd, "ax");
        Strings.Copy("push ax", buf)
      ELSIF IsRegName(opnd) THEN
        Strings.Copy("push ", buf); Strings.Append(opnd, buf)
      ELSIF isByteVar THEN
        (* opnd is a byte-sized memory operand ("[bp-N]"/"[name]") --
           load through AL (correctly 1-byte-wide) and zero-extend,
           instead of a blind word-wide "mov ax, opnd". *)
        Strings.Copy("mov al, byte ", buf); Strings.Append(opnd, buf); EmitInd(buf);
        Strings.Copy("mov ah, 0", buf); EmitInd(buf);
        Strings.Copy("push ax", buf)
      ELSE
        Strings.Copy("mov ax, ", buf); Strings.Append(opnd, buf); EmitInd(buf);
        Strings.Copy("push ax", buf)
      END;
      EmitInd(buf)
    UNTIL ~IsLexSym(",");
    Expect(")")
  END;
  IF ~ProcFindIsFar(name, isFar) THEN
    isFar := TRUE; PendingAppend(StrTab.Intern(name), line)
  END;
  IF isFar THEN Strings.Copy("call far ", buf) ELSE Strings.Copy("call ", buf) END;
  Strings.Append(name, buf); EmitInd(buf)
END EmitCall;

(* EmitCallNoArgs: 'Name' already consumed, no '(' at all -- SPHINX.MD's
   own worked xmsCopy example calls a bare "XMS_CLEAR_REC;" with no
   parens (SPHINX.MD §13). EmitCall itself can't be reused unchanged
   here: it always starts by checking for an immediate ')' (empty-parens
   "Name()") and otherwise tries to parse whatever follows as a first
   argument -- for a genuinely paren-less call the token right after
   `name` is the statement terminator, not a stray ')', so that check
   would misfire and try to read it as an operand. A bare call always
   has zero arguments, so this skips argument-parsing entirely and goes
   straight to the same call/call-far emission EmitCall itself ends
   with. *)
PROCEDURE EmitCallNoArgs(name: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR; isFar: BOOLEAN;
BEGIN
  IF ~ProcFindIsFar(name, isFar) THEN
    isFar := TRUE; PendingAppend(StrTab.Intern(name), line)
  END;
  IF isFar THEN Strings.Copy("call far ", buf) ELSE Strings.Copy("call ", buf) END;
  Strings.Append(name, buf); EmitInd(buf)
END EmitCallNoArgs;

(* EmitAssignRhs: 'dst :=' already consumed (dst's NASM operand text
   already in buf/destReg form, chosen by caller). If the RHS is
   'Name(args)', emit the call (result in AX per SPHINX.MD §6.4) then
   move AX to the destination if needed; otherwise fall back to the
   ordinary left-to-right expression emitter. *)

(* ---------------- LONGINT register-pair moves (SPHINX.MD §11) ---------------- *)

(* LesLdsInstr: TRUE (with the right mnemonic) if seg:offReg is a valid
   LES/LDS target -- LES always loads its 16-bit register plus ES, LDS
   always loads its register plus DS, from a 32-bit memory operand, so
   "ES:reg" only matches LES and "DS:reg" only matches LDS (never the
   other way around); any other seg name (DX, CS, SS, ...) can't be paired
   with a LES/LDS load at all. offReg itself is not restricted here (8086
   allows LES/LDS into any general 16-bit register, not just BX/SI/DI --
   SPHINX.MD's own table just happens to show those four combinations). *)
PROCEDURE LesLdsInstr(seg: ARRAY OF CHAR; VAR instr: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Strings.EqualICase(seg, "ES") THEN Strings.Copy("les", instr); RETURN TRUE
  ELSIF Strings.EqualICase(seg, "DS") THEN Strings.Copy("lds", instr); RETURN TRUE
  END;
  RETURN FALSE
END LesLdsInstr;

(* IsPlainLongVar: TRUE if nm names a declared, non-CONST LONGINT
   variable, global or local -- the RHS shape LES/LDS actually needs (a
   real 32-bit memory operand, SPHINX.MD §11's own "ES:BX := longvar;").
   A local's "[bp-N]" text (from IdentOperandText) is exactly as valid a
   dword memory operand as a global's bare "[name]" -- both work
   unchanged with HighWordOperand's "+2"-before-']' insertion -- so
   there's no reason to special-case locals out; a LONGINT VAR parameter
   is in fact the common case for this (e.g. "Seek(h: INTEGER; pos:
   LONGINT); BEGIN CX:DX := pos; ..."). *)
PROCEDURE IsPlainLongVar(nm: ARRAY OF CHAR): BOOLEAN;
  VAR si: INTEGER;
BEGIN
  si := FindSym(nm);
  RETURN (si >= 0) & (SymKind(si) = SymVar) & (SymTy(si) = TyLong)
END IsPlainLongVar;

(* EmitRegPairStore: destSeg:destOff := srcSeg:srcOff (both already-read
   register-pair halves) -- always two plain word movs (SPHINX.MD §11's
   own "ES:DI := DX:AX;" example: "MOV DI,AX" / "MOV ES,DX"); LES/LDS
   only ever loads from a 32-bit *memory* operand, never from another
   register pair, so there is no single-instruction form here. *)
PROCEDURE EmitRegPairStore(destSeg, destOff, srcSeg, srcOff: ARRAY OF CHAR);
  VAR buf: ARRAY MaxLine OF CHAR;
BEGIN
  Strings.Copy("mov ", buf); Strings.Append(destOff, buf); Strings.Append(", ", buf);
  Strings.Append(srcOff, buf); EmitInd(buf);
  Strings.Copy("mov ", buf); Strings.Append(destSeg, buf); Strings.Append(", ", buf);
  Strings.Append(srcSeg, buf); EmitInd(buf)
END EmitRegPairStore;

(* HighWordOperand: longVarMem is an already-bracketed memory operand
   (e.g. "[xmsApiEntry]" from IdentOperandText, or "[bp-8]" for a local
   -- the same fully-formed-operand convention EmitExprAssign's own
   destMem parameter already uses throughout this file); returns the
   operand for the dword's high 16 bits, by inserting "+2" just before
   the closing ']' ("[xmsApiEntry+2]" / "[bp-8+2]" -- NASM evaluates the
   arithmetic itself, so textual insertion is sufficient, no need to
   pre-fold "-8+2" into "-6" here). *)
PROCEDURE HighWordOperand(longVarMem: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR n: WORD;
BEGIN
  n := Strings.Length(longVarMem);
  Strings.Copy(longVarMem, dst);
  dst[n - 1] := 0X;   (* drop the trailing ']' *)
  Strings.Append("+2]", dst)
END HighWordOperand;

(* EmitRegPairFromLongVar: destSeg:destOff := longVarMem (an already-
   bracketed operand, see HighWordOperand's own header comment) --
   LES/LDS in one instruction when destSeg is ES or DS (SPHINX.MD §11's
   own table), else the general two-mov fallback (destSeg is some other
   register, e.g. hypothetically "DX:AX := longvar;" has no ES/DS half
   at all). *)
PROCEDURE EmitRegPairFromLongVar(destSeg, destOff, longVarMem: ARRAY OF CHAR);
  VAR instr, hi, buf: ARRAY MaxLine OF CHAR;
BEGIN
  IF LesLdsInstr(destSeg, instr) THEN
    Strings.Copy(instr, buf); Strings.Append(" ", buf); Strings.Append(destOff, buf);
    Strings.Append(", ", buf); Strings.Append(longVarMem, buf); EmitInd(buf)
  ELSE
    HighWordOperand(longVarMem, hi);
    Strings.Copy("mov ", buf); Strings.Append(destOff, buf); Strings.Append(", ", buf);
    Strings.Append(longVarMem, buf); EmitInd(buf);
    Strings.Copy("mov ", buf); Strings.Append(destSeg, buf); Strings.Append(", ", buf);
    Strings.Append(hi, buf); EmitInd(buf)
  END
END EmitRegPairFromLongVar;

(* EmitLongVarFromRegPair: longVarMem := srcSeg:srcOff (longVarMem
   already bracketed, see HighWordOperand's own header comment) --
   LES/LDS only ever *loads* a register pair, never stores one, so
   storing FROM a register pair INTO a LONGINT var is always the two-mov
   form (SPHINX.MD §11's own "longvar := ES:BX;" example:
   "mov [longvar], bx" / "mov [longvar+2], es"). *)
PROCEDURE EmitLongVarFromRegPair(longVarMem, srcSeg, srcOff: ARRAY OF CHAR);
  VAR hi, buf: ARRAY MaxLine OF CHAR;
BEGIN
  HighWordOperand(longVarMem, hi);
  Strings.Copy("mov ", buf); Strings.Append(longVarMem, buf); Strings.Append(", ", buf);
  Strings.Append(srcOff, buf); EmitInd(buf);
  Strings.Copy("mov ", buf); Strings.Append(hi, buf); Strings.Append(", ", buf);
  Strings.Append(srcSeg, buf); EmitInd(buf)
END EmitLongVarFromRegPair;

(* TryParseRegPair: if the current token names a register immediately
   followed by ':' (a bare ':', never ':=' -- SPHINX.MD gives register
   pairs no other spelling), consume 'REG:REG' and return its two halves.
   Used for both LHS and RHS register-pair operands (SPHINX.MD §11) since
   the syntax is identical either side of ':='.

   The scanner has no token-level backtrack (only a 2-*character* raw
   lookahead, see DOCS/SPHO.MD's own design note), so telling "REG:REG"
   apart from a plain "REG" operand needs the register name consumed
   BEFORE the deciding ':' can even be seen. When that ':' turns out not
   to be there, the already-consumed register name would be silently
   lost if this simply returned FALSE -- consumedReg carries it back to
   the caller in that case, so nothing the scanner has already read is
   ever discarded (an earlier version of this procedure had exactly that
   bug: a plain register operand like "[mem] := AL;" made it consume AL,
   find no ':', and return FALSE with AL gone -- the caller's own
   subsequent register check then saw whatever token came after AL
   instead, silently corrupting the parse).

   Returns FALSE with consumedReg set to the register just read (empty
   only when the current token wasn't a register at all, i.e. nothing
   was consumed) if it isn't a genuine pair. *)
PROCEDURE TryParseRegPair(VAR seg, offReg, consumedReg: ARRAY OF CHAR): BOOLEAN;
BEGIN
  consumedReg[0] := 0X;
  IF (tokKind # TIdent) OR ~IsRegName(tokText) THEN RETURN FALSE END;
  Strings.Copy(tokText, seg); Next;
  IF ~IsLexSym(":") THEN Strings.Copy(seg, consumedReg); RETURN FALSE END;
  IF (tokKind # TIdent) OR ~IsRegName(tokText) THEN
    LogErr.Error("spho: expected register after ':' in register pair"); ok := FALSE;
    Strings.Copy("AX", offReg); RETURN TRUE
  END;
  Strings.Copy(tokText, offReg); Next;
  RETURN TRUE
END TryParseRegPair;

(* ParseRegPairAssign: 'destSeg:' already read (destSeg is the LHS's own
   segment half); parses '.offReg := RHS' and dispatches on the RHS's own
   shape -- a register pair (EmitRegPairStore), a plain LONGINT variable
   (EmitRegPairFromLongVar, LES/LDS-eligible), or a call (whose result
   convention is DX:AX per SPHINX.MD §6.4, so 'ES:BX := myfunction();' is
   just 'ES:BX := DX:AX' after the call, per SPHINX.MD §11's own last
   worked example). *)
PROCEDURE ParseRegPairAssign(destSeg: ARRAY OF CHAR);
  VAR destOff, srcSeg, srcOff, consumedReg, nm, longText, msg: ARRAY MaxLine OF CHAR;
BEGIN
  IF (tokKind # TIdent) OR ~IsRegName(tokText) THEN
    LogErr.Error("spho: expected register after ':' in register pair"); ok := FALSE;
    Strings.Copy("AX", destOff)
  ELSE
    Strings.Copy(tokText, destOff); Next
  END;
  Expect(":=");
  IF TryParseRegPair(srcSeg, srcOff, consumedReg) THEN
    EmitRegPairStore(destSeg, destOff, srcSeg, srcOff)
  ELSIF consumedReg[0] # 0X THEN
    (* a lone register (no ':' pair) isn't one of SPHINX.MD §11's
       documented RHS forms (LONGINT VAR / register pair / call) --
       TryParseRegPair already consumed it, so this reports the error
       against what's actually there instead of silently mis-parsing. *)
    Strings.Copy("spho: register-pair RHS must be a LONGINT VAR, a register pair, or a call, not a single register: ", msg);
    Strings.Append(consumedReg, msg); LogErr.Error(msg); ok := FALSE
  ELSIF (tokKind = TIdent) & ~IsRegName(tokText) THEN
    Strings.Copy(tokText, nm); Next;
    IF IsLexSym("(") THEN
      (* 'destSeg:destOff := myfunction();' -- result convention is
         DX:AX (SPHINX.MD §6.4); route through it as if the call's own
         result were a register-pair RHS. *)
      EmitCall(nm);
      EmitRegPairStore(destSeg, destOff, "DX", "AX")
    ELSE
      IdentOperandText(nm, longText);
      IF ~IsPlainLongVar(nm) THEN
        Strings.Copy("spho: register-pair RHS must be a LONGINT VAR or a call: ", msg);
        Strings.Append(nm, msg); LogErr.Error(msg); ok := FALSE
      END;
      EmitRegPairFromLongVar(destSeg, destOff, longText)
    END
  ELSE
    LogErr.Error("spho: expected LONGINT VAR, register pair, or call after ':=' in register-pair assignment");
    ok := FALSE
  END
END ParseRegPairAssign;

(* EmitAssignRhs: destSize (see EmitExprAssign's own header comment) is
   "byte"/"word"/"" -- the destination's own declared storage size when
   known (resolved by the caller from a SymTy/TypeField lookup), used to
   size every path below that stores through AX/AL into memory. Does NOT
   affect the fast-path register-source case just above it (already
   correctly sized from the source register, SPHINX.MD §10's own
   "[ES:BX] := AL;" example) or a register destination (destIsMem=FALSE,
   always its own fixed size regardless of destSize).

   Also handles the reverse LONGINT register-pair direction (SPHINX.MD
   §11's own "longvar := ES:BX;"): destReg/destIsMem is an ordinary
   already-resolved LHS (a plain LONGINT VAR's memory-operand text, in
   this case), and the RHS -- checked first, before any of the ordinary
   expression paths below -- may itself be a bare 'SEG:REG' register
   pair, which none of those paths know how to parse at all (OperandText
   would misread the segment half as a plain register operand and then
   choke on the stray ':'). *)
PROCEDURE EmitAssignRhs(destReg: ARRAY OF CHAR; destIsMem: BOOLEAN; destSize: ARRAY OF CHAR);
  VAR nm, opnd, buf, sfx, srcSeg, srcOff, consumedReg: ARRAY MaxLine OF CHAR;
      regId: INTEGER; gotReg: BOOLEAN;
BEGIN
  gotReg := FALSE;
  IF destIsMem THEN
    IF TryParseRegPair(srcSeg, srcOff, consumedReg) THEN
      EmitLongVarFromRegPair(destReg, srcSeg, srcOff); RETURN
    ELSIF consumedReg[0] # 0X THEN
      (* TryParseRegPair already consumed a lone register (no ':' pair
         followed it) while checking -- feed it straight into the fast
         path below instead of re-reading tokText, which no longer holds
         it (see TryParseRegPair's own header comment on why this can't
         just be re-scanned). *)
      Strings.Copy(consumedReg, nm); gotReg := TRUE
    END
  END;
  (* Fast path: '[mem] := SingleReg;' with no further chained operator --
     size the move from the source register (byte or word) instead of
     always routing through word-sized AX (which corrupts a byte target,
     e.g. SPHINX.MD §10's own "[ES:BX] := AL;"). *)
  IF gotReg OR (destIsMem & (tokKind = TIdent) & IsRegName(tokText)) THEN
    IF ~gotReg THEN Strings.Copy(tokText, nm); Next END;
    IF ~IsChainOp() THEN
      Strings.Copy(nm, opnd); SYSTEM.UPSTR(opnd);
      regId := Lex.LookupReg(opnd);
      IF Lex.IsByteReg(regId) THEN Strings.Copy("byte ", sfx) ELSE Strings.Copy("word ", sfx) END;
      Strings.Copy("mov ", buf); Strings.Append(sfx, buf); Strings.Append(destReg, buf);
      Strings.Append(", ", buf); Strings.Append(nm, buf); EmitInd(buf);
      RETURN
    END;
    EmitExprFrom(nm, "ax");
    MoveAxToDest(destReg, destIsMem, destSize);
    RETURN
  END;
  IF (tokKind = TIdent) & IsBuiltinName(tokText) THEN
    (* ADR/SEG/SIZE/ODD (SPHINX.MD §9): must not fall into the generic
       call-or-plain-var dispatch below, which would treat e.g. "SIZE" as
       an ordinary undeclared variable/call name. *)
    IF destIsMem THEN EmitExpr("ax"); MoveAxToDest(destReg, destIsMem, destSize)
    ELSE EmitExpr(destReg)
    END;
    RETURN
  END;
  (* A plain-identifier RHS (var or call) now falls straight through to
     the generic EmitExprAssign/EmitExpr path below: OperandText itself
     recognizes 'Name(' as a call (emits it, yields "ax" as the operand
     text) and EmitExprFrom/EmitExprTail already chain any operator that
     follows -- a bespoke call-detection branch used to live here
     instead, but it RETURNed immediately after EmitCall, before ever
     checking for a trailing operator ('t := Helper(x) + 1;' silently
     dropped the '+ 1' and then hung the same way OperandText's own
     pre-fix gap did, since the un-consumed '+ 1' was never read either
     — reproduced directly). *)
  IF destIsMem THEN EmitExprAssign(destReg, destSize) ELSE EmitExpr(destReg) END
END EmitAssignRhs;

(* ParseAssignOrCall: an assignment 'dst := expr' (dst is a register, a
   named var, or a '[seg:base]' direct memory operand, SPHINX.MD §10) or
   a procedure call 'Name(args)'. destSize (resolved here, from a
   TypeField lookup for '[seg:base].RecordType.field' or a SymTy lookup
   for a plain named VAR) is threaded into EmitAssignRhs so a BYTE/
   BOOLEAN destination gets a correctly-sized store instead of always a
   word (see EmitExprAssign's own header comment for the bug this
   fixes). *)
PROCEDURE ParseAssignOrCall;
  VAR lhs, buf, msg, destSize: ARRAY MaxLine OF CHAR; si: INTEGER;
BEGIN
  IF IsSym("[") THEN
    Next; ParseMemOperand(buf, destSize);
    Expect(":=");
    EmitAssignRhs(buf, TRUE, destSize)
  ELSIF tokKind = TIdent THEN
    Strings.Copy(tokText, lhs); Next;
    IF IsRegName(lhs) & IsLexSym(":") THEN
      (* 'SEG:REG := ...' (SPHINX.MD §11, LONGINT register-pair moves) --
         lhs was only the segment half; ':' (not ':=') here means a
         register-pair LHS, not a plain register assignment. Handled
         separately since it needs both halves before dispatching on the
         RHS shape (plain longvar/register-pair/call). Previously nothing
         matched this shape at all: IsLexSym(":=") failed on the bare ':'
         token, IsLexSym("(") failed too, so the statement silently
         consumed nothing and ParseStmtList re-parsed the same unconsumed
         ':' forever -- a hang, not merely an unimplemented feature. *)
      ParseRegPairAssign(lhs)
    ELSIF IsLexSym(":=") THEN
      IF IsRegName(lhs) THEN
        EmitAssignRhs(lhs, FALSE, "")
      ELSE
        si := FindSym(lhs);
        IF (si >= 0) & (SymKind(si) = SymConst) THEN
          Strings.Copy("spho: cannot assign to a CONST: ", msg); Strings.Append(lhs, msg);
          LogErr.Error(msg); ok := FALSE
          (* fall through and still consume the RHS via EmitAssignRhs below
             (its emitted text is moot -- LogErr.HaveErr() suppresses the
             whole .ASM output -- but the tokens MUST be consumed, or
             ParseStmtList spins forever re-parsing the same unconsumed
             RHS token: see DOCS/SPHO.MD's LOOP/EXIT note for the class of
             bug this is, a hang, not just a wrong-but-terminating parse). *)
        END;
        SymOperandText(si, lhs, buf);
        (* SymTy is only meaningful for kind=SymVar (a CONST entry's own
           ty field is never set by SymAppend/ParseConstDecl) -- guard
           against reading it for the CONST-error case just above, which
           falls through to here rather than returning early. *)
        IF (si >= 0) & (SymKind(si) = SymVar) THEN SizeHintFor(SymTy(si), destSize)
        ELSE destSize[0] := 0X
        END;
        (* a register-named param (SPHINX.MD §6.2) resolves to a bare
           register name, not a memory operand -- destIsMem must be
           FALSE for it, exactly like the IsRegName(lhs) branch above. *)
        IF (si >= 0) & SymIsReg(si) THEN EmitAssignRhs(buf, FALSE, "")
        ELSE EmitAssignRhs(buf, TRUE, destSize)
        END
      END
    ELSIF IsLexSym("(") THEN
      EmitCall(lhs)
    ELSIF ~IsRegName(lhs) THEN
      (* 'Name;' with no parens at all -- SPHINX.MD §13's own worked
         xmsCopy example calls "XMS_CLEAR_REC;" this exact way (a bare,
         zero-argument procedure call). Only reachable for a non-register
         lhs: no SPHINX construct ever calls a register name, so "AL"
         reaching here (not ':', ':=', or '(') is a genuine error, not a
         bare call -- handled by the final ELSE below instead. *)
      EmitCallNoArgs(lhs)
    ELSE
      (* lhs (already consumed) was a register name followed by none of
         ':' (register pair), ':=' (assignment), or '(' -- e.g.
         "AL = 5;" (bare '=' where SPHINX requires ':='). Nothing here
         would otherwise consume the unexpected token, and neither would
         the next ParseStmt call (it isn't a '[' or a TIdent either), so
         ParseStmtList's own loop would spin on it forever -- report it
         as an error instead of silently hanging (reproduced directly). *)
      Strings.Copy("spho: expected ':=' after register '", msg); Strings.Append(lhs, msg);
      Strings.Append("' near line ", msg); Strings.AppendInt(LONGINT(line), msg);
      LogErr.Error(msg); ok := FALSE; Next
    END
  ELSIF ~IsSym(";") THEN
    (* current token starts neither a '[seg:base] := ...' statement nor
       an identifier-led one, and isn't a bare ';' (a legitimate empty
       statement -- ParseStmt's own trailing "WHILE IsLexSym(';') DO END"
       consumes it right after this call returns, so leaving it
       unconsumed here is correct, not a hang risk). An unexpected symbol
       (bare '=', a stray ')', ...) sitting where a statement was
       expected does need the same "must consume or hang" handling as
       the identifier-led ELSE above, though. *)
    Strings.Copy("spho: unexpected '", msg); Strings.Append(tokText, msg);
    Strings.Append("' near line ", msg); Strings.AppendInt(LONGINT(line), msg);
    LogErr.Error(msg); ok := FALSE; Next
  END
END ParseAssignOrCall;

PROCEDURE ParseIf;
  VAR elseLbl, endLbl: INTEGER;
BEGIN
  elseLbl := NewLabel(); endLbl := NewLabel();
  EmitCondJump(elseLbl, FALSE);
  ExpectKw("THEN");
  ParseStmtList;
  WHILE IsLexKw("ELSIF") DO
    EmitInd2("jmp", endLbl);
    EmitLabel(elseLbl);
    elseLbl := NewLabel();
    EmitCondJump(elseLbl, FALSE);
    ExpectKw("THEN");
    ParseStmtList
  END;
  IF IsLexKw("ELSE") THEN
    EmitInd2("jmp", endLbl);
    EmitLabel(elseLbl);
    ParseStmtList
  ELSE
    EmitLabel(elseLbl)
  END;
  EmitLabel(endLbl);
  ExpectKw("END")
END ParseIf;

PROCEDURE ParseWhile;
  VAR topLbl, exitLbl: INTEGER;
BEGIN
  topLbl := NewLabel(); exitLbl := NewLabel();
  EmitLabel(topLbl);
  EmitCondJump(exitLbl, FALSE);
  ExpectKw("DO");
  INC(loopDepth); loopExitStack[loopDepth] := exitLbl; loopContStack[loopDepth] := topLbl;
  ParseStmtList;
  DEC(loopDepth);
  EmitInd2("jmp", topLbl);
  EmitLabel(exitLbl);
  ExpectKw("END")
END ParseWhile;

(* ParseReturn: RETURN [expr] (SPHINX.MD §6.4/§8.3) -- evaluates expr (if
   present) into AX, then jumps to procExitLbl, the current procedure's
   one epilogue label (ParseProcedure emits the actual epilogue body --
   local-frame cleanup, USES pop, ret/retf/iret -- right after that
   label, exactly once, no matter how many RETURNs reach it). A bare
   "jmp" here is unconditionally correct for a RETURN inside a
   conditional branch too, not only one written as literally the last
   statement of the body: previously this only ever set AX and returned,
   relying entirely on RETURN being the textually final statement --
   `IF cond THEN RETURN x ELSE RETURN y END` (a completely ordinary
   pattern) instead fell through whatever statements followed the IF,
   silently overwriting the "returned" value before the real epilogue
   ever ran (reproduced directly via EXAMPLES/SPHO/A.SMD's own Main,
   which followed such an IF with "AX := 50;"). *)
PROCEDURE ParseReturn;
BEGIN
  IF ~IsSym(";") & (tokKind # TEof) & ~IsKw("END") THEN
    EmitExpr("ax")
  END;
  EmitInd2("jmp", procExitLbl)
END ParseReturn;

(* ParseAsm: copies raw text verbatim until a line whose first word is END. *)
PROCEDURE ParseAsm;
  VAR buf, word: ARRAY MaxLine OF CHAR; i, j: INTEGER; done: BOOLEAN;
BEGIN
  SkipBlanks;
  done := FALSE;
  WHILE ~done & (ch # 0X) DO
    i := 0; buf[0] := 0X; word[0] := 0X; j := -1;
    WHILE (ch # 0X) & (ch # 0AX) DO
      IF (j < 0) & IsIdentStart(ch) THEN j := 0 END;   (* first word starts *)
      IF (j >= 0) & IsIdentCh(ch) & (j < MaxLine-1) THEN
        word[j] := ch; INC(j); word[j] := 0X
      ELSIF j >= 0 THEN
        j := -2   (* first word ended (whitespace/punct after it) *)
      END;
      IF i < MaxLine - 1 THEN buf[i] := ch; INC(i) END;
      NextCh
    END;
    IF ch # 0X THEN NextCh; INC(line) END;
    buf[i] := 0X;
    IF Strings.EqualICase(word, "END") THEN
      done := TRUE
    ELSE
      Strings.Trim(buf);
      IF buf[0] # 0X THEN Emit(buf) END
    END
  END;
  Next
END ParseAsm;

(* EmitIncDec: 'INC('/'DEC(' already parsed up to the argument identifier.
   nm may be a bare register name (SPHINX.MD §9's own "INC(var)" table
   doesn't rule this out, and DOCS/SPHINX.MD §2 registers are ordinary
   assignable "variables" throughout the dialect) -- checked via
   IsRegName BEFORE FindSym, since a register is a LexReg lexeme, a kind
   FindSym never searches (it only ever matches LexConst/LexVar rows);
   passing an unrecognized name straight to SymOperandText(-1, "BX", ...)
   used to silently fall through to its own "bare global label" branch,
   emitting "inc word [BX]" -- incrementing the BYTE/WORD stored AT the
   address BX happens to hold, not the BX register itself (reproduced
   directly: EXAMPLES/SPHO/OUT.SMD's own Out_String does "INC(BX)" to
   advance a string pointer, and got a runaway climbing-byte-value
   pattern printed instead of the string, since the loop's own [BX]
   character was incremented in place on every iteration instead of BX
   ever advancing). A register-named PARAM (SPHINX.MD §6.2, SymIsReg)
   is the separate, pre-existing case below -- its own formal identifier
   IS a register name too, just reached by declaration instead of being
   the literal token "BX"/"AX"/etc.

   For everything else, a single FindSym lookup drives the rest: kind
   (reject CONST: no storage exists to inc/dec, SPHINX.MD §4), and ty
   (byte vs word sizing). *)
(* AddSubMnemonic: the plain-inc/dec mnemonic's own two-operand
   equivalent -- "inc"->"add", "dec"->"sub" -- used for the INC(var,expr)/
   DEC(var,expr) form below, which needs "add opnd, ax"/"sub opnd, ax"
   instead of a bare "inc opnd"/"dec opnd" once a second argument names
   a specific amount rather than "by exactly one". *)
PROCEDURE AddSubMnemonic(mnemonic: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
BEGIN
  IF Strings.EqualICase(mnemonic, "inc") THEN Strings.Copy("add", dst)
  ELSE Strings.Copy("sub", dst)
  END
END AddSubMnemonic;

(* EmitIncDec: 'INC('/'DEC(' already parsed up to the argument
   identifier. Two forms: INC(var) / DEC(var) (SPHINX.MD §9's own
   single-argument table, "by exactly one") -- the original, unchanged
   below -- and INC(var, expr) / DEC(var, expr), an extension: "var :=
   var + expr" / "var := var - expr" in one call, still going through
   the same byte/word-sized destination as the one-argument form (a
   BYTE/BOOLEAN var still stores through AL, never blindly word-sized).
   expr may be an arbitrary expression, including a call (EmitExpr
   handles the full SPHINX.MD §7 left-to-right chain, the same machinery
   every other expression context in this file already uses) -- it is
   evaluated into AX BEFORE opnd's own text is read back out for the
   add/sub, so a register-named var (nm itself, not opnd) is safe even
   though EmitExpr may clobber AX: the register case returns immediately
   below without ever needing opnd's memory text at all. *)
(* EmitIncDecAmountToReg: nm is the register being INC'd/DEC'd by a
   second-argument expr (INC(nm, expr)/DEC(nm, expr)). EmitExpr("ax")
   ALWAYS targets AX, no matter what expr actually is (a plain literal,
   not only a call) -- so if nm IS ax (case-insensitively; AX and ax are
   the same physical register to NASM), evaluating expr overwrites nm's
   own pre-existing value before the add/sub ever reads it, the exact
   same accumulator-clobber EmitTailOperand's own header comment
   describes for chained expressions, just triggered by a register
   collision instead of a call (reproduced directly: "AX := 50;
   INC(AX, 7);" printed 14, not 57 -- EmitExpr("ax") overwrote AX's 50
   with 7 first, so "add AX, ax" read 7+7). Guarded the same way
   EmitTailOperand guards a call clobbering destReg: push nm before
   EmitExpr, stash the freshly-computed amount in CX, pop nm back to its
   real pre-expr value, THEN add/sub against CX. Any OTHER register
   (BX, CX, ...) is never touched by EmitExpr("ax") at all, so no
   push/pop is emitted for those -- zero-cost for the common case. *)
PROCEDURE EmitIncDecAmountToReg(nm, mnemonic: ARRAY OF CHAR);
  VAR buf, addSub: ARRAY MaxLine OF CHAR; nmIsAx: BOOLEAN;
BEGIN
  nmIsAx := Strings.EqualICase(nm, "ax");
  IF nmIsAx THEN Strings.Copy("push ax", buf); EmitInd(buf) END;
  EmitExpr("ax");
  AddSubMnemonic(mnemonic, addSub);
  IF nmIsAx THEN
    Emit("    mov cx, ax");
    Emit("    pop ax");
    Strings.Copy(addSub, buf); Strings.Append(" ax, cx", buf); EmitInd(buf)
  ELSE
    Strings.Copy(addSub, buf); Strings.Append(" ", buf); Strings.Append(nm, buf);
    Strings.Append(", ax", buf); EmitInd(buf)
  END
END EmitIncDecAmountToReg;

PROCEDURE EmitIncDec(mnemonic: ARRAY OF CHAR);
  VAR nm, opnd, buf, sfx, msg, addSub: ARRAY MaxLine OF CHAR; si, ty: INTEGER;
      hasAmount: BOOLEAN;
BEGIN
  Strings.Copy(tokText, nm); Next;
  hasAmount := IsLexSym(",");
  IF IsRegName(nm) THEN
    IF hasAmount THEN EmitIncDecAmountToReg(nm, mnemonic)
    ELSE
      Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
    END;
    RETURN
  END;
  si := FindSym(nm);
  IF (si >= 0) & (SymKind(si) = SymConst) THEN
    Strings.Copy("spho: cannot INC/DEC a CONST: ", msg); Strings.Append(nm, msg);
    LogErr.Error(msg); ok := FALSE; RETURN
  END;
  IF (si >= 0) & SymIsReg(si) THEN
    IF hasAmount THEN EmitIncDecAmountToReg(nm, mnemonic)
    ELSE
      Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
    END;
    RETURN
  END;
  SymOperandText(si, nm, opnd);
  IF (si >= 0) & (SymKind(si) = SymVar) THEN ty := SymTy(si) ELSE ty := TyWord END;
  IF (ty = TyByte) OR (ty = TyBool) THEN
    Strings.Copy("byte", sfx)
  ELSE
    Strings.Copy("word", sfx)
  END;
  IF hasAmount THEN
    (* opnd's own text (a [bp-N]/[name] memory operand) is read back out
       AFTER EmitExpr, exactly like EmitTailOperand's own reasoning:
       EmitExpr may itself emit a call, but opnd here is memory text, not
       a register -- a call clobbering AX never touches it, so no
       push/pop guard is needed the way EmitTailOperand's destReg-in-AX
       case requires. AL, not AX, sizes the add/sub source when the
       destination is byte-sized -- BYTE/BOOLEAN are documented unsigned
       (SPHINX.MD §3.1), so only the low byte of expr's result is ever
       meaningful here anyway. *)
    EmitExpr("ax");
    AddSubMnemonic(mnemonic, addSub);
    Strings.Copy(addSub, buf); Strings.Append(" ", buf); Strings.Append(sfx, buf);
    Strings.Append(" ", buf); Strings.Append(opnd, buf);
    IF Strings.EqualICase(sfx, "byte") THEN Strings.Append(", al", buf)
    ELSE Strings.Append(", ax", buf)
    END;
    EmitInd(buf)
  ELSE
    Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(sfx, buf);
    Strings.Append(" ", buf); Strings.Append(opnd, buf); EmitInd(buf)
  END
END EmitIncDec;

(* ParsePushPop: 'PUSH(r1,r2,...)'/'POP(r1,r2,...)' (SPHINX.MD §9) --
   PUSH pushes left to right; POP pops in reverse order (rN first) so a
   PUSH(AX,BX)/POP(AX,BX) pair round-trips each register back to itself. *)
PROCEDURE ParsePushPop(mnemonic: ARRAY OF CHAR; reverse: BOOLEAN);
  VAR regs: RegList; n, i: INTEGER; buf, msg: ARRAY MaxLine OF CHAR;
BEGIN
  Expect("(");
  n := 0;
  IF ~IsSym(")") THEN
    REPEAT
      IF tokKind # TIdent THEN
        Strings.Copy("spho: expected register name in PUSH/POP near line ", msg);
        Strings.AppendInt(LONGINT(line), msg); LogErr.Error(msg); ok := FALSE
      ELSIF n >= MaxUses THEN
        LogErr.Error("spho: too many registers in PUSH/POP"); ok := FALSE
      ELSE
        Strings.Copy(tokText, regs[n]); INC(n)
      END;
      Next
    UNTIL ~IsLexSym(",")
  END;
  Expect(")");
  IF reverse THEN i := n - 1 ELSE i := 0 END;
  WHILE (i >= 0) & (i < n) DO
    Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(regs[i], buf); EmitInd(buf);
    IF reverse THEN DEC(i) ELSE INC(i) END
  END
END ParsePushPop;

(* ParseStmt: one statement. Statement separator ';' consumed here. *)
PROCEDURE ParseStmt;
  VAR buf: ARRAY MaxLine OF CHAR;
BEGIN
  IF IsLexKw("IF") THEN ParseIf
  ELSIF IsLexKw("WHILE") THEN ParseWhile
  ELSIF IsLexKw("BREAK") THEN
    IF loopDepth >= 0 THEN EmitInd2("jmp", loopExitStack[loopDepth]) END
  ELSIF IsLexKw("CONTINUE") THEN
    IF loopDepth >= 0 THEN EmitInd2("jmp", loopContStack[loopDepth]) END
  ELSIF IsLexKw("RETURN") THEN ParseReturn
  ELSIF IsKw("ASM") THEN ParseAsm
  ELSIF IsLexKw("INC") THEN
    Expect("("); EmitIncDec("inc"); Expect(")")
  ELSIF IsLexKw("DEC") THEN
    Expect("("); EmitIncDec("dec"); Expect(")")
  ELSIF IsLexKw("INT") THEN
    Expect("("); Strings.Copy(tokText, buf); Next; Expect(")");
    Strings.Insert("int ", 0, buf); EmitInd(buf)
  ELSIF IsLexKw("PUSH") THEN ParsePushPop("push", FALSE)
  ELSIF IsLexKw("POP") THEN ParsePushPop("pop", TRUE)
  ELSE
    ParseAssignOrCall
  END;
  WHILE IsLexSym(";") DO END
END ParseStmt;

PROCEDURE ParseStmtList;
BEGIN
  WHILE (tokKind # TEof) & ~IsKw("END") & ~IsKw("ELSE") & ~IsKw("ELSIF") DO
    ParseStmt
  END
END ParseStmtList;

(* ---------------- procedure translation ---------------- *)

(* ParseParams: '(' already consumed. Register-named params get no stack
   slot; others get Pascal-order [bp+4],[bp+6],... (SPHINX.MD §6.1/6.2).
   Only records each param's name/register-ness into vars[] (as a not-
   yet-offset param, regFlags[] mirrors which are register-named).
   Actual [bp+N] offsets depend on isFar, which isn't known until the
   NEAR/FAR keyword is parsed -- textually AFTER the "(params)" list --
   so offset assignment is a separate later step, AssignParamOffsets.

   Formal-parameter groups (SPHINX.MD §6.6: "parameters with different
   types"): 'name {, name} : type' -- a comma-separated run of names
   shares ONE trailing type (standard Oberon FPSection shape, matching
   §6.1's own "Add(a, b: INTEGER)" example, where both a and b are
   INTEGER); ';' starts a new group with its own type, so different
   groups can carry different types in one param list (e.g.
   "x: BYTE; y: INTEGER"). Each name is buffered until the group's own
   type is known, then SymAppend'd/typed together -- resolving each
   name's type independently as soon as it's read (the previous design)
   silently mistyped every name but the last in a shared-type group
   (e.g. "a, b: BYTE" typed 'a' as the TyInt default, not BYTE, since
   only 'b' ever reached the ": BYTE"). A register-named formal (SPHINX.MD
   §6.2) carries no type at all -- typed immediately as it's read, not
   folded into a following group's type, and doesn't force the group to
   end (a register name may sit alongside ordinary names in one comma run,
   though SPHINX.MD gives no such example). *)
PROCEDURE ParseParams(VAR regFlags: ARRAY OF BOOLEAN; VAR sis: ARRAY OF INTEGER; VAR n: INTEGER);
  VAR ty, recIdx, groupStart, i: INTEGER;
      nm: ARRAY MaxName OF CHAR; moreGroups, moreNames: BOOLEAN;
BEGIN
  n := 0;
  IF IsLexKw("REG") THEN END; (* optional leading REG keyword, SPHINX.MD §6.2 *)
  IF ~IsSym(")") THEN
    moreGroups := TRUE;
    WHILE moreGroups DO
      groupStart := n;
      moreNames := TRUE;
      WHILE moreNames DO
        IF n >= MaxParams THEN
          LogErr.Error("spho: too many parameters"); ok := FALSE; moreNames := FALSE; moreGroups := FALSE
        ELSE
          regFlags[n] := IsRegName(tokText);
          Strings.Copy(tokText, nm); Next;
          sis[n] := SymAppend(nm, SymVar);
          SymSetIsLocal(sis[n], TRUE); SymSetIsParam(sis[n], TRUE);
          IF regFlags[n] THEN
            (* register param: no type at all (SPHINX.MD §6.2's own bare
               "PROCEDURE CB_API(AX);" example) -- type it immediately,
               it never participates in a following group's ": type". *)
            SymSetTy(sis[n], TyInt, -1)
          END;
          INC(n);
          moreNames := IsLexSym(",")
        END
      END;
      IF ~IsLexSym(":") THEN ty := TyInt; recIdx := -1
      ELSE ParseBaseType(ty, recIdx)
      END;
      i := groupStart;
      WHILE i < n DO
        IF ~regFlags[i] THEN SymSetTy(sis[i], ty, recIdx) END;
        INC(i)
      END;
      moreGroups := moreGroups & IsLexSym(";")
    END
  END;
  Expect(")")
END ParseParams;

(* RejectRecordParams: a by-value RECORD-typed formal parameter is not
   supported -- the Pascal calling convention (§6.1) pushes/reads a
   parameter as a single word (or byte, for BYTE/BOOLEAN), which silently
   truncates a multi-byte RECORD to its own first word instead of really
   passing the whole value (reproduced directly: a 4-byte record param
   compiled to "mov ax, [rec]; push ax" at the call site -- only the
   first field -- and "retn 2" in the callee's epilogue -- cleaning 2
   bytes, not the record's real size; see DOCS/SPHO.MD "RECORD-by-value
   parameters"). Caught here, right after ParseParams, as a clear
   translator error instead of silently emitting wrong code -- pass
   ADR(rec) into a plain WORD/INTEGER parameter instead (§3.3's own
   pass-by-offset model, already the working pattern for arrays and
   strings). A register-named param (regFlags[i]) is skipped -- SPHINX.MD
   §6.2's register-parameter form has no type at all (ParseParams always
   types it TyInt), so it can never be RECORD-typed in the first place. *)
PROCEDURE RejectRecordParams(VAR regFlags: ARRAY OF BOOLEAN; VAR sis: ARRAY OF INTEGER; n: INTEGER);
  VAR i: INTEGER; msg: ARRAY MaxLine OF CHAR;
BEGIN
  i := 0;
  WHILE i < n DO
    IF ~regFlags[i] & (SymTy(sis[i]) = TyRec) THEN
      Strings.Copy("spho: by-value RECORD parameter not supported near line ", msg);
      Strings.AppendInt(LONGINT(line), msg);
      Strings.Append(" (pass ADR(rec) into a WORD/INTEGER parameter instead)", msg);
      LogErr.Error(msg); ok := FALSE
    END;
    INC(i)
  END
END RejectRecordParams;

(* AssignParamOffsets: called once isFar is finally known (after the
   NEAR/FAR keyword, if any) -- see ParseParams's own header comment.
   Takes sis[] (the real SymAppend-returned index of each param, filled
   by ParseParams) instead of independently recomputing each one as
   "savedLex + i" -- that positional shortcut only works by relying on
   an implicit invariant (params are exactly the n LexemeArray slots
   appended immediately after savedLex, nothing else interleaved) that
   ParseParams's own sis[] array already exists specifically to avoid
   depending on elsewhere in this file (every other lookup here goes
   through a real id/index, never a derived position). *)
PROCEDURE AssignParamOffsets(VAR regFlags: ARRAY OF BOOLEAN; VAR sis: ARRAY OF INTEGER; n: INTEGER; isFar: BOOLEAN; VAR nStack: INTEGER);
  VAR i, retOfs: INTEGER;
BEGIN
  (* saved BP (2 bytes) + return addr: NEAR=2 (IP), FAR=4 (CS:IP) --
     SPHINX.MD §6.1's own worked example: rightmost param at [bp+4] for
     a NEAR proc, i.e. 2 (saved BP) + 2 (return IP). *)
  IF isFar THEN retOfs := 6 ELSE retOfs := 4 END;
  nStack := 0;
  i := n - 1;
  WHILE i >= 0 DO
    IF regFlags[i] THEN
      SymSetIsReg(sis[i], TRUE)  (* accessed by register name directly, no frame slot at all *)
    ELSE
      SymSetOfs(sis[i], -(retOfs + nStack)); (* negative marks [bp+N] via ABS in OperandText *)
      INC(nStack, 2)
    END;
    DEC(i)
  END
END AssignParamOffsets;

PROCEDURE ParseUses(VAR regs: RegList; VAR n: INTEGER);
BEGIN
  n := 0;
  IF IsLexKw("USES") THEN
    REPEAT
      Strings.Copy(tokText, regs[n]); Next; INC(n)
    UNTIL ~IsLexSym(",");
    Expect(";")
  END
END ParseUses;

PROCEDURE EmitUsesPush(VAR regs: RegList; n: INTEGER);
  VAR i: INTEGER; buf: ARRAY 32 OF CHAR;
BEGIN
  i := 0;
  WHILE i < n DO
    IF Strings.EqualICase(regs[i], "FLAGS") THEN Emit("    pushf")
    ELSE Strings.Copy("push ", buf); Strings.Append(regs[i], buf); EmitInd(buf) END;
    INC(i)
  END
END EmitUsesPush;

PROCEDURE EmitUsesPop(VAR regs: RegList; n: INTEGER);
  VAR i: INTEGER; buf: ARRAY 32 OF CHAR;
BEGIN
  i := n - 1;
  WHILE i >= 0 DO
    IF Strings.EqualICase(regs[i], "FLAGS") THEN Emit("    popf")
    ELSE Strings.Copy("pop ", buf); Strings.Append(regs[i], buf); EmitInd(buf) END;
    DEC(i)
  END
END EmitUsesPop;

(* ParseProcedure: 'PROCEDURE' already consumed.

   FORWARD (extension beyond SPHINX.MD's originally-documented grammar --
   see DOCS/SPHINX.MD "FORWARD declarations"): 'PROCEDURE Name(params):
   RetTy; NEAR|FAR; FORWARD;' parses the full signature (so params get
   real frame-offset/register-name checking exactly like a normal
   definition would) and registers isFar via ProcSetIsFar immediately,
   but emits no label/prologue/body at all -- the params' own lexeme rows
   are truncated away right after (LexTruncate to the pre-params mark),
   since they aren't real locals for a body that doesn't exist yet; the
   REAL later definition re-parses its own params afresh under the same
   names. A name already forward-declared (ProcFindAny finds an existing
   row with isValid=FALSE) reuses that row's pi instead of ProcReserve
   creating a second, independent one -- so ProcFindIsFar's backward
   search (which stops at the FIRST matching row) keeps finding the one
   true entry throughout, both before and after the real body fills it
   in. A name already FULLY defined (isValid=TRUE) is a genuine
   duplicate-definition translator error, not silently accepted (the old
   behavior: two full same-named PROCEDUREs compiled with no error at
   all, corrupting the emitted .ASM with a duplicate NASM label instead
   of a clear diagnostic). *)
PROCEDURE ParseProcedure;
  VAR nm: ARRAY 64 OF CHAR; exported, isFar, isInterrupt, hasParams, isFwd, wasValid: BOOLEAN;
      nStack, savedLex, nParams, pi: INTEGER;
      regFlags: ARRAY MaxParams OF BOOLEAN;
      sis: ARRAY MaxParams OF INTEGER;
      uses: RegList; nUses: INTEGER;
      buf, msg: ARRAY MaxLine OF CHAR;
BEGIN
  Strings.Copy(tokText, nm); Next;
  exported := FALSE;
  IF IsLexSym("*") THEN exported := TRUE END;
  (* ProcFindAny/ProcReserve happens BEFORE savedLex is captured: the
     procedure's own name is module-scope (like a TYPE/CONST), but --
     unlike TYPE/CONST, which are always fully parsed before any
     PROCEDURE is reached -- isFar isn't known until after this same
     procedure's own params/NEAR/FAR keyword are parsed (ParseParams's
     own header comment). Reserving the lexeme row here, ahead of
     savedLex, keeps it outside the range LexTruncate discards at the end
     of THIS SAME procedure's own body -- otherwise a later call site (in
     a later procedure) could never find it again: reachable directly by
     any two-procedure file where the second calls the first. *)
  pi := ProcFindAny(nm, wasValid);
  IF pi >= 0 THEN
    IF wasValid THEN
      Strings.Copy("spho: duplicate PROCEDURE definition: ", msg);
      Strings.Append(nm, msg); LogErr.Error(msg); ok := FALSE
    END
    (* pi >= 0 & ~wasValid: reusing an existing FORWARD-pending row --
       fall through with pi already set, no new ProcReserve. *)
  ELSE
    pi := ProcReserve(nm)
  END;
  savedLex := nLex;
  hasParams := IsLexSym("(");
  IF hasParams THEN ParseParams(regFlags, sis, nParams) ELSE nParams := 0 END;
  RejectRecordParams(regFlags, sis, nParams);
  IF IsLexSym(":") THEN
    IF IsLexKw("BYTE") OR IsLexKw("BOOLEAN") OR IsLexKw("WORD") OR IsLexKw("INTEGER")
       OR IsLexKw("LONGINT") THEN END
  END;
  (* exported procedures default to FAR (SPHINX.MD §6.3/notes: "can be
     NEAR/FAR (default - far)"); an explicit NEAR/FAR keyword always wins.
     Params' [bp+N] offsets can only be assigned once isFar is final --
     see ParseParams's own header comment -- hence AssignParamOffsets
     below, after this keyword is parsed. *)
  isFar := exported; isInterrupt := FALSE;
  IF IsLexSym(";") THEN END;
  IF IsLexKw("NEAR") THEN isFar := FALSE; IsLexSym(";")
  ELSIF IsLexKw("FAR") THEN isFar := TRUE; IsLexSym(";")
  ELSIF IsLexKw("INTERRUPT") THEN isInterrupt := TRUE; IsLexSym(";")
  END;
  isFwd := IsLexKw("FORWARD");
  IF isFwd THEN
    IsLexSym(";");
    IF isInterrupt THEN
      LogErr.Error("spho: FORWARD not supported for INTERRUPT procedures"); ok := FALSE
    ELSE
      ProcSetForward(pi, isFar)
    END;
    LexTruncate(savedLex);   (* discard the FORWARD decl's own param rows *)
    RETURN
  END;
  AssignParamOffsets(regFlags, sis, nParams, isFar, nStack);
  IF ~isInterrupt THEN ProcSetIsFar(pi, isFar) END;
  ParseUses(uses, nUses);

  IF exported THEN Emit2("global ", nm) END;
  Emit2(nm, ":");
  Emit("    push bp");
  Emit("    mov  bp, sp");
  EmitUsesPush(uses, nUses);
  frameOfs := 0;
  IF IsLexKw("VAR") THEN ParseVarSection(FALSE) END;
  IF frameOfs > 0 THEN
    Strings.Copy("sub  sp, ", buf); Strings.AppendInt(LONGINT(frameOfs), buf); EmitInd(buf)
  END;

  procExitLbl := NewLabel();
  IF IsLexKw("BEGIN") THEN ParseStmtList END;
  ExpectKw("END");
  IF tokKind = TIdent THEN Next END; (* trailing proc-name repeat *)
  Expect(";");

  (* Every RETURN in the body jumps here (ParseReturn's own header
     comment) instead of falling through -- the epilogue below runs
     exactly once regardless of how many RETURNs reached it, and a body
     that falls off the end without an explicit RETURN reaches the same
     label by falling through it, unaffected. *)
  EmitLabel(procExitLbl);

  IF frameOfs > 0 THEN
    Strings.Copy("add  sp, ", buf); Strings.AppendInt(LONGINT(frameOfs), buf); EmitInd(buf)
  END;
  EmitUsesPop(uses, nUses);
  IF isInterrupt THEN
    Emit("    iret")
  ELSE
    Emit("    mov  sp, bp");
    Emit("    pop  bp");
    IF isFar THEN
      IF nStack > 0 THEN
        Strings.Copy("retf ", buf); Strings.AppendInt(LONGINT(nStack), buf); EmitInd(buf)
      ELSE Emit("    retf") END
    ELSE
      IF nStack > 0 THEN
        Strings.Copy("retn ", buf); Strings.AppendInt(LONGINT(nStack), buf); EmitInd(buf)
      ELSE Emit("    retn") END
    END
  END;
  Emit("");
  LexTruncate(savedLex)   (* pop params/locals off the lexeme table *)
END ParseProcedure;

(* ---------------- module translation ---------------- *)

PROCEDURE OpenInclude(nm: ARRAY OF CHAR): BOOLEAN; FORWARD;
PROCEDURE CloseInclude; FORWARD;

(* ParseModule: isTop = top-level file (may IMPORT, and a BEGIN...END
   becomes 'start') vs. an IMPORTed file (spliced in, but may not itself
   IMPORT or have a BEGIN...END -- see DOCS/SPHO.MD). *)
PROCEDURE ParseModule(isTop: BOOLEAN): BOOLEAN;
  VAR incNm: ARRAY 64 OF CHAR;
BEGIN
  ok := TRUE;
  ExpectKw("MODULE");
  Next; (* module name -- not otherwise used by the translator *)
  Expect(";");

  (* `&` short-circuits in this compiler (Oberon-07 §9.1), so a guard
     written as "isTop & IsLexKw(...)" would never even evaluate
     IsLexKw when isTop=FALSE -- the IMPORT keyword inside an included
     file would then be left completely unconsumed (not an error, not
     skipped, just abandoned mid-stream), silently defeating the
     single-include-level check below instead of triggering it. The
     keyword must always be consumed via IsLexKw so the loop body's own
     ~isTop check can actually run and report it. *)
  WHILE IsLexKw("IMPORT") DO
    IF ~isTop THEN
      LogErr.Error("spho: an IMPORTed file may not itself IMPORT (single include level)");
      ok := FALSE
    END;
    REPEAT
      Strings.Copy(tokText, incNm); Next;
      IF ok THEN
        IF ~OpenInclude(incNm) THEN ok := FALSE
        ELSE
          IF ~ParseModule(FALSE) THEN ok := FALSE END;
          CloseInclude   (* restores the already-fetched token too, see outerTokKind *)
        END
      END
    UNTIL ~IsLexSym(",");
    Expect(";")
  END;
  IF IsLexKw("CONST") THEN
    WHILE (tokKind = TIdent) & ~IsKw("TYPE") & ~IsKw("VAR") & ~IsKw("PROCEDURE")
          & ~IsKw("BEGIN") & ~IsKw("END") DO
      ParseConstDecl
    END
  END;
  IF IsLexKw("TYPE") THEN ParseTypeSection END;
  IF IsLexKw("VAR") THEN ParseVarSection(TRUE) END;

  (* Every file's own PROCEDURE bodies belong in .text -- this used to be
     gated "IF isTop", so an IMPORTed file's procedures (spliced in via
     '#include', DOCS/SPHO.MD) fell through with whatever section was
     still active from the top-level file's own CONST/TYPE/VAR handling
     (.data, or .bss if the last global VAR happened to be an array) --
     every imported PROCEDURE landed under the wrong section header,
     genuinely misplaced in the emitted .ASM (reproduced directly:
     EXAMPLES/SPHO/A.SMD importing FILES.SMD/SYSTEM.SMD put all nine of
     their procedures under "section .data"). EnsureSection makes this
     safe to call unconditionally for both top-level and imported files:
     it only emits a fresh "section .text" line when curSect isn't
     already SectCode, so back-to-back procedure-bearing files (or a
     file with no CONST/TYPE/VAR of its own at all) don't get redundant
     section switches. *)
  EnsureSection(SectCode);
  WHILE IsLexKw("PROCEDURE") DO ParseProcedure END;

  (* a BEGIN...END body is the module's init part -- 'start' marks the
     program entry point (SPHO.MD §"Entry point selection"); only legal
     in the top-level file. *)
  IF IsLexKw("BEGIN") THEN
    IF ~isTop THEN
      LogErr.Error("spho: an IMPORTed file may not have its own BEGIN...END init part");
      ok := FALSE
    ELSE
      Emit("global start");
      Emit("start:")
    END;
    ParseStmtList
  END;
  ExpectKw("END");
  IF tokKind = TIdent THEN Next END;
  Expect(".");
  RETURN ok
END ParseModule;

(* ---------------- driver ---------------- *)

PROCEDURE Usage;
BEGIN
  Out.String("SPHINX Oberon translator, 2026 (c) DosWorld, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("Usage: SPHO file.smd"); Out.Ln;
  Out.Ln;
  Out.String("  Translates file.smd (SPHINX Oberon, see DOCS/SPHINX.MD) to"); Out.Ln;
  Out.String("  file.asm (NASM-subset syntax) -- feed that into TASM.EXE."); Out.Ln
END Usage;

(* OpenSource: open path as the current stream, priming the lookahead.
   Used for the top-level file and (via OpenInclude) an IMPORTed one. *)
PROCEDURE OpenSource(path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ~Files.Reset(srcF, path) THEN
    LogErr.Error2("spho: cannot open ", path); RETURN FALSE
  END;
  line := 1; ch := 0X; ch2 := 0X;
  NextCh; NextCh;
  RETURN TRUE
END OpenSource;

(* OpenInclude: IMPORT ModName = #include ModName.SMD (SPHINX.MD line
   11); saves the includer's state in outer* to resume in CloseInclude.
   Single level only (ParseModule's isTop check enforces it). *)
PROCEDURE OpenInclude;
  VAR path: ARRAY 128 OF CHAR;
BEGIN
  outerF := srcF; outerCh := ch; outerCh2 := ch2; outerLine := line;
  outerTokKind := tokKind; Strings.Copy(tokText, outerTokText); outerTokLex := tokLex;
  Strings.Copy(nm, path); Strings.Append(".SMD", path);
  IF ~OpenSource(path) THEN RETURN FALSE END;
  Next;
  RETURN TRUE
END OpenInclude;

PROCEDURE CloseInclude;
BEGIN
  Files.Close(srcF);
  srcF := outerF; ch := outerCh; ch2 := outerCh2; line := outerLine;
  tokKind := outerTokKind; Strings.Copy(outerTokText, tokText); tokLex := outerTokLex
END CloseInclude;

(* RegisterBuiltins: seeds the unified LexemeArray with every keyword/
   symbol (walking kwSpellings/sySpellings -- InitKwSyTables's own single
   enumeration, id i <-> array index i, so this loop needs no separate
   spelling list of its own) plus every register (still hand-listed:
   Lex.MOD's own Reg* ids aren't a dense 0-based range starting at 0 the
   way Kw*/Sy* are, so a parallel spellings-array-plus-loop would need
   its own id renumbering to index by -- not worth it for 20 fixed
   names; seeded UPPERCASE, matching Lex.LookupReg's own already-
   uppercased-input contract, since FindLexeme/StrTab is exact-byte, not
   case-folded -- IsRegName uppercases its own argument before
   searching). Called once per file at the start of RunBody, after the
   LexemeArray itself is reset.

   Also seeds TRUE/FALSE as ordinary predeclared CONST entries (SPHINX.MD
   §3.1: BOOLEAN is "like BYTE, 0 = FALSE, #0 = TRUE") through the normal
   SymAppend/SymSetVal path so they resolve exactly like any user CONST
   (a direct literal, never a [name] memory read) everywhere a CONST
   already works. Without this seeding, "TRUE"/"FALSE" fell through to
   the plain-identifier case as an ordinary, never-declared variable
   name, emitting a bogus "mov ax, [TRUE]" memory read instead of the
   literal 1/0 (reproduced directly via EXAMPLES/SPHO/A.SMD's own
   "RETURN TRUE").

   A user CONST/VAR of the same spelling as a keyword can never arise
   (SPHINX reserves keyword spellings the same way IsKw/ExpectKw always
   checked kind=LexKw/ref=KwIdOf(...) before falling through to any
   generic-identifier path), so seeding these once up front never creates
   a shadowing conflict for FindSym/FindType/ProcFindIsFar to worry
   about. *)
PROCEDURE RegisterBuiltins;
  VAR si, i: INTEGER;
BEGIN
  i := 0;
  WHILE i < NKw DO LexAppendRaw(kwSpellings[i], LexKw, i); INC(i) END;
  i := 0;
  WHILE i < NSy DO LexAppendRaw(sySpellings[i], LexSym, i); INC(i) END;

  LexAppendRaw("AX", LexReg, Lex.RegAX); LexAppendRaw("CX", LexReg, Lex.RegCX);
  LexAppendRaw("DX", LexReg, Lex.RegDX); LexAppendRaw("BX", LexReg, Lex.RegBX);
  LexAppendRaw("SP", LexReg, Lex.RegSP); LexAppendRaw("BP", LexReg, Lex.RegBP);
  LexAppendRaw("SI", LexReg, Lex.RegSI); LexAppendRaw("DI", LexReg, Lex.RegDI);
  LexAppendRaw("AL", LexReg, Lex.RegAL); LexAppendRaw("CL", LexReg, Lex.RegCL);
  LexAppendRaw("DL", LexReg, Lex.RegDL); LexAppendRaw("BL", LexReg, Lex.RegBL);
  LexAppendRaw("AH", LexReg, Lex.RegAH); LexAppendRaw("CH", LexReg, Lex.RegCH);
  LexAppendRaw("DH", LexReg, Lex.RegDH); LexAppendRaw("BH", LexReg, Lex.RegBH);
  LexAppendRaw("ES", LexReg, Lex.RegES); LexAppendRaw("CS", LexReg, Lex.RegCS);
  LexAppendRaw("SS", LexReg, Lex.RegSS); LexAppendRaw("DS", LexReg, Lex.RegDS);

  si := SymAppend("TRUE", SymConst); SymSetVal(si, 1);
  si := SymAppend("FALSE", SymConst); SymSetVal(si, 0)
END RegisterBuiltins;

(* EmitLiterals: the user's own requested output shape -- one
   ".data"-section "db 'text', 0" line per distinct string literal
   collected during translation, in first-occurrence order, emitted
   once at the very end of RunBody after everything else (so a literal
   used inside, say, PROCEDURE Foo doesn't need its label defined before
   Foo's own body references it -- forward references to a later .data
   label are perfectly normal in NASM). Nothing is emitted at all if no
   string literal ever appeared. Each literal's raw bytes are re-fetched
   from StrTab (StrTab.Get) rather than kept in a second, separate copy
   -- StrTab is already the single source of truth for the exact
   content, LitChunk only remembers WHICH ids are literals and in what
   order. *)
PROCEDURE EmitLiterals;
  VAR c: LitChunk; i, k: INTEGER; text, buf, lbl: ARRAY MaxLine OF CHAR;
BEGIN
  IF nLits = 0 THEN RETURN END;
  EnsureSection(SectData);
  c := litHead; i := 0;
  WHILE c # NIL DO
    k := 0;
    WHILE k < c^.count DO
      StrTab.Get(c^.id[k], text);
      LitLabelName(i, lbl);
      Strings.Copy(lbl, buf); Strings.Append(": db '", buf);
      Strings.Append(text, buf); Strings.Append("', 0", buf);
      Emit(buf);
      INC(k); INC(i)
    END;
    c := c^.next
  END
END EmitLiterals;

PROCEDURE RunBody(): INTEGER;
  VAR outPath: ARRAY 128 OF CHAR;
      argc, i: INTEGER;
BEGIN
  argc := Dos.ParamCount();
  IF argc < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, srcPath);
  IF ~Files.FileExists(srcPath) THEN
    LogErr.Error2("spho: no such file: ", srcPath); RETURN ExitIo
  END;
  (* explicit init, not assumed -- the runtime does not zero module
     globals (see StrTab.MOD's own header comment); lexHead, every
     typeDir/procDir/constDir/varDir slot, and every lexBuckets entry
     must start NIL/-1, not garbage. *)
  nTypes := 0; nLex := 0; nProcs := 0; nConsts := 0; nVars := 0; nLits := 0;
  nPending := 0;
  labelCnt := 0; loopDepth := -1;
  curSect := SectNone;
  lexHead := NIL; lexTail := NIL;
  litHead := NIL; litTail := NIL;
  pendingHead := NIL; pendingTail := NIL;
  i := 0;
  WHILE i < MaxDetailChunks DO
    typeDir[i] := NIL; procDir[i] := NIL; constDir[i] := NIL; varDir[i] := NIL;
    INC(i)
  END;
  i := 0;
  WHILE i < LexBuckets DO lexBuckets[i] := -1; INC(i) END;
  InitKwSyTables;
  RegisterBuiltins;
  IF ~OpenSource(srcPath) THEN RETURN ExitIo END;
  Next;

  Files.ReplaceExt(srcPath, ".ASM", outPath);
  IF ~Files.ReWrite(outF, outPath) THEN
    Files.Close(srcF); LogErr.Error2("spho: cannot write ", outPath); RETURN ExitIo
  END;

  IF ~ParseModule(TRUE) OR LogErr.HaveErr() THEN
    Files.Close(srcF);
    Files.SetDeleteOnClose(outF, TRUE); Files.Close(outF);
    FreeChunks; RETURN ExitAsm
  END;

  (* Every PROCEDURE in the whole translation unit (top-level file + every
     IMPORTed file it spliced in) has now been parsed -- safe to
     re-resolve every call site that couldn't be resolved at the time it
     was emitted (see PendingChunk's own header comment). *)
  CheckPendingCalls;
  IF LogErr.HaveErr() THEN
    Files.Close(srcF);
    Files.SetDeleteOnClose(outF, TRUE); Files.Close(outF);
    FreeChunks; RETURN ExitAsm
  END;

  EmitLiterals;
  Files.Close(srcF);
  Files.Close(outF);
  LogErr.Info2("spho: wrote ", outPath);
  FreeChunks;
  RETURN ExitOk
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  LogErr.Close;
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in spho *)
END Run;

END SPHO.
