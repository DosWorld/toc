(*$D-*)
MODULE Crt;

IMPORT Out;

CONST

(* CRT modes *)

BW40*    = 0;            (* 40x25 B/W on Color Adapter *)
CO40*    = 1;            (* 40x25 Color on Color Adapter *)
BW80*    = 2;            (* 80x25 B/W on Color Adapter *)
CO80*    = 3;            (* 80x25 Color on Color Adapter *)
Mono*    = 7;            (* 80x25 on Monochrome Adapter *)
Font8x8* = 256;          (* Add-in for ROM font *)

(* Mode constants for TP 3.0 compatibility *)

C40*     = CO40;
C80*     = CO80;

(* Foreground and background color constants *)

Black*     = 0;
Blue*      = 1;
Green*     = 2;
Cyan*      = 3;
Red*       = 4;
Magenta*   = 5;
Brown*     = 6;
LightGray* = 7;

(* Foreground color constants *)

DarkGray*      = 0;
LightBlue*     = 1;
LightGreen*    = 2;
LightCyan*     = 3;
LightRed*      = 4;
LightMagenta*  = 5;
Yellow*        = 6;
White*         = 7;

(* Add-in for blinking *)

Blink* = 128;

VAR

(* Interface variables *)

CheckBreak*: BOOLEAN;    (* Enable Ctrl-Break *)
CheckEOF*: BOOLEAN;      (* Enable Ctrl-Z *)
DirectVideo*: BOOLEAN;   (* Enable direct video addressing *)
CheckSnow*: BOOLEAN;     (* Enable snow filtering *)
LastMode*: BYTE;         (* Current text mode *)
TextAttr*: BYTE;         (* Current text attribute *)
WindMin*: INTEGER;       (* Window upper left coordinates *)
WindMax*: INTEGER;       (* Window lower right coordinates *)

(* Interface PROCEDUREs *)

(*
PROCEDURE KeyPressed*: BOOLEAN;
PROCEDURE ReadKey*: Char;
PROCEDURE TextMode*(Mode: Integer);
PROCEDURE Window*(X1,Y1,X2,Y2: BYTE);
PROCEDURE GotoXY*(X,Y: BYTE);
PROCEDURE WhereX*: BYTE;
PROCEDURE WhereY*: BYTE;
PROCEDURE ClrScr*;
PROCEDURE ClrEol*;
PROCEDURE InsLine*;
PROCEDURE DelLine*;
PROCEDURE TextColor*(Color: BYTE);
PROCEDURE TextBackground*(Color: BYTE);
PROCEDURE LowVideo*;
PROCEDURE HighVideo*;
PROCEDURE NormVideo*;
PROCEDURE Delay*(MS: INTEGER);
PROCEDURE Sound*(Hz: INTEGER);
PROCEDURE NoSound*;
*)

(* KeyPressed: check whether a key is waiting in the keyboard buffer, via
   INT 21h AH=0Bh (get input status), without removing it.
   Parameters: none.
   Result: TRUE if a key is available to be read. *)
PROCEDURE KeyPressed*: BOOLEAN;
VAR r : SYSTEM.Registers;
BEGIN
    r.AX := 0B00H;
    SYSTEM.Intr(21H, r);
    RETURN SYSTEM.AND(SYSTEM.LSR(r.AX, 8), 0FFH) = 0FFH;
END KeyPressed;

(* ReadKey: read one character from the keyboard, via INT 21h AH=08h
   (read character without echo), blocking until a key is pressed.
   Parameters: none.
   Result: the character read (extended/function keys return a NUL-lead
   scan code sequence via successive calls, per standard DOS behavior). *)
PROCEDURE ReadKey*: CHAR;
VAR r : SYSTEM.Registers;
BEGIN
    r.AX := 0800H;
    SYSTEM.Intr(21H, r);
    RETURN CHR(SYSTEM.AND(r.AX, 0FFH))
END ReadKey;

(* TextMode: switch the video adapter into a BIOS text/graphics mode
   (INT 10h AH=00h).
   Parameters: Mode — a mode number, e.g. one of the BW40/CO40/BW80/CO80/
   Mono constants (optionally combined with Font8x8).
   Result: none. *)
PROCEDURE TextMode*(Mode: BYTE);
BEGIN
    SYSTEM.VIDEOMODE(Mode)
END TextMode;

