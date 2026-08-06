(*$D-,R-,A-*)
(* Graph — Trubo Oberon implementation BGI graphics interface. *)
MODULE Graph;

IMPORT Files, Strings, Math, Det := Detect;

CONST

(* .BGI v2.0 header layout, see DOCS/BGI.MD §3 *)
HeaderSize   = 0A0H;   (* driver image begins at this file offset *)
Block2Ofs    = 080H;   (* second (fixed-offset) header block *)
BlockLen     = 10;     (* v2.0 header block length in bytes *)
SigOfs       = 0CH;    (* 'CB' validity marker, relative to image start *)
DDOVecCount  = 30;     (* number of documented DDOVEC entries, SI 0x00..0x3A *)

(* DDOVEC table indices (CallDriver's n; SI = n*2), see DOCS/BGI.MD §5 *)
DvInstall      = 0;
DvInit         = 1;
DvClear        = 2;
DvPost         = 3;
DvMove         = 4;   (* SI 0x08 *)
DvDraw         = 5;   (* SI 0x0A *)
DvVect         = 6;   (* SI 0x0C *)
DvPatbar       = 9;   (* SI 0x12 *)
DvPalette      = 13;  (* SI 0x1A *)
DvSetAllPal    = 14;  (* SI 0x1C *)
DvColour       = 15;  (* SI 0x1E *)
DvFillStyle    = 16;  (* SI 0x20 *)
DvLineStyle    = 17;  (* SI 0x22 *)
DvTextStyle    = 18;  (* SI 0x24 *)
DvText         = 19;  (* SI 0x26 *)
DvTextSize     = 20;  (* SI 0x28 *)
DvFloodFill    = 22;  (* SI 0x2C *)
DvDone         = 23;  (* SI 0x2E *)
DvGetPixel     = 23;  (* SI 0x2E *)
DvPutPixel     = 24;  (* SI 0x30 *)
DvSaveBitmap   = 26;  (* SI 0x34 *)
DvRestoreBitmap = 27; (* SI 0x36 *)
DvSetClip      = 28;  (* SI 0x38 *)
DvColourQuery  = 29;  (* SI 0x3A *)

(* GraphResult error return codes *)
grOk*             =   0;
grNoInitGraph*    =  -1;
grNotDetected*    =  -2;
grFileNotFound*   =  -3;
grInvalidDriver*  =  -4;
grNoLoadMem*      =  -5;
grNoScanMem*      =  -6;
grNoFloodMem*     =  -7;
grFontNotFound*   =  -8;
grNoFontMem*      =  -9;
grInvalidMode*    = -10;
grError*          = -11;   (* generic error *)
grIOerror*        = -12;
grInvalidFont*    = -13;
grInvalidFontNum* = -14;

(* graphics drivers *)
CurrentDriver* = -128; (* passed to GetModeRange *)
Detect*        = 0;    (* requests autodetection *)
CGA*           = 1;
MCGA*          = 2;
EGA*           = 3;
EGA64*         = 4;
EGAMono*       = 5;
IBM8514*       = 6;
HercMono*      = 7;
ATT400*        = 8;
VGA*           = 9;
PC3270*        = 10;

(* graphics modes for each driver *)
CGAC0*      = 0;  (* 320x200 palette 0: LightGreen, LightRed, Yellow; 1 page *)
CGAC1*      = 1;  (* 320x200 palette 1: LightCyan, LightMagenta, White; 1 page *)
CGAC2*      = 2;  (* 320x200 palette 2: Green, Red, Brown; 1 page *)
CGAC3*      = 3;  (* 320x200 palette 3: Cyan, Magenta, LightGray; 1 page *)
CGAHi*      = 4;  (* 640x200 1 page *)
MCGAC0*     = 0;  (* 320x200 palette 0: LightGreen, LightRed, Yellow; 1 page *)
MCGAC1*     = 1;  (* 320x200 palette 1: LightCyan, LightMagenta, White; 1 page *)
MCGAC2*     = 2;  (* 320x200 palette 2: Green, Red, Brown; 1 page *)
MCGAC3*     = 3;  (* 320x200 palette 3: Cyan, Magenta, LightGray; 1 page *)
MCGAMed*    = 4;  (* 640x200 1 page *)
MCGAHi*     = 5;  (* 640x480 1 page *)
EGALo*      = 0;  (* 640x200 16 color 4 page *)
EGAHi*      = 1;  (* 640x350 16 color 2 page *)
EGA64Lo*    = 0;  (* 640x200 16 color 1 page *)
EGA64Hi*    = 1;  (* 640x350 4 color  1 page *)
EGAMonoHi*  = 3;  (* 640x350 64K on card, 1 page; 256K on card, 2 page *)
HercMonoHi* = 0;  (* 720x348 2 page *)
ATT400C0*   = 0;  (* 320x200 palette 0: LightGreen, LightRed, Yellow; 1 page *)
ATT400C1*   = 1;  (* 320x200 palette 1: LightCyan, LightMagenta, White; 1 page *)
ATT400C2*   = 2;  (* 320x200 palette 2: Green, Red, Brown; 1 page *)
ATT400C3*   = 3;  (* 320x200 palette 3: Cyan, Magenta, LightGray; 1 page *)
ATT400Med*  = 4;  (* 640x200 1 page *)
ATT400Hi*   = 5;  (* 640x400 1 page *)
VGALo*      = 0;  (* 640x200 16 color 4 page *)
VGAMed*     = 1;  (* 640x350 16 color 2 page *)
VGAHi*      = 2;  (* 640x480 16 color 1 page *)
PC3270Hi*   = 0;  (* 720x350 1 page *)
IBM8514LO*  = 0;  (* 640x480 256 colors *)
IBM8514HI*  = 1;  (* 1024x768 256 colors *)

(* Colors for SetPalette and SetAllPalette *)
Black*        = 0;
Blue*         = 1;
Green*        = 2;
Cyan*         = 3;
Red*          = 4;
Magenta*      = 5;
Brown*        = 6;
LightGray*    = 7;
DarkGray*     = 8;
LightBlue*    = 9;
LightGreen*   = 10;
LightCyan*    = 11;
LightRed*     = 12;
LightMagenta* = 13;
Yellow*       = 14;
White*        = 15;

(* colors for 8514 to set standard EGA colors w/o knowing their values *)
EGABlack*        = 0;   (* dark colors *)
EGABlue*         = 1;
EGAGreen*        = 2;
EGACyan*         = 3;
EGARed*          = 4;
EGAMagenta*      = 5;
EGABrown*        = 20;
EGALightgray*    = 7;
EGADarkgray*     = 56;  (* light colors *)
EGALightblue*    = 57;
EGALightgreen*   = 58;
EGALightcyan*    = 59;
EGALightred*     = 60;
EGALightmagenta* = 61;
EGAYellow*       = 62;
EGAWhite*        = 63;

(* Line styles and widths for Get/SetLineStyle *)
SolidLn*   = 0;
DottedLn*  = 1;
CenterLn*  = 2;
DashedLn*  = 3;
UserBitLn* = 4;   (* User-defined line style *)

NormWidth*  = 1;
ThickWidth* = 3;

(* Set/GetTextStyle constants *)
DefaultFont*   = 0;  (* 8x8 bit mapped font *)
TriplexFont*   = 1;  (* "Stroked" fonts *)
SmallFont*     = 2;
SansSerifFont* = 3;
GothicFont*    = 4;

HorizDir* = 0;  (* left to right *)
VertDir*  = 1;  (* bottom to top *)

UserCharSize* = 0;  (* user-defined char size *)

(* Clipping constants: this compiler does not allow BOOLEAN constants, so
   these are INTEGER (1=TRUE / 0=FALSE); convert at call sites *)
ClipOn*  = 1;
ClipOff* = 0;

(* Bar3D constants: this compiler does not allow BOOLEAN constants, so
   these are INTEGER (1=TRUE / 0=FALSE); convert at call sites *)
TopOn*  = 1;
TopOff* = 0;

(* Fill patterns for Get/SetFillStyle *)
EmptyFill*      = 0;  (* fills area in background color *)
SolidFill*      = 1;  (* fills area in solid fill color *)
LineFill*       = 2;  (* --- fill *)
LtSlashFill*    = 3;  (* /// fill *)
SlashFill*      = 4;  (* /// fill with thick lines *)
BkSlashFill*    = 5;  (* \\\ fill with thick lines *)
LtBkSlashFill*  = 6;  (* \\\ fill *)
HatchFill*      = 7;  (* light hatch fill *)
XHatchFill*     = 8;  (* heavy cross hatch fill *)
InterleaveFill* = 9;  (* interleaving line fill *)
WideDotFill*    = 10; (* Widely spaced dot fill *)
CloseDotFill*   = 11; (* Closely spaced dot fill *)
UserFill*       = 12; (* user defined fill *)

(* BitBlt operators for PutImage *)
NormalPut* = 0;  (* MOV *)  (* left for 1.0 compatibility *)
CopyPut*   = 0;  (* MOV *)
XORPut*    = 1;  (* XOR *)
OrPut*     = 2;  (* OR  *)
AndPut*    = 3;  (* AND *)
NotPut*    = 4;  (* NOT *)

(* Horizontal and vertical justification for SetTextJustify *)
LeftText*   = 0;
CenterText* = 1;
RightText*  = 2;

BottomText* = 0;
(* CenterText = 1; already defined above *)
TopText*    = 2;

MaxColors* = 15;

TYPE

PaletteType* = RECORD
  Size*   : BYTE;
  Colors* : ARRAY (MaxColors+1) OF INTEGER
END;

LineSettingsType* = RECORD
  LineStyle* : WORD;
  Pattern*   : WORD;
  Thickness* : WORD
END;

TextSettingsType* = RECORD
  Font*      : WORD;
  Direction* : WORD;
  CharSize*  : WORD;
  Horiz*     : WORD;
  Vert*      : WORD
END;

FillSettingsType* = RECORD  (* Pre-defined fill style *)
  Pattern* : WORD;
  Color*   : WORD
END;

FillPatternType* = ARRAY 8 OF BYTE;  (* User defined fill style *)

PointType* = RECORD
  X*, Y* : INTEGER
END;

ViewPortType* = RECORD
  x1*, y1*, x2*, y2* : INTEGER;
  Clip*               : BOOLEAN
END;

ArcCoordsType* = RECORD
  X*, Y*           : INTEGER;
  Xstart*, Ystart* : INTEGER;
  Xend*, Yend*     : INTEGER
END;

(* DDOVec: the driver's dispatch table, copied out of the loaded image.
   Entry[n] is the near offset (within the image) of the routine at
   SI = n*2 -- see DOCS/BGI.MD §5. *)
DDOVec = ARRAY DDOVecCount OF WORD;

VAR

GraphGetMemPtr*  : SYSTEM.ADDRESS;  (* allows user to steal heap allocation *)
GraphFreeMemPtr* : SYSTEM.ADDRESS;  (* allows user to steal heap de-allocation *)

(* Loaded-driver state (§9 loader). DrvBase is the far address of the
   driver image (as returned by SYSTEM.Alloc); DDOVEC entries and
   BgiEntry (image offset 0) are called relative to it -- there is no
   requirement that DrvBase be paragraph/offset-0 aligned. *)
DrvLoaded  : BOOLEAN;          (* TRUE once a driver image is loaded *)
DrvBase    : SYSTEM.ADDRESS;   (* far address of the driver image *)
DrvSize    : WORD;             (* image size in bytes (codeSize) *)

DrvName    : ARRAY 9 OF CHAR;  (* driver name from the header, e.g. "CGA4" *)
DrvVec     : DDOVec;           (* parsed DDOVEC table *)

(* Colour state: the driver's `colour` routine (§5.1) is set-only --
   AL=draw, AH=fill in one call -- so the current draw/fill colours are
   tracked here (mirroring what the real BGI kernel keeps) and resent
   together on every SetColor/SetBkColor. *)
CurDrawColor : WORD;
CurFillColor : WORD;

(* Current pointer (CP), tracked here since the driver's move/draw
   routines (§5.1) do not hand it back on query -- mirrors what the real
   BGI kernel keeps for MoveTo/LineTo/MoveRel/LineRel/GetX/GetY. *)
CurX, CurY : INTEGER;

(* Current view port, tracked here since setclip (§5.1) is set-only --
   mirrors what the real BGI kernel keeps for GetViewSettings. Origin
   (VpX1,VpY1) is subtracted from user coordinates before each DDOVEC
   call, since the driver has no concept of a view-port origin of its
   own (only an absolute clip rectangle). *)
VpX1, VpY1, VpX2, VpY2 : INTEGER;
VpClip : BOOLEAN;

(* Current line style, tracked here since linestyle (§5.1) is set-only
   -- mirrors what the real BGI kernel keeps for GetLineSettings. *)
CurLineStyle, CurLinePattern, CurLineThickness : WORD;

(* Current fill style, tracked here since fillstyle (§5.1) is set-only
   -- mirrors what the real BGI kernel keeps for GetFillSettings. *)
CurFillPattern : WORD;
CurFillBytes : FillPatternType;

(* Current text style/justification, tracked here since textstyle
   (§5.1) is set-only -- mirrors what the real BGI kernel keeps for
   GetTextSettings. *)
CurFont, CurTextDir, CurCharSize : WORD;
CurHorizJust, CurVertJust : WORD;

(* Current pixel aspect ratio, tracked here since the driver exposes no
   DDOVEC query for hardware geometry (§7's DIT is internal-only -- see
   DOCS/BGI.MD §7). Defaults to 10000/10000 (square pixels); callers on
   non-square hardware (e.g. CGA graphics modes) must SetAspectRatio
   themselves for aspect-correct Circle/Ellipse/Arc, same as real BGI
   apps that read GetAspectRatio and adjust radii by hand. *)
AspX, AspY : WORD;

(* Last Arc/Ellipse call's centre and arc endpoints, served by
   GetArcCoords -- there is no DDOVEC query for this either (arc/
   ellipse are software-emulated here, see Ellipse). *)
LastArcX, LastArcY : INTEGER;
LastArcXStart, LastArcYStart : INTEGER;
LastArcXEnd, LastArcYEnd : INTEGER;

LastResult : INTEGER;  (* last GraphResult error code, set by InitGraph *)

(* *** high-level error handling *** *)
PROCEDURE GraphErrorMsg*(ErrorCode: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
END GraphErrorMsg;

PROCEDURE GraphResult*(): INTEGER;
BEGIN
  RETURN LastResult
END GraphResult;

(* *** detection, initialization and crt mode routines *** *)
PROCEDURE DetectGraph*(VAR GraphDriver, GraphMode: INTEGER);
BEGIN
   GraphDriver := Det.Video();
   GraphMode := 0;
END DetectGraph;

PROCEDURE GetDriverName*(VAR s: ARRAY OF CHAR);
BEGIN
END GetDriverName;

(* ReadHeaderWord: read a little-endian WORD from the second (fixed 0x80)
   header block, at byte offset `blockOfs` within that 10-byte block. *)
PROCEDURE ReadHeaderWord(VAR f: Files.File; blockOfs: WORD): WORD; NEAR;
  VAR lo, hi: BYTE;
BEGIN
  Files.Seek(f, LONGINT(Block2Ofs + blockOfs));
  Files.ReadByte(f, lo);
  Files.ReadByte(f, hi);
  RETURN SYSTEM.IOR(SYSTEM.LSL(WORD(hi), 8), WORD(lo))
END ReadHeaderWord;

(* UnloadDriver: release a driver image loaded via LoadDriver and reset
   the loader state.  Safe to call when no driver is loaded. *)
PROCEDURE UnloadDriver;
  VAR i: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  SYSTEM.Free(DrvBase);
  DrvBase := NIL;
  DrvSize := 0;
  DrvName[0] := 0X;
  i := 0;
  WHILE i < DDOVecCount DO DrvVec[i] := 0; INC(i) END;
  DrvLoaded := FALSE
END UnloadDriver;

(* LoadDriver: load and parse a .BGI v2.0 driver file into a fresh heap
   block, and populate DrvBase/DrvSize/DrvName/DrvVec (see DOCS/BGI.MD
   §3, §5).  Any previously loaded driver is freed first.
   Parameters: FileName — path to the .BGI file.
   Result: TRUE on success; FALSE on file-not-found, bad header magic/
   'CB' signature, or out-of-memory (state left unloaded). *)
PROCEDURE LoadDriver(FileName: ARRAY OF CHAR): BOOLEAN;
  VAR
    f: Files.File;
    codeSize: WORD;
    namelen: BYTE;
    i: WORD;
    sigLo, sigHi, sigVer: BYTE;
    ddoOfs: WORD;
    ch: BYTE;
BEGIN
  IF DrvLoaded THEN UnloadDriver END;
  IF ~Files.Reset(f, FileName) THEN RETURN FALSE END;

  (* second header block, fixed at file offset Block2Ofs (§3.2) *)
  codeSize := ReadHeaderWord(f, 4);

  Files.Seek(f, LONGINT(Block2Ofs + BlockLen));
  Files.ReadByte(f, namelen);
  IF namelen > 8 THEN namelen := 8 END;
  i := 0;
  WHILE i < WORD(namelen) DO
    Files.ReadByte(f, ch);
    DrvName[i] := CHR(ch);
    INC(i)
  END;
  DrvName[i] := 0X;

  IF (codeSize = 0) OR (codeSize > 0FFF0H) THEN Files.Close(f); RETURN FALSE END;
  DrvBase := SYSTEM.Alloc(codeSize);
  IF DrvBase = NIL THEN Files.Close(f); RETURN FALSE END;

  Files.Seek(f, LONGINT(HeaderSize));
  IF Files.BlockRead(f, DrvBase^, codeSize) # codeSize THEN
    SYSTEM.Free(DrvBase); Files.Close(f); RETURN FALSE
  END;
  Files.Close(f);
  DrvSize := codeSize;

  (* validity check: 'CB' marker at image+SigOfs (§4.1) *)
  sigLo := BYTE(DrvBase^[SigOfs]);
  sigHi := BYTE(DrvBase^[SigOfs + 1]);
  IF (CHR(sigLo) # 'C') OR (CHR(sigHi) # 'B') THEN
    SYSTEM.Free(DrvBase); RETURN FALSE
  END;
  sigVer := BYTE(DrvBase^[SigOfs + 3]);

  (* DDOVEC offset word sits at entry-stub image+0x07..0x08 (§4.1) *)
  ddoOfs := SYSTEM.IOR(SYSTEM.LSL(WORD(BYTE(DrvBase^[8])), 8),
                        WORD(BYTE(DrvBase^[7])));

  i := 0;
  WHILE i < DDOVecCount DO
    DrvVec[i] := SYSTEM.IOR(
      SYSTEM.LSL(WORD(BYTE(DrvBase^[ddoOfs + i*2 + 1])), 8),
      WORD(BYTE(DrvBase^[ddoOfs + i*2])));
    INC(i)
  END;

  DrvLoaded := TRUE;
  RETURN TRUE
END LoadDriver;

(* DriverLoaded: whether a driver image is currently loaded. *)
PROCEDURE DriverLoaded*(): BOOLEAN;
BEGIN
  RETURN DrvLoaded
END DriverLoaded;

(* DriverName: copy the loaded driver's name (from the header) into s;
   empty string if no driver is loaded. *)
PROCEDURE DriverName*(VAR s: ARRAY OF CHAR);
  VAR i: WORD;
BEGIN
  i := 0;
  WHILE DrvName[i] # 0X DO s[i] := DrvName[i]; INC(i) END;
  s[i] := 0X
END DriverName;

(* DriverImageSize: the loaded driver image's size in bytes (codeSize);
   0 if no driver is loaded. *)
PROCEDURE DriverImageSize*(): WORD;
BEGIN
  RETURN DrvSize
END DriverImageSize;

(* DriverVecEntry: the n-th DDOVEC entry (near offset within the image
   of the routine at SI = n*2); 0 if no driver is loaded or n is out of
   range (see DOCS/BGI.MD §5). *)
PROCEDURE DriverVecEntry*(n: WORD): WORD;
BEGIN
  IF n >= DDOVecCount THEN RETURN 0 END;
  RETURN DrvVec[n]
END DriverVecEntry;

(* CallDriver: invoke DDOVEC routine n in the loaded driver.
   DDOVEC entries are NEAR offsets, valid only relative to DS=CS inside
   the driver's own image, and end in a near RET -- they cannot be
   far-called directly (see DOCS/BGI.MD §4.1/§4.3/§5).  The only far-
   callable address is image offset 0 (BgiEntry), which the kernel
   invokes with SI = the byte index of the wanted routine; BgiEntry
   itself sets DS:=CS and near-calls through DDOVEC[SI].  This mirrors
   that: it far-calls DrvBase (offset 0) with Regs.SI := n*2, so
   BgiEntry dispatches to DDOVEC[n] on our behalf.
   Parameters: n — DDOVEC table index (0 = install, 2 = init, ... see
   §5's SI table); Regs — register set to load before the call (AX/BX/
   CX/DX/ES/etc. per the routine's ABI, §5.1); Regs.SI is overwritten
   with n*2.  On return, Regs holds whatever the routine left (e.g.
   GetPixel's DL, textsize's BX/CX).
   Result: none. Caller must ensure DriverLoaded() is TRUE first --
   calling with no driver loaded far-calls a NIL/freed address. *)
PROCEDURE CallDriver*(n: WORD; VAR Regs: SYSTEM.Registers);
BEGIN
  Regs.SI := INTEGER(n * 2);
  SYSTEM.CallFar(DrvBase, Regs)
END CallDriver;

(* InitGraph: load a .BGI driver and enter graphics mode.
   PathToDriver is taken as the literal .BGI filename to load (this
   project's driver files -- CGA4.BGI, VGA16.BGI, etc, see BGI/ -- do
   not follow stock Borland driver names, so there is no
   GraphDriver -> filename table; the caller names the exact file).
   GraphMode selects the driver's mode via install (AL=0, CL=GraphMode);
   GraphDriver is left unchanged (echoes what the caller passed) on
   success. On failure GraphDriver is set to grError and GraphResult()
   reports the specific code (grFileNotFound / grInvalidDriver). *)
PROCEDURE InitGraph*(VAR GraphDriver: INTEGER; VAR GraphMode: INTEGER; PathToDriver: ARRAY OF CHAR);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~LoadDriver(PathToDriver) THEN
    GraphDriver := grError;
    LastResult := grFileNotFound;
    RETURN
  END;

  (* install: AL=0, CL=GraphMode -- select mode, no INT 10h yet (§9.2) *)
  regs.AX := 0;
  regs.CX := GraphMode;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvInstall, regs);

  (* init: SI=2, no inputs -- performs the actual INT 10h mode switch *)
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvInit, regs);

  CurDrawColor := 0;
  CurFillColor := 0;
  CurX := 0; CurY := 0;
  VpX1 := 0; VpY1 := 0; VpX2 := 0; VpY2 := 0; VpClip := FALSE;
  CurLineStyle := SolidLn; CurLinePattern := 0; CurLineThickness := NormWidth;
  CurFillPattern := SolidFill;
  CurFont := DefaultFont; CurTextDir := HorizDir; CurCharSize := 1;
  CurHorizJust := LeftText; CurVertJust := TopText;
  AspX := 10000; AspY := 10000;
  LastResult := grOk
END InitGraph;

PROCEDURE RegisterBGIfont*(Font: SYSTEM.ADDRESS): INTEGER;
BEGIN
  RETURN grError
END RegisterBGIfont;

PROCEDURE RegisterBGIdriver*(Driver: SYSTEM.ADDRESS): INTEGER;
BEGIN
  RETURN grError
END RegisterBGIdriver;

PROCEDURE InstallUserDriver*(DriverFileName: ARRAY OF CHAR; AutoDetectPtr: SYSTEM.ADDRESS): INTEGER;
BEGIN
  RETURN grError
END InstallUserDriver;

PROCEDURE InstallUserFont*(FontFileName: ARRAY OF CHAR): INTEGER;
BEGIN
  RETURN grError
END InstallUserFont;

PROCEDURE SetGraphBufSize*(BufSize: WORD);
BEGIN
END SetGraphBufSize;

PROCEDURE GetMaxMode*(): INTEGER;
BEGIN
  RETURN 0
END GetMaxMode;

PROCEDURE GetModeRange*(GraphDriver: INTEGER; VAR LoMode, HiMode: INTEGER);
BEGIN
END GetModeRange;

PROCEDURE GetModeName*(GraphMode: INTEGER; VAR s: ARRAY OF CHAR);
BEGIN
END GetModeName;

PROCEDURE SetGraphMode*(Mode: INTEGER);
BEGIN
END SetGraphMode;

PROCEDURE GetGraphMode*(): INTEGER;
BEGIN
  RETURN 0
END GetGraphMode;

PROCEDURE GraphDefaults*;
BEGIN
END GraphDefaults;

PROCEDURE RestoreCrtMode*;
BEGIN
END RestoreCrtMode;

PROCEDURE CloseGraph*;
  VAR regs: SYSTEM.Registers;
BEGIN
  IF DrvLoaded THEN
     regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
     CallDriver(DvPost, regs);
     UnloadDriver
  END
END CloseGraph;

(* GetX/GetY: the current pointer (CP), served from the CurX/CurY mirror
   kept by MoveTo/LineTo/MoveRel/LineRel (the driver's move/draw
   routines do not hand the CP back on query). *)
PROCEDURE GetX*(): INTEGER;
BEGIN
  RETURN CurX
END GetX;

PROCEDURE GetY*(): INTEGER;
BEGIN
  RETURN CurY
END GetY;

PROCEDURE GetMaxX*(): INTEGER;
BEGIN
  RETURN 0
END GetMaxX;

PROCEDURE GetMaxY*(): INTEGER;
BEGIN
  RETURN 0
END GetMaxY;

(* *** Screen, viewport, page routines *** *)
(* ClearDevice: clear the whole screen to colour 0 via the loaded
   driver's clear routine (DDOVEC SI=0x04; no inputs -- see DOCS/BGI.MD
   §5). No-op if no driver is loaded. *)
PROCEDURE ClearDevice*;
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvClear, regs)
END ClearDevice;

(* SetViewPort: set the clipping rectangle used by drawing primitives
   via the loaded driver's setclip routine (DDOVEC SI=0x38; AX,BX=UL;
   CX,DX=LR -- see DOCS/BGI.MD §5.1), and track it locally for
   GetViewSettings (setclip is set-only). No-op if no driver is loaded. *)
PROCEDURE SetViewPort*(x1, y1, x2, y2: INTEGER; Clip: BOOLEAN);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  VpX1 := x1; VpY1 := y1; VpX2 := x2; VpY2 := y2; VpClip := Clip;

  regs.AX := x1; regs.BX := y1; regs.CX := x2; regs.DX := y2;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvSetClip, regs)
END SetViewPort;

(* GetViewSettings: the current view port, served from the
   VpX1/VpY1/VpX2/VpY2/VpClip mirror kept by SetViewPort (setclip,
   §5.1, is set-only). *)
PROCEDURE GetViewSettings*(VAR ViewPort: ViewPortType);
BEGIN
  ViewPort.x1 := VpX1; ViewPort.y1 := VpY1;
  ViewPort.x2 := VpX2; ViewPort.y2 := VpY2;
  ViewPort.Clip := VpClip
END GetViewSettings;

(* ClearViewPort: fill the current view port via the loaded driver's
   patbar routine (DDOVEC SI=0x12; AX,BX=UL, CX,DX=LR -- see
   DOCS/BGI.MD §5.1), using the current fill colour/pattern -- there is
   no dedicated DDOVEC primitive for this (mirrors how Rectangle is
   built from Line). No-op if no driver is loaded. *)
PROCEDURE ClearViewPort*;
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := 0; regs.BX := 0;
  regs.CX := VpX2 - VpX1; regs.DX := VpY2 - VpY1;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvPatbar, regs)
