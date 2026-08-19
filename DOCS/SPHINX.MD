# SPHINX Oberon Language Specification

## A Low‑Level Oberon Dialect Compiling to NASM

SPHINX Oberon is a strict 16‑bit systems programming language that combines the structured syntax of Oberon‑2 with direct access to the x86 CPU. This document defines the complete language semantics and, crucially, shows how each construct translates into human‑readable NASM assembly. The target is real‑mode DOS .COM or .EXE programs; segment registers are 16‑bit and memory is addressed with `segment:offset` pairs.

Few notes:
- This dialect allow _ into identifiers.
- Comments are `(* ... *)` only — no `//` line-comment form. `(* *)` does **not** nest: the first `*)` closes the comment regardless of any `(*` seen since, so `(* outer (* inner *) still code *)` is a comment ending after `inner`, leaving `still code *)` to be parsed as ordinary source (and very likely a syntax error) — unlike Oberon-07 proper (`DOCS/OBERON07.EBN`), which does nest.
- Exported procedures (marked with * ) is GLOBAL (nasm) and can be NEAR/FAR (default - far).
- If module initialization part exists - need generate label "start" and this block begin.
- IMPORT keyword is the same as #include (in c) - just includes other source file (in Sphinx Oberon). This file must start with `MODULE modulename;` and ends with `END modulename.`. All others - ecavtly as in C (just include SPHINX Oberon text).
- STRONG: Allowed 8086 intruction set only. (no 286, 386 etc)

---

## 1. Module Structure

```
MODULE ModuleName;
  IMPORT OtherModule;   (* optional *)
  CONST ...
  TYPE  ...
  VAR   ...             (* global variables *)
  PROCEDURE ...;         (* definitions, and optionally FORWARD
                             declarations -- see §6.3.1 *)
  PROCEDURE ...;
  ...
BEGIN
  ...                   (* module initialisation *)
END ModuleName.
```

**NASM translation:**  
Globals are placed in the `.data` section (or `.bss` for uninitialised). Code goes in the `.text` section. The module body becomes the entry point. Example:

```
MODULE Hello;
BEGIN
  AX := 0x4C00;
  INT(21H)
END Hello.
```

↓

```nasm
section .data
section .text
global start
start:
    mov  ax, 0x4C00
    int  0x21
```

---

## 2. Registers

The CPU registers are predefined variables. They are typed as follows:

| Register | Type     |
|----------|----------|
| AX, BX, CX, DX, SI, DI, BP, SP | WORD (16‑bit unsigned/signed) |
| AL, AH, BL, BH, CL, CH, DL, DH | BYTE |
| CS, DS, ES, SS                 | WORD (segment) |

Registers can be read and written just like ordinary variables. The compiler generates a `mov` instruction (or an appropriate alternative) for every assignment.

**Examples:**

```ob2
AX := 0x1234;
AL := AH;
BX := CX + 4;
DS := CS;
```

↓

```nasm
mov  ax, 0x1234
mov  al, ah
mov  bx, cx
add  bx, 4          ; because + is left‑to‑right, but BX := CX + 4 becomes mov bx,cx then add bx,4
push cs             ; mov ds, cs does not exists for 8086
pop  ds
```

The compiler must never preserve a register unless explicitly instructed by `USES` (see §7). In expressions, reading a register yields its current value; writing it updates the hardware.

---

## 3. Types and Type Declarations

### 3.1 Basic Types

| Type    | Size (bytes) | Description                           |
|---------|--------------|---------------------------------------|
| BYTE    | 1            | unsigned 8‑bit                        |
| BOOLEAN | 1            | like BYTE, 0 = FALSE, ≠0 = TRUE       |
| WORD    | 2            | unsigned 16‑bit (synonym for INTEGER) |
| INTEGER | 2            | signed 16‑bit                         |
| LONGINT | 4            | signed 32‑bit, stored little‑endian   |
| Array   | element_size × count | packed sequentially           |
| RECORD  | sum of field sizes   | fields aligned to natural boundaries |

`TRUE` and `FALSE` are predeclared BOOLEAN constants (`TRUE` = 1, `FALSE` = 0), usable anywhere a literal is:

```ob2
RETURN TRUE
```

↓

```nasm
mov  ax, 1
```

Arrays and records are declared as in Oberon:

```ob2
VAR
  buf: BYTE[128];
  items: StructXmsRec[4];
```

In NASM these become `resb`, `resw`, `resd` or `db`, `dw`, `dd`.

**Passing an array to a procedure:** there is no array-typed formal
parameter syntax (`ParseParams` only ever resolves a scalar or RECORD
type per parameter group, §6.6 — `x: BYTE[10]` in a parameter list does
not parse). The working pattern is the same address-passing model
string literals already use (§3.3): declare the parameter as a plain
`WORD`/`INTEGER` holding the array's address, pass `ADR(arr)` at the call
site, and index through it with direct memory access (§10) inside the
callee.

