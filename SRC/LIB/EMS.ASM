bits 16
cpu 8086
%define IS_FAR

section .data
driverPresent:
    db 0
pageFrameObtained:
    db 0
pageFrameSeg:
    dw 0
errorCode:
    dw 0
moveDesc:
    times 18 db 0                       ; static TMoveDesc scratch buffer,
                                         ; shared by EMS_CopyToEMS/CopyToDos
                                         ; (never called re-entrantly) --
                                         ; avoids per-call stack-frame
                                         ; arithmetic and the SS-vs-CS
                                         ; DS:SI addressing subtlety.

section .text

%ifdef IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

%define PageSize 16384
%define PageShift 14
%define MaxPhysicalPages 4

; move_source_dest_struct, per LIM EMS 4.0 spec -- matches EMS.MOD's old
; MoveDesc RECORD (*$A-*) field-for-field:
;   len:LONGINT, srcType:BYTE, srcHandle:WORD, src:LONGINT,
;   dstType:BYTE, dstHandle:WORD, dst:LONGINT  (18 bytes total).
; Each Longint field's low word is the far-pointer offset (conventional
; memory) or the in-page byte offset (EMS memory); the high word is the
; segment (conventional) or the logical page number (EMS) -- NOT a raw
; byte offset, per the spec.
struc TMoveDesc
    .len        resd 1
    .srcType    resb 1
    .srcHandle  resw 1
    .srcOfs     resw 1
    .srcSeg     resw 1
    .dstType    resb 1
    .dstHandle  resw 1
    .dstOfs     resw 1
    .dstSeg     resw 1
endstruc

