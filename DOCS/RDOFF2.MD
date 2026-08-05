# RDOFF2 (Relocatable Data Object File Format) & RDL (RDOFF Library)

**Specification Version:** 2.2 (Revised & Corrected)
**Architecture:** x86 (16-bit / 32-bit agnostic)
**Byte Order:** Little-Endian
**String Encoding:** ASCII (Null-terminated)

---

## 1. Introduction

RDOFF2 (RDF) is a simplified, relocatable object file format used primarily by the NASM assembler. It supports multi-module linking, symbol export/import, and segment relocation.

The format consists of two distinct file types:
1.  **RDF (Object File):** Contains code, data, and relocation metadata for a single compilation unit.
2.  **RDL (Library File):** A container format (archive) holding multiple RDF files.

Command line to produce RDOFF2 object file:

```
    nasm -f rdf myfile.asm
```

This project's own toolchain also produces RDOFF2 directly: `toc.exe` (the Oberon-07
compiler, `SRC/TOC/`) writes it for every compiled module, and `tasm.exe` (a self-hosted
NASM-subset assembler, `SRC/TASM/`) writes it for hand-written `.asm` sources:

```
    tasm.exe myfile.asm
```

See [PORTING.MD](PORTING.MD) §1.6 for `tasm.exe`'s CLI and coverage.

---

## 2. RDF File Structure

The RDF file is strictly sequential. All multi-byte integers are stored in Little-Endian format.

| Offset | Field Name  | Size      | Description |
|--------|-------------|-----------|-------------|
|  0000  | Signature   | 6         | Magic string: `'RDOFF2'` |
|  0006  | Module Size | 4 (DWORD) | Total size of the file in bytes. |
|  000A  | Header Size | 4 (DWORD) | Length of the **Header Records** section (starts at `0x0E`). |
|  000E  | Records     | Variable  | Sequence of metadata records (Relocations, Imports, Exports). |
|  ...   | Segments    | Variable  | Sequence of raw segment data blocks. Starts immediately after Records. |

---

## 3. Header Records

The "Header" section contains a list of variable-length records. Each record instructs the linker to perform an action (patch memory, define a symbol, reserve BSS).

### 3.1. Generic Record Structure

Every record begins with a 2-byte preamble:

| Offset | Type  | Description |
|--------|-------|-------------|
|   +0   | Byte  | **Record Type ID** (See Table 3.2). |
|   +1   | Byte  | **Record Length**. The number of bytes of data *following* this byte. <br>Total Record Size = `Length + 2`. |
|   +2   | Bytes | **Record Data** (Payload). |

### 3.2. Record Types Summary

| ID | Constant Name   | Description |
|----|-----------------|-------------|
|  1 | RDFREC_RELOC    | Apply a fixup (patch) to code or data. |
|  2 | RDFREC_IMPORT   | Declare an external symbol required by this module. |
|  3 | RDFREC_GLOBAL   | Declare a public symbol provided by this module. |
|  4 | RDFREC_DLL      | Declare dependency on a dynamic library (ignored in static linking). |
|  5 | RDFREC_BSS      | Request uninitialized memory reservation. |
|  6 | RDFREC_SEGRELOC | Patch a location with a Segment Base Address. |
|  8 | RDFREC_MODNAME  | Name of the module (metadata). Optional, no wide usage. |

---

### 3.3. Detailed Record Layouts

#### Type 1: RDFREC_RELOC

Used to modify a pointer within the module's code or data segments.

| Offset | Type  | Description |
|--------|-------|-------------|
|   +0   | Byte  | **Flags / Physical Segment**: <br> **Bit 6 (0x40):** Relative Flag. If set, the relocation is PC-relative. <br> **Bits 0-5:** Physical Segment Index containing the code to patch (0 = Code, 1 = Data). |
|   +1   | DWORD | **Offset**. The location within the segment to apply the patch. |
|   +5   | Byte  | **Width**. Size of the patch in bytes. Valid values: 1, 2, 4. |
|   +6   | Word  | **Reference Segment (RSEG)**. <br> `0`: Code Segment <br> `1`: Data Segment <br> `2`: BSS <br> `>2`: **Import ID** (Matches `RDFREC_IMPORT` Segment ID). |

