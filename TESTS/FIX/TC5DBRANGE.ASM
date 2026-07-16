; TC5DBRANGE.ASM -- regression fixture for TASM.MD BUG C5: DB N silently
; truncated any out-of-range N via BYTE(N) (e.g. "db 300" wrote byte 44).
; Must now be a fatal range error instead.
bits 16
cpu 8086
section .text
global Foo
Foo:
    db 300
