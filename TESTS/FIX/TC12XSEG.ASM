; TC12XSEG.ASM -- regression fixture for TASM.MD BUG C12: a short branch
; to a label defined in a different segment (here .data) computed a rel8
; across segments -- a meaningless value, silently accepted whenever it
; happened to land inside the +-128 range. Must now be a fatal error.
bits 16
cpu 8086
section .data
dataLabel: dw 0

section .text
global Foo
Foo:
    jne short dataLabel
    ret
