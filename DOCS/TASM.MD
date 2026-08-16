# TASM — user manual

`tasm.exe` is this project's Oberon-hosted 8086 assembler: it reads a `.asm`
source file and writes a single RDOFF2 `.rdf` object file. No listing file,
no other object format, no linker built in (linking is `toc.exe`'s or
`tlink.exe`'s job — see [BUILD.MD](BUILD.MD) and [PORTING.MD](PORTING.MD)
§1.7).

`tasm` understands **two source dialects**, selected by `/LNG=`:

- **`/LNG=nasm`** (default) — a practical subset of real NASM syntax.
  This is the dialect every hand-written `.ASM` file in `SRC/LIB/` is
  written in, and the one `tasm`'s own parser (`SRC/TASM/{SCAN,SYM,LEX,
  DIR,ENC,PARSE}.MOD`) understands natively.
  See **§1 The NASM dialect** below.
- **`/LNG=turbo`** — Borland Turbo Assembler 5.0 source (MASM and Ideal
  mode). A source-to-source converter (`SRC/TASM/TURBO.MOD`, module
  `Turbo`) rewrites the file into the NASM dialect above, then feeds the
  result through the exact same parser. See **§2 The Turbo dialect** below.

Both dialects produce byte-for-byte the same kind of RDOFF2 object; there
is no "Turbo mode" object format, only a "Turbo mode" *front end* that ends
up calling the identical NASM-subset assembler.

---

## 0. Command-line usage

```
tasm.exe [/LNG=nasm|turbo] [/LOG=level] [-Dname[=value]]... file.asm
tasm.exe /BIN=code|data /NAME=GlobalName [/LOG=level] file.bin
```

- Exactly one positional argument (the input path). The output filename
  is auto-derived by replacing the extension with `.RDF` (uppercase 8.3):
  `File.asm` → `File.RDF`.
- `/LNG=nasm|turbo` — dialect switch, case-insensitive, defaults to
  `nasm`. Purely additive: no existing invocation changes behavior.
- `/LOG=debug|info|warn|error` — diagnostic verbosity, case-insensitive,
  same convention as `toc.exe`.
- `-Dname[=value]` (may repeat) — CLI predefine, applied as if
  `%define name value` appeared before line 1 of the source. A later
  source-level `%define` of the same name overwrites it. Not valid with
  `/LNG=turbo` combined with `/BIN=` (bin2obj mode never runs any parser
  at all, Turbo or NASM).
- `/BIN=code|data /NAME=GlobalName file.bin` — **bin2obj mode**: wraps an
  arbitrary binary blob (< 64 KB) into an RDOFF2 object with the blob as
  the named segment's entire content and one `GLOBAL` record at offset 0.
  No parser (NASM or Turbo) runs in this mode at all; `/LNG=turbo` is
  rejected together with `/BIN=`.

`/LNG=turbo` writes a temporary `File.NAS` (the converted NASM-subset
source) alongside the input, feeds it through the same assemble pipeline
`/LNG=nasm` uses, and deletes `File.NAS` only on full success. If either
the conversion or the subsequent assembly fails, `File.NAS` is left on
disk so the intermediate can be inspected by hand.

---

## 1. The NASM dialect

This is the dialect `tasm` was built for first, and the one every
production `.ASM` file in this repository (`SYSTEM.ASM`, `EMS.ASM`,
`DETECT.ASM`, `WINCB.ASM`, `KMOUSE.ASM`, `SCREEN.ASM`) is written in.

### 1.1 What's covered

- **General-purpose and segment/string instructions**, including
  `LDS`/`LES`.
- **Shift/rotate**, by the literal `1` or by `CL` only — matching real
  8086 (no 186+ immediate-count shifts).
- `MUL`/`DIV`/`IMUL`/`IDIV` (`IMUL`'s 2-/3-operand 186+ forms are **not**
  supported — one-operand `IMUL r/m` only).
- The full `Jcc` family, `LOCK`/`REP`/`REPE`/`REPNE` prefixes.
- `BITS`/`CPU` directives.
- `SECTION .text` / `.data` / `.bss`.
- `GLOBAL` (export a symbol) and `EXTERN` (import one) — `IMPORT` is
  accepted as a TASM-added synonym for `EXTERN`.
- `STRUC` / `ENDSTRUC` with `RESB`/`RESW`/`RESD` fields.
- `RESB`/`RESW`/`RESD` — valid only inside `SECTION .bss` (outside a
  struc) or a `STRUC`/`ENDSTRUC` block.
- Preprocessor: `%DEFINE`/`%UNDEF`, `%IFDEF`/`%ELSE`/`%ENDIF`,
  `%INCLUDE "FILE.INC"`, `%MACRO name nparams ... %ENDMACRO`,
  `%REP count ... %ENDREP` (see §1.3a), `%ASSIGN name expr`.
- Data: `DB`/`DW`/`DD`, `TIMES` (including `TIMES n DW label`, N
  independently relocated words), `EQU`.
- Operand qualifiers: `SEG`, `BYTE`/`WORD`/`FAR`/`SHORT`/`NEAR`; a
  `BYTE`/`WORD` qualifier may also appear as the leading token of the
  SECOND operand (`mov [x], word 0`) instead of prefixing the memory
  operand itself (`mov word [x], 0`) — non-standard but accepted.
- Segment-override prefix on a memory operand as either `[seg:expr]`
  (inside the brackets) or `seg:[expr]` (outside, real NASM's own usual
  spelling) — both produce identical encodings.
- Constant-expression grammar: `+ - * / % << >> & | ^` (full NASM
  precedence) and parens, over integer literals, `EQU`/`%assign` names,
  and (additively only) a label address — usable anywhere a constant
  expression is accepted, including as the value in a `DW`/`DD` list
  (`dw NAME*2 + (flag & 1)`).
- A dot-local label (`.name`) may appear inside `[ ]`, with or without a
  segment override (`[cs:.loop]`).
- Character-literal immediates (`'A'`, `"x"`).
- `-Dname[=value]` CLI predefines (see §0).
- An out-of-range `Jcc`, forward- or backward-referenced, auto-widens to
  the 8086-only `Jncc short +3 / JMP near target` idiom instead of
  erroring (see §1.5a).

`EXTERN`/`IMPORT` symbols resolve through RDOFF2 `RDFREC_IMPORT` records,
so a `.rdf` produced by `tasm` can reference a symbol defined in another
module exactly like real NASM output — but a cross-module call **must**
be written `CALL FAR target`, never a bare `CALL` (see §3 below).

### 1.2 `%include`

```
%include "FILE.INC"
```

Textual inclusion, resolved relative to the current working directory (no
search path). Nested up to 8 levels deep; a file including itself,
directly or transitively, is a fatal "recursive %include" error. Skipped
without even being opened when it sits inside a false `%ifdef` branch, so
an `%ifdef DOS_BUILD` / `%include "dosonly.inc"` idiom works even when
`dosonly.inc` does not exist in a build that never defines `DOS_BUILD`.

### 1.3 `%macro` / `%endmacro`

```
%macro PushAll 2
    push %1
    push %2
