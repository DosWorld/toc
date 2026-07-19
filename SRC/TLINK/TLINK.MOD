MODULE TLink;
(*
  Trubo Link (tlink.exe) - RDOFF2 linker for tiny-model .COM/.SYS
  and small-model .EXE output.
  tiny model: .COM/.SYS, no relocation table and
  small model: .EXE with an MZ relocation table,
  RDOFF2/RDLIB2/TAR format detection, smart-link marking.

  Usage:
    tlink /t=com [@list] input... output.com          (default mode)
    tlink /t=sys /A:xxxx [/N:name] input... output.sys
    tlink /t=exe input... output.exe

  Uses Rdoff.ScanHeader/ScanRelocs/ReadCode/ReadData (the same primitives
  SRC/TOC/LINK.MOD uses for toc.exe's own embedded linker) instead of
  re-parsing RDOFF2 records by hand, and Tar.ListTar for .tar scanning.
  RDLIB2 scanning (DOCS/RDOFF2.MD §7) has no existing reader in this repo
  and is implemented here directly, following the spec: ASCIIZ name +
  DWORD size, sequential, '.'-prefixed entries (e.g. ".sig") are metadata
  and skipped.
*)
IMPORT Dos, Files, LogErr, Rdoff, Strings, Tar, Out;

CONST
  ModeCom = 0;
  ModeSys = 1;
  ModeExe = 2;

  MaxPath = 128;
  MaxName = 64;
  MaxArgs = 64;

  SymChunk = 64;   (* symbols per chunk node (small-record rule) *)
  ImpChunk = 32;   (* per-module import entries per chunk node *)
  RelChunk = 128;  (* MZ relocations per chunk node (EXE mode only) *)

TYPE
  Module = POINTER TO ModRec;
  ModRec = RECORD
    fileName:     ARRAY MaxPath OF CHAR;
    libOfs:       LONGINT;
    rawSize:      LONGINT;
    hdrSize:      LONGINT;
    codeSize:     LONGINT;
    dataSize:     LONGINT;
    bssSize:      LONGINT;
    finalCodeOfs: LONGINT;
    finalDataOfs: LONGINT;
    finalBssOfs:  LONGINT;
    used:         BOOLEAN;
    next:         Module
  END;

  SymNode = POINTER TO SymNodeRec;
  SymNodeRec = RECORD
    name:   ARRAY SymChunk OF ARRAY MaxName OF CHAR;
    owner:  ARRAY SymChunk OF Module;
    segId:  ARRAY SymChunk OF INTEGER;
    offset: ARRAY SymChunk OF LONGINT;
    count:  INTEGER;
    next:   SymNode
  END;

  (* a resolved symbol handle: which chunk node + slot within it (Symbol
     records aren't individually addressable via POINTER since they live
     packed inside SymNodeRec — this pair stands in for that pointer) *)
  SymEntry = RECORD
    node: SymNode;
    slot: INTEGER
  END;

  ImpNode = POINTER TO ImpNodeRec;
  ImpNodeRec = RECORD
    id:    ARRAY ImpChunk OF INTEGER;
    sym:   ARRAY ImpChunk OF SymEntry;
    count: INTEGER;
    next:  ImpNode
  END;

  RelNode = POINTER TO RelNodeRec;
  RelNodeRec = RECORD
    w:     ARRAY RelChunk * 2 OF WORD;  (* wire order: ofs,seg per entry *)
    count: INTEGER;
    next:  RelNode
  END;

VAR
  mode:        INTEGER;
  modHead, modTail: Module;
  symHead, symTail: SymNode;
  noSym:       SymEntry;   (* node=NIL marks "not found" *)

  codeBuf:     Rdoff.SegBuf;
  dataBuf:     Rdoff.SegBuf;
  totalCodeLen, totalDataLen, totalBssLen: LONGINT;

  relHead, relTail: RelNode;
  relCount:    WORD;

  outFileName: ARRAY MaxPath OF CHAR;
  sysAttr:     INTEGER;
  sysName:     ARRAY 9 OF CHAR;
  headerSize:  INTEGER;
  strategyIp, interruptIp, entryIp: INTEGER;

(* ---- string / path helpers ---- *)

(* BaseName: strip any directory prefix, returning just the filename.
   Parameters: path — the full path; VAR dst — receives the basename.
   Result: none. *)
PROCEDURE BaseName(path: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, start: INTEGER;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = "\") OR (path[i] = "/") OR (path[i] = ":") THEN start := i + 1 END;
    INC(i)
  END;
  Strings.Extract(path, start, i - start, dst)
END BaseName;

PROCEDURE UpcaseInPlace(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO s[i] := SYSTEM.UCASE(s[i]); INC(i) END
END UpcaseInPlace;

(* SearchFile: resolve 'name' against CWD first, then each ';'-separated
   directory in the RLIB environment variable.
   Parameters: name — the requested file name; VAR dst — receives the
   resolved path (unchanged if not found anywhere).
   Result: none. *)
PROCEDURE SearchFile(name: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR env, path, testName, base: ARRAY MaxPath OF CHAR;
      p, s, envLen: INTEGER;
BEGIN
  IF Files.FileExists(name) THEN Strings.Copy(name, dst); RETURN END;
  Dos.GetEnv("RLIB", env);
  IF env[0] = 0X THEN Strings.Copy(name, dst); RETURN END;
  BaseName(name, base);
  envLen := Strings.Length(env);
  p := 0;
  WHILE p < envLen DO
    s := p;
    WHILE (s < envLen) & (env[s] # ";") DO INC(s) END;
    Strings.Extract(env, p, s - p, path);
    IF (Strings.Length(path) > 0) THEN
      IF (path[Strings.Length(path) - 1] # "\") & (path[Strings.Length(path) - 1] # "/") THEN
        Strings.Append("\", path)
      END
    END;
    Strings.Copy(path, testName);
    Strings.Append(base, testName);
    IF Files.FileExists(testName) THEN Strings.Copy(testName, dst); RETURN END;
    p := s + 1
  END;
  Strings.Copy(name, dst)
END SearchFile;

(* ---- module / symbol tables ---- *)

PROCEDURE RegisterModule(fileName: ARRAY OF CHAR; libOfs: LONGINT): Module;
  VAR m: Module;
BEGIN
  NEW(m);
  IF m = NIL THEN LogErr.Error("out of memory (module)"); RETURN NIL END;
  Strings.Copy(fileName, m.fileName);
  m.libOfs := libOfs;
  m.rawSize := LONGINT(0); m.hdrSize := LONGINT(0);
  m.codeSize := LONGINT(0); m.dataSize := LONGINT(0); m.bssSize := LONGINT(0);
  m.used := FALSE; m.next := NIL;
  IF modHead = NIL THEN modHead := m ELSE modTail.next := m END;
  modTail := m;
  RETURN m
END RegisterModule;

PROCEDURE AddSymbol(name: ARRAY OF CHAR; owner: Module; segId: INTEGER; offset: LONGINT);
  VAR n: SymNode;
BEGIN
  IF (symTail = NIL) OR (symTail.count >= SymChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (symbol)"); RETURN END;
    n.count := 0; n.next := NIL;
    IF symHead = NIL THEN symHead := n ELSE symTail.next := n END;
    symTail := n
  END;
  Strings.Copy(name, symTail.name[symTail.count]);
  symTail.owner[symTail.count] := owner;
  symTail.segId[symTail.count] := segId;
  symTail.offset[symTail.count] := offset;
  INC(symTail.count)
END AddSymbol;

(* FindSymbol: look up a symbol by exact name across all chunk nodes.
   Parameters: name — the symbol name; VAR e — receives the result
   (node=NIL if not found).
   Result: none. *)
PROCEDURE FindSymbol(name: ARRAY OF CHAR; VAR e: SymEntry);
  VAR n: SymNode; i: INTEGER;
BEGIN
  n := symHead;
  WHILE n # NIL DO
    i := 0;
    WHILE i < n.count DO
      IF Strings.Equal(n.name[i], name) THEN
        e.node := n; e.slot := i; RETURN
      END;
      INC(i)
    END;
    n := n.next
  END;
  e := noSym
END FindSymbol;

PROCEDURE SymOwner(e: SymEntry): Module;
BEGIN RETURN e.node.owner[e.slot]
END SymOwner;

PROCEDURE SymSegId(e: SymEntry): INTEGER;
BEGIN RETURN e.node.segId[e.slot]
END SymSegId;

PROCEDURE SymOffset(e: SymEntry): LONGINT;
BEGIN RETURN e.node.offset[e.slot]
END SymOffset;

PROCEDURE SymFound(e: SymEntry): BOOLEAN;
BEGIN RETURN e.node # NIL
END SymFound;

(* per-module import list: rebuilt fresh for each module during PerformLinking *)
VAR impHead, impTail: ImpNode;

PROCEDURE ImpReset;
BEGIN impHead := NIL; impTail := NIL
END ImpReset;

PROCEDURE ImpAdd(id: INTEGER; sym: SymEntry);
  VAR n: ImpNode;
BEGIN
  IF (impTail = NIL) OR (impTail.count >= ImpChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (import)"); RETURN END;
    n.count := 0; n.next := NIL;
    IF impHead = NIL THEN impHead := n ELSE impTail.next := n END;
    impTail := n
  END;
  impTail.id[impTail.count] := id;
  impTail.sym[impTail.count] := sym;
  INC(impTail.count)
END ImpAdd;

PROCEDURE ImpFind(id: INTEGER; VAR e: SymEntry);
  VAR n: ImpNode; i: INTEGER;
BEGIN
  n := impHead;
  WHILE n # NIL DO
    i := 0;
    WHILE i < n.count DO
      IF n.id[i] = id THEN e := n.sym[i]; RETURN END;
      INC(i)
    END;
    n := n.next
  END;
  e := noSym
END ImpFind;

PROCEDURE ImpFree;
  VAR n, next: ImpNode;
BEGIN
  n := impHead;
  WHILE n # NIL DO next := n.next; DISPOSE(n); n := next END;
  impHead := NIL; impTail := NIL
END ImpFree;

(* ---- MZ relocation list (EXE mode only) ---- *)

PROCEDURE AddReloc(seg, ofs: WORD);
  VAR n: RelNode;
BEGIN
  IF (relTail = NIL) OR (relTail.count >= RelChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (reloc)"); RETURN END;
    n.count := 0; n.next := NIL;
    IF relHead = NIL THEN relHead := n ELSE relTail.next := n END;
    relTail := n
  END;
  relTail.w[relTail.count * 2] := ofs;
  relTail.w[relTail.count * 2 + 1] := seg;
  INC(relTail.count);
  INC(relCount)
END AddReloc;

(* ---- RDOFF2 / RDLIB2 / TAR scanning ---- *)

VAR scanMod: Module;   (* module currently being header-scanned (for onGlobal) *)

PROCEDURE OnGlobal(name: ARRAY OF CHAR; segId: INTEGER; offset: LONGINT); FAR;
BEGIN AddSymbol(name, scanMod, segId, offset)
END OnGlobal;

(* ScanRdf: read one module's RDOFF2 header (globals -> symbol table,
   code/data/bss sizes) via Rdoff.ScanHeader.
   Parameters: m — the module descriptor (fileName/libOfs already set).
   Result: none (failures latch via LogErr). *)
PROCEDURE ScanRdf(m: Module);
BEGIN
  scanMod := m;
  Rdoff.ScanHeader(m.fileName, m.libOfs, m.rawSize, m.hdrSize,
                    m.codeSize, m.dataSize, m.bssSize, OnGlobal, NIL)
END ScanRdf;

PROCEDURE OnTarMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT; archPath: ARRAY OF CHAR);
  VAR m: Module;
BEGIN
  m := RegisterModule(archPath, libOfs);
  IF m # NIL THEN m.rawSize := rawSize; ScanRdf(m) END
END OnTarMember;

VAR tarArchPath: ARRAY MaxPath OF CHAR;

PROCEDURE OnTarMemberCb(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
BEGIN OnTarMember(name, libOfs, rawSize, tarArchPath)
END OnTarMemberCb;

(* ScanRdl: scan an RDLIB2 archive (DOCS/RDOFF2.MD §7): sequential
   ASCIIZ-name + DWORD-size entries; '.'-prefixed names (e.g. ".sig")
   are metadata and skipped.
   Parameters: fname — path of the .rdl archive.
   Result: none (failures latch via LogErr). *)
PROCEDURE ScanRdl(fname: ARRAY OF CHAR);
  VAR f: Files.File;
      modName: ARRAY MaxName OF CHAR;
      modSize: LONGINT;
      curPos, fsize: LONGINT;
      m: Module;
BEGIN
  IF ~Files.Reset(f, fname) THEN LogErr.Error2("tlink: cannot open ", fname); RETURN END;
  fsize := Files.Size(f);
  Files.Seek(f, LONGINT(6));
  curPos := LONGINT(6);
  WHILE curPos < fsize DO
    Files.Seek(f, curPos);
    Files.ReadAsciizString(f, modName);
    Files.ReadDWord(f, modSize);
    curPos := Files.Position(f);
    IF (modName[0] # 0X) & (modName[0] # ".") THEN
      m := RegisterModule(fname, curPos);
      IF m # NIL THEN m.rawSize := modSize; ScanRdf(m) END
    END;
    curPos := curPos + modSize
  END;
  Files.Close(f)
END ScanRdl;

(* ScanFile: detect the format of 'rawName' (RDOFF2 / RDLIB2 / tar) and
   register every module it contains.
   Parameters: rawName — the file argument as given on the command line
   (resolved against RLIB via SearchFile first).
   Result: none (failures latch via LogErr). *)
PROCEDURE ScanFile(rawName: ARRAY OF CHAR);
  VAR fname: ARRAY MaxPath OF CHAR;
      f: Files.File;
      sig: ARRAY 9 OF CHAR;
      n: WORD;
      m: Module;
BEGIN
  SearchFile(rawName, fname);
  IF ~Files.Reset(f, fname) THEN LogErr.Error2("tlink: cannot open ", rawName); RETURN END;
  n := Files.BlockRead(f, sig[0], 8);
  Files.Close(f);
  sig[8] := 0X;

  IF (n >= 6) & Strings.StartsWith(sig, "RDOFF2", FALSE) THEN
    m := RegisterModule(fname, LONGINT(0));
    IF m # NIL THEN ScanRdf(m) END
  ELSIF (n >= 6) & Strings.StartsWith(sig, "RDLIB2", FALSE) THEN
    ScanRdl(fname)
  ELSE
    Strings.Copy(fname, tarArchPath);
    Tar.ListTar(fname, OnTarMemberCb)
  END
END ScanFile;

(* ---- smart-link marking ---- *)

PROCEDURE MarkModule(m: Module); FORWARD;

PROCEDURE OnImportForMark(flag, segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR e: SymEntry;
BEGIN
  FindSymbol(name, e);
  IF SymFound(e) THEN MarkModule(SymOwner(e))
  ELSE LogErr.Error2("tlink: unresolved external: ", name)
  END
END OnImportForMark;

PROCEDURE MarkModule;
BEGIN
  IF (m = NIL) OR m.used THEN RETURN END;
  m.used := TRUE;
  Rdoff.ScanRelocs(m.fileName, m.libOfs, m.hdrSize, OnImportForMark, NIL, NIL)
END MarkModule;

(* SmartLink: mark every module reachable from the entry symbol(s) as
   used. .SYS mode needs both "strategy" and "interrupt"; .COM/.EXE need
   only "start".
   Parameters: none (reads `mode` and the symbol table).
   Result: none (failures latch via LogErr). *)
PROCEDURE SmartLink;
  VAR e: SymEntry;
BEGIN
  IF mode = ModeSys THEN
    FindSymbol("strategy", e);
    IF ~SymFound(e) THEN LogErr.Error("tlink: symbol 'strategy' not found (required for SYS)"); RETURN END;
    MarkModule(SymOwner(e));
    FindSymbol("interrupt", e);
    IF ~SymFound(e) THEN LogErr.Error("tlink: symbol 'interrupt' not found (required for SYS)"); RETURN END;
    MarkModule(SymOwner(e))
  ELSE
    FindSymbol("start", e);
    IF ~SymFound(e) THEN LogErr.Error("tlink: entry point 'start' not found"); RETURN END;
    MarkModule(SymOwner(e))
  END
END SmartLink;

(* ---- layout ---- *)

PROCEDURE Align2(v: LONGINT): LONGINT;
BEGIN
  IF SYSTEM.AND(WORD(v), 1) # 0 THEN RETURN v + LONGINT(1) END;
  RETURN v
END Align2;

PROCEDURE Align16(v: LONGINT): LONGINT;
BEGIN
  IF SYSTEM.AND(WORD(v), 15) # 0 THEN RETURN (v - Align2(SYSTEM.AND(WORD(v), 15)) + LONGINT(16)) END;
  RETURN v
END Align16;

(* CalculateLayoutTiny: contiguous code+data+bss, header bytes reserved
   up front (18 for .SYS device-driver header, 3 for a .COM JMP stub).
   Parameters: none.
   Result: none (fatal via LogErr if the tiny-model 64KB limit is exceeded). *)
PROCEDURE CalculateLayoutTiny;
  VAR m: Module; codeBase, dataBase, bssBase: LONGINT;
BEGIN
  IF mode = ModeSys THEN headerSize := 18 ELSE headerSize := 3 END;
  codeBase := LONGINT(headerSize);
  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN m.finalCodeOfs := codeBase; codeBase := Align2(codeBase + m.codeSize) END;
    m := m.next
  END;
  totalCodeLen := codeBase;
  dataBase := totalCodeLen;
  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN m.finalDataOfs := dataBase; dataBase := Align2(dataBase + m.dataSize) END;
    m := m.next
  END;
  totalDataLen := dataBase - totalCodeLen;
  bssBase := dataBase;
  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN m.finalBssOfs := bssBase; bssBase := Align2(bssBase + m.bssSize) END;
    m := m.next
  END;
  totalBssLen := bssBase - (totalCodeLen + totalDataLen);
  IF bssBase > LONGINT(65530) THEN LogErr.Error("tlink: total size exceeds 64KB (Tiny Model)") END
END CalculateLayoutTiny;

(* CalculateLayoutSmall: CS is its own 64K segment (code, paragraph-
   aligned).  DS=SS is a SECOND 64K segment holding data+bss+stack
   together (small model): bss is placed right after data within that
   same DS-relative address space, NOT independently from 0 -- otherwise
   a bss variable and a data variable at the same module-relative offset
   would alias onto the same DS:offset at runtime.
   Parameters: none.
   Result: none (fatal via LogErr if code or data+bss exceeds 64KB). *)
PROCEDURE CalculateLayoutSmall;
  VAR m: Module; codeBase, dataBase, bssBase: LONGINT;
BEGIN
  codeBase := LONGINT(0); dataBase := LONGINT(0);
  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN
      m.finalCodeOfs := codeBase; m.finalDataOfs := dataBase;
      codeBase := Align16(codeBase + m.codeSize);
      dataBase := Align16(dataBase + m.dataSize)
    END;
    m := m.next
  END;
  totalCodeLen := codeBase; totalDataLen := dataBase;
  bssBase := totalDataLen;
  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN m.finalBssOfs := bssBase; bssBase := Align16(bssBase + m.bssSize) END;
    m := m.next
  END;
  totalBssLen := bssBase - totalDataLen;
  IF totalCodeLen > LONGINT(65520) THEN LogErr.Error("tlink: code > 64KB") END;
  IF totalDataLen + totalBssLen > LONGINT(65520) THEN LogErr.Error("tlink: data+bss > 64KB (DS/SS segment)") END
END CalculateLayoutSmall;

(* ---- relocation patching ---- *)

PROCEDURE PatchMem(rseg: INTEGER; offset: LONGINT; val: LONGINT; width: INTEGER);
  VAR buf: Rdoff.SegBuf; o: INTEGER; cur: WORD;
BEGIN
  IF mode = ModeExe THEN
    (* small model: code and data are two independent buffers, each
       offset is already relative to its own buffer's start *)
    IF rseg = Rdoff.SegCode THEN buf := codeBuf ELSE buf := dataBuf END;
    o := INTEGER(offset)
  ELSE
    (* tiny model: code and data share one contiguous buffer, data
       physically follows code, so an absolute offset picks the buffer *)
    IF offset < totalCodeLen THEN buf := codeBuf; o := INTEGER(offset)
    ELSE buf := dataBuf; o := INTEGER(offset - totalCodeLen)
    END
  END;

  IF width = 1 THEN
    buf^[o] := BYTE(SYSTEM.AND(INTEGER(buf^[o]) + INTEGER(BYTE(val)), 0FFH))
  ELSE
    cur := WORD(INTEGER(buf^[o]) + SYSTEM.LSL(INTEGER(buf^[o+1]), 8));
    cur := cur + WORD(val);   (* 16-bit WORD arithmetic wraps mod 65536 *)
    buf^[o]   := BYTE(SYSTEM.AND(cur, 0FFH));
    buf^[o+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(cur, 8), 0FFH))
  END
END PatchMem;

(* ---- linking: load code/data, apply relocations ---- *)

(* LeakGuard: report (DEBUG level only) if free heap shrank across a bounded
   unit of work that is expected to return to its starting baseline —
   matches SRC/TOC/TOC.MOD's own LeakGuard exactly (zero-heap-leak
   discipline applies to every tool in this toolchain, not just toc.exe).
   Parameters: memBefore — SYSTEM.MemAvail() captured before the unit of
   work; what — description of the unit, for the diagnostic message.
   Result: none (diagnostic only via LogErr.Debug). *)
PROCEDURE LeakGuard(memBefore: WORD; what: ARRAY OF CHAR);
  VAR memAfter: WORD; msg: ARRAY 256 OF CHAR;
BEGIN
  memAfter := SYSTEM.MemAvail();
  IF memAfter < memBefore THEN
    Strings.Copy("tlink: heap leak in ", msg);
    Strings.Append(what, msg);
    Strings.Append(" (", msg);
    Strings.AppendInt(LONGINT(memBefore - memAfter), msg);
    Strings.Append(" paragraphs)", msg);
    LogErr.Debug(msg)
  END
END LeakGuard;

VAR curMod: Module;   (* module whose relocs are being applied (for the FAR callbacks) *)

PROCEDURE OnImportForLink(flag, segId: INTEGER; name: ARRAY OF CHAR); FAR;
  VAR e: SymEntry;
BEGIN
  FindSymbol(name, e);
  ImpAdd(segId, e)
END OnImportForLink;

(* resolve a RELOC/SEGRELOC's target address (rrefSeg = 0/1/2 for code/
   data/bss, or an import ID > 2). Returns the resolved value, and sets
   ok FALSE (latching via LogErr) if an import ID can't be resolved. *)
PROCEDURE ResolveTarget(rrefSeg: INTEGER; VAR ok: BOOLEAN): LONGINT;
  VAR e: SymEntry; val: LONGINT; owner: Module;
BEGIN
  ok := TRUE;
  IF rrefSeg = Rdoff.SegCode THEN RETURN curMod.finalCodeOfs
  ELSIF rrefSeg = Rdoff.SegData THEN RETURN curMod.finalDataOfs
  ELSIF rrefSeg = Rdoff.SegBss THEN
    (* finalBssOfs is already DS-relative (CalculateLayoutSmall starts
       bssBase at totalDataLen; CalculateLayoutTiny starts it at
       totalCodeLen+totalDataLen) -- no extra totalDataLen addition here,
       that would double-count it (was needed only when bssBase used to
       start independently at 0 in small-model mode). *)
    RETURN curMod.finalBssOfs
  ELSE
    ImpFind(rrefSeg, e);
    IF ~SymFound(e) THEN LogErr.Error("tlink: relocation to missing import"); ok := FALSE; RETURN LONGINT(0) END;
    val := SymOffset(e);
    owner := SymOwner(e);
    IF SymSegId(e) = Rdoff.SegCode THEN RETURN val + owner.finalCodeOfs
    ELSIF SymSegId(e) = Rdoff.SegData THEN RETURN val + owner.finalDataOfs
    ELSE RETURN owner.finalBssOfs + val
    END
  END
END ResolveTarget;

PROCEDURE OnReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER; rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR patchAddr, fixup: LONGINT; ok: BOOLEAN;
BEGIN
  IF rseg = Rdoff.SegCode THEN patchAddr := curMod.finalCodeOfs + rofs
  ELSE patchAddr := curMod.finalDataOfs + rofs
  END;
  fixup := ResolveTarget(rrefSeg, ok);
  IF ~ok THEN RETURN END;
  IF rrel # 0 THEN
    IF rseg = Rdoff.SegCode THEN fixup := fixup - curMod.finalCodeOfs
    ELSE fixup := fixup - curMod.finalDataOfs
    END
  END;
  PatchMem(rseg, patchAddr, fixup, rwidth)
END OnReloc;

(* SEGRELOC only matters in EXE mode: patch the segment-base word and
   record an MZ relocation entry so DOS fixes it up again at load time
   (the small-model image can load at any paragraph). In COM/SYS (tiny)
   mode there is only one segment for the whole program, so a SEGRELOC
   target is always segment 0 relative to the image itself; tiny-model
   input never emits or consumes SEGRELOC records at all, so OnSegReloc is
   never wired for ModeCom/ModeSys — see PerformLinking below. *)
PROCEDURE OnSegReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER; rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR patchAddr, fixup: LONGINT; e: SymEntry;
BEGIN
  IF rseg = Rdoff.SegCode THEN patchAddr := curMod.finalCodeOfs + rofs
  ELSE patchAddr := curMod.finalDataOfs + rofs
  END;
  fixup := LONGINT(0);
  IF (rrefSeg = Rdoff.SegData) OR (rrefSeg = Rdoff.SegBss) THEN
    fixup := SYSTEM.LSR(WORD(totalCodeLen), 4)
  ELSIF rrefSeg > Rdoff.SegBss THEN
    ImpFind(rrefSeg, e);
    IF SymFound(e) & ((SymSegId(e) = Rdoff.SegData) OR (SymSegId(e) = Rdoff.SegBss)) THEN
      fixup := SYSTEM.LSR(WORD(totalCodeLen), 4)
    END
  END;
  PatchMem(rseg, patchAddr, fixup, 2);
  IF rseg = Rdoff.SegCode THEN AddReloc(0, WORD(patchAddr))
  ELSE AddReloc(WORD(SYSTEM.LSR(WORD(totalCodeLen), 4)), WORD(patchAddr))
  END
END OnSegReloc;

(* PerformLinking: allocate the code/data buffers, load every used
   module's code/data segment, then apply every RELOC (and, in EXE mode,
   SEGRELOC) fixup.
   Parameters: none (reads modHead/mode/totalCodeLen/totalDataLen).
   Result: none (failures latch via LogErr). *)
PROCEDURE PerformLinking;
  VAR m, owner: Module; e: SymEntry; k: WORD; memBefore: WORD;
BEGIN
  NEW(codeBuf, WORD(totalCodeLen));
  IF codeBuf = NIL THEN LogErr.Error("tlink: out of memory (code buffer)"); RETURN END;
  IF totalDataLen > LONGINT(0) THEN
    NEW(dataBuf, WORD(totalDataLen));
    IF dataBuf = NIL THEN LogErr.Error("tlink: out of memory (data buffer)"); RETURN END
  END;
  (* explicit indexed loop, NOT SYSTEM.FILL: SegBuf is a far-heap pointer and
     SYSTEM.FILL mis-addresses it — see DOCS/IMPLRULE.MD
     §"Reusing one shared code buffer" *)
  k := 0; WHILE k < WORD(totalCodeLen) DO codeBuf^[k] := BYTE(0); INC(k) END;
  IF totalDataLen > LONGINT(0) THEN
    k := 0; WHILE k < WORD(totalDataLen) DO dataBuf^[k] := BYTE(0); INC(k) END
  END;

  m := modHead;
  WHILE m # NIL DO
    IF m.used THEN
      Rdoff.ReadCode(m.fileName, m.libOfs, m.hdrSize, codeBuf, WORD(m.finalCodeOfs), WORD(m.codeSize));
      IF m.dataSize > LONGINT(0) THEN
        IF mode = ModeExe THEN
          Rdoff.ReadData(m.fileName, m.libOfs, m.hdrSize, dataBuf, WORD(m.finalDataOfs), WORD(m.dataSize))
        ELSE
          Rdoff.ReadData(m.fileName, m.libOfs, m.hdrSize, dataBuf, WORD(m.finalDataOfs - totalCodeLen), WORD(m.dataSize))
        END
      END;
      curMod := m;
      memBefore := SYSTEM.MemAvail();
      ImpReset;
      (* two-pass, matching SRC/TOC/LINK.MOD's own PerformLinking: collect
         IMPORT records first (a RELOC may reference an import that appears
         later in the same header-record stream), then apply RELOC/SEGRELOC.
         SEGRELOC only matters in EXE mode (see OnSegReloc's comment). *)
      Rdoff.ScanRelocs(m.fileName, m.libOfs, m.hdrSize, OnImportForLink, NIL, NIL);
      IF mode = ModeExe THEN
        Rdoff.ScanRelocs(m.fileName, m.libOfs, m.hdrSize, NIL, OnReloc, OnSegReloc)
      ELSE
        Rdoff.ScanRelocs(m.fileName, m.libOfs, m.hdrSize, NIL, OnReloc, NIL)
      END;
      ImpFree;
      LeakGuard(memBefore, "PerformLinking (per-module import scan)")
    END;
    m := m.next
  END;

  IF mode = ModeSys THEN
    FindSymbol("strategy", e); owner := SymOwner(e);
    strategyIp := WORD(SymOffset(e) + owner.finalCodeOfs);
    FindSymbol("interrupt", e); owner := SymOwner(e);
    interruptIp := WORD(SymOffset(e) + owner.finalCodeOfs)
  ELSE
    FindSymbol("start", e); owner := SymOwner(e);
    IF mode = ModeExe THEN
      entryIp := WORD(SymOffset(e));
      IF SymSegId(e) = Rdoff.SegCode THEN entryIp := entryIp + WORD(owner.finalCodeOfs)
      ELSIF SymSegId(e) = Rdoff.SegData THEN entryIp := entryIp + WORD(owner.finalDataOfs)
      END
    ELSE
      entryIp := WORD(SymOffset(e) + owner.finalCodeOfs)
    END
  END
END PerformLinking;

(* ---- output writers ---- *)

(* WriteOutputTiny: write a raw .COM (JMP start stub) or .SYS (device-
   driver header) image — no MZ header, no relocation table.
   Parameters: none (reads mode/codeBuf/dataBuf/outFileName/etc.).
   Result: none (failures latch via LogErr). *)
PROCEDURE WriteOutputTiny;
  VAR fout: Files.File; i: INTEGER; nameCh: CHAR; summary, base: ARRAY MaxPath OF CHAR;
BEGIN
  IF mode = ModeSys THEN
    (* device driver header: next(-1)[4] attr[2] strategy[2] interrupt[2] name[8] *)
    codeBuf^[0] := 0FFH; codeBuf^[1] := 0FFH; codeBuf^[2] := 0FFH; codeBuf^[3] := 0FFH;
    codeBuf^[4] := BYTE(SYSTEM.AND(sysAttr, 0FFH));
    codeBuf^[5] := BYTE(SYSTEM.AND(SYSTEM.LSR(sysAttr, 8), 0FFH));
    codeBuf^[6] := BYTE(SYSTEM.AND(strategyIp, 0FFH));
    codeBuf^[7] := BYTE(SYSTEM.AND(SYSTEM.LSR(strategyIp, 8), 0FFH));
    codeBuf^[8] := BYTE(SYSTEM.AND(interruptIp, 0FFH));
    codeBuf^[9] := BYTE(SYSTEM.AND(SYSTEM.LSR(interruptIp, 8), 0FFH));
    i := 0;
    WHILE i < 8 DO
      nameCh := sysName[i];
      IF nameCh = 0X THEN nameCh := " " END;
      codeBuf^[10 + i] := BYTE(ORD(nameCh));
      INC(i)
    END
  ELSE
    (* .COM stub: E9 rel16 (JMP start), rel16 = start - 3 *)
    codeBuf^[0] := 0E9H;
    codeBuf^[1] := BYTE(SYSTEM.AND(entryIp - 3, 0FFH));
    codeBuf^[2] := BYTE(SYSTEM.AND(SYSTEM.LSR(entryIp - 3, 8), 0FFH))
  END;

  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("tlink: cannot write ", outFileName); RETURN END;
  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("tlink: write error (code)")
  END;
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("tlink: write error (data)")
    END
  END;
  Files.Close(fout);

  BaseName(outFileName, base);
  UpcaseInPlace(base);
  Strings.Copy(base, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(totalBssLen,  summary);
  LogErr.Info(summary)
END WriteOutputTiny;

(* WriteOutputExe: write an MZ small-model .EXE (header + relocation
   table + padding + code + data): SS = codePara, SP = $FFFE fixed,
   ExtraMem heuristic for min/max alloc.
   Parameters: none (reads codeBuf/dataBuf/relocHead/entryIp/outFileName).
   Result: none (failures latch via LogErr). *)
PROCEDURE WriteOutputExe;
  VAR fout: Files.File;
      codePara, dataPara, hdrPara: WORD;
      exeSize: LONGINT;
      pageCnt, partPage: WORD;
      extraMem: WORD;
      rel: RelNode;
      gapBytes: LONGINT;
      pad: BYTE;
      summary, base: ARRAY MaxPath OF CHAR;
BEGIN
  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("tlink: cannot write ", outFileName); RETURN END;

  (* codePara must round UP (ceiling), not truncate: SS is set to codePara,
     so if totalCodeLen isn't a multiple of 16, truncating leaves the last
     <16 bytes of code physically inside the stack segment -- stack pushes
     during execution then overwrite the tail of the code image (observed
     as a live jnz/jmp target silently corrupted to different bytes at
     runtime while the on-disk .EXE stayed correct -- see VOIDF.C's putint
     loop, TESTS/FIX/CC repro). *)
  codePara := WORD(SYSTEM.LSR(WORD(totalCodeLen), 4));
  IF SYSTEM.AND(WORD(totalCodeLen), 15) # 0 THEN INC(codePara) END;
  dataPara := WORD(SYSTEM.LSR(WORD(totalDataLen), 4));
  IF SYSTEM.AND(WORD(totalDataLen), 15) # 0 THEN INC(dataPara) END;

  hdrPara := WORD(SYSTEM.LSR(28 + relCount * 4, 4)) + 1;

  IF dataPara < 1000H THEN extraMem := 1000H - dataPara ELSE extraMem := 0 END;

  (* the on-disk code region is padded up to codePara*16 bytes (below) so
     that DS (set at runtime to SS=codePara via "mov ax,ss / mov ds,ax")
     really does point at the first byte of data -- otherwise DS:0 would
     land codePara*16 - totalCodeLen bytes before the true start of .data,
     corrupting every "mov ax, label" / "mov ax, label+N" data reference
     (observed as HELLO.C's string losing its first byte: PatchMem/
     ResolveTarget compute data-buffer-relative offsets under exactly this
     assumption -- see CalculateLayoutSmall / ResolveTarget's SegData case). *)
  exeSize  := LONGINT(hdrPara) * LONGINT(16) + LONGINT(codePara) * LONGINT(16) + totalDataLen;
  pageCnt  := WORD(exeSize DIV LONGINT(512));
  partPage := WORD(exeSize MOD LONGINT(512));
  IF partPage # 0 THEN INC(pageCnt) END;

  Files.WriteWord(fout, 5A4DH);          (* signature "MZ" *)
  Files.WriteWord(fout, INTEGER(partPage));
  Files.WriteWord(fout, INTEGER(pageCnt));
  Files.WriteWord(fout, INTEGER(relCount));
  Files.WriteWord(fout, INTEGER(hdrPara));
  Files.WriteWord(fout, INTEGER(extraMem));  (* min alloc *)
  Files.WriteWord(fout, INTEGER(extraMem));  (* max alloc *)
  Files.WriteWord(fout, INTEGER(codePara));  (* SS *)
  Files.WriteWord(fout, 0FFFEH);             (* SP *)
  Files.WriteWord(fout, 0);                  (* checksum *)
  Files.WriteWord(fout, entryIp);            (* IP *)
  Files.WriteWord(fout, 0);                  (* CS *)
  Files.WriteWord(fout, 28);                 (* reloc table offset *)
  Files.WriteWord(fout, 0);                  (* overlay *)

  rel := relHead;
  WHILE rel # NIL DO
    IF rel.count > 0 THEN
      IF Files.BlockWrite(fout, rel.w[0], WORD(rel.count * 2 * 2)) # WORD(rel.count * 2 * 2) THEN
        LogErr.Error("tlink: write error (MZ reloc)")
      END
    END;
    rel := rel.next
  END;

  gapBytes := LONGINT(hdrPara) * LONGINT(16) - Files.Position(fout);
  pad := 0;
  WHILE gapBytes > LONGINT(0) DO Files.BlockWrite(fout, pad, 1); DEC(gapBytes) END;

  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("tlink: write error (code)")
  END;
  gapBytes := LONGINT(codePara) * LONGINT(16) - totalCodeLen;
  WHILE gapBytes > LONGINT(0) DO Files.BlockWrite(fout, pad, 1); DEC(gapBytes) END;
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("tlink: write error (data)")
    END
  END;
  Files.Close(fout);

  BaseName(outFileName, base);
  UpcaseInPlace(base);
  Strings.Copy(base, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(totalBssLen,  summary);
  LogErr.Info(summary)
END WriteOutputExe;

(* ---- command line ---- *)

(* ParseHex: parse a hex string (no prefix required, e.g. "8000" from
   "/A:8000") into an INTEGER.
   Parameters: s — the hex digits.
   Result: the parsed value (fatal via LogErr on a non-hex character). *)
PROCEDURE ParseHex(s: ARRAY OF CHAR): INTEGER;
  VAR v, i: INTEGER; c: CHAR;
BEGIN
  v := 0; i := 0;
  IF s[0] = 0X THEN LogErr.Error("tlink: /A: requires a hex value"); RETURN 0 END;
  WHILE s[i] # 0X DO
    c := SYSTEM.UCASE(s[i]);
    IF (c >= "0") & (c <= "9") THEN v := v * 16 + (ORD(c) - ORD("0"))
    ELSIF (c >= "A") & (c <= "F") THEN v := v * 16 + (ORD(c) - ORD("A") + 10)
    ELSE LogErr.Error2("tlink: invalid hex value: ", s); RETURN v
    END;
    INC(i)
  END;
  RETURN v
END ParseHex;

PROCEDURE ProcessBinaryInput(name: ARRAY OF CHAR);
BEGIN ScanFile(name)
END ProcessBinaryInput;

(* MatchSwitchVal: case-insensitive prefix match; on success copies the
   remainder of 'arg' (after 'pfx') into 'val'.
   Parameters: arg — the command-line argument; pfx — the switch prefix to
   match, e.g. "/T="; VAR val — receives the value after the prefix.
   Result: TRUE if 'arg' starts with 'pfx' (case-insensitive). *)
PROCEDURE MatchSwitchVal(arg, pfx: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (pfx[i] # 0X) & (SYSTEM.UCASE(arg[i]) = SYSTEM.UCASE(pfx[i])) DO INC(i) END;
  IF pfx[i] # 0X THEN RETURN FALSE END;
  j := 0;
  WHILE arg[i] # 0X DO val[j] := arg[i]; INC(i); INC(j) END;
  val[j] := 0X;
  RETURN TRUE
END MatchSwitchVal;

(* ParseListFile: read one whitespace-trimmed path per line from 'path'
   and ScanFile each.
   Parameters: path — the @listfile's path (without the leading '@').
   Result: none (failures latch via LogErr). *)
PROCEDURE ParseListFile(path: ARRAY OF CHAR);
  VAR f: Files.File; line: ARRAY MaxPath OF CHAR;
BEGIN
  IF ~Files.Reset(f, path) THEN LogErr.Error2("tlink: cannot open list file ", path); RETURN END;
  WHILE Files.Position(f) < Files.Size(f) DO
    Files.ReadLine(f, line, WORD(LEN(line)));
    IF line[0] # 0X THEN ProcessBinaryInput(line) END
  END;
  Files.Close(f)
END ParseListFile;

PROCEDURE Usage;
BEGIN
  Out.String("Trubo Link, (c) 2026 DosWord, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("Usage: TLINK [options] <input> ... <output>"); Out.Ln;
  Out.Ln;
  Out.String("Options:"); Out.Ln;
  Out.Ln;
  Out.String(" /T=com      Tiny model .COM output (default)"); Out.Ln;
  Out.String(" /T=sys      Tiny model .SYS device driver output"); Out.Ln;
  Out.String(" /T=exe      Small model .EXE output"); Out.Ln;
  Out.String(" /A=xxxx     Device attribute (hex) - implies /T=sys"); Out.Ln;
  Out.String(" /N=name     Device name (max 8 chars, /T=sys only)"); Out.Ln;
  Out.String(" /LOG=level  debug|info|warn|error"); Out.Ln;
  Out.String(" @list.lst   Process list file"); Out.Ln;
  Out.Ln;
  Out.String("Inputs: .rdf, .rdl, .tar"); Out.Ln
END Usage;

(* RunBody: parse arguments, drive the four link phases, and report the
   process exit code.
   Parameters: none.
   Result: 0 on success, 1 on any link error, 2 if usage was printed. *)
PROCEDURE RunBody(): INTEGER;
  VAR i, argc: INTEGER; arg, val: ARRAY MaxPath OF CHAR; showHelp: BOOLEAN;
BEGIN
  argc := Dos.ParamCount();
  showHelp := argc < 1;
  i := 1;
  WHILE i <= argc DO
    Dos.ParamStr(i, arg);
    IF Strings.Equal(arg, "/?") OR Strings.Equal(arg, "-?")
       OR Strings.EqualICase(arg, "/h") OR Strings.EqualICase(arg, "-h") THEN
      showHelp := TRUE
    END;
    INC(i)
  END;
  IF showHelp THEN Usage; RETURN 2 END;

  mode := ModeCom;
  sysAttr := 0;
  sysName := "        ";
  modHead := NIL; modTail := NIL;
  symHead := NIL; symTail := NIL;
  noSym.node := NIL; noSym.slot := 0;
  relHead := NIL; relTail := NIL; relCount := 0;

  (* pass 1: options + inputs (all args except the last, which is the output) *)
  i := 1;
  WHILE i < argc DO
    Dos.ParamStr(i, arg);
    IF MatchSwitchVal(arg, "/LOG=", val) THEN
      IF Strings.EqualICase(val, "debug") THEN LogErr.SetLevel(LogErr.LDEBUG)
      ELSIF Strings.EqualICase(val, "info") THEN LogErr.SetLevel(LogErr.LINFO)
      ELSIF Strings.EqualICase(val, "warn") THEN LogErr.SetLevel(LogErr.LWARN)
      ELSIF Strings.EqualICase(val, "error") THEN LogErr.SetLevel(LogErr.LERROR)
      ELSE LogErr.Error2("tlink: /LOG=: unknown level: ", val); RETURN 1
      END
    ELSIF MatchSwitchVal(arg, "/T=", val) THEN
      IF Strings.EqualICase(val, "com") THEN mode := ModeCom
      ELSIF Strings.EqualICase(val, "sys") THEN mode := ModeSys
      ELSIF Strings.EqualICase(val, "exe") THEN mode := ModeExe
      ELSE LogErr.Error2("tlink: unknown /T= mode: ", val); RETURN 1
      END
    ELSIF MatchSwitchVal(arg, "/A=", val) THEN
      mode := ModeSys;
      sysAttr := ParseHex(val)
    ELSIF MatchSwitchVal(arg, "/N=", val) THEN
      mode := ModeSys;
      Strings.Extract(val, 0, 8, sysName);
      WHILE Strings.Length(sysName) < 8 DO Strings.Append(" ", sysName) END
    ELSIF arg[0] = "@" THEN
      Strings.Extract(arg, 1, Strings.Length(arg) - 1, val);
      ParseListFile(val)
    ELSIF (arg[0] # "-") & (arg[0] # "/") THEN
      ProcessBinaryInput(arg)
    ELSE
      LogErr.Error2("tlink: unknown option: ", arg); RETURN 1
    END;
    INC(i)
  END;

  Dos.ParamStr(argc, outFileName);

  SmartLink;
  IF LogErr.HaveErr() THEN RETURN 1 END;
  IF mode = ModeExe THEN CalculateLayoutSmall ELSE CalculateLayoutTiny END;
  IF LogErr.HaveErr() THEN RETURN 1 END;
  PerformLinking;
  IF LogErr.HaveErr() THEN RETURN 1 END;
  IF mode = ModeExe THEN WriteOutputExe ELSE WriteOutputTiny END;
  IF LogErr.HaveErr() THEN RETURN 1 END;

  RETURN 0
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  LogErr.Close;
  SYSTEM.Halt(rc)   (* the ONE and ONLY SYSTEM.Halt in tlink *)
END Run;

END TLink.
