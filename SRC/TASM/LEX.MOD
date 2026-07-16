MODULE Lex;
(*
  Lexeme dictionary: maps mnemonic / register / directive names to small
  integer IDs, once, at the point an identifier token is recognized --
  every later dispatch point (Enc.Encode, Parse's directive/mnemonic
  routing) then switches on the integer ID via CASE instead of repeating
  Strings.Equal(name, "MOV") chains.

  ID space (disjoint ranges so a single CASE can dispatch across all three
  categories, or a caller can range-check "is this a register" etc.):
    0        = LNone      (not a recognized lexeme)
    1..49    = registers
    50..169  = mnemonics (widened from 50..149 during the v2 "full 8086
               coverage" plan's batch 4 -- the original 100-slot range
               filled up exactly at MAas=149)
    170..199 = directives (BITS/CPU/SECTION/GLOBAL/STRUC/... and DB/DW/TIMES)
    200..209 = keyword-like operand qualifiers (BYTE/WORD/FAR/SHORT/NEAR/SEG)

  Lookup uses the same "dispatch on first letter, then a short
  Strings.Equal chain" idiom as SRC/TOC/SCAN.MOD's LookupKeyword -- the
  common case (a label/identifier that is NOT a reserved word) rejects
  after one CHAR compare per bucket instead of scanning the whole table.
*)
IMPORT Strings;

CONST
  LNone* = 0;

  (* ---- registers (1..49) ---- *)
  RegAX* = 1; RegCX* = 2; RegDX* = 3; RegBX* = 4;
  RegSP* = 5; RegBP* = 6; RegSI* = 7; RegDI* = 8;
  RegAL* = 9; RegCL* = 10; RegDL* = 11; RegBL* = 12;
  RegAH* = 13; RegCH* = 14; RegDH* = 15; RegBH* = 16;
  RegES* = 17; RegCS* = 18; RegSS* = 19; RegDS* = 20;

  (* ---- mnemonics (50..169, non-contiguous -- see the §D block and
     MLoope*/MLoopnz* below, which extend the range past 149) ---- *)
  MMov* = 50; MPush* = 51; MPop* = 52; MLea* = 53; MLes* = 54; MXchg* = 55;
  MAdd* = 56; MSub* = 57; MAdc* = 58; MSbb* = 59; MAnd* = 60; MOr* = 61;
  MXor* = 62; MCmp* = 63; MTest* = 64;
  MNot* = 65; MNeg* = 66; MMul* = 67; MImul* = 122; MDiv* = 123; MIdiv* = 124;
  MInc* = 68; MDec* = 69;
  MShl* = 70; MShr* = 71; MRcl* = 72; MRcr* = 73;
  MRol* = 125; MRor* = 126; MSar* = 127; MSal* = 128;
  MInt* = 74; MInt3* = 75;
  MRet* = 76; MRetn* = 77; MRetf* = 78; MIret* = 79;
  MCld* = 80; MCli* = 81; MSti* = 82; MClc* = 83; MStc* = 84; MNop* = 85;
  MPushf* = 86; MPopf* = 87;
  MFninit* = 88; MFstcw* = 89; MFwait* = 90;
  MJmp* = 91; MCall* = 92; MLoop* = 93;
  MJe* = 94; MJz* = 95; MJne* = 96; MJnz* = 97;
  MJb* = 98; MJc* = 99; MJnae* = 100;
  MJae* = 101; MJnb* = 102; MJnc* = 103;
  MJbe* = 104; MJna* = 105; MJa* = 106; MJnbe* = 107;
  MJs* = 108; MJns* = 109;
  MMovsb* = 110; MMovsw* = 111; MScasb* = 112; MScasw* = 113;
  MCmpsb* = 114; MCmpsw* = 115; MIn* = 116; MOut* = 117;
  MLodsb* = 118; MLodsw* = 119; MStosb* = 120; MStosw* = 121;
  MJo* = 129; MJno* = 130; MJp* = 131; MJpe* = 132; MJnp* = 133; MJpo* = 134;
  MJl* = 135; MJnge* = 136; MJge* = 137; MJnl* = 138;
  MJle* = 139; MJng* = 140; MJg* = 141; MJnle* = 142;
  MCbw* = 143; MCwd* = 144; MHlt* = 145; MXlat* = 146; MInto* = 147;
  MAaa* = 148; MAas* = 149; MAam* = 150; MAad* = 151; MDaa* = 152; MDas* = 153;
  MLds* = 154;
  (* ---- §D 8086-coverage-gap additions ---- *)
  MCmc* = 155; MLahf* = 156; MSahf* = 157; MJcxz* = 158;
  MLoope* = 166; MLoopz* = 167; MLoopne* = 168; MLoopnz* = 169;

  (* ---- prefix pseudo-mnemonics (160..165 ONLY -- 166..169 are the
     LOOPcc mnemonics above, not prefixes) -- LOCK/REP* precede the real
     mnemonic as a separate leading token on the same source line (e.g.
     "rep movsb", "lock inc [x]"); Parse.MOD's ParseLine recognizes one via
     Lex.LookupMnem exactly like a real mnemonic, but instead of calling
     ParseInstruction directly it stashes the corresponding prefix byte
     (see Enc.PrefixByteFor) and re-dispatches on the next token.
     MPrefixLast is IsPrefixMnem's single authority for the top of this
     range -- extending the range means moving this constant, not just
     adding a new MRep* case, so the two can never drift apart again
     (S1 fix: the old comment claimed 160..169, which would have
     collided with MLoope*..MLoopnz* had anyone trusted it literally). *)
  MLock* = 160; MRep* = 161; MRepe* = 162; MRepz* = 163; MRepne* = 164; MRepnz* = 165;
  MPrefixLast* = MRepnz;

  (* ---- directives (170..199) ---- *)
  DBits* = 170; DCpu* = 171; DSection* = 172; DGlobal* = 173;
  DStruc* = 174; DEndstruc* = 175; DDb* = 176; DDw* = 177; DTimes* = 178;
  DResb* = 179; DResw* = 180; DResd* = 181;
  DExtern* = 185;

  (* ---- operand qualifiers (200..209) ---- *)
  QByte* = 200; QWord* = 201; QFar* = 202; QShort* = 203; QNear* = 204; QSeg* = 205;

