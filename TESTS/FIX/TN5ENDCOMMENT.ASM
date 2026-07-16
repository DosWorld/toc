; TN5ENDCOMMENT.ASM -- regression fixture: BUG N5, "%endmacro ; note" is
; valid NASM source (a comment-to-EOL after the directive) but the old
; IsEndmacroLine required EXACTLY blanks-then-EOL, so the line was
; captured as body text and capture ran to EOF ("missing %endmacro").
; Checked via TESTS/test_tasm.sh's check_one byte-diff helper.
bits 16
cpu 8086
section .text
global Foo
%macro double 1
    mov ax, %1
    add ax, %1
%endmacro ; trailing comment must not break recognition
Foo:
    double 3
    ret
