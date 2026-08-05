# NE (New Executable) / DPMI16 — reference format + this project's implementation

This is the single source of truth for the `/CP` (DPMI16 protected-mode, NE
container) build target: what Borland Pascal 7.0 actually emits (the
empirical reference we match against), and what this project's own linker
(`SRC/TOC/LINKNE.MOD`) does, including where it deliberately differs and
what real-hardware bugs were found and fixed getting here.

See also: [NE.MD](NE.MD) — the generic NE file-format specification
(read-only, format-agnostic background reading).

> **`/CP` is NOT OS/2-API programming.** It produces a plain 16-bit DPMI
> protected-mode program in an NE wrapper. The header's Target-OS byte is
> `01h` (OS/2) and the sole module reference is **`KERNEL`**, but `KERNEL`
> here is BPC's own DPMI **runtime** — not the OS/2 API. A `/CP` program
> makes no OS/2 system calls; its only external imports are into that
> runtime kernel, by ordinal.

---

## Part 1 — The Borland Pascal reference (empirical, byte-exact)

Derived byte-for-byte from real BPC `/CP` output: `OS2NE/1/H.EXE`,
`OS2NE/2/T.EXE` (hello-world / two-unit), and especially
`OS2NE/3/NEBIG.EXE` (a multi-unit feature-stress program). This is the
concrete target structure this project's linker matches against.

