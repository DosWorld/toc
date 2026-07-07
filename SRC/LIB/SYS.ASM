bits 16
cpu 8086
%define IS_FAR

section .data
i87:
    dw 0
section .text

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif


struc TRegisters
    ._AX resw 1
    ._BX resw 1
    ._CX resw 1
    ._DX resw 1
    ._SI resw 1
    ._DI resw 1
    ._DS resw 1
    ._ES resw 1
    ._Flags resw 1
endstruc

global SYSTEM_INIT, SYSTEM_DONE
global SYSTEM_Intr, SYSTEM_CallFar
global SYSTEM_Alloc, SYSTEM_Free
global SYSTEM_MemAvail, SYSTEM_MemMaxAvail
global SYSTEM_S32DIV, SYSTEM_S32MOD, SYSTEM_S32MUL
global SYSTEM_REQUIRE87
global SYSTEM_Halt

check_8087:
        FNINIT
        FSTCW   [i87]
        FWAIT
        MOV     AX, [i87]
        AND     AX, 0x103F
        CMP     AX, 0x003F
        MOV     AL, 0
        JNE     .no_fpu
        INC     AL
.no_fpu:
        retn
i87msg:
    db 'Numeric coprecessor required.$'
nomemmsg:
    db 'Not enough memory.$'

SYSTEM_REQUIRE87:
        cmp  BYTE[i87], 0
        jne  .ok
        mov  al, 87
        mov  dx, i87msg
        jmp  ErrWithMsg
.ok:
        RETF
SYSTEM_Halt:
        ; FAR proc, no prologue.  Param byte was pushed as a word before
        ; CALL FAR, then CALL FAR pushed CS:IP.  Stack:
        ;   [SP+0]=ret IP   [SP+2]=ret CS   [SP+4]=param word (low byte = code)
        mov  bx, sp
        mov  al, BYTE[ss:bx+4]
        mov  BYTE[cs:err_code], AL
        jmp  SYSTEM_DONE

ErrWithMsg:
        mov  BYTE[cs:err_code], al
        push ds
        mov  ax, cs
        mov  ds, ax
        mov  ah, 9
        int  21h
        pop  ds
        jmp  SYSTEM_DONE
SYSTEM_INIT:
        push ax
        push bx
        mov  ax, seg i87
        mov  ds, ax
        call check_8087
        xor  ah, ah
        mov  [i87], ax
        mov  ah, 48h
        mov  bx, 0FFFFh
        int  21h
        jc   .end1
        push es
        mov  es, ax
        mov  ah, 49h
        int  21h
        pop  es
        mov  bx, 0FFFFh
.end1:
        pop  cx
        pop  ax
        cmp  bx, ax           ; paragraph counts are UNSIGNED (0..65535)
        jae  .okmem_min       ; unsigned: BX (free) >= AX (user_min)?
        mov  al, 1
        mov  dx, nomemmsg
        jmp  ErrWithMsg
.okmem_min:
        cmp  bx, cx
        jbe  .okmem        ; clamp unsigned
        mov  bx, cx
.okmem:
        push bx
        mov  ah, 48h
        int  21h
        jnc  .end2
        xor  ax, ax
.end2:
        pop  bx
        push ax
        push bx
        push cs
        call MEM_INIT
        retf

SYSTEM_DONE:
        push es
        mov  ax, [cs:MemStartSeg]
        mov  es, ax
        mov  ah, 49h
        int  21h
        pop  es
        mov  al, [cs:err_code]
        mov  ah, 4Ch
        int  21h

err_code: db 0

; SS:SP snapshot for SYSTEM_Intr.  Stored in the code segment so the save
; site doesn't touch the stack and the restore site doesn't need a valid
; SS (some DOS calls — notably INT 21h / 4B00h Exec — leave SS:SP
; corrupted on return).  CS overrides let us read/write these without DS.
saved_ss: dw 0
saved_sp: dw 0

