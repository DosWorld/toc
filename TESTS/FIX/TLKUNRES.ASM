bits 16
cpu 8086

; fixture for test_tlink.sh: 'start' calls an extern that no input module
; defines -- tlink must report "unresolved external: missing_symbol" and
; produce no output file.
section .text
extern missing_symbol
global start
start:
    call missing_symbol
    mov  ax, 4c00h
    int  21h
