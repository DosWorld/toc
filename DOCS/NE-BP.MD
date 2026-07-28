# Borland Pascal 7.0 `/CP` (DPMI16) New-Executable format — reverse-engineered

> **STRONG RULE: DOCS/NE-BP.MD IS A READ-ONLY FILE.** This is authoritative
> reverse-engineered reference material. Do NOT edit, rewrite, or "align" it to
> any implementation. Reference only.

**What this documents.** How Borland Pascal 7.0's `/CP` target (16-bit DPMI
protected mode, stored in an **NE** container) lays out its executables, derived
byte-for-byte from real BPC output: `OS2NE/1/H.EXE`, `OS2NE/2/T.EXE`
(hello-world / two-unit), and especially `OS2NE/3/NEBIG.EXE` (a multi-unit
feature-stress program). This is the concrete, empirical companion to the
generic spec in [NE.MD](NE.MD) (which is read-only) — it records exactly what
BPC emits, so we can generate NE files with the same structure.

> **`/CP` is NOT OS/2-API programming.** It produces a plain 16-bit DPMI
> protected-mode program in an NE wrapper. The header's Target-OS byte is `01h`
> (OS/2) and the sole module reference is **`KERNEL`**, but `KERNEL` here is
> BPC's own DPMI **runtime** — not the OS/2 API. A `/CP` program makes no OS/2
> system calls; its only external imports are into that runtime kernel, by
> ordinal.

---

## 1. Overall file shape

```
+-------------------+  0x0000
|  MZ stub (real)   |   3646 bytes, byte-identical across all BPC /CP outputs
|                   |   (carries "16STUB" at 0x200 + real DOS stub code)
+-------------------+  0x0E3E  = e_lfanew (fixed)
|  NE header (64 B) |
+-------------------+  +0x40
|  segment table    |   segCount * 8 bytes
+-------------------+
|  resource table   |   present but empty: alignShift WORD + 0000 terminator
+-------------------+
|  resident names   |   module name (ord 0) + 00 terminator
+-------------------+
|  module ref table |   modRefCount * 2 bytes (each = offset into imp-names)
+-------------------+
|  imported names   |   00 <counted strings...>  (leading 00 = terminator@0)
+-------------------+
|  entry table      |   4 zero bytes (empty — see §6)
+-------------------+
|  nonresident names|   "STEM.EXE" (ord 0) + 00 terminator  (at file offset)
+-------------------+  (padded to sector)
|  seg1 data+relocs |   each segment: raw bytes, then <count WORD><8*count>
|  seg2 data+relocs |
|  seg3 data        |   (DATA/DGROUP; no relocs here in these samples)
+-------------------+
```

`e_lfanew` is always **`0x0E3E`** because the MZ stub is a fixed 3646-byte blob.

---

## 2. NE header (measured, all three samples)

