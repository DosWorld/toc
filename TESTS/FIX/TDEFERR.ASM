; TDEFERR.ASM -- regression fixture: a diagnostic raised INSIDE a
; %define substitution must name the real source file (the S2 refactor
; pushed %define substitutions onto the input-source stack and copied
; InvokeMacro's CurFname-after-INC ordering bug, blanking the filename).
; The test greps for "TDEFERR.ASM(" in the diagnostic.
bits 16
cpu 8086
%define BAD ]
section .text
global Foo
Foo:
    mov ax, BAD
    ret
