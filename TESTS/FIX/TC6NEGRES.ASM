; TC6NEGRES.ASM -- regression fixture for TASM.MD BUG C6: a negative
; RESB/RESW/RESD count at SECTION .bss statement level silently SHRINKS
; bssOfs (later labels then overlap earlier reservations) instead of
; erroring. Must now be a fatal error.
bits 16
cpu 8086
section .bss
buf: resb -2048

section .text
global Foo
Foo:
    ret