; This is the full LIM EMS 4.0 page-frame driver implementation for EMS.MOD:
; every procedure EMS.MOD used to implement in Oberon (KB->pages rounding,
; MoveDesc struct packing, page-frame pointer arithmetic, the
; driverPresent/pageFrameObtained/pageFrameSeg/errorCode module state) now
; lives here, in the same style as SYSTEM.MOD/SYS.ASM: EMS.MOD is reduced to
; bare `PROCEDURE ...; EXTERNAL;` declarations with no logic of their own.
; Global symbol names follow the compiler's EXTERNAL-import rule:
; "<MODULE>_<ProcName>" (Parser.MOD ParseProcDecl's EXTERNAL branch), so
; every label below is EMS_<ProcName> to match EMS.MOD's declarations.
;
; PageSize (16384 = 2^14) divides/mods are done with a shift/mask (PageShift)
; instead of a general 32-bit divide kernel -- both operands of every
; DIV/MOD on an EMS offset in this file are powers of two.  (A general
; 32-bit divide kernel already exists as SYS.ASM's SYSTEM_S32DIV/S32MOD, but
; it is not reachable from here: separate $L .rdf blobs are appended into
; the .om archive as opaque data, not symbol-resolved against each other,
; so EMS.RDF cannot call into SYS.RDF.)  Every routine below saves/
; restores DS around its own access to the module's .data state
; (driverPresent/pageFrameObtained/pageFrameSeg/errorCode/moveDesc), loading
; DS via `mov ax, seg driverPresent` -- the same idiom SYS.ASM uses for its
; own .data (`mov ax, seg i87` / `mov ax, seg ExitProc`) -- since a FAR
; proc's DS on entry is the caller's data segment, not necessarily this
; module's, and .data is a segment distinct from .text in this model.

global EMS_Detect, EMS_Present, EMS_GetError
global EMS_Alloc, EMS_Free, EMS_Realloc
global EMS_CopyToEMS, EMS_CopyToDos
global EMS_Version, EMS_RequireVersion
global EMS_MapPage, EMS_UnmapPage, EMS_MapPtr

; -----------------------------------------------------------------------------
; EMS_Detect()
; Probes INT 67h presence via the INT 21h/AH=35h vector-get + "EMMXXXX0"
; device-header signature check (LIM EMS spec), then AH=41h (get page frame
; segment).  Sets driverPresent/pageFrameObtained/pageFrameSeg.  Called once
; from EMS.MOD's module BEGIN block.
; Call Type: FAR, no params, no return value.
; -----------------------------------------------------------------------------
EMS_Detect:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es

        mov     ax, seg driverPresent
        mov     ds, ax
        mov     byte [driverPresent], 0
        mov     byte [pageFrameObtained], 0
        mov     word [pageFrameSeg], 0
        mov     word [errorCode], 0

        mov     ax, 3567h
        int     21h                     ; ES:BX = INT 67h vector

        mov     di, 0Ah
        cmp     byte [es:di+0], 'E'
        jne     .absent
        cmp     byte [es:di+1], 'M'
        jne     .absent
        cmp     byte [es:di+2], 'M'
        jne     .absent
        cmp     byte [es:di+3], 'X'
        jne     .absent
        cmp     byte [es:di+4], 'X'
        jne     .absent
        cmp     byte [es:di+5], 'X'
        jne     .absent
        cmp     byte [es:di+6], 'X'
        jne     .absent
        cmp     byte [es:di+7], '0'
        jne     .absent

        mov     byte [driverPresent], 1

        mov     ax, 4100h
        int     67h
        or      ah, ah
        jnz     .absent
        mov     word [pageFrameSeg], bx
        mov     byte [pageFrameObtained], 1

.absent:
        pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        RETMACRO 0

; -----------------------------------------------------------------------------
; EMS_Present(): BOOLEAN
; Call Type: FAR, no params.  Output: AX = 0/1.
; -----------------------------------------------------------------------------
EMS_Present:
        push    ds
        mov     ax, seg driverPresent
        mov     ds, ax
        xor     ah, ah
        mov     al, [driverPresent]
        pop     ds
        RETMACRO 0

; -----------------------------------------------------------------------------
; EMS_GetError(): WORD
; Call Type: FAR, no params.  Output: AX = last error code.
; -----------------------------------------------------------------------------
EMS_GetError:
        push    ds
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     ax, [errorCode]
        pop     ds
        RETMACRO 0

; -----------------------------------------------------------------------------
; EMS_Alloc(sizeKB: WORD; VAR handle: WORD): BOOLEAN
; Rounds sizeKB up to 16 KB pages (0 KB -> 1 page, same as the original
; Oberon `WORD((LONGINT(sizeKB)+15) DIV 16)` -- sizeKB fits in WORD, and
; sizeKB+15 cannot overflow 16 bits for any sizeKB a caller could sensibly
; pass here (EMS handles top out at 8 MB = 8192 KB), so the +15 add before
; the >>4 is safe without widening to 32 bits), gates on driverPresent, then
; AH=43h (Allocate Pages): BX=pages in, DX=handle out.
; Output: AX = 0/1 (BOOLEAN); handle is written only on success; errorCode
; updated always.
; Stack (POP order): handle_seg, handle_ofs, sizeKB.  Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_Alloc:
        push    bp
        mov     bp, sp
        %define sizeKB_w    [bp+RSIZE+2]
        %define handle_ofs  [bp+RSIZE+4]
        %define handle_seg  [bp+RSIZE+6]
        push    bx
        push    dx
        push    ds
        push    es
        push    di

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .go
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.go:
        mov     ax, sizeKB_w
        or      ax, ax
        jnz     .roundup
        mov     bx, 1
        jmp     .doalloc
.roundup:
        add     ax, 15
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        mov     bx, ax

.doalloc:
        mov     ax, 4300h
        int     67h
        xor     al, al
        xchg    al, ah                  ; ax = error code (0 = success)
        mov     [errorCode], ax
        or      al, al
        jnz     .fail

        les     di, handle_ofs
        mov     [es:di], dx
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     di
        pop     es
        pop     ds
        pop     dx
        pop     bx
        %undef sizeKB_w
        %undef handle_ofs
        %undef handle_seg
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; EMS_Free(handle: WORD): BOOLEAN
; AH=45h (Deallocate Handle and Release Pages).  Input: DX=handle.
; Stack: handle.  Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_Free:
        push    bp
        mov     bp, sp
        %define handle_w [bp+RSIZE+2]
        push    dx
        push    ds

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .go
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.go:
        mov     dx, handle_w
        mov     ax, 4500h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     [errorCode], ax
        or      al, al
        jnz     .fail
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     ds
        pop     dx
        %undef handle_w
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; EMS_Realloc(VAR handle: WORD; newSizeKB: WORD): BOOLEAN
; Rounds newSizeKB up to pages (same rule as EMS_Alloc), then AH=4Ch (Get
; Handle Pages) to read the current page count; if it already matches, skips
; AH=51h (Reallocate Pages) entirely -- same short-circuit EMS.Realloc had
; before.  Function 51h keeps the SAME handle (it never returns a new one),
; so `handle` itself is never rewritten by this routine.
; Output: AX = 0/1 (BOOLEAN).
; Stack (POP order): newSizeKB, handle_ofs, handle_seg.  Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_Realloc:
        push    bp
        mov     bp, sp
        %define handle_ofs   [bp+RSIZE+2]
        %define handle_seg   [bp+RSIZE+4]
        %define newSizeKB_w  [bp+RSIZE+6]
        push    bx
        push    dx
        push    ds
        push    es
        push    di

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .go
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.go:
        les     di, handle_ofs
        mov     dx, [es:di]             ; dx = handle

        mov     ax, newSizeKB_w
        or      ax, ax
        jnz     .roundup
        mov     bx, 1
        jmp     .getpages
.roundup:
        add     ax, 15
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        mov     bx, ax                  ; bx = newPages (kept across the 4Ch call)

.getpages:
        push    bx                      ; save newPages
        mov     ax, 4C00h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     [errorCode], ax
        pop     bx                      ; bx = newPages
        or      al, al
        jnz     .fail                   ; 4Ch itself failed

        cmp     cx, bx                  ; 4Ch returns current page count in BX;
                                         ; NASM aliases don't survive the far
                                         ; call, so re-read handle/newPages
                                         ; fresh below instead of trusting
                                         ; register survival across INT 67h.
        jmp     .comparecur

.comparecur:
        les     di, handle_ofs
        mov     dx, [es:di]
        mov     ax, newSizeKB_w
        or      ax, ax
        jnz     .roundup2
        mov     cx, 1
        jmp     .havenew2
.roundup2:
        add     ax, 15
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        mov     cx, ax
.havenew2:
        cmp     bx, cx                  ; bx = current pages (from 4Ch's BX,
                                         ; still valid: no call between AH=4Ch
                                         ; and here clobbered it), cx = newPages
        je      .samesize

        mov     ax, 5100h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     [errorCode], ax
        or      al, al
        jnz     .fail
        mov     ax, 1
        jmp     .ret
.samesize:
        mov     word [errorCode], 0
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     di
        pop     es
        pop     ds
        pop     dx
        pop     bx
        %undef handle_ofs
        %undef handle_seg
        %undef newSizeKB_w
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; EMS_CopyToEMS(VAR dosBuf; handle: WORD; emsOffset: LONGINT; size: WORD): BOOLEAN
; EMS_CopyToDos(handle: WORD; emsOffset: LONGINT; VAR dosBuf; size: WORD): BOOLEAN
; Both fill the static `moveDesc` scratch buffer (CS-relative, DS=CS -- no
; stack-frame arithmetic needed since neither routine is ever called
; re-entrantly) and issue AH=57h (Move Memory Region).  conv (dosBuf's far
; address) arrives on the stack as offset:segment exactly as SYSTEM.ADR
; would have packed it.  emsOffset is a flat LONGINT byte offset;
; PageSize=16384=2^14 so logical page = emsOffset >> 14 and offsetInPage =
; emsOffset & 0x3FFF (pure shift/mask -- no 32-bit divide needed).  size=0
; short-circuits to success without touching the driver (matches the
; original Oberon fast path in EMS.MOD's CopyToEMS/CopyToDos, which never
; even called DoMove for size=0).
; Output: AX = 0/1 (BOOLEAN).
; -----------------------------------------------------------------------------

; EMS_CopyToEMS stack (POP order): size, emsOffset_hi, emsOffset_lo, handle,
; dosBuf_seg, dosBuf_ofs.  Call Type: FAR.
EMS_CopyToEMS:
        push    bp
        mov     bp, sp
        %define dosBuf_ofs   [bp+RSIZE+2]
        %define dosBuf_seg   [bp+RSIZE+4]
        %define handle_w     [bp+RSIZE+6]
        %define emsOfs_lo    [bp+RSIZE+8]
        %define emsOfs_hi    [bp+RSIZE+10]
        %define size_w       [bp+RSIZE+12]
        push    bx
        push    cx
        push    dx
        push    si
        push    ds

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .gate_ok
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.gate_ok:
        mov     ax, size_w
        or      ax, ax
        jnz     .go
        mov     word [errorCode], 0
        mov     ax, 1
        jmp     .ret

.go:
        ; bx = emsOffset >> PageShift (logical page number); cx = scratch
        ; loop counter for the compile-time-constant 14-bit shift (paid once
        ; per call, not per byte moved -- see SYS.ASM's div_kernel_32 for the
        ; same reasoning applied to its 32-iteration shift loop).
        mov     ax, emsOfs_lo
        mov     dx, emsOfs_hi
        mov     cx, PageShift
.shr32:
        shr     dx, 1
        rcr     ax, 1
        loop    .shr32
        mov     bx, ax                  ; bx = logical page number

        mov     ax, emsOfs_lo
        and     ax, (PageSize - 1)      ; ax = offset within page

        mov     dx, size_w
        mov     word [moveDesc+TMoveDesc.len], dx
        mov     word [moveDesc+TMoveDesc.len+2], 0
        mov     byte [moveDesc+TMoveDesc.srcType], 0
        mov     word [moveDesc+TMoveDesc.srcHandle], 0
        mov     dx, dosBuf_ofs
        mov     word [moveDesc+TMoveDesc.srcOfs], dx
        mov     dx, dosBuf_seg
        mov     word [moveDesc+TMoveDesc.srcSeg], dx
        mov     byte [moveDesc+TMoveDesc.dstType], 1
        mov     dx, handle_w
        mov     word [moveDesc+TMoveDesc.dstHandle], dx
        mov     word [moveDesc+TMoveDesc.dstOfs], ax   ; offset within page
        mov     word [moveDesc+TMoveDesc.dstSeg], bx   ; logical page number

        mov     si, moveDesc            ; DS is already set to moveDesc's
                                         ; segment (same .data section as
                                         ; driverPresent) from function
                                         ; entry, so DS:SI = moveDesc here
        mov     ax, 5700h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     [errorCode], ax
        or      al, al
        jne     .fail
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     ds
        pop     si
        pop     dx
        pop     cx
        pop     bx
        %undef dosBuf_ofs
        %undef dosBuf_seg
        %undef handle_w
        %undef emsOfs_lo
        %undef emsOfs_hi
        %undef size_w
        pop     bp
        RETMACRO 12

; EMS_CopyToDos stack (POP order): size, dosBuf_ofs, dosBuf_seg,
; emsOffset_hi, emsOffset_lo, handle.  Call Type: FAR.
EMS_CopyToDos:
        push    bp
        mov     bp, sp
        %define handle_w     [bp+RSIZE+2]
        %define emsOfs_lo    [bp+RSIZE+4]
        %define emsOfs_hi    [bp+RSIZE+6]
        %define dosBuf_seg   [bp+RSIZE+8]
        %define dosBuf_ofs   [bp+RSIZE+10]
        %define size_w       [bp+RSIZE+12]
        push    bx
        push    cx
        push    dx
        push    si
        push    ds

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .gate_ok
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.gate_ok:
        mov     ax, size_w
        or      ax, ax
        jnz     .go
        mov     word [errorCode], 0
        mov     ax, 1
        jmp     .ret

.go:
        mov     ax, emsOfs_lo
        mov     dx, emsOfs_hi
        mov     cx, PageShift
.shr32:
        shr     dx, 1
        rcr     ax, 1
        loop    .shr32
        mov     bx, ax                  ; bx = logical page number

        mov     ax, emsOfs_lo
        and     ax, (PageSize - 1)      ; ax = offset within page

        mov     dx, size_w
        mov     word [moveDesc+TMoveDesc.len], dx
        mov     word [moveDesc+TMoveDesc.len+2], 0
        mov     byte [moveDesc+TMoveDesc.srcType], 1
        mov     dx, handle_w
        mov     word [moveDesc+TMoveDesc.srcHandle], dx
        mov     word [moveDesc+TMoveDesc.srcOfs], ax   ; offset within page
        mov     word [moveDesc+TMoveDesc.srcSeg], bx   ; logical page number
        mov     byte [moveDesc+TMoveDesc.dstType], 0
        mov     word [moveDesc+TMoveDesc.dstHandle], 0
        mov     dx, dosBuf_ofs
        mov     word [moveDesc+TMoveDesc.dstOfs], dx
        mov     dx, dosBuf_seg
        mov     word [moveDesc+TMoveDesc.dstSeg], dx

        mov     si, moveDesc            ; DS is already set to moveDesc's
                                         ; segment (same .data section as
                                         ; driverPresent) from function
                                         ; entry, so DS:SI = moveDesc here
        mov     ax, 5700h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     [errorCode], ax
        or      al, al
        jne     .fail
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     ds
        pop     si
        pop     dx
        pop     cx
        pop     bx
        %undef handle_w
        %undef emsOfs_lo
        %undef emsOfs_hi
        %undef dosBuf_seg
        %undef dosBuf_ofs
        %undef size_w
        pop     bp
        RETMACRO 12

; -----------------------------------------------------------------------------
; version_near: NEAR helper shared by EMS_Version and EMS_RequireVersion.
; AH=46h (Get EMM Version).  Output: AL = BCD version byte on success, AH=0;
; AL=0 on failure or if the driver isn't present (matches EMS.MOD's original
; Version, which returned 0 in both cases and did not distinguish them).
; A NEAR helper (not `global`, plain `retn`) rather than a second `global`
; FAR routine, since calling one `global` FAR entry point from another
; within this file needs a segment-base reference that only a real
; RDOFF-relocatable build can resolve (see EMS_MapPtr's note on the same
; issue) -- easier to factor the shared logic into a NEAR call instead,
; matching SYS.ASM's own div_kernel_32/check_8087/MEM_INIT pattern.
; Clobbers: AX.  Preserves: BX, CX, DX, SI, DI, DS, ES.
; -----------------------------------------------------------------------------
version_near:
        push    ds
        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .go
        xor     ax, ax
        jmp     .ret
