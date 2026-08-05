; TMACSTR.ASM -- regression fixture: %macro invoked with a string-literal
; actual parameter (single-char and multi-char, both quote styles).
; TokToText (the shared actual-parameter/%-define-body re-serialiser) used
; to reject TString outright ("unsupported token in macro argument"), so
; `CMPCHAR 'D'` or a DB with a %1 bound to a quoted string could not be
; expressed as a macro call at all. First instruction is `cmp al, 'D'`
; (opcode 3C 44) so code-starts can confirm the substitution encoded the
; right immediate byte, not just that assembly succeeded.
bits 16
cpu 8086

%macro CMPCHAR 1
    cmp al, %1
%endmacro

%macro DEFMSG 1
    db %1, 13, 10, '$'
%endmacro

section .text
global Foo
Foo:
    CMPCHAR 'D'
    ret

section .data
msg1: DEFMSG 'hi there'
msg2: DEFMSG "double quoted"
