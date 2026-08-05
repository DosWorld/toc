bits 16
cpu 8086
; DB deliberately rejects a bare LABEL (a 16-bit address, not a byte-sized
; constant) -- unlike DW/DD, DB has no relocation-emission path, so
; silently truncating a label's address to one byte would corrupt data,
; not just be an odd feature gap. Regression for the fix that added
; EQU-constant support to ParseDbList: the new identifier branch must
; only accept EQU constants (Sym.LookupConst), never fall through to
; accepting an arbitrary label.
section .text
global start
start:
    ret
target:
    ret
    db target
