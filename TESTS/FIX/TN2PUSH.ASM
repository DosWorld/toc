; TN2PUSH.ASM -- regression fixture: BUG N2, "push al" has no byte PUSH
; encoding on 8086 -- EncPushPopReg must reject a non-WORD register
; instead of silently emitting 50H (push ax). Checked via
; TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    push al
    ret
