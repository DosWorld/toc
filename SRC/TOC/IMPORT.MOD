(*D+*)
MODULE Import;
(*
  Module import resolver.
  Searches for .def content (extracted from .om archives only — standalone
  .def files are never read; they may be stale crash artifacts) in:

  For ModName:
    1. ModName.OM in the current directory
    2. Each .OM file listed in OBERON_LIB (semicolon-separated paths to .OM files)
    3. OBERON.OM in the current directory

  OBERON_LIB contains semicolon-separated paths to .OM archive files, e.g.:
    OBERON_LIB=C:\OBERON\OBERON.OM;C:\OBERON\MYLIB.OM
*)
IMPORT Dos, Files, Err, Def, Tar, Strings;

CONST
  NameLen = 40;
  PathLen = 128;

TYPE
  Loaded = POINTER TO LoadedRec;
  LoadedRec = RECORD
    alias: ARRAY NameLen OF CHAR;
    next:  Loaded
  END;

VAR
  loadedHead: Loaded;   (* aliases whose .def has already been read this compile *)

(* Reset the loaded-.def set; call once at the start of each module compile.
   Frees the previous list so the guard itself never leaks across compiles. *)
PROCEDURE ResetLoaded*;
  VAR p, n: Loaded;
BEGIN
  p := loadedHead;
  WHILE p # NIL DO n := p^.next; DISPOSE(p); p := n END;
  loadedHead := NIL
END ResetLoaded;

(* TRUE if alias' .def was already loaded; otherwise records it and returns FALSE.
   Ensures each module's .def is read exactly once per compile (a .def, like an
   .rdf at link time, must be processed only once — re-reading duplicates every
   imported type/const/var symbol into the symbol table). *)
PROCEDURE AlreadyLoaded(alias: ARRAY OF CHAR): BOOLEAN;
  VAR p: Loaded;
BEGIN
  p := loadedHead;
  WHILE p # NIL DO
    IF Strings.Equal(p^.alias, alias) THEN RETURN TRUE END;
    p := p^.next
  END;
  NEW(p); Strings.Copy(alias, p^.alias); p^.next := loadedHead; loadedHead := p;
  RETURN FALSE
END AlreadyLoaded;

(* Extract .def content from inside .om archive at path.
   Standalone .def files are never read. *)
PROCEDURE TryExtract(omPath, defname: ARRAY OF CHAR;
                     VAR out: Files.File): BOOLEAN;
BEGIN
  RETURN Tar.TarExtract(omPath, defname, out)
END TryExtract;

