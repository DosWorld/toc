; TN4LBLWRAP.ASM -- regression fixture: N4-family residual, a label
; operand's "+n" addend ("mov ax, tbl+70000") wrapped mod 65536 silently
; -- the N4 guard originally covered only the non-label arm of
; EmitDisp16/EmitDataWordMaybeLabel. Must be fatal. Checked via
; TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .data
tbl: dw 0
section .text
global Foo
Foo:
    mov ax, tbl+70000
    ret
