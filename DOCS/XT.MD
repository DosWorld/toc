# XT Emulator — Reference

## What is XT

`xt` (XT/DW version 1.0.6, Copyright 2026 DosWorld / 2025 Electric Bolt Limited) is a
command-line MS-DOS 8086 emulator used by this project to run and test compiled `.EXE`
programs without a real DOS machine.

Binary location: `/Users/admin/bin/xt`

xt is a blackbox for you. investigation of emulator internals - is prohibited.

---

## Command-line usage

```
xt run   [--max=N] [-e KEY=VALUE]... [-c dir] program [args...]
xt trace [--max=N] [-e KEY=VALUE]... [--bp=SEG:OFS[:COND]]... [--wp=SEG:OFS:type]...
         [--dump=SEG:OFS:LEN]... [-c dir] program [args...]
xt int
xt help [run|trace]
```

| Sub-command | Description |
|-------------|-------------|
| `xt run`    | Execute a `.EXE` or `.COM` program |
| `xt trace`  | Execute with per-instruction trace written to stderr |
| `xt int`    | List all emulated INT handlers |

**Note:** `xt help` and `xt` with no arguments exit with code 255. That is normal — it is
not an error in your script. Always check stderr for the message, not just the exit code.

### Options (run and trace)

| Option | Description |
|--------|-------------|
| `--max=N` | Halt after N instructions (prevents infinite loops) |
| `-c dir` | Map host directory as the emulated C: drive root. Default: current directory. |
| `-e KEY=VALUE` | Set a DOS environment variable visible to the program. Repeatable. |
| `--env=KEY=VALUE` | Same as `-e KEY=VALUE` |

### Additional options (trace only)

| Option | Description |
|--------|-------------|
| `--bp=SEG:OFS` | Breakpoint at address (hex). Repeatable. |
| `--bp=SEG:OFS:REG==VAL` | Conditional breakpoint, e.g. `--bp=00A0:0050:AX==0003` |
| `--wp=SEG:OFS:type` | Watchpoint. type: `r`=read, `w`=write, `a`=access. Repeatable. |
| `--dump=SEG:OFS:LEN` | Dump memory region at program stop (hex). Repeatable. |

Supported registers for conditional breakpoints: `AX BX CX DX SI DI BP SP DS ES SS FLAGS.CARRY FLAGS.ZERO FLAGS.OVERFLOW`

### Exit codes

| Code | Meaning |
|------|---------|
| 0..254 | Program's own exit code (from INT 21h/4Ch) |
| 255 | XT error (bad arguments, program not found, execution error, or `--max` reached) |

`--max` reached counts as exit 255. Always filter `xt` stderr for the `Maximum instructions`
line to distinguish a normal `--max` stop from a real emulator error.

---

## Filesystem and path conventions

- The host directory passed with `-c dir` is mounted as `C:\`. Default: current directory.
- The DOS current directory inside xt starts at `C:\` (the root of the mount). Programs
  can `chdir` to subdirectories using `Dos.ChDir`; the path is tracked per-process.
- All filenames in program arguments must use DOS paths (`C:\lib\SYSTEM.OM` or just
  `SYSTEM.OM` for files in the root). Paths are case-insensitive inside xt.
- `OBERON_LIB` uses semicolon `;` as path separator (DOS convention), e.g.
  `-e "OBERON_LIB=C:\;C:\lib"`.
- **ALWAYS QUOTE any DOS path that contains a backslash** (`-c`, `-e OBERON_LIB=…`,
  and DOS-path program arguments).  A backslash is the shell's escape character, so
  an **unquoted** `\123\DIR` reaches xt as `123DIR` (backslashes silently eaten) and
  `OBERON_LIB=C:\lib` becomes `C:lib` — the library is then not found and the
  compile fails silently.  This is a **shell-quoting** issue, not an xt bug.
  Fix by single-quoting (`-e 'OBERON_LIB=C:\lib'`), double-quoting
  (`-e "OBERON_LIB=C:\lib"`), or doubling each backslash (`\\123\\DIR`).
  Single quotes are preferred — they are literal and need no further escaping.
  (Host `-c dir` paths normally use forward slashes — `-c /tmp/work`, `-c ../../`
  — which need no quoting unless they contain spaces, so this project's makefiles
  are already safe; the rule matters whenever a backslash DOS path is introduced.)
- **Do not leave stale zero-byte `.OM` files in the `-c dir` mount root.**
  The compiler reads `.def` content exclusively from inside `.om` archives (standalone
  `.def` files are ignored). A 0-byte or truncated `.om` causes import failures.

---

## Running the Oberon compiler (toc.exe) under xt

### Usage

```
toc.exe [/ENTRY=Proc] [/SYSTEM] [/M] <File.Mod>
```

All options are documented in [BUILD.MD](BUILD.MD).

### Example

```bash
WORKDIR=/tmp/xt_test
mkdir -p $WORKDIR/lib

# Copy library and compiler into the mount root
cp /Users/admin/dosbox-x/oberonc/BIN/OBERON.OM $WORKDIR/lib/
cp /Users/admin/dosbox-x/oberonc/BIN/TOC.EXE $WORKDIR/
cp Hello.Mod $WORKDIR/

