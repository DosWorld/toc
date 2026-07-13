; TBADIF.ASM -- regression fixture: an %ifdef with no matching %endif must
; be a fatal error ("%ifdef without matching %endif"), not a silent
; success that truncates or drops the unclosed block's content. See
; DOCS/TASM_PLAN.MD "Testing strategy for v2" -- this fixture is checked
; via TESTS/test_tasm.sh's check_fails helper (expects a non-zero exit and
; the diagnostic substring in the log), not a byte-diff.
bits 16
cpu 8086
section .text
global Foo
Foo:
%ifdef NEVER_DEFINED
    mov ax, 1
