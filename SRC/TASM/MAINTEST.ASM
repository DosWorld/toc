section .text
Main:
    push bp
    mov  bp, sp
    mov AX, [bp+8]
    mov BX, [bp+6]
    add ax, BX
    jmp .L1
.L1:
    mov  sp, bp
    pop  bp
    retf 4

global start
start:
    mov AX, 0x4C00
    int 21H
