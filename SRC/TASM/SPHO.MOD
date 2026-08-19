(*$M 32000,192000,650000*)
(*$D-*)
MODULE SPHO;
(* spho -- SPHINX Oberon dialect translator: SRCFILE.SMD -> SRCFILE.ASM
   (NASM-subset, feed into TASM.EXE). Single recursive-descent pass, no
   AST: each Parse* procedure both parses its construct and emits its
   NASM text before returning. Full design notes: DOCS/SPHO.MD.

   The lexical layer -- character-level scanner, unified lexeme table,
   TYPE/PROCEDURE/CONST/VAR detail tables, and the sticky `ok` failure
   flag -- lives in SPHOLEX (IMPORTed below); every token-state read
   here goes through its SPHOLEX.CurTok*() wrapper accessors, never a
   bare tokKind/tokText/tokVal/tokLex VAR. *)
IMPORT Out, Dos, Files, Strings, LogErr, Lex, SPHOLEX, StrTab;

CONST
  ExitOk = 0; ExitUsage = 2; ExitIo = 3; ExitAsm = 4;

  MaxLine = SPHOLEX.MaxStrLit;   (* NASM output-line buffer size; shares
                                     SPHOLEX's own MaxStrLit bound, the
                                     widest token-text buffer in the
                                     translator, since an emitted line can
                                     embed a full string-literal token. *)
  MaxName = SPHOLEX.MaxName;

  TEof = SPHOLEX.TEof; TIdent = SPHOLEX.TIdent; TNum = SPHOLEX.TNum;
  TStr = SPHOLEX.TStr; TSym = SPHOLEX.TSym; TChar = SPHOLEX.TChar;

  TyByte = SPHOLEX.TyByte; TyBool = SPHOLEX.TyBool; TyWord = SPHOLEX.TyWord;
  TyInt = SPHOLEX.TyInt; TyLong = SPHOLEX.TyLong; TyRec = SPHOLEX.TyRec;

  SymVar = SPHOLEX.SymVar; SymConst = SPHOLEX.SymConst;

  MaxFields = SPHOLEX.MaxFields; MaxParams = SPHOLEX.MaxParams; MaxUses = SPHOLEX.MaxUses;

  Chunk = 64;   (* LitChunk/PendingChunk's own append-chunk size (CLAUDE.md
                   "Chunk small records") -- independent of SPHOLEX's own
                   internal Chunk constant, just the same conventional value. *)

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

TYPE
  RegList = SPHOLEX.RegList;

  (* LitChunk: every distinct string literal seen so far, in first-
     occurrence order -- StrTab itself is shared with every identifier
     name in this file (SPHOLEX's own lexeme table nameId field), so it
     has no notion of "which ids are literals" on its own; this is the
     separate list that tracks exactly that, letting RunBody emit one
     ".data" line per distinct literal at the very end (the user's own
     requested "_literalNNNN: db 'literal', 0" table). No SPHINX
     construct ever references a literal's own text back by name, so
     literals stay OUT of SPHOLEX's unified lexeme table entirely --
     LitChunk is not a lexeme kind, it's a separate append-only list.
     StrTab.Intern/Find already dedups by exact content (never case-
     folded, unlike the identifier tables that share the same underlying
     store -- literal bytes are stored and compared exactly as written),
     so EmitStringLiteral only appends an id here the first time it's
     seen; a repeated literal reuses the same id and therefore the same
     label. *)
  LitChunk = POINTER TO LitChunkDesc;
  LitChunkDesc = RECORD
    id:    ARRAY Chunk OF StrTab.TStrTabId;
    count: INTEGER;
    next:  LitChunk
  END;

  (* PendingChunk: every call site emitted against a procedure name not
     yet resolvable (SPHOLEX.ProcFindIsFar returned FALSE -- no
     PROCEDURE with this name parsed so far, and no FORWARD declaration
     for it either), in first-occurrence order. EmitCall/EmitCallNoArgs
     record one entry per such call (name + source line, for a useful
     error message) and default to a FAR call exactly as before --
     unchanged for the common case where the name IS defined later in
     the file without a FORWARD (e.g. calling a procedure that will turn
     out to be FAR anyway, or one whose caller comes after it in file
     order and never hits this path at all). CheckPendingCalls (end of
     RunBody, after every PROCEDURE has been parsed) re-resolves each
     recorded name: still unresolved AND never FORWARD-declared is now a
     hard translator error (a forward call to a NEAR procedure with no
     FORWARD line silently corrupts the stack via a wrong FAR call --
     reproduced directly, see DOCS/SPHO.MD "FORWARD declarations"),
     instead of the old silent FAR-call guess. *)
  PendingChunk = POINTER TO PendingChunkDesc;
  PendingChunkDesc = RECORD
    id:    ARRAY Chunk OF StrTab.TStrTabId;
    line:  ARRAY Chunk OF INTEGER;
    fname: ARRAY Chunk OF ARRAY 128 OF CHAR;   (* srcPath at PendingAppend
                                       time -- CheckPendingCalls runs at
                                       end-of-file, after every IMPORTed
                                       file has already been closed and
                                       srcPath restored to the top-level
                                       file's own path, so the call
                                       site's own filename (which may be
                                       an IMPORTed file, not the top-level
                                       one) must be captured up front,
                                       the same way line[] already is. *)
    count: INTEGER;
    next:  PendingChunk
  END;

VAR
  outF: Files.File;

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
      Strings.Copy("call to '", msg);
      Strings.Append(nm, msg);
      Strings.Append("' precedes its own definition with no FORWARD declaration", msg);
      LogErr.ErrorInFile(pc^.fname[k], LONGINT(pc^.line[k]), msg); SPHOLEX.SetOk(FALSE);
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
   contract as the SPHOLEX detail tables' own VarAppend/ConstAppend/
   TypeAppend/ProcReserve. *)
PROCEDURE LitAppend(id: StrTab.TStrTabId): INTEGER;
  VAR last: LitChunk; li, k: INTEGER;
BEGIN
  IF (litTail = NIL) OR (litTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("out of memory (literal table)"); SPHOLEX.SetOk(FALSE); RETURN nLits END;
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
   interned StrTab id), source line, and source FILENAME (srcPath at the
   time of the call -- see PendingChunkDesc's own fname[] header comment
   for why this must be captured now, not re-read later), for
   CheckPendingCalls to re-resolve once the whole file has been parsed.
   Same append-only chunk-growth shape as LitAppend. *)
PROCEDURE PendingAppend(id: StrTab.TStrTabId; ln: INTEGER);
  VAR last: PendingChunk; pi, k: INTEGER; sp: ARRAY 128 OF CHAR;
