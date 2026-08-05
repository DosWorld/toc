bits 16
cpu 8086
%define IS_FAR

section .data
i87:      dw 0
isDpmi:   dw 0
ExitProc: dw 0, 0
seg0040:  dw 00040h
segb000:  dw 0b000h
segb800:  dw 0b800h
sega000:  dw 0a000h
segpsp:   dw 0
err_code: db 0

i87msg:
    db 'Numeric coprecessor required.$'
nomemmsg:
    db 'Not enough memory.$'

; Net paragraphs currently outstanding via DPMI_Alloc/DPMI_Free.  DPMI's
; INT 31h/0500h "Get Free Memory Information" reports HOST-WIDE free memory,
; not this process's own heap, so LeakGuard's deterministic before/after
; MemAvail() diff (valid in real mode, which walks a process-private
; free-list) produced spurious "leaks" under DPMI from host-side memory
; drift unrelated to this process.  DPMI_MemAvail/DPMI_MemMaxAvail report
; against this process-local counter instead of querying the host.
dpmiAllocParas: dw 0

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
global SYSTEM_SetExitProc, SYSTEM_GetExitProc
global SYSTEM_Seg0040, SYSTEM_SegB000, SYSTEM_SegB800, SYSTEM_SegA000, SYSTEM_PrefixSeg
global SYSTEM_IsDPMI, SYSTEM_DPMI_INIT
global SYSTEM_DpmiMapDosSeg, SYSTEM_DpmiUnmapDosSeg

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

SYSTEM_REQUIRE87:
        ; FAR-called from any module's __init (via SYSTEM_REQUIRE87 import) —
        ; the caller's DS is now THEIR OWN data segment (one module = one
        ; data segment), not SYSTEM's, so [i87] must be read through
        ; SYSTEM's own DS, saved/restored around the check like
        ; SYSTEM_GetExitProc/SYSTEM_SetExitProc already do.
        push ds
        mov  ax, seg i87
        mov  ds, ax
        cmp  BYTE[i87], 0
        pop  ds
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
        mov  ax, seg err_code
        mov  ds, ax
        mov  al, BYTE[ss:bx+4]
        mov  BYTE[err_code], AL
        jmp  SYSTEM_DONE

ErrWithMsg:
        mov  bx, seg err_code
        mov  ds, bx
        mov  BYTE[err_code], al
        mov  ah, 9
        int  21h
        jmp  SYSTEM_DONE

SYSTEM_IsDPMI:
        mov  ax, seg isDpmi
        mov  es, ax
        mov  ax,[es:isDpmi]
        retf

common_init:
        mov  ax, seg i87
        mov  ds, ax
        mov  es, ax
        call check_8087
        xor  ah, ah
        mov  [i87], ax
        mov  ah, 62h
        int  21h
        mov  [segpsp], bx
        xor  ax, ax
        mov  [isDpmi], ax
        retn

%macro MAP_DOS_SEG 1
        mov  ax, [%1]
        push ax
        push cs
        call SYSTEM_DpmiMapDosSeg
        mov  [%1], ax
%endmacro

%macro UNMAP_DOS_SEG 1
        mov  ax, [%1]
        push ax
        push cs
        call SYSTEM_DpmiUnmapDosSeg
%endmacro

SYSTEM_DPMI_INIT:
        call common_init
        inc  word[isDpmi]

        MAP_DOS_SEG seg0040
        MAP_DOS_SEG segb000
        MAP_DOS_SEG segb800
        MAP_DOS_SEG sega000
        push ds
        pop  ds
        retf

SYSTEM_INIT:
        push ax
        push bx
        call common_init
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

dos_done:
        push es
        mov  ax, [cs:MemStartSeg]
        mov  es, ax
        mov  ah, 49h
        int  21h
        pop  es
        retn

dpmi_done:
        push ds
        mov  ax, [segpsp]
        mov  ds, ax
        pop  ds
        UNMAP_DOS_SEG seg0040
        UNMAP_DOS_SEG segb000
        UNMAP_DOS_SEG segb800
        UNMAP_DOS_SEG sega000
        retn

