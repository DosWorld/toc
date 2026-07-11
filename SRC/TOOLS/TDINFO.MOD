MODULE TDInfo;
(*
  TDInfo — reader/inspector for the Borland Turbo-Debugger (TDS/TDINFO v2.08)
  debug-info block that `oc /G` appends to a linked `.EXE`.

  Oberon-07 port of docs/tdinfo.c with FULL section parity: header counts,
  symbols (with type index + class name), modules, source files, line numbers,
  scopes, segments (with module names + scope links), correlations, types
  (with TYPE_ID names), members, and the names pool listing.

  Where docs/tdinfo.c is STALE for v2.08 this reader uses the probe-verified
  layouts instead (docs/td-spec.md §EMPIRICAL):
    SOURCE_FILE_RECORD = name index + DOS time + DOS date  (no segment field)
    LINE_NUMBER_RECORD = (line, offset) — line word FIRST
  (the C tool prints garbage for both sections on a real v2.08 file).

  Tool DATA goes to stdout (Out); diagnostics go via LogErr (matches rdfgrep).
  Chunk small records (KEY RULE): symbols/lines/types/members/scopes are read
  into chunked node lists; modules/source-files/segments/correlations are few
  (small fixed cap).

  Exit codes: 0 ok, 2 usage, 3 I/O / parse error.
*)
IMPORT Out, Dos, Files, LogErr;

CONST
  Magic     = 052FBH;   (* on disk: bytes FB 52 -> little-endian word 0x52FB *)
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;

  SymChunk   = 64;
  LineChunk  = 128;
  TypeChunk  = 64;
  MembChunk  = 64;
  ScopeChunk = 32;
  NameLen    = 64;
  MaxMod     = 128;   (* caps: modules / source files / segments / correlations *)
  MaxSrc     = 128;
  MaxSeg     = 128;
  MaxCorr    = 128;

  (* on-disk record sizes (bytes) *)
  SzSym  = 9;  SzMod = 16; SzSrc = 6;  SzLine = 4;
  SzScope = 12; SzSeg = 16; SzCorr = 8; SzType = 8; SzMember = 5;

TYPE
  Header = RECORD
    magic:              INTEGER;
    minorVer, majorVer: BYTE;
    namesPoolSize:      LONGINT;
    namesCount, typesCount, membersCount, symbolsCount, globalsCount,
    modulesCount, localsCount, scopesCount, lineNumbersCount,
    sourceFilesCount, segmentsCount, correlationsCount: INTEGER;
    extensionSize:      INTEGER
  END;

  SymNode = POINTER TO SymNodeDesc;
  SymNodeDesc = RECORD
    index, typ, offset, segment: ARRAY SymChunk OF INTEGER;
    bitfield: ARRAY SymChunk OF BYTE;
    count: INTEGER; next: SymNode
  END;

  LineNode = POINTER TO LineNodeDesc;
  LineNodeDesc = RECORD
    offset, line: ARRAY LineChunk OF INTEGER;
    count: INTEGER; next: LineNode
  END;

  TypeNode = POINTER TO TypeNodeDesc;
  TypeNodeDesc = RECORD
    id, classT:        ARRAY TypeChunk OF BYTE;
    name, size, membT: ARRAY TypeChunk OF INTEGER;
    count: INTEGER; next: TypeNode
  END;

  MembNode = POINTER TO MembNodeDesc;
  MembNodeDesc = RECORD
    info:      ARRAY MembChunk OF BYTE;
    name, typ: ARRAY MembChunk OF INTEGER;
    count: INTEGER; next: MembNode
  END;

  ScopeNode = POINTER TO ScopeNodeDesc;
  ScopeNodeDesc = RECORD
    symFirst, symCnt, parent, func, ofs, len: ARRAY ScopeChunk OF INTEGER;
    count: INTEGER; next: ScopeNode
  END;

VAR
  symHead, symTail:     SymNode;
  lineHead, lineTail:   LineNode;
  typeHead, typeTail:   TypeNode;
  membHead, membTail:   MembNode;
  scopeHead, scopeTail: ScopeNode;
  modName:  ARRAY MaxMod OF INTEGER;                 (* name index per module *)
  srcName, srcTime, srcDate: ARRAY MaxSrc OF INTEGER;
  segMod, segSeg, segOfs, segLen, segScIx, segScCnt: ARRAY MaxSeg OF INTEGER;
  corrSrc, corrSeg, corrMod, corrFlags: ARRAY MaxCorr OF INTEGER;
  pool:    POINTER TO ARRAY OF CHAR;
  poolLen: LONGINT;

