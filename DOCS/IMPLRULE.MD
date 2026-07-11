# Implementation Rules — Oberon Compiler for MS-DOS

Rules that govern how the compiler itself is written (Oberon source in `SRC/TOC/`).
See also: [Oberon language rules](OBERLANG.MD).

---

## No-zero-init  ← CRITICAL, applies everywhere

The DOS runtime does **not** zero-initialize `NEW`'d heap memory or module-
level global variables at load — every field must be set explicitly before
it's read, and there is no "it's probably 0/NIL/empty-string" assumption
that's ever safe. Two concrete traps this has caused:

- **A `NEW`'d chunk's fields are garbage until explicitly written.** Every
  chunked-record allocator (`RelocNode`, `SymbolRec`/`TypeDescRec` in the RAM
  arena, etc.) must fully initialize a fresh chunk's fields before the
  pointer escapes — do not rely on a freshly-`NEW`'d array being zeroed.
- **A module's global `VAR`s are garbage, not zero, right after module
  load** — they only become defined values once that module's own `BEGIN`
  block (or an explicit init procedure it calls) runs. This bit a real S8
  draft: `Def.MOD` tried to cache `Syms.TypeInteger`/`TypeBoolean`/… (module
  globals in `SYMS.MOD`) into a table filled inside `Def`'s own `BEGIN`
  block — but those `Syms` globals are not set by `Syms`'s module body at
  all; they're assigned by `Syms.SymInit` (called explicitly from
  `PARSER.MOD`, once per compile), which runs long *after* every module has
  already loaded. `Def`'s `BEGIN` block runs at module-*load* time, strictly
  before `SymInit` ever executes, so the cached pointers would have captured
  stale/garbage values. Fixed by not caching at all: read `Syms.TypeXxx`
  live on every call instead (a `CASE`-dispatch helper,
  `Def.PrimTypeOf(form)`), never at module-init time. **Rule: don't cache a
  value that another module's explicit init procedure sets later, at a
  point your own module's `BEGIN` block has already run** — this is a
  cross-module ordering hazard, not just a "did I forget to init this field"
  one, so it can't be fixed by more careful zeroing in your own module.

---

## Emit-series rule  ← USE IT

For a fixed byte sequence of length **3 or more**, prefer `EmitCodeStr("XX,YY,...")`
over a chain of `Emit1` / `Emit2` calls. One call site instead of several is smaller
in the compiler binary (fewer FAR calls) and easier to read.

```oberon
(* prefer *)  Cgen.EmitCodeStr("8C,D2,8E,C2")
(* over   *)  Cgen.Emit2(08CH, 0D2H); Cgen.Emit2(08EH, 0C2H)
```

---

## Visibility / NEAR rule  ← USE IT

A procedure that is only called from **inside its own module** must not be exported.
Drop the `*` export marker. Non-exported procs are NEAR by default
(see `OBERLANG.MD` §"Determining is_far").

A NEAR proc emits `E8 rel16` (3 bytes, no PUSH CS, no reloc) at the call site and
`RET`/`RET N` at the epilogue, vs. a FAR proc's `9A` (5 bytes + 2 relocs).
De-exporting an internal proc shrinks **both** the compiler binary and every program it compiles.

When adding a helper used cross-module, mark it `*`.
When the helper is internal, do **not** export it.

**Measuring NEAR-ization:** the win is **binary size + real 8086 cycles**, NOT the
xt instruction count.  A far call and a near call are each ~one instruction to
xt's `--max` counter (Metric A), so an instruction-count comparison shows NEAR
work as **flat**.  Judge it by `.exe`/`.om` size and the byte-stable self-host,
not Metric A.  (Verified 2026-06-28 when QW3 NEAR-ized 10 `Cgen` procs with
zero Metric-A change.)

---

## Strength reduction & peephole optimizations  ← codegen

The 8086 has no barrel shifter and a very slow `IMUL`/`IDIV` (70–90 cycles).
When one operand of `*`, `DIV`, or `MOD` is a compile-time constant, the compiler
replaces the multiply/divide with shifts, masks, or shift+add sequences.  The
logic lives in `PExpr.StrengthReduce` / `StrengthReducible` / `CanShiftAddMul`
(dispatched from `ParseTerm`), plus `Cgen.CgMulConst16` and `Cgen.CgAndImm16/32`.

| Source | Emitted | Notes |
|--------|---------|-------|
| `x * 2^n`, `2^n * x` | `SHL` (16-bit) / `CgLsl32Imm` (LONGINT) | commutative — both operand orders |
| `x * 1` | nothing | identity |
| `x * 0` | `XOR AX,AX` (+`XOR DX,DX`) | |
| `x * m` (m = 2^a−1: 3,7,15,…) | `MOV CX,AX; SHL AX×a; SUB AX,CX` | 16-bit only (`CgMulConst16`) |
| `x * m` (m = 2^a+2^b: 5,6,9,10,12,…) | `MOV CX,AX; SHL AX×a; SHL CX×b; ADD AX,CX` | 16-bit only |
| `x DIV 2^n` | `SAR` (INTEGER/LONGINT) / `SHR` (WORD) | right-operand const only |
| `x MOD 2^n` | `AND AX,2^n−1` (16-bit) / `CgAndImm32` (LONGINT) | right-operand const only |
| `x + 0`, `x − 0`, `0 + x` | nothing (load x) | identity |
| `0 − x` | `NEG` (INTEGER/WORD) | LONGINT `0−l` is a type error (use `−l`) |
| `a[i]`, elem size 2/4/8/16… | `SHL` instead of `IMUL` | `ParseDesignator` index scaling |
| `CMP AX,0` | `TEST AX,AX` | `CgCmpAxImm(0)` — 1 byte shorter, same flags |

**Sign correctness (verified, no correction terms needed):**
- `DIV` floors toward −∞ in Oberon; 8086 `SAR` also floors for negatives, so
  `x DIV 2^n` == `SAR x,n` exactly (e.g. `−7 DIV 2 = −4 = SAR(−7,1)`).
- Oberon `MOD` with a positive divisor is the non-negative low bits, so
  `x MOD 2^n` == `AND x,(2^n−1)` even for negative x (e.g. `−5 MOD 4 = 3`).

**Multiply commutativity:** `*` reduces in BOTH operand orders.  `DIV`/`MOD` are
NOT commutative — only `x DIV const` / `x MOD const` (constant divisor) reduce;
a constant dividend (`const DIV x`) keeps the real divide.

**Shift-by-N caveat:** `CgMulConst16` uses repeated `SHL r16,1` (`D1 /4`), never
`MOV CL,n; SHL r,CL`, because loading CL would corrupt CX which holds the saved
operand.  (8086 has no `SHL r16,imm8` — that is 186+.)

Regression tests: `TESTS/TOPT.MOD` (runtime values incl. negative dividends) and
`TESTS/MANIFEST.TSV` `opt/*` rows (assert fast opcodes present, `F7 E9`/`F7 F9`
absent).

### INC/DEC memory-destination fast path  ← codegen

`INC`/`DEC` on a variable whose address is a **fixed compile-time displacement**
no longer does the `LOAD → op → STORE` round-trip — it emits an op straight to
memory.  Logic lives in the `Syms.SpInc, Syms.SpDec` case of `PSTMT.MOD`, using
`Cgen.CgIncDecMem` / `CgAddSubMemW` / `CgAddSubMemB` / `CgAddSubMemL` (near, at
`[disp16]` in DS or `[BP+disp]` in SS) and `CgAddSubEsbxW/B/L`
(far, `[ES:BX]` with a `26h` override — there is no dedicated far INC/DEC-by-1
opcode; the far implicit-step-1 path reuses the ADD/SUB-imm helper with imm=1).

Two gates decide which fast form applies (both from the destination Item, read
**before** any `CgLoadItem`):
- `fastAddr` = `~isRef & (mode = MGlobal OR MLocal)` — plain near var.
- `refFast`  = `isRef & ~isAddrV & (mode = MGlobal OR MLocal)` — far ref (`p^`,
  far `VAR` param, far array elem) whose far pointer sits in a fixed slot; load
  ES:BX once via `CgLesBxItem`, then the `26h`-prefixed memory op.  ADDRESS-`isRef`
  is excluded (its slot value *is* the address → near path on the slot).

