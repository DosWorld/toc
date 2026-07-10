MODULE Calendar;
(*
  Prints a text calendar for a given month/year.

  Usage: CALENDAR [year month] [/SUNDAY | /MONDAY]
    year month   defaults to the current DOS date if omitted
    /SUNDAY      week starts on Sunday
    /MONDAY      week starts on Monday (default)
*)
IMPORT Dos, Out, Strings, Time;

PROCEDURE ParseInt(s: ARRAY OF CHAR; VAR ok: BOOLEAN): INTEGER;
  VAR i, v: INTEGER;
BEGIN
  ok := (s[0] >= "0") & (s[0] <= "9");
  i := 0; v := 0;
  WHILE (s[i] >= "0") & (s[i] <= "9") DO
    v := v * 10 + (ORD(s[i]) - ORD("0")); INC(i)
  END;
  IF s[i] # 0X THEN ok := FALSE END;
  RETURN v
END ParseInt;

(* Matches a "/NAME" or "-NAME" switch (case-insensitive) against name. *)
PROCEDURE EqualSwitch(VAR arg: ARRAY OF CHAR; name: ARRAY OF CHAR): BOOLEAN;
  VAR tail: ARRAY 32 OF CHAR;
BEGIN
  Strings.Extract(arg, 1, Strings.Length(arg) - 1, tail);
  RETURN Strings.EqualICase(tail, name)
END EqualSwitch;

PROCEDURE PrintMonthName(m: WORD);
BEGIN
  CASE m OF
    1:  Out.String("Jan")
  | 2:  Out.String("Feb")
  | 3:  Out.String("Mar")
  | 4:  Out.String("Apr")
  | 5:  Out.String("May")
  | 6:  Out.String("Jun")
  | 7:  Out.String("Jul")
  | 8:  Out.String("Aug")
  | 9:  Out.String("Sep")
  | 10: Out.String("Oct")
  | 11: Out.String("Nov")
  | 12: Out.String("Dec")
  END
END PrintMonthName;

(* Returns the calendar column (0..6) the 1st of the month falls under.
   Time.DayOfWeek returns 0=Sunday..6=Saturday; when the week starts on
   Monday, rotate so column 0 = Monday. *)
PROCEDURE FirstDayColumn(y, m: WORD; startSunday: BOOLEAN): INTEGER;
  VAR dow: INTEGER;
BEGIN
  dow := Time.DayOfWeek(y, m, 1);
  IF ~startSunday THEN dow := (dow + 6) MOD 7 END;
  RETURN dow
END FirstDayColumn;

PROCEDURE PrintHeader(startSunday: BOOLEAN);
BEGIN
  IF startSunday THEN
    Out.String("Su Mo Tu We Th Fr Sa")
  ELSE
    Out.String("Mo Tu We Th Fr Sa Su")
  END;
  Out.Ln
END PrintHeader;

PROCEDURE PrintMonth(y, m: WORD; startSunday: BOOLEAN);
  VAR i, col, day, dim: INTEGER;
BEGIN
  Out.String("     ");PrintMonthName(m); Out.Int(y, 6); Out.Ln;
  PrintHeader(startSunday);

  col := FirstDayColumn(y, m, startSunday);
  i := col;
  WHILE i > 0 DO Out.String("   "); DEC(i) END;

  dim := Time.DaysInMonth(y, m);
  day := 1;
  WHILE day <= dim DO
    Out.Int(day, 2); Out.Char(" ");
    INC(col); INC(day);
    IF col = 7 THEN Out.Ln; col := 0 END
  END;
  IF col # 0 THEN Out.Ln END
END PrintMonth;

PROCEDURE Run*;
  VAR argc, i: INTEGER;
      arg: ARRAY 32 OF CHAR;
      year, month: INTEGER;
      startSunday, ok, haveYearMonth: BOOLEAN;
      now: Time.DateTime;
BEGIN
  Out.Open;
  argc := Dos.ParamCount();
  startSunday := FALSE;
  haveYearMonth := FALSE;
  year := 0; month := 0;

  i := 1;
  WHILE i <= argc DO
    Dos.ParamStr(i, arg);
    IF (arg[0] = "/") OR (arg[0] = "-") THEN
      IF EqualSwitch(arg, "SUNDAY") THEN startSunday := TRUE
      ELSIF EqualSwitch(arg, "MONDAY") THEN startSunday := FALSE
      ELSE
        Out.String("Unknown switch: "); Out.String(arg); Out.Ln;
        SYSTEM.Halt(1)
      END
    ELSIF ~haveYearMonth THEN
      year := ParseInt(arg, ok);
      IF ~ok THEN Out.String("Bad year: "); Out.String(arg); Out.Ln; SYSTEM.Halt(1) END;
      INC(i);
      IF i > argc THEN Out.String("Missing month argument"); Out.Ln; SYSTEM.Halt(1) END;
      Dos.ParamStr(i, arg);
      month := ParseInt(arg, ok);
      IF ~ok OR (month < 1) OR (month > 12) THEN
        Out.String("Bad month: "); Out.String(arg); Out.Ln; SYSTEM.Halt(1)
      END;
      haveYearMonth := TRUE
    ELSE
      Out.String("Unexpected argument: "); Out.String(arg); Out.Ln;
      SYSTEM.Halt(1)
    END;
    INC(i)
  END;

  IF ~haveYearMonth THEN
    Time.NowDateTime(now);
    year := now.Year; month := now.Month
  END;

  PrintMonth(WORD(year), WORD(month), startSunday);
  SYSTEM.Halt(0)
END Run;

END Calendar.
