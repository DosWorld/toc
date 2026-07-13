# Test Suite

> **IMPORTANT — ALL test information lives here.**
> Do NOT add test commands, test descriptions, xt reference, pass criteria, or
> "how to add tests" guidance to CLAUDE.md. Keep it in this file only.

---

## Running tests

**Always run a full clean + rebuild before running tests.** Stale compiler or library
objects will produce false results. `make test` enforces this automatically.

```bash
make test      # clean, full rebuild, run 281 manifest rows + TASM regression (host-side, fast)
make testall   # full DOS-side suite via xt: manifest + Section 17/18 + SYSTEM.DEF checks (~9 min)
```

---

## Test philosophy

**Prefer executable tests over byte-sequence checks.**

When adding tests for a new language feature or built-in:
1. Write a `TestXxx.Mod` module with a `RunAllTests*` entry point that exercises the feature at runtime and prints `Failed: N`. Add it to `TESTALL.MOD`'s `RunSection17`.
2. For compiler-output checks (byte patterns, symbol presence, error messages), add a row to `TESTS/MANIFEST.TSV`. This is the preferred path for new non-runtime checks.
3. Reserve byte-level checks only for things **not** observable at runtime: RDOFF layout, opcode selection, compile-error cases, codegen invariants.

Executable tests catch real runtime bugs, survive code-generator refactors without byte-count updates, and serve as documentation of correct behavior. Byte-level tests are brittle and should be the last resort.

---

## Pass criteria

- **All tests must be green before merging any change.**
- `TCGEN.MOD` checks exact byte sequences — any codegen change must update the expected bytes.
- `TRDOF.MOD` checks IMPORT has 2-byte seg_id and GLOBAL has 1-byte seg_id — do not mix them.
- Any new language feature needs at least one entry in `TESTS/MANIFEST.TSV`.
- Any new `.def` format change requires `TDEF.MOD` round-trips to pass and SYSTEM library to build without warnings (see `DOCS/IMPLRULE.MD` for canonical format).

---

## `BIN/RDFGREP.EXE` — RDOFF/.om/.exe inspection tool

`BIN/RDFGREP.EXE` is the test suite's RDOFF/.om/.exe inspector.  It is built
from `SRC/TOOLS/RDFGREP.MOD` (a pure Oberon-7 program linking against the
`Rdoff` + `Tar` modules from `SRC/TOC/`) and runs as a DOS MZ binary under
`xt`.  Binary-introspection checks in `TESTS/MANIFEST.TSV` are routed through
`rdfgrep`; `testall.exe` also calls the same predicates in-process.

> **Gotcha — rdfgrep shares `Rdoff`'s in-memory types.**  Because `rdfgrep`
> links the real `Rdoff` module, any change to a node layout there (e.g.
> chunking `RelocNode` into parallel arrays + `count`) **also breaks rdfgrep's
> own walkers** if they are not updated in the same change.  rdfgrep's reloc
> predicates (`has-segreloc`, `has-reloc-and-segreloc`, `has-reloc-to-seg`,
> `has-reloc-for`) must iterate the chunk (`WHILE k < r^.count` over
> `r^.physSeg[k]`/`r^.rseg[k]`), not read scalar fields.  A stale scalar reader
> silently reports *no relocations* — the `cross-call/10b-reloc-segreloc-pair`
> row is the regression sentinel for this.

**Policy.**  Do not introduce new python (or perl, ruby, …) helpers into
the test scripts.  If you need a new predicate, add a subcommand to
`SRC/TOOLS/RDFGREP.MOD` instead.  This keeps the suite buildable in a
DOS-only environment.

### Subcommands

```
rdfgrep SUBCOMMAND FILE [ARGS...]

RDF predicates:
  has-import        FILE.RDF NAME
  has-global        FILE.RDF NAME
  code-starts       FILE.RDF HEX
  code-contains     FILE.RDF HEX
  code-count        FILE.RDF HH MIN
  code-byte-at      FILE.RDF OFS HH
  init-imports      FILE.RDF
  has-segreloc      FILE.RDF
  no-segreloc       FILE.RDF
  has-reloc-and-segreloc FILE.RDF
  has-reloc-for     FILE.RDF NAME
  has-reloc-to-seg  FILE.RDF SEG    (0=code, 1=data, 2=bss)

.om (ustar) operations:
  om-has-file       FILE.OM MEMBER
  om-extract        FILE.OM MEMBER OUT
  om-member-equals  FILE.OM MEMBER VALUE
  om-member-contains FILE.OM MEMBER TEXT
  make-stub         OUT.OM MODNAME [DEFTEXT|@FILE]

MZ EXE inspection:
  mz-sp             FILE.EXE VALUE       MZ SP word at offset 16 == VALUE
  mz-min-alloc      FILE.EXE VALUE       MZ min_alloc word at offset 10 == VALUE
  mz-max-alloc      FILE.EXE VALUE       MZ max_alloc word at offset 12 == VALUE

Exit codes: 0=match  1=no-match  2=usage  3=I/O
```

Run `rdfgrep` with no arguments (under xt) to print this list.

### Adding a new predicate

1. Implement the predicate in `SRC/TOOLS/RDFGREP.MOD` as a new subcommand.
2. Update the `Usage` proc with the new subcommand.
3. Rebuild via `make tools`.
4. Use it in `TESTS/MANIFEST.TSV` as the EXPECT value, or call it from `TESTALL.MOD` via `Spawn(rdfgrepPath, "new-pred ...")`.

---

## Unit tests (Oberon)

