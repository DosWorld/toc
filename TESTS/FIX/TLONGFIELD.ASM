; TLONGFIELD.ASM -- regression fixture: a STRUC name long enough that
; "STRUCTNAME.field" would overflow the Sym %define key bound must be a
; fatal "STRUC field name too long" error, not a silent truncation that
; could collide two different (struct,field) pairs onto the same %define
; entry (BUG B3.1). The struct name itself (60 chars) is within the
; per-identifier limit (64) -- only the composed "name.field" key (66
; chars) exceeds Sym.MaxName. Checked via TESTS/test_tasm.sh's
; check_fails helper.
bits 16
cpu 8086
section .text

struc SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS
    .fld resw 1
endstruc

global Foo
Foo:
    ret
