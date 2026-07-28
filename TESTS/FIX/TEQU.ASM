bits 16
cpu 8086
; EQU constant definitions, including an expression over prior EQU constants.
BUFSIZE EQU 128
BASE    EQU 0x20
COMBO   EQU BUFSIZE*2+BASE      ; 128*2+32 = 288 = 0x120
section .text
global start
start:
    mov ax, BUFSIZE             ; B8 80 00
    mov bx, BASE                ; BB 20 00
    mov cx, COMBO               ; B9 20 01
    ret                         ; C3
section .bss
buf:  resb BUFSIZE              ; EQU constant as a RESB count
