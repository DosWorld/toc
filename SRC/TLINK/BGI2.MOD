MODULE Bgi2;
(*
  Borland BGI v2.0 graphics-driver file writer, used by TLINK.MOD's
  /T=bgi2 output mode.  Full format reference: DOCS/BGI.MD.

  Write* takes the already-linked flat code+data image (the SAME buffers
  TLINK.MOD's WriteOutputTiny writes verbatim for /T=com) and prepends the
  0xA0-byte v2.0 header: magic, banner+copyright text terminated by
  00,1A, two 10-byte header blocks (first at a variable offset right
  after 00,1A, second at the FIXED offset 0x80), then the driver name.
  There is no on-image JMP stub for BGI (unlike /T=com): the kernel
  always far-calls image offset 0 directly, and image+0x0C must be the
  'CB' signature, not a relocated jump target -- TLINK.MOD's
  CalculateLayoutTiny enforces that the module's "start" entry symbol
  sits at code offset 0 before ever calling Write here.
*)
IMPORT Files, Strings, LogErr, Rdoff;

CONST
  HeaderSize* = 0A0H;   (* v2.0 header size before the driver image *)
  Blk2Ofs     = 080H;   (* fixed offset of the SECOND header block *)
  BlkSize     = 10;     (* v2.0 header block size in bytes *)

(* PutWord: store a little-endian 16-bit value into hdr[i]. *)
PROCEDURE PutWord(VAR hdr: ARRAY OF BYTE; i: INTEGER; val: LONGINT);
BEGIN
  hdr[i]   := BYTE(SYSTEM.AND(val, 0FFH));
  hdr[i+1] := BYTE(SYSTEM.AND(SYSTEM.LSR(val, 8), 0FFH))
END PutWord;

(* WriteBlock: emit the 10-byte v2.0 header block at hdr[ofs]
   (DOCS/BGI.MD 3.2). *)
PROCEDURE WriteBlock(VAR hdr: ARRAY OF BYTE; ofs: INTEGER; codeSize: LONGINT);
BEGIN
  PutWord(hdr, ofs,   LONGINT(HeaderSize));  (* +0 headerSize *)
  PutWord(hdr, ofs+2, LONGINT(0));            (* +2 driverNum  *)
  PutWord(hdr, ofs+4, codeSize);              (* +4 codeSize   *)
  hdr[ofs+6] := 2;                             (* +6 version     *)
  hdr[ofs+7] := 0;                             (* +7 revision    *)
  hdr[ofs+8] := 1;                             (* +8 minVersion  *)
  hdr[ofs+9] := 0                              (* +9 minRevision *)
  (* v2.0 block is exactly 10 bytes -- the name follows immediately, no
     trailing pad (a v3.0 block would add dataOfs/dataSize at +10/+12). *)
END WriteBlock;

(* AppendStr: copy s (excluding its 0X terminator) into hdr at p,
   returning the new index. *)
PROCEDURE AppendStr(VAR hdr: ARRAY OF BYTE; p: INTEGER; s: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO hdr[p] := BYTE(ORD(s[i])); INC(p); INC(i) END;
  RETURN p
END AppendStr;

(* DriverName: basename of path with its directory prefix and extension
   stripped, upcased -- e.g. "c:\drv\cga4.bgi" -> "CGA4".  Used both as
   the header's driver-name field (DOCS/BGI.MD 3.1, offset 0x8A) and as
   the leading word of the banner text. *)
PROCEDURE DriverName(path: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR base: ARRAY 128 OF CHAR; i, start: INTEGER;
BEGIN
  start := 0; i := 0;
  WHILE path[i] # 0X DO
    IF (path[i] = "\") OR (path[i] = "/") OR (path[i] = ":") THEN start := i + 1 END;
    INC(i)
  END;
  Strings.Extract(path, start, i - start, base);
  Files.ReplaceExt(base, "", dst);
  i := 0;
  WHILE dst[i] # 0X DO dst[i] := SYSTEM.UCASE(dst[i]); INC(i) END
END DriverName;

(* Write: write a Borland BGI v2.0 graphics driver file to outFileName --
   the 0xA0-byte header (magic/banner/copyright/header-blocks/name)
   followed by codeBuf[0..totalCodeLen) and dataBuf[0..totalDataLen)
   verbatim.
   Parameters: codeBuf, dataBuf — the linked flat code/data image (same
   buffers TLINK.MOD's WriteOutputTiny writes for /T=com); totalCodeLen,
   totalDataLen — their lengths; outFileName — the .BGI path to write;
   descr — /D= value verbatim (may be empty; NOT prefixed with the driver
   name — that is added here), appended as "<NAME> BGI Device Driver -
   <descr>" (or just "<NAME> BGI Device Driver" when empty); copyr — /C=
   value verbatim (may be empty, in which case a generic public-domain
   notice is used).
   Result: none (failures latch via LogErr). *)
PROCEDURE Write*(codeBuf, dataBuf: Rdoff.SegBuf; totalCodeLen, totalDataLen: LONGINT;
                 outFileName, descr, copyr: ARRAY OF CHAR);
  VAR fout: Files.File;
      name: ARRAY 32 OF CHAR;
      banner, copyrLine: ARRAY 200 OF CHAR;
      hdr: ARRAY HeaderSize OF BYTE;
      i, p: INTEGER;
      codeSize: LONGINT;
      summary: ARRAY 128 OF CHAR;
BEGIN
  DriverName(outFileName, name);

  (* /D=text is appended as "<NAME> BGI Device Driver - <text>"; without
     it, just "<NAME> BGI Device Driver". *)
  Strings.Copy(" BGI Device Driver", banner);
  IF descr[0] # 0X THEN Strings.Append(" - ", banner); Strings.Append(descr, banner) END;

  IF copyr[0] # 0X THEN Strings.Copy(copyr, copyrLine)
  ELSE Strings.Copy("Public domain BGI driver (c) DosWorld 2026", copyrLine)
  END;

  codeSize := totalCodeLen + totalDataLen;

  (* The banner sits between offset 4 and the first header block, which
     must still fit (with its 10 bytes) below the fixed second block at
     0x80 -- reject rather than silently corrupt the header. *)
  IF 4 + INTEGER(SYSTEM.LENGTH(name)) + INTEGER(SYSTEM.LENGTH(banner)) + 2
       + INTEGER(SYSTEM.LENGTH(copyrLine)) + 2 + 2 + BlkSize > Blk2Ofs THEN
    LogErr.Error("tlink: /T=bgi2 description/copyright too long for the header"); RETURN
  END;

  i := 0; WHILE i < HeaderSize DO hdr[i] := 0; INC(i) END;

  (* v2.0 magic "pk",08,08 *)
  hdr[0] := BYTE(ORD("p")); hdr[1] := BYTE(ORD("k")); hdr[2] := 8; hdr[3] := 8;

  (* banner + copyright, terminated by 00,1A; the FIRST header block
     follows immediately after (variable offset) -- only the SECOND block
     sits at the fixed 0x80 (DOCS/BGI.MD 3.3). *)
  p := 4;
  p := AppendStr(hdr, p, name);
  p := AppendStr(hdr, p, banner);
  hdr[p] := 0DH; INC(p); hdr[p] := 0AH; INC(p);
  p := AppendStr(hdr, p, copyrLine);
  hdr[p] := 0DH; INC(p); hdr[p] := 0AH; INC(p);
  hdr[p] := 0; INC(p);       (* 00 *)
  hdr[p] := 1AH; INC(p);     (* 1A (EOF) *)

  WriteBlock(hdr, p, codeSize);
  INC(p, BlkSize);
  WHILE p < Blk2Ofs DO hdr[p] := 0; INC(p) END;

  (* second header block at the FIXED offset 0x80, then namelen + name
     immediately after (image+0x8A) -- no trailing pad inside the block. *)
  WriteBlock(hdr, Blk2Ofs, codeSize);
  p := Blk2Ofs + BlkSize;
  hdr[p] := BYTE(SYSTEM.LENGTH(name)); INC(p);
  p := AppendStr(hdr, p, name);

  IF ~Files.ReWrite(fout, outFileName) THEN LogErr.Error2("tlink: cannot write ", outFileName); RETURN END;
  IF Files.BlockWrite(fout, hdr, WORD(HeaderSize)) # WORD(HeaderSize) THEN
    LogErr.Error("tlink: write error (BGI header)")
  END;
  IF Files.BlockWrite(fout, codeBuf^[0], WORD(totalCodeLen)) # WORD(totalCodeLen) THEN
    LogErr.Error("tlink: write error (code)")
  END;
  IF totalDataLen > LONGINT(0) THEN
    IF Files.BlockWrite(fout, dataBuf^[0], WORD(totalDataLen)) # WORD(totalDataLen) THEN
      LogErr.Error("tlink: write error (data)")
    END
  END;
  Files.Close(fout);

  Strings.Copy(name, summary);
  Strings.Append(": Header=", summary); Strings.AppendInt(LONGINT(HeaderSize), summary);
  Strings.Append(", Image=", summary); Strings.AppendInt(codeSize, summary);
  LogErr.Info(summary)
END Write;

END Bgi2.
