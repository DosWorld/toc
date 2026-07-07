MODULE TOLib;
(*
  tolib — .OM archive manager for the Oberon toolchain.

  Commands:
    tolib list    FILE.OM              print member names and sizes
    tolib extract FILE.OM MEMBER [OUT] extract a member to a file
    tolib create  OUT.OM FILE ...      create archive from files
    tolib merge   OUT.OM IN.OM ...     merge archives into one

  Uses the shared Tar module for all archive I/O.
*)
IMPORT Dos, Files, IO, Err, Strings, Tar;

CONST
  MaxPath = 128;
  MaxArgs = 32;

VAR
  outRider: IO.Rider;

(* ---- list command ---- *)

VAR
  listCount: INTEGER;
  listTotal: LONGINT;

PROCEDURE OnListMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
BEGIN
  IO.WriteStr(outRider, name);
  IO.WriteStr(outRider, "  ");
  IO.WriteInt(outRider, rawSize);
  IO.WriteLn(outRider);
  INC(listCount);
  INC(listTotal, rawSize)
END OnListMember;

PROCEDURE CmdList(archPath: ARRAY OF CHAR): INTEGER;
BEGIN
  listCount := 0; listTotal := LONGINT(0);
  Tar.ListTar(archPath, OnListMember);
  IO.WriteStr(outRider, "--- ");
  IO.WriteInt(outRider, LONGINT(listCount));
  IO.WriteStr(outRider, " member(s), ");
  IO.WriteInt(outRider, listTotal);
  IO.WriteStr(outRider, " byte(s) total");
  IO.WriteLn(outRider);
  RETURN 0
END CmdList;

(* ---- extract command ---- *)

PROCEDURE CmdExtract(archPath, memberName, outPath: ARRAY OF CHAR): INTEGER;
  VAR tmp, fout: Files.File;
      buf: ARRAY 512 OF BYTE;
      n: INTEGER;
      ok: BOOLEAN;
BEGIN
  ok := Tar.TarExtract(archPath, memberName, tmp);
  IF ~ok THEN
    Err.Error2("olib: member not found: ", memberName);
    RETURN 1
  END;

  IF ~Files.ReWrite(fout, outPath) THEN
    Err.Error2("olib: cannot write: ", outPath);
    Files.Close(tmp);   (* TAR$$.TMP auto-deletes on close *)
    RETURN 1
  END;
  n := Files.BlockRead(tmp, buf[0], 512);
  WHILE n > 0 DO
    IF Files.BlockWrite(fout, buf[0], WORD(n)) # WORD(n) THEN
      Err.Error2("olib: write failed: ", outPath);
      Files.Close(fout); Files.Close(tmp);
      RETURN 1
    END;
    n := Files.BlockRead(tmp, buf[0], 512)
  END;
  Files.Close(fout);
  Files.Close(tmp);   (* TAR$$.TMP auto-deletes on close *)
  RETURN 0
END CmdExtract;

(* ---- create command ---- *)

