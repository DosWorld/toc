; TMACRO.ASM -- regression fixture for TASM.MD §I.4: %macro NAME NPARAMS
; ... %endmacro with %1/%2 parameter substitution and a %%local branch
; label. addtwo is invoked twice with different arguments (proves %1/%2
; substitute correctly per-invocation, not just once); checkpos exercises
; %%skip -- each invocation must get its OWN uniquely-named local label
; so the two jl/mov bx,1 sequences don't collide.
bits 16
cpu 8086
section .text
global Foo

%macro addtwo 2
    mov ax, %1
    add ax, %2
%endmacro

%macro checkpos 1
    cmp ax, %1
    jl %%skip
    mov bx, 1
%%skip:
%endmacro

Foo:
    addtwo 3, 4
    addtwo 10, 20
    checkpos 5
    checkpos 10
    ret
