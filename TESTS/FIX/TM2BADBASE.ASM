; TM2BADBASE.ASM -- regression fixture: BUG M2, "[ax]" is not a legal
; 8086 base/index register (only BX/BP/SI/DI can appear inside [ ]).
; The old parser fell through to the identifier/label branch and
; reported a misleading "undefined symbol ax" -- or worse, if a label
; named "ax" existed, silently assembled a direct-memory reference.
; ParseMemBody must now reject it with a clear diagnostic. Checked via
; TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov bx, [ax]
    ret