PROCEDURE Upcase(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO s[i] := SYSTEM.UCASE(s[i]); INC(i) END
END Upcase;

PROCEDURE GetBasename(path: ARRAY OF CHAR; VAR name: ARRAY OF CHAR);
  VAR start, i: INTEGER;
BEGIN
  start := Tar.BasenameStart(path);
  i := 0;
  WHILE (start + i < LEN(path)) & (path[start + i] # 0X) & (i < LEN(name) - 1) DO
    name[i] := path[start + i]; INC(i)
  END;
  name[i] := 0X
END GetBasename;

PROCEDURE AddFileToArchive(VAR fout: Files.File; filePath: ARRAY OF CHAR): BOOLEAN;
  VAR fin: Files.File;
      name: ARRAY MaxPath OF CHAR;
      fsize: LONGINT;
BEGIN
  IF ~Files.Reset(fin, filePath) THEN
    Err.Error2("olib: cannot open: ", filePath);
    RETURN FALSE
  END;
  fsize := Files.Size(fin);
  GetBasename(filePath, name);
  Upcase(name);
  Tar.TarAddFromFile(fout, name, fin, fsize);
  Files.Close(fin);
  RETURN TRUE
END AddFileToArchive;

(* ---- merge command ---- *)

VAR
  mergeOut:     Files.File;
  mergeArchBuf: ARRAY MaxPath OF CHAR;

PROCEDURE OnMergeMember(name: ARRAY OF CHAR; libOfs, rawSize: LONGINT); FAR;
  VAR fsrc: Files.File;
      uname: ARRAY MaxPath OF CHAR;
      i: INTEGER;
BEGIN
  IF ~Files.Reset(fsrc, mergeArchBuf) THEN RETURN END;
  Files.Seek(fsrc, libOfs);
  i := 0;
  WHILE (i < LEN(uname) - 1) & (name[i] # 0X) DO
    uname[i] := SYSTEM.UCASE(name[i]); INC(i)
  END;
  uname[i] := 0X;
  Tar.TarAddFromFile(mergeOut, uname, fsrc, rawSize);
  Files.Close(fsrc)
END OnMergeMember;

(* ---- usage ---- *)

PROCEDURE Usage;
BEGIN
  Err.Info("olib - .OM archive manager");
  Err.Info("Usage:");
  Err.Info("  tolib list    FILE.OM");
  Err.Info("  tolib extract FILE.OM MEMBER OUTFILE");
  Err.Info("  tolib create  OUT.OM  FILE ...");
  Err.Info("  tolib merge   OUT.OM  IN.OM ...");
  Err.Info("  @listfile    expand file with one arg per line (any command)")
END Usage;

(* ---- entry point ---- *)

(* Body of olib: returns the process exit code.  ALL error paths return a code
   here; the ONLY SYSTEM.Halt lives in Run.  Tar can no longer abort the process
   (it latches via Err.HaveErr()), so create/merge check the latch. *)
PROCEDURE RunBody(): INTEGER;
  VAR cmd:  ARRAY 16 OF CHAR;
      args: ARRAY MaxArgs OF ARRAY MaxPath OF CHAR;
      nArgs, argc, i, li, ret: INTEGER;
      fout, lf: Files.File;
      ok: BOOLEAN;
      line: ARRAY MaxPath OF CHAR;
      n: WORD;
BEGIN
  argc := Dos.ParamCount();
  IF argc < 2 THEN Usage; RETURN 1 END;

  Dos.ParamStr(1, cmd);

  (* collect args; expand @listfile entries one level deep *)
  nArgs := 0;
  i := 2;
  WHILE (i <= argc) & (nArgs < MaxArgs) DO
    Dos.ParamStr(i, line);
    IF line[0] = "@" THEN
      (* strip the @ to get the filename *)
      li := 0;
      WHILE line[li+1] # 0X DO line[li] := line[li+1]; INC(li) END;
      line[li] := 0X;
      IF Files.Reset(lf, line) THEN
        li := 0;
        n := Files.BlockRead(lf, args[nArgs][li], 1);
        WHILE n > 0 DO
          IF (args[nArgs][li] = 0DX) OR (args[nArgs][li] = 0AX) THEN
            (* end of line: commit current entry if non-empty *)
            args[nArgs][li] := 0X;
            IF (li > 0) & (nArgs < MaxArgs) THEN INC(nArgs) END;
            li := 0
          ELSE
            INC(li);
            IF li >= MaxPath - 1 THEN li := MaxPath - 2 END
          END;
          n := Files.BlockRead(lf, args[nArgs][li], 1)
        END;
        (* last line without trailing newline *)
        args[nArgs][li] := 0X;
        IF (li > 0) & (nArgs < MaxArgs) THEN INC(nArgs) END;
        Files.Close(lf)
      ELSE
        Err.Error2("olib: cannot open list file: ", line);
        RETURN 1
      END
    ELSE
      Strings.Copy(line, args[nArgs]);
      INC(nArgs)
    END;
    INC(i)
  END;

  ret := 0;

  IF Strings.EqualICase(cmd, "list") THEN
    IF nArgs < 1 THEN Usage; RETURN 1 END;
    ret := CmdList(args[0])

  ELSIF Strings.EqualICase(cmd, "extract") THEN
    IF nArgs < 3 THEN Usage; RETURN 1 END;
    ret := CmdExtract(args[0], args[1], args[2])

  ELSIF Strings.EqualICase(cmd, "create") THEN
    IF nArgs < 2 THEN Usage; RETURN 1 END;
    IF ~Files.ReWrite(fout, args[0]) THEN
      Err.Error2("olib: cannot create: ", args[0]);
      RETURN 1
    END;
    Tar.TarBegin(fout);
    i := 1; ok := TRUE;
    WHILE (i < nArgs) & ok DO
      IF ~AddFileToArchive(fout, args[i]) THEN
        Files.Close(fout); ok := FALSE; ret := 1
      END;
      INC(i)
    END;
    IF ok THEN Tar.TarEnd(fout); Files.Close(fout) END;
    IF Err.HaveErr() THEN ret := 1 END

  ELSIF Strings.EqualICase(cmd, "merge") THEN
    IF nArgs < 2 THEN Usage; RETURN 1 END;
    IF ~Files.ReWrite(mergeOut, args[0]) THEN
      Err.Error2("olib: cannot create: ", args[0]);
      RETURN 1
    END;
    Tar.TarBegin(mergeOut);
    i := 1;
    WHILE i < nArgs DO
      Strings.Copy(args[i], mergeArchBuf);
      Tar.ListTar(mergeArchBuf, OnMergeMember);  (* all members, including .def *)
      INC(i)
    END;
    Tar.TarEnd(mergeOut);
    Files.Close(mergeOut);
    IF Err.HaveErr() THEN ret := 1 END

  ELSE
    Err.Error2("olib: unknown command: ", cmd);
    Usage; ret := 1
  END;

  RETURN ret
END RunBody;

PROCEDURE Run*;
  VAR rc: INTEGER;
BEGIN
  IO.StdOut(outRider);     (* list output is tool DATA on stdout; diagnostics go via Err *)
  Err.Open;
  rc := RunBody();
  Err.Close;
  SYSTEM.Halt(rc)          (* the ONE and ONLY SYSTEM.Halt in olib *)
END Run;

END TOLib.
