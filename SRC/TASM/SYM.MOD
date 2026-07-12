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
IMPORT Strings, LogErr;

CONST
  Chunk = 32;
  MaxName* = 40;

  SegCode* = 0;
  SegData* = 1;

TYPE
  GlobalVisitProc* = PROCEDURE(name: ARRAY OF CHAR; seg: INTEGER; offset: LONGINT);

  LabelNode = POINTER TO LabelNodeDesc;
  LabelNodeDesc = RECORD
    name*:    ARRAY Chunk OF ARRAY MaxName OF CHAR;
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
       order -- verified against SRC/LIB/SYS.RDF, where "global
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

  DefineNode = POINTER TO DefineNodeDesc;
  DefineNodeDesc = RECORD
    name*:  ARRAY Chunk OF ARRAY MaxName OF CHAR;
    value*: ARRAY Chunk OF ARRAY 128 OF CHAR;
    count*: INTEGER;
    next*:  DefineNode
  END;

VAR
  labelHead, labelTail: LabelNode;
  nLabels: INTEGER;
  defineHead, defineTail: DefineNode;
  nDefines: INTEGER;
  lastLabel: ARRAY MaxName OF CHAR;   (* most recent non-local label, for .local resolution *)
  nextDefOrder: LONGINT;

PROCEDURE Init*;
BEGIN
  labelHead := NIL; labelTail := NIL; nLabels := 0;
  defineHead := NIL; defineTail := NIL; nDefines := 0;
  lastLabel[0] := 0X; nextDefOrder := LONGINT(0)
END Init;

PROCEDURE Free*;
  VAR l, ln: LabelNode; d, dn: DefineNode;
BEGIN
  l := labelHead;
  WHILE l # NIL DO ln := l^.next; DISPOSE(l); l := ln END;
  labelHead := NIL; labelTail := NIL;
  d := defineHead;
  WHILE d # NIL DO dn := d^.next; DISPOSE(d); d := dn END;
  defineHead := NIL; defineTail := NIL
END Free;

