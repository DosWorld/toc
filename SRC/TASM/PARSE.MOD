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
  DOCS/TASM_PLAN.MD scoped for v1 (no parameterized macros).

  %ifdef/%else/%endif are handled at the raw-line level (SkipToEndifOrElse)
  before any %define expansion of that line's tokens, matching the "skip
  branches wholesale" scope call in DOCS/TASM_PLAN.MD.

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
  MaxLine    = 256;
  MacroDepth = 4;     (* nested macro-token pushback buffers *)

TYPE
  (* One pending macro-substitution being re-lexed as a private byte
     buffer + cursor (macro bodies are single-line text -- no file I/O). *)
  MacroBuf = RECORD
    text: ARRAY 256 OF CHAR;
    pos:  INTEGER
  END;

VAR
  s:         Scan.Scanner;
  fname:     ARRAY 128 OF CHAR;
  obj:       Rdoff.ObjFile;

  (* macro pushback stack *)
  mbuf:      ARRAY MacroDepth OF MacroBuf;
  mtop:      INTEGER;            (* -1 = no macro active, else index into mbuf *)

  (* current token, after macro expansion -- callers read these instead of
     touching s.* directly once tokenizing has started *)
  tSym:      INTEGER;
  tId:       ARRAY Scan.MaxIdent OF CHAR;
  tIdOrig:   ARRAY Scan.MaxIdent OF CHAR;
  tIval:     LONGINT;
  tSval:     ARRAY Scan.MaxStr OF CHAR;
  tLine:     LONGINT;

  curPass:   INTEGER;
  curSeg:    INTEGER;             (* Sym.SegCode / Sym.SegData -- current SECTION *)
  codeOfs:   LONGINT;             (* running code offset, both passes (Pass 2 mirrors Rdoff.CodeLen) *)
  dataOfs:   LONGINT;
  anyErr:    BOOLEAN;

PROCEDURE Fail(msg: ARRAY OF CHAR);
BEGIN LogErr.ErrorInFile(fname, tLine, msg); anyErr := TRUE
END Fail;

(* ---- token stream with %define expansion ---- *)

(* RawNext: pull the next token either from an active macro pushback
   buffer (mbuf[mtop]) or, if none is active/exhausted, from the real file
   scanner s.  A macro buffer holding only whitespace-separated identifiers
   /numbers/punctuation is re-lexed by a tiny ad-hoc scan (macro bodies in
   both oracle files are short: bare constants, mnemonic aliases, or one
   bracketed memory expression -- never multi-line). *)
PROCEDURE McSkipBlanks(VAR m: MacroBuf);
BEGIN WHILE (m.text[m.pos] = " ") OR (ORD(m.text[m.pos]) = 9) DO INC(m.pos) END
END McSkipBlanks;

