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
     ModuleHeaderDesc's own codeLen comment. *)
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

  ovrHeapOrgParas, ovrHeapPtrParas, ovrHeapEndParas: WORD; (* segment values *)
  ovrHeapSizeParas: WORD;
  ovrHeapBuf: SYSTEM.ADDRESS;  (* the actual SYSTEM.Alloc block backing the
                                   overlay buffer, or NIL -- kept separately
                                   from ovrHeapOrgParas (which only has the
                                   segment, needed for SYSTEM.Free's own
                                   pointer) so a second OvrSetBuf call can
                                   free the previous block instead of
                                   leaking it (this project's zero-heap-
                                   leaks rule, CLAUDE.md) *)
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
  ovrResumeTrapTableSeg: WORD; (* OVERLAY.ASM's resumeTrapTable own
                                   segment, cached by Init -- fixed for
                                   the life of the program (this whole
                                   module is resident).  Stale-return-
                                   address fix, 2026-08-08, see
                                   Link.AddOvrReturnTrampoline's own
                                   comment. *)
  ovrResumeTrapTableOfs: WORD; (* resumeTrapTable's own IN-SEGMENT byte
                                   offset -- NOT assumed to be 0 (found
                                   2026-08-08: it isn't -- see
                                   Overlay_ResumeTrapTableOfs's own
                                   comment for the crash this caused).
                                   slot(globalId)'s real offset is this
                                   PLUS globalId*5, never globalId*5
                                   alone. *)

(* ---- OVERLAY.ASM externals (see that file for what each does) ---- *)

PROCEDURE InstallHandler; FAR; EXTERNAL;
PROCEDURE RemoveHandler; FAR; EXTERNAL;
PROCEDURE PatchTrampoline(siteSeg, siteOfs: WORD; toResident: BOOLEAN;
                          targetSeg, targetOfs: WORD); FAR; EXTERNAL;
PROCEDURE ReadTrampolineId(siteSeg, siteOfs: WORD): BYTE; FAR; EXTERNAL;
PROCEDURE ReadTrampolineEntryOfs(siteSeg, siteOfs: WORD): WORD; FAR; EXTERNAL;
PROCEDURE ResumeTrapTableSeg(): WORD; FAR; EXTERNAL;
PROCEDURE ResumeTrapTableOfs(): WORD; FAR; EXTERNAL;
PROCEDURE InitResumeTrapTable; FAR; EXTERNAL;

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
   guarded (ovrTrapInstalled/ovrUseEms/ovrHeapBuf#NIL), so this is safe to
   run regardless of how far Init/OvrSetBuf/InitEMS got. *)
PROCEDURE ExitCleanup; FAR;
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
  IF ovrHeapBuf # NIL THEN
    SYSTEM.Free(ovrHeapBuf); ovrHeapBuf := NIL
  END;
  IF ovrDirectory # NIL THEN
    SYSTEM.Free(ovrDirectory); ovrDirectory := NIL
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
   0, then entryIdCount LONGINT file offsets right after.  Frees any
   previous ovrDirectory first (guards a second Init call the same way
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

  dirBytes := WORD(LONGINT(ovrEntryIdCount) * LONGINT(4));
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
  INC(p, LONGINT(entryId) * LONGINT(4));
  b0 := WORD(ORD(p^[0])); b1 := WORD(ORD(p^[1]));
  b2 := WORD(ORD(p^[2])); b3 := WORD(ORD(p^[3]));
  base := LONGINT(b0) + LONGINT(b1)*LONGINT(256)
        + LONGINT(b2)*LONGINT(65536) + LONGINT(b3)*LONGINT(16777216);
  RETURN base + ovrPayloadStart
END DirEntry;

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
     Link.AddOvrReturnTrampoline's own comment.  Idempotent to call again
     on a second Init (harmless re-fill of the same 256 slots), so no
     ovrResumeTableInited-style guard is needed the way ovrTrapInstalled
     needs one for the vector install. *)
  ovrResumeTrapTableSeg := ResumeTrapTableSeg();
  ovrResumeTrapTableOfs := ResumeTrapTableOfs();
  InitResumeTrapTable;

  ovrResult := ovrOk;
  RETURN ovrResult
END Init;

