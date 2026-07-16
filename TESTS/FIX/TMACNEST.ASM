; TMACNEST.ASM -- regression fixture: a %macro defined inside another
; %macro's body must be a fatal "nested %macro not supported" error, not
; silently mis-scoping the outer macro's body at the first %endmacro
; encountered.
bits 16
cpu 8086
section .text
global Foo
%macro outer 1
    mov ax, %1
%macro inner 1
    mov bx, %1
%endmacro
%endmacro
Foo:
    ret