SYSTEM_DONE:
        call RunExitProcChain

        mov  ax, seg isDpmi
        mov  es, ax
        mov  ds, ax
        mov  ax, [es:isDpmi]
        or   ax, ax
        jnz  .dpmi
        call dos_done
        jmp  .cont
.dpmi:
        call dpmi_done
.cont:
        mov  al, [err_code]
        mov  ah, 4Ch
        int  21h

SYSTEM_SetExitProc:
        ; FAR proc, no prologue.  Param (ADDRESS, 4 bytes) was pushed by the
        ; caller before CALL FAR, which then pushed CS:IP (2 words, RSIZE=4).
        ; Stack: [SP+0]=ret IP [SP+2]=ret CS [SP+4]=proc_ofs [SP+6]=proc_seg
        push bp
        mov  bp, sp
        push ds
        push ax
        mov  ax, seg ExitProc
        mov  ds, ax
        mov  ax, [bp+RSIZE+2]
        mov  [ExitProc], ax
        mov  ax, [bp+RSIZE+4]
        mov  [ExitProc+2], ax
        pop  ax
        pop  ds
        pop  bp
        retf 4

SYSTEM_GetExitProc:
        push ds
        mov  ax, seg ExitProc
        mov  ds, ax
        mov  ax, [ExitProc]
        mov  dx, [ExitProc+2]
        pop  ds
        retf

RunExitProcChain:
        mov  ax, seg ExitProc
        mov  ds, ax
        mov  bx, ExitProc
.cont:
        mov  ax, [bx]
        mov  dx, [bx+2]
        or   ax, dx
        jz   .end
        push ds
        push bx
        call far [bx]
        pop  bx
        pop  ds
        jmp  .cont
.end:
        retn
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

MemStartSeg:
        dw 0

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
        mov  ax, seg isDpmi
        mov  es, ax
        mov  ax, [es:isDpmi]
        or   ax, ax
        jz   .cont
        jmp  DPMI_Alloc
.cont:
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
        mov  ax, seg isDpmi
        mov  es, ax
        mov  ax, [es:isDpmi]
        or   ax, ax
        jz   .cont
        jmp  DPMI_Free
.cont:
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
        jne .cont22
        jmp .free_ret
.cont22:
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
        mov  ax, seg isDpmi
        mov  es, ax
        mov  ax, [es:isDpmi]
        or   ax, ax
        jz   .cont
        jmp  DPMI_MemAvail
.cont:
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
        mov  ax, seg isDpmi
        mov  es, ax
        mov  ax, [es:isDpmi]
        or   ax, ax
        jz   .cont
        jmp  DPMI_MemMaxAvail
.cont:
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

; Oberon-07 DIV/MOD are floored (quotient rounds toward -infinity, remainder
; takes the divisor's sign), not the div_kernel_32/8086 IDIV truncating
; convention (quotient rounds toward zero, remainder takes the dividend's
; sign).  di tracks "a (dividend) was negative", si tracks "b (divisor) was
; negative" (each 0 or 1, independently -- NOT xored together as the old
; truncating version did).  After the unsigned kernel call, dx:ax holds the
; truncating |quotient| and cx:bx the truncating |remainder|.  Truncating and
; floored results agree whenever the remainder is 0 or the two operand signs
; match; otherwise floored_quotient = truncating_quotient - 1 and
; floored_remainder = truncating_remainder_signed + b.
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
        xor di, di
        xor si, si
        test dx, dx
        jns .check_b
        mov di, 1
        not dx
        not ax
        add ax, 1
        adc dx, 0
.check_b:
        test cx, cx
        jns .do_div
        mov si, 1
        not cx
        not bx
        add bx, 1
        adc cx, 0
.do_div:
        push di
        push si
        call div_kernel_32          ; dx:ax = |quotient|, cx:bx = |remainder|
        pop si
        pop di
        cmp di, si
        je .same_sign               ; same sign (or a==0): truncating == floored
        not dx
        not ax
        add ax, 1
        adc dx, 0                   ; dx:ax = -|quotient| (truncating quotient)
        mov si, cx
        or si, bx
        jz .end                     ; remainder == 0: no floored fixup needed
        sub ax, 1
        sbb dx, 0                   ; floored quotient = truncating quotient - 1
        jmp .end
