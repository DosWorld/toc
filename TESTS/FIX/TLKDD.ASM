bits 16
cpu 8086
; TLINK width=4 (DD-with-label) relocation regression: TASM emits a
; width=4 RELOC for 'dd target'; TLINK.MOD's PatchMem/PatchMem4 must patch
; all 4 bytes, not just the low word (PatchMem previously had no width=4
; branch at all and silently treated it as width=2, corrupting the high
; word). 'target' is placed after some padding bytes so its own in-module
; offset is nonzero -- with /ORG=100 the two together prove PatchMem4
; adds BOTH into a real 32-bit sum (0x100 + target's offset), not just
; coincidentally right at 0.
section .text
global start
start:
    ret
    db 1, 2, 3, 4, 5
target:
    ret
    dd target