(* GotoXY: move the text cursor to a specific screen location using an
   ANSI escape sequence (ESC [ row ; col H).
   Parameters: X — 1-based column; Y — 1-based row.
   Result: none. *)
PROCEDURE GotoXY*(X, Y: INTEGER);
BEGIN
    Out.Char(1BX);
    Out.Char('[');
    Out.Int(Y, 0);
    Out.Char(';');
    Out.Int(X, 0);
    Out.Char('H')
END GotoXY;

PROCEDURE EscStr(s: ARRAY OF CHAR);
VAR buf : ARRAY 32 OF CHAR; i : WORD;
BEGIN
  buf[0] := 1BX;
  i := 0;
  WHILE s[i] # 0X DO
    buf[i+1] := s[i];
    INC(i)
  END;
  buf[i + 1] := 0X;
  Out.String(buf);
END EscStr;

(* ClrScr: clear the whole screen and home the cursor, via ANSI escape
   sequences (ESC [2J then ESC [1;1H).
   Parameters: none.
   Result: none. *)
PROCEDURE ClrScr*;
BEGIN
  EscStr("[2J");
  EscStr("[1;1H");
END ClrScr;

(* ClrEol: clear from the cursor to the end of the current line, via the
   ANSI escape sequence ESC [K.
   Parameters: none.
   Result: none. *)
PROCEDURE ClrEol*;
BEGIN
  EscStr("[K");
END ClrEol;

(* TextColor: set the foreground text color using an ANSI SGR escape
   sequence (ESC [3<n>m).
   Parameters: fg — color index 0..7 (see the color constants above; only
   the low 3 bits are used).
   Result: none. *)
PROCEDURE TextColor*(fg : INTEGER);
VAR buf : ARRAY 12 OF CHAR;
BEGIN
  buf[0] := "[";
  buf[1] := "3";
  buf[2] := CHR(30H + (fg MOD 8));
  buf[3] := "m";
  buf[4] := 0X;
  EscStr(buf)
END TextColor;

(* TextBackground: set the background text color using an ANSI SGR escape
   sequence (ESC [4<n>m).
   Parameters: bg — color index 0..7 (see the color constants above; only
   the low 3 bits are used).
   Result: none. *)
PROCEDURE TextBackground*(bg : INTEGER);
VAR buf : ARRAY 12 OF CHAR;
BEGIN
  buf[0] := "[";
  buf[1] := "4";
  buf[2] := CHR(30H + (bg MOD 8));
  buf[3] := "m";
  buf[4] := 0X;
  EscStr(buf)
END TextBackground;

(* Delay: pause execution for approximately the given duration, via
   repeated INT 15h AH=86h (BIOS wait) calls in 65535-microsecond chunks.
   Parameters: MS — delay duration in milliseconds; values <= 0 return
   immediately.
   Result: none. *)
PROCEDURE Delay*(MS: INTEGER);
  VAR r: SYSTEM.Registers; us: LONGINT;
BEGIN
  IF MS <= 0 THEN RETURN END;
  us := LONGINT(MS) * 1000;
  WHILE us > 0 DO
    r.AX := 8600H;
    IF us > 65535 THEN
      r.CX := INTEGER(SYSTEM.LSR(us, 16));
      r.DX := INTEGER(SYSTEM.AND(us, 0FFFFH));
      us := 0
    ELSE
      r.CX := 0;
      r.DX := INTEGER(us);
      us := 0
    END;
    SYSTEM.Intr(15H, r)
  END
END Delay;

(* Sound: start the PC speaker beeping at a given frequency, by
   programming PIT channel 2 (ports 43h/42h) and gating the speaker on
   via port 61h.
   Parameters: Hz — tone frequency in Hertz; values <= 0 return
   immediately without changing the speaker state.
   Result: none. *)
PROCEDURE Sound*(Hz: INTEGER);
  VAR divisor: INTEGER;
BEGIN
  IF Hz <= 0 THEN RETURN END;
  divisor := 1193180 DIV Hz;
  SYSTEM.PORTOUT(43H, 0B6H);
  SYSTEM.PORTOUT(42H, SYSTEM.AND(divisor, 0FFH));
  SYSTEM.PORTOUT(42H, SYSTEM.LSR(divisor, 8));
  SYSTEM.PORTOUT(61H, SYSTEM.IOR(SYSTEM.PORTIN(61H), 3))
END Sound;

(* NoSound: stop the PC speaker by gating it off via port 61h.
   Parameters: none.
   Result: none. *)
PROCEDURE NoSound*;
BEGIN
  SYSTEM.PORTOUT(61H, SYSTEM.AND(SYSTEM.PORTIN(61H), 0FCH))
END NoSound;

END Crt.
