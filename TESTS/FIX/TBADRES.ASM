; TBADRES.ASM -- regression fixture: RESB/RESW/RESD outside SECTION .bss
; must be a fatal error, not a silent no-op. See DOCS/TASM_PLAN.MD
; "Testing strategy for v2" -- checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    resb 4
    retf