```ob2
VAR buf: BYTE[16];
PROCEDURE FillIt(bufAddr: INTEGER); NEAR;
BEGIN
  BX := bufAddr;
  [DS:BX] := 65
END FillIt;
...
FillIt(ADR(buf));
```

↓

```nasm
FillIt:
    push bp
    mov  bp, sp
    mov  bx, [bp+4]     ; bufAddr
    mov  ax, 65
    mov  [ds:bx], ax    ; a bare "[DS:BX] := 65" stores a WORD -- see §10
                         ; for how to size a store to a specific field/byte
    mov  sp, bp
    pop  bp
    retn 2
...
    mov  ax, buf        ; ADR(buf) -- buf's own address, a compile-time constant for a global
    push ax
    call FillIt
```

### 3.2 Global Type Declarations

Record types are defined at module level in the `TYPE` section. Each record becomes a NASM structure that can be used for field offset calculations.

**Syntax:**

```
TYPE
  RecordName = RECORD
    field1 : type;
    field2 : type;
    ...
  END;
```

**NASM translation:**  
A NASM `struc` is emitted. The structure name is `RecordName` and its fields are accessible as `RecordName.fieldName` inside the assembler.

```
TYPE
  Point = RECORD
    x : INTEGER;
    y : INTEGER;
  END;

  BigData = RECORD
    id    : WORD;
    value : LONGINT;
    flag  : BYTE;
  END;
```

↓

```nasm
struc Point
    .x: resw 1
    .y: resw 1
endstruc

struc BigData
    .id:    resw 1
    .value: resd 1
    .flag:  resb 1
endstruc
```

The compiler may add alignment padding as needed for word/dword fields (usually no padding in 16‑bit real mode, but we keep it simple – no padding by default). All field offsets are byte offsets from the start of the structure.

Once a record type is defined, it can be used in variable declarations and direct memory access (see §10).

### 3.3 Character and String Literals

Two distinct quoting styles, matching NASM's own distinction between a character-literal immediate and a quoted string operand:

- **`'x'`** (single-quoted, exactly one character) is a plain numeric immediate — its `ORD` value. No storage is allocated; it behaves exactly like a numeric literal.
- **`"..."`** (double-quoted, any length including empty) is a genuine string literal. It is stored once in a `.data` table (deduplicated: two occurrences of the identical text share one label) and evaluates everywhere to its own **offset** — SPHINX has no string-*value* operations, only pass-by-offset, the same model arrays and records already use. A string literal can be passed as a call argument, assigned to a register, or assigned to a 16-bit variable.

```ob2
AL := 'A';
PrintMsg("Hello, world!$");
msgPtr := "Another one$";
```

↓

```nasm
mov  AL, 65
mov  ax, _literal0
push ax
call PrintMsg
mov  ax, _literal1
mov  [msgPtr], ax
...
section .data
_literal0: db 'Hello, world!$', 0
_literal1: db 'Another one$', 0
```

Every literal used anywhere in a module is collected and emitted once, as a NUL-terminated `db` line, in a `.data` block appended at the very end of the translated output — the label may be referenced (as a forward reference) from anywhere earlier in the file.

A literal cannot contain its own delimiter character (no escape mechanism): a `"..."` string cannot contain `"`, and `'...'` is always exactly one character.

---

## 4. Constants

Constants are simple named values of type INTEGER, WORD, BYTE, or LONGINT. They can be used wherever a literal is allowed. No storage is allocated.

```ob2
CONST
  MaxBuf = 128;
  ComPort = 0x3F8;
```

---

## 5. Variables

### 5.1 Global Variables
Defined at module level, they reside in either the `.bss` or `.data` segment depending on whether an initializer is given: an **uninitialized** global (the common case — a plain scalar, an array, or a RECORD instance) is zero-filled reserved space and belongs in `.bss`; only a global with an explicit `= value` initializer holds a real stored value and belongs in `.data`. There is no default/assumed section anywhere in the output — each declaration switches to whichever section it needs.

```ob2
VAR
  counter: INTEGER;
  flag: BYTE;
  bigValue: LONGINT;
```

↓

```nasm
section .bss
counter: resw 1
flag:    resb 1
bigValue: resd 1
```

If an initial value is given (Oberon allows it), a real value is stored, and it goes to `.data` instead:

```ob2
VAR version: WORD = 0x1700;
```

↓

```nasm
section .data
version dw 0x1700
```

### 5.2 Local Variables
Declared inside a procedure, they are allocated on the stack. The compiler reserves space by adjusting `SP`.

```ob2
PROCEDURE Example;FAR;
VAR
  i: INTEGER;
  tmp: BYTE[4];
BEGIN
  ...
END
```

↓

