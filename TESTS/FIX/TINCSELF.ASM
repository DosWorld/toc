; TINCSELF.ASM -- regression fixture: a %include cycle (a file including
; itself, directly or transitively) must be a fatal "recursive %include"
; error, not silently recursed until %include nested too deep fires with
; a confusing message.
bits 16
cpu 8086
section .text
global Foo
Foo:
%include "TINCSELF.ASM"
    ret
