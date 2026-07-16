; TM1LBLREG.ASM -- regression fixture: BUG M1, "[label+reg]"/"[reg+label]"
; is a legal, common 8086/NASM table-indexing idiom (Mod=10 + disp16
; carrying the label's own RELOC) that the parser used to reject outright
; ("label displacement combined with base register not supported").
; Also exercises the EmitModRm fix that was needed alongside it: a label
; whose own constant offset is 0 must still force Mod=10 (disp16), not
; fall into the disp=0 -> Mod=00 shortcut meant for plain numeric
; displacements. Includes a bss-segment label too (three-way seg
; dispatch, same family as R3/A5). Checked via TESTS/test_tasm.sh's
; check_one byte-diff helper.
bits 16
cpu 8086
section .data
table: dw 0, 1, 2, 3
section .bss
barr: resw 4
section .text
global Foo
Foo:
    mov al, [table+bx]
    mov ax, [bx+table]
    mov ax, [bx+si+table]
    mov ax, [barr+si]
    ret
