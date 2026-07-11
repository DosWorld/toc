# Oberon-07 Language — Compiler Rules

Rules for how Oberon-07 source is compiled to 8086/8087 machine code.
See also: [Implementation rules](IMPLRULE.MD), [RDOFF2 spec](RDOFF2.MD).

---

## Language dialect: Oberon-07 (with extensions)

Wirth 2007 revision plus practical extensions for DOS targets. Key differences from Oberon-2:
- No type-bound procedures (no methods)
- `FLOOR(x)` built-in (standard Oberon-07); `ENTIER(x)` accepted as synonym
- `FLOAT(x)` accepted as synonym for `REAL(x)`
- Integer operands are implicitly coerced to REAL/LONGREAL in binary expressions (`* / + - = # < > <= >=`); assignment still requires an explicit `REAL(x)` cast
- `FOR` loop with optional `BY` and multi-branch `ELSIF`
- `WHILE` loop has `ELSIF` branches
- No `WITH` statement
- `IMPORT` must list module names explicitly
- `LONGINT` = signed 32-bit integer (extension; uses DX:AX pair)
- `REAL` = 32-bit IEEE 754 float (extension; uses x87 FPU)
- `LONGREAL` = 64-bit IEEE 754 float (extension; uses x87 FPU)
- `SET` = 16-bit (fits in one word)
- Modules using `REAL` or `LONGREAL` require an x87 FPU coprocessor

Grammar reference: `DOCS/OBERON07.EBN`

### Identifier case sensitivity

**All identifiers are case-sensitive.** `Foo`, `foo`, and `FOO` are three distinct names.
This applies uniformly to: procedure names, variable names, constant names, type names,
parameter names, field names, module names, and module aliases.

Keywords (`BEGIN`, `END`, `VAR`, etc.) are all uppercase; their lowercase or mixed-case
variants (e.g. `begin`, `Begin`) are legal identifiers, not keywords.

Context-sensitive identifiers used as modifiers (`FAR`, `NEAR`, `EXTERNAL`) are also
matched case-sensitively and must appear in uppercase.

---

## Target: MS-DOS Real Mode

- **CPU:** 8086/8088 — NO 286+ instructions (except LES which is 8086 ✓)
- **FPU:** 8087 — NO 287+ instructions
- **Mode:** Real mode, 16-bit
- **Memory model:** Large model — CS≠DS≠SS at all times (see section below).
- **No DOS extender** — pure real mode, INT 21h for all OS calls
- Each procedure address must be aligned to 2.
- All pointers are FAR (4 bytes: offset word, segment word)

---

## Large memory model rules  ← CRITICAL for codegen

The linker produces a **large model** DOS executable.  The three segment registers have
distinct values at all times during execution:

```
CS  = current module's code segment paragraph    (differs per module)
DS  = combined data segment paragraph            (same for all modules)
SS  = stack segment paragraph                    (separate from DS)
```

**`CS ≠ DS ≠ SS`** — All three are distinct at all times.  Code that assumes any two
are equal (as in tiny/small/compact models) is WRONG for this target.

### Segment register usage at codegen level

| Variable kind       | Where stored              | Segment to push for VAR param |
|---------------------|---------------------------|-------------------------------|
| Local (stack)       | SS:[BP+ofs]               | `PUSH SS`                     |
| Global (data seg)   | DS:[data_ofs]             | `PUSH DS`                     |
| Heap object         | arbitrary far segment:ofs | already a far ptr (ES:BX)     |

(Uplevel access from a nested procedure to an enclosing procedure's locals or
parameters is **not supported** — it is rejected at compile time. A nested
procedure may read/write only module globals, imports, and its own locals
and parameters.)

### Codegen rules derived from large model

1. **VAR parameter actual argument**: push `{segment, offset}` as 4 bytes.
   - Local var → `PUSH SS; PUSH AX`
   - Global var → `PUSH DS; PUSH AX`

2. **Array element access in data segment**: use `MOV DX,DS; MOV ES,DX` to set ES=DS
   before accessing via the `ES:[BX]` convention.  **Do not assume ES=DS.**

3. **Memory access through ADDRESS**: use `POINTER TO T` and pointer dereference (`p^`).
   Assign an `ADDRESS` value to a typed pointer variable; then `p^` reads/writes through it.
   `SYSTEM.GET` and `SYSTEM.PUT` have been **removed** — they are not part of this dialect.

4. **`SYSTEM.MOVE(src, dst: ADDRESS; n: INTEGER)` / `SYSTEM.FILL(dst: ADDRESS; n: INTEGER; b: BYTE)`**:
   Implemented as INLINE procedures in `SYSTEM.MOD` (POP-based value mode).
   Caller pushes actual argument values via `parse_actual_params`; the inline byte
   pattern POPs them into registers and runs `REP MOVSB` / `REP STOSB`.
   `MOVE`: POPs n→CX, dst_ofs→DI, dst_seg→ES, src_ofs→SI, src_seg→AX;
   then `PUSH DS; MOV DS,AX; CLD; REP MOVSB; POP DS` — DS restored.
   `FILL`: POPs b→AX, n→CX, dst_ofs→DI, dst_seg→ES; then `CLD; REP STOSB`.
   SP is balanced (all pushed values consumed by POPs).  Both accept any segment
   (heap, stack, data).  No C-side codegen — no `SP_MOVE`/`SP_FILL` constants.

5. **`SYSTEM.SEG(v)`**: returns SS for locals, DS for globals.

6. **`SYSTEM_INIT`** (in SYSTEM.ASM): sets DS via a SEGRELOC-patched paragraph
   constant (`mov ax, seg segd_mark; mov ds, ax`).  This runs at program entry
   before any Oberon module body executes — after `SYSTEM_INIT` returns, DS is
   valid for all modules.

7. **Module `__init` guards**: the guard word is in CS (code segment) and accessed
   with a `CS:` override prefix (`2E`) + RELOC.  This avoids touching DS/SS
   before `SYSTEM_INIT` has set them up.

8. **Stack-based FPU temporaries**: `cg_fpush`/`cg_fpop` use SS-relative SP
   (`MOV BX,SP` then SS: prefix) because DS ≠ SS and the stack is in SS.

---

## Type sizes  (COMPLETE — do not deviate)

| Type      | Size | Align | Notes                                                  |
|-----------|------|-------|--------------------------------------------------------|
| BOOLEAN   | 1    | 1     | 0=FALSE, 1=TRUE                                        |
| CHAR      | 1    | 1     | ASCII                                                  |
| BYTE      | 1    | 1     | unsigned 0..255                                        |
| INTEGER   | 2    | 2     | signed −32768..32767                                   |
| WORD      | 2    | 2     | unsigned 0..65535; same size as INTEGER, unsigned ops  |
| LONGINT   | 4    | 2     | signed −2147483648..2147483647; DX:AX pair             |
| REAL      | 4    | 2     | IEEE 754 single precision; FPU ST(0)                   |
| LONGREAL  | 8    | 2     | IEEE 754 double precision; FPU ST(0)                   |
| SET       | 2    | 2     | elements 0..15 (one word)                              |
| POINTER   | 4    | 2     | FAR: {offset:word, segment:word}, offset first         |
| PROC ptr (FAR)  | 4 | 2 | FAR proc variable: {offset:word, segment:word}         |
| PROC ptr (NEAR) | 2 | 2 | NEAR proc variable: {offset:word} only                 |

`SZ_WORD=2`, `SZ_POINTER=4`, `SZ_LONGINT=4`, `SZ_REAL=4`, `SZ_LONGREAL=8`, `SZ_SET=2` in `symbols.h`.
NIL = 0000:0000 (both words zero).

**TF_ form constants** (symbols.h):
```
TF_INTEGER=0  TF_BOOLEAN=1  TF_CHAR=2   TF_BYTE=3   TF_SET=4
TF_NILTYPE=5  TF_NOTYPE=6   TF_ARRAY=7  TF_RECORD=8 TF_POINTER=9
TF_PROC=10    TF_ADDRESS=11 TF_LONGINT=12 TF_WORD=13
TF_REAL=14    /* 32-bit float; FPU FLD/FSTP dword */
TF_LONGREAL=15/* 64-bit float; FPU FLD/FSTP qword */
```

Note: TF_ADDRESS=11 is SYSTEM.ADDRESS (4-byte far pointer, compatible with any POINTER or LONGINT).
TF_WORD=13: 16-bit unsigned integer; same storage as INTEGER but unsigned arithmetic and comparisons.

**CRITICAL — token vs type-form constants must never be mixed:**
`T_xxx` in `scanner.h` are TOKEN constants; `TF_xxx` in `symbols.h` are TYPE FORM constants.
`T_ARRAY=50`, `TF_ARRAY=7`; `T_RECORD=73`, `TF_RECORD=8`; `T_POINTER=71`, `TF_POINTER=9` — completely different numbers.

**Multi-dimensional array syntax:** `ARRAY m, n OF T` is parsed and automatically desugared
to `ARRAY m OF ARRAY n OF T` (nested arrays). Up to 7 dimensions supported. The resulting
type tree is identical to the manually-written nested form — same ABI, same codegen.

---

## Calling convention: Pascal (callee cleans)  ← CRITICAL

**Argument push order:** LEFT TO RIGHT — first param pushed first, lands deepest.

There are two calling conventions depending on the procedure's `is_far` flag:

### NEAR procedure (`is_far=0`)

NEAR call (`E8 rel16`) pushes only a 2-byte return IP. Stack layout:
```
[BP + 0]              saved BP
[BP + 2]              return IP (2 bytes — NEAR return address only)
[BP + 4]              last param (pushed last = topmost)
[BP + 4 + ...]        first param (pushed first = deepest)
[BP - 2]              first local variable
```

Epilogue: `RET` (C3) or `RET N` (C2 nn nn) — pops IP only.

### FAR procedure (`is_far=1`)

FAR call (`0E PUSH CS + E8 rel16` for intra-module, or `9A` inter-module) pushes 4-byte return address (IP:CS). Stack layout:
```
[BP + 0]              saved BP
[BP + 2]              return IP (2 bytes)
[BP + 4]              return CS (2 bytes)
[BP + 6]              last param (pushed last = topmost)
[BP + 6 + ...]        first param (pushed first = deepest)
[BP - 2]              first local variable
```

Epilogue: `RETF` (CB) or `RETF N` (CA nn nn) — pops IP then CS.

### Nested procedure frame layout

Nested PROCEDUREs are syntactically allowed but cannot access an enclosing
procedure's locals or parameters (compile-time rejection — see Visibility
section above).  A nested procedure therefore compiles to the same frame
layout as a module-level procedure of the same calling convention; no
hidden static-link slot is reserved.

Summary table:

| Convention | Return addr               | Params start |
|------------|---------------------------|--------------|
| NEAR       | `[BP+2]` IP               | `[BP+4]`     |
| FAR        | `[BP+2]` IP + `[BP+4]` CS | `[BP+6]`     |

The formula in `type_calc_arg_size()`:
```c
ofs = (pt->is_far ? 6 : 4) + total;
```

For 4-byte params (POINTER, VAR param address): offset word at `[BP+n]`, segment at `[BP+n+2]`.
`LES BX, [BP+4]` loads offset→BX, segment→ES correctly (NEAR proc, no SL).

**VAR param address encoding (large model):**  Caller pushes `{segment, offset}` = 4 bytes.
- Local var actual: `PUSH SS; PUSH AX`  (SS = stack segment)
- Global var actual: `PUSH DS; PUSH AX`  (DS = data segment)
**Never** push SS for a global var — DS ≠ SS in the large model.