PROCEDURE Usage;
BEGIN
  Out.String("usage: tdinfo FILE.EXE"); Out.Ln;
  Out.String("  Locate + dump the TDINFO (0x52FB) debug block in a linked .EXE."); Out.Ln
END Usage;

(* Files.ReadWord yields a signed INTEGER; reinterpret as unsigned 0..65535. *)
PROCEDURE UW(w: INTEGER): LONGINT;
BEGIN RETURN LONGINT(w) MOD LONGINT(65536)
END UW;

PROCEDURE WHex4(v: INTEGER);
  VAR h: ARRAY 8 OF CHAR; i, d: INTEGER; u: LONGINT;
BEGIN
  u := UW(v);
  FOR i := 3 TO 0 BY -1 DO
    d := INTEGER(u MOD 16); u := u DIV 16;
    IF d < 10 THEN h[i] := CHR(ORD("0") + d) ELSE h[i] := CHR(ORD("A") + d - 10) END
  END;
  h[4] := 0X; Out.String(h)
END WHex4;

PROCEDURE WHex2(b: BYTE);
  VAR h: ARRAY 4 OF CHAR; d: INTEGER;
BEGIN
  d := INTEGER(b) DIV 16;
  IF d < 10 THEN h[0] := CHR(ORD("0") + d) ELSE h[0] := CHR(ORD("A") + d - 10) END;
  d := INTEGER(b) MOD 16;
  IF d < 10 THEN h[1] := CHR(ORD("0") + d) ELSE h[1] := CHR(ORD("A") + d - 10) END;
  h[2] := 0X; Out.String(h)
END WHex2;

(* Unsigned decimal of a 16-bit word. *)
PROCEDURE WUns(v: INTEGER);
BEGIN Out.Int(UW(v), 0)
END WUns;

PROCEDURE W2(v: INTEGER);
BEGIN
  IF v < 10 THEN Out.String("0") END; Out.Int(v, 0)
END W2;

(* Decode a DOS packed date/time word pair, e.g. " (2026-07-03 09:38:50)". *)
PROCEDURE WriteStamp(date, time: INTEGER);
  VAR d, t: LONGINT;
BEGIN
  d := UW(date); t := UW(time);
  Out.String(" (");
  Out.Int(INTEGER(d DIV 512) + 1980, 0); Out.String("-");
  W2(INTEGER((d DIV 32) MOD 16)); Out.String("-"); W2(INTEGER(d MOD 32));
  Out.String(" ");
  W2(INTEGER(t DIV 2048)); Out.String(":");
  W2(INTEGER((t DIV 32) MOD 64)); Out.String(":");
  W2(INTEGER((t MOD 32) * 2));
  Out.String(")")
END WriteStamp;

PROCEDURE GetName(index: INTEGER; VAR dst: ARRAY OF CHAR);
  VAR p: LONGINT; k: INTEGER; idx, i: LONGINT;
