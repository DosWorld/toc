MODULE rdfgrep;
(* rdfgrep — RDOFF/.om introspection CLI.
   Replaces the python heredocs formerly in tests/test_src.sh.
   See docs/tests.md for the full EXPECT predicate vocabulary.

   Exit codes:
     0   — match / success
     1   — no match (predicate false)
     2   — usage error (missing args, bad hex, etc.)
     3   — I/O error (cannot open file, parse failure)

   Subcommands (all take a file path as second positional arg):

     RDF predicates:
     rdfgrep has-import        FILE.RDF NAME    — RDOFF has IMPORT NAME
     rdfgrep no-import         FILE.RDF NAME    — RDOFF does NOT have IMPORT NAME
     rdfgrep has-global        FILE.RDF NAME    — RDOFF has GLOBAL NAME
     rdfgrep no-global         FILE.RDF NAME    — RDOFF does NOT have GLOBAL NAME
     rdfgrep code-starts       FILE.RDF HEX     — code segment starts with HEX
     rdfgrep code-contains     FILE.RDF HEX     — code segment contains HEX
     rdfgrep no-code-contains  FILE.RDF HEX     — code segment does NOT contain HEX
     rdfgrep code-count        FILE.RDF HH MIN  — count of byte HH in code >= MIN
     rdfgrep code-byte-at      FILE.RDF OFS HH  — code[OFS] == HH
     rdfgrep init-imports      FILE.RDF         — print imports ending '__init'
     rdfgrep init-imports-empty FILE.RDF        — zero imports end with '__init'
     rdfgrep has-segreloc      FILE.RDF         — at least one SEGRELOC record
     rdfgrep no-segreloc       FILE.RDF         — zero SEGRELOC records
     rdfgrep has-reloc-and-segreloc FILE.RDF    — at least one of each
     rdfgrep has-reloc-for     FILE.RDF NAME    — RELOC referencing import NAME
     rdfgrep has-reloc-to-seg  FILE.RDF SEG     — RELOC referencing seg
                                                  (0=code, 1=data, 2=bss)

     .om (ustar) operations:
     rdfgrep om-has-file       FILE.OM MEMBER          — archive has MEMBER
     rdfgrep om-no-file        FILE.OM MEMBER          — archive does NOT have MEMBER
     rdfgrep om-extract        FILE.OM MEMBER OUT      — extract MEMBER to OUT
     rdfgrep om-member-equals  FILE.OM MEMBER VALUE    — MEMBER (trimmed) == VALUE
     rdfgrep om-member-contains FILE.OM MEMBER TEXT    — MEMBER bytes contain TEXT
     rdfgrep om-member-no-contains FILE.OM MEMBER TEXT — MEMBER bytes do NOT contain TEXT
     rdfgrep make-stub         OUT.OM MODNAME [DEFTEXT|@FILE]
                                                       — write .om with one .DEF

     MZ EXE inspection:
     rdfgrep mz-sp             FILE.EXE VALUE          — MZ SP word at offset 16 == VALUE
     rdfgrep mz-min-alloc      FILE.EXE VALUE          — MZ min_alloc word at offset 10 == VALUE
     rdfgrep mz-max-alloc      FILE.EXE VALUE          — MZ max_alloc word at offset 12 == VALUE

   HEX format: pairs of hex digits, optionally separated by whitespace.
   Example: "CB", "0E E8", "0000 2E 83 3E".

   make-stub DEFTEXT forms:
     (omitted)   default body "MODULE <name>\n"
     literal     a single-word literal — DOS does not honour quotes, so
                 multi-word literals split at whitespace.
     @FILE       read the .def body verbatim from FILE.  Use this when the
                 body needs newlines, spaces, or multiple declarations. *)

IMPORT Out, Dos, Strings, Files, Rdoff, Tar, LogErr;

CONST
  ExitMatch* = 0;
  ExitNoMatch* = 1;
  ExitUsage* = 2;
  ExitIo* = 3;

PROCEDURE Halt(code: INTEGER);
BEGIN
  LogErr.Close;
  SYSTEM.Halt(BYTE(code))