%endmacro

    PushAll ax, bx
```

- `NPARAMS` is 0..9; inside the body, `%1`..`%9` substitute the
  corresponding invocation argument.
- `%%ident` expands to a macro-local, per-invocation-unique label
  (`?Mk?ident`, `k` a counter) — use it for any label declared inside the
  macro body that must not collide across two expansions.
- The body is captured as raw text (byte-exact — comments, strings, and
  spacing preserved) up to a 4096-byte cap.
- **Not supported:** default/greedy parameters (`%macro x 1-3`), `%0`,
  `%rotate`, `%rep`, `%ifmacro`, overloading a macro name by arity. A
  nested `%macro` definition, or a macro that invokes itself past the
  same 8-level depth `%include` uses, is a fatal error, not a hang or a
  silently wrong expansion.

### 1.3a `%rep` / `%endrep`, `%assign`

```
        %assign _y 0
        %rep    4
        dw      _y*2
        %assign _y _y+1
        %endrep
```

- `COUNT` is a full constant expression (same grammar as `EQU`/`TIMES`),
  evaluated **once** before the body is captured — matching real NASM,
  the body's own `%assign` side effects never change `COUNT` after the
  fact. `COUNT <= 0` is accepted and simply produces zero iterations.
- The body is captured as raw text, exactly like `%macro`'s own body
  (byte-exact, 4096-byte cap), and replayed `COUNT` times; a nested
  `%rep` is a fatal "nested %rep not supported" error, same restriction
  `%macro` has on nesting itself.
- `%assign name expr` defines or **redefines** a numeric constant — unlike
  `EQU` (fatal on a differing redefinition), a `%assign` name may be
  reassigned freely, which is what makes a `%rep`-body counter (`_y` in
  the example above) work. Resolves through the same `EQU`-constant path
  everywhere a constant expression is accepted (`ParseConstExpr`'s
  grammar), so a `%assign`'d name is usable identically to an `EQU` name.

### 1.4 `EQU`

```
BUFSIZE EQU 128
COMBO   EQU BUFSIZE*2+BASE
```

`expr` is a constant integer expression over `+ - * / % << >> & | ^` (full
NASM precedence) and parens; its terms are integer literals or
previously-defined `EQU`/`%assign` constants. Unlike `%define`, an `EQU` name is a
real symbol (stored as a `SegConst` entry in the label table, not the
text-substitution table): it never self-expands on its own definition
line, and it resolves to a plain absolute immediate — no relocation —
wherever referenced, including as a `RESB`/`RESW`/`RESD` count. Using an
`EQU` name as a branch target is a "target must be a label" error, not a
silent jump to its numeric value. Only constant-integer right-hand sides
are accepted — no label-address or forward-reference arithmetic.

### 1.5 `DB`/`DW`/`DD` value lists

Accepted item forms:
- numeric literals,
- quoted strings — `DB` only, each character emitted as one byte,
- `EQU`/`%assign` constants, with a trailing arithmetic tail using the
  full `+ - * / % << >> & | ^` grammar (§1.4's expression grammar —
  `dw NAME*2 + (flag & 1)`, not just a `+N`/`-N` tail),
- for `DW`/`DD` only, a **bare label address**, emitted as a
  width-2/width-4 relocation respectively (`DD`'s "32-bit address" is the
  label's own 16-bit in-module offset, zero-extended into the low word —
  this assembler has no real 32-bit address space).

`DB` deliberately does **not** accept a bare label — it has no
relocation-emission path, so silently truncating a label's address to one
byte would corrupt data instead of just being a feature gap. Use `DW` or
`DD` for label addresses.

`TIMES n DB/DW/DD val` (single-value form only) is supported. `TIMES n DW
label` is also supported (unlike `DB`/`DD`): it emits `n` independently
relocated words, each pointing at `label` — useful for filling a
dispatch/jump table with `n` copies of the same handler address
(`times 16 dw NotImplemented`).

### 1.5a `Jcc` auto-widen (out-of-range short branches)

An unqualified `Jcc` (no explicit `SHORT`) whose target is out of rel8
(±127-byte) range auto-widens instead of failing — forward- or
backward-referenced alike:

```
Jncc    short SKIP     ; 70h+(cc XOR 1), inverted condition, rel8=03h
jmp     near TARGET    ; E9h rel16 -- plain 8086 near jmp, no 386 needed
SKIP:
```

5 bytes total instead of 2, matching what real NASM itself emits for an
out-of-range `Jcc`. `LOOP`/`LOOPE`/`LOOPZ`/`LOOPNE`/`LOOPNZ`/`JCXZ` do
**not** auto-widen (each has its own CX side effect an invert+JMP wrapper
cannot preserve) — those stay rel8-only, fatal on overflow, same as
`Jcc SHORT target` written explicitly. `Jcc SHORT target` written
explicitly also stays rel8-only and fatal on overflow, for any target —
`SHORT` is a hard requirement, not a hint.

A forward reference (target not yet assembled at the point the branch is
first sized) is handled by rerunning Pass 1 itself to a fixed point
before Pass 2 ever starts: assume every `Jcc` short, widen the ones that
don't fit, rerun, repeat until the total code size stops changing (the
same "quick winner" algorithm real assemblers use for this — converges
in 1-2 reruns for any real source; internally bounded at 8 reruns as a
fatal "did not converge" safety net, never expected to trigger). A
target that is STILL out of range after convergence is a hard
"branch target out of short (rel8) range — restructure source" error —
this can only happen if the branch's own true distance exceeds what any
finite widening could reach, not a real-world case for an 8086-sized
program.

### 1.6 Bin2obj mode (`/BIN=`)

See §0 above and [PORTING.MD](PORTING.MD) §1.6 for the full description —
it bypasses the assembler pipeline (NASM and Turbo alike) entirely and is
documented there rather than duplicated here.

### 1.7 What's explicitly out of scope

No current `.ASM` file in this repository needs any of the following, and
per this project's Simplicity First rule they are not speculatively
added:

- `[label+register]` combined addressing (a data-segment label combined
  with a base register in one bracket, e.g. `MOV AL, [spinnerChars+BX]`).
  Work around it with `MOV reg, label` (load the address) then
  `ADD reg, indexReg` then `[reg]` — three instructions instead of one
  addressing form.
- 32-bit/protected-mode instruction forms.
- `IMUL`'s 2-/3-operand forms (186+ only).
- `%macro` default/greedy params, `%0`, `%rotate`, `%ifmacro`, macro
  overloading by arity. (`%rep`/`%endrep` IS supported — see §1.3a.)
- `%if`/`%elif` numeric preprocessing — only `%ifdef`/`%ifndef` exist.
- `struc` nesting, `group`/`class` segment attributes, `org`, external
  linker scripts.
- General FPU operand/addressing-mode support — the three trivial
  no-operand FPU opcodes `FNINIT`/`FSTCW`/`FWAIT` (used by `SYSTEM.ASM`)
  are supported as plain no-operand mnemonics; nothing else FPU-related
  is. Every other bit of FPU code in this repository is hand-written
  `INLINE(...)` byte sequences inside `.MOD` files, not `.ASM` source.

---

## 2. The Turbo dialect (`/LNG=turbo`)

`/LNG=turbo` treats the input as Borland Turbo Assembler 5.0 source,
either **MASM mode** (`name PROC ...`, `label:`, TASM's classic syntax)
or **Ideal mode** (`PROC name ...`, TASM's stricter, MASM-incompatible
mode entered with the `IDEAL` directive). The converter auto-detects
which form a given line uses; a single file may freely use both, and
most fixtures in this repository's own tests are written in Ideal mode
since that's the form the `IDEAL` directive selects.

The converter works **line by line, left to right**: each source line is
classified by its leading token (a label, a directive, a mnemonic, a data
definition, or a macro/conditional keyword) and rewritten into one or
more NASM-subset output lines. There is no symbolic model of TASM's own
segment/group/model system — `.MODEL`, `ASSUME`, and friends are either
translated into their nearest flat-`SECTION` equivalent or dropped with
an explanatory note (see §2.9).

**Nothing is dropped silently.** Every judgment call, approximation, or
manual follow-up step the converter has to make is written into the
output as a `; T2NASM: ...` comment. Whenever you convert an unfamiliar
file, search its `.NAS` output for `T2NASM:` and read every hit before
trusting the result. A file that fails to assemble after conversion
leaves its `.NAS` on disk specifically so you can do this.

### 2.1 What the Turbo dialect covers, dialect by dialect

The table below lists Turbo Assembler constructs this converter
recognizes. "Full" means the construct is translated into working NASM
code with equivalent behavior (possibly plus an advisory note). "Partial"
means only part of the real Turbo Assembler feature is handled — see the
linked subsection. Anything not listed here is **not** recognized: an
unknown directive keyword is kept as a `; T2NASM: unrecognized TASM
directive '...'` comment rather than translated, and an unknown mnemonic
falls through to the plain-instruction path unchanged (so it assembles
only if the underlying NASM-subset assembler itself understands it).

| Feature | Coverage |
|---|---|
| `IDEAL`/`MASM` mode declaration | Full — normalized transparently; both forms parse throughout |
| `.MODEL`, `.CODE`/`CODESEG`, `.DATA`/`DATASEG`, `.DATA?`/`UDATASEG`, `.CONST`, `.STACK`/`STACK`, `.FARDATA[?]`/`FARDATA[?]` | Full — see §2.9 |
| `SEGMENT`/`ENDS`/`GROUP` (raw, non-simplified segments) | Full — see §2.9 |
| `.STARTUP`/`STARTUPCODE`, `.EXIT`/`EXITCODE` | Full — canned prologue/exit expansion, see §2.9 |
| `PROC`/`ENDP`, `NEAR`/`FAR`, `ARG`, `LOCAL`, `USES`, `RET`/`RETN`/`RETF` | Full — complete calling-convention machinery, see §2.2 |
| `PASCAL`/`BASIC`/`FORTRAN`/`C`/`CPP`/`SYSCALL`/`STDCALL`/`PROLOG`/`NOLANGUAGE` | Full — see §2.2 |
| Extended `CALL target LANGUAGE, arg1, arg2, ...` | Full — see §2.2.4 |
| `STRUC`/`ENDS` (plain field layout) | Full — see §2.3 |
| `UNION` | Partial — see §2.3 |
| `RECORD` + `WIDTH`/`MASK` | Full — see §2.4 |
| `SETFIELD`/`GETFIELD`/`TESTFLAG`/`MASKFLAG`/`SETFLAG`/`FLIPFLAG` | Full — see §2.4 |
| OOP `STRUC ... METHOD { }`, `TBLINST`, `TBLINIT`, `CALL inst METHOD name` | Full — see §2.5 |
| `MACRO`/`ENDM`, `LOCAL` (in-macro), `EXITM`, `PURGE` | Partial — see §2.6 |
| `GOTO`/`:tag` | Partial — see §2.6.3 |
| `REPT` | Full (as `%rep`) |
| `WHILE` | Partial — see §2.6.4 |
| `IRP`/`IRPC` | Full, expanded at conversion time — see §2.6.5 |
| `CATSTR`/`SUBSTR`/`SIZESTR` | Full |
| `INSTR` | Not supported — left as a comment, see §2.6.6 |
| `IFDEF`/`IFNDEF`/`ELSEIFDEF`/`ELSEIFNDEF`/`ELSE`/`ENDIF` | Full |
| `IFIDN`/`IFIDNI`/`IFDIF`/`IFDIFI` | Full |
| `IFB`/`IFNB` | Partial — approximated, see §2.7 |
| `IF1`/`IF2` | Partial — always-true approximation, see §2.7 |
| `IF`/`IFE`/`ELSEIF`/`ELSEIFE` (numeric) | Full |
| `ERR`, `ERRIFDEF`, `ERRIFNDEF` | Full |
| `DB`/`DW`/`DD`/`DQ`/`DT` + `DUP`/`?` | Full — see §2.8 |
| `DF`/`DP` (48-bit far pointer) | Partial — split into `dd`+`dw`, see §2.8.3 |
| `ORG`, `EVEN`, `EVENDATA`, `ALIGN` | Full |
| `PUBLIC`/`EXTRN`/`EXTERN`/`GLOBAL`/`COMM` | Full — see §2.9.3 |
| `INCLUDE` | Full (as `%include`) |
| `INCLUDELIB`, `ALIAS` | Not supported — linker-level, left as a note, see §2.9.4 |
| `ENUM` | Full — see §2.10 |
| `TYPEDEF` | Partial — becomes an untyped `%define`, see §2.11 |
| `LABEL` | Full |
| `PROCTYPE`/`PROCDESC` | Full (no-op — compile-time-only in real TASM too) |
| `RADIX`/`.RADIX` | Full — see §2.12 |
| `.8086` .. `.586`/`.586P`, `.8087`..`.587` | Full/no-op — CPU level maps to `cpu N`; FPU-level directives are dropped (NASM enables FPU mnemonics automatically) |
| `@@name` local labels, `@@name` in `ARG`/`LOCAL` | Full — see §2.13 |
| `WARN`/`NOWARN`, `DISPLAY`/`%OUT` | Partial/full — see §2.9.4 |
| `NAME`, `VERSION`, `DOSSEG`, `.SEQ`, `LOCALS`/`NOLOCALS`, `END` | No-op — silently dropped, no NASM equivalent needed |

### 2.2 Procedures: `PROC`/`ENDP`, `ARG`, `LOCAL`, `USES`, calling conventions

```
Add PROC C x:WORD, y:WORD
    mov ax, [x]
    add ax, [y]
    ret
