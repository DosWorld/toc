# BGI Driver Format & Authoring Guide

**Everything about the Borland Graphics Interface (`.BGI`) driver format
lives here.** This document specifies the on-disk file structure, the
runtime calling convention, the dispatch table, the Device Information
Table, and gives a complete, worked recipe for writing a new driver — with
the exact byte layouts and the traps that make Turbo Pascal / Borland C++
reject a file.

---

## 1. What a BGI driver is

A `.BGI` file is a **relocatable, position-independent 16-bit real-mode
code+data blob** with a text/binary **header** prepended. Borland's graphics
kernel (`GRAPHICS.LIB` for C, the `Graph` unit for Pascal) loads the file,
skips the header, copies the driver image into a single segment, sets
`DS = CS`, and calls into it through a fixed **far-call entry stub**. The
driver renders directly to video hardware.

Every graphics primitive an application calls (`Line`, `Bar`, `PutPixel`,
`FloodFill`, `OutText`, …) is dispatched by the kernel to a numbered driver
routine via a **dispatch table** (`DDOVEC`). The driver implements the low-
level primitives; the kernel *emulates* the expensive ones (arcs, ellipses,
pieslices, filled 3-D bars) on top of the driver's `PutPixel`/`GetPixel`
when the driver declines them.

There are two header revisions:

* **v2.0 (`pk`)** — the classic real-mode format. `DS := CS` (single
  segment, code and data live together). Used by most BC/TC/BP/TP
  drivers. **This is the format to write.**
* **v3.0 (`FBGD`)** — adds a separate DATA segment (for BP7 protected
  mode) via an alias word and an InitTable. Used by the stock Borland
  drivers. More complex; only needed for protected-mode hosts.

This guide targets **v2.0** and notes v3.0 differences where they matter.

---

## 2. File structure overview

```
+----------------------------------------------------------+  offset 0x00
| Header (0xA0 = 160 bytes)                                 |
|   magic + human-readable banner + two header blocks +     |
|   driver name                                             |
+----------------------------------------------------------+  offset 0xA0
| Driver image (verbatim flat binary):                      |
|   far entry stub                                          |
|   ... primitive routines ...                              |
|   DDOVEC dispatch table                                   |
|   BitmapTable                                             |
|   Device Information Table(s) + mode-name strings         |
|   data / scratch variables                                |
+----------------------------------------------------------+  EOF
```

The header is always **0xA0 bytes** (`HEADER_SIZE`). The driver image
begins at file offset **0xA0** and is a plain copy of what `nasm -f bin`
(or `TASM`+`TLINK`+`EXE2BIN`) produced — a flat, `org 0` binary.

---

## 3. The header (offset 0x00 … 0xA0)

### 3.1 v2.0 (`pk`) header — annotated real example

```
offset  bytes                       meaning
------  --------------------------  -------------------------------------
0x00    70 6B 08 08                 magic "pk",08,08     (v2.0 signature)
0x04    "CGA4 BGI Device Driver …"  free-form ASCII banner
        … 0D 0A                     CR LF
        "Oberon-07 … driver" 0D 0A  copyright / second line, CR LF
        00 1A                       NUL + EOF(^Z) terminator  <-- KEY
0x4E    ── FIRST header block ──    immediately after 00 1A (see 3.3)
        A0 00                         +0  dw headerSize  = 0x00A0
        00 00                         +2  dw driverNum   = 0
        38 0E                         +4  dw codeSize     (image length)
        02                            +6  db version      = 2
        00                            +7  db revision     = 0
        01                            +8  db minVersion   = 1
        00                            +9  db minRevision  = 0
0x58    00 … 00                     zero pad up to 0x80
0x80    ── SECOND header block ──   at the FIXED offset 0x80
        A0 00 00 00 38 0E 02 00 01 00   (same 10 bytes as the first block)
0x8A    04                          namelen byte  <-- name is HERE
0x8B    "CGA4"                      driver name (namelen bytes)
0x8F    00 … 00                     zero pad up to 0xA0
0xA0    ── driver image begins ──
```

