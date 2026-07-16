; TPIFDEFJUNK.ASM -- regression fixture: paper cut, "%ifdef NAME junk"
; must be fatal (mirroring %include's own trailing-EOL check), not
; silently mis-parse the junk token as the start of a new statement.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
%define FOO
%ifdef FOO junk
section .text
global Bar
Bar:
    ret
%endif