ENDP Add
```

`PROC` accepts, in any order after the name: `NEAR`/`FAR` (defaults to
`NEAR`), and a calling-convention keyword — `PASCAL`, `BASIC`, `FORTRAN`
(the callee-cleans-the-stack family, TASM's own default), or `C`, `CPP`,
`SYSCALL`, `STDCALL`, `PROLOG` (the caller-cleans-the-stack family), or
`NOLANGUAGE` (no automatic prologue/epilogue at all — a bare `push
bp`/`mov bp,sp` must be hand-written if the body then uses `ARG`-style
stack access; the converter emits an advisory note for this case).

#### 2.2.1 `ARG` and `LOCAL`

```
Draw PROC PASCAL buf:WORD, spr:DWORD
    LOCAL tmp:WORD
    ...
ENDP Draw
```

Each `ARG`/`LOCAL` entry is `name[:type[:count]]`, where `type` is
`BYTE`/`WORD`/`DWORD`/`FAR`/`PTR`/`NEAR` (byte promotes to a full word —
you cannot `PUSH` a raw byte) and an optional `:count` repeats the slot
`count` times.

- `LOCAL` is always a single forward streaming pass: the first-declared
  name gets `[bp-2]`, the next `[bp-4]`, and so on, regardless of calling
  convention.
- `ARG` offset assignment depends on the **push direction** the PROC's
  language implies:
  - `C`/`CPP`/`SYSCALL`/`PROLOG`/`STDCALL` push **right-to-left**, so the
    first-*declared* name gets the *smallest* offset (`[bp+4]` for a NEAR
    proc, `[bp+6]` for FAR).
  - `PASCAL`/`BASIC`/`FORTRAN`/`NOLANGUAGE` push **left-to-right**, so
    the first-*declared* name gets the *largest* offset.

  Either way, **write your `ARG` list in the procedure's natural
  left-to-right declared-parameter order** — the converter reverses the
  assignment internally for the PASCAL-family case so the source doesn't
  have to. Each name becomes a `%define name bp+N` / `%define name bp-N`
  line, undone with `%undef` at the matching `ENDP` so a later `PROC`
  reusing the same short name gets its own binding, not a stale one.

- `USES reg1, reg2, ...` pushes the listed registers, in order, right
  after the frame is set up; the matching pops (in reverse order) are
  injected before every `RET`/`RETF` in the procedure automatically.

A `PROC` that declares none of `ARG`/`LOCAL`/`USES` gets **no** `push
bp`/`mov bp,sp` prologue at all — matching real TASM, which only builds a
stack frame when one is actually needed.

#### 2.2.2 `RET`/`RETN`/`RETF`

Each `RET` inside a `PROC` with a language convention is expanded to the
full epilogue: pop `USES` registers (reverse order), `mov sp,bp` if any
`LOCAL` reserved space, `pop bp`, then `ret`/`retf` with the callee's
total `ARG` byte count as the cleanup operand — **only** for the
callee-cleans-the-stack family (`PASCAL`/`BASIC`/`FORTRAN`); the
caller-cleans family (`C`/`CPP`/`SYSCALL`/`PROLOG`/`STDCALL`) gets a
plain `ret`/`retf` with no operand, since the caller cleans up. `RETF`
forces the procedure's distance to `FAR` for that return, matching TASM.
A `PROC` with no language convention (`NOLANGUAGE`) or not currently open
at all gets its `RET` passed through as a bare `ret`/`retf` with whatever
explicit operand was written.

#### 2.2.3 `@@name` local labels vs. `ARG`/`LOCAL` names

Turbo Assembler's `@@name` labels are lexically scoped to the enclosing
`PROC`. The converter rewrites every `@@name`:

- to NASM's own dot-local syntax `.name` when it's a genuine jump-target
  `LABEL`/reference (NASM already scopes `.name` per enclosing non-local
  label — exactly TASM's own semantics, no extra bookkeeping needed), or
- to `_name` when it's one of the current `PROC`'s own `ARG`/`LOCAL`
  names (NASM's `%define` cannot target a name starting with `.`), with
  the surrounding `[...]` added or omitted exactly as an ordinary memory
  reference would need it (an `OFFSET`-context reference or a `LEA`
  operand needs the bracket-free address form; a plain load/store needs
  it bracket-wrapped).

A bare `@@` with no identifier following it (MASM-compat mode's
anonymous numbered local label, paired with single-`@` `@F`/`@B`
forward/backward references) is a distinct, rarer TASM feature this
converter does **not** implement, and is left untouched.

#### 2.2.4 Extended `CALL` (argument-list form)

```
CALL Add PASCAL, ax, [bx]
CALL Sub1 C, arg1, arg2
```

`CALL target LANGUAGE, arg1, arg2, ...` pushes each *argument* (not each
space-separated token within one argument) in the direction the language
requires — declared order for `PASCAL`/`BASIC`/`FORTRAN`, reversed for
`C`/`CPP`/`SYSCALL`/`STDCALL` — then emits the plain `call target`. The
language keyword here must agree with the one on the callee's own `PROC`
header, or the callee's `ARG` offsets won't line up with what was
actually pushed. `OFFSET name` as one argument component folds to a bare
`name` push (a label already evaluates to its own offset in NASM); a
`WORD`/`BYTE`/`DWORD` size-cast prefix on one component is kept as a
sized `push`. An ordinary `CALL target` with no language keyword and no
comma is passed straight through as a plain instruction.

### 2.3 `STRUC`/`ENDS`, `UNION`

```
Point STRUC
    x DW ?
    y DW ?