| Field | Offset | H.EXE | T.EXE | NEBIG.EXE | Notes |
|---|---|---|---|---|---|
| Signature | 00 | `NE` | `NE` | `NE` | |
| Linker version | 02 | 6.1 | 6.1 | 6.1 | major=6, minor=1 |
| Entry-table offset | 04 | 0x73 | 0x73 | 0x77 | from NE header start |
| Entry-table length | 06 | 4 | 4 | 4 | empty table (§6) |
| File-load CRC | 08 | 0 | 0 | 0 | BPC leaves 0 |
| **Program flags** | 0C | `0x0A` | `0x0A` | `0x0A` | DGROUP=multiple(10) + prot-mode-only(bit3). 8086/286/386/87 bits all clear |
| **Application flags** | 0D | `0x03` | `0x03` | `0x03` | app-type=011 (uses P.M. API) |
| **Auto-data seg idx** | 0E | 3 | 3 | 3 | 1-based → the DGROUP DATA segment |
| Initial local heap | 10 | 0 | 0 | 0 | |
| Initial stack size | 12 | 0 | 0 | 0 | (SP set explicitly, see below) |
| **Entry CS:IP** | 14 | 1:0x0F | 1:0x02 | 1:0x02 | CS = seg index (1), IP = offset in seg1 |
| **Initial SS:SP** | 18 | 4:0x4000 | 4:0x4000 | 4:0x4000 | SS = the auto/stack segment (seg 4), SP = 0x4000 |
| **Segment count** | 1C | 4 | 4 | 4 | see §3 — BP7 uses a FIXED 4-segment model |
| **Module-ref count** | 1E | 1 | 1 | 1 | the single KERNEL runtime import |
| Nonresident-names len | 20 | 9 | 9 | 13 | = 1+len(stem+".EXE")+2+1 |
| Segment-table offset | 22 | 0x40 | 0x40 | 0x40 | |
| Resource-table offset | 24 | 0x60 | 0x60 | 0x60 | present, empty |
| Resident-names offset | 26 | 0x64 | 0x64 | 0x64 | |
| Module-ref-tbl offset | 28 | 0x69 | 0x69 | 0x6D | |
| Imported-names offset | 2A | 0x6B | 0x6B | 0x6F | |
| Nonresident-names ofs | 2C | 0xEB5 | 0xEB5 | 0xEB9 | **file** offset (not NE-relative) |
| Moveable-entry count | 30 | 0 | 0 | 0 | |
| **File-align shift** | 32 | 8 | 8 | 8 | → 256-byte sectors (1<<8) |
| Resource-tbl entries | 34 | 0 | 0 | 0 | |
| **Target OS** | 36 | 1 | 1 | 1 | OS/2 (the DPMI runtime kernel is "KERNEL") |
| Other-EXE flags | 37 | 0 | 0 | 0 | |
| Return thunks | 38 | 0 | 0 | 0 | |
| Seg-ref thunks | 3A | 0 | 0 | 0 | |
| Min code-swap area | 3C | 0 | 0 | 0 | |
| **Expected version** | 3E | 0x0300 | 0x0300 | 0x0300 | 3.0 |

**Header constants to reproduce:** linkver `6.1`, progFlags `0x0A`, appFlags
`0x03`, autoData `3`, alignShift `8`, targetOS `1`, expVer `0x0300`, heap/stack
size fields `0`, SS:SP = `4:0x4000`. Everything else is derived from the image.

---

## 3. Segment table — a FIXED 4-segment model

BPC `/CP` emits **exactly 4 segments regardless of program size** (H, T, and the
multi-unit NEBIG all show 4). It packs all user+unit code into segments and uses
a DGROUP data segment + an auto/stack segment:

| Seg | Kind | Role | Attr | Notes |
|---|---|---|---|---|
| 1 | CODE | main + first code | `0x1D10` | MOVEABLE + RELOCS + DISCARD + DPL=3, **no PRELOAD** |
| 2 | CODE | runtime/library code | `0x0D40` | PRELOAD + RELOCS + DPL=3 |
| 3 | DATA | DGROUP (initialised + reserved) | `0x0C41` | DATA + PRELOAD + DPL=3 |
| 4 | DATA | auto-data / stack | `0x0C41` | DATA + PRELOAD + DPL=3; fileoff=0, len=0, min=0x4000 |

Segment-table entry = `fileOfsSectors(2) fileLen(2) attr(2) minAlloc(2)`.

**Attribute bits (measured):**
- `0x0001` DATA, `0x0010` MOVEABLE, `0x0040` PRELOAD, `0x0100` HAS-RELOCS,
  `0x0C00` **DPL=3 (bits 10-11, set on EVERY segment)**, `0x1000` DISCARD.
- CODE seg1 = `0x1D10` (MOVEABLE|RELOCS|DISCARD|DPL). CODE seg2 = `0x0D40`
  (PRELOAD|RELOCS|DPL). DATA = `0x0C41` (DATA|PRELOAD|DPL).

**`minAlloc` (offset 6) can far exceed the file length** — it reserves the
uninitialised DGROUP/BSS tail. NEBIG seg3: fileLen `0x460`, **minAlloc
`0xAB52`** (all those `var` arrays). Seg4 (stack): fileLen `0`, fileOfs `0`,
minAlloc `0x4000` — allocated, never stored.

**File offset field is in SECTORS** (×256). A `fileOfs` of `0` means "no file
data" (the stack segment). Segment raw data is sector-aligned in the file.

---

## 4. Relocations — THE key section

Each relocated segment has `HAS-RELOCS` (attr bit 8) set and stores, immediately
after its raw data:

```
<count: WORD> <count × 8-byte relocation record>
```

**8-byte relocation record:**

