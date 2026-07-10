MODULE Forth;

IMPORT In, Out, Strings;

CONST
  MaxNameLen = 32;
  MaxDefLen  = 2048;
  MaxStack   = 1024;

TYPE
  ForthWord = POINTER TO WordDesc;
  WordProc = PROCEDURE (w: ForthWord);
  WordDesc = RECORD
    name:      ARRAY MaxNameLen OF CHAR;
    immediate: BOOLEAN;
    func:      WordProc;
    def:       ARRAY MaxDefLen OF CHAR;
    next:      ForthWord
  END;

VAR
  dict: ForthWord;
  stack: ARRAY MaxStack OF INTEGER;
  sp: INTEGER;
  compiling, expectingName: BOOLEAN;
  newWordName: ARRAY MaxNameLen OF CHAR;
  defBuffer:   ARRAY MaxDefLen OF CHAR;
  defLen: INTEGER;
  (* for main loop *)
  line: ARRAY 256 OF CHAR;
  i: INTEGER;
  token: ARRAY MaxNameLen OF CHAR;

(* ---------- Stack operations ---------- *)
PROCEDURE Push(v: INTEGER);
BEGIN
  IF sp >= MaxStack-1 THEN
    Out.String("Stack overflow"); Out.Ln; SYSTEM.Halt(1)
  END;
  INC(sp); stack[sp] := v
END Push;

PROCEDURE Pop(): INTEGER;
BEGIN
  IF sp < 0 THEN
    Out.String("Stack underflow"); Out.Ln; SYSTEM.Halt(1)
  END;
  DEC(sp); RETURN stack[sp+1]
END Pop;

(* ---------- Dictionary ---------- *)
PROCEDURE Find(name: ARRAY OF CHAR): ForthWord;
  VAR w: ForthWord;
BEGIN
  w := dict;
  WHILE w # NIL DO
    IF Strings.Equal(w.name, name) THEN RETURN w END;
    w := w.next
  END;
  RETURN NIL
END Find;

PROCEDURE AddWord(name: ARRAY OF CHAR; immediate: BOOLEAN;
                  func: WordProc; def: ARRAY OF CHAR);
  VAR w: ForthWord;
BEGIN
  NEW(w);
  Strings.Copy(name, w.name);
  w.immediate := immediate;
  w.func := func;
  IF def = "" THEN w.def[0] := 0X ELSE Strings.Copy(def, w.def) END;
  w.next := dict;
  dict := w
END AddWord;

PROCEDURE AppendToBuffer(tok: ARRAY OF CHAR);
  VAR j: INTEGER;
