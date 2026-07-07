# Build Guide

## Toolchain binaries

| Binary | Source | Purpose |
|--------|--------|---------|
| `BOOT/TOC.EXE` | checked-in MS-DOS binary | Bootstrap compiler — seeds the self-hosted build; **never modified by `make`** |
| `BOOT/TOLIB.EXE` | checked-in MS-DOS binary | Bootstrap archive manager — used only during stdlib merge; **never modified by `make`** |
| `BIN/TOC.EXE` | `SRC/TOC/` (Oberon) | **All-in-one** MS-DOS build tool: dep-scan + incremental compile + smart link |
| `BIN/TOLIB.EXE` | `SRC/TOOLS/` (Oberon) | .OM archive manager (list/extract/create/merge); supports `@listfile` |
| `BIN/RDFGREP.EXE` | `SRC/TOOLS/` (Oberon) | RDOFF/.om/.exe introspection for tests |
| `BIN/TDINFO.EXE` | `SRC/TOOLS/` (Oberon) | TDS/TDINFO (0x52FB) debug-block inspector for `.exe` files |
| `BIN/TOSTRIP.EXE` | `SRC/TOOLS/` (Oberon) | Strips debug info from `.exe` (TDS block) or `.om` (`.DBG` member) files |

All binaries are MS-DOS MZ executables that run on real MS-DOS or under `xt`.
`BOOT/TOC.EXE` and `BOOT/TOLIB.EXE` are the only pre-built binaries in the repository;
everything else is built from Oberon source by the bootstrap.

---

## Building on Linux / Mac

```bash
make          # full build: stdlib → BIN/TOC.EXE → BIN/TOLIB.EXE → tools → OBERON.OM
make test     # clean rebuild + run 265 manifest tests (host-side, fast)
make testall  # full DOS-side suite via xt: manifest + Section 17/18 (~9 min)
```

### Build sequence

```
BOOT/TOC.EXE (via xt)
  └─ SRC/LIB/*.MOD  →  SRC/LIB/*.om   (standard library)
  └─ SRC/TOC/*.MOD   →  SRC/TOC/*.om   →  BIN/TOC.EXE  (compiler/linker)

BIN/TOC.EXE (via xt)
  └─ SRC/TOOLS/TOLIB.MOD   → BIN/TOLIB.EXE
  └─ SRC/TOOLS/RDFGREP.MOD → BIN/RDFGREP.EXE
  └─ TESTS/TESTALL.MOD     → BIN/TESTALL.EXE
  └─ SRC/TOOLS/TDINFO.MOD  → BIN/TDINFO.EXE
  └─ SRC/TOOLS/TOSTRIP.MOD → BIN/TOSTRIP.EXE

BOOT/TOLIB.EXE (via xt)
  └─ SRC/LIB/*.om  →  BIN/OBERON.OM   (merged standard library; individual .om removed)
```

### Per sub-project

```bash
cd SRC/TOC   && make && make install   # → BIN/TOC.EXE
cd SRC/TOOLS && make                   # → BIN/TOLIB.EXE, BIN/RDFGREP.EXE, BIN/TDINFO.EXE, BIN/TOSTRIP.EXE
```

---

## Using the compiler

### Compile a module

```bash
xt run --max=50000000 -c . BIN/TOC.EXE File.Mod
# → File.om  (File.rdf + File.def packed, then deleted)
```

Normal output:
1. Writes `ModName.rdf` and `ModName.def` as intermediates
2. Packs them into `ModName.om` (ustar tar)
3. Deletes `ModName.rdf` and `ModName.def` — only `.om` remains
4. On error: intermediates deleted, no `.om` written

**Exit code & cleanup.** Every run ends at a **single** `SYSTEM.Halt(code)` in
`TOC.Run` (`code` = 0 on success, 1 on any error), reached only after `TOC.Cleanup`
closes all temp files (module-graph, symbol/type, `RDFCODE`/`RDFDATA`) and frees
the heap.  No internal step aborts the process — errors are returned/latched up to
the driver — so even a failed compile or link leaves **no leaked temp file and no
half-written `.exe`/`.om`** behind.

> **Import resolution:** the compiler reads `.def` content **only from inside `.om` archives**
> (via tar extraction). Standalone `.def` files are ignored — they may be stale crash artifacts.
> To create a stub import for testing, use `xt run BIN/RDFGREP.EXE make-stub OUT.OM MODNAME`.

### Compile the SYSTEM module itself

