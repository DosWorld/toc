# Porting Guide — Oberon-07 for MS-DOS (Real Mode 16-bit, 8086)

This document is for an AI agent (or developer) porting software from another language to
this Oberon-07 compiler targeting MS-DOS real-mode 16-bit.  It covers the dialect,
restrictions, the 8086 architecture constraints, common programming tricks, the standard
library modules, and the command-line toolchain.

---

## 1. Toolchain overview

### 1.1 Tools at a glance

| Binary | Purpose |
|--------|---------|
| `BOOT/TOC.EXE` | Bootstrap MS-DOS compiler — seeds the build; **never modified by `make`** |
| `BOOT/TOLIB.EXE` | Bootstrap archive manager — used during stdlib merge; **never modified by `make`** |
| `BOOT/TASM.EXE` | Bootstrap MS-DOS assembler (NASM subset, `.asm`→`.rdf`) — seeds `SRC/LIB/Makefile`'s `regen-asm` step; **never modified by `make`**, installed manually by the maintainer only |
| `BIN/TOC.EXE` | **All-in-one** MS-DOS build tool: dep-scan + incremental compile + smart link |
| `BIN/TOLIB.EXE` | `.om` archive manager (list / extract / create / merge); supports `@listfile` |
| `BIN/TASM.EXE` | Self-hosted MS-DOS assembler, built via `SRC/TASM/Makefile` from `BOOT/TASM.EXE` |
| `BIN/TLINK.EXE` | Merged RDOFF2 linker for tiny-model `.COM`/`.SYS`/`texe` and small-model `.EXE`, built via `SRC/TLINK/Makefile` |
| `BIN/RDFGREP.EXE` | RDOFF/.om/.exe introspection tool (used in tests) |
| `xt` | DOS emulator; runs MS-DOS `.exe` files on Linux/Mac |

### 1.2 `toc.exe` — all-in-one build tool

```
toc.exe [/ENTRY=Proc] [/SYSTEM] [/M] Root.Mod
```

`BIN/TOC.EXE` is the primary build tool for MS-DOS.  It handles dep-scan, incremental compilation, and linking in a single command.

Switches use the DOS `/` style and are case-insensitive (`/M` = `/m`, `/SYSTEM` =
`/system`, `/ENTRY=` = `/entry=`).  The `/ENTRY=` value (the procedure name) keeps
its case.  There are exactly three switches — any other `-…`/`/…` token is a fatal
`unknown option` error.

**Two modes determined by `/ENTRY=`:**

| Command | Behaviour |
|---------|-----------|
| `toc.exe Root.Mod` | **Compile-only**: scan transitive deps, recompile stale modules, emit `.om` files. No linking. Use for libraries. |
| `toc.exe /ENTRY=Proc Root.Mod` | **Compile + link**: scan deps, compile stale modules, link → `Root.exe` (auto-named from `<ModName>.exe`). |

- `/SYSTEM` — single-file compile for the `SYSTEM` module itself (`SYSTEM.MOD`); no dep-scan or link.  Not usable for any other module.
- `/M` — recompile all modules regardless of staleness (the old `-force`).

**Import resolution:** the compiler finds imported modules by searching for `ModName.OM` in:
1. Current directory
2. Directory containing `toc.exe` (the exe directory)
3. Each file listed in `OBERON_LIB` (`;`-separated `.OM` file paths)
4. `OBERON.OM` in current directory (merged standard library — fallback)
5. `OBERON.OM` in exe directory (fallback)

Only `.om` archives are read — standalone `.def` files are ignored.

**Error messages** go to stderr.  Exit code 0 = success, non-zero = failure.

### 1.3 Linking — integrated in `toc.exe`

The linker is now built into `toc.exe`.  Pass `/ENTRY=ProcName` to trigger linking:

```
toc.exe /ENTRY=Run MyProg.Mod   → MyProg.exe (auto-named from the module name)
```

`OBERON.OM` (the merged standard library) is loaded automatically — no need to list
individual `.om` files.  `toc.exe` handles dep-scan, compile, and link in one step.

Linking is fully integrated — no separate linker binary is needed.

### 1.4 `xt` — DOS emulator

```
xt run [--max=N] [-c dir] [-e KEY=VALUE] program.exe [args]
xt trace [--max=N] [--bp=SEG:OFS] ... program.exe
```

- Runs MS-DOS MZ executables on Linux/Mac.
- `-c dir` — mount `dir` as the DOS `C:` drive root.  All file paths the DOS program sees start from here.
- `-e KEY=VALUE` — set an environment variable for the DOS process.
- `--max=N` — stop after N instructions (always use to avoid infinite loops during development).
- Exit code 255 = emulator error; otherwise = the DOS program's exit code.
- Output is DOS CRLF (`\r\n`); pipe through `| tr -d '\r'` on Unix if needed.
- `xt trace` produces a per-instruction log: registers, stack, flags — essential for debugging.

**Running the Oberon compiler under xt:**
```bash
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run MyModule.Mod
```

### 1.5 No separate build scripts needed

`toc.exe` is all-in-one: dep-scan, incremental compilation, and linking happen in one
invocation.  There is no separate linker binary, no separate dep-scanner, and no
build-script generator.

```bash
# Single command: dep-scan + compile + link
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run MyProg.Mod
```

`toc.exe` automatically recompiles only stale modules (pass `/M` to recompile
everything).  `OBERON.OM` is found automatically in CWD or in the exe directory.

### 1.6 `tolib` — archive manager

```
tolib list    File.om
tolib extract File.om MemberName OutFile
tolib create  File.om member1 member2 ...
tolib merge   Out.om  In1.om In2.om ...
@listfile     (any command: expand file with one argument per line)
```

Used to inspect or manipulate `.om` archives.  `merge` combines multiple archives into one,
copying all members (`.RDF` and `.DEF`).  When the argument list exceeds the 127-character
DOS command-line limit, pass `@listfile` with one path per line.

### 1.7 `tasm.exe` — self-hosted NASM-subset assembler

```
tasm.exe [/LOG=level] File.asm
tasm.exe /BIN=code|data /NAME=GlobalName [/LOG=level] File.bin
```

`BIN/TASM.EXE` assembles a NASM-subset `.asm` source file straight to a single RDOFF2
`.rdf` object — **no other output format**.  Exactly one positional argument is accepted
(the `.asm` path); the output filename is auto-derived (`File.asm` → `File.rdf`).  `/LOG=`
works exactly like `toc.exe`'s (`/LOG=debug|info|warn|error`, case-insensitive).

**bin2obj mode** (`/BIN=code|data /NAME=GlobalName File.bin`, 2026-07-16):
converts any binary file (< 64 KB, strictly — the real limit is
`Rdoff.SegLimit-1` = 64999 bytes, one 16-bit segment) into an RDOFF2
object with the blob as `/BIN=`'s named segment's entire content and one
GLOBAL record (named by `/NAME=`) at offset 0 — no RELOC/IMPORT/BSS
records. Does not touch the Scan/Sym/Parse/Enc assembler pipeline at all;
a separate branch in `TASM.MOD` that builds the RDOFF2 object directly
via `Rdoff` (`Files.BlockCopy` straight into the `ObjFile`'s own
code/data temp file, the same pattern `Rdoff.RdfLoad` itself uses to
read a segment back out of a `.rdf`). `/NAME=` is required in this mode
and validated as an identifier (first-char alpha/`_`/`$`/`?`/`@`, rest
ident chars, length ≤ 63) — invalid or missing names are a usage error,
never silently truncated or ignored. `/BIN=bss` is not offered (a blob
has content; BSS is contentless by definition). Inspect the result with
`rdfgrep has-global`/`code-contains`/`data-contains` (see
`DOCS/TESTS.MD`).

Covers a practical 8086 subset: the general-purpose/segment/string instructions
(including `LDS`/`LES`), shift/rotate (by 1 or `CL` only, matching real 8086),
`MUL`/`DIV`/`IMUL`/`IDIV`, `Jcc`, `LOCK`/`REP` prefixes, `BITS`/`CPU`/
`SECTION .text|.data|.bss`/`GLOBAL`/`EXTERN` (with `IMPORT` as a TASM-added
synonym)/`STRUC`/`ENDSTRUC`/`RESB`/`RESW`/`RESD` (valid only inside
`SECTION .bss`)/`%DEFINE`/`%UNDEF`/`%IFDEF`/`%ELSE`/`%ENDIF`/`%INCLUDE`/
`%MACRO`/`%ENDMACRO`/`DB`/`DW`/`TIMES`, plus `SEG`/`BYTE`/`WORD`/`FAR`/
`SHORT`/`NEAR` operand qualifiers, character-literal immediates, and
`-Dname[=value]` CLI predefines.  `EXTERN`/`IMPORT` symbols resolve through
RDOFF2 `RDFREC_IMPORT` records, so a `.rdf` produced by `tasm` can reference
symbols defined in another module exactly like one produced by real NASM
(`CALL FAR`, not a bare `CALL`, is required for such cross-module calls — see
§16.1 below). **Not supported:** `[label+register]` combined addressing (a
data-segment label combined with a base register in one bracket) — load the
label address into a register first, then add the index register separately;
`%macro` default/greedy params (`%macro x 1-3`), `%0`, `%rotate`, `%rep`,
`%ifmacro`, macro overloading by arity; `%if`/`%elif` numeric preprocessing
(only `%ifdef` exists).