.go:
        mov     word [errorCode], 0
        mov     ax, 4600h
        int     67h
        or      ah, ah
        jz      .ok
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.ok:
        xor     ah, ah                  ; ax = version byte, zero-extended

.ret:
        pop     ds
        ret

; -----------------------------------------------------------------------------
; EMS_Version(): BYTE
; Call Type: FAR, no params.  Output: AX low byte = BCD version (0 on
; failure/absent driver).
; -----------------------------------------------------------------------------
EMS_Version:
        call    version_near
        RETMACRO 0

; -----------------------------------------------------------------------------
; EMS_RequireVersion(ver: BYTE)
; Clears driverPresent if version_near() < ver.
; Stack: ver.  Call Type: FAR, no return value.
; -----------------------------------------------------------------------------
EMS_RequireVersion:
        push    bp
        mov     bp, sp
        %define ver_w [bp+RSIZE+2]
        push    ax
        push    ds

        call    version_near
        cmp     al, byte ver_w
        jae     .ret
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     byte [driverPresent], 0

.ret:
        pop     ds
        pop     ax
        %undef ver_w
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; EMS_MapPage(handle: WORD; logicalPage: WORD; physicalPage: WORD): BOOLEAN
; AH=44h (Map Handle Page).  Input: AL=physicalPage, BX=logicalPage,
; DX=handle.  Gates on driverPresent, pageFrameObtained, and
; physicalPage < MaxPhysicalPages, matching EMS.MOD's original MapPage.
; Output: AX = 0/1 (BOOLEAN).
; Stack (POP order): physicalPage, logicalPage, handle.  Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_MapPage:
        push    bp
        mov     bp, sp
        %define handle_w    [bp+RSIZE+2]
        %define logPage_w   [bp+RSIZE+4]
        %define physPage_w  [bp+RSIZE+6]
        push    bx
        push    dx
        push    ds

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .chk2
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.chk2:
        cmp     byte [pageFrameObtained], 0
        jne     .chk3
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.chk3:
        mov     ax, physPage_w
        cmp     ax, MaxPhysicalPages
        jb      .go
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.go:
        mov     dx, handle_w
        mov     bx, logPage_w
        mov     al, byte physPage_w
        mov     ah, 44h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     [errorCode], ax
        or      al, al
        jnz     .fail
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     ds
        pop     dx
        pop     bx
        %undef handle_w
        %undef logPage_w
        %undef physPage_w
        pop     bp
        RETMACRO 6

