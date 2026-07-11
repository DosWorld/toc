(*$D-*)
MODULE Time;

CONST
  SecsPerDay* = 86400;
  DaysTo1980 = 3652; (* days from 1970-01-01 to 1980-01-01 (incl. 2 leap years: 1972, 1976) *)

TYPE

UnixTime* = LONGINT;
DosTime*  = LONGINT;

DateTime* = RECORD
  Year*:  WORD;
  Month*: WORD;
  Day*:   WORD;
  Hour*:  WORD;
  Min*:   WORD;
  Sec*:   WORD;
END;

(* PackTime: encode a DateTime record into the packed 32-bit DOS
   date/time format used by file directory entries (FAT timestamp).
   Parameters: t — date/time fields to encode; p — output, the packed
   DosTime value.
   Result: none (p is filled in place). *)
PROCEDURE PackTime*(VAR t: DateTime; VAR p: DosTime);
VAR d, tm : WORD;
BEGIN
    d := SYSTEM.IOR(SYSTEM.LSL(t.Year - 1980, 9), SYSTEM.IOR(SYSTEM.LSL(t.Month, 5), t.Day));
    tm := SYSTEM.IOR(SYSTEM.LSL(t.Hour, 11), SYSTEM.IOR(SYSTEM.LSL(t.Min, 5), t.Sec DIV 2));
    p := SYSTEM.IOR(SYSTEM.LSL(LONGINT(d), 16), LONGINT(tm))
END PackTime;

(* UnpackTime: decode a packed 32-bit DOS date/time value (FAT
   timestamp) into individual date/time fields.
   Parameters: p — packed DosTime value to decode; t — output, the
   decoded date/time fields.
   Result: none (t is filled in place). *)
PROCEDURE UnpackTime*(p: DosTime; VAR t: DateTime);
VAR d, tm : WORD;
BEGIN
    d := SYSTEM.LSR(p, 16);
    tm := SYSTEM.AND(p, 0FFFFH);
    t.Day := SYSTEM.AND(d, 1FH);
    t.Month := SYSTEM.AND(SYSTEM.LSR(d, 5), 0FH);
    t.Year := 1980 + SYSTEM.AND(SYSTEM.LSR(d, 10), 3FH);
    t.Hour := SYSTEM.AND(SYSTEM.LSR(tm, 11), 1FH);
    t.Min := SYSTEM.AND(SYSTEM.LSR(tm, 5), 1FH);
    t.Sec := SYSTEM.AND(tm, 1FH) * 2;
END UnpackTime;

(* IsLeap: determine whether a given year is a leap year in the
   Gregorian calendar.
   Parameters: y — full year to test.
   Result: TRUE if y is a leap year. *)
