(*$D-*)
MODULE Files;

IMPORT EMS, Time;

CONST
  BUFSIZE = 8192;
  CopyChunk = 1024;  (* BlockCopy stack staging buffer — MUST stay small, see BlockCopy *)
  BkDisk = 0;
  BkEms  = 1;
  EmsChunkKB = 64;

TYPE
  FileBuf = ARRAY BUFSIZE OF CHAR;
  File* = RECORD
    handle     : INTEGER;
    name       : ARRAY 256 OF CHAR;
    buf        : POINTER TO FileBuf;
    bufTag     : LONGINT;
    bufSize    : WORD;
    bufPos     : WORD;
    delOnClose : BOOLEAN;
    dirty      : BOOLEAN;
    pos        : LONGINT;
    size       : LONGINT;
    backend    : INTEGER;
    emsHandle  : WORD;
    emsCap     : LONGINT
  END;

VAR
  tempSeq:  INTEGER;

PROCEDURE DOSGetFileSize(handle: INTEGER): LONGINT;
BEGIN
  RETURN SYSTEM.FSIZE(handle)
END DOSGetFileSize;

PROCEDURE CopyName(VAR F: File; VAR name: ARRAY OF CHAR);
  VAR n: WORD;
BEGIN
  (* name is a value param here at both call sites (Reset/ReWrite), so it can
     never alias F.name -> SYSTEM.MOVE is safe (non-overlapping). *)
  n := SYSTEM.LENGTH(name);
  IF n > WORD(255) THEN n := WORD(255) END;
  SYSTEM.MOVE(name[0], F.name[0], n);
  F.name[n] := 0X
END CopyName;

PROCEDURE EmsEnsureCap(VAR F: File; need: LONGINT): BOOLEAN;
  VAR newCap: LONGINT;
BEGIN
  IF need <= F.emsCap THEN RETURN TRUE END;
  newCap := F.emsCap;
  WHILE newCap < need DO INC(newCap, LONGINT(EmsChunkKB) * LONGINT(1024)) END;
  IF ~EMS.Realloc(F.emsHandle, WORD(newCap DIV LONGINT(1024))) THEN
    RETURN FALSE
  END;
  F.emsCap := newCap;
  RETURN TRUE
END EmsEnsureCap;

PROCEDURE BufFlush(VAR F: File);
BEGIN
  IF ~F.dirty THEN RETURN END;
  IF F.backend = BkEms THEN
    IF EmsEnsureCap(F, (F.bufTag + 1) * LONGINT(BUFSIZE)) THEN
      EMS.CopyToEMS(F.buf^, F.emsHandle, F.bufTag * BUFSIZE, WORD(BUFSIZE))
    END
  ELSE
    SYSTEM.FSEEK(F.handle, F.bufTag * BUFSIZE);
    SYSTEM.BLOCKWRITE(F.handle, F.buf^, F.bufSize);
  END;
  F.dirty := FALSE
END BufFlush;

PROCEDURE BufFetch(VAR F: File; tag: LONGINT);
  VAR avail, pageOfs: LONGINT;
BEGIN
  IF tag = F.bufTag THEN RETURN END;
  BufFlush(F);
  F.bufTag := tag;
  IF F.backend = BkEms THEN
    pageOfs := tag * BUFSIZE;
    IF pageOfs < F.emsCap THEN
      EMS.CopyToDos(F.emsHandle, pageOfs, F.buf^, WORD(BUFSIZE));
    END;
    avail := F.size - pageOfs;
    IF avail < 0 THEN avail := 0
    ELSIF avail > LONGINT(BUFSIZE) THEN avail := LONGINT(BUFSIZE)
    END;
    F.bufSize := WORD(avail)
  ELSE
    SYSTEM.FSEEK(F.handle, F.bufTag * BUFSIZE);
    F.bufSize := SYSTEM.BLOCKREAD(F.handle, F.buf^, WORD(BUFSIZE));
  END;
  F.dirty := FALSE
END BufFetch;

PROCEDURE BufInitEmpty(VAR F: File);
BEGIN
  F.bufTag := 0; F.bufSize := 0; F.bufPos := 0; F.dirty := FALSE; F.pos := 0
END BufInitEmpty;

PROCEDURE NextPage(VAR F: File);
BEGIN
  BufFetch(F, F.bufTag + 1);
  F.bufPos := 0
END NextPage;

