(*$D-*)
MODULE Parser;
(*
  Oberon compiler — declaration parsing (CONST/TYPE/VAR/PROCEDURE) and
  module-level code (module init, __init guard, dep calls).
  Expressions: PExpr.  Statements: PStmt.
*)
IMPORT Dos, Files, LogErr, Scan, Syms, Cgen, Rdoff, Tar, Def, Import,
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

  (* DOCS/OVR.MD §5: exported, module-level ($O+ region) procedures,
     collected for the MODNAME.OVR archive member (§11.2). *)
  OvrEntryNode = POINTER TO OvrEntryNodeDesc;
  OvrEntryNodeDesc = RECORD
    name: ARRAY NameLen OF CHAR;
    next: OvrEntryNode
  END;

  FwdRef = RECORD
    name: ARRAY NameLen OF CHAR;
    ptr:  Syms.TypeDesc
  END;

VAR
  parserModName*:   ARRAY NameLen OF CHAR;
  parserSystemMode*: BOOLEAN;
  parserEntryProc*: ARRAY NameLen OF CHAR;
  (* Extra __init calls for the ENTRY module only, appended via AddExtraInit
     (TOC.MOD calls it before ParseModule, for the root module's own compile
     alone — see TOC.MOD's own TransitiveResidentInits comment for why this
     exists). Each name
     here is merged onto initImpsHead's own list, right after the IMPORT
     clause is parsed, exactly as if it had been a direct IMPORT of this
     module — the existing __init-call codegen loop then treats it
     identically to a real import, with no separate code path. Consumed and
     cleared by ParseModule; TOC.MOD repopulates it fresh before every
     entry-module compile. *)
  parserExtraInits: InitImpNode;
  parserExtraInitsTail: InitImpNode;
  parserStackSize*:   LONGINT;
  parserMinMemPara*:  LONGINT;  (* $M min, rounded up to paragraphs; default 8192 = 128 KiB *)
  parserMaxMemPara*:  LONGINT;  (* $M max, rounded up to paragraphs; default 16384 = 256 KiB *)
  parserMemSet*:      BOOLEAN;  (* TRUE once $M has been seen *)
  extraRdfsHead:    ExtraRdf;
  extraRdfsTail:    ExtraRdf;
  initImpsHead:     InitImpNode;
  initImpsTail:     InitImpNode;
  nInitImps:        INTEGER;
  ovrEntriesHead:   OvrEntryNode;
  ovrEntriesTail:   OvrEntryNode;
  nOvrEntries:      INTEGER;
  modIsOverlay:     BOOLEAN;  (* TRUE iff $O+ was active at any PROCEDURE decl seen *)
  fwdRefs:          ARRAY MaxFwdRefs OF FwdRef;
  nFwdRefs:         INTEGER;
  curModName:       ARRAY NameLen OF CHAR;

PROCEDURE IsLex(sym : INTEGER):BOOLEAN;
BEGIN
  IF PExpr.sc.sym = sym THEN
    Scan.Next(PExpr.sc);
    RETURN TRUE
  END;
  RETURN FALSE
END IsLex;

