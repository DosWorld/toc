; TR3DWBSS.ASM -- regression fixture for TASM.MD BUG R3: an A5-adjacent
; gap where Parse.EmitDataWordMaybeLabel's intra-module branch was a
; two-way SegCode/SegData dispatch -- "dw bssLabel" (a label defined in
; SECTION .bss) relocated against SegData instead of SegBss, so the
; linker would add the wrong segment base to a BSS pointer. Fixed by
; making the dispatch three-way, mirroring Enc.AddReloc.
bits 16
cpu 8086
section .bss
buf: resb 4

section .data
ptr1: dw buf

section .text
global Foo
Foo:
    mov ax, [ptr1]
    ret
