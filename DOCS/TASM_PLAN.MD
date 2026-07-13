# TASM Implementation Plan

**Status:** v1 IMPLEMENTED AND PART OF THE TOOLCHAIN (both plan milestones
verified: `SYS.ASM`→`SYS.RDF` and `EMS.ASM`→`EMS.RDF` byte-identical
to the real-NASM oracles, `TESTS/test_tasm.sh` wired into `make test`).
**v2 (full 8086 instruction-set coverage) is COMPLETE.** All five batches
(1: `ROL`/`ROR`/`SAR`/`SAL`; 2: `IMUL`/`DIV`/`IDIV`; 3: full `Jcc` set;
4: no-operand opcodes + `PUSH imm` + far-direct `JMP`/`CALL`; 5: `LOCK`/
`REP*` prefix bytes) landed 2026-07-12 — see "§v2 plan: full 8086
instruction-set coverage" below for the full gap analysis and per-batch
implementation notes.
TASM is the tool of record for regenerating `SRC/LIB/SYS.RDF` and
`SRC/LIB/EMS.RDF` from their `.ASM` sources: `BOOT/TASM.EXE` (an
immutable bootstrap binary, same status as `BOOT/TOC.EXE`/`BOOT/TOLIB.EXE`)
is invoked via `cd SRC/LIB && make regen-asm`. See `DOCS/BUILD.MD` for the
full build-integration story, including why TASM can't be a hard
prerequisite of `make all` (it needs a fully-built `OBERON.OM` to run,
which itself needs `SYS.RDF`). The sections below up to "§v2 plan" are kept
as a historical record of the v1 design decisions (scope,
mnemonic/addressing-mode coverage, the five resolved open questions) —
extend TASM's mnemonic/directive coverage directly in `SRC/TASM/*.MOD`
following the same "add a table entry, not a redesign" approach the code
already uses, per the v2 plan's batching below.

**Location:** `SRC/TASM/`.
**Goal (achieved):** A self-hosted (Oberon, running under `xt`/MS-DOS) 8086
assembler that reads NASM-subset `.asm` source and writes RDOFF2 `.rdf`
object files — **no other output format**. Builds via
`cd SRC/TASM && make` (standalone, `BOOT/TOC.EXE`-seeded, same shape as
`SRC/TOC/Makefile`); the built `TASM.EXE` is invoked as `tasm file.asm`
(exactly one positional argument; output auto-named `file.RDF`) with an
optional `/LOG=level` switch matching `toc.exe`'s.