; -----------------------------------------------------------------------------
; EMS_UnmapPage(physicalPage: WORD): BOOLEAN
; AH=44h (Map Handle Page) with BX=0/DX=0 -- the exact bytes EMS.MOD's
; original UnmapPage issued (there is no dedicated "unmap" function in the
; LIM EMS spec; mapping logical page 0 of handle 0 into the physical page is
; the idiom the prior SYSTEM.Intr version used, preserved verbatim here).
; Gates the same way as EMS_MapPage.
; Output: AX = 0/1 (BOOLEAN).
; Stack: physicalPage.  Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_UnmapPage:
        push    bp
        mov     bp, sp
        %define physPage_w [bp+RSIZE+2]
        push    bx
        push    dx
        push    ds

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .chk2
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.chk2:
        cmp     byte [pageFrameObtained], 0
        jne     .chk3
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.chk3:
        mov     ax, physPage_w
        cmp     ax, MaxPhysicalPages
        jb      .go
        mov     word [errorCode], 0FFh
        xor     ax, ax
        jmp     .ret
.go:
        xor     bx, bx
        xor     dx, dx
        mov     al, byte physPage_w
        mov     ah, 44h
        int     67h
        xor     al, al
        xchg    al, ah
        mov     [errorCode], ax
        or      al, al
        jnz     .fail
        mov     ax, 1
        jmp     .ret
