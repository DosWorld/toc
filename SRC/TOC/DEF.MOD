(*D+*)
MODULE Def;
(*
  Port of def.c/def.h to Oberon-07.
  .def file writer (DefWrite) and reader (DefRead).
  Text I/O via Files.File with byte-level helpers.
*)
IMPORT Files, LogErr, Syms, Strings, StrTab;

CONST
  SegData* = 1;
  NameLen  = 40;   (* same as Syms.NameLen *)
  QNameLen = 80;   (* alias.shortname — must be 2 * NameLen *)

TYPE
  BasePatch = POINTER TO BasePatchDesc;
  BasePatchDesc = RECORD
    derived:   Syms.TypeDesc;
    baseShort: ARRAY NameLen OF CHAR;
    next:      BasePatch
  END;

VAR
  curAlias: ARRAY NameLen OF CHAR;
  (* primFormName[form] = keyword for a primitive scalar type form, or "" if
     form is not a simple primitive (ARRAY/RECORD/POINTER/PROC/... need
     structural handling in WriteType).  Filled in the module body below —
     no CONST arrays. *)
  primFormName: ARRAY 16 OF ARRAY 12 OF CHAR;
  i: INTEGER;

(* ---- write helpers ---- *)

PROCEDURE WInt(VAR f: Files.File; v: LONGINT);
  VAR buf: ARRAY 16 OF CHAR;
BEGIN
  Strings.Str(v, buf);
  Files.Write(f, buf)
END WInt;

(* Write the text of a StrTab name id. *)
PROCEDURE WName(VAR f: Files.File; id: WORD);
  VAR nm: ARRAY NameLen OF CHAR;
BEGIN
  StrTab.Get(id, nm);
  Files.Write(f, nm)
END WName;

(* Write "modName_id" (qualified name), e.g. for CONST/VAR/PROC/INLINE lines. *)
PROCEDURE WQualName(VAR f: Files.File; modName: ARRAY OF CHAR; id: WORD);
BEGIN
  Files.Write(f, modName); Files.WriteByte(f, ORD('_')); WName(f, id)
END WQualName;

(* Write "TYPE modName_id" — the header common to every WriteOneType branch. *)
PROCEDURE WTypeHdr(VAR f: Files.File; modName: ARRAY OF CHAR; id: WORD);
BEGIN
  Files.Write(f, "TYPE "); WQualName(f, modName, id)
END WTypeHdr;

(* ---- type name finder (writer side) ---- *)

PROCEDURE FindTypeName(t: Syms.TypeDesc; VAR name: ARRAY OF CHAR);
  VAR sym: Syms.Symbol;
BEGIN
  name[0] := 0X;
  sym := Syms.TopScope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF (sym.kind = Syms.KType) & (sym.type = t) THEN
      StrTab.Get(sym.nameId, name); RETURN
    END;
    sym := sym.next
  END
END FindTypeName;

PROCEDURE WriteType(VAR f: Files.File; t: Syms.TypeDesc);
  VAR nm: ARRAY NameLen OF CHAR;
