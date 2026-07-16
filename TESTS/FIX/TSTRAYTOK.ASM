; TSTRAYTOK.ASM -- regression fixture: a line starting with a token that is
; neither a label/directive/instruction start (a bare number here) must be
; a fatal "unexpected token" error, not an infinite loop in RunPass (BUG A2:
; ParseLine consumed nothing and returned, re-entering on the identical
; token forever). Checked via TESTS/test_tasm.sh's check_fails helper
; (which itself relies on xt's --max instruction budget to convert a real
; hang into a nonzero exit, but the fix means this never reaches that
; budget at all).
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, 1
42
    ret
