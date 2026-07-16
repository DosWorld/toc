; TBSS.ASM -- regression fixture for SECTION .bss support (v2 "full 8086
; coverage" plan follow-up): RESB/RESW/RESD reserve uninitialized space
; without emitting any bytes, and code can reference a .bss label via a
; normal RELOC (absolute reference) exactly like a .data label. No
; independent NASM oracle: the local nasm build lacks the rdf output
; backend. Expected TBSS.RDF was hand-verified byte-for-byte (code bytes
; + a RDFREC_BSS header record for the reserved total) before being
; adopted as the regression baseline -- see DOCS/TESTS.MD "TASM assembler
; regression test".
bits 16
cpu 8086
section .bss
counter: resw 1
buffer:  resb 10
big:     resd 1

section .text
global Foo
Foo:
    mov ax, [counter]
    mov bx, buffer
    mov cx, [big]
    retf