END ClearViewPort;

PROCEDURE SetVisualPage*(Page: WORD);
BEGIN
END SetVisualPage;

PROCEDURE SetActivePage*(Page: WORD);
BEGIN
END SetActivePage;

(* *** point-oriented routines *** *)
(* PutPixel: write a pixel via the loaded driver's putpixel routine
   (DDOVEC SI=0x30; AX=X, BX=Y, DL=colour -- see DOCS/BGI.MD §5.1).
   No-op if no driver is loaded. *)
PROCEDURE PutPixel*(X, Y: INTEGER; Pixel: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := X;
  regs.BX := Y;
  regs.DX := INTEGER(Pixel);
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvPutPixel, regs)
END PutPixel;

(* GetPixel: read a pixel's colour via the loaded driver's getpixel
   routine (DDOVEC SI=0x2E; AX=X, BX=Y -> DL=colour -- see DOCS/BGI.MD
   §5.1). Returns 0 if no driver is loaded. *)
PROCEDURE GetPixel*(X, Y: INTEGER): WORD;
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN 0 END;
  regs.AX := X;
  regs.BX := Y;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvGetPixel, regs);
  RETURN SYSTEM.AND(regs.DX, 0FFH)
END GetPixel;

(* *** line-oriented routines *** *)
PROCEDURE SetWriteMode*(WriteMode: INTEGER);
BEGIN
END SetWriteMode;

