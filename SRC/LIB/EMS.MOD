(*$D-*)
MODULE EMS;

CONST
  PageSize = 16384;
  MaxPhysicalPages = 4;

  VER35* = 035H;
  VER40* = 040H;

TYPE
(*$A-*)
  MoveDesc = RECORD
    len       : LONGINT;
    srcType   : BYTE;
    srcHandle : WORD;
    src       : LONGINT;
    dstType   : BYTE;
    dstHandle : WORD;
    dst       : LONGINT
  END;

VAR
  driverPresent: BOOLEAN;
  errorCode: WORD;
  pageFrameSeg: WORD;
  pageFrameObtained: BOOLEAN;

PROCEDURE Err(AH: INTEGER): WORD;
BEGIN
  RETURN WORD(SYSTEM.LSR(AH, 8))
END Err;

PROCEDURE Present*(): BOOLEAN;
BEGIN
  RETURN driverPresent
END Present;

PROCEDURE Alloc*(sizeKB: WORD; VAR handle: WORD): BOOLEAN;
  VAR pages: WORD; r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF sizeKB = 0 THEN pages := 1
  ELSE pages := WORD((LONGINT(sizeKB) + 15) DIV 16)
  END;
  r.AX := 4300H;
  r.BX := INTEGER(pages);
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  IF errorCode = 0 THEN handle := WORD(r.DX) END;
  RETURN errorCode = 0
END Alloc;

PROCEDURE Free*(handle: WORD): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  r.AX := 4500H;
  r.DX := INTEGER(handle);
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  RETURN errorCode = 0
END Free;

PROCEDURE DoMove(fromEMS: BYTE;
                 conv : LONGINT; emsHandle: WORD;
                 ems: LONGINT;
                 length: WORD): BOOLEAN;
  VAR desc: MoveDesc; r: SYSTEM.Registers;
BEGIN
  (* Per LIM EMS 4.0 move_source_dest_struct, each side packs two WORDs:
     +0 offset, +2 segment-or-logical-page.
       - Conventional memory: low word = far-pointer offset, high word =
         segment.  `conv` is LONGINT(SYSTEM.ADR(buf)) verbatim (ADR already
         packs segment:offset as high:low).
       - EMS memory: low word = offset WITHIN the 16 KB logical page, high word
         = the logical PAGE NUMBER -- NOT a raw byte offset.  `ems` arrives as a
         flat byte offset, so re-pack it with SYSTEM.PTR(page, offsetInPage).
         (Passing the raw byte offset is a bug: any offset >= 16384 overflows
         the 16-bit offset field and corrupts the move.)  Per the LIM EMS 4.0
         spec, function 57h maps consecutive logical pages of the handle to
         complete the move, so a length that crosses a page boundary is handled
         by the EMM and needs no manual splitting here.
     *Handle is 0 for the conventional side "for future compatibility" -- it is
     NOT a place to stash the segment. *)
  ems := LONGINT(SYSTEM.PTR(WORD(ems DIV PageSize), WORD(ems MOD PageSize)));
  desc.len := LONGINT(length);
  IF fromEMS = 0 THEN
    desc.srcType    := 0;
    desc.srcHandle  := 0;
    desc.src        := conv;
    desc.dstType    := 1;
    desc.dstHandle  := emsHandle;
    desc.dst        := ems;
  ELSE
    desc.srcType    := 1;
    desc.srcHandle  := emsHandle;
    desc.src        := ems;
    desc.dstType    := 0;
    desc.dstHandle  := 0;
    desc.dst        := conv
  END;
  r.AX := 5700H;
  r.DS := SYSTEM.SEG(desc);
  r.SI := SYSTEM.OFS(desc);
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  RETURN errorCode = 0
END DoMove;

PROCEDURE CopyToEMS*(VAR dosBuf;
                     handle: WORD;
                     emsOffset: LONGINT;
                     size: WORD): BOOLEAN;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF size = 0 THEN errorCode := 0; RETURN TRUE END;
  RETURN DoMove(0, LONGINT(SYSTEM.ADR(dosBuf)), handle, emsOffset, size)
END CopyToEMS;

PROCEDURE CopyToDos*(handle: WORD;
                     emsOffset: LONGINT;
                     VAR dosBuf;
                     size: WORD): BOOLEAN;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF size = 0 THEN errorCode := 0; RETURN TRUE END;
  RETURN DoMove(1, LONGINT(SYSTEM.ADR(dosBuf)), handle, emsOffset, size)
END CopyToDos;

