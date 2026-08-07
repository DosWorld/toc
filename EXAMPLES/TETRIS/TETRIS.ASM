IDEAL
MODEL Small
;
; TETRIS.ASM -- CGA blitter + BIOS/port helpers for the Oberon Tetris
; port, written in genuine Borland Turbo Assembler 5.0 (Ideal mode) syntax.
; This is a hand-conversion of TETRIS.ASM (NASM subset) into real TASM
; dialect, meant as a round-trip fixture for `tasm /LNG=turbo`: converting
; this file back should reproduce TETRIS.ASM's behavior (not its exact
; bytes -- PROC/ARG/RET's automatic PASCAL prologue/epilogue and TURBO.MOD's
; own translation choices don't guarantee byte-identical output, only the
; same external calling convention and the same instructions per routine).
;
; Routines (all FAR PASCAL, matching TETRIS.MOD's `PROCEDURE ...; FAR;
; EXTERNAL;` declarations -- see DOCS/OBERLANG.MD "Calling convention:
; Pascal (callee cleans)": left-to-right push order, callee cleans the
; stack via RETF n, FAR params start at [bp+6]):
;
;   Draw(VAR buf; VAR spr)          CGA sprite blitter -> B800h
;   CalcDiff(VAR screen; VAR prev)  dirty-cell diff pass before Draw
;   GraphMode                       INT 10h AX=0004h (CGA mode 4)
;   TextMode                        INT 10h AX=0003h (80x25 text)
;   SetCgaPalette(num: BYTE)        INT 10h AH=0Bh BH=1
;   GetKey(): WORD                  INT 16h AH=0  (blocking; AH=scan, AL=ascii)
;   HasKey(): BOOLEAN               INT 16h AH=1  (ZF clear => key waiting)
;   Scan(key: WORD): BYTE           high byte of key = scan code
;   WaitKey                         drain buffered keys, then block for one
;   Delay(ms: INTEGER)              INT 15h AH=86h (BIOS wait)
;   Sound(hz: INTEGER)              PIT ch2 + speaker gate on
;   NoSound                         speaker gate off
;   SetCgaSeg(seg: INTEGER)         stash the CGA video segment for Draw
;
; PROC ... PASCAL FAR + ARG generates the [bp+6..]-based ARG offsets and the
; matching `RETF argBytes` epilogue automatically (Chapter 10 "Declaring
; procedures" / "Calling procedures with stack frames") -- no RSIZE/RETMACRO
; %define plumbing needed the way the NASM subset version required, since
; TASM's own PROC header already knows FAR means a 4-byte return address.
; ARG's VAR-param entries are declared DWORD (a 4-byte far pointer: offset
; word then segment word, matching Oberon's VAR-param push order).

DATASEG

cgaseg  DW  0

CODESEG

PUBLIC  Tetris_Draw, Tetris_CalcDiff
PUBLIC  Tetris_GraphMode, Tetris_TextMode, Tetris_SetCgaPalette
PUBLIC  Tetris_GetKey, Tetris_HasKey, Tetris_Scan, Tetris_WaitKey
PUBLIC  Tetris_Delay, Tetris_Sound, Tetris_NoSound, Tetris_SetCgaSeg

; -----------------------------------------------------------------------
; SetCgaSeg(seg: INTEGER) -- 1 scalar arg -> RETF 2.
; -----------------------------------------------------------------------
PROC Tetris_SetCgaSeg PASCAL FAR
    ARG @@seg:WORD
    USES es

    mov     ax, @@seg
    mov     bx, seg cgaseg
    mov     es, bx
    mov     [es:cgaseg], ax
    RET
ENDP

; -----------------------------------------------------------------------
; CalcDiff(VAR screen; VAR prev) -- 2 VAR params = 8 arg bytes -> RETF 8.
; Dirty-cell diff over all 25*40 = 1000 bytes.  For each cell i:
;   if screen[i] = prev[i]  ->  screen[i] := 0FFh  (mark unchanged for Draw)
;   else                    ->  prev[i]   := screen[i]  (remember new value)
; After this, Draw skips every 0FFh cell, so only cells that changed since
; the previous frame are blitted.  DS:SI walks screen, ES:DI walks prev,
; in lockstep.  ARG is written in TETRIS.MOD's own natural declared
; parameter order (screen first, then prev) -- for a PASCAL proc, TURBO.MOD
; assigns each ARG name its stack offset by walking the declared list
; back-to-front internally (PASCAL pushes left-to-right, so the FIRST
; declared parameter is pushed FIRST and ends up at the LARGEST/deepest
; offset), so the ARG list itself never needs to be hand-reversed here.
; -----------------------------------------------------------------------
PROC Tetris_CalcDiff PASCAL FAR
    ARG @@screen:DWORD, @@prev:DWORD
    USES ds, es

    les     di, @@prev             ; ES:DI = prev
    lds     si, @@screen           ; DS:SI = screen
    mov     cx, 1000               ; 25*40 cells
    cld
@@cdloop:
    lodsb                          ; AL = screen[i]; SI++ (SI now -> i+1)
    cmp     al, [es:di]            ; == prev[i] ?
    jne     @@cdchanged
    mov     byte ptr [si-1], 0FFh  ; unchanged -> mask screen[i] so Draw skips it
    inc     di                     ; advance prev in step (no write)
    jmp     @@cdnext
@@cdchanged:
    stosb                          ; changed -> prev[i] := AL (screen value); DI++
@@cdnext:
    dec     cx
    jnz     @@cdloop

    RET
ENDP

; -----------------------------------------------------------------------
; Draw(VAR buf; VAR spr) -- 2 VAR params = 8 arg bytes -> RETF 8.
;
; Dirty-cell blit: a cell whose sprite index byte is 0FFh is UNCHANGED since
; the previous frame -- the blitter skips it entirely (leaves that 4x8 area
; of CGA memory untouched) and only advances the CGA cursor.  Sprite indices
; are 0..9, so 0FFh is a safe "skip" sentinel that ReDraw writes into every
; cell that did not change.
;
; For each of 25 rows x 40 columns of buf: read a sprite index byte; if
; 0FFh, skip; else scale by 16 (SHL 4) to index spr, then copy the 4x8 CGA
; cell into B800h: even scanlines at BX, odd scanlines at BX+2000h, +80
; bytes per scanline pair.
; -----------------------------------------------------------------------
PROC Tetris_Draw PASCAL FAR
    ARG @@buf:DWORD, @@spr:DWORD
    USES ds, es

    les     di, @@spr             ; ES:DI = spr
    lds     si, @@buf             ; DS:SI = buf

    push    ds
    mov     ax, seg cgaseg
    mov     ds, ax
    mov     bp, [cgaseg]           ; CGA video segment (BP scratch; frame ptr no longer needed)
    pop     ds
    mov     dh, 25
    xor     bx, bx
    cld
@@drawrow:
    push    bx
    mov     dl, 40
@@drawcol:
    lodsb                          ; AL = buf[] sprite index
    cmp     al, 0FFh               ; unchanged cell?
    je      @@skipcell             ; yes -> leave CGA area untouched
    push    di
    push    bx
    push    ds
    xor     ah, ah
    mov     cl, 4
    shl     ax, cl                 ; AX = index * 16
    add     di, ax                 ; ES:DI -> sprite cell
    mov     ds, bp                 ; DS = B800h
    mov     cl, 4
@@drawchar:
    mov     ax, [es:di]
    mov     [bx], ax               ; even scanline
    add     di, 2
    mov     ax, [es:di]
    mov     [bx+2000h], ax         ; odd scanline
    add     di, 2
    add     bx, 80
    dec     cl
    jnz     @@drawchar
    pop     ds
    pop     bx
    pop     di
@@skipcell:
    add     bx, 2
    dec     dl
    jnz     @@drawcol
    pop     bx
    add     bx, 320
    dec     dh
    jnz     @@drawrow

    RET
ENDP

; -----------------------------------------------------------------------
; GraphMode / TextMode -- no args -> RETF 0.
; -----------------------------------------------------------------------
PROC Tetris_GraphMode PASCAL FAR
    mov     ax, 0004h              ; INT 10h: set CGA mode 4 (320x200x4)
    int     10h
    RET
ENDP

PROC Tetris_TextMode PASCAL FAR
    mov     ax, 0003h              ; INT 10h: set 80x25 colour text
    int     10h
    RET
ENDP

; -----------------------------------------------------------------------
; SetCgaPalette(num: BYTE) -- 1 arg -> RETF 2.
; Selects the CGA mode-4 palette via INT 10h AH=0Bh, BH=1:
;   num=0 -> green / red / brown ; num=1 -> cyan / magenta / white.
; -----------------------------------------------------------------------
PROC Tetris_SetCgaPalette PASCAL FAR
    ARG @@num:WORD

    mov     al, @@num              ; AL = num (low byte of arg word)
    mov     bl, al                 ; BL = palette number
    mov     bh, 1                  ; BH=1: select palette
    mov     ah, 0Bh                ; INT 10h AH=0Bh: set colour palette
    int     10h
    RET
ENDP

; -----------------------------------------------------------------------
; GetKey(): WORD -- blocking read, no args.  Result in AX (AH=scan, AL=ascii).
; -----------------------------------------------------------------------
PROC Tetris_GetKey PASCAL FAR
    xor     ax, ax                 ; AH=0: read key (blocks)
    int     16h
    RET
ENDP

; -----------------------------------------------------------------------
; HasKey(): BOOLEAN -- no args.  AH=1 peek: ZF=0 => key available.
; Result 0/1 in AX.
; -----------------------------------------------------------------------
PROC Tetris_HasKey PASCAL FAR
    mov     ax, 0100h              ; AH=1: check keyboard status
    int     16h
    mov     ax, 1
    jnz     @@has                  ; ZF clear -> a key is waiting
    xor     ax, ax
@@has:
    RET
ENDP

; -----------------------------------------------------------------------
; WaitKey -- no args -> RETF 0.  Drain any keys already in the buffer,
; then block until the next keypress (result discarded).  Equivalent to
; the Oberon  WHILE HasKey() DO GetKey() END; GetKey()
; -----------------------------------------------------------------------
PROC Tetris_WaitKey PASCAL FAR
@@drain:
    mov     ax, 0100h              ; AH=1: peek keyboard status
    int     16h
    jz      @@block                ; ZF set -> buffer empty, go block
    xor     ax, ax                 ; AH=0: consume the waiting key
    int     16h
    jmp     @@drain
@@block:
    xor     ax, ax                 ; AH=0: block for one keypress
    int     16h
    RET
ENDP

; -----------------------------------------------------------------------
; Scan(key: WORD): BYTE -- 1 arg -> RETF 2.
; Returns the high byte of key (the scan code) zero-extended in AX.
; -----------------------------------------------------------------------
PROC Tetris_Scan PASCAL FAR
    ARG @@key:WORD

    mov     ax, @@key
    mov     al, ah                 ; scan code = high byte
    xor     ah, ah
    RET
ENDP

; -----------------------------------------------------------------------
; Delay(ms: INTEGER) -- 1 arg -> RETF 2.
; BIOS wait: INT 15h AH=86h, CX:DX = microseconds = ms * 1000.
; ms <= 0 returns immediately.  ms*1000 fits in 32 bits for any sane ms.
; -----------------------------------------------------------------------
PROC Tetris_Delay PASCAL FAR
    ARG @@ms:WORD

    mov     ax, @@ms
    or      ax, ax
    jle     @@ddone                ; ms <= 0 -> no wait (signed)
    mov     cx, 1000
    mul     cx                     ; DX:AX = ms * 1000 = microseconds
    mov     cx, dx                 ; CX = us high word
    mov     dx, ax                 ; DX = us low word
    mov     ax, 8600h              ; INT 15h AH=86h: BIOS wait CX:DX us
    int     15h
@@ddone:
    RET
ENDP

; -----------------------------------------------------------------------
; Sound(hz: INTEGER) -- 1 arg -> RETF 2.
; divisor = 1193180 / hz; program PIT channel 2 (ports 43h/42h) and gate
; the speaker on via port 61h.  hz <= 0 returns immediately.
; -----------------------------------------------------------------------
PROC Tetris_Sound PASCAL FAR
    ARG @@hz:WORD

    mov     bx, @@hz
    or      bx, bx
    jle     @@sret                 ; hz <= 0 -> no tone
    ; divisor = 1193180 / hz  (1193180 = 0012_34DDh)
    mov     dx, 0012h
    mov     ax, 34DDh
    div     bx                     ; AX = 1193180 / hz  (divisor)
    mov     bx, ax                 ; keep divisor in BX
    mov     al, 0B6h               ; PIT: ch2, mode 3, lobyte/hibyte
    out     43h, al
    mov     al, bl                 ; divisor low
    out     42h, al
    mov     al, bh                 ; divisor high
    out     42h, al
    in      al, 61h                ; gate speaker on
    or      al, 03h
    out     61h, al
@@sret:
    RET
ENDP

; -----------------------------------------------------------------------
; NoSound -- no args -> RETF 0.  Gate the speaker off (clear bits 0-1 of
; port 61h).
; -----------------------------------------------------------------------
PROC Tetris_NoSound PASCAL FAR
    in      al, 61h
    and     al, 0FCh
    out     61h, al
    RET
ENDP

END
