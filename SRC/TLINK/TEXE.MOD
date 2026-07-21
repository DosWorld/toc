MODULE TExe;
(*
  TExe: MZ "tiny .EXE" writer for tlink.exe's /T=texe mode.
  Same contiguous code+data layout as a .COM (CalculateLayoutTiny with
  headerSize=0, no JMP stub) wrapped in a minimal MZ header instead of
  relying on DOS to build a PSP-relative .COM image:
    - CS=SS=-10H (one paragraph behind the load segment -> the PSP
      segment), so DS=CS=SS=PSP at runtime, same as a .COM.
    - IP = entry point offset directly (no JMP stub -- the header's own
      IP field is the entry point).
    - SP = 0FFFEH (fixed, top of the PSP segment).
    - No relocation table (tiny model has exactly one segment).
    - MinAlloc=MaxAlloc reserve the rest of the 64K PSP segment after
      the image, matching a .COM's implicit "own the whole segment".
*)
IMPORT Files, LogErr, Rdoff, Strings;

CONST HdrParas = 2;   (* CEIL(28 / 16): 28-byte header, no reloc table *)

PROCEDURE BaseName(path: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, start: INTEGER;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = "\") OR (path[i] = "/") OR (path[i] = ":") THEN start := i + 1 END;
    INC(i)
  END;
  Strings.Extract(path, start, i - start, dst)
END BaseName;

PROCEDURE UpcaseInPlace(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO s[i] := SYSTEM.UCASE(s[i]); INC(i) END
END UpcaseInPlace;

(* Write: emit a tiny-model MZ .EXE (header, no relocations, then the
   code buffer followed by the data buffer).
   Parameters: codeBuf/dataBuf — the two tiny-model buffers (independently
   0-based, exactly as WriteOutputTiny writes them for .COM/.SYS);
   totalCodeLen, totalDataLen, totalBssLen — layout sizes; entryIp —
   offset of `start` within codeBuf; outFileName — path to write.
   Result: none (failures latch via LogErr).

   CS=SS point at the PSP segment, but the code/data image itself
   physically loads at the load segment (PSP+0x10), i.e. byte offset
   0x100 relative to CS -- exactly the classic .COM CS:100h convention.
   So the header's IP must carry that same +0x100 bias; entryIp (an
   offset within codeBuf, i.e. relative to the load segment) is not
   itself CS-relative. *)
PROCEDURE Write*(codeBuf, dataBuf: Rdoff.SegBuf; totalCodeLen, totalDataLen, totalBssLen: LONGINT;
                  entryIp: INTEGER; outFileName: ARRAY OF CHAR);
  VAR fout: Files.File;
      imgLen, exeSize: LONGINT;
      pageCnt, partPage: WORD;
      minAlloc: WORD;
      summary, base: ARRAY 128 OF CHAR;
BEGIN
  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("texe: cannot write ", outFileName); RETURN END;

  imgLen := totalCodeLen + totalDataLen;
  exeSize := LONGINT(HdrParas) * LONGINT(16) + imgLen;
  pageCnt := WORD(exeSize DIV LONGINT(512));
  partPage := WORD(exeSize MOD LONGINT(512));
  IF partPage # 0 THEN INC(pageCnt) END;

  minAlloc := WORD((LONGINT(65536) - (imgLen + totalBssLen) + LONGINT(15)) DIV LONGINT(16));

  Files.WriteWord(fout, 5A4DH);          (* signature "MZ" *)
  Files.WriteWord(fout, INTEGER(partPage));
  Files.WriteWord(fout, INTEGER(pageCnt));
  Files.WriteWord(fout, 0);                  (* relocation count *)
  Files.WriteWord(fout, HdrParas);           (* header size, paragraphs *)
  Files.WriteWord(fout, INTEGER(minAlloc));  (* min alloc *)
  Files.WriteWord(fout, INTEGER(minAlloc));  (* max alloc *)
  Files.WriteWord(fout, 0FFF0H);             (* SS = -1 paragraph -> PSP segment *)
  Files.WriteWord(fout, 0FFFEH);             (* SP *)
  Files.WriteWord(fout, 0);                  (* checksum *)
  Files.WriteWord(fout, entryIp + 100H);     (* IP: CS-relative, +100H for the PSP-vs-load-segment bias *)
  Files.WriteWord(fout, 0FFF0H);             (* CS = -1 paragraph -> PSP segment *)
  Files.WriteWord(fout, 28);                 (* reloc table offset *)
  Files.WriteWord(fout, 0);                  (* overlay *)
  Files.WriteWord(fout, 0);                  (* pad: 28-byte header -> HdrParas*16 = 32 bytes *)
  Files.WriteWord(fout, 0);                  (* pad *)

  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("texe: write error (code)")
  END;
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("texe: write error (data)")
    END
  END;
  Files.Close(fout);

  BaseName(outFileName, base);
  UpcaseInPlace(base);
  Strings.Copy(base, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(totalBssLen,  summary);
  LogErr.Info(summary)
END Write;

END TExe.