ENDS
```

Each `DB`/`DW`/`DD`/`DQ`/`DT` field line inside an open `STRUC` becomes a
`resb`/`resw`/`resd`/`resq`/`rest` line at the struc's running offset —
NASM structs carry no initial values, only offsets and sizes, so any RHS
value list on a field line is discarded (a `DUP(n)` count still
determines the field's total width). `ENDS` closes the struc with a real
`endstruc` — required in NASM, unlike a plain `SECTION`'s implicit close
— so code appearing after the struc parses correctly rather than being
mis-read as more struc fields.

`UNION` is translated the same way as `STRUC` (every member kept at the
struc's normal running, non-overlapping offset) with an advisory note:
NASM's `struc` has no union mode, so true member overlap must be
recreated by hand (re-zeroing each member's `resb`) if the source
actually relies on it.

### 2.4 `RECORD`, `WIDTH`/`MASK`, bit-field ops

```
Flags RECORD f1:1, f2:3, f3:4
```

`RECORD name field1:width1, field2:width2, ...` registers a bit-layout
type: the *last*-declared field occupies bit 0 (matching TASM), so shift
positions are assigned right-to-left across the declared list. No storage
is emitted for a `RECORD` declaration itself — it's a bit-layout type,
not a variable.

Once registered, `WIDTH fieldname` and `MASK fieldname` (or the bare
record name, for the whole-record form) resolve to literal integers
anywhere they're used as an expression operand — including inside
`EQU`/`%assign`/`IF`/`ELSEIF` right-hand sides.

The field-op family reduces directly to the underlying shift/mask
instruction sequence, all computed from the field's recorded width and
shift:

| Directive | Shape | Expands to |
|---|---|---|
| `SETFIELD field dest,src` | | `shl src, shift` (if shift>0) then `or dest, src` |
| `GETFIELD field dest,src` | | `mov dest,src` / `and dest,mask` / `shr dest,shift` (if shift>0) |
| `TESTFLAG field dest` | | `test dest, mask` |
| `MASKFLAG field dest` | | `and dest, mask` |
| `SETFLAG field dest` | | `or dest, mask` |
| `FLIPFLAG field dest` | | `xor dest, mask` |

A field-op referencing a name that was never registered via `RECORD` is
left as a plain `; ...` comment with an advisory note, rather than
guessed at.

### 2.5 OOP: `STRUC ... METHOD { }`, `TBLINST`, `TBLINIT`, `CALL obj METHOD`

Turbo Assembler's object-oriented extension is supported end to end:

```
Shape STRUC GLOBAL METHOD {
    Draw:WORD = Shape_Draw
    VIRTUAL Area:WORD = Shape_Area
}
    x DW ?
    y DW ?
