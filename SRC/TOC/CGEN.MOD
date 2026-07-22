(*$D-*)
MODULE Cgen;
(*
  Oberon compiler code generator.
  Byte emitter: code/data buffers, relocations, jumps, load/store, arithmetic,
  FPU helpers, LONGINT helpers, far-pointer helpers.
  Imports Rdoff for ObjFile and low-level emit/reloc primitives.
  Imports Syms for TypeDesc (used in Item).
*)
IMPORT Rdoff, Syms, Strings, LogErr;

CONST
  (* item addressing modes *)
  MConst*   = 0;
  MGlobal*  = 1;
  MLocal*   = 2;
  MReg*     = 3;   (* value in AX *)
  MProc*    = 4;
  MImport*  = 5;
  MSysProc* = 6;
  MFreg*    = 7;   (* value in FPU ST(0) *)

  (* x86 opcodes *)
  OpCallNear* = 0E8H;
  OpJmpNear*  = 0E9H;
  OpJmpShort* = 0EBH;
  OpJz*       = 074H;
  OpJnz*      = 075H;
  OpJl*       = 07CH;
  OpJge*      = 07DH;
  OpJle*      = 07EH;
  OpJg*       = 07FH;
  OpJb*       = 072H;   (* unsigned below *)
  OpJae*      = 073H;   (* unsigned above-or-equal *)
  OpJbe*      = 076H;   (* unsigned below-or-equal *)
  OpJa*       = 077H;   (* unsigned above *)
  OpRet*      = 0C3H;
  OpRetN*     = 0C2H;
  OpRetf*     = 0CBH;
  OpRetfN*    = 0CAH;
  OpCallFar*  = 09AH;
  OpInt*      = 0CDH;
  OpPushAx*   = 050H;
  OpPopAx*    = 058H;
  OpPopCx*    = 059H;
  OpPushBx*   = 053H;
  OpPopBx*    = 05BH;
  OpPushDx*   = 052H;
  OpPopDx*    = 05AH;
  OpPushCs*   = 00EH;
  OpCld*      = 0FCH;
  OpPushSs*   = 016H;
  OpPushDs*   = 01EH;
  OpPushEs*   = 006H;
  OpPopEs*    = 007H;
  OpLes*      = 0C4H;
  OpEsPfx*    = 026H;
  OpMovEsDx*  = 0C2H;
  OpOutDxAl*  = 0EEH;
  OpInAlDx*   = 0ECH;
  OpPushSi*   = 056H;
  OpPopSi*    = 05EH;

TYPE
  Backpatch* = RECORD
    offset*: LONGINT;   (* where rel8/rel16 sits in code buf *)
    width*:  BYTE       (* 1 or 2 *)
  END;

  Item* = RECORD
    mode*:     INTEGER;
    type*:     Syms.TypeDesc;
    val*:      LONGINT;    (* M_CONST: value *)
    adr*:      LONGINT;    (* M_GLOBAL: data seg ofs; M_LOCAL: BP ofs *)
    rdoffId*:  INTEGER;    (* M_IMPORT: import seg id *)
    isRef*:    BOOLEAN;    (* VAR param *)
    isFar*:    BOOLEAN;    (* local exported FAR proc *)
    typeless*: BOOLEAN;    (* typeless VAR param *)
    addrDeref*: BOOLEAN;   (* CHAR ref produced by SYSTEM.ADDRESS `^` (byte-indexable) *)
    fwdSym*:   Syms.Symbol; (* non-NIL when MProc and fwdDecl *)
    rootSym*:  Syms.Symbol  (* designator's root identifier *)
  END;

VAR
  CgObj*: Rdoff.ObjFile;

  (* ---- condition-fusion single-frame relay ----
     Armed immediately before one top-level ParseExpression call that is
     known to be a boolean condition (IF/WHILE/&/OR/~ operand); consumed by
     the NEXT CgSetcc call, which then emits a direct branch to condBp
     instead of materializing 0/1 in AX.  MUST be disarmed (condArmed:=FALSE)
     by CgSetcc on every use (hit or not) so a nested ParseExpression call for
     an unrelated parenthesized arithmetic subexpression never sees a stale
     armed flag — the flag is single-shot, not saved/restored across
     recursion, so any recursive re-entry before the outer CgSetcc fires
     naturally finds it already consumed. *)
  condArmed*:    BOOLEAN;
  condWantTrue*: BOOLEAN;   (* branch to condBp when the condition is NOT this value *)
  condBp*:       Backpatch;
  condHit*:      BOOLEAN;   (* set by CgSetcc when it actually consumed condArmed *)

PROCEDURE CgLoadItem*(VAR item: Item); FORWARD;
PROCEDURE CgLoadImm*(val: INTEGER); FORWARD;
PROCEDURE CgDerefFar(); FORWARD;
PROCEDURE CgDerefFarByte(); FORWARD;
PROCEDURE CgDerefFarLong(); FORWARD;
PROCEDURE CgStoreDerefFar(); FORWARD;
PROCEDURE CgStoreDerefFarByte(); FORWARD;
PROCEDURE CgStoreDerefFarLong(); FORWARD;

(* CgDerefFarSized — pick the right far-deref opcode for the current item width. *)
PROCEDURE CgDerefFarSized(isByte, isLong, isPtr: BOOLEAN);
BEGIN
  IF isByte THEN CgDerefFarByte()
  ELSIF isLong OR isPtr THEN CgDerefFarLong()
  ELSE CgDerefFar()
  END
END CgDerefFarSized;

(* CgStoreDerefFarSized — same idea for stores. *)
PROCEDURE CgStoreDerefFarSized(isByte, isLong, isPtr: BOOLEAN);
BEGIN
  IF isByte THEN CgStoreDerefFarByte()
  ELSIF isLong OR isPtr THEN CgStoreDerefFarLong()
  ELSE CgStoreDerefFar()
  END
END CgStoreDerefFarSized;


(* ---- init/free ---- *)

PROCEDURE CgInit*;
BEGIN
  NEW(CgObj);
  IF CgObj = NIL THEN
    LogErr.Error("out of memory (codegen object)"); RETURN
  END;
  (* condArmed/condWantTrue/condHit are module globals, never zero-initialized
     by this runtime (see DOCS/IMPLRULE.MD) — condArmed left uninitialized
     decoded as nonzero (TRUE) in at least one build, silently leaving
     condition-fusion "armed" for the entire rest of the compile after the
     very first ParseCondExpr call, corrupting unrelated parsing/codegen
     throughout the program (a real, caught-by-testing bug — see
     SIZE-REPORT.MD 2.1 "full &/OR/~ fusion"). *)
  condArmed := FALSE; condWantTrue := FALSE; condHit := FALSE;
  Rdoff.RdfInit(CgObj)   (* errors latch in LogErr; caller checks LogErr.HaveErr() *)
END CgInit;

PROCEDURE CgFree*();
BEGIN
  IF CgObj # NIL THEN
    Rdoff.RdfFree(CgObj);
    DISPOSE(CgObj)   (* return the ObjFile struct itself to the heap *)
  END
END CgFree;

PROCEDURE CgPc*(): LONGINT;
BEGIN
  RETURN Rdoff.CodeLen(CgObj)
END CgPc;

PROCEDURE CgDpc*(): LONGINT;
BEGIN
  RETURN Rdoff.DataLen(CgObj)
END CgDpc;

(* ---- raw emit ---- *)

PROCEDURE Emit1*(b: BYTE);
BEGIN
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b)
END Emit1;

PROCEDURE Emit2*(b0, b1: BYTE);
BEGIN
  Rdoff.EmitByte2(CgObj, Rdoff.SegCode, b0, b1)
END Emit2;

PROCEDURE Emit3*(b0, b1, b2: BYTE);
BEGIN
  Rdoff.EmitByte3(CgObj, Rdoff.SegCode, b0, b1, b2)
END Emit3;

PROCEDURE EmitW*(w: INTEGER);
BEGIN
  Rdoff.EmitWord(CgObj, Rdoff.SegCode, w)
END EmitW;

(* EmitRel — emit `<opcode> modR/M disp8/disp16` choosing the short (mod=01)
   or long (mod=10) form.  `regRm` is the bare mod-R/M byte with mod=00 —
   i.e. just the reg field (bits 3-5) OR'd with the r/m field (bits 0-2).
   Caller passes 06H for AX/[BP], 16H for DX/[BP], 1EH for BX/[BP],
   07H for AX/[BX], 17H for DX/[BX], etc.  The helper OR's mod=01 (+40H)
   or mod=10 (+80H) at emit time. *)
PROCEDURE EmitRel(opcode, regRm: BYTE; ofs: LONGINT);
VAR buf : ARRAY 4 OF BYTE;
    bufSize : WORD;
BEGIN
  buf[0] := opcode;
  IF (ofs >= -128) & (ofs <= 127) THEN
    buf[1] := SYSTEM.IOR(regRm, 040H);
    buf[2] := SYSTEM.AND(BYTE(ofs), 0FFH);
    bufSize := 3
  ELSE
    buf[1] := SYSTEM.IOR(regRm, 080H);
    buf[2] := SYSTEM.AND(WORD(ofs), 0FFH);
    buf[3] := SYSTEM.AND(SYSTEM.LSR(WORD(ofs), 8), 0FFH);
    bufSize := 4
  END;
  Rdoff.EmitBlock(CgObj, Rdoff.SegCode, buf, bufSize)
END EmitRel;

PROCEDURE EmitCodeStr*(s: ARRAY OF CHAR);
  VAR i, v, d: INTEGER; c: CHAR;
      buf    : ARRAY 256 OF BYTE;
      bufPos : WORD;
