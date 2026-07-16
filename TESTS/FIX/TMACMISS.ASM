; TMACMISS.ASM -- regression fixture: a %macro with no matching
; %endmacro before EOF must be a fatal "missing %endmacro" error.
bits 16
cpu 8086
section .text
global Foo
%macro addtwo 2
    mov ax, %1
    add ax, %2
Foo:
    ret
