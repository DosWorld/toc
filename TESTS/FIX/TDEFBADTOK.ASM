; TDEFBADTOK.ASM -- regression fixture: a %define body containing a token
; the re-serialiser cannot represent (here: '(' -- TLparen has no
; TokToText case) must be a fatal error, not silently dropped with only a
; separator space appended (BUG B5). String literals used to be in this
; class too but gained their own TString re-quoting case in TokToText, so
; this fixture switched from a string body to '(' to keep exercising the
; ELSE/unsupported-token path. Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
%define BADBODY (
section .text
global Foo
Foo:
    mov al, BADBODY
    ret
