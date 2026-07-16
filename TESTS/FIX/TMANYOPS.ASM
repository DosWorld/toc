; TMANYOPS.ASM -- regression fixture: an instruction with a 4th operand
; must be a fatal "too many operands" error, not an infinite loop (BUG A2:
; ParseInstruction stopped at MaxOperands leaving the trailing comma
; unconsumed, so RunPass re-entered ParseLine on the same TComma forever).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, bx, cx, dx
    ret
