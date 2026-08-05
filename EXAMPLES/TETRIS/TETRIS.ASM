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

SECTION .data

cgaseg: dw 0

SECTION .text

GLOBAL Tetris_Draw, Tetris_CalcDiff
GLOBAL Tetris_GraphMode, Tetris_TextMode, Tetris_SetCgaPalette
GLOBAL Tetris_GetKey, Tetris_HasKey, Tetris_Scan, Tetris_WaitKey
GLOBAL Tetris_Delay, Tetris_Sound, Tetris_NoSound, Tetris_SetCgaSeg

%define IS_FAR

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

Tetris_SetCgaSeg:
        push bp
        mov  bp, sp
        push es
        mov  ax, [ss:bp+RSIZE+2]
        mov  bx, seg cgaseg
        mov  es, bx
        mov  [es:cgaseg], ax
        pop  es
        pop  bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; CalcDiff(VAR screen; VAR prev)  -- 2 VAR params = 8 arg bytes -> retf 8
; Dirty-cell diff over all 25*40 = 1000 bytes.  For each cell i:
;   if screen[i] = prev[i]  ->  screen[i] := 0FFH  (mark unchanged for Draw)
;   else                    ->  prev[i]   := screen[i]  (remember new value)
; After this, Draw skips every 0FFH cell, so only cells that changed since the
; previous frame are blitted.  Same FAR/Pascal convention as Draw:
;   screen (param 1): ofs [bp+RSIZE+6], seg [bp+RSIZE+8]
;   prev   (param 2): ofs [bp+RSIZE+2], seg [bp+RSIZE+4]
; DS:SI walks screen, ES:DI walks prev, in lockstep.
; -----------------------------------------------------------------------------
Tetris_CalcDiff:
        push    bp
        mov     bp, sp
        push    ds
        push    es
        push    si
        push    di

        les     di, [ss:bp+RSIZE+2]        ; ES:DI = prev   (param 2, low slot)
        lds     si, [ss:bp+RSIZE+6]        ; DS:SI = screen (param 1, high slot)
        mov     cx, 1000                ; 25*40 cells
        cld
.cdloop:
        lodsb                           ; AL = screen[i]; SI++ (SI now -> i+1)
        cmp     al, [es:di]             ; == prev[i] ?
        jne     .cdchanged
        mov     byte [si-1], 0FFH       ; unchanged -> mask screen[i] so Draw skips it
        inc     di                      ; advance prev in step (no write)
        jmp     .cdnext
.cdchanged:
        stosb                           ; changed -> prev[i] := AL (screen value); DI++
.cdnext:
        dec     cx
        jnz     .cdloop

        pop     di
        pop     si
        pop     es
        pop     ds
        pop     bp
        RETMACRO 8

; -----------------------------------------------------------------------------
; Draw(VAR buf; VAR spr)   -- 2 VAR params = 8 arg bytes -> retf 8
; Oberon pushes args left-to-right: param 1 (buf) lands at the HIGHEST offset,
; param 2 (spr) at the lowest.  With a FAR frame:
;   buf (param 1): ofs [bp+RSIZE+6], seg [bp+RSIZE+8]
;   spr (param 2): ofs [bp+RSIZE+2], seg [bp+RSIZE+4]
;
; Dirty-cell blit: a cell whose sprite index byte is 0FFH is UNCHANGED since
; the previous frame -- the blitter skips it entirely (leaves that 4x8 area of
; CGA memory untouched) and only advances the CGA cursor.  Sprite indices are
; 0..9, so 0FFH is a safe "skip" sentinel that ReDraw writes into every cell
; that did not change.
;
; For each of 25 rows x 40 columns of buf: read a sprite index byte; if 0FFH,
; skip; else scale by 16 (SHL 4) to index spr, then copy the 4x8 CGA cell into
; B800: even scanlines at BX, odd scanlines at BX+2000h, +80 bytes per
; scanline pair.
; -----------------------------------------------------------------------------
Tetris_Draw:
        push    bp
        mov     bp, sp
        push    ds
        push    es
        push    si
        push    di
        push    bx

        les     di, [ss:bp+RSIZE+2]        ; ES:DI = spr (param 2, low slot)
        lds     si, [ss:bp+RSIZE+6]        ; DS:SI = buf (param 1, high slot)

        push    ds
        mov     ax, seg cgaseg
        mov     ds, ax
        mov     bp, [cgaseg]            ; CGA video segment (BP scratch; frame ptr no longer needed)
        pop     ds
        mov     dh, 25
        xor     bx, bx
        cld
.drawrow:
        push    bx
        mov     dl, 40
.drawcol:
        lodsb                           ; AL = buf[] sprite index
        cmp     al, 0FFH                ; unchanged cell?
        je      .skipcell               ; yes -> leave CGA area untouched
        push    di
        push    bx
        push    ds
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
.skipcell:
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
; SetCgaPalette(num: BYTE) -- 1 arg (2 bytes) -> retf 2.
; Selects the CGA mode-4 palette via INT 10h AH=0Bh, BH=1:
;   num=0 -> green / red / brown ; num=1 -> cyan / magenta / white.
; The BYTE arg is passed in the low byte of the pushed word at [bp+RSIZE+2].
; -----------------------------------------------------------------------------
Tetris_SetCgaPalette:
        push    bp
        mov     bp, sp
        mov     al, [ss:bp+RSIZE+2]        ; AL = num (low byte of arg word)
        mov     bl, al                  ; BL = palette number
        mov     bh, 1                   ; BH=1: select palette
        mov     ah, 0Bh                 ; INT 10h AH=0Bh: set colour palette
        int     10h
        pop     bp
        RETMACRO 2

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
; WaitKey -- no args -> retf 0.  Drain any keys already in the buffer, then
; block until the next keypress (result discarded).  Equivalent to the Oberon
;   WHILE HasKey() DO GetKey() END; GetKey()
; -----------------------------------------------------------------------------
Tetris_WaitKey:
.drain:
        mov     ax, 0100h               ; AH=1: peek keyboard status
        int     16h
        jz      .block                  ; ZF set -> buffer empty, go block
        xor     ax, ax                  ; AH=0: consume the waiting key
        int     16h
        jmp     .drain
.block:
        xor     ax, ax                  ; AH=0: block for one keypress
        int     16h
        RETMACRO

; -----------------------------------------------------------------------------
; Scan(key: WORD): BYTE -- 1 arg (2 bytes) -> retf 2.
; Returns the high byte of key (the scan code) zero-extended in AX.
; -----------------------------------------------------------------------------
Tetris_Scan:
        push    bp
        mov     bp, sp
        mov     ax, [ss:bp+RSIZE+2]     ; key
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
        mov     ax, [ss:bp+RSIZE+2]        ; ms
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
        mov     bx, [ss:bp+RSIZE+2]        ; hz
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
