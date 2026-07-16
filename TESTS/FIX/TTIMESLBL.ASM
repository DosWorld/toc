; TTIMESLBL.ASM -- regression fixture: "times N dw label" (or db label)
; must be a fatal error, not silently emit N zero words/bytes with the
; label reference dropped entirely and no relocation (BUG B2: DoTimes
; only checked op.kind=OKImm, which a label reference also satisfies --
; hasLabel was never tested). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .data
Target: dw 0
section .text
global Foo
Foo:
    times 2 dw Target
    ret