```nasm
Example:
    push bp
    mov  bp, sp
    sub  sp, 6          ; 2 bytes for i + 4 bytes for tmp
    ...
    mov  sp, bp
    pop  bp
    retf                ; or retn
```

Access to local variables uses `[bp - offset]`.

---

## 6. Procedures and Calling Convention

### 6.1 Pascal Calling Convention
Parameters are pushed **left to right**. The callee cleans the stack with `ret n`. This is the default for `NEAR` procedures.

```ob2
PROCEDURE Add(a, b: INTEGER): INTEGER; NEAR;
BEGIN
  AX := a;
  AX := AX + b;
  RETURN AX
END Add;
```

Call: `result := Add(3, 4);`

↓

```nasm
; Call site
mov  ax, 3
push ax
mov  ax, 4
push ax
call Add
; (callee cleans, so no add here)

; Procedure definition
Add:
%define _a bp+6
%define _b bp+4
    push bp
    mov  bp, sp
    mov  ax, [_a]   ; a (first param, higher address)
    add  ax, [_b]   ; b (second param)
    mov  sp, bp
    pop  bp
    retn  4           ; clean 4 bytes of parameters
%undef _a
%undef _b
```

Stack layout after `push bp` / `mov bp, sp`:

```
[bp+0] = saved BP
[bp+2] = return IP (NEAR)
[bp+4] = last pushed param (rightmost)
[bp+6] = first pushed param (leftmost)
```

### 6.2 Register Parameters
If a formal parameter name matches a register, the value is passed **directly in that register** – no stack operation.

```ob2
PROCEDURE CB_API(AX); NEAR;
BEGIN
  INT(2FH)
END CB_API;
```

Call: `CB_API(0x1700);`

↓

```nasm
; call site
mov  ax, 0x1700
call CB_API

; procedure (near, no stack frame needed)
CB_API:
    int  0x2F
    retn
```

No stack frame is generated if the procedure doesn't have local variables, non-register parameters, or `USES`.

The call site shown above is the minimal-case ideal, not `SPHO.MOD`'s own literal current output: the real translator always pushes every argument first (any argument's own evaluation might otherwise clobber an already-computed register-bound one, `DOCS/SPHO.MD`'s own "Call sites now load a register-named formal's argument directly" entry has the full reasoning), then extracts each register-bound one back off the stack via a small self-contained `push bp`/`[bp+N]`/`pop bp` sequence — a few bytes larger than the ideal `mov ax, 0x1700; call CB_API` shown here for this trivial single-argument case, but correct for any number/mix of register- and stack-bound arguments in any order, which the minimal form cannot express in general.

The keyword `REG` is optional for clarity: `PROCEDURE CB_API(REG AX);` is equivalent.

### 6.3 Procedure Attributes

| Attribute   | Call instruction | Return instruction | Description |
|-------------|------------------|--------------------|-------------|
| `NEAR` (default) | `call`      | `ret` / `ret n`    | 16‑bit near call |
| `FAR`       | `call far`       | `retf` / `retf n`  | 16‑bit far call, stack includes segment |
| `INTERRUPT` | (none)           | `iret`             | Interrupt handler, no parameters allowed |

**INTERRUPT** procedures cannot be `NEAR`/`FAR`. They must end with `iret`. `USES` and local `VAR`s are allowed (an `INTERRUPT` procedure has its own stack frame for those, same `push bp`/`mov bp,sp` prologue as any other), but **parameters are not** — an interrupt has no caller-pushed argument list to clean up. If `USES` is present, the compiler automatically saves/restores the listed registers and flags. Without `USES`, the programmer must do it manually in `ASM` blocks.