`SYSTEM.om` is built from two sources:

- `SRC/LIB/SYSTEM.MOD` — Oberon source for the SYSTEM module (compiled with `/SYSTEM`)
- `SRC/LIB/SYS.RDF` — pre-assembled RDOFF2 object for `SRC/LIB/SYS.ASM` (hand-assembled helpers);
  packed into the output `.om` via a `(*$LSYS.RDF*)` directive in `SYSTEM.MOD`

```bash
# Done automatically by: cd SRC/LIB && make install
xt run --max=50000000 -c . 'BOOT/TOC.EXE' /SYSTEM 'SRC/LIB\SYSTEM.MOD'
```

**IMPORTANT — `SYS.RDF` is a checked-in binary:**
`SRC/LIB/SYS.RDF` is the pre-assembled RDOFF2 object for `SRC/LIB/SYS.ASM`.
`SRC/LIB/Makefile` has **no rule** to rebuild it from `SYS.ASM`.
After editing `SYS.ASM`, you must manually reassemble with a RDOFF2-capable NASM
(older version) or patch the binary directly, then run `cd SRC/LIB && make install`.

The `/SYSTEM` flag disables the implicit SYSTEM import that every other module receives:
- No `SYSTEM.def` is auto-loaded at startup
- `IMPORT SYSTEM` in the source is allowed (not rejected as it would be normally)
- `SYSTEM__init` is never emitted as an `__init` dependency (same rule as normal modules)
- All other compiler behaviour is unchanged (SYSTEM universe built-ins remain pre-declared)

### Include extra .rdf files in the output .om

Use the `$L` system comment directive in the source file to pack an additional `.rdf` into
the `.om` archive alongside the compiled module's own `.rdf` and `.def`:

```oberon
(*$L helper.rdf*)       (* block-comment form *)
//$L helper.rdf         (* line-comment form  *)
```

The directive is processed during scanning and may appear anywhere in the source.  The file
is stored in the archive under `MODNAME/<BASENAME>.RDF` where `MODNAME` is the uppercased
module name and `BASENAME` is the uppercased filename (directory part stripped).  This
prefix prevents member-name collisions when multiple `.om` files are merged into `OBERON.OM`.
Up to 128 extra `.rdf` files total.

If a `$L` path cannot be opened or read, the compiler reports an error and compilation fails.

### Set memory triple ($M)

Use the `$M` system comment directive to declare the program's memory needs:

```oberon
(*$M 10240, 128000, 650000*)   (* 10 KB stack, 128 KB min heap, ~635 KB max heap *)
//$M 8192, 0, 0                 (* line-comment form; 8 KB stack, no heap *)
```

Syntax: `$M stack_bytes, min_heap_bytes, max_heap_bytes` — three comma-separated decimals.

- `stack_bytes`: 1..65536.  Hint for the DOS stack segment; with `/ENTRY=` this value is
  written as `META-INF/STACK.TXT` inside the `.om`, and the linker sets the MZ SP field
  to `stack_bytes - 2`.
- `min_heap_bytes`, `max_heap_bytes`: 0..640*1024 (655360).  The compiler rounds each
  UP to 16-byte paragraphs (4 bytes → 1 paragraph; 0 → 0).  When generating MAIN.RDF
  for `/ENTRY=`, it emits `MOV AX,min_para; MOV BX,max_para` before the `CALL FAR
  SYSTEM_INIT`; the runtime then asks DOS to allocate at least `min_para` paragraphs,
  clamps to the actually-available amount but no more than `max_para` paragraphs.

Constraints:
- `min_heap_bytes <= max_heap_bytes`.
- All three values are mandatory.  The legacy single-value form `$M N` is rejected.
- Multiple `$M` directives: last wins.

Defaults (when no `$M` is present): `stack=8192, min=131072, max=262144` bytes
(8 KB / 128 KB / 256 KB).  Without `/ENTRY=` the directive is parsed and validated
but no STACK.TXT is written and no prologue is generated.

#### How this interacts with the MZ EXE header

The linker (embedded in `toc.exe`) sets the MZ `min_alloc` and `max_alloc` fields to exactly
the paragraphs the program needs above the file image for BSS-extension plus
the stack — `(data_bss_para − ceil(data_in_file/16)) + ceil(stack_bytes/16)` —
with `max_alloc = min_alloc`.  This leaves any remaining DOS free memory
available for the runtime heap and for `Dos.Exec` children.