(* Function 18 (AH=51h, Reallocate Pages) keeps the SAME handle; it never
   returns a new one in DX -- only BX (the new page count) is meaningful on
   success.  newHandle is therefore always 'handle' on success. *)
PROCEDURE Realloc*(VAR handle: WORD; newSizeKB: WORD): BOOLEAN;
  VAR newPages, curPages: WORD; r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF newSizeKB = 0 THEN newPages := 1
  ELSE newPages := WORD((LONGINT(newSizeKB) + 15) DIV 16)
  END;
  r.AX := 4C00H;
  r.DX := INTEGER(handle);
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  IF errorCode # 0 THEN RETURN FALSE END;
  curPages := WORD(r.BX);
  IF curPages = newPages THEN
    errorCode := 0;
    RETURN TRUE
  END;
  r.AX := 5100H;
  r.DX := INTEGER(handle);
  r.BX := INTEGER(newPages);
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  RETURN errorCode = 0
END Realloc;

PROCEDURE GetError*(): WORD;
BEGIN
  RETURN errorCode
END GetError;

PROCEDURE Detect;
  VAR
      p: POINTER TO ARRAY 8 OF CHAR;
      r: SYSTEM.Registers;
BEGIN
  driverPresent := FALSE;
  errorCode := 0;
  pageFrameSeg := 0;
  pageFrameObtained := FALSE;

  (* INT 21h/AH=35h returns the INT 67h handler segment in ES; a real EMM driver
     exposes the "EMMXXXX0" device-header signature at ES:000Ah. *)
  r.AX := 3567H;
  SYSTEM.Intr(21H, r);
  p := SYSTEM.PTR(r.ES, 0AH);
  IF (p^[0] = 'E') & (p^[1] = 'M') & (p^[2] = 'M') & (p^[3] = 'X') &
     (p^[4] = 'X') & (p^[5] = 'X') & (p^[6] = 'X') & (p^[7] = '0') THEN
    driverPresent := TRUE;
    r.AX := 4100H;
    SYSTEM.Intr(67H, r);
    errorCode := Err(r.AX);
    IF errorCode = 0 THEN
      pageFrameSeg := WORD(r.BX);
      pageFrameObtained := TRUE
    END
  END
END Detect;

PROCEDURE Version*:BYTE;
  VAR
      r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN RETURN 0 END;
  errorCode := 0;
  r.AX := 4600H;
  SYSTEM.Intr(21H, r);
  errorCode := Err(r.AX);
  IF errorCode = 0 THEN RETURN SYSTEM.AND(r.AX, 0FFH) END;
  RETURN 0
END Version;

PROCEDURE RequireVersion*(ver: BYTE);
BEGIN
  IF Version() < ver THEN driverPresent := FALSE END;
END RequireVersion;

PROCEDURE MapPage*(handle: WORD; logicalPage: WORD; physicalPage: WORD): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF ~pageFrameObtained THEN errorCode := 0FFH; RETURN FALSE END;
  IF physicalPage >= MaxPhysicalPages THEN errorCode := 0FFH; RETURN FALSE END;
  r.DX := INTEGER(handle);
  r.BX := INTEGER(logicalPage);
  r.AX := SYSTEM.IOR(4400H, BYTE(physicalPage));
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  RETURN errorCode = 0
END MapPage;

PROCEDURE UnmapPage*(physicalPage: WORD): BOOLEAN;
  VAR r: SYSTEM.Registers;
BEGIN
  IF ~driverPresent THEN errorCode := 0FFH; RETURN FALSE END;
  IF ~pageFrameObtained THEN errorCode := 0FFH; RETURN FALSE END;
  IF physicalPage >= MaxPhysicalPages THEN errorCode := 0FFH; RETURN FALSE END;
  r.AX := 4400H;
  r.DX := 0;
  r.BX := 0;
  r.AX := SYSTEM.IOR(4400H, BYTE(physicalPage));
  SYSTEM.Intr(67H, r);
  errorCode := Err(r.AX);
  RETURN errorCode = 0
END UnmapPage;

PROCEDURE MapPtr*(handle: WORD; emsOffset: LONGINT; physWin: WORD): SYSTEM.ADDRESS;
  VAR logicalPage: WORD; offsetInPage: WORD;
BEGIN
  logicalPage := WORD(emsOffset DIV PageSize);
  offsetInPage := WORD(emsOffset MOD PageSize);
  IF MapPage(handle, logicalPage, physWin) THEN
    RETURN SYSTEM.PTR(pageFrameSeg + physWin * (PageSize DIV 16), offsetInPage)
  ELSE
    RETURN NIL
  END
END MapPtr;

BEGIN
  Detect;
END EMS.
