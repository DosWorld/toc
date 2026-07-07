bits 16
cpu 8086

GLOBAL print_msg

SECTION .data

    db 1,2,3,4,5 ; msg label have non-zero offset (for testing header reloc records)

msg db 'Hello from external library!$'

SECTION .text

print_msg:
    push ds
    mov  ax, seg msg
    mov  ds, ax
    mov  dx, msg
    mov  ah, 09h
    int  21h
    pop  ds
    retf

