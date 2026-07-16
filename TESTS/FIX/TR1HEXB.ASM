; TR1HEXB.ASM -- regression fixture for TASM.MD BUG R1: an A7-fix
; regression where the trailing b/B binary-literal check ran BEFORE the
; 0x prefix check, so any "0x...b"-shaped hex literal (0xb, 0x1b, 0xABB)
; was misclassified as binary and rejected with "bad binary literal".
; Fixed by testing the 0x prefix first and skipping the binary branch
; when it matches. Also keeps a plain binary literal (101b) passing, so
; a sloppy fix that always skips the binary branch would be caught here.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov al, 0x1b
    mov ax, 0xABB
    mov bl, 101b
    ret