BEGIN
  IF defLen > 0 THEN
    IF defLen < MaxDefLen-1 THEN
      defBuffer[defLen] := " "; INC(defLen)
    END
  END;
  j := 0;
  WHILE (tok[j] # 0X) & (defLen < MaxDefLen-1) DO
    defBuffer[defLen] := tok[j]; INC(defLen); INC(j)
  END;
  defBuffer[defLen] := 0X
END AppendToBuffer;

(* ---------- Primitive words ---------- *)
PROCEDURE PrimDup(w: ForthWord);FAR;
  VAR a: INTEGER;
BEGIN a := Pop(); Push(a); Push(a)
END PrimDup;

PROCEDURE PrimDrop(w: ForthWord);FAR;
  VAR dummy: INTEGER;
BEGIN dummy := Pop()
END PrimDrop;

PROCEDURE PrimSwap(w: ForthWord);FAR;
  VAR a, b: INTEGER;
BEGIN a := Pop(); b := Pop(); Push(a); Push(b)
END PrimSwap;

PROCEDURE PrimOver(w: ForthWord);FAR;
  VAR a, b: INTEGER;
BEGIN a := Pop(); b := Pop(); Push(b); Push(a); Push(b)
END PrimOver;

PROCEDURE PrimPlus(w: ForthWord);FAR;
BEGIN Push(Pop() + Pop())
END PrimPlus;

PROCEDURE PrimMinus(w: ForthWord);FAR;
  VAR a, b: INTEGER;
BEGIN a := Pop(); b := Pop(); Push(b - a)
END PrimMinus;

PROCEDURE PrimMul(w: ForthWord);FAR;
BEGIN Push(Pop() * Pop())
END PrimMul;

PROCEDURE PrimDot(w: ForthWord);FAR;
BEGIN Out.Int(Pop(), 0); Out.Char(" ")
END PrimDot;

PROCEDURE PrimCr(w: ForthWord);FAR;
BEGIN Out.Ln
END PrimCr;

PROCEDURE PrimEmit(w: ForthWord);FAR;
BEGIN Out.Char(CHR(Pop()))
END PrimEmit;

PROCEDURE PrimKey(w: ForthWord);FAR;
  VAR ch: CHAR;
BEGIN In.Char(ch); Push(ORD(ch))
END PrimKey;

PROCEDURE Interpret(s: ARRAY OF CHAR); FORWARD;

PROCEDURE ColonExec(w: ForthWord);FAR;
BEGIN Interpret(w.def)
END ColonExec;

PROCEDURE PrimColon(w: ForthWord);FAR;
BEGIN
  IF compiling THEN
    Out.String("Nested definitions not allowed"); Out.Ln; RETURN
  END;
  compiling := TRUE; expectingName := TRUE;
  defBuffer[0] := 0X; defLen := 0
END PrimColon;

PROCEDURE PrimSemicolon(w: ForthWord);FAR;
BEGIN
  IF ~compiling THEN
    Out.String("';' outside a definition"); Out.Ln; RETURN
  END;
  IF expectingName THEN
    Out.String("No name given for definition"); Out.Ln;
    newWordName[0] := 0X; compiling := FALSE; RETURN
  END;
  IF defLen = 0 THEN
    Out.String("Empty definition"); Out.Ln;
    newWordName[0] := 0X; compiling := FALSE; RETURN
  END;
  AddWord(newWordName, FALSE, ColonExec, defBuffer);
  newWordName[0] := 0X; defBuffer[0] := 0X; defLen := 0;
  compiling := FALSE
END PrimSemicolon;

PROCEDURE IsInt(s: ARRAY OF CHAR): BOOLEAN;
  VAR i, len: INTEGER;
BEGIN
  len := 0; WHILE (s[len] # 0X) & (len < LEN(s)) DO INC(len) END;
  i := 0;
  IF s[0] = "-" THEN i := 1 END;
  IF i >= len THEN RETURN FALSE END;
  WHILE i < len DO
    IF (s[i] < "0") OR (s[i] > "9") THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END IsInt;

PROCEDURE StrToInt(s: ARRAY OF CHAR): INTEGER;
  VAR i, len, sign, val: INTEGER;
BEGIN
  len := 0; WHILE (s[len] # 0X) & (len < LEN(s)) DO INC(len) END;
  sign := 1; i := 0;
  IF s[0] = "-" THEN sign := -1; i := 1 END;
  val := 0;
  WHILE i < len DO
    val := val * 10 + (ORD(s[i]) - ORD("0"));
    INC(i)
  END;
  RETURN sign * val
END StrToInt;

PROCEDURE NextToken(s: ARRAY OF CHAR; VAR pos: INTEGER;
                    VAR token: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  i := pos;
  WHILE (i < LEN(s)) & (s[i] # 0X) & ((s[i] = " ") OR (s[i] = 9X)) DO
    INC(i)
  END;
  IF (i >= LEN(s)) OR (s[i] = 0X) THEN
    token[0] := 0X; pos := i; RETURN
  END;
  j := 0;
  WHILE (i < LEN(s)) & (s[i] # 0X) & (s[i] # " ") & (s[i] # 9X) DO
    token[j] := s[i]; INC(j); INC(i)
  END;
  token[j] := 0X;
  pos := i
END NextToken;

PROCEDURE ProcessToken(token: ARRAY OF CHAR);
  VAR w: ForthWord; val: INTEGER;
BEGIN
  IF compiling & expectingName THEN
    Strings.Copy(token, newWordName); expectingName := FALSE
  ELSE
    w := Find(token);
    IF w # NIL THEN
      IF compiling & ~w.immediate THEN
        AppendToBuffer(token)
      ELSE
        w.func(w)
      END
    ELSE
      IF IsInt(token) THEN
        val := StrToInt(token);
        IF compiling THEN AppendToBuffer(token) ELSE Push(val) END
      ELSE
        Out.String("Unknown word: "); Out.String(token); Out.Ln
      END
    END
  END
END ProcessToken;

PROCEDURE Interpret;
  VAR savedCompiling, savedExpecting: BOOLEAN;
      savedName: ARRAY MaxNameLen OF CHAR;
      savedDef: ARRAY MaxDefLen OF CHAR;
      savedLen, idx: INTEGER;
      tok: ARRAY MaxNameLen OF CHAR;
BEGIN
  savedCompiling := compiling; savedExpecting := expectingName;
  Strings.Copy(newWordName, savedName);
  Strings.Copy(defBuffer, savedDef);
  savedLen := defLen;
  compiling := FALSE; expectingName := FALSE;
  newWordName[0] := 0X; defBuffer[0] := 0X; defLen := 0;
  idx := 0;
  NextToken(s, idx, tok);
  WHILE tok[0] # 0X DO
    ProcessToken(tok);
    NextToken(s, idx, tok)
  END;
  compiling := savedCompiling; expectingName := savedExpecting;
  Strings.Copy(savedName, newWordName);
  Strings.Copy(savedDef, defBuffer);
  defLen := savedLen
END Interpret;

PROCEDURE Reset;
VAR
  d : ForthWord;
BEGIN
  WHILE dict # NIL DO
     d := dict;
     dict := dict^.next;
     DISPOSE(d);
  END;
  dict := NIL; sp := -1; compiling := FALSE; expectingName := FALSE;
  newWordName[0] := 0X; defBuffer[0] := 0X; defLen := 0;

  AddWord("dup",   FALSE, PrimDup,   "");
  AddWord("drop",  FALSE, PrimDrop,  "");
  AddWord("swap",  FALSE, PrimSwap,  "");
  AddWord("over",  FALSE, PrimOver,  "");
  AddWord("+",     FALSE, PrimPlus,  "");
  AddWord("-",     FALSE, PrimMinus, "");
  AddWord("*",     FALSE, PrimMul,   "");
  AddWord(".",     FALSE, PrimDot,   "");
  AddWord("cr",    FALSE, PrimCr,    "");
  AddWord("emit",  FALSE, PrimEmit,  "");
  AddWord("key",   FALSE, PrimKey,   "");
  AddWord(":",     FALSE, PrimColon, "");
  AddWord(";",     TRUE,  PrimSemicolon, "");
END Reset;

(* ---------- Main program ---------- *)
PROCEDURE Run*;
BEGIN
  Out.String("Minimal Forth"); Out.Ln;
  Reset;
  In.Open;
  WHILE TRUE DO
    Out.String("> ");
    In.String(line);
    IF ~In.Done THEN RETURN END;
    i := 0;
    NextToken(line, i, token);
    WHILE token[0] # 0X DO
      ProcessToken(token);
      NextToken(line, i, token)
    END
  END
END Run;

BEGIN
  dict := NIL;
END Forth.
