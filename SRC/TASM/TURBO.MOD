(*$D-,R-,A-,O-*)
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
  CALL..METHOD).  All of that state, plus the string/expression-rewrite
  helpers and the per-directive handlers, live in TurboDir (TURBODIR.MOD)
  -- split out 2026-08-09 because TURBO.MOD's own compiled code no longer
  fit in the 64K RDOFF2 code-segment limit (Rdoff.SegLimit).  This module
  keeps only the per-line dispatcher (ProcessLine/HandleDirectiveOrInstr/
  HandleInstruction) and the public entry point below.

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
IMPORT Files, Strings, LogErr, TurboDir;


PROCEDURE ContainsMethodKeyword(rest: ARRAY OF CHAR; VAR instance: ARRAY OF CHAR; VAR methodTail: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER; word: TurboDir.Name32;
BEGIN
  instance[0] := 0X; methodTail[0] := 0X;
  len := INTEGER(Strings.Length(rest)); i := 0;
  WHILE i < len DO
    IF TurboDir.IsIdentStart(rest[i]) THEN
      word[0] := 0X;
      WHILE (i < len) & TurboDir.IsIdentChar(rest[i]) DO TurboDir.AppendChar(rest[i], word); INC(i) END;
      IF Strings.EqualICase(word, "METHOD") THEN
        Strings.RTrim(instance);
        Strings.Extract(rest, WORD(i), WORD(len - i), methodTail);
        Strings.Trim(methodTail);
        RETURN TRUE
      END;
      Strings.Append(word, instance)
    ELSE
      TurboDir.AppendChar(rest[i], instance); INC(i)
    END
  END;
  instance[0] := 0X;
  RETURN FALSE
END ContainsMethodKeyword;

(* HandleInstruction: label may be "" if none.  mnemonicAndRest is the
   full instruction text (mnemonic + operands). *)
PROCEDURE HandleInstruction(label: ARRAY OF CHAR; mnemonicAndRest: ARRAY OF CHAR);
  VAR sized, rewritten, line: ARRAY TurboDir.MaxLine OF CHAR; mnem: TurboDir.Name32;
      after, len: INTEGER; rest: ARRAY TurboDir.MaxLine OF CHAR; operand: ARRAY TurboDir.MaxLine OF CHAR;
      methodTail: ARRAY TurboDir.MaxLine OF CHAR;
BEGIN
  (* Every ARG/LOCAL/USES directive for the currently open PROC has by
     now been processed (they all precede the first real instruction in
     valid TASM source) -- safe to finalize the BP frame here, before
     the first instruction of the body is emitted.  EnsureProcFrame is
     idempotent (no-op once TurboDir.procHasFrame is set, or if this PROC never
     declared ARG/LOCAL/USES at all), so calling it unconditionally on
     every instruction line costs nothing after the first. *)
  TurboDir.EnsureProcFrame;
  len := INTEGER(Strings.Length(mnemonicAndRest));
  mnem[0] := 0X;
  after := TurboDir.SplitWord(mnemonicAndRest, 0, len, mnem);

  IF Strings.EqualICase(mnem, "TBLINST") THEN
    IF TurboDir.inMethodTable THEN
      TurboDir.EmitVmt(TurboDir.objName, TurboDir.objDist)
    ELSE
      TurboDir.EmitNote("TBLINST outside an OOP STRUC/METHOD declaration -- no object context to build a VMT for; left as a comment")
    END;
    RETURN
  ELSIF Strings.EqualICase(mnem, "TBLINIT") THEN
    after := TurboDir.SkipBlanks(mnemonicAndRest, after, len);
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest);
    Strings.Trim(rest);
    TurboDir.HandleTblinit(rest);
    RETURN
  ELSIF Strings.EqualICase(mnem, "RET") OR Strings.EqualICase(mnem, "RETN")
     OR Strings.EqualICase(mnem, "RETF") THEN
    after := TurboDir.SkipBlanks(mnemonicAndRest, after, len);
    operand[0] := 0X;
    IF after < len THEN
      Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), operand);
      Strings.Trim(operand)
    END;
    IF Strings.EqualICase(mnem, "RETF") THEN TurboDir.procDist := TurboDir.DistFar END;
    TurboDir.InjectEpilogue(operand);
    RETURN
  ELSIF Strings.EqualICase(mnem, "CALL") THEN
    after := TurboDir.SkipBlanks(mnemonicAndRest, after, len);
    rest[0] := 0X;
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest);
    (* "instance METHOD ..." -- instance is everything up to the METHOD
       keyword (may itself contain a ':' segment override, e.g. "es:di") *)
    IF ContainsMethodKeyword(rest, operand, methodTail) THEN
      TurboDir.HandleCallMethod(operand, methodTail);
      RETURN
    END;
    (* not a METHOD call -- check the other CALL extension: high-level
       language argument list ("CALL test PASCAL,ax,es OFFSET buffer"). *)
    IF TurboDir.HandleCallLanguage(rest) THEN RETURN END
    (* else fall through to plain-instruction handling below (bare
       "CALL target", no language/arg-list extension in use) *)
  END;

  (* Rewrite only the OPERAND portion (mnemonicAndRest past the mnemonic
     itself) through the expression-word/PTR-size passes.  AND/OR/XOR/NOT
     are both TASM keyword-operators AND real 8086 mnemonics --
     running TurboDir.RewriteExprWords over the whole line, mnemonic
     included, corrupted a bare "xor bx,bx" instruction into "^ bx,bx"
     since it can't tell "XOR" the opcode from "XOR" the operator. The
     mnemonic itself never needs any of these rewrites (PTR-casts,
     WIDTH/MASK, keyword operators only ever appear in operands). *)
  after := TurboDir.SkipBlanks(mnemonicAndRest, after, len);
  rest[0] := 0X;
  IF after < len THEN
    Strings.Extract(mnemonicAndRest, WORD(after), WORD(len - after), rest)
  END;
  TurboDir.RewriteOperandSizes(rest, sized);
  TurboDir.RewriteWidthMask(sized, rest);
  TurboDir.RewriteExprWords(rest, rewritten);
  line[0] := 0X;
  IF label[0] # 0X THEN Strings.Append(label, line); Strings.Append(": ", line) END;
  Strings.Append(mnem, line);
  IF rewritten[0] # 0X THEN Strings.Append(" ", line); Strings.Append(rewritten, line) END;
  IF TurboDir.inMacro THEN
    sized[0] := 0X; TurboDir.SubstituteMacroParams(line, sized); TurboDir.Emit(sized)
  ELSE
    TurboDir.Emit(line)
  END
