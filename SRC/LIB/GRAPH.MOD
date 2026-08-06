(*$D-,R-,A-*)
(* Graph — Trubo Oberon implementation BGI graphics interface. *)
MODULE Graph;

IMPORT Files, Det := Detect;

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
DvVect         = 6;   (* SI 0x0C *)
DvPatbar       = 9;   (* SI 0x12 *)
DvColour       = 15;  (* SI 0x1E *)
DvFillStyle    = 16;  (* SI 0x20 *)
DvDone         = 23;  (* SI 0x2E *)
DvGetPixel     = 23;  (* SI 0x2E *)
DvPutPixel     = 24;  (* SI 0x30 *)
DvSaveBitmap   = 26;  (* SI 0x34 *)
DvRestoreBitmap = 27; (* SI 0x36 *)

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

PROCEDURE GetX*(): INTEGER;
BEGIN
  RETURN 0
END GetX;

PROCEDURE GetY*(): INTEGER;
BEGIN
  RETURN 0
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
PROCEDURE ClearDevice*;
BEGIN
END ClearDevice;

PROCEDURE SetViewPort*(x1, y1, x2, y2: INTEGER; Clip: BOOLEAN);
BEGIN
END SetViewPort;

PROCEDURE GetViewSettings*(VAR ViewPort: ViewPortType);
BEGIN
END GetViewSettings;

PROCEDURE ClearViewPort*;
BEGIN
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

PROCEDURE LineTo*(X, Y: INTEGER);
BEGIN
END LineTo;

PROCEDURE LineRel*(Dx, Dy: INTEGER);
BEGIN
END LineRel;

PROCEDURE MoveTo*(X, Y: INTEGER);
BEGIN
END MoveTo;

PROCEDURE MoveRel*(Dx, Dy: INTEGER);
BEGIN
END MoveRel;

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

PROCEDURE GetLineSettings*(VAR LineInfo: LineSettingsType);
BEGIN
END GetLineSettings;

PROCEDURE SetLineStyle*(LineStyle, Pattern, Thickness: WORD);
BEGIN
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

PROCEDURE Bar3D*(x1, y1, x2, y2: INTEGER; Depth: WORD; Top: BOOLEAN);
BEGIN
END Bar3D;

PROCEDURE DrawPoly*(NumPoints: WORD; VAR PolyPoints: ARRAY OF PointType);
BEGIN
END DrawPoly;

PROCEDURE FillPoly*(NumPoints: WORD; VAR PolyPoints: ARRAY OF PointType);
BEGIN
END FillPoly;

PROCEDURE GetFillSettings*(VAR FillInfo: FillSettingsType);
BEGIN
END GetFillSettings;

PROCEDURE GetFillPattern*(VAR FillPattern: FillPatternType);
BEGIN
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

  regs.AX := INTEGER(SYSTEM.AND(Pattern, 0FFH));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvFillStyle, regs);

  regs.AX := INTEGER(SYSTEM.IOR(SYSTEM.AND(CurDrawColor, 0FFH),
                                 SYSTEM.LSL(SYSTEM.AND(Color, 0FFH), 8)));
  regs.DS := SYSTEM.GetDS(); regs.ES := SYSTEM.GetES();
  CallDriver(DvColour, regs)
END SetFillStyle;

PROCEDURE SetFillPattern*(Pattern: FillPatternType; Color: WORD);
BEGIN
END SetFillPattern;

PROCEDURE FloodFill*(X, Y: INTEGER; Border: WORD);
BEGIN
END FloodFill;

(* *** arc, circle, and other curves *** *)
PROCEDURE Arc*(X, Y: INTEGER; StAngle, EndAngle, Radius: WORD);
BEGIN
END Arc;

PROCEDURE GetArcCoords*(VAR ArcCoords: ArcCoordsType);
BEGIN
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

PROCEDURE Ellipse*(X, Y: INTEGER; StAngle, EndAngle: WORD; XRadius, YRadius: WORD);
BEGIN
END Ellipse;

PROCEDURE FillEllipse*(X, Y: INTEGER; XRadius, YRadius: WORD);
BEGIN
END FillEllipse;

PROCEDURE GetAspectRatio*(VAR Xasp, Yasp: WORD);
BEGIN
END GetAspectRatio;

PROCEDURE SetAspectRatio*(Xasp, Yasp: WORD);
BEGIN
END SetAspectRatio;

PROCEDURE PieSlice*(X, Y: INTEGER; StAngle, EndAngle, Radius: WORD);
BEGIN
END PieSlice;

PROCEDURE Sector*(X, Y: INTEGER; StAngle, EndAngle, XRadius, YRadius: WORD);
BEGIN
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

PROCEDURE SetAllPalette*(VAR Palette: PaletteType);
BEGIN
END SetAllPalette;

PROCEDURE SetPalette*(ColorNum: WORD; Color: INTEGER);
BEGIN
END SetPalette;

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

PROCEDURE GetMaxColor*(): WORD;
BEGIN
  RETURN 0
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
PROCEDURE GetTextSettings*(VAR TextInfo: TextSettingsType);
BEGIN
END GetTextSettings;

PROCEDURE OutText*(TextString: ARRAY OF CHAR);
BEGIN
END OutText;

PROCEDURE OutTextXY*(X, Y: INTEGER; TextString: ARRAY OF CHAR);
BEGIN
END OutTextXY;

PROCEDURE SetTextJustify*(Horiz, Vert: WORD);
BEGIN
END SetTextJustify;

PROCEDURE SetTextStyle*(Font, Direction, CharSize: WORD);
BEGIN
END SetTextStyle;

PROCEDURE SetUserCharSize*(MultX, DivX, MultY, DivY: WORD);
BEGIN
END SetUserCharSize;

PROCEDURE TextHeight*(TextString: ARRAY OF CHAR): WORD;
BEGIN
  RETURN 0
END TextHeight;

PROCEDURE TextWidth*(TextString: ARRAY OF CHAR): WORD;
BEGIN
  RETURN 0
END TextWidth;

END Graph.
