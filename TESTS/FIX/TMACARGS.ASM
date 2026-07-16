; TMACARGS.ASM -- regression fixture: a %macro invocation with the wrong
; number of arguments must be a fatal "macro argument count mismatch"
; error.
bits 16
cpu 8086
section .text
global Foo
%macro addtwo 2
    mov ax, %1
    add ax, %2
%endmacro
Foo:
    addtwo 3
    ret