# Compile (OBERON_LIB uses DOS path inside xt)
xt run --max=50000000 -e "OBERON_LIB=C:\lib" -c $WORKDIR toc.exe Hello.Mod

# Compile + link with entry point (one step — no separate linker needed)
xt run --max=50000000 -e "OBERON_LIB=C:\lib" -c $WORKDIR toc.exe /ENTRY=Run Hello.Mod
```

- `--max=50000000`: 50 million instructions is enough for compilation.
- Output `.om` file is written into `$WORKDIR/` (the C:\ root).
- On error, toc.exe writes a message to stderr and exits non-zero. **Always check the exit
  code.** A non-zero exit means compilation failed — do not proceed to link.

---

## Linking

Linking is embedded in `toc.exe` — there is no separate linker binary.
Use `/ENTRY=ProcName` to compile and link in one step:

```bash
xt run --max=50000000 -e "OBERON_LIB=C:\lib" -c $WORKDIR \
    toc.exe /ENTRY=Run Hello.Mod
```

`toc.exe` performs dep-scan → incremental compile → smart link → MZ EXE output.
See [BUILD.MD](BUILD.MD) for full options.

---

## Running a compiled program

```bash
xt run --max=5000000 -c /tmp/xt_test hello.exe
```

With arguments:
```bash
xt run --max=5000000 -c /tmp/xt_test hello.exe arg1 arg2
```

---

## Using xt trace for debugging

`xt trace` is the primary debugging tool. It prints every instruction to stderr before
executing it: address, hex bytes, disassembly, and all register values. Use it whenever
a program crashes, hangs, or produces wrong output.

### Workflow

**Step 1 — Confirm the crash with a short run:**
```bash
xt trace --max=200 -c /tmp/xt_test program.exe 2>&1 | tail -30
echo "exit: $?"
```
The last few lines show what the program was doing just before it stopped.

**Step 2 — Find the bad address:**
From the tail output, note the `CS:IP` of the instruction that looks wrong (bad register
value, wrong memory access, unexpected jump). Example: `00A0:01B4`.

**Step 3 — Set a breakpoint and narrow down:**
```bash
xt trace --max=50000 --bp=00A0:01B4 -c /tmp/xt_test program.exe 2>&1 | tail -50
```
Trace stops at that address. Inspect registers (AX, BX, DS, ES, BP, SP) in the output.

**Step 4 — Add watchpoints or conditional breakpoints if needed:**
```bash
# Stop when AX becomes 0 at that address
xt trace --max=50000 --bp=00A0:01B4:AX==0000 -c /tmp/xt_test program.exe 2>&1 | tail -50

# Stop on any write to a suspicious memory location (e.g. DS:0030)
xt trace --max=50000 --wp=00B0:0030:w -c /tmp/xt_test program.exe 2>&1 | tail -50
```

**Step 5 — Dump memory at stop:**
```bash
xt trace --max=50000 --bp=00A0:01B4 --dump=00B0:0000:64 -c /tmp/xt_test program.exe 2>&1 | tail -50
```

### Interpreting the register dump on crash

When xt stops (either `--max` reached or breakpoint hit), it prints a register dump and
a stack frame dump. Key things to check:

- **IP**: where exactly the program stopped
- **AX/DX**: return value or scratch — what was being computed
- **BP**: current frame pointer — used to read local variables and parameters
- **SP**: stack pointer — if SP > expected, the stack may have been corrupted
- **DS**: data segment — all `[BP+n]` accesses use SS, all `[data_ofs]` uses DS
- **ES**: extra segment — used for far pointer dereferences

Stack frame dump (printed at crash) shows `[SS:BP+n]` values — compare with expected
parameter/local layout from the calling convention (see `DOCS/OBERLANG.MD`).

### Tracing a compiler run

```bash
# Trace toc.exe compiling Hello.Mod — first 10000 instructions
xt trace --max=10000 -e "OBERON_LIB=C:\lib" -c /tmp/xt_test \
    toc.exe Hello.Mod 2>&1 | head -200

# Find all INT 21h calls (file I/O, memory allocation)
xt trace --max=2000000 -e "OBERON_LIB=C:\lib" -c /tmp/xt_test \
    toc.exe Hello.Mod 2>&1 | grep "int 21h"
```

---

## Trace format

Each line of `xt trace` output (written to stderr):

```
CS:IP | hex-bytes | disassembly | AX=,BX=,CX=,DX=,SI=,DI=,BP=,DS=,ES= | SS:SP= | FLAGS=
```

Registers shown are **state before** the instruction executes. Flags: `C` (carry),
`P` (parity), `A` (aux carry), `Z` (zero), `S` (sign), `T` (trap), `I` (interrupt),
`D` (direction), `O` (overflow); `-` = clear.

Example:
```
00F1:0070 | CD 21 | int 21h | AX=4801,BX=FFFF,CX=0000,DX=0000,SI=0000,DI=0000,BP=0000,DS=00A0,ES=00A0 | SS:SP=00C0:1FFA | FLAGS=-------I-
```

### Breakpoints (trace only)

```bash
# Stop at address 00A0:0050
xt trace --max=100000 --bp=00A0:0050 -c /tmp/xt_test hello.exe

