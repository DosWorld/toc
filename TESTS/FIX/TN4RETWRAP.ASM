; TN4RETWRAP.ASM -- regression fixture: BUG N4, "ret 65536" must be
; fatal, not silently wrapped mod 65536 to "ret 0". Checked via
; TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    ret 65536
