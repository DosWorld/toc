MODULE Screen;
(* Text-mode screen buffer driver -- shadow buffer + blit, color
   print/scroll, cursor, spinner, VGA palette fades. See SCREEN.ASM
   for the assembly leaf routines (BIOS/DOS INT calls, the INT 1Ch
   spinner handler) and their exact register conventions. Every
   module-level EXTERNAL procedure below maps 1:1 to a SCREEN.ASM
   routine of the same name (module-name-prefixed at link time,
   e.g. Cls -> Screen_Cls). *)

IMPORT Dos, Detect, KMouse;

CONST
  (* Fade0/FadeIn/FadeOut palette-adjustment tuning: ported unchanged
     from the original Pascal FADE_STEP/FADE_DELAY constants. *)
  FadeStep  = 8;
  FadeDelay = 15;

  (* Port I/O addresses for the VGA DAC (palette) registers. *)
  PortDacIndex = 3C7H;
  PortDacData  = 3C9H;
  PortDacWrite = 3C8H;

CONST
  ScrChunk = 32;   (* entries per ScrDesc chunk node, see "Chunk small records" *)

TYPE
  (* PScr: one chunk of up to ScrChunk saved-screen-buffer stack slots
     (Screen.Push/Pop/Pick's linked stack). Ported from the Pascal TScr
     record; the variable-length payload ("buf: byte" flexible-array-
     member trick in the original) is a separately NEW'd byte buffer per
     slot, linked via the buf[] array -- simpler and safer than
     replicating the flexible-array-member layout in Oberon. Slots are
     packed low-to-high within a chunk (count live entries); a new node
     is only allocated once the current top chunk fills. *)
  PScr = POINTER TO ScrDesc;
  ScrDesc = RECORD
    size:  ARRAY ScrChunk OF WORD;
    x, y:  ARRAY ScrChunk OF INTEGER;
    buf:   ARRAY ScrChunk OF SYSTEM.ADDRESS;
    count: INTEGER;
    prev:  PScr
  END;

VAR
  screen:        SYSTEM.ADDRESS;      (* far pointer to the shadow screen buffer *)
  cursor:        WORD;                (* saved hardware cursor shape, from module init *)
  screenSize:    WORD;
  lineSize:      WORD;

  lastScrBuf:    PScr;                (* Push/Pop/Pick stack top chunk *)

  spinnerOldInt: SYSTEM.ADDRESS;
  spinnerOn:     BOOLEAN;

  palette:       ARRAY 256 * 3 OF BYTE;
  vga:           BOOLEAN;

(* ---- SCREEN.ASM leaf routines (EXTERNAL) ---- *)

PROCEDURE SetBuf(p: SYSTEM.ADDRESS); EXTERNAL;
PROCEDURE SetLineSize(w: WORD); EXTERNAL;
PROCEDURE SetScreenSize(n: WORD); EXTERNAL;
PROCEDURE SetVSeg(seg: WORD); EXTERNAL;


(* GetWidth returns the number of text columns in the current video
   mode. No parameters. Result: column count (BIOS word 0040h:004Ah). *)
PROCEDURE GetWidth*(): INTEGER; EXTERNAL;

(* GetHeight returns the number of text rows in the current video mode.
   No parameters. Result: row count (BIOS byte 0040h:0084h + 1). *)
PROCEDURE GetHeight*(): INTEGER; EXTERNAL;

PROCEDURE ClsAsm(clr: BYTE); EXTERNAL;
PROCEDURE ClnAsm(x, y: INTEGER; clr: BYTE); EXTERNAL;
PROCEDURE HPrintAsm(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER); EXTERNAL;
PROCEDURE ChColorAsm(x, y: INTEGER; clr: BYTE; len: INTEGER); EXTERNAL;
PROCEDURE VPrintAsm(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER); EXTERNAL;
PROCEDURE PrintAsm(x, y: INTEGER; clr: BYTE; s: SYSTEM.ADDRESS); EXTERNAL;
PROCEDURE PrintHlAsm(x, y: INTEGER; clr, hlclr: BYTE; s: SYSTEM.ADDRESS); EXTERNAL;
PROCEDURE ShowAsm; EXTERNAL;

PROCEDURE LocateAsm(x, y: INTEGER); EXTERNAL;

(* GetX returns the current hardware text-cursor column. No parameters.
   Result: the column. *)
PROCEDURE GetX*(): INTEGER; EXTERNAL;

(* GetY returns the current hardware text-cursor row. No parameters.
   Result: the row. *)
PROCEDURE GetY*(): INTEGER; EXTERNAL;

PROCEDURE SetCursorAsm(w: WORD); EXTERNAL;
PROCEDURE GetCursorAsm(): WORD; EXTERNAL;
PROCEDURE SetBlinkAsm(on: BOOLEAN); EXTERNAL;

PROCEDURE DelayAsm(ms: WORD); EXTERNAL;
PROCEDURE WaitRetraceAsm; EXTERNAL;

PROCEDURE Spinner1c; FAR; EXTERNAL;

(*$L SCREEN.RDF*)

(* Cls clears the entire shadow screen buffer to spaces in color clr.
   Parameters: clr -- the fill attribute byte. Result: none. Call Show
   afterward to make the change visible on real video memory. *)
PROCEDURE Cls*(clr: BYTE);
BEGIN ClsAsm(clr)
END Cls;

(* Cln clears from column x to the last column of row y in color clr.
   Parameters: x, y -- starting cell; clr -- fill attribute byte.
   Result: none. *)
PROCEDURE Cln*(x, y: INTEGER; clr: BYTE);
BEGIN ClnAsm(x, y, clr)
END Cln;

(* Print writes the Pascal-style length-prefixed string s at (x,y) in
   color clr. Parameters: x, y -- starting cell; clr -- attribute byte;
   s -- length-prefixed string (s^ = length, s^[1..] = characters,
   matching Turbo Pascal's ShortString layout). Result: none. *)
PROCEDURE Print*(x, y: INTEGER; clr: BYTE; s: SYSTEM.ADDRESS);
BEGIN PrintAsm(x, y, clr, s)
END Print;

(* PrintHl is like Print, but every '~' character in s toggles between
   clr and hlclr instead of being displayed. Parameters: x, y -- starting
   cell; clr -- initial attribute byte; hlclr -- the attribute '~'
   toggles to; s -- length-prefixed string. Result: none. *)
PROCEDURE PrintHl*(x, y: INTEGER; clr, hlclr: BYTE; s: SYSTEM.ADDRESS);
BEGIN PrintHlAsm(x, y, clr, hlclr, s)
END PrintHl;

(* HPrint draws a horizontal run of len copies of character c in color
   clr, starting at (x,y). Parameters: x, y -- starting cell; clr --
   attribute byte; c -- character to repeat; len -- run length.
   Result: none. *)
PROCEDURE HPrint*(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER);
BEGIN HPrintAsm(x, y, clr, c, len)
END HPrint;

(* VPrint draws a vertical run of len copies of character c in color
   clr, starting at (x,y) and advancing one screen row per cell.
   Parameters: x, y -- starting cell; clr -- attribute byte; c --
   character to repeat; len -- run length. Result: none. *)
PROCEDURE VPrint*(x, y: INTEGER; clr: BYTE; c: CHAR; len: INTEGER);
BEGIN VPrintAsm(x, y, clr, c, len)
END VPrint;

(* ChColor recolors len cells starting at (x,y) to attribute clr without
   changing their character bytes. Parameters: x, y -- starting cell;
   clr -- new attribute byte; len -- number of cells. Result: none. *)
PROCEDURE ChColor*(x, y: INTEGER; clr: BYTE; len: INTEGER);
BEGIN ChColorAsm(x, y, clr, len)
END ChColor;

(* Show blits the shadow screen buffer to real video memory, hiding and
   re-showing the mouse cursor around the blit so a visible cursor
   sprite is never partially overwritten. No parameters, no result. *)
PROCEDURE Show*;
BEGIN ShowAsm
END Show;

(* Locate moves the hardware text cursor to (x,y). Parameters: x, y --
   target column/row. Result: none. *)
PROCEDURE Locate*(x, y: INTEGER);
BEGIN LocateAsm(x, y)
END Locate;

(* CursorOff hides the hardware text cursor (sets an off-screen cursor
   shape). No parameters, no result. *)
PROCEDURE CursorOff*;
BEGIN SetCursorAsm(2020H)
END CursorOff;

(* CursorOn restores the hardware text cursor to the shape saved by the
   module's initialization (the shape active when Screen was loaded).
   No parameters, no result. *)
PROCEDURE CursorOn*;
BEGIN SetCursorAsm(cursor)
END CursorOn;

(* CursorBig widens the cursor to a full-height block by clearing the
   high byte of the saved shape (the start-scanline byte), leaving only
   the end-scanline byte -- a common "block cursor" trick. No
   parameters, no result. *)
PROCEDURE CursorBig*;
BEGIN SetCursorAsm(SYSTEM.AND(cursor, 0FFH))
END CursorBig;

(* SetBlink toggles the CGA/EGA/VGA high-intensity-background-vs-blink
   attribute bit. Parameters: on -- TRUE selects blinking text, FALSE
   selects high-intensity background colors instead. Result: none. *)
PROCEDURE SetBlink*(on: BOOLEAN);
BEGIN SetBlinkAsm(on)
END SetBlink;

(* Push allocates a new save-buffer, copies the current shadow screen
   contents and cursor position into it, and pushes it onto the
   save-buffer stack (see Pop/Pick). Entries are packed ScrChunk-per-
   node; a fresh chunk node is allocated only when the top chunk is
   full. No parameters, no result. *)
PROCEDURE Push*;
  VAR p: PScr; buf: SYSTEM.ADDRESS; k: INTEGER;
BEGIN
  NEW(buf, screenSize);
  IF buf = NIL THEN RETURN END;
  IF (lastScrBuf = NIL) OR (lastScrBuf.count >= ScrChunk) THEN
    NEW(p);
    IF p = NIL THEN RETURN END;
    p.count := 0;
    p.prev := lastScrBuf;
    lastScrBuf := p
  END;
  k := lastScrBuf.count;
  lastScrBuf.size[k] := screenSize;
  lastScrBuf.x[k] := GetX();
  lastScrBuf.y[k] := GetY();
  lastScrBuf.buf[k] := buf;
  SYSTEM.MOVE(screen, buf, screenSize);
  INC(lastScrBuf.count)
END Push;

(* Pop restores the shadow screen contents and cursor position from the
   top of the save-buffer stack and removes it (see Push/Pick). A no-op
   if the stack is empty. Once a chunk's last entry is removed, the
   (now-empty) chunk node itself is unlinked and freed. No parameters,
   no result. *)
PROCEDURE Pop*;
  VAR p: PScr; k: INTEGER;
BEGIN
  IF lastScrBuf = NIL THEN RETURN END;
  k := lastScrBuf.count - 1;
  SYSTEM.MOVE(lastScrBuf.buf[k], screen, lastScrBuf.size[k]);
  LocateAsm(lastScrBuf.x[k], lastScrBuf.y[k]);
  DISPOSE(lastScrBuf.buf[k]);
  DEC(lastScrBuf.count);
  IF lastScrBuf.count = 0 THEN
    p := lastScrBuf;
    lastScrBuf := lastScrBuf.prev;
    DISPOSE(p)
  END
END Pop;

(* Pick restores the shadow screen contents and cursor position from the
   top of the save-buffer stack WITHOUT removing it (see Push/Pop, for
   "peek" rather than "pop" semantics). A no-op if the stack is empty.
   No parameters, no result. *)
PROCEDURE Pick*;
  VAR k: INTEGER;
BEGIN
  IF lastScrBuf = NIL THEN RETURN END;
  k := lastScrBuf.count - 1;
  SYSTEM.MOVE(lastScrBuf.buf[k], screen, lastScrBuf.size[k]);
  LocateAsm(lastScrBuf.x[k], lastScrBuf.y[k])
END Pick;

(* ScrollUp scrolls a w-by-h rectangle at (stx,sty) upward by lines rows
   (rows below the scrolled region shift up; the bottom `lines` rows are
   left unchanged -- caller typically clears them separately).
   Parameters: stx, sty -- top-left of the rectangle; w, h -- rectangle
   size in character cells; lines -- number of rows to scroll by.
   Result: none. *)
PROCEDURE ScrollUp*(stx, sty, w, h, lines: INTEGER);
  VAR i, scrw, slines, cur, wBytes: INTEGER;
      src, dst: SYSTEM.ADDRESS;
BEGIN
  i := 0; wBytes := w * 2; scrw := GetWidth();
  slines := (lines * scrw) * 2;
  cur := (stx + sty * scrw) * 2;
  scrw := scrw * 2;
  WHILE i < (h - lines) DO
    src := screen; src := src + LONGINT(slines + cur);
    dst := screen; dst := dst + LONGINT(cur);
    SYSTEM.MOVE(src, dst, WORD(wBytes));
    cur := cur + scrw;
    i := i + 1
  END
END ScrollUp;

(* ScrollDown scrolls a w-by-h rectangle at (stx,sty) downward by lines
   rows (the mirror image of ScrollUp: rows above the bottom shift down;
   the top `lines` rows are left unchanged). Parameters: stx, sty --
   top-left of the rectangle; w, h -- rectangle size in character cells;
   lines -- number of rows to scroll by. Result: none. *)
PROCEDURE ScrollDown*(stx, sty, w, h, lines: INTEGER);
  VAR i, scrw, slines, cur, wBytes: INTEGER;
      src, dst: SYSTEM.ADDRESS;
BEGIN
  i := h - lines; wBytes := w * 2; scrw := GetWidth();
  slines := (lines * scrw) * 2;
  cur := (stx + i * scrw) * 2;
  scrw := scrw * 2;
  WHILE i >= 0 DO
    src := screen; src := src + LONGINT(cur);
    dst := screen; dst := dst + LONGINT(slines + cur);
    SYSTEM.MOVE(src, dst, WORD(wBytes));
    cur := cur - scrw;
    i := i - 1
  END
END ScrollDown;

(* SavePalette reads the current 256-color VGA DAC palette into the
   module's own palette buffer (used by ResetPalette/GrayPalette/the
   Fade routines as the "target" palette to fade toward/from). A no-op
   if no VGA adapter was detected. No parameters, no result. *)
PROCEDURE SavePalette;
  VAR i: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  FOR i := 0 TO 255 DO
    SYSTEM.PORTOUT(PortDacIndex, BYTE(i));
    palette[i * 3]     := SYSTEM.PORTIN(PortDacData);
    palette[i * 3 + 1] := SYSTEM.PORTIN(PortDacData);
    palette[i * 3 + 2] := SYSTEM.PORTIN(PortDacData)
  END
END SavePalette;

(* SetColor writes one VGA DAC palette entry. Parameters: num -- palette
   index (0..255); r, g, b -- 6-bit-per-channel color values. Result:
   none. Not exported -- an internal helper for ResetPalette/GrayPalette/
   the Fade routines, matching the original Pascal's set_color (also
   UNIT-internal, not in its INTERFACE section). *)
PROCEDURE SetColor(num, r, g, b: BYTE);
BEGIN
  SYSTEM.PORTOUT(PortDacWrite, num);
  SYSTEM.PORTOUT(PortDacData, r);
  SYSTEM.PORTOUT(PortDacData, g);
  SYSTEM.PORTOUT(PortDacData, b)
END SetColor;

(* ResetPalette writes the module's saved palette (see SavePalette) back
   to the VGA DAC, restoring the screen's normal colors after a fade. A
   no-op if no VGA adapter was detected. No parameters, no result. *)
PROCEDURE ResetPalette*;
  VAR i: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  FOR i := 0 TO 255 DO
    SetColor(BYTE(i), palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2])
  END
