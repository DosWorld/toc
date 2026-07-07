MODULE TTAR;
(* Unit tests for Tar — Oberon port of tests/test_tar.c.  Each test writes
   one or more tar members to a temp file, then reads the bytes back and
   asserts the ustar layout (name, size, checksum, padding, EOF blocks). *)

IMPORT Test, Files, Tar;

CONST
  TarName  = 0;
  TarSize  = 124;
  TarCksum = 148;
  TarType  = 156;
  TarMagic = 257;
  TarVer   = 263;

VAR
  TmpTar: ARRAY 8 OF CHAR;
  Buf: ARRAY 4096 OF BYTE;
  BufLen: LONGINT;

PROCEDURE slurp;
  VAR f: Files.File; n: WORD; size: LONGINT;
BEGIN
  IF Files.Reset(f, TmpTar) THEN
    size := Files.Size(f);
    IF size > LONGINT(LEN(Buf)) THEN size := LONGINT(LEN(Buf)) END;
    BufLen := size;
    Files.Seek(f, 0);
    n := Files.BlockRead(f, Buf, WORD(size));
    Files.Close(f)
  ELSE BufLen := 0 END
END slurp;

PROCEDURE writeOne(name: ARRAY OF CHAR; VAR data: ARRAY OF BYTE; dataLen: LONGINT);
  VAR f: Files.File; ok: BOOLEAN;
BEGIN
  ok := Files.ReWrite(f, TmpTar);
  Tar.TarBegin(f);
  Tar.TarAddFile(f, name, data, dataLen);
  Tar.TarEnd(f);
  Files.Close(f);
  slurp
END writeOne;

PROCEDURE cleanup;
  VAR ok: BOOLEAN;
BEGIN ok := Files.Delete(TmpTar) END cleanup;

PROCEDURE b(off: INTEGER): INTEGER;
BEGIN RETURN INTEGER(Buf[off]) END b;

PROCEDURE parseOctal(off, len: INTEGER): LONGINT;
  VAR v: LONGINT; i: INTEGER; c: INTEGER;
BEGIN
  v := 0; i := 0;
  WHILE i < len DO
    c := b(off + i);
    IF (c < ORD("0")) OR (c > ORD("7")) THEN RETURN v END;
    v := v * LONGINT(8) + LONGINT(c - ORD("0"));
    INC(i)
  END;
  RETURN v
END parseOctal;

(* ---- magic ---- *)

PROCEDURE TMagic*;
  VAR d: ARRAY 3 OF BYTE;
BEGIN
  d[0] := 1; d[1] := 2; d[2] := 3;
  writeOne("test.rdf", d, 3);
  Test.AssertInt(ORD("u"), b(TarMagic + 0), "magic[0]=u");
  Test.AssertInt(ORD("s"), b(TarMagic + 1), "magic[1]=s");
  Test.AssertInt(ORD("t"), b(TarMagic + 2), "magic[2]=t");
  Test.AssertInt(ORD("a"), b(TarMagic + 3), "magic[3]=a");
  Test.AssertInt(ORD("r"), b(TarMagic + 4), "magic[4]=r");
  Test.AssertInt(ORD("0"), b(TarVer + 0), "version[0]=0");
  Test.AssertInt(ORD("0"), b(TarVer + 1), "version[1]=0");
  cleanup
END TMagic;

(* ---- typeflag ---- *)

PROCEDURE TTypeflag*;
  VAR d: ARRAY 1 OF BYTE;
BEGIN
  d[0] := 0;
  writeOne("x.def", d, 1);
  Test.AssertInt(ORD("0"), b(TarType), "typeflag=regular file");
  cleanup
END TTypeflag;

(* ---- name field ---- *)

PROCEDURE TNameField*;
  VAR d: ARRAY 1 OF BYTE;
