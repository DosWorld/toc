; TBADBYTEIMM.ASM -- regression fixture: a byte-width immediate whose value
; is a label reference has no representable low-byte value and no RDOFF2
; byte-sized relocation -- must be a fatal error, not silently emit
; BYTE(0) with the reference dropped entirely (BUG A6).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .data
Msg: db 'hi', 0
section .text
global Foo
Foo:
    mov al, Msg
    ret
