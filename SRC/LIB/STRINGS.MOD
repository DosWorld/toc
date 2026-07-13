(*$R-,D-*)
MODULE Strings;

(* Length: compute the length of a NUL-terminated string.
   Parameters: s — the string to measure.
   Result: number of characters before the terminating 0X. *)
PROCEDURE Length*(s: ARRAY OF CHAR): INTEGER;
BEGIN
  RETURN SYSTEM.LENGTH(s)
END Length;

PROCEDURE NearLength(s: ARRAY OF CHAR): INTEGER; NEAR;
BEGIN
  RETURN SYSTEM.LENGTH(s)
END NearLength;

(* Pos: find the first occurrence of pat in s starting the scan at pos.
   Parameters: pat — substring to search for; s — string to search within;
   pos — 0-based index to start scanning from.
   Result: 0-based index of the first match, or -1 if not found. *)
PROCEDURE Pos*(pat, s: ARRAY OF CHAR; pos: INTEGER): INTEGER;
VAR i, j, lp, ls, r: INTEGER; found: BOOLEAN;
BEGIN
  lp := NearLength(pat);
  ls := NearLength(s);
  IF lp = 0 THEN RETURN pos END;
  IF lp = 1 THEN
    (* Single-char pattern: dispatch to the fast REPNE SCASB scan instead of
       the general double loop below. *)
    r := SYSTEM.FINDBYTE(s[pos], BYTE(pat[0]), WORD(ls - pos));
    IF r = WORD(ls - pos) THEN RETURN -1 ELSE RETURN pos + r END
  END;
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

(* Append: append s to the end of the NUL-terminated string d, truncating
   if d's buffer is too small.
   Parameters: s — string to append; d — destination string, modified in place. *)
