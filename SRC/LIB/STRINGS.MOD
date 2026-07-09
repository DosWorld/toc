(*$R-,D-*)
MODULE Strings;

PROCEDURE Length*(s: ARRAY OF CHAR): INTEGER;
BEGIN
  RETURN SYSTEM.LENGTH(s)
END Length;

PROCEDURE NearLength(s: ARRAY OF CHAR): INTEGER; NEAR;
BEGIN
  RETURN SYSTEM.LENGTH(s)
END NearLength;

PROCEDURE Pos*(pat, s: ARRAY OF CHAR; pos: INTEGER): INTEGER;
VAR i, j, lp, ls: INTEGER; found: BOOLEAN;
BEGIN
  lp := NearLength(pat);
  ls := NearLength(s);
  IF lp = 0 THEN RETURN pos END;
  i := pos; found := FALSE;
  WHILE (i <= ls - lp) & ~found DO
    j := 0;
    WHILE (j < lp) & (s[i + j] = pat[j]) DO
      INC(j)
    END;
    IF j = lp THEN found := TRUE ELSE INC(i) END
  END;
  IF found THEN RETURN i ELSE RETURN -1 END
END Pos;

PROCEDURE Append*(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
VAR dl, len: INTEGER;
BEGIN
  dl := NearLength(d);
  len := SYSTEM.MIN(NearLength(s) + 1, LEN(d) - 1 - dl);
  IF len > 0 THEN
    SYSTEM.MOVE(s[0], d[dl], len);
    d[dl + len - 1] := 0X
  END
END Append;

PROCEDURE Insert*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
VAR sl, dl, i, max: INTEGER;
BEGIN
  sl := NearLength(src);
  dl := NearLength(dst);
  max := LEN(dst) - 1;
  IF pos < 0 THEN pos := 0 END;
  IF pos > dl THEN pos := dl END;
  IF sl > 0 THEN
    i := dl;
    WHILE i >= pos DO
      IF i + sl <= max THEN
        dst[i + sl] := dst[i]
      END;
      DEC(i)
    END;
    i := 0;
    WHILE (i < sl) & (pos + i < max) DO
      dst[pos + i] := src[i];
      INC(i)
    END
  END
END Insert;

PROCEDURE Delete*(VAR s: ARRAY OF CHAR; pos, n: INTEGER);
VAR i, l: INTEGER;
BEGIN
  l := NearLength(s);
  IF pos < 0 THEN pos := 0 END;
  IF pos >= l THEN n := 0 END;
  IF pos + n > l THEN n := l - pos END;
  IF n > 0 THEN
    i := pos;
    WHILE i + n <= l DO
      s[i] := s[i + n];
      INC(i)
    END
  END
END Delete;

PROCEDURE Replace*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i, sl, dl: INTEGER;
BEGIN
  sl := NearLength(src);
  dl := NearLength(dst);
  IF pos < 0 THEN pos := 0 END;
  IF pos > dl THEN pos := dl END;
  i := 0;
  WHILE (i < sl) & (pos + i < LEN(dst) - 1) DO
    dst[pos + i] := src[i];
    INC(i)
  END;
  IF pos + i > dl THEN dst[pos + i] := 0X END
END Replace;

PROCEDURE Extract*(VAR src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR i, sl: INTEGER;
BEGIN
  sl := NearLength(src);
  IF pos < 0 THEN pos := 0 END;
  IF pos >= sl THEN n := 0 END;
  IF pos + n > sl THEN n := sl - pos END;
  i := 0;
  WHILE (i < n) & (i < LEN(dst) - 1) DO
    dst[i] := src[pos + i];
    INC(i)
  END;
  dst[i] := 0X
END Extract;

(* 16-bit name hash (h := h*43 + c over the chars; WORD wraps mod 65536).  Cheap
   pre-filter so a symbol-table scan rejects most candidates with a 2-byte compare
   and reads the full record only on a hash hit.  Implemented INLINE for speed:
   the open array is pushed {ofs, seg, len}; the pattern POPs it and scans ES:[DI]
   (avoids LODSB so the caller's DS is untouched), result in AX.  Verified
   byte-identical to the Oberon `h*43+c` reference for sample names.
     POP DI; POP ES; POP CX; MOV BX,0CBF0H
   .loop: JCXZ .done; MOV AL,ES:[DI]; OR AL,AL; JZ .done
          PUSH CX; MOV AH,0; PUSH AX; MOV AX,BX; MOV CX,43; MUL CX
          POP CX(char); ADD AX,CX; MOV BX,AX; POP CX(count); INC DI; DEC CX; JMP .loop
   .done: MOV AX,BX *)
PROCEDURE HashCode*(str: ARRAY OF CHAR): WORD;
  INLINE(05FH,007H,059H,0BBH,0F0H,0CBH,0E3H,01CH,026H,08AH,005H,008H,0C0H,074H,015H,
         051H,0B4H,000H,050H,089H,0D8H,0B9H,02BH,000H,0F7H,0E1H,059H,001H,0C8H,089H,0C3H,
         059H,047H,049H,0EBH,0E2H,089H,0D8H);

PROCEDURE EqCh(a, b: SYSTEM.ADDRESS; ICase: BOOLEAN): BOOLEAN; NEAR;
BEGIN
  IF ICase THEN
    RETURN SYSTEM.UCASE(a^) = SYSTEM.UCASE(b^)
  ELSE
    RETURN a^ = b^
  END
END EqCh;

PROCEDURE EqualCase(a, b: SYSTEM.ADDRESS; ICase: BOOLEAN): BOOLEAN; NEAR;
BEGIN
  WHILE EqCh(a, b, ICase) & (a^ # 0X) DO INC(a); INC(b) END;
  RETURN EqCh(a, b, ICase)
END EqualCase;

(* Case-sensitive Equal is the hot path (SymFind hash-hit confirm, keyword
   lookup, PredeclType, linker FindSymbol): two INLINE string ops, no per-char
   procedure call.  Comparing LENGTH(a)+1 bytes includes a's terminator, so a
   length mismatch always hits a terminator-vs-char difference first — REPE
   CMPSB stops there, never reading past the shorter string's buffer. *)
PROCEDURE Equal*(a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN SYSTEM.COMPARE(a[0], b[0], SYSTEM.LENGTH(a) + 1)
END Equal;

PROCEDURE EqualICase*(a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN EqualCase(SYSTEM.ADR(a[0]), SYSTEM.ADR(b[0]), TRUE)
END EqualICase;

PROCEDURE StartsWith*(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN;
VAR st, subs : SYSTEM.ADDRESS;
BEGIN
  st := SYSTEM.ADR(str[0]);
  subs := SYSTEM.ADR(substr[0]);
  WHILE subs^ # 0X DO
    IF (st^ = 0X) OR ~EqCh(st, subs, ICase) THEN RETURN FALSE END;
    INC(st);
    INC(subs);
  END;
  RETURN TRUE
END StartsWith;

PROCEDURE EndsWith*(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN;
VAR ls, lsub: INTEGER;
BEGIN
  ls := NearLength(str);
  lsub := NearLength(substr);
  IF lsub > ls THEN RETURN FALSE END;
  RETURN EqualCase(SYSTEM.ADR(str[ls-lsub]), SYSTEM.ADR(substr[0]), ICase)
END EndsWith;

PROCEDURE Copy*(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR len : INTEGER;
BEGIN
  len := SYSTEM.MIN(NearLength(src) + 1, LEN(dst) - 1);
  SYSTEM.MOVE(src[0], dst[0], len);
  dst[len] := 0X
END Copy;

PROCEDURE Str*(src : LONGINT; VAR dst : ARRAY OF CHAR);
  CONST MaxLen = 12;
  VAR buf : ARRAY MaxLen OF CHAR;
      i, j, len, digit : INTEGER;
      n : LONGINT;
      neg : BOOLEAN;
BEGIN
  i := MaxLen;
  n := src;

  IF n = 0 THEN
    DEC(i);
    buf[i] := '0';
  ELSE
    neg := n < 0;
    REPEAT
      DEC(i);
      digit := n MOD 10;
      IF digit < 0 THEN
        digit := -digit;
      END;
      buf[i] := CHR(ORD('0') + digit);
      n := n DIV 10;
    UNTIL n = 0;
    IF neg THEN
      DEC(i);
      buf[i] := '-';
    END;
  END;

  len := MaxLen - i;
  j := 0;
  WHILE (j < len) & (j < LEN(dst)) DO
    dst[j] := buf[i + j];
    INC(j);
  END;

  IF j < LEN(dst) THEN
    dst[j] := 0X;
  ELSE
    dst[LEN(dst) - 1] := 0X;
  END;
END Str;

PROCEDURE Val*(VAR s; VAR startFrom: WORD): LONGINT;
  VAR v: LONGINT; neg: BOOLEAN;
BEGIN
  WHILE (s^ <= " ") & (s^ # 0X) DO INC(s); INC(startFrom) END;
  neg := FALSE;
  IF s^ = '-' THEN neg := TRUE; INC(s); INC(startFrom) END;
  v := 0;
  WHILE SYSTEM.ISDIGIT(s^) DO
    v := v * 10 + LONGINT(ORD(s^) - ORD('0')); INC(s); INC(startFrom)
  END;
  WHILE (s^ <= " ") & (s^ # 0X) DO INC(s); INC(startFrom) END;
  IF neg THEN RETURN -v END;
  RETURN v
END Val;

PROCEDURE AppendInt*(val : LONGINT; VAR str : ARRAY OF CHAR);
VAR v   : ARRAY 16 OF CHAR;
BEGIN
  Str(val, v);
  Append(v, str);
END AppendInt;

PROCEDURE HexVal(v : BYTE) : CHAR;
BEGIN
  v := SYSTEM.AND(v, 0FH);
  IF v < 10 THEN RETURN CHR(ORD('0') + v)
  ELSE RETURN CHR(ORD('A') + v - 10)
  END
END HexVal;

PROCEDURE ByteToHexStr*(val : BYTE; VAR str : ARRAY OF CHAR);
BEGIN
  str[1] := HexVal(val);  val := SYSTEM.LSR(val, 4);
  str[0] := HexVal(val);
  str[2] := 0X;
END ByteToHexStr;

PROCEDURE WordToHexStr*(val : WORD; VAR str : ARRAY OF CHAR);
BEGIN
  str[3] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[2] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[1] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[0] := HexVal(BYTE(val));
  str[4] := 0X;
END WordToHexStr;

PROCEDURE AppendHexByte*(val : BYTE; VAR str : ARRAY OF CHAR);
VAR v   : ARRAY 3 OF CHAR;
BEGIN
  ByteToHexStr(val, v);
  Append(v, str);
END AppendHexByte;

PROCEDURE AppendHexWord*(val : WORD; VAR str : ARRAY OF CHAR);
VAR v   : ARRAY 5 OF CHAR;
BEGIN
  WordToHexStr(val, v);
  Append(v, str);
END AppendHexWord;

END Strings.
