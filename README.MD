# Trubo Oberon

### A self-hosting Oberon-07 compiler for 16-bit MS-DOS real mode

[![license](https://img.shields.io/badge/license-public%20domain-brightgreen)](LICENSE.TXT)
[![platform](https://img.shields.io/badge/platform-MS--DOS%20%2F%208086%20real%20mode-blue)](DOCS/XT.MD)
[![self-hosted](https://img.shields.io/badge/self--hosted-byte--stable-success)](TESTS/test_selfhost.sh)

[Oberon](https://en.wikipedia.org/wiki/Oberon_(programming_language)) is
Niklaus Wirth's successor to Pascal and Modula-2 — a small, strongly-typed
systems language designed to be compilable by a single programmer in a
single pass, with no preprocessor and (almost) no undefined behavior.
Oberon-07 (2007) is Wirth's own later simplification of the language.

> Wirth's Oberon-07, compiling itself, targeting a 1981 processor. Written
> entirely in Oberon, running on real DOS hardware — no C, no assembler
> front end, no host toolchain required at runtime.

This project implements a **practical DOS dialect** of Oberon-07: the core
language plus what real 16-bit systems programming needs — `SYSTEM`
intrinsics for port I/O and inline machine code, `FAR`/`NEAR` procedures,
typeless `VAR` parameters, and an `INLINE` mechanism for embedding raw
opcodes. See [`DOCS/OBERON07.EBN`](DOCS/OBERON07.EBN) for the authoritative
grammar and every deviation from the standard.

---

## Why this exists

There is no free, modern, actively-usable Pascal-family compiler that
targets (and works) 16-bit MS-DOS real mode. Borland stopped at Turbo Pascal 7 /
Borland Pascal 7 in the early '90s and never open-sourced it. FreePascal —
the natural place to look — has supported 16-bit `i8086` code generation
since around 2014, but it was always the neglected back corner of the
project: undermaintained, thin on runtime support, and never treated as a
first-class target the way its 32/64-bit backends are. I had been waiting
since the late 1990s for a serious support 16-bit target from the Free
Pascal and it never statify my expectations.

So this project doesn't try to be that. It picks Wirth's other, smaller
language — Oberon-07, Pascal's own successor — and builds a compiler for
it *from scratch*, purpose-built for 16-bit DOS real mode, with no
inherited 32-bit assumptions to work around. The compiler, linker,
dependency scanner, archive manager, and test tools are all written in
Oberon-07 and compile *themselves*, on the target architecture (8086 real
mode), from a single checked-in bootstrap binary. Feed it its own source
and it reproduces itself **byte-for-byte** — a full fixpoint, verified on
every change.

That means:

- No hidden C runtime. `SYSTEM.MOD` + a small `SYS.ASM` are the entire
  foundation.
- No 32-bit protected-mode escape hatch. Real segmented 8086 memory, real
  64 KB segments, real far pointers.
- A compiler that could, in principle, have been built in 1987 — but with
  the discipline of zero-heap-leak, byte-reproducible modern engineering
  practice behind it.

---

## Highlights

- **Self-hosting, byte-stable.** `toc /ENTRY=Run TOC.MOD` rebuilds the whole
  compiler in a single process; two consecutive generations are
  byte-identical. See [`TESTS/test_selfhost.sh`](TESTS/test_selfhost.sh).
- **Zero heap leaks, guaranteed.** Every compile and every link reports
  `0 leaked paragraphs` — enforced by `LeakGuard` instrumentation and
  regression tests, not just hoped for.
- **All-in-one driver.** `toc.exe` is the dep-scanner, incremental compiler,
  and smart linker in one binary and one command — no makefiles required to
  build an Oberon program.
- **Real DOS constraints, handled properly.** Per-module 64 KB code segments,
  far pointers (segment:offset), a large memory model, EMS-backed temp files,
  and a linker that streams instead of holding everything in RAM.
- **272-row regression manifest** plus DOS-side executable and unit-test
  suites — every codegen change is checked against real compiled/linked/run
  output, not just "it compiled."
- **Turbo Debugger-compatible debug info.** Compile with `(*$D+*)`, link with
  `/G`, and get a Borland TDS/TDINFO v2.08 block appended straight onto the
  `.EXE` — inspect with the included `tdinfo.exe`.
- **Linkable with external object files.** The linker consumes standard RDOFF2
  object files, so hand-written assembly modules assembled with NASM, YASM,
  or MSA2 (`-f rdf`) can be linked directly alongside Oberon-compiled
  `.rdf`/`.om` modules — no C shim required.

---

## Quick start

**Hello, world:**

```oberon
MODULE Hello;

IMPORT Out;

PROCEDURE Run*;
BEGIN
  Out.Open;
  Out.String("Hello, world!"); Out.Ln
END Run;

END Hello.
```

```bash
BIN\TOC.EXE /ENTRY=Run Hello.Mod
Hello.exe
```

---

## A slightly bigger taste of the language

```oberon
MODULE Example;
IMPORT Out;

TYPE
  PNode = POINTER TO Node;
  Node  = RECORD val: INTEGER; next: PNode END;

VAR head: PNode;

PROCEDURE Push*(val: INTEGER);
  VAR n: PNode;
BEGIN
  NEW(n); n^.val := val; n^.next := head; head := n
END Push;

PROCEDURE Pop*(): INTEGER;
  VAR v: INTEGER;
BEGIN
  v := head^.val; head := head^.next;
  RETURN v
END Pop;

PROCEDURE Run*;
  VAR i: INTEGER;
BEGIN
  Out.Open;
  FOR i := 1 TO 5 DO Push(i) END;
  WHILE head # NIL DO Out.Int(Pop(), 0); Out.Char(" ") END;
  Out.Ln
END Run;

END Example.
```

```
BIN\TOC.EXE /ENTRY=Run Example.Mod
Example.exe
5 4 3 2 1
```

See [`EXAMPLES/`](examples) for larger programs, including a Forth
interpreter.

---

## Language features

| Area | Support |
|------|---------|
| Types | `INTEGER`, `LONGINT` (32-bit), `WORD` (16-bit unsigned), `BYTE`, `CHAR`, `BOOLEAN`, `SET`, `REAL`/`LONGREAL` (x87), `ARRAY` (fixed/open/multi-dim), `RECORD` with single inheritance, `POINTER`, `FAR`/`NEAR` procedure variables |
| Control flow | `IF/ELSIF/ELSE`, `WHILE/ELSIF`, `FOR/BY` (negative step), `REPEAT`, `CASE` (INTEGER or CHAR, incl. ranges) |
| Procedures | `FAR`/`NEAR`, nested, `EXTERNAL`, `INLINE` (whole-body and statement forms), `FORWARD`, typeless `VAR` params, full actual-parameter type checking |
| Object model | `POINTER TO RECORD` extension, runtime `IS` type tests (compile-time folded where possible), `NEW`/`DISPOSE` with runtime type tags |
| Modules | Qualified imports, namespace isolation, `$L`/`$M`/`$R` directives, dead-code/unused-symbol warnings |
| `SYSTEM` | `ADR`, `SEG`, `OFS`, `PTR`, `GET`/`PUT`, `MOVE`, `FILL`, `PORTOUT`/`PORTIN`, `Intr`, `LSL`/`LSR`/`ASR`/`ROR`/`AND`/`IOR`/`XOR` |
| Expressions | Constant folding, implicit `INTEGER`→`REAL` coercion, `SET` operators, `IN`, array bounds checks (`$R+`/`$R-`), `SIZE`/`LEN` |
| Codegen | Strength reduction (mul/div/mod by powers of two and small constants → shift/add), peephole cleanup, RDOFF2 object format with smart (dead-module-eliminating) linking |

Full detail lives in [`DOCS/OBERLANG.MD`](DOCS/OBERLANG.MD) and
[`MANUAL.MD`](MANUAL.MD).

---

## Architecture

```
SCAN.MOD    tokens (sym, id, ival, rval, sval, line)
    |
PARSER.MOD  module / declarations / statements / types  (single-pass, no AST)
    |
PEXPR.MOD   expressions: designators, actual params, SYSTEM intrinsics
    |            |                |
SYMS.MOD   CGEN.MOD --> RDOFF.MOD   IMPORT.MOD --> .rdf object file
                              |
                          LINK.MOD  --> smart-linked MZ .EXE
```

`toc.exe` bundles all of the above plus dependency scanning into one binary.
`toc /ENTRY=Run MyProg.Mod` scans, compiles whatever's stale, and links — one
command, no makefile needed for user programs.

### Self-hosting bootstrap

```
BOOT/TOC.EXE   (checked-in seed binary — never touched by `make`)
  |-- SRC/LIB/*.MOD   -> BIN/OBERON.OM   (standard library archive)
  |-- SRC/TOC/*.MOD   -> BIN/TOC.EXE     (compiler + linker + dep-scan)

BIN/TOC.EXE
  |-- SRC/TOOLS/TOLIB.MOD   -> BIN/TOLIB.EXE    (archive manager)
  |-- SRC/TOOLS/RDFGREP.MOD -> BIN/RDFGREP.EXE  (RDOFF/.om/.exe inspector)
  |-- TESTS/TESTALL.MOD     -> BIN/TESTALL.EXE  (DOS-side test driver)
```

Rebuilding `SRC/TOC` with `BOOT/TOC.EXE` produces `toc1.exe`; rebuilding the
*same sources* with `toc1.exe` produces `toc2.exe`. `toc1.exe == toc2.exe`,
byte-for-byte, every time. That's the self-hosting proof, and it's run as a
regression test, not just a one-time milestone.

---

## Standard library

Fourteen modules, merged into one `BIN/OBERON.OM` archive:

| Module | Purpose |
|--------|---------|
| `SYSTEM` | Runtime: allocation, halt, FPU detection, INT calls, bitwise ops |
| `Out` / `Out87` | Formatted stdout, including REAL/LONGREAL (x87) |
| `In` | Buffered stdin: char, integer, long integer, token |
| `Files` | Buffered file I/O — open, read, write, seek, close; EMS-backed temp files |
| `Strings` | Length, Equal, Copy, Append, Pos, Insert, Delete, Extract |
| `IO` | Raw rider-based I/O to any DOS file handle |
| `Mem` | Raw heap: `Alloc`/`Free` with a 65 KB guard |
| `Dos` | Args, `Exec`, `FindFirst`, date/time, interrupts |
| `Time` | DOS packed date/time <-> `DateTime` record conversion (`PackTime`/`UnpackTime`) |
| `Crt` | Terminal control via INT 10h: cursor, clear, colour |
| `Math` | FPU math: sin, cos, sqrt, exp, ln, abs, … |
| `EMS` | Expanded-memory page-frame management |
| `Test` | Unit-test framework: `AddTest`, `RunTests`, `Assert*` |
| `RdfLoad` | Runtime RDOFF2 loader — dynamic code loading from a running program |

---

## Test suite

```bash
make test     # 294-row manifest — codegen bytes, RDOFF structure, error messages, exit codes
make testall  # + DOS-side executables (Section 17) and unit tests (Section 18)
```

Every codegen or language change is checked three ways: the compile-time
manifest (does it produce the right object bytes / the right diagnostic?),
DOS-side executables (does the linked program actually behave correctly when
run under `xt`?), and the self-hosting fixpoint (does the compiler still
reproduce itself?).

---

## Documentation

| File | Contents |
|------|----------|
| [`MANUAL.MD`](MANUAL.MD) | Language reference, ABI, library APIs, porting guide |
| [`DOCS/OBERON07.EBN`](DOCS/OBERON07.EBN) | Authoritative grammar for this dialect |
| [`DOCS/OBERLANG.MD`](DOCS/OBERLANG.MD) | Type sizes, calling convention, codegen patterns, SYSTEM intrinsics |
| [`DOCS/IMPLRULE.MD`](DOCS/IMPLRULE.MD) | DOS/portability rules, `.def` file format, emit conventions |
| [`DOCS/BUILD.MD`](DOCS/BUILD.MD) | Build instructions, `toc.exe` flags, linker internals |
| [`DOCS/TESTS.MD`](DOCS/TESTS.MD) | Test suite reference: running, adding, interpreting tests |
| [`DOCS/XT.MD`](DOCS/XT.MD) | `xt` emulator reference: options, trace format, debugging |
| [`DOCS/RDOFF2.MD`](DOCS/RDOFF2.MD) | RDOFF2 object file format specification |
| [`DOCS/TD-SPEC.MD`](DOCS/TD-SPEC.MD) | Turbo Debugger TDS/TDINFO format notes |
| [`DOCS/PORTING.MD`](DOCS/PORTING.MD) | Guide for porting code from C/Pascal |

---

## License

Public domain. See [`LICENSE.TXT`](LICENSE.TXT).