(* ---- OvrSetBuf / OvrGetBuf, DOCS/OVR.MD §13.2 ----
   This toolchain's Oberon runtime has no "shrink the heap ceiling"
   primitive exposed to library code (SYSTEM.Alloc/Free manage a
   free-list, not a movable ceiling an ordinary module can adjust) --
   so ovrHeapOrg/ovrHeapPtr/ovrHeapEnd here track the overlay buffer as
   its own independent region, allocated via a plain SYSTEM.Alloc block.
   The overlay buffer's own bookkeeping is a simple bump allocator
   between ovrHeapOrg and ovrHeapEnd. *)

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
PROCEDURE OvrSetBuf*(size: LONGINT);
  VAR paras: WORD; blk: SYSTEM.ADDRESS;
BEGIN
  IF ~ovrHaveHandle THEN ovrResult := ovrError; RETURN END;
  IF ovrLoadList # NIL THEN ovrResult := ovrError; RETURN END;
  IF size < LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize) THEN
    size := LONGINT(ovrHeapSizeParas) * LONGINT(ParaSize)
  END;
  paras := WORD((size + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
  IF paras < MinHeapParas THEN paras := MinHeapParas END;

  (* WORD, not INTEGER: paras*ParaSize legitimately exceeds 32767 (e.g.
     4094*16=65504) -- SYSTEM.Alloc's own parameter is WORD, and an
     INTEGER*INTEGER multiply here traps the CPU's overflow exception
     (int 04) the moment the product itself doesn't fit signed 16-bit,
     even though both operands individually do. *)
  blk := SYSTEM.ADDRESS(SYSTEM.Alloc(WORD(paras) * WORD(ParaSize)));
  IF blk = NIL THEN ovrResult := ovrNoMemory; RETURN END;

  (* Free a previous buffer, if OvrSetBuf is being called again before any
     overlay was ever loaded (ovrLoadList = NIL is only checked above to
     block RESIZING an in-use buffer, not a second call before first use). *)
  IF ovrHeapBuf # NIL THEN SYSTEM.Free(ovrHeapBuf) END;
  ovrHeapBuf := blk;

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
  ovrHeapOrgParas := WORD(LONGINT(blk) DIV LONGINT(65536));
  ovrHeapPtrParas := ovrHeapOrgParas;
  ovrHeapEndParas := WORD(LONGINT(ovrHeapOrgParas) + LONGINT(paras));
  ovrResult := ovrOk
END OvrSetBuf;

PROCEDURE OvrGetBuf*(): LONGINT;
BEGIN
  RETURN LONGINT(WORD(ovrHeapEndParas - ovrHeapOrgParas)) * LONGINT(ParaSize)
END OvrGetBuf;

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
  VAR u: ModuleHeader;
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
  ovrHeapPtrParas := ovrHeapOrgParas;
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
PROCEDURE FindSiteOwner(u: ModuleHeader; siteSeg, siteOfs: WORD): WORD;
  VAR node: SiteNode; k: INTEGER;
      siteFileOfs: LONGINT; loadSeg, candSeg, candOfs: WORD;
      ownerGlobalId: WORD; ownerHdrFileOfs: LONGINT; owner: ModuleHeader;
      wantLinear, candLinear: LONGINT;
BEGIN
  IF u^.siteCount = 0 THEN RETURN OvrNoOwner END;
  IF (siteSeg < ovrHeapOrgParas) OR (siteSeg >= ovrHeapEndParas) THEN
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
        IF candLinear = wantLinear THEN RETURN ownerGlobalId END
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
        IF toResident THEN
          (* Each call site may target a DIFFERENT entry point within this
             same module (OVERLAY.MOD/LINK.MOD's own use of the trampoline's
             id-byte+3/+4 bytes, see Overlay_ReadTrampolineEntryOfs) -- read
             THIS site's own in-module code offset before overwriting it with
             the resident JMP FAR form, so the jump target is destParas:
             entryOfs, not always destParas:0 (which would jump into
             whichever entry happens to be first in the module's own code,
             typically __init).  Use the entryOfsCache once this entryId has
             been seen before -- the trampoline bytes this READ would
             otherwise use are the exact bytes the LAST resident-form patch
             overwrote (EntryOfsNodeRec's own comment: this cache exists
             precisely because that read is only trustworthy the first
             time). *)
          IF ~CachedEntryOfs(u, entryId, entryOfs) THEN
            entryOfs := ReadTrampolineEntryOfs(siteSeg, siteOfs);
            CacheEntryOfs(u, entryId, entryOfs)
          END;
          PatchTrampoline(siteSeg, siteOfs, TRUE, destParas, entryOfs)
        ELSE
          (* Restoring the swappable form needs (entryId, entryOfs) written
             back explicitly too (Overlay_PatchTrampoline's own header
             comment) -- entryId is already known (read from the call-site
             table above); entryOfs comes from the SAME cache OvrDispatch's
             own individual-site patch populates (2026-08-12: LoadModule no
             longer eagerly patches every site, so the cache is filled one
             entry at a time, by whichever code path -- this one or
             OvrDispatch's -- first resident-patches a given site) --
             falling back to a fresh read (still correct: an entryId whose
             cache entry is missing here can only mean NONE of its sites
             have individually trapped yet, so every one of them is still
             holding its original, honest CD 3F entryOfs bytes) if this
             entryId was never patched resident in this process at all. *)
          IF ~CachedEntryOfs(u, entryId, entryOfs) THEN
            entryOfs := ReadTrampolineEntryOfs(siteSeg, siteOfs);
            CacheEntryOfs(u, entryId, entryOfs)
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

(* TryEvictOne: find the first ovrLoadList entry that is resident and not
   in use, and evict it (DOCS/OVR.MD §13.4's "never evict inUse#0" rule --
   §17's documented simplification of the full ring+probation
   scheme).  Returns FALSE if every resident module is currently in use
   (nothing could be evicted). *)
PROCEDURE TryEvictOne(): BOOLEAN;
  VAR u: ModuleHeader;
BEGIN
  u := ovrLoadList;
  WHILE u # NIL DO
    IF (u^.residentSeg # 0) & (u^.inUse = 0) THEN
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
PROCEDURE LoadModule(u: ModuleHeader): BOOLEAN;
  VAR needParas: WORD; destParas: WORD; codeFileOfs: LONGINT;
      rc: INTEGER;
BEGIN
  needParas := WORD((LONGINT(u^.codeLen) + LONGINT(ParaSize - 1)) DIV LONGINT(ParaSize));
  (* The module cannot possibly fit even in a totally empty buffer -- fail
     fast rather than looping forever resetting to ovrHeapOrgParas without
     ever reaching TryEvictOne (that branch only fires on the END-of-
     buffer condition, which this case can never clear). *)
  IF LONGINT(needParas) > LONGINT(ovrHeapEndParas) - LONGINT(ovrHeapOrgParas) THEN
    RETURN FALSE
  END;
  IF LONGINT(ovrHeapPtrParas) + LONGINT(needParas) > LONGINT(ovrHeapEndParas) THEN
    ovrHeapPtrParas := ovrHeapOrgParas
  END;
  WHILE (LONGINT(ovrHeapPtrParas) + LONGINT(needParas) > LONGINT(ovrHeapEndParas))
      OR ~RegionFree(ovrHeapPtrParas, needParas) DO
    IF LONGINT(ovrHeapPtrParas) + LONGINT(needParas) > LONGINT(ovrHeapEndParas) THEN
      ovrHeapPtrParas := ovrHeapOrgParas
    ELSIF ~TryEvictOne() THEN
      RETURN FALSE   (* overlay buffer too small even with everything evictable freed *)
    END
  END;
  destParas := ovrHeapPtrParas;

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
  ovrHeapPtrParas := WORD(LONGINT(destParas) + LONGINT(needParas));
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
   own resume table and the entry id (calleeId) of the module caller JUST
   called (the id that trapped as an ORDINARY entry), find the resume
   record caller itself owns for THAT specific call and return its own
   globalId (the resume trampoline's id, resumeTrapTable's own slot
   index).  Needed for the stale-return-address fix (2026-08-08, Solution
   2 regression) -- OvrDispatch's ordinary-entry path must know WHICH
   resident-table slot to bake as the return address, not just THAT the
   call is cross-overlay (FindSiteOwner already established that).  Also
   called every time a cross-overlay call site traps (ownerGlobalId #
   OvrNoOwner branch of OvrDispatch) -- same in-memory u^.resumeCache
   ResumeCallee above uses, not the file. *)
PROCEDURE FindResumeGlobalId(caller: ModuleHeader; calleeId: WORD; VAR resumeGlobalId: WORD): BOOLEAN;
  VAR node: ResumeNode; k: INTEGER;
BEGIN
  IF caller^.resumeCount = 0 THEN RETURN FALSE END;
  node := caller^.resumeCache;
  WHILE node # NIL DO
    k := 0;
    WHILE k < node^.count DO
      IF node^.calleeGlobalId[k] = calleeId THEN
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
  VAR id: BYTE; hdrFileOfs: LONGINT; u, callee, caller: ModuleHeader; entryOfs: WORD;
      calleeId: WORD; calleeHdrFileOfs: LONGINT; isResume: BOOLEAN;
      ownerGlobalId: WORD; ownerHdrFileOfs: LONGINT; resumeGlobalId: WORD;
      staleEntryOfs: WORD;
BEGIN
  IF ~ovrHaveHandle OR (ovrDirectory = NIL) THEN SYSTEM.Halt(208) END;
  INC(ovrTrapCount);

  id := ReadTrampolineId(siteSeg, siteOfs);
  IF WORD(id) >= ovrEntryIdCount THEN SYSTEM.Halt(209) END;
  hdrFileOfs := DirEntry(WORD(id));

  u := RegisterModule(hdrFileOfs);
  IF u = NIL THEN
    SYSTEM.Halt(209)
  END;

  (* entryOfs is THIS site's own in-module code offset (Overlay_
     ReadTrampolineEntryOfs), not necessarily the same entry point
     another site targets -- must be read BEFORE any patch write touches
     this site's own bytes+3/+4.  Only meaningful for an ORDINARY entry;
     for a RESUME trap it reads the resident table's own always-zero
     trailing bytes (Overlay_InitResumeTrapTable never writes anything
     else there) and is OVERWRITTEN below, once ResumeCallee resolves
     the real value from the resume record's own on-disk "ofs" field
     (stale-return-address fix, 2026-08-08 -- see ResumeCallee's own
     comment for the bug this fixes). *)
  entryOfs := ReadTrampolineEntryOfs(siteSeg, siteOfs);

  (* Default: same segment/offset+5 as the trap site itself -- correct
     unless the cross-overlay branch below overrides it. *)
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
    ownerGlobalId := FindSiteOwner(u, siteSeg, siteOfs);
    IF ownerGlobalId # OvrNoOwner THEN
      ownerHdrFileOfs := DirEntry(ownerGlobalId);
      caller := RegisterModule(ownerHdrFileOfs);
      IF (caller # NIL) & (caller^.inUse > 0) THEN DEC(caller^.inUse) END;
      (* Stale-return-address fix: redirect the synthesized return
         address through the resident table instead of caller's own
         (possibly soon-stale) segment -- see this procedure's own
         header comment. *)
      IF (caller # NIL) & FindResumeGlobalId(caller, WORD(id), resumeGlobalId) THEN
        retSegOut := ovrResumeTrapTableSeg;
        retOfsOut := ovrResumeTrapTableOfs + resumeGlobalId * WORD(5)
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

  (* inUse nesting, continued: an ORDINARY entry increments u's own
     inUse (one INC per genuine call, matching TryEvictOne's "never
     evict inUse#0" contract).  A RESUME re-increments u's own inUse
     too -- u (the caller, resuming) went idle the moment it made the
     now-returning call (decremented above, in a PRIOR dispatch, by
     THIS module's own caller-DEC branch when u's outgoing call site
     itself trapped) and becomes busy again now that control is back
     with it.  This replaces the old "resume never increments, caller
     stays inUse for its whole activation" rule -- the one that made
     eviction of an idle-but-on-stack caller structurally impossible
     (see DOCS/OVR.MD §10 for the full before/after). *)
  INC(u^.inUse);
  targetSeg := u^.residentSeg;
  targetOfs := entryOfs;
  IF isResume THEN isResumeOut := 1 ELSE isResumeOut := 0 END
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
  ovrHeapOrgParas := 0; ovrHeapPtrParas := 0; ovrHeapEndParas := 0;
  ovrHeapBuf := NIL;
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
  ovrDirectory := NIL
END Overlay.
