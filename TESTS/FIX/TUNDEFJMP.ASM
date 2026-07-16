; TUNDEFJMP.ASM -- regression fixture: a conditional jump to a never-
; defined, never-EXTERN label must be a fatal "undefined symbol" error
; (BUG A1), not a silent wild backward jump to offset 0.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    cmp ax, 0
    jne NoSuchLabel
    ret
