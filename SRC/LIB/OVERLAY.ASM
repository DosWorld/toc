bits 16
cpu 8086
%define IS_FAR

; -----------------------------------------------------------------------------
; OVERLAY.ASM -- the pieces of this project's own overlay manager
; (OVERLAY.MOD) that cannot be expressed in Oberon: the INT 3Fh
; trap-handler entry/exit, installing/removing that handler on the
; interrupt vector table, and the raw trampoline-byte patch write.
;
; See DOCS/OVR.MD for the full design this implements. Interrupt vector,
; trampoline byte layout, and the per-segment header format are all
; documented there (DOCS/OVR.MD §5-6); this file implements
; §5's mechanism (the trap-handler shell), with the load/evict
; algorithm and per-module header/table format (§6-8) implemented
; in OVERLAY.MOD, which Ovr_DispatchStub below calls into.
;
; ----- Why this must be assembly, not Oberon -----
; An interrupt handler's entry state (arbitrary caller registers/DS/stack,
; no prologue run yet) cannot be expressed as an Oberon PROCEDURE -- same
; reason SYSTEM.ASM's own IntrReal/IntrDpmi handlers are hand-written.  The
; trampoline patch write is a self-modifying-code write to a CALLER's
; code, not this module's own -- still bound by CLAUDE.md's "no write
; access to [cs:xxx]" rule (added after DOCS/NE-BP.MD section 2.4 bug #6):
; Ovr_PatchTrampoline below writes through the caller-supplied seg:ofs via
; an ordinary ES-relative store, never through CS, so it is unaffected by
; that rule regardless of which segment happens to hold the call site.
;
; ----- Real-mode only -----
; No DPMI16 story exists here yet (DOCS/OVR.MD §14 flags this).  If
; overlay support is ever wanted under DPMI16, the vector-install/restore
; pair below would need the DPMI "Simulate Real Mode Interrupt"-adjacent
; INT 31h services for hooking a REAL-mode vector from protected mode
; (DPMI09.HTM section 9, "raw mode switch" / real-mode interrupt vector
; get-set, AX=0200h/0201h) -- a different mechanism than IntrDpmi's own
; AX=0300h "simulate a real-mode interrupt", which calls OUT to real mode
; rather than hooking a vector for real-mode code to call IN through.
; -----------------------------------------------------------------------------

section .data
; The interrupt number this build's trampolines use.  Fixed at 3Fh
; (confirmed unused elsewhere in this codebase's own
; SYSTEM.ASM/EMS.ASM/DOS.MOD/KMOUSE.MOD -- see DOCS/OVR.MD §5 and
; the maintainer decision recorded in project history).
%define OverlayIntNo 3Fh

installed:      db      0        ; nonzero once Ovr_InstallHandler has run
savedOfs:       dw      0        ; previous vector's offset (chain target)
savedSeg:       dw      0        ; previous vector's segment

