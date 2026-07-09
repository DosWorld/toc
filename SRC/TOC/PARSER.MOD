MODULE Parser;
(*
  Oberon compiler — declaration parsing (CONST/TYPE/VAR/PROCEDURE) and
  module-level code (module init, __init guard, dep calls).
  Expressions: PExpr.  Statements: PStmt.
*)
IMPORT Dos, Files, Err, Scan, Syms, Cgen, Rdoff, Tar, Def, Import,
       PExpr, PStmt, TDbg, Strings, StrTab;

CONST
  NameLen    = 33;
  MaxFwdRefs = 32;

TYPE
  ExtraRdf* = POINTER TO ExtraRdfDesc;
  ExtraRdfDesc* = RECORD
    path*: POINTER TO ARRAY 256 OF CHAR;
    next*: ExtraRdf
  END;

  IdentNode = POINTER TO IdentNodeDesc;
  IdentNodeDesc = RECORD
    name:     ARRAY NameLen OF CHAR;
    exported: BOOLEAN;
    next:     IdentNode
  END;

  InitImpNode = POINTER TO InitImpNodeDesc;
  InitImpNodeDesc = RECORD
    name: ARRAY NameLen OF CHAR;
    next: InitImpNode
  END;

  FwdRef = RECORD
    name: ARRAY NameLen OF CHAR;
    ptr:  Syms.TypeDesc
  END;

VAR
  parserModName*:   ARRAY NameLen OF CHAR;
  parserSystemMode*: BOOLEAN;
  parserEntryProc*: ARRAY NameLen OF CHAR;
  parserStackSize*:   LONGINT;
  parserMinMemPara*:  LONGINT;  (* $M min, rounded up to paragraphs; default 8192 = 128 KiB *)
  parserMaxMemPara*:  LONGINT;  (* $M max, rounded up to paragraphs; default 16384 = 256 KiB *)
  parserMemSet*:      BOOLEAN;  (* TRUE once $M has been seen *)
  extraRdfsHead:    ExtraRdf;
  extraRdfsTail:    ExtraRdf;
  initImpsHead:     InitImpNode;
  initImpsTail:     InitImpNode;
  nInitImps:        INTEGER;
  fwdRefs:          ARRAY MaxFwdRefs OF FwdRef;
  nFwdRefs:         INTEGER;
  curModName:       ARRAY NameLen OF CHAR;

(* ---- syscomment handler ---- *)

