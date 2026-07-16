; TINCDEEP.ASM -- regression fixture: a %include chain deeper than
; MaxSrcDepth (8) must be a fatal "%include nested too deep" error, not
; a silent stack overrun. TINCD1.INC..TINCD9.INC chain-include each
; other one level deeper.
bits 16
cpu 8086
section .text
global Foo
Foo:
%include "TINCD1.INC"
    ret
