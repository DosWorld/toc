; TBADINC.ASM -- regression fixture: "inc" applied to a bare label (not a
; memory reference in [ ]) must be a fatal error, not silently encode
; garbage ModRM bytes from an uninitialised Operand (BUG A3: EmitModRm only
; distinguished OKReg from "everything else is memory", so an OKImm
; bare-label operand was encoded as a memory operand using stack-garbage
; addressing-mode/disp fields). Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .data
Counter: dw 0
section .text
global Foo
Foo:
    inc Counter
    ret
