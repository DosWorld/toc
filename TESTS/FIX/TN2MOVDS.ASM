; TN2MOVDS.ASM -- regression fixture: BUG N2, "mov ds, al" pairs a
; segment-register dst with a byte r/m source in the 8E /r encoding,
; which always moves a WORD into the segment register. EncMov's Sreg arm
; must reject a non-WORD r/m register instead of silently emitting
; "mov ds, ax". Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ds, al
    ret