.same_sign:
        ; a and b have the same sign (both >=0 or both negative): the quotient of
        ; two same-signed values is always non-negative, and div_kernel_32 was
        ; called on the two magnitudes, so dx:ax already holds the correct
        ; positive quotient -- no negation needed either way.
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
        xor di, di
        xor si, si
        mov dx, [a_high]
        mov ax, [a_low]
        mov cx, [b_high]
        mov bx, [b_low]
        test dx, dx
        jns .check_b
        mov di, 1
        not dx
        not ax
        add ax, 1
        adc dx, 0
.check_b:
        test cx, cx
        jns .do_div
        mov si, 1
        not cx
        not bx
        add bx, 1
        adc cx, 0
.do_div:
        push di
        push si
        call div_kernel_32          ; cx:bx = |remainder| (unsigned kernel output)
        pop si
        pop di
        mov dx, cx
        mov ax, bx                  ; dx:ax = |remainder|
        test di, di
        jz .have_mag                ; a >= 0: truncating remainder is +|remainder|
        not dx
        not ax
        add ax, 1
        adc dx, 0                   ; a < 0: truncating remainder is -|remainder|
.have_mag:
        ; dx:ax = truncating remainder (dividend's sign, 0 if exact).
        cmp di, si
        je .end                     ; same sign or remainder 0-safe: no fixup
        mov cx, dx
        mov bx, ax
        or cx, bx
        jz .end                     ; remainder == 0: floored == truncating
        mov cx, [b_high]
        mov bx, [b_low]
        add ax, bx
        adc dx, cx                  ; floored remainder = truncating remainder + b
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
        mov ax, dx
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

SYSTEM_Seg0040:
        mov  ax, seg seg0040
        mov  es, ax
        mov  ax, [es:seg0040]
        RETMACRO

SYSTEM_SegB000:
        mov  ax, seg segb000
        mov  es, ax
        mov  ax, [es:segb000]
        RETMACRO

SYSTEM_SegB800:
        mov  ax, seg segb800
        mov  es, ax
        mov  ax, [es:segb800]
        RETMACRO

SYSTEM_SegA000:
        mov  ax, seg sega000
        mov  es, ax
        mov  ax, [es:sega000]
        RETMACRO

SYSTEM_PrefixSeg:
        mov  ax, seg segpsp
        mov  es, ax
        mov  ax, [es:segpsp]
        RETMACRO

; -----------------------------------------------------------------------------
; DPMI_Alloc
; DPMI-mode backend for SYSTEM_Alloc.  Allocates a linear memory block via
; DPMI 0501h and wraps it in a fresh LDT descriptor (16-bit R/W data, ring 3),
; selector base = block base + 4.  The 32-bit block handle needed by 0502h
; (free) is stashed in the 4 hidden bytes just below the selector's base, via
; a throwaway scratch descriptor, and is never visible through the returned
; selector itself.
; Input:  Stack: [SizeBytes (2 bytes)] (same frame SYSTEM_Alloc was entered
;         with -- DPMI_Alloc is reached by a plain jmp, so bp/sp/args are
;         exactly as the caller pushed them for a FAR call.)
; Output: DX:AX = Seg:Ofs pointer (selector:0) to the block, or 0:0 on error.
; -----------------------------------------------------------------------------
DPMI_Alloc:
        %define a_size ss:bp+RSIZE+2
        push bp
        mov  bp, sp
        push es

        mov  cx, [a_size]
        test cx, cx
        jnz  .da_sizeok1
        jmp  .da_fail
.da_sizeok1:
        xor  bx, bx
        add  cx, 4
        adc  bx, 0
        mov  ax, 0501h
        int  31h
        jnc  .da_gotmem
        jmp  .da_fail
.da_gotmem:
        push bx
        push cx
        push si
        push di

        xor  ax, ax
        mov  cx, 1
        int  31h
        jnc  .da_gotdesc1
        jmp  .da_err_free_mem
.da_gotdesc1:
        mov  bx, ax

        mov  dx, [bp-6]
        mov  cx, [bp-4]
        add  dx, 4
        adc  cx, 0
        mov  ax, 0007h
        int  31h
        jnc  .da_setbase_ok
        jmp  .da_err_free_desc
.da_setbase_ok:

        mov  dx, [a_size]
        dec  dx
        xor  cx, cx
        mov  ax, 0008h
        int  31h
        jnc  .da_setlimit_ok
        jmp  .da_err_free_desc
.da_setlimit_ok:

        mov  cx, 0F2h
        mov  ax, 0009h
        int  31h
        jnc  .da_setrights_ok
        jmp  .da_err_free_desc
.da_setrights_ok:

        push bx

        xor  ax, ax
        mov  cx, 1
        int  31h
        jnc  .da_scratchdesc_ok
        jmp  .da_step6_fail_pop
.da_scratchdesc_ok:
        mov  bx, ax

        mov  dx, [bp-6]
        mov  cx, [bp-4]
        mov  ax, 0007h
        int  31h
        jnc  .da_scratchbase_ok
        jmp  .da_step6_fail_scratch
.da_scratchbase_ok:

        xor  cx, cx
        mov  dx, 3
        mov  ax, 0008h
        int  31h
        jnc  .da_scratchlimit_ok
        jmp  .da_step6_fail_scratch
.da_scratchlimit_ok:

        mov  cx, 0F2h
        mov  ax, 0009h
        int  31h
        jnc  .da_scratchrights_ok
        jmp  .da_step6_fail_scratch
.da_scratchrights_ok:

        push ds
        mov  ds, bx
        mov  ax, [bp-10]
        mov  [0], ax
        mov  ax, [bp-8]
        mov  [2], ax
        pop  ds

        mov  cx, 1
        mov  ax, 0001h
        int  31h

        pop  bx

        add  sp, 8

        ; Track this block's paragraph size in dpmiAllocParas (see .data
        ; comment) so DPMI_MemAvail can report a deterministic, process-
        ; local figure instead of querying host-wide free memory.
        push ax
        push cx
        push dx
        push ds
        mov  cx, [a_size]
        add  cx, 15
        shr  cx, 1
        shr  cx, 1
        shr  cx, 1
        shr  cx, 1           ; cx = paragraphs, rounded up (8086-safe: 4x SHR 1)
        mov  ax, seg dpmiAllocParas
        mov  ds, ax
        add  [dpmiAllocParas], cx
        pop  ds
        pop  dx
        pop  cx
        pop  ax

        mov  dx, bx
        xor  ax, ax
        jmp  .da_exit

