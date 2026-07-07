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

  RDFModule* = POINTER TO RDFModuleDesc;
  RDFModuleDesc = RECORD
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
  (* SYSTEM — provided by SYS.ASM at link time *)
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
  ELSIF Strings.Equal(name, "Files_BlockRead")  THEN RETURN SYSTEM.ADR(Files.BlockRead)
  ELSIF Strings.Equal(name, "Files_BlockWrite") THEN RETURN SYSTEM.ADR(Files.BlockWrite)
  ELSIF Strings.Equal(name, "Files_BlockCopy")  THEN RETURN SYSTEM.ADR(Files.BlockCopy)
  ELSIF Strings.Equal(name, "Files_ReadByte")   THEN RETURN SYSTEM.ADR(Files.ReadByte)
  ELSIF Strings.Equal(name, "Files_ReadWord")   THEN RETURN SYSTEM.ADR(Files.ReadWord)
  ELSIF Strings.Equal(name, "Files_WriteByte")  THEN RETURN SYSTEM.ADR(Files.WriteByte)
  ELSIF Strings.Equal(name, "Files_WriteWord")  THEN RETURN SYSTEM.ADR(Files.WriteWord)
  ELSIF Strings.Equal(name, "Files_Truncate")   THEN RETURN SYSTEM.ADR(Files.Truncate)
  ELSIF Strings.Equal(name, "Files_Delete")     THEN RETURN SYSTEM.ADR(Files.Delete)
  ELSIF Strings.Equal(name, "Files_SetDeleteOnClose") THEN RETURN SYSTEM.ADR(Files.SetDeleteOnClose)
  (* Strings *)
  ELSIF Strings.Equal(name, "Strings_Length")   THEN RETURN SYSTEM.ADR(Strings.Length)
  ELSIF Strings.Equal(name, "Strings_Pos")      THEN RETURN SYSTEM.ADR(Strings.Pos)
  ELSIF Strings.Equal(name, "Strings_Append")   THEN RETURN SYSTEM.ADR(Strings.Append)
  ELSIF Strings.Equal(name, "Strings_Insert")   THEN RETURN SYSTEM.ADR(Strings.Insert)
  ELSIF Strings.Equal(name, "Strings_Delete")   THEN RETURN SYSTEM.ADR(Strings.Delete)
  ELSIF Strings.Equal(name, "Strings_Replace")  THEN RETURN SYSTEM.ADR(Strings.Replace)
  ELSIF Strings.Equal(name, "Strings_Extract")  THEN RETURN SYSTEM.ADR(Strings.Extract)
  ELSIF Strings.Equal(name, "Strings_Equal")    THEN RETURN SYSTEM.ADR(Strings.Equal)
  ELSIF Strings.Equal(name, "Strings_Copy")     THEN RETURN SYSTEM.ADR(Strings.Copy)
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

PROCEDURE ScanSegments(VAR f: Files.File; startPos: LONGINT;
                       VAR cSize, dSize: LONGINT);
  VAR sh: SegHeader;
BEGIN
  cSize := 0; dSize := 0;
  Files.Seek(f, startPos);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF    sh.segType = 1 THEN cSize := cSize + sh.length
    ELSIF sh.segType = 2 THEN dSize := dSize + sh.length
    END;
    IF sh.length > 0 THEN Files.Seek(f, Files.Position(f) + sh.length) END
  UNTIL sh.segType = 0
END ScanSegments;

PROCEDURE LoadSegmentData(VAR f: Files.File; startPos: LONGINT; mod: RDFModule);
  VAR sh: SegHeader;
BEGIN
  Files.Seek(f, startPos);
  REPEAT
    Files.BlockRead(f, sh, 10);
    IF sh.length > 0 THEN
      IF sh.segType = 1 THEN
        Files.BlockRead(f, mod.codeBase^, WORD(sh.length))
      ELSIF sh.segType = 2 THEN
        Files.BlockRead(f, mod.dataBase^, WORD(sh.length))
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
      relRSeg: INTEGER;
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
      IF SYSTEM.AND(relFlags, 0FH) = 0 THEN baseAddr := mod.codeBase
      ELSE                                  baseAddr := mod.dataBase
      END;
      patchAddr := baseAddr + WORD(relOffset);
      (* Resolve the target:
           RSeg=0 → Code segment of this module
           RSeg=1 → Data segment of this module
           RSeg=2 → BSS  (concatenated after raw data)
           RSeg>2 → IMPORT ID — look up in mod.imports list             *)
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
      IF targetPtr # NIL THEN
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
      gSegId := buf[1];
      SYSTEM.MOVE(buf[2], gOffset, 4);
      NEW(newSym);
      ExtractString(buf, 6, ORD(h.recLen), newSym.name);
      newSym.next := mod.exports;
      mod.exports := newSym;
      IF gSegId = 0 THEN
        newSym.addr := mod.codeBase + WORD(gOffset)
      ELSIF gSegId = 2 THEN
        newSym.addr := mod.dataBase + mod.dataRawSize + WORD(gOffset)
      ELSE
        newSym.addr := mod.dataBase + WORD(gOffset)
      END
    END
  END
END ApplyRecords;

(* LoadLibraryWith — load an RDOFF2 file and resolve its IMPORTs.
   For each IMPORT record in the file, `resolve(name)` is called first
   (if non-NIL); if that returns NIL, BuiltinResolve is tried.  Unresolved
   imports leave their RELOC/SEGRELOC patches untouched — the caller can
   walk the module's imports list (currently private) or simply detect a
   call into NIL at runtime.  Returns NIL on file/format failure. *)
PROCEDURE LoadLibraryWith*(fileName: ARRAY OF CHAR;
                          resolve: Resolver): RDFModule;
  VAR f: Files.File;
      hdr: RdfHeader;
      recStart, segStart: LONGINT;
      cSize, dSize, bSize: LONGINT;
      mod: RDFModule;
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
  ScanSegments(f, segStart, cSize, dSize);
  IF (cSize > LONGINT(65520)) OR (LONGINT(dSize + bSize) > LONGINT(65520)) THEN
    Files.Close(f); RETURN NIL
  END;
  NEW(mod);
  mod.codeBase := NIL;
  mod.dataBase := NIL;
  mod.exports  := NIL;
  mod.imports  := NIL;
  mod.codeSize    := WORD(Align2(cSize));
  mod.dataSize    := WORD(Align2(dSize + bSize));
  mod.dataRawSize := WORD(dSize);

  IF mod.codeSize > 0 THEN NEW(mod.codeBase, mod.codeSize) END;
  IF mod.dataSize > 0 THEN
    NEW(mod.dataBase, mod.dataSize);
    SYSTEM.FILL(mod.dataBase^, mod.dataSize, 0)
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
   procedures from SYSTEM, Files and Strings. *)
PROCEDURE LoadLibrary*(fileName: ARRAY OF CHAR): RDFModule;
BEGIN
  RETURN LoadLibraryWith(fileName, NIL)
END LoadLibrary;

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

PROCEDURE FreeLibrary*(module: RDFModule);
  VAR eNext: ExportSym; iNext: ImportSym;
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
  IF (module.codeSize > 0) & (module.codeBase # NIL) THEN
    DISPOSE(module.codeBase)
  END;
  IF (module.dataSize > 0) & (module.dataBase # NIL) THEN
    DISPOSE(module.dataBase)
  END;
  DISPOSE(module)
END FreeLibrary;

END RdfLoad.