Any violation (range, format, ordering) is a fatal compile error mentioning `$M`;
no output `.om` is produced.

### Compile with entry point

```bash
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=ProcName File.Mod
# → File.exe (compiled + linked in one step)
```

Also generates `MAIN.RDF` (packed into `File.om`) containing:
```asm
CALL FAR SYSTEM_INIT        ; runtime init   (import seg 3)
CALL FAR ModName__init      ; module init    (import seg 5)
CALL FAR ModName_ProcName   ; entry proc     (import seg 6)
CALL FAR SYSTEM_DONE        ; DOS exit       (import seg 4)
```
`MAIN.RDF` exports GLOBAL `start` at offset 0 (linker entry point).

---

## Source layout

```
oberonc/
  BOOT/               Bootstrap DOS binaries (immutable — updated manually)
    TOC.EXE              All-in-one compiler/linker/dep-scan (MS-DOS MZ)
    TOLIB.EXE            Archive manager (MS-DOS MZ)
  SRC/                Oberon source for all tools
    TOC/                Compiler + linker (Main, Parser, Link, …)
      SCAN.MOD          Scanner (Scan)
      RDOFF.MOD         RDOFF2 object file read/write (Rdoff)
      TAR.MOD           ustar archive read/write (Tar)
      SYMS.MOD          Symbol table (Syms)
      CGEN.MOD          Code generator (Cgen)
      DEF.MOD           .def file writer/reader (Def)
      IMPORT.MOD        .om search and loading (Import)
      PEXPR.MOD         Expression parser (PExpr)
      PSTMT.MOD         Statement parser (PStmt)
      PARSER.MOD        Top-level parser: module, decls, types (Parser)
      LINK.MOD          Smart linker — embedded in toc.exe (Link)
      TOC.MOD            Entry point + build-driver (OC)
    TOOLS/              Test tools
      TOLIB.MOD
      RDFGREP.MOD
  SRC/LIB/            Standard library Oberon sources + SYSTEM assembly
  BIN/              Built binaries + OBERON.OM (all output here after make)
  TESTS/              Test suite
  DOCS/               Documentation
```

---

## Running `BIN/TOC.EXE` on real MS-DOS

Copy `BIN/TOC.EXE` and `BIN/OBERON.OM` to the DOS machine.

```
REM Optional — toc.exe also finds OBERON.OM from its own directory automatically:
SET OBERON_LIB=C:\bin\OBERON.OM
toc.exe Hello.Mod               REM compile-only → Hello.om
toc.exe /ENTRY=Run Hello.Mod    REM compile + link → Hello.exe
```

### On Linux / Mac (via xt emulator)

On the host, run them with the `xt` emulator. See [XT.MD](XT.MD) for full reference.

### Oberon toc.exe — command line (all-in-one)

`BIN/TOC.EXE` is the primary build tool.  It handles dependency scanning,
incremental compilation, and linking in a single invocation.

```
toc.exe [/ENTRY=Proc] [/SYSTEM] [/M] [/G] <Root.Mod>
```

Switches are case-insensitive (`/M`=`/m`, `/SYSTEM`=`/system`, `/ENTRY=`=`/entry=`);
the `/ENTRY=` value keeps its case.  Any other option is a fatal `unknown option`.

**Two modes:**

| Command | Behaviour |
|---------|-----------|
| `toc.exe Root.Mod` | **Compile-only**: scan transitive deps, recompile stale modules, emit `.om` files. No linking. Used for libraries. |
| `toc.exe /ENTRY=Run Root.Mod` | **Compile + link**: scan deps, compile stale modules, link all `.om` → `Root.exe` (auto-named). |

- `/ENTRY=ProcName` — triggers the link phase; output is named `<ModName>.exe` (auto-derived from module name).
- `/M` — recompile all modules even if `.om` is up-to-date (the old `-force`).
- `/SYSTEM` — single-file compile for the `SYSTEM` module itself (`SYSTEM.MOD`); no dep-scan.
- `/G` — at link time, merge the `MODNAME.DBG` members of modules compiled with
  `(*$D+*)` into a Borland Turbo-Debugger (TDS/TDINFO v2.08) block **appended**
  to the `.exe`.  Without `/G` the `.exe` is byte-identical to before the
  feature existed; with `/G` the loaded program is unchanged too (DOS never
  loads the trailing block — debugger-only data).  Inspect with
  `BIN/TDINFO.EXE FILE.EXE`.  Details: `DOCS/OBERLANG.MD` §"Debug info",
  `DOCS/IMPLRULE.MD` §".DBG file format", `DOCS/TD-SPEC.MD`.