.da_step6_fail_scratch:
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        jmp  .da_step6_restore
.da_step6_fail_pop:
.da_step6_restore:
        pop  bx
        jmp  .da_err_free_desc

.da_err_free_desc:
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        jmp  .da_err_free_mem_onstk
.da_err_free_mem:
.da_err_free_mem_onstk:
        pop  di
        pop  si
        add  sp, 4
        mov  ax, 0502h
        int  31h

.da_fail:
        xor  dx, dx
        xor  ax, ax

.da_exit:
        pop  es
        %undef a_size
        pop  bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; DPMI_get_hidden_handle  (module-internal, NEAR)
; Reads the 32-bit memory-block handle from the hidden 4-byte prefix living
; immediately before the given selector's base, via a throwaway scratch
; descriptor.  The caller's selector (BX) is left untouched -- BX is
; caller-supplied input only; the scratch descriptor is tracked separately
; (in DI, unused by DPMI 0006h/0007h/0008h/0009h/0001h's BX-selector
; argument convention) so the original BX survives across the whole call,
; and callers (e.g. DPMI_Free) can still free BX's selector afterward.
; Input:  BX = selector whose hidden handle to fetch
; Output: SI:DI = handle (high:low); BX unchanged; CF = 1 on any DPMI error
; -----------------------------------------------------------------------------
DPMI_get_hidden_handle:
        mov  ax, 0006h
        int  31h
        jnc  .hh_gotbase
        stc
        ret
.hh_gotbase:
        sub  dx, 4
        sbb  cx, 0
        push cx
        push dx

        xor  ax, ax
        mov  cx, 1
        int  31h
        jnc  .hh_gotscratch
        add  sp, 4
        stc
        ret
