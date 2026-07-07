; todbg.asm — minimal interactive DOS debugger (NASM, 8086 real mode).
;
; Usage:  TODBG program.exe [args...]
;
; Loads program.exe as a child process via INT 21h AH=4Bh AL=01h (load but
; do not execute), installs INT 01h (single-step) and INT 03h (breakpoint)
; handlers, then hands control to the child under trace.  While the child
; is stopped, an interactive command loop on stdin/stdout lets the user:
;
;   T           trace one instruction (single-step)
;   G           go: run free until a breakpoint or program exit
;   B xxxx:yyyy set a breakpoint at CS:IP = xxxx:yyyy (INT 3 patch)
;   D xxxx:yyyy delete the breakpoint at xxxx:yyyy
;   R           show registers/flags
;   Q           quit: terminate the child and exit todbg
;
; Addresses are raw segment:offset (hex) — no symbol/TDINFO awareness.
; This is a COM-style program: single segment, org 100h, all code/data/stack
; sharing one 64K segment (a debugger stub does not need more). The child
; runs on ITS OWN stack at all times (todbg never touches it except to read
; the interrupt frame at trap entry); todbg only switches onto its own
; private stack (DbgStackTop) once inside a trap handler, and switches back
; before resuming the child — see the INT 01h/INT 03h handler comment below.
;
; Build:  nasm -f bin -o TODBG.COM todbg.asm

bits 16
cpu 8086

org 100h

section .text

start:
        ; ---- parse command tail: first token = child path, rest = child args ----
        mov     si, 80h                  ; DOS command tail: [80h]=len, [81h..]=text
        xor     cx, cx
        mov     cl, [si]
        add     si, 1
        mov     di, si
        add     di, cx                   ; DI -> byte after tail (usually 0Dh)
        mov     byte [di], 0             ; NUL-terminate whole tail for scanning

        call    SkipSpaces
        cmp     byte [si], 0
        jne     .have_arg
        mov     dx, MsgUsage
        call    PrintStr
        jmp     ExitNow

.have_arg:
        mov     di, ChildPath
        call    CopyToken                ; SI -> after path token now

        ; copy remainder (child args, still NUL-terminated at old tail end) as-is
        call    SkipSpaces
        mov     di, ChildTail + 1
        xor     cx, cx
.copy_tail:
        mov     al, [si]
        cmp     al, 0
        je      .tail_done
        mov     [di], al
        inc     si
        inc     di
        inc     cx
        jmp     .copy_tail