END Halt;

PROCEDURE Usage;
BEGIN
  Out.String("usage: rdfgrep SUBCOMMAND FILE [ARGS...]"); Out.Ln;
  Out.Ln;
  Out.String("RDF predicates:"); Out.Ln;
  Out.String("  has-import        FILE.RDF NAME       RDOFF has IMPORT NAME"); Out.Ln;
  Out.String("  no-import         FILE.RDF NAME       RDOFF does NOT have IMPORT NAME"); Out.Ln;
  Out.String("  has-global        FILE.RDF NAME       RDOFF has GLOBAL NAME"); Out.Ln;
  Out.String("  no-global         FILE.RDF NAME       RDOFF does NOT have GLOBAL NAME"); Out.Ln;
  Out.String("  code-starts       FILE.RDF HEX        code segment starts with HEX"); Out.Ln;
  Out.String("  code-contains     FILE.RDF HEX        code segment contains HEX"); Out.Ln;
  Out.String("  no-code-contains  FILE.RDF HEX        code segment does NOT contain HEX"); Out.Ln;
  Out.String("  code-count        FILE.RDF HH MIN     count of byte HH in code >= MIN"); Out.Ln;
  Out.String("  code-byte-at      FILE.RDF OFS HH     code[OFS] == HH"); Out.Ln;
  Out.String("  init-imports      FILE.RDF            print imports ending '__init'"); Out.Ln;
  Out.String("  init-imports-empty FILE.RDF           zero imports end with '__init'"); Out.Ln;
  Out.String("  has-segreloc      FILE.RDF            at least one SEGRELOC record"); Out.Ln;
  Out.String("  no-segreloc       FILE.RDF            zero SEGRELOC records"); Out.Ln;
  Out.String("  has-reloc-and-segreloc FILE.RDF       at least one RELOC and one SEGRELOC"); Out.Ln;
  Out.String("  has-reloc-for     FILE.RDF NAME       RELOC references import NAME"); Out.Ln;
  Out.String("  has-reloc-to-seg  FILE.RDF SEG        RELOC references seg (0=code/1=data/2=bss)"); Out.Ln;
  Out.Ln;
  Out.String(".om (ustar) operations:"); Out.Ln;
  Out.String("  om-has-file       FILE.OM MEMBER       archive has MEMBER"); Out.Ln;
  Out.String("  om-no-file        FILE.OM MEMBER       archive does NOT have MEMBER"); Out.Ln;
  Out.String("  om-extract        FILE.OM MEMBER OUT   extract MEMBER to OUT"); Out.Ln;
  Out.String("  om-member-equals  FILE.OM MEMBER VALUE MEMBER trimmed text == VALUE"); Out.Ln;
  Out.String("  om-member-contains FILE.OM MEMBER TEXT MEMBER bytes contain TEXT"); Out.Ln;
  Out.String("  om-member-no-contains FILE.OM MEMBER TEXT MEMBER bytes do NOT contain TEXT"); Out.Ln;
  Out.String("  make-stub         OUT.OM MODNAME [DEFTEXT|@FILE]  write .om with one .DEF"); Out.Ln;
  Out.Ln;
  Out.String("MZ EXE inspection:"); Out.Ln;
  Out.String("  mz-sp             FILE.EXE VALUE       MZ SP word at offset 16 == VALUE"); Out.Ln;
  Out.String("  mz-min-alloc      FILE.EXE VALUE       MZ min_alloc word at offset 10 == VALUE"); Out.Ln;
  Out.String("  mz-max-alloc      FILE.EXE VALUE       MZ max_alloc word at offset 12 == VALUE"); Out.Ln;
  Out.Ln;
  Out.String("Exit codes: 0=match  1=no-match  2=usage  3=I/O"); Out.Ln;
  Halt(ExitUsage)
END Usage;

(* ---- arg helpers ---- *)

