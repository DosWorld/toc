; TBADRETIMM.ASM -- regression fixture: "ret ax" (register operand where
; RET only accepts an imm16 stack-adjust) must be a fatal error, not
; silently emit W(imm.disp) of an uninitialised disp field (BUG A3).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    ret ax
