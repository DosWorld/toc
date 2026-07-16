; TCLIDEF.ASM -- regression fixture for TASM.MD §I.2: -D/-Dname=value
; CLI predefines, applied as if "%define name value" appeared before
; line 1. With -DFEATURE -DVAL=5, the %ifdef branch is taken and VAL
; expands to 5 (mov ax, 5); without any -D, the %else branch is taken
; (mov ax, 0).
bits 16
cpu 8086
section .text
global Foo
Foo:
%ifdef FEATURE
    mov ax, VAL
%else
    mov ax, 0
%endif
    ret
