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
  ELSE
    Rdoff.RdfAddReloc(obj, Rdoff.SegCode, patchOfs, width, Rdoff.SegData, FALSE)
  END
END AddReloc;

PROCEDURE SegPrefixByte(seg: INTEGER): BYTE;
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
PROCEDURE EnsureImportId(name: ARRAY OF CHAR): INTEGER;
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
           not 0 -- verified against SYS.RDF, a real-NASM-built oracle,
           which pre-fills exactly this value at every intra-module RELOC
           site. *)
        W(INTEGER(op.disp + lofs))
      END;
      IF pass = 2 THEN
        IF op.isSegOf THEN
          IF lseg = Sym.SegCode THEN
            Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, Rdoff.SegCode)
          ELSE
            Rdoff.RdfAddSegReloc(obj, Rdoff.SegCode, patchOfs, Rdoff.SegData)
          END
        ELSE
          AddReloc(patchOfs, lseg, 2)
        END
      END
    END
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
  (* OKMem *)
  IF mem.am = AmNone THEN
    B(ModRmByte(0, regField, AmDisp));
    EmitDisp16(mem);
    RETURN
  END;
  IF mem.disp = 0 THEN
    (* [BP] with disp=0 must still encode disp8=0 (Mod=01): Mod=00,rm=110
       is reserved for the [disp16] direct-address form, not [BP]. *)
    IF mem.am = AmDisp THEN modv := 1 ELSE modv := 0 END
  ELSIF (mem.disp >= -128) & (mem.disp <= 127) & ~mem.hasLabel THEN
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
  ELSE B(BYTE(imm.disp))
  END
END EmitImm;

(* ---- register-only / no-memory-operand instructions (Suggested
   implementation order step 3): PUSH/POP/INC/DEC reg, register-to-register
   arithmetic, INT imm8, RET/RETN/RETF [imm16], CLD/CLI/STI/PUSHF/POPF. ---- *)

PROCEDURE EncPushPopReg(opcodeBase: BYTE; VAR op: Operand);
BEGIN
  IF op.kind = OKReg THEN
    B(BYTE(INTEGER(opcodeBase) + op.reg))
  ELSE
    Err("PUSH/POP requires a register or memory operand")
  END
END EncPushPopReg;

(* Group opcode FF /rm (PUSH mem) or 8F /0 (POP mem) -- memory-operand form. *)
PROCEDURE EncPushMem(VAR op: Operand);
BEGIN EmitModRm(6, op)
END EncPushMem;

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
    IF op.size = SzByte THEN B(BYTE(0FEH)) ELSE B(BYTE(0FFH)) END;
    EmitModRm(ext, op)
  END
END EncIncDec;

(* ---- MOV ---- *)

PROCEDURE EncMov(VAR dst, src: Operand);
BEGIN
  IF (dst.kind = OKSegReg) & ((src.kind = OKReg) OR (src.kind = OKMem)) THEN
    (* MOV Sreg, r/m16 -> 8E /r (segment register in the /reg field). *)
    B(BYTE(08EH)); EmitModRm(dst.reg, src)
  ELSIF (src.kind = OKSegReg) & ((dst.kind = OKReg) OR (dst.kind = OKMem)) THEN
    (* MOV r/m16, Sreg -> 8C /r. *)
    B(BYTE(08CH)); EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKImm) THEN
    (* compact form: B0+r ib / B8+r iw *)
    IF dst.size = SzByte THEN B(BYTE(0B0H + dst.reg)); EmitImm(src, FALSE)
    ELSE B(BYTE(0B8H + dst.reg)); EmitImm(src, TRUE)
    END
  ELSIF src.kind = OKImm THEN
    (* MOV mem, imm: C6 /0 ib  or  C7 /0 iw *)
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
    (* MOV [disp16], AL  ->  A2 disp16  (verified against SYS.RDF's
       "mov BYTE[cs:err_code], AL" -> 2E A2 disp16, not the equally-valid
       general ModRM form 2E 88 06 disp16 that a naive encoder would pick). *)
    B(BYTE(0A2H)); EmitDisp16(dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKReg) THEN
    (* register-to-register MOV: NASM always encodes opcode 88/89 (r/m,
       reg) with dst as the r/m field and src as /reg, never 8A/8B --
       verified against SYS.RDF's "mov bx, sp" (oracle: 89 E3, i.e.
       dst=BX in r/m, src=SP in /reg -- not the equally-valid 8B DC). *)
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
   SYS.RDF's "sub sp, 4" -> 81 EC 04 00, not 83 EC 04. *)