**Linking Logic:**

1.  **Absolute (Flag 0x40 unset):**
    `*Patch_Location += Target_Symbol_Address`
    *The value already present at `Patch_Location` (the addend) is added to the absolute address of the target.*

2.  **Relative (Flag 0x40 set):**
    `*Patch_Location += Target_Symbol_Address - Module_Base_Address`
    
    > **Critical Note on Relative Relocations:**
    > The formula above calculates the distance from the start of the module to the target. However, x86 relative jumps (`CALL`, `JMP`) are relative to the *end* of the instruction (`EIP`).
    > To compensate for this, the **Assembler** must pre-calculate a negative addend and store it at `*Patch_Location`.
    > The stored addend is typically: `-(Offset_Of_Patch + Patch_Width)`.

#### Type 2: RDFREC_IMPORT

Defines a symbol that is not present in this file but will be provided by another file at link time.

| Offset | Type   | Description |
|--------|--------|-------------|
|   +0   | Byte   | **Flags**. Usually 0. |
|   +1   | Word   | **Segment ID**. A 16-bit unique internal identifier assigned to this import. <br>**Note:** This is strictly **2 bytes**, unlike the Segment ID in GLOBAL records. |
|   +3   | String | **Name**. ASCIIZ (Null-terminated) string. |

**Linking Logic:**
The Linker builds a map: `ImportID -> Symbol_Final_Address`. When a `RELOC` record refers to `RSEG = ImportID`, the linker applies the address of this symbol.

#### Type 3: RDFREC_GLOBAL

Defines a symbol inside this file that can be used by other files.

| Offset | Type   | Description |
|--------|--------|-------------|
|   +0   | Byte   | **Flags**. `0x01` = Global/Exported. |
|   +1   | Byte   | **Segment ID**. The physical segment where the symbol lives (0=Code, 1=Data, 2=BSS). <br>**Note:** This is strictly **1 byte**. |
|   +2   | DWORD  | **Offset**. The offset of the symbol from the start of its segment. |
|   +6   | String | **Name**. ASCIIZ string. |

#### Type 5: RDFREC_BSS

Declares how much uninitialized memory (BSS) the module needs.

| Offset | Type  | Description |
|--------|-------|-------------|
|   +0   | DWORD | **Amount**. Number of bytes to reserve. |

#### Type 6: RDFREC_SEGRELOC

Used when code needs to know the Segment Selector or Paragraph Address (e.g., `mov ax, seg data_label`).

| Offset | Type  | Description |
|--------|-------|-------------|
|   +0   | Byte  | **Segment Index**. Physical segment (0/1) to patch. |
|   +1   | DWORD | **Offset**. Location to patch. |
|   +5   | Byte  | **Width**. Usually 2 (16-bit segment register). |
|   +6   | Word  | **Reference Segment**. The target segment whose base is needed. |

---

## 4. Segments Structure

Immediately following the Header Records (at offset `0x0E + HeaderSize`), the file contains the raw content of the segments.

**Segment Header:**

| Offset | Type  | Description |
|--------|-------|-------------|
|   +0   | Word  | **Type**. <br> `0` = EOF (End of File)<br> `1` = Code<br> `2` = Data |
|   +2   | Word  | **Number**. Segment Index (0, 1). |
|   +4   | Word  | **Reserved**. Should be 0. |
|   +6   | DWORD | **Length**. Size of the following data in bytes. |
|   +10  | Bytes | **Content**. Raw binary data (`Length` bytes). |

**Scanning Logic:**
The linker reads segments sequentially. After reading `Length` bytes of content, it expects the next Segment Header immediately. The file ends when a Segment Header with **Type 0** is encountered.

