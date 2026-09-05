(*$D-,O-,R-,A-*)
MODULE Overlay;
(*
  Overlay manager -- this project's own runtime for its own $O+ overlay
  scheme (see DOCS/OVR.MD for the full design; section references below
  point back into that document).

  STATUS (DOCS/OVR.MD §16): complete.  OvrDispatch below resolves a
  trapped trampoline's global entry id against the real on-disk
  directory, registers/loads/evicts ModuleHeader records against the real
  per-module header/fixup/call-site/resume tables, and patches every
  affected trampoline via Overlay_PatchTrampoline -- including
  cross-overlay calls (DOCS/OVR.MD §9) and real eviction of an idle
  caller under buffer pressure (DOCS/OVR.MD §10).  Deliberately simpler
  than a full-featured overlay manager (DOCS/OVR.MD §17): no
  ring-buffer/probation eviction (this project's own rule is "never
  evict inUse#0", with real per-call inUse nesting -- §10).

  This is a normal stdlib module (SRC/LIB/OVERLAY.MOD, built into
  OBERON.OM alongside Files/Out/EMS/etc.) -- any program imports it with
  a plain IMPORT Overlay.

  The INT 3Fh trap handler, vector install/remove, and the raw trampoline
  patch write live in OVERLAY.ASM (cannot be expressed in Oberon --
  see that file's own header comment for why); OvrDispatch below is the
  Oberon procedure OVERLAY.ASM's Ovr_DispatchStub calls into.

  Naming uses `Ovr*` names (Init, OvrSetBuf, ...) rather than this
  project's usual PascalCase-without-prefix convention, matching this
  module's own role as the project's overlay-management interface.
*)
IMPORT Files, Strings, Dos, EMS;

CONST
  ovrOk*           =  0;
  ovrError*        = -1;
  ovrNotFound*     = -2;
  ovrNoMemory*     = -3;
  ovrIOError*      = -4;
  ovrNoEMSDriver*  = -5;
  ovrNoEMSMemory*  = -6;

  MinHeapParas = 16;         (* OvrSetBuf's minimum, mirroring MEM_INIT's own
                                 "at least 16 paragraphs" floor in SYSTEM.ASM *)
  ParaSize     = 16;
  NumHeapBlocks = 2;         (* Multi-block overlay buffer (2026-08-21,
                                 OVR-BUG.MD follow-up): SYSTEM.Alloc hands
                                 out one DOS block at a time, hard-capped
                                 near 64KB (WORD paras * WORD ParaSize must
                                 itself fit a WORD) -- a single such block
                                 cannot hold every module that can be
                                 legitimately resident AT ONCE (the module
                                 currently executing, pinned by inUse/its
                                 own epilogue counter, PLUS whatever it
                                 calls into) once the overlay module pool
                                 grew large enough (PExpr2.MOD).  OvrSetBuf
                                 allocates NumHeapBlocks independent blocks
                                 instead of one; every block runs its own
                                 independent bump-pointer-with-wraparound
                                 allocator (LoadModule tries block 0 first,
                                 exactly the original single-block logic,
                                 falling over to block 1 only once block 0's
                                 own eviction loop is truly exhausted) --
                                 see LoadModule's own comment. *)
  PageSize     = 16384;      (* EMS page size, DOCS/OVR.MD §13.7 --
                                 EMS.MOD's own page-mapped copy granularity,
                                 NOT this module's scratch-buffer size (see
                                 PrimeEmsChunk below: a 16 KB stack local
                                 would overflow this project's 8 KB default
                                 $M stack on its own) *)
  PrimeEmsChunk = 1024;      (* PrimeEmsFromDisk's disk->EMS scratch buffer
                                 size -- stack-safe against the 8 KB default
                                 $M stack (DOCS/BUILD.MD "Defaults... stack=
                                 8192"); EMS.CopyToEMS itself still moves
                                 data through EMS in full 16 KB pages
                                 internally regardless of this chunk size *)

  (* Standalone .OVR file custom-header signature: 'D','W' at offset 0, or
     'O','V' at offset 2 (DOCS/OVR.MD §11) -- checked directly in
     DetectFormat rather than as named CONSTs, since this dialect's CONST
     declarations only accept integer-family types, not CHAR. *)
  OvrHeaderSize = 8;         (* the header read length Init uses *)

  (* Per-module on-disk header size (DOCS/OVR.MD §11.1, §6): fixupLen(2) +
     xfixupLen(2) + codeLen(4) + siteCount(2) + resumeCount(2) = 12 bytes.
     Widened from 10 (codeLen WORD -> LONGINT) 2026-08-11 -- see
     ModuleHeaderDesc's own codeLen comment.  Deliberately NOT widened
     again for the OVR-BUG.MD epilogue-counter fix -- BOOT/TOC.EXE (the
     sole bootstrap) has this writer's old form permanently compiled in
     and cannot be updated by an agent; see ModuleHeaderDesc's own
     dataParaRel/counterOfs comments (removed) and ReadCounter below for
     how the fix avoids needing any new on-disk field at all. *)
  ModuleHdrSize = 12;

  (* Call-site table ownerGlobalId sentinel -- matches Link.OvrNoOwner
     exactly (SRC/TOC/LINK.MOD); "this site lives in the main image, not
     inside another overlay module's own code" (cross-overlay calls,
     DOCS/OVR.MD §9). *)
  OvrNoOwner = 0FFFFH;

  EntryOfsChunk = 8;  (* EntryOfsNodeRec's own per-node entry count -- see
                          that record's own comment *)
  SiteChunk = 8;      (* SiteNodeRec's own per-node entry count -- see
                          that record's own comment *)
  ResumeChunk = 8;    (* ResumeNodeRec's own per-node entry count -- see
                          that record's own comment *)

TYPE
  (* HeapBlockDesc: one independent overlay-buffer block (2026-08-21,
     OVR-BUG.MD follow-up -- see NumHeapBlocks' own comment).  orgParas/
     ptrParas/endParas are exactly the original single-buffer
     ovrHeapOrg/Ptr/EndParas fields, now per-block; buf mirrors the
     original ovrHeapBuf (the real SYSTEM.Alloc pointer, needed for
     SYSTEM.Free). *)
  HeapBlockDesc = RECORD
    buf: SYSTEM.ADDRESS;
    orgParas, ptrParas, endParas: WORD
  END;

  (* Per-module header record layout, DOCS/OVR.MD §6.  hdrFileOfs is
     NOT part of the original's DATA-segment layout (it has no equivalent
     offset in DOCS/OVR.MD's table) -- it is this port's own bookkeeping,
     the on-disk byte offset (DOCS/OVR.MD §11.1's directory
     format) this in-memory record was built from, used to recognise
     "already registered" modules when multiple entry ids share one header
     (RegisterModule below). *)
  (* entryOfs cache, one entry per DISTINCT entryId this module's own
     call-site table has ever presented to PatchSitesForModule (chunked,
     CLAUDE.md "Chunk small records" -- a (WORD,WORD) pair is far below
     the 32-byte threshold and a module's own entry count is unbounded).
     Exists because Overlay_PatchTrampoline's resident (JMP FAR) form
     PERMANENTLY overwrites a swappable trampoline's own entry-id/entryOfs
     bytes (+2..+4) with the jump target's offset:segment -- so once a
     site has been patched resident even once, ReadTrampolineEntryOfs can
     never again recover the real entryOfs from ITS bytes on a later
     evict-then-reload cycle (bug found 2026-08-09 via OVRMAINX.MOD's
     OvrClearBuf-mid-run regression: the second Ovrdemo.Run crashed with
     a bogus jump target, traced to exactly this).  Fix: read entryOfs
     from the trampoline bytes only the FIRST time a given entryId is
     ever seen (while its bytes are still the pristine link-time form,
     unconditionally true the first time PatchSitesForModule visits it),
     cache it here, and reuse the cached value on every later patch --
     never re-reading the (possibly by-then-corrupted) trampoline bytes
     for a repeat entryId. *)
  EntryOfsNode* = POINTER TO EntryOfsNodeRec;
  EntryOfsNodeRec* = RECORD
    entryId*:  ARRAY EntryOfsChunk OF WORD;
    entryOfs*: ARRAY EntryOfsChunk OF WORD;
    count*:    INTEGER;
    next*:     EntryOfsNode
  END;

  (* Call-site table cache, one entry per row of DOCS/OVR.MD §8's own
     on-disk call-site table (siteFileOfs, entryId, ownerGlobalId -- 8
     bytes/entry on disk), chunked per CLAUDE.md "Chunk small records".
     Exists because FindSiteOwner/PatchSitesForModule used to re-read this
     WHOLE table from disk (Files.Seek + one Files.BlockRead PER ENTRY)
     on every single dispatch through the owning module, even a REPEAT
     dispatch that changes nothing about the table itself -- found while
     chasing DOCS/OVR.MD §16's "severe performance regression" ($O+
     Def/LinkNE): confirmed via isolated xt reproducers that dispatch
     cost scales with siteCount, not just call count (a 30-site module
     costs ~5x more per dispatch than a 1-site module at the same call
     volume) -- consistent with an O(dispatches * siteCount) linear
     disk-rescan.  Filled once by RegisterModule (mirroring how
     ReadModuleHeader8 already reads the fixed header once); every
     later FindSiteOwner/PatchSitesForModule call reads this in-memory
     copy instead of re-opening the file. *)
  SiteNode* = POINTER TO SiteNodeRec;
  SiteNodeRec* = RECORD
    siteFileOfs*:    ARRAY SiteChunk OF LONGINT;
    entryId*:        ARRAY SiteChunk OF WORD;
    ownerGlobalId*:  ARRAY SiteChunk OF WORD;
    count*:          INTEGER;
    next*:           SiteNode
  END;

  (* Resume-point table cache, mirroring SiteNodeRec above but for
     DOCS/OVR.MD §9's resume table (ofs, globalId, calleeGlobalId -- 6
     bytes/entry on disk) -- ResumeCallee/FindResumeGlobalId had the
     exact same unconditional per-dispatch disk-rescan problem SiteNode
     above fixes for the call-site table. *)
  ResumeNode* = POINTER TO ResumeNodeRec;
  ResumeNodeRec* = RECORD
    ofs*:             ARRAY ResumeChunk OF WORD;
    globalId*:        ARRAY ResumeChunk OF WORD;
    calleeGlobalId*:  ARRAY ResumeChunk OF WORD;
    count*:           INTEGER;
    next*:            ResumeNode
  END;

  ModuleHeader* = POINTER TO ModuleHeaderDesc;
  ModuleHeaderDesc* = RECORD
    hdrFileOfs*:   LONGINT;  (* this port's own: on-disk header offset *)
    fixupLen*:     WORD;     (* +0x00: internal fixup table byte length --
                                 self-CODE fixups, this module's own load
                                 segment (destParas) addend *)
    xfixupLen*:    WORD;     (* +0x02: cross-module fixup table byte length
                                 -- Link.Module.ovrXFixups, program-load-
                                 segment addend (LINKOVR.MOD's own header
                                 comment) *)
    codeLen*:      LONGINT;  (* +0x04: on-disk code byte length -- widened
                                 from WORD 2026-08-11: a WORD capped a
                                 single overlay module's code at 65535 bytes
                                 with NO overflow check anywhere in the
                                 linker, so a genuinely large $O+ module
                                 (SRC/TASM/TURBODIR.MOD, ~2600 lines) had
                                 its real codeLen silently truncated at
                                 link time -- LoadModule then copied only
                                 the truncated byte count, and the module's
                                 real (larger) code ran off into whatever
                                 memory followed the truncated copy,
                                 producing a garbage jump / infinite loop
                                 with no diagnostic at all.  See
                                 DOCS/OVR.MD §11.1 for the widened on-disk
                                 layout (12-byte module header now, was 10). *)
    siteCount*:    WORD;     (* +0x08: call-site patch table entry count *)
    resumeCount*:  WORD;     (* +0x0A: resume-point (return-address
                                 trampoline) table entry count --
                                 cross-overlay calls, DOCS/OVR.MD §9 *)
    residentSeg*:  WORD;     (* +0x12: 0 = not loaded, else the load segment *)
    inUse*:        WORD;     (* +0x14: nonzero while a call is active *)
    next*:         ModuleHeader; (* +0x16: OvrLoadList chain *)
    entryOfsCache*: EntryOfsNode; (* this port's own: see EntryOfsNodeRec *)
    siteCache*:    SiteNode;    (* this port's own: see SiteNodeRec -- NIL
                                    until LoadSiteCache below has run once
                                    (siteCount=0 modules never need it) *)
    resumeCache*:  ResumeNode;  (* this port's own: see ResumeNodeRec --
                                    NIL until LoadResumeCache below has run
                                    once (resumeCount=0 modules never need
                                    it) *)
    tablesCached*: BOOLEAN      (* this port's own: TRUE once
                                    LoadSiteCache/LoadResumeCache have both
                                    run for this module -- guards against
                                    re-reading on a later RegisterModule
                                    hit, distinct from siteCache/
                                    resumeCache staying NIL when the real
                                    on-disk count is 0 *)
  END;

VAR
  i: INTEGER;  (* module BEGIN block's own loop var, zeroing ovrHeaps
                  (see NumHeapBlocks' own comment; this runtime does not
                  zero-init module globals, project-wide rule) *)
  (* ---- state mirroring the original's DATA-segment globals, DOCS/OVR.MD
     §6 ---- *)
  ovrDosHandle: Files.File;
  ovrHaveHandle: BOOLEAN;      (* ovrDosHandle actually open (Files.File has
                                   no defined "closed" sentinel value to test) *)
  ovrFileBase:  LONGINT;
  ovrPayloadStart: LONGINT;   (* DOCS/OVR.MD §12, "Appended-to-EXE overlay
                                  file format": the payload's own byte 0, as a
                                  real offset into ovrDosHandle -- 0 for a
                                  standalone .OVR file, nonzero when the
                                  SAME payload has been concatenated onto
                                  an .EXE's own tail.  Every directory
                                  value LinkOvr.WriteOvrFile writes
                                  (DirEntry's return value, and so every
                                  hdrFileOfs derived from it) is relative
                                  to the PAYLOAD's own byte 0, not the
                                  real file's -- DirEntry adds this to
                                  turn that into a real Files.Seek
                                  target, so every downstream consumer
                                  (ReadModuleHeader8, codeFileOfs, …) needs
                                  no change of its own. *)
  ovrFileMode:  BYTE;

  ovrHeaps: ARRAY NumHeapBlocks OF HeapBlockDesc;
  ovrHeapSizeParas: WORD;
  ovrRetrySize: LONGINT;

  ovrLoadList:  ModuleHeader;
  ovrResult:    INTEGER;
  ovrTrapCount, ovrLoadCount: WORD;

  (* ---- DOCS/OVR.MD §11.1: the real .OVR directory, loaded once by
     Init.  entryIdCount global entry ids, each
     slot a LONGINT file offset of the owning module's on-disk header --
     see LoadDirectory. *)
  ovrEntryIdCount: WORD;
  ovrDirectory:    SYSTEM.ADDRESS;  (* heap block: ovrEntryIdCount LONGINTs *)

  ovrEmsHandle: WORD;
  ovrEmsPages:  WORD;
  ovrUseEms:    BOOLEAN;       (* TRUE after a successful InitEMS --
                                   selects which reader OvrReadSegment uses *)

  ovrTrapInstalled: BOOLEAN;   (* guards against installing the INT 3Fh
                                   vector twice if Init is called more
                                   than once *)
  prevExitProc: SYSTEM.ADDRESS; (* saved by Init before installing
                                    ExitCleanup, so it can chain onward --
                                    see ExitCleanup's own comment *)
  ovrResumeTrapTable: SYSTEM.ADDRESS; (* heap block: ovrEntryIdCount 4-byte
                                   slots (DOCS/OVR-ID-WIDEN-PLAN.MD steps 1+2,
                                   2026-08-26) -- used to be a fixed
                                   256-slot static array in OVERLAY.ASM;
                                   now SYSTEM.Alloc'd by Init, sized to the
                                   real program's own ovrEntryIdCount, same
                                   idiom as ovrDirectory below.  Segment is
                                   fixed once allocated (never freed/moved
                                   again for the life of the program, same
                                   guarantee the old static array gave —
                                   Stale-return-address fix, 2026-08-08,
                                   see Link.AddOvrReturnTrampoline's own
                                   comment). *)
  ovrResumeTrapTableSeg: WORD; (* cached segment half of ovrResumeTrapTable,
                                   extracted the same way AllocHeapBlock's
                                   own comment documents (LONGINT(blk) DIV
                                   65536, never SYSTEM.SEG(blk) -- that
                                   returns SS for a local, a real bug fixed
                                   2026-08-12 elsewhere in this file). *)
  ovrResumeTrapTableOfs: WORD; (* cached offset half -- always 0 in practice
                                   (SYSTEM.Alloc is paragraph-granular, see
                                   Init's own comment) but kept as an
                                   explicit field rather than hardcoding 0
                                   at every use site, matching ovrDirectory's
                                   own style; slot(globalId)'s real offset
                                   is this PLUS globalId*5, never globalId*5
                                   alone, in case that assumption ever
                                   changes. *)

(* ---- OVERLAY.ASM externals (see that file for what each does) ---- *)

PROCEDURE InstallHandler; FAR; EXTERNAL;
PROCEDURE RemoveHandler; FAR; EXTERNAL;
PROCEDURE PatchTrampoline(siteSeg, siteOfs: WORD; toResident: BOOLEAN;
                          targetSeg, targetOfs: WORD); FAR; EXTERNAL;
PROCEDURE ReadTrampolineId(siteSeg, siteOfs: WORD): WORD; FAR; EXTERNAL;
PROCEDURE InitResumeTrapTable(tableSeg, tableOfs, count: WORD); FAR; EXTERNAL;

(* Free every ModuleHeader node in ovrLoadList -- DOCS/OVR.MD §11's own
   addition (the original algorithm has no equivalent free path,
   since real DOS process exit reclaims everything; this port follows
   CLAUDE.md's zero-heap-leaks rule instead and frees explicitly at exit).
   Also frees each module's own chunked caches (entryOfsCache,
   siteCache, resumeCache -- the latter two added 2026-08-15's
   performance fix, EntryOfsNodeRec/SiteNodeRec/ResumeNodeRec's own
   comments): DISPOSE(u) only reclaims the fixed ModuleHeaderDesc itself,
   never a chain a POINTER field inside it happens to lead to. *)
PROCEDURE FreeModuleList;
  VAR u, nx: ModuleHeader;
      eo, eonx: EntryOfsNode; sc, scnx: SiteNode; rc, rcnx: ResumeNode;
BEGIN
  u := ovrLoadList;
  WHILE u # NIL DO
    nx := u^.next;
    eo := u^.entryOfsCache;
    WHILE eo # NIL DO eonx := eo^.next; DISPOSE(eo); eo := eonx END;
    sc := u^.siteCache;
    WHILE sc # NIL DO scnx := sc^.next; DISPOSE(sc); sc := scnx END;
    rc := u^.resumeCache;
    WHILE rc # NIL DO rcnx := rc^.next; DISPOSE(rc); rc := rcnx END;
    DISPOSE(u);
    u := nx
  END;
  ovrLoadList := NIL
END FreeModuleList;

(* ExitCleanup: the single exit-procedure hook Init installs (DOCS/OVR.MD
   §13.6's exit-hook idea, generalised to cover the trap vector too,
   not just EMS -- this project's runtime has only the one
   SYSTEM.SetExitProc slot, so one hook does both jobs).  Per SYSTEM.MOD's
   SetExitProc/GetExitProc chaining contract, the FIRST action must be
   restoring the previously-installed hook (so SYSTEM_DONE doesn't call this handler
   again, and the previous handler still runs after this one); actual
   cleanup happens after that restore.  Removing the trap handler,
   freeing EMS, and freeing the overlay heap buffer are all individually
   guarded (ovrTrapInstalled/ovrUseEms/ovrHeaps[i].buf#NIL), so this is
   safe to run regardless of how far Init/OvrSetBuf/InitEMS got. *)
PROCEDURE ExitCleanup; FAR;
  VAR i: INTEGER;
BEGIN
  SYSTEM.SetExitProc(prevExitProc);
  IF ovrTrapInstalled THEN
    RemoveHandler;
    ovrTrapInstalled := FALSE
  END;
  IF ovrUseEms THEN
    EMS.Free(ovrEmsHandle);
    ovrUseEms := FALSE
  END;
  i := 0;
  WHILE i < NumHeapBlocks DO
    IF ovrHeaps[i].buf # NIL THEN
      SYSTEM.Free(ovrHeaps[i].buf); ovrHeaps[i].buf := NIL
    END;
    INC(i)
  END;
  IF ovrDirectory # NIL THEN
    SYSTEM.Free(ovrDirectory); ovrDirectory := NIL
  END;
  IF ovrResumeTrapTable # NIL THEN
    SYSTEM.Free(ovrResumeTrapTable); ovrResumeTrapTable := NIL
  END;
  FreeModuleList
END ExitCleanup;

(* ---- Init / file-format detection, DOCS/OVR.MD §11, §13.1 ---- *)

(* TryOpen: attempt to open `path`, returning TRUE and leaving the handle
   in ovrDosHandle on success.  Mirrors the three-attempts loop in
   Init (DOCS/OVR.MD §13.1) at the CALLER's level, one attempt at
   a time. *)
PROCEDURE TryOpen(path: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF ovrHaveHandle THEN Files.Close(ovrDosHandle); ovrHaveHandle := FALSE END;
  IF Files.Reset(ovrDosHandle, path) THEN
    ovrHaveHandle := TRUE; RETURN TRUE
  END;
  RETURN FALSE
END TryOpen;

(* SearchPath: try `fileName` in each ';'-separated directory of the PATH
   environment variable, in order.  DOCS/OVR.MD §13.1's attempt (b). *)
PROCEDURE SearchPath(fileName: ARRAY OF CHAR): BOOLEAN;
  VAR pathVar, dir, candidate: ARRAY 256 OF CHAR;
      i, start, n: WORD; found: BOOLEAN;
BEGIN
  Dos.GetEnv("PATH", pathVar);
  n := Strings.Length(pathVar);
  IF n = 0 THEN RETURN FALSE END;
  start := 0; i := 0; found := FALSE;
  WHILE (i <= n) & ~found DO
    IF (i = n) OR (pathVar[i] = ";") THEN
      IF i > start THEN
        Strings.Extract(pathVar, start, i - start, dir);
        Strings.Copy(dir, candidate);
        IF (Strings.Length(candidate) > 0) &
           (candidate[Strings.Length(candidate) - 1] # "\") THEN
          Strings.Append("\", candidate)
        END;
        Strings.Append(fileName, candidate);
        found := TryOpen(candidate)
      END;
      start := i + 1
    END;
    INC(i)
  END;
  RETURN found
END SearchPath;

(* SearchOwnDir: try `fileName` in the same directory as the running
   program's own .EXE (argv[0]).  DOCS/OVR.MD §13.1's attempt (c). *)
PROCEDURE SearchOwnDir(fileName: ARRAY OF CHAR): BOOLEAN;
  VAR exePath, candidate: ARRAY 256 OF CHAR; i, lastSep: INTEGER;
BEGIN
  Dos.ParamStr(0, exePath);
  lastSep := -1; i := 0;
  WHILE exePath[i] # 0X DO
    IF (exePath[i] = "\") OR (exePath[i] = "/") OR (exePath[i] = ":") THEN lastSep := i END;
    INC(i)
  END;
  IF lastSep < 0 THEN RETURN FALSE END;
  Strings.Extract(exePath, 0, lastSep + 1, candidate);
  Strings.Append(fileName, candidate);
  RETURN TryOpen(candidate)
END SearchOwnDir;

(* DetectFormat: locate the .OVR payload by reading backward from
   end-of-file (DOCS/OVR.MD §12, "Appended-to-EXE overlay file format", the
   maintainer's own design, 2026-08-08) -- works identically whether
   `ovrDosHandle` is a standalone .OVR file (LinkOvr.WriteOvrFile's own
   output, opened directly) OR an .EXE with that SAME payload
   concatenated onto its own tail by the user afterward (e.g. DOS `copy
   /b PROG.EXE+PROG.OVR PROG.EXE`) -- LinkOvr.WriteOvrFile's trailing
   DWORD (the whole payload's own byte length, INCLUDING that field
   itself) makes both cases the exact same read: seek to EOF-4, read
   that length, seek BACK that many bytes from EOF to land exactly on
   the payload's own 8-byte "DW" header, wherever in the file that
   turns out to be. Returns FALSE (leaving ovrResult set) if EOF-4 isn't
   a plausible length (too large for the file, or too small to hold even
   the 8-byte header + this trailing field) or the header found there
   doesn't start "DW". *)
PROCEDURE DetectFormat(): BOOLEAN;
  VAR hdr: ARRAY OvrHeaderSize OF BYTE; got: WORD;
      fileSize, ovrLen, payloadStart: LONGINT;
      lenBuf: ARRAY 4 OF BYTE;
BEGIN
  fileSize := Files.Size(ovrDosHandle);
  IF fileSize < LONGINT(OvrHeaderSize) + LONGINT(4) THEN RETURN FALSE END;

  Files.Seek(ovrDosHandle, fileSize - LONGINT(4));
  got := Files.BlockRead(ovrDosHandle, lenBuf, 4);
  IF got < 4 THEN RETURN FALSE END;
  ovrLen := LONGINT(WORD(lenBuf[0])) + LONGINT(WORD(lenBuf[1])) * LONGINT(256)
          + LONGINT(WORD(lenBuf[2])) * LONGINT(65536) + LONGINT(WORD(lenBuf[3])) * LONGINT(16777216);
  IF (ovrLen < LONGINT(OvrHeaderSize) + LONGINT(4)) OR (ovrLen > fileSize) THEN
    RETURN FALSE
  END;

  payloadStart := fileSize - ovrLen;
  Files.Seek(ovrDosHandle, payloadStart);
  got := Files.BlockRead(ovrDosHandle, hdr, OvrHeaderSize);
  IF got < OvrHeaderSize THEN RETURN FALSE END;
  IF (CHR(hdr[0]) = "D") & (CHR(hdr[1]) = "W") THEN
    ovrPayloadStart := payloadStart;
    ovrFileBase := payloadStart + LONGINT(OvrHeaderSize);
    RETURN TRUE
  END;
  RETURN FALSE
END DetectFormat;

(* LoadDirectory: read the .OVR file's own directory (DOCS/OVR.MD §11.1)
   into a heap buffer -- entryIdCount (WORD) at ovrFileBase-relative offset
   0, then entryIdCount (fileOfs: LONGINT; entryOfs: WORD) 6-byte pairs
   right after (widened from a 4-byte fileOfs-only slot, DOCS/OVR-ID-
   WIDEN-PLAN.MD step 2 option (c), 2026-08-26 -- see LinkOvr.WriteOvrFile's
   own header comment for the full reasoning).  Frees any previous
   ovrDirectory first (guards a second Init call the same way
   OvrSetBuf/InitEMS already guard their own state).  Returns FALSE on
   any read failure, leaving ovrDirectory NIL/ovrEntryIdCount 0. *)
PROCEDURE LoadDirectory(): BOOLEAN;
  VAR hdr: ARRAY 2 OF BYTE; got: WORD; dirBytes: WORD;
BEGIN
  IF ovrDirectory # NIL THEN SYSTEM.Free(ovrDirectory); ovrDirectory := NIL END;
  ovrEntryIdCount := 0;

  Files.Seek(ovrDosHandle, ovrFileBase);
  got := Files.BlockRead(ovrDosHandle, hdr, 2);
  IF got < 2 THEN RETURN FALSE END;
  ovrEntryIdCount := WORD(hdr[0]) + WORD(hdr[1]) * 256;
  IF ovrEntryIdCount = 0 THEN RETURN TRUE END;   (* no overlay modules at all *)

  dirBytes := WORD(LONGINT(ovrEntryIdCount) * LONGINT(6));
  ovrDirectory := SYSTEM.ADDRESS(SYSTEM.Alloc(INTEGER(dirBytes)));
  IF ovrDirectory = NIL THEN ovrEntryIdCount := 0; RETURN FALSE END;

  got := Files.BlockRead(ovrDosHandle, ovrDirectory^, dirBytes);
  IF got < dirBytes THEN
    SYSTEM.Free(ovrDirectory); ovrDirectory := NIL; ovrEntryIdCount := 0;
    RETURN FALSE
  END;
  RETURN TRUE
END LoadDirectory;

(* DirEntry: entry id's own directory slot -- the owning module's on-disk
   header offset, as a real Files.Seek target into ovrDosHandle.
   LINKOVR.MOD (SRC/TOC/LINKOVR.MOD, DOCS/OVR.MD §11.1) writes this as a byte
   offset from the PAYLOAD'S OWN START (byte 0 of whatever
   LinkOvr.WriteOvrFile wrote, since it computes hdrPos via
   Files.Position on a freshly-opened file it started writing from its
   own byte 0) -- ovrPayloadStart is added here to turn that
   payload-relative value into a real file offset, correct whether
   ovrDosHandle is a standalone .OVR file (ovrPayloadStart = 0) or an
   .EXE with that same payload appended onto its own tail
   (ovrPayloadStart = wherever DetectFormat found it), so every caller of
   DirEntry needs no change of its own. *)
PROCEDURE DirEntry(entryId: WORD): LONGINT;
  VAR p: SYSTEM.ADDRESS; base: LONGINT;
      b0, b1, b2, b3: WORD;
BEGIN
  p := ovrDirectory;
  INC(p, LONGINT(entryId) * LONGINT(6));
  b0 := WORD(ORD(p^[0])); b1 := WORD(ORD(p^[1]));
  b2 := WORD(ORD(p^[2])); b3 := WORD(ORD(p^[3]));
  base := LONGINT(b0) + LONGINT(b1)*LONGINT(256)
        + LONGINT(b2)*LONGINT(65536) + LONGINT(b3)*LONGINT(16777216);
  RETURN base + ovrPayloadStart
END DirEntry;

(* DirEntryOfs: entry id's own directory-stored in-module code offset
   (bytes +4/+5 of its 6-byte slot) -- DOCS/OVR-ID-WIDEN-PLAN.MD step 2
   option (c), 2026-08-26.  Replaces the old call-site-embedded entryOfs
   read (Overlay_ReadTrampolineEntryOfs, now unused/removable) as the
   authoritative source for an ORDINARY entry's own in-module code
   offset; a resume-point global id's directory slot always holds 0 here
   (LinkOvr.DirectResumeDirSlots never writes anything else), matching
   the pre-existing convention that a resume id's real jump target comes
   from the resume record's own on-disk "ofs" field instead, never from
   here. *)
PROCEDURE DirEntryOfs(entryId: WORD): WORD;
  VAR p: SYSTEM.ADDRESS;
BEGIN
  p := ovrDirectory;
  INC(p, LONGINT(entryId) * LONGINT(6) + LONGINT(4));
  RETURN WORD(ORD(p^[0])) + WORD(ORD(p^[1])) * 256
END DirEntryOfs;

(* Init: open the overlay file (DOCS/OVR.MD §13.1).
   Parameters: fileName -- the overlay file to open, tried as given, then
   searched on PATH, then relative to the running program's own directory.
   Result: ovrResult (see OvrResult).

   Also installs the INT 3Fh trap handler (OVERLAY.ASM's
   Overlay_InstallHandler) and the single exit-procedure hook
   (ExitCleanup) that removes it again at program exit -- guarded by
   ovrTrapInstalled so calling Init more than once does not install
   the vector twice or chain the exit hook onto itself.  Per
   SYSTEM.MOD's SetExitProc/GetExitProc contract, prevExitProc must be
   captured BEFORE installing ExitCleanup. *)
PROCEDURE Init*(fileName: ARRAY OF CHAR) : INTEGER;
BEGIN
  IF ~(TryOpen(fileName) OR SearchPath(fileName) OR SearchOwnDir(fileName)) THEN
    ovrResult := ovrNotFound; RETURN ovrResult
  END;
  IF ~DetectFormat() THEN
    Files.Close(ovrDosHandle); ovrHaveHandle := FALSE;
    ovrResult := ovrError; RETURN ovrResult
  END;
  FreeModuleList;   (* guards a second Init call, same as OvrSetBuf/InitEMS *)
  IF ~LoadDirectory() THEN
    Files.Close(ovrDosHandle); ovrHaveHandle := FALSE;
    ovrResult := ovrError; RETURN ovrResult
  END;

  IF ~ovrTrapInstalled THEN
    InstallHandler;
    ovrTrapInstalled := TRUE;
    prevExitProc := SYSTEM.GetExitProc();
    SYSTEM.SetExitProc(SYSTEM.ADR(ExitCleanup))
  END;

  (* Stale-return-address fix (2026-08-08, Solution 2 regression) -- see
     Link.AddOvrReturnTrampoline's own comment.  Table is now SYSTEM.Alloc'd
     here, sized to THIS program's own ovrEntryIdCount (DOCS/OVR-ID-WIDEN-
     PLAN.MD step 1, 2026-08-26 -- used to be a fixed 256-slot static ASM
     array, unconditionally present regardless of program size).  Freed
     first so a second Init call re-sizes cleanly instead of leaking the
     previous allocation (same guard shape as FreeModuleList/LoadDirectory
     above for their own second-Init cases).  entryIdCount=0 (no overlay
     modules at all) correctly allocates nothing -- InitResumeTrapTable's
     own count=0 case is a no-op fill, and ovrResumeTrapTableSeg/Ofs stay 0,
     never dereferenced since no resume point can exist without at least
     one $O+ entry. *)
  IF ovrResumeTrapTable # NIL THEN
    SYSTEM.Free(ovrResumeTrapTable); ovrResumeTrapTable := NIL
  END;
  ovrResumeTrapTableSeg := 0; ovrResumeTrapTableOfs := 0;
  IF ovrEntryIdCount > 0 THEN
    (* LONGINT arithmetic throughout, narrowed to WORD only at the very
       end: ovrEntryIdCount*4 (4-byte slots -- id:WORD only, entryOfs no
       longer stored here at all, DOCS/OVR-ID-WIDEN-PLAN.MD step 2
       option (c), 2026-08-26) can exceed WORD range (65535) for a large
       enough program -- SYSTEM.Alloc's own parameter is WORD (a single
       DOS allocation request is capped well under 64K anyway by the
       conventional-memory budget in practice), so a request that would
       overflow is a genuine "too many overlay entries to fit"
       condition, reported the same way an ordinary allocation failure
       is. *)
    IF LONGINT(ovrEntryIdCount) * LONGINT(4) > LONGINT(65535) THEN
      Files.Close(ovrDosHandle); ovrHaveHandle := FALSE;
      ovrResult := ovrNoMemory; RETURN ovrResult
    END;
    ovrResumeTrapTable := SYSTEM.ADDRESS(SYSTEM.Alloc(WORD(LONGINT(ovrEntryIdCount) * LONGINT(4))));
    IF ovrResumeTrapTable = NIL THEN
      Files.Close(ovrDosHandle); ovrHaveHandle := FALSE;
      ovrResult := ovrNoMemory; RETURN ovrResult
    END;
    (* SYSTEM.SEG(ovrResumeTrapTable) would be wrong here -- it returns the
       segment ovrResumeTrapTable ITSELF is stored in (a module global,
       so this module's own DATA segment), not the segment half of the
       far-pointer VALUE it holds.  Same extraction AllocHeapBlock uses,
       and the same real bug (2026-08-12) this comment there documents.
       Offset is always 0: SYSTEM.Alloc is a paragraph-granular allocator
       (SYSTEM.ASM's SYSTEM_Alloc rounds every request up to whole
       paragraphs), so the returned far pointer's offset half is always
       0 -- AllocHeapBlock's own paragraph-count treatment of orgParas
       relies on this same fact without needing to state it explicitly,
       since it only ever uses the block as a paragraph-addressed base. *)
    ovrResumeTrapTableSeg := WORD(LONGINT(ovrResumeTrapTable) DIV LONGINT(65536));
    ovrResumeTrapTableOfs := 0;
    InitResumeTrapTable(ovrResumeTrapTableSeg, ovrResumeTrapTableOfs, ovrEntryIdCount)
  END;

  ovrResult := ovrOk;
  RETURN ovrResult
END Init;

(* ---- OvrSetBuf / OvrGetBuf, DOCS/OVR.MD §13.2 ----
   This toolchain's Oberon runtime has no "shrink the heap ceiling"
   primitive exposed to library code (SYSTEM.Alloc/Free manage a
   free-list, not a movable ceiling an ordinary module can adjust) --
   so each ovrHeaps[i]'s own orgParas/ptrParas/endParas track ITS block as
   an independent region, allocated via a plain SYSTEM.Alloc block.  Each
   block's own bookkeeping is a simple bump allocator between orgParas and
   endParas -- exactly the original (pre-2026-08-21) single-buffer design,
   just replicated NumHeapBlocks times (see that CONST's own comment for
   why one block stopped being enough). *)

(* NOTE: the size < ovrHeapSizeParas clamp below is currently a no-op:
   ovrHeapSizeParas is never assigned anywhere in this file (stays 0 from
   the module BEGIN block).  In the original, OvrHeapSize is the total
   size of every overlay module -- something only a linker that actually
   emits per-module ModuleHeader records (DOCS/OVR.MD §6) could compute; there
   is no other source for it today.
   The clamp is left in place, written against the intended semantics,
   rather than removed, so it starts working the moment something sets
   ovrHeapSizeParas -- but right now MinHeapParas below is the only floor
   that actually does anything. *)
(* AllocHeapBlock: allocate ovrHeaps[i]'s own SYSTEM.Alloc block, sized
   `size` bytes (floored to MinHeapParas paragraphs) -- shared by
   OvrSetBuf/OvrSetBuf2 below.  size=0 leaves the block genuinely empty
   (buf=NIL, org=ptr=end=0): LoadModule's own "cannot possibly fit"
   fast-fail check (needParas > endParas-orgParas) already makes a
   zero-size block silently unusable, without needing a separate
   "is this block enabled" flag anywhere else in the file. *)
PROCEDURE AllocHeapBlock(i: INTEGER; size: LONGINT): BOOLEAN;
  VAR paras: WORD; blk: SYSTEM.ADDRESS;
BEGIN
  IF ovrHeaps[i].buf # NIL THEN
    SYSTEM.Free(ovrHeaps[i].buf); ovrHeaps[i].buf := NIL
  END;
  IF size <= 0 THEN
    ovrHeaps[i].orgParas := 0; ovrHeaps[i].ptrParas := 0; ovrHeaps[i].endParas := 0;
    RETURN TRUE
  END;
  paras := WORD((size + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
  IF paras < MinHeapParas THEN paras := MinHeapParas END;

  (* WORD, not INTEGER: paras*ParaSize legitimately exceeds 32767 (e.g.
     4094*16=65504) -- SYSTEM.Alloc's own parameter is WORD, and an
     INTEGER*INTEGER multiply here traps the CPU's overflow exception
     (int 04) the moment the product itself doesn't fit signed 16-bit,
     even though both operands individually do. *)
  blk := SYSTEM.ADDRESS(SYSTEM.Alloc(WORD(paras) * WORD(ParaSize)));
  IF blk = NIL THEN RETURN FALSE END;
  ovrHeaps[i].buf := blk;

  (* SYSTEM.SEG(blk) would be wrong here: it returns the segment blk ITSELF
     is stored in (SS, since blk is a local) -- DOCS/OBERLANG.MD's own SEG
     entry says as much ("SS for locals/params").  What's needed instead is
     the segment HALF OF THE FAR-POINTER VALUE blk holds (SYSTEM.Alloc's own
     result) -- SYSTEM.ADDRESS is {offset,segment} (DOCS/OBERLANG.MD "4-byte
     far value"), so LONGINT(blk) reinterprets it as segment:offset with the
     segment in the high word, isolated by DIV 65536.  Found 2026-08-12: the
     SEG(blk) bug silently returned SS instead of the real allocated block's
     segment, so the second and later trampoline hits into any $O+ module were
     patched to JMP FAR SS:entryOfs -- a jump into the stack segment executed
     as code, eventually corrupting far enough to crash (varying symptom per
     build: Invalid opcode / Unhandled interrupt A0 / 04 / 21, all one root
     cause) -- reproduced via EXAMPLES/OVRDEMO/repro5_minimal_double_call/. *)
  ovrHeaps[i].orgParas := WORD(LONGINT(blk) DIV LONGINT(65536));
  ovrHeaps[i].ptrParas := ovrHeaps[i].orgParas;
  ovrHeaps[i].endParas := WORD(LONGINT(ovrHeaps[i].orgParas) + LONGINT(paras));
  RETURN TRUE
END AllocHeapBlock;

(* OvrSetBuf: sizes block 0 only -- unchanged behavior/signature from the
   original single-buffer design, so every existing caller (TOC.MOD,
   every EXAMPLES/OVRDEMO fixture, several deliberately tiny to force
   eviction pressure as a test tool) keeps working exactly as before,
   including memory footprint: block 1 stays unallocated (size 0) unless
   OvrSetBuf2 below is used instead. *)
PROCEDURE OvrSetBuf*(size: LONGINT);
BEGIN
  IF ~ovrHaveHandle THEN ovrResult := ovrError; RETURN END;
  IF ovrLoadList # NIL THEN ovrResult := ovrError; RETURN END;
  IF size < LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize) THEN
    size := LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize)
  END;
  IF ~AllocHeapBlock(0, size) THEN ovrResult := ovrNoMemory; RETURN END;
  ovrResult := ovrOk
END OvrSetBuf;

(* OvrSetBuf2 (2026-08-21, OVR-BUG.MD follow-up -- see NumHeapBlocks' own
   comment): sizes BOTH blocks independently.  size1 need not match size0
   -- TOC.MOD sizes block 0 at the original 65500 (holds any one overlay
   module up to that size) and block 1 much smaller (just enough to cover
   a second, simultaneously-resident module in the pressure case that
   motivated this), keeping the total memory delta small against DOS's
   640KB conventional-memory ceiling (already fully committed -- CLAUDE.md/
   DOCS/OVR.MD §16's own memkb=640 bump history) rather than doubling the
   whole buffer, which was tried first and genuinely exhausted it
   ("oc: cannot create .dbg temp" compiling SRC/TASM). *)
PROCEDURE OvrSetBuf2*(size0, size1: LONGINT);
BEGIN
  IF ~ovrHaveHandle THEN ovrResult := ovrError; RETURN END;
  IF ovrLoadList # NIL THEN ovrResult := ovrError; RETURN END;
  IF size0 < LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize) THEN
    size0 := LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize)
  END;
  IF ~AllocHeapBlock(0, size0) THEN ovrResult := ovrNoMemory; RETURN END;
  IF ~AllocHeapBlock(1, size1) THEN ovrResult := ovrNoMemory; RETURN END;
  ovrResult := ovrOk
END OvrSetBuf2;

PROCEDURE OvrGetBuf*(): LONGINT;
  VAR i: INTEGER; total: LONGINT;
BEGIN
  total := 0; i := 0;
  WHILE i < NumHeapBlocks DO
    total := total + LONGINT(WORD(ovrHeaps[i].endParas - ovrHeaps[i].orgParas)) * LONGINT(ParaSize);
    INC(i)
  END;
  RETURN total
END OvrGetBuf;

(* InAnyHeap: TRUE iff seg falls inside ANY overlay block's own
   [orgParas,endParas) range -- the multi-block generalization of the
   original single-buffer "siteSeg < ovrHeapOrgParas OR >= ovrHeapEndParas"
   fast-path check (FindSiteOwner's own comment). *)
PROCEDURE InAnyHeap(seg: WORD): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < NumHeapBlocks DO
    IF (seg >= ovrHeaps[i].orgParas) & (seg < ovrHeaps[i].endParas) THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END InAnyHeap;

PROCEDURE OvrSetRetry*(size: LONGINT);
BEGIN
  ovrRetrySize := size
END OvrSetRetry;

PROCEDURE OvrGetRetry*(): LONGINT;
BEGIN
  RETURN ovrRetrySize
END OvrGetRetry;

(* ---- OvrClearBuf, DOCS/OVR.MD §13.5 ---- *)

(* PatchSitesForModule is defined further below (needs Files/PatchTrampoline
   plumbing shared with the load path) -- FORWARD so OvrClearBuf, declared
   here to keep DOCS/OVR.MD's section ordering, can call the real unpatch
   logic instead of the old no-op stub this comment used to describe. *)
PROCEDURE PatchSitesForModule(u: ModuleHeader; toResident: BOOLEAN; destParas: WORD): BOOLEAN; FORWARD;

(* OvrClearBuf: evict every resident module (real call-site unpatch, via
   PatchSitesForModule) and reset the buffer -- DOCS/OVR.MD §13.5.  Per
   that section, this evicts everything and resets the heap; it does NOT
   forget which modules exist (ovrLoadList's nodes survive with
   residentSeg=0), since RegisterModule relies on a module staying registered
   across an eviction so a later call doesn't need to re-read its header
   from disk -- only ExitCleanup's FreeModuleList actually frees the nodes. *)
PROCEDURE OvrClearBuf*;
  VAR u: ModuleHeader; i: INTEGER;
BEGIN
  IF ~ovrHaveHandle THEN ovrResult := ovrError; RETURN END;
  u := ovrLoadList;
  WHILE u # NIL DO
    IF u^.residentSeg # 0 THEN
      PatchSitesForModule(u, FALSE, 0);
      u^.residentSeg := 0
    END;
    u := u^.next
  END;
  i := 0;
  WHILE i < NumHeapBlocks DO
    ovrHeaps[i].ptrParas := ovrHeaps[i].orgParas;
    INC(i)
  END;
  ovrResult := ovrOk
END OvrClearBuf;

(* ---- disk-backed OvrReadBuf, DOCS/OVR.MD §13.1's OvrReadBuf default
   (the one Init installs; InitEMS below swaps it out) ---- *)

(* ReadSegmentFromDisk: load `u`'s code bytes into the overlay buffer at
   `destParas`.  fileOfs is the code's own FILE-ABSOLUTE byte offset
   (already includes hdrFileOfs + header + fixup table + call-site table
   -- see LoadModule's own computation, matching LINKOVR.MOD's write order,
   DOCS/OVR.MD §11.1) -- NOT relative to ovrFileBase; DirEntry's own comment
   explains how hdrFileOfs (and so fileOfs, built from it) becomes
   file-absolute (DirEntry adds ovrPayloadStart to LINKOVR.MOD's own
   payload-relative directory values). *)
PROCEDURE ReadSegmentFromDisk(u: ModuleHeader; fileOfs: LONGINT; destParas: WORD): INTEGER;
  VAR dst: SYSTEM.ADDRESS; got: WORD;
BEGIN
  IF ~ovrHaveHandle THEN RETURN ovrIOError END;
  Files.Seek(ovrDosHandle, fileOfs);
  dst := SYSTEM.PTR(destParas, 0);
  got := Files.BlockRead(ovrDosHandle, dst^, WORD(u^.codeLen));
  IF LONGINT(got) < u^.codeLen THEN RETURN ovrIOError END;
  RETURN ovrOk
END ReadSegmentFromDisk;

(* ---- InitEMS, DOCS/OVR.MD §13.6 ---- *)

(* ReadSegmentFromEms: EMS-backed OvrReadBuf, DOCS/OVR.MD §13.7.
   Copies `u`'s bytes out of the EMS handle allocated by InitEMS, via
   EMS.CopyToDos -- this project's EMS.MOD already provides page-mapped
   block copy, so this needs none of the original's own manual
   page-at-a-time INT 67h/AH=44h loop or the (page,offset) resume cursor
   the original's own +0x16/+0x18 header fields tracked: EMS.CopyToDos
   handles a copy spanning multiple 16 KB pages internally. *)
PROCEDURE ReadSegmentFromEms(u: ModuleHeader; emsOfs: LONGINT; destParas: WORD): INTEGER;
  VAR dst: SYSTEM.ADDRESS;
BEGIN
  dst := SYSTEM.PTR(destParas, 0);
  IF ~EMS.CopyToDos(ovrEmsHandle, emsOfs, dst^, WORD(u^.codeLen)) THEN
    RETURN ovrIOError
  END;
  RETURN ovrOk
END ReadSegmentFromEms;

(* PrimeEmsFromDisk: copy the overlay file's own bytes (from ovrFileBase
   onward) into the freshly allocated EMS handle, PrimeEmsChunk bytes at a
   time via a conventional-memory scratch buffer -- EMS.CopyToEMS takes a
   VAR conventional-memory source, not a file, so this bridges the two.
   NEAR: only ever called from InitEMS below. *)
PROCEDURE PrimeEmsFromDisk(totalSize: LONGINT): BOOLEAN;
  VAR buf: ARRAY PrimeEmsChunk OF BYTE; emsOfs: LONGINT; got, want: WORD; ok: BOOLEAN;
BEGIN
  Files.Seek(ovrDosHandle, ovrFileBase);
  emsOfs := 0; ok := TRUE;
  WHILE ok & (emsOfs < totalSize) DO
    want := PrimeEmsChunk;
    IF LONGINT(want) > totalSize - emsOfs THEN want := WORD(totalSize - emsOfs) END;
    got := Files.BlockRead(ovrDosHandle, buf, want);
    IF got # want THEN RETURN FALSE END;
    ok := EMS.CopyToEMS(buf, ovrEmsHandle, emsOfs, got);
    emsOfs := emsOfs + LONGINT(got)
  END;
  RETURN ok
END PrimeEmsFromDisk;

PROCEDURE InitEMS*;
  VAR totalSize: LONGINT; sizeKB: WORD;
BEGIN
  IF ~ovrHaveHandle THEN ovrResult := ovrError; RETURN END;
  IF ~EMS.Present() THEN ovrResult := ovrNoEMSDriver; RETURN END;

  totalSize := Files.Size(ovrDosHandle) - ovrFileBase;
  IF totalSize < 0 THEN totalSize := 0 END;
  sizeKB := WORD((totalSize + 1023) DIV 1024);

  IF ~EMS.Alloc(sizeKB, ovrEmsHandle) THEN
    ovrResult := ovrNoEMSMemory; RETURN
  END;
  ovrEmsPages := WORD((totalSize + LONGINT(PageSize - 1)) DIV LONGINT(PageSize));

  (* Prime EMS with the whole overlay region in one shot, since ReadSegmentFromEms
     has no per-module file offset to seek by (module comment) -- copy file bytes
     to a scratch conventional buffer, then to EMS, PageSize at a time. *)
  IF ~PrimeEmsFromDisk(totalSize) THEN
    EMS.Free(ovrEmsHandle); ovrResult := ovrIOError; RETURN
  END;

  (* No separate exit-hook install here: Init already installed
     ExitCleanup (which frees EMS too, guarded by ovrUseEms) before this
     could ever be called -- InitEMS requires ovrHaveHandle, which only
     Init sets. *)
  ovrUseEms := TRUE;
  ovrResult := ovrOk
END InitEMS;

(* ---- DOCS/OVR.MD §13.3: real dispatch ----
   Everything below reads SRC/TOC/LINKOVR.MOD's real .OVR output
   (DOCS/OVR.MD §11.1) and drives an actual load/evict cycle -- this is
   the piece that was "written against the documented layout but not
   reachable from anything" per this module's own header comment and
   DOCS/OVR.MD §12; that comment is now stale for this section (fixed
   below), though it still applies to eviction's probation/reprieve
   refinement (DOCS/OVR.MD §17's documented simplification: this port
   only ever does "never evict inUse#0"). *)

(* LoadSegment: the segment DOS loaded this program's own image at --
   immediately after the fixed 256-byte (16-paragraph) PSP.  Every
   trampoline site's own siteFileOfs (Link.AddOvrSite, DOCS/OVR.MD §11.1) is
   CODE-region-relative (paragraph*16 + in-module offset, counted from the
   image's own start, NOT the PSP) -- adding this segment's paragraph
   value converts that into a real runtime CS:offset the ASM side can
   patch through. *)
PROCEDURE LoadSegment(): WORD;
BEGIN RETURN SYSTEM.PrefixSeg() + 16 END LoadSegment;

(* ReadModuleHeader8: read the ModuleHdrSize-byte on-disk header subset
   (LINKOVR.MOD's own header comment -- revised 2026-08-08 (twice):
   dropped the dead extraLen field, reordered so xfixupLen sits next to
   fixupLen, then grew to 10 bytes for resumeCount, cross-overlay calls;
   revised again 2026-08-11: codeLen widened WORD->LONGINT, header now
   ModuleHdrSize=12 bytes -- see ModuleHeaderDesc's own codeLen comment) at
   absolute file offset hdrFileOfs. *)
PROCEDURE ReadModuleHeader8(hdrFileOfs: LONGINT;
                         VAR fixupLen, xfixupLen: WORD; VAR codeLen: LONGINT;
                         VAR siteCount, resumeCount: WORD): BOOLEAN;
  VAR buf: ARRAY ModuleHdrSize OF BYTE; got: WORD;
BEGIN
  Files.Seek(ovrDosHandle, hdrFileOfs);
  got := Files.BlockRead(ovrDosHandle, buf, ModuleHdrSize);
  IF got < ModuleHdrSize THEN RETURN FALSE END;
  fixupLen    := WORD(buf[0]) + WORD(buf[1]) * 256;
  xfixupLen   := WORD(buf[2]) + WORD(buf[3]) * 256;
  codeLen     := LONGINT(buf[4]) + LONGINT(buf[5]) * 256
               + LONGINT(buf[6]) * 65536 + LONGINT(buf[7]) * 16777216;
  siteCount   := WORD(buf[8]) + WORD(buf[9]) * 256;
  resumeCount := WORD(buf[10]) + WORD(buf[11]) * 256;
  RETURN TRUE
END ReadModuleHeader8;

(* LoadSiteCache: read u's own call-site table (DOCS/OVR.MD §8) off disk
   ONCE and store it in u^.siteCache (SiteNodeRec, chunked) -- see that
   record's own comment for why this exists (the O(dispatches*siteCount)
   disk-rescan bug).  Called once from RegisterModule, right after a
   module's fixed header is first read, while hdrFileOfs/fixupLen/
   xfixupLen/siteCount are already known.  A siteCount=0 module leaves
   u^.siteCache NIL, same as an empty chunk list -- callers iterate it the
   same way either way. *)
PROCEDURE LoadSiteCache(u: ModuleHeader): BOOLEAN;
  VAR i: WORD; buf: ARRAY 8 OF BYTE; got: WORD; siteFileOfs: LONGINT;
      entryId, ownerGlobalId: WORD; node: SiteNode; k: INTEGER;
BEGIN
  IF u^.siteCount = 0 THEN RETURN TRUE END;
  Files.Seek(ovrDosHandle, u^.hdrFileOfs + LONGINT(ModuleHdrSize) + LONGINT(u^.fixupLen)
             + LONGINT(u^.xfixupLen));
  i := 0;
  WHILE i < u^.siteCount DO
    got := Files.BlockRead(ovrDosHandle, buf, 8);
    IF got < 8 THEN RETURN FALSE END;
    siteFileOfs := LONGINT(buf[0]) + LONGINT(buf[1]) * 256
                 + LONGINT(buf[2]) * 65536 + LONGINT(buf[3]) * 16777216;
    entryId := WORD(buf[4]) + WORD(buf[5]) * 256;
    ownerGlobalId := WORD(buf[6]) + WORD(buf[7]) * 256;
    IF (u^.siteCache = NIL) OR (u^.siteCache^.count >= SiteChunk) THEN
      NEW(node);
      IF node = NIL THEN RETURN FALSE END;
      node^.count := 0; node^.next := u^.siteCache; u^.siteCache := node
    END;
    k := u^.siteCache^.count;
    u^.siteCache^.siteFileOfs[k]   := siteFileOfs;
    u^.siteCache^.entryId[k]       := entryId;
    u^.siteCache^.ownerGlobalId[k] := ownerGlobalId;
    INC(u^.siteCache^.count);
    INC(i)
  END;
  RETURN TRUE
END LoadSiteCache;

(* LoadResumeCache: read u's own resume table (DOCS/OVR.MD §9) off disk
   ONCE, mirroring LoadSiteCache above -- see ResumeNodeRec's own comment. *)
PROCEDURE LoadResumeCache(u: ModuleHeader): BOOLEAN;
  VAR i: WORD; buf: ARRAY 6 OF BYTE; got: WORD;
      ofs, globalId, calleeGlobalId: WORD; node: ResumeNode; k: INTEGER;
BEGIN
  IF u^.resumeCount = 0 THEN RETURN TRUE END;
  Files.Seek(ovrDosHandle, u^.hdrFileOfs + LONGINT(ModuleHdrSize) + LONGINT(u^.fixupLen)
             + LONGINT(u^.xfixupLen) + LONGINT(u^.siteCount) * LONGINT(8));
  i := 0;
  WHILE i < u^.resumeCount DO
    got := Files.BlockRead(ovrDosHandle, buf, 6);
    IF got < 6 THEN RETURN FALSE END;
    ofs            := WORD(buf[0]) + WORD(buf[1]) * 256;
    globalId       := WORD(buf[2]) + WORD(buf[3]) * 256;
    calleeGlobalId := WORD(buf[4]) + WORD(buf[5]) * 256;
    IF (u^.resumeCache = NIL) OR (u^.resumeCache^.count >= ResumeChunk) THEN
      NEW(node);
      IF node = NIL THEN RETURN FALSE END;
      node^.count := 0; node^.next := u^.resumeCache; u^.resumeCache := node
    END;
    k := u^.resumeCache^.count;
    u^.resumeCache^.ofs[k]            := ofs;
    u^.resumeCache^.globalId[k]       := globalId;
    u^.resumeCache^.calleeGlobalId[k] := calleeGlobalId;
    INC(u^.resumeCache^.count);
    INC(i)
  END;
  RETURN TRUE
END LoadResumeCache;

(* RegisterModule: find the already-registered ModuleHeader for hdrFileOfs, or
   read its on-disk header and create one.  Multiple entry ids can share
   one hdrFileOfs (one module, several exported entry points, DOCS/OVR.MD
   §11.1) -- this is what keeps ovrLoadList one node PER MODULE, not per
   entry id, matching DOCS/OVR.MD §6's own per-segment (not per-entry-point)
   header model.  Also loads the call-site and resume table caches (above)
   the FIRST time a module is registered -- tablesCached guards against
   redoing this on a later cache hit, both here (never re-reached, since a
   found `u` returns immediately above) and defensively on the freshly
   allocated node. *)
PROCEDURE RegisterModule(hdrFileOfs: LONGINT): ModuleHeader;
  VAR u: ModuleHeader; fixupLen, xfixupLen, siteCount, resumeCount: WORD; codeLen: LONGINT;
BEGIN
  u := ovrLoadList;
  WHILE (u # NIL) & (u^.hdrFileOfs # hdrFileOfs) DO u := u^.next END;
  IF u # NIL THEN RETURN u END;

  IF ~ReadModuleHeader8(hdrFileOfs, fixupLen, xfixupLen, codeLen, siteCount, resumeCount) THEN
    RETURN NIL
  END;
  NEW(u);
  IF u = NIL THEN RETURN NIL END;
  u^.hdrFileOfs  := hdrFileOfs;
  u^.fixupLen    := fixupLen;
  u^.xfixupLen   := xfixupLen;
  u^.codeLen     := codeLen;
  u^.siteCount   := siteCount;
  u^.resumeCount := resumeCount;
  u^.residentSeg := 0;
  u^.inUse       := 0;
  u^.siteCache     := NIL;
  u^.resumeCache   := NIL;
  u^.tablesCached  := FALSE;
  u^.next        := ovrLoadList;
  ovrLoadList    := u;
  IF LoadSiteCache(u) & LoadResumeCache(u) THEN END;
  u^.tablesCached := TRUE;
  (* Pre-allocate u's own entryOfsCache's first (empty) chunk node here,
     at registration time, instead of letting CacheEntryOfs's own NEW
     fire lazily on this module's first real dispatch.  WarmModuleCaches
     forces RegisterModule (this procedure) for every module before
     TocMain.Run's own per-module LeakGuard baseline is captured -- but
     entryOfsCache stayed NIL until here, so a module dispatched into for
     the very first time mid-compile still paid this one-time NEW cost
     AFTER the baseline, reading as a false-positive leak on whichever
     source file happened to trigger it first (found 2026-08-16 compiling
     NOIMP.MOD: "heap leak ... in Cgen.CgFree() (5 paragraphs)").  One
     chunk (EntryOfsChunk=8 slots) is enough for the life of the process,
     not just at warm-up: OvrDispatch's own CacheEntryOfs call is gated on
     CachedEntryOfs first (see that call site's own comment for the real,
     separate bug this fixes -- an un-deduped repeat dispatch into the
     same entryId used to append a fresh duplicate slot every time,
     growing entryOfsCache without bound), so entryOfsCache holds at most
     one entry per DISTINCT entryId ever routed to this module -- bounded
     by that module's own export count, always far below 8 for every
     overlay module in this project. *)
  NEW(u^.entryOfsCache);
  IF u^.entryOfsCache # NIL THEN
    u^.entryOfsCache^.count := 0; u^.entryOfsCache^.next := NIL
  END;
  RETURN u
END RegisterModule;

(* WarmModuleCaches: eagerly RegisterModule every entry the directory
   names -- called once, right after Init, from TOC.MOD's own SetupOvr
   (not from Init itself: RegisterModule is defined below Init in this
   file, and forward-declaring it there hit a genuine parser error this
   dialect's FORWARD support doesn't explain -- calling from outside
   avoids that entirely, at the cost of one extra explicit call at every
   Init call site).  RegisterModule's own first-time cost per module
   (reading the fixed header plus LoadSiteCache/LoadResumeCache's chunked
   table reads, above) is a genuine, permanent, one-time allocation for
   the process's whole lifetime, not a per-compile leak -- but left
   lazy, it only happens on whichever dispatch first needs a given
   module, which can land AFTER a caller's own leak-guard baseline was
   captured (TocMain.MOD's LeakGuard "whole run" check runs before
   SYSTEM.Halt, the only thing that ever runs ExitCleanup/
   FreeModuleList), making the same permanent allocation LOOK like a
   leak purely because of WHEN it happened relative to that baseline.
   Calling this right after Init, before any caller's own baseline
   capture, moves the one-time cost to the "before" side of that
   baseline -- exactly the same idea as SRC/TASM/SYM.MOD's WarmStrTab*,
   DOCS/IMPLRULE.MD §"StrTab adoption pattern". *)
PROCEDURE WarmModuleCaches*;
  VAR id: WORD; hdrFileOfs: LONGINT;
BEGIN
  id := 0;
  WHILE id < ovrEntryIdCount DO
    hdrFileOfs := DirEntry(id);
    RegisterModule(hdrFileOfs);
    INC(id)
  END
END WarmModuleCaches;

(* ApplyFixupsAt: read a fixup table of `byteLen` bytes starting at absolute
   file offset `tableOfs` and adjust each listed in-code WORD (within the
   module now resident at `destParas`) by ADDING `addend` -- shared by
   ApplyFixups (self-CODE table, addend=this module's own load segment) and
   ApplyXFixups (cross-module table, addend=the PROGRAM's own load segment
   -- see Link.Module.ovrXFixups' own comment for why these need a
   DIFFERENT addend, not the same one). *)
PROCEDURE ApplyFixupsAt(tableOfs: LONGINT; byteLen: WORD; destParas, addend: WORD): BOOLEAN;
  VAR i, n: WORD; ofsBuf: ARRAY 2 OF BYTE; got: WORD;
      target: SYSTEM.ADDRESS; cur: WORD;
BEGIN
  IF byteLen = 0 THEN RETURN TRUE END;
  Files.Seek(ovrDosHandle, tableOfs);
  n := byteLen DIV 2;
  i := 0;
  WHILE i < n DO
    got := Files.BlockRead(ovrDosHandle, ofsBuf, 2);
    IF got < 2 THEN RETURN FALSE END;
    target := SYSTEM.PTR(destParas, WORD(ofsBuf[0]) + WORD(ofsBuf[1]) * 256);
    (* SYSTEM.GET/PUT do not exist in this dialect (DOCS/OBERLANG.MD --
       removed).  SYSTEM.ADDRESS's own ^[i] gives byte (CHAR) semantics
       only, so the little-endian WORD is built/stored by hand, same
       idiom as every raw byte-buffer read elsewhere in this file. *)
    cur := WORD(ORD(target^[0])) + WORD(ORD(target^[1])) * 256;
    cur := cur + addend;
    target^[0] := CHR(SYSTEM.AND(cur, 0FFH));
    target^[1] := CHR(SYSTEM.LSR(cur, 8));
    INC(i)
  END;
  RETURN TRUE
END ApplyFixupsAt;

(* ApplyFixups: u's own internal (self-CODE) fixup table, right after the
   10-byte header at hdrFileOfs+10 -- the compiler/linker assumed load
   segment 0 for every self-referencing CODE value (Link.OnSegRelocOverlay,
   DOCS/OVR.MD §7), so the runtime's job is exactly "add the real load
   segment now that one is known" (DOCS/OVR.MD §5's own framing). *)
PROCEDURE ApplyFixups(u: ModuleHeader; destParas: WORD): BOOLEAN;
BEGIN
  RETURN ApplyFixupsAt(u^.hdrFileOfs + LONGINT(ModuleHdrSize), u^.fixupLen, destParas, destParas)
END ApplyFixups;

(* ApplyXFixups: u's own cross-module fixup table, right after the self-CODE
   fixup table (hdrFileOfs+10+fixupLen) -- every DATA/BSS/import SEGRELOC
   Link.OnSegRelocOverlay bakes is relative to the WHOLE PROGRAM's own load
   segment (codePara/dataPara/bssPara), exactly like a main-image SEGRELOC's
   target; a main-image site gets that correction for free from the DOS MZ
   loader's own relocation table, but .OVR file content is never touched by
   that loader at all, so nothing else will ever add it -- this pass adds
   the PROGRAM's load segment (LoadSegment(), NOT destParas: destParas is
   THIS module's own load segment, only correct for a genuine self-reference
   to this module's own CODE, which ApplyFixups above already handles). *)
PROCEDURE ApplyXFixups(u: ModuleHeader; destParas: WORD): BOOLEAN;
BEGIN
  RETURN ApplyFixupsAt(u^.hdrFileOfs + LONGINT(ModuleHdrSize) + LONGINT(u^.fixupLen),
                       u^.xfixupLen, destParas, LoadSegment())
END ApplyXFixups;

(* FindSiteOwner: scan u's own call-site table (same on-disk layout
   PatchSitesForModule reads) looking for the ONE entry whose resolved
   siteSeg:siteOfs matches the site that just trapped, and return its own
   ownerGlobalId -- OvrDispatch's real per-call inUse nesting (DOCS/OVR.MD
   §10, "inUse and eviction-pressure testing"): the ordinary-entry path needs
   to know WHICH caller module to DEC (mirroring the resume path's existing
   callee DEC), and ownerGlobalId (Link.AddOvrSite, already written into
   every call-site record) is exactly that -- it was only ever consumed
   at link/patch time before (PatchSitesForModule, rewriting trampoline
   bytes), never read back at dispatch time.  Returns OvrNoOwner if no
   site matches (defensive -- should not happen for a real trap, since
   the site that fired must be in SOME module's own table) or the site
   lives in the main resident image (OvrNoOwner is also the on-disk
   sentinel for that ordinary case, so the two "nothing to decrement"
   outcomes collapse into the same return value, which is exactly what
   OvrDispatch's caller-DEC guard already checks for).

   Fast path (added chasing the bug #5 performance investigation,
   2026-08-14): a cross-overlay call site can only ever live INSIDE the
   shared overlay heap buffer (ovrHeapOrgParas..ovrHeapEndParas), since
   that is the only place overlay CODE is ever loaded to.  Every call
   made from the RESIDENT main image -- the overwhelming majority of
   real dispatches, since it covers every ordinary (non-overlay-to-
   overlay) call site -- has siteSeg outside that range and can never
   match any site-table entry, so the whole per-call scan below is
   entirely skippable with one cheap in-memory range check.

   In-memory table (2026-08-15, same performance investigation
   continued): even the "still needs it" case -- siteSeg genuinely
   inside the heap buffer, a real cross-overlay call -- used to re-read
   u's ENTIRE call-site table from disk (Files.Seek + one
   Files.BlockRead PER ENTRY) on EVERY dispatch through it, including a
   plain repeat call that changes nothing about the table.  Confirmed
   via isolated xt reproducers that this scales with siteCount, not
   just call count (see SiteNodeRec's own comment) -- exactly the
   remaining O(dispatches*siteCount) cost behind DOCS/OVR.MD §16's
   still-open "severe performance regression."  Now scans u^.siteCache
   (RegisterModule's own one-time LoadSiteCache read) instead of the
   file -- same logic, same match rule, no disk I/O. *)
(* VAR ownerSiteFileOfs (Bug 2 fix, OVR-BUG.MD): the MATCHED site record's
   own siteFileOfs -- the caller-module-relative opcode offset of the
   call site that actually trapped, needed by FindResumeGlobalId below to
   disambiguate WHICH of caller's (possibly several) call sites into the
   same callee entry point this particular trap corresponds to.  Left
   unset (caller must ignore it) whenever this returns OvrNoOwner. *)
PROCEDURE FindSiteOwner(u: ModuleHeader; siteSeg, siteOfs: WORD; VAR ownerSiteFileOfs: LONGINT): WORD;
  VAR node: SiteNode; k: INTEGER;
      siteFileOfs: LONGINT; loadSeg, candSeg, candOfs: WORD;
      ownerGlobalId: WORD; ownerHdrFileOfs: LONGINT; owner: ModuleHeader;
      wantLinear, candLinear: LONGINT;
BEGIN
  IF u^.siteCount = 0 THEN RETURN OvrNoOwner END;
  IF ~InAnyHeap(siteSeg) THEN
    RETURN OvrNoOwner
  END;
  (* Compare LINEAR addresses (seg*16+ofs), not seg:ofs pairs directly --
     a real-mode address has many valid seg:ofs spellings for the same
     physical byte (found via a debug probe: the trapped site's own
     siteSeg:siteOfs and this scan's own owner^.residentSeg-derived
     candSeg:candOfs computed the SAME address but via different
     segment/offset splits, so a direct field-by-field compare missed
     the real match every time). *)
  wantLinear := LONGINT(siteSeg) * LONGINT(16) + LONGINT(siteOfs);
  loadSeg := LoadSegment();
  node := u^.siteCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      siteFileOfs := node^.siteFileOfs[k];
      ownerGlobalId := node^.ownerGlobalId[k];
      IF ownerGlobalId = OvrNoOwner THEN
        candSeg := loadSeg + WORD(siteFileOfs DIV LONGINT(16));
        candOfs := WORD(siteFileOfs MOD LONGINT(16))
      ELSE
        ownerHdrFileOfs := DirEntry(ownerGlobalId);
        owner := RegisterModule(ownerHdrFileOfs);
        IF (owner # NIL) & (owner^.residentSeg # 0) THEN
          candSeg := owner^.residentSeg + WORD(siteFileOfs DIV LONGINT(16));
          candOfs := WORD(siteFileOfs MOD LONGINT(16))
        ELSE
          candSeg := 0
        END
      END;
      IF candSeg # 0 THEN
        candLinear := LONGINT(candSeg) * LONGINT(16) + LONGINT(candOfs);
        IF candLinear = wantLinear THEN
          ownerSiteFileOfs := siteFileOfs;
          RETURN ownerGlobalId
        END
      END;
      INC(k)
    END;
    node := node^.next
  END;
  RETURN OvrNoOwner
END FindSiteOwner;

(* CachedEntryOfs: look up entryId in u's own entryOfsCache; TRUE + the
   cached value if found.  See EntryOfsNodeRec's own comment for why this
   cache exists. *)
PROCEDURE CachedEntryOfs(u: ModuleHeader; entryId: WORD; VAR entryOfs: WORD): BOOLEAN;
  VAR node: EntryOfsNode; k: INTEGER;
BEGIN
  node := u^.entryOfsCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      IF node^.entryId[k] = entryId THEN entryOfs := node^.entryOfs[k]; RETURN TRUE END;
      INC(k)
    END;
    node := node^.next
  END;
  RETURN FALSE
END CachedEntryOfs;

(* CacheEntryOfs: remember entryId -> entryOfs for every future patch of
   any site sharing this entryId, so ReadTrampolineEntryOfs is never
   trusted again once this module's OWN trampoline bytes might have been
   overwritten by an earlier resident-form patch (EntryOfsNodeRec's own
   comment). *)
PROCEDURE CacheEntryOfs(u: ModuleHeader; entryId, entryOfs: WORD);
  VAR node: EntryOfsNode; k: INTEGER;
BEGIN
  IF (u^.entryOfsCache = NIL) OR (u^.entryOfsCache^.count >= EntryOfsChunk) THEN
    NEW(node);
    IF node = NIL THEN RETURN END;
    node^.count := 0; node^.next := u^.entryOfsCache; u^.entryOfsCache := node
  END;
  k := u^.entryOfsCache^.count;
  u^.entryOfsCache^.entryId[k] := entryId;
  u^.entryOfsCache^.entryOfs[k] := entryOfs;
  INC(u^.entryOfsCache^.count)
END CacheEntryOfs;

(* PatchSitesForModule: read u's own call-site table (DOCS/OVR.MD §8, right
   after the header + fixup table) and rewrite every listed trampoline to
   the resident (toResident=TRUE, seg=destParas) or swappable
   (toResident=FALSE) form.  siteFileOfs entries are CODE-region-relative
   (LINK.MOD's AddOvrSite) -- LoadSegment() converts to a real seg:ofs.
   toResident=TRUE is no longer called from LoadModule (2026-08-12 fix, see
   that procedure's own comment) -- eagerly patching every site the
   moment ANY ONE trapped skipped Ovr_TrapEntry's return-address
   synthesis for every site but the one that actually trapped.  Kept
   generic (both directions still real, working code) rather than
   splitting into two procedures -- only its CALLERS changed. toResident=
   FALSE (eviction) still visits every site unconditionally, which is
   correct: reverting to CD 3F never loses a return-address opportunity,
   it restores the only one there ever is.

   In-memory table (2026-08-15, performance investigation): scans
   u^.siteCache (RegisterModule's own one-time LoadSiteCache read)
   instead of re-reading the file -- same logic, same match rule, no
   disk I/O (SiteNodeRec's own comment). *)
PROCEDURE PatchSitesForModule;
  VAR node: SiteNode; k: INTEGER;
      siteFileOfs: LONGINT; loadSeg, siteSeg, siteOfs, entryOfs, entryId: WORD;
      ownerGlobalId: WORD; ownerHdrFileOfs: LONGINT; owner: ModuleHeader;
      calleeHdrFileOfs: LONGINT; callee: ModuleHeader;
BEGIN
  IF u^.siteCount = 0 THEN RETURN TRUE END;
  loadSeg := LoadSegment();
  node := u^.siteCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      siteFileOfs := node^.siteFileOfs[k];
      entryId := node^.entryId[k];
      ownerGlobalId := node^.ownerGlobalId[k];
      IF ownerGlobalId = OvrNoOwner THEN
        (* Ordinary case: site lives in the main image, siteFileOfs is
           already absolute-from-load-segment (Link.AddOvrSite's own
           comment). *)
        siteSeg := loadSeg + WORD(siteFileOfs DIV LONGINT(16));
        siteOfs := WORD(siteFileOfs MOD LONGINT(16))
      ELSE
        (* Cross-overlay call site (DOCS/OVR.MD §9, "Cross-overlay calls"): the
           call site itself lives inside another $O+ module's own code.  That
           module has no fixed runtime address at all unless it is CURRENTLY
           resident -- if it isn't, there is nothing to patch right now: its
           own call sites are still sitting on disk in their default INT 3Fh
           form (never wrote a real address, since it never ran), so a
           future load of THAT module starts with correctly-trapping sites,
           and each one self-patches to JMP FAR the first time it actually
           executes, exactly like any ordinary trampoline hit -- no eager
           patching is needed or possible for a non-resident owner. *)
        ownerHdrFileOfs := DirEntry(ownerGlobalId);
        owner := RegisterModule(ownerHdrFileOfs);
        IF (owner # NIL) & (owner^.residentSeg # 0) THEN
          siteSeg := owner^.residentSeg + WORD(siteFileOfs DIV LONGINT(16));
          siteOfs := WORD(siteFileOfs MOD LONGINT(16))
        ELSE
          siteSeg := 0   (* not resident -- skip, see comment above *)
        END
      END;
      IF siteSeg # 0 THEN
        (* entryId here is the CALLEE's own entry id -- the entry point
           THIS site calls INTO, which belongs to whichever module owns
           entryId, NOT necessarily u (u is only the module whose own
           call-SITE table is being walked).  Bug fix (2026-09-02,
           OVR-BUG.MD "EXACT BUG CONFIRMED"): the entryOfsCache lookup/
           write below used to run against u^.entryOfsCache -- caching
           the CALLEE's entry offset under u's own module header.
           ReadCounter unconditionally trusts entryOfsCache[0] as one of
           ITS OWN module's real entry points (to locate the CgPrologue
           DATA-segment operand for the epilogue counter read); a
           foreign callee's entryOfs landing in slot 0 there made
           ReadCounter parse arbitrary bytes inside u's own code as if
           they were u's own prologue, returning garbage -- confirmed via
           OVRINUSE7.LOG showing a nonzero garbage counter value on an
           otherwise-idle module immediately preceding Bug 6's crash.
           Fix: resolve the callee's own ModuleHeader (RegisterModule via
           DirEntry(entryId), mirroring how the ownerGlobalId branch
           above already resolves an unrelated module by id) and cache
           into THAT module's own entryOfsCache instead of u's. *)
        calleeHdrFileOfs := DirEntry(entryId);
        callee := RegisterModule(calleeHdrFileOfs);
        IF toResident THEN
          (* Each call site may target a DIFFERENT entry point within this
             same module -- need THIS site's own in-module code offset
             before overwriting it with the resident JMP FAR form, so the
             jump target is destParas:entryOfs, not always destParas:0
             (which would jump into whichever entry happens to be first
             in the module's own code, typically __init).  entryOfs now
             comes straight from the .OVR directory (DirEntryOfs,
             DOCS/OVR-ID-WIDEN-PLAN.MD step 2 option (c), 2026-08-26) --
             a pure function of entryId, always authoritative, no longer
             read from THIS call site's own (possibly already-overwritten)
             bytes at all.  entryOfsCache still used as a speed
             optimization (skip the directory dereference on repeat
             hits) but is no longer load-bearing for correctness the way
             it was under the old call-site-embedded scheme -- see
             EntryOfsNodeRec's own comment for that now-historical
             reasoning. *)
          IF (callee = NIL) OR ~CachedEntryOfs(callee, entryId, entryOfs) THEN
            entryOfs := DirEntryOfs(entryId);
            IF callee # NIL THEN CacheEntryOfs(callee, entryId, entryOfs) END
          END;
          PatchTrampoline(siteSeg, siteOfs, TRUE, destParas, entryOfs)
        ELSE
          (* Restoring the swappable form needs entryId written back
             explicitly (Overlay_PatchTrampoline's own header comment) --
             already known (read from the call-site table above).
             entryOfs is STILL passed here (kept for a uniform
             PatchTrampoline signature across both branches) but the ASM
             now ignores it in the swappable branch (DOCS/OVR-ID-WIDEN-
             PLAN.MD step 2 option (c), 2026-08-26: entryOfs no longer
             lives in the trampoline at all); still resolved via the
             cache/directory lookup for cheapness, not correctness. *)
          IF (callee = NIL) OR ~CachedEntryOfs(callee, entryId, entryOfs) THEN
            entryOfs := DirEntryOfs(entryId);
            IF callee # NIL THEN CacheEntryOfs(callee, entryId, entryOfs) END
          END;
          PatchTrampoline(siteSeg, siteOfs, FALSE, entryId, entryOfs)
        END
      END;
      INC(k)
    END;
    node := node^.next
  END;
  RETURN TRUE
END PatchSitesForModule;

(* HasCounter: TRUE iff u is CURRENTLY RESIDENT and has at least one
   cached entry offset to read a live prologue from (EntryOfsNodeRec) --
   every $O+ module has a real epilogue counter (Parser.MOD's isOvrEntry
   INC/DEC always targets DATA offset 0, the pre-existing per-module
   placeholder -- see that call site's own comment), so this reduces to
   "can ReadCounter actually reach it right now": u must be loaded
   (residentSeg#0, its compiled prologue bytes must exist in memory to
   read the DS operand from) AND have at least one REAL cached entry
   (entryOfsCache^.count>0 -- entryOfsCache itself is never NIL after
   RegisterModule's own WarmModuleCaches-driven eager NEW, but starts
   with count=0 and an unwritten entryOfs[0] slot until the first real
   CacheEntryOfs call, so entryOfsCache#NIL alone is NOT sufficient).
   This becomes TRUE the instant a module is first loaded (LoadModule
   always returns via the trapped site's own OvrDispatch, which caches
   entryOfs for that entryId before TryEvictOne could ever see this
   module resident at all) -- see ReadCounter's own comment for why
   entryOfs specifically, not u^.hdrFileOfs or similar, is what's
   needed. *)
PROCEDURE HasCounter(u: ModuleHeader): BOOLEAN;
BEGIN
  RETURN (u^.residentSeg # 0) & (u^.entryOfsCache # NIL) & (u^.entryOfsCache^.count > 0)
END HasCounter;

(* ReadCounter: far-read u's own epilogue counter WORD.
   Deliberately avoids any NEW .OVR on-disk field (OVR-BUG.MD's own
   handoff: BOOT/TOC.EXE's writer is permanently fixed at the OLD
   12-byte header and cannot be updated by an agent) -- everything
   needed is already resident, once u is loaded:
     1. u^.residentSeg is u's own current CODE segment (LoadModule's own
        field, always current).
     2. Any cached entryOfs (u^.entryOfsCache, first slot of the first
        chunk -- any one works, they all belong to FAR/exported entry
        points of the SAME module) points at a real CgPrologue start.
        CgPrologue's own byte layout (CGEN.MOD, isFar branch) is fixed:
        55 8B EC 81 EC ll hh 1E B8 lo hi 8E D8 -- the `MOV AX,imm16` at
        +9/+10 is the ONE instruction Link.OnSegRelocOverlay's own
        rrefSeg=SegData branch bakes with `lnkMod^.dataPara`
        (link-time-fixed), and Overlay.ApplyXFixups patches with
        +LoadSegment() the moment this module is loaded -- so once u is
        resident, that imm16 IS u's own real, current DATA segment,
        already fully resolved, sitting in memory needing no further
        computation at all.
     3. The counter itself lives at DATA offset 0 in that segment (the
        pre-existing per-module placeholder every module already
        reserves -- Parser.MOD's own ParseModule comment).
   Same raw SYSTEM.PTR + byte-pair idiom ApplyFixupsAt already uses for a
   far WORD/read (SYSTEM.GET/PUT don't exist in this dialect).
   Read-only: codegen (Parser.MOD/CGEN.MOD's CgIncDecMem calls) is the
   only writer, in the module's own compiled INC/DEC-at-prologue/
   epilogue code -- the runtime never writes either word this reads. *)
PROCEDURE ReadCounter(u: ModuleHeader): WORD;
  VAR entryOfs: WORD; opnd: SYSTEM.ADDRESS; dataSeg: WORD; ctr: SYSTEM.ADDRESS;
BEGIN
  entryOfs := u^.entryOfsCache^.entryOfs[0];
  opnd := SYSTEM.PTR(u^.residentSeg, entryOfs + WORD(9));
  dataSeg := WORD(ORD(opnd^[0])) + WORD(ORD(opnd^[1])) * 256;
  ctr := SYSTEM.PTR(dataSeg, WORD(0));
  RETURN WORD(ORD(ctr^[0])) + WORD(ORD(ctr^[1])) * 256
END ReadCounter;

(* TryEvictOne: find the first ovrLoadList entry that is resident and not
   in use, and evict it (DOCS/OVR.MD §13.4's "never evict inUse#0" rule --
   §17's documented simplification of the full ring+probation
   scheme).  Returns FALSE if every resident module is currently in use
   (nothing could be evicted).
   OVR-BUG.MD epilogue-counter fix: inUse and the counter track TWO
   DIFFERENT, independently-necessary things, not one replacing the
   other -- the counter tracks "is u's OWN compiled code currently
   executing" (INC/DEC in u's own prologue/epilogue, correct for the
   ordinary-call case that used to leak, OvrDispatch's own INC(u^.inUse)
   comment), while inUse (now ONLY INC'd on resume, never on an ordinary
   entry -- see that same comment) tracks "is u currently a live
   cross-overlay CALLER waiting on a nested call to return" (DOCS/OVR.MD
   §9/§10) -- a real, separate condition the counter cannot see (u's own
   code is correctly NOT executing while it waits on the stack for a
   callee, so the counter alone would authorize evicting u right out
   from under a resume return address still pointing into it).  BOTH
   must be zero before u is genuinely idle.  Confirmed via a real
   self-hosting corruption compiling with PEXPR.MOD $O+ (the first
   module to exercise real cross-overlay resume chains): counter-only
   eviction evicted a module with inUse=1, corrupting memory a live
   resume target still needed.
   HasCounter(u)=FALSE (u not currently resident, or resident but never
   yet dispatched through any entry point -- see that procedure's own
   comment) falls back to inUse alone here; the outer `u^.residentSeg#0`
   check below already excludes a non-resident module from eviction
   regardless of what `idle` evaluates to in that case, so the fallback
   value is never actually consulted for it. *)
PROCEDURE TryEvictOne(): BOOLEAN;
  VAR u: ModuleHeader; idle: BOOLEAN;
BEGIN
  u := ovrLoadList;
  WHILE u # NIL DO
    IF HasCounter(u) THEN idle := (ReadCounter(u) = 0) & (u^.inUse = 0)
    ELSE idle := u^.inUse = 0 END;
    IF (u^.residentSeg # 0) & idle THEN
      IF ~PatchSitesForModule(u, FALSE, 0) THEN RETURN FALSE END;
      u^.residentSeg := 0;
      RETURN TRUE
    END;
    u := u^.next
  END;
  RETURN FALSE
END TryEvictOne;

(* RegionFree: TRUE iff [destParas, destParas+needParas) does not overlap
   any currently-resident module's own occupied range.  Needed alongside
   TryEvictOne (found 2026-08-08 setting up cross-overlay-calls eviction-
   pressure testing): after a wraparound reset, "does this fit before
   ovrHeapEndParas" is NOT the same question as "is this space actually
   free" -- a still-resident module (in use or not) can occupy exactly the
   region the bump pointer just wrapped back into.  LoadModule must check
   this and keep evicting (TryEvictOne) until the destination region is
   genuinely clear, not just within the buffer's own outer bounds. *)
PROCEDURE RegionFree(destParas, needParas: WORD): BOOLEAN;
  VAR u: ModuleHeader; uNeed: WORD;
BEGIN
  u := ovrLoadList;
  WHILE u # NIL DO
    IF u^.residentSeg # 0 THEN
      uNeed := WORD((LONGINT(u^.codeLen) + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
      (* Two ranges [a,a+alen) and [b,b+blen) overlap iff a < b+blen AND b < a+alen. *)
      IF (LONGINT(destParas) < LONGINT(u^.residentSeg) + LONGINT(uNeed))
       & (LONGINT(u^.residentSeg) < LONGINT(destParas) + LONGINT(needParas)) THEN
        RETURN FALSE
      END
    END;
    u := u^.next
  END;
  RETURN TRUE
END RegionFree;

(* FindFreeSpot: scan block i's ENTIRE [orgParas, endParas) range, not
   just from the current bump pointer, for the first position where a
   needParas-sized region is genuinely free (RegionFree) -- candidate
   positions are orgParas itself plus every resident module's own end
   paragraph (residentSeg + itsOwnNeedParas), since those are the only
   offsets a free gap can ever legitimately start at.  Found 2026-08-25
   (OVR-BUG.MD Bug 5, the SYSTEM.Halt(209) shape reached once PSTMT.MOD
   joins the $O+ pool alongside PExpr2.MOD): TryLoadIntoBlock's own
   monotonic bump pointer can walk PAST a position that would have fit
   (e.g. the large gap right after orgParas) before that gap's own
   blocking module(s) get evicted -- once ptrParas has moved on, the
   original single-obstruction-skip fix (see this procedure's own
   predecessor, ObstructionEnd, superseded here) could only ever skip
   FORWARD from wherever ptrParas already was, never back to an earlier,
   now-free gap.  A concrete repro: PSTMT.MOD resident in the MIDDLE of
   the block (not at orgParas) leaves a large free span BEFORE it and a
   small one after; if ptrParas is already past the large span when
   eviction frees everything else, only the small trailing span was ever
   considered, and the load failed even though the earlier span was
   easily big enough.  This full block-wide scan finds ANY qualifying
   gap regardless of where ptrParas happened to be. *)
PROCEDURE FindFreeSpot(i: INTEGER; needParas: WORD; VAR spotOut: WORD): BOOLEAN;
  VAR u: ModuleHeader; uNeed: WORD; cand: WORD;
BEGIN
  IF RegionFree(ovrHeaps[i].orgParas, needParas) THEN
    spotOut := ovrHeaps[i].orgParas; RETURN TRUE
  END;
  u := ovrLoadList;
  WHILE u # NIL DO
    IF u^.residentSeg # 0 THEN
      uNeed := WORD((LONGINT(u^.codeLen) + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
      cand := WORD(LONGINT(u^.residentSeg) + LONGINT(uNeed));
      IF (LONGINT(cand) >= LONGINT(ovrHeaps[i].orgParas))
       & (LONGINT(cand) + LONGINT(needParas) <= LONGINT(ovrHeaps[i].endParas))
       & RegionFree(cand, needParas) THEN
        spotOut := cand; RETURN TRUE
      END
    END;
    u := u^.next
  END;
  RETURN FALSE
END FindFreeSpot;

(* LoadModule: make u resident.  Allocates u^.codeLen bytes from the overlay
   buffer's bump pointer, evicting not-in-use modules (one at a time) until
   enough room is genuinely free or nothing more can be evicted; wraps
   back to ovrHeapOrgParas (this port's simplification of DOCS/OVR.MD
   §13.4's ring-buffer wraparound-and-slide, §17) when the bump
   pointer would overrun ovrHeapEndParas.  BUG FIX (found 2026-08-08
   setting up cross-overlay-calls eviction-pressure testing): "fits
   before ovrHeapEndParas" is NOT the same question as "this region is
   actually free" -- after a wraparound reset in particular, a still-
   resident module (e.g. the very module whose own call is what's driving
   this reload, mid-eviction-pressure) can occupy exactly the region the
   bump pointer just landed on.  RegionFree (above) checks real overlap
   against every resident module's own occupied range; the loop below keeps
   evicting until BOTH the end-of-buffer bound AND RegionFree hold.
   Confirmed via a debug probe: an earlier version of this fix (checking
   only the end-of-buffer bound after a wraparound reset) let a second
   module's LoadModule silently overlap the first, still-active module's own
   memory with TryEvictOne never firing at all.
   Reads the code (disk or EMS, per ovrUseEms) and applies the internal
   fixup table.  Does NOT eagerly patch every call site targeting u to
   the resident form (see the "repeat-call, no push" bug fixed
   2026-08-12, this procedure's own header comment update below, and
   OvrDispatch's own "Always (re-)patch THIS SITE" comment) -- only the
   ONE site that actually trapped is patched, by OvrDispatch itself right
   after this call returns; every OTHER site referencing u is patched
   lazily, the first time each one individually traps. *)
(* TryLoadIntoBlock: the original (pre-2026-08-21) single-buffer LoadModule
   bump/evict logic, verbatim, parameterized over WHICH block (ovrHeaps[i])
   to bump-allocate from.  Evicting via TryEvictOne is global (not
   restricted to block i) -- freeing space anywhere is never wrong, just
   occasionally not helpful for THIS block specifically; the caller's own
   per-block loop (LoadModule below) simply re-checks fit after each
   eviction and gives up on this block once TryEvictOne returns FALSE
   (nothing left to evict anywhere), falling through to try the next
   block. *)
PROCEDURE TryLoadIntoBlock(i: INTEGER; needParas: WORD; VAR destParasOut: WORD): BOOLEAN;
  VAR spot: WORD;
BEGIN
  (* The module cannot possibly fit even in a totally empty block -- fail
     fast rather than looping forever resetting to orgParas without ever
     reaching TryEvictOne (that branch only fires on the END-of-block
     condition, which this case can never clear). *)
  IF LONGINT(needParas) > LONGINT(ovrHeaps[i].endParas) - LONGINT(ovrHeaps[i].orgParas) THEN
    RETURN FALSE
  END;
  IF LONGINT(ovrHeaps[i].ptrParas) + LONGINT(needParas) > LONGINT(ovrHeaps[i].endParas) THEN
    ovrHeaps[i].ptrParas := ovrHeaps[i].orgParas
  END;
  WHILE (LONGINT(ovrHeaps[i].ptrParas) + LONGINT(needParas) > LONGINT(ovrHeaps[i].endParas))
      OR ~RegionFree(ovrHeaps[i].ptrParas, needParas) DO
    IF LONGINT(ovrHeaps[i].ptrParas) + LONGINT(needParas) > LONGINT(ovrHeaps[i].endParas) THEN
      ovrHeaps[i].ptrParas := ovrHeaps[i].orgParas
    ELSIF ~TryEvictOne() THEN
      (* Every module TryEvictOne could ever free has already been freed --
         it is now globally exhausted (OVR-BUG.MD Bug 5).  This is NOT
         necessarily "the block is too small": the monotonic bump pointer
         (ptrParas) may simply have walked PAST a gap that's genuinely
         free NOW, well before eviction actually freed it (a module
         resident in the MIDDLE of the block, e.g. a caller like PSTMT.MOD
         mid-call, splits the block into a span before it and a span after
         it -- ptrParas, having already advanced past the first span while
         probing, can never walk BACKWARD to revisit it under the plain
         bump/skip scheme this loop otherwise implements).  Before giving
         up, do one full block-wide scan (FindFreeSpot) for ANY position
         -- not just forward from ptrParas -- that's free now; if none
         exists, the block genuinely has no big enough contiguous span
         even after every eviction, and giving up is correct. *)
      IF FindFreeSpot(i, needParas, spot) THEN
        ovrHeaps[i].ptrParas := spot
      ELSE
        RETURN FALSE   (* this block too small even with everything evictable freed *)
      END
    END
  END;
  destParasOut := ovrHeaps[i].ptrParas;
  RETURN TRUE
END TryLoadIntoBlock;

PROCEDURE LoadModule(u: ModuleHeader): BOOLEAN;
  VAR needParas: WORD; destParas: WORD; codeFileOfs: LONGINT;
      rc: INTEGER; i: INTEGER; loaded: BOOLEAN;
BEGIN
  needParas := WORD((LONGINT(u^.codeLen) + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
  (* Try each block in turn (block 0 first, exactly the original single-
     block search order/behavior when NumHeapBlocks=1 would have been the
     whole story) -- falls over to the next block only once the current
     one's own TryLoadIntoBlock genuinely can't make room (full AND
     nothing left evictable anywhere). *)
  i := 0; loaded := FALSE;
  WHILE (i < NumHeapBlocks) & ~loaded DO
    loaded := TryLoadIntoBlock(i, needParas, destParas);
    IF ~loaded THEN INC(i) END
  END;
  IF ~loaded THEN RETURN FALSE END;

  codeFileOfs := u^.hdrFileOfs + LONGINT(ModuleHdrSize) + LONGINT(u^.fixupLen)
               + LONGINT(u^.xfixupLen) + LONGINT(u^.siteCount) * LONGINT(8)
               + LONGINT(u^.resumeCount) * LONGINT(6);
  IF ovrUseEms THEN
    rc := ReadSegmentFromEms(u, codeFileOfs - ovrFileBase, destParas)
  ELSE
    rc := ReadSegmentFromDisk(u, codeFileOfs, destParas)
  END;
  IF rc # ovrOk THEN
    RETURN FALSE
  END;

  IF ~ApplyFixups(u, destParas) THEN
    RETURN FALSE
  END;
  IF ~ApplyXFixups(u, destParas) THEN
    RETURN FALSE
  END;
  (* No eager PatchSitesForModule(u, TRUE, destParas) here -- see this
     procedure's own header comment.  Patching every known call site the
     moment ANY ONE of them traps was the bug: a site that has never yet
     executed as a real CALL (still CD 3F, or even still virgin 9A if the
     module loaded via a DIFFERENT site's trap first) would be overwritten
     straight to JMP FAR without ever going through Ovr_TrapEntry's own
     interrupt-frame return-address synthesis -- the ONLY place a return
     address is ever pushed for a fresh call site.  A later hit on that
     site then executed a bare JMP FAR with nothing on the stack for its
     target's own RETF to pop.  OvrDispatch (this procedure's own caller,
     right below) already patches the ONE site that actually trapped,
     unconditionally, every time -- that is sufficient: every site gets
     patched lazily, on its own first trap, whether or not its target
     module needed loading. *)
  u^.residentSeg := destParas;
  ovrHeaps[i].ptrParas := WORD(LONGINT(destParas) + LONGINT(needParas));
  INC(ovrLoadCount);
  RETURN TRUE
END LoadModule;

(* ResumeCallee: TRUE iff globalId is one of u's own resume points
   (return-address trampolines, cross-overlay calls, DOCS/OVR.MD §9),
   and if so, calleeId is the entry id of the
   module whose call it returns from.  Called UNCONDITIONALLY, first
   thing, on every single OvrDispatch -- genuinely a hot path, not the
   "not a hot path" this comment used to claim (found chasing DOCS/OVR.MD
   §16's "severe performance regression": u^.resumeCache below, filled
   once by RegisterModule's own LoadResumeCache, replaced what used to be
   a fresh Files.Seek + one Files.BlockRead PER ENTRY against the file on
   every one of those calls -- see ResumeNodeRec's own comment). *)
(* resumeOfs (added 2026-08-08, stale-return-address fix): the resume
   record's own "ofs" field -- caller's own in-module code offset to
   resume at.  Previously OvrDispatch just reused ReadTrampolineEntryOfs
   for BOTH ordinary entries and resumes, which was correct back when a
   resume trampoline's own bytes were physically patched into the
   caller's code at that exact offset (entryOfs WAS retOfs then).  Now
   that the resume trampoline lives in the resident redirect table
   instead (see Link.AddOvrReturnTrampoline's own comment), its bytes
   +3/+4 are always 0 (Overlay_InitResumeTrapTable never writes anything
   else there) -- reading them as "the resume offset" always resolved to
   0, silently resuming every caller at its own PROCEDURE START instead
   of the real mid-body return point (found via a full clean-rebuild
   test: Ovrdemo.Run re-executed from its own top in an infinite loop
   instead of printing "resumed" and returning to main).  The real
   value was always available in the resume record's own on-disk "ofs"
   field (buf[0..1]) -- just never read back before now. *)
PROCEDURE ResumeCallee(u: ModuleHeader; globalId: WORD; VAR calleeId: WORD; VAR resumeOfs: WORD): BOOLEAN;
  VAR node: ResumeNode; k: INTEGER;
BEGIN
  IF u^.resumeCount = 0 THEN RETURN FALSE END;
  node := u^.resumeCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      IF node^.globalId[k] = globalId THEN
        calleeId := node^.calleeGlobalId[k];
        resumeOfs := node^.ofs[k];
        RETURN TRUE
      END;
      INC(k)
    END;
    node := node^.next
  END;
  RETURN FALSE
END ResumeCallee;

(* FindResumeGlobalId: the INVERSE lookup of ResumeCallee -- given caller's
   own resume table, the entry id (calleeId) of the module caller JUST
   called (the id that trapped as an ORDINARY entry), and siteFileOfs (the
   caller-module-relative opcode offset of the call site that actually
   trapped, from FindSiteOwner's own matching scan), find the ONE resume
   record caller itself owns for THAT specific call site and return its
   own globalId (the resume trampoline's id, resumeTrapTable's own slot
   index).  Needed for the stale-return-address fix (2026-08-08, Solution
   2 regression) -- OvrDispatch's ordinary-entry path must know WHICH
   resident-table slot to bake as the return address, not just THAT the
   call is cross-overlay (FindSiteOwner already established that).  Also
   called every time a cross-overlay call site traps (ownerGlobalId #
   OvrNoOwner branch of OvrDispatch) -- same in-memory u^.resumeCache
   ResumeCallee above uses, not the file.
   BUG FIX (2026-08-21, OVR-BUG.MD "Bug 2"): matching on calleeId ALONE
   is wrong whenever caller has more than one call site targeting the
   SAME callee entry point (e.g. PEXPR.MOD calling the same overlay
   entry from dozens of distinct sites, including recursive call
   patterns) -- AddOvrReturnTrampoline (LINK.MOD) allocates one resume
   record PER CALL SITE, each with its own distinct globalId and its own
   distinct "ofs" (the caller-relative offset to resume AT, right after
   THAT site's own 5 trampoline bytes) , so a calleeId-only scan can
   return an arbitrary one of several sites' resume records -- whichever
   happens to come first in the (most-recently-added-first, see
   AddOvrReturnTrampoline's prepend) chunk chain -- with no guarantee it
   is the one belonging to the site that actually trapped.  The caller
   then gets redirected, on the callee's eventual RETF, to resume at the
   WRONG offset inside its own code: silent corruption (confirmed via
   PEXPR.MOD $O+, whose call pattern is the first in this project's
   history to have a caller with real multi-site traffic into the same
   overlay entry).  Disambiguated the only way that is unambiguous: the
   resume record's own on-disk "ofs" field is always siteFileOfs+5 --
   the call site's own reserved footprint is 5 bytes (matching the
   resident JMP-FAR rewrite form's own fixed width), unaffected by the
   swappable trampoline's own byte count (DOCS/OVR-ID-WIDEN-PLAN.MD step
   2 option (c), 2026-08-26 settled this at 4 bytes; a brief, reverted
   intermediate attempt made the trampoline itself 6 bytes and this
   +6, but the call site's own RESERVED width was never actually
   affected either way -- see Link.AddOvrReturnTrampoline's own retOfs
   computation), so matching on BOTH calleeId AND ofs=siteFileOfs+5
   identifies the exact site. *)
PROCEDURE FindResumeGlobalId(caller: ModuleHeader; calleeId: WORD; siteFileOfs: LONGINT; VAR resumeGlobalId: WORD): BOOLEAN;
  VAR node: ResumeNode; k: INTEGER; wantOfs: WORD;
BEGIN
  IF caller^.resumeCount = 0 THEN RETURN FALSE END;
  wantOfs := WORD(siteFileOfs) + WORD(5);
  node := caller^.resumeCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      IF (node^.calleeGlobalId[k] = calleeId) & (node^.ofs[k] = wantOfs) THEN
        resumeGlobalId := node^.globalId[k];
        RETURN TRUE
      END;
      INC(k)
    END;
    node := node^.next
  END;
  RETURN FALSE
END FindResumeGlobalId;

(* OvrDispatch: the real per-module lookup Ovr_DispatchStub (OVERLAY.ASM)
   calls into.  siteSeg:siteOfs is the trampoline site that trapped;
   ReadTrampolineId reads its id byte, DirEntry resolves that GLOBAL id
   (Link.State.ovrNextEntryId, DOCS/OVR.MD §7/§11.1) to its owning module's
   on-disk header offset, RegisterModule finds-or-creates that module's
   in-memory record.  If already resident: just re-patch THIS site to the
   resident form (it may have been evicted-then-reloaded by another call
   without this particular site being re-patched yet, if this is the
   first call through it since that reload) and mark inUse.  If not:
   LoadModule brings it in (which itself patches every site targeting it,
   including this one).  ovrHaveHandle/ovrDirectory being unset means
   Init was never called or failed -- this project's own convention is
   run-time error 208 ("Overlay manager not installed"), DOCS/OVR.MD's own
   text confirms the number; a real per-module read failure is
   error 209 ("overlay read error").  FAR + exported: this is the one
   procedure OVERLAY.ASM's Ovr_DispatchStub must be able to call across
   from its own hand-assembled body into this module's compiled code --
   confirmed as a supported pattern (this project's own maintainer,
   2026-08-07: "yes, asm can call other oberon"), resolving the open
   question this file's header comment used to carry.

   Returns the RESOLVED target seg:ofs (out params), not just a flag --
   Ovr_TrapEntry does not re-fetch the (now-patched) trampoline slot and
   IRET back into it; it JMPs FAR straight to this returned address
   itself, once, so the trapped call behaves exactly like the ordinary
   CALL FAR it stands in for (see Ovr_TrapEntry's own header comment for
   why re-executing the site was the wrong design).

   isResumeOut (0/1, WORD rather than BOOLEAN -- simpler to read back
   across the ASM boundary) tells Ovr_TrapEntry whether this id resolved
   to an ORDINARY entry point (a real trapped CALL FAR, isResumeOut=0) or
   one of a caller's own return-address trampolines (a callee's RETF
   landing on the resume site, isResumeOut=1).  The two cases need
   different stack handling on the ASM side: an ordinary call is standing
   in for a CALL FAR that never executed, so Ovr_TrapEntry must synthesize
   a fresh return-address frame for the target; a resume trampoline is NOT
   a call site at all -- it is the very return address an EARLIER call's
   RETF just landed on, so the stack is already exactly call-frame-shaped
   for the code being resumed, and Ovr_TrapEntry must do a plain far JMP
   with no new frame pushed (pushing one would insert a bogus return
   address -- back into the resume trampoline's own bytes -- underneath
   the real caller's frame, corrupting the stack the first time the
   resumed code's own RETF fires).

   retSegOut/retOfsOut (stale-return-address fix, 2026-08-08, Solution 2
   "inUse and eviction-pressure testing" regression): the RETURN address
   Ovr_TrapEntry should synthesize for an ORDINARY entry (ignored/
   unused for a resume, which never synthesizes a frame at all -- see
   above).  For a call site living in the MAIN IMAGE or a RESIDENT
   caller's own code, this is simply siteSeg:siteOfs+5 (that segment
   never moves, so baking it directly is always safe -- unchanged from
   the original design).  For a CROSS-OVERLAY call (the caller is
   itself overlay code, found via FindSiteOwner below), baking the
   caller's OWN resident segment directly is NOT safe: that segment can
   change (caller evicted-and-reloaded elsewhere) before the callee
   actually returns, silently corrupting the return address with no way
   to fix it up after the fact (confirmed via a 3-module A->B->C
   regression -- see Link.AddOvrReturnTrampoline's own comment for the
   full story).  So for THAT case, retSegOut/retOfsOut instead point
   into Overlay.ResumeTrapTable -- a small table in this whole module's
   own resident data, never swapped, whose segment can never go stale --
   at the slot for THIS call's own resume-trampoline global id (found via
   FindResumeGlobalId).  When the callee eventually returns, it lands on
   THAT slot's own INT 3Fh bytes, re-traps, and this same OvrDispatch
   resolves the resume normally, re-reading the caller's CURRENT resident
   segment fresh (exactly as any ordinary entry already does) -- so the
   caller's own segment is re-resolved every time, never baked stale. *)
PROCEDURE OvrDispatch*(siteSeg, siteOfs: WORD; VAR targetSeg, targetOfs: WORD;
                        VAR isResumeOut: WORD; VAR retSegOut, retOfsOut: WORD);
  VAR id: WORD; hdrFileOfs: LONGINT; u, callee, caller: ModuleHeader; entryOfs: WORD;
      calleeId: WORD; calleeHdrFileOfs: LONGINT; isResume: BOOLEAN;
      ownerGlobalId: WORD; ownerHdrFileOfs: LONGINT; resumeGlobalId: WORD;
      staleEntryOfs: WORD; ownerSiteFileOfs: LONGINT;
BEGIN
  IF ~ovrHaveHandle OR (ovrDirectory = NIL) THEN SYSTEM.Halt(208) END;
  INC(ovrTrapCount);

  id := ReadTrampolineId(siteSeg, siteOfs);
  IF WORD(id) >= ovrEntryIdCount THEN SYSTEM.Halt(291) END;
  hdrFileOfs := DirEntry(WORD(id));

  u := RegisterModule(hdrFileOfs);
  IF u = NIL THEN
    SYSTEM.Halt(292)
  END;

  (* entryOfs is id's own in-module code offset -- now read straight
     from the .OVR directory (DirEntryOfs), not from the call site's own
     bytes at all (DOCS/OVR-ID-WIDEN-PLAN.MD step 2 option (c),
     2026-08-26: entryOfs moved out of the trampoline format entirely,
     since it is purely a function of id, never call-site-specific).
     Only meaningful for an ORDINARY entry; for a RESUME trap id's own
     directory slot always holds 0 (LinkOvr.DirectResumeDirSlots never
     writes anything else there) and is OVERWRITTEN below, once
     ResumeCallee resolves the real value from the resume record's own
     on-disk "ofs" field (stale-return-address fix, 2026-08-08 -- see
     ResumeCallee's own comment for the bug this fixes). *)
  entryOfs := DirEntryOfs(WORD(id));

  (* Default: same segment/offset+5 as the trap site itself -- the call
     site's own reserved footprint is 5 bytes regardless of the
     swappable trampoline's own byte count (DOCS/OVR-ID-WIDEN-PLAN.MD
     step 2 option (c), 2026-08-26 settled on a 4-byte trampoline; a
     brief, reverted intermediate attempt used +6) -- correct unless the
     cross-overlay branch below overrides it. *)
  retSegOut := siteSeg; retOfsOut := siteOfs + WORD(5);

  (* Cross-overlay calls (DOCS/OVR.MD §9): if this id
     is one of u's own resume points (a return-address trampoline, not a
     real public entry point), the callee whose call is now returning
     must have its own inUse decremented -- it may safely be evicted
     again once this reaches 0.  Must happen BEFORE u^.residentSeg is
     checked/loaded below: loading u (the CALLER module, resuming after
     possibly being evicted itself) and decrementing the CALLEE's inUse
     are independent bookkeeping, but doing this first keeps the "resolve
     everything about this id, then act" structure the ordinary entry
     path already follows above. *)
  isResume := ResumeCallee(u, WORD(id), calleeId, entryOfs);
  IF isResume THEN
    calleeHdrFileOfs := DirEntry(calleeId);
    callee := RegisterModule(calleeHdrFileOfs);
    IF (callee # NIL) & (callee^.inUse > 0) THEN DEC(callee^.inUse) END
  ELSE
    (* Real per-call inUse nesting (DOCS/OVR.MD §10, "inUse and eviction-
       pressure testing", closed 2026-08-08): this is a fresh call INTO
       u.  If the call SITE itself lives inside another overlay module's
       own code (a cross-overlay call), that caller module is about to go
       idle -- it made the call and is now just waiting on the stack for
       u to return, so it becomes safely evictable while idle. This
       module finds the caller via FindSiteOwner reading the SAME
       ownerGlobalId PatchSitesForModule already writes into every
       call-site record, just never previously read back at dispatch
       time.  Must happen BEFORE
       u^.residentSeg is loaded below, mirroring the resume branch's own
       "resolve everything, then act" ordering; DirEntry(ownerGlobalId)
       is safe to call before u's own load since it only reads the
       (already-loaded) on-disk directory, not any module's resident code. *)
    ownerGlobalId := FindSiteOwner(u, siteSeg, siteOfs, ownerSiteFileOfs);
    IF ownerGlobalId # OvrNoOwner THEN
      ownerHdrFileOfs := DirEntry(ownerGlobalId);
      caller := RegisterModule(ownerHdrFileOfs);
      IF (caller # NIL) & (caller^.inUse > 0) THEN DEC(caller^.inUse) END;
      (* Stale-return-address fix: redirect the synthesized return
         address through the resident table instead of caller's own
         (possibly soon-stale) segment -- see this procedure's own
         header comment.  ownerSiteFileOfs (Bug 2 fix, OVR-BUG.MD)
         identifies WHICH of caller's own call sites into u actually
         trapped, so FindResumeGlobalId picks the matching resume
         record even when caller has several call sites into the same
         callee entry point. *)
      IF (caller # NIL) & FindResumeGlobalId(caller, WORD(id), ownerSiteFileOfs, resumeGlobalId) THEN
        retSegOut := ovrResumeTrapTableSeg;
        (* *WORD(4): the resume table's own slot width -- 4 bytes
           (id:WORD only, entryOfs no longer stored in any trampoline
           slot at all, DOCS/OVR-ID-WIDEN-PLAN.MD step 2 option (c),
           2026-08-26; a brief, reverted intermediate attempt made this
           *WORD(6)). *)
        retOfsOut := ovrResumeTrapTableOfs + resumeGlobalId * WORD(4)
      END
    END
  END;

  IF u^.residentSeg = 0 THEN
    IF ~LoadModule(u) THEN
      SYSTEM.Halt(209)
    END
  END;

  (* NEVER patch a call site to the resident JMP FAR form (reverted
     2026-08-12 -- see this procedure's own header comment for the full
     story).  A call site is only ever CD 3F id entryOfs: every single
     call through it, first or hundredth, traps and re-runs this
     dispatch.  u^.residentSeg#0 (checked above) already makes a repeat
     dispatch into an already-loaded module cheap (skips LoadModule entirely,
     just a RegisterModule cache hit) -- what's given up is the literal
     single-JMP fast path for a call site executed more than once, which
     no existing overlay fixture ever exercised (found via a WHILE-loop
     reproducer, EXAMPLES/OVRDEMO/repro7_loop_call/) but real code
     absolutely does (e.g. this project's own compiler calling
     Def.DefWrite once per compiled module -- structurally a loop).
     CacheEntryOfs kept for symmetry with the eviction path's own
     fallback lookup, though with sites never becoming JMP FAR it can no
     longer actually matter (every site's own CD-3F bytes are always
     honest).  Gated on CachedEntryOfs first (found 2026-08-16
     self-hosting): CacheEntryOfs itself has no dedup -- an entryId
     already cached still gets a fresh duplicate slot appended on every
     repeat dispatch (this comment's own "Def.DefWrite once per compiled
     module" example calls through the SAME entryId every time), growing
     entryOfsCache one more entry forever, for the life of the process --
     a real unbounded leak, not just a leak-guard accounting artifact,
     surfacing as "heap leak ... in Cgen.CgFree() (N paragraphs)" on
     whichever source file happened to be compiling when the 9th (then
     17th, ...) call landed. *)
  IF ~isResume THEN
    IF ~CachedEntryOfs(u, WORD(id), staleEntryOfs) THEN
      CacheEntryOfs(u, WORD(id), entryOfs)
    END
  END;

  (* inUse nesting, continued: a RESUME re-increments u's own inUse --
     u (the caller, resuming) went idle the moment it made the
     now-returning call (decremented above, in a PRIOR dispatch, by
     THIS module's own caller-DEC branch when u's outgoing call site
     itself trapped) and becomes busy again now that control is back
     with it.  This is the cross-overlay caller-idle signal (DOCS/OVR.MD
     §10) -- still real, still needed, untouched by the epilogue-counter
     fix below.
     An ORDINARY entry used to ALSO INC(u^.inUse) here unconditionally
     (matching TryEvictOne's old "never evict inUse#0" contract) -- but
     for a module WITH a real epilogue counter (HasCounter), that job now
     belongs entirely to the counter (INC'd by u's own compiled prologue,
     DEC'd by its epilogue, tracking real in-body execution independent of
     the trap mechanism -- OVR-BUG.MD).  Still INC-ing inUse here
     unconditionally for such a module left inUse permanently elevated
     the instant ANY ordinary call ever traps once -- TryEvictOne's old
     "prefer the counter, else inUse" logic then let counter=0 alone
     authorize eviction while inUse stayed stuck at that stale nonzero
     value FOREVER, silently masking the real problem: a module's own
     inUse could go stale (nonzero, meaning "some earlier caller relationship
     never resolved") while its counter correctly said idle, and something
     else still trusted that inUse value elsewhere -- confirmed via a real
     self-hosting corruption (compiling with PEXPR.MOD $O+, the first
     module exercising real cross-overlay resume chains: inUse=1 persisted
     on a module whose counter=0, TryEvictOne evicted it anyway, corrupting
     memory a live resume return address still pointed into).  Skipping the
     ordinary-entry INC entirely for a HasCounter module keeps inUse
     reserved purely for cross-overlay caller/callee bookkeeping (the DEC/
     INC pairs above and below), the one job it still does correctly. *)
  IF isResume OR ~HasCounter(u) THEN INC(u^.inUse) END;
  targetSeg := u^.residentSeg;
  targetOfs := entryOfs;
  IF isResume THEN isResumeOut := 1 ELSE isResumeOut := 0 END;
END OvrDispatch;

(*$L OVERLAY.RDF*)

BEGIN
  IF SYSTEM.IsDPMI() THEN
    SYSTEM.DOSMESSAGE('Overlay is not available with DPMI$');
    SYSTEM.Halt(255);
  END;
  ovrHaveHandle := FALSE;
  ovrFileBase := 0;
  ovrPayloadStart := 0;
  ovrFileMode := 0;
  i := 0;
  WHILE i < NumHeapBlocks DO
    ovrHeaps[i].orgParas := 0; ovrHeaps[i].ptrParas := 0; ovrHeaps[i].endParas := 0;
    ovrHeaps[i].buf := NIL;
    INC(i)
  END;
  ovrHeapSizeParas := 0;
  ovrRetrySize := 0;
  ovrLoadList := NIL;
  ovrResult := ovrOk;
  ovrTrapCount := 0; ovrLoadCount := 0;
  ovrEmsHandle := 0; ovrEmsPages := 0;
  ovrUseEms := FALSE;
  ovrTrapInstalled := FALSE;
  prevExitProc := NIL;
  ovrEntryIdCount := 0;
  ovrDirectory := NIL;
  ovrResumeTrapTable := NIL;
  ovrResumeTrapTableSeg := 0; ovrResumeTrapTableOfs := 0
END Overlay.