### 3.2 The header block is **10 bytes** in v2.0 — the #1 gotcha

The v2.0 header block is exactly **10 bytes**:

```
+0  dw  headerSize   (0x00A0)
+2  dw  driverNum    (0 — the kernel assigns the real number at load)
+4  dw  codeSize     (length of the driver image = filesize − 0xA0)
+6  db  version      (2)
+7  db  revision     (0)
+8  db  minVersion   (1)
+9  db  minRevision  (0)
```

The **driver-name length byte follows IMMEDIATELY at block+10**. There are
**no trailing pad bytes inside the block.** Writing a 12-byte block (two
extra zeros) shoves the name to 0x8C; the loader reads a length of `00` at
0x8A and rejects the file with **“Invalid device driver file.”**

> A v3.0 block is longer — it appends `dw dataOfs` (+10) and `dw dataSize`
> (+12), so a v3.0 name sits at block+14. Do **not** carry those two words
> into a v2.0 file.

### 3.3 The first block must follow `00 1A` — the #2 gotcha

The header is written by two passes (mirroring Borland's `BGIHDR`):

1. magic + banner text + `0D 0A` + copyright + `0D 0A` + **`00 1A`**
2. **first header block, right there** (variable offset — depends on banner
   length), then zero-pad up to **0x80**
3. **second header block at the fixed 0x80**, then namelen + name
4. zero-pad up to **0xA0**

Only the **second** block is at a fixed offset. Hardcoding the first block
to some fixed offset, or omitting the `00 1A`, yields **“driver has invalid
structure.”** The `00 1A` is a genuine DOS text EOF so a plain `TYPE
DRIVER.BGI` shows only the banner.

### 3.4 v3.0 (`FBGD`) header differences

```
0x00    46 42 47 44 08 08 08 08     magic "FBGD",08,08,08,08
…       banner + 0D 0A + copyright + 0D 0A + 00 1A
        first block (v3, 14 bytes)  immediately after 00 1A
        zero pad to 0x80
0x80    second block (v3, 14 bytes):
          A0 00        headerSize
          00 00        driverNum
          <code> …     codeSize
          03 00        version 3, revision 0
          03 00        minVersion 3, minRevision 0
          <dataOfs>    dw   offset of DATA segment within the image
          <dataSize>   dw   length of the DATA segment
        namelen + name  (at 0x80 + 14 = 0x8E)
        zero pad to 0xA0
0xA0    driver image (code segment, then data segment at dataOfs)
```

`dataOfs`/`dataSize` tell the protected-mode loader where to split code from
data so it can build a separate DATA selector. In v2.0 there is no split.

---

## 4. The driver image (offset 0xA0 →)

The image is a flat binary assembled with `org 0`. Its first bytes are the
**far entry stub** the kernel calls; the rest is routines and data, ending
with the dispatch tables and the Device Information Table(s).

### 4.1 The v2.0 far entry stub

The kernel far-calls **offset 0** of the image with `SI` = the byte index of
the wanted routine in `DDOVEC`, and the primitive's arguments in registers.
The stub selects `DS := CS`, then near-calls through `DDOVEC[SI]`:

```asm
BgiEntry:
        push    ds
        push    cs
        pop     ds              ; DS = CS  (v2.0 single-segment model)
        cld
        push    bp
        call    word [si+DDOVEC]
        pop     bp
        pop     ds
        retf
        db      'CB'            ; validity signature — MUST be at image+0x0C
        db      0
        db      2               ; BGI revision byte
```

On disk (image bytes 0x00…) this is:

```
1E 0E 1F FC 55 FF 94 <ddo_lo><ddo_hi> 5D 1F CB 43 42 00 02
                     └ call word[si+DDOVEC] ─┘        └'C''B'─┘
```

The kernel validates the **`CB` marker at image+0x0C** (file offset 0xAC).
`<ddo_lo><ddo_hi>` is the 16-bit offset of the `DDOVEC` table within the
image and naturally differs per driver.

### 4.2 The v3.0 far entry stub

v3.0 loads `DS` from an alias word patched by the kernel at load time, and
carries an InitTable describing real-mode segments/vectors:

```asm
BgiEntry:
        push    ds
        mov     ds, cs:[alias]  ; alias word patched at load
        cld
        push    bp
        call    word [DDOVEC+si]
        pop     bp
        pop     ds
        retf
verID   db      BGIVERSION      ; 3
alias   dw      0               ; kernel writes the DATA selector here
```

On disk: `1E 2E 8E 1E <alias_ofs> FC 55 FF 94 <ddo_ofs> 5D 1F CB`.

Unless you are targeting BP7 protected mode, **write v2.0** and skip all of
this.

### 4.3 EMULATE thunks

Routines you don't implement point at an `EMULATE` far-call slot that the
kernel patches at load time to vector into its own emulation code:

```asm
EMULATE:  ret                   ; NEAR - see below
          dw 0,0                ; kernel writes its far target here
```

The `ret` **must be near**. `BgiEntry` reaches every `DDOVEC` entry with
`call word ptr [si+DDOVEC]`, a near call that pushes only an offset, so a
`retf` here pops the return offset plus whatever word follows it as `CS`
and jumps to a wild address. Until the kernel patches the stub, this is
what `Circle`/`Ellipse`/`Arc`/`PieSlice` actually execute.

Arc, pieslice, filled-ellipse, filled-3d-bar, and the two “reserved” slots
are normally left as `EMULATE`. The kernel emulates them using your
`PutPixel`/`GetPixel` via the **BitmapTable** (§6).

---

## 5. The dispatch table (`DDOVEC`)

`DDOVEC` is an array of **near** offsets (within the image) indexed by the
kernel. The index passed in `SI` is a **byte offset** (0, 2, 4, …), so entry
*n* is at `SI = 2n`. Standard table (indices are the values the kernel puts
in `SI`):

| SI   | Routine        | Purpose                                   |
|------|----------------|-------------------------------------------|
| 0x00 | `install`      | install / mode query (see §5.1)           |
| 0x02 | `init`         | enter graphics mode                       |
| 0x04 | `clear`        | clear the screen                          |
| 0x06 | `post`         | leave graphics mode                       |
| 0x08 | `move`         | move current pointer (CP) to X,Y          |
| 0x0A | `draw`         | line from CP to X,Y (updates CP)          |
| 0x0C | `vect`         | line from X1,Y1 to X2,Y2                   |
| 0x0E | *reserved*     | → EMULATE                                  |
| 0x10 | *filled 3d bar*| → EMULATE                                  |
| 0x12 | `patbar`       | patterned/filled bar                      |
| 0x14 | *arc*          | → EMULATE                                  |
| 0x16 | *pieslice*     | → EMULATE                                  |
| 0x18 | *filled ellipse*| → EMULATE                                 |
| 0x1A | `palette`      | set one palette entry                     |
| 0x1C | `setallpalette`| load the whole palette                    |
| 0x1E | `colour`       | set draw & fill colours                   |
| 0x20 | `fillstyle`    | set fill pattern                          |
| 0x22 | `linestyle`    | set line style + width                    |
| 0x24 | `textstyle`    | set font direction & size                 |
| 0x26 | `text`         | output a string at CP                     |
| 0x28 | `textsize`     | measure a string (px)                     |
| 0x2A | *reserved*     | → EMULATE                                  |
| 0x2C | `floodfill`    | flood-fill a bounded region               |
| 0x2E | `getpixel`     | read pixel colour at X,Y                  |
| 0x30 | `putpixel`     | write pixel colour at X,Y                 |
| 0x32 | `bitmaputil`   | return pointer to BitmapTable (§6)        |
| 0x34 | `savebitmap`   | BITBLT screen → buffer                    |
| 0x36 | `restorebitmap`| BITBLT buffer → screen                    |
| 0x38 | `setclip`      | set clipping rectangle                    |
| 0x3A | `colourquery`  | colour-table query                        |
| …    | 16× `NotImp`   | reserved for future use                   |

### 5.1 Register ABI per routine

All coordinates are 16-bit signed. `CP` = current pointer (drawing cursor).

| Routine | Inputs | Outputs |
|---------|--------|---------|
| `install` | `AL=0` set mode `CL`; `AL=1` query → `CX`=#modes; `AL≠0`+mode `CL` → `BX`=mode-name ptr | as noted |
| `init` | — (uses stored `curr_mode`) | enters graphics mode |
| `clear` | — | screen cleared to colour 0 |
| `post` | — | back to text mode |
| `move` | `AX=X, BX=Y` | CP updated |
| `draw` | `AX=X, BX=Y` | line CP→(X,Y); CP updated |
| `vect` | `AX=X1, BX=Y1, CX=X2, DX=Y2` | line drawn |
| `patbar` | `AX,BX = UL; CX,DX = LR` | filled bar |
| `palette` | `AH` top 2 bits select mode; `AL`=index; `BX`/`CX`/`DX` per mode | — |
| `colour` | `AL`=draw colour, `AH`=fill colour | stored |
| `fillstyle` | `AL`=pattern#; if `0FFh`, `ES:BX`=user 8-byte pattern | stored |
| `linestyle` | `AL`=style#; if ≥4, `BX`=user pattern; `CX`=width | stored |
| `textstyle` | `AL`=font, `AH`=dir(0 horiz/1 vert), `BX`=xsize, `CX`=ysize | stored |
| `text` | `ES:BX`=string, `CX`=length | rendered at CP |
| `textsize` | `ES:BX`=string, `CX`=length | `BX`=width, `CX`=height |
| `getpixel` | `AX=X, BX=Y` | `DL`=colour |
| `putpixel` | `AX=X, BX=Y, DL`=colour | pixel written |
| `floodfill` | `AX=X, BX=Y, CL`=boundary colour | region filled with fill colour |
| `savebitmap` | `ES:BX`=buffer, `CX,DX`=UL corner; buffer[0]=w−1, [2]=h−1 | image saved |
| `restorebitmap` | `ES:BX`=buffer, `CX,DX`=UL, `AL`=logical op | image drawn |
| `setclip` | `AX,BX = UL; CX,DX = LR` | clip rect set |
| `colourquery` | `AL=0` → `BX`=table len, `CX`=max colour; `AL≠0` → `BX`=table ptr | as noted |

Every routine returns with a **near `RET`** (it was near-called by the
entry stub). Preserve `BP`; the kernel expects `DS`/`ES` conventions to hold
on return (the stub restores `DS`). Bitmap-table entries (§6) are the
exception — they are **far** (`RETF`).

**Bitmap-font size/scaling (`textstyle`).** For the built-in 8×8 font the
kernel passes `BX` = desired character width in pixels; the driver derives a
magnification factor `textinc = BX / 8` and a scaled cell size
`textxsiz = textysiz = 8·textinc`. `text` then renders each lit font-cell
pixel as a **`textinc × textinc` block** (not a single pixel), so a
`SetTextStyle(…, charsize)` of 2 doubles the glyph. `text` advances by
`textxsiz` per character; `textsize` returns the scaled cell (swapping
width/height when `textdir=1`). Clamp `textinc` to a minimum of 1 so a
sub-8-pixel request still draws. See `CGA4.ASM`'s `princ`/`PlotBlock`/
`MulInc` for a worked implementation (and note `MulInc` avoids `MUL` so it
doesn't clobber `DX`, which `princ` uses to hold the rotating glyph-row bits).

### 5.2 install — the mode negotiation

`install` is called first, in three ways:

* `AL = 1` → **count query**: return the number of modes in `CX`.
* `AL <> 0`, `CL` = mode → **name query**: return a far/near pointer in `BX`
  to the mode's name string (`db len, "text", 0`).
* `AL = 0`, `CL` = mode → **select**: store `curr_mode := CL`, read the
  matching Device Information Table (§7), publish `xsiz`/`ysiz`/`xbytes`,
  and (for text) fetch the ROM font pointer via `INT 10h AX=1130h`.

`init` (0x02) later performs the actual mode switch using the stored
`curr_mode`.

---

## 6. The BitmapTable (emulation helpers)

`bitmaputil` (0x32) returns a pointer to an 8-entry table of **far**
routines the kernel's emulated arc/ellipse/pieslice code calls back into:

```asm
BitmapTable:
        dw  GotoGraphic     ; usually NotImpFar
        dw  ExitGraphic     ; usually NotImpFar
        dw  putpixel        ; the driver's PutPixel
        dw  getpixel        ; the driver's GetPixel
        dw  bits_per_pix    ; returns colour depth in AX
        dw  setdrawpage
        dw  setvispage
        dw  setwritemode
```

The table is **mixed**, and it must stay that way: the four helpers
(`bits_per_pix`, `setdrawpage`, `setvispage`, `setwritemode`, plus
`GotoGraphic`/`ExitGraphic`) are `proc far` and end in `RETF`, while
`putpixel` and `getpixel` are the *same near labels* used by `DDOVEC` and
end in a near `RET` — they have to, since the driver near-calls them
internally. Do not make the table uniform; match each entry's calling
convention exactly. Implementing correct `putpixel`/`getpixel` is enough to
make every emulated primitive work.

---

## 7. The Device Information Table (DIT / `Status`)

Each supported mode has a DIT describing its geometry. The kernel reads it
during `install` and exposes it to the app via `GetModeRange`,
`GetMaxX/Y`, `GetAspectRatio`, etc. Layout of the `Status` structure:

```
offset size field    meaning
------ ---- -------- --------------------------------------------
+0     db   stat     status code (0)
+1     db   devtyp   device type (0 for graphics adapters)
+2     dw   xres     device x-resolution − 1  (e.g. 319)
+4     dw   yres     device y-resolution − 1  (e.g. 199)
+6     dw   xefres   effective x-res − 1
+8     dw   yefres   effective y-res − 1
+10    dw   xinch    physical width  (arbitrary units, e.g. 9000)
+12    dw   yinch    physical height (e.g. 7000)
+14    dw   aspec    aspect ratio (×10000; CGA ≈ 4653)
+16    db   txtw     text-cell width  in px (8)
+17    db   txth     text-cell height in px (font height)
+18    db   —        (0x90; purpose unclear, kept for compatibility)
+19    db   —        (0x90)
```

Alongside the DITs the driver keeps parallel tables, both indexed by mode
number (from `CGA4.ASM`):

```asm
StatTable  dw  Stat0, Stat0, Stat0          ; DIT pointers, indexed by mode
ModeTable  dw  Mode0, Mode1, Mode2          ; mode-name string pointers
Mode0      db  12,"320x200x4@P0",0          ; length byte, text, NUL
```

The leading length byte must match the string. Modes that differ only in
how the display is driven can share one DIT, as all three CGA4 modes do.

Aspect ratio matters: it's how the kernel keeps `Circle`/`Arc` round. For a
square-pixel mode use 10000; for CGA 320×200 (non-square pixels) ≈ 4653.

---

## 8. Colour, palette, line & fill state

A driver holds mutable state set by the `colour`/`fillstyle`/`linestyle`/
`textstyle`/`setclip` routines and consumed by the drawing routines:

* `linecolour`, `fillcolour` — current draw/fill colour indices.
* `curr_linestyle` (16-bit rotating bit pattern), `linestyles[]` table
  (solid `FFFF`, dotted `CCCC`, center `FC78`, dashed `F8F8`).
* `fillpatnum` + `curr_fillpat[8]` — 8×8 fill bitmap; the standard 10
  patterns (line, slash, backslash, hatch, xhatch, interleave, dots, …) are
  in `fillpatterns[]`.
* `writemode` — 0 = COPY_PUT, 1 = XOR_PUT (used by `vect`/BITBLT).
* `clip_x1/y1/x2/y2` — clipping rectangle.
* `cp_x/cp_y` — current pointer.

`palette` (0x1A) decodes the top two bits of `AH`:

```
00b : BX = colour, AX = index          (set palette entry)
01b : (unsupported)
10b : BX=Red, CX=Green, DX=Blue, AX=idx (set RGB — VGA DAC)
11b : BX = background colour
```

On fixed-palette hardware (CGA) it is legitimate to **accept-and-ignore**
these — store nothing, just `RET`. Drawing still works against the active
hardware palette.

---

## 9. Writing a driver — step by step

### 9.1 Choose the target CPU

BGI drivers run on whatever the graphics card implies. CGA/EGA-era hardware
is **8086/8088**. Assemble accordingly:

* **NASM:** put `cpu 8086` at the top. NASM then refuses 186+/386-only
  encodings and *synthesises* out-of-range conditional jumps as
  `Jcc short` + `jmp near` (a bare `jnz far_label` would otherwise assemble
  to the 386-only `0F 85` two-byte form and fault on an 8086).
* **No 186 shift-by-immediate.** `shr bx,3` is a 186 instruction; on an 8086
  do three `shr bx,1`, or load `CL` and `shr bx,cl`.
* MASM users write `.186`/`.286` as the card allows and let the assembler
  pick encodings, but keep an 8086 floor if the card is CGA/EGA.

### 9.2 Skeleton (NASM, v2.0)

```asm
        bits 16
        cpu  8086
        org  0

DDOVEC_ADDR equ DDOVEC           ; forward ref resolved by the assembler

BgiEntry:
        push ds
        push cs
        pop  ds
        cld
        push bp
        call word [si+DDOVEC]
        pop  bp
        pop  ds
        retf
        db   'CB', 0, 2          ; signature + version (CB at image+0x0C)

EMULATE:  ret                    ; NEAR (§4) - retf here jumps to a wild address
          dw 0,0
NotImpNear: ret
NotImpFar:  retf

; ---- primitives ----
install:  … ret
init:     … ret
; …
putpixel: … ret
getpixel: … ret

; ---- dispatch table ----
DDOVEC:
        dw install, init, clear, post, move, draw, vect
        dw EMULATE, EMULATE, patbar, EMULATE, EMULATE, EMULATE
        dw palette, setallpalette, colour, fillstyle, linestyle
        dw textstyle, text, textsize, EMULATE, floodfill
        dw getpixel, putpixel, bitmaputil, savebitmap, restorebitmap
        dw setclip, colourquery
        times 16 dw NotImpNear

BitmapTable:
        dw NotImpFar, NotImpFar, putpixel, getpixel
        dw bits_per_pix, setdrawpage, setvispage, setwritemode

; ---- DITs + mode names ----
Stat0:  db 0,0
        dw XRES-1, YRES-1, XRES-1, YRES-1
        dw 9000, 7000, ASPECT
        db 8, FONT_H, 90h, 90h
Mode0:  db 13, "CGA 320x200x4", 0
StatTable: dw Stat0
ModeTable: dw Mode0

; ---- state variables ----
cp_x dw 0
…
```

### 9.3 Implement the primitives

Start with **`putpixel`/`getpixel`** — with those and the DDOVEC/BitmapTable
wired up, `Line`, `Circle`, `Bar`, `FloodFill`, and text all work (the
kernel emulates the rest). Then optimise: a native `vect` (Bresenham), a
native `patbar`, native BITBLT. See `CGA4.ASM` for a full packed-pixel
example and `VGA16.ASM` for a planar one.

### 9.4 Hardware-specific address math

The one thing every driver gets wrong first is the framebuffer address
calculation. Isolate it in one routine (`CalcAddr`) and unit-test it
(see §10). Two worked examples:

* **CGA 320×200×4** (packed 2 bpp, interleaved): video segment `B800h`,
  even scanlines at offset 0, **odd scanlines at +2000h**, 80 bytes/row,
  4 pixels/byte.

  ```
  offset = (Y >> 1) * 80 + (X >> 2)     ; +2000h if Y is odd
  shift  = (3 - (X & 3)) * 2            ; bit position of the 2-bit pixel
  ```

  **Trap:** `MUL` clobbers `DX`. If you stash the Y-parity bit in `DL`
  before `mul xbytes`, it is destroyed. Save it across the multiply (push
  it, or test parity first).

* **EGA/VGA planar** (`VGA16.ASM`): video segment `A000h`, 1 bit/pixel/plane
  across 4 planes, address = `Y*xbytes + X/8`, pixel selected by
  Graphics-Controller port writes — no interleave.

### 9.5 The single-`init` / mode-set rule

`install` (mode select) must not switch video modes — it only records state
and reads the DIT. `init` performs the `INT 10h` mode switch. `post`
restores text mode (`INT 10h AX=0003h`). Keep these three cleanly separated;
Borland calls them at distinct lifecycle points.

---

## 10. Building and testing

> **This project:** `SRC/TLINK/TLINK.MOD`'s `/T=bgi2` mode (module `Bgi2`
> in `SRC/TLINK/BGI2.MOD`) links a NASM-subset `.asm` source (via
> `tasm.exe`) directly into a `.BGI` file in one step — no separate
> `mkbgi`/`exe2bin` pass needed: `tasm DRV.ASM` then `tlink /T=bgi2
> [/D=descr] [/C=copyright] DRV.RDF DRV.BGI`. See `DOCS/BUILD.MD`
> §"Using tlink" for the full CLI and `TESTS/FIX/TLKBGI.ASM` for a minimal
> worked skeleton. The `mkbgi`/NASM pipeline below is the format's
> general reference recipe, not this project's own build path.

### 10.1 Build pipeline

Classic Borland pipeline (MASM):

```
tasm /dBGIVERSION=2 DRV.asm, DRV.obj ;
tlink /3 DRV.obj
exe2bin DRV.exe DRV.bin
mkbgi DRV
```

NASM pipeline (used by `BGI/CGABGI`, no TLINK/EXE2BIN needed — NASM emits
the flat image directly):

```
nasm -f bin -o DRV.BIN DRV.ASM      ; flat 16-bit image
mkbgi DRV                            ; prepend the BGI v2.0 header → DRV.BGI
```

`mkbgi` is `MKBGI.MOD` — an Oberon-07 header generator (built with
Trubo Oberon). It reads
`DRV.BIN`, writes the exact 0xA0-byte v2.0 header (§3), and appends the
image.

### 10.2 Header-generator checklist (what `mkbgi` gets right)

1. `pk 08 08` magic at 0x00.
2. Banner text, then `0D 0A`, copyright, `0D 0A`, then **`00 1A`**.
3. **First 10-byte block immediately after `00 1A`.**
4. Zero-pad to 0x80.
5. **Second 10-byte block at 0x80.**
6. **Namelen byte + name immediately after the block (0x8A).**
7. Zero-pad to 0xA0.
8. Append the driver image verbatim; `codeSize` = image length.

---

## 11. Quick reference card

```
Header (v2.0):
  0x00  "pk" 08 08
  0x04  banner 0D0A copyright 0D0A 00 1A
  ....  block1 (10 bytes)         right after 00 1A
  ....  pad → 0x80
  0x80  block2 (10 bytes)
  0x8A  namelen, name
  ....  pad → 0xA0
  0xA0  image

Header block (10 bytes):
  dw headerSize(A0) | dw driverNum(0) | dw codeSize |
  db ver(2) rev(0) minVer(1) minRev(0)

Entry stub (v2.0), image+0x00:
  1E 0E 1F FC 55 FF 94 <DDOVEC ofs> 5D 1F CB   ('CB' at image+0x0C)

Dispatch SI index → routine: 00 install, 02 init, 04 clear, 06 post,
  08 move, 0A draw, 0C vect, 12 patbar, 1A palette, 1C setallpalette,
  1E colour, 20 fillstyle, 22 linestyle, 24 textstyle, 26 text,
  28 textsize, 2C floodfill, 2E getpixel, 30 putpixel, 32 bitmaputil,
  34 savebitmap, 36 restorebitmap, 38 setclip, 3A colourquery.
  (0E/10/14/16/18/2A → EMULATE.)

CGA 320x200x4:  seg B800h; even rows +0, odd rows +2000h; 80 B/row;
  offset=(Y>>1)*80+(X>>2); shift=(3-(X&3))*2; 2 bpp.
```

---