---

## 5. Implementation Standards (Small Model)

When linking RDOFF2 files into a 16-bit DOS `.EXE` (Small Model), the following rules apply:

### 5.1. Memory Layout
1.  **Code Block (CS):** Concatenation of all Code segments (Type 1).
2.  **Data Block (DS):** Concatenation of all Data segments (Type 2) + Total BSS.

### 5.2. Alignment
*   **CS/DS Boundary:** In Small Model, the Data Block must start at a 16-byte (paragraph) boundary relative to the start of the Code Block. The linker must zero-pad the Code section of each module to ensure alignment if necessary.

### 5.3. Address Calculation Formula
Assuming `PatchAddr` is the pointer in the final binary to be modified:

*   **Import (External) Reference:**
    `Value = *PatchAddr + Symbol_Absolute_Address`

*   **Relative Import (External) Reference:**
    `Value = *PatchAddr + Symbol_Absolute_Address - Module_Base_Address`
    *(Where `*PatchAddr` is the negative addend placed by the assembler, as described in Section 3.3).*

### 5.4. Reserved Segment IDs
*   **0**: Code Segment (Physical)
*   **1**: Data Segment (Physical)
*   **2**: BSS (Virtual). Symbols in BSS are resolved as: `Total_Data_Size + Offset_In_BSS`.
*   **>=3**: Dynamically assigned Import IDs.

---

## 6. Implementation Standards (Large Model — CS≠DS≠SS)

When linking RDOFF2 files into a 16-bit DOS `.EXE` under the DOS real-mode **large memory model**
(as produced by `olink`), the following rules apply.  In this model code, data, and stack each
occupy separate segments; no two of CS, DS, SS are the same at runtime.

### 6.1. Memory Layout

| Region | Segment register | Contents |
|--------|-----------------|----------|
| Code groups | CS (one per `.om` group) | All Code segments (Type 1) from one `.om` archive concatenated, 2-byte aligned |
| Combined data | DS | All Data segments (Type 2) from every used module, concatenated |
| BSS | DS (beyond data) | Zero-initialised; not written to file |
| Stack | SS | Separate paragraph after data+BSS; size = `stack_size` bytes (default 8192, overridden by `META-INF/STACK.TXT`) |

### 6.2. Code Grouping

All `.rdf` members extracted from the same `.om` archive share **one code segment (CS paragraph)**.
Members within a group are packed with 2-byte word alignment.  Each group is paragraph-aligned
(16 bytes) relative to the start of the combined code block.

Standalone `.rdf` files are rejected; all objects must be packaged into `.om` archives.

### 6.3. Alignment

*   **Between code groups:** Each group starts at a paragraph (16-byte) boundary.
*   **Within a code group:** Individual `.rdf` code sections are 2-byte (word) aligned.
*   **Data segment start:** Starts at a paragraph boundary after the entire code block.
*   **Data segment end / BSS start:** BSS immediately follows the last data byte (no extra alignment).

### 6.4. Address Calculation

Let `module_code_ofs` be the byte offset of the module's code section within its group, and
`group_code_para` the paragraph number of the group from the start of the combined code block.

#### Absolute code reference (RDFREC_RELOC, width=2, flag 0x40 unset, RSEG=0):
```
*PatchAddr += module_code_ofs   ; offset within the group's code segment
```

#### Absolute data reference (RDFREC_RELOC, width=2, flag 0x40 unset, RSEG=1):
```
*PatchAddr += module_data_ofs   ; offset within the combined DS
```

#### Relative code reference (RDFREC_RELOC, width=2, flag 0x40 set, RSEG=import_id) — NEAR CALL E8:
```
*PatchAddr += target_code_ofs_in_group - (patch_ofs_in_group + 2)
```
The assembler stores the pre-calculated addend `-(patch_offset_in_module + 2)` at `*PatchAddr`.
The linker adds the target symbol's group-relative offset; the result is the signed 16-bit
displacement from the end of the instruction to the target.

