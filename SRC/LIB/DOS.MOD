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

(* Intr: invoke an arbitrary software interrupt with caller-supplied
   register values, and return the register values set on return.
   Parameters: IntNo — interrupt number to invoke; Regs — in/out register
   set (AX/BX/CX/DX/SI/DI/DS/ES/Flags).
   Result: none (Regs is updated in place). *)
PROCEDURE Intr*(IntNo: BYTE; VAR Regs: Registers);
BEGIN
    SYSTEM.Intr(IntNo, Regs);
END Intr;

(* MsDos: invoke INT 21h (the DOS API dispatcher) with caller-supplied
   register values, and return the register values set on return.
   Parameters: Regs — in/out register set (AX/BX/CX/DX/SI/DI/DS/ES/Flags).
   Result: none (Regs is updated in place). *)
PROCEDURE MsDos*(VAR Regs: Registers);
BEGIN
    SYSTEM.Intr(21H, Regs)
END MsDos;

VAR
    argBuf   : ARRAY 200 OF CHAR;
    argOfs   : ARRAY 32 OF INTEGER;
    argCount : INTEGER;

(* GetPsp: retrieve the segment address of the current process's Program
   Segment Prefix, via INT 21h AH=62h.
   Parameters: none.
   Result: the PSP segment. *)
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
    len     : WORD;
    pos     : WORD;
    ai      : INTEGER;
    bi      : INTEGER;
    ch      : CHAR;
    inQuote : BOOLEAN;
    inArg   : BOOLEAN;
    k       : SYSTEM.ADDRESS;
BEGIN
    argCount := 0;
    k := SYSTEM.PTR(GetPsp(), 80H);
    len := ORD(k^);
    IF len = 0 THEN RETURN END;

    pos     := 0;
    inQuote := FALSE;
    inArg   := FALSE;
    ai      := 1;
    bi      := 1;
    INC(k);
    WHILE (pos < len) & (ai < 32) DO
        ch := k^[pos];
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

(* ParamCount: report how many command-line arguments were passed to
   this program (parsed from the PSP command tail at startup).
   Parameters: none.
   Result: the number of arguments (excludes argument 0, the program
   name). *)
PROCEDURE ParamCount*: INTEGER;
BEGIN
    RETURN argCount
END ParamCount;

(* ParamStr: retrieve one command-line argument by index.
   Parameters: i — argument index (0 = the program's own path/name,
   retrieved from the environment block; 1..ParamCount() = the parsed
   command-tail arguments); p — output buffer receiving the ASCIIZ
   argument text (truncated to fit).
   Result: none (p is filled in place; empty string if i is out of
   range). *)
PROCEDURE ParamStr*(i: INTEGER; VAR p: ARRAY OF CHAR);
    VAR src, dst, envseg : WORD; ch : CHAR; k : SYSTEM.ADDRESS;
BEGIN
    IF i = 0 THEN
        (* Argv[0] = EXE filename, retrieved from PSP environment block. *)
        dst := 0;
        k := SYSTEM.PTR(GetPsp(), 2CH);
        envseg := ORD(k^) + ORD(k^[1]) * 256;
        IF envseg = 0 THEN p[0] := 0X; RETURN END;
        k := SYSTEM.PTR(envseg, 0);
        WHILE k^ # 0X DO
            WHILE k^ # 0X DO INC(k) END;
            INC(k)
        END;
        (* now at the empty-string marker (single 0 byte) — skip it *)
        INC(k);
        (* now at the 2-byte program-string count (always 1 under DOS 3.0+) *)
        INC(k, 2);
        (* now at the ASCIIZ program-name *)
        ch := k^;
        WHILE (ch # 0X) & (dst < LEN(p) - 1) DO
            p[dst] := ch; INC(dst); INC(k);
            ch := k^
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

(* GetEnv: look up an environment variable by name in the process's
   environment block (reached via the PSP environment segment pointer).
   Parameters: envvar — variable name to search for (case-insensitive);
   dst — output buffer receiving the value's ASCIIZ text (truncated to
   fit).
   Result: none (dst is set to the value, or to an empty string if the
   variable is not found). *)
