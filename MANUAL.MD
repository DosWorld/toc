# Trubo Oberon Compiler — Manual

### Language reference · ABI · standard library · porting guide

---

This is the complete reference for **TOC**, a self-hosted Oberon-07 compiler
that targets 16-bit MS-DOS real mode on the 8086/8087. If you want the
elevator pitch, see [`README.MD`](README.MD). This document is for people
writing Oberon programs against this compiler and standard library.

**Table of contents**

- [The dialect](#the-dialect)
- [Types](#types)
- [Procedures, FAR/NEAR, and the calling convention](#procedures-farnear-and-the-calling-convention)
- [Pointers and memory](#pointers-and-memory)
- [Modules](#modules)
- [SYSTEM — low-level access](#system--low-level-access)
- [INLINE — embedding raw machine code](#inline--embedding-raw-machine-code)
- [Compiler directives](#compiler-directives)
- [Compiling and linking](#compiling-and-linking)
- [Standard library reference](#standard-library-reference)
- [Debug info for Turbo Debugger](#debug-info-for-turbo-debugger)
- [Porting from Pascal / C](#porting-from-pascal--c)
- [Examples](#examples)

---

## The dialect

TOC compiles the Wirth 2007 revision of Oberon, plus a small set of
extensions needed to write real 16-bit DOS system software. If you know
Oberon-2 or standard Oberon-07, the differences are:

| | |
|---|---|
| No type-bound procedures | Oberon-07 dropped methods; write ordinary procedures over records instead |
| `FLOOR(x)` / `ENTIER(x)` | Both accepted, `ENTIER` as a synonym |
| `FLOAT(x)` | Accepted as a synonym for `REAL(x)` |
| Implicit int → float promotion | `INTEGER`/`LONGINT` operands are silently promoted to `REAL`/`LONGREAL` inside `* / + - = # < > <= >=`; **assignment** still requires an explicit `REAL(x)` cast |
| `FOR ... BY` | Optional step, positive or negative |
| Multi-branch `ELSIF` | On both `IF` and `WHILE` |
| No `WITH` statement | Not implemented |
| `IMPORT` is explicit | Every imported module must be named; no wildcard imports |
| `LONGINT` | Signed 32-bit (extension) — carried in a `DX:AX` register pair |
| `REAL` / `LONGREAL` | IEEE-754 single/double (extension) — require an x87 coprocessor |
| `SET` | 16-bit — elements `0..15` |

The full grammar, kept in lock-step with the compiler, lives in
[`DOCS/OBERON07.EBN`](DOCS/OBERON07.EBN) — that file is authoritative over
anything summarized here.

**Identifiers are case-sensitive.** `Foo`, `foo`, and `FOO` are three
different names. Keywords (`BEGIN`, `END`, `PROCEDURE`, …) are always
uppercase; their lowercase spellings are ordinary identifiers, not reserved
words. The context-sensitive modifiers `FAR`, `NEAR`, and `EXTERNAL` are
matched the same way and must be written uppercase.

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

```
toc.exe /ENTRY=Run Hello.Mod
Hello.exe
```

---

## Types

TOC targets a **large memory model**: `CS`, `DS`, and `SS` are three
distinct segments at all times, for every module, for the whole run of the
program. There is no tiny/small/compact-model shortcut where two of them
happen to coincide — code that assumes that is simply wrong here.

| Type | Size | Notes |
|---|---|---|
| `BOOLEAN` | 1 | `0`=`FALSE`, `1`=`TRUE` |
| `CHAR` | 1 | ASCII |
| `BYTE` | 1 | unsigned `0..255` |
| `INTEGER` | 2 | signed `−32768..32767` |
| `WORD` | 2 | unsigned `0..65535` — same storage as `INTEGER`, unsigned arithmetic and comparisons |
| `LONGINT` | 4 | signed 32-bit; `DX:AX` register pair |
| `REAL` | 4 | IEEE-754 single precision; x87 `ST(0)` |
| `LONGREAL` | 8 | IEEE-754 double precision; x87 `ST(0)` |
| `SET` | 2 | elements `0..15` |
| `POINTER` | 4 | far: `{offset:word, segment:word}` |
| `PROCEDURE FAR` (proc variable) | 4 | far: `{offset, segment}` |
| `PROCEDURE NEAR` (proc variable) | 2 | near: `{offset}` only — same code segment assumed |

`NIL` is `0000:0000` — both words zero.

**Aggregates** (`ARRAY`, `RECORD`) follow the usual Oberon-07 rules:
`RECORD` supports single inheritance via `POINTER TO RECORD` extension, with
a runtime type tag (a hidden 2-byte word ahead of every heap-allocated
record) backing the `IS` type test and `NEW`'s dynamic dispatch.

`ARRAY` comes in two flavors that matter for the ABI:

- A **fixed-size array** (`ARRAY N OF T`) is a plain block of `N` elements —
  passed by value like a record (see below) unless the formal is `VAR`.
- An **open array** (`ARRAY OF T`, no length) can only appear as a formal
  parameter. It is always passed **by reference**, VAR or not, as a 6-byte
  slot: `{offset:2, segment:2, LEN:2}`. `LEN(a)` recovers the length at
  runtime.

`SIZE(T)` returns the byte size of any type at compile time — useful for
`NEW(p, n)` and manual buffer sizing.

### Constants are integers only

`CONST` declarations must reduce to an `INTEGER`-family value — `INTEGER`,
`LONGINT`, `WORD`, or `BYTE`. `CHAR`, `BOOLEAN`, `REAL`, `LONGREAL`, `SET`,
and string/array/record/pointer constants are all rejected at compile time.
This is a deliberate deviation from standard Oberon-07 (which allows several
of those); write the literal directly at the use site instead.

---

## Procedures, FAR/NEAR, and the calling convention

Every procedure is Pascal-convention: **the callee cleans the stack**, and
arguments are pushed **left to right** (the first parameter lands deepest).

A procedure is either **NEAR** (same-segment call, `RET`/`RET N` epilogue,
parameters start at `[BP+4]`) or **FAR** (cross-segment call, `RETF`/`RETF N`
epilogue, parameters start at `[BP+6]`, return address is 4 bytes: IP then
CS). The rule for which one you get:

| Situation | Convention |
|---|---|
| Exported (`*`) | Always FAR — cannot be overridden |
| `PROCEDURE p; FAR;` | Explicit FAR |
| `PROCEDURE p; NEAR;` | Explicit NEAR (error if also exported) |
| Not exported, no modifier | NEAR by default |
| A module's `__init` | Always FAR |

De-exporting an internal helper (dropping its `*`) makes it NEAR, which is
smaller and faster at every call site — see the "Visibility / NEAR rule" in
[`DOCS/IMPLRULE.MD`](DOCS/IMPLRULE.MD).

**Return values:** scalars in `AX`; `LONGINT` and far pointers in `DX:AX`
(segment in `DX`); a NEAR procedure-variable's value in `AX` only. **A
procedure may not return an array or a record** — there's no hidden
result-pointer convention, so the result type must be scalar, pointer, or
procedure.

**Nested procedures** are legal syntactically, but a nested procedure can
only read/write module globals, imported names, and its own parameters and
locals — **not** the enclosing procedure's locals (rejected at compile time
as "uplevel access not allowed"). Because of this there is no hidden
static-link slot; a nested procedure compiles to an ordinary NEAR procedure.

**By-value aggregates.** Passing a `RECORD` or fixed `ARRAY` by value copies
the whole thing onto the stack (2-byte aligned) at the call site — the
callee reads its own copy in place. An open array is never copied; see
above.

**`FORWARD` and `EXTERNAL`.** `FORWARD` declares a signature now and
supplies the body later in the same declaration sequence — useful for
mutual recursion. `EXTERNAL` declares a signature with **no** body at all;
the implementation is supplied by a hand-assembled `.rdf` object linked in
via a `$L` directive (this is exactly how `SYSTEM.MOD`'s primitives —
`Halt`, `Alloc`, `Intr`, … — are wired to `SYS.ASM`). Both accept `FAR`/`NEAR`,
neither can be combined with `INLINE`, and neither can be both at once.

```oberon
PROCEDURE Halt*(ErrCode: BYTE); EXTERNAL;
PROCEDURE Even(n: INTEGER): BOOLEAN; FORWARD;
```

---

## Pointers and memory

Every `POINTER TO T`, every far procedure variable, and every `VAR`
parameter's bound address is a 4-byte **far pointer**: offset word at
`addr+0`, segment word at `addr+2`. As a *value* it lives in `DX:AX`
(`AX`=offset, `DX`=segment); to *dereference* it, the compiler loads it into
`ES:BX` (`BX`=offset, `ES`=segment).

```oberon
TYPE
  PNode = POINTER TO Node;
  Node  = RECORD val: INTEGER; next: PNode END;

VAR head: PNode;

PROCEDURE Push(val: INTEGER);
  VAR n: PNode;
BEGIN
  NEW(n); n.val := val; n.next := head; head := n
END Push;
```

**Implicit dereference:** `p.f` means exactly `p^.f`, and `p[i]` means
exactly `p^[i]` — the compiler inserts the dereference automatically
whenever a selector is applied to a pointer. Chained selectors
(`p.a.b`, `p[i][j]`) work the same way.

`NEW(p)` allocates `SIZE(T)` bytes on the heap and stores the resulting far
address in `p`; `NEW(p, n)` allocates exactly `n` bytes (also legal when `p`
is a `SYSTEM.ADDRESS`). `DISPOSE(p)` frees it. There is no garbage
collector — this is a manual-management heap on top of DOS's own allocator.

**Pointer comparison** (`p = q`, `p # q`, `p = NIL`) compares **both** words
— segment and offset — because `SYSTEM.Alloc` always returns offset 0, so
comparing only the offset against `NIL` would spuriously succeed for every
live pointer.

**VAR parameters must be l-values.** A `VAR` formal binds to the caller's
storage, so the actual must be a real variable, a dereferenced pointer, or
an indexed element — never a literal, a constant, an expression, or a
procedure value. This is caught at compile time.

---

## Modules

```oberon
MODULE Name;
IMPORT Mod1, Mod2;

(* declarations *)

BEGIN
  (* optional module-level init statements *)
END Name.
```

Every module gets a compiler-generated `ModuleName__init` FAR procedure that
runs its imports' `__init` procedures (each exactly once, guarded against
re-entry) and then its own body. There is nothing to call manually — the
`/ENTRY=` build step chains `SYSTEM_INIT → YourModule__init → YourEntryProc
→ SYSTEM_DONE` for you.

**Exported symbols** are named `ModuleName_SymbolName` at the object-file
level; `_` itself is forbidden inside module names, and the `__` prefix is
reserved for compiler-generated names. None of this is visible from Oberon
source — it only matters if you're reading `.rdf`/`.def` output or linking
against a hand-written external object.

`IMPORT SYSTEM` is a compile error: `SYSTEM` is always implicitly available,
under exactly that qualifier.

---

## SYSTEM — low-level access

`SYSTEM` is pre-declared; you never write `IMPORT SYSTEM`, and writing it is
an error. Everything below is reached as `SYSTEM.Name`.

### Address intrinsics

| Call | Result | Meaning |
|---|---|---|
| `SYSTEM.ADR(v)` | `ADDRESS` | Far address of variable `v` (or of a procedure, giving its far code address) |
| `SYSTEM.SEG(v)` | `INTEGER` | Segment of `v` |
| `SYSTEM.OFS(v)` | `INTEGER` | Offset of `v` within its segment |
| `SYSTEM.PTR(s, o)` | `ADDRESS` | Construct a far pointer from segment `s` and offset `o` |
| `SYSTEM.MOVE(src, dst, n)` | — | Copy `n` bytes `src → dst` (any combination of heap/stack/data segments) |
| `SYSTEM.FILL(dst, n, b)` | — | Fill `n` bytes at `dst` with byte `b` |
| `SYSTEM.PORTOUT(p, b)` | — | `OUT` byte `b` to I/O port `p` |
| `SYSTEM.PORTIN(p)` | `BYTE` | `IN` a byte from I/O port `p` |

`SYSTEM.ADDRESS` is the universal 4-byte far value — assignment-compatible
with any `POINTER`, and usable on its own as an implicit `POINTER TO CHAR`
with byte-level pointer arithmetic:

```oberon
VAR p: SYSTEM.ADDRESS;
...
ch := p^;            (* read the byte at p *)
p^[3] := "!";         (* write the 4th byte from p *)
INC(p);               (* advance the offset by one *)
```

`INC`/`DEC`/`+`/`-` on a `SYSTEM.ADDRESS` only ever touch the **offset**
word — the segment word is never carried into, so a 16-bit offset overflow
silently wraps instead of crossing into the next segment. Converting
between `LONGINT` and `ADDRESS` requires an explicit cast in either
direction (`LONGINT(p)` / `SYSTEM.ADDRESS(n)`); anything narrower than 4
bytes is rejected, since it would drop the segment.

`SYSTEM.GET`, `SYSTEM.PUT`, and `SYSTEM.VAL` from standard Oberon are **not**
part of this dialect — use a typed `POINTER TO T` and `p^` instead.

### Bitwise and shift intrinsics

| Call | Notes |
|---|---|
| `SYSTEM.LSL(x, n)` | logical shift left, result type = type of `x` |
| `SYSTEM.LSR(x, n)` | logical shift right |
| `SYSTEM.ASR(x, n)` | arithmetic shift right |
| `SYSTEM.ROR(x, n)` | rotate right |
| `SYSTEM.AND(x, y)` | bitwise AND — result widens to the larger of `x`/`y` (`LONGINT` > `WORD` > `INTEGER`) |
| `SYSTEM.IOR(x, y)` | bitwise OR, same widening rule |
| `SYSTEM.XOR(x, y)` | bitwise XOR, same widening rule |

These must always be written with the `SYSTEM.` qualifier — bare `LSL(x, n)`
is a compile error, by design (they need type-dependent codegen that an
ordinary imported procedure can't express).

### `SYSTEM.Registers` and `SYSTEM.Intr`

```oberon
TYPE Registers = RECORD AX, BX, CX, DX, SI, DI, DS, ES, Flags: INTEGER END;
PROCEDURE Intr*(IntNo: BYTE; VAR Regs: Registers);
```

Fire a raw DOS/BIOS interrupt with the given register set; `Regs` is
updated in place with the result. `Dos.MOD` and `Crt.MOD` are built entirely
on top of this — reach for it directly only when you need an interrupt the
stdlib doesn't already wrap.

### `SYSTEM.SetExitProc` / `SYSTEM.GetExitProc`

```oberon
PROCEDURE SetExitProc*(proc: ADDRESS);
PROCEDURE GetExitProc*(): ADDRESS;
```

A single global far-procedure hook, run automatically just before the
program terminates (normal exit or `SYSTEM.Halt`). Semantics mirror Turbo
Pascal's `ExitProc` variable: there is exactly **one** slot, not a list, so
chaining multiple handlers is the caller's responsibility, done the same way
Turbo Pascal programs do it — save the previous hook before installing a new
one, and restore it as the *first* action inside the new handler:

```oberon
VAR prevExitProc: SYSTEM.ADDRESS;

PROCEDURE MyExit;
BEGIN
  SYSTEM.SetExitProc(prevExitProc);  (* restore first — see below *)
  (* ... actual cleanup ... *)
END MyExit;

(* installation, e.g. in the module body *)
prevExitProc := SYSTEM.GetExitProc();
SYSTEM.SetExitProc(SYSTEM.ADR(MyExit));
```

At program termination the runtime calls the installed hook in a loop,
re-reading it after each call and stopping once it reads `NIL` — so a chain
of handlers, each restoring its predecessor first, runs to completion one
link at a time, most-recently-installed first, exactly like nested Turbo
Pascal `ExitProc` chains. **The restore-first order is not optional**: a
handler that does not restore the previous value before returning will be
invoked repeatedly forever, since the runtime never sees the hook change.

---

## INLINE — embedding raw machine code

An `INLINE` procedure has no prologue, no epilogue, and no `CALL`
instruction: the declared byte pattern is stitched directly into the
caller's instruction stream at every call site.

```oberon
PROCEDURE Cli*;
BEGIN
  INLINE(0FAH)              (* CLI *)
END Cli;
```

`INLINE` also works as a **statement** form inside an ordinary procedure
body — handy for a one-off `CLI`/`STI`/`HLT` without declaring a whole
procedure for it.

Two entry kinds can appear in the byte list:

- an **integer literal** (`0..255`) — emitted verbatim as one raw byte;
- a **formal parameter name** — substituted with the 2-byte address of the
  actual argument (a signed `BP`-relative offset for locals, or a `DS`
  offset plus a relocation for globals).

**The one rule that must never be broken:** stack pointer `SP` at the end
of the byte sequence must equal `SP` at the start. There's no `CALL`/`RET`
frame to absorb an imbalance — a stray `PUSH` with no matching `POP`
corrupts the *caller's* frame, and the compiler cannot detect this for you.

```oberon
INLINE(050H, 058H);          (* PUSH AX; POP AX — balanced, fine *)
INLINE(050H);                (* PUSH AX only — SP off by 2, BROKEN *)
```

This is exactly how `SYSTEM.MOD`'s `ADR`/`SEG`/`OFS`/`PTR`/`MOVE`/`FILL`/
`PORTOUT`/`PORTIN` are implemented — read `SRC/LIB/SYSTEM.MOD` for worked,
correct examples of both the address-substitution and value-push styles.

---

## Compiler directives

System comments (`(*$...*)` or `//$...`) carry compiler directives, several
of which can be combined in one comment separated by commas:

| Directive | Meaning |
|---|---|
| `$L path` | Pack the `.rdf` at `path` into this module's `.om` archive (used to attach hand-assembled helpers, e.g. `SYSTEM.MOD`'s `$L SYS.RDF`) |
| `$M stack,min,max` | Stack size hint (bytes) and heap min/max (bytes), all three required. Only takes effect with `/ENTRY=`. Defaults: `8192, 131072, 262144` |
| `$R+` / `$R-` | Enable/disable runtime array-bounds checks from this point in the file onward (default off) |
| `$D+` / `$D-` | Enable/disable Turbo-Debugger symbol/line collection for this module (default off) — see [Debug info](#debug-info-for-turbo-debugger) |

```oberon
(*$M 10240, 128000, 650000*)   (* 10 KB stack, 128 KB min heap, ~635 KB max heap *)
```

---

## Compiling and linking

`toc.exe` is the whole toolchain in one binary: dependency scanner,
incremental compiler, and smart linker.

```
toc.exe [/ENTRY=Proc] [/SYSTEM] [/M] [/G] <Root.Mod>
```

| Command | Behavior |
|---|---|
| `toc.exe Root.Mod` | **Compile-only.** Scans transitive imports, recompiles anything stale, emits `.om` files. No link step — this is how you build a library. |
| `toc.exe /ENTRY=Run Root.Mod` | **Compile + link.** Same scan/compile, then links every `.om` into `Root.exe` (name auto-derived from the module name). |

Switches are case-insensitive except the value after `/ENTRY=`, which keeps
its case:

- **`/ENTRY=ProcName`** — build an executable; `ProcName` must be an
  exported procedure in the root module.
- **`/M`** — an import is normally only recompiled if its `.om` is missing
  or empty; `/M` additionally recompiles any import whose source is newer
  than its `.om`. The module named on the command line is always
  recompiled either way.
- **`/SYSTEM`** — the one flag used to compile `SYSTEM.MOD` itself: turns
  off the implicit `SYSTEM` auto-import and dependency scan for that single
  file.
- **`/G`** — at link time, merge every module's Turbo-Debugger symbol
  records (collected via `$D+`) into a TDS/TDINFO block appended to the
  `.exe`. See [Debug info](#debug-info-for-turbo-debugger).

```
toc.exe MyLib.Mod                     REM compile-only → MyLib.om
toc.exe /ENTRY=Run MyProg.Mod         REM compile + link → MyProg.exe
toc.exe /M /ENTRY=Run MyProg.Mod      REM force-check every import's timestamp
toc.exe /G /ENTRY=Run MyProg.Mod      REM link with Turbo-Debugger symbols
```

**`OBERON_LIB`** tells the compiler where to find the standard library
archive: a semicolon-separated list of `.om` files, searched after the
current directory.

```
SET OBERON_LIB=C:\TOC\OBERON.OM
```

`toc.exe` also looks for `OBERON.OM` next to its own binary automatically,
so on a normal install you often don't need to set this at all.

**Output layout.** A normal compile writes `ModName.rdf` + `ModName.def` as
intermediates, packs them into `ModName.om` (a `ustar` archive), then
deletes the intermediates — only the `.om` remains. On error, nothing is
left behind: no partial `.om`, no leftover temp file. `/ENTRY=` additionally
generates a small `MAIN.RDF` startup stub (packed into the root module's
`.om`) that chains runtime init, your module's init, your entry procedure,
and runtime shutdown.

---

## Standard library reference

Fourteen modules, merged into one `BIN\OBERON.OM` archive by `make`.
Every procedure below is exported (`*`) and callable after `IMPORT`.

### `SYSTEM` — see [above](#system--low-level-access)

Also exports the raw runtime primitives that everything else is built on:

```oberon
PROCEDURE GetExitProc*(): ADDRESS;
PROCEDURE SetExitProc*(proc: ADDRESS);
PROCEDURE Halt*(ErrCode: BYTE);                          EXTERNAL;

PROCEDURE Alloc*(sizeInBytes: WORD): ADDRESS;             EXTERNAL;
PROCEDURE Free*(p: ADDRESS);                              EXTERNAL;
PROCEDURE MemAvail*(): WORD;                              EXTERNAL;  (* total free heap, paragraphs *)
PROCEDURE MemMaxAvail*(): WORD;                           EXTERNAL;  (* largest free block, paragraphs *)

PROCEDURE Intr*(IntNo: BYTE; VAR Regs: Registers);
PROCEDURE CallFar*(ProcPtr: ADDRESS; VAR Regs: Registers); EXTERNAL;
```

Plus a small set of value-only helpers that don't need INLINE:
`MAX(a,b)`, `MIN(a,b)`, `LENGTH(s)`, `UCASE(c)`, `LCASE(c)`, `ISDIGIT(c)`,
`ISALPHA(c)`, `ISSPACE(c)`, `ISHEX(c)`, `COMPARE(VAR m1, m2; len)`.

### `Out` — formatted stdout

```oberon
PROCEDURE Open*;
PROCEDURE Char*(ch: CHAR);
PROCEDURE Ln*;
PROCEDURE String*(s: ARRAY OF CHAR);
PROCEDURE Int*(l: LONGINT; w: INTEGER);        (* right-justified in field width w *)
PROCEDURE Hex*(i: INTEGER; w: INTEGER);
PROCEDURE Adr*(p: SYSTEM.ADDRESS);
PROCEDURE Boolean*(val: BOOLEAN);
PROCEDURE HexDump*(VAR buf; len: WORD);
```

### `Out87` — same interface, plus floating point

Requires an x87 FPU. Same `Open`/`Char`/`Ln`/`String`/`Boolean`/`Int`/`Hex`/
`Adr`/`HexDump` as `Out`, plus:

```oberon
PROCEDURE Real*(x: REAL; w: INTEGER);
PROCEDURE LongReal*(x: LONGREAL; w: INTEGER);
```

### `In` — buffered stdin

```oberon
PROCEDURE Open*;
PROCEDURE Char*(VAR c: CHAR);
PROCEDURE Int*(VAR i: INTEGER);
PROCEDURE LongInt*(VAR l: LONGINT);
PROCEDURE String*(VAR s: ARRAY OF CHAR);
```

### `Files` — buffered file I/O

```oberon
TYPE File = RECORD ... END;   (* opaque; EMS- or disk-backed *)

PROCEDURE Reset*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;      (* open existing, for reading *)
PROCEDURE ReWrite*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;    (* create/truncate, for writing *)
PROCEDURE Append*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;     (* open existing, seek to end *)
PROCEDURE ReWriteTemp*(VAR F: File): BOOLEAN;                     (* anonymous temp file, EMS- or disk-backed, deleted on Close *)
PROCEDURE Close*(VAR F: File);

PROCEDURE BlockRead*(VAR F: File; VAR x; len: WORD): WORD;        (* returns bytes actually read *)
PROCEDURE BlockWrite*(VAR F: File; VAR x; len: WORD): WORD;
PROCEDURE ReadByte*(VAR F: File; VAR b: BYTE): BOOLEAN;
PROCEDURE ReadWord*(VAR F: File; VAR w: INTEGER);
PROCEDURE ReadDWord*(VAR F: File; VAR w: LONGINT);
PROCEDURE WriteByte*(VAR F: File; b: BYTE): WORD;
PROCEDURE WriteWord*(VAR F: File; w: INTEGER): WORD;
PROCEDURE WriteDWord*(VAR F: File; w: LONGINT): WORD;
PROCEDURE ReadAsciizString*(VAR f: File; VAR dst: ARRAY OF CHAR);
PROCEDURE ReadLine*(VAR f: File; VAR buf: ARRAY OF CHAR; maxLen: WORD): WORD;
PROCEDURE Write*(VAR f: File; line: ARRAY OF CHAR): WORD;
PROCEDURE WriteLine*(VAR f: File; line: ARRAY OF CHAR): WORD;     (* Write + WriteLn *)
PROCEDURE WriteLn*(VAR f: File): WORD;

PROCEDURE Seek*(VAR F: File; pos: LONGINT);
PROCEDURE Position*(VAR F: File): LONGINT;
PROCEDURE Size*(VAR F: File): LONGINT;
PROCEDURE Truncate*(VAR F: File);

PROCEDURE FileExists*(FileName: ARRAY OF CHAR): BOOLEAN;
PROCEDURE Delete*(FileName: ARRAY OF CHAR): BOOLEAN;
PROCEDURE Rename*(OldName, NewName: ARRAY OF CHAR): BOOLEAN;
PROCEDURE Copy*(src, dst: ARRAY OF CHAR): BOOLEAN;
PROCEDURE BlockCopy*(VAR src, dst: File; len: LONGINT): BOOLEAN;
PROCEDURE ReplaceExt*(path: ARRAY OF CHAR; newExt: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
PROCEDURE SetDeleteOnClose*(VAR F: File; delOnClose: BOOLEAN);
PROCEDURE GetFTime*(VAR f: File; VAR time: Time.DosTime);
PROCEDURE SetFTime*(VAR f: File; time: Time.DosTime);
```

### `Strings` — string manipulation

```oberon
PROCEDURE Length*(s: ARRAY OF CHAR): INTEGER;
PROCEDURE Equal*(a, b: ARRAY OF CHAR): BOOLEAN;
PROCEDURE EqualICase*(a, b: ARRAY OF CHAR): BOOLEAN;
PROCEDURE StartsWith*(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN;
PROCEDURE EndsWith*(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN;
PROCEDURE Pos*(pat, s: ARRAY OF CHAR; pos: INTEGER): INTEGER;
PROCEDURE Copy*(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
PROCEDURE Append*(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
PROCEDURE Insert*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
PROCEDURE Delete*(VAR s: ARRAY OF CHAR; pos, n: INTEGER);
PROCEDURE Replace*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
PROCEDURE Extract*(VAR src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR);
PROCEDURE HashCode*(str: ARRAY OF CHAR): WORD;

PROCEDURE Str*(src: LONGINT; VAR dst: ARRAY OF CHAR);             (* integer -> decimal string *)
PROCEDURE Val*(VAR s; VAR startFrom: WORD): LONGINT;              (* decimal string -> integer *)
PROCEDURE AppendInt*(val: LONGINT; VAR str: ARRAY OF CHAR);
PROCEDURE ByteToHexStr*(val: BYTE; VAR str: ARRAY OF CHAR);
PROCEDURE WordToHexStr*(val: WORD; VAR str: ARRAY OF CHAR);
PROCEDURE AppendHexByte*(val: BYTE; VAR str: ARRAY OF CHAR);
PROCEDURE AppendHexWord*(val: WORD; VAR str: ARRAY OF CHAR);
```

### `Crt` — terminal control (INT 10h)

```oberon
PROCEDURE KeyPressed*: BOOLEAN;
PROCEDURE ReadKey*: CHAR;
PROCEDURE TextMode*(Mode: BYTE);
PROCEDURE GotoXY*(X, Y: INTEGER);
PROCEDURE ClrScr*;
PROCEDURE ClrEol*;
PROCEDURE TextColor*(fg: INTEGER);
PROCEDURE TextBackground*(bg: INTEGER);
PROCEDURE Delay*(MS: INTEGER);
PROCEDURE Sound*(Hz: INTEGER);
PROCEDURE NoSound*;
```

### `Dos` — process, filesystem, date/time, interrupts

```oberon
TYPE
  Registers* = SYSTEM.Registers;
  SearchRec* = RECORD attr*: BYTE; time*: LONGINT; size*: LONGINT;
                       name*: ARRAY 13 OF CHAR; ... END;

VAR
  DosError*: WORD;        (* last INT 21h result; 0 = ok *)
  DosExitCode*: WORD;     (* last Exec'd child's exit status *)

PROCEDURE Intr*(IntNo: BYTE; VAR Regs: Registers);
PROCEDURE MsDos*(VAR Regs: Registers);                            (* INT 21h shorthand *)

PROCEDURE ParamCount*: INTEGER;
PROCEDURE ParamStr*(i: INTEGER; VAR p: ARRAY OF CHAR);
PROCEDURE GetEnv*(envvar: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);

PROCEDURE FindFirst*(Path: ARRAY OF CHAR; Attr: BYTE; VAR S: SearchRec);
PROCEDURE FindNext*(VAR S: SearchRec);
PROCEDURE MkDir*(Path: ARRAY OF CHAR): BOOLEAN;
PROCEDURE ChDir*(Path: ARRAY OF CHAR): BOOLEAN;
PROCEDURE FExpand*(Path: ARRAY OF CHAR; VAR Dest: ARRAY OF CHAR);
PROCEDURE FSplit*(Path: ARRAY OF CHAR; VAR Dir, Name, Ext: ARRAY OF CHAR);

PROCEDURE GetDate*(VAR Year, Month, Day, DayOfWeek: INTEGER);
PROCEDURE SetDate*(Year, Month, Day: INTEGER);
PROCEDURE GetTime*(VAR Hour, Minute, Second, Sec100: INTEGER);
PROCEDURE SetTime*(Hour, Minute, Second, Sec100: INTEGER);

PROCEDURE DiskFree*(Drive: BYTE): LONGINT;
PROCEDURE DiskSize*(Drive: BYTE): LONGINT;

PROCEDURE GetIntVec*(IntNo: BYTE; VAR Vector: SYSTEM.ADDRESS);
PROCEDURE SetIntVec*(IntNo: BYTE; Vector: SYSTEM.ADDRESS);

PROCEDURE Exec*(Path, CmdLine: ARRAY OF CHAR);                    (* sets DosError/DosExitCode *)
PROCEDURE SwapVectors*;
```

### `IO` — raw rider-based I/O

For writing to an arbitrary DOS file handle (stdout, stderr, or a file)
without going through `Files.File`:

```oberon
PROCEDURE StdOut*(VAR r: Rider);
PROCEDURE StdErr*(VAR r: Rider);
PROCEDURE OpenHandle*(VAR r: Rider; h: INTEGER);
PROCEDURE ReadChar*(VAR r: Rider; VAR ch: CHAR);
PROCEDURE WriteChar*(VAR r: Rider; ch: CHAR);
PROCEDURE WriteStr*(VAR r: Rider; s: ARRAY OF CHAR);
PROCEDURE WriteInt*(VAR r: Rider; n: LONGINT);
PROCEDURE WriteBoolean*(VAR r: Rider; n: BOOLEAN);
PROCEDURE WriteLn*(VAR r: Rider);
PROCEDURE HexDump*(VAR r: Rider; VAR buf; len: WORD);
```

### `Time` — DOS packed date/time conversion

```oberon
TYPE
  DosTime*  = LONGINT;                          (* packed DOS FAT date/time *)
  UnixTime* = LONGINT;                          (* seconds since 1970-01-01 *)
  DateTime* = RECORD Year*, Month*, Day*, Hour*, Min*, Sec*: WORD END;

PROCEDURE PackTime*(VAR t: DateTime; VAR p: DosTime);
PROCEDURE UnpackTime*(p: DosTime; VAR t: DateTime);
PROCEDURE IsLeap*(y: WORD): BOOLEAN;
PROCEDURE DaysInMonth*(y, m: WORD): WORD;
PROCEDURE DayOfWeek*(y, m, d: WORD): BYTE;               (* 0=Sunday .. 6=Saturday *)
PROCEDURE DosToUnixTime*(d: DosTime): UnixTime;
PROCEDURE UnixToDosTime*(u: UnixTime): DosTime;
PROCEDURE NowDateTime*(VAR t: DateTime);
PROCEDURE Now*(): DosTime;
PROCEDURE SecondsBetween*(d1, d2: DosTime): LONGINT;     (* d2 - d1, signed *)
```

### `Math` — x87 floating-point functions

```oberon
PROCEDURE Abs*(x: REAL): REAL;
PROCEDURE Sqr*(x: REAL): REAL;
PROCEDURE Sqrt*(x: REAL): REAL;
PROCEDURE Round*(x: REAL): INTEGER;
PROCEDURE Trunc*(x: REAL): INTEGER;
PROCEDURE Int*(x: REAL): REAL;         (* integer part, toward zero *)
PROCEDURE Sin*(x: REAL): REAL;
PROCEDURE Cos*(x: REAL): REAL;
PROCEDURE Tan*(x: REAL): REAL;
PROCEDURE ArcSin*(x: REAL): REAL;
PROCEDURE ArcCos*(x: REAL): REAL;
PROCEDURE ArcTan*(x: REAL): REAL;
```

### `EMS` — expanded-memory page-frame management

```oberon
PROCEDURE Present*(): BOOLEAN;
PROCEDURE Alloc*(sizeKB: WORD; VAR handle: WORD): BOOLEAN;
PROCEDURE Free*(handle: WORD): BOOLEAN;
PROCEDURE Realloc*(VAR handle: WORD; newSizeKB: WORD): BOOLEAN;
PROCEDURE CopyToEMS*(VAR dosBuf; ...);
PROCEDURE CopyToDos*(handle: WORD; ...);
PROCEDURE MapPage*(handle: WORD; logicalPage, physicalPage: WORD): BOOLEAN;
PROCEDURE UnmapPage*(physicalPage: WORD): BOOLEAN;
PROCEDURE MapPtr*(handle: WORD; emsOffset: LONGINT; physWin: WORD): SYSTEM.ADDRESS;
PROCEDURE Version*: BYTE;
PROCEDURE RequireVersion*(ver: BYTE);
PROCEDURE GetError*(): WORD;
```

`Files.MOD`'s `ReWriteTemp` uses this transparently — a temp file backed by
EMS behaves identically to a disk-backed one through the same buffered
`BlockRead`/`BlockWrite` interface.

### `Test` — unit-test framework

```oberon
TYPE TestProc = PROCEDURE;

PROCEDURE AddTest*(t: TestProc; name: ARRAY OF CHAR);
PROCEDURE RunTests*;

PROCEDURE AssertTrue*(cond: BOOLEAN; msg: ARRAY OF CHAR);
PROCEDURE AssertFalse*(cond: BOOLEAN; msg: ARRAY OF CHAR);
PROCEDURE AssertNil*(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR);
PROCEDURE AssertNotNil*(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR);
PROCEDURE AssertByte*(expected, actual: BYTE; msg: ARRAY OF CHAR);
PROCEDURE AssertInt*(expected, actual: INTEGER; msg: ARRAY OF CHAR);
PROCEDURE AssertWord*(expected, actual: WORD; msg: ARRAY OF CHAR);
PROCEDURE AssertLong*(expected, actual: LONGINT; msg: ARRAY OF CHAR);
PROCEDURE AssertReal*(expected, actual: REAL; msg: ARRAY OF CHAR);
PROCEDURE AssertLongReal*(expected, actual: LONGREAL; msg: ARRAY OF CHAR);
PROCEDURE AssertStr*(expected, actual: ARRAY OF CHAR; msg: ARRAY OF CHAR);
```

```oberon
MODULE TMyFeature;
IMPORT Test;

PROCEDURE TestAddition; FAR;   (* TestProc is a FAR procedure type *)
BEGIN
  Test.AssertInt(4, 2 + 2, "2+2 should be 4")
END TestAddition;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TestAddition, "TestAddition");
  Test.RunTests
END RunAllTests;

END TMyFeature.
```

### `RdfLoad` — runtime RDOFF2 loader

Loads a compiled `.rdf` object at runtime and calls into it — dynamic
loading without touching the linker.

```oberon
TYPE RDFModule;   (* opaque handle *)

PROCEDURE LoadLibrary*(fileName: ARRAY OF CHAR): RDFModule;
PROCEDURE LoadLibraryWith*(fileName: ARRAY OF CHAR; ...): RDFModule;
PROCEDURE GetProcAddress*(module: RDFModule; name: ARRAY OF CHAR): SYSTEM.ADDRESS;
PROCEDURE FreeLibrary*(module: RDFModule);
```

See [`examples/RDFLOAD/`](examples/RDFLOAD) for a worked example that loads
a hand-assembled `.rdf` and calls an exported function through a procedure
variable.

---

## Debug info for Turbo Debugger

Compile a module with `(*$D+*)` and link with `/G` to append a Borland
TDS/TDINFO v2.08 debug-info block onto the linked `.exe`:

```oberon
(*$D+*)
MODULE MyProg;
...
```

```
toc.exe /G /ENTRY=Run MyProg.Mod
```

The block carries modules, source file names, symbols, and a line-number
table, readable by Turbo Debugger or a compatible tool. **Without `/G` the
`.exe` is byte-identical** to a build without the feature at all — the
block is a pure append, and DOS never loads it (only a debugger reads past
the program's own image). Inspect one with the bundled `BIN/TDINFO.EXE
FILE.EXE`. Full binary layout: [`DOCS/TD-SPEC.MD`](DOCS/TD-SPEC.MD).

---

## Porting from Pascal / C

Coming from Turbo Pascal, Borland Pascal, or 16-bit C, most of what you
already know carries over directly — DOS is DOS. The full guide, including
a construct-by-construct comparison table and idiom translations, is
[`DOCS/PORTING.MD`](DOCS/PORTING.MD). The short version:

- **Modules replace units/headers.** `IMPORT` is Oberon's `uses`/`#include`
  — no forward declarations of imported symbols needed.
- **No preprocessor.** `$L`/`$M`/`$R`/`$D` directives cover the handful of
  things you'd reach for `{$...}` for in Pascal.
- **`VAR` is Pascal's `var`, not a C `&`.** Passing a literal or an
  expression to a `VAR` parameter is a compile error, same as Pascal.
- **`RECORD`/`POINTER` extension replaces `object`/classes.** No virtual
  methods — write ordinary procedures that take the record as an explicit
  parameter, and use `IS`/type-tag dispatch where Pascal would use a vtable.
- **`FAR`/`NEAR`/`EXTERNAL` map onto exactly what they meant in Turbo
  Pascal** — this compiler targets the same large memory model conventions
  by design.

---

## Examples

Small, self-contained programs under [`examples/`](examples):

| Example | What it shows |
|---|---|
| [`CALENDAR.MOD`](examples/CALENDAR.MOD) | Command-line argument parsing (`Dos.ParamStr`), `Time` date arithmetic, formatted grid output via `Out` |
| [`FORTH.MOD`](examples/FORTH.MOD) | A small interactive Forth interpreter — procedure variables as a dispatch table, dynamic word definitions, a hand-rolled parser over `In`/`Out` |
| [`RDFLOAD/`](examples/RDFLOAD) | Loading a separately-assembled `.rdf` at runtime with `RdfLoad` and calling into it through a procedure variable |

---

For anything not covered here — exact codegen sequences, the RDOFF2 object
format, `.def` file layout, or the DOS/16-bit portability rules the
compiler itself follows — see [`DOCS/OBERLANG.MD`](DOCS/OBERLANG.MD),
[`DOCS/RDOFF2.MD`](DOCS/RDOFF2.MD), and [`DOCS/IMPLRULE.MD`](DOCS/IMPLRULE.MD).
