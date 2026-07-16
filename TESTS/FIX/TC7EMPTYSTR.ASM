; TC7EMPTYSTR.ASM -- regression fixture for TASM.MD BUG C7: an empty
; string literal '' as an immediate passed the old (tSval[1] # 0X) check
; (both tSval[0] and tSval[1] are 0X) and silently yielded immediate 0.
; Must now be a fatal error.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov al, ''