; Resident (NEVER swapped -- this whole module is part of the main image,
; not an $O+ module) return-address redirect table (bug fix, 2026-08-08,
; Solution 2 "inUse and eviction-pressure testing" regression -- see
; Link.AddOvrReturnTrampoline's own comment for the full story).  One
; 5-byte INT 3Fh slot per possible resume-trampoline global id (0..255,
; matching the trampoline id's own 1-byte range, DOCS/OVR.MD §5):
; slot i holds `CD 3F i 00 00`.  A cross-overlay call's synthesized
; return address (Ovr_TrapEntry below) points HERE instead of into the
; caller's own overlay code, so it can never go stale no matter how many
; times the caller itself is evicted and reloaded to a different segment
; before the callee actually returns -- this table's own segment is
; fixed for the life of the program.  Overlay_InitResumeTrapTable
; (OVERLAY.MOD) fills every slot at Init time; the two trailing zero
; bytes of each slot are never read (Overlay_ReadTrampolineEntryOfs is
; never called against a resident-table site -- OvrDispatch's resume
; branch resolves the real jump target from the resume table's own "ofs"
; field on disk, not from these bytes) but are written anyway so each
; slot is a well-formed 5-byte trampoline record, matching the on-disk
; shape exactly (simpler to reason about than a deliberately-short slot).
resumeTrapTable: times (256*5) db 0

section .text

%ifdef  IS_FAR
%define RSIZE 4
%define RETMACRO retf
%else
%define RSIZE 2
%define RETMACRO retn
%endif

global  Overlay_InstallHandler, Overlay_RemoveHandler
global  Overlay_PatchTrampoline, Overlay_ReadTrampolineId
global  Overlay_ReadTrampolineEntryOfs
global  Overlay_ResumeTrapTableSeg, Overlay_ResumeTrapTableOfs
global  Overlay_InitResumeTrapTable

; -----------------------------------------------------------------------------
; Overlay_InstallHandler()
; Hooks INT 3Fh: saves the current vector (for chaining/restore) via
; INT 21h/AH=35h, then installs Ovr_TrapEntry via INT 21h/AH=25h.  A
; no-op if already installed (the `installed` flag makes this idempotent
; at the ASM level too, as a second line of defense beyond OVERLAY.MOD's
; own ovrTrapInstalled guard around its one call site in OvrInit).
; Call Type: FAR, no params.
; Result: none.
; -----------------------------------------------------------------------------
Overlay_InstallHandler:
        push    ax
        push    bx
        push    dx
        push    ds
        push    es

        mov     ax, seg installed
        mov     ds, ax
        cmp     byte [installed], 0
        jne     .done

        mov     ah, 35h
        mov     al, OverlayIntNo
        int     21h                     ; ES:BX = current vector
        mov     ax, bx
        mov     [savedOfs], ax
        mov     ax, es
        mov     [savedSeg], ax

        push    cs
        pop     ds
        mov     dx, Ovr_TrapEntry
        mov     ah, 25h
        mov     al, OverlayIntNo
        int     21h

        mov     ax, seg installed
        mov     ds, ax
        mov     byte [installed], 1
.done:
        pop     es
        pop     ds
        pop     dx
        pop     bx
        pop     ax
        RETMACRO        0

; -----------------------------------------------------------------------------
; Overlay_RemoveHandler()
; Restores whatever vector Overlay_InstallHandler saved (INT 21h/AH=25h),
; and clears the installed flag.  A no-op if never installed.  Does NOT
; verify the vector still points at Ovr_TrapEntry before restoring (a
; well-behaved program does not install another INT 3Fh handler on top of
; this one without its own save/chain, same assumption every other
; vector-hooking routine in this codebase makes).
; Call Type: FAR, no params.
; Result: none.
; -----------------------------------------------------------------------------
Overlay_RemoveHandler:
        push    ax
        push    dx
        push    ds

        mov     ax, seg installed
        mov     ds, ax
        cmp     byte [installed], 0
        je      .done

        mov     dx, [savedOfs]
        mov     ax, [savedSeg]
        push    ax
        pop     ds
        mov     ah, 25h
        mov     al, OverlayIntNo
        int     21h

        mov     ax, seg installed
        mov     ds, ax
        mov     byte [installed], 0
.done:
        pop     ds
        pop     dx
        pop     ax
        RETMACRO        0

; -----------------------------------------------------------------------------
; Overlay_PatchTrampoline(siteSeg, siteOfs: WORD; toResident: BOOLEAN;
;                         targetSeg, targetOfs: WORD)
; Rewrites a 5-byte call-site trampoline slot in place -- see DOCS/OVR.MD
; §5 for the two byte forms.  toResident=TRUE writes the resident
; (direct JMP FAR) form using targetSeg:targetOfs.  toResident=FALSE
; rewrites back to the swappable (INT 3Fh) form -- targetSeg/targetOfs
; are then read as (entryId, entryOfs) instead (same two stack slots,
; repurposed by the caller -- OVERLAY.MOD's PatchSitesForModule), and
; WRITTEN into bytes +2/+3..+4: the resident-form write above just did
; (bytes +1..+4 = offset:segment, unconditionally, every time), so bytes
; +2..+4 can no longer be assumed to still hold the entry id/entryOfs the
; ORIGINAL link-time INT 3Fh form had -- restoring the full 5-byte
; swappable form explicitly here, rather than only bytes 0/1 and trusting
; +2..+4 to have survived, is required from the very first evict cycle
; onward (bug found 2026-08-09 via OVRMAINX.MOD's OvrClearBuf-mid-run
; regression: a second load after one evict cycle read garbage entryOfs
; and crashed on a bogus jump target -- entryId is the caller's own
; concern too, cached the same way, see EntryOfsNodeRec's own comment in
; OVERLAY.MOD).
;
; Writes through ES:[siteOfs] against the CALLER-supplied siteSeg -- this
; is a self-modifying-code write to a DIFFERENT segment than this
; procedure's own CS (the call site lives in whatever module made the
; overlaid call, not in OVERLAY.ASM), so it is an ordinary far data write,
; not a same-segment CS write, and is unaffected by CLAUDE.md's "no write
; access to [cs:xxx]" rule (that rule concerns writes through THIS code's
; own CS, e.g. self-patching an immediate operand in the currently
; executing instruction stream -- see SYSTEM.ASM's IntrReal for the one
; place that legitimately needs that; this is not that case).
;
; Call Type: FAR.
; Stack (Oberon's Pascal calling convention pushes arguments LEFT TO
; RIGHT, so the first param lands deepest -- DOCS/OBERLANG.MD "Calling
; convention: Pascal" -- siteSeg is pushed first/deepest, targetOfs last/
; nearest): [siteSeg][siteOfs][toResident][targetSeg][targetOfs]
; Result: none.
; -----------------------------------------------------------------------------
Overlay_PatchTrampoline:
%define pt_siteSeg    bp+RSIZE+10
%define pt_siteOfs    bp+RSIZE+8
%define pt_toResident bp+RSIZE+6
%define pt_targetSeg  bp+RSIZE+4
%define pt_targetOfs  bp+RSIZE+2
        push    bp
        mov     bp, sp
        push    ax
        push    bx
        push    es

        mov     es, word [ss:pt_siteSeg]
        mov     bx, word [ss:pt_siteOfs]

        mov     ax, word [ss:pt_toResident]
        or      ax, ax
        jz      .swappable

        mov     byte [es:bx], 0EAh             ; JMP FAR imm16:imm16
        mov     ax, word [ss:pt_targetOfs]
        mov     [es:bx+1], ax
        mov     ax, word [ss:pt_targetSeg]
        mov     [es:bx+3], ax
        jmp     .done

.swappable:
        mov     byte [es:bx], 0CDh             ; INT imm8
        mov     byte [es:bx+1], OverlayIntNo
        ; bytes +2 (entry id, low byte of pt_targetSeg here) and +3..+4
        ; (entryOfs, pt_targetOfs here) are WRITTEN explicitly -- see this
        ; procedure's own header comment for why they can no longer be
        ; assumed to still hold their original link-time values.
        mov     ax, word [ss:pt_targetSeg]     ; entryId (only AL used --
        mov     [es:bx+2], al                  ; id is a 1-byte field)
        mov     ax, word [ss:pt_targetOfs]     ; entryOfs
        mov     [es:bx+3], ax

.done:
        pop     es
        pop     bx
        pop     ax
        pop     bp
%undef pt_siteSeg
%undef pt_siteOfs
%undef pt_toResident
%undef pt_targetSeg
%undef pt_targetOfs
        RETMACRO        10

; -----------------------------------------------------------------------------
; Overlay_ReadTrampolineId(siteSeg, siteOfs: WORD): BYTE
; Reads back the 1-byte module/entry-point id stored at siteOfs+2 of a
; trampoline slot (see DOCS/OVR.MD §5) -- used by OVERLAY.MOD to
; identify which module a given call site targets when building/inspecting
; the call-site table, without needing its own far-pointer byte read.
; Call Type: FAR.
; Result: BYTE (in AL).
; -----------------------------------------------------------------------------
%define ri_siteSeg bp+RSIZE+4
%define ri_siteOfs bp+RSIZE+2
Overlay_ReadTrampolineId:

        push    bp
        mov     bp, sp
        push    bx
        push    es

        mov     es, word [ss:ri_siteSeg]
        mov     bx, word [ss:ri_siteOfs]
        mov     al, [es:bx+2]

        pop     es
        pop     bx
        pop     bp
%undef ri_siteSeg
%undef ri_siteOfs
        RETMACRO        4

; -----------------------------------------------------------------------------
; Overlay_ReadTrampolineEntryOfs(siteSeg, siteOfs: WORD): WORD
; Reads back the 2-byte in-module code offset stored at siteOfs+3 of a
; trampoline slot -- THIS PROJECT'S OWN use of those bytes (SRC/TOC/LINK.MOD's
; PatchOverlayCallSite; the target module's own code blob is one contiguous
; region and different exported entry points do NOT all start at offset 0
; within it -- DOCS/OVR.MD §11.1 documents the real contract). See
; this file's own header comment and DOCS/OVR.MD §5 for the full
; trampoline layout.
; Call Type: FAR.
; Result: WORD (in AX).
; -----------------------------------------------------------------------------

