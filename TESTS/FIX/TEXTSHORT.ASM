; TEXTSHORT.ASM -- regression fixture: a short conditional branch (Jcc) to
; an EXTERN symbol has no valid RDOFF2 relocation (rel8 cannot be patched
; at link time) and must be a fatal error, not silently encode a wild
; rel8 = -(here+2) backward jump (BUG A4). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
extern ExternalRoutine
section .text
global Foo
Foo:
    cmp ax, 0
    jne ExternalRoutine
    ret