### 1.1 Overall file shape

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
|  entry table      |   4 zero bytes (empty — see §1.6)
+-------------------+
|  nonresident names|   "STEM.EXE" (ord 0) + 00 terminator  (at file offset)
+-------------------+  (padded to sector)
|  seg1 data+relocs |   each segment: raw bytes, then <count WORD><8*count>
|  seg2 data+relocs |
|  seg3 data        |   (DATA/DGROUP; no relocs here in these samples)
+-------------------+
```

`e_lfanew` is always **`0x0E3E`** in the BPC reference because its MZ stub is
a fixed 3646-byte blob. (Our own stub differs in size — see Part 2.)

### 1.2 NE header (measured, all three samples)

| Field | Offset | H.EXE | T.EXE | NEBIG.EXE | Notes |
|---|---|---|---|---|---|
| Signature | 00 | `NE` | `NE` | `NE` | |
| Linker version | 02 | 6.1 | 6.1 | 6.1 | major=6, minor=1 |
| Entry-table offset | 04 | 0x73 | 0x73 | 0x77 | from NE header start |
| Entry-table length | 06 | 4 | 4 | 4 | empty table (§1.6) |
| File-load CRC | 08 | 0 | 0 | 0 | BPC leaves 0 |
| **Program flags** | 0C | `0x0A` | `0x0A` | `0x0A` | DGROUP=multiple(10) + prot-mode-only(bit3). 8086/286/386/87 bits all clear |
| **Application flags** | 0D | `0x03` | `0x03` | `0x03` | app-type=011 (uses P.M. API) |
| **Auto-data seg idx** | 0E | 3 | 3 | 3 | 1-based → the DGROUP DATA segment |
| Initial local heap | 10 | 0 | 0 | 0 | |
| Initial stack size | 12 | 0 | 0 | 0 | (SP set explicitly, see below) |
| **Entry CS:IP** | 14 | 1:0x0F | 1:0x02 | 1:0x02 | CS = seg index (1), IP = offset in seg1 |
| **Initial SS:SP** | 18 | 4:0x4000 | 4:0x4000 | 4:0x4000 | SS = the auto/stack segment (seg 4), SP = 0x4000 |
| **Segment count** | 1C | 4 | 4 | 4 | see §1.3 — BP7 uses a FIXED 4-segment model |
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

### 1.3 Segment table — a FIXED 4-segment model

BPC `/CP` emits **exactly 4 segments regardless of program size** (H, T, and
the multi-unit NEBIG all show 4). It packs all user+unit code into segments
and uses a DGROUP data segment + an auto/stack segment:

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

### 1.4 Relocations — THE key section

Each relocated segment has `HAS-RELOCS` (attr bit 8) set and stores,
immediately after its raw data:

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

**Placeholder convention (measured, universal): every relocated word in the
file holds `FFFF`; the loader writes the real value.** BPC does NOT bake
resolved addresses. Specifically:
- **OFFS** (single word): the word = `FFFF`.
- **BASE** (single segment word): the word = `FFFF`.
- **PTR** (two words, offset:segment): **offset word = `FFFF`, segment word =
  `0000`**. One PTR record covers both words; its `site offset` points at the
  offset word.

**One record per site — no fixup chains.** Where several sites reference the
same target (e.g. many OFFS records to KERNEL ord 114), BPC emits a
**separate 8-byte record for each site**. It does NOT use the
placeholder-as-linked-list chain form. (The generic spec allows chains via a
non-`FFFF` placeholder that points at the next site; BPC does not use it here.)

**Types actually emitted by BPC `/CP` (from NEBIG):** `02` BASE, `03` PTR,
`05` OFFS. LOBYTE/OFFS32/PTR48 did not appear.

#### Reloc examples (NEBIG.EXE seg1/seg2)

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

### 1.5 Import / module-reference tables

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

### 1.6 Name tables & entry table

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

### 1.7 Entry / startup sequence (seg1 head)

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

### 1.8 What "generate the same structure" requires

To emit a BPC-identical `/CP` NE, a linker must:
1. Copy the fixed 3646-byte MZ stub (→ `e_lfanew = 0x0E3E`).
2. Write the header constants from §1.2.
3. Emit the segment table with the §1.3 attributes (DPL bits on every segment;
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
reloc-record encoding matches this document (see Part 2 §2.2 below).
LOBYTE/OFFS32/PTR48 reloc types and the additive (`0x04`) and IMPORTNAME
(`0x02`) flag forms are defined by the format but not emitted by BPC `/CP`,
so we need not generate them.

---

## Part 2 — This project's implementation (`SRC/TOC/LINKNE.MOD`)

**Status: ARCHIVED — CONFIRMED WORKING END-TO-END ON REAL DPMI16 HARDWARE
(2026-08-05)**, via the HX-DOS extender. `BIN/TOC286.EXE` (the same compiler
as `TOC.EXE`, linked `/CP` instead of `/CD` — see `SRC/TOC/TOC286.MOD`)
compiles and links correctly under DPMI16, with zero heap leaks, and
**self-hosts** (compiling its own sources) correctly on real DPMI16 hardware.
See §2.4 for the five real-hardware bugs found and fixed getting here. This
target is considered complete; no further DPMI16-specific work is planned
unless a new bug surfaces.

### 2.1 What matches the BPC reference exactly

`LINKNE.MOD` writes a single-image NE (`/CP` target selected in `TOC.MOD`):
verbatim MZ stub + NE header + segment table + per-segment relocation blocks
+ name/reference tables. Verified byte-for-byte against the BPC reference at
the encoding level:

| Element | LinkNE behaviour | Matches reference? |
|---|---|---|
| Header constants | linkver/progFlags/appFlags/alignShift/targetOS/expVer set to the §1.2 values | ✅ |
| Entry CS:IP | CS = entry module's CODE seg index, IP = `ls^.entryIp` | ✅ form |
| Segment attributes | CODE `0x1C10`(+`0x0100` reloc → `0x1D10`); DATA/BSS `0x0C41`(+reloc `0x0D41`); DPL bits on all | ✅ |
| Module ref + imported names | one `KERNEL` ref; imported names `00 06 "KERNEL"` | ✅ byte-identical |
| Resident / nonresident names | module stem / `STEM.EXE` | ✅ |
| Resource / entry tables | empty (align-shift+`0000` / 4 zero bytes) | ✅ |
| Relocation records | 8-byte `type flags site tseg toff`, per-segment `<count><records>` | ✅ layout |
| **Reloc placeholder model** | FFFF/0000 placeholders, loader writes (no bake for `/CP`) | ✅ §1.4 |
| **Reloc flags** | internal `00`; KERNEL.INITTASK import-ordinal `01` | ✅ |
| **First instruction** | `CALL FAR KERNEL.INITTASK` (ordinal 91) | ✅ |

Implemented via `LinkNE.OnReloc`/`OnSegReloc` using `Link.ReadSiteWord` (grab
the compiler-baked self-ref offset for the reloc's `toff` before overwriting)
and `Link.WriteSiteWord` (stamp the placeholder). IP-relative near
calls/branches (`rrel # 0`) are position-independent, still baked, and get
NO NE reloc — exactly as BPC omits them.

