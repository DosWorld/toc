MODULE TOStrip;
(*
  tostrip — strip debug info from a linked .EXE or a compiler .OM archive.

  usage: tostrip FILE

  Format is detected from file content, not extension:
    - ustar archive (.om): the ".DBG" member (per-module TDbg info, always
      present, 0-byte when (*$D-*)) is rewritten with 0 bytes; every other
      member is copied through unchanged.  The rebuilt archive is assembled
      in an anonymous delete-on-close temp file (Files.ReWriteTemp); the
      original is then kept as FILE.BAK (extension replaced, not appended,
      to stay 8.3-valid — Files.Rename does not overwrite an existing
      destination, so any stale .BAK is removed first) and the temp's
      content is copied into the original's path before the temp closes.
    - MZ .exe: locates the Borland TDS/TDINFO v2.08 block (magic 0x52FB)
      appended after the MZ image (oc's `/G` link switch).  Before truncating,
      the original is copied to FILE.BAK (extension replaced; any stale .BAK
      is removed first), then the working file is truncated back to the
      pre-debug-info size.  If no block is found, the file is already
      stripped (or was never linked with /G) — this is a no-op, not an
      error, and no .BAK is made.

  All error/exit paths funnel through RunBody's result code; the single
  SYSTEM.Halt lives in Run.  Every opened file is closed on every path.
*)
IMPORT Out, Dos, Files, Strings, Tar, LogErr;

CONST
  ExitOk    = 0;
  ExitUsage = 2;
  ExitIo    = 3;

  Magic     = 052FBH;   (* on disk: bytes FB 52 -> little-endian word 0x52FB *)

  MembChunk = 32;

TYPE
  MembNode = POINTER TO MembNodeDesc;
  MembNodeDesc = RECORD
    name:  ARRAY MembChunk OF ARRAY 128 OF CHAR;
    ofs:   ARRAY MembChunk OF LONGINT;
    size:  ARRAY MembChunk OF LONGINT;
    count: INTEGER;
    next:  MembNode
  END;

VAR
  membHead, membTail: MembNode;

PROCEDURE Usage;
BEGIN
  Out.String("usage: tostrip FILE"); Out.Ln;
  Out.String("  Strip debug info from a linked .EXE (TDS/TDINFO block)"); Out.Ln;
  Out.String("  or a compiler .OM archive (zero the .DBG member)."); Out.Ln
END Usage;

PROCEDURE FreeList;
  VAR m, mn: MembNode;
BEGIN
  m := membHead;
  WHILE m # NIL DO mn := m^.next; DISPOSE(m); m := mn END;
  membHead := NIL; membTail := NIL
END FreeList;

(* Callbacks passed as proc-typed values to other modules must be FAR — see
   Link.mod's OnGlobal comment: Tar.MemberProc is declared FAR. *)
PROCEDURE OnMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
BEGIN
  IF (membTail = NIL) OR (membTail^.count = MembChunk) THEN
    NEW(membTail);
    IF membHead = NIL THEN membHead := membTail
    ELSE membHead^.next := membTail  (* only ever one node in practice; kept general *)
    END;
    membTail^.count := 0; membTail^.next := NIL
  END;
  Strings.Copy(name, membTail^.name[membTail^.count]);
  membTail^.ofs[membTail^.count]  := libOfs;
  membTail^.size[membTail^.count] := rawSize;
  INC(membTail^.count)
END OnMember;

(* UW: reinterpret a signed 16-bit word as unsigned 0..65535. *)
PROCEDURE UW(w: INTEGER): LONGINT;
BEGIN RETURN LONGINT(w) MOD LONGINT(65536)
END UW;

(* Locate the TDS/TDINFO block appended after the MZ image; TRUE + off on
   success.  Mirrors TDInfo.RunBody's locate logic. *)
PROCEDURE FindTdsBlock(VAR f: Files.File; fileSize: LONGINT; VAR off: LONGINT): BOOLEAN;
  VAR w: INTEGER; imgSize: LONGINT; found: BOOLEAN;
BEGIN
  found := FALSE; off := LONGINT(0);
  Files.Seek(f, LONGINT(0)); Files.ReadWord(f, w);
  IF w = 5A4DH THEN                                        (* "MZ" *)
    Files.ReadWord(f, w); imgSize := UW(w);                (* e_cblp *)
    IF imgSize = LONGINT(0) THEN imgSize := LONGINT(512) END;
    Files.ReadWord(f, w);                                  (* e_cp *)
    imgSize := (UW(w) - LONGINT(1)) * LONGINT(512) + imgSize;
    IF imgSize + LONGINT(2) <= fileSize THEN
      Files.Seek(f, imgSize); Files.ReadWord(f, w);
      IF w = Magic THEN found := TRUE; off := imgSize END
    END;
    IF ~found THEN                                         (* paragraph round-up *)
      imgSize := (imgSize + LONGINT(15)) DIV LONGINT(16) * LONGINT(16);
      IF imgSize + LONGINT(2) <= fileSize THEN
        Files.Seek(f, imgSize); Files.ReadWord(f, w);
        IF w = Magic THEN found := TRUE; off := imgSize END
      END
    END
  END;
  WHILE (~found) & (off < fileSize - LONGINT(1)) DO
    Files.Seek(f, off); Files.ReadWord(f, w);
    IF w = Magic THEN found := TRUE ELSE off := off + LONGINT(1) END
  END;
  RETURN found
END FindTdsBlock;

PROCEDURE StripExe(path: ARRAY OF CHAR): INTEGER;
  VAR f: Files.File; fileSize, off: LONGINT; rc: INTEGER;
      bakPath: ARRAY 128 OF CHAR;
BEGIN
  rc := ExitOk;
  IF ~Files.Reset(f, path) THEN
    LogErr.Error2("tostrip: cannot open ", path); RETURN ExitIo
  END;
  fileSize := Files.Size(f);
  IF FindTdsBlock(f, fileSize, off) THEN
    Files.Close(f);

    Files.ReplaceExt(path, ".BAK", bakPath);
    IF Files.FileExists(bakPath) THEN
      IF ~Files.Delete(bakPath) THEN
        LogErr.Error2("tostrip: cannot remove stale ", bakPath); RETURN ExitIo
      END
    END;
    IF ~Files.Copy(path, bakPath) THEN
      LogErr.Error2("tostrip: cannot back up ", path); RETURN ExitIo
    END;

    IF ~Files.Reset(f, path) THEN
      LogErr.Error2("tostrip: cannot reopen ", path); RETURN ExitIo
    END;
    Files.Seek(f, off);
    Files.Truncate(f);
    Files.Close(f);
    Out.String("tostrip: removed debug info at offset 0x"); Out.Int(off, 0);
    Out.String(" (original kept as "); Out.String(bakPath); Out.String(")"); Out.Ln
  ELSE
    Files.Close(f);
    Out.String("tostrip: no debug info found, nothing to strip"); Out.Ln
  END;
  RETURN rc
END StripExe;

PROCEDURE StripOm(path: ARRAY OF CHAR): INTEGER;
  VAR src, dst, empty, out: Files.File;
      bakPath: ARRAY 128 OF CHAR;
      m: MembNode; i: INTEGER;
      rc: INTEGER;
BEGIN
  rc := ExitOk;
  membHead := NIL; membTail := NIL;
  Tar.ListTar(path, OnMember);
  IF LogErr.HaveErr() THEN RETURN ExitIo END;

  Files.ReplaceExt(path, ".BAK", bakPath);

  IF ~Files.Reset(src, path) THEN
    LogErr.Error2("tostrip: cannot open ", path); FreeList; RETURN ExitIo
  END;
  IF ~Files.ReWriteTemp(dst) THEN
    LogErr.Error("tostrip: cannot create temp file");
    Files.Close(src); FreeList; RETURN ExitIo
  END;
  IF ~Files.ReWriteTemp(empty) THEN
    LogErr.Error("tostrip: cannot create temp file");
    Files.Close(src); Files.Close(dst); FreeList; RETURN ExitIo
  END;

  Tar.TarBegin(dst);
  m := membHead;
  WHILE m # NIL DO
    i := 0;
    WHILE i < m^.count DO
      IF Strings.EndsWith(m^.name[i], ".DBG", TRUE) THEN
        Tar.TarAddFromFile(dst, m^.name[i], empty, LONGINT(0))
      ELSE
        Files.Seek(src, m^.ofs[i]);
        Tar.TarAddFromFile(dst, m^.name[i], src, m^.size[i])
      END;
      INC(i)
    END;
    m := m^.next
  END;
  Tar.TarEnd(dst);

  Files.Close(empty);
  Files.Close(src);
  FreeList;

  IF LogErr.HaveErr() THEN
    Files.Close(dst); RETURN ExitIo
  END;

  IF Files.FileExists(bakPath) THEN
    IF ~Files.Delete(bakPath) THEN
      LogErr.Error2("tostrip: cannot remove stale ", bakPath); Files.Close(dst); RETURN ExitIo
    END
  END;
  IF ~Files.Rename(path, bakPath) THEN
    LogErr.Error2("tostrip: cannot back up ", path); Files.Close(dst); RETURN ExitIo
  END;

  Files.Seek(dst, LONGINT(0));
  IF ~Files.ReWrite(out, path) THEN
    LogErr.Error2("tostrip: cannot write ", path); Files.Close(dst); RETURN ExitIo
  END;
  IF ~Files.BlockCopy(dst, out, Files.Size(dst)) THEN
    LogErr.Error2("tostrip: short write to ", path); rc := ExitIo
  END;
  Files.Close(out);
  Files.Close(dst);

  IF rc = ExitOk THEN
    Out.String("tostrip: cleared .DBG member(s) in "); Out.String(path);
    Out.String(" (original kept as "); Out.String(bakPath); Out.String(")"); Out.Ln
  END;
  RETURN rc
END StripOm;

PROCEDURE RunBody(): INTEGER;
  VAR path: ARRAY 128 OF CHAR; rc: INTEGER;
BEGIN
  membHead := NIL; membTail := NIL;
  IF Dos.ParamCount() < 1 THEN Usage; RETURN ExitUsage END;
  Dos.ParamStr(1, path);
  IF ~Files.FileExists(path) THEN
    LogErr.Error2("tostrip: no such file: ", path); RETURN ExitIo
  END;
  IF Tar.IsOmFile(path) THEN
    rc := StripOm(path)
  ELSE
    rc := StripExe(path)
  END;
  RETURN rc
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  LogErr.Open;
  rc := RunBody();
  LogErr.Close;
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in tostrip *)
END Run;

BEGIN
  membHead := NIL; membTail := NIL
END TOStrip.