END ResetPalette;

(* SpinnerStart installs the background spinner animation as an INT 1Ch
   (timer tick) handler and begins animating (see SCREEN.ASM's
   Spinner1c). A no-op if already running. No parameters, no result. *)
PROCEDURE SpinnerStart*;
BEGIN
  IF spinnerOn THEN RETURN END;
  Dos.SetIntVec(1CH, SYSTEM.ADR(Spinner1c));
  spinnerOn := TRUE
END SpinnerStart;

(* SpinnerStop uninstalls the spinner's INT 1Ch handler (restoring
   whatever handler was in place before SpinnerStart) and resets the
   palette. No parameters, no result. *)
PROCEDURE SpinnerStop*;
BEGIN
  Dos.SetIntVec(1CH, spinnerOldInt);
  ResetPalette;
  spinnerOn := FALSE
END SpinnerStop;

(* GrayPalette replaces every saved palette entry with its grayscale
   equivalent (average of R/G/B) and writes that to the VGA DAC. A no-op
   if no VGA adapter was detected. No parameters, no result. *)
PROCEDURE GrayPalette*;
  VAR i, n: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  FOR i := 0 TO 255 DO
    n := INTEGER(palette[i * 3]) + INTEGER(palette[i * 3 + 1]) + INTEGER(palette[i * 3 + 2]);
    n := n DIV 6;
    SetColor(BYTE(i), BYTE(n), BYTE(n), BYTE(n))
  END