SPHO.MOD does not currently enforce "no parameters" for `INTERRUPT` — a parameter list is parsed and accepted the same as for any other procedure attribute (`SRC/TASM/SPHO.MOD`'s `ParseProcedure` parses `(...)` before it ever sees `NEAR`/`FAR`/`INTERRUPT`, with no rejection check afterward); writing one anyway is unspecified behavior, not a documented feature — the resulting `iret` return does not clean up a caller-pushed argument list the way `retn n`/`retf n` would for `NEAR`/`FAR`.

### 6.3.1 `FORWARD` Declarations

`PROCEDURE Name(params): RetTy; NEAR|FAR; FORWARD;` declares a procedure's
full signature without a body — the real definition (identical signature,
a real `BEGIN...END` body) appears later in the same file. This lets a
procedure call another one that is textually defined further down:

```ob2
PROCEDURE Helper(): INTEGER; NEAR; FORWARD;

PROCEDURE Caller(): INTEGER; NEAR;
BEGIN
  RETURN Helper()
END Caller;

PROCEDURE Helper(): INTEGER; NEAR;
BEGIN
  RETURN 42
END Helper;
```

**Why this matters:** a call site can only ever know `Helper`'s
`NEAR`/`FAR`-ness (`call` vs. `call far`, §6.3 — getting this wrong
corrupts the stack on return, in either direction) from a PROCEDURE
declaration/definition of that name already seen earlier in the file
(single-pass translator, no whole-file lookahead). A forward call with
**no** `FORWARD` declaration for its target is a translator error
("call to '...' precedes its own definition with no FORWARD
declaration") — earlier versions of `SPHO.MOD` silently guessed `FAR`
for an unresolved name instead, which corrupted the stack (hung the
program) whenever the real procedure turned out to be `NEAR`. There is
no equivalent for the reverse situation (defined before use) — that case
never needs `FORWARD` at all, since the definition has already been seen
by the time the call site is translated.

A `FORWARD` declaration is not itself a callable definition: a second,
real `PROCEDURE Name...` with the same name (matching or not) is
required later in the file, or the name is still unresolved at
end-of-file (same error as never declaring it). Two full `PROCEDURE`
definitions sharing a name (not a `FORWARD` followed by its real body)
is a translator error ("duplicate PROCEDURE definition"). `FORWARD` is
not supported on an `INTERRUPT` procedure.

### 6.4 Return Values
Functions return via registers:

| Return type | Register |
|-------------|----------|
| BYTE, BOOLEAN | AL     |
| INTEGER, WORD | AX     |
| LONGINT       | DX:AX (DX=high, AX=low) |

**`CHAR` is not a real SPHINX Oberon type** — `SRC/TASM/SPHO.MOD` has no `CHAR` type anywhere (`ParseBaseType`'s scalar-keyword list is `BYTE`/`BOOLEAN`/`WORD`/`INTEGER`/`LONGINT` only, matching §3.1's own table). A single character is represented as a `BYTE` holding its ASCII value (or a `'x'` character literal, §3.3, which is itself just a numeric immediate).

The compiler generates a move to the appropriate register(s) before `RET`.

```ob2
PROCEDURE GetMax(): INTEGER; NEAR;
BEGIN
  RETURN 0xFFFF
END;
```

↓

```nasm
GetMax:
    mov  ax, 0xFFFF
    retn
```

A procedure call taking no arguments may omit the parentheses entirely — `Foo;` is equivalent to `Foo();`:

```ob2
XMS_CLEAR_REC;
```

↓

```nasm
call far XMS_CLEAR_REC
```

### 6.5 `USES` Clause
`USES` lists registers that the procedure must preserve. The compiler emits `push` in prologue and `pop` in epilogue. `FLAGS` is also valid and generates `pushf`/`popf`.

```ob2
PROCEDURE Calc; NEAR;
USES BX, CX, FLAGS;
BEGIN
  ...
END;
```

↓

```nasm
Calc:
    push bx
    push cx
    pushf
    ... body ...
    popf
    pop  cx
    pop  bx
    retn
```

`USES` can appear together with local variables; the allocation order is: push BP, set BP, push USES registers, then allocate local space. Epilogue reverses.

### 6.6 Procedure Parameters

Procedures can have parameters with different types. A comma-separated run of names shares one trailing type (`a, b: INTEGER` — both `a` and `b` are INTEGER); `;` starts a new group with its own type, so a single parameter list can mix types freely:

```ob2
PROCEDURE Mixed(x: BYTE; y: INTEGER): INTEGER;
BEGIN
  AX := x;
  BX := y;
  RETURN AX + BX
END Mixed;
```

Call: `result := Mixed(1, 20);`

↓

```nasm
; Call site
mov  ax, 1
push ax
mov  ax, 20
push ax
call far Mixed

; Procedure definition
Mixed:
    push bp
    mov  bp, sp
    mov  AX, [bp+8]   ; x (first param, higher address)
    mov  BX, [bp+6]   ; y (second param)
    add  ax, BX
    mov  sp, bp
    pop  bp
    retf  4           ; clean 4 bytes of parameters (default FAR, unmarked NEAR/FAR)
```

A register-named formal (§6.2) never takes a type at all and never shares a following group's type — it may sit alongside ordinary names in the same comma-separated run.

**By-value RECORD parameters are not supported.** A parameter's type may
be `BYTE`/`BOOLEAN`/`WORD`/`INTEGER`/`LONGINT` or a declared RECORD type,
but a RECORD-typed one is rejected as a translator error ("by-value
RECORD parameter not supported") — the Pascal calling convention above
pushes/reads exactly one word (or byte) per parameter, which cannot
represent a multi-byte struct's full value: an earlier version of
`SPHO.MOD` accepted this silently and truncated the record to its own
first field at both the call site and the callee's own stack-cleanup
size, a correctness bug, not merely an unsupported feature. Pass a
record the same way an array is passed (§3.1): `ADR(rec)` into a plain
`WORD`/`INTEGER` parameter, and access fields inside the callee via
direct memory access (§10, `[seg:paramReg].RecordType.field`).

---

## 7. Expressions and Operators

Expressions are evaluated **strictly left to right**, ignoring traditional operator precedence. Parentheses override the default order.

### 7.1 Arithmetic Operators

| Operator | Meaning          | x86 instruction |
|----------|------------------|-----------------|
| `+`      | addition         | `add`           |
| `-`      | subtraction      | `sub`           |
| `*`      | unsigned multiply (16‑bit) | `mul` (DX:AX = AX * src) |
| `IDIV`   | signed division   | `idiv` (AX = quotient, DX = remainder) |
| `IMOD`   | signed remainder  | same `idiv`, use DX |
| `DIV`    | unsigned division | `div`           |
| `MOD`    | unsigned remainder| same `div`, use DX |

**Not implemented in `SPHO.MOD`:** `*`, `IDIV`, `IMOD`, `DIV`, `MOD` are
none of them wired up — `IDIV`/`IMOD`/`DIV`/`MOD` are not even registered
keywords (`SRC/TASM/SPHO.MOD`'s own keyword table has no `Kw` entry for
any of the four), and the symbol `*` is only ever consumed elsewhere in
the grammar (procedure-export marker `PROCEDURE Foo*`), never as a
binary multiply operator — `mul`/`idiv`/`div` never appear anywhere in
SPHO's own codegen. `+`, `-` (§7.1) and `&`, `|` (§7.2) are the only
arithmetic/bitwise binary operators SPHO actually emits; the rest of
this section documents the intended design, not current behavior.

Because evaluation is left to right, the compiler must carefully order operands. Example (**not implemented** — uses `*`, see above):

```ob2
AX := 3 + 4 * 5;   (* = (3+4)*5 = 35 *)
```

↓

```nasm
mov  ax, 3
add  ax, 4
mov  cx, 5
mul  cx              ; DX:AX = AX * CX, result in AX (truncated)
```

For `IDIV`/`DIV`, the dividend is DX:AX, so the compiler must sign‑extend or zero‑extend AX into DX before the division.

```ob2
AX := BX IDIV CX;    (* signed division -- NOT IMPLEMENTED, see above *)
```

↓

```nasm
mov  ax, bx
cwd                   ; sign-extend AX to DX:AX
idiv cx               ; AX=quotient, DX=remainder
; result in AX
```

### 7.2 Bitwise Operators

| Operator | Meaning   | x86 instruction |
|----------|-----------|-----------------|
| `&`      | AND       | `and`           |
| `\|`     | OR        | `or`            |
| `~`      | NOT (unary)| `not`          |
| `SHL`    | left shift | `shl` (clamping count) |
| `SHR`    | right shift| `shr`          |

**`~` as a general unary NOT is not implemented.** `SPHO.MOD` only ever
consumes `~` in condition position, directly in front of `CFLAG`/`ZFLAG`
(§7.5) or a bare BOOLEAN condition (§8.1) — negating there via jump
selection (`onTrue # negated` picking the opposite `Jcc`), never by
emitting a `not` instruction. `~` used as an ordinary expression operator
(`AL := ~AL;`) is not recognized. `&` and `\|` (this table's other two
rows) ARE real, general binary expression operators, wired into the
left-to-right emitter the same as `+`/`-` (§7.1).

The shift count is either an immediate or taken from `CL` if the right operand is a register.

```ob2
AL := AL SHL 1;
BX := CX SHR CL;
```

↓

```nasm
shl  al, 1
mov  bx, cx
shr  bx, cl
```

### 7.3 Relational Operators
Relationals compare two values and set the destination to 0 or 1. Internally, they use `cmp` and a conditional jump — **never `SETcc`** (that's a 386+ instruction; this dialect targets 8086 only, see the notes at the top of this document).

```ob2
IF AX > BX THEN ...
```

↓

```nasm
cmp  ax, bx
jg   .L1
...
```

When used as a value, an 8086-legal `cmp`/`Jcc`/`mov 0`/`jmp`/`mov 1` sequence is emitted instead of `xor`/`setCC`:

```ob2
AL := AX > BX;   (* AL = 1 if AX>BX else 0 *)
```

↓

```nasm
cmp  ax, bx
jg   .L1
mov  al, 0
jmp  .L2
.L1:
mov  al, 1
.L2:
```

This is terminal — no example chains a relational result into a further operator.

### 7.4 Logical Operators
`~`, `&`, `OR` operate on boolean (byte) values. No short‑circuit; both operands are computed.

**Not implemented in `SPHO.MOD`.** The keyword `OR` does not exist at
all (absent from `SRC/TASM/SPHO.MOD`'s own keyword table), and a
condition accepts only a single `a REL b` relational or a single bare
BOOLEAN value (§8.1), optionally `~`-negated — never a composition of
two conditions joined by `&`/`OR`. `IF (AX < 10) OR (BX > 20) THEN` does
not parse; write it as two nested `IF`s, or compute each half into a
BOOLEAN local first and combine with `&`/`\|` (§7.2, both of which ARE
real binary operators) before testing the combined result.

```ob2
IF (AX < 10) OR (BX > 20) THEN ...   (* NOT IMPLEMENTED *)
```

↓

```nasm
; compute (AX<10) -> al
; compute (BX>20) -> bl
; or al, bl
; jnz .Ltrue
```

The compiler may optimise by using conditional jumps directly for `IF`.

### 7.5 Conditional Flags
In a condition, `CFLAG` and `ZFLAG` can be tested directly, avoiding a `cmp`.

```ob2
WHILE ~ZFLAG DO ... END;
```

↓

```nasm
.Lloop:
    jz  .Lexit
    ...
    jmp .Lloop
.Lexit:
```

---

## 8. Control Flow

### 8.1 IF Statement

```
IF condition THEN
  stats
{ELSIF condition THEN
  stats}
[ELSE
  stats]
END
```

The compiler generates labels and conditional jumps.

```ob2
IF AX = 0 THEN
  BX := 1
ELSE
  BX := 2
END;
```

↓

```nasm
    cmp  ax, 0
    jne  .Lelse
    mov  bx, 1
    jmp  .Lend
.Lelse:
    mov  bx, 2
.Lend:
```

`condition` (here and in `WHILE` below) is either a full `a REL b` relational (§7.3) or a bare BOOLEAN value used directly — a variable, register, or a BOOLEAN-returning call — tested against zero (TRUE=1/FALSE=0, §3.1) instead of a `cmp`:

```ob2
IF sss THEN ... END;          (* same as IF sss = TRUE THEN ... END *)
IF ~sss THEN ... END;         (* same as IF sss = FALSE THEN ... END *)
WHILE HasMore() DO ... END;   (* same as WHILE HasMore() = TRUE DO ... END *)
```

`~` in front of a bare condition negates it the same way it does for `CFLAG`/`ZFLAG` (§7.5); it is not a general boolean-expression operator elsewhere (§7.4's own "no `&`/`OR` composition in a condition" limit still applies — only a single bare condition, optionally `~`-negated, is accepted, not `~(a & b)` or similar).

### 8.2 WHILE Loop

```
WHILE condition DO
  stats
END
```

`BREAK` exits the innermost loop. `CONTINUE` jumps to the condition check.

```ob2
WHILE CX # 0 DO
  DX := DX - 1;
  IF DX = 0 THEN BREAK END;
  CX := CX - 1
END;
```

↓

```nasm
.Lloop:
    cmp  cx, 0
    je   .Lexit
    dec  dx
    cmp  dx, 0
    jne  .Lskip_break
    jmp  .Lexit
.Lskip_break:
    dec  cx
    jmp  .Lloop
.Lexit:
```

### 8.3 RETURN Statement

```ob2
RETURN expression;
```

Evaluates expression into `AX`, then jumps to the procedure's own single epilogue label. `RETURN` is legal anywhere inside a procedure body, not only as its textually last statement — a `RETURN` inside a conditional branch, a loop, or any nested statement correctly skips the rest of the body:

```ob2
PROCEDURE Cond(x: INTEGER): BOOLEAN;
BEGIN
  IF x < 5 THEN RETURN TRUE
  ELSE RETURN FALSE END;
  AX := 999   (* unreachable *)
END Cond;
```

↓

```nasm
Cond:
    push bp
    mov  bp, sp
    mov  ax, [bp+4]
    cmp  ax, 5
    jge  .L1
    mov  ax, 1
    jmp  .Lexit
.L1:
    mov  ax, 0
    jmp  .Lexit
    mov  AX, 999   ; unreachable
.Lexit:
    mov  sp, bp
    pop  bp
    retn 2
```

The epilogue (local-frame cleanup, `USES` pop, `ret`/`retf`/`iret`) is emitted exactly once, right after `.Lexit`; a body that falls off the end without an explicit `RETURN` reaches the same label by falling through, unaffected.

If no expression is given (for a procedure), it just jumps to the epilogue.

---

## 9. Built‑in Procedures and Functions

These are part of the language and generate inline code.

| Built‑in          | NASM translation                    |
|-------------------|-------------------------------------|
| `INC(var)`        | `inc word [var]` (or byte)          |
| `DEC(var)`        | `dec word [var]`                    |
| `INC(var, expr)`  | `add [var], expr` (or a register destination directly) |
| `DEC(var, expr)`  | `sub [var], expr` |
| `PUSH(r1,r2,...)` | `push r1` etc.                      |
| `POP(r1,r2,...)`  | `pop rN` in reverse order           |
| `INT(n)`          | `int n`                             |
| `ADR(v)`          | `offset v`                          |
| `SEG(v)`          | `seg v`                             |
| `SIZE(T)`         | `sizeof(T)` (constant)              |
| `ODD(x)`          | `test ax,1` / `jz`/`mov 0`/`jmp`/`mov 1` (no `SETcc`; 8086 only) |

`ADR(v)` returns the offset of `v` within its segment. `v` may name a global VAR, a local VAR, a (non-register) parameter, or a PROCEDURE: a global or a PROCEDURE both yield a constant offset (`offset v`, a PROCEDURE's own bare label is already its own offset as a NASM immediate — useful for installing an interrupt vector or any other function-pointer-style use), while a local/parameter yields its stack-frame address computed at runtime (`lea ax, [bp±N]`). A register-named parameter has no address and is rejected.
For far pointers, the segment can be obtained via `CS`, `DS`, etc.
For example, `ADR(xmsRec)` yields a constant offset.

`SEG(v)` returns the segment of `v` (also global-VAR only).

`ADR`/`SEG`/`SIZE`/`ODD` are value built-ins — usable as an expression's RHS, but not directly as an `IF`/`WHILE` condition. `CFLAG`/`ZFLAG` (§7.5), by contrast, are condition-position-only. The two built-in families are not interchangeable.

`INC`/`DEC` take an optional second argument — `INC(v, expr)`/`DEC(v, expr)` is `v := v + expr`/`v := v - expr`, `expr` any expression (including a call), evaluated the same way an ordinary right-hand side is. `v` may be a variable or a bare register name.

```ob2
INC(counter, 5);
DEC(BX, delta);
```

↓

```nasm
mov  ax, 5
add  word [counter], ax
mov  ax, [delta]
sub  bx, ax
```

When `v` is the register `AX` itself, its old value must survive evaluating `expr` (which may itself use `AX`, e.g. any call result) — `AX` is saved and restored around `expr`'s evaluation instead of being combined directly:

```ob2
INC(AX, delta);
```

↓

```nasm
push ax
mov  ax, [delta]
mov  cx, ax
pop  ax
add  ax, cx
```

---

## 10. Direct Memory Access

Square‑bracket notation accesses memory at a given segment:offset. The general forms are:

```
[segment:offset]                     ; simple byte/word access
[segment:base] RecordType.field      ; structured field access
```

The segment override is optional; if omitted, `DS` is assumed (except when `BP` is the base, where `SS` applies). The base register can be any 16‑bit register that can be used in an effective address (`BX`, `BP`, `SI`, `DI`). For structured access, the record type and field name are appended with a dot, allowing the compiler to compute the correct offset.

**Examples:**

```ob2
AL := [DS:0484H];               (* direct memory byte read *)
[ES:BX] := AL;                  (* direct byte write *)
[DS:SI].StructXmsRec.len := AX; (* write to record field *)
AX := [ES:BX].Point.x;          (* read record field *)
```

**NASM translation:**

```nasm
mov  al, [ds:0x0484]
mov  byte [es:bx], al
mov  [ds:si + StructXmsRec.len], ax   ; offset of 'len' is StructXmsRec.len
mov  ax, [es:bx + Point.x]            ; offset of 'x' is Point.x
```

If no segment is given:

```ob2
AL := [0484H];                 ; DS is implied
```

↓

```nasm
mov  al, [0x0484]
```

The compiler resolves the field offset using the NASM structure definition. For example, `StructXmsRec` defined as a `struc` with `.len` at offset 0, `.src_hnd` at offset 4, etc. `[SI].StructXmsRec.src_hnd` becomes `[si + StructXmsRec.src_hnd]`.

When the target is a `LONGINT`, the compiler generates two moves if necessary, but the built‑in `LONGINT` register‑pair moves (see §11) provide more efficient bulk transfer.

---

## 11. LONGINT Register‑Pair Moves

Basic syntax — `variable` is a declared `LONGINT` VAR (global or local) referenced by its bare name, `SEGREG:REG` is `ES`/`DS` paired with any general 16‑bit register, and `REG:REG` is any other register pair (`DX:AX`, `ES:DI`, ...):

```ob2
SEGREG:REG := variable;
REG:REG    := variable;
variable   := SEGREG:REG;
variable   := REG:REG;
SEGREG:REG := REG:REG;
SEGREG:REG := myfunction();
```

These allow efficient loading/storing of 32‑bit values using `LES`/`LDS` instructions where possible. A register-pair operand may not currently be a `[seg:base]` memory-access expression — only a plain named `LONGINT` variable.

| Syntax | NASM |
|--------|------|
| `ES:BX := longvar;` | `les bx, [longvar]` |
| `DS:BX := longvar;` | `lds bx, [longvar]` |
| `DS:SI := longvar;` | `lds si, [longvar]` |
| `ES:DI := longvar;` | `les di, [longvar]` |
| `DX:AX := longvar;` | `mov ax, [longvar]` / `mov dx, [longvar+2]` |
| `ES:DI := DX:AX;` | `MOV DI,AX`/`MOV ES,DX` |
| `longvar := ES:BX;` | `mov [longvar], bx` / `mov [longvar+2], es` |
| etc. | … |

The compiler uses `les`/`lds` when possible, which are more efficient.

```ob2
xmsApiEntry := ES:BX;
```

↓

```nasm
mov  [xmsApiEntry], bx
mov  [xmsApiEntry+2], es
```

```ob2
ES:BX := xmsApiEntry;
```

↓

```nasm
les  bx, [xmsApiEntry]
```

```ob2
ES:BX := myfunction()
```

↓

```nasm
call myfunction
mov  bx, ax
mov  es, dx
```

... and vice versa!

---

## 12. Inline Assembly

A block `ASM ... END` is copied verbatim into the output. It must respect NASM syntax. Labels inside are local to the procedure.

```ob2
ASM
  cld
  rep stosb
END
```

↓

```nasm
cld
rep stosb
```

---

## 13. Complete Example with Record Types

The following excerpt shows the declaration of a record type and its use with structured memory access.

### Type declaration (module level)

```ob2
TYPE
  StructXmsRec = RECORD
    len      : LONGINT;
    src_hnd  : INTEGER;
    src_ofs  : LONGINT;
    dst_hnd  : INTEGER;
    dst_ofs  : LONGINT;
    src_high : BYTE;
    dst_high : BYTE
  END;
```

↓

```nasm
struc StructXmsRec
    .len:      resd 1
    .src_hnd:  resw 1
    .src_ofs:  resd 1
    .dst_hnd:  resw 1
    .dst_ofs:  resd 1
    .src_high: resb 1
    .dst_high: resb 1
endstruc
```

### Access in code

```ob2
PROCEDURE xmsCopy(lenl, lenh, srcHnd, srcl, srch, dstHnd, dstl, dsth: INTEGER); NEAR;
USES DS, SI, CX;
VAR
  tmpLen, tmpSrc, tmpDst: LONGINT;
BEGIN
  XMS_CLEAR_REC;
  DS := CS;
  SI := ADR(xmsRec);
  tmpLen := lenl + (lenh * 65536);
  tmpSrc := srcl + (srch * 65536);
  tmpDst := dstl + (dsth * 65536);
  DX:AX := tmpLen;   [DS:SI].StructXmsRec.len     := DX:AX;
  DX:AX := tmpSrc;   [DS:SI].StructXmsRec.src_ofs := DX:AX;
  DX:AX := tmpDst;   [DS:SI].StructXmsRec.dst_ofs := DX:AX;
  [DS:SI].StructXmsRec.src_hnd := srcHnd;
  [DS:SI].StructXmsRec.dst_hnd := dstHnd;
  XMS(XMS_API_COPY)
END xmsCopy;
```

↓

```nasm
xmsCopy:
    push bp
    mov  bp, sp
    push ds
    push si
    push cx
    sub  sp, 12       ; local LONGINT variables (3*4 bytes)
    ; ... (XMS_CLEAR_REC call, etc.)
    mov  ds, cs
    mov  si, xmsRec   ; ADR(xmsRec) = offset xmsRec
    ; tmpLen ...
    ; DX:AX := tmpLen
    mov  ax, [bp-4]
    mov  dx, [bp-2]
    mov  [ds:si + StructXmsRec.len], ax
    mov  [ds:si + StructXmsRec.len + 2], dx
    ; etc.
    ...
    call XMS
    ; epilogue
    add  sp, 12
    pop  cx
    pop  si
    pop  ds
    mov  sp, bp
    pop  bp
    ret  16           ; 8 params * 2 bytes
```

The structured access `[DS:SI].StructXmsRec.len` elegantly maps to a NASM expression using the structure field offset.

---

## 14. Compiler Notes

- All numeric literals are evaluated as 16‑bit unless cast by context. **Not implemented:** an `L` suffix marking a literal LONGINT (`SRC/TASM/SPHO.MOD` has no such suffix anywhere) — a LONGINT value is only ever produced by a LONGINT-typed VAR/expression, never a literal written directly as one.
- The compiler should infer the type of expressions from the target register or variable.
- `WORD` and `INTEGER` are identical; the distinction is only for readability.
- Code generation must respect the 64‑KB segment limits; no relocation is performed.
- The resulting NASM file is assembled by this project's own `TASM.EXE` (`DOCS/TASM.MD`) into a RDOFF2 `.RDF`, then linked (`toc.exe`'s embedded linker, or `TLINK.EXE`'s `/T=com`/`/T=exe`/etc., `DOCS/BUILD.MD`) into a `.COM`/`.EXE` — not a generic `nasm -f bin`/`nasm -f obj` invocation.
- Global type declarations produce `struc` definitions that are visible throughout the module; field offsets are accessed using the `RecordType.fieldName` notation in NASM expressions.