(* NormalizeLocal: a NASM-style local label ".name" is scoped to the last
   non-local label -- expand it to "LAST.name" before storing/looking up,
   so ".ok"/".fail" in two different routines don't collide. *)
PROCEDURE NormalizeLocal(name: ARRAY OF CHAR; VAR full: ARRAY OF CHAR);
BEGIN
  IF name[0] = "." THEN
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

PROCEDURE FindNode(full: ARRAY OF CHAR; VAR node: LabelNode; VAR idx: INTEGER): BOOLEAN;
  VAR l: LabelNode; i: INTEGER;
BEGIN
  l := labelHead;
  WHILE l # NIL DO
    i := 0;
    WHILE i < l^.count DO
      IF Strings.Equal(l^.name[i], full) THEN
        node := l; idx := i; RETURN TRUE
      END;
      INC(i)
    END;
    l := l^.next
  END;
  RETURN FALSE
END FindNode;

(* DefineLabel: record a label's definition at the current assembly
   position.  name -- raw label text (".name" local form accepted); seg --
   SegCode/SegData; offset -- byte offset within that segment; isGlobal --
   whether this label was named in a GLOBAL directive.
   A second DefineLabel for the same (already-defined) name is a fatal
   duplicate-label error -- except Pass 2 re-defining the exact same
   (seg,offset) a Pass-1 run already recorded, which is expected and a
   silent no-op (Parse.MOD calls DefineLabel again in Pass 2). *)
PROCEDURE DefineLabel*(name: ARRAY OF CHAR; seg: INTEGER; offset: LONGINT; isGlobal: BOOLEAN; fname: ARRAY OF CHAR; line: LONGINT);
  VAR full: ARRAY MaxName OF CHAR; node, last: LabelNode; idx: INTEGER;
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
    IF (labelTail = NIL) OR (labelTail^.count >= Chunk) THEN
      NEW(last);
      IF last = NIL THEN LogErr.Error("out of memory (label table)"); RETURN END;
      last^.count := 0; last^.next := NIL;
      IF labelHead = NIL THEN labelHead := last ELSE labelTail^.next := last END;
      labelTail := last
    END;
    idx := labelTail^.count;
    Strings.Copy(full, labelTail^.name[idx]);
    labelTail^.seg[idx] := seg; labelTail^.offset[idx] := offset;
    labelTail^.defined[idx] := TRUE; labelTail^.isGlobal[idx] := isGlobal;
    labelTail^.defOrder[idx] := nextDefOrder; INC(nextDefOrder);
    labelTail^.isExtern[idx] := FALSE; labelTail^.importId[idx] := 0;
    INC(labelTail^.count); INC(nLabels)
  END;
  SetLastLabel(name)
END DefineLabel;

(* ReserveLabel: ensure a (possibly forward-referenced, not-yet-defined)
   label exists in the table so Lookup won't report "unknown symbol" for a
   genuine forward reference during Pass 1 operand scanning.  A no-op if
   the label (defined or not) already exists. *)
PROCEDURE ReserveLabel*(name: ARRAY OF CHAR);
  VAR full: ARRAY MaxName OF CHAR; node, last: LabelNode; idx: INTEGER;
BEGIN
  NormalizeLocal(name, full);
  IF ~FindNode(full, node, idx) THEN
    IF (labelTail = NIL) OR (labelTail^.count >= Chunk) THEN
      NEW(last);
      IF last = NIL THEN LogErr.Error("out of memory (label table)"); RETURN END;
      last^.count := 0; last^.next := NIL;
      IF labelHead = NIL THEN labelHead := last ELSE labelTail^.next := last END;
      labelTail := last
    END;
    idx := labelTail^.count;
    Strings.Copy(full, labelTail^.name[idx]);
    labelTail^.seg[idx] := SegCode; labelTail^.offset[idx] := 0;
    labelTail^.defined[idx] := FALSE; labelTail^.isGlobal[idx] := FALSE;
    labelTail^.defOrder[idx] := -1;
    labelTail^.isExtern[idx] := FALSE; labelTail^.importId[idx] := 0;
    INC(labelTail^.count); INC(nLabels)
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
   SYS.ASM/EMSAPI.ASM are a few dozen entries, not thousands). *)
PROCEDURE EnumGlobals*(visit: GlobalVisitProc);
  VAR l: LabelNode; i: INTEGER;
      lastVisited, bestOrder: LONGINT;
      bestL: LabelNode; bestI: INTEGER;
      more: BOOLEAN;
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
      visit(bestL^.name[bestI], bestL^.seg[bestI], bestL^.offset[bestI]);
      lastVisited := bestOrder
    END
  END
END EnumGlobals;

(* ---- %define text-substitution (whole-token only, no parameters) ---- *)

PROCEDURE FindDefine(name: ARRAY OF CHAR; VAR node: DefineNode; VAR idx: INTEGER): BOOLEAN;
  VAR d: DefineNode; i: INTEGER;
BEGIN
  d := defineHead;
  WHILE d # NIL DO
    i := 0;
    WHILE i < d^.count DO
      IF Strings.Equal(d^.name[i], name) THEN
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
  Strings.Copy(name, defineTail^.name[idx]);
  Strings.Copy(value, defineTail^.value[idx]);
  INC(defineTail^.count); INC(nDefines)
END Define;

PROCEDURE Undef*(name: ARRAY OF CHAR);
  VAR node: DefineNode; idx: INTEGER; last: INTEGER;
BEGIN
  IF FindDefine(name, node, idx) THEN
    last := node^.count - 1;
    IF idx # last THEN
      Strings.Copy(node^.name[last], node^.name[idx]);
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
   the "78 occurrences, all whole-token" audit in DOCS/TASM_PLAN.MD). *)
PROCEDURE Expand*(name: ARRAY OF CHAR; VAR out: ARRAY OF CHAR): BOOLEAN;
  VAR node: DefineNode; idx: INTEGER;
BEGIN
  IF FindDefine(name, node, idx) THEN
    Strings.Copy(node^.value[idx], out); RETURN TRUE
  END;
  RETURN FALSE
END Expand;

END Sym.
