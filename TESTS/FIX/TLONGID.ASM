; TLONGID.ASM -- regression fixture: an identifier past the scanner's
; identifier-length limit must be a fatal "identifier too long" error, not
; silently truncated (BUG B3: two long labels sharing a 63-char prefix
; would otherwise both truncate to the same stored name and collide).
; Checked via TESTS/test_tasm.sh's check_fails helper.
bits 16
cpu 8086
section .text
global Foo
Foo:
    mov ax, ThisIdentifierIsDeliberatelyMuchLongerThanSixtyFourCharactersToTripTheLimit
    ret