BEGIN
  bufPos := 0;
  i := 0;
  WHILE (s[i] # 0X) & (bufPos < WORD(256)) DO
    v := 0;
    c := s[i];
    IF SYSTEM.ISDIGIT(c) THEN d := ORD(c) - ORD("0")
    ELSIF (c >= "A") & (c <= "F") THEN d := ORD(c) - ORD("A") + 10
    ELSE d := 0
    END;
    v := d; INC(i);
    c := s[i];
    IF (c # ",") & (c # 0X) THEN
      IF SYSTEM.ISDIGIT(c) THEN d := ORD(c) - ORD("0")
      ELSIF (c >= "A") & (c <= "F") THEN d := ORD(c) - ORD("A") + 10
      ELSE d := 0
      END;
      v := SYSTEM.LSL(v, 4) + d; INC(i)
    END;
    buf[bufPos] := v;
    INC(bufPos);
    IF s[i] = "," THEN INC(i) END
  END;
  (* Bounds guard: a >256-byte hex string used to run buf[] off the end of
     the stack frame.  All current literals are far shorter, so hitting this
     is an internal emitter bug, not a user error. *)
  IF s[i] # 0X THEN
    LogErr.Error("internal: EmitCodeStr pattern longer than 256 bytes")
  END;
  Rdoff.EmitBlock(CgObj, Rdoff.SegCode, buf, bufPos)
END EmitCodeStr;

PROCEDURE EmitDataByte*(b: BYTE);
BEGIN
  Rdoff.EmitByte(CgObj, Rdoff.SegData, b)
END EmitDataByte;

PROCEDURE EmitDataWord*(w: INTEGER);
BEGIN
  Rdoff.EmitWord(CgObj, Rdoff.SegData, w)
END EmitDataWord;

PROCEDURE EmitDataZero*(n: LONGINT);
BEGIN
  IF n > LONGINT(0) THEN Rdoff.EmitZero(CgObj, n) END
END EmitDataZero;

(* Allocate a 4-byte far-pointer slot in the data segment patched by the
   linker with the address of an imported symbol.  Slot layout matches LES:
     [slot+0]: offset word (patched via RdfAddReloc width=2)
     [slot+2]: segment word (patched via RdfAddSegReloc)
   Returns the slot's data-segment offset.  Caller sets item.mode=MGlobal,
   item.adr=slot, item.isRef=TRUE. *)
PROCEDURE CgImportVarSlot*(rdoffId: INTEGER): LONGINT;
  VAR slot: LONGINT;
BEGIN
  slot := Rdoff.DataLen(CgObj);
  Rdoff.EmitZero(CgObj, LONGINT(4));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegData, slot, 2, rdoffId, FALSE);
  Rdoff.RdfAddSegReloc(CgObj, Rdoff.SegData, slot + LONGINT(2), rdoffId);
  RETURN slot
END CgImportVarSlot;

PROCEDURE EmitDataString*(s: ARRAY OF CHAR);
BEGIN
  Rdoff.EmitBlock(CgObj, Rdoff.SegData, s, Strings.Length(s) + 1);
END EmitDataString;

(* ---- frame ---- *)

PROCEDURE CgPrologue*(localBytes: INTEGER);
BEGIN
  (* PUSH BP / MOV BP,SP / SUB SP,imm16 *)
  EmitCodeStr("55,8B,EC,81,EC");
  EmitW(localBytes)
END CgPrologue;

PROCEDURE CgEpilogue*(argBytes: INTEGER);
BEGIN
  (* MOV SP,BP / POP BP *)
  EmitCodeStr("8B,E5,5D");
  IF argBytes = 0 THEN Emit1(BYTE(OpRet))
  ELSE Emit1(BYTE(OpRetN)); EmitW(argBytes)
  END
END CgEpilogue;

PROCEDURE CgEpilogueFar*(argBytes: INTEGER);
BEGIN
  EmitCodeStr("8B,E5,5D");  (* MOV SP,BP / POP BP *)
  IF argBytes = 0 THEN Emit1(BYTE(OpRetf))
  ELSE Emit1(BYTE(OpRetfN)); EmitW(argBytes)
  END
END CgEpilogueFar;

(* ---- calls ---- *)

PROCEDURE CgCallNear*(importId: INTEGER);
  VAR patchAt: LONGINT;
BEGIN
  Emit1(BYTE(OpCallNear));
  patchAt := CgPc();
  EmitW(INTEGER(-(patchAt + LONGINT(2))));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patchAt, 2, importId, TRUE)
END CgCallNear;

PROCEDURE CgCallLocal*(target: LONGINT);
  VAR patchAt: LONGINT;
BEGIN
  Emit1(BYTE(OpCallNear));
  patchAt := CgPc();
  EmitW(INTEGER(target - (patchAt + LONGINT(2))))
END CgCallLocal;

PROCEDURE CgCallLocalFar*(target: LONGINT);
BEGIN
  Emit1(BYTE(OpPushCs));
  CgCallLocal(target)
END CgCallLocalFar;

PROCEDURE CgCallProcVarBp*(ofs: LONGINT); BEGIN EmitRel(0FFH, 01EH, ofs) END CgCallProcVarBp;

PROCEDURE CgCallProcVarEsbx*();
BEGIN
  Emit3(026H, 0FFH, 01FH)
END CgCallProcVarEsbx;

(* CgCallProcVarRefTail — the shared tail of an indirect call through a
   proc-var whose SLOT ADDRESS was in ES:BX before the argument list was
   parsed (MReg/isRef designator: record field, array element, pointer
   deref).  Protocol, shared by PExpr (call-in-expression) and PStmt
   (call-statement) so the two sites cannot drift:
     caller emits PUSH BX; PUSH ES  (save slot addr)   -- "53,06"
     caller parses/pushes the actual arguments (argSize bytes)
     this tail: MOV BX,SP; ADD BX,argSize   ; BX -> saved slot addr
                SS: MOV CX,[BX]; SS: MOV BX,[BX+2]; MOV ES,CX
                CALL FAR [ES:BX]            ; through the proc-var slot
                ADD SP,4                    ; pop saved BX/ES *)
PROCEDURE CgCallProcVarRefTail*(argSize: LONGINT);
BEGIN
  Emit2(089H, 0E3H);                       (* MOV BX, SP *)
  IF argSize > 0 THEN
    IF argSize <= 127 THEN
      Emit2(083H, 0C3H); Emit1(BYTE(INTEGER(argSize) MOD 256))
    ELSE
      Emit2(081H, 0C3H); EmitW(INTEGER(SYSTEM.AND(argSize, LONGINT(0FFFFH))))
    END
  END;
  (* SS: MOV CX,[BX] / SS: MOV BX,[BX+2] / MOV ES,CX *)
  EmitCodeStr("36,8B,0F,36,8B,5F,02,8E,C1");
  CgCallProcVarEsbx();
  EmitCodeStr("83,C4,04")                  (* ADD SP,4 *)
END CgCallProcVarRefTail;

PROCEDURE CgCallFar*(importId: INTEGER);
  VAR ofsAt, segAt: LONGINT;
BEGIN
  Emit1(BYTE(OpCallFar));
  ofsAt := CgPc(); EmitW(0);
  segAt := CgPc(); EmitW(0);
  Rdoff.RdfAddReloc   (CgObj, Rdoff.SegCode, ofsAt, 2, importId, FALSE);
  Rdoff.RdfAddSegReloc(CgObj, Rdoff.SegCode, segAt, importId)
END CgCallFar;

(* Load the FAR address of an imported procedure into DX:AX.
   Used by SYSTEM.ADR(ImportedProc) — the linker fills in both placeholder
   words at link time, the same way it fills CALL FAR. *)
PROCEDURE CgLoadImportAddr*(importId: INTEGER);
  VAR ofsAt, segAt: LONGINT;
BEGIN
  Emit1(0B8H); ofsAt := CgPc(); EmitW(0);   (* MOV AX, imm16 *)
  Emit1(0BAH); segAt := CgPc(); EmitW(0);   (* MOV DX, imm16 *)
  Rdoff.RdfAddReloc   (CgObj, Rdoff.SegCode, ofsAt, 2, importId, FALSE);
  Rdoff.RdfAddSegReloc(CgObj, Rdoff.SegCode, segAt, importId)
END CgLoadImportAddr;

(* ---- jumps ---- *)

PROCEDURE InvertJcc(opcode: INTEGER): INTEGER;
BEGIN
  RETURN SYSTEM.XOR(opcode, 1)
END InvertJcc;

PROCEDURE CgJmpNear*(VAR bp: Backpatch);
BEGIN
  Emit1(BYTE(OpJmpNear));
  bp.offset := CgPc(); bp.width := BYTE(2); EmitW(0)
END CgJmpNear;

PROCEDURE CgCondShort*(opcode: INTEGER; VAR bp: Backpatch);
BEGIN
  Emit1(BYTE(opcode));
  bp.offset := CgPc(); bp.width := BYTE(1); Emit1(BYTE(0))
END CgCondShort;

PROCEDURE CgCondNear*(opcode: INTEGER; VAR bp: Backpatch);
BEGIN
  (* inv_opcode +3 / JMP near target *)
  Emit2(BYTE(InvertJcc(opcode)), BYTE(3));
  Emit1(BYTE(OpJmpNear));
  bp.offset := CgPc(); bp.width := BYTE(2); EmitW(0)
END CgCondNear;

PROCEDURE CgPatchShort*(VAR bp: Backpatch);
  VAR rel: LONGINT;
BEGIN
  rel := CgPc() - (bp.offset + LONGINT(1));
  (* A short Jcc/JMP rel8 only reaches -128..+127.  Out of range MUST be
     fatal: a silently wrapped rel8 jumps into the middle of another
     instruction (this exact overflow — a 142-byte span in a short-circuit
     `&`-chain — produced a wild backward jump and broke self-hosting; see
     opt.md §8).  Callers with unbounded spans must use CgCondNear/CgJmpNear. *)
  IF (rel < LONGINT(-128)) OR (rel > LONGINT(127)) THEN
    LogErr.Error("internal: short jump out of range (compiler bug — use near jump)")
  END;
  Rdoff.PatchCodeByte(CgObj, bp.offset, BYTE(INTEGER(rel) MOD 256))
END CgPatchShort;

PROCEDURE CgPatchNear*(VAR bp: Backpatch);
  VAR rel: LONGINT;
BEGIN
  rel := CgPc() - (bp.offset + LONGINT(2));
  Rdoff.PatchCodeByte(CgObj, bp.offset,     BYTE(INTEGER(rel MOD LONGINT(256))));
  Rdoff.PatchCodeByte(CgObj, bp.offset + LONGINT(1), BYTE(INTEGER((rel DIV LONGINT(256)) MOD LONGINT(256))))
END CgPatchNear;

PROCEDURE CgJmpBack*(target: LONGINT);
  VAR rel: LONGINT;
BEGIN
  rel := target - (CgPc() + LONGINT(2));
  IF (rel >= LONGINT(-128)) & (rel <= LONGINT(127)) THEN
    Emit1(BYTE(OpJmpShort)); Emit1(BYTE(INTEGER(rel) MOD 256))
  ELSE
    Emit1(BYTE(OpJmpNear)); EmitW(INTEGER(target - (CgPc() + LONGINT(2))))
  END
END CgJmpBack;

PROCEDURE CgCondBack*(opcode: INTEGER; target: LONGINT);
  VAR rel: LONGINT;
BEGIN
  rel := target - (CgPc() + LONGINT(2));
  IF (rel >= LONGINT(-128)) & (rel <= LONGINT(127)) THEN
    Emit1(BYTE(opcode)); Emit1(BYTE(SYSTEM.AND(INTEGER(rel), 0FFH)))
  ELSE
    (* 5-byte: Jcc_inv +3 / JMP NEAR target *)
    Emit2(BYTE(InvertJcc(opcode)), BYTE(3));
    Emit1(BYTE(OpJmpNear));
    EmitW(INTEGER(target - (CgPc() + LONGINT(2))))
  END
END CgCondBack;

(* ---- load / store ---- *)