PROCEDURE SeekTo(VAR F: File; pos: LONGINT);
BEGIN
  BufFetch(F, pos DIV BUFSIZE);
  F.bufPos := SYSTEM.AND(WORD(pos), BUFSIZE - 1);
  F.pos := pos
END SeekTo;

PROCEDURE Seek*(VAR F: File; pos: LONGINT);
BEGIN
  IF pos < 0 THEN pos := 0 END;
  IF pos > F.size THEN pos := F.size END;
  SeekTo(F, pos)
END Seek;

PROCEDURE AbsPos(VAR F: File): LONGINT;
BEGIN
  RETURN F.bufTag * BUFSIZE + F.bufPos
END AbsPos;

PROCEDURE SyncPos(VAR F: File; grow: BOOLEAN);
BEGIN
  F.pos := AbsPos(F);
  IF grow & (F.pos > F.size) THEN F.size := F.pos END
END SyncPos;

PROCEDURE ClampLen(VAR F: File; len: WORD): WORD;
  VAR rem: LONGINT;
BEGIN
  rem := F.size - AbsPos(F);
  IF rem < 0 THEN rem := 0 END;
  IF rem < len THEN RETURN WORD(rem) END;
  RETURN len
END ClampLen;

PROCEDURE BlockRead*(VAR F: File; VAR x; len: WORD): WORD;
  VAR total, delta, avail: WORD; dest: SYSTEM.ADDRESS;
BEGIN
  len := ClampLen(F, len);
  IF len = 0 THEN RETURN 0 END;
  total := 0;
  dest := x;
  WHILE total < len DO
    avail := F.bufSize - F.bufPos;
    IF avail = 0 THEN
      NextPage(F);
      IF F.bufSize = 0 THEN SyncPos(F, FALSE); RETURN total END;
      avail := F.bufSize
    END;
    delta := len - total;
    IF delta > avail THEN delta := avail END;
    SYSTEM.MOVE(F.buf^[F.bufPos], dest^[total], delta);
    INC(F.bufPos, delta);
    INC(total, delta)
  END;
  SyncPos(F, FALSE);
  RETURN total
END BlockRead;

PROCEDURE BlockWrite*(VAR F: File; VAR x; len: WORD): WORD;
  VAR total, delta, room: WORD; src: SYSTEM.ADDRESS;
BEGIN
  IF len = 0 THEN RETURN 0 END;
  total := 0;
  src := x;
  (* SYSTEM2 hot loop: pure WORD *)
  WHILE total < len DO
    room := WORD(BUFSIZE) - F.bufPos;
    IF room = 0 THEN
      SyncPos(F, TRUE);
      NextPage(F); room := WORD(BUFSIZE)
    END;
    delta := len - total;
    IF delta > room THEN delta := room END;
    SYSTEM.MOVE(src^[total], F.buf^[F.bufPos], delta);
    F.dirty := TRUE;
    INC(F.bufPos, delta);
    IF F.bufPos > F.bufSize THEN F.bufSize := F.bufPos END;
    INC(total, delta)
  END;
  SyncPos(F, TRUE);
  RETURN total
END BlockWrite;

PROCEDURE WriteByte*(VAR F: File; b: BYTE) : WORD;
BEGIN
  IF F.bufPos = WORD(BUFSIZE) THEN NextPage(F) END;
  F.buf^[F.bufPos] := CHR(b);
  F.dirty := TRUE;
  INC(F.bufPos);
  IF F.bufPos > F.bufSize THEN
    F.bufSize := F.bufPos;
    SyncPos(F, TRUE)
  END;
  RETURN 1
END WriteByte;

PROCEDURE WriteWord*(VAR F: File; w: INTEGER) : WORD;
BEGIN
  IF F.bufPos <= WORD(BUFSIZE - 2) THEN
    (* both bytes in the current page: two direct WORD-indexed stores *)
    F.buf^[F.bufPos]     := CHR(SYSTEM.AND(w, 0FFH));
    F.buf^[F.bufPos + 1] := CHR(SYSTEM.AND(SYSTEM.LSR(w, 8), 0FFH));
    F.dirty := TRUE;
    INC(F.bufPos, 2);
    IF F.bufPos > F.bufSize THEN
      F.bufSize := F.bufPos;
      SyncPos(F, TRUE)
    END
  ELSE
    WriteByte(F, BYTE(SYSTEM.AND(w, 0FFH)));
    WriteByte(F, BYTE(SYSTEM.AND(SYSTEM.LSR(w, 8), 0FFH)))
  END;
  RETURN 2