SYSTEM_Intr:
    push bp
    mov  bp, sp
    sub  sp, 4
    %define IntNo_byte bp+RSIZE+6
    %define Regs_seg   bp+RSIZE+4
    %define Regs_off   bp+RSIZE+2
    %define saved_off  bp-2
    %define saved_seg  bp-4
    push ds
    push es
    push si
    push di

    mov  al, [ss:IntNo_byte]
    mov  [cs:int_ins+1], al

    mov  ax, [ss:Regs_off]
    mov  [ss:saved_off], ax
    mov  ax, [ss:Regs_seg]
    mov  [ss:saved_seg], ax

    les  di, [ss:Regs_off]
    mov  ax, [es:di + TRegisters._AX]
    mov  bx, [es:di + TRegisters._BX]
    mov  cx, [es:di + TRegisters._CX]
    mov  dx, [es:di + TRegisters._DX]
    mov  si, [es:di + TRegisters._SI]
    mov  di, [es:di + TRegisters._DI]

    push si
    push di
    mov  di, [ss:saved_off]
    mov  es, [ss:saved_seg]
    push word [es:di + TRegisters._Flags]
    popf
    push word [es:di + TRegisters._DS]
    push word [es:di + TRegisters._ES]
    pop  es
    pop  ds
    pop  di
    pop  si

    push bp
    ; Save SS:SP into CS-relative slots just before the INT.  Some calls —
    ; notably INT 21h / 4B00h Exec — may corrupt SS:SP across the call.
    ; Restore them immediately on return so `pop bp` (and every following
    ; stack ref) sees the original frame.  Save/restore through CS
    ; overrides so neither path depends on SS being valid.  CLI/STI
    ; bracket prevents an interrupt firing while SS and SP describe
    ; inconsistent stacks.
    mov  [cs:saved_ss], ss
    mov  [cs:saved_sp], sp
int_ins:
    int  0
    cli
    mov  ss, [cs:saved_ss]
    mov  sp, [cs:saved_sp]
    sti
    pop  bp

    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    pushf

    mov di, [ss:saved_off]
    mov es, [ss:saved_seg]
    mov bx, di

    pop word [es:bx + TRegisters._Flags]
    pop word [es:bx + TRegisters._ES]
    pop word [es:bx + TRegisters._DS]
    pop word [es:bx + TRegisters._DI]
    pop word [es:bx + TRegisters._SI]
    pop word [es:bx + TRegisters._DX]
    pop word [es:bx + TRegisters._CX]
    pop word [es:bx + TRegisters._BX]
    pop word [es:bx + TRegisters._AX]

    pop  di
    pop  si
    pop  es
    pop  ds
    %undef IntNo_byte
    %undef Regs_seg
    %undef Regs_off
    %undef saved_off
    %undef saved_seg
    add  sp, 4
    pop  bp
    RETMACRO 6

SYSTEM_CallFar:
    push bp
    mov  bp, sp
    sub  sp, 4
    %define ProcPtr_seg bp+RSIZE+8
    %define ProcPtr_off bp+RSIZE+6
    %define Regs_seg    bp+RSIZE+4
    %define Regs_off    bp+RSIZE+2
    %define saved_off   bp-2
    %define saved_seg   bp-4
    push ds
    push es
    push si
    push di

    mov  ax, [Regs_off]
    mov  [saved_off], ax
    mov  ax, [Regs_seg]
    mov  [saved_seg], ax

    les  di, [Regs_off]
    mov  ax, [es:di + TRegisters._AX]
    mov  bx, [es:di + TRegisters._BX]
    mov  cx, [es:di + TRegisters._CX]
    mov  dx, [es:di + TRegisters._DX]
    mov  si, [es:di + TRegisters._SI]
    mov  di, [es:di + TRegisters._DI]

    push si
    push di
    mov  di, [saved_off]
    mov  es, [saved_seg]
    push word [es:di + TRegisters._Flags]
    popf
    push word [es:di + TRegisters._DS]
    push word [es:di + TRegisters._ES]
    pop  es
    pop  ds
    pop  di
    pop  si

    push bp
    call far [ProcPtr_off]
    pop  bp

    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push ds
    push es
    pushf

    mov  di, [saved_off]
    mov  es, [saved_seg]
    mov  bx, di

    pop word [es:bx + TRegisters._Flags]
    pop word [es:bx + TRegisters._ES]
    pop word [es:bx + TRegisters._DS]
    pop word [es:bx + TRegisters._DI]
    pop word [es:bx + TRegisters._SI]
    pop word [es:bx + TRegisters._DX]
    pop word [es:bx + TRegisters._CX]
    pop word [es:bx + TRegisters._BX]
    pop word [es:bx + TRegisters._AX]

    pop  di
    pop  si
    pop  es
    pop  ds
    %undef ProcPtr_seg
    %undef ProcPtr_off
    %undef Regs_seg
    %undef Regs_off
    %undef saved_off
    %undef saved_seg
    add  sp, 4
    pop  bp
    RETMACRO 8