```bash
# Compile a library (no /ENTRY=): transitive dep scan + incremental compile
xt run --max=50000000 -c . BIN/TOC.EXE MyLib.Mod

# Build an executable (with /ENTRY=): compile + link in one step → MyProg.exe
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run MyProg.Mod

# Force full recompile + link
xt run --max=50000000 -c . BIN/TOC.EXE /M /ENTRY=Run MyProg.Mod

# Build with Turbo-Debugger debug info (modules with (*$D+*) contribute)
xt run --max=50000000 -c . BIN/TOC.EXE /G /ENTRY=Run MyProg.Mod
```

**Check exit code.** Non-zero = error.  xt itself exits 255 on emulator error.

### Setup checklist

Before running toc.exe under xt:

1. All files that xt programs read/write must be under the `-c dir` mount root.
2. `OBERON_LIB` uses **DOS path syntax** (`C:\lib\OBERON.OM`); set it before invoking.
3. `BIN/OBERON.OM` must be present — it is the merged standard library.
4. Remove any stale zero-byte `.OM` files — they confuse the dep-scan staleness check.

**CRITICAL — rebuild OBERON.OM clean before compiling importers:**
If `OBERON.OM` is stale or was built against an older compiler, modules that embed
stdlib types in their own records (e.g. a record with a `f: Files.File` field) will
read the wrong `RECORD <size>` and mislay all fields that follow, silently corrupting
data layout.  Always rebuild `BIN/OBERON.OM` from the current stdlib sources (via
`make` from the repo root, or `cd SRC/LIB && make`) before compiling any module that
imports stdlib types.

---

## Using tolib — archive manager

```
tolib list    FILE.OM
tolib extract FILE.OM MEMBER OUTFILE
tolib create  OUT.OM  FILE ...
tolib merge   OUT.OM  IN.OM ...
@listfile    (any command: expand file with one argument per line)
```

`tolib merge` copies **all** members (`.RDF` and `.DEF`) from each source archive into the
output — unlike the linker's scanner which only reads `.RDF` members.

When the argument list is too long for the 127-char DOS command line, use `@listfile`:
```bash
printf '%s\n' SRC/LIB/SYSTEM.om SRC/LIB/OUT.om SRC/LIB/STRINGS.om > merge.lst
xt run --max=50000000 -c . BOOT/TOLIB.EXE merge BIN/OBERON.OM @merge.lst
rm merge.lst
```

---

## Using tostrip — strip debug info

```
tostrip FILE
```

`FILE` is either a linked `.exe` or a compiler `.om` archive; the format is
detected from file content (MZ signature vs. ustar magic), not the extension.

- **`.exe`**: locates the Borland TDS/TDINFO v2.08 block (magic `0x52FB`)
  appended by `oc /G` after the MZ image, and truncates the file back to its
  pre-debug-info size. If no block is found (the `.exe` was never linked with
  `/G`), this is a no-op — not an error.
- **`.om`**: zeros the `.DBG` member (the per-module `(*$D+*)` debug info,
  always present in every `.om`, 0 bytes when `$D-`) while copying every other
  member through unchanged, so the archive stays a structurally valid ustar
  file with the same member names.

In both cases the original is preserved first: it is copied/renamed to
`FILE.BAK` (extension replaced, not appended, to stay 8.3-valid — e.g.
`HELLO.OM` -> `HELLO.BAK`). Any stale `.BAK` from a previous run is removed
before the new one is written.

---

## Environment variable: OBERON_LIB

`OBERON_LIB` is the way to tell `toc.exe` where to find `.om` files.

```
SET OBERON_LIB=C:\bin\OBERON.OM        (DOS / xt)
```

`BIN/TOC.EXE` uses `;` as the path separator (DOS convention).

**Search order:** current directory first, then `OBERON_LIB` entries left to right.

After `make` from the root, `BIN/OBERON.OM` is a single merged
archive of all standard library modules.  The individual `.om` files are built as
intermediates, merged, then removed.  `BIN/OBERON.OM` is the only file that needs
to be distributed or set in `OBERON_LIB`.

### OBERON.OM — merged standard library

`BIN/OBERON.OM` is a single `.om` archive containing every `.RDF` and `.DEF` member
from all standard library modules.  Both the compiler and the linker search for it
**automatically** in `OBERON_LIB` without requiring it to be named
explicitly on the command line.