END WriteWord;

PROCEDURE WriteDWord*(VAR F: File; w: LONGINT) : WORD;
BEGIN
  IF F.bufPos <= WORD(BUFSIZE - 4) THEN
    (* both bytes in the current page: two direct WORD-indexed stores *)
    F.buf^[F.bufPos]     := CHR(SYSTEM.AND(w, 0FFH));
    F.buf^[F.bufPos + 1] := CHR(SYSTEM.AND(SYSTEM.LSR(w, 8), 0FFH));
    F.buf^[F.bufPos + 2] := CHR(SYSTEM.AND(SYSTEM.LSR(w, 16), 0FFH));
    F.buf^[F.bufPos + 3] := CHR(SYSTEM.AND(SYSTEM.LSR(w, 24), 0FFH));
    F.dirty := TRUE;
    INC(F.bufPos, 4);
    IF F.bufPos > F.bufSize THEN
      F.bufSize := F.bufPos;
      SyncPos(F, TRUE)
    END
  ELSE
    WriteByte(F, BYTE(SYSTEM.AND(w, 0FFH)));
    WriteByte(F, BYTE(SYSTEM.AND(SYSTEM.LSR(w, 8), 0FFH)));
    WriteByte(F, BYTE(SYSTEM.AND(SYSTEM.LSR(w, 16), 0FFH)));
    WriteByte(F, BYTE(SYSTEM.AND(SYSTEM.LSR(w, 24), 0FFH)))
  END;
  RETURN 4
END WriteDWord;

PROCEDURE ReadByte*(VAR F: File; VAR b: BYTE) : BOOLEAN;
BEGIN
  IF F.bufPos >= F.bufSize THEN
    NextPage(F);
    IF F.bufSize = 0 THEN b := BYTE(0); RETURN FALSE END
  END;
  b := BYTE(F.buf^[F.bufPos]);
  INC(F.bufPos);
  RETURN TRUE
END ReadByte;

PROCEDURE ReadWord*(VAR F: File; VAR w: INTEGER);
  VAR lo, hi: BYTE;
BEGIN
  IF F.bufPos + 1 < F.bufSize THEN
    w := SYSTEM.IOR(WORD(BYTE(F.buf^[F.bufPos])),
                    SYSTEM.LSL(WORD(BYTE(F.buf^[F.bufPos + 1])), 8));
    INC(F.bufPos, 2)
  ELSE
    ReadByte(F, lo); ReadByte(F, hi);
    w := SYSTEM.IOR(WORD(lo), SYSTEM.LSL(WORD(hi), 8))
  END
END ReadWord;

PROCEDURE ReadDWord*(VAR F: File; VAR w: LONGINT);
  VAR w1, w2: INTEGER;
BEGIN
  IF F.bufPos + 3 < F.bufSize THEN
    w1 := SYSTEM.IOR(WORD(BYTE(F.buf^[F.bufPos])),
                    SYSTEM.LSL(WORD(BYTE(F.buf^[F.bufPos + 1])), 8));
    w2 := SYSTEM.IOR(WORD(BYTE(F.buf^[F.bufPos+2])),
                    SYSTEM.LSL(WORD(BYTE(F.buf^[F.bufPos + 3])), 8));
    INC(F.bufPos, 4)
  ELSE
    ReadWord(F, w1); ReadWord(F, w2)
  END;
  w := SYSTEM.IOR(LONGINT(WORD(w1)), SYSTEM.LSL(LONGINT(w2), 16))
END ReadDWord;

PROCEDURE ReadAsciizString*(VAR f: File; VAR dst: ARRAY OF CHAR);
  VAR i: INTEGER; b: BYTE;
