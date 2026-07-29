; TETRIS.ASM -- CGA blitter + BIOS/port helpers for the Oberon Tetris port.
;
; Routines (all FAR; the caller does NOT clean the stack, so each routine
; that takes arguments returns with `retf <argBytes>`):
;
;   Draw(VAR buf; VAR spr)          CGA sprite blitter -> B800h
;   GraphMode                       INT 10h AX=0004h (CGA mode 4)
;   TextMode                        INT 10h AX=0003h (80x25 text)
;   GetKey(): WORD                  INT 16h AH=0  (blocking; AH=scan, AL=ascii)
;   HasKey(): BOOLEAN               INT 16h AH=1  (ZF clear => key waiting)
;   Scan(key: WORD): BYTE           high byte of key = scan code
;   Delay(ms: INTEGER)              INT 15h AH=86h (BIOS wait)
;   Sound(hz: INTEGER)              PIT ch2 + speaker gate on
;   NoSound                         speaker gate off
;
; Declared in TETRIS.MOD as `PROCEDURE Name(...); FAR; EXTERNAL;` and linked
; via (*$L TETRIS.RDF*).  Oberon function results come back in AX (BYTE /
; BOOLEAN zero-extended into AX).
;
; Calling convention (verified empirically for $L externals):
;  * FAR (retf); the CALLEE pops its own arguments -> `retf argBytes`.
;  * Oberon pushes args left-to-right, so with `push bp; mov bp,sp` and a FAR
;    return address (RSIZE=4) the FIRST param is at [bp+RSIZE+2], the next at
;    [bp+RSIZE+4], and so on (each VAR param is 4 bytes: ofs then seg).

BITS 16
CPU 8086

%define IS_FAR

SECTION .text

GLOBAL Tetris_Draw
GLOBAL Tetris_GraphMode, Tetris_TextMode
GLOBAL Tetris_GetKey, Tetris_HasKey, Tetris_Scan
GLOBAL Tetris_Delay, Tetris_Sound, Tetris_NoSound

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

; -----------------------------------------------------------------------------
; Draw(VAR buf; VAR spr)   -- 2 VAR params = 8 arg bytes -> retf 8
; Oberon pushes args left-to-right: param 1 (buf) lands at the HIGHEST offset,
; param 2 (spr) at the lowest.  With a FAR frame:
;   buf (param 1): ofs [bp+RSIZE+6], seg [bp+RSIZE+8]
;   spr (param 2): ofs [bp+RSIZE+2], seg [bp+RSIZE+4]
;
; For each of 25 rows x 40 columns of buf: read a sprite index byte, scale
; by 16 (SHL 4) to index spr, then copy the 4x8 CGA cell into B800: even
; scanlines at BX, odd scanlines at BX+2000h, +80 bytes per scanline pair.
; -----------------------------------------------------------------------------
Tetris_Draw:
        push    bp
        mov     bp, sp
        push    ds
        push    es
        push    si
        push    di
        push    bx

        les     di, [bp+RSIZE+2]        ; ES:DI = spr (param 2, low slot)
        lds     si, [bp+RSIZE+6]        ; DS:SI = buf (param 1, high slot)
        mov     dh, 25
        xor     bx, bx
        mov     bp, 0B800h              ; CGA video segment (BP scratch here)
        cld
.drawrow:
        push    bx
        mov     dl, 40
.drawcol:
        push    di
        push    bx
        push    ds
        lodsb                           ; AL = buf[] sprite index
        xor     ah, ah
        mov     cl, 4
        shl     ax, cl                  ; AX = index * 16
        add     di, ax                  ; ES:DI -> sprite cell
        mov     ds, bp                  ; DS = B800h
        mov     cl, 4
.drawchar:
        mov     ax, [es:di]
        mov     [bx], ax                ; even scanline
        add     di, 2
        mov     ax, [es:di]
        mov     [bx+2000h], ax          ; odd scanline
        add     di, 2
        add     bx, 80
        dec     cl
        jnz     .drawchar
        pop     ds
        pop     bx
        pop     di
        add     bx, 2
        dec     dl
        jnz     .drawcol
        pop     bx
        add     bx, 320
        dec     dh
        jnz     .drawrow

        pop     bx
        pop     di
        pop     si
        pop     es
        pop     ds
        pop     bp
        RETMACRO 8