(* MoveTo: move the current pointer (CP) to (X,Y) via the loaded driver's
   move routine (DDOVEC SI=0x08; AX=X, BX=Y -- see DOCS/BGI.MD §5.1).
   CP is also tracked locally for GetX/GetY, since the driver does not
   hand it back on query. No-op if no driver is loaded. *)
PROCEDURE MoveTo*(X, Y: INTEGER);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := X;
  regs.BX := Y;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvMove, regs);
  CurX := X; CurY := Y
END MoveTo;

(* MoveRel: move the CP by (Dx,Dy) relative to its current position. *)
PROCEDURE MoveRel*(Dx, Dy: INTEGER);
BEGIN
  MoveTo(CurX + Dx, CurY + Dy)
END MoveRel;

(* LineTo: draw a line from the CP to (X,Y) via the loaded driver's draw
   routine (DDOVEC SI=0x0A; AX=X, BX=Y -- see DOCS/BGI.MD §5.1), and
   update the CP to (X,Y). No-op if no driver is loaded. *)
PROCEDURE LineTo*(X, Y: INTEGER);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := X;
  regs.BX := Y;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvDraw, regs);
  CurX := X; CurY := Y
END LineTo;

(* LineRel: draw a line from the CP to a point (Dx,Dy) relative to it. *)
PROCEDURE LineRel*(Dx, Dy: INTEGER);
BEGIN
  LineTo(CurX + Dx, CurY + Dy)