PROCEDURE IsLeap*(y: WORD): BOOLEAN;
BEGIN
  RETURN ((y MOD 4 = 0) & (y MOD 100 # 0)) OR (y MOD 400 = 0)
END IsLeap;

(* DaysInMonth: report how many days a given month has, accounting for
   leap years.
   Parameters: y — full year (used to resolve February's length);
   m — month number, 1..12.
   Result: the number of days in that month (28..31). *)
PROCEDURE DaysInMonth*(y, m: WORD): WORD;
BEGIN
  CASE m OF
    1, 3, 5, 7, 8, 10, 12: RETURN 31
  | 4, 6, 9, 11:           RETURN 30
  | 2:                     IF IsLeap(y) THEN RETURN 29 ELSE RETURN 28 END
  END
END DaysInMonth;

(* DosToUnixTime: convert a packed DOS date/time value into a Unix
   timestamp (seconds since 1970-01-01 00:00:00).
   Parameters: d — packed DosTime value to convert.
   Result: the equivalent UnixTime (seconds since the Unix epoch). *)
PROCEDURE DosToUnixTime*(d: DosTime): UnixTime;
VAR t: DateTime; y, m: WORD; days: LONGINT; secs: LONGINT;
BEGIN
  UnpackTime(d, t);
  days := DaysTo1980;
  y := 1980;
  WHILE y < t.Year DO
    IF IsLeap(y) THEN days := days + 366 ELSE days := days + 365 END;
    INC(y)
  END;
  m := 1;
  WHILE m < t.Month DO
    days := days + LONGINT(DaysInMonth(t.Year, m));
    INC(m)
  END;
  days := days + LONGINT(t.Day - 1);
  secs := LONGINT(t.Hour) * 3600 + LONGINT(t.Min) * 60 + LONGINT(t.Sec);
  RETURN days * SecsPerDay + secs
END DosToUnixTime;

(* UnixToDosTime: convert a Unix timestamp (seconds since 1970-01-01
   00:00:00) into a packed DOS date/time value.
   Parameters: u — UnixTime value to convert.
   Result: the equivalent packed DosTime value. *)
PROCEDURE UnixToDosTime*(u: UnixTime): DosTime;
VAR t: DateTime; days: LONGINT; secs: LONGINT; y: WORD; dim: WORD; p: DosTime;
BEGIN
  days := u DIV SecsPerDay;
  secs := u MOD SecsPerDay;
  t.Hour := WORD(secs DIV 3600);
  t.Min := WORD((secs DIV 60) MOD 60);
  t.Sec := WORD(secs MOD 60);

  days := days - DaysTo1980;
  y := 1980;
  IF IsLeap(y) THEN dim := 366 ELSE dim := 365 END;
  WHILE days >= LONGINT(dim) DO
    days := days - LONGINT(dim);
    INC(y);
    IF IsLeap(y) THEN dim := 366 ELSE dim := 365 END
  END;
  t.Year := y;

  t.Month := 1;
  dim := DaysInMonth(t.Year, t.Month);
  WHILE days >= LONGINT(dim) DO
    days := days - LONGINT(dim);
    INC(t.Month);
    dim := DaysInMonth(t.Year, t.Month)
  END;
  t.Day := WORD(days) + 1;

  PackTime(t, p);
  RETURN p
END UnixToDosTime;

(* Returns day of week for date y-m-d: 0=Sunday, 1=Monday, ..., 6=Saturday.
   Sakamoto's algorithm.
   Parameters: y — full year; m — month, 1..12; d — day, 1..31.
   Result: day of week, 0=Sunday..6=Saturday. *)
PROCEDURE DayOfWeek*(y, m, d: WORD): BYTE;
VAR yy, t: WORD;
BEGIN
  yy := y;
  IF m < 3 THEN yy := yy - 1 END;
  CASE m OF
    1:  t := 0
  | 2:  t := 3
  | 3:  t := 2
  | 4:  t := 5
  | 5:  t := 0
  | 6:  t := 3
  | 7:  t := 5
  | 8:  t := 1
  | 9:  t := 4
  | 10: t := 6
  | 11: t := 2
  | 12: t := 4
  END;
  RETURN BYTE((yy + yy DIV 4 - yy DIV 100 + yy DIV 400 + t + d) MOD 7)
END DayOfWeek;

(* NowDateTime: retrieve the current system date and time, via
   INT 21h AH=2Ah (get date) and AH=2Ch (get time).
   Parameters: t — output, filled with the current date/time fields.
   Result: none (t is filled in place). *)
PROCEDURE NowDateTime*(VAR t: DateTime);
VAR r: SYSTEM.Registers;
BEGIN
  r.AX := 2A00H;
  SYSTEM.Intr(21H, r);
  t.Year := r.CX;
  t.Month := SYSTEM.LSR(r.DX, 8);
  t.Day := r.DX MOD 256;

  r.AX := 2C00H;
  SYSTEM.Intr(21H, r);
  t.Hour := SYSTEM.LSR(r.CX, 8);
  t.Min := r.CX MOD 256;
  t.Sec := SYSTEM.LSR(r.DX, 8)
END NowDateTime;

(* Returns the current system date/time as a packed DosTime
   (INT 21h AH=2Ah/2Ch, same as Dos.GetDate/GetTime).
   Parameters: none.
   Result: the current date/time as a packed DosTime value. *)
PROCEDURE Now*(): DosTime;
VAR t: DateTime; p: DosTime;
BEGIN
  NowDateTime(t);
  PackTime(t, p);
  RETURN p
END Now;

(* Returns d2 - d1 in seconds (negative if d2 is earlier than d1).
   Parameters: d1 — earlier reference DosTime; d2 — later DosTime.
   Result: the difference d2 - d1, in seconds. *)
PROCEDURE SecondsBetween*(d1, d2: DosTime): LONGINT;
BEGIN
  RETURN DosToUnixTime(d2) - DosToUnixTime(d1)
END SecondsBetween;

END Time.
