; TPUNDEFJUNK.ASM -- regression fixture: paper cut, "%undef NAME junk"
; must be fatal (mirroring %include's own trailing-EOL check), not
; silently mis-parse the junk token as the start of a new statement.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
%define FOO
%undef FOO junk
section .text
global Bar
Bar:
    ret
