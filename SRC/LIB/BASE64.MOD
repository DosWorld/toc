MODULE Base64;

IMPORT Strings;

VAR
  DecodeTable : ARRAY 128 OF INTEGER;
  Alphabet    : ARRAY 64 OF CHAR;

PROCEDURE InitDecodeTable;
  VAR
      i: INTEGER;
BEGIN
  Strings.Copy("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", Alphabet);
  FOR i := 0 TO 127 DO DecodeTable[i] := -1 END;
  FOR i := 0 TO 63 DO DecodeTable[ORD(Alphabet[i])] := i END
END InitDecodeTable;

PROCEDURE Encode*(VAR Src, Dst; len: WORD): WORD;
  VAR i, j: WORD;
      b0, b1, b2: INTEGER;
BEGIN
  i := 0; j := 0;
  WHILE i < len DO
    b0 := ORD(Src^[i]); INC(i);
    b1 := -1;
    IF i < len THEN b1 := ORD(Src^[i]); INC(i) END;
    b2 := -1;
    IF i < len THEN b2 := ORD(Src^[i]); INC(i) END;

    Dst^[j] := Alphabet[b0 DIV 4]; INC(j);
    IF b1 >= 0 THEN
      Dst^[j] := Alphabet[(b0 MOD 4) * 16 + b1 DIV 16]; INC(j);
      IF b2 >= 0 THEN
        Dst^[j] := Alphabet[(b1 MOD 16) * 4 + b2 DIV 64]; INC(j);
        Dst^[j] := Alphabet[b2 MOD 64]; INC(j)
      ELSE
        Dst^[j] := Alphabet[(b1 MOD 16) * 4]; INC(j);
        Dst^[j] := "="; INC(j)
      END
    ELSE
      Dst^[j] := Alphabet[(b0 MOD 4) * 16]; INC(j);
      Dst^[j] := "="; INC(j);
      Dst^[j] := "="; INC(j)
    END
  END;
  Dst^[j] := 0X;
  RETURN j
END Encode;

PROCEDURE Decode*(VAR Src, Dst; len: INTEGER): INTEGER;
  VAR i, j, v0, v1, v2, v3, b0, b1, b2: INTEGER;
      ch: CHAR;
BEGIN
  i := 0; j := 0;
  WHILE i < len DO
    v0 := -1; v1 := -1; v2 := -1; v3 := -1;
    IF i < len THEN
      ch := Src^[i]; INC(i);
      IF ch = "=" THEN (* padding – skip *) ELSE v0 := DecodeTable[ORD(ch)] END
    END;
    IF i < len THEN
      ch := Src^[i]; INC(i);
      IF ch = "=" THEN ELSE v1 := DecodeTable[ORD(ch)] END
    END;
    IF i < len THEN
      ch := Src^[i]; INC(i);
      IF ch = "=" THEN ELSE v2 := DecodeTable[ORD(ch)] END
    END;
    IF i < len THEN
      ch := Src^[i]; INC(i);
      IF ch = "=" THEN ELSE v3 := DecodeTable[ORD(ch)] END
    END;

    IF (v0 >= 0) & (v1 >= 0) THEN
      b0 := v0 * 4 + v1 DIV 16;
      Dst^[j] := CHR(b0); INC(j);
      IF v2 >= 0 THEN
        b1 := (v1 MOD 16) * 16 + v2 DIV 4;
        Dst^[j] := CHR(b1); INC(j);
        IF v3 >= 0 THEN
          b2 := (v2 MOD 4) * 64 + v3;
          Dst^[j] := CHR(b2); INC(j)
        END
      END
    END
  END;
  RETURN j
END Decode;

BEGIN
  InitDecodeTable
END Base64.
