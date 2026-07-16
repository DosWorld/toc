; SCREEN.ASM -- ported from a Turbo Pascal UNIT scr: text-mode
; screen buffer driver (shadow buffer + blit, color print/scroll,
; cursor, INT 1Ch spinner). Every routine here was originally a
; "PROCEDURE/FUNCTION ...; ASSEMBLER; ASM ... END;" body -- translated
; 1:1 into NASM routines, following the same conventions established for
; WINCB.ASM/KMOUSE.ASM/EMS.ASM: stack-argument aliases via %define/%undef
; ([BP+RSIZE+N]), module-private .data state accessed through direct-
; memory forms, and one-shot Oberon-callable setters for state that used
; to be plain Pascal UNIT-level VARs (screen/lineSize/screenSize/vseg --
; every ASM leaf routine here needs them, so they live in this file's own
; .data, set once from SCREEN.MOD's module init via Screen_SetBuf/
; Screen_SetLineSize/Screen_SetScreenSize/Screen_SetVSeg).
;
; Screen_Spinner1c is the one routine with NO Oberon-callable-convention
; counterpart: it is installed directly as the INT 1Ch handler (raw
; PUSH/POP all registers + IRET, not RETF/RETN -- Oberon procedures have
; no interrupt-handler calling convention, so this must be hand-written
; here rather than declared as an Oberon PROCEDURE).

BITS 16
CPU 8086

%define IS_FAR

SECTION .data
screenOfs:     dw 0
screenSeg:     dw 0
lineSize:      dw 0
screenSize:    dw 0
vseg:          dw 0
spinnerValue:  dw 0
spinnerChars:  db '|/-\|/-\'

SECTION .text

GLOBAL Screen_SetBuf, Screen_SetLineSize, Screen_SetScreenSize, Screen_SetVSeg
GLOBAL Screen_GetHeight, Screen_GetWidth
GLOBAL Screen_Cls, Screen_Cln, Screen_HPrint, Screen_ChColor, Screen_VPrint
GLOBAL Screen_Print, Screen_PrintHl, Screen_Show
GLOBAL Screen_Locate, Screen_GetX, Screen_GetY
GLOBAL Screen_SetCursor, Screen_GetCursor, Screen_SetBlink
GLOBAL Screen_Delay, Screen_WaitRetrace
GLOBAL Screen_Spinner1c

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

; SYSTEM_Seg0040 (SYSTEM.Seg0040 in Oberon) returns the BIOS data-area
; segment (0040h) -- used instead of a hardcoded %define per the
; project's architecture: every "magic segment" constant is a real
; SYSTEM procedure call, not baked into each .ASM file separately.
EXTERN SYSTEM_Seg0040

