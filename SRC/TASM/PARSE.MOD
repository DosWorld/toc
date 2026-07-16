MODULE Parse;
(*
  TASM top-level driver: one source line at a time, dispatch to Dir (if a
  directive) or Enc (if an instruction), handle label definitions, drive
  the two-pass forward-reference fixup.

  %define expansion happens inline at the token level via TokNext (below):
  whenever the raw scanner would yield an identifier that Sym recognizes as
  a %define macro, TokNext instead re-lexes the macro's substitution text
  from a small pushback buffer and returns tokens from there until it is
  exhausted, then resumes pulling from the real file scanner.  This mirrors
  NASM's own text-substitution semantics for the whole-token-only subset
  this assembler supports (no parameterized macros -- see DOCS/IMPLRULE.MD's
  TASM section).

  %ifdef/%else/%endif are handled at the raw-line level (SkipToEndifOrElse)
  before any %define expansion of that line's tokens (skip branches
  wholesale).

  Two passes: Pass 1 walks the whole source, encoding every instruction
  through Enc (Enc counts bytes but does not write them in pass 1 -- see
  ENC.MOD's pass-gated B/W helpers) so every label's final code/data offset
  is known by the time Pass 1 finishes.  Pass 2 re-walks, encoding again
  (now with Enc actually writing bytes + relocations via Rdoff).  Running
  this same single code path twice (not two hand-synced copies) is what
  guarantees Pass 1's byte count and Pass 2's real emission can never drift
  apart.
*)
IMPORT Files, Strings, LogErr, Rdoff, Sym, Dir, Enc, Scan, Lex;

CONST
  MaxSrcDepth = 8;    (* §I.3: input-source stack depth -- top-level file
                          (always stk[0]) plus up to 7 nested %include/
                          %macro/%define levels (§S2: %define substitutions
                          share this same stack/bound now, retiring the
                          separate MacroDepth=4 pushback-buffer budget --
                          one recursion-depth authority instead of two). A
                          DOS-target assembler's nesting is not expected to
                          run deep (Simplicity First), and each stack slot
                          holds a full Scan.Scanner + Files.File (well over
                          500 bytes each -- see the module-VAR placement
                          note below), so the bound stays modest rather
                          than generous. *)

  (* E7 fix: named markers for BaseIndexOf/CombineBaseIndex/SingleRegAm --
     one code per 8086 base/index register legal inside [ ... ], distinct
     from Enc's own register-number space (hence the offset, not just
     Enc.RBX etc. directly) so BaseIndexOf's -1 "not a base/index reg"
     sentinel can't collide with a real register code. *)
  MkBx = 100; MkBp = 101; MkSi = 102; MkDi = 103;

