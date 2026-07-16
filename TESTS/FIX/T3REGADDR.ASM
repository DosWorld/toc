; T3REGADDR.ASM -- regression fixture: three base/index registers inside
; [ ] (e.g. [bx+si+di]) have no 8086 addressing mode -- must be a fatal
; "too many registers in address" error, not silently keep the first two
; and drop the third with no diagnostic (BUG B4).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, [bx+si+di]
    ret