.fail:
        xor     ax, ax

.ret:
        pop     ds
        pop     dx
        pop     bx
        %undef physPage_w
        pop     bp
        RETMACRO 2

; -----------------------------------------------------------------------------
; EMS_MapPtr(handle: WORD; emsOffset_lo, emsOffset_hi: WORD; physWin: WORD): SYSTEM.ADDRESS
; logicalPage = emsOffset >> PageShift; offsetInPage = emsOffset & (PageSize-1)
; (pure shift/mask, same reasoning as EMS_CopyToEMS).  The AH=44h Map
; Handle Page gating/call is inlined here rather than calling EMS_MapPage
; directly: NASM's `bin`-testable syntax for an intra-file FAR call needs a
; segment-base reference that only a real RDOFF-relocatable build can
; resolve, and SYS.ASM's own routines never call one another's `global` FAR
; entry points either -- each externally-callable routine is self-contained.
; On success returns DX:AX = far pointer {segment = pageFrameSeg +
; physWin*(PageSize/16), offset = offsetInPage}; on failure returns DX:AX =
; 0:0 (NIL).
; Stack (POP order): physWin, emsOffset_hi, emsOffset_lo, handle.
; Call Type: FAR.
; -----------------------------------------------------------------------------
EMS_MapPtr:
        push    bp
        mov     bp, sp
        %define handle_w      [bp+RSIZE+2]
        %define emsOfs_lo     [bp+RSIZE+4]
        %define emsOfs_hi     [bp+RSIZE+6]
        %define physWin_w     [bp+RSIZE+8]
        push    bx
        push    cx
        ; No push dx: this routine returns DX:AX (far pointer / NIL), so DX
        ; is a result register here, not a callee-saved one -- same
        ; convention SYS.ASM's SYSTEM_Alloc follows for its DX:AX result.

        mov     ax, seg driverPresent
        mov     ds, ax
        cmp     byte [driverPresent], 0
        jne     .chk2
        mov     word [errorCode], 0FFh
        jmp     .fail
