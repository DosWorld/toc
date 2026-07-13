BITS 16
CPU 8086

%define IS_FAR

SECTION .text

GLOBAL WinCB_Detect, WinCB_Clear, WinCB_Open, WinCB_Close, WinCB_GetDataSize
GLOBAL WinCB_SetData, WinCB_GetData

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

WinCB_Detect:
        MOV  AX, 1700H
        INT  2FH
        XOR  BX, BX
        CMP  AX, 1700H
        JE   .end
        INC  BX
.end:
        MOV  AX, BX
        RETMACRO

WinCB_Clear:
        MOV  AX, 1702H
        INT  2FH
        XOR  BX, BX
        OR   AX, AX
        JZ   .end
        INC  BX
.end:
        MOV  AX, BX
        RETMACRO

WinCB_Open:
        MOV  AX, 1701H
        INT  2FH
        XOR  BX, BX
        OR   AX, AX
        JZ   .end
        INC  BX
.end:
        MOV  AX, BX
        RETMACRO

WinCB_Close:
        MOV  AX, 1708H
        INT  2FH
        RETMACRO

WinCB_GetDataSize:
        MOV  AX, 1704H
        MOV  DX, 1
        INT  2FH
        RETMACRO

; WinCB_SetData(VAR d; size: WORD): BOOLEAN
; AX=1703h (WinOldAp SetClipboardData), format DX=1 (CF_TEXT), ES:BX=data
; pointer, CX=data size.  Returns AX<>0 on success, so the far pointer is
; loaded via LES straight from the stack argument (Files/EMS.ASM's own
; "VAR d" convention) rather than needing a local BOOLEAN temp.
WinCB_SetData:
        PUSH BP
        MOV  BP, SP
        %define d_ofs  [BP+RSIZE+2]
        %define d_seg  [BP+RSIZE+4]
        %define size_w [BP+RSIZE+6]
        PUSH ES
        PUSH BX
        PUSH CX
        PUSH DX
        LES  BX, d_ofs
        MOV  CX, size_w
        MOV  DX, 1
        MOV  AX, 1703H
        INT  2FH
        XOR  BX, BX
        OR   AX, AX
        JZ   .end
        INC  BX
.end:
        MOV  AX, BX
        POP  DX
        POP  CX
        POP  BX
        POP  ES
        %undef d_ofs
        %undef d_seg
        %undef size_w
        POP  BP
        RETMACRO 6

; WinCB_GetData(VAR d): BOOLEAN
; AX=1705h (WinOldAp GetClipboardData), format DX=1 (CF_TEXT), ES:BX=
; destination buffer pointer (caller-owned, must be large enough).
; Returns AX<>0 on success.
WinCB_GetData:
        PUSH BP
        MOV  BP, SP
        %define d_ofs [BP+RSIZE+2]
        %define d_seg [BP+RSIZE+4]
        PUSH ES
        PUSH BX
        PUSH DX
        LES  BX, d_ofs
        MOV  DX, 1
        MOV  AX, 1705H
        INT  2FH
        XOR  BX, BX
        OR   AX, AX
        JZ   .end
        INC  BX
.end:
        MOV  AX, BX
        POP  DX
        POP  BX
        POP  ES
        %undef d_ofs
        %undef d_seg
        POP  BP
        RETMACRO 4
