; TEXTDW.ASM -- regression fixture: "dw" referencing an EXTERN symbol must
; emit an RDFREC_RELOC whose RSEG is the import ID (link-time address),
; not this module's own SegCode/SegData (BUG A5: EmitDataWordMaybeLabel had
; no extern branch and always emitted an intra-module reloc, which silently
; adds the wrong base at link time). Checked via TESTS/test_tasm.sh's
; check_reloc_for helper (rdfgrep has-reloc-for), not a byte-diff.
bits 16
cpu 8086
extern ExternalProc
section .data
global FooPtrTable
FooPtrTable:
    dw ExternalProc
