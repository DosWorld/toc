bits 16
cpu 8086

section .text
global start
start:
    mov  dx, msg
    mov  ah, 9
    int  21h
    mov  ax, 4c00h
    int  21h

section .data
msg: db 'Hi from tlink!', 13, 10, '$'
