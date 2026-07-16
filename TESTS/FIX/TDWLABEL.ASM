; TDWLABEL.ASM -- regression fixture for BUG 3 (SRC/TASM/TASM.MD):
; EmitDataWordMaybeLabel wrote only op.disp as the on-disk RELOC addend for
; `DW label`, discarding the label's own resolved local offset (lofs) --
; every `dw label` initializer therefore linked to the wrong address
; whenever the target wasn't coincidentally at offset 0 of its segment
; (e.g. a jump/dispatch table entry pointing at code). Fixed by writing
; op.disp + lofs, matching EmitDisp16's established intra-module RELOC
; addend convention (see its own comment). pad: below pushes mytable off
; data offset 0 so the missing-lofs bug can't hide behind a coincidental
; zero address.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov  bx, [mytable]
    retf
mylabel:
    nop

section .data
pad: dw 0, 0, 0, 0
mytable: dw mylabel