.tail_done:
        mov     byte [di], 0Dh           ; DOS tail convention: ends with CR
        mov     [ChildTail], cl          ; length byte

        ; ---- build EXEC parameter block ----
        ; ExecBlock:
        ;   +0  word  env segment (0 = copy parent's)
        ;   +2  dword ptr to command tail (len-byte + text + CR)
        ;   +6  dword ptr to first FCB (unused, zeroed)
        ;   +10 dword ptr to second FCB (unused, zeroed)
        mov     word [ExecBlock+0], 0
        mov     word [ExecBlock+2], ChildTail
        mov     [ExecBlock+4], cs
        mov     word [ExecBlock+6], DummyFCB
        mov     [ExecBlock+8], cs
        mov     word [ExecBlock+10], DummyFCB
        mov     [ExecBlock+12], cs

        ; ---- load child, do not execute (AL=01h) ----
        mov     ax, cs
        mov     es, ax
        mov     dx, ChildPath
        mov     bx, ExecBlock
        mov     ax, 4B01h
        int     21h
        jnc     .load_ok
        mov     dx, MsgLoadFail
        call    PrintStr
        jmp     ExitNow

.load_ok:
        ; DOS fills a LOAD_EXEC_BLOCK-compatible structure at ExecBlock only
        ; for overlay loads (AL=03h). For AL=01h ("load, don't execute") DOS
        ; instead returns child's initial CS:IP/SS:SP in this SAME 16-byte
        ; area for real MS-DOS 3.x+ semantics used here:
        ;   ExecBlock+14 word  child IP
        ;   ExecBlock+16 word  child CS
        ;   ExecBlock+18 word  child SP
        ;   ExecBlock+20 word  child SS
        mov     ax, [ExecBlock+16]
        mov     [ChildCS], ax
        mov     ax, [ExecBlock+14]
        mov     [ChildIP], ax
        mov     ax, [ExecBlock+20]
        mov     [ChildSS], ax
        mov     ax, [ExecBlock+18]
        mov     [ChildSP], ax

        ; ---- install INT 01h / INT 03h vectors, remembering the old ones ----
        mov     ax, 3501h                ; get vector 01h
        int     21h
        mov     [OldInt1Off], bx
        mov     [OldInt1Seg], es
        mov     dx, Int1Handler
        mov     ax, 2501h                ; set vector 01h
        int     21h

        mov     ax, 3503h                ; get vector 03h
        int     21h
        mov     [OldInt3Off], bx
        mov     [OldInt3Seg], es
        mov     dx, Int3Handler
        mov     ax, 2503h                ; set vector 03h
        int     21h

        mov     byte [BpCount], 0

        ; Seed Saved* with the child's actual entry state, so the first
        ; ResumeChild (from CmdTrace/CmdGo) jumps into the child rather than
        ; wherever stale data happens to be.  DOS starts a child with all
        ; general registers zeroed and DS=ES=its own PSP segment; child
        ; starts under trace (TF set) so the very first instruction already
        ; stops back in the command loop.
        mov     word [SavedFlags], 0202h ; IF=1, TF=1
        xor     ax, ax
        mov     [SavedAX], ax
        mov     [SavedBX], ax
        mov     [SavedCX], ax
        mov     [SavedDX], ax
        mov     [SavedSI], ax
        mov     [SavedDI], ax
        mov     [SavedBP], ax
        mov     ax, [ChildCS]
        mov     [SavedCS], ax
        mov     ax, [ChildIP]
        mov     [SavedIP], ax
        ; child's PSP segment == ChildCS - 10h (PSP is one paragraph, 16
        ; bytes, before the load segment for a .COM/.EXE with no header
        ; relocation offset); DOS actually sets DS=ES=PSP segment at entry,
        ; which for our purposes we approximate with ChildCS since child
        ; code always reloads DS/ES itself before touching data.
        mov     ax, [ChildCS]
        mov     [SavedDS], ax
        mov     [SavedES], ax

        mov     dx, MsgReady
        call    PrintStr
        jmp     CommandLoop

; -------------------------------------------------------------------------
; INT 01h / INT 03h handlers.
;
; Both fire with SS:SP still pointing at the CHILD's stack (real-mode
; interrupts don't switch stacks), with the CPU's 3-word far-interrupt
; frame (IP, CS, FLAGS) sitting on top of it. Since they're entered
; directly by the CPU as interrupt vector targets (not CALLed), SP on
; entry points exactly at that frame — no return address to account for.
; We must not PUSH/CALL anything while SS:SP is still on the child's stack
; without having read the frame out first, so each handler:
;   1. saves general/segment regs into Saved* (plain MOVs, no stack use)
;   2. reads IP/CS/FLAGS from [ss:bx+0/2/4] without popping
;   3. records ChildSS/ChildSP as sp+6 (past the frame: where the child's
;      own stack pointer really is once the frame is accounted for)
;   4. calls SwitchToDbgStack, which moves SS:SP onto todbg's own private
;      stack — only after that is it safe to CALL/PUSH again
; -------------------------------------------------------------------------
Int1Handler:
        mov     [SavedAX], ax
        mov     [SavedBX], bx
        mov     [SavedCX], cx
        mov     [SavedDX], dx
        mov     [SavedSI], si
        mov     [SavedDI], di
        mov     [SavedBP], bp
        mov     [SavedDS], ds
        mov     [SavedES], es
        mov     bx, sp
        mov     ax, [ss:bx+0]
        mov     [SavedIP], ax
        mov     ax, [ss:bx+2]
        mov     [SavedCS], ax
        mov     ax, [ss:bx+4]
        mov     [SavedFlags], ax
        mov     [ChildSS], ss
        add     bx, 6                    ; past the frame: real child SP
        mov     [ChildSP], bx
        call    SwitchToDbgStack         ; safe to CALL/PUSH from here on
        mov     dx, MsgTraceStop
        call    PrintStr
        call    ShowRegs
        jmp     CommandLoop

