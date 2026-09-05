bits 16
cpu 8086
%define IS_FAR

; -----------------------------------------------------------------------------
; DOS.ASM -- assembly half of module Dos, linked into DOS.MOD via (*$L DOS.RDF*)
; exactly as EMS.ASM/EMS.MOD and OVERLAY.ASM/OVERLAY.MOD are paired.
;
; WHAT LIVES HERE AND WHY
; Every procedure moved here was a thin INT 21h wrapper whose entire Oberon
; body was "fill a SYSTEM.Registers record, call SYSTEM.Intr, read fields
; back".  That record is ~30 bytes of stack plus a field store per register,
; and SYSTEM.Intr then copies it into the real registers and back again --
; all so a two-instruction DOS call can be made.  Written directly in
; assembly each of these is a handful of instructions with no frame at all.
;
; WHAT DELIBERATELY STAYS IN DOS.MOD
;   GetEnv, ParamStr, FSplit, PathJoin, FExpand  -- string parsing, not
;     register shuffling; they would be longer, harder to read and no faster
;     in assembly.
;   Intr, MsDos, SwapVectors                     -- Intr/MsDos are the raw
;     SYSTEM.Intr passthroughs the rest of the module is built on.
;   FindFirst/FindNext                           -- they marshal an ASCIIZ
;     path copy and a SearchRec; the DOS call is the small part.
;
; CONVENTIONS (see DOCS/OBERLANG.MD "Calling convention")
;   - FAR procedures: return address is 4 bytes, hence RSIZE below.
;   - Arguments pushed LEFT TO RIGHT, so the first parameter lies DEEPEST
;     (highest offset) and the LAST parameter sits nearest BP at
;     [bp+RSIZE+2] -- DOCS/OBERLANG.MD's frame layout, confirmed
;     empirically with a 3-argument probe.  Sizes: INTEGER 2, VAR param 4
;     ({ofs:2, seg:2}), open array 6 ({ofs:2, seg:2, len:2}).
;   - A VAR parameter is a 4-byte far pointer: `les di, <ofs>` then write
;     through [es:di] -- the same idiom EMS_Alloc uses for its handle.
;   - Callee removes its own arguments: RETMACRO n.
;   - DS must be reloaded before touching this module's own .data (none of
;     these procedures have any, so DS is only saved when a DOS call needs
;     it pointed elsewhere).
; -----------------------------------------------------------------------------

section .text

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

global Dos_GetDate, Dos_SetDate, Dos_GetTime, Dos_SetTime
global Dos_GetCBreak, Dos_SetCBreak, Dos_GetVerify, Dos_SetVerify
global Dos_GetDTA, Dos_SetDTA, Dos_GetIntVec, Dos_SetIntVec
global Dos_MkDir, Dos_ChDir

; -----------------------------------------------------------------------------
; PROCEDURE GetDate*(VAR Year,Month,Day,DayOfWeek: INTEGER);
; INT 21h/AH=2Ah -> CX=year, DH=month, DL=day, AL=day-of-week.
; -----------------------------------------------------------------------------
Dos_GetDate:
        push    bp
        mov     bp, sp
        push    ds
        %define gd_year_ofs [bp+RSIZE+14]
        %define gd_year_seg [bp+RSIZE+16]
        %define gd_mon_ofs [bp+RSIZE+10]
        %define gd_mon_seg [bp+RSIZE+12]
        %define gd_day_ofs [bp+RSIZE+6]
        %define gd_day_seg [bp+RSIZE+8]
        %define gd_dow_ofs [bp+RSIZE+2]
        %define gd_dow_seg [bp+RSIZE+4]
        push    bx
        push    cx
        push    dx
        push    es
        push    di

        mov     ah, 2Ah
        int     21h
        ; AL=dow, CX=year, DH=month, DL=day
        mov     bx, dx                  ; keep month/day, DX is clobbered next
        xor     ah, ah
        mov     dx, ax                  ; DX = day-of-week (zero-extended)

        les     di, gd_year_ofs
        mov     [es:di], cx
        mov     al, bh                  ; month
        xor     ah, ah
        les     di, gd_mon_ofs
        mov     [es:di], ax
        mov     al, bl                  ; day
        xor     ah, ah
        les     di, gd_day_ofs
        mov     [es:di], ax
        les     di, gd_dow_ofs
        mov     [es:di], dx

        pop     di
        pop     es
        pop     dx
        pop     cx
        pop     bx
        pop     ds
        pop     bp
        RETMACRO 16