`%include "FILE.INC"` (2026-07-16): textual inclusion, resolved relative to
CWD (no search path). Nested up to 8 levels deep (`Parse.MaxSrcDepth`); a
cycle (a file including itself, directly or transitively) is a fatal
"recursive %include" error. Skipped without opening the file at all when
inside a false `%ifdef` branch — the `%ifdef DOS_BUILD / %include
"dosonly.inc"` idiom works even when `dosonly.inc` doesn't exist on this
build.

`%macro NAME NPARAMS ... %endmacro` (2026-07-16): `%1`..`%9` parameter
substitution (`NPARAMS` 0..9) and `%%ident` macro-local-label uniquing
(expands to `?Mk?ident`, `k` a per-invocation counter). A macro body is
captured as raw text (byte-exact, comments/strings/spacing preserved) up
to a fixed 4096-byte cap (`Scan.MaxMemText`); nested `%macro` and macro-
invokes-itself recursion (past the same 8-level source-stack depth as
`%include`) are both fatal errors, not hangs or silent mis-scoping.

`tasm` is the tool of record for six hand-written `SRC/LIB/*.asm` files:
`SYSTEM.ASM`→`SYSTEM.RDF`, `EMS.ASM`→`EMS.RDF`, `DETECT.ASM`→`DETECT.RDF`,
`WINCB.ASM`→`WINCB.RDF`, `KMOUSE.ASM`→`KMOUSE.RDF`, and
`SCREEN.ASM`→`SCREEN.RDF`.  It is **not** a prerequisite of `make all` —
`tasm` itself needs a fully-built `OBERON.OM`, which in turn is built from
`SYSTEM.RDF`, so making `tasm` a hard build dependency would be circular.
Instead, all six `.RDF` files are checked into the repo, and regenerated only
via the manual `SRC/LIB/Makefile` target `regen-asm` (uses `BOOT/TASM.EXE`,
not `BIN/TASM.EXE`). See [BUILD.MD](BUILD.MD) §"Refreshing `BOOT/TASM.EXE`"
for the maintainer-only install step — like `BOOT/TOC.EXE`, `BOOT/TASM.EXE`
is never touched by `make` and is installed manually by the maintainer only.
`SYSTEM.ASM`/`EMS.ASM`/`WINCB.ASM`/`KMOUSE.ASM` are fully byte-identical to real
NASM output; `DETECT.ASM`/`SCREEN.ASM` are byte-identical in code/data with
only a benign header-record ordering difference. See `DOCS/IMPLRULE.MD`
§"TASM — design decisions and known limitations" for the resolved design
questions (jump sizing, FPU/`%define` scope, CLI conventions) and the
`[label+register]` addressing limitation.

Source: `SRC/TASM/{SCAN,SYM,LEX,DIR,ENC,PARSE,TASM}.MOD`.  Tests:
`TESTS/test_tasm.sh` — 16 checks: 3 real-NASM oracles (`SYSTEM.ASM`/`EMS.ASM`/
`DETECT.ASM`), 11 byte-diff self-consistency/synthetic fixtures (incl.
`WINCB.ASM`/`KMOUSE.ASM`/`SCREEN.ASM` and the `TESTS/FIX/*.ASM` STRUC/EXTERN/
shift/Jcc/no-operand/REP/`.bss` fixtures), 2 `check_fails` error-path
fixtures — run as part of `make test`. See `DOCS/TESTS.MD` §"TASM assembler
regression test" for the full breakdown.

### 1.8 `tlink.exe` — Trubo Link (merged RDOFF2 linker)

```
tlink [/T=com|sys|exe|texe] [/A:xxxx] [/N:name] [/LOG=level] <input> ... <output>
```