ENDS

    TBLINST                      ; build the VMT once
...
Shape_Init PROC
    mov bx, ax
    TBLINIT ds:bx                ; wire this instance's VMT pointer
    ret
ENDP Shape_Init
...
    mov ax, [inst.x]
    CALL inst METHOD Area        ; virtual: indirect through the VMT
    CALL inst METHOD Draw        ; static (non-VIRTUAL): direct call
```

- `STRUC name [GLOBAL] [parent] METHOD { [VIRTUAL] name:type = proc, ... }`
  emits a `struc` whose first field is a `WORD`- or `DWORD`-sized
  `@Mptr_<name>` (VMT pointer) slot, matching the `type`/`NEAR`/`FAR` on
  the `STRUC` header (`WORD` type in the method entry → `NEAR` method
  pointer, `DWORD` → `FAR`). Data members declared below it extend the
  struc normally (§2.3). Non-`VIRTUAL` methods occupy no storage in
  either the instance or the VMT — they're compile-time bound, just like
  real TASM.
- `TBLINST` ("creates a table for the most recently declared object")
  emits the object's single VMT instance: one pointer-sized data slot per
  `VIRTUAL` method, in declared order, each initialized to point at its
  implementing procedure.
- `TBLINIT seg:reg` (used inside an init method, with the instance
  pointer already in `reg`) stores the VMT's address into that instance's
  `@Mptr_<obj>` field.
- `CALL instance METHOD [obj:]methodname [USES seg:reg] [, args...]`
  resolves at conversion time: a non-`VIRTUAL` method becomes a direct
  `call procname`; a `VIRTUAL` one becomes `mov reg,[instance.@Mptr_obj]`
  followed by an indirect `call [reg+offset]` through the VMT slot
  (`reg` defaults to `bx` unless `USES seg:reg` names another). A method
  name not found in the currently open object's table is left as a
  comment with an advisory note.

### 2.6 Macros

```
MACRO PushAll reg1, reg2
    push reg1
    push reg2