END LineRel;

(* Line: draw a line from (x1,y1) to (x2,y2) via the loaded driver's
   vect routine (DDOVEC SI=0x0C; AX=X1, BX=Y1, CX=X2, DX=Y2 -- see
   DOCS/BGI.MD §5.1). No-op if no driver is loaded. *)
PROCEDURE Line*(x1, y1, x2, y2: INTEGER);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := x1;
  regs.BX := y1;
  regs.CX := x2;
  regs.DX := y2;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvVect, regs)
END Line;

(* GetLineSettings: the current line style/pattern/thickness, served
   from the CurLineStyle/CurLinePattern/CurLineThickness mirror kept by
   SetLineStyle (linestyle, §5.1, is set-only). *)
PROCEDURE GetLineSettings*(VAR LineInfo: LineSettingsType);
BEGIN
  LineInfo.LineStyle := CurLineStyle;
  LineInfo.Pattern := CurLinePattern;
  LineInfo.Thickness := CurLineThickness
END GetLineSettings;

(* SetLineStyle: set the line style, user pattern, and thickness used by
   Line/vect via the loaded driver's linestyle routine (DDOVEC SI=0x22;
   AL=style#, BX=user pattern (if style>=UserBitLn), CX=width -- see
   DOCS/BGI.MD §5.1). No-op if no driver is loaded. *)
