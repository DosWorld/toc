; TINCMISS.ASM -- regression fixture: %include of a nonexistent file must
; be a fatal "cannot open include file" error.
bits 16
cpu 8086
section .text
global Foo
Foo:
%include "NOSUCH.INC"
    ret