PROCEDURE TrimAndCopy(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, j, last: INTEGER;
BEGIN
  i := 0;
  WHILE (src[i] # 0X) & ((src[i] = " ") OR (src[i] = 09X)) DO INC(i) END;
  j := 0; last := -1;
  WHILE (src[i] # 0X) & (j < LEN(dst) - 1) DO
    dst[j] := src[i];
    IF (src[i] # " ") & (src[i] # 09X) THEN last := j END;
    INC(j); INC(i)
  END;
  dst[last + 1] := 0X
END TrimAndCopy;

(* Apply a single +/- toggle directive (currently A, R, D).  Returns the index
   just past the consumed "+" or "-" in val, or -1 on error (caller reports). *)
PROCEDURE ApplyToggle(dir: CHAR; val: ARRAY OF CHAR; i: INTEGER): INTEGER;
BEGIN
  IF val[i] = "+" THEN
    IF dir = "R" THEN PExpr.boundsChk := TRUE
    ELSIF dir = "A" THEN Syms.AlignFields := TRUE
    ELSIF dir = "D" THEN TDbg.SetEnabled(TRUE)
    ELSE RETURN -1
    END;
    RETURN i + 1
  ELSIF val[i] = "-" THEN
    IF dir = "R" THEN PExpr.boundsChk := FALSE
    ELSIF dir = "A" THEN Syms.AlignFields := FALSE
    ELSIF dir = "D" THEN TDbg.SetEnabled(FALSE)
    ELSE RETURN -1
    END;
    RETURN i + 1
  ELSE RETURN -1
  END
END ApplyToggle;

(* Toggle directives (A, R, D) may be combined in one comment, comma-separated:
   (*$A-,R-*), (*$R-,D-*).  Parses "Dir+-[,Dir+-]*" starting at val[0], where
   the first Dir is already known (dir/val holds only the value after it). *)
PROCEDURE ProcessToggleChain(dir: CHAR; val: ARRAY OF CHAR);
  VAR i: INTEGER; nextDir: CHAR;
BEGIN
  i := ApplyToggle(dir, val, 0);
  IF i < 0 THEN PExpr.Error("$ directive requires + or -"); RETURN END;
  WHILE val[i] = "," DO
    INC(i);
    nextDir := val[i];
    IF (nextDir = "A") OR (nextDir = "R") OR (nextDir = "D") THEN
      INC(i);
      i := ApplyToggle(nextDir, val, i);
      IF i < 0 THEN PExpr.Error("$ directive requires + or -"); RETURN END
    ELSE
      PExpr.Error("$ directive: only A, R and D may be combined with ','"); RETURN
    END
  END;
  IF val[i] # 0X THEN PExpr.Error("$ directive: trailing text after toggle chain") END
END ProcessToggleChain;

PROCEDURE ProcessSyscomment(VAR sc: Scan.Scanner);
  VAR dir: CHAR; val: ARRAY 128 OF CHAR; n: LONGINT; i, mi: INTEGER;
      mvals: ARRAY 3 OF LONGINT; hasDigits: BOOLEAN;
      node: ExtraRdf;
BEGIN
  IF sc.sysDir = 0X THEN RETURN END;
  dir := sc.sysDir;
  TrimAndCopy(sc.sysArg, val);
  sc.sysDir := 0X;   (* clear so we don't re-process *)
  sc.sysArg[0] := 0X;

  IF (dir = "R") OR (dir = "A") OR (dir = "D") THEN
    ProcessToggleChain(dir, val)
  ELSIF dir = "M" THEN
    (* $M stack_size, min_memory, max_memory
         stack_size: 1..65535 bytes
         min_memory, max_memory: 0..640*1024 bytes, rounded UP to paragraphs
         min_memory <= max_memory; all three values mandatory. *)
    i := 0; mi := 0;
    WHILE mi < 3 DO
      n := 0; hasDigits := FALSE;
      WHILE (val[i] = " ") OR (val[i] = 09X) DO INC(i) END;
      WHILE (val[i] >= "0") & (val[i] <= "9") DO
        n := n * LONGINT(10) + LONGINT(ORD(val[i]) - ORD("0"));
        hasDigits := TRUE; INC(i)
      END;
      WHILE (val[i] = " ") OR (val[i] = 09X) DO INC(i) END;
      IF ~hasDigits THEN
        PExpr.Error("$M requires 3 comma-separated values: stack,min_memory,max_memory");
        RETURN
      END;
      mvals[mi] := n;
      IF mi < 2 THEN
        IF val[i] # "," THEN
          PExpr.Error("$M requires 3 comma-separated values: stack,min_memory,max_memory");
          RETURN
        END;
        INC(i)
      END;
      INC(mi)
    END;
    IF val[i] # 0X THEN
      PExpr.Error("$M trailing text after third value (expect: stack,min_memory,max_memory)");
      RETURN
    END;
    IF (mvals[0] <= LONGINT(0)) OR (mvals[0] > LONGINT(65536)) THEN
      PExpr.Error("$M stack_size out of range 1..65536"); RETURN
    END;
    IF (mvals[1] < LONGINT(0)) OR (mvals[1] > LONGINT(655360)) THEN
      PExpr.Error("$M min_memory out of range 0..655360"); RETURN
    END;
    IF (mvals[2] < LONGINT(0)) OR (mvals[2] > LONGINT(655360)) THEN
      PExpr.Error("$M max_memory out of range 0..655360"); RETURN
    END;
    IF mvals[1] > mvals[2] THEN
      PExpr.Error("$M min_memory must be <= max_memory"); RETURN
    END;
    parserStackSize  := mvals[0];
    parserMinMemPara := (mvals[1] + LONGINT(15)) DIV LONGINT(16);
    parserMaxMemPara := (mvals[2] + LONGINT(15)) DIV LONGINT(16);
    parserMemSet     := TRUE
  ELSIF dir = "L" THEN
    NEW(node); NEW(node^.path); Strings.Copy(val, node^.path^); node^.next := NIL;
    IF extraRdfsTail # NIL THEN extraRdfsTail^.next := node ELSE extraRdfsHead := node END;
    extraRdfsTail := node
  ELSE
    (* unknown: warn but continue *)
    PExpr.Error("unknown system comment directive")
  END
END ProcessSyscomment;

(* A procedure result type must be a scalar, pointer, or procedure — Oberon-07
   forbids returning arrays or records (they cannot be returned in DX:AX, and
   this dialect does not implement a hidden result-pointer ABI).  Reject them
   with a fatal error rather than silently emitting broken code. *)
PROCEDURE CheckResultType(t: Syms.TypeDesc);
  VAR f: INTEGER;
BEGIN
  IF t # Syms.NoType THEN
    f := t.form;
    IF (f = Syms.TFArray) OR (f = Syms.TFRecord) THEN
      PExpr.Error("procedure result type must be scalar, pointer, or procedure (cannot return an array or record)")
    END
  END
END CheckResultType;

(* ---- ident list helpers ---- *)

PROCEDURE IdListAppend(VAR head: IdentNode; VAR tail: IdentNode;
                        name: ARRAY OF CHAR; exported: BOOLEAN): IdentNode;
  VAR n: IdentNode;
BEGIN
  NEW(n); Strings.Copy(name, n^.name); n^.exported := exported; n^.next := NIL;
  IF tail # NIL THEN tail^.next := n ELSE head := n END;
  tail := n; RETURN head
END IdListAppend;

(* Free an IdentNode list once its names have been consumed into the symbol
   table.  These temp lists are not on any arena chain, so they must be
   DISPOSEd explicitly or they leak one node per declared identifier. *)
PROCEDURE IdListFree(VAR head: IdentNode);
  VAR n, nx: IdentNode;
BEGIN
  n := head;
  WHILE n # NIL DO nx := n^.next; DISPOSE(n); n := nx END;
  head := NIL
END IdListFree;

(* ParseExportedIdentList — the "ident [`*`] {, ident [`*`]}" loop shared by
   record field lists and VAR declarations: append each identifier, mark it
   exported if followed by `*`, and consume a trailing comma between names.
   Stops at the first non-TIdent token (the caller then expects `:`). *)
PROCEDURE ParseExportedIdentList(VAR head, tail: IdentNode);
BEGIN
  WHILE PExpr.sc.sym = Scan.TIdent DO
    head := IdListAppend(head, tail, PExpr.sc.id, FALSE);
    Scan.Next(PExpr.sc);
    IF PExpr.sc.sym = Scan.TStar THEN tail^.exported := TRUE; Scan.Next(PExpr.sc) END;
    IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END
  END
END ParseExportedIdentList;

(* ---- type descriptor emitter ---- *)

PROCEDURE EmitTypeDescriptor(VAR rec: Syms.TypeDesc);
  VAR t: Syms.TypeDesc;
BEGIN
  rec.descOfs := Cgen.CgDpc();
  t := rec;
  WHILE t # Syms.NoType DO Cgen.EmitDataWord(INTEGER(t.tagId)); t := t.base END;
  Cgen.EmitDataWord(0)
END EmitTypeDescriptor;

(* ---- forward declarations ---- *)
PROCEDURE ParseType(VAR out: Syms.TypeDesc); FORWARD;
PROCEDURE ParseDeclSeq; FORWARD;
PROCEDURE ParseStatSeq(retType: Syms.TypeDesc); FORWARD;
PROCEDURE WarnUnusedInScope; FORWARD;

(* ---- ParseType ---- *)

PROCEDURE ParseArrayDim(): LONGINT;
  VAR it: Cgen.Item;
BEGIN
  (* Accept any constant expression (constant folding applies), not just a
     literal or named const.  Allows `ARRAY N+1 OF T`, `ARRAY 4*4 OF T`,
     `ARRAY SIZE(T) OF U`, etc.  Must reduce to a compile-time INTEGER or
     WORD constant. *)
  PExpr.ParseExpression(it);
  IF (it.mode # Cgen.MConst) OR (it.type = Syms.NoType) OR
     ((it.type.form # Syms.TFInteger) & (it.type.form # Syms.TFWord)) THEN
    PExpr.Error("integer constant expression expected as array dimension"); RETURN 1
  END;
  RETURN it.val
END ParseArrayDim;

PROCEDURE ParseFormalPars(VAR pt: Syms.TypeDesc; genSyms: BOOLEAN);
  VAR head, tail, pi: IdentNode; isVar, typelessVar: BOOLEAN;
      ptype: Syms.TypeDesc; p, s: Syms.Symbol;
      nm: ARRAY NameLen OF CHAR;
BEGIN
  PExpr.Expect(Scan.TLparen);
  WHILE (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
    head := NIL; tail := NIL; typelessVar := FALSE;
    isVar := (PExpr.sc.sym = Scan.TVar);
    IF isVar THEN Scan.Next(PExpr.sc) END;
    Strings.Copy(PExpr.sc.id, nm); Scan.Next(PExpr.sc);
    head := IdListAppend(head, tail, nm, FALSE);
    IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END;
    WHILE (PExpr.sc.sym # Scan.TColon) & (PExpr.sc.sym # Scan.TSemi) &
          (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
      Strings.Copy(PExpr.sc.id, nm); Scan.Next(PExpr.sc);
      head := IdListAppend(head, tail, nm, FALSE);
      IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END
    END;
    IF PExpr.sc.sym = Scan.TColon THEN
      Scan.Next(PExpr.sc); ptype := Syms.TypeInteger; ParseType(ptype)
    ELSE
      IF ~isVar THEN PExpr.Error("parameter requires a type") END;
      typelessVar := TRUE; ptype := Syms.TypeAddress
    END;
    pi := head;
    WHILE pi # NIL DO
      p := Syms.TypeAddParam(pt, pi^.name, ptype, isVar);
      p.declLine := PExpr.sc.line;
      IF typelessVar THEN p.typeless := TRUE END;
      IF genSyms THEN
        s := Syms.SymNew(pi^.name, p.kind);
        s.type := ptype;
        s.declLine := PExpr.sc.line;
        IF typelessVar THEN s.typeless := TRUE END
      END;
      pi := pi^.next
    END;
    IdListFree(head);
    IF PExpr.sc.sym = Scan.TSemi THEN Scan.Next(PExpr.sc) END
  END;
  PExpr.Expect(Scan.TRparen)
END ParseFormalPars;

PROCEDURE ParseType;
  VAR sym, tsym, fs: Syms.Symbol; len: LONGINT; elem, base, rec, ft: Syms.TypeDesc;
      tkey: ARRAY 66 OF CHAR; fhead, ftail, fi: IdentNode;
      dims: ARRAY 8 OF LONGINT; ndims: INTEGER;
      modWord: ARRAY 32 OF CHAR; rtmp: Syms.TypeDesc;
BEGIN
  IF PExpr.sc.sym = Scan.TIdent THEN
    sym := Syms.SymFind(PExpr.sc.id); Scan.Next(PExpr.sc);
    IF (sym # Syms.NoSym) & (sym.kind = Syms.KImport) & (PExpr.sc.sym = Scan.TDot) THEN
      Scan.Next(PExpr.sc);
      IF PExpr.sc.sym # Scan.TIdent THEN
        PExpr.Error("type name expected after '.'"); out := Syms.TypeInteger; RETURN
      END;
      StrTab.Get(sym.nameId, tkey); Strings.Append(".", tkey); Strings.Append(PExpr.sc.id, tkey);
      tsym := Syms.SymFind(tkey);
      IF tsym = Syms.NoSym THEN tsym := Syms.SymFind(PExpr.sc.id) END;
      Scan.Next(PExpr.sc);
      IF (tsym = Syms.NoSym) OR (tsym.kind # Syms.KType) THEN
        PExpr.Error("type name expected"); out := Syms.TypeInteger; RETURN
      END;
      out := tsym.type; RETURN
    END;
    IF (sym = Syms.NoSym) OR (sym.kind # Syms.KType) THEN
      PExpr.Error("type name expected"); out := Syms.TypeInteger; RETURN
    END;
    out := sym.type;
    (* If a type symbol has NIL type, it is being defined — its own name appeared
       on the RHS (e.g. TYPE ADDRESS* = ADDRESS).  Resolve via predeclared universe. *)
    IF out = Syms.NoType THEN out := Syms.PredeclTypeId(sym.nameId) END;
    IF (out # Syms.NoType) & ((out.form = Syms.TFReal) OR (out.form = Syms.TFLongreal)) THEN
      PExpr.modUsesFpu := TRUE
    END
  ELSIF PExpr.sc.sym = Scan.TArray THEN
    Scan.Next(PExpr.sc); len := -1;
    IF PExpr.sc.sym # Scan.TOf THEN len := ParseArrayDim() END;
    IF PExpr.sc.sym = Scan.TComma THEN
      (* Multi-dim: ARRAY m, n OF T → ARRAY m OF ARRAY n OF T.
         Consume the comma before reading the next dimension. *)
      Scan.Next(PExpr.sc);
      ndims := 0; dims[ndims] := ParseArrayDim(); INC(ndims);
      WHILE (PExpr.sc.sym = Scan.TComma) & (ndims < 7) DO
        Scan.Next(PExpr.sc); dims[ndims] := ParseArrayDim(); INC(ndims)
      END;
      PExpr.Expect(Scan.TOf); elem := Syms.TypeInteger; ParseType(elem);
      base := elem;
      WHILE ndims > 0 DO DEC(ndims); base := Syms.TypeNewArray(base, dims[ndims]) END;
      out := Syms.TypeNewArray(base, len)
    ELSE
      PExpr.Expect(Scan.TOf); elem := Syms.TypeInteger; ParseType(elem);
      out := Syms.TypeNewArray(elem, len)
    END
  ELSIF PExpr.sc.sym = Scan.TRecord THEN
    Scan.Next(PExpr.sc); base := NIL;
    IF PExpr.sc.sym = Scan.TLparen THEN
      Scan.Next(PExpr.sc); ParseType(base); PExpr.Expect(Scan.TRparen)
    END;
    rec := Syms.TypeNewRecord(base);
    WHILE PExpr.sc.sym = Scan.TIdent DO
      fhead := NIL; ftail := NIL;
      ParseExportedIdentList(fhead, ftail);
      PExpr.Expect(Scan.TColon); ft := Syms.TypeInteger; ParseType(ft);
      fi := fhead;
      WHILE fi # NIL DO
        fs := Syms.TypeAddField(rec, fi^.name, ft);
        fs.exported := fi^.exported;
        fi := fi^.next
      END;
      IdListFree(fhead);
      IF PExpr.sc.sym = Scan.TSemi THEN Scan.Next(PExpr.sc) END
    END;
    PExpr.Expect(Scan.TEnd); EmitTypeDescriptor(rec); out := rec
  ELSIF PExpr.sc.sym = Scan.TPointer THEN
    Scan.Next(PExpr.sc); PExpr.Expect(Scan.TTo);
    IF (PExpr.sc.sym = Scan.TIdent) & (Syms.SymFind(PExpr.sc.id) = Syms.NoSym) THEN
      out := Syms.TypeNewPointer(Syms.TypeNotype);
      IF nFwdRefs < MaxFwdRefs THEN
        Strings.Copy(PExpr.sc.id, fwdRefs[nFwdRefs].name);
        fwdRefs[nFwdRefs].ptr := out; INC(nFwdRefs)
      ELSE PExpr.Error("too many forward type references") END;
      Scan.Next(PExpr.sc)
    ELSE
      base := Syms.TypeInteger; ParseType(base); out := Syms.TypeNewPointer(base)
    END
  ELSIF PExpr.sc.sym = Scan.TProcedure THEN
    Scan.Next(PExpr.sc);
    out := Syms.TypeNewProc(Syms.TypeNotype);
    (* Optional FAR/NEAR modifier on procedure type; default FAR. *)
    out.isFar := TRUE; out.size := Syms.SzPointer;
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, modWord);
      IF modWord = "FAR" THEN
        Scan.Next(PExpr.sc)
      ELSIF modWord = "NEAR" THEN
        out.isFar := FALSE; out.size := 2; Scan.Next(PExpr.sc)
      END
    END;
    IF PExpr.sc.sym = Scan.TLparen THEN ParseFormalPars(out, FALSE) END;
    IF PExpr.sc.sym = Scan.TColon THEN
      Scan.Next(PExpr.sc); rtmp := Syms.TypeInteger; ParseType(rtmp);
      CheckResultType(rtmp);
      out.retType := rtmp
    END;
    Syms.TypeCalcArgSize(out)
  ELSE
    PExpr.Error("type expected"); out := Syms.TypeInteger
  END
END ParseType;

(* ---- CONST declaration ---- *)

PROCEDURE ParseConstDecl;
  VAR name: ARRAY NameLen OF CHAR; exported: BOOLEAN; val: Cgen.Item; s: Syms.Symbol;
BEGIN
  WHILE PExpr.sc.sym = Scan.TIdent DO
    Strings.Copy(PExpr.sc.id, name); Scan.Next(PExpr.sc);
    IF Syms.SymFindLocal(name) # NIL THEN PExpr.Error2("duplicate identifier", name) END;
    exported := FALSE;
    IF PExpr.sc.sym = Scan.TStar THEN exported := TRUE; Scan.Next(PExpr.sc) END;
    PExpr.Expect(Scan.TEql); PExpr.ParseExpression(val);
    (* A CONST must be an integer-family compile-time value: INTEGER, LONGINT,
       WORD, or BYTE.  CHAR/BOOLEAN/REAL/LONGREAL/SET constants and string,
       array, record, or pointer constants are rejected — use a literal at the
       use site instead. *)
    IF (val.type = Syms.NoType) OR
       ((val.type.form # Syms.TFInteger) & (val.type.form # Syms.TFLongint) &
        (val.type.form # Syms.TFWord) & (val.type.form # Syms.TFByte)) THEN
      PExpr.Error2("CONST must be an integer (INTEGER/LONGINT/WORD/BYTE) value", name)
    END;
    s := Syms.SymNew(name, Syms.KConst);
    s.exported := exported; s.type := val.type;
    IF val.mode = Cgen.MConst THEN s.val := val.val; s.adr := val.adr
    ELSIF val.mode = Cgen.MGlobal THEN s.val := 0; s.adr := val.adr
    ELSE s.val := 0; s.adr := 0 END;
    IF PExpr.sc.sym = Scan.TSemi THEN Scan.Next(PExpr.sc) END
  END
END ParseConstDecl;

(* ---- TYPE declaration ---- *)

PROCEDURE ParseTypeDecl;
  VAR name: ARRAY NameLen OF CHAR; exported: BOOLEAN;
      placeholder, t: Syms.TypeDesc; s, fsym: Syms.Symbol; i: INTEGER;
BEGIN
  nFwdRefs := 0;
  WHILE PExpr.sc.sym = Scan.TIdent DO
    Strings.Copy(PExpr.sc.id, name); Scan.Next(PExpr.sc);
    IF Syms.SymFindLocal(name) # Syms.NoSym THEN PExpr.Error2("duplicate identifier", name) END;
    exported := FALSE;
    IF PExpr.sc.sym = Scan.TStar THEN exported := TRUE; Scan.Next(PExpr.sc) END;
    (* Pre-register placeholder so self-referential pointers (POINTER TO T inside T)
       resolve to the same TypeDesc and stay valid after the real type is parsed. *)
    placeholder := Syms.TypeNew(Syms.TFNotype, 0);
    placeholder.size := 4; placeholder.align := 2;
    s := Syms.SymNew(name, Syms.KType);
    s.type := placeholder; s.exported := exported;
    PExpr.Expect(Scan.TEql); t := Syms.TypeInteger; ParseType(t);
    (* Self-referential alias (e.g. TYPE ADDRESS* = ADDRESS): ParseType sees the
       placeholder we just registered and returns it unchanged (still TFNotype).
       Resolve through the predeclared universe so the real built-in type is used. *)
    IF t = placeholder THEN
      t := Syms.PredeclType(name);
      IF t = Syms.NoType THEN t := placeholder END
    END;
    (* Patch placeholder in place: any pointer that captured placeholder
       (e.g. a POINTER TO T field parsed before the RECORD body) must see
       the real type contents.  Whole-record assignment is not supported
       by the codegen for pointer-deref records, so use the field-by-field
       helper from Syms to patch the placeholder. *)
    Syms.TypeCopyFields(placeholder, t);
    (* Redirect forward-ref entries that point to `t` (a stub created during
       ParseType above) to point to `placeholder` instead.  After this loop
       the stub is orphaned but the symbol's placeholder is the authoritative
       TypeDesc. *)
    i := 0;
    WHILE i < nFwdRefs DO
      IF fwdRefs[i].ptr = t THEN fwdRefs[i].ptr := placeholder END;
      INC(i)
    END;
    (* debug info: TYPEDEF symbol for every module-level named TYPE decl
       (exported AND non-exported — same policy as module VARs). Local
       (procedure-nested) TYPE decls are out of scope for now, matching the
       existing locals/scopes deferral. *)
    IF (Syms.TopScope^.level = 0) & TDbg.Enabled() THEN
      TDbg.AddSymT("Y", "-", 0, TDbg.TypeIndex(placeholder), name)
    END;
    IF PExpr.sc.sym = Scan.TSemi THEN Scan.Next(PExpr.sc) END
  END;
  (* Resolve forward POINTER TO <name> references *)
  i := 0;
  WHILE i < nFwdRefs DO
    fsym := Syms.SymFind(fwdRefs[i].name);
    IF (fsym = Syms.NoSym) OR (fsym.kind # Syms.KType) THEN
      PExpr.Error2("unresolved forward type reference", fwdRefs[i].name)
    ELSE fwdRefs[i].ptr.base := fsym.type END;
    INC(i)
  END;
  nFwdRefs := 0
END ParseTypeDecl;

(* ---- VAR declaration ---- *)

PROCEDURE ParseVarDecl;
  VAR head, tail, it: IdentNode; t: Syms.TypeDesc; s: Syms.Symbol;
      gname: ARRAY 66 OF CHAR;
BEGIN
  WHILE PExpr.sc.sym = Scan.TIdent DO
    head := NIL; tail := NIL;
    ParseExportedIdentList(head, tail);
    PExpr.Expect(Scan.TColon); t := Syms.TypeInteger; ParseType(t);
    it := head;
    WHILE it # NIL DO
      IF Syms.SymFindLocal(it^.name) # Syms.NoSym THEN PExpr.Error2("duplicate identifier", it^.name) END;
      s := Syms.SymNew(it^.name, Syms.KVar);
      s.exported := it^.exported; s.type := t;
      s.declLine := PExpr.sc.line;
      IF Syms.TopScope^.level = 0 THEN
        s.adr := Cgen.CgDpc(); Cgen.EmitDataZero(INTEGER(t.size));
        (* debug info: module-level VAR — all globals live in SegData ('D') *)
        TDbg.AddSymT("V", "D", WORD(s.adr), TDbg.TypeIndex(t), it^.name);
        IF s.exported THEN
          Strings.Copy(parserModName, gname); Strings.Append("_", gname); Strings.Append(it^.name, gname);
          Rdoff.RdfAddGlobal(Cgen.CgObj, gname, Rdoff.SegData, s.adr)
        END
      ELSE Syms.SymAllocLocal(s) END;
      it := it^.next
    END;
    IdListFree(head);
    IF PExpr.sc.sym = Scan.TSemi THEN Scan.Next(PExpr.sc) END
  END
END ParseVarDecl;

(* ---- PROCEDURE declaration ---- *)

PROCEDURE ParseProcDecl;
  VAR name: ARRAY NameLen OF CHAR;
      gname: ARRAY 66 OF CHAR;  (* modName_funcName: up to 2*NameLen *)
      sym, existing, p, s: Syms.Symbol;
      exported: BOOLEAN; pt: Syms.TypeDesc;
      prologuePatch: LONGINT;
      savedRetList: PStmt.BpNode;
      savedProloguePatch: LONGINT; savedProcDepth: INTEGER;
      skipNested: Cgen.Backpatch;
      inlNode, inlTail: Syms.InlineNode;
      idx: INTEGER; fp: Syms.Symbol; found: BOOLEAN;
      wordA: ARRAY 16 OF CHAR; wid: WORD;
      rtmp: Syms.TypeDesc; nInl: INTEGER;
BEGIN
  Scan.Next(PExpr.sc);  (* consume PROCEDURE *)
  IF PExpr.sc.sym # Scan.TIdent THEN PExpr.Error("procedure name expected"); RETURN END;
  Strings.Copy(PExpr.sc.id, name); Scan.Next(PExpr.sc);

  (* Implementation of forward-declared proc: "PROCEDURE name;" only *)
  existing := Syms.SymFindLocal(name);
  IF (existing # Syms.NoSym) & existing.fwdDecl THEN
    PExpr.Expect(Scan.TSemi);
    sym := existing; pt := existing.type; exported := existing.exported;
    Syms.SymOpenScope();
    p := pt.params;
    WHILE p # Syms.NoSym DO
      s := Syms.SymNewId(p.nameId, p.kind);
      s.type := p.type; s.adr := p.adr; s.typeless := p.typeless;
      s.declLine := p.declLine;
      p := p.next
    END
  ELSE
    IF existing # Syms.NoSym THEN PExpr.Error2("duplicate name", name) END;
    sym := Syms.SymNew(name, Syms.KProc);
    sym.declLine := PExpr.sc.line;
    exported := FALSE;
    IF PExpr.sc.sym = Scan.TStar THEN exported := TRUE; Scan.Next(PExpr.sc);
      sym.exported := TRUE END;
    pt := Syms.TypeNewProc(Syms.TypeNotype);
    sym.type := pt;
    Syms.SymOpenScope();
    IF PExpr.sc.sym = Scan.TLparen THEN ParseFormalPars(pt, TRUE) END;
    IF PExpr.sc.sym = Scan.TColon THEN Scan.Next(PExpr.sc);
      rtmp := Syms.TypeInteger; ParseType(rtmp);
      CheckResultType(rtmp);
      pt.retType := rtmp END;
    IF exported THEN pt.isFar := TRUE END;
    PExpr.Expect(Scan.TSemi);

    (* FAR/NEAR modifier *)
    wordA := "";
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, wordA);
      IF wordA = "FAR" THEN
        pt.isFar := TRUE; Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi)
      ELSIF wordA = "NEAR" THEN
        IF exported THEN PExpr.Error("exported procedure cannot be NEAR") END;
        pt.isFar := FALSE; Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi)
      END
    END;

    (* FORWARD / EXTERNAL / INLINE — one token peek, one dispatch *)
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, wordA);
      IF wordA = "FORWARD" THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi);
        Syms.TypeCalcArgSize(pt);
        sym.fwdDecl := TRUE;
        Syms.SymCloseScope(); RETURN
      ELSIF wordA = "EXTERNAL" THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi);
        Syms.TypeCalcArgSize(pt);
        Strings.Copy(parserModName, gname); Strings.Append("_", gname); Strings.Append(name, gname);
        sym.rdoffId := Rdoff.RdfAddImport(Cgen.CgObj, gname);
        sym.codeOfs := 0;
        Syms.SymCloseScope(); RETURN
      ELSIF wordA = "INLINE" THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TLparen);
        inlNode := NIL; inlTail := NIL; nInl := 0;
        WHILE (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
          IF PExpr.sc.sym = Scan.TInt THEN
            Syms.InlineAppend(inlNode, inlTail, FALSE, BYTE(INTEGER(PExpr.sc.ival) MOD 256), 0);
            INC(nInl); Scan.Next(PExpr.sc)
          ELSIF PExpr.sc.sym = Scan.TIdent THEN
            wid := StrTab.Find(PExpr.sc.id);   (* 0 (unknown) matches no param *)
            idx := 0; fp := pt.params; found := FALSE;
            WHILE fp # Syms.NoSym DO
              IF fp.nameId = wid THEN found := TRUE; fp := Syms.NoSym
              ELSE INC(idx); fp := fp.next END
            END;
            IF ~found THEN PExpr.Error("unknown parameter name in INLINE") END;
            Syms.InlineAppend(inlNode, inlTail, TRUE, BYTE(0), idx);
            INC(nInl); Scan.Next(PExpr.sc)
          ELSE PExpr.Error("byte literal or parameter name expected"); Scan.Next(PExpr.sc) END;
          IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END
        END;
        PExpr.Expect(Scan.TRparen); PExpr.Expect(Scan.TSemi);
        pt.isInline := TRUE; pt.inlineList := inlNode;
        pt.nInline := nInl;
        Syms.TypeCalcArgSize(pt);
        Syms.SymCloseScope(); RETURN
      END
    END
  END;

  (* emit body *)
  Syms.TypeCalcArgSize(pt);
  (* copy BP offsets from pt^.params into scope symbols *)
  p := pt.params;
  WHILE p # Syms.NoSym DO
    s := Syms.SymFindLocalId(p.nameId);
    IF s # Syms.NoSym THEN s.adr := p.adr END;
    p := p.next
  END;

  sym.codeOfs := Cgen.CgPc();
  IF exported THEN
    Strings.Copy(parserModName, gname); Strings.Append("_", gname); Strings.Append(name, gname);
    Rdoff.RdfAddGlobal(Cgen.CgObj, gname, Rdoff.SegCode, sym.codeOfs)
  END;

  (* save outer context *)
  savedRetList := PStmt.retPatchList;
  savedProloguePatch := PStmt.curProloguePatch;
  savedProcDepth := PStmt.curProcDepth;

  INC(PStmt.curProcDepth);
  PStmt.retPatchList := NIL;

  (* debug info: procedure symbol at its code entry (before prologue) *)
  TDbg.AddSym("P", "C", WORD(Cgen.CgPc()), name);
  prologuePatch := Cgen.CgPc() + LONGINT(5);
  PStmt.curProloguePatch := prologuePatch;
  Cgen.CgPrologue(0);

  Cgen.CgJmpNear(skipNested);
  ParseDeclSeq();
  Cgen.CgPatchNear(skipNested);
  PStmt.curProloguePatch := prologuePatch;

  PStmt.PatchFrameSize;

  IF PExpr.sc.sym = Scan.TBegin THEN
    Scan.Next(PExpr.sc); ParseStatSeq(pt.retType)
  END;
  PExpr.Expect(Scan.TEnd);
  IF PExpr.sc.sym = Scan.TIdent THEN
    IF PExpr.sc.id # name THEN PExpr.Error("procedure name mismatch") END;
    Scan.Next(PExpr.sc)
  END;

  PStmt.BpPatchFree(PStmt.retPatchList);
  IF pt.isFar THEN Cgen.CgEpilogueFar(INTEGER(pt.argSize))
  ELSE Cgen.CgEpilogue(INTEGER(pt.argSize)) END;
  WarnUnusedInScope;
  (* debug info: this procedure's params + locals (class AUTO), then close
     its scope with the proc's own code length.  Emitted here (into the same
     flat stream as the proc's own 'P' symbol, right after it) so the linker
     can build one SCOPE_RECORD per procedure without a second file scan. *)
  IF TDbg.Enabled() THEN
    s := Syms.TopScope^.symbols;
    WHILE s # Syms.NoSym DO
      IF (s.kind = Syms.KParam) OR (s.kind = Syms.KVarParam) OR (s.kind = Syms.KVar) THEN
        StrTab.Get(s.nameId, gname);
        TDbg.AddLocalSym(s.adr, TDbg.TypeIndex(s.type), gname)
      END;
      s := s.next
    END;
    TDbg.EndScope(WORD(Cgen.CgPc() - sym.codeOfs))
  END;
  Syms.SymCloseScope();

  PStmt.retPatchList := savedRetList;
  PStmt.curProloguePatch := savedProloguePatch;
  PStmt.curProcDepth := savedProcDepth;

  IF sym.fwdDecl THEN
    PExpr.FwdPatchCalls(sym, sym.codeOfs);
    sym.fwdDecl := FALSE
  END;
  PExpr.Expect(Scan.TSemi)
END ParseProcDecl;

(* ---- DeclSeq ---- *)

PROCEDURE ParseDeclSeq;
BEGIN
  ProcessSyscomment(PExpr.sc);
  (* Declaration sequence: accepts CONST/TYPE/VAR/PROCEDURE in any order,
     repeated.  The Oberon-07 spec is stricter (each section at most once
     and in order), but the test suite relies on permissive ordering
     (e.g. VAR after nested PROCEDURE blocks). *)
  WHILE (PExpr.sc.sym = Scan.TConst) OR (PExpr.sc.sym = Scan.TType) OR
        (PExpr.sc.sym = Scan.TVar)   OR (PExpr.sc.sym = Scan.TProcedure) DO
    IF PExpr.sc.sym = Scan.TConst THEN
      Scan.Next(PExpr.sc); ParseConstDecl
    ELSIF PExpr.sc.sym = Scan.TType THEN
      Scan.Next(PExpr.sc); ParseTypeDecl
    ELSIF PExpr.sc.sym = Scan.TVar THEN
      Scan.Next(PExpr.sc); ParseVarDecl
    ELSE
      ParseProcDecl
    END;
    ProcessSyscomment(PExpr.sc)
  END
END ParseDeclSeq;

PROCEDURE ParseStatSeq;
BEGIN
  PStmt.ParseStatementSequence(retType)
END ParseStatSeq;

(* ---- sanitise-import pass (CLAUDE.md "Pending #1") --------------------- *)

(* TRUE iff `name` ends with "__init" (length >= 7). *)
PROCEDURE EndsWithInit(VAR name: ARRAY OF CHAR; nl: INTEGER): BOOLEAN;
BEGIN
  RETURN (nl >= 7) &
         (name[nl - 6] = "_") & (name[nl - 5] = "_") & (name[nl - 4] = "i") &
         (name[nl - 3] = "n") & (name[nl - 2] = "i") & (name[nl - 1] = "t")
END EndsWithInit;

(* TRUE iff some IMPORT record refers to a symbol from `modName`
   OTHER than its own __init.  modLen = length of modName (no nul). *)
PROCEDURE HasOtherImportFromMod(modName: ARRAY OF CHAR; modLen: INTEGER): BOOLEAN;
  VAR imp: Rdoff.ImportNode; nl, j: INTEGER; matches: BOOLEAN;
BEGIN
  imp := Cgen.CgObj^.importHead;
  WHILE imp # NIL DO
    nl := Strings.Length(imp^.name);
    IF (nl > modLen + 1) & (imp^.name[modLen] = "_") THEN
      matches := TRUE; j := 0;
      WHILE (j < modLen) & matches DO
        IF imp^.name[j] # modName[j] THEN matches := FALSE END;
        INC(j)
      END;
      IF matches & ~EndsWithInit(imp^.name, nl) THEN RETURN TRUE END
    END;
    imp := imp^.next
  END;
  RETURN FALSE
END HasOtherImportFromMod;

(* Patch the 5-byte CALL FAR at code offset `base` to 5 NOPs. *)
PROCEDURE PatchCallToNops(base: LONGINT);
BEGIN
  Rdoff.PatchCodeByte(Cgen.CgObj, base,            BYTE(090H));
  Rdoff.PatchCodeByte(Cgen.CgObj, base + LONGINT(1), BYTE(090H));
  Rdoff.PatchCodeByte(Cgen.CgObj, base + LONGINT(2), BYTE(090H));
  Rdoff.PatchCodeByte(Cgen.CgObj, base + LONGINT(3), BYTE(090H));
  Rdoff.PatchCodeByte(Cgen.CgObj, base + LONGINT(4), BYTE(090H))
END PatchCallToNops;

PROCEDURE WarnUnusedInScope;
  VAR s: Syms.Symbol; what: ARRAY 96 OF CHAR;
      nbuf: ARRAY Syms.NameLen OF CHAR;
BEGIN
  IF Syms.TopScope = NIL THEN RETURN END;
  s := Syms.TopScope^.symbols;
  WHILE s # Syms.NoSym DO
    StrTab.Get(s.nameId, nbuf);
    IF ~s.exported & (nbuf[0] # "$") &
       (s.readCount = WORD(0)) &
       (s.kind # Syms.KImport) & (s.kind # Syms.KConst) &
       (s.kind # Syms.KType) & (s.kind # Syms.KField) &
       (s.kind # Syms.KSysProc) &
       ~s.fwdDecl &
       ~((s.kind = Syms.KProc) & (s.type # Syms.NoType) & s.type.isInline) THEN
      IF s.kind = Syms.KVar THEN Strings.Copy("variable", what)
      ELSIF s.kind = Syms.KParam THEN Strings.Copy("parameter", what)
      ELSIF s.kind = Syms.KVarParam THEN Strings.Copy("VAR parameter", what)
      ELSIF s.kind = Syms.KProc THEN Strings.Copy("procedure", what)
      ELSE Strings.Copy("identifier", what) END;
      Strings.Append(" '", what);
      Strings.Append(nbuf, what);
      Strings.Append("' declared but never used", what);
      Err.WarnInFile(PExpr.sc.filename, LONGINT(s.declLine), what)
    END;
    s := s.next
  END
END WarnUnusedInScope;

(* For each IMPORT "<Mod>__init" with no sibling "<Mod>_xxx" reference:
     patch its CALL FAR site(s) to NOPs, then drop the RELOC + SEGRELOC
     records and the IMPORT record itself. *)
PROCEDURE SanitizeImports;
  VAR imp, impPrev, impNext: Rdoff.ImportNode;
      r: Rdoff.RelocNode;
      nl, modLen: INTEGER;
      modBuf: ARRAY 40 OF CHAR;
      deadId: INTEGER;
      base: LONGINT;
      stillUsed: BOOLEAN;
      k, j: INTEGER;
BEGIN
  (* First pass: for each <Mod>__init with no sibling refs,
     patch+remove its RELOC/SEGRELOC records. *)
  imp := Cgen.CgObj^.importHead;
  WHILE imp # NIL DO
    nl := Strings.Length(imp^.name);
    IF EndsWithInit(imp^.name, nl) THEN
      modLen := nl - 6;
      (* copy module-name prefix into modBuf *)
      k := 0;
      WHILE k < modLen DO modBuf[k] := imp^.name[k]; INC(k) END;
      modBuf[modLen] := 0X;
      IF ~HasOtherImportFromMod(modBuf, modLen) THEN
        deadId := imp^.segId;
        (* delete every reloc whose rseg = deadId by compacting the chunk's
           parallel arrays: shift entries [k+1..count-1] down over slot k and
           DEC(count) (order-preserving; re-check slot k after the shift). *)
        r := Cgen.CgObj^.relocHead;
        WHILE r # NIL DO
          k := 0;
          WHILE k < r^.count DO
            IF r^.rseg[k] = deadId THEN
              IF SYSTEM.AND(r^.physSeg[k], BYTE(080H)) # BYTE(0) THEN
                base := r^.offset[k] - LONGINT(3)   (* SEGRELOC: base = offset - 3 *)
              ELSE
                base := r^.offset[k] - LONGINT(1)   (* RELOC: base = offset - 1 *)
              END;
              PatchCallToNops(base);
              j := k;
              WHILE j < r^.count - 1 DO
                r^.physSeg[j] := r^.physSeg[j+1]; r^.offset[j] := r^.offset[j+1];
                r^.width[j]   := r^.width[j+1];   r^.rseg[j]   := r^.rseg[j+1];
                INC(j)
              END;
              DEC(r^.count); DEC(Cgen.CgObj^.nRelocs)
              (* do NOT INC(k): slot k now holds the shifted-down entry *)
            ELSE
              INC(k)
            END
          END;
          r := r^.next
        END
      END
    END;
    imp := imp^.next
  END;

  (* Second pass: drop IMPORT records whose seg_id no longer appears
     in any reloc.  Only <Mod>__init imports are candidates. *)
  imp := Cgen.CgObj^.importHead; impPrev := NIL;
  WHILE imp # NIL DO
    impNext := imp^.next;
    nl := Strings.Length(imp^.name);
    IF EndsWithInit(imp^.name, nl) THEN
      stillUsed := FALSE;
      r := Cgen.CgObj^.relocHead;
      WHILE (r # NIL) & ~stillUsed DO
        k := 0;
        WHILE k < r^.count DO
          IF r^.rseg[k] = imp^.segId THEN stillUsed := TRUE END; INC(k)
        END;
        r := r^.next
      END;
      IF ~stillUsed THEN
        IF impPrev # NIL THEN impPrev^.next := impNext
        ELSE Cgen.CgObj^.importHead := impNext END;
        IF imp = Cgen.CgObj^.importTail THEN
          Cgen.CgObj^.importTail := impPrev
        END;
        DEC(Cgen.CgObj^.nImports);
        DISPOSE(imp)   (* node unlinked from CgObj list; free it so it does not leak *)
      ELSE
        impPrev := imp
      END
    ELSE
      impPrev := imp
    END;
    imp := impNext
  END
END SanitizeImports;

(* ---- module ---- *)

PROCEDURE ParseModule*(VAR s: Scan.Scanner);
  VAR modName, iname, alias, depInit: ARRAY NameLen OF CHAR;
      isym: Syms.Symbol; hasImports, hasBody: BOOLEAN;
      nbuf: ARRAY Syms.NameLen OF CHAR;
      initName: ARRAY 66 OF CHAR;
      initOfs, guardOfs: LONGINT;
      rdfName, defName, libName, dbgName: ARRAY 40 OF CHAR;
      srcBase: ARRAY 40 OF CHAR;
      rf, df, lf, sf, dg: Files.File;
      dgOpen: BOOLEAN;
      ip, ipNext: InitImpNode;
      er, erNext: ExtraRdf;
      sym: Syms.Symbol;
      req87Id, depImportId: INTEGER;
      addrField: LONGINT;
      i, j: INTEGER; badName: BOOLEAN;
      upName: ARRAY 48 OF CHAR;
      baseStart: INTEGER;
      rfOpen, dfOpen: BOOLEAN;
BEGIN
  PExpr.sc := s;
  Syms.SymInit;
  IF Err.HaveErr() THEN RETURN END;
  Cgen.CgInit;
  IF Err.HaveErr() THEN Syms.SymsFree(); RETURN END;
  Import.ResetLoaded();
  Cgen.EmitDataZero(2);
  PExpr.modUsesFpu := FALSE;
  PExpr.boundsChk := FALSE;
  PStmt.retPatchList := NIL;
  PStmt.curProloguePatch := 0;
  PStmt.curProcDepth := 0;
  (* reset init imports *)
  initImpsHead := NIL; initImpsTail := NIL; nInitImps := 0;
  (* reset extra rdfs *)
  extraRdfsHead := NIL; extraRdfsTail := NIL;

  IF ~parserSystemMode THEN Import.AddImplicitImport("SYSTEM") END;

  (* Handle any system comment that preceded the MODULE keyword
     (e.g. `(*$R+*)` at the top of a file enabling bounds checks). *)
  ProcessSyscomment(PExpr.sc);
  PExpr.Expect(Scan.TModule);
  ProcessSyscomment(PExpr.sc);
  IF PExpr.sc.sym # Scan.TIdent THEN PExpr.Error("module name expected"); RETURN END;
  Strings.Copy(PExpr.sc.id, modName); Scan.Next(PExpr.sc);
  Strings.Copy(modName, parserModName); Strings.Copy(modName, curModName);
  Strings.Copy(modName, PExpr.modName);

  (* Debug-info collection: record module + source-file name.  srcBase =
     uppercased basename of the input path (WITH .MOD).  $D state was set by
     any $D+ directive scanned before MODULE; if $D-, BeginModule still runs
     but Enabled() stays FALSE so no records are collected. *)
  baseStart := 0; j := 0;
  WHILE PExpr.sc.filename[j] # 0X DO
    IF (PExpr.sc.filename[j] = "/") OR (PExpr.sc.filename[j] = "\")
       OR (PExpr.sc.filename[j] = ":") THEN baseStart := j + 1 END;
    INC(j)
  END;
  j := baseStart; i := 0;
  WHILE (PExpr.sc.filename[j] # 0X) & (i < LEN(srcBase) - 1) DO
    srcBase[i] := SYSTEM.UCASE(PExpr.sc.filename[j]); INC(i); INC(j)
  END;
  srcBase[i] := 0X;
  TDbg.BeginModule(modName, srcBase);

  (* check no '_' in module name *)
  i := 0; badName := FALSE;
  WHILE modName[i] # 0X DO IF modName[i] = "_" THEN badName := TRUE END; INC(i) END;
  IF badName THEN PExpr.Error("module name must not contain '_'") END;

  PExpr.Expect(Scan.TSemi);

  (* IMPORT list *)
  IF PExpr.sc.sym = Scan.TImport THEN
    Scan.Next(PExpr.sc);
    WHILE PExpr.sc.sym = Scan.TIdent DO
      Strings.Copy(PExpr.sc.id, iname); Scan.Next(PExpr.sc);
      Strings.Copy(iname, alias);
      IF PExpr.sc.sym = Scan.TAssign THEN
        Scan.Next(PExpr.sc);
        Strings.Copy(PExpr.sc.id, iname); Scan.Next(PExpr.sc)
      END;
      IF ~parserSystemMode & (iname = "SYSTEM") THEN
        PExpr.Error("SYSTEM is implicitly imported")
      ELSE
        isym := Syms.SymNew(alias, Syms.KImport);
        isym.modId := StrTab.Intern(iname);
        IF iname # "SYSTEM" THEN
          NEW(ip); Strings.Copy(iname, ip^.name); ip^.next := NIL;
          IF initImpsTail # NIL THEN initImpsTail^.next := ip ELSE initImpsHead := ip END;
          initImpsTail := ip; INC(nInitImps)
        END;
        Import.LoadExplicitImport(iname, alias)
      END;
      IF PExpr.sc.sym = Scan.TComma THEN Scan.Next(PExpr.sc) END
    END;
    PExpr.Expect(Scan.TSemi)
  END;

  (* parse declarations *)
  ParseDeclSeq();

  (* check unresolved FORWARD *)
  sym := Syms.TopScope^.symbols;
  WHILE sym # Syms.NoSym DO
    IF (sym.kind = Syms.KProc) & sym.fwdDecl THEN
      StrTab.Get(sym.nameId, nbuf);
      PExpr.Error2("unresolved FORWARD procedure", nbuf)
    END;
    sym := sym.next
  END;

  (* validate /ENTRY= proc *)
  IF (parserEntryProc # "") & ~Err.HaveErr() THEN
    sym := Syms.SymFind(parserEntryProc);
    IF (sym = Syms.NoSym) OR (sym.kind # Syms.KProc) OR (sym.level # 0) THEN
      PExpr.Error2("/ENTRY= procedure not found", parserEntryProc)
    ELSIF ~sym.exported THEN
      PExpr.Error2("/ENTRY= procedure is not exported", parserEntryProc)
    END
  END;

  (* generate __init *)
  hasImports := (nInitImps > 0);
  hasBody    := (PExpr.sc.sym = Scan.TBegin);
  Strings.Copy(modName, initName); Strings.Append("__init", initName);

  IF ~hasImports & ~hasBody THEN
    initOfs := Cgen.CgPc();
    Rdoff.RdfAddGlobal(Cgen.CgObj, initName, Rdoff.SegCode, initOfs);
    Cgen.Emit1(BYTE(Cgen.OpRetf))
  ELSE
    guardOfs := Cgen.CgPc();
    Cgen.EmitW(0);
    initOfs := Cgen.CgPc();
    Rdoff.RdfAddGlobal(Cgen.CgObj, initName, Rdoff.SegCode, initOfs);
    (* CS: CMP word [guardOfs], 0 *)
    Cgen.Emit1(02EH); Cgen.Emit2(083H, 03EH);
    addrField := Cgen.CgPc(); Cgen.EmitW(INTEGER(guardOfs));
    Rdoff.RdfAddReloc(Cgen.CgObj, Rdoff.SegCode, addrField, 2, Rdoff.SegCode, FALSE);
    Cgen.Emit1(000H);
    Cgen.Emit2(074H, 001H);   (* JE .cont *)
    Cgen.Emit1(BYTE(Cgen.OpRetf));
    (* .cont: CS: INC word [guardOfs] *)
    Cgen.Emit1(02EH); Cgen.Emit2(0FFH, 006H);
    addrField := Cgen.CgPc(); Cgen.EmitW(INTEGER(guardOfs));
    Rdoff.RdfAddReloc(Cgen.CgObj, Rdoff.SegCode, addrField, 2, Rdoff.SegCode, FALSE);
    IF PExpr.modUsesFpu THEN
      req87Id := PExpr.GetSystemImport("SYSTEM_REQUIRE87");
      Cgen.CgCallFar(req87Id)
    END;
    ip := initImpsHead;
    WHILE ip # NIL DO
      Strings.Copy(ip^.name, depInit); Strings.Append("__init", depInit);
      depImportId := Rdoff.RdfAddImport(Cgen.CgObj, depInit);
      Cgen.CgCallFar(depImportId);
      ip := ip^.next
    END;
    IF PExpr.sc.sym = Scan.TBegin THEN
      Scan.Next(PExpr.sc); ParseStatSeq(Syms.TypeNotype)
    END;
    Cgen.Emit1(BYTE(Cgen.OpRetf))
  END;

  PExpr.Expect(Scan.TEnd);
  IF PExpr.sc.sym = Scan.TIdent THEN
    IF PExpr.sc.id # modName THEN PExpr.Error("module name mismatch at END") END;
    Scan.Next(PExpr.sc)
  END;
  PExpr.Expect(Scan.TDot);

  (* Dead-code/variable elimination: warn about unused module-level
     non-exported globals and procedures.  Per-procedure warnings
     already emitted as each procedure's scope closed. *)
  WarnUnusedInScope;

  Strings.Copy(modName, rdfName); Strings.Append(".RDF", rdfName); SYSTEM.UPSTR(rdfName);
  Strings.Copy(modName, defName); Strings.Append(".DEF", defName); SYSTEM.UPSTR(defName);
  Strings.Copy(modName, dbgName); Strings.Append(".DBG", dbgName); SYSTEM.UPSTR(dbgName);
  Strings.Copy(modName, libName); Strings.Append(".OM",  libName); SYSTEM.UPSTR(libName);

  (* debug info: module code length for the SEGMENT slice *)
  TDbg.SetCodeLen(WORD(Rdoff.CodeLen(Cgen.CgObj)));

  IF ~Err.HaveErr() THEN
    (* sanitise-import: drop IMPORT records (and their CALL sites) for
       modules whose only reference was the __init dep call. *)
    SanitizeImports;
    (* Serialise the object + .def into TEMP files (auto-deleted on Close): the
       full .rdf and .def are never materialised as named files on disk — they
       are streamed straight into the .om.  rdfName/defName are still used as the
       tar MEMBER names so the archive layout is byte-identical to before. *)
    rfOpen := Files.ReWriteTemp(rf);
    IF ~rfOpen THEN Err.Error("oc: cannot create .rdf temp")
    ELSE Rdoff.RdfWriteTo(Cgen.CgObj, rf) END;
    IF Err.HaveErr() THEN
      IF rfOpen THEN Files.Close(rf) END
    ELSE
    (* write .def into a temp *)
    dfOpen := Files.ReWriteTemp(df);
    IF dfOpen THEN
      Def.DefWrite(df, modName)
    END;
    (* write .DBG into a temp — always present (0-byte when $D-); the writer
       emits nothing when collection was disabled. *)
    dgOpen := Files.ReWriteTemp(dg);
    IF dgOpen THEN
      TDbg.WriteDbg(dg)
    END;
    (* Symbol table is no longer needed: .def captures all exported info.
       Release it now to free DOS heap before the entry-stub generator
       allocates its own ObjFile. *)
    Syms.SymsFree();
    (* pack .om — stream the .rdf/.def temps and any $L extras directly into the
       tar.  No slurp buffers: TarAddFromFile copies through a 512-byte stack
       buffer. *)
    IF Files.ReWrite(lf, libName) THEN
      Tar.TarBegin(lf);
      (* stream .rdf temp *)
      Files.Seek(rf, LONGINT(0));
      IF Files.Size(rf) > LONGINT(0) THEN
        Tar.TarAddFromFile(lf, rdfName, rf, Files.Size(rf))
      END;
      (* stream .def temp *)
      IF dfOpen THEN
        Files.Seek(df, LONGINT(0));
        IF Files.Size(df) > LONGINT(0) THEN
          Tar.TarAddFromFile(lf, defName, df, Files.Size(df))
        END
      END;
      (* stream .DBG temp — ALWAYS emitted (0-byte member when $D-) so the
         archive layout is uniform for the linker. *)
      IF dgOpen THEN
        Files.Seek(dg, LONGINT(0));
        Tar.TarAddFromFile(lf, dbgName, dg, Files.Size(dg))
      END;
      (* extra .rdf files from $L directives — stream under MODNAME/<UPNAME>.
         Using the module name prefix avoids member-name collisions when multiple
         .om files are merged into OBERON.OM. *)
      er := extraRdfsHead;
      WHILE er # NIL DO
        IF Files.Reset(sf, er^.path^) THEN
          IF Files.Size(sf) > LONGINT(0) THEN
            (* build "MODNAME/" prefix — uppercased module name + "/" *)
            i := 0;
            WHILE parserModName[i] # 0X DO
              upName[i] := SYSTEM.UCASE(parserModName[i]);
              INC(i)
            END;
            upName[i] := "/"; INC(i); upName[i] := 0X;
            (* append uppercased basename of the extra rdf path *)
            baseStart := 0; j := 0;
            WHILE er^.path^[j] # 0X DO
              IF (er^.path^[j] = "/") OR (er^.path^[j] = "\") OR (er^.path^[j] = ":") THEN baseStart := j + 1 END;
              INC(j)
            END;
            j := baseStart;
            WHILE er^.path^[j] # 0X DO
              upName[i] := SYSTEM.UCASE(er^.path^[j]);
              INC(i); INC(j)
            END;
            upName[i] := 0X;
            Tar.TarAddFromFile(lf, upName, sf, Files.Size(sf))
          END;
          Files.Close(sf)
        ELSE
          Err.Error2("oc: cannot open extra rdf ", er^.path^)
        END;
        er := er^.next
      END;
      Tar.TarEnd(lf);
      Files.Close(lf)
    END;
    (* close (auto-delete) the .rdf/.def/.dbg temps *)
    Files.Close(rf);
    IF dfOpen THEN Files.Close(df) END;
    IF dgOpen THEN Files.Close(dg) END;
    Err.Info2("wrote ", libName)
    END   (* IF Err.HaveErr() *)
  END;
  (* On error, the failing diagnostic was already reported through Err; the
     latch suppresses any further output, so nothing more is printed here. *)
  (* Release the symbol/type/scope arena on EVERY path.  The success branch
     already freed it (line ~1132, before .om packing); the error branch did not,
     which left ~1800 paragraphs allocated when a compile failed — a leak the
     per-module LeakGuard reported.  SymsFree is idempotent (guards on
     symOpen/typeOpen), so calling it again here is safe and makes the
     error path leak-free too. *)
  Syms.SymsFree();
  (* Free per-module debug-info chunk tables on EVERY path (success + error). *)
  TDbg.Reset();
  (* Free per-module driver lists so nothing leaks across an in-process compile.
     (SymsFree already released the symbol/type/scope arena; these lists are
     owned by Parser/Import, not Syms.) *)
  Import.ResetLoaded();   (* free the per-compile import-dedup list now *)
  WHILE extraRdfsHead # NIL DO
    erNext := extraRdfsHead^.next;
    DISPOSE(extraRdfsHead^.path); DISPOSE(extraRdfsHead);
    extraRdfsHead := erNext
  END;
  extraRdfsTail := NIL;
  WHILE initImpsHead # NIL DO
    ipNext := initImpsHead^.next;
    DISPOSE(initImpsHead);
    initImpsHead := ipNext
  END;
  initImpsTail := NIL; nInitImps := 0
END ParseModule;

BEGIN
  parserModName := ""; parserSystemMode := FALSE;
  parserEntryProc := ""; parserStackSize := 0;
  parserMinMemPara := LONGINT(8192);   (* 128 KiB default *)
  parserMaxMemPara := LONGINT(16384);  (* 256 KiB default *)
  parserMemSet := FALSE;
  extraRdfsHead := NIL; extraRdfsTail := NIL;
  initImpsHead := NIL; initImpsTail := NIL; nInitImps := 0;
  nFwdRefs := 0
END Parser.