%define STATUS_BUSY 1
%define STATUS_FREE 0

struc MEMHEADER
    .Prev  resw 1
    .Next  resw 1
    .Size  resw 1
    .State resw 1
endstruc

MemStartSeg  dw 0

; -----------------------------------------------------------------------------
; Memory_Init
; Initializes the memory manager with a single large free block.
; Input:
;   Stack: [StartSegment (2 bytes)], [SizeInParas (2 bytes)]
;   Call Type: FAR
; Output:
;   None
; -----------------------------------------------------------------------------
MEM_INIT:
    %define arg_seg [ss:bp+RSIZE+4]
    %define arg_size [ss:bp+RSIZE+2]

    push bp
    mov  bp, sp
    push es

    mov  ax, arg_seg
    mov  bx, arg_size
    cmp  bx, 16
    jb   .ret
    mov  [cs:MemStartSeg], ax

    mov  es, ax
    xor  ax, ax
    mov  word [es:MEMHEADER.Prev], ax
    mov  word [es:MEMHEADER.Next], ax
    dec  bx
    mov  word [es:MEMHEADER.Size], bx
    mov  word [es:MEMHEADER.State], STATUS_FREE
.ret:
    pop  es
    %undef arg_seg
    %undef arg_size
    pop  bp
    RETMACRO 4

; -----------------------------------------------------------------------------
; SYSTEM_Alloc
; Allocates a memory block of the requested size.
; Input:
;   Stack: [SizeBytes (2 bytes)]
;   Call Type: FAR
; Output:
;   DX:AX - Pointer to the allocated memory (Seg:Ofs). 0:0 on failure.
; -----------------------------------------------------------------------------
SYSTEM_Alloc:
    %define arg_size [ss:bp+RSIZE+2]

    push bp
    mov  bp, sp
    push es
    push bx
    push cx
    push di
    push si

    mov cx, arg_size
    add cx, 15
    shr cx, 1
    shr cx, 1
    shr cx, 1
    shr cx, 1
    
    test cx, cx
    jnz .notfail1
    jmp .fail
.notfail1:
    mov ax, [cs:MemStartSeg]

.scan:
    test ax, ax
    jnz .notfail2
    jmp .fail
.notfail2:
    mov es, ax
    xor di, di

    cmp word [es:MEMHEADER.State], STATUS_FREE
    jne .next
    cmp word [es:MEMHEADER.Size], cx
    jb .next

    mov bx, [es:MEMHEADER.Size]
    mov si, cx
    inc si
    cmp bx, si
    jb .take_whole

    ; Split: allocated block stays at the START (segment ax),
    ; the free remainder goes to the END (segment bx).
    ; si = remainder size = bx(orig) - cx - 1
    mov si, bx
    sub si, cx
    dec si

    ; segment of the new free remainder block
    mov bx, ax
    inc bx
    add bx, cx

    ; old block at ax becomes the busy allocated block
    mov word [es:MEMHEADER.State], STATUS_BUSY
    mov word [es:MEMHEADER.Size], cx
    mov dx, [es:MEMHEADER.Next]      ; save old Next

    ; build the free remainder block at bx
    push es
    mov es, bx
    mov word [es:MEMHEADER.State], STATUS_FREE
    mov word [es:MEMHEADER.Size], si
    mov word [es:MEMHEADER.Prev], ax
    mov word [es:MEMHEADER.Next], dx
    pop es

    ; fix old Next's Prev to point at the remainder block
    test dx, dx
    jz .link
    push es
    mov es, dx
    mov word [es:MEMHEADER.Prev], bx
    pop es

.link:
    ; allocated block's Next points to the remainder block
    mov word [es:MEMHEADER.Next], bx

    ; return pointer to allocated payload = ax + 1
    mov dx, ax
    inc dx
    xor ax, ax
    jmp .ret

.take_whole:
    mov word [es:MEMHEADER.State], STATUS_BUSY
    
    mov dx, ax
    inc dx
    xor ax, ax
    jmp .ret

.next:
    mov ax, [es:MEMHEADER.Next]
    jmp .scan

.fail:
    xor dx, dx
    xor ax, ax

.ret:
    pop si
    pop di
    pop cx
    pop bx
    pop es
    %undef arg_size
    pop bp
    RETMACRO 2

