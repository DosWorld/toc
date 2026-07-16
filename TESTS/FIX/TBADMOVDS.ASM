; TBADMOVDS.ASM -- regression fixture: "mov ds, 5" (segment register
; destination, plain-immediate source) has no valid 8086 encoding -- MOV
; Sreg only accepts r/m16 as its source, never an immediate. Before BUG
; A3's fix this silently fell through to EmitModRm treating the OKImm
; source as a memory operand with garbage addressing fields. Now must be
; a fatal error. Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ds, 5
    ret