#### Import reference (RDFREC_RELOC, width=2, flag 0x40 unset, RSEG=import_id) — FAR CALL 9A offset word:
```
*PatchAddr += target_symbol_offset_within_its_group_code_segment
```
A matching SEGRELOC record patches the segment word of the same FAR CALL.

#### Segment relocation (RDFREC_SEGRELOC, RSEG=import_id or 0/1):
```
*PatchAddr = paragraph_of_target_group   ; CS paragraph, relative to load image start
```
For data/BSS references: `*PatchAddr = code_para` (paragraph of the combined DS, i.e. `group0_para + total_code_groups`).

### 6.5. Reserved Segment IDs

| ID | Meaning |
|----|---------|
| 0  | Physical code segment of the current module |
| 1  | Physical data segment of the current module |
| 2  | BSS (virtual); resolved as `total_data_size + bss_offset_in_module` |
| ≥3 | Dynamically assigned import IDs (assigned sequentially per module, starting at 3) |

### 6.6. MZ Executable Header

The linker produces a standard DOS MZ executable.  Key fields derived from the link:

| MZ Field | Value |
|----------|-------|
| CS       | `entry_cs_para` — `group_code_para` of the module owning `start`, relative to load image |
| IP       | group-relative offset of `start` within its code segment |
| SS       | `code_para + data_bss_para` — paragraph of stack segment, relative to load image |
| SP       | `stack_size - 2` |
| DS       | Not set by MZ loader; `SYSTEM_INIT` loads DS from a linker-patched paragraph value in code |

`code_para` = total code bytes rounded up to next paragraph.
`data_bss_para` = `(total_data + total_bss + 15) / 16`.

### 6.7. DS Initialisation

Because the large model has DS ≠ CS, the MZ loader cannot set DS automatically.  The entry stub
(generated by `oc /ENTRY=` and merged into the module's own `.rdf` via `Rdoff.MergeRdf`
— see §8 below) calls `SYSTEM_INIT` as its first action.  `SYSTEM_INIT`
reads a SEGRELOC-patched 16-bit immediate in its own code to obtain the DS paragraph, then executes
`MOV DS, AX` before any module-level code runs.

### 6.8. Merging `$L` Extras and the Entry Stub (`Rdoff.MergeRdf`)

`toc.exe` never keeps a `$L`-directive's extra `.rdf` (e.g. a hand-assembled helper) or the
`/ENTRY=` entry stub as a separate archive member.  Instead, each is folded directly into the
compiling module's own `.rdf` by `Rdoff.MergeRdf(host, donor, dst)` before the `.om` is packed.
Merge order is significant: the module's own generated code first, then each `$L` extra in
source order, then (for `/ENTRY=`) the entry stub last — this keeps debug-info offsets
predictable across the whole merged object.

**What the merge does:**

1. **Alignment.** Host's code, data, and BSS lengths are rounded up to an even (2-byte) boundary
   before donor's bytes are appended — matching §6.3's word-alignment rule for objects sharing a
   code group.
2. **Concatenation.** Donor's code/data bytes are appended after host's (host is never moved);
   BSS sizes are summed.
3. **Import resolution.** For any import one side declares that the other side's GLOBAL table can
   satisfy, every RELOC/SEGRELOC record referencing that import is rewritten: `rseg` becomes the
   resolved GLOBAL's plain segment id (`SegCode`/`SegData`/`SegBss`), and — for RELOC only, never
   SEGRELOC — the addend already at the patch site is updated to the target's offset within the
   merged object.  The now-fully-resolved import itself is removed from the import list.  The
   record is **never dropped** even once resolved: the real linker's own `OnReloc`/`OnSegReloc`
   still add the owning module's `GroupOfs`/`groupCodeStart` paragraph on top of this at final
   link time (§6.4), and dropping the record early only works by accident when the merged object
   happens to land at code-group offset 0.