END GrayPalette;

(* Fade0 immediately blanks the VGA palette to black (all 256 entries).
   A no-op if no VGA adapter was detected. No parameters, no result. *)
PROCEDURE Fade0*;
  VAR i: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  WaitRetraceAsm;
  FOR i := 0 TO 255 DO
    SetColor(BYTE(i), 0, 0, 0)
  END
END Fade0;

(* FadeIn blanks the palette (Fade0) then ramps every entry up toward
   its saved target value over 8 steps of FadeStep intensity units each,
   waiting FadeDelay milliseconds between steps -- a smooth fade-in
   effect. A no-op if no VGA adapter was detected. No parameters, no
   result. *)
PROCEDURE FadeIn*;
  VAR op1, op2, op3, p1, p2, p3: BYTE;
      i, j: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  Fade0;
  FOR j := 0 TO 7 DO
    WaitRetraceAsm;
    FOR i := 0 TO 255 DO
      SYSTEM.PORTOUT(PortDacIndex, BYTE(i));
      op1 := SYSTEM.PORTIN(PortDacData);
      op2 := SYSTEM.PORTIN(PortDacData);
      op3 := SYSTEM.PORTIN(PortDacData);
      p1 := palette[i * 3]; p2 := palette[i * 3 + 1]; p3 := palette[i * 3 + 2];
      IF INTEGER(op1) + FadeStep <= INTEGER(p1) THEN op1 := BYTE(INTEGER(op1) + FadeStep) ELSE op1 := p1 END;
      IF INTEGER(op2) + FadeStep <= INTEGER(p2) THEN op2 := BYTE(INTEGER(op2) + FadeStep) ELSE op2 := p2 END;
      IF INTEGER(op3) + FadeStep <= INTEGER(p3) THEN op3 := BYTE(INTEGER(op3) + FadeStep) ELSE op3 := p3 END;
      SetColor(BYTE(i), op1, op2, op3)
    END;
    DelayAsm(FadeDelay)
  END
