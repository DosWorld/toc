BITS 16
CPU 8086

%define IS_FAR

SECTION .text

GLOBAL Detect_Video, Detect_IsFreeDos, Detect_GetFreeDosVer
GLOBAL Detect_IsMonochrome, Detect_IsInputRedirected, Detect_IsOutputRedirected
GLOBAL Detect_IsAnsiSys, Detect_Cpu
EXTERN SYSTEM_Seg0040

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

VIDEO_VGA  equ  9
VIDEO_EGA  equ  3
VIDEO_MDA  equ  7
VIDEO_CGA  equ  1

Detect_Video:
        mov  ax, 1200h
        mov  bl, 32h
        int  10h
        cmp  al, 12h
        jne  .not_vga

        mov  al, VIDEO_VGA
        xor  ah, ah
        retf

.not_vga:
        mov  ah, 12h
        mov  bl, 10h
        int  10h
        cmp  bl, 4
        jae  .not_ega

        mov  al, VIDEO_EGA
        retf

.not_ega:
        mov  ah, 0Fh
        int  10h
        cmp  al, 7
        je   .is_mda

        mov  al, VIDEO_CGA
        xor  ah, ah
        retf

.is_mda:
        mov  al, VIDEO_MDA
        xor  ah, ah
        retf

Detect_IsFreeDos:
        MOV  AX, 3000H
        XOR  BX, BX
        INT  21H
        CMP  BH, 0FDH
        JE   .end
        XOR  BH, BH
.end:
        MOV  AL, BH
        RETMACRO

Detect_GetFreeDosVer:
        MOV  AX, 33FFH
        XOR  DX, DX
        INT  21H
        TEST DX, DX
        JNZ  .end
        XOR  AX, AX
        MOV  DX, AX
.end:
        RETMACRO

Detect_IsMonochrome:
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  AL, BYTE[0065H]
        POP  DS
        AND  AL, 4
        RETMACRO

Detect_IsInputRedirected:
        MOV  AX, 4400H
        XOR  BX, BX
        INT  21H
        XOR  AL, AL
        AND  DL, 81H
        OR   DL, DL
        JNZ  .end
        INC  AL
.end:
        RETMACRO

Detect_IsOutputRedirected:
        MOV  AX, 4400H
        MOV  BX, 1
        INT  21H
        XOR  AL, AL
        AND  DL, 82H
        OR   DL, DL
        JNZ  .end
        INC  AL
.end:
        RETMACRO

Detect_IsAnsiSys:
        MOV     AX,1A00H
        INT     2FH
        XOR     AH, AH
        RETMACRO

Detect_Cpu:
        XOR  DX, DX
        PUSH DX
        POPF
        PUSHF
        POP  AX
        AND  AX, 0F000H
        CMP  AX, 0F000H
        JE   .end
        INC  DX
        MOV  AX, 0F000H
        PUSH AX
        POPF
        PUSHF
        POP  AX
        AND  AX, 0F000H
        JZ   .end
        INC  DX
.end:
        MOV  AX, DX
        RETMACRO