PROCEDURE EncAlu(base: BYTE; ext: INTEGER; VAR dst, src: Operand);
  VAR wide: BOOLEAN;
BEGIN
  wide := dst.size = SzWord;
  IF src.kind = OKImm THEN
    IF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzByte) THEN
      B(BYTE(INTEGER(base) + 4)); EmitImm(src, FALSE)
    ELSIF (dst.kind = OKReg) & (dst.reg = RAX) & (dst.size = SzWord) THEN
      B(BYTE(INTEGER(base) + 5)); EmitImm(src, TRUE)
    ELSIF wide THEN
      B(BYTE(081H)); EmitModRm(ext, dst); EmitImm(src, TRUE)
    ELSE
      B(BYTE(080H)); EmitModRm(ext, dst); EmitImm(src, FALSE)
    END
  ELSIF (dst.kind = OKReg) & (src.kind = OKReg) THEN
    (* register-to-register: same NASM convention as MOV (see EncMov) --
       always the r/m,reg direction (base+0/1), dst in r/m, src in /reg,
       never base+2/3.  Verified against SYS.RDF's "xor ah, ah" -> 30 E4
       (opcode 0x30 = base+0 for XOR's base 0x30), not 32 E4. *)
    IF wide THEN B(BYTE(INTEGER(base) + 1)) ELSE B(BYTE(INTEGER(base))) END;
    EmitModRm(src.reg, dst)
  ELSIF (dst.kind = OKReg) & (src.kind = OKMem) THEN
    IF wide THEN B(BYTE(INTEGER(base) + 3)) ELSE B(BYTE(INTEGER(base) + 2)) END;
    EmitModRm(dst.reg, src)
  ELSIF (src.kind = OKReg) & (dst.kind = OKMem) THEN
    IF wide THEN B(BYTE(INTEGER(base) + 1)) ELSE B(BYTE(INTEGER(base))) END;
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
    ELSIF wide THEN
      B(BYTE(0F7H)); EmitModRm(0, dst); EmitImm(src, TRUE)
    ELSE
      B(BYTE(0F6H)); EmitModRm(0, dst); EmitImm(src, FALSE)
    END
  ELSIF (src.kind = OKReg) & ((dst.kind = OKReg) OR (dst.kind = OKMem)) THEN
    IF wide THEN B(BYTE(085H)) ELSE B(BYTE(084H)) END;
    EmitModRm(src.reg, dst)
  ELSE
    Err("unsupported TEST operand combination")
  END
END EncTest;

(* ---- single-operand group F6/F7: NOT=/2 NEG=/3 MUL=/4 ---- *)
PROCEDURE EncUnaryGroup(ext: INTEGER; VAR op: Operand);
BEGIN
  IF op.size = SzByte THEN B(BYTE(0F6H)) ELSE B(BYTE(0F7H)) END;
  EmitModRm(ext, op)
END EncUnaryGroup;

(* ---- shift/rotate group D0/D1 (by 1) or D2/D3 (by CL): SHL=/4 SHR=/5
   RCL=/2 RCR=/3.  8086 has no immediate-count shift (that's a 186+
   extension) -- only "by 1" or "by CL" forms exist here. *)
PROCEDURE EncShift(ext: INTEGER; VAR dst, cnt: Operand);
  VAR wide: BOOLEAN;
BEGIN
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
    B(BYTE(090H + b.reg))
  ELSIF (b.kind = OKReg) & (b.reg = RAX) & (b.size = SzWord) & (a.kind = OKReg) THEN
    B(BYTE(090H + a.reg))
  ELSIF a.kind = OKReg THEN
    IF a.size = SzByte THEN B(BYTE(086H)) ELSE B(BYTE(087H)) END;
    EmitModRm(a.reg, b)
  ELSIF b.kind = OKReg THEN
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

(* ---- INT imm8 ---- *)
PROCEDURE EncInt(VAR op: Operand);
BEGIN
  IF op.kind # OKImm THEN Err("INT requires an immediate byte")
  ELSE B(BYTE(0CDH)); B(BYTE(op.disp))
  END
END EncInt;

(* ---- RET / RETN (near) = C3, or C2 iw if an imm16 pop-count is given.
   RETF (far) = CB, or CA iw. ---- *)
PROCEDURE EncRet(far: BOOLEAN; hasImm: BOOLEAN; VAR imm: Operand);
BEGIN
  IF hasImm THEN
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

(* EncJmpShort: unqualified JMP/Jcc -- v1 policy (DOCS/TASM_PLAN.MD decision
   #1): compute assuming rel8 in pass 1 sizing (2 bytes total: opcode+rel8),
   validate in pass 2 that the real displacement still fits; a target that
   doesn't fit is a fatal error asking the source to be restructured (no
   iterative resizing, no NEAR-qualified auto-widening in v1). *)
PROCEDURE EncJmpShort(opcode: BYTE; VAR target: Operand);
  VAR lseg: INTEGER; lofs, rel: LONGINT; instrEnd: LONGINT;
BEGIN
  IF ~target.hasLabel THEN Err("JMP/Jcc target must be a label"); RETURN END;
  IF pass = 1 THEN
    B(opcode); B(BYTE(0));   (* placeholder rel8; real size is always 2 bytes for short form *)
    RETURN
  END;
  IF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
    Err("undefined symbol"); B(opcode); B(BYTE(0)); RETURN
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
  instrEnd := here + LONGINT(3);
  rel := lofs - instrEnd;
  B(opcode); W(INTEGER(rel))
END EncNearRel;

(* EncJmpAuto: unqualified JMP (no explicit SHORT/NEAR keyword) to a label.
   Real NASM auto-selects the 2-byte short (EB rel8) encoding whenever it
   safely can, falling back to the 3-byte near (E9 rel16) form otherwise --
   verified against SYS.RDF, where "jmp ErrWithMsg" (a BACKWARD reference,
   already-defined at encode time) short-sizes to EB despite no `short`
   keyword in the source.

   This can only be done losslessly for a reference whose target is
   already DEFINED at the moment Pass 1 first walks past this instruction:
   for those, Pass 1 already knows the real distance and can pick a size.
   A FORWARD reference has no such fixed point without iterative resizing
   (the exact problem DOCS/TASM_PLAN.MD's decision #1 avoids for Jcc/LOOP)
   -- so a forward JMP always takes the near (E9) form.

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
CONST MaxJmpDecisions = 128;
VAR
  jmpDecOfs:   ARRAY MaxJmpDecisions OF LONGINT;
  jmpDecShort: ARRAY MaxJmpDecisions OF BOOLEAN;
  nJmpDec:     INTEGER;

PROCEDURE ResetJmpDecisions*;
BEGIN nJmpDec := 0
END ResetJmpDecisions;

PROCEDURE RecordJmpDecision(ofs: LONGINT; isShort: BOOLEAN);
BEGIN
  IF nJmpDec < MaxJmpDecisions THEN
    jmpDecOfs[nJmpDec] := ofs; jmpDecShort[nJmpDec] := isShort; INC(nJmpDec)
  ELSE
    Err("too many auto-sized JMPs in one file (internal limit)")
  END
END RecordJmpDecision;

(* ReplayJmpDecision: pass 2 only -- find the decision recorded for the JMP
   instruction that started at code offset `ofs` during pass 1, in order
   (each pass 2 call consumes the next unconsumed record; since both
   passes walk instructions in the same source order, position-in-sequence
   is a simpler and equally correct key than the recorded offset itself,
   but the offset is kept too as a consistency cross-check). *)
VAR replayIdx: INTEGER;

PROCEDURE ResetJmpReplay*;
BEGIN replayIdx := 0
END ResetJmpReplay;

PROCEDURE ReplayJmpDecision(): BOOLEAN;
  VAR r: BOOLEAN;
BEGIN
  IF replayIdx < nJmpDec THEN
    r := jmpDecShort[replayIdx]; INC(replayIdx); RETURN r
  END;
  Err("JMP auto-size replay ran out of pass-1 decisions (internal error)");
  RETURN FALSE
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
    useShort := ReplayJmpDecision()
  END;
  IF useShort THEN
    IF ~Sym.Lookup(target.labelName, lseg, lofs) THEN
      Err("undefined symbol"); B(BYTE(0EBH)); B(BYTE(0)); RETURN
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
  IF mem.isFar THEN EmitModRm(5, mem) ELSE EmitModRm(4, mem) END
END EncJmpIndirect;

PROCEDURE EncCallIndirect(VAR mem: Operand);
BEGIN
  B(BYTE(0FFH));
  IF mem.isFar THEN EmitModRm(3, mem) ELSE EmitModRm(2, mem) END
END EncCallIndirect;

(* EncJmpFarDirect: JMP/CALL far ptr16:16 -- EA/9A followed by offset then
   segment word.  Segment word needs a RDFREC_SEGRELOC against the target
   label's group (import or same-module code group), per DOCS/RDOFF2.MD
   Type 6 / large-model address calc.  Used for `call far [ProcPtr_off]`-
   style indirect forms only when the operand is a label naming a FAR proc
   pointer variable read from memory -- direct far CALL/JMP to a label (not
   through a pointer) does not occur in SYS.ASM/EMSAPI.ASM (both only use
   `call far [mem]`, the indirect form above), so this direct-immediate
   far form is not required for v1's two oracle files and is intentionally
   left unimplemented (Simplicity First) until a real .asm needs it. *)

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
   idiom), replacing the former Strings.Equal(mnem, "MOV") chain. *)
PROCEDURE Encode*(mnemId: INTEGER; VAR ops: ARRAY OF Operand; n: INTEGER);
  VAR imm0: Operand; i: INTEGER;
BEGIN
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
         leading FWAIT (9B) -- verified against SYS.RDF, a real-NASM-built
         oracle: NASM emits "9B D9 /7", not bare "D9 /7", for this mnemonic. *)
      IF n # 1 THEN Err("FSTCW requires 1 operand")
      ELSE B(BYTE(09BH)); B(BYTE(0D9H)); EmitModRm(7, ops[0])
      END
  | Lex.MFwait: EncNoOperand(BYTE(09BH))
  | Lex.MJmp:
      IF n # 1 THEN Err("JMP requires 1 operand")
      ELSIF ops[0].kind = OKMem THEN EncJmpIndirect(ops[0])
      ELSIF ops[0].isShort THEN EncJmpShort(BYTE(0EBH), ops[0])
      ELSE EncJmpAuto(ops[0])
      END
  | Lex.MCall:
      IF n # 1 THEN Err("CALL requires 1 operand")
      ELSIF ops[0].kind = OKMem THEN EncCallIndirect(ops[0])
      ELSE EncNearRel(BYTE(0E8H), ops[0])
      END
  | Lex.MLoop:
      IF n # 1 THEN Err("LOOP requires 1 operand") ELSE EncJmpShort(BYTE(0E2H), ops[0]) END
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
  ELSE
    Err("unknown mnemonic")
  END
END Encode;

END Enc.
