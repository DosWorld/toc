MODULE Enc;
(*
  TASM x86 (8086) instruction encoder.
  (mnemonic, operand list) -> byte sequence + relocation info, written
  straight into Rdoff's code segment via Rdoff.EmitByte*.

  Operand normalization: Parse.MOD parses each instruction's operand list
  into an array of Operand records (see TYPE Operand below) before calling
  Encode.  This module owns opcode selection, ModRM/addressing-mode
  encoding, immediate-size selection, and relocation emission -- it never
  touches the scanner or the token stream.

  Two-pass model: EncodeInstr is called once per pass.  In BOTH passes it
  runs the exact same encoding logic and byte-counts every emitted byte
  into `emitted` (the caller, Parse.MOD, uses this to advance its own
  running code-offset for Pass 1 label assignment).  In Pass 2 only, bytes
  are additionally written to Rdoff via Rdoff.EmitByte/EmitWord, and
  label-valued displacements get a RDFREC_RELOC.  This guarantees Pass 1's
  byte count and Pass 2's actual emission can never drift apart -- there is
  only one code path, not two hand-synced copies.

  8086 addressing modes (no SIB, no 32-bit forms):
    Mod=00: [BX+SI] [BX+DI] [BP+SI] [BP+DI] [SI] [DI] [disp16] [BX]
            (rm=110 with Mod=00 means [disp16] direct, not [BP])
    Mod=01: same base table + disp8
    Mod=10: same base table + disp16
    Mod=11: register-direct
*)
IMPORT Rdoff, Sym, LogErr, Strings, Lex;

CONST
  (* Operand kinds *)
  OKNone*   = 0;
  OKReg*    = 1;   (* register-direct: reg field identifies which *)
  OKMem*    = 2;   (* [base(+index)+disp] or [disp16] *)
  OKImm*    = 3;   (* immediate constant / label-as-immediate *)
  OKSegReg* = 4;   (* segment register (ES/CS/SS/DS) used as a GPR-like
                       operand, e.g. "mov ax, cs" / "push ds" -- distinct
                       from OKReg because segment register numbers (0..3)
                       collide with general register numbers (0..3 = AX/CX/
                       DX/BX) and use entirely different opcodes (8C/8E for
                       MOV, 06/0E/16/1E push, 07/17/1F pop -- no POP CS). *)

  (* Operand sizes *)
  SzNone* = 0;
  SzByte* = 1;
  SzWord* = 2;

  (* Register codes (0..7 = AX/CX/DX/BX/SP/BP/SI/DI for word regs;
     0..7 = AL/CL/DL/BL/AH/CH/DH/BH for byte regs) *)
  RAX* = 0; RCX* = 1; RDX* = 2; RBX* = 3; RSP* = 4; RBP* = 5; RSI* = 6; RDI* = 7;
  RAL* = 0; RCL* = 1; RDL* = 2; RBL* = 3; RAH* = 4; RCH* = 5; RDH* = 6; RBH* = 7;

  (* Segment registers *)
  SegES* = 0; SegCS* = 1; SegSS* = 2; SegDS* = 3;
  NoSeg* = -1;

  (* Base/index addressing-mode table selector (0..7), matching the 8086
     Mod=00/01/10 rm field encoding; 6 means [disp16] (Mod=00 direct) or
     [BP+disp] (Mod=01/10). *)
  AmBxSi* = 0; AmBxDi* = 1; AmBpSi* = 2; AmBpDi* = 3;
  AmSi*   = 4; AmDi*   = 5; AmDisp* = 6; AmBx*   = 7;
  AmNone* = -1;   (* no base/index register at all: [disp16] direct memory *)

TYPE
  (* A fully-parsed operand. *)
  Operand* = RECORD
    kind*:      INTEGER;
    size*:      INTEGER;
    reg*:       INTEGER;      (* OKReg: which register *)
    am*:        INTEGER;      (* OKMem: addressing-mode selector, or AmNone *)
    seg*:       INTEGER;      (* OKMem: segment override, or NoSeg *)
    disp*:      LONGINT;      (* OKMem/OKImm: numeric part *)
    hasLabel*:  BOOLEAN;      (* OKMem/OKImm: disp includes an unresolved/external symbol *)
    labelName*: ARRAY Sym.MaxName OF CHAR;
    isFar*:     BOOLEAN;      (* OKMem: `far [reg]` indirect call/jmp *)
    isSegOf*:   BOOLEAN;      (* OKImm: `SEG label` -- value is the label's
                                  paragraph (SEGRELOC), not its offset (RELOC) *)
    isShort*:   BOOLEAN       (* OKImm jump target: `SHORT` keyword was given
                                  explicitly -- forces the 2-byte rel8 form
                                  and makes an out-of-range target a hard
                                  error instead of silently widening *)
  END;

VAR
  obj:      Rdoff.ObjFile;
  curFname: ARRAY 128 OF CHAR;
  curLine:  LONGINT;
  pass:     INTEGER;          (* 1 or 2 *)
  here:     LONGINT;          (* current code offset -- Parse.MOD's own running
                                  counter, valid in BOTH passes (Rdoff.CodeLen is
                                  only meaningful in pass 2, since pass 1 never
                                  writes to Rdoff at all) *)
  emitted:  LONGINT;          (* bytes emitted by the current EncodeInstr call *)
  failed:   BOOLEAN;          (* TRUE if the current instruction could not be sized/encoded *)

PROCEDURE SetObj*(o: Rdoff.ObjFile);
BEGIN obj := o
END SetObj;

PROCEDURE SetContext*(fname: ARRAY OF CHAR; line: LONGINT; curPass: INTEGER; curOfs: LONGINT);
BEGIN
  Strings.Copy(fname, curFname); curLine := line; pass := curPass; here := curOfs;
  emitted := LONGINT(0); failed := FALSE
END SetContext;

PROCEDURE Emitted*(): LONGINT;
BEGIN RETURN emitted
END Emitted;

PROCEDURE Failed*(): BOOLEAN;
BEGIN RETURN failed
END Failed;

PROCEDURE Err(msg: ARRAY OF CHAR);
BEGIN LogErr.ErrorInFile(curFname, curLine, msg); failed := TRUE
END Err;

(* ---- low-level byte emission: always counts; only writes in pass 2 ---- *)

PROCEDURE B(b: BYTE);
BEGIN
  IF pass = 2 THEN Rdoff.EmitByte(obj, Rdoff.SegCode, b) END;
  emitted := emitted + LONGINT(1); here := here + LONGINT(1)
END B;

PROCEDURE W(w: INTEGER);
BEGIN
  IF pass = 2 THEN Rdoff.EmitWord(obj, Rdoff.SegCode, w) END;
  emitted := emitted + LONGINT(2); here := here + LONGINT(2)
END W;

(* AddReloc: pass-2 only.  Adds a RDFREC_RELOC for the just-emitted disp16
   field, resolving against a label already defined in Sym (guaranteed by
   the two-pass structure: Pass 1 finishes assigning every label's offset
   before Pass 2 runs, so every reference resolves except a genuinely
   undefined symbol, which is a fatal error). *)
PROCEDURE AddReloc(patchOfs: LONGINT; labelSeg: INTEGER; width: INTEGER);
BEGIN
  IF labelSeg = Sym.SegCode THEN
    Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, width, Rdoff.SegCode, FALSE)
  ELSIF labelSeg = Sym.SegData THEN
    Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, width, Rdoff.SegData, FALSE)
  ELSE
    Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, width, Rdoff.SegBss, FALSE)
  END
END AddReloc;

(* SegPrefixByte: exported (D fix) so Parse.MOD can synthesize a leading
   segment-override prefix byte for the "es stosb"-style form (a bare
   segment-register token before a string op, distinct from the
   `[es:...]` memory-operand override this procedure already serves via
   EmitSegPrefix below). *)
PROCEDURE SegPrefixByte*(seg: INTEGER): BYTE;
BEGIN
  CASE seg OF
    SegES: RETURN BYTE(026H)
  | SegCS: RETURN BYTE(02EH)
  | SegSS: RETURN BYTE(036H)
  | SegDS: RETURN BYTE(03EH)
  ELSE RETURN BYTE(0)
  END
END SegPrefixByte;

PROCEDURE EmitSegPrefix(seg: INTEGER);
BEGIN IF seg # NoSeg THEN B(SegPrefixByte(seg)) END
END EmitSegPrefix;

(* PrefixByteFor: LOCK/REP* pseudo-mnemonic id -> its x86 prefix byte.
   LOCK=F0H; REP/REPE/REPZ share F3H (REP for string-store/move ops, REPE/
   REPZ for string-compare/scan ops -- same opcode byte on real 8086, NASM
   accepts all three spellings); REPNE/REPNZ share F2H.  Called from
   Parse.MOD once a leading LOCK/REP* token is recognized; the resulting
   byte is threaded through to Encode* as `prefixByte` and emitted first,
   before the segment-override prefix. *)