BEGIN
  dst[0] := 0X;
  idx := UW(index);
  IF (idx = LONGINT(0)) OR (pool = NIL) THEN RETURN END;
  p := LONGINT(0); i := LONGINT(1);
  WHILE (i < idx) & (p < poolLen) DO
    WHILE (p < poolLen) & (pool[p] # 0X) DO INC(p) END;
    INC(p); INC(i)
  END;
  IF p >= poolLen THEN RETURN END;
  k := 0;
  WHILE (p < poolLen) & (pool[p] # 0X) & (k < LEN(dst) - 1) DO
    dst[k] := pool[p]; INC(k); INC(p)
  END;
  dst[k] := 0X
END GetName;

(* Print name padded to `width` columns (name printed fully if longer). *)
PROCEDURE WPad(VAR name: ARRAY OF CHAR; width: INTEGER);
  VAR k: INTEGER;
BEGIN
  Out.String(name);
  k := 0; WHILE name[k] # 0X DO INC(k) END;
  WHILE k < width DO Out.String(" "); INC(k) END
END WPad;

(* symbol class 0..7 -> name *)
PROCEDURE WClass(cls: INTEGER);
BEGIN
  IF    cls = 0 THEN Out.String("STATIC")
  ELSIF cls = 1 THEN Out.String("ABSOLUTE")
  ELSIF cls = 2 THEN Out.String("AUTO")
  ELSIF cls = 3 THEN Out.String("PASCAL_VAR")
  ELSIF cls = 4 THEN Out.String("REGISTER")
  ELSIF cls = 5 THEN Out.String("CONSTANT")
  ELSIF cls = 6 THEN Out.String("TYPEDEF")
  ELSE Out.String("STRUCT_UNION_OR_ENUM")
  END
END WClass;

(* TYPE_RECORD id -> mnemonic (docs/tdinfo.c type_id_names) *)
PROCEDURE WTypeId(id: INTEGER);
BEGIN
  IF    id =  0 THEN Out.String("VOID")
  ELSIF id =  1 THEN Out.String("LSTR")
  ELSIF id =  2 THEN Out.String("DSTR")
  ELSIF id =  3 THEN Out.String("PSTR")
  ELSIF id =  4 THEN Out.String("SCHAR")
  ELSIF id =  5 THEN Out.String("SINT")
  ELSIF id =  6 THEN Out.String("SLONG")
  ELSIF id =  8 THEN Out.String("UCHAR")
  ELSIF id =  9 THEN Out.String("UINT")
  ELSIF id = 10 THEN Out.String("ULONG")
  ELSIF id = 12 THEN Out.String("PCHAR")
  ELSIF id = 13 THEN Out.String("FLOAT")
  ELSIF id = 14 THEN Out.String("TPREAL")
  ELSIF id = 15 THEN Out.String("DOUBLE")
  ELSIF id = 16 THEN Out.String("LDOUBLE")
  ELSIF id = 17 THEN Out.String("BCD4")
  ELSIF id = 18 THEN Out.String("BCD8")
  ELSIF id = 19 THEN Out.String("BCD10")
  ELSIF id = 20 THEN Out.String("BCDCOB")
  ELSIF id = 21 THEN Out.String("NEAR")
  ELSIF id = 22 THEN Out.String("FAR")
  ELSIF id = 23 THEN Out.String("SEG")
  ELSIF id = 24 THEN Out.String("NEAR386")
  ELSIF id = 25 THEN Out.String("FAR386")
  ELSIF id = 26 THEN Out.String("ARRAY")
  ELSIF id = 28 THEN Out.String("PARRAY")
  ELSIF id = 30 THEN Out.String("STRUCT")
  ELSIF id = 31 THEN Out.String("UNION")
  ELSIF id = 34 THEN Out.String("ENUM")
  ELSIF id = 35 THEN Out.String("FUNCTION")
  ELSIF id = 36 THEN Out.String("LABEL")
  ELSIF id = 37 THEN Out.String("SET")
  ELSIF id = 38 THEN Out.String("TFILE")
  ELSIF id = 39 THEN Out.String("BFILE")
  ELSIF id = 40 THEN Out.String("BOOL")
  ELSIF id = 41 THEN Out.String("PENUM")
  ELSIF id = 44 THEN Out.String("FUNCPROTOTYPE")
  ELSIF id = 45 THEN Out.String("SPECIALFUNC")
  ELSIF id = 46 THEN Out.String("OBJECT")
  ELSIF id = 52 THEN Out.String("NREF")
  ELSIF id = 53 THEN Out.String("FREF")
  ELSIF id = 54 THEN Out.String("WORDBOOL")
  ELSIF id = 55 THEN Out.String("LONGBOOL")
  ELSE Out.String("UNKNOWN")
  END
END WTypeId;

PROCEDURE ReadHeader(VAR f: Files.File; VAR h: Header);
  VAR b: BYTE;
BEGIN
  Files.ReadWord(f, h.magic);
  IF Files.ReadByte(f, b) THEN h.minorVer := b END;
  IF Files.ReadByte(f, b) THEN h.majorVer := b END;
  Files.ReadDWord(f, h.namesPoolSize);
  Files.ReadWord(f, h.namesCount);      Files.ReadWord(f, h.typesCount);
  Files.ReadWord(f, h.membersCount);    Files.ReadWord(f, h.symbolsCount);
  Files.ReadWord(f, h.globalsCount);    Files.ReadWord(f, h.modulesCount);
  Files.ReadWord(f, h.localsCount);     Files.ReadWord(f, h.scopesCount);
  Files.ReadWord(f, h.lineNumbersCount);
  Files.ReadWord(f, h.sourceFilesCount);
  Files.ReadWord(f, h.segmentsCount);   Files.ReadWord(f, h.correlationsCount);
  Files.Seek(f, Files.Position(f) + LONGINT(14));   (* reserved[14] *)
  Files.ReadWord(f, h.extensionSize)
END ReadHeader;

PROCEDURE FreeLists;
  VAR s, sn: SymNode; l, ln: LineNode; t, tn: TypeNode;
      m, mn: MembNode; c, cn: ScopeNode;
BEGIN
  s := symHead;  WHILE s # NIL DO sn := s^.next; DISPOSE(s); s := sn END;
  l := lineHead; WHILE l # NIL DO ln := l^.next; DISPOSE(l); l := ln END;
  t := typeHead; WHILE t # NIL DO tn := t^.next; DISPOSE(t); t := tn END;
  m := membHead; WHILE m # NIL DO mn := m^.next; DISPOSE(m); m := mn END;
  c := scopeHead; WHILE c # NIL DO cn := c^.next; DISPOSE(c); c := cn END;
  symHead := NIL; symTail := NIL; lineHead := NIL; lineTail := NIL;
  typeHead := NIL; typeTail := NIL; membHead := NIL; membTail := NIL;
  scopeHead := NIL; scopeTail := NIL
END FreeLists;

(* Name of module m (1-based module index) into nm; "" when out of range. *)
PROCEDURE ModuleName(m, mc: INTEGER; VAR nm: ARRAY OF CHAR);
BEGIN
  nm[0] := 0X;
  IF (m >= 1) & (m <= mc) & (m <= MaxMod) THEN GetName(modName[m - 1], nm) END
END ModuleName;

(* Body of tdinfo: returns the process exit code.  ALL error paths return a
   code here; the ONLY SYSTEM.Halt lives in Run. *)
PROCEDURE RunBody(): INTEGER;
  VAR f: Files.File; path: ARRAY 128 OF CHAR;
      fileSize, off, imgSize: LONGINT; w: INTEGER; found: BOOLEAN;
      h: Header; i, j, cnt, mc, sc, gc, cc, cls: INTEGER;
      b: BYTE;
      name: ARRAY NameLen OF CHAR;
      nm2:  ARRAY NameLen OF CHAR;
      sn: SymNode; ln: LineNode; tn: TypeNode; mn: MembNode; cn: ScopeNode;
      p: LONGINT;
BEGIN
  symHead := NIL; symTail := NIL; lineHead := NIL; lineTail := NIL;
  typeHead := NIL; typeTail := NIL; membHead := NIL; membTail := NIL;
  scopeHead := NIL; scopeTail := NIL;
  pool := NIL; poolLen := 0;

  IF Dos.ParamCount() < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, path);
  IF ~Files.Reset(f, path) THEN LogErr.Error2("tdinfo: cannot open ", path); RETURN ExitIo END;
  fileSize := Files.Size(f);

  (* Locate the block.  Method A (preferred): the TDS block starts exactly at
     the MZ image end — image_size from e_cp/e_cblp; also try the 16-aligned
     round-up (td-spec §LOCATING).  Method B (fallback): forward byte scan —
     can false-positive on FB 52 inside code, so it is only the fallback. *)
  found := FALSE; off := LONGINT(0);
  Files.Seek(f, LONGINT(0)); Files.ReadWord(f, w);
  IF w = 5A4DH THEN                                        (* "MZ" *)
    Files.ReadWord(f, w); imgSize := UW(w);                (* e_cblp *)
    IF imgSize = LONGINT(0) THEN imgSize := LONGINT(512) END;
    Files.ReadWord(f, w);                                  (* e_cp *)
    imgSize := (UW(w) - LONGINT(1)) * LONGINT(512) + imgSize;
    IF imgSize + LONGINT(2) <= fileSize THEN
      Files.Seek(f, imgSize); Files.ReadWord(f, w);
      IF w = Magic THEN found := TRUE; off := imgSize END
    END;
    IF ~found THEN                                         (* paragraph round-up *)
      imgSize := (imgSize + LONGINT(15)) DIV LONGINT(16) * LONGINT(16);
      IF imgSize + LONGINT(2) <= fileSize THEN
        Files.Seek(f, imgSize); Files.ReadWord(f, w);
        IF w = Magic THEN found := TRUE; off := imgSize END
      END
    END
  END;
  WHILE (~found) & (off < fileSize - LONGINT(1)) DO
    Files.Seek(f, off); Files.ReadWord(f, w);
    IF w = Magic THEN found := TRUE ELSE off := off + LONGINT(1) END
  END;
  IF ~found THEN
    LogErr.Error("tdinfo: TDINFO signature (0x52FB) not found");
    Files.Close(f); RETURN ExitIo
  END;

  Out.String("TDINFO at offset 0x"); WHex4(INTEGER(off)); Out.Ln;
  Files.Seek(f, off);
  ReadHeader(f, h);
  IF h.extensionSize # 0 THEN Files.Seek(f, Files.Position(f) + UW(h.extensionSize)) END;

  Out.String("Borland TLINK v"); Out.Int(h.majorVer, 0); Out.String(".");
  IF h.minorVer < 10 THEN Out.String("0") END; Out.Int(h.minorVer, 0);
  Out.String("  names:");   WUns(h.namesCount);
  Out.String(" types:");    WUns(h.typesCount);
  Out.String(" members:");  WUns(h.membersCount);
  Out.String(" symbols:");  WUns(h.symbolsCount);
  Out.String("(global:");   WUns(h.globalsCount); Out.String(")");
  Out.String(" modules:");  WUns(h.modulesCount);
  Out.String(" locals:");   WUns(h.localsCount);
  Out.String(" scopes:");   WUns(h.scopesCount);
  Out.String(" seg:");      WUns(h.segmentsCount);
  Out.String(" src:");      WUns(h.sourceFilesCount);
  Out.String(" lines:");    WUns(h.lineNumbersCount);
  Out.String(" corr:");     WUns(h.correlationsCount);
  Out.String(" pool:");     Out.Int(h.namesPoolSize, 0); Out.Ln;

  (* --- read arrays in on-disk order (cursor is right after the header) --- *)

  (* [1] SYMBOL_RECORD (9B) -> chunked list *)
  cnt := INTEGER(UW(h.symbolsCount)); j := 0;
  WHILE j < cnt DO
    IF (symTail = NIL) OR (symTail^.count = SymChunk) THEN
      NEW(sn); sn^.count := 0; sn^.next := NIL;
      IF symTail # NIL THEN symTail^.next := sn ELSE symHead := sn END; symTail := sn
    END;
    Files.ReadWord(f, symTail^.index[symTail^.count]);
    Files.ReadWord(f, symTail^.typ[symTail^.count]);
    Files.ReadWord(f, symTail^.offset[symTail^.count]);
    Files.ReadWord(f, symTail^.segment[symTail^.count]);
    IF ~Files.ReadByte(f, symTail^.bitfield[symTail^.count]) THEN END;
    INC(symTail^.count); INC(j)
  END;

  (* [2] MODULE_RECORD (16B): name(2) + 14 pad *)
  mc := INTEGER(UW(h.modulesCount)); j := 0;
  WHILE j < mc DO
    Files.ReadWord(f, w); IF j < MaxMod THEN modName[j] := w END;
    Files.Seek(f, Files.Position(f) + LONGINT(14)); INC(j)
  END;

  (* [3] SOURCE_FILE_RECORD (6B): file_name_index, DOS time, DOS date.
     EMPIRICAL v2.08 (DBGPROBE.EXE): NOT (segment,start,name) as tdinfo.c says. *)
  sc := INTEGER(UW(h.sourceFilesCount)); j := 0;
  WHILE j < sc DO
    Files.ReadWord(f, w); IF j < MaxSrc THEN srcName[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSrc THEN srcTime[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSrc THEN srcDate[j] := w END;
    INC(j)
  END;

  (* [4] LINE_NUMBER_RECORD (4B): line, offset -> chunked list.
     EMPIRICAL v2.08: line FIRST, then code offset (tdinfo.c has them swapped). *)
  cnt := INTEGER(UW(h.lineNumbersCount)); j := 0;
  WHILE j < cnt DO
    IF (lineTail = NIL) OR (lineTail^.count = LineChunk) THEN
      NEW(ln); ln^.count := 0; ln^.next := NIL;
      IF lineTail # NIL THEN lineTail^.next := ln ELSE lineHead := ln END; lineTail := ln
    END;
    Files.ReadWord(f, lineTail^.line[lineTail^.count]);
    Files.ReadWord(f, lineTail^.offset[lineTail^.count]);
    INC(lineTail^.count); INC(j)
  END;

  (* [5] SCOPE_RECORD (12B): symbol_index, symbol_count, parent, function,
     offset, length -> chunked list *)
  cnt := INTEGER(UW(h.scopesCount)); j := 0;
  WHILE j < cnt DO
    IF (scopeTail = NIL) OR (scopeTail^.count = ScopeChunk) THEN
      NEW(cn); cn^.count := 0; cn^.next := NIL;
      IF scopeTail # NIL THEN scopeTail^.next := cn ELSE scopeHead := cn END; scopeTail := cn
    END;
    Files.ReadWord(f, scopeTail^.symFirst[scopeTail^.count]);
    Files.ReadWord(f, scopeTail^.symCnt[scopeTail^.count]);
    Files.ReadWord(f, scopeTail^.parent[scopeTail^.count]);
    Files.ReadWord(f, scopeTail^.func[scopeTail^.count]);
    Files.ReadWord(f, scopeTail^.ofs[scopeTail^.count]);
    Files.ReadWord(f, scopeTail^.len[scopeTail^.count]);
    INC(scopeTail^.count); INC(j)
  END;

  (* [6] SEGMENT_RECORD (16B): module, code_segment, code_offset, code_length,
         scope_index, scope_count, 4 pad *)
  gc := INTEGER(UW(h.segmentsCount)); j := 0;
  WHILE j < gc DO
    Files.ReadWord(f, w); IF j < MaxSeg THEN segMod[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSeg THEN segSeg[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSeg THEN segOfs[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSeg THEN segLen[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSeg THEN segScIx[j] := w END;
    Files.ReadWord(f, w); IF j < MaxSeg THEN segScCnt[j] := w END;
    Files.Seek(f, Files.Position(f) + LONGINT(4));   (* pad *)
    INC(j)
  END;

  (* [7] CORRELATION_RECORD (8B): source_file_index, segment_index,
     module_index, flags *)
  cc := INTEGER(UW(h.correlationsCount)); j := 0;
  WHILE j < cc DO
    Files.ReadWord(f, w); IF j < MaxCorr THEN corrSrc[j] := w END;
    Files.ReadWord(f, w); IF j < MaxCorr THEN corrSeg[j] := w END;
    Files.ReadWord(f, w); IF j < MaxCorr THEN corrMod[j] := w END;
    Files.ReadWord(f, w); IF j < MaxCorr THEN corrFlags[j] := w END;
    INC(j)
  END;

  (* [8] TYPE_RECORD (8B): id(1), name(2), size(2), class_type(1),
     member_type(2) -> chunked list *)
  cnt := INTEGER(UW(h.typesCount)); j := 0;
  WHILE j < cnt DO
    IF (typeTail = NIL) OR (typeTail^.count = TypeChunk) THEN
      NEW(tn); tn^.count := 0; tn^.next := NIL;
      IF typeTail # NIL THEN typeTail^.next := tn ELSE typeHead := tn END; typeTail := tn
    END;
    IF Files.ReadByte(f, b) THEN typeTail^.id[typeTail^.count] := b END;
    Files.ReadWord(f, typeTail^.name[typeTail^.count]);
    Files.ReadWord(f, typeTail^.size[typeTail^.count]);
    IF Files.ReadByte(f, b) THEN typeTail^.classT[typeTail^.count] := b END;
    Files.ReadWord(f, typeTail^.membT[typeTail^.count]);
    INC(typeTail^.count); INC(j)
  END;

  (* [9] MEMBER_RECORD (5B): info(1), name(2), type(2) -> chunked list *)
  cnt := INTEGER(UW(h.membersCount)); j := 0;
  WHILE j < cnt DO
    IF (membTail = NIL) OR (membTail^.count = MembChunk) THEN
      NEW(mn); mn^.count := 0; mn^.next := NIL;
      IF membTail # NIL THEN membTail^.next := mn ELSE membHead := mn END; membTail := mn
    END;
    IF Files.ReadByte(f, b) THEN membTail^.info[membTail^.count] := b END;
    Files.ReadWord(f, membTail^.name[membTail^.count]);
    Files.ReadWord(f, membTail^.typ[membTail^.count]);
    INC(membTail^.count); INC(j)
  END;

  (* [10] string pool = trailing namesPoolSize bytes *)
  IF (h.namesPoolSize > LONGINT(0)) & (fileSize - h.namesPoolSize >= LONGINT(0)) THEN
    NEW(pool, INTEGER(h.namesPoolSize)); poolLen := h.namesPoolSize;
    Files.Seek(f, fileSize - h.namesPoolSize);
    IF Files.BlockRead(f, pool[0], WORD(h.namesPoolSize)) # WORD(h.namesPoolSize) THEN
      LogErr.Warn("tdinfo: short read on names pool")
    END
  END;

  (* --- dump --- *)

  Out.Ln; Out.String("=== Symbols ("); WUns(h.symbolsCount); Out.String(") ==="); Out.Ln;
  i := 0; sn := symHead;
  WHILE sn # NIL DO
    j := 0;
    WHILE j < sn^.count DO
      GetName(sn^.index[j], name); cls := sn^.bitfield[j] MOD 8;
      Out.String("  ["); Out.Int(i, 3); Out.String("] ");
      WPad(name, 32);
      Out.String(" type="); WUns(sn^.typ[j]);
      Out.String(" seg:off="); WHex4(sn^.segment[j]); Out.String(":"); WHex4(sn^.offset[j]);
      Out.String(" class="); WClass(cls); Out.Ln;
      INC(j); INC(i)
    END;
    sn := sn^.next
  END;

  Out.Ln; Out.String("=== Modules ("); WUns(h.modulesCount); Out.String(") ==="); Out.Ln;
  j := 0; WHILE j < mc DO
    GetName(modName[j], name); Out.String("  ["); Out.Int(j, 3); Out.String("] ");
    Out.String(name); Out.Ln; INC(j)
  END;

  (* Corrected v2.08 layout: name + DOS timestamp (the C tool prints garbage
     here — it decodes the stale segment/start layout). *)
  Out.Ln; Out.String("=== Source files ("); WUns(h.sourceFilesCount); Out.String(") ==="); Out.Ln;
  j := 0; WHILE j < sc DO
    GetName(srcName[j], name);
    Out.String("  ["); Out.Int(j, 3); Out.String("] ");
    WPad(name, 16);
    WriteStamp(srcDate[j], srcTime[j]); Out.Ln; INC(j)
  END;

  Out.Ln; Out.String("=== Line numbers ("); WUns(h.lineNumbersCount); Out.String(") ==="); Out.Ln;
  ln := lineHead;
  WHILE ln # NIL DO
    j := 0;
    WHILE j < ln^.count DO
      Out.String("  line "); Out.Int(UW(ln^.line[j]), 5);
      Out.String(" at offset "); WHex4(ln^.offset[j]); Out.Ln;
      INC(j)
    END;
    ln := ln^.next
  END;

  Out.Ln; Out.String("=== Scopes ("); WUns(h.scopesCount); Out.String(") ==="); Out.Ln;
  i := 0; cn := scopeHead;
  WHILE cn # NIL DO
    j := 0;
    WHILE j < cn^.count DO
      Out.String("  ["); Out.Int(i, 3); Out.String("] sym_first=");
      WUns(cn^.symFirst[j]);
      Out.String(" cnt=");    WUns(cn^.symCnt[j]);
      Out.String(" parent="); WUns(cn^.parent[j]);
      Out.String(" func=");   WUns(cn^.func[j]);
      Out.String(" offset="); WHex4(cn^.ofs[j]);
      Out.String(" len=");    WHex4(cn^.len[j]); Out.Ln;
      INC(j); INC(i)
    END;
    cn := cn^.next
  END;

  Out.Ln; Out.String("=== Segments ("); WUns(h.segmentsCount); Out.String(") ==="); Out.Ln;
  j := 0; WHILE j < gc DO
    ModuleName(INTEGER(UW(segMod[j])), mc, nm2);
    Out.String("  ["); Out.Int(j, 3); Out.String("] module=");
    WUns(segMod[j]);
    Out.String(" ("); Out.String(nm2); Out.String(")");
    Out.String(" seg:off="); WHex4(segSeg[j]); Out.String(":"); WHex4(segOfs[j]);
    Out.String(" len="); WHex4(segLen[j]);
    Out.String(" scope_first="); WUns(segScIx[j]);
    Out.String(" scope_count="); WUns(segScCnt[j]); Out.Ln;
    INC(j)
  END;

  Out.Ln; Out.String("=== Correlations ("); WUns(h.correlationsCount); Out.String(") ==="); Out.Ln;
  j := 0; WHILE j < cc DO
    i := INTEGER(UW(corrSrc[j]));
    name[0] := 0X;
    IF (i >= 1) & (i <= sc) & (i <= MaxSrc) THEN GetName(srcName[i - 1], name) END;
    ModuleName(INTEGER(UW(corrMod[j])), mc, nm2);
    Out.String("  ["); Out.Int(j, 3); Out.String("] src_file=");
    Out.String(name);
    Out.String(" seg="); WUns(corrSeg[j]);
    Out.String(" mod="); WUns(corrMod[j]);
    Out.String(" ("); Out.String(nm2); Out.String(")");
    Out.String(" flags=0x"); WHex4(corrFlags[j]); Out.Ln;
    INC(j)
  END;

  Out.Ln; Out.String("=== Types ("); WUns(h.typesCount); Out.String(") ==="); Out.Ln;
  i := 0; tn := typeHead;
  WHILE tn # NIL DO
    j := 0;
    WHILE j < tn^.count DO
      GetName(tn^.name[j], name);
      Out.String("  ["); Out.Int(i, 3); Out.String("] ");
      IF name[0] = 0X THEN Out.String("(anonymous)         ")   (* 20 cols *)
      ELSE WPad(name, 20) END;
      Out.String(" id="); WTypeId(INTEGER(tn^.id[j]));
      Out.String(" size=");        WUns(tn^.size[j]);
      Out.String(" class_type=");  Out.Int(INTEGER(tn^.classT[j]), 0);
      Out.String(" member_type="); WUns(tn^.membT[j]); Out.Ln;
      INC(j); INC(i)
    END;
    tn := tn^.next
  END;

  Out.Ln; Out.String("=== Members ("); WUns(h.membersCount); Out.String(") ==="); Out.Ln;
  i := 0; mn := membHead;
  WHILE mn # NIL DO
    j := 0;
    WHILE j < mn^.count DO
      GetName(mn^.name[j], name);
      Out.String("  ["); Out.Int(i, 3); Out.String("] ");
      WPad(name, 24);
      Out.String(" type="); WUns(mn^.typ[j]);
      Out.String(" info=0x"); WHex2(mn^.info[j]); Out.Ln;
      INC(j); INC(i)
    END;
    mn := mn^.next
  END;

  Out.Ln; Out.String("=== Names pool ("); WUns(h.namesCount); Out.String(" names) ==="); Out.Ln;
  i := 1; p := LONGINT(0);
  WHILE p < poolLen DO
    Out.String("  ["); Out.Int(i, 3); Out.String("] ");
    WHILE (p < poolLen) & (pool[p] # 0X) DO Out.Char(pool[p]); INC(p) END;
    INC(p); Out.Ln; INC(i)
  END;

  Files.Close(f);
  FreeLists; pool := NIL;
  RETURN ExitOk
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  LogErr.Close;
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in tdinfo *)
END Run;

BEGIN
  symHead := NIL; symTail := NIL; lineHead := NIL; lineTail := NIL;
  typeHead := NIL; typeTail := NIL; membHead := NIL; membTail := NIL;
  scopeHead := NIL; scopeTail := NIL;
  pool := NIL; poolLen := 0
END TDInfo.
