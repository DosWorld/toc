bits 16
cpu 8086

; fixture for test_tlink.sh: also exports 'start' (see TLKDUPA.ASM).
section .text
global start
start:
    mov  ax, 4c00h
    int  21h
