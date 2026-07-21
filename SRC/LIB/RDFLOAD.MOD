(*$R-*)(*$D-*)
MODULE RdfLoad;

(* Minimal dynamic-loader for RDOFF2 object files.
   Loads a .RDF into freshly-allocated code/data heap blocks, resolves
   external IMPORTs against the host runtime (built-in SYSTEM_* table
   plus an optional user resolver), applies relocation and
   segment-relocation records, then exposes any GLOBAL symbols through
   GetProcAddress.  See examples/RDFLOAD/README.TXT. *)

IMPORT Files, Strings;

CONST
  RecReloc    = 1;
  RecImport   = 2;
  RecGlobal   = 3;
  RecBss      = 5;
  RecSegReloc = 6;

  MaxSeg*     = 64;   (* RDOFF2 physical-segment index is 6 bits: segNum 0..63.
                         segNum (physical index, addressed by a RELOC's
                         low-6-bit "physical segment" field / a SEGRELOC's
                         segment-index byte) is DISTINCT from segType (kind:
                         1=code, 2=data). See DOCS/RDOFF2.MD §4. *)

TYPE
  (* Resolver: returns the host address of `name`, or NIL if unknown. *)
  Resolver* = PROCEDURE(name: ARRAY OF CHAR): SYSTEM.ADDRESS;

  ExportSym = POINTER TO ExportSymDesc;
  ExportSymDesc = RECORD
    name: ARRAY 33 OF CHAR;
    addr: SYSTEM.ADDRESS;
    next: ExportSym
  END;

  ImportSym = POINTER TO ImportSymDesc;
  ImportSymDesc = RECORD
    segId: INTEGER;                (* RDOFF2 16-bit unique id, >= 3   *)
    name:  ARRAY 33 OF CHAR;
    addr:  SYSTEM.ADDRESS;          (* host-side resolved address; NIL if unresolved *)
    next:  ImportSym
  END;

  (* One physical segment.  A module may hold up to MaxSeg of these, each
     addressed by its own segNum.  segType is the KIND (1=code, 2=data);
     segNum is the PHYSICAL INDEX a relocation patches into.  These are two
     independent values — an RDF may, e.g., carry several code segments each
     with segType=1 but distinct segNum.  Internal: RDFModule stays an opaque
     handle to importers (RDFModuleDesc's fields are not exported), so SegInfo
     does not enter the public interface either. *)
  SegInfo = RECORD
    base:    SYSTEM.ADDRESS;   (* heap block holding this segment (NIL if empty) *)
    segType: INTEGER;          (* 1=code, 2=data *)
    segNum:  INTEGER;          (* physical index 0..MaxSeg-1 *)
    rawSize: WORD;             (* file-backed byte count (before BSS tail) *)
    size:    WORD;             (* allocated byte count (raw, aligned; first DATA seg also holds BSS) *)
    bss:     WORD              (* BSS bytes appended after rawSize (data segments only) *)
  END;

  RDFModule* = POINTER TO RDFModuleDesc;
  (* RDFModuleDesc is exported (like Link.StateRec) so the .def emits its RECORD
     header + size and importers can resolve `POINTER RDFModuleDesc`.  Its FIELDS
     stay non-exported, so the record is opaque and SegInfo never enters the
     interface. *)
  RDFModuleDesc* = RECORD
    (* Per-segment store, indexed by segNum. *)
    seg:         ARRAY MaxSeg OF SegInfo;
    nSeg*:       INTEGER;          (* highest (segNum+1) seen; slots 0..nSeg-1 valid-or-empty.
                                      Exported (a harmless scalar) so RDFModuleDesc's .def
                                      RECORD block carries a FIELD line — a field-less
                                      exported record's stub does not round-trip through the
                                      importer's .def pre-pass (empty RECORD/END). *)
    (* Legacy convenience aliases into seg[] — the FIRST code segment and the
       FIRST data segment — so existing two-segment callers keep working. *)
    codeBase:    SYSTEM.ADDRESS;
    dataBase:    SYSTEM.ADDRESS;
    codeSize:    WORD;
    dataSize:    WORD;
    dataRawSize: WORD;
    exports:     ExportSym;
    imports:     ImportSym
  END;

  RdfHeader = RECORD
    sign:     ARRAY 6 OF CHAR;
    modSize:  LONGINT;
    headSize: LONGINT
  END;

  SegHeader = RECORD
    segType:  INTEGER;
    segNum:   INTEGER;
    reserved: INTEGER;
    length:   LONGINT
  END;

  RecHeader = RECORD
    recType: BYTE;
    recLen:  BYTE
  END;

(* Built-in resolver: maps `Mod_Sym` names to host-side addresses for the
   SYSTEM, Files, and Strings runtime modules that RdfLoad already imports.
   Returns NIL for unknown names — callers can fall back to a user resolver. *)
PROCEDURE BuiltinResolve(name: ARRAY OF CHAR): SYSTEM.ADDRESS;
BEGIN
  (* SYSTEM — provided by SYSTEM.ASM at link time *)
  IF    Strings.Equal(name, "SYSTEM_Alloc")   THEN RETURN SYSTEM.ADR(SYSTEM.Alloc)
  ELSIF Strings.Equal(name, "SYSTEM_Free")    THEN RETURN SYSTEM.ADR(SYSTEM.Free)
  ELSIF Strings.Equal(name, "SYSTEM_Halt")    THEN RETURN SYSTEM.ADR(SYSTEM.Halt)
  ELSIF Strings.Equal(name, "SYSTEM_Intr")    THEN RETURN SYSTEM.ADR(SYSTEM.Intr)
  ELSIF Strings.Equal(name, "SYSTEM_CallFar") THEN RETURN SYSTEM.ADR(SYSTEM.CallFar)
  ELSIF Strings.Equal(name, "SYSTEM_S32MUL")  THEN RETURN SYSTEM.ADR(SYSTEM.S32MUL)
  ELSIF Strings.Equal(name, "SYSTEM_S32DIV")  THEN RETURN SYSTEM.ADR(SYSTEM.S32DIV)
  ELSIF Strings.Equal(name, "SYSTEM_S32MOD")  THEN RETURN SYSTEM.ADR(SYSTEM.S32MOD)
  ELSIF Strings.Equal(name, "SYSTEM_ErrDivisionByZero")   THEN RETURN SYSTEM.ADR(SYSTEM.ErrDivisionByZero)
  ELSIF Strings.Equal(name, "SYSTEM_ErrIndexOutOfBounds") THEN RETURN SYSTEM.ADR(SYSTEM.ErrIndexOutOfBounds)
  ELSIF Strings.Equal(name, "SYSTEM_ErrStackOverflow")    THEN RETURN SYSTEM.ADR(SYSTEM.ErrStackOverflow)
  ELSIF Strings.Equal(name, "SYSTEM_ErrInvalidPointerOperation") THEN RETURN SYSTEM.ADR(SYSTEM.ErrInvalidPointerOperation)
  (* Files *)
  ELSIF Strings.Equal(name, "Files_Reset")      THEN RETURN SYSTEM.ADR(Files.Reset)
  ELSIF Strings.Equal(name, "Files_ReWrite")    THEN RETURN SYSTEM.ADR(Files.ReWrite)
  ELSIF Strings.Equal(name, "Files_Append")     THEN RETURN SYSTEM.ADR(Files.Append)
  ELSIF Strings.Equal(name, "Files_ReWriteTemp")THEN RETURN SYSTEM.ADR(Files.ReWriteTemp)
  ELSIF Strings.Equal(name, "Files_Close")      THEN RETURN SYSTEM.ADR(Files.Close)
  ELSIF Strings.Equal(name, "Files_Seek")       THEN RETURN SYSTEM.ADR(Files.Seek)
  ELSIF Strings.Equal(name, "Files_Position")   THEN RETURN SYSTEM.ADR(Files.Position)
  ELSIF Strings.Equal(name, "Files_Size")       THEN RETURN SYSTEM.ADR(Files.Size)
  ELSIF Strings.Equal(name, "Files_Eof")        THEN RETURN SYSTEM.ADR(Files.Eof)
  ELSIF Strings.Equal(name, "Files_BlockRead")  THEN RETURN SYSTEM.ADR(Files.BlockRead)
  ELSIF Strings.Equal(name, "Files_BlockWrite") THEN RETURN SYSTEM.ADR(Files.BlockWrite)
  ELSIF Strings.Equal(name, "Files_BlockCopy")  THEN RETURN SYSTEM.ADR(Files.BlockCopy)
  ELSIF Strings.Equal(name, "Files_ReadByte")   THEN RETURN SYSTEM.ADR(Files.ReadByte)
  ELSIF Strings.Equal(name, "Files_ReadWord")   THEN RETURN SYSTEM.ADR(Files.ReadWord)
  ELSIF Strings.Equal(name, "Files_ReadDWord")  THEN RETURN SYSTEM.ADR(Files.ReadDWord)
  ELSIF Strings.Equal(name, "Files_WriteByte")  THEN RETURN SYSTEM.ADR(Files.WriteByte)
  ELSIF Strings.Equal(name, "Files_WriteWord")  THEN RETURN SYSTEM.ADR(Files.WriteWord)
  ELSIF Strings.Equal(name, "Files_WriteDWord") THEN RETURN SYSTEM.ADR(Files.WriteDWord)
  ELSIF Strings.Equal(name, "Files_ReadAsciizString") THEN RETURN SYSTEM.ADR(Files.ReadAsciizString)
  ELSIF Strings.Equal(name, "Files_ReadLine")   THEN RETURN SYSTEM.ADR(Files.ReadLine)
  ELSIF Strings.Equal(name, "Files_WriteLn")    THEN RETURN SYSTEM.ADR(Files.WriteLn)
  ELSIF Strings.Equal(name, "Files_Write")      THEN RETURN SYSTEM.ADR(Files.Write)
  ELSIF Strings.Equal(name, "Files_WriteLine")  THEN RETURN SYSTEM.ADR(Files.WriteLine)
  ELSIF Strings.Equal(name, "Files_Truncate")   THEN RETURN SYSTEM.ADR(Files.Truncate)
  ELSIF Strings.Equal(name, "Files_Delete")     THEN RETURN SYSTEM.ADR(Files.Delete)
  ELSIF Strings.Equal(name, "Files_SetDeleteOnClose") THEN RETURN SYSTEM.ADR(Files.SetDeleteOnClose)
  ELSIF Strings.Equal(name, "Files_Rename")     THEN RETURN SYSTEM.ADR(Files.Rename)
  ELSIF Strings.Equal(name, "Files_Copy")       THEN RETURN SYSTEM.ADR(Files.Copy)
  ELSIF Strings.Equal(name, "Files_ReplaceExt") THEN RETURN SYSTEM.ADR(Files.ReplaceExt)
  ELSIF Strings.Equal(name, "Files_FileExists") THEN RETURN SYSTEM.ADR(Files.FileExists)
  ELSIF Strings.Equal(name, "Files_GetFTime")   THEN RETURN SYSTEM.ADR(Files.GetFTime)
  ELSIF Strings.Equal(name, "Files_SetFTime")   THEN RETURN SYSTEM.ADR(Files.SetFTime)
  (* Strings *)
  ELSIF Strings.Equal(name, "Strings_Length")   THEN RETURN SYSTEM.ADR(Strings.Length)
  (* Strings_Pos: signature is now (substr, string: ARRAY OF CHAR; VAR pos: WORD): BOOLEAN
     -- pos is in/out (start offset in, match offset out) and the result is
     TRUE/FALSE, not an INTEGER index.  Any external .RDF caller resolving
     this symbol must match the new calling convention. *)
  ELSIF Strings.Equal(name, "Strings_Pos")      THEN RETURN SYSTEM.ADR(Strings.Pos)
  ELSIF Strings.Equal(name, "Strings_LTrim")    THEN RETURN SYSTEM.ADR(Strings.LTrim)
  ELSIF Strings.Equal(name, "Strings_RTrim")    THEN RETURN SYSTEM.ADR(Strings.RTrim)
  ELSIF Strings.Equal(name, "Strings_Trim")     THEN RETURN SYSTEM.ADR(Strings.Trim)
  ELSIF Strings.Equal(name, "Strings_Append")   THEN RETURN SYSTEM.ADR(Strings.Append)
  ELSIF Strings.Equal(name, "Strings_Insert")   THEN RETURN SYSTEM.ADR(Strings.Insert)
  ELSIF Strings.Equal(name, "Strings_Delete")   THEN RETURN SYSTEM.ADR(Strings.Delete)
  ELSIF Strings.Equal(name, "Strings_Replace")  THEN RETURN SYSTEM.ADR(Strings.Replace)
  ELSIF Strings.Equal(name, "Strings_Extract")  THEN RETURN SYSTEM.ADR(Strings.Extract)
  ELSIF Strings.Equal(name, "Strings_Equal")    THEN RETURN SYSTEM.ADR(Strings.Equal)
  ELSIF Strings.Equal(name, "Strings_EqualICase") THEN RETURN SYSTEM.ADR(Strings.EqualICase)
  ELSIF Strings.Equal(name, "Strings_StartsWith") THEN RETURN SYSTEM.ADR(Strings.StartsWith)
  ELSIF Strings.Equal(name, "Strings_EndsWith") THEN RETURN SYSTEM.ADR(Strings.EndsWith)
  ELSIF Strings.Equal(name, "Strings_Copy")     THEN RETURN SYSTEM.ADR(Strings.Copy)
  ELSIF Strings.Equal(name, "Strings_HashCode") THEN RETURN SYSTEM.ADR(Strings.HashCode)
  ELSIF Strings.Equal(name, "Strings_Str")      THEN RETURN SYSTEM.ADR(Strings.Str)
  ELSIF Strings.Equal(name, "Strings_Val")      THEN RETURN SYSTEM.ADR(Strings.Val)
  ELSIF Strings.Equal(name, "Strings_AppendInt") THEN RETURN SYSTEM.ADR(Strings.AppendInt)
  ELSIF Strings.Equal(name, "Strings_ByteToHexStr") THEN RETURN SYSTEM.ADR(Strings.ByteToHexStr)
  ELSIF Strings.Equal(name, "Strings_WordToHexStr") THEN RETURN SYSTEM.ADR(Strings.WordToHexStr)
  ELSIF Strings.Equal(name, "Strings_AppendHexByte") THEN RETURN SYSTEM.ADR(Strings.AppendHexByte)
  ELSIF Strings.Equal(name, "Strings_AppendHexWord") THEN RETURN SYSTEM.ADR(Strings.AppendHexWord)
  END;
  RETURN NIL
END BuiltinResolve;

PROCEDURE Align2(size: LONGINT): LONGINT;
BEGIN
  IF SYSTEM.AND(size, 1) # 0 THEN INC(size) END;
  RETURN size
END Align2;

PROCEDURE ExtractString(VAR buf: ARRAY OF BYTE; offset, maxLen: WORD;
                        VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (offset + i < maxLen) & (buf[offset + i] # 0) & (i < 32) DO
    s[i] := CHR(buf[offset + i]); INC(i)
  END;
  s[i] := 0X
END ExtractString;

PROCEDURE GetBSSSize(VAR f: Files.File; startPos, endPos: LONGINT): LONGINT;
  VAR h: RecHeader;
      buf: ARRAY 256 OF BYTE;
      total, val: LONGINT;
BEGIN
  total := 0;
  Files.Seek(f, startPos);
  WHILE Files.Position(f) < endPos DO
    Files.BlockRead(f, h, 2);
    IF h.recLen > 0 THEN Files.BlockRead(f, buf, ORD(h.recLen)) END;
    IF h.recType = RecBss THEN
      SYSTEM.MOVE(buf[0], val, 4);
      total := total + val
    END
  END;
  RETURN total
END GetBSSSize;

(* ScanSegments — record every physical segment's kind (segType) and raw file
   size into mod.seg[segNum].  Does NOT read segment content (that is
   LoadSegmentData's job); it only seeks past each block.  Returns FALSE if the
   file names a segNum outside 0..MaxSeg-1 or any single segment exceeds the
   65520-byte real-mode limit. *)
PROCEDURE ScanSegments(VAR f: Files.File; startPos: LONGINT;
                       mod: RDFModule): BOOLEAN;
  VAR sh: SegHeader; n: INTEGER;
BEGIN
  Files.Seek(f, startPos);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF sh.segType # 0 THEN
      n := sh.segNum;
      IF (n < 0) OR (n >= MaxSeg) THEN RETURN FALSE END;
      IF sh.length > LONGINT(65520) THEN RETURN FALSE END;
      mod.seg[n].segType := sh.segType;
      mod.seg[n].segNum  := n;
      mod.seg[n].rawSize := WORD(sh.length);
      IF n + 1 > mod.nSeg THEN mod.nSeg := n + 1 END
    END;
    IF sh.length > 0 THEN Files.Seek(f, Files.Position(f) + sh.length) END
  UNTIL sh.segType = 0;
  RETURN TRUE
END ScanSegments;

(* LoadSegmentData — read each physical segment's content into its own
   heap block mod.seg[segNum].base (allocated by the caller). *)
PROCEDURE LoadSegmentData(VAR f: Files.File; startPos: LONGINT; mod: RDFModule);
  VAR sh: SegHeader; n: INTEGER;
BEGIN
  Files.Seek(f, startPos);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF sh.length > 0 THEN
      n := sh.segNum;
      IF (sh.segType # 0) & (n >= 0) & (n < MaxSeg) & (mod.seg[n].base # NIL) THEN
        Files.BlockRead(f, mod.seg[n].base^, WORD(sh.length))
      ELSE
        Files.Seek(f, Files.Position(f) + sh.length)
      END
    END
  UNTIL sh.segType = 0
END LoadSegmentData;

(* FindImport — locate an ImportSym by its 16-bit RDOFF segment-id.
   Returns NIL if no IMPORT record declared this id. *)
PROCEDURE FindImport(mod: RDFModule; segId: INTEGER): ImportSym;
  VAR cur: ImportSym;
BEGIN
  cur := mod.imports;
  WHILE cur # NIL DO
    IF cur^.segId = segId THEN RETURN cur END;
    cur := cur^.next
  END;
  RETURN NIL
END FindImport;

(* CollectImports — pass 1 over the header section.  Reads every IMPORT
   record (type 2) and links a fresh ImportSym onto mod.imports with the
   resolved host address (or NIL if no resolver knows the name).  Run
   BEFORE ApplyRecords so RELOC/SEGRELOC against an Import ID can look up
   the resolved address. *)
PROCEDURE CollectImports(VAR f: Files.File; startPos, endPos: LONGINT;
                         mod: RDFModule; resolve: Resolver);
  VAR h: RecHeader;
      buf: ARRAY 256 OF BYTE;
      segId: INTEGER;
      imp: ImportSym;
      addr: SYSTEM.ADDRESS;
BEGIN
  Files.Seek(f, startPos);
  WHILE Files.Position(f) < endPos DO
    Files.BlockRead(f, h, 2);
    IF h.recLen > 0 THEN Files.BlockRead(f, buf, ORD(h.recLen)) END;
    IF h.recType = RecImport THEN
      (* Layout: flags(1) + segId(2) + name(asciiz at offset 3) *)
      SYSTEM.MOVE(buf[1], segId, 2);
      NEW(imp);
      imp^.segId := segId;
      ExtractString(buf, 3, ORD(h.recLen), imp^.name);
      addr := BuiltinResolve(imp^.name);
      IF (addr = NIL) & (resolve # NIL) THEN addr := resolve(imp^.name) END;
      imp^.addr := addr;
      imp^.next := mod.imports;
      mod.imports := imp
    END
  END
END CollectImports;

PROCEDURE ApplyRecords(VAR f: Files.File; startPos, endPos: LONGINT;
                       mod: RDFModule);
  VAR h: RecHeader;
      buf: ARRAY 256 OF BYTE;
      baseAddr, targetPtr, patchAddr: SYSTEM.ADDRESS;
      relFlags, relWidth, gSegId: BYTE;
      relOffset, gOffset: LONGINT;
      relRSeg, physSeg: INTEGER;
      newSym: ExportSym;
      imp:    ImportSym;
      pW: POINTER TO INTEGER;
BEGIN
  Files.Seek(f, startPos);
  WHILE Files.Position(f) < endPos DO
    Files.BlockRead(f, h, 2);
    IF h.recLen > 0 THEN Files.BlockRead(f, buf, ORD(h.recLen)) END;
    IF (h.recType = RecReloc) OR (h.recType = RecSegReloc) THEN
      relFlags := buf[0];
      SYSTEM.MOVE(buf[1], relOffset, 4);
      relWidth := buf[5];
      SYSTEM.MOVE(buf[6], relRSeg, 2);
      (* The patch-into segment is the low 6 bits of byte +0 (the physical
         segment index / segNum, 0..63 — DISTINCT from the RSEG target below).
         Bit 6 (0x40) is the RELOC relative flag, not part of the index. *)
      physSeg := INTEGER(SYSTEM.AND(relFlags, 3FH));
      IF (physSeg >= 0) & (physSeg < MaxSeg) & (mod.seg[physSeg].base # NIL) THEN
        baseAddr := mod.seg[physSeg].base
      ELSE
        baseAddr := NIL
      END;
      patchAddr := baseAddr + WORD(relOffset);
      (* Resolve the RSEG target (byte +6, NOT a physical index):
           RSeg=0 → this module's (first) code segment
           RSeg=1 → this module's (first) data segment
           RSeg=2 → BSS  (concatenated after that data segment's raw bytes)
           RSeg>2 → IMPORT ID — look up in mod.imports list.
         Per RDOFF2 the import id base is 3, so RSEG can never name a physical
         segment 3..63 directly; cross-segment references go by import name. *)
      IF    relRSeg = 0 THEN targetPtr := mod.codeBase
      ELSIF relRSeg = 1 THEN targetPtr := mod.dataBase
      ELSIF relRSeg = 2 THEN
        targetPtr := mod.dataBase + mod.dataRawSize
      ELSE
        (* Import ID — resolve via mod.imports.  An unresolved import
           leaves patchAddr alone (caller can detect via WalkImports). *)
        imp := FindImport(mod, relRSeg);
        IF (imp = NIL) OR (imp^.addr = NIL) THEN targetPtr := NIL
        ELSE targetPtr := imp^.addr
        END
      END;
      IF (targetPtr # NIL) & (baseAddr # NIL) THEN
        IF h.recType = RecReloc THEN
          IF relWidth = 2 THEN
            pW := patchAddr;
            INC(pW^, SYSTEM.OFS(targetPtr^))
          END
        ELSE  (* RecSegReloc *)
          IF relWidth = 2 THEN
            pW := patchAddr;
            pW^ := SYSTEM.SEG(targetPtr^)
          END
        END
      END
    ELSIF h.recType = RecGlobal THEN
      (* GLOBAL segId (byte +1) is a physical segment index (segNum): a symbol
         may live in any loaded segment, not just code(0)/data(1).  segNum=2 is
         the virtual BSS, resolved after the (first) data segment's raw bytes. *)
      gSegId := buf[1];
      SYSTEM.MOVE(buf[2], gOffset, 4);
      NEW(newSym);
      ExtractString(buf, 6, ORD(h.recLen), newSym.name);
      newSym.next := mod.exports;
      mod.exports := newSym;
      IF gSegId = 2 THEN
        newSym.addr := mod.dataBase + mod.dataRawSize + WORD(gOffset)
      ELSIF (INTEGER(gSegId) < MaxSeg) & (mod.seg[gSegId].base # NIL) THEN
        newSym.addr := mod.seg[gSegId].base + WORD(gOffset)
      ELSE
        newSym.addr := NIL   (* symbol in an empty/absent segment *)
      END
    END
  END
END ApplyRecords;

(* LoadLibraryWith — load an RDOFF2 file and resolve its IMPORTs.
   For each IMPORT record in the file, `resolve(name)` is called first
   (if non-NIL); if that returns NIL, BuiltinResolve is tried.  Unresolved
   imports leave their RELOC/SEGRELOC patches untouched — the caller can
   walk the module's imports list (currently private) or simply detect a
   call into NIL at runtime.  Returns NIL on file/format failure.
   Parameters: fileName — path of the .RDF file to load; resolve — optional
   user-supplied resolver called before BuiltinResolve for each IMPORT name
   (pass NIL to use only the built-in table).
   Result: the loaded module (heap-allocated code/data + export/import
   lists), or NIL if the file could not be opened, is not a valid RDOFF2
   signature, or its code/data+bss size exceeds the 65520-byte segment
   limit. *)
(* InitModule — NEW'd memory is NOT zero-initialised on this runtime, so every
   seg[] slot must be cleared explicitly before use (an uninitialised base would
   be read as a live pointer by LoadSegmentData/ApplyRecords/FreeLibrary). *)
PROCEDURE InitModule(mod: RDFModule);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < MaxSeg DO
    mod.seg[i].base    := NIL;
    mod.seg[i].segType := 0;
    mod.seg[i].segNum  := i;
    mod.seg[i].rawSize := 0;
    mod.seg[i].size    := 0;
    mod.seg[i].bss     := 0;
    INC(i)
  END;
  mod.nSeg        := 0;
  mod.codeBase    := NIL;
  mod.dataBase    := NIL;
  mod.codeSize    := 0;
  mod.dataSize    := 0;
  mod.dataRawSize := 0;
  mod.exports     := NIL;
  mod.imports     := NIL
END InitModule;

PROCEDURE LoadLibraryWith*(fileName: ARRAY OF CHAR;
                          resolve: Resolver): RDFModule;
  VAR f: Files.File;
      hdr: RdfHeader;
      recStart, segStart: LONGINT;
      bSize: LONGINT;
      mod: RDFModule;
      i, firstData: INTEGER;
      total: WORD;
BEGIN
  IF ~Files.Reset(f, fileName) THEN RETURN NIL END;
  Files.BlockRead(f, hdr, 14);
  IF (hdr.sign[0] # "R") OR (hdr.sign[1] # "D") OR (hdr.sign[2] # "O") OR
     (hdr.sign[3] # "F") OR (hdr.sign[4] # "F") OR (hdr.sign[5] # "2") THEN
    Files.Close(f); RETURN NIL
  END;
  recStart := Files.Position(f);
  segStart := recStart + hdr.headSize;
  bSize := GetBSSSize(f, recStart, segStart);

  NEW(mod);
  IF mod = NIL THEN Files.Close(f); RETURN NIL END;
  InitModule(mod);

  IF ~ScanSegments(f, segStart, mod) THEN Files.Close(f); RETURN NIL END;

  (* BSS is appended to the FIRST data segment (lowest segNum with segType=2),
     matching RSEG=2 → dataBase + dataRawSize. *)
  firstData := -1;
  i := 0;
  WHILE i < mod.nSeg DO
    IF (firstData < 0) & (mod.seg[i].segType = 2) THEN firstData := i END;
    INC(i)
  END;

  (* Size and allocate one heap block per non-empty segment. *)
  i := 0;
  WHILE i < mod.nSeg DO
    IF mod.seg[i].segType # 0 THEN
      total := WORD(Align2(LONGINT(mod.seg[i].rawSize)));
      IF i = firstData THEN total := WORD(Align2(LONGINT(mod.seg[i].rawSize) + bSize)) END;
      IF LONGINT(total) > LONGINT(65520) THEN Files.Close(f); RETURN NIL END;
      mod.seg[i].size := total;
      IF i = firstData THEN mod.seg[i].bss := WORD(bSize) END;
      IF total > 0 THEN
        NEW(mod.seg[i].base, total);
        IF mod.seg[i].base = NIL THEN Files.Close(f); RETURN NIL END;
        SYSTEM.FILL(mod.seg[i].base^, total, 0)   (* clears the BSS tail too *)
      END
    END;
    INC(i)
  END;

  (* Legacy aliases: first code segment, first data segment. *)
  i := 0;
  WHILE i < mod.nSeg DO
    IF (mod.codeBase = NIL) & (mod.seg[i].segType = 1) & (mod.seg[i].base # NIL) THEN
      mod.codeBase := mod.seg[i].base; mod.codeSize := mod.seg[i].size
    END;
    INC(i)
  END;
  IF firstData >= 0 THEN
    mod.dataBase    := mod.seg[firstData].base;
    mod.dataSize    := mod.seg[firstData].size;
    mod.dataRawSize := mod.seg[firstData].rawSize
  END;

  LoadSegmentData(f, segStart, mod);
  (* Pass 1: read all IMPORTs and resolve them up front. *)
  CollectImports(f, recStart, segStart, mod, resolve);
  (* Pass 2: apply RELOC/SEGRELOC/GLOBAL — RELOCs against import ids
     now have a resolved address to patch with. *)
  ApplyRecords(f, recStart, segStart, mod);

  Files.Close(f);
  RETURN mod
END LoadLibraryWith;

(* LoadLibrary — convenience wrapper that uses only BuiltinResolve.
   Suitable for RDFs that import nothing or only standard runtime
   procedures from SYSTEM, Files and Strings.
   Parameters: fileName — path of the .RDF file to load.
   Result: the loaded module, or NIL on failure (see LoadLibraryWith). *)
PROCEDURE LoadLibrary*(fileName: ARRAY OF CHAR): RDFModule;
BEGIN
  RETURN LoadLibraryWith(fileName, NIL)
END LoadLibrary;

(* GetProcAddress — look up a GLOBAL (exported) symbol by name in an
   already-loaded module.
   Parameters: module — a module returned by LoadLibrary/LoadLibraryWith;
   name — the exported symbol's name as it appears in the RDOFF2 GLOBAL
   record.
   Result: the symbol's host-side address, or NIL if no such export exists. *)
PROCEDURE GetProcAddress*(module: RDFModule; name: ARRAY OF CHAR): SYSTEM.ADDRESS;
  VAR cur: ExportSym;
BEGIN
  cur := module.exports;
  WHILE cur # NIL DO
    IF Strings.Equal(cur^.name, name) THEN RETURN cur^.addr END;
    cur := cur^.next
  END;
  RETURN NIL
END GetProcAddress;

(* FreeLibrary — release a loaded module's export/import lists and its
   heap-allocated code/data blocks.  Safe to call with module = NIL (no-op).
   Parameters: module — a module returned by LoadLibrary/LoadLibraryWith.
   Result: none. *)
PROCEDURE FreeLibrary*(module: RDFModule);
  VAR eNext: ExportSym; iNext: ImportSym; i: INTEGER;
BEGIN
  IF module = NIL THEN RETURN END;
  WHILE module.exports # NIL DO
    eNext := module.exports.next;
    DISPOSE(module.exports);
    module.exports := eNext
  END;
  WHILE module.imports # NIL DO
    iNext := module.imports.next;
    DISPOSE(module.imports);
    module.imports := iNext
  END;
  (* Free every physical segment's heap block.  codeBase/dataBase are only
     ALIASES into seg[], so they must NOT be disposed separately. *)
  i := 0;
  WHILE i < MaxSeg DO
    IF module.seg[i].base # NIL THEN
      DISPOSE(module.seg[i].base);
      module.seg[i].base := NIL
    END;
    INC(i)
  END;
  module.codeBase := NIL;
  module.dataBase := NIL;
  DISPOSE(module)
END FreeLibrary;

END RdfLoad.