(* MacroAtEnd: TRUE if the active macro buffer has nothing but trailing
   whitespace left.  Must skip blanks before testing for the 0X terminator
   -- %define bodies are built with a trailing " " after every token (see
   TryPercentDirective's DEFINE loop), so the raw text almost always ends
   in a space, not immediately 0X; without the skip here, PopMacroIfDone
   would fail to recognize the buffer as exhausted one call early, and
   McNextTok would return a spurious TEof for what should have been a
   transparent pop back to the real token stream (e.g. "[bp+RSIZE+2]" with
   RSIZE="4 " would see TEof right after the 4, truncating the "+2]" that
   follows in the real source). *)
PROCEDURE MacroAtEnd(): BOOLEAN;
BEGIN
  IF mtop < 0 THEN RETURN FALSE END;
  McSkipBlanks(mbuf[mtop]);
  RETURN mbuf[mtop].text[mbuf[mtop].pos] = 0X
END MacroAtEnd;

PROCEDURE PopMacroIfDone;
BEGIN
  WHILE MacroAtEnd() DO DEC(mtop) END
END PopMacroIfDone;

PROCEDURE IsIdStart(c: CHAR): BOOLEAN;
BEGIN
  RETURN ((c >= "A") & (c <= "Z")) OR ((c >= "a") & (c <= "z")) OR (c = "_")
         OR (c = ".") OR (c = "$") OR (c = "?") OR (c = "@")
END IsIdStart;

PROCEDURE IsIdChar(c: CHAR): BOOLEAN;
BEGIN RETURN IsIdStart(c) OR SYSTEM.ISDIGIT(c)
END IsIdChar;

(* McNextTok: lex one token from a MacroBuf using the same T* sym space as
   Scan.  Numbers here are plain decimal or 0x../h-suffixed hex (matches
   what %define bodies in the two oracle files actually contain: small
   integers and one bracketed address expression). *)
PROCEDURE McNextTok(VAR m: MacroBuf; VAR sym: INTEGER; VAR id, idOrig: ARRAY OF CHAR; VAR ival: LONGINT);
  VAR i: INTEGER; c: CHAR; buf: ARRAY 32 OF CHAR; isHex: BOOLEAN;
BEGIN
  McSkipBlanks(m);
  c := m.text[m.pos];
  IF c = 0X THEN sym := Scan.TEof; RETURN END;
  IF IsIdStart(c) THEN
    i := 0;
    WHILE IsIdChar(m.text[m.pos]) DO
      IF i < LEN(id) - 1 THEN idOrig[i] := m.text[m.pos]; id[i] := SYSTEM.UCASE(m.text[m.pos]); INC(i) END;
      INC(m.pos)
    END;
    idOrig[i] := 0X; id[i] := 0X; sym := Scan.TIdent
  ELSIF SYSTEM.ISDIGIT(c) THEN
    i := 0;
    WHILE IsIdChar(m.text[m.pos]) DO   (* IsIdChar also matches hex letters/digits/x *)
      IF i < LEN(buf) - 1 THEN buf[i] := m.text[m.pos]; INC(i) END;
      INC(m.pos)
    END;
    buf[i] := 0X;
    isHex := (i >= 2) & (buf[0] = "0") & ((buf[1] = "x") OR (buf[1] = "X"));
    ival := LONGINT(0);
    IF isHex THEN
      i := 2;
      WHILE buf[i] # 0X DO
        ival := ival * 16;
        IF (buf[i] >= "0") & (buf[i] <= "9") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("0"))
        ELSIF (buf[i] >= "A") & (buf[i] <= "F") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("A") + 10)
        ELSIF (buf[i] >= "a") & (buf[i] <= "f") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("a") + 10)
        END;
        INC(i)
      END
    ELSIF (i >= 1) & ((buf[i-1] = "h") OR (buf[i-1] = "H")) THEN
      i := 0;
      WHILE buf[i+1] # 0X DO
        ival := ival * 16;
        IF (buf[i] >= "0") & (buf[i] <= "9") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("0"))
        ELSIF (buf[i] >= "A") & (buf[i] <= "F") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("A") + 10)
        ELSIF (buf[i] >= "a") & (buf[i] <= "f") THEN ival := ival + LONGINT(ORD(buf[i]) - ORD("a") + 10)
        END;
        INC(i)
      END
    ELSE
      i := 0;
      WHILE buf[i] # 0X DO
        ival := ival * 10 + LONGINT(ORD(buf[i]) - ORD("0")); INC(i)
      END
    END;
    sym := Scan.TInt
  ELSIF c = ":" THEN INC(m.pos); sym := Scan.TColon
  ELSIF c = "[" THEN INC(m.pos); sym := Scan.TLbrak
  ELSIF c = "]" THEN INC(m.pos); sym := Scan.TRbrak
  ELSIF c = "+" THEN INC(m.pos); sym := Scan.TPlus
  ELSIF c = "-" THEN INC(m.pos); sym := Scan.TMinus
  ELSIF c = "," THEN INC(m.pos); sym := Scan.TComma
  ELSE INC(m.pos); sym := Scan.TError
  END
END McNextTok;

(* TokNext: the token source every parser procedure below calls.  Expands
   %define macros transparently: if the raw next token is an identifier
   matching a Sym macro, push its substitution text as a new MacroBuf and
   pull the first token from there instead (recursively -- a macro body
   naming another macro is re-checked once the pushed buffer starts
   yielding, since McNextTok's identifiers go through the same
   Sym.Expand check below). *)
