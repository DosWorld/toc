bits 16
cpu 8086

; Module 2 for the multi-module /T=exe test: exports 'getmsg', which returns in
; AX the DS-relative offset of its own message.  `mov ax, msg` is an OFFS
; relocation into module 2's DATA segment — resolved via the small-model layout
; (finalDataOfs computed with Align16).  If Align16 mis-aligns module 2's data,
; AX points at the wrong offset and DOS prints garbage / wrong text.

section .text
global getmsg
getmsg:
    mov  ax, msg
    ret

section .data
msg: db 'tlink-multi-ok', 13, 10, '$'
