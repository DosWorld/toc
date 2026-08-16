; TTIMESLBL.ASM -- regression fixture: "times N dw label" originally
; (BUG B2) had to be a fatal error, since DoTimesTail only checked
; op.kind=OKImm (a label reference also satisfies that) without testing
; hasLabel, silently emitting N zero words with the label reference
; dropped entirely and no relocation. DoTimesTail's DW branch (2026-08-11)
; now instead calls EmitDataWordMaybeLabel N times, correctly emitting N
; independently relocated words -- CGA2.ASM's own "times 16 dw
; NotImpNear" dispatch-table-fill idiom needs exactly this. Assembly now
; SUCCEEDS with N RELOC records targeting Target's segment (.data, seg 1)
; -- see TESTS/test_tasm.sh's check_reloc_to_seg helper for what this
; fixture verifies today. "times N db label"/"times N dd label" remain
; fatal (DB has no relocation-emission path at all; DD's label case was
; never requested) -- unchanged.
bits 16
cpu 8086
section .data
Target: dw 0
section .text
global Foo
Foo:
    times 2 dw Target
    ret
