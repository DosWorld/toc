bits 16
cpu 8086

; /T=com "start is NOT first" regression: helper code precedes 'start' in
; the .text section, so TLINK must still emit the 3-byte JMP stub (start is
; not at code offset 0).  Paired with TLINKHI.ASM (where 'start' IS the very
; first byte, so TLINK must OMIT the stub instead) to cover both sides of the
; CalculateLayoutTiny/WriteOutputTiny "no-jmp-to-next" check.

section .text

helper:
    ret

global start
start:
    mov  dx, msg
    mov  ah, 9
    int  21h
    mov  ax, 4c00h
    int  21h

section .data
msg: db 'Hi from tlink!', 13, 10, '$'
