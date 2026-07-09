MODULE Asgwiden;
(* Runtime test: assigning a WORD/BYTE/CHAR value to a LONGINT var must
   zero-extend, not sign-extend (CWD).  A WORD >= 32768 has bit 15 set;
   sign-extending it would set the LONGINT's high word to FFFFH instead of 0.
   Each check exits via SYSTEM.Halt(N) on failure (errorlevel N). *)

VAR
  w: WORD;
  b: BYTE;
  c: CHAR;
  l: LONGINT;

PROCEDURE Run*;
BEGIN
  (* WORD >= 32768: plain assignment l := w must zero-extend, not sign-extend.
     40000 as INTEGER bit pattern is negative; CWD would set l's high word
     to FFFFH, yielding l = -25536 instead of 40000. *)
  w := WORD(40000);
  l := w;
  IF l # LONGINT(40000) THEN SYSTEM.Halt(1) END;

  (* WORD at the very top of range. *)
  w := WORD(65535);
  l := w;
  IF l # LONGINT(65535) THEN SYSTEM.Halt(2) END;

  (* BYTE >= 128: must zero-extend. *)
  b := BYTE(200);
  l := b;
  IF l # LONGINT(200) THEN SYSTEM.Halt(3) END;

  (* CHAR with high bit set: must zero-extend. *)
  c := CHR(200);
  l := c;
  IF l # LONGINT(200) THEN SYSTEM.Halt(4) END

  (* fall through: errorlevel 0 means all tests passed *)
END Run;
END Asgwiden.
