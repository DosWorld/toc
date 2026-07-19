MODULE Condchn;
(* Regression for SIZE-REPORT.MD "bug 8": ParseCondAndChain's chainFalseList
   and ParseOrTail's chainTrueList are CondBpNode locals used as CondBpPush's
   initial `head` (the ~wantTrue `&`-chain branch and the condWantTrue OR-chain
   branch, respectively) without first being set to NIL.  This runtime does
   NOT zero-init locals, so CondBpPush's `n^.next := head` captured garbage;
   the later CondBpPatchFree walk dereferenced that garbage as a CondBpNode
   and wrote a bogus patch into an unrelated, already-compiled procedure's
   code (observed clobbering a preceding procedure's entry prologue).  Needs
   an armed OR-chain (or a `&`-chain reached via `~`/OR's inverted polarity)
   followed by a call to a procedure defined earlier in the same module.
   Each check exits via SYSTEM.Halt(N) on failure (errorlevel N). *)

PROCEDURE HexDigit(c: CHAR): INTEGER;
BEGIN
  IF (c >= "0") & (c <= "9") THEN RETURN ORD(c) - ORD("0") END;
  IF (c >= "A") & (c <= "F") THEN RETURN ORD(c) - ORD("A") + 10 END;
  RETURN -1
END HexDigit;

(* condWantTrue=TRUE OR-chain (ParseOrTail's chainTrueList path), followed in
   the same procedure by a call to an earlier-defined procedure — this is
   the exact shape that clobbered HexDigit's prologue before the fix. *)
PROCEDURE ParseHex(s: ARRAY OF CHAR): INTEGER;
  VAR i, n, h1, h2: INTEGER; done: BOOLEAN;
BEGIN
  i := 0; n := 0; done := FALSE;
  WHILE ~done DO
    IF (i >= LEN(s)) OR (s[i] = 0X) THEN done := TRUE
    ELSE
      h1 := HexDigit(s[i]); INC(i);
      IF h1 < 0 THEN RETURN -1 END;
      IF (i >= LEN(s)) OR (s[i] = 0X) THEN RETURN -1 END;
      h2 := HexDigit(s[i]); INC(i);
      IF h2 < 0 THEN RETURN -1 END;
      n := n + 1
    END
  END;
  RETURN n
END ParseHex;

(* wantTrue=FALSE `&`-chain reached via `~` (ParseCondAndChain's
   chainFalseList path), same "call an earlier proc afterward" shape. *)
PROCEDURE NotAndThenCall(a, b: INTEGER): INTEGER;
BEGIN
  IF ~((a > 0) & (b > 0)) THEN RETURN HexDigit("F") END;
  RETURN -2
END NotAndThenCall;

PROCEDURE Run*;
BEGIN
  IF HexDigit("9") # 9 THEN SYSTEM.Halt(1) END;
  IF ParseHex("0EE8") # 2 THEN SYSTEM.Halt(2) END;
  IF ParseHex("") # 0 THEN SYSTEM.Halt(3) END;
  IF ParseHex("G0") # -1 THEN SYSTEM.Halt(4) END;
  IF NotAndThenCall(-1, 5) # 15 THEN SYSTEM.Halt(5) END;
  IF NotAndThenCall(1, 1) # -2 THEN SYSTEM.Halt(6) END
  (* fall through: errorlevel 0 means all tests passed *)
END Run;

END Condchn.
