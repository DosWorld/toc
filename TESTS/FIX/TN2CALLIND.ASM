; TN2CALLIND.ASM -- regression fixture: BUG N2, "call al" / "jmp al"
; target a register in the FF /2 indirect-call encoding, which is
; WORD-only (there is no 8-bit indirect call/jmp on 8086). EncCallIndirect
; must reject a non-WORD register operand instead of silently emitting
; "call ax". Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    call al
    ret