; -----------------------------------------------------------------------------
; PROCEDURE SetDate*(Year,Month,Day: INTEGER);
; INT 21h/AH=2Bh, CX=year, DH=month, DL=day.
; -----------------------------------------------------------------------------
Dos_SetDate:
        push    bp
        mov     bp, sp
        push    ds
        %define sd_year [bp+RSIZE+6]
        %define sd_mon [bp+RSIZE+4]
        %define sd_day [bp+RSIZE+2]
        push    cx
        push    dx

        mov     cx, sd_year
        mov     dx, sd_mon
        mov     dh, dl                  ; DH = month
        mov     ax, sd_day
        mov     dl, al                  ; DL = day
        mov     ah, 2Bh
        int     21h

        pop     dx
        pop     cx
        pop     ds
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; PROCEDURE GetTime*(VAR Hour,Minute,Second,Sec100: INTEGER);
; INT 21h/AH=2Ch -> CH=hour, CL=min, DH=sec, DL=hundredths.
; -----------------------------------------------------------------------------
Dos_GetTime:
        push    bp
        mov     bp, sp
        push    ds
        %define gt_h_ofs [bp+RSIZE+14]
        %define gt_m_ofs [bp+RSIZE+10]
        %define gt_s_ofs [bp+RSIZE+6]
        %define gt_c_ofs [bp+RSIZE+2]
        push    bx
        push    cx
        push    dx
        push    es
        push    di

        mov     ah, 2Ch
        int     21h
        mov     bx, cx                  ; BH=hour, BL=min

        mov     al, bh
        xor     ah, ah
        les     di, gt_h_ofs
        mov     [es:di], ax
        mov     al, bl
        xor     ah, ah
        les     di, gt_m_ofs
        mov     [es:di], ax
        mov     al, dh
        xor     ah, ah
        les     di, gt_s_ofs
        mov     [es:di], ax
        mov     al, dl
        xor     ah, ah
        les     di, gt_c_ofs
        mov     [es:di], ax

        pop     di
        pop     es
        pop     dx
        pop     cx
        pop     bx
        pop     ds
        pop     bp
        RETMACRO 16

; -----------------------------------------------------------------------------
; PROCEDURE SetTime*(Hour,Minute,Second,Sec100: INTEGER);
; INT 21h/AH=2Dh, CH=hour, CL=min, DH=sec, DL=hundredths.
; -----------------------------------------------------------------------------
Dos_SetTime:
        push    bp
        mov     bp, sp
        push    ds
        %define st_h [bp+RSIZE+8]
        %define st_m [bp+RSIZE+6]
        %define st_s [bp+RSIZE+4]
        %define st_c [bp+RSIZE+2]
        push    cx
        push    dx

        mov     ax, st_h
        mov     ch, al
        mov     ax, st_m
        mov     cl, al
        mov     ax, st_s
        mov     dh, al
        mov     ax, st_c
        mov     dl, al
        mov     ah, 2Dh
        int     21h

        pop     dx
        pop     cx
        pop     ds
        pop     bp
        RETMACRO 8

; -----------------------------------------------------------------------------
; PROCEDURE GetCBreak*(VAR Break: BOOLEAN);
; INT 21h/AX=3300h -> DL = current break state.  BOOLEAN is one byte.
; -----------------------------------------------------------------------------
Dos_GetCBreak:
        push    bp
        mov     bp, sp
        push    ds
        %define gcb_ofs [bp+RSIZE+2]
        push    dx
        push    es
        push    di

        mov     ax, 3300h
        int     21h
        or      dl, dl
        jz      .off
        mov     al, 1
        jmp     .store
.off:
        xor     al, al
.store:
        les     di, gcb_ofs
        mov     [es:di], al

        pop     di
        pop     es
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 4

; -----------------------------------------------------------------------------
; PROCEDURE SetCBreak*(Break: BOOLEAN);
; INT 21h/AX=3301h, DL = new state.
; -----------------------------------------------------------------------------
Dos_SetCBreak:
        push    bp
        mov     bp, sp
        push    ds
        %define scb [bp+RSIZE+2]
        push    dx
        mov     ax, scb
        mov     dl, al
        and     dl, 1
        mov     ax, 3301h
        int     21h
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; PROCEDURE GetVerify*(VAR Verify: BOOLEAN);   INT 21h/AH=54h -> AL.
; -----------------------------------------------------------------------------
Dos_GetVerify:
        push    bp
        mov     bp, sp
        push    ds
        %define gv_ofs [bp+RSIZE+2]
        push    es
        push    di
        mov     ah, 54h
        int     21h
        and     al, 1
        les     di, gv_ofs
        mov     [es:di], al
        pop     di
        pop     es
        pop     ds
        pop     bp
        RETMACRO 4