PROCEDURE PrefixByteFor*(mnemId: INTEGER): BYTE;
BEGIN
  CASE mnemId OF
    Lex.MLock: RETURN BYTE(0F0H)
  | Lex.MRep, Lex.MRepe, Lex.MRepz: RETURN BYTE(0F3H)
  | Lex.MRepne, Lex.MRepnz: RETURN BYTE(0F2H)
  ELSE RETURN BYTE(0)
  END
END PrefixByteFor;

PROCEDURE ModRmByte(modv, regField, rm: INTEGER): BYTE;
BEGIN RETURN BYTE(modv * 64 + regField * 8 + rm)
END ModRmByte;

(* ResolveW: resolve mem/imm's label (if any) to a 16-bit patched value and
   emit it, adding a relocation in pass 2.  Used for both ModRM disp16 and
   plain word immediates that reference a label (e.g. MOV AX, label). *)
(* EnsureImportId: return the RDOFF2 import segment ID for an EXTERN
   symbol, assigning one via Rdoff.RdfAddImport the first time it's
   actually referenced (cached in Sym so a symbol used N times gets
   exactly one IMPORT record).  Pass-2 only (import IDs, like all other
   header records, are only meaningful once Rdoff is actually being
   written). *)
PROCEDURE EnsureImportId*(name: ARRAY OF CHAR): INTEGER;
  VAR id: INTEGER;
BEGIN
  id := Sym.GetImportId(name);
  IF id = 0 THEN
    id := Rdoff.RdfAddImport(obj, name);
    Sym.SetImportId(name, id)
  END;
  RETURN id
END EnsureImportId;

PROCEDURE EmitDisp16(VAR op: Operand);
  VAR lseg: INTEGER; lofs: LONGINT; patchOfs: LONGINT; impId: INTEGER;
BEGIN
  IF op.hasLabel THEN
    IF Sym.IsExtern(op.labelName) THEN
      (* External symbol: offset is unknown until link time -- the addend
         is 0 (no local offset to add in), and the RELOC's RSEG is the
         import ID (per DOCS/RDOFF2.MD §3.3 "RSEG >2 = Import ID"), not
         SegCode/SegData. *)
      (* N4 residual fix: the +n addend of "extlabel+n" wraps mod 65536
         in W's INTEGER truncation just like a plain word value -- guard
         it with the same bounds as the non-label arm below. *)
      IF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
        Err("word value out of range"); W(0); RETURN
      END;
      patchOfs := Rdoff.CodeLen(obj);
      W(INTEGER(op.disp));
      IF pass = 2 THEN
        impId := EnsureImportId(op.labelName);
        IF op.isSegOf THEN
          Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, impId)
        ELSE
          Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, 2, impId, FALSE)
        END
      END
    ELSIF ~Sym.Lookup(op.labelName, lseg, lofs) THEN
      Err("undefined symbol"); W(0)
    ELSE
      patchOfs := Rdoff.CodeLen(obj);
      IF op.isSegOf THEN
        (* SEGRELOC patches a paragraph/segment value, not an offset -- the
           on-disk word is a pure placeholder (0), unlike the absolute-
           offset RELOC case below. *)
        W(INTEGER(op.disp))
      ELSE
        (* Absolute RELOC (RDOFF2 §3.3): "*Patch_Location += Target_Symbol_
           Address".  For an RSEG=0/1 (this module's own code/data segment)
           reference, the linker's large-model address formula
           (DOCS/RDOFF2.MD §6.4) computes
             *PatchAddr += module_code_ofs (group-relative base of the
             WHOLE module's code/data section)
           so the addend already on disk before linking must be the
           target's own LOCAL offset within that section (lofs+op.disp),
           not 0 -- verified against SYSTEM.RDF, a real-NASM-built oracle,
           which pre-fills exactly this value at every intra-module RELOC
           site.
           N4 residual fix: that sum wraps mod 65536 in W's INTEGER
           truncation just like a plain word value ("mov ax, tbl+70000"
           silently became "mov ax, tbl+4464") -- same guard/bounds as
           the non-label arm below. *)
        IF (op.disp + lofs < LONGINT(-32768)) OR (op.disp + lofs > LONGINT(65535)) THEN
          Err("word value out of range"); W(0); RETURN
        END;
        W(INTEGER(op.disp + lofs))
      END;
      IF pass = 2 THEN
        IF op.isSegOf THEN
          IF lseg = Sym.SegCode THEN
            Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, Rdoff.SegCode)
          ELSIF lseg = Sym.SegData THEN
            Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, Rdoff.SegData)
          ELSE
            Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, Rdoff.SegBss)
          END
        ELSE
          AddReloc(patchOfs, lseg, 2)
        END
      END
    END
  ELSIF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
    (* N4 fix: same class of trap C5 closed for byte immediates -- W's
       INTEGER(op.disp) truncation silently wraps any out-of-range word
       value mod 65536 (e.g. "mov ax, 70000" -> "mov ax, 4464"). *)
    Err("word value out of range"); W(0)
  ELSE
    W(INTEGER(op.disp))
  END
END EmitDisp16;

(* EmitModRm: mem operand supplies addressing; regField is the /reg (or
   opcode-extension) nibble. *)
(* EmitModRm: the segment-override prefix (if any) is emitted separately,
   by Encode*, BEFORE the opcode byte -- a prefix must precede the whole
   instruction (prefix, opcode, ModRM, disp), not just the ModRM byte, so
   it cannot be emitted here (this runs after EncMov/EncAlu/etc. have
   already written their opcode byte via B()).  See Encode*'s own leading
   EmitSegPrefix(SegOfOperands(...)) call. *)
PROCEDURE EmitModRm(regField: INTEGER; VAR mem: Operand);
  VAR modv: INTEGER;
BEGIN
  IF mem.kind = OKReg THEN
    B(ModRmByte(3, regField, mem.reg)); RETURN
  END;
  IF mem.kind # OKMem THEN
    Err("register or memory operand required"); RETURN
  END;
  (* OKMem *)
  IF mem.am = AmNone THEN
    B(ModRmByte(0, regField, AmDisp));
    EmitDisp16(mem);
    RETURN
  END;
  IF mem.hasLabel THEN
    (* M1 fix: [label+reg] must always carry a disp16 RELOC (Mod=10),
       even when the label's own constant offset happens to be 0 --
       the mem.disp=0 branch below picks Mod=00 (no displacement byte
       at all) purely from the numeric disp, which silently dropped the
       label's relocation entirely for e.g. "[table+bx]" where table's
       local disp is 0. A label reference is never "no displacement". *)
    modv := 2
  ELSIF mem.disp = 0 THEN
    (* [BP] with disp=0 must still encode disp8=0 (Mod=01): Mod=00,rm=110
       is reserved for the [disp16] direct-address form, not [BP]. *)
    IF mem.am = AmDisp THEN modv := 1 ELSE modv := 0 END
  ELSIF (mem.disp >= -128) & (mem.disp <= 127) THEN
    modv := 1
  ELSE
    modv := 2
  END;
  B(ModRmByte(modv, regField, mem.am));
  IF modv = 1 THEN
    B(BYTE(mem.disp))
  ELSIF modv = 2 THEN
    EmitDisp16(mem)
  END
END EmitModRm;

CONST
  MaxOperands* = 3;

(* ---- immediate emission, size-selected by the destination operand ---- *)

PROCEDURE EmitImm(VAR imm: Operand; wide: BOOLEAN);
BEGIN
  IF wide THEN EmitDisp16(imm)
  ELSIF imm.hasLabel THEN
    (* a label's low byte is not a meaningful value and RDOFF2 has no
       byte-sized relocation type -- BUG A6: silently emitted BYTE(0) with
       no diagnostic and no reloc, dropping the reference entirely. *)
    Err("label not allowed as byte immediate")
  ELSIF (imm.disp < -128) OR (imm.disp > 255) THEN
    (* C5 fix: BYTE(imm.disp) silently truncates any out-of-range value
       (e.g. "mov al, 300") -- reject rather than wrap. *)
    Err("byte immediate out of range (-128..255)")
  ELSE B(BYTE(imm.disp))
  END
END EmitImm;

(* ---- register-only / no-memory-operand instructions (Suggested
   implementation order step 3): PUSH/POP/INC/DEC reg, register-to-register
   arithmetic, INT imm8, RET/RETN/RETF [imm16], CLD/CLI/STI/PUSHF/POPF. ---- *)

PROCEDURE EncPushPopReg(opcodeBase: BYTE; VAR op: Operand);
BEGIN
  IF op.kind = OKReg THEN
    (* N2 fix: the 50+r/58+r short forms are WORD-only on 8086 -- "push al"
       must not silently become "push ax" (there is no byte PUSH/POP). *)
    IF op.size # SzWord THEN Err("operand size mismatch"); RETURN END;
    B(BYTE(INTEGER(opcodeBase) + op.reg))
  ELSE
    Err("PUSH/POP requires a register or memory operand")
  END
END EncPushPopReg;

