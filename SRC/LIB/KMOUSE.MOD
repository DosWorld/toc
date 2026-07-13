MODULE KMouse;

(* Extended keyboard +
   Microsoft-mouse (INT 33h) driver. Scan-code CONSTs and the EXTERNAL
   procedures below;
   See KMOUSE.ASM for the assembly routines and their INT 16h/33h
   call conventions. *)

CONST
  ScanEsc*          = 01H;

  ScanUp*           = 48H;
  ScanDown*         = 50H;
  ScanLeft*         = 4BH;
  ScanRight*        = 4DH;

  ScanCtrlLeft*     = 73H;
  ScanCtrlRight*    = 74H;
  ScanCtrlUp*       = 8DH;
  ScanCtrlDown*     = 91H;

  ScanIns*          = 52H;
  ScanHome*         = 47H;
  ScanPgUp*         = 49H;
  ScanDel*          = 53H;
  ScanEnd*          = 4FH;
  ScanPgDn*         = 51H;

  ScanCtrlHome*     = 77H;
  ScanCtrlPgUp*     = 84H;
  ScanCtrlEnd*      = 75H;
  ScanCtrlPgDn*     = 76H;

  ScanF1*           = 3BH;
  ScanF2*           = 3CH;
  ScanF3*           = 3DH;
  ScanF4*           = 3EH;
  ScanF5*           = 3FH;
  ScanF6*           = 40H;
  ScanF7*           = 41H;
  ScanF8*           = 42H;
  ScanF9*           = 43H;
  ScanF10*          = 44H;
  ScanF11*          = 85H;
  ScanF12*          = 86H;

  ScanAltF1*        = 68H;
  ScanAltF2*        = 69H;
  ScanAltF3*        = 6AH;
  ScanAltF4*        = 6BH;
  ScanAltF5*        = 6CH;
  ScanAltF6*        = 6DH;
  ScanAltF7*        = 6EH;
  ScanAltF8*        = 6FH;
  ScanAltF9*        = 70H;
  ScanAltF10*       = 71H;
  ScanAltF11*       = 8BH;
  ScanAltF12*       = 8CH;

  ScanShiftF1*      = 54H;
  ScanShiftF2*      = 55H;
  ScanShiftF3*      = 56H;
  ScanShiftF4*      = 57H;
  ScanShiftF5*      = 58H;
  ScanShiftF6*      = 59H;
  ScanShiftF7*      = 5AH;
  ScanShiftF8*      = 5BH;
  ScanShiftF9*      = 5CH;
  ScanShiftF10*     = 5DH;
  ScanShiftF11*     = 87H;
  ScanShiftF12*     = 88H;

  ScanCtrlF1*       = 5EH;
  ScanCtrlF2*       = 5FH;
  ScanCtrlF3*       = 60H;
  ScanCtrlF4*       = 61H;
  ScanCtrlF5*       = 62H;
  ScanCtrlF6*       = 63H;
  ScanCtrlF7*       = 64H;
  ScanCtrlF8*       = 65H;
  ScanCtrlF9*       = 66H;
  ScanCtrlF10*      = 67H;
  ScanCtrlF11*      = 89H;
  ScanCtrlF12*      = 8AH;

  (* first row *)
  ScanTilda*        = 29H;
  Scan1*            = 02H;
  Scan2*            = 03H;
  Scan3*            = 04H;
  Scan4*            = 05H;
  Scan5*            = 06H;
  Scan6*            = 07H;
  Scan7*            = 08H;
  Scan8*            = 09H;
  Scan9*            = 0AH;
  Scan0*            = 0BH;
  ScanMinus*        = 0CH;
  ScanEq*           = 0DH;
  ScanBs*           = 0EH;

  (* second row *)
  ScanTab*          = 0FH;
  ScanQ*            = 10H;
  ScanW*            = 11H;
  ScanE*            = 12H;
  ScanR*            = 13H;
  ScanT*            = 14H;
  ScanY*            = 15H;
  ScanU*            = 16H;
  ScanI*            = 17H;
  ScanO*            = 18H;
  ScanP*            = 19H;
  ScanLBraket*      = 1AH;
  ScanRBraket*      = 1BH;
  ScanBackSlash*    = 2BH;

  (* third row *)
  ScanA*            = 1EH;
  ScanS*            = 1FH;
  ScanD*            = 20H;
  ScanF*            = 21H;
  ScanG*            = 22H;
  ScanH*            = 23H;
  ScanJ*            = 24H;
  ScanK*            = 25H;
  ScanL*            = 26H;
  ScanDotComa*      = 27H;
  ScanQuote*        = 28H;
  ScanEnter*        = 1CH;

  (* fourth row *)
  ScanZ*            = 2CH;
  ScanX*            = 2DH;
  ScanC*            = 2EH;
  ScanV*            = 2FH;
  ScanB*            = 30H;
  ScanN*            = 31H;
  ScanM*            = 32H;
  ScanComa*         = 33H;
  ScanDot*          = 34H;
  ScanSlash*        = 35H;

  ScanSpace*        = 39H;

  ScanGreyMinus*    = 4AH;
  ScanGreyPlus*     = 4EH;

  MouseB1*          = 1;
  MouseB2*          = 2;