PROCEDURE GetEnv*(envvar: ARRAY OF CHAR; VAR dst: ARRAY OF CHAR);
VAR
    envseg : INTEGER;
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
    pw := SYSTEM.PTR(envseg, 0);
    WHILE pw^ # 0X DO
        ei := 0;
        match := TRUE;
        ch := pw^;
        WHILE (ch # '=') & (ch # 0X) DO
            IF (ei < LEN(envvar) - 1) & match THEN
                match := SYSTEM.UCASE(ch) = SYSTEM.UCASE(envvar[ei]);
                INC(ei)
            ELSE
                match := FALSE
            END;
            INC(pw);
            ch := pw^
        END;
        IF match & (envvar[ei] = 0X) & (ch = '=') THEN
            INC(pw);
            di := 0;
            ch := pw^;
            WHILE ch # 0X DO
                IF di < LEN(dst) - 1 THEN
                    dst[di] := ch; INC(di)
                END;
                INC(pw);
                ch := pw^
            END;
            dst[di] := 0X;
            RETURN
        END;
        WHILE pw^ # 0X DO INC(pw) END;
        INC(pw)
    END
END GetEnv;

(* GetDTA: retrieve the current Disk Transfer Area address, via
   INT 21h AH=2Fh.
   Parameters: none.
   Result: far address of the current DTA. *)
PROCEDURE GetDTA*: SYSTEM.ADDRESS;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2F00H;
  SYSTEM.Intr(21H, r);
  RETURN SYSTEM.PTR(r.ES, r.BX)
END GetDTA;

(* SetDTA: set the Disk Transfer Area address, via INT 21h AH=1Ah.
   Parameters: dta — far address to use as the new DTA.
   Result: none. *)
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
   files for FindNext).  Matches Turbo Pascal's Dos.FindFirst semantics.
   Parameters: Path — ASCIIZ search pattern (may include wildcards);
   Attr — attribute mask to match (e.g. AnyFile); S — output search
   record, filled with the first match.
   Result: none (see DosError for success/failure). *)
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
   state in `S.fill`.  Sets DosError to 12H when no more entries match.
   Parameters: S — the search record from the prior FindFirst/FindNext
   call, updated in place with the next match.
   Result: none (see DosError for success/failure). *)
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
   directory already exists or cannot be created.  Sets DosError.
   Parameters: Path — ASCIIZ directory path to create.
   Result: TRUE on success, FALSE on failure. *)
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
   DosError.
   Parameters: Path — ASCIIZ directory path to change into.
   Result: TRUE on success, FALSE on failure. *)
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

(* GetDate: retrieve the current system date, via INT 21h AH=2Ah.
   Parameters: Year — output, full year (e.g. 2026); Month — output,
   1..12; Day — output, 1..31; DayOfWeek — output, 0=Sunday..6=Saturday.
   Result: none (all four VAR parameters are filled). *)
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

(* SetDate: set the system date, via INT 21h AH=2Bh.
   Parameters: Year — full year; Month — 1..12; Day — 1..31.
   Result: none. *)