**Compiler:** after failing to find `ModName.om` in the search path, the compiler
also tries `OBERON.OM` in the same directories and extracts `MODNAME.DEF` from it.
Search order: `ModName.om` (current dir) → `ModName.om` (OBERON_LIB) → `OBERON.OM`
(current dir) → `OBERON.OM` (OBERON_LIB).

**Linker:** after processing all explicitly listed `.om` files, the linker locates
`OBERON.OM` via the search path and scans it for additional symbols — silently ignored
if not found (backwards-compatible).  The smart linker only pulls in modules actually
referenced.

**Practical effect:** one command does everything:
```bash
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run Hello.Mod
# ↑ dep-scan + incremental compile + link; Out, Strings, SYSTEM from OBERON.OM
```

No need to list `Out.om`, `Strings.om`, `SYSTEM.om` etc. individually.

---

## Linker internals

The linker is embedded in `toc.exe` (`SRC/TOC/LINK.MOD`).  Two architectural details
are worth knowing when debugging large programs or link failures:

**Code-group streaming.**  The linker processes one code group (one module's code
segment) at a time.  Each group buffer is allocated, loaded, its RELOC/SEGRELOC
records are applied, and the bytes are immediately appended to a temporary spill file
(`LNKCODE.TMP`).  The buffer is then freed before the next group is loaded.  Groups
are written sequentially, with each group padded at the start to a 16-byte-aligned
offset using explicit zero bytes.  Peak code memory = one group at a time; the spill
file is copied into the final `.exe` during the `WriteExe` step and then deleted.
This design allows the compiler+linker to self-link a 185 KB+ executable inside the
DOS 640 KB conventional memory envelope.

**RDF / `.def` deduplication.**  When the same `.om` file appears more than once in
the link input (e.g. because it is listed explicitly and also found in `OBERON.OM`),
the linker deduplicates at the RDF level: the first-scanned `.om` wins; subsequent
occurrences of the same RDF (identified by their first exported GLOBAL symbol) are
silently skipped.  Similarly, the compiler (`IMPORT.MOD`) deduplicates `.def` loading
at the alias level: if a module alias was already loaded, the `.def` is not re-read.
This prevents the "two copies of SYS.RDF linked in" problem that would result in two
separate code segments for the same runtime helper, each with its own `MemStartSeg`
copy, causing `SYSTEM.MemAvail()` to read from the wrong segment.  The lesson:
**avoid shipping the same RDF member in both a dedicated `.om` and `OBERON.OM`.**

---

## Bootstrap rule

`BOOT/TOC.EXE` and `BOOT/TOLIB.EXE` are **never updated by `make`**.
They are updated manually by the maintainer after verifying that the newly built
`BIN/TOC.EXE` is byte-identical to the previous one (self-hosting test).
This guarantees a reproducible build from any clean checkout.

## Single-command self-host

The whole compiler builds in one process (no module-by-module make):

```bash
cd SRC/TOC
xt run --max=4000000000 -c . ../../BIN/TOC.EXE /ENTRY=Run TOC.MOD   # → TOC.exe
```

Building `TOC.exe` this way, then rebuilding again from that output, yields a
**byte-identical** `TOC.exe` (toc2 == toc3) — the self-host fixpoint.  This works
because every phase reports **0 leaked paragraphs**: the per-module heap leak is
0 (BUG 2 / `IdListFree`) so the 12-deep import tree fits in one process, and the
link of the large image stays uncorrupted because `ModEntryDefrag` frees the
long-lived dep-scan graph before the link (keeping the arena contiguous for the
code-group buffers).  See
[IMPLRULE.MD](IMPLRULE.MD) §"Compile→link defrag".

## Refreshing `BOOT/TOC.EXE` (maintainer step)

When `BIN/TOC.EXE` has been verified byte-stable (`TESTS/test_selfhost.sh`, or
the single-command toc2 == toc3 check above), copy it over the bootstrap:

```bash
cp BIN/TOC.EXE BOOT/TOC.EXE        # manual; never done by make
```

After a Parser-affecting fix (e.g. a new BUG 2-class leak fix), the **old**
`BOOT/TOC.EXE` may not be able to build `SRC/TOC` at all (it stops at
`error: cannot write Parser.rdf`).  Refresh it as above so the normal `make`
path works again.  Keep a known-good `BIN/TOC.EXE` (or one of the `BIN/*.bak-*`
backups) on hand as the source for such a refresh.