PROCEDURE getArg(i: INTEGER; VAR s: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF i > Dos.ParamCount() THEN s[0] := 0X; RETURN FALSE END;
  Dos.ParamStr(i, s);
  RETURN TRUE
END getArg;

(* ---- hex parsing ----
   Parse a space-separated hex string into a byte buffer.  "0E E8" → 2 bytes.
   Returns the number of bytes parsed, or -1 on bad input. *)

PROCEDURE hexDigit(c: CHAR): INTEGER;
BEGIN
  IF (c >= "0") & (c <= "9") THEN RETURN ORD(c) - ORD("0") END;
  IF (c >= "a") & (c <= "f") THEN RETURN ORD(c) - ORD("a") + 10 END;
  IF (c >= "A") & (c <= "F") THEN RETURN ORD(c) - ORD("A") + 10 END;
  RETURN -1
END hexDigit;

PROCEDURE parseHex(s: ARRAY OF CHAR; VAR buf: ARRAY OF BYTE): INTEGER;
  VAR i, n, h1, h2: INTEGER; done: BOOLEAN;
BEGIN
  i := 0; n := 0; done := FALSE;
  WHILE ~done DO
    (* skip whitespace *)
    WHILE (i < LEN(s)) & ((s[i] = " ") OR (s[i] = 9X)) DO INC(i) END;
    IF (i >= LEN(s)) OR (s[i] = 0X) THEN done := TRUE
    ELSE
      h1 := hexDigit(s[i]); INC(i);
      IF h1 < 0 THEN RETURN -1 END;
      IF (i >= LEN(s)) OR (s[i] = 0X) THEN RETURN -1 END;
      h2 := hexDigit(s[i]); INC(i);
      IF h2 < 0 THEN RETURN -1 END;
      IF n >= LEN(buf) THEN RETURN -1 END;
      buf[n] := BYTE(h1 * 16 + h2); INC(n)
    END
  END;
  RETURN n
END parseHex;

(* Decimal parse — accepts any non-negative value that fits in LONGINT.
   The mz-sp test compares MZ SP words like 65534 which would overflow
   16-bit INTEGER arithmetic; LONGINT widens the staging value. *)
PROCEDURE parseInt(s: ARRAY OF CHAR): LONGINT;
  VAR i: INTEGER; v: LONGINT;
BEGIN
  i := 0; v := LONGINT(0);
  WHILE (i < LEN(s)) & (s[i] >= "0") & (s[i] <= "9") DO
    v := v * LONGINT(10) + LONGINT(ORD(s[i]) - ORD("0"));
    INC(i)
  END;
  RETURN v
END parseInt;

(* ---- predicates over a loaded ObjFile ---- *)

PROCEDURE hasImport(obj: Rdoff.ObjFile; name: ARRAY OF CHAR): BOOLEAN;
  VAR imp: Rdoff.ImportNode;
BEGIN
  imp := obj^.importHead;
  WHILE imp # NIL DO
    IF Strings.Equal(imp^.name, name) THEN RETURN TRUE END;
    imp := imp^.next
  END;
  RETURN FALSE
END hasImport;

PROCEDURE hasGlobal(obj: Rdoff.ObjFile; name: ARRAY OF CHAR): BOOLEAN;
  VAR g: Rdoff.GlobalNode;
BEGIN
  g := obj^.globalHead;
  WHILE g # NIL DO
    IF Strings.Equal(g^.name, name) THEN RETURN TRUE END;
    g := g^.next
  END;
  RETURN FALSE
END hasGlobal;

PROCEDURE codeStartsWith(obj: Rdoff.ObjFile; VAR pat: ARRAY OF BYTE;
                         npat: INTEGER): BOOLEAN;
  VAR i: INTEGER;
BEGIN
  IF LONGINT(npat) > LONGINT(obj^.codeLen) THEN RETURN FALSE END;
  FOR i := 0 TO npat - 1 DO
    IF Rdoff.PeekCodeByte(obj, LONGINT(i)) # pat[i] THEN RETURN FALSE END
  END;
  RETURN TRUE
END codeStartsWith;

PROCEDURE codeContains(obj: Rdoff.ObjFile; VAR pat: ARRAY OF BYTE;
                       npat: INTEGER): BOOLEAN;
  VAR i, j: LONGINT; match: BOOLEAN;
BEGIN
  IF npat = 0 THEN RETURN TRUE END;
  IF LONGINT(npat) > LONGINT(obj^.codeLen) THEN RETURN FALSE END;
  i := LONGINT(0);
  WHILE i <= LONGINT(obj^.codeLen) - LONGINT(npat) DO
    match := TRUE; j := LONGINT(0);
    WHILE match & (j < LONGINT(npat)) DO
      IF Rdoff.PeekCodeByte(obj, i + j) # pat[INTEGER(j)] THEN match := FALSE END;
      INC(j)
    END;
    IF match THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END codeContains;

PROCEDURE codeCount(obj: Rdoff.ObjFile; needle: BYTE): INTEGER;
  VAR i: LONGINT; n: INTEGER;
BEGIN
  n := 0; i := LONGINT(0);
  WHILE i < LONGINT(obj^.codeLen) DO
    IF Rdoff.PeekCodeByte(obj, i) = needle THEN INC(n) END;
    INC(i)
  END;
  RETURN n
END codeCount;

(* Code byte at OFS equals HH. *)
PROCEDURE codeByteAt(obj: Rdoff.ObjFile; ofs: LONGINT; hh: BYTE): BOOLEAN;
BEGIN
  IF (ofs < LONGINT(0)) OR (ofs >= LONGINT(obj^.codeLen)) THEN RETURN FALSE END;
  RETURN Rdoff.PeekCodeByte(obj, ofs) = hh
END codeByteAt;

PROCEDURE isInitName(name: ARRAY OF CHAR): BOOLEAN;
  VAR l: INTEGER;
BEGIN
  l := 0;
  WHILE (l < LEN(name)) & (name[l] # 0X) DO INC(l) END;
  IF l < 6 THEN RETURN FALSE END;
  RETURN (name[l-6] = "_") & (name[l-5] = "_") &
         (name[l-4] = "i") & (name[l-3] = "n") &
         (name[l-2] = "i") & (name[l-1] = "t")
END isInitName;

PROCEDURE printInitImports(obj: Rdoff.ObjFile);
  VAR imp: Rdoff.ImportNode;
BEGIN
  imp := obj^.importHead;
  WHILE imp # NIL DO
    IF isInitName(imp^.name) THEN Out.String(imp^.name); Out.Ln END;
    imp := imp^.next
  END
END printInitImports;

(* TRUE iff any IMPORT entry name ends with "__init". *)
PROCEDURE anyInitImport(obj: Rdoff.ObjFile): BOOLEAN;
  VAR imp: Rdoff.ImportNode;
BEGIN
  imp := obj^.importHead;
  WHILE imp # NIL DO
    IF isInitName(imp^.name) THEN RETURN TRUE END;
    imp := imp^.next
  END;
  RETURN FALSE
END anyInitImport;

PROCEDURE countRelocs(obj: Rdoff.ObjFile; VAR nReloc, nSegreloc: INTEGER);
  VAR r: Rdoff.RelocNode; k: INTEGER;
BEGIN
  nReloc := 0; nSegreloc := 0;
  r := obj^.relocHead;
  WHILE r # NIL DO
    k := 0;
    WHILE k < r^.count DO
      IF SYSTEM.AND(INTEGER(r^.physSeg[k]), 080H) # 0 THEN INC(nSegreloc)
      ELSE INC(nReloc) END;
      INC(k)
    END;
    r := r^.next
  END
END countRelocs;

(* RELOC references a target segment id directly (0=code, 1=data, 2=bss,
   >=3 = import).  Skips SEGRELOCs (bit 7 of physSeg). *)
PROCEDURE hasRelocToSeg(obj: Rdoff.ObjFile; seg: INTEGER): BOOLEAN;
  VAR r: Rdoff.RelocNode; k: INTEGER;
BEGIN
  r := obj^.relocHead;
  WHILE r # NIL DO
    k := 0;
    WHILE k < r^.count DO
      IF (SYSTEM.AND(INTEGER(r^.physSeg[k]), 080H) = 0) & (r^.rseg[k] = seg) THEN
        RETURN TRUE
      END;
      INC(k)
    END;
    r := r^.next
  END;
  RETURN FALSE
END hasRelocToSeg;

(* RELOC references the import-id of an IMPORT named NAME. *)
PROCEDURE hasRelocForImport(obj: Rdoff.ObjFile; name: ARRAY OF CHAR): BOOLEAN;
  VAR imp: Rdoff.ImportNode; r: Rdoff.RelocNode; id, k: INTEGER;
BEGIN
  id := -1;
  imp := obj^.importHead;
  WHILE imp # NIL DO
    IF Strings.Equal(imp^.name, name) THEN id := imp^.segId END;
    imp := imp^.next
  END;
  IF id < 0 THEN RETURN FALSE END;
  r := obj^.relocHead;
  WHILE r # NIL DO
    k := 0;
    WHILE k < r^.count DO
      IF (SYSTEM.AND(INTEGER(r^.physSeg[k]), 080H) = 0) & (r^.rseg[k] = id) THEN
        RETURN TRUE
      END;
      INC(k)
    END;
    r := r^.next
  END;
  RETURN FALSE
END hasRelocForImport;

(* ---- file ops ---- *)

PROCEDURE loadRdf(VAR obj: Rdoff.ObjFile; path: ARRAY OF CHAR);
BEGIN
  NEW(obj);
  Rdoff.RdfInit(obj);
  IF LogErr.HaveErr() OR ~Rdoff.RdfLoad(obj, path) THEN
    Out.String("rdfgrep: cannot load "); Out.String(path); Out.Ln;
    Halt(ExitIo)
  END
END loadRdf;

(* ---- om-has-file via Tar.TarExtract ---- *)

PROCEDURE omHasFile(libPath, member: ARRAY OF CHAR): BOOLEAN;
  VAR tmp: Files.File; ok: BOOLEAN;
BEGIN
  ok := Tar.TarExtract(libPath, member, tmp);
  IF ok THEN
    Files.Close(tmp)   (* TAR$$.TMP auto-deletes on close *)
  END;
  RETURN ok
END omHasFile;

(* Copy a tar member from libPath to outPath (binary verbatim).  Returns
   FALSE if the member isn't found or I/O fails. *)
PROCEDURE omExtract(libPath, member, outPath: ARRAY OF CHAR): BOOLEAN;
  VAR src, dst: Files.File; ok: BOOLEAN;
      buf: ARRAY 512 OF BYTE; n: INTEGER;
BEGIN
  ok := Tar.TarExtract(libPath, member, src);
  IF ~ok THEN RETURN FALSE END;
  IF ~Files.ReWrite(dst, outPath) THEN
    Files.Close(src); RETURN FALSE   (* TAR$$.TMP auto-deletes on close *)
  END;
  Files.Seek(src, LONGINT(0));
  n := Files.BlockRead(src, buf[0], 512);
  WHILE n > 0 DO
    n := Files.BlockWrite(dst, buf[0], n);
    n := Files.BlockRead(src, buf[0], 512)
  END;
  Files.Close(src); Files.Close(dst);
  RETURN TRUE
END omExtract;

(* Extract MEMBER into a scratch buffer (up to LEN(buf) bytes).  Returns
   the count, or -1 if MEMBER not found / I/O error. *)
PROCEDURE omReadMember(libPath, member: ARRAY OF CHAR;
                       VAR buf: ARRAY OF BYTE): INTEGER;
  VAR src: Files.File; ok: BOOLEAN; n: INTEGER; size: LONGINT;
BEGIN
  ok := Tar.TarExtract(libPath, member, src);
  IF ~ok THEN RETURN -1 END;
  size := Files.Size(src);
  IF size > LONGINT(LEN(buf)) THEN size := LONGINT(LEN(buf)) END;
  Files.Seek(src, LONGINT(0));
  n := Files.BlockRead(src, buf[0], INTEGER(size));
  Files.Close(src);   (* TAR$$.TMP auto-deletes on close *)
  RETURN n
END omReadMember;

(* Member text (trimmed of trailing whitespace including LF/CR) equals
   the given value. *)
PROCEDURE omMemberEquals(libPath, member, value: ARRAY OF CHAR): BOOLEAN;
  VAR buf: ARRAY 256 OF BYTE; n, i, vlen: INTEGER;
BEGIN
  n := omReadMember(libPath, member, buf);
  IF n < 0 THEN RETURN FALSE END;
  (* trim trailing whitespace *)
  WHILE (n > 0) &
        ((buf[n-1] = BYTE(20H)) OR (buf[n-1] = BYTE(09H)) OR
         (buf[n-1] = BYTE(0AH)) OR (buf[n-1] = BYTE(0DH))) DO
    DEC(n)
  END;
  vlen := 0;
  WHILE (vlen < LEN(value)) & (value[vlen] # 0X) DO INC(vlen) END;
  IF n # vlen THEN RETURN FALSE END;
  i := 0;
  WHILE i < n DO
    IF INTEGER(buf[i]) # ORD(value[i]) THEN RETURN FALSE END;
    INC(i)
  END;
  RETURN TRUE
END omMemberEquals;

(* Member raw bytes contain the byte sequence corresponding to TEXT (plain
   ASCII substring, no NUL).  Used to grep MAIN.RDF for a name etc. *)
PROCEDURE omMemberContains(libPath, member, text: ARRAY OF CHAR): BOOLEAN;
  VAR buf: ARRAY 2048 OF BYTE; n, tlen, i, j: INTEGER; match: BOOLEAN;
BEGIN
  n := omReadMember(libPath, member, buf);
  IF n < 0 THEN RETURN FALSE END;
  tlen := 0;
  WHILE (tlen < LEN(text)) & (text[tlen] # 0X) DO INC(tlen) END;
  IF tlen = 0 THEN RETURN TRUE END;
  IF tlen > n THEN RETURN FALSE END;
  i := 0;
  WHILE i <= n - tlen DO
    match := TRUE; j := 0;
    WHILE match & (j < tlen) DO
      IF INTEGER(buf[i+j]) # ORD(text[j]) THEN match := FALSE END;
      INC(j)
    END;
    IF match THEN RETURN TRUE END;
    INC(i)
  END;
  RETURN FALSE
END omMemberContains;

(* Read a 16-bit little-endian word from an MZ header at the given byte
   offset.  Used by mz-sp (offset 16), mz-min-alloc (10), mz-max-alloc (12). *)
PROCEDURE mzWordAt(path: ARRAY OF CHAR; ofs: LONGINT; VAR val: INTEGER): BOOLEAN;
  VAR f: Files.File; b: ARRAY 2 OF BYTE; n: INTEGER;
BEGIN
  IF ~Files.Reset(f, path) THEN RETURN FALSE END;
  Files.Seek(f, ofs);
  n := Files.BlockRead(f, b[0], 2);
  Files.Close(f);
  IF n # 2 THEN RETURN FALSE END;
  val := INTEGER(SYSTEM.IOR(INTEGER(b[0]), SYSTEM.LSL(INTEGER(b[1]), 8)));
  RETURN TRUE
END mzWordAt;

PROCEDURE mzSpWord(path: ARRAY OF CHAR; VAR sp: INTEGER): BOOLEAN;
BEGIN RETURN mzWordAt(path, LONGINT(16), sp)
END mzSpWord;

PROCEDURE mzMinAlloc(path: ARRAY OF CHAR; VAR v: INTEGER): BOOLEAN;
BEGIN RETURN mzWordAt(path, LONGINT(10), v)
END mzMinAlloc;

PROCEDURE mzMaxAlloc(path: ARRAY OF CHAR; VAR v: INTEGER): BOOLEAN;
BEGIN RETURN mzWordAt(path, LONGINT(12), v)
END mzMaxAlloc;

(* ---- make-stub: write a tiny .om containing one .DEF member ---- *)

(* Slurp up to LEN(bytes) bytes from `path` into `bytes`.  Returns the byte
   count, or -1 on I/O error. *)
PROCEDURE slurpFile(path: ARRAY OF CHAR; VAR bytes: ARRAY OF BYTE): INTEGER;
  VAR f: Files.File; size: LONGINT; n: INTEGER;
BEGIN
  IF ~Files.Reset(f, path) THEN RETURN -1 END;
  size := Files.Size(f);
  IF size > LONGINT(LEN(bytes)) THEN size := LONGINT(LEN(bytes)) END;
  Files.Seek(f, LONGINT(0));
  n := Files.BlockRead(f, bytes[0], INTEGER(size));
  Files.Close(f);
  RETURN n
END slurpFile;

PROCEDURE makeStub(outPath, modName, defText: ARRAY OF CHAR);
  VAR f: Files.File;
      member: ARRAY 64 OF CHAR;
      content: ARRAY 1024 OF CHAR;
      bytes: ARRAY 1024 OF BYTE;
      filePath: ARRAY 128 OF CHAR;
      i, n: INTEGER;
      c: CHAR;
BEGIN
  (* member name = uppercase MODNAME + ".DEF" *)
  i := 0;
  WHILE (modName[i] # 0X) & (i < 32) DO
    c := modName[i];
    IF (c >= "a") & (c <= "z") THEN c := CHR(ORD(c) - 32) END;
    member[i] := c; INC(i)
  END;
  member[i] := 0X;
  Strings.Append(".DEF", member);

  IF defText[0] = "@" THEN
    (* @FILE — slurp body verbatim from FILE *)
    i := 0;
    WHILE (defText[i + 1] # 0X) & (i < LEN(filePath) - 1) DO
      filePath[i] := defText[i + 1]; INC(i)
    END;
    filePath[i] := 0X;
    n := slurpFile(filePath, bytes);
    IF n < 0 THEN
      Out.String("rdfgrep: cannot read "); Out.String(filePath); Out.Ln;
      Halt(ExitIo)
    END
  ELSIF defText[0] = 0X THEN
    (* default body: "MODULE <name>\n" *)
    Strings.Copy("MODULE ", content);
    Strings.Append(modName, content);
    n := 0;
    WHILE (n < LEN(content) - 2) & (content[n] # 0X) DO
      bytes[n] := BYTE(ORD(content[n])); INC(n)
    END;
    bytes[n] := BYTE(0AH); INC(n)
  ELSE
    (* literal single-word body *)
    n := 0;
    WHILE (n < LEN(content) - 1) & (defText[n] # 0X) DO
      bytes[n] := BYTE(ORD(defText[n])); INC(n)
    END
  END;

  IF ~Files.ReWrite(f, outPath) THEN
    Out.String("rdfgrep: cannot write "); Out.String(outPath); Out.Ln;
    Halt(ExitIo)
  END;
  Tar.TarBegin(f);
  Tar.TarAddFile(f, member, bytes, WORD(n));
  Tar.TarEnd(f);
  Files.Close(f)
END makeStub;

(* ---- command dispatch ---- *)

PROCEDURE Run*;
  VAR cmd, file, a1, a2: ARRAY 128 OF CHAR;
      obj: Rdoff.ObjFile;
      buf: ARRAY 64 OF BYTE;
      npat, minCount, found: INTEGER;
      spVal: INTEGER;
      lval: LONGINT;
      nReloc, nSegreloc: INTEGER;
BEGIN
  LogErr.Open;
  IF Dos.ParamCount() < 2 THEN Usage END;
  Dos.ParamStr(1, cmd);
  Dos.ParamStr(2, file);

  IF Strings.Equal(cmd, "has-import") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF hasImport(obj, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "no-import") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF ~hasImport(obj, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "has-global") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF hasGlobal(obj, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "no-global") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF ~hasGlobal(obj, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "init-imports-empty") THEN
    loadRdf(obj, file);
    IF ~anyInitImport(obj) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "code-starts") THEN
    IF ~getArg(3, a1) THEN Usage END;
    npat := parseHex(a1, buf);
    IF npat < 0 THEN Usage END;
    loadRdf(obj, file);
    IF codeStartsWith(obj, buf, npat) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "code-contains") THEN
    IF ~getArg(3, a1) THEN Usage END;
    npat := parseHex(a1, buf);
    IF npat < 0 THEN Usage END;
    loadRdf(obj, file);
    IF codeContains(obj, buf, npat) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "no-code-contains") THEN
    IF ~getArg(3, a1) THEN Usage END;
    npat := parseHex(a1, buf);
    IF npat < 0 THEN Usage END;
    loadRdf(obj, file);
    IF ~codeContains(obj, buf, npat) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "code-count") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    npat := parseHex(a1, buf);
    IF (npat # 1) THEN Usage END;
    minCount := INTEGER(parseInt(a2));
    loadRdf(obj, file);
    found := codeCount(obj, buf[0]);
    IF found >= minCount THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "init-imports") THEN
    loadRdf(obj, file);
    printInitImports(obj);
    Halt(ExitMatch)

  ELSIF Strings.Equal(cmd, "has-segreloc") THEN
    loadRdf(obj, file);
    countRelocs(obj, nReloc, nSegreloc);
    IF nSegreloc > 0 THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "no-segreloc") THEN
    loadRdf(obj, file);
    countRelocs(obj, nReloc, nSegreloc);
    IF nSegreloc = 0 THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "has-reloc-and-segreloc") THEN
    loadRdf(obj, file);
    countRelocs(obj, nReloc, nSegreloc);
    IF (nReloc > 0) & (nSegreloc > 0) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "has-reloc-for") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF hasRelocForImport(obj, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "has-reloc-to-seg") THEN
    IF ~getArg(3, a1) THEN Usage END;
    loadRdf(obj, file);
    IF hasRelocToSeg(obj, INTEGER(parseInt(a1))) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "code-byte-at") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    npat := parseHex(a2, buf);
    IF (npat # 1) THEN Usage END;
    loadRdf(obj, file);
    IF codeByteAt(obj, parseInt(a1), buf[0]) THEN
      Halt(ExitMatch) ELSE Halt(ExitNoMatch)
    END

  ELSIF Strings.Equal(cmd, "om-has-file") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF omHasFile(file, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "om-no-file") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~omHasFile(file, a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "om-extract") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    (* file = LIB.OM, a1 = MEMBER, a2 = OUT *)
    IF omExtract(file, a1, a2) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "om-member-equals") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    IF omMemberEquals(file, a1, a2) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "om-member-contains") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    IF omMemberContains(file, a1, a2) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "om-member-no-contains") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN Usage END;
    IF ~omMemberContains(file, a1, a2) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "mz-sp") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~mzSpWord(file, spVal) THEN Halt(ExitIo) END;
    (* spVal is INTEGER (signed 16-bit) holding the unsigned MZ SP word.
       Widen with a mask to compare against the user-supplied decimal. *)
    lval := SYSTEM.AND(LONGINT(spVal), LONGINT(0FFFFH));
    IF lval = parseInt(a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "mz-min-alloc") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~mzMinAlloc(file, spVal) THEN Halt(ExitIo) END;
    lval := SYSTEM.AND(LONGINT(spVal), LONGINT(0FFFFH));
    IF lval = parseInt(a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "mz-max-alloc") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~mzMaxAlloc(file, spVal) THEN Halt(ExitIo) END;
    lval := SYSTEM.AND(LONGINT(spVal), LONGINT(0FFFFH));
    IF lval = parseInt(a1) THEN Halt(ExitMatch) ELSE Halt(ExitNoMatch) END

  ELSIF Strings.Equal(cmd, "make-stub") THEN
    IF ~getArg(3, a1) THEN Usage END;
    IF ~getArg(4, a2) THEN a2[0] := 0X END;
    (* file = OUT.OM, a1 = MODNAME, a2 = optional DEFTEXT *)
    makeStub(file, a1, a2);
    Halt(ExitMatch)

  ELSE
    Out.String("rdfgrep: unknown subcommand: "); Out.String(cmd); Out.Ln;
    Usage
  END
END Run;

END rdfgrep.