**Since this plan was written, TASM's actual scope grew beyond the
original v1 list** (added during implementation, at the maintainer's
request): `IRET`/`CLC`/`STC`/`NOP`/`INT3`/`MOVSB`/`MOVSW`/`SCASB`/`SCASW`/
`CMPSB`/`CMPSW`/`LODSB`/`LODSW`/`STOSB`/`STOSW`/`IN`/`OUT` mnemonics,
`EXTERN`/`IMPORT` (synonym) directive support for cross-module symbol
resolution via `RDFREC_IMPORT`, and a `Lex.MOD` lexeme dictionary
(mnemonic/register/directive/qualifier names resolved to integer IDs once,
dispatched via `CASE` — replacing repeated `Strings.Equal` chains, matching
`SRC/TOC/SCAN.MOD`'s own dispatch idiom). `STRUC`/`ENDSTRUC` and
`EXTERN`/`IMPORT` now have dedicated byte-diff regression fixtures
(`TESTS/FIX/TSTRUC.ASM`/`TEXTERN.ASM`, see "Testing strategy" below).

## Why this is smaller than it looks

`SRC/LIB/RDOFF.MOD` (`Rdoff` module — moved from `SRC/TOC` and merged into
`OBERON.OM` 2026-07-11) already implements the **entire RDOFF2
object-file writer** that `toc.exe`'s own code generator uses — `RdfInit`,
`EmitByte`/`EmitByte2`/`EmitByte3`/`EmitWord`/`EmitBlock`/`EmitZero`,
`PatchCodeByte`/`PeekCodeByte`/`PeekDataByte` (backpatching), `RdfAddImport`,
`RdfAddGlobal`, `RdfAddReloc`, `RdfAddSegReloc`, `RdfSetBss`, `RdfWriteTo`.
Every `SRC/TOOLS/*.MOD` tool (`RDFGREP`, `TOLIB`, `TDINFO`, `TOSTRIP`) already
imports `Rdoff` — now via the plain `OBERON.OM` merge, no special
`OBERON_LIB` entry needed — same pattern `TASM.MOD` uses.

**TASM does not touch RDOFF2 encoding at all.** It is purely a front end:
tokenize assembly text → parse instructions/directives → encode each
instruction into bytes → call `Rdoff.EmitByte*` to write those bytes →
call `Rdoff.RdfAddReloc`/`RdfAddSegReloc` wherever an operand references an
external or forward-declared symbol → call `Rdoff.RdfWriteTo` at EOF.

This mirrors `SRC/TOC`'s own architecture (`Scan → Parser/PExpr/PStmt → Cgen
→ Rdoff`) almost exactly, just for assembly instead of Oberon-07.

**Error handling and memory hygiene reuse the same two mechanisms every
other tool in this repo uses — TASM does not invent its own:**

- **Module `LogErr`** (`SRC/LIB/LOGERR.MOD` — moved from `SRC/TOC/ERR.MOD` and
  renamed from `Err`, 2026-07-11, merged into `OBERON.OM`) is the single
  error/diagnostic sink, same as `toc.exe`, `rdfgrep.exe`, `tolib.exe`,
  `tdinfo.exe`, `tostrip.exe`.
  All TASM diagnostics (bad mnemonic, unresolved short-jump distance, syntax
  error, unknown directive, etc.) go through `LogErr.Error`/`LogErr.ErrorInFile`
  (positional, so a message carries `file.asm(line):` — exactly the
  `*InFile` variant `Parser.MOD`/`Scan.MOD` use for compiler diagnostics),
  never a raw `Out.String`/ad-hoc print. `TASM.MOD`'s `Run` calls `LogErr.Open`
  first and the single `Halt` wrapper calls `LogErr.Close` before
  `SYSTEM.Halt` — the exact `RDFGREP.MOD` shape (`PROCEDURE Halt(code:
  INTEGER); BEGIN LogErr.Close; SYSTEM.Halt(BYTE(code)) END`). **`SYSTEM.Halt`
  is called from exactly one place** (that `Halt` wrapper), per the
  project's strong rule — no module below `TASM.MOD`'s entry point aborts
  the process directly; a fallible procedure reports failure by calling
  `LogErr.Error`/`LogErr.ErrorInFile` and returning a `BOOLEAN`/latched-state
  signal, and the caller checks `LogErr.HaveErr()` to decide whether to keep
  going or unwind to `Halt`.
- **The `LeakGuard` technique** (`TOC.MOD`'s private `LeakGuard(memBefore,
  module, subPart)` helper) is duplicated as TASM's own private helper of
  the same shape: snapshot `SYSTEM.MemAvail()` before a phase (assembling
  one `.asm` file, or a well-defined sub-phase like "after Pass 1" /
  "after Pass 2"), and after the phase compare — if free memory shrank,
  report it via `LogErr.Debug` (gated on `LogErr.IsDebug()`, so it's silent
  unless the caller passed `/LOG=debug`). `TASM.MOD`'s `Run` wraps the
  whole assemble-one-file operation in a `LeakGuard` window, and
  `TPARSE.MOD`'s two-pass driver adds an inner window around each pass, so
  a leak can be localized to "Pass 1" vs "Pass 2" the same way `TOC.MOD`
  localizes a leak to "in init" vs "in Cgen.CgFree()" vs "in
  GenEntryStub". This is copy-the-pattern, not import-a-module — `LeakGuard`
  is private to `TOC.MOD` today (not exported), so TASM gets its own
  private copy of the same ~15-line helper, matching how the pattern is
  already duplicated rather than shared.

## Scope: NASM subset actually used in this repo

Per the maintainer's explicit choice: **match exactly what `SRC/LIB/SYS.ASM`
and `SRC/LIB/EMS.ASM` use — nothing broader.** These are the only two
`.ASM` files that exist (or will exist) in the tree, and each already has a
checked-in `.RDF` (`SYS.RDF`, `EMS.RDF`) built by a real external NASM —
**these are the acceptance-test oracles** (see §Verification).

Extracted vocabulary (exhaustive, from actual `grep` over both files):

**Directives:**
`BITS 16`, `CPU 8086`, `SECTION .text` / `SECTION .data`, `GLOBAL sym[,
sym...]`, `STRUC name` / `.field RESB/RESW/RESD n` / `ENDSTRUC`
(computes `name_size` and per-field offset constants), `%DEFINE
name value`, `%UNDEF name`, `%IFDEF name` / `%ELSE` / `%ENDIF`, label
definitions (`name:`), `DB`/`DW`/`TIMES n DB/DW value`.

**Addressing forms:** register-direct, immediate, `[reg]`, `[reg+disp]`,
`[reg+reg+disp]` (BX+SI etc. — 8086 base+index forms), segment overrides
`SEG:[...]` for `CS:`/`DS:`/`ES:`/`SS:`, and the bare `mem` label form
(`MOV AX, [i87]` style — resolves to a `[disp16]` direct-address encoding,
data-segment relative, needing a RELOC record since the final linked address
isn't known until link time).

**Instructions actually used** (~35 mnemonics — the exhaustive list from the
grep above): `MOV, PUSH, POP, LEA, LES, XCHG, ADD, SUB, ADC, SBB, AND, OR,
XOR, NOT, NEG, CMP, TEST, INC, DEC, MUL, SHL, SHR, RCL, RCR, JMP, CALL,
RET/RETN/RETF, INT, LOOP, CLI, STI, PUSHF, POPF, CLD` — this is a genuine
subset of 8086 (no 286+, no FPU beyond the handful of `FNINIT`/`FSTCW`/`FWAIT`
opcodes SYS.ASM hand-encodes as raw bytes already, so TASM doesn't even need
FPU mnemonic support for the current files — confirm this holds before
cutting FPU support entirely, see §Open questions).

**Added beyond the v1 list above, at the maintainer's request during/after
implementation** (not needed by SYS.ASM/EMS.ASM, but part of TASM's
mnemonic vocabulary as of this writing): `IRET, CLC, STC, NOP, INT3,
MOVSB, MOVSW, CMPSB, CMPSW, SCASB, SCASW, LODSB, LODSW, STOSB, STOSW, IN,
OUT`. Plus the `EXTERN`/`IMPORT` (synonym) directive, for cross-module
symbol resolution via `RDFREC_IMPORT` — not used by either oracle file
(both are freestanding, no external symbols), covered instead by
`TESTS/FIX/TEXTERN.ASM`.

**Explicitly OUT of scope for v1** (no current `.ASM` file needs them):
macros (`%macro`/`%endmacro`), `%include`, `struc` nesting, `group`/`class`
segment attributes, 32-bit (`bits 32`) or protected-mode addressing, any
286+/287+ instruction, `org`, multiple `section .data` re-entries with
different names, external linker scripts. If a future `.ASM` file needs one
of these, extend TASM then — do not speculatively build it now (matches
project's "Simplicity First" rule).

## Module breakdown (mirrors SRC/TOC's Scan/Parser/Cgen split)

```
SRC/TASM/
  SCAN.MOD     Tokenizer: identifiers, numbers (dec/hex 0x../0..h/binary),
               strings, registers, mnemonics, directives, punctuation,
               line comments (;), block state for %ifdef skip-regions.
  SYM.MOD      Symbol table: labels (code/data-relative), STRUC field
               offsets, %define macros (text-substitution only — no
               parameterized macros). Two-pass friendly: a symbol can be
               referenced before its defining label is scanned (forward
               ref) — this is why Rdoff's PatchCodeByte/PeekCodeByte exist.
  ENC.MOD      x86 instruction encoder: (mnemonic, operand list) -> byte
               sequence + relocation info. This is the biggest module by
               far (analogous to CGEN.MOD). Structure as a mnemonic-keyed
               dispatch table (not a flat IF/ELSIF chain) with shared
               ModRM/addressing-mode and immediate-size-selection helpers —
               full 8086 coverage is a stated future goal (see below), so
               v1's ~35 mnemonics should be table entries that are easy to
               add to, not a design that needs restructuring later.
  DIR.MOD      Directive handling: BITS/CPU/SECTION/GLOBAL/STRUC/ENDSTRUC/
               %DEFINE/%UNDEF/%IFDEF/%ELSE/%ENDIF/DB/DW/TIMES.
  PARSE.MOD    Top-level driver: one line at a time, dispatch to TDIR (if
               a directive) or TENC (if an instruction), handle label
               definitions, drive the two-pass forward-reference fixup.
               Wraps each pass in its own private LeakGuard window (copy of
               TOC.MOD's helper) so a leak is localized to "Pass 1" vs
               "Pass 2"; every fallible step reports via LogErr.Error /
               LogErr.ErrorInFile and the caller checks LogErr.HaveErr() rather
               than aborting directly.
  TASM.MOD     Entry point (RunBody pattern, single Halt) — CLI arg
               parsing, open .asm, drive TPARSE, call Rdoff.RdfInit /
               RdfWriteTo, write the .rdf. Mirrors SRC/TOOLS/*.MOD's
               RunBody/LogErr-routed-diagnostics shape exactly: LogErr.Open first
               in Run, a single Halt(code) wrapper that calls LogErr.Close
               then SYSTEM.Halt (the only SYSTEM.Halt call site in TASM),
               and its own outer LeakGuard window around the whole
               assemble-one-file operation.
  Makefile     Same shape as SRC/TOOLS/Makefile: builds via BIN/TOC.EXE,
               OBERON_LIB = BIN/OBERON.OM only — Rdoff/LogErr are stdlib
               modules merged into OBERON.OM (SRC/LIB, moved 2026-07-11), so
               no separate .OM path entries are needed (simpler than the
               original SRC/TOC/RDOFF.OM;TAR.OM;ERR.OM form the other
               SRC/TOOLS/*.MOD tools needed before that move).
```

Rough size estimate (calibrated against `SRC/TOC/SCAN.MOD` 671 lines,
`CGEN.MOD` 1510 lines, `LINK.MOD` 1657 lines — comparable complexity
tiers): `SCAN` ~300-400, `SYM` ~200-300, `ENC` ~1200-1800 (the encoder
is the real work — one shape per mnemonic × addressing-mode combination),
`DIR` ~300-400, `PARSE` ~400-600, `TASM` ~150-250. **Total estimate:
~2600-3800 lines** — comparable to `PARSER.MOD` + `CGEN.MOD` combined,
which is a realistic multi-session undertaking, not a quick add.

## The encoding problem in detail (TENC.MOD)

This is where the real design work is. For each mnemonic, TASM must:

1. Parse the operand list (0-3 operands depending on mnemonic) into a
   normalized form: `{kind: REG|MEM|IMM|REL, size: BYTE|WORD, ...}`.
2. Select the correct opcode + ModRM byte (or the compact register-encoded
   forms like `B8+r` for `MOV reg,imm16`) per the 8086 instruction table.
3. Compute displacement/immediate encoding size (8086 addressing modes are
   a fixed, small table — `[BX+SI]`, `[BX+DI]`, `[BP+SI]`, `[BP+DI]`, `[SI]`,
   `[DI]`, `[disp16]`, `[BX]` for Mod=00, plus Mod=01/10 disp8/disp16 forms,
   plus Mod=11 register-direct — NO SIB byte, NO 32-bit addressing modes,
   since this is 8086 only).
4. If an operand is a **forward or external symbol** (a label not yet
   defined, or a name in `GLOBAL`/imported elsewhere), emit a placeholder
   value (0, or the pre-calculated negative addend for PC-relative forms
   per `DOCS/RDOFF2.MD` §3.3) and call `Rdoff.RdfAddReloc`/`RdfAddSegReloc`
   with the right `physSeg`/`offset`/`width`/`rseg`/`relative` — TASM never
   patches the actual target address itself; that's the *linker's* job,
   which `toc.exe`'s `Link` module already does correctly for the RELOC
   records TASM writes.
5. For a **backward** (already-defined, same-module) symbol reference where
   the final displacement IS known at assembly time (e.g. a `JMP short`
   within the same code segment), TASM computes the real displacement
   directly — no RELOC record needed, exactly like `Cgen.CgCondShort` in
   the compiler's own codegen does for known-target jumps.

**Two-pass structure is required** (same reasoning `Parser.MOD`'s forward-decl
handling and `LINK.MOD`'s two-phase compile-then-link split already use in
this codebase): Pass 1 walks the source, assigns every label a
code/data-relative offset (sizes are computable without knowing final
values, since every instruction's ENCODED LENGTH is determined by its
mnemonic + operand kinds, independent of the actual displacement value —
**caveat:** NASM's real behavior picks short-vs-near jump encoding based on
the actual displacement, which creates a chicken-and-egg sizing problem;
see §Open questions for how to resolve this cleanly). Pass 2 re-walks and
emits real bytes, now that every label's final offset is known, using
`Rdoff.PatchCodeByte` for same-module backward-reference patches computed
in pass 1 but written in pass 2, or a live two-pass alternates like
`Parser.MOD`'s existing `FwdRef`/backpatch-chain machinery for forward
same-module jumps.

## Testing strategy (implemented)

Per the maintainer's choice: **byte-diff against the checked-in oracles.**
`TESTS/test_tasm.sh` implements this and is wired into `make test`:

1. Builds `TASM.exe` fresh via `BOOT/TOC.EXE`.
2. Assembles `SRC/LIB/SYS.ASM` and byte-diffs the result (`cmp`) against
   the checked-in `SRC/LIB/SYS.RDF` — **PASS: byte-identical.**
3. Same for `EMS.ASM` → `EMS.RDF` — **PASS: byte-identical.**
4. `SRC/LIB/Makefile`'s `regen-asm` target uses `BOOT/TASM.EXE` (the
   verified bootstrap binary) to regenerate the checked-in `.RDF` files
   in place — see `DOCS/BUILD.MD`. The checked-in `.RDF`s are TASM's own
   output now, not NASM's; `test_tasm.sh` keeps them honest against
   TASM re-deriving itself, generation over generation.
5. **Done:** small `.asm` fixtures under `TESTS/FIX/`, wired into
   `test_tasm.sh`, for constructs the two real files alone don't reach:
   - `TSTRUC.ASM`/`TSTRUC.RDF` — `STRUC`/`ENDSTRUC` field-offset
     arithmetic (`.field` access via `NAME.field`) and the computed
     `NAME_size` bare-identifier constant.
   - `TEXTERN.ASM`/`TEXTERN.RDF` — `EXTERN`/`IMPORT` cross-module symbol
     resolution: `CALL`/`MOV reg,label` (RDFREC_RELOC against an import
     ID) and `SEG label` (RDFREC_SEGRELOC against an import ID).

   Unlike the SYS.ASM/EMS.ASM oracles (independently produced by real
   NASM), these fixtures have no independent oracle — the expected `.RDF`
   is TASM's own previously-verified output, so they're a regression
   guard (catches TASM changing its own behavior) rather than an
   independent correctness proof. Re-derive the expected `.RDF` by
   hand-inspecting the output whenever a fixture's `.ASM` changes.

   **Still not covered:** `%IFDEF`/`%ELSE` branch skipping, `TIMES n DB 0`
   zero-fill, and the string-op/`IN`/`OUT` mnemonics (`MOVSB`/`STOSB`/etc.
   — neither oracle file uses them). Add fixtures as needed.
6. **Zero heap leaks — same KEY RULE as the rest of the toolchain.** Every
   assemble-one-file run must report 0 leaked paragraphs via TASM's own
   `LeakGuard` windows (gated on `/LOG=debug` to actually print). Before
   landing any change to TASM's alloc/free paths (symbol table nodes,
   macro-substitution buffers, the two-pass label table), run a real
   `.asm` through `tasm.exe` with `/LOG=debug` and confirm no `LeakGuard`
   line appears — exactly the discipline `CLAUDE.md` already requires for
   `TOC.MOD`'s Cgen/Syms/Parser/Link/Rdoff/Import paths. **Not yet
   independently re-verified after the post-milestone feature additions**
   (EXTERN, new mnemonics, Lex.MOD) — worth a dedicated `/LOG=debug` pass.

## Resolved design decisions

All five open questions were investigated with concrete evidence (source
inspection + an actual NASM run to confirm real-world behavior) before
coding starts, per maintainer instruction. Decisions below are final for v1.

1. **Short-vs-near jump sizing — RESOLVED: require explicit `SHORT`/`NEAR`.**
   Verified empirically (`nasm -f bin` on a synthetic test) that NASM's bare
   `jmp label` genuinely does distance-dependent auto-sizing: a 5-byte-away
   target encodes as `EB` (2-byte short), a 200-byte-away target encodes as
   `E9` (3-byte near) — confirming the classical iterative-fixpoint sizing
   problem is real in general NASM, not a hypothetical. However, an
   exhaustive line-by-line audit of every `jmp`/`Jcc`/`loop` in both
   `SYS.ASM` (54 jump sites) and `EMS.ASM` (56 jump sites) found **every
   target is a same-routine local label within a few dozen source lines** —
   no ambiguous case exists in either file today, and the largest routine
   (`SYSTEM_Free`, ~116 source lines) is comfortably under the rel8 ±127-byte
   range even accounting for multi-byte instructions.
   **Decision:** TASM v1 requires unqualified `jmp`/`Jcc` targets to resolve
   to a fixed-size encoding without iteration — i.e. TASM computes each
   label's offset in a single forward pass assuming the *shortest* encoding
   (rel8) for every branch, then a validation pass confirms every actual
   displacement still fits in rel8; if any doesn't, TASM emits a fatal error
   asking the user to widen the source (restructure, or once implemented,
   use an explicit `NEAR`-forcing prefix). This matches both real files
   exactly (verified by inspection) and avoids implementing NASM's
   full iterative multi-pass sizing algorithm. If a future `.ASM` file needs
   a genuine long-range branch, extend TASM then with either an explicit
   qualifier syntax or real iterative sizing — do not build it speculatively
   now (Simplicity First).
2. **FPU instructions — RESOLVED: excluded entirely from v1.** Confirmed via
   `SRC/LIB/MATH.MOD`'s own header comment: "8087-based math primitives,
   implemented as INLINE byte patterns" — i.e. ALL FPU code in this repo
   lives as raw `INLINE(...)` byte sequences directly inside `.MOD` files,
   never in a `.ASM` file. `SYS.ASM`'s three FPU opcodes
   (`FNINIT`/`FSTCW`/`FWAIT`) are the only FPU mnemonics in any current
   `.ASM` source. **Decision:** TENC.MOD supports exactly those three FPU
   mnemonics (trivial, no-operand encodings) and no others; general FPU
   operand/addressing support is out of scope until a real `.ASM` file needs
   it.
3. **`%define`/`%undef` scope — RESOLVED: whole-token substitution only.**
   Enumerated every `%define`/`%undef` in both files (78 occurrences) by
   hand: 100% are either a bare constant (`%define RSIZE 4`), a mnemonic
   alias (`%define RETMACRO retf`), or a bracketed memory-operand expression
   (`%define arg_seg [ss:bp+RSIZE+4]`) — never a parameterized
   `%define NAME(params) ...` form, and `%macro`/`%endmacro` never appear
   anywhere. **Decision:** `TSYM.MOD`'s macro table is a simple
   name→token-list substitution map (no parameters, no multi-line macro
   bodies) — confirmed sufficient for both real files, matches the original
   scope call exactly.
4. **RDOFF2 MODNAME record — RESOLVED: omit it.** Confirmed by reading
   `Rdoff.MOD`'s own `CONST` block: the record-type constants are
   `RecReloc=1, RecImport=2, RecGlobal=3, RecBss=5, RecSegreloc=6` — **there
   is no `RecModname` constant at all**, and `RdfWriteTo` (the only writer
   procedure) never emits record type 8. **Decision:** TASM never emits a
   MODNAME record either, for exact consistency with what the existing
   linker reads and writes.
5. **CLI conventions — RESOLVED: DOS-style `/SWITCH` form.** Matches every
   other tool in this repo (`toc.exe /ENTRY=`, `/SYSTEM`, `/M`, `/LOG=`;
   `tolib.exe`; `rdfgrep.exe`) rather than NASM's Unix-style `-f rdf -o
   file` flags. **Decision:** `tasm.exe file.asm` (output name auto-derived
   from the input basename with a `.RDF` extension, uppercase 8.3, matching
   `toc.exe`'s own auto-naming convention) with an optional `/OUT=file.rdf`
   override. This is an intentional, documented deviation from real NASM's
   CLI, chosen for consistency with the rest of this toolchain.

## Forward-looking note: full 8086 support is a stated future goal

The maintainer has confirmed that **full 8086 instruction-set coverage is
planned for TASM eventually** — the "NASM subset actually used in
SYS.ASM/EMS.ASM" scope above is the *v1 starting point*, not a permanent
ceiling. This affects how v1 should be built: prefer designs in `TENC.MOD`
that generalize cleanly (e.g. a real opcode/addressing-mode dispatch table
keyed by mnemonic string, not a giant flat `IF/ELSIF` chain hardcoded to
exactly 35 mnemonics) so that widening coverage later is a matter of adding
table entries, not restructuring the encoder. Do not, however, pre-build
support for instructions/addressing modes that have zero current test
coverage (no `.ASM` file to validate against) — per Simplicity First, extend
opcode-by-opcode as real `.ASM` files demand them, but keep the *scaffolding*
(dispatch structure, ModRM/addressing-mode helpers, immediate-size selection
logic) written in a way that naturally scales to the full instruction set
rather than needing a rewrite.

## Suggested implementation order

1. `SCAN.MOD` — tokenizer. Testable standalone (dump token stream for a
   `.asm` file, eyeball against expected).
2. `SYM.MOD` — symbol table + `%define` substitution. Testable standalone.
3. `ENC.MOD` starting with the ~15 mnemonics that need NO memory operand
   (register-only forms: `PUSH reg`, `POP reg`, `INC reg`, register-to-
   register `MOV`/`ADD`/etc., `INT imm8`, `RET`/`RETN`/`RETF` with/without
   imm16, `CLD`/`CLI`/`STI`/`PUSHF`/`POPF`) — these have no addressing-mode
   or relocation complexity, good first slice to validate the Rdoff
   integration end-to-end on a tiny hand-written `.asm`.
4. Extend `ENC.MOD` with `[BP+n]`/`[ES:reg+n]`/direct-`[label]` addressing
   modes and the RELOC/SEGRELOC emission path — validate against a
   hand-written `.asm` with one forward reference.
5. `DIR.MOD` — directives, starting with `BITS`/`CPU`/`SECTION`/`GLOBAL`
   (needed by both real files), then `STRUC`/`ENDSTRUC`, then `%DEFINE`
   family last (needed for stack-offset aliasing, used heavily but is pure
   text substitution — mechanically simple once the tokenizer feeds it
   raw tokens).
6. `PARSE.MOD` + `TASM.MOD` — wire it all together, get a real end-to-end
   run on a minimal hand-written `.asm`.
7. **Milestone: byte-diff SYS.ASM → SYS.RDF.** This is the first real
   correctness signal. Expect several iterations here — SYS.ASM exercises
   nearly the full mnemonic/addressing-mode/directive set in one file.
8. **Milestone: byte-diff EMS.ASM → EMS.RDF.** Exercises `struc`,
   `%ifdef`/`%else`, `times`, `db`/`dw` data directives more thoroughly than
   SYS.ASM does.
9. Add the `TESTS/test_tasm.sh` regression script + wire into `make test`.
10. Write small isolated `.asm` fixtures for directive/addressing-mode edge
    cases not exercised by the two real files, for durable regression
    coverage independent of SYS.ASM/EMS.ASM ever changing.

## v2 plan: full 8086 instruction-set coverage

**Status: COMPLETE (all five batches landed 2026-07-12).** Requested by
the maintainer as the next TASM milestone, superseding the "extend as
needed" posture of the sections above. This section is the concrete gap
analysis and per-batch implementation record — kept as a historical record
now that every batch has landed, the same way §"Resolved design decisions"
above documents the v1 milestone's own final design.

### Final coverage (confirmed by reading `SRC/TASM/LEX.MOD` post-batch-5)

91 mnemonic IDs (`Lex.MMov*=50` .. `Lex.MDas*=153`, plus six LOCK/REP*
prefix pseudo-mnemonics at 160..169): the original ~35-mnemonic v1 list,
the post-milestone additions (`IRET`, `CLC`/`STC`/`NOP`/`INT3`, the six
string ops, `IN`/`OUT`), `IMUL`/`DIV`/`IDIV` (batch 2), `ROL`/`ROR`/`SAR`/
`SAL` (batch 1), the 14 signed-comparison/overflow/parity `Jcc` variants
(batch 3), `CBW`/`CWD`/`HLT`/`INTO`/`XLAT`/`AAA`/`AAS`/`AAM`/`AAD`/`DAA`/
`DAS`/`PUSH imm`/far-direct `JMP`/`CALL` (batch 4), and the `LOCK`/`REP*`
prefix mechanism (batch 5). This covers the full base 8086 instruction set
within this project's stated scope (see "Explicitly still out of scope"
below for what's deliberately excluded — 32-bit/protected-mode forms,
286+/187+ instructions beyond the maintainer-approved `PUSH imm8`
exception, `IMUL`'s multi-operand forms, and macros beyond `%define`).

### Architecture verdict: no rewrite needed

`ENC.MOD` already dispatches via `CASE mnemId OF` (not an `IF/ELSIF` chain)
keyed on `Lex.M*` IDs, and ModRM/displacement/immediate encoding is
centrally factored behind three reusable helpers already used by every
existing instruction: `EmitModRm(regField, VAR mem: Operand)`, `EmitDisp16`
(handles label/reloc/external-import resolution, shared by ModRm disp16 and
word immediates), and `EmitImm(VAR imm: Operand; wide: BOOLEAN)`. Grouped
opcodes already exist as parameterized shared encoders — `EncAlu(base, ext,
...)` for the eight ALU ops, `EncShift(ext, ...)` for SHL/SHR/RCL/RCR,
`EncUnaryGroup(ext, ...)` for NOT/NEG/MUL — so most of the gap below is
**a new `ext` value or a new `CASE` arm reusing an existing helper, not new
addressing-mode machinery.** The 8086 ModRM Mod=00/R/M=110 direct-address
special case and the `[BP]`-disp0-forced-to-Mod=01 case are already
correctly handled in `EmitModRm`; segment-override prefixes are already
emitted uniformly for all instructions via a pre-scan loop in `Encode*`
before mnemonic dispatch. **Two genuinely new mechanisms are needed** (see
Batch 5 below); everything else is table/arm additions.

### Gap, batched by implementation risk (mirrors the "add a table entry, not
a redesign" approach already used for the post-v1 mnemonic additions)

1. **Shift/rotate group completion — DONE (2026-07-12).** `ROL` (ext=0),
   `ROR` (ext=1), `SAR` (ext=7) — same D0/D1/D2/D3 opcode group
   SHL/SHR/RCL/RCR already use, added as new `Lex.M*` IDs (`MRol=125`,
   `MRor=126`, `MSar=127`, `MSal=128`) routed through the existing
   `EncShift(ext, ...)` — zero new encoder code. `SAL` is a pure
   assembler-level alias for `SHL` (same opcode, ext=4), mapped to the
   same `EncShift(4,...)` call. No real-NASM oracle available (same local
   `nasm` limitation as batch 2), so the regression fixture
   (`TESTS/FIX/TSHIFT.ASM`/`.RDF`, covering all four mnemonics × byte/word
   × mem/reg/CL-count operand forms) was hand-verified byte-for-byte
   against the 8086 D0-D3 opcode table, then adopted as the baseline.
   Wired into `TESTS/test_tasm.sh`. Verified via `make test` (280/280
   manifest, `test_tasm.sh` 6/6) after landing.
2. **Multiply/divide group completion — DONE (2026-07-12).** `IMUL`
   (1-operand F6/F7 ext=5 form only — the 2-operand/3-operand 186+ forms
   stay out of scope, this is 8086-only), `DIV` (ext=6), `IDIV` (ext=7)
   added as new `Lex.M*` IDs (`MImul=122`, `MDiv=123`, `MIdiv=124`) routed
   through the existing `EncUnaryGroup(ext, ...)` — zero new encoder code,
   confirming the "trivial, reuse `EncUnaryGroup`" estimate exactly. No
   real-NASM oracle available (the local `nasm` build lacks the `rdf`
   output backend), so the regression fixture
   (`TESTS/FIX/TMULDIV.ASM`/`.RDF`, covering all three mnemonics × byte/
   word × mem/reg operand forms) was hand-verified byte-for-byte against
   the 8086 F6/F7 opcode table instead, then adopted as the baseline —
   same fallback `TSTRUC`/`TEXTERN` already used. Wired into
   `TESTS/test_tasm.sh`. Verified via `make test` (280/280 manifest,
   `test_tasm.sh` 5/5) after landing.
3. **Full `Jcc` set — DONE (2026-07-12).** `JG`/`JNLE`, `JGE`/`JNL`,
   `JL`/`JNGE`, `JLE`/`JNG` (signed comparison), `JO`, `JNO` (overflow),
   `JP`/`JPE`, `JNP`/`JPO` (parity) — 14 new `Lex.M*` IDs (`MJo=129` ..
   `MJnle=142`) routed through the existing `EncJmpShort(opcode, ops[0])`
   — zero new sizing logic, the short-vs-near resolved-design-decision in
   §"Resolved design decisions" #1 already covered these uniformly (each
   condition's rel8 opcode is `70H+cc`, mirrored exactly from the existing
   `MJe`/`MJne`/etc. arms). No real-NASM oracle available (same local
   `nasm` limitation as batches 1-2), so the regression fixture
   (`TESTS/FIX/TJCC2.ASM`/`.RDF`, all 14 mnemonics as backward branches to
   a single label) was hand-verified byte-for-byte against the 8086
   70H-7FH Jcc opcode map and rel8 displacement arithmetic, then adopted
   as the baseline. Wired into `TESTS/test_tasm.sh`. Verified via
   `make test` (280/280 manifest, `test_tasm.sh` 7/7) after landing.
   `JCXZ` stays explicitly excluded per this project's own "no
   JCXZ/LOOP" strong rule (real 8086 hardware cost, not a coverage gap) —
   `LOOP` itself is already implemented as an exception predating that
   rule and is not being removed.
4. **No-operand single/double-byte opcodes — DONE (2026-07-12).** `CBW`
   (98H), `CWD` (99H), `HLT` (F4H), `INTO` (CEH), `XLAT` (D7H),
   `AAA`/`AAS`/`DAA`/`DAS` (37H/3FH/27H/2FH, single-byte) and `AAM`/`AAD`
   (D4H/D5H, each followed by an implicit 0AH operand byte) — all new
   `Lex.M*` IDs routed through the existing `EncNoOperand` (or, for
   AAM/AAD, two raw `B()` calls), no ModRM. `PUSH imm16` (68H, genuine
   8086) and `PUSH imm8` (6AH — technically an 80186+ opcode, included
   anyway per maintainer decision despite being outside this project's
   stated pure-8086 scope) both added via a new `EncPushImm` procedure,
   dispatched from a new `OKImm` branch in `MPush`'s arm (size selects
   68H-vs-6AH; a label operand is explicitly rejected — no relocation use
   case found in any fixture). Far-direct `JMP`/`CALL` (`EA`/`9A`
   ptr16:16) implemented as `EncJmpFarDirect`, reusing `EmitDisp16` twice
   against two `Operand` copies of the same label target (one plain =
   offset/RELOC, one with `isSegOf:=TRUE` = segment/SEGRELOC) — exactly
   the same offset/segment split `EmitDisp16` already performs for `SEG
   label` elsewhere, just both halves of one instruction instead of two;
   dispatched via a `far` qualifier check (`ops[0].isFar`) ahead of the
   existing near-JMP/CALL paths. `Lex.MOD`'s mnemonic ID range had to be
   widened from 50..149 (exactly full after batch 3) to 50..169, shifting
   directives to 170..199 and qualifiers to 200..209 — a pure
   renumbering, no call site referenced the old literal values. No
   real-NASM oracle available (same local `nasm` limitation as batches
   1-3), so the regression fixture (`TESTS/FIX/TNOOP4.ASM`/`.RDF`,
   covering every new no-operand mnemonic plus both PUSH-imm forms plus
   far JMP/CALL, verified to carry both a RELOC and a SEGRELOC record via
   `RDFGREP.EXE has-reloc-and-segreloc`) was hand-verified byte-for-byte
   against the 8086 opcode map, then adopted as the baseline. Wired into
   `TESTS/test_tasm.sh`. Verified via `make test` (280/280 manifest,
   `test_tasm.sh` 8/8) after landing.
5. **Prefix bytes — DONE (2026-07-12), the only genuinely new mechanism.**
   `LOCK` (F0H) and `REP`/`REPE`/`REPZ` (F3H, shared)/`REPNE`/`REPNZ`
   (F2H, shared) added as six new `Lex.M*` "prefix pseudo-mnemonic" IDs
   (160..169, `Lex.IsPrefixMnem` range-checks them) resolved via the same
   `Lex.LookupMnem` dictionary as real mnemonics. `Parse.MOD`'s `ParseLine`
   gained a new `ELSIF Lex.IsPrefixMnem(mnemId)` branch (before the
   existing label/directive/mnemonic dispatch) that consumes the prefix
   token, re-reads the next identifier as the real mnemonic, and calls
   `ParseInstruction(mnemId, Enc.PrefixByteFor(prefixId))` — note the
   fix needed here: `PrefixByteFor` must be called with the ORIGINAL
   prefix mnemonic id, captured in a separate `prefixId` local BEFORE
   `mnemId` is overwritten with the real instruction's id, not after.
   `Enc.Encode`'s signature grew a `prefixByte: BYTE` parameter (0 = none,
   threaded through every other call site as `BYTE(0)`), emitted first —
   before the segment-override prefix scan, per real 8086 prefix-byte
   ordering — via a one-line `IF prefixByte # BYTE(0) THEN B(prefixByte)
   END` at the very top of `Encode*`. No real-NASM oracle available (same
   local `nasm` limitation as batches 1-4), so the regression fixture
   (`TESTS/FIX/TREP.ASM`/`.RDF`, one instruction per LOCK/REP/REPE/REPZ/
   REPNE/REPNZ) was hand-verified byte-for-byte against the 8086
   prefix-byte convention, then adopted as the baseline. Wired into
   `TESTS/test_tasm.sh`. Both `SYS.RDF`/`EMS.RDF` re-verified
   byte-identical after the `Encode*` signature change (no regression from
   threading the new parameter through every existing call site).
   Verified via `make test` (280/280 manifest, `test_tasm.sh` 9/9) after
   landing.

### Explicitly still out of scope (unchanged from v1's non-goals)

32-bit/protected-mode forms, `IMUL`'s 2- and 3-operand forms (186+), a
general macro language beyond `%define`. These remain excluded because
they are not 8086 real-mode instructions at all — "full 8086 support"
means the complete **8086** opcode map, not later x86 extensions. **One
exception, made explicitly by the maintainer during batch 4:** `PUSH imm8`
(6AH) is technically an 80186+ opcode, not real 8086, but was implemented
anyway alongside the genuine 8086 `PUSH imm16` (68H) form since it costs
nothing extra and NASM assembles it without complaint — the "any 286+/187+
instruction" exclusion otherwise still holds for everything else (no ENTER/
LEAVE/BOUND/INS/OUTS/shift-by-immediate/IMUL-multi-operand, etc.).

### Testing strategy for v2

Same byte-diff discipline as v1 (§"Testing strategy" above), extended:
since no current `.ASM` file in this repo exercises most of the Batch 1-5
gap, each new mnemonic needs its own small `TESTS/FIX/*.ASM` fixture
byte-diffed against a real-NASM-produced oracle `.RDF` (`nasm -f rdf`) when
one is obtainable — **not** a TASM-self-consistency fixture like
`TSTRUC`/`TEXTERN`, since a real external oracle is preferred (per the
project's existing "real-NASM oracle over synthetic expectation" priority).
**Caveat found in batch 2:** the `nasm` build available in this dev
environment lacks the `rdf` output backend entirely (`-hf` doesn't list
`rdf`), so no oracle could be produced for `TMULDIV.ASM` — fell back to
hand-verifying the expected `.RDF` against the 8086 opcode table by hand
(documented in the fixture's own header comment) and adopting that as the
regression baseline, same fallback `TSTRUC`/`TEXTERN` already used. Check
`nasm -hf` for `rdf` support before starting each future batch; use a real
oracle if available, hand-verification if not — either way the fixture
must be self-documenting about which path was used. Group fixtures by
batch (e.g. `TSHIFT.ASM` for batch 1, `TMULDIV.ASM` for batch 2 — done,
`TJCC2.ASM` for batch 3, `TREP.ASM` for batch 5) rather than one per
mnemonic, matching the existing `TSTRUC`/`TEXTERN` granularity. Each batch
must pass `make test` (280+N manifest rows unaffected, `test_tasm.sh`
growing by the new fixtures) with 0 heap leaks (`/LOG=debug`, per the KEY
RULE) before moving to the next batch.

### Execution order (as actually landed)

All five batches landed 2026-07-12, in the suggested order: 1
(shift/rotate), 2 (mul/div), 3 (Jcc), 4 (no-operand opcodes/PUSH-imm/
far-direct JMP-CALL) — each with no inter-dependencies and no new
mechanism, verified independently — then 5 (LOCK/REP* prefix bytes) last,
since it was the only batch touching `Parse.MOD`'s token-consumption loop
and `Encode*`'s signature; landing it after the mechanical batches were
already stable kept the debugging surface small for the one genuinely new
mechanism.

## Post-v2 fixes (2026-07-12/13): empty `.data` segment + `%ifdef` hardening

Two real bugs found while adding `SRC/LIB/DETECT.MOD`/`DETECT.ASM` (a new
stdlib module wrapping BIOS/DOS/CPU detection routines) as TASM's first
`.text`-only real-NASM oracle — every prior oracle (`SYS.ASM`, `EMS.ASM`)
happened to have a real `SECTION .data`, so this code path was never
exercised end-to-end before:

1. **`SRC/LIB/RDOFF.MOD` `RdfWriteTo` omitted the `.data` segment header
   entirely when `dataLen=0`** — DONE. Real NASM always emits it (segType=2,
   dataLen=0), verified against `DETECT.RDF` (a genuine NASM-built oracle).
   Fixed by removing the `IF obj^.dataLen > 0 THEN` guard around both the
   segment-header write and the `modSize` accounting (`INC(modSize, LONGINT(10)
   + LONGINT(obj^.dataLen))` is now unconditional — `dataLen=0` contributes
   just the 10-byte header, matching NASM exactly). This is a shared
   `Rdoff` fix, not TASM-specific — `toc.exe`'s own compiled output goes
   through the same `RdfWriteTo`, but every Oberon module already has a
   non-empty `.data` segment (globals/strings), so this was a live,
   previously-undetected gap specifically in the `.text`-only path, not a
   compiler-output regression. Verified via `make test` (full manifest +
   self-host) after landing. Four existing `.text`-only synthetic fixtures
   (`TEXTERN`/`TJCC2`/`TNOOP4`/`TREP` — all lack `SECTION .data`) needed
   their expected `.RDF` baselines regenerated (+10 bytes each, the new
   empty-`.data`-header, verified by hand-diffing the exact byte delta
   before adopting).
2. **Unterminated `%ifdef` (no matching `%endif`) silently succeeded**
   instead of erroring — DONE. `Parse.MOD RunPass`'s outer loop now checks
   `(tSym = Scan.TEof) & (ifDepth > 0)` after the main parse loop exits and
   raises a fatal `"%ifdef without matching %endif"` if so. Found via a
   maintainer-requested infinite-loop-hardening audit (a static sweep of
   every `WHILE` loop in `SRC/TASM/*.MOD` found no confirmed hang — the
   original reported hang was independently traced to and fixed by using
   MASM `BYTE PTR [...]` syntax instead of NASM's `BYTE [...]`, before this
   audit even started; the outer `RunPass` loop's `~LogErr.HaveErr() &
   ~anyErr` guard already backstops most malformed-input cases). This
   specific gap doesn't hang either — it silently drops/keeps the unclosed
   block's content depending on the last-evaluated condition, with zero
   diagnostic — caught as a "silent success" correctness bug adjacent to
   the hang-hardening request, not a hang itself. Regression fixture:
   `TESTS/FIX/TBADIF.ASM`, checked via `test_tasm.sh`'s new `check_fails`
   helper (expects non-zero exit + a diagnostic substring, for fixtures
   that must be a fatal error rather than a byte-diff).

## `SECTION .bss` support (2026-07-13)

`SECTION .bss` was entirely unimplemented — `SECTION .text`/`.data` were
the only two recognized sub-keywords, and there was no third segment kind
anywhere in `Sym.MOD`'s label table. DONE:

- **`Sym.MOD`**: added `SegBss* = 2` alongside the existing `SegCode*=0`/
  `SegData*=1` (matches `Rdoff.MOD`'s own `SegBss*=2` numbering exactly,
  no translation needed at the boundary).
- **`Parse.MOD`**: `SECTION .bss` recognized in the `SECTION` directive
  handler (`curSeg := Sym.SegBss`); a new `bssOfs: LONGINT` running
  counter (reset to 0 alongside `codeOfs`/`dataOfs` at the top of each
  `RunPass`) tracks the current position inside `.bss`; a new top-level
  `ParseTopLevelRes` procedure handles `RESB`/`RESW`/`RESD n` as
  statement-level directives (distinct from `Dir.MOD`'s `ParseStrucField`,
  which handles the *same* keywords inside `STRUC`/`ENDSTRUC` blocks) —
  reserves `n*size` bytes by advancing `bssOfs` without emitting any bytes
  (BSS content never appears in the RDOFF2 code/data segment streams at
  all). Fatal error if `RESB`/`RESW`/`RESD` is used outside `SECTION
  .bss` (no silent no-op). A new `DefineCurLabel` helper factors out the
  `SegCode`/`SegData`/`SegBss` three-way dispatch that both of
  `ParseLine`'s colon-terminated-label sites need (previously a two-way
  `SegCode`/`else-SegData` dispatch, now three-way).
- **`Enc.MOD`**: `AddReloc` and the `SEG label` SEGRELOC-emission branch
  inside `EmitDisp16` both widened from a `SegCode`/else-`SegData` binary
  branch to a proper `SegCode`/`SegData`/else-`SegBss` three-way dispatch
  — without this, a `.bss` label reference (e.g. `mov ax, [bssLabel]`)
  would have silently emitted a `Rdoff.SegData`-targeted RELOC instead of
  the correct `Rdoff.SegBss` one, corrupting the linked address (verified
  the linker-side already handles `Rdoff.SegBss` relocations correctly —
  `SRC/TOC/LINK.MOD` already had `RSEG=2` support from the compiler's own
  BSS-backed global VARs, so this was purely a TASM emission gap, not a
  missing linker feature).
- **`Assemble`**: calls `Rdoff.RdfSetBss(obj, bssOfs)` once, after both
  passes finish, only if `bssOfs > 0` (a no-op for every existing
  `.bss`-free file).

Regression fixtures: `TESTS/FIX/TBSS.ASM`/`.RDF` (three `.bss` labels —
`RESW`/`RESB`/`RESD` — referenced from `.text` via three separate RELOC
records, plus the trailing `RDFREC_BSS` total; hand-verified byte-for-byte
including the exact RELOC offsets and the `RDFREC_BSS` DWORD = 2+10+4=16)
and `TESTS/FIX/TBADRES.ASM` (`RESB` outside `.bss`, `check_fails` for
`"RESB/RESW/RESD only valid in SECTION .bss"`). `SYS.RDF`/`EMS.RDF`/
`DETECT.RDF`/`WINCB.RDF` all reverified byte-identical after landing (none
of them use `.bss`, so zero effect expected and confirmed).

## `SRC/LIB/WINCB.MOD`/`WINCB.ASM` (2026-07-13)

New stdlib module wrapping the Windows 3.x WinOldAp (INT 2Fh AX=17xxh)
clipboard interface — `Detect`/`Open`/`Clear`/`Close`/`GetDataSize` were
already NASM-syntax `EXTERNAL` routines; `SetData`/`GetData` were ported
from a Turbo-Pascal-syntax `ASM` inline block (not valid input to this
compiler at all — `MODUL`/`FUNCTION`/`ASM...END`/`$hex`/`@label` are all
foreign syntax) into real `WINCB.ASM` NASM routines using the same
`[BP+RSIZE+N]` stack-argument convention `EMS.ASM`'s far-pointer `VAR`
routines already use (`LES BX, [BP+RSIZE+2]` loads the far pointer;
`RETF N` pops the N bytes of stack arguments on return). `WinCB.MOD`
itself needed porting to valid Oberon-07 too: `max_size` → `maxSize` (no
underscores in identifiers in this dialect), and `Paste`'s null-terminator
write (`d^[size] := 0X` in the original) rewritten as `SYSTEM.ADR` +
pointer arithmetic (`p := p + size`) + `SYSTEM.FILL(p, 1, 0)`, since `d`
is a typeless `VAR` (matching `EMS.MOD`'s `CopyToEMS`/`CopyToDos`
convention) and typeless `VAR`s can't be indexed directly — `SYSTEM.GET`/
`PUT` are removed from this dialect entirely, so `SYSTEM.FILL` is the
correct primitive. Wired into `SRC/LIB/Makefile` (`STDLIB_OMS`,
`regen-asm`, a `WINCB.OM` build rule) the same way as `DETECT.OM`.
`WINCB.RDF` is a TASM self-consistency baseline (not a real-NASM oracle —
`SetData`/`GetData` were hand-translated, never run through actual NASM),
hand-verified byte-for-byte (`LES BX,[BP+6]`, `MOV CX,[BP+0AH]`, `RETF 6`/
`RETF 4`) before being adopted.

## `SRC/LIB/KMOUSE.MOD`/`KMOUSE.ASM` (2026-07-13)

New stdlib module: extended-keyboard (BIOS INT 16h, incl. 101/102-key and
122-key detection) + Microsoft-mouse (INT 33h) driver, ported from
`KMOUSE.PAS` (a Turbo Pascal `UNIT`). Every routine in the original was a
`PROCEDURE/FUNCTION ...; ASSEMBLER; ASM ... END;` body — translated 1:1
into `KMOUSE.ASM` NASM routines (`KMouse_KbdGetKey`, `KMouse_MouseShow`,
etc.), reusing the same conventions established for `WINCB.ASM`/
`EMS.ASM`: byte-flag stack arguments via `[BP+RSIZE+2]` for `IsCtrl`/
`IsAlt`/`IsShift` (mirroring `WINCB.ASM`'s `SetData`/`GetData`), and
module-private `.data` state (`haveExtKb`/`have122Kb`/`mousePresent`/
`mouseState`) accessed via direct-memory `MOV [label],AL`/`MOV AL,[label]`
forms (mirroring `EMS.ASM`'s `driverPresent`). The Pascal `UNIT`'s own
`BEGIN...END.` initialization block (probing INT 16h AH=09h for keyboard
capabilities and INT 33h AX=0 for mouse presence) became `KMouse_Detect`,
called once from `KMOUSE.MOD`'s module `BEGIN` — same `Detect`-then-
module-`BEGIN` pattern as `EMS.MOD`/`WINCB.MOD`. `KbdReset` (the *only*
non-`ASSEMBLER` body in the original `UNIT`, `WHILE kbd_haskey DO
kbd_getkey`) stayed pure Oberon control flow, unchanged in meaning.
Roughly 90 Pascal `CONST SCAN_*` scan-code definitions were renamed to
Oberon identifier casing (`ScanF1`, `ScanCtrlHome`, etc. — no underscores
allowed in this dialect's identifiers) with no value changes. Wired into
`SRC/LIB/Makefile` the same way as `DETECT.OM`/`WINCB.OM`. `KMOUSE.RDF` is
a TASM self-consistency baseline (not a real-NASM oracle), hand-verified
byte-for-byte (`KMouse_Detect`'s `MOV [haveExtKb],AL` direct-address form,
and the shared `PUSH BP; MOV BP,SP; MOV AL,[BP+6]; AND AL,N` prologue
across all three `IsCtrl`/`IsAlt`/`IsShift` routines) before being
adopted.

## `SRC/LIB/SCREEN.MOD`/`SCREEN.ASM` (2026-07-13)

New stdlib module: text-mode screen buffer driver ported from `SCR.PAS` (a
Turbo Pascal `UNIT`) — shadow-buffer blit, colour print/scroll, cursor
control, a background INT 1Ch "spinner" animation, and VGA DAC palette
fades. Full port (all ~30 procedures), not a core-only subset.

- **ASM leaves** (`SCREEN.ASM`, `[BP+RSIZE+N]` convention throughout):
  `Screen_GetHeight`/`GetWidth` (BIOS data-area queries), `Screen_Cls`/
  `Cln`/`HPrint`/`ChColor`/`VPrint`/`Print`/`PrintHl` (shadow-buffer text
  ops, an internal `BufEsDi` register-arg helper computes the ES:DI cell
  address), `Screen_Show` (blits the shadow buffer to real video memory,
  hiding/showing the mouse cursor around the blit), `Screen_Locate`/`GetX`/
  `GetY`/`SetCursor`/`GetCursor`/`SetBlink`/`Delay`/`WaitRetrace`, and
  `Screen_Spinner1c` — the INT 1Ch handler itself, necessarily **hand-
  written raw assembly ending in `IRET`, not a compiled Oberon procedure**:
  this dialect has no `INTERRUPT` proc modifier (confirmed by grep across
  `SRC/TOC/*.MOD` and `DOCS/OBERON07.EBN`/`OBERLANG.MD` before writing it).
- **Oberon control flow** (`SCREEN.MOD`): `Push`/`Pop`/`Pick` (a save-buffer
  stack — see the chunking note below), `ScrollUp`/`ScrollDown` (via
  `SYSTEM.MOVE`), `CursorOff`/`On`/`Big`, `SpinnerStart`/`Stop` (via
  `Dos.SetIntVec`/`GetIntVec`, address of `Spinner1c` taken with
  `SYSTEM.ADR`), `SavePalette`/`SetColor`/`ResetPalette`/`GrayPalette`/
  `Fade0`/`FadeIn`/`FadeOut` (via `SYSTEM.PORTOUT`/`PORTIN` on the VGA DAC
  ports `3C7h`/`3C8h`/`3C9h`), and the module `BEGIN` init block (1:1 port
  of the Pascal `UNIT`'s own init: save the old INT 1Ch vector, detect VGA
  via `Detect.IsVga`, save the palette, pick the video segment — `SegB000`
  vs `SegB800` — via `Detect.IsMonochrome`, disable blink, allocate the
  shadow buffer, show the mouse).
- **`SYSTEM.Seg0040`/`SegB000`/`SegB800`/`SegA000` architectural rule**:
  magic BIOS/video segment constants are obtained via these four
  `SYSTEM.MOD EXTERNAL` procedures (backed by `SYS.ASM` — `mov ax,<const>;
  RETMACRO` each), never hardcoded as a local `%define` in an individual
  `.ASM` file. `SCREEN.ASM` calls them with **`CALL FAR`** (opcode `9A`,
  `RELOC`+`SEGRELOC` against the import ID) since they resolve to another
  module's `EXTERNAL` routine — a bare near `CALL` (`E8`) is wrong here and
  was caught and fixed during this port (mirroring the same fix already
  applied to `DETECT.ASM`'s own `SYSTEM_Seg0040` call). The two
  `KMouse_MouseHide`/`MouseShow` calls inside `Screen_Show` are `CALL FAR`
  for the same reason (cross-module `EXTERNAL`).
- **`PCHAR` maps to `SYSTEM.ADDRESS`** throughout the port, per the
  project's explicit Pascal→Oberon type-mapping rule.
- **`ScrDesc` (the `Push`/`Pop`/`Pick` save-buffer stack node) is chunked**
  per the "Chunk small records" rule (`DOCS/IMPLRULE.MD`): rather than one
  `NEW` per pushed screen (`prev`/`size`/`x`/`y`/`buf` fields, well under 32
  bytes), a `PScr` node holds `ScrChunk=32` parallel `size[]`/`x[]`/`y[]`/
  `buf[]` slots plus a `count`/`prev`. `Push` appends into the current top
  chunk and only allocates a fresh chunk node once it fills; `Pop` removes
  the top live entry and frees the chunk node once its `count` reaches 0.
  Each slot's `buf[k]` is still a separately-`NEW`'d byte buffer (its size
  is runtime-determined by the current screen mode, so it can't be
  flattened into the chunk payload itself) — only the small fixed-size
  bookkeeping record is chunked, matching the Pascal original's own
  separation of the `TScr` header from its variable-length screen-capture
  payload.
- **`LDS` instruction added to TASM** (`SRC/TASM/LEX.MOD`'s `MLds=154` +
  `SRC/TASM/ENC.MOD`'s `EncLds`, opcode `C5H` — a straight mirror of the
  pre-existing `LES`/`C4H` pair): needed for `Screen_Print`/`Screen_PrintHl`
  to load a far pointer to the caller's length-prefixed string argument
  (`LDS SI, s_ofs`). TASM's v1/v2 scope only implemented `LES` (the far-
  pointer-into-`ES` idiom `EMS.ASM`/`WINCB.ASM` already used for `VAR`
  params) — `LDS` (far-pointer-into-`DS`) was a genuine gap, not a design
  choice, closed the same way any future far-pointer-opcode gap should be:
  add the `Lex` mnemonic ID + `Enc` procedure, no wider redesign needed.
- A `MOV reg, label` / `ADD reg, indexReg` / `MOV reg, [reg]` sequence was
  needed inside `Screen_Spinner1c` for `spinnerChars[bx]`-style indexed
  reads — **TASM does not support `[label+register]` combined addressing**
  (a data-segment label combined with a base register inside one bracket
  pair) — confirmed as a real, if narrow, limitation, not attempted to fix
  given how rarely this addressing form is needed elsewhere in the repo.
- Wired into `SRC/LIB/Makefile` (`STDLIB_OMS`, `regen-asm`, a `SCREEN.OM`
  rule depending on `DETECT.OM`/`KMOUSE.OM`/`DOS.OM`/`SYSTEM.OM`) and
  `TESTS/test_tasm.sh` the same way as `WINCB.OM`/`KMOUSE.OM`.

`TESTS/test_tasm.sh` now runs 16 checks (3 real-NASM oracles — `SYS.ASM`,
`EMS.ASM`, `DETECT.ASM` — 11 byte-diff synthetic/self-consistency fixtures
including `WINCB.ASM`, `KMOUSE.ASM`, `SCREEN.ASM`, and `TBSS.ASM`, 2
`check_fails` error-path fixtures).

## Real-NASM cross-verification of every `.ASM` file (2026-07-13)

Beyond the original `SYS.ASM`/`EMS.ASM`/`DETECT.ASM` real-NASM oracles, all
six `SRC/LIB/*.ASM` files were independently reassembled with real NASM and
diffed against a fresh TASM build:

- **`SYS.ASM`, `EMS.ASM`, `WINCB.ASM`, `KMOUSE.ASM`: byte-identical to real
  NASM, no differences whatsoever.**
- **`DETECT.ASM`, `SCREEN.ASM`: code and data segment bytes byte-identical
  to real NASM; only the header-record *ordering* differs** — NASM
  interleaves `RDFREC_IMPORT` records at the point in source order where
  the `EXTERN` is declared, while TASM groups all `RDFREC_GLOBAL` records
  first and emits every `RDFREC_IMPORT` afterward, before the `RELOC`/
  `SEGRELOC` records. Verified by parsing both header-record streams by
  hand against `DOCS/RDOFF2.MD`'s layout: identical set of GLOBAL/IMPORT/
  RELOC/SEGRELOC records, identical IDs, identical offsets/widths/rsegs —
  purely a difference in emission order. This is semantically inert (the
  linker builds its `ImportID -> address` map from a full scan of the
  header before resolving any `RELOC`/`SEGRELOC`, so record order doesn't
  matter) and was deliberately **left as-is** rather than changed to match
  NASM's interleaved order — doing so would touch `SRC/TASM/PARSE.MOD`'s
  header-emission loop for a purely cosmetic diff-friendliness win, and
  would require regenerating every checked-in `.RDF` baseline in the repo
  for zero functional benefit.

---

## Non-goals (explicit)

- Not a general-purpose NASM replacement. No 32-bit, no other object
  formats, no macro language beyond `%define`.
- **Not a hard build dependency of `make all`** — this is a structural
  constraint, not caution: TASM needs a fully-built `OBERON.OM`
  (Files/Strings/LogErr/Rdoff/Out/Dos) to run at all, and `OBERON.OM`'s own
  `SYSTEM.OM` is built *from* `SYS.RDF`, so TASM cannot be a prerequisite
  of the stdlib build without a circular dependency. `SYS.RDF`/`EMS.RDF`
  stay checked into the repo (regenerated via `BOOT/TASM.EXE` and
  `make regen-asm`, then committed) — see `DOCS/BUILD.MD`.
- No plans to self-assemble TASM's own generated code back through itself
  as a bootstrap check — TASM is a leaf tool, not part of the compiler's
  self-hosting chain.