# Stop at 00A0:0050 only when AX==0003
xt trace --max=100000 --bp=00A0:0050:AX==0003 -c /tmp/xt_test hello.exe

# Watchpoint: stop on any write to 00B0:0100
xt trace --max=100000 --wp=00B0:0100:w -c /tmp/xt_test hello.exe

# Dump 32 bytes at DS:0010 when stopped
xt trace --max=100000 --bp=00A0:0050 --dump=00B0:0010:20 -c /tmp/xt_test hello.exe
```

Memory layout for loaded EXE programs:
- PSP always at `0x0090:0x0000` (256 bytes)
- Code segment starts at `0x00A0:0x0000` (relocatable)
- Stack segment typically at `0xF000:0xF000` (for EXE files)

---

## Setting up a test directory

```bash
WORKDIR=/tmp/xt_test
mkdir -p $WORKDIR/lib

# Library and compiler
cp /Users/admin/dosbox-x/oberonc/BIN/OBERON.OM $WORKDIR/lib/
cp /Users/admin/dosbox-x/oberonc/BIN/TOC.EXE $WORKDIR/

# Source files to compile go in the root
cp MyModule.Mod $WORKDIR/
```

**Important:** check for and remove any stale zero-byte `.OM` files (standalone `.DEF`
files are ignored by the compiler):
```bash
find $WORKDIR -maxdepth 1 -size 0 -iname "*.om" -print
# Delete any found
```

---

## Debugging tips

### Always check the exit code

```bash
xt run --max=5000000 -c /tmp/xt_test program.exe
echo "exit: $?"
```

Exit 255 from xt means either `--max` was reached or xt itself had an error. Look at
xt's stderr output: it prints `Maximum instructions limit: N` when `--max` fires, or
an error message otherwise.

### Narrowing a crash with trace

```bash
# Short run to see last instructions before crash
xt trace --max=500 -c /tmp/xt_test program.exe 2>&1 | tail -30

# Find specific instruction address, then set a breakpoint
xt trace --max=100000 --bp=00A0:00AB -c /tmp/xt_test program.exe 2>&1 | tail -20
```

### Inspecting compiler output

Use `BIN/RDFGREP.EXE` under xt to inspect `.om`/`.rdf` artefacts:

```bash
# Check if OC.OM contains a specific IMPORT
xt run -c /tmp/xt_test BIN/RDFGREP.EXE has-import OC.RDF SYSTEM__init

# Check code-segment prefix
xt run -c /tmp/xt_test BIN/RDFGREP.EXE code-starts HELLO.RDF "55 8B EC"

# Extract a member from a .om archive
xt run -c /tmp/xt_test BIN/RDFGREP.EXE om-extract HELLO.OM HELLO.RDF HELLO.RDF
```

For byte-exact binary comparison, use `cmp -s` on the extracted `.rdf` files.

---

## Known limitations

- No interrupt 10h (BIOS video) — screen output only via INT 21h
- No timer interrupts — real-time behavior not simulated
- Program must exit via INT 21h/4Ch; `--max` reached exits with code 255
- No network, no sound, no mouse
- `Dos.Exec` (INT 21h/4Bh) is supported: child processes run inside the same
  xt instance; exit code returned correctly via INT 21h/4Dh.  Performance:
  each `Dos.Exec` spawn takes roughly the same CPU time as a top-level `xt run`
  invocation of that program (~2 s for `toc.exe` on typical hardware)
- **EMS (INT 67h) emulation — re-verified 2026-06-25 against the current `xt`
  build; no known open bugs.**  Detection (`INT 21h/AH=3567h` returning the
  `EMMXXXX0` signature at `ES:000Ah`), Alloc/Free (AH=43h/45h), Get Handle
  Pages (AH=4Ch), Reallocate Pages (AH=51h), and Move Memory Region (AH=57h,
  including with multiple concurrent handles) all work correctly.
  `EMS.Detect`/`EMS.Present` return TRUE, single- and multi-handle AH=57h
  round trips are byte-exact, and `EMS.Realloc` (AH=4Ch + AH=51h) completes
  correctly. A prior investigation flagged AH=4Ch/51h as unhandled and
  multi-handle AH=57h as corrupting data; the former was an xt bug that has
  since been fixed, the latter turned out to be a move-descriptor field-layout
  bug in `EMS.MOD`'s `DoMove` (conventional-memory segment was written into
  the wrong struct field), now fixed there.

## Recent xt changes (2026-06-28)

- **`xt trace` now prints the executed-instruction count at the end of the run.**
  Useful for *small* runs where the full per-instruction trace is manageable.
  For the large `toc Parser.Mod` benchmark (~40 M instructions) the trace
  output is far too large to use this way — use an `xt run --max` binary
  search instead for Metric A on big runs.
- **`Truncate` now works** under xt.  This affects `Files` temp-file behaviour
  (the disk-backed `ReWriteTemp` path and any `Files.Truncate` use); a previously
  no-op truncate is now honored.
