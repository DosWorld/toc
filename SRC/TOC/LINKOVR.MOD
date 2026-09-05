(*$D-*)
MODULE LinkOvr;
(*
  Standalone .OVR file writer (DOCS/OVR.MD §11.1).
  /CD only -- never called for a /CP link (Link.CalculateLayout already
  clears every Module.isOverlay when ls^.targetCP is TRUE, so ls^.anyOverlay
  is always FALSE there and TOC.MOD's caller skips this module entirely).

  FILE FORMAT (this project's own from-scratch convention -- DOCS/OVR.MD
  documents the per-module header FIELDS (§6) and the 'DW'-signature
  detection header (§11.1); OVERLAY.MOD's own ReadSegmentFromDisk takes
  fileOfs as an external parameter rather than deriving it from anything
  stored on disk -- there is no separate on-disk directory mapping
  id->file offset. This format is a clean design choice for this
  project -- the CONTRACT between this writer and SRC/LIB/
  OVERLAY.MOD's own reader (RegisterModule/dispatch, DOCS/OVR.MD §11.1)
  -- documented here and in DOCS/OVR.MD.

  Revised 2026-08-08 (DOCS/OVR.MD §11.1's own changelog has the full
  reasoning): dropped the dead `extraLen` field (always written 0, never
  read for anything -- "trailing extra data" was never emitted by this
  writer in the first place) and changed the outer signature from "FB" to
  "DW", shrinking the OUTER file header from 10 to 8 bytes with no loss of
  information. Revised again 2026-08-11: the PER-MODULE header's own
  codeLen field widened WORD->LONGINT (12 bytes now, was 10) -- see that
  field's own entry below.

  OVR-BUG.MD epilogue-counter fix (deliberately NOT a format change):
  an earlier version of this fix widened the per-module header to 16
  bytes (dataParaRel/counterOfs). That was reverted -- BOOT/TOC.EXE (the
  sole bootstrap, CLAUDE.md "never modified by make") has this writer's
  OLD 12-byte form already compiled in, and cannot be updated by an
  agent; a build using BOOT/TOC.EXE to link a fresh, 16-byte-header-
  reading OVERLAY.MOD produces a self-inconsistent binary (new reader +
  old writer) that crashes on its own first real overlay dispatch --
  confirmed via `make test`'s own single-pass build. The counter's
  runtime address is instead derived entirely without new header data:
  see SRC/LIB/OVERLAY.MOD's ReadCounter (reads the DS segment straight
  out of the module's own already-resident, already-patched CgPrologue
  bytes) and SRC/TOC/PARSER.MOD's counter-slot allocation (reuses the
  pre-existing, unconditional 2-byte DATA placeholder at offset 0 --
  Cgen.EmitDataZero(2) -- instead of allocating a new slot, so the
  counter's own DATA offset is always the compile-time constant 0, never
  transmitted at all).

    Offset 0:  "DW" + 6 reserved bytes (OvrHeaderSize=8, matches
               OVERLAY.MOD's DetectFormat 'DW' branch)
    Offset 8:  entryIdCount: WORD -- one past the highest GLOBAL entry id
               used anywhere in the program (Link.State.ovrNextEntryId).
               DOCS/OVR.MD §5: the trampoline's 1-byte id is the trap
               handler's ONLY way to identify which module a trapped call
               site targets, so ids are unique across the WHOLE program
               (Link.Module.ovrEntryIdBase), not per-module -- this
               directory is therefore indexed by GLOBAL id directly, not
               by a separate module index: entry k's owning module's header
               offset is read straight from directory slot k, with no
               extra module-lookup indirection.  Multiple consecutive slots
               legitimately repeat the same fileOfs when they belong to
               the same module (all of module M's entries share one header).
    Offset 10: directory: entryIdCount * (fileOfs: LONGINT; entryOfs: WORD)
               -- fileOfs: byte offset (from file start) of the OWNING
               module's header, one slot per GLOBAL entry id.  entryOfs:
               the in-module code offset that entry id's own exported
               procedure starts at (widened into the directory 2026-08-26,
               DOCS/OVR-ID-WIDEN-PLAN.MD step 2 option (c) -- previously
               baked into every CALL-SITE trampoline's own bytes instead,
               which only worked because it fit alongside a 1-byte id in
               the same 5-byte slot a plain CALL FAR already reserved;
               moving it here instead of widening the call-site format
               keeps every swappable trampoline slot's REQUIRED width at
               `CD 3F id:WORD` = 4 bytes, comfortably under the 5-byte
               ceiling the resident JMP-FAR rewrite form still needs,
               with NO dependency on whether the calling code happens to
               have reserved extra padding -- see that section for the
               full story of why the call-site-embedded design broke).
               entryOfs is per-id, not per-call-site: every site
               targeting the same entry id already had to agree on this
               same value even under the old embedded scheme (Link.OnReloc
               resolves it once per relocation, from the target symbol's
               own SymOffset, identically every time), so this is a
               format relocation, not a semantic change.
    Then, back-to-back, one per module (each written once, pointed at by
    every one of its own entry ids' directory slots):
      module header (12 bytes -- the ON-DISK subset of DOCS/OVR.MD §6; the
                   runtime-only WORDs at +0x12/+0x14/+0x16 -- residentSeg/
                   inUse/next -- are never stored, since they have no
                   meaning until a real load happens):
        +0x00 WORD    fixupLen   (byte length of the self-CODE fixup table)
        +0x02 WORD    xfixupLen  (byte length of the cross-module fixup
                                  table below -- Link.Module.ovrXFixups,
                                  added when the original fixupLen-only
                                  scheme was found to leave every
                                  cross-module DATA/BSS/import SEGRELOC
                                  baked with no load-segment correction at
                                  all: unlike a main-image site, nothing
                                  ever adds the real load segment to .OVR
                                  file content, so ANY load-segment-
                                  relative paragraph baked here -- not
                                  just a self-CODE reference -- needs a
                                  runtime fixup)
        +0x04 LONGINT codeLen    (byte length of the code -- widened from
                                  WORD 2026-08-11: a WORD capped a single
                                  overlay module's code at 65535 bytes with
                                  NO overflow check anywhere in this
                                  writer, so a genuinely large $O+ module
                                  had its real size silently truncated at
                                  link time and its runtime copy silently
                                  corrupted -- see OVERLAY.MOD's
                                  ModuleHeaderDesc.codeLen comment for the
                                  full story)
        +0x08 WORD    siteCount  (entry count of the call-site table below)
        +0x0A WORD    resumeCount (entry count of the resume table below --
                                  Link.Module.ovrResumes, added for
                                  cross-overlay calls, DOCS/OVR.MD §9:
                                  return-address trampolines for calls
                                  THIS module's own code makes into another
                                  overlay module)
      fixup table:    fixupLen/2 WORDs (each an in-code byte offset needing
                        THIS module's own load segment added, Overlay.MOD's
                        ApplyFixups)
      xfixup table:   xfixupLen/2 WORDs (each an in-code byte offset
                        needing the PROGRAM's own load segment added,
                        Overlay.MOD's ApplyXFixups)
      call-site table: siteCount * (siteFileOfs: LONGINT, entryId: WORD,
                        ownerGlobalId: WORD) -- 8 bytes/entry (entryId is
                        the GLOBAL id, matching the trampoline's own id
                        byte; siteFileOfs/ownerGlobalId together locate the
                        site itself -- see Link.OvrSiteNodeRec's own
                        comment for the two cases: ownerGlobalId=OvrNoOwner
                        means siteFileOfs is the FINAL .exe's absolute
                        code-region byte offset (main image, the ordinary
                        case); any other ownerGlobalId means the site lives
                        inside THAT overlay module's own code and siteFileOfs
                        is relative to its own code origin instead --
                        cross-overlay calls, DOCS/OVR.MD §9)
      resume table:   resumeCount * (ofs: WORD, globalId: WORD,
                        calleeGlobalId: WORD) -- 6 bytes/entry
                        (Link.OvrResumeNodeRec).  ofs is THIS module's own
                        in-code offset the return-address trampoline lives
                        at (already patched into the code below at link
                        time, via PatchOverlayCallSite -- this table entry
                        exists so Overlay.MOD can find/re-verify it, not
                        so it can write it for the first time); globalId is
                        the trampoline's own fresh entry id (matches its
                        id byte); calleeGlobalId is the entry id of the
                        module whose call this resume point returns from,
                        needed by Overlay.OvrDispatch to know whose inUse
                        to decrement on resume.
      code:           codeLen bytes, read back from Link.State.ovrSpillFile
                        at the module's own ovrCodeOfs
*)
IMPORT Files, LogErr, Link;

CONST
  OvrHeaderSize = 8;

(* Write one fixup table (a WORD per entry) directly from its chunked list
   -- chunks are head-first (LIFO); order among fixups doesn't matter to
   the runtime (each is an independent offset), so no reversal is needed
   here (unlike OvrEntryId's declaration-order need).  Shared by both
   ovrFixups (self-CODE, destParas addend) and ovrXFixups (cross-module,
   program-load-segment addend) -- same on-disk shape, different table. *)
PROCEDURE WriteFixups(VAR f: Files.File; node: Link.OvrFixupNode);
  VAR k: INTEGER;
BEGIN
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      Files.WriteWord(f, INTEGER(node^.ofs[k])); INC(k)
    END;
    node := node^.next
  END
END WriteFixups;

PROCEDURE WriteSites(VAR f: Files.File; m: Link.Module);
  VAR node: Link.OvrSiteNode; k: INTEGER;
BEGIN
  node := m^.ovrSites;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      Files.WriteDWord(f, node^.siteFileOfs[k]);
      Files.WriteWord(f, INTEGER(node^.entryId[k]));
      Files.WriteWord(f, INTEGER(node^.ownerGlobalId[k]));
      INC(k)
    END;
    node := node^.next
  END
END WriteSites;

(* Write one module's resume table (Link.OvrResumeNodeRec) -- see this
   file's own header comment for the on-disk shape.  Chunks are
   head-first (LIFO); order among resume points doesn't matter to the
   runtime (each is independently keyed by its own globalId), same
   reasoning as WriteFixups. *)
PROCEDURE WriteResumes(VAR f: Files.File; m: Link.Module);
  VAR node: Link.OvrResumeNode; k: INTEGER;
BEGIN
  node := m^.ovrResumes;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      Files.WriteWord(f, INTEGER(node^.ofs[k]));
      Files.WriteWord(f, INTEGER(node^.globalId[k]));
      Files.WriteWord(f, INTEGER(node^.calleeGlobalId[k]));
      INC(k)
    END;
    node := node^.next
  END
END WriteResumes;

(* Point every one of m's own resume points' directory slots at hdrPos --
   mirrors the ordinary entry-id loop in WriteOvrFile below, but walks
   m^.ovrResumes' own chunked list instead of a contiguous index range
   (see WriteOvrFile's own call site comment for why). *)
(* Directory slot stride 6 (widened from 4, DOCS/OVR-ID-WIDEN-PLAN.MD
   step 2 option (c), 2026-08-26).  entryOfs is written as 0 for every
   resume slot -- a resume global id is never dispatched as an ordinary
   entry (OvrDispatch's own isResume branch resolves the real jump
   target from the resume record's own on-disk "ofs" field instead, per
   ResumeCallee's comment elsewhere), so its directory entryOfs column
   is simply unused; 0 is an explicit, well-defined placeholder rather
   than leftover garbage. *)
PROCEDURE DirectResumeDirSlots(VAR f: Files.File; dirBase: LONGINT; m: Link.Module; hdrPos: LONGINT);
  VAR node: Link.OvrResumeNode; k: INTEGER;
BEGIN
  node := m^.ovrResumes;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      Files.Seek(f, dirBase + LONGINT(INTEGER(node^.globalId[k])) * LONGINT(6));
      Files.WriteDWord(f, hdrPos);
      Files.WriteWord(f, 0);
      INC(k)
    END;
    node := node^.next
  END
END DirectResumeDirSlots;

(* Copy exactly n bytes from ls^.ovrSpillFile (positioned by the caller at
   m^.ovrCodeOfs) to f, via Files.BlockCopy -- same technique LinkMZ's
   CopyCodeImage uses for the main image's own spill file.  n is LONGINT
   (matching m^.codeSize/codeLen's own widened type -- see this module's
   own header comment) though Rdoff.SegLimit already keeps any single
   overlay module's real code well under 65535 bytes; Files.BlockCopy itself
   accepts LONGINT and chunks internally regardless. *)
PROCEDURE CopyCode(VAR spill, f: Files.File; n: LONGINT);
BEGIN
  IF n > LONGINT(0) THEN Files.BlockCopy(spill, f, n) END
END CopyCode;

(* Write the standalone .OVR file for every used, isOverlay module.
   Called from TOC.MOD after LinkMZ.PerformLinking (so every Module's
   codePara/dataPara/ovrCodeOfs/ovrEntryIdBase and every OvrSite's
   siteFileOfs are already final).  Closes ls^.ovrSpillFile itself, since
   nothing else ever reads it (unlike the main image's spillFile, which
   LinkMZ.WriteExe consumes). *)
PROCEDURE WriteOvrFile*(ls: Link.State; ovrPath: ARRAY OF CHAR);
  VAR f: Files.File;
      m: Link.Module;
      entryIdCount: WORD;
      dirBase, hdrPos, endPos: LONGINT;
      j: INTEGER;
      entryName: ARRAY 33 OF CHAR;
      entrySym: Link.Symbol;
BEGIN
  IF ~Files.ReWrite(f, ovrPath) THEN
    LogErr.Error2("overlay: cannot create ", ovrPath); RETURN
  END;

  entryIdCount := ls^.ovrNextEntryId;

  Files.Write(f, "DW"); Files.WriteWord(f, 0); Files.WriteDWord(f, LONGINT(0));  (* 8-byte header *)
  Files.WriteWord(f, INTEGER(entryIdCount));

  (* directory: entryIdCount placeholder (fileOfs: LONGINT; entryOfs: WORD)
     pairs -- 6 bytes/slot (widened from a 4-byte fileOfs-only slot,
     DOCS/OVR-ID-WIDEN-PLAN.MD step 2 option (c), 2026-08-26) -- one slot
     per GLOBAL entry id, patched below once each module's real header
     offset (and, for ordinary entries, each entry's own in-module code
     offset) is known (written in one forward pass, so the placeholder-
     then-seek-back pattern mirrors WriteExe's own header patching
     elsewhere in this codebase). *)
  dirBase := Files.Position(f);
  j := 0;
  WHILE j < INTEGER(entryIdCount) DO
    Files.WriteDWord(f, LONGINT(0)); Files.WriteWord(f, 0); INC(j)
  END;

  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & m^.isOverlay THEN
      hdrPos := Files.Position(f);

      Files.WriteWord(f, INTEGER(WORD(m^.ovrNFixups) * 2));
      Files.WriteWord(f, INTEGER(WORD(m^.ovrNXFixups) * 2));
      Files.WriteDWord(f, m^.codeSize);
      Files.WriteWord(f, INTEGER(WORD(m^.ovrNSites)));
      Files.WriteWord(f, INTEGER(WORD(m^.ovrNResumes)));

      WriteFixups(f, m^.ovrFixups);
      WriteFixups(f, m^.ovrXFixups);
      WriteSites(f, m);
      WriteResumes(f, m);

      Files.Seek(ls^.ovrSpillFile, m^.ovrCodeOfs);
      CopyCode(ls^.ovrSpillFile, f, m^.codeSize);
      (* BlockCopy leaves f positioned right after the copied bytes. *)
      endPos := Files.Position(f);

      (* Point every one of this module's own directory slots at
         (hdrPos, entryOfs) -- one write per entry id it owns
         (m^.ovrNEntries of them, starting at m^.ovrEntryIdBase).
         entryOfs is resolved the SAME way Link.OnReloc always has --
         via the entry's own exported symbol's SymOffset -- just moved
         here from the call-site patch (DOCS/OVR-ID-WIDEN-PLAN.MD step 2
         option (c), 2026-08-26): Link.OvrEntryNameAt gives the entry's
         name at this declaration-order index (the SAME order
         Link.OvrEntryId itself walks, so index<->id stays consistent
         with every other consumer of m^.ovrEntryIdBase), FindSymbol
         resolves that name within the WHOLE link state (an exported
         $O+ entry's own symbol, added like any other global), and
         SymOffset gives its in-module code offset -- identical to what
         Link.OnReloc's own `fixup := WORD(SymOffset(lnkLs, sym))`
         already computed for every overlay call site under the old,
         call-site-embedded scheme.  A name that fails to resolve here
         should not happen (every OvrEntryNode name is only ever added,
         PARSER.MOD's AddOvrEntry, for a genuinely exported $O+
         procedure -- see OvrEntryId's own identical assumption) -- 0 is
         written as an intentionally-inert fallback offset rather than
         aborting the whole link over what would be a pre-existing bug
         elsewhere, consistent with this writer's own style of not
         re-validating invariants other passes already guarantee. *)
      j := 0;
      WHILE j < m^.ovrNEntries DO
        Files.Seek(f, dirBase + LONGINT(INTEGER(m^.ovrEntryIdBase) + j) * LONGINT(6));
        Files.WriteDWord(f, hdrPos);
        IF Link.OvrEntryNameAt(m, j, entryName) THEN
          entrySym := Link.FindSymbol(ls, entryName);
          IF entrySym # Link.NoSym THEN
            Files.WriteWord(f, INTEGER(WORD(Link.SymOffset(ls, entrySym))))
          ELSE
            Files.WriteWord(f, 0)
          END
        ELSE
          Files.WriteWord(f, 0)
        END;
        INC(j)
      END;

      (* Same, for this module's own return-address-trampoline (resume)
         points -- their global ids are NOT part of the contiguous
         ovrEntryIdBase..+ovrNEntries-1 range above (allocated later,
         during PerformLinking, as a separate extension of the same
         counter -- Link.AddOvrReturnTrampoline), so each one's directory
         slot needs its own explicit patch, read straight from the
         resume table itself rather than a simple index range. *)
      DirectResumeDirSlots(f, dirBase, m, hdrPos);

      Files.Seek(f, endPos)   (* resume appending where this module's body ended *)
    END;
    m := m^.next
  END;

  (* Trailing DWORD: total .OVR payload length, INCLUDING this trailing
     field itself (Files.Position(f) here is exactly the content written
     so far, i.e. the length WITHOUT the trailing field -- +4 accounts
     for the field about to be appended).  Lets a reader find the start
     of an appended-to-EXE .OVR payload by seeking backward from
     end-of-file, without needing a separate standalone .OVR file at all
     -- added ahead of that feature (DOCS/OVR.MD §12) so the standalone writer already
     produces a payload shaped to be relocatable onto an .EXE's own tail
     later with no format change. *)
  Files.WriteDWord(f, Files.Position(f) + LONGINT(4));

  Files.Close(f);
  IF ~Files.Ok(f) THEN
    LogErr.Error2("overlay: write error (disk full?) on ", ovrPath)
  END;
  Files.Close(ls^.ovrSpillFile)   (* delete-on-close removes the temp *)
END WriteOvrFile;

END LinkOvr.
