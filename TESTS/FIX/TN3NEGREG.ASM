; TN3NEGREG.ASM -- regression fixture: BUG N3/M3, "-" before a register
; inside [ ] was silently dropped -- "[bx-si]" assembled as "[bx+si]"
; (8B 00) instead of failing (NASM rejects [bx-si] as an invalid
; effective address; a register can never be legally negated on 8086).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, [bx-si]
    ret