Int3Handler:
        mov     [SavedAX], ax
        mov     [SavedBX], bx
        mov     [SavedCX], cx
        mov     [SavedDX], dx
        mov     [SavedSI], si
        mov     [SavedDI], di
        mov     [SavedBP], bp
        mov     [SavedDS], ds
        mov     [SavedES], es
        mov     bx, sp
        mov     ax, [ss:bx+0]
        mov     [SavedIP], ax
        mov     ax, [ss:bx+2]
        mov     [SavedCS], ax
        mov     ax, [ss:bx+4]
        mov     [SavedFlags], ax
        mov     [ChildSS], ss
        add     bx, 6
        mov     [ChildSP], bx
        call    SwitchToDbgStack         ; safe to CALL/PUSH from here on
        dec     word [SavedIP]           ; back up over the 0CCh byte
        call    RestoreBpAt              ; undo the 0CCh patch at SavedCS:SavedIP
        mov     dx, MsgBpHit
        call    PrintStr
        call    ShowRegs
        jmp     CommandLoop

; SwitchToDbgStack: move SS:SP onto todbg's own private stack. Must only be
; called after the child's frame/registers have already been captured into
; Saved*/Child*, since it discards whatever was addressable via the old
; SS:SP (the child's stack is left untouched in memory — we simply stop
; using it until ResumeChild switches back).
SwitchToDbgStack:
        pop     bx                       ; our own return address, off the CHILD stack
        cli
        mov     ax, cs
        mov     ss, ax
        mov     sp, DbgStackTop
        sti
        jmp     bx

; -------------------------------------------------------------------------
; Command loop: prompt, read a line from stdin, dispatch on first letter.
; -------------------------------------------------------------------------
CommandLoop:
        mov     dx, MsgPrompt
        call    PrintStr
        call    ReadLine                 ; fills LineBuf, NUL-terminated
        mov     si, LineBuf
        call    SkipSpaces
        mov     al, [si]
        call    ToUpper
        cmp     al, 'T'
        je      CmdTrace
        cmp     al, 'G'
        je      CmdGo
        cmp     al, 'B'
        je      CmdSetBp
        cmp     al, 'D'
        je      CmdDelBp
        cmp     al, 'R'
        je      CmdRegs
        cmp     al, 'Q'
        je      CmdQuit
        cmp     al, 0
        je      CommandLoop              ; blank line: just re-prompt
        mov     dx, MsgBadCmd
        call    PrintStr
        jmp     CommandLoop

; T — single-step one instruction: set TF, resume child, INT 1 fires next.
CmdTrace:
        or      word [SavedFlags], 0100h ; TF
        jmp     ResumeChild

; G — free run: clear TF, resume; only breakpoints (INT 3) will stop it.
CmdGo:
        and     word [SavedFlags], 0FEFFh ; ~TF
        jmp     ResumeChild

; R — print registers without stepping, stay in the command loop.
CmdRegs:
        call    ShowRegs
        jmp     CommandLoop

; Q — restore any patched breakpoint bytes, restore vectors, terminate.
CmdQuit:
        call    RemoveAllBps
        call    RestoreVectors
        mov     dx, MsgBye
        call    PrintStr
        jmp     ExitNow