(* LookupReg: name (already uppercased) -> Reg* id, or LNone. *)
PROCEDURE LookupReg*(name: ARRAY OF CHAR): INTEGER;
BEGIN
  CASE name[0] OF
    "A":
      IF    Strings.Equal(name, "AX") THEN RETURN RegAX
      ELSIF Strings.Equal(name, "AL") THEN RETURN RegAL
      ELSIF Strings.Equal(name, "AH") THEN RETURN RegAH
      END
  | "B":
      IF    Strings.Equal(name, "BX") THEN RETURN RegBX
      ELSIF Strings.Equal(name, "BP") THEN RETURN RegBP
      ELSIF Strings.Equal(name, "BL") THEN RETURN RegBL
      ELSIF Strings.Equal(name, "BH") THEN RETURN RegBH
      END
  | "C":
      IF    Strings.Equal(name, "CX") THEN RETURN RegCX
      ELSIF Strings.Equal(name, "CL") THEN RETURN RegCL
      ELSIF Strings.Equal(name, "CH") THEN RETURN RegCH
      ELSIF Strings.Equal(name, "CS") THEN RETURN RegCS
      END
  | "D":
      IF    Strings.Equal(name, "DX") THEN RETURN RegDX
      ELSIF Strings.Equal(name, "DI") THEN RETURN RegDI
      ELSIF Strings.Equal(name, "DL") THEN RETURN RegDL
      ELSIF Strings.Equal(name, "DH") THEN RETURN RegDH
      ELSIF Strings.Equal(name, "DS") THEN RETURN RegDS
      END
  | "S":
      IF    Strings.Equal(name, "SP") THEN RETURN RegSP
      ELSIF Strings.Equal(name, "SI") THEN RETURN RegSI
      ELSIF Strings.Equal(name, "SS") THEN RETURN RegSS
      END
  | "E":
      IF Strings.Equal(name, "ES") THEN RETURN RegES END
  ELSE
  END;
  RETURN LNone
END LookupReg;

(* IsByteReg / IsSegReg: classify an already-resolved register ID. *)
PROCEDURE IsByteReg*(r: INTEGER): BOOLEAN;
BEGIN RETURN (r >= RegAL) & (r <= RegBH)
END IsByteReg;

(* IsPrefixMnem: classify an already-resolved M* id as one of the
   LOCK/REP* leading-prefix pseudo-mnemonics (160..165, MLock..MPrefixLast)
   rather than a real instruction mnemonic. *)
PROCEDURE IsPrefixMnem*(m: INTEGER): BOOLEAN;
BEGIN RETURN (m >= MLock) & (m <= MPrefixLast)
END IsPrefixMnem;

PROCEDURE IsSegReg*(r: INTEGER): BOOLEAN;
BEGIN RETURN (r >= RegES) & (r <= RegDS)
END IsSegReg;