; -----------------------------------------------------------------------------
; SYSTEM_Free
; Frees a previously allocated memory block and merges adjacent free blocks.
; Input:
;   Stack: [PtrSeg (2 bytes)], [PtrOfs (2 bytes)]
;   Call Type: FAR
; Output:
;   None
; -----------------------------------------------------------------------------
SYSTEM_Free:
    %define arg_seg [ss:bp+RSIZE+4]
    %define arg_ofs [ss:bp+RSIZE+2]

    push bp
    mov bp, sp
    push ds
    push es
    push ax
    push bx
    push cx
    push dx
    push si
    push di

    mov ax, arg_seg
    mov bx, arg_ofs
    
    mov cx, ax
    or cx, bx
    jnz .free_ret1
    jmp .free_ret
.free_ret1:
    dec ax
    mov es, ax
    xor di, di

    cmp word [es:MEMHEADER.State], STATUS_FREE
    jne .cont
    jmp .free_ret
.cont:
    mov word [es:MEMHEADER.State], STATUS_FREE

    mov dx, [es:MEMHEADER.Next]
    test dx, dx
    jz .free_prev
    
    push es
    mov es, dx
    cmp word [es:MEMHEADER.State], STATUS_FREE
    jne .free_next_skip
    
    mov cx, [es:MEMHEADER.Size]
    mov si, [es:MEMHEADER.Next]
    pop es
    
    inc word [es:MEMHEADER.Size]
    add word [es:MEMHEADER.Size], cx
    mov word [es:MEMHEADER.Next], si
    
    test si, si
    jz .free_prev
    push es
    mov es, si
    mov word [es:MEMHEADER.Prev], ax
    pop es
    jmp .free_prev

.free_next_skip:
    pop es

.free_prev:
    mov dx, [es:MEMHEADER.Prev]
    test dx, dx
    jz .free_ret

    push es
    mov es, dx
    cmp word [es:MEMHEADER.State], STATUS_FREE
    jne .free_prev_skip

    push es
    mov es, ax
    mov cx, [es:MEMHEADER.Size]
    mov si, [es:MEMHEADER.Next]
    pop es
    
    inc word [es:MEMHEADER.Size]
    add word [es:MEMHEADER.Size], cx
    mov word [es:MEMHEADER.Next], si
    
    test si, si
    jz .prev_done
    
    push es
    mov es, si
    mov word [es:MEMHEADER.Prev], dx
    pop es

.prev_done:
    pop es
    jmp .free_ret

.free_prev_skip:
    pop es

.free_ret:
    pop di
    pop si
    pop dx
    pop cx
    pop bx
    pop ax
    pop es
    pop ds
    %undef arg_seg
    %undef arg_ofs
    pop bp
    RETMACRO 4

; -----------------------------------------------------------------------------
; SYSTEM_MemAvail
; Returns the total amount of free heap memory, in paragraphs (16-byte units),
; as the sum of the Size fields of all STATUS_FREE blocks in the free list.
; Input:  none.   Call Type: FAR.   Output: AX = free paragraphs.
; -----------------------------------------------------------------------------
SYSTEM_MemAvail:
    push es
    push bx
    push dx
    xor  dx, dx                 ; dx = running total (paragraphs)
    mov  ax, [cs:MemStartSeg]
.ma_scan:
    test ax, ax
    jz   .ma_done
    mov  es, ax
    cmp  word [es:MEMHEADER.State], STATUS_FREE
    jne  .ma_next
    add  dx, [es:MEMHEADER.Size]
.ma_next:
    mov  ax, [es:MEMHEADER.Next]
    jmp  .ma_scan
.ma_done:
    mov  ax, dx
    pop  dx
    pop  bx
    pop  es
    RETMACRO 0

; -----------------------------------------------------------------------------
; SYSTEM_MemMaxAvail
; Returns the size of the largest single free block, in paragraphs.
; Input:  none.   Call Type: FAR.   Output: AX = largest free block paragraphs.
; -----------------------------------------------------------------------------
SYSTEM_MemMaxAvail:
    push es
    push bx
    push dx
    xor  dx, dx                 ; dx = max so far (paragraphs)
    mov  ax, [cs:MemStartSeg]
.mm_scan:
    test ax, ax
    jz   .mm_done
    mov  es, ax
    cmp  word [es:MEMHEADER.State], STATUS_FREE
    jne  .mm_next
    mov  bx, [es:MEMHEADER.Size]
    cmp  bx, dx
    jbe  .mm_next
    mov  dx, bx
.mm_next:
    mov  ax, [es:MEMHEADER.Next]
    jmp  .mm_scan
