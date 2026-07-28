bits 16
cpu 8086

; Multi-module /T=exe (small model) regression for TLINK.
; Module 1: entry 'start'.  TLINK's /T=exe startup stub establishes DS=SS=DGROUP
; before entering 'start' (DS setup is the LINKER's job for small model), so the
; program can immediately call the external 'getmsg' (module 2), which returns
; AX = the DS-relative offset of module 2's message, and print it via DOS.
;
; This exercises CalculateLayoutSmall's Align16 for module 2's code/data
; offsets: module 1's code is a deliberately non-16 length, so module 2 only
; lands on a paragraph boundary if Align16 rounds up correctly.  With the old
; buggy Align16 (v=17 -> 31 instead of 32) module 2's data offset was wrong and
; getmsg returned a bad pointer -> garbage/wrong text.

section .text
global start
extern getmsg

start:
    ; DS is already SS=DGROUP here — TLINK's /T=exe startup stub set it up
    ; before jumping to 'start'.  The program does NOT set DS itself.
    call getmsg          ; AX <- DS-relative offset of module 2's message
    mov  dx, ax
    mov  ah, 9
    int  21h             ; DOS print-string ($-terminated)
    mov  ax, 4c00h
    int  21h
    ; padding to make this module's own code a non-16-multiple length
    db 0,0,0,0,0