Canonical unit coverage lives in `TESTS/T*.MOD` (Section 18) — see
the table further down ("Oberon-port unit-test modules") for what each
T*.MOD covers.

---

## SYSTEM intrinsics tests

SYSTEM intrinsics compile-level checks are now covered by manifest rows (T1–T4, T7–T17b)
and `testall.exe` (T5/T6 — SYSTEM.DEF absent checks).  The old
`test_system_intrinsics.sh` was deleted in Phase 4 (2026-06-03).  Key rules enforced:

- `SYSTEM.ADR` emits correct push+INLINE pattern; `ADR(proc)` emits PUSH CS + MOV AX.
- `ADR(constant)` gives compile error (manifest row).
- SYSTEM-specific intrinsics (`LSL`, `LSR`, `ASR`, `ROR`, `AND`, `IOR`, `XOR`) require
  the qualified `SYSTEM.Name(...)` form — bare names are rejected.
- `SYSTEM_VAL`, `SYSTEM_GET`, `SYSTEM_PUT` are absent from `SYSTEM.DEF` (removed from dialect).

---

## Manifest tests (TESTS/MANIFEST.TSV)

A TSV-driven test runner — one row per test, no shell heredocs.  Each row
names a fixture in `TESTS/FIX/`, optional compiler flags, an EXPECT
predicate, and an argument.  **281 rows, all passing.**

Driven by two runners:
- **Host-side (POSIX):** `make -f TESTS/Makefile.man test` — GNU make, calls xt per row.  Per-row scratch dirs are created under the project `TMP/` (not the system tmpfs); see `TMPROOT` in `TESTS/Makefile.man`.
- **DOS-side:** `make testall` → `xt run TESTALL.EXE .` — testall.exe reads the manifest directly and spawns `toc.exe`/`rdfgrep.exe` via `Dos.Exec`.  For `errorlevel` and `mz-sp` rows that require linking, testall re-invokes `toc.exe /ENTRY=` (no separate linker needed).

Row format:
```
test-name<TAB>FIX_FILE.MOD[+EXTRA.MOD]<TAB>oc-flags<TAB>EXPECT<TAB>arg
```

Supported EXPECT predicates:

| EXPECT | Meaning |
|--------|---------|
| `has-import` | compiled `.rdf` must contain an IMPORT record named `arg` |
| `no-import` | compiled `.rdf` must NOT contain an IMPORT record named `arg` |
| `has-global` | compiled `.rdf` must contain a GLOBAL record named `arg` |
| `no-global` | compiled `.rdf` must NOT contain a GLOBAL record named `arg` |
| `code-starts` | code segment must start with hex bytes `arg` |
| `code-contains` | code segment must contain hex byte sequence `arg` |
| `no-code-contains` | code segment must NOT contain hex byte sequence `arg` |
| `code-byte-at` | byte at offset `OFS` must equal `HH` (arg = `OFS HH`) |
| `code-count` | byte `HH` must appear at least `MIN` times (arg = `HH MIN`) |
| `init-imports-empty` | `__init` procedure has no IMPORT records |
| `has-segreloc` | `.rdf` must contain at least one SEGRELOC record |
| `no-segreloc` | `.rdf` must contain no SEGRELOC records |
| `has-reloc-and-segreloc` | `.rdf` must contain both a RELOC and a SEGRELOC |
| `has-reloc-for` | `.rdf` must have a RELOC referencing import named `arg` |
| `has-reloc-to-seg` | `.rdf` must have a RELOC to segment `arg` (0=code, 1=data, 2=bss) |
| `om-has-file` / `om-no-file` | `.om` archive must / must not contain member `arg` |
| `om-member-contains` / `om-member-no-contains` | `.om` member must / must not contain text `arg` |
| `om-member-equals` | `.om` member must equal the literal bytes given |
| `stderr-contains` | compile stderr must contain `arg` substring |
| `stderr-no-contains` | compile stderr must NOT contain `arg` substring |
| `file-in-workdir` | named file must exist after compile |
| `no-file-in-workdir` | named file must NOT exist after compile |
| `errorlevel` | compile + link (via `toc.exe /ENTRY=`) + run; `.exe` must exit with value `arg` |
| `mz-sp` | linked `.exe` must have SP field = `arg` in MZ header |
| `mz-min-alloc` / `mz-max-alloc` | linked `.exe` must have min/max\_alloc = `arg` paragraphs |
| `compile-fails` | (when `oc-flags` column is `fails`) — compile must exit non-zero |

Test categories currently covered (selection):

- `inline/*` — INLINE proc + INLINE statement form
- `near-far/*` — NEAR/FAR proc visibility + reloc opcodes
- `dead/*` — **9 dead-code/unused-symbol warning tests** (locals,
  params, VAR params, globals, procs, exported-no-warn, RETURN-counts,
  CASE-label-counts, SYSTEM.ADR-counts)