END HandleInstruction;

(* ---------------------------------------------------------------- *)
(*  main per-line dispatcher                                         *)
(* ---------------------------------------------------------------- *)

PROCEDURE HandleDirectiveOrInstr(label: ARRAY OF CHAR; word: ARRAY OF CHAR; rest: ARRAY OF CHAR; codeFull: ARRAY OF CHAR);
  VAR full: ARRAY TurboDir.MaxLine OF CHAR;
BEGIN
  IF TurboDir.IsGlobalDirectiveWord(word) THEN
    TurboDir.HandleDirectiveLine(label, word, rest, codeFull)
  ELSE
    full[0] := 0X; Strings.Append(word, full);
    IF rest[0] # 0X THEN Strings.Append(" ", full); Strings.Append(rest, full) END;
    HandleInstruction(label, full)
  END
END HandleDirectiveOrInstr;

PROCEDURE ProcessLine(raw: ARRAY OF CHAR);
  VAR commentAt: INTEGER; code, comment, atAtOut: ARRAY TurboDir.MaxLine OF CHAR;
      codeLen: INTEGER; label: TurboDir.Name32; firstWord: TurboDir.Name32;
      restIdx, afterFirstWord: INTEGER; rest: ARRAY TurboDir.MaxLine OF CHAR; secondWord: TurboDir.Name32;
      after2: INTEGER; line: ARRAY TurboDir.MaxLine OF CHAR;