(* Group opcode FF /rm (PUSH mem) or 8F /0 (POP mem) -- memory-operand form. *)
PROCEDURE EncPushMem(VAR op: Operand);
BEGIN EmitModRm(6, op)
END EncPushMem;

(* PUSH imm16 (68H) / PUSH imm8 (6AH, sign-extended) -- both are 80186+
   opcodes, NOT genuine 8086 (CLAUDE.md targets pure 8086; PROHIBITED for
   generated code -- see SRC/CC/CCASM.MOD's EmitIntr, which hit this the
   hard way: `xt` decodes 68H as an invalid opcode and halts).  Encoding
   is included here only because TASM is a general assembler front-end
   (a .ASM author could still write PUSH imm and expect NASM-compatible
   bytes out); callers targeting this project's real 8086 execution
   environment must avoid it (e.g. "xor ax,ax / push ax" instead of
   "push word 0"). Labels as push operands are not supported (PUSH imm
   has no relocation use case in this codebase's fixtures; a bare "push
   label" already parses as OKImm with hasLabel and would need
   EmitDisp16 -- left unimplemented until a real .asm needs it). *)
PROCEDURE EncPushImm(VAR op: Operand);
BEGIN
  IF op.hasLabel THEN Err("PUSH label immediate not supported"); RETURN END;
  IF op.size = SzByte THEN
    B(BYTE(06AH)); B(BYTE(op.disp))
  ELSE
    (* N4 fix: same word-range guard as EmitDisp16 -- W's truncation
       silently wraps an out-of-range PUSH immediate mod 65536. *)
    IF (op.disp < LONGINT(-32768)) OR (op.disp > LONGINT(65535)) THEN
      Err("word value out of range"); RETURN
    END;
    B(BYTE(068H)); W(INTEGER(op.disp))
  END
END EncPushImm;

PROCEDURE EncPopMem(VAR op: Operand);
BEGIN EmitModRm(0, op)
END EncPopMem;

(* IncDecRm -- group FE/FF, /0=INC /1=DEC, works for both reg and mem, byte
   or word (opcode's low bit selects width: FE=byte, FF=word). *)
PROCEDURE EncIncDec(ext: INTEGER; VAR op: Operand);
BEGIN
  IF op.kind = OKReg THEN
    IF op.size = SzWord THEN
      (* compact single-byte form: INC reg16 = 40+r, DEC reg16 = 48+r *)
      IF ext = 0 THEN B(BYTE(040H + op.reg)) ELSE B(BYTE(048H + op.reg)) END
    ELSE
      B(BYTE(0FEH)); EmitModRm(ext, op)
    END
  ELSE
    IF op.size = SzNone THEN
      Err("operation size not specified"); RETURN
    END;
    IF op.size = SzByte THEN B(BYTE(0FEH)) ELSE B(BYTE(0FFH)) END;
    EmitModRm(ext, op)
  END
END EncIncDec;

(* ---- MOV ---- *)

PROCEDURE EncMov(VAR dst, src: Operand);
BEGIN
  IF (dst.kind = OKSegReg) & ((src.kind = OKReg) OR (src.kind = OKMem)) THEN
    (* MOV Sreg, r/m16 -> 8E /r (segment register in the /reg field).
       N2 fix: the r/m must be word-sized -- a byte register (e.g.
       "mov ds, al") shares AL's reg code with AX and would silently
       encode as "mov ds, ax" otherwise; a BYTE-qualified [mem]
       ("mov ds, byte [x]") is the same mismatch spelled on a memory
       operand (an UNSIZED [mem] is fine -- 8E always moves a word). *)
    IF (src.size # SzNone) & (src.size # SzWord) THEN
      Err("operand size mismatch"); RETURN
    END;
    B(BYTE(08EH)); EmitModRm(dst.reg, src)
  ELSIF (src.kind = OKSegReg) & ((dst.kind = OKReg) OR (dst.kind = OKMem)) THEN
    (* MOV r/m16, Sreg -> 8C /r. Same N2 fix, mirrored. *)
    IF (dst.size # SzNone) & (dst.size # SzWord) THEN
      Err("operand size mismatch"); RETURN
    END;
    B(BYTE(08CH)); EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKImm) THEN
    (* compact form: B0+r ib / B8+r iw *)
    IF dst.size = SzByte THEN B(BYTE(0B0H + dst.reg)); EmitImm(src, FALSE)
    ELSE B(BYTE(0B8H + dst.reg)); EmitImm(src, TRUE)
    END
  ELSIF src.kind = OKImm THEN
    (* MOV mem, imm: C6 /0 ib  or  C7 /0 iw *)
    IF (dst.kind = OKMem) & (dst.size = SzNone) THEN
      Err("operation size not specified"); RETURN
    END;
    IF dst.size = SzByte THEN B(BYTE(0C6H)); EmitModRm(0, dst); EmitImm(src, FALSE)
    ELSE B(BYTE(0C7H)); EmitModRm(0, dst); EmitImm(src, TRUE)
    END
  ELSIF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzWord) & (src.kind = OKMem)
        & (src.am = AmNone) THEN
    (* MOV AX, [disp16]  ->  A1 disp16  (the moffs16 short form; valid with
       a segment-override prefix too, e.g. "mov ax, [cs:x]" -> 2E A1). *)
    B(BYTE(0A1H)); EmitDisp16(src)
  ELSIF (dst.kind = OKReg) & (dst.reg = RAL) & (dst.size = SzByte) & (src.kind = OKMem)
        & (src.am = AmNone) THEN
    (* MOV AL, [disp16]  ->  A0 disp16 (the moffs8 short form). *)
    B(BYTE(0A0H)); EmitDisp16(src)
  ELSIF (src.kind = OKReg) & (src.reg = RAX) & (src.size = SzWord) & (dst.kind = OKMem)
        & (dst.am = AmNone) THEN
    (* MOV [disp16], AX  ->  A3 disp16 *)
    B(BYTE(0A3H)); EmitDisp16(dst)
  ELSIF (src.kind = OKReg) & (src.reg = RAL) & (src.size = SzByte) & (dst.kind = OKMem)
        & (dst.am = AmNone) THEN
    (* MOV [disp16], AL  ->  A2 disp16  (verified against SYSTEM.RDF's
       "mov BYTE[cs:err_code], AL" -> 2E A2 disp16, not the equally-valid
       general ModRM form 2E 88 06 disp16 that a naive encoder would pick). *)
    B(BYTE(0A2H)); EmitDisp16(dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKReg) THEN
    (* register-to-register MOV: NASM always encodes opcode 88/89 (r/m,
       reg) with dst as the r/m field and src as /reg, never 8A/8B --
       verified against SYSTEM.RDF's "mov bx, sp" (oracle: 89 E3, i.e.
       dst=BX in r/m, src=SP in /reg -- not the equally-valid 8B DC).
       N2 fix: dst/src reg codes overlap across sizes (AL=AX=0, BL=BX=3,
       ...), so a mismatched pair (e.g. "mov al, bx") must be rejected
       instead of silently renaming one side to its same-numbered
       same-size counterpart. *)
    IF dst.size # src.size THEN Err("operand size mismatch"); RETURN END;
    IF dst.size = SzByte THEN B(BYTE(088H)) ELSE B(BYTE(089H)) END;
    EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKMem) THEN
    IF dst.size = SzByte THEN B(BYTE(08AH)) ELSE B(BYTE(08BH)) END;
    EmitModRm(dst.reg, src)
  ELSIF (src.kind = OKReg) & (dst.kind = OKMem) THEN
    IF src.size = SzByte THEN B(BYTE(088H)) ELSE B(BYTE(089H)) END;
    EmitModRm(src.reg, dst)
  ELSE
    Err("unsupported MOV operand combination")
  END
END EncMov;

