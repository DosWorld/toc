; TNOSIZEMOV.ASM -- regression fixture: "mov [x], 5" with no size qualifier
; and no register operand to infer width from must be a fatal "operation
; size not specified" error (BUG B1), not a silent WORD default.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .bss
X: resb 1
section .text
global Foo
Foo:
    mov [X], 5
    ret