(* KbdGetKey reads and removes the next key from the BIOS extended
   (INT 16h, AH=10h) keyboard buffer, blocking until a key is available.
   No parameters. Result: the raw scan-code/ASCII WORD (high byte =
   scan code, low byte = ASCII, as returned by INT 16h AH=10h). *)
PROCEDURE KbdGetKey* : WORD; EXTERNAL;

(* KbdHasKey checks the BIOS extended (INT 16h, AH=11h) keyboard buffer
   without removing anything. No parameters. Result: TRUE if a key is
   waiting, FALSE otherwise. *)
PROCEDURE KbdHasKey* : BOOLEAN; EXTERNAL;

(* KbdGetFlags reads the current BIOS keyboard shift-state flags byte
   (INT 16h, AH=12h / BIOS data area 0040h:0017h). No parameters.
   Result: the raw shift-state flags byte (bit layout: see IsCtrl/
   IsAlt/IsShift). *)
PROCEDURE KbdGetFlags* : BYTE; EXTERNAL;

(* KbdFast enables the extended (101/102-key) INT 16h keyboard functions
   when supported, so KbdGetKey/KbdHasKey report the fuller F11/F12/
   extended scan-code set instead of only the original 84-key set. No
   parameters, no result. *)
PROCEDURE KbdFast*; EXTERNAL;

(* IsCtrl tests a shift-state flags byte (as returned by KbdGetFlags)
   for the Ctrl-key-held bit. Parameters: flags -- the shift-state
   byte. Result: TRUE if Ctrl was held. *)
PROCEDURE IsCtrl*(flags : BYTE) : BOOLEAN; EXTERNAL;

(* IsAlt tests a shift-state flags byte (as returned by KbdGetFlags) for
   the Alt-key-held bit. Parameters: flags -- the shift-state byte.
   Result: TRUE if Alt was held. *)
PROCEDURE IsAlt*(flags : BYTE) : BOOLEAN; EXTERNAL;

(* IsShift tests a shift-state flags byte (as returned by KbdGetFlags)
   for the Shift-key-held bit (either shift key). Parameters: flags --
   the shift-state byte. Result: TRUE if Shift was held. *)
PROCEDURE IsShift*(flags : BYTE) : BOOLEAN; EXTERNAL;

(* MouseShow increments the Microsoft Mouse driver's internal cursor
   show/hide counter and makes the mouse cursor visible when it reaches
   zero (INT 33h, AX=1). No parameters, no result. *)
PROCEDURE MouseShow*; EXTERNAL;

(* MouseHide decrements the Microsoft Mouse driver's internal cursor
   show/hide counter and hides the mouse cursor (INT 33h, AX=2). No
   parameters, no result. *)
PROCEDURE MouseHide*; EXTERNAL;

(* MouseVisible reports whether a mouse driver was detected during
   module initialization (see Detect / MouseAvail). No parameters.
   Result: TRUE if the mouse cursor is currently shown. *)
PROCEDURE MouseVisible* : BOOLEAN; EXTERNAL;

(* MouseButtons reads the current state of the mouse buttons (INT 33h,
   AX=3). No parameters. Result: a bitmask (bit 0 = left/MouseB1 held,
   bit 1 = right/MouseB2 held). *)
PROCEDURE MouseButtons* : BYTE; EXTERNAL;

(* MouseGetX reads the mouse cursor's current horizontal position (INT
   33h, AX=3). No parameters. Result: the X coordinate in the driver's
   native (mickey/pixel) units. *)
PROCEDURE MouseGetX* : INTEGER; EXTERNAL;

(* MouseGetY reads the mouse cursor's current vertical position (INT
   33h, AX=3). No parameters. Result: the Y coordinate in the driver's
   native (mickey/pixel) units. *)
PROCEDURE MouseGetY* : INTEGER; EXTERNAL;

(* MouseAvail reports whether a Microsoft Mouse (or compatible) driver
   was detected during module initialization. No parameters. Result:
   TRUE if a mouse driver is present and usable. *)
PROCEDURE MouseAvail* : BOOLEAN; EXTERNAL;

(* Detect probes for an extended (101/102-key) keyboard and a mouse
   driver (INT 16h AH=09h, INT 33h AX=0) and caches the results for
   MouseAvail/the extended-keyboard fast path; called once from this
   module's own initialization. No parameters, no result. *)
PROCEDURE Detect; FAR; EXTERNAL;

(*$L KMOUSE.RDF*)

(* KbdReset* : discard any keys already waiting in the BIOS keyboard
   buffer (ported 1:1 from the Pascal UNIT's "WHILE kbd_haskey DO
   kbd_getkey" -- the only non-ASSEMBLER body in the original UNIT). *)
PROCEDURE KbdReset*;
BEGIN
  WHILE KbdHasKey() DO KbdGetKey END
END KbdReset;

BEGIN
  Detect
END KMouse.