(* RawTokNext: fetch the next token with NO %define expansion.  Used only
   for the identifier immediately following %define/%undef/%ifdef: that
   name is being declared or tested, not used as a value, so it must never
   itself be macro-expanded -- e.g. "%define IS_FAR" (empty-bodied, used
   purely as an %ifdef flag in SYS.ASM/EMSAPI.ASM) followed later by
   "%ifdef IS_FAR" would otherwise have TokNext silently expand IS_FAR to
   its (empty) substitution before DoIfdef ever saw an identifier token,
   desyncing the whole token stream. *)
PROCEDURE RawTokNext;
BEGIN
  PopMacroIfDone;
  IF mtop >= 0 THEN
    McNextTok(mbuf[mtop], tSym, tId, tIdOrig, tIval);
    tLine := s.line
  ELSE
    Scan.Next(s);
    tSym := s.sym; tLine := s.tokLine; tIval := s.ival;
    Strings.Copy(s.id, tId); Strings.Copy(s.idOrig, tIdOrig); Strings.Copy(s.sval, tSval)
  END
END RawTokNext;

PROCEDURE TokNext;
  VAR sub: ARRAY 128 OF CHAR;
BEGIN
  RawTokNext;
  IF (tSym = Scan.TIdent) & Sym.Expand(tId, sub) THEN
    IF mtop < MacroDepth - 1 THEN
      INC(mtop);
      Strings.Copy(sub, mbuf[mtop].text);
      mbuf[mtop].pos := 0;
      TokNext; RETURN     (* re-enter: pull the macro's first real token *)
    ELSE
      Fail("macro expansion nested too deep")
    END
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

(* IsBaseIndexReg: TRUE if reg (a word register code) may appear inside
   [ ... ] as a base/index register (BX, BP, SI, DI only -- 8086 addressing
   has no other valid base/index registers). *)
PROCEDURE BaseIndexOf(reg: INTEGER): INTEGER;
BEGIN
  CASE reg OF
    Enc.RBX: RETURN 100
  | Enc.RBP: RETURN 101
  | Enc.RSI: RETURN 102
  | Enc.RDI: RETURN 103
  ELSE RETURN -1
  END
END BaseIndexOf;

(* CombineBaseIndex: given two base/index component codes (each one of the
   100..103 markers from BaseIndexOf, order-independent), pick the 8086
   Am* addressing-mode selector.  Only [BX+SI] [BX+DI] [BP+SI] [BP+DI] are
   legal two-register forms; anything else is a caller error. *)
PROCEDURE CombineBaseIndex(a, b: INTEGER; VAR am: INTEGER): BOOLEAN;
BEGIN
  IF ((a = 100) & (b = 102)) OR ((a = 102) & (b = 100)) THEN am := Enc.AmBxSi; RETURN TRUE END;
  IF ((a = 100) & (b = 103)) OR ((a = 103) & (b = 100)) THEN am := Enc.AmBxDi; RETURN TRUE END;
  IF ((a = 101) & (b = 102)) OR ((a = 102) & (b = 101)) THEN am := Enc.AmBpSi; RETURN TRUE END;
  IF ((a = 101) & (b = 103)) OR ((a = 103) & (b = 101)) THEN am := Enc.AmBpDi; RETURN TRUE END;
  RETURN FALSE
END CombineBaseIndex;

PROCEDURE SingleRegAm(marker: INTEGER; VAR am: INTEGER): BOOLEAN;
BEGIN
  CASE marker OF
    100: am := Enc.AmBx; RETURN TRUE
  | 101: am := Enc.AmDisp; RETURN TRUE   (* [BP] alone: Am selector reuses 6, mod forced to 01 by EmitModRm's disp=0 rule *)
  | 102: am := Enc.AmSi; RETURN TRUE
  | 103: am := Enc.AmDi; RETURN TRUE
  ELSE RETURN FALSE
  END
END SingleRegAm;

(* ---- operand parsing ----
   ParseMemBody parses the contents of [ ... ] (after the '[' has been
   consumed by the caller, up to but not including ']'), filling `op` as
   an OKMem operand.  Grammar actually needed (per DOCS/TASM_PLAN.MD's
   addressing-form audit): reg | reg+reg | reg+disp | reg+reg+disp | disp
   | label | label+disp -- disp may itself be a NAME.field struct-offset
   constant (resolved via Dir.TryResolveField) or a %define'd numeric
   token (already expanded by TokNext by the time we see it) or a bare
   label (data/code address, becomes hasLabel+labelName). *)
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
        IF ~haveReg THEN marker1 := BaseIndexOf(reg); haveReg := TRUE
        ELSE marker2 := BaseIndexOf(reg)
        END;
        TokNext
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
      Fail("label displacement combined with base register not supported"); RETURN
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
  op.size := sizeHint; op.isFar := FALSE; op.isSegOf := FALSE; op.isShort := FALSE;
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
       above: label names are never uppercased). *)
    TokNext;
    op.kind := Enc.OKImm; op.hasLabel := TRUE; Strings.Copy(nameOrig, op.labelName);
    op.disp := LONGINT(0);
    Sym.ReserveLabel(nameOrig);
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
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
    RETURN
  ELSIF tSym = Scan.TLbrak THEN
    TokNext; ParseMemBody(op);
    IF op.size = Enc.SzNone THEN op.size := Enc.SzWord END;
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
  VAR lseg: INTEGER; lofs: LONGINT; patchSeg: INTEGER; patchOfs: LONGINT;
