; TNOSIZE.ASM -- regression fixture: an unsized memory operand (no
; BYTE/WORD qualifier, no register operand to infer width from) must be a
; fatal "operation size not specified" error, matching real NASM, not a
; silent WORD assumption that can corrupt an adjacent byte in a hand-
; ported byte buffer (BUG B1). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .bss
Count: resb 1
section .text
global Foo
Foo:
    inc [Count]
    ret