; -----------------------------------------------------------------------------
; PROCEDURE SetVerify*(Verify: BOOLEAN);       INT 21h/AH=2Eh, AL = state.
; -----------------------------------------------------------------------------
Dos_SetVerify:
        push    bp
        mov     bp, sp
        push    ds
        %define sv [bp+RSIZE+2]
        mov     ax, sv
        and     al, 1
        mov     ah, 2Eh
        int     21h
        pop     ds
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; PROCEDURE GetDTA*(): SYSTEM.ADDRESS;
; INT 21h/AH=2Fh -> ES:BX.  A far pointer is returned in DX:AX (seg:ofs).
; -----------------------------------------------------------------------------
Dos_GetDTA:
        push    ds
        push    bx
        push    es
        mov     ah, 2Fh
        int     21h
        mov     ax, bx                  ; offset
        mov     dx, es                  ; segment
        pop     es
        pop     bx
        pop     ds
        RETMACRO 0

; -----------------------------------------------------------------------------
; PROCEDURE SetDTA*(dta: SYSTEM.ADDRESS);
; INT 21h/AH=1Ah, DS:DX = new DTA.  The ADDRESS arrives as {seg, ofs}.
; -----------------------------------------------------------------------------
Dos_SetDTA:
        push    bp
        mov     bp, sp
        %define sdta_ofs [bp+RSIZE+2]
        %define sdta_seg [bp+RSIZE+4]
        push    ds
        push    dx
        mov     dx, sdta_ofs
        mov     ax, sdta_seg
        mov     ds, ax
        mov     ah, 1Ah
        int     21h
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 4

; -----------------------------------------------------------------------------
; PROCEDURE GetIntVec*(IntNo: BYTE): SYSTEM.ADDRESS;
; INT 21h/AH=35h -> ES:BX.  Returned as DX:AX like GetDTA.
; -----------------------------------------------------------------------------
Dos_GetIntVec:
        push    bp
        mov     bp, sp
        push    ds
        %define giv_no [bp+RSIZE+6]
        %define giv_ofs [bp+RSIZE+2]
        %define giv_seg [bp+RSIZE+4]
        push    bx
        push    cx
        push    es
        push    di

        mov     ax, giv_no
        mov     ah, 35h
        int     21h
        mov     cx, es                  ; handler segment (ES is reused below)

        ; Vector is a VAR SYSTEM.ADDRESS: a 4-byte far pointer stored as
        ; {offset, segment} in that order, matching SYSTEM.PTR(seg, ofs).
        les     di, giv_ofs
        mov     [es:di], bx             ; offset
        mov     [es:di+2], cx           ; segment

        pop     di
        pop     es
        pop     cx
        pop     bx
        pop     ds
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; PROCEDURE SetIntVec*(IntNo: BYTE; Vec: SYSTEM.ADDRESS);
; INT 21h/AH=25h, AL = vector number, DS:DX = handler.
; -----------------------------------------------------------------------------
Dos_SetIntVec:
        push    bp
        mov     bp, sp
        %define siv_no [bp+RSIZE+6]
        %define siv_ofs [bp+RSIZE+2]
        %define siv_seg [bp+RSIZE+4]
        push    ds
        push    dx
        mov     dx, siv_ofs
        mov     ax, siv_seg
        mov     ds, ax
        mov     ax, siv_no
        mov     ah, 25h
        int     21h
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; PROCEDURE MkDir*(Path: ARRAY OF CHAR): BOOLEAN;   INT 21h/AH=39h.
; PROCEDURE ChDir*(Path: ARRAY OF CHAR): BOOLEAN;   INT 21h/AH=3Bh.
; An open-array CHAR parameter arrives as {seg, ofs, len} (DOCS/OBERLANG.MD
; open-array ABI); the string is already 0X-terminated by the caller, so the
; length word is ignored and DS:DX points straight at it.  Result AX = 0/1.
; -----------------------------------------------------------------------------
Dos_MkDir:
        push    bp
        mov     bp, sp
        ; open array = {ofs:2, seg:2, len:2}, sole param so it starts at +2
        %define mk_ofs [bp+RSIZE+2]
        %define mk_seg [bp+RSIZE+4]
        push    ds
        push    dx
        mov     dx, mk_ofs
        mov     ax, mk_seg
        mov     ds, ax
        mov     ah, 39h
        int     21h
        mov     ax, 1
        jnc     .ret
        xor     ax, ax
.ret:
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 6

Dos_ChDir:
        push    bp
        mov     bp, sp
        ; open array = {ofs:2, seg:2, len:2}, sole param so it starts at +2
        %define cd_ofs [bp+RSIZE+2]
        %define cd_seg [bp+RSIZE+4]
        push    ds
        push    dx
        mov     dx, cd_ofs
        mov     ax, cd_seg
        mov     ds, ax
        mov     ah, 3Bh
        int     21h
        mov     ax, 1
        jnc     .ret
        xor     ax, ax
.ret:
        pop     dx
        pop     ds
        pop     bp
        RETMACRO 6