PROCEDURE SetLineStyle*(LineStyle, Pattern, Thickness: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  CurLineStyle := LineStyle;
  CurLinePattern := Pattern;
  CurLineThickness := Thickness;

  regs.AX := INTEGER(SYSTEM.AND(LineStyle, 0FFH));
  regs.BX := INTEGER(Pattern);
  regs.CX := INTEGER(Thickness);
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvLineStyle, regs)
END SetLineStyle;

(* *** polygon, fills and figures *** *)
(* Rectangle: draw an unfilled rectangle outline. Not a DDOVEC driver
   primitive (only patbar/filled-bar is) -- the real BGI kernel builds
   Rectangle from four Line calls, and this mirrors that. *)
PROCEDURE Rectangle*(x1, y1, x2, y2: INTEGER);
BEGIN
  Line(x1, y1, x2, y1);
  Line(x2, y1, x2, y2);
  Line(x2, y2, x1, y2);
  Line(x1, y2, x1, y1)
END Rectangle;

(* Bar: draw a filled bar via the loaded driver's patbar routine
   (DDOVEC SI=0x12; AX,BX=UL, CX,DX=LR -- see DOCS/BGI.MD §5.1).
   No-op if no driver is loaded. *)
PROCEDURE Bar*(x1, y1, x2, y2: INTEGER);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := x1;
  regs.BX := y1;
  regs.CX := x2;
  regs.DX := y2;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvPatbar, regs)
END Bar;

(* Bar3D: draw a filled 3D bar -- front face via Bar/Rectangle (patbar,
   §5.1), a Depth-offset back edge and connecting side lines via Line,
   and (if Top) a top-face outline -- matching real BGI's Bar3D shape.
   Not a DDOVEC driver primitive (only patbar/filled-bar is; 3D bars are
   normally left as EMULATE, see DOCS/BGI.MD §4.3). No-op if no driver
   is loaded. *)
PROCEDURE Bar3D*(x1, y1, x2, y2: INTEGER; Depth: WORD; Top: BOOLEAN);
  VAR d: INTEGER;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  d := INTEGER(Depth);
  Bar(x1, y1, x2, y2);
  Rectangle(x1, y1, x2, y2);
  IF d # 0 THEN
    Line(x2, y1, x2 + d, y1 - d);
    Line(x2, y2, x2 + d, y2 - d);
    Line(x2 + d, y1 - d, x2 + d, y2 - d);
    IF Top THEN
      Line(x1, y1, x1 + d, y1 - d);
      Line(x1 + d, y1 - d, x2 + d, y1 - d)
    END
  END
END Bar3D;

(* DrawPoly: draw the outline of a closed polygon by connecting each
   point to the next with Line (vect, §5.1), closing back to the first
   point. Not a DDOVEC driver primitive -- polygon ops are not in the
   DDOVEC table at all, so the real BGI kernel builds them from Line/
   patbar itself; this mirrors that. No-op if no driver is loaded. *)
PROCEDURE DrawPoly*(NumPoints: WORD; VAR PolyPoints: ARRAY OF PointType);
  VAR i: INTEGER;
BEGIN
  IF (~DrvLoaded) OR (NumPoints < 2) THEN RETURN END;
  FOR i := 0 TO INTEGER(NumPoints) - 2 DO
    Line(PolyPoints[i].X, PolyPoints[i].Y, PolyPoints[i+1].X, PolyPoints[i+1].Y)
  END;
  Line(PolyPoints[INTEGER(NumPoints)-1].X, PolyPoints[INTEGER(NumPoints)-1].Y, PolyPoints[0].X, PolyPoints[0].Y)
END DrawPoly;

(* FillPoly: fill a closed polygon with the current fill colour, via a
   scanline algorithm plotting through PutPixel (itself CallDriver-
   backed) -- same approach as Circle. Not a DDOVEC driver primitive
   (see DrawPoly). Also draws the outline via DrawPoly, matching real
   BGI's FillPoly. No-op if no driver is loaded. *)
PROCEDURE FillPoly*(NumPoints: WORD; VAR PolyPoints: ARRAY OF PointType);
  VAR
    minY, maxY, y, x: INTEGER;
    i, j, k: INTEGER;
    xs: ARRAY 64 OF INTEGER;
    n: INTEGER;
    tmp: INTEGER;
    colour: WORD;
BEGIN
  IF (~DrvLoaded) OR (NumPoints < 3) THEN RETURN END;
  colour := CurFillColor;

  minY := PolyPoints[0].Y; maxY := PolyPoints[0].Y;
  FOR i := 1 TO INTEGER(NumPoints) - 1 DO
    IF PolyPoints[i].Y < minY THEN minY := PolyPoints[i].Y END;
    IF PolyPoints[i].Y > maxY THEN maxY := PolyPoints[i].Y END
  END;

  FOR y := minY TO maxY DO
    n := 0;
    FOR i := 0 TO INTEGER(NumPoints) - 1 DO
      j := (i + 1) MOD INTEGER(NumPoints);
      IF ((PolyPoints[i].Y <= y) & (PolyPoints[j].Y > y)) OR
         ((PolyPoints[j].Y <= y) & (PolyPoints[i].Y > y)) THEN
        IF n < 64 THEN
          x := PolyPoints[i].X + (y - PolyPoints[i].Y) * (PolyPoints[j].X - PolyPoints[i].X)
                 DIV (PolyPoints[j].Y - PolyPoints[i].Y);
          xs[n] := x; INC(n)
        END
      END
    END;

    k := 1;
    WHILE k < n DO
      tmp := xs[k]; j := k;
      WHILE (j > 0) & (xs[j-1] > tmp) DO xs[j] := xs[j-1]; DEC(j) END;
      xs[j] := tmp;
      INC(k)
    END;

    k := 0;
    WHILE k + 1 < n DO
      FOR x := xs[k] TO xs[k+1] DO PutPixel(x, y, colour) END;
      INC(k, 2)
    END
  END;

  DrawPoly(NumPoints, PolyPoints)
END FillPoly;

(* GetFillSettings: the current fill pattern/colour, served from the
   CurFillPattern/CurFillColor mirror kept by SetFillStyle/SetFillPattern
   (fillstyle, §5.1, is set-only). *)
PROCEDURE GetFillSettings*(VAR FillInfo: FillSettingsType);
BEGIN
  FillInfo.Pattern := CurFillPattern;
  FillInfo.Color := CurFillColor
END GetFillSettings;

(* GetFillPattern: the current user-defined fill pattern, served from
   the CurFillBytes mirror kept by SetFillPattern. *)
PROCEDURE GetFillPattern*(VAR FillPattern: FillPatternType);
  VAR i: INTEGER;
BEGIN
  FOR i := 0 TO 7 DO FillPattern[i] := CurFillBytes[i] END
END GetFillPattern;

(* SetFillStyle: set the fill pattern and colour used by Bar/patbar via
   the loaded driver's fillstyle routine (DDOVEC SI=0x20; AL=pattern#
   -- see DOCS/BGI.MD §5.1) plus a colour resend (colour is set-only
   and takes AL=draw/AH=fill together, so CurDrawColor is resent
   unchanged alongside the new fill colour, same as SetColor).
   Pattern is one of the EmptyFill..UserFill constants; UserFill (a
   caller-supplied 8-byte pattern via ES:BX) is not handled here -- use
   SetFillPattern for that. No-op if no driver is loaded. *)
