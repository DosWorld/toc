; TC5INTRANGE.ASM -- regression fixture for TASM.MD BUG C5: INT vec
; silently truncated any out-of-range vector via BYTE(vec) (e.g.
; "int 999" wrote INT E7h). Must now be a fatal range error instead.
bits 16
cpu 8086
section .text
global Foo
Foo:
    int 999
