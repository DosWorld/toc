MODULE Sym;
(*
  TASM symbol table: labels (code/data-relative offsets), STRUC field-offset
  constants, and %define text-substitution macros.  Chunked linked lists
  throughout (CLAUDE.md "Chunk small records" rule) since every entry here
  is small and NEW'd frequently.

  A label can be referenced before it is defined (forward reference) --
  Pass 1 (Parse.MOD) walks the whole source and fills in every label's
  final offset; Pass 2 re-walks and emits real bytes, so by the time an
  operand needs a label's value, Lookup always succeeds.  Undefined-at-
  end-of-pass-1 is the only "forward ref never resolved" error case.
*)
IMPORT Strings, LogErr, Scan, StrTab;

CONST
  Chunk = 32;
  MaxName* = 64;   (* BUG B3: was 40, diverging from Scan.MaxIdent (64) --
                       silently truncating a >=40-char label collided two
                       long labels sharing a common prefix. One shared
                       bound (Scan's own limit, now enforced as a fatal
                       scan error rather than silent truncation, see
                       Scan.ScanIdent) removes the mismatch entirely. *)

  SegCode* = 0;
  SegData* = 1;
  SegBss*  = 2;
  SegConst* = 3;   (* EQU constant: label-table entry whose "offset" is the
                      constant's absolute value; resolved as a plain immediate,
                      never a relocated address (see Parse.MOD's operand path). *)

TYPE
  GlobalVisitProc* = PROCEDURE(name: ARRAY OF CHAR; seg: INTEGER; offset: LONGINT);

  LabelNode = POINTER TO LabelNodeDesc;
  LabelNodeDesc = RECORD
    nameId*:  ARRAY Chunk OF StrTab.TStrTabId;   (* StrTab id, not the string itself --
                                         E1's cached-hash trick is superseded
                                         by StrTab: FindNode now compares a
                                         single WORD id (StrTab.Find's own
                                         internal hash chaining already did
                                         the expensive part once), so no
                                         separate hash field or Strings.Equal
                                         call is needed on the hot path. *)
    seg*:     ARRAY Chunk OF INTEGER;    (* SegCode/SegData *)
    offset*:  ARRAY Chunk OF LONGINT;
    defined*: ARRAY Chunk OF BOOLEAN;
    isGlobal*:ARRAY Chunk OF BOOLEAN;
    (* defOrder: the order labels were actually DEFINED (given a real
       offset via DefineLabel), NOT the order they were first reserved
       (a GLOBAL directive or a forward operand reference can reserve a
       table slot long before the label's defining ":" line is reached).
       EnumGlobals must walk in defOrder to match real NASM's RDOFF2
       writer, which emits GLOBAL records in source label-definition
       order -- verified against SRC/LIB/SYSTEM.RDF, where "global
       SYSTEM_INIT, SYSTEM_DONE" (an early GLOBAL directive) is declared
       before "global SYSTEM_REQUIRE87" (a later one), but SYSTEM_REQUIRE87
       is DEFINED earlier in the file and is the FIRST global record in
       the oracle.  -1 until DefineLabel assigns a real order. *)
    defOrder*:ARRAY Chunk OF LONGINT;
    (* isExtern: declared via EXTERN -- never expects a local ":" definition;
       Lookup for such a label reports "known but not locally defined" (the
       caller, Enc.MOD, routes the reference through an RDFREC_IMPORT
       instead of an intra-module RDFREC_RELOC).  importId caches the
       RDOFF2 import segment ID once Rdoff.RdfAddImport has assigned one
       (0 = not yet assigned; real IDs start at 3, see Rdoff.MOD). *)
    isExtern*:ARRAY Chunk OF BOOLEAN;
    importId*:ARRAY Chunk OF INTEGER;
    count*:   INTEGER;
    next*:    LabelNode
  END;

  (* E9 (code-smell audit): this one table backs TWO distinct, individually
     self-consistent case conventions, chosen by the CALLER, not enforced
     here:
       1. plain %define names and Dir.EndStruc's "NAME_size" keys are
          stored/looked-up UPPERCASE (Parse.MOD's TokNext calls
          Sym.Expand(tId, ...) -- tId is Scan's always-uppercased form);
       2. Dir.AddField's "STRUCT.field" keys are stored/looked-up in
          ORIGINAL case (Dir.TryResolveField takes tIdOrig throughout, see
          Parse.MOD's ParseMemBody comment on why -- mixed-case struct
          names must round-trip).
     The two never collide today only because their key SHAPES differ (a
     "STRUCT.field" key always contains a literal '.'; a %define/NAME_size
     key never does) -- nothing in Define/Expand/FindDefine enforces that
     separation, so a future caller building a dotted key without going
     through AddField's exact convention (or a bare key going through the
     wrong case) would silently miscompile via a phantom hit or a real
     "unknown symbol". Do not add a third convention; if you add a new kind
     of Sym.Define key, decide which of the two above it matches and follow
     that caller's case discipline exactly. *)
  DefineNode = POINTER TO DefineNodeDesc;
  DefineNodeDesc = RECORD
    nameId*: ARRAY Chunk OF StrTab.TStrTabId;   (* StrTab id -- see LabelNodeDesc.nameId *)
    value*: ARRAY Chunk OF ARRAY 128 OF CHAR;
    count*: INTEGER;
    next*:  DefineNode
  END;

  (* MacroNode: §I.4's %macro storage -- same StrTab-interned-name shape
     as DefineNode (convention 1 of the E9 case-discipline note above:
     %macro names, like %define names, are looked up via the always-
     uppercased scanned token). body is a heap-allocated exact-
     size NUL-terminated buffer (Scan.MemText, the same pointer type
     Scan.InitMem consumes directly -- no copy needed at invocation
     time), captured verbatim by Parse.MOD's %macro recorder; freed here
     in Free since Sym owns the table that holds the pointers. *)
  MacroNode = POINTER TO MacroNodeDesc;
  MacroNodeDesc = RECORD
    nameId*:  ARRAY Chunk OF StrTab.TStrTabId;   (* StrTab id -- see LabelNodeDesc.nameId *)
    nParams*: ARRAY Chunk OF INTEGER;
    body*:    ARRAY Chunk OF Scan.MemText;
    count*:   INTEGER;
    next*:    MacroNode
  END;

VAR
  labelHead, labelTail: LabelNode;
  nLabels: INTEGER;
  defineHead, defineTail: DefineNode;
  nDefines: INTEGER;
  macroHead, macroTail: MacroNode;
  lastLabel: ARRAY MaxName OF CHAR;   (* most recent non-local label, for .local resolution *)
  nextDefOrder: LONGINT;

PROCEDURE Init*;
BEGIN
  labelHead := NIL; labelTail := NIL; nLabels := 0;
  defineHead := NIL; defineTail := NIL; nDefines := 0;
  macroHead := NIL; macroTail := NIL;
  lastLabel[0] := 0X; nextDefOrder := LONGINT(0)
END Init;

(* WarmStrTab: force StrTab's first text/entry chunk allocation (~10 KB)
   right now, before the caller captures its own "before" MemAvail
   baseline for a leak-guard window.  StrTab never Resets mid-process
   here (TASM assembles exactly one file per invocation, see the module
   header), so the first-ever Intern call anywhere pays a one-time
   chunk-bootstrap cost that is NOT a leak — without this warm-up call,
   whichever file happens to intern the first label/define/macro name in
   a fresh tasm.exe process absorbs that cost into its own leak-guard
   window and reports a false leak. Interning a name already guaranteed
   never to appear as a real label/define/macro (a token no NASM-subset
   source can produce) keeps this warm-up itself side-effect-free for
   every real lookup. *)
PROCEDURE WarmStrTab*;
BEGIN
  StrTab.Intern(" $tasm-warmup$ ")
END WarmStrTab;

PROCEDURE Free*;
  VAR l, ln: LabelNode; d, dn: DefineNode; m, mn: MacroNode; i: INTEGER;
BEGIN
  l := labelHead;
  WHILE l # NIL DO ln := l^.next; DISPOSE(l); l := ln END;
  labelHead := NIL; labelTail := NIL;
  d := defineHead;
  WHILE d # NIL DO dn := d^.next; DISPOSE(d); d := dn END;
  defineHead := NIL; defineTail := NIL;
  m := macroHead;
  WHILE m # NIL DO
    mn := m^.next;
    i := 0;
    WHILE i < m^.count DO DISPOSE(m^.body[i]); INC(i) END;
    DISPOSE(m); m := mn
  END;
  macroHead := NIL; macroTail := NIL
END Free;

(* NormalizeLocal: a NASM-style local label ".name" is scoped to the last
   non-local label -- expand it to "LAST.name" before storing/looking up,
   so ".ok"/".fail" in two different routines don't collide. *)
PROCEDURE NormalizeLocal(name: ARRAY OF CHAR; VAR full: ARRAY OF CHAR);
BEGIN
  IF name[0] = "." THEN
    IF Strings.Length(lastLabel) + Strings.Length(name) >= LEN(full) THEN
      (* BUG B3.2: composing "LAST" + ".local" into full (bounded to
         MaxName) silently truncated the LOCAL SUFFIX when the parent
         label alone was already long -- ".ok" and ".fail" under the same
         long parent could then normalise to the identical truncated
         string, silently aliasing two different branch targets. *)
      LogErr.Error2("tasm: local label too long: ", name); full[0] := 0X; RETURN
    END;
    Strings.Copy(lastLabel, full);
    Strings.Append(name, full)
  ELSE
    Strings.Copy(name, full)
  END
END NormalizeLocal;

PROCEDURE SetLastLabel*(name: ARRAY OF CHAR);
BEGIN
  IF name[0] # "." THEN Strings.Copy(name, lastLabel) END
END SetLastLabel;

(* A name never interned (StrTab.Find returns 0) cannot be any label's
   name (StrTab id 0 matches nothing), so the id compare alone is exact. *)
PROCEDURE FindNode(full: ARRAY OF CHAR; VAR node: LabelNode; VAR idx: INTEGER): BOOLEAN;
  VAR l: LabelNode; i: INTEGER; id: StrTab.TStrTabId;
BEGIN
  id := StrTab.Find(full);
  l := labelHead;
  WHILE l # NIL DO
    i := 0;
    WHILE i < l^.count DO
      IF l^.nameId[i] = id THEN
        node := l; idx := i; RETURN TRUE
      END;
      INC(i)
    END;
    l := l^.next
  END;
  RETURN FALSE
END FindNode;

(* AppendLabelSlot: E4 fix -- shared chunk-append boilerplate for
   DefineLabel/ReserveLabel (previously two near-identical NEW/init
   blocks). Grows the chunk list if the tail is full or absent, returns
   the fresh slot's node+index with name/hash already filled in; caller
   fills the remaining per-purpose fields (seg/offset/defined/isGlobal/
   defOrder/isExtern/importId). Returns FALSE on OOM (already reported via
   LogErr by this procedure; caller should just RETURN). *)
PROCEDURE AppendLabelSlot(full: ARRAY OF CHAR; VAR node: LabelNode; VAR idx: INTEGER): BOOLEAN;
  VAR last: LabelNode;
BEGIN
  IF (labelTail = NIL) OR (labelTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("out of memory (label table)"); RETURN FALSE END;
    last^.count := 0; last^.next := NIL;
    IF labelHead = NIL THEN labelHead := last ELSE labelTail^.next := last END;
    labelTail := last
  END;
  idx := labelTail^.count;
  labelTail^.nameId[idx] := StrTab.Intern(full);
  node := labelTail;
  RETURN TRUE
END AppendLabelSlot;

(* DefineLabel: record a label's definition at the current assembly
   position.  name -- raw label text (".name" local form accepted); seg --
   SegCode/SegData; offset -- byte offset within that segment; isGlobal --
   whether this label was named in a GLOBAL directive.
   A second DefineLabel for the same (already-defined) name is a fatal
   duplicate-label error -- except Pass 2 re-defining the exact same
   (seg,offset) a Pass-1 run already recorded, which is expected and a
   silent no-op (Parse.MOD calls DefineLabel again in Pass 2). *)
PROCEDURE DefineLabel*(name: ARRAY OF CHAR; seg: INTEGER; offset: LONGINT; isGlobal: BOOLEAN; fname: ARRAY OF CHAR; line: LONGINT);
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN
    IF node^.isExtern[idx] THEN
      LogErr.ErrorInFile(fname, line, "label declared EXTERN cannot also be defined locally")
    ELSIF node^.defined[idx] THEN
      IF (node^.seg[idx] = seg) & (node^.offset[idx] = offset) THEN
        (* Pass 2 redefinition with an identical value: expected, ignore *)
      ELSE
        LogErr.ErrorInFile(fname, line, "duplicate label")
      END
    ELSE
      node^.seg[idx] := seg; node^.offset[idx] := offset; node^.defined[idx] := TRUE;
      node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder);
      IF isGlobal THEN node^.isGlobal[idx] := TRUE END
    END
  ELSE
    IF ~AppendLabelSlot(full, node, idx) THEN RETURN END;
    node^.seg[idx] := seg; node^.offset[idx] := offset;
    node^.defined[idx] := TRUE; node^.isGlobal[idx] := isGlobal;
    node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder);
    node^.isExtern[idx] := FALSE; node^.importId[idx] := 0;
    INC(node^.count); INC(nLabels)
  END;
  SetLastLabel(name)
END DefineLabel;

(* DefineConst: register an EQU constant NAME = value.  Stored in the label
   table with seg=SegConst so the scanner's %define expansion never touches it
   (that only consults the define table) — which is why an EQU name does not
   self-expand on its own definition line in pass 2.  A pass-2 re-definition
   with the same value is expected (idempotent); a different value, or a clash
   with a real label of the same name, is a duplicate error. *)
PROCEDURE DefineConst*(name: ARRAY OF CHAR; value: LONGINT; fname: ARRAY OF CHAR; line: LONGINT);
  VAR node: LabelNode; idx: INTEGER;
BEGIN
  IF FindNode(name, node, idx) THEN
    IF node^.defined[idx] THEN
      IF (node^.seg[idx] = SegConst) & (node^.offset[idx] = value) THEN
        (* pass-2 identical re-definition: ignore *)
      ELSE
        LogErr.ErrorInFile(fname, line, "duplicate symbol (EQU name clashes)")
      END
    ELSE
      node^.seg[idx] := SegConst; node^.offset[idx] := value; node^.defined[idx] := TRUE;
      node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder)
    END
  ELSE
    IF ~AppendLabelSlot(name, node, idx) THEN RETURN END;
    node^.seg[idx] := SegConst; node^.offset[idx] := value;
    node^.defined[idx] := TRUE; node^.isGlobal[idx] := FALSE;
    node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder);
    node^.isExtern[idx] := FALSE; node^.importId[idx] := 0;
    INC(node^.count); INC(nLabels)
  END
END DefineConst;

(* AssignConst: register or REDEFINE a %assign constant NAME = value --
   same SegConst storage/lookup as DefineConst (so LookupConst/EvalFactor
   see no difference between an EQU name and a %assign name), but unlike
   DefineConst a differing value on redefinition is NOT an error: %assign
   is NASM's explicitly-redefinable numeric constant (distinct from
   EQU's one-shot-per-name and %define's pure text substitution). Both
   passes redefine identically since the RHS is evaluated fresh each
   time from the same source text (§I.0's two-pass replay rule), so no
   cross-pass staleness risk. A clash with a real LABEL (seg # SegConst)
   is still rejected -- %assign redefines only its own kind. *)
PROCEDURE AssignConst*(name: ARRAY OF CHAR; value: LONGINT; fname: ARRAY OF CHAR; line: LONGINT);
  VAR node: LabelNode; idx: INTEGER;
BEGIN
  IF FindNode(name, node, idx) THEN
    IF node^.defined[idx] & (node^.seg[idx] # SegConst) THEN
      LogErr.ErrorInFile(fname, line, "%assign name clashes with an existing label/EQU"); RETURN
    END;
    node^.seg[idx] := SegConst; node^.offset[idx] := value; node^.defined[idx] := TRUE;
    IF node^.defOrder[idx] = 0 THEN node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder) END
  ELSE
    IF ~AppendLabelSlot(name, node, idx) THEN RETURN END;
    node^.seg[idx] := SegConst; node^.offset[idx] := value;
    node^.defined[idx] := TRUE; node^.isGlobal[idx] := FALSE;
    node^.defOrder[idx] := nextDefOrder; INC(nextDefOrder);
    node^.isExtern[idx] := FALSE; node^.importId[idx] := 0;
    INC(node^.count); INC(nLabels)
  END
END AssignConst;

(* LookupConst: if NAME is an EQU constant, return its value and TRUE. *)
PROCEDURE LookupConst*(name: ARRAY OF CHAR; VAR value: LONGINT): BOOLEAN;
  VAR node: LabelNode; idx: INTEGER;
BEGIN
  IF FindNode(name, node, idx) & node^.defined[idx] & (node^.seg[idx] = SegConst) THEN
    value := node^.offset[idx]; RETURN TRUE
  END;
  RETURN FALSE
END LookupConst;

(* ReserveLabel: ensure a (possibly forward-referenced, not-yet-defined)
   label exists in the table so Lookup won't report "unknown symbol" for a
   genuine forward reference during Pass 1 operand scanning.  A no-op if
   the label (defined or not) already exists. *)
PROCEDURE ReserveLabel*(name: ARRAY OF CHAR);
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF ~FindNode(full, node, idx) THEN
    IF ~AppendLabelSlot(full, node, idx) THEN RETURN END;
    node^.seg[idx] := SegCode; node^.offset[idx] := 0;
    node^.defined[idx] := FALSE; node^.isGlobal[idx] := FALSE;
    node^.defOrder[idx] := -1;
    node^.isExtern[idx] := FALSE; node^.importId[idx] := 0;
    INC(node^.count); INC(nLabels)
  END
END ReserveLabel;

(* MarkExtern: declare `name` as an EXTERN/IMPORT symbol -- it will never
   receive a local ":" definition; references to it resolve via an
   RDFREC_IMPORT instead of an intra-module RDFREC_RELOC.  Reserves the
   label first if not already known (same as MarkGlobal's pattern). *)
PROCEDURE MarkExtern*(name: ARRAY OF CHAR);
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF ~FindNode(full, node, idx) THEN
    ReserveLabel(name);
    IF ~FindNode(full, node, idx) THEN RETURN END
  END;
  node^.isExtern[idx] := TRUE
END MarkExtern;

PROCEDURE IsExtern*(name: ARRAY OF CHAR): BOOLEAN;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN RETURN node^.isExtern[idx] END;
  RETURN FALSE
END IsExtern;

(* GetImportId / SetImportId: cache the RDOFF2 import segment ID assigned
   by Rdoff.RdfAddImport the first time an EXTERN symbol is actually
   referenced (so a symbol referenced N times gets exactly one IMPORT
   record, not N).  0 means "not yet assigned". *)
PROCEDURE GetImportId*(name: ARRAY OF CHAR): INTEGER;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN RETURN node^.importId[idx] END;
  RETURN 0
END GetImportId;

PROCEDURE SetImportId*(name: ARRAY OF CHAR; id: INTEGER);
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN node^.importId[idx] := id END
END SetImportId;

(* Lookup: resolve a label to its segment/offset.  Returns FALSE if the name
   was never seen at all (not even as a forward reference) -- callers that
   need "defined vs merely reserved" use IsDefined instead. *)
PROCEDURE Lookup*(name: ARRAY OF CHAR; VAR seg: INTEGER; VAR offset: LONGINT): BOOLEAN;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN
    seg := node^.seg[idx]; offset := node^.offset[idx];
    RETURN TRUE
  END;
  RETURN FALSE
END Lookup;

(* LookupDefined: like Lookup, but returns FALSE for a reserved-but-never-
   DEFINED label (Lookup returns TRUE with a placeholder offset 0 for those, so
   a branch emitter that trusted it would jump to code offset 0 — a "jump into
   nowhere").  Used by the branch/call emitters (pass 2 only, where the target
   must be defined), so an undefined target is a clean error instead of a wild
   jump even if CheckAllDefined is ever bypassed.  NOT used on the pass-1
   forward-reference data path (EmitDisp16), which legitimately needs the
   offset-0 placeholder before the label is defined. *)
PROCEDURE LookupDefined*(name: ARRAY OF CHAR; VAR seg: INTEGER; VAR offset: LONGINT): BOOLEAN;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) & node^.defined[idx] THEN
    seg := node^.seg[idx]; offset := node^.offset[idx];
    RETURN TRUE
  END;
  RETURN FALSE
END LookupDefined;

PROCEDURE IsDefined*(name: ARRAY OF CHAR): BOOLEAN;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN RETURN node^.defined[idx] END;
  RETURN FALSE
END IsDefined;

PROCEDURE IsKnown*(name: ARRAY OF CHAR): BOOLEAN;
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  RETURN FindNode(full, node, idx)
END IsKnown;

PROCEDURE MarkGlobal*(name: ARRAY OF CHAR);
  VAR full: ARRAY MaxName OF CHAR; node: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF FindNode(full, node, idx) THEN
    node^.isGlobal[idx] := TRUE
  ELSE
    ReserveLabel(name);
    IF FindNode(full, node, idx) THEN node^.isGlobal[idx] := TRUE END
  END
END MarkGlobal;

(* EnumGlobals: invoke visit(name, seg, offset) for every label marked
   GLOBAL, in definition order.  Used by Parse.MOD at end-of-assembly to
   emit RDFREC_GLOBAL records via Rdoff.RdfAddGlobal. *)
(* EnumGlobals: invoke visit(...) for every GLOBAL-marked, defined label,
   in DEFINITION order (the order each label's ":" line was reached during
   assembly) -- NOT insertion order into the table (a GLOBAL directive or a
   forward operand reference can insert a table slot long before the
   label's own defining line, see the defOrder field comment above) and
   NOT GLOBAL-directive order.  Real NASM's RDOFF2 writer emits GLOBAL
   records in label-definition order; matching it lets a TASM-produced
   .rdf byte-diff clean against a real-NASM oracle.
   Implementation: repeated "find the smallest remaining defOrder not yet
   visited" -- O(n^2) in label count, fine here (the label tables in
   SYSTEM.ASM/EMS.ASM are a few dozen entries, not thousands). *)
PROCEDURE EnumGlobals*(visit: GlobalVisitProc);
  VAR l: LabelNode; i: INTEGER;
      lastVisited, bestOrder: LONGINT;
      bestL: LabelNode; bestI: INTEGER;
      more: BOOLEAN; nameBuf: ARRAY MaxName OF CHAR;
BEGIN
  lastVisited := LONGINT(-1);
  more := TRUE;
  WHILE more DO
    bestL := NIL; bestI := -1; bestOrder := LONGINT(-1);
    l := labelHead;
    WHILE l # NIL DO
      i := 0;
      WHILE i < l^.count DO
        IF l^.isGlobal[i] & l^.defined[i] & (l^.defOrder[i] > lastVisited) THEN
          IF (bestL = NIL) OR (l^.defOrder[i] < bestOrder) THEN
            bestL := l; bestI := i; bestOrder := l^.defOrder[i]
          END
        END;
        INC(i)
      END;
      l := l^.next
    END;
    IF bestL = NIL THEN
      more := FALSE
    ELSE
      StrTab.Get(bestL^.nameId[bestI], nameBuf);
      visit(nameBuf, bestL^.seg[bestI], bestL^.offset[bestI]);
      lastVisited := bestOrder
    END
  END
END EnumGlobals;

(* CheckAllDefined: walk every label chunk once; for the first entry that
   is neither defined nor EXTERN (a forward reference Pass 1 never reached
   a ":" definition for, i.e. a typo'd/missing label), copy its name into
   `name` and return TRUE.  Called by Parse.Assemble between Pass 1 and
   Pass 2 -- this is the "Undefined-at-end-of-pass-1" check promised by
   this module's header comment but never implemented until BUG A1's fix. *)
PROCEDURE CheckAllDefined*(VAR name: ARRAY OF CHAR): BOOLEAN;
  VAR l: LabelNode; i: INTEGER;
BEGIN
  l := labelHead;
  WHILE l # NIL DO
    i := 0;
    WHILE i < l^.count DO
      IF ~l^.defined[i] & ~l^.isExtern[i] THEN
        StrTab.Get(l^.nameId[i], name); RETURN TRUE
      END;
      INC(i)
    END;
    l := l^.next
  END;
  RETURN FALSE
END CheckAllDefined;

(* ---- %define text-substitution (whole-token only, no parameters) ---- *)

PROCEDURE FindDefine(name: ARRAY OF CHAR; VAR node: DefineNode; VAR idx: INTEGER): BOOLEAN;
  VAR d: DefineNode; i: INTEGER; id: StrTab.TStrTabId;
BEGIN
  id := StrTab.Find(name);
  d := defineHead;
  WHILE d # NIL DO
    i := 0;
    WHILE i < d^.count DO
      IF d^.nameId[i] = id THEN
        node := d; idx := i; RETURN TRUE
      END;
      INC(i)
    END;
    d := d^.next
  END;
  RETURN FALSE
END FindDefine;

PROCEDURE Define*(name, value: ARRAY OF CHAR);
  VAR node, last: DefineNode; idx: INTEGER;
BEGIN
  IF FindDefine(name, node, idx) THEN
    Strings.Copy(value, node^.value[idx]); RETURN
  END;
  IF (defineTail = NIL) OR (defineTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN LogErr.Error("out of memory (define table)"); RETURN END;
    last^.count := 0; last^.next := NIL;
    IF defineHead = NIL THEN defineHead := last ELSE defineTail^.next := last END;
    defineTail := last
  END;
  idx := defineTail^.count;
  defineTail^.nameId[idx] := StrTab.Intern(name);
  Strings.Copy(value, defineTail^.value[idx]);
  INC(defineTail^.count); INC(nDefines)
END Define;

PROCEDURE Undef*(name: ARRAY OF CHAR);
  VAR node: DefineNode; idx: INTEGER; last: INTEGER;
BEGIN
  IF FindDefine(name, node, idx) THEN
    last := node^.count - 1;
    IF idx # last THEN
      node^.nameId[idx] := node^.nameId[last];
      Strings.Copy(node^.value[last], node^.value[idx])
    END;
    DEC(node^.count); DEC(nDefines)
  END
END Undef;

PROCEDURE IsDefine*(name: ARRAY OF CHAR): BOOLEAN;
  VAR node: DefineNode; idx: INTEGER;
BEGIN RETURN FindDefine(name, node, idx)
END IsDefine;

(* Expand: if name is a %define'd macro, copy its substitution text into
   out and return TRUE; else leave out untouched and return FALSE.
   Whole-token substitution only: out is re-lexed as source text by the
   caller (Parse.MOD), it is never itself further macro-expanded (matches
   the whole-token-only design decision in DOCS/IMPLRULE.MD's TASM
   section). *)
PROCEDURE Expand*(name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
  VAR node: DefineNode; idx: INTEGER;
BEGIN
  IF FindDefine(name, node, idx) THEN
    Strings.Copy(node^.value[idx], out); RETURN TRUE
  END;
  RETURN FALSE
END Expand;

(* ---- %macro storage (§I.4) ---- *)

PROCEDURE FindMacro(name: ARRAY OF CHAR; VAR node: MacroNode; VAR idx: INTEGER): BOOLEAN;
  VAR m: MacroNode; i: INTEGER; id: StrTab.TStrTabId;
BEGIN
  id := StrTab.Find(name);
  m := macroHead;
  WHILE m # NIL DO
    i := 0;
    WHILE i < m^.count DO
      IF m^.nameId[i] = id THEN
        node := m; idx := i; RETURN TRUE
      END;
      INC(i)
    END;
    m := m^.next
  END;
  RETURN FALSE
END FindMacro;

(* IsMacro: TRUE if name (already uppercased, matching %define's own
   keying convention) names a %macro. Checked by ParseLine only after
   label handling, TryDirective, and Lex.LookupMnem all miss a given
   identifier -- a %macro name must never shadow a real mnemonic or
   directive (Simplicity First: no name-collision detection/warning
   beyond "mnemonics and directives always win"). *)
PROCEDURE IsMacro*(name: ARRAY OF CHAR): BOOLEAN;
  VAR node: MacroNode; idx: INTEGER;
BEGIN RETURN FindMacro(name, node, idx)
END IsMacro;

(* GetMacro: fetch a %macro's parameter count and body pointer. Returns
   FALSE if name is not a known macro (caller should not reach this
   without checking IsMacro first, but this stays a full lookup rather
   than assuming success, matching Expand's own shape). body is the
   SAME pointer stored in the table, not a copy -- the caller must not
   DISPOSE it (Sym.Free owns that). *)
PROCEDURE GetMacro*(name: ARRAY OF CHAR; VAR nParams: INTEGER; VAR body: Scan.MemText): BOOLEAN;
  VAR node: MacroNode; idx: INTEGER;
BEGIN
  IF FindMacro(name, node, idx) THEN
    nParams := node^.nParams[idx]; body := node^.body[idx]; RETURN TRUE
  END;
  RETURN FALSE
END GetMacro;

(* DefineMacro: record a %macro's name/nParams/body. Idempotent-by-
   overwrite like Define -- Pass 2 re-records the identical
   name/nParams/body its own %macro...%endmacro capture produced in
   Pass 1 (RunPass replays the whole source per pass, %macro included),
   so a same-name redefinition on the SECOND pass is expected, not an
   error; DISPOSEs the old body first so redefinition never leaks. A
   same-name redefinition WITHIN one pass (a genuine duplicate %macro in
   source) is intentionally allowed too -- last one wins, matching
   %define's own overwrite semantics (Simplicity First: no separate
   "duplicate macro" diagnostic class). body ownership transfers to Sym
   on success; the caller must not DISPOSE it itself afterward. *)
PROCEDURE DefineMacro*(name: ARRAY OF CHAR; nParams: INTEGER; body: Scan.MemText);
  VAR node, last: MacroNode; idx: INTEGER;
BEGIN
  IF FindMacro(name, node, idx) THEN
    DISPOSE(node^.body[idx]);
    node^.nParams[idx] := nParams; node^.body[idx] := body; RETURN
  END;
  IF (macroTail = NIL) OR (macroTail^.count >= Chunk) THEN
    NEW(last);
    IF last = NIL THEN
      (* N8 fix: the caller (Parse.DoMacroRecord) transfers ownership of
         `body` unconditionally on the call -- an early RETURN here without
         disposing it leaked the body buffer on this OOM path. *)
      DISPOSE(body); LogErr.Error("out of memory (macro table)"); RETURN
    END;
    last^.count := 0; last^.next := NIL;
    IF macroHead = NIL THEN macroHead := last ELSE macroTail^.next := last END;
    macroTail := last
  END;
  idx := macroTail^.count;
  macroTail^.nameId[idx] := StrTab.Intern(name);
  macroTail^.nParams[idx] := nParams;
  macroTail^.body[idx] := body;
  INC(macroTail^.count)
END DefineMacro;

END Sym.
