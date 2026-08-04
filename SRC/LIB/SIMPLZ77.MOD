MODULE SimpLZ77;

(* Простой LZ77: окно 256 байт, длина ссылки от 3 до 255, смещение 1..256 *)
(* Формат сжатого потока:
   байт 0..1 : исходная длина (little-endian)
   затем повторяющиеся блоки:
     байт флагов (1 бит на элемент: 1=литерал, 0=ссылка)
     данные элементов: для литерала 1 байт, для ссылки 2 байта (offset-1, length-3) *)

PROCEDURE Encode*(VAR Src, Dst; len: WORD): WORD;
  VAR i, j, maxOff, off, k, bestLen, bestOff: INTEGER;
      blockFlag, bitVal, blockLen, dataPos: INTEGER;
      block: ARRAY 17 OF CHAR;  (* флаг + до 8 элементов по 2 байта *)
BEGIN
  IF len < 0 THEN len := 0 END;
  Dst[0] := CHR(len MOD 256);
  Dst[1] := CHR(len DIV 256);
  j := 2;
  i := 0;
  blockLen := 0; dataPos := 1; blockFlag := 0; bitVal := 1;

  WHILE i < len DO
    (* Если блок полон, записываем его *)
    IF blockLen = 8 THEN
      block[0] := CHR(blockFlag);
      FOR k := 0 TO dataPos-1 DO Dst[j] := block[k]; INC(j) END;
      blockLen := 0; dataPos := 1; blockFlag := 0; bitVal := 1
    END;

    (* Поиск наибольшего совпадения в окне i..i-1 *)
    maxOff := i;
    IF maxOff > 256 THEN maxOff := 256 END;
    bestLen := 0; bestOff := 0;
    FOR off := 1 TO maxOff DO
      k := 0;
      WHILE (i + k < len) & (k < 255) & (Src[i + k] = Src[i - off + k]) DO
        INC(k)
      END;
      IF k > bestLen THEN bestLen := k; bestOff := off END
    END;

    IF bestLen >= 3 THEN
      (* Ссылка: флаг = 0, записываем offset-1 и length-3 *)
      block[dataPos] := CHR(bestOff - 1); INC(dataPos);
      block[dataPos] := CHR(bestLen - 3); INC(dataPos);
      i := i + bestLen
    ELSE
      (* Литерал: флаг = 1, записываем сам байт *)
      blockFlag := blockFlag + bitVal;
      block[dataPos] := Src[i]; INC(dataPos);
      i := i + 1
    END;
    bitVal := bitVal * 2;
    INC(blockLen)
  END;

  (* Запись остатка блока *)
  IF blockLen > 0 THEN
    block[0] := CHR(blockFlag);
    FOR k := 0 TO dataPos-1 DO Dst[j] := block[k]; INC(j) END
  END;

  RETURN j
END Encode;

PROCEDURE Decode*(VAR Src, Dst; len: INTEGER): INTEGER;
  VAR outLen, i, j, flag, bit, off, length, pos: INTEGER;
      window: ARRAY 256 OF CHAR;
      wpos: INTEGER;
BEGIN
  IF len < 2 THEN Dst[0] := 0X; RETURN 0 END;
  outLen := ORD(Src[0]) + ORD(Src[1]) * 256;
  i := 2; j := 0; wpos := 0;

  WHILE j < outLen DO
    flag := ORD(Src[i]); INC(i);
    bit := 0;
    WHILE (bit < 8) & (j < outLen) DO
      IF (flag MOD 2) = 1 THEN
        (* литерал *)
        Dst[j] := Src[i]; INC(i);
        window[wpos] := Dst[j];
        INC(j); wpos := (wpos + 1) MOD 256
      ELSE
        (* ссылка *)
        off := ORD(Src[i]) + 1; INC(i);
        length := ORD(Src[i]) + 3; INC(i);
        WHILE length > 0 DO
          pos := (wpos - off) MOD 256;
          (* MOD в Oberon-07 для положительного делителя всегда >=0 *)
          Dst[j] := window[pos];
          window[wpos] := Dst[j];
          INC(j); wpos := (wpos + 1) MOD 256;
          pos := (pos + 1) MOD 256;
          DEC(length)
        END
      END;
      flag := flag DIV 2;
      INC(bit)
    END
  END;

  RETURN j
END Decode;

END SimpLZ77.
