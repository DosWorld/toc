; TBADPUSH.ASM -- regression fixture: "push" applied to a bare label
; (immediate-with-label, not a register/segreg/plain-immediate/[mem]) must
; be a fatal error, not silently routed into EncPushMem with a garbage
; addressing mode (BUG A3). Checked via TESTS/test_tasm.sh's check_fails
; helper.
bits 16
cpu 8086
section .data
MyLabel: dw 0
section .text
global Foo
Foo:
    push MyLabel
    ret