BEGIN
  IF t = Syms.NoType THEN Files.Write(f, "VOID"); RETURN END;
  IF primFormName[t.form][0] # 0X THEN Files.Write(f, primFormName[t.form]); RETURN END;
  IF t.form = Syms.TFArray THEN
    IF t.len >= LONGINT(0) THEN
      Files.Write(f, "ARRAY "); WInt(f, t.len); Files.Write(f, " OF ")
    ELSE
      Files.Write(f, "ARRAY OF ")
    END;
    WriteType(f, t.elem);
    RETURN
  END;
  IF t.form = Syms.TFPointer THEN
    Files.Write(f, "POINTER ");
    IF t.base # Syms.NoType THEN
      FindTypeName(t.base, nm);
      IF nm[0] # 0X THEN Files.Write(f, nm); RETURN END;
      (* Anonymous base (e.g. POINTER TO ARRAY N OF T with no named alias
         for the array itself) — the base has no symbol table name to
         reference, so write its structure inline.  ParseDefType's own
         POINTER case already accepts any type token here, including
         "ARRAY ...", so this round-trips.  See PTR.MD. *)
      IF t.base.form = Syms.TFArray THEN WriteType(f, t.base); RETURN END
    END;
    Files.Write(f, "VOID"); RETURN
  END;
  IF t.form = Syms.TFRecord THEN
    FindTypeName(t, nm);
    IF nm[0] # 0X THEN Files.Write(f, nm); RETURN END;
    Files.Write(f, "VOID"); RETURN
  END;
  IF t.form = Syms.TFProc THEN
    (* Emit "PROC" so the importer treats the slot as a 4-byte FAR proc value.
       Cross-module proc variables are always FAR (NEAR can't be exported),
       so no FAR/NEAR keyword is needed.  The signature itself is not
       serialised — at the call boundary only the slot size matters. *)
    Files.Write(f, "PROC"); RETURN
  END;
  Files.Write(f, "INTEGER")
END WriteType;

PROCEDURE HasDot(name: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE name[i] # 0X DO IF name[i] = '.' THEN RETURN TRUE END; INC(i) END;
  RETURN FALSE
END HasDot;

PROCEDURE HasDotId(id: WORD): BOOLEAN;
  VAR nm: ARRAY NameLen OF CHAR;
BEGIN
  StrTab.Get(id, nm);
  RETURN HasDot(nm)
END HasDotId;

PROCEDURE WriteOneType(VAR f: Files.File; modName: ARRAY OF CHAR; sym: Syms.Symbol);
  VAR td: Syms.TypeDesc; fld: Syms.Symbol;
      bnm: ARRAY NameLen OF CHAR;
BEGIN
  td := sym.type;
  IF (td # Syms.NoType) & (td.form = Syms.TFRecord) THEN
    (* Always emit the RECORD header with its size, even when no field is
       exported: importers need the size to lay out records that embed this one
       (e.g. Scan.Scanner has a private `file: Files.File`).  Only the FIELD lines
       are gated on `exported`. *)
    WTypeHdr(f, modName, sym.nameId);
    Files.Write(f, " RECORD "); WInt(f, td.size); Files.WriteLn(f);
    IF td.base # Syms.NoType THEN
      FindTypeName(td.base, bnm);
      IF bnm[0] # 0X THEN
        Files.Write(f, "  BASE "); Files.Write(f, modName); Files.WriteByte(f, ORD('_')); Files.Write(f, bnm); Files.WriteLn(f)
      END
    END;
    fld := td.fields;
    WHILE fld # Syms.NoSym DO
      IF fld.exported THEN
        Files.Write(f, "  FIELD "); WName(f, fld.nameId); Files.WriteByte(f, ORD(' '));
        WriteType(f, fld.type); Files.WriteByte(f, ORD(' ')); WInt(f, fld.offset); Files.WriteLn(f)
      END;
      fld := fld.next
    END;
    Files.Write(f, "END"); Files.WriteLn(f)
  ELSIF (td # Syms.NoType) & (td.form = Syms.TFPointer) THEN
    WTypeHdr(f, modName, sym.nameId);
    Files.Write(f, " POINTER "); WriteType(f, td.base); Files.WriteLn(f)
  ELSIF (td # Syms.NoType) & (td.form = Syms.TFProc) THEN
    WTypeHdr(f, modName, sym.nameId);
    Files.Write(f, " PROC"); Files.WriteLn(f)
  ELSIF (td # Syms.NoType) & (td.form = Syms.TFAddress) THEN
    WTypeHdr(f, modName, sym.nameId);
    Files.Write(f, " ADDRESS"); Files.WriteLn(f)
  ELSIF (td # Syms.NoType) & (td.form = Syms.TFArray) THEN
    WTypeHdr(f, modName, sym.nameId);
    Files.WriteByte(f, ORD(' ')); WriteType(f, td); Files.WriteLn(f)
  ELSIF (td # Syms.NoType) &
        ((td.form = Syms.TFInteger) OR (td.form = Syms.TFBoolean) OR
         (td.form = Syms.TFChar) OR (td.form = Syms.TFByte) OR
         (td.form = Syms.TFWord) OR (td.form = Syms.TFLongint) OR
         (td.form = Syms.TFReal) OR (td.form = Syms.TFLongreal) OR
         (td.form = Syms.TFSet)) THEN
    (* A TYPE alias of a primitive built-in (e.g. TYPE X = LONGINT) must carry
       its underlying form across the .def boundary — an importer that
       cannot see the form defaults it to INTEGER (2 bytes), silently
       truncating any 4-byte (LONGINT) or other-width value stored through a
       VAR parameter/global of the alias type. *)
    WTypeHdr(f, modName, sym.nameId);
    Files.Write(f, " PRIM "); WriteType(f, td); Files.WriteLn(f)
  ELSE
    WTypeHdr(f, modName, sym.nameId); Files.WriteLn(f)
  END
END WriteOneType;

(* Write the "  PARAM ..." lines for a parameter chain starting at p. *)
PROCEDURE WriteParams(VAR f: Files.File; p: Syms.Symbol);
BEGIN
  WHILE p # Syms.NoSym DO
    IF (p.kind = Syms.KVarParam) & p.typeless THEN Files.Write(f, "  PARAM TYPELESSVAR ")
    ELSIF p.kind = Syms.KVarParam THEN Files.Write(f, "  PARAM VAR ")
    ELSE Files.Write(f, "  PARAM ")
    END;
    IF ~((p.kind = Syms.KVarParam) & p.typeless) THEN
      WName(f, p.nameId); Files.WriteByte(f, ORD(' ')); WriteType(f, p.type); Files.WriteLn(f)
    ELSE
      WName(f, p.nameId); Files.WriteLn(f)
    END;
    p := p.next
  END
END WriteParams;

PROCEDURE DefWrite*(VAR f: Files.File; modName: ARRAY OF CHAR);
  VAR sym: Syms.Symbol; scope: Syms.Scope;
      pt: Syms.TypeDesc; nd: Syms.InlineNode;
      ki: INTEGER;
BEGIN
  scope := Syms.TopScope;
  Files.Write(f, "MODULE "); Files.Write(f, modName); Files.WriteLn(f);

  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KConst) THEN
      Files.Write(f, "CONST "); WQualName(f, modName, sym.nameId);
      Files.WriteByte(f, ORD(' ')); WInt(f, sym.val); Files.WriteLn(f)
    END;
    sym := sym.next
  END;

  (* Pass 2a: root records (no base) first — they must precede any ARRAY/
     POINTER alias that references them, so the element record's real size
     is known when parse_def_type constructs the array type. *)
  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KType) &
       (sym.type # Syms.NoType) &
       (sym.type.form = Syms.TFRecord) & (sym.type.base = Syms.NoType) THEN
      WriteOneType(f, modName, sym)
    END;
    sym := sym.next
  END;

  (* Pass 2b: extended records (have a base) *)
  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KType) &
       (sym.type # Syms.NoType) &
       (sym.type.form = Syms.TFRecord) & (sym.type.base # Syms.NoType) THEN
      WriteOneType(f, modName, sym)
    END;
    sym := sym.next
  END;

  (* Pass 2c: everything else (pointer, array, address, proc, opaque) *)
  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KType) &
       (sym.type # Syms.NoType) & (sym.type.form # Syms.TFRecord) THEN
      WriteOneType(f, modName, sym)
    END;
    sym := sym.next
  END;

  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KVar) THEN
      (* Format: VAR ModName_varname <type> seg offset *)
      Files.Write(f, "VAR "); WQualName(f, modName, sym.nameId);
      Files.WriteByte(f, ORD(' ')); WriteType(f, sym.type); Files.WriteByte(f, ORD(' '));
      IF sym.level = 0 THEN Files.WriteByte(f, ORD('1')) ELSE Files.WriteByte(f, ORD('0')) END;
      Files.WriteByte(f, ORD(' ')); WInt(f, sym.adr); Files.WriteLn(f)
    END;
    sym := sym.next
  END;

  sym := scope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF sym.exported & ~HasDotId(sym.nameId) & (sym.kind = Syms.KProc) THEN
      pt := sym.type;
      IF (pt # Syms.NoType) & pt.isInline THEN
        Files.Write(f, "INLINE "); WQualName(f, modName, sym.nameId);
        Files.WriteByte(f, ORD(' ')); WriteType(f, pt.retType); Files.WriteLn(f);
        WriteParams(f, pt.params);
        Files.Write(f, "  BYTES");
        nd := pt.inlineList;
        WHILE nd # NIL DO
          ki := 0;
          WHILE ki < nd^.count DO
            Files.WriteByte(f, ORD(' '));
            IF nd^.isParam[ki] THEN Files.WriteByte(f, ORD('P')); WInt(f, LONGINT(nd^.paramIdx[ki]))
            ELSE WInt(f, LONGINT(INTEGER(nd^.rawByte[ki])))
            END;
            INC(ki)
          END;
          nd := nd^.next
        END;
        Files.WriteLn(f); Files.Write(f, "END"); Files.WriteLn(f)
      ELSE
        Files.Write(f, "PROC "); WQualName(f, modName, sym.nameId);
        Files.WriteByte(f, ORD(' '));
        IF (pt # Syms.NoType) & pt.isFar THEN Files.Write(f, "FAR") ELSE Files.Write(f, "NEAR") END;
        Files.WriteByte(f, ORD(' ')); WriteType(f, pt.retType); Files.WriteLn(f);
        IF pt # Syms.NoType THEN WriteParams(f, pt.params) END;
        Files.Write(f, "END"); Files.WriteLn(f)
      END
    END;
    sym := sym.next
  END
END DefWrite;

(* ---- reader helpers ---- *)

PROCEDURE SkipWS(s: ARRAY OF CHAR; VAR i: INTEGER);
BEGIN WHILE (s[i] = ' ') OR (s[i] = 09X) DO INC(i) END END SkipWS;

PROCEDURE ReadToken(s: ARRAY OF CHAR; VAR i: INTEGER; VAR tok: ARRAY OF CHAR);
  VAR j: INTEGER;
BEGIN
  SkipWS(s, i); j := 0;
  WHILE (s[i] # 0X) & (s[i] # ' ') & (s[i] # 09X) DO
    IF j < LEN(tok) - 1 THEN tok[j] := s[i]; INC(j) END; INC(i)
  END;
  tok[j] := 0X
END ReadToken;

PROCEDURE ReadLong(s: ARRAY OF CHAR; VAR i: INTEGER): LONGINT;
  VAR v: LONGINT; neg: BOOLEAN;
BEGIN
  SkipWS(s, i); neg := FALSE;
  IF s[i] = '-' THEN neg := TRUE; INC(i) END;
  v := 0;
  WHILE SYSTEM.ISDIGIT(s[i]) DO
    v := v * 10 + LONGINT(ORD(s[i]) - ORD('0')); INC(i)
  END;
  IF neg THEN RETURN -v END;
  RETURN v
END ReadLong;

PROCEDURE MakeShort(full: ARRAY OF CHAR; VAR short: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  i := 0; WHILE (full[i] # 0X) & (full[i] # '_') DO INC(i) END;
  IF full[i] = '_' THEN INC(i) END;
  j := 0;
  WHILE (full[i] # 0X) & (j < LEN(short) - 1) DO
    short[j] := full[i]; INC(j); INC(i)
  END;
  short[j] := 0X
END MakeShort;

(* Build qname = prefix + "." + suffix into dst. *)
PROCEDURE BuildQName(prefix, suffix: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
BEGIN
  Strings.Copy(prefix, dst);
  Strings.Append(".", dst);
  Strings.Append(suffix, dst);
END BuildQName;

PROCEDURE HasDotChar(tname: ARRAY OF CHAR): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE tname[i] # 0X DO
    IF tname[i] = "." THEN RETURN TRUE END; INC(i)
  END;
  RETURN FALSE
END HasDotChar;

(* Map a primitive-form index to its live TypeDesc singleton.  Syms.TypeXxx
   are set by Syms.SymInit at compile-start (not at Def's module load time),
   so this must read them live rather than caching into a table at init. *)
PROCEDURE PrimTypeOf(form: INTEGER): Syms.TypeDesc;
BEGIN
  CASE form OF
    Syms.TFInteger:  RETURN Syms.TypeInteger
  | Syms.TFBoolean:  RETURN Syms.TypeBoolean
  | Syms.TFChar:     RETURN Syms.TypeChar
  | Syms.TFByte:     RETURN Syms.TypeByte
  | Syms.TFWord:     RETURN Syms.TypeWord
  | Syms.TFLongint:  RETURN Syms.TypeLongint
  | Syms.TFReal:     RETURN Syms.TypeReal
  | Syms.TFLongreal: RETURN Syms.TypeLongreal
  | Syms.TFSet:      RETURN Syms.TypeSet
  | Syms.TFAddress:  RETURN Syms.TypeAddress
  | Syms.TFNotype:   RETURN Syms.TypeNotype
  ELSE RETURN NIL
  END
END PrimTypeOf;

(* Linear scan over the primitive-form-name table; returns NIL if tname is
   not one of the primitive scalar keywords. *)
PROCEDURE FindPrimType(VAR tname: ARRAY OF CHAR): Syms.TypeDesc;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < 16 DO
    IF (primFormName[k][0] # 0X) & Strings.Equal(tname, primFormName[k]) THEN
      RETURN PrimTypeOf(k)
    END;
    INC(k)
  END;
  RETURN NIL
END FindPrimType;

PROCEDURE ResolveTypeName(VAR tname: ARRAY OF CHAR): Syms.TypeDesc;
  VAR s: Syms.Symbol; qn: ARRAY QNameLen OF CHAR; rec: Syms.TypeDesc; pt: Syms.TypeDesc;
BEGIN
  pt := FindPrimType(tname);
  IF pt # NIL THEN RETURN pt END;
  IF Strings.Equal(tname, "ARRAY")    THEN
    RETURN Syms.TypeNewArray(Syms.TypeChar, LONGINT(-1))
  END;
  (* If tname is already qualified (contains '.'), look it up directly.
     If not found yet, create a forward RECORD stub so POINTER types are
     well-formed before the referenced module's def is loaded. *)
  IF HasDotChar(tname) THEN
    s := Syms.SymFind(tname);
    IF (s # Syms.NoSym) & (s.kind = Syms.KType) THEN RETURN s.type END;
    rec := Syms.TypeNewRecord(Syms.NoType);
    s := Syms.SymNew(tname, Syms.KType);
    s.type := rec; s.exported := TRUE;
    RETURN rec
  END;
  IF curAlias[0] # 0X THEN
    BuildQName(curAlias, tname, qn);
    s := Syms.SymFind(qn);
    IF (s # Syms.NoSym) & (s.kind = Syms.KType) THEN RETURN s.type END
  END;
  s := Syms.SymFind(tname);
  IF (s # Syms.NoSym) & (s.kind = Syms.KType) THEN RETURN s.type END;
  LogErr.Warn2("unknown type in .def: ", tname);
  RETURN Syms.TypeInteger
END ResolveTypeName;

PROCEDURE ParseDefType(line: ARRAY OF CHAR; VAR i: INTEGER): Syms.TypeDesc;
  VAR tok: ARRAY QNameLen OF CHAR; alen: LONGINT; pty: Syms.TypeDesc;
BEGIN
  ReadToken(line, i, tok);
  IF Strings.Equal(tok, "POINTER") THEN
    RETURN Syms.TypeNewPointer(ParseDefType(line, i))
  END;
  IF Strings.Equal(tok, "PROC") THEN
    (* "PROC" — FAR proc value (4 bytes); signature not serialised.
       NEAR procs cannot be exported, so cross-module proc types are FAR. *)
    pty := Syms.TypeNewProc(Syms.TypeNotype);
    pty.isFar := TRUE; pty.size := Syms.SzPointer;
    RETURN pty
  END;
  IF Strings.Equal(tok, "ARRAY") THEN
    (* Forms accepted:
         ARRAY N OF <elem>   — fixed-size, explicit element type
         ARRAY OF <elem>     — open array, explicit element type
         ARRAY N             — legacy: fixed-size, element defaults to CHAR
         ARRAY               — legacy: open array of CHAR                *)
    alen := LONGINT(-1);
    SkipWS(line, i);
    IF (line[i] >= "0") & (line[i] <= "9") THEN
      alen := ReadLong(line, i);
      SkipWS(line, i)
    END;
    IF (line[i] = "O") & (line[i+1] = "F") &
       ((line[i+2] = " ") OR (line[i+2] = 09X)) THEN
      INC(i, 2); SkipWS(line, i);
      RETURN Syms.TypeNewArray(ParseDefType(line, i), alen)
    END;
    RETURN Syms.TypeNewArray(Syms.TypeChar, alen)
  END;
  RETURN ResolveTypeName(tok)
END ParseDefType;

(* Pre-pass helper: register RECORD stubs from an already-read line buffer. *)
PROCEDURE TryRegisterRecordStub(pline: ARRAY OF CHAR; alias: ARRAY OF CHAR;
                                 modSeen: BOOLEAN);
  VAR i: INTEGER; pkw, pfull, pshort, psubkw: ARRAY QNameLen OF CHAR;
      pqn: ARRAY QNameLen OF CHAR; ps: Syms.Symbol;
BEGIN
  IF ~modSeen THEN RETURN END;
  i := 0; ReadToken(pline, i, pkw);
  IF Strings.Equal(pkw, "TYPE") THEN
    ReadToken(pline, i, pfull);
    ReadToken(pline, i, psubkw);
    IF Strings.Equal(psubkw, "RECORD") THEN
      MakeShort(pfull, pshort);
      BuildQName(alias, pshort, pqn);
      ps := Syms.SymFind(pqn);
      IF ps = Syms.NoSym THEN
        ps := Syms.SymNew(pqn, Syms.KType);
        ps.type     := Syms.TypeNewRecord(Syms.NoType);
        ps.exported := TRUE;
        ps.modId := StrTab.Intern(alias)
      END
    END
  END
END TryRegisterRecordStub;

PROCEDURE DefRead*(VAR f: Files.File; alias: ARRAY OF CHAR);
  VAR line: ARRAY 512 OF CHAR;
      kw, tok, fullname, shortname: ARRAY QNameLen OF CHAR;
      qname: ARRAY QNameLen OF CHAR;
      modname: ARRAY NameLen OF CHAR;
      pname: ARRAY NameLen OF CHAR;
      i, seg, before: INTEGER;
      curRec:    Syms.TypeDesc;
      curRecSize: LONGINT;
      curProc:   Syms.TypeDesc;
      curInline: Syms.TypeDesc;
      patches:   BasePatch; bp, bpNext: BasePatch;
      s, fs:     Syms.Symbol;
      t, ft, pt, ret, base, rec: Syms.TypeDesc;
      ndHead, ndTail: Syms.InlineNode;
      isVar: BOOLEAN; ofs, v: LONGINT;
      modSeen: BOOLEAN;
BEGIN
  Strings.Copy(alias, curAlias);
  modname[0] := 0X; modSeen := FALSE;
  curRec := Syms.NoType; curRecSize := 0;
  curProc := Syms.NoType; curInline := Syms.NoType;
  patches := NIL;

  (* Pre-pass: register all RECORD stubs so FIELD cross-refs resolve. *)
  WHILE Files.ReadLine(f, line, 512) > 0 DO
    i := 0; ReadToken(line, i, kw);
    IF Strings.Equal(kw, "MODULE") THEN modSeen := TRUE END;
    TryRegisterRecordStub(line, alias, modSeen)
  END;
  Files.Seek(f, LONGINT(0));

  (* Main pass *)
  WHILE Files.ReadLine(f, line, 512) > 0 DO
    i := 0; ReadToken(line, i, kw);
    IF kw[0] = 0X THEN (* blank *)
    ELSIF Strings.Equal(kw, "END") THEN
      IF curRec # Syms.NoType THEN
        curRec.size := curRecSize; curRec := Syms.NoType
      ELSIF curInline # Syms.NoType THEN
        Syms.TypeCalcArgSize(curInline); curInline := Syms.NoType
      ELSIF curProc # Syms.NoType THEN
        Syms.TypeCalcArgSize(curProc); curProc := Syms.NoType
      END
    ELSIF Strings.Equal(kw, "BYTES") & (curInline # Syms.NoType) THEN
      ndHead := curInline.inlineList; ndTail := curInline.inlineList;
      (* advance ndTail to the last chunk so InlineAppend appends in order *)
      IF ndTail # NIL THEN WHILE ndTail^.next # NIL DO ndTail := ndTail^.next END END;
      WHILE (line[i] # 0X) & ~LogErr.HaveErr() DO
        SkipWS(line, i);
        IF line[i] # 0X THEN
          (* a malformed token (not 'P'/'p', not a digit/'-') makes ReadLong
             consume nothing, leaving i unchanged and this loop spinning
             forever on a corrupt .def; guard with a no-progress check. *)
          before := i;
          IF (line[i] = 'P') OR (line[i] = 'p') THEN
            INC(i); Syms.InlineAppend(ndHead, ndTail, TRUE, BYTE(0), INTEGER(ReadLong(line, i)))
          ELSE
            Syms.InlineAppend(ndHead, ndTail, FALSE, BYTE(INTEGER(ReadLong(line, i)) MOD 256), 0)
          END;
          IF i = before THEN LogErr.Error("malformed BYTES token in .def") END;
          curInline.inlineList := ndHead; INC(curInline.nInline)
        END
      END
    ELSIF Strings.Equal(kw, "BASE") & (curRec # Syms.NoType) THEN
      ReadToken(line, i, tok);
      NEW(bp); MakeShort(tok, bp^.baseShort);
      bp^.derived := curRec; bp^.next := patches; patches := bp
    ELSIF Strings.Equal(kw, "FIELD") & (curRec # Syms.NoType) THEN
      ReadToken(line, i, pname);
      ft := ParseDefType(line, i);
      ofs := ReadLong(line, i);
      fs := Syms.TypeAddField(curRec, pname, ft);
      fs.offset := ofs
    ELSIF Strings.Equal(kw, "PARAM") & ((curProc # Syms.NoType) OR (curInline # Syms.NoType)) THEN
      IF curProc # Syms.NoType THEN pt := curProc ELSE pt := curInline END;
      SkipWS(line, i);
      isVar := FALSE;
      IF (line[i] = 'T') & (line[i+1] = 'Y') & (line[i+2] = 'P') &
         (line[i+3] = 'E') & (line[i+4] = 'L') & (line[i+5] = 'E') &
         (line[i+6] = 'S') & (line[i+7] = 'S') & (line[i+8] = 'V') &
         (line[i+9] = 'A') & (line[i+10] = 'R') &
         ((line[i+11] = ' ') OR (line[i+11] = 09X)) THEN
        (* typeless VAR: type is ADDRESS, no type token after name *)
        INC(i, 11);
        ReadToken(line, i, pname);
        s := Syms.TypeAddParam(pt, pname, Syms.TypeAddress, TRUE);
        s.typeless := TRUE
      ELSE
        IF (line[i] = 'V') & (line[i+1] = 'A') & (line[i+2] = 'R') &
           ((line[i+3] = ' ') OR (line[i+3] = 09X)) THEN
          isVar := TRUE; INC(i, 3)
        END;
        ReadToken(line, i, pname);
        t := ParseDefType(line, i);
        s := Syms.TypeAddParam(pt, pname, t, isVar)
      END
    ELSIF Strings.Equal(kw, "MODULE") THEN
      ReadToken(line, i, modname)
    ELSIF modname[0] # 0X THEN
      ReadToken(line, i, fullname);
      MakeShort(fullname, shortname);
      BuildQName(alias, shortname, qname);

      IF Strings.Equal(kw, "CONST") THEN
        v := ReadLong(line, i);
        s := Syms.SymNew(qname, Syms.KConst);
        s.val := v;
        IF (v < LONGINT(-32768)) OR (v > LONGINT(32767)) THEN
          s.type := Syms.TypeLongint
        ELSE
          s.type := Syms.TypeInteger
        END;
        s.exported := TRUE; s.modId := StrTab.Intern(alias)
      ELSIF Strings.Equal(kw, "VAR") THEN
        (* Two formats:
             legacy: VAR name seg offset       (no type — defaults to INTEGER)
             new:    VAR name type seg offset  (type carried explicitly)
           Detect by peeking: if next non-WS char is digit, legacy. *)
        SkipWS(line, i);
        IF (line[i] >= "0") & (line[i] <= "9") THEN
          t := Syms.TypeInteger
        ELSE
          t := ParseDefType(line, i)
        END;
        seg := INTEGER(ReadLong(line, i));
        ofs := ReadLong(line, i);
        s := Syms.SymNew(qname, Syms.KVar);
        s.adr := ofs;
        IF seg = SegData THEN s.level := 0 ELSE s.level := 1 END;
        s.type := t;
        s.exported := TRUE; s.modId := StrTab.Intern(alias)
      ELSIF Strings.Equal(kw, "TYPE") THEN
        ReadToken(line, i, tok);
        IF Strings.Equal(tok, "RECORD") THEN
          v := ReadLong(line, i);
          s := Syms.SymFind(qname);
          IF (s # Syms.NoSym) & (s.kind = Syms.KType) & (s.type # Syms.NoType) &
             (s.type.form = Syms.TFRecord) THEN
            rec := s.type; rec.size := 0
          ELSE
            rec := Syms.TypeNewRecord(Syms.NoType);
            s := Syms.SymNew(qname, Syms.KType);
            s.type := rec; s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END;
          curRec := rec; curRecSize := v
        ELSIF Strings.Equal(tok, "POINTER") THEN
          base := ParseDefType(line, i);
          s := Syms.SymFind(qname);
          IF (s # Syms.NoSym) & (s.kind = Syms.KType) THEN
            s.type := Syms.TypeNewPointer(base)
          ELSE
            s := Syms.SymNew(qname, Syms.KType);
            s.type := Syms.TypeNewPointer(base);
            s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END
        ELSIF Strings.Equal(tok, "ADDRESS") THEN
          (* TYPE name ADDRESS — alias to the universe ADDRESS type.
             Must not fall through to opaque-INTEGER branch (size 4, not 2).
             Affects SYSTEM.ADDRESS: every var `: SYSTEM.ADDRESS` is 4 bytes. *)
          s := Syms.SymFind(qname);
          IF s = Syms.NoSym THEN
            s := Syms.SymNew(qname, Syms.KType);
            s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END;
          s.type := Syms.TypeAddress
        ELSIF Strings.Equal(tok, "PRIM") THEN
          (* TYPE name PRIM <builtin> — alias of a primitive built-in type
             (e.g. TYPE X = LONGINT).  Must resolve to the REAL underlying
             form: a bare "TYPE name" with no form info defaults to INTEGER
             (2 bytes), silently truncating a wider alias (LONGINT/REAL/...)
             written through a VAR parameter or global of the alias type. *)
          ft := ParseDefType(line, i);
          s := Syms.SymFind(qname);
          IF s = Syms.NoSym THEN
            s := Syms.SymNew(qname, Syms.KType);
            s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END;
          s.type := ft
        ELSIF Strings.Equal(tok, "ARRAY") THEN
          (* TYPE name ARRAY [N] OF <elem> — array alias.  ReadToken has already
             consumed "ARRAY"; parse the optional length and the element type
             inline (matching the ARRAY case in ParseDefType). *)
          v := LONGINT(-1);
          SkipWS(line, i);
          IF (line[i] >= "0") & (line[i] <= "9") THEN
            v := ReadLong(line, i); SkipWS(line, i)
          END;
          IF (line[i] = "O") & (line[i+1] = "F") &
             ((line[i+2] = " ") OR (line[i+2] = 09X)) THEN
            INC(i, 2); SkipWS(line, i);
            base := Syms.TypeNewArray(ParseDefType(line, i), v)
          ELSE
            base := Syms.TypeNewArray(Syms.TypeChar, v)
          END;
          s := Syms.SymFind(qname);
          IF s = Syms.NoSym THEN
            s := Syms.SymNew(qname, Syms.KType);
            s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END;
          s.type := base
        ELSE
          s := Syms.SymFind(qname);
          IF s = Syms.NoSym THEN
            s := Syms.SymNew(qname, Syms.KType);
            s.type := Syms.TypeInteger;
            s.exported := TRUE; s.modId := StrTab.Intern(alias)
          END
        END
      ELSIF Strings.Equal(kw, "INLINE") THEN
        ret := ParseDefType(line, i);
        pt := Syms.TypeNewProc(ret);
        pt.isInline := TRUE; pt.isFar := FALSE;
        s := Syms.SymNew(qname, Syms.KProc);
        s.codeOfs := 0; s.rdoffId := -1;
        s.type := pt; s.exported := TRUE;
        s.modId := StrTab.Intern(fullname);
        curInline := pt
      ELSIF Strings.Equal(kw, "PROC") THEN
        ReadToken(line, i, tok);
        IF Strings.Equal(tok, "FAR") OR Strings.Equal(tok, "NEAR") THEN
          ret := ParseDefType(line, i);
          pt  := Syms.TypeNewProc(ret);
          pt.isFar := Strings.Equal(tok, "FAR");
          s := Syms.SymNew(qname, Syms.KProc);
          s.codeOfs := 0; s.rdoffId := -1;
          s.type := pt; s.exported := TRUE;
          s.modId := StrTab.Intern(fullname);
          curProc := pt
        ELSE
          (* legacy: seg offset *)
          seg := INTEGER(ReadLong(line, i));
          ofs := ReadLong(line, i);
          s := Syms.SymNew(qname, Syms.KProc);
          s.codeOfs := ofs; s.rdoffId := -1;
          s.type := Syms.TypeNewProc(Syms.TypeNotype);
          s.exported := TRUE; s.modId := StrTab.Intern(fullname)
        END
      END
    END
  END;

  IF curProc   # Syms.NoType THEN Syms.TypeCalcArgSize(curProc) END;
  IF curInline # Syms.NoType THEN Syms.TypeCalcArgSize(curInline) END;

  (* Resolve deferred BASE links, then free the patch list (per-import temp). *)
  bp := patches;
  WHILE bp # NIL DO
    BuildQName(alias, bp^.baseShort, qname);
    s := Syms.SymFind(qname);
    IF (s = Syms.NoSym) OR (s.kind # Syms.KType) THEN
      s := Syms.SymFind(bp^.baseShort)
    END;
    IF (s # Syms.NoSym) & (s.kind = Syms.KType) & (s.type # Syms.NoType) &
       (s.type.form = Syms.TFRecord) THEN
      bp^.derived.base := s.type
    END;
    bpNext := bp^.next; DISPOSE(bp); bp := bpNext
  END
END DefRead;

BEGIN
  i := 0;
  WHILE i < 16 DO primFormName[i][0] := 0X; INC(i) END;
  primFormName[Syms.TFInteger]  := "INTEGER";
  primFormName[Syms.TFBoolean]  := "BOOLEAN";
  primFormName[Syms.TFChar]     := "CHAR";
  primFormName[Syms.TFByte]     := "BYTE";
  primFormName[Syms.TFWord]     := "WORD";
  primFormName[Syms.TFLongint]  := "LONGINT";
  primFormName[Syms.TFReal]     := "REAL";
  primFormName[Syms.TFLongreal] := "LONGREAL";
  primFormName[Syms.TFSet]      := "SET";
  primFormName[Syms.TFAddress]  := "ADDRESS";
  primFormName[Syms.TFNotype]   := "VOID"
END Def.