ENDM
```

Both `label MACRO paramlist` (MASM form) and `MACRO name paramlist`
(Ideal form) become `%macro name N` / `%endmacro`; every occurrence of a
declared parameter name inside the body is substituted with NASM's
`%1`..`%9` positional syntax, and `&name` string-concatenation splices
become NASM's `%+` operator.

#### 2.6.1 `LOCAL` inside a macro

TASM's in-macro `LOCAL name1, name2, ...` (declaring per-expansion-unique
label names) has **no direct translation** — it is dropped with an
advisory note. Rewrite the body to use NASM's own `%%name` local-label
syntax directly wherever the macro used to reference a `LOCAL`-declared
name; NASM auto-uniques any `%%`-prefixed label per expansion, which is
the same guarantee `LOCAL` provided.

#### 2.6.2 `EXITM`, `PURGE`

`EXITM` becomes `%exitmacro`; `PURGE name` becomes `%undef name`.

#### 2.6.3 `GOTO` / `:tag`

TASM's `GOTO tag` inside a macro is a preprocessor-time jump — real TASM
skips every line between the `GOTO` and its matching `:tag`, including
across conditional blocks. NASM's preprocessor has no equivalent jump, so
the converter approximates it mechanically: `GOTO tag` closes the
*innermost currently-open* `%if`/`%endif` and opens a fresh `%if 0` block
that runs to the matching `:tag` line (which re-opens with `%endif`).
This only produces correct output when the `GOTO`'s enclosing conditional
really was the innermost open block at that point — a nested or
non-linear `GOTO` needs manual restructuring after conversion. An
advisory note is always emitted at the `GOTO` site.

#### 2.6.4 `WHILE`

`WHILE cond ... ENDM` has no native looping construct in NASM's
preprocessor (`%rep` only repeats a fixed count, known up front). The
converter emits `%if cond` for the `WHILE` line itself (with an advisory
note) — genuinely reproducing the loop requires manually re-invoking the
enclosing `%macro` recursively at the bottom of the block before the
matching `%endif` (the classic NASM recursive-macro `WHILE` idiom). This
is not automated; the note is there specifically to flag it.

#### 2.6.5 `IRP` / `IRPC`

```
IRP reg, <ax, bx, cx>
    push reg
