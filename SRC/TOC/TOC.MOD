(*$M 26000, 256000, 256000*)
(*$D-*)
MODULE TOC;
(*
  All-in-one build driver: dependency scan + incremental compile + link.

  Modes (determined by /ENTRY=):
    No /ENTRY=:   scan deps, recompile stale modules, emit .om files only.
                  Used for building libraries and intermediate modules.
    /ENTRY=Proc:  scan deps, recompile stale modules, link all .om -> .exe.
                  Used for building executables.

  The module named directly on the command line (the root module) is always
  recompiled.  An imported (dependency) module is "stale" — and so is
  recompiled — if its .om is missing or has zero size; with /M, it is ALSO
  stale if its source file's mtime is newer than its .om's (checked via
  Files.GetFTime).  /M does not force-rebuild every module unconditionally —
  it only enables that source-newer-than-.om comparison for imports that
  have a source file available.
  Pass /G to append the TDS/TDINFO debug block to the linked .exe (merged from
  the MODNAME.DBG members of modules compiled with $D+; see
  docs/implementation-rules.md §".DBG file format").
*)
IMPORT Dos, Files, Strings, Scan, Syms, Cgen, Rdoff, Tar,
       Import, Parser, PExpr, Link, LogErr, Time, Out, StrTab;

CONST
  NameLen  = 33;
  MaxPath  = 128;
  OpCallFar = 09AH;

CONST
  MaxDeps  = 32;   (* per-module import cap (largest real module imports ~14) *)

  (* flag bits in the on-file ModEntry record *)
  FlagHasSrc  = 1;
  FlagIsMain  = 2;
  FlagSorted  = 4;
  FlagVisited = 8;
  FlagInStack = 16;

