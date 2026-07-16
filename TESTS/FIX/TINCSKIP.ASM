; TINCSKIP.ASM -- regression fixture: %include of a NONEXISTENT file
; inside a false %ifdef branch must be a no-op (skipped, never opened),
; not an error -- matches NASM's `%ifdef DOS_BUILD / %include
; "dosonly.inc"` idiom, where dosonly.inc need not exist on this build.
bits 16
cpu 8086
section .text
global Foo
Foo:
%ifdef NEVER_DEFINED
%include "NOSUCH.INC"
%endif
    ret