Overlay_ReadTrampolineEntryOfs:
%define re_siteSeg bp+RSIZE+4
%define re_siteOfs bp+RSIZE+2
        push    bp
        mov     bp, sp
        push    bx
        push    cx
        push    es

        mov     es, word [ss:re_siteSeg]
        mov     bx, word [ss:re_siteOfs]
        mov     cl, [es:bx+3]           ; low byte, single-byte read (matches
                                          ; Overlay_ReadTrampolineId's own
                                          ; proven-reliable byte-at-a-time
                                          ; style, avoiding whatever affects
                                          ; the word-sized form in this
                                          ; caller context)
        mov     ch, [es:bx+4]           ; high byte
        mov     ax, cx

        pop     es
        pop     cx
        pop     bx
        pop     bp
%undef re_siteSeg
%undef re_siteOfs
        RETMACRO        4

; -----------------------------------------------------------------------------
; Overlay_ResumeTrapTableSeg(): WORD
; Returns resumeTrapTable's own segment -- fixed for the life of the
; program (this whole module is resident, never an $O+ module).  OVERLAY.MOD
; needs this to bake a cross-overlay call's synthesized return address as
; resumeTrapTableSeg:slot(globalId) instead of the caller's own (possibly
; soon-stale) resident segment -- see Link.AddOvrReturnTrampoline's own
; comment for the full bug story (2026-08-08).
; Call Type: FAR.  Result: WORD (in AX).
; -----------------------------------------------------------------------------
Overlay_ResumeTrapTableSeg:
        mov     ax, seg resumeTrapTable
        RETMACRO