| Off | Size | Field | Meaning |
|---|---|---|---|
| 0 | 1 | **source type** | `00`=LOBYTE, `02`=BASE(segment), `03`=PTR(16:16), `05`=OFFS(16), `0B`=PTR48, `0D`=OFFS32 |
| 1 | 1 | **flags** | bits 0-1 = **target type**; bit 2 = **additive**; see below |
| 2 | 2 | **site offset** | offset within THIS segment of the word(s) to fix up |
| 4 | 2 | **target seg / modref** | internal: 1-based segment index; import: module-ref index |
| 6 | 2 | **target offset / ordinal** | internal: offset in target seg; import-ord: ordinal; import-name: offset into imported-names |

**Flags byte (bits 0-1 = target type):**
- `00` **INTERNALREF** — target is a segment in THIS module. `w4` = 1-based
  segment index, `w6` = offset in that segment.
- `01` **IMPORTORDINAL** — external import by ordinal. `w4` = module-ref index
  (e.g. `1` = KERNEL), `w6` = **ordinal** in that module.
- `02` **IMPORTNAME** — external import by name. `w4` = module-ref index,
  `w6` = offset into the imported-names table of the symbol string. *(Not
  emitted by these samples — BPC's runtime imports are all by ordinal.)*
- `03` OSFIXUP.
- bit 2 (`0x04`) **ADDITIVE** — add the fixup to the existing value instead of
  replacing. *(Not used by these samples — every record here is 00 or 01.)*

**Placeholder convention (measured, universal): every relocated word in the file
holds `FFFF`; the loader writes the real value.** BPC does NOT bake resolved
addresses. Specifically:
- **OFFS** (single word): the word = `FFFF`.
- **BASE** (single segment word): the word = `FFFF`.
- **PTR** (two words, offset:segment): **offset word = `FFFF`, segment word =
  `0000`**. One PTR record covers both words; its `site offset` points at the
  offset word.

**One record per site — no fixup chains.** Where several sites reference the same
target (e.g. many OFFS records to KERNEL ord 114), BPC emits a **separate
8-byte record for each site**. It does NOT use the placeholder-as-linked-list
chain form. (The generic spec allows chains via a non-`FFFF` placeholder that
points at the next site; BPC does not use it here.)

**Types actually emitted by BPC `/CP` (from NEBIG):** `02` BASE, `03` PTR,
`05` OFFS. LOBYTE/OFFS32/PTR48 did not appear.

### 4.1 Reloc examples (NEBIG.EXE seg1/seg2)

```
seg1 [0] PTR  flag=01(IMPORTORD)  site=0x003  -> MODREF#1 (KERNEL) ord=91
seg1 [1] PTR  flag=00(INTERNAL)   site=0x008  -> seg2:0x007
seg1 [5] BASE flag=00(INTERNAL)   site=0x024  -> seg1:0x336   (SEG of a symbol)
seg2 [0] BASE flag=00(INTERNAL)   site=0x008  -> seg3:0x000   (load DGROUP seg)
seg2 [1] OFFS flag=01(IMPORTORD)  site=0x039  -> MODREF#1 (KERNEL) ord=114
seg2 [12]BASE flag=00(INTERNAL)   site=0x3EE  -> seg2:0x6A0   (self-segment SEG)
```

- **PTR internal** (`seg2:0x7`) — a far call to another code segment; the
  loader writes {offset=0x7, segment=selector-of-seg2}.
- **PTR import-ordinal** — a far call into KERNEL by ordinal; loader resolves
  via the module-reference table.
- **BASE internal** — a segment-only fixup (e.g. `MOV reg, SEG X` / building a
  far pointer / loading DGROUP). `w6` is the target's offset for a self-segment
  reference (BPC records it even though only the segment word is patched), `0`
  for a pure DGROUP-selector load.
- **OFFS import-ordinal** — a 16-bit offset fixup into an imported routine.

---

## 5. Import / module-reference tables

- **Module Reference Table** (`modRefTblOfs`): `modRefCount` × WORD. Each WORD
  is an **offset into the Imported Names Table** of that module's name. NEBIG:
  count 1, entry `0x0001` → "KERNEL".
- **Imported Names Table** (`impNamesOfs`): `00` then counted strings.
  NEBIG raw: `00 06 "KERNEL" 00`. **The leading `00` is the length-0 entry at
  offset 0** (the terminator convention). Module-ref offsets are relative to the
  table start, so offset `1` = the `06 "KERNEL"` string. Import-by-ordinal
  relocations reference the module (via modref index), NOT a string, so only the
  module name "KERNEL" appears here — individual imported routines are named
  only by ordinal.

`KERNEL` is BPC's DPMI runtime. **Every external call in a `/CP` image is an
IMPORTORDINAL fixup into KERNEL**; the ordinals seen in NEBIG include 91
(the very first call = task init), 114, 174, 181, 182, 193, 229 (RTL entry
points).

---

## 6. Name tables & entry table

- **Resident Names** (`resNamesOfs`): first (only) entry = the module name =
  the `.exe` stem, uppercased 8.3 ("NEBIG"), ordinal 0, then `00` terminator.
  Format per entry: `len(1) name(len) ordinal(2)`.
- **Nonresident Names** (`nrNamesOfs`, a **file** offset): first entry = the
  `.exe` filename ("NEBIG.EXE"), ordinal 0, then `00`. `nrNamesLen` in the
  header = the whole table's byte length.
- **Entry Table** (`entryTblOfs`, len 4): **four zero bytes** in all samples.
  BPC exports nothing at the NE level for a program, so the table is a single
  empty terminating bundle padded to 4 bytes. The program entry point comes
  solely from the header CS:IP.
- **Resource Table** (`resTblOfs`): present but empty — `alignShift` WORD then a
  `0000` type terminator (`08 00 00 00`).

---

## 7. Entry / startup sequence (seg1 head)

Entry is CS=1, IP=2. Seg1 starts:

```
offset 0x00:  01 00                 ; 2 bytes of data before the entry point
offset 0x02:  9A FF FF 00 00        ; CALL FAR KERNEL.ord91  (external, INITTASK)
                                    ;   PTR reloc @0x03: IMPORTORD modref1 ord=91
offset 0x07:  9A FF FF 00 00        ; CALL FAR seg2:0x7      (internal runtime init)
                                    ;   PTR reloc @0x08: INTERNAL seg2:0x7
offset 0x0C:  55                    ; PUSH BP
offset 0x0D:  89 E5                 ; MOV BP,SP
offset 0x0F:  31 C0                 ; XOR AX,AX
offset 0x11:  9A FF FF 00 00        ; CALL FAR ...           (more init/unit calls)
...
```

**The program's FIRST executed instruction is an EXTERNAL far call to
`KERNEL` ordinal 91** — the runtime task-init ("INITTASK"). Its operand is the
`FFFF:0000` placeholder; the IMPORTORDINAL PTR reloc supplies {modref=1,
ordinal=91} and the loader patches the real far address. This is the same
`0x5B`(=91) value the H.EXE reference shows — it is an **ordinal**, not a
segment offset. After it, the second far call is an INTERNAL call into seg2
(runtime setup), then the Pascal init/unit-init calls follow.

---

## 8. What "generate the same structure" requires

To emit a BPC-identical `/CP` NE, a linker must:
1. Copy the fixed 3646-byte MZ stub (→ `e_lfanew = 0x0E3E`).
2. Write the header constants from §2.
3. Emit the segment table with the §3 attributes (DPL bits on every segment;
   CODE `0x1D10`/`0x0D40`, DATA `0x0C41`), file offsets in 256-byte sectors,
   and `minAlloc` covering the uninitialised DGROUP/stack tail.
4. Emit the KERNEL module reference + imported-names `00 06 "KERNEL"`.
5. Emit resident (module) and nonresident (`STEM.EXE`) name tables, empty
   resource + entry tables.
6. For every fixup, write an 8-byte reloc record and leave the site as an
   `FFFF` (PTR: `FFFF`/`0000`) placeholder — **do not bake**:
   - internal code/data reference → flags `00`, `{segIndex, offset}`;
   - runtime call → flags `01` (IMPORTORDINAL), `{modref=1(KERNEL), ordinal}`;
   - one record per site (no chains).
7. Make the entry point's first instruction an external far call to
   `KERNEL` ord 91 (task init).

**Open/irrelevant for us:** BPC also uses fixed 4 segments (user code / runtime
code / DGROUP / stack); our Oberon toolchain keeps its own per-module segment
model, so segment *count* will differ even though every per-segment field and
reloc-record encoding matches this document. LOBYTE/OFFS32/PTR48 reloc types and
the additive (`0x04`) and IMPORTNAME (`0x02`) flag forms are defined by the
format but not emitted by BPC `/CP`, so we need not generate them.
