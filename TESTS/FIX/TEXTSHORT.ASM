; TEXTSHORT.ASM -- regression fixture: a plain (unqualified) conditional
; branch (Jcc) to an EXTERN symbol has no valid rel8 RDOFF2 relocation
; (rel8 cannot be patched at link time) -- originally (BUG A4) this was a
; required fatal error, not a silent wild rel8 = -(here+2) backward jump.
; EncJccAuto's auto-widen feature (2026-08-11/12) now instead retargets
; this case through the widened invert+JMP-near form, which DOES have a
; valid relocation, so assembly now SUCCEEDS with a RELOC referencing
; ExternalRoutine (matches real NASM, which auto-widens here too instead
; of erroring). An explicit "Jcc SHORT ExternalRoutine" still hits
; EncJmpShort's own extern check and is still a hard "short branch to
; EXTERN symbol is impossible" error (unchanged) -- see TESTS/test_tasm.sh's
; check_reloc_for helper for what this fixture verifies today.
bits 16
cpu 8086
extern ExternalRoutine
section .text
global Foo
Foo:
    cmp ax, 0
    jne ExternalRoutine
    ret