; B xxxx:yyyy — parse two hex words separated by ':', patch 0CCh at that
; child address (saving the original byte), record in the breakpoint table.
CmdSetBp:
        inc     si
        call    SkipSpaces
        call    ParseSegOfs
        jc      .bad
        cmp     byte [BpCount], MaxBps
        jae     .full
        ; CX:DX = target seg:ofs (from ParseSegOfs). Save the new row index
        ; (current BpCount) on the stack — BX is needed as scratch below,
        ; both for the *4 table-row multiply and as an [es:bx] pointer into
        ; child memory, so we don't try to keep the index in a register
        ; across those.
        xor     bh, bh
        mov     bl, [BpCount]
        push    bx
        mov     al, bl
        mov     ah, 4
        mul     ah                       ; AX = index*4 = BpTable row offset
        mov     di, BpTable
        add     di, ax
        mov     [di+0], cx               ; segment
        mov     [di+2], dx               ; offset

        ; read the original byte at CX:DX in child memory, then patch 0CCh
        push    es
        mov     es, cx
        mov     bx, dx
        mov     al, [es:bx]
        mov     byte [es:bx], 0CCh       ; patch INT 3
        pop     es

        pop     bx                       ; row index (0..MaxBps-1)
        mov     di, BpSaved
        add     di, bx                   ; BpSaved is 1 byte/row: index == offset
        mov     [di], al                 ; original byte, saved for restore

        inc     byte [BpCount]
        mov     dx, MsgBpSet
        call    PrintStr
        jmp     CommandLoop
.full:
        mov     dx, MsgBpFull
        call    PrintStr
        jmp     CommandLoop
.bad:
        mov     dx, MsgBadAddr
        call    PrintStr
        jmp     CommandLoop

; D xxxx:yyyy — remove a previously set breakpoint (restore original byte).
CmdDelBp:
        inc     si
        call    SkipSpaces
        call    ParseSegOfs
        jc      .bad
        call    FindBp                   ; -> BX = table index or -1 in AX
        cmp     ax, -1
        je      .notfound
        call    RemoveBpIndex
        mov     dx, MsgBpDel
        call    PrintStr
        jmp     CommandLoop
.notfound:
        mov     dx, MsgBpNone
        call    PrintStr
        jmp     CommandLoop
.bad:
        mov     dx, MsgBadAddr
        call    PrintStr
        jmp     CommandLoop

; -------------------------------------------------------------------------
; Resume the child: rebuild its interrupt frame (FLAGS,CS,IP) on ITS stack,
; restore its registers, switch SS:SP to the child stack, then IRET into
; child code.  This mirrors exactly what the CPU would do returning from
; the trap, so single-step/breakpoint continuation is transparent to it.
; -------------------------------------------------------------------------
ResumeChild:
        cli
        mov     ax, [ChildSS]
        mov     ss, ax
        mov     sp, [ChildSP]
        push    word [SavedFlags]
        push    word [SavedCS]
        push    word [SavedIP]
        mov     ax, [SavedAX]
        mov     bx, [SavedBX]
        mov     cx, [SavedCX]
        mov     dx, [SavedDX]
        mov     si, [SavedSI]
        mov     di, [SavedDI]
        mov     bp, [SavedBP]
        mov     ds, [SavedDS]
        mov     es, [SavedES]
        iret

; -------------------------------------------------------------------------
; ShowRegs: print "AX=.... BX=.... CX=.... DX=.... SI=.... DI=.... BP=...."
; then "DS=.... ES=.... SS=.... SP=.... CS=IP=xxxx:yyyy  FL=...." with a
; newline.  Uses PrintHexWord for each field.
; -------------------------------------------------------------------------
ShowRegs:
        mov     dx, LblAX
        call    PrintStr
        mov     ax, [SavedAX]
        call    PrintHexWord
        mov     dx, LblBX
        call    PrintStr
        mov     ax, [SavedBX]
        call    PrintHexWord
        mov     dx, LblCX
        call    PrintStr
        mov     ax, [SavedCX]
        call    PrintHexWord
        mov     dx, LblDX
        call    PrintStr
        mov     ax, [SavedDX]
        call    PrintHexWord
        call    PrintCRLF

        mov     dx, LblSI
        call    PrintStr
        mov     ax, [SavedSI]
        call    PrintHexWord
        mov     dx, LblDI
        call    PrintStr
        mov     ax, [SavedDI]
        call    PrintHexWord
        mov     dx, LblBP
        call    PrintStr
        mov     ax, [SavedBP]
        call    PrintHexWord
        mov     dx, LblFL
        call    PrintStr
        mov     ax, [SavedFlags]
        call    PrintHexWord
        call    PrintCRLF

        mov     dx, LblCSIP
        call    PrintStr
        mov     ax, [SavedCS]
        call    PrintHexWord
        mov     dl, ':'
        mov     ah, 2
        int     21h
        mov     ax, [SavedIP]
        call    PrintHexWord
        call    PrintCRLF
        retn

