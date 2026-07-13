bits 16
cpu 8086
section .data
buf: dw 0
    dw 0
    dw 0
    dw 0

section .text

struc TPoint
    .X   resw 1
    .Y   resw 1
    .Flags resb 1
    .Pad resb 1
endstruc

global Foo
Foo:
    mov  bx, buf
    mov  ax, [bx + TPoint.X]
    mov  [bx + TPoint.Y], ax
    mov  al, [bx + TPoint.Flags]
    mov  cx, TPoint_size
    retf
