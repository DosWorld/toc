(*D+*)
MODULE Tar;
(*
  ustar archive module: read/write .om archives.
  All .om archives use standard ustar format with 512-byte header blocks.
*)
IMPORT Files, Strings, LogErr;

TYPE
  HdrBuf = ARRAY 512 OF BYTE;

  (* Callback for ScanTar: called for each .rdf member found. *)
  MemberProc* = PROCEDURE(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT);

(* Tar cannot abort the process (the only SYSTEM.Halt lives in TOC.Run).  All
   errors latch in module LogErr (LogErr.Error/Error2); the caller checks
   LogErr.HaveErr() at a boundary. *)

(* Return index of first char after last '/' or '\' in s, or 0 if none.
   Parameters: s — a path string.
   Result: 0-based index where the basename starts within s. *)
PROCEDURE BasenameStart*(s: ARRAY OF CHAR): INTEGER;
  VAR i, last: INTEGER;
BEGIN
  i := 0; last := 0;
  WHILE s[i] # 0X DO
    IF (s[i] = "/") OR (s[i] = "\") OR (s[i] = ":") THEN last := i + 1 END;
    INC(i)
  END;
  RETURN last
END BasenameStart;

PROCEDURE ParseOctal(VAR hdr: HdrBuf; offset, width: INTEGER): LONGINT;
  VAR i: INTEGER; res: LONGINT;
BEGIN
  res := LONGINT(0);
  i := offset;
  (* some tar writers pad octal fields with leading spaces; skip them so the
     digit scan below isn't short-circuited by the very first byte. *)
  WHILE (i < offset + width) & (hdr[i] = BYTE(ORD(" "))) DO INC(i) END;
  WHILE i < offset + width DO
    IF (hdr[i] >= BYTE(ORD("0"))) & (hdr[i] <= BYTE(ORD("7"))) THEN
      res := res * LONGINT(8) + LONGINT(INTEGER(hdr[i]) - ORD("0"))
    ELSE
      i := offset + width
    END;
    INC(i)
  END;
  RETURN res
END ParseOctal;

PROCEDURE ReadHdrName(VAR hdr: HdrBuf; VAR name: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < 100) & (i < LEN(name) - 1) & (hdr[i] # BYTE(0)) DO
    name[i] := CHR(INTEGER(hdr[i]));
    INC(i)
  END;
  name[i] := 0X
END ReadHdrName;

(* ---- writer helpers ---- *)

PROCEDURE FillOctal(VAR hdr: HdrBuf; offset, width: INTEGER; val: LONGINT);
  VAR i: INTEGER;
BEGIN
  i := offset + width - 1;
  hdr[i] := BYTE(0);
  DEC(i);
  WHILE i >= offset DO
    hdr[i] := BYTE(ORD('0') + INTEGER(val MOD LONGINT(8)));
    val := val DIV LONGINT(8);
    DEC(i)
  END
END FillOctal;

PROCEDURE TarChecksum(VAR hdr: HdrBuf): LONGINT;
  VAR sum: LONGINT; i: INTEGER;
BEGIN
  sum := LONGINT(0);
  i := 0;
  WHILE i < 512 DO
    IF (i >= 148) & (i < 156) THEN INC(sum, LONGINT(20H))
    ELSE INC(sum, LONGINT(INTEGER(hdr[i])))
    END;
    INC(i)
  END;
  RETURN sum
END TarChecksum;

PROCEDURE SetStr(VAR hdr: HdrBuf; offset, maxLen: INTEGER; s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < maxLen - 1) & (s[i] # 0X) DO
    hdr[offset + i] := BYTE(ORD(s[i])); INC(i)
  END;
  hdr[offset + i] := BYTE(0)
END SetStr;

PROCEDURE WriteZeros(VAR f: Files.File; n: WORD);
  VAR hdr: ARRAY 512 OF BYTE;
BEGIN
  SYSTEM.FILL(hdr, 512, 0);
  Files.BlockWrite(f, hdr, n)
END WriteZeros;

PROCEDURE WriteTarHeader(VAR f: Files.File; VAR name: ARRAY OF CHAR; dataLen: LONGINT);
  VAR hdr: HdrBuf; csum: LONGINT;
BEGIN
  SYSTEM.FILL(hdr, 512, 0);
  SetStr(hdr, 0, 100, name);
  FillOctal(hdr, 100, 8, LONGINT(420));  (* mode 0644 *)
  FillOctal(hdr, 108, 8, LONGINT(0));
  FillOctal(hdr, 116, 8, LONGINT(0));
  FillOctal(hdr, 124, 12, dataLen);
  FillOctal(hdr, 136, 12, LONGINT(0));
  SYSTEM.FILL(hdr[148], 8, 32);
  hdr[156] := BYTE(ORD('0'));
  hdr[257] := BYTE(ORD('u')); hdr[258] := BYTE(ORD('s'));
  hdr[259] := BYTE(ORD('t')); hdr[260] := BYTE(ORD('a'));
  hdr[261] := BYTE(ORD('r')); hdr[262] := BYTE(0);
  hdr[263] := BYTE(ORD('0')); hdr[264] := BYTE(ORD('0'));
  csum := TarChecksum(hdr);
  IF csum >= LONGINT(2097152) THEN LogErr.Error("tar: checksum overflow") END;
  FillOctal(hdr, 148, 7, csum);
  hdr[155] := BYTE(ORD(' '));
  Files.BlockWrite(f, hdr, 512);
END WriteTarHeader;

(* ---- public writer procedures ---- *)

(* TarBegin*: no-op placeholder for archive-start bookkeeping (kept for
   symmetry with TarEnd; the ustar format needs no leading marker).
   Parameters: f — the archive file, opened for writing by the caller.
   Result: none. *)
PROCEDURE TarBegin*(VAR f: Files.File);
BEGIN
END TarBegin;

(* TarAddFile*: append one member to the archive from an in-memory buffer,
   writing its 512-byte ustar header followed by the data and zero-padding
   to the next 512-byte boundary.
   Parameters: f — the archive file, positioned at the append point; name —
   member name (path within the archive); data — buffer holding the member's
   content; len — number of bytes to write from data.
   Result: none. *)
PROCEDURE TarAddFile*(VAR f: Files.File; name: ARRAY OF CHAR;
                      VAR data: ARRAY OF BYTE; len: WORD);
  VAR pad : WORD;
BEGIN
  WriteTarHeader(f, name, len);
  Files.BlockWrite(f, data[0], len);
  pad := len MOD 512;
  IF pad # 0 THEN WriteZeros(f, 512 - pad) END
END TarAddFile;

(* TarAddFromFile*: append one member to the archive, streaming its content
   from another open file (via Files.BlockCopy) instead of an in-memory
   buffer — used to pack large .rdf/.def temp files without holding them
   fully in RAM.
   Parameters: f — the archive file, positioned at the append point; name —
   member name; src — source file to copy from, read from its current
   cursor position; dataLen — number of bytes to copy from src.
   Result: none. *)
PROCEDURE TarAddFromFile*(VAR f: Files.File; name: ARRAY OF CHAR;
                          VAR src: Files.File; dataLen: LONGINT);
  VAR pad: WORD;
BEGIN
  WriteTarHeader(f, name, dataLen);
  Files.BlockCopy(src, f, dataLen);
  pad := WORD(dataLen MOD 512);
  IF pad # 0 THEN WriteZeros(f, 512 - pad) END
END TarAddFromFile;

(* TarEnd*: write the two all-zero 512-byte blocks that mark end-of-archive
   in the ustar format.  Call once after the last TarAddFile/TarAddFromFile.
   Parameters: f — the archive file, positioned at the append point.
   Result: none. *)
PROCEDURE TarEnd*(VAR f: Files.File);
BEGIN
  WriteZeros(f, 512);
  WriteZeros(f, 512)
END TarEnd;

(* ---- public reader procedures ---- *)

(*
  Extract member 'memberName' (basename or full path, case-insensitive) from
  the ustar archive at 'libPath'.  Writes content to a temp file that is kept
  open and rewound to byte 0; 'out' is that open file.  Returns TRUE on success.
  The temp is delete-on-close, so the caller need only Files.Close(out) when
  done — its content lives only while the file is open (never reopened by name).
  Parameters: libPath — path of the archive to search; memberName — member
  to extract, matched case-insensitively against either its basename or its
  full in-archive path; out — receives the open, rewound temp file on success.
  Result: TRUE if the member was found and extracted.
*)
PROCEDURE TarExtract*(libPath: ARRAY OF CHAR; memberName: ARRAY OF CHAR;
                      VAR out: Files.File): BOOLEAN;
  VAR lib, tmp: Files.File;
      hdr: HdrBuf;
      fsize, padded: LONGINT;
      n, bnStart, i: INTEGER;
      name: ARRAY 100 OF CHAR;
      bn: ARRAY 100 OF CHAR;
      done: BOOLEAN;
BEGIN
  IF ~Files.Reset(lib, libPath) THEN RETURN FALSE END;
  done := FALSE;
  WHILE ~done DO
    n := Files.BlockRead(lib, hdr[0], 512);
    IF (n # 512) OR (hdr[0] = BYTE(0)) THEN
      done := TRUE
    ELSE
      fsize := ParseOctal(hdr, 124, 12);
      ReadHdrName(hdr, name);
      bnStart := BasenameStart(name);
      i := 0;
      WHILE (bnStart + i < 100) & (name[bnStart + i] # 0X) & (i < 99) DO
        bn[i] := name[bnStart + i]; INC(i)
      END;
      bn[i] := 0X;

      IF (Strings.EqualICase(bn, memberName) OR Strings.EqualICase(name, memberName)) &
         (fsize > LONGINT(0)) THEN
        IF ~Files.ReWriteTemp(tmp) THEN Files.Close(lib); RETURN FALSE END;
        Files.BlockCopy(lib, tmp, fsize);
        Files.Close(lib);
        Files.Seek(tmp, LONGINT(0));
        out := tmp;
        RETURN TRUE
      END;

      padded := ((fsize + LONGINT(511)) DIV LONGINT(512)) * LONGINT(512);
      IF padded > LONGINT(0) THEN
        Files.Seek(lib, Files.Position(lib) + padded)
      END
    END
  END;
  Files.Close(lib);
  RETURN FALSE
END TarExtract;

(*
  Scan the tar archive at 'archPath'.
  For every .rdf member calls onMember(name, libOfs, rawSize).
  libOfs is the byte offset of the RDOFF2 data (after the 512-byte header).
  If readStack is TRUE, parses META-INF/STACK.TXT and updates stackSize.
  Parameters: archPath — path of the archive to scan; onMember — callback
  invoked once per .rdf member found (or NIL to skip callbacks); stackSize —
  updated in place if readStack is TRUE and a valid META-INF/STACK.TXT value
  (2..65536) is found; readStack — whether to look for META-INF/STACK.TXT.
  Result: none.
*)
PROCEDURE ScanTar*(archPath: ARRAY OF CHAR; onMember: MemberProc;
                   VAR stackSize: LONGINT; readStack: BOOLEAN);
  VAR f: Files.File;
      hdr: HdrBuf;
      name: ARRAY 128 OF CHAR;
      modSize, padding: LONGINT;
      typeFlag: INTEGER;
      curPos, fsize: LONGINT;
      n, i: INTEGER;
      buf: ARRAY 33 OF CHAR;
      val: LONGINT;
      ok: BOOLEAN;
BEGIN
  IF ~Files.Reset(f, archPath) THEN LogErr.Error2("Cannot open: ", archPath); RETURN END;
  fsize := Files.Size(f);
  curPos := LONGINT(0);

  WHILE curPos + LONGINT(512) <= fsize DO
    Files.Seek(f, curPos);
    n := Files.BlockRead(f, hdr[0], 512);
    IF n < 512 THEN curPos := fsize
    ELSIF hdr[0] = BYTE(0) THEN curPos := fsize
    ELSE
      ReadHdrName(hdr, name);
      modSize  := ParseOctal(hdr, 124, 12);
      typeFlag := INTEGER(hdr[156]);

      IF (typeFlag = ORD("0")) OR (typeFlag = 0) THEN
        IF Strings.EndsWith(name, ".rdf", TRUE) THEN
          IF onMember # NIL THEN
            onMember(name, curPos + LONGINT(512), modSize)
          END
        ELSIF readStack & Strings.EqualICase(name, "META-INF/STACK.TXT") THEN
          n := INTEGER(modSize);
          IF n > LEN(buf) - 1 THEN n := LEN(buf) - 1 END;
          n := Files.BlockRead(f, buf[0], n);
          buf[n] := 0X;
          i := 0;
          WHILE (buf[i] = " ") OR (buf[i] = 09X) DO INC(i) END;
          ok := (buf[i] >= "0") & (buf[i] <= "9");
          IF ok THEN
            val := LONGINT(0);
            WHILE (buf[i] >= "0") & (buf[i] <= "9") DO
              val := val * LONGINT(10) + LONGINT(ORD(buf[i]) - ORD("0"));
              INC(i)
            END;
            IF (val >= LONGINT(2)) & (val <= LONGINT(65536)) THEN
              stackSize := val
            END
          END
        END
      END;

      padding := (modSize + LONGINT(511)) DIV LONGINT(512) * LONGINT(512);
      curPos := curPos + LONGINT(512) + padding
    END
  END;

  Files.Close(f)
END ScanTar;

(*
  Return TRUE if the file at 'path' is a ustar archive (checks magic at offset 257).
  Parameters: path — file to test.
  Result: TRUE if the file is at least 262 bytes and has the "ustar" magic
  at offset 257.
*)
PROCEDURE IsOmFile*(path: ARRAY OF CHAR): BOOLEAN;
  VAR f: Files.File;
      magic: ARRAY 6 OF CHAR;
      n: INTEGER;
      ok: BOOLEAN;
BEGIN
  ok := FALSE;
  IF Files.Reset(f, path) THEN
    IF Files.Size(f) > LONGINT(262) THEN
      Files.Seek(f, LONGINT(257));
      n := Files.BlockRead(f, magic[0], 5);
      magic[5] := 0X;
      IF (n = 5) &
         (magic[0] = "u") & (magic[1] = "s") & (magic[2] = "t") &
         (magic[3] = "a") & (magic[4] = "r") THEN
        ok := TRUE
      END
    END;
    Files.Close(f)
  END;
  RETURN ok
END IsOmFile;

(*
  Return the total number of members and their combined data size.
  Calls onMember for each member (any type, not just .rdf).
  Parameters: archPath — path of the archive to list; onMember — callback
  invoked once per member (name, data offset, data size), or NIL to skip
  callbacks.
  Result: none (member count/sizes are reported via onMember, not returned).
*)
PROCEDURE ListTar*(archPath: ARRAY OF CHAR; onMember: MemberProc);
  VAR f: Files.File;
      hdr: HdrBuf;
      name: ARRAY 128 OF CHAR;
      modSize, padding: LONGINT;
      curPos, fsize: LONGINT;
      n: INTEGER;
BEGIN
  IF ~Files.Reset(f, archPath) THEN LogErr.Error2("Cannot open: ", archPath); RETURN END;
  fsize := Files.Size(f);
  curPos := LONGINT(0);

  WHILE curPos + LONGINT(512) <= fsize DO
    Files.Seek(f, curPos);
    n := Files.BlockRead(f, hdr[0], 512);
    IF n < 512 THEN curPos := fsize
    ELSIF hdr[0] = BYTE(0) THEN curPos := fsize
    ELSE
      ReadHdrName(hdr, name);
      modSize := ParseOctal(hdr, 124, 12);
      IF onMember # NIL THEN
        onMember(name, curPos + LONGINT(512), modSize)
      END;
      padding := (modSize + LONGINT(511)) DIV LONGINT(512) * LONGINT(512);
      curPos := curPos + LONGINT(512) + padding
    END
  END;

  Files.Close(f);
END ListTar;

END Tar.