- `init/*` — `__init` deps, `IMPORT SYSTEM` rejection, sanitise-import pass
- `inc-long/*` — INC/DEC carry into LONGINT high word
- `mz/*` — MZ header min_alloc/max_alloc/SP for various `$M stack`
- `bounds/*` — `$R+` runtime check call
- `dbg/*` — `$D+` debug-info collection (`MODNAME.DBG` member present + contains
  the module ident; a no-`$D` module's `.DBG` has no content) and `/G` link
  (`dbg/link-g-runs`: flags column `/G /ENTRY=Run`, exe still exits 0).
  Deeper TDS invariants live in `TESTS/test_dbg.sh` (see "Debug-info regression
  test" below)
- many more — `awk -F'\t' '{print $1}' TESTS/MANIFEST.TSV | sort -u`

When adding a manifest row: pick the most specific EXPECT that locks
the behavior; prefer `errorlevel` (runtime exit code) for any check
expressible as "module reports `Failed: 0`" — it's the most robust
form and survives all codegen reshuffles.

---

## Integration tests

All integration tests are now in `TESTS/MANIFEST.TSV` (281 rows) or run by
`BIN/TESTALL.EXE` (Section 17/18 executables + SYSTEM.DEF artefact checks).
The old bash drivers (`test_src.sh`, `test_system_intrinsics.sh`) have been deleted —
their content is fully covered by the manifest and testall.

### What is covered

| Area | Checks |
|------|--------|
| `__init` protocol | Guard word present, CMP/JE/RETF pattern, INC before dep calls |
| `__init` deps | Each imported module's `__init` called in source order |
| SYSTEM exclusion | `SYSTEM__init` never called even when `SYSTEM.*` used |
| `IMPORT SYSTEM` | Compiler exits 1 with error |
| SYSTEM.* access | `SYSTEM.Intr` etc. resolve to lazy RDOFF imports |
| Naming convention | Exported symbols prefixed `ModName_`; `__init` double-underscore |
| Qualified imports | `H := Hello; H.WriteStr` → `Hello_WriteStr` RDOFF import |
| .om contents | tar contains `ModName.rdf` and `ModName.def`; intermediates deleted |
| Stub imports | `make_stub_om` helper creates minimal `.om` with only a `.DEF` member; replaces old `printf > foo.def` pattern (standalone `.def` ignored by compiler) |
| `/ENTRY=` / `MAIN.RDF` | SYSTEM_INIT / ModName__init / ModName_Proc / SYSTEM_DONE in order; RDOFF import IDs 3/4/5/6 |
| Cleanup | `.rdf` and `.def` deleted after `.om` produced; absent on error |
| No INT 20h | `CD 20` never in output (DOS exit is SYSTEM_DONE's job) |
| Exported RETF | Exported proc epilogue uses `CA`/`CB` (RETF); internal uses `C2`/`C3` (RET) |
| Cross-module call | FAR call `9A` + RELOC + SEGRELOC for every imported proc call |
| Underscore in name | `MODULE Foo_Bar` → compiler exits 1 |
| Missing import | `IMPORT Unknown` with no `Unknown.om` in search path → compiler exits 1 |
| NEAR/FAR codegen | NEAR/FAR epilogue bytes, param offsets, call opcodes, proc var encoding (Section 37) |
| EXTERNAL procs | RDOFF IMPORT emitted; FAR external → CALL FAR (9A)+RELOC+SEGRELOC; NEAR external → CALL NEAR (E8)+RELOC; .def export; FAR/NEAR+EXTERNAL combos (Section 38) |
| `/SYSTEM` mode | Compiles without implicit SYSTEM import; IMPORT SYSTEM allowed; no SYSTEM__init dep; no spurious runtime imports (Section 39) |
| `$L` directive | `(*$Lpath.rdf*)` / `//$Lpath.rdf` in source packs extra `.rdf` into `.om` under `MODNAME/<BASENAME>.RDF` (uppercased module name as directory prefix, preventing collisions in `OBERON.OM`); up to 128 entries; unreadable path is a fatal compiler error (Section 41) |
| `.om` naming | All member names in `.om` archives are stored in upper case (e.g. `HASBODY.RDF`, `HASBODY.DEF`, `MAIN.RDF`); `tar_extract_file` searches case-insensitively |
| `ADR/SEG/OFS(n^)` | `ADR(n^)` emits `MOV AX,BX`+`MOV DX,ES` = full far pointer = value of `n`; `SEG(n^)` emits `MOV AX,ES`; `OFS(n^)` emits `MOV AX,BX` (Section 43) |
| Typeless VAR param | `VAR name` without type accepted; parameter without type and without VAR keyword rejected with compile error (Section 46e–f) |
| Array dim constants | `ARRAY N OF T` and `ARRAY ROWS, COLS OF T` accept named INTEGER constants as dimensions; non-integer constants rejected (Section 47) |
| `FLOAT`/`ENTIER` synonyms | `FLOAT(x)` compiles identically to `REAL(x)`; `ENTIER(x)` compiles identically to `FLOOR(x)`; FILD/FSTCW byte patterns verified (Section 48) |
| Implicit int→REAL coercion | `r * n`, `n + r`, `r < 0`, `r = 0` etc. compile and emit FILD word (DF 07) for the integer operand; both orderings and all four operator groups covered (Section 49) |
| Filename vs module name | Filename (e.g. `testhello.mod`) used for file open only; output names and RDOFF symbols use module name from `MODULE` keyword (`parser_mod_name`). `/ENTRY=` stub imports correct name even with lowercase filename. (Section 53) |
| `$M` memory triple | `(*$M stack, min, max*)` sets `parser_stack_size` (bytes), `parser_min_mem_para`, `parser_max_mem_para` (each rounded UP to 16-byte paragraphs; ceiling div). With `/ENTRY=`, the stack value is written as `META-INF/STACK.TXT` (plain decimal) and the min/max paragraphs become the MAIN.RDF prologue (`MOV AX,min ; MOV BX,max` before `CALL FAR SYSTEM_INIT`).  Without `/ENTRY=` no STACK.TXT is written (the prologue isn't generated).  Multiple `$M` directives: last wins.  Defaults if no `$M`: stack=8192, min=131072, max=262144 bytes (128 KiB / 256 KiB).  Rules: stack 1..65536; min/max 0..655360; min<=max; all three values mandatory (legacy `$M N` single-value is rejected).  Any violation is a fatal compile error mentioning `$M`. (Section 54) |
| Stack size override | The linker (embedded in `toc.exe`) reads `META-INF/STACK.TXT` from the entry `.om` after smart-link; sets `LinkerState.stack_size`; MZ SP field = `stack_size - 2`; invalid/missing → default `STACK_SIZE=8192`. MZ header verified by parsing SP at byte offset 16. (Section 55) |
| MZ min_alloc / max_alloc | The linker writes min_alloc = max_alloc = `(data_bss_para − ceil(total_data_len/16)) + ceil(stack_size/16)` paragraphs (the BSS-extension gap plus the stack).  This is the minimum DOS must reserve above the file image for the program to start safely.  Setting max = min (instead of the historical 0xFFFF) leaves remaining DOS free memory available for the runtime heap (`SYSTEM_INIT` calls INT 21h/48h) and for `Dos.Exec` children.  Manifest tests `mz/min-alloc-*` and `mz/max-alloc-*` verify both fields against expected paragraph counts for fixtures with different `$M stack` sizes. |
| `IS` type test | `p IS Base` compiles (static extension → TRUE); `p IS Ext` where `p: POINTER TO Base` compiles (runtime tag check); `p IS B` for unrelated types compiles (folds to FALSE). `TestTypeTag.Mod` executable verifies 7 runtime IS scenarios including cross-type checks. (Section 57) |
| FORWARD procedures | `PROCEDURE name(params): T; FORWARD;` compiles; body `PROCEDURE name;` resolves and patches all call sites; mutual recursion works; unresolved FORWARD gives error. (Section 58) |
| `$R` directive | `$R-` (default) — no bounds checks emitted. `$R+` — constant out-of-bounds index (negative or ≥ len) gives compile error; variable index emits runtime check calling `SYSTEM_ErrIndexOutOfBounds` (FAR, no args) on violation, which prints a message and halts. Open-array params use LEN slot at `[BP+adr+4]`. Directive toggles mid-file; `$R-` after `$R+` turns checks off. (Section 59) |

---

## Executable test modules (Section 17)

All executable tests are consolidated into a small set of 8.3-named modules
in `TESTS/`. Each module groups related sub-tests, registers them via the
`Test` framework (`Test.AddTest(proc, name)` then `Test.RunTests`), and is
driven by `testall.exe` (`RunSection17`) under `xt`:

1. Compile with `/ENTRY=RunAllTests`.
2. Verify `.om` produced.
3. Link against `lib/Test.om lib/Math.om lib/Out87.om lib/Out.om lib/Strings.om lib/Dos.om lib/Crt.om lib/SYSTEM.om`.
4. Run via `Dos.Exec`; PASS iff exit code is 0.

Section 17 runs only under `make testall` (requires `xt`).

### Consolidated module map

| File           | Tests merged from                                                                                                                       |
|----------------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `NUM.MOD`      | INTEGER, BYTE, WORD, LONGINT — arithmetic, boundaries, comparisons, BOOLEAN ops, NOT (~), shifts (LSL/LSR/ASR/ROR), bit ops (AND/IOR/XOR) |
| `FLOAT.MOD`    | REAL, LONGREAL — arithmetic, conversions (REAL/LONGREAL/FLOOR), Math 8087 INLINE wrappers, implicit INT→REAL coercion                   |
| `CTRL.MOD`     | Control flow — IF/ELSIF, WHILE, REPEAT (large body), FOR (asc/desc/nested), CASE, NOT, constant-expr evaluation, FORWARD               |
| `PROC1.MOD`    | Procedures — value/VAR/mixed params, nested procs (no uplevel access), recursion, deep recursion, function composition, params           |
| `PROC2.MOD`    | More procedure features — ADR params, proc variables (FAR/NEAR), proc types as params, typeless VAR params                               |
| `RECARR.MOD`   | Records + arrays — fields, alignment, extension, IS type-test, NewField regression, multi-dim arrays, type-tags, bounds, casts          |
| `PTR.MOD`      | Pointers — NEW/DISPOSE, NIL, deref, chains, VAR pointer params (regression), linked lists, binary trees                                  |
| `SYS1.MOD`     | SYSTEM — constants/Registers/Intr, SEG/OFS/ADR/MOVE/FILL, SET ops + IN, NEW(addr,n)                                                       |
| `SYS2.MOD`     | NEAR/FAR procs + proc types, INLINE bytes, AdrProc (ADR-of-proc), globals, RetAddr                                                       |
| `STR.MOD`      | Strings library (Length/Pos/Append/Insert/Delete/Replace/Extract), ASSERT                                                               |
| `IMPCA + IMPCB`| Imported CONST in expressions, array dimensions, CASE labels                                                                            |
| `IMPPA + IMPPB`| Direct deref of imported POINTER global (regression 5p)                                                                                  |
| `DEEP.MOD`     | Deep composite-type designator chains — record fields, nested records, array elements, pointer fields, multi-level access                |
| `DEEP2.MOD`    | Multi-dim arrays of LONGINT/REAL/POINTER; procedure-valued fields in records and arrays                                                  |
| `SCOPA + SCOPB`| Composite-type access in every scope: local, parameter, module-global, imported global — read and write patterns                        |

Each module emits a `Failed: N` line; `testall.exe` uses the exit code (0 = all passed) to decide pass/fail.

## Oberon-port unit-test modules (Section 18)

The compiler modules in `SRC/TOC/` (`Scan`/`Syms`/`Cgen`/`Def`/`Rdoff`/`Tar`
and the parser-side modules `Parser`/`PExpr`/`PStmt`/`Import`) have unit
coverage in `TESTS/T*.MOD`, written using the `Test` framework and running under `xt`
exactly like the Section 17 modules.

| File        | Module under test | Coverage                                                                 |
|-------------|-------------------|--------------------------------------------------------------------------|
| `TSCAN.MOD` | `Scan`            | keywords, idents, integers/char/hex literals, strings, operators, comments, whitespace, line tracking |
| `TSYMS.MOD` | `Syms`            | predeclared types/consts/sysprocs, scope open/close/find, AllocLocal, CalcArgSize, records + extension |
| `TCGEN.MOD` | `Cgen`            | prologue/epilogue, LoadImm, BP/mem load+store (incl. byte), far ptr helpers, arithmetic, inc/dec/cmp, setcc, FAR call, jumps + cond-back (short + near), call-near / call-local-far, InvertJcc, shifts |
| `TRDOF.MOD` | `Rdoff`           | init state, import-id assignment, global add, signature, file/header sizes, IMPORT 2-byte seg-id, GLOBAL 1-byte seg-id, reloc/segreloc/BSS records, code-seg header, no-data + data-segment, EOF, header record order |
| `TTAR.MOD`  | `Tar`             | magic, typeflag, name, size, zero-size, checksum, data follows header, padding to 512 and 1024, EOF blocks, two-file archive |
| `TDEF.MOD`  | `Def` + `Syms`    | MODULE/CONST/VAR/TYPE/PROC writes, non-exported excluded, full round-trip, empty module, multi-CONST, VAR code-seg, record + extension, POINTER to record, REAL/LONGREAL/SET field types, PROC float params, write order, REAL primitives, typed/typeless VAR params, FORWARD proc, imported-type pointer, cross-module extension (23 tests) |
| `TPRSR.MOD` | `Parser`          | end-to-end compile of fixture modules from `TESTS/FIX/*.MOD`; verifies module name, exported symbol set in `.def`, and produced `.om` archive members |
| `TADDR.MOD` | `Cgen` (codegen regression) | Typeless-VAR-param-as-value: `WriteThrough(VAR x; ...)` assigns `x` to a typed pointer and writes through it; asserts the bytes landed in the caller's array. Fails on the unfixed compiler (`CgLoadItem` extra-deref bug). |
| `TFBUF.MOD` | `Files` (buffered I/O regression) | Writes 20000 bytes 1 byte at a time, reads back, spot-checks at offsets 8191/8192/8193/16384 (BUFSIZE boundary). Guards the `SYSTEM.AND` bit-mask fix in `BlockRead`/`BlockWrite`. |
| `TFREC.MOD` | `Files` (embedded-File / imported-record-size regression) | Embeds a `Files.File` in a record with a trailing `BOOLEAN`/`INTEGER`, writes the trailing field right after `Reset`, then reads back. Guards against an importer laying a field on top of an embedded `File`'s internals when `Files.File` grows (gr_bug 2026-06-23). |
| `TEMSTMP.MOD` | `Files` (EMS temp backend regression) | Three concurrent `ReWriteTemp` temp files, odd 277-byte records, 110800 bytes/handle (>64 KB, crosses BUFSIZE), interleaved random-access read-back while files grow. Guards the unification of the `BkEms` backend into the shared `BufFetch`/`BufFlush` path (2026-06-26) — the prior separate EMS staging path made the compiler write no output under EMS. Passes under both EMS and `--noems` (transparent disk fallback). |

**How they run.**  `testall.exe` (`RunSection18`) first compiles the
Oberon-port dependency modules (`Scan`, `Syms`, `Rdoff`, `Cgen`,
`Tar`, `Def`, `PExpr`, `PStmt`, `Import`, `Parser`) into
a scratch directory, then for each `T<X>.MOD` it:

1. compiles `TESTS/T<X>.MOD` with `/ENTRY=RunAllTests`;
2. checks that `T<X>.om` was produced;
3. links it against the appropriate Oberon-port `.om` files plus the
   standard runtime libraries;
4. runs the resulting `T<X>.exe` via `Dos.Exec` and checks the exit code.

Section 18 runs only under `make testall` (requires `xt`).

### Strong rules — Oberon-port unit tests

This rule is **mandatory** and applies whenever the unit-test surface changes:

**Oberon-compiler rule.**  Every `T<X>.MOD` is compiled with `BOOT/TOC.EXE` (via xt)
or `BIN/TOC.EXE` after it is built.  The test file must use only the dialect features
the compiler supports:
- **No uplevel access.**  A test procedure may read/write
  only module-level VAR/CONST, names from imports, and its own locals/params.
- All test procs registered with `Test.AddTest(T<Name>, "...")` are called from
  `RunTests`; mark them with `*` so they are exported.
- CASE labels accept any constant expression including imported CONST
  (`Alias.Const`).
- Module names must be DOS-8.3 compatible (≤ 8 chars); procedure names inside
  a module can be longer.

The `T*.MOD` modules are the sole canonical coverage.

To add a new Oberon-port unit test:

1. Add a procedure `T<Name>*` to one of the existing modules (or create a
   new `TESTS/T<X>.MOD` and register it in `RunSection18` of `TESTS/TESTALL.MOD`).
2. Register it in that module's `RunAllTests` via `Test.AddTest`.
3. The test should use the `Test.Assert*` helpers exclusively; no direct
   stdout writes.

The Oberon-port modules export the helpers needed by tests (e.g.
`Cgen.CgStoreBp`, `Rdoff.PeekCodeByte`, `Cgen.InvertJcc`).  If a test
needs to inspect emitted code bytes, use `Rdoff.PeekCodeByte(obj, ofs)`.

### What each module covers

See the module source files in `TESTS/` for the exact test list. Each
`PROCEDURE T<name>*` is a single test case registered in `RunAllTests` with
`Test.AddTest(T<name>, "Tag/name")`. Sub-tests inside a procedure use the
`Test.Assert*` framework calls.

Regressions of historical compiler bugs are preserved in the corresponding modules:

- **PTR.MOD** carries the VAR-pointer-parameter deref regression and the
  imported-pointer deref regression (via `IMPPB`).
- **RECARR.MOD** carries the `NEW(rec^.field, sizeExpr)` regression and
  the `IS` runtime type-tag check.
- **SYS2.MOD** carries `SYSTEM.ADR(procedure)` for FAR/NEAR/imported procs.
- **PROC2.MOD** carries the `.def` `PROC` keyword and LONGINT→INTEGER param
  narrowing regression (the older "TestProcType" coverage).
- **TADDR.MOD** is the regression test for the typeless-VAR-param-as-value
  codegen bug (`CgLoadItem` erroneously dereferenced TFAddress params); it
  provably fails on the unfixed compiler.
- **TFBUF.MOD** is the regression test for the buffered-I/O correctness bug
  (`Files.BlockRead`/`BlockWrite` used LONGINT MOD instead of a power-of-two
  AND bit mask), exercising reads/writes that cross the 8192-byte BUFSIZE boundary.
- **TCASETBL.MOD** is the regression test for the CASE jump-table dispatch
  codegen (G7, `DOCS/IMPLRULE.MD` §"CASE jump-table dispatch"); it caught a
  real out-of-range-dispatch bug (values outside the label range fell into
  arm 1's body instead of the `ELSE`/fall-through target) that `make test`'s
  281-row manifest cannot catch, since the manifest only checks compile-time
  byte/symbol patterns, not runtime dispatch correctness. Also runnable
  standalone, bypassing `make testall`'s harness bugs:
  `toc /ENTRY=RunAllTests TCASETBL.MOD` then run the resulting `.exe`.


### Test framework (`SRC/LIB/TEST.MOD`)

Test modules register their cases with `Test.AddTest(proc, name)` and then call `Test.RunTests`.  Each `proc` is FAR (cross-module-callable) and contains a sequence of `Test.AssertX` calls.  Test.RunTests iterates the registered list, runs each procedure with a fresh `failureCount`, prints `<name> PASSED` or per-failure messages, and ends with:

```
--------------------------------------
Total: N
Passed: P
Failed: F
```

Exit code 0 if all pass, 1 if any fail; `testall.exe` uses the exit code to record pass/fail.

**Available assertions** (all take a trailing `msg: ARRAY OF CHAR`):
- `AssertTrue(cond)`, `AssertFalse(cond)`
- `AssertNil(p)`, `AssertNotNil(p)`
- `AssertByte(expected, actual)`, `AssertInt(expected, actual)`, `AssertWord(expected, actual)`, `AssertLong(expected, actual)`
- `AssertReal(expected, actual)` (with epsilon = 1.0e-6)
- `AssertStr(expected, actual)`

**Linking.** With the all-in-one `toc.exe`, linking is automatic via `/ENTRY=`:
```sh
OBERON_LIB=lib toc /ENTRY=RunAllTests MyTest.Mod my.exe
# Test.om, Out.om, SYSTEM.om etc. come from BIN/OBERON.OM automatically
```

**All tests use the framework.** Per-test `.Mod` files have been consolidated
into the 8.3-named modules listed in the module map above (`NUM`, `FLOAT`,
`CTRL`, `PROC1`, `PROC2`, `RECARR`, `PTR`, `SYS1`, `SYS2`, `STR`, plus the
import pairs `IMPCA`+`IMPCB` and `IMPPA`+`IMPPB`).  Every test ends with a
`Failed: N` line driven by `Test.RunTests`.

**Imported CONST in CASE labels.** CASE labels accept any constant expression —
including `Alias.Const`, `Alias.Const ± delta`, and arithmetic over imported and
local CONST names.  `PSTMT.MOD` routes labels through the expression parser and requires
the folded result to be a compile-time INTEGER or CHAR constant.
Coverage: `IMPCB.TConsts` exercises `I.N`, `I.N-1`, and `D` (a local CONST equal
to `I.N`) as CASE labels.

---

## Self-hosting regression test

`TESTS/test_selfhost.sh` verifies the compiler can reproduce itself byte-identically:

1. `BOOT/TOC.EXE` compiles `SRC/TOC/*.MOD` → `toc1.exe`
2. `toc1.exe` under xt recompiles the same sources → per-module `.om` files
3. `toc1.exe /ENTRY=Run` links them → `toc2.exe`
4. Assert `toc1.exe == toc2.exe` byte-for-byte, and each `.om` is byte-identical

Run manually (not part of `make test` or `make testall`):

```bash
bash TESTS/test_selfhost.sh
# … 13 passed, 0 failed
```

Skips silently if `xt` is not on `PATH` (or `$XT` is not set).

> **Host-filesystem caveat:** the gen-1 compiler is staged as `SELFTOC.EXE`, **not**
> `toc.exe`.  On a case-insensitive host filesystem (macOS) `toc.exe` and the
> compiler's own `TOC.exe` output collide on the same path, so a self-compile would
> overwrite the running binary mid-link and corrupt gen-2 (symptom: `OC.om` differs
> by 1 byte, `toc2.exe` not produced).  Keep the staged compiler name distinct from
> the `OC` output module.

---

## TASM assembler regression test

`TESTS/test_tasm.sh` verifies `SRC/TASM/` (the self-hosted NASM-subset assembler,
`.asm`→RDOFF2 `.rdf`, see `DOCS/PORTING.MD` §1.7 and `DOCS/TASM_PLAN.MD`) by byte-diffing
its output against expected `.rdf` files. 16 checks total:

1. Builds `TASM.exe` via `BOOT/TOC.EXE` (single-process `/ENTRY=Run`, same pattern as the
   compiler's own self-host).
2. **Real-NASM oracles** (3) — assembles `SRC/LIB/SYS.ASM`, `SRC/LIB/EMS.ASM`, and
   `SRC/LIB/DETECT.ASM`, byte-diffing against the checked-in `SYS.RDF`/`EMS.RDF`/
   `DETECT.RDF`, all originally produced by real NASM. This is the authoritative
   correctness signal. `DETECT.ASM` is the only `.text`-only oracle (no `SECTION
   .data`) — it caught a real bug (`RDOFF.MOD`'s `RdfWriteTo` used to skip the
   `.data` segment header entirely when `dataLen=0`, but real NASM always emits
   it) that `SYS.ASM`/`EMS.ASM`'s real `.data` sections never exercised. A later
   independent full re-verification against fresh real-NASM builds of every
   `SRC/LIB/*.ASM` file confirmed `SYS.ASM`/`EMS.ASM`/`WINCB.ASM`/`KMOUSE.ASM`
   are fully byte-identical to NASM, and `DETECT.ASM`/`SCREEN.ASM` are
   byte-identical in their code/data segments with only a benign header-record
   *ordering* difference (NASM interleaves `IMPORT` records at their point of
   declaration; TASM groups them after all `GLOBAL` records — semantically inert,
   see `DOCS/TASM_PLAN.MD`).
3. **Synthetic / self-consistency fixtures** (11) — `TESTS/FIX/TSTRUC.ASM`
   (STRUC/ENDSTRUC field-offset and `_size` arithmetic), `TEXTERN.ASM`
   (EXTERN/IMPORT cross-module relocations), `TMULDIV.ASM` (IMUL/DIV/IDIV
   F6/F7-group encoding), `TSHIFT.ASM` (shift/rotate-by-1-or-CL), `TJCC2.ASM`
   (Jcc encoding), `TNOOP4.ASM` (no-operand opcodes), `TREP.ASM` (LOCK/REP
   prefixes + LODSB/LODSW/STOSB/STOSW), `TBSS.ASM` (`SECTION .bss`
   RESB/RESW/RESD + `RDFREC_BSS` + BSS-target RELOC coverage), plus
   `SRC/LIB/WINCB.ASM` (stack-argument LES/RETF-imm16 pattern),
   `SRC/LIB/KMOUSE.ASM` (direct-memory `MOV [label],AL` / stack-argument
   byte-flag pattern), and `SRC/LIB/SCREEN.ASM` (`CALL FAR` cross-module
   relocations to `SYSTEM.Seg0040`/`KMouse_Mouse*`, and `LDS` encoding). No
   independent NASM oracle backed these when first written — the expected
   `.rdf` was TASM's own previously-verified output, a regression guard rather
   than an independent correctness proof — but `WINCB`/`KMOUSE`/`SCREEN` have
   since also been confirmed against real NASM (see point 2 above). Re-derive
   the expected `.rdf` by hand whenever a fixture changes.
4. **Error-path fixtures** (2, `check_fails`) — `TESTS/FIX/TBADIF.ASM` (an
   unterminated `%ifdef` must be a fatal error, not silently accepted) and
   `TESTS/FIX/TBADRES.ASM` (`RESB`/`RESW`/`RESD` outside `SECTION .bss` must be
   a fatal error).

Run as part of `make test` (see `Makefile`'s `test:` target), or standalone:

```bash
bash TESTS/test_tasm.sh
# Results: 16 passed, 0 failed
```

Skips silently if `xt` is not on `PATH` (or `$XT` is not set).

---

## Debug-info regression test

`TESTS/test_dbg.sh` verifies the `$D+`/`/G` TDS debug-info invariants
(design: `DOCS/OBERLANG.MD` §"Debug info",
`DOCS/IMPLRULE.MD` §".DBG file format"):

1. **Pure append**: the non-`/G` `.exe` is an exact byte prefix of the `/G`
   `.exe` (same MZ header/code/data — only the trailing TDS block differs),
   and the `/G` exe runs with the same exit code.
2. **Round-trip**: `BIN/TDINFO.EXE` parses the `/G` exe and reports the
   expected module, source file, proc + global symbols, and a line table.
3. **Always-present `.DBG` member**: `$D+` `.om` carries a non-empty
   `MODNAME.DBG`; a no-`$D` `.om` carries a **0-byte** one (checked with
   `tolib list`).
4. **Mixed build**: only the `$D+` module contributes records (`modules:1`).

Run manually (not part of `make test`):

```bash
bash TESTS/test_dbg.sh
# PASS: debug-info (/G) regression
```

Fixtures: `TESTS/FIX/DBGINFO.MOD` (`$D+`), `TESTS/FIX/DBGOFF.MOD` (no `$D`).
The fast per-row checks live in the manifest under `dbg/*`.
`BIN/TDINFO.EXE` (from `SRC/TOOLS/TDINFO.MOD`) is the TDS block inspector —
it locates the `0x52FB` block at the MZ image end and dumps header, modules,
symbols, source files (with DOS timestamp), line numbers and segments.

**Compiler module list** (`SRC/TOC/`):

| Module file  | Role                            |
|--------------|---------------------------------|
| `SCAN.MOD`   | Scanner (Scan)                  |
| `RDOFF.MOD`  | RDOFF2 object file r/w (Rdoff)  |
| `TAR.MOD`    | ustar archive r/w (Tar)         |
| `SYMS.MOD`   | Symbol table (Syms)             |
| `CGEN.MOD`   | Code generator (Cgen)           |
| `DEF.MOD`    | .def writer/reader (Def)        |
| `IMPORT.MOD` | .om import resolution (Import)  |
| `PEXPR.MOD`  | Expression parser (PExpr)       |
| `PSTMT.MOD`  | Statement parser (PStmt)        |
| `PARSER.MOD` | Top-level parser (Parser)       |
| `LINK.MOD`   | Smart linker (Link)             |
| `TOC.MOD`     | Entry point + build driver (OC)   |

**Known dialect restrictions** (enforced by the compiler itself):
- No `LOOP`/`EXIT` — use `WHILE ~done DO ... END` pattern
- No `SHORT()` — use direct assignment for LONGREAL→REAL coercion
- No `SYSTEM.VAL/GET/PUT` — use `POINTER TO T` and `p^` dereference
- `SYSTEM.AND(x, LONGINT(0FFFFH))` instead of `INTEGER MOD 65536`
- All `SYSTEM.*` intrinsics require the `SYSTEM.` qualified prefix

---

## xt emulator reference

```
xt run   [--max=N] [-c dir] program [args]   # run .EXE/.COM, print stdout
xt trace [--max=N] [--bp=SEG:OFS[:COND]]...
         [--wp=SEG:OFS:type]...
         [--dump=SEG:OFS:LEN]...  program    # trace with register/stack dump per insn
xt int                                        # list supported DOS interrupts
```

**`xt run` options:**
- `--max=N` — stop after N instructions (ALWAYS use to prevent infinite loops)
- `-c dir` — host directory used as the C: drive root (default: cwd)
- `--env=KEY=VALUE` - allow pass environment variables
- Output is DOS CRLF (`\r\n`); always strip CR: `| tr -d '\r'`
- Exit code 255 = emulator error; otherwise = program exit code

**`xt trace` options:**
- `--max=N` — stop after N instructions (mandatory)
- `--bp=SEG:OFS` — breakpoint at hex address; e.g. `--bp=00A0:0020`
- `--bp=SEG:OFS:COND` — conditional: `AX==1234`, `FLAGS.ZERO==1`, etc.
  Supported regs: `AX BX CX DX SI DI BP SP DS ES SS FLAGS.CARRY FLAGS.ZERO FLAGS.OVERFLOW`
- `--wp=SEG:OFS:r|w|a` — watchpoint (read/write/access)
- `--dump=SEG:OFS:LEN` — hex dump of memory region at stop
- `--env=KEY=VALUE` - allow pass environment variables
- Does NOT support `-c`; run from the directory containing the `.EXE`
- Trace format per instruction: `CS:IP | bytes | disasm | registers | SS:SP | FLAGS`
- After stop: full register dump + 32-word stack dump

**Memory layout (EXE files):**
- PSP: `0x0090:0x0000` (256 bytes)
- Code: starts at `0x00A0:0x0000`
- Stack: `0xF000:0xF000`

**Supported interrupts:** INT 20/21 (DOS), INT 1A (time), INT 2F (XMS/clipboard), INT 67 (EMS).
Key INT 21 functions: 02 (write char), 09 (write string), 3C/3D/3E/3F/40/41/42 (files),
48/49/4A (memory), 4B00 (EXEC), 4C (terminate).

---

## Adding tests

### New Oberon unit test (Section 18)

Add a `TXXX.MOD` in `TESTS/` following the existing T*.MOD pattern:
- Import `Test, Xxx` (the module under test, e.g. `Scan`, `Cgen`, `Rdoff`)
- Write `PROCEDURE TFoo*` procedures using `Test.AssertXxx`
- Register with `Test.AddTest(TFoo, "name")`; run with `Test.RunTests`
- Add to `RunSection18` in `TESTS/TESTALL.MOD` (deps and link args)

### New executable test (Section 17)

Write `MYTEST.MOD` in `TESTS/` with `PROCEDURE RunAllTests*`.  Add to:
1. `RunSection17` in `TESTS/TESTALL.MOD` (compile + link + run call)
2. The consolidated module map table in this document

### New manifest test (preferred for compiler-output checks)

Add a fixture `.MOD` to `TESTS/FIX/` (8.3 uppercase name), then append a row to
`TESTS/MANIFEST.TSV`.  Row format:

```
name<TAB>FIXTURE.MOD<TAB>oc-flags<TAB>EXPECT<TAB>arg
```

Common EXPECT values: `code-starts`, `has-import`, `has-global`, `compile-fails`,
`errorlevel`, `om-has-file`, `mz-sp`.  See the full vocabulary in the
"Manifest tests" section above.

### New stderr-text check

Use the `stderr-contains` or `stderr-no-contains` EXPECT predicates in the manifest.
These are evaluated by `Makefile.man` on the host (captures stderr to a temp file)
and by `testall.exe` on DOS (currently passed through — stderr goes to the console
and is not captured; these rows always PASS in testall).

