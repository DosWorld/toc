; TN3NEGLBL.ASM -- regression fixture: BUG N3/M3, "-" before a bare label
; inside [ ] was silently dropped -- "[-buf]" assembled as "[+buf]" with
; no diagnostic. A label can never be legally negated inside an
; effective address on 8086. Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .data
buf: dw 0
section .text
global Foo
Foo:
    mov ax, [-buf]
    ret
