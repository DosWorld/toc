; TMACERR.ASM -- regression fixture: a diagnostic raised INSIDE a %macro
; expansion must name the real source file. InvokeMacro used to call
; CurFname AFTER pushing the expansion slot, seeding the expansion
; scanner's fname from the new slot's stale/blank field -- every error
; inside a macro body printed "ERROR:(line):" with an empty filename.
; The test greps for "TMACERR.ASM(" in the diagnostic, so a blank
; filename fails the row even though the error itself still fires.
bits 16
cpu 8086
section .text
global Foo
%macro bad 0
    mov ax,
%endmacro
Foo:
    bad
    ret
