; TN2XCHGM.ASM -- regression fixture: N2-family residual, "xchg" with an
; explicitly BYTE-qualified memory operand against a word register used
; to silently ignore the qualifier and encode a word XCHG (87). Must be
; a fatal size mismatch, same guard family as EncAlu's R2 fix. Checked
; via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .data
x: db 0
section .text
global Foo
Foo:
    xchg byte [x], ax
    ret