; -----------------------------------------------------------------------------
; Overlay_ResumeTrapTableOfs(): WORD
; Returns resumeTrapTable's own IN-SEGMENT offset -- NOT assumed to be 0
; (bug found 2026-08-08: `seg resumeTrapTable` alone is not enough,
; resumeTrapTable is not the first item in this module's own merged data
; segment -- installed/savedOfs/savedSeg precede it, 5 bytes, and this
; whole .data section is itself $L-merged into OVERLAY.MOD's own Oberon-
; compiled data, whose own layout is not under this file's control
; either -- landed 5 bytes into the table's own first slot instead of at
; slot 0, executing garbage as code the first time a resume actually
; fired).  OVERLAY.MOD must add this to slot(globalId)'s own byte offset
; (globalId*5), never assume slot 0 sits at the segment's own offset 0.
; Call Type: FAR.  Result: WORD (in AX).
; -----------------------------------------------------------------------------
Overlay_ResumeTrapTableOfs:
        mov     ax, resumeTrapTable
        RETMACRO

; -----------------------------------------------------------------------------
; Overlay_InitResumeTrapTable()
; Fills every one of the 256 5-byte slots in resumeTrapTable with a
; well-formed swappable trampoline `CD 3F <slot index> 00 00` -- called
; once by OVERLAY.MOD's Init.  Unconditional for all 256 slots regardless
; of which ids actually turn out to be resume points (cheaper than a
; directory pre-scan to find out; a slot for an id that's actually an
; ORDINARY entry point is simply never used as a jump target by anything,
; since only resume ids are ever baked as return addresses).
; Call Type: FAR.  Result: none.
; -----------------------------------------------------------------------------
Overlay_InitResumeTrapTable:
        push    bx
        push    cx
        push    dx
        push    es

        mov     ax, ds
        mov     es, ax
        mov     bx, resumeTrapTable
        xor     dx, dx                  ; dx = slot index, 0..255
.loop:
        mov     byte [es:bx], 0CDh             ; INT imm8
        mov     byte [es:bx+1], OverlayIntNo
        mov     al, dl
        mov     byte [es:bx+2], al             ; this slot's own id
        mov     byte [es:bx+3], 0
        mov     byte [es:bx+4], 0
        add     bx, 5
        inc     dl
        jnz     .loop                   ; wraps 255->0 after all 256 slots

        pop     es
        pop     dx
        pop     cx
        pop     bx
        RETMACRO

