; TD86COV.ASM -- regression fixture for TASM.MD §D 8086-coverage-gap
; additions: CMC/LAHF/SAHF (trivial no-operand), WAIT (FWAIT alias),
; LOOPE/LOOPZ/LOOPNE/LOOPNZ (short-branch, same shape as LOOP), JCXZ
; (short-branch, E3), XLATB (XLAT alias), TEST reg,mem (commutative
; swap of the existing mem,reg form), and "es movsb"-style leading
; segment-register prefix on a string op.
bits 16
cpu 8086
section .data
w: dw 0

section .text
global Foo
Foo:
    cmc
    lahf
    sahf
    wait
    xlatb
L1:
    loope L1
    loopz L1
    loopne L1
    loopnz L1
    jcxz L1
    test ax, [w]
    es movsb
    ret
