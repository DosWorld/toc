; TJCC2.ASM -- regression fixture for the full Jcc set completion (v2
; "full 8086 coverage" plan, batch 3): signed-comparison, overflow, and
; parity conditional jumps. No independent NASM oracle: the local nasm
; build lacks the rdf output backend. Expected TJCC2.RDF was hand-verified
; byte-for-byte against the 8086 70h-7Fh Jcc opcode map before being
; adopted as the regression baseline -- see DOCS/TESTS.MD "TASM assembler
; regression test".
bits 16
cpu 8086
section .text
global Foo
Foo:
L1:
    jo   L1
    jno  L1
    jp   L1
    jpe  L1
    jnp  L1
    jpo  L1
    jl   L1
    jnge L1
    jge  L1
    jnl  L1
    jle  L1
    jng  L1
    jg   L1
    jnle L1
    retf