BEGIN
  d[0] := 0;
  writeOne("MyMod.rdf", d, 1);
  Test.AssertInt(ORD("M"), b(TarName + 0), "name[0]=M");
  Test.AssertInt(ORD("y"), b(TarName + 1), "name[1]=y");
  Test.AssertInt(ORD("M"), b(TarName + 2), "name[2]=M");
  Test.AssertInt(ORD("o"), b(TarName + 3), "name[3]=o");
  Test.AssertInt(ORD("d"), b(TarName + 4), "name[4]=d");
  Test.AssertInt(ORD("."), b(TarName + 5), "name[5]=.");
  Test.AssertInt(ORD("r"), b(TarName + 6), "name[6]=r");
  Test.AssertInt(ORD("d"), b(TarName + 7), "name[7]=d");
  Test.AssertInt(ORD("f"), b(TarName + 8), "name[8]=f");
  Test.AssertInt(0,        b(TarName + 9), "name[9]=NUL");
  cleanup
END TNameField;

(* ---- size field ---- *)

PROCEDURE TSizeField*;
  VAR d: ARRAY 100 OF BYTE; d5: ARRAY 5 OF BYTE; i: INTEGER;
BEGIN
  FOR i := 0 TO 99 DO d[i] := 0AAH END;
  writeOne("big.rdf", d, 100);
  Test.AssertLong(100, parseOctal(TarSize, 12), "size/100 bytes");
  cleanup;

  d5[0] := 1; d5[1] := 2; d5[2] := 3; d5[3] := 4; d5[4] := 5;
  writeOne("small.rdf", d5, 5);
  Test.AssertLong(5, parseOctal(TarSize, 12), "size/5 bytes");
  cleanup
END TSizeField;

(* ---- zero size ---- *)

PROCEDURE TZeroSize*;
  VAR d: ARRAY 1 OF BYTE;
BEGIN
  writeOne("empty.def", d, 0);
  Test.AssertLong(0, parseOctal(TarSize, 12), "zero/size field=0");
  Test.AssertLong(1536, BufLen, "zero/total=1536");  (* 512 + 1024 *)
  cleanup
END TZeroSize;

(* ---- checksum ---- *)

PROCEDURE TChecksum*;
  VAR d: ARRAY 4 OF BYTE; sum, stored: LONGINT; i: INTEGER;
BEGIN
  d[0] := 0DEH; d[1] := 0ADH; d[2] := 0BEH; d[3] := 0EFH;
  writeOne("chk.rdf", d, 4);
  sum := 0;
  FOR i := 0 TO 511 DO
    IF (i >= TarCksum) & (i < TarCksum + 8) THEN
      sum := sum + LONGINT(ORD(" "))
    ELSE
      sum := sum + LONGINT(b(i))
    END
  END;
  stored := parseOctal(TarCksum, 7);
  Test.AssertLong(stored, sum, "checksum/matches header");
  cleanup
END TChecksum;

(* ---- data follows header ---- *)

PROCEDURE TDataFollowsHeader*;
  VAR d: ARRAY 4 OF BYTE;
BEGIN
  d[0] := 0DEH; d[1] := 0ADH; d[2] := 0BEH; d[3] := 0EFH;
  writeOne("data.rdf", d, 4);
  Test.AssertInt(0DEH, b(512), "data[0]=DE");
  Test.AssertInt(0ADH, b(513), "data[1]=AD");
  Test.AssertInt(0BEH, b(514), "data[2]=BE");
  Test.AssertInt(0EFH, b(515), "data[3]=EF");
  cleanup
END TDataFollowsHeader;

(* ---- padding to 512 ---- *)

PROCEDURE TPaddingTo512*;
  VAR d: ARRAY 1 OF BYTE;
BEGIN
  d[0] := 055H;
  writeOne("p.rdf", d, 1);
  (* Total: 512 (hdr) + 512 (1 byte padded to 512) + 1024 (EOF) = 2048 *)
  Test.AssertLong(2048, BufLen, "pad/1-byte total=2048");
  Test.AssertInt(055H, b(512),  "pad/data byte ok");
  Test.AssertInt(0,    b(513),  "pad/first padding byte=0");
  Test.AssertInt(0,    b(1023), "pad/last padding byte=0");
  cleanup
END TPaddingTo512;

(* ---- padding 513 bytes ---- *)

PROCEDURE TPadding513*;
  VAR d: ARRAY 513 OF BYTE; i: INTEGER;