BEGIN
  commentAt := TurboDir.FindCommentStart(raw);
  Strings.Extract(raw, 0, WORD(commentAt), code);
  Strings.Trim(code);
  (* PreRegisterFrameNames must see this line's ORIGINAL "@@name"
     spelling before RewriteAtAt touches it, so an ARG/LOCAL line's own
     declared names are already known to IsArgLocalName by the time
     RewriteAtAt rewrites references on this very same line (not just
     on later ones). @@name -> .name for a real LABEL, or _name for a
     known ARG/LOCAL name -- see RewriteAtAt's own header comment. *)
  TurboDir.PreRegisterFrameNames(code);
  TurboDir.RewriteAtAt(code, atAtOut); Strings.Copy(atAtOut, code);
  comment[0] := 0X;
  IF commentAt < INTEGER(Strings.Length(raw)) THEN
    Strings.Extract(raw, WORD(commentAt), Strings.Length(raw) - WORD(commentAt), comment);
    Strings.RTrim(comment)
  END;

  codeLen := INTEGER(Strings.Length(code));
  IF codeLen = 0 THEN
    IF comment[0] # 0X THEN TurboDir.Emit(comment) ELSE TurboDir.Emit("") END;
    RETURN
  END;

  label[0] := 0X;
  restIdx := TurboDir.SplitWord(code, 0, codeLen, firstWord);
  afterFirstWord := restIdx;

  (* ":tag" macro-goto-target line -- must be checked
     before the generic "name:" label case since it looks identical
     but sits at column 0 with the colon FIRST, not last. *)
  IF (firstWord[0] = 0X) & (codeLen > 0) & (code[0] = ":") THEN
    Strings.Extract(code, 1, WORD(codeLen - 1), firstWord);
    Strings.Trim(firstWord);
    TurboDir.Emit("%endif   ; T2NASM: end of GOTO-skip block");
    TurboDir.Emit2(firstWord, ":");
    IF comment[0] # 0X THEN TurboDir.Emit(comment) END;
    RETURN
  END;

  IF (restIdx < codeLen) & (code[restIdx] = ":") THEN
    Strings.Copy(firstWord, label);
    INC(restIdx);
    IF (restIdx < codeLen) & (code[restIdx] = ":") THEN INC(restIdx) END;
    restIdx := TurboDir.SkipBlanks(code, restIdx, codeLen);
    IF restIdx >= codeLen THEN
      TurboDir.Emit2(label, ":");
      IF comment[0] # 0X THEN TurboDir.Emit(comment) END;
      RETURN
    END;
    Strings.Extract(code, WORD(restIdx), WORD(codeLen - restIdx), rest);
    after2 := TurboDir.SplitWord(rest, 0, INTEGER(Strings.Length(rest)), secondWord);
    IF secondWord[0] # 0X THEN
      after2 := TurboDir.SkipBlanks(rest, after2, INTEGER(Strings.Length(rest)));
      line[0] := 0X; Strings.Extract(rest, WORD(after2), Strings.Length(rest) - WORD(after2), line);
      HandleDirectiveOrInstr(label, secondWord, line, code)
    END;
    IF comment[0] # 0X THEN TurboDir.Emit(comment) END;
    RETURN
  END;

  restIdx := TurboDir.SkipBlanks(code, restIdx, codeLen);
  secondWord[0] := 0X;
  IF restIdx < codeLen THEN
    IF code[restIdx] = "=" THEN
      Strings.Copy("=", secondWord); INC(restIdx)
    ELSE
      restIdx := TurboDir.SplitWord(code, restIdx, codeLen, secondWord)
    END
  END;
  restIdx := TurboDir.SkipBlanks(code, restIdx, codeLen);
  Strings.Extract(code, WORD(restIdx), WORD(codeLen - restIdx), rest);

  IF TurboDir.IsKnownDirective(secondWord) THEN
    (* "name DIRECTIVE rest" -- e.g. "foo SEGMENT ...", "foo PROC ...",
       "foo EQU ...", "foo = expr" *)
    IF Strings.Equal(secondWord, "=") THEN
      line[0] := 0X; Strings.Append("%assign ", line); Strings.Append(firstWord, line);
      Strings.Append(" ", line);
      TurboDir.HandleAssignRhs(rest, line);
      TurboDir.Emit(line)
    ELSE
      TurboDir.HandleDirectiveLine(firstWord, secondWord, rest, code)
    END
  ELSIF TurboDir.IsGlobalDirectiveWord(firstWord) THEN
    (* "DIRECTIVE rest" -- no name/label first: bare directives like
       IDEAL, MODEL, CODESEG, END, or one taking an operand like
       ORG/PUBLIC/EXTERN/IFDEF/DB(no label)/etc.  Must re-slice from
       right after firstWord, NOT from after the already-consumed
       secondWord probe above (which is not actually part of this
       directive's own operand list at all -- e.g. "USES si,di" would
       otherwise lose "si", already probed as a would-be secondWord). *)
    afterFirstWord := TurboDir.SkipBlanks(code, afterFirstWord, codeLen);
    Strings.Extract(code, WORD(afterFirstWord), WORD(codeLen - afterFirstWord), rest);
    TurboDir.HandleDirectiveLine("", firstWord, rest, code)
  ELSE
    Strings.Extract(code, 0, WORD(codeLen), rest);
    HandleInstruction("", rest)
  END;
  IF comment[0] # 0X THEN TurboDir.Emit(comment) END
END ProcessLine;

(* Convert: rewrite inPath (TASM syntax) to outPath (NASM syntax).
   Result: TRUE on success (outPath was fully written), FALSE on any I/O
   failure (a LogErr diagnostic is already latched -- caller just checks
   LogErr.HaveErr()/the result and maps to its own exit code, same
   convention as Parse.Assemble). *)
PROCEDURE Convert*(inPath, outPath: ARRAY OF CHAR): BOOLEAN;
  VAR
      line: ARRAY TurboDir.MaxLine OF CHAR;
BEGIN
  TurboDir.radix := 10; TurboDir.reviewCount := 0;
  TurboDir.inProc := FALSE; TurboDir.inStruc := FALSE; TurboDir.inMacro := FALSE; TurboDir.macroParamCount := 0;
  TurboDir.inMethodTable := FALSE; TurboDir.recFieldCount := 0;

  IF ~Files.FileExists(inPath) THEN
    LogErr.Error2("tasm: no such file: ", inPath);
    RETURN FALSE
  END;
  IF ~Files.Reset(TurboDir.srcFile, inPath) THEN
    LogErr.Error2("tasm: cannot open ", inPath);
    RETURN FALSE
  END;
  IF ~Files.ReWrite(TurboDir.dst, outPath) THEN
    LogErr.Error2("tasm: cannot create ", outPath);
    Files.Close(TurboDir.srcFile); RETURN FALSE
  END;

  TurboDir.Emit("; converted from TASM syntax by t2nasm -- search for 'T2NASM:' notes below");
  WHILE ~Files.Eof(TurboDir.srcFile) DO
    IF (Files.ReadLine(TurboDir.srcFile, line, LEN(line)) # 0) OR (line[0] # 0X) THEN
      ProcessLine(line)
    ELSIF ~Files.Eof(TurboDir.srcFile) THEN
      TurboDir.Emit("")
    END
  END;

  Files.Close(TurboDir.srcFile);
  Files.Close(TurboDir.dst);

  (* A directive deep inside the streaming ProcessLine loop (e.g.
     HandleFrameList's too-many-ARG/LOCAL-entries check) may have
     called LogErr.Error2 without unwinding the loop early -- Convert
     must surface that as a real failure, not silently report success
     with a corrupted .NAS already written to outPath. *)
  RETURN ~LogErr.HaveErr()
END Convert;

END Turbo.
