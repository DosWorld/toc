; TR4LONGDEF.ASM -- regression fixture for TASM.MD BUG R4: the B5-fix
; %define-body overflow guard compared Strings.Length(val) + LEN(tIdOrig)
; (LEN(tIdOrig) is the compile-time array bound, 64, not the token's
; actual text length) against LEN(val) (127), so the guard fired once the
; serialized body reached ~62 chars even though the buffer holds 127.
; This body's serialized form ("[ 1 + 1 + ... ]") is well past that false
; threshold but under the real 127-char bound, and must assemble
; successfully -- not fail with "%define body too long". Also checks the
; macro expands and evaluates correctly (25 ones summed = 25 = 0x19).
bits 16
cpu 8086
%define BIGVAL [1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1]
section .text
global Foo
Foo:
    mov ax, word BIGVAL
    ret