BEGIN
  FOR i := 0 TO 512 DO d[i] := 077H END;
  writeOne("p513.rdf", d, 513);
  Test.AssertLong(2560, BufLen, "pad/513 total=2560");
  Test.AssertInt(077H, b(512 + 512), "pad/513th byte ok");
  Test.AssertInt(0,    b(512 + 513), "pad/first pad after 513=0");
  cleanup
END TPadding513;

(* ---- EOF blocks ---- *)

PROCEDURE TEofBlocks*;
  VAR f: Files.File; ok, allZero: BOOLEAN; i: INTEGER;
BEGIN
  ok := Files.ReWrite(f, TmpTar);
  Tar.TarBegin(f);
  Tar.TarEnd(f);
  Files.Close(f);
  slurp;
  Test.AssertLong(1024, BufLen, "eof/two zero blocks=1024");
  allZero := TRUE;
  FOR i := 0 TO INTEGER(BufLen) - 1 DO
    IF b(i) # 0 THEN allZero := FALSE END
  END;
  Test.AssertTrue(allZero, "eof/all zero");
  cleanup
END TEofBlocks;

(* ---- two files ---- *)

PROCEDURE TTwoFiles*;
  VAR f: Files.File; ok: BOOLEAN;
      rdf: ARRAY 2 OF BYTE;
      def: ARRAY 9 OF BYTE;
BEGIN
  rdf[0] := 0ABH; rdf[1] := 0CDH;
  def[0] := ORD("M"); def[1] := ORD("O"); def[2] := ORD("D");
  def[3] := ORD("U"); def[4] := ORD("L"); def[5] := ORD("E");
  def[6] := ORD(" "); def[7] := ORD("X"); def[8] := 0AX;
  ok := Files.ReWrite(f, TmpTar);
  Tar.TarBegin(f);
  Tar.TarAddFile(f, "X.rdf", rdf, 2);
  Tar.TarAddFile(f, "X.def", def, 9);
  Tar.TarEnd(f);
  Files.Close(f);
  slurp;
  Test.AssertInt(ORD("X"), b(TarName + 0), "two/first name[0]");
  Test.AssertInt(ORD("."), b(TarName + 1), "two/first name[1]");
  Test.AssertInt(ORD("r"), b(TarName + 2), "two/first name[2]");
  Test.AssertInt(ORD("d"), b(TarName + 3), "two/first name[3]");
  Test.AssertInt(ORD("f"), b(TarName + 4), "two/first name[4]");
  Test.AssertInt(0,        b(TarName + 5), "two/first name[5]=NUL");
  Test.AssertInt(ORD("X"), b(1024 + TarName + 0), "two/second name[0]");
  Test.AssertInt(ORD("."), b(1024 + TarName + 1), "two/second name[1]");
  Test.AssertInt(ORD("d"), b(1024 + TarName + 2), "two/second name[2]");
  Test.AssertInt(ORD("e"), b(1024 + TarName + 3), "two/second name[3]");
  Test.AssertInt(ORD("f"), b(1024 + TarName + 4), "two/second name[4]");
  Test.AssertInt(0,        b(1024 + TarName + 5), "two/second name[5]=NUL");
  Test.AssertLong(3072, BufLen, "two/total=3072");
  cleanup
END TTwoFiles;

PROCEDURE RunAllTests*;
BEGIN
  TmpTar := "_t.LIB";
  Test.AddTest(TMagic,             "Tar/magic");
  Test.AddTest(TTypeflag,          "Tar/typeflag");
  Test.AddTest(TNameField,         "Tar/name");
  Test.AddTest(TSizeField,         "Tar/size");
  Test.AddTest(TZeroSize,          "Tar/zero-size");
  Test.AddTest(TChecksum,          "Tar/checksum");
  Test.AddTest(TDataFollowsHeader, "Tar/data-follows-header");
  Test.AddTest(TPaddingTo512,      "Tar/padding-to-512");
  Test.AddTest(TPadding513,        "Tar/padding-513");
  Test.AddTest(TEofBlocks,         "Tar/eof-blocks");
  Test.AddTest(TTwoFiles,          "Tar/two-files");
  Test.RunTests
END RunAllTests;

END TTAR.
