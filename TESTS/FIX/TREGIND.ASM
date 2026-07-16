; TREGIND.ASM -- regression fixture: register-indirect JMP/CALL (`jmp bx`,
; `call bx`).  Before this fix, EncJmpAuto/EncNearRel required a label
; operand and rejected a bare register with "JMP target must be a label";
; EmitModRm already handled OKReg correctly (mode=3, ModRmByte(3,reg,mem.reg))
; via EncJmpIndirect/EncCallIndirect, but the MJmp/MCall dispatch in
; TranslateOpcode only checked for OKMem, never OKReg, so it never reached
; that path.  Fixed by adding "OR (ops[0].kind = OKReg)" to both dispatch
; checks. `far reg` is rejected with a real error (no segment half fits in
; one register) rather than silently emitting a near form under a far
; reg-field.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov  bx, Target
    jmp  bx
    call bx
Target:
    ret
