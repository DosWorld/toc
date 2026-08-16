bits 16
cpu 8086
; DB deliberately rejects a bare LABEL (a 16-bit address, not a byte-sized
; constant) -- unlike DW/DD, DB has no relocation-emission path, so
; silently truncating a label's address to one byte would corrupt data,
; not just be an odd feature gap. DB values go through ParseConstExpr
; (the shared expression evaluator also used by RESB/RESW/RESD/TIMES/
; EQU/%assign), which rejects any label term outright.
section .text
global start
start:
    ret
target:
    ret
    db target
