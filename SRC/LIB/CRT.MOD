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

PROCEDURE KeyPressed*: BOOLEAN;
VAR r : SYSTEM.Registers;
BEGIN
    r.AX := 0B00H;
    SYSTEM.Intr(21H, r);
    RETURN SYSTEM.AND(SYSTEM.LSR(r.AX, 8), 0FFH) = 0FFH;
END KeyPressed;

PROCEDURE ReadKey*: CHAR;
VAR r : SYSTEM.Registers;
BEGIN
    r.AX := 0800H;
    SYSTEM.Intr(21H, r);
    RETURN CHR(SYSTEM.AND(r.AX, 0FFH))
END ReadKey;

PROCEDURE TextMode*(Mode: BYTE);
BEGIN
    SYSTEM.VIDEOMODE(Mode)
END TextMode;

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

PROCEDURE ClrScr*;
BEGIN
  EscStr("[2J");
  EscStr("[1;1H");
END ClrScr;

PROCEDURE ClrEol*;
BEGIN
  EscStr("[K");
END ClrEol;

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

PROCEDURE NoSound*;
BEGIN
  SYSTEM.PORTOUT(61H, SYSTEM.AND(SYSTEM.PORTIN(61H), 0FCH))
END NoSound;

END Crt.
