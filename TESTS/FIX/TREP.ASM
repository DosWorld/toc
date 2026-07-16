; TREP.ASM -- regression fixture for the LOCK/REP* prefix-byte mechanism
; (v2 "full 8086 coverage" plan, batch 5 -- the one genuinely new
; mechanism: a leading LOCK/REP*/REPE/REPZ/REPNE/REPNZ token consumed by
; Parse.MOD, threaded through Enc.Encode as a prefix byte emitted before
; the segment-override prefix). No independent NASM oracle: the local
; nasm build lacks the rdf output backend. Expected TREP.RDF was hand-
; verified byte-for-byte against the 8086 prefix-byte convention (F0=LOCK,
; F3=REP/REPE/REPZ, F2=REPNE/REPNZ) before being adopted as the
; regression baseline -- see DOCS/TESTS.MD "TASM assembler regression test".
bits 16
cpu 8086
section .text
global Foo
Foo:
    lock inc word [bx]
    rep movsb
    repe cmpsb
    repz scasb
    repne cmpsw
    repnz scasw
    retf
