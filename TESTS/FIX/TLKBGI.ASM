bits 16
cpu 8086

; Minimal skeleton BGI v2.0 driver image for /T=bgi2 regression.  Not a
; real hardware driver -- just enough structure (entry stub at offset 0,
; 'CB' signature at +0x0C, DDOVEC table, one real primitive) to prove
; TLINK's header-writer produces a byte-correct BGI v2.0 file per
; DOCS/BGI.MD.  'start' is deliberately the very first label (offset 0),
; required by /T=bgi2 (CalculateLayoutTiny rejects anything else).

section .text
global start
start:
        push    ds
        push    cs
        pop     ds
        cld
        push    bp
        call    word [si+DDOVEC]
        pop     bp
        pop     ds
        retf
        db      'CB', 0, 2          ; signature + version, MUST be at +0x0C

EMULATE:
        ret                         ; near -- see DOCS/BGI.MD 4.3
        dw      0, 0

install:
        ret
init:
        ret
putpixel:
        ret
getpixel:
        ret

DDOVEC:
        dw install, init, EMULATE, EMULATE, EMULATE, EMULATE, EMULATE
        dw EMULATE, EMULATE, EMULATE, EMULATE, EMULATE, EMULATE
        dw EMULATE, EMULATE, EMULATE, EMULATE, EMULATE
        dw EMULATE, EMULATE, EMULATE, EMULATE, EMULATE
        dw getpixel, putpixel, EMULATE, EMULATE, EMULATE
        dw EMULATE, EMULATE

section .data
driverTag: db 'TLKBGI-fixture', 0
