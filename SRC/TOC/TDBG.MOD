(*D-*)
MODULE TDbg;
(*
  Turbo-Debugger (TDS/TDINFO) debug-info collection — compiler side.

  Accumulates per-module debug records during compilation and serialises them
  to a text `.DBG` member (grammar in docs/implementation-rules.md §".DBG file
  format").  No binary TDS I/O here; the linker builds the final TDS block
  from the merged `.DBG` members.

  Collection is gated by Enabled() ($D+ / $D-).  When disabled, WriteDbg writes
  an empty (0-byte) member and no records are collected.

  Chunk small records (KEY RULE): N entries per node, count + next.

  Types/members (Phase 2): every distinct Syms.TypeDesc reachable from a
  collected VAR/TYPEDEF symbol gets one module-local TYPE_RECORD (1-based
  index); RECORD types additionally get one MEMBER_RECORD per field.  The
  Syms.TypeDesc -> local-index map is by pointer identity (a TypeDesc is
  never copied — Parser hands out the same pointer everywhere a named type
  is used), so lookup is a linear scan of a small chunked table.
*)
IMPORT Files, Strings, Syms, StrTab, LogErr;

CONST
  LineChunk = 128;
  SymChunk  = 32;
  TypeChunk = 32;
  MembChunk = 32;
  MapChunk  = 32;
  NameLen   = 40;   (* same as Syms.NameLen *)

  (* TD TYPE_RECORD id mnemonics (docs/tdinfo.c type_id_names / docs/td-spec.md) *)
  IdVoid     = 0;
  IdSChar    = 4;
  IdSInt     = 5;
  IdSLong    = 6;
  IdUChar    = 8;
  IdUInt     = 9;
  IdFloat    = 13;
  IdDouble   = 15;
  IdFar      = 22;
  IdArray    = 26;
  IdStruct   = 30;
  IdSet      = 37;
  IdBool     = 40;

  (* TD TYPE_RECORD class_type values relevant here *)
  ClassPlain = 0;

TYPE
  LineNode = POINTER TO LineNodeDesc;
  LineNodeDesc = RECORD
    ofs:   ARRAY LineChunk OF WORD;
    line:  ARRAY LineChunk OF INTEGER;
    count: INTEGER;
    next:  LineNode
  END;

  (* One flat, insertion-ordered stream so a procedure's locals/scope-end
     land textually right after its own S-line (the linker depends on that
     adjacency to build SCOPE_RECORDs without a second pass).  `off` is
     reused as a signed BP offset (bit pattern) for class 'A' and as the
     scope's code length for class 'E' — both fit a WORD.
     Classes: 'P' proc, 'V' module var, 'Y' typedef, 'A' local/param,
     'E' scope-end (closes the most recent 'P'; `off`=code length). *)
  SymNode = POINTER TO SymNodeDesc;
  SymNodeDesc = RECORD
    off:   ARRAY SymChunk OF WORD;
    seg:   ARRAY SymChunk OF CHAR;     (* 'C' code, 'D' data, '-' n/a *)
    class: ARRAY SymChunk OF CHAR;
    typ:   ARRAY SymChunk OF WORD;     (* 1-based local TYPE index, 0=none *)
    name:  ARRAY SymChunk OF ARRAY NameLen OF CHAR;  (* unused for 'E' *)
    count: INTEGER;
    next:  SymNode
  END;

  (* TYPE_RECORD (module-local, 1-based index) *)
  TypeNode = POINTER TO TypeNodeDesc;
  TypeNodeDesc = RECORD
    id:     ARRAY TypeChunk OF BYTE;   (* TD type-id mnemonic *)
    size:   ARRAY TypeChunk OF WORD;
    classT: ARRAY TypeChunk OF BYTE;
    membT:  ARRAY TypeChunk OF WORD;   (* local MEMBER/TYPE index, 0=none *)
    name:   ARRAY TypeChunk OF ARRAY NameLen OF CHAR;  (* "" = anonymous *)
    count:  INTEGER;
    next:   TypeNode
  END;

  (* MEMBER_RECORD (module-local, 1-based index) *)
  MembNode = POINTER TO MembNodeDesc;
  MembNodeDesc = RECORD
    info: ARRAY MembChunk OF BYTE;     (* 0x80 = last field of its record *)
    typ:  ARRAY MembChunk OF WORD;     (* local TYPE index of the field *)
    name: ARRAY MembChunk OF ARRAY NameLen OF CHAR;
    count: INTEGER;
    next: MembNode
  END;

  (* Syms.TypeDesc -> local TYPE_RECORD index map (pointer-identity, chunked). *)
  MapNode = POINTER TO MapNodeDesc;
  MapNodeDesc = RECORD
    t:     ARRAY MapChunk OF Syms.TypeDesc;
    idx:   ARRAY MapChunk OF WORD;
    count: INTEGER;
    next:  MapNode
  END;

VAR
  enabled:  BOOLEAN;
  modName:  ARRAY NameLen OF CHAR;
  srcFile:  ARRAY NameLen OF CHAR;
  codeLen:  WORD;
  lastLine: INTEGER;
  lastOfs:  WORD;
  nextTypeIdx: WORD;
  nextMembIdx: WORD;

  lineHead, lineTail: LineNode;
  symHead,  symTail:  SymNode;
  typeHead, typeTail: TypeNode;
  membHead, membTail: MembNode;
  mapHead,  mapTail:  MapNode;

PROCEDURE Enabled*(): BOOLEAN;
BEGIN RETURN enabled
END Enabled;

PROCEDURE SetEnabled*(on: BOOLEAN);
BEGIN enabled := on
END SetEnabled;

PROCEDURE BeginModule*(mn, sf: ARRAY OF CHAR);
BEGIN
  Strings.Copy(mn, modName);
  Strings.Copy(sf, srcFile);
  codeLen := 0; lastLine := -1; lastOfs := 0
END BeginModule;

PROCEDURE AddLine*(codeOfs: WORD; line: INTEGER);
  VAR n: LineNode;
BEGIN
  IF ~enabled THEN RETURN END;
  (* per-source-line dedup + suppress when code has not advanced *)
  IF (line = lastLine) OR ((lineHead # NIL) & (codeOfs = lastOfs)) THEN RETURN END;
  IF (lineTail = NIL) OR (lineTail^.count = LineChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (debug line list)"); RETURN END;
    n^.count := 0; n^.next := NIL;
    IF lineTail # NIL THEN lineTail^.next := n ELSE lineHead := n END;
    lineTail := n
  END;
  lineTail^.ofs[lineTail^.count]  := codeOfs;
  lineTail^.line[lineTail^.count] := line;
  INC(lineTail^.count);
  lastLine := line; lastOfs := codeOfs
END AddLine;

(* ---- type table ---- *)

(* MapFind — return the already-assigned local index for t, or 0 if unmapped. *)
PROCEDURE MapFind(t: Syms.TypeDesc): WORD;
  VAR n: MapNode; i: INTEGER;
BEGIN
  n := mapHead;
  WHILE n # NIL DO
    i := 0;
    WHILE i < n^.count DO
      IF n^.t[i] = t THEN RETURN n^.idx[i] END;
      INC(i)
    END;
    n := n^.next
  END;
  RETURN 0
END MapFind;

PROCEDURE MapAdd(t: Syms.TypeDesc; idx: WORD);
  VAR n: MapNode;
BEGIN
  IF (mapTail = NIL) OR (mapTail^.count = MapChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (debug type-map list)"); RETURN END;
    n^.count := 0; n^.next := NIL;
    IF mapTail # NIL THEN mapTail^.next := n ELSE mapHead := n END;
    mapTail := n
  END;
  mapTail^.t[mapTail^.count] := t;
  mapTail^.idx[mapTail^.count] := idx;
  INC(mapTail^.count)
END MapAdd;

(* NewTypeRec — allocate the next local TYPE_RECORD slot and return its
   1-based index; caller fills fields via TypeSet*. *)
PROCEDURE NewTypeRec(): WORD;
  VAR n: TypeNode; idx: WORD;
BEGIN
  IF (typeTail = NIL) OR (typeTail^.count = TypeChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (debug type-record list)"); RETURN 0 END;
    n^.count := 0; n^.next := NIL;
    IF typeTail # NIL THEN typeTail^.next := n ELSE typeHead := n END;
    typeTail := n
  END;
  INC(nextTypeIdx); idx := nextTypeIdx;
  typeTail^.id[typeTail^.count]     := BYTE(IdVoid);
  typeTail^.size[typeTail^.count]   := 0;
  typeTail^.classT[typeTail^.count] := BYTE(ClassPlain);
  typeTail^.membT[typeTail^.count]  := 0;
  typeTail^.name[typeTail^.count][0] := 0X;
  INC(typeTail^.count);
  RETURN idx
END NewTypeRec;

PROCEDURE TypeSetAt(idx: WORD; id: BYTE; size: WORD; classT: BYTE; membT: WORD;
                     VAR name: ARRAY OF CHAR);
  VAR n: TypeNode; pos: WORD;
BEGIN
  n := typeHead; pos := idx - 1;
  WHILE pos >= WORD(TypeChunk) DO n := n^.next; pos := pos - WORD(TypeChunk) END;
  n^.id[pos] := id; n^.size[pos] := size; n^.classT[pos] := classT;
  n^.membT[pos] := membT; Strings.Copy(name, n^.name[pos])
END TypeSetAt;

PROCEDURE NewMembRec(info: BYTE; typ: WORD; VAR name: ARRAY OF CHAR): WORD;
  VAR n: MembNode; idx: WORD;
BEGIN
  IF (membTail = NIL) OR (membTail^.count = MembChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (debug member-record list)"); RETURN 0 END;
    n^.count := 0; n^.next := NIL;
    IF membTail # NIL THEN membTail^.next := n ELSE membHead := n END;
    membTail := n
  END;
  INC(nextMembIdx); idx := nextMembIdx;
  membTail^.info[membTail^.count] := info;
  membTail^.typ[membTail^.count]  := typ;
  Strings.Copy(name, membTail^.name[membTail^.count]);
  INC(membTail^.count);
  RETURN idx
END NewMembRec;

(* Map an Oberon primitive type form to a TD TYPE_RECORD id + size. *)
PROCEDURE PrimId(form: INTEGER; VAR id: BYTE; VAR size: WORD);
BEGIN
  CASE form OF
    Syms.TFInteger:  id := BYTE(IdSInt);  size := Syms.SzInteger
  | Syms.TFBoolean:  id := BYTE(IdBool);  size := Syms.SzBoolean
  | Syms.TFChar:     id := BYTE(IdUChar); size := Syms.SzChar
  | Syms.TFByte:     id := BYTE(IdUChar); size := Syms.SzByte
  | Syms.TFSet:      id := BYTE(IdSet);   size := Syms.SzSet
  | Syms.TFWord:     id := BYTE(IdUInt);  size := Syms.SzWord
  | Syms.TFLongint:  id := BYTE(IdSLong); size := Syms.SzLongint
  | Syms.TFAddress:  id := BYTE(IdFar);   size := Syms.SzPointer
  | Syms.TFReal:     id := BYTE(IdFloat); size := Syms.SzReal
  | Syms.TFLongreal: id := BYTE(IdDouble);size := Syms.SzLongreal
  | Syms.TFProc:     id := BYTE(IdFar);   size := Syms.SzPointer
  ELSE id := BYTE(IdVoid); size := 0
  END
END PrimId;

(* TypeIndex — intern t (and everything it references) into this module's
   local TYPE_RECORD/MEMBER_RECORD tables; return t's 1-based local index
   (0 if t is NIL or debug info is disabled). Recursion is safe against
   self-referential POINTER types: the index is reserved (via MapAdd) BEFORE
   recursing into elem/base/fields. *)
PROCEDURE TypeIndex*(t: Syms.TypeDesc): WORD;
  VAR idx, elemIdx, firstMemb, membIdx: WORD;
      id: BYTE; size: WORD; info: BYTE;
      nm: ARRAY NameLen OF CHAR;
      fld: Syms.Symbol;
BEGIN
  IF (~enabled) OR (t = NIL) THEN RETURN 0 END;
  idx := MapFind(t);
  IF idx # 0 THEN RETURN idx END;
  idx := NewTypeRec();
  MapAdd(t, idx);            (* reserve before recursing (self-reference) *)
  nm[0] := 0X;
  IF t.form = Syms.TFArray THEN
    elemIdx := TypeIndex(t.elem);
    TypeSetAt(idx, BYTE(IdArray), WORD(t.size), BYTE(ClassPlain), elemIdx, nm)
  ELSIF t.form = Syms.TFRecord THEN
    firstMemb := 0; membIdx := 0;
    fld := t.fields;
    WHILE fld # Syms.NoSym DO
      StrTab.Get(fld.nameId, nm);
      info := BYTE(0);
      IF fld.next = Syms.NoSym THEN info := BYTE(080H) END;
      membIdx := NewMembRec(info, TypeIndex(fld.type), nm);
      IF firstMemb = 0 THEN firstMemb := membIdx END;
      fld := fld.next
    END;
    nm[0] := 0X;
    TypeSetAt(idx, BYTE(IdStruct), WORD(t.size), BYTE(ClassPlain), firstMemb, nm)
  ELSIF t.form = Syms.TFPointer THEN
    elemIdx := TypeIndex(t.base);
    TypeSetAt(idx, BYTE(IdFar), WORD(t.size), BYTE(ClassPlain), elemIdx, nm)
  ELSE
    PrimId(t.form, id, size);
    TypeSetAt(idx, id, size, BYTE(ClassPlain), 0, nm)
  END;
  RETURN idx
END TypeIndex;

PROCEDURE AddSymT*(class, seg: CHAR; off: WORD; typ: WORD; name: ARRAY OF CHAR);
  VAR n: SymNode;
BEGIN
  IF ~enabled THEN RETURN END;
  IF (symTail = NIL) OR (symTail^.count = SymChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("out of memory (debug symbol list)"); RETURN END;
    n^.count := 0; n^.next := NIL;
    IF symTail # NIL THEN symTail^.next := n ELSE symHead := n END;
    symTail := n
  END;
  symTail^.class[symTail^.count] := class;
  symTail^.seg[symTail^.count]   := seg;
  symTail^.off[symTail^.count]   := off;
  symTail^.typ[symTail^.count]   := typ;
  Strings.Copy(name, symTail^.name[symTail^.count]);
  INC(symTail^.count)
END AddSymT;

PROCEDURE AddSym*(class, seg: CHAR; off: WORD; name: ARRAY OF CHAR);
BEGIN
  AddSymT(class, seg, off, 0, name)
END AddSym;

(* AddLocalSym — a local/parameter (class AUTO).  bpOfs is the Syms BP-relative
   offset (LONGINT: negative for locals, positive for params); it always fits
   16 bits (DOS stack frames are far under 32K) so the WORD bit pattern is
   re-widened to signed INTEGER by the writer/reader. *)
PROCEDURE AddLocalSym*(bpOfs: LONGINT; typ: WORD; name: ARRAY OF CHAR);
BEGIN
  AddSymT("A", "-", WORD(INTEGER(bpOfs)), typ, name)
END AddLocalSym;

(* EndScope — close the most recently opened procedure's local scope;
   procLen is that procedure's own code length in bytes.  A no-op record (no
   name) so it reuses the shared stream/writer machinery. *)
PROCEDURE EndScope*(procLen: WORD);
  VAR empty: ARRAY 1 OF CHAR;
BEGIN
  empty[0] := 0X;
  AddSymT("E", "-", procLen, 0, empty)
END EndScope;

PROCEDURE SetCodeLen*(len: WORD);
BEGIN codeLen := len
END SetCodeLen;

(* ---- text writer ---- *)

(* AppHex4 — append fixed 4-digit uppercase hex of v to line[]. *)
PROCEDURE AppHex4(VAR line: ARRAY OF CHAR; v: WORD);
  VAR h: ARRAY 8 OF CHAR; i, d: INTEGER;
BEGIN
  FOR i := 3 TO 0 BY -1 DO
    d := v MOD 16; v := v DIV 16;
    IF d < 10 THEN h[i] := CHR(ORD("0") + d)
    ELSE h[i] := CHR(ORD("A") + d - 10) END
  END;
  h[4] := 0X; Strings.Append(h, line)
END AppHex4;

(* AppDec — append decimal of v to line[]. *)
PROCEDURE AppDec(VAR line: ARRAY OF CHAR; v: LONGINT);
  VAR d: ARRAY 16 OF CHAR;
BEGIN
  Strings.Str(v, d); Strings.Append(d, line)
END AppDec;

(* AppCh — append single char c to line[]. *)
PROCEDURE AppCh(VAR line: ARRAY OF CHAR; c: CHAR);
  VAR s: ARRAY 2 OF CHAR;
BEGIN
  s[0] := c; s[1] := 0X; Strings.Append(s, line)
END AppCh;

PROCEDURE WriteDbg*(VAR f: Files.File);
  VAR ln: LineNode; sn: SymNode; tn: TypeNode; mn: MembNode;
      i: INTEGER; line: ARRAY 96 OF CHAR;
BEGIN
  IF ~enabled THEN RETURN END;   (* $D- -> 0-byte member *)
  Files.WriteLine(f, "D 1");
  line := "M "; Strings.Append(modName, line); Files.WriteLine(f, line);
  line := "F "; Strings.Append(srcFile, line); Files.WriteLine(f, line);
  line := "C "; AppDec(line, codeLen); Files.WriteLine(f, line);
  (* types + members BEFORE symbols, so the linker can build its type/member
     tables in one earlier pass and rebase symbol type-indices in the same
     pass it rebases the symbols themselves *)
  tn := typeHead;
  WHILE tn # NIL DO
    i := 0;
    WHILE i < tn^.count DO
      line := "T "; AppHex4(line, tn^.id[i]); AppCh(line, " ");
      AppHex4(line, tn^.size[i]); AppCh(line, " ");
      AppHex4(line, tn^.classT[i]); AppCh(line, " ");
      AppHex4(line, tn^.membT[i]); AppCh(line, " ");
      IF tn^.name[i][0] = 0X THEN AppCh(line, "-")
      ELSE Strings.Append(tn^.name[i], line) END;
      Files.WriteLine(f, line);
      INC(i)
    END;
    tn := tn^.next
  END;
  mn := membHead;
  WHILE mn # NIL DO
    i := 0;
    WHILE i < mn^.count DO
      line := "B "; AppHex4(line, mn^.info[i]); AppCh(line, " ");
      AppHex4(line, mn^.typ[i]); AppCh(line, " ");
      Strings.Append(mn^.name[i], line);
      Files.WriteLine(f, line);
      INC(i)
    END;
    mn := mn^.next
  END;
  sn := symHead;
  WHILE sn # NIL DO
    i := 0;
    WHILE i < sn^.count DO
      line := "S "; AppCh(line, sn^.class[i]); AppCh(line, " ");
      AppHex4(line, sn^.off[i]); AppCh(line, " ");
      AppCh(line, sn^.seg[i]);   AppCh(line, " ");
      AppHex4(line, sn^.typ[i]); AppCh(line, " ");
      Strings.Append(sn^.name[i], line);
      Files.WriteLine(f, line);
      INC(i)
    END;
    sn := sn^.next
  END;
  ln := lineHead;
  WHILE ln # NIL DO
    i := 0;
    WHILE i < ln^.count DO
      line := "L "; AppHex4(line, ln^.ofs[i]); AppCh(line, " ");
      AppDec(line, ln^.line[i]);
      Files.WriteLine(f, line);
      INC(i)
    END;
    ln := ln^.next
  END
END WriteDbg;

PROCEDURE Reset*();
  VAR ln, lnNext: LineNode; sn, snNext: SymNode;
      tn, tnNext: TypeNode; mn, mnNext: MembNode;
      mp, mpNext: MapNode;
BEGIN
  ln := lineHead;
  WHILE ln # NIL DO lnNext := ln^.next; DISPOSE(ln); ln := lnNext END;
  sn := symHead;
  WHILE sn # NIL DO snNext := sn^.next; DISPOSE(sn); sn := snNext END;
  tn := typeHead;
  WHILE tn # NIL DO tnNext := tn^.next; DISPOSE(tn); tn := tnNext END;
  mn := membHead;
  WHILE mn # NIL DO mnNext := mn^.next; DISPOSE(mn); mn := mnNext END;
  mp := mapHead;
  WHILE mp # NIL DO mpNext := mp^.next; DISPOSE(mp); mp := mpNext END;
  lineHead := NIL; lineTail := NIL;
  symHead := NIL; symTail := NIL;
  typeHead := NIL; typeTail := NIL;
  membHead := NIL; membTail := NIL;
  mapHead := NIL; mapTail := NIL;
  nextTypeIdx := 0; nextMembIdx := 0;
  enabled := FALSE;
  modName[0] := 0X; srcFile[0] := 0X;
  codeLen := 0; lastLine := -1; lastOfs := 0
END Reset;

BEGIN
  enabled := FALSE;
  lineHead := NIL; lineTail := NIL;
  symHead := NIL; symTail := NIL;
  typeHead := NIL; typeTail := NIL;
  membHead := NIL; membTail := NIL;
  mapHead := NIL; mapTail := NIL;
  nextTypeIdx := 0; nextMembIdx := 0;
  modName[0] := 0X; srcFile[0] := 0X;
  codeLen := 0; lastLine := -1; lastOfs := 0
END TDbg.