.hh_gotscratch:
        mov  es, ax
        xchg ax, bx         ; ax = caller's original selector, bx = scratch selector
        pop  dx
        pop  cx
        push ax             ; stash caller's selector across the DPMI calls below
        mov  ax, 0007h
        int  31h
        jnc  .hh_setbase_ok
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        pop  ax
        mov  bx, ax
        stc
        ret
.hh_setbase_ok:
        xor  cx, cx
        mov  dx, 3
        mov  ax, 0008h
        int  31h
        jnc  .hh_setlimit_ok
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        pop  ax
        mov  bx, ax
        stc
        ret
.hh_setlimit_ok:
        mov  cx, 0F2h           ; P=1 DPL=3 S=1 data R/W -- matches DPMI_Alloc's
                                 ; own rights byte (SYSTEM.ASM:1232,1265).  The
                                 ; previous 0092h (DPL=0/ring-0) was silently
                                 ; tolerated by some DPMI hosts/emulators but
                                 ; rejected by real DPMI16 hardware (DPMI 0009h
                                 ; fails), leaving DPMI_get_hidden_handle unable
                                 ; to read the hidden handle and DPMI_Free
                                 ; unable to free the block at all -- root
                                 ; cause of a full per-block DPMI16 heap leak
                                 ; (confirmed via SYSTEM.MemAvail() round-trip
                                 ; on real hardware).
        mov  ax, 0009h
        int  31h
        jnc  .hh_setrights_ok
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        pop  ax
        mov  bx, ax
        stc
        ret
.hh_setrights_ok:
        mov  di, [es:0]
        mov  si, [es:2]
        mov  cx, 1
        mov  ax, 0001h
        int  31h
        pop  ax
        mov  bx, ax
        clc
        ret

DPMI_Free:
        %define a_ofs ss:bp+6
        %define a_seg ss:bp+8

        push bp
        mov  bp, sp

        mov  bx, [a_seg]
        mov  ax, [a_ofs]
        or   ax, bx
        jnz  .df_notnil
        jmp  .df_ret          ; NIL: nothing to free (far jump: .df_ret is
                               ; out of short/rel8 range from here)
.df_notnil:

        call DPMI_get_hidden_handle
        jnc  .df_hhok
        jmp  .df_ret          ; far jump, same reason as above
.df_hhok:

        ; Read this block's byte limit BEFORE freeing its descriptor, so
        ; dpmiAllocParas can be decremented by the same paragraph count
        ; DPMI_Alloc added -- keeps SYSTEM.MemAvail() deterministic under
        ; DPMI (see .data comment on dpmiAllocParas).
        ;
        ; NOTE: there is no INT 31h service that returns a selector's limit.
        ; AX=0003h is "Get Next Selector Increment Value" (takes no selector
        ; input at all, always succeeds, returns an unrelated power-of-two
        ; in AX) -- a prior version of this code mistakenly called that
        ; thinking it was "Get Segment Limit", which doesn't exist as a
        ; DPMI service; it silently returned a bogus near-zero limit,
        ; making DPMI_Free decrement dpmiAllocParas by ~1 paragraph instead
        ; of the true block size on every free (DOCS/DPMI09.HTM section 8.8
        ; explicitly says to use the LSL instruction instead).  Use LSL
        ; DX,BX (0Fh,03h,0D3h -- TASM only assembles 8086, so this is raw
        ; bytes) -- an 80286+ instruction, always available here since DPMI
        ; requires at least an 80286.  LSL sets DX = the selector's limit
        ; and ZF=1 if BX is a valid, accessible descriptor; ZF=0 (skip via
        ; JNZ) on an invalid selector, in which case DX is undefined and
        ; must not be used.
        push ax
        push cx
        push dx
        db 0Fh, 03h, 0D3h        ; LSL DX, BX
        jnz  .df_lslfail         ; ZF=0 -> BX was not a valid/accessible
                                  ; selector; treat limit as unknown (0)
        inc  dx
        jnz  .df_szok
        inc  cx
        jmp  .df_szok
.df_lslfail:
        xor  dx, dx
        xor  cx, cx