; -----------------------------------------------------------------------------
; GraphMode / TextMode -- no args -> retf 0
; -----------------------------------------------------------------------------
Tetris_GraphMode:
        mov     ax, 0004h               ; INT 10h: set CGA mode 4 (320x200x4)
        int     10h
        RETMACRO

Tetris_TextMode:
        mov     ax, 0003h               ; INT 10h: set 80x25 colour text
        int     10h
        RETMACRO

; -----------------------------------------------------------------------------
; GetKey(): WORD -- blocking read, no args.  Result in AX (AH=scan, AL=ascii).
; -----------------------------------------------------------------------------
Tetris_GetKey:
        xor     ax, ax                  ; AH=0: read key (blocks)
        int     16h
        RETMACRO

; -----------------------------------------------------------------------------
; HasKey(): BOOLEAN -- no args.  AH=1 peek: ZF=0 => key available.
; Result 0/1 in AX.
; -----------------------------------------------------------------------------
Tetris_HasKey:
        mov     ax, 0100h               ; AH=1: check keyboard status
        int     16h
        mov     ax, 1
        jnz     .has                    ; ZF clear -> a key is waiting
        xor     ax, ax
.has:
        RETMACRO

; -----------------------------------------------------------------------------
; Scan(key: WORD): BYTE -- 1 arg (2 bytes) -> retf 2.
; Returns the high byte of key (the scan code) zero-extended in AX.
; -----------------------------------------------------------------------------
Tetris_Scan:
        push    bp
        mov     bp, sp
        mov     ax, [bp+RSIZE+2]        ; key
        mov     al, ah                  ; scan code = high byte
        xor     ah, ah
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; Delay(ms: INTEGER) -- 1 arg (2 bytes) -> retf 2.
; BIOS wait: INT 15h AH=86h, CX:DX = microseconds = ms * 1000.
; ms <= 0 returns immediately.  ms*1000 fits in 32 bits for any sane ms.
; -----------------------------------------------------------------------------
Tetris_Delay:
        push    bp
        mov     bp, sp
        mov     ax, [bp+RSIZE+2]        ; ms
        or      ax, ax
        jle     .done                   ; ms <= 0 -> no wait (signed)
        mov     cx, 1000
        mul     cx                      ; DX:AX = ms * 1000 = microseconds
        mov     cx, dx                  ; CX = us high word
        mov     dx, ax                  ; DX = us low word
        mov     ax, 8600h               ; INT 15h AH=86h: BIOS wait CX:DX us
        int     15h
.done:
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; Sound(hz: INTEGER) -- 1 arg (2 bytes) -> retf 2.
; divisor = 1193180 / hz; program PIT channel 2 (ports 43h/42h) and gate the
; speaker on via port 61h.  hz <= 0 returns immediately.
; -----------------------------------------------------------------------------
Tetris_Sound:
        push    bp
        mov     bp, sp
        mov     bx, [bp+RSIZE+2]        ; hz
        or      bx, bx
        jle     .ret                    ; hz <= 0 -> no tone
        ; divisor = 1193180 / hz  (1193180 = 0012_34DDh)
        mov     dx, 0012h
        mov     ax, 34DDh
        div     bx                      ; AX = 1193180 / hz  (divisor)
        mov     bx, ax                  ; keep divisor in BX
        mov     al, 0B6h                ; PIT: ch2, mode 3, lobyte/hibyte
        out     43h, al
        mov     al, bl                  ; divisor low
        out     42h, al
        mov     al, bh                  ; divisor high
        out     42h, al
        in      al, 61h                 ; gate speaker on
        or      al, 03h
        out     61h, al
.ret:
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; NoSound -- no args -> retf 0.  Gate the speaker off (clear bits 0-1 of 61h).
; -----------------------------------------------------------------------------
Tetris_NoSound:
        in      al, 61h
        and     al, 0FCh
        out     61h, al
        RETMACRO
