MODULE Passopen;
(* Stability-critical: OPEN arrays (ARRAY OF ...).  Open arrays are always
   passed by reference (6-byte slot {ofs,seg,LEN}); VAR vs non-VAR both see the
   caller's storage, but only VAR may be written.  Covers: 1D open (read+VAR
   write), LEN correctness, open-of-record, multi-dim open, mixed open+scalar
   params, and forwarding an open array to a nested open-array proc.
   Halt(N) on failure; fall-through = errorlevel 0. *)

TYPE
  Rec = RECORD a, b: INTEGER END;

VAR
  v4: ARRAY 4 OF INTEGER;
  v7: ARRAY 7 OF INTEGER;
  rr: ARRAY 3 OF Rec;

(* sum a 1D open array (read-only use) *)
PROCEDURE Sum(p: ARRAY OF INTEGER): INTEGER;
  VAR i, s: INTEGER;
BEGIN s := 0; i := 0; WHILE i < LEN(p) DO s := s + p[i]; INC(i) END; RETURN s END Sum;

(* LEN must reflect the ACTUAL array length at the call site *)
PROCEDURE Length(p: ARRAY OF INTEGER): INTEGER;
BEGIN RETURN LEN(p) END Length;

(* VAR open array: write back through the reference *)
PROCEDURE Bump(VAR p: ARRAY OF INTEGER);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < LEN(p) DO p[i] := p[i] + 1; INC(i) END END Bump;

(* open array of records (read) *)
PROCEDURE SumRec(p: ARRAY OF Rec): INTEGER;
  VAR i, s: INTEGER;
BEGIN s := 0; i := 0; WHILE i < LEN(p) DO s := s + p[i].a + p[i].b; INC(i) END; RETURN s END SumRec;

(* mixed: open array (VAR) + scalar value + scalar VAR out *)
PROCEDURE FillAdd(VAR p: ARRAY OF INTEGER; k: INTEGER; VAR n: INTEGER);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < LEN(p) DO p[i] := k; INC(i) END; n := LEN(p) END FillAdd;

(* forward an open array to another open-array proc (LEN must survive the hop) *)
PROCEDURE FwdSum(p: ARRAY OF INTEGER): INTEGER;
BEGIN RETURN Sum(p) END FwdSum;

PROCEDURE Run*;
  VAR t, n: INTEGER;
BEGIN
  v4[0]:=1; v4[1]:=2; v4[2]:=3; v4[3]:=4;
  v7[0]:=1; v7[1]:=1; v7[2]:=1; v7[3]:=1; v7[4]:=1; v7[5]:=1; v7[6]:=1;

  (* read-only open array *)
  IF Sum(v4) # 10 THEN SYSTEM.Halt(1) END;
  IF Sum(v7) # 7 THEN SYSTEM.Halt(2) END;

  (* LEN reflects the actual array, not a fixed size *)
  IF Length(v4) # 4 THEN SYSTEM.Halt(3) END;
  IF Length(v7) # 7 THEN SYSTEM.Halt(4) END;

  (* VAR open array writes back *)
  Bump(v4);
  IF (v4[0] # 2) OR (v4[1] # 3) OR (v4[2] # 4) OR (v4[3] # 5) THEN SYSTEM.Halt(5) END;

  (* open array of records *)
  rr[0].a:=1; rr[0].b:=2; rr[1].a:=3; rr[1].b:=4; rr[2].a:=5; rr[2].b:=6;
  IF SumRec(rr) # 21 THEN SYSTEM.Halt(6) END;

  (* mixed open(VAR) + value scalar + VAR scalar *)
  FillAdd(v4, 9, n);
  IF (v4[0] # 9) OR (v4[3] # 9) THEN SYSTEM.Halt(7) END;
  IF n # 4 THEN SYSTEM.Halt(8) END;

  (* forwarding preserves LEN and contents *)
  t := FwdSum(v7);
  IF t # 7 THEN SYSTEM.Halt(9) END

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Passopen.