; -------------------------------------------------------------------------
; Utility routines
; -------------------------------------------------------------------------

; SkipSpaces: advance SI past ASCII spaces/tabs.
SkipSpaces:
        mov     al, [si]
        cmp     al, ' '
        je      .adv
        cmp     al, 9
        jne     .done
.adv:
        inc     si
        jmp     SkipSpaces
.done:
        retn

; CopyToken: copy non-space chars from SI into DI, NUL-terminate; SI left
; pointing right after the token (at the terminating space/NUL).
CopyToken:
        mov     al, [si]
        cmp     al, 0
        je      .done
        cmp     al, ' '
        je      .done
        cmp     al, 9
        je      .done
        cmp     al, 0Dh
        je      .done
        mov     [di], al
        inc     si
        inc     di
        jmp     CopyToken
.done:
        mov     byte [di], 0
        retn

; ToUpper: AL := upper-case of [SI] (does not modify SI).
ToUpper:
        mov     al, [si]
        cmp     al, 'a'
        jb      .done
        cmp     al, 'z'
        ja      .done
        sub     al, 20h
.done:
        retn

; ParseSegOfs: parse "XXXX:YYYY" hex at SI -> CX:DX (seg:ofs).
; Advances SI past the parsed text.  CF set on malformed input.
ParseSegOfs:
        call    ParseHexWord
        jc      .bad
        mov     cx, ax
        cmp     byte [si], ':'
        jne     .bad
        inc     si
        call    ParseHexWord
        jc      .bad
        mov     dx, ax
        clc
        retn
.bad:
        stc
        retn

; ParseHexWord: parse up to 4 hex digits at SI into AX. Advances SI.
; CF set if no hex digit was found at all.
ParseHexWord:
        xor     ax, ax
        xor     cx, cx
.loop:
        mov     bl, [si]
        call    HexDigitVal              ; -> BL = 0..15, CF set if not hex
        jc      .maybedone
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        or      al, bl
        inc     si
        inc     cx
        jmp     .loop
.maybedone:
        cmp     cx, 0
        je      .none
        clc
        retn
.none:
        stc
        retn

; HexDigitVal: BL := [0-9A-Fa-f] value of AL char; CF set if not a hex digit.
HexDigitVal:
        mov     bl, [si]
        cmp     bl, '0'
        jb      .no
        cmp     bl, '9'
        ja      .notdigit
        sub     bl, '0'
        clc
        retn
.notdigit:
        cmp     bl, 'A'
        jb      .no
        cmp     bl, 'F'
        ja      .lower
        sub     bl, 'A' - 10
        clc
        retn
.lower:
        cmp     bl, 'a'
        jb      .no
        cmp     bl, 'f'
        ja      .no
        sub     bl, 'a' - 10
        clc
        retn
.no:
        stc
        retn

; FindBp: search BpTable for segment CX / offset DX. Returns AX = index or
; -1 if not present. Uses BX as scratch (clobbered).
FindBp:
        xor     bx, bx
.loop:
        cmp     bl, [BpCount]
        jae     .none
        mov     al, bl
        mov     ah, 4
        mul     ah
        push    bx
        mov     bx, ax
        mov     di, BpTable
        add     di, bx
        cmp     word [di+0], cx
        jne     .next
        cmp     word [di+2], dx
        jne     .next
        pop     bx
        mov     ax, bx
        retn
.next:
        pop     bx
        inc     bx
        jmp     .loop
.none:
        mov     ax, -1
        retn

; RestoreBpAt: if SavedCS:SavedIP matches a set breakpoint, write its saved
; original byte back into child memory (undoing our 0CCh patch) so the
; instruction can execute normally when resumed.
RestoreBpAt:
        mov     cx, [SavedCS]
        mov     dx, [SavedIP]
        call    FindBp
        cmp     ax, -1
        je      .done
        mov     bx, ax                   ; BpSaved is 1 byte/row: index == offset
        mov     di, BpSaved
        add     di, bx
        mov     al, [di]
        push    es
        mov     es, cx
        mov     bx, dx
        mov     [es:bx], al
        pop     es