### 2.2 Deliberate structural differences from BPC

**Segment model / count.** BPC uses a fixed 4 segments (user code / runtime
code / DGROUP / stack); **LinkNE keeps the Oberon per-module segment model**
(one CODE + one DATA per used module, plus one shared BSS/stack segment),
per the maintainer's instruction ("don't change segments"). Consequences
(all inherent, not bugs):
- `segCount` is data-dependent, not `4`.
- `autoData` (`0Eh`), `SS`, and `SP` index our shared-BSS/stack segment
  rather than a BPC-style DGROUP-with-stack. `SP` points at the top of the
  combined `totalBssLen + stackSize` region (see §2.4 bug #1 for why this
  must include both, not just `stackSize`) — BPC uses a fixed `0x4000`
  because its stack lives at the top of DGROUP with a different layout.
- We have no user/runtime code split, so every code segment gets the
  user-code attribute `0x1D10` (BPC's runtime-code seg is `0x0D40`).

Every *per-segment field* (attributes incl. DPL bits, min-alloc, reloc
encoding) still follows the reference.

**Far fewer external imports (by design).** In BPC **every** runtime call is
IMPORTORDINAL into KERNEL. In the Oberon toolchain the runtime (SYSTEM_INIT,
module inits, OBERON.OM library) is our own code, resolved and merged into
the flat image before the NE header is written — so those calls are
**internal**, not KERNEL imports. The single external reloc LinkNE emits is
the KERNEL.INITTASK first-call (§2.3).

**Own MZ stub, own `e_lfanew`.** Unlike BPC's fixed 3646-byte stub (always
`e_lfanew = 0x0E3E`), this project's `NESTUB.BIN` has been swapped more than
once (currently 512 bytes) and `WriteStub` (`LINKNE.MOD`) explicitly patches
offset `0x3C` with `StubBytes` after writing the stub — it does NOT trust
the stub file's own embedded `e_lfanew` to already be correct, since a past
stub swap shipped with `e_lfanew=0`, which silently pointed the NE header
lookup back at the MZ header and corrupted every downstream file offset
(this was bug #3 in §2.4, now permanently guarded against).

### 2.3 The KERNEL.INITTASK external call

The one place LinkNE emits a genuine external NE relocation, matching the
reference's mandatory first instruction (`CALL FAR KERNEL.ord 91`, task
init — see §1.7).

- **Entry stub** (`TOC.GenEntryStub`, `/CP` only): prepends the far call as
  the program's first instruction, emitted as an unresolvable import named
  `KERNEL_INITTASK`. `"start"` stays at offset 0 so CS:IP points at it.
  `/CD` never emits it.
- **Mark pass** (`Link.OnImportForMark`): skips the name `KERNEL_INITTASK` —
  not an "unresolved external" error, pulls in no dependency.
- **LinkNE** (`IsExternalImport` + `OnSegReloc`): the only unresolved import
  in this no-import model, emitted as ONE external **PTR (`03h`)** record
  covering the far pointer — flags = **IMPORTORDINAL (`0x01`)**, `tseg` =
  KERNEL module-ref index (`1`), `toff` = the INITTASK **ordinal**. The site
  keeps its placeholder; the loader writes the real far address.
- **Ordinal:** `LinkNE.InitTaskOrdinal` = **91** (`0x5B`, observed identically
  in the BPC reference H/T/NEBIG.EXE).
- **Flag encoding note:** the flags byte's low two bits are the target type
  (`0`=internal, `1`=import-ordinal); additive is bit 2 (`0x04`). Internal
  records MUST use `0x00` and INITTASK `0x01` — do not reuse `0x01` for
  anything internal. BPC never emits the additive bit or import-by-name;
  neither do we.

### 2.4 Real-hardware bugs found and fixed (2026-08-04 – 2026-08-05)

