MODULE Bin;
(*
  Raw binary blob writer, used by TLINK.MOD's /T=bin output mode.

  /T=bin is /T=com's tiny-model layout (single contiguous code+data+bss
  segment, no relocation table) minus DOS-specific assumptions: no JMP
  stub is ever generated (there is no "entry point" convention to jump
  to), no "start" entry symbol is required at all (SmartLink links every
  module given on the command line, not just what's reachable from an
  entry point), and the assumed load address used to resolve absolute
  in-image references is caller-supplied via /ORG= (default 0) instead
  of /T=com's hardcoded 0x100 PSP bias -- see TLINK.MOD's OnReloc.

  Write* just writes codeBuf/dataBuf verbatim, with no header of any
  kind -- the whole procedure exists (rather than reusing
  TLINK.MOD's WriteOutputTiny outright) to keep /T=bin's own file-format
  contract (a raw blob, nothing else, ever) explicit and independently
  testable, the same way BGI2.MOD owns /T=bgi2's.
*)
IMPORT Files, Strings, LogErr, Rdoff;

(* Write: write codeBuf[0..totalCodeLen) then dataBuf[0..totalDataLen)
   verbatim to outFileName -- no header, no JMP stub, no padding.
   Parameters: codeBuf, dataBuf — the linked flat code/data image;
   totalCodeLen, totalDataLen, totalBssLen — their lengths (totalBssLen is
   informational only, for the summary line: BSS carries no file bytes);
   outFileName — the output path.
   Result: none (failures latch via LogErr). *)
PROCEDURE Write*(codeBuf, dataBuf: Rdoff.SegBuf;
                 totalCodeLen, totalDataLen, totalBssLen: LONGINT;
                 outFileName: ARRAY OF CHAR);
  VAR fout: Files.File; summary, base: ARRAY 128 OF CHAR; i, start: INTEGER;
BEGIN
  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("tlink: cannot write ", outFileName); RETURN END;
  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("tlink: write error (code)")
  END;
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("tlink: write error (data)")
    END
  END;
  Files.Close(fout);

  start := 0; i := 0;
  WHILE outFileName[i] # 0X DO
    IF (outFileName[i] = "\") OR (outFileName[i] = "/") OR (outFileName[i] = ":") THEN start := i + 1 END;
    INC(i)
  END;
  Strings.Extract(outFileName, start, i - start, base);
  i := 0; WHILE base[i] # 0X DO base[i] := SYSTEM.UCASE(base[i]); INC(i) END;

  Strings.Copy(base, summary);
  Strings.Append(": Code=", summary); Strings.AppendInt(totalCodeLen, summary);
  Strings.Append(", Data=", summary); Strings.AppendInt(totalDataLen, summary);
  Strings.Append(", BSS=",  summary); Strings.AppendInt(totalBssLen,  summary);
  LogErr.Info(summary)
END Write;

END Bin.
