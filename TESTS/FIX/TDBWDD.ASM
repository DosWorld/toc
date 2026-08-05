bits 16
cpu 8086
; DB/DW/DD accepting EQU constants (with +/- tail) and DD accepting a
; label (32-bit address: 16-bit in-module offset zero-extended, width=4
; relocation) -- self-consistency baseline, not a real-NASM oracle.
FOO equ 8
BAR equ 300
section .text
global start
start:
    ret
    db FOO          ; 08
    db FOO-1         ; 07
    db FOO+1         ; 09
    dw FOO           ; 08 00
    dw BAR-1         ; 2B 01
    dd BAR           ; 2C 01 00 00
    dd start         ; RELOC width=4 to SegCode, addend = start's own offset
    times 3 db 0
    times 2 dw 0
    times 2 dd 0
