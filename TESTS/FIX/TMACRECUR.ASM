; TMACRECUR.ASM -- regression fixture: a macro that invokes itself must
; be a fatal "macro expansion nested too deep" error (the source-stack
; depth cap), not an infinite expansion loop / hang.
bits 16
cpu 8086
section .text
global Foo
%macro recur 0
    recur
%endmacro
Foo:
    recur
    ret
