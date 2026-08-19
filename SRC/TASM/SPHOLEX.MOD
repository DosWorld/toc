(*$D-*)
MODULE SPHOLEX;
(* spholex -- SPHINX Oberon translator's lexical layer: character-level
   scanner (Next/NextCh/SkipBlanks/ParseNumText/OpenSource/OpenInclude/
   CloseInclude) plus the unified lexeme table (keywords, symbols,
   registers, TYPE/PROCEDURE/CONST/VAR names) and its small per-kind
   detail tables. Split out of SPHO.MOD so the scanner/symbol-table
   layer has its own module boundary from the parser/codegen layer
   (SPHO.MOD, which IMPORTs this). Full design notes: DOCS/SPHO.MD.

   Token state (tokKind/tokText/tokVal/tokLex) is read at nearly every
   parse step in SPHO.MOD but is accessed there only through the CurTok*
   wrapper accessors below, never as bare VARs -- SPHO.MOD has no direct
   view of this module's own internal token-buffer storage.

   ok (sticky translator-failed flag) lives here, not in SPHO.MOD: the
   scanner itself (Next) can fail (an over-long or empty literal) and
   must be able to set it directly, alongside every SPHO.MOD-side parse
   error. ParseModule (SPHO.MOD) is the only reader, via Ok()/SetOk. *)
IMPORT Out, Files, Strings, LogErr, Lex, Scan, StrTab;