4. **Addend shift for self-targeting relocs.** A RELOC record that was *never* an import — its
   `rseg` was already `SegCode`/`SegData`/`SegBss`, targeting somewhere inside the donor's own
   code/data/bss (e.g. self-modifying code patching one of its own instructions) — has its donor
   bytes moved by the merge, so the byte-value addend already sitting at its patch site must gain
   the same code/data/bss base the donor's content was appended at.  Missing this step is a
   distinct bug from missing step 3: the patch *site* still moves correctly (its own `offset`
   field is base-shifted like any other reloc), but the *value written there* keeps pointing at
   the target's stale pre-merge offset, so the final linker's `GroupOfs(module)` addition (§6.4)
   lands on the wrong byte entirely.  (Found via `SYSTEM.RDF`'s `SYSTEM_Intr`, which self-patches
   its own `INT` opcode's interrupt-number byte — a merge that skipped this step corrupted the
   patch, and every program crashed at its very first `SYSTEM.Intr` call.)  SEGRELOC records
   never need this: their value is a paragraph number computed entirely at final link time, never
   an addend baked in by the merge.
5. **Import renumbering.** Any import neither side can resolve is genuinely external and survives,
   renumbered (if needed) so it does not collide with the host's own import ids; every reloc that
   referenced the donor's old id is repointed at the new one.
6. **Globals.** Donor's GLOBAL entries are re-emitted into the host with their offset shifted by
   the matching code/data/bss base, so other modules can still resolve them by name after the
   merge.

Because RDOFF2 objects are file-backed (never loaded whole into memory — see DOCS/IMPLRULE.MD's
DOS memory-constraint rules), all of the above is done via seek+patch on the underlying files,
not on an in-memory buffer.

---

## 7. RDOFF Library Format (RDL)

The RDL format (identified by the signature `'RDLIB2'`) is a simple, sequential archive format used to bundle multiple RDOFF2 object files into a single library file. It functions similarly to a simplified `tar` archive.

### 7.1. File Header

The file begins with a global signature.

| Offset | Field Name | Size | Description |
|---|---|---|---|
| 0000 | Signature | 6 | Magic string: `'RDLIB2'` |

### 7.2. Library Entries

Immediately following the signature, the file consists of a sequence of **Module Entries**. There is no central directory; the file must be read sequentially from start to finish.

**Structure of a Single Entry:**

| Offset | Field Name | Size | Description |
|---|---|---|---|
| +0 | Name | Variable | **ASCIIZ String**. The name of the module (e.g., `math.obj`), terminated by a null byte (`0x00`). |
| +Var | Content Size | 4 (DWORD) | The size of the module data in bytes ($N$). |
| +Var+4 | Content | $N$ Bytes | The raw binary content of the module (typically a complete RDOFF2 file). |

### 7.3. Special Entries (The `.sig` Block)

By convention, RDL files generated by standard tools include a metadata block as the **first entry** in the library.

*   **Name:** `'.sig'` (plus null terminator).
*   **Size:** 4 bytes.
*   **Content:** 4 null bytes (`0x00000000`).

**Linker Behavior:**
When iterating through the library, the linker **must** check the first character of the `Name` field.
*   If `Name` starts with a dot (`.`) (e.g., `.sig`), the entry is considered internal metadata and **must be skipped**.
*   The skip logic is: `Next_Entry_Offset = Current_File_Pos + Content_Size`.

### 7.4. Parsing Algorithm

To read an RDL file:
1.  Verify the `'RDLIB2'` signature.
2.  Loop while not End-Of-File:
    a.  Read string at current position until `0x00` is found (`ModuleName`).
    b.  Read the next 4 bytes as `DataSize` (DWORD).
    c.  If `ModuleName` starts with `.` (dot), `Seek` forward by `DataSize`.
    d.  Else, process `DataSize` bytes as a valid RDOFF2 object file.
    e.  Repeat.
