bits 16
cpu 8086

; fixture for test_tlink.sh: exports 'start', paired with TLKDUPB.ASM
; (which also exports 'start') to check tlink rejects duplicate GLOBAL
; symbol names instead of silently picking whichever module was scanned
; first.
section .text
global start
start:
    mov  ax, 4c00h
    int  21h