(* ---- generic ALU group: ADD/OR/ADC/SBB/AND/SUB/XOR/CMP share one
   opcode-block layout (Intel's classic "group 1"), selected by `ext`
   0..7 in that order.  Forms:
     ext,00 /r   : op r/m8, r8
     ext,01 /r   : op r/m16, r16
     ext,02 /r   : op r8, r/m8
     ext,03 /r   : op r16, r/m16
     04 ib       : op AL, imm8       (only ext=0 uses the block base+0..5 shortcuts;
     05 iw       : op AX, imm16       generalized below via the block base)
     80 /ext ib  : op r/m8, imm8
     81 /ext iw  : op r/m16, imm16
   `base` is the block's opcode base (ADD=0x00, OR=0x08, ADC=0x10, SBB=0x18,
   AND=0x20, SUB=0x28, XOR=0x30); CMP has no accumulator-shortcut collision
   issue since it is block base 0x38, ext=7.  The 83 /ext ib (sign-extended
   imm8) short form is intentionally NOT auto-selected even when the
   immediate fits in a byte: real NASM (without -O) never performs this
   optimization on its own, and always emits the full-width 81 iw form
   unless the source uses BYTE-qualified syntax -- verified against
   SYSTEM.RDF's "sub sp, 4" -> 81 EC 04 00, not 83 EC 04. *)
PROCEDURE EncAlu(base: BYTE; ext: INTEGER; VAR dst, src: Operand);
  VAR wide: BOOLEAN;
BEGIN
  wide := dst.size = SzWord;
  IF src.kind = OKImm THEN
    IF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzByte) THEN
      B(BYTE(INTEGER(base) + 4)); EmitImm(src, FALSE)
    ELSIF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzWord) THEN
      B(BYTE(INTEGER(base) + 5)); EmitImm(src, TRUE)
    ELSIF (dst.kind = OKMem) & (dst.size = SzNone) THEN
      Err("operation size not specified")
    ELSIF wide THEN
      B(BYTE(081H)); EmitModRm(ext, dst); EmitImm(src, TRUE)
    ELSE
      B(BYTE(080H)); EmitModRm(ext, dst); EmitImm(src, FALSE)
    END
  ELSIF (dst.kind = OKReg) & (src.kind = OKReg) THEN
    (* register-to-register: same NASM convention as MOV (see EncMov) --
       always the r/m,reg direction (base+0/1), dst in r/m, src in /reg,
       never base+2/3.  Verified against SYSTEM.RDF's "xor ah, ah" -> 30 E4
       (opcode 0x30 = base+0 for XOR's base 0x30), not 32 E4.
       N2 fix: reject a size mismatch, same as the mem,reg arms below. *)
    IF dst.size # src.size THEN Err("operand size mismatch"); RETURN END;
    IF wide THEN B(BYTE(INTEGER(base) + 1)) ELSE B(BYTE(INTEGER(base))) END;
    EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKMem) THEN
    IF wide THEN B(BYTE(INTEGER(base) + 3)) ELSE B(BYTE(INTEGER(base) + 2)) END;
    EmitModRm(dst.reg, src)
  ELSIF (src.kind = OKReg) & (dst.kind = OKMem) THEN
    (* R2 fix: width must come from the REGISTER operand, not dst.size --
       dst.size may be SzNone for an unqualified `[mem]` (B1 stopped
       defaulting it to SzWord), and the top-of-procedure `wide` was
       computed from dst.size alone, so e.g. `add [wvar], ax` silently
       encoded the BYTE opcode (00, not 01) with a word register --
       verified: pre-B1 the WORD default masked this, post-B1 it went
       silently wrong instead of erroring. Also reject a genuine
       size mismatch between an explicit `[mem]` qualifier and the
       register width (e.g. `add byte [x], ax`). *)
    IF (dst.size # SzNone) & (dst.size # src.size) THEN
      Err("operand size mismatch"); RETURN
    END;
    IF src.size = SzWord THEN B(BYTE(INTEGER(base) + 1)) ELSE B(BYTE(INTEGER(base))) END;
    EmitModRm(src.reg, dst)
  ELSE
    Err("unsupported ALU operand combination")
  END
END EncAlu;

(* ---- TEST: same shape as CMP but a distinct, smaller opcode family
   (no 83 sign-extend-imm8 short form, no subtract-with-borrow variants). *)
PROCEDURE EncTest(VAR dst, src: Operand);
  VAR wide: BOOLEAN;
BEGIN
  wide := dst.size = SzWord;
  IF src.kind = OKImm THEN
    IF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzByte) THEN
      B(BYTE(0A8H)); EmitImm(src, FALSE)
    ELSIF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzWord) THEN
      B(BYTE(0A9H)); EmitImm(src, TRUE)
    ELSIF (dst.kind = OKMem) & (dst.size = SzNone) THEN
      Err("operation size not specified")
    ELSIF wide THEN
      B(BYTE(0F7H)); EmitModRm(0, dst); EmitImm(src, TRUE)
    ELSE
      B(BYTE(0F6H)); EmitModRm(0, dst); EmitImm(src, FALSE)
    END
  ELSIF (src.kind = OKReg) & (dst.kind = OKReg) THEN
    (* N2 fix: reject a size mismatch, same as the mem,reg arms below. *)
    IF dst.size # src.size THEN Err("operand size mismatch"); RETURN END;
    IF wide THEN B(BYTE(085H)) ELSE B(BYTE(084H)) END;
    EmitModRm(src.reg, dst)
  ELSIF (src.kind = OKReg) & (dst.kind = OKMem) THEN
    (* R2 fix: same width-from-register fix as EncAlu -- dst.size (the
       memory operand) may be SzNone for an unqualified `[mem]`, so width
       must come from src.size (the register), not the top-of-procedure
       `wide` which was computed from dst.size alone. *)
    IF (dst.size # SzNone) & (dst.size # src.size) THEN
      Err("operand size mismatch"); RETURN
    END;
    IF src.size = SzWord THEN B(BYTE(085H)) ELSE B(BYTE(084H)) END;
    EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKMem) THEN
    (* D fix: NASM accepts "test reg, mem" (TEST is commutative, unlike
       CMP/SUB) by swapping to the reg,mem encoding above -- TASM only
       had the mem,reg (dst=mem) form. Same width-from-register /
       size-mismatch guard as the dst=mem arm, mirrored with dst/src
       swapped. *)
    IF (src.size # SzNone) & (src.size # dst.size) THEN
      Err("operand size mismatch"); RETURN
    END;
    IF dst.size = SzWord THEN B(BYTE(085H)) ELSE B(BYTE(084H)) END;
    EmitModRm(dst.reg, src)
  ELSE
    Err("unsupported TEST operand combination")
  END
END EncTest;

(* ---- single-operand group F6/F7: NOT=/2 NEG=/3 MUL=/4 ---- *)
PROCEDURE EncUnaryGroup(ext: INTEGER; VAR op: Operand);
BEGIN
  IF (op.kind = OKMem) & (op.size = SzNone) THEN
    Err("operation size not specified"); RETURN
  END;
  IF op.size = SzByte THEN B(BYTE(0F6H)) ELSE B(BYTE(0F7H)) END;
  EmitModRm(ext, op)
END EncUnaryGroup;

(* ---- shift/rotate group D0/D1 (by 1) or D2/D3 (by CL): ROL=/0 ROR=/1
   RCL=/2 RCR=/3 SHL=/4 (SAL is a pure assembler alias for SHL, same /4)
   SHR=/5 SAR=/7.  8086 has no immediate-count shift (that's a 186+
   extension) -- only "by 1" or "by CL" forms exist here. *)
PROCEDURE EncShift(ext: INTEGER; VAR dst, cnt: Operand);
  VAR wide: BOOLEAN;
BEGIN
  IF (dst.kind = OKMem) & (dst.size = SzNone) THEN
    Err("operation size not specified"); RETURN
  END;
  wide := dst.size = SzWord;
  IF (cnt.kind = OKImm) & (cnt.disp = LONGINT(1)) & ~cnt.hasLabel THEN
    IF wide THEN B(BYTE(0D1H)) ELSE B(BYTE(0D0H)) END;
    EmitModRm(ext, dst)
  ELSIF (cnt.kind = OKReg) & (cnt.reg = RCL) THEN
    IF wide THEN B(BYTE(0D3H)) ELSE B(BYTE(0D2H)) END;
    EmitModRm(ext, dst)
  ELSE
    Err("shift count must be 1 or CL on 8086")
  END
END EncShift;

(* ---- XCHG: AX,reg has a 1-byte short form (90+r); otherwise the general
   87 /r (word) or 86 /r (byte) ModRM form. *)
(* NOTE: deliberately does NOT copy a VAR-param Operand into a local via
   `:=` (e.g. "other := b") -- a compiler codegen bug (under investigation)
   makes that copy read from the WRONG VAR parameter's address when a
   procedure has two VAR params of the same RECORD type.  EmitModRm is
   called directly on the VAR params themselves instead. *)
PROCEDURE EncXchg(VAR a, b: Operand);
BEGIN
  IF (a.kind = OKReg) & (a.reg = RAX) & (a.size = SzWord) & (b.kind = OKReg) THEN
    (* N2 fix: the AX short form (90+r) always encodes a WORD swap --
       "xchg ax, bl" must not silently become "xchg ax, bx". *)
    IF b.size # SzWord THEN Err("operand size mismatch"); RETURN END;
    B(BYTE(090H + b.reg))
  ELSIF (b.kind = OKReg) & (b.reg = RAX) & (b.size = SzWord) & (a.kind = OKReg) THEN
    IF a.size # SzWord THEN Err("operand size mismatch"); RETURN END;
    B(BYTE(090H + a.reg))
  ELSIF (a.kind = OKReg) & (b.kind = OKReg) THEN
    (* N2 fix: general reg,reg form -- both sides must agree in size. *)
    IF a.size # b.size THEN Err("operand size mismatch"); RETURN END;
    IF a.size = SzByte THEN B(BYTE(086H)) ELSE B(BYTE(087H)) END;
    EmitModRm(a.reg, b)
  ELSIF a.kind = OKReg THEN
    (* reg,mem arm -- same explicit-qualifier mismatch guard as EncAlu's
       R2 fix: "xchg ax, byte [x]" must not silently ignore the BYTE
       qualifier and encode a word XCHG. An UNSIZED [mem] still takes
       its width from the register, as everywhere else. *)
    IF (b.size # SzNone) & (b.size # a.size) THEN
      Err("operand size mismatch"); RETURN
    END;
    IF a.size = SzByte THEN B(BYTE(086H)) ELSE B(BYTE(087H)) END;
    EmitModRm(a.reg, b)
  ELSIF b.kind = OKReg THEN
    IF (a.size # SzNone) & (a.size # b.size) THEN
      Err("operand size mismatch"); RETURN
    END;
    IF b.size = SzByte THEN B(BYTE(086H)) ELSE B(BYTE(087H)) END;
    EmitModRm(b.reg, a)
  ELSE
    Err("XCHG requires at least one register operand")
  END
END EncXchg;

(* ---- LEA / LES: both are reg16, mem -- 8D /r and C4 /r. ---- *)
PROCEDURE EncLea(VAR dst, src: Operand);
BEGIN
  IF (dst.kind # OKReg) OR (src.kind # OKMem) THEN Err("LEA requires reg, mem")
  ELSE B(BYTE(08DH)); EmitModRm(dst.reg, src)
  END
END EncLea;

PROCEDURE EncLes(VAR dst, src: Operand);
BEGIN
  IF (dst.kind # OKReg) OR (src.kind # OKMem) THEN Err("LES requires reg, mem")
  ELSE B(BYTE(0C4H)); EmitModRm(dst.reg, src)
  END
END EncLes;

(* EncLds: identical to EncLes but opcode C5H instead of C4H -- LDS
   loads DS:reg from a far pointer in memory, LES loads ES:reg; same
   ModRM semantics either way. *)
PROCEDURE EncLds(VAR dst, src: Operand);
BEGIN
  IF (dst.kind # OKReg) OR (src.kind # OKMem) THEN Err("LDS requires reg, mem")
  ELSE B(BYTE(0C5H)); EmitModRm(dst.reg, src)
  END
END EncLds;

(* ---- INT imm8 ---- *)
PROCEDURE EncInt(VAR op: Operand);
BEGIN
  IF op.kind # OKImm THEN Err("INT requires an immediate byte")
  ELSIF op.hasLabel THEN Err("label not allowed here")  (* R6 fix *)
  ELSIF (op.disp < 0) OR (op.disp > 255) THEN
    Err("INT vector out of range (0..255)")  (* C5 fix *)
  ELSE B(BYTE(0CDH)); B(BYTE(op.disp))
  END
END EncInt;

(* ---- RET / RETN (near) = C3, or C2 iw if an imm16 pop-count is given.
   RETF (far) = CB, or CA iw. ---- *)
PROCEDURE EncRet(far: BOOLEAN; hasImm: BOOLEAN; VAR imm: Operand);
BEGIN
  IF hasImm THEN
    IF imm.kind # OKImm THEN Err("RET immediate must be a constant"); RETURN END;
    IF imm.hasLabel THEN Err("label not allowed here"); RETURN END;  (* R6 fix *)
    (* N4 fix: RET's imm16 operand count is a WORD -- "ret 65536" must not
       silently wrap to "ret 0". *)
    IF (imm.disp < LONGINT(-32768)) OR (imm.disp > LONGINT(65535)) THEN
      Err("word value out of range"); RETURN
    END;
    IF far THEN B(BYTE(0CAH)) ELSE B(BYTE(0C2H)) END;
    W(INTEGER(imm.disp))
  ELSE
    IF far THEN B(BYTE(0CBH)) ELSE B(BYTE(0C3H)) END
  END
END EncRet;

(* ---- no-operand single-byte instructions ---- *)
PROCEDURE EncNoOperand(opcode: BYTE);
BEGIN B(opcode)
END EncNoOperand;

(* ---- JMP / CALL, near / far, direct label or indirect memory ---- *)

(* EncJmpShort: unqualified JMP/Jcc -- policy (see DOCS/IMPLRULE.MD's TASM
   section, "short-vs-near jump sizing"): compute assuming rel8 in pass 1
   sizing (2 bytes total: opcode+rel8), validate in pass 2 that the real
   displacement still fits; a target that doesn't fit is a fatal error
   asking the source to be restructured (no iterative resizing, no
   NEAR-qualified auto-widening). *)
PROCEDURE EncJmpShort(opcode: BYTE; VAR target: Operand);
  VAR lseg: INTEGER; lofs, rel: LONGINT; instrEnd: LONGINT;
BEGIN
  IF ~target.hasLabel THEN Err("JMP/Jcc target must be a label"); RETURN END;
  IF pass = 1 THEN
    B(opcode); B(BYTE(0));   (* placeholder rel8; real size is always 2 bytes for short form *)
    RETURN
  END;
  IF Sym.IsExtern(target.labelName) THEN
    (* rel8 (short branch) has no RDOFF2 relocation type at all -- unlike
       EncNearRel/EmitDisp16, which route an EXTERN target through an
       RDFREC_IMPORT-relative reloc, there is no way to patch a 1-byte
       displacement against a symbol whose address is only known at link
       time. Sym.Lookup would otherwise return the reserved placeholder
       (SegCode, 0) for an EXTERN name (BUG A1's table never marks these
       "defined"), silently encoding a wild rel8 (BUG A4). *)
    Err("short branch to EXTERN symbol is impossible (rel8 has no relocation)");
    B(opcode); B(BYTE(0)); RETURN
  END;
  IF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
    Err("undefined symbol"); B(opcode); B(BYTE(0)); RETURN
  END;
  IF lseg # Sym.SegCode THEN
    (* C12 fix: a short branch to a data/bss label computes a rel8 across
       segments -- a meaningless value, usually (but not always) caught
       by the +-128 range check below since data/bss offsets are
       unrelated to code offsets; silent inside that window otherwise. *)
    Err("branch target is not in the code segment"); B(opcode); B(BYTE(0)); RETURN
  END;
  instrEnd := here + LONGINT(2);
  rel := lofs - instrEnd;
  IF (rel < -128) OR (rel > 127) THEN
    Err("branch target out of short (rel8) range -- restructure source"); B(opcode); B(BYTE(0)); RETURN
  END;
  B(opcode); B(BYTE(rel))
END EncJmpShort;

(* EncCallNear / EncJmpNear: E8/E9 rel16 direct call/jmp to a same-module
   code label. *)
PROCEDURE EncNearRel(opcode: BYTE; VAR target: Operand);
  VAR lseg: INTEGER; lofs, rel: LONGINT; instrEnd: LONGINT; impId: INTEGER; patchOfs: LONGINT;
BEGIN
  IF ~target.hasLabel THEN Err("target must be a label"); RETURN END;
  IF pass = 1 THEN
    B(opcode); W(0); RETURN   (* fixed 3-byte size regardless of target; real value patched in pass 2 *)
  END;
  IF Sym.IsExtern(target.labelName) THEN
    (* CALL/JMP to an external symbol: E8/E9 rel16 with a PC-relative
       RDFREC_RELOC against the import ID (RDOFF2 §3.3 "Relative"),
       addend = -(patch_offset_in_module + 2) per the large-model NEAR
       CALL convention documented in DOCS/RDOFF2.MD §6.4. *)
    B(opcode);
    patchOfs := Rdoff.CodeLen(obj);
    W(INTEGER(-(patchOfs + LONGINT(2))));
    impId := EnsureImportId(target.labelName);
    Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, 2, impId, TRUE);
    RETURN
  END;
  IF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
    Err("undefined symbol"); B(opcode); W(0); RETURN
  END;
  IF lseg # Sym.SegCode THEN
    Err("branch target is not in the code segment"); B(opcode); W(0); RETURN  (* C12 fix *)
  END;
  instrEnd := here + LONGINT(3);
  rel := lofs - instrEnd;
  B(opcode); W(INTEGER(rel))
END EncNearRel;

(* EncJmpAuto: unqualified JMP (no explicit SHORT/NEAR keyword) to a label.
   Real NASM auto-selects the 2-byte short (EB rel8) encoding whenever it
   safely can, falling back to the 3-byte near (E9 rel16) form otherwise --
   verified against SYSTEM.RDF, where "jmp ErrWithMsg" (a BACKWARD reference,
   already-defined at encode time) short-sizes to EB despite no `short`
   keyword in the source.

   This can only be done losslessly for a reference whose target is
   already DEFINED at the moment Pass 1 first walks past this instruction:
   for those, Pass 1 already knows the real distance and can pick a size.
   A FORWARD reference has no such fixed point without iterative resizing
   (the exact problem the short-vs-near jump sizing decision in
   DOCS/IMPLRULE.MD's TASM section avoids for Jcc/LOOP) -- so a forward
   JMP always takes the near (E9) form.

   CRITICAL: Sym's label table is NOT reset between passes (Pass 2 needs
   Pass 1's final offsets to resolve forward refs), so by the time Pass 2
   re-walks the SAME source line, Sym.IsDefined/Lookup reflect Pass 1's
   FINAL state -- every label looks "already defined", including ones that
   were genuinely still-forward at this exact point during Pass 1's own
   walk.  Re-deriving the short-vs-near choice independently in Pass 2
   would therefore pick short far more often than Pass 1 did, producing a
   different byte count and corrupting every subsequent label's offset.
   The fix: Pass 1's choice is authoritative and cached (keyed by `here`,
   the unique starting code-offset of this specific JMP instruction, valid
   as a key since code only grows monotonically); Pass 2 replays the same
   choice instead of re-deciding. *)
(* BUG B6: was a fixed ARRAY MaxJmpDecisions=128 -- the 129th unqualified
   auto-sized JMP in one file hit a hard "internal limit" error. Chunked
   linked list (CLAUDE.md "Chunk small records" rule), same shape as
   Sym.MOD's label/define tables: each entry is tiny (a LONGINT offset + a
   BOOLEAN), NEW'd once per auto-sized JMP encountered. *)
CONST JmpChunk = 32;
TYPE
  JmpDecNode = POINTER TO JmpDecNodeDesc;
  JmpDecNodeDesc = RECORD
    ofs*:   ARRAY JmpChunk OF LONGINT;
    short*: ARRAY JmpChunk OF BOOLEAN;
    count*: INTEGER;
    next*:  JmpDecNode
  END;
VAR
  jmpDecHead, jmpDecTail: JmpDecNode;

PROCEDURE ResetJmpDecisions*;
  VAR n, nn: JmpDecNode;
BEGIN
  (* free any chain from a PRIOR Assemble call in this process (CLAUDE.md
     zero-leak rule) -- called once per Pass 1, i.e. once per Assemble;
     within one Assemble, Pass 2 must NOT call this (it needs Pass 1's
     recorded decisions still present to replay), which the call sites in
     Parse.RunPass already guarantee (pass=1 only). *)
  n := jmpDecHead;
  WHILE n # NIL DO nn := n^.next; DISPOSE(n); n := nn END;
  jmpDecHead := NIL; jmpDecTail := NIL
END ResetJmpDecisions;

(* FreeJmpDecisions: release Pass 2's now-unneeded jmp-decision chain --
   called once at the END of Assemble (mirrors Sym.Free), so TASM.MOD's
   LeakGuard measurement (taken right after Assemble returns) doesn't see
   this chunk-list as a leak. *)
PROCEDURE FreeJmpDecisions*;
  VAR n, nn: JmpDecNode;
BEGIN
  n := jmpDecHead;
  WHILE n # NIL DO nn := n^.next; DISPOSE(n); n := nn END;
  jmpDecHead := NIL; jmpDecTail := NIL
END FreeJmpDecisions;

PROCEDURE RecordJmpDecision(ofs: LONGINT; isShort: BOOLEAN);
  VAR last: JmpDecNode;
BEGIN
  IF (jmpDecTail = NIL) OR (jmpDecTail^.count >= JmpChunk) THEN
    NEW(last);
    IF last = NIL THEN Err("out of memory (jmp-decision table)"); RETURN END;
    last^.count := 0; last^.next := NIL;
    IF jmpDecHead = NIL THEN jmpDecHead := last ELSE jmpDecTail^.next := last END;
    jmpDecTail := last
  END;
  jmpDecTail^.ofs[jmpDecTail^.count] := ofs;
  jmpDecTail^.short[jmpDecTail^.count] := isShort;
  INC(jmpDecTail^.count)
END RecordJmpDecision;

(* ReplayJmpDecision: pass 2 only -- find the decision recorded for the JMP
   instruction that started at code offset `ofs` during pass 1, in order
   (each pass 2 call consumes the next unconsumed record; since both
   passes walk instructions in the same source order, position-in-sequence
   is a simpler and equally correct key than the recorded offset itself).
   `ofs` is now actually cross-checked against the recorded offset (it was
   written but never read before this fix) -- a mismatch means pass 1 and
   pass 2 walked the source differently, i.e. some earlier encoder desynced
   the two passes' byte counts, exactly the class of bug old BUG 3's family
   was. *)
VAR replayNode: JmpDecNode; replayIdx: INTEGER;

PROCEDURE ResetJmpReplay*;
BEGIN replayNode := jmpDecHead; replayIdx := 0
END ResetJmpReplay;

PROCEDURE ReplayJmpDecision(ofs: LONGINT): BOOLEAN;
  VAR r: BOOLEAN;
BEGIN
  WHILE (replayNode # NIL) & (replayIdx >= replayNode^.count) DO
    replayNode := replayNode^.next; replayIdx := 0
  END;
  IF replayNode = NIL THEN
    Err("JMP auto-size replay ran out of pass-1 decisions (internal error)");
    RETURN FALSE
  END;
  IF replayNode^.ofs[replayIdx] # ofs THEN
    Err("JMP auto-size replay desynced from pass 1 (internal error)");
    RETURN FALSE
  END;
  r := replayNode^.short[replayIdx]; INC(replayIdx); RETURN r
END ReplayJmpDecision;

PROCEDURE EncJmpAuto(VAR target: Operand);
  VAR lseg: INTEGER; lofs, rel: LONGINT; instrEnd: LONGINT;
      startOfs: LONGINT; useShort: BOOLEAN;
BEGIN
  IF ~target.hasLabel THEN Err("JMP target must be a label"); RETURN END;
  startOfs := here;
  IF pass = 1 THEN
    IF ~Sym.IsDefined(target.labelName) THEN
      useShort := FALSE
    ELSIF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
      useShort := FALSE
    ELSE
      instrEnd := here + LONGINT(2);
      rel := lofs - instrEnd;
      useShort := (rel >= -128) & (rel <= 127)
    END;
    RecordJmpDecision(startOfs, useShort)
  ELSE
    useShort := ReplayJmpDecision(startOfs)
  END;
  IF useShort THEN
    IF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
      Err("undefined symbol"); B(BYTE(0EBH)); B(BYTE(0)); RETURN
    END;
    IF lseg # Sym.SegCode THEN
      Err("branch target is not in the code segment"); B(BYTE(0EBH)); B(BYTE(0)); RETURN  (* C12 fix *)
    END;
    instrEnd := here + LONGINT(2);
    rel := lofs - instrEnd;
    B(BYTE(0EBH)); B(BYTE(rel))
  ELSE
    EncNearRel(BYTE(0E9H), target)
  END
END EncJmpAuto;

(* EncJmpIndirect / EncCallIndirect: FF /4 (near) FF /5 (far) through a
   memory or register operand -- `far [reg]`/`far [mem]` selects /5. *)
PROCEDURE EncJmpIndirect(VAR mem: Operand);
BEGIN
  IF mem.isFar & (mem.kind = OKReg) THEN
    Err("far JMP/CALL cannot target a plain register (no segment half)"); RETURN
  END;
  (* N2 fix: a register target must be WORD-sized -- "jmp al" has no
     8-bit indirect-jump encoding and must not silently become "jmp ax". *)
  IF (mem.kind = OKReg) & (mem.size # SzWord) THEN
    Err("operand size mismatch"); RETURN
  END;
  B(BYTE(0FFH));
  IF mem.isFar THEN EmitModRm(5, mem) ELSE EmitModRm(4, mem) END
END EncJmpIndirect;

PROCEDURE EncCallIndirect(VAR mem: Operand);
BEGIN
  IF mem.isFar & (mem.kind = OKReg) THEN
    Err("far JMP/CALL cannot target a plain register (no segment half)"); RETURN
  END;
  IF (mem.kind = OKReg) & (mem.size # SzWord) THEN
    Err("operand size mismatch"); RETURN
  END;
  B(BYTE(0FFH));
  IF mem.isFar THEN EmitModRm(3, mem) ELSE EmitModRm(2, mem) END
END EncCallIndirect;

(* EncJmpFarDirect: JMP/CALL far ptr16:16 -- EA/9A followed by offset then
   segment word.  Does not occur in SYSTEM.ASM/EMS.ASM (both only use
   `call far [mem]`, the indirect form above) but is part of the base 8086
   instruction set (v2 "full 8086 coverage" plan, batch 4).  Reuses
   EmitDisp16 twice against two Operand copies of the same label target --
   one plain (isSegOf=FALSE, emits the offset word via a normal RELOC) and
   one isSegOf=TRUE (emits the segment word via a SEGRELOC) -- exactly the
   same offset/segment split EmitDisp16 already performs for `SEG label`
   elsewhere, just both halves of the same instruction instead of two
   separate instructions. *)
(* E2 (code-smell audit): `segOp := target` below copies a VAR-param
   Operand into a local -- currently safe (EncJmpFarDirect has only ONE
   VAR Operand param, and EncXchg's comment above scopes the known TOC
   codegen bug to procedures with TWO same-type VAR record params), but
   the pattern is a trap: adding a second VAR Operand param here later
   would silently hit the same miscompile EncXchg works around by never
   doing this copy at all. If this procedure ever grows a second VAR
   Operand parameter, build segOp field-by-field instead of `:=`. *)
PROCEDURE EncJmpFarDirect(opcode: BYTE; VAR target: Operand);
  VAR segOp: Operand;
BEGIN
  IF ~target.hasLabel THEN Err("far JMP/CALL target must be a label"); RETURN END;
  B(opcode);
  EmitDisp16(target);
  segOp := target;
  segOp.isSegOf := TRUE;
  EmitDisp16(segOp)
END EncJmpFarDirect;

(* EncStrOp: no-operand string instructions MOVSB/MOVSW/SCASB/SCASW/
   CMPSB/CMPSW -- single opcode byte each, no ModRM. *)
PROCEDURE EncStrOp(opcode: BYTE);
BEGIN B(opcode)
END EncStrOp;

(* EncInOut: IN AL/AX, imm8|DX  and  OUT imm8|DX, AL/AX.  8086 has no
   memory or general-register form -- only accumulator <-> port. *)
PROCEDURE EncIn(VAR dst, src: Operand);
  VAR wide: BOOLEAN;
BEGIN
  IF (dst.kind # OKReg) OR (dst.reg # RAX) THEN Err("IN requires AL/AX as destination"); RETURN END;
  wide := dst.size = SzWord;
  IF (src.kind = OKReg) & (src.reg = RDX) THEN
    IF wide THEN B(BYTE(0EDH)) ELSE B(BYTE(0ECH)) END
  ELSIF src.kind = OKImm THEN
    IF src.hasLabel THEN Err("label not allowed here"); RETURN END;  (* R6 fix *)
    IF (src.disp < 0) OR (src.disp > 255) THEN
      Err("port number out of range (0..255)"); RETURN  (* C5 fix *)
    END;
    IF wide THEN B(BYTE(0E5H)) ELSE B(BYTE(0E4H)) END;
    B(BYTE(src.disp))
  ELSE
    Err("IN requires DX or an immediate byte as source")
  END
END EncIn;

PROCEDURE EncOut(VAR dst, src: Operand);
  VAR wide: BOOLEAN;
BEGIN
  IF (src.kind # OKReg) OR (src.reg # RAX) THEN Err("OUT requires AL/AX as source"); RETURN END;
  wide := src.size = SzWord;
  IF (dst.kind = OKReg) & (dst.reg = RDX) THEN
    IF wide THEN B(BYTE(0EFH)) ELSE B(BYTE(0EEH)) END
  ELSIF dst.kind = OKImm THEN
    IF dst.hasLabel THEN Err("label not allowed here"); RETURN END;  (* R6 fix *)
    IF (dst.disp < 0) OR (dst.disp > 255) THEN
      Err("port number out of range (0..255)"); RETURN  (* C5 fix *)
    END;
    IF wide THEN B(BYTE(0E7H)) ELSE B(BYTE(0E6H)) END;
    B(BYTE(dst.disp))
  ELSE
    Err("OUT requires DX or an immediate byte as destination")
  END
END EncOut;

(* ---- top-level dispatch: (mnemonicId, operand[0..n-1]) -> bytes ----
   `mnemId` is a Lex.M* id, resolved once by Parse.MOD via Lex.LookupMnem
   (an identifier is looked up against the lexeme dictionary exactly once,
   not re-compared against every mnemonic string at every dispatch site).
   `n` is the actual operand count Parse.MOD parsed; operands beyond `n`
   are unused placeholders.  CASE on the integer id compiles to a jump
   table (matching SRC/TOC/SCAN.MOD's own LookupKeyword-style dispatch
   idiom), replacing the former Strings.Equal(mnem, "MOV") chain.
   `prefixByte` (0 = none) is a LOCK/REP* prefix Parse.MOD already
   recognized as a separate leading token on the same source line and
   resolved via PrefixByteFor -- emitted first, before the segment-
   override scan, per real 8086 prefix-byte ordering (v2 "full 8086
   coverage" plan, batch 5). *)
PROCEDURE Encode*(mnemId: INTEGER; VAR ops: ARRAY OF Operand; n: INTEGER; prefixByte: BYTE);
  VAR imm0: Operand; i: INTEGER;
BEGIN
  IF prefixByte # BYTE(0) THEN B(prefixByte) END;
  (* A segment-override prefix must be the FIRST byte of the whole
     instruction (prefix, opcode, ModRM, disp) -- not just before the
     ModRM byte -- so it is emitted here, once, ahead of any mnemonic-
     specific encoder, by scanning every operand for a seg override
     (at most one memory operand per real 8086 instruction can carry
     one). EmitModRm intentionally does NOT emit it (see its comment). *)
  i := 0;
  WHILE i < n DO
    IF (ops[i].kind = OKMem) & (ops[i].seg # NoSeg) THEN EmitSegPrefix(ops[i].seg) END;
    INC(i)
  END;
  CASE mnemId OF
    Lex.MMov:
      IF n # 2 THEN Err("MOV requires 2 operands") ELSE EncMov(ops[0], ops[1]) END
  | Lex.MPush:
      (* segment-register PUSH: ES=06 CS=0E SS=16 DS=1E (each = SegXX*8+6). *)
      IF n # 1 THEN Err("PUSH requires 1 operand")
      ELSIF ops[0].kind = OKSegReg THEN B(BYTE(ops[0].reg * 8 + 6))
      ELSIF ops[0].kind = OKReg THEN EncPushPopReg(BYTE(050H), ops[0])
      ELSIF (ops[0].kind = OKImm) & ~ops[0].hasLabel THEN EncPushImm(ops[0])
      ELSE B(BYTE(0FFH)); EncPushMem(ops[0])
      END
  | Lex.MPop:
      (* segment-register POP: ES=07 SS=17 DS=1F (no POP CS on 8086). *)
      IF n # 1 THEN Err("POP requires 1 operand")
      ELSIF ops[0].kind = OKSegReg THEN
        IF ops[0].reg = SegCS THEN Err("POP CS is not a valid instruction")
        ELSE B(BYTE(ops[0].reg * 8 + 7))
        END
      ELSIF ops[0].kind = OKReg THEN EncPushPopReg(BYTE(058H), ops[0])
      ELSE B(BYTE(08FH)); EncPopMem(ops[0])
      END
  | Lex.MLea:
      IF n # 2 THEN Err("LEA requires 2 operands") ELSE EncLea(ops[0], ops[1]) END
  | Lex.MLes:
      IF n # 2 THEN Err("LES requires 2 operands") ELSE EncLes(ops[0], ops[1]) END
  | Lex.MLds:
      IF n # 2 THEN Err("LDS requires 2 operands") ELSE EncLds(ops[0], ops[1]) END
  | Lex.MXchg:
      IF n # 2 THEN Err("XCHG requires 2 operands") ELSE EncXchg(ops[0], ops[1]) END
  | Lex.MAdd:
      IF n # 2 THEN Err("ADD requires 2 operands") ELSE EncAlu(BYTE(000H), 0, ops[0], ops[1]) END
  | Lex.MOr:
      IF n # 2 THEN Err("OR requires 2 operands") ELSE EncAlu(BYTE(008H), 1, ops[0], ops[1]) END
  | Lex.MAdc:
      IF n # 2 THEN Err("ADC requires 2 operands") ELSE EncAlu(BYTE(010H), 2, ops[0], ops[1]) END
  | Lex.MSbb:
      IF n # 2 THEN Err("SBB requires 2 operands") ELSE EncAlu(BYTE(018H), 3, ops[0], ops[1]) END
  | Lex.MAnd:
      IF n # 2 THEN Err("AND requires 2 operands") ELSE EncAlu(BYTE(020H), 4, ops[0], ops[1]) END
  | Lex.MSub:
      IF n # 2 THEN Err("SUB requires 2 operands") ELSE EncAlu(BYTE(028H), 5, ops[0], ops[1]) END
  | Lex.MXor:
      IF n # 2 THEN Err("XOR requires 2 operands") ELSE EncAlu(BYTE(030H), 6, ops[0], ops[1]) END
  | Lex.MCmp:
      IF n # 2 THEN Err("CMP requires 2 operands") ELSE EncAlu(BYTE(038H), 7, ops[0], ops[1]) END
  | Lex.MTest:
      IF n # 2 THEN Err("TEST requires 2 operands") ELSE EncTest(ops[0], ops[1]) END
  | Lex.MNot:
      IF n # 1 THEN Err("NOT requires 1 operand") ELSE EncUnaryGroup(2, ops[0]) END
  | Lex.MNeg:
      IF n # 1 THEN Err("NEG requires 1 operand") ELSE EncUnaryGroup(3, ops[0]) END
  | Lex.MMul:
      IF n # 1 THEN Err("MUL requires 1 operand") ELSE EncUnaryGroup(4, ops[0]) END
  | Lex.MImul:
      IF n # 1 THEN Err("IMUL requires 1 operand") ELSE EncUnaryGroup(5, ops[0]) END
  | Lex.MDiv:
      IF n # 1 THEN Err("DIV requires 1 operand") ELSE EncUnaryGroup(6, ops[0]) END
  | Lex.MIdiv:
      IF n # 1 THEN Err("IDIV requires 1 operand") ELSE EncUnaryGroup(7, ops[0]) END
  | Lex.MInc:
      IF n # 1 THEN Err("INC requires 1 operand") ELSE EncIncDec(0, ops[0]) END
  | Lex.MDec:
      IF n # 1 THEN Err("DEC requires 1 operand") ELSE EncIncDec(1, ops[0]) END
  | Lex.MShl:
      IF n # 2 THEN Err("SHL requires 2 operands") ELSE EncShift(4, ops[0], ops[1]) END
  | Lex.MShr:
      IF n # 2 THEN Err("SHR requires 2 operands") ELSE EncShift(5, ops[0], ops[1]) END
  | Lex.MRcl:
      IF n # 2 THEN Err("RCL requires 2 operands") ELSE EncShift(2, ops[0], ops[1]) END
  | Lex.MRcr:
      IF n # 2 THEN Err("RCR requires 2 operands") ELSE EncShift(3, ops[0], ops[1]) END
  | Lex.MRol:
      IF n # 2 THEN Err("ROL requires 2 operands") ELSE EncShift(0, ops[0], ops[1]) END
  | Lex.MRor:
      IF n # 2 THEN Err("ROR requires 2 operands") ELSE EncShift(1, ops[0], ops[1]) END
  | Lex.MSar:
      IF n # 2 THEN Err("SAR requires 2 operands") ELSE EncShift(7, ops[0], ops[1]) END
  | Lex.MSal:
      IF n # 2 THEN Err("SAL requires 2 operands") ELSE EncShift(4, ops[0], ops[1]) END
  | Lex.MInt:
      IF n # 1 THEN Err("INT requires 1 operand") ELSE EncInt(ops[0]) END
  | Lex.MRet, Lex.MRetn:
      IF n = 0 THEN imm0.kind := OKNone; EncRet(FALSE, FALSE, imm0)
      ELSIF n = 1 THEN EncRet(FALSE, TRUE, ops[0])
      ELSE Err("RET takes 0 or 1 operand")
      END
  | Lex.MRetf:
      IF n = 0 THEN imm0.kind := OKNone; EncRet(TRUE, FALSE, imm0)
      ELSIF n = 1 THEN EncRet(TRUE, TRUE, ops[0])
      ELSE Err("RETF takes 0 or 1 operand")
      END
  | Lex.MCld: EncNoOperand(BYTE(0FCH))
  | Lex.MCli: EncNoOperand(BYTE(0FAH))
  | Lex.MSti: EncNoOperand(BYTE(0FBH))
  | Lex.MClc: EncNoOperand(BYTE(0F8H))
  | Lex.MStc: EncNoOperand(BYTE(0F9H))
  | Lex.MIret: EncNoOperand(BYTE(0CFH))
  | Lex.MNop: EncNoOperand(BYTE(090H))
  | Lex.MInt3: EncNoOperand(BYTE(0CCH))
  | Lex.MPushf: EncNoOperand(BYTE(09CH))
  | Lex.MPopf: EncNoOperand(BYTE(09DH))
  | Lex.MMovsb: EncStrOp(BYTE(0A4H))
  | Lex.MMovsw: EncStrOp(BYTE(0A5H))
  | Lex.MScasb: EncStrOp(BYTE(0AEH))
  | Lex.MScasw: EncStrOp(BYTE(0AFH))
  | Lex.MCmpsb: EncStrOp(BYTE(0A6H))
  | Lex.MCmpsw: EncStrOp(BYTE(0A7H))
  | Lex.MLodsb: EncStrOp(BYTE(0ACH))
  | Lex.MLodsw: EncStrOp(BYTE(0ADH))
  | Lex.MStosb: EncStrOp(BYTE(0AAH))
  | Lex.MStosw: EncStrOp(BYTE(0ABH))
  | Lex.MIn:
      IF n # 2 THEN Err("IN requires 2 operands") ELSE EncIn(ops[0], ops[1]) END
  | Lex.MOut:
      IF n # 2 THEN Err("OUT requires 2 operands") ELSE EncOut(ops[0], ops[1]) END
  | Lex.MFninit: B(BYTE(0DBH)); B(BYTE(0E3H))
  | Lex.MFstcw:
      (* FSTCW (as opposed to FNSTCW) is defined to include an implicit
         leading FWAIT (9B) -- verified against SYSTEM.RDF, a real-NASM-built
         oracle: NASM emits "9B D9 /7", not bare "D9 /7", for this mnemonic. *)
      IF n # 1 THEN Err("FSTCW requires 1 operand")
      ELSE B(BYTE(09BH)); B(BYTE(0D9H)); EmitModRm(7, ops[0])
      END
  | Lex.MFwait: EncNoOperand(BYTE(09BH))
  | Lex.MCbw:  EncNoOperand(BYTE(098H))
  | Lex.MCwd:  EncNoOperand(BYTE(099H))
  | Lex.MHlt:  EncNoOperand(BYTE(0F4H))
  | Lex.MXlat: EncNoOperand(BYTE(0D7H))
  | Lex.MCmc:  EncNoOperand(BYTE(0F5H))
  | Lex.MLahf: EncNoOperand(BYTE(09FH))
  | Lex.MSahf: EncNoOperand(BYTE(09EH))
  | Lex.MInto: EncNoOperand(BYTE(0CEH))
  | Lex.MAaa:  EncNoOperand(BYTE(037H))
  | Lex.MAas:  EncNoOperand(BYTE(03FH))
  | Lex.MDaa:  EncNoOperand(BYTE(027H))
  | Lex.MDas:  EncNoOperand(BYTE(02FH))
  | Lex.MAam:  B(BYTE(0D4H)); B(BYTE(00AH))
  | Lex.MAad:  B(BYTE(0D5H)); B(BYTE(00AH))
  | Lex.MJmp:
      IF n # 1 THEN Err("JMP requires 1 operand")
      ELSIF (ops[0].kind = OKMem) OR (ops[0].kind = OKReg) THEN EncJmpIndirect(ops[0])
      ELSIF (ops[0].kind = OKImm) & ops[0].isFar THEN EncJmpFarDirect(BYTE(0EAH), ops[0])
      ELSIF ops[0].isShort THEN EncJmpShort(BYTE(0EBH), ops[0])
      ELSE EncJmpAuto(ops[0])
      END
  | Lex.MCall:
      IF n # 1 THEN Err("CALL requires 1 operand")
      ELSIF (ops[0].kind = OKMem) OR (ops[0].kind = OKReg) THEN EncCallIndirect(ops[0])
      ELSIF (ops[0].kind = OKImm) & ops[0].isFar THEN EncJmpFarDirect(BYTE(09AH), ops[0])
      ELSE EncNearRel(BYTE(0E8H), ops[0])
      END
  | Lex.MLoop:
      IF n # 1 THEN Err("LOOP requires 1 operand") ELSE EncJmpShort(BYTE(0E2H), ops[0]) END
  | Lex.MLoope, Lex.MLoopz:
      IF n # 1 THEN Err("LOOPE/LOOPZ requires 1 operand") ELSE EncJmpShort(BYTE(0E1H), ops[0]) END
  | Lex.MLoopne, Lex.MLoopnz:
      IF n # 1 THEN Err("LOOPNE/LOOPNZ requires 1 operand") ELSE EncJmpShort(BYTE(0E0H), ops[0]) END
  | Lex.MJcxz:
      IF n # 1 THEN Err("JCXZ requires 1 operand") ELSE EncJmpShort(BYTE(0E3H), ops[0]) END
  | Lex.MJe, Lex.MJz:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(074H), ops[0]) END
  | Lex.MJne, Lex.MJnz:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(075H), ops[0]) END
  | Lex.MJb, Lex.MJc, Lex.MJnae:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(072H), ops[0]) END
  | Lex.MJae, Lex.MJnb, Lex.MJnc:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(073H), ops[0]) END
  | Lex.MJbe, Lex.MJna:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(076H), ops[0]) END
  | Lex.MJa, Lex.MJnbe:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(077H), ops[0]) END
  | Lex.MJs:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(078H), ops[0]) END
  | Lex.MJns:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(079H), ops[0]) END
  | Lex.MJo:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(070H), ops[0]) END
  | Lex.MJno:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(071H), ops[0]) END
  | Lex.MJp, Lex.MJpe:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07AH), ops[0]) END
  | Lex.MJnp, Lex.MJpo:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07BH), ops[0]) END
  | Lex.MJl, Lex.MJnge:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07CH), ops[0]) END
  | Lex.MJge, Lex.MJnl:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07DH), ops[0]) END
  | Lex.MJle, Lex.MJng:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07EH), ops[0]) END
  | Lex.MJg, Lex.MJnle:
      IF n # 1 THEN Err("Jcc requires 1 operand") ELSE EncJmpShort(BYTE(07FH), ops[0]) END
  ELSE
    Err("unknown mnemonic")
  END
END Encode;

END Enc.