BEGIN
  IF (pendingTail = NIL) OR (pendingTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("out of memory (pending-call table)"); SPHOLEX.SetOk(FALSE); RETURN END;
    last^.count := 0; last^.next := NIL;
    IF pendingHead = NIL THEN pendingHead := last ELSE pendingTail^.next := last END;
    pendingTail := last
  END;
  pi := nPending; INC(nPending);
  last := pendingTail;
  WHILE pi >= Chunk DO last := last^.next; DEC(pi, Chunk) END;
  k := pi;
  SPHOLEX.SrcPath(sp);
  last^.id[k] := id; last^.line[k] := ln; Strings.Copy(sp, last^.fname[k]);
  last^.count := k + 1
END PendingAppend;

(* InternStringLiteral: text is a double-quoted string literal's
   already-scanned content (SPHOLEX.CurTokText, no quotes). Interns it
   via StrTab (exact byte content, dedup for free -- a repeated literal
   reuses the same StrTab id and therefore the same label) and returns
   its NASM label text -- the literal's own address, which is all a
   caller ever needs (SPHINX has no string-VALUE operations, only
   pass-by-offset: "literal possible pass to procedure call (pass
   offset) and assign (offset) to 16-bit regs", the user's own words) --
   callers use dst as a bare operand, exactly like a global VAR's own
   name resolves to its address as an immediate elsewhere in this file. *)
PROCEDURE InternStringLiteral(text: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR id: StrTab.TStrTabId; li: INTEGER;
BEGIN
  id := StrTab.Intern(text);
  li := LitIndexOf(id);
  IF li < 0 THEN li := LitAppend(id) END;
  LitLabelName(li, dst)
END InternStringLiteral;

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

(* IsZeroLiteral: TRUE if s is a numeric-literal spelling of zero via
   the decimal ("0", "00", ...) or trailing-H/B-suffix (SPHO.MD's own
   documented trailing-H-hex/trailing-B-binary forms, e.g. "0H") shapes
   -- NOT the C-style "0x..." prefix hex form (a leading zero followed
   by a non-digit, non-H/B letter falls through to FALSE here, missing
   this one optimization case, never wrong -- just the plain "mov reg,0"
   fallback instead of "xor reg,reg" for that one spelling). Used by
   EmitExprFrom's own "reg := 0" -> "xor reg,reg" optimization --
   deliberately a direct digit-scan rather than routing through
   Scan.ParseNumBuf (SPHOLEX's ParseNumText's own parser): firstOpnd here
   might just as easily be a register name, a "[bp-N]" memory operand, or
   a bare identifier, none of which should ever reach a numeric parser at
   all (risking a spurious error side effect for a string that was
   never meant to be numeric in the first place) -- checking "is every
   digit character '0'" first, and bailing on the first non-digit/
   non-zero character, needs no parser and can never misfire on a
   non-numeric operand. *)
PROCEDURE IsZeroLiteral(s: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  IF ~SYSTEM.ISDIGIT(s[0]) THEN RETURN FALSE END;
  i := 0;
  WHILE SYSTEM.ISDIGIT(s[i]) DO
    IF s[i] # "0" THEN RETURN FALSE END;
    INC(i)
  END;
  (* every digit seen so far was '0' -- what follows must be nothing
     (plain "0"/"00") or a single trailing H/X/B literal-kind suffix
     (SPHO.MD's own documented decimal/trailing-H-hex/trailing-B-binary
     forms) for this to still mean zero. Deliberately checks for
     EXACTLY those three letters, not "any trailing letter" -- a hex
     literal like "0A" (no H suffix) has a real nonzero hex digit right
     where a suffix would be, and must NOT be mistaken for zero; only
     H/X/B are ever valid immediately after an all-zero digit run in
     this dialect's own numeric-literal grammar. *)
  IF s[i] = 0X THEN RETURN TRUE END;
  IF s[i+1] # 0X THEN RETURN FALSE END;
  RETURN (s[i] = "H") OR (s[i] = "h") OR (s[i] = "X") OR (s[i] = "x")
       OR (s[i] = "B") OR (s[i] = "b")
END IsZeroLiteral;


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
     WHILE i < SPHOLEX.TypeNFields(recIdx) DO
       SPHOLEX.TypeField(recIdx, i, fnm, fty, frecIdx);
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
  VAR ti, aliasTy: INTEGER; nm: ARRAY MaxName OF CHAR;
BEGIN
  recIdx := -1;
  IF SPHOLEX.IsLexKw("BYTE") THEN ty := TyByte
  ELSIF SPHOLEX.IsLexKw("BOOLEAN") THEN ty := TyBool
  ELSIF SPHOLEX.IsLexKw("WORD") THEN ty := TyWord
  ELSIF SPHOLEX.IsLexKw("INTEGER") THEN ty := TyInt
  ELSIF SPHOLEX.IsLexKw("LONGINT") THEN ty := TyLong
  ELSIF SPHOLEX.CurTokKind() = TIdent THEN
    SPHOLEX.CurTokText(nm);
    ti := SPHOLEX.FindType(nm);
    IF ti >= 0 THEN
      aliasTy := SPHOLEX.TypeAliasTy(ti);
      IF aliasTy = TyRec THEN ty := TyRec; recIdx := ti
      ELSE ty := aliasTy   (* non-RECORD alias: use its real scalar type *)
      END
    ELSE
      ty := TyWord
    END;
    SPHOLEX.Next
  ELSE
    ty := TyWord; SPHOLEX.Next
  END
END ParseBaseType;

(* ParseBaseTypeName: like ParseBaseType's own scalar-keyword matching,
   but resolves an already-read name string (nm) instead of consuming the
   current token itself -- used by SIZE(T) (SPHINX.MD §9), where the type
   name has already been copied out and SPHOLEX.Next-ed past by the caller before
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
    Strings.Copy("unknown type name in SIZE(): ", msg); Strings.Append(nm, msg);
    SPHOLEX.ReportError(msg); ty := TyWord
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
  ti := SPHOLEX.TypeAppend(nm, TyRec);
  Emit2("struc ", nm);
  more := TRUE;
  WHILE more & (SPHOLEX.CurTokKind() = TIdent) DO
    SPHOLEX.CurTokText(fieldName); SPHOLEX.Next;
    SPHOLEX.Expect(":");
    ParseBaseType(ty, recIdx);
    SPHOLEX.TypeAddField(ti, fieldName, ty, recIdx);
    ResSuffix(ty, sfx);
    Strings.Copy("    .", buf); Strings.Append(fieldName, buf);
    Strings.Append(": ", buf); Strings.Append(sfx, buf); Strings.Append(" 1", buf);
    Emit(buf);
    more := SPHOLEX.IsLexSym(";")
  END;
  SPHOLEX.ExpectKw("END");
  Emit("endstruc")
END ParseRecordType;

PROCEDURE ParseTypeSection;
  VAR nm: ARRAY MaxName OF CHAR; msg: ARRAY 128 OF CHAR; ty, recIdx: INTEGER;
BEGIN
  WHILE (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsKw("VAR") & ~SPHOLEX.IsKw("PROCEDURE") & ~SPHOLEX.IsKw("BEGIN") & ~SPHOLEX.IsKw("END") DO
    SPHOLEX.CurTokText(nm); SPHOLEX.Next;
    SPHOLEX.Expect("=");
    IF SPHOLEX.IsLexKw("RECORD") THEN ParseRecordType(nm)
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
        Strings.Copy("TYPE alias of a RECORD type not supported: ", msg);
        Strings.Append(nm, msg); SPHOLEX.ReportError(msg)
      ELSE
        SPHOLEX.TypeAppend(nm, ty)
      END
    END;
    SPHOLEX.Expect(";")
  END
END ParseTypeSection;

(* ParseConstDecl: 'name = numericLiteral;' -- SPHINX.MD §4: named INTEGER/
   WORD/BYTE/LONGINT values, no storage allocated. Recorded so later
   references (IdentOperandText) emit the literal value instead of a
   bogus [name] memory read. *)
PROCEDURE ParseConstDecl;
  VAR nm, msg: ARRAY MaxLine OF CHAR; val: LONGINT; neg: BOOLEAN; si: INTEGER;
BEGIN
  SPHOLEX.CurTokText(nm); SPHOLEX.Next;
  SPHOLEX.Expect("=");
  neg := SPHOLEX.IsLexSym("-");   (* CONST Foo = -5; -- SPHOLEX.CurTokVal() is only ever set for
                              a TNum token, so the '-' must be consumed
                              separately before reading it, or val silently
                              reads the '-' TSym's own (unset) SPHOLEX.CurTokVal(). *)
  IF SPHOLEX.CurTokKind() = TNum THEN
    val := SPHOLEX.CurTokVal(); SPHOLEX.Next
  ELSE
    Strings.Copy("expected numeric literal in CONST", msg);
    SPHOLEX.ReportError(msg); val := 0
  END;
  IF neg THEN val := -val END;
  si := SPHOLEX.SymAppend(nm, SymConst);
  SPHOLEX.SymSetVal(si, val);
  SPHOLEX.Expect(";")
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
  SPHOLEX.SymName(si, nm); ty := SPHOLEX.SymTy(si);
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
   is allowed") a CONST identifier. SPHOLEX.CurTokVal() is only ever populated by the
   scanner for a TNum token, so a bare `cnt := INTEGER(SPHOLEX.CurTokVal())` silently
   read 0/stale for a CONST name -- resolve through the symbol table
   instead, and report a translator error for anything else (an
   undeclared name, or a VAR used where a constant bound is required)
   rather than silently emitting a wrong-sized reservation. *)
PROCEDURE ParseArrayBound(): INTEGER;
  VAR si: INTEGER; nm, msg: ARRAY MaxLine OF CHAR;
BEGIN
  IF SPHOLEX.CurTokKind() = TNum THEN
    si := INTEGER(SPHOLEX.CurTokVal()); SPHOLEX.Next; RETURN si
  ELSIF SPHOLEX.CurTokKind() = TIdent THEN
    SPHOLEX.CurTokText(nm); SPHOLEX.Next;
    si := SPHOLEX.FindSym(nm);
    IF (si >= 0) & (SPHOLEX.SymKind(si) = SymConst) THEN RETURN INTEGER(SPHOLEX.SymVal(si)) END;
    Strings.Copy("array bound is not a numeric literal or CONST: ", msg);
    Strings.Append(nm, msg); SPHOLEX.ReportError(msg); RETURN 1
  ELSE
    SPHOLEX.ReportError("expected array bound"); RETURN 1
  END
END ParseArrayBound;

(* 'NAME: T[N]' -- array of N elements of T (SPHINX.MD §3.1). *)
PROCEDURE ParseVarSection(isGlobal: BOOLEAN);
  VAR nm: ARRAY MaxName OF CHAR; ty, recIdx, si, cnt, elemSz: INTEGER;
      hasInit: BOOLEAN; initVal: LONGINT; buf, rsfx: ARRAY MaxLine OF CHAR;
      isArr: BOOLEAN;
BEGIN
  WHILE (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsKw("PROCEDURE") & ~SPHOLEX.IsKw("BEGIN") & ~SPHOLEX.IsKw("END") DO
    SPHOLEX.CurTokText(nm); SPHOLEX.Next;
    SPHOLEX.Expect(":");
    ParseBaseType(ty, recIdx);
    isArr := FALSE; cnt := 1;
    IF SPHOLEX.IsLexSym("[") THEN
      isArr := TRUE;
      cnt := ParseArrayBound();
      SPHOLEX.Expect("]")
    END;
    hasInit := FALSE; initVal := 0;
    IF SPHOLEX.IsLexSym("=") THEN
      hasInit := TRUE; initVal := SPHOLEX.CurTokVal(); SPHOLEX.Next
    END;
    si := SPHOLEX.SymAppend(nm, SymVar);
    SPHOLEX.SymSetTy(si, ty, recIdx); SPHOLEX.SymSetIsLocal(si, ~isGlobal); SPHOLEX.SymSetIsParam(si, FALSE);
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
      SPHOLEX.SymSetOfs(si, frameOfs)
    END;
    SPHOLEX.Expect(";")
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
   si (SPHOLEX.FindSym(nm), or -1 if never declared) instead of looking it up
   again -- shared by IdentOperandText itself and by callers that already
   had to resolve si for their own purposes (e.g. to reject a CONST
   target, or to check SymIsReg), so nm's symbol is looked up at most
   once per reference. *)
PROCEDURE SymOperandText(si: INTEGER; nm: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR ofs: INTEGER;
BEGIN
  IF (si >= 0) & (SPHOLEX.SymKind(si) = SymConst) THEN
    dst[0] := 0X; Strings.AppendInt(SPHOLEX.SymVal(si), dst); RETURN
  END;
  IF (si >= 0) & SPHOLEX.SymIsReg(si) THEN
    (* register-named param (SPHINX.MD §6.2): the actual formal-parameter
       identifier IS the register name -- reuse it verbatim, no [bp+N]
       frame slot exists for it at all. *)
    Strings.Copy(nm, dst); RETURN
  END;
  IF (si >= 0) & SPHOLEX.SymIsLocal(si) THEN
    ofs := SPHOLEX.SymOfs(si);
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
BEGIN SymOperandText(SPHOLEX.FindSym(nm), nm, dst)
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
  seg[0] := 0X; SPHOLEX.CurTokText(base); SPHOLEX.Next;
  haveSeg := FALSE;
  IF SPHOLEX.IsLexSym(":") THEN
    haveSeg := TRUE; Strings.Copy(base, seg); SPHOLEX.CurTokText(base); SPHOLEX.Next
  END;
  SPHOLEX.Expect("]");
  Strings.Copy("[", dst);
  IF haveSeg THEN Strings.Append(seg, dst); Strings.Append(":", dst); Strings.Append(base, dst)
  ELSE Strings.Append(base, dst)
  END;
  IF SPHOLEX.IsLexSym(".") THEN
    SPHOLEX.CurTokText(fieldName); SPHOLEX.Next;   (* RecordType name *)
    ti := SPHOLEX.FindType(fieldName);
    SPHOLEX.Expect(".");
    SPHOLEX.CurTokText(fieldName); SPHOLEX.Next;   (* field name *)
    Strings.Append(" + ", dst);
    IF ti >= 0 THEN
      SPHOLEX.TypeName(ti, recTyName);
      Strings.Append(recTyName, dst); Strings.Append(".", dst); Strings.Append(fieldName, dst);
      IF SPHOLEX.TypeFindFieldTy(ti, fieldName, fty, frecIdx) THEN SizeHintFor(fty, sizeHint) END
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
  IF SPHOLEX.IsRegName(arg) THEN RETURN FALSE END;
  si := SPHOLEX.FindSym(arg);
  RETURN (si >= 0) & ~SPHOLEX.SymIsLocal(si)
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
  IF ~SPHOLEX.SymIsLocal(si) THEN
    Strings.Copy(arg, dst); RETURN
  END;
  IF SPHOLEX.SymIsReg(si) THEN
    Strings.Copy("ADR() of a register-named param has no address: ", msg);
    Strings.Append(arg, msg); SPHOLEX.ReportError(msg); Strings.Copy("0", dst); RETURN
  END;
  SymOperandText(si, arg, mem);
  Strings.Copy("lea ax, ", buf); Strings.Append(mem, buf); EmitInd(buf);
  Strings.Copy("ax", dst)
END EmitAdrOperand;

PROCEDURE TryBuiltinOperand(VAR dst: ARRAY OF CHAR): BOOLEAN;
  VAR nm, arg, msg: ARRAY MaxLine OF CHAR; ty, recIdx, ti, si: INTEGER;
      wasValid: BOOLEAN;
BEGIN
  IF SPHOLEX.TokTextEqICase("ADR") THEN
    SPHOLEX.Next; SPHOLEX.Expect("(");
    IF SPHOLEX.CurTokKind() = TIdent THEN
      SPHOLEX.CurTokText(arg); SPHOLEX.Next;
      si := SPHOLEX.FindSym(arg);
      IF (si >= 0) & ~SPHOLEX.IsRegName(arg) THEN
        EmitAdrOperand(arg, si, dst)
      ELSIF ~SPHOLEX.IsRegName(arg) & (SPHOLEX.ProcFindAny(arg, wasValid) >= 0) THEN
        (* ADR(ProcName): a PROCEDURE's own bare label name already IS
           its offset as a NASM immediate ("mov ax, NEW_CB_INT"), the
           identical convention a global VAR's own bare name already
           uses (EmitAdrOperand's own "~SPHOLEX.SymIsLocal(si) THEN
           Strings.Copy(arg, dst)" fast path, just reached through
           ProcFindAny instead of FindSym since a PROCEDURE name is
           never a FindSym match -- FindSym only ever searches
           LexConst/LexVar rows, never LexProc). Needed so a call site
           installing an interrupt vector (SETINTVECT-style, INT 21h/
           AH=25h -- DS:DX = new vector) can get the handler's own
           offset without a raw ASM block (reproduced directly: before
           this, ADR(NEW_CB_INT) was rejected as "requires a declared
           VAR or param name", forcing EXAMPLES/CLIPDRV/CLIPDRV.SMD's
           own INSTALL to fall back to "ASM mov ax, NEW_CB_INT END"
           instead). Whether the named procedure is FORWARD-pending or
           already fully defined makes no difference here -- either way
           it already has a real NASM label reserved under this exact
           name, which is all a bare-offset reference needs. *)
        Strings.Copy(arg, dst)
      ELSE
        Strings.Copy("ADR() requires a declared VAR, param, or PROCEDURE name: ", msg);
        Strings.Append(arg, msg); SPHOLEX.ReportError(msg); Strings.Copy("0", dst)
      END
    ELSE
      SPHOLEX.ReportError("expected variable or procedure name in ADR()"); SPHOLEX.Next; Strings.Copy("0", dst)
    END;
    SPHOLEX.Expect(")"); RETURN TRUE
  ELSIF SPHOLEX.TokTextEqICase("SEG") THEN
    SPHOLEX.Next; SPHOLEX.Expect("(");
    IF SPHOLEX.CurTokKind() = TIdent THEN
      SPHOLEX.CurTokText(arg); SPHOLEX.Next;
      IF ~IsGlobalVarName(arg) THEN
        Strings.Copy("SEG() requires a global VAR name: ", msg);
        Strings.Append(arg, msg); SPHOLEX.ReportError(msg); Strings.Copy("0", dst)
      ELSE
        Strings.Copy("seg ", dst); Strings.Append(arg, dst)
      END
    ELSE
      SPHOLEX.ReportError("expected variable name in SEG()"); SPHOLEX.Next; Strings.Copy("0", dst)
    END;
    SPHOLEX.Expect(")"); RETURN TRUE
  ELSIF SPHOLEX.TokTextEqICase("SIZE") THEN
    SPHOLEX.Next; SPHOLEX.Expect("(");
    IF SPHOLEX.CurTokKind() = TIdent THEN
      SPHOLEX.CurTokText(nm); SPHOLEX.Next;
      ti := SPHOLEX.FindType(nm);
      IF ti >= 0 THEN ty := TyRec; recIdx := ti
      ELSE ParseBaseTypeName(nm, ty, recIdx) END;
      dst[0] := 0X; Strings.AppendInt(LONGINT(TySize(ty, recIdx)), dst)
    ELSE
      SPHOLEX.ReportError("expected a type name in SIZE()"); SPHOLEX.Next; Strings.Copy("0", dst)
    END;
    SPHOLEX.Expect(")"); RETURN TRUE
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
  VAR discardSize, nm: ARRAY MaxLine OF CHAR;
BEGIN
  IF SPHOLEX.CurTokKind() = TNum THEN
    SPHOLEX.CurTokText(dst); SPHOLEX.Next
  ELSIF SPHOLEX.CurTokKind() = TChar THEN
    (* single-quoted 'x' (SPHINX.MD gives no worked example, but this
       mirrors NASM's own character-literal immediate) -- a plain
       numeric operand, SPHOLEX.CurTokVal() already holds ORD(the one character). *)
    dst[0] := 0X; Strings.AppendInt(SPHOLEX.CurTokVal(), dst); SPHOLEX.Next
  ELSIF SPHOLEX.CurTokKind() = TStr THEN
    (* double-quoted "..." string literal -- pass-by-offset only
       (SPHINX has no string-value operations): resolves to its own
       .data label, the same as a global VAR's bare name already
       resolves to its address elsewhere in this file (ADR()'s own
       operand text, or a bare global reference in a register-pair
       move). *)
    SPHOLEX.CurTokText(nm); InternStringLiteral(nm, dst); SPHOLEX.Next
  ELSIF (SPHOLEX.CurTokKind() = TIdent) & TryBuiltinOperand(dst) THEN
    (* handled *)
  ELSIF SPHOLEX.CurTokKind() = TIdent THEN
    IF SPHOLEX.CurTokIsReg() THEN SPHOLEX.CurTokText(dst); SPHOLEX.Next
    ELSE
      SPHOLEX.CurTokText(nm); SPHOLEX.Next;
      IF SPHOLEX.IsLexSym("(") THEN
        EmitCall(nm); Strings.Copy("ax", dst)
      ELSE
        IdentOperandText(nm, dst)
      END
    END
  ELSIF SPHOLEX.IsSym("[") THEN
    (* read context: the field's own declared size doesn't matter here --
       ParseMemOperand's size hint is only meaningful when *storing*
       through this operand (see ParseAssignOrCall's own use of it). *)
    SPHOLEX.Next; ParseMemOperand(dst, discardSize)
  ELSIF SPHOLEX.IsSym("-") THEN
    (* unary minus on a numeric literal (SPHINX.MD gives no example, but
       "AX := -1;" must be expressible) -- NASM accepts a negative
       immediate written as "-N" directly. Nothing else may follow '-'. *)
    SPHOLEX.Next;
    IF SPHOLEX.CurTokKind() = TNum THEN
      SPHOLEX.CurTokText(nm); Strings.Copy("-", dst); Strings.Append(nm, dst); SPHOLEX.Next
    ELSE
      SPHOLEX.ReportError("expected numeric literal after unary '-'");
      Strings.Copy("0", dst)
    END
  ELSE
    SPHOLEX.CurTokText(dst); SPHOLEX.Next
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
  VAR nm: ARRAY MaxName OF CHAR;
BEGIN
  IF SPHOLEX.CurTokKind() # TIdent THEN RETURN FALSE END;
  SPHOLEX.CurTokText(nm);
  IF SPHOLEX.IsRegName(nm) THEN RETURN FALSE END;
  IF IsBuiltinName(nm) THEN RETURN FALSE END;
  RETURN SPHOLEX.FindSym(nm) < 0
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
    IF SPHOLEX.CurTokKind() = TSym THEN
      SPHOLEX.CurTokText(sym);
      IF Strings.Equal(sym,"+") OR Strings.Equal(sym,"-") OR Strings.Equal(sym,"&") OR Strings.Equal(sym,"|") THEN
        SPHOLEX.Next; matched := OpInstr(sym, instr);
        EmitTailOperand(destReg, opnd);
        Strings.Copy(instr, buf); Strings.Append(" ", buf); Strings.Append(destReg, buf);
        Strings.Append(", ", buf); Strings.Append(opnd, buf); EmitInd(buf)
      END
    ELSIF SPHOLEX.IsKw("SHL") THEN
      SPHOLEX.Next; EmitTailOperand(destReg, opnd);
      Strings.Copy("shl ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf); matched := TRUE
    ELSIF SPHOLEX.IsKw("SHR") THEN
      SPHOLEX.Next; EmitTailOperand(destReg, opnd);
      Strings.Copy("shr ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
      Strings.Append(opnd, buf); EmitInd(buf); matched := TRUE
    ELSIF SPHOLEX.IsKw("XOR") THEN
      SPHOLEX.Next; EmitTailOperand(destReg, opnd);
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
  SPHOLEX.CurTokText(rel);
  IF (SPHOLEX.CurTokKind() = TSym) & IsRelSym(rel) THEN
    SPHOLEX.Next;
    EmitRelational(firstOpnd, rel, destReg); RETURN
  END;
  (* firstOpnd a byte register (AL/BL/CL/DL/AH/BH/CH/DH) landing in a
     word-sized destReg is a size mismatch TASM rejects ("operand size
     mismatch") -- widen instead of a bare mov. When destReg is itself a
     byte register too (e.g. EmitAssignRhs's LHS register fallback,
     "AL := BL;"), the plain same-size mov below is correct as-is. *)
  IF SPHOLEX.IsRegName(firstOpnd) & Lex.IsByteReg(Lex.LookupReg(firstOpnd))
     & (~SPHOLEX.IsRegName(destReg) OR ~Lex.IsByteReg(Lex.LookupReg(destReg))) THEN
    EmitWidenByteToWord(firstOpnd, destReg)
  ELSIF Strings.EqualICase(firstOpnd, destReg) THEN
    (* firstOpnd already names the same register as destReg (case-
       insensitively, e.g. "RETURN AX+BX;" calls EmitExprFrom("AX","ax"))
       -- the value is already sitting where it needs to be, so skip the
       no-op "mov ax, AX" self-move entirely instead of emitting it. *)
  ELSIF SPHOLEX.IsRegName(firstOpnd) & SPHOLEX.IsRegName(destReg)
        & Lex.IsSegReg(Lex.LookupReg(firstOpnd)) & Lex.IsSegReg(Lex.LookupReg(destReg)) THEN
    (* 'DS := CS;' (SPHINX.MD §2's own worked example) -- 8086 has no
       segreg-to-segreg mov ("mov ds, cs" is not a legal encoding; TASM:
       "unsupported MOV operand combination", reproduced directly). The
       documented idiom is push/pop through the stack instead. Previously
       this fell straight into the generic "mov destReg, firstOpnd" path
       below with no segment-register check at all -- every "SEGREG :=
       SEGREG;" assignment silently emitted an illegal instruction. *)
    Strings.Copy("push ", buf); Strings.Append(firstOpnd, buf); EmitInd(buf);
    Strings.Copy("pop  ", buf); Strings.Append(destReg, buf); EmitInd(buf)
  ELSIF IsZeroLiteral(firstOpnd) & SPHOLEX.IsRegName(destReg) & ~Lex.IsSegReg(Lex.LookupReg(destReg)) THEN
    (* 'reg := 0;' -- xor reg,reg is the standard 8086 idiom (shorter
       encoding than "mov reg,0", same zero result) for any general-
       purpose 8/16-bit register; not used for a segment-register
       destination (xor es,es and similar are not meaningful/legal the
       same way -- SEGREG := 0 falls through to the ordinary "mov"
       below, unchanged). *)
    Strings.Copy("xor ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
    Strings.Append(destReg, buf); EmitInd(buf)
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
  IF ~((SPHOLEX.CurTokKind() = TIdent) & SPHOLEX.TokTextEqICase("ODD")) THEN RETURN FALSE END;
  SPHOLEX.Next; SPHOLEX.Expect("(");
  OperandText(arg);
  SPHOLEX.Expect(")");
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
  negated := SPHOLEX.IsSym("~");
  IF negated THEN SPHOLEX.Next END;
  SPHOLEX.CurTokText(nm);
  IF (SPHOLEX.CurTokKind() = TIdent) & FlagJumps(nm, jt, jf) THEN
    SPHOLEX.Next;
    LabelName(toLabel, nm);
    (* NOT written as "onTrue # negated" -- see EmitCondJump's own
       header comment below (the 'a REL b' branch) for the confirmed
       TOC.EXE codegen bug this form triggers under specific recursive-
       call conditions; the nested-IF form is the verified-safe
       equivalent used everywhere in this procedure. *)
    IF onTrue THEN
      IF negated THEN Strings.Copy(jf, buf) ELSE Strings.Copy(jt, buf) END
    ELSE
      IF negated THEN Strings.Copy(jt, buf) ELSE Strings.Copy(jf, buf) END
    END;
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
  SPHOLEX.CurTokText(nm);
  IF (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsRegName(nm) THEN
    si := SPHOLEX.FindSym(nm);
    IF (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) THEN
      ty := SPHOLEX.SymTy(si);
      aIsByteVar := (ty = TyByte) OR (ty = TyBool)
    END
  END;
  OperandText(a);
  SPHOLEX.CurTokText(rel);
  IF (SPHOLEX.CurTokKind() = TSym) & IsRelSym(rel) THEN
    SPHOLEX.Next;
    OperandText(b);
    (* a bare "[...]" memory operand compared directly against an
       immediate is size-ambiguous to TASM (see LoadIfMem's own header
       comment) -- load through AX first when needed. *)
    LoadIfMem(a, "ax", aIsByteVar, aLoaded);
    IF SPHOLEX.IsRegName(aLoaded) & IsZeroLiteral(b) & (Strings.Equal(rel, "=") OR Strings.Equal(rel, "#")) THEN
      (* 'reg = 0'/'reg # 0' -- "or reg,reg" sets ZF identically to
         "cmp reg,0" (ZF=1 iff reg is zero either way) with a shorter
         encoding and no immediate operand at all; only valid for
         zero/nonzero testing (=/#), never the ordering relationals
         (</>/<=/>=), which need a real subtract's borrow/sign flags
         that "or" does not produce. *)
      Strings.Copy("or ", buf); Strings.Append(aLoaded, buf); Strings.Append(", ", buf);
      Strings.Append(aLoaded, buf); EmitInd(buf)
    ELSE
      Strings.Copy("cmp ", buf); Strings.Append(aLoaded, buf); Strings.Append(", ", buf);
      Strings.Append(b, buf); EmitInd(buf)
    END;
    RelJumps(rel, jt, jf);
    LabelName(toLabel, nm);
    IF onTrue THEN
      IF negated THEN Strings.Copy(jf, buf) ELSE Strings.Copy(jt, buf) END
    ELSE
      IF negated THEN Strings.Copy(jt, buf) ELSE Strings.Copy(jf, buf) END
    END;
    Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
  ELSE
    (* Bare BOOLEAN condition -- 'a' alone (var, register, or call result,
       always TRUE=1/FALSE=0 per SPHINX.MD §3.1), no REL operator
       followed it. Test against zero instead of comparing to TRUE/FALSE
       explicitly. *)
    LoadIfMem(a, "ax", aIsByteVar, aLoaded);
    Strings.Copy("cmp ", buf); Strings.Append(aLoaded, buf); Strings.Append(", 0", buf); EmitInd(buf);
    LabelName(toLabel, nm);
    IF onTrue THEN
      IF negated THEN Strings.Copy("je", buf) ELSE Strings.Copy("jne", buf) END
    ELSE
      IF negated THEN Strings.Copy("jne", buf) ELSE Strings.Copy("je", buf) END
    END;
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
  RETURN (SPHOLEX.CurTokKind() = TSym) & (SPHOLEX.IsSym("+") OR SPHOLEX.IsSym("-") OR SPHOLEX.IsSym("&") OR SPHOLEX.IsSym("|"))
       OR SPHOLEX.IsKw("SHL") OR SPHOLEX.IsKw("SHR") OR SPHOLEX.IsKw("XOR")
END IsChainOp;

(* ExtractRegArg: after ALL arguments have been pushed (left to right,
   Pascal order, exactly the old unconditional behavior -- this is what
   keeps evaluation order/clobber-safety identical to before: a later
   argument's own evaluation can never disturb an earlier one, since
   nothing is read out of any of them until every push is done), one
   argument turned out to belong to a register-named formal parameter
   (SPHINX.MD §6.2) and must be moved from its stack slot into that
   register, WITHOUT disturbing the relative stack order of any other
   still-stack-bound arguments still sitting above it (pushed after it,
   i.e. at a SMALLER depth from the current SP).

   depthBytes = this argument's own distance from SP, in bytes, at the
   moment all pushes just finished (0 = the very last-pushed argument,
   sitting right on top).

   8086 has no SP-relative addressing mode at all (SP cannot be a base
   register -- only BX/BP/SI/DI can, DOCS/8086 addressing rules; TASM:
   "register not usable as base/index on 8086" -- reproduced directly, a
   first attempt at this using a literal "[sp+N]" operand failed to
   assemble). BP is repurposed as a throwaway index base instead: `push
   bp` (saving the caller's own frame pointer -- needed again the moment
   this procedure returns to its own body) then `mov bp, sp` snapshots
   the CURRENT sp into bp for [bp+N] addressing; this push itself shifts
   every original depth by +2 (one more word now sits between bp and the
   arguments), hence bpDepth := depthBytes + 2 below. Reads the target
   argument via [bp+bpDepth] (no pop -- nothing above it is disturbed by
   a plain read), then closes the gap by shifting every word between the
   snapshot point and this slot down by one word (AX as scratch -- safe:
   by this point every argument's own value is already safely on the
   stack, nothing further needs AX to still hold anything), shrinks SP by
   2 to actually remove the now-duplicate top slot, and finally `pop bp`
   restores the caller's own frame pointer. depthBytes=0 (nothing above
   it) skips the shift loop entirely -- a plain pop would already have
   worked, but the general [bp+N]-based shift handles it too, one less
   special case to get wrong. *)
PROCEDURE ExtractRegArg(regName: ARRAY OF CHAR; depthBytes: INTEGER);
  VAR buf: ARRAY MaxLine OF CHAR; d, bpDepth: INTEGER;
BEGIN
  Emit("    push bp");
  Emit("    mov  bp, sp");
  bpDepth := depthBytes + 2;
  Strings.Copy("mov ", buf); Strings.Append(regName, buf); Strings.Append(", [bp+", buf);
  Strings.AppendInt(LONGINT(bpDepth), buf); Strings.Append("]", buf); EmitInd(buf);
  d := bpDepth;
  WHILE d > 2 DO
    Strings.Copy("mov ax, [bp+", buf); Strings.AppendInt(LONGINT(d - 2), buf); Strings.Append("]", buf); EmitInd(buf);
    Strings.Copy("mov [bp+", buf); Strings.AppendInt(LONGINT(d), buf); Strings.Append("], ax", buf); EmitInd(buf);
    DEC(d, 2)
  END;
  Emit("    pop  bp");
  Emit("    add  sp, 2")
END ExtractRegArg;

(* EmitCall: 'Name(' already consumed. Pushes actual params left to
   right (Pascal convention, SPHINX.MD §6.1) -- EVERY argument, even one
   destined for a register-named formal parameter (SPHINX.MD §6.2, see
   ExtractRegArg's own header comment for why: pushing first keeps every
   argument's own evaluation order/clobber-safety identical to a normal
   call, regardless of how many of the callee's own params are register-
   named or where). Once all arguments are on the stack, each
   register-param one is extracted via ExtractRegArg (in left-to-right
   argument order -- irrelevant to correctness here, since each
   extraction's own depthBytes was captured at push time and no longer
   changes as EARLIER-pushed arguments are extracted, only as
   LATER-pushed ones might be -- but this file always records depth
   relative to the argument list's own fixed positions, not a moving
   target). Then `call`/`call far Name` depending on the callee's own
   FAR-ness (SPHINX.MD §6.3). A bare `call` always assembles as a
   same-module NEAR call regardless of the target label's own kind
   (DOCS/TASM.MD §3), so a FAR callee's `retf` would pop 2 bytes too
   many; a name not found in the proc table (a forward reference within
   this file, or a name resolved only externally/via ASM) defaults to
   FAR, matching both SPHINX.MD's own default-FAR rule for exported
   procs and DOCS/TASM.MD §3's requirement that any cross-module
   reference be `CALL FAR`. Each argument may be a full expression
   (SPHINX.MD §7's own left-to-right chain), not just a single operand --
   see the IsChainOp check inside the argument loop below. *)
PROCEDURE EmitCall;
  VAR opnd, buf, nm: ARRAY MaxLine OF CHAR; isFar: BOOLEAN; si, ty, pi, argIdx, nArgs: INTEGER;
      isByteVar, wasValid: BOOLEAN;
      argIsReg: ARRAY MaxParams OF BOOLEAN; argRegName: ARRAY MaxParams OF ARRAY 32 OF CHAR;
BEGIN
  (* Resolve the callee's own proc-table row FIRST (before any argument
     is parsed), so each argument's own register-ness can be recorded via
     ProcParamIsReg as it's pushed -- ProcFindAny finds a row regardless
     of valid[]/isFwdKnown[] (unlike ProcFindIsFar), but ProcParamIsReg
     only ever returns real data for a row ProcSetParams actually filled
     in (the real definition, already parsed) -- anything else (never
     seen, INTERRUPT, FORWARD-pending) safely reports every position as
     NOT register-named, so every argument falls back to the ordinary
     push path (unchanged from before this fix) and the extraction pass
     below finds nothing to extract. *)
  pi := SPHOLEX.ProcFindAny(name, wasValid);
  argIdx := 0;
  IF ~SPHOLEX.IsLexSym(")") THEN
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
      SPHOLEX.CurTokText(nm);
      IF (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsRegName(nm) THEN
        si := SPHOLEX.FindSym(nm);
        IF (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) THEN
          ty := SPHOLEX.SymTy(si);
          isByteVar := (ty = TyByte) OR (ty = TyBool)
        END
      END;
      OperandText(opnd);
      (* Every argument is ALWAYS pushed here, even one destined for a
         register-named formal -- see EmitCall's own header comment for
         why (evaluation-order/clobber-safety). argIsReg[argIdx]/
         argRegName[argIdx] are only recorded for the extraction pass
         below, run once every argument is safely on the stack. *)
      argIsReg[argIdx] := SPHOLEX.ProcParamIsReg(pi, argIdx, argRegName[argIdx]);
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
        Strings.Copy("push ax", buf); EmitInd(buf)
      ELSIF SPHOLEX.IsRegName(opnd) & Lex.IsByteReg(Lex.LookupReg(opnd)) THEN
        (* 8086 has no `push` for a byte register (AL/BL/CL/DL/AH/BH/CH/
           DH) -- "push al" is not a legal instruction (TASM: "operand
           size mismatch"). Zero-extend into AX first (BYTE/BOOLEAN are
           documented unsigned, SPHINX.MD §3.1, same reasoning
           EmitWidenByteToWord's own header comment already gives), then
           push that. *)
        EmitWidenByteToWord(opnd, "ax");
        Strings.Copy("push ax", buf); EmitInd(buf)
      ELSIF SPHOLEX.IsRegName(opnd) THEN
        Strings.Copy("push ", buf); Strings.Append(opnd, buf); EmitInd(buf)
      ELSIF isByteVar THEN
        (* opnd is a byte-sized memory operand ("[bp-N]"/"[name]") --
           load through AL (correctly 1-byte-wide) and zero-extend,
           instead of a blind word-wide "mov ax, opnd". *)
        Strings.Copy("mov al, byte ", buf); Strings.Append(opnd, buf); EmitInd(buf);
        Strings.Copy("mov ah, 0", buf); EmitInd(buf);
        Strings.Copy("push ax", buf); EmitInd(buf)
      ELSE
        Strings.Copy("mov ax, ", buf); Strings.Append(opnd, buf); EmitInd(buf);
        Strings.Copy("push ax", buf); EmitInd(buf)
      END;
      INC(argIdx)
    UNTIL ~SPHOLEX.IsLexSym(",");
    SPHOLEX.Expect(")")
  END;
  nArgs := argIdx;
  (* Extraction pass: every argument is now on the stack, last-pushed on
     top (depth 0). Argument i (0-based, left to right) sits at depth
     2*(nArgs-1-i) bytes from SP -- process left to right (order doesn't
     matter for correctness, ExtractRegArg's own depth is fixed per
     argument regardless of what's already been extracted to its LEFT;
     only extractions to a given argument's RIGHT would shift its own
     depth, and those are always processed... actually depth only
     depends on how many words are STILL ABOVE this one, i.e. arguments
     to its right not yet extracted -- ExtractRegArg's shift-down loop
     itself only touches words between SP and this argument's own slot,
     never anything below it, so an EARLIER (to the right, shallower)
     extraction never invalidates a LATER (to the left, deeper) one's own
     depth: every already-extracted register argument is gone from the
     stack entirely, and the shift-down closes its gap by moving
     everything shallower than it down by one slot -- which is exactly
     what keeps a deeper not-yet-extracted argument's own depth-from-SP
     unchanged, since the argument count above IT (register or not) is
     conserved by the shift, only the register ones vanish). *)
  argIdx := 0;
  WHILE argIdx < nArgs DO
    IF argIsReg[argIdx] THEN
      ExtractRegArg(argRegName[argIdx], 2 * (nArgs - 1 - argIdx))
    END;
    INC(argIdx)
  END;
  IF ~SPHOLEX.ProcFindIsFar(name, isFar) THEN
    isFar := TRUE; PendingAppend(StrTab.Intern(name), SPHOLEX.CurLine())
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
  IF ~SPHOLEX.ProcFindIsFar(name, isFar) THEN
    isFar := TRUE; PendingAppend(StrTab.Intern(name), SPHOLEX.CurLine())
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
  si := SPHOLEX.FindSym(nm);
  RETURN (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) & (SPHOLEX.SymTy(si) = TyLong)
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
  SPHOLEX.CurTokText(seg);
  IF (SPHOLEX.CurTokKind() # TIdent) OR ~SPHOLEX.IsRegName(seg) THEN RETURN FALSE END;
  SPHOLEX.Next;
  IF ~SPHOLEX.IsLexSym(":") THEN Strings.Copy(seg, consumedReg); RETURN FALSE END;
  SPHOLEX.CurTokText(offReg);
  IF (SPHOLEX.CurTokKind() # TIdent) OR ~SPHOLEX.IsRegName(offReg) THEN
    SPHOLEX.ReportError("expected register after ':' in register pair");
    Strings.Copy("AX", offReg); RETURN TRUE
  END;
  SPHOLEX.Next;
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
  SPHOLEX.CurTokText(destOff);
  IF (SPHOLEX.CurTokKind() # TIdent) OR ~SPHOLEX.IsRegName(destOff) THEN
    SPHOLEX.ReportError("expected register after ':' in register pair");
    Strings.Copy("AX", destOff)
  ELSE
    SPHOLEX.Next
  END;
  SPHOLEX.Expect(":=");
  IF TryParseRegPair(srcSeg, srcOff, consumedReg) THEN
    EmitRegPairStore(destSeg, destOff, srcSeg, srcOff)
  ELSIF consumedReg[0] # 0X THEN
    (* a lone register (no ':' pair) isn't one of SPHINX.MD §11's
       documented RHS forms (LONGINT VAR / register pair / call) --
       TryParseRegPair already consumed it, so this reports the error
       against what's actually there instead of silently mis-parsing. *)
    Strings.Copy("register-pair RHS must be a LONGINT VAR, a register pair, or a call, not a single register: ", msg);
    Strings.Append(consumedReg, msg); SPHOLEX.ReportError(msg)
  ELSIF SPHOLEX.CurTokKind() = TIdent THEN
    (* consumedReg[0]=0X here means TryParseRegPair found the current
       token wasn't a register at all (its own IsRegName check already
       failed and nothing was consumed) -- no separate ~IsRegName guard
       needed on top of that. *)
    SPHOLEX.CurTokText(nm); SPHOLEX.Next;
    IF SPHOLEX.IsLexSym("(") THEN
      (* 'destSeg:destOff := myfunction();' -- result convention is
         DX:AX (SPHINX.MD §6.4); route through it as if the call's own
         result were a register-pair RHS. *)
      EmitCall(nm);
      EmitRegPairStore(destSeg, destOff, "DX", "AX")
    ELSE
      IdentOperandText(nm, longText);
      IF ~IsPlainLongVar(nm) THEN
        Strings.Copy("register-pair RHS must be a LONGINT VAR or a call: ", msg);
        Strings.Append(nm, msg); SPHOLEX.ReportError(msg)
      END;
      EmitRegPairFromLongVar(destSeg, destOff, longText)
    END
  ELSE
    SPHOLEX.ReportError("expected LONGINT VAR, register pair, or call after ':=' in register-pair assignment")
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
      regId, si, ty: INTEGER; gotReg, freshIsReg: BOOLEAN;
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
  freshIsReg := FALSE;
  IF ~gotReg & destIsMem & (SPHOLEX.CurTokKind() = TIdent) THEN
    SPHOLEX.CurTokText(nm); freshIsReg := SPHOLEX.IsRegName(nm)
  END;
  IF gotReg OR freshIsReg THEN
    IF ~gotReg THEN SPHOLEX.Next END;
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
  SPHOLEX.CurTokText(nm);
  IF (SPHOLEX.CurTokKind() = TIdent) & IsBuiltinName(nm) THEN
    (* ADR/SEG/SIZE/ODD (SPHINX.MD §9): must not fall into the generic
       call-or-plain-var dispatch below, which would treat e.g. "SIZE" as
       an ordinary undeclared variable/call name. *)
    IF destIsMem THEN EmitExpr("ax"); MoveAxToDest(destReg, destIsMem, destSize)
    ELSE EmitExpr(destReg)
    END;
    RETURN
  END;
  (* Fast path: '[mem] := byteVar;' with no further chained operator and
     no RECORD-field size hint already known (destSize="", a bare
     '[seg:base]' target -- ParseMemOperand only ever fills destSize in
     from a '.RecordType.field' access) -- size the store from the
     SOURCE variable's own declared type instead of leaving it to fall
     through to EmitExprAssign's word-wide default, which corrupts the
     byte immediately after the intended one (reproduced directly:
     EXAMPLES/CLIPDRV/CLIPCLI.SMD's own "[ES:DI] := curCh;" with
     curCh:BYTE, building up a byte buffer one character at a time --
     every character write clobbered the NEXT character's own future
     byte with a garbage high byte before it was ever written; same
     latent bug already present, unnoticed, in EXAMPLES/SPHO/LCOUNT.SMD's
     own "[DS:SI] := c;", c:BYTE, where it happens not to matter because
     nothing ever reads the byte immediately after that particular write
     before it's overwritten again). *)
  IF destIsMem & (destSize[0] = 0X) & (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsRegName(nm) THEN
    si := SPHOLEX.FindSym(nm);
    IF (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) THEN
      ty := SPHOLEX.SymTy(si);
      IF (ty = TyByte) OR (ty = TyBool) THEN
        SPHOLEX.CurTokText(nm); SPHOLEX.Next;
        IF ~IsChainOp() THEN
          IdentOperandText(nm, opnd);
          IF opnd[0] = "[" THEN
            (* opnd is itself memory text ("[bp-N]"/"[name]") -- x86 has
               no mem,mem mov form, load through AL first (byte-sized,
               matching ty). *)
            Strings.Copy("mov al, byte ", buf); Strings.Append(opnd, buf); EmitInd(buf);
            Strings.Copy("mov byte ", buf); Strings.Append(destReg, buf); Strings.Append(", al", buf); EmitInd(buf)
          ELSE
            Strings.Copy("mov byte ", buf); Strings.Append(destReg, buf); Strings.Append(", ", buf);
            Strings.Append(opnd, buf); EmitInd(buf)
          END;
          RETURN
        END;
        EmitExprFrom(nm, "ax");
        Strings.Copy("mov byte ", buf); Strings.Append(destReg, buf); Strings.Append(", al", buf); EmitInd(buf);
        RETURN
      END
    END
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
  IF SPHOLEX.IsSym("[") THEN
    SPHOLEX.Next; ParseMemOperand(buf, destSize);
    SPHOLEX.Expect(":=");
    EmitAssignRhs(buf, TRUE, destSize)
  ELSIF SPHOLEX.CurTokKind() = TIdent THEN
    SPHOLEX.CurTokText(lhs); SPHOLEX.Next;
    IF SPHOLEX.IsRegName(lhs) & SPHOLEX.IsLexSym(":") THEN
      (* 'SEG:REG := ...' (SPHINX.MD §11, LONGINT register-pair moves) --
         lhs was only the segment half; ':' (not ':=') here means a
         register-pair LHS, not a plain register assignment. Handled
         separately since it needs both halves before dispatching on the
         RHS shape (plain longvar/register-pair/call). Previously nothing
         matched this shape at all: SPHOLEX.IsLexSym(":=") failed on the bare ':'
         token, SPHOLEX.IsLexSym("(") failed too, so the statement silently
         consumed nothing and ParseStmtList re-parsed the same unconsumed
         ':' forever -- a hang, not merely an unimplemented feature. *)
      ParseRegPairAssign(lhs)
    ELSIF SPHOLEX.IsLexSym(":=") THEN
      IF SPHOLEX.IsRegName(lhs) THEN
        EmitAssignRhs(lhs, FALSE, "")
      ELSE
        si := SPHOLEX.FindSym(lhs);
        IF (si >= 0) & (SPHOLEX.SymKind(si) = SymConst) THEN
          Strings.Copy("cannot assign to a CONST: ", msg); Strings.Append(lhs, msg);
          SPHOLEX.ReportError(msg)
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
        IF (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) THEN SizeHintFor(SPHOLEX.SymTy(si), destSize)
        ELSE destSize[0] := 0X
        END;
        (* a register-named param (SPHINX.MD §6.2) resolves to a bare
           register name, not a memory operand -- destIsMem must be
           FALSE for it, exactly like the SPHOLEX.IsRegName(lhs) branch above. *)
        IF (si >= 0) & SPHOLEX.SymIsReg(si) THEN EmitAssignRhs(buf, FALSE, "")
        ELSE EmitAssignRhs(buf, TRUE, destSize)
        END
      END
    ELSIF SPHOLEX.IsLexSym("(") THEN
      EmitCall(lhs)
    ELSIF ~SPHOLEX.IsRegName(lhs) THEN
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
      Strings.Copy("expected ':=' after register '", msg); Strings.Append(lhs, msg);
      Strings.Append("'", msg);
      SPHOLEX.ReportError(msg); SPHOLEX.Next
    END
  ELSIF ~SPHOLEX.IsSym(";") THEN
    (* current token starts neither a '[seg:base] := ...' statement nor
       an identifier-led one, and isn't a bare ';' (a legitimate empty
       statement -- ParseStmt's own trailing "WHILE SPHOLEX.IsLexSym(';') DO END"
       consumes it right after this call returns, so leaving it
       unconsumed here is correct, not a hang risk). An unexpected symbol
       (bare '=', a stray ')', ...) sitting where a statement was
       expected does need the same "must consume or hang" handling as
       the identifier-led ELSE above, though. *)
    SPHOLEX.CurTokText(lhs);
    Strings.Copy("unexpected '", msg); Strings.Append(lhs, msg);
    Strings.Append("'", msg);
    SPHOLEX.ReportError(msg); SPHOLEX.Next
  END
END ParseAssignOrCall;

PROCEDURE ParseIf;
  VAR elseLbl, endLbl: INTEGER;
BEGIN
  elseLbl := NewLabel(); endLbl := NewLabel();
  EmitCondJump(elseLbl, FALSE);
  SPHOLEX.ExpectKw("THEN");
  ParseStmtList;
  WHILE SPHOLEX.IsLexKw("ELSIF") DO
    EmitInd2("jmp", endLbl);
    EmitLabel(elseLbl);
    elseLbl := NewLabel();
    EmitCondJump(elseLbl, FALSE);
    SPHOLEX.ExpectKw("THEN");
    ParseStmtList
  END;
  IF SPHOLEX.IsLexKw("ELSE") THEN
    EmitInd2("jmp", endLbl);
    EmitLabel(elseLbl);
    ParseStmtList
  ELSE
    EmitLabel(elseLbl)
  END;
  EmitLabel(endLbl);
  SPHOLEX.ExpectKw("END")
END ParseIf;

PROCEDURE ParseWhile;
  VAR topLbl, exitLbl: INTEGER;
BEGIN
  topLbl := NewLabel(); exitLbl := NewLabel();
  EmitLabel(topLbl);
  EmitCondJump(exitLbl, FALSE);
  SPHOLEX.ExpectKw("DO");
  INC(loopDepth); loopExitStack[loopDepth] := exitLbl; loopContStack[loopDepth] := topLbl;
  ParseStmtList;
  DEC(loopDepth);
  EmitInd2("jmp", topLbl);
  EmitLabel(exitLbl);
  SPHOLEX.ExpectKw("END")
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
  (* A bare "RETURN" (no expression) must recognize EVERY token that can
     legally follow it as a statement-list terminator/continuation, not
     only ";"/"END"/end-of-file -- "ELSE"/"ELSIF" (a bare RETURN as the
     last statement of an IF's own THEN branch, immediately followed by
     ELSE/ELSIF, SPHINX.MD §8.1) were missing here, so "IF cond THEN
     RETURN ELSE ... END" wrongly fell into the EmitExpr("ax") branch and
     tried to parse the ELSE keyword itself as an expression operand --
     reproduced directly: emitted "mov ax, [ELSE]" (ELSE read as a bare,
     undeclared identifier) into the .ASM output, an undefined symbol at
     assemble time. *)
  IF ~SPHOLEX.IsSym(";") & (SPHOLEX.CurTokKind() # TEof) & ~SPHOLEX.IsKw("END")
     & ~SPHOLEX.IsKw("ELSE") & ~SPHOLEX.IsKw("ELSIF") THEN
    EmitExpr("ax")
  END;
  EmitInd2("jmp", procExitLbl)
END ParseReturn;

(* ParseAsm: copies raw text verbatim until a line whose first word is END. *)

(* ParseAsm: copies raw text verbatim until a line whose first word is
   END. Reads one raw line at a time via SPHOLEX.ReadAsmLine (character-
   level scanner state -- ch/NextCh/line -- is private to SPHOLEX). *)
PROCEDURE ParseAsm;
  VAR buf, word: ARRAY MaxLine OF CHAR; atEnd: BOOLEAN;
BEGIN
  SPHOLEX.SkipAsmLead;
  atEnd := FALSE;
  WHILE ~atEnd DO
    SPHOLEX.ReadAsmLine(buf, word, atEnd);
    IF ~atEnd THEN
      IF Strings.EqualICase(word, "END") THEN
        atEnd := TRUE
      ELSE
        Strings.Trim(buf);
        IF buf[0] # 0X THEN Emit(buf) END
      END
    END
  END;
  SPHOLEX.Next
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
  SPHOLEX.CurTokText(nm); SPHOLEX.Next;
  hasAmount := SPHOLEX.IsLexSym(",");
  IF SPHOLEX.IsRegName(nm) THEN
    IF hasAmount THEN EmitIncDecAmountToReg(nm, mnemonic)
    ELSE
      Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
    END;
    RETURN
  END;
  si := SPHOLEX.FindSym(nm);
  IF (si >= 0) & (SPHOLEX.SymKind(si) = SymConst) THEN
    Strings.Copy("cannot INC/DEC a CONST: ", msg); Strings.Append(nm, msg);
    SPHOLEX.ReportError(msg); RETURN
  END;
  IF (si >= 0) & SPHOLEX.SymIsReg(si) THEN
    IF hasAmount THEN EmitIncDecAmountToReg(nm, mnemonic)
    ELSE
      Strings.Copy(mnemonic, buf); Strings.Append(" ", buf); Strings.Append(nm, buf); EmitInd(buf)
    END;
    RETURN
  END;
  SymOperandText(si, nm, opnd);
  IF (si >= 0) & (SPHOLEX.SymKind(si) = SymVar) THEN ty := SPHOLEX.SymTy(si) ELSE ty := TyWord END;
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
  VAR regs: RegList; n, i: INTEGER; buf: ARRAY MaxLine OF CHAR;
BEGIN
  SPHOLEX.Expect("(");
  n := 0;
  IF ~SPHOLEX.IsSym(")") THEN
    REPEAT
      IF SPHOLEX.CurTokKind() # TIdent THEN
        SPHOLEX.ReportError("expected register name in PUSH/POP")
      ELSIF n >= MaxUses THEN
        SPHOLEX.ReportError("too many registers in PUSH/POP")
      ELSE
        SPHOLEX.CurTokText(regs[n]); INC(n)
      END;
      SPHOLEX.Next
    UNTIL ~SPHOLEX.IsLexSym(",")
  END;
  SPHOLEX.Expect(")");
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
  IF SPHOLEX.IsLexKw("IF") THEN ParseIf
  ELSIF SPHOLEX.IsLexKw("WHILE") THEN ParseWhile
  ELSIF SPHOLEX.IsLexKw("BREAK") THEN
    IF loopDepth >= 0 THEN EmitInd2("jmp", loopExitStack[loopDepth]) END
  ELSIF SPHOLEX.IsLexKw("CONTINUE") THEN
    IF loopDepth >= 0 THEN EmitInd2("jmp", loopContStack[loopDepth]) END
  ELSIF SPHOLEX.IsLexKw("RETURN") THEN ParseReturn
  ELSIF SPHOLEX.IsKw("ASM") THEN ParseAsm
  ELSIF SPHOLEX.IsLexKw("INC") THEN
    SPHOLEX.Expect("("); EmitIncDec("inc"); SPHOLEX.Expect(")")
  ELSIF SPHOLEX.IsLexKw("DEC") THEN
    SPHOLEX.Expect("("); EmitIncDec("dec"); SPHOLEX.Expect(")")
  ELSIF SPHOLEX.IsLexKw("INT") THEN
    SPHOLEX.Expect("("); SPHOLEX.CurTokText(buf); SPHOLEX.Next; SPHOLEX.Expect(")");
    Strings.Insert("int ", 0, buf); EmitInd(buf)
  ELSIF SPHOLEX.IsLexKw("PUSH") THEN ParsePushPop("push", FALSE)
  ELSIF SPHOLEX.IsLexKw("POP") THEN ParsePushPop("pop", TRUE)
  ELSE
    ParseAssignOrCall
  END;
  WHILE SPHOLEX.IsLexSym(";") DO END
END ParseStmt;

PROCEDURE ParseStmtList;
BEGIN
  WHILE (SPHOLEX.CurTokKind() # TEof) & ~SPHOLEX.IsKw("END") & ~SPHOLEX.IsKw("ELSE") & ~SPHOLEX.IsKw("ELSIF") DO
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
  IF SPHOLEX.IsLexKw("REG") THEN END; (* optional leading REG keyword, SPHINX.MD §6.2 *)
  IF ~SPHOLEX.IsSym(")") THEN
    moreGroups := TRUE;
    WHILE moreGroups DO
      groupStart := n;
      moreNames := TRUE;
      WHILE moreNames DO
        IF n >= MaxParams THEN
          SPHOLEX.ReportError("too many parameters"); moreNames := FALSE; moreGroups := FALSE
        ELSE
          SPHOLEX.CurTokText(nm);
          regFlags[n] := SPHOLEX.IsRegName(nm);
          SPHOLEX.Next;
          sis[n] := SPHOLEX.SymAppend(nm, SymVar);
          SPHOLEX.SymSetIsLocal(sis[n], TRUE); SPHOLEX.SymSetIsParam(sis[n], TRUE);
          IF regFlags[n] THEN
            (* register param: no type at all (SPHINX.MD §6.2's own bare
               "PROCEDURE CB_API(AX);" example) -- type it immediately,
               it never participates in a following group's ": type". *)
            SPHOLEX.SymSetTy(sis[n], TyInt, -1)
          END;
          INC(n);
          moreNames := SPHOLEX.IsLexSym(",")
        END
      END;
      IF ~SPHOLEX.IsLexSym(":") THEN ty := TyInt; recIdx := -1
      ELSE ParseBaseType(ty, recIdx)
      END;
      i := groupStart;
      WHILE i < n DO
        IF ~regFlags[i] THEN SPHOLEX.SymSetTy(sis[i], ty, recIdx) END;
        INC(i)
      END;
      moreGroups := moreGroups & SPHOLEX.IsLexSym(";")
    END
  END;
  SPHOLEX.Expect(")")
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
    IF ~regFlags[i] & (SPHOLEX.SymTy(sis[i]) = TyRec) THEN
      Strings.Copy("by-value RECORD parameter not supported", msg);
      Strings.Append(" (pass ADR(rec) into a WORD/INTEGER parameter instead)", msg);
      SPHOLEX.ReportError(msg)
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
      SPHOLEX.SymSetIsReg(sis[i], TRUE)  (* accessed by register name directly, no frame slot at all *)
    ELSE
      SPHOLEX.SymSetOfs(sis[i], -(retOfs + nStack)); (* negative marks [bp+N] via ABS in OperandText *)
      INC(nStack, 2)
    END;
    DEC(i)
  END
END AssignParamOffsets;

(* ParseUses: 'USES r1, r2, ...;' (SPHINX.MD §6.5). Bound-checked against
   MaxUses the same way ParsePushPop's own PUSH/POP register list already
   is -- previously unchecked here, so a USES clause naming more than
   MaxUses registers would silently write past regs[]'s own fixed-size
   array bounds instead of reporting a clear translator error. *)
PROCEDURE ParseUses(VAR regs: RegList; VAR n: INTEGER);
BEGIN
  n := 0;
  IF SPHOLEX.IsLexKw("USES") THEN
    REPEAT
      IF n >= MaxUses THEN
        SPHOLEX.ReportError("too many registers in USES"); SPHOLEX.Next
      ELSE
        SPHOLEX.CurTokText(regs[n]); SPHOLEX.Next; INC(n)
      END
    UNTIL ~SPHOLEX.IsLexSym(",");
    SPHOLEX.Expect(";")
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
  VAR nm: ARRAY 64 OF CHAR; exported, isFar, isInterrupt, hasParams, isFwd, wasValid, needsFrame: BOOLEAN;
      nStack, savedLex, nParams, pi: INTEGER;
      regFlags: ARRAY MaxParams OF BOOLEAN;
      sis: ARRAY MaxParams OF INTEGER;
      uses: RegList; nUses: INTEGER;
      buf, msg: ARRAY MaxLine OF CHAR;
BEGIN
  SPHOLEX.CurTokText(nm); SPHOLEX.Next;
  exported := FALSE;
  IF SPHOLEX.IsLexSym("*") THEN exported := TRUE END;
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
  pi := SPHOLEX.ProcFindAny(nm, wasValid);
  IF pi >= 0 THEN
    IF wasValid THEN
      Strings.Copy("duplicate PROCEDURE definition: ", msg);
      Strings.Append(nm, msg); SPHOLEX.ReportError(msg)
    END
    (* pi >= 0 & ~wasValid: reusing an existing FORWARD-pending row --
       fall through with pi already set, no new ProcReserve. *)
  ELSE
    pi := SPHOLEX.ProcReserve(nm)
  END;
  savedLex := SPHOLEX.CurLexMark();
  hasParams := SPHOLEX.IsLexSym("(");
  IF hasParams THEN ParseParams(regFlags, sis, nParams) ELSE nParams := 0 END;
  RejectRecordParams(regFlags, sis, nParams);
  IF SPHOLEX.IsLexSym(":") THEN
    IF SPHOLEX.IsLexKw("BYTE") OR SPHOLEX.IsLexKw("BOOLEAN") OR SPHOLEX.IsLexKw("WORD") OR SPHOLEX.IsLexKw("INTEGER")
       OR SPHOLEX.IsLexKw("LONGINT") THEN END
  END;
  (* exported procedures default to FAR (SPHINX.MD §6.3/notes: "can be
     NEAR/FAR (default - far)"); an explicit NEAR/FAR keyword always wins.
     Params' [bp+N] offsets can only be assigned once isFar is final --
     see ParseParams's own header comment -- hence AssignParamOffsets
     below, after this keyword is parsed. *)
  isFar := exported; isInterrupt := FALSE;
  IF SPHOLEX.IsLexSym(";") THEN END;
  IF SPHOLEX.IsLexKw("NEAR") THEN isFar := FALSE; SPHOLEX.IsLexSym(";")
  ELSIF SPHOLEX.IsLexKw("FAR") THEN isFar := TRUE; SPHOLEX.IsLexSym(";")
  ELSIF SPHOLEX.IsLexKw("INTERRUPT") THEN isInterrupt := TRUE; SPHOLEX.IsLexSym(";")
  END;
  isFwd := SPHOLEX.IsLexKw("FORWARD");
  IF isFwd THEN
    SPHOLEX.IsLexSym(";");
    IF isInterrupt THEN
      SPHOLEX.ReportError("FORWARD not supported for INTERRUPT procedures")
    ELSE
      SPHOLEX.ProcSetForward(pi, isFar)
    END;
    SPHOLEX.LexTruncate(savedLex);   (* discard the FORWARD decl's own param rows *)
    RETURN
  END;
  AssignParamOffsets(regFlags, sis, nParams, isFar, nStack);
  IF ~isInterrupt THEN SPHOLEX.ProcSetIsFar(pi, isFar); SPHOLEX.ProcSetParams(pi, regFlags, sis, nParams) END;
  ParseUses(uses, nUses);

  IF exported THEN Emit2("global ", nm) END;
  Emit2(nm, ":");
  (* needsFrame: a BP-based stack frame (push bp/mov bp,sp ... mov sp,bp/
     pop bp) is only actually needed when the body can reference [bp+N]
     (a non-register parameter, nStack > 0) or [bp-N] (a local VAR,
     frameOfs > 0 once ParseVarSection below has run) -- a procedure with
     ONLY register-named params and no locals never emits either kind of
     operand at all, so BP is never touched and the frame is pure waste
     (bytes in the .COM/.EXE and cycles on every call/return, and an
     unnecessary clobber of the caller's own BP). frameOfs isn't known
     until ParseVarSection has actually run, so the prologue itself
     (label already emitted above, unconditionally) is deferred past it
     -- USES is parsed (not emitted) earlier already, order-independent
     of VAR section parsing since both are pure lookahead before the
     body's own statements. *)
  frameOfs := 0;
  IF SPHOLEX.IsLexKw("VAR") THEN ParseVarSection(FALSE) END;
  needsFrame := (nStack > 0) OR (frameOfs > 0);
  IF needsFrame THEN
    Emit("    push bp");
    Emit("    mov  bp, sp")
  END;
  EmitUsesPush(uses, nUses);
  IF frameOfs > 0 THEN
    Strings.Copy("sub  sp, ", buf); Strings.AppendInt(LONGINT(frameOfs), buf); EmitInd(buf)
  END;

  procExitLbl := NewLabel();
  IF SPHOLEX.IsLexKw("BEGIN") THEN ParseStmtList END;
  SPHOLEX.ExpectKw("END");
  IF SPHOLEX.CurTokKind() = TIdent THEN SPHOLEX.Next END; (* trailing proc-name repeat *)
  SPHOLEX.Expect(";");

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
    IF needsFrame THEN
      Emit("    mov  sp, bp");
      Emit("    pop  bp")
    END;
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
  SPHOLEX.LexTruncate(savedLex)   (* pop params/locals off the lexeme table *)
END ParseProcedure;


(* ---------------- module translation ---------------- *)

(* ParseModule: isTop = top-level file (may IMPORT, and a BEGIN...END
   becomes 'start') vs. an IMPORTed file (spliced in, but may not itself
   IMPORT or have a BEGIN...END -- see DOCS/SPHO.MD). *)
PROCEDURE ParseModule(isTop: BOOLEAN): BOOLEAN;
  VAR incNm: ARRAY 64 OF CHAR; sp: ARRAY 128 OF CHAR;
BEGIN
  SPHOLEX.SetOk(TRUE);
  SPHOLEX.ExpectKw("MODULE");
  SPHOLEX.Next; (* module name -- not otherwise used by the translator *)
  SPHOLEX.Expect(";");

  (* `&` short-circuits in this compiler (Oberon-07 §9.1), so a guard
     written as "isTop & SPHOLEX.IsLexKw(...)" would never even evaluate
     IsLexKw when isTop=FALSE -- the IMPORT keyword inside an included
     file would then be left completely unconsumed (not an error, not
     skipped, just abandoned mid-stream), silently defeating the
     single-include-level check below instead of triggering it. The
     keyword must always be consumed via IsLexKw so the loop body's own
     ~isTop check can actually run and report it. *)
  WHILE SPHOLEX.IsLexKw("IMPORT") DO
    IF ~isTop THEN
      SPHOLEX.SrcPath(sp);
      LogErr.ErrorInFile(sp, LONGINT(SPHOLEX.CurLine()), "an IMPORTed file may not itself IMPORT (single include level)");
      SPHOLEX.SetOk(FALSE)
    END;
    REPEAT
      SPHOLEX.CurTokText(incNm); SPHOLEX.Next;
      IF SPHOLEX.Ok() THEN
        IF ~SPHOLEX.OpenInclude(incNm) THEN SPHOLEX.SetOk(FALSE)
        ELSE
          IF ~ParseModule(FALSE) THEN SPHOLEX.SetOk(FALSE) END;
          SPHOLEX.CloseInclude   (* restores the already-fetched token too *)
        END
      END
    UNTIL ~SPHOLEX.IsLexSym(",");
    SPHOLEX.Expect(";")
  END;
  IF SPHOLEX.IsLexKw("CONST") THEN
    WHILE (SPHOLEX.CurTokKind() = TIdent) & ~SPHOLEX.IsKw("TYPE") & ~SPHOLEX.IsKw("VAR") & ~SPHOLEX.IsKw("PROCEDURE")
          & ~SPHOLEX.IsKw("BEGIN") & ~SPHOLEX.IsKw("END") DO
      ParseConstDecl
    END
  END;
  IF SPHOLEX.IsLexKw("TYPE") THEN ParseTypeSection END;
  IF SPHOLEX.IsLexKw("VAR") THEN ParseVarSection(TRUE) END;

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
  WHILE SPHOLEX.IsLexKw("PROCEDURE") DO ParseProcedure END;

  (* a BEGIN...END body is the module's init part -- 'start' marks the
     program entry point (SPHO.MD §"Entry point selection"); only legal
     in the top-level file. *)
  IF SPHOLEX.IsLexKw("BEGIN") THEN
    IF ~isTop THEN
      SPHOLEX.SrcPath(sp);
      LogErr.ErrorInFile(sp, LONGINT(SPHOLEX.CurLine()), "an IMPORTed file may not have its own BEGIN...END init part");
      SPHOLEX.SetOk(FALSE)
    ELSE
      Emit("global start");
      Emit("start:")
    END;
    ParseStmtList
  END;
  SPHOLEX.ExpectKw("END");
  IF SPHOLEX.CurTokKind() = TIdent THEN SPHOLEX.Next END;
  SPHOLEX.Expect(".");
  RETURN SPHOLEX.Ok()
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

(* FreeChunks: DISPOSE every allocated node/block of THIS module's own
   Lit/Pending lists (zero-leak rule -- CLAUDE.md "ZERO HEAP LEAKS"),
   then SPHOLEX.FreeChunks for its own lex/type/proc/const/var tables --
   one call from RunBody frees everything either module owns. *)
PROCEDURE FreeChunks;
  VAR lc, ln: LitChunk; pc, pn: PendingChunk;
BEGIN
  lc := litHead;
  WHILE lc # NIL DO ln := lc^.next; DISPOSE(lc); lc := ln END;
  litHead := NIL; litTail := NIL;
  pc := pendingHead;
  WHILE pc # NIL DO pn := pc^.next; DISPOSE(pc); pc := pn END;
  pendingHead := NIL; pendingTail := NIL;
  SPHOLEX.FreeChunks
END FreeChunks;

PROCEDURE RunBody(): INTEGER;
  VAR srcPath, outPath: ARRAY 128 OF CHAR;
      argc: INTEGER; dbgbuf: ARRAY 96 OF CHAR;
BEGIN
  argc := Dos.ParamCount();
  IF argc < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, srcPath);
  IF ~Files.FileExists(srcPath) THEN
    LogErr.Error2("no such file: ", srcPath); RETURN ExitIo
  END;
  (* explicit init, not assumed -- the runtime does not zero module
     globals (see StrTab.MOD's own header comment). *)
  nLits := 0;
  nPending := 0;
  labelCnt := 0; loopDepth := -1;
  curSect := SectNone;
  litHead := NIL; litTail := NIL;
  pendingHead := NIL; pendingTail := NIL;
  SPHOLEX.Reset;
  Out.String("DEBUG after Reset nLex="); Out.Int(SPHOLEX.CurLexMark(), 0); Out.String(" find="); Out.Int(SPHOLEX.FindLexeme("MODULE"), 0); Out.Ln;
  SPHOLEX.SetSrcPath(srcPath);
  Out.String("DEBUG after SetSrcPath find="); Out.Int(SPHOLEX.FindLexeme("MODULE"), 0); Out.Ln;
  IF ~SPHOLEX.OpenSource(srcPath) THEN RETURN ExitIo END;
  Out.String("DEBUG after OpenSource find="); Out.Int(SPHOLEX.FindLexeme("MODULE"), 0); Out.Ln;
  SPHOLEX.Next;
  SPHOLEX.CurTokText(dbgbuf);
  Out.String("DEBUG tokKind="); Out.Int(SPHOLEX.CurTokKind(), 0); Out.String(" tokLex="); Out.Int(SPHOLEX.CurTokLex(), 0);
  Out.String(" tokText=["); Out.String(dbgbuf); Out.String("]"); Out.Ln;
  Out.String("DEBUG FindLexeme(MODULE)="); Out.Int(SPHOLEX.FindLexeme("MODULE"), 0); Out.Ln;

  Files.ReplaceExt(srcPath, ".ASM", outPath);
  IF ~Files.ReWrite(outF, outPath) THEN
    SPHOLEX.CloseSource; LogErr.Error2("cannot write ", outPath); RETURN ExitIo
  END;

  IF ~ParseModule(TRUE) OR LogErr.HaveErr() THEN
    SPHOLEX.CloseSource;
    Files.SetDeleteOnClose(outF, TRUE); Files.Close(outF);
    FreeChunks; RETURN ExitAsm
  END;

  (* Every PROCEDURE in the whole translation unit (top-level file + every
     IMPORTed file it spliced in) has now been parsed -- safe to
     re-resolve every call site that couldn't be resolved at the time it
     was emitted (see PendingChunk's own header comment). *)
  CheckPendingCalls;
  IF LogErr.HaveErr() THEN
    SPHOLEX.CloseSource;
    Files.SetDeleteOnClose(outF, TRUE); Files.Close(outF);
    FreeChunks; RETURN ExitAsm
  END;

  EmitLiterals;
  SPHOLEX.CloseSource;
  Files.Close(outF);
  LogErr.Info2("wrote ", outPath);
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
