; TINC1.ASM -- regression fixture for TASM.MD §I.3: %include "FILE.INC"
; textual inclusion. TINC2.INC defines MyVar in SECTION .data; TINC1.ASM
; references it from SECTION .text -- proves the included file's tokens
; parse in the includer's own context (section state, label table) and
; that two-pass forward/label resolution works across the include
; boundary.
bits 16
cpu 8086
section .data
%include "TINC2.INC"

section .text
global Foo
Foo:
    mov ax, [MyVar]
    ret
