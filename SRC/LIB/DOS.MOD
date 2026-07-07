(*$R-*)(*$D-*)
MODULE Dos;

CONST

ReadOnly*  = 01H;
Hidden*    = 02H;
SysFile*   = 04H;
VolumeID*  = 08H;
Directory* = 10H;
Archive*   = 20H;
AnyFile*   = 3FH;

STDIN*  = 0;
STDOUT* = 1;
STDERR* = 2;
STDPRN* = 4;
STDAUX* = 5;


TYPE
Registers* = SYSTEM.Registers;

DateTime* = RECORD
    Year*, Month*, Day*, Hour*, Min*, Sec*: INTEGER;
END;

(* DOS Exec parameter block (EPB) for INT 21h / 4B00h "Load and Execute".
   Layout is fixed by DOS: 14 bytes, all WORD fields, no padding. *)
ExecPB = RECORD
  envSeg : WORD;                       (* 00H: 0 = inherit parent's env *)
  tailOfs, tailSeg : WORD;             (* 02H: ptr to command-tail block *)
  fcb1Ofs, fcb1Seg : WORD;             (* 06H: ptr to FCB 1 *)
  fcb2Ofs, fcb2Seg : WORD;             (* 0AH: ptr to FCB 2 *)
END;

(* SearchRec layout mirrors the DOS DTA after INT 21h / 4Eh / 4Fh.
   The first 21 bytes are reserved for DOS's per-search bookkeeping and
   must round-trip unchanged between FindFirst and successive FindNext
   calls (DOS stuffs the search handle, attribute mask, etc. in there).
   Field offsets and meanings match Turbo Pascal's Dos.SearchRec. *)
(*$A-*)
SearchRec* = RECORD
  fill*: ARRAY 21 OF BYTE;             (* 00H..14H: DOS reserved *)
  attr*: BYTE;                         (* 15H: file attribute byte *)
  time*: LONGINT;                      (* 16H..19H: packed FAT time/date *)
  size*: LONGINT;                      (* 1AH..1DH: file size in bytes *)
  name*: ARRAY 13 OF CHAR;             (* 1EH..2AH: ASCIIZ basename *)
END;

VAR
DosError*    : WORD;     (* last DOS API result (0 = ok, else INT 21h error code) —
                            updated by Exec; matches Turbo Pascal Dos.DosError. *)
DosExitCode* : WORD;     (* child's exit status from last Exec — low byte is the
                            INT 21h/4Ch code the child supplied, high byte is the
                            termination type (0=normal, 1=Ctrl-C, 2=critical err,
                            3=TSR).  Matches Turbo Pascal Dos.DosExitCode. *)

PROCEDURE Intr*(IntNo: BYTE; VAR Regs: Registers);
BEGIN
    SYSTEM.Intr(IntNo, Regs);
END Intr;

PROCEDURE MsDos*(VAR Regs: Registers);
BEGIN
    SYSTEM.Intr(21H, Regs)
END MsDos;

VAR
    argBuf   : ARRAY 200 OF CHAR;
    argOfs   : ARRAY 32 OF INTEGER;
    argCount : INTEGER;

PROCEDURE ReadByte(seg, ofs: INTEGER): CHAR;
VAR
    p : POINTER TO CHAR;
BEGIN
    p := SYSTEM.PTR(seg, ofs);
    RETURN p^
END ReadByte;

PROCEDURE GetPsp*:INTEGER;
VAR
    regs    : SYSTEM.Registers;
BEGIN
    regs.AX := 6200H;
    SYSTEM.Intr(21H, regs);
    RETURN regs.BX;
END GetPsp;

PROCEDURE ArgInit;
VAR
    psp     : INTEGER;
    len     : INTEGER;
    pos     : INTEGER;
    ai      : INTEGER;
    bi      : INTEGER;
    ch      : CHAR;
    inQuote : BOOLEAN;
    inArg   : BOOLEAN;
BEGIN
    psp  := GetPsp();
    len  := ORD(ReadByte(psp, 80H));
    IF len = 0 THEN
        argCount := 0;
        RETURN
    END;

    pos     := 0;
    inQuote := FALSE;
    inArg   := FALSE;
    ai      := 1;
    bi      := 1;
    argCount := 0;

    WHILE (pos < len) & (ai < 32) DO
        ch := ReadByte(psp, 81H + pos);
        INC(pos);

        IF ch = 22X THEN
            IF inQuote THEN
                inQuote := FALSE
            ELSE
                IF ~inArg THEN
                    argOfs[ai] := bi;
                    inArg := TRUE
                END;
                inQuote := TRUE
            END
        ELSIF (ch = ' ') OR (ch = 9X) THEN
            IF inQuote THEN
                IF bi < 199 THEN
                    argBuf[bi] := ch; INC(bi)
                END
            ELSIF inArg THEN
                IF bi < 199 THEN
                    argBuf[bi] := 0X; INC(bi)
                END;
                INC(ai); INC(argCount);
                inArg := FALSE
            END
        ELSE
            IF ~inArg THEN
                argOfs[ai] := bi;
                inArg := TRUE
            END;
            IF bi < 199 THEN
                argBuf[bi] := ch; INC(bi)
            END
        END
    END;

    IF inArg & (ai < 32) THEN
        IF bi < 199 THEN
            argBuf[bi] := 0X
        END;
        INC(argCount)
    END
END ArgInit;

PROCEDURE ParamCount*: INTEGER;
BEGIN
    RETURN argCount
END ParamCount;

PROCEDURE ParamStr*(i: INTEGER; VAR p: ARRAY OF CHAR);
    VAR src, dst, envseg, ofs : INTEGER; ch : CHAR;
BEGIN
    IF i = 0 THEN
        (* Argv[0] = EXE filename, retrieved from PSP environment block. *)
        dst := 0;
        envseg := ORD(ReadByte(GetPsp(), 2CH)) + ORD(ReadByte(GetPsp(), 2DH)) * 256;
        IF envseg = 0 THEN
            p[0] := 0X;
            RETURN
        END;
        ofs := 0;
        WHILE ReadByte(envseg, ofs) # 0X DO
            WHILE ReadByte(envseg, ofs) # 0X DO INC(ofs) END;
            INC(ofs)
        END;
        (* now at the empty-string marker (single 0 byte) — skip it *)
        INC(ofs);
        (* now at the 2-byte program-string count (always 1 under DOS 3.0+) *)
        INC(ofs, 2);
        (* now at the ASCIIZ program-name *)
        ch := ReadByte(envseg, ofs);
        WHILE (ch # 0X) & (dst < LEN(p) - 1) DO
            p[dst] := ch; INC(dst); INC(ofs);
            ch := ReadByte(envseg, ofs)
        END;
        p[dst] := 0X
    ELSE
        dst := 0;
        IF (i >= 1) & (i <= argCount) THEN
            src := argOfs[i];
            ch := argBuf[src];
            WHILE ch # 0X DO
                IF dst < LEN(p) - 1 THEN
                    p[dst] := ch;
                    INC(dst)
                END;
                INC(src);
                ch := argBuf[src]
            END
        END;
        p[dst] := 0X
    END
END ParamStr;

PROCEDURE GetEnv*(envvar: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR
    envseg : INTEGER;
    ofs    : INTEGER;
    ei     : INTEGER;
    di     : INTEGER;
    ch     : CHAR;
    match  : BOOLEAN;
    pw     : POINTER TO WORDD;
BEGIN
    dst[0] := 0X;
    pw := SYSTEM.PTR(GetPsp(), 2CH);
    envseg := pw^;
    IF envseg = 0 THEN RETURN END;

    ofs := 0;
    WHILE ReadByte(envseg, ofs) # 0X DO
        ei := 0;
        match := TRUE;
        ch := ReadByte(envseg, ofs);
        WHILE (ch # '=') & (ch # 0X) DO
            IF (ei < LEN(envvar) - 1) & match THEN
                match := SYSTEM.UCASE(ch) = SYSTEM.UCASE(envvar[ei]);
                INC(ei)
            ELSE
                match := FALSE
            END;
            INC(ofs);
            ch := ReadByte(envseg, ofs)
        END;
        IF match & (envvar[ei] = 0X) & (ch = '=') THEN
            INC(ofs);
            di := 0;
            ch := ReadByte(envseg, ofs);
            WHILE ch # 0X DO
                IF di < LEN(dst) - 1 THEN
                    dst[di] := ch; INC(di)
                END;
                INC(ofs);
                ch := ReadByte(envseg, ofs)
            END;
            dst[di] := 0X;
            RETURN
        END;
        WHILE ReadByte(envseg, ofs) # 0X DO INC(ofs) END;
        INC(ofs)
    END
END GetEnv;

PROCEDURE GetDTA*: SYSTEM.ADDRESS;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2F00H;
  SYSTEM.Intr(21H, r);
  RETURN SYSTEM.PTR(r.ES, r.BX)
END GetDTA;

PROCEDURE SetDTA*(dta : SYSTEM.ADDRESS);
  VAR r: SYSTEM.Registers; p : POINTER TO CHAR;
BEGIN
  p := dta;
  r.AX := 1A00H;
  r.DS := SYSTEM.SEG(p^);
  r.DX := SYSTEM.OFS(p^);
  SYSTEM.Intr(21H, r)
END SetDTA;

(* FindFirst: locate the first directory entry matching `Path` (DOS-style
   wildcards `*` and `?` allowed) whose attribute is `Attr`-compatible
   (use AnyFile to match every file).  The result lives in `S` and is
   self-contained: subsequent FindNext calls re-use it without an
   explicit DTA argument.  Sets DosError to 0 on success or to the
   INT 21h failure code (typically 02 = file not found, 12H = no more
   files for FindNext).  Matches Turbo Pascal's Dos.FindFirst semantics. *)
PROCEDURE FindFirst*(Path: ARRAY OF CHAR; Attr: BYTE; VAR S: SearchRec);
  VAR r: SYSTEM.Registers;
      pathz: ARRAY 80 OF CHAR;
      i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(pathz) - 1) & (Path[i] # 0X) DO
    pathz[i] := Path[i]; INC(i)
  END;
  pathz[i] := 0X;
  (* Point DOS's DTA at our SearchRec so the result lands inside it. *)
  r.AX := 1A00H;
  r.DS := SYSTEM.SEG(S);
  r.DX := SYSTEM.OFS(S);
  SYSTEM.Intr(21H, r);
  (* INT 21h / 4Eh: AX=4E00, DS:DX = ASCIIZ pattern, CX = attribute mask. *)
  r.AX := 4E00H;
  r.CX := Attr;
  r.DS := SYSTEM.SEG(pathz);
  r.DX := SYSTEM.OFS(pathz);
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN DosError := r.AX
  ELSE DosError := 0
  END
END FindFirst;

(* FindNext: continue a search opened by FindFirst.  The same SearchRec
   must be passed and unmodified between calls — DOS keeps its search
   state in `S.fill`.  Sets DosError to 12H when no more entries match. *)
PROCEDURE FindNext*(VAR S: SearchRec);
  VAR r: SYSTEM.Registers;
BEGIN
  (* DTA must still point at S.  We re-set it defensively in case the
     caller (or a child process via Exec) clobbered it. *)
  r.AX := 1A00H;
  r.DS := SYSTEM.SEG(S);
  r.DX := SYSTEM.OFS(S);
  SYSTEM.Intr(21H, r);
  r.AX := 4F00H;
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN DosError := r.AX
  ELSE DosError := 0
  END
END FindNext;

(* MkDir: create a directory.  Returns TRUE on success, FALSE if the
   directory already exists or cannot be created.  Sets DosError. *)
PROCEDURE MkDir*(Path: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers; pathz: ARRAY 80 OF CHAR; i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(pathz) - 1) & (Path[i] # 0X) DO
    pathz[i] := Path[i]; INC(i)
  END;
  pathz[i] := 0X;
  r.AX := 3900H;
  r.DS := SYSTEM.SEG(pathz);
  r.DX := SYSTEM.OFS(pathz);
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN
    DosError := r.AX; RETURN FALSE
  END;
  DosError := 0; RETURN TRUE
END MkDir;

(* ChDir: change current directory.  Returns TRUE on success.  Sets
   DosError. *)
PROCEDURE ChDir*(Path: ARRAY OF CHAR): BOOLEAN;
  VAR r: SYSTEM.Registers; pathz: ARRAY 80 OF CHAR; i: INTEGER;
BEGIN
  i := 0;
  WHILE (i < LEN(pathz) - 1) & (Path[i] # 0X) DO
    pathz[i] := Path[i]; INC(i)
  END;
  pathz[i] := 0X;
  r.AX := 3B00H;
  r.DS := SYSTEM.SEG(pathz);
  r.DX := SYSTEM.OFS(pathz);
  r.Flags := SYSTEM.FCarry;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN
    DosError := r.AX; RETURN FALSE
  END;
  DosError := 0; RETURN TRUE
END ChDir;

PROCEDURE GetDate*(VAR Year,Month,Day,DayOfWeek: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2A00H;
  SYSTEM.Intr(21H, r);
  Year := r.CX;
  Month := ORD(SYSTEM.LSR(r.DX, 8));
  Day := r.DX MOD 256;
  DayOfWeek := r.AX MOD 256
END GetDate;

PROCEDURE SetDate*(Year,Month,Day: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2B00H;
  r.CX := Year;
  r.DX := Day + SYSTEM.LSL(Month, 8);
  SYSTEM.Intr(21H, r)
END SetDate;

PROCEDURE GetTime*(VAR Hour,Minute,Second,Sec100: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2C00H;
  SYSTEM.Intr(21H, r);
  Hour := ORD(SYSTEM.LSR(r.CX, 8));
  Minute := r.CX MOD 256;
  Second := ORD(SYSTEM.LSR(r.DX, 8));
  Sec100 := r.DX MOD 256
END GetTime;

PROCEDURE SetTime*(Hour,Minute,Second,Sec100: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2D00H;
  r.CX := Minute + SYSTEM.LSL(Hour, 8);
  r.DX := Sec100 + SYSTEM.LSL(Second, 8);
  SYSTEM.Intr(21H, r)
END SetTime;

PROCEDURE GetCBreak*(VAR Break: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3300H;
  SYSTEM.Intr(21H, r);
  Break := (r.DX MOD 256) # 0
END GetCBreak;

PROCEDURE SetCBreak*(Break: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3301H;
  IF Break THEN r.DX := 1 ELSE r.DX := 0 END;
  SYSTEM.Intr(21H, r)
END SetCBreak;

PROCEDURE GetVerify*(VAR Verify: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 5400H;
  SYSTEM.Intr(21H, r);
  Verify := (r.AX MOD 256) # 0
END GetVerify;

PROCEDURE SetVerify*(Verify: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2E00H;
  IF Verify THEN r.DX := 1 ELSE r.DX := 0 END;
  SYSTEM.Intr(21H, r)
END SetVerify;

PROCEDURE DiskFree*(Drive: BYTE): LONGINT;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3600H;
  r.DX := Drive;
  SYSTEM.Intr(21H, r);
  IF r.AX = 0FFFFH THEN RETURN -1 END;
  RETURN LONGINT(r.AX) * LONGINT(r.BX) * LONGINT(r.CX)
END DiskFree;

PROCEDURE DiskSize*(Drive: BYTE): LONGINT;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3600H;
  r.DX := Drive;
  SYSTEM.Intr(21H, r);
  IF r.AX = 0FFFFH THEN RETURN -1 END;
  RETURN LONGINT(r.AX) * LONGINT(r.CX) * LONGINT(r.DX)
END DiskSize;

PROCEDURE GetIntVec*(IntNo: BYTE; VAR Vector: SYSTEM.ADDRESS);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3500H + IntNo;
  SYSTEM.Intr(21H, r);
  Vector := SYSTEM.PTR(r.ES, r.BX)
END GetIntVec;

PROCEDURE SetIntVec*(IntNo: BYTE; Vector: SYSTEM.ADDRESS);
  VAR r: SYSTEM.Registers; p: POINTER TO CHAR;
BEGIN
  p := Vector;
  r.AX := 2500H + IntNo;
  r.DS := SYSTEM.SEG(p^);
  r.DX := SYSTEM.OFS(p^);
  SYSTEM.Intr(21H, r)
END SetIntVec;

PROCEDURE FExpand*(Path: ARRAY OF CHAR; VAR Dest : ARRAY OF CHAR);
  VAR r: SYSTEM.Registers; p, d: POINTER TO CHAR; i: INTEGER;
BEGIN
  p := SYSTEM.ADR(Path);
  d := SYSTEM.ADR(Dest);
  r.AX := 6000H;
  r.DS := SYSTEM.SEG(p^);
  r.SI := SYSTEM.OFS(p^);
  r.ES := SYSTEM.SEG(d^);
  r.DI := SYSTEM.OFS(d^);
  r.Flags := 0;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN
    i := 0;
    WHILE (i < LEN(Dest)) & (Path[i] # 0X) DO
      Dest[i] := Path[i]; INC(i)
    END;
    IF i < LEN(Dest) THEN Dest[i] := 0X END
  END
END FExpand;

PROCEDURE FSplit*(Path: ARRAY OF CHAR; VAR Dir, Name, Ext: ARRAY OF CHAR);
  VAR i, j, len, dirEnd, nameStart, extStart : INTEGER;
BEGIN
  len := 0; WHILE (len < LEN(Path)) & (Path[len] # 0X) DO INC(len) END;
  dirEnd := -1;
  i := 0;
  WHILE i < len DO
    IF (Path[i] = '\') OR (Path[i] = ':') THEN dirEnd := i END;
    INC(i)
  END;
  nameStart := dirEnd + 1;
  i := nameStart;
  WHILE (i < len) & (Path[i] # '.') DO INC(i) END;
  extStart := i;
  IF dirEnd < 0 THEN
    Dir[0] := 0X
  ELSE
    j := 0;
    i := 0;
    WHILE (i <= dirEnd) & (j < LEN(Dir)-1) DO
      Dir[j] := Path[i]; INC(i); INC(j)
    END;
    Dir[j] := 0X
  END;
  j := 0;
  i := nameStart;
  WHILE (i < extStart) & (j < LEN(Name)-1) DO
    Name[j] := Path[i]; INC(i); INC(j)
  END;
  Name[j] := 0X;
  IF extStart < len THEN
    j := 0;
    i := extStart;
    WHILE (i < len) & (j < LEN(Ext)-1) DO
      Ext[j] := Path[i]; INC(i); INC(j)
    END;
    Ext[j] := 0X
  ELSE
    Ext[0] := 0X
  END
END FSplit;

(* Exec: load and execute an external .EXE / .COM via INT 21h function 4B00h.

   Path is the ASCIIZ path to the executable; CmdLine is the command-tail
   (without the program name).  Sets the module-level DosError to 0 on
   success and to the INT 21h error code on failure (2 = file not found,
   8 = insufficient memory, 0BH = invalid format, ...).  The child's exit
   code can be retrieved separately by calling the DosExitCode function.

   Semantics match Turbo Pascal's Dos.Exec.  No Setblock dance: the runtime
   (SYS.ASM SYSTEM_INIT) allocates only $M max paragraphs, so memory above
   the parent's heap is naturally available to the child. *)
PROCEDURE Exec*(Path, CmdLine: ARRAY OF CHAR);
VAR
    pathz : ARRAY 80 OF CHAR;  (* NUL-terminated path *)
    tail  : ARRAY 130 OF CHAR; (* len byte + 0..127 chars + 0DH *)
    epb   : ExecPB;
    regs  : SYSTEM.Registers;
    i, n  : INTEGER;
    pw    : POINTER TO WORD;
BEGIN
    (* Copy Path into pathz with NUL terminator. *)
    i := 0;
    WHILE (i < LEN(pathz) - 1) & (Path[i] # 0X) DO
        pathz[i] := Path[i]; INC(i)
    END;
    pathz[i] := 0X;

    (* Build command-tail block: tail[0] = length, tail[1..n] = chars, tail[n+1] = 0DH. *)
    n := 0;
    WHILE (n < 127) & (CmdLine[n] # 0X) DO INC(n) END;
    tail[0] := CHR(n);
    i := 0;
    WHILE i < n DO
        tail[i + 1] := CmdLine[i]; INC(i)
    END;
    tail[n + 1] := 0DX;

    (* Fill EPB.  FCB pointers go to tail buffer as harmless placeholders. *)
    pw := SYSTEM.PTR(GetPsp(), 2CH);
    epb.envSeg := pw^;
    epb.tailOfs := SYSTEM.OFS(tail); epb.tailSeg := SYSTEM.SEG(tail);
    epb.fcb1Ofs := SYSTEM.OFS(tail); epb.fcb1Seg := SYSTEM.SEG(tail);
    epb.fcb2Ofs := SYSTEM.OFS(tail); epb.fcb2Seg := SYSTEM.SEG(tail);

    (* INT 21h / 4B00h: DS:DX → path (ASCIIZ); ES:BX → EPB. *)
    regs.AX := 4B00H;
    regs.DX := SYSTEM.OFS(pathz); regs.DS := SYSTEM.SEG(pathz);
    regs.BX := SYSTEM.OFS(epb);   regs.ES := SYSTEM.SEG(epb);
    SYSTEM.Intr(21H, regs);

    IF SYSTEM.AND(regs.Flags, 1) # 0 THEN
        DosError := SYSTEM.AND(regs.AX, 0FFH)
    ELSE
        DosError := 0;
        (* INT 21h / 4D00h "Get exit code of child":
             AL = exit code, AH = termination type (0=normal, 1=Ctrl-C,
                                                   2=critical-err, 3=TSR). *)
        regs.AX := 4D00H;
        SYSTEM.Intr(21H, regs);
        DosExitCode := SYSTEM.AND(regs.AX, 0FFH)
    END
END Exec;

PROCEDURE SwapVectors*;
BEGIN
END SwapVectors;

BEGIN
    DosError    := 0;
    DosExitCode := 0;
    ArgInit;
END Dos.