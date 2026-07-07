# Oberon-07 Compiler Manual — MS-DOS Real Mode

Self-hosted Oberon-07 compiler and toolchain for MS-DOS real-mode 16-bit (8086/8087).
All tools run natively on MS-DOS and under the `xt` emulator on Linux/macOS.

---

## 1. Toolchain

| Binary | Purpose |
|--------|---------|
| `bin/toc.exe` | All-in-one: dep-scan + incremental compile + smart link |
| `bin/tolib.exe` | `.om` archive manager: list / extract / create / merge |
| `bin/rdfgrep.exe` | RDOFF2 / `.om` / `.exe` introspection (used in tests) |
| `boot/toc.exe` | Bootstrap seed binary — never modified by `make` |
| `xt` | DOS emulator; runs MS-DOS MZ executables on Linux/macOS |

### 1.1 Compiler usage

```
toc.exe [flags] Root.Mod
```

**Compile-only** (no `/ENTRY=`): scan transitive deps, recompile stale modules, write `.om` files. No linking.

**Compile + link** (`/ENTRY=ProcName`): scan deps, compile stale modules, link → `output.exe` (defaults to `Root.exe`).

Switches use the DOS `/` style and are case-insensitive (`/M`=`/m`, `/SYSTEM`=`/system`, `/ENTRY=`=`/entry=`); the `/ENTRY=` value keeps its case. Any other option is a fatal `unknown option` error.

| Flag | Effect |
|------|--------|
| `/ENTRY=ProcName` | Generate startup stub and link to executable |
| `/M` | Recompile all modules regardless of staleness |
| `/SYSTEM` | Special single-module mode for building the SYSTEM module (`SYSTEM.mod`) itself |

**Import resolution order:** `ModName.OM` in CWD → `ModName.OM` in exe directory → each file in `OBERON_LIB` → `OBERON.OM` in CWD → `OBERON.OM` in exe directory. Only `.om` archives are read; standalone `.def` files are ignored.

**Running under xt:**
```bash
xt run --max=50000000 -c . bin/toc.exe /ENTRY=Run MyProg.Mod
```

### 1.2 olib — archive manager

```
tolib.exe list    File.om
tolib.exe extract File.om MemberName OutFile
tolib.exe create  Out.om  file1 file2 ...
tolib.exe merge   Out.om  In1.om In2.om ...
@listfile         (any command: expand one arg per line)
```

### 1.3 Build

```bash
make          # stdlib → bin/toc.exe → bin/tolib.exe → tools → bin/OBERON.OM
make test     # clean rebuild + 247 manifest tests
make testall  # full DOS-side suite (manifest + Section 17/18 unit tests)
```

---

## 2. Language dialect

Oberon-07 (Wirth 2007) with practical extensions for DOS system programming.

### 2.1 Type system

| Type | Size | Notes |
|------|------|-------|
| `BOOLEAN` | 1 byte | `FALSE`=0, `TRUE`=1 |
| `CHAR` | 1 byte | ASCII; string literals are `ARRAY OF CHAR`, NUL-terminated |
| `BYTE` | 1 byte | Unsigned 0..255 |
| `INTEGER` | 2 bytes | Signed −32768..32767 |
| `WORD` | 2 bytes | Unsigned 0..65535 |
| `LONGINT` | 4 bytes | Signed 32-bit; DX:AX register pair |
| `REAL` | 4 bytes | IEEE 754 single; requires x87 FPU |
| `LONGREAL` | 8 bytes | IEEE 754 double; requires x87 FPU |
| `SET` | 2 bytes | Elements 0..15 |
| `POINTER TO T` | 4 bytes | Far pointer: `{offset, segment}`; `NIL` = `0000:0000` |
| `SYSTEM.ADDRESS` | 4 bytes | Far pointer; compatible with any `POINTER TO T` |

No 64-bit integers. No implicit int↔float promotion at assignment — use `REAL(x)`, `FLOOR(x)`.

Within binary expressions (`+ - * / = # < > <= >=`), an integer operand is promoted to float when the other side is `REAL` or `LONGREAL`.

### 2.2 Type casts

```oberon
INTEGER(x)      (* truncate to low 16 bits *)
LONGINT(x)      (* sign-extend INTEGER/BYTE/WORD to 32-bit *)
WORD(x)         (* reinterpret 16 bits as unsigned *)
BYTE(x)         (* mask to low 8 bits *)
REAL(x)         (* integer → 32-bit float, FILD *)
LONGREAL(x)     (* integer → 64-bit float, FILD *)
FLOOR(x)        (* float → INTEGER, rounds toward −∞ *)
ENTIER(x)       (* synonym for FLOOR *)
FLOAT(x)        (* synonym for REAL(x) *)
CHR(i)          (* INTEGER → CHAR *)
ORD(c)          (* CHAR → INTEGER *)
```

### 2.3 Identifiers and keywords

All identifiers are **case-sensitive**.  Keywords are uppercase: `BEGIN END VAR CONST TYPE PROCEDURE MODULE IMPORT RECORD ARRAY POINTER TO OF RETURN IF THEN ELSIF ELSE WHILE DO REPEAT UNTIL FOR BY CASE NIL TRUE FALSE OR DIV MOD IS IN NEW DISPOSE`.

Context-sensitive modifiers (also uppercase): `FAR NEAR EXTERNAL INLINE FORWARD`.

### 2.4 Procedures

```oberon
PROCEDURE Name*(param: Type): RetType;  (* exported = always FAR *)
  VAR local: INTEGER;
BEGIN
  RETURN value
END Name;

PROCEDURE Internal(x: INTEGER);         (* not exported = NEAR by default *)
BEGIN ... END Internal;

PROCEDURE Ext*; EXTERNAL;               (* body in an external .rdf *)

PROCEDURE Fast*; INLINE(55H, 8BH, 0ECH); (* raw bytes at call site *)

PROCEDURE Forward*; FORWARD;            (* declared before body *)
```

- Exported procedures (`*`) are FAR (cross-module callable, `9A` CALL FAR).
- Non-exported procedures are NEAR by default (`E8` CALL NEAR, smaller + faster).
- `INLINE` procedures emit raw bytes at each call site; no stack frame.
- `FORWARD` allows mutual recursion within one module.
- **No uplevel access**: a nested procedure can only see module globals, imports, and its own locals/parameters. It cannot access the enclosing procedure's variables.
- **Calling convention**: Pascal (callee cleans). Args pushed left-to-right.

### 2.5 Control flow

```oberon
IF x > 0 THEN ...
ELSIF x = 0 THEN ...
ELSE ... END;

WHILE cond DO ...
ELSIF cond2 DO ... END;          (* Oberon-07 multi-branch WHILE *)

REPEAT ... UNTIL cond;

FOR i := 0 TO n-1 DO ... END;
FOR i := n-1 TO 0 BY -1 DO ... END;

CASE ch OF
  "A".."Z": ...
| "0".."9": ...
| 0X:       ...
ELSE ... END;
```

- `LOOP`/`EXIT` are **not supported**. Use `WHILE` with a BOOLEAN flag.
- No `WITH` statement.
- CASE selector must be INTEGER or CHAR. Labels accept constant expressions.

### 2.6 Arrays and records

```oberon
VAR a: ARRAY 10 OF INTEGER;         (* fixed, 10 elements *)
VAR m: ARRAY 4, 8 OF BYTE;          (* multi-dim: 4×8 = ARRAY 4 OF ARRAY 8 OF BYTE *)

TYPE Base    = RECORD x, y: INTEGER END;
TYPE Derived = RECORD (Base) z: INTEGER END;   (* record extension *)
```

- `LEN(a)` — element count (`WORD`); compile-time for fixed arrays, runtime for open-array params.
- `SIZE(T)` — byte size of type `T` (`WORD`).
- Open-array parameter: 6 bytes on stack — 4-byte far pointer + 2-byte length word.
- `IS` type test: `p IS Derived` — runtime check against the tag word embedded before each heap record.
- Implicit pointer dereference: `p.field` == `p^.field`, `p[i]` == `p^[i]`.

### 2.7 Module structure

```oberon
MODULE MyMod;
IMPORT Out, Strings;

CONST N* = 42;
TYPE  T* = RECORD x: INTEGER END;
VAR   g*: INTEGER;

PROCEDURE Run*;
BEGIN
  Out.Open;
  Out.String("hello"); Out.Ln
END Run;

BEGIN
  g := 0    (* module init body — runs once when first imported *)
END MyMod.
```

- `IMPORT SYSTEM` is a **compile error** — SYSTEM is always implicitly available.
- Module names must not contain underscores.
- Each module auto-generates `ModName__init` which runs the BEGIN body and calls imported modules' inits.

### 2.8 Compiler directives

```oberon
(*$M 8192, 131072, 262144*)   (* stack bytes, min heap bytes, max heap bytes *)
(*$R+*)                        (* enable runtime array bounds checking *)
(*$R-*)                        (* disable bounds checking (default) *)
(*$L path/to/extra.rdf*)       (* pack an extra .rdf into the .om *)
```