.mm_done:
    mov  ax, dx
    pop  dx
    pop  bx
    pop  es
    RETMACRO 0

SYSTEM_S32DIV:
    push bp
    mov bp, sp
    %define a_high bp+RSIZE+8
    %define a_low  bp+RSIZE+6
    %define b_high bp+RSIZE+4
    %define b_low  bp+RSIZE+2
    push bx
    push cx
    push si
    push di
    mov dx, [a_high]
    mov ax, [a_low]
    mov cx, [b_high]
    mov bx, [b_low]
    xor si, si
    test dx, dx
    jns .check_b
    not dx
    not ax
    add ax, 1
    adc dx, 0
    not si
.check_b:
    test cx, cx
    jns .do_div
    not cx
    not bx
    add bx, 1
    adc cx, 0
    not si
.do_div:
    call div_kernel_32
    test si, si
    jz .end
    not dx
    not ax
    add ax, 1
    adc dx, 0
.end:
    pop di
    pop si
    pop cx
    pop bx
    %undef a_high
    %undef a_low
    %undef b_high
    %undef b_low
    pop bp
    RETMACRO 8


SYSTEM_S32MOD:
    push bp
    mov bp, sp
    %define a_high bp+RSIZE+8
    %define a_low  bp+RSIZE+6
    %define b_high bp+RSIZE+4
    %define b_low  bp+RSIZE+2
    push bx
    push cx
    push si
    push di
    mov dx, [a_high]
    mov ax, [a_low]
    mov cx, [b_high]
    mov bx, [b_low]
    xor si, si
    test dx, dx
    jns .check_b
    mov si, 1
    not dx
    not ax
    add ax, 1
    adc dx, 0
.check_b:
    test cx, cx
    jns .do_div
    not cx
    not bx
    add bx, 1
    adc cx, 0
.do_div:
    call div_kernel_32
    mov dx, cx
    mov ax, bx
    test si, si
    jz .end
    not dx
    not ax
    add ax, 1
    adc dx, 0
.end:
    pop di
    pop si
    pop cx
    pop bx
    %undef a_high
    %undef a_low
    %undef b_high
    %undef b_low
    pop bp
    RETMACRO 8

div_kernel_32:
    push bp
    push si
    push di
    
    mov si, cx
    or si, bx
    jz .div_by_zero

    mov si, cx
    mov di, bx
    xor cx, cx
    xor bx, bx
    mov bp, 32

.div_loop:
    shl ax, 1
    rcl dx, 1
    rcl bx, 1
    rcl cx, 1
    
    cmp cx, si
    jb .next_bit
    ja .sub_div
    cmp bx, di
    jb .next_bit

.sub_div:
    sub bx, di
    sbb cx, si
    inc ax 

.next_bit:
    dec bp
    jnz .div_loop
    jmp .done

.div_by_zero:
    mov dx, 0FFFFh
    mov ax, 0FFFFh
    mov cx, dx
    mov bx, ax

.done:
    pop di
    pop si
    pop bp
    ret

SYSTEM_S32MUL:
    push bp
    mov bp, sp
    %define a_high bp+RSIZE+8
    %define a_low  bp+RSIZE+6
    %define b_high bp+RSIZE+4
    %define b_low  bp+RSIZE+2
    push si
    push di
    sub sp, 6

    mov dx, [a_high]
    mov ax, [a_low]
    mov cx, [b_high]
    mov bx, [b_low]

    xor si, si
    test dx, 0x8000
    jz .chk_y
    mov si, 1
    not dx
    not ax
    add ax, 1
    adc dx, 0
.chk_y:
    test cx, 0x8000
    jz .save_abs
    xor si, 1
    not cx
    not bx
    add bx, 1
    adc cx, 0
.save_abs:
    mov [bp-8], bx
    mov [bp-10], cx
    mov [bp-6], si

    mov si, ax
    mov di, dx

    mov ax, si
    mul word [bp-8]
    mov bx, ax
    push dx

    mov ax, si
    mul word [bp-10]
    pop cx
    add cx, ax
    push cx

    mov ax, di
    mul word [bp-8]
    pop cx
    add cx, ax

    mov ax, bx
    mov dx, cx

    mov si, [bp-6]
    test si, 1
    jz .done
    not dx
    not ax
    add ax, 1
    adc dx, 0
.done:
    add sp, 6
    pop di
    pop si
    %undef a_high
    %undef a_low
    %undef b_high
    %undef b_low
    pop bp
    RETMACRO 8
