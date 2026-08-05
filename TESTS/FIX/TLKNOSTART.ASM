bits 16
cpu 8086

; fixture for test_tlink.sh: no 'start' global at all -- tlink must
; report "entry point 'start' not found" and produce no output file.
section .text
global notstart
notstart:
    ret