.done:
        retn

; RemoveBpIndex: AX = table index to remove; restore its byte in child
; memory and compact the table by shifting later entries down.
RemoveBpIndex:
        push    ax
        mov     bx, ax
        mov     al, bl
        mov     ah, 4
        mul     ah
        mov     di, BpTable
        add     di, ax                   ; AX = index*4 = BpTable row offset
        mov     cx, [di+0]
        mov     dx, [di+2]
        pop     ax
        push    ax
        mov     bx, ax                   ; BpSaved is 1 byte/row: index == offset
        mov     si, BpSaved
        add     si, bx
        mov     al, [si]
        push    es
        mov     es, cx
        mov     bx, dx
        mov     [es:bx], al
        pop     es
        pop     ax
        ; compact BpTable/BpSaved: shift everything above index down by one
        ; row (simple byte-wise move; breakpoint tables are tiny)
        mov     bx, ax
        inc     bx
.compact:
        cmp     bl, [BpCount]
        jae     .compacted
        push    bx
        mov     al, bl
        mov     ah, 4
        mul     ah
        mov     si, BpTable
        add     si, ax
        mov     di, si
        sub     di, 4
        mov     cx, 4
        rep     movsb
        pop     bx
        push    bx
        mov     si, BpSaved
        add     si, bx                   ; BpSaved is 1 byte/row: index == offset
        mov     di, si
        dec     di
        mov     al, [si]
        mov     [di], al
        pop     bx
        inc     bx
        jmp     .compact
.compacted:
        dec     byte [BpCount]
        retn

; RemoveAllBps: restore every currently-patched breakpoint byte.
RemoveAllBps:
        xor     bx, bx
.loop:
        cmp     bl, [BpCount]
        jae     .done
        push    bx
        mov     al, bl
        mov     ah, 4
        mul     ah
        mov     di, BpTable
        add     di, ax
        mov     cx, [di+0]
        mov     dx, [di+2]
        pop     bx
        push    bx
        mov     si, BpSaved
        add     si, bx                   ; BpSaved is 1 byte/row: index == offset
        mov     al, [si]
        push    es
        mov     es, cx
        mov     bx, dx
        mov     [es:bx], al
        pop     es
        pop     bx
        inc     bx
        jmp     .loop
.done:
        retn

; RestoreVectors: put INT 01h/03h back the way DOS had them at startup.
RestoreVectors:
        push    ds
        mov     dx, [OldInt1Off]
        mov     ax, [OldInt1Seg]
        mov     ds, ax
        mov     ax, 2501h
        int     21h
        mov     dx, [OldInt3Off]
        mov     ax, [OldInt3Seg]
        mov     ds, ax
        mov     ax, 2503h
        int     21h
        pop     ds
        retn

; PrintStr: print NUL-terminated string at DS:DX via DOS AH=09h needs '$'
; terminator, so we use INT 21h/AH=02h in a loop instead (NUL-terminated).
; DX can't be used as a memory base on 8086, so the cursor is kept in BX.
PrintStr:
        push    ax
        push    bx
        push    dx
        mov     bx, dx
.loop:
        mov     al, [bx]
        cmp     al, 0
        je      .done
        mov     dl, al
        mov     ah, 2
        int     21h
        inc     bx
        jmp     .loop
.done:
        pop     dx
        pop     bx
        pop     ax
        retn

; PrintCRLF: print CR LF.
PrintCRLF:
        push    ax
        push    dx
        mov     dl, 13
        mov     ah, 2
        int     21h
        mov     dl, 10
        mov     ah, 2
        int     21h
        pop     dx
        pop     ax
        retn

; PrintHexWord: print AX as 4 upper-case hex digits.
PrintHexWord:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     cx, 4
        mov     bx, ax