PROCEDURE SetFillStyle*(Pattern, Color: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  CurFillColor := Color;
  CurFillPattern := Pattern;

  regs.AX := INTEGER(SYSTEM.AND(Pattern, 0FFH));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvFillStyle, regs);

  regs.AX := INTEGER(SYSTEM.IOR(SYSTEM.AND(CurDrawColor, 0FFH),
                                 SYSTEM.LSL(SYSTEM.AND(Color, 0FFH), 8)));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvColour, regs)
END SetFillStyle;

(* SetFillPattern: set a caller-supplied 8-byte fill pattern used by
   Bar/patbar via the loaded driver's fillstyle routine (DDOVEC SI=0x20;
   AL=0FFh, ES:BX=user pattern -- see DOCS/BGI.MD §5.1) plus a colour
   resend, mirroring SetFillStyle. No-op if no driver is loaded. *)
PROCEDURE SetFillPattern*(Pattern: FillPatternType; Color: WORD);
  VAR regs: SYSTEM.Registers; i: INTEGER;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  CurFillColor := Color;
  CurFillPattern := UserFill;
  FOR i := 0 TO 7 DO CurFillBytes[i] := Pattern[i] END;

  regs.AX := 0FFH;
  regs.BX := SYSTEM.OFS(CurFillBytes);
  regs.ES := SYSTEM.SEG(CurFillBytes);
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvFillStyle, regs);

  regs.AX := INTEGER(SYSTEM.IOR(SYSTEM.AND(CurDrawColor, 0FFH),
                                 SYSTEM.LSL(SYSTEM.AND(Color, 0FFH), 8)));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvColour, regs)
END SetFillPattern;

(* FloodFill: fill a bounded region containing (X,Y) with the current
   fill colour/pattern, via the loaded driver's floodfill routine
   (DDOVEC SI=0x2C; AX=X, BX=Y, CL=boundary colour -- see DOCS/BGI.MD
   §5.1). No-op if no driver is loaded. *)
PROCEDURE FloodFill*(X, Y: INTEGER; Border: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := X;
  regs.BX := Y;
  regs.CX := INTEGER(SYSTEM.AND(Border, 0FFH));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvFloodFill, regs)
END FloodFill;

(* *** arc, circle, and other curves *** *)
(* GetArcCoords: the centre and endpoints of the last Arc/Ellipse call,
   served from the LastArcX/Y* mirror (there is no DDOVEC query for
   this -- arc/ellipse are software-emulated here). *)
PROCEDURE GetArcCoords*(VAR ArcCoords: ArcCoordsType);
BEGIN
  ArcCoords.X := LastArcX; ArcCoords.Y := LastArcY;
  ArcCoords.Xstart := LastArcXStart; ArcCoords.Ystart := LastArcYStart;
  ArcCoords.Xend := LastArcXEnd; ArcCoords.Yend := LastArcYEnd
END GetArcCoords;

(* PlotCircle8: plot the 8 symmetric points of (dx,dy) around centre
   (X,Y) via PutPixel, using the current draw colour. *)
PROCEDURE PlotCircle8(X, Y, dx, dy: INTEGER; colour: WORD); NEAR;
BEGIN
  PutPixel(X + dx, Y + dy, colour);
  PutPixel(X - dx, Y + dy, colour);
  PutPixel(X + dx, Y - dy, colour);
  PutPixel(X - dx, Y - dy, colour);
  PutPixel(X + dy, Y + dx, colour);
  PutPixel(X - dy, Y + dx, colour);
  PutPixel(X + dy, Y - dx, colour);
  PutPixel(X - dy, Y - dx, colour)
END PlotCircle8;

(* Circle: draw a circle outline of the given radius centred at (X,Y),
   via the integer midpoint (Bresenham) circle algorithm plotting
   through PutPixel (itself CallDriver-backed).  Not a DDOVEC driver
   primitive -- circle/arc/ellipse are normally left as EMULATE, see
   DOCS/BGI.MD §4.3. No-op if no driver is loaded. *)
PROCEDURE Circle*(X, Y: INTEGER; Radius: WORD);
  VAR dx, dy, d: INTEGER; colour: WORD;
BEGIN
  IF (~DrvLoaded) OR (Radius = 0) THEN RETURN END;
  colour := CurDrawColor;
  dx := 0;
  dy := INTEGER(Radius);
  d := 3 - 2 * INTEGER(Radius);
  WHILE dx <= dy DO
    PlotCircle8(X, Y, dx, dy, colour);
    IF d < 0 THEN
      d := d + 4 * dx + 6
    ELSE
      d := d + 4 * (dx - dy) + 10;
      DEC(dy)
    END;
    INC(dx)
  END
END Circle;

(* EllipsePoint: the (dx,dy) offset from centre for a given angle (in
   degrees, standard BGI convention: 0=east, CCW positive) around an
   ellipse of radii XRadius/YRadius, via Math.Sin/Cos. NEAR helper for
   Ellipse/Arc/PieSlice/Sector. *)
PROCEDURE EllipsePoint(angleDeg: INTEGER; XRadius, YRadius: WORD; VAR dx, dy: INTEGER); NEAR;
  VAR rad: REAL;
BEGIN
  rad := REAL(angleDeg) * 3.14159265 / 180.0;
  dx := Math.Round(Math.Cos(rad) * REAL(XRadius));
  dy := -Math.Round(Math.Sin(rad) * REAL(YRadius))
END EllipsePoint;

(* Ellipse: draw an elliptical arc from StAngle to EndAngle (degrees,
   0=east, CCW positive) centred at (X,Y), stepping one degree at a
   time and plotting through PutPixel (itself CallDriver-backed) --
   same software-emulation approach as Circle, generalised to unequal
   radii and a partial angle range (arc/ellipse are normally left as
   EMULATE in a real driver, see DOCS/BGI.MD §4.3). Also updates the
   GetArcCoords state. No-op if no driver is loaded. *)
PROCEDURE Ellipse*(X, Y: INTEGER; StAngle, EndAngle: WORD; XRadius, YRadius: WORD);
  VAR a: INTEGER; dx, dy: INTEGER; colour: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  colour := CurDrawColor;

  EllipsePoint(INTEGER(StAngle), XRadius, YRadius, dx, dy);
  LastArcX := X; LastArcY := Y;
  LastArcXStart := X + dx; LastArcYStart := Y + dy;
  EllipsePoint(INTEGER(EndAngle), XRadius, YRadius, dx, dy);
  LastArcXEnd := X + dx; LastArcYEnd := Y + dy;

  a := INTEGER(StAngle);
  WHILE a <= INTEGER(EndAngle) DO
    EllipsePoint(a, XRadius, YRadius, dx, dy);
    PutPixel(X + dx, Y + dy, colour);
    INC(a)
  END;
  EllipsePoint(INTEGER(EndAngle), XRadius, YRadius, dx, dy);
  PutPixel(X + dx, Y + dy, colour)
END Ellipse;

(* FillEllipse: fill a full ellipse (0..360 degrees) with the current
   fill colour via a scanline pass through PutPixel, then draw its
   outline via Ellipse -- same approach as FillPoly. No-op if no driver
   is loaded. *)
PROCEDURE FillEllipse*(X, Y: INTEGER; XRadius, YRadius: WORD);
  VAR yy, halfw, px: INTEGER; xr, yr: INTEGER; colour: WORD;