| Target / step | Emitted |
|---------------|---------|
| INTEGER/WORD, ±1 (near) | `INC/DEC WORD [x]` = `FF 06`/`FF 0E …` |
| BYTE/CHAR, ±1 (near) | `FE 06`/`FE 0E` |
| Any type, ±1 (far, `[ES:BX]`) | same as "const N" below with N=1 — no dedicated far INC/DEC opcode |
| INTEGER/WORD/ADDRESS, const N | `ADD/SUB [x],N` (`83 /0,/5` imm8 if fits, else `81`, far: `26`-prefixed); ADDRESS touches only the offset word (no carry into its segment) |
| BYTE/CHAR, const N | `80 /0,/5 [x], imm8` |
| LONGINT, ±1 or const N | `ADD/SUB [lo]` then `ADC/SBB [hi]` — carry-correct 32-bit |

**Not optimized (fall back to LOAD+op+STORE):** `MReg`-held refs (array element
mid-expression, ES:BX not from a fixed slot); ADDRESS-`isRef`; the `refFast`
**runtime-step** sub-case (step expression could clobber ES:BX, so it uses the
original save-across-parse path).  A `fastAddr` **runtime step** on a near var
uses a lighter no-save path (the memory var is stable across the step parse):
load step, `PUSH`, load old, `POP CX`, `ADD/SUB AX,CX` — note operands are
`AX=old, CX=step` so `SUB AX,CX` gives `old−step` (do **not** use `Cgen.CgSub`,
whose `XCHG`+`SUB` convention expects the opposite order).

**Byte cost:** `INC WORD [g]` is 4 B (+reloc) vs 5 B for load/inc/store; the win
is code-size / real cycles, invisible to Metric A (xt instruction count barely
moves — same instruction *count*, fewer bytes/cycles).

**Self-host note:** because this changes the compiler's OWN emitted code, the
standard `TESTS/test_selfhost.sh` (asserts `oc1 == oc2`) fails by one generation
— `BOOT/TOC.EXE` built oc1 *without* the optimization, so oc1's INC/DEC sites
differ from oc2's.  The correct fixpoint check is **toc2 == toc3** (both built by
an optimizing compiler); verified byte-identical.  Refresh `BOOT/TOC.EXE` from a
verified `BIN/TOC.EXE` to make `oc1 == oc2` hold again.

Regression test: `TESTS/TINCDEC.MOD` (Section 18) — runtime values across every
type/mode/step/direction combination incl. LONGINT carry and ADDRESS offset.

### CASE jump-table dispatch (G7)  ← codegen

A `CASE` with **≥ 6 single-value INTEGER/CHAR labels** and a **dense span**
(`hi−lo+1 ≤ 2×labelCount`) dispatches through an indexed jump table instead of
the default linear `CMP`/`Jcc` chain. Range labels (`a..b`) anywhere in the
`CASE`, or any label shape more complex than an optional unary minus plus an
int/char/single-char-string literal, disqualify the *whole* `CASE` from the
table path (falls back to the existing chain — never a correctness risk, only
a missed optimization).

