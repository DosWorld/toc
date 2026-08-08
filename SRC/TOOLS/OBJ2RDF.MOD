MODULE Obj2Rdf;
(*
  obj2rdf — convert a 16-bit Microsoft/Intel OMF .OBJ file into a RDOFF2
  .rdf file, so legacy Turbo Assembler/MASM-era object code can be linked
  by this toolchain's `toc`/`Link`.

  usage: obj2rdf FILE.OBJ
  Writes FILE.RDF (same basename, extension replaced) in the current
  directory.

  General-purpose 16-bit-OMF converter, not limited to any specific
  source .OBJ — code/data segments are staged in full-size (65000-byte,
  matching Rdoff.SegLimit) far heap buffers, and name/external/segment
  tables are sized for real-world .OBJ files (up to 1024 EXTDEF/PUBDEF
  names, 512 LNAMES entries, 64 SEGDEF records).

  Record format reference: Microsoft SS0288 "Relocatable Object Module
  Format" application note (DOCS/OBJ.ZIP).  Only the record types actually
  needed to convert real 16-bit .OBJ files are implemented; anything
  requiring semantics RDOFF2 cannot express is a hard error, never a
  silent guess:

    - RDOFF2 has exactly two physical segments (code, data), so exactly
      one CODE-class-or-named SEGDEF and one DATA-class-or-named SEGDEF
      are MAPPED and used (SEGDEF's segment-name field is checked first,
      falling back to class name — real .OBJ files seen so far use empty
      class names but meaningful segment names).  A second SEGDEF that
      would map to an already-used slot is rejected; unmapped SEGDEFs
      (any other name/class) are tolerated and simply never referenced by
      an emitted RELOC/SEGRELOC/GLOBAL.  Any GRPDEF is rejected outright
      (no group-relative addressing model in RDOFF2).
    - COMDEF/LCOMDEF (communal variables) are rejected.
    - LIDATA is supported only for the simple (non-nested) repeat form
      (Block Count = 0); nested block counts are rejected.
    - FIXUP subrecords: only Location=1 (16-bit offset) and Location=2
      (16-bit segment base) are supported (RDOFF2's RELOC/SEGRELOC have no
      other patch shapes); TARGET must resolve to a mapped SEGDEF or an
      EXTDEF (GRPDEF-as-target, or an explicit frame number, is rejected).
      FRAME is accepted from any method except an explicit frame number
      (method 3) — for Location=1/2, FRAME only documents the translator's
      runtime segment-register assumption and does not change what bytes
      RDOFF2 needs to write (see ValidateFrame's own comment for the full
      reasoning). THREAD subrecords are tracked as state, since FIXUP
      subrecords may reference them instead of specifying FRAME/TARGET
      explicitly.

  Every OMF record is read fully into a small stack/heap buffer per record
  (max content 1024 bytes per the spec) before being interpreted --
  simpler and safer than tracking partial reads across record boundaries.
*)
IMPORT Files, Strings, Out, Dos, LogErr, Rdoff, StrTab;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;
  ExitFormat = 4;

  (* OMF record type bytes actually handled *)
  RtTHEADR  = 080H;
  RtLHEADR  = 082H;
  RtCOMENT  = 088H;
  RtMODEND1 = 08AH;
  RtMODEND2 = 08BH;
  RtEXTDEF  = 08CH;
  RtPUBDEF1 = 090H;
  RtPUBDEF2 = 091H;
  RtLNAMES  = 096H;
  RtSEGDEF1 = 098H;
  RtSEGDEF2 = 099H;
  RtGRPDEF  = 09AH;
  RtFIXUPP1 = 09CH;
  RtFIXUPP2 = 09DH;
  RtLEDATA1 = 0A0H;
  RtLEDATA2 = 0A1H;
  RtLIDATA1 = 0A2H;
  RtLIDATA2 = 0A3H;
  RtCOMDEF  = 0B0H;
  RtLEXTDEF = 0B4H;
  RtLCOMDEF = 0B8H;

  MaxRec    = 1024;   (* max OMF record content per spec *)
  MaxNames  = 512;     (* LNAMES entries *)
  MaxSegs   = 64;      (* SEGDEFs seen; only 2 (one CODE, one DATA) may
                          ever be MAPPED, but a real .OBJ may declare more
                          (e.g. a debug/BSS/const segment this converter
                          doesn't use) and those still need an index slot
                          so later records referencing them by index don't
                          misparse *)
  MaxExt    = 1024;    (* EXTDEF/PUBDEF entries *)
  MaxSegLen = Rdoff.SegLimit;  (* per-segment staging buffer: full RDOFF2
                                  segment capacity (65000 bytes), matching
                                  what toc/Link themselves allow *)
  NameLen   = 64;   (* scratch buffer size for reading a <count,char> name
                        off the wire, before it's interned; not a per-entry
                        storage cost (see StrTab adoption note below) *)

  SegNone = 0;  SegTheCode = 1;  SegTheData = 2;   (* which physical slot a SEGDEF maps to *)

TYPE
  NameArr = ARRAY NameLen OF CHAR;

  (* LNAMES and EXTDEF/PUBDEF name tables store a StrTab.TStrTabId (2
     bytes) per entry instead of a full name array -- CLAUDE.md's "StrTab
     adoption pattern" strong rule, and the reason this converter needs
     it at all: 1024 EXTDEF entries x a NameLen-sized array each would
     overflow a single 64K data segment on its own (confirmed by an
     actual "global variable exceeds 64K data segment limit" compile
     error before this change). The interned text itself lives in
     StrTab's own chunked heap storage, not in this module's globals. *)
  NameTab = ARRAY MaxNames OF StrTab.TStrTabId;

  (* One SEGDEF: which physical RDOFF2 segment (if any) it maps to, and
     its declared length (for staging-buffer sizing / BSS-less zero-fill). *)
  SegInfo = RECORD
    mapsTo: INTEGER;    (* SegNone / SegTheCode / SegTheData *)
    length: LONGINT
  END;
  SegTab = ARRAY MaxSegs OF SegInfo;

  (* One EXTDEF/PUBDEF-joint-ordered external name (spec: EXTDEF, COMDEF,
     LEXTDEF share one index space). *)
  ExtInfo = RECORD
    nameId: StrTab.TStrTabId;
    rdfImportId: INTEGER   (* -1 until first referenced by a FIXUP *)
  END;
  ExtTab = ARRAY MaxExt OF ExtInfo;

  (* THREAD subrecord state: 4 FRAME threads + 4 TARGET threads. *)
  ThreadInfo = RECORD
    valid:  BOOLEAN;
    method: INTEGER;   (* 0/1/2 = SEGDEF/GRPDEF/EXTDEF index method *)
    idx:    INTEGER    (* the SEGDEF/GRPDEF/EXTDEF index *)
  END;

VAR
  inF:  Files.File;

  names:   NameTab;  nNames: INTEGER;
  segs:    SegTab;   nSegs:  INTEGER;
  exts:    ExtTab;   nExts:  INTEGER;
  frameThreads, targetThreads: ARRAY 4 OF ThreadInfo;

  codeBuf, dataBuf: Rdoff.SegBuf;   (* far heap blocks, Rdoff.SegLimit bytes each --
                                        NEW'd in RunBody before parsing, same
                                        pattern as Link.ReserveBuffers *)
  codeLen, dataLen: LONGINT;   (* high-water mark actually written *)
  curSeg: INTEGER;             (* SegTheCode/SegTheData/SegNone: segment of the most recent LEDATA/LIDATA *)
  curOfs: LONGINT;             (* start offset of the most recent LEDATA/LIDATA, for FIXUP's Data Record Offset *)

  obj: Rdoff.ObjFile;

PROCEDURE Usage;
BEGIN
  Out.String("Obj2Rdf (c) 2026 DosWorld, Public domain (unlicense)"); Out.Ln;
  Out.Ln;
  Out.String("usage: OBJ2RDF file.obj"); Out.Ln;
  Out.String("  Converts a 16-bit OMF .OBJ file to RDOFF2 .rdf."); Out.Ln
END Usage;

(* ---- record-content byte cursor ----
   Every OMF record's content (excluding type/length/checksum) is read
   into `rec` once, then walked with a cursor -- avoids interleaving file
   I/O with bit-level parsing. *)

VAR
  recBuf: ARRAY MaxRec OF BYTE;
  recLen: INTEGER;   (* bytes of real content (excludes checksum) *)
  cur:    INTEGER;   (* read cursor into recBuf, 0..recLen *)

PROCEDURE AtEnd(): BOOLEAN;
BEGIN RETURN cur >= recLen END AtEnd;

PROCEDURE GetByte(): BYTE;
  VAR b: BYTE;
BEGIN
  IF cur >= recLen THEN LogErr.Error("obj2rdf: record truncated"); RETURN 0 END;
  b := recBuf[cur]; INC(cur); RETURN b
END GetByte;

PROCEDURE GetWord(): INTEGER;
  VAR lo, hi: BYTE;
BEGIN
  lo := GetByte(); hi := GetByte();
  RETURN INTEGER(hi) * 256 + INTEGER(lo)
END GetWord;

(* SkipWord: advance past a 2-byte field whose value is not needed. *)
PROCEDURE SkipWord;
  VAR b: BYTE;
BEGIN
  b := GetByte(); b := GetByte()
END SkipWord;

(* Indexed reference (Names/SEGDEF/GRPDEF/EXTDEF indexes): 1 or 2 bytes,
   high bit of first byte selects width (see spec "Indexed References"). *)
PROCEDURE GetIndex(): INTEGER;
  VAR b1, b2: BYTE;
BEGIN
  b1 := GetByte();
  IF SYSTEM.AND(b1, 080H) # 0 THEN
    b2 := GetByte();
    RETURN INTEGER(SYSTEM.AND(b1, 07FH)) * 256 + INTEGER(b2)
  ELSE
    RETURN INTEGER(b1)
  END
END GetIndex;

(* SkipIndex: advance past an index field whose value is not needed (e.g.
   EXTDEF's per-entry Type Index, PUBDEF's per-entry Type Index) --
   avoids a write-only "discard" local that trips the dead-variable check. *)
PROCEDURE SkipIndex;
  VAR b1: BYTE;
BEGIN
  b1 := GetByte();
  IF SYSTEM.AND(b1, 080H) # 0 THEN b1 := GetByte() END
END SkipIndex;

(* <count,char> name string, as used by THEADR/LNAMES/EXTDEF/PUBDEF/etc. *)
PROCEDURE GetName(VAR s: ARRAY OF CHAR);
  VAR n, i: INTEGER; b: BYTE;
BEGIN
  n := INTEGER(GetByte());
  i := 0;
  WHILE i < n DO
    b := GetByte();
    IF i < LEN(s) - 1 THEN s[i] := CHR(b) END;
    INC(i)
  END;
  IF n < LEN(s) THEN s[n] := 0X ELSE s[LEN(s)-1] := 0X END
END GetName;

(* ---- one raw OMF record: type + content into recBuf/recLen ---- *)

PROCEDURE ReadRecord(VAR rtype: BYTE): BOOLEAN;
  VAR lo, hi: BYTE; total: INTEGER; ok: BOOLEAN; i: INTEGER; b: BYTE;
BEGIN
  ok := Files.ReadByte(inF, rtype);
  IF ~ok THEN RETURN FALSE END;   (* clean EOF *)
  IF ~Files.ReadByte(inF, lo) OR ~Files.ReadByte(inF, hi) THEN
    LogErr.Error("obj2rdf: truncated record header"); RETURN FALSE
  END;
  total := INTEGER(hi) * 256 + INTEGER(lo);   (* includes the 1-byte checksum *)
  IF total > MaxRec + 1 THEN
    LogErr.Error("obj2rdf: record exceeds 1024-byte maximum"); RETURN FALSE
  END;
  recLen := total - 1;   (* exclude checksum *)
  i := 0;
  WHILE i < recLen DO
    IF ~Files.ReadByte(inF, b) THEN
      LogErr.Error("obj2rdf: truncated record body"); RETURN FALSE
    END;
    recBuf[i] := b; INC(i)
  END;
  IF ~Files.ReadByte(inF, b) THEN   (* checksum byte, discarded *)
    LogErr.Error("obj2rdf: truncated record checksum"); RETURN FALSE
  END;
  cur := 0;
  RETURN TRUE
END ReadRecord;

(* ---- LNAMES ---- *)

PROCEDURE HandleLnames;
  VAR nm: NameArr;
BEGIN
  WHILE ~AtEnd() DO
    IF nNames >= MaxNames THEN LogErr.Error("obj2rdf: too many LNAMES entries"); RETURN END;
    GetName(nm);
    names[nNames] := StrTab.Intern(nm);
    INC(nNames)
  END
END HandleLnames;

PROCEDURE NameOf(idx: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
  IF (idx < 1) OR (idx > nNames) THEN s[0] := 0X
  ELSE StrTab.Get(names[idx-1], s)
  END
END NameOf;

(* ---- SEGDEF ----
   Maps a SEGDEF to SegTheCode/SegTheData by segment NAME first ("CODE"/
   "DATA", case-sensitive match against what Turbo Assembler emits),
   falling back to CLASS name if the segment name doesn't match either
   (covers Microsoft-compiler-style .OBJ files, per the SS0288 worked
   examples, where class names ARE "CODE"/"DATA"). *)

PROCEDURE ClassifySeg(segName, className: ARRAY OF CHAR): INTEGER;
BEGIN
  IF Strings.Equal(segName, "CODE") THEN RETURN SegTheCode END;
  IF Strings.Equal(segName, "DATA") THEN RETURN SegTheData END;
  IF Strings.Equal(className, "CODE") THEN RETURN SegTheCode END;
  IF Strings.Equal(className, "DATA") THEN RETURN SegTheData END;
  RETURN SegNone
END ClassifySeg;

PROCEDURE HandleSegdef;
  VAR acbp: BYTE; a, b: INTEGER; segLen: LONGINT;
      segNameIdx, classNameIdx: INTEGER;
      segName, className: NameArr;
      mapsTo: INTEGER; i: INTEGER;
BEGIN
  IF nSegs >= MaxSegs THEN LogErr.Error("obj2rdf: too many SEGDEF records"); RETURN END;
  acbp := GetByte();
  a := INTEGER(SYSTEM.LSR(acbp, 5));            (* Alignment, bits 7-5 *)
  b := INTEGER(SYSTEM.AND(SYSTEM.LSR(acbp, 1), 1)); (* Big bit *)
  IF a = 0 THEN
    LogErr.Error("obj2rdf: absolute (A=0) SEGDEF not supported"); RETURN
  END;
  IF b # 0 THEN
    segLen := 65536
  ELSE
    segLen := LONGINT(GetWord())
  END;
  segNameIdx := GetIndex();
  classNameIdx := GetIndex();
  NameOf(segNameIdx, segName);
  NameOf(classNameIdx, className);
  (* Overlay Name Index field follows but is always ignored (per spec). *)

  (* A SEGDEF that doesn't classify as CODE or DATA is TOLERATED, not
     rejected: real .OBJ files can carry segments this converter has no
     use for (debug info, an unused const/BSS segment, etc.) -- it just
     gets a table slot with mapsTo=SegNone so later records that index it
     resolve cleanly to "unmapped" (PhysOfSegIndex returns -1), rather
     than desyncing the whole SEGDEF index numbering by skipping it. *)
  mapsTo := ClassifySeg(segName, className);
  IF mapsTo # SegNone THEN
    i := 0;
    WHILE i < nSegs DO
      IF segs[i].mapsTo = mapsTo THEN
        LogErr.Error("obj2rdf: more than one CODE or DATA segment (RDOFF2 has only 2 physical segments)");
        RETURN
      END;
      INC(i)
    END;
    IF segLen > LONGINT(MaxSegLen) THEN
      LogErr.Error("obj2rdf: segment exceeds RDOFF2's 65000-byte segment limit"); RETURN
    END
  END;
  segs[nSegs].mapsTo := mapsTo;
  segs[nSegs].length := segLen;
  INC(nSegs)
END HandleSegdef;

(* physSeg (SegTheCode/SegTheData) -> Rdoff.SegCode/SegData, or -1 if the
   SEGDEF index is out of range / unmapped (GRPDEF-only segment etc). *)
PROCEDURE PhysOfSegIndex(segIdx: INTEGER): INTEGER;
BEGIN
  IF (segIdx < 1) OR (segIdx > nSegs) THEN RETURN -1 END;
  IF segs[segIdx-1].mapsTo = SegTheCode THEN RETURN Rdoff.SegCode END;
  IF segs[segIdx-1].mapsTo = SegTheData THEN RETURN Rdoff.SegData END;
  RETURN -1
END PhysOfSegIndex;

(* ---- EXTDEF / LEXTDEF (COMDEF rejected) ----
   Joint index space with COMDEF/LEXTDEF per spec; since COMDEF is
   rejected outright, only EXTDEF/LEXTDEF entries are ever appended, and
   this converter's own index counting stays in lockstep with the file's
   true joint ordering as long as no COMDEF appears. *)

PROCEDURE HandleExtdef;
  VAR nm: NameArr;
BEGIN
  WHILE ~AtEnd() DO
    IF nExts >= MaxExt THEN LogErr.Error("obj2rdf: too many EXTDEF entries"); RETURN END;
    GetName(nm);
    exts[nExts].nameId := StrTab.Intern(nm);
    exts[nExts].rdfImportId := -1;
    INC(nExts);
    SkipIndex   (* Type Index field: index format, value unused *)
  END
END HandleExtdef;

(* Returns the RDOFF2 import id for EXTDEF entry #idx (1-based), creating
   the Rdoff import record on first reference. *)
PROCEDURE ImportIdFor(idx: INTEGER): INTEGER;
  VAR nm: NameArr;
BEGIN
  IF (idx < 1) OR (idx > nExts) THEN
    LogErr.Error("obj2rdf: EXTDEF index out of range"); RETURN -1
  END;
  IF exts[idx-1].rdfImportId < 0 THEN
    StrTab.Get(exts[idx-1].nameId, nm);
    exts[idx-1].rdfImportId := Rdoff.RdfAddImport(obj, nm)
  END;
  RETURN exts[idx-1].rdfImportId
END ImportIdFor;

(* ---- PUBDEF ---- *)

PROCEDURE HandlePubdef;
  VAR segIdx, physSeg: INTEGER;
      nm: NameArr; ofs: LONGINT;
BEGIN
  SkipIndex;   (* Base Group field: always ignored by LINK, per spec *)
  segIdx := GetIndex();
  IF segIdx = 0 THEN
    SkipWord;   (* absolute-frame PUBDEF: not supported as a global *)
    LogErr.Error("obj2rdf: absolute-frame PUBDEF not supported"); RETURN
  END;
  physSeg := PhysOfSegIndex(segIdx);
  IF physSeg < 0 THEN
    LogErr.Error("obj2rdf: PUBDEF references unmapped segment"); RETURN
  END;
  WHILE ~AtEnd() DO
    GetName(nm);
    ofs := LONGINT(GetWord());
    SkipIndex;   (* Type Index, unused *)
    Rdoff.RdfAddGlobal(obj, nm, BYTE(physSeg), ofs)
  END
END HandlePubdef;

(* ---- LEDATA / LIDATA: stage into codeBuf/dataBuf ---- *)

PROCEDURE StageByte(physSeg: INTEGER; ofs: LONGINT; b: BYTE);
BEGIN
  IF physSeg = Rdoff.SegCode THEN
    IF ofs >= LONGINT(MaxSegLen) THEN LogErr.Error("obj2rdf: code offset exceeds 65000-byte segment limit"); RETURN END;
    codeBuf^[WORD(ofs)] := b;
    IF ofs + 1 > codeLen THEN codeLen := ofs + 1 END
  ELSE
    IF ofs >= LONGINT(MaxSegLen) THEN LogErr.Error("obj2rdf: data offset exceeds 65000-byte segment limit"); RETURN END;
    dataBuf^[WORD(ofs)] := b;
    IF ofs + 1 > dataLen THEN dataLen := ofs + 1 END
  END
END StageByte;

PROCEDURE HandleLedata;
  VAR segIdx, physSeg: INTEGER; ofs: LONGINT; b: BYTE;
BEGIN
  segIdx := GetIndex();
  physSeg := PhysOfSegIndex(segIdx);
  ofs := LONGINT(GetWord());
  curSeg := physSeg; curOfs := ofs;
  IF physSeg < 0 THEN
    LogErr.Error("obj2rdf: LEDATA references unmapped segment"); RETURN
  END;
  WHILE ~AtEnd() DO
    b := GetByte();
    StageByte(physSeg, ofs, b);
    INC(ofs)
  END
END HandleLedata;

(* LIDATA: only the simple (Block Count = 0) repeated-byte-block form. *)
PROCEDURE HandleLidata;
  VAR segIdx, physSeg: INTEGER; ofs: LONGINT;
      repeatCount: LONGINT; blockCount: INTEGER;
      contentLen, i: INTEGER; b: BYTE; r: LONGINT;
BEGIN
  segIdx := GetIndex();
  physSeg := PhysOfSegIndex(segIdx);
  ofs := LONGINT(GetWord());
  curSeg := physSeg; curOfs := ofs;
  IF physSeg < 0 THEN
    LogErr.Error("obj2rdf: LIDATA references unmapped segment"); RETURN
  END;
  WHILE ~AtEnd() DO
    repeatCount := LONGINT(GetWord());
    blockCount := GetWord();
    IF blockCount # 0 THEN
      LogErr.Error("obj2rdf: nested LIDATA blocks not supported"); RETURN
    END;
    contentLen := INTEGER(GetByte());
    r := 0;
    WHILE r < repeatCount DO
      i := 0;
      WHILE i < contentLen DO
        b := recBuf[cur + i];
        StageByte(physSeg, ofs, b);
        INC(ofs); INC(i)
      END;
      INC(r)
    END;
    cur := cur + contentLen
  END
END HandleLidata;

(* ---- FIXUPP ----
   THREAD subrecords update frameThreads[]/targetThreads[].  FIXUP
   subrecords resolve FRAME/TARGET (explicit or via thread), reject
   anything RDOFF2 cannot express, and emit RdfAddReloc / RdfAddSegReloc
   against the LEDATA/LIDATA offset (curOfs + Data Record Offset). *)

PROCEDURE HandleThread(b0: BYTE);
  VAR d: INTEGER; method: INTEGER; thred: INTEGER; idx: INTEGER;
BEGIN
  d := INTEGER(SYSTEM.AND(SYSTEM.LSR(b0, 6), 1));
  method := INTEGER(SYSTEM.AND(SYSTEM.LSR(b0, 3), 7));
  thred := INTEGER(SYSTEM.AND(b0, 3));
  idx := 0;
  IF (method = 0) OR (method = 1) OR (method = 2) THEN idx := GetIndex() END;
  IF d = 1 THEN
    frameThreads[thred].valid := TRUE;
    frameThreads[thred].method := method;
    frameThreads[thred].idx := idx
  ELSE
    targetThreads[thred].valid := TRUE;
    targetThreads[thred].method := method;
    targetThreads[thred].idx := idx
  END
END HandleThread;

(* Resolve a FIXUP's TARGET to an RDOFF2 rseg id (0=code,1=data,>=? import).
   targMethod (explicit, T=0 case): per spec, "the P bit and the Targt
   field can be considered a 3-bit field analogous to the Frame field" --
   i.e. targMethod = (P<<2)|Targt, giving T0=SEGDEF, T1=GRPDEF, T2=EXTDEF
   (Target Displacement field present), or T4=SEGDEF, T5=GRPDEF, T6=EXTDEF
   (no Target Displacement field -- the P=1 case, which is what real
   single-module .OBJ files actually emit almost exclusively, since the
   displacement is usually 0 and already baked into the LEDATA bytes).
   T3/T7 (explicit frame number) are rejected the same as frame method 3.
   THREAD-subrecord targMethod (T=1 case) reuses this same 0/1/2 space
   directly (THREAD's own Method field only has 3 values, T0/T1/T2 by a
   different name), so both paths funnel through the same idx%4 check. *)
PROCEDURE ResolveTarget(targMethod, targDatum: INTEGER; VAR rseg: INTEGER): BOOLEAN;
  VAR kind: INTEGER;
BEGIN
  kind := targMethod MOD 4;   (* 0=SEGDEF, 1=GRPDEF, 2=EXTDEF, 3=frame number *)
  IF kind = 0 THEN
    rseg := PhysOfSegIndex(targDatum);
    IF rseg < 0 THEN LogErr.Error("obj2rdf: FIXUP target SEGDEF unmapped"); RETURN FALSE END;
    RETURN TRUE
  ELSIF kind = 2 THEN
    rseg := ImportIdFor(targDatum);
    RETURN rseg >= 0
  ELSE
    LogErr.Error("obj2rdf: FIXUP target GRPDEF/frame-number method not supported");
    RETURN FALSE
  END
END ResolveTarget;

(* FRAME tells the linker which segment register the TRANSLATOR assumed
   would be live at runtime for this reference -- it does NOT change what
   bytes get patched.  RDOFF2's RELOC/SEGRELOC records only ever encode
   "patch this offset" (Location=1) or "patch this segment base"
   (Location=2); neither has any place to store a frame at all, and for
   both, whatever frame the translator assumed is exactly the caller's
   responsibility at runtime (a plain offset word means nothing without
   the reader already having the right segment register loaded, same as
   any RDOFF2-native reloc). So for the two LOCATION types this converter
   supports, FRAME is accepted unconditionally EXCEPT method 3 (explicit
   frame number -- never supported by LINK either, per spec, and not
   resolvable to any RDOFF2 segment/import at all).
   For any other LOCATION type (rejected earlier in HandleFixup before
   this is even called), a real frame/target split would matter and this
   converter does not implement it. *)
PROCEDURE ValidateFrame(f: INTEGER; frameMethod: INTEGER): BOOLEAN;
BEGIN
  IF f = 1 THEN RETURN TRUE END;   (* frame given by a FRAME thread: the thread's
                                       own method was already resolved when defined;
                                       nothing further to check here *)
  IF frameMethod = 3 THEN
    LogErr.Error("obj2rdf: FIXUP frame method 3 (explicit frame number) not supported");
    RETURN FALSE
  END;
  RETURN TRUE
END ValidateFrame;

PROCEDURE HandleFixup(b0: BYTE);
  VAR locHi: BYTE; m, location, dro: INTEGER;
      fixdata: BYTE; f, frame, t, p, targt: INTEGER;
      frameMethod, frameDatum, targMethod, targDatum: INTEGER;
      targetDisp: INTEGER;
      siteOfs: LONGINT; rseg: INTEGER; width: INTEGER; relative: BOOLEAN;
BEGIN
  locHi := GetByte();
  m := INTEGER(SYSTEM.AND(SYSTEM.LSR(b0, 6), 1));
  location := INTEGER(SYSTEM.AND(SYSTEM.LSR(b0, 2), 0FH));
  dro := INTEGER(SYSTEM.AND(b0, 3)) * 256 + INTEGER(locHi);

  fixdata := GetByte();
  f := INTEGER(SYSTEM.AND(SYSTEM.LSR(fixdata, 7), 1));
  frame := INTEGER(SYSTEM.AND(SYSTEM.LSR(fixdata, 4), 7));
  t := INTEGER(SYSTEM.AND(SYSTEM.LSR(fixdata, 3), 1));
  p := INTEGER(SYSTEM.AND(SYSTEM.LSR(fixdata, 2), 1));
  targt := INTEGER(SYSTEM.AND(fixdata, 3));

  frameMethod := 0; frameDatum := 0;
  IF f = 0 THEN
    frameMethod := frame;
    IF (frameMethod = 0) OR (frameMethod = 1) OR (frameMethod = 2) THEN
      frameDatum := GetIndex()
    END
  ELSE
    IF ~frameThreads[frame MOD 4].valid THEN
      LogErr.Error("obj2rdf: FIXUP references undefined FRAME thread"); RETURN
    END;
    frameMethod := frameThreads[frame MOD 4].method;
    frameDatum := frameThreads[frame MOD 4].idx
  END;

  targMethod := 0; targDatum := 0;
  IF t = 0 THEN
    (* explicit TARGET: method = (P bit)*4 + Targt, per spec (P combines
       with Targt to form the 3-bit method when T=0) *)
    targMethod := p * 4 + targt;
    targDatum := GetIndex()
  ELSE
    IF ~targetThreads[targt].valid THEN
      LogErr.Error("obj2rdf: FIXUP references undefined TARGET thread"); RETURN
    END;
    targMethod := targetThreads[targt].method;
    targDatum := targetThreads[targt].idx;
    (* P bit still governs whether a Target Displacement follows *)
  END;

  targetDisp := 0;
  IF p = 0 THEN targetDisp := GetWord() END;
  (* targetDisp is not applied here: for the supported cases (Location=1/2,
     addend already resident in the LEDATA bytes at the patch site), the
     linker-facing addend is whatever is already staged in codeBuf/dataBuf;
     a nonzero explicit Target Displacement on top of that would require
     adding it into the staged bytes, which none of the fixups in the
     files this converter was built against ever exercise (all seen so
     far have P=1, "no Target Displacement field"). Flag it rather than
     silently drop it. *)
  IF (p = 0) & (targetDisp # 0) THEN
    LogErr.Error("obj2rdf: FIXUP with explicit nonzero Target Displacement not supported");
    RETURN
  END;

  IF (location # 1) & (location # 2) THEN
    LogErr.Error("obj2rdf: FIXUP LOCATION type not supported (only 16-bit offset/base)");
    RETURN
  END;
  IF curSeg < 0 THEN
    LogErr.Error("obj2rdf: FIXUP with no preceding LEDATA/LIDATA in a mapped segment");
    RETURN
  END;
  IF ~ValidateFrame(f, frameMethod) THEN RETURN END;

  IF ~ResolveTarget(targMethod, targDatum, rseg) THEN RETURN END;

  siteOfs := curOfs + LONGINT(dro);
  relative := (m = 0);   (* M=0: self-relative; M=1: segment-relative (absolute site) *)

  IF location = 1 THEN
    width := 2;
    Rdoff.RdfAddReloc(obj, curSeg, siteOfs, width, rseg, relative)
  ELSE   (* location = 2: 16-bit segment base *)
    IF relative THEN
      LogErr.Error("obj2rdf: self-relative segment-base FIXUP not supported"); RETURN
    END;
    Rdoff.RdfAddSegReloc(obj, curSeg, siteOfs, rseg)
  END
END HandleFixup;

PROCEDURE HandleFixupp;
  VAR b0: BYTE;
BEGIN
  WHILE ~AtEnd() DO
    b0 := GetByte();
    IF SYSTEM.AND(b0, 080H) = 0 THEN HandleThread(b0)
    ELSE HandleFixup(b0)
    END
  END
END HandleFixupp;

(* ---- top-level record dispatch ---- *)

PROCEDURE ConvertFile(): BOOLEAN;
  VAR rtype: BYTE; more: BOOLEAN; sawModend: BOOLEAN;
BEGIN
  nNames := 0; nSegs := 0; nExts := 0;
  codeLen := 0; dataLen := 0;
  curSeg := -1; curOfs := 0;
  sawModend := FALSE;
  more := ReadRecord(rtype);
  WHILE more & ~LogErr.HaveErr() & ~sawModend DO
    CASE rtype OF
      RtTHEADR, RtLHEADR, RtCOMENT: (* ignored *)
    | RtLNAMES:   HandleLnames
    | RtSEGDEF1:  HandleSegdef
    | RtSEGDEF2:  LogErr.Error("obj2rdf: 32-bit SEGDEF (99H) not supported")
    | RtGRPDEF:   LogErr.Error("obj2rdf: GRPDEF (segment grouping) not supported")
    | RtEXTDEF:   HandleExtdef
    | RtLEXTDEF:  HandleExtdef
    | RtPUBDEF1:  HandlePubdef
    | RtPUBDEF2:  LogErr.Error("obj2rdf: 32-bit PUBDEF (91H) not supported")
    | RtCOMDEF, RtLCOMDEF: LogErr.Error("obj2rdf: COMDEF/LCOMDEF (communal vars) not supported")
    | RtLEDATA1:  HandleLedata
    | RtLEDATA2:  LogErr.Error("obj2rdf: 32-bit LEDATA (A1H) not supported")
    | RtLIDATA1:  HandleLidata
    | RtLIDATA2:  LogErr.Error("obj2rdf: 32-bit LIDATA (A3H) not supported")
    | RtFIXUPP1:  HandleFixupp
    | RtFIXUPP2:  LogErr.Error("obj2rdf: 32-bit FIXUPP (9DH) not supported")
    | RtMODEND1, RtMODEND2: sawModend := TRUE
    ELSE
      (* unrecognised/unimplemented record type: ignore, matching how real
         linkers skip record types they don't understand *)
    END;
    IF ~sawModend & ~LogErr.HaveErr() THEN more := ReadRecord(rtype) END
  END;
  RETURN ~LogErr.HaveErr()
END ConvertFile;

(* Byte-by-byte via Rdoff.EmitByte rather than EmitBlock: EmitBlock's `VAR
   buf` parameter expects an addressable variable to take the address of,
   which a SegBuf (already SYSTEM.ADDRESS, dereferenced via ^[i]) is not —
   this avoids that type mismatch.  Not a hot path (max 65000 bytes, once
   per segment, once per conversion). *)
PROCEDURE EmitSegments;
  VAR i: WORD;
BEGIN
  i := 0;
  WHILE LONGINT(i) < codeLen DO Rdoff.EmitByte(obj, Rdoff.SegCode, BYTE(codeBuf^[i])); INC(i) END;
  i := 0;
  WHILE LONGINT(i) < dataLen DO Rdoff.EmitByte(obj, Rdoff.SegData, BYTE(dataBuf^[i])); INC(i) END
END EmitSegments;

PROCEDURE RunBody(): INTEGER;
  VAR inPath, outPath: ARRAY 128 OF CHAR;
BEGIN
  IF Dos.ParamCount() < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, inPath);
  IF ~Files.FileExists(inPath) THEN
    LogErr.Error2("obj2rdf: no such file: ", inPath); RETURN ExitIo
  END;
  IF ~Files.Reset(inF, inPath) THEN
    LogErr.Error2("obj2rdf: cannot open ", inPath); RETURN ExitIo
  END;

  NEW(codeBuf, MaxSegLen);
  NEW(dataBuf, MaxSegLen);
  IF (codeBuf = NIL) OR (dataBuf = NIL) THEN
    Files.Close(inF); LogErr.Error("obj2rdf: out of memory (staging buffers)"); RETURN ExitIo
  END;

  NEW(obj);
  IF obj = NIL THEN
    Files.Close(inF); DISPOSE(codeBuf); DISPOSE(dataBuf);
    LogErr.Error("obj2rdf: out of memory"); RETURN ExitIo
  END;
  Rdoff.RdfInit(obj);

  IF ~ConvertFile() THEN
    Files.Close(inF); Rdoff.RdfFree(obj); DISPOSE(obj);
    DISPOSE(codeBuf); DISPOSE(dataBuf); RETURN ExitFormat
  END;
  Files.Close(inF);

  EmitSegments;
  DISPOSE(codeBuf); DISPOSE(dataBuf);
  IF LogErr.HaveErr() THEN Rdoff.RdfFree(obj); DISPOSE(obj); RETURN ExitFormat END;

  Files.ReplaceExt(inPath, ".RDF", outPath);
  Rdoff.RdfWrite(obj, outPath);
  Rdoff.RdfFree(obj); DISPOSE(obj);
  IF LogErr.HaveErr() THEN RETURN ExitIo END;

  Out.String("obj2rdf: wrote "); Out.String(outPath); Out.Ln;
  RETURN ExitOk
END RunBody;

PROCEDURE Run*;
  VAR r: INTEGER;
BEGIN
  LogErr.Open;
  r := RunBody();
  LogErr.Close;
  SYSTEM.Halt(r)   (* the ONE and ONLY SYSTEM.Halt in obj2rdf *)
END Run;

BEGIN
  nNames := 0; nSegs := 0; nExts := 0
END Obj2Rdf.