(* Append one module name onto parserExtraInits (TOC.MOD calls this,
   once per resident module in its own transitive-import walk, before
   compiling the ENTRY module only — see parserExtraInits's own comment).
   Must be called before ParseModule for that compile; ParseModule
   consumes and clears the list. *)
PROCEDURE AddExtraInit*(name: ARRAY OF CHAR);
  VAR n: InitImpNode;
BEGIN
  NEW(n);
  IF n = NIL THEN
    LogErr.Error("out of memory (extra init list)"); RETURN
  END;
  Strings.Copy(name, n^.name); n^.next := NIL;
  IF parserExtraInitsTail # NIL THEN parserExtraInitsTail^.next := n
  ELSE parserExtraInits := n END;
  parserExtraInitsTail := n
END AddExtraInit;

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

(* Apply a single +/- toggle directive (currently A, R, D, O).  Returns the
   index just past the consumed "+" or "-" in val, or -1 on error (caller
   reports). *)
PROCEDURE ApplyToggle(dir: CHAR; val: ARRAY OF CHAR; i: INTEGER): INTEGER;
BEGIN
  IF val[i] = "+" THEN
    IF dir = "R" THEN PExpr.boundsChk := TRUE
    ELSIF dir = "A" THEN Syms.AlignFields := TRUE
    ELSIF dir = "D" THEN TDbg.SetEnabled(TRUE)
    ELSIF dir = "O" THEN PExpr.overlayMode := TRUE
    ELSE RETURN -1
    END;
    RETURN i + 1
  ELSIF val[i] = "-" THEN
    IF dir = "R" THEN PExpr.boundsChk := FALSE
    ELSIF dir = "A" THEN Syms.AlignFields := FALSE
    ELSIF dir = "D" THEN TDbg.SetEnabled(FALSE)
    ELSIF dir = "O" THEN PExpr.overlayMode := FALSE
    ELSE RETURN -1
    END;
    RETURN i + 1
  ELSE RETURN -1
  END
END ApplyToggle;

(* Toggle directives (A, R, D, O) may be combined in one comment, comma-
   separated: (*$A-,R-*), (*$R-,D-*), (*$O+,R-*).  Parses "Dir+-[,Dir+-]*"
   starting at val[0], where the first Dir is already known (dir/val holds
   only the value after it). *)
PROCEDURE ProcessToggleChain(dir: CHAR; val: ARRAY OF CHAR);
  VAR i: INTEGER; nextDir: CHAR;
BEGIN
  i := ApplyToggle(dir, val, 0);
  IF i < 0 THEN PExpr.Error("$ directive requires + or -"); RETURN END;
  WHILE val[i] = "," DO
    INC(i);
    nextDir := val[i];
    IF (nextDir = "A") OR (nextDir = "R") OR (nextDir = "D") OR (nextDir = "O") THEN
      INC(i);
      i := ApplyToggle(nextDir, val, i);
      IF i < 0 THEN PExpr.Error("$ directive requires + or -"); RETURN END
    ELSE
      PExpr.Error("$ directive: only A, R, D and O may be combined with ','"); RETURN
    END
  END;
  IF val[i] # 0X THEN PExpr.Error("$ directive: trailing text after toggle chain") END
END ProcessToggleChain;

(* Apply one already-dequeued system comment.  Scan.MOD queues up to
   MaxPendSys directives per Scanner (see Scan.MOD's Scanner record comment)
   instead of applying them via a callback: a module-level PROCEDURE-typed
   VAR would be the first of its kind in this codebase and every currently
   available bootstrap binary still miscompiles that pattern
   (Cgen.CgCallProcVarMem's missing relocation — see
   TESTS/FIX/SYSCOMMENT_STACK_BUG.md), which would make the bootstrap's own
   `$M` stack-size directive processing crash before it could ever take
   effect.  ProcessSyscomment (below) drains the queue with a plain call. *)
PROCEDURE ApplyOneSyscomment(dir: CHAR; VAR arg: ARRAY OF CHAR);
  VAR val: ARRAY 128 OF CHAR; n: LONGINT; i, mi: INTEGER;
      mvals: ARRAY 3 OF LONGINT; hasDigits: BOOLEAN;
      node: ExtraRdf;
BEGIN
  TrimAndCopy(arg, val);

  IF (dir = "R") OR (dir = "A") OR (dir = "D") OR (dir = "O") THEN
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
    NEW(node);
    IF node = NIL THEN
      LogErr.Error("out of memory ($L directive)"); RETURN
    END;
    NEW(node^.path);
    IF node^.path = NIL THEN
      DISPOSE(node);
      LogErr.Error("out of memory ($L directive)"); RETURN
    END;
    Strings.Copy(val, node^.path^); node^.next := NIL;
    IF extraRdfsTail # NIL THEN extraRdfsTail^.next := node ELSE extraRdfsHead := node END;
    extraRdfsTail := node
  ELSE
    (* unknown: warn but continue *)
    PExpr.Error("unknown system comment directive")
  END
END ApplyOneSyscomment;

(* Drain every system comment Scan queued since the last call (in scan
   order) and reset the queue. *)
PROCEDURE ProcessSyscomment(VAR sc: Scan.Scanner);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i < sc.nSys DO
    ApplyOneSyscomment(sc.sysDirs[i], sc.sysArgs[i]);
    INC(i)
  END;
  sc.nSys := 0
END ProcessSyscomment;

(* Append one overlay-entry-point name (DOCS/OVR.MD §5). *)
PROCEDURE AddOvrEntry(name: ARRAY OF CHAR);
  VAR node: OvrEntryNode;
BEGIN
  NEW(node);
  IF node = NIL THEN LogErr.Error("out of memory (overlay entry list)"); RETURN END;
  Strings.Copy(name, node^.name); node^.next := NIL;
  IF ovrEntriesTail # NIL THEN ovrEntriesTail^.next := node ELSE ovrEntriesHead := node END;
  ovrEntriesTail := node; INC(nOvrEntries)
END AddOvrEntry;

(* Write the MODNAME.OVR archive member text (DOCS/OVR.MD §11.2):
     OVERLAY=1
     ENTRYCOUNT=<n>
     ENTRY0=<name>
     ENTRY1=<name>
     ...
   Only called when modIsOverlay is TRUE — a non-overlay module gets no
   .OVR member at all (om-no-file, checked by the manifest). *)
PROCEDURE WriteOvrMember(VAR f: Files.File);
  VAR line: ARRAY 80 OF CHAR;
      oe: OvrEntryNode; idx: INTEGER;
BEGIN
  Files.WriteLine(f, "OVERLAY=1");
  Strings.Copy("ENTRYCOUNT=", line); Strings.AppendInt(LONGINT(nOvrEntries), line);
  Files.WriteLine(f, line);
  oe := ovrEntriesHead; idx := 0;
  WHILE oe # NIL DO
    Strings.Copy("ENTRY", line); Strings.AppendInt(LONGINT(idx), line);
    Strings.Append("=", line); Strings.Append(oe^.name, line);
    Files.WriteLine(f, line);
    INC(idx); oe := oe^.next
  END
END WriteOvrMember;

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
  NEW(n);
  IF n = NIL THEN
    (* MUST be fatal: a silently-dropped IdentNode means the declared
       identifier never reaches the symbol table, and the compile then fails
       later with a misleading "undefined identifier" (or worse, corrupts
       the IVT via the NIL far write below).  This exact silent-OOM path is
       what broke self-hosting when a $M-less build ran with the 256 KB
       default heap (fixed 2026-07-11; see DOCS/IMPLRULE.MD §"Allocation
       failure is FATAL"). *)
    LogErr.Error("out of memory (ident list)");
    RETURN head
  END;
  Strings.Copy(name, n^.name); n^.exported := exported; n^.next := NIL;
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
    IF IsLex(Scan.TStar) THEN tail^.exported := TRUE END;
    IsLex(Scan.TComma)
  END
END ParseExportedIdentList;

(* ---- type descriptor emitter ---- *)

PROCEDURE EmitTypeDescriptor(VAR rec: Syms.TypeDesc);
  VAR t: Syms.TypeDesc;
BEGIN
  rec.lenOrDescOrArg := Cgen.CgDpc();
  t := rec;
  WHILE t # Syms.NoType DO Cgen.EmitDataWord(INTEGER(t.tagIdOrNParams)); t := t.base END;
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
    (* Each name position MUST hold an identifier: without the check, a
       malformed list copied whatever stale text sat in sc.id as a
       parameter name — silently. *)
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, nm); Scan.Next(PExpr.sc);
      head := IdListAppend(head, tail, nm, FALSE)
    ELSE
      PExpr.Error("parameter name expected"); Scan.Next(PExpr.sc)
    END;
    IsLex(Scan.TComma);
    WHILE (PExpr.sc.sym # Scan.TColon) & (PExpr.sc.sym # Scan.TSemi) &
          (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
      IF PExpr.sc.sym = Scan.TIdent THEN
        Strings.Copy(PExpr.sc.id, nm); Scan.Next(PExpr.sc);
        head := IdListAppend(head, tail, nm, FALSE)
      ELSE
        PExpr.Error("parameter name expected"); Scan.Next(PExpr.sc)
      END;
      IsLex(Scan.TComma)
    END;
    IF IsLex(Scan.TColon) THEN
      ptype := Syms.TypeInteger; ParseType(ptype)
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
        (* Duplicate parameter names were silently accepted (the later one
           shadowed the earlier in the scope while both occupied BP slots). *)
        IF Syms.SymFindLocal(pi^.name) # Syms.NoSym THEN
          PExpr.Error2("duplicate parameter name", pi^.name)
        END;
        s := Syms.SymNew(pi^.name, p.kind);
        s.type := ptype;
        s.declLine := PExpr.sc.line;
        IF typelessVar THEN s.typeless := TRUE END
      END;
      pi := pi^.next
    END;
    IdListFree(head);
    IsLex(Scan.TSemi)
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
  ELSIF IsLex(Scan.TArray) THEN
    len := -1;
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
  ELSIF IsLex(Scan.TRecord) THEN
    base := NIL;
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
      IsLex(Scan.TSemi)
    END;
    PExpr.Expect(Scan.TEnd); EmitTypeDescriptor(rec); out := rec
  ELSIF IsLex(Scan.TPointer) THEN
    PExpr.Expect(Scan.TTo);
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
  ELSIF IsLex(Scan.TProcedure) THEN
    out := Syms.TypeNewProc(Syms.TypeNotype);
    (* A PROCEDURE type (used to declare a proc-typed VAR) is always FAR: a
       stored procedure value's address is loaded/called indirectly through
       memory, so it must always carry a full segment:offset regardless of
       the target procedure's own FAR/NEAR-ness (see DOCS/OBERLANG.MD
       §"Procedural variables"). Optional "FAR" modifier accepted for
       symmetry/clarity; "NEAR" is rejected — a NEAR proc-typed VAR is no
       longer supported. *)
    out.isFar := TRUE; out.size := Syms.SzPointer;
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, modWord);
      IF Strings.Equal(modWord, "FAR") THEN
        Scan.Next(PExpr.sc)
      ELSIF Strings.Equal(modWord, "NEAR") THEN
        PExpr.Error("PROCEDURE NEAR type is not supported — proc-typed VARs are always FAR");
        Scan.Next(PExpr.sc)
      END
    END;
    IF PExpr.sc.sym = Scan.TLparen THEN ParseFormalPars(out, FALSE) END;
    IF IsLex(Scan.TColon) THEN
      rtmp := Syms.TypeInteger; ParseType(rtmp);
      CheckResultType(rtmp);
      out.elemOrRet := rtmp
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
    exported := IsLex(Scan.TStar);
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
    IsLex(Scan.TSemi)
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
    exported := IsLex(Scan.TStar);
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
    IsLex(Scan.TSemi)
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
        IF t.size >= LONGINT(Rdoff.SegLimit) THEN
          PExpr.Error2("global variable exceeds 64K data segment limit", it^.name)
        END;
        s.adr := Cgen.CgDpc(); Cgen.EmitDataZero(t.size);
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
    IsLex(Scan.TSemi)
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
      wordA: ARRAY 16 OF CHAR; wid: StrTab.TStrTabId;
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
    p := pt.symList;
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
    IF IsLex(Scan.TStar) THEN exported := TRUE; sym.exported := TRUE END;
    pt := Syms.TypeNewProc(Syms.TypeNotype);
    sym.type := pt;
    Syms.SymOpenScope();
    IF PExpr.sc.sym = Scan.TLparen THEN ParseFormalPars(pt, TRUE) END;
    IF IsLex(Scan.TColon) THEN
      rtmp := Syms.TypeInteger; ParseType(rtmp);
      CheckResultType(rtmp);
      pt.elemOrRet := rtmp END;
    IF exported THEN pt.isFar := TRUE END;
    PExpr.Expect(Scan.TSemi);

    (* FAR/NEAR modifier *)
    wordA := "";
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, wordA);
      IF Strings.Equal(wordA, "FAR") THEN
        pt.isFar := TRUE; Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi)
      ELSIF Strings.Equal(wordA, "NEAR") THEN
        IF exported THEN PExpr.Error("exported procedure cannot be NEAR") END;
        pt.isFar := FALSE; Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi)
      END
    END;

    (* FORWARD / EXTERNAL / INLINE — one token peek, one dispatch *)
    IF PExpr.sc.sym = Scan.TIdent THEN
      Strings.Copy(PExpr.sc.id, wordA);
      IF Strings.Equal(wordA, "FORWARD") THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi);
        Syms.TypeCalcArgSize(pt);
        sym.fwdDecl := TRUE;
        Syms.SymCloseScope(); RETURN
      ELSIF Strings.Equal(wordA, "EXTERNAL") THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TSemi);
        Syms.TypeCalcArgSize(pt);
        Strings.Copy(parserModName, gname); Strings.Append("_", gname); Strings.Append(name, gname);
        sym.rdoffId := Rdoff.RdfAddImport(Cgen.CgObj, gname);
        sym.adr := 0;
        Syms.SymCloseScope(); RETURN
      ELSIF Strings.Equal(wordA, "INLINE") THEN
        Scan.Next(PExpr.sc); PExpr.Expect(Scan.TLparen);
        inlNode := NIL; inlTail := NIL; nInl := 0;
        WHILE (PExpr.sc.sym # Scan.TRparen) & (PExpr.sc.sym # Scan.TEof) DO
          IF PExpr.sc.sym = Scan.TInt THEN
            Syms.InlineAppend(inlNode, inlTail, FALSE, BYTE(INTEGER(PExpr.sc.ival) MOD 256), 0);
            INC(nInl); Scan.Next(PExpr.sc)
          ELSIF PExpr.sc.sym = Scan.TIdent THEN
            wid := StrTab.Find(PExpr.sc.id);   (* 0 (unknown) matches no param *)
            idx := 0; fp := pt.symList; found := FALSE;
            WHILE fp # Syms.NoSym DO
              IF fp.nameId = wid THEN found := TRUE; fp := Syms.NoSym
              ELSE INC(idx); fp := fp.next END
            END;
            IF ~found THEN PExpr.Error("unknown parameter name in INLINE") END;
            Syms.InlineAppend(inlNode, inlTail, TRUE, BYTE(0), idx);
            INC(nInl); Scan.Next(PExpr.sc)
          ELSE PExpr.Error("byte literal or parameter name expected"); Scan.Next(PExpr.sc) END;
          IsLex(Scan.TComma)
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
  (* copy BP offsets from pt^.symList into scope symbols *)
  p := pt.symList;
  WHILE p # Syms.NoSym DO
    s := Syms.SymFindLocalId(p.nameId);
    IF s # Syms.NoSym THEN s.adr := p.adr END;
    p := p.next
  END;

  sym.adr := Cgen.CgPc();
  IF exported THEN
    Strings.Copy(parserModName, gname); Strings.Append("_", gname); Strings.Append(name, gname);
    Rdoff.RdfAddGlobal(Cgen.CgObj, gname, Rdoff.SegCode, sym.adr)
  END;

  (* DOCS/OVR.MD §5: an overlay entry point is exported AND module-level
     AND declared while $O+ was active.  sym.level was captured at SymNew
     time (before this procedure's own param scope was opened), so it
     reflects the DECLARING scope, not the body we're about to parse.
     Stored under the MANGLED global name (gname, "<Mod>_<Proc>") -- the
     linker's own symbol table (LINK.MOD's FindImport/SymOwner) is keyed
     by that same mangled name, never the bare proc name, so OvrEntryId's
     lookup at link time only works if the .OVR member matches it. *)
  IF exported & (sym.level = 0) & PExpr.overlayMode THEN
    modIsOverlay := TRUE;
    AddOvrEntry(gname)
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
  Cgen.CgPrologue(0, pt.isFar);

  Cgen.CgJmpNear(skipNested);
  ParseDeclSeq();
  Cgen.CgPatchNear(skipNested);
  PStmt.curProloguePatch := prologuePatch;

  PStmt.PatchFrameSize;

  IF IsLex(Scan.TBegin) THEN ParseStatSeq(pt.elemOrRet) END;
  PExpr.Expect(Scan.TEnd);
  IF PExpr.sc.sym = Scan.TIdent THEN
    IF ~Strings.Equal(PExpr.sc.id, name) THEN PExpr.Error("procedure name mismatch") END;
    Scan.Next(PExpr.sc)
  END;

  PStmt.BpPatchFree(PStmt.retPatchList);
  Cgen.CgEpilogue(INTEGER(pt.lenOrDescOrArg), pt.isFar);
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
    TDbg.EndScope(WORD(Cgen.CgPc() - sym.adr))
  END;
  Syms.SymCloseScope();

  PStmt.retPatchList := savedRetList;
  PStmt.curProloguePatch := savedProloguePatch;
  PStmt.curProcDepth := savedProcDepth;

  IF sym.fwdDecl THEN
    PExpr.FwdPatchCalls(sym, sym.adr);
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
    IF IsLex(Scan.TConst) THEN
      ParseConstDecl
    ELSIF IsLex(Scan.TType) THEN
      ParseTypeDecl
    ELSIF IsLex(Scan.TVar) THEN
      ParseVarDecl
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
       ~s.wasRead &
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
      LogErr.WarnInFile(PExpr.sc.filename, LONGINT(s.declLine), what)
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
              (* Hardening: this pass ASSUMES every reloc against a dead
                 __init import sits inside a 5-byte CALL FAR.  Verify the
                 opcode before NOP-patching — a future feature that takes an
                 __init address any other way would otherwise be silently
                 destroyed.  90H is equally valid: each call site carries TWO
                 relocs (offset RELOC + SEGRELOC), so the second one finds
                 the site already NOP-patched by the first. *)
              IF (Rdoff.PeekCodeByte(Cgen.CgObj, base) # BYTE(09AH)) &
                 (Rdoff.PeekCodeByte(Cgen.CgObj, base) # BYTE(090H)) THEN
                LogErr.Error("internal: __init reloc is not a CALL FAR site (SanitizeImports)")
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
      rdfName, defName, libName, dbgName, ovrName: ARRAY 40 OF CHAR;
      srcBase: ARRAY 40 OF CHAR;
      rf, df, lf, sf, dg, mf, ov: Files.File;
      dgOpen, ovOpen: BOOLEAN;
      mergeOk: BOOLEAN;
      ip, ipNext: InitImpNode;
      er, erNext: ExtraRdf;
      oe, oeNext: OvrEntryNode;
      sym: Syms.Symbol;
      req87Id, depImportId: INTEGER;
      addrField, dsImmAt: LONGINT;
      i, j: INTEGER; badName: BOOLEAN;
      baseStart: INTEGER;
      rfOpen, dfOpen: BOOLEAN;
BEGIN
  (* ALIASING INVARIANT (whole-Scanner record copy): PExpr.sc becomes a full
     copy of the caller's Scanner, including the embedded Files.File RECORD —
     both copies share the same DOS handle and the same heap `buf` pointer.
     This is safe ONLY because the scanner never writes (never dirties the
     buffer): the caller may later Close through its own, position-stale copy
     (see TOC.CompileModule) and nothing is flushed wrongly, and the shared
     buf is DISPOSEd exactly once.  If the Scanner ever gains a write path,
     this copy (and Scan.Mark/Restore's) must become pointer-held instead. *)
  PExpr.sc := s;
  Syms.SymInit;
  IF LogErr.HaveErr() THEN RETURN END;
  Cgen.CgInit;
  IF LogErr.HaveErr() THEN Syms.SymsFree(); RETURN END;
  Import.ResetLoaded();
  Cgen.EmitDataZero(2);
  PExpr.modUsesFpu := FALSE;
  PExpr.boundsChk := FALSE;
  PExpr.overlayMode := FALSE;
  PStmt.retPatchList := NIL;
  PStmt.curProloguePatch := 0;
  PStmt.curProcDepth := 0;
  (* reset init imports *)
  initImpsHead := NIL; initImpsTail := NIL; nInitImps := 0;
  (* reset extra rdfs *)
  extraRdfsHead := NIL; extraRdfsTail := NIL;
  (* reset overlay entry-point collection (DOCS/OVR.MD §5) *)
  ovrEntriesHead := NIL; ovrEntriesTail := NIL; nOvrEntries := 0; modIsOverlay := FALSE;

  IF ~parserSystemMode THEN Import.AddImplicitImport("SYSTEM") END;

  (* Handle any system comment(s) that preceded the MODULE keyword
     (e.g. `(*$R+*)` at the top of a file enabling bounds checks, or
     TOC.MOD's own stacked `(*$M ...*)(*$D+*)`). *)
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
  IF IsLex(Scan.TImport) THEN
    WHILE PExpr.sc.sym = Scan.TIdent DO
      Strings.Copy(PExpr.sc.id, iname); Scan.Next(PExpr.sc);
      Strings.Copy(iname, alias);
      IF IsLex(Scan.TAssign) THEN
        IF PExpr.sc.sym = Scan.TIdent THEN
          Strings.Copy(PExpr.sc.id, iname); Scan.Next(PExpr.sc)
        ELSE
          PExpr.Error("module name expected after ':=' in IMPORT")
        END
      END;
      IF ~parserSystemMode & Strings.Equal(iname, "SYSTEM") THEN
        PExpr.Error("SYSTEM is implicitly imported")
      ELSE
        isym := Syms.SymNew(alias, Syms.KImport);
        isym.modId := StrTab.Intern(iname);
        IF ~Strings.Equal(iname, "SYSTEM") THEN
          NEW(ip);
          IF ip = NIL THEN
            (* Fatal: a silently-dropped node here means the dep's __init is
               never called — the same silent-OOM class as the 2026-07-11
               ident-list bug.  Latch and stop adding. *)
            LogErr.Error("out of memory (import list)")
          ELSE
            Strings.Copy(iname, ip^.name); ip^.next := NIL;
            IF initImpsTail # NIL THEN initImpsTail^.next := ip ELSE initImpsHead := ip END;
            initImpsTail := ip; INC(nInitImps)
          END
        END;
        Import.LoadExplicitImport(iname, alias)
      END;
      IsLex(Scan.TComma)
    END;
    PExpr.Expect(Scan.TSemi)
  END;
  (* The import-dedup list (Import.AlreadyLoaded's LoadedRecs) is only read
     while the IMPORT clause is being processed — nothing below references it.
     Free it HERE, right after its last use, rather than at the ParseModule
     tail: freed late, each LoadedRec is a small block that ends up pinned in
     the middle of the heap by the far larger parse/codegen allocations made
     after it, so its paragraph cannot coalesce back on release — a
     fragmentation "leak" the per-module LeakGuard flags (~1 block per real
     import).  Freeing it now, before those allocations, keeps the arena
     contiguous. *)
  Import.ResetLoaded();

  (* Merge TOC.MOD's extra transitive-init list (entry module only; NIL for
     every other module's compile) onto the tail of the ordinary IMPORT-
     derived list, so the existing __init-call codegen loop below calls
     them exactly like any other direct import — see parserExtraInits's
     own comment. A name already reached through this module's own real
     IMPORT clause is harmless to call twice (the callee's own guard word
     absorbs the redundant call — DOCS/OVR.MD §4) so no dedup is done here. *)
  WHILE parserExtraInits # NIL DO
    IF initImpsTail # NIL THEN initImpsTail^.next := parserExtraInits
    ELSE initImpsHead := parserExtraInits END;
    initImpsTail := parserExtraInits;
    parserExtraInits := parserExtraInits^.next;
    initImpsTail^.next := NIL;
    INC(nInitImps)
  END;
  parserExtraInitsTail := NIL;

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
  IF (parserEntryProc # "") & ~LogErr.HaveErr() THEN
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

  (* An $O+ module may not have a BEGIN block at all: an overlay module's
     own init body would have to be called through the SAME overlay-
     trampoline mechanism as any other overlay call, and doing so before
     OvrInit has run would crash -- giving an $O+ module no init code at
     all removes that failure class by construction (DOCS/OVR.MD §4).
     Reject at compile time rather than silently
     miscompiling. *)
  IF modIsOverlay & hasBody THEN
    PExpr.Error("$O+ module may not have a BEGIN block")
  END;

  (* No __init at all for an $O+ module: nothing outside the entry
     module's own transitive-init walk (TOC.MOD, see parserExtraInits)
     ever calls an overlay module's init, and an $O+ module's own direct
     imports (if any) have no init caller either — DOCS/OVR.MD §4 documents
     this: once a unit has no init body, nothing tries to run one
     separately. *)
  IF modIsOverlay THEN
    (* still consume a body if present, even though it's a compile error
       above, so parsing doesn't derail on the rest of the file *)
    IF hasBody THEN
      IsLex(Scan.TBegin); ParseStatSeq(Syms.TypeNotype)
    END

  (* The bare-RETF short form is only valid when the module ALSO needs no
     FPU check: a body-less, import-less module whose procedures use REAL/
     LONGREAL must still get the SYSTEM_REQUIRE87 call in its __init, or it
     runs undetected on FPU-less hardware. *)
  ELSIF ~hasImports & ~hasBody & ~PExpr.modUsesFpu THEN
    initOfs := Cgen.CgPc();
    Rdoff.RdfAddGlobal(Cgen.CgObj, initName, Rdoff.SegCode, initOfs);
    Cgen.Emit1(BYTE(Cgen.OpRetf))
  ELSE
    (* Guard word lives in THIS module's own data segment, not the code
       segment: a DPMI16 code selector is execute-only, and the guard is
       read AND written (CMP/INC) on every __init call — a bare [cs:xxx]
       access there faults on real DPMI16 hardware (same class of bug as
       SYSTEM_Intr's int_ins+1 self-patch, see DOCS/NE-BP.MD Part 2).
       DS must therefore point at this module's data segment BEFORE the
       guard check, not after — so the PUSH DS/MOV DS,imm/MOV DS,AX
       sequence (originally emitted after the guard, since the old
       CS-relative guard didn't need DS at all) moves up front here.  The
       early-return path now needs its own matching POP DS, since RETF no
       longer happens with DS untouched. *)
    guardOfs := Cgen.CgDpc();
    Cgen.EmitDataWord(0);
    initOfs := Cgen.CgPc();
    Rdoff.RdfAddGlobal(Cgen.CgObj, initName, Rdoff.SegCode, initOfs);
    Cgen.Emit1(01EH);                             (* PUSH DS *)
    Cgen.Emit1(0B8H); dsImmAt := Cgen.CgPc(); Cgen.EmitW(0);  (* MOV AX,imm16 *)
    Rdoff.RdfAddSegReloc(Cgen.CgObj, Rdoff.SegCode, dsImmAt, Rdoff.SegData);
    Cgen.Emit2(08EH, 0D8H);                       (* MOV DS, AX *)
    (* CMP word [guardOfs], 0 *)
    Cgen.Emit2(083H, 03EH);
    addrField := Cgen.CgPc(); Cgen.EmitW(INTEGER(guardOfs));
    Rdoff.RdfAddReloc(Cgen.CgObj, Rdoff.SegCode, addrField, 2, Rdoff.SegData, FALSE);
    Cgen.Emit1(000H);
    Cgen.Emit2(074H, 002H);   (* JE .cont (skip POP DS + RETF below) *)
    Cgen.Emit1(01FH);                             (* POP DS *)
    Cgen.Emit1(BYTE(Cgen.OpRetf));
    (* .cont: INC word [guardOfs] *)
    Cgen.Emit2(0FFH, 006H);
    addrField := Cgen.CgPc(); Cgen.EmitW(INTEGER(guardOfs));
    Rdoff.RdfAddReloc(Cgen.CgObj, Rdoff.SegCode, addrField, 2, Rdoff.SegData, FALSE);
    IF PExpr.modUsesFpu THEN
      req87Id := PExpr.GetSystemImport("SYSTEM_REQUIRE87");
      Cgen.CgCallFar(req87Id)
    END;
    ip := initImpsHead;
    WHILE ip # NIL DO
      (* An $O+ import has no __init to call (see the modIsOverlay branch
         above) -- skip it rather than emit a CALL FAR to a symbol that
         will never exist.  A name reached here via parserExtraInits
         (entry module only) is always resident by construction (TOC.MOD's
         transitive walk never adds an $O+ node to that list), so this
         check only ever fires for a module's own real IMPORT clause. *)
      IF ~Import.IsOverlayModule(ip^.name) THEN
        Strings.Copy(ip^.name, depInit); Strings.Append("__init", depInit);
        depImportId := Rdoff.RdfAddImport(Cgen.CgObj, depInit);
        Cgen.CgCallFar(depImportId)
      END;
      ip := ip^.next
    END;
    IF IsLex(Scan.TBegin) THEN ParseStatSeq(Syms.TypeNotype) END;
    Cgen.Emit1(01FH);                             (* POP DS *)
    Cgen.Emit1(BYTE(Cgen.OpRetf))
  END;

  PExpr.Expect(Scan.TEnd);
  IF PExpr.sc.sym = Scan.TIdent THEN
    IF ~Strings.Equal(PExpr.sc.id, modName) THEN PExpr.Error("module name mismatch at END") END;
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
  Strings.Copy(modName, ovrName); Strings.Append(".OVR", ovrName); SYSTEM.UPSTR(ovrName);
  Strings.Copy(modName, libName); Strings.Append(".OM",  libName); SYSTEM.UPSTR(libName);

  (* debug info: module code length for the SEGMENT slice *)
  TDbg.SetCodeLen(WORD(Rdoff.CodeLen(Cgen.CgObj)));

  IF ~LogErr.HaveErr() THEN
    (* sanitise-import: drop IMPORT records (and their CALL sites) for
       modules whose only reference was the __init dep call. *)
    SanitizeImports;
    (* Serialise the object + .def into TEMP files (auto-deleted on Close): the
       full .rdf and .def are never materialised as named files on disk — they
       are streamed straight into the .om.  rdfName/defName are still used as the
       tar MEMBER names so the archive layout is byte-identical to before. *)
    rfOpen := Files.ReWriteTemp(rf);
    IF ~rfOpen THEN LogErr.Error("oc: cannot create .rdf temp")
    ELSE Rdoff.RdfWriteTo(Cgen.CgObj, rf) END;
    (* Fold every $L extra directly into rf via Rdoff.MergeRdf: code/data/bss
       2-byte aligned, relocations/segrelocs offset-corrected, imports
       resolved against the other side's globals where possible (and
       removed once resolved — never left dangling), remaining imports
       renumbered to avoid id collisions, both sides' globals re-exposed
       with corrected offsets.  The extra is folded into MODNAME.RDF itself
       — it is NEVER packed as its own MODNAME/UPNAME.RDF archive member
       anymore. *)
    IF rfOpen & ~LogErr.HaveErr() THEN
      er := extraRdfsHead;
      WHILE (er # NIL) & ~LogErr.HaveErr() DO
        IF Files.Reset(sf, er^.path^) THEN
          IF ~Files.ReWriteTemp(mf) THEN
            LogErr.Error("oc: cannot create merge temp"); Files.Close(sf)
          ELSE
            Files.Seek(rf, LONGINT(0));
            mergeOk := Rdoff.MergeRdf(rf, sf, mf);
            Files.Close(sf); Files.Close(rf);
            IF ~mergeOk THEN
              LogErr.Error2("oc: failed to merge $L extra ", er^.path^)
            END;
            rf := mf (* mf becomes the new accumulator; auto-deleted like rf *)
          END
        ELSE
          LogErr.Error2("oc: cannot open extra rdf ", er^.path^)
        END;
        er := er^.next
      END
    END;
    IF LogErr.HaveErr() THEN
      IF rfOpen THEN Files.Close(rf) END
    ELSE
    (* write .def into a temp *)
    dfOpen := Files.ReWriteTemp(df);
    IF dfOpen THEN
      Def.DefWrite(df, modName)
    ELSE
      LogErr.Error("oc: cannot create .def temp")
    END;
    (* write .DBG into a temp — always present (0-byte when $D-); the writer
       emits nothing when collection was disabled. *)
    dgOpen := Files.ReWriteTemp(dg);
    IF dgOpen THEN
      TDbg.WriteDbg(dg)
    ELSE
      LogErr.Error("oc: cannot create .dbg temp")
    END;
    (* write .OVR into a temp -- only for modules with $O+ entry points
       (DOCS/OVR.MD §11.2); non-overlay modules get no .OVR member at all. *)
    ovOpen := FALSE;
    IF modIsOverlay THEN
      ovOpen := Files.ReWriteTemp(ov);
      IF ovOpen THEN
        WriteOvrMember(ov)
      ELSE
        LogErr.Error("oc: cannot create .ovr temp")
      END
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
      (* stream .OVR temp — only present for $O+ overlay-eligible modules. *)
      IF ovOpen THEN
        Files.Seek(ov, LONGINT(0));
        Tar.TarAddFromFile(lf, ovrName, ov, Files.Size(ov))
      END;
      Tar.TarEnd(lf);
      Files.Close(lf);
      (* Disk-full / write errors are latched inside Files (wrErr survives
         Close); without this check a truncated .om was reported as written. *)
      IF ~Files.Ok(lf) THEN
        LogErr.Error2("oc: write error (disk full?) on ", libName);
        Files.Delete(libName)
      END
    ELSE
      LogErr.Error2("oc: cannot create ", libName)
    END;
    (* close (auto-delete) the .rdf/.def/.dbg/.ovr temps *)
    Files.Close(rf);
    IF dfOpen THEN Files.Close(df) END;
    IF dgOpen THEN Files.Close(dg) END;
    IF ovOpen THEN Files.Close(ov) END;
    IF ~LogErr.HaveErr() THEN LogErr.Info2("wrote ", libName) END
    END   (* IF LogErr.HaveErr() *)
  END;
  (* On error, the failing diagnostic was already reported through LogErr; the
     latch suppresses any further output, so nothing more is printed here. *)
  (* Release the symbol/type/scope arena on EVERY path.  The success branch
     already freed it (before .om packing); the error branch did not, which
     left ~1800 paragraphs allocated when a compile failed — a leak the
     per-module LeakGuard reported.  SymsFree is idempotent — FreeChunks and
     the allInline/allFwd/allScopes walks all no-op on the already-NIL state
     a first SymsFree leaves behind — so calling it again here is safe and
     makes the error path leak-free too. *)
  Syms.SymsFree();
  (* Free per-module debug-info chunk tables on EVERY path (success + error). *)
  TDbg.Reset();
  (* Free per-module driver lists so nothing leaks across an in-process compile.
     (SymsFree already released the symbol/type/scope arena; these lists are
     owned by Parser/Import, not Syms.) *)
  Import.ResetLoaded();   (* idempotent safety: the list was already freed
                             right after the IMPORT clause; harmless no-op on
                             the normal path, covers early-return error paths *)
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
  initImpsTail := NIL; nInitImps := 0;
  WHILE ovrEntriesHead # NIL DO
    oeNext := ovrEntriesHead^.next;
    DISPOSE(ovrEntriesHead);
    ovrEntriesHead := oeNext
  END;
  ovrEntriesTail := NIL; nOvrEntries := 0
END ParseModule;

BEGIN
  parserModName := ""; parserSystemMode := FALSE;
  parserEntryProc := ""; parserStackSize := 0;
  parserMinMemPara := LONGINT(8192);   (* 128 KiB default *)
  parserMaxMemPara := LONGINT(16384);  (* 256 KiB default *)
  parserMemSet := FALSE;
  extraRdfsHead := NIL; extraRdfsTail := NIL;
  initImpsHead := NIL; initImpsTail := NIL; nInitImps := 0;
  ovrEntriesHead := NIL; ovrEntriesTail := NIL; nOvrEntries := 0; modIsOverlay := FALSE;
  nFwdRefs := 0
END Parser.