PROCEDURE Append*(s: ARRAY OF CHAR; VAR d: ARRAY OF CHAR);
VAR dl, len: INTEGER;
BEGIN
  dl := NearLength(d);
  (* len = number of CHARACTERS to copy (excludes the NUL terminator,
     written separately below at d[dl+len] -- always in bounds since
     len <= LEN(d)-1-dl).  The previous formula folded the terminator into
     len's own MIN clamp (NearLength(s)+1 vs available room), which stole
     the last available character slot for a NUL when the destination had
     exactly 1 byte of room left, silently dropping the appended character
     entirely (e.g. an 8-char string in a 9-byte buffer appending a single
     space) -- found while porting SRC/TLINK's /N: device-name padding. *)
  len := SYSTEM.MIN(NearLength(s), LEN(d) - 1 - dl);
  IF len > 0 THEN
    SYSTEM.MOVE(s[0], d[dl], len);
    d[dl + len] := 0X
  END
END Append;

(* Insert: insert src into dst at position pos, shifting the existing tail
   right to make room (truncating if dst's buffer is too small).
   Parameters: src — string to insert; pos — 0-based insertion index (clamped
   to dst's current length); dst — destination string, modified in place. *)
PROCEDURE Insert*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
VAR sl, dl, i, max, tailLen: INTEGER;
BEGIN
  sl := NearLength(src);
  dl := NearLength(dst);
  max := LEN(dst) - 1;
  IF pos < 0 THEN pos := 0 END;
  IF pos > dl THEN pos := dl END;
  IF sl > 0 THEN
    (* Shift-right: dst (destination dst[pos+sl..]) is at a HIGHER address
       than src (dst[pos..]) and the ranges overlap — SYSTEM.MOVE's REP MOVSB
       always copies low-to-high, so a forward SYSTEM.MOVE here would read
       bytes AFTER they were already overwritten (silent corruption).  Must
       stay a manual backward (high-to-low) loop; only the final src-copy
       below (into the now-vacated gap) is safe to move in bulk. *)
    i := dl;
    WHILE i >= pos DO
      IF i + sl <= max THEN
        dst[i + sl] := dst[i]
      END;
      DEC(i)
    END;
    (* src is a VALUE param (by-value copy on entry) so it can never alias
       dst — a forward SYSTEM.MOVE into the gap is always safe here. *)
    tailLen := SYSTEM.MIN(sl, max - pos);
    IF tailLen > 0 THEN SYSTEM.MOVE(src[0], dst[pos], tailLen) END
  END
END Insert;

(* Delete: remove n characters from s starting at pos, shifting the tail left.
   Parameters: s — string to modify in place; pos — 0-based index of the first
   character to remove (clamped to s's length); n — number of characters to
   remove (clamped so it doesn't run past the end of s). *)
PROCEDURE Delete*(VAR s: ARRAY OF CHAR; pos, n: INTEGER);
VAR l, tailLen: INTEGER;
BEGIN
  l := NearLength(s);
  IF pos < 0 THEN pos := 0 END;
  IF pos >= l THEN n := 0 END;
  IF pos + n > l THEN n := l - pos END;
  IF n > 0 THEN
    (* Shift-left: dst (s[pos..]) is at a LOWER address than src (s[pos+n..]),
       so the ranges can overlap but a forward copy (SYSTEM.MOVE's REP MOVSB,
       low-to-high) never reads a byte after it has already been overwritten
       — safe, unlike Insert's shift-right below. Includes the terminating
       0X, so tailLen = l - (pos+n) + 1. *)
    tailLen := l - (pos + n) + 1;
    SYSTEM.MOVE(s[pos + n], s[pos], tailLen)
  END
END Delete;

(* Replace: overwrite dst starting at pos with the characters of src (does not
   shift the remaining tail; truncates if dst's buffer is too small).
   Parameters: src — replacement text; pos — 0-based index in dst to start
   overwriting (clamped to dst's current length); dst — destination string,
   modified in place. *)
PROCEDURE Replace*(src: ARRAY OF CHAR; pos: INTEGER; VAR dst: ARRAY OF CHAR);
VAR sl, dl, n: INTEGER;
BEGIN
  sl := NearLength(src);
  dl := NearLength(dst);
  IF pos < 0 THEN pos := 0 END;
  IF pos > dl THEN pos := dl END;
  (* src is a VALUE param (by-value copy on entry), so it can never alias
     dst — a forward SYSTEM.MOVE is always safe regardless of pos vs dl. *)
  n := SYSTEM.MIN(sl, LEN(dst) - 1 - pos);
  IF n > 0 THEN SYSTEM.MOVE(src[0], dst[pos], n) END;
  IF pos + n > dl THEN dst[pos + n] := 0X END
END Replace;

(* Extract: copy a substring of src into dst.
   Parameters: src — source string; pos — 0-based start index (clamped to
   src's length); n — number of characters to copy (clamped to src's length
   and dst's buffer size); dst — destination string, overwritten and
   NUL-terminated. *)
PROCEDURE Extract*(VAR src: ARRAY OF CHAR; pos, n: INTEGER; VAR dst: ARRAY OF CHAR);
VAR sl: INTEGER;
BEGIN
  sl := NearLength(src);
  IF pos < 0 THEN pos := 0 END;
  IF pos >= sl THEN n := 0 END;
  IF pos + n > sl THEN n := sl - pos END;
  (* dst is a separate array from src, so no overlap is possible — a plain
     forward SYSTEM.MOVE is always safe here. *)
  n := SYSTEM.MIN(n, LEN(dst) - 1);
  IF n > 0 THEN SYSTEM.MOVE(src[pos], dst[0], n) END;
  dst[n] := 0X
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
   .done: MOV AX,BX
   Parameters: str — string to hash.
   Result: 16-bit hash of str's characters. *)
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
   CMPSB stops there, never reading past the shorter string's buffer.
   Parameters: a, b — strings to compare.
   Result: TRUE if a and b are identical (case-sensitive). *)
PROCEDURE Equal*(a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN SYSTEM.COMPARE(a[0], b[0], SYSTEM.LENGTH(a) + 1)
END Equal;

(* EqualICase: compare two strings for equality, ignoring letter case.
   Parameters: a, b — strings to compare.
   Result: TRUE if a and b are identical when case is ignored. *)
PROCEDURE EqualICase*(a, b: ARRAY OF CHAR): BOOLEAN;
BEGIN
  RETURN EqualCase(SYSTEM.ADR(a[0]), SYSTEM.ADR(b[0]), TRUE)
END EqualICase;

(* StartsWith: test whether str begins with substr.
   Parameters: str — string to test; substr — prefix to look for; ICase —
   TRUE to ignore letter case during comparison.
   Result: TRUE if str starts with substr. *)
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

(* EndsWith: test whether str ends with substr.
   Parameters: str — string to test; substr — suffix to look for; ICase —
   TRUE to ignore letter case during comparison.
   Result: TRUE if str ends with substr. *)
PROCEDURE EndsWith*(VAR str: ARRAY OF CHAR; substr: ARRAY OF CHAR; ICase: BOOLEAN): BOOLEAN;
VAR ls, lsub: INTEGER;
BEGIN
  ls := NearLength(str);
  lsub := NearLength(substr);
  IF lsub > ls THEN RETURN FALSE END;
  RETURN EqualCase(SYSTEM.ADR(str[ls-lsub]), SYSTEM.ADR(substr[0]), ICase)
END EndsWith;

(* Copy: copy src into dst, truncating if dst's buffer is too small.
   Parameters: src — source string; dst — destination string, overwritten
   and NUL-terminated. *)
PROCEDURE Copy*(src: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR len : INTEGER;
BEGIN
  len := SYSTEM.MIN(NearLength(src) + 1, LEN(dst) - 1);
  SYSTEM.MOVE(src[0], dst[0], len);
  dst[len] := 0X
END Copy;

(* Str: convert a LONGINT to its decimal string representation.
   Parameters: src — value to convert; dst — destination string, overwritten
   and NUL-terminated (truncated if dst's buffer is too small). *)
PROCEDURE Str*(src : LONGINT; VAR dst : ARRAY OF CHAR);
  CONST MaxLen = 12; MinLong = -2147483647 - 1;
  VAR buf : ARRAY MaxLen OF CHAR;
      i, j, len, digit : INTEGER;
      n : LONGINT;
      neg : BOOLEAN;
BEGIN
  i := MaxLen;
  neg := src < 0;

  (* Work from the non-negative magnitude (negate up front) so the digit
     loop's termination (n = 0) and each digit's sign don't depend on
     whether DIV/MOD are truncating or floored -- both flavors agree once
     n >= 0.  MinLong can't be negated (overflows LONGINT), so peel its
     last digit off separately using its known decimal value. *)
  IF src = 0 THEN
    DEC(i);
    buf[i] := '0'
  ELSIF src = MinLong THEN
    DEC(i); buf[i] := '8';                (* ...2147483648, last digit 8 *)
    n := 214748364;
    WHILE n # 0 DO
      DEC(i);
      digit := n MOD 10;
      buf[i] := CHR(ORD('0') + digit);
      n := n DIV 10
    END;
    DEC(i); buf[i] := '-'
  ELSE
    IF neg THEN n := -src ELSE n := src END;
    REPEAT
      DEC(i);
      digit := n MOD 10;
      buf[i] := CHR(ORD('0') + digit);
      n := n DIV 10
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

(* Val: parse a decimal (optionally signed) integer from s, skipping leading
   and trailing whitespace.
   Parameters: s — character pointer to parse from; startFrom — updated by
   the number of characters consumed while scanning.
   Result: the parsed LONGINT value. *)
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

(* AppendInt: append the decimal representation of val to str.
   Parameters: val — value to convert and append; str — destination string,
   modified in place. *)
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

(* ByteToHexStr: format val as a 2-digit uppercase hexadecimal string.
   Parameters: val — byte to format; str — destination string, overwritten
   and NUL-terminated. *)
PROCEDURE ByteToHexStr*(val : BYTE; VAR str : ARRAY OF CHAR);
BEGIN
  str[1] := HexVal(val);  val := SYSTEM.LSR(val, 4);
  str[0] := HexVal(val);
  str[2] := 0X;
END ByteToHexStr;

(* WordToHexStr: format val as a 4-digit uppercase hexadecimal string.
   Parameters: val — word to format; str — destination string, overwritten
   and NUL-terminated. *)
PROCEDURE WordToHexStr*(val : WORD; VAR str : ARRAY OF CHAR);
BEGIN
  str[3] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[2] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[1] := HexVal(BYTE(val));  val := SYSTEM.LSR(val, 4);
  str[0] := HexVal(BYTE(val));
  str[4] := 0X;
END WordToHexStr;

(* AppendHexByte: append the 2-digit hexadecimal representation of val to str.
   Parameters: val — byte to convert and append; str — destination string,
   modified in place. *)
PROCEDURE AppendHexByte*(val : BYTE; VAR str : ARRAY OF CHAR);
VAR v   : ARRAY 3 OF CHAR;
BEGIN
  ByteToHexStr(val, v);
  Append(v, str);
END AppendHexByte;

(* AppendHexWord: append the 4-digit hexadecimal representation of val to str.
   Parameters: val — word to convert and append; str — destination string,
   modified in place. *)
PROCEDURE AppendHexWord*(val : WORD; VAR str : ARRAY OF CHAR);
VAR v   : ARRAY 5 OF CHAR;
BEGIN
  WordToHexStr(val, v);
  Append(v, str);
END AppendHexWord;

END Strings.
