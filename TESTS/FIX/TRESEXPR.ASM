; TRESEXPR.ASM -- regression fixture for BUG 4 (SRC/TASM/TASM.MD):
; RESB/RESW/RESD's count operand hung the assembler forever on any binary
; arithmetic expression (32*1024, 1024/16, 2048+1, ...) because Scan.MOD
; never tokenized '/' at all (falling into TError, never consumed) and
; Parse.MOD's ParseTopLevelRes only ever read a single bare TInt, leaving
; any trailing '*'/'/'/'+'/'-' token unconsumed -- RunPass's main loop
; then spun forever re-parsing the same leftover token, never reaching
; TEol/TEof. Fixed by adding TSlash to Scan.MOD and giving
; ParseTopLevelRes a real left-to-right '*','/'  then '+','-' expression
; grammar (ParseResExpr/ParseResMulDiv/ParseResTerm).
;
; first: resw 4*2+1   -> 9 words  -> next label at bss offset 18
; second: resb 100/10+3*2 -> 16 bytes -> next label at bss offset 34
; third: resd 2-1     -> 1 dword (4 bytes)
;
; .text references each label so their resolved bss offsets are baked
; into the RELOC addends -- a byte-diff against the hand-verified
; TRESEXPR.RDF catches any regression in the count arithmetic.
bits 16
cpu 8086
section .bss
first:  resw 4*2+1
second: resb 100/10+3*2
third:  resd 2-1

section .text
global Foo
Foo:
    mov ax, [first]
    mov bx, second
    mov cx, [third]
    retf
