; TUNDEFDW.ASM -- regression fixture: "dw" referencing a never-defined,
; never-EXTERN label must be a fatal "undefined symbol" error (BUG A1),
; not a silent zero word with a bogus intra-module reloc.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .data
global FooTable
FooTable:
    dw NoSuchTable
