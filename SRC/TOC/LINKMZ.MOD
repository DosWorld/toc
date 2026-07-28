(*$D-*)
MODULE LinkMZ;
(*
  MZ-specific consumer of Link's target-agnostic core: writes a DOS real-mode
  MZ .EXE (§0 of DOCS/NE-PLAN.MD).  Owns everything the generic Link module no
  longer hardcodes for MZ: the flat MZ relocation list, the SEGRELOC callback
  that both patches a segment-value fixup and records an MZ reloc entry, the
  TDS/TDINFO (/G) debug-info writer, and the final WriteExe.

  One module = one CODE segment = one DATA segment = one BSS segment (see
  Link.CalculateLayout — no more grouping multiple modules' code together).
  Image layout: [mod1 CODE][mod1 DATA] ... [modN CODE][modN DATA]
                [mod1 BSS] ... [modN BSS] [stack]
  CODE+DATA segments carry real file bytes; BSS segments and the stack are
  memory-only (DOS zero-fills them at load via min_alloc) — see WriteExe.

  Memory strategy: the MZ reloc list and all /G debug-info state live in this
  module's own State record (LinkMZ.State), separate from Link.State — Link's
  generic core has no notion of either.
*)
IMPORT Dos, Files, LogErr, Rdoff, Tar, Strings, Link;

CONST
  MzHdrBytes = 28;       (* fixed MZ header size *)
  MZChunk    = 256;      (* MZ relocations per chunk node (small-record rule) *)
  DbgScopeChunk   = 64;  (* SCOPE_RECORD entries per chunk node (small-record rule) *)
  DbgMaxProcDepth = 8;   (* max nested-procedure depth for scope tracking (matches Syms.MaxLevel) *)

TYPE
  (* Chunked MZ relocation list (small-record rule): seg/ofs are 2 bytes each,
     so one node per reloc would waste 16-byte headers; pack MZChunk per node.
     `w` stores the relocs already in MZ wire order — {ofs, seg} per reloc, i.e.
     w[2i]=ofs, w[2i+1]=seg — so the whole chunk spills to the .exe with a SINGLE
     BlockWrite (the in-memory WORD array is little-endian, matching the format). *)
  MZReloc = POINTER TO MZRelocRec;
  MZRelocRec = RECORD
    w:     ARRAY MZChunk * 2 OF WORD;
    count: INTEGER;     (* number of relocs (each uses 2 words of w) *)
    next:  MZReloc
  END;

  (* Chunked TDS string pool (small-record rule).  Strings never span a chunk;
     on disk the chunks are written back-to-back, so the reader sees one
     contiguous NUL-separated pool.  Ordinals are 1-based string indices. *)
  PoolNode = POINTER TO PoolNodeRec;
  PoolNodeRec = RECORD
    bytes: ARRAY 2048 OF CHAR;
    used:  INTEGER;
    next:  PoolNode
  END;

  (* SCOPE_RECORD, built while pass 2 streams SYMBOL_RECORDs (a scope's
     sym_first/function are only known once those symbols are actually
     written), then emitted as array [5] after LINE_NUMBER records.  Chunked
     (small-record rule): one scope per procedure that has params/locals. *)
  ScopeNode = POINTER TO ScopeNodeDesc;
  ScopeNodeDesc = RECORD
    symFirst: ARRAY DbgScopeChunk OF WORD;
    symCnt:   ARRAY DbgScopeChunk OF WORD;
    func:     ARRAY DbgScopeChunk OF WORD;
    offset:   ARRAY DbgScopeChunk OF WORD;
    length:   ARRAY DbgScopeChunk OF WORD;
    count:    INTEGER;
    next:     ScopeNode
  END;

  State* = POINTER TO StateRec;
  StateRec* = RECORD
    genDebug*:    BOOLEAN;    (* /G: append the TDS debug block to the .exe *)
    dbgPool:      PoolNode;   (* TDS string pool chunks (head) *)
    dbgPoolTail:  PoolNode;
    dbgPoolBytes: LONGINT;    (* total pool bytes (names_pool_size) *)
    dbgNames:     INTEGER;    (* pool string count (names_count) *)
    dbgModCnt:    INTEGER;    (* modules contributing debug info *)
    dbgSymCnt:    WORD;       (* total S records *)
    dbgLineCnt:   WORD;       (* total L records *)
    dbgTypeCnt:   WORD;       (* total T records *)
    dbgMembCnt:   WORD;       (* total B records *)
    dbgScopeCnt:  WORD;       (* total scopes (one per proc with locals) *)
    dbgSymWritten:WORD;       (* running count of SYMBOL_RECORDs written so
                                 far in pass 2 — 1-based index of the NEXT
                                 symbol is dbgSymWritten+1 *)
    dbgScopeHead: ScopeNode;
    dbgScopeTail: ScopeNode;
    (* Procedure-nesting stack (small-record rule doesn't apply — fixed size,
       bounded by DbgMaxProcDepth, matches Syms.MaxLevel): a nested procedure's
       own 'P'/'A'/'E' lines appear INSIDE its enclosing procedure's stream
       (between the outer 'P' and the outer 'E'), so tracking "the most
       recent P" as flat scalars breaks as soon as any nesting occurs — the
       inner proc's context must be pushed/popped, not overwritten. *)
    dbgProcTop:     INTEGER;                        (* -1 = empty *)
    dbgProcSym:     ARRAY DbgMaxProcDepth OF WORD;   (* global 1-based sym index *)
    dbgProcOfs:     ARRAY DbgMaxProcDepth OF WORD;   (* rebased code offset *)
    dbgProcLocFirst:ARRAY DbgMaxProcDepth OF WORD;   (* first 'A' global idx for this level *)
    dbgProcLocCnt:  ARRAY DbgMaxProcDepth OF WORD;   (* 'A' count for this level *)
    dbgLocalTotal:  WORD;     (* running total of ALL 'A' symbols (header locals_count) *)
    relocHead:    MZReloc;
    relocTail:    MZReloc;
    mzRelocCnt:   WORD
  END;

PROCEDURE InitState*(ms: State);
BEGIN
  ms^.relocHead  := NIL; ms^.relocTail  := NIL;
  ms^.mzRelocCnt := 0;
  ms^.genDebug     := FALSE;
  ms^.dbgPool      := NIL; ms^.dbgPoolTail := NIL;
  ms^.dbgPoolBytes := LONGINT(0);
  ms^.dbgNames     := 0;  ms^.dbgModCnt := 0;
  ms^.dbgSymCnt    := 0;  ms^.dbgLineCnt := 0;
  ms^.dbgTypeCnt   := 0;  ms^.dbgMembCnt := 0;
  ms^.dbgScopeCnt  := 0;  ms^.dbgSymWritten := 0;
  ms^.dbgScopeHead := NIL; ms^.dbgScopeTail := NIL;
  ms^.dbgProcTop := -1; ms^.dbgLocalTotal := 0
END InitState;

(* ---- MZ reloc list ---- *)

PROCEDURE AddReloc(ms: State; seg, ofs: WORD);
  VAR r: MZReloc; k: INTEGER;
BEGIN
  (* append to tail chunk; new chunk only when full *)
  IF (ms^.relocTail = NIL) OR (ms^.relocTail^.count >= MZChunk) THEN
    NEW(r);
    IF r = NIL THEN LogErr.Error("Out of memory (MZ reloc chunk)"); RETURN END;
    r^.count := 0; r^.next := NIL;
    IF ms^.relocHead = NIL THEN ms^.relocHead := r ELSE ms^.relocTail^.next := r END;
    ms^.relocTail := r
  END;
  r := ms^.relocTail; k := r^.count;
  r^.w[2*k] := ofs; r^.w[2*k + 1] := seg;   (* MZ wire order: ofs then seg *)
  INC(r^.count);
  INC(ms^.mzRelocCnt)
END AddReloc;

(* ---- SEGRELOC callback: MZ's segRelocProc for Link.PerformLinking ----
   Structurally parallel to Link's own (removed) OnSegReloc: resolves via
   Link.CurrentState()/CurrentModule() (set by Link.ProcessModule for the
   duration of one module's relocation scan), patches via Link.PatchBuf/
   PatchDataFile, and — unlike a generic reloc — ALSO records an MZ
   relocation-table entry (the DOS loader adds the load segment to every
   entry at load time).

   One module = one CODE segment = one DATA segment now (see
   Link.CalculateLayout); BSS stays ONE shared segment across every module
   (Link.State.bssPara), same as the pre-per-module-CODE/DATA combined-
   segment model — resolving a SEGRELOC's target paragraph is "which of
   that module's own CODE/DATA segments, or the one shared BSS segment,
   and which module (for CODE/DATA)". *)
VAR curMs: State;

(* Resolve the target module + which segment a SEGRELOC's rrefSeg names,
   then return that segment's own paragraph. *)
PROCEDURE TargetSegPara(ls: Link.State; m: Link.Module; rrefSeg: INTEGER): WORD;
  VAR so: Link.Module; sym: Link.Symbol; segId: INTEGER;
BEGIN
  IF rrefSeg = Rdoff.SegCode THEN RETURN m^.codePara
  ELSIF rrefSeg = Rdoff.SegData THEN RETURN m^.dataPara
  ELSIF rrefSeg = Rdoff.SegBss THEN RETURN ls^.bssPara
  ELSE
    sym := Link.FindImport(rrefSeg);
    IF sym = Link.NoSym THEN RETURN 0 END;
    so := Link.SymOwner(ls, sym);
    segId := Link.SymSegId(ls, sym);
    IF segId = 0 THEN RETURN so^.codePara
    ELSIF segId = 1 THEN RETURN so^.dataPara
    ELSE RETURN ls^.bssPara END
  END
END TargetSegPara;

PROCEDURE OnSegReloc(rseg: INTEGER; rofs: LONGINT; rwidth: INTEGER;
                     rrefSeg: INTEGER; rrel: INTEGER); FAR;
  VAR ls: Link.State; m: Link.Module;
      fixup: WORD;      (* a segment paragraph value: WORD, not INTEGER *)
      patchAddr: LONGINT;
      mzSeg, mzOfs: WORD;   (* MZ reloc seg:ofs — absolute values -> WORD *)
BEGIN
  ls := Link.CurrentState();
  m  := Link.CurrentModule();
  IF rseg = Rdoff.SegCode THEN patchAddr := rofs
  ELSE patchAddr := Link.DataFileOffsetOf(ls, m, rofs) END;

  fixup := TargetSegPara(ls, m, rrefSeg);

  IF rseg = Rdoff.SegCode THEN Link.PatchBuf(patchAddr, fixup, 2)
  ELSE Link.PatchDataFile(patchAddr, fixup, 2) END;

  (* add MZ reloc entry (offset in load image, 0-based from image start) *)
  IF rseg = Rdoff.SegCode THEN
    mzSeg := m^.codePara;
    mzOfs := WORD(rofs)
  ELSE
    mzSeg := m^.dataPara;
    mzOfs := WORD(rofs)
  END;
  AddReloc(curMs, mzSeg, mzOfs)
END OnSegReloc;

(* Called by TOC.MOD in place of Link.PerformLinking directly: stashes ms
   (curMs) for OnSegReloc's duration, then drives the generic core with MZ's
   own segRelocProc. *)
PROCEDURE PerformLinking*(ls: Link.State; ms: State);
BEGIN
  curMs := ms;
  Link.PerformLinking(ls, Link.OnReloc, OnSegReloc)
END PerformLinking;

(* ---- TDS/TDINFO debug block (/G) ----

   Merges the MODNAME.DBG text members of the used modules into one binary
   TDS v2.08 block appended after the data image (dbg.md §5; layouts per
   docs/td-spec.md §EMPIRICAL: 48-byte header w/ reserved[14],
   SOURCE_FILE = name+time+date, LINE = (line, offset) — line word FIRST,
   one CORRELATION per module).  No MZ header field changes and no MZ relocs
   (model B) — without /G the .exe is byte-identical.

   Memory strategy: NO record tables are built.  Each module's .DBG is
   extracted (TarExtract → temp) once per pass — pass 1 counts records and
   interns names into the chunked string pool; passes 2/3 stream the symbol
   and line arrays straight to the output file.  Only the string pool lives
   in the heap (chunked, deduplicated, freed in LinkFree). *)

(* Find name in the chunked pool or append it; returns the 1-based string
   ordinal (TDS pool indices are ordinals, not byte offsets).
   O(pool) per intern (O(n^2) per link) — ACCEPTED: /G debug links intern a
   few thousand names at most (measured well under a second under xt); a hash
   over the pool would cost heap the linker is short of.  Revisit only if /G
   link time becomes noticeable. *)
PROCEDURE DbgIntern(ms: State; VAR name: ARRAY OF CHAR): INTEGER;
  VAR p: PoolNode; i, j, k, ord, len: INTEGER; match: BOOLEAN;
BEGIN
  ord := 1;
  p := ms^.dbgPool;
  WHILE p # NIL DO
    i := 0;
    WHILE i < p^.used DO
      k := i; j := 0; match := TRUE;
      WHILE match & (p^.bytes[k] # 0X) & (name[j] # 0X) DO
        IF p^.bytes[k] # name[j] THEN match := FALSE ELSE INC(k); INC(j) END
      END;
      IF match & (p^.bytes[k] = 0X) & (name[j] = 0X) THEN RETURN ord END;
      WHILE p^.bytes[k] # 0X DO INC(k) END;   (* skip to end of pool string *)
      i := k + 1; INC(ord)
    END;
    p := p^.next
  END;
  (* not found: append (strings never span a chunk) *)
  len := 0; WHILE name[len] # 0X DO INC(len) END;
  IF (ms^.dbgPoolTail = NIL) OR (ms^.dbgPoolTail^.used + len + 1 > 2048) THEN
    NEW(p);
    IF p = NIL THEN LogErr.Error("Out of memory (debug pool)"); RETURN 0 END;
    p^.used := 0; p^.next := NIL;
    IF ms^.dbgPoolTail = NIL THEN ms^.dbgPool := p ELSE ms^.dbgPoolTail^.next := p END;
    ms^.dbgPoolTail := p
  END;
  p := ms^.dbgPoolTail;
  k := 0;
  WHILE k <= len DO p^.bytes[p^.used] := name[k]; INC(p^.used); INC(k) END;
  ms^.dbgPoolBytes := ms^.dbgPoolBytes + LONGINT(len + 1);
  INC(ms^.dbgNames);
  RETURN ms^.dbgNames
END DbgIntern;

(* Read one CRLF/LF-terminated line from f; FALSE at EOF. *)
PROCEDURE DbgReadLine(VAR f: Files.File; VAR s: ARRAY OF CHAR): BOOLEAN;
  VAR b: BYTE; k: INTEGER; more: BOOLEAN;
BEGIN
  k := 0;
  more := Files.ReadByte(f, b);
  IF ~more THEN s[0] := 0X; RETURN FALSE END;
  WHILE more & (b # BYTE(10)) DO
    IF (b # BYTE(13)) & (k < LEN(s) - 1) THEN s[k] := CHR(b); INC(k) END;
    more := Files.ReadByte(f, b)
  END;
  s[k] := 0X;
  RETURN TRUE
END DbgReadLine;

(* Fixed-width 4-digit uppercase hex at s[p] (TDbg offset format). *)
PROCEDURE DbgHex4(VAR s: ARRAY OF CHAR; p: INTEGER): WORD;
  VAR v: WORD; k, d: INTEGER; c: CHAR;
BEGIN
  v := 0; k := 0;
  WHILE k < 4 DO
    c := s[p + k];
    IF (c >= "0") & (c <= "9") THEN d := ORD(c) - ORD("0")
    ELSE d := ORD(c) - ORD("A") + 10 END;
    v := v * 16 + WORD(d);
    INC(k)
  END;
  RETURN v
END DbgHex4;

(* Decimal number at s[p]. *)
PROCEDURE DbgDec(VAR s: ARRAY OF CHAR; p: INTEGER): INTEGER;
  VAR v: INTEGER;
BEGIN
  v := 0;
  WHILE (s[p] >= "0") & (s[p] <= "9") DO
    v := v * 10 + (ORD(s[p]) - ORD("0"));
    INC(p)
  END;
  RETURN v
END DbgDec;

PROCEDURE DbgNameAt(VAR s: ARRAY OF CHAR; p: INTEGER; VAR nm: ARRAY OF CHAR);
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE (s[p] # 0X) & (k < LEN(nm) - 1) DO nm[k] := s[p]; INC(k); INC(p) END;
  nm[k] := 0X
END DbgNameAt;

(* Append one SCOPE_RECORD (small-record chunked table, flushed as array [5]
   after LINE_NUMBER records in WriteDebugInfo). *)
PROCEDURE AddScope(ms: State; symFirst, symCnt, func, offset, length: WORD);
  VAR n: ScopeNode;
BEGIN
  IF (ms^.dbgScopeTail = NIL) OR (ms^.dbgScopeTail^.count = DbgScopeChunk) THEN
    NEW(n);
    IF n = NIL THEN LogErr.Error("Out of memory (debug scope chunk)"); RETURN END;
    n^.count := 0; n^.next := NIL;
    IF ms^.dbgScopeTail # NIL THEN ms^.dbgScopeTail^.next := n ELSE ms^.dbgScopeHead := n END;
    ms^.dbgScopeTail := n
  END;
  ms^.dbgScopeTail^.symFirst[ms^.dbgScopeTail^.count] := symFirst;
  ms^.dbgScopeTail^.symCnt[ms^.dbgScopeTail^.count]   := symCnt;
  ms^.dbgScopeTail^.func[ms^.dbgScopeTail^.count]     := func;
  ms^.dbgScopeTail^.offset[ms^.dbgScopeTail^.count]   := offset;
  ms^.dbgScopeTail^.length[ms^.dbgScopeTail^.count]   := length;
  INC(ms^.dbgScopeTail^.count);
  INC(ms^.dbgScopeCnt)
END AddScope;

(* One streaming pass over module m's MODNAME.DBG member (absent or 0-byte
   member = module contributes nothing).  .DBG line columns are fixed:
     S c XXXX s YYYY name  (c: P/V/Y/A; XXXX: hex4 offset (signed bit-pattern
                            for A); s: C/D/-; YYYY: hex4 local TYPE index)
     S E LLLL - 0000       (scope-end marker, NOT a real symbol; LLLL = the
                            most recent P's own code length)
     T II SSSS CC MMMM name|-  (II: hex4 TD type-id; SSSS: hex4 size;
                                 CC: hex4 class_type; MMMM: hex4 member_type)
     B II TTTT name            (II: hex4 info; TTTT: hex4 field TYPE index)
     L XXXX nnn        (hex4 code offset; decimal line)
     M name / F name / C nnn / D 1
   pass 1: count records + intern names + set m^.hasDbg/dbgModName/dbgSrcName/
           dbgTypeBase/dbgMembBase (bases are running totals BEFORE this
           module's own T/B records, so pass 1 must run in module order and
           read the previous totals before adding this module's counts).
           'E' lines do not count as symbols.
   pass 2: write SYMBOL_RECORDs (rebased) to fout; build SCOPE_RECORDs (needs
           the just-written global index of each 'P'/'A' symbol, and the
           preceding 'P' to close on 'E' — so scopes can only be built here,
           not in a later pass).
   pass 3: write LINE_NUMBER_RECORDs — (line, offset), line word FIRST.
   pass 4: write TYPE_RECORDs (rebased member_type).
   pass 5: write MEMBER_RECORDs (rebased type). *)
PROCEDURE DbgPass(ms: State; m: Link.Module; pass: INTEGER; VAR fout: Files.File);
  VAR f: Files.File;
      s: ARRAY 96 OF CHAR;
      memb: ARRAY 14 OF CHAR;
      nm: ARRAY 40 OF CHAR;
      offw, segw, typw: WORD;
      any: BOOLEAN;
BEGIN
  IF m^.stem[0] = 0X THEN RETURN END;
  Strings.Copy(m^.stem, memb); Strings.Append(".DBG", memb);
  IF ~Tar.TarExtract(m^.path, memb, f) THEN RETURN END;
  any := FALSE;
  IF pass = 1 THEN m^.dbgTypeBase := ms^.dbgTypeCnt; m^.dbgMembBase := ms^.dbgMembCnt END;
  IF (pass = 1) OR (pass = 2) THEN ms^.dbgProcTop := -1 END;
  WHILE DbgReadLine(f, s) DO
    IF (s[0] = "S") & (s[2] = "E") THEN
      (* close the innermost open 'P' scope (nested procedures push/pop a
         stack frame — a nested proc's own P..E fully nests inside its
         enclosing proc's P..E in the .DBG stream, so "the most recent P"
         must be a stack top, not a flat scalar, or an inner proc's context
         clobbers the outer one's before the outer 'E' is reached).
         A SCOPE_RECORD is only produced if the frame collected at least one
         local/param (matches how real TLINK skips empty scopes — verified:
         probe has no zero-local scope entries).  Counted in pass 1 (header
         needs scopes_count before pass 2 runs); built in pass 2 once symbol
         indices are known. *)
      IF ms^.dbgProcTop >= 0 THEN
        IF pass = 1 THEN
          IF ms^.dbgProcLocCnt[ms^.dbgProcTop] > 0 THEN INC(ms^.dbgScopeCnt) END
        ELSIF pass = 2 THEN
          IF ms^.dbgProcLocCnt[ms^.dbgProcTop] > 0 THEN
            AddScope(ms, ms^.dbgProcLocFirst[ms^.dbgProcTop], ms^.dbgProcLocCnt[ms^.dbgProcTop],
                     ms^.dbgProcSym[ms^.dbgProcTop], ms^.dbgProcOfs[ms^.dbgProcTop], DbgHex4(s, 4))
          END
        END;
        DEC(ms^.dbgProcTop)
      END
    ELSIF s[0] = "S" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 16, nm);
        DbgIntern(ms, nm);          (* result discarded: intern only *)
        INC(ms^.dbgSymCnt); any := TRUE;
        IF s[2] = "P" THEN
          IF ms^.dbgProcTop < DbgMaxProcDepth - 1 THEN INC(ms^.dbgProcTop) END;
          ms^.dbgProcLocCnt[ms^.dbgProcTop] := 0
        ELSIF s[2] = "A" THEN
          INC(ms^.dbgLocalTotal);
          IF ms^.dbgProcTop >= 0 THEN INC(ms^.dbgProcLocCnt[ms^.dbgProcTop]) END
        END
      ELSIF pass = 2 THEN
        DbgNameAt(s, 16, nm);
        Files.WriteWord(fout, DbgIntern(ms, nm));       (* name index (hit) *)
        typw := DbgHex4(s, 11);
        IF typw # 0 THEN typw := typw + m^.dbgTypeBase END;
        Files.WriteWord(fout, INTEGER(typw));
        offw := DbgHex4(s, 4);
        IF s[2] = "P" THEN                              (* proc: code seg —
             offw is already the module's own code offset, final as-is *)
          segw := m^.codePara
        ELSIF (s[2] = "Y") OR (s[2] = "A") THEN
          (* typedef: no location.  local/param: offw is a signed BP offset,
             already correct as-is — no code/data rebasing. *)
          IF s[2] = "Y" THEN offw := 0 END;
          segw := 0
        ELSE                                            (* global VAR: data *)
          (* offw is already the module's own data offset — already final *)
          segw := m^.dataPara
        END;
        Files.WriteWord(fout, INTEGER(offw));
        Files.WriteWord(fout, INTEGER(segw));
        INC(ms^.dbgSymWritten);
        IF s[2] = "Y" THEN Files.WriteByte(fout, BYTE(6))     (* TYPEDEF *)
        ELSIF s[2] = "A" THEN
          Files.WriteByte(fout, BYTE(2));                     (* AUTO *)
          IF ms^.dbgProcTop >= 0 THEN
            IF ms^.dbgProcLocCnt[ms^.dbgProcTop] = 0 THEN
              ms^.dbgProcLocFirst[ms^.dbgProcTop] := ms^.dbgSymWritten
            END;
            INC(ms^.dbgProcLocCnt[ms^.dbgProcTop])
          END
        ELSE
          Files.WriteByte(fout, BYTE(0));                     (* STATIC *)
          IF s[2] = "P" THEN
            IF ms^.dbgProcTop < DbgMaxProcDepth - 1 THEN INC(ms^.dbgProcTop) END;
            ms^.dbgProcSym[ms^.dbgProcTop] := ms^.dbgSymWritten;
            ms^.dbgProcOfs[ms^.dbgProcTop] := offw;
            ms^.dbgProcLocCnt[ms^.dbgProcTop] := 0
          END
        END
      END
    ELSIF s[0] = "L" THEN
      IF pass = 1 THEN INC(ms^.dbgLineCnt); any := TRUE
      ELSIF pass = 3 THEN
        Files.WriteWord(fout, DbgDec(s, 7));            (* line FIRST *)
        offw := DbgHex4(s, 2);   (* module's own code offset — already final *)
        Files.WriteWord(fout, INTEGER(offw))
      END
    ELSIF s[0] = "T" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 22, nm);
        IF nm[0] # "-" THEN DbgIntern(ms, nm) END;   (* intern now: header pool size is snapshotted right after pass 1 *)
        INC(ms^.dbgTypeCnt); any := TRUE
      ELSIF pass = 4 THEN
        (* TYPE_RECORD wire order (docs/tdinfo.c, packed 8 bytes):
           id(1), name(2), size(2), class_type(1), member_type(2). *)
        DbgNameAt(s, 22, nm);
        Files.WriteByte(fout, BYTE(DbgHex4(s, 2)));       (* id *)
        IF nm[0] = "-" THEN Files.WriteWord(fout, 0)
        ELSE Files.WriteWord(fout, DbgIntern(ms, nm)) END; (* name *)
        Files.WriteWord(fout, INTEGER(DbgHex4(s, 7)));    (* size *)
        Files.WriteByte(fout, BYTE(DbgHex4(s, 12)));       (* class_type *)
        typw := DbgHex4(s, 17);                            (* member_type *)
        IF typw # 0 THEN
          (* STRUCT's member_type indexes MEMBER_RECORD; everything else
             (ARRAY elem / POINTER target) indexes TYPE_RECORD.  id 30=STRUCT. *)
          IF DbgHex4(s, 2) = WORD(30) THEN typw := typw + m^.dbgMembBase
          ELSE typw := typw + m^.dbgTypeBase END
        END;
        Files.WriteWord(fout, INTEGER(typw))
      END
    ELSIF s[0] = "B" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 12, nm);
        DbgIntern(ms, nm);          (* result discarded: intern only *)
        INC(ms^.dbgMembCnt); any := TRUE
      ELSIF pass = 5 THEN
        (* MEMBER_RECORD wire order (docs/tdinfo.c, packed 5 bytes):
           info(1), name(2), type(2). *)
        DbgNameAt(s, 12, nm);
        Files.WriteByte(fout, BYTE(DbgHex4(s, 2)));       (* info *)
        Files.WriteWord(fout, DbgIntern(ms, nm));          (* name *)
        typw := DbgHex4(s, 7);
        IF typw # 0 THEN typw := typw + m^.dbgTypeBase END;
        Files.WriteWord(fout, INTEGER(typw))               (* type *)
      END
    ELSIF s[0] = "M" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 2, nm); m^.dbgModName := DbgIntern(ms, nm); any := TRUE
      END
    ELSIF s[0] = "F" THEN
      IF pass = 1 THEN
        DbgNameAt(s, 2, nm); m^.dbgSrcName := DbgIntern(ms, nm); any := TRUE
      END
    END
    (* "D" (version) and "C" (code length) lines are ignored: m^.codeSize from
       the RDOFF header is authoritative for the SEGMENT record. *)
  END;
  Files.Close(f);
  IF (pass = 1) & any THEN m^.hasDbg := TRUE; INC(ms^.dbgModCnt) END
END DbgPass;

(* Append the merged TDS block to fout (which is positioned right after the
   data image).  Pure append: no MZ header field and no relocation changes, so
   without /G the output is byte-identical (immediate RETURN). *)
PROCEDURE WriteDebugInfo(ls: Link.State; ms: State; VAR fout: Files.File);
  VAR m: Link.Module; p: PoolNode; i, k, j: INTEGER; scNode: ScopeNode;
BEGIN
  IF ~ms^.genDebug THEN RETURN END;

  (* pass 1: counts + string pool + per-module name ordinals *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.used & ~m^.dup THEN DbgPass(ms, m, 1, fout) END;
    m := m^.next
  END;
  IF ms^.dbgModCnt = 0 THEN RETURN END;    (* no $D+ module linked: no block *)

  (* TDINFO_HEADER — 48 bytes: magic, ver 2.08, pool size, 12 counts,
     reserved[14], extension_size=0 *)
  Files.WriteWord(fout, 052FBH);
  Files.WriteByte(fout, BYTE(8));                  (* minor *)
  Files.WriteByte(fout, BYTE(2));                  (* major *)
  Files.WriteDWord(fout, ms^.dbgPoolBytes);
  Files.WriteWord(fout, ms^.dbgNames);             (* names_count *)
  Files.WriteWord(fout, INTEGER(ms^.dbgTypeCnt));  (* types *)
  Files.WriteWord(fout, INTEGER(ms^.dbgMembCnt));  (* members *)
  Files.WriteWord(fout, INTEGER(ms^.dbgSymCnt));   (* symbols *)
  Files.WriteWord(fout, 0);                        (* globals *)
  Files.WriteWord(fout, ms^.dbgModCnt);            (* modules *)
  Files.WriteWord(fout, INTEGER(ms^.dbgLocalTotal));(* locals (informational) *)
  Files.WriteWord(fout, INTEGER(ms^.dbgScopeCnt)); (* scopes *)
  Files.WriteWord(fout, INTEGER(ms^.dbgLineCnt));  (* line numbers *)
  Files.WriteWord(fout, ms^.dbgModCnt);            (* source files *)
  Files.WriteWord(fout, ms^.dbgModCnt);            (* segments *)
  Files.WriteWord(fout, ms^.dbgModCnt);            (* correlations *)
  k := 0; WHILE k < 14 DO Files.WriteByte(fout, BYTE(0)); INC(k) END;
  Files.WriteWord(fout, 0);                        (* extension_size *)

  (* [1] SYMBOL_RECORDs *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ms, m, 2, fout) END;
    m := m^.next
  END;

  (* [2] MODULE_RECORDs: name + 14 zero bytes *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, m^.dbgModName);
      k := 0; WHILE k < 14 DO Files.WriteByte(fout, BYTE(0)); INC(k) END
    END;
    m := m^.next
  END;

  (* [3] SOURCE_FILE records: name index + DOS time/date (0 in Phase 1) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, m^.dbgSrcName);
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0)
    END;
    m := m^.next
  END;

  (* [4] LINE_NUMBER records *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ms, m, 3, fout) END;
    m := m^.next
  END;

  (* [5] SCOPE_RECORDs — built in RAM during pass 2 (small: one per procedure
     with locals/params), so just stream the chunk list; no extra DbgPass. *)
  scNode := ms^.dbgScopeHead;
  WHILE scNode # NIL DO
    j := 0;
    WHILE j < scNode^.count DO
      Files.WriteWord(fout, INTEGER(scNode^.symFirst[j]));
      Files.WriteWord(fout, INTEGER(scNode^.symCnt[j]));
      Files.WriteWord(fout, 0);                        (* parent: none (flat scopes) *)
      Files.WriteWord(fout, INTEGER(scNode^.func[j]));
      Files.WriteWord(fout, INTEGER(scNode^.offset[j]));
      Files.WriteWord(fout, INTEGER(scNode^.length[j]));
      INC(j)
    END;
    scNode := scNode^.next
  END;

  (* [6] SEGMENT records: one per module — the module's own CS segment,
     whole (one module = one segment now, never a slice of a shared one) *)
  i := 1;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, i);                          (* module (1-based) *)
      Files.WriteWord(fout, INTEGER(m^.codePara));       (* code_segment *)
      Files.WriteWord(fout, 0);                          (* code_offset: 0 — one module = one CS segment now *)
      Files.WriteWord(fout, INTEGER(m^.codeSize));       (* code_length *)
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0);(* scope idx/cnt *)
      Files.WriteWord(fout, 0); Files.WriteWord(fout, 0);(* 4 pad bytes *)
      INC(i)
    END;
    m := m^.next
  END;

  (* [7] CORRELATION records: srcfile i <-> segment i <-> module i *)
  i := 1;
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN
      Files.WriteWord(fout, i); Files.WriteWord(fout, i);
      Files.WriteWord(fout, i); Files.WriteWord(fout, 0007H);
      INC(i)
    END;
    m := m^.next
  END;

  (* [8] TYPE_RECORDs (rebased member_type) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ms, m, 4, fout) END;
    m := m^.next
  END;

  (* [9] MEMBER_RECORDs (rebased type) *)
  m := ls^.modHead;
  WHILE m # NIL DO
    IF m^.hasDbg THEN DbgPass(ms, m, 5, fout) END;
    m := m^.next
  END;

  (* [10] string pool — chunks written back-to-back *)
  p := ms^.dbgPool;
  WHILE p # NIL DO
    IF p^.used > 0 THEN
      IF Files.BlockWrite(fout, p^.bytes[0], WORD(p^.used)) # WORD(p^.used) THEN
        LogErr.Error("Write error (debug pool)")
      END
    END;
    p := p^.next
  END
END WriteDebugInfo;

(* ---- write MZ EXE ---- *)

(* Copy n bytes of the linked code image from the spill file into fout, then
   close (and so delete) the spill file.  The spill file is the one opened in
   Link.PerformLinking and left open + rewound; it is never reopened by name.
   The chunked copy itself lives in Link.CopySpan (shared with LinkNE). *)
PROCEDURE CopyCodeImage(ls: Link.State; VAR fout: Files.File; n: LONGINT);
BEGIN
  IF n > LONGINT(0) THEN Files.BlockCopy(ls^.spillFile, fout, n) END;
  Files.Close(ls^.spillFile)   (* delete-on-close removes LNKCODE.TMP *)
END CopyCodeImage;

PROCEDURE WriteExe*(ls: Link.State; ms: State; outPath: ARRAY OF CHAR);
  VAR fout: Files.File;
      hdrPara: INTEGER;
      exeSize, fileImageLen: LONGINT;
      partPage, pageCnt: INTEGER;
      hdrBytes: LONGINT;
      gapBytes: LONGINT;
      rel: MZReloc;
      ssPara: LONGINT;
      stackPara, minAlloc: LONGINT;
      summary: ARRAY 128 OF CHAR;
BEGIN
  IF ~Files.ReWrite(fout, outPath) THEN LogErr.Error2("Cannot write: ", outPath); RETURN END;

  (* File image = every module's own CODE segment, then every module's own
     DATA segment (both carry real bytes — see Link.CalculateLayout).  BSS
     segments follow but carry NO file bytes at all: DOS zero-fills them at
     load via min_alloc, which only works because nothing with real file
     bytes follows BSS in the image (stack is memory-only too). *)
  fileImageLen := ls^.totalCodeLen + ls^.totalDataLen;
  hdrBytes     := LONGINT(MzHdrBytes) + LONGINT(ms^.mzRelocCnt) * LONGINT(4);
  hdrPara      := INTEGER((hdrBytes + LONGINT(15)) DIV LONGINT(16)) + 1;

  exeSize  := LONGINT(hdrPara) * LONGINT(16) + fileImageLen;
  pageCnt  := INTEGER(exeSize DIV LONGINT(512));
  partPage := INTEGER(exeSize MOD LONGINT(512));
  IF partPage # 0 THEN INC(pageCnt) END;

  (* SS paragraph: right after every module's CODE+DATA+BSS (see the image
     layout comment on Link.CalculateLayout) — code_data_para + bss_para. *)
  ssPara := (ls^.totalCodeLen + ls^.totalDataLen + ls^.totalBssLen) DIV LONGINT(16);

  (* min/max_alloc: static memory needed BEYOND the file image — the BSS
     region (memory-only, zero-filled by DOS) plus the stack.  We set
     min = max so DOS gives us exactly what we need and leaves the rest
     free for the runtime heap (INT 21h/48h in SYSTEM_INIT) and for
     Dos.Exec child processes.  Using 0/0FFFFH (old behaviour) hogs all
     free memory and breaks both. *)
  stackPara := (ls^.stackSize + LONGINT(15)) DIV LONGINT(16);
  minAlloc  := (ls^.totalBssLen DIV LONGINT(16)) + stackPara;
  IF minAlloc > LONGINT(0FFFFH) THEN minAlloc := LONGINT(0FFFFH) END;

  (* write MZ header *)
  Files.WriteWord(fout, 5A4DH);
  Files.WriteWord(fout, partPage);
  Files.WriteWord(fout, pageCnt);
  Files.WriteWord(fout, INTEGER(ms^.mzRelocCnt));
  Files.WriteWord(fout, hdrPara);
  Files.WriteWord(fout, INTEGER(minAlloc));
  Files.WriteWord(fout, INTEGER(minAlloc));
  Files.WriteWord(fout, INTEGER(ssPara));            (* SS *)
  Files.WriteWord(fout, INTEGER(ls^.stackSize) - 2);(* SP *)
  Files.WriteWord(fout, 0);                          (* checksum *)
  Files.WriteWord(fout, ls^.entryIp);               (* IP *)
  Files.WriteWord(fout, ls^.entryCSPara);           (* CS *)
  Files.WriteWord(fout, MzHdrBytes);                (* reloc table offset *)
  Files.WriteWord(fout, 0);                          (* overlay *)

  (* write MZ relocation table — one BlockWrite per chunk (w already holds the
     relocs in MZ wire order: count*2 little-endian WORDs). *)
  rel := ms^.relocHead;
  WHILE rel # NIL DO
    IF rel^.count > 0 THEN
      IF Files.BlockWrite(fout, rel^.w[0], WORD(rel^.count * 2 * 2)) # WORD(rel^.count * 2 * 2) THEN
        LogErr.Error("Write error (MZ reloc)")
      END
    END;
    rel := rel^.next
  END;

  (* pad header to hdrPara * 16 *)
  gapBytes := LONGINT(hdrPara) * LONGINT(16) - Files.Position(fout);
  Link.WriteZeros(fout, gapBytes);

  (* copy the linked code image (totalCodeLen bytes) from the spill file *)
  CopyCodeImage(ls, fout, ls^.totalCodeLen);

  (* write data segment: copy from the file-backed ls^.dataFile (rewound
     first) instead of a resident RAM buffer — see LINKBUF-REPORT.MD §4.1.
     Files.BlockCopy already does exactly this chunked-copy pattern
     (staged through its own small stack buffer). *)
  IF ls^.totalDataLen > LONGINT(0) THEN
    Files.Seek(ls^.dataFile, LONGINT(0));
    IF ~Files.BlockCopy(ls^.dataFile, fout, ls^.totalDataLen) THEN
      LogErr.Error("Write error (data)")
    END
  END;
  Files.Close(ls^.dataFile);   (* delete-on-close removes the data temp *)

  (* /G: append the TDS debug block after the data image (debugger-only tail —
     DOS loads only header+code+data; no header field above changes). *)
  WriteDebugInfo(ls, ms, fout);

  Files.Close(fout);
  IF ~Files.Ok(fout) THEN
    (* Disk-full during any buffered flush: without this the truncated .exe
       was reported as linked.  TOC.LinkAll deletes the output on HaveErr. *)
    LogErr.Error2("Write error (disk full?): ", outPath);
    RETURN
  END;

  Strings.Copy(outPath, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(ls^.totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(ls^.totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(ls^.totalBssLen,  summary);
  Strings.Append(", Stack=", summary); Strings.AppendInt(ls^.stackSize,   summary);
  LogErr.Info(summary)
END WriteExe;

(* Release ms's own chains (MZ reloc list + TDS debug state).  Link.LinkFree
   still releases everything in Link.State (modules, symbols, groups). *)
PROCEDURE LinkFree*(ms: State);
  VAR r, rNext: MZReloc; p, pNext: PoolNode; sc, scNext: ScopeNode;
BEGIN
  p := ms^.dbgPool;
  WHILE p # NIL DO pNext := p^.next; DISPOSE(p); p := pNext END;
  ms^.dbgPool := NIL; ms^.dbgPoolTail := NIL;

  sc := ms^.dbgScopeHead;
  WHILE sc # NIL DO scNext := sc^.next; DISPOSE(sc); sc := scNext END;
  ms^.dbgScopeHead := NIL; ms^.dbgScopeTail := NIL;

  r := ms^.relocHead;
  WHILE r # NIL DO rNext := r^.next; DISPOSE(r); r := rNext END;
  ms^.relocHead := NIL; ms^.relocTail := NIL
END LinkFree;

END LinkMZ.
