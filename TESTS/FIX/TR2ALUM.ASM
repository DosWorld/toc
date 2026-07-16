; TR2ALUM.ASM -- regression fixture for TASM.MD BUG R2: a B1-fix
; regression where EncAlu/EncTest's mem,reg opcode-width selection used
; dst.size (the memory operand, SzNone for an unqualified [mem]) instead
; of src.size (the register operand) -- add [w], ax silently emitted the
; BYTE opcode (00) with a word register instead of the WORD opcode (01).
; Fixed by deriving width from the register operand in the reg->mem arms
; of EncAlu/EncTest.
bits 16
cpu 8086
section .data
w: dw 0
section .text
global Foo
Foo:
    add [w], ax
    and byte [w], al
    test [w], ax
    cmp [w], bx
    ret