`BIN/TLINK.EXE` links RDOFF2 objects into a tiny-model `.COM`/`.SYS`/`texe`
image (`/T=com`, the default; `/T=sys` with `/A:`/`/N:` for a device
driver; `/T=texe` for a tiny-model MZ `.EXE` — a 3-byte `JMP start` stub,
an 18-byte device header, or no on-disk stub at all, respectively, all
sharing one contiguous code+data+bss segment with no relocation table) or
a small-model `.EXE` (`/T=exe` — paragraph-aligned code/data/bss regions
plus an MZ relocation table). These are memory models `toc.exe`'s own
embedded linker does not target (it always produces a full/large-model-style
single-segment image sized to the compiler's own conventions).

`/T=texe` wraps the same tiny-model layout as `/T=com` in a minimal MZ
header instead of relying on DOS's `.COM` loader convention: header
`CS=SS=-1` paragraph (resolving to the PSP segment, one paragraph behind
the load segment, so `DS=CS=SS=PSP` at runtime exactly like a `.COM`), `IP`
set directly to the entry point plus `0x100` (the PSP-vs-load-segment
bias, standing in for the `JMP` stub `/T=com` needs on disk), `SP=0xFFFE`,
no relocation table, and `MinAlloc=MaxAlloc` sized to reserve the rest of
the 64K PSP segment after the image. Implemented in `SRC/TLINK/TEXE.MOD`
(module `TExe`), called from `TLINK.MOD`'s output-dispatch step. `/T=com`
and `/T=texe` share `TLINK.MOD`'s `OnReloc` PSP (`CS:100h`) address bias
for absolute in-image references — `/T=sys` does not apply it (no PSP).

Keeps the logic shared between tiny and small model (module/symbol
scanning, RDOFF2/RDLIB2/TAR auto-detection by content signature,
smart-link marking from an entry symbol — only `start`, or both
`strategy` and `interrupt` for `/T=sys`) once, branching only at
layout/output time on the target mode. AR (`.a`) archive support was
intentionally not implemented — not needed by anything in this repo.
`/LOG=` works exactly like `toc.exe`'s/`tasm.exe`'s (`LogErr.SetLevel`).

Source: `SRC/TLINK/TLINK.MOD`, `SRC/TLINK/TEXE.MOD`. Build: `cd SRC/TLINK
&& make && make install`. See [BUILD.MD](BUILD.MD) §"Using tlink" for the
full CLI reference. Regression test: `TESTS/test_tlink.sh` (see
[TESTS.MD](TESTS.MD) §"TLINK linker regression test").

---

## 2. The Oberon-07 dialect

This compiler implements **Oberon-07** (Wirth 2007) with practical extensions for DOS.
It is **not** Oberon-2 and has no type-bound procedures (methods).

### 2.1 Keywords and case sensitivity

All identifiers are **case-sensitive**.  Keywords are uppercase: `BEGIN END VAR CONST TYPE PROCEDURE MODULE IMPORT RECORD ARRAY POINTER TO OF RETURN IF THEN ELSIF ELSE WHILE DO REPEAT UNTIL FOR BY CASE WITH NIL TRUE FALSE OR DIV MOD IS IN NEW DISPOSE`.

`FAR`, `NEAR`, `EXTERNAL` are context-sensitive modifiers (also uppercase).

### 2.2 Type system

| Type | Size | Range / Notes |
|------|------|---------------|
| `BOOLEAN` | 1 byte | `FALSE`=0, `TRUE`=1 |
| `CHAR` | 1 byte | ASCII; string literals are `ARRAY OF CHAR` (NUL-terminated) |
| `BYTE` | 1 byte | unsigned 0..255 |
| `INTEGER` | 2 bytes | signed −32768..32767 |
| `WORD` | 2 bytes | unsigned 0..65535; same storage as INTEGER |
| `LONGINT` | 4 bytes | signed 32-bit; stored in DX:AX register pair |
| `REAL` | 4 bytes | IEEE 754 single precision; requires x87 FPU |
| `LONGREAL` | 8 bytes | IEEE 754 double precision; requires x87 FPU |
| `SET` | 2 bytes | elements 0..15 (one word) |
| `POINTER TO T` | 4 bytes | FAR pointer: `{offset:word, segment:word}`; `NIL` = 0000:0000 |

**No 64-bit integers.**  The largest integer type is `LONGINT` (32-bit).  For values larger than 2 147 483 647, use `LONGREAL` (if precision allows) or split into two `LONGINT` fields.

**`WORD`** is an extension type: unsigned 16-bit.  Use it for values that are logically non-negative and may reach 65535 (e.g. file sizes within one segment, counts).  In mixed expressions with `INTEGER`, WORD "wins" (result is WORD, unsigned arithmetic).

**No `SHORT`, no `LONG` suffix.**  Type widths are fixed by the type name.

### 2.3 Numeric conversions — explicit casts required

Unlike C, there is no implicit numeric promotion between the integer and float families.

```oberon
VAR i: INTEGER; l: LONGINT; r: REAL;

(* Integer → float: explicit cast at assignment *)
r := REAL(i);           (* OK *)
r := REAL(l);           (* OK *)
r := i;                 (* COMPILE ERROR *)

(* Float → integer: explicit truncation *)
i := FLOOR(r);          (* truncate toward -∞ *)
i := ENTIER(r);         (* synonym for FLOOR *)
l := LONGINT(FLOOR(r)); (* LONGINT result *)

(* Widening within integers: implicit *)
l := i;                 (* OK: INTEGER → LONGINT *)
i := INTEGER(l);        (* truncate to low 16 bits *)
i := INTEGER(w);        (* WORD → INTEGER: bit reinterpret *)
```

**In binary expressions** (`+ - * / = # < > <= >=`), an integer operand is automatically promoted to float when the other operand is `REAL` or `LONGREAL` (FILD is emitted).  This only applies inside expressions, not at the assignment boundary.

```oberon
r := r + i;    (* OK: i promoted to float in expression *)
r := i;        (* COMPILE ERROR: no implicit promo at assignment *)
```

### 2.4 Type casts

```oberon
INTEGER(x)     (* truncate to low 16 bits *)
LONGINT(x)     (* sign-extend INTEGER/BYTE/WORD to 32-bit *)
WORD(x)        (* reinterpret 16 bits as unsigned *)
BYTE(x)        (* mask to low 8 bits *)
REAL(x)        (* integer → 32-bit float via FILD *)
LONGREAL(x)    (* integer → 64-bit float via FILD *)
FLOOR(x)       (* float → INTEGER, rounds toward -∞ *)
ENTIER(x)      (* synonym for FLOOR *)
FLOAT(x)       (* synonym for REAL(x) *)
CHR(i)         (* INTEGER → CHAR *)
ORD(c)         (* CHAR → INTEGER *)
```

`SYSTEM.VAL` is **not available** in this dialect (see §3.3 for workarounds).

### 2.5 Strings

Strings are `ARRAY OF CHAR`, always NUL-terminated.  String literals (`"hello"`) are zero-terminated constants.  There is no dynamic string type.

```oberon
VAR s: ARRAY 64 OF CHAR;
s := "hello";                  (* copy literal into array *)
Strings.Append(" world", s);   (* s = "hello world\0" *)
```

- Maximum string length = array length − 1 (for the NUL terminator).
- `Strings.Length(s)` returns the length excluding NUL.
- Single-character string literals (`"A"`) are compatible with `CHAR` formals.

### 2.6 Arrays

```oberon
VAR a: ARRAY 10 OF INTEGER;          (* fixed array, 10 elements *)
VAR m: ARRAY 4, 8 OF BYTE;           (* multi-dim, 4×8; same as ARRAY 4 OF ARRAY 8 OF BYTE *)
```

- Array dimensions can be named integer constants: `ARRAY MyConst OF T`.
- `LEN(a)` returns the element count as a compile-time `WORD` constant for fixed arrays; runtime `WORD` for open-array parameters.
- `SIZE(T)` returns the byte size of type `T` as a compile-time `WORD` constant.
- Bounds checking is off by default; enable with the `$R+` directive.

**Open-array parameters** (variable-length):
```oberon
PROCEDURE Foo(a: ARRAY OF INTEGER);
  VAR len: INTEGER;
BEGIN
  len := INTEGER(LEN(a));   (* LEN returns WORD *)
END Foo;
```
An open-array parameter occupies 6 bytes on the stack: 4-byte far pointer + 2-byte length word.

### 2.7 Records

```oberon
TYPE
  Base = RECORD x, y: INTEGER END;
  Derived = RECORD (Base) z: INTEGER END;   (* record extension *)
```

- Fields are accessed as `rec.field` or `ptr^.field`.
- Record extension (single inheritance) is supported; runtime type tests use `IS`.
- No methods; no `WITH` statement.

### 2.8 Pointers and heap

```oberon
TYPE PNode = POINTER TO Node;
     Node  = RECORD val: INTEGER; next: PNode END;
VAR p: PNode;

NEW(p);          (* allocate; p^ is the Node *)
p^.val := 42;
p^.next := NIL;
DISPOSE(p);      (* free; does NOT set p to NIL *)
```

- `NIL` = 0000:0000 (both segment and offset are zero).
- `p = NIL` compares both words; testing `p # NIL` before deref is always correct.
- `NEW(p, n)` allocates `n` bytes (for `SYSTEM.ADDRESS` or sized allocation).
  This holds even when `p: POINTER TO ARRAY OF T` with `SIZE(T) > 1` — `n`
  is NOT an element count here (a deliberate deviation from standard
  Oberon-07's `NEW(p, n)` semantics for open-array pointers). Write
  `NEW(p, n * SIZE(T))` explicitly when you mean "n elements"; see
  `DOCS/OBERLANG.MD` §"NEW and DISPOSE" for the full pitfall writeup.
- Heap is managed by the runtime (`SYSTEM_Alloc` / `SYSTEM_Free`); there is no GC.

**All pointers are FAR (4 bytes).**  On 8086 real mode, every heap object lives in its own memory segment; the pointer carries both segment and offset.

### 2.9 Procedures

```oberon
PROCEDURE Name*(param: Type): RetType;   (* exported, FAR *)
  VAR local: INTEGER;
BEGIN
  ...
  RETURN value
END Name;

PROCEDURE Internal(x: INTEGER);          (* not exported, NEAR — cheaper calls *)
BEGIN ... END Internal;
```

- Exported procedures (`*`) are always FAR (cross-module callable via 9A CALL FAR).
- Non-exported procedures are NEAR by default (E8 CALL NEAR, smaller and faster).
- Explicitly: `PROCEDURE name; FAR;` or `PROCEDURE name; NEAR;`.
- `EXTERNAL` procedures link to an external RDOFF symbol without a body.
- `INLINE` procedures emit raw bytes at the call site (see §3.5).
- `FORWARD` declarations allow mutual recursion.

**No uplevel variable access.**  A nested procedure can only see module globals, its own imports, and its own locals/parameters.  It cannot access the enclosing procedure's variables.

**Calling convention:** Pascal (callee cleans).  Arguments pushed left-to-right (first param pushed first = deepest on stack).

### 2.10 Control flow

```oberon
(* IF with ELSIF *)
IF x > 0 THEN ...
ELSIF x = 0 THEN ...
ELSE ...
END;

(* WHILE with ELSIF *)
WHILE cond DO ...
ELSIF cond2 DO ...
END;

(* REPEAT *)
REPEAT ... UNTIL cond;

(* FOR *)
FOR i := 0 TO n-1 DO ... END;
FOR i := n-1 TO 0 BY -1 DO ... END;

(* CASE — INTEGER or CHAR selector *)
CASE ch OF
  "A".."Z": ...
| "0".."9": ...
| 0X:       ...
ELSE ...
END;
```

- `LOOP`/`EXIT` are **not supported**.  Use `WHILE done := FALSE` or a BOOLEAN flag.
- No `WITH` statement.
- CASE labels accept any constant expression, including imported constants (`Module.Const`).

#### No BREAK, CONTINUE, or mid-body RETURN

This dialect has **no `BREAK`** (exit a loop early), **no `CONTINUE`** (skip to next iteration), and **no mid-body `RETURN`** from a procedure — `RETURN` is only the final expression in a function procedure.

**Replacing `break`:**
```oberon
(* C: while(cond) { if(x) break; } *)
done := FALSE;
WHILE cond & ~done DO
  IF x THEN done := TRUE
  ELSE (* normal body *)
  END
END;
```

**Replacing `continue`:**
```oberon
(* C: while(cond) { if(skip) continue; body; } *)
WHILE cond DO
  IF ~skip THEN
    (* body *)
  END
END;
```

**Replacing early return from a procedure:**  
Factor out the early-exit condition using a BOOLEAN variable or restructure with ELSIF:
```oberon
(* C: void Foo() { if(bad) return; body; } *)
PROCEDURE Foo;
BEGIN
  IF ~bad THEN
    (* body *)
  END
END Foo;

(* Or for deeper nesting, use a flag and a single exit: *)
PROCEDURE Bar;
  VAR ok: BOOLEAN;
BEGIN
  ok := TRUE;
  IF bad1 THEN ok := FALSE END;
  IF ok & bad2 THEN ok := FALSE END;
  IF ok THEN
    (* body *)
  END
END Bar;
```

**Function procedures** (`RETURN expr`) only support `RETURN` at the syntactic end of the body — there is exactly one return point.  Structure the logic with IF/ELSIF to select the value:
```oberon
PROCEDURE Max(a, b: INTEGER): INTEGER;
BEGIN
  IF a >= b THEN RETURN a ELSE RETURN b END
END Max;
```

### 2.11 Module structure

```oberon
MODULE MyMod;
IMPORT Out, Strings, Dos;

CONST N* = 42;
TYPE  T* = RECORD x: INTEGER END;
VAR   g*: INTEGER;

PROCEDURE Run*;
BEGIN
  Out.String("hello"); Out.Ln
END Run;

BEGIN
  (* module initialization body — runs once when first imported *)
  g := 0
END MyMod.
```

- `IMPORT SYSTEM` is a **compile error**.  SYSTEM is always implicitly available via `SYSTEM.xxx` qualified access.
- Module names must not contain underscores (`_`).
- Every module auto-generates a `ModName__init` procedure that runs the BEGIN body and calls imported modules' inits.

### 2.12 Compiler directives

Directives appear as special comments:

```oberon
(*$M 8192, 131072, 262144*)   (* stack bytes, min heap bytes, max heap bytes *)
(*$R+*)                        (* enable runtime array bounds checking *)
(*$R-*)                        (* disable bounds checking (default) *)
(*$L path/to/extra.rdf*)       (* pack an extra .rdf into the .om *)
```

`$M` must appear in the module that uses `/ENTRY=`.  Defaults: 8 KB stack, 128 KB min heap, 256 KB max heap.

---

## 3. 8086 Architecture constraints

### 3.1 Memory model: Large (CS ≠ DS ≠ SS)

The program runs in real mode with the **large memory model**:

```
CS  = current module's code segment  (unique per module)
DS  = combined data segment          (shared by all modules; set once at startup)
SS  = stack segment                  (separate from DS and CS)
```

**Practical implications for porting:**
- You cannot assume any two segment registers are equal.
- Stack variables live in SS; global variables live in DS; heap objects have their own segment.
- Far pointers (4 bytes) are everywhere — all `POINTER TO T` are far pointers.
- Maximum code size per module: ~64 KB.  Split large modules.
- Maximum data segment: ~64 KB total across all modules.
- Maximum single array: must fit in one 64 KB segment.

### 3.2 Integer sizes

On 8086:
- `INTEGER` = 16-bit (2 bytes) — the native word size.
- `LONGINT` = 32-bit (4 bytes) — uses DX:AX register pair; multiply/divide require runtime calls.
- There is no 64-bit integer.

**When porting from a 32-bit or 64-bit language:**
- `int` / `int32_t` → `LONGINT`
- `short` / `int16_t` → `INTEGER`
- `uint8_t` → `BYTE`
- `uint16_t` → `WORD`
- `uint32_t` → `LONGINT` (only values ≤ 2 147 483 647; larger values need special handling)
- `int64_t` / `long long` → not available; use two `LONGINT` fields or `LONGREAL`

### 3.3 No FPU without hardware

`REAL` and `LONGREAL` require an 8087 coprocessor.  The runtime automatically detects its absence and halts with an error message.  If you need to run on hardware without an FPU, avoid floating-point entirely.

### 3.4 Recursion depth

The stack is typically 8 KB (configurable via `$M`).  Deep recursion will crash with a stack overflow (no guard page).  Convert deep recursion to iteration when porting.

---

## 4. Programming tricks and workarounds

### 4.1 No `SYSTEM.VAL` — type reinterpretation

`SYSTEM.VAL(T, x)` from standard Oberon is **not available**.  Use typed pointers instead:

```oberon
(* Reinterpret an INTEGER as two BYTEs *)
TYPE PByte = POINTER TO BYTE;
VAR  i: INTEGER; p: PByte; lo, hi: BYTE;
BEGIN
  p  := SYSTEM.PTR(SYSTEM.SEG(i), SYSTEM.OFS(i));
  lo := p^;
  p  := SYSTEM.PTR(SYSTEM.SEG(i), SYSTEM.OFS(i) + 1);
  hi := p^;
END;

(* Or use SYSTEM.MOVE to copy bytes *)
VAR src: LONGINT; dst: ARRAY 4 OF BYTE;
BEGIN
  SYSTEM.MOVE(SYSTEM.ADR(src), SYSTEM.ADR(dst), 4);
END;
```

For simple BYTE/INTEGER reinterpretation, the cast functions often suffice:
```oberon
i := INTEGER(b);    (* BYTE → INTEGER, zero-extends *)
b := BYTE(i);       (* INTEGER → BYTE, masks to low 8 bits *)
i := INTEGER(w);    (* WORD → INTEGER, bit-reinterpret *)
```

### 4.2 Bitwise operations — use `SYSTEM.AND/IOR/XOR`

```oberon
flags := SYSTEM.AND(flags, 0FEH);     (* clear bit 0 *)
flags := SYSTEM.IOR(flags, 080H);     (* set bit 7 *)
flags := SYSTEM.XOR(flags, 001H);     (* toggle bit 0 *)
```

These work on `INTEGER` and `LONGINT`.  Always use the `SYSTEM.` prefix; bare `AND(x,y)` is a compile error.

### 4.3 Bit shifts — use `SYSTEM.LSL/LSR/ASR/ROR`

```oberon
x := SYSTEM.LSL(x, 3);   (* x << 3, logical shift left *)
x := SYSTEM.LSR(x, 1);   (* x >> 1, logical shift right (unsigned) *)
x := SYSTEM.ASR(x, 1);   (* x >> 1, arithmetic shift right (sign-extending) *)
```

All work on `INTEGER` and `LONGINT`.

### 4.4 No dynamic arrays — use linked lists or fixed-size buffers

There are no resizable arrays.  When porting dynamic data structures:

```oberon
(* Linked list node *)
TYPE
  PNode = POINTER TO Node;
  Node  = RECORD
    data: INTEGER;
    next: PNode
  END;

VAR head: PNode;

PROCEDURE Prepend(val: INTEGER);
  VAR n: PNode;
BEGIN
  NEW(n);
  n^.data := val;
  n^.next := head;
  head := n
END Prepend;
```

For fixed-size buffers, declare them as `ARRAY MaxN OF T` with a count variable.

### 4.5 No exceptions — use error codes or globals

There is no exception handling.  Use return values or a module-level error variable:

```oberon
VAR lastError: INTEGER;

PROCEDURE DoSomething(): BOOLEAN;
BEGIN
  IF badCondition THEN
    lastError := 42;
    RETURN FALSE
  END;
  lastError := 0;
  RETURN TRUE
END DoSomething;
```

`ASSERT(cond)` halts the program with a non-zero exit code if the condition is false.  Use it for invariants, not recoverable errors.

### 4.6 String building — use a buffer and Strings module

```oberon
PROCEDURE FormatInt(n: LONGINT; VAR buf: ARRAY OF CHAR);
  (* simple decimal formatting *)
  VAR tmp: ARRAY 12 OF CHAR; i, j: INTEGER; neg: BOOLEAN;
BEGIN
  neg := n < 0L;
  IF neg THEN n := -n END;
  i := 0;
  REPEAT
    tmp[i] := CHR(INTEGER(n MOD 10L) + ORD("0")); INC(i);
    n := n DIV 10L
  UNTIL n = 0L;
  IF neg THEN tmp[i] := "-"; INC(i) END;
  (* reverse *)
  j := 0;
  WHILE i > 0 DO DEC(i); buf[j] := tmp[i]; INC(j) END;
  buf[j] := 0X
END FormatInt;
```

Alternatively, `Out.Int(n, 0)` writes directly to stdout.

### 4.7 Low-level memory access — typed pointers

```oberon
TYPE PInt = POINTER TO INTEGER;
VAR  p: PInt; addr: SYSTEM.ADDRESS;

(* Read an INTEGER at a known segment:offset *)
addr := SYSTEM.PTR(0B800H, 0);   (* CGA video memory *)
p    := addr;
p^   := 0720H;                    (* write space + grey-on-black attribute *)
```

### 4.8 Calling DOS interrupts — Dos.Intr

```oberon
VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 0900H;                    (* INT 21h: write string to stdout *)
  r.DS := SYSTEM.SEG(myString);
  r.DX := SYSTEM.OFS(myString);
  Dos.Intr(21H, r);
END;
```

### 4.9 Checking for EOF in file reading

```oberon
VAR f: Files.File; ch: CHAR; n: WORD;
BEGIN
  IF Files.Reset(f, "data.txt") THEN
    n := Files.BlockRead(f, ch, 1);
    WHILE n > 0 DO
      (* process ch *)
      n := Files.BlockRead(f, ch, 1)
    END;
    Files.Close(f)
  END
END;
```

### 4.10 Replacing `LOOP`/`EXIT`

```oberon
(* Instead of: LOOP ... IF done THEN EXIT END ... END *)
done := FALSE;
WHILE ~done DO
  ...
  IF condition THEN done := TRUE END;
  ...
END;
```

### 4.11 LONGINT arithmetic tips

`LONGINT` multiply, divide, and modulo call runtime helpers and are slower than `INTEGER` ops.  Prefer `INTEGER` where values fit.

```oberon
(* Mask a LONGINT to 16 bits unsigned: *)
w := WORD(INTEGER(n));            (* take low 16 bits *)

(* Multiply two INTEGERs safely producing LONGINT result: *)
l := LONGINT(a) * LONGINT(b);

(* Divide LONGINT by a constant power of 2 (faster): *)
l := SYSTEM.ASR(l, 3);           (* l DIV 8 for non-negative l *)
```

### 4.12 Procedure variables

```oberon
TYPE Callback = PROCEDURE FAR (x: INTEGER);   (* FAR = cross-module callable *)
VAR  cb: Callback;

PROCEDURE MyProc*(x: INTEGER);
BEGIN Out.Int(x, 0); Out.Ln END MyProc;

BEGIN
  cb := MyProc;
  cb(42)
END;
```

FAR proc variables are 4 bytes (segment:offset); NEAR are 2 bytes (offset only, same module).  FAR and NEAR proc variables are not assignment-compatible.

---

## 5. Standard library — `OBERON.OM`

After `make`, `BIN/OBERON.OM` is a single merged archive of all
20 standard library modules: `SYSTEM`, `Out`, `Out87`, `In`, `Strings`,
`Files`, `Crt`, `Dos`, `IO`, `RdfLoad`, `Math`, `Test`, `Ems`, `Time`,
`LogErr`, `Rdoff`, `Tar`, `Detect`, `WinCB`, `KMouse`, `Screen`.  Individual
`.om` files are built as intermediates, merged, then removed. Only
`BIN/OBERON.OM` remains.

`Detect` (hardware/environment probing — EGA/VGA/mono, redirected stdio,
FreeDOS, CPU class), `WinCB` (Windows 3.x clipboard access via WinOldAp
INT 2Fh), `KMouse` (extended-keyboard + Microsoft-mouse INT 33h driver),
and `Screen` (text-mode shadow-buffer driver: colour print/scroll, cursor,
a background spinner, VGA palette fades) are all ports of small Turbo
Pascal `UNIT`s — see §16 below for the porting conventions they establish
(EXTERNAL leaf routines in a companion `.ASM` file, `%define`/`%undef`
stack-argument aliasing, `PCHAR` → `SYSTEM.ADDRESS`).

`BIN/TOC.EXE` finds `OBERON.OM` automatically in CWD or in the same directory as `toc.exe`.
One command handles compile and link — no individual `.om` files needed:

```bash
# Unix host driving xt:
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run MyProg.Mod

# Real MS-DOS (with OBERON.OM in CWD or alongside toc.exe):
toc.exe /ENTRY=Run MyProg.Mod
```

Individual `.om` files can be placed in `OBERON_LIB` to override specific modules —
the compiler and linker search `ModName.OM` in CWD and exe directory before falling
back to `OBERON.OM`.

---

## 6. Module SYSTEM

`SYSTEM` is always implicitly available — never write `IMPORT SYSTEM`.  All access is via `SYSTEM.Name(...)`.

### 6.1 Types

```oberon
SYSTEM.ADDRESS    (* 4-byte far pointer; compatible with any POINTER *)

SYSTEM.Registers  (* RECORD, 18 bytes — 8086 register set for INT calls *)
  AX, BX, CX, DX, SI, DI, DS, ES, Flags: INTEGER
```

Flag constants: `SYSTEM.FCarry=1`, `SYSTEM.FParity=4`, `SYSTEM.FAuxiliary=16`, `SYSTEM.FZero=64`, `SYSTEM.FSign=128`, `SYSTEM.FOverflow=2048`.

### 6.2 Procedures

```oberon
SYSTEM.Intr(IntNo: BYTE; VAR Regs: Registers)
```
Execute a software interrupt.  Fill `Regs` with input values; read output values after the call.

```oberon
SYSTEM.ADR(VAR v): SYSTEM.ADDRESS
```
Returns the far address (segment:offset) of variable `v`.  Also accepts a procedure name: `SYSTEM.ADR(MyProc)` returns the code address.

```oberon
SYSTEM.SEG(VAR v): INTEGER
```
Returns the segment register value for `v` (SS for locals/params, DS for globals, heap segment for `p^`).

```oberon
SYSTEM.OFS(VAR v): INTEGER
```
Returns the offset within the segment for `v`.

```oberon
SYSTEM.PTR(seg, ofs: INTEGER): SYSTEM.ADDRESS
```
Construct a far pointer from separate segment and offset values.

```oberon
SYSTEM.MOVE(VAR src, dst; n: WORD)
```
Copy `n` bytes from `src` to `dst`.  Works across any segments.  Equivalent to `memcpy`.

```oberon
SYSTEM.FILL(VAR dst; n: WORD; b: BYTE)
```
Fill `n` bytes at `dst` with byte value `b`.  Equivalent to `memset`.

```oberon
SYSTEM.PORTOUT(port: INTEGER; b: BYTE)
```
Write byte `b` to hardware I/O port `port` (x86 `OUT` instruction).

```oberon
SYSTEM.PORTIN(port: INTEGER; VAR b: BYTE)
```
Read a byte from hardware I/O port `port` into `b` (x86 `IN` instruction).

```oberon
SYSTEM.LSL(x, n): same type as x    (* logical shift left *)
SYSTEM.LSR(x, n): same type as x    (* logical shift right, unsigned *)
SYSTEM.ASR(x, n): same type as x    (* arithmetic shift right, sign-extending *)
SYSTEM.ROR(x, n): same type as x    (* rotate right *)
SYSTEM.AND(x, y): widest of x, y    (* bitwise AND *)
SYSTEM.IOR(x, y): widest of x, y    (* bitwise OR *)
SYSTEM.XOR(x, y): widest of x, y    (* bitwise XOR *)
```

`x` may be `BYTE`, `INTEGER`, `WORD`, or `LONGINT`.  `n` is `INTEGER`.

**Type propagation rules:**
- **Shifts** (`LSL`/`LSR`/`ASR`/`ROR`): result type = type of `x`.  `WORD` in → `WORD` out (unsigned semantics preserved).
- **Bitwise** (`AND`/`IOR`/`XOR`): result type = widest of `x` and `y`.  Precedence: `LONGINT` > `WORD` > `INTEGER`.  The 16-bit machine code (AX/CX ops) is identical for `INTEGER` and `WORD`; only the type tag differs.

```oberon
VAR w: WORD; i: INTEGER;
w := WORD(0F0F0H);
w := SYSTEM.AND(w, 0FF00H);  (* result type = WORD: 0F000H *)
i := SYSTEM.AND(i, 0FF00H);  (* result type = INTEGER: same bits, signed view *)
w := SYSTEM.LSR(w, 4);       (* result type = WORD: 00F00H, unsigned shift *)
```

**Not available:** `SYSTEM.VAL`, `SYSTEM.GET`, `SYSTEM.PUT` — use typed pointers instead.

```oberon
SYSTEM.MemAvail(): WORD
```
Returns the total amount of free heap, in 16-byte paragraphs, by walking the
`MEMHEADER` free list.  Useful for detecting memory leaks during development.

```oberon
SYSTEM.MemMaxAvail(): WORD
```
Returns the size of the largest contiguous free block, in 16-byte paragraphs.
Both procedures are exported FAR from `SYSTEM.MOD` / `SYSTEM.ASM`.

```oberon
SYSTEM.UCASE(c: CHAR): CHAR
```
Returns the ASCII uppercase of `c` (A–Z only; all other characters returned
unchanged).  Inline single-instruction expansion — no function-call overhead.

---

## 7. Module Out

Simple character-based output to stdout.  No floating-point — use `Out87` for REAL/LONGREAL.

```
IMPORT Out;
```

```oberon
Out.Open;                    (* initialize; call once before first output *)
Out.Char(ch: CHAR);          (* write one character *)
Out.String(s: ARRAY OF CHAR);(* write NUL-terminated string *)
Out.Int(n: LONGINT; w: INTEGER);  (* write integer, right-justified in w chars *)
Out.Hex(n: INTEGER; w: INTEGER);  (* write integer in hex, right-justified in w chars *)
Out.Adr(p: SYSTEM.ADDRESS);  (* write address as SSSS:OOOO *)
Out.Ln;                      (* write newline (CR+LF on DOS) *)
```

`Out.Open` must be called before any other `Out` procedure.  Typically called once from the main procedure.

---

## 8. Module Out87

Like `Out`, but includes `REAL` and `LONGREAL` output.  Requires an x87 FPU.  Imports `Out` internally; call `Out87.Open` instead of `Out.Open`.

```
IMPORT Out87;
```

```oberon
Out87.Open;
Out87.Char(ch: CHAR);
Out87.String(s: ARRAY OF CHAR);
Out87.Int(n: LONGINT; w: INTEGER);
Out87.Hex(n: INTEGER; w: INTEGER);
Out87.Adr(p: SYSTEM.ADDRESS);
Out87.Real(x: REAL; w: INTEGER);         (* write REAL, w chars wide *)
Out87.LongReal(x: LONGREAL; w: INTEGER); (* write LONGREAL, w chars wide *)
Out87.Ln;
```

---

## 9. Module In

Simple input from stdin.

```
IMPORT In;
```

```oberon
In.Open;                        (* initialize; call once *)
In.Char(VAR c: CHAR);           (* read one character *)
In.Int(VAR i: INTEGER);         (* read decimal integer; skips whitespace *)
In.LongInt(VAR l: LONGINT);     (* read decimal long integer *)
In.String(VAR s: ARRAY OF CHAR);(* read whitespace-delimited token *)
```

`In.Open` must be called before first use.

---

## 10. Module IO

Low-level rider-based I/O for arbitrary file handles (stdin, stdout, stderr, or a `Files.File`-backed handle).  Used primarily by compiler tools for structured output; useful when you need to write to stderr or a specific file without going through `Out`.

```
IMPORT IO;
```

```oberon
TYPE IO.Rider   (* opaque; bound to a file handle *)

IO.StdOut(VAR r: Rider);              (* bind rider to stdout *)
IO.StdErr(VAR r: Rider);              (* bind rider to stderr *)
IO.OpenHandle(VAR r: Rider; h: INTEGER); (* bind to DOS file handle h *)

IO.ReadChar(VAR r: Rider; VAR ch: CHAR);
IO.WriteChar(VAR r: Rider; ch: CHAR);
IO.WriteStr(VAR r: Rider; s: ARRAY OF CHAR);
IO.WriteInt(VAR r: Rider; n: LONGINT);
IO.WriteLn(VAR r: Rider);
```

Example — writing to stderr:
```oberon
VAR err: IO.Rider;
BEGIN
  IO.StdErr(err);
  IO.WriteStr(err, "Error: something went wrong"); IO.WriteLn(err)
END;
```

---

## 11. Module Files

Buffered random-access file I/O using DOS file handles.

```
IMPORT Files;
```

```oberon
TYPE Files.File   (* opaque record; pass by VAR *)

Files.Reset(VAR F: File; name: ARRAY OF CHAR): BOOLEAN
```
Open an existing file for read/write.  Returns `FALSE` if not found.

```oberon
Files.ReWrite(VAR F: File; name: ARRAY OF CHAR): BOOLEAN
```
Create or truncate a file for writing.  Returns `FALSE` on failure.

```oberon
Files.Close(VAR F: File)
```
Flush and close.  Always call when done.

```oberon
Files.BlockRead(VAR F: File; VAR x; len: WORD): WORD
```
Read up to `len` bytes into `x` (typeless VAR).  Returns the number of bytes actually read (0 = EOF or error).

```oberon
Files.BlockWrite(VAR F: File; VAR x; len: WORD): WORD
```
Write `len` bytes from `x`.  Returns bytes written.

```oberon
Files.Seek(VAR F: File; pos: LONGINT)
```
Set the file position to `pos` bytes from the start.

```oberon
Files.Position(VAR F: File): LONGINT
```
Return the current file position.

```oberon
Files.Size(VAR F: File): LONGINT
```
Return the file size in bytes.

```oberon
Files.Truncate(VAR F: File)
```
Truncate the file at the current position.

```oberon
Files.Delete(FileName: ARRAY OF CHAR): BOOLEAN
Files.Rename(OldName, NewName: ARRAY OF CHAR): BOOLEAN
Files.Copy(src, dst: ARRAY OF CHAR): BOOLEAN
Files.FileExists(FileName: ARRAY OF CHAR): BOOLEAN
```

**Reading bytes one at a time:**
```oberon
VAR f: Files.File; b: BYTE; n: WORD;
BEGIN
  IF Files.Reset(f, "data.bin") THEN
    n := Files.BlockRead(f, b, 1);
    WHILE n > 0 DO
      (* process b *)
      n := Files.BlockRead(f, b, 1)
    END;
    Files.Close(f)
  END
END;
```

**Writing a record:**
```oberon
TYPE Rec = RECORD a, b: INTEGER END;
VAR  f: Files.File; r: Rec; n: WORD;
BEGIN
  r.a := 1; r.b := 2;
  IF Files.ReWrite(f, "out.bin") THEN
    n := Files.BlockWrite(f, r, SIZE(Rec));
    Files.Close(f)
  END
END;
```

---

## 12. Module Strings

String operations.  Strings are `ARRAY OF CHAR`, NUL-terminated.

```
IMPORT Strings;
```

```oberon
Strings.Length(s: ARRAY OF CHAR): INTEGER
```
Length of `s` excluding the NUL terminator.

```oberon
Strings.Pos(substr, string: ARRAY OF CHAR; VAR pos: WORD): BOOLEAN
```
Find the first occurrence of `substr` in `string`, starting the scan at the offset passed in
`pos`.  `pos` is in/out: on entry it's the 0-based index to start scanning from (0 to search
the whole string); on a `TRUE` result it's overwritten with the 0-based index of the match;
on a `FALSE` result it's left unspecified.  Returns `TRUE` if found, `FALSE` if not found or
if the original `pos` was already past the end of `string`.

```oberon
Strings.Append(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR)
```
Append `s` to `d`.  `d` must be large enough.

```oberon
Strings.Insert(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)
```
Insert `src` into `dst` at position `pos`.

```oberon
Strings.Delete(VAR s: ARRAY OF CHAR; pos, n: INTEGER)
```
Delete `n` characters from `s` starting at `pos`.

```oberon
Strings.Replace(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)
```
Replace characters in `dst` starting at `pos` with `src`.

```oberon
Strings.Extract(src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR)
```
Copy `n` characters from `src` at `pos` into `dst`.

```oberon
Strings.Equal(a, b: ARRAY OF CHAR): BOOLEAN
```
Case-sensitive string comparison.

```oberon
Strings.StartsWith(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN
```
TRUE if `str` begins with `substr`.  `ICase` = TRUE compares case-insensitively.

```oberon
Strings.EndsWith(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN
```
TRUE if `str` ends with `substr`.  `ICase` = TRUE compares case-insensitively.

```oberon
Strings.Copy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)
```
Copy `src` into `dst`.

```oberon
Strings.LTrim(VAR s: ARRAY OF CHAR)
```
Remove leading whitespace from `s`, in place.  Whitespace is any byte `SYSTEM.ISSPACE`
accepts (`ORD` 1..32: space plus the low control characters).

```oberon
Strings.RTrim(VAR s: ARRAY OF CHAR)
```
Remove trailing whitespace from `s`, in place.  Same whitespace definition as `LTrim`.

```oberon
Strings.Trim(VAR s: ARRAY OF CHAR)
```
Remove both leading and trailing whitespace from `s`, in place (equivalent to `RTrim`
followed by `LTrim`).  Internal whitespace is left untouched.

---

## 13. Module Mem

Low-level heap allocation (bypass the Oberon `NEW`/`DISPOSE` mechanism).

```
IMPORT Mem;
```

```oberon
Mem.Alloc(size: WORD): SYSTEM.ADDRESS
```
Allocate `size` bytes.  Returns `NIL` on failure.

```oberon
Mem.Free(p: SYSTEM.ADDRESS)
```
Free a previously allocated block.

Use `NEW`/`DISPOSE` for typed heap objects.  Use `Mem` only when you need raw byte buffers or interfacing with DOS memory functions.

---

## 14. Module Test

Unit-test framework.  Register test procedures, run them all, and report results.
Requires x87 FPU (it imports `Out87` and `Math`).

```
IMPORT Test;
```

```oberon
TYPE Test.TestProc = PROCEDURE FAR
```
Type of a test procedure — must be exported (`*`) and FAR so it is callable cross-module.

```oberon
Test.AddTest(t: TestProc; name: ARRAY OF CHAR)
```
Register test procedure `t` under the given `name` (truncated to 24 characters).
Maximum 128 tests per program.

```oberon
Test.RunTests*
```
Run all registered tests in registration order.  For each test: calls the procedure
with a fresh failure counter, prints `<name> PASSED` or per-failure detail lines.
At the end prints:
```
--------------------------------------
Total: N
Passed: P
Failed: F
```
Exits the program with code 0 if all passed, 1 if any failed.

**Assertion procedures** (all take a trailing `msg: ARRAY OF CHAR` for failure messages):

```oberon
Test.AssertTrue(cond: BOOLEAN; msg: ARRAY OF CHAR)
Test.AssertFalse(cond: BOOLEAN; msg: ARRAY OF CHAR)
Test.AssertNil(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR)
Test.AssertNotNil(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR)
Test.AssertByte(expected, actual: BYTE; msg: ARRAY OF CHAR)
Test.AssertInt(expected, actual: INTEGER; msg: ARRAY OF CHAR)
Test.AssertWord(expected, actual: WORD; msg: ARRAY OF CHAR)
Test.AssertLong(expected, actual: LONGINT; msg: ARRAY OF CHAR)
Test.AssertReal(expected, actual: REAL; msg: ARRAY OF CHAR)       (* epsilon = 1.0E-6 *)
Test.AssertLongReal(expected, actual: LONGREAL; msg: ARRAY OF CHAR) (* epsilon = 1.0E-6 *)
Test.AssertStr(expected, actual: ARRAY OF CHAR; msg: ARRAY OF CHAR)
```

On failure each assertion prints `<testname> FAIL: <msg>` with the expected and actual values, then increments the failure counter.  Execution continues — assertions do not abort.

**Typical usage:**

```oberon
MODULE MyTest;
IMPORT Test;

PROCEDURE TAddition*;
BEGIN
  Test.AssertInt(4, 2 + 2, "2+2");
  Test.AssertInt(0, 1 - 1, "1-1")
END TAddition;

PROCEDURE TStrings*;
BEGIN
  Test.AssertStr("hello", "hello", "equal strings");
  Test.AssertStr("hi", "bye", "should fail")
END TStrings;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TAddition, "addition");
  Test.AddTest(TStrings,  "strings");
  Test.RunTests
END RunAllTests;

END MyTest.
```

Build with the all-in-one `toc.exe /ENTRY=RunAllTests MyTest.Mod`; `OBERON.OM`
provides `Test`, `Out87`, `Math`, `Out`, `SYSTEM`, and all other stdlib modules
automatically — no individual `.om` files need to be listed.

---

## 15. Module Dos

DOS system interface: interrupts, command-line arguments, environment, file search, date/time, process execution.

```
IMPORT Dos;
```

### 15.1 Types and constants

```oberon
TYPE Dos.Registers = SYSTEM.Registers   (* alias *)

TYPE Dos.DateTime = RECORD
  Year, Month, Day, Hour, Min, Sec: INTEGER
END;

TYPE Dos.SearchRec = RECORD
  fill: ARRAY 21 OF BYTE;  (* DOS reserved *)
  attr: BYTE;              (* file attributes *)
  time: LONGINT;           (* packed FAT date/time *)
  size: LONGINT;           (* file size in bytes *)
  name: ARRAY 13 OF CHAR;  (* 8.3 filename, NUL-terminated *)
END;

(* File attribute constants *)
Dos.ReadOnly  = 01H
Dos.Hidden    = 02H
Dos.SysFile   = 04H
Dos.VolumeID  = 08H
Dos.Directory = 10H
Dos.Archive   = 20H
Dos.AnyFile   = 3FH

(* Standard handle numbers *)
Dos.STDIN  = 0
Dos.STDOUT = 1
Dos.STDERR = 2

(* Result variables (updated by most Dos procedures) *)
Dos.DosError*:    WORD   (* 0 = success; DOS error code on failure *)
Dos.DosExitCode*: WORD   (* exit code from last Exec call *)
```

### 15.2 Interrupts and low-level calls

```oberon
Dos.Intr(IntNo: BYTE; VAR Regs: Registers)
```
Execute interrupt `IntNo` with register values from `Regs`; outputs go back into `Regs`.

```oberon
Dos.MsDos(VAR Regs: Registers)
```
Equivalent to `Dos.Intr(21H, Regs)` — INT 21h (DOS function call).

### 15.3 Command-line arguments

```oberon
Dos.ParamCount(): INTEGER
```
Number of command-line arguments (0 = no arguments).

```oberon
Dos.ParamStr(i: INTEGER; VAR p: ARRAY OF CHAR)
```
Get argument `i` (1-based) into `p`.  Argument 0 is typically the program name (may be empty on some DOS versions).

### 15.4 Environment

```oberon
Dos.GetEnv(envvar: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)
```
Look up environment variable `envvar` and copy its value into `dst`.  If not found, `dst` is set to an empty string.

### 15.5 File search

```oberon
Dos.FindFirst(Path: ARRAY OF CHAR; Attr: BYTE; VAR S: SearchRec)
```
Begin a file search matching `Path` (wildcards `*` and `?` allowed) and attribute `Attr`.  Result in `S`; check `Dos.DosError = 0`.

```oberon
Dos.FindNext(VAR S: SearchRec)
```
Continue the search started by `FindFirst`.  Check `Dos.DosError = 0`.

### 15.6 Date and time

```oberon
Dos.GetDate(VAR Year, Month, Day, DayOfWeek: INTEGER)
Dos.SetDate(Year, Month, Day: INTEGER)
Dos.GetTime(VAR Hour, Minute, Second, Sec100: INTEGER)
Dos.SetTime(Hour, Minute, Second, Sec100: INTEGER)
```

### 15.7 Disk

```oberon
Dos.DiskFree(Drive: BYTE): LONGINT   (* 0=current, 1=A:, 2=B:, 3=C:, ... *)
Dos.DiskSize(Drive: BYTE): LONGINT
```

### 15.8 Directory

```oberon
Dos.MkDir(Path: ARRAY OF CHAR): BOOLEAN
Dos.ChDir(Path: ARRAY OF CHAR): BOOLEAN
```

### 15.9 Path utilities

```oberon
Dos.FExpand(Path: ARRAY OF CHAR; VAR Dest: ARRAY OF CHAR)
```
Expand `Path` to an absolute path.

```oberon
Dos.FSplit(Path: ARRAY OF CHAR; VAR Dir, Name, Ext: ARRAY OF CHAR)
```
Split `Path` into directory, base name, and extension parts.

### 15.10 Interrupt vectors

```oberon
Dos.GetIntVec(IntNo: BYTE; VAR Vector: SYSTEM.ADDRESS)
Dos.SetIntVec(IntNo: BYTE; Vector: SYSTEM.ADDRESS)
Dos.SwapVectors
```

### 15.11 Process execution

```oberon
Dos.Exec(Path, CmdLine: ARRAY OF CHAR)
```
Run a child process synchronously.  `Path` is the `.exe` file; `CmdLine` is the command tail (the part after the program name, starting with a space if non-empty).  After return, check `Dos.DosError` (0 = ok) and `Dos.DosExitCode` (child's exit code, low byte).

```oberon
Dos.GetPsp(): INTEGER
```
Return the Program Segment Prefix segment address.

---

## 16. Porting checklist

When porting code from C, Pascal, or another language:

1. **Replace all dynamic strings** with `ARRAY OF CHAR` with a chosen max length.
2. **Replace `int` with `INTEGER` or `LONGINT`** depending on the expected range.  When in doubt, use `LONGINT`.
3. **Replace `unsigned int` / `uint16_t` with `WORD`.**
4. **Replace `float` / `double` with `REAL` / `LONGREAL`** and add `(*$M ...*)` with FPU requirements.
5. **Replace `malloc`/`free` with `NEW`/`DISPOSE`** (typed) or `Mem.Alloc`/`Mem.Free` (raw).
6. **Replace exception handling** with return values and error globals.
7. **Replace `break`** with a BOOLEAN flag and `WHILE ~done DO ... END`.
8. **Replace `continue`** by inverting the condition: `WHILE cond DO IF ~skip THEN body END END`.
9. **Replace early `return` / mid-body exit** by restructuring with IF/ELSIF or a flag variable (see §2.10).
10. **Replace `LOOP`/`EXIT` patterns** with `WHILE`/boolean flag.
11. **Replace recursion** where depth could exceed ~200 frames with iteration.
12. **Replace bitwise ops** (`&`, `|`, `^`, `<<`, `>>`) with `SYSTEM.AND/IOR/XOR/LSL/LSR`.  These work for `BYTE`, `INTEGER`, `WORD`, and `LONGINT`; `WORD` operands produce `WORD` results.
13. **Replace type-punning / `union`** with typed pointer trick (§4.1) or `SYSTEM.MOVE`.
14. **Replace `printf`** with `Out.String`, `Out.Int`, `Out.Ln` etc.
15. **Replace file I/O** with `Files.Reset`/`ReWrite`/`BlockRead`/`BlockWrite`/`Close`.
16. **Replace environment access** with `Dos.GetEnv`.
17. **Replace command-line parsing** with `Dos.ParamCount`/`Dos.ParamStr`.
18. **Split large files** — each module's code must fit in ~64 KB; its data likewise.
19. **Use 8.3 filenames** for all module names and all files on DOS.
20. **Build with `toc.exe /ENTRY=`** — one command handles dep-scan, incremental compile, and link.  There is no separate linker or build-script generator.

### 16.1 Porting Turbo Pascal `ASM ... END` blocks

Turbo Pascal `UNIT`s that wrap DOS/BIOS interrupts often write each routine
as `PROCEDURE Foo; ASSEMBLER; ASM ... END;` — inline MASM-syntax assembly is
not valid Oberon-07 input in this dialect (no inline-assembly proc bodies at
all beyond the `INLINE(...)` byte-list form). The established pattern for
porting these, used by `Detect`/`WinCB`/`KMouse`/`Screen` (all four ported
from small Turbo Pascal `UNIT`s this way), is a **companion `.ASM` file**:

1. **Split each Pascal `UNIT` into two files**: a `Foo.MOD` with `EXTERNAL`
   procedure declarations (no bodies) plus any pure-Oberon control flow the
   original had, and a `Foo.ASM` with the actual NASM-syntax routine bodies
   — one per Pascal `ASM` block, name-prefixed `Foo_RoutineName` (module
   name, underscore, original name) since that's how the linker resolves
   `EXTERNAL` procedures against `.ASM` globals.
2. **Translate MASM syntax to NASM syntax**: `BYTE PTR [x]` → `BYTE[x]`,
   `@label` → a plain NASM local label, `$hex` → `hexH`, etc. — see §1.7
   above for the exact NASM subset TASM accepts (this compiler's own
   assembler, TASM, only understands NASM syntax, and even where
   `SRC/LIB/*.RDF` files are built with real NASM instead, the source must
   still be NASM-syntax).
3. **Stack arguments use a `%define`/`%undef` bracket, not manual offset
   arithmetic**: every parameterized routine follows
   `PUSH BP; MOV BP,SP; %define argName [BP+RSIZE+N]; ...body...; %undef
   argName; POP BP; RETMACRO N`, where `RSIZE`=4 for a `FAR` proc (the
   normal case — Oberon calls cross-module `EXTERNAL` procs far) and `N` in
   `RETMACRO` is the total byte count of stack arguments to pop. This keeps
   the routine body readable (`MOV AX, x_arg` instead of `MOV AX,
   [BP+6]`) and self-documents the calling convention at a glance.
4. **`PCHAR` (Pascal's typed far pointer) maps to `SYSTEM.ADDRESS`.**
   Typeless `VAR` parameters (Pascal's untyped `VAR d` used for raw memory
   access) map the same way `Ems.MOD`'s `CopyToEMS`/`CopyToDos` already do:
   a `VAR d` far-pointer load via `LES BX, [BP+RSIZE+N]` inside the `.ASM`
   routine, and `SYSTEM.ADR`/`SYSTEM.MOVE`/`SYSTEM.FILL` (never
   `SYSTEM.GET`/`PUT` — not present in this dialect) on the Oberon side
   when the untyped block needs touching from `.MOD` code directly.
5. **Any `INTERRUPT`-modifier Pascal procedure (a raw ISR, e.g. a timer-tick
   handler) has no Oberon equivalent** — this dialect has no `INTERRUPT`
   proc modifier at all. Port it as hand-written raw assembly ending in
   `IRET` (not `RETF`/`RETN`) inside the `.ASM` file, saving/restoring every
   register it touches, and install it via `Dos.SetIntVec`/`GetIntVec` with
   `SYSTEM.ADR(procName)` from the Oberon side (`procName` declared
   `EXTERNAL; FAR;` with no Oberon body — see `Screen.MOD`'s
   `SpinnerStart`/`Stop` and `Screen.ASM`'s `Screen_Spinner1c`).
6. **Cross-module calls inside the `.ASM` file must be `CALL FAR`, not a
   bare `CALL`.** A same-module call to a local label in the same `.ASM`
   file stays a near `CALL` (`E8`, no relocation needed); a call to another
   module's `EXTERNAL`-linked routine — including a plain `SYSTEM.MOD`
   procedure like `SYSTEM.Seg0040` — needs `CALL FAR labelName` (`9A`, with
   a `RELOC`+`SEGRELOC` against the import ID). Getting this wrong doesn't
   fail to assemble; it silently produces a near call that jumps to the
   wrong address at runtime, so it's easy to miss without careful review.
7. **Never hardcode "magic" segment constants** (`0040h` BIOS data area,
   `A000h`/`B000h`/`B800h` video segments) as a local `%define` in the new
   `.ASM` file — call the corresponding `SYSTEM.Seg0040`/`SegA000`/
   `SegB000`/`SegB800` `EXTERNAL` procedure (`CALL FAR`, per point 6)
   instead. This is a deliberate project-wide architectural rule, not a
   style preference.
8. **Every exported `PROCEDURE` needs a doc comment** immediately above its
   declaration: what it does, each parameter's meaning, and what the result
   means — see `Detect.MOD` for the reference style.
9. **Verify against real NASM if available**: assemble the new `.ASM` with
   an independent NASM build and byte-diff its `.rdf` against TASM's own
   output. A pure content match with only header-record-*ordering*
   differences (NASM interleaves `IMPORT` records at their point of
   declaration; TASM groups them after all `GLOBAL`s) is expected and
   fine — see `DOCS/IMPLRULE.MD` §"TASM — design decisions and known
   limitations". A genuine code/data byte difference is not.
10. **Wire the new module into `SRC/LIB/Makefile`** (`STDLIB_OMS`, the
    `regen-asm` target, and a per-module `.OM` build rule depending on its
    checked-in `.RDF`) and, if it's assembled by TASM as part of the
    project's own regression coverage, into `TESTS/test_tasm.sh` — follow
    any existing entry (e.g. `KMOUSE.OM`/`KMOUSE.ASM`) as the template.

---

## 17. Complete example — reading a file and printing its lines

```oberon
MODULE Lines;
IMPORT Out, Files, Strings;

PROCEDURE Run*;
  VAR f: Files.File; buf: ARRAY 256 OF CHAR; ch: CHAR;
      i: INTEGER; n: WORD;
BEGIN
  Out.Open;
  IF ~Files.Reset(f, "test.txt") THEN
    Out.String("Cannot open test.txt"); Out.Ln; RETURN
  END;
  i := 0;
  n := Files.BlockRead(f, ch, 1);
  WHILE n > 0 DO
    IF (ch = 0AX) OR (i = LEN(buf) - 2) THEN
      buf[i] := 0X;
      Out.String(buf); Out.Ln;
      i := 0
    ELSIF ch # 0DX THEN  (* skip CR *)
      buf[i] := ch; INC(i)
    END;
    n := Files.BlockRead(f, ch, 1)
  END;
  IF i > 0 THEN buf[i] := 0X; Out.String(buf); Out.Ln END;
  Files.Close(f)
END Run;

END Lines.
```

Build and run — one command does everything:
```bash
# All-in-one: dep-scan + compile + link in a single toc.exe invocation
# OBERON.OM is found automatically in CWD or alongside BIN/TOC.EXE
xt run --max=50000000 -c . BIN/TOC.EXE /ENTRY=Run Lines.Mod
xt run --max=10000000 -c . lines.exe
```
