; TR6INTLBL.ASM -- regression fixture for TASM.MD BUG R6: EncInt/EncRet/
; EncIn/EncOut wrote their immediate operand directly, bypassing
; EmitImm's A6 label guard, and checked only kind = OKImm -- a label
; operand IS OKImm with disp holding just the constant part (0), so
; "int deflabel" (deflabel is a DEFINED label, so BUG A1's
; undefined-symbol check does not catch it) silently assembled to
; "INT 0" with no diagnostic. Must now be a fatal "label not allowed
; here" error. Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
deflabel:
Foo:
    int deflabel
    ret