.loop:
        rol     bx, 1
        rol     bx, 1
        rol     bx, 1
        rol     bx, 1
        mov     al, bl
        and     al, 0Fh
        cmp     al, 10
        jb      .digit
        add     al, 'A' - 10
        jmp     .emit
.digit:
        add     al, '0'
.emit:
        mov     dl, al
        mov     ah, 2
        int     21h
        loop    .loop
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        retn

; ReadLine: read a CR-terminated line from stdin into LineBuf (NUL-terminated,
; CR/LF stripped), echoing characters as typed (DOS buffered input echoes).
ReadLine:
        push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, LineBufReq
        mov     byte [bx], LineBufMax
        mov     dx, LineBufReq
        mov     ah, 0Ah
        int     21h
        mov     ah, 2
        mov     dl, 13
        int     21h
        mov     dl, 10
        int     21h
        xor     bx, bx
        mov     bl, [LineBufReq+1]       ; actual length typed
        mov     byte [LineBuf + bx], 0
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        retn

; ExitNow: terminate todbg itself.
ExitNow:
        mov     ax, 4C00h
        int     21h

; -------------------------------------------------------------------------
; Data
; -------------------------------------------------------------------------
section .data

MaxBps          equ     8

MsgUsage        db      'usage: TODBG program.exe [args]', 13, 10, 0
MsgLoadFail     db      'todbg: could not load child program', 13, 10, 0
MsgReady        db      'todbg: child loaded, stopped at entry point', 13, 10, 0
MsgTraceStop    db      '-- step --', 13, 10, 0
MsgBpHit        db      '-- breakpoint --', 13, 10, 0
MsgPrompt       db      'todbg> ', 0
MsgBadCmd       db      'unknown command (T/G/B/D/R/Q)', 13, 10, 0
MsgBadAddr      db      'bad address, expected XXXX:YYYY', 13, 10, 0
MsgBpSet        db      'breakpoint set', 13, 10, 0
MsgBpFull       db      'breakpoint table full', 13, 10, 0
MsgBpDel        db      'breakpoint removed', 13, 10, 0
MsgBpNone       db      'no such breakpoint', 13, 10, 0
MsgBye          db      'todbg: exiting', 13, 10, 0

LblAX           db      'AX=', 0
LblBX           db      ' BX=', 0
LblCX           db      ' CX=', 0
LblDX           db      ' DX=', 0
LblSI           db      'SI=', 0
LblDI           db      ' DI=', 0
LblBP           db      ' BP=', 0
LblFL           db      ' FL=', 0
LblCSIP         db      'CS:IP=', 0

ChildPath       times 64 db 0
ChildTail       times 128 db 0

DummyFCB        times 37 db 0

; EXEC parameter block (16 bytes we use; DOS AL=01h also returns child's
; initial CS:IP/SS:SP into the same buffer per the note at .load_ok above)
ExecBlock       times 24 db 0

ChildCS         dw      0
ChildIP         dw      0
ChildSS         dw      0
ChildSP         dw      0

OldInt1Off      dw      0
OldInt1Seg      dw      0
OldInt3Off      dw      0
OldInt3Seg      dw      0

SavedAX         dw      0
SavedBX         dw      0
SavedCX         dw      0
SavedDX         dw      0
SavedSI         dw      0
SavedDI         dw      0
SavedBP         dw      0
SavedDS         dw      0
SavedES         dw      0
SavedCS         dw      0
SavedIP         dw      0
SavedFlags      dw      0

BpCount         db      0
BpTable         times   MaxBps * 4 db 0   ; each row: seg(2) + ofs(2)
BpSaved         times   MaxBps     db 0   ; original byte at each patched addr

LineBufMax      equ     127
LineBufReq      db      LineBufMax
                db      0
LineBuf         times   LineBufMax + 1 db 0

; Private debugger stack: used only while control is inside todbg (command
; loop, breakpoint patching, etc). ResumeChild switches SS:SP back onto the
; child's own stack before IRETing into it, so this never needs to be large
; — 512 bytes is generous for a command loop with no recursion.
DbgStackSize    equ     512
                times   DbgStackSize db 0
DbgStackTop:
