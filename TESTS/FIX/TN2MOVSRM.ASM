; TN2MOVSRM.ASM -- regression fixture: N2-family residual, "mov" between
; a segment register and a BYTE-qualified memory operand used to
; silently ignore the qualifier (8C/8E always move a word). Must be a
; fatal size mismatch. Checked via TESTS/test_tasm.sh's check_fails
; helper.
bits 16
cpu 8086
section .data
x: db 0
section .text
global Foo
Foo:
    mov byte [x], ds
    ret
