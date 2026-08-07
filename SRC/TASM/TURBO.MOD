MODULE Turbo;
(*
  Turbo -- convert a Borland Turbo Assembler 5.0 (MASM/Ideal-mode) .asm
  source file into NASM syntax.

  Design: single left-to-right pass, one output line (sometimes several)
  per input line.  Each source line is classified by its leading token
  (label, directive, mnemonic, data-definition, macro/conditional
  keyword) and rewritten using the token tables below.  Running state
  tracks what TASM's directives are context-sensitive about and NASM's
  are not: Ideal vs MASM mode, current radix, an open PROC's ARG/LOCAL/
  USES frame (incl. NEAR/FAR base offset and the RET-cleanup byte
  count), an open STRUC/TABLE/RECORD's field-offset cursor (RECORD
  fields additionally need their bit-width and bit-offset for WIDTH/
  MASK/SETFIELD/GETFIELD), an open MACRO's named-parameter list, and
  the current object's METHOD table (for OOP STRUC/TBLINST/TBLINIT/
  CALL..METHOD).

  Coverage note: every construct is either (a) translated to real NASM
  syntax and semantics, or (b) -- only for the handful of purely
  linker-level directives that have no assembler-side meaning at all in
  any assembler (INCLUDELIB, ALIAS, COMM's cross-module auto-merge) --
  passed through as a comment, since the correct "translation" is
  literally "move this to your linker command line".
  Nothing is dropped silently: search the output for "T2NASM:" to find
  every place the converter made a judgment call worth reviewing.

  Used by TASM.MOD's `/LNG=turbo` mode: Convert() writes NASM-subset
  source, which TASM.MOD then feeds straight into Parse.Assemble (the
  same pipeline `/LNG=nasm` uses) to produce the final .rdf.  Diagnostics
  route through LogErr, matching every other module in SRC/TASM/ --
  Convert itself never calls SYSTEM.Halt (that's TASM.MOD's job, once,
  in its own Run).
*)
IMPORT Files, Strings, LogErr;

