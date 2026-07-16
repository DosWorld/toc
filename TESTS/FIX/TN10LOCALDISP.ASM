; TN10LOCALDISP.ASM -- regression fixture: BUG N10, a local-label operand
; did not accept a trailing "+disp"/"-disp" chain, unlike the bare-ident
; branch -- "jmp .loop+0" used to fall through to the generic A2
; no-progress guard ("unexpected token at start of statement") instead of
; either working or naming the real problem. Checked via
; TESTS/test_tasm.sh's check_one byte-diff helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
.loop:
    nop
    jmp .loop+0
    ret
