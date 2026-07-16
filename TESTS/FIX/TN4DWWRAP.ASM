; TN4DWWRAP.ASM -- regression fixture: BUG N4, "dw 70000" must be fatal,
; not silently wrapped mod 65536. Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .data
    dw 70000
section .text
global Foo
Foo:
    ret
