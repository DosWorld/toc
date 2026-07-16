; TN4MOVWRAP.ASM -- regression fixture: BUG N4, a word immediate outside
; -32768..65535 must be fatal, not silently wrapped mod 65536
; ("mov ax, 70000" -> "mov ax, 4464"). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, 70000
    ret
