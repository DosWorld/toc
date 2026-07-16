; TN2MOVBA.ASM -- regression fixture: BUG N2, "mov bx, al" mixes a word
; dst with a byte src -- same reg-code-overlap trap as TN2MOVAB but with
; dst/src swapped (dst in r/m, src in /reg -- EncMov's reg,reg arm must
; catch it on this side too). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov bx, al
    ret
