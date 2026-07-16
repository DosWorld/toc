; TDEFBADTOK.ASM -- regression fixture: a %define body containing a token
; the re-serialiser cannot represent (here: a string literal) must be a
; fatal error, not silently dropped with only a separator space appended
; (BUG B5). Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
%define BADBODY 'x'
section .text
global Foo
Foo:
    mov al, BADBODY
    ret
