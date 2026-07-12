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
    50..149  = mnemonics
    150..179 = directives (BITS/CPU/SECTION/GLOBAL/STRUC/... and DB/DW/TIMES)
    180..189 = keyword-like operand qualifiers (BYTE/WORD/FAR/SHORT/NEAR/SEG)

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

  (* ---- mnemonics (50..149) ---- *)
  MMov* = 50; MPush* = 51; MPop* = 52; MLea* = 53; MLes* = 54; MXchg* = 55;
  MAdd* = 56; MSub* = 57; MAdc* = 58; MSbb* = 59; MAnd* = 60; MOr* = 61;
  MXor* = 62; MCmp* = 63; MTest* = 64;
  MNot* = 65; MNeg* = 66; MMul* = 67; MImul* = 122; MDiv* = 123; MIdiv* = 124;
  MInc* = 68; MDec* = 69;
  MShl* = 70; MShr* = 71; MRcl* = 72; MRcr* = 73;
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

  (* ---- directives (150..179) ---- *)
  DBits* = 150; DCpu* = 151; DSection* = 152; DGlobal* = 153;
  DStruc* = 154; DEndstruc* = 155; DDb* = 156; DDw* = 157; DTimes* = 158;
  DResb* = 159; DResw* = 160; DResd* = 161; DEndStrucAlt* = 162;
  DText* = 163; DData* = 164; DExtern* = 165;

  (* ---- operand qualifiers (180..189) ---- *)
  QByte* = 180; QWord* = 181; QFar* = 182; QShort* = 183; QNear* = 184; QSeg* = 185;

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
      ELSIF Strings.Equal(name, "LOOP")   THEN RETURN MLoop
      ELSIF Strings.Equal(name, "LODSB")  THEN RETURN MLodsb
      ELSIF Strings.Equal(name, "LODSW")  THEN RETURN MLodsw
      END
  | "X":
      IF Strings.Equal(name, "XCHG") THEN RETURN MXchg
      ELSIF Strings.Equal(name, "XOR") THEN RETURN MXor
      END
  | "A":
      IF    Strings.Equal(name, "ADD") THEN RETURN MAdd
      ELSIF Strings.Equal(name, "ADC") THEN RETURN MAdc
      ELSIF Strings.Equal(name, "AND") THEN RETURN MAnd
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
      END
  | "D":
      IF    Strings.Equal(name, "DEC") THEN RETURN MDec
      ELSIF Strings.Equal(name, "DIV") THEN RETURN MDiv
      END
  | "R":
      IF    Strings.Equal(name, "RCL")  THEN RETURN MRcl
      ELSIF Strings.Equal(name, "RCR")  THEN RETURN MRcr
      ELSIF Strings.Equal(name, "RET")  THEN RETURN MRet
      ELSIF Strings.Equal(name, "RETN") THEN RETURN MRetn
      ELSIF Strings.Equal(name, "RETF") THEN RETURN MRetf
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
      END
  | "F":
      IF    Strings.Equal(name, "FNINIT") THEN RETURN MFninit
      ELSIF Strings.Equal(name, "FSTCW")  THEN RETURN MFstcw
      ELSIF Strings.Equal(name, "FWAIT")  THEN RETURN MFwait
      END
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
