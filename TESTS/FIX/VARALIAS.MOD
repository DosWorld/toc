MODULE VarAlias;
(* Regression: a VAR parameter typed via a NAMED fixed-size array alias must
   forward the caller's storage correctly when re-passed to an open-array
   formal (e.g. Out.String).  Before the fix, the callee passed the ADDRESS of
   its own 4-byte pointer slot instead of dereferencing it, prepending garbage
   bytes.  SYSTEM.Halt(N) on mismatch; fall through = errorlevel 0. *)
CONST MaxIdent = 33;
TYPE Str33 = ARRAY MaxIdent OF CHAR;

PROCEDURE Len(VAR s: ARRAY OF CHAR): INTEGER;
  VAR i: INTEGER;
BEGIN i := 0; WHILE s[i] # 0X DO INC(i) END; RETURN i END Len;

(* VAR param typed via the named alias; forwards s to the open-array Len *)
PROCEDURE ViaAlias(VAR s: Str33): INTEGER;
BEGIN RETURN Len(s) END ViaAlias;

PROCEDURE Run*;
  VAR buf: Str33;
BEGIN
  buf[0] := "H"; buf[1] := "I"; buf[2] := 0X;
  (* correct forwarding => Len sees "HI" (2).  The old bug prepended garbage,
     so Len counted extra leading bytes. *)
  IF ViaAlias(buf) # 2 THEN SYSTEM.Halt(1) END
END Run;

END VarAlias.
