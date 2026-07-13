; KMOUSE.ASM -- ported from KMOUSE.PAS (Turbo Pascal UNIT KMouse): extended
; keyboard + Microsoft-mouse (INT 33h) driver.  Every routine here was
; originally a Pascal "PROCEDURE/FUNCTION ...; ASSEMBLER; ASM ... END;"
; body -- straight NASM translation, same register/flag conventions,
; `mov mouse_present, al`-style module-.data access replaced with this
; file's own SECTION .data labels (Oberon can't reference a bare .asm
; label from KMOUSE.MOD directly -- KMouse_Detect below is the only
; entry point that touches them, matching EMS.ASM's driverPresent
; pattern) plus a new KMouse_Detect routine (the Pascal UNIT's own
; "BEGIN ... END." initialization block, ported 1:1) that KMOUSE.MOD's
; module BEGIN calls once at load time.

BITS 16
CPU 8086

%define IS_FAR

SECTION .data
haveExtKb:    db 0
have122Kb:    db 0
mousePresent: db 0
mouseState:   db 0

SECTION .text

GLOBAL KMouse_Detect
GLOBAL KMouse_KbdGetKey, KMouse_KbdHasKey, KMouse_KbdGetFlags
GLOBAL KMouse_KbdFast
GLOBAL KMouse_IsCtrl, KMouse_IsAlt, KMouse_IsShift
GLOBAL KMouse_MouseAvail, KMouse_MouseVisible
GLOBAL KMouse_MouseShow, KMouse_MouseHide
GLOBAL KMouse_MouseButtons, KMouse_MouseGetX, KMouse_MouseGetY

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

; KMouse_Detect: ported from the Pascal UNIT's own "BEGIN...END." init
; block -- probes the extended-keyboard BIOS function (INT 16h AH=09h,
; bits 5/6 of AL = 122-key/enhanced support) and the Microsoft Mouse
; driver (INT 33h AX=0, AL<>0 on return = present), stashing the results
; in this file's own .data flags.  No parameters, no return value --
; called once from KMOUSE.MOD's module BEGIN, exactly like EMS.MOD calls
; EMS_Detect.
KMouse_Detect:
        PUSH AX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AX, 0900H
        INT  16H
        PUSH AX
        AND  AL, 20H
        MOV  [haveExtKb], AL
        POP  AX
        AND  AL, 40H
        MOV  [have122Kb], AL
        XOR  AX, AX
        INT  33H
        MOV  [mousePresent], AL
        POP  DS
        POP  AX
        RETMACRO

; KMouse_KbdGetKey: WORD -- extended-keyboard-aware "read key" (INT 16h
; AH=00h/10h/20h depending on which keyboard BIOS extension is present).
KMouse_KbdGetKey:
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        CMP  BYTE [have122Kb], 0
        JNE  .h122
        CMP  BYTE [haveExtKb], 0
        JNE  .hext
        XOR  AX, AX
        JMP  .go
.h122:
        MOV  AH, 20H
        JMP  .go
.hext:
        MOV  AH, 10H
.go:
        POP  DS
        INT  16H
        RETMACRO

; KMouse_KbdHasKey: BOOLEAN -- INT 16h AH=01h/11h/21h "key waiting" check;
; ZF set on return means no key, so the Pascal original's CX=0/DEC CX
; trick turns "ZF set" into AX=0 and "ZF clear" into AX=0FFFFh.
KMouse_KbdHasKey:
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        CMP  BYTE [have122Kb], 0
        JNE  .h122
        CMP  BYTE [haveExtKb], 0
        JNE  .hext
        MOV  AH, 1
        JMP  .go
.hext:
        MOV  AH, 11H
        JMP  .go
.h122:
        MOV  AH, 21H
.go:
        POP  DS
        INT  16H
        MOV  CX, 0
        JZ   .nokey
        DEC  CX
.nokey:
        MOV  AX, CX
        RETMACRO

; KMouse_KbdGetFlags: BYTE -- INT 16h AH=02h/12h/22h "get shift flags".
KMouse_KbdGetFlags:
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        CMP  BYTE [have122Kb], 0
        JNE  .h122
        CMP  BYTE [haveExtKb], 0
        JNE  .hext
        MOV  AH, 2
        JMP  .go
