; TSHIFT.ASM -- regression fixture for the ROL/ROR/SAR/SAL shift/rotate
; group completion (v2 "full 8086 coverage" plan, batch 1). No independent
; NASM oracle: the local nasm build lacks the rdf output backend. Expected
; TSHIFT.RDF was hand-verified byte-for-byte against the 8086 D0-D3 opcode
; table (reg field = /ext: ROL=0, ROR=1, SAR=7, SAL=4 same as SHL) before
; being adopted as the regression baseline -- see DOCS/TESTS.MD
; "TASM assembler regression test".
bits 16
cpu 8086
section .data
val: dw 0

section .text
global Foo
Foo:
    mov  bx, val
    rol  byte [bx], 1
    rol  word [bx], 1
    rol  cx, 1
    rol  bl, cl
    ror  byte [bx], 1
    ror  word [bx], 1
    ror  cx, 1
    ror  bl, cl
    sar  byte [bx], 1
    sar  word [bx], 1
    sar  cx, 1
    sar  bl, cl
    sal  byte [bx], 1
    sal  word [bx], 1
    sal  cx, 1
    sal  bl, cl
    retf