ENDM
```

Unlike a real `%macro`, `IRP`'s item list (and `IRPC`'s character string)
is compile-time-known text right there in the source, so the converter
expands it **immediately, at conversion time**: it captures the body up
to the matching `ENDM`, then emits one substituted copy per list item
(`IRP`, whole-token replace) or per character (`IRPC`, one raw splice per
character — quote the dummy yourself inside the body if you need an
actual character literal rather than a bare symbol substitution). Both
directives carry an advisory note explaining the expansion happened at
conversion time, not as a real preprocessor loop in the output.

#### 2.6.6 `CATSTR`/`SUBSTR`/`SIZESTR`/`INSTR`

`CATSTR name a, b, c` becomes `%define name a %+ b %+ c`. `SUBSTR`/
`SIZESTR` map directly to NASM's `%substr`/`%strlen`. `INSTR` (substring
search) has no NASM preprocessor primitive and cannot be evaluated at
conversion time without implementing a search — it is left as a `; ...`
comment with an advisory note for manual `%assign`-loop implementation.

### 2.7 Conditionals

`IFDEF`/`IFNDEF`/`ELSEIFDEF`/`ELSEIFNDEF` map directly to NASM's
`%ifdef`/`%ifndef`/`%elifdef`/`%elifndef`; `IFIDN`/`IFIDNI`/`IFDIF`/
`IFDIFI` map to `%ifidn`/`%ifidni`/`%ifnidn`/`%ifnidni`; numeric `IF`/
`IFE`/`ELSEIF`/`ELSEIFE` map to `%if`/`%if !(...)`/`%elif`/`%elif !(...)`
(after `WIDTH`/`MASK` and keyword-operator rewriting, so a `RECORD`-based
condition works the same as anywhere else — see §2.4). `ELSE`/`ENDIF` map
straight across.

Two forms are **approximated**, not exactly reproduced:

- `IFB`/`IFNB` (blank/non-blank macro-argument test) become
  `%if %0 = 0` / `%if %0 > 0` — a parameter-*count* check, not a test of
  one specific positional argument. If the original tested a particular
  argument slot rather than "no arguments at all", adjust the compared
  count by hand.
- `IF1`/`IF2` (true on assembler pass 1 / pass 2 respectively — a
  two-pass-assembler concept) both become `%if 1`, since this pipeline
  has no matching two-pass-visible state to test.

### 2.8 Data definitions

`DB`/`DW`/`DD`/`DQ`/`DT` outside a `STRUC` map to the same-named NASM
pseudo-ops after two passes: `?` placeholders become `0`, and a
`count DUP(body)` wrapper expands to `times count db/dw/... body` (a
single-value body) or a `%rep count` / `%endrep` block (a multi-item
comma-separated body).

#### 2.8.1 `DUP`

```
buf DB 64 DUP(0)
tbl DW 4 DUP(1, 2)
```

`64 DUP(0)` → `buf: times 64 db 0`. A multi-item body (`DUP(1,2)`, two
items) cannot be expressed with `times`, since `times` repeats one fixed
value — it expands to a `%rep`/`%endrep` block emitting the whole item
list once per repetition instead.

#### 2.8.2 Struc fields with `DUP`

Inside a `STRUC`, a `DUP(n)`-qualified field becomes `resX n` at the
struc's running offset (the value list inside `DUP(...)`, if any, is
discarded — struc fields carry no initial values regardless).

#### 2.8.3 `DF`/`DP` (48-bit far pointer)

NASM has no single pseudo-op for a 48-bit `segment:offset` far pointer.
`DF`/`DP` split into a `dd` (offset part, low 4 bytes) followed by a
`dw seg ...` (segment part) — exactly what a far pointer physically is on
this architecture. An advisory note flags this at every use so the value
expression can be double-checked as genuinely the *offset* half.

### 2.9 Segments, models, and program startup

#### 2.9.1 Simplified segment directives

| TASM | NASM output |
|---|---|
| `.CODE` / `CODESEG` | `section .text` |
| `.DATA` / `DATASEG` | `section .data` |
| `.DATA?` / `UDATASEG` | `section .bss` |
| `.CONST` (or bare `CONST` with no label) | `section .rodata` |
| `.FARDATA[name]` / `FARDATA[name]` | `section name` (default `.fardata`) |
| `.FARDATA?[name]` / `UFARDATA[name]` | `section name` (default `.fardata_bss`) |
| `.STACK size` / `STACK size` | `section .bss` + `stackbottom: resb size` + `stacktop:` label |

`.MODEL`/`MODEL` itself is dropped with an advisory note — NASM has no
memory-model system, so a raw `SEGMENT`/`GROUP` (OMF) layout, or plain
flat `section` directives as above, must stand in for whatever `DGROUP`
arrangement the model implied.

#### 2.9.2 Raw `SEGMENT`/`ENDS`/`GROUP`

A raw (non-simplified) `name SEGMENT [align] [combine] [class] [access]`
translates its recognized attribute words (`PARA`/`BYTE`/`WORD`/`DWORD`/
`PAGE`/`MEMPAGE` → `ALIGN=`, `PUBLIC`/`COMMON`/`MEMORY`/`STACK`/`PRIVATE`
lowercased as-is, a quoted class name → `CLASS=`) onto a NASM-syntax
`SEGMENT name ...` line (this project's own NASM-subset assembler
recognizes this raw form, not the simplified one). `ENDS` closes either a
plain segment (dropped — NASM's section close is implicit at the next
`SECTION`/EOF) or an open `STRUC` (closed with a real `endstruc`, see
§2.3 — the converter tracks which one is open so `ENDS` does the right
thing either way). `GROUP` passes its argument list straight through.
`ASSUME` is dropped with an advisory note: NASM never elides
segment-override bytes the way `ASSUME` lets MASM/TASM do implicitly, so
any code site that relied on it needs an explicit `seg:` prefix added by
hand.

#### 2.9.3 `PUBLIC`/`EXTRN`/`EXTERN`/`GLOBAL`/`COMM`

`PUBLIC name` → `global name`. `EXTRN`/`EXTERN name:type` → `extern name`
(the `:type` tail is stripped — NASM `extern` is untyped). A bare
`GLOBAL name` (TASM's own combined publish-or-import directive, distinct
from NASM's `GLOBAL` which only ever publishes) is emitted as `global`
with an advisory note to change it to `extern` by hand if the file only
*references* the symbol rather than defining it here. `COMM name:type` (a
communal variable, auto-merged across modules by the *linker*) becomes a
`section .bss` reservation plus `global name` in the module that should
own its storage, with a note that any other module referencing the same
`COMM` name needs a plain `extern name` instead — this project's linker
has no auto-merge step, so only one module may actually define it.

#### 2.9.4 Linker-only and cosmetic directives

`INCLUDELIB` and `ALIAS` are pure linker-level concepts with no
assembler-side meaning in any assembler; both are kept as advisory
comments explaining what to move to the linker command line / map file
instead, never translated into assembler output.

`WARN`/`NOWARN` (per-warning-class control) has no per-class NASM
equivalent and is dropped with a note to use `nasm -w+xxx`/`-w-xxx`\-style
command-line flags instead (via `tasm`'s own `/LOG=` for overall
verbosity — see §0). `DISPLAY`/`%OUT` become NASM's `%warning`.

`.STARTUP`/`STARTUPCODE` expands to the canned `mov ax,DGROUP` / `mov
ds,ax` / `mov ss,ax` / `mov sp,stacktop` sequence, with a note that it
assumes a `DGROUP` group and a `stacktop` label both exist (declare them
via `GROUP`/`.STACK` as your model requires). `.EXIT`/`EXITCODE [code]`
expands to `mov ax, 4C00h + (code & 0FFh)` / `int 21h`.

`NAME`, `VERSION`, `DOSSEG`, `.SEQ`, `LOCALS`/`NOLOCALS`, and `END` are
silently dropped — none has a NASM-side meaning worth preserving.

### 2.10 `ENUM`

```
ENUM Red, Green, Blue=10, Yellow
```

Each entry becomes an `%assign name value` line: an unadorned name gets
the next value in an auto-incrementing counter starting at 0; an
`name=value` entry both emits that literal value and resets the counter
to continue from `value+1` for the next unadorned entry (`Yellow` above
gets `11`).

### 2.11 `TYPEDEF`

```
PWORD TYPEDEF WORD PTR
```

Becomes a plain `%define name expansion` (after the usual `PTR`/size-word
rewriting) — an advisory note flags that NASM performs **no** type
checking on the resulting macro's use, unlike real TASM's `TYPEDEF`,
which is a genuine type alias the assembler enforces at every use site.

### 2.12 `RADIX`

```
RADIX 16
    mov ax, 20        ; means 0x20 under RADIX 16