TYPE
  (* PredefNode: one -Dname[=value] CLI predefine (§I.2). A plain linked
     list, not a chunked Chunk=32 table like Sym's -- a DOS command line
     holds only a handful of -D switches, so the chunk machinery's extra
     complexity buys nothing here. *)
  PredefNode = POINTER TO PredefNodeDesc;
  PredefNodeDesc = RECORD
    name:  ARRAY Sym.MaxName OF CHAR;
    value: ARRAY 128 OF CHAR;
    next:  PredefNode
  END;

  (* SrcSlot / SrcStack: §I.3's input-source stack -- replaces the single
     module-global Scan.Scanner. stk[0] is always the top-level .asm file
     (opened by RunPass); %include pushes stk[1..] for nested files.
     isFile distinguishes a real Files.File entry (closed on pop) from a
     memory-source entry (§I.4's %macro expansions AND §S2's %define
     substitutions both reuse this same stack with isFile=FALSE, nothing
     to close, just DISPOSE(scn.mem) -- see the N1 fix). isDefine further
     distinguishes a %define substitution from a %macro expansion/
     %include file: a %define substitution running dry must pop
     transparently and keep reading the SAME logical line from the
     parent slot (no synthesized TEol -- see RawTokNext's EOF handling),
     whereas a %macro expansion or %include running dry ends its own
     line and must synthesize exactly one TEol before falling back to
     the parent. Each Scanner+File pair is 500+ bytes, so the array is a
     module VAR, never a local -- the 2026-07-11 stack-frame STRONG RULE
     (DOCS/IMPLRULE.MD) applies directly here. *)
  SrcSlot = RECORD
    scn:      Scan.Scanner;
    f:        Files.File;
    isFile:   BOOLEAN;
    isDefine: BOOLEAN
  END;
  SrcStack = ARRAY MaxSrcDepth OF SrcSlot;

VAR
  stk:       SrcStack;
  srcTop:    INTEGER;    (* index of the active slot; -1 = nothing open yet *)
  obj:       Rdoff.ObjFile;

  (* current token, after macro expansion -- callers read these instead of
     touching s.* directly once tokenizing has started *)
  tSym:      INTEGER;
  tId:       ARRAY Scan.MaxIdent OF CHAR;
  tIdOrig:   ARRAY Scan.MaxIdent OF CHAR;
  tIval:     LONGINT;
  tSval:     ARRAY Scan.MaxStr OF CHAR;
  tLine:     LONGINT;
  tokCount:  LONGINT;   (* incremented on every RawTokNext -- RunPass's
                            no-progress guard (BUG A2) compares this before/
                            after ParseLine: unchanged means ParseLine
                            returned without consuming a token, which would
                            otherwise spin RunPass's main loop forever *)

  curPass:   INTEGER;
  curSeg:    INTEGER;             (* Sym.SegCode / Sym.SegData / Sym.SegBss -- current SECTION *)
  codeOfs:   LONGINT;             (* running code offset, both passes (Pass 2 mirrors Rdoff.CodeLen) *)
  dataOfs:   LONGINT;
  bssOfs:    LONGINT;             (* running BSS offset -- RESB/RESW/RESD reserve space here without
                                      emitting any bytes; total becomes Rdoff.RdfSetBss's argument. *)
  anyErr:    BOOLEAN;

  predefHead: PredefNode;   (* §I.2: -D command-line predefines, applied in Assemble *)

  (* §I.4 %macro state. macroBodyBuf is the fixed staging buffer for
     %macro...%endmacro raw-text capture -- a module VAR, not a stack
     local (4096 bytes is well past the 2 KB stack-frame STRONG RULE
     ceiling, see DOCS/IMPLRULE.MD). macroLocalCounter numbers each
     %%ident -> ?Mk?ident substitution; RunPass resets it at the start
     of EACH pass so both passes generate the identical sequence of
     synthesized local-label names for the same source (§I.0's two-pass
     replay rule) -- it does NOT reset per file/include, only per pass,
     matching how label offsets themselves are pass-global. *)
  macroBodyBuf: ARRAY 4096 OF CHAR;
  macroLocalCounter: LONGINT;

(* AddPredef: TASM.MOD's RunBody calls this once per -D/-Dname=value CLI
   argument, before Assemble runs. name is already uppercased and
   validated non-empty by the caller (matches %define's own uppercase-
   keying convention, see TASM.MD §I.0); an absent "=value" in the
   original switch means an empty value (a bare %ifdef flag, exactly
   NASM's `-Dname`). *)
PROCEDURE AddPredef*(name, value: ARRAY OF CHAR);
  VAR node: PredefNode;
BEGIN
  NEW(node);
  IF node = NIL THEN LogErr.Error("tasm: out of memory (predef)"); RETURN END;
  Strings.Copy(name, node^.name);
  Strings.Copy(value, node^.value);
  node^.next := predefHead;
  predefHead := node
END AddPredef;

(* FreePredefs: release the -D list. Called on every RunBody exit path
   (TASM.MOD) alongside Assemble's own Sym.Free/Enc.FreeJmpDecisions
   cleanup -- the predef list is TASM.MOD's own allocation, outside
   Assemble's normal per-call cleanup, so it needs its own free call. *)
PROCEDURE FreePredefs*;
  VAR n, nn: PredefNode;
BEGIN
  n := predefHead;
  WHILE n # NIL DO nn := n^.next; DISPOSE(n); n := nn END;
  predefHead := NIL
END FreePredefs;

(* ApplyPredefs: record every -D name/value into Sym via Sym.Define,
   exactly as if `%define name value` had appeared before line 1 of the
   source -- called once per Assemble, right after Sym.Init. Because
   Sym's define table is untouched by RunPass (not reset between passes,
   see RunPass's own header comment), this needs no per-pass replay
   machinery: applied once, it stays defined through both passes with
   no cross-pass caching risk (§I.0's ground rule). A source-level
   %undef NAME still works normally afterward. *)
PROCEDURE ApplyPredefs;
  VAR n: PredefNode;
BEGIN
  n := predefHead;
  WHILE n # NIL DO
    Sym.Define(n^.name, n^.value);
    n := n^.next
  END
END ApplyPredefs;

(* CurFname: the ACTIVE source's filename for diagnostics (§I.3 -- was a
   single module-global `fname`, wrong once %include can push a second
   file: an error inside an included file must report the include's own
   name, not the top-level .asm's). Every Scan.Scanner already carries
   its own fname, so this just copies the active stack slot's. *)
PROCEDURE CurFname(VAR out: ARRAY OF CHAR);
BEGIN Strings.Copy(stk[srcTop].scn.fname, out)
END CurFname;

PROCEDURE Fail(msg: ARRAY OF CHAR);
  VAR fn: ARRAY 128 OF CHAR;
BEGIN CurFname(fn); LogErr.ErrorInFile(fn, tLine, msg); anyErr := TRUE
END Fail;

(* DefineCurLabel: define a label at the current position in whichever
   segment (curSeg) is active -- SegCode/codeOfs, SegData/dataOfs, or
   SegBss/bssOfs.  Factors out the SegCode/SegData/SegBss three-way
   dispatch that both label-definition sites in ParseLine need. *)
PROCEDURE DefineCurLabel(nameOrig: ARRAY OF CHAR);
  VAR fn: ARRAY 128 OF CHAR;
BEGIN
  CurFname(fn);
  IF curSeg = Sym.SegCode THEN
    Sym.DefineLabel(nameOrig, Sym.SegCode, codeOfs, FALSE, fn, tLine)
  ELSIF curSeg = Sym.SegData THEN
    Sym.DefineLabel(nameOrig, Sym.SegData, dataOfs, FALSE, fn, tLine)
  ELSE
    Sym.DefineLabel(nameOrig, Sym.SegBss, bssOfs, FALSE, fn, tLine)
  END
END DefineCurLabel;

(* ---- token stream with %define expansion ---- *)

(* RawTokNext: fetch the next token with NO %define expansion, from
   whichever slot is on top of the §I.3 input-source stack -- a real file,
   a %macro expansion, or (§S2) a %define substitution, all lexed by the
   ONE real Scan.Next now (McNextTok's ad-hoc re-lexer is retired: it used
   to diverge from Scan.Next on strings/parens/'*'/'/' and every other
   token this module has ever added, smell C8/S2). Used raw (no expansion)
   for the identifier immediately following %define/%undef/%ifdef: that
   name is being declared or tested, not used as a value, so it must never
   itself be macro-expanded -- e.g. "%define IS_FAR" (empty-bodied, used
   purely as an %ifdef flag in SYSTEM.ASM/EMS.ASM) followed later by
   "%ifdef IS_FAR" would otherwise have TokNext silently expand IS_FAR to
   its (empty) substitution before DoIfdef ever saw an identifier token,
   desyncing the whole token stream. *)
PROCEDURE RawTokNext;
BEGIN
  INC(tokCount);
  Scan.Next(stk[srcTop].scn);
  tSym := stk[srcTop].scn.sym; tLine := stk[srcTop].scn.tokLine; tIval := stk[srcTop].scn.ival;
  Strings.Copy(stk[srcTop].scn.id, tId);
  Strings.Copy(stk[srcTop].scn.idOrig, tIdOrig);
  Strings.Copy(stk[srcTop].scn.sval, tSval);
  IF (tSym = Scan.TEof) & (srcTop > 0) THEN
    IF stk[srcTop].isDefine THEN
      (* §S2: a %define substitution running dry must pop TRANSPARENTLY
         and keep reading the SAME logical line from the parent slot --
         unlike a %macro expansion or %include file (below), it must NOT
         synthesize a TEol, since the substitution sits mid-statement
         (e.g. "mov ax, RSIZE+2" with RSIZE="4" must continue reading
         "+2" from the real source right after "4", not see an end of
         line first). DISPOSE + DEC, then re-read from the (now) top
         slot -- recursion depth is bounded by MaxSrcDepth, same as
         %include/%macro's own guards. *)
      DISPOSE(stk[srcTop].scn.mem);
      DEC(srcTop);
      RawTokNext; RETURN
    END;
    (* §I.3: on inner-file/%macro EOF (srcTop > 0), pop back to the
       parent source and synthesize ONE TEol first -- an included file
       not ending in a newline (or a %macro expansion, which is never
       newline-terminated) must not glue its last token onto the
       parent's next line -- then continue reading from the parent so
       the outer loop (RunPass) never observes an inner TEof at all;
       only the true top-level EOF (stack empty down to stk[0]) ever
       surfaces as TEof to callers. *)
    IF stk[srcTop].isFile THEN Files.Close(stk[srcTop].f)
    ELSE DISPOSE(stk[srcTop].scn.mem) END;   (* N1 fix: %macro expansion buffer *)
    DEC(srcTop);
    tSym := Scan.TEol
  END
END RawTokNext;

(* TokNext: the token source every parser procedure below calls.  Expands
   %define macros transparently: if the raw next token is an identifier
   matching a Sym macro, push its substitution text as a new memory-source
   slot (§S2: Scan.InitMem, the same real tokenizer %macro expansions
   already use) and pull the first token from there instead (recursively --
   a macro body naming another macro is re-checked once the pushed slot
   starts yielding, since RawTokNext's tokens go through the same
   Sym.Expand check below regardless of which slot they came from). *)
PROCEDURE TokNext;
  VAR sub: ARRAY 128 OF CHAR; expansion: Scan.MemText; fn: ARRAY 128 OF CHAR;
BEGIN
  RawTokNext;
  IF (tSym = Scan.TIdent) & Sym.Expand(tId, sub) THEN
    IF srcTop = MaxSrcDepth - 1 THEN Fail("macro expansion nested too deep"); RETURN END;
    NEW(expansion);
    IF expansion = NIL THEN Fail("out of memory (define expansion)"); RETURN END;
    SYSTEM.MOVE(sub[0], expansion^.buf[0], Strings.Length(sub));
    expansion^.buf[Strings.Length(sub)] := 0X;
    (* CurFname BEFORE the push: it must capture the INVOCATION SITE's
       filename for the expansion's diagnostics -- after INC(srcTop) it
       would read the new slot's stale/blank fname instead, making every
       error inside an expansion report an empty filename (found by the
       2026-07-16 review probe; InvokeMacro had the same ordering bug). *)
    CurFname(fn);
    INC(srcTop);
    stk[srcTop].isFile := FALSE; stk[srcTop].isDefine := TRUE;
    Scan.InitMem(stk[srcTop].scn, expansion, fn, tLine);
    TokNext; RETURN     (* re-enter: pull the macro's first real token *)
  END
END TokNext;

(* ---- register name lookup ----
   Returns TRUE + size (SzByte/SzWord) + reg code if `name` (already
   uppercased) names a register; segment registers set isSeg TRUE and reg
   is one of Enc.SegES/CS/SS/DS. *)
(* LookupReg: delegates the name->id lookup to Lex.LookupReg (the shared
   lexeme dictionary), then maps Lex's Reg* id space onto Enc's own
   register-number space (0..7 word/byte registers, 0..3 segment
   registers) and word/byte size. *)
PROCEDURE LookupReg(name: ARRAY OF CHAR; VAR size, reg: INTEGER; VAR isSeg: BOOLEAN): BOOLEAN;
  VAR r: INTEGER;
BEGIN
  isSeg := FALSE;
  r := Lex.LookupReg(name);
  CASE r OF
    Lex.RegAX: size := Enc.SzWord; reg := Enc.RAX
  | Lex.RegCX: size := Enc.SzWord; reg := Enc.RCX
  | Lex.RegDX: size := Enc.SzWord; reg := Enc.RDX
  | Lex.RegBX: size := Enc.SzWord; reg := Enc.RBX
  | Lex.RegSP: size := Enc.SzWord; reg := Enc.RSP
  | Lex.RegBP: size := Enc.SzWord; reg := Enc.RBP
  | Lex.RegSI: size := Enc.SzWord; reg := Enc.RSI
  | Lex.RegDI: size := Enc.SzWord; reg := Enc.RDI
  | Lex.RegAL: size := Enc.SzByte; reg := Enc.RAL
  | Lex.RegCL: size := Enc.SzByte; reg := Enc.RCL
  | Lex.RegDL: size := Enc.SzByte; reg := Enc.RDL
  | Lex.RegBL: size := Enc.SzByte; reg := Enc.RBL
  | Lex.RegAH: size := Enc.SzByte; reg := Enc.RAH
  | Lex.RegCH: size := Enc.SzByte; reg := Enc.RCH
  | Lex.RegDH: size := Enc.SzByte; reg := Enc.RDH
  | Lex.RegBH: size := Enc.SzByte; reg := Enc.RBH
  | Lex.RegES: isSeg := TRUE; reg := Enc.SegES; size := Enc.SzWord
  | Lex.RegCS: isSeg := TRUE; reg := Enc.SegCS; size := Enc.SzWord
  | Lex.RegSS: isSeg := TRUE; reg := Enc.SegSS; size := Enc.SzWord
  | Lex.RegDS: isSeg := TRUE; reg := Enc.SegDS; size := Enc.SzWord
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END LookupReg;

(* IsSegRegPrefixNext / SegRegPrefixByteFor: D fix -- support NASM's
   "es stosb"-style bare segment-register prefix before a string op
   (STOSB/MOVSB/... take no memory operand of their own to carry a
   `[es:...]` override, so this leading-token form is the only way to
   apply one). `name` is already-uppercased (matches LookupReg's
   contract); only recognizes ES/CS/SS/DS, same set LookupReg accepts. *)
PROCEDURE IsSegRegPrefixNext(name: ARRAY OF CHAR): BOOLEAN;
  VAR size, reg: INTEGER; isSeg: BOOLEAN;
BEGIN
  RETURN LookupReg(name, size, reg, isSeg) & isSeg
END IsSegRegPrefixNext;

PROCEDURE SegRegPrefixByteFor(name: ARRAY OF CHAR): INTEGER;
  VAR size, reg: INTEGER; isSeg: BOOLEAN;
BEGIN
  IF LookupReg(name, size, reg, isSeg) & isSeg THEN
    RETURN INTEGER(Enc.SegPrefixByte(reg))
  END;
  RETURN 0
END SegRegPrefixByteFor;

(* IsBaseIndexReg: TRUE if reg (a word register code) may appear inside
   [ ... ] as a base/index register (BX, BP, SI, DI only -- 8086 addressing
   has no other valid base/index registers). *)
PROCEDURE BaseIndexOf(reg: INTEGER): INTEGER;
BEGIN
  CASE reg OF
    Enc.RBX: RETURN MkBx
  | Enc.RBP: RETURN MkBp
  | Enc.RSI: RETURN MkSi
  | Enc.RDI: RETURN MkDi
  ELSE RETURN -1
  END
END BaseIndexOf;

(* CombineBaseIndex: given two base/index component codes (each one of the
   Mk* markers from BaseIndexOf, order-independent), pick the 8086 Am*
   addressing-mode selector.  Only [BX+SI] [BX+DI] [BP+SI] [BP+DI] are
   legal two-register forms; anything else is a caller error. *)
PROCEDURE CombineBaseIndex(a, b: INTEGER; VAR am: INTEGER): BOOLEAN;
BEGIN
  IF ((a = MkBx) & (b = MkSi)) OR ((a = MkSi) & (b = MkBx)) THEN am := Enc.AmBxSi; RETURN TRUE END;
  IF ((a = MkBx) & (b = MkDi)) OR ((a = MkDi) & (b = MkBx)) THEN am := Enc.AmBxDi; RETURN TRUE END;
  IF ((a = MkBp) & (b = MkSi)) OR ((a = MkSi) & (b = MkBp)) THEN am := Enc.AmBpSi; RETURN TRUE END;
  IF ((a = MkBp) & (b = MkDi)) OR ((a = MkDi) & (b = MkBp)) THEN am := Enc.AmBpDi; RETURN TRUE END;
  RETURN FALSE
END CombineBaseIndex;

PROCEDURE SingleRegAm(marker: INTEGER; VAR am: INTEGER): BOOLEAN;
BEGIN
  CASE marker OF
    MkBx: am := Enc.AmBx; RETURN TRUE
  | MkBp: am := Enc.AmDisp; RETURN TRUE   (* [BP] alone: Am selector reuses 6, mod forced to 01 by EmitModRm's disp=0 rule *)
  | MkSi: am := Enc.AmSi; RETURN TRUE
  | MkDi: am := Enc.AmDi; RETURN TRUE
  ELSE RETURN FALSE
  END
END SingleRegAm;

(* ---- operand parsing ----
   ParseMemBody parses the contents of [ ... ] (after the '[' has been
   consumed by the caller, up to but not including ']'), filling `op` as
   an OKMem operand.  Grammar actually needed: reg | reg+reg | reg+disp |
   reg+reg+disp | disp | label | label+disp -- disp may itself be a
   NAME.field struct-offset constant (resolved via Dir.TryResolveField) or
   a %define'd numeric token (already expanded by TokNext by the time we
   see it) or a bare label (data/code address, becomes
   hasLabel+labelName). *)
PROCEDURE ParseMemBody(VAR op: Enc.Operand);
  VAR size, reg: INTEGER; isSeg: BOOLEAN;
      marker1, marker2: INTEGER;
      haveReg: BOOLEAN;
      disp: LONGINT;      hasLabel: BOOLEAN; labelName: ARRAY Sym.MaxName OF CHAR;
      negNext: BOOLEAN;
      fieldVal: LONGINT;
      firstIdent: ARRAY Scan.MaxIdent OF CHAR;
BEGIN
  op.kind := Enc.OKMem; op.seg := Enc.NoSeg; op.am := Enc.AmNone;
  op.disp := LONGINT(0); op.hasLabel := FALSE; op.isFar := FALSE; op.isSegOf := FALSE;
  marker1 := -1; marker2 := -1; haveReg := FALSE;
  disp := LONGINT(0); hasLabel := FALSE; negNext := FALSE;

  (* optional leading SEG: override *)
  IF tSym = Scan.TIdent THEN
    IF LookupReg(tId, size, reg, isSeg) & isSeg THEN
      TokNext;
      IF tSym = Scan.TColon THEN
        op.seg := reg; TokNext
      ELSE
        Fail("expected ':' after segment override"); RETURN
      END
    END
  END;

  WHILE (tSym # Scan.TRbrak) & (tSym # Scan.TEof) & (tSym # Scan.TEol) DO
    IF tSym = Scan.TPlus THEN negNext := FALSE; TokNext
    ELSIF tSym = Scan.TMinus THEN negNext := TRUE; TokNext
    ELSIF tSym = Scan.TInt THEN
      IF negNext THEN disp := disp - tIval ELSE disp := disp + tIval END;
      negNext := FALSE; TokNext
    ELSIF tSym = Scan.TIdent THEN
      IF LookupReg(tId, size, reg, isSeg) & ~isSeg & (BaseIndexOf(reg) >= 0) THEN
        (* N3/M3 fix: a register can never be legally negated on 8086 --
           "[bx-si]" was silently dropping the '-' and encoding [bx+si]
           instead of failing (NASM rejects it as an invalid effective
           address). *)
        IF negNext THEN Fail("'-' before register/label in address"); RETURN END;
        IF ~haveReg THEN marker1 := BaseIndexOf(reg); haveReg := TRUE
        ELSIF marker2 < 0 THEN marker2 := BaseIndexOf(reg)
        ELSE
          (* BUG B4: a third base/index register (e.g. [bx+si+di]) has no
             8086 addressing mode at all -- silently overwriting marker2
             dropped the second register from the encoded address with no
             diagnostic. *)
          Fail("too many registers in address"); RETURN
        END;
        TokNext
      ELSIF LookupReg(tId, size, reg, isSeg) & ~isSeg THEN
        (* M2 fix: a recognized register that is NOT usable as a base/index
           (AX/CX/DX/BX's word forms are fine via BaseIndexOf above; this
           catches AX/CX/DX/SP and any other register with no addressing
           role, e.g. "[ax]") -- falling through to the identifier/label
           branch below would either report a misleading "undefined
           symbol ax", or worse, silently resolve to a same-named label
           (a label named "ax" is legal) and emit a direct-memory
           reference where NASM rejects the effective address outright. *)
        Fail("register not usable as base/index on 8086"); RETURN
      ELSE
        (* identifier: either NAME.field (struct offset), or a plain label.
           Use original case throughout -- struct names/fields are stored
           by BeginStruc/AddField using tIdOrig (see PARSE.MOD's STRUC
           handling in ParseLine), and label names are likewise looked up
           by original case (Sym.DefineLabel/Lookup) -- using the
           uppercased tId here would silently miss any mixed-case struct
           name (e.g. "TRegisters" vs the stored "TRegisters"). *)
        Strings.Copy(tIdOrig, firstIdent);
        TokNext;
        IF (tSym = Scan.TDot) THEN
          TokNext;
          IF tSym # Scan.TIdent THEN Fail("expected field name after '.'"); RETURN END;
          IF Dir.TryResolveField(firstIdent, tIdOrig, fieldVal) THEN
            IF negNext THEN disp := disp - fieldVal ELSE disp := disp + fieldVal END;
            negNext := FALSE
          ELSE
            Fail("unknown struct field")
          END;
          TokNext
        ELSE
          (* N3/M3 fix: same negation guard as the register case -- a bare
             label can also never be legally negated inside [ ] (there is
             no "negative address" concept; "[-label]" must fail, not
             silently become "[+label]"). *)
          IF negNext THEN Fail("'-' before register/label in address"); RETURN END;
          hasLabel := TRUE; Strings.Copy(firstIdent, labelName)
        END
      END
    ELSE
      Fail("unexpected token inside [ ]"); RETURN
    END
  END;

  IF tSym = Scan.TRbrak THEN TokNext ELSE Fail("expected ']'") END;

  IF haveReg THEN
    IF marker2 >= 0 THEN
      IF ~CombineBaseIndex(marker1, marker2, op.am) THEN
        Fail("invalid base+index combination"); RETURN
      END
    ELSE
      IF ~SingleRegAm(marker1, op.am) THEN Fail("invalid base register"); RETURN END
    END;
    op.disp := disp;
    IF hasLabel THEN
      (* M1 fix: [label+reg]/[reg+label] IS a legal, common 8086/NASM
         table-indexing idiom -- EmitModRm already forces Mod=10 (disp16)
         whenever hasLabel is set and EmitDisp16 already emits the RELOC
         correctly (see ENC.MOD's EmitModRm mod-selection); only this
         parser-side Fail was blocking the combination. Keep the label
         alongside the base/index register instead of rejecting it. *)
      op.hasLabel := TRUE; Strings.Copy(labelName, op.labelName);
      Sym.ReserveLabel(labelName)
    END
  ELSE
    op.am := Enc.AmNone;
    IF hasLabel THEN
      op.hasLabel := TRUE; Strings.Copy(labelName, op.labelName); op.disp := disp;
      Sym.ReserveLabel(labelName)
    ELSE
      op.disp := disp
    END
  END
END ParseMemBody;

(* ParseOperand: parse one operand (register, memory [ ... ], immediate
   number, label-as-immediate, or `far [ ... ]` / `far mem`).  `sizeHint`
   (Enc.SzByte/SzWord/SzNone) supplies the BYTE/WORD qualifier already
   consumed by the caller (Parse.MOD's directive-adjacent `byte [x]`/
   `word [x]` forms), or SzNone if none was written -- used to disambiguate
   a memory operand's width when no register operand in the same
   instruction otherwise pins it (needed for MOV [x], imm and the F6/F7/
   FE/FF unary-group forms). *)
PROCEDURE ParseOperand(VAR op: Enc.Operand; sizeHint: INTEGER);
  VAR size, reg, qual: INTEGER; isSeg: BOOLEAN; neg: BOOLEAN;
      name: ARRAY Scan.MaxIdent OF CHAR; nameOrig: ARRAY Scan.MaxIdent OF CHAR;
BEGIN
  (* full zero-init: an OKReg/OKImm operand only fills the fields it needs,
     leaving the rest as stack garbage from the caller's uninitialised
     `ops` array (BUG A3) -- EmitModRm and friends must be able to trust
     every field regardless of kind. *)
  op.kind := Enc.OKNone; op.size := sizeHint; op.reg := 0; op.am := Enc.AmNone;
  op.seg := Enc.NoSeg; op.disp := LONGINT(0); op.hasLabel := FALSE;
  op.labelName[0] := 0X;
  op.isFar := FALSE; op.isSegOf := FALSE; op.isShort := FALSE;
  IF tSym = Scan.TIdent THEN
    Strings.Copy(tId, name); Strings.Copy(tIdOrig, nameOrig);
    qual := Lex.LookupQualifier(name);
    IF qual = Lex.QByte THEN TokNext; ParseOperand(op, Enc.SzByte); RETURN END;
    IF qual = Lex.QWord THEN TokNext; ParseOperand(op, Enc.SzWord); RETURN END;
    IF qual = Lex.QFar THEN
      TokNext; ParseOperand(op, sizeHint); op.isFar := TRUE; RETURN
    END;
    IF qual = Lex.QShort THEN
      TokNext; ParseOperand(op, sizeHint); op.isShort := TRUE; RETURN
    END;
    IF qual = Lex.QNear THEN TokNext; ParseOperand(op, sizeHint); RETURN END;
    IF qual = Lex.QSeg THEN
      TokNext;
      IF tSym # Scan.TIdent THEN Fail("expected label after SEG"); RETURN END;
      Strings.Copy(tIdOrig, nameOrig); TokNext;
      op.kind := Enc.OKImm; op.hasLabel := TRUE; op.isSegOf := TRUE;
      Strings.Copy(nameOrig, op.labelName); op.disp := LONGINT(0);
      Sym.ReserveLabel(nameOrig);
      IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
      RETURN
    END;
    IF LookupReg(name, size, reg, isSeg) THEN
      TokNext;
      IF isSeg THEN op.kind := Enc.OKSegReg ELSE op.kind := Enc.OKReg END;
      op.reg := reg; op.size := size; op.seg := Enc.NoSeg;
      RETURN
    END;
    (* bare label used as an immediate/address value -- original case, to
       match Sym.DefineLabel's storage (see the note on the [ ] path
       above: label names are never uppercased).  Optional trailing
       "+ disp"/"- disp" (e.g. "mov ax, __data+0", ccasm's array-address
       form) is consumed here the same way ParseMemBody does inside [ ] --
       without this, the leftover '+'/'-' token is never advanced past by
       ParseInstruction/ParseLine and RunPass's main loop spins forever
       (never reaching TEol/TEof). *)
    TokNext;
    op.kind := Enc.OKImm; op.hasLabel := TRUE; Strings.Copy(nameOrig, op.labelName);
    op.disp := LONGINT(0);
    Sym.ReserveLabel(nameOrig);
    WHILE (tSym = Scan.TPlus) OR (tSym = Scan.TMinus) DO
      neg := (tSym = Scan.TMinus); TokNext;
      IF tSym # Scan.TInt THEN Fail("expected number after '+'/'-'"); RETURN END;
      IF neg THEN op.disp := op.disp - tIval ELSE op.disp := op.disp + tIval END;
      TokNext
    END;
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
    RETURN
  ELSIF tSym = Scan.TDot THEN
    (* bare local-label reference, e.g. "jne .no_fpu" *)
    TokNext;
    IF tSym # Scan.TIdent THEN Fail("expected identifier after '.'"); RETURN END;
    nameOrig[0] := "."; nameOrig[1] := 0X; Strings.Append(tIdOrig, nameOrig); TokNext;
    op.kind := Enc.OKImm; op.hasLabel := TRUE; Strings.Copy(nameOrig, op.labelName);
    op.disp := LONGINT(0);
    Sym.ReserveLabel(nameOrig);
    (* N10 fix: mirror the bare-ident branch's "+ disp"/"- disp" chain --
       without this, "jmp .loop+2" fell through to the generic A2
       no-progress guard ("unexpected token at start of statement")
       instead of either working or naming the real problem. *)
    WHILE (tSym = Scan.TPlus) OR (tSym = Scan.TMinus) DO
      neg := (tSym = Scan.TMinus); TokNext;
      IF tSym # Scan.TInt THEN Fail("expected number after '+'/'-'"); RETURN END;
      IF neg THEN op.disp := op.disp - tIval ELSE op.disp := op.disp + tIval END;
      TokNext
    END;
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
    RETURN
  ELSIF tSym = Scan.TLbrak THEN
    TokNext; ParseMemBody(op);
    (* BUG B1: no WORD default here -- an unsized memory operand (no
       BYTE/WORD qualifier and no register operand on the same instruction
       to infer width from) is a real NASM hard error ("operation size not
       specified"), not a silent WORD assumption that corrupts an adjacent
       byte buffer. Encoders whose width depends solely on the memory
       operand (EncIncDec/EncUnaryGroup/EncShift, mem-imm EncMov/EncAlu/
       EncTest) must Err on SzNone themselves; a register operand on the
       same instruction still pins width the same way it always has,
       since those encoders read the REGISTER's size in that case, not
       the memory operand's. *)
    RETURN
  ELSIF (tSym = Scan.TInt) OR (tSym = Scan.TMinus) THEN
    neg := FALSE;
    IF tSym = Scan.TMinus THEN neg := TRUE; TokNext END;
    IF tSym # Scan.TInt THEN Fail("expected number"); RETURN END;
    op.kind := Enc.OKImm; op.hasLabel := FALSE;
    IF neg THEN op.disp := -tIval ELSE op.disp := tIval END;
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
    TokNext; RETURN
  ELSIF tSym = Scan.TString THEN
    (* single-character literal used as an immediate, e.g. cmp byte [..], 'E' *)
    (* C7 fix: an empty string '' has tSval[0]=0X too, so the old check
       (tSval[1] # 0X) alone passed it through as immediate 0, silently. *)
    IF tSval[0] = 0X THEN Fail("empty string literal is not valid as an immediate"); RETURN END;
    IF tSval[1] # 0X THEN Fail("only single-character literals are valid as an immediate"); RETURN END;
    op.kind := Enc.OKImm; op.hasLabel := FALSE; op.disp := LONGINT(ORD(tSval[0]));
    IF op.size = Enc.SzNone THEN op.size := Enc.SzByte END;
    TokNext; RETURN
  ELSIF tSym = Scan.TLparen THEN
    (* parenthesized constant-arithmetic immediate, e.g. "and ax, (PageSize
       - 1)" -- PageSize is a %define already expanded to a plain number by
       TokNext by the time we see it here, so this only needs to sum a
       chain of +/- terms up to the closing ')'; no label references occur
       in this form in either oracle file (Simplicity First: general
       expression parsing is not implemented). *)
    TokNext;
    op.kind := Enc.OKImm; op.hasLabel := FALSE; op.disp := LONGINT(0);
    neg := FALSE;
    WHILE (tSym # Scan.TRparen) & (tSym # Scan.TEol) & (tSym # Scan.TEof) DO
      IF tSym = Scan.TPlus THEN neg := FALSE; TokNext
      ELSIF tSym = Scan.TMinus THEN neg := TRUE; TokNext
      ELSIF tSym = Scan.TInt THEN
        IF neg THEN op.disp := op.disp - tIval ELSE op.disp := op.disp + tIval END;
        neg := FALSE; TokNext
      ELSE
        Fail("unsupported expression inside ( )"); RETURN
      END
    END;
    IF tSym = Scan.TRparen THEN TokNext ELSE Fail("expected ')'"); RETURN END;
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
    RETURN
  ELSE
    Fail("expected operand")
  END
END ParseOperand;

(* ---- emission helpers that respect pass gating the same way Enc.B/W do:
   count in pass 1, write to Rdoff in pass 2.  DB/DW/TIMES are legal in
   both SECTION .text and SECTION .data, so every one of these routes
   through the current section (curSeg: Sym.SegCode/Sym.SegData), updating
   whichever running offset (codeOfs/dataOfs) matches. *)

PROCEDURE EmitDataByte(b: BYTE);
  VAR rseg: INTEGER;
BEGIN
  IF curSeg = Sym.SegCode THEN rseg := Rdoff.SegCode ELSE rseg := Rdoff.SegData END;
  IF curPass = 2 THEN Rdoff.EmitByte(obj, rseg, b) END;
  IF curSeg = Sym.SegCode THEN codeOfs := codeOfs + LONGINT(1)
  ELSE dataOfs := dataOfs + LONGINT(1)
  END
END EmitDataByte;

PROCEDURE EmitDataWord(w: INTEGER);
  VAR rseg: INTEGER;
BEGIN
  IF curSeg = Sym.SegCode THEN rseg := Rdoff.SegCode ELSE rseg := Rdoff.SegData END;
  IF curPass = 2 THEN Rdoff.EmitWord(obj, rseg, w) END;
  IF curSeg = Sym.SegCode THEN codeOfs := codeOfs + LONGINT(2)
  ELSE dataOfs := dataOfs + LONGINT(2)
  END
END EmitDataWord;

(* EmitDataWordMaybeLabel: DW val, where val may be a label (word address,
   with a relocation in pass 2) rather than a plain constant. *)
PROCEDURE EmitDataWordMaybeLabel(VAR op: Enc.Operand);
  VAR lseg: INTEGER; lofs: LONGINT; patchSeg: INTEGER; patchOfs: LONGINT; impId: INTEGER;
BEGIN
  IF op.hasLabel & (curPass = 2) THEN
    IF curSeg = Sym.SegCode THEN patchSeg := Rdoff.SegCode; patchOfs := codeOfs
    ELSE patchSeg := Rdoff.SegData; patchOfs := dataOfs
    END;
    IF Sym.IsExtern(op.labelName) THEN
      (* mirror Enc.EmitDisp16's extern branch (BUG A5): an EXTERN target's
         address is unknown until link time, so the reloc's RSEG must be
         the import ID, not this module's own code/data segment -- the
         addend is the operand's own constant offset only (no lofs, since
         there is no local definition to add in). *)
      (* N4 residual fix: the +n addend of "dw extlabel+n" wraps mod
         65536 just like a plain word value -- same guard/bounds as the
         constant arm below. *)
      IF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
        Fail("word value out of range"); RETURN
      END;
      impId := Enc.EnsureImportId(op.labelName);
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, impId, FALSE);
      EmitDataWord(INTEGER(op.disp));
      RETURN
    END;
    (* N9 fix: every sibling site (EmitDisp16, EncJmpShort, ...) returns/
       emits-placeholder on this Fail -- missing RETURN here left
       lseg/lofs uninitialized and fell through into the reloc dispatch
       below. Currently unreachable (A1's CheckAllDefined runs before
       Pass 2 and every referenced label is at least reserved), but a
       future refactor could reach this with garbage state. *)
    IF ~Sym.Lookup(op.labelName, lseg, lofs) THEN Fail("undefined symbol"); RETURN END;
    (* three-way dispatch (R3 fix): a BSS-defined label was falling into
       the ELSE arm and relocating against SegData -- mirror Enc.AddReloc's
       three-way dispatch so `dw bssLabel` gets the correct RSEG. *)
    IF lseg = Sym.SegCode THEN
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, Rdoff.SegCode, FALSE)
    ELSIF lseg = Sym.SegData THEN
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, Rdoff.SegData, FALSE)
    ELSE
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, Rdoff.SegBss, FALSE)
    END;
    (* addend on disk must be the target's own local offset (op.disp+lofs),
       matching EmitDisp16's intra-module RELOC convention -- see its
       comment on the absolute-RELOC addend formula. N4 residual fix:
       guard the sum against mod-65536 wrap, same as EmitDisp16's own
       intra-module arm. *)
    IF (op.disp + lofs < LONGINT(-32768)) OR (op.disp + lofs > LONGINT(65535)) THEN
      Fail("word value out of range"); RETURN
    END;
    EmitDataWord(INTEGER(op.disp + lofs));
    RETURN
  END;
  (* N4 fix: same word-range guard as Enc.EmitDisp16 -- a plain-constant
     DW value silently wrapped mod 65536 (e.g. "dw 70000" -> 4464) with
     no diagnostic. *)
  IF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
    Fail("word value out of range"); RETURN
  END;
  EmitDataWord(INTEGER(op.disp))
END EmitDataWordMaybeLabel;

(* ParseDbList: DB val [, val ...] -- each val is a numeric byte or a
   quoted string (each character emitted as one byte, NASM db-string
   semantics). *)
PROCEDURE ParseDbList;
  VAR i: INTEGER; more: BOOLEAN;
BEGIN
  more := TRUE;
  WHILE more DO
    IF tSym = Scan.TString THEN
      i := 0;
      WHILE tSval[i] # 0X DO EmitDataByte(BYTE(ORD(tSval[i]))); INC(i) END;
      TokNext
    ELSIF (tSym = Scan.TInt) OR (tSym = Scan.TMinus) THEN
      IF tSym = Scan.TMinus THEN
        TokNext;
        IF tSym # Scan.TInt THEN Fail("expected number after '-'"); RETURN END;
        (* C5 fix: BYTE(...) silently truncates any out-of-range value --
           reject rather than wrap, matching NASM's warning-turned-error
           policy for this class of surprise. *)
        IF (tIval < 0) OR (tIval > 128) THEN Fail("DB value out of range (-128..255)"); RETURN END;
        EmitDataByte(BYTE(-tIval)); TokNext
      ELSE
        IF (tIval < 0) OR (tIval > 255) THEN Fail("DB value out of range (-128..255)"); RETURN END;
        EmitDataByte(BYTE(tIval)); TokNext
      END
    ELSE
      Fail("expected byte value in DB"); RETURN
    END;
    IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
  END
END ParseDbList;

(* ParseDwList: DW val [, val ...] -- val is a number or a label (word
   address, with a relocation in pass 2). *)
PROCEDURE ParseDwList;
  VAR op: Enc.Operand; more: BOOLEAN;
BEGIN
  more := TRUE;
  WHILE more DO
    ParseOperand(op, Enc.SzWord);
    IF op.kind = Enc.OKImm THEN EmitDataWordMaybeLabel(op)
    ELSE Fail("expected value in DW")
    END;
    IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
  END
END ParseDwList;

(* ---- STRUC field-size keywords: RESB/RESW/RESD n ---- *)
PROCEDURE ParseStrucField(field: ARRAY OF CHAR);
  VAR kw: ARRAY Scan.MaxIdent OF CHAR; szBytes, count: LONGINT; neg: BOOLEAN; d: INTEGER;
      fn: ARRAY 128 OF CHAR;
BEGIN
  IF tSym # Scan.TIdent THEN Fail("expected RESB/RESW/RESD"); RETURN END;
  Strings.Copy(tId, kw); TokNext;
  d := Lex.LookupDirective(kw);
  IF d = Lex.DResb THEN szBytes := LONGINT(1)
  ELSIF d = Lex.DResw THEN szBytes := LONGINT(2)
  ELSIF d = Lex.DResd THEN szBytes := LONGINT(4)
  ELSE Fail("expected RESB/RESW/RESD"); RETURN
  END;
  neg := FALSE;
  IF tSym = Scan.TMinus THEN neg := TRUE; TokNext END;
  IF tSym # Scan.TInt THEN Fail("expected count"); RETURN END;
  count := tIval; IF neg THEN count := -count END;
  TokNext;
  (* C6 fix: a negative count walks the STRUC field offset backwards with
     no diagnostic, corrupting every later field's offset silently. *)
  IF count < LONGINT(0) THEN Fail("RESB/RESW/RESD count must not be negative"); RETURN END;
  CurFname(fn);
  Dir.AddField(field, szBytes, count, fn, tLine)
END ParseStrucField;

(* ---- directive dispatch: BITS/CPU/SECTION/GLOBAL/STRUC/ENDSTRUC/
   %DEFINE/%UNDEF/%IFDEF/%ELSE/%ENDIF/DB/DW/TIMES.  Returns TRUE if `kw`
   (already uppercased) was a recognized directive and was fully consumed
   (including its own trailing operands, up to TEol/TEof). ---- *)

PROCEDURE SkipToEol;
BEGIN WHILE (tSym # Scan.TEol) & (tSym # Scan.TEof) DO TokNext END
END SkipToEol;

(* skipDepth/ifTrue track %ifdef nesting: skipping[d] TRUE means the code
   at nesting depth d is currently suppressed (condition false, or an
   outer level is already suppressed).  branchTaken[d] remembers whether
   the IF (not yet ELSE) branch condition was true, for %else to invert. *)
VAR
  skipping:    ARRAY 16 OF BOOLEAN;
  branchTrue:  ARRAY 16 OF BOOLEAN;
  sawElse:     ARRAY 16 OF BOOLEAN;   (* C9: duplicate %else detection *)
  ifDepth:     INTEGER;

PROCEDURE CurrentlySkipping(): BOOLEAN;
  VAR i: INTEGER; r: BOOLEAN;
BEGIN
  r := FALSE; i := 0;
  WHILE i < ifDepth DO IF skipping[i] THEN r := TRUE END; INC(i) END;
  RETURN r
END CurrentlySkipping;

PROCEDURE DoIfdef;
  VAR name: ARRAY Scan.MaxIdent OF CHAR; cond: BOOLEAN;
BEGIN
  IF tSym # Scan.TIdent THEN Fail("expected identifier after %ifdef"); RETURN END;
  Strings.Copy(tId, name); RawTokNext;
  (* paper cut fix: mirror %include's own trailing-EOL check -- trailing
     junk after the name used to be silently mis-parsed as a new
     statement ("unknown directive or mnemonic") instead of naming the
     real problem. *)
  IF (tSym # Scan.TEol) & (tSym # Scan.TEof) THEN
    Fail("unexpected text after %ifdef name"); RETURN
  END;
  cond := Sym.IsDefine(name);
  IF ifDepth < 16 THEN
    skipping[ifDepth] := CurrentlySkipping() OR ~cond;
    branchTrue[ifDepth] := cond;
    sawElse[ifDepth] := FALSE;
    INC(ifDepth)
  ELSE
    Fail("%ifdef nested too deep")
  END
END DoIfdef;

PROCEDURE DoElse;
BEGIN
  IF ifDepth = 0 THEN Fail("%else without %ifdef"); RETURN END;
  (* C9 fix: a duplicate %else for the same %ifdef was silently accepted
     and re-toggled nothing detectably. *)
  IF sawElse[ifDepth-1] THEN Fail("duplicate %else for the same %ifdef"); RETURN END;
  sawElse[ifDepth-1] := TRUE;
  IF ifDepth = 1 THEN skipping[0] := branchTrue[0]
  ELSE skipping[ifDepth-1] := skipping[ifDepth-2] OR branchTrue[ifDepth-1]
  END
END DoElse;

PROCEDURE DoEndif;
BEGIN
  IF ifDepth = 0 THEN Fail("%endif without %ifdef"); RETURN END;
  DEC(ifDepth)
END DoEndif;

(* DoInclude: %include "FILE.INC" -- §I.3. The filename is read via
   RawTokNext (NOT TokNext) so it is never itself %define-expanded, same
   rationale as the identifier immediately after %define/%undef/%ifdef.
   NASM skips %include inside a false %ifdef branch without opening the
   file at all (the `%ifdef DOS_BUILD / %include "dosonly.inc"` idiom
   must not fail just because dosonly.inc doesn't exist on this build),
   so the skip check runs BEFORE any Files.Reset. *)
PROCEDURE DoInclude;
  VAR path: ARRAY 128 OF CHAR; i: INTEGER;
BEGIN
  (* TryPercentDirective's caller already advanced past the "INCLUDE"
     keyword itself (its own RawTokNext, right after matching kw) before
     dispatching here -- the current token IS the filename operand
     already; do not consume another token first. *)
  IF tSym # Scan.TString THEN Fail("expected filename string after %include"); RETURN END;
  (* paper cut fix: Strings.Copy truncates silently when tSval (up to
     Scan.MaxStr-1 = 255 chars) doesn't fit path (128) -- without this
     guard, a >127-char include path failed downstream with a confusing
     "cannot open include file" naming the TRUNCATED path. *)
  IF Strings.Length(tSval) >= LEN(path) THEN Fail("%include path too long"); RETURN END;
  Strings.Copy(tSval, path);
  RawTokNext;
  IF (tSym # Scan.TEol) & (tSym # Scan.TEof) THEN
    Fail("unexpected text after %include filename"); RETURN
  END;
  IF CurrentlySkipping() THEN RETURN END;
  IF srcTop = MaxSrcDepth - 1 THEN Fail("%include nested too deep"); RETURN END;
  (* cycle check: compare against every FILE entry currently on the
     stack, case-insensitively (DOS paths are case-insensitive) -- a
     %include cycle would otherwise recurse until MaxSrcDepth's fatal
     error fires anyway, but with a confusing "nested too deep" message
     instead of naming the actual problem. *)
  i := 0;
  WHILE i <= srcTop DO
    IF stk[i].isFile & Strings.EqualICase(stk[i].scn.fname, path) THEN
      Fail("recursive %include"); RETURN
    END;
    INC(i)
  END;
  INC(srcTop);
  stk[srcTop].isFile := TRUE; stk[srcTop].isDefine := FALSE;
  IF ~Files.Reset(stk[srcTop].f, path) THEN
    DEC(srcTop); Fail("cannot open include file"); RETURN
  END;
  Scan.Init(stk[srcTop].scn, stk[srcTop].f, path)
END DoInclude;

VAR
  inMacroDef: BOOLEAN;   (* §I.4: TRUE while DoMacroRecord is capturing a
                             %macro...%endmacro body -- guards against a
                             nested %macro, which this design does not
                             support (Out of scope v1, TASM.MD §I.4). *)

(* IsEndmacroLine: TRUE if the raw line text (buf[0..n)) is, once leading
   blanks are skipped, the bare directive "%endmacro" (case-insensitive,
   matching every other directive keyword in this module) and nothing
   else but trailing blanks. Deliberately simple string scanning, not a
   real tokenize -- this is the one line DoMacroRecord's raw-capture loop
   must recognize without disturbing the byte-exact capture of every
   OTHER line. *)
PROCEDURE IsEndmacroLine(buf: ARRAY OF CHAR; n: INTEGER): BOOLEAN;
  VAR i, j: INTEGER; word: ARRAY 16 OF CHAR;
BEGIN
  i := 0;
  WHILE (i < n) & ((buf[i] = " ") OR (ORD(buf[i]) = 9)) DO INC(i) END;
  j := 0;
  WHILE (i < n) & (j < LEN(word) - 1) & (buf[i] # " ") & (ORD(buf[i]) # 9) DO
    word[j] := SYSTEM.UCASE(buf[i]); INC(i); INC(j)
  END;
  word[j] := 0X;
  WHILE (i < n) & ((buf[i] = " ") OR (ORD(buf[i]) = 9)) DO INC(i) END;
  (* N5 fix: "%endmacro ; note" was captured as body text instead of being
     recognized, since this required EXACTLY blanks-then-EOL after the
     keyword -- a trailing comment-to-EOL is valid NASM source and must be
     accepted the same way IsMacroLine's own trailing-content tolerance
     already treats non-blank content after "%macro" as fine. *)
  RETURN ((i = n) OR (buf[i] = ";")) & Strings.Equal(word, "%ENDMACRO")
END IsEndmacroLine;

(* IsMacroLine: TRUE if the raw line text starts (after leading blanks)
   with "%macro" as a whole word -- used by DoMacroRecord's raw-capture
   loop to detect and reject a NESTED %macro while still inside another
   one. Without this check, a nested %macro's header line would simply
   be captured as ordinary body text (indistinguishable from any other
   line) and the raw-capture loop would stop at whichever %endmacro it
   sees FIRST -- silently mis-scoping the outer macro's body instead of
   reporting "nested %macro not supported" the way the header comment
   promises. Only checks the word, not trailing content, since a
   %macro line always has more tokens after the keyword (name,
   nparams) that this raw check does not need to validate -- DoMacroRecord's
   fatal path fires before any of that would matter. *)
PROCEDURE IsMacroLine(buf: ARRAY OF CHAR; n: INTEGER): BOOLEAN;
  VAR i, j: INTEGER; word: ARRAY 16 OF CHAR;
BEGIN
  i := 0;
  WHILE (i < n) & ((buf[i] = " ") OR (ORD(buf[i]) = 9)) DO INC(i) END;
  j := 0;
  WHILE (i < n) & (j < LEN(word) - 1) & (buf[i] # " ") & (ORD(buf[i]) # 9) DO
    word[j] := SYSTEM.UCASE(buf[i]); INC(i); INC(j)
  END;
  word[j] := 0X;
  RETURN Strings.Equal(word, "%MACRO")
END IsMacroLine;

(* DoMacroRecord: %macro NAME NPARAMS ... %endmacro -- §I.4. Reads the
   header via the normal tokenizer (RawTokNext, uppercased name, exactly
   %define's own convention), then switches to RAW LINE capture
   (Scan.ReadRawLine) for the body: re-tokenizing and re-serializing the
   body via TokToText would reopen the B5 lossy-serializer trap this
   design explicitly avoids -- a macro body's strings/comments/spacing
   must survive byte-for-byte. Skipped (consumed, not stored) inside a
   false %ifdef branch, mirroring %define's own skip semantics -- the
   raw lines are still read (to keep the scanner in sync and to still
   detect %endmacro/EOF correctly) but never appended to the staging
   buffer nor recorded into Sym. *)
PROCEDURE DoMacroRecord;
  VAR name: ARRAY Sym.MaxName OF CHAR; nParams: INTEGER;
      lineBuf: ARRAY 512 OF CHAR;
      total, lineLen: INTEGER; eof, overLong, done, skipping: BOOLEAN;
      body: Scan.MemText;
BEGIN
  IF inMacroDef THEN Fail("nested %macro not supported"); RETURN END;
  IF tSym # Scan.TIdent THEN Fail("expected macro name after %macro"); RETURN END;
  Strings.Copy(tId, name); RawTokNext;
  IF tSym # Scan.TInt THEN Fail("expected parameter count after %macro name"); RETURN END;
  IF (tIval < 0) OR (tIval > 9) THEN Fail("%macro parameter count must be 0..9"); RETURN END;
  nParams := INTEGER(tIval);
  RawTokNext;
  IF (tSym # Scan.TEol) & (tSym # Scan.TEof) THEN
    Fail("unexpected text after %macro header"); RETURN
  END;
  skipping := CurrentlySkipping();
  inMacroDef := TRUE;
  total := 0; done := FALSE;
  WHILE ~done DO
    (* Raw capture stays anchored to stk[srcTop] -- the file/include
       currently supplying source at the point %macro appeared; a
       %macro body can span physical lines of that same source but
       never crosses an include boundary (the design does not support
       a %macro spanning into/out of a %include). *)
    Scan.ReadRawLine(stk[srcTop].scn, lineBuf, lineLen, eof, overLong);
    IF IsEndmacroLine(lineBuf, lineLen) THEN
      done := TRUE
    ELSIF IsMacroLine(lineBuf, lineLen) THEN
      (* without this check, a nested %macro's header would just be
         captured as body text and the outer capture would stop at
         whichever %endmacro comes first -- silently mis-scoping the
         outer body instead of rejecting the nesting outright. *)
      Fail("nested %macro not supported"); inMacroDef := FALSE; RETURN
    ELSIF eof THEN
      Fail("missing %endmacro"); inMacroDef := FALSE; RETURN
    (* N7 fix: a macro-body line longer than LEN(lineBuf) used to be
       captured silently truncated -- reject it loudly instead. *)
    ELSIF overLong THEN
      Fail("macro body line too long"); inMacroDef := FALSE; RETURN
    ELSE
      IF ~skipping THEN
        (* +1 for the LF this loop re-inserts between captured lines
           (ReadRawLine strips it), +1 for the final NUL added once the
           whole body is staged. *)
        IF total + lineLen + 2 >= LEN(macroBodyBuf) THEN
          Fail("macro body too long"); inMacroDef := FALSE; RETURN
        END;
        IF lineLen > 0 THEN SYSTEM.MOVE(lineBuf[0], macroBodyBuf[total], lineLen) END;
        INC(total, lineLen);
        macroBodyBuf[total] := CHR(10); INC(total)   (* re-insert the LF *)
      END
    END
  END;
  inMacroDef := FALSE;
  IF skipping THEN RETURN END;
  macroBodyBuf[total] := 0X;
  (* MemText is a fixed-size (Scan.MaxMemText) heap pointer to a one-
     field RECORD wrapping the buffer -- see Scan.MemText's own comment
     for why (a compiler VAR-parameter type-compatibility gap for bare
     POINTER-TO-ARRAY across three modules). NEW takes no size argument. *)
  NEW(body);
  IF body = NIL THEN Fail("out of memory (macro body)"); RETURN END;
  SYSTEM.MOVE(macroBodyBuf[0], body^.buf[0], total);
  body^.buf[total] := 0X;
  Sym.DefineMacro(name, nParams, body)
END DoMacroRecord;

(* DoTimes: TIMES n DB/DW val -- since every TIMES in both oracle files is
   `times N db 0` (a single repeated byte), this handles exactly
   `TIMES n DB byteval` and `TIMES n DW wordval` (single-value form only,
   matching actual usage -- a list form `times n db a,b,c` is out of scope
   for v1, Simplicity First). *)
PROCEDURE DoTimes(count: LONGINT);
  VAR kw: ARRAY Scan.MaxIdent OF CHAR; op: Enc.Operand; i: LONGINT;
BEGIN
  TokNext;  (* consume the count *)
  IF tSym # Scan.TIdent THEN Fail("expected DB/DW after TIMES"); RETURN END;
  Strings.Copy(tId, kw); TokNext;
  IF Strings.Equal(kw, "DB") THEN
    ParseOperand(op, Enc.SzByte);
    IF (op.kind # Enc.OKImm) OR op.hasLabel THEN
      (* BUG B2: a label reference (kind=OKImm, hasLabel=TRUE) passed this
         check when it only tested `kind`, then EmitDataByte(BYTE(op.disp))
         silently wrote a run of 0-bytes with no reloc at all -- TIMES has
         no per-iteration reloc-emission path, so a repeated label value is
         not supported at all (Simplicity First), not merely a constant. *)
      Fail("TIMES DB requires a constant value"); RETURN
    END;
    i := LONGINT(0);
    WHILE i < count DO EmitDataByte(BYTE(op.disp)); i := i + LONGINT(1) END
  ELSIF Strings.Equal(kw, "DW") THEN
    ParseOperand(op, Enc.SzWord);
    IF (op.kind # Enc.OKImm) OR op.hasLabel THEN
      Fail("TIMES DW requires a constant value"); RETURN
    END;
    (* N4 fix: same word-range guard as EmitDataWordMaybeLabel. *)
    IF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
      Fail("word value out of range"); RETURN
    END;
    i := LONGINT(0);
    WHILE i < count DO EmitDataWord(INTEGER(op.disp)); i := i + LONGINT(1) END
  ELSE
    Fail("TIMES only supports DB/DW in this dialect")
  END
END DoTimes;

(* ParseTopLevelRes: RESB/RESW/RESD n as a statement-level directive
   inside SECTION .bss (as opposed to Dir.MOD's ParseStrucField, the same
   keywords used as STRUC field declarations) -- reserves n*size bytes of
   uninitialized space by advancing bssOfs, without emitting anything
   (BSS content lives outside the RDOFF2 code/data segment streams
   entirely -- see Rdoff.RdfSetBss). A label immediately before the
   directive (e.g. "buf: resb 100") is defined by ParseLine's normal
   colon-terminated-label handling before TryDirective ever runs, so no
   special label logic is needed here. Only valid in SECTION .bss --
   RESB/RESW/RESD in .text/.data would silently do nothing useful (no
   bytes end up in the segment stream either way), so it's rejected as a
   fatal error instead of a silent no-op. *)
(* ParseResTerm: one signed integer literal -- the leaf of the count
   expression grammar below. *)
PROCEDURE ParseResTerm(VAR v: LONGINT);
  VAR neg: BOOLEAN;
BEGIN
  neg := FALSE;
  IF tSym = Scan.TMinus THEN neg := TRUE; TokNext END;
  IF tSym # Scan.TInt THEN Fail("expected count after RESB/RESW/RESD"); RETURN END;
  v := tIval; IF neg THEN v := -v END;
  TokNext
END ParseResTerm;

(* ParseResMulDiv: left-to-right chain of '*'/'/' over integer terms,
   e.g. "32*1024/16". *)
PROCEDURE ParseResMulDiv(VAR v: LONGINT);
  VAR rhs: LONGINT;
BEGIN
  ParseResTerm(v);
  WHILE (tSym = Scan.TStar) OR (tSym = Scan.TSlash) DO
    IF tSym = Scan.TStar THEN
      TokNext; ParseResTerm(rhs); v := v * rhs
    ELSE
      TokNext; ParseResTerm(rhs);
      IF rhs = LONGINT(0) THEN Fail("division by zero in RESB/RESW/RESD count"); RETURN END;
      v := v DIV rhs
    END
  END
END ParseResMulDiv;

(* ParseResExpr: left-to-right chain of '+'/'-' over ParseResMulDiv terms,
   e.g. "32*1024/16+1" -- the full count-operand grammar RESB/RESW/RESD
   accept (bare integers, optionally combined with +, -, *, / at NASM's
   usual precedence -- no parens, matching Simplicity First: this dialect
   only needs to size .bss buffers from simple constant arithmetic). *)
PROCEDURE ParseResExpr(VAR v: LONGINT);
  VAR rhs: LONGINT; isPlus: BOOLEAN;
BEGIN
  ParseResMulDiv(v);
  WHILE (tSym = Scan.TPlus) OR (tSym = Scan.TMinus) DO
    isPlus := (tSym = Scan.TPlus); TokNext;
    ParseResMulDiv(rhs);
    IF isPlus THEN v := v + rhs ELSE v := v - rhs END
  END
END ParseResExpr;

PROCEDURE ParseTopLevelRes(d: INTEGER);
  VAR szBytes, count: LONGINT;
BEGIN
  IF curSeg # Sym.SegBss THEN
    Fail("RESB/RESW/RESD only valid in SECTION .bss"); RETURN
  END;
  IF d = Lex.DResb THEN szBytes := LONGINT(1)
  ELSIF d = Lex.DResw THEN szBytes := LONGINT(2)
  ELSE szBytes := LONGINT(4)
  END;
  ParseResExpr(count);
  (* C6 fix: a negative count silently SHRINKS bssOfs (later labels then
     overlap earlier reservations) instead of erroring. *)
  IF count < LONGINT(0) THEN Fail("RESB/RESW/RESD count must not be negative"); RETURN END;
  bssOfs := bssOfs + szBytes * count
END ParseTopLevelRes;

(* TryDirective: handles the directive named by `kw` (already scanned and
   uppercased, current token already advanced past it).  Returns TRUE if
   `kw` was recognized. *)
PROCEDURE TryDirective(kw: ARRAY OF CHAR): BOOLEAN;
  VAR strucName: ARRAY Sym.MaxName OF CHAR;
      more: BOOLEAN; d: INTEGER;
      fn: ARRAY 128 OF CHAR;
BEGIN
  CurFname(fn);
  d := Lex.LookupDirective(kw);
  CASE d OF
    Lex.DBits, Lex.DCpu:
      SkipToEol
  | Lex.DSection:
      IF tSym # Scan.TDot THEN Fail("expected .text/.data/.bss after SECTION")
      ELSE
        TokNext;
        IF tSym # Scan.TIdent THEN Fail("expected .text/.data/.bss after SECTION")
        ELSE
          IF Strings.Equal(tId, "TEXT") THEN curSeg := Sym.SegCode
          ELSIF Strings.Equal(tId, "DATA") THEN curSeg := Sym.SegData
          ELSIF Strings.Equal(tId, "BSS") THEN curSeg := Sym.SegBss
          ELSE Fail("unknown section (want .text, .data, or .bss)")
          END;
          TokNext
        END
      END
  | Lex.DGlobal:
      more := TRUE;
      WHILE more DO
        IF tSym # Scan.TIdent THEN Fail("expected symbol name after GLOBAL"); more := FALSE
        ELSE
          Sym.MarkGlobal(tIdOrig); TokNext;
          IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
        END
      END
  | Lex.DExtern:
      (* EXTERN name[, name...] (IMPORT is a TASM-added synonym) -- declares
         a symbol defined in another module; references to it resolve via
         an RDFREC_IMPORT (Enc.MOD's EmitDisp16) instead of an intra-module
         RDFREC_RELOC. *)
      more := TRUE;
      WHILE more DO
        IF tSym # Scan.TIdent THEN Fail("expected symbol name after EXTERN"); more := FALSE
        ELSE
          Sym.MarkExtern(tIdOrig); TokNext;
          IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
        END
      END
  | Lex.DStruc:
      IF tSym # Scan.TIdent THEN Fail("expected struct name after STRUC")
      ELSE
        Strings.Copy(tIdOrig, strucName);
        Dir.BeginStruc(strucName, fn, tLine);
        TokNext
      END
  | Lex.DEndstruc:
      Dir.EndStruc(fn, tLine)
  | Lex.DDb:
      ParseDbList
  | Lex.DDw:
      ParseDwList
  | Lex.DTimes:
      IF tSym # Scan.TInt THEN Fail("expected repeat count after TIMES")
      ELSE DoTimes(tIval)
      END
  | Lex.DResb, Lex.DResw, Lex.DResd:
      ParseTopLevelRes(d)
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END TryDirective;

(* TokToText: append the CURRENT token's text representation to val,
   followed by one separator space -- the ONE shared token->text
   serializer (B5/E3 lesson: this used to be duplicated once for
   %define bodies and would have been duplicated again for %macro
   actual-parameter capture; now both call this). Returns FALSE (with
   Fail already called) on a token this serializer cannot represent, or
   on growth that would truncate val. *)
PROCEDURE TokToText(VAR val: ARRAY OF CHAR; whatBody: ARRAY OF CHAR): BOOLEAN;
  VAR msg: ARRAY 96 OF CHAR;
BEGIN
  IF tSym = Scan.TIdent THEN Strings.Append(tIdOrig, val)
  ELSIF tSym = Scan.TInt THEN Strings.AppendInt(tIval, val)
  ELSIF tSym = Scan.TColon THEN Strings.Append(":", val)
  ELSIF tSym = Scan.TLbrak THEN Strings.Append("[", val)
  ELSIF tSym = Scan.TRbrak THEN Strings.Append("]", val)
  ELSIF tSym = Scan.TPlus THEN Strings.Append("+", val)
  ELSIF tSym = Scan.TMinus THEN Strings.Append("-", val)
  ELSIF tSym = Scan.TComma THEN Strings.Append(",", val)
  ELSIF tSym = Scan.TStar THEN Strings.Append("*", val)
  ELSIF tSym = Scan.TSlash THEN Strings.Append("/", val)
  ELSE
    (* BUG B5: every other token (string literals, '(' ')' '.' '%',
       TError) was silently swallowed here -- only the separator space
       got appended, so e.g. "%define SZ 4*2" (before the TStar/TSlash
       cases above existed) stored "4 2 ", which a later use then
       mis-parses or re-triggers BUG A2's stray-token hang, with no
       diagnostic pointing at the %define line itself. *)
    Strings.Copy("unsupported token in ", msg); Strings.Append(whatBody, msg);
    Fail(msg); RETURN FALSE
  END;
  (* val's buffer size varies by caller (128 for %define, up to the
     shared macro-arg staging size); Strings.Append truncates silently
     past LEN(val) -- reject growth that would truncate rather than
     storing a partial body with no diagnostic. R4 fix: check the
     ACTUAL length already written, not a compile-time array bound that
     doesn't match the token's real text length. *)
  IF Strings.Length(val) >= LEN(val) - 1 THEN
    Strings.Copy(whatBody, msg); Strings.Append(" too long", msg);
    Fail(msg); RETURN FALSE
  END;
  Strings.Append(" ", val);
  RETURN TRUE
END TokToText;

(* ---- %-preprocessor line dispatch (a leading '%' token; consumes the
   directive keyword itself since Scan yields TPercent as a separate
   token from the following identifier). ---- *)
PROCEDURE TryPercentDirective(): BOOLEAN;
  VAR kw, name, val: ARRAY 128 OF CHAR;
BEGIN
  RawTokNext;   (* consume '%' *)
  IF tSym # Scan.TIdent THEN Fail("expected directive name after '%'"); RETURN TRUE END;
  Strings.Copy(tId, kw); RawTokNext;
  IF Strings.Equal(kw, "DEFINE") THEN
    IF tSym # Scan.TIdent THEN Fail("expected name after %define"); RETURN TRUE END;
    Strings.Copy(tId, name); RawTokNext;
    val[0] := 0X;
    WHILE (tSym # Scan.TEol) & (tSym # Scan.TEof) DO
      IF ~TokToText(val, "%define body") THEN RETURN TRUE END;
      RawTokNext
    END;
    (* %define/%undef must NOT take effect when the current %ifdef/%else
       branch is being skipped -- unlike %ifdef/%else/%endif themselves
       (which must always run to track nesting), a %define inside a false
       branch is dead code and must not overwrite an outer definition.
       Verified against SYSTEM.RDF: "%else / %define RSIZE 2 / %endif" (the
       untaken branch, since IS_FAR is defined) was clobbering RSIZE's
       real value of 4 with 2, corrupting every later [bp+RSIZE+n]
       reference -- the tokens must still be consumed above (to keep the
       scanner in sync) even while skipped, just not stored. *)
    IF ~CurrentlySkipping() THEN Sym.Define(name, val) END;
    RETURN TRUE
  ELSIF Strings.Equal(kw, "UNDEF") THEN
    IF tSym # Scan.TIdent THEN Fail("expected name after %undef"); RETURN TRUE END;
    IF ~CurrentlySkipping() THEN Sym.Undef(tId) END;
    RawTokNext;
    (* paper cut fix: mirror %include's own trailing-EOL check -- trailing
       junk after the name used to be silently mis-parsed as a new
       statement ("unknown directive or mnemonic") instead of naming the
       real problem. *)
    IF (tSym # Scan.TEol) & (tSym # Scan.TEof) THEN
      Fail("unexpected text after %undef name"); RETURN TRUE
    END;
    RETURN TRUE
  ELSIF Strings.Equal(kw, "IFDEF") THEN
    DoIfdef; RETURN TRUE
  ELSIF Strings.Equal(kw, "ELSE") THEN
    DoElse; RETURN TRUE
  ELSIF Strings.Equal(kw, "ENDIF") THEN
    DoEndif; RETURN TRUE
  ELSIF Strings.Equal(kw, "INCLUDE") THEN
    DoInclude; RETURN TRUE
  ELSIF Strings.Equal(kw, "MACRO") THEN
    DoMacroRecord; RETURN TRUE
  ELSIF Strings.Equal(kw, "ENDMACRO") THEN
    (* %endmacro is only ever consumed internally by DoMacroRecord's raw-
       line scan (IsEndmacroLine) -- reaching this dispatch means it
       appeared with no matching %macro at all. *)
    Fail("%endmacro without %macro"); RETURN TRUE
  ELSE
    Fail("unknown % directive"); RETURN TRUE
  END
END TryPercentDirective;

(* IsDataDirectiveNext: TRUE if the CURRENT token (tSym/tId, already
   advanced past a just-consumed leading identifier) is one of the data
   directive keywords DB/DW/TIMES -- used to detect a colon-less implicit
   label immediately followed by a data declaration. *)
PROCEDURE IsDataDirectiveNext(): BOOLEAN;
  VAR d: INTEGER;
BEGIN
  IF tSym # Scan.TIdent THEN RETURN FALSE END;
  d := Lex.LookupDirective(tId);
  RETURN (d = Lex.DDb) OR (d = Lex.DDw) OR (d = Lex.DTimes)
END IsDataDirectiveNext;

(* ParseInstruction: mnemId already resolved via Lex.LookupMnem; parse
   0..3 comma-separated operands, then hand off to Enc.Encode.  Enc's own
   pass gating (see ENC.MOD SetContext/B/W) means calling Encode
   identically in both passes is exactly what keeps Pass 1's byte count
   and Pass 2's real emission from ever drifting apart.  `prefixByte` (0 =
   none) is a LOCK/REP* prefix ParseLine already consumed as a separate
   leading token on this same source line. *)
PROCEDURE ParseInstruction(mnemId: INTEGER; prefixByte: BYTE);
  VAR ops: ARRAY Enc.MaxOperands OF Enc.Operand; n: INTEGER; more: BOOLEAN;
      fn: ARRAY 128 OF CHAR;
BEGIN
  n := 0; more := (tSym # Scan.TEol) & (tSym # Scan.TEof);
  WHILE more & (n < Enc.MaxOperands) DO
    ParseOperand(ops[n], Enc.SzNone);
    INC(n);
    IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
  END;
  IF more THEN Fail("too many operands"); RETURN END;
  CurFname(fn);
  Enc.SetContext(fn, tLine, curPass, codeOfs);
  Enc.Encode(mnemId, ops, n, prefixByte);
  codeOfs := codeOfs + Enc.Emitted();
  IF Enc.Failed() THEN anyErr := TRUE END
END ParseInstruction;

(* ParseLine: one full logical source line.  Grammar:
     [ label ':' ]* ( directive | instruction )?  EOL
   A label may be followed directly by a directive/instruction on the same
   line (both oracle files do this frequently, e.g. "i87msg: db '...'" and
   "SYSTEM_Halt:" alone on its own line before the body starts on the next
   line).  Inside a STRUC..ENDSTRUC block, every non-empty line is a field
   declaration (".field RESB/RESW/RESD n") handled by ParseStrucField
   instead -- STRUC field names are never colon-terminated labels. *)
(* ParseStrucLine: job 3 of ParseLine's original five (E5 fix) -- handles
   one source line while inside a STRUC/ENDSTRUC block, where every line
   is either a ".field RESB/RESW/RESD n" declaration or the closing
   ENDSTRUC keyword; ordinary label/mnemonic dispatch does not apply. *)
PROCEDURE ParseStrucLine;
  VAR nameOrig: ARRAY Scan.MaxIdent OF CHAR; fn: ARRAY 128 OF CHAR;
BEGIN
  (* Field names are written ".fieldname" (e.g. "._AX resw 1"); Scan now
     always yields a standalone TDot before the identifier (see SCAN.MOD's
     Next -- the dot is never merged into the following identifier). *)
  IF tSym = Scan.TDot THEN
    TokNext;
    IF tSym # Scan.TIdent THEN Fail("expected field name after '.'"); RETURN END;
    (* Field key reconstruction in Dir.TryResolveField is
       "structName + '.' + field" -- store the field name WITHOUT the
       leading dot (the dot that introduced it in source, ".field", is
       punctuation, not part of the name) so a later "STRUCT.field"
       lookup (also structName + "." + field, no double dot) matches. *)
    Strings.Copy(tIdOrig, nameOrig); TokNext;
    ParseStrucField(nameOrig)
  ELSIF tSym = Scan.TIdent THEN
    IF Lex.LookupDirective(tId) = Lex.DEndstruc THEN
      TokNext; CurFname(fn); Dir.EndStruc(fn, tLine)
    ELSE
      Strings.Copy(tIdOrig, nameOrig); TokNext;
      ParseStrucField(nameOrig)
    END
  ELSE
    Fail("expected field name in STRUC")
  END
END ParseStrucLine;

(* AppendChecked: Strings.Append silently truncates past dst's buffer --
   this wraps it with the explicit overflow check §I.0's "no silent
   truncation" rule requires (same shape as TokToText's own guard).
   Returns FALSE (with Fail already called) if s would not fit. *)
PROCEDURE AppendChecked(s: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR; errMsg: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Strings.Length(dst) + Strings.Length(s) >= LEN(dst) THEN
    Fail(errMsg); RETURN FALSE
  END;
  Strings.Append(s, dst);
  RETURN TRUE
END AppendChecked;

(* InvokeMacro: §I.4 -- expand a %macro invocation. name is already
   uppercased and confirmed to be a known macro by the caller.
   1. Parse actuals: comma-separated raw token runs up to EOL, each
      re-serialized to text via the shared TokToText (same serializer
      %define bodies use -- B5/E3 lesson: one copy, not two divergent
      ones). Count mismatch vs the macro's own nParams is fatal.
   2. Build the expansion: copy the body, replacing %n (n=1..9, n<=
      nParams) with the argument text, and %%ident with ?Mk?ident (k =
      a per-invocation counter that advances identically in both passes
      -- see macroLocalCounter's own comment). Uses Strings.Pos (single-
      char pattern "%", dispatches to SYSTEM.FINDBYTE internally) to
      find each substitution site and Strings.Extract to pull out the
      literal run before it, rather than a manual char-by-char scan.
   3. Push the expansion as a memory source on the I.3 stack
      (isFile=FALSE, Scan.InitMem) and return -- ParseLine's caller
      continues the parse loop, so the macro's first expanded line is
      simply the next token read. *)
PROCEDURE InvokeMacro(name: ARRAY OF CHAR);
  VAR nParams: INTEGER; body: Scan.MemText;
      args: ARRAY 9 OF ARRAY 128 OF CHAR;
      nArgs: INTEGER;
      expBuf: ARRAY 4096 OF CHAR;
      literalBuf: ARRAY 128 OF CHAR;
      localTag: ARRAY 16 OF CHAR;
      expansion: Scan.MemText;
      fn: ARRAY 128 OF CHAR;
      bodyLen, runStart, argNum: INTEGER;
      pctPos: WORD;
      afterPct: CHAR;
      more: BOOLEAN;
BEGIN
  IF ~Sym.GetMacro(name, nParams, body) THEN RETURN END;   (* caller already checked IsMacro *)
  nArgs := 0;
  IF (tSym # Scan.TEol) & (tSym # Scan.TEof) THEN
    args[0][0] := 0X;
    IF nParams = 0 THEN Fail("macro argument count mismatch"); RETURN END;
    WHILE (tSym # Scan.TEol) & (tSym # Scan.TEof) & (tSym # Scan.TComma) DO
      IF ~TokToText(args[nArgs], "macro argument") THEN RETURN END;
      TokNext
    END;
    INC(nArgs);
    WHILE tSym = Scan.TComma DO
      TokNext;
      IF nArgs >= LEN(args) THEN Fail("too many macro arguments"); RETURN END;
      args[nArgs][0] := 0X;
      WHILE (tSym # Scan.TEol) & (tSym # Scan.TEof) & (tSym # Scan.TComma) DO
        IF ~TokToText(args[nArgs], "macro argument") THEN RETURN END;
        TokNext
      END;
      INC(nArgs)
    END
  END;
  IF nArgs # nParams THEN Fail("macro argument count mismatch"); RETURN END;

  Strings.Copy("?M", localTag);
  Strings.AppendInt(macroLocalCounter, localTag);
  Strings.Append("?", localTag);
  INC(macroLocalCounter);

  (* Body-scan: Strings.Pos's `pos` parameter is both the search-start
     offset (input) and the match offset (output, on success) -- set it
     to runStart before each call, which is exactly the "search forward
     from here" semantics this loop needs. Each iteration: find the next
     '%' at or after runStart, Extract the literal run strictly before
     it and append that run verbatim, then classify the ONE character
     after '%' -- a digit 1-9 is a %n parameter substitution, a second
     '%' is a %%local substitution; runStart advances past the 2-char
     sequence either way. Once no more '%' is found, the final literal
     tail (including a trailing lone '%' with nothing useful after it,
     copied through as-is) is appended and the loop ends. *)
  bodyLen := Strings.Length(body^.buf);
  expBuf[0] := 0X;
  runStart := 0;
  more := TRUE;
  WHILE more DO
    pctPos := WORD(runStart);
    IF ~Strings.Pos("%", body^.buf, pctPos) THEN
      Strings.Extract(body^.buf, runStart, bodyLen - runStart, literalBuf);
      IF ~AppendChecked(literalBuf, expBuf, "macro expansion too long") THEN RETURN END;
      more := FALSE
    ELSE
      Strings.Extract(body^.buf, runStart, INTEGER(pctPos) - runStart, literalBuf);
      IF ~AppendChecked(literalBuf, expBuf, "macro expansion too long") THEN RETURN END;
      IF INTEGER(pctPos) + 1 >= bodyLen THEN
        (* trailing lone '%' at the very end of the body -- copy it
           through literally rather than reading a nonexistent next
           char. *)
        IF ~AppendChecked("%", expBuf, "macro expansion too long") THEN RETURN END;
        more := FALSE
      ELSE
        Strings.Extract(body^.buf, INTEGER(pctPos) + 1, 1, literalBuf);
        afterPct := literalBuf[0];
        IF (afterPct >= "1") & (afterPct <= "9") THEN
          argNum := ORD(afterPct) - ORD("0");
          IF argNum > nParams THEN Fail("macro parameter %n beyond nParams"); RETURN END;
          IF ~AppendChecked(args[argNum-1], expBuf, "macro expansion too long") THEN RETURN END;
          runStart := INTEGER(pctPos) + 2
        ELSIF afterPct = "%" THEN
          IF ~AppendChecked(localTag, expBuf, "macro expansion too long") THEN RETURN END;
          runStart := INTEGER(pctPos) + 2
        ELSE
          (* '%' followed by something not 1-9 or '%' -- not a
             recognized substitution in this body; copy the '%' through
             literally and resume scanning right after it (matches how
             an ordinary '%' inside macro body TEXT, as opposed to a
             %define/%macro line, is just a character here -- macro
             bodies are raw captured text, never re-run through the
             %-directive dispatcher). *)
          IF ~AppendChecked("%", expBuf, "macro expansion too long") THEN RETURN END;
          runStart := INTEGER(pctPos) + 1
        END
      END
    END
  END;

  IF srcTop = MaxSrcDepth - 1 THEN Fail("macro expansion nested too deep"); RETURN END;
  NEW(expansion);
  IF expansion = NIL THEN Fail("out of memory (macro expansion)"); RETURN END;
  SYSTEM.MOVE(expBuf[0], expansion^.buf[0], Strings.Length(expBuf));
  expansion^.buf[Strings.Length(expBuf)] := 0X;
  (* CurFname BEFORE the push -- same ordering fix as TokNext's %define
     push: after INC(srcTop) it reads the new slot's stale/blank fname,
     which made every diagnostic inside a macro body report an empty
     filename (this was also the real cause of the "blank filename at
     the depth-cap edge" gap documented after the §I.4 pass). *)
  CurFname(fn);
  INC(srcTop);
  stk[srcTop].isFile := FALSE; stk[srcTop].isDefine := FALSE;
  Scan.InitMem(stk[srcTop].scn, expansion, fn, tLine)
END InvokeMacro;

(* ParseStatement: job 5 of ParseLine's original five (E5 fix) -- the
   actual statement dispatch once the label-consuming loop in ParseLine
   has determined `name`/`nameOrig`/`mnemId` (the first non-label token on
   the line, already consumed, token stream positioned just past it) is
   NOT itself a colon-terminated label. Handles LOCK/REP* and segment-
   override leading prefixes, the colon-less-label-before-DB/DW/TIMES
   form, and plain directive/mnemonic dispatch. Always returns to
   ParseLine's caller (every path here consumes the rest of the
   statement); extracted verbatim from ParseLine's final ELSIF chain --
   no control-flow change, just named and separated from the label loop
   it used to share a body with. *)
PROCEDURE ParseStatement(name, nameOrig: ARRAY OF CHAR; mnemId: INTEGER);
  VAR prefixId: INTEGER;
BEGIN
  IF (mnemId = Lex.LNone) & IsDataDirectiveNext() THEN
    (* NASM allows a colon-less label immediately followed by a data
       directive on the same line, e.g. "MemStartSeg  dw 0" -- `name`
       (already consumed) is that implicit label; `tSym` is now
       positioned at DB/DW/TIMES itself. Only recognized for the data-
       directive keywords (not general directives/mnemonics), matching
       the one real occurrence in SYSTEM.ASM/EMS.ASM -- a colon-less
       label before an instruction or SECTION/GLOBAL/etc. does not occur
       in either oracle file, so is intentionally not supported
       (Simplicity First). *)
    DefineCurLabel(nameOrig);
    Strings.Copy(tId, name); TokNext;
    IF ~TryDirective(name) THEN Fail("unknown directive or mnemonic") END
  ELSIF Lex.IsPrefixMnem(mnemId) THEN
    (* LOCK/REP* leading token: not a label, not itself an instruction --
       stash its prefix byte and re-read the NEXT identifier as the real
       mnemonic (e.g. "rep movsb"; label-before-prefix, "L: rep movsb",
       is handled naturally since ParseStatement is only reached after
       the label-consuming iterations in ParseLine already ran). *)
    prefixId := mnemId;
    IF tSym # Scan.TIdent THEN
      Fail("expected instruction mnemonic after LOCK/REP prefix"); RETURN
    END;
    Strings.Copy(tId, name); TokNext;
    mnemId := Lex.LookupMnem(name);
    IF mnemId = Lex.LNone THEN
      Fail("unknown mnemonic after LOCK/REP prefix"); RETURN
    END;
    ParseInstruction(mnemId, Enc.PrefixByteFor(prefixId))
  ELSIF (mnemId = Lex.LNone) & IsSegRegPrefixNext(name) THEN
    (* D fix: "es stosb"-style leading segment-register override -- same
       shape as the LOCK/REP* prefix branch above, but the token is a
       segment-register name (not a Lex.M* prefix id), only valid
       directly before a string-op mnemonic (STOSB/MOVSB/... take no
       explicit memory operand to carry a `[es:...]` override, so that's
       the only way NASM lets one apply here). *)
    IF tSym # Scan.TIdent THEN
      Fail("expected string-op mnemonic after segment override"); RETURN
    END;
    prefixId := SegRegPrefixByteFor(name);
    Strings.Copy(tId, name); TokNext;
    mnemId := Lex.LookupMnem(name);
    IF mnemId = Lex.LNone THEN
      Fail("unknown mnemonic after segment override"); RETURN
    END;
    ParseInstruction(mnemId, BYTE(prefixId))
  ELSE
    (* not a label: `name` (already consumed, token stream positioned
       just past it) is a directive keyword, an instruction mnemonic, or
       (§I.4) a %macro invocation -- checked LAST, only once label
       handling, TryDirective, and Lex.LookupMnem all miss, so a %macro
       can never shadow a real mnemonic or directive. *)
    IF TryDirective(name) THEN
      (* handled *)
    ELSIF mnemId # Lex.LNone THEN
      ParseInstruction(mnemId, BYTE(0))
    ELSIF Sym.IsMacro(name) THEN
      InvokeMacro(name)
    ELSE
      Fail("unknown directive or mnemonic")
    END
  END
END ParseStatement;

PROCEDURE ParseLine;
  VAR name: ARRAY Scan.MaxIdent OF CHAR; nameOrig: ARRAY Scan.MaxIdent OF CHAR;
      more: BOOLEAN; mnemId: INTEGER;
BEGIN
  IF tSym = Scan.TEol THEN RETURN END;
  IF tSym = Scan.TPercent THEN
    IF TryPercentDirective() THEN RETURN END
  END;
  IF CurrentlySkipping() THEN SkipToEol; RETURN END;

  IF Dir.InStruc() THEN ParseStrucLine; RETURN END;

  (* consume zero or more "IDENT :" or ".IDENT :" (local) labels, then
     dispatch the statement itself via ParseStatement (E5 fix: this loop
     is job 4, label-consuming, of ParseLine's original five; the
     dispatch it used to inline is now ParseStatement, job 5). *)
  more := TRUE;
  WHILE more & ((tSym = Scan.TIdent) OR (tSym = Scan.TDot)) DO
    IF tSym = Scan.TDot THEN
      TokNext;
      IF tSym # Scan.TIdent THEN Fail("expected identifier after '.'"); RETURN END;
      nameOrig[0] := "."; nameOrig[1] := 0X; Strings.Append(tIdOrig, nameOrig);
      name[0] := "."; name[1] := 0X; Strings.Append(tId, name)
    ELSE
      Strings.Copy(tId, name); Strings.Copy(tIdOrig, nameOrig)
    END;
    TokNext;
    mnemId := Lex.LookupMnem(name);
    IF tSym = Scan.TColon THEN
      TokNext;
      DefineCurLabel(nameOrig)
    ELSE
      more := FALSE;
      ParseStatement(name, nameOrig, mnemId);
      RETURN
    END
  END
  (* loop exits here only when every token on the line was a colon-
     terminated label and the line has nothing else (or EOL/EOF) -- a bare
     label line, nothing further to dispatch. *)
END ParseLine;

(* RunPass: assemble the whole file once (one Pass).  Resets the scanner
   and the running code/data offsets, but NOT the Sym label table (Pass 2
   needs Pass 1's label offsets still present to resolve forward refs; new
   DefineLabel calls in Pass 2 just re-confirm the same values, see Sym.MOD's
   "Pass 2 redefinition with an identical value: expected, ignore" case).
   %define/%undef DO need to replay identically in both passes (their
   ORDER relative to label definitions matters for text substitution), so
   Sym's define-table is NOT reset either -- it simply accumulates the
   exact same Define/Undef calls again, which are idempotent. *)
(* CloseAllSources: close every open file on the stack (top level +
   any still-pushed %include levels) and reset it to empty. Called on
   every early-exit path out of Assemble/RunPass (§I.3's "files closed
   on all paths" rule) and at the start of each RunPass (the stack from
   the PREVIOUS pass, if any, must not leak into the next one). A
   memory-source slot (isFile=FALSE, §I.4) has no file to close. *)
PROCEDURE CloseAllSources;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE i <= srcTop DO
    IF stk[i].isFile THEN Files.Close(stk[i].f)
    ELSE DISPOSE(stk[i].scn.mem) END;   (* N1 fix: %macro expansion buffer *)
    INC(i)
  END;
  srcTop := -1
END CloseAllSources;

(* RunPass: assemble the whole source tree once (one Pass), starting by
   opening srcPath fresh as stk[0] -- %include (§I.3) pushes further
   slots during the walk; RawTokNext pops back to the parent
   transparently on each pushed slot's EOF, so this loop only ever sees
   the outermost TEof once the WHOLE tree (not just the top-level file)
   is exhausted. *)
PROCEDURE RunPass(passNo: INTEGER; srcPath: ARRAY OF CHAR; VAR ok: BOOLEAN);
  VAR beforeCount: LONGINT;
BEGIN
  ok := TRUE;
  CloseAllSources;
  srcTop := 0;
  stk[0].isFile := TRUE; stk[0].isDefine := FALSE;
  IF ~Files.Reset(stk[0].f, srcPath) THEN
    LogErr.Error2("tasm: cannot open ", srcPath); srcTop := -1; ok := FALSE; RETURN
  END;
  Scan.Init(stk[0].scn, stk[0].f, srcPath);
  curPass := passNo;
  curSeg := Sym.SegCode;
  codeOfs := LONGINT(0); dataOfs := LONGINT(0); bssOfs := LONGINT(0);
  ifDepth := 0; tokCount := LONGINT(0); macroLocalCounter := LONGINT(0);
  IF passNo = 1 THEN Enc.ResetJmpDecisions ELSE Enc.ResetJmpReplay END;
  TokNext;
  WHILE (tSym # Scan.TEof) & ~LogErr.HaveErr() & ~anyErr DO
    beforeCount := tokCount;
    ParseLine;
    IF tSym = Scan.TEol THEN TokNext
    ELSIF tokCount = beforeCount THEN
      (* ParseLine consumed nothing and left a token that is neither TEol
         nor TEof (BUG A2): a stray operator/number/bracket at the start of
         a statement, or trailing junk ParseInstruction didn't consume --
         without this, the loop re-enters ParseLine on the identical token
         forever. *)
      Fail("unexpected token at start of statement"); SkipToEol;
      IF tSym = Scan.TEol THEN TokNext END
    END
  END;
  (* EOF reached with an %ifdef still open: without this check, a missing
     %endif is a silent no-op -- everything inside the never-closed block
     (taken or skipped) either gets assembled or dropped based on whatever
     %ifdef condition was last true, with no diagnostic either way, since
     SkipToEndifOrElse only ever fires on an explicit %else/%endif token
     that never arrives.  Caught here rather than at each %ifdef site so
     it applies uniformly regardless of nesting depth. *)
  IF (tSym = Scan.TEof) & (ifDepth > 0) & ~LogErr.HaveErr() & ~anyErr THEN
    Fail("%ifdef without matching %endif")
  END;
  CloseAllSources
END RunPass;

(* EmitGlobal: Sym.GlobalVisitProc callback, invoked once per GLOBAL-marked
   label after Pass 2 finishes -- writes the RDFREC_GLOBAL record.  Must be
   FAR: it is passed as a procedure VALUE to Sym.EnumGlobals (see
   SRC/TOOLS/TOSTRIP.MOD's OnMember comment on why callback procs are FAR
   in this codebase -- Link.mod's OnGlobal note). *)
PROCEDURE EmitGlobal(name: ARRAY OF CHAR; seg: INTEGER; offset: LONGINT); FAR;
BEGIN
  IF seg = Sym.SegCode THEN
    Rdoff.RdfAddGlobal(obj, name, BYTE(Rdoff.SegCode), offset)
  ELSIF seg = Sym.SegData THEN
    Rdoff.RdfAddGlobal(obj, name, BYTE(Rdoff.SegData), offset)
  ELSE
    Rdoff.RdfAddGlobal(obj, name, BYTE(Rdoff.SegBss), offset)
  END
END EmitGlobal;

(* Assemble: top-level entry point.  Opens srcPath, runs Pass 1 (sizes
   every instruction and fixes every label's final offset) then Pass 2
   (emits real bytes + relocations into `outObj`, which the caller
   (TASM.MOD) must have already RdfInit'd).  Returns TRUE on success (no
   LogErr errors latched during either pass).
   NOT re-entrant / not safe to call twice concurrently for different
   files (E10, code-smell audit): the scanner state, current token,
   %ifdef nesting, current section, and code/data/bss offsets are all
   module-level VARs in this module (and in Enc.MOD's mirrored pass/here/
   jmp-decision state), reset at the top of each RunPass rather than
   threaded through an explicit context record. Fine for TASM.MOD's own
   one-file-per-process CLI driver; a future TOC-style batch driver that
   wants to assemble multiple files in one process must call Assemble to
   completion (or hold a lock) before starting the next one, not
   interleave/parallelize calls. *)
PROCEDURE Assemble*(srcPath: ARRAY OF CHAR; outObj: Rdoff.ObjFile): BOOLEAN;
  VAR undefName: ARRAY Sym.MaxName OF CHAR; ok: BOOLEAN;
BEGIN
  srcTop := -1;
  obj := outObj;
  Enc.SetObj(outObj);
  anyErr := FALSE;
  Sym.Init; Dir.Init;
  ApplyPredefs;

  RunPass(1, srcPath, ok);
  IF ~ok THEN Sym.Free; Enc.FreeJmpDecisions; RETURN FALSE END;
  IF anyErr OR LogErr.HaveErr() THEN Sym.Free; Enc.FreeJmpDecisions; RETURN FALSE END;

  IF Sym.CheckAllDefined(undefName) THEN
    LogErr.Error2("tasm: undefined symbol ", undefName);
    Sym.Free; Enc.FreeJmpDecisions; RETURN FALSE
  END;

  RunPass(2, srcPath, ok);
  IF ~ok THEN Sym.Free; Enc.FreeJmpDecisions; RETURN FALSE END;
  IF anyErr OR LogErr.HaveErr() THEN Sym.Free; Enc.FreeJmpDecisions; RETURN FALSE END;

  IF bssOfs > LONGINT(0) THEN Rdoff.RdfSetBss(obj, bssOfs) END;
  Sym.EnumGlobals(EmitGlobal);
  Sym.Free;
  Enc.FreeJmpDecisions;
  RETURN ~(anyErr OR LogErr.HaveErr())
END Assemble;

END Parse.
