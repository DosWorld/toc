; TR5STRUCLONG.ASM -- regression fixture for TASM.MD BUG R5: Dir.EndStruc
; composed "NAME_size" with no length guard (unlike AddField's B3.1
; guard) -- a struct name >= 59 chars yields a "NAME_size" key >= 64
; chars that Sym.Define's Strings.Copy would silently truncate,
; resurrecting the hash-of-full-name vs stored-truncated-name permanent-
; mismatch bug. The struct name here is exactly 60 chars (a valid
; identifier, under Scan's 64-char cap); the single field name is only
; 1 char so AddField's own B3.1 guard ("STRUCT.field" = 60+1+1 = 62 chars,
; under 64) does NOT fire -- only EndStruc's composed "_size" key (65
; chars) crosses Sym.MaxName (64), isolating the R5 guard specifically.
; Must be a fatal "STRUC name too long" error, not silent truncation.
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text

struc SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS
    .f resw 1
endstruc

global Foo
Foo:
    ret