TYPE
  (* A module is identified by its 0-based index into the file-backed module
     table (gModFile).  ModEntry is that index; NoMod (-1) is the null handle. *)
  ModEntry = INTEGER;

  (* On-file fixed-size module record.  The whole dependency graph lives in one
     temp file (gModFile) for the entire compile→link cycle, so the long-lived
     graph never sits in the heap to fragment the arena (every per-module .rdf
     buffer and the linker's code-group buffer then allocate contiguously).
     Layout (RecLen bytes): flags(1) name(NameLen) srcPath(MaxPath)
     sortNext(2) nDeps(1) deps(MaxDeps*2).  omPath is derived from name
     (MakeOmName) so it is not stored.  sortNext chains the topological order as
     an in-file linked list (index, or NoMod for end) — so module count is
     unbounded (no fixed sortOrder array). *)
  ModRec = RECORD
    flags:    INTEGER;
    name:     ARRAY NameLen OF CHAR;
    srcPath:  ARRAY MaxPath OF CHAR;
    sortNext: ModEntry;
    nDeps:    INTEGER;
    deps:     ARRAY MaxDeps OF ModEntry
  END;

  (* Linked list of imported module names, collected while the source file is
     open, then traversed AFTER it is closed (so only one scanner is open at a
     time during the recursive dependency walk).  Freed at the end of the scan. *)
  NameNode = POINTER TO NameNodeRec;
  NameNodeRec = RECORD
    name: ARRAY NameLen OF CHAR;
    next: NameNode
  END;

CONST
  NoMod   = -1;
  RecLen  = 1 + NameLen + MaxPath + 2 + 1 + MaxDeps * 2;

VAR
  (* File-backed module table — one temp file holding every ModRec, opened once
     in Run and kept open the whole cycle (an open file costs ~8 KB, so we use
     exactly one for the entire graph; module count is unbounded).  modCount is
     the number of records; gSortHead is the index of the first module in topo
     order (the chain follows ModRec.sortNext). *)
  gModFile:  Files.File;
  gModOpen:  BOOLEAN;
  modCount:  ModEntry;
  gSortHead: ModEntry;
  gSortTail: ModEntry;

(* ---- string helpers ---- *)

(* If `arg` begins with `pfx` (compared case-insensitively), copy the remainder
   after the prefix into `val` (case-preserving) and return TRUE; else FALSE.
   Used for the /ENTRY=Proc switch (prefix /ENTRY= is case-insensitive, the
   procedure name keeps its case). *)
PROCEDURE MatchSwitchVal(arg, pfx: ARRAY OF CHAR; VAR val: ARRAY OF CHAR): BOOLEAN;
  VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (pfx[i] # 0X) & (SYSTEM.UCASE(arg[i]) = SYSTEM.UCASE(pfx[i])) DO INC(i) END;
  IF pfx[i] # 0X THEN RETURN FALSE END;   (* prefix did not fully match *)
  j := 0;
  WHILE arg[i] # 0X DO val[j] := arg[i]; INC(i); INC(j) END;
  val[j] := 0X;
  RETURN TRUE
END MatchSwitchVal;

PROCEDURE MakeOmName(modName: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
BEGIN
  Files.ReplaceExt(modName, ".OM", dst);
  SYSTEM.UPSTR(dst)
END MakeOmName;

PROCEDURE BaseStem(path: ARRAY OF CHAR; VAR stem: ARRAY OF CHAR);
  VAR i, start, dot: INTEGER;
BEGIN
  start := 0; dot := -1; i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = "/") OR (path[i] = "\") OR (path[i] = ":") THEN start := i + 1; dot := -1 END;
    IF path[i] = "." THEN dot := i END;
    INC(i)
  END;
  IF dot < start THEN dot := i END;
  i := start;
  WHILE (i < dot) & (i - start < LEN(stem) - 1) DO
    stem[i - start] := path[i]; INC(i)
  END;
  stem[i - start] := 0X
END BaseStem;

(* ---- staleness check ---- *)

(* A module is stale if its .om is missing or zero-size.  When checkTime is
   TRUE (i.e. /M was passed) and a source file is available, it is ALSO stale
   if the source's mtime is newer than the .om's — so /M means "rebuild
   whatever actually changed", not "rebuild everything unconditionally".
   srcPath may be empty (module has no source, e.g. a pure .om dependency);
   the time check is skipped in that case. *)
PROCEDURE IsStale(omPath, srcPath: ARRAY OF CHAR; checkTime: BOOLEAN): BOOLEAN;
  VAR f: Files.File; omTime, srcTime: Time.DosTime;
BEGIN
  IF ~Files.Reset(f, omPath) THEN RETURN TRUE END;
  IF Files.Size(f) = LONGINT(0) THEN Files.Close(f); RETURN TRUE END;
  IF checkTime & (srcPath[0] # 0X) THEN
    Files.GetFTime(f, omTime);
    Files.Close(f);
    IF Files.Reset(f, srcPath) THEN
      Files.GetFTime(f, srcTime);
      Files.Close(f);
      RETURN srcTime > omTime
    END;
    RETURN FALSE
  END;
  Files.Close(f);
  RETURN FALSE
END IsStale;

(* ---- source file search ---- *)

PROCEDURE TryPath(dir, name: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
  VAR path: ARRAY MaxPath OF CHAR; f: Files.File; i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(path) - 1) & (dir[i] # 0X) DO path[i] := dir[i]; INC(i) END;
  IF (i > 0) & (path[i-1] # "\") & (path[i-1] # "/") & (i < LEN(path) - 1) THEN
    path[i] := "\"; INC(i)
  END;
  j := 0;
  WHILE (i < LEN(path) - 5) & (name[j] # 0X) DO path[i] := name[j]; INC(i); INC(j) END;
  path[i] := 0X;
  IF Files.Reset(f, path) THEN
    IF Files.Size(f) > LONGINT(0) THEN Files.Close(f); Strings.Copy(path, result); RETURN TRUE END;
    Files.Close(f)
  END;
  path[i] := "."; path[i+1] := "M"; path[i+2] := "O"; path[i+3] := "D"; path[i+4] := 0X;
  IF Files.Reset(f, path) THEN
    IF Files.Size(f) > LONGINT(0) THEN Files.Close(f); Strings.Copy(path, result); RETURN TRUE END;
    Files.Close(f)
  END;
  RETURN FALSE
END TryPath;

PROCEDURE FindSrc(name: ARRAY OF CHAR; VAR result: ARRAY OF CHAR): BOOLEAN;
  VAR i, dlen: INTEGER; env: ARRAY 256 OF CHAR; dir: ARRAY MaxPath OF CHAR;
BEGIN
  IF TryPath(".", name, result) THEN RETURN TRUE END;
  Dos.GetEnv("OBERON_LIB", env);
  i := 0;
  WHILE env[i] # 0X DO
    dlen := 0;
    WHILE (env[i] # 0X) & (env[i] # ";") & (env[i] # ":") & (dlen < MaxPath - 1) DO
      dir[dlen] := env[i]; INC(dlen); INC(i)
    END;
    dir[dlen] := 0X;
    IF (env[i] = ";") OR (env[i] = ":") THEN INC(i) END;
    IF (dlen > 0) & TryPath(dir, name, result) THEN RETURN TRUE END
  END;
  result[0] := 0X; RETURN FALSE
END FindSrc;

(* ---- file-backed module table ----
   Every ModRec lives in gModFile at offset idx*RecLen.  ModRead/ModWrite move a
   whole record in/out through a fixed local ModRec on the stack — the heap never
   holds the graph, so it cannot fragment the arena.  The record is serialized to
   a flat byte buffer first (so a single BlockRead/Write moves it). *)

(* 16-bit value stored low-then-high at buf[p]/buf[p+1] *)
PROCEDURE PutW(VAR buf: ARRAY OF BYTE; p: INTEGER; v: INTEGER);
BEGIN
  buf[p]   := BYTE(SYSTEM.AND(v, 0FFH));
  buf[p+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(v, 8), 0FFH))
END PutW;

(* an all-ones value reads back as the signed INTEGER -1 (= NoMod), which is
   exactly what we want for sortNext/deps. *)
PROCEDURE GetW(VAR buf: ARRAY OF BYTE; p: INTEGER): INTEGER;
BEGIN
  RETURN INTEGER(buf[p]) + SYSTEM.LSL(INTEGER(buf[p+1]), 8)
END GetW;

PROCEDURE PackMod(VAR r: ModRec; VAR buf: ARRAY OF BYTE);
  VAR i, p: INTEGER;
BEGIN
  buf[0] := BYTE(r.flags);
  i := 0; WHILE i < NameLen DO buf[1 + i] := ORD(r.name[i]); INC(i) END;
  i := 0; WHILE i < MaxPath DO buf[1 + NameLen + i] := ORD(r.srcPath[i]); INC(i) END;
  p := 1 + NameLen + MaxPath;
  PutW(buf, p, r.sortNext);
  INC(p, 2);
  buf[p] := BYTE(r.nDeps); INC(p);
  i := 0;
  WHILE i < MaxDeps DO
    PutW(buf, p, r.deps[i]);
    INC(p, 2); INC(i)
  END
END PackMod;

PROCEDURE UnpackMod(VAR buf: ARRAY OF BYTE; VAR r: ModRec);
  VAR i, p: INTEGER;
BEGIN
  r.flags := INTEGER(buf[0]);
  i := 0; WHILE i < NameLen DO r.name[i] := CHR(buf[1 + i]); INC(i) END;
  i := 0; WHILE i < MaxPath DO r.srcPath[i] := CHR(buf[1 + NameLen + i]); INC(i) END;
  p := 1 + NameLen + MaxPath;
  r.sortNext := GetW(buf, p);
  INC(p, 2);
  r.nDeps := INTEGER(buf[p]); INC(p);
  i := 0;
  WHILE i < MaxDeps DO
    r.deps[i] := GetW(buf, p);
    INC(p, 2); INC(i)
  END
END UnpackMod;

PROCEDURE ModRead(idx: ModEntry; VAR r: ModRec);
  VAR buf: ARRAY RecLen OF BYTE;
BEGIN
  Files.Seek(gModFile, LONGINT(idx) * LONGINT(RecLen));
  Files.BlockRead(gModFile, buf[0], RecLen);
  UnpackMod(buf, r)
END ModRead;

PROCEDURE ModWrite(idx: ModEntry; VAR r: ModRec);
  VAR buf: ARRAY RecLen OF BYTE;
BEGIN
  PackMod(r, buf);
  Files.Seek(gModFile, LONGINT(idx) * LONGINT(RecLen));
  Files.BlockWrite(gModFile, buf[0], RecLen)
END ModWrite;

PROCEDURE HasFlag(VAR r: ModRec; bit: INTEGER): BOOLEAN;
BEGIN RETURN SYSTEM.AND(r.flags, bit) # 0 END HasFlag;

PROCEDURE SetFlag(VAR r: ModRec; bit: INTEGER);
BEGIN r.flags := SYSTEM.IOR(r.flags, bit) END SetFlag;

PROCEDURE ClrFlag(VAR r: ModRec; bit: INTEGER);
BEGIN r.flags := SYSTEM.AND(r.flags, SYSTEM.XOR(bit, 0FFH)) END ClrFlag;

(* ---- dependency scanner ---- *)

PROCEDURE FindMod(name: ARRAY OF CHAR): ModEntry;
  VAR i: ModEntry; r: ModRec;
BEGIN
  i := 0;
  WHILE i < modCount DO
    ModRead(i, r);
    IF Strings.Equal(r.name, name) THEN RETURN i END;
    INC(i)
  END;
  RETURN NoMod
END FindMod;

PROCEDURE AddMod(name: ARRAY OF CHAR): ModEntry;
  VAR idx: ModEntry; i: INTEGER; r: ModRec;
BEGIN
  idx := FindMod(name);
  IF idx # NoMod THEN RETURN idx END;
  r.flags := 0;
  Strings.Copy(name, r.name);
  r.srcPath[0] := 0X;
  r.sortNext := NoMod;
  r.nDeps := 0;
  i := 0; WHILE i < MaxDeps DO r.deps[i] := NoMod; INC(i) END;
  idx := modCount;
  ModWrite(idx, r);
  INC(modCount);
  RETURN idx
END AddMod;

PROCEDURE ScanDeps(mod: ModEntry); FORWARD;

(* ParseAndScanS: dep-scan one source file using a caller-supplied Scanner.
   The Scanner record is ~2 KB (sysArgs alone is 1 KB); the recursive walk
   ParseAndScan -> ScanDeps -> ParseAndScan must NOT keep one per stack frame
   (SP wrap hazard, see DOCS/IMPLRULE.MD stack-frame rule), so the wrapper
   below heap-allocates it per recursion level instead. *)
PROCEDURE ParseAndScanS(VAR sc: Scan.Scanner; srcPath: ARRAY OF CHAR;
                        owner: ModEntry): BOOLEAN;
  VAR modName, realName, alias: ARRAY NameLen OF CHAR;
      dep: ModEntry;
      ownerR, depR: ModRec;
      srcPath2: ARRAY MaxPath OF CHAR;
      (* Collect imported module names into a linked list FIRST, then close the
         source file before recursing.  Recursing while `sc` is still open would
         keep one open file handle + one 8 KB scanner buffer alive per import-tree
         level — a 12-deep graph (Parser imports 12 modules) would pin ~12 handles
         and ~100 KB at once, exhausting the DOS handle table / heap before the
         deepest module can write its .rdf.  A linked list (vs. a fixed array)
         imposes no static import-count limit and is freed at the end of the scan. *)
      head, tail, n, nx: NameNode;
BEGIN
  head := NIL; tail := NIL;
  Scan.Open(sc, srcPath);
  IF LogErr.HaveErr() THEN Scan.Close(sc); RETURN FALSE END;
  IF sc.sym # Scan.TModule THEN Scan.Close(sc); RETURN FALSE END;
  Scan.Next(sc);
  IF sc.sym # Scan.TIdent THEN Scan.Close(sc); RETURN FALSE END;
  Strings.Copy(sc.id, modName);
  (* Track the module by its REAL name (from the source), not the file stem.
     The compiler names the output .om after the module name, so the driver must
     look it up by the same name — otherwise a file whose basename differs from
     its MODULE identifier (e.g. entrycas.mod / MODULE EntryCase53) is not found
     at link time. *)
  ModRead(owner, ownerR);
  Strings.Copy(modName, ownerR.name);
  ModWrite(owner, ownerR);   (* persist real name before recursion (dedup needs it) *)
  Scan.Next(sc);
  IF sc.sym # Scan.TSemi THEN Scan.Close(sc); RETURN TRUE END;
  Scan.Next(sc);
  IF sc.sym # Scan.TImport THEN Scan.Close(sc); RETURN TRUE END;
  Scan.Next(sc);
  (* Pass 1: read all imported real-names into the list while the file is open. *)
  WHILE sc.sym = Scan.TIdent DO
    Strings.Copy(sc.id, alias);
    Scan.Next(sc);
    IF sc.sym = Scan.TAssign THEN
      Scan.Next(sc);
      IF sc.sym = Scan.TIdent THEN
        Strings.Copy(sc.id, realName); Scan.Next(sc)
      ELSE
        (* free the partial list before bailing out *)
        WHILE head # NIL DO nx := head^.next; DISPOSE(head); head := nx END;
        Scan.Close(sc); RETURN FALSE
      END
    ELSE
      Strings.Copy(alias, realName)
    END;
    IF ~Strings.Equal(realName, "SYSTEM") THEN
      NEW(n);
      IF n = NIL THEN
        LogErr.Error("out of memory (import list)");
        WHILE head # NIL DO nx := head^.next; DISPOSE(head); head := nx END;
        Scan.Close(sc); RETURN FALSE
      END;
      Strings.Copy(realName, n^.name); n^.next := NIL;
      IF tail = NIL THEN head := n ELSE tail^.next := n END;
      tail := n
    END;
    IF sc.sym = Scan.TComma THEN Scan.Next(sc) END
  END;
  (* Close the source file (frees its handle + 8 KB buffer) BEFORE recursing. *)
  Scan.Close(sc);
  (* Pass 2: register each dependency and recurse — now with no file open here.
     Each dep index is appended to the owner's in-file deps[] array.  We re-read
     the owner record each iteration because AddMod / ScanDeps may have grown the
     file (the owner's slot itself is never moved, so its index is stable). *)
  n := head;
  WHILE n # NIL DO
    dep := AddMod(n^.name);
    ModRead(dep, depR);
    IF ~HasFlag(depR, FlagHasSrc) & ~HasFlag(depR, FlagVisited) THEN
      IF FindSrc(n^.name, srcPath2) THEN
        Strings.Copy(srcPath2, depR.srcPath);
        SetFlag(depR, FlagHasSrc);
        ModWrite(dep, depR)
      END
    END;
    ModRead(owner, ownerR);
    IF ownerR.nDeps < MaxDeps THEN
      ownerR.deps[ownerR.nDeps] := dep; INC(ownerR.nDeps);
      ModWrite(owner, ownerR)
    ELSE
      LogErr.Error2("oc: too many imports in module ", ownerR.name);
      (* free the remaining import-name list and fail (no Halt — funnels to Run) *)
      WHILE head # NIL DO nx := head^.next; DISPOSE(head); head := nx END;
      RETURN FALSE
    END;
    ScanDeps(dep);
    n := n^.next
  END;
  (* Free the import-name list at the end of this module's scan. *)
  n := head;
  WHILE n # NIL DO nx := n^.next; DISPOSE(n); n := nx END;
  RETURN TRUE
END ParseAndScanS;

PROCEDURE ParseAndScan(srcPath: ARRAY OF CHAR; owner: ModEntry): BOOLEAN;
  VAR scP: POINTER TO Scan.Scanner; ok: BOOLEAN;
BEGIN
  NEW(scP);
  IF scP = NIL THEN
    LogErr.Error("oc: out of memory (dep-scan scanner)");
    RETURN FALSE
  END;
  ok := ParseAndScanS(scP^, srcPath, owner);
  DISPOSE(scP);
  RETURN ok
END ParseAndScan;

PROCEDURE ScanDeps;
  VAR r: ModRec; srcPath: ARRAY MaxPath OF CHAR;
BEGIN
  ModRead(mod, r);
  IF HasFlag(r, FlagVisited) THEN RETURN END;
  SetFlag(r, FlagVisited);
  ModWrite(mod, r);
  IF HasFlag(r, FlagHasSrc) THEN
    Strings.Copy(r.srcPath, srcPath);   (* ParseAndScan re-reads/writes mod *)
    IF ~ParseAndScan(srcPath, mod) THEN
      LogErr.Error2("oc: parse error in: ", srcPath)
    END
  END
END ScanDeps;

(* ---- topological sort ---- *)

PROCEDURE TopoVisit(mod: ModEntry);
  VAR r: ModRec; i: INTEGER; dep: ModEntry;
BEGIN
  ModRead(mod, r);
  IF HasFlag(r, FlagInStack) THEN
    LogErr.Error2("oc: circular dependency: ", r.name);
    RETURN
  END;
  IF HasFlag(r, FlagSorted) THEN RETURN END;
  SetFlag(r, FlagInStack);
  ModWrite(mod, r);
  (* recurse into deps (TopoVisit may rewrite mod's flags only, not its deps) *)
  i := 0;
  WHILE i < r.nDeps DO dep := r.deps[i]; TopoVisit(dep); INC(i) END;
  ModRead(mod, r);
  ClrFlag(r, FlagInStack);
  SetFlag(r, FlagSorted);
  r.sortNext := NoMod;
  ModWrite(mod, r);
  IF gSortTail = NoMod THEN
    gSortHead := mod
  ELSE
    ModRead(gSortTail, r); r.sortNext := mod; ModWrite(gSortTail, r)
  END;
  gSortTail := mod
END TopoVisit;

PROCEDURE TopoSort;
  VAR i: ModEntry; r: ModRec;
BEGIN
  gSortHead := NoMod; gSortTail := NoMod;
  i := 0;
  WHILE i < modCount DO
    ModRead(i, r);
    IF ~HasFlag(r, FlagSorted) THEN TopoVisit(i) END;
    INC(i)
  END
END TopoSort;

(* ---- module-graph lifetime ----
   The whole dependency graph lives in one temp file (gModFile), opened once at
   the start of Run and kept open the entire compile→link cycle.  Because it is
   never resident in the heap, it cannot fragment the arena: every per-module
   .rdf buffer and the linker's contiguous code-group buffer allocate cleanly.
   FreeMods just closes (and so deletes) the temp file. *)

PROCEDURE OpenModFile(): BOOLEAN;
BEGIN
  IF ~Files.ReWriteTemp(gModFile) THEN
    LogErr.Error("oc: cannot create module-graph temp");
    RETURN FALSE
  END;
  gModOpen := TRUE;
  modCount := 0;
  gSortHead := NoMod; gSortTail := NoMod;
  RETURN TRUE
END OpenModFile;

PROCEDURE FreeMods;
BEGIN
  IF gModOpen THEN Files.Close(gModFile); gModOpen := FALSE END;
  modCount := 0; gSortHead := NoMod; gSortTail := NoMod
END FreeMods;

(* ---- entry stub + repack (from original Main) ---- *)

PROCEDURE EmitFarCallTo(obj: Rdoff.ObjFile; id: INTEGER);
  VAR oa, sa: LONGINT;
BEGIN
  Rdoff.EmitByte(obj, Rdoff.SegCode, OpCallFar);
  oa := Rdoff.CodeLen(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0));
  sa := Rdoff.CodeLen(obj);
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0));
  Rdoff.RdfAddReloc(obj, Rdoff.SegCode, oa, 2, id, FALSE);
  Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, sa, id)
END EmitFarCallTo;

(* Build the entry stub into the caller-owned, already-open TEMP file `mainRdf`
   (the caller owns Close — see CompileModule).  MAIN.RDF is never named on disk;
   RepackOm streams `mainRdf` straight into the .om. *)
PROCEDURE GenEntryStub(modName, procName: ARRAY OF CHAR; minPara, maxPara: LONGINT;
                       VAR mainRdf: Files.File): BOOLEAN;
  VAR obj: Rdoff.ObjFile;
      sysInitId, sysDoneId, modInitId, procId: INTEGER;
      initSym: ARRAY 66 OF CHAR;
      procSym: ARRAY 66 OF CHAR;
BEGIN
  NEW(obj);
  IF obj = NIL THEN LogErr.Error("out of memory (entry stub)"); RETURN FALSE END;
  Rdoff.RdfInit(obj);
  IF LogErr.HaveErr() THEN DISPOSE(obj); RETURN FALSE END;
  sysInitId := Rdoff.RdfAddImport(obj, "SYSTEM_INIT");
  sysDoneId := Rdoff.RdfAddImport(obj, "SYSTEM_DONE");
  Strings.Copy(modName, initSym); Strings.Append("__init", initSym);
  modInitId := Rdoff.RdfAddImport(obj, initSym);
  Strings.Copy(modName, procSym); Strings.Append("_", procSym);
  Strings.Append(procName, procSym);
  procId := Rdoff.RdfAddImport(obj, procSym);
  Rdoff.RdfAddGlobal(obj, "start", BYTE(Rdoff.SegCode), LONGINT(0));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0B8H));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(minPara MOD LONGINT(256)));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE((minPara DIV LONGINT(256)) MOD LONGINT(256)));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(0BBH));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(maxPara MOD LONGINT(256)));
  Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE((maxPara DIV LONGINT(256)) MOD LONGINT(256)));
  EmitFarCallTo(obj, sysInitId);
  EmitFarCallTo(obj, modInitId);
  EmitFarCallTo(obj, procId);
  EmitFarCallTo(obj, sysDoneId);
  Rdoff.RdfWriteTo(obj, mainRdf);
  Rdoff.RdfFree(obj);
  DISPOSE(obj);              (* release the ObjFile record + its file buffers *)
  RETURN ~LogErr.HaveErr()
END GenEntryStub;

PROCEDURE FormatStackSize(n: LONGINT; VAR dst: ARRAY OF CHAR; VAR len: INTEGER);
  VAR digits: ARRAY 16 OF CHAR; ndig, i: INTEGER;
BEGIN
  ndig := 0;
  IF n = LONGINT(0) THEN digits[0] := "0"; ndig := 1
  ELSE
    WHILE n > LONGINT(0) DO
      digits[ndig] := CHR(ORD("0") + INTEGER(n MOD LONGINT(10)));
      n := n DIV LONGINT(10); INC(ndig)
    END
  END;
  i := 0;
  WHILE i < ndig DO dst[i] := digits[ndig - 1 - i]; INC(i) END;
  dst[i] := 0AX; INC(i); dst[i] := 0X; len := i
END FormatStackSize;

(* Stream the entry-stub temp `mainRdf` (built by GenEntryStub) into the .om as
   member "MAIN.RDF".  The caller (CompileModule) owns Close of `mainRdf`. *)
PROCEDURE RepackOm(modName: ARRAY OF CHAR; stackSize: LONGINT;
                   VAR mainRdf: Files.File): BOOLEAN;
  VAR libName: ARRAY 40 OF CHAR;
      lf: Files.File;
      stackTxt: ARRAY 24 OF CHAR; stackLen: INTEGER;
      endBuf: ARRAY 512 OF BYTE;
      omSize: LONGINT; k: INTEGER; endOk: BOOLEAN;
BEGIN
  MakeOmName(modName, libName);
  IF ~Files.Reset(lf, libName) THEN
    LogErr.Error2("oc: /ENTRY=: cannot reopen ", libName);
    RETURN FALSE
  END;
  (* Validate the archive tail before overwriting it: a well-formed .om ends
     with TWO all-zero 512-byte end blocks.  Blind-seeking Size-1024 on a
     truncated/corrupt archive would append MAIN.RDF over live member data
     and silently produce a corrupt .om. *)
  omSize := Files.Size(lf);
  endOk := omSize >= LONGINT(1024);
  IF endOk THEN
    Files.Seek(lf, omSize - LONGINT(1024));
    IF Files.BlockRead(lf, endBuf[0], 512) # WORD(512) THEN endOk := FALSE END;
    k := 0;
    WHILE endOk & (k < 512) DO
      IF endBuf[k] # BYTE(0) THEN endOk := FALSE END;
      INC(k)
    END
  END;
  IF ~endOk THEN
    Files.Close(lf);
    LogErr.Error2("oc: /ENTRY=: malformed .om (missing end blocks): ", libName);
    RETURN FALSE
  END;
  Files.Seek(lf, omSize - LONGINT(1024));
  Files.Seek(mainRdf, LONGINT(0));
  Tar.TarAddFromFile(lf, "MAIN.RDF", mainRdf, Files.Size(mainRdf));
  IF stackSize > LONGINT(0) THEN
    FormatStackSize(stackSize, stackTxt, stackLen);
    Tar.TarAddFile(lf, "META-INF/STACK.TXT", stackTxt, stackLen)
  END;
  Tar.TarEnd(lf);
  Files.Close(lf);
  IF ~Files.Ok(lf) THEN
    LogErr.Error2("oc: /ENTRY=: write error (disk full?) on ", libName);
    RETURN FALSE
  END;
  RETURN TRUE
END RepackOm;

(* ---- compile one module ---- *)

PROCEDURE DbgMemSize(umsg : ARRAY OF CHAR);
VAR msg : ARRAY 512 OF CHAR;
    am  : WORD;
BEGIN
  IF ~LogErr.IsDebug() THEN RETURN END;
  am := SYSTEM.MemAvail();
  Strings.Copy(umsg, msg);
  Strings.Append(" Free memory ", msg);
  Strings.AppendInt(LONGINT(am), msg);
  Strings.Append(" paragraphs / ", msg);
  Strings.AppendInt(LONGINT(am)*16 DIV 1024, msg);
  Strings.Append("kb", msg);
  LogErr.Debug(msg)
END DbgMemSize;

PROCEDURE LeakGuard(memBefore : WORD; module, subPart : ARRAY OF CHAR);
VAR memAfter: WORD;
    msg : ARRAY 512 OF CHAR;
BEGIN
  memAfter := SYSTEM.MemAvail();
  IF (memAfter < memBefore) THEN
    (* ZERO HEAP LEAKS is a KEY RULE (CLAUDE.md): a leak is a bug to fix, so
       the report must be visible at the DEFAULT log level, not gated behind
       /LOG=debug (where regressions went unseen). *)
    Strings.Copy("oc: WARNING: heap leak compiling ", msg);
    Strings.Append(module, msg);
    Strings.Append(subPart, msg);
    Strings.Append(" (", msg);
    Strings.AppendInt(LONGINT(memBefore - memAfter), msg);
    Strings.Append(" paragraphs)", msg);
    LogErr.Warn(msg)
  END
END LeakGuard;

(* Debug metric: total on-disk size of the file-backed module table (gModFile),
   i.e. modCount * RecLen.  Printed once the dep-scan has fixed modCount, so a
   DEBUG-level run reports exactly how many bytes the whole build's ModRecs
   occupy (relevant to the FindMod O(n) linear-scan cost: each FindMod call
   walks up to this many bytes via Seek+BlockRead). *)
PROCEDURE DbgModTableSize;
VAR msg : ARRAY 128 OF CHAR;
BEGIN
  IF ~LogErr.IsDebug() THEN RETURN END;
  Strings.Copy("ModRec table: modCount=", msg);
  Strings.AppendInt(LONGINT(modCount), msg);
  Strings.Append(" recLen=", msg);
  Strings.AppendInt(LONGINT(RecLen), msg);
  Strings.Append(" totalBytes=", msg);
  Strings.AppendInt(LONGINT(modCount) * LONGINT(RecLen), msg);
  LogErr.Debug(msg)
END DbgModTableSize;

PROCEDURE CompileModule(srcPath, entryProc: ARRAY OF CHAR;
                        isRoot, hasSystem: BOOLEAN);
  VAR sc: Scan.Scanner;
      memBefore: WORD;
      mainRdf: Files.File;
BEGIN
  memBefore := SYSTEM.MemAvail();
  Parser.parserSystemMode := hasSystem;
  (* The /ENTRY= procedure lives in the ROOT module only.  Passing it to a
     dependency module's parse would make Parser's entry-proc validation fail
     ("/ENTRY= procedure not found") when that dependency lacks the proc. *)
  IF isRoot THEN Strings.Copy(entryProc, Parser.parserEntryProc)
  ELSE Parser.parserEntryProc := "" END;
  LeakGuard(memBefore, srcPath, " in init");
  Scan.Open(sc, srcPath);
  Parser.ParseModule(sc);
  DbgMemSize("Module compiled.");
  (* Closing through OUR copy of the Scanner is safe even though ParseModule
     advanced its own copy (PExpr.sc): the scanner is read-only, so there is
     nothing to flush, and both copies share the one heap buffer/handle —
     see the aliasing-invariant note at the top of Parser.ParseModule. *)
  Scan.Close(sc);
  Cgen.CgFree();
  LeakGuard(memBefore, srcPath, " in Cgen.CgFree()");
  IF LogErr.HaveErr() THEN RETURN END;
  IF isRoot & (entryProc[0] # 0X) THEN
    memBefore := SYSTEM.MemAvail();
    (* mainRdf temp is opened, written, streamed and closed entirely within this
       one LeakGuard window so the open buffer never looks like a leak. *)
    IF ~Files.ReWriteTemp(mainRdf) THEN
      LogErr.Error("oc: /ENTRY=: cannot create MAIN.RDF temp");
      LeakGuard(memBefore, srcPath, " in GenEntryStub"); RETURN
    END;
    IF ~GenEntryStub(Parser.parserModName, entryProc,
                 Parser.parserMinMemPara, Parser.parserMaxMemPara, mainRdf) THEN
      Files.Close(mainRdf);
      LeakGuard(memBefore, srcPath, " in GenEntryStub"); RETURN
    END;
    IF ~RepackOm(Parser.parserModName, Parser.parserStackSize, mainRdf) THEN
      Files.Close(mainRdf);
      LeakGuard(memBefore, srcPath, " in RepackOm"); RETURN
    END;
    Files.Close(mainRdf);
    LeakGuard(memBefore, srcPath, " in RepackOm")
  END
END CompileModule;

(* ---- link phase ---- *)

PROCEDURE LinkAll(outExe: ARRAY OF CHAR; genDebug: BOOLEAN);
  VAR ls: Link.State; m: ModEntry; mr: ModRec;
      pos, dlen: INTEGER;
      omPath: ARRAY MaxPath OF CHAR;
      p: ARRAY 512 OF CHAR;
      dir: ARRAY MaxPath OF CHAR;
      omExe: ARRAY MaxPath OF CHAR;
      memBefore: WORD;
BEGIN
  (* The module graph lives entirely in gModFile (never in the heap), so the
     arena is contiguous here.  Reserve the two fixed 65000-byte link buffers
     NOW — before the module scan opens each .rdf through an 8 KB Files buffer and
     fragments the arena so no 65000-byte hole survives. *)
  DbgMemSize("Linker, before init state.");
  NEW(ls);
  DbgMemSize("Linker, after init state.");
  IF ls = NIL THEN LogErr.Error("out of memory (link state)"); RETURN END;
  Link.InitState(ls);
  ls^.genDebug := genDebug;   (* /G: emit the TDS debug block into the .exe *)
  IF ~Link.ReserveBuffers(ls) THEN
    Link.LinkFree(ls); DISPOSE(ls); RETURN   (* LogErr latched by ReserveBuffers *)
  END;

  (* Load source modules in topo order (deepest deps first), walking the in-file
     sortNext chain.  A latched read/parse error stops the load. *)
  m := gSortHead;
  WHILE (m # NoMod) & ~LogErr.HaveErr() DO
     DbgMemSize("Linker load module.");
     ModRead(m, mr);
    IF HasFlag(mr, FlagHasSrc) THEN
      MakeOmName(mr.name, omPath);
      Link.ProcessFile(ls, omPath)
    END;
    m := mr.sortNext
  END;

  Dos.GetEnv("OBERON_LIB", p);
  pos := 0;
  WHILE p[pos] # 0X DO
    dlen := 0;
    WHILE (p[pos] # 0X) & (p[pos] # ";") & (dlen < MaxPath - 1) DO
      dir[dlen] := p[pos]; INC(dlen); INC(pos)
    END;
    dir[dlen] := 0X;
    IF p[pos] = ";" THEN INC(pos) END;
    Import.NormalizeSlashes(dir);
    IF (dlen > 0) & Files.FileExists(dir) & Tar.IsOmFile(dir) THEN
      Link.ProcessFile(ls, dir)
    END
  END;

  (* Load OBERON.OM: Link.FindFile already searches CWD then the running
     exe's directory (same two locations the old hand-assembled fallback
     covered), returning whichever path exists (or the bare name if neither
     does, in which case IsOmFile below correctly rejects it). *)

  Link.FindFile("OBERON.OM", omExe);
  IF Files.FileExists(omExe) & Tar.IsOmFile(omExe) THEN
    Link.ProcessFile(ls, omExe)
  END;

  DbgMemSize("Linker has been load all modules");

  memBefore := SYSTEM.MemAvail();
  IF ~LogErr.HaveErr() THEN Link.SmartLink(ls) END;
  LeakGuard(memBefore, "link", " in SmartLink");
  memBefore := SYSTEM.MemAvail();
  IF ~LogErr.HaveErr() THEN Link.ReadStackSize(ls) END;
  LeakGuard(memBefore, "link", " in ReadStackSize");
  memBefore := SYSTEM.MemAvail();
  IF ~LogErr.HaveErr() THEN Link.CalculateLayout(ls) END;
  LeakGuard(memBefore, "link", " in CalculateLayout");
  DbgMemSize("Linker, after calculate layouts.");
  memBefore := SYSTEM.MemAvail();
  IF ~LogErr.HaveErr() THEN Link.PerformLinking(ls) END;
  DbgMemSize("Linker, after linking, before write .exe");
  memBefore := SYSTEM.MemAvail();
  IF ~LogErr.HaveErr() THEN Link.WriteExe(ls, outExe) END;
  LeakGuard(memBefore, "link", " in WriteExe");
  Link.LinkFree(ls);
  DISPOSE(ls);
  IF LogErr.HaveErr() THEN
    Files.Delete(outExe)    (* never leave a half-written .exe behind *)
  END
END LinkAll;

(* ---- main entry point ---- *)

PROCEDURE RunSystemMode(srcFile, entryProc: ARRAY OF CHAR);
  VAR sc: Scan.Scanner;
BEGIN
  Parser.parserSystemMode := TRUE;
  Strings.Copy(entryProc, Parser.parserEntryProc);
  Scan.Open(sc, srcFile);
  Parser.ParseModule(sc);
  Scan.Close(sc);
  Cgen.CgFree()
  (* error (if any) is latched in LogErr; the caller checks LogErr.HaveErr() *)
END RunSystemMode;

(* Idempotent cleanup run before the single SYSTEM.Halt in Run, on every exit
   path (success or error).  Guarantees no open temp file or held heap survives:
   FreeMods closes/deletes the module-graph temp; CgFree releases the code-gen
   ObjFile + its RDFCODE/RDFDATA temps; SymsFree closes the symbol/type temps.
   Each underlying free is itself guarded (gModOpen / CgObj # NIL / symOpen), so
   calling Cleanup twice or after a partial run is safe. *)
PROCEDURE Cleanup;
BEGIN
  FreeMods;
  Cgen.CgFree();
  Syms.SymsFree()
END Cleanup;

(* Body of the driver: returns the process exit code (0 = ok, 1 = error).  ALL
   error paths return a code here; the ONLY SYSTEM.Halt lives in Run, after
   Cleanup.  This is the single-Halt rule: no module below may abort the
   process — they latch/return errors that funnel here. *)
PROCEDURE RunBody(): INTEGER;
  VAR argc, i : INTEGER;
      mainMod, m: ModEntry;
      mr: ModRec;
      arg: ARRAY 128 OF CHAR;
      srcFile: ARRAY 128 OF CHAR;
      outExe:  ARRAY 128 OF CHAR;
      entryProc: ARRAY NameLen OF CHAR;
      logLevel: ARRAY NameLen OF CHAR;
      hasEntry, hasSystem, force, genDbg: BOOLEAN;
      stem: ARRAY NameLen OF CHAR;
      omPath: ARRAY MaxPath OF CHAR;
      memBefore, k: WORD;
BEGIN
  LogErr.SetLevel(LogErr.LINFO);
  argc := Dos.ParamCount();
  IF argc < 1 THEN
    Out.String("Trubo Oberon (c) 2026 DosWorld, Public domain (unlicense)"); Out.Ln;
    Out.Ln;
    Out.String("usage: TOC [/ENTRY=Proc] [/SYSTEM] [/M] [/G] [/LOG=level] <file.Mod>"); Out.Ln;
    Out.String("  /ENTRY=Proc  compile + link: build <file.Mod> and all its"); Out.Ln;
    Out.String("               imports, then link an .EXE whose entry point"); Out.Ln;
    Out.String("               calls the exported procedure Proc. Without"); Out.Ln;
    Out.String("               /ENTRY=, only .om files are produced (no link)."); Out.Ln;
    Out.String("  /SYSTEM      compile the SYSTEM module itself (no implicit"); Out.Ln;
    Out.String("               SYSTEM import, no dep-scan)."); Out.Ln;
    Out.String("  /M           rebuild imported modules whose source is newer"); Out.Ln;
    Out.String("               than their .om (checked via file timestamps)."); Out.Ln;
    Out.String("               Without /M, an import is only rebuilt if its"); Out.Ln;
    Out.String("               .om is missing or empty. The module named on"); Out.Ln;
    Out.String("               the command line is always rebuilt either way."); Out.Ln;
    Out.String("  /G           append a Turbo-Debugger (TDS/TDINFO) debug-info"); Out.Ln;
    Out.String("               block to the linked .EXE, merged from every"); Out.Ln;
    Out.String("               module compiled with (*$D+*). Requires /ENTRY=."); Out.Ln;
    Out.String("  /LOG=level   set diagnostic verbosity: debug, info (default),"); Out.Ln;
    Out.String("               warn, or error. Case-insensitive."); Out.Ln;
    LogErr.Error("missing <file.Mod> argument");
    RETURN 1
  END;

  srcFile[0] := 0X; outExe[0] := 0X; entryProc[0] := 0X;
  hasEntry := FALSE; hasSystem := FALSE; force := FALSE; genDbg := FALSE;
  i := 1;
  WHILE i <= argc DO
    Dos.ParamStr(i, arg);
    IF MatchSwitchVal(arg, "/ENTRY=", entryProc) THEN
      hasEntry := TRUE
    ELSIF MatchSwitchVal(arg, "/LOG=", logLevel) THEN
      IF Strings.EqualICase(logLevel, "debug") THEN LogErr.SetLevel(LogErr.LDEBUG)
      ELSIF Strings.EqualICase(logLevel, "info") THEN LogErr.SetLevel(LogErr.LINFO)
      ELSIF Strings.EqualICase(logLevel, "warn") THEN LogErr.SetLevel(LogErr.LWARN)
      ELSIF Strings.EqualICase(logLevel, "error") THEN LogErr.SetLevel(LogErr.LERROR)
      ELSE
        LogErr.Error2("oc: /LOG=: unknown level (want debug/info/warn/error) ", logLevel);
        RETURN 1
      END
    ELSIF Strings.EqualICase(arg, "/SYSTEM") THEN
      hasSystem := TRUE
    ELSIF Strings.EqualICase(arg, "/M") THEN
      force := TRUE
    ELSIF Strings.EqualICase(arg, "/G") THEN
      genDbg := TRUE
    ELSIF (arg[0] # "/") & (arg[0] # "-") THEN
      IF srcFile[0] = 0X THEN Strings.Copy(arg, srcFile) END
    ELSE
      LogErr.Error2("oc: unknown option ", arg);
      RETURN 1
    END;
    INC(i)
  END;

  IF srcFile[0] = 0X THEN
    LogErr.Error("oc: no source file");
    RETURN 1
  END;

  (* /SYSTEM: single-file compile only, no dep-scan or link *)
  IF hasSystem THEN
    RunSystemMode(srcFile, entryProc);
    IF LogErr.HaveErr() THEN RETURN 1 ELSE RETURN 0 END
  END;

  (* Open the file-backed module table for the whole compile→link cycle. *)
  IF ~OpenModFile() THEN RETURN 1 END;

  (* Determine if input is a filename or module name *)
  k := 0;
  IF Strings.Pos(".", srcFile, k) THEN
    BaseStem(srcFile, stem);
    mainMod := AddMod(stem);
    ModRead(mainMod, mr);
    Strings.Copy(srcFile, mr.srcPath);
    SetFlag(mr, FlagHasSrc)
  ELSE
    mainMod := AddMod(srcFile);
    ModRead(mainMod, mr);
    IF ~FindSrc(srcFile, mr.srcPath) THEN
      LogErr.Error2("oc: cannot find source for: ", srcFile);
      RETURN 1
    END;
    SetFlag(mr, FlagHasSrc)
  END;
  SetFlag(mr, FlagIsMain);
  ModWrite(mainMod, mr);

  (* Default output exe from root module name *)
  IF hasEntry & (outExe[0] = 0X) THEN
    Strings.Copy(mr.name, outExe);
    Strings.Append(".EXE", outExe);
    SYSTEM.UPSTR(outExe)
  END;

  (* Phase 1: dependency scan *)
  ScanDeps(mainMod);
  TopoSort;
  DbgModTableSize;

  memBefore := SYSTEM.MemAvail();
  (* Phase 2: compile stale modules in topo order (walk the in-file sortNext chain).
     A latched error (LogErr.HaveErr) stops the whole compile at once. *)
  m := gSortHead;
  WHILE (m # NoMod) & ~LogErr.HaveErr() DO
    ModRead(m, mr);
    IF HasFlag(mr, FlagHasSrc) THEN
      MakeOmName(mr.name, omPath);
      (* Root module with /ENTRY= always recompiled to (re)pack MAIN.RDF.
         /M does not force every module — it switches imported modules from
         "missing/zero-size only" staleness to "missing/zero-size OR source
         newer than .om" (checked via Files.GetFTime through IsStale). *)
      IF IsStale(omPath, mr.srcPath, force) OR (HasFlag(mr, FlagIsMain) & hasEntry) THEN
        (* Memory-leak guard: a module compile must release everything it
           allocated (SymsFree + CgFree).  Capture free heap before/after; if it
           drops, the compile leaked — warn (non-fatal) with the module name and
           the paragraph delta so a regression is caught immediately. *)
        CompileModule(mr.srcPath, entryProc, HasFlag(mr, FlagIsMain) & hasEntry, FALSE)
      END
    END;
    m := mr.sortNext
  END;
  LeakGuard(memBefore, "all module(s)", "");

  IF LogErr.HaveErr() THEN RETURN 1 END;

  (* Phase 3: link when /ENTRY= given.  The module graph already lives in
     gModFile (never in the heap), so the arena is contiguous for the linker's
     code-group buffer — no defrag round-trip is needed. *)
  IF hasEntry THEN
    memBefore := SYSTEM.MemAvail();
    LinkAll(outExe, genDbg);
    FreeMods;             (* close + delete the module-graph temp after linking *)
    (* LinkAll's own symbol table now interns names via StrTab (LINK.MOD's
       SymRec.nameId refactor) — those names are never referenced again once
       linking is done (Phase 2 compile, the table's only other user, already
       finished before Phase 3 link began), so release them here rather than
       waiting for the process-wide Syms.SymsFree() in Cleanup.  Without this,
       the leak checkpoint below sees them as still-allocated and reports a
       false-positive leak even though Cleanup frees them moments later (see
       the "whole run" LeakGuard in Run, which stays clean either way). *)
    StrTab.Reset;
    LeakGuard(memBefore, "link all module(s)", "");
    IF LogErr.HaveErr() THEN RETURN 1 END
  ELSE
    FreeMods              (* compile-only: still release the graph *)
  END;
  RETURN 0
END RunBody;

PROCEDURE Run*;
  VAR exitCode: INTEGER; memBefore: WORD;
BEGIN
  LogErr.Open;               (* open output.log / error.log for this run *)
  memBefore := SYSTEM.MemAvail();
  exitCode := RunBody();
  Cleanup;                (* close every temp + free heap on EVERY exit path *)
  LeakGuard(memBefore, "whole run", "");
  LogErr.Close;              (* flush + close the log files *)
  SYSTEM.Halt(exitCode)   (* the ONE and ONLY SYSTEM.Halt in the compiler *)
END Run;

END TOC.
