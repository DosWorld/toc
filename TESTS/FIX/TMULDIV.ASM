; TMULDIV.ASM -- regression fixture for the IMUL/DIV/IDIV F6/F7 unary group
; (v2 "full 8086 coverage" plan, batch 2). No independent NASM oracle: the
; local nasm build lacks the rdf output backend. Expected TMULDIV.RDF was
; hand-verified byte-for-byte against the 8086 F6/F7 opcode table (reg
; field = /ext: IMUL=5, DIV=6, IDIV=7) before being adopted as the
; regression baseline -- see DOCS/TASM_PLAN.MD "Testing strategy for v2".
bits 16
cpu 8086
section .data
val: dw 0

section .text
global Foo
Foo:
    mov  bx, val
    imul byte [bx]
    imul word [bx]
    imul cx
    imul bl
    div  byte [bx]
    div  word [bx]
    div  cx
    div  bl
    idiv byte [bx]
    idiv word [bx]
    idiv cx
    idiv bl
    retf