`xt` (this project's dev-loop DOS emulator) **cannot execute NE binaries at
all** — every check up to 2026-08-04 was structural byte-inspection only
(`BIN/RDFGREP.EXE` NE subcommands: `ne-signature`, `ne-seg-count`,
`ne-entry-seg`, `ne-word-at`, `ne-lfanew`, `ne-seg-attr`, `ne-has-kernel`,
`ne-init-task`, plus the manifest `ne/cp-*` rows). A 2026-07-28 real-hardware
smoke test confirmed a *small* NE-EXE loads and runs, but running the actual
self-hosted compiler under DPMI16 (via HX-DOS) on 2026-08-04/05 surfaced five
real bugs invisible to both `xt` and that earlier small-file smoke test:

**Bug #1 — BSS/stack segment sizing (`LINKNE.MOD` `BuildSegTable`/`WriteExe`).**
The shared BSS/stack segment's `allocLen` was set to `totalBssLen` only,
with `SP` fixed at `stackSize − 2` regardless of how large the compiler's
own BSS footprint was. Under DPMI16 (unlike real mode's forgiving flat
heap), the descending stack silently aliased live global data the moment
real call depth was used. Fixed by sizing the segment as
`totalBssLen + stackSize` (erroring rather than truncating if that exceeds
64K — a single NE segment can't be larger) and pointing `SP` at the top of
that combined region.

**Bug #2 — header-size miscalculation (`LINKNE.MOD` `WriteExe`, `filePos`
computation).** The code computed the end of the NE header area as
`nonresOfs + 1`, treating the nonresident-names table as a 1-byte empty
terminator — but it always carries the `.EXE` filename entry (`nrTabLen`
bytes, never 1). That too-small `filePos` fed into `Link.WriteZeros`
(`LINK.MOD`) with a **negative** pad-length argument; `WriteZeros` had no
guard against `n ≤ 0`, so `WORD(negative)` reinterpreted as a huge unsigned
chunk size, corrupting every downstream file offset — segment data landed
at different physical positions than the segment table claimed. Symptom on
real hardware: `DPMILD16: Relocatable code has zero relocations` (the
segment table's `HASRELOC` bit was internally consistent with what
`AddReloc` counted, but pointed at the wrong physical file location once
padding went haywire). Fixed: `filePos` now uses the real `nrTabLen`;
`Link.WriteZeros` now guards `n ≤ 0` as a no-op, so any future off-by-a-few
miscalculation elsewhere fails safe instead of corrupting the file.

**Bug #3 — `SYSTEM.ASM` DPMI descriptor privilege + a nonexistent DPMI
call.** Two separate `SYSTEM.ASM` bugs (both required maintainer sign-off
per this project's rules) combined to leak nearly all heap memory allocated
under DPMI16:
- `DPMI_get_hidden_handle`'s scratch descriptor requested DPL=0 (ring-0/
  kernel privilege) instead of DPL=3 for its access rights. Real DPMI16
  hosts correctly rejected this privilege violation (some emulators
  tolerated it silently), which broke every `DISPOSE`/heap-free call.
- `DPMI_Free` then called `INT 31h AX=0003h` intending "Get Segment Limit"
  — no such DPMI service exists. `0003h` is actually "Get Next Selector
  Increment Value" (an unrelated, always-succeeding call). The correct
  mechanism is the native `LSL` (Load Segment Limit) CPU instruction
  (80286+, always available under DPMI) — see `DOCS/DPMI09.HTM` §8.8's
  explicit note. Fixed by emitting `LSL DX,BX` as raw bytes (`0F 03 D3`,
  since this project's assembler — TASM, `SRC/TASM/`— only targets 8086).

Bugs #1-3 verified via a purpose-built reproducer (`Files.ReWriteTemp`/
`Files.Close` round-tripped through `SYSTEM.MemAvail()`, now a deterministic
process-local paragraph counter under DPMI — see `DOCS/IMPLRULE.MD`) run on
real DPMI16 hardware, confirming exact, full memory recovery on every free.

**Bug #4 — `CGEN.MOD` `Cgen.CgFree` double-free.** `CgFree` disposed the
module-level `CgObj` pointer (`DISPOSE(CgObj)`) but never set it back to
`NIL` afterward, so its own guard (`IF CgObj # NIL THEN ... END`) was
permanently broken after the very first call. `Cgen.CgFree` runs once per
compiled module (`TOC.MOD`'s per-module compile loop) and again
unconditionally in `TOC.MOD`'s `Cleanup` (run on every exit path, by design,
so an error partway through a multi-module compile still frees everything).
For a single-module program (e.g. `HELLO.MOD`), the second call saw a stale
non-NIL `CgObj` and re-entered `Rdoff.RdfFree(CgObj)` on an already-disposed
pointer — a genuine use-after-free / double-free. Real-mode DOS's coalescing
heap allocator silently tolerated the stale dereference (the freed block's
memory was often still intact or reused predictably); DPMI16's
non-coalescing per-selector LDT allocator turned it into a hard GP fault the
moment the freed selector was reused for something else (observed as
`EBX=EDX=<stale selector>`, faulting inside `Rdoff.RdfFree`'s first
`Files.Close` call). Found via systematic bisection: temporary print markers
bracketing `TOC.MOD`'s `Cleanup` calls showed the crash fell strictly between
a successful `FreeMods` completion and the next marker, isolating it to
`Cgen.CgFree`. Fixed by adding `CgObj := NIL` after `DISPOSE(CgObj)`, mirroring
the guard pattern `TOC.MOD`'s own `gModOpen` flag already used correctly for
the analogous `FreeMods`/`gModFile` double-call case.

**Bug #5 — `SYSTEM.ASM` `SYSTEM_IsDPMI` wrong-segment memory read.** The
function loaded `isDpmi`'s segment into `ES` but then read the flag with a
bare `mov ax, [isDpmi]` operand — which defaults to `DS`, not `ES` — instead
of the correct `[es:isDpmi]`. The read result was immediately clobbered by
the following `int 21h/AH=62h` call anyway, making the line dead code by
outcome, but the wrong-segment read itself could still fault under DPMI16:
at some call sites the caller's `DS` did not point at a valid/mapped selector
for that offset, producing a GP fault deep inside what looked like
unrelated compiler logic (crash `EIP` landed inside `SYSTEM_IsDPMI`, called
transitively via `EMS.EMS_Detect`, which every module's `__init` reaches).
Fixed directly by the maintainer.

### 2.5 Building and testing `/CP`

`make`/`make test`/`make testall` build and test **only** `TOC.EXE` (`/CD`,
MZ) — `xt` cannot execute NE binaries, so it is structurally incapable of
testing `/CP` output beyond byte-inspection. `BIN/TOC286.EXE` is built
additively:

```bash
make -C SRC/TOC toc286   # builds + installs BIN/TOC286.EXE
```

and must be tested on a real DPMI16 host or DPMI16-capable extender (e.g.
HX-DOS, or a real DPMI server under DOSBox-X) — there is no automated
in-repo test for `/CP` execution correctness, only for structural/byte-level
conformance to this document.

### 2.6 Status: archived

As of 2026-08-05 the `/CP` DPMI16 target is considered **complete and
archived**:

- The full self-hosted compiler (51+ NE segments) links, runs, and
  **self-hosts** (compiles its own sources) correctly on real DPMI16
  hardware via HX-DOS, with zero heap leaks confirmed across the whole run.
- All five bugs found during bring-up (§2.4) are fixed and covered by either
  the in-repo manifest (`ne/cp-*` structural rows, unaffected by any of
  these bugs since they only manifest at DPMI16 runtime) or real-hardware
  verification (heap-leak reproducer for #1-3; the double-free and
  wrong-segment-read bugs #4-5 were only reproducible by running the actual
  compiler under DPMI16, since `xt` cannot execute NE binaries).
- No further DPMI16-specific work is planned unless a new bug surfaces.
  **Segment model** remains per-module by design (not BPC's fixed 4) — see
  §2.2 — this is a deliberate, permanent difference, not a TODO.
- A dedicated large/many-segment fixture in the in-repo test suite (beyond
  manual real-hardware runs) would still be a nice-to-have for future
  regression coverage, since `xt` cannot exercise `/CP` execution at all —
  but is not required given the target is now confirmed working end-to-end.