BEGIN
  IF op.hasLabel & (curPass = 2) THEN
    IF ~Sym.Lookup(op.labelName, lseg, lofs) THEN Fail("undefined symbol") END;
    IF curSeg = Sym.SegCode THEN patchSeg := Rdoff.SegCode; patchOfs := codeOfs
    ELSE patchSeg := Rdoff.SegData; patchOfs := dataOfs
    END;
    IF lseg = Sym.SegCode THEN
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, Rdoff.SegCode, FALSE)
    ELSE
      Rdoff.RdfAddReloc(obj, patchSeg, patchOfs, 2, Rdoff.SegData, FALSE)
    END
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
        EmitDataByte(BYTE(-tIval)); TokNext
      ELSE
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
  Dir.AddField(field, szBytes, count, fname, tLine)
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
  cond := Sym.IsDefine(name);
  IF ifDepth < 16 THEN
    skipping[ifDepth] := CurrentlySkipping() OR ~cond;
    branchTrue[ifDepth] := cond;
    INC(ifDepth)
  ELSE
    Fail("%ifdef nested too deep")
  END
END DoIfdef;

PROCEDURE DoElse;
BEGIN
  IF ifDepth = 0 THEN Fail("%else without %ifdef"); RETURN END;
  IF ifDepth = 1 THEN skipping[0] := branchTrue[0]
  ELSE skipping[ifDepth-1] := skipping[ifDepth-2] OR branchTrue[ifDepth-1]
  END
END DoElse;

PROCEDURE DoEndif;
BEGIN
  IF ifDepth = 0 THEN Fail("%endif without %ifdef"); RETURN END;
  DEC(ifDepth)
END DoEndif;

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
    IF op.kind # Enc.OKImm THEN Fail("TIMES DB requires a constant value"); RETURN END;
    i := LONGINT(0);
    WHILE i < count DO EmitDataByte(BYTE(op.disp)); i := i + LONGINT(1) END
  ELSIF Strings.Equal(kw, "DW") THEN
    ParseOperand(op, Enc.SzWord);
    IF op.kind # Enc.OKImm THEN Fail("TIMES DW requires a constant value"); RETURN END;
    i := LONGINT(0);
    WHILE i < count DO EmitDataWord(INTEGER(op.disp)); i := i + LONGINT(1) END
  ELSE
    Fail("TIMES only supports DB/DW in this dialect")
  END
END DoTimes;

(* TryDirective: handles the directive named by `kw` (already scanned and
   uppercased, current token already advanced past it).  Returns TRUE if
   `kw` was recognized. *)
PROCEDURE TryDirective(kw: ARRAY OF CHAR): BOOLEAN;
  VAR strucName: ARRAY Sym.MaxName OF CHAR;
      more: BOOLEAN; d: INTEGER;