(* Build module archive name from defname (e.g. "Foo.def" -> "FOO.OM") *)
PROCEDURE DefToOmName(defname: ARRAY OF CHAR; VAR omname: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE (defname[i] # 0X) & (defname[i] # ".") & (i < LEN(omname) - 4) DO
    omname[i] := SYSTEM.UCASE(defname[i]);
    INC(i)
  END;
  omname[i] := "."; omname[i+1] := "O"; omname[i+2] := "M"; omname[i+3] := 0X
END DefToOmName;

(* Real MS-DOS file APIs (INT 21h) never accept '/' as a path separator —
   only '\' and ':'.  A forward-slash path (e.g. from a Makefile's
   OBERON_LIB=bin/OBERON.OM) silently fails to resolve.  Every OBERON_LIB
   path — both here (compile-time .def search) and in TOC.MOD (link-time
   module loading) — must go through this before any Files/Tar call. *)
PROCEDURE NormalizeSlashes*(VAR path: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = "/" THEN path[i] := "\" END;
    INC(i)
  END
END NormalizeSlashes;

(* Join dir and file into dst, inserting "\" separator if needed. *)
PROCEDURE PathJoin(VAR dst: ARRAY OF CHAR; dir, file: ARRAY OF CHAR);
  VAR i, j: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(dst) - 1) & (dir[i] # 0X) DO dst[i] := dir[i]; INC(i) END;
  IF (i > 0) & (dst[i-1] # "\") & (i < LEN(dst) - 1) THEN
    dst[i] := "\"; INC(i)
  END;
  j := 0;
  WHILE (i < LEN(dst) - 1) & (file[j] # 0X) DO dst[i] := file[j]; INC(i); INC(j) END;
  dst[i] := 0X
END PathJoin;

(* Search for defname — first in ModName.OM (CWD), then ModName.OM in exe dir,
   then in each OBERON_LIB archive, then OBERON.OM (CWD), then OBERON.OM in exe dir. *)
PROCEDURE FindImportFile(defname: ARRAY OF CHAR; VAR out: Files.File): BOOLEAN;
  VAR omname: ARRAY NameLen OF CHAR;
      env: ARRAY 512 OF CHAR;
      omPath: ARRAY PathLen OF CHAR;
      exePath, exeDir, n1, n2: ARRAY PathLen OF CHAR;
      i, dlen: INTEGER;
BEGIN
  DefToOmName(defname, omname);

  (* 1. ModName.OM in current directory *)
  IF TryExtract(omname, defname, out) THEN RETURN TRUE END;

  (* Get exe directory for steps 1.5 and 4 *)
  Dos.ParamStr(0, exePath);
  IF exePath[0] # 0X THEN
    Dos.FSplit(exePath, exeDir, n1, n2)
  ELSE
    exeDir[0] := 0X
  END;

  (* 1.5. ModName.OM in exe directory *)
  IF exeDir[0] # 0X THEN
    PathJoin(omPath, exeDir, omname);
    IF TryExtract(omPath, defname, out) THEN RETURN TRUE END
  END;

  (* 2. Each .OM file in OBERON_LIB *)
  Dos.GetEnv("OBERON_LIB", env);
  IF env[0] # 0X THEN
    i := 0;
    WHILE env[i] # 0X DO
      dlen := 0;
      WHILE (env[i] # 0X) & (env[i] # ";") & (dlen < PathLen - 1) DO
        omPath[dlen] := env[i]; INC(dlen); INC(i)
      END;
      omPath[dlen] := 0X;
      IF env[i] = ";" THEN INC(i) END;
      NormalizeSlashes(omPath);
      IF (dlen > 0) & TryExtract(omPath, defname, out) THEN RETURN TRUE END
    END
  END;

  (* 3. OBERON.OM in current directory *)
  IF TryExtract("OBERON.OM", defname, out) THEN RETURN TRUE END;

  (* 4. OBERON.OM in exe directory *)
  IF exeDir[0] # 0X THEN
    PathJoin(omPath, exeDir, "OBERON.OM");
    IF TryExtract(omPath, defname, out) THEN RETURN TRUE END
  END;

  RETURN FALSE
END FindImportFile;

(* ---- public API ---- *)

(* A missing/unresolvable import is a normal compile error, not a process abort:
   report it via Err (latches, fail-fast); the caller checks Err.HaveErr().  The
   only SYSTEM.Halt lives in TOC.Run. *)
PROCEDURE LoadExplicitImport*(modName, alias: ARRAY OF CHAR);
  VAR deffile: ARRAY NameLen OF CHAR;
      f: Files.File;
      env: ARRAY 512 OF CHAR;
      msg: ARRAY 640 OF CHAR;
BEGIN
  IF AlreadyLoaded(alias) THEN RETURN END;
  Strings.Copy(modName, deffile);
  Strings.Append(".def", deffile);

  IF ~FindImportFile(deffile, f) THEN
    (* One message: the Err latch prints only the first line, so assemble the
       full diagnostic before reporting it once. *)
    Strings.Copy("cannot find module '", msg);
    Strings.Append(modName, msg);
    Strings.Append(".om' (or '.def'); searched current directory", msg);
    Dos.GetEnv("OBERON_LIB", env);
    IF env[0] # 0X THEN
      Strings.Append(" and OBERON_LIB=", msg);
      Strings.Append(env, msg)
    END;
    Err.Error(msg); RETURN
  END;

  Def.DefRead(f, alias);
  Files.Close(f)
END LoadExplicitImport;

PROCEDURE AddImplicitImport*(modName: ARRAY OF CHAR);
  VAR deffile: ARRAY NameLen OF CHAR;
      f: Files.File;
BEGIN
  IF AlreadyLoaded(modName) THEN RETURN END;
  Strings.Copy(modName, deffile);
  Strings.Append(".def", deffile);

  IF FindImportFile(deffile, f) THEN
    Def.DefRead(f, modName);
    Files.Close(f)
  END
END AddImplicitImport;

END Import.
