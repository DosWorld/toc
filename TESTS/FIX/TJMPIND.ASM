; TJMPIND.ASM -- regression fixture for BUG 1 (SRC/TASM/TASM.MD):
; EncJmpIndirect was missing its leading 0FFh opcode byte, so `jmp [mem]`
; assembled to a bare ModRM byte (e.g. `jmp [bx]` -> stray 27h, decoded by
; the CPU as DAA) instead of `FF /4`. Fixed by adding `B(BYTE(0FFH))` as
; EncJmpIndirect's first line, matching EncCallIndirect right next to it.
; Covers both the register-indirect and memory-indirect near forms, plus
; the far form (`jmp far [bx]` -> FF /5) for completeness.
bits 16
cpu 8086
section .data
tbl: dw 0

section .text
global Foo
Foo:
    mov  bx, tbl
    jmp  [bx]
    jmp  far [bx]
    retf