PROCEDURE SetDate*(Year,Month,Day: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2B00H;
  r.CX := Year;
  r.DX := Day + SYSTEM.LSL(Month, 8);
  SYSTEM.Intr(21H, r)
END SetDate;

(* GetTime: retrieve the current system time, via INT 21h AH=2Ch.
   Parameters: Hour — output, 0..23; Minute — output, 0..59;
   Second — output, 0..59; Sec100 — output, hundredths of a second,
   0..99.
   Result: none (all four VAR parameters are filled). *)
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

(* SetTime: set the system time, via INT 21h AH=2Dh.
   Parameters: Hour — 0..23; Minute — 0..59; Second — 0..59;
   Sec100 — hundredths of a second, 0..99.
   Result: none. *)
PROCEDURE SetTime*(Hour,Minute,Second,Sec100: INTEGER);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2D00H;
  r.CX := Minute + SYSTEM.LSL(Hour, 8);
  r.DX := Sec100 + SYSTEM.LSL(Second, 8);
  SYSTEM.Intr(21H, r)
END SetTime;

(* GetCBreak: query the current Ctrl-Break check setting, via
   INT 21h AH=33h/AL=00h.
   Parameters: Break — output, TRUE if extended Ctrl-Break checking is
   enabled.
   Result: none (Break is filled in place). *)
PROCEDURE GetCBreak*(VAR Break: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3300H;
  SYSTEM.Intr(21H, r);
  Break := (r.DX MOD 256) # 0
END GetCBreak;

(* SetCBreak: enable or disable extended Ctrl-Break checking, via
   INT 21h AH=33h/AL=01h.
   Parameters: Break — TRUE to enable extended checking, FALSE to
   disable it.
   Result: none. *)
PROCEDURE SetCBreak*(Break: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3301H;
  IF Break THEN r.DX := 1 ELSE r.DX := 0 END;
  SYSTEM.Intr(21H, r)
END SetCBreak;

(* GetVerify: query the current disk-write verify flag, via
   INT 21h AH=54h.
   Parameters: Verify — output, TRUE if verify-after-write is enabled.
   Result: none (Verify is filled in place). *)
PROCEDURE GetVerify*(VAR Verify: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 5400H;
  SYSTEM.Intr(21H, r);
  Verify := (r.AX MOD 256) # 0
END GetVerify;

(* SetVerify: enable or disable disk-write verification, via
   INT 21h AH=2Eh.
   Parameters: Verify — TRUE to enable verify-after-write, FALSE to
   disable it.
   Result: none. *)
PROCEDURE SetVerify*(Verify: BOOLEAN);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2E00H;
  IF Verify THEN r.DX := 1 ELSE r.DX := 0 END;
  SYSTEM.Intr(21H, r)
END SetVerify;

(* DiskFree: report the free space on a drive, via INT 21h AH=36h (get
   free disk space): AX=sectors/cluster, BX=free clusters, CX=bytes/sector.
   Parameters: Drive — drive number (0=default, 1=A:, 2=B:, ...).
   Result: free space in bytes, or -1 if the drive number is invalid. *)
PROCEDURE DiskFree*(Drive: BYTE): LONGINT;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3600H;
  r.DX := Drive;
  SYSTEM.Intr(21H, r);
  IF r.AX = 0FFFFH THEN RETURN -1 END;
  RETURN LONGINT(r.AX) * LONGINT(r.BX) * LONGINT(r.CX)
END DiskFree;

(* DiskSize: report the total capacity of a drive, via INT 21h AH=36h
   (get free disk space): AX=sectors/cluster, CX=bytes/sector,
   DX=total clusters.
   Parameters: Drive — drive number (0=default, 1=A:, 2=B:, ...).
   Result: total capacity in bytes, or -1 if the drive number is
   invalid. *)
PROCEDURE DiskSize*(Drive: BYTE): LONGINT;
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3600H;
  r.DX := Drive;
  SYSTEM.Intr(21H, r);
  IF r.AX = 0FFFFH THEN RETURN -1 END;
  RETURN LONGINT(r.AX) * LONGINT(r.CX) * LONGINT(r.DX)
END DiskSize;

(* GetIntVec: retrieve the current handler address for an interrupt
   vector, via INT 21h AH=35h (get interrupt vector).
   Parameters: IntNo — interrupt number to query; Vector — output, far
   address of the current handler.
   Result: none (Vector is filled in place). *)
PROCEDURE GetIntVec*(IntNo: BYTE; VAR Vector: SYSTEM.ADDRESS);
  VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 3500H + IntNo;
  SYSTEM.Intr(21H, r);
  Vector := SYSTEM.PTR(r.ES, r.BX)
END GetIntVec;

(* SetIntVec: install a new handler address for an interrupt vector, via
   INT 21h AH=25h (set interrupt vector).
   Parameters: IntNo — interrupt number to modify; Vector — far address
   of the new handler.
   Result: none. *)
PROCEDURE SetIntVec*(IntNo: BYTE; Vector: SYSTEM.ADDRESS);
  VAR r: SYSTEM.Registers; p: POINTER TO CHAR;
BEGIN
  p := Vector;
  r.AX := 2500H + IntNo;
  r.DS := SYSTEM.SEG(p^);
  r.DX := SYSTEM.OFS(p^);
  SYSTEM.Intr(21H, r)
END SetIntVec;

(* FExpand: expand a path into its canonical fully-qualified form
   (drive, directory, name), via INT 21h AX=6000h ("truename"); falls
   back to copying Path unchanged if the call fails (e.g. on DOS
   versions that don't support it).
   Parameters: Path — ASCIIZ path to expand; Dest — output buffer
   receiving the expanded ASCIIZ path (truncated to fit).
   Result: none (Dest is filled in place). *)
PROCEDURE FExpand*(Path: ARRAY OF CHAR; VAR Dest : ARRAY OF CHAR);
  VAR r: SYSTEM.Registers; p, d: SYSTEM.ADDRESS; i: WORD;
BEGIN
  p := SYSTEM.ADR(Path[0]);
  d := SYSTEM.ADR(Dest[0]);
  r.AX := 6000H;
  r.DS := SYSTEM.SEG(p^);
  r.SI := SYSTEM.OFS(p^);
  r.ES := SYSTEM.SEG(d^);
  r.DI := SYSTEM.OFS(d^);
  r.Flags := 0;
  SYSTEM.Intr(21H, r);
  IF SYSTEM.AND(r.Flags, SYSTEM.FCarry) # 0 THEN
    i := SYSTEM.MIN(LEN(Dest) - 1, SYSTEM.LENGTH(Path));
    SYSTEM.MOVE(Path[0], Dest[0], i);
    Dest[i] := 0X
  END
END FExpand;

(* FSplit: split a path into its directory, base name, and extension
   components (pure string parsing, no DOS call).
   Parameters: Path — ASCIIZ path to split; Dir — output, the directory
   portion including the trailing '\' or ':' (empty if none); Name —
   output, the base filename without extension; Ext — output, the
   extension including the leading '.' (empty if none).
   Result: none (Dir, Name, Ext are filled in place). *)
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
   (SYSTEM.ASM SYSTEM_INIT) allocates only $M max paragraphs, so memory above
   the parent's heap is naturally available to the child.
   Parameters: Path — ASCIIZ path to the executable; CmdLine — ASCIIZ
   command-tail text (without the program name).
   Result: none (see DosError/DosExitCode for outcome). *)
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

(* SwapVectors: Turbo Pascal compatibility stub for swapping the
   critical-error and Ctrl-Break interrupt vectors around an Exec call;
   currently a no-op in this runtime.
   Parameters: none.
   Result: none. *)
PROCEDURE SwapVectors*;
BEGIN
END SwapVectors;

BEGIN
    DosError    := 0;
    DosExitCode := 0;
    ArgInit;
END Dos.