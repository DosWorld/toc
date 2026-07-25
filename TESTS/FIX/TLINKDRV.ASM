bits 16
cpu 8086

section .text
global strategy
global interrupt
strategy:
    retf
interrupt:
    retf