```

Sets the converter's own notion of the current default numeric radix
(2/8/10/16); every bare, unsuffixed digit run seen afterward is given an
explicit NASM suffix (`h`/`o`/`b`, nothing for base 10) so its meaning
survives the fact that NASM has no notion of a file-wide default radix.
A literal that already carries one of TASM's own `h`/`o`/`q`/`b`/`d`
suffixes is self-describing and passed through untouched.

### 2.13 Character-set and quoting notes

Operator keywords (`AND`/`OR`/`XOR`/`NOT`/`MOD`/`SHL`/`SHR`/`EQ`/`NE`/
`GE`/`LE`/`GT`/`LT`) are rewritten to their NASM symbolic equivalents
(`&`/`|`/`^`/`~`/`%`/`<<`/`>>`/`=`/`!=`/`>=`/`<=`/`>`/`<`) **only** inside
expression/operand text — never inside a string or character literal,
and never for a word that is simultaneously a real mnemonic used as an
instruction's own opcode (a bare `xor bx,bx` is never touched, since only
the *operand* portion of an instruction line ever passes through this
rewrite, not the mnemonic itself). `WORD PTR [bx]`/`BYTE PTR foo`-style
size casts are lowered to NASM's `word [bx]`/`byte [foo]` form, including
MASM's implied-dereference spelling with no brackets at all
(`BYTE PTR foo`, no brackets in source, still becomes `byte [foo]`).

---

## 3. Cross-module calls: `CALL FAR`, not a bare `CALL`

Regardless of dialect, a call to a symbol resolved through
`EXTERN`/`IMPORT` (i.e. defined in a different module) must be written
`CALL FAR target`, never a bare `CALL target` — this project's RDOFF2
`RDFREC_IMPORT`/relocation model resolves cross-module references at
link time as far calls. See [PORTING.MD](PORTING.MD) §16.1 for the full
explanation and for porting Turbo Pascal `ASM ... END` blocks that
reference procedures from another module.

---

See [PORTING.MD](PORTING.MD) §1.6 for `tasm.exe`'s place in the overall
toolchain (build dependency ordering, which `.ASM` files it's the tool of
record for) and [IMPLRULE.MD](IMPLRULE.MD) §"TASM — design decisions and
known limitations" for the resolved design questions behind the NASM-side
parser (jump sizing, FPU/`%define` scope, CLI conventions) and the
`[label+register]` addressing limitation.