- `$M` is required in the module passed to `/ENTRY=`. Defaults: 8 KB stack, 128 KB min heap, 256 KB max heap.
- `$R` can appear multiple times; last one wins per source region.
- `$L` packs a hand-assembled RDOFF2 object alongside the compiled module's own code.

---

## 3. Memory model

### 3.1 Large model (CS ≠ DS ≠ SS)

```
CS = current module's code segment    (unique per module)
DS = combined data segment            (shared by all modules)
SS = stack segment                    (separate from DS and CS)
```

All three are distinct at all times. Maximum code per module: ~64 KB. Maximum total data: ~64 KB. Heap lives in separately-allocated paragraphs (one paragraph per `NEW` object).

### 3.2 Pointers

All `POINTER TO T` and `SYSTEM.ADDRESS` are 4-byte far pointers: `{offset word, segment word}`.

```
NIL = 0000:0000 (both words zero)
```

```oberon
NEW(p);           (* allocate; stores 2-byte tag word before p^ for IS checks *)
p^.field := 42;
p^.next := NIL;
DISPOSE(p);       (* free; does NOT set p to NIL *)
```

- `NEW(p, n)` — sized allocation: `n` bytes (for `SYSTEM.ADDRESS` targets or byte buffers).
- `p = NIL` compares both segment and offset — always use this form, never just offset.

### 3.3 FAR/NEAR calling convention

| Attribute | FAR (exported) | NEAR (internal) |
|-----------|---------------|-----------------|
| Call | `9A` CALL FAR + SEGRELOC | `E8` CALL NEAR rel16 |
| Epilogue | `RETF [n]` | `RET [n]` |
| First param | `[BP+6]` | `[BP+4]` |
| Proc-var size | 4 bytes (segment:offset) | 2 bytes (offset only) |

**VAR parameter:** caller pushes `{segment, offset}` = 4 bytes. Local vars use SS; globals use DS.

**Open-array parameter:** 6 bytes — 4-byte far address + 2-byte length word.

**Return values:**
- Scalar (BOOLEAN/CHAR/BYTE/INTEGER/WORD/SET) → AX
- LONGINT → DX:AX (lo in AX, hi in DX)
- POINTER/ADDRESS/FAR PROC → DX:AX (offset in AX, segment in DX)
- Records/arrays by value → hidden VAR param (callee writes through it)

**Callee-saved:** BP, SI, DI. **Scratch:** AX, BX, CX, DX, ES.

---

## 4. Module SYSTEM

Always implicitly available — never write `IMPORT SYSTEM`. All access via `SYSTEM.Name(...)`.

### 4.1 Types

```oberon
SYSTEM.ADDRESS    (* 4-byte far pointer; compatible with any POINTER TO T *)

SYSTEM.Registers  (* 18-byte RECORD for INT calls *)
  AX, BX, CX, DX, SI, DI, DS, ES, Flags: INTEGER

(* Flag constants *)
SYSTEM.FCarry = 1; SYSTEM.FParity = 4; SYSTEM.FAuxiliary = 16;
SYSTEM.FZero = 64; SYSTEM.FSign = 128; SYSTEM.FOverflow = 2048;
```

### 4.2 SYSTEM.Intr — software interrupts

```oberon
SYSTEM.Intr(IntNo: BYTE; VAR Regs: Registers)
```

Fill `Regs` with input values; read output values after the call. Always set `Regs.Flags := 0` before a call unless pre-setting carry is required.

```oberon
VAR r: SYSTEM.Registers;
r.AX := 4200H; r.Flags := 0;
SYSTEM.Intr(21H, r);
IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN (* error *) END;
```

### 4.3 Memory access

```oberon
SYSTEM.ADR(VAR v): SYSTEM.ADDRESS    (* far address of v; also: SYSTEM.ADR(ProcName) *)
SYSTEM.SEG(VAR v): INTEGER           (* segment register for v (SS/DS/heap) *)
SYSTEM.OFS(VAR v): INTEGER           (* offset of v within its segment *)
SYSTEM.PTR(seg, ofs: INTEGER): SYSTEM.ADDRESS  (* construct far pointer *)
SYSTEM.MOVE(VAR src, dst; n: WORD)   (* copy n bytes, any segment *)
SYSTEM.FILL(VAR dst; n: WORD; b: BYTE) (* fill n bytes with b *)
```

### 4.4 Bitwise intrinsics