; ---- one-shot state setters (called once from SCREEN.MOD's module init) ----

; Screen_SetBuf(p: SYSTEM.ADDRESS): sets the far pointer to the shadow
; screen buffer that every other routine here blits into/out of.
Screen_SetBuf:
        PUSH BP
        MOV  BP, SP
        %define p_ofs [BP+RSIZE+2]
        %define p_seg [BP+RSIZE+4]
        PUSH AX
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, p_ofs
        MOV  [screenOfs], AX
        MOV  AX, p_seg
        MOV  [screenSeg], AX
        POP  DS
        POP  AX
        %undef p_ofs
        %undef p_seg
        POP  BP
        RETMACRO 4

; Screen_SetLineSize(w: WORD): bytes per screen row (2 bytes/char cell).
Screen_SetLineSize:
        PUSH BP
        MOV  BP, SP
        %define w_arg [BP+RSIZE+2]
        PUSH AX
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, w_arg
        MOV  [lineSize], AX
        POP  DS
        POP  AX
        %undef w_arg
        POP  BP
        RETMACRO 2

; Screen_SetScreenSize(n: WORD): total shadow-buffer size in bytes.
Screen_SetScreenSize:
        PUSH BP
        MOV  BP, SP
        %define n_arg [BP+RSIZE+2]
        PUSH AX
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, n_arg
        MOV  [screenSize], AX
        POP  DS
        POP  AX
        %undef n_arg
        POP  BP
        RETMACRO 2

; Screen_SetVSeg(seg: WORD): real video memory segment (B800h/B000h).
Screen_SetVSeg:
        PUSH BP
        MOV  BP, SP
        %define seg_arg [BP+RSIZE+2]
        PUSH AX
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, seg_arg
        MOV  [vseg], AX
        POP  DS
        POP  AX
        %undef seg_arg
        POP  BP
        RETMACRO 2

; ---- BIOS data-area queries ----

; Screen_GetHeight(): INTEGER -- number of text rows (BIOS byte
; 0040h:0084h, EGA/VGA "rows minus one"; 0 on plain CGA/MDA -> height 1
; more than the byte, matching the original Pascal's "inc(ax)").
Screen_GetHeight:
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  AL, [0084H]
        XOR  AH, AH
        INC  AX
        POP  DS
        RETMACRO

; Screen_GetWidth(): INTEGER -- number of text columns (BIOS word
; 0040h:004Ah).
Screen_GetWidth:
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  AX, [004AH]
        POP  DS
        RETMACRO

; ---- internal helper: ES:DI = shadow-buffer address of cell (x,y) ----
; in: AX=x, CX=y.  Not exported (matches the original Pascal's buf_es_di,
; called only from other routines in this file, never from Oberon).
BufEsDi:
        PUSH BP
        MOV  BP, SP
        PUSH DX
        PUSH DS
        MOV  DX, AX
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, [lineSize]
        MUL  CX
        XCHG DX, AX
        SHL  AX, 1
        ADD  AX, DX
        MOV  DI, AX
        MOV  ES, [screenSeg]
        ADD  DI, [screenOfs]
        POP  DS
        POP  DX
        POP  BP
        RET

; Screen_Cls(clr: BYTE): fills the whole shadow buffer with spaces in
; color clr (does not touch real video memory -- see Screen_Show).
Screen_Cls:
        PUSH BP
        MOV  BP, SP
        %define clr_arg [BP+RSIZE+2]
        PUSH AX
        PUSH CX
        PUSH DX
        PUSH ES
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, [screenSize]
        SHR  AX, 1
        XCHG AX, CX
        MOV  DL, clr_arg
        MOV  AH, DL
        MOV  AL, ' '
        MOV  ES, [screenSeg]
        MOV  DI, [screenOfs]
        CLD
        REPZ STOSW
        POP  DS
        POP  ES
        POP  DX
        POP  CX
        POP  AX
        %undef clr_arg
        POP  BP
        RETMACRO 2

; Screen_Cln(x, y: INTEGER; clr: BYTE): clears from column x to the end
; of row y (the original Pascal computed the clear width as
; getwidth()-x, so this matches: fills to the last column, not just a
; fixed run).
Screen_Cln:
        PUSH BP
        MOV  BP, SP
        %define x_arg   [BP+RSIZE+2]
        %define y_arg   [BP+RSIZE+4]
        %define clr_arg [BP+RSIZE+6]
        PUSH AX
        PUSH CX
        PUSH DX
        PUSH ES
        CALL Screen_GetWidth
        PUSH AX
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        POP  CX
        SUB  CX, x_arg
        MOV  DL, clr_arg
        MOV  AH, DL
        MOV  AL, ' '
        CLD
        REPZ STOSW
        POP  ES
        POP  DX
        POP  CX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        POP  BP
        RETMACRO 6

; Screen_HPrint(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER):
; horizontal run of len copies of character c in color clr, starting at
; (x,y).
Screen_HPrint:
        PUSH BP
        MOV  BP, SP
        %define x_arg   [BP+RSIZE+2]
        %define y_arg   [BP+RSIZE+4]
        %define clr_arg [BP+RSIZE+6]
        %define c_arg   [BP+RSIZE+7]
        %define len_arg [BP+RSIZE+8]
        PUSH AX
        PUSH CX
        PUSH DX
        PUSH ES
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        MOV  CX, len_arg
        MOV  DL, clr_arg
        MOV  AH, DL
        MOV  AL, c_arg
        CLD
        REPZ STOSW
        POP  ES
        POP  DX
        POP  CX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        %undef c_arg
        %undef len_arg
        POP  BP
        RETMACRO 10

; Screen_ChColor(x, y: INTEGER; clr: BYTE; len: INTEGER): recolors len
; cells starting at (x,y) without touching their character bytes (writes
; only the attribute byte of each cell, matching the original's
; INC DI/DEC CL loop rather than a REP STOSW pair-write).
Screen_ChColor:
        PUSH BP
        MOV  BP, SP
        %define x_arg   [BP+RSIZE+2]
        %define y_arg   [BP+RSIZE+4]
        %define clr_arg [BP+RSIZE+6]
        %define len_arg [BP+RSIZE+7]
        PUSH AX
        PUSH CX
        PUSH ES
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        INC  DI
        MOV  CX, len_arg
        MOV  AL, clr_arg
        CLD
        OR   CL, CL
        JZ   .end
.cont:
        STOSB
        INC  DI
        DEC  CL
        JNZ  .cont
.end:
        POP  ES
        POP  CX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        %undef len_arg
        POP  BP
        RETMACRO 8

; Screen_VPrint(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER):
; vertical run of len copies of character c in color clr, starting at
; (x,y) and advancing one full screen row (lineSize) per cell.
Screen_VPrint:
        PUSH BP
        MOV  BP, SP
        %define x_arg   [BP+RSIZE+2]
        %define y_arg   [BP+RSIZE+4]
        %define clr_arg [BP+RSIZE+6]
        %define c_arg   [BP+RSIZE+7]
        %define len_arg [BP+RSIZE+8]
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        PUSH ES
        PUSH DS
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  BX, [lineSize]
        SUB  BX, 2
        MOV  CX, len_arg
        MOV  DL, clr_arg
        MOV  AH, DL
        MOV  AL, c_arg
        CLD
        OR   CL, CL
        JZ   .end
.cont:
        STOSW
        ADD  DI, BX
        DEC  CL
        JNZ  .cont
.end:
        POP  DS
        POP  ES
        POP  DX
        POP  CX
        POP  BX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        %undef c_arg
        %undef len_arg
        POP  BP
        RETMACRO 10

; Screen_Print(x, y: INTEGER; clr: BYTE; s: SYSTEM.ADDRESS): writes the
; Pascal-style length-prefixed string at s (s^ = length byte, s^[1..] =
; characters) starting at (x,y) in color clr.
Screen_Print:
        PUSH BP
        MOV  BP, SP
        %define x_arg   [BP+RSIZE+2]
        %define y_arg   [BP+RSIZE+4]
        %define clr_arg [BP+RSIZE+6]
        %define s_ofs   [BP+RSIZE+7]
        %define s_seg   [BP+RSIZE+9]
        PUSH AX
        PUSH CX
        PUSH SI
        PUSH DX
        PUSH ES
        PUSH DS
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        MOV  DL, clr_arg
        MOV  AH, DL
        LDS  SI, s_ofs
        LODSB
        OR   AL, AL
        JZ   .end
        MOV  CL, AL
        CLD
.cont:
        LODSB
        STOSW
        DEC  CL
        JNZ  .cont
.end:
        POP  DS
        POP  ES
        POP  DX
        POP  SI
        POP  CX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        %undef s_ofs
        %undef s_seg
        POP  BP
        RETMACRO 11

; Screen_PrintHl(x, y: INTEGER; clr, hlclr: BYTE; s: SYSTEM.ADDRESS):
; like Screen_Print, but every '~' character in s toggles between clr
; and hlclr instead of being printed (the original Pascal's "poor man's
; markup" convention -- '~' is consumed, not displayed).
Screen_PrintHl:
        PUSH BP
        MOV  BP, SP
        %define x_arg     [BP+RSIZE+2]
        %define y_arg     [BP+RSIZE+4]
        %define clr_arg   [BP+RSIZE+6]
        %define hlclr_arg [BP+RSIZE+7]
        %define s_ofs     [BP+RSIZE+8]
        %define s_seg     [BP+RSIZE+10]
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH SI
        PUSH DX
        PUSH ES
        PUSH DS
        MOV  AX, x_arg
        MOV  CX, y_arg
        CALL BufEsDi
        MOV  DL, clr_arg
        MOV  AH, DL
        MOV  BL, hlclr_arg
        MOV  BH, BL
        LDS  SI, s_ofs
        LODSB
        OR   AL, AL
        JZ   .end
        MOV  CL, AL
        CLD
.cont:
        LODSB
        CMP  AL, '~'
        JNZ  .print
        XCHG AH, BH
        JMP  .cont2
.print:
        STOSW
.cont2:
        DEC  CL
        JNZ  .cont
.end:
        POP  DS
        POP  ES
        POP  DX
        POP  SI
        POP  CX
        POP  BX
        POP  AX
        %undef x_arg
        %undef y_arg
        %undef clr_arg
        %undef hlclr_arg
        %undef s_ofs
        %undef s_seg
        POP  BP
        RETMACRO 12

; Screen_Show(): blits the whole shadow buffer to real video memory
; (segment vseg). Hides/shows the mouse cursor around the blit so a
; visible cursor sprite is never partially overwritten (calls
; KMouse_MouseHide/KMouse_MouseShow -- SRC/LIB/KMOUSE.ASM must be linked
; alongside this module, same as the original Pascal UNIT's "uses
; kminput").
EXTERN KMouse_MouseHide
EXTERN KMouse_MouseShow
Screen_Show:
        PUSH BP
        MOV  BP, SP
        CALL FAR KMouse_MouseHide
        CALL FAR Screen_WaitRetrace
        PUSH AX
        PUSH CX
        PUSH SI
        PUSH DI
        PUSH ES
        PUSH DS
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, [screenSize]
        SHR  AX, 1
        MOV  CX, AX
        MOV  AX, [vseg]
        MOV  ES, AX
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  SI, [screenOfs]
        PUSH WORD [screenSeg]
        POP  DS
        XOR  DI, DI
        CLD
        REPZ MOVSW
        POP  DS
        POP  ES
        POP  DI
        POP  SI
        POP  CX
        POP  AX
        CALL FAR KMouse_MouseShow
        POP  BP
        RETMACRO

; Screen_Locate(x, y: INTEGER): moves the hardware text cursor to
; (x,y) (INT 10h AH=02h, BH=current video page from BIOS byte
; 0040h:0062h).
Screen_Locate:
        PUSH BP
        MOV  BP, SP
        %define x_arg [BP+RSIZE+2]
        %define y_arg [BP+RSIZE+4]
        PUSH AX
        PUSH BX
        PUSH DX
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  BH, [0062H]
        POP  DS
        MOV  DL, BYTE x_arg
        MOV  DH, BYTE y_arg
        MOV  AH, 2
        INT  10H
        POP  DX
        POP  BX
        POP  AX
        %undef x_arg
        %undef y_arg
        POP  BP
        RETMACRO 4

; Screen_GetX(): INTEGER -- current hardware text-cursor column (INT
; 10h AH=03h).
Screen_GetX:
        PUSH BX
        PUSH DX
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  BH, [0062H]
        POP  DS
        MOV  AH, 3
        INT  10H
        MOV  AL, DL
        XOR  AH, AH
        POP  DX
        POP  BX
        RETMACRO

; Screen_GetY(): INTEGER -- current hardware text-cursor row (INT
; 10h AH=03h).
Screen_GetY:
        PUSH BX
        PUSH DX
        PUSH DS
        CALL FAR SYSTEM_Seg0040
        MOV  DS, AX
        MOV  BH, [0062H]
        POP  DS
        MOV  AH, 3
        INT  10H
        MOV  AL, DH
        XOR  AH, AH
        POP  DX
        POP  BX
        RETMACRO

; Screen_SetCursor(w: WORD): sets the hardware cursor shape (INT 10h
; AH=01h, CX=shape word -- start/end scanlines packed as Pascal's
; original "mov cx, w").
Screen_SetCursor:
        PUSH BP
        MOV  BP, SP
        %define w_arg [BP+RSIZE+2]
        PUSH CX
        MOV  CX, w_arg
        MOV  AH, 1
        INT  10H
        POP  CX
        %undef w_arg
        POP  BP
        RETMACRO 2

; Screen_GetCursor(): WORD -- reads the current hardware cursor shape
; (INT 10h AH=0Fh to select the active page, then AH=03h to read its
; cursor shape into CX).
Screen_GetCursor:
        PUSH BX
        PUSH CX
        MOV  AH, 0FH
        INT  10H
        MOV  AH, 3
        INT  10H
        MOV  AX, CX
        POP  CX
        POP  BX
        RETMACRO

; Screen_SetBlink(on: BOOLEAN): toggles the CGA/EGA/VGA high-intensity-
; background-vs-blink attribute bit (INT 10h AX=1003h).
Screen_SetBlink:
        PUSH BP
        MOV  BP, SP
        %define on_arg [BP+RSIZE+2]
        PUSH AX
        PUSH BX
        MOV  BL, on_arg
        MOV  AX, 1003H
        INT  10H
        POP  BX
        POP  AX
        %undef on_arg
        POP  BP
        RETMACRO 2

; Screen_Delay(ms: WORD): busy-waits approximately ms milliseconds (INT
; 15h AH=86h, CX:DX = microseconds -- ms*1000 split into CX:DX by the
; MUL).
Screen_Delay:
        PUSH BP
        MOV  BP, SP
        %define ms_arg [BP+RSIZE+2]
        PUSH AX
        PUSH CX
        PUSH DX
        MOV  AX, 1000
        MUL  WORD ms_arg
        MOV  CX, DX
        MOV  DX, AX
        MOV  AH, 86H
        INT  15H
        POP  DX
        POP  CX
        POP  AX
        %undef ms_arg
        POP  BP
        RETMACRO 2

; Screen_WaitRetrace(): busy-waits for the start of the next vertical
; retrace (port 3DAh bit 3 = "in retrace"; first waits for retrace to
; END, then waits for it to START again, so the caller gets a full
; retrace period to work with).
Screen_WaitRetrace:
        PUSH AX
        PUSH DX
        MOV  DX, 3DAH
.l1:
        IN   AL, DX
        TEST AL, 8
        JNZ  .l1
.l2:
        IN   AL, DX
        TEST AL, 8
        JZ   .l2
        POP  DX
        POP  AX
        RETMACRO

; Screen_Spinner1c: INT 1Ch handler (installed via DOS SetIntVec by
; SCREEN.MOD's SpinnerStart, restored by SpinnerStop) -- NOT an Oberon-
; callable routine, so it has no RSIZE/RETMACRO stack-argument
; convention at all: it is entered exactly like any hardware interrupt
; (no arguments, must preserve every register and flag, and returns via
; IRET rather than RETF/RETN). Advances a spinner animation character
; directly into real video memory at vseg:0/vseg:1 (top-left screen
; cell) on every timer tick (~18.2 Hz), matching the original Pascal's
; "mem[vseg:0] := ...; mem[vseg:1] := $20" -- writes straight to video
; memory rather than through the shadow buffer, since a background
; spinner must stay visible without needing a full Screen_Show blit.
Screen_Spinner1c:
        PUSH AX
        PUSH BX
        PUSH CX
        PUSH DX
        PUSH DI
        PUSH DS
        PUSH ES
        MOV  AX, SEG screenOfs
        MOV  DS, AX
        MOV  AX, [spinnerValue]
        MOV  CX, 3
        SHR  AX, CL             ; (spinnerValue >> 3)
        XOR  DX, DX
        MOV  BX, 8              ; length(SPINNER) = 8
        DIV  BX                 ; DX := (spinnerValue >> 3) MOD 8
        MOV  BX, spinnerChars
        ADD  BX, DX
        MOV  AL, [BX]
        MOV  ES, [vseg]
        MOV  DI, 0
        MOV  BYTE [ES:DI], AL
        MOV  BYTE [ES:DI+1], 20H
        INC  WORD [spinnerValue]
        POP  ES
        POP  DS
        POP  DI
        POP  DX
        POP  CX
        POP  BX
        POP  AX
        IRET