PROCEDURE CgLoadBp*(ofs: LONGINT);     BEGIN EmitRel(08BH, 006H, ofs) END CgLoadBp;
PROCEDURE CgStoreBp(ofs: LONGINT);    BEGIN EmitRel(089H, 006H, ofs) END CgStoreBp;
PROCEDURE CgLoadByteBp(ofs: LONGINT);
BEGIN
  EmitRel(08AH, 006H, ofs);
  Emit2(030H, 0E4H)  (* XOR AH, AH *)
END CgLoadByteBp;
PROCEDURE CgStoreByteBp(ofs: LONGINT); BEGIN EmitRel(088H, 006H, ofs) END CgStoreByteBp;
PROCEDURE CgLoadAddrBp*(ofs: LONGINT); BEGIN EmitRel(08DH, 006H, ofs) END CgLoadAddrBp;

(* EmitMemReloc — emit a 1-byte opcode followed by a 16-bit imm patched by a
   reloc into segReloc.  Used by every load/store-immediate-from-data and
   the MOV AX,code-addr forms.  Saves repeating the patch/EmitW/RdfAddReloc
   triple across every helper. *)
PROCEDURE EmitMemReloc(opcode: BYTE; dataOfs: WORD; segReloc: INTEGER);
  VAR patch: LONGINT;