**Prologue** (always 7 bytes, same for NEAR and FAR):
```asm
55          PUSH BP
8B EC       MOV  BP, SP
81 EC ww ww SUB  SP, imm16   ; 4-byte form even if localSize=0; never SUB SP,0
```

**NEAR epilogue:**
```asm
8B E5       MOV  SP, BP
5D          POP  BP
C2 nn nn    RET  imm16    ; callee-cleans (argBytes > 0)
C3          RET            ; no args
```

**FAR epilogue:**
```asm
8B E5       MOV  SP, BP
5D          POP  BP
CA nn nn    RETF imm16    ; callee-cleans (argBytes > 0)
CB          RETF           ; no args
```

**`EmitCleanArgs` does NOT exist** — caller emits NOTHING after a CALL.

**Return values:**
- Scalar (BOOLEAN/CHAR/BYTE/INTEGER/SET) → AX
- LONGINT → DX:AX (lo word in AX, hi word in DX)
- FAR POINTER / FAR PROC ptr → DX:AX (offset in AX, segment in DX)
- NEAR PROC ptr → AX only (offset; same code segment assumed)
- **Arrays / records may NOT be returned** — a result type must be scalar, pointer,
  or procedure.  `Parser.CheckResultType` rejects an array/record result type with
  a fatal error (they can't fit in DX:AX and there is no hidden-result-pointer ABI).

**By-value aggregate parameters (record / fixed array):**
- The **caller copies the whole aggregate onto the stack**, rounded UP to an even
  byte count (2-byte aligned).  `Cgen.CgPushAggrValue(evenSize)` reserves the slot
  (`SUB SP, evenSize`), then `REP MOVSB`s the source into it; the callee reads the
  copy in place at `[BP+ofs]`.  `Syms.ParamSlotSize` reserves the same even SIZE so
  the callee's Pascal `RET imm16` cleanup stays balanced.
- An **open array** (`ARRAY OF …`) is different: always passed by reference as a
  6-byte slot `{ofs:2, seg:2, LEN:2}` — never copied — for both VAR and non-VAR.
- This applies recursively/everywhere (records with array fields, arrays of
  records, odd-sized records); see the PASSREC/PASSARR/PASSOPEN test fixtures.

**Callee-saved:** BP, SI, DI  
**Scratch:** AX, BX, CX, DX, ES

---

## Open-array parameters  ← CRITICAL ABI

An `ARRAY OF T` formal (with no fixed length, i.e. `type->len = -1`) is an
**open-array parameter**.  It occupies **6 bytes** on the stack:

```
[BP+adr+0]  offset word   } far pointer to first element
[BP+adr+2]  segment word  }   (LES BX,[BP+adr] loads it)
[BP+adr+4]  LEN word      hidden length parameter
```

**Caller push order** (Pascal left-to-right; first pushed = deepest = highest BP offset):

```asm
; actual arg is an array; LEN=N, far ptr = SEG:OFS
PUSH N        ; LEN  (pushed first → [BP+adr+4])
PUSH SEG      ; segment word  → [BP+adr+2]
PUSH OFS      ; offset word   → [BP+adr+0]
```

**Cases for the actual argument:**

| Actual arg kind | LEN | Segment pushed | Offset pushed |
|-----------------|-----|----------------|---------------|
| Global fixed array | compile-time `type->len` | `PUSH DS` | `LEA AX,[data_ofs]+RELOC; PUSH AX` |
| Local fixed array | compile-time `type->len` | `PUSH SS` | `LEA AX,[BP+adr]; PUSH AX` |
| Open-array formal forwarded | `MOV AX,[BP+adr+4]; PUSH AX` | `MOV AX,[BP+adr+2]; PUSH AX` | `MOV AX,[BP+adr]; PUSH AX` |

**`LEN(arr)` in callee** (arr is an open-array formal):
```asm
MOV AX, [BP+adr+4]   ; read hidden LEN word
```

**`LEN(arr)` for fixed-size array**: a compile-time `WORD` **constant**
(`M_CONST` item, no code emitted).  Usable in any constant-expression
context — `CONST` declarations, `ARRAY` dimensions, `CASE` labels:

```oberon
VAR src: ARRAY 16 OF INTEGER;
CONST N  = LEN(src);                      (* 16 *)
TYPE  Buf = ARRAY LEN(src) OF INTEGER;    (* 16 elems *)
VAR sel: INTEGER;
BEGIN
  CASE sel OF
    LEN(src):  (* 16 *) ...
  END
END
```

**Return type of LEN:** `WORD` (unsigned 16-bit), not `INTEGER`.  Array lengths are
non-negative and can reach 65535 elements without surprise sign-flip when assigned to
a `WORD`-typed accumulator.  Use `INTEGER(LEN(a))` if you need signed semantics, or
`LONGINT(LEN(a))` for 32-bit arithmetic.

### `SIZE(T)` — byte size of a type

`SIZE(T)` returns the byte size of type `T` as a compile-time `WORD` constant.
The argument is a type **name** (possibly qualified `Alias.Type`), not a variable
or value.  Accepted: every predeclared scalar (`INTEGER`/`BYTE`/`CHAR`/`BOOLEAN`/`SET`/`WORD`/
`LONGINT`/`REAL`/`LONGREAL`) and any user-defined `RECORD`/`ARRAY`/`POINTER`.

| Type | `SIZE` |
|------|--------|
| `BYTE`, `BOOLEAN`, `CHAR` | 1 |
| `INTEGER`, `WORD`, `SET` | 2 |
| `LONGINT`, `REAL`, `POINTER TO T` | 4 |
| `LONGREAL` | 8 |
| `RECORD { f1: T1; f2: T2; ... }` | sum of field sizes with 2-byte alignment for fields whose type is ≥ 2 bytes |
| `ARRAY N OF T` | `N * SIZE(T)` |

Because `SIZE(T)` is a constant expression of type `WORD`, it may appear anywhere a
constant is required — `CONST`, `ARRAY <dim> OF T`, and `CASE` labels.  The compiler
errors out if the identifier is undeclared or denotes a non-type (variable/constant).

```oberon
TYPE Pt = RECORD x, y: INTEGER END;
CONST PtSize = SIZE(Pt);                  (* = 4 *)
TYPE Buf = ARRAY SIZE(Pt) OF INTEGER;     (* 4 elems *)
VAR sel: INTEGER;
BEGIN
  CASE sel OF
    SIZE(BYTE):    (* 1 *) ...
  | SIZE(INTEGER): (* 2 *) ...
  | SIZE(Pt):      (* 4 *) ...
  END
END
```

### CONST declarations are integer-only  ← DEVIATION from Oberon-07

A `CONST` value must be an **INTEGER-family** compile-time value: `INTEGER`,
`LONGINT`, `WORD`, or `BYTE`.  `CHAR`, `BOOLEAN`, `REAL`, `LONGREAL`, `SET`, and
string / array / record / pointer constants are **rejected** with
`CONST must be an integer (INTEGER/LONGINT/WORD/BYTE) value`.  Use a literal at
the use site instead (e.g. write `09X` inline rather than `CONST Tab = 09X`, or
pass `"_t.DEF"` directly to the file call rather than naming it as a CONST).
Enforced in `Parser.ParseConstDecl` by checking `val.type^.form`.  Standard
Oberon-07 permits CHAR/BOOLEAN/REAL/string constants; this compiler does not.

### Function result may be discarded as a statement  ← DEVIATION from Oberon-07

A call to a **function procedure** (one declared with a result type) may be used
as a **statement**, discarding the returned value.  Standard Oberon-07 forbids
this — a function procedure may appear only inside an expression, and a value
must be consumed.  This compiler accepts the call-as-statement form.

Used throughout the toolchain: e.g. `Files.Write(f, s)` and `Files.WriteLine(f, s)`
return a WORD (bytes written) that callers routinely ignore, so writing them as
plain statements avoids a throwaway `VAR w: WORD; w := ...` at every call site.
The value is computed and dropped; there is no `void`-cast syntax and none is
needed.

### Constant folding and imported constants

- Constant folding is performed at compile time for constant expressions used in CONST declarations, array dimension expressions (`ARRAY N OF T`), and CASE label values. Supported operators include `+`, `-`, `*`, `DIV`, and `MOD` with Oberon-07 floor-division semantics.
- Qualified imported constants (Alias.Const) loaded from `.def` files are treated as compile-time constants and participate in constant folding. Examples: `CONST C = I.N + 1;`, `VAR a: ARRAY I.N OF INTEGER;`, and `CASE I.N OF ...` — all are accepted and folded when `I` is an imported module.
- Non-integer constants used where an integer constant is required (e.g., array dimension) produce a compile-time error.
- Large integer results are promoted to `LONGINT` when they exceed 16-bit range; folded values carry appropriate type (`INTEGER` or `LONGINT`).


**Array element access** (`arr[i]`):
- Open-array formal: `LES BX,[BP+adr]` loads far ptr; then `ADD BX, AX` (index×elemsize).
- Global fixed array: `LEA AX,[data_ofs]; MOV ES,DS; MOV BX,AX` then `ADD BX, AX`.
- Local fixed array: `LEA AX,[BP+adr]; MOV ES,SS; MOV BX,AX` then `ADD BX, AX`.
- All element accesses then use `ES:[BX]` convention (M_REG, is_ref=1).

**`param_slot_size` in symbols.c:**
- `K_VARPARAM` → 4 bytes (far ptr: offset+segment)
- non-VAR open-array → **6 bytes** (far ptr + LEN)
- other non-VAR → `max(type->size, 2)`

---

## Boolean NOT (~) operator

`~expr` negates a BOOLEAN expression. Syntax: `"~" factor` (unary prefix).

**Codegen:** `cg_bool_not()` — emits `XOR AX, 1` (opcode `83 F0 01`).
- Operand must be loaded into AX first (`cg_load_item`).
- Result: 0 (FALSE) ↔ 1 (TRUE) in AX. Result type = BOOLEAN, mode = M_REG.

```asm
; ~b where b is a BOOLEAN variable
MOV AX, [BP+adr]   ; load b into AX
XOR AX, 1          ; flip lowest bit: 0↔1
```

**Usage patterns:**
```oberon
IF ~condition THEN ... END          (* negate condition *)
WHILE ~done DO ... END              (* loop while not done *)
c := ~a & b                        (* combine with & *)
c := ~(a OR b)                     (* negate compound expr *)
```

**Double negation:** `~~b` emits two `XOR AX,1` — result equals `b`.

---

## LONGINT (signed 32-bit integer)

**Register pair:** DX (high word) : AX (low word). Memory: lo-word at `[ofs]`, hi-word at `[ofs+2]`.

**Type-cast expressions** (parse_factor handles K_TYPE with castable form):
- `INTEGER(x)` — truncate to low 16 bits; just use AX. Result type = INTEGER.
- `BYTE(x)` — `AND AX, 00FFh` after loading. Result type = BYTE.
- `LONGINT(x)` — if source is already LONGINT: no-op. **Unsigned sources
  (WORD/BYTE/CHAR/BOOLEAN) zero-extend** (`XOR DX,DX`); only signed `INTEGER`
  sign-extends (`CWD`).  This matters: a WORD value ≥ 32768 (e.g. a 37 KB code
  group length, `LEN`/`SIZE` result) must NOT be sign-extended — doing so makes
  it read as a large negative LONGINT and corrupts any later 32-bit arithmetic.
  The same zero-vs-sign rule applies wherever a narrow value is widened to
  LONGINT: explicit `LONGINT()` cast, implicit widening in a mixed
  WORD/LONGINT binary expression, and actual-parameter promotion to a LONGINT
  formal.  (Fixed 2026-06-19; the prior code sign-extended WORD via `CWD`.)

**Widening assignment** (type_assign_compat): INTEGER and BYTE can be assigned to LONGINT (implicit `CWD` on store; WORD zero-extends).

**Arithmetic:**

| Operation | Code generated |
|-----------|---------------|
| `a + b`   | `ADD AX, BX` / `ADC DX, CX` (cg_add32) |
| `a - b`   | XCHG AX↔BX, XCHG DX↔CX, `SUB AX,BX` / `SBB DX,CX` (cg_sub32) |
| `-a`      | `NOT AX` / `NOT DX` / `ADD AX,1` / `ADC DX,0` (cg_neg32) |
| `INC(a)`  | `ADD AX,1` / `ADC DX,0` (carry into DX must be preserved) |
| `DEC(a)`  | `SUB AX,1` / `SBB DX,0` (borrow from DX must be preserved) |
| `a * b`   | FAR call `SYSTEM_S32MUL` from SYSTEM (lazy RDOFF import) |
| `a DIV b` | FAR call `SYSTEM_S32DIV` from SYSTEM |
| `a MOD b` | FAR call `SYSTEM_S32MOD` from SYSTEM |

**Stack convention for SYSTEM_S32MUL/SYSTEM_S32DIV/SYSTEM_S32MOD** (Pascal calling, RETF 8):
```
Caller pushes: PUSH DX(lhs_hi) PUSH AX(lhs_lo) PUSH DX(rhs_hi) PUSH AX(rhs_lo)
Callee sees:   [BP+12]=lhs_hi [BP+10]=lhs_lo [BP+8]=rhs_hi [BP+6]=rhs_lo
Result returned in DX:AX.
```

**Comparison (parse_expr → cg_cmp32_bool or cg_cmp32_eq/neq):**

Two-stage: compare hi words (CX vs DX, signed); if unequal → use JL/JG result; if equal → compare lo words (BX vs AX, unsigned JB/JA/JBE/JAE).

```
CMP CX, DX           ; hi-word signed compare
Jhi_true → .true     ; e.g. JL for LSS
Jhi_false → .false   ; e.g. JG for LSS
CMP BX, AX           ; lo-word unsigned compare
Jlo_true → .true     ; e.g. JB for LSS
.false: XOR AX,AX; JMP .end
.true:  MOV AX, 1
.end:
```

For `=` and `#`: XOR hi-words, XOR lo-words, OR together, then JZ/JNZ.

**LONGINT parameters:**

Pushed as 4 bytes: `PUSH DX` (hi) then `PUSH AX` (lo). `type_calc_arg_size` uses `sz=4` (SZ_LONGINT).

**VAR LONGINT parameters:**

Passed as 4-byte far address (same as any VAR param). Load/store uses `cg_load_long_bp(ofs)` / `cg_store_long_bp(ofs)`.

**codegen.h helpers:**
```c
cg_load_long_bp(ofs)    /* DX:AX = [BP+ofs+2]:[BP+ofs] */
cg_store_long_bp(ofs)   /* [BP+ofs]=AX, [BP+ofs+2]=DX */
cg_load_long_mem(ofs)   /* from DS:[ofs] and DS:[ofs+2] */
cg_store_long_mem(ofs)  /* DS:[ofs]=AX, DS:[ofs+2]=DX */
cg_load_long_imm(val)   /* AX=lo16, DX=hi16 */
cg_add32()   cg_sub32()   cg_neg32()
cg_and32()   cg_or32()    cg_xor32()
cg_push_dxax()   cg_pop_cxbx()
cg_cmp32_bool(hi_true_jcc, hi_false_jcc, lo_true_jcc)
cg_cmp32_eq()   cg_cmp32_neq()
```

**Lazy SYSTEM imports for arithmetic** (resolved via `PExpr.GetSystemImport`):
```
GetSystemImport("SYSTEM_S32MUL")
GetSystemImport("SYSTEM_S32DIV")
GetSystemImport("SYSTEM_S32MOD")
```

---

## WORD (unsigned 16-bit integer)

`WORD` is a 16-bit unsigned integer type (0..65535).  Same storage size as `INTEGER` but uses
unsigned arithmetic and unsigned comparisons.  `TF_WORD=13`, `SZ_WORD=2`, `SP_TOWORD=31`.

### Type cast

```oberon
w := WORD(x)    (* reinterpret low 16 bits as unsigned; no extra codegen *)
i := INTEGER(w) (* bit-reinterpret; values > 32767 become negative *)
```

Constant fold: `WORD(0FFFFH) = 65535`, `WORD(-1) = 65535`.
At runtime: AX is already 16-bit, so the cast emits no instructions for INTEGER/WORD source.
REAL/LONGREAL source: `CgFistAx()` (FISTP word) then reinterpret.

### "WORD wins" rule for mixed expressions

| LHS type  | RHS type  | Result type | Ops used |
|-----------|-----------|-------------|----------|
| WORD      | WORD      | WORD        | unsigned |
| WORD      | INTEGER   | WORD        | unsigned |
| INTEGER   | WORD      | WORD        | unsigned |
| LONGINT   | WORD      | LONGINT     | signed   |
| WORD      | LONGINT   | LONGINT     | signed   |

LONGINT always wins over WORD.  WORD always wins over INTEGER.

### Arithmetic

| Operation | Code generated |
|-----------|---------------|
| `a * b`   | `MUL CX` (F7 E1) — unsigned 16×16→16 in AX |
| `a DIV b` | `XCHG AX,CX; XOR DX,DX; DIV CX` (87 C1, 31 D2, F7 F1) |
| `a MOD b` | same as DIV, then `MOV AX, DX` (8B C2) |
| `a + b`   | `ADD AX, CX` — same encoding as INTEGER |
| `a - b`   | `SUB AX, CX` — same encoding as INTEGER |

Overflow wraps silently (unsigned 16-bit modular arithmetic).

Helpers: `Cgen.CgMulU()`, `Cgen.CgDivU()`, `Cgen.CgModU()`.

### Comparisons

When either operand of a 16-bit comparison (`=`, `#`, `<`, `<=`, `>`, `>=`) is WORD,
unsigned jump opcodes are used instead of signed:

| Operator | Signed (INTEGER) | Unsigned (WORD) |
|----------|-----------------|-----------------|
| `<`      | JL (7C)         | JB  (72)        |
| `<=`     | JLE (7E)        | JBE (76)        |
| `>`      | JG (7F)         | JA  (77)        |
| `>=`     | JGE (7D)        | JAE (73)        |
| `=`      | JZ (74)         | JZ  (74)        |
| `#`      | JNZ (75)        | JNZ (75)        |

Helper: `PExpr.RelopJccU(op)`.

### Constant folding

WORD constant folding uses unsigned arithmetic: operand values masked to `0..65535`,
result wrapped with `AND result, 0FFFFH`.  Result type = `TypeWord`.
Unsigned DIV/MOD use natural (floor) division since both operands are non-negative.

### Assignment compatibility

```
BYTE  → WORD   : allowed (zero-extend)
INTEGER → WORD : allowed (bit-reinterpret)
WORD → INTEGER : allowed (bit-reinterpret)
WORD → LONGINT : allowed (zero-extend)
```

---

## FPU types: REAL, LONGREAL  ← CRITICAL

### Prerequisites

Any module that declares or uses `REAL` or `LONGREAL` requires an x87 FPU
(8087/80287/80387 coprocessor or integrated FPU).  The compiler **detects FPU type usage**
during parsing and sets a module-level flag `mod_uses_fpu`.  When this flag is set the
`__init` function emits a FAR call to `SYSTEM_REQUIRE87` immediately after the guard
INC and before any dependency `__init` calls.

```asm
; __init with FPU types used — layout:
[guard_ofs]   DW 0
              CS: CMP [guard], 0
              JE .cont
              RETF
; .cont:
              CS: INC [guard]
              CALL FAR SYSTEM_REQUIRE87   ← only when mod_uses_fpu
              CALL FAR Dep1__init
              ; ... module body ...
              RETF
```

`SYSTEM_REQUIRE87` checks for the presence of a real 8087/287/387 coprocessor using
the standard DOS detection sequence.  If no FPU is found it prints an error message and
terminates the process with exit code 87.  It is provided by `SYSTEM.RDF` and exported as a GLOBAL.

The RDOFF import for `SYSTEM_REQUIRE87` is created lazily the same way as other SYSTEM
imports — via `PExpr.GetSystemImport("SYSTEM_REQUIRE87")`.

**`modUsesFpu` flag** (`PEXPR.MOD` module-level VAR):  set to TRUE the first time
the parser encounters `TFReal` or `TFLongreal` in any type position (variable
declaration, parameter, record field) or a `TReal` literal in an expression.
Reset to FALSE at the start of each module compilation.

---

### FPU register model

The x87 FPU has an 8-level stack: `ST(0)` is the top.  All arithmetic operates on
`ST(0)` (and `ST(1)` for binary ops).  The compiler uses a **strict stack discipline**:
every expression leaves exactly one value on the FPU stack; every statement that uses
an FPU value pops it.

**Value in FPU register for Item:** `item->mode = M_FREG` (mode constant 7).
`M_FREG` means the value is on top of the FPU stack (`ST(0)`).

```c
#define M_FREG  7   /* value in FPU ST(0) */
```

The integer CPU registers (AX, DX, etc.) are **not** used for REAL/LONGREAL
values except as memory address operands.

---

### Memory layout

| Type     | Memory layout                    | FPU load/store instructions      |
|----------|----------------------------------|----------------------------------|
| REAL     | 4 bytes, IEEE 754 single (dword) | `FLD dword [addr]` / `FSTP dword [addr]` |
| LONGREAL | 8 bytes, IEEE 754 double (qword) | `FLD qword [addr]` / `FSTP qword [addr]` |

Both types must be stored in **memory** (stack frame or data segment) — never in
CPU registers.  The FPU stack is only used as a transient during expression evaluation.

For local variables: allocated by `sym_alloc_local` with their full size (4 or 8 bytes),
word-aligned.

---

### Load / store codegen

#### Local variable (stack frame, BP-relative)

```asm
; REAL load:     FLD  dword ptr [BP + ofs]  — D9 45 ofs8  or  D9 85 ofs16
; REAL store:    FSTP dword ptr [BP + ofs]  — D9 5D ofs8  or  D9 9D ofs16
; LONGREAL load: FLD  qword ptr [BP + ofs]  — DD 45 ofs8  or  DD 85 ofs16
; LONGREAL store:FSTP qword ptr [BP + ofs]  — DD 5D ofs8  or  DD 9D ofs16
```

Encoding: `D9`=FLD/FSTP float dword, `DD`=FLD/FSTP double qword.
ModRM for `[BP + disp8]`: `45 ofs8`. For `[BP + disp16]`: `85 ofs16` (little-endian).

`codegen.h` helpers:
```c
void cg_fld_real_bp(int32_t ofs);       /* FLD  dword [BP+ofs] */
void cg_fstp_real_bp(int32_t ofs);      /* FSTP dword [BP+ofs] */
void cg_fld_longreal_bp(int32_t ofs);   /* FLD  qword [BP+ofs] */
void cg_fstp_longreal_bp(int32_t ofs);  /* FSTP qword [BP+ofs] */
```

#### Global variable (data segment, DS-relative)

Same opcodes with ModRM `05 lo hi` for `[disp16]` plus a DATA RELOC record:
```c
void cg_fld_real_mem(uint16_t ofs);      /* FLD  dword [DS:ofs] */
void cg_fstp_real_mem(uint16_t ofs);     /* FSTP dword [DS:ofs] */
void cg_fld_longreal_mem(uint16_t ofs);  /* FLD  qword [DS:ofs] */
void cg_fstp_longreal_mem(uint16_t ofs); /* FSTP qword [DS:ofs] */
```

#### REAL/LONGREAL literal constants

Floating-point literals are stored as raw bytes in the **data segment** at parse time.
There is no FPU "load immediate" instruction.

- `T_REAL` literal → 4 bytes (IEEE 754 single) emitted via `cg_emit_data_byte` × 4
- LONGREAL literal → 8 bytes (IEEE 754 double) emitted via `cg_emit_data_byte` × 8
- `item->adr` = data segment offset of the constant
- `item->mode = M_CONST`; loaded by `cg_fld_real_const(item->adr)` or `cg_fld_longreal_const`

```c
void cg_fld_real_const(uint16_t data_ofs);      /* FLD dword [CS:data_ofs] */
void cg_fld_longreal_const(uint16_t data_ofs);  /* FLD qword [CS:data_ofs] */
```

**Important:** the current scanner always produces `T_REAL` tokens for any floating-point
literal. The compiler determines REAL vs LONGREAL by context (variable type), NOT by
any `L` suffix. All float literals are initially stored as 4-byte REAL unless the
assignment/parameter context requires LONGREAL (then 8 bytes are emitted).

---

### Arithmetic codegen

The compiler uses `cg_fpush` / `cg_fpop` to manage operand order:

```
1. Evaluate LHS → ST(0)  [M_FREG]
2. cg_fpush()            ; SUB SP,8; FSTP qword SS:[BX] — saves LHS from ST(0) to CPU stack
3. Evaluate RHS → ST(0)  [M_FREG]
4. cg_fpop()             ; FLD qword SS:[BX]; ADD SP,8 — pushes LHS back onto FPU stack
   ; After fpop: ST(0)=LHS, ST(1)=RHS
5. Emit FPU binary op    ; result in ST(0), both ST(0) and ST(1) consumed
```

The critical point: after step 4, **ST(0)=LHS and ST(1)=RHS**.

`FSUBP ST(1),ST` computes `ST(1) - ST(0) = RHS - LHS` — **wrong**.
`FSUBRP ST(1),ST` computes `ST(0) - ST(1) = LHS - RHS` — **correct**.

Similarly for division: `FDIVRP ST(1),ST` = `ST(0)/ST(1) = LHS/RHS`.

**Implemented opcodes (ST(0)=LHS, ST(1)=RHS after fpush/fpop):**

| Operation | Opcode bytes  | Mnemonic              | Result         |
|-----------|---------------|-----------------------|----------------|
| `a + b`   | `DE C1`       | `FADDP  ST(1),ST`     | ST(1)+ST(0)=LHS+RHS ✓ (commutative) |
| `a - b`   | `DE E1`       | `FSUBRP ST(1),ST`     | ST(0)-ST(1)=LHS-RHS ✓ |
| `a * b`   | `DE C9`       | `FMULP  ST(1),ST`     | ST(1)*ST(0)=LHS*RHS ✓ (commutative) |
| `a / b`   | `DE F1`       | `FDIVRP ST(1),ST`     | ST(0)/ST(1)=LHS/RHS ✓ |
| `-a`      | `D9 E0`       | `FCHS`                | negate ST(0) |
| `ABS(a)`  | `D9 E1`       | `FABS`                | \|ST(0)\| |

**SS: prefix required for FPU memory operands via BX** (8086 cannot use SP as memory base):
```asm
; cg_fpush:
SUB SP, 8        ; 83 EC 08 — allocate 8 bytes
MOV BX, SP       ; 89 E3
SS: FSTP qword [BX]   ; 36 DD 1F — store ST(0) to CPU stack, pop FPU

; cg_fpop:
MOV BX, SP       ; 89 E3
SS: FLD qword [BX]    ; 36 DD 07 — load from CPU stack → pushes onto FPU
ADD SP, 8        ; 83 C4 08
```

---

### Comparison codegen

After `cg_fpush` + evaluate RHS + `cg_fpop`: ST(0)=LHS, ST(1)=RHS.
FPU comparison uses `FCOMPP` + `FNSTSW AX` + `SAHF`.

```asm
; After fpush+rhs+fpop: ST(0)=LHS, ST(1)=RHS
FCOMPP          ; DE D9 — compare ST(0) with ST(1), pop both
                ;   C0=1 if ST(0) < ST(1), i.e. LHS < RHS
FNSTSW AX       ; DF E0 — store FPU status word into AX (no WAIT)
SAHF            ; 9E    — load AH into flags: CF=C0, ZF=C3, PF=C2
```

After `SAHF`, the x86 flags reflect the comparison of LHS vs RHS:
- `CF=1` → LHS < RHS (C0=1)
- `ZF=1` → LHS = RHS (C3=1)
- `CF=0, ZF=0` → LHS > RHS

Mapping to Oberon comparison operators (`PExpr.FrelopJcc`):

| Operator | Opcode | Jump name | Condition after SAHF |
|----------|--------|-----------|----------------------|
| `=`      | 74     | JZ        | ZF=1                 |
| `#`      | 75     | JNZ       | ZF=0                 |
| `<`      | 72     | JB        | CF=1                 |
| `<=`     | 76     | JBE       | CF=1 or ZF=1         |
| `>`      | 77     | JA        | CF=0 and ZF=0        |
| `>=`     | 73     | JAE       | CF=0                 |

The standard `cg_setcc(jcc_opcode)` helper works unchanged after `SAHF`.

**FCOMPP opcode: `DE D9`** (not `D9 D9` which is `FLDL2T`).

**Full comparison sequence for `a < b`:**
```asm
; After fpush+eval_b+fpop: ST(0)=a, ST(1)=b (but we compare a<b)
; Correction: standard flow is cg_fpush saves a; then b evaluated;
; cg_fpop restores a → ST(0)=a=LHS, ST(1)=b=RHS
FCOMPP          ; DE D9 — compare ST(0) [LHS/a] with ST(1) [RHS/b], pop both
                ; C0=1 if a < b → CF=1 after SAHF
FNSTSW AX       ; DF E0
SAHF            ; 9E
; JB (72) = jump if a < b
```

---

### Type casts and conversions

All conversions via explicit cast syntax `REAL(x)`, `LONGREAL(x)`, `INTEGER(x)`, `LONGINT(x)`.
`FLOAT(x)` is accepted as a synonym for `REAL(x)`; `ENTIER(x)` is accepted as a synonym for `FLOOR(x)`.

**Integer → float** (result in ST(0), mode=M_FREG): push value to SS stack, FILD, restore SP:
```asm
; INTEGER → REAL or LONGREAL:
SUB SP, 2        ; 83 EC 02
MOV BX, SP       ; 89 E3
SS: MOV [BX], AX ; 36 89 07   — store AX (INTEGER value)
SS: FILD word [BX] ; 36 DF 07 — load as 16-bit signed int → ST(0)
ADD SP, 2        ; 83 C4 02

; LONGINT → REAL or LONGREAL (DX:AX → ST(0)):
SUB SP, 4        ; 83 EC 04
MOV BX, SP       ; 89 E3
SS: MOV [BX], AX   ; 36 89 07
SS: MOV [BX+2], DX ; 36 89 57 02
SS: FILD dword [BX] ; 36 DB 07
ADD SP, 4        ; 83 C4 04
```

| Cast | Code generated |
|------|----------------|
| `REAL(INTEGER)` | FILD word via SS stack → ST(0) |
| `REAL(LONGINT)` | FILD dword via SS stack → ST(0) |
| `LONGREAL(INTEGER)` | same as REAL(INTEGER) — FPU extended precision |
| `LONGREAL(LONGINT)` | same as REAL(LONGINT) |
| `LONGREAL(REAL)` | no-op (FPU operates in extended precision internally) |
| `REAL(LONGREAL)` | no-op (FPU extended → effectively REAL on store) |
| `INTEGER(REAL)` | `cg_fist_ax()`: FISTP word via SS stack → AX (truncate toward 0) |
| `INTEGER(LONGREAL)` | same as INTEGER(REAL) |
| `LONGINT(REAL)` | FISTP dword via SS stack → DX:AX |
| `LONGINT(LONGREAL)` | same |

**FLOOR(x) / ENTIER(x)** for REAL/LONGREAL → INTEGER:
Uses `cg_floor_ax()`: saves FPU control word, sets RC=01 (round toward −∞), FISTP word → AX, restores CW.

**Assignment compatibility:**
- `INTEGER → LONGINT`: implicit widening (CWD sign-extend)
- `WORD → INTEGER`: bit-reinterpret (same 16-bit storage; values > 32767 become negative INTEGER)
- `INTEGER → WORD`: bit-reinterpret (INTEGER(-1) = WORD(65535))
- `BYTE → WORD`: zero-extend
- `WORD → LONGINT`: implicit widening (zero-extend; WORD is unsigned so high word = 0)
- `LONGINT accepts INTEGER/BYTE/WORD` via `type_assign_compat`
- `REAL` and `LONGREAL`: assignment requires explicit cast (`REAL(i)`, `LONGREAL(i)`). In binary expressions (`*`, `/`, `+`, `-`, `=`, `#`, `<`, `>`, `<=`, `>=`) an integer operand (INTEGER, BYTE, LONGINT) is automatically coerced to REAL/LONGREAL via FILD when the other operand is a float type. Both orderings work: `r * n`, `n * r`, `r < 0`, `1 < r`.

---

### Calling convention for FPU types

FPU types are passed and returned differently from integer types:

**Passing REAL/LONGREAL parameters (caller):**  
Passed on the **CPU stack** as raw bytes via `FSTP` — the FPU stack is NOT used for
parameter passing (DOS/Pascal convention).

```asm
; Pass REAL argument (value currently in ST(0)):
SUB SP, 4        ; 83 EC 04 — allocate 4 bytes
MOV BX, SP       ; 89 E3
SS: FSTP dword [BX] ; 36 D9 1F — store float, pop ST(0)

; Pass LONGREAL argument (value currently in ST(0)):
SUB SP, 8        ; 83 EC 08
MOV BX, SP       ; 89 E3
SS: FSTP qword [BX] ; 36 DD 1F — store double, pop ST(0)
```

Memory layout on stack (Pascal order: left param deepest):
- REAL (4 bytes): `[BP+n]`=lo-word, `[BP+n+2]`=hi-word
- LONGREAL (8 bytes): 8 bytes at `[BP+n..BP+n+7]`

**Returning REAL/LONGREAL:**  
Returned in `ST(0)` of the FPU stack.  Caller receives M_FREG item; must store ST(0).

**`type_calc_arg_size`:** uses `sz = t->size` (4 or 8 bytes) for REAL/LONGREAL,
same as LONGINT uses sz=4.

---

### Module FPU requirement — SYSTEM_REQUIRE87

**Detection:** the parser sets `modUsesFpu := TRUE` the first time it sees `TFReal`
or `TFLongreal` in any context (variable declaration, parameter, record field,
or `TReal` literal in an expression).

**`modUsesFpu`** (`PEXPR.MOD` module-level VAR):
Reset to FALSE at the start of each module. Set wherever TFReal/TFLongreal is first encountered.

**Codegen in `PARSER.MOD` / `__init` generation:**  
After `CS: INC [guard]` and before any dep-`__init` FAR calls:

```oberon
IF PExpr.modUsesFpu THEN
  req87Id := PExpr.GetSystemImport("SYSTEM_REQUIRE87");
  Cgen.CgCallFar(req87Id)
END
```

This produces `9A oo oo ss ss` + RELOC + SEGRELOC pointing at `SYSTEM_REQUIRE87`.

`SYSTEM_REQUIRE87` is provided by `SYSTEM.RDF` (FAR, no args, no return value, Pascal).
It halts the program with an error message if no 8087-compatible FPU is detected.
It does not appear in `SYSTEM.DEF` (it is not a user-callable proc).

---

## Far pointer model  ← CRITICAL

All POINTER TO T and procedure-pointer variables are 4-byte far pointers.
VAR parameters also pass a 4-byte far address (seg:offset).

**Memory layout:** `[addr+0]` = offset (low word), `[addr+2]` = segment (high word).
`LES BX, [addr]` → BX = offset, ES = segment. ✓

| Situation | Registers |
|-----------|-----------|
| Far ptr as VALUE (DX:AX) | AX = offset, DX = segment |
| Far ptr for DEREFERENCE (ES:BX) | BX = offset, ES = segment |

Convert DX:AX → ES:BX: `MOV BX,AX` (8B D8) + `MOV ES,DX` (8E C2).

**Loading:**
```asm
; local  [BP+ofs]:  C4 5E ofs8  (LES BX,[BP+ofs])
; global [DS:adr]:  C4 1E lo hi +RELOC
```

**Dereference (read):** `26 8B 07` = MOV AX, ES:[BX]  
**Store through (write):** `26 89 07` = MOV ES:[BX], AX

**Pushing a far pointer:**
```asm
PUSH DX   ; segment first  → lands at [BP+n+2]
PUSH AX   ; offset  second → lands at [BP+n]
```

**VAR-parameter actual must be a variable (l-value).**  A `VAR` formal binds to
the caller's storage, so the actual argument must have an address: a local or
global variable, or a far-addressed element (pointer-deref / indexed element).
A **string literal, a constant (scalar or array), an expression, or a procedure
value is rejected** at compile time ("VAR parameter requires a variable …").
Passing a string literal to a `VAR ARRAY` formal used to be silently
miscompiled into a far reference with a bad length, which hung the compiler in
the INLINE name scan (`Strings.HashCode` / `Util.Eq` scanning `ES:[DI]`); it is
now a clean error.  See `PExpr.CheckParamCompat`.

**VAR parameter passing (caller):**
```asm
LEA AX, [BP+localOfs]    ; or MOV AX, imm16 for globals
PUSH DS                  ; segment = DS
PUSH AX                  ; offset
```

**VAR parameter store (callee):**
```asm
PUSH AX
LES BX, [BP+paramOfs]
POP AX
MOV ES:[BX], AX
```

**NIL comparison:** `OR AX, DX` → JZ = is NIL.  
**NIL check after LES:** `MOV AX,ES / OR AX,AX / JNZ ok / OR BX,BX / JNZ ok / call trap`

**Pointer equality `p = q` (or `p # q`):** BOTH segment (DX) and offset (AX) must be compared.
`SYSTEM_Alloc` returns `DX=segment, AX=0` (offset is always 0 for heap blocks). So comparing only
AX against NIL (AX=0) always equals! Use `cg_ptr_cmp_eq()`:
```
PUSH DX          ; push LHS segment
PUSH AX          ; push LHS offset
<load RHS>       ; RHS DX:AX (NIL = XOR AX,AX; XOR DX,DX)
POP CX           ; LHS offset
XOR AX, CX       ; 0 if offsets equal
POP BX           ; LHS segment
XOR DX, BX       ; 0 if segments equal
OR  AX, DX       ; 0 iff both equal → ZF=1
TEST AX, AX
```
Then `cg_setcc(OP_JZ)` for `=`, `cg_setcc(OP_JNZ)` for `#`.

**Note:** This comparison is correct for `NEW`-allocated pointers (where `SYSTEM_Alloc` returns
offset=0), and for NIL (0000:0000). For pointers constructed via `SYSTEM.PTR` or `SYSTEM.ADR`,
offset may be non-zero — but the two-word XOR+OR comparison handles those correctly too.

**CRITICAL:** When loading a `TF_NILTYPE` constant (NIL), `cg_load_item` MUST zero DX as well as AX.
The `is_ptr` check uses `TF_POINTER` which NIL's type is not — check `TF_NILTYPE` separately.

**Implicit pointer dereference (auto-deref):**  In a field or array selector, if the
current item's type is `POINTER TO T`, the compiler automatically dereferences the
pointer before applying the selector.  This means `p.f` is exactly equivalent to
`p^.f`, and `p[i]` is exactly equivalent to `p^[i]`.  The auto-deref is performed in
`PExpr.ParseDesignator` for both the `.` (TDot) and `[` (TLbrak) selector branches:
when `item.type^.form = TFPointer`, the compiler emits a far-ptr load (`CgLesBxBp` /
`CgLesBxMem`) and sets `item.isRef := TRUE` before continuing with the field/index
access.  Chained selectors (`p.a.b`, `p[i][j]`) work because the loop re-enters per
selector.

---

## Jump instructions  (CRITICAL — strict 8086)

8086 conditional jumps are SHORT ONLY (rel8, range -128..127). No `0F 8x` near Jcc.
Solution for long forward conditional jumps: INVERT condition + JMP near.

```
JNZ +3        ; 75 03 — skip the near jump (5 bytes total: inv_opcode 03 E9 lo hi)
JMP target    ; E9 rel16
```

Inversion: `opcode ^ 1` for all 0x70-0x7F Jcc.
`Cgen.InvertJcc(opcode)` helper.

| Helper | Use |
|--------|-----|
| `cg_cond_near` | ALL forward conditional jumps (emits 5 bytes) |
| `cg_cond_short` | Backward jumps only (WHILE/REPEAT/FOR back-edges) — ASSERT fits |
| `cg_jmp_near` | Forward unconditional (E9 rel16) |
| `cg_jmp_back` | Backward unconditional (chooses EB or E9 automatically) |

Patch forward jumps with `cg_patch_near` (not `cg_patch_short`).

---

## Naming convention  ← CRITICAL

All exported symbols: `ModuleName_SymbolName`

- `_` is **forbidden** in module names (compile error)
- `__` prefix is reserved for compiler-generated names
- Every module exports `ModName__init` (double underscore)
- `MAIN.RDF` is the entry-point stub generated by `oc /ENTRY=`

Examples: `Hello_WriteStr`, `Kernel_heap`, `Hello__init`

---

## FAR / NEAR procedure rules  ← CRITICAL

### Determining `is_far`

| Condition | `is_far` | Notes |
|-----------|----------|-------|
| Exported (`*`) | 1 (FAR) | Mandatory; cannot be overridden with NEAR |
| `PROCEDURE name; FAR;` | 1 (FAR) | Explicit FAR modifier |
| `PROCEDURE name; NEAR;` | 0 (NEAR) | Explicit NEAR modifier; error if exported |
| Non-exported, no modifier | 0 (NEAR) | Default for top-level and nested non-exported procs |
| `__init` | 1 (FAR) | Always FAR, always exported |

### Call and epilogue dispatch

| `is_far` | Epilogue | Call intra-module | Call inter-module |
|----------|----------|-------------------|-------------------|
| 0 (NEAR) | `RET` / `RET N` (C3/C2) | `cg_call_local` — `E8 rel16` | N/A (NEAR procs not exported) |
| 1 (FAR)  | `RETF` / `RETF N` (CB/CA) | `cg_call_local_far` — `0E PUSH CS` + `E8 rel16` | `cg_call_far` — `9A` + RELOC + SEGRELOC |

**Three call cases:**

1. **Local NEAR** (`is_far=0`): `E8 rel16` — plain CALL NEAR, no PUSH CS, no relocations.  
   Params start at `[BP+4]`; epilogue `RET N` pops only IP.
2. **Local FAR** (`is_far=1`, same module): `0E PUSH CS` + `E8 rel16` — no relocations.  
   Use when `sym->exported && sym->rdoff_id < 0`.  
   Params start at `[BP+6]`; epilogue `RETF N` pops IP then CS.
3. **Imported** (another module, `M_IMPORT`): `9A oo oo ss ss` CALL FAR + RELOC + SEGRELOC.  
   Always FAR (`item->is_far` set from `.def` type, default 1); params start at `[BP+6]`.  
   EXTERNAL NEAR procs are the one exception: `item->is_far=0` → `E8 rel16` NEAR call.

### Procedural variables

**Procedure-typed values are ALWAYS FAR (maintainer rule, 2026-07-10/11:
"procedure addr always is FAR").**  The `PROCEDURE NEAR (...)` TYPE form was
removed: declaring a proc-typed VAR/field/param type as NEAR is a fatal
compile error ("PROCEDURE NEAR type is not supported — proc-typed VARs are
always FAR"); the `FAR` modifier is accepted as a no-op.  This is only about
the TYPE used for proc *values* — a real procedure's own `NEAR;`/`FAR;`
declaration (the Visibility/NEAR rule) is unchanged.

| Type | Storage | Assignment | Call |
|------|---------|------------|------|
| `PROCEDURE [FAR] (...)` (always FAR) | 4 bytes `{offset, segment}` | loads `AX=offset, DX=CS`; stores DX:AX | `CALL FAR [BP+n]` (FF 5E) or `CALL FAR [mem]` (FF 1E) |

A FAR proc var may hold the address of a NEAR-declared procedure — only the
variable's own storage and call-through-variable codegen must be FAR.

**STRONG RULE — a procedure-typed value passed or stored as a value must always be
loaded/compared/called as FAR, even when the underlying procedure is itself
declared NEAR.** A NEAR procedure's code lives in the same code segment as its
call sites *only* while every reference to it is a direct, statically-resolved
`CALL`/`JMP`. The moment its address is taken as a **value** (assigned to a
`PROCEDURE` type variable/parameter, stored in a record field, compared to
another proc value, etc.), that value can end up read back and called from a
*different* code segment than where the procedure lives — the same 8086
memory model that makes intra-segment NEAR calls cheap makes a NEAR *address
value* meaningless outside the segment it was taken in. Treat every
procedure-typed value as FAR for storage/comparison/indirect-call purposes;
only a direct `CALL`/`JMP` to a known NEAR procedure may skip the segment.

**2026-07-10 bug (found + fixed) — missing relocation for indirect calls
through a data-segment procedure variable.** `Cgen.CgCallProcVarMem` /
`CgCallProcVarNearMem` (the `CALL FAR/NEAR [mem]` emitters used when the
procedure variable is a **module-level `VAR`**, as opposed to a local/param
living at `[BP+n]`) baked the module-local data offset directly into the
instruction with a bare `EmitW` and **no relocation** — every sibling
load/store-from-data-offset helper (`CgLoadMem`, `CgStoreMem`,
`CgLoadAddrMem`, …) goes through `EmitMemReloc`, which pairs the `EmitW` with
`Rdoff.RdfAddReloc(..., Rdoff.SegData, FALSE)` so the linker corrects the
offset once the module's data is placed at its real base inside the combined
DGROUP; these two did not. The write side (`CgStorePtrMem`, used when
*assigning* to the proc-typed VAR) already did this correctly, so the STORED
far pointer itself was correct in the final image — only the READ-and-CALL
site read from the wrong, un-relocated address, landing on whatever
unrelated bytes happened to sit at the raw pre-link offset in the final
binary. Symptom: `Invalid opcode` crash, `CS=0000` in the register dump,
jumping through garbage. This pattern was previously unexercised: nothing in
the compiler before 2026-07-10 stored a FAR procedure value into a
**global** `VAR` and called it later (a transient `Scan.SyscommentHook`
experiment that session was the first; the shipped fix for the lost-`$M`
problem is the `MaxPendSys` syscomment *queue* on `Scan.Scanner`, no proc-var
involved). Fixed by routing both emitters through `EmitMemReloc` like every
other data-offset site (`CgCallProcVarNearMem` was later deleted outright
when proc-typed values became FAR-only). See
`TESTS/FIX/SYSCOMMENT_STACK_BUG.md` for the full trace and isolated repro.

---

## Module initialization protocol  ← CRITICAL

Every module gets a compiler-generated `__init` FAR procedure, exported as `ModName__init`.

**Trivial module** (no imports, no body): just `CB` (RETF).

**Module with imports or body:**
```asm
[guard_ofs]   DW 0                      ; guard word in CODE segment
              2E 83 3E lo hi 00         ; CS: CMP word [guard], 0
              74 01                     ; JE .cont
              CB                        ; RETF  (already inited)
; .cont:
              2E FF 06 lo hi            ; CS: INC word [guard]  ← BEFORE dep calls
              9A oo oo ss ss            ; CALL FAR Mod1__init
              ; ... module body ...
              CB                        ; RETF
```

Rules:
- No stack frame in `__init` (no PUSH BP / MOV BP,SP / SUB SP)
- INC before dep calls → circular-init safe
- CS: prefix (2Eh) — guard in code segment, not DS
- SYSTEM excluded from dep calls; `IMPORT SYSTEM` is a compile error
- `__init` always exported as RDOFF GLOBAL; never in .def file

**Sanitise-import pass (CLAUDE.md "Pending #1"):** after parsing the whole
module the compiler walks the IMPORT records.  For each entry named
`<Mod>__init`, if there is no other IMPORT `<Mod>_<sym>` in the same RDF,
the `<Mod>__init` reference is dead — the source declared `IMPORT <Mod>`
but never referenced a symbol from `<Mod>` (e.g. only used `<Mod>`'s
constants or inline procedures, both of which are resolved at compile
time without an RDOFF reference).  In that case:
- The 5-byte CALL FAR site is patched in-place to `90 90 90 90 90` (NOPs).
- The matching RELOC + SEGRELOC records are dropped from the list.
- The `<Mod>__init` IMPORT record is dropped from the list.

The smart linker can then omit `<Mod>.om` from the final EXE.  This pass
runs after all code emission, before `cg_finish`, so the body's symbol
references are already final.  Side effect: the per-module `.rdf` keeps
5 NOPs per dropped call (negligible at the per-module level; saved on
the final EXE because the whole `<Mod>` is no longer pulled in).

---

## SYSTEM pseudo-module  ← CRITICAL

SYSTEM is pre-declared as a K_IMPORT symbol, **always implicitly available**.

- `IMPORT SYSTEM` is a **compile error**
- `SYSTEM.Foo` creates a lazy RDOFF IMPORT for `SYSTEM_Foo` on first use
- `SYSTEM__init` is never called

### SYSTEM module symbols (from `SRC/LIB/SYSTEM.MOD`)

**Constants:** `FCarry=1  FParity=4  FAuxiliary=16  FZero=64  FSign=128  FOverflow=2048`

**Types:**
```
SYSTEM.Registers — RECORD, 18 bytes, 9 INTEGER fields:
  AX(0) BX(2) CX(4) DX(6) SI(8) DI(10) DS(12) ES(14) Flags(16)
```
No direct access to 8-bit registers (AL, etc.).

**Procedures:**
```
SYSTEM_INIT      — FAR, no args, no return
SYSTEM_DONE      — FAR, no args, no return
SYSTEM_CallFar   — FAR; args: ProcPtr:POINTER, Regs:POINTER Registers
SYSTEM_Intr      — FAR; args: IntNo:BYTE, Regs:POINTER Registers
SYSTEM_Alloc     — FAR; arg: sizeInBytes:INTEGER; returns POINTER (DX:AX)
SYSTEM_Free     — FAR; arg: p:POINTER; returns nothing
```

Note: SYSTEM_Intr contains `INT 0`, but it is self-modified code - interrupt number will be patched
in call time.

### SYSTEM intrinsics

**Type:** `SYSTEM.ADDRESS` (TF_ADDRESS, size 4) — compatible with any POINTER.

#### SYSTEM.ADDRESS as a byte pointer (pointer-to-CHAR semantics)

`SYSTEM.ADDRESS` is a 4-byte far value `{offset:word, segment:word}` (DX=segment,
AX=offset when loaded).  Beyond being POINTER-compatible, it behaves as an
implicit **`POINTER TO CHAR`** with byte addressing and pointer arithmetic:

| Form | Meaning | Codegen |
|------|---------|---------|
| `p^` | the `CHAR` at the address | load DX:AX → ES:BX; deref `MOV AL, ES:[BX]` |
| `p^[i]` | the `CHAR` at address + `i` (byte element, no bounds check) | ES:BX := address; `BX := BX + i` |
| `p^[i] := c` | write a `CHAR` through the address | `MOV ES:[BX], AL` after `BX += i` |
| `INC(p)` / `DEC(p)` | advance / retreat the **offset** by 1 | `INC AX` / `DEC AX` (DX untouched) |
| `INC(p, n)` / `DEC(p, n)` | advance / retreat the offset by `n` | offset-only `ADD/SUB AX, step.lo` |
| `p := p + e` / `p := p - e` | offset-only arithmetic in an expression | `ADD/SUB AX, e.lo`, DX preserved |

**MATH RULE — offset only, segment never carries.**  All `SYSTEM.ADDRESS`
arithmetic (`INC`/`DEC`/`+`/`-`) operates on the **offset word (AX) only**.  The
**segment word (DX) is never modified** — if the 16-bit offset overflows, it
wraps and the segment is left untouched (no carry into the segment, no `ADC`/
`SBB`).  The compiler saves and restores DX across the step/rhs evaluation so a
step expression that clobbers DX cannot corrupt the segment.

**LONGINT ↔ ADDRESS conversion is by CAST only** (no implicit assignment):

- `LONGINT(p)` — reinterpret the 4-byte `SYSTEM.ADDRESS` as a `LONGINT` (DX:AX,
  no extension; segment preserved as the high word).
- `SYSTEM.ADDRESS(L)` — reinterpret a `LONGINT` (or another pointer/address/far
  PROC) as a `SYSTEM.ADDRESS` (DX:AX, no change).

Only the **4-byte** forms convert: `LONGINT(p)` and `SYSTEM.ADDRESS(L)` are
legal; `INTEGER(p)` / `WORD(p)` / `BYTE(p)` (would drop the segment) and
`SYSTEM.ADDRESS(int16)` (no segment to supply) are **rejected** with a fatal
error.  Assigning a `LONGINT` directly to an `ADDRESS` (or vice versa) **without
a cast** is a type error.

**INLINE procedures in SYSTEM.MOD** (resolved from SYSTEM.OM, typeless VAR push):

All of ADR/SEG/OFS/PTR/MOVE/FILL/PORTOUT/PORTIN are INLINE procedures in SYSTEM.MOD using typeless
VAR params. `parse_actual_params` computes the far address of each actual variable and
pushes `{segment, offset}` = 4 bytes; the INLINE byte pattern then POPs them.

| Intrinsic | Signature | Bytes | Description |
|-----------|-----------|-------|-------------|
| `SYSTEM.ADR(v)` | `VAR v): ADDRESS` | `58 5A` | Far address of `v`; result DX:AX={seg,ofs} |
| `SYSTEM.SEG(v)` | `VAR v): INTEGER` | `58 58` | Segment of `v` (SS for locals, DS for globals, heap seg for `p^`) |
| `SYSTEM.OFS(v)` | `VAR v): INTEGER` | `58 59` | Offset of `v` within its segment |
| `SYSTEM.PTR(s, o)` | `s, o: INTEGER): ADDRESS` | `58 5A` | Construct far pointer from seg `s` and ofs `o` |
| `SYSTEM.MOVE(src, dst, n)` | `VAR src, dst; n: INTEGER` | `59 5F 07 5E 58 1E 8E D8 FC F3 A4 1F` | Copy `n` bytes from `src` to `dst` |
| `SYSTEM.FILL(dst, n, b)` | `VAR dst; n: INTEGER; b: BYTE` | `58 59 5F 07 FC F3 AA` | Fill `n` bytes at `dst` with byte `b` |
| `SYSTEM.PORTOUT(p, b)` | `p: INTEGER; b: BYTE` | `58 5A EE` | Write byte `b` to port `p` (OUT DX, AL) |
| `SYSTEM.PORTIN(p, v)` | `p: INTEGER; VAR v: BYTE` | `58 5B 5A EC 26 88 07` | Read byte from port `p` into `v` (IN AL, DX) |

**INLINE + VAR / open-array params — push width MUST match the POPs.**  An INLINE
proc with *no named params in the `INLINE(...)` list* gets its arguments pushed on
the stack by `parse_actual_params` (the normal call ABI), and the INLINE bytes
`POP` them — so the **formal's declared type decides how many words are pushed**,
and the byte pattern must POP exactly that many:

- **typeless `VAR v`** (ADR/SEG/OFS/MOVE/…): caller pushes `{seg, ofs}` = 4 bytes →
  the pattern POPs 2 words.
- **open array `VAR s: ARRAY OF CHAR`** (UPSTR/LOSTR/BLOCKWRITE/BLOCKREAD): caller
  pushes `{ofs, seg, LEN}` = 6 bytes → the pattern POPs 3 words (`POP BX; POP ES;
  POP CX`).  **Declaring such a proc as typeless `VAR s` is a bug**: only 4 bytes
  are pushed, so `POP CX` reads the return address as the length → the loop runs
  over garbage and corrupts the stack/heap.  Keep the `ARRAY OF CHAR` signature.

> **Lesson (UPSTR/LOSTR off-by-2, fixed 2026-06-27):** an INLINE that branches must
> use **byte offsets counted within its own emitted body**.  UPSTR/LOSTR are 28
> bytes; `JCXZ done`/`JZ done` had `E3 19`/`74 12` (target +30, 2 past the end) and
> jumped into the following code → "Invalid opcode".  Correct: `E3 17`/`74 10`.
> When hand-assembling an INLINE with internal jumps, count the bytes.

**Removed (not available in this dialect):** `SYSTEM.GET`, `SYSTEM.PUT`, `SYSTEM.VAL`.
Use `POINTER TO T` and `p^` for memory read/write through an `ADDRESS`.
Use `INTEGER(x)`, `BYTE(x)`, `CHR(x)`, `ORD(x)` for type reinterpretation/casting.

Invariants: `ADR(n^) = n`; `SEG(n^) = SEG(n)`; `OFS(n^) = OFS(n)`; `ADR(v) = PTR(SEG(v), OFS(v))`.

`SYSTEM.ADR` also accepts procedure names: `SYSTEM.ADR(ProcName)` returns the far code address `CS:code_offset`.

**Typeless VAR push — what gets pushed for each argument form:**

| Argument form | Emitted push | Stack result |
|---------------|-------------|--------------|
| Global var/field/array `g` | `LEA AX,[g_ofs]+RELOC; PUSH DS; PUSH AX` | `{g_ofs, DS}` |
| Local var/field/array `x` | `LEA AX,[BP+ofs]; PUSH SS; PUSH AX` | `{BP-ofs, SS}` |
| VAR param `v` (is_ref) | copy slot: `MOV AX,[BP+ofs+2]; PUSH; MOV AX,[BP+ofs]; PUSH` | caller's `{seg, ofs}` |
| Pointer deref / array elem `p^` | `PUSH ES; MOV AX,BX; PUSH AX` | `{BX, ES}` = `{ofs, seg}` of pointed-to location |
| Procedure name `P` | `PUSH CS; MOV AX,ofs+CODE_RELOC; PUSH AX` | `{code_ofs, CS}` = far code address |

**Typeless VAR param as a value (CRITICAL — `CgLoadItem` rule):**
A typeless (`VAR x` with no declared type) formal parameter has `item.type^.form = TFAddress`
(declared via `TypeAddress` in `Syms`).  When such a param is used as an r-value (e.g.
`dest := x`), its *value IS* the 4-byte far address held in its ref slot — there is nothing
to dereference *to*.  `CgLoadItem` must load the slot directly (`CgLoadPtrBp`/`CgLoadPtrMem`)
**without** an extra far-pointer dereference.  The discriminant is `item.type^.form = TFAddress`
(not the `item.typeless` flag, which is an uninitialized local on most code paths).
Typed pointer VAR params (`TFPointer`) still dereference normally.

**Expression intrinsics (compiler built-in, cannot be INLINE):**

| Intrinsic | Returns | Why compiler built-in |
|-----------|---------|----------------------|
| `SYSTEM.LSL(x, n)` | same type as `x` (BYTE/INTEGER/WORD/LONGINT) | Type-dispatch (16-bit vs 32-bit) + const vs variable shift |
| `SYSTEM.LSR(x, n)` | same type as `x` | Same |
| `SYSTEM.ASR(x, n)` | same type as `x` | Same |
| `SYSTEM.ROR(x, n)` | same type as `x` | Same |
| `SYSTEM.AND(x, y)` | LONGINT if either is LONGINT; else WORD if either is WORD; else INTEGER | Bitwise AND with type dispatch |
| `SYSTEM.IOR(x, y)` | same rule as AND | Bitwise OR with type dispatch |
| `SYSTEM.XOR(x, y)` | same rule as AND | Bitwise XOR with type dispatch |

**Type rules:** For shifts, the result type matches `x` exactly (WORD in → WORD out, preserving unsigned semantics).  For AND/IOR/XOR, the widest type wins: LONGINT > WORD > INTEGER.  The 16-bit codegen (AX/CX ops) is identical for INTEGER and WORD — only the result type differs.

These intrinsics are **not** expressible as INLINE byte patterns because they need type dispatch (16-bit vs 32-bit). They are registered in the compiler under `"SYSTEM.Name"` (not as bare names), so **bare `LSL(x,n)` is a compile error** — callers must write `SYSTEM.LSL(x,n)`.

**Rule: SYSTEM intrinsics must not be pre-declared with bare names in the compiler.** Any intrinsic conceptually belonging to SYSTEM is registered in `sym_init()` under `"SYSTEM.Name"` so that only qualified `SYSTEM.Name(...)` access works.

**Key codegen notes:**
- ADR/SEG/OFS/PTR: share the same typeless VAR push mechanism; INLINE patterns differ only in how they pop the two stack words
- **CLD always** before REP MOVSB/STOSB (direction flag may be set)
- `LSL/LSR/ASR/ROR`: inline 8086 shifts, no function call.
  Shift-by-1: `D1` form. Shift-by-N (N≥2): `MOV CL,N` then CL form.
  Variable: `MOV CL,AL / AND CL,0Fh` then CL form.

**SP_ constants (symbols.h) — ADR, SEG, OFS, PTR, MOVE, FILL all resolved via SYSTEM.DEF (INLINE in SYSTEM.MOD):**
```c
SP_LSL=21  SP_ASR=22  SP_ROR=23  SP_LSR=24
SP_AND=28  SP_IOR=29  SP_XOR=30
SP_TOWORD=31   /* WORD(x) type cast — compiler built-in */
```

---

## NEW and DISPOSE

**NEW(p)** where `p: POINTER TO T`:
- Calls `SYSTEM_Alloc(sizeof(T))` FAR — Pascal, cleans 2 bytes
- Result DX:AX stored into p
- Codegen: `cg_load_imm(sz)` / `PUSH AX` / `cg_call_far(Alloc_id)` / `cg_store_item`

**NEW(p, n)** sized allocation:
- `n` is any INTEGER expression; always interpreted as **byte count**
- Also works when `p` is `SYSTEM.ADDRESS` (TF_ADDRESS)
- Codegen: evaluate n into AX, `PUSH AX`, `cg_call_far(Alloc_id)`

**DISPOSE(p)** where `p: POINTER TO T` or `SYSTEM.ADDRESS`:
- Calls `SYSTEM_Free(p)` FAR — Pascal, cleans 4 bytes. Does NOT set p to NIL.
- Codegen: `cg_load_item(&ptr)` → DX:AX / `PUSH DX` / `PUSH AX` / `cg_call_far(Free_id)`
- Predeclared as `SP_DISPOSE = 11`

---

## Qualified import access

```oberon
IMPORT H := Hello;
H.WriteStr("hi")
```

Lookup: `H` → K_IMPORT with `mod_name="Hello"` → DOT → construct `Hello_WriteStr`
→ find or add RDOFF IMPORT → item = M_IMPORT with rdoff_id.

**`item->is_far` must be set** from the resolved `.def` symbol's type (`def_sym->type->is_far`).
If no `.def` entry exists, default `is_far = 1` (cross-module calls are always FAR).
Failure to set `is_far` causes `cg_call_near` (E8) to be emitted instead of `cg_call_far` (9A),
producing a stack-corrupting NEAR call into a FAR procedure in another code segment.

---

## Import error handling

- Missing `.def` for explicit `IMPORT Foo`: **fatal error** (exit 1).
- SYSTEM always implicitly available; missing `SYSTEM.def` silently ignored.
- No partial compilation with unresolved imports.
- Tests using `IMPORT X` must create stub `X.def` (`MODULE X\n` minimum).

---

## Entry point: /ENTRY= flag

```
oc /ENTRY=ProcName File.Mod
```

Generates `MAIN.RDF` containing:
```asm
MOV AX, min_para            ; B8 lo hi  — heap min (paragraphs) from $M
MOV BX, max_para            ; BB lo hi  — heap max (paragraphs) from $M
CALL FAR SYSTEM_INIT        ; seg 3 — uses AX/BX to size the heap
CALL FAR ModName__init      ; seg 5
CALL FAR ModName_ProcName   ; seg 6
CALL FAR SYSTEM_DONE        ; seg 4
```
Exports GLOBAL `start` at offset 0 (the `MOV AX`). Compiler never emits `INT 20h` — DOS exit is `SYSTEM_DONE`'s job.
`min_para`/`max_para` come from the `$M` directive (defaults: 8192/16384 = 128 KiB/256 KiB paragraphs).
If ProcName does not exists into module File.mod -> compiler must produce error and stop.

---

## INLINE procedures  ← CRITICAL stack-balance rule

```
PROCEDURE name*(params): rettype; INLINE(byte, byte, ..., paramName, ...);
```

An INLINE procedure has **no body, no prologue, no epilogue, and no CALL instruction**.
The byte pattern is emitted verbatim at every call site.

### How the byte pattern is emitted

- **Integer literal**: emitted as a single raw byte (0..255). Must fit in one byte.
- **Formal parameter name**: substituted by the 2-byte little-endian address of the actual argument:
  - Local variable / stack parameter → signed 16-bit BP offset, no relocation.
  - Global variable → unsigned 16-bit DS offset + DATA relocation record.

The substituted address is the **address** (location) of the variable, not its value.
The byte pattern is responsible for the actual load/store using that address.

### Stack balance rule — MANDATORY

**SP before the inline call equals SP after the inline call.**

The compiler emits the byte pattern directly in-line with the surrounding code.
There is no CALL/RET frame to hide stack imbalance.  Any PUSH inside the byte
pattern that is not matched by a corresponding POP (or equivalent SP adjustment)
corrupts the caller's stack frame and leads to undefined behavior at RET time.

**Every INLINE procedure MUST leave SP unchanged.** This is a hard, unconditional
rule enforced by programmer discipline — the compiler does not verify the byte
sequence, but the rule MUST be followed for correctness.

Examples of correct balanced patterns:
```
INLINE(090H);               (* NOP — SP unchanged *)
INLINE(050H, 058H);         (* PUSH AX; POP AX — balanced *)
INLINE(0B8H, 02AH, 000H);  (* MOV AX, 42 — SP unchanged, result in AX *)
```

Examples of INCORRECT unbalanced patterns (FORBIDDEN):
```
INLINE(050H);               (* PUSH AX only — SP decremented by 2, BROKEN *)
INLINE(058H);               (* POP AX only  — SP incremented by 2, BROKEN *)
```

### Restrictions

- Cannot be combined with `FAR`, `NEAR`, or `EXTERNAL` modifiers.
- Can be exported (`*`); exported inline procs have no RDOFF GLOBAL record.
- Return value (if any) must be in AX (INTEGER/BOOLEAN/CHAR/BYTE/SET/POINTER) or
  DX:AX (LONGINT/ADDRESS) — same convention as regular procedures.

### Cross-module export / import

Exported inline procs are stored in the `.def` file as:
```
INLINE ModName_ProcName rettype
  PARAM VAR name type
  BYTES b0 b1 P0 b2 ...
END
```
`def_read` fully reconstructs the `TypeDesc` (including byte pattern and param list).
At import sites, bytes are emitted directly — no RDOFF IMPORT record is created.

### INLINE as a statement

`INLINE(byte, byte, ...)` is also accepted as a **statement** inside an ordinary
procedure body.  Constants only (no `Pn` parameter references — that form is
exclusive to the proc-body-as-INLINE declarator above).  The listed bytes
are emitted verbatim into the current procedure's code stream, in place.

```
PROCEDURE Cli*;
BEGIN
  INLINE(0FAH)              (* CLI *)
END Cli;

PROCEDURE Halt*;
BEGIN
  INLINE(0F4H)              (* HLT *)
END Halt;
```

Used to inject low-level instructions (CLI/STI, IN/OUT, HLT, INT, ...) inside
a regular Oberon procedure.  The stack-balance rule applies just as for the
declarator form: SP at the end of the byte sequence must equal SP at the
start, or the surrounding procedure's epilogue will misbehave.

---

## IS type test

`v IS T` is a type test where `v` is a `POINTER TO RECORD` and `T` is a `RECORD` type name (or `POINTER TO RECORD` type name, in which case its base record is used).

### Rules

- LHS must be a `POINTER` (or `SYSTEM.ADDRESS`).  RHS must be a `RECORD` type name (or a `POINTER TO RECORD` type name).
- If the LHS pointer's static base type **extends** `T`, the expression folds to the constant `TRUE`.
- If `T` **extends** the LHS base type (possible at runtime), a runtime tag check is emitted.
- If the two types are **unrelated** (neither extends the other), the expression folds to `FALSE`.

### Type tag implementation

Every heap-allocated RECORD allocated by `NEW(p)` where `p: POINTER TO RECORD` gets a hidden 2-byte **type descriptor offset** stored at `[seg:ofs-2]` — two bytes *before* the record data. The POINTER variable itself holds `seg:ofs` (pointing to the data, not the tag).

Each RECORD type has a globally unique integer `tag_id` (assigned at parse time, starting at 1). When a RECORD type is parsed, its **type descriptor** — a zero-terminated WORD array listing `[self_id, parent_id, ..., root_id, 0]` — is emitted into the module's data segment. `desc_ofs` in TypeDesc records the data-segment offset of this array.

`NEW(p)`:
1. Allocates `size + 2` bytes.
2. Writes `base->desc_ofs` (a WORD) at the start of the allocation (the tag slot).
3. Returns `ptr + 2` so the POINTER variable points to the record data.

`DISPOSE(p)`:
1. Subtracts 2 from the offset before passing the pointer to `SYSTEM_Free`.

`v IS T` (runtime):
1. Load the far pointer into ES:BX.
2. `AX = ES:[BX-2]` — the tag descriptor offset.
3. Scan `DS:[AX], DS:[AX+2], ...` for `T.tag_id`; return 1 if found, 0 if not (hits sentinel 0).

This design keeps record field offsets unchanged (compatible with assembly code using the same record layout).

### Codegen

Compile-time folds: `cg_load_imm(1)` or `cg_load_imm(0)`.
Runtime: `cg_load_item` + `cg_dxax_to_esbx` + `cg_load_tag_far` + `cg_is_tag_scan(tag_id)`.

### Example

```oberon
TYPE
  Animal  = RECORD legs: INTEGER END;
  Dog     = RECORD (Animal) tricks: INTEGER END;
  PAnimal = POINTER TO Animal;
  PDog    = POINTER TO Dog;
VAR pd: PDog; pa: PAnimal; b: BOOLEAN;
BEGIN
  NEW(pd);
  b := pd IS Animal;  (* compile-time TRUE — Dog extends Animal *)
  b := pd IS Dog;     (* compile-time TRUE — same type *)
  pa := pd;
  b := pa IS Dog;     (* runtime check — TRUE because pa points to a Dog *)
  NEW(pa);
  b := pa IS Dog;     (* runtime check — FALSE because pa now points to Animal *)
END
```

---

## Dead-code/unused-symbol warnings

After parsing each procedure body (and again at end of module) the
compiler walks the just-closed scope and emits a non-fatal stderr
warning for every declaration that was never **read**:

```
mymodule.mod(12): warning: variable 'tmp' declared but never used
mymodule.mod(7):  warning: parameter 'unused' declared but never used
mymodule.mod(33): warning: procedure 'Helper' declared but never used
```

A "read" is any expression-context access (RHS of assignment, condition
expression, CASE selector, CASE label, RETURN expression, actual
parameter, VAR-param actual, SYSTEM.ADR argument, etc.). **Assignment
alone (`x := 5;` with `x` then never used) does NOT count as a read** —
this is intentional, since the typical case for that pattern is a typo
(`x` should have been `xs`).

### Per-category rules

| Symbol kind | Warned when |
|---|---|
| Local variable | Never read in body |
| Procedure parameter (value) | Never read in body |
| VAR parameter | Never read AND never written — assignment counts as use, because VAR params are out-parameters |
| Module-level global (non-exported) | Never read anywhere in module |
| Procedure (non-exported) | Never called anywhere in module |

### What's skipped

- **Exported symbols** (`*`): may be used by other modules; whole-program
  analysis isn't done.
- **Names starting with `$`**: compiler-internal generated names
  (`$case`, `$lim`).
- **K_IMPORT** entries: dead imports are handled by the separate
  **sanitise-import** pass, not this one.
- **K_CONST / K_TYPE / K_FIELD / K_SYSPROC**: these aren't "read" the
  same way a value is — `CONST` may be folded into expressions that
  leave no trace; `TYPE` references are structural; etc.
- **FORWARD-declared procedures whose body is missing**: a separate hard
  error already covers that case.
- **INLINE procedures and their parameters**: the byte pattern *is* the
  body; there's no "use site" to find inside it.

### Implementation

Each `Symbol` carries `read_count` (saturating 16-bit, only "0 vs >0"
matters) and `decl_line` (source line of declaration).  Each `Item`
carries `root_sym` — a pointer to the designator's root symbol.

`pe_mark_read(Item*)` (C) / `PExpr.MarkRead(Item)` (Oberon) is called
from every read site:
- `parse_factor` after `parse_designator` (expression read)
- `parse_actual_params` for VAR-param actuals (address taken)
- `pe_emit_inline_call` for ADDRESS-mode args (SYSTEM.ADR family)
- proc-call statement branches (M_PROC, M_IMPORT, proc-var call,
  inline-proc call)
- assignment LHS, ONLY if the target is a K_VARPARAM (out-param write)

At end of scope, `warn_unused_in_scope()` walks `top_scope->symbols`,
applies the filters above, and prints to stderr.

---

## Debug info: `$D` directive + `/G` link switch (TDS/TDINFO)

Source-level debug information for Borland Turbo-Debugger-style debuggers.
On-disk TDS wire format + record layouts: `DOCS/TD-SPEC.MD` §EMPIRICAL.
`.DBG` transport grammar (compiler→linker) + linker merge algorithm
(nested-procedure scope stack, rebase rules): `DOCS/IMPLRULE.MD`
§".DBG file format".

**Per-module collection — `(*$D+*)` / `(*$D-*)` (also `//$D+` form):**

- Default **off**. Like `$R`/`$A`, the last toggle before codegen wins; `$D`
  may not be combined with `,` in one comment.
- When on, the compiler (module `TDbg`, hooks in `Parser`/`PStmt`) records:
  the module ident (source case, no extension), the source filename
  (uppercase 8.3, with `.MOD`), every procedure (code offset at prologue),
  every module-level VAR (data offset; this compiler has no BSS), every
  module-level named `TYPE` declaration (exported AND non-exported — a
  TYPEDEF-class symbol with no code/data location), the full type graph
  reachable from those VARs/TYPEs (primitives, ARRAY, RECORD incl. one
  MEMBER per field, POINTER), every procedure's own params and locals
  (class AUTO, signed BP-relative offset, one SCOPE per procedure that has
  at least one), and one line record per source line that emitted code
  (first instruction, deduped). There is **no separate switch for line
  info vs. full info** — `$D+` always collects everything above in one
  pass; there is no Turbo-Pascal-style `$L+`/`$L-` toggle in this compiler.
- **Every** compiled `.om` carries a `MODNAME.DBG` text member: non-empty
  under `$D+`, a **0-byte member** under `$D-` (uniform archive layout).
  Offsets in the member are module-relative, fixed-width hex4; line numbers
  and code length are decimal. Full grammar in `DOCS/IMPLRULE.MD`
  §".DBG file format":
  `M`/`F`/`C` (module/source/code-length), `T`/`B` (type/member records,
  module-local 1-based indices, emitted before `S`), `S` (symbol: class
  P/V/Y/A, offset, seg, type index, name — class `A` is a param/local, its
  offset a signed BP-relative value; class `E` is a scope-end marker, not a
  real symbol, closing the most recent `P`'s scope with that procedure's own
  code length), `L` (line: offset, line).
- Procedures currently carry type index 0 (no FUNCTION-return typing yet);
  nested/block scopes narrower than "the whole procedure body" are not
  modeled (this dialect has no nested-proc uplevel access, so one flat AUTO
  scope per procedure is the whole picture — no further phase is needed
  here).

**Link-time emission — `oc /G /ENTRY=...`:**

- The linker extracts each used module's `.DBG`, rebases offsets
  (code: + module's offset inside its group; data: + `dataFinalOfs`; a
  local's/param's BP offset needs no rebasing — it is frame-relative, not
  segment-relative) and type/member indices (`+ Module.dbgTypeBase` /
  `+ Module.dbgMembBase`, running per-module totals computed in the same
  counting pass that also interns names), and appends one merged **TDS
  v2.08** block after the data image: 48-byte header (`0x52FB`, ver 2.08),
  STATIC/TYPEDEF/AUTO symbol records (with real type indices), module/
  source-file records, `(line, offset)` line records, one SCOPE_RECORD per
  procedure that has params/locals (`sym_first`/`sym_cnt` index into the
  *same* global SYMBOL_RECORD array; `function` is that procedure's own
  1-based symbol index), TYPE_RECORD/MEMBER_RECORD arrays, one segment
  record per module (slice of the group's load-relative paragraph), one
  correlation record per module, and a deduplicated string pool.
- SCOPE_RECORDs are built **while** SYMBOL_RECORDs are streamed (`Link.
  DbgPass` pass 2): a scope's `sym_first`/`function` are only known once
  those symbols are actually written, so scope-building cannot be deferred
  to a later pass the way TYPE_RECORD/MEMBER_RECORD rebasing is. `scopes`/
  `locals` header counts are pre-computed in pass 1 (same "count before the
  header is written" requirement as every other array).
- **Pure append**: no MZ header field and no relocation changes.  Without
  `/G` the `.exe` is byte-identical; with `/G` the *loaded* program is still
  identical (DOS loads only header+code+data — the tail is debugger-only).
- Inspect with `BIN/TDINFO.EXE FILE.EXE` (locates the block at MZ image end).

Tests: manifest rows `dbg/*` + `TESTS/test_dbg.sh` (see DOCS/TESTS.MD).

---

## Known limitations (not yet implemented)

| Feature | Workaround |
|---------|------------|
| (no current entries — Wirth-style strictness now enforced on all numeric paths) | — |

### Actual-parameter type checking

Both local and imported procedure calls verify each actual argument's
type against the formal's declared type.  Diagnostics:

```
foo.mod(12): type mismatch in actual parameter: 'x'
```

Rules applied at each call (`parse_actual_params` → `check_param_compat`):

- VAR parameter: the actual must be a **variable (l-value)** — a local/global
  variable, record field, array element, or pointer dereference.  A string
  literal, a constant (scalar or array), an arbitrary expression, or a
  procedure value is rejected ("VAR parameter requires a variable (not a
  literal, constant, or expression)").  A VAR formal binds to the caller's
  storage, so a value with no address cannot be bound; in particular passing a
  string literal to a `VAR ARRAY OF CHAR` formal used to be miscompiled into a
  far ref with a bad length that hung the compiler in the INLINE name scan — it
  is now a clean compile error.  (Implementation: `check_param_compat` requires
  `arg.mode` ∈ {MLocal, MGlobal, MReg&isRef}.)
- VAR parameter type: requires identity match — same `TypeDesc` or, for records
  reached via alias / cross-module import, structurally identical
  (same `fields` linked list and `size`); for pointer formals, the base
  records must match by identity or structure; arrays must match by
  element type + length (fixed) or by element type alone (open formal).
- Value parameter: `type_assign_compat` applies — integer-family widening
  (BYTE/WORD/INTEGER → LONGINT) is implicit, NIL is compatible with any
  POINTER / PROC formal, single-character string literals are compatible
  with CHAR / BYTE formals, ARRAY OF CHAR string literals are compatible
  with `ARRAY OF CHAR` / `ARRAY OF BYTE` formals, REAL widens to
  LONGREAL at the call boundary.
- Skipped: typeless VAR formal accepts any actual by design.

Without this check the compiler would silently push the wrong byte
count onto the stack (e.g. pushing a 4-byte REAL where the callee
reads 2 bytes as INTEGER), corrupting subsequent params and any frame
above.  Same risk for VAR-by-alias mismatches.

### Cross-family numeric assignment (int ↔ float)

`r := i` where `r` is `REAL`/`LONGREAL` and `i` is `INTEGER`/`LONGINT`/
`BYTE`/`WORD`/`CHAR` (and the reverse direction) is **rejected at compile
time** with:

```
type mismatch in assignment: int/float require explicit cast
(REAL(x), LONGREAL(x), FLOOR(x), ENTIER(x))
```

Use an explicit cast at the assignment boundary:

| Direction | Cast |
|-----------|------|
| `INTEGER`/`LONGINT` → `REAL` | `r := REAL(i)` |
| `INTEGER`/`LONGINT` → `LONGREAL` | `lr := LONGREAL(i)` |
| `REAL`/`LONGREAL` → `INTEGER` (truncating) | `i := FLOOR(r)` (or `ENTIER(r)`) |

This matches Wirth's Oberon-07 spec — there is no implicit narrowing or
widening between the integer and floating-point families.  Without the
check the load/store paths would emit either integer bytes interpreted as
an IEEE-float bit pattern, or vice-versa, with no diagnostic.  Binary
expression context (`r + i`, `r < i`) still performs implicit `int→float`
promotion (FILD); the strict rule applies only to assignment.
