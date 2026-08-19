# SPHO — SPHINX Oberon Translator

`SRC/TASM/SPHO.MOD` (module `SPHO`, built as `BIN/SPHO.EXE` via
`SRC/TASM/Makefile`) translates a SPHINX Oberon source file (dialect defined
in [DOCS/SPHINX.MD](SPHINX.MD)) into NASM-subset `.ASM` source, feedable
straight into `TASM.EXE` (see [DOCS/TASM.MD](TASM.MD)).

```
spho SRCFILE.SMD
```

Output path is auto-derived by replacing the input's extension with `.ASM`
(`Files.ReplaceExt`), matching `TASM.EXE`/`TA2NASM.EXE`'s own
single-positional-argument, no `-o` override convention. On any parse
error the partial `.ASM` is deleted (`Files.SetDeleteOnClose`), matching
`TASM.MOD`'s own error-cleanup convention.

## Design

SPHINX Oberon is a line-oriented, statement-level **1:1 mapping** onto NASM
— no optimization, no dataflow analysis, no whole-program symbol
resolution across files. This lets the whole translator be a single
recursive-descent pass with **no separate AST**: each `Parse*`/`Emit*`
procedure both parses its construct and emits its NASM text before
returning.

SPHO owns a small hand-written scanner (not TASM's own `SCAN.MOD`, whose
token set is NASM-instruction-shaped, not SPHINX-Oberon-shaped). Source is
**streamed** from a `Files.File` handle with a 2-char lookahead (mirrors
`SCAN.MOD`'s own `NextCh` shape) — no whole-file RAM buffer, so source
files are not size-limited. Identifier/keyword recognition uses
`SYSTEM.ISALPHA`/`ISDIGIT` plus `_` (SPHINX idents allow underscore, e.g.
`src_hnd`); number literals are decoded by `Scan.ParseNumBuf` (SCAN.MOD's
own canonical parser — decimal, C-style `0x1A`, trailing-`H` hex, and
trailing-`B` binary). Register-name recognition delegates to
`Lex.LookupReg`/`Lex.IsByteReg` (LEX.MOD's own register table, the same
one `TASM.EXE` uses) instead of a separate hand-written list.

**Unified lexeme table**: every keyword, symbol, register, `TYPE` name,
`PROCEDURE` name, `CONST` name, and `VAR` name in the whole file lives in
ONE chunked list (`LexChunk`, `Chunk = 64` entries per node, CLAUDE.md
"Chunk small records"), each row uniform — `nameId` (interned via
`StrTab`, CLAUDE.md "StrTab adoption pattern"; lookup is a
`StrTab.TStrTabId` compare, not a string compare), `kind`
(`LexKw`/`LexSym`/`LexReg`/`LexType`/`LexProc`/`LexConst`/`LexVar`), and
`ref` (meaning depends on `kind`: a hand-numbered `Kw*`/`Sy*` id for
keywords/symbols, `Lex.RegAX..Lex.RegDS` directly for registers, or an
index into a small per-kind detail table — `TypeChunk`/`ProcChunk`/
`ConstChunk`/`VarChunk` — for everything else). This replaced four
separate lookup tables (a shared `SymChunk` for `VAR`/`CONST`, plus
separate `TypeChunk`/`ProcChunk` tables) and the ad-hoc string-compare
`IsKw`/`IsSym`/`IsRegName` checks with one lookup shape: `FindLexeme`
walks a hash bucket (`nameId MOD LexBuckets`, mirroring `StrTab.MOD`'s
own bucket-chain design — O(bucket-chain length) instead of the older
O(whole-array) backward scan) most-recent-first, so a user `CONST`/`VAR`
of the same spelling as an earlier one, a keyword, or a register
correctly shadows it; `IsKw`/`IsSym`/`IsRegName` are now `tokLex`
kind/ref comparisons against the current token's already-resolved
lexeme, not fresh string compares. Keywords/symbols/registers are
pre-seeded once per file (`RegisterBuiltins`, called at the start of
`RunBody`) from `kwSpellings`/`sySpellings` — the one place their
spellings are enumerated, walked both to seed the table and (via
`KwIdOf`/`SyIdOf`) to resolve an id back from a token.

`LexTruncate` (a procedure's own locals/params going out of scope at
`END`) also unlinks each truncated row from its own bucket chain, not
just shrinking `nLex` — cheap, since the truncated range is always one
procedure's own locals/params, never the whole file.

`TYPE`/`PROCEDURE`/`CONST`/`VAR` detail tables (`TypeChunk`/`ProcChunk`/
`ConstChunk`/`VarChunk`) are fixed-size **directories** of `Chunk`-sized
blocks (`ARRAY MaxDetailChunks OF pointer-to-block`, the same shape
`StrTab.MOD`'s own `textDir`/`entDir` already use), not linked lists — a
detail-table slot is an O(1) `ref DIV Chunk` array index instead of an
O(n/Chunk) next-pointer hop. `CONST` values are `LONGINT` (4 bytes, too
wide for the lexeme row's own `ref: INTEGER` field), so `ConstChunk`
genuinely can't fold into the lexeme row itself the way `LexKw`/`LexSym`/
`LexReg` do.

## Translation rules implemented

- **`IMPORT ModName;`** = `#include ModName.SMD` (SPHINX.MD's own words):
  the named `.SMD` file is opened, streamed, and fully translated in
  place — its `TYPE`/`VAR`/`PROCEDURE` declarations are spliced into the
  includer's own output — not a NASM `%include` of a separate object.
  **Single include level only**: an IMPORTed file may not itself IMPORT,
  and may not have its own `BEGIN...END` init part (both are translator
  errors) — only the top-level file may hold the program's entry point.
- **Module init (`BEGIN...END`)** → label `start:` at its first
  instruction, with `global start` emitted once at the top of `.text`.
  This is how the translator marks the program's entry module.
- **`TYPE R = RECORD ... END`** → NASM `struc R ... endstruc`, one `resb`/
  `resw`/`resd` line per field (no padding, per SPHINX.MD §3.2).
- **No default/assumed section anywhere**: `curSect` starts at a real
  `SectNone` sentinel (not `.data`), and every section-dependent
  emission site calls `EnsureSection` explicitly — the very first
  `section .xxx` line in a translated file's output always comes from
  an actual declaration that needs it, never a hardcoded top-of-file
  emission. A file with nothing to declare (no globals, no procedures)
  emits no section header at all.
- **Global `VAR`**: an **initialized** scalar (`= value` given, a real
  stored value, SPHINX.MD §5.1) emits a `.data` declaration (`dw`/`db`/
  `dd`); every **uninitialized** global — a plain scalar (no `= value`),
  an array of a scalar type (`resb`/`resw`/`resd N`), **an array of
  RECORD** (SPHINX.MD §3.1's own `items: StructXmsRec[4]` example, →
  `resb <N * sizeof(record)>` directly, since the scalar array path's
  `resb`/`resw`/`resd N` only sizes one scalar element and would
  silently under-reserve a record array), or a single RECORD instance
  (→ `resb <sizeof(record)>`, the same shape as the array-of-RECORD case
  — **not** NASM's `istruc`/`iend`, which TASM does not support at all)
  — is zero-filled reserved space and emits into `.bss` instead (TASM
  rejects `RESB`/`RESW`/`RESD` outside `.bss`; `RESB`/`RESW`/`RESD` also
  require a colon after the label, unlike `DW`/`DB`/`DD`, which TASM
  also accepts label-first with no colon). The translator switches
  sections (`EnsureSection`) around each declaration as needed, since
  initialized and uninitialized globals may appear in any order in the
  source.
  Array bounds (`T[N]`) accept a numeric literal or a `CONST` name
  (SPHINX.MD §4: constants usable "wherever a literal is allowed").
- **Local `VAR`** → `[bp-N]` frame slots, `sub sp, N` prologue / `add sp, N`
  epilogue around the body.
- **`CONST name = numericLiteral;`** (SPHINX.MD §4), including a leading
  unary `-` (`CONST Neg = -5;`): recorded in the chunked symbol table; a
  later reference emits the literal value directly, never a memory read.
  Assigning to a `CONST`, or calling `INC`/`DEC` on one, is a translator
  error (`LogErr.Error`) — SPHINX.MD §4's "no storage is allocated"
  invariant means there is nothing to write to. **`TRUE`/`FALSE`**
  (SPHINX.MD §3.1) are registered as ordinary predeclared `CONST`
  entries (`RegisterBuiltinConsts`, values 1/0) at the start of every
  translation, resolving through this exact same path — a user
  declaration of the same name correctly shadows the builtin (`FindSym`
  is a backward, most-recent-wins search).
- **`'x'`/`"..."` literals** (SPHINX.MD §3.3): the scanner distinguishes
  single- from double-quoted text (`TChar` vs. `TStr`) where it
  previously scanned both identically. A `'x'` (single quote, always
  exactly one character) is a plain numeric immediate, `ORD` of that
  character. A `"..."` (double quote, any length) is interned via
  `StrTab` (exact byte content, dedup for free — a repeated literal
  reuses the same `StrTab` id and therefore the same label) and tracked
  in a separate `LitChunk` list (StrTab itself has no notion of "which
  ids are literals" — it's shared with every identifier name in the
  file); it evaluates to its own `.data` label as a bare operand,
  exactly like a global VAR's name already resolves to its address
  elsewhere in this file — usable as a call argument, an assignment RHS
  to a register or a 16-bit variable, or anywhere else an ordinary
  operand is read. `EmitLiterals` appends one `_literalN: db '...', 0`
  line per distinct literal, in first-occurrence order, to a `.data`
  block at the very end of `RunBody` (after everything else — a
  forward reference to a later `.data` label is normal in NASM).
- **`PROCEDURE Name[*](params)[:type][NEAR|FAR|INTERRUPT][;USES regs]`**:
  - **Formal-parameter groups** (SPHINX.MD §6.6): `name {, name} : type`
    — a comma-separated run of names shares ONE trailing type (`a, b:
    INTEGER` types both `a` and `b` as INTEGER); `;` starts a new group
    with its own type, so a single parameter list can mix types (`x:
    BYTE; y: INTEGER`). Each group's names are buffered until its own
    type is known, then typed together — resolving each name's type
    independently as soon as it was read (the previous design) silently
    mistyped every name but the last in a shared-type group.
  - Register-named formals (SPHINX.MD §6.2) get no stack slot at all —
    tracked via a dedicated `isReg` flag (not inferred from `ofs=0`, which
    would be ambiguous with a genuine `[bp-0]`) — every reference to one
    (a read, an assignment target, or `INC`/`DEC`) resolves straight to
    the bare register name; ordinary names get Pascal-order `[bp+4]`,
    `[bp+6]`, ... for NEAR or `[bp+6]`, `[bp+8]`, ... for FAR (rightmost
    actual pushed first, so it lands at the lowest offset; +2 more for
    FAR's extra return-CS word). Offsets are assigned by
    `AssignParamOffsets` only **after** the trailing `NEAR`/`FAR`/
    `INTERRUPT` keyword is parsed — computing them from the pre-keyword
    `exported` flag alone would bake in the wrong offset for an exported-
    but-explicitly-NEAR (or non-exported-but-FAR) procedure. A register
    formal carries no type at all and never joins a following group's
    type.
  - **Call sites now load a register-named formal's argument directly
    into that register, instead of pushing it** (SPHINX.MD §6.2's own
    worked `CB_API(0x1700)` example only ever worked "by accident" until
    this fix — reproduced directly with a second register: `PROCEDURE
    Foo(BX); ... Foo(0x1234);` compiled to `mov ax,0x1234; push ax; call
    Foo`, leaving `BX` holding whatever garbage register value it had
    *before* the call, since `Foo`'s own body reads its parameter
    straight off the bare `BX` name with no stack slot to pop from at
    all). Every declared procedure's own per-parameter register-ness/
    register-name is now recorded (`ProcSetParams`, a new `nParams`/
    `paramIsReg`/`paramRegName` addition to the `ProcChunk` row —
    `ProcParamIsReg` looks it up by position at a call site).

    `EmitCall` still pushes **every** argument, in order, exactly as
    before — this is deliberate, not incidental: it's what keeps each
    argument's own evaluation free to reference/clobber any register
    (including one another callee-bound register argument) with zero
    ordering hazard, the identical guarantee a normal all-stack-param
    call already had. Only *after* every argument is safely on the stack
    does a second pass (`ExtractRegArg`, one call per register-param
    position) pull each register-bound value back off — via a direct
    `[bp+N]` read (`push bp; mov bp,sp` first: 8086 has no SP-relative
    addressing mode at all, `SP` cannot be a base register — a first
    attempt using a literal `[sp+N]` operand failed to assemble, TASM:
    "register not usable as base/index on 8086") into its target
    register, then closing the gap in the remaining stack-bound
    arguments by shifting every word above it down one slot and shrinking
    `SP` by 2. This correctly handles a register-param argument at *any*
    position, including one with ordinary stack-bound arguments both
    before AND after it in the same call (verified directly: `Foo(x:
    INTEGER; BX; y: INTEGER)` called as `Foo(1, 20, 3)` extracts `BX`
    from its own middle slot and re-closes the gap for `y`, both
    computed via a fixed per-argument depth recorded at push time that
    provably never changes as earlier/deeper register arguments are
    extracted — see `ExtractRegArg`'s own header comment for the
    depth-invariance argument). A byte-register argument into a
    byte-register-named formal, or a byte VAR/word-register/word-VAR
    argument into any register formal, is sized/widened the same way the
    stack-bound argument path already does.
  - Exported (`*`) procedures always get `global Name`; **default FAR**,
    but an explicit `NEAR`/`FAR` keyword always wins (SPHINX.MD's own
    note: "can be NEAR/FAR (default - far)"). Every declared procedure's
    resolved FAR-ness is recorded in a chunked name→isFar table
    (`ProcReserve`/`ProcSetIsFar`/`ProcFindIsFar`); `EmitCall` looks a
    callee up there to choose `call` vs. `call far` (SPHINX.MD §6.3) — a
    bare `call` always assembles as a same-module NEAR call regardless of
    the target label's own kind (DOCS/TASM.MD §3), so a FAR callee's
    `retf` epilogue would otherwise pop 2 bytes too many off the return
    address (and, in the other direction, a `retn` on a `call far` leaves
    the return CS word stranded on the stack — either mismatch corrupts
    every instruction after the call returns).
  - **`FORWARD` declarations** (SPHINX.MD §6.3.1, extension beyond the
    dialect's originally-documented grammar): `PROCEDURE Name(params):
    RetTy; NEAR|FAR; FORWARD;` — the full signature is parsed (so params
    get real checking), then `ProcSetForward` records `isFar` via a new
    `isFwdKnown` flag on the `ProcChunk` row WITHOUT marking it `valid`
    (unlike `ProcSetIsFar`, which does both) — `valid` alone answers
    "is this a real, callable definition yet" (ParseProcedure's own
    duplicate-definition check reads it), while `isFwdKnown` alone
    answers "can a call site already trust this row's `isFar`"
    (`ProcFindIsFar` now checks `valid[pk] OR isFwdKnown[pk]`) — the two
    questions are independent on purpose: a FORWARD-declared row is
    trustworthy for `isFar` immediately, but not yet a valid call target
    for duplicate-detection purposes. The FORWARD declaration's own
    parsed params are discarded (`LexTruncate` back to the pre-params
    mark) — they aren't real locals for a body that doesn't exist here;
    the real later definition re-parses its own params afresh under the
    same names, reusing the FORWARD row's `pi` via `ProcFindAny` instead
    of `ProcReserve` creating a second, independent row.

    **Before this fix**, a call to a procedure not yet seen (no
    definition, no way to know NEAR/FAR) silently defaulted to `call
    far`, correct only when the real procedure later turned out to
    genuinely be FAR — reproduced directly: a same-file forward call to a
    NEAR procedure with no FORWARD declaration compiled and linked
    cleanly, but hung the resulting `.COM` at runtime (a `call far` to a
    NEAR target's plain `retn` leaves a stale segment word on the stack,
    desyncing every return address after it). **Now**: `EmitCall`/
    `EmitCallNoArgs` still emit the FAR-guess `call far` when
    `ProcFindIsFar` fails (unchanged — the .ASM text for that call site
    is already written by the time more information could exist), but
    also record the call site (name + source line, `PendingAppend`, a
    `LitChunk`-shaped linked-chunk list of `StrTab.TStrTabId`+`line`
    pairs) into a pending list. Once the WHOLE file (and every file it
    IMPORTs) has been parsed, `CheckPendingCalls` walks that list and
    turns EVERY entry into a hard translator error unconditionally — not
    a re-resolution check: whether the name eventually turned out to be
    defined by end of file makes no difference, since the wrong `call
    far` was already emitted into the output either way, and this
    single-pass/no-AST translator has no way to patch already-written
    text. A `FORWARD` declaration is the only way to make a same-file
    forward call resolvable AT THE CALL SITE ITSELF, which is exactly why
    using one means the call never reaches `PendingAppend` in the first
    place. The ordinary case (caller defined textually AFTER its callee)
    is completely unaffected — `ProcFindIsFar` already succeeds via the
    plain `valid` path before `PendingAppend` would ever be reached.
  - **By-value RECORD parameters are rejected** (SPHINX.MD §6.6,
    `RejectRecordParams`, called right after `ParseParams` in
    `ParseProcedure`): a non-register formal parameter typed as a
    declared RECORD is a translator error ("by-value RECORD parameter
    not supported"). **Before this fix**, it was silently accepted and
    miscompiled: the call site's argument-pushing code has no RECORD
    case at all, so it fell into the generic `mov ax, opnd; push ax`
    path — pushing only the record's own first field (2 bytes) — while
    the callee's own `nStack`/`retn N`/`retf N` accounting (from
    `AssignParamOffsets`) also only ever charges 2 bytes per non-register
    parameter regardless of its real type. Reproduced directly: a 4-byte
    `RECORD x,y: INTEGER END` passed by value compiled clean with no
    error, but silently truncated to `pt.x` alone at the call site and
    mismatched the real 4-byte stack layout at the callee's own cleanup.
    Implementing real by-value struct passing (correct multi-word push
    order, `[bp+N+fieldOffset]` addressing for every parameter after a
    RECORD one, and size-aware stack cleanup) was judged too large/risky
    a change for the value it adds, since the working alternative
    (`ADR(rec)` into a plain `WORD`/`INTEGER` parameter, §3.1) already
    covers the same use case with no new codegen risk.
  - **`Name;`** (no parentheses at all, SPHINX.MD §6.4/§13's own
    `XMS_CLEAR_REC;`): a zero-argument call, `EmitCallNoArgs` — a bare
    identifier statement matching neither a register-pair LHS (`:`) nor
    an assignment (`:=`) nor a parenthesized call (`(`) is treated as
    this, unless it names a register (in which case it's a translator
    error, not a call — no SPHINX construct ever calls a register name).
  - `USES r1, r2, ...` (`FLAGS` included) emits `push`/`pushf` in the
    prologue and the mirrored `pop`/`popf` in the epilogue. Bound-checked
    against `MaxUses` (raised 8 → 16) the same way `ParsePushPop`'s own
    `PUSH`/`POP` register list already was — `ParseUses` previously had
    **no bound check at all**, so a `USES` clause naming more than the
    old `MaxUses=8` registers would silently write past `regs[]`'s own
    fixed-size array bounds instead of reporting a translator error
    (reproduced directly: `EXAMPLES/CLIPDRV/CLIPDRV.SMD`'s own
    `NEW_PS_INT` interrupt handler genuinely needs `USES ES, DS, BP, SI,
    DI, DX, CX, BX, AX, FLAGS` — 10 entries — to save/restore every
    register it touches).
  - `INTERRUPT` procedures end in `iret` instead of `ret`/`retf`.
  - **The `push bp`/`mov bp,sp` ... `mov sp,bp`/`pop bp` stack frame is
    only emitted when the procedure actually needs one** — `needsFrame
    := (nStack > 0) OR (frameOfs > 0)`, i.e. it has at least one
    non-register parameter (`[bp+N]` addressing) or at least one local
    `VAR` (`[bp-N]` addressing); a procedure with only register-named
    parameters and no locals never references `BP` at all, so building
    the frame was pure waste (extra bytes and cycles on every call, plus
    an unnecessary clobber of the caller's own `BP` — harmless since it's
    always restored, but still work with no purpose). In that case only
    the label and the bare `retn`/`retf`/`iret` are emitted — no
    `push`/`pop bp` on either side (verified directly: `PROCEDURE
    Foo(BX): INTEGER; NEAR; BEGIN RETURN BX+1 END;` compiles to just
    `Foo: add ax,1 \ jmp .L1 \ .L1: retn`). `frameOfs` isn't known until
    `ParseVarSection` has actually run, so the label is emitted first
    (unconditionally, needed regardless), then `VAR` is parsed, then the
    frame decision is made and the (possibly-empty) prologue follows —
    `USES` is parsed earlier (order-independent of `VAR`, both pure
    lookahead before the body itself) but its own `push`/`pop` pair
    always still happens, framed or not.
  - **`RETURN [expr]`** (SPHINX.MD §8.3) is legal anywhere in the body,
    not only as the textually last statement: it evaluates `expr` into
    `AX` (if given) and jumps to the procedure's own single epilogue
    label (`procExitLbl`, allocated once per `ParseProcedure`; no stack
    needed since SPHINX has no nested procedures) — the actual epilogue
    (local-frame cleanup, `USES` pop, `ret`/`retf`/`iret`) is emitted
    exactly once, right after that label. A body with no explicit
    `RETURN` falls through to the same label unaffected. A bare
    `RETURN` (no `expr` at all) recognizes `ELSE`/`ELSIF` as
    terminators too, not only `;`/`END`/end-of-file — previously missing
    (`ParseReturn`'s own no-expression check was `~IsSym(";") &
    (tokKind # TEof) & ~IsKw("END")`, nothing more), so `IF cond THEN
    RETURN ELSE ... END` (a completely ordinary pattern — a bare
    `RETURN` as the last statement of an `IF`'s own THEN branch,
    immediately followed by `ELSE`) wrongly fell into the
    expression-parsing branch and tried to read the `ELSE` keyword
    itself as an expression operand — reproduced directly: emitted `mov
    ax, [ELSE]` (`ELSE` read as a bare, undeclared identifier) into the
    `.ASM` output, an undefined symbol at assemble time
    (`EXAMPLES/CLIPDRV/CLIPDRV.SMD`'s own `INSTALL`: `IF AX = 0 THEN ...
    RETURN ELSE xmsHndl := AX END`).
- **Expressions**: strictly left to right, no precedence (SPHINX.MD §7) —
  first operand loads into a scratch register/destination, then each
  further `(op, operand)` pair applies the matching instruction
  (`add`/`sub`/`and`/`or`/`xor`/`shl`/`shr`) in turn. A leading unary `-`
  on a numeric literal (`AX := -1;`) emits a negative NASM immediate
  directly. A byte-register first operand (`AL`/`BL`/`CL`/`DL`/`AH`/
  `BH`/`CH`/`DH`) landing in a word-sized destination is zero-extended
  (`EmitWidenByteToWord`: load into the destination's own low half, or
  `AL` if it has none, then clear the high half) rather than emitted as
  a same-size `mov` — BYTE/BOOLEAN are documented unsigned (SPHINX.MD
  §3.1), so this is zero- not sign-extension (no `CBW`).
- **`SEGREG := SEGREG;`** (SPHINX.MD §2's own worked `DS := CS;`
  example): 8086 has no segment-register-to-segment-register `mov`
  encoding at all (TASM: "unsupported MOV operand combination",
  reproduced directly — the generic `mov destReg, firstOpnd` fallback
  every other register assignment already used had no segment-register
  check of its own, so `DS := CS;` silently emitted the illegal `mov
  ds, cs`). Now detected via `Lex.IsSegReg` on both sides and emitted as
  `push CS` / `pop DS` instead, matching SPHINX.MD's own documented
  output exactly. Two ordinary (non-segment) registers, or a
  segment-register destination with a non-register/non-segment source,
  are unaffected — this check only fires when BOTH sides are segment
  registers.
- **`reg := 0;`** (any general-purpose 8/16-bit register, never a
  segment register) compiles to `xor reg, reg` instead of `mov reg, 0`
  — shorter encoding, identical result. Detected via `IsZeroLiteral` (a
  direct digit-scan over the literal's own source spelling — deliberately
  NOT routed through the numeric-literal parser, since the RHS operand
  text reaching this check might just as easily be a register name, a
  memory operand, or a bare identifier, none of which should ever hit a
  numeric parser at all) recognizing plain-decimal (`0`, `00`, ...) and
  trailing-H/B-suffix (`0H`, `0B`, ...) zero spellings; the C-style
  `0x0` prefix form is not recognized (falls through to the safe,
  unchanged `mov reg, 0`, never wrong — just misses this one
  optimization for that one spelling).
- **`reg = 0`/`reg # 0`** as an `IF`/`WHILE` condition compiles to
  `or reg, reg` instead of `cmp reg, 0` — `or` sets `ZF` identically for
  a zero/nonzero test (shorter encoding, no immediate operand), but is
  **not** used for the ordering relationals (`<`/`>`/`<=`/`>=`), which
  need the real borrow/sign flags a genuine `sub`-based `cmp` produces
  and `or` does not. Applies after `LoadIfMem`'s own memory-operand
  load, so `IF someVar = 0 THEN` (a memory operand, loaded into `AX`
  first) benefits too, not just a bare register condition.
- **Relational operators as a value** (SPHINX.MD §7.3, `AL := AX > BX;`):
  detected before the ordinary arithmetic chain and diverted to
  `cmp a,b` / `Jcc` / `mov dst,0` / `jmp` / `mov dst,1` — terminal
  (SPHINX gives no example chaining a relational result into a further
  operator). 8086 has no `SETcc` (that's 386+), hence the jump-based
  form instead of `xor`/`setCC`. A bare memory first operand (no size
  prefix) is loaded into `AX` first, since comparing `[bp-N]` directly
  against an immediate is size-ambiguous to TASM.
- **`ADR(v)`/`SEG(v)`/`SIZE(T)`/`ODD(x)`** (SPHINX.MD §9 value
  built-ins): `SEG(v)` still requires `v` to name a *global* VAR (a
  local/param has no separate segment override — it's always
  `SS`-relative, and SPHINX has no syntax to express "SS" as `SEG`'s own
  result) — a local, a register, or an undeclared name is a translator
  error. `ADR(v)` accepts a *local or param* too, not only a global: a
  global's bare label name is still its own offset as a NASM immediate
  (unchanged, zero-cost), but a local/param has no compile-time-constant
  offset (only known relative to `BP` at runtime), so `ADR(local)`
  instead emits `lea ax, [bp±N]` and yields `"ax"` as the operand text —
  the same emit-then-substitute-a-register convention a call's own
  result already uses elsewhere in `OperandText`. A register-named
  param (SPHINX.MD §6.2) has no frame slot and no address at all —
  `ADR()` on one is still a translator error. `ADR(v)` also now accepts
  a **PROCEDURE name**, not only a VAR/param — the procedure's own bare
  label is already its own offset as a NASM immediate (`mov ax,
  ProcName`), the identical zero-cost convention a global VAR's own bare
  name already gets (`FindSym` never matches a `LexProc` row, so this
  falls back to `ProcFindAny` when the plain-VAR lookup fails, before
  reporting an error). Needed for installing an interrupt vector
  (`INT 21h/AH=25h`-style "DS:DX = new vector") without a raw `ASM mov
  ax, ProcName` block — before this, `ADR(SomeInterruptHandler)` was
  rejected as "requires a declared VAR or param name"
  (`EXAMPLES/CLIPDRV/CLIPDRV.SMD`'s own `INSTALL`, installing
  `NEW_CB_INT`/`NEW_PS_INT` as interrupt handlers, needed the
  workaround). Whether the named procedure is FORWARD-pending or already
  fully defined makes no difference — either way it already has a real
  NASM label reserved under that exact name, which is all a bare-offset
  reference needs. `SIZE(T)` accepts a
  scalar-type keyword or a declared `RECORD` type name. `ODD(x)` is a
  terminal boolean expression like a relational (handled in `EmitExpr`,
  not `OperandText`, since its `test`/`jz`/`mov 0`/`jmp`/`mov 1` result
  needs the final destination register up front) — its argument is
  routed through `AX` first for the same size-ambiguity reason as
  relational comparisons.
- **`CFLAG`/`ZFLAG`** (SPHINX.MD §7.5): recognized only directly in
  condition position (`IF`/`WHILE`, optionally negated with a leading
  `~`), tested via the matching `Jcc` with no `cmp` at all.
- **`Name(args)` as any expression operand**: `OperandText` itself
  recognizes a plain identifier immediately followed by `(` as a call —
  emits it (result lands in `AX`, SPHINX.MD §6.4) and yields `"ax"` as
  the operand text, so a call can appear anywhere an ordinary operand
  is read: `RETURN Helper(x, y)`, an `IF`/`WHILE` condition, a call's
  own actual-parameter expressions, or chained into a further operator
  (`t := Helper(x) + 1;`). Previously only `EmitAssignRhs`'s own
  bespoke top-level RHS shape recognized a call at all, and even that
  returned immediately after emitting it — it never chained a following
  operator, silently dropping it (`t := Helper(x) + 1;` computed the
  call but never added the `1`). Every other context (`RETURN`'s
  expression, a condition, a nested actual parameter) didn't recognize
  a call as an operand shape at all: `Name` was read as a plain
  (undeclared) variable and the following `(args)` was left completely
  unconsumed, hanging the translator (`ParseStmtList`'s own loop spun
  forever re-parsing the same stuck token) — reproduced directly via
  `RETURN Helper(x, y)`.
- **Chained expression with a call as the right-hand operand**
  (`x := x + Call(...)`, SPHINX.MD §7's own left-to-right chain):
  `EmitExprTail`'s `+`/`-`/`&`/`|`/`SHL`/`SHR`/`XOR` branches now read
  the chain's next operand through `EmitTailOperand`, not a bare
  `OperandText` call. A call operand's result always lands in `AX`
  (SPHINX.MD §6.4), which — for every one of these ops — is also the
  running accumulator (`destReg`) holding the chain's own left-hand
  value so far; evaluating the call before combining silently
  overwrites that accumulator, so the instruction ends up combining the
  call's result with itself instead of with the chain's actual
  left-hand value (reproduced directly: `dstEnd := dstEnd +
  Strings_Length(dst)`, `EXAMPLES/SPHO/STRINGS.SMD`'s own
  `Strings_Cat`, compiled to `add ax, ax` instead of `add ax, cx` —
  `Strings_Length`'s own call overwrote `AX`, i.e. `dstEnd`'s running
  value, with its result, and a call's own operand text is always just
  `"ax"` again, so the add doubled the call's result instead of adding
  it to `dstEnd`). `IsCallOperand` decides — from `tokText` alone,
  *before* consuming anything (the scanner has no token-level backtrack,
  so this can't be answered by first trying `OperandText` and checking
  after) — whether the upcoming operand is going to be read as a call: a
  bare identifier reaching an operand position is only ever valid as a
  register, a builtin (`ADR`/`SEG`/`SIZE`/`ODD`), an already-declared
  `CONST`/`VAR`, or a call, so ruling out the first three makes "must be
  a call" the only remaining possibility for any other identifier
  (including one not yet declared — `FindSym` only ever matches
  `CONST`/`VAR` rows, never a proc name, so a forward-referenced `NEAR`
  proc correctly falls into "must be a call" too). Only when
  `IsCallOperand` is true does `EmitTailOperand` pay for a
  `push destReg` / evaluate / `mov cx, destReg` / `pop destReg`
  save-and-restore around the call, so the combining instruction sees
  the chain's real left-hand value in `destReg` and the call's result in
  `cx` — every non-call operand (immediate, register, memory, builtin)
  takes the exact same single `OperandText` call this always used, zero
  bytes of overhead (verified byte-diff-identical against every
  existing fixture with a non-call chain, e.g. `RETURN AX+BX`).
- **Call-argument sizing** (`EmitCall`, SPHINX.MD §6.1's own
  left-to-right `push` convention): a byte register argument
  (`AL`/`BL`/`CL`/`DL`/`AH`/`BH`/`CH`/`DH`) is zero-extended into `AX`
  before pushing — 8086 has no `push` form for a single byte register
  (`push al` is "operand size mismatch" to TASM), unlike a word register,
  which pushes directly. A byte-typed `VAR`/param argument (detected by
  peeking its declared type via `FindSym`/`SymTy` *before*
  `OperandText` flattens it to memory text, the same peek-before-consume
  shape `IsCallOperand` uses) is loaded through `AL` — one byte, from
  the identifier's own real 1-byte frame slot or global storage — then
  zero-extended, instead of a blind word-wide `mov ax, opnd`, which
  would read one byte *past* a 1-byte slot into `AH` as garbage
  (reproduced directly: `EXAMPLES/SPHO/LCOUNT.SMD`'s own `Out_Int(c)`
  with `c: BYTE` printed a large garbage value — hundreds, not `c`'s
  real `0..255` range — because the call-argument load picked up
  whatever adjacent stack byte happened to sit at `[bp-N+1]`). Every
  other argument shape (immediate, non-byte `VAR`, expression) is
  unaffected.
- **`[seg:base] := expr;` / `x := [seg:base];`** (SPHINX.MD §10, direct
  memory access): `[` starts a memory operand, both as a statement's
  assignment target and inside any expression. `[seg:base].RecordType.field`
  resolves the field offset via the declared `struc`. A single-register
  RHS with no further chained operator (`[ES:BX] := AL;`) sizes the move
  from the source register (`mov byte [es:bx], al`) instead of always
  routing word-sized through AX. A single-**variable** RHS (not a
  register) with no chained operator and no already-known size hint
  (a bare `[seg:base]` target, not a `.RecordType.field` one — that case
  already gets its size from the field's own declared type) is sized
  from the SOURCE variable's own declared type the same way: `destSize`
  is only ever filled in from a RECORD-field access (`ParseMemOperand`
  never looks at the RHS at all, since it's parsed later), so a bare
  `[ES:DI] := byteVar;` used to fall through to the generic word-wide
  `EmitExprAssign` default and silently write 2 bytes where 1 was meant
  — reproduced directly: `EXAMPLES/CLIPDRV/CLIPCLI.SMD`'s own `[ES:DI]
  := curCh; INC(DI);` building up a byte buffer one character at a time
  corrupted every next character's own future byte with a garbage high
  byte before it was ever written (the identical latent bug was already
  present, unnoticed, in `EXAMPLES/SPHO/LCOUNT.SMD`'s own `[DS:SI] :=
  c;`, `c: BYTE` — harmless there only because nothing reads the byte
  immediately after that particular write before it's overwritten
  again). When the source variable's own operand text turns out to be
  memory (not a register), it's loaded through `AL` first — x86 has no
  mem,mem `mov` form.
- **Conditions** (`IF`/`WHILE`): a single `a REL b` test
  (`=`, `#`, `<`, `>`, `<=`, `>=`) becomes `cmp` plus the matching
  conditional jump; a bare memory first operand is loaded into `AX`
  first (same size-ambiguity reasoning as relational-as-value above,
  via `LoadIfMem`) — sized correctly for a `BYTE`/`BOOLEAN` operand
  too: `LoadIfMem` now takes an `isByteVar` flag (peeked the same way
  `EmitCall`'s own byte-argument check works — before `OperandText`
  flattens the identifier to memory text) and, when set, loads through
  `AL` and zero-extends instead of a blind word-wide `mov ax, opnd`,
  which read one byte past a 1-byte slot into `AH` as garbage
  (reproduced directly: `WHILE gotByte = TRUE DO` with
  `gotByte: BOOLEAN`, `EXAMPLES/SPHO/LCOUNT.SMD`'s own main read loop,
  terminated after exactly one iteration instead of running to EOF,
  since the garbage high byte alongside `gotByte`'s own `TRUE`/`FALSE`
  low byte almost never happened to be zero). Only the condition's own
  first operand (`a`) is peeked and byte-checked this way — a value
  used in `EmitRelational` (the `AL := AX > BX;` "relational as value"
  form, not a condition) still doesn't get this treatment, since its
  `firstOpnd` arrives already flattened to text by a caller several
  calls removed from the original identifier token; see "Known
  simplifications" below.
- **Bare BOOLEAN conditions** (`IF sss THEN`, `IF ~sss THEN`,
  `IF SomeCall() THEN`, `WHILE sss DO`, ...): a condition's first operand
  `a` is now always parsed via `OperandText` first (uniformly handling a
  bare variable, a register, or a call — `OperandText` already dispatches
  to `EmitCall` for `Name(...)`, per its own header comment), and only
  *after* that is the next token peeked via `IsRelSym` to decide which of
  two paths applies: a relational operator (`=`/`#`/`</>`/`<=`/`>=`)
  continues into the existing full `a REL b` → `cmp`+`Jcc` path; anything
  else (`THEN`/`DO`, i.e. nothing followed `a`) falls into a new
  bare-boolean path instead — `cmp aLoaded, 0` then `jne`/`je` (TRUE=1 is
  nonzero, FALSE=0, per SPHINX.MD §3.1), honoring a leading `~` the same
  way the existing `CFLAG`/`ZFLAG` path already did (a nested `IF onTrue
  THEN ... ELSE ...` picks the jump — see the `TOC.EXE` codegen bug this
  now deliberately avoids, just below). This removes the previous
  requirement to spell out `sss = TRUE`/`sss = FALSE`/`SomeCall() = TRUE`
  explicitly — that form still works unchanged (it takes the `a REL b`
  path, `b` being the literal `TRUE`/`0`/`FALSE`/`1` operand), the bare
  form is now just an additional accepted shape for the same condition
  position. `~` in front of a bare condition (previously a translator
  error — "'~' only supported directly on CFLAG/ZFLAG" — for anything
  but `CFLAG`/`ZFLAG`) now works for any bare BOOLEAN condition, not only
  the flag tests. The byte-var peek (`aIsByteVar`, described just above)
  is unaffected — still computed once, before `OperandText` runs, and
  used by both paths.
- **Every jump-polarity choice in `EmitCondJump` is written as a nested
  `IF onTrue THEN ... ELSE ...`, never `IF onTrue # negated THEN ... ELSE
  ...`** (a plain BOOLEAN `#` comparison) — all three sites (the
  `CFLAG`/`ZFLAG` path, the `a REL b` path, and the bare-boolean path).
  This works around a confirmed `TOC.EXE` (the Oberon-07 compiler that
  builds `SPHO.MOD` itself) codegen bug: `onTrue # negated`, evaluated
  from *inside a condition nested within another condition's own THEN/DO
  body* (a nested `IF`, or an `IF` inside a `WHILE` — a sequential,
  non-nested pair of conditions was unaffected), silently picked the
  WRONG side regardless of `onTrue`/`negated`'s actual values — diagnostic
  instrumentation confirmed `onTrue`, `negated`, and `RelJumps`' own
  `jt`/`jf` output were all individually correct at the point of the
  bug, yet the `#`-based selection still chose wrong. Reproduced directly
  (bisected against an Aug-14 SPHO.EXE build, confirmed correct, so this
  was introduced sometime in the bare-boolean-condition work above, not
  present from the start): `IF a = 0 THEN IF b = 0 THEN RETURN 1 END
  END; RETURN 0` — called as `Test(0, 0)`, both conditions genuinely
  TRUE — returned `0` instead of `1`, the inner condition's own THEN
  branch unreachable no matter what `b` was. Rewriting the exact same
  logic as a nested `IF onTrue THEN (IF negated THEN X ELSE Y) ELSE (IF
  negated THEN Y ELSE X) END` — provably equivalent boolean logic, just
  not expressed via `#` — fixed it completely; verified via the same
  repro (now returns `1` correctly), a full runtime `.COM` build/run, and
  the regression suite (`FILES.ASM`/`MAINTEST.ASM` byte-identical
  before/after). Root cause not pursued further (would require debugging
  `TOC.EXE`'s own codegen, out of `SPHO.MOD`'s scope and requiring
  maintainer sign-off per CLAUDE.md) — this is a workaround at the
  `SPHO.MOD` source level, not a fix to the underlying compiler bug.
- **`WHILE`/`DO`/`END` is the only loop construct** — `REPEAT`/`UNTIL` is
  not part of SPHINX Oberon and is not recognized: `SPHO.MOD` briefly had
  a `ParseRepeat`/`KwRepeat`/`KwUntil` implementation (never a documented
  SPHINX Oberon feature) that has since been removed — `REPEAT` now falls
  through to the ordinary call/assignment parser (an undeclared
  identifier), and `UNTIL` is not a recognized statement-list terminator,
  so a `REPEAT ... UNTIL cond` block fails downstream with a parse error
  rather than being accepted.
- **`BREAK`/`CONTINUE`**: jump to the innermost loop's exit/top label.
- **`INC(v)`/`DEC(v)`**: resolved through the same symbol table as any
  other reference (so a local's `[bp+-N]` slot or a register param's bare
  register is used, not the raw name), sized `byte`/`word` from `v`'s
  declared type; a `v` naming a `CONST` is a translator error. `v` may
  also be a bare register name (`INC(BX)`), checked via `IsRegName`
  *before* the symbol-table lookup, since a register is a `LexReg`
  lexeme — a kind `FindSym` never searches (only `LexConst`/`LexVar`
  rows) — passing an unrecognized name straight through used to fall
  into the "bare global label" text-substitution path, silently
  emitting `inc word [BX]` (incrementing the memory *at* address `BX`,
  not the register itself) instead of `inc BX` — reproduced directly via
  `OUT.SMD`'s own `Out_String`, whose `INC(BX)` pointer-advance compiled
  to that exact bug, corrupting the string's own bytes in place instead
  of ever advancing past them.

  **`INC(v, expr)`/`DEC(v, expr)`** (extension beyond SPHINX.MD §9's own
  single-argument table): `v := v ± expr`, `expr` a full expression
  (including a call) evaluated via the same `EmitExpr` machinery every
  other expression context uses. Guarded against two distinct
  accumulator-clobber hazards: (1) if `expr` is itself a call, its
  result — always returned via `AX` — would otherwise land on top of
  `v`'s own pre-existing value before the add/sub combining them ever
  runs (`EmitTailOperand`'s own hazard, described above under "Chained
  expression with a call as the right-hand operand", reached here
  through `EmitExpr`'s ordinary call-as-operand path); (2) if `v` *is* the
  register `AX` itself, `EmitExpr("ax")` always targets `AX` regardless
  of what `expr` is (not only for a call — a bare literal like
  `INC(AX, 7)` hits this too), so `v`'s old value is clobbered by
  `expr`'s own evaluation before the instruction reads it back
  (reproduced directly: `AX := 50; INC(AX, 7);` printed `14`, not `57`
  — `EmitExpr("ax")` overwrote `AX`'s `50` with `7` first, so `add AX,
  ax` read `7+7`). `EmitIncDecAmountToReg` guards case (2) — push `AX`,
  evaluate `expr`, stash the result in `CX`, pop `AX` back, then
  combine — only when the destination register is `AX` itself; any
  other register (`BX`, `CX`, ...) is never touched by `EmitExpr("ax")`
  at all, so no push/pop is emitted for those, zero-cost for the common
  case. **`INT(n)`**: direct `int n`. **`PUSH(r1,r2,...)`/
  `POP(r1,r2,...)`** (SPHINX.MD §9): `PUSH` pushes left to right; `POP`
  pops in reverse order so a matching `PUSH`/`POP` pair round-trips each
  register.
- **`ASM ... END`**: copied verbatim, line by line, into the output. The
  keyword is consumed with a peek (`IsKw`, not `IsLexKw`), not the
  usual eager `Next`-consuming form every other keyword dispatch in
  `ParseStmt` uses — `ParseAsm` itself reads the block's raw text
  directly off `ch`/`ch2` starting right where `ASM`'s own characters
  ended, and an eager `Next()` call would have already tokenized (and
  thereby silently discarded) the block's first line before `ParseAsm`
  ever got control. This was a real, general bug: every `ASM` block's
  first line was silently dropped whenever the caller used the ordinary
  `IsLexKw("ASM")` form (reproduced directly — a block opening with
  `cld` lost that line entirely, keeping only the lines after it).
- **`SEGREG:REG := ...` / `REG:REG := ...`** (SPHINX.MD §11, LONGINT
  register-pair moves): `TryParseRegPair` peeks a register name
  immediately followed by a bare `:` (never `:=`) to recognize a
  register-pair operand on either side of `:=`; dispatches to `LES`/
  `LDS` when the destination segment is `ES`/`DS` and the source is a
  plain named `LONGINT` VAR (`EmitRegPairFromLongVar`), or a two-`mov`
  fallback otherwise (register-pair-to-register-pair, a call's `DX:AX`
  result, or storing a register pair back into a `LONGINT` VAR). The
  scanner has no token-level backtrack, so recognizing "REG:REG" needs
  the register name consumed before the deciding `:` can even be
  seen — when that `:` turns out not to be there, `TryParseRegPair`
  hands the already-consumed register name back to its caller
  (`consumedReg`) instead of silently discarding it, so a plain register
  operand elsewhere (`[mem] := AL;`) is unaffected. Before this was
  implemented, `SEGREG:REG := ...` matched no parse branch at all:
  `IsLexSym(":=")` failed on the bare `:`, `IsLexSym("(")` failed too,
  and the statement silently consumed nothing, hanging the translator
  (`ParseStmtList`'s own loop spun forever re-parsing the same
  unconsumed `:`) — a hang, not merely an unimplemented feature.

## Known simplifications (not implemented)

- `EmitRelational`'s own comparison operand (the `AL := AX > BX;`
  "relational as value" form, SPHINX.MD §7.3 — not a condition) does not
  get the `isByteVar`-aware `LoadIfMem` treatment `EmitCondJump` now has:
  its `firstOpnd` arrives already flattened to memory/register text by a
  caller several calls removed from the original identifier token, with
  no cheap way left at that point to recover whether the source was a
  byte-sized VAR needing a zero-extending `AL` load instead of a blind
  word-wide one. `EmitCondJump` itself (`IF`/`WHILE` conditions) is
  unaffected — it peeks the identifier *before* flattening it, same
  pattern as `EmitCall`'s own byte-VAR-argument peek.
- `*` (`mul`), `IDIV`/`DIV`/`MOD` are not wired into the expression
  emitter (SPHINX.MD §7.1's `mul`/`idiv`/`div` forms need dedicated
  register-clobber handling — `AX`/`DX` — that the generic left-to-right
  emitter does not yet special-case).
- LONGINT register-pair moves (§11) only accept a plain named `LONGINT`
  VAR as the non-register-pair operand — never a `[seg:base]`
  memory-access expression (`IsPlainLongVar` resolves through
  `FindSym`/`SymTy`, which has no way to evaluate an arbitrary memory
  operand's declared type).
- Local `VAR` declarations accept only one name per line (`VAR i:
  INTEGER; sum: INTEGER;`), unlike formal parameters, which now support
  comma-separated shared-type groups (`a, b: BYTE`) — `ParseVarSection`
  (used for both global and local VARs) was not updated alongside
  `ParseParams`'s own group-typing fix.
- `ODD(x)`/`SIZE(T)` (SPHINX.MD §9) are value built-ins only — usable as
  an expression's RHS, not directly as an `IF`/`WHILE` condition
  (`IF ODD(x) THEN` is not recognized; write
  `t := ODD(x); IF t = 1 THEN` instead). `CFLAG`/`ZFLAG` (§7.5), by
  contrast, *are* condition-position-only (`IF ZFLAG THEN` /
  `WHILE ~ZFLAG DO`) — the two built-in families are not
  interchangeable.
- `~` (logical NOT) is recognized only directly in front of `CFLAG`/
  `ZFLAG` in condition position, not as a general boolean-expression
  operator elsewhere.
- Byte-register-typed expression results widen correctly into a
  word-sized destination register only at the `EmitExprFrom`/`EmitExpr`
  entry point (covers `RETURN byteExpr`, `wordVar := byteExpr`, an
  assignment's RHS, and `ODD`'s own internal use); a raw memory operand's
  true declared size (byte VAR vs. word VAR) is still not tracked through
  `OperandText`'s plain `[name]`/`[bp-N]` text, so a local/global `BYTE`
  VAR compared or combined with a word literal can still emit an
  ambiguous or wrong-width instruction outside the specific paths above.

## 8086-only codegen

Every construct SPHO emits, including the value built-ins (`ODD`,
relational-as-value `AL := AX > BX`), uses only plain-8086 instructions
— no `SETcc` (386+; expressed instead as `cmp`/`Jcc`/`mov 0`/`mov 1` or
`test`/`jz`/`mov 0`/`mov 1`, mirroring `EmitCondJump`'s own jump-based
style) and no `JCXZ`/`LOOP` (CLAUDE.md's own project-wide rule).

## Diagnostics carry filename + line

Every translator diagnostic (`LogErr.ErrorInFile(srcPath, LONGINT(line),
msg)`) reports the source **file** a problem was found in, not only its
line number — `filename(line): message`, the same convention
`SRC/TOC/SCAN.MOD`/`PEXPR.MOD` already use for the Oberon-07 compiler
itself. **Before this fix**, every one of SPHO's own diagnostics (`Expect`/
`ExpectKw`, and roughly thirty other individual `LogErr.Error` call
sites scattered through the file) built its own `"... near line N"` text
by hand, with no filename anywhere — ambiguous the moment `IMPORT`
splices a second file's own line numbers into the same translation unit
(reproduced directly: a syntax error inside an `IMPORT`ed file reported
only its own line number, indistinguishable from the same line number in
the top-level file or any other file it might also `IMPORT`).

`srcPath` (already existed, but was only ever set once, for the
top-level file, via `Dos.ParamStr(1, srcPath)`) is now kept correct
across `IMPORT` too: `OpenSource` copies its own `path` argument into
`srcPath` every time it opens a file (top-level or included), and
`OpenInclude`/`CloseInclude` save/restore it via a new `outerPath`, the
same save/restore shape `outerLine`/`outerCh`/etc. already used.
`CheckPendingCalls` (the end-of-file FORWARD-declaration check, which
runs *after* every `IMPORT`ed file has already been closed and `srcPath`
restored to the top-level file) needed its own dedicated fix: each
`PendingChunk` entry now also stores the call site's own `srcPath`
**at `PendingAppend` time** (`fname[]`, alongside the existing `line[]`),
since by the time `CheckPendingCalls` itself runs, `srcPath` no longer
reflects whichever file the original call was actually written in.

`Expect`/`ExpectKw` — the two most-hit sites, covering the overwhelming
majority of real "expected X, got Y" syntax errors — were converted
first; every other individual `LogErr.Error` call building its own
`"near line N"` text, plus every other one reporting a genuine parse/
semantic problem with no location info at all (`"too many parameters"`,
`"expected register after ':' in register pair"`, `"an IMPORTed file may
not itself IMPORT"`, ...), was converted the same way. The ~8 heap-
exhaustion (`"out of memory (X table)"`) sites were deliberately left as
plain `LogErr.Error` — an allocation failure isn't really "at" a source
location the way a syntax error is, and a stale/misleading line number
(whatever was mid-parse when the allocation failed) would arguably be
worse than none.

## Implementation note: no `LOOP`/`EXIT` in this compiler's Oberon-07

`SRC/TOC/`'s Oberon-07 dialect (the language SPHO.MOD itself is written
in) has no `LOOP`/`EXIT`/`BREAK`/`CONTINUE` statement — only `WHILE` and
`REPEAT..UNTIL` with real conditions (see `DOCS/OBERON07.EBN`). Every
`LOOP...EXIT` construct in SPHO.MOD's own source is written as a `REPEAT
... UNTIL cond` (loop body runs unconditionally once, exits on `cond`) or
a `WHILE ~done DO ... END` with an explicit flag, whichever fits.