BEGIN
  i := 0;
  WHILE ReadByte(f, b) & (b # BYTE(0)) DO
    IF i < LEN(dst) - 1 THEN dst[i] := CHR(INTEGER(b)); INC(i) END
  END;
  dst[i] := 0X
END ReadAsciizString;

PROCEDURE ReadLine*(VAR f: File; VAR buf: ARRAY OF CHAR; maxLen: WORD): WORD;
  VAR b: BYTE; n, len: WORD;
BEGIN
  len := 0;
  IF ReadByte(f, b) THEN n := 1 ELSE n := 0 END;
  WHILE n > 0 DO
    IF b = 0DH THEN
      IF ReadByte(f, b) THEN n := 1 ELSE n := 0 END;
    ELSIF b = 0AH THEN
      n := 0
    ELSE
      IF len < maxLen - 1 THEN buf[len] := CHR(b); INC(len) END;
      n := 1;
      ReadByte(f, b)
    END
  END;
  buf[len] := 0X;
  RETURN len
END ReadLine;

PROCEDURE WriteLn*(VAR f: File) : WORD;
BEGIN
  RETURN WriteWord(f, 0A0DH)
END WriteLn;

PROCEDURE Write*(VAR f: File; line: ARRAY OF CHAR) : WORD;
BEGIN
  RETURN BlockWrite(f, line, SYSTEM.LENGTH(line));
END Write;

PROCEDURE WriteLine*(VAR f: File; line: ARRAY OF CHAR) : WORD;
VAR w : WORD;
BEGIN
  w := Write(f, line);
  INC(w, WriteLn(f));
  RETURN w
END WriteLine;

PROCEDURE Position*(VAR F: File): LONGINT;
BEGIN
  (* derive from the WORD cursor — F.pos is only kept fresh on growth/block ops *)
  IF F.bufTag = -1 THEN RETURN F.pos END;
  RETURN AbsPos(F)
END Position;

PROCEDURE Size*(VAR F: File): LONGINT;
BEGIN
  RETURN F.size
END Size;

PROCEDURE Truncate*(VAR F: File);
  VAR pos, pageBase: LONGINT;
BEGIN
  pos := Position(F);
  BufFlush(F);
  IF F.bufTag # -1 THEN
    pageBase := F.bufTag * BUFSIZE;
    IF pos > pageBase THEN
      F.bufSize := WORD(pos - pageBase)
    ELSE
      F.bufSize := 0
    END
  END;
  F.size := pos;
  IF F.backend # BkEms THEN
    SYSTEM.FSEEK(F.handle, pos);
    SYSTEM.BLOCKWRITE(F.handle, F.buf^, 0);
  END
END Truncate;

PROCEDURE Reset*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  F.handle := -1;
  F.buf := NIL;
  F.backend := BkDisk;
  CopyName(F, name);
  F.delOnClose := FALSE;
  r.Flags := 0; r.ES := 0;
  r.AX := 3D02H;
  r.DS := SYSTEM.SEG(name);
  r.DX := SYSTEM.OFS(name);
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0 THEN
    F.handle := r.AX
  END;
  IF F.handle = -1 THEN
    F.pos := 0; F.size := -1; RETURN FALSE
  END;
  NEW(F.buf);
  IF F.buf = NIL THEN
     SYSTEM.FCLOSE(F.handle);
     F.handle := -1;
     RETURN FALSE
  END;
  F.bufTag := -1;
  F.bufSize := 0;
  F.bufPos := 0;
  F.dirty := FALSE;
  F.pos := 0;
  F.size := DOSGetFileSize(F.handle);
  F.backend := BkDisk;
  IF F.size > 0 THEN
    BufFetch(F, LONGINT(0)); F.bufPos := 0
  ELSE
    BufInitEmpty(F)
  END;
  RETURN TRUE
END Reset;

PROCEDURE ReWrite*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  F.handle := -1;
  F.buf := NIL;
  F.backend := BkDisk;
  CopyName(F, name);
  F.delOnClose := FALSE;
  r.Flags := 0; r.ES := 0;
  r.AX := 3C00H;
  r.CX := 0;
  r.DS := SYSTEM.SEG(name);
  r.DX := SYSTEM.OFS(name);
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0 THEN
    F.handle := r.AX
  END;
  IF F.handle = -1 THEN
    F.pos := 0; F.size := -1; RETURN FALSE
  END;
  NEW(F.buf);
  IF F.buf = NIL THEN
     SYSTEM.FCLOSE(F.handle);
     F.handle := -1;
     RETURN FALSE
  END;
  F.bufTag := -1;
  F.bufSize := 0;
  F.bufPos := 0;
  F.dirty := FALSE;
  F.pos := 0;
  F.size := 0;
  F.backend := BkDisk;
  Truncate(F);
  BufInitEmpty(F);
  RETURN TRUE
END ReWrite;

PROCEDURE Append*(VAR F: File; name: ARRAY OF CHAR): BOOLEAN;
BEGIN
  IF Reset(F, name) THEN
    Seek(F, Size(F))
  ELSE
    RETURN ReWrite(F, name)
  END;
  RETURN TRUE
END Append;

PROCEDURE MakeTempName(VAR dst: ARRAY OF CHAR);
  VAR i: INTEGER; v: LONGINT;
BEGIN
  INC(tempSeq);
  v := LONGINT(tempSeq);
  i := 0; WHILE i < 8 DO dst[7 - i] := CHR(ORD("0") + INTEGER(v MOD LONGINT(10))); v := v DIV LONGINT(10); INC(i) END;
  dst[8] := "."; dst[9] := "T"; dst[10] := "M"; dst[11] := "P"; dst[12] := 0X
END MakeTempName;

PROCEDURE ReWriteTemp*(VAR F: File): BOOLEAN;
  VAR name: ARRAY 16 OF CHAR; ok: BOOLEAN; handle: WORD;
BEGIN
  IF EMS.Present() & EMS.Alloc(WORD(EmsChunkKB), handle) THEN
    F.handle := -1;
    NEW(F.buf);
    IF F.buf = NIL THEN ok := EMS.Free(handle); RETURN FALSE END;
    F.name[0] := 0X;
    F.delOnClose := FALSE;
    F.bufTag := -1;
    F.bufSize := 0;
    F.bufPos := 0;
    F.dirty := FALSE;
    F.pos := 0;
    F.size := 0;
    F.backend := BkEms;
    F.emsHandle := handle;
    F.emsCap := LONGINT(EmsChunkKB) * LONGINT(1024);
    BufInitEmpty(F);
    RETURN TRUE
  END;
  MakeTempName(name);
  ok := ReWrite(F, name);
  IF ok THEN F.delOnClose := TRUE END;
  RETURN ok
END ReWriteTemp;

PROCEDURE Delete*(FileName: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 7141H;
  r.CX := 0;
  r.SI := 0;
  r.DS := SYSTEM.SEG(FileName);
  r.DX := SYSTEM.OFS(FileName);
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN
    r.AX := 4100H;
    r.DS := SYSTEM.SEG(FileName);
    r.DX := SYSTEM.OFS(FileName);
    SYSTEM.Intr(21H, r)
  END;
  RETURN SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0
END Delete;

PROCEDURE SetDeleteOnClose*(VAR F: File; delOnClose : BOOLEAN);
BEGIN
  F.delOnClose := delOnClose
END SetDeleteOnClose;

PROCEDURE Close*(VAR F: File);
BEGIN
  IF F.backend = BkEms THEN
    EMS.Free(F.emsHandle);
    F.backend := BkDisk;
    F.emsHandle := 0;
    F.emsCap := 0;
    F.size := 0; F.pos := 0
  ELSIF F.handle # -1 THEN
    BufFlush(F);
    SYSTEM.FCLOSE(F.handle);
    F.handle := -1;
    IF F.delOnClose THEN Delete(F.name) END
  END;
  IF F.buf # NIL THEN
    DISPOSE(F.buf);
    F.buf := NIL
  END
END Close;

PROCEDURE Rename*(OldName, NewName: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 5600H;
  r.DS := SYSTEM.SEG(OldName);
  r.DX := SYSTEM.OFS(OldName);
  r.ES := SYSTEM.SEG(NewName);
  r.DI := SYSTEM.OFS(NewName);
  SYSTEM.Intr(21H, r);
  RETURN SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0
END Rename;

(* BlockCopy's staging buffer is deliberately SMALL (CopyChunk): it lives on
   the stack, and tools linked with the default 8192-byte stack ($M absent)
   MUST NOT carry a multi-KB frame here — an 8 KB frame wraps SP around 64K
   and sprays the copied bytes over the heap (see DOCS/IMPLRULE.MD §"Stack
   size and big stack frames").  Both files are 8 KB-buffered internally, so
   a small staging chunk costs almost nothing. *)
PROCEDURE BlockCopy*(VAR src, dst: File; len : LONGINT): BOOLEAN;
  VAR buf: ARRAY CopyChunk OF BYTE;
      n: WORD;
BEGIN
  WHILE len # 0 DO
    IF len > CopyChunk THEN n := CopyChunk ELSE n := len END;
    n := BlockRead(src, buf[0], n);
    IF n # 0 THEN
      IF BlockWrite(dst, buf[0], n) # n THEN RETURN FALSE END;
      DEC(len, n)
    ELSE
      RETURN FALSE
    END
  END;
  RETURN TRUE
END BlockCopy;

PROCEDURE Copy*(src, dst: ARRAY OF CHAR): BOOLEAN;
  VAR fSrc, fDst: File;
      res : BOOLEAN;
BEGIN
  IF ~Reset(fSrc, src) THEN RETURN FALSE END;
  IF ~ReWrite(fDst, dst) THEN Close(fSrc); RETURN FALSE END;
  res := BlockCopy(fSrc, fDst, Size(fSrc));
  Close(fSrc); Close(fDst); RETURN res
END Copy;

(* Build dst = path with its extension (the part from the last "." after the
   last path separator) replaced by newExt (e.g. "OSTRIP.OM" + ".BAK" ->
   "OSTRIP.BAK") — keeps 8.3 names valid (no double extension). If path has
   no extension, newExt is simply appended. *)
PROCEDURE ReplaceExt*(path: ARRAY OF CHAR; newExt: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
  VAR i, dot, sep: INTEGER; extLen: WORD;
BEGIN
  (* The dot/sep scan tests 4 distinct byte values per position, not a single
     byte -> not a FINDBYTE candidate; kept as a manual loop. *)
  dot := -1; sep := -1; i := 0;
  WHILE path[i] # 0X DO
    IF path[i] = "." THEN dot := i
    ELSIF (path[i] = "/") OR (path[i] = "\") OR (path[i] = ":") THEN sep := i
    END;
    INC(i)
  END;
  IF dot <= sep THEN dot := i END;
  (* path/newExt are value params, dst is a separate VAR param -> non-aliased,
     SYSTEM.MOVE is safe for both straight-line copies. *)
  SYSTEM.MOVE(path[0], dst[0], WORD(dot));
  extLen := SYSTEM.LENGTH(newExt);
  SYSTEM.MOVE(newExt[0], dst[dot], extLen);
  dst[dot + INTEGER(extLen)] := 0X
END ReplaceExt;

PROCEDURE FileExists*(FileName: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers; buf: ARRAY 320 OF CHAR; oldES, oldBX: INTEGER; ok: BOOLEAN;
BEGIN
  r.AX := 714EH;
  r.CX := 0;
  r.DS := SYSTEM.SEG(FileName);
  r.DX := SYSTEM.OFS(FileName);
  r.ES := SYSTEM.SEG(buf);
  r.DI := SYSTEM.OFS(buf);
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);

  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0 THEN RETURN TRUE END;
  IF r.AX # 7100H THEN RETURN FALSE END;

  r.AX := 2F00H;
  SYSTEM.Intr(21H, r);
  oldES := r.ES;
  oldBX := r.BX;

  r.AX := 1A00H;
  r.DS := SYSTEM.SEG(buf);
  r.DX := SYSTEM.OFS(buf);
  SYSTEM.Intr(21H, r);

  r.AX := 4E00H;
  r.CX := 0;
  r.DS := SYSTEM.SEG(FileName);
  r.DX := SYSTEM.OFS(FileName);
  SYSTEM.Intr(21H, r);

  ok := SYSTEM.AND(r.Flags, SYSTEM.FCarry) = 0;

  r.AX := 1A00H;
  r.DS := oldES;
  r.DX := oldBX;
  SYSTEM.Intr(21H, r);

  RETURN ok
END FileExists;

PROCEDURE GetFTime*(VAR f : File; VAR time : Time.DosTime);
  VAR r: SYSTEM.Registers;

BEGIN
  time := 0;
  IF f.backend # BkDisk THEN RETURN END;
  r.BX := f.handle;
  r.AX := 5700H;
  SYSTEM.Intr(21H, r);
  time := SYSTEM.IOR(LONGINT(SYSTEM.LSL(LONGINT(WORD(r.DX)), 16)), LONGINT(WORD(r.CX)))
END GetFTime;

PROCEDURE SetFTime*(VAR f : File; time : Time.DosTime);
  VAR r: SYSTEM.Registers;
BEGIN
  IF f.backend # BkDisk THEN RETURN END;
  r.BX := f.handle;
  r.AX := 5701H;
  r.DX := SYSTEM.LSR(time, 16);
  r.CX := SYSTEM.AND(time, 0FFFFH);
  SYSTEM.Intr(21H, r);
END SetFTime;

BEGIN
  tempSeq := 0
END Files.