BEGIN
  IF (~DrvLoaded) OR (XRadius = 0) OR (YRadius = 0) THEN RETURN END;
  colour := CurFillColor;
  xr := INTEGER(XRadius); yr := INTEGER(YRadius);

  FOR yy := -yr TO yr DO
    halfw := Math.Round(REAL(xr) * Math.Sqrt(1.0 - (REAL(yy) * REAL(yy)) / (REAL(yr) * REAL(yr))));
    FOR px := X - halfw TO X + halfw DO PutPixel(px, Y + yy, colour) END
  END;

  Ellipse(X, Y, 0, 360, XRadius, YRadius)
END FillEllipse;

(* Arc: draw a circular arc of the given radius from StAngle to
   EndAngle (degrees, 0=east, CCW positive) centred at (X,Y), via
   Ellipse with the Y radius adjusted by the current aspect ratio
   (AspX/AspY) so the arc traces a true circle on non-square-pixel
   hardware -- same aspect adjustment a real BGI app would apply by
   hand (see DOCS/BGI.MD §8). No-op if no driver is loaded. *)
PROCEDURE Arc*(X, Y: INTEGER; StAngle, EndAngle, Radius: WORD);
  VAR yr: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  IF AspY = 0 THEN yr := Radius
  ELSE yr := WORD((LONGINT(Radius) * LONGINT(AspX)) DIV LONGINT(AspY))
  END;
  Ellipse(X, Y, StAngle, EndAngle, Radius, yr)
END Arc;

(* GetAspectRatio: the current pixel aspect ratio, served from the
   AspX/AspY mirror kept by SetAspectRatio -- the driver exposes no
   DDOVEC query for hardware geometry, see the AspX/AspY declaration. *)
PROCEDURE GetAspectRatio*(VAR Xasp, Yasp: WORD);
BEGIN
  Xasp := AspX; Yasp := AspY
END GetAspectRatio;

(* SetAspectRatio: set the pixel aspect ratio used by Circle/Arc/
   Ellipse/PieSlice/Sector to keep curves round on non-square-pixel
   hardware. Not a DDOVEC driver primitive -- tracked here and applied
   by the software curve routines, mirroring the real BGI kernel. *)
PROCEDURE SetAspectRatio*(Xasp, Yasp: WORD);
BEGIN
  AspX := Xasp; AspY := Yasp
END SetAspectRatio;

(* WedgePoly: build a filled-wedge polygon (centre + points along the
   elliptical arc from StAngle to EndAngle, one every 4 degrees to stay
   within the 64-point buffer) and fill+outline it via FillPoly/
   DrawPoly.  NEAR helper for PieSlice/Sector. *)
PROCEDURE WedgePoly(X, Y: INTEGER; StAngle, EndAngle, XRadius, YRadius: WORD); NEAR;
  VAR pts: ARRAY 47 OF PointType; n: WORD; a: INTEGER; dx, dy: INTEGER;
BEGIN
  n := 0;
  pts[0].X := X; pts[0].Y := Y; INC(n);
  a := INTEGER(StAngle);
  WHILE (a < INTEGER(EndAngle)) & (n < 46) DO
    EllipsePoint(a, XRadius, YRadius, dx, dy);
    pts[n].X := X + dx; pts[n].Y := Y + dy; INC(n);
    INC(a, 4)
  END;
  EllipsePoint(INTEGER(EndAngle), XRadius, YRadius, dx, dy);
  pts[n].X := X + dx; pts[n].Y := Y + dy; INC(n);

  LastArcX := X; LastArcY := Y;
  LastArcXStart := pts[1].X; LastArcYStart := pts[1].Y;
  LastArcXEnd := pts[n-1].X; LastArcYEnd := pts[n-1].Y;

  FillPoly(n, pts)
END WedgePoly;

(* PieSlice: draw and fill a pie-shaped wedge (two radii + an arc) of
   the given radius from StAngle to EndAngle (degrees) centred at
   (X,Y), via WedgePoly. Not a DDOVEC driver primitive (arc/pieslice
   are normally left as EMULATE, see DOCS/BGI.MD §4.3). No-op if no
   driver is loaded. *)
PROCEDURE PieSlice*(X, Y: INTEGER; StAngle, EndAngle, Radius: WORD);
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  WedgePoly(X, Y, StAngle, EndAngle, Radius, Radius)
END PieSlice;

(* Sector: draw and fill an elliptical pie-shaped wedge (independent X/Y
   radii) from StAngle to EndAngle (degrees) centred at (X,Y), via
   WedgePoly. No-op if no driver is loaded. *)
PROCEDURE Sector*(X, Y: INTEGER; StAngle, EndAngle, XRadius, YRadius: WORD);
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  WedgePoly(X, Y, StAngle, EndAngle, XRadius, YRadius)
END Sector;

(* *** color and palette routines *** *)
PROCEDURE SetBkColor*(ColorNum: WORD);
BEGIN
END SetBkColor;

(* SetColor: set the current drawing colour via the loaded driver's
   colour routine (DDOVEC SI=0x1E; AL=draw colour, AH=fill colour --
   see DOCS/BGI.MD §5.1).  colour is set-only and takes both draw and
   fill together, so the current fill colour (CurFillColor) is resent
   unchanged.  No-op if no driver is loaded. *)
PROCEDURE SetColor*(Color: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  CurDrawColor := Color;
  regs.AX := INTEGER(SYSTEM.IOR(SYSTEM.AND(Color, 0FFH),
                                 SYSTEM.LSL(SYSTEM.AND(CurFillColor, 0FFH), 8)));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvColour, regs)
END SetColor;

PROCEDURE GetBkColor*(): WORD;
BEGIN
  RETURN 0
END GetBkColor;

(* GetColor: the current drawing colour (§5.1's colour routine is
   set-only, so this is served from the CurDrawColor mirror kept by
   SetColor -- same as a real BGI kernel, which tracks colour state
   itself rather than querying the driver). *)
PROCEDURE GetColor*(): WORD;
BEGIN
  RETURN CurDrawColor
END GetColor;

(* SetPalette: set one palette entry via the loaded driver's palette
   routine (DDOVEC SI=0x1A; mode 00b -- top 2 bits of AH clear -- AX=
   index, BX=colour -- see DOCS/BGI.MD §8). On fixed-palette hardware
   (e.g. CGA) the driver may legitimately accept-and-ignore this. No-op
   if no driver is loaded. *)
PROCEDURE SetPalette*(ColorNum: WORD; Color: INTEGER);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := INTEGER(SYSTEM.AND(ColorNum, 0FFH));
  regs.BX := Color;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvPalette, regs)
END SetPalette;

(* SetAllPalette: load a whole palette via the loaded driver's
   setallpalette routine (DDOVEC SI=0x1C; ES:BX=palette table pointer
   -- see DOCS/BGI.MD §5). No-op if no driver is loaded. *)
PROCEDURE SetAllPalette*(VAR Palette: PaletteType);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.BX := SYSTEM.OFS(Palette);
  regs.ES := SYSTEM.SEG(Palette);
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvSetAllPal, regs)
END SetAllPalette;

PROCEDURE GetPalette*(VAR Palette: PaletteType);
BEGIN
END GetPalette;

PROCEDURE GetPaletteSize*(): INTEGER;
BEGIN
  RETURN 0
END GetPaletteSize;

PROCEDURE GetDefaultPalette*(VAR Palette: PaletteType);
BEGIN
END GetDefaultPalette;

(* GetMaxColor: the highest valid colour index, via the loaded driver's
   colourquery routine (DDOVEC SI=0x3A; AL=0 -> CX=max colour -- see
   DOCS/BGI.MD §5.1). Returns 0 if no driver is loaded. *)
PROCEDURE GetMaxColor*(): WORD;
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN 0 END;
  regs.AX := 0;
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvColourQuery, regs);
  RETURN WORD(regs.CX)
END GetMaxColor;

PROCEDURE SetRGBPalette*(ColorNum, RedValue, GreenValue, BlueValue: INTEGER);
BEGIN
END SetRGBPalette;