END FadeIn;

(* FadeOut ramps every palette entry down toward black over 8 steps of
   FadeStep intensity units each, waiting FadeDelay milliseconds between
   steps, then restores the saved palette (ResetPalette) -- a smooth
   fade-out-and-restore effect. A no-op if no VGA adapter was detected.
   No parameters, no result. *)
PROCEDURE FadeOut*;
  VAR op1, op2, op3: BYTE;
      i, j: INTEGER;
BEGIN
  IF ~vga THEN RETURN END;
  FOR j := 0 TO 7 DO
    WaitRetraceAsm;
    FOR i := 0 TO 255 DO
      SYSTEM.PORTOUT(PortDacIndex, BYTE(i));
      op1 := SYSTEM.PORTIN(PortDacData);
      op2 := SYSTEM.PORTIN(PortDacData);
      op3 := SYSTEM.PORTIN(PortDacData);
      IF INTEGER(op1) >= FadeStep THEN op1 := BYTE(INTEGER(op1) - FadeStep) ELSE op1 := 0 END;
      IF INTEGER(op2) >= FadeStep THEN op2 := BYTE(INTEGER(op2) - FadeStep) ELSE op2 := 0 END;
      IF INTEGER(op3) >= FadeStep THEN op3 := BYTE(INTEGER(op3) - FadeStep) ELSE op3 := 0 END;
      SetColor(BYTE(i), op1, op2, op3)
    END;
    DelayAsm(FadeDelay)
  END;
  ResetPalette
END FadeOut;

(* WaitRetrace busy-waits for the start of the next VGA vertical
   retrace. No parameters, no result. *)
PROCEDURE WaitRetrace*;
BEGIN WaitRetraceAsm
END WaitRetrace;

BEGIN
  Dos.GetIntVec(1CH, spinnerOldInt);
  spinnerOn := FALSE;
  vga := Detect.IsVga();
  SavePalette;
  cursor := GetCursorAsm();
  IF (~vga) & Detect.IsMonochrome() THEN SetVSeg(SYSTEM.SegB000())
  ELSE SetVSeg(SYSTEM.SegB800())
  END;
  SetBlinkAsm(FALSE);
  screenSize := WORD((GetWidth() * GetHeight()) * 2);
  lineSize := WORD(GetWidth() * 2);
  SetLineSize(lineSize);
  SetScreenSize(screenSize);
  NEW(screen, screenSize);
  SetBuf(screen);
  KMouse.MouseShow
END Screen.