```oberon
SYSTEM.LSL(x, n)   (* logical shift left;  result type = type of x *)
SYSTEM.LSR(x, n)   (* logical shift right, unsigned *)
SYSTEM.ASR(x, n)   (* arithmetic shift right, sign-extending *)
SYSTEM.ROR(x, n)   (* rotate right *)
SYSTEM.AND(x, y)   (* bitwise AND; result = widest of LONGINT > WORD > INTEGER *)
SYSTEM.IOR(x, y)   (* bitwise OR *)
SYSTEM.XOR(x, y)   (* bitwise XOR *)
SYSTEM.UCASE(c: CHAR): CHAR  (* ASCII upper-case (inline) *)
```

Works on BYTE, INTEGER, WORD, LONGINT. Always use the `SYSTEM.` prefix.

**Prefer `SYSTEM.AND` and `SYSTEM.LSR` over `MOD`/`DIV` for power-of-two splits** — the 32-bit software division loop is expensive on 8086:

```oberon
off := WORD(SYSTEM.AND(F.pos, LONGINT(BUFSIZE - 1)));  (* pos MOD 8192 — fast *)
tag := F.pos - off;                                     (* pos rounded down *)
```

> **Note:** the compiler already strength-reduces `*`, `DIV`, `MOD` by a **constant** power
> of two to shifts/AND automatically (e.g. `x * 8` → `SHL`, `x DIV 4` → `SAR`, `x MOD 16` →
> `AND`), and small constant multipliers (×3,×5,×6,×7,×9,…) to shift+add.  The manual
> `SYSTEM.AND` form above is only needed when the operand is a **runtime** value (as in
> `Files.BlockRead`'s `F.pos MOD BUFSIZE`).  See `docs/implementation-rules.md`
> §"Strength reduction & peephole optimizations".

### 4.5 I/O port access

```oberon
SYSTEM.PORTOUT(port: INTEGER; b: BYTE)    (* OUT DX, AL *)
SYSTEM.PORTIN(port: INTEGER; VAR b: BYTE) (* IN AL, DX *)
```

### 4.6 Heap diagnostics

```oberon
SYSTEM.MemAvail*(): WORD      (* total free heap paragraphs *)
SYSTEM.MemMaxAvail*(): WORD   (* largest contiguous free block in paragraphs *)
```

Walk the MEMHEADER free-list from `MemStartSeg`. Useful for detecting compile-phase leaks.

---

## 5. Standard library

After `make`, `bin/OBERON.OM` is the merged archive of all stdlib modules. `toc.exe` finds `OBERON.OM` automatically from its own directory (same as `bin/`), so `OBERON_LIB` is typically not needed.

### 5.1 Out — stdout output

```oberon
IMPORT Out;
Out.Open;                           (* call once before any output *)
Out.Char(ch: CHAR);
Out.String(s: ARRAY OF CHAR);       (* NUL-terminated *)
Out.Int(n: LONGINT; w: INTEGER);    (* right-justified in w chars *)
Out.Hex(n: INTEGER; w: INTEGER);
Out.Adr(p: SYSTEM.ADDRESS);         (* prints SSSS:OOOO *)
Out.Ln;                             (* CR+LF *)
```

### 5.2 Out87 — FPU output (requires x87)

```oberon
IMPORT Out87;
Out87.Open;                                          (* replaces Out.Open *)
Out87.Real(x: REAL; w: INTEGER);
Out87.LongReal(x: LONGREAL; w: INTEGER);
(* all Out.* procedures also available via Out87.* *)
```

### 5.3 In — stdin input

```oberon
IMPORT In;
In.Open;
In.Char(VAR c: CHAR);
In.Int(VAR i: INTEGER);
In.LongInt(VAR l: LONGINT);
In.String(VAR s: ARRAY OF CHAR);    (* whitespace-delimited token *)
```

### 5.4 Files — buffered file I/O

```oberon
IMPORT Files;
TYPE Files.File    (* opaque; pass by VAR; buffered (8 KB) on disk or EMS *)

(* Open / create / close *)
Files.Reset(VAR F: File; name: ARRAY OF CHAR): BOOLEAN     (* open existing *)
Files.ReWrite(VAR F: File; name: ARRAY OF CHAR): BOOLEAN   (* create/truncate *)
Files.Append(VAR F: File; name: ARRAY OF CHAR): BOOLEAN    (* open existing (seek to end) or create *)
Files.ReWriteTemp(VAR F: File): BOOLEAN                    (* anonymous temp: EMS-backed if available, else auto-named delete-on-close disk file *)
Files.SetDeleteOnClose(VAR F: File; delOnClose: BOOLEAN)
Files.Close(VAR F: File)

(* Block I/O — typeless VAR, works on any variable/buffer *)
Files.BlockRead(VAR F: File; VAR x; len: WORD): WORD
Files.BlockWrite(VAR F: File; VAR x; len: WORD): WORD
Files.BlockCopy(VAR src, dst: File; len: LONGINT): BOOLEAN  (* copy len bytes src->dst via internal buffer *)

(* Fixed-width scalar I/O (little-endian) *)
Files.WriteByte(VAR F: File; b: BYTE): WORD
Files.WriteWord(VAR F: File; w: INTEGER): WORD
Files.WriteDWord(VAR F: File; w: LONGINT): WORD
Files.ReadByte(VAR F: File; VAR b: BYTE): BOOLEAN           (* FALSE at EOF *)
Files.ReadWord(VAR F: File; VAR w: INTEGER)
Files.ReadDWord(VAR F: File; VAR w: LONGINT)

(* Text I/O *)
Files.ReadAsciizString(VAR f: File; VAR dst: ARRAY OF CHAR) (* reads to NUL byte in the file *)
Files.ReadLine(VAR f: File; VAR buf: ARRAY OF CHAR; maxLen: WORD): WORD  (* strips CR/LF; returns length *)
Files.Write(VAR f: File; line: ARRAY OF CHAR): WORD         (* NUL-terminated string, no newline *)
Files.WriteLn(VAR f: File): WORD                            (* CR+LF *)
Files.WriteLine(VAR f: File; line: ARRAY OF CHAR): WORD     (* Write + WriteLn *)

(* Position / size *)
Files.Seek(VAR F: File; pos: LONGINT)
Files.Position(VAR F: File): LONGINT
Files.Size(VAR F: File): LONGINT
Files.Truncate(VAR F: File)                                 (* truncate at current position *)

(* Whole-file / path operations *)
Files.Delete(FileName: ARRAY OF CHAR): BOOLEAN
Files.Rename(OldName, NewName: ARRAY OF CHAR): BOOLEAN
Files.Copy(src, dst: ARRAY OF CHAR): BOOLEAN                (* whole-file copy *)
Files.FileExists(FileName: ARRAY OF CHAR): BOOLEAN
Files.ReplaceExt(path: ARRAY OF CHAR; newExt: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)  (* "OSTRIP.OM"+".BAK" -> "OSTRIP.BAK" *)

(* Timestamps (DOS directory entry time, see Time module) *)
Files.GetFTime(VAR f: File; VAR time: Time.DosTime)
Files.SetFTime(VAR f: File; time: Time.DosTime)
```

Read loop:
```oberon
VAR f: Files.File; b: BYTE; n: WORD;
IF Files.Reset(f, "data.bin") THEN
  n := Files.BlockRead(f, b, 1);
  WHILE n > 0 DO
    (* process b *)
    n := Files.BlockRead(f, b, 1)
  END;
  Files.Close(f)
END;
```

`ReWriteTemp` is the preferred way to get scratch storage: it prefers an
EMS-backed buffer (freed automatically on `Close`, never touches disk) and
falls back to a hidden auto-named `<nnnnnnnn>.TMP` disk file with
`delOnClose` set. Both backends share the same buffered read/write path, so
every other `Files` procedure works identically on either.

### 5.5 Strings — string operations

```oberon
IMPORT Strings;

(* Length, comparison *)
Strings.Length(s: ARRAY OF CHAR): INTEGER
Strings.Equal(a, b: ARRAY OF CHAR): BOOLEAN           (* case-sensitive; hot path, INLINE *)
Strings.EqualICase(a, b: ARRAY OF CHAR): BOOLEAN
Strings.StartsWith(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN
Strings.EndsWith(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN
Strings.HashCode(str: ARRAY OF CHAR): WORD            (* INLINE hash, for hash-table keys *)
Strings.Pos(pat, s: ARRAY OF CHAR; pos: INTEGER): INTEGER   (* -1 if not found *)

(* Copy / build *)
Strings.Copy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)
Strings.Append(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR)
Strings.Insert(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)
Strings.Delete(VAR s: ARRAY OF CHAR; pos, n: INTEGER)
Strings.Replace(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR)
Strings.Extract(VAR src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR)

(* Number <-> string *)
Strings.Str(src: LONGINT; VAR dst: ARRAY OF CHAR)             (* signed decimal *)
Strings.Val(VAR s; VAR startFrom: WORD): LONGINT              (* parses leading int, advances startFrom *)
Strings.AppendInt(val: LONGINT; VAR str: ARRAY OF CHAR)
Strings.ByteToHexStr(val: BYTE; VAR str: ARRAY OF CHAR)       (* 2 hex digits *)
Strings.WordToHexStr(val: WORD; VAR str: ARRAY OF CHAR)       (* 4 hex digits *)
Strings.AppendHexByte(val: BYTE; VAR str: ARRAY OF CHAR)
Strings.AppendHexWord(val: WORD; VAR str: ARRAY OF CHAR)
```

### 5.6 IO — raw rider-based I/O

```oberon
IMPORT IO;
TYPE IO.Rider   (* bound to a DOS file handle *)
IO.StdOut(VAR r: Rider);
IO.StdErr(VAR r: Rider);
IO.OpenHandle(VAR r: Rider; h: INTEGER);
IO.ReadChar(VAR r: Rider; VAR ch: CHAR);
IO.WriteChar(VAR r: Rider; ch: CHAR);
IO.WriteStr(VAR r: Rider; s: ARRAY OF CHAR);
IO.WriteInt(VAR r: Rider; n: LONGINT);
IO.WriteLn(VAR r: Rider);
```

### 5.7 Mem — raw heap allocation

```oberon
IMPORT Mem;
Mem.Alloc(size: WORD): SYSTEM.ADDRESS   (* NIL on failure *)
Mem.Free(p: SYSTEM.ADDRESS)
```

Use `NEW`/`DISPOSE` for typed objects. `Mem` is for raw byte buffers or DOS memory functions.

### 5.8 Dos — DOS system interface

```oberon
IMPORT Dos;
TYPE Dos.Registers = SYSTEM.Registers   (* alias *)
TYPE Dos.DateTime = RECORD Year, Month, Day, Hour, Min, Sec: INTEGER END;
TYPE Dos.SearchRec = RECORD fill: ARRAY 21 OF BYTE; attr: BYTE;
                            time, size: LONGINT; name: ARRAY 13 OF CHAR END;

(* File attribute constants *)
Dos.ReadOnly=01H; Dos.Hidden=02H; Dos.SysFile=04H;
Dos.Directory=10H; Dos.Archive=20H; Dos.AnyFile=3FH;
Dos.DosError*: WORD;     (* 0 = success; DOS error code on failure *)
Dos.DosExitCode*: WORD;  (* exit code from last Exec *)

Dos.Intr(IntNo: BYTE; VAR Regs: Registers)         (* execute interrupt *)
Dos.MsDos(VAR Regs: Registers)                      (* INT 21h shorthand *)
Dos.ParamCount(): INTEGER
Dos.ParamStr(i: INTEGER; VAR p: ARRAY OF CHAR)      (* 0=program name *)
Dos.GetEnv(envvar: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR)
Dos.FindFirst(Path: ARRAY OF CHAR; Attr: BYTE; VAR S: SearchRec)
Dos.FindNext(VAR S: SearchRec)
Dos.GetDate(VAR Year, Month, Day, DayOfWeek: INTEGER)
Dos.SetDate(Year, Month, Day: INTEGER)
Dos.GetTime(VAR Hour, Minute, Second, Sec100: INTEGER)
Dos.DiskFree(Drive: BYTE): LONGINT                  (* 0=current, 1=A:, ... *)
Dos.DiskSize(Drive: BYTE): LONGINT
Dos.MkDir(Path: ARRAY OF CHAR): BOOLEAN
Dos.ChDir(Path: ARRAY OF CHAR): BOOLEAN
Dos.FExpand(Path: ARRAY OF CHAR; VAR Dest: ARRAY OF CHAR)
Dos.FSplit(Path: ARRAY OF CHAR; VAR Dir, Name, Ext: ARRAY OF CHAR)
Dos.GetIntVec(IntNo: BYTE; VAR Vector: SYSTEM.ADDRESS)
Dos.SetIntVec(IntNo: BYTE; Vector: SYSTEM.ADDRESS)
Dos.Exec(Path, CmdLine: ARRAY OF CHAR)
Dos.GetPsp(): INTEGER
```

### 5.9 Time — DOS date/time conversion

```oberon
IMPORT Time;
TYPE Time.DateTime = RECORD Year, Month, Day, Hour, Min, Sec: WORD END;
TYPE Time.DosTime  = LONGINT;    (* packed DOS date/time, e.g. FindFirst/Files timestamps *)
TYPE Time.UnixTime = LONGINT;    (* seconds since 1970-01-01 *)

Time.PackTime(VAR t: DateTime; VAR p: DosTime)
Time.UnpackTime(p: DosTime; VAR t: DateTime)
Time.IsLeap(y: WORD): BOOLEAN
Time.DaysInMonth(y, m: WORD): WORD
Time.DayOfWeek(y, m, d: WORD): BYTE          (* 0=Sunday .. 6=Saturday, Sakamoto's algorithm *)
Time.DosToUnixTime(d: DosTime): UnixTime
Time.UnixToDosTime(u: UnixTime): DosTime
Time.NowDateTime(VAR t: DateTime)            (* reads INT 21h AH=2Ah/2Ch *)
Time.Now(): DosTime                          (* current time, packed *)
Time.SecondsBetween(d1, d2: DosTime): LONGINT  (* d2 - d1, in seconds *)
```

### 5.10 Test — unit test framework

```oberon
IMPORT Test;
TYPE Test.TestProc = PROCEDURE FAR   (* must be exported * and FAR *)

Test.AddTest(t: TestProc; name: ARRAY OF CHAR)   (* register, max 128 *)
Test.RunTests                                      (* run all; prints Total/Passed/Failed; exits 0 or 1 *)

Test.AssertTrue(cond: BOOLEAN; msg: ARRAY OF CHAR)
Test.AssertFalse(cond: BOOLEAN; msg: ARRAY OF CHAR)
Test.AssertInt(expected, actual: INTEGER; msg: ARRAY OF CHAR)
Test.AssertWord(expected, actual: WORD; msg: ARRAY OF CHAR)
Test.AssertLong(expected, actual: LONGINT; msg: ARRAY OF CHAR)
Test.AssertByte(expected, actual: BYTE; msg: ARRAY OF CHAR)
Test.AssertStr(expected, actual: ARRAY OF CHAR; msg: ARRAY OF CHAR)
Test.AssertReal(expected, actual: REAL; msg: ARRAY OF CHAR)
Test.AssertLongReal(expected, actual: LONGREAL; msg: ARRAY OF CHAR)
Test.AssertNil(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR)
Test.AssertNotNil(p: SYSTEM.ADDRESS; msg: ARRAY OF CHAR)
```

Requires `Out87` and `Math` in the link (via `OBERON.OM`).

```oberon
MODULE MyTest;
IMPORT Test;

PROCEDURE TAdder*;
BEGIN Test.AssertInt(4, 2+2, "2+2") END TAdder;

PROCEDURE RunAllTests*;
BEGIN Test.AddTest(TAdder, "adder"); Test.RunTests END RunAllTests;

END MyTest.
```

Build: `xt run --max=50000000 -c . bin/toc.exe /ENTRY=RunAllTests MyTest.Mod`

### 5.11 Math — FPU math functions

```oberon
IMPORT Math;
Math.sin(x: LONGREAL): LONGREAL
Math.cos(x: LONGREAL): LONGREAL
Math.sqrt(x: LONGREAL): LONGREAL
Math.exp(x: LONGREAL): LONGREAL
Math.ln(x: LONGREAL): LONGREAL
Math.Abs(x: LONGREAL): LONGREAL
(* ... and more *)
```

### 5.12 Crt — terminal control

```oberon
IMPORT Crt;
Crt.ClrScr;
Crt.GotoXY(x, y: INTEGER);
Crt.TextColor(color: INTEGER);
Crt.TextBackground(color: INTEGER);
(* Uses DOS INT 10h *)
```

### 5.13 EMS — expanded memory (LIM EMS 4.0)

```oberon
IMPORT EMS;
EMS.Present(): BOOLEAN                                    (* EMM driver installed? *)
EMS.Version(): BYTE                                       (* e.g. 40H for 4.0 *)
EMS.RequireVersion(ver: BYTE)                             (* fatal error if below ver *)

EMS.Alloc(sizeKB: WORD; VAR handle: WORD): BOOLEAN        (* allocate EMS pages *)
EMS.Realloc(VAR handle: WORD; newSizeKB: WORD): BOOLEAN
EMS.Free(handle: WORD): BOOLEAN

EMS.MapPage(handle, logicalPage, physicalPage: WORD): BOOLEAN
EMS.UnmapPage(physicalPage: WORD): BOOLEAN
EMS.MapPtr(handle: WORD; emsOffset: LONGINT; physWin: WORD): SYSTEM.ADDRESS

EMS.CopyToEMS(VAR dosBuf; handle: WORD; emsOffset, len: LONGINT)
EMS.CopyToDos(handle: WORD; emsOffset: LONGINT; VAR dosBuf; len: LONGINT)

EMS.GetError(): WORD
```

Used internally by `Files.ReWriteTemp` for the EMS-backed temp-file backend
(see §5.4); most programs only need `Files`, not `EMS`, directly.

### 5.14 RdfLoad — runtime RDOFF2 loader

```oberon
IMPORT RdfLoad;
TYPE RdfLoad.RDFModule    (* opaque handle to a loaded .rdf module *)
TYPE RdfLoad.Resolver = PROCEDURE(name: ARRAY OF CHAR): SYSTEM.ADDRESS;

RdfLoad.LoadLibrary(fileName: ARRAY OF CHAR): RDFModule
RdfLoad.LoadLibraryWith(fileName: ARRAY OF CHAR; resolve: Resolver): RDFModule
RdfLoad.GetProcAddress(module: RDFModule; name: ARRAY OF CHAR): SYSTEM.ADDRESS
RdfLoad.FreeLibrary(module: RDFModule)
```

Loads a standalone `.rdf` object file at run time (relocating code/data
segments, applying import fixups via the supplied `Resolver`) and returns
callable procedure addresses — dynamic code loading without going through
`toc.exe`/the linker. See `examples/RDFLOAD/` for a worked example.

---

## 6. Assembly interop

Pack hand-assembled RDOFF2 code into an `.om` archive alongside Oberon-compiled code:

1. Write assembly source and produce a `.rdf` file (NASM with RDOFF2 output).
2. Declare `EXTERNAL` procedures in the Oberon wrapper module.
3. Use `$L` to pack the `.rdf` into the output `.om`.

```oberon
MODULE MyLib;

PROCEDURE FastMove*(VAR src, dst; n: INTEGER); EXTERNAL;
(*$L FASTMOV.RDF*)

END MyLib.
```

Compile: `xt run --max=50000000 -c . bin/toc.exe MyLib.Mod`

The produced `MyLib.om` contains both the Oberon-generated code (just the EXTERNAL stubs) and your hand-assembled `FASTMOV.RDF`. Any module that `IMPORT MyLib` and calls `MyLib.FastMove` will link against your assembly.

---

## 7. Porting tips

1. Replace `int` / `int32_t` → `LONGINT`; `short` / `int16_t` → `INTEGER`; `uint16_t` → `WORD`; `uint8_t` → `BYTE`.
2. Replace `malloc`/`free` with `NEW`/`DISPOSE` (typed) or `Mem.Alloc`/`Mem.Free` (raw bytes).
3. Replace bitwise `&`, `|`, `^`, `<<`, `>>` with `SYSTEM.AND`, `SYSTEM.IOR`, `SYSTEM.XOR`, `SYSTEM.LSL`, `SYSTEM.LSR`.
4. Replace `break` with a BOOLEAN done-flag: `WHILE cond & ~done DO ... IF exit THEN done := TRUE END END`.
5. Replace `continue` by inverting the condition: `WHILE cond DO IF ~skip THEN body END END`.
6. No early return from procedures — restructure with IF/ELSIF or a flag.
7. No `LOOP`/`EXIT` — use `WHILE`.
8. No exceptions — use return values or a module-level error variable.
9. No dynamic strings — use `ARRAY N OF CHAR` with a chosen max length.
10. No `printf` — use `Out.String`, `Out.Int`, `Out.Ln` etc.
11. No `union` / `SYSTEM.VAL` — use typed pointer trick or `SYSTEM.MOVE`.
12. No recursion deeper than ~100 frames (8 KB default stack) — convert to iteration.
13. File names must be 8.3 DOS format. Module names ≤ 8 characters.
14. Each module's code must fit in ~64 KB; data likewise.
15. Use `SYSTEM.AND`/`SYSTEM.LSR` instead of `MOD`/`DIV` for power-of-two byte extraction — the 32-bit software division loop is expensive on 8086.

---

## 8. Complete example

```oberon
MODULE Lines;
IMPORT Out, Files;

PROCEDURE Run*;
  VAR f: Files.File; ch: CHAR; buf: ARRAY 256 OF CHAR;
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
      buf[i] := 0X; Out.String(buf); Out.Ln; i := 0
    ELSIF ch # 0DX THEN
      buf[i] := ch; INC(i)
    END;
    n := Files.BlockRead(f, ch, 1)
  END;
  IF i > 0 THEN buf[i] := 0X; Out.String(buf); Out.Ln END;
  Files.Close(f)
END Run;

END Lines.
```

Build and run:
```bash
export OBERON_LIB="C:\lib"
xt run --max=50000000 -c . bin/toc.exe /ENTRY=Run Lines.Mod
xt run --max=10000000 -c . lines.exe
```

On real MS-DOS:
```
SET OBERON_LIB=C:\lib
toc.exe /ENTRY=Run Lines.Mod
lines.exe
```