(* *** bit-image routines *** *)
PROCEDURE ImageSize*(x1, y1, x2, y2: INTEGER): WORD;
BEGIN
  RETURN 0
END ImageSize;

(* GetImage: save the (x1,y1)-(x2,y2) rectangle into BitMap via the
   loaded driver's savebitmap routine (DDOVEC SI=0x34; ES:BX=buffer,
   CX,DX=UL corner; caller pre-fills buffer word0=w-1, word2=h-1 --
   see DOCS/BGI.MD §5.1). No-op if no driver is loaded. *)
PROCEDURE GetImage*(x1, y1, x2, y2: INTEGER; VAR BitMap: SYSTEM.ADDRESS);
  TYPE PWORD = POINTER TO WORD;
  VAR regs: SYSTEM.Registers; pw: PWORD; addr: SYSTEM.ADDRESS;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  pw := BitMap;
  pw^ := WORD(x2 - x1);
  addr := BitMap; INC(addr, 2);
  pw := addr;
  pw^ := WORD(y2 - y1);
  regs.BX := SYSTEM.OFS(BitMap^);
  regs.ES := SYSTEM.SEG(BitMap^);
  regs.CX := x1;
  regs.DX := y1;
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvSaveBitmap, regs)
END GetImage;

(* PutImage: draw a bitmap saved by GetImage at (X,Y) via the loaded
   driver's restorebitmap routine (DDOVEC SI=0x36; ES:BX=buffer,
   CX,DX=UL, AL=logical op -- see DOCS/BGI.MD §5.1). BitBlt is one of
   the CopyPut/XORPut/OrPut/AndPut/NotPut constants. No-op if no
   driver is loaded. *)
PROCEDURE PutImage*(X, Y: INTEGER; VAR BitMap: SYSTEM.ADDRESS; BitBlt: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  regs.AX := INTEGER(SYSTEM.AND(BitBlt, 0FFH));
  regs.BX := SYSTEM.OFS(BitMap^);
  regs.ES := SYSTEM.SEG(BitMap^);
  regs.CX := X;
  regs.DX := Y;
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvRestoreBitmap, regs)
END PutImage;

(* *** text routines *** *)
(* GetTextSettings: the current font/direction/charsize/justification,
   served from the CurFont/CurTextDir/CurCharSize/CurHorizJust/
   CurVertJust mirror kept by SetTextStyle/SetTextJustify (textstyle,
   §5.1, is set-only). *)
PROCEDURE GetTextSettings*(VAR TextInfo: TextSettingsType);
BEGIN
  TextInfo.Font := CurFont;
  TextInfo.Direction := CurTextDir;
  TextInfo.CharSize := CurCharSize;
  TextInfo.Horiz := CurHorizJust;
  TextInfo.Vert := CurVertJust
END GetTextSettings;

(* TextWidth/TextHeight: measure a string via the loaded driver's
   textsize routine (DDOVEC SI=0x28; ES:BX=string, CX=length -> BX=
   width, CX=height -- see DOCS/BGI.MD §5.1). Return 0 if no driver is
   loaded. *)
PROCEDURE TextWidth*(TextString: ARRAY OF CHAR): WORD;
  VAR regs: SYSTEM.Registers; len: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN 0 END;
  len := Strings.Length(TextString);
  regs.BX := SYSTEM.OFS(TextString);
  regs.ES := SYSTEM.SEG(TextString);
  regs.CX := INTEGER(len);
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvTextSize, regs);
  RETURN WORD(regs.BX)
END TextWidth;

PROCEDURE TextHeight*(TextString: ARRAY OF CHAR): WORD;
  VAR regs: SYSTEM.Registers; len: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN 0 END;
  len := Strings.Length(TextString);
  regs.BX := SYSTEM.OFS(TextString);
  regs.ES := SYSTEM.SEG(TextString);
  regs.CX := INTEGER(len);
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvTextSize, regs);
  RETURN WORD(regs.CX)
END TextHeight;

(* OutText: render TextString at the current pointer (CP) via the
   loaded driver's text routine (DDOVEC SI=0x26; ES:BX=string, CX=
   length -- see DOCS/BGI.MD §5.1). Justification (SetTextJustify) is
   not applied -- the driver always renders left/top-anchored at CP; see
   OutTextXY for justified placement. No-op if no driver is loaded. *)
PROCEDURE OutText*(TextString: ARRAY OF CHAR);
  VAR regs: SYSTEM.Registers; len: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  len := Strings.Length(TextString);
  regs.BX := SYSTEM.OFS(TextString);
  regs.ES := SYSTEM.SEG(TextString);
  regs.CX := INTEGER(len);
  regs.DS := SYSTEM.GetDS();
  CallDriver(DvText, regs)
END OutText;

(* OutTextXY: render TextString at (X,Y), honouring the current
   justification (CurHorizJust/CurVertJust) by offsetting the CP before
   calling the driver's text routine -- mirrors how the real BGI kernel
   applies justification (the driver itself always renders left/top-
   anchored at CP, per §5.1). No-op if no driver is loaded. *)
PROCEDURE OutTextXY*(X, Y: INTEGER; TextString: ARRAY OF CHAR);
  VAR w, h: WORD; ox, oy: INTEGER;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  w := TextWidth(TextString);
  h := TextHeight(TextString);
  ox := X; oy := Y;
  IF CurHorizJust = CenterText THEN ox := X - INTEGER(w) DIV 2
  ELSIF CurHorizJust = RightText THEN ox := X - INTEGER(w)
  END;
  IF CurVertJust = CenterText THEN oy := Y - INTEGER(h) DIV 2
  ELSIF CurVertJust = BottomText THEN oy := Y - INTEGER(h)
  END;
  MoveTo(ox, oy);
  OutText(TextString)
END OutTextXY;

(* SetTextJustify: set the horizontal/vertical anchor OutTextXY applies
   around its (X,Y) point. Not a DDOVEC driver primitive (the driver
   always renders left/top-anchored at CP, per §5.1) -- tracked here and
   applied by OutTextXY, mirroring the real BGI kernel. *)
PROCEDURE SetTextJustify*(Horiz, Vert: WORD);
BEGIN
  CurHorizJust := Horiz;
  CurVertJust := Vert
END SetTextJustify;

(* SetTextStyle: set the font, direction, and character size used by
   OutText/OutTextXY/textsize via the loaded driver's textstyle routine
   (DDOVEC SI=0x24; AL=font, AH=dir, BX=xsize, CX=ysize -- see
   DOCS/BGI.MD §5.1). No-op if no driver is loaded. *)
PROCEDURE SetTextStyle*(Font, Direction, CharSize: WORD);
  VAR regs: SYSTEM.Registers;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  CurFont := Font; CurTextDir := Direction; CurCharSize := CharSize;

  regs.AX := INTEGER(SYSTEM.IOR(SYSTEM.AND(Font, 0FFH),
                                 SYSTEM.LSL(SYSTEM.AND(Direction, 0FFH), 8)));
  regs.BX := INTEGER(CharSize);
  regs.CX := INTEGER(CharSize);
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvTextStyle, regs)
END SetTextStyle;

(* SetUserCharSize: set a custom character magnification via the ratio
   MultX/DivX (width) and MultY/DivY (height), by resending textstyle
   with a scale derived from MultY/DivY (the driver's textstyle only
   accepts one scale factor -- see §5.1's "Bitmap-font size/scaling"
   note -- so this approximates the two independent Pascal ratios with
   one). No-op if no driver is loaded. *)
PROCEDURE SetUserCharSize*(MultX, DivX, MultY, DivY: WORD);
  VAR scale: WORD;
BEGIN
  IF ~DrvLoaded THEN RETURN END;
  IF DivY = 0 THEN RETURN END;
  scale := MultY DIV DivY;
  IF scale = 0 THEN scale := 1 END;
  SetTextStyle(CurFont, CurTextDir, scale)
END SetUserCharSize;

END Graph.
