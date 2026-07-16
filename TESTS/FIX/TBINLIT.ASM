; TBINLIT.ASM -- regression fixture: NASM-style binary integer literals
; (101b) must actually parse (BUG A7: the digit-gathering loop in
; ScanNumber consumed the trailing 'b' as a hex digit before the binary-
; suffix branch ever got to see it, so the branch was permanently dead
; code and every binary literal failed with "bad decimal literal").
; Also exercises that 0ABh (hex, ends in a non-'b'-final digit that could
; be confused with binary if the fix were sloppy) still parses as hex.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov al, 1010b
    mov bl, 11111111b
    mov cx, 0ABh
    ret
