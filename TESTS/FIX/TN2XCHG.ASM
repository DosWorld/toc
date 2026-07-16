; TN2XCHG.ASM -- regression fixture: BUG N2, "xchg ax, bl" hits the AX
; short-form arm (90+r) which is WORD-only -- EncXchg must reject a
; byte-sized other operand instead of silently swapping AX,BX. Checked
; via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    xchg ax, bl
    ret
