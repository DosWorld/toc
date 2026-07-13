bits 16
cpu 8086
extern SomeFunc
import OtherFunc

section .text
global Foo
Foo:
    call SomeFunc
    mov  ax, SomeFunc
    mov  ax, seg OtherFunc
    call OtherFunc
    retf
