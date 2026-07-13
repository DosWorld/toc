MODULE WinCB;

(*$L WINCB.RDF*)

(* Detect returns TRUE if a Windows 3.x (WinOldAp) clipboard interface is
   present. No parameters. Uses INT 2Fh AX=1700h (clipboard installation
   check); TRUE unless AX still reads back as 1700h (function not
   supported). *)
PROCEDURE Detect* : BOOLEAN; FAR; EXTERNAL;
PROCEDURE Clear* : BOOLEAN; FAR; EXTERNAL;
PROCEDURE GetDataSize* : LONGINT; FAR; EXTERNAL;

PROCEDURE Open : BOOLEAN; FAR; EXTERNAL;
PROCEDURE Close; FAR; EXTERNAL;

(* SetData writes size bytes from d to the Windows clipboard in CF_TEXT
   format (INT 2Fh AX=1703h). d is a typeless VAR -- the caller's buffer
   is passed by its far address only, matching EMS.MOD's CopyToEMS/
   CopyToDos convention -- so any variable/array can be used without a
   type-specific overload. Returns TRUE on success. *)
PROCEDURE SetData(VAR d; size : WORD) : BOOLEAN; FAR; EXTERNAL;

(* GetData reads the current clipboard contents (CF_TEXT format) into d
   (INT 2Fh AX=1705h). d is a typeless VAR, same far-address-only
   convention as SetData -- the caller is responsible for the buffer
   being large enough (see Paste, which checks GetDataSize() first).
   Returns TRUE on success. *)
PROCEDURE GetData(VAR d) : BOOLEAN; FAR; EXTERNAL;

(* Copy* : "write to Windows clipboard" -- writes size bytes from d as
   CF_TEXT.  Fails (returns FALSE) if no clipboard is present, or if
   Open/Clear fail; the size passed to SetData is rounded down to a
   multiple of 32 bytes plus 31 (SYSTEM.AND(size,0FFE0H)+31) to match
   the original WinCB clipboard-block-size convention. *)
PROCEDURE Copy*(VAR d; size : WORD) : BOOLEAN;
VAR r : BOOLEAN;
BEGIN
  r := FALSE;
  IF Detect() THEN
    IF Open() THEN
      IF Clear() THEN
        r := SetData(d, SYSTEM.IOR(SYSTEM.AND(size, 0FFE0H), 1FH))
      END;
      Close
    END
  END;
  RETURN r
END Copy;

(* Paste* : "read from Windows clipboard" -- reads into d (a byte buffer
   of at least maxSize+1 bytes) if the clipboard's current CF_TEXT size
   fits, appending a 0X terminator after the last byte read. Returns
   FALSE if no clipboard is present, Open fails, or the clipboard content
   is too large for maxSize. *)
PROCEDURE Paste*(VAR d; maxSize : WORD) : BOOLEAN;
VAR r    : BOOLEAN;
    size : LONGINT;
    p    : SYSTEM.ADDRESS;
BEGIN
  r := FALSE;
  IF Detect() THEN
    IF Open() THEN
      size := GetDataSize();
      IF (size - 1) < LONGINT(maxSize) THEN
        r := GetData(d);
        IF r THEN
          p := SYSTEM.ADR(d);
          p := p + size;
          SYSTEM.FILL(p, 1, 0)
        END
      END;
      Close
    END
  END;
  RETURN r
END Paste;

END WinCB.