.df_szok:
        add  dx, 15
        adc  cx, 0
        shr  dx, 1
        rcr  cx, 1
        shr  dx, 1
        rcr  cx, 1
        shr  dx, 1
        rcr  cx, 1
        shr  dx, 1
        rcr  cx, 1           ; dx = paragraphs (low 16 bits; cx expected 0 --
                              ; every DPMI_Alloc request is well under 64K,
                              ; see Rdoff.SegLimit)
        push ds
        push ax
        mov  ax, seg dpmiAllocParas
        mov  ds, ax
        sub  [dpmiAllocParas], dx
        pop  ax
        pop  ds
        pop  dx
        pop  cx
        pop  ax

        mov  cx, 1
        mov  ax, 0001h
        int  31h

        mov  ax, 0502h
        int  31h

.df_ret:
        %undef a_ofs
        %undef a_seg
        pop  bp
        RETMACRO 4

; -----------------------------------------------------------------------------
; DPMI_MemAvail
; DPMI-mode backend for SYSTEM_MemAvail.  Reports a deterministic,
; process-local figure (0FFFFh minus dpmiAllocParas, the running total of
; paragraphs outstanding via DPMI_Alloc/DPMI_Free) instead of querying the
; DPMI host's system-wide free memory (INT 31h/0500h) -- that call reflects
; host-wide/other-client memory pressure unrelated to this process's own
; allocations, which made LeakGuard's deterministic before/after diff (sound
; in real mode, which walks a process-private free-list) report spurious
; leaks under DPMI purely from host-side memory drift.  See the
; dpmiAllocParas .data comment.
; Input:  none.   Output: AX = 0FFFFh - dpmiAllocParas.
; -----------------------------------------------------------------------------
DPMI_MemAvail:
        push ds
        mov  ax, seg dpmiAllocParas
        mov  ds, ax
        mov  ax, 0FFFFh
        sub  ax, [dpmiAllocParas]
        pop  ds
        RETMACRO 0

; -----------------------------------------------------------------------------
; DPMI_MemMaxAvail
; DPMI-mode backend for SYSTEM_MemMaxAvail.  Same process-local figure as
; DPMI_MemAvail -- there is no distinct "largest free block" concept for a
; single running counter (unlike the real-mode free-list, which can be
; fragmented).  See DPMI_MemAvail above.
; Input:  none.   Output: AX = 0FFFFh - dpmiAllocParas.
; -----------------------------------------------------------------------------
DPMI_MemMaxAvail:
        push ds
        mov  ax, seg dpmiAllocParas
        mov  ds, ax
        mov  ax, 0FFFFh
        sub  ax, [dpmiAllocParas]
        pop  ds
        RETMACRO 0

; -----------------------------------------------------------------------------
; SYSTEM_DpmiMapDosSeg
; Maps a real-mode DOS segment into a fresh LDT descriptor for protected-mode
; access: base = dosseg*16 (linear), limit = 64KB, 16-bit R/W data, ring 3.
; Only meaningful when running under DPMI (SYSTEM.IsDPMI() = TRUE); the
; returned selector cannot be loaded into CS (data descriptors are never
; executable -- see DpmiMapDosSeg's doc comment in SYSTEM.MOD).
; Input:  Stack: [DosSeg (2 bytes)].   Call Type: FAR.
; Output: AX = scratch selector, or 0 on any DPMI error.
; -----------------------------------------------------------------------------
SYSTEM_DpmiMapDosSeg:
        %define a_dosseg [ss:bp+RSIZE+2]

        push bp
        mov  bp, sp

        mov  bx, a_dosseg
        mov  ax, 0002h
        int  31h
        jnc  .dm_exit
        xor  ax, ax
.dm_exit:
        %undef a_dosseg
        pop  bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; SYSTEM_DpmiUnmapDosSeg
; Releases a selector previously returned by SYSTEM_DpmiMapDosSeg (frees its
; LDT descriptor via DPMI 0001h).
; Input:  Stack: [ScrSelector (2 bytes)].   Call Type: FAR.
; Output: none.
; -----------------------------------------------------------------------------
SYSTEM_DpmiUnmapDosSeg:
        %define a_sel [ss:bp+RSIZE+2]

        push bp
        mov  bp, sp
        push ax
        push bx

        mov  bx, a_sel
        mov  ax, 0001h
        int  31h

        pop  bx
        pop  ax
        %undef a_sel
        pop  bp
        RETMACRO 2
