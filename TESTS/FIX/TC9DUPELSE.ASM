; TC9DUPELSE.ASM -- regression fixture for TASM.MD BUG C9: a duplicate
; %else for the same %ifdef was silently accepted and re-toggled nothing
; detectably. Must now be a fatal error.
bits 16
cpu 8086
%define WANT_A
section .text
global Foo
Foo:
%ifdef WANT_A
    mov ax, 1
%else
    mov ax, 2
%else
    mov ax, 3
%endif
    ret
