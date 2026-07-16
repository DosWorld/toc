; TN2MOVAB.ASM -- regression fixture: BUG N2, "mov al, bx" mixes a byte
; dst with a word src -- reg codes overlap (AL=0=AX, BL=3=BX), so a naive
; encoder silently renames src to BL. EncMov's reg,reg arm must reject the
; size mismatch instead. Checked via TESTS/test_tasm.sh's check_fails
; helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov al, bx
    ret