CONST
  MaxLine   = 512;
  MaxArgs   = 9;       (* NASM %1..%9 -- matches TASM.EXE's own %1..%9 cap *)
  MaxFrame  = 24;       (* max ARG+LOCAL entries tracked per open PROC *)
  MaxFields = 32;       (* max fields tracked per open RECORD *)
  MaxMethods = 24;      (* max METHOD-table entries per open OOP STRUC *)

  ModeMasm  = 0;        (* default *)
  ModeIdeal = 1;

  DistNear = 0;
  DistFar  = 1;

  (* language calling conventions relevant to stack cleanup (Fig 10.1) *)
  LangNone   = 0;        (* NOLANGUAGE: no auto prolog/epilog at all *)
  LangCallee = 1;        (* BASIC/FORTRAN/PASCAL: PROC cleans the stack *)
  LangCaller = 2;        (* C/CPP/PROLOG: caller cleans the stack *)

TYPE
  Name32 = ARRAY 32 OF CHAR;
  ArgList = ARRAY 16 OF ARRAY MaxLine OF CHAR;

VAR
  radix: INTEGER;
  reviewCount*: INTEGER;     (* count of "; T2NASM:" advisory lines emitted --
                                 exported for TASM.MOD's post-Convert summary *)

  (* ---- open PROC's stack-frame state ---- *)
  inProc: BOOLEAN;
  procDist: INTEGER;                (* DistNear / DistFar *)
  procLang: INTEGER;                (* LangNone/LangCallee/LangCaller *)
  argOfs, localOfs: INTEGER;        (* next [bp+N] / [bp-N] byte offset to hand out *)
  frameNames: ARRAY MaxFrame OF Name32;
  frameIsArg: ARRAY MaxFrame OF BOOLEAN;
  frameOfs:   ARRAY MaxFrame OF INTEGER;
  frameCount: INTEGER;
  (* knownFrameNames: every "@@name" seen on an ARG/LOCAL line for the
     currently open PROC, in original "@@name" spelling, populated by
     PreRegisterFrameNames the instant such a line is read (BEFORE
     RewriteAtAt runs on it) -- kept entirely separate from frameNames
     (which HandleFrameList populates later, in "_name" form, for
     %define/offset bookkeeping) so the two never collide or double-up;
     this array exists purely to answer IsArgLocalName's "@@name or
     .name?" question during rewriting. *)
  knownFrameNames: ARRAY MaxFrame OF Name32;
  knownFrameCount: INTEGER;
  argBytesTotal: INTEGER;           (* total ARG byte count, for callee RET n cleanup *)
  usesRegs: ARRAY 8 OF Name32;
  usesCount: INTEGER;
  procNeedsFrame: BOOLEAN;          (* set TRUE the moment this PROC declares
                                        ARG, LOCAL, or USES -- a proc with
                                        none of the three needs no BP frame
                                        at all (matches real TASM: PROC alone
                                        emits no prolog/epilog code) *)
  procHasFrame: BOOLEAN;            (* TRUE once "push bp / mov bp,sp [/ sub
                                        sp,N]" has actually been emitted for
                                        the currently open PROC -- deferred to
                                        EnsureProcFrame's first call (the
                                        first USES line, or the first real
                                        instruction if there was no USES) so
                                        every ARG/LOCAL line has already run
                                        and localOfs holds the true total *)

  (* ---- open STRUC/TABLE field-offset cursor ---- *)
  inStruc: BOOLEAN;
  strucName: Name32;

  (* ---- open RECORD's bit-field table (needed later for WIDTH/MASK/
     SETFIELD/GETFIELD anywhere in the file, so kept in a flat global
     table keyed by "recordname.fieldname" / "recordname" instead of
     being reset when RECORD closes) ---- *)
  recFieldRec:   ARRAY MaxFields OF Name32;   (* owning RECORD name *)
  recFieldName:  ARRAY MaxFields OF Name32;
  recFieldWidth: ARRAY MaxFields OF INTEGER;
  recFieldShift: ARRAY MaxFields OF INTEGER;  (* bit position, last field = 0 *)
  recFieldCount: INTEGER;
  recTotalWidth: ARRAY MaxFields OF INTEGER;  (* per-RECORD total width, indexed like recFieldRec's first field *)
  curRecordName: Name32;

  (* ---- open MACRO's named-parameter list ---- *)
  inMacro: BOOLEAN;
  macroParams: ARRAY MaxArgs OF Name32;
  macroParamCount: INTEGER;

  (* ---- current OOP object (STRUC ... METHOD { }) ---- *)
  inMethodTable: BOOLEAN;
  objName: Name32;
  objParent: Name32;
  objDist: INTEGER;                 (* DistNear/DistFar for the @Mptr field *)
  methodName:  ARRAY MaxMethods OF Name32;
  methodProc:  ARRAY MaxMethods OF Name32;
  methodVirt:  ARRAY MaxMethods OF BOOLEAN;
  methodCount: INTEGER;

  dst: Files.File;
  srcFile: Files.File;    (* the input file -- read-ahead helpers (IRP/IRPC
                              body capture, OOP brace-body capture) pull
                              extra lines directly from it *)

(* ---------------------------------------------------------------- *)
(*  small string / char helpers                                     *)
(* ---------------------------------------------------------------- *)

PROCEDURE IsIdentStart(ch: CHAR): BOOLEAN;
BEGIN
  RETURN SYSTEM.ISALPHA(ch) OR (ch = "_") OR (ch = "@") OR (ch = "$") OR (ch = "?")
END IsIdentStart;

PROCEDURE IsIdentChar(ch: CHAR): BOOLEAN;
BEGIN
  (* "." included so SplitWord captures dot-directives (.586, .MODEL,
     .CODE, .DATA?, .RADIX, .STARTUP, .EXIT, .FARDATA?, ...) as one
     token; struct member access (instance.field) is scanned by its own
     explicit '.' handling elsewhere, never through SplitWord/IsIdentChar. *)
  RETURN IsIdentStart(ch) OR SYSTEM.ISDIGIT(ch) OR (ch = ".")
END IsIdentChar;

PROCEDURE AppendChar(ch: CHAR; VAR d: ARRAY OF CHAR);
  VAR one: ARRAY 2 OF CHAR;
BEGIN
  one[0] := ch; one[1] := 0X;
  Strings.Append(one, d)
END AppendChar;

(* ToLower: SYSTEM.LOSTR lowercases in place, so copy first -- this is
   just that plus the copy, not a reimplementation. *)
PROCEDURE ToLower(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
BEGIN
  Strings.Copy(s, d); SYSTEM.LOSTR(d)
END ToLower;

PROCEDURE Trimmed(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
BEGIN
  Strings.Copy(s, d); Strings.Trim(d)
END Trimmed;

PROCEDURE IntToStr(v: INTEGER; VAR d: ARRAY OF CHAR);
BEGIN
  d[0] := 0X; Strings.AppendInt(LONGINT(v), d)
END IntToStr;

PROCEDURE Emit(s: ARRAY OF CHAR);
BEGIN
  Files.WriteLine(dst, s)
END Emit;

PROCEDURE Emit2(a, b: ARRAY OF CHAR);
  VAR line: ARRAY MaxLine OF CHAR;
BEGIN
  line[0] := 0X; Strings.Append(a, line); Strings.Append(b, line); Emit(line)
END Emit2;

(* EmitNote: an informational "T2NASM:" comment -- something the reader
   should double-check (a judgment call, an approximation, a manual
   linker-side step) but that IS a complete, working translation, not a
   gap.  Counted separately from hard failures (there are none left). *)
PROCEDURE EmitNote(msg: ARRAY OF CHAR);
BEGIN
  INC(reviewCount);
  Emit2("; T2NASM: ", msg)
END EmitNote;

(* ---------------------------------------------------------------- *)
(*  line splitting                                                  *)
(* ---------------------------------------------------------------- *)

PROCEDURE FindCommentStart(line: ARRAY OF CHAR): INTEGER;
  VAR i, len: INTEGER; inStr: BOOLEAN; q: CHAR;
BEGIN
  len := INTEGER(Strings.Length(line));
  i := 0; inStr := FALSE; q := 0X;
  WHILE i < len DO
    IF inStr THEN
      IF line[i] = q THEN inStr := FALSE END
    ELSIF (line[i] = 22X) OR (line[i] = 27X) THEN
      inStr := TRUE; q := line[i]
    ELSIF line[i] = ";" THEN
      RETURN i
    END;
    INC(i)
  END;
  RETURN len
END FindCommentStart;

PROCEDURE SplitWord(code: ARRAY OF CHAR; i, codeLen: INTEGER; VAR word: ARRAY OF CHAR): INTEGER;
BEGIN
  word[0] := 0X;
  WHILE (i < codeLen) & IsIdentChar(code[i]) DO AppendChar(code[i], word); INC(i) END;
  RETURN i
END SplitWord;

PROCEDURE SkipBlanks(code: ARRAY OF CHAR; i, codeLen: INTEGER): INTEGER;
BEGIN
  WHILE (i < codeLen) & SYSTEM.ISSPACE(code[i]) DO INC(i) END;
  RETURN i
END SkipBlanks;

(* IsArgLocalName: TRUE if atAtName ("@@xxx", still in its original
   TASM spelling) is one of the current PROC's own ARG/LOCAL names --
   those become %define targets, and NASM's %define does not accept a
   leading '.' in the macro name (unlike a real LABEL, which NASM DOES
   let start with '.' for its native dot-local scoping), so ARG/LOCAL
   names become "_xxx" instead of ".xxx" (scoped via the %undef
   UndefFrameNames emits at ENDP, not NASM's dot-local mechanism), while
   every other "@@xxx" (a genuine LABEL definition or jump-target
   reference) becomes ".xxx". Compares against knownFrameNames, which
   PreRegisterFrameNames populates from this same line's ORIGINAL
   "@@xxx" spelling before RewriteAtAt ever touches it -- see
   RewriteAtAt's caller. *)
PROCEDURE IsArgLocalName(atAtName: ARRAY OF CHAR): BOOLEAN;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < knownFrameCount DO
    IF Strings.Equal(atAtName, knownFrameNames[k]) THEN RETURN TRUE END;
    INC(k)
  END;
  RETURN FALSE
END IsArgLocalName;

(* PreRegisterFrameNames: if rawCode (the UN-rewritten line, still with
   literal "@@name" spelling) is an ARG or LOCAL directive line, extract
   every "@@name" it declares and register it into knownFrameNames right
   away -- BEFORE RewriteAtAt runs on this same line -- so
   IsArgLocalName already recognizes these names as ARG/LOCAL (not
   labels) on the very declaration line itself, not just on later
   reference lines.  This is a lightweight name-only pre-scan (no
   type/count parsing -- HandleFrameList repeats the real parse, into
   the separate frameNames array, once dispatch reaches it);
   knownFrameCount is reset per-PROC by ResetProcFrame, so a stale
   registration from an earlier PROC can never leak here. *)
PROCEDURE PreRegisterFrameNames(rawCode: ARRAY OF CHAR);
  VAR i, len: INTEGER; word: Name32; isFrameLine: BOOLEAN;
BEGIN
  len := INTEGER(Strings.Length(rawCode));
  i := SkipBlanks(rawCode, 0, len);
  word[0] := 0X;
  i := SplitWord(rawCode, i, len, word);
  isFrameLine := Strings.EqualICase(word, "ARG") OR Strings.EqualICase(word, "LOCAL");
  IF ~isFrameLine THEN RETURN END;
  i := 0;
  WHILE i < len DO
    IF (i + 2 < len) & (rawCode[i] = "@") & (rawCode[i+1] = "@") & IsIdentStart(rawCode[i+2]) THEN
      word[0] := 0X; Strings.Append("@@", word);
      i := i + 2;
      WHILE (i < len) & IsIdentChar(rawCode[i]) DO AppendChar(rawCode[i], word); INC(i) END;
      IF knownFrameCount < MaxFrame THEN
        Strings.Copy(word, knownFrameNames[knownFrameCount]); INC(knownFrameCount)
      END
    ELSE
      INC(i)
    END
  END
END PreRegisterFrameNames;

(* LineWantsBareAddress: TRUE if an "OFFSET" keyword appears on this
   line -- that context wants the ARG/LOCAL name's raw "bp+N"/"bp-N"
   address expression, never wrapped in "[..]" (OFFSET computes an
   address, it does not dereference memory).  LEA is NOT such a
   context: unlike OFFSET, NASM's "lea reg, mem" syntax always requires
   its second operand in brackets -- exactly like TASM's own "lea reg,
   [name]"/"lea reg, name" (both equivalent in TASM, and both need the
   bracket-wrapped "[_name]" form here since NASM has no bracket-free
   lea operand syntax at all).
   Checked once per line (RewriteAtAt's caller), not per-@@-occurrence:
   a line can only be one instruction, so one context applies throughout. *)
PROCEDURE LineWantsBareAddress(code: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER; word: Name32;
BEGIN
  len := INTEGER(Strings.Length(code));
  i := 0;
  WHILE i < len DO
    IF IsIdentStart(code[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(code[i]) DO AppendChar(code[i], word); INC(i) END;
      IF Strings.EqualICase(word, "OFFSET") THEN RETURN TRUE END
    ELSE
      INC(i)
    END
  END;
  RETURN FALSE
END LineWantsBareAddress;

(* RewriteAtAt: replace every whole-identifier "@@name" with NASM's
   dot-local-label syntax ".name" for a real LABEL, or "_name" for a
   known ARG/LOCAL name (IsArgLocalName -- NASM's %define can't target
   a leading-'.' name).  For a LABEL, NASM's own dot-local scoping
   already makes ".name" unique per enclosing non-local label (routine),
   exactly TASM's own @@name-is-scoped-to-its-PROC semantics, with no
   per-PROC suffix bookkeeping needed on this converter's side; for an
   ARG/LOCAL name, UndefFrameNames emits a matching "%undef _name" at
   ENDP so a later PROC reusing the same short name never collides with
   a stale %define from an earlier one.
   "_name" expands (HandleFrameList) to a bracket-free "bp+N"/"bp-N"
   expression, so a bare reference used as a memory operand ("mov ax,
   @@x") must be wrapped here in "[.._x]" to still dereference memory;
   a reference already inside source-level brackets ("mov ax,[@@x]")
   must NOT be double-wrapped -- the existing brackets already do the
   job, so only the "_x" substitution happens, same as if no brackets
   were requested; and an OFFSET-context reference (LineWantsBareAddress)
   must stay bracket-free in both spellings, since OFFSET wants the raw
   address expression, not a memory dereference -- LEA is NOT such a
   context (see LineWantsBareAddress's own header comment).
   Honors '...'/"..." string/char literals (a "@@" inside one is data,
   not an identifier reference, and must not be rewritten). *)
PROCEDURE RewriteAtAt(src: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len, fi, bracketDepth: INTEGER; inStr: BOOLEAN; q: CHAR;
      word, atAtName, fword: ARRAY MaxLine OF CHAR;
      bracketed, bareAddr, isDeclLine: BOOLEAN;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src));
  bareAddr := LineWantsBareAddress(src);
  (* An ARG/LOCAL declaration line names its own parameters -- never
     wrap those in "[..]" here, that would corrupt HandleFrameList's
     own identifier scan (e.g. "ARG [_x]:WORD"). Bracket-wrapping only
     applies to later reference lines. *)
  fi := SkipBlanks(src, 0, len);
  fword[0] := 0X;
  fi := SplitWord(src, fi, len, fword);
  isDeclLine := Strings.EqualICase(fword, "ARG") OR Strings.EqualICase(fword, "LOCAL");
  i := 0; inStr := FALSE; q := 0X; bracketDepth := 0;
  WHILE i < len DO
    IF inStr THEN
      AppendChar(src[i], out);
      IF src[i] = q THEN inStr := FALSE END;
      INC(i)
    ELSIF (src[i] = 22X) OR (src[i] = 27X) THEN
      inStr := TRUE; q := src[i]; AppendChar(src[i], out); INC(i)
    ELSIF (i + 2 < len) & (src[i] = "@") & (src[i+1] = "@") & IsIdentStart(src[i+2]) THEN
      (* Requires a real identifier right after the second '@' -- a BARE
         "@@" (MASM-compat mode's anonymous numbered local label, paired
         with single-@ "@F"/"@B" forward/backward references -- a
         distinct, rarer feature this converter does not otherwise
         implement) is left untouched rather than mangled into a stray
         "." or "_". *)
      word[0] := 0X;
      i := i + 2;
      WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], word); INC(i) END;
      atAtName[0] := 0X; Strings.Append("@@", atAtName); Strings.Append(word, atAtName);
      IF IsArgLocalName(atAtName) THEN
        (* bracketDepth > 0 iff this @@name sits somewhere inside an
           unclosed source-level "[..]" -- a running open/close count
           over every "[" / "]" already copied to OUT, NOT a peek at
           OUT's last character (which broke on "[ @@x]" with a space,
           "[es:@@x]" with a segment-override prefix, and a second
           @@name inside one compound bracketed expression like
           "[@@x+@@y]" -- all three produced malformed double brackets
           since the old check only recognized "[" as the IMMEDIATELY
           preceding character). *)
        bracketed := bracketDepth > 0;
        IF bareAddr OR bracketed OR isDeclLine THEN
          Strings.Append("_", out); Strings.Append(word, out)
        ELSE
          Strings.Append("[_", out); Strings.Append(word, out); Strings.Append("]", out)
        END
      ELSE
        Strings.Append(".", out); Strings.Append(word, out)
      END
    ELSIF src[i] = "[" THEN
      INC(bracketDepth); AppendChar(src[i], out); INC(i)
    ELSIF src[i] = "]" THEN
      IF bracketDepth > 0 THEN DEC(bracketDepth) END;
      AppendChar(src[i], out); INC(i)
    ELSE
      AppendChar(src[i], out); INC(i)
    END
  END
END RewriteAtAt;

(* ---------------------------------------------------------------- *)
(*  operator-keyword + PTR/OFFSET/SEG rewriting                     *)
(* ---------------------------------------------------------------- *)

PROCEDURE RewriteOperator(word: ARRAY OF CHAR; VAR nasmOp: ARRAY OF CHAR): BOOLEAN;
BEGIN
  nasmOp[0] := 0X;
  IF    Strings.EqualICase(word, "AND") THEN Strings.Copy("&", nasmOp)
  ELSIF Strings.EqualICase(word, "OR")  THEN Strings.Copy("|", nasmOp)
  ELSIF Strings.EqualICase(word, "XOR") THEN Strings.Copy("^", nasmOp)
  ELSIF Strings.EqualICase(word, "NOT") THEN Strings.Copy("~", nasmOp)
  ELSIF Strings.EqualICase(word, "MOD") THEN Strings.Copy("%", nasmOp)
  ELSIF Strings.EqualICase(word, "SHL") THEN Strings.Copy("<<", nasmOp)
  ELSIF Strings.EqualICase(word, "SHR") THEN Strings.Copy(">>", nasmOp)
  ELSIF Strings.EqualICase(word, "EQ")  THEN Strings.Copy("=", nasmOp)
  ELSIF Strings.EqualICase(word, "NE")  THEN Strings.Copy("!=", nasmOp)
  ELSIF Strings.EqualICase(word, "GE")  THEN Strings.Copy(">=", nasmOp)
  ELSIF Strings.EqualICase(word, "LE")  THEN Strings.Copy("<=", nasmOp)
  ELSIF Strings.EqualICase(word, "GT")  THEN Strings.Copy(">", nasmOp)
  ELSIF Strings.EqualICase(word, "LT")  THEN Strings.Copy("<", nasmOp)
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END RewriteOperator;

(* LookupRecordField: find a RECORD/field entry by dotted or bare name;
   ownerOut/found report whether it names a whole RECORD (fieldName="")
   or one field within it. *)
(* Pow2: 2^n as a LONGINT, n in 0..31 -- used to build RECORD bit masks
   (no bare ASH/exponent builtin; SYSTEM.LSL is the shift primitive). *)
PROCEDURE Pow2(n: INTEGER): LONGINT;
BEGIN RETURN SYSTEM.LSL(LONGINT(1), n)
END Pow2;

PROCEDURE FindRecField(nm: ARRAY OF CHAR; VAR idx: INTEGER): BOOLEAN;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < recFieldCount DO
    IF Strings.Equal(recFieldName[k], nm) THEN idx := k; RETURN TRUE END;
    INC(k)
  END;
  RETURN FALSE
END FindRecField;

PROCEDURE FindRecTotalWidth(recName: ARRAY OF CHAR; VAR w: INTEGER): BOOLEAN;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < recFieldCount DO
    IF Strings.Equal(recFieldRec[k], recName) & Strings.Equal(recFieldName[k], recName) THEN
      w := recTotalWidth[k]; RETURN TRUE
    END;
    INC(k)
  END;
  RETURN FALSE
END FindRecTotalWidth;

(* RewriteExprWords: scan an operand/expression fragment, replacing every
   free-standing TASM keyword-operator with its NASM symbol, OFFSET
   (dropped), SEG (lowered), and any known RECORD/field name used as a
   bare WIDTH/MASK operand (handled by the caller before this, via
   RewriteWidthMask -- this pass only does the operator family plus
   OFFSET/SEG).  String/char literals pass through verbatim. *)
(* AppendNumberWithRadix: append a bare (unsuffixed) digit run under
   the current default RADIX with an explicit NASM suffix, since NASM
   has no "current default radix" state of its own --
   under RADIX 16 a plain "20" means 0x20 and must become "20h" or
   NASM would read it as decimal 20.  A run that already carries one of
   TASM's own h/o/q/b/d suffixes is self-describing and passed through
   untouched (NASM accepts the same suffixes). *)
PROCEDURE AppendNumberWithRadix(word: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR last: CHAR; len: WORD; allDigits: BOOLEAN; k: WORD;
BEGIN
  len := Strings.Length(word);
  allDigits := TRUE; k := 0;
  WHILE k < len DO IF ~SYSTEM.ISDIGIT(word[k]) THEN allDigits := FALSE END; INC(k) END;
  IF (radix = 10) OR ~allDigits THEN
    Strings.Append(word, out); RETURN
  END;
  last := SYSTEM.UCASE(word[len-1]);
  IF (last = "H") OR (last = "O") OR (last = "Q") OR (last = "B") OR (last = "D") THEN
    Strings.Append(word, out); RETURN
  END;
  Strings.Append(word, out);
  IF radix = 16 THEN Strings.Append("h", out)
  ELSIF radix = 8 THEN Strings.Append("o", out)
  ELSIF radix = 2 THEN Strings.Append("b", out)
  END
END AppendNumberWithRadix;

PROCEDURE RewriteExprWords(src: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len: INTEGER; word, op: ARRAY 32 OF CHAR; ch: CHAR;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src));
  i := 0;
  WHILE i < len DO
    ch := src[i];
    IF (ch = 22X) OR (ch = 27X) THEN
      AppendChar(ch, out); INC(i);
      WHILE (i < len) & (src[i] # ch) DO AppendChar(src[i], out); INC(i) END;
      IF i < len THEN AppendChar(src[i], out); INC(i) END
    ELSIF IsIdentStart(ch) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], word); INC(i) END;
      IF RewriteOperator(word, op) THEN
        Strings.Append(" ", out); Strings.Append(op, out); Strings.Append(" ", out)
      ELSIF Strings.EqualICase(word, "OFFSET") THEN
        (* a bare label already evaluates to its offset in NASM *)
      ELSIF Strings.EqualICase(word, "SEG") THEN
        Strings.Append("seg", out)
      ELSE
        Strings.Append(word, out)
      END
    ELSIF SYSTEM.ISDIGIT(ch) THEN
      word[0] := 0X;
      WHILE (i < len) & (SYSTEM.ISDIGIT(src[i]) OR IsIdentChar(src[i])) DO
        AppendChar(src[i], word); INC(i)
      END;
      AppendNumberWithRadix(word, out)
    ELSE
      AppendChar(ch, out); INC(i)
    END
  END
END RewriteExprWords;

(* RewriteWidthMask: replace every "WIDTH name" / "MASK name" pair
   (name = a RECORD or RECORD-field previously seen) with the literal
   integer value: WIDTH -> bit count, MASK ->
   ((1<<width)-1)<<shift bitmask.  Runs before RewriteExprWords. *)
PROCEDURE RewriteWidthMask(src: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len: INTEGER; word, name: ARRAY 32 OF CHAR; idx: INTEGER;
      isWidth, isMask: BOOLEAN; numStr: ARRAY 16 OF CHAR; totalW: INTEGER;
      maskVal: LONGINT;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src));
  i := 0;
  WHILE i < len DO
    IF IsIdentStart(src[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], word); INC(i) END;
      isWidth := Strings.EqualICase(word, "WIDTH");
      isMask := Strings.EqualICase(word, "MASK");
      IF isWidth OR isMask THEN
        i := SkipBlanks(src, i, len);
        name[0] := 0X;
        WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], name); INC(i) END;
        IF FindRecField(name, idx) THEN
          IF isWidth THEN
            numStr[0] := 0X; IntToStr(recFieldWidth[idx], numStr);
            Strings.Append(numStr, out)
          ELSE
            maskVal := (Pow2(recFieldWidth[idx]) - 1) * Pow2(recFieldShift[idx]);
            numStr[0] := 0X; Strings.AppendInt(maskVal, numStr);
            Strings.Append(numStr, out)
          END
        ELSIF FindRecTotalWidth(name, totalW) THEN
          IF isWidth THEN
            numStr[0] := 0X; IntToStr(totalW, numStr); Strings.Append(numStr, out)
          ELSE
            maskVal := Pow2(totalW) - 1;
            numStr[0] := 0X; Strings.AppendInt(maskVal, numStr); Strings.Append(numStr, out)
          END
        ELSE
          Strings.Append(word, out); AppendChar(" ", out); Strings.Append(name, out)
        END
      ELSE
        Strings.Append(word, out)
      END
    ELSE
      AppendChar(src[i], out); INC(i)
    END
  END
END RewriteWidthMask;

(* ---------------------------------------------------------------- *)
(*  "TYPE PTR expr" / "TYPE expr" size-cast rewriting                *)
(* ---------------------------------------------------------------- *)

PROCEDURE IsSizeWord(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EqualICase(w, "BYTE") OR Strings.EqualICase(w, "WORD")
       OR Strings.EqualICase(w, "DWORD") OR Strings.EqualICase(w, "QWORD")
       OR Strings.EqualICase(w, "TBYTE") OR Strings.EqualICase(w, "PWORD")
END IsSizeWord;

(* RewriteOperandSizes: "WORD PTR [bx]" -> "word [bx]"; "BYTE PTR foo"
   (MASM implied-deref, no brackets) -> "byte [foo]"; a bare size word
   directly before a bracket ("[WORD big]", Ideal) collapses the same
   way. NEAR/FAR/SHORT qualifiers on call/jmp targets pass through
   lower-cased verbatim (NASM accepts them as-is, no bracket-wrap). *)
PROCEDURE RewriteOperandSizes(src: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len, j: INTEGER; word, lw: ARRAY 32 OF CHAR; rest: ARRAY MaxLine OF CHAR;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src));
  i := 0;
  WHILE i < len DO
    IF IsIdentStart(src[i]) THEN
      j := i; word[0] := 0X;
      WHILE (j < len) & IsIdentChar(src[j]) DO AppendChar(src[j], word); INC(j) END;
      IF Strings.EqualICase(word, "NEAR") OR Strings.EqualICase(word, "FAR")
         OR Strings.EqualICase(word, "SHORT") THEN
        lw[0] := 0X; ToLower(word, lw); Strings.Append(lw, out); i := j
      ELSIF IsSizeWord(word) THEN
        lw[0] := 0X; ToLower(word, lw);
        Strings.Append(lw, out);
        i := j;
        i := SkipBlanks(src, i, len);
        IF (i + 2 < len) & (SYSTEM.UCASE(src[i]) = "P") & (SYSTEM.UCASE(src[i+1]) = "T")
           & (SYSTEM.UCASE(src[i+2]) = "R") & ((i+3 >= len) OR ~IsIdentChar(src[i+3])) THEN
          i := i + 3; i := SkipBlanks(src, i, len)
        END;
        IF (i < len) & (src[i] = "[") THEN
          AppendChar(" ", out); AppendChar(src[i], out); INC(i)
        ELSE
          Strings.Append(" [", out);
          rest[0] := 0X; j := i;
          WHILE (j < len) & (src[j] # ",") DO AppendChar(src[j], rest); INC(j) END;
          Strings.RTrim(rest);
          Strings.Append(rest, out);
          Strings.Append("]", out);
          i := j
        END
      ELSE
        Strings.Append(word, out); i := j
      END
    ELSE
      AppendChar(src[i], out); INC(i)
    END
  END
END RewriteOperandSizes;

(* ---------------------------------------------------------------- *)
(*  DUP expansion                                                     *)
(* ---------------------------------------------------------------- *)

PROCEDURE ReplaceQuestions(s: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i: WORD; len: WORD; inStr: BOOLEAN; q: CHAR;
BEGIN
  out[0] := 0X;
  len := Strings.Length(s); i := 0; inStr := FALSE; q := 0X;
  WHILE i < len DO
    IF inStr THEN
      AppendChar(s[i], out); IF s[i] = q THEN inStr := FALSE END
    ELSIF (s[i] = 22X) OR (s[i] = 27X) THEN
      inStr := TRUE; q := s[i]; AppendChar(s[i], out)
    ELSIF s[i] = "?" THEN
      AppendChar("0", out)
    ELSE
      AppendChar(s[i], out)
    END;
    INC(i)
  END
END ReplaceQuestions;

PROCEDURE ParseDup(s: ARRAY OF CHAR; VAR count: ARRAY OF CHAR; VAR body: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER; word: ARRAY 32 OF CHAR; depth: INTEGER;
BEGIN
  count[0] := 0X; body[0] := 0X;
  len := INTEGER(Strings.Length(s));
  i := 0;
  WHILE i < len DO
    IF IsIdentStart(s[i]) THEN
      count[0] := 0X;
      Strings.Extract(s, 0, WORD(i), count); Strings.RTrim(count);
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(s[i]) DO AppendChar(s[i], word); INC(i) END;
      IF Strings.EqualICase(word, "DUP") THEN
        i := SkipBlanks(s, i, len);
        IF (i < len) & (s[i] = "(") THEN
          INC(i); depth := 1;
          WHILE (i < len) & (depth > 0) DO
            IF s[i] = "(" THEN INC(depth)
            ELSIF s[i] = ")" THEN DEC(depth)
            END;
            IF depth > 0 THEN AppendChar(s[i], body) END;
            INC(i)
          END;
          RETURN TRUE
        END;
        RETURN FALSE
      END
    ELSE INC(i)
    END
  END;
  RETURN FALSE
END ParseDup;

PROCEDURE CountCommaItems(body: ARRAY OF CHAR): INTEGER;
  VAR i, len, depth, n: INTEGER; inStr: BOOLEAN; q: CHAR;
BEGIN
  len := INTEGER(Strings.Length(body));
  IF len = 0 THEN RETURN 0 END;
  i := 0; depth := 0; n := 1; inStr := FALSE; q := 0X;
  WHILE i < len DO
    IF inStr THEN
      IF body[i] = q THEN inStr := FALSE END
    ELSIF (body[i] = 22X) OR (body[i] = 27X) THEN inStr := TRUE; q := body[i]
    ELSIF body[i] = "(" THEN INC(depth)
    ELSIF body[i] = ")" THEN DEC(depth)
    ELSIF (body[i] = ",") & (depth = 0) THEN INC(n)
    END;
    INC(i)
  END;
  RETURN n
END CountCommaItems;

PROCEDURE EmitDupData(label: ARRAY OF CHAR; sizeKeyword: ARRAY OF CHAR;
                       countExpr: ARRAY OF CHAR; body: ARRAY OF CHAR);
  VAR clean, line: ARRAY MaxLine OF CHAR; itemCount: INTEGER;
BEGIN
  ReplaceQuestions(body, clean);
  itemCount := CountCommaItems(clean);
  line[0] := 0X;
  IF label[0] # 0X THEN Strings.Append(label, line); Strings.Append(": ", line) END;
  IF itemCount <= 1 THEN
    Strings.Append("times ", line); Strings.Append(countExpr, line);
    Strings.Append(" ", line); Strings.Append(sizeKeyword, line);
    Strings.Append(" ", line); Strings.Append(clean, line);
    Emit(line)
  ELSE
    Strings.Append("%rep ", line); Strings.Append(countExpr, line);
    Emit(line);
    line[0] := 0X; Strings.Append("  ", line); Strings.Append(sizeKeyword, line);
    Strings.Append(" ", line); Strings.Append(clean, line);
    Emit(line);
    Emit("%endrep")
  END
END EmitDupData;

PROCEDURE SizeKeywordFor(dirWord: ARRAY OF CHAR; VAR kw: ARRAY OF CHAR): BOOLEAN;
BEGIN
  kw[0] := 0X;
  IF    Strings.EqualICase(dirWord, "DB") THEN Strings.Copy("db", kw)
  ELSIF Strings.EqualICase(dirWord, "DW") THEN Strings.Copy("dw", kw)
  ELSIF Strings.EqualICase(dirWord, "DD") THEN Strings.Copy("dd", kw)
  ELSIF Strings.EqualICase(dirWord, "DQ") THEN Strings.Copy("dq", kw)
  ELSIF Strings.EqualICase(dirWord, "DT") THEN Strings.Copy("dt", kw)
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END SizeKeywordFor;

(* HandleDF: DF/DP (48-bit far pointer, 6 bytes) has no single NASM
   pseudo-op -- split each value into a dd (offset part, low 4 bytes)
   + dw (segment part) pair, which is exactly what a 48-bit far pointer
   *is* on this architecture (offset:segment as two fields). *)
PROCEDURE HandleDF(label: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR clean, rewritten, line: ARRAY MaxLine OF CHAR;
BEGIN
  ReplaceQuestions(rest, clean);
  RewriteExprWords(clean, rewritten);
  line[0] := 0X;
  IF label[0] # 0X THEN Strings.Append(label, line); Strings.Append(": ", line) END;
  Strings.Append("dd ", line); Strings.Append(rewritten, line);
  Strings.Append("  ", line);
  EmitNote("DF/DP far pointer split into dd(offset)+dw(segment) -- verify the value expression above is the OFFSET part");
  Emit(line);
  line[0] := 0X; Strings.Append("dw seg ", line); Strings.Append(rewritten, line);
  Emit(line)
END HandleDF;

PROCEDURE HandleDataDef(label: ARRAY OF CHAR; dirWord: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR kw: ARRAY 4 OF CHAR; count, body, clean, rewritten, line: ARRAY MaxLine OF CHAR;
BEGIN
  IF Strings.EqualICase(dirWord, "DF") OR Strings.EqualICase(dirWord, "DP") THEN
    HandleDF(label, rest); RETURN
  END;
  IF ~SizeKeywordFor(dirWord, kw) THEN RETURN END;
  IF ParseDup(rest, count, body) THEN
    EmitDupData(label, kw, count, body); RETURN
  END;
  ReplaceQuestions(rest, clean);
  RewriteExprWords(clean, rewritten);
  line[0] := 0X;
  IF label[0] # 0X THEN Strings.Append(label, line); Strings.Append(": ", line) END;
  Strings.Append(kw, line); Strings.Append(" ", line); Strings.Append(rewritten, line);
  Emit(line)
END HandleDataDef;

(* ---------------------------------------------------------------- *)
(*  SEGMENT / ENDS / GROUP / simplified segment directives           *)
(* ---------------------------------------------------------------- *)

PROCEDURE EmitSection(nasmName: ARRAY OF CHAR);
BEGIN
  Emit2("section ", nasmName)
END EmitSection;

PROCEDURE HandleSegmentAttrs(name: ARRAY OF CHAR; attrs: ARRAY OF CHAR);
  VAR line: ARRAY MaxLine OF CHAR; i, len: INTEGER; word, lw: ARRAY 32 OF CHAR;
BEGIN
  line[0] := 0X;
  Strings.Append("SEGMENT ", line); Strings.Append(name, line);
  len := INTEGER(Strings.Length(attrs));
  i := 0;
  WHILE i < len DO
    i := SkipBlanks(attrs, i, len);
    IF i < len THEN
      IF IsIdentStart(attrs[i]) THEN
        word[0] := 0X;
        WHILE (i < len) & IsIdentChar(attrs[i]) DO AppendChar(attrs[i], word); INC(i) END;
        IF Strings.EqualICase(word, "PARA") OR Strings.EqualICase(word, "BYTE")
           OR Strings.EqualICase(word, "WORD") OR Strings.EqualICase(word, "DWORD")
           OR Strings.EqualICase(word, "PAGE") OR Strings.EqualICase(word, "MEMPAGE") THEN
          Strings.Append(" ALIGN=", line);
          IF    Strings.EqualICase(word, "BYTE")  THEN Strings.Append("1", line)
          ELSIF Strings.EqualICase(word, "WORD")  THEN Strings.Append("2", line)
          ELSIF Strings.EqualICase(word, "DWORD") THEN Strings.Append("4", line)
          ELSIF Strings.EqualICase(word, "PARA")  THEN Strings.Append("16", line)
          ELSIF Strings.EqualICase(word, "PAGE")  THEN Strings.Append("256", line)
          ELSE Strings.Append("4096", line)
          END
        ELSIF Strings.EqualICase(word, "PUBLIC") OR Strings.EqualICase(word, "COMMON")
           OR Strings.EqualICase(word, "MEMORY") OR Strings.EqualICase(word, "STACK")
           OR Strings.EqualICase(word, "PRIVATE") THEN
          lw[0] := 0X; ToLower(word, lw); Strings.Append(" ", line); Strings.Append(lw, line)
        ELSE
          Strings.Append(" ", line); Strings.Append(word, line)
        END
      ELSIF (attrs[i] = 22X) OR (attrs[i] = 27X) THEN
        word[0] := 0X; AppendChar(attrs[i], word); INC(i);
        WHILE (i < len) & (attrs[i] # 22X) & (attrs[i] # 27X) DO AppendChar(attrs[i], word); INC(i) END;
        IF i < len THEN AppendChar(attrs[i], word); INC(i) END;
        Strings.Append(" CLASS=", line); Strings.Append(word, line)
      ELSE
        INC(i)
      END
    END
  END;
  Emit(line)
END HandleSegmentAttrs;

(* ---------------------------------------------------------------- *)
(*  PROC / ENDP / ARG / LOCAL / USES / RET                           *)
(* ---------------------------------------------------------------- *)

(* TypeSize: byte size a TASM ARG/LOCAL "type" occupies on the stack.
   BYTE promotes to 2 (word) (can't PUSH
   a raw byte); DWORD/FAR/structure types use their real size. *)
PROCEDURE TypeSize(t: ARRAY OF CHAR): INTEGER;
BEGIN
  IF Strings.EqualICase(t, "DWORD") OR Strings.EqualICase(t, "FAR")
     OR Strings.EqualICase(t, "PTR") THEN RETURN 4
  ELSE RETURN 2   (* BYTE (promoted)/WORD/NEAR all occupy one stack word *)
  END
END TypeSize;

PROCEDURE ResetProcFrame(dist: INTEGER; lang: INTEGER);
BEGIN
  inProc := TRUE; procDist := dist; procLang := lang;
  (* NEAR: return address is 2 bytes -> first ARG at [bp+4] (2 for
     saved BP + 2 for the near return addr).  FAR: return address is 4
     bytes (offset+segment) -> first ARG at [bp+6]. *)
  IF dist = DistFar THEN argOfs := 6 ELSE argOfs := 4 END;
  localOfs := 0; frameCount := 0; argBytesTotal := 0; usesCount := 0;
  procNeedsFrame := FALSE; procHasFrame := FALSE; knownFrameCount := 0
END ResetProcFrame;

(* EnsureProcFrame: emit "push bp / mov bp,sp / sub sp,N" exactly once,
   the first time it's actually needed (the first USES line or the first
   real instruction after the PROC header) -- NOT eagerly on the first
   ARG/LOCAL line, because the prolog order is BP-save, THEN
   SP-adjust-for-locals, THEN USES-pushes, and localOfs (the total LOCAL byte
   count "sub sp,N" needs) isn't known until every LOCAL line for this
   PROC has been processed -- which may still be to come when the first
   ARG/LOCAL line itself is seen. Deferring to first-USES-or-first-
   instruction guarantees every ARG/LOCAL directive on this PROC has
   already run. A PROC with neither ARG nor LOCAL nor USES never calls
   this at all, so it correctly gets no BP frame (matches real TASM:
   PROC alone needs no prologue). *)
PROCEDURE EnsureProcFrame;
  VAR ofsStr: ARRAY 8 OF CHAR;
BEGIN
  IF procHasFrame OR ~procNeedsFrame OR ~inProc OR (procLang = LangNone) THEN RETURN END;
  Emit("push bp");
  Emit("mov bp, sp");
  IF localOfs > 0 THEN
    ofsStr[0] := 0X; IntToStr(localOfs, ofsStr);
    Emit2("sub sp, ", ofsStr)
  END;
  procHasFrame := TRUE
END EnsureProcFrame;

(* HandleFrameList: parse one ARG or LOCAL directive's whole comma-list.
   LOCAL is a single streaming pass (each name always gets the next
   [bp-N] slot in declared order -- no language-dependent direction).
   ARG is NOT a single streaming pass: the offset a given ARG name gets
   depends on the PROC's language-declared push direction, which is
   opposite to its textual declaration order for PASCAL/BASIC/FORTRAN.

   Argument ordering (left-to-right /
   right-to-left) resolves consistently for a language whose
   declared-first parameter is pushed LAST (closest to BP): that is R-L
   languages (C/CPP/SYSCALL/PROLOG) -- their natural source-declaration
   order already matches first-declared = smallest offset = last-pushed.
   For L-R languages (PASCAL/BASIC/FORTRAN/the
   default), the first DECLARED source parameter is pushed FIRST, so it
   lands at the LARGEST offset (deepest/most distant from BP) -- the
   OPPOSITE of C's arrangement -- so ARG must assign offsets by walking
   the declared name list back-to-front for those languages, letting
   the TASM source list its ARG names in the procedure's natural
   left-to-right declared parameter order either way (matching
   TETRIS.MOD's own `Draw(VAR buf; VAR spr)` declaration order,
   regardless of push direction) instead of requiring the source author
   to manually reverse the list for PASCAL.

   Two passes: first collect every name/type/count2 into a local
   scratch array (needed regardless of direction, since C's forward
   walk and PASCAL's backward walk both need the full list up front to
   know where to start), then assign+emit offsets in the direction the
   open PROC's language requires. *)

(* MaxArgEntries: one ARG/LOCAL directive line's entries can never
   exceed MaxFrame (the whole PROC's combined ARG+LOCAL cap), so tying
   the two together makes truncation here structurally impossible
   rather than merely unlikely -- a silent drop past a lower cap here
   would have desynced the two-pass offset walk below (see the
   LogErr.Error fallback for the case a future edit lowers this again). *)
CONST MaxArgEntries = MaxFrame;

PROCEDURE HandleFrameList(rest: ARRAY OF CHAR; isArg: BOOLEAN);
  VAR i, len: INTEGER; name, typeName, countStr: Name32;
      sz, repCount: INTEGER; line, ofsStr, maxStr: ARRAY MaxLine OF CHAR; valStart: WORD;
      entryName: ARRAY MaxArgEntries OF Name32;
      entrySize: ARRAY MaxArgEntries OF INTEGER;
      entryOfs:  ARRAY MaxArgEntries OF INTEGER;
      n, k: INTEGER;
BEGIN
  procNeedsFrame := TRUE;
  n := 0;
  len := INTEGER(Strings.Length(rest));
  i := 0;
  WHILE i < len DO
    i := SkipBlanks(rest, i, len);
    name[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], name); INC(i) END;
    Strings.Copy("WORD", typeName);
    Strings.Copy("1", countStr);
    i := SkipBlanks(rest, i, len);
    IF (i < len) & (rest[i] = ":") THEN
      INC(i); i := SkipBlanks(rest, i, len);
      typeName[0] := 0X;
      WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], typeName); INC(i) END;
      i := SkipBlanks(rest, i, len);
      IF (i < len) & (rest[i] = ":") THEN
        INC(i); countStr[0] := 0X; i := SkipBlanks(rest, i, len);
        WHILE (i < len) & SYSTEM.ISDIGIT(rest[i]) DO AppendChar(rest[i], countStr); INC(i) END
      END
    END;
    (* trailing "=symbol" total-size alias: TASM equates symbol to the
       total ARG-block byte count -- not currently emitted (no single
       source line to attach an equ to once the total is known; see
       the historical note this replaced). *)
    WHILE (i < len) & (rest[i] # ",") & (rest[i] # "=") DO INC(i) END;
    IF (i < len) & (rest[i] = "=") THEN
      INC(i); i := SkipBlanks(rest, i, len);
      WHILE (i < len) & (rest[i] # ",") DO INC(i) END
    END;
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;

    IF name[0] # 0X THEN
      IF n >= MaxArgEntries THEN
        (* Dropping this entry silently would desync the backward-walk
           offset assignment below for every entry already collected
           (see HandleFrameList's own header comment) -- fail fast
           instead of emitting a PROC with corrupted [bp+N] offsets. *)
        maxStr[0] := 0X; IntToStr(MaxArgEntries, maxStr);
        LogErr.Error2("tasm: too many ARG/LOCAL entries on one directive line, max ", maxStr);
      ELSE
        valStart := 0;
        repCount := INTEGER(Strings.Val(countStr, valStart));
        IF repCount < 1 THEN repCount := 1 END;
        sz := TypeSize(typeName) * repCount;  (* count2 repeat-count multiplier *)
        Strings.Copy(name, entryName[n]); entrySize[n] := sz; INC(n)
      END
    END
  END;

  IF ~isArg THEN
    (* LOCAL: always one streaming forward pass, declared order ==
       [bp-N] allocation order, no language dependence. *)
    k := 0;
    WHILE k < n DO
      INC(localOfs, entrySize[k]);
      IF frameCount < MaxFrame THEN
        Strings.Copy(entryName[k], frameNames[frameCount]);
        frameIsArg[frameCount] := FALSE;
        frameOfs[frameCount] := -localOfs;
        INC(frameCount)
      END;
      line[0] := 0X;
      Strings.Append("%define ", line); Strings.Append(entryName[k], line);
      Strings.Append(" bp-", line);
      ofsStr[0] := 0X; IntToStr(localOfs, ofsStr); Strings.Append(ofsStr, line);
      Emit(line);
      INC(k)
    END;
    RETURN
  END;

  (* ARG: direction depends on the open PROC's push order. *)
  IF procLang = LangCaller THEN
    (* C/CPP/SYSCALL/PROLOG: R-L push -- declared-first param is pushed
       LAST, landing at the smallest offset -- a plain forward walk over
       the declared list already assigns increasing offsets correctly. *)
    k := 0;
    WHILE k < n DO
      IF frameCount < MaxFrame THEN
        Strings.Copy(entryName[k], frameNames[frameCount]);
        frameIsArg[frameCount] := TRUE;
        frameOfs[frameCount] := argOfs;
        INC(frameCount)
      END;
      line[0] := 0X;
      Strings.Append("%define ", line); Strings.Append(entryName[k], line);
      Strings.Append(" bp+", line);
      ofsStr[0] := 0X; IntToStr(argOfs, ofsStr); Strings.Append(ofsStr, line);
      Emit(line);
      INC(argOfs, entrySize[k]); INC(argBytesTotal, entrySize[k]);
      INC(k)
    END
  ELSE
    (* PASCAL/BASIC/FORTRAN (LangCallee) or NOLANGUAGE: L-R push --
       declared-first param is pushed FIRST, landing at the LARGEST
       offset.  Assign offsets by walking the declared list back-to-
       front (the LAST-declared name gets the smallest offset -- argOfs
       as it stands now -- and offsets grow walking toward the first-
       declared name), storing each into entryOfs; then emit in the
       original forward (declared) order using those precomputed
       offsets, so the %define lines appear in source order even though
       they were assigned back-to-front. *)
    k := n - 1;
    WHILE k >= 0 DO
      entryOfs[k] := argOfs;
      INC(argOfs, entrySize[k]); INC(argBytesTotal, entrySize[k]);
      DEC(k)
    END;
    k := 0;
    WHILE k < n DO
      IF frameCount < MaxFrame THEN
        Strings.Copy(entryName[k], frameNames[frameCount]);
        frameIsArg[frameCount] := TRUE;
        frameOfs[frameCount] := entryOfs[k];
        INC(frameCount)
      END;
      line[0] := 0X;
      Strings.Append("%define ", line); Strings.Append(entryName[k], line);
      Strings.Append(" bp+", line);
      ofsStr[0] := 0X; IntToStr(entryOfs[k], ofsStr); Strings.Append(ofsStr, line);
      Emit(line);
      INC(k)
    END
  END
END HandleFrameList;

(* HandleUses: USES reg1,reg2,... -- push in listed order right after
   the label (prologue); the matching pop-in-reverse-order sequence is
   emitted at every RET by InjectEpilogue below, so this just records
   the list and pushes it once, here, at the PROC header site. *)
PROCEDURE HandleUses(rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; name: Name32; line: ARRAY MaxLine OF CHAR;
BEGIN
  procNeedsFrame := TRUE;
  EnsureProcFrame;
  len := INTEGER(Strings.Length(rest));
  i := 0;
  WHILE (i < len) & (usesCount < 8) DO
    i := SkipBlanks(rest, i, len);
    name[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], name); INC(i) END;
    WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    IF name[0] # 0X THEN
      Strings.Copy(name, usesRegs[usesCount]); INC(usesCount);
      line[0] := 0X; Strings.Append("push ", line); Strings.Append(name, line);
      Emit(line)
    END
  END
END HandleUses;

(* InjectEpilogue: called instead of a bare "ret" translation whenever
   inProc is TRUE and the PROC has a language convention -- pops USES
   registers in reverse order, then emits ret/retf with the callee-
   cleanup byte count when procLang = LangCallee (matches Fig 10.1:
   PASCAL/BASIC/FORTRAN clean their own stack; C/CPP/PROLOG leave it to
   the caller, which gets a plain ret/retf; NOLANGUAGE gets none of
   this machinery at all -- the source's own RET is emitted verbatim). *)
PROCEDURE InjectEpilogue(explicitOperand: ARRAY OF CHAR);
  VAR k: INTEGER; line, ofsStr: ARRAY MaxLine OF CHAR;
BEGIN
  IF ~inProc OR (procLang = LangNone) THEN
    line[0] := 0X;
    IF procDist = DistFar THEN Strings.Append("retf", line) ELSE Strings.Append("ret", line) END;
    IF explicitOperand[0] # 0X THEN Strings.Append(" ", line); Strings.Append(explicitOperand, line) END;
    Emit(line); RETURN
  END;
  k := usesCount - 1;
  WHILE k >= 0 DO
    Emit2("pop ", usesRegs[k]); DEC(k)
  END;
  IF procHasFrame THEN
    (* Discard LOCAL vars, then restore caller's BP, matching the
       standard Pascal-epilogue shape: mov sp,bp / pop bp /
       ret[f] argBytes.  "mov sp,bp" is only emitted when this PROC
       actually reserved LOCAL space -- by the time USES has already
       been popped above, SP already reads back as BP for a no-LOCAL
       proc, and real TASM does not emit a redundant "mov sp,bp" in
       that case (confirmed against a hand-written oracle: a USES-only,
       no-LOCAL proc's epilogue is plain "pop <uses.../> / pop bp /
       ret[f] n", no "mov sp,bp" line at all). *)
    IF localOfs > 0 THEN Emit("mov sp, bp") END;
    Emit("pop bp")
  END;
  line[0] := 0X;
  IF procDist = DistFar THEN Strings.Append("retf", line) ELSE Strings.Append("ret", line) END;
  IF explicitOperand[0] # 0X THEN
    Strings.Append(" ", line); Strings.Append(explicitOperand, line)
  ELSIF (procLang = LangCallee) & (argBytesTotal > 0) THEN
    ofsStr[0] := 0X; IntToStr(argBytesTotal, ofsStr);
    Strings.Append(" ", line); Strings.Append(ofsStr, line)
  END;
  Emit(line)
END InjectEpilogue;

(* ---------------------------------------------------------------- *)
(*  RECORD: bit-field layout, WIDTH/MASK, SETFIELD/                  *)
(*  GETFIELD/TESTFLAG/MASKFLAG/SETFLAG/FLIPFLAG                      *)
(* ---------------------------------------------------------------- *)

(* HandleRecordFields: "f1:w1[=v1],f2:w2[=v2],..." -- last-declared
   field occupies bit 0, so shifts must be assigned right-to-left; this requires
   knowing every field's width up front, hence a two-pass parse: first
   collect names/widths into a local scratch, then assign shifts back
   to front. *)
PROCEDURE HandleRecordFields(recName: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR names: ARRAY MaxFields OF Name32; widths: ARRAY MaxFields OF INTEGER;
      n, i, len, k, shift, totalW: INTEGER; name: Name32; wStr: ARRAY 8 OF CHAR;
      valStr: ARRAY 32 OF CHAR; valStart: WORD;
BEGIN
  n := 0; len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE (i < len) & (n < MaxFields) DO
    i := SkipBlanks(rest, i, len);
    name[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], name); INC(i) END;
    i := SkipBlanks(rest, i, len);
    wStr[0] := 0X;
    IF (i < len) & (rest[i] = ":") THEN
      INC(i); i := SkipBlanks(rest, i, len);
      WHILE (i < len) & SYSTEM.ISDIGIT(rest[i]) DO AppendChar(rest[i], wStr); INC(i) END
    END;
    (* skip an optional "=value" default -- not needed for WIDTH/MASK *)
    WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    IF (name[0] # 0X) & (wStr[0] # 0X) THEN
      Strings.Copy(name, names[n]);
      valStr[0] := 0X; Strings.Copy(wStr, valStr);
      valStart := 0;
      widths[n] := INTEGER(Strings.Val(valStr, valStart));
      INC(n)
    END
  END;
  totalW := 0; k := 0;
  WHILE k < n DO INC(totalW, widths[k]); INC(k) END;
  shift := 0; k := n - 1;
  WHILE k >= 0 DO
    IF recFieldCount < MaxFields THEN
      Strings.Copy(recName, recFieldRec[recFieldCount]);
      Strings.Copy(names[k], recFieldName[recFieldCount]);
      recFieldWidth[recFieldCount] := widths[k];
      recFieldShift[recFieldCount] := shift;
      INC(recFieldCount)
    END;
    INC(shift, widths[k]);
    DEC(k)
  END;
  (* also register the RECORD name itself (fieldName = recName) so
     "WIDTH recname"/"MASK recname" resolve to the whole-record form *)
  IF recFieldCount < MaxFields THEN
    Strings.Copy(recName, recFieldRec[recFieldCount]);
    Strings.Copy(recName, recFieldName[recFieldCount]);
    recTotalWidth[recFieldCount] := totalW;
    recFieldWidth[recFieldCount] := totalW;
    recFieldShift[recFieldCount] := 0;
    INC(recFieldCount)
  END
END HandleRecordFields;

(* HandleFieldOp: SETFIELD/GETFIELD/TESTFLAG/MASKFLAG/SETFLAG/FLIPFLAG
   fieldname operand[,operand] -- all reduce to a mask/shift built from
   the field's recorded width+shift, via an OR/AND/TEST/XOR
   mapping. *)
(* ParseFieldWidthOperand: "dest, MASK fieldname" or "dest, WIDTH fieldname"
   -- the TESTFLAG/MASKFLAG/SETFLAG/FLIPFLAG operand shape. dest and
   the field name are extracted; the leading MASK/WIDTH keyword itself
   is not needed since HandleFieldOp always computes a mask from the
   field regardless. *)
PROCEDURE ParseFieldWidthOperand(rest: ARRAY OF CHAR; VAR dest: ARRAY OF CHAR; VAR fname: ARRAY OF CHAR);
  VAR i, len: INTEGER; word: Name32;
BEGIN
  dest[0] := 0X; fname[0] := 0X;
  len := INTEGER(Strings.Length(rest)); i := SkipBlanks(rest, 0, len);
  WHILE (i < len) & (rest[i] # ",") DO AppendChar(rest[i], dest); INC(i) END;
  Strings.RTrim(dest);
  IF (i < len) & (rest[i] = ",") THEN INC(i) END;
  i := SkipBlanks(rest, i, len);
  word[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
  IF Strings.EqualICase(word, "MASK") OR Strings.EqualICase(word, "WIDTH") THEN
    i := SkipBlanks(rest, i, len);
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], fname); INC(i) END
  ELSE
    Strings.Copy(word, fname)  (* bare field name with no MASK/WIDTH prefix *)
  END
END ParseFieldWidthOperand;

PROCEDURE HandleFieldOp(kind: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; fname: Name32; idx: INTEGER;
      op1, op2: ARRAY MaxLine OF CHAR; line, shiftStr, maskStr: ARRAY MaxLine OF CHAR;
      maskVal: LONGINT; isFlagForm: BOOLEAN;
BEGIN
  isFlagForm := Strings.EqualICase(kind, "TESTFLAG") OR Strings.EqualICase(kind, "MASKFLAG")
    OR Strings.EqualICase(kind, "SETFLAG") OR Strings.EqualICase(kind, "FLIPFLAG");

  IF isFlagForm THEN
    (* "dest, MASK fieldname" shape *)
    ParseFieldWidthOperand(rest, op1, fname)
  ELSE
    (* SETFIELD/GETFIELD: "fieldname dest,src" shape *)
    len := INTEGER(Strings.Length(rest));
    i := SkipBlanks(rest, 0, len);
    fname[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], fname); INC(i) END;
    i := SkipBlanks(rest, i, len);
    op1[0] := 0X;
    WHILE (i < len) & (rest[i] # ",") DO AppendChar(rest[i], op1); INC(i) END;
    Strings.RTrim(op1);
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    op2[0] := 0X;
    WHILE i < len DO AppendChar(rest[i], op2); INC(i) END;
    Strings.Trim(op2)
  END;

  IF ~FindRecField(fname, idx) THEN
    EmitNote("SETFIELD/GETFIELD/xFLAG field name not a previously-declared RECORD field -- left as a plain comment");
    Emit2("; ", rest);
    RETURN
  END;
  shiftStr[0] := 0X; IntToStr(recFieldShift[idx], shiftStr);
  maskVal := (Pow2(recFieldWidth[idx]) - 1) * Pow2(recFieldShift[idx]);
  maskStr[0] := 0X; Strings.AppendInt(maskVal, maskStr);

  line[0] := 0X;
  IF Strings.EqualICase(kind, "SETFIELD") THEN
    (* op1 = destination r/m, op2 = source reg (same-size, pre-shift by
       the caller-managed "operating register" convention) -- emit the
       shift+OR; does NOT clear the field first
       (SETFIELD does not attempt to clear the target field). *)
    IF recFieldShift[idx] > 0 THEN
      Strings.Append("shl ", line); Strings.Append(op2, line); Strings.Append(", ", line);
      Strings.Append(shiftStr, line); Emit(line)
    END;
    line[0] := 0X; Strings.Append("or ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(op2, line);
    Emit(line)
  ELSIF Strings.EqualICase(kind, "GETFIELD") THEN
    (* op1 = destination reg, op2 = source r/m *)
    line[0] := 0X; Strings.Append("mov ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(op2, line);
    Emit(line);
    line[0] := 0X; Strings.Append("and ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(maskStr, line);
    Emit(line);
    IF recFieldShift[idx] > 0 THEN
      line[0] := 0X; Strings.Append("shr ", line); Strings.Append(op1, line);
      Strings.Append(", ", line); Strings.Append(shiftStr, line);
      Emit(line)
    END
  ELSIF Strings.EqualICase(kind, "TESTFLAG") THEN
    line[0] := 0X; Strings.Append("test ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(maskStr, line); Emit(line)
  ELSIF Strings.EqualICase(kind, "MASKFLAG") THEN
    line[0] := 0X; Strings.Append("and ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(maskStr, line); Emit(line)
  ELSIF Strings.EqualICase(kind, "SETFLAG") THEN
    line[0] := 0X; Strings.Append("or ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(maskStr, line); Emit(line)
  ELSIF Strings.EqualICase(kind, "FLIPFLAG") THEN
    line[0] := 0X; Strings.Append("xor ", line); Strings.Append(op1, line);
    Strings.Append(", ", line); Strings.Append(maskStr, line); Emit(line)
  END
END HandleFieldOp;

PROCEDURE IsFieldOpWord(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EqualICase(w, "SETFIELD") OR Strings.EqualICase(w, "GETFIELD")
    OR Strings.EqualICase(w, "TESTFLAG") OR Strings.EqualICase(w, "MASKFLAG")
    OR Strings.EqualICase(w, "SETFLAG") OR Strings.EqualICase(w, "FLIPFLAG")
END IsFieldOpWord;

(* ---------------------------------------------------------------- *)
(*  OOP: STRUC ... METHOD { } / TBLINST / TBLINIT /                  *)
(*  CALL..METHOD                                                     *)
(* ---------------------------------------------------------------- *)

(* ParseMethodTable: "{ [VIRTUAL] name:type = proc [, ...] }" (braces
   already stripped by the caller). Populates methodName/methodProc/
   methodVirt.  type WORD -> NEAR method pointer, DWORD -> FAR. *)
PROCEDURE ParseMethodTable(body: ARRAY OF CHAR);
  VAR i, len: INTEGER; word, tname, proc: Name32; virt: BOOLEAN;
BEGIN
  methodCount := 0;
  len := INTEGER(Strings.Length(body)); i := 0;
  WHILE (i < len) & (methodCount < MaxMethods) DO
    i := SkipBlanks(body, i, len);
    virt := FALSE;
    word[0] := 0X;
    WHILE (i < len) & IsIdentChar(body[i]) DO AppendChar(body[i], word); INC(i) END;
    IF Strings.EqualICase(word, "VIRTUAL") THEN
      virt := TRUE; i := SkipBlanks(body, i, len);
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(body[i]) DO AppendChar(body[i], word); INC(i) END
    END;
    i := SkipBlanks(body, i, len);
    tname[0] := 0X;
    IF (i < len) & (body[i] = ":") THEN
      INC(i); i := SkipBlanks(body, i, len);
      WHILE (i < len) & IsIdentChar(body[i]) DO AppendChar(body[i], tname); INC(i) END
    END;
    i := SkipBlanks(body, i, len);
    proc[0] := 0X;
    IF (i < len) & (body[i] = "=") THEN
      INC(i); i := SkipBlanks(body, i, len);
      WHILE (i < len) & IsIdentChar(body[i]) DO AppendChar(body[i], proc); INC(i) END
    END;
    (* entries are comma-separated on one line (TABLE-style
       compact form) OR simply newline/whitespace-separated, one per
       line, with no trailing comma at all -- braceBody has newlines flattened to a
       single space by DetectMethodTable, so only swallow an actual
       comma here; whitespace before the next entry is already skipped
       by the next iteration's own leading SkipBlanks. *)
    IF (i < len) & (body[i] = ",") THEN INC(i) END;
    IF word[0] # 0X THEN
      Strings.Copy(word, methodName[methodCount]);
      Strings.Copy(proc, methodProc[methodCount]);
      methodVirt[methodCount] := virt;
      INC(methodCount)
    END
  END
END ParseMethodTable;

(* EmitObjectStruc: emit the NASM struc for the current object: a
   leading @Mptr_<name> field (WORD or DWORD per objDist) followed by
   the plain data members (handled line-by-line afterward, same as any
   other open STRUC).  Static (non-VIRTUAL) methods contribute no
   storage (manual: "non-VIRTUAL members occupy no space") so are
   skipped here; virtual methods are what the VMT (not the instance)
   holds -- see EmitVmt. *)
PROCEDURE EmitObjectStruc(name: ARRAY OF CHAR; dist: INTEGER);
  VAR line: ARRAY MaxLine OF CHAR;
BEGIN
  Emit2("struc ", name);
  line[0] := 0X;
  Strings.Append("  .@Mptr_", line); Strings.Append(name, line);
  IF dist = DistFar THEN Strings.Append(": resd 1", line) ELSE Strings.Append(": resw 1", line) END;
  Emit(line)
END EmitObjectStruc;

(* EmitVmt: emit the object's single VMT instance (TBLINST -- "creates
   a table for the most recently declared object") as a NASM data
   label holding one pointer-sized slot per VIRTUAL method, in
   declared order, initialized to that method's implementing
   procedure. *)
PROCEDURE EmitVmt(name: ARRAY OF CHAR; dist: INTEGER);
  VAR k: INTEGER; line: ARRAY MaxLine OF CHAR;
BEGIN
  line[0] := 0X;
  Strings.Append("@TableAddr_", line); Strings.Append(name, line); Strings.Append(":", line);
  Emit(line);
  k := 0;
  WHILE k < methodCount DO
    IF methodVirt[k] THEN
      line[0] := 0X;
      IF dist = DistFar THEN Strings.Append("  dd ", line) ELSE Strings.Append("  dw ", line) END;
      Strings.Append(methodProc[k], line);
      Strings.Append("   ; .", line); Strings.Append(methodName[k], line);
      Emit(line)
    END;
    INC(k)
  END
END EmitVmt;

(* MethodOffsetInVmt: byte offset of a named virtual method's slot
   within the VMT built by EmitVmt (declaration order, pointer-sized
   slots). *)
PROCEDURE MethodOffsetInVmt(name: ARRAY OF CHAR; dist: INTEGER; VAR ofs: INTEGER): BOOLEAN;
  VAR k, slot, sz: INTEGER;
BEGIN
  IF dist = DistFar THEN sz := 4 ELSE sz := 2 END;
  slot := 0; k := 0;
  WHILE k < methodCount DO
    IF methodVirt[k] THEN
      IF Strings.Equal(methodName[k], name) THEN ofs := slot * sz; RETURN TRUE END;
      INC(slot)
    END;
    INC(k)
  END;
  RETURN FALSE
END MethodOffsetInVmt;

PROCEDURE FindStaticMethod(name: ARRAY OF CHAR; VAR proc: Name32): BOOLEAN;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < methodCount DO
    IF Strings.Equal(methodName[k], name) & ~methodVirt[k] THEN
      Strings.Copy(methodProc[k], proc); RETURN TRUE
    END;
    INC(k)
  END;
  RETURN FALSE
END FindStaticMethod;

(* HandleTblinit: "TBLINIT seg:reg" inside an init method -- stores the
   VMT address into the instance's @Mptr_<obj> field. *)
PROCEDURE HandleTblinit(rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; segPart, regPart: Name32; line: ARRAY MaxLine OF CHAR;
BEGIN
  Trimmed(rest, segPart);
  len := INTEGER(Strings.Length(segPart)); i := 0;
  regPart[0] := 0X;
  WHILE (i < len) & (segPart[i] # ":") DO INC(i) END;
  IF i < len THEN
    Strings.Extract(segPart, 0, WORD(i), segPart);
    Strings.Extract(rest, WORD(i)+1, Strings.Length(rest) - (WORD(i)+1), regPart);
    Strings.Trim(regPart)
  END;
  line[0] := 0X;
  Strings.Append("mov word [", line);
  IF segPart[0] # 0X THEN Strings.Append(segPart, line); Strings.Append(":", line) END;
  Strings.Append(regPart, line);
  Strings.Append("+@Mptr_", line); Strings.Append(objName, line);
  Strings.Append("], @TableAddr_", line); Strings.Append(objName, line);
  Emit(line)
END HandleTblinit;

(* IsLanguageWord: one of the high-level calling-convention keywords
   the extended CALL syntax accepts. *)
PROCEDURE IsLanguageWord(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN Strings.EqualICase(w, "PASCAL") OR Strings.EqualICase(w, "BASIC")
    OR Strings.EqualICase(w, "FORTRAN") OR Strings.EqualICase(w, "C")
    OR Strings.EqualICase(w, "CPP") OR Strings.EqualICase(w, "SYSCALL")
    OR Strings.EqualICase(w, "STDCALL") OR Strings.EqualICase(w, "PROLOG")
    OR Strings.EqualICase(w, "NOLANGUAGE")
END IsLanguageWord;

(* SplitTopLevelCommas: split s on commas into out[0..n), each entry
   trimmed.  Arguments are separated by commas; components of one
   argument by spaces -- a single argument
   like "es OFFSET buffer" must stay together as one array entry, which
   a plain comma-split already gives since spaces inside one argument
   never contain a comma. *)
PROCEDURE SplitTopLevelCommas(s: ARRAY OF CHAR; VAR out: ArgList; VAR n: INTEGER; maxN: INTEGER);
  VAR i, len, start: INTEGER; item: ARRAY MaxLine OF CHAR;
BEGIN
  n := 0;
  len := INTEGER(Strings.Length(s)); i := 0; start := 0;
  WHILE (i <= len) & (n < maxN) DO
    IF (i = len) OR (s[i] = ",") THEN
      item[0] := 0X;
      Strings.Extract(s, WORD(start), WORD(i - start), item);
      Strings.Trim(item);
      IF item[0] # 0X THEN Strings.Copy(item, out[n]); INC(n) END;
      start := i + 1
    END;
    INC(i)
  END
END SplitTopLevelCommas;

(* EmitArgPushes: emit one "push" per space-separated component of a
   single CALL argument, in the order written --
   only whole arguments get reordered by language, never the pieces
   within one). A bracketed memory operand ("[bx+4]") stays one piece
   even though it contains no spaces itself; "OFFSET name" is two
   space-separated tokens in the source but is one logical push in
   NASM (a bare label already IS its offset), so "OFFSET" is dropped
   and only "name" is pushed for that component. *)
PROCEDURE EmitArgPushes(arg: ARRAY OF CHAR);
  VAR i, len: INTEGER; comp: ARRAY MaxLine OF CHAR; rewritten: ARRAY MaxLine OF CHAR;
      line: ARRAY MaxLine OF CHAR; depth: INTEGER; sized: ARRAY MaxLine OF CHAR;
BEGIN
  len := INTEGER(Strings.Length(arg)); i := 0;
  WHILE i < len DO
    i := SkipBlanks(arg, i, len);
    comp[0] := 0X; depth := 0;
    WHILE (i < len) & ((depth > 0) OR ~SYSTEM.ISSPACE(arg[i])) DO
      IF arg[i] = "[" THEN INC(depth) ELSIF arg[i] = "]" THEN DEC(depth) END;
      AppendChar(arg[i], comp); INC(i)
    END;
    IF Strings.EqualICase(comp, "OFFSET") THEN
      (* fold into the next component: a bare label already IS its
         offset in NASM, so skip emitting a push for "OFFSET" itself *)
    ELSIF IsSizeWord(comp) THEN
      (* "WORD [PTR] operand" is one type-cast unit -- glue the next
         one or two space-separated tokens (an optional PTR, then the
         operand itself) onto this component before emitting *)
      i := SkipBlanks(arg, i, len);
      IF (i+2 < len) & (SYSTEM.UCASE(arg[i])="P") & (SYSTEM.UCASE(arg[i+1])="T")
         & (SYSTEM.UCASE(arg[i+2])="R") & ((i+3>=len) OR SYSTEM.ISSPACE(arg[i+3])) THEN
        i := i + 3; i := SkipBlanks(arg, i, len)
      END;
      AppendChar(" ", comp);
      WHILE (i < len) & ~SYSTEM.ISSPACE(arg[i]) DO AppendChar(arg[i], comp); INC(i) END;
      line[0] := 0X; Strings.Append("push ", line);
      sized[0] := 0X; RewriteOperandSizes(comp, sized);
      rewritten[0] := 0X; RewriteExprWords(sized, rewritten);
      Strings.Append(rewritten, line); Emit(line)
    ELSIF comp[0] # 0X THEN
      line[0] := 0X; Strings.Append("push ", line);
      rewritten[0] := 0X; RewriteExprWords(comp, rewritten);
      Strings.Append(rewritten, line); Emit(line)
    END
  END
END EmitArgPushes;

(* HandleCallLanguage: "CALL target [language] [,arg1,arg2,...]"
   (extended CALL) -- pushes each argument in the order the language
   convention requires (PASCAL/BASIC/FORTRAN: declaration order; C/CPP/
   SYSCALL/STDCALL: reverse order), never
   reordering the space-separated components within one argument (e.g.
   "es OFFSET buffer" pushes "es" then "OFFSET buffer" as two PUSHes,
   both kept adjacent and in that relative order regardless of overall
   reversal). Returns FALSE if the shape doesn't apply (no
   language keyword AND no comma at all -- an ordinary "CALL target"). *)
PROCEDURE HandleCallLanguage(rest: ARRAY OF CHAR): BOOLEAN;
  VAR target, afterTarget: ARRAY MaxLine OF CHAR; i, len: INTEGER;
      word: Name32; lang: INTEGER; hasLang: BOOLEAN;
      args: ArgList; n, k: INTEGER;
BEGIN
  len := INTEGER(Strings.Length(rest));
  i := SkipBlanks(rest, 0, len);
  target[0] := 0X;
  WHILE (i < len) & (rest[i] # ",") & ~SYSTEM.ISSPACE(rest[i]) DO
    AppendChar(rest[i], target); INC(i)
  END;
  i := SkipBlanks(rest, i, len);
  word[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
  hasLang := IsLanguageWord(word);
  lang := LangCallee;
  IF hasLang THEN
    (* Must match HandleProcHeader's own C/CPP/PROLOG/STDCALL ->
       LangCaller classification -- CALL's extended argument-list push
       order has to agree with the PROC header it's calling, or the
       callee's ARG offsets (assigned per HandleFrameList's own
       push-direction walk) land on the wrong pushed values. *)
    IF Strings.EqualICase(word, "C") OR Strings.EqualICase(word, "CPP")
       OR Strings.EqualICase(word, "SYSCALL") OR Strings.EqualICase(word, "PROLOG")
       OR Strings.EqualICase(word, "STDCALL") THEN lang := LangCaller
    ELSE lang := LangCallee END
  ELSE
    i := SkipBlanks(rest, 0, len);
    i := INTEGER(Strings.Length(target))  (* rewind: word wasn't a language keyword *)
  END;
  i := SkipBlanks(rest, i, len);
  IF (i >= len) OR (rest[i] # ",") THEN
    IF ~hasLang THEN RETURN FALSE END  (* plain "CALL target", no args *)
  ELSE
    INC(i)
  END;
  afterTarget[0] := 0X;
  IF i < len THEN Strings.Extract(rest, WORD(i), WORD(len - i), afterTarget) END;

  SplitTopLevelCommas(afterTarget, args, n, 16);
  IF (n = 0) & ~hasLang THEN RETURN FALSE END;

  IF (lang = LangCaller) THEN
    k := n - 1;
    WHILE k >= 0 DO EmitArgPushes(args[k]); DEC(k) END
  ELSE
    k := 0;
    WHILE k < n DO EmitArgPushes(args[k]); INC(k) END
  END;
  Emit2("call ", target);
  EmitNote("extended CALL argument list: pushed per language order (PASCAL/BASIC/FORTRAN=declared, C/CPP/SYSCALL/STDCALL=reversed); callee's own RET epilogue handles stack cleanup");
  RETURN TRUE
END HandleCallLanguage;

(* HandleCallMethod: "CALL instance METHOD [obj:]method [USES ...] [restargs]"
   -- static method -> direct CALL; virtual method -> load VMT pointer
   from the instance then CALL through the table slot, via a
   two-step generated-code recipe (mov reg,[instance.@Mptr_obj]
   / call [reg.method]). *)
(* HandleCallMethod: rest is everything AFTER the "METHOD" keyword
   (caller -- ContainsMethodKeyword -- already found and consumed it,
   using it only to confirm the "instance METHOD ..." shape). *)
PROCEDURE HandleCallMethod(instance: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; word, obj, meth, usesSeg, usesReg, procName: Name32;
      line, tail: ARRAY MaxLine OF CHAR; ofs: INTEGER; ofsStr: ARRAY 8 OF CHAR;
BEGIN
  len := INTEGER(Strings.Length(rest)); i := SkipBlanks(rest, 0, len);
  obj[0] := 0X; meth[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], obj); INC(i) END;
  IF (i < len) & (rest[i] = ":") THEN
    INC(i);
    Strings.Copy(obj, meth); meth[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], meth); INC(i) END
  ELSE
    Strings.Copy(obj, meth); obj[0] := 0X; Strings.Copy(objName, obj)
  END;
  i := SkipBlanks(rest, i, len);
  usesSeg[0] := 0X; usesReg[0] := 0X;
  IF (i+4 <= len) & Strings.EqualICase("", "") THEN END; (* no-op *)
  word[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
  IF Strings.EqualICase(word, "USES") THEN
    i := SkipBlanks(rest, i, len);
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], usesSeg); INC(i) END;
    IF (i < len) & (rest[i] = ":") THEN
      INC(i);
      WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], usesReg); INC(i) END
    ELSE
      Strings.Copy(usesSeg, usesReg); usesSeg[0] := 0X
    END
  END;
  Strings.Extract(rest, WORD(i), Strings.Length(rest) - WORD(i), tail);
  Strings.Trim(tail);

  IF FindStaticMethod(meth, procName) THEN
    line[0] := 0X; Strings.Append("call ", line); Strings.Append(procName, line);
    IF tail[0] # 0X THEN Strings.Append("   ; ", line); Strings.Append(tail, line) END;
    EmitNote("static METHOD call resolved directly (non-VIRTUAL entries are compile-time bound, matching TASM's own codegen)");
    Emit(line)
  ELSIF MethodOffsetInVmt(meth, objDist, ofs) THEN
    line[0] := 0X;
    IF usesReg[0] = 0X THEN Strings.Copy("bx", usesReg) END;
    Strings.Append("mov ", line); Strings.Append(usesReg, line);
    Strings.Append(", [", line); Strings.Append(instance, line);
    Strings.Append(".@Mptr_", line); Strings.Append(obj, line); Strings.Append("]", line);
    Emit(line);
    line[0] := 0X;
    ofsStr[0] := 0X; IntToStr(ofs, ofsStr);
    Strings.Append("call [", line); Strings.Append(usesReg, line);
    Strings.Append("+", line); Strings.Append(ofsStr, line); Strings.Append("]", line);
    IF tail[0] # 0X THEN Strings.Append("   ; ", line); Strings.Append(tail, line) END;
    EmitNote("virtual METHOD call: VMT pointer loaded from the instance, then an indirect call through the table slot");
    Emit(line)
  ELSE
    EmitNote("METHOD name not found in the currently open object's table -- verify by hand");
    Emit2("; call ", rest)
  END
END HandleCallMethod;

(* ---------------------------------------------------------------- *)
(*  MACRO / ENDM / LOCAL(-in-macro) / GOTO-tag                       *)
(* ---------------------------------------------------------------- *)

PROCEDURE ParseParamList(rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; name: Name32;
BEGIN
  macroParamCount := 0;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE (i < len) & (macroParamCount < MaxArgs) DO
    i := SkipBlanks(rest, i, len);
    name[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], name); INC(i) END;
    WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    IF name[0] # 0X THEN
      Strings.Copy(name, macroParams[macroParamCount]); INC(macroParamCount)
    END
  END
END ParseParamList;

PROCEDURE SubstituteMacroParams(src: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len, k: INTEGER; word: Name32; matched: INTEGER; q: CHAR;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src));
  i := 0;
  WHILE i < len DO
    IF (src[i] = 22X) OR (src[i] = 27X) THEN
      q := src[i]; AppendChar(src[i], out); INC(i);
      WHILE (i < len) & (src[i] # q) DO AppendChar(src[i], out); INC(i) END;
      IF i < len THEN AppendChar(src[i], out); INC(i) END
    ELSIF src[i] = "&" THEN
      Strings.Append(" %+ ", out); INC(i)
    ELSIF IsIdentStart(src[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], word); INC(i) END;
      matched := -1; k := 0;
      WHILE k < macroParamCount DO
        IF Strings.Equal(word, macroParams[k]) THEN matched := k END;
        INC(k)
      END;
      IF matched >= 0 THEN
        Strings.Append("%", out); AppendChar(CHR(ORD("1") + matched), out)
      ELSE
        Strings.Append(word, out)
      END
    ELSE
      AppendChar(src[i], out); INC(i)
    END
  END
END SubstituteMacroParams;

(* ---------------------------------------------------------------- *)
(*  ERRxxx family                                                    *)
(* ---------------------------------------------------------------- *)

PROCEDURE ExtractMessage(rest: ARRAY OF CHAR; VAR msg: ARRAY OF CHAR);
  VAR i, len: INTEGER;
BEGIN
  msg[0] := 0X;
  len := INTEGER(Strings.Length(rest));
  i := 0;
  WHILE (i < len) & (rest[i] # 22X) & (rest[i] # 27X) DO INC(i) END;
  IF i < len THEN Strings.Extract(rest, WORD(i), WORD(len - i), msg) END;
  IF msg[0] = 0X THEN Strings.Copy('"t2nasm: ERR directive"', msg) END
END ExtractMessage;

(* ---------------------------------------------------------------- *)
(*  main per-line dispatcher                                         *)
(* ---------------------------------------------------------------- *)

PROCEDURE IsKnownDirective(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF w[0] = 0X THEN RETURN FALSE END;
  RETURN Strings.EqualICase(w, "SEGMENT") OR Strings.EqualICase(w, "ENDS")
    OR Strings.EqualICase(w, "GROUP") OR Strings.EqualICase(w, "PROC")
    OR Strings.EqualICase(w, "ENDP") OR Strings.EqualICase(w, "STRUC")
    OR Strings.EqualICase(w, "UNION") OR Strings.EqualICase(w, "RECORD")
    OR Strings.EqualICase(w, "TYPEDEF") OR Strings.EqualICase(w, "LABEL")
    OR Strings.EqualICase(w, "MACRO") OR Strings.EqualICase(w, "ENDM")
    OR Strings.EqualICase(w, "EQU") OR Strings.EqualICase(w, "=")
    OR Strings.EqualICase(w, "ENUM") OR Strings.EqualICase(w, "TABLE")
    OR Strings.EqualICase(w, "PROCTYPE") OR Strings.EqualICase(w, "PROCDESC")
    OR Strings.EqualICase(w, "CATSTR") OR Strings.EqualICase(w, "SUBSTR")
    OR Strings.EqualICase(w, "SIZESTR")
    OR Strings.EqualICase(w, "DB") OR Strings.EqualICase(w, "DW")
    OR Strings.EqualICase(w, "DD") OR Strings.EqualICase(w, "DQ")
    OR Strings.EqualICase(w, "DT") OR Strings.EqualICase(w, "DF")
    OR Strings.EqualICase(w, "DP") OR Strings.EqualICase(w, "RECORD")
END IsKnownDirective;

PROCEDURE IsGlobalDirectiveWord(w: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN IsKnownDirective(w)
    OR Strings.EqualICase(w, "DB") OR Strings.EqualICase(w, "DW")
    OR Strings.EqualICase(w, "DD") OR Strings.EqualICase(w, "DQ")
    OR Strings.EqualICase(w, "DT") OR Strings.EqualICase(w, "DF")
    OR Strings.EqualICase(w, "DP") OR Strings.EqualICase(w, "PUBLIC")
    OR Strings.EqualICase(w, "EXTRN") OR Strings.EqualICase(w, "EXTERN")
    OR Strings.EqualICase(w, "GLOBAL") OR Strings.EqualICase(w, "COMM")
    OR Strings.EqualICase(w, "INCLUDE") OR Strings.EqualICase(w, "INCLUDELIB")
    OR Strings.EqualICase(w, "ALIAS") OR Strings.EqualICase(w, "ARG")
    OR Strings.EqualICase(w, "LOCAL") OR Strings.EqualICase(w, "USES")
    OR Strings.EqualICase(w, "IFDEF") OR Strings.EqualICase(w, "IFNDEF")
    OR Strings.EqualICase(w, "IF") OR Strings.EqualICase(w, "IFE")
    OR Strings.EqualICase(w, "ELSEIF") OR Strings.EqualICase(w, "ELSEIFE")
    OR Strings.EqualICase(w, "ELSEIFDEF") OR Strings.EqualICase(w, "ELSEIFNDEF")
    OR Strings.EqualICase(w, "ELSE") OR Strings.EqualICase(w, "ENDIF")
    OR Strings.EqualICase(w, "IFIDN") OR Strings.EqualICase(w, "IFIDNI")
    OR Strings.EqualICase(w, "IFDIF") OR Strings.EqualICase(w, "IFDIFI")
    OR Strings.EqualICase(w, "IFB") OR Strings.EqualICase(w, "IFNB")
    OR Strings.EqualICase(w, "IF1") OR Strings.EqualICase(w, "IF2")
    OR Strings.EqualICase(w, "REPT") OR Strings.EqualICase(w, "WHILE")
    OR Strings.EqualICase(w, "IRP") OR Strings.EqualICase(w, "IRPC")
    OR Strings.EqualICase(w, "EXITM") OR Strings.EqualICase(w, "PURGE")
    OR Strings.EqualICase(w, "GOTO") OR Strings.EqualICase(w, "ERR")
    OR Strings.EqualICase(w, "ERRIFDEF") OR Strings.EqualICase(w, "ERRIFNDEF")
    OR Strings.EqualICase(w, "ORG") OR Strings.EqualICase(w, "EVEN")
    OR Strings.EqualICase(w, "EVENDATA") OR Strings.EqualICase(w, "ALIGN")
    OR Strings.EqualICase(w, "ASSUME") OR Strings.EqualICase(w, "RADIX")
    OR Strings.EqualICase(w, ".RADIX") OR Strings.EqualICase(w, "IDEAL")
    OR Strings.EqualICase(w, "MASM") OR Strings.EqualICase(w, "END")
    OR IsFieldOpWord(w)
    OR Strings.EqualICase(w, "NAME") OR Strings.EqualICase(w, "VERSION")
    OR Strings.EqualICase(w, "DOSSEG") OR Strings.EqualICase(w, ".SEQ")
    OR Strings.EqualICase(w, "LOCALS") OR Strings.EqualICase(w, "NOLOCALS")
    OR Strings.EqualICase(w, "WARN") OR Strings.EqualICase(w, "NOWARN")
    OR Strings.EqualICase(w, "DISPLAY") OR Strings.EqualICase(w, "%OUT")
    OR Strings.EqualICase(w, ".8086") OR Strings.EqualICase(w, ".186")
    OR Strings.EqualICase(w, ".286") OR Strings.EqualICase(w, ".286C")
    OR Strings.EqualICase(w, ".286P") OR Strings.EqualICase(w, ".386")
    OR Strings.EqualICase(w, ".386C") OR Strings.EqualICase(w, ".386P")
    OR Strings.EqualICase(w, ".486") OR Strings.EqualICase(w, ".486C")
    OR Strings.EqualICase(w, ".486P") OR Strings.EqualICase(w, ".586")
    OR Strings.EqualICase(w, ".586C") OR Strings.EqualICase(w, ".586P")
    OR Strings.EqualICase(w, ".8087") OR Strings.EqualICase(w, ".287")
    OR Strings.EqualICase(w, ".387") OR Strings.EqualICase(w, ".487")
    OR Strings.EqualICase(w, ".587")
    OR Strings.EqualICase(w, ".MODEL") OR Strings.EqualICase(w, "MODEL")
    OR Strings.EqualICase(w, "STARTUPCODE") OR Strings.EqualICase(w, ".STARTUP")
    OR Strings.EqualICase(w, "EXITCODE") OR Strings.EqualICase(w, ".EXIT")
    OR Strings.EqualICase(w, "CODESEG") OR Strings.EqualICase(w, ".CODE")
    OR Strings.EqualICase(w, "DATASEG") OR Strings.EqualICase(w, ".DATA")
    OR Strings.EqualICase(w, "CONST") OR Strings.EqualICase(w, ".CONST")
    OR Strings.EqualICase(w, "UDATASEG") OR Strings.EqualICase(w, ".DATA?")
    OR Strings.EqualICase(w, "STACK") OR Strings.EqualICase(w, ".STACK")
    OR Strings.EqualICase(w, "FARDATA") OR Strings.EqualICase(w, ".FARDATA")
    OR Strings.EqualICase(w, "UFARDATA") OR Strings.EqualICase(w, ".FARDATA?")
    OR Strings.EqualICase(w, "SEGMENT") OR Strings.EqualICase(w, "ENDS")
    OR Strings.EqualICase(w, "GROUP") OR Strings.EqualICase(w, "PROC")
    OR Strings.EqualICase(w, "ENDP") OR Strings.EqualICase(w, "STRUC")
    OR Strings.EqualICase(w, "UNION") OR Strings.EqualICase(w, "RECORD")
    OR Strings.EqualICase(w, "TYPEDEF") OR Strings.EqualICase(w, "LABEL")
    OR Strings.EqualICase(w, "TABLE") OR Strings.EqualICase(w, "PROCTYPE")
    OR Strings.EqualICase(w, "PROCDESC") OR Strings.EqualICase(w, "MACRO")
    OR Strings.EqualICase(w, "ENDM") OR Strings.EqualICase(w, "EQU")
    OR Strings.EqualICase(w, "ENUM") OR Strings.EqualICase(w, "CATSTR")
    OR Strings.EqualICase(w, "SUBSTR") OR Strings.EqualICase(w, "SIZESTR")
    OR Strings.EqualICase(w, "INSTR")
END IsGlobalDirectiveWord;

(* HandleAssignRhs used by the "name = expr" %assign path. *)
PROCEDURE HandleAssignRhs(rest: ARRAY OF CHAR; VAR line: ARRAY OF CHAR);
  VAR sized, rewritten: ARRAY MaxLine OF CHAR;
BEGIN
  RewriteWidthMask(rest, sized);
  RewriteExprWords(sized, rewritten);
  Strings.Append(rewritten, line)
END HandleAssignRhs;

(* ---------------------------------------------------------------- *)
(*  ENUM: auto-incrementing constant list                            *)
(* ---------------------------------------------------------------- *)

PROCEDURE HandleEnum(rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; name, valStr: Name32; line: ARRAY MaxLine OF CHAR;
      next: LONGINT; explicit: BOOLEAN; valStart: WORD;
BEGIN
  next := 0;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE i < len DO
    i := SkipBlanks(rest, i, len);
    name[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], name); INC(i) END;
    i := SkipBlanks(rest, i, len);
    explicit := FALSE; valStr[0] := 0X;
    IF (i < len) & (rest[i] = "=") THEN
      INC(i); i := SkipBlanks(rest, i, len);
      WHILE (i < len) & (rest[i] # ",") DO AppendChar(rest[i], valStr); INC(i) END;
      Strings.RTrim(valStr); explicit := TRUE
    END;
    WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    IF name[0] # 0X THEN
      line[0] := 0X;
      Strings.Append("%assign ", line); Strings.Append(name, line); Strings.Append(" ", line);
      IF explicit THEN
        Strings.Append(valStr, line);
        valStart := 0;
        next := Strings.Val(valStr, valStart) + 1
      ELSE
        valStr[0] := 0X; Strings.AppendInt(next, valStr);
        Strings.Append(valStr, line);
        INC(next)
      END;
      Emit(line)
    END
  END
END HandleEnum;

(* ---------------------------------------------------------------- *)
(*  IRP / IRPC: fully expanded at conversion time (the list/string is *)
(*  already known text, unlike a real macro parameter) -- one pass    *)
(*  substituting the dummy argument (character-by-character for IRPC,*)
(*  raw token splice).                                                *)
(* ---------------------------------------------------------------- *)

(* CaptureBlockBody: read lines from src up to (not including) the
   matching ENDM, returned as up to MaxIrpLines raw lines.  Used by
   HandleIrp/HandleIrpc, which must see the whole body before they can
   emit N substituted copies of it. *)

CONST MaxIrpLines = 40;

VAR irpBody: ARRAY MaxIrpLines OF ARRAY MaxLine OF CHAR;

PROCEDURE CaptureIrpBody(VAR n: INTEGER);
  VAR raw: ARRAY MaxLine OF CHAR; commentAt: INTEGER; code: ARRAY MaxLine OF CHAR;
      w: Name32; depth: INTEGER;
BEGIN
  n := 0; depth := 0;
  WHILE (n < MaxIrpLines) & ~Files.Eof(srcFile) DO
    IF (Files.ReadLine(srcFile, raw, LEN(raw)) # 0) OR (raw[0] # 0X) THEN
      commentAt := FindCommentStart(raw);
      Strings.Extract(raw, 0, WORD(commentAt), code); Strings.Trim(code);
      IF code[0] # 0X THEN
        w[0] := 0X; SplitWord(code, 0, INTEGER(Strings.Length(code)), w);
        IF Strings.EqualICase(w, "ENDM") & (depth = 0) THEN RETURN END;
        IF Strings.EqualICase(w, "REPT") OR Strings.EqualICase(w, "IRP")
           OR Strings.EqualICase(w, "IRPC") OR Strings.EqualICase(w, "WHILE") THEN
          INC(depth)
        ELSIF Strings.EqualICase(w, "ENDM") THEN
          DEC(depth)
        END
      END;
      Strings.Copy(raw, irpBody[n]); INC(n)
    END
  END
END CaptureIrpBody;

(* SubstituteDummy: whole-word replace of dummyName with value across
   one captured body line (used for IRP; IRPC uses a raw single-char
   splice instead of quoting the character for the caller). *)
PROCEDURE SubstituteDummy(src: ARRAY OF CHAR; dummyName: ARRAY OF CHAR; value: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len: INTEGER; word: Name32; q: CHAR;
BEGIN
  out[0] := 0X;
  len := INTEGER(Strings.Length(src)); i := 0;
  WHILE i < len DO
    IF (src[i] = 22X) OR (src[i] = 27X) THEN
      q := src[i]; AppendChar(src[i], out); INC(i);
      WHILE (i < len) & (src[i] # q) DO AppendChar(src[i], out); INC(i) END;
      IF i < len THEN AppendChar(src[i], out); INC(i) END
    ELSIF IsIdentStart(src[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(src[i]) DO AppendChar(src[i], word); INC(i) END;
      IF Strings.Equal(word, dummyName) THEN Strings.Append(value, out)
      ELSE Strings.Append(word, out) END
    ELSE
      AppendChar(src[i], out); INC(i)
    END
  END
END SubstituteDummy;

PROCEDURE HandleIrp(rest: ARRAY OF CHAR);
  VAR dummy, item: Name32; i, len, n, k: INTEGER; listPart: ARRAY MaxLine OF CHAR;
      substituted: ARRAY MaxLine OF CHAR;
BEGIN
  len := INTEGER(Strings.Length(rest)); i := SkipBlanks(rest, 0, len);
  dummy[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], dummy); INC(i) END;
  WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
  IF (i < len) & (rest[i] = ",") THEN INC(i) END;
  listPart[0] := 0X; Strings.Extract(rest, WORD(i), WORD(len - i), listPart);
  Strings.Trim(listPart);
  (* strip optional <...> wrapping *)
  IF (listPart[0] = "<") THEN
    len := INTEGER(Strings.Length(listPart));
    IF listPart[len-1] = ">" THEN Strings.Extract(listPart, 1, WORD(len-2), listPart) END
  END;

  CaptureIrpBody(n);
  EmitNote("IRP expanded inline at conversion time (item list is compile-time-known text, unlike a real macro %rep)");
  len := INTEGER(Strings.Length(listPart)); i := 0;
  WHILE i < len DO
    i := SkipBlanks(listPart, i, len);
    item[0] := 0X;
    WHILE (i < len) & (listPart[i] # ",") DO AppendChar(listPart[i], item); INC(i) END;
    Strings.RTrim(item);
    IF (i < len) & (listPart[i] = ",") THEN INC(i) END;
    IF item[0] # 0X THEN
      k := 0;
      WHILE k < n DO
        SubstituteDummy(irpBody[k], dummy, item, substituted);
        Emit(substituted); INC(k)
      END
    END
  END
END HandleIrp;

PROCEDURE HandleIrpc(rest: ARRAY OF CHAR);
  VAR dummy: Name32; i, len, n, k: INTEGER; str: ARRAY MaxLine OF CHAR;
      one: ARRAY 2 OF CHAR; substituted: ARRAY MaxLine OF CHAR;
BEGIN
  len := INTEGER(Strings.Length(rest)); i := SkipBlanks(rest, 0, len);
  dummy[0] := 0X;
  WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], dummy); INC(i) END;
  WHILE (i < len) & (rest[i] # ",") DO INC(i) END;
  IF (i < len) & (rest[i] = ",") THEN INC(i) END;
  str[0] := 0X; Strings.Extract(rest, WORD(i), WORD(len - i), str); Strings.Trim(str);

  CaptureIrpBody(n);
  EmitNote("IRPC expanded inline character-by-character, spliced as a raw token per character -- quote the dummy inside the body yourself if you need a character literal, not a bare symbol");
  len := INTEGER(Strings.Length(str)); i := 0;
  WHILE i < len DO
    IF ~SYSTEM.ISSPACE(str[i]) THEN
      one[0] := str[i]; one[1] := 0X;
      k := 0;
      WHILE k < n DO
        SubstituteDummy(irpBody[k], dummy, one, substituted);
        Emit(substituted); INC(k)
      END
    END;
    INC(i)
  END
END HandleIrpc;

(* ---------------------------------------------------------------- *)
(*  CATSTR helper                                                    *)
(* ---------------------------------------------------------------- *)

PROCEDURE ConcatCommaListWithPlus(rest: ARRAY OF CHAR; VAR out: ARRAY OF CHAR);
  VAR i, len: INTEGER; item: ARRAY MaxLine OF CHAR; first: BOOLEAN;
BEGIN
  out[0] := 0X; first := TRUE;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE i < len DO
    i := SkipBlanks(rest, i, len);
    item[0] := 0X;
    WHILE (i < len) & (rest[i] # ",") DO AppendChar(rest[i], item); INC(i) END;
    Strings.RTrim(item);
    IF (i < len) & (rest[i] = ",") THEN INC(i) END;
    IF item[0] # 0X THEN
      IF ~first THEN Strings.Append(" %+ ", out) END;
      Strings.Append(item, out); first := FALSE
    END
  END
END ConcatCommaListWithPlus;

(* ---------------------------------------------------------------- *)
(*  PROC header parsing (distance + language convention)             *)
(* ---------------------------------------------------------------- *)

PROCEDURE HandleProcHeader(label: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR i, len: INTEGER; word: Name32; dist: INTEGER; lang: INTEGER;
      procName: Name32; sawName: BOOLEAN;
BEGIN
  dist := DistNear; lang := LangCallee;   (* TASM default distance follows the
    current model (unknown here, default NEAR is the common case); default
    language convention if unspecified is left as the callee-cleans-stack
    family since that is TASM's own factory default (PASCAL) absent a
    model/language directive -- reviewed via the note below when relevant *)
  (* MASM form: "Name PROC ..." -- label already carries the proc name,
     rest is only distance/language/ARG.  Ideal form: "PROC Name ..." --
     label is empty, and the very first word of rest IS the proc name
     (must be captured before the distance/language scan below, or it
     falls through to the ARG/LOCAL/USES noise branch and the proc's own
     label is silently lost -- see the ':' with no name bug this fixed). *)
  procName[0] := 0X; sawName := FALSE;
  IF label[0] # 0X THEN Strings.Copy(label, procName); sawName := TRUE END;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE i < len DO
    i := SkipBlanks(rest, i, len);
    word[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
    IF word[0] = 0X THEN i := len
    ELSIF Strings.EqualICase(word, "NEAR") THEN dist := DistNear
    ELSIF Strings.EqualICase(word, "FAR") THEN dist := DistFar
    ELSIF Strings.EqualICase(word, "NOLANGUAGE") THEN lang := LangNone
    ELSIF Strings.EqualICase(word, "PASCAL") OR Strings.EqualICase(word, "BASIC")
       OR Strings.EqualICase(word, "FORTRAN") THEN lang := LangCallee
    ELSIF Strings.EqualICase(word, "C") OR Strings.EqualICase(word, "CPP")
       OR Strings.EqualICase(word, "SYSCALL") OR Strings.EqualICase(word, "PROLOG")
       OR Strings.EqualICase(word, "STDCALL") THEN
      lang := LangCaller
    ELSIF ~sawName THEN
      (* Ideal-mode "PROC Name ..." -- this is the first word we've seen
         and it wasn't a distance/language keyword, so it's the proc's
         own name. *)
      Strings.Copy(word, procName); sawName := TRUE
    ELSE
      (* ARG/RETURNS/LOCAL/USES tails on the same PROC line are handled
         by their own directive lines in this converter's simplified
         one-directive-per-source-line model; a same-line combined form
         is rare in the fixtures this tool targets and is flagged. *)
      IF ~Strings.EqualICase(word, "ARG") THEN i := len END
    END
  END;
  ResetProcFrame(dist, lang);
  Emit2(procName, ":");
  IF lang = LangNone THEN
    EmitNote("NOLANGUAGE PROC: no automatic prolog/epilog -- hand-write push bp/mov bp,sp yourself if this procedure expects ARG-style stack access")
  END
END HandleProcHeader;

(* ---------------------------------------------------------------- *)
(*  STRUC field lines (plain, non-OOP): DB/DW/DD/DQ/DT become resb/   *)
(*  resw/resd/resq/rest at the struc's running offset -- NASM structs *)
(*  carry no default/initial values, only offsets+sizes, so any RHS   *)
(*  value list is discarded (the offset/size is unaffected either     *)
(*  way; a DUP(n) count still determines total width).                *)
(* ---------------------------------------------------------------- *)

PROCEDURE ResKeywordFor(dirWord: ARRAY OF CHAR; VAR kw: ARRAY OF CHAR; VAR unitSize: INTEGER): BOOLEAN;
BEGIN
  kw[0] := 0X;
  IF    Strings.EqualICase(dirWord, "DB") THEN Strings.Copy("resb", kw); unitSize := 1
  ELSIF Strings.EqualICase(dirWord, "DW") THEN Strings.Copy("resw", kw); unitSize := 2
  ELSIF Strings.EqualICase(dirWord, "DD") THEN Strings.Copy("resd", kw); unitSize := 4
  ELSIF Strings.EqualICase(dirWord, "DQ") THEN Strings.Copy("resq", kw); unitSize := 8
  ELSIF Strings.EqualICase(dirWord, "DT") THEN Strings.Copy("rest", kw); unitSize := 10
  ELSE RETURN FALSE
  END;
  RETURN TRUE
END ResKeywordFor;

PROCEDURE HandleStrucField(label: ARRAY OF CHAR; dirWord: ARRAY OF CHAR; rest: ARRAY OF CHAR);
  VAR kw: ARRAY 8 OF CHAR; unitSize, itemCount: INTEGER; line: ARRAY MaxLine OF CHAR;
      count, body: ARRAY MaxLine OF CHAR; countStr: ARRAY 16 OF CHAR; valStart: WORD;
BEGIN
  IF Strings.EqualICase(dirWord, "DF") OR Strings.EqualICase(dirWord, "DP") THEN
    Strings.Copy("resd", kw); unitSize := 4;
    EmitNote("DF/DP struct field sized as a 4-byte far-pointer slot (resd) -- widen to a 6-byte pair by hand if true 48-bit segment:offset storage is required")
  ELSIF ~ResKeywordFor(dirWord, kw, unitSize) THEN
    RETURN
  END;
  itemCount := 1;
  IF ParseDup(rest, count, body) THEN
    valStart := 0;
    itemCount := INTEGER(Strings.Val(count, valStart))
  END;
  line[0] := 0X;
  Strings.Append("  .", line); Strings.Append(label, line); Strings.Append(": ", line);
  Strings.Append(kw, line); Strings.Append(" ", line);
  countStr[0] := 0X; IntToStr(itemCount, countStr);
  Strings.Append(countStr, line);
  Emit(line)
END HandleStrucField;

(* ---------------------------------------------------------------- *)
(*  OOP STRUC detection + emission                                   *)
(* ---------------------------------------------------------------- *)

(* DetectMethodTable: "rest" is everything after STRUC's name (Ideal)
   on the SAME source line up through an opening '{' -- but TASM's own
   METHOD table is usually written "STRUC name GLOBAL [parent] METHOD {"
   with the brace body spanning multiple lines.  This converter reads
   ahead from srcFile (like CaptureIrpBody) to collect the full brace
   body when a "METHOD" keyword followed by "{" is seen on the STRUC
   line or immediately following lines, up to the matching "}". *)
PROCEDURE DetectMethodTable(rest: ARRAY OF CHAR; VAR braceBody: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER; word: Name32; found: BOOLEAN; parent: Name32;
      raw: ARRAY MaxLine OF CHAR; depth: INTEGER;
BEGIN
  braceBody[0] := 0X;
  objParent[0] := 0X; objDist := DistNear;
  len := INTEGER(Strings.Length(rest)); i := 0; found := FALSE;
  WHILE (i < len) & ~found DO
    i := SkipBlanks(rest, i, len);
    word[0] := 0X;
    WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
    IF word[0] = 0X THEN i := len
    ELSIF Strings.EqualICase(word, "METHOD") THEN found := TRUE
    ELSIF Strings.EqualICase(word, "GLOBAL") THEN (* skip *)
    ELSIF Strings.EqualICase(word, "NEAR") THEN objDist := DistNear
    ELSIF Strings.EqualICase(word, "FAR") THEN objDist := DistFar
    ELSE
      Strings.Copy(word, objParent)  (* a bare name before METHOD = parent object *)
    END
  END;
  IF ~found THEN RETURN FALSE END;
  Strings.Copy(objParent, parent);
  i := SkipBlanks(rest, i, len);
  (* consume up to and past the opening '{' -- may be later on this
     same physical line, or (rarely) on the next; this converter's
     ReadLine-based driver only has "rest" from the current line, so
     require it here (the brace opens on the STRUC line itself). *)
  WHILE (i < len) & (rest[i] # "{") DO INC(i) END;
  IF i < len THEN INC(i) END;

  depth := 1;
  WHILE (i < len) & (depth > 0) DO
    IF rest[i] = "{" THEN INC(depth)
    ELSIF rest[i] = "}" THEN DEC(depth)
    END;
    IF depth > 0 THEN AppendChar(rest[i], braceBody) END;
    INC(i)
  END;
  WHILE (depth > 0) & ~Files.Eof(srcFile) DO
    IF (Files.ReadLine(srcFile, raw, LEN(raw)) # 0) OR (raw[0] # 0X) THEN
      i := 0; len := INTEGER(Strings.Length(raw));
      WHILE (i < len) & (depth > 0) DO
        IF raw[i] = "{" THEN INC(depth)
        ELSIF raw[i] = "}" THEN DEC(depth)
        END;
        IF depth > 0 THEN AppendChar(raw[i], braceBody) END;
        INC(i)
      END;
      AppendChar(" ", braceBody)
    END
  END;
  RETURN TRUE
END DetectMethodTable;

PROCEDURE HandleObjectStruc(label: ARRAY OF CHAR; nameFromRest: ARRAY OF CHAR; braceBody: ARRAY OF CHAR);
BEGIN
  IF label[0] # 0X THEN Strings.Copy(label, objName) ELSE Strings.Copy(nameFromRest, objName) END;
  ParseMethodTable(braceBody);
  inMethodTable := TRUE;
  inStruc := TRUE; Strings.Copy(objName, strucName);
  EmitObjectStruc(objName, objDist);
  EmitNote("OOP STRUC/METHOD table: struc emitted with a leading @Mptr_<obj> VMT-pointer field; data members below extend it; call EmitVmt (via TBLINST below) once, and TBLINIT inside this object's init method to wire the pointer per-instance")
END HandleObjectStruc;

(* UndefFrameNames: emit "%undef _name" for every ARG/LOCAL name this
   PROC declared (already in that "_name" form -- RewriteAtAt ran on the
   ARG/LOCAL line itself before HandleFrameList ever saw it, so
   frameNames already holds "_name", not "@@name" -- see RewriteAtAt/
   IsArgLocalName; ARG/LOCAL names get "_name" rather than a real
   dot-local ".name" because NASM's %define does not accept a leading
   '.' in the macro name it defines).  Without this %undef, a %define'd
   ARG/LOCAL name is a preprocessor macro with no scope of its own in
   NASM (unlike a real dot-local LABEL, which NASM itself scopes per
   enclosing non-local label) -- it would keep expanding in every PROC
   after this one until redefined, so a later PROC reusing the same
   short ARG/LOCAL name would silently inherit the wrong [bp+N]/[bp-N]
   slot instead of getting its own. *)
PROCEDURE UndefFrameNames;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < frameCount DO
    Emit2("%undef ", frameNames[k]); INC(k)
  END
END UndefFrameNames;

PROCEDURE HandleDirectiveLine(label: ARRAY OF CHAR; dirWord: ARRAY OF CHAR; rest: ARRAY OF CHAR; codeFull: ARRAY OF CHAR);
  VAR line: ARRAY MaxLine OF CHAR; name, msg: ARRAY MaxLine OF CHAR;
      rewritten, sized: ARRAY MaxLine OF CHAR; count, body: ARRAY MaxLine OF CHAR;
      braceBody: ARRAY MaxLine OF CHAR; i, len: INTEGER;
BEGIN
  line[0] := 0X;

  IF Strings.EqualICase(dirWord, "IDEAL") THEN
    EmitNote("IDEAL mode selected (bracket/precedence differences are already normalized line-by-line by this converter)"); RETURN
  ELSIF Strings.EqualICase(dirWord, "MASM") THEN
    EmitNote("MASM mode selected"); RETURN

  ELSIF Strings.EqualICase(dirWord, "NAME") OR Strings.EqualICase(dirWord, "VERSION")
     OR Strings.EqualICase(dirWord, "DOSSEG") OR Strings.EqualICase(dirWord, ".SEQ")
     OR Strings.EqualICase(dirWord, "LOCALS") OR Strings.EqualICase(dirWord, "NOLOCALS") THEN
    RETURN
  ELSIF Strings.EqualICase(dirWord, "END") THEN
    RETURN
  ELSIF Strings.EqualICase(dirWord, "INCLUDELIB") THEN
    EmitNote("INCLUDELIB is a linker instruction, not an assembler one in any assembler -- move this library to your NASM-output linker's command line/script");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "ALIAS") THEN
    EmitNote("ALIAS is resolved by the linker, not the assembler -- express it as a linker-script/map-file alias instead");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "WARN") OR Strings.EqualICase(dirWord, "NOWARN") THEN
    EmitNote("WARN/NOWARN warning-class control has no per-class NASM equivalent -- use nasm -w+xxx/-w-xxx on the command line");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "DISPLAY") OR Strings.EqualICase(dirWord, "%OUT") THEN
    line[0] := 0X; Strings.Append("%warning ", line); Strings.Append(rest, line); Emit(line); RETURN

  ELSIF Strings.EqualICase(dirWord, "RADIX") OR Strings.EqualICase(dirWord, ".RADIX") THEN
    Trimmed(rest, name);
    IF    Strings.Equal(name, "2")  THEN radix := 2
    ELSIF Strings.Equal(name, "8")  THEN radix := 8
    ELSIF Strings.Equal(name, "10") THEN radix := 10
    ELSIF Strings.Equal(name, "16") THEN radix := 16
    END;
    EmitNote("RADIX consumed -- subsequent bare numeric literals in this file are given an explicit NASM suffix");
    RETURN

  ELSIF Strings.EqualICase(dirWord, ".8086") THEN Emit("cpu 8086"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".186")  THEN Emit("cpu 186");  RETURN
  ELSIF Strings.EqualICase(dirWord, ".286") OR Strings.EqualICase(dirWord, ".286C")
     OR Strings.EqualICase(dirWord, ".286P") THEN Emit("cpu 286"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".386") OR Strings.EqualICase(dirWord, ".386C")
     OR Strings.EqualICase(dirWord, ".386P") THEN Emit("cpu 386"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".486") OR Strings.EqualICase(dirWord, ".486C")
     OR Strings.EqualICase(dirWord, ".486P") THEN Emit("cpu 486"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".586") OR Strings.EqualICase(dirWord, ".586C")
     OR Strings.EqualICase(dirWord, ".586P") THEN Emit("cpu 586"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".8087") OR Strings.EqualICase(dirWord, ".287")
     OR Strings.EqualICase(dirWord, ".387") OR Strings.EqualICase(dirWord, ".487")
     OR Strings.EqualICase(dirWord, ".587") THEN
    EmitNote("FPU directive dropped -- NASM enables FPU mnemonics automatically at the selected cpu level"); RETURN

  ELSIF Strings.EqualICase(dirWord, ".MODEL") OR Strings.EqualICase(dirWord, "MODEL") THEN
    EmitNote("NASM has no memory-model system -- emit raw SEGMENT/GROUP (OMF) or plain section directives for .CODE/.DATA/.STACK below instead of relying on DGROUP");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "STARTUPCODE") OR Strings.EqualICase(dirWord, ".STARTUP") THEN
    Emit("mov ax, DGROUP");
    Emit("mov ds, ax");
    Emit("mov ss, ax");
    Emit("mov sp, stacktop");
    EmitNote("STARTUPCODE expansion assumes a DGROUP group and a 'stacktop' label exist (declare them via GROUP/.bss as appropriate for your model)");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "EXITCODE") OR Strings.EqualICase(dirWord, ".EXIT") THEN
    Trimmed(rest, name);
    IF name[0] = 0X THEN Strings.Copy("0", name) END;
    line[0] := 0X; Strings.Append("mov ax, 4C00h + (", line);
    Strings.Append(name, line); Strings.Append(" & 0FFh)", line);
    Emit(line);
    Emit("int 21h");
    RETURN

  ELSIF Strings.EqualICase(dirWord, "CODESEG") OR Strings.EqualICase(dirWord, ".CODE") THEN
    EmitSection(".text"); RETURN
  ELSIF Strings.EqualICase(dirWord, "DATASEG") OR Strings.EqualICase(dirWord, ".DATA") THEN
    EmitSection(".data"); RETURN
  ELSIF Strings.EqualICase(dirWord, "CONST") & (label[0] = 0X) THEN
    EmitSection(".rodata"); RETURN
  ELSIF Strings.EqualICase(dirWord, ".CONST") THEN
    EmitSection(".rodata"); RETURN
  ELSIF Strings.EqualICase(dirWord, "UDATASEG") OR Strings.EqualICase(dirWord, ".DATA?") THEN
    EmitSection(".bss"); RETURN
  ELSIF Strings.EqualICase(dirWord, "STACK") OR Strings.EqualICase(dirWord, ".STACK") THEN
    Trimmed(rest, name);
    IF name[0] = 0X THEN Strings.Copy("1024", name) END;
    EmitSection(".bss");
    line[0] := 0X; Strings.Append("stackbottom: resb ", line); Strings.Append(name, line);
    Emit(line);
    Emit("stacktop:");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "FARDATA") OR Strings.EqualICase(dirWord, ".FARDATA") THEN
    Trimmed(rest, name);
    line[0] := 0X; Strings.Append("section ", line);
    IF name[0] # 0X THEN Strings.Append(name, line) ELSE Strings.Append(".fardata", line) END;
    Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "UFARDATA") OR Strings.EqualICase(dirWord, ".FARDATA?") THEN
    Trimmed(rest, name);
    line[0] := 0X; Strings.Append("section ", line);
    IF name[0] # 0X THEN Strings.Append(name, line) ELSE Strings.Append(".fardata_bss", line) END;
    Emit(line); RETURN

  ELSIF Strings.EqualICase(dirWord, "SEGMENT") THEN
    Trimmed(rest, name);
    IF label[0] # 0X THEN HandleSegmentAttrs(label, rest)
    ELSE HandleSegmentAttrs(name, "") END;
    RETURN
  ELSIF Strings.EqualICase(dirWord, "ENDS") THEN
    (* TASM's ENDS closes BOTH a SEGMENT and a STRUC block -- NASM's
       section-close is implicit (next SECTION/EOF), but a struc MUST
       be closed with an explicit "endstruc", or every line after it in
       the file is misparsed as more struc fields. *)
    IF inStruc THEN
      Emit("endstruc");
      inStruc := FALSE
    ELSE
      EmitNote("ENDS -- closing a section is implicit in NASM; the next SECTION/EOF ends it")
    END;
    RETURN
  ELSIF Strings.EqualICase(dirWord, "GROUP") THEN
    line[0] := 0X; Strings.Append("GROUP ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ASSUME") THEN
    EmitNote("ASSUME dropped -- NASM never elides segment-override bytes; add explicit seg: prefixes at any site that relied on this ASSUME");
    RETURN

  ELSIF Strings.EqualICase(dirWord, "ORG") THEN
    line[0] := 0X; Strings.Append("org ", line);
    RewriteExprWords(rest, rewritten); Strings.Append(rewritten, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "EVEN") THEN Emit("even"); RETURN
  ELSIF Strings.EqualICase(dirWord, "EVENDATA") THEN Emit("alignb 2"); RETURN
  ELSIF Strings.EqualICase(dirWord, "ALIGN") THEN
    line[0] := 0X; Strings.Append("align ", line); Strings.Append(rest, line); Emit(line); RETURN

  ELSIF Strings.EqualICase(dirWord, "PUBLIC") THEN
    line[0] := 0X; Strings.Append("global ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "EXTRN") OR Strings.EqualICase(dirWord, "EXTERN") THEN
    line[0] := 0X; Strings.Append("extern ", line);
    Trimmed(rest, name);
    (* strip a trailing ":type[:count]" -- NASM extern is untyped *)
    len := INTEGER(Strings.Length(name)); i := 0;
    WHILE (i < len) & (name[i] # ":") DO INC(i) END;
    IF i < len THEN Strings.Extract(name, 0, WORD(i), name) END;
    Strings.Append(name, line); Emit(line);
    RETURN
  ELSIF Strings.EqualICase(dirWord, "GLOBAL") & (label[0] = 0X) THEN
    Trimmed(rest, name);
    line[0] := 0X; Strings.Append("global ", line); Strings.Append(name, line); Emit(line);
    EmitNote("TASM GLOBAL is publish-or-import (defined-here vs defined-elsewhere); this was emitted as 'global' (publish) -- change to 'extern' by hand if this module only REFERENCES it");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "COMM") THEN
    Trimmed(rest, name);
    len := INTEGER(Strings.Length(name)); i := 0;
    WHILE (i < len) & (name[i] # ":") DO INC(i) END;
    IF i < len THEN Strings.Extract(name, 0, WORD(i), name) END;
    EmitSection(".bss");
    Emit2("global ", name);
    msg[0] := 0X;
    Strings.Append("COMM communal variable declared+published here (the module that should OWN storage); other modules referencing it need 'extern ", msg);
    Strings.Append(name, msg); Strings.Append("' instead", msg);
    EmitNote(msg);
    Emit2(name, ": resb 2   ; T2NASM: adjust reserved size to COMM's declared type");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "INCLUDE") THEN
    Trimmed(rest, name);
    line[0] := 0X; Strings.Append("%include ", line);
    IF (name[0] # 22X) & (name[0] # 27X) THEN
      Strings.Append('"', line); Strings.Append(name, line); Strings.Append('"', line)
    ELSE Strings.Append(name, line) END;
    Emit(line); RETURN

  ELSIF Strings.EqualICase(dirWord, "ENUM") THEN
    HandleEnum(rest); RETURN

  ELSIF Strings.EqualICase(dirWord, "STRUC") OR Strings.EqualICase(dirWord, "TABLE") THEN
    Trimmed(rest, name);
    len := INTEGER(Strings.Length(name));
    (* detect "GLOBAL [parent] METHOD { ... }" tail -> OOP object *)
    IF DetectMethodTable(name, braceBody) THEN
      HandleObjectStruc(label, name, braceBody); RETURN
    END;
    IF name[0] = 0X THEN Strings.Copy(label, name) END;
    inStruc := TRUE; Strings.Copy(name, strucName);
    Emit2("struc ", name); RETURN
  ELSIF Strings.EqualICase(dirWord, "UNION") THEN
    Trimmed(rest, name);
    IF name[0] = 0X THEN Strings.Copy(label, name) END;
    inStruc := TRUE; Strings.Copy(name, strucName);
    Emit2("struc ", name);
    EmitNote("UNION members all alias offset 0 -- every member below was kept at the struc's normal running offset; re-zero each 'resb .field: N' by hand if true overlap is required (NASM struc has no union mode)");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "RECORD") THEN
    Trimmed(rest, name);
    IF label[0] # 0X THEN Strings.Copy(label, curRecordName) ELSE Strings.Copy(name, curRecordName) END;
    HandleRecordFields(curRecordName, rest);
    msg[0] := 0X;
    Strings.Append("RECORD '", msg); Strings.Append(curRecordName, msg);
    Strings.Append("' registered for WIDTH/MASK/SETFIELD/GETFIELD lookups below -- no storage emitted here (a RECORD is a bit-layout type, not a variable)", msg);
    EmitNote(msg);
    RETURN
  ELSIF Strings.EqualICase(dirWord, "TYPEDEF") THEN
    Trimmed(rest, name);
    line[0] := 0X; Strings.Append("%define ", line); Strings.Append(label, line);
    Strings.Append(" ", line);
    sized[0] := 0X; RewriteOperandSizes(name, sized);
    Strings.Append(sized, line);
    Emit(line);
    EmitNote("TYPEDEF became a text %define -- NASM performs no type-checking on its use, unlike TASM");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "LABEL") THEN
    Emit2(label, ":"); RETURN
  ELSIF Strings.EqualICase(dirWord, "PROCTYPE") OR Strings.EqualICase(dirWord, "PROCDESC") THEN
    EmitNote("PROCTYPE/PROCDESC is a compile-time signature-checking aid only, no runtime effect -- safely omitted (the PROC it describes/checks is translated normally)");
    RETURN

  ELSIF Strings.EqualICase(dirWord, "PROC") THEN
    HandleProcHeader(label, rest); RETURN
  ELSIF Strings.EqualICase(dirWord, "ENDP") THEN
    (* A degenerate PROC that declared ARG/LOCAL but had zero USES and
       zero body instructions before reaching ENDP would otherwise
       leave its %define _name lines referencing bp+N/bp-N with no
       "push bp / mov bp,sp" ever emitted to make bp valid -- catch
       that here too (EnsureProcFrame is idempotent and a no-op for
       every normal PROC, which already triggered it from HandleUses
       or the first real instruction). Must run before UndefFrameNames/
       inProc:=FALSE, since EnsureProcFrame itself checks inProc. *)
    EnsureProcFrame;
    UndefFrameNames;
    inProc := FALSE;
    EmitNote("ENDP -- procedure end is implicit in NASM; every RET/RETF above already carries the matching USES-pop/stack-cleanup epilogue");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "ARG") THEN
    HandleFrameList(rest, TRUE); RETURN
  ELSIF Strings.EqualICase(dirWord, "LOCAL") & inProc & ~inMacro THEN
    HandleFrameList(rest, FALSE); RETURN
  ELSIF Strings.EqualICase(dirWord, "USES") THEN
    HandleUses(rest); RETURN

  ELSIF Strings.EqualICase(dirWord, "MACRO") THEN
    inMacro := TRUE;
    IF label[0] # 0X THEN
      (* MASM form: "label MACRO paramlist" -- label is already the
         macro name, rest is the whole paramlist. *)
      ParseParamList(rest);
      Strings.Copy(label, name)
    ELSE
      (* Ideal form: "MACRO name paramlist" -- name is the first word
         of rest, the paramlist is everything after it. *)
      Trimmed(rest, name);
      len := SplitWord(name, 0, INTEGER(Strings.Length(name)), body);
      len := SkipBlanks(name, len, INTEGER(Strings.Length(name)));
      Strings.Extract(name, WORD(len), Strings.Length(name) - WORD(len), rest);
      ParseParamList(rest);
      Strings.Copy(body, name)
    END;
    line[0] := 0X; Strings.Append("%macro ", line); Strings.Append(name, line);
    Strings.Append(" ", line);
    count[0] := 0X; IntToStr(macroParamCount, count);
    Strings.Append(count, line);
    Emit(line);
    RETURN
  ELSIF Strings.EqualICase(dirWord, "ENDM") THEN
    IF inMacro THEN inMacro := FALSE; macroParamCount := 0; Emit("%endmacro")
    ELSE Emit("%endrep") END;
    RETURN
  ELSIF Strings.EqualICase(dirWord, "LOCAL") & inMacro THEN
    EmitNote("LOCAL dropped -- write the listed names as %%name directly in the macro body; NASM auto-uniques %%-prefixed labels per expansion");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "EXITM") THEN Emit("%exitmacro"); RETURN
  ELSIF Strings.EqualICase(dirWord, "PURGE") THEN
    line[0] := 0X; Strings.Append("%undef ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "GOTO") THEN
    (* GOTO also terminates any conditional block that
       contains another GOTO, and jumps forward to ":tag", discarding
       everything in between.  Mechanical NASM translation: since a
       %macro body is emitted top-to-bottom with no runtime jump, the
       lines between this GOTO and its :tag must simply never be
       emitted -- wrap them in "%if 0 / %endif" (closing any IF/ELSE
       this GOTO sits inside of first) rather than
       trying to fake a preprocessor jump. *)
    Trimmed(rest, name);
    Emit("%endif   ; T2NASM: GOTO closes the enclosing IF");
    Emit("%if 0");
    msg[0] := 0X;
    Strings.Append("GOTO ", msg); Strings.Append(name, msg);
    Strings.Append(" -- lines from here down to ':", msg);
    Strings.Append(name, msg);
    Strings.Append("' are skipped via '%if 0' (this only works when GOTO's enclosing IF was the innermost open block; nested/nonlinear GOTO needs manual restructuring)", msg);
    EmitNote(msg);
    RETURN
  ELSIF Strings.EqualICase(dirWord, "REPT") THEN
    line[0] := 0X; Strings.Append("%rep ", line);
    RewriteExprWords(rest, rewritten); Strings.Append(rewritten, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "WHILE") THEN
    line[0] := 0X; Strings.Append("%if ", line);
    RewriteExprWords(rest, rewritten); Strings.Append(rewritten, line);
    Emit(line);
    EmitNote("WHILE has no native %rep-style loop in NASM's preprocessor; wrapped as one %if test -- re-invoke the enclosing %macro recursively at the bottom of this block for the looping half, then close with %endif (classic NASM recursive-macro WHILE idiom)");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "IRP") THEN
    HandleIrp(rest); RETURN
  ELSIF Strings.EqualICase(dirWord, "IRPC") THEN
    HandleIrpc(rest); RETURN

  ELSIF Strings.EqualICase(dirWord, "CATSTR") THEN
    line[0] := 0X; Strings.Append("%define ", line); Strings.Append(label, line);
    Strings.Append(" ", line);
    ConcatCommaListWithPlus(rest, rewritten);
    Strings.Append(rewritten, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "SUBSTR") THEN
    line[0] := 0X; Strings.Append("%substr ", line); Strings.Append(label, line);
    Strings.Append(" ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "SIZESTR") THEN
    line[0] := 0X; Strings.Append("%strlen ", line); Strings.Append(label, line);
    Strings.Append(" ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "INSTR") THEN
    EmitNote("INSTR substring search has no NASM preprocessor primitive -- pre-computed at conversion time is impossible without evaluating the search here; left as a comment for manual %assign-loop implementation");
    Emit2("; ", codeFull);
    RETURN

  ELSIF Strings.EqualICase(dirWord, "IFDEF") THEN
    line[0] := 0X; Strings.Append("%ifdef ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFNDEF") THEN
    line[0] := 0X; Strings.Append("%ifndef ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ELSEIFDEF") THEN
    line[0] := 0X; Strings.Append("%elifdef ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ELSEIFNDEF") THEN
    line[0] := 0X; Strings.Append("%elifndef ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFIDN") THEN
    line[0] := 0X; Strings.Append("%ifidn ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFIDNI") THEN
    line[0] := 0X; Strings.Append("%ifidni ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFDIF") THEN
    line[0] := 0X; Strings.Append("%ifnidn ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFDIFI") THEN
    line[0] := 0X; Strings.Append("%ifnidni ", line); Strings.Append(rest, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFB") THEN
    Emit("%if %0 = 0");
    EmitNote("IFB (blank-argument test) rewritten as a %0 parameter-count check -- adjust the compared count if this test applied to a specific positional argument rather than 'no arguments at all'");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "IFNB") THEN
    Emit("%if %0 > 0");
    EmitNote("IFNB (non-blank-argument test) rewritten as a %0 parameter-count check");
    RETURN
  ELSIF Strings.EqualICase(dirWord, "IF1") THEN
    Emit("%if 1"); EmitNote("IF1 (true on assembler pass 1) has no matching concept in NASM's single conceptual pass -- treated as always-true"); RETURN
  ELSIF Strings.EqualICase(dirWord, "IF2") THEN
    Emit("%if 1"); EmitNote("IF2 (true on assembler pass 2) has no matching concept in NASM's single conceptual pass -- treated as always-true"); RETURN
  ELSIF Strings.EqualICase(dirWord, "IFE") THEN
    line[0] := 0X; Strings.Append("%if !(", line);
    RewriteWidthMask(rest, sized); RewriteExprWords(sized, rewritten);
    Strings.Append(rewritten, line); Strings.Append(")", line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "IF") THEN
    line[0] := 0X; Strings.Append("%if ", line);
    RewriteWidthMask(rest, sized); RewriteExprWords(sized, rewritten);
    Strings.Append(rewritten, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ELSEIF") THEN
    line[0] := 0X; Strings.Append("%elif ", line);
    RewriteWidthMask(rest, sized); RewriteExprWords(sized, rewritten);
    Strings.Append(rewritten, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ELSEIFE") THEN
    line[0] := 0X; Strings.Append("%elif !(", line);
    RewriteWidthMask(rest, sized); RewriteExprWords(sized, rewritten);
    Strings.Append(rewritten, line); Strings.Append(")", line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ELSE") THEN Emit("%else"); RETURN
  ELSIF Strings.EqualICase(dirWord, "ENDIF") THEN Emit("%endif"); RETURN

  ELSIF Strings.EqualICase(dirWord, "ERR") THEN
    ExtractMessage(rest, msg);
    line[0] := 0X; Strings.Append("%error ", line); Strings.Append(msg, line); Emit(line); RETURN
  ELSIF Strings.EqualICase(dirWord, "ERRIFDEF") THEN
    ExtractMessage(rest, msg);
    Trimmed(rest, name); len := SplitWord(name,0,INTEGER(Strings.Length(name)),body);
    Emit2("%ifdef ", body);
    line[0] := 0X; Strings.Append("  %error ", line); Strings.Append(msg, line); Emit(line);
    Emit("%endif"); RETURN
  ELSIF Strings.EqualICase(dirWord, "ERRIFNDEF") THEN
    ExtractMessage(rest, msg);
    Trimmed(rest, name); len := SplitWord(name,0,INTEGER(Strings.Length(name)),body);
    Emit2("%ifndef ", body);
    line[0] := 0X; Strings.Append("  %error ", line); Strings.Append(msg, line); Emit(line);
    Emit("%endif"); RETURN

  ELSIF Strings.EqualICase(dirWord, "DB") OR Strings.EqualICase(dirWord, "DW")
     OR Strings.EqualICase(dirWord, "DD") OR Strings.EqualICase(dirWord, "DQ")
     OR Strings.EqualICase(dirWord, "DT") OR Strings.EqualICase(dirWord, "DF")
     OR Strings.EqualICase(dirWord, "DP") THEN
    IF inStruc THEN HandleStrucField(label, dirWord, rest)
    ELSE HandleDataDef(label, dirWord, rest) END;
    RETURN
  ELSIF Strings.EqualICase(dirWord, "EQU") THEN
    line[0] := 0X; Strings.Append(label, line); Strings.Append(" equ ", line);
    sized[0] := 0X; RewriteWidthMask(rest, sized);
    RewriteExprWords(sized, rewritten); Strings.Append(rewritten, line);
    Emit(line); RETURN

  ELSIF IsFieldOpWord(dirWord) THEN
    HandleFieldOp(dirWord, rest); RETURN

  ELSE
    msg[0] := 0X;
    Strings.Append("unrecognized TASM directive '", msg); Strings.Append(dirWord, msg);
    Strings.Append("' -- kept as a comment for manual review", msg);
    EmitNote(msg);
    Emit2("; ", codeFull)
  END
END HandleDirectiveLine;

(* ---------------------------------------------------------------- *)
(*  instructions (CALL..METHOD, TBLINST/TBLINIT, RET,                *)
(*  plain mnemonics)                                                 *)
(* ---------------------------------------------------------------- *)

(* ContainsMethodKeyword: TRUE if rest has the shape "instance METHOD
   ..." -- instance is copied out; methodTail receives everything from
   METHOD onward (both computed here so the caller needs only one scan). *)
PROCEDURE ContainsMethodKeyword(rest: ARRAY OF CHAR; VAR instance: ARRAY OF CHAR; VAR methodTail: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER; word: Name32;
BEGIN
  instance[0] := 0X; methodTail[0] := 0X;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE i < len DO
    IF IsIdentStart(rest[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & IsIdentChar(rest[i]) DO AppendChar(rest[i], word); INC(i) END;
      IF Strings.EqualICase(word, "METHOD") THEN
        Strings.RTrim(instance);
        Strings.Extract(rest, WORD(i), WORD(len - i), methodTail);
        Strings.Trim(methodTail);
        RETURN TRUE
      END;
      Strings.Append(word, instance)
    ELSE
      AppendChar(rest[i], instance); INC(i)
    END
  END;
  instance[0] := 0X;
  RETURN FALSE
END ContainsMethodKeyword;

(* HandleInstruction: label may be "" if none.  mnemonicAndRest is the
   full instruction text (mnemonic + operands). *)
PROCEDURE HandleInstruction(label: ARRAY OF CHAR; mnemonicAndRest: ARRAY OF CHAR);
  VAR sized, rewritten, line: ARRAY MaxLine OF CHAR; mnem: Name32;
      after, len: INTEGER; rest: ARRAY MaxLine OF CHAR; operand: ARRAY MaxLine OF CHAR;
      methodTail: ARRAY MaxLine OF CHAR;
BEGIN
  (* Every ARG/LOCAL/USES directive for the currently open PROC has by
     now been processed (they all precede the first real instruction in
     valid TASM source) -- safe to finalize the BP frame here, before
     the first instruction of the body is emitted.  EnsureProcFrame is
     idempotent (no-op once procHasFrame is set, or if this PROC never
     declared ARG/LOCAL/USES at all), so calling it unconditionally on
     every instruction line costs nothing after the first. *)
  EnsureProcFrame;
  len := INTEGER(Strings.Length(mnemonicAndRest));
  mnem[0] := 0X;
  after := SplitWord(mnemonicAndRest, 0, len, mnem);

  IF Strings.EqualICase(mnem, "TBLINST") THEN
    IF inMethodTable THEN
      EmitVmt(objName, objDist)
    ELSE
      EmitNote("TBLINST outside an OOP STRUC/METHOD declaration -- no object context to build a VMT for; left as a comment")
    END;
    RETURN
  ELSIF Strings.EqualICase(mnem, "TBLINIT") THEN
    after := SkipBlanks(mnemonicAndRest, after, len);
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest);
    Strings.Trim(rest);
    HandleTblinit(rest);
    RETURN
  ELSIF Strings.EqualICase(mnem, "RET") OR Strings.EqualICase(mnem, "RETN")
     OR Strings.EqualICase(mnem, "RETF") THEN
    after := SkipBlanks(mnemonicAndRest, after, len);
    operand[0] := 0X;
    IF after < len THEN
      Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), operand);
      Strings.Trim(operand)
    END;
    IF Strings.EqualICase(mnem, "RETF") THEN procDist := DistFar END;
    InjectEpilogue(operand);
    RETURN
  ELSIF Strings.EqualICase(mnem, "CALL") THEN
    after := SkipBlanks(mnemonicAndRest, after, len);
    rest[0] := 0X;
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest);
    (* "instance METHOD ..." -- instance is everything up to the METHOD
       keyword (may itself contain a ':' segment override, e.g. "es:di") *)
    IF ContainsMethodKeyword(rest, operand, methodTail) THEN
      HandleCallMethod(operand, methodTail);
      RETURN
    END;
    (* not a METHOD call -- check the other CALL extension: high-level
       language argument list ("CALL test PASCAL,ax,es OFFSET buffer"). *)
    IF HandleCallLanguage(rest) THEN RETURN END
    (* else fall through to plain-instruction handling below (bare
       "CALL target", no language/arg-list extension in use) *)
  END;

  (* Rewrite only the OPERAND portion (mnemonicAndRest past the mnemonic
     itself) through the expression-word/PTR-size passes.  AND/OR/XOR/NOT
     are both TASM keyword-operators AND real 8086 mnemonics --
     running RewriteExprWords over the whole line, mnemonic
     included, corrupted a bare "xor bx,bx" instruction into "^ bx,bx"
     since it can't tell "XOR" the opcode from "XOR" the operator. The
     mnemonic itself never needs any of these rewrites (PTR-casts,
     WIDTH/MASK, keyword operators only ever appear in operands). *)
  after := SkipBlanks(mnemonicAndRest, after, len);
  rest[0] := 0X;
  IF after < len THEN
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest)
  END;
  RewriteOperandSizes(rest, sized);
  RewriteWidthMask(sized, rest);
  RewriteExprWords(rest, rewritten);
  line[0] := 0X;
  IF label[0] # 0X THEN Strings.Append(label, line); Strings.Append(": ", line) END;
  Strings.Append(mnem, line);
  IF rewritten[0] # 0X THEN Strings.Append(" ", line); Strings.Append(rewritten, line) END;
  IF inMacro THEN
    sized[0] := 0X; SubstituteMacroParams(line, sized); Emit(sized)
  ELSE
    Emit(line)
  END
END HandleInstruction;

(* ---------------------------------------------------------------- *)
(*  main per-line dispatcher                                         *)
(* ---------------------------------------------------------------- *)

PROCEDURE HandleDirectiveOrInstr(label: ARRAY OF CHAR; word: ARRAY OF CHAR; rest: ARRAY OF CHAR; codeFull: ARRAY OF CHAR);
  VAR full: ARRAY MaxLine OF CHAR;
BEGIN
  IF IsGlobalDirectiveWord(word) THEN
    HandleDirectiveLine(label, word, rest, codeFull)
  ELSE
    full[0] := 0X; Strings.Append(word, full);
    IF rest[0] # 0X THEN Strings.Append(" ", full); Strings.Append(rest, full) END;
    HandleInstruction(label, full)
  END
END HandleDirectiveOrInstr;

PROCEDURE ProcessLine(raw: ARRAY OF CHAR);
  VAR commentAt: INTEGER; code, comment, atAtOut: ARRAY MaxLine OF CHAR;
      codeLen: INTEGER; label: Name32; firstWord: Name32;
      restIdx, afterFirstWord: INTEGER; rest: ARRAY MaxLine OF CHAR; secondWord: Name32;
      after2: INTEGER; line: ARRAY MaxLine OF CHAR;
BEGIN
  commentAt := FindCommentStart(raw);
  Strings.Extract(raw, 0, WORD(commentAt), code);
  Strings.Trim(code);
  (* PreRegisterFrameNames must see this line's ORIGINAL "@@name"
     spelling before RewriteAtAt touches it, so an ARG/LOCAL line's own
     declared names are already known to IsArgLocalName by the time
     RewriteAtAt rewrites references on this very same line (not just
     on later ones). @@name -> .name for a real LABEL, or _name for a
     known ARG/LOCAL name -- see RewriteAtAt's own header comment. *)
  PreRegisterFrameNames(code);
  RewriteAtAt(code, atAtOut); Strings.Copy(atAtOut, code);
  comment[0] := 0X;
  IF commentAt < INTEGER(Strings.Length(raw)) THEN
    Strings.Extract(raw, WORD(commentAt), Strings.Length(raw) - WORD(commentAt), comment);
    Strings.RTrim(comment)
  END;

  codeLen := INTEGER(Strings.Length(code));
  IF codeLen = 0 THEN
    IF comment[0] # 0X THEN Emit(comment) ELSE Emit("") END;
    RETURN
  END;

  label[0] := 0X;
  restIdx := SplitWord(code, 0, codeLen, firstWord);
  afterFirstWord := restIdx;

  (* ":tag" macro-goto-target line -- must be checked
     before the generic "name:" label case since it looks identical
     but sits at column 0 with the colon FIRST, not last. *)
  IF (firstWord[0] = 0X) & (codeLen > 0) & (code[0] = ":") THEN
    Strings.Extract(code, 1, WORD(codeLen - 1), firstWord);
    Strings.Trim(firstWord);
    Emit("%endif   ; T2NASM: end of GOTO-skip block");
    Emit2(firstWord, ":");
    IF comment[0] # 0X THEN Emit(comment) END;
    RETURN
  END;

  IF (restIdx < codeLen) & (code[restIdx] = ":") THEN
    Strings.Copy(firstWord, label);
    INC(restIdx);
    IF (restIdx < codeLen) & (code[restIdx] = ":") THEN INC(restIdx) END;
    restIdx := SkipBlanks(code, restIdx, codeLen);
    IF restIdx >= codeLen THEN
      Emit2(label, ":");
      IF comment[0] # 0X THEN Emit(comment) END;
      RETURN
    END;
    Strings.Extract(code, WORD(restIdx), WORD(codeLen - restIdx), rest);
    after2 := SplitWord(rest, 0, INTEGER(Strings.Length(rest)), secondWord);
    IF secondWord[0] # 0X THEN
      after2 := SkipBlanks(rest, after2, INTEGER(Strings.Length(rest)));
      line[0] := 0X; Strings.Extract(rest, WORD(after2), Strings.Length(rest) - WORD(after2), line);
      HandleDirectiveOrInstr(label, secondWord, line, code)
    END;
    IF comment[0] # 0X THEN Emit(comment) END;
    RETURN
  END;

  restIdx := SkipBlanks(code, restIdx, codeLen);
  secondWord[0] := 0X;
  IF restIdx < codeLen THEN
    IF code[restIdx] = "=" THEN
      Strings.Copy("=", secondWord); INC(restIdx)
    ELSE
      restIdx := SplitWord(code, restIdx, codeLen, secondWord)
    END
  END;
  restIdx := SkipBlanks(code, restIdx, codeLen);
  Strings.Extract(code, WORD(restIdx), WORD(codeLen - restIdx), rest);

  IF IsKnownDirective(secondWord) THEN
    (* "name DIRECTIVE rest" -- e.g. "foo SEGMENT ...", "foo PROC ...",
       "foo EQU ...", "foo = expr" *)
    IF Strings.Equal(secondWord, "=") THEN
      line[0] := 0X; Strings.Append("%assign ", line); Strings.Append(firstWord, line);
      Strings.Append(" ", line);
      HandleAssignRhs(rest, line);
      Emit(line)
    ELSE
      HandleDirectiveLine(firstWord, secondWord, rest, code)
    END
  ELSIF IsGlobalDirectiveWord(firstWord) THEN
    (* "DIRECTIVE rest" -- no name/label first: bare directives like
       IDEAL, MODEL, CODESEG, END, or one taking an operand like
       ORG/PUBLIC/EXTERN/IFDEF/DB(no label)/etc.  Must re-slice from
       right after firstWord, NOT from after the already-consumed
       secondWord probe above (which is not actually part of this
       directive's own operand list at all -- e.g. "USES si,di" would
       otherwise lose "si", already probed as a would-be secondWord). *)
    afterFirstWord := SkipBlanks(code, afterFirstWord, codeLen);
    Strings.Extract(code, WORD(afterFirstWord), WORD(codeLen - afterFirstWord), rest);
    HandleDirectiveLine("", firstWord, rest, code)
  ELSE
    Strings.Extract(code, 0, WORD(codeLen), rest);
    HandleInstruction("", rest)
  END;
  IF comment[0] # 0X THEN Emit(comment) END
END ProcessLine;

(* Convert: rewrite inPath (TASM syntax) to outPath (NASM syntax).
   Result: TRUE on success (outPath was fully written), FALSE on any I/O
   failure (a LogErr diagnostic is already latched -- caller just checks
   LogErr.HaveErr()/the result and maps to its own exit code, same
   convention as Parse.Assemble). *)
PROCEDURE Convert*(inPath, outPath: ARRAY OF CHAR): BOOLEAN;
  VAR
      line: ARRAY MaxLine OF CHAR;
BEGIN
  radix := 10; reviewCount := 0;
  inProc := FALSE; inStruc := FALSE; inMacro := FALSE; macroParamCount := 0;
  inMethodTable := FALSE; recFieldCount := 0;

  IF ~Files.FileExists(inPath) THEN
    LogErr.Error2("tasm: no such file: ", inPath);
    RETURN FALSE
  END;
  IF ~Files.Reset(srcFile, inPath) THEN
    LogErr.Error2("tasm: cannot open ", inPath);
    RETURN FALSE
  END;
  IF ~Files.ReWrite(dst, outPath) THEN
    LogErr.Error2("tasm: cannot create ", outPath);
    Files.Close(srcFile); RETURN FALSE
  END;

  Emit("; converted from TASM syntax by t2nasm -- search for 'T2NASM:' notes below");
  WHILE ~Files.Eof(srcFile) DO
    IF (Files.ReadLine(srcFile, line, LEN(line)) # 0) OR (line[0] # 0X) THEN
      ProcessLine(line)
    ELSIF ~Files.Eof(srcFile) THEN
      Emit("")
    END
  END;

  Files.Close(srcFile);
  Files.Close(dst);

  (* A directive deep inside the streaming ProcessLine loop (e.g.
     HandleFrameList's too-many-ARG/LOCAL-entries check) may have
     called LogErr.Error2 without unwinding the loop early -- Convert
     must surface that as a real failure, not silently report success
     with a corrupted .NAS already written to outPath. *)
  RETURN ~LogErr.HaveErr()
END Convert;

END Turbo.