CONST
  MaxTok = 64; MaxLine = 256;
  (* MaxName: every identifier-name storage buffer uses this, not a
     disconnected literal 32 -- BUG B3's lesson (SYM.MOD's own header
     comment): a smaller separate bound than the scanner's own MaxTok-1
     silently truncates a long identifier, letting two distinct names
     sharing a common prefix alias to the same stored/interned symbol. *)
  MaxName* = MaxTok;
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
  MaxStrLit* = MaxLine;

  (* token kinds -- TStr (double-quoted "...", any length including 0/1
     chars) is a genuine string literal, needing a .data label; TChar
     (single-quoted '...', always exactly one character) is a plain
     numeric CHAR immediate (its ORD value), the same distinction NASM
     itself makes between a quoted string operand and a character
     literal. Previously both quote styles scanned identically into one
     TStr kind with no way to tell them apart. *)
  TEof* = 0; TIdent* = 1; TNum* = 2; TStr* = 3; TSym* = 4; TChar* = 5;

  (* type kinds *)
  TyByte* = 0; TyBool* = 1; TyWord* = 2; TyInt* = 3; TyLong* = 4; TyRec* = 5;

  (* symbol-table entry kinds -- VAR and CONST share one identifier
     namespace (both are referenced as a bare operand name), so they
     share one table; TYPE is a separate namespace in real Oberon
     (TYPE Point and VAR Point don't collide) and stays its own table. *)
  SymVar* = 0; SymConst* = 1;

  (* LexemeArray kinds -- see the "unified lexeme table" block below.
     Every keyword, symbol, register, TYPE, PROCEDURE, CONST, and VAR
     name in the whole file lives in ONE chunked list (lexHead), each row
     uniform (nameId/kind/ref); `kind` picks which of these seven this
     row is, `ref` means something different per kind (see LexAppend's
     own header comment). *)
  LexKw* = 0; LexSym* = 1; LexReg* = 2; LexType* = 3; LexProc* = 4;
  LexConst* = 5; LexVar* = 6;

  (* Kw* -- hand-numbered id for every keyword SPHO recognizes (LexKw rows'
     own `ref`). Alphabetical, arbitrary numbering -- nothing outside
     RegisterBuiltins/tokLex dispatch ever needs a particular value, only
     identity (kind=LexKw & ref=KwXxx). *)
  KwAsm* = 0; KwBegin* = 1; KwBoolean* = 2; KwBreak* = 3; KwByte* = 4;
  KwConst* = 5; KwContinue* = 6; KwDec* = 7; KwDo* = 8; KwElse* = 9;
  KwElsif* = 10; KwEnd* = 11; KwFar* = 12; KwForward* = 13; KwIf* = 14;
  KwImport* = 15; KwInc* = 16; KwInt* = 17; KwInteger* = 18; KwInterrupt* = 19;
  KwLongint* = 20; KwModule* = 21; KwNear* = 22; KwPop* = 23; KwProcedure* = 24;
  KwPush* = 25; KwRecord* = 26; KwReg* = 27; KwReturn* = 28; KwShl* = 29;
  KwShr* = 30; KwThen* = 31; KwType* = 32; KwUses* = 33;
  KwVar* = 34; KwWhile* = 35; KwWord* = 36; KwXor* = 37;

  (* Sy* -- hand-numbered id for every symbol (LexSym rows' own `ref`),
     including the five relational symbols (#,<,>,<=,>=) which are given
     ids for uniformity but are never looked up via tokLex -- IsRelSym/
     RelJumps/OpInstr (SPHO.MOD) keep reading tokText directly, unchanged. *)
  SyAmp* = 0; SyLParen* = 1; SyRParen* = 2; SyStar* = 3; SyPlus* = 4;
  SyComma* = 5; SyMinus* = 6; SyDot* = 7; SyColon* = 8; SyAssign* = 9;
  SySemi* = 10; SyEq* = 11; SyLBrack* = 12; SyRBrack* = 13; SyBar* = 14;
  SyTilde* = 15; SyNe* = 16; SyLt* = 17; SyGt* = 18; SyLe* = 19; SyGe* = 20;

  (* NKw/NSy: keyword/symbol counts -- one past the last Kw*/Sy* id above.
     kwSpellings/sySpellings (below) hold exactly this many entries,
     index i <-> id i; adding a new keyword/symbol means appending one
     more Kw*/Sy* CONST, bumping this count, and adding its spelling to
     the matching InitKwSyTables assignment -- ONE place, not the old
     two-place (KwIdOf's own dispatch chain + RegisterBuiltins' seeding
     call) duplication. *)
  NKw = 38; NSy = 21;

  MaxFields* = 24; MaxParams* = 16; MaxUses* = 16;

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
  RegList* = ARRAY MaxUses OF ARRAY 32 OF CHAR;
  FieldDef* = RECORD nameId: StrTab.TStrTabId; ty*: INTEGER; recIdx*: INTEGER END;

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
     entries, addressed via procDir[ref DIV Chunk]. EmitCall (SPHO.MOD)
     needs isFar to pick `call` vs `call far` (SPHINX.MD §6.3) -- a bare
     `call` always assembles as a same-module NEAR call regardless of the
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
    isFwdKnown: ARRAY Chunk OF BOOLEAN;  (* TRUE only for a FORWARD-
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
    (* nParams/paramIsReg/paramRegName: the callee's own formal-parameter
       shape, recorded so a CALL SITE can tell -- before it starts
       pushing arguments -- which positions are register-named formals
       (SPHINX.MD §6.2) needing a direct register load instead of a
       stack push. Recorded by ProcSetParams (called once, right after
       ParseParams, alongside ProcSetIsFar/ProcSetForward, all in
       SPHO.MOD) -- an INTERRUPT procedure's own row never reaches
       ProcSetParams (never a valid call target anyway) and a FORWARD
       declaration's own params are irrelevant here (LexTruncate discards
       them; the real definition's own ProcSetParams call, from the SAME
       pi via ProcFindAny, is what actually matters). *)
    nParams: ARRAY Chunk OF INTEGER;
    paramIsReg: ARRAY Chunk OF ARRAY MaxParams OF BOOLEAN;
    paramRegName: ARRAY Chunk OF ARRAY MaxParams OF ARRAY 32 OF CHAR
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
     read these instead of each separately hand-listing all 38+21 names
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
  outerPath: ARRAY 128 OF CHAR;
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
     (Reset below) -- FreeChunks DISPOSEs exactly the ones that were ever
     allocated. *)
  typeDir: ARRAY MaxDetailChunks OF TypeChunk;
  nTypes: INTEGER;

  procDir: ARRAY MaxDetailChunks OF ProcChunk;
  nProcs: INTEGER;

  constDir: ARRAY MaxDetailChunks OF ConstChunk;
  nConsts: INTEGER;

  varDir: ARRAY MaxDetailChunks OF VarChunk;
  nVars: INTEGER;

  ok: BOOLEAN;             (* sticky success flag -- SPHO.MOD's ParseModule
                               is the only reader (via Ok), but both this
                               module's own scanner (Next) and every
                               SPHO.MOD parse-error site can set it FALSE. *)

(* ---------------- token-state accessors (wrapper form, per design) ---------------- *)

PROCEDURE CurTokKind*(): INTEGER;
BEGIN RETURN tokKind
END CurTokKind;

PROCEDURE CurTokText*(VAR dst: ARRAY OF CHAR);
BEGIN Strings.Copy(tokText, dst)
END CurTokText;

PROCEDURE CurTokVal*(): LONGINT;
BEGIN RETURN tokVal
END CurTokVal;

PROCEDURE CurTokLex*(): INTEGER;
BEGIN RETURN tokLex
END CurTokLex;

(* TokTextEqICase/TokTextEq: TRUE if the CURRENT token's own text equals s
   (case-insensitively / exactly) -- convenience wrappers over CurTokText
   for the common "check tokText's spelling without needing its own local
   copy" call sites (SPHO.MOD's IsRegName/IsBuiltinName-style checks and
   the ADR/SEG/SIZE/ODD dispatch), so those sites need no local buffer of
   their own at all. *)
PROCEDURE TokTextEqICase*(s: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Strings.EqualICase(tokText, s)
END TokTextEqICase;

PROCEDURE TokTextEq*(s: ARRAY OF CHAR): BOOLEAN;
BEGIN RETURN Strings.Equal(tokText, s)
END TokTextEq;

(* ---------------- misc shared-state accessors ---------------- *)

PROCEDURE SrcPath*(VAR dst: ARRAY OF CHAR);
BEGIN Strings.Copy(srcPath, dst)
END SrcPath;

PROCEDURE CurLine*(): INTEGER;
BEGIN RETURN line
END CurLine;

PROCEDURE Ok*(): BOOLEAN;
BEGIN RETURN ok
END Ok;

PROCEDURE SetOk*(v: BOOLEAN);
BEGIN ok := v
END SetOk;

(* ReportError: LogErr.ErrorInFile(srcPath, LONGINT(line), msg) + ok :=
   FALSE in one call -- srcPath/line are this module's own private
   scanner state, so every SPHO.MOD-side diagnostic site (which used to
   read both bare VARs directly, before the split) goes through this
   instead of needing its own local srcPath copy just to report an
   error. *)
PROCEDURE ReportError*(msg: ARRAY OF CHAR);
BEGIN
  LogErr.ErrorInFile(srcPath, LONGINT(line), msg); ok := FALSE
END ReportError;

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
PROCEDURE LexAppendRaw*(nm: ARRAY OF CHAR; kind, ref: INTEGER): INTEGER;
  VAR last: LexChunk; li, k: INTEGER; id: StrTab.TStrTabId; b: INTEGER;
BEGIN
  IF (lexTail = NIL) OR (lexTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("out of memory (lexeme table)"); ok := FALSE; RETURN nLex END;
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
  Out.String("DEBUG LexAppendRaw nm=["); Out.String(nm); Out.String("] id="); Out.Int(INTEGER(id),0);
  Out.String(" li="); Out.Int(li,0); Out.String(" bucket="); Out.Int(b,0); Out.Ln;
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
(* CurLexMark: current nLex watermark -- ParseProcedure (SPHO.MOD) saves
   this before parsing a procedure's own params/locals, later passed
   back to LexTruncate to pop them off the lexeme table again. *)
PROCEDURE CurLexMark*(): INTEGER;
BEGIN RETURN nLex
END CurLexMark;

PROCEDURE LexTruncate*(savedLex: INTEGER);
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
PROCEDURE FindLexeme*(nm: ARRAY OF CHAR): INTEGER;
  VAR id: StrTab.TStrTabId; c: LexChunk; k, li: INTEGER;
BEGIN
  id := StrTab.Find(nm);
  Out.String("DEBUG FindLexeme nm=["); Out.String(nm); Out.String("] id="); Out.Int(INTEGER(id), 0); Out.Ln;
  IF id = 0 THEN RETURN -1 END;
  li := lexBuckets[INTEGER(id) MOD LexBuckets];
  Out.String("DEBUG bucket="); Out.Int(INTEGER(id) MOD LexBuckets, 0); Out.String(" firstLi="); Out.Int(li, 0); Out.Ln;
  WHILE li >= 0 DO
    LexChunkFor(li, c, k);
    IF c^.nameId[k] = id THEN RETURN li END;
    li := c^.hnext[k]
  END;
  RETURN -1
END FindLexeme;

PROCEDURE LexKind*(li: INTEGER): INTEGER;
  VAR c: LexChunk; k: INTEGER;
BEGIN LexChunkFor(li, c, k); RETURN c^.kind[k]
END LexKind;

PROCEDURE LexRef*(li: INTEGER): INTEGER;
  VAR c: LexChunk; k: INTEGER;
BEGIN LexChunkFor(li, c, k); RETURN c^.ref[k]
END LexRef;

PROCEDURE LexName*(li: INTEGER; VAR dst: ARRAY OF CHAR);
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
    IF constDir[bi] = NIL THEN LogErr.Error("out of memory (const table)"); ok := FALSE; RETURN LexAppendRaw(nm, LexConst, 0) END
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
    IF varDir[bi] = NIL THEN LogErr.Error("out of memory (var table)"); ok := FALSE; RETURN LexAppendRaw(nm, LexVar, 0) END
  END;
  si := LexAppendRaw(nm, LexVar, vi);
  VarChunkFor(vi, last, k);
  last^.isReg[k] := FALSE;   (* NEW'd chunks are not zeroed -- explicit default *)
  RETURN si
END VarAppend;

(* ---- SymXxx accessors: si is a LexemeArray index whose row kind is
   LexConst or LexVar (never checked here -- callers only ever pass an si
   that FindSym/SymAppend variants already established as one of those two
   kinds, exactly like the old shared-SymChunk API's own contract). ---- *)

PROCEDURE SymName*(si: INTEGER; VAR dst: ARRAY OF CHAR);
BEGIN LexName(si, dst)
END SymName;

PROCEDURE SymKind*(si: INTEGER): INTEGER;
  VAR k: INTEGER;
BEGIN
  k := LexKind(si);
  IF k = LexConst THEN RETURN SymConst ELSE RETURN SymVar END
END SymKind;

PROCEDURE SymTy*(si: INTEGER): INTEGER;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.ty[k]
END SymTy;

PROCEDURE SymSetTy*(si, ty, recIdx: INTEGER);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.ty[k] := ty; c^.recIdx[k] := recIdx
END SymSetTy;

PROCEDURE SymIsLocal*(si: INTEGER): BOOLEAN;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.isLocal[k]
END SymIsLocal;

PROCEDURE SymSetIsLocal*(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isLocal[k] := v
END SymSetIsLocal;

PROCEDURE SymOfs*(si: INTEGER): INTEGER;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.ofs[k]
END SymOfs;

PROCEDURE SymSetOfs*(si, ofs: INTEGER);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.ofs[k] := ofs
END SymSetOfs;

PROCEDURE SymSetIsParam*(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isParam[k] := v
END SymSetIsParam;

PROCEDURE SymIsReg*(si: INTEGER): BOOLEAN;
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); RETURN c^.isReg[k]
END SymIsReg;

PROCEDURE SymSetIsReg*(si: INTEGER; v: BOOLEAN);
  VAR c: VarChunk; k: INTEGER;
BEGIN VarChunkFor(LexRef(si), c, k); c^.isReg[k] := v
END SymSetIsReg;

PROCEDURE SymVal*(si: INTEGER): LONGINT;
  VAR c: ConstChunk; k: INTEGER;
BEGIN ConstChunkFor(LexRef(si), c, k); RETURN c^.val[k]
END SymVal;

PROCEDURE SymSetVal*(si: INTEGER; val: LONGINT);
  VAR c: ConstChunk; k: INTEGER;
BEGIN ConstChunkFor(LexRef(si), c, k); c^.val[k] := val
END SymSetVal;

(* SymAppend: intern nm and add a fresh lexeme row of the given kind
   (SymVar/SymConst) at the end of the LexemeArray, returning its si.
   Caller fills the kind-specific fields (ty/recIdx/isLocal/ofs/isParam
   for SymVar, val for SymConst) afterward -- same contract the old
   shared-SymChunk SymAppend had, now dispatching to VarAppend/
   ConstAppend instead of a single table. *)
PROCEDURE SymAppend*(nm: ARRAY OF CHAR; kind: INTEGER): INTEGER;
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
PROCEDURE FindSym*(nm: ARRAY OF CHAR): INTEGER;
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
PROCEDURE TypeAppend*(nm: ARRAY OF CHAR; aliasTy: INTEGER): INTEGER;
  VAR last: TypeChunk; ti, bi, k: INTEGER;
BEGIN
  ti := nTypes; INC(nTypes);
  bi := ti DIV Chunk;
  IF typeDir[bi] = NIL THEN
    NEW(typeDir[bi]);
    IF typeDir[bi] = NIL THEN LogErr.Error("out of memory (type table)"); ok := FALSE; RETURN ti END
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
PROCEDURE FindType*(nm: ARRAY OF CHAR): INTEGER;
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

PROCEDURE TypeName*(ti: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); StrTab.Get(c^.nameId[k], dst)
END TypeName;

PROCEDURE TypeNFields*(ti: INTEGER): INTEGER;
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); RETURN c^.nFields[k]
END TypeNFields;

PROCEDURE TypeAliasTy*(ti: INTEGER): INTEGER;
  VAR c: TypeChunk; k: INTEGER;
BEGIN TypeChunkFor(ti, c, k); RETURN c^.aliasTy[k]
END TypeAliasTy;

(* TypeAddField: append a field to type ti's own (fixed-size, MaxFields-
   bounded) field list -- a single record's field count is not the kind
   of unbounded whole-file accumulation the chunk rule targets. *)
PROCEDURE TypeAddField*(ti: INTEGER; nm: ARRAY OF CHAR; ty, recIdx: INTEGER);
  VAR c: TypeChunk; k, fi: INTEGER;
BEGIN
  TypeChunkFor(ti, c, k);
  fi := c^.nFields[k];
  IF fi >= MaxFields THEN
    LogErr.ErrorInFile(srcPath, LONGINT(line), "too many fields in RECORD"); ok := FALSE; RETURN
  END;
  c^.fields[k][fi].nameId := StrTab.Intern(nm);
  c^.fields[k][fi].ty := ty; c^.fields[k][fi].recIdx := recIdx;
  c^.nFields[k] := fi + 1
END TypeAddField;

PROCEDURE TypeField*(ti, fi: INTEGER; VAR nm: ARRAY OF CHAR; VAR ty, recIdx: INTEGER);
  VAR c: TypeChunk; k: INTEGER;
BEGIN
  TypeChunkFor(ti, c, k);
  StrTab.Get(c^.fields[k][fi].nameId, nm);
  ty := c^.fields[k][fi].ty; recIdx := c^.fields[k][fi].recIdx
END TypeField;

(* TypeFindFieldTy: linear scan of ti's own field list for fieldName --
   used by ParseMemOperand (SPHO.MOD) to resolve a '.RecordType.field'
   access's own declared type, so its later assignment can be sized
   correctly (a BYTE field, e.g. StructXmsRec.src_high in SPHINX.MD §13's
   own worked example, must not get a word-sized store). FALSE (ty left
   TyWord) if ti < 0 or fieldName isn't found -- matches ParseMemOperand's
   own existing "field not found" tolerance (it still emits the bare
   field name as NASM text on that path). *)
PROCEDURE TypeFindFieldTy*(ti: INTEGER; fieldName: ARRAY OF CHAR; VAR ty, recIdx: INTEGER): BOOLEAN;
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
   ParseProcedure (SPHO.MOD) BEFORE its own savedLex watermark, same
   textual position the procedure's name is read at. A duplicate name
   (re-declaration) just overwrites via a fresh append -- ProcFindIsFar
   finds the most-recent (last) match, same shadowing order as FindSym.
   Returns pi, so ParseProcedure can pass it back to ProcSetIsFar once
   isFar is finally known (after the NEAR/FAR keyword, if any). NEWs a
   fresh procDir block only when pi is about to cross into one that
   hasn't been allocated yet. *)
PROCEDURE ProcReserve*(nm: ARRAY OF CHAR): INTEGER;
  VAR last: ProcChunk; pi, bi, k: INTEGER;
BEGIN
  pi := nProcs; INC(nProcs);
  bi := pi DIV Chunk;
  IF procDir[bi] = NIL THEN
    NEW(procDir[bi]);
    IF procDir[bi] = NIL THEN LogErr.Error("out of memory (proc table)"); ok := FALSE; RETURN -1 END
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
  last^.nParams[k] := 0;   (* NEW'd chunks are not zeroed -- explicit default;
                                 ProcParamIsReg's own range check (i >= nParams)
                                 must see 0, not garbage, until ProcSetParams
                                 (real definition only) fills this in. *)
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
PROCEDURE ProcSetIsFar*(pi: INTEGER; isFar: BOOLEAN);
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
PROCEDURE ProcSetForward*(pi: INTEGER; isFar: BOOLEAN);
  VAR c: ProcChunk; k: INTEGER;
BEGIN ProcChunkFor(pi, c, k); c^.isFar[k] := isFar; c^.valid[k] := FALSE; c^.isFwdKnown[k] := TRUE
END ProcSetForward;

(* ProcSetParams: records the callee's own formal-parameter shape (see
   ProcChunkDesc's own header comment) -- regFlags[i]/sis[i] are
   ParseParams's own output arrays; sis[i]'s symbol name IS the register
   name text for a register-named param (SymAppend(nm, SymVar) used that
   literal text when ParseParams first created it), recovered via
   SymName. Called once per ParseProcedure (real definition only -- a
   FORWARD declaration's own params are discarded by LexTruncate before
   this would matter, and an INTERRUPT procedure is never a valid call
   target regardless). *)
PROCEDURE ProcSetParams*(pi: INTEGER; VAR regFlags: ARRAY OF BOOLEAN; VAR sis: ARRAY OF INTEGER; n: INTEGER);
  VAR c: ProcChunk; k, i: INTEGER;
BEGIN
  ProcChunkFor(pi, c, k);
  c^.nParams[k] := n;
  i := 0;
  WHILE i < n DO
    c^.paramIsReg[k][i] := regFlags[i];
    IF regFlags[i] THEN SymName(sis[i], c^.paramRegName[k][i]) END;
    INC(i)
  END
END ProcSetParams;

(* ProcParamIsReg: TRUE (and the register's own name text) if pi's i-th
   formal parameter (0-based) is register-named -- used by EmitCall/
   EmitCallNoArgs (SPHO.MOD) at a call site to decide whether an argument
   needs a direct register load instead of a stack push. FALSE (regName
   untouched) if pi is out of range, i is out of range, or the callee's
   own ProcSetParams was never called for it (an INTERRUPT row, or a
   FORWARD-pending row whose real body hasn't been parsed yet -- neither
   is ever a valid call target in the first place, so a call site
   reaching this for either case falls back to the ordinary push path,
   same as before this fix existed). *)
PROCEDURE ProcParamIsReg*(pi, i: INTEGER; VAR regName: ARRAY OF CHAR): BOOLEAN;
  VAR c: ProcChunk; k: INTEGER;
BEGIN
  IF (pi < 0) OR (pi >= nProcs) THEN RETURN FALSE END;
  ProcChunkFor(pi, c, k);
  IF (i < 0) OR (i >= c^.nParams[k]) THEN RETURN FALSE END;
  IF ~c^.paramIsReg[k][i] THEN RETURN FALSE END;
  Strings.Copy(c^.paramRegName[k][i], regName);
  RETURN TRUE
END ProcParamIsReg;

(* ProcFindIsFar: TRUE/set isFar if nm names a PROCEDURE parsed so far
   (searched backward, most-recent wins, mirrors FindSym) OR a FORWARD-
   declared one (isFwdKnown[], SPHINX.MD "FORWARD declarations" -- a
   FORWARD declaration's own isFar is already trustworthy for a call site
   even though the real body hasn't been parsed yet); result FALSE (not
   found) for a genuine forward reference with no FORWARD declaration, or
   a symbol defined only externally (e.g. via ASM/IMPORT-spliced source
   not yet reached, or a genuinely external label) -- EmitCall's caller
   (SPHO.MOD) decides the fallback for that case (PendingAppend +
   CheckPendingCalls, now a hard error at end-of-file instead of a
   silent FAR-call guess). *)
PROCEDURE ProcFindIsFar*(nm: ARRAY OF CHAR; VAR isFar: BOOLEAN): BOOLEAN;
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
PROCEDURE ProcFindAny*(nm: ARRAY OF CHAR; VAR isValid: BOOLEAN): INTEGER;
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
  VAR v: LONGINT; errMsg: ARRAY 40 OF CHAR;
BEGIN
  IF ~Scan.ParseNumBuf(text, INTEGER(Strings.Length(text)), FALSE, v, errMsg) THEN
    LogErr.ErrorInFile(srcPath, LONGINT(line), errMsg); ok := FALSE
  END;
  RETURN v
END ParseNumText;

(* ReadAsmLine: raw-copy one line of verbatim ASM text (ParseAsm, SPHO.MOD
   -- 'ASM ... END' blocks pass their body through unparsed/untokenized,
   copying raw source bytes rather than going through Next's normal
   tokenization). Reads directly from ch/NextCh/line (private scanner
   state, not exposed as bare VARs outside this module) up to the next
   newline or EOF, filling buf with the raw line text and firstWord with
   its first identifier-shaped run (so the caller can check for the
   terminating "END" without re-scanning buf itself) -- atEnd is TRUE at
   EOF (ch = 0X on entry, nothing read). Caller must call SkipAsmLead
   once before the first ReadAsmLine call (ParseAsm's own leading
   SkipBlanks, unchanged) -- subsequent calls need no SkipBlanks of
   their own, since ASM body text is copied byte-for-byte including any
   internal blank lines/indentation, never skipped. *)
(* SkipAsmLead: ParseAsm's own one-time SkipBlanks call, before its first
   ReadAsmLine -- skips the whitespace/comment run right after the ASM
   keyword (still the current, unconsumed token at that point) up to the
   first real body line. Never called again for the rest of the ASM
   block: each subsequent ReadAsmLine call reads a raw line verbatim,
   preserving any internal blank lines/indentation exactly as written. *)
PROCEDURE SkipAsmLead*;
BEGIN SkipBlanks
END SkipAsmLead;

PROCEDURE ReadAsmLine*(VAR buf: ARRAY OF CHAR; VAR firstWord: ARRAY OF CHAR; VAR atEnd: BOOLEAN);
  VAR i, j: INTEGER;
BEGIN
  atEnd := (ch = 0X);
  IF atEnd THEN buf[0] := 0X; firstWord[0] := 0X; RETURN END;
  i := 0; buf[0] := 0X; firstWord[0] := 0X; j := -1;
  WHILE (ch # 0X) & (ch # 0AX) DO
    IF (j < 0) & IsIdentStart(ch) THEN j := 0 END;   (* first word starts *)
    IF (j >= 0) & IsIdentCh(ch) & (j < LEN(firstWord)-1) THEN
      firstWord[j] := ch; INC(j); firstWord[j] := 0X
    ELSIF j >= 0 THEN
      j := -2   (* first word ended (whitespace/punct after it) *)
    END;
    IF i < LEN(buf) - 1 THEN buf[i] := ch; INC(i) END;
    NextCh
  END;
  IF ch # 0X THEN NextCh; INC(line) END;
  buf[i] := 0X
END ReadAsmLine;

(* Next: fetch the next token into tokKind/tokText/tokVal/tokLex. tokLex
   is the resolved LexemeArray index of this token's own spelling
   (FindLexeme, most-recent-wins shadowing) for TIdent/TSym -- the only
   two kinds that ever name a lexeme -- and -1 for TNum/TStr/TChar/TEof. *)
PROCEDURE Next*;
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
      Strings.Copy("string/char literal too long (max ", msg);
      Strings.AppendInt(LONGINT(MaxStrLit - 1), msg);
      Strings.Append(" chars)", msg);
      LogErr.ErrorInFile(srcPath, LONGINT(line), msg); ok := FALSE;
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
        Strings.Copy("empty char literal ''", msg);
        LogErr.ErrorInFile(srcPath, LONGINT(line), msg); ok := FALSE;
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
   ExpectKw call site passes a literal keyword spelling, so this linear
   search's own table is exhaustive by construction -- adding a new
   keyword anywhere means adding one more Kw* CONST, a matching
   kwSpellings assignment in InitKwSyTables, and bumping NKw -- ONE
   place, not separately updating a dispatch chain here AND
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
PROCEDURE IsKw*(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (tokKind = TIdent) & (tokLex >= 0) & (LexKind(tokLex) = LexKw) & (LexRef(tokLex) = KwIdOf(kw))
END IsKw;

(* IsSym: TRUE if the CURRENT token is the symbol spelling s -- same
   tokLex-based comparison as IsKw, for LexSym rows. *)
PROCEDURE IsSym*(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN (tokKind = TSym) & (tokLex >= 0) & (LexKind(tokLex) = LexSym) & (LexRef(tokLex) = SyIdOf(s))
END IsSym;

(* IsLex pattern (DOCS/IMPLRULE.MD): peek + consume-on-match, kw form *)
PROCEDURE IsLexKw*(kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF IsKw(kw) THEN Next; RETURN TRUE END;
  RETURN FALSE
END IsLexKw;

PROCEDURE IsLexSym*(s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF IsSym(s) THEN Next; RETURN TRUE END;
  RETURN FALSE
END IsLexSym;

PROCEDURE Expect*(s: ARRAY OF CHAR);
  VAR msg: ARRAY 96 OF CHAR;
BEGIN
  IF ~IsLexSym(s) THEN
    Strings.Copy("expected '", msg); Strings.Append(s, msg);
    Strings.Append("' got '", msg); Strings.Append(tokText, msg); Strings.Append("'", msg);
    LogErr.ErrorInFile(srcPath, LONGINT(line), msg); ok := FALSE
  END
END Expect;

PROCEDURE ExpectKw*(kw: ARRAY OF CHAR);
  VAR msg: ARRAY 96 OF CHAR;
BEGIN
  IF ~IsLexKw(kw) THEN
    Strings.Copy("expected '", msg); Strings.Append(kw, msg); Strings.Append("'", msg);
    LogErr.ErrorInFile(srcPath, LONGINT(line), msg); ok := FALSE
  END
END ExpectKw;

(* IsRegName: delegates to Lex.LookupReg (the register-name source of
   truth TASM.EXE itself uses) instead of a hand-written OR-chain, so
   SPHO can never silently drift from what TASM.EXE actually accepts. *)
PROCEDURE IsRegName*(s: ARRAY OF CHAR): BOOLEAN;
  VAR up: ARRAY 32 OF CHAR; li: INTEGER;
BEGIN
  Strings.Copy(s, up); SYSTEM.UPSTR(up);
  li := FindLexeme(up);
  RETURN (li >= 0) & (LexKind(li) = LexReg)
END IsRegName;

(* CurTokIsReg: TRUE if the CURRENT token's own text names a register --
   IsRegName(CurTokText()) without needing a local buffer at the call
   site, the common case throughout SPHO.MOD's own call/operand dispatch. *)
PROCEDURE CurTokIsReg*(): BOOLEAN;
BEGIN RETURN IsRegName(tokText)
END CurTokIsReg;

(* ---------------- driver-facing setup/reset ---------------- *)

(* OpenSource: open path as the current stream, priming the lookahead.
   Used for the top-level file and (via OpenInclude) an IMPORTed one.
   Updates srcPath to path -- every LogErr.ErrorInFile call reads srcPath
   as "the file the current line number belongs to", so this must happen
   before any diagnostic reachable from the newly-opened file's own
   parsing runs (otherwise a mid-IMPORT error would misreport itself
   against whichever file was open before). *)
PROCEDURE OpenSource*(path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ~Files.Reset(srcF, path) THEN
    LogErr.Error2("cannot open ", path); RETURN FALSE
  END;
  Strings.Copy(path, srcPath);
  line := 1; ch := 0X; ch2 := 0X;
  NextCh; NextCh;
  RETURN TRUE
END OpenSource;

(* OpenInclude: IMPORT ModName = #include ModName.SMD (SPHINX.MD line
   11); saves the includer's state in outer* (including its own srcPath,
   via outerPath) to resume in CloseInclude. Single level only (SPHO.MOD's
   ParseModule isTop check enforces it). *)
PROCEDURE OpenInclude*(nm: ARRAY OF CHAR): BOOLEAN;
  VAR path: ARRAY 128 OF CHAR;
BEGIN
  outerF := srcF; outerCh := ch; outerCh2 := ch2; outerLine := line;
  Strings.Copy(srcPath, outerPath);
  outerTokKind := tokKind; Strings.Copy(tokText, outerTokText); outerTokLex := tokLex;
  Strings.Copy(nm, path); Strings.Append(".SMD", path);
  IF ~OpenSource(path) THEN RETURN FALSE END;
  Next;
  RETURN TRUE
END OpenInclude;

PROCEDURE CloseInclude*;
BEGIN
  Files.Close(srcF);
  srcF := outerF; ch := outerCh; ch2 := outerCh2; line := outerLine;
  Strings.Copy(outerPath, srcPath);
  tokKind := outerTokKind; Strings.Copy(outerTokText, tokText); tokLex := outerTokLex
END CloseInclude;

(* CloseSource: closes the CURRENT top-level srcF -- RunBody (SPHO.MOD)
   calls this once (success or error exit), never CloseInclude (which
   only ever closes an IMPORTed file's own stream and resumes the
   includer's). srcF is otherwise private to this module. *)
PROCEDURE CloseSource*;
BEGIN Files.Close(srcF)
END CloseSource;

(* SetSrcPath: RunBody (SPHO.MOD) reads the top-level path off the
   command line into its own buffer before OpenSource is ever called
   (its own srcPath doubles as the FileExists check target) -- this
   copies that starting value in so OpenSource's very first call, and
   any diagnostic before it, agree with what RunBody already reported. *)
PROCEDURE SetSrcPath*(path: ARRAY OF CHAR);
BEGIN Strings.Copy(path, srcPath)
END SetSrcPath;

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
PROCEDURE RegisterBuiltins*;
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
  si := SymAppend("FALSE", SymConst); SymSetVal(si, 0);
  Out.String("DEBUG end-of-RegisterBuiltins lexBuckets[22]="); Out.Int(lexBuckets[22], 0); Out.Ln
END RegisterBuiltins;

(* Reset: explicit init, not assumed -- the runtime does not zero module
   globals (see StrTab.MOD's own header comment); lexHead, every
   typeDir/procDir/constDir/varDir slot, and every lexBuckets entry must
   start NIL/-1, not garbage. Called once per RunBody, before
   InitKwSyTables/RegisterBuiltins. *)
PROCEDURE Reset*;
  VAR i: INTEGER;
BEGIN
  nTypes := 0; nLex := 0; nProcs := 0; nConsts := 0; nVars := 0;
  lexHead := NIL; lexTail := NIL;
  i := 0;
  WHILE i < MaxDetailChunks DO
    typeDir[i] := NIL; procDir[i] := NIL; constDir[i] := NIL; varDir[i] := NIL;
    INC(i)
  END;
  i := 0;
  WHILE i < LexBuckets DO lexBuckets[i] := -1; INC(i) END;
  InitKwSyTables;
  RegisterBuiltins
END Reset;

(* FreeChunks: DISPOSE every allocated node/block (zero-leak rule --
   CLAUDE.md "ZERO HEAP LEAKS"). Called once at the very end of RunBody
   (SPHO.MOD). lexHead is still a linked list (walked next-pointer
   style); typeDir/procDir/constDir/varDir are fixed-size directories
   (MaxDetailChunks's own header comment) -- DISPOSE only the slots that
   were ever NEW'd (non-NIL), leaving the rest NIL for the next RunBody
   call. *)
PROCEDURE FreeChunks*;
  VAR xc, xn: LexChunk; i: INTEGER;
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
  END
END FreeChunks;

END SPHOLEX.