.hext:
        MOV  AH, 12H
        JMP  .go
.h122:
        MOV  AH, 22H
.go:
        POP  DS
        INT  16H
        RETMACRO

; KMouse_KbdFast: no return value -- INT 16h AX=0305h BX=0 sets the
; keyboard typematic rate/delay to the fastest setting.
KMouse_KbdFast:
        MOV  AX, 0305H
        XOR  BX, BX
        INT  16H
        RETMACRO

; KMouse_IsCtrl/IsAlt/IsShift(flags: BYTE): BOOLEAN -- test a bit of the
; INT 16h shift-flags byte (passed as a stack argument, same [BP+RSIZE+2]
; convention as EMS.ASM/WINCB.ASM's byte-sized VAR/value params).
KMouse_IsCtrl:
        PUSH BP
        MOV  BP, SP
        MOV  AL, [BP+RSIZE+2]
        AND  AL, 4H
        POP  BP
        RETMACRO 2

KMouse_IsAlt:
        PUSH BP
        MOV  BP, SP
        MOV  AL, [BP+RSIZE+2]
        AND  AL, 8H
        POP  BP
        RETMACRO 2

KMouse_IsShift:
        PUSH BP
        MOV  BP, SP
        MOV  AL, [BP+RSIZE+2]
        AND  AL, 3H
        POP  BP
        RETMACRO 2

; KMouse_MouseAvail: BOOLEAN -- TRUE iff KMouse_Detect found a mouse driver.
KMouse_MouseAvail:
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        POP  DS
        RETMACRO

; KMouse_MouseVisible: BOOLEAN -- TRUE iff the cursor is currently shown
; (tracked in mouseState, since INT 33h has no direct "is visible" query).
KMouse_MouseVisible:
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AL, [mouseState]
.nomouse:
        POP  DS
        RETMACRO

; KMouse_MouseShow: no return value -- INT 33h AX=1 (show cursor); no-op
; if no mouse was detected.
KMouse_MouseShow:
        PUSH AX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AX, 1
        INT  33H
        MOV  BYTE [mouseState], 1
.nomouse:
        POP  DS
        POP  AX
        RETMACRO

; KMouse_MouseHide: no return value -- INT 33h AX=2 (hide cursor); no-op
; if no mouse was detected.
KMouse_MouseHide:
        PUSH AX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AX, 2
        INT  33H
        MOV  BYTE [mouseState], 0
.nomouse:
        POP  DS
        POP  AX
        RETMACRO

; KMouse_MouseButtons: BYTE -- INT 33h AX=3 (get position/button status),
; low 2 bits of BL = button state; 0 if no mouse.
KMouse_MouseButtons:
        PUSH BX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AX, 3
        INT  33H
        MOV  AL, BL
        AND  AL, 3
        JMP  .end
.nomouse:
        XOR  AL, AL
.end:
        POP  DS
        POP  BX
        RETMACRO

; KMouse_MouseGetX/GetY: INTEGER -- INT 33h AX=3, CX/DX = pixel position;
; shifted right by 3 to convert from the driver's 1-pixel-per-unit
; graphics coordinate to an 8x8 text-cell column/row (matches the
; original Pascal's "shr ax, 3"); 0 if no mouse.
KMouse_MouseGetX:
        PUSH CX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AX, 3
        INT  33H
        MOV  AX, CX
        MOV  CL, 3
        SHR  AX, CL
        JMP  .end
.nomouse:
        XOR  AX, AX
.end:
        POP  DS
        POP  CX
        RETMACRO

KMouse_MouseGetY:
        PUSH CX
        PUSH DX
        PUSH DS
        MOV  AX, SEG haveExtKb
        MOV  DS, AX
        MOV  AL, [mousePresent]
        OR   AL, AL
        JZ   .nomouse
        MOV  AX, 3
        INT  33H
        MOV  AX, DX
        MOV  CL, 3
        SHR  AX, CL
        JMP  .end
.nomouse:
        XOR  AX, AX
.end:
        POP  DS
        POP  DX
        POP  CX
        RETMACRO