(* LookupMnem: name (already uppercased) -> M* id, or LNone.  Dispatch on
   first letter first (SRC/TOC/SCAN.MOD's LookupKeyword idiom): a plain
   label/identifier (the common case at the start of a source line)
   rejects after one CHAR compare per bucket. *)
PROCEDURE LookupMnem*(name: ARRAY OF CHAR): INTEGER;
BEGIN
  CASE name[0] OF
    "M":
      IF    Strings.Equal(name, "MOV")    THEN RETURN MMov
      ELSIF Strings.Equal(name, "MUL")    THEN RETURN MMul
      ELSIF Strings.Equal(name, "MOVSB")  THEN RETURN MMovsb
      ELSIF Strings.Equal(name, "MOVSW")  THEN RETURN MMovsw
      END
  | "P":
      IF    Strings.Equal(name, "PUSH")  THEN RETURN MPush
      ELSIF Strings.Equal(name, "POP")   THEN RETURN MPop
      ELSIF Strings.Equal(name, "PUSHF") THEN RETURN MPushf
      ELSIF Strings.Equal(name, "POPF")  THEN RETURN MPopf
      END
  | "L":
      IF    Strings.Equal(name, "LEA")    THEN RETURN MLea
      ELSIF Strings.Equal(name, "LES")    THEN RETURN MLes
      ELSIF Strings.Equal(name, "LDS")    THEN RETURN MLds
      ELSIF Strings.Equal(name, "LOOP")   THEN RETURN MLoop
      ELSIF Strings.Equal(name, "LODSB")  THEN RETURN MLodsb
      ELSIF Strings.Equal(name, "LODSW")  THEN RETURN MLodsw
      ELSIF Strings.Equal(name, "LOCK")   THEN RETURN MLock
      ELSIF Strings.Equal(name, "LAHF")   THEN RETURN MLahf
      ELSIF Strings.Equal(name, "LOOPE")  THEN RETURN MLoope
      ELSIF Strings.Equal(name, "LOOPZ")  THEN RETURN MLoopz
      ELSIF Strings.Equal(name, "LOOPNE") THEN RETURN MLoopne
      ELSIF Strings.Equal(name, "LOOPNZ") THEN RETURN MLoopnz
      END
  | "X":
      IF    Strings.Equal(name, "XCHG") THEN RETURN MXchg
      ELSIF Strings.Equal(name, "XOR")  THEN RETURN MXor
      ELSIF Strings.Equal(name, "XLAT") THEN RETURN MXlat
      ELSIF Strings.Equal(name, "XLATB") THEN RETURN MXlat  (* alias, D7 *)
      END
  | "A":
      IF    Strings.Equal(name, "ADD") THEN RETURN MAdd
      ELSIF Strings.Equal(name, "ADC") THEN RETURN MAdc
      ELSIF Strings.Equal(name, "AND") THEN RETURN MAnd
      ELSIF Strings.Equal(name, "AAA") THEN RETURN MAaa
      ELSIF Strings.Equal(name, "AAS") THEN RETURN MAas
      ELSIF Strings.Equal(name, "AAM") THEN RETURN MAam
      ELSIF Strings.Equal(name, "AAD") THEN RETURN MAad
      END
  | "S":
      IF    Strings.Equal(name, "SUB")    THEN RETURN MSub
      ELSIF Strings.Equal(name, "SBB")    THEN RETURN MSbb
      ELSIF Strings.Equal(name, "SHL")    THEN RETURN MShl
      ELSIF Strings.Equal(name, "SHR")    THEN RETURN MShr
      ELSIF Strings.Equal(name, "STI")    THEN RETURN MSti
      ELSIF Strings.Equal(name, "STC")    THEN RETURN MStc
      ELSIF Strings.Equal(name, "SCASB")  THEN RETURN MScasb
      ELSIF Strings.Equal(name, "SCASW")  THEN RETURN MScasw
      ELSIF Strings.Equal(name, "STOSB")  THEN RETURN MStosb
      ELSIF Strings.Equal(name, "STOSW")  THEN RETURN MStosw
      ELSIF Strings.Equal(name, "SAR")    THEN RETURN MSar
      ELSIF Strings.Equal(name, "SAL")    THEN RETURN MSal
      ELSIF Strings.Equal(name, "SAHF")   THEN RETURN MSahf
      END
  | "O":
      IF    Strings.Equal(name, "OR")  THEN RETURN MOr
      ELSIF Strings.Equal(name, "OUT") THEN RETURN MOut
      END
  | "C":
      IF    Strings.Equal(name, "CMP")    THEN RETURN MCmp
      ELSIF Strings.Equal(name, "CALL")   THEN RETURN MCall
      ELSIF Strings.Equal(name, "CLD")    THEN RETURN MCld
      ELSIF Strings.Equal(name, "CLI")    THEN RETURN MCli
      ELSIF Strings.Equal(name, "CLC")    THEN RETURN MClc
      ELSIF Strings.Equal(name, "CMPSB")  THEN RETURN MCmpsb
      ELSIF Strings.Equal(name, "CMPSW")  THEN RETURN MCmpsw
      ELSIF Strings.Equal(name, "CBW")    THEN RETURN MCbw
      ELSIF Strings.Equal(name, "CWD")    THEN RETURN MCwd
      ELSIF Strings.Equal(name, "CMC")    THEN RETURN MCmc
      END
  | "T":
      IF Strings.Equal(name, "TEST") THEN RETURN MTest END
  | "N":
      IF    Strings.Equal(name, "NOT") THEN RETURN MNot
      ELSIF Strings.Equal(name, "NEG") THEN RETURN MNeg
      ELSIF Strings.Equal(name, "NOP") THEN RETURN MNop
      END
  | "I":
      IF    Strings.Equal(name, "INC")  THEN RETURN MInc
      ELSIF Strings.Equal(name, "INT")  THEN RETURN MInt
      ELSIF Strings.Equal(name, "INT3") THEN RETURN MInt3
      ELSIF Strings.Equal(name, "IRET") THEN RETURN MIret
      ELSIF Strings.Equal(name, "IN")   THEN RETURN MIn
      ELSIF Strings.Equal(name, "IMUL") THEN RETURN MImul
      ELSIF Strings.Equal(name, "IDIV") THEN RETURN MIdiv
      ELSIF Strings.Equal(name, "INTO") THEN RETURN MInto
      END
  | "D":
      IF    Strings.Equal(name, "DEC") THEN RETURN MDec
      ELSIF Strings.Equal(name, "DIV") THEN RETURN MDiv
      ELSIF Strings.Equal(name, "DAA") THEN RETURN MDaa
      ELSIF Strings.Equal(name, "DAS") THEN RETURN MDas
      END
  | "R":
      IF    Strings.Equal(name, "RCL")   THEN RETURN MRcl
      ELSIF Strings.Equal(name, "RCR")   THEN RETURN MRcr
      ELSIF Strings.Equal(name, "RET")   THEN RETURN MRet
      ELSIF Strings.Equal(name, "RETN")  THEN RETURN MRetn
      ELSIF Strings.Equal(name, "RETF")  THEN RETURN MRetf
      ELSIF Strings.Equal(name, "ROL")   THEN RETURN MRol
      ELSIF Strings.Equal(name, "ROR")   THEN RETURN MRor
      ELSIF Strings.Equal(name, "REP")   THEN RETURN MRep
      ELSIF Strings.Equal(name, "REPE")  THEN RETURN MRepe
      ELSIF Strings.Equal(name, "REPZ")  THEN RETURN MRepz
      ELSIF Strings.Equal(name, "REPNE") THEN RETURN MRepne
      ELSIF Strings.Equal(name, "REPNZ") THEN RETURN MRepnz
      END
  | "J":
      IF    Strings.Equal(name, "JMP")  THEN RETURN MJmp
      ELSIF Strings.Equal(name, "JE")   THEN RETURN MJe
      ELSIF Strings.Equal(name, "JZ")   THEN RETURN MJz
      ELSIF Strings.Equal(name, "JNE")  THEN RETURN MJne
      ELSIF Strings.Equal(name, "JNZ")  THEN RETURN MJnz
      ELSIF Strings.Equal(name, "JB")   THEN RETURN MJb
      ELSIF Strings.Equal(name, "JC")   THEN RETURN MJc
      ELSIF Strings.Equal(name, "JNAE") THEN RETURN MJnae
      ELSIF Strings.Equal(name, "JAE")  THEN RETURN MJae
      ELSIF Strings.Equal(name, "JNB")  THEN RETURN MJnb
      ELSIF Strings.Equal(name, "JNC")  THEN RETURN MJnc
      ELSIF Strings.Equal(name, "JBE")  THEN RETURN MJbe
      ELSIF Strings.Equal(name, "JNA")  THEN RETURN MJna
      ELSIF Strings.Equal(name, "JA")   THEN RETURN MJa
      ELSIF Strings.Equal(name, "JNBE") THEN RETURN MJnbe
      ELSIF Strings.Equal(name, "JS")   THEN RETURN MJs
      ELSIF Strings.Equal(name, "JNS")  THEN RETURN MJns
      ELSIF Strings.Equal(name, "JO")   THEN RETURN MJo
      ELSIF Strings.Equal(name, "JNO")  THEN RETURN MJno
      ELSIF Strings.Equal(name, "JP")   THEN RETURN MJp
      ELSIF Strings.Equal(name, "JPE")  THEN RETURN MJpe
      ELSIF Strings.Equal(name, "JNP")  THEN RETURN MJnp
      ELSIF Strings.Equal(name, "JPO")  THEN RETURN MJpo
      ELSIF Strings.Equal(name, "JL")   THEN RETURN MJl
      ELSIF Strings.Equal(name, "JNGE") THEN RETURN MJnge
      ELSIF Strings.Equal(name, "JGE")  THEN RETURN MJge
      ELSIF Strings.Equal(name, "JNL")  THEN RETURN MJnl
      ELSIF Strings.Equal(name, "JLE")  THEN RETURN MJle
      ELSIF Strings.Equal(name, "JNG")  THEN RETURN MJng
      ELSIF Strings.Equal(name, "JG")   THEN RETURN MJg
      ELSIF Strings.Equal(name, "JNLE") THEN RETURN MJnle
      ELSIF Strings.Equal(name, "JCXZ") THEN RETURN MJcxz
      END
  | "F":
      IF    Strings.Equal(name, "FNINIT") THEN RETURN MFninit
      ELSIF Strings.Equal(name, "FSTCW")  THEN RETURN MFstcw
      ELSIF Strings.Equal(name, "FWAIT")  THEN RETURN MFwait
      END
  | "H":
      IF Strings.Equal(name, "HLT") THEN RETURN MHlt END
  | "W":
      IF Strings.Equal(name, "WAIT") THEN RETURN MFwait END  (* alias, 9B *)
  ELSE
  END;
  RETURN LNone
END LookupMnem;

(* LookupDirective: name (already uppercased) -> D* id, or LNone. *)
PROCEDURE LookupDirective*(name: ARRAY OF CHAR): INTEGER;
BEGIN
  CASE name[0] OF
    "B": IF Strings.Equal(name, "BITS") THEN RETURN DBits END
  | "C": IF Strings.Equal(name, "CPU") THEN RETURN DCpu END
  | "S":
      IF    Strings.Equal(name, "SECTION")  THEN RETURN DSection
      ELSIF Strings.Equal(name, "STRUC")    THEN RETURN DStruc
      END
  | "G": IF Strings.Equal(name, "GLOBAL") THEN RETURN DGlobal END
  | "E":
      IF    Strings.Equal(name, "ENDSTRUC") THEN RETURN DEndstruc
      ELSIF Strings.Equal(name, "EXTERN")   THEN RETURN DExtern
      END
  | "I": IF Strings.Equal(name, "IMPORT") THEN RETURN DExtern END  (* IMPORT is a TASM-added synonym for NASM's EXTERN *)
  | "D":
      IF    Strings.Equal(name, "DB") THEN RETURN DDb
      ELSIF Strings.Equal(name, "DW") THEN RETURN DDw
      END
  | "T": IF Strings.Equal(name, "TIMES") THEN RETURN DTimes END
  | "R":
      IF    Strings.Equal(name, "RESB") THEN RETURN DResb
      ELSIF Strings.Equal(name, "RESW") THEN RETURN DResw
      ELSIF Strings.Equal(name, "RESD") THEN RETURN DResd
      END
  ELSE
  END;
  RETURN LNone
END LookupDirective;

(* LookupQualifier: name (already uppercased) -> Q* id, or LNone. *)
PROCEDURE LookupQualifier*(name: ARRAY OF CHAR): INTEGER;
BEGIN
  CASE name[0] OF
    "B": IF Strings.Equal(name, "BYTE") THEN RETURN QByte END
  | "W": IF Strings.Equal(name, "WORD") THEN RETURN QWord END
  | "F": IF Strings.Equal(name, "FAR") THEN RETURN QFar END
  | "S":
      IF    Strings.Equal(name, "SHORT") THEN RETURN QShort
      ELSIF Strings.Equal(name, "SEG")   THEN RETURN QSeg
      END
  | "N": IF Strings.Equal(name, "NEAR") THEN RETURN QNear END
  ELSE
  END;
  RETURN LNone
END LookupQualifier;

END Lex.