BEGIN
  d := Lex.LookupDirective(kw);
  CASE d OF
    Lex.DBits, Lex.DCpu:
      SkipToEol
  | Lex.DSection:
      IF tSym # Scan.TDot THEN Fail("expected .text/.data after SECTION")
      ELSE
        TokNext;
        IF tSym # Scan.TIdent THEN Fail("expected .text/.data after SECTION")
        ELSE
          IF Strings.Equal(tId, "TEXT") THEN curSeg := Sym.SegCode
          ELSIF Strings.Equal(tId, "DATA") THEN curSeg := Sym.SegData
          ELSE Fail("unknown section (want .text or .data)")
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
        Dir.BeginStruc(strucName, fname, tLine);
        TokNext
      END
  | Lex.DEndstruc:
      Dir.EndStruc(fname, tLine)
  | Lex.DDb:
      ParseDbList
  | Lex.DDw:
      ParseDwList
  | Lex.DTimes:
      IF tSym # Scan.TInt THEN Fail("expected repeat count after TIMES")
      ELSE DoTimes(tIval)
      END
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END TryDirective;

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
      IF tSym = Scan.TIdent THEN Strings.Append(tIdOrig, val)
      ELSIF tSym = Scan.TInt THEN Strings.AppendInt(tIval, val)
      ELSIF tSym = Scan.TColon THEN Strings.Append(":", val)
      ELSIF tSym = Scan.TLbrak THEN Strings.Append("[", val)
      ELSIF tSym = Scan.TRbrak THEN Strings.Append("]", val)
      ELSIF tSym = Scan.TPlus THEN Strings.Append("+", val)
      ELSIF tSym = Scan.TMinus THEN Strings.Append("-", val)
      ELSIF tSym = Scan.TComma THEN Strings.Append(",", val)
      END;
      Strings.Append(" ", val);
      RawTokNext
    END;
    (* %define/%undef must NOT take effect when the current %ifdef/%else
       branch is being skipped -- unlike %ifdef/%else/%endif themselves
       (which must always run to track nesting), a %define inside a false
       branch is dead code and must not overwrite an outer definition.
       Verified against SYS.RDF: "%else / %define RSIZE 2 / %endif" (the
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
    RETURN TRUE
  ELSIF Strings.Equal(kw, "IFDEF") THEN
    DoIfdef; RETURN TRUE
  ELSIF Strings.Equal(kw, "ELSE") THEN
    DoElse; RETURN TRUE
  ELSIF Strings.Equal(kw, "ENDIF") THEN
    DoEndif; RETURN TRUE
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
   and Pass 2's real emission from ever drifting apart. *)
PROCEDURE ParseInstruction(mnemId: INTEGER);
  VAR ops: ARRAY Enc.MaxOperands OF Enc.Operand; n: INTEGER; more: BOOLEAN;
BEGIN
  n := 0; more := (tSym # Scan.TEol) & (tSym # Scan.TEof);
  WHILE more & (n < Enc.MaxOperands) DO
    ParseOperand(ops[n], Enc.SzNone);
    INC(n);
    IF tSym = Scan.TComma THEN TokNext ELSE more := FALSE END
  END;
  Enc.SetContext(fname, tLine, curPass, codeOfs);
  Enc.Encode(mnemId, ops, n);
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
PROCEDURE ParseLine;
  VAR name: ARRAY Scan.MaxIdent OF CHAR; nameOrig: ARRAY Scan.MaxIdent OF CHAR;
      more: BOOLEAN; mnemId: INTEGER;
BEGIN
  IF tSym = Scan.TEol THEN RETURN END;
  IF tSym = Scan.TPercent THEN
    IF TryPercentDirective() THEN RETURN END
  END;
  IF CurrentlySkipping() THEN SkipToEol; RETURN END;

  IF Dir.InStruc() THEN
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
        TokNext; Dir.EndStruc(fname, tLine)
      ELSE
        Strings.Copy(tIdOrig, nameOrig); TokNext;
        ParseStrucField(nameOrig)
      END
    ELSE
      Fail("expected field name in STRUC")
    END;
    RETURN
  END;

  (* consume zero or more "IDENT :" or ".IDENT :" (local) labels *)
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
      IF curSeg = Sym.SegCode THEN
        Sym.DefineLabel(nameOrig, Sym.SegCode, codeOfs, FALSE, fname, tLine)
      ELSE
        Sym.DefineLabel(nameOrig, Sym.SegData, dataOfs, FALSE, fname, tLine)
      END
    ELSIF (mnemId = Lex.LNone) & IsDataDirectiveNext() THEN
      (* NASM allows a colon-less label immediately followed by a data
         directive on the same line, e.g. "MemStartSeg  dw 0" -- `name`
         (already consumed) is that implicit label; `tSym` is now
         positioned at DB/DW/TIMES itself. Only recognized for the data-
         directive keywords (not general directives/mnemonics), matching
         the one real occurrence in SYS.ASM/EMSAPI.ASM -- a colon-less
         label before an instruction or SECTION/GLOBAL/etc. does not occur
         in either oracle file, so is intentionally not supported
         (Simplicity First). *)
      more := FALSE;
      IF curSeg = Sym.SegCode THEN
        Sym.DefineLabel(nameOrig, Sym.SegCode, codeOfs, FALSE, fname, tLine)
      ELSE
        Sym.DefineLabel(nameOrig, Sym.SegData, dataOfs, FALSE, fname, tLine)
      END;
      Strings.Copy(tId, name); TokNext;
      IF ~TryDirective(name) THEN Fail("unknown directive or mnemonic") END;
      RETURN
    ELSE
      (* not a label: `name` (already consumed, token stream positioned
         just past it) is a directive keyword or an instruction mnemonic. *)
      more := FALSE;
      IF TryDirective(name) THEN
        (* handled *)
      ELSIF mnemId # Lex.LNone THEN
        ParseInstruction(mnemId)
      ELSE
        Fail("unknown directive or mnemonic")
      END;
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
PROCEDURE RunPass(passNo: INTEGER; VAR f2: Files.File);
BEGIN
  curPass := passNo;
  Scan.Init(s, f2, fname);
  curSeg := Sym.SegCode;
  codeOfs := LONGINT(0); dataOfs := LONGINT(0);
  mtop := -1; ifDepth := 0;
  IF passNo = 1 THEN Enc.ResetJmpDecisions ELSE Enc.ResetJmpReplay END;
  TokNext;
  WHILE (tSym # Scan.TEof) & ~LogErr.HaveErr() & ~anyErr DO
    ParseLine;
    IF tSym = Scan.TEol THEN TokNext END
  END
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
  ELSE
    Rdoff.RdfAddGlobal(obj, name, BYTE(Rdoff.SegData), offset)
  END
END EmitGlobal;

(* Assemble: top-level entry point.  Opens srcPath, runs Pass 1 (sizes
   every instruction and fixes every label's final offset) then Pass 2
   (emits real bytes + relocations into `outObj`, which the caller
   (TASM.MOD) must have already RdfInit'd).  Returns TRUE on success (no
   LogErr errors latched during either pass). *)
PROCEDURE Assemble*(srcPath: ARRAY OF CHAR; outObj: Rdoff.ObjFile): BOOLEAN;
  VAR f1: Files.File;
BEGIN
  Strings.Copy(srcPath, fname);
  obj := outObj;
  Enc.SetObj(outObj);
  anyErr := FALSE;
  Sym.Init; Dir.Init;

  IF ~Files.Reset(f1, srcPath) THEN
    LogErr.Error2("tasm: cannot open ", srcPath); RETURN FALSE
  END;
  RunPass(1, f1);
  Files.Close(f1);
  IF anyErr OR LogErr.HaveErr() THEN Sym.Free; RETURN FALSE END;

  IF ~Files.Reset(f1, srcPath) THEN
    LogErr.Error2("tasm: cannot reopen ", srcPath); Sym.Free; RETURN FALSE
  END;
  RunPass(2, f1);
  Files.Close(f1);
  IF anyErr OR LogErr.HaveErr() THEN Sym.Free; RETURN FALSE END;

  Sym.EnumGlobals(EmitGlobal);
  Sym.Free;
  RETURN ~(anyErr OR LogErr.HaveErr())
END Assemble;

END Parse.