.chk2:
        cmp     byte [pageFrameObtained], 0
        jne     .chk3
        mov     word [errorCode], 0FFh
        jmp     .fail
.chk3:
        mov     ax, physWin_w
        cmp     ax, MaxPhysicalPages
        jb      .go
        mov     word [errorCode], 0FFh
        jmp     .fail

.go:
        ; bx = logicalPage = emsOffset >> PageShift; cx = offsetInPage =
        ; emsOffset & (PageSize-1).  Computed before the INT 67h call since
        ; that call clobbers AX/BX/DX.
        mov     ax, emsOfs_lo
        mov     bx, emsOfs_hi
        mov     cx, PageShift
.shr32:
        shr     bx, 1
        rcr     ax, 1
        loop    .shr32
        mov     bx, ax                  ; bx = logicalPage

        mov     ax, emsOfs_lo
        and     ax, (PageSize - 1)
        mov     cx, ax                  ; cx = offsetInPage

        mov     dx, handle_w
        mov     al, byte physWin_w
        mov     ah, 44h
        int     67h                     ; AH=44h Map Handle Page: AL=physWin,
                                         ; BX=logicalPage, DX=handle (all set
                                         ; above; clobbers AX/BX/DX)
        xor     al, al
        xchg    al, ah
        mov     ax, seg driverPresent
        mov     ds, ax
        mov     [errorCode], ax
        or      al, al
        jnz     .fail

        mov     bx, [pageFrameSeg]
        mov     ax, physWin_w
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                   ; ax = physWin * (PageSize/16) = physWin*1024
        add     bx, ax
        mov     dx, bx                  ; dx = segment
        mov     ax, cx                  ; ax = offsetInPage
        jmp     .done

.fail:
        xor     dx, dx
        xor     ax, ax

.done:
        pop     cx
        pop     bx
        %undef handle_w
        %undef emsOfs_lo
        %undef emsOfs_hi
        %undef physWin_w
        pop     bp
        RETMACRO 8