; -----------------------------------------------------------------------------
; Ovr_TrapEntry -- the actual INT 3Fh handler.
; Standard interrupt prologue/epilogue (push all, DS := this module's own
; .data, STI so a slow disk/EMS load inside the dispatch doesn't run with
; interrupts disabled the whole time, matching SYSTEM.ASM's own IntrReal
; comment on why CLI/STI brackets are kept tight around the genuinely
; unsafe window only).
;
; Reads the return CS:IP off the interrupt stack frame (the trampoline's
; own site -- this is how the handler knows which slot fired: the return
; address the CPU pushed for a software INT IS the byte immediately after
; the CD 3F opcode, i.e. exactly the id-byte/padding region of the
; trampoline slot itself), then calls Ovr_DispatchStub with that
; information.
;
; Ovr_DispatchStub calls Overlay_OvrDispatch (OVERLAY.MOD's real
; per-module lookup, DOCS/OVR.MD §13.3) directly -- a same-module extern
; call from this file's own hand-assembled half into the Oberon-compiled
; half, NOT the cross-.rdf-blob scenario EMS.ASM's header comment
; discusses (that comment is about SEPARATE $L-merged .rdf blobs unable to
; resolve symbols against EACH OTHER; OVERLAY.ASM/OVERLAY.MOD share one
; module's own symbol space the same way SYSTEM.ASM/SYSTEM.MOD or
; EMS.ASM/EMS.MOD do -- this pattern was confirmed supported by this
; project's own maintainer, 2026-08-07: "yes, asm can call other oberon").
;
; ----- Does NOT IRET back into the trampoline site -----
; Earlier version of this handler did a plain IRET, resuming execution AT
; the trampoline site so the CPU would re-fetch/re-decode whatever
; Overlay_OvrDispatch had just patched it to.  That is wrong on two counts
; (found and fixed 2026-08-07, this project's maintainer): (1) the CPU's
; own return-IP push for INT 3Fh is opcode_offset+2, not opcode_offset+5,
; so an unadjusted IRET resumed 3 bytes INTO the trampoline's own id/
; entryOfs payload bytes, which the CPU then decoded as garbage
; instructions; (2) even correctly adjusted to opcode_offset+5, resuming
; at the site at all is unnecessary indirection -- Overlay_OvrDispatch
; already knows the resolved target seg:ofs, and the target procedure
; must see exactly the register/stack state an ordinary CALL FAR would
; have produced (its own RETF returns straight to the ORIGINAL caller,
; never back into this handler).
;
; ----- Does NOT IRET into the target either (found and fixed 2026-08-08,
; this project's maintainer) -----
; A first fix (superseded, see above two counts) tried overwriting the
; interrupt frame's own saved IP:CS in place with the resolved target and
; IRETing into it directly.  That is wrong on a THIRD count, only visible
; once a real callee actually RETURNs (EXAMPLES/OVRDEMO's own demo never
; exercised this until Ovrdemo.Run's call finally resolved correctly):
; INT pushes THREE words (FLAGS, CS, IP), but the trampoline stands in for
; an ordinary CALL FAR, which pushes only TWO (CS, IP) -- IRET into the
; target consumes exactly the three words INT pushed, leaving SP back at
; its PRE-TRAP depth, i.e. as if the call-site instruction had never
; pushed anything at all.  The target's own eventual RETF then pops
; whatever garbage was ALREADY on the caller's stack below that point
; (some unrelated saved value), landing anywhere -- confirmed via xt
; trace: RETF landed back on the trampoline's own INT 3Fh opcode, which
; re-fired the SAME trap a second time, producing the demo's own
; characteristic doubled output before eventually running off into
; invalid opcodes.
;
; The fix: synthesize a genuine CALL-FAR-shaped stack for the target
; instead of an INT-shaped one.  [bp+10]/[bp+12] (the interrupt frame's
; saved IP/CS slots) are overwritten with the REAL return address --
; site segment : opcode offset+5 (one past the 5-byte trampoline, i.e.
; exactly the caller's own next instruction after its now-rewritten CALL
; FAR) -- turning those two slots from "the trap's own return point" into
; "the ordinary return address a CALL FAR at the site would have pushed".
; The interrupt's own FLAGS word (at [bp+14], never touched otherwise) is
; POPped off and discarded before the jump -- CALL FAR never pushes FLAGS
; at all, so the target must NOT inherit an extra stack word it doesn't
; expect; discarding it here (rather than restoring it via POPF) leaves
; the caller's FLAGS exactly as the interrupted CALL-FAR-equivalent
; instruction left them, unmodified, matching what an ordinary CALL FAR
; does (CALL FAR is FLAGS-transparent: the callee simply keeps running
; under whatever FLAGS the caller already had). What's left on the stack
; after that pop is exactly {targetIP, targetCS} -- an ordinary far call
; frame -- so a plain JMP FAR to the resolved target is now equivalent to
; CALL FAR having executed at the original site: the target's own RETF
; pops that frame and returns straight to the real caller, never back
; into this handler.
;
; AX/BX/CX/DX are NOT saved/restored -- they're pure scratch here.  A
; plain CALL FAR at the original site wouldn't have preserved them into
; the callee either (ordinary Pascal calling convention: caller-saved),
; so the target proc gets no guarantee about their contents regardless of
; whether the call went through this trap or not.  Only SI/DI/BP/DS/ES
; are saved/restored -- the ones this handler itself uses as a stack
; frame / working segments that must not leak into the target's own view
; of "whatever the interrupted caller last had there".
; -----------------------------------------------------------------------------
; PASCAL CALLING CONVENTION applies to every Oberon call this file makes
; (Overlay_OvrDispatch below) -- arguments pushed LEFT TO RIGHT, callee
; pops them via RETF n. Ovr_TrapEntry itself is reached via a hardware
; INT, not a call, so it has no formal parameters of its own -- only a
; local, hand-built register-save frame -- but every BP-relative slot in
; it is still %define'd here, matching Overlay_PatchTrampoline/
; Overlay_ReadTrampolineId/Overlay_ReadTrampolineEntryOfs's own style,
; so the frame layout is self-documenting instead of bare-offset
; arithmetic:
;   [bp+0]  = saved ES  (pushed last, 5th)
;   [bp+2]  = saved DS  (pushed 4th)
;   [bp+4]  = saved BP  (pushed 3rd)
;   [bp+6]  = saved DI  (pushed 2nd)
;   [bp+8]  = saved SI  (pushed 1st/deepest of the 5)
;   [bp+10] = CPU-pushed IP  (INT 3Fh's own return address)
;   [bp+12] = CPU-pushed CS  (the trampoline site's own segment)
;   [bp+14] = CPU-pushed FLAGS
%define te_savedES   bp+0
%define te_savedDS   bp+2
%define te_savedBP   bp+4
%define te_savedDI   bp+6
%define te_savedSI   bp+8
%define te_retIP     bp+10
%define te_retCS     bp+12
%define te_retFLAGS  bp+14
Ovr_TrapEntry:
        push    si
        push    di
        push    bp
        push    ds
        push    es

        mov     ax, seg installed
        mov     ds, ax
        sti

        mov     bp, sp
        mov     bx, [te_retIP]          ; return IP (pushed by the CPU under
                                          ; the 5 registers above: 5*2=10) --
                                          ; this is opcode_offset+2 (the byte
                                          ; right after CD 3F, i.e. the id
                                          ; byte's own offset), NOT the
                                          ; opcode's own offset
        sub     bx, 2                   ; BX := opcode's own offset, so it
                                          ; matches every other function's
                                          ; contract (Overlay_ReadTrampolineId/
                                          ; Overlay_PatchTrampoline both take
                                          ; the OPCODE offset, reading/writing
                                          ; the id byte at +2 themselves)
        mov     cx, [te_retCS]          ; return CS (the site's own segment)

        call    Ovr_DispatchStub        ; BX=site ofs (opcode offset), CX=site seg on
                                          ; entry; returns DX:AX = target
                                          ; seg:ofs, CX=isResume (0/1),
                                          ; DI:SI=return seg:ofs (stale-
                                          ; return-address fix, 2026-08-08)
                                          ; -- BX is preserved across the
                                          ; call (still the site's own
                                          ; opcode offset), but CX/DI/SI
                                          ; are NOT: they come back holding
                                          ; the stub's own return values
                                          ; instead (see Ovr_DispatchStub's
                                          ; own header comment)

        or      cx, cx
        jnz     .resume

        ; ----- Ordinary entry point: synthesize a CALL-FAR-shaped frame -----
        ; Replace the interrupt frame's own saved IP:CS -- [bp+10]/[bp+12],
        ; the SAME stack slots the CPU's INT 3Fh push put IP/CS into -- with
        ; the REAL return address Overlay_OvrDispatch computed (DI:SI,
        ; stale-return-address fix, 2026-08-08).  This turns the interrupt
        ; frame into an ordinary CALL-FAR-shaped return frame for whatever
        ; we jump to below, so the target's own eventual RETF pops a valid
        ; address and returns straight to the ORIGINAL caller.
        ; Previously this was always synthesized right here in ASM as
        ; site_seg:site_ofs+5 (site segment untouched in [bp+12], only
        ; [bp+10] updated) -- correct ONLY as long as the caller's own
        ; segment never changes before the callee returns.  For a
        ; cross-overlay call, the caller CAN be evicted-and-reloaded
        ; elsewhere in between (confirmed via a 3-module regression, see
        ; Link.AddOvrReturnTrampoline's own comment for the full story),
        ; so the segment half must come from Overlay_OvrDispatch now,
        ; which redirects through a never-moving resident table for that
        ; specific case (site_seg:site_ofs+5 unchanged for the ordinary,
        ; still-safe resident-caller case -- Overlay_OvrDispatch's own
        ; default is exactly that value, so this is a strict superset of
        ; the old behavior, not a divergent path).
        ;
        ; (2026-08-13: a bug #4 investigation briefly replaced this
        ; bp-relative write with a BX:CX-relayed, purely SP-relative
        ; version, theorizing SS:SP could be disturbed across
        ; Overlay_OvrDispatch's own call chain (it does real disk I/O via
        ; SYSTEM.Intr, which SYSTEM.ASM's own IntrReal documents CAN
        ; corrupt SS:SP for some INT 21h calls).  That fix built and ran
        ; correctly but did NOT resolve bug #4 -- tracing after the fix
        ; proved the wrong value (matching the pre-trap caller's own DI)
        ; is already present in DI/SI by the time THIS code runs, i.e.
        ; BEFORE any bp-relative addressing happens at all.  The real bug
        ; is upstream, inside Overlay_OvrDispatch's own retSegOut
        ; computation or FindSiteOwner's call-site scan -- reverted back
        ; to the original bp-relative form here, which is not implicated.
        ; See EXAMPLES/OVRDEMO/repro7_loop_call/README.md for the full,
        ; still-open investigation.) *)
        mov     [te_retIP], si          ; real return offset
        mov     [te_retCS], di          ; real return segment
        jmp     .frame_done

.resume:
        ; ----- Resume point: NOT a call site -- do not synthesize a frame.
        ; This id is one of a caller's own return-address trampolines: a
        ; callee's RETF just landed here, so the stack is ALREADY exactly
        ; call-frame-shaped for the code being resumed (see
        ; Overlay_OvrDispatch's own header comment for the full reasoning).
        ; Simply discard this trap's own interrupt frame -- FLAGS/CS/IP,
        ; none of which lead anywhere real, since this trap did not stand
        ; in for a CALL FAR -- and jump straight to the resolved target;
        ; the target's own eventual RETF pops the REAL caller's frame that
        ; was already sitting there underneath, untouched.
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si
        add     sp, 6                   ; discard this trap's own IP/CS/FLAGS
                                          ; (nothing downstream ever returns
                                          ; here -- this trap did not stand in
                                          ; for a CALL FAR)
        push    dx                      ; target segment
        push    ax                      ; target offset
        retf                            ; plain far jump to the resumed code;
                                          ; its own eventual RETF pops the
                                          ; REAL caller's frame, already
                                          ; sitting untouched below where this
                                          ; trap's own frame just was

.frame_done:
        pop     es
        pop     ds
        pop     bp
        pop     di
        pop     si

        ; SP now points at {return_ofs, return_seg, FLAGS} (in that order,
        ; low to high address).  Pop the real return address into DI:SI
        ; (pure scratch at this point -- already restored above), discard
        ; FLAGS (CALL FAR never pushes one, so the target must not inherit
        ; an extra stack word it doesn't expect), then push the RESOLVED
        ; target's own seg:ofs (DX:AX from Ovr_DispatchStub) followed by
        ; the real return address back on top -- an ordinary far-call
        ; return frame with the target reachable via RETF (the standard
        ; indirect-far-jump trick, no memory operand needed).
        pop     si                      ; real return offset
        pop     di                      ; real return segment
        add     sp, 2                   ; discard FLAGS
        push    di                      ; real return segment
        push    si                      ; real return offset
        push    dx                      ; target segment
        push    ax                      ; target offset
        retf                            ; jumps to target seg:ofs; target's
                                          ; own eventual RETF pops the real
                                          ; return address left below,
                                          ; returning straight to the
                                          ; ORIGINAL caller, never back here
%undef te_savedES
%undef te_savedDS
%undef te_savedBP
%undef te_savedDI
%undef te_savedSI
%undef te_retIP
%undef te_retCS
%undef te_retFLAGS

extern  Overlay_OvrDispatch

; -----------------------------------------------------------------------------
; Ovr_DispatchStub(BX=site offset, CX=site segment): DX:AX = target seg:ofs,
; CX = isResume (0/1), DI:SI = return seg:ofs (stale-return-address fix,
; 2026-08-08 -- see Overlay_OvrDispatch's own header comment) -- CX
; overwrites the site-segment CX had on entry, since Ovr_TrapEntry has
; already used it (folded into [bp+12]) by the time this returns.
; Calls Overlay_OvrDispatch(siteSeg, siteOfs, VAR targetSeg, VAR targetOfs,
; VAR isResumeOut, VAR retSegOut, VAR retOfsOut) -- OVERLAY.MOD's real
; per-module lookup/load/evict logic (DOCS/OVR.MD §13.3), which resolves
; and returns the far address to jump to, whether this id was a resume
; point, and which return address Ovr_TrapEntry should synthesize for an
; ordinary entry.  Oberon's own Pascal calling convention pushes arguments
; LEFT TO RIGHT (DOCS/OBERLANG.MD "Calling convention: Pascal"), so
; siteSeg (the first formal) is pushed first/deepest, siteOfs next; a VAR
; actual pushes {segment, offset} as 4 bytes, segment first/deeper
; (DOCS/OBERLANG.MD "Pushing a far pointer") -- targetSeg's slot is pushed
; before targetOfs's, before isResumeOut's, before retSegOut's, before
; retOfsOut's, matching the formal order.
; DS/ES/BX/CX are already this procedure's own working registers at entry
; (from Ovr_TrapEntry), saved/restored here since the Oberon callee is free
; to clobber them.  NEAR proc, called only from Ovr_TrapEntry above.
; -----------------------------------------------------------------------------
; BP-relative locals frame, so the address arithmetic for the five VAR
; out-param actuals is fixed and readable instead of tracked by hand
; across a chain of PUSHes.  The locals are reserved FIRST, right after the
; BP/SP prologue, so pushing the callee-saved registers afterward cannot
; collide with their slots.  %define'd here, matching every other
; procedure in this file, so the frame layout is self-documenting:
;   [bp-2]   = targetSeg local
;   [bp-4]   = targetOfs local
;   [bp-6]   = isResumeOut local
;   [bp-8]   = retSegOut local
;   [bp-10]  = retOfsOut local
;   [bp-12]  = saved BX (site offset, from Ovr_TrapEntry)
;   [bp-14]  = saved CX (site segment, from Ovr_TrapEntry)
;   [bp-16]  = saved SI (caller's, pure scratch here)
;   [bp-18]  = saved DI (caller's, pure scratch here)
%define ds_targetSeg    bp-2
%define ds_targetOfs    bp-4
%define ds_isResumeOut  bp-6
%define ds_retSegOut    bp-8
%define ds_retOfsOut    bp-10
%define ds_savedBX      bp-12
Ovr_DispatchStub:
        push    bp
        mov     bp, sp
        sub     sp, 10                  ; [bp-2]..[bp-10], five WORD locals
        push    bx
        push    cx
        push    si
        push    di

        ; Actuals pushed LEFT TO RIGHT (first formal deepest): siteSeg,
        ; siteOfs, targetSeg, targetOfs, isResumeOut, retSegOut, retOfsOut
        ; -- PASCAL CALLING CONVENTION, matching Overlay_OvrDispatch's own
        ; Oberon formal-parameter order exactly (DOCS/OBERLANG.MD "Calling
        ; convention: Pascal").
        push    cx                      ; siteSeg
        push    bx                      ; siteOfs
        ; targetSeg actual (VAR): {segment=SS, offset=addr of [ds_targetSeg]}
        push    ss
        lea     ax, [ds_targetSeg]
        push    ax
        ; targetOfs actual (VAR): {segment=SS, offset=addr of [ds_targetOfs]}
        push    ss
        lea     ax, [ds_targetOfs]
        push    ax
        ; isResumeOut actual (VAR): {segment=SS, offset=addr of [ds_isResumeOut]}
        push    ss
        lea     ax, [ds_isResumeOut]
        push    ax
        ; retSegOut actual (VAR): {segment=SS, offset=addr of [ds_retSegOut]}
        push    ss
        lea     ax, [ds_retSegOut]
        push    ax
        ; retOfsOut actual (VAR): {segment=SS, offset=addr of [ds_retOfsOut]}
        push    ss
        lea     ax, [ds_retOfsOut]
        push    ax
        call    far Overlay_OvrDispatch

        mov     ax, [ds_targetOfs]
        mov     dx, [ds_targetSeg]
        mov     cx, [ds_isResumeOut]    ; isResume flag (0/1)
        mov     di, [ds_retSegOut]      ; return segment (stale-return-
                                          ; address fix)
        mov     si, [ds_retOfsOut]      ; return offset
        ; BX must still come back to Ovr_TrapEntry UNCHANGED (it still
        ; needs the site's own opcode offset after this call, for the
        ; ordinary-entry "add bx,5" -- see Ovr_TrapEntry's own comment) --
        ; restore it from the pushed save.  CX/SI/DI's ORIGINAL (caller's)
        ; values are NOT restored: Ovr_TrapEntry has already consumed
        ; everything else it needed from them before this call (site seg
        ; folded into te_retCS), and CX/SI/DI are now this stub's own
        ; RETURN values instead.
        mov     bx, [ds_savedBX]        ; the pushed bx save (right below
                                          ; the five WORD locals)
        mov     sp, bp                  ; discards the five locals AND the
                                          ; four pushed registers below
                                          ; them in one step
        pop     bp
%undef ds_targetSeg
%undef ds_targetOfs
%undef ds_isResumeOut
%undef ds_retSegOut
%undef ds_retOfsOut
%undef ds_savedBX
        ret