BEGIN
  Emit1(opcode); patch := CgPc(); EmitW(INTEGER(dataOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, segReloc, FALSE)
END EmitMemReloc;

PROCEDURE CgLoadMem*(dataOfs: WORD);   BEGIN EmitMemReloc(0A1H, dataOfs, Rdoff.SegData) END CgLoadMem;
PROCEDURE CgStoreMem(dataOfs: WORD);   BEGIN EmitMemReloc(0A3H, dataOfs, Rdoff.SegData) END CgStoreMem;
PROCEDURE CgLoadByteMem(dataOfs: WORD);
BEGIN
  EmitMemReloc(0A0H, dataOfs, Rdoff.SegData);
  Emit2(030H, 0E4H)  (* XOR AH, AH *)
END CgLoadByteMem;
PROCEDURE CgStoreByteMem(dataOfs: WORD);BEGIN EmitMemReloc(0A2H, dataOfs, Rdoff.SegData) END CgStoreByteMem;

PROCEDURE CgLoadAddrMem*(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  (* 2-byte opcode: LEA AX,[imm16] — needs the patch position AFTER both bytes *)
  Emit2(08DH, 006H);
  patch := CgPc(); EmitW(INTEGER(dataOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgLoadAddrMem;

PROCEDURE CgCallProcVarMem*(dataOfs: WORD);
BEGIN
  (* CALL FAR [dataOfs] — dataOfs is a module-local data offset (e.g. a
     KProc-typed global VAR's Symbol.adr) and MUST go through the same
     SegData relocation as every other load/store-from-data-offset site
     (see EmitMemReloc above); a bare EmitW here (as before 2026-07-10) left
     the PRE-link module-local offset unpatched, so the CALL read 4 bytes
     from the wrong absolute address once the module's data was placed at a
     nonzero base in the combined DGROUP.  A global PROC-typed VAR is the one
     case that reaches this path (a local/param proc-var uses
     CgCallProcVarBp instead, which patches an SS:[BP+ofs] frame offset, not
     a data-segment address), so it went unexercised until Scan.Scanner's
     eager-syscomment-hook fix (2026-07-10) added the first one. *)
  Emit1(0FFH); EmitMemReloc(01EH, dataOfs, Rdoff.SegData)
END CgCallProcVarMem;

PROCEDURE CgLoadCodeAddr*(codeOfs: WORD); BEGIN EmitMemReloc(0B8H, codeOfs, Rdoff.SegCode)
END CgLoadCodeAddr;

(* CgEmitJumpTableEntry — emit one bare 16-bit code-offset word (no opcode
   prefix) for a jump table slot, with a code-to-code relocation.  codeOfs is
   the module-local code offset at the moment the target is known (typically
   CgPc() taken right before an arm's body); the linker adds this module's
   code-group base to it (see LINK.MOD OnReloc, rrefSeg=SegCode branch). *)
PROCEDURE CgEmitJumpTableEntry*(codeOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  patch := CgPc(); EmitW(INTEGER(codeOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegCode, FALSE)
END CgEmitJumpTableEntry;

(* CgPatchJumpTableEntry — retroactively fill a jump-table slot (emitted
   earlier via CgEmitJumpTableEntry with a placeholder codeOfs, typically 0)
   once the real target offset is known.  The reloc added at emit time is
   unaffected — only the stored addend word (which IS the module-local code
   offset the linker's relocator adds its group base to) needs updating. *)
PROCEDURE CgPatchJumpTableEntry*(slotOfs: LONGINT; codeOfs: WORD);
BEGIN
  Rdoff.PatchCodeByte(CgObj, slotOfs,     BYTE(SYSTEM.AND(codeOfs, 0FFH)));
  Rdoff.PatchCodeByte(CgObj, slotOfs + LONGINT(1), BYTE(SYSTEM.AND(SYSTEM.LSR(codeOfs, 8), 0FFH)))
END CgPatchJumpTableEntry;

(* CgSubAxImm — SUB AX, imm16 (always the full 16-bit form; no imm8 fast path
   needed here — used only in the CASE jump-table dispatch prologue, where
   this runs once per dispatch, not per element). *)
PROCEDURE CgSubAxImm*(val: INTEGER);
BEGIN
  IF val # 0 THEN Emit1(02DH); EmitW(val) END
END CgSubAxImm;

(* CgCmpAxImmUnsignedAbove — CMP AX,imm16 followed by the caller emitting a
   JA/JBE (unsigned) branch; this just does the compare (mirrors CgCmpAxImm
   but documents that callers use the unsigned condition codes OpJa/OpJbe,
   needed for the CASE jump-table bounds check: AX is (selector-lo), which is
   never negative when in range, but IS a huge unsigned value when the true
   selector was below lo — signed JG/JL would misclassify that case). *)
PROCEDURE CgCmpAxImmUnsigned*(val: INTEGER);
BEGIN
  Emit1(03DH); EmitW(val)
END CgCmpAxImmUnsigned;

(* CgJmpTableCs — CS: JMP [BX+tableCodeOfs] — indexed near jump through a
   jump table living in the code segment (hence the CS: override: DS points
   at the data segment, not code, in this compiler's segment model).
   tableCodeOfs is the module-local code offset of the table's first entry. *)
PROCEDURE CgJmpTableCs*(tableCodeOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  Emit1(02EH);              (* CS: prefix *)
  Emit2(0FFH, 0A7H);        (* FF /4, mod=10 rm=111(BX): JMP [BX+disp16] *)
  patch := CgPc(); EmitW(INTEGER(tableCodeOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegCode, FALSE)
END CgJmpTableCs;

(* ---- far-pointer helpers ---- *)

PROCEDURE CgLesBxBp*(ofs: LONGINT); BEGIN EmitRel(BYTE(OpLes), 01EH, ofs) END CgLesBxBp;

PROCEDURE CgLesBxMem*(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  Emit2(BYTE(OpLes), 01EH);
  patch := CgPc(); EmitW(INTEGER(dataOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgLesBxMem;

(* CgLoadAddrItem — AX := address of an MGlobal/MLocal item.
   Replaces the IF MGlobal THEN CgLoadAddrMem ELSE CgLoadAddrBp END pattern. *)
PROCEDURE CgLoadAddrItem*(mode: INTEGER; adr: LONGINT);
BEGIN
  IF mode = MGlobal THEN CgLoadAddrMem(WORD(adr)) ELSE CgLoadAddrBp(adr) END
END CgLoadAddrItem;

(* CgLesBxItem — ES:BX := far ptr stored at an MGlobal/MLocal slot. *)
PROCEDURE CgLesBxItem*(mode: INTEGER; adr: LONGINT);
BEGIN
  IF mode = MGlobal THEN CgLesBxMem(WORD(adr)) ELSE CgLesBxBp(adr) END
END CgLesBxItem;

(* CgPushAggrValue — push a by-value aggregate (record / fixed array) onto the
   stack as a call argument.  IN: ES:BX = far address of the SOURCE aggregate
   (loaded by the call site).  `evenSize` = SIZE(aggregate) rounded UP to an even
   number of bytes (the formal slot is 2-byte aligned, per the calling
   convention).  The whole aggregate is copied into a freshly reserved stack slot
   so the callee can read it in place at [BP+ofs]; the post-call `ADD SP,argSize`
   pops it (argSize counts the same evenSize for this param — see
   Syms.ParamSlotSize).  DS is preserved. *)
(* CgLoadFarAddrEsBx — ES:BX := far address of an item (for CgPushAggrValue's
   source).  isRef: the slot holds a far ptr -> LES BX,slot.  plain MGlobal: near
   var in DS.  plain MLocal: near var on the stack (SS). *)
PROCEDURE CgLoadFarAddrEsBx*(mode: INTEGER; adr: LONGINT; isRef: BOOLEAN);
BEGIN
  IF isRef THEN
    CgLesBxItem(mode, adr)
  ELSE
    CgLoadAddrItem(mode, adr);
    Emit2(08BH, 0D8H);        (* MOV BX, AX *)
    IF mode = MLocal THEN EmitCodeStr("8C,D0,8E,C0")   (* MOV AX,SS; MOV ES,AX *)
    ELSE                  EmitCodeStr("8C,D8,8E,C0")   (* MOV AX,DS; MOV ES,AX *)
    END
  END
END CgLoadFarAddrEsBx;

PROCEDURE CgPushAggrValue*(evenSize: INTEGER);
BEGIN
  EmitCodeStr("8B,F3,8C,C1");   (* MOV SI,BX ; src ofs / MOV CX,ES ; src seg (saved) *)
  Emit2(081H, 0ECH); EmitW(evenSize);(* SUB SP, evenSize  ; reserve dest slot *)
  (* MOV DI,SP ; dest ofs = new top / PUSH DS ; save DS / MOV DS,CX ; DS = src seg /
     MOV AX,SS / MOV ES,AX ; ES = SS (dest seg) *)
  EmitCodeStr("8B,FC,1E,8E,D9,8C,D0,8E,C0");
  CgLoadImm(evenSize); Emit2(08BH, 0C8H);  (* MOV CX, evenSize *)
  EmitCodeStr("FC,F3,A4");      (* CLD / REP MOVSB ; DS:SI -> ES:DI *)
  Emit1(01FH)                        (* POP DS            ; restore DS *)
END CgPushAggrValue;

(* CgEsFromMode — emit `MOV DX, SS/DS; MOV ES, DX` (4 bytes).
   Sets ES to the segment matching an MLocal (SS) or MGlobal (DS) item. *)
PROCEDURE CgEsFromMode*(mode: INTEGER);
BEGIN
  IF mode = MLocal THEN EmitCodeStr("8C,D2,8E,C2")   (* MOV DX,SS; MOV ES,DX *)
  ELSE                  EmitCodeStr("8C,DA,8E,C2")   (* MOV DX,DS; MOV ES,DX *)
  END
END CgEsFromMode;

(* CgRepMovsb — emit `MOV AX,count; MOV CX,AX; CLD; [SS-prefix]; REP MOVSB`.
   Replaces the trailing block used by all four record/array copy paths. *)
PROCEDURE CgRepMovsb*(count: INTEGER; ssPrefix: BOOLEAN);
BEGIN
  CgLoadImm(count);
  Emit2(08BH, 0C8H);                  (* MOV CX, AX *)
  Emit1(BYTE(OpCld));                 (* CLD *)
  IF ssPrefix THEN Emit1(036H) END;   (* SS: prefix (source on stack) *)
  Emit2(0F3H, 0A4H)                   (* REP MOVSB *)
END CgRepMovsb;

PROCEDURE CgDxaxToEsbx*();
BEGIN
  (* MOV BX,AX / MOV ES,DX *)
  EmitCodeStr("8B,D8,8E,C2")
END CgDxaxToEsbx;

(* CgPushFarAddrItem — push the far address of an array item as
   [segment][offset] (offset on top of stack).  Handles a non-MReg item:
     isRef          : the slot holds a far ptr  -> LES BX,slot
     plain MGlobal  : near var in DS            -> AX=ofs, seg=DS
     plain MLocal   : near var on the stack(SS) -> AX=ofs, seg=SS
   Leaves ES:BX = far addr as a side effect.  Caller must NOT use this for
   MReg/isRef items (their ES:BX is already loaded). *)
PROCEDURE CgPushFarAddrItem*(mode: INTEGER; adr: LONGINT; isRef: BOOLEAN);
BEGIN
  IF isRef THEN
    CgLesBxItem(mode, adr)
  ELSE
    CgLoadAddrItem(mode, adr);
    Emit2(08BH, 0D8H);        (* MOV BX, AX *)
    CgEsFromMode(mode)        (* ES = SS or DS *)
  END;
  Emit1(006H);                (* PUSH ES  (segment) *)
  Emit1(053H)                 (* PUSH BX  (offset)  *)
END CgPushFarAddrItem;

(* CgArrCount — CX := number of bytes to copy for an array assignment.
   dstSize is the destination's fixed byte size.  When the source is an open
   array (srcOpen=TRUE, slot at [BP+srcAdr]) the count is min(dstSize, LEN);
   otherwise it is the compile-time min(dstSize, srcSize). *)
PROCEDURE CgArrCount*(dstSize: LONGINT; srcOpen: BOOLEAN; srcAdr, srcSize: LONGINT);
  VAR n: LONGINT; ok: Backpatch;
BEGIN
  IF srcOpen THEN
    (* AX = runtime LEN: the 6-byte open-array slot {ofs:2, seg:2, LEN:2}
       lives at [BP+srcAdr]; LEN is at +4. *)
    CgLoadBp(srcAdr + 4);
    Emit1(03DH); EmitW(INTEGER(dstSize));  (* CMP AX, dstSize *)
    (* UNSIGNED compare: dstSize may legally be up to 64000 — a signed JLE
       treats a >= 32 KB size as negative and picks the wrong count for the
       REP MOVSB below (silent corruption). *)
    CgCondShort(OpJbe, ok);                (* JBE keep (AX <= dstSize, unsigned) *)
    CgLoadImm(INTEGER(dstSize));           (* MOV AX, dstSize *)
    CgPatchShort(ok);
    Emit2(08BH, 0C8H)                      (* MOV CX, AX *)
  ELSE
    IF srcSize < dstSize THEN n := srcSize ELSE n := dstSize END;
    Emit1(0B9H);                                  (* MOV CX, imm16 *)
    Emit1(BYTE(n MOD LONGINT(256)));
    Emit1(BYTE((n DIV LONGINT(256)) MOD LONGINT(256)))
  END
END CgArrCount;

PROCEDURE CgDerefFar;
BEGIN
  Emit3(026H, 08BH, 007H)  (* ES: MOV AX,[BX] *)
END CgDerefFar;

PROCEDURE CgDerefFarByte;
BEGIN
  (* ES: MOV AL,[BX] / AND AX,00FFh *)
  EmitCodeStr("26,8A,07,25,FF,00")
END CgDerefFarByte;

PROCEDURE CgStoreDerefFar;
BEGIN
  Emit3(026H, 089H, 007H)  (* ES: MOV [BX],AX *)
END CgStoreDerefFar;

PROCEDURE CgStoreDerefFarByte;
BEGIN
  Emit3(026H, 088H, 007H)  (* ES: MOV [BX],AL *)
END CgStoreDerefFarByte;

PROCEDURE CgDerefFarLong;
BEGIN
  (* ES:MOV AX,[BX] / ES:MOV DX,[BX+2] *)
  EmitCodeStr("26,8B,07,26,8B,57,02")
END CgDerefFarLong;

PROCEDURE CgStoreDerefFarLong;
BEGIN
  (* ES:MOV [BX],AX / ES:MOV [BX+2],DX *)
  EmitCodeStr("26,89,07,26,89,57,02")
END CgStoreDerefFarLong;

PROCEDURE CgLoadTagFar();
BEGIN
  (* ES: MOV AX,[BX-2] *)
  EmitCodeStr("26,8B,47,FE")
END CgLoadTagFar;

PROCEDURE CgStoreWordEsbxImm*(val: INTEGER);
BEGIN
  Emit3(026H, 0C7H, 007H); EmitW(val)  (* ES: MOV [BX], imm16 *)
END CgStoreWordEsbxImm;

PROCEDURE CgLoadPtrBp(ofs: LONGINT);
BEGIN
  CgLoadBp(ofs);                  (* AX = [BP+ofs]   (offset word) *)
  EmitRel(08BH, 016H, ofs + 2)    (* MOV DX, [BP+ofs+2] (segment word) *)
END CgLoadPtrBp;

PROCEDURE CgStorePtrBp(ofs: LONGINT);
BEGIN
  CgStoreBp(ofs);                 (* [BP+ofs] := AX *)
  EmitRel(089H, 016H, ofs + 2)    (* [BP+ofs+2] := DX *)
END CgStorePtrBp;

PROCEDURE CgLoadPtrMem(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  CgLoadMem(dataOfs);  (* AX = [dataOfs] + RELOC *)
  Emit2(08BH, 016H);
  patch := CgPc(); EmitW(INTEGER(dataOfs + WORD(2)));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgLoadPtrMem;

PROCEDURE CgStorePtrMem(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  CgStoreMem(dataOfs);  (* [dataOfs] = AX + RELOC *)
  Emit2(089H, 016H);
  patch := CgPc(); EmitW(INTEGER(dataOfs + WORD(2)));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgStorePtrMem;

PROCEDURE CgAddBxImm*(imm: INTEGER);
BEGIN
  IF imm = 0 THEN RETURN END;
  (* imm8 form sign-extends: valid ONLY for -128..127.  A missing lower bound
     let a negative imm (e.g. a field offset >= 32768 arriving as a negative
     INTEGER) be emitted as one sign-extended byte — a different constant. *)
  IF (imm >= -128) & (imm <= 127) THEN
    Emit3(083H, 0C3H, BYTE(imm))
  ELSE
    Emit2(081H, 0C3H); EmitW(imm)
  END
END CgAddBxImm;

(* ---- LONGINT (32-bit) helpers ---- *)

PROCEDURE CgLoadLongBp(ofs: LONGINT);
BEGIN
  CgLoadBp(ofs);
  EmitRel(08BH, 016H, ofs + 2)    (* MOV DX, [BP+ofs+2] (hi word) *)
END CgLoadLongBp;

PROCEDURE CgStoreLongBp(ofs: LONGINT);
BEGIN
  CgStoreBp(ofs);
  EmitRel(089H, 016H, ofs + 2)    (* [BP+ofs+2] := DX (hi word) *)
END CgStoreLongBp;

PROCEDURE CgLoadLongMem(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  CgLoadMem(dataOfs);
  Emit2(08BH, 016H);
  patch := CgPc(); EmitW(INTEGER(dataOfs + WORD(2)));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgLoadLongMem;

PROCEDURE CgStoreLongMem(dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  CgStoreMem(dataOfs);
  Emit2(089H, 016H);
  patch := CgPc(); EmitW(INTEGER(dataOfs + WORD(2)));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END CgStoreLongMem;

PROCEDURE CgLoadLongImm(val: LONGINT);
  VAR lo, hi: INTEGER;
BEGIN
  (* Bitwise extraction: unsigned right shift of the high 16 bits.
     Arithmetic DIV 65536 would round toward zero (IDIV), giving wrong
     bits for the hi-half when val is negative. *)
  lo := INTEGER(SYSTEM.AND(val, LONGINT(0FFFFH)));
  hi := INTEGER(SYSTEM.AND(SYSTEM.LSR(val, 16), LONGINT(0FFFFH)));
  IF lo = 0 THEN Emit2(033H, 0C0H)    (* XOR AX, AX *)
  ELSE Emit1(0B8H); EmitW(lo)          (* MOV AX, imm16 *)
  END;
  IF hi = 0 THEN Emit2(033H, 0D2H)    (* XOR DX, DX *)
  ELSE Emit1(0BAH); EmitW(hi)          (* MOV DX, imm16 *)
  END
END CgLoadLongImm;

PROCEDURE CgPushDxax*();
BEGIN
  EmitCodeStr("52,50")  (* PUSH DX; PUSH AX *)
END CgPushDxax;

PROCEDURE CgPopCxbx*();
BEGIN
  EmitCodeStr("5B,59")  (* POP BX; POP CX *)
END CgPopCxbx;

PROCEDURE CgPopAxdx*();
BEGIN
  EmitCodeStr("58,5A")  (* POP AX; POP DX *)
END CgPopAxdx;

PROCEDURE CgAdd32*();
BEGIN
  (* ADD AX,BX / ADC DX,CX *)
  EmitCodeStr("03,C3,13,D1")
END CgAdd32;

PROCEDURE CgSub32*();
BEGIN
  (* XCHG AX,BX / SUB AX,BX / XCHG DX,CX / SBB DX,CX *)
  EmitCodeStr("87,C3,2B,C3,87,D1,1B,D1")
END CgSub32;

PROCEDURE CgNeg32*();
BEGIN
  (* NOT AX / NOT DX / ADD AX,1 / ADC DX,0 *)
  EmitCodeStr("F7,D0,F7,D2,05,01,00,83,D2,00")
END CgNeg32;

PROCEDURE CgAnd32*();
BEGIN
  (* AND AX,BX / AND DX,CX *)
  EmitCodeStr("23,C3,23,D1")
END CgAnd32;

PROCEDURE CgOr32*();
BEGIN
  (* OR AX,BX / OR DX,CX *)
  EmitCodeStr("0B,C3,0B,D1")
END CgOr32;

PROCEDURE CgXor32*();
BEGIN
  (* XOR AX,BX / XOR DX,CX *)
  EmitCodeStr("33,C3,33,D1")
END CgXor32;

(* AssertEmitLen — guard for emitters whose hard-coded rel8 jump distances
   depend on the exact byte length of the emitted fragment: any edit that
   changes a neighbouring byte silently breaks control flow, so each such
   emitter asserts its own total length at compile time (of the USER's
   program — zero cost in the generated code). *)
PROCEDURE AssertEmitLen(startPc: LONGINT; expect: INTEGER); NEAR;
BEGIN
  IF CgPc() - startPc # LONGINT(expect) THEN
    LogErr.Error("internal: emitter length drift (hard-coded jump offsets)")
  END
END AssertEmitLen;

(* .false: XOR AX,AX / JMP +3 / .true: MOV AX,1 — boolean materialize tail *)
PROCEDURE CgFalseTrue; NEAR;
  VAR pc0: LONGINT;
BEGIN
  pc0 := CgPc();
  EmitCodeStr("33,C0,EB,03,B8,01,00");
  AssertEmitLen(pc0, 7)
END CgFalseTrue;

PROCEDURE CgCmp32Bool*(hiTrue, hiFalse, loTrue: INTEGER);
  VAR pc0: LONGINT;
BEGIN
  (* layout: lo-word compare then hi-word combine *)
  pc0 := CgPc();
  Emit2(03BH, 0CAH);                   (* CMP CX, DX *)
  Emit2(BYTE(hiTrue),  BYTE(10));      (* Jhi_true → .true *)
  Emit2(BYTE(hiFalse), BYTE(4));       (* Jhi_false → .false *)
  Emit2(03BH, 0D8H);                   (* CMP BX, AX *)
  Emit2(BYTE(loTrue),  BYTE(4));       (* Jlo_true → .true *)
  CgFalseTrue;
  AssertEmitLen(pc0, 17)
END CgCmp32Bool;

(* ---- setcc ---- *)

PROCEDURE CgSetcc*(jcc: INTEGER);
  VAR pc0: LONGINT; branchJcc: INTEGER;
BEGIN
  IF condArmed THEN
    condArmed := FALSE; condHit := TRUE;
    (* Flags are fresh here (every CgSetcc caller emits exactly one
       flag-setting instruction immediately before calling CgSetcc — see
       bigopt.md 2.1).  Branch straight on those flags instead of
       materializing 0/1 then re-testing. *)
    (* CgCondNear(Y, bp) branches to bp when Y is TRUE (falls through when Y
       false — see CgCondNear: it skips the near JMP via InvertJcc(Y), so
       the JMP itself executes exactly when Y holds).  We want: branch to
       condBp when the condition is NOT condWantTrue.
       - condWantTrue=TRUE:  branch to bp when jcc false -> CgCondNear(InvertJcc(jcc), bp)
       - condWantTrue=FALSE: branch to bp when jcc true  -> CgCondNear(jcc, bp) *)
    IF condWantTrue THEN branchJcc := InvertJcc(jcc) ELSE branchJcc := jcc END;
    CgCondNear(branchJcc, condBp)
  ELSE
    pc0 := CgPc();
    Emit2(BYTE(jcc), BYTE(4));           (* Jcc +4 *)
    CgFalseTrue;
    AssertEmitLen(pc0, 9)
  END
END CgSetcc;

PROCEDURE CgCmp32Eq*();
BEGIN
  EmitCodeStr("33,CA,33,D8,0B,CB");
  CgSetcc(OpJz)
END CgCmp32Eq;

PROCEDURE CgCmp32Neq*();
BEGIN
  EmitCodeStr("33,CA,33,D8,0B,CB");
  CgSetcc(OpJnz)
END CgCmp32Neq;

(* ---- arithmetic ---- *)

PROCEDURE CgAdd*()      ; BEGIN Emit2(003H, 0C1H) END CgAdd;       (* ADD AX, CX *)
PROCEDURE CgSub*()      ; BEGIN EmitCodeStr("91,2B,C1") END CgSub; (* XCHG AX,CX / SUB AX,CX *)
PROCEDURE CgMul*()      ; BEGIN Emit2(0F7H, 0E9H) END CgMul;       (* IMUL CX *)
(* Oberon-07 DIV/MOD are floored (result has the divisor's sign; quotient
   rounds toward -infinity), not the 8086 IDIV's truncating (toward zero).
   After XCHG AX,CX / CWD / IDIV CX: AX=truncated quotient, DX=remainder
   (dividend's sign), CX=divisor (unchanged by IDIV).  If the remainder is
   nonzero and its sign differs from the divisor's, truncating and floored
   disagree; fix up by decrementing the quotient and adding the divisor back
   into the remainder (BX is free scratch here — not live across IDIV). *)
PROCEDURE CgDivModFixup;
  VAR doneBp1, doneBp2: Backpatch;
BEGIN
  Emit2(BYTE(085H), 0D2H);                 (* TEST DX,DX *)
  CgCondShort(OpJz, doneBp1);
  Emit2(BYTE(089H), 0D3H);                 (* MOV BX,DX *)
  Emit2(BYTE(031H), 0CBH);                 (* XOR BX,CX *)
  CgCondShort(0079H, doneBp2);             (* JNS done (signs equal) *)
  Emit1(BYTE(048H));                       (* DEC AX *)
  Emit2(BYTE(001H), 0CAH);                 (* ADD DX,CX *)
  CgPatchShort(doneBp1);
  CgPatchShort(doneBp2)
END CgDivModFixup;

PROCEDURE CgDiv*()      ; BEGIN EmitCodeStr("91,99,F7,F9"); CgDivModFixup() END CgDiv; (* XCHG AX,CX / CWD / IDIV CX *)
PROCEDURE CgMod*()      ; BEGIN CgDiv(); Emit2(08BH,0C2H) END CgMod;
PROCEDURE CgMulU*()     ; BEGIN Emit2(0F7H, 0E1H) END CgMulU;      (* MUL CX unsigned *)
PROCEDURE CgDivU*()     ; BEGIN EmitCodeStr("91,31,D2,F7,F1") END CgDivU; (* XCHG AX,CX / XOR DX,DX / DIV CX *)
PROCEDURE CgModU*()     ; BEGIN CgDivU(); Emit2(08BH,0C2H) END CgModU;
PROCEDURE CgNeg*()      ; BEGIN Emit2(0F7H, 0D8H) END CgNeg;
PROCEDURE CgAnd*()      ; BEGIN Emit2(023H, 0C1H) END CgAnd;
PROCEDURE CgOr*()       ; BEGIN Emit2(00BH, 0C1H) END CgOr;
PROCEDURE CgXor*()      ; BEGIN Emit2(033H, 0C1H) END CgXor;

(* CgAndImm16 — AND AX, imm16  (used for `x MOD 2^n` → mask). *)
PROCEDURE CgAndImm16*(mask: INTEGER);
BEGIN
  Emit1(025H); EmitW(mask)
END CgAndImm16;

(* CgAndImm32 — AND DX:AX, imm32  (LONGINT `x MOD 2^n` → mask).
   Emits `AND AX,lo` then `AND DX,hi`.  hi=0 collapses to `XOR DX,DX`. *)
PROCEDURE CgAndImm32*(mask: LONGINT);
  VAR lo, hi: INTEGER;
BEGIN
  lo := INTEGER(SYSTEM.AND(mask, LONGINT(0FFFFH)));
  hi := INTEGER(SYSTEM.AND(SYSTEM.LSR(mask, 16), LONGINT(0FFFFH)));
  Emit1(025H); EmitW(lo);                  (* AND AX, lo *)
  IF hi = 0 THEN Emit2(033H, 0D2H)         (* XOR DX, DX *)
  ELSE Emit1(081H); Emit1(0E2H); EmitW(hi) (* AND DX, hi *)
  END
END CgAndImm32;
PROCEDURE CgIncAx*()    ; BEGIN Emit1(040H) END CgIncAx;
PROCEDURE CgDecAx*()    ; BEGIN Emit1(048H) END CgDecAx;

(* ---- memory-destination INC/DEC/ADD/SUB (compile-time-address fast path) ----
   These operate directly on a plain near variable at a fixed displacement,
   avoiding the LOAD+op+STORE round-trip.  MGlobal = [disp16] in DS; MLocal =
   [BP+disp] in SS.  Only valid when the variable is NOT accessed via a far
   ref (isRef) — the caller guarantees this. *)

(* EmitMemDstBp — opcode + [BP+disp] modrm with extension /ext (reg field). *)
PROCEDURE EmitMemDstBp(opcode: BYTE; ext: INTEGER; ofs: LONGINT);
BEGIN EmitRel(opcode, BYTE(006H + ext * 8), ofs) END EmitMemDstBp;

(* EmitMemDstMem — opcode + [disp16] modrm (mod=00,rm=110) with extension /ext,
   followed by the reloc'd data offset. *)
PROCEDURE EmitMemDstMem(opcode: BYTE; ext: INTEGER; dataOfs: WORD);
  VAR patch: LONGINT;
BEGIN
  Emit1(opcode); Emit1(BYTE(006H + ext * 8));
  patch := CgPc(); EmitW(INTEGER(dataOfs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END EmitMemDstMem;

(* INC/DEC by 1 on a 16-bit or 8-bit memory dest.  byteSz => FE (/0=INC,/1=DEC);
   else FF.  isInc selects the /ext.  isGlobal selects the DS-mem vs BP form. *)
PROCEDURE CgIncDecMem*(isGlobal, isInc, byteSz: BOOLEAN; adr: LONGINT);
  VAR opc: BYTE; ext: INTEGER;
BEGIN
  IF byteSz THEN opc := 0FEH ELSE opc := 0FFH END;
  IF isInc THEN ext := 0 ELSE ext := 1 END;
  IF isGlobal THEN EmitMemDstMem(opc, ext, WORD(adr))
  ELSE EmitMemDstBp(opc, ext, adr) END
END CgIncDecMem;

(* ADD/SUB imm to a 16-bit memory dest.  Uses the 83 /0,/5 sign-extended-imm8
   form when the immediate fits in a signed byte, else 81 with a full imm16.
   isInc selects ADD (/0) vs SUB (/5). *)
PROCEDURE CgAddSubMemW*(isGlobal, isInc: BOOLEAN; adr: LONGINT; imm: INTEGER);
  VAR ext: INTEGER; short: BOOLEAN;
BEGIN
  IF isInc THEN ext := 0 ELSE ext := 5 END;
  short := (imm >= -128) & (imm <= 127);
  IF isGlobal THEN
    IF short THEN EmitMemDstMem(083H, ext, WORD(adr)); Emit1(BYTE(SYSTEM.AND(imm, 0FFH)))
    ELSE EmitMemDstMem(081H, ext, WORD(adr)); EmitW(imm) END
  ELSE
    IF short THEN EmitMemDstBp(083H, ext, adr); Emit1(BYTE(SYSTEM.AND(imm, 0FFH)))
    ELSE EmitMemDstBp(081H, ext, adr); EmitW(imm) END
  END
END CgAddSubMemW;

(* ADD/SUB imm to an 8-bit (BYTE/CHAR) memory dest: 80 /0,/5 + imm8. *)
PROCEDURE CgAddSubMemB*(isGlobal, isInc: BOOLEAN; adr: LONGINT; imm: INTEGER);
  VAR ext: INTEGER;
BEGIN
  IF isInc THEN ext := 0 ELSE ext := 5 END;
  IF isGlobal THEN EmitMemDstMem(080H, ext, WORD(adr))
  ELSE EmitMemDstBp(080H, ext, adr) END;
  Emit1(BYTE(SYSTEM.AND(imm, 0FFH)))
END CgAddSubMemB;

(* ---- far-ref memory-dest ADD/SUB via ES:BX ----
   Same fast path as the near ADD/SUB-const helpers above, but the destination
   is [ES:BX] (a dereferenced far pointer / VAR param / far array element).
   ES:BX must already be loaded (CgLesBxItem).  Every instruction gets a 26h
   ES-override prefix; the modrm rm=111 selects [BX] (disp=0) — for the high
   word of a LONGINT we use [BX+2] (26 .. 47 02).  (There is no dedicated
   INC/DEC-by-1 far opcode: the far implicit-step-1 path reuses these
   ADD/SUB-imm helpers with imm=1 instead.) *)

(* ADD/SUB imm16 to [ES:BX] (INTEGER/WORD/ADDRESS-offset). *)
PROCEDURE CgAddSubEsbxW*(isInc: BOOLEAN; imm: INTEGER);
  VAR ext: INTEGER; short: BOOLEAN;
BEGIN
  IF isInc THEN ext := 0 ELSE ext := 5 END;
  short := (imm >= -128) & (imm <= 127);
  Emit1(026H);
  IF short THEN Emit1(083H); Emit1(BYTE(007H + ext * 8)); Emit1(BYTE(SYSTEM.AND(imm, 0FFH)))
  ELSE Emit1(081H); Emit1(BYTE(007H + ext * 8)); EmitW(imm) END
END CgAddSubEsbxW;

(* ADD/SUB imm8 to [ES:BX] (BYTE/CHAR). *)
PROCEDURE CgAddSubEsbxB*(isInc: BOOLEAN; imm: INTEGER);
  VAR ext: INTEGER;
BEGIN
  IF isInc THEN ext := 0 ELSE ext := 5 END;
  Emit3(026H, 080H, BYTE(007H + ext * 8)); Emit1(BYTE(SYSTEM.AND(imm, 0FFH)))
END CgAddSubEsbxB;

(* ADD/SUB a 32-bit constant to [ES:BX] (LONGINT): low word at [BX], carry into
   the high word at [BX+2]. *)
PROCEDURE CgAddSubEsbxL*(isInc: BOOLEAN; imm: LONGINT);
  VAR lo, hi, extLo, extHi: INTEGER;
BEGIN
  lo := INTEGER(SYSTEM.AND(imm, LONGINT(0FFFFH)));
  hi := INTEGER(SYSTEM.AND(SYSTEM.LSR(imm, 16), LONGINT(0FFFFH)));
  IF isInc THEN extLo := 0; extHi := 2 ELSE extLo := 5; extHi := 3 END;
  (* low: 26 81 /extLo [BX]  imm16 *)
  Emit1(026H); Emit1(081H); Emit1(BYTE(007H + extLo * 8)); EmitW(lo);
  (* high: 26 81 /extHi [BX+2]  imm16   (modrm rm=111 disp8 => base+040H, +02) *)
  Emit1(026H); Emit1(081H); Emit1(BYTE(047H + extHi * 8)); Emit1(002H); EmitW(hi)
END CgAddSubEsbxL;

(* 32-bit (LONGINT / SYSTEM.ADDRESS-with-carry) memory-dest add/sub of a constant.
   Emits a low-word ADD/SUB then a high-word ADC/SBB so carry propagates.
   For SYSTEM.ADDRESS (offset-only, no carry into segment) use CgAddSubMemW on
   the offset word instead — callers pick the right one. *)
PROCEDURE CgAddSubMemL*(isGlobal, isInc: BOOLEAN; adr: LONGINT; imm: LONGINT);
  VAR lo, hi, extLo, extHi: INTEGER;
BEGIN
  lo := INTEGER(SYSTEM.AND(imm, LONGINT(0FFFFH)));
  hi := INTEGER(SYSTEM.AND(SYSTEM.LSR(imm, 16), LONGINT(0FFFFH)));
  IF isInc THEN extLo := 0; extHi := 2 ELSE extLo := 5; extHi := 3 END;
  (* low word: ADD/SUB [adr], lo  (full imm16 form to keep it uniform) *)
  IF isGlobal THEN EmitMemDstMem(081H, extLo, WORD(adr)) ELSE EmitMemDstBp(081H, extLo, adr) END;
  EmitW(lo);
  (* high word: ADC/SBB [adr+2], hi *)
  IF isGlobal THEN EmitMemDstMem(081H, extHi, WORD(adr + 2)) ELSE EmitMemDstBp(081H, extHi, adr + 2) END;
  EmitW(hi)
END CgAddSubMemL;
PROCEDURE CgCmp*()      ; BEGIN Emit2(03BH, 0C8H) END CgCmp;       (* CMP CX, AX *)
PROCEDURE CgCmpAxBp*(ofs: LONGINT); BEGIN EmitRel(03BH, 006H, ofs) END CgCmpAxBp; (* CMP AX, [BP+ofs] *)
PROCEDURE CgTestAx*()   ; BEGIN Emit2(085H, 0C0H) END CgTestAx;
PROCEDURE CgBoolNot*()  ; BEGIN Emit3(083H, 0F0H, 001H) END CgBoolNot; (* XOR AX,1 *)
PROCEDURE CgCmpAxImm*(val: INTEGER);
BEGIN
  IF val = 0 THEN Emit2(085H, 0C0H)      (* TEST AX,AX — 2 bytes, same flags as CMP AX,0 *)
  ELSE Emit1(03DH); EmitW(val)           (* CMP AX, imm16 *)
  END
END CgCmpAxImm;

PROCEDURE CgPtrCmpEq*();
BEGIN
  (* POP CX / XOR AX,CX / POP BX / XOR DX,BX / OR AX,DX / TEST AX,AX *)
  EmitCodeStr("59,33,C1,5B,33,D3,0B,C2,85,C0")
END CgPtrCmpEq;

PROCEDURE CgLoadImm;
BEGIN
  IF val = 0 THEN Emit2(033H, 0C0H)   (* XOR AX,AX *)
  ELSE Emit1(0B8H); EmitW(val)
  END
END CgLoadImm;

PROCEDURE CgLoadImmCx*(val: INTEGER);
BEGIN
  Emit1(0B9H); EmitW(val)
END CgLoadImmCx;

(* ---- IS type tag scan ---- *)

PROCEDURE CgIsTagScan(tagId: INTEGER);
  VAR pc0: LONGINT;
BEGIN
  pc0 := CgPc();
  (* PUSH SI; MOV SI,AX; loop: MOV AX,[SI]; TEST AX,AX; JZ +10 -> false *)
  EmitCodeStr("56,89,C6,8B,04,85,C0,74,0A");
  Emit1(03DH); EmitW(tagId);        (* CMP AX, tagId *)
  (* JE +9 -> true; ADD SI,2; JMP -16 -> loop; false: XOR AX,AX; JMP +3 -> POP SI *)
  EmitCodeStr("74,09,83,C6,02,EB,F0,33,C0,EB,03");
  EmitCodeStr("B8,01,00,5E");       (* true: MOV AX,1 / POP SI *)
  AssertEmitLen(pc0, 27)
END CgIsTagScan;

PROCEDURE CgIsTagCheck*(VAR item: Item; tagId: INTEGER);
BEGIN
  CgLoadItem(item);              (* DX:AX = far pointer *)
  CgDxaxToEsbx();               (* ES:BX = object data *)
  CgLoadTagFar();               (* AX = ES:[BX-2] = tag descriptor offset *)
  CgIsTagScan(tagId)            (* AX = 0 or 1 *)
END CgIsTagCheck;

(* ---- shift / rotate ---- *)

PROCEDURE EmitShw(d1op, d3op: BYTE; n: INTEGER);
BEGIN
  IF n = 1 THEN Emit2(0D1H, d1op)
  ELSE Emit2(0B1H, BYTE(n)); Emit2(0D3H, d3op)
  END
END EmitShw;

PROCEDURE CgShlImm*(n: INTEGER); BEGIN EmitShw(0E0H, 0E0H, n) END CgShlImm;
PROCEDURE CgShrImm*(n: INTEGER); BEGIN EmitShw(0E8H, 0E8H, n) END CgShrImm;
PROCEDURE CgSarImm*(n: INTEGER); BEGIN EmitShw(0F8H, 0F8H, n) END CgSarImm;
PROCEDURE CgRorImm*(n: INTEGER); BEGIN EmitShw(0C8H, 0C8H, n) END CgRorImm;

(* PopCount16 — number of set bits in the low 16 bits of m. *)
PROCEDURE PopCount16*(m: INTEGER): INTEGER;
  VAR n, c: INTEGER;
BEGIN
  n := SYSTEM.AND(m, 0FFFFH); c := 0;
  WHILE n # 0 DO INC(c, SYSTEM.AND(n, 1)); n := SYSTEM.LSR(n, 1) END;
  RETURN c
END PopCount16;

(* ShlAxBy1N / ShlCxBy1N — emit `SHL AX,1` (D1 E0) / `SHL CX,1` (D1 E1) n times.
   Shift-by-1 is used instead of the `MOV CL,n; SHL r,CL` form because loading
   CL would clobber the low byte of the value held in CX (the saved operand). *)
PROCEDURE ShlAxBy1N(n: INTEGER);
  VAR i: INTEGER;
BEGIN
  i := 0; WHILE i < n DO Emit2(0D1H, 0E0H); INC(i) END
END ShlAxBy1N;

PROCEDURE ShlCxBy1N(n: INTEGER);
  VAR i: INTEGER;
BEGIN
  i := 0; WHILE i < n DO Emit2(0D1H, 0E1H); INC(i) END
END ShlCxBy1N;

(* CgMulConst16 — 16-bit (INTEGER/WORD) multiply of AX by a small positive
   constant `m` using shift+add/sub instead of IMUL.  The value is in AX; CX is
   used as scratch (free at this point in the term dispatch).  Returns TRUE if a
   fast sequence was emitted, FALSE if the caller must fall back to IMUL.

   All shifts use the SHL r16,1 form (D1 /4) repeated, NOT `MOV CL,n; SHL r,CL`,
   because MOV CL,n would corrupt CX (which holds the saved operand x).

   Handles:
     m = 2^a - 1 (3,7,15,31,63):
        x*(2^a-1) = (x<<a) - x          -> MOV CX,AX; (SHL AX,1)*a; SUB AX,CX
     m with exactly two set bits (5,6,9,10,12,...):
        x*(2^a+2^b) = (x<<a) + (x<<b)   -> MOV CX,AX; (SHL AX,1)*a; (SHL CX,1)*b; ADD AX,CX
   (Powers of two are handled earlier by CgShlImm and never reach here.)
   Only attempted for small m (<= 64) so the shift chains stay short. *)
PROCEDURE CgMulConst16*(m: INTEGER): BOOLEAN;
  VAR a, b, t, i: INTEGER;
BEGIN
  IF (m < 3) OR (m > 64) THEN RETURN FALSE END;
  (* 2^a - 1 form: m+1 is a power of two (3,7,15,31,63) *)
  IF PopCount16(m + 1) = 1 THEN
    a := 0; t := m + 1; WHILE t > 1 DO t := SYSTEM.LSR(t, 1); INC(a) END;
    Emit2(089H, 0C1H);          (* MOV CX, AX *)
    ShlAxBy1N(a);               (* AX = x<<a *)
    Emit2(02BH, 0C1H);          (* SUB AX, CX *)
    RETURN TRUE
  END;
  (* two-bits-set form: m = 2^a + 2^b, a > b >= 0 *)
  IF PopCount16(m) = 2 THEN
    a := -1; b := -1; i := 0; t := SYSTEM.AND(m, 0FFFFH);
    WHILE t # 0 DO
      IF SYSTEM.AND(t, 1) # 0 THEN
        IF b < 0 THEN b := i ELSE a := i END
      END;
      t := SYSTEM.LSR(t, 1); INC(i)
    END;
    Emit2(089H, 0C1H);          (* MOV CX, AX  (CX = x = x<<0) *)
    ShlAxBy1N(a);               (* AX = x<<a   (high term) *)
    ShlCxBy1N(b);               (* CX = x<<b   (low term) *)
    Emit2(003H, 0C1H);          (* ADD AX, CX *)
    RETURN TRUE
  END;
  RETURN FALSE
END CgMulConst16;
PROCEDURE CgShlCl*(); BEGIN Emit2(0D3H, 0E0H) END CgShlCl;
PROCEDURE CgShrCl*(); BEGIN Emit2(0D3H, 0E8H) END CgShrCl;
PROCEDURE CgSarCl*(); BEGIN Emit2(0D3H, 0F8H) END CgSarCl;
PROCEDURE CgRorCl*(); BEGIN Emit2(0D3H, 0C8H) END CgRorCl;

(* ---- 32-bit shifts ---- *)

PROCEDURE CgLsl32Imm*(n: INTEGER);
BEGIN
  n := n MOD 32;
  IF n = 0 THEN RETURN END;
  IF n = 16 THEN
    Emit2(089H, 0C2H); Emit2(033H, 0C0H)  (* MOV DX,AX / XOR AX,AX *)
  ELSIF n > 16 THEN
    Emit2(089H, 0C2H); Emit2(033H, 0C0H);
    EmitShw(0E2H, 0E2H, n - 16)           (* SHL DX, (n-16) *)
  ELSE
    Emit1(053H);                           (* PUSH BX *)
    Emit2(089H, 0C3H);                     (* MOV BX,AX *)
    EmitShw(0E0H, 0E0H, n);               (* SHL AX,n *)
    EmitShw(0EBH, 0EBH, 16 - n);          (* SHR BX,(16-n) *)
    EmitShw(0E2H, 0E2H, n);               (* SHL DX,n *)
    Emit2(00BH, 0D3H);                     (* OR DX,BX *)
    Emit1(05BH)                            (* POP BX *)
  END
END CgLsl32Imm;

PROCEDURE CgLsr32Imm*(n: INTEGER);
BEGIN
  n := n MOD 32;
  IF n = 0 THEN RETURN END;
  IF n = 16 THEN
    Emit2(089H, 0D0H); Emit2(033H, 0D2H)  (* MOV AX,DX / XOR DX,DX *)
  ELSIF n > 16 THEN
    Emit2(089H, 0D0H); Emit2(033H, 0D2H);
    EmitShw(0E8H, 0E8H, n - 16)           (* SHR AX, (n-16) *)
  ELSE
    Emit1(053H);                           (* PUSH BX *)
    Emit2(089H, 0D3H);                     (* MOV BX,DX *)
    EmitShw(0EAH, 0EAH, n);               (* SHR DX,n *)
    EmitShw(0E3H, 0E3H, 16 - n);          (* SHL BX,(16-n) *)
    EmitShw(0E8H, 0E8H, n);               (* SHR AX,n *)
    Emit2(00BH, 0C3H);                     (* OR AX,BX *)
    Emit1(05BH)                            (* POP BX *)
  END
END CgLsr32Imm;

PROCEDURE CgAsr32Imm*(n: INTEGER);
BEGIN
  n := n MOD 32;
  IF n = 0 THEN RETURN END;
  IF n = 16 THEN
    Emit2(089H, 0D0H); (* MOV AX, DX *)
    Emit2(0B1H, 15); Emit2(0D3H, 0FAH) (* SAR DX, 15 *)
  ELSIF n > 16 THEN
    Emit2(089H, 0D0H);
    Emit2(0B1H, 15); Emit2(0D3H, 0FAH); (* SAR DX, 15 *)
    EmitShw(0F8H, 0F8H, n - 16)         (* SAR AX, (n-16) *)
  ELSE
    Emit1(053H);
    Emit2(089H, 0D3H);
    EmitShw(0FAH, 0FAH, n);             (* SAR DX, n *)
    EmitShw(0E3H, 0E3H, 16 - n);
    EmitShw(0E8H, 0E8H, n);             (* SHR AX, n (gets bits from DX) *)
    Emit2(00BH, 0C3H);
    Emit1(05BH)
  END
END CgAsr32Imm;

PROCEDURE CgRor32Imm*(n: INTEGER);
BEGIN
  n := n MOD 32;
  IF n = 0 THEN RETURN END;
  IF n = 16 THEN
    Emit2(087H, 0C2H)  (* XCHG AX,DX *)
  ELSIF n > 16 THEN
    Emit2(087H, 0C2H);
    CgRor32Imm(n - 16)
  ELSE
    Emit1(053H);
    Emit2(089H, 0C3H);                    (* MOV BX,AX *)
    EmitShw(0E8H, 0E8H, n);
    EmitShw(0E3H, 0E3H, 16 - n);
    Emit1(052H);                           (* PUSH DX *)
    EmitShw(0EAH, 0EAH, n);
    Emit2(00BH, 0D3H);
    Emit1(05BH);                           (* POP BX (=old DX) *)
    EmitShw(0E3H, 0E3H, 16 - n);
    Emit2(00BH, 0C3H);
    Emit1(05BH)
  END
END CgRor32Imm;

(* The four variable-count 32-bit shifts are JCXZ/LOOP-free (project strong
   rule — both are slow on real 8086 hardware): AND CX,1F already sets ZF, so
   the zero-count guard is a plain JZ, and the loop tail is DEC CX / JNZ. *)

PROCEDURE CgLsl32Cl*();
BEGIN
  (* AND CX,1Fh; JZ done; loop: SHL AX,1; RCL DX,1; DEC CX; JNZ loop; done: *)
  EmitCodeStr("83,E1,1F,74,07,D1,E0,D1,D2,49,75,F9")
END CgLsl32Cl;

PROCEDURE CgLsr32Cl*();
BEGIN
  (* AND CX,1Fh; JZ done; loop: SHR DX,1; RCR AX,1; DEC CX; JNZ loop; done: *)
  EmitCodeStr("83,E1,1F,74,07,D1,EA,D1,D8,49,75,F9")
END CgLsr32Cl;

PROCEDURE CgAsr32Cl*();
BEGIN
  (* AND CX,1Fh; JZ done; loop: SAR DX,1; RCR AX,1; DEC CX; JNZ loop; done: *)
  EmitCodeStr("83,E1,1F,74,07,D1,FA,D1,D8,49,75,F9")
END CgAsr32Cl;

PROCEDURE CgRor32Cl*();
BEGIN
  (* Rewritten JCXZ/LOOP-free — and the old sequence was WRONG twice over:
     its JZ tested ZF from `SHR DX,1` (not the saved bit-0 of AX: rotates
     don't touch ZF, but SHR does), and its `JZ +3` skipped only 3 of the
     4-byte `OR DX,8000h`, landing mid-instruction.  Correct rotate step:
     SHR DX,1 moves DX bit0 into CF; RCR AX,1 pulls it into AX bit15 and
     leaves OLD AX bit0 in CF; JNC skips the wrap; else OR DX,8000h sets the
     bit that wrapped around.
       AND CX,1Fh; JZ done;
       loop: SHR DX,1; RCR AX,1; JNC noset; OR DX,8000h;
       noset: DEC CX; JNZ loop; done: *)
  EmitCodeStr("83,E1,1F,74,0D,D1,EA,D1,D8,73,04,81,CA,00,80,49,75,F3")
END CgRor32Cl;

(* ---- FPU helpers ---- *)

PROCEDURE FldStoreMem(op1, op2: BYTE; ofs: WORD);
  VAR patch: LONGINT;
BEGIN
  Emit2(op1, op2);
  patch := CgPc(); EmitW(INTEGER(ofs));
  Rdoff.RdfAddReloc(CgObj, Rdoff.SegCode, patch, 2, Rdoff.SegData, FALSE)
END FldStoreMem;

PROCEDURE CgFldRealBp(ofs: LONGINT);       BEGIN EmitRel(0D9H, 006H, ofs) END CgFldRealBp;
PROCEDURE CgFstpRealBp(ofs: LONGINT);      BEGIN EmitRel(0D9H, 01EH, ofs) END CgFstpRealBp;
PROCEDURE CgFldLongrealBp(ofs: LONGINT);   BEGIN EmitRel(0DDH, 006H, ofs) END CgFldLongrealBp;
PROCEDURE CgFstpLongrealBp(ofs: LONGINT);  BEGIN EmitRel(0DDH, 01EH, ofs) END CgFstpLongrealBp;
PROCEDURE CgFldRealMem(ofs: WORD);      BEGIN FldStoreMem(0D9H, 006H, ofs) END CgFldRealMem;
PROCEDURE CgFstpRealMem(ofs: WORD);     BEGIN FldStoreMem(0D9H, 01EH, ofs) END CgFstpRealMem;
PROCEDURE CgFldLongrealMem(ofs: WORD);  BEGIN FldStoreMem(0DDH, 006H, ofs) END CgFldLongrealMem;
PROCEDURE CgFstpLongrealMem(ofs: WORD); BEGIN FldStoreMem(0DDH, 01EH, ofs) END CgFstpLongrealMem;
PROCEDURE CgFldRealConst(dataOfs: WORD);     BEGIN FldStoreMem(0D9H, 006H, dataOfs) END CgFldRealConst;
PROCEDURE CgFldLongrealConst(dataOfs: WORD); BEGIN FldStoreMem(0DDH, 006H, dataOfs) END CgFldLongrealConst;

PROCEDURE CgFldRealEsbx();     BEGIN Emit3(026H, 0D9H, 007H) END CgFldRealEsbx;
PROCEDURE CgFstpRealEsbx();    BEGIN Emit3(026H, 0D9H, 01FH) END CgFstpRealEsbx;
PROCEDURE CgFldLongrealEsbx(); BEGIN Emit3(026H, 0DDH, 007H) END CgFldLongrealEsbx;
PROCEDURE CgFstpLongrealEsbx(); BEGIN Emit3(026H, 0DDH, 01FH) END CgFstpLongrealEsbx;

PROCEDURE CgFadd*(); BEGIN Emit2(0DEH, 0C1H) END CgFadd;
PROCEDURE CgFmul*(); BEGIN Emit2(0DEH, 0C9H) END CgFmul;
PROCEDURE CgFchs*(); BEGIN Emit2(0D9H, 0E0H) END CgFchs;

PROCEDURE CgFpush*();
BEGIN
  (* SUB SP,8 / MOV BX,SP / SS: FSTP qword [BX] *)
  EmitCodeStr("83,EC,08,89,E3,36,DD,1F")
END CgFpush;

PROCEDURE CgFpop*();
BEGIN
  (* MOV BX,SP / SS: FLD qword [BX] / ADD SP,8 *)
  EmitCodeStr("89,E3,36,DD,07,83,C4,08")
END CgFpop;

PROCEDURE CgFistAx*();
BEGIN
  (* SUB SP,2 / MOV BX,SP / SS:FISTP word [BX] / SS:MOV AX,[BX] / ADD SP,2 *)
  EmitCodeStr("83,EC,02,89,E3,36,DF,1F,36,8B,07,83,C4,02")
END CgFistAx;

PROCEDURE CgFloorAx*();
BEGIN
  EmitCodeStr("83,EC,04,89,E3,36,D9,3F,36,8B,07,25,FF,F3,0D,00,04,36,89,47,02,36,D9,6F,02,83,EC,02,89,E3,36,DF,1F,36,8B,07,83,C4,02,89,E3,36,D9,2F,83,C4,04")
END CgFloorAx;

PROCEDURE CgFcmp*(jccTrue: INTEGER);
BEGIN
  EmitCodeStr("DE,D9,DF,E0,9E");  (* FCOMPP; FNSTSW AX; SAHF *)
  CgSetcc(jccTrue)
END CgFcmp;

(* ---- item helpers ---- *)

PROCEDURE CgLoadItem;
  VAR isPtr, isByte, isLong, isReal, isLreal, isNil, isAddr: BOOLEAN;
      tForm: INTEGER; tFar: BOOLEAN;
BEGIN
  tForm := -1; tFar := FALSE;
  IF item.type # Syms.NoType THEN
    tForm := item.type.form; tFar := item.type.isFar
  END;
  isPtr   := (tForm = Syms.TFPointer) OR (tForm = Syms.TFAddress) OR
             ((tForm = Syms.TFProc) & tFar);
  isByte  := (tForm = Syms.TFChar) OR (tForm = Syms.TFByte) OR (tForm = Syms.TFBoolean);
  isLong  := tForm = Syms.TFLongint;
  isReal  := tForm = Syms.TFReal;
  isLreal := tForm = Syms.TFLongreal;
  isNil   := tForm = Syms.TFNiltype;
  isAddr  := tForm = Syms.TFAddress;

  IF item.mode = MFreg THEN RETURN END;

  IF item.mode = MConst THEN
    IF isReal OR isLreal THEN
      IF isReal THEN CgFldRealConst(WORD(item.adr))
      ELSE CgFldLongrealConst(WORD(item.adr))
      END;
      item.mode := MFreg; RETURN
    ELSIF isLong THEN
      CgLoadLongImm(item.val)
    ELSE
      CgLoadImm(INTEGER(item.val));
      IF isPtr OR isNil THEN
        Emit2(033H, 0D2H)  (* XOR DX,DX *)
      END
    END
  ELSIF item.mode = MLocal THEN
    IF isReal THEN
      CgFldRealBp(item.adr); item.mode := MFreg; RETURN
    ELSIF isLreal THEN
      CgFldLongrealBp(item.adr); item.mode := MFreg; RETURN
    ELSIF item.isRef & isAddr THEN
      (* Typeless VAR param: its slot holds a far address and its *value* IS that
         address — load the 4-byte slot directly, do NOT dereference. *)
      CgLoadPtrBp(item.adr); item.isRef := FALSE
    ELSIF item.isRef THEN
      CgLesBxBp(item.adr);
      CgDerefFarSized(isByte, isLong, isPtr);
      item.isRef := FALSE
    ELSIF isPtr THEN CgLoadPtrBp(item.adr)
    ELSIF isLong THEN CgLoadLongBp(item.adr)
    ELSIF isByte THEN CgLoadByteBp(item.adr)
    ELSE CgLoadBp(item.adr)
    END
  ELSIF item.mode = MGlobal THEN
    IF isReal THEN
      CgFldRealMem(WORD(item.adr)); item.mode := MFreg; RETURN
    ELSIF isLreal THEN
      CgFldLongrealMem(WORD(item.adr)); item.mode := MFreg; RETURN
    ELSIF item.isRef & isAddr THEN
      (* Typeless VAR param: load the far-address slot directly, do NOT deref. *)
      CgLoadPtrMem(WORD(item.adr)); item.isRef := FALSE
    ELSIF item.isRef THEN
      CgLesBxMem(WORD(item.adr));
      CgDerefFarSized(isByte, isLong, isPtr);
      item.isRef := FALSE
    ELSIF isPtr THEN CgLoadPtrMem(WORD(item.adr))
    ELSIF isLong THEN CgLoadLongMem(WORD(item.adr))
    ELSIF isByte THEN CgLoadByteMem(WORD(item.adr))
    ELSE CgLoadMem(WORD(item.adr))
    END
  ELSIF item.mode = MReg THEN
    IF item.isRef THEN
      IF isReal THEN
        CgFldRealEsbx(); item.isRef := FALSE; item.mode := MFreg; RETURN
      ELSIF isLreal THEN
        CgFldLongrealEsbx(); item.isRef := FALSE; item.mode := MFreg; RETURN
      END;
      CgDerefFarSized(isByte, isLong, isPtr);
      item.isRef := FALSE
    END
  ELSIF item.mode = MProc THEN
    CgLoadCodeAddr(WORD(item.adr));
    IF item.isFar THEN
      Emit1(BYTE(OpPushCs));  (* PUSH CS *)
      Emit1(BYTE(OpPopDx))    (* POP DX *)
    END
  ELSIF item.mode = MImport THEN
    (* Imported FAR procedure as a value (e.g. SYSTEM.ADR(SYSTEM.Alloc)
       or PROCEDURE-typed assignment).  Linker patches both placeholder
       words against the import id at link time. *)
    CgLoadImportAddr(item.rdoffId)  (* DX:AX = far addr *)
  END;
  item.mode := MReg
END CgLoadItem;

PROCEDURE CgStoreItem*(VAR item: Item);
  VAR isPtr, isByte, isLong, isReal, isLreal: BOOLEAN;
      tForm: INTEGER; tFar: BOOLEAN;
BEGIN
  tForm := -1; tFar := FALSE;
  IF item.type # Syms.NoType THEN
    tForm := item.type.form; tFar := item.type.isFar
  END;
  isPtr   := (tForm = Syms.TFPointer) OR (tForm = Syms.TFAddress) OR
             ((tForm = Syms.TFProc) & tFar);
  isByte  := (tForm = Syms.TFChar) OR (tForm = Syms.TFByte) OR (tForm = Syms.TFBoolean);
  isLong  := tForm = Syms.TFLongint;
  isReal  := tForm = Syms.TFReal;
  isLreal := tForm = Syms.TFLongreal;

  IF item.mode = MLocal THEN
    IF isReal THEN CgFstpRealBp(item.adr); RETURN
    ELSIF isLreal THEN CgFstpLongrealBp(item.adr); RETURN
    ELSIF item.isRef THEN
      IF isLong OR isPtr THEN
        Emit1(052H); Emit1(BYTE(OpPushAx)); CgLesBxBp(item.adr);
        Emit1(BYTE(OpPopAx)); Emit1(05AH); CgStoreDerefFarLong()
      ELSE
        Emit1(BYTE(OpPushAx)); CgLesBxBp(item.adr); Emit1(BYTE(OpPopAx));
        IF isByte THEN CgStoreDerefFarByte() ELSE CgStoreDerefFar() END
      END
    ELSIF isPtr THEN CgStorePtrBp(item.adr)
    ELSIF isLong THEN CgStoreLongBp(item.adr)
    ELSIF isByte THEN CgStoreByteBp(item.adr)
    ELSE CgStoreBp(item.adr)
    END
  ELSIF item.mode = MGlobal THEN
    IF isReal THEN CgFstpRealMem(WORD(item.adr)); RETURN END;
    IF isLreal THEN CgFstpLongrealMem(WORD(item.adr)); RETURN END;
    IF item.isRef THEN
      IF isLong OR isPtr THEN
        Emit1(052H); Emit1(BYTE(OpPushAx)); CgLesBxMem(WORD(item.adr));
        Emit1(BYTE(OpPopAx)); Emit1(05AH); CgStoreDerefFarLong()
      ELSE
        Emit1(BYTE(OpPushAx)); CgLesBxMem(WORD(item.adr)); Emit1(BYTE(OpPopAx));
        IF isByte THEN CgStoreDerefFarByte() ELSE CgStoreDerefFar() END
      END
    ELSIF isPtr THEN CgStorePtrMem(WORD(item.adr))
    ELSIF isLong THEN CgStoreLongMem(WORD(item.adr))
    ELSIF isByte THEN CgStoreByteMem(WORD(item.adr))
    ELSE CgStoreMem(WORD(item.adr))
    END
  ELSIF item.mode = MReg THEN
    IF item.isRef THEN
      IF isReal THEN CgFstpRealEsbx(); RETURN END;
      IF isLreal THEN CgFstpLongrealEsbx(); RETURN END;
      CgStoreDerefFarSized(isByte, isLong, isPtr)
    END
  END
END CgStoreItem;

END Cgen.
