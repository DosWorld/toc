; TUNDEF.ASM -- regression fixture: a reference to a symbol that is never
; defined (locally) and never declared EXTERN must be a fatal "undefined
; symbol" error, not silently resolve to code-segment offset 0 (BUG A1).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    call MisspeldTarget
    ret
