; TNOOP4.ASM -- regression fixture for the no-operand-opcode + PUSH-imm +
; far-direct-JMP/CALL completion (v2 "full 8086 coverage" plan, batch 4).
; No independent NASM oracle: the local nasm build lacks the rdf output
; backend. Expected TNOOP4.RDF was hand-verified byte-for-byte against the
; 8086 opcode map before being adopted as the regression baseline -- see
; DOCS/TESTS.MD "TASM assembler regression test".
bits 16
cpu 8086
section .text
global Foo
Far1:
    retf
Foo:
    cbw
    cwd
    hlt
    xlat
    into
    aaa
    aas
    aam
    aad
    daa
    das
    push word 1234
    push byte 5
    jmp far Far1
    call far Far1
    retf