**Why a pre-scan is required:** the compiler is single-pass with no AST, so
the dense-vs-chain decision (which needs every label's value up front) must
happen before any dispatch code is emitted, but labels are normally only
known as each arm is parsed. `PSTMT.MOD`'s `PreScanCase` walks the token
stream once via `Scan.Mark`/`Scan.Restore` (bracket save/rewind of the lexer
position — SCAN.MOD) to compute `count`/`lo`/`hi` with zero side effects
(it deliberately does NOT call `PExpr.ParseExpression`, only a narrow
`PreScanLabel` recognizer, to avoid double-interning strings or double-
allocating symbols on the real pass that follows), then rewinds and lets the
ordinary parse proceed — either building the table (`ParseCaseTable`) or
falling through unchanged to the existing chain.

**Emitted dispatch** (`ParseCaseTable`, `PSTMT.MOD`):
```
SUB  AX, lo                  ; Cgen.CgSubAxImm
CMP  AX, (hi-lo)             ; Cgen.CgCmpAxImmUnsigned
JA   default                 ; unsigned: covers BOTH below-lo (huge wrap) and above-hi
SHL  AX, 1                   ; word-index scaling
MOV  BX, AX
CS:  JMP [BX+table]          ; Cgen.CgJmpTableCs — table lives in the CODE segment,
                              ; hence the CS: override (DS points at data, not code)
table: dw <code-offset>, <code-offset>, ...   ; Cgen.CgEmitJumpTableEntry/CgPatchJumpTableEntry
```
Each table entry is a **module-local code offset with a code-to-code
relocation** (`Rdoff.RdfAddReloc(..., Rdoff.SegCode, ..., Rdoff.SegCode, ...)`
— the same mechanism `Cgen.CgLoadCodeAddr` already used for the `__init`
guard word in `PARSER.MOD`; the linker's `OnReloc` adds this module's
code-group base to whatever module-local offset is stored at the patch site).
Unclaimed slots and the `JA` target both resolve to the same address: a
`defaultJmp` backpatch, itself resolved at the very end to right before the
`ELSE` body (or to the same "fall through past the whole CASE" point the
chain path already uses when there is no `ELSE`).

**Trap already hit once — do not regress it:** the "default" landing point
MUST have an explicit unconditional jump (`CgJmpNear(defaultJmp)`) past every
arm's body. Without it, out-of-range values silently fall into whatever code
is emitted next (arm 1's body) — this was a real bug in the first
implementation, caught by `TESTS/TCASETBL.MOD`'s `TDenseNoElse`/
`TDenseWithElse` tests, not by `make test` (the 280-row manifest only checks
compile-time byte/symbol patterns, not runtime dispatch correctness).

**This dialect has no `LOOP`/`EXIT` statement at all** — `SkipArmBody`'s
first draft used `LOOP ... END` (a compile error: "undefined identifier
'LOOP'") and was rewritten as `WHILE ~done DO ... END` with an explicit
`done`/`result` flag pair. Confirmed against `DOCS/OBERON07.EBN`: neither
keyword is part of the grammar.

**Duplicate labels:** Oberon-07 requires distinct `CASE` labels, but the
existing chain path silently lets the *first* matching arm win if two arms
share a label (later compares are simply never reached). The table path
replicates this via a `claimed: ARRAY MaxTableSlots OF BOOLEAN` guard — only
the first arm to claim a slot patches it; a later arm's claim on an
already-claimed slot is a no-op.

Regression test: `TESTS/TCASETBL.MOD` (Section 18) — 7 cases covering basic
dispatch, `ELSE` handling, negative labels (stresses the subtract-then-
unsigned-compare bounds check with `lo` itself negative), `CHAR` selector,
a comma-list sharing one arm/slot, a range label forcing chain fallback, and
nested `IF`/`WHILE`/`REPEAT` inside a table-dispatched arm's body. Also
runnable standalone (bypassing `make testall`'s unrelated harness bugs):
`toc /ENTRY=RunAllTests TCASETBL.MOD` then run the resulting `.exe` directly.

**Deferred optimizations** (not implemented — higher risk / lower payoff in a
single-pass front end with no register allocation; documented so a future
contributor knows the trade-off):
- **Constant `SET` literal folding** — `{0,3,5}` is built with a runtime
  shift-OR loop; an all-constant set could fold to an immediate bitmask.  Needs
  element buffering in the single-pass SET parser.  Benefit MEDIUM (`IN {…}`).
- **Dead `XOR AH,AH` after byte load** — byte loads always zero-extend even when
  only AL is used.  Needs known-width/liveness tracking.  Benefit LOW-MED.
- **Drop `CMP`/`TEST` when flags already live** from a preceding arithmetic op.
  Needs lookahead the front end lacks.  (The unconditional `CMP AX,0`→`TEST AX,AX`
  size win is already done; only the *elimination* is deferred.)
- **FOR-limit / loop-invariant hoisting** — needs register allocation / loop
  analysis.  Benefit MEDIUM.
- **`CgSub` XCHG removal** — `SUB` emits `XCHG AX,CX; SUB AX,CX`; fixing it is an
  operand-placement convention change in `ParseSimpleExpression` (byte-diff churn
  across many tests).  Benefit LOW (2 bytes/subtract).

---

## Integer type rules  ← CRITICAL

The compiler runs as a 16-bit MS-DOS application. `INTEGER` is 16 bits.
Using `INTEGER` for anything that can exceed 32767 will silently overflow.
**Use `LONGINT` wherever a value can exceed 32767, and `WORD` for 16-bit unsigned.**

| What it represents | Oberon type |
|--------------------|-------------|
| Code/data segment offsets (0..64KB) | `WORD` |
| Data segment variable address | `WORD` |
| Code buffer PC | `WORD` |
| Backpatch offset (signed, ±32KB+) | `LONGINT` |
| BP-relative frame offset (signed) | `INTEGER` (fits ±32K) |
| Record field offset | `WORD` |
| Type/array size in bytes | `WORD` |
| RDOFF/MZ 16-bit word fields | `WORD` |
| Header build buffer sizes | `LONGINT` |
| Small counts, loop indices, flags | `INTEGER` |

**`Cgen` segment offset parameters:** All `Cgen` procedures that accept a
code-segment or data-segment offset take `WORD` parameters. Callers pass
`WORD(item.adr)` (LONGINT → low 16-bit unsigned) at call sites.

### Two-arg INC/DEC step widening bug — FIXED (2026-06-26)

`PSTMT.MOD`'s `ParseSysprocCall` (case `Syms.SpInc`/`SpDec`) widens a 16-bit
`step` value into DX:AX before adding/subtracting it from a `LONGINT` target.
It used to emit `CWD` (sign-extend AX→DX:AX) unconditionally, which is wrong
in two cases:

- **`step` is itself `LONGINT`** — `Cgen.CgLoadItem` already loaded the true
  32-bit value into DX:AX; the subsequent `CWD` re-derived DX from AX's sign
  bit alone and silently clobbered the real high word.
- **`step` is `WORD`** — unsigned 16-bit; `CWD` wrongly treats a step with bit
  15 set (e.g. 40000 = `9C40H`) as negative, producing a corrupted high word.

Symptom: `FILES.MOD`'s EMS-capacity growth loop
(`WHILE newCap < need DO INC(newCap, LONGINT(EmsChunkKB)*LONGINT(1024)) END`)
never terminated once the running `LONGINT` step computation was miscomputed,
which surfaced as `toc.exe` hanging/timing out on any compile that pushed its
own EMS-backed temp-file storage past a 64 KB EMS boundary. Root cause was
in the compiler's codegen, not in `FILES.MOD` or `EMS.MOD` (both audited and
confirmed correct).

Fix (`PSTMT.MOD`): detect the step's actual form via its type's `.form` field and choose
the widening instruction accordingly — `XOR DX,DX` (zero-extend) for `WORD`
steps, no extend at all for `LONGINT` steps (DX:AX is already correct), `CWD`
only for `INTEGER`/`BYTE` steps (both are sign-range-safe: `BYTE` loads with
`AH=0`, so `CWD` correctly yields `DX=0`). The one-argument `INC(v)`/`DEC(v)`
form is a separate code path (hardcoded `±1`, never touches `step`) and was
never affected.

Regression coverage: `TESTS/NUM.MOD` `LgTIncDecStep` (Section 17) exercises
`LONGINT` target with `LONGINT`/`WORD`(bit-15-set)/`BYTE`/`INTEGER` steps and
the 1-arg form.

---

## DOS memory model constraints  ← CRITICAL

The compiler runs as a real-mode DOS application (16-bit, large model).

*Strong rule*: Release memory, ASAP !

### Stack size and big stack frames  ← STRONG RULE (2026-07-11)

**No procedure may declare a multi-KB local array.**  A DOS tool linked
without `$M` gets the default 8192-byte stack: SP starts at 0x1FFE, so a
frame bigger than ~7 KB **wraps SP around 64 K** — the locals land at
`SS:0xE000`-ish, which is ~56 KB *above* SS, **inside the DOS heap block**.
There is no fault: the procedure happily reads/writes someone else's heap
memory.  `Files.BlockCopy`'s old 8 KB staging buffer did exactly this on
every `Tar.TarExtract` and silently corrupted StrTab/Files heap data for
months (found and fixed 2026-07-11 — see CLAUDE.md's "Self-hosting RESTORED"
changelog entry) — it surfaced only when the 2026-07 RAM arenas moved live
symbol data into the blast zone.  Rules:

- Local buffers: **≤ 512 bytes** preferred, 2 KB absolute ceiling (audit the
  whole call chain if you need even that).  Bigger scratch space goes on the
  heap (`NEW`/`DISPOSE`) or in a module global.
- Every long-running tool with deep call chains (the compiler itself) must
  declare `(*$M ...*)`; the 8192 default is only for small tools.
- The `$M` in `TOC.MOD` is load-bearing: without it the compiler runs with a
  256 KB heap max and dies (see next rule) — never remove or reorder it.

### Allocation failure is FATAL — never continue past a NIL `NEW`  ← STRONG RULE (2026-07-11)

When the heap is exhausted, `NEW(p)` yields `p = NIL`; a following
`p^.field := x` is a **NIL far write into the interrupt vector table** — no
fault under xt, just silent corruption, and the compile continues producing
garbage ("undefined identifier" cascades hundreds of lines later; found and
fixed 2026-07-11 — see CLAUDE.md's "Self-hosting RESTORED" changelog entry).
Every `NEW` on a compiler-critical path must check for NIL and latch
`LogErr.Error("out of memory (...)")` (fail-fast does the rest).
`Parser.IdListAppend` and `Syms.SymOpenScope` are the canonical examples;
StrTab/Syms-arena/Link.SymAlloc/Files already checked.  When adding any new
`NEW` site, add the check.

### Jump-range discipline: short (rel8) jumps only over FIXED emit sequences  ← STRONG RULE (2026-07-11)

`Cgen.CgCondShort`/`CgPatchShort` (rel8) may only span a **fixed, known-size**
byte sequence emitted by the same procedure (a NEG skip, a NIL guard — a few
bytes).  Any jump over a *parsed* region (an expression, a statement, an RHS)
must use `CgCondNear`/`CgJmpNear`/`CgPatchNear` (rel16): parsed regions have
unbounded size, and a >127-byte span silently wraps the rel8 **backward into
the middle of another instruction** (wild execution: hang or invalid opcode).
This exact bug in the short-circuit `&`/`OR` emitters broke self-hosting;
found and fixed 2026-07-11 (see CLAUDE.md's "Self-hosting RESTORED" changelog
entry).  `CgPatchShort` now latches a fatal
`"internal: short jump out of range"` when the displacement leaves −128..127
— if you ever see that error, the fix is to switch the call site to the near
variants, never to widen the check.

### Memory-leak discipline — ZERO tolerance  ← CRITICAL

The compiler runs many module compiles **in one process** (the all-in-one build
driver and any single-shot `oc /ENTRY=Run Root.Mod`).  A leak of even a few hundred
bytes per module compounds across a dependency tree and exhausts the DOS heap — the
symptom is a misleading `error: cannot write <Mod>.rdf` (the per-file 8 KB `Files`
buffer's `NEW` returns NIL) when compiling an import-heavy module such as `PARSER.MOD`.

Rules:
- **Every `NEW` has a matching `DISPOSE`** — either directly, or because the node is
  on a freed allocation chain.  A node that is not on a chain (a temporary list built
  during parsing — ident groups, `$L` extra-rdf list, init-import list, backpatch
  chains, the `.def` BASE-patch list) **must be freed explicitly** when its job is done.
- **Symbol table is a RAM pointer-record arena** (see §"Symbol table: RAM
  pointer-record arena" below): `Syms.SymsFree` `DISPOSE`s the arena chunks
  wholesale and frees the remaining heap-resident allocation chains —
  `allScopes` (every scope), `allInline` (every `InlineNode` chunk), `allFwd` (every
  `FwdNode` chunk).  Anything reachable only through the arena or these chains
  is released; anything else is NOT.
- **`Cgen.CgFree`** frees the `ObjFile` (reloc/import/global lists + the
  `RDFCODE.TMP`/`RDFDATA.TMP` temp files and their buffers).
- **Backpatch lists** (`PStmt.BpPatchFree`) must `DISPOSE` each node after patching.
- **Import dedup list** (`Import.ResetLoaded`) is freed at the end of each module compile.

### Single `SYSTEM.Halt` + error-return convention  ← CRITICAL

The whole compiler/linker funnels every failure to **one** `SYSTEM.Halt`, in
`OC.Run`, called **after** `OC.Cleanup`.  No module below `OC` may abort the
process: an aborting `SYSTEM.Halt` deep in RDOFF/TAR/Link/Syms/Import would skip
`Cleanup` and leak the open temp files (the module-graph temp, the symbol/type
temps, `RDFCODE.TMP`/`RDFDATA.TMP`, the linker spill).  So a fallible operation
must **report** the error through module **LogErr** (see below), never halt.  A
fallible proc reports and `RETURN`s; its caller tests `LogErr.HaveErr()` at a
boundary.  **A report that leaves an object in a state the following code would
dereference (NIL buffer, NIL symbol, unopened file) MUST be followed by
`RETURN`** — `LogErr.Error` does not stop execution by itself.

`OC.Cleanup` (FreeMods + `Cgen.CgFree` + `Syms.SymsFree`) is **idempotent** and
runs on every exit path — success or error — so no temp file or heap block
survives the process.  `OC.RunBody` returns the exit code (0/1); `OC.Run` does
`LogErr.Open; exitCode := RunBody(); Cleanup; LogErr.Close; SYSTEM.Halt(exitCode)`.

### Error handling: module LogErr  ← CRITICAL

**`SRC/LIB/LOGERR.MOD` (module `LogErr`, renamed from `LogErr` and moved from
`SRC/TOC` to `SRC/LIB` 2026-07-11 — now a stdlib module, merged into
`OBERON.OM` like `Strings`/`Files`) is the SINGLE error state and the SINGLE
place any message is printed** for the whole toolchain (compiler, linker,
olib, tools). No other module keeps its own error flag or writes diagnostics
directly.

- **One latch.** `LogErr.Error`/`LogErr.Error2`/`LogErr.ErrorInFile` set an
  internal `err` flag and print the message.  `LogErr.HaveErr()` reads it.
  There is **no reset** — the toolchain is **fail-fast**: the first error
  latches and every later message is swallowed, so the run aborts at the
  first failure.  Removed (do not reintroduce): `Rdoff.rdfErr`, `Tar.tarErr`,
  `Link.linkErr`, `PExpr.errors`, `Parser.parserErrors`, `Scan.errCount`, and
  all `VAR err: BOOLEAN` out-params.  Callers gate on `LogErr.HaveErr()`
  instead.
- **Levels + routing.** `LogErr.Error` (LERROR) → **stderr** and latches;
  `LogErr.Warn`/`Info`/`Debug` (LWARN/LINFO/LDEBUG) → **stdout**, gated by
  `LogErr.SetLevel` (default LINFO; use `/LOG=debug` etc. to widen).
  `LogErr.Error2`/`Info2`/`Warn2` take a `msg,arg` pair.  Positional
  diagnostics from the **scanner, parser and code generator** MUST use the
  `*InFile` variants (`LogErr.ErrorInFile`, `LogErr.WarnInFile`) so every line
  is `filename(line): message`.
- **Logging.** `LogErr.Open` (start of each tool's `Run`) opens `output.log`
  (every message) and `error.log` (errors only); `LogErr.Close` (end of `Run`)
  closes them. Errors go to stderr **and** both logs; warnings/info go to
  stdout **and** `output.log`.
- **No wrappers.** Do not wrap `LogErr`'s procs in per-module `Fatal`/`ErrMsg`
  helpers, and do not wrap stdlib (`IO`/`Files`/`Strings`) — call `LogErr.*`
  directly at the site.  Exception (approved): `PExpr.Error`/`Error2`/`Expect`
  and `Parser.Error` are position *injectors* (they add `sc.filename`/`sc.line`
  then call `LogErr.ErrorInFile`), not pass-throughs — keep them.  Need a new
  wrapper? Ask first.  `LogErr.Info2`/`Warn2` were added *inside* LOGERR.MOD
  (not an external wrapper).
- **Tool DATA stays on stdout.** olib's `list` member table and rdfgrep's query
  results are program output, not diagnostics — they stay on `IO`/`Out`; only
  their error/usage messages go through `LogErr`.  The manifest harness greps
  `output.log` for `stderr-contains` rows so it sees diagnostics regardless of
  stream.
- **Build graph.** `Rdoff`/`Tar`/`LogErr` all live in `SRC/LIB` now and are
  merged into `OBERON.OM` — any tool linking them (olib, rdfgrep, toc.exe
  itself, and future tools like TASM) gets them automatically via the normal
  `OBERON_LIB=...OBERON.OM` entry; no separate per-module `.OM` path is
  needed on `OBERON_LIB` any more (the old `SRC/TOC/RDOFF.OM;SRC/TOC/TAR.OM;
  SRC/TOC/ERR.OM` entries were removed from the tools Makefile).

The same one-Halt shape applies to the standalone tools: `olib` has its body in
`TOLib.RunBody(): INTEGER`, and its `Run` wraps it with the log lifecycle —
`LogErr.Open; rc := RunBody(); LogErr.Close; SYSTEM.Halt(rc)` (rdfgrep opens the
logs at the top of `Run` and closes them in its single `Halt` choke point;
testall opens at the start of `Run` and closes before every `SYSTEM.Halt`).
Every tool that uses `LogErr` MUST bracket its work with `LogErr.Open` …
`LogErr.Close`.

When adding a new failure path: return/latch it, close what you opened, and add a
`compile-fails` manifest row proving the compile exits non-zero and leaves no
`*.TMP` behind (see `import/unresolved-import-fails`).

### Leak guard — built into the compiler (keep it)

`OC.CompileModule` brackets each module compile with `SYSTEM.MemAvail()` checkpoints via
the `LeakGuard(memBefore, module, subPart)` helper.  If free heap dropped across a phase
it prints a non-fatal `oc: WARNING: heap leak compiling <module> <phase> (N paragraphs)`
to stderr.  Phases checked: after parse + `Cgen.CgFree`, and (for `/ENTRY=` roots) after
`GenEntryStub` and `RepackOm`.

This guard is **permanent infrastructure, not debug scaffolding** — it is the regression
detector for the zero-leak rule.  When adding any allocation to a compile path, build the
compiler, recompile a heavily-importing module (e.g. `TAR.MOD`, `CGEN.MOD`) and confirm the
guard reports **0 paragraphs**.  `SYSTEM.MemAvail` is exact (a free-list walk; verified
stable across repeated calls), so a non-zero delta is a real leak, not measurement noise.
The heap allocator coalesces *adjacent* freed blocks fully (SYS.ASM `SYSTEM_Free`
merges next+prev), so a clean NEW/DISPOSE pairing returns the heap to its starting
level.  Coalescing cannot merge **non-adjacent** holes, though — see the defrag note.

### Reserve the linker's big buffers up front — keep them off the fragmented arena

`oc /ENTRY=Run Root.Mod` compiles every module and then links, all in one process.
The module graph itself is **file-backed** (`OC.gModFile`, never in the heap), so it
no longer fragments the arena — after the compile phase the whole free heap is one
contiguous block (measured: `SYSTEM.MemMaxAvail` = `MemAvail` at `preLink`).

The fragmentation now comes from the **link module-scan** instead.  `Link.ProcessFile`
→ `Tar.ScanTar` → `Rdoff.ScanHeader` opens every `.rdf` member through an **8 KB
`Files` buffer**, and `Link.AddSymbol`/`NewModule` `NEW` their small records *inside*
that open-buffer window; when the 8 KB buffer frees, the small records strand the
arena.  After the scan, total free is still large but the **largest hole collapses**
(measured: 349 KB free, 8.7 KB largest).  The linker's two big buffers are a fixed
`Rdoff.SegBuf = POINTER TO ARRAY 65000 OF BYTE`, so `NEW(dataBuf)` / `NEW(g^.buf)`
each need a **65000-byte contiguous** block (the `NEW(p, sz)` size arg is *ignored*
for a fixed-array pointer) — which no longer fits → `Out of memory (data buffer)`.

**Fix — `Link.ReserveBuffers`, called at the START of `OC.LinkAll` (before any
`ProcessFile`).**  It `NEW`s **both** `ls^.dataBuf` and a single reusable
`ls^.codeBuf` while the arena is still contiguous.  `PerformLinking` then only zeroes
the used span of `dataBuf` (no `NEW`), and `ProcessGroup` **reuses `ls^.codeBuf`**
(`g^.buf := ls^.codeBuf`) instead of `NEW`/`DISPOSE` per group — groups are processed
one at a time, so one buffer serves all.  `LinkFree` frees `dataBuf` + `codeBuf` once.
Peak heap is unchanged (data + one code buffer were always the two big blocks); only
the *timing* of the two fixed 65000-byte allocations moved earlier, ahead of the
small-record scan.  Verified: current-source compiler self-links OC with no OOM and
gen2 == gen3 byte-identical.

**Second layer — chunk the linker's small records so the scan barely fragments at
all.**  The residual fragmentation source (the hundreds of tiny `NEW`s inside the
scan window) is removed by the "chunk small records" rule applied to the linker's
own tables:
- **`Symbol`** is now a **WORD index handle** (not a pointer — Oberon can't point
  into an array), addressing a chunked store `symDir[LSR(i,SymShift)]^.s[AND(i,SymMask)]`
  with `SymChunk = 128` (a power of two, so index→(chunk,slot) is shift+mask, not the
  slow `DIV`/`MOD`, since the reloc loop dereferences symbols per relocation).
  `SymRec` also caches `hashCode` (`Strings.HashCode`) so `FindSymbol` skips most
  `Util.Eq` calls.  Hundreds of per-symbol blocks collapse to a handful of chunk nodes.
- **`ImportNodeRec`** (per-module, rebuilt inside the reloc scan) and
  **`GroupNodeRec`** are likewise chunked (`ImpChunk`/`GrpChunk` = 128).
`ModRec` stays a pointer record (only dozens, and `CalculateLayout` re-splices its
linked list — index conversion there would touch the trickiest layout code for little
gain).  `NoSym` (`0FFFFH`) is the null symbol handle.  Verified: 267/0 manifest +
self-host 13/0 byte-identical + 0 leaks.

> **Reusing one shared code buffer is now correct** (an earlier attempt was reverted
> because a `SYSTEM.FILL`-zeroed buffer mis-addressed a far heap deref).  The current
> `ProcessGroup` zeroes with an **explicit indexed loop** (`WHILE k < sz DO
> g^.buf^[k] := BYTE(0)`), never `SYSTEM.FILL`, so that old failure does not apply.
>
> **Re-confirmed 2026-07-05 (opt2.md finding 8):** a perf pass proposed
> `SYSTEM.FILL` for both `ProcessGroup`'s `codeBuf` zero-fill and
> `PerformLinking`'s `dataBuf` zero-fill — both are `Rdoff.SegBuf`
> (`POINTER TO ARRAY 65000 OF BYTE`, far heap), i.e. exactly the case this
> note warns about.  **Left as the explicit indexed loop; do not convert.**
> The *other* zero-fill/padding sites fixed in that same pass
> (`LINK.MOD`'s `WriteZeros` and `ProcessGroup`'s ≤15-byte inter-group
> alignment pad) are safe to batch with `SYSTEM.FILL` because they fill a
> small **local stack** `ARRAY OF BYTE`, not a far-heap pointer — the
> mis-addressing failure is specific to `SYSTEM.FILL` on a far/heap
> destination, not to `SYSTEM.FILL` in general.

**Dead ends (reverted — do not retry blindly):**
- *Rdoff alloc-chain* (`allocNext` on `RelocNode`/`ImportNode` so `RdfFree` could
  free `SanitizeImports` orphans without mid-compile `DISPOSE`): +4 bytes/node ×
  Parser's thousands of relocs pushed `PARSER.MOD` over the heap limit
  (`cannot write Parser.rdf`).  `RDOFF.MOD` has no `allocNext`; free the orphans
  explicitly instead.
- *Mutable-record cache over `Syms.GetSym`/`GetType`* ("C1", reverted 2026-07-03,
  back when the symbol table was still file-backed and handle-addressed):
  a handle-keyed RAM cache of whole `SymbolRec`/`TypeDescRec` values corrupts
  cross-module `.def` import — write-through, clear-between-modules, AND
  invalidate-on-write all failed the same way (`unknown type in .def: Rider`).
  See the full analysis under "Symbol table: RAM pointer-record arena → DEAD
  END".  The symbol table has since moved to the RAM pointer-record arena
  described there, which sidesteps this class of bug entirely (records are
  read/written directly through the pointer — there is no separate cache to
  go stale).  If a *new* cache over the current arena is ever proposed, cache
  only **immutable** fields (`form`/`size`) in a never-invalidated side-table.

### Segment size limit — 65000 bytes maximum

**No single `ARRAY … OF BYTE` (or equivalent buffer) may exceed 65000 bytes.**
On DOS the heap lives in a single 64KB segment.

```oberon
(* WRONG — exceeds DOS segment *)
buf: ARRAY 65536 OF BYTE;

(* CORRECT *)
buf: ARRAY 65000 OF BYTE;
```

`SegLimit = 65000` — enforced in `Rdoff.RdfWrite` (a code/data segment that grew
past the limit fails the write and sets `Rdoff.rdfErr`).  The check is **not** in
`Rdoff.EmitByte`: `EmitByte` runs once per emitted byte (the hottest path in
codegen), and a segment can only overflow by growing through it, so a per-byte
`LONGINT` compare was pure overhead — `RdfWrite` validates `codeLen`/`dataLen`
once before serializing.  Do not reintroduce the per-byte limit check.

### ObjFile — heap-allocated

`ObjFile` in `RDOFF.MOD` stores large buffers via `Files.File` temporaries (heap-backed).
Call `RdfInit(obj, err)` to open temp files (`err` is set if a temp can't be
created); call `RdfFree(obj)` when done.

### Fixed arrays — use linked lists for variable-length data

For variable-length collections (symbol tables, import lists, relocation tables,
module lists), use **linked lists** with individually heap-allocated (`NEW`) nodes.
Fixed arrays are only acceptable for small, bounded counts.

### Chunk small records  ← STRONG RULE

Every heap block carries a **16-byte header**, so allocating many *tiny*
value-records one-by-one wastes memory — the header can dwarf the payload. A node
is a candidate when its payload is **small (< 32 bytes)** and it is `NEW`'d
**frequently** (patch addresses, relocations, idents, backpatches, inline-byte
runs, …). Store a **CHUNK** of N such entries per node and allocate a fresh node
only when the chunk fills.

Convert from one-entry-per-node:

```oberon
FwdNodeDesc = RECORD ofs: LONGINT; next: FwdNode END;
```

to a chunked node (parallel arrays + a count):

```oberon
FwdNodeDesc = RECORD
  ofs:   ARRAY 32 OF LONGINT;   (* the payload, one array per field *)
  count: INTEGER;              (* live entries in this chunk *)
  next:  FwdNode
END;
```

- **Append** writes `arr[count] := v; INC(count)`; allocate a new node only when
  `count >= ChunkN`.
- **Delete** compacts: shift trailing entries down (`SYSTEM.MOVE` / index copy) and
  `DEC(count)` so the arrays stay dense — never leave holes.
- **Every consumer must iterate the chunk**, not the node: walk nodes with
  `WHILE n # NIL`, and inside each node `WHILE k < n^.count` indexing `arr[k]`.
  A reader that still treats a chunked field as a scalar silently sees only garbage
  (this exact bug hit `rdfgrep`'s reloc walkers after `RelocNode` was chunked — see
  the test note below).

Applies across the **whole compiler AND linker**. Implemented chunk sizes:
`RDOFF.MOD` `RelocNode` (256/chunk, parallel `physSeg/offset/width/rseg`),
`LINK.MOD` `MZReloc` (256/chunk, one `BlockWrite` per chunk in wire order),
`FwdNode` and `InlineNode` (SYSTEM imports many inlines into *every* module, so
this is not rare). When chunking a record, grep for **all** readers of its fields
(including `SRC/TOOLS/RDFGREP.MOD`) and convert them in the same change.

### Symbol table: RAM pointer-record arena  ← current design (final form, 2026-07-05)

`Symbol` and `TypeDesc` are `POINTER TO` records (`SymbolRec`, `TypeDescRec`)
that live inside chunked, bump-allocated RAM arenas (256 records/chunk, 32
chunks each — up to 8192 symbols / 8192 types).  There is **no handle
indirection and no Get/Set copy API**: callers read and write record fields
directly through the pointer (`s.kind`, `t.form`, `t.base`, …).  `NoSym`/
`NoType` are exported `VAR`s holding `NIL`.  This design replaced an earlier
file-backed handle store (see the superseded-design note below) once
measurement showed the RAM footprint fit comfortably inside the
single-process self-host's free heap (see [opt_meas.md](../opt_meas.md)).

- **Names are not stored in records.**  `nameId`/`modId` are `StrTab` ids
  (Layer 1 interning) — name equality is `WORD` id equality, so `SymFind`/
  `SymFindLocal`/`SymFindField` compare ids directly, with no hash file and
  no `Strings.Equal` on the lookup path.  A name never interned cannot be any
  symbol's name (id `0` matches nothing).
- **Arena chunks never move**, so a `Symbol`/`TypeDesc` pointer handed out
  stays valid until `SymsFree` (which `DISPOSE`s whole chunks — zero-leak,
  no per-record heap headers, no record walking).  `NewSymRec`/`NewTypeDesc`
  fully initialise every field before the pointer escapes (the runtime does
  **not** zero `NEW`'d chunks — see §"No-zero-init" at the top of this file).
- **No accessor wrappers.**  `SYMS.MOD` used to export single-field readers
  (`FormOf`/`KindOf`/`BaseOf`/…) as a migration aid from the old handle API;
  they were pure `NIL`-guard pass-throughs once records became real pointers
  and were removed (2026-07-05) once every call site was converted to direct
  field access (`t.form` instead of `Syms.FormOf(t)`).  New code should always
  read fields directly; only guard with `# NIL`/`# Syms.NoType` /
  `# Syms.NoSym` where the pointer is not already known non-NIL.
- **Chunk-allocation failure** latches `LogErr` ("out of memory (symbol/type
  table)") and returns the last valid record so no `NIL` deref occurs before
  the compile dies at the next `LogErr` boundary — fail-fast, single `Halt` in
  `OC.Run`.
- Records reachable from a `Symbol`/`TypeDesc` that hold **heap** sub-objects
  (an `InlineNode`/`FwdNode` chunk chain) are registered on a module-global
  allocation chain (`allInline`/`allFwd`) so `SymsFree` can release them —
  the arena itself is freed wholesale by chunk, not by walking records.
- **VAR open-array name params must receive an l-value (literal->VAR pitfall).**
  A `VAR name: ARRAY OF CHAR` formal is passed as `{offset, segment, LEN}` taken
  from the actual's storage.  Passing a **string literal** (or any non-l-value)
  fabricates a bad far ref / length, and because the lookup's very next step is
  the INLINE `Strings.HashCode` / `Util.Eq` `ES:[DI]` scan over `LEN` bytes, a
  garbage `LEN` makes that scan run essentially forever — the compiler *hangs*
  rather than faults.  (This was the 2026-06-29 "infinite loop compiling a proc
  value / imported-record VAR arg" bug: `Syms.SymNew` had `VAR name` but was
  called with literals `"FLOAT"`/`"SYSTEM"`/`"$lim"`/`"$case"`.)  Two guards keep
  it from recurring: (1) cold-path helpers called with literals (e.g.
  `Syms.SymNew`) take `name` **by value**, not `VAR`; (2)
  `PExpr.CheckParamCompat` rejects a non-l-value VAR actual at compile time
  ("VAR parameter requires a variable …").  Keep `VAR name` only where every
  caller passes an l-value (the hot `SymFind*`/`TypeAddField`/`PredeclType`).

#### DEAD END — a mutable-record cache over `GetSym`/`GetType` (reverted 2026-07-03, do not retry this shape)

*(Historical: this happened while the symbol table was still file-backed and
handle-addressed, before the 2026-07-05 move to the RAM pointer-record arena
described above.  `GetSym`/`GetType`/`SetSym`/`SetType`/`symHashFile` and the
`FormOf`/`KindOf`/… accessor wrappers referenced below no longer exist — kept
for the lesson, not as a description of current code.)*

**The idea (call it "C1"):** the hottest read on the whole compiler is a
single-field probe of a file-backed record — `Syms.FormOf(t)` alone has 154
static call sites and appears **3–8× in one boolean expression** in `PExpr`.
Each one is a `Files.Seek` (32-bit `DIV`) + `BlockRead` (MOVE of the whole
54/165-byte record) + a far call, just to return one `INTEGER`.  The obvious fix
is a small RAM cache keyed by handle so repeat probes of the same handle become a
compare + copy.  **This is a genuine hot path and the motivation is sound — but a
cache that mirrors the *whole mutable record* is not the way to build it.**

**What was tried, and why each failed:**
1. **1-deep write-through** (`GetSym`/`GetType` cache the last record; `SetSym`/
   `SetType` refresh the cached copy).  Broke cross-module `.def` import:
   `unknown type in .def: Rider` / `File` / `Registers` when compiling OLIB, and
   `make` died at `tolib.exe`.
2. **Clear the cache at each module boundary** (`Syms.CacheClear` at the top of
   `Def.DefRead` and after its mid-function `Seek(0)`).  Did **not** help — the
   staleness happens *within* a single `.def` load's field-resolution loop, not
   only across modules.
3. **Invalidate-on-write** (a `Set` clears the cache instead of refreshing it, so
   the next `Get` reloads from the file — provably can't serve data older than
   the file).  **Still failed** with the same import corruption.

**The decisive evidence** (self-check probe that read the file fresh on every
cache hit and compared it to the cached copy): the cache returned a record whose
`name` was **empty** for **handle 1 = `INTEGER`** — a predeclared *universe*
symbol that is written once and never rewritten.  A read-only, single-write
symbol coming back empty rules out every write-ordering theory: the incoherence
is **not** on the write path, so neither write-through discipline nor
invalidate-on-write can close it.  The remaining suspects are the interaction of
the cache with (a) `SymFind`'s traversal of the *separate* `symHashFile` (the
scan follows `next` links from the hash file while resolving records through the
cached main file — two stores that a naive record cache lets drift apart), and/or
(b) `Files` buffer/position state exposed by the changed access pattern.  Root
cause was **not** fully isolated before reverting.

**Rule going forward:** do **not** cache whole mutable `SymbolRec`/`TypeDescRec`
values keyed by handle.  If the `FormOf`-style probe cost is revisited, cache
only **immutable** fields — a type's `form`/`size`/`align` never change after the
`AddType` that creates it — in a small RAM side-table indexed by handle,
populated once at construction and **never invalidated**.  That sidesteps the
entire write-coherence problem that sank C1.  The cheap, *safe* redundant-read
win that DID land is C2: never re-read a field you already hold in a local,
and don't walk a param/field list twice re-reading each entry (see
`Syms.TypeCalcArgSize`, which now computes each param's slot size once into a
local array).  With the current RAM pointer-record arena this is just "read
`t.form` into a local instead of writing `t.form` twice" — there is no
accessor call to avoid any more (see §"Symbol table: RAM pointer-record arena").

### `Files.File` is a value RECORD — never copy it, write through the original

`Files.File` (`SRC/LIB/FILES.MOD`) is a plain `RECORD`, not a pointer, and
`Files.WriteByte`/`ReadByte`/etc. all take `VAR F: File` to mutate its
buffered state (`bufPos`, `bufTag`, dirty flag, …). A real bug from an
`Rdoff.MOD` refactor (merging `EmitByte2/3/4` into one `emitN` helper):
`f := obj^.codeFile` (or `dataFile`) followed by `Files.WriteByte(f, ...)`
compiles cleanly but writes through the **local copy** `f`, never touching
`obj^.codeFile` — the buffered bytes are silently dropped, and the bug does
not show up as a compile error or an obvious crash (the `.rdf`/`.om` output
is just quietly truncated). Caught by `make test` before landing, but only
because the manifest's byte-pattern checks happened to notice missing
output. **Rule: when branching on which `Files.File` field to write through
(e.g. code vs. data segment), branch on the *destination of the call*, not
by assigning the record into a local first** — call
`Files.WriteByte(obj^.codeFile, b)` / `Files.WriteByte(obj^.dataFile, b)`
directly in each arm of the `IF`, never `f := obj^.codeFile; ...
Files.WriteByte(f, b)`.

### Files temp backend — one buffered path for disk AND EMS

`Files.ReWriteTemp` returns a temp file backed by EMS (`BkEms`, when an EMM
driver is present) or by a hidden delete-on-close disk file (`BkDisk`,
fallback).  The compiler's remaining file-backed machinery (the `OC` module
graph `gModFile`, the linker spill, TAR extraction — `Syms` itself is now the
RAM pointer-record arena described above, not file-backed) sits on top of it,
so its correctness is load-bearing for the whole compiler.

**STRONG RULE: there is exactly one read/write code path, and EMS rides it.**
Both backends share the same 8 KB `F.buf` and the same `BufFetch`/`BufFlush`:

- `BufFlush` writes the buffered block back — `DOSWrite` for disk,
  `EMS.CopyToEMS` for EMS.
- `BufFetch` loads the `BUFSIZE`-aligned block — `DOSRead` for disk,
  `EMS.CopyToDos` for EMS (then sets `bufSize` from `F.size` so reads past EOF
  return short, exactly as on disk).
- `BlockRead`/`BlockWrite`/`Seek`/`Truncate`/`Close` are **backend-agnostic**;
  the only EMS-specific step is `EmsEnsureCap` (grow the allocation in 64 KB
  steps) before a write, and freeing the handle on `Close`.
- `BUFSIZE` (8192) **must stay even**: EMM "move memory region" transfers only
  2-byte-aligned lengths, and moving whole `BUFSIZE` blocks makes that automatic
  — no per-record odd-tail padding, no separate staging buffer.

Do **not** reintroduce a second, parallel EMS path inside `BlockRead`/
`BlockWrite` (an ad-hoc staging buffer + per-call `EMS` moves).  That older
design diverged from the disk path under the compiler's concurrent multi-handle,
interleaved random-access usage and made a compile-under-EMS silently write no
output.  Regression test: `TESTS/TEMSTMP.MOD` (and the `EMS.MOD` history is in
the EMS/xt notes).

---

## Large memory model — codegen segment register rules  ← CRITICAL

The **compiled Oberon program** runs in large model (CS≠DS≠SS).

### Segment register values at Oberon program runtime

```
CS  = this module's code segment paragraph   (unique per module)
DS  = combined data segment                  (same for all modules; set by SYSTEM_INIT)
SS  = stack segment                          (separate from DS; set by MZ header)
```

**CS ≠ DS ≠ SS at all times.**

### Codegen rules (enforced in Parser / PExpr)

| Situation | Correct code | Wrong (small-model) code |
|-----------|-------------|--------------------------|
| VAR param — local actual | `PUSH SS; PUSH AX` | ~~`PUSH DS; PUSH AX`~~ |
| VAR param — global actual | `PUSH DS; PUSH AX` | ~~`PUSH SS; PUSH AX`~~ |
| Array elem in DS via ES:[BX] | `MOV DX,DS; MOV ES,DX` before access | ~~assume ES=DS~~ |
| SYSTEM.GET/PUT (far ADDRESS) | `MOV ES,DX; MOV BX,AX` then `ES:[BX]` | ~~`ES:[BX]` with DS offset~~ |
| SYSTEM.SEG(local) | `MOV AX, SS` | ~~`MOV AX, DS`~~ |
| SYSTEM.SEG(global) | `MOV AX, DS` | ~~`MOV AX, SS`~~ |
| FPU stack temps (fpush/fpop) | `SS:` prefix on `[BX]` where BX=SP | ~~no prefix (uses DS)~~ |

### Why locals use SS and globals use DS

- **Locals** (K_VAR at level>0, K_PARAM, K_VARPARAM) live in the stack frame (SS).
- **Globals** (K_VAR at level=0) live in the data segment (DS).

---

## Path handling

`OBERON_LIB` is split by `;` (DOS convention).  Multiple directories can be listed.
Search order: current directory → `OBERON_LIB` entries left to right.

All path buffers: 96 characters (safe for DOS 8.3 paths).
Library search order: current directory → OBERON_LIB → `-L` entries.

**Shell quoting of backslash DOS paths (build/test scripts).**  A backslash is the
shell's escape character, so an **unquoted** DOS path is silently corrupted before it
ever reaches `xt` or the compiler: `\123\DIR` → `123DIR`, `OBERON_LIB=C:\lib` → `C:lib`
(library not found → compile fails silently).  This is a shell issue, not an xt or
compiler bug.  **Always single-quote** such arguments in makefiles/scripts —
`-e 'OBERON_LIB=C:\lib'`, `-c '\path\to\dir'` — or double each backslash (`\\`).
The project's makefiles avoid the trap by using forward-slash host paths for `-c`
(`../../`, `$wd`) and single-quoting `OBERON_LIB`; keep it that way.  See
[XT.MD](XT.MD) §"Filesystem and path conventions".

---

## .def file format  ← CANONICAL

The `.def` file written by `Def` and read during import resolution.

**Write order** (guaranteed): CONST → TYPE → VAR → PROC/INLINE.
TYPE is emitted in two sub-passes: root records (no base) first, then extended records.
This ensures every named type is defined before it is referenced.

```
MODULE ModuleName
CONST  ModuleName_SymName  intValue
TYPE   ModuleName_TypeName
TYPE   ModuleName_RecName RECORD totalSize
  FIELD fieldName type offset
  ...
END
TYPE   ModuleName_DerivedName RECORD totalSize
  BASE  ModuleName_BaseName
  FIELD fieldName type offset
  ...
END
VAR    ModuleName_SymName  segId  byteOffset
PROC   ModuleName_ProcName FAR rettype
  PARAM name type
  PARAM VAR name type
END
INLINE ModuleName_ProcName rettype
  PARAM name type
  BYTES byte ...
END
```

**Type tokens** used in FIELD, PARAM, and PROC return positions:
`VOID` / `INTEGER` / `LONGINT` / `BOOLEAN` / `CHAR` / `BYTE` / `REAL` / `LONGREAL` /
`SET` / `ADDRESS` / `ARRAY` / `POINTER name`.

**RECORD size rule (CRITICAL):** `RECORD <size>` is ALWAYS emitted for every exported
record type, even if ALL fields are private (unexported).  Importers may embed the
record in another record (e.g. `f: SomeModule.Opaque`), so they need the `size` to
compute the enclosing record's layout.  Emitting a bare `TYPE M_T` with no `RECORD`
clause causes importers to collapse the field to a zero/unknown size and mislay all
subsequent fields — a silent data-corruption bug.  `Def.WriteOneType` gates per-FIELD
lines on `exported`, but the `RECORD <size> … END` wrapper is unconditional.

**PROC line format** (always used — no legacy form):
- `PROC fullname FAR rettype` or `PROC fullname NEAR rettype`
- Followed by zero or more `  PARAM [VAR] name type` lines
- Terminated by `END`
- Even procedures with **no parameters** use this format

**CONST line has no type token — the reader infers it from magnitude.**
`Def.DefWrite` writes only the decimal value (`CONST fullname intValue`); it
never carries the exporting module's declared CONST type (INTEGER/WORD/
LONGINT — recall CONST is integer-family-only, see §"CONST declarations are
integer-only" in OBERLANG.MD).  `Def.DefRead` types the imported symbol
LONGINT when the value falls outside signed INTEGER range (-32768..32767),
INTEGER otherwise.  A value in that range is always typed INTEGER on import
even if the exporter declared it WORD or LONGINT — this is a lossy but safe
default (the bit pattern is identical for all three types at that magnitude).
Without this inference, `CONST Big* = 100000` imported as INTEGER silently
truncated to 34464 at every use site with no diagnostic (found and fixed
2026-07-11).

---

## .DBG file format  ← CANONICAL (TDS/TDINFO debug-info transport)

The `MODNAME.DBG` text member written into every `.om` by `TDbg.WriteDbg`
(module `TDbg`, `SRC/TOC/TDBG.MOD`), read by the linker's `Link.DbgPass`
(`SRC/TOC/LINK.MOD`) to build the merged TDS v2.08 block appended to the
`.exe` under `/G`. Full wire-format record layouts (TDINFO_HEADER,
SYMBOL_RECORD, TYPE_RECORD, etc.): `DOCS/TD-SPEC.MD`. This section covers
only the **compiler↔linker transport grammar** and the linker-side
algorithm, neither of which lives on disk in the final `.exe`.

**Always present, even when `(*$D-*)`:** every `.om` carries a
`MODNAME.DBG` member — non-empty when the module was compiled with
`(*$D+*)` (default off), a **0-byte** file otherwise. This keeps the
archive layout uniform: the linker never special-cases a missing member.

**Grammar** (line-oriented ASCII; a `$D-` module's member is empty):

```
D 1                         ; format/version line, first line of file
M ModuleName                 ; module ident: logical name, NO extension, source case
F MODNAME.MOD                ; source filename: on-disk, uppercase 8.3, WITH .MOD
C 1234                       ; this module's code length in bytes (decimal)
T id size classt membtype name|-   ; TYPE_RECORD, module-local 1-based index (implicit — Nth T line = index N)
B info type name                   ; MEMBER_RECORD, module-local 1-based index (implicit)
S class off seg typ name           ; SYMBOL_RECORD-ish (see class table below)
L codeoffset line                  ; LINE_NUMBER_RECORD (line FIRST on the wire; here codeoffset first)
```

Number formats: `off`/`codeoffset`/`id`/`size`/`classt`/`membtype`/`typ`
are **fixed-width 4-digit uppercase hex** (a signed BP offset round-trips
through hex as its WORD bit-pattern — e.g. `-2` → `FFFE` — and is
re-widened to signed on read); `C`'s code length and `L`'s line number are
**decimal**.

**`S` line — one line, five classes via the `class` field:**

| class | meaning | `off` | `seg` | `typ` | notes |
|-------|---------|-------|-------|-------|-------|
| `P` | procedure | code offset at prologue | `C` | 0 (no FUNCTION-return typing yet) | |
| `V` | module-level VAR (exported AND non-exported) | data offset | `D` | type index | this compiler has no BSS — `seg` is always `D` |
| `Y` | TYPEDEF (named `TYPE` decl, exported AND non-exported) | 0 | `-` | type index | no code/data location |
| `A` | param/local of the most recently opened `P` | **signed** BP offset (WORD bit-pattern) | `-` | type index | not rebased at link time (frame-relative) |
| `E` | scope-end marker — **NOT a real symbol** | that procedure's own code length | `-` | 0 | closes the innermost open `P` (see nested-proc stack below); no name |

Types/members are emitted **before** symbols in the member, so the linker
can build its type/member tables in the same early pass it interns names.
`A`/`E` lines are emitted into the *same* flat, insertion-ordered stream as
`P`/`V`/`Y` (not a separate table) — a procedure's own `S A ...` lines and
its closing `S E ...` line always appear directly after that procedure's
`S P ...` line, before the next procedure's `S P ...`.

**Compiler-side collection hooks** (module `TDbg`, all gated by
`TDbg.Enabled()` i.e. `(*$D+*)`):
- Module begin: `TDbg.BeginModule`. Module end: `TDbg.SetCodeLen` then
  `TDbg.WriteDbg` (streams the member) then `TDbg.Reset` (frees all chunk
  tables — zero-leak rule).
- Line records: `PStmt.ParseStatement` entry hook, `TDbg.AddLine` (dedups
  same line / same offset).
- Procedure symbol: at prologue emission in `Parser.ParseProcDecl`,
  `TDbg.AddSym("P", "C", ...)`.
- Module VAR symbol: `Parser.ParseVarDecl`'s level-0 branch,
  `TDbg.AddSymT("V", "D", ..., TDbg.TypeIndex(t), ...)`.
- TYPEDEF symbol: `Parser.ParseTypeDecl`, module-level only (level 0 — no
  local/nested TYPE decls get one), `TDbg.AddSymT("Y", "-", 0,
  TDbg.TypeIndex(placeholder), name)`.
- Params/locals + scope-end: `Parser.ParseProcDecl`, right before
  `Syms.SymCloseScope()` — walks `Syms.TopScope^.symbols` (KParam/
  KVarParam/KVar only), calls `TDbg.AddLocalSym` per symbol then
  `TDbg.EndScope(Cgen.CgPc() - sym.codeOfs)`. Runs for **every** procedure
  regardless of nesting depth (nested procedures get their own debug info
  too — this compiler collects strictly more than real TLINK, which
  omits nested-procedure debug info entirely; that's fine, not a bug).
- Type graph: `TDbg.TypeIndex(t: Syms.TypeDesc): WORD` interns every
  distinct `TypeDesc` by **pointer identity** (chunked map, small linear
  scan) and recursively walks `elem`/`base`/`fields` — the index is
  reserved via the map **before** recursing, so self-referential POINTER
  types terminate correctly. Oberon form → TD type-id mapping is in
  `TDbg.PrimId` (INTEGER→SINT, BYTE/CHAR→UCHAR, WORD→UINT, LONGINT→SLONG,
  BOOLEAN→BOOL, REAL→FLOAT, LONGREAL→DOUBLE, SET→SET,
  POINTER/PROC→FAR(member_type=target), ARRAY→ARRAY(member_type=elem),
  RECORD→STRUCT(member_type=first MEMBER, last field gets info bit 0x80)).

**Linker-side merge** (`Link.DbgPass`, called once per module per pass from
`Link.WriteDebugInfo`):
- **Pass 1** (before the TDINFO_HEADER is written): counts every array
  (`dbgSymCnt`/`dbgLineCnt`/`dbgTypeCnt`/`dbgMembCnt`/`dbgScopeCnt`/
  `dbgLocalTotal`) and interns every name into the chunked dedup pool —
  **all header counts and the string pool size must be fully known before
  the header is written**, since nothing after it can retroactively grow
  those fields. (A real bug once: `T`/`B` names were interned only in the
  later write passes, so the pool grew *after* the header already claimed
  a smaller size — corrupted every downstream name lookup. Fix: intern
  during pass 1, same as every other line kind.)
- **Passes 2–5** stream the actual arrays: pass 2 = SYMBOL_RECORDs (also
  where SCOPE_RECORDs are *built*, see below), pass 3 = LINE_NUMBERs,
  pass 4 = TYPE_RECORDs, pass 5 = MEMBER_RECORDs. Rebasing: code offsets
  `+ GroupOfs(m)`, data offsets `+ m.dataFinalOfs`, type/member indices
  `+ Module.dbgTypeBase` / `+ Module.dbgMembBase` (running per-module
  totals captured at the start of each module's pass-1 scan). An `A`
  symbol's BP offset needs **no** rebasing (frame-relative already).
- **SCOPE_RECORD nested-procedure stack (CRITICAL):** `sym_first`/
  `sym_cnt` index into the *same* global SYMBOL_RECORD array as every
  other symbol, and `function` is the owning procedure's own 1-based
  index into that array — both are only knowable once pass 2 has actually
  written them, so scopes are built **during** pass 2, not deferred to a
  later pass. Because a nested procedure's own `P`/`A`/`E` lines appear
  **inside** its enclosing procedure's stream (between the outer `P` and
  the outer `E`), tracking "the most recently seen `P`" as a flat scalar
  is a bug: the inner proc's `P` silently clobbers the outer's tracking
  before the outer's own `E` is reached, so the outer's SCOPE_RECORD ends
  up pointing at the wrong (inner) procedure. Fix: a small fixed-depth
  stack (`dbgProcTop`/`dbgProcSym[]`/`dbgProcOfs[]`/`dbgProcLocFirst[]`/
  `dbgProcLocCnt[]`, depth 8, matching `Syms.MaxLevel`) — push on `P`, pop
  on the matching `E`; each frame tracks its own locals independently, so
  any nesting depth resolves correctly. A scope is only emitted if its
  frame collected ≥1 local/param (real TLINK never emits empty scopes).
- Every extracted `.DBG` temp is closed/deleted on all paths; every new
  chunk table is freed in `LinkFree`. No new `SYSTEM.Halt`, no stdlib
  wrappers — errors route through `LogErr`.

**Field-order gotcha (verified against real TLINK, not assumed):** the
on-disk `TYPE_RECORD` field order is `id, name, size, class_type,
member_type` and `MEMBER_RECORD` is `info, name, type` — i.e. **name comes
right after `id`/`info`, not last**. A writer that emits `id, size,
class_type, member_type, name` (name last) produces a file that *parses*
without error but decodes completely wrong names/sizes throughout — this
was a real bug, caught only by decoding the raw on-disk bytes with a
throwaway script rather than trusting either the reader's or the writer's
own self-consistent interpretation.

---

## Import resolution — .om archive only  ← CRITICAL

The compiler reads module `.def` metadata **exclusively from inside `.om` archives**.
Standalone `.def` files on disk are **never read**.

**Rationale:** a standalone `.def` is either a stale intermediate from a crash or
a zero-byte placeholder. The `.om` archive is always authoritative.

**Consequence for testing:** stubs must be created as minimal `.om` archives with
a single `FOO.DEF` member — use `rdfgrep make-stub OUT.OM MODNAME` to create one.

**Consequence for distribution:** always distribute `.om` archives, never bare `.def` files.
