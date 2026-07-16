; TMACARG3.ASM -- regression fixture: a %macro body referencing %3 when
; the macro only declares 2 parameters must be a fatal "macro parameter
; %n beyond nParams" error.
bits 16
cpu 8086
section .text
global Foo
%macro addtwo 2
    mov ax, %1
    add ax, %3
%endmacro
Foo:
    addtwo 3, 4
    ret
