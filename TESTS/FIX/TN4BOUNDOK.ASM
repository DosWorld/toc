; TN4BOUNDOK.ASM -- regression fixture: BUG N4's guard must not reject
; legal boundary values -- 65535 (max unsigned word) and -32768 (min
; signed word) must still assemble. Checked via TESTS/test_tasm.sh's
; check_one byte-diff helper.
bits 16
cpu 8086
section .data
    dw 65535
    dw -32768
section .text
global Foo
Foo:
    mov ax, 65535
    ret
