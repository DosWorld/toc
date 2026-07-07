MODULE Passarr;
(* Stability-critical: by-VALUE vs by-VAR passing of FIXED arrays.
   By-value fixed array = callee gets a deep copy (caller unchanged).
   By-VAR fixed array   = callee mutates the caller's array.
   Covers: 1D, multi-dim, array-of-records, odd-length (alignment), and a
   value array forwarded through a second call.  Halt(N) on failure. *)

TYPE
  Vec   = ARRAY 4 OF INTEGER;
  Mat   = ARRAY 2, 3 OF INTEGER;
  Rec   = RECORD a, b: INTEGER END;
  RVec  = ARRAY 2 OF Rec;
  Odd3  = ARRAY 3 OF CHAR;          (* 3 bytes -> padded to 4 on the stack *)

VAR
  gv: Vec; gm: Mat; grv: RVec; god: Odd3;

(* ---- by-value: must NOT change caller ---- *)
PROCEDURE ValVec(p: Vec): INTEGER;
BEGIN p[0] := 99; p[3] := 99; RETURN p[1] + p[2] END ValVec;

PROCEDURE ValMat(p: Mat): INTEGER;
BEGIN p[0,0] := 99; RETURN p[1,2] END ValMat;

PROCEDURE ValRVec(p: RVec): INTEGER;
BEGIN p[0].a := 99; RETURN p[1].a + p[1].b END ValRVec;

PROCEDURE ValOdd3(p: Odd3): CHAR;
BEGIN p[0] := "X"; RETURN p[2] END ValOdd3;

(* ---- by-VAR: must change caller ---- *)
PROCEDURE VarVec(VAR p: Vec);
BEGIN p[0] := 100; p[3] := 400 END VarVec;

PROCEDURE VarMat(VAR p: Mat);
BEGIN p[0,0] := 11; p[1,2] := 66 END VarMat;

PROCEDURE VarRVec(VAR p: RVec);
BEGIN p[0].a := 7; p[1].b := 8 END VarRVec;

(* value array forwarded by value into a second proc (copy of a copy) *)
PROCEDURE Forward(p: Vec): INTEGER;
BEGIN RETURN ValVec(p) END Forward;

PROCEDURE Run*;
  VAR t: INTEGER; c: CHAR;
BEGIN
  (* by-value 1D: caller unchanged *)
  gv[0]:=1; gv[1]:=2; gv[2]:=3; gv[3]:=4;
  t := ValVec(gv);
  IF t # 5 THEN SYSTEM.Halt(1) END;                  (* p[1]+p[2] = 2+3 *)
  IF (gv[0] # 1) OR (gv[3] # 4) THEN SYSTEM.Halt(2) END;

  (* by-value multi-dim *)
  gm[0,0]:=10; gm[1,2]:=20;
  t := ValMat(gm);
  IF t # 20 THEN SYSTEM.Halt(3) END;
  IF gm[0,0] # 10 THEN SYSTEM.Halt(4) END;

  (* by-value array-of-records *)
  grv[0].a:=1; grv[1].a:=5; grv[1].b:=6;
  t := ValRVec(grv);
  IF t # 11 THEN SYSTEM.Halt(5) END;
  IF grv[0].a # 1 THEN SYSTEM.Halt(6) END;

  (* by-value odd-length (alignment) *)
  god[0]:="a"; god[1]:="b"; god[2]:="c";
  c := ValOdd3(god);
  IF c # "c" THEN SYSTEM.Halt(7) END;
  IF god[0] # "a" THEN SYSTEM.Halt(8) END;

  (* forwarded value array: still a copy at every hop *)
  gv[0]:=1; gv[1]:=2; gv[2]:=3; gv[3]:=4;
  t := Forward(gv);
  IF t # 5 THEN SYSTEM.Halt(9) END;
  IF gv[0] # 1 THEN SYSTEM.Halt(10) END;

  (* by-VAR 1D: caller mutated *)
  VarVec(gv);
  IF (gv[0] # 100) OR (gv[3] # 400) THEN SYSTEM.Halt(11) END;

  (* by-VAR multi-dim *)
  VarMat(gm);
  IF (gm[0,0] # 11) OR (gm[1,2] # 66) THEN SYSTEM.Halt(12) END;

  (* by-VAR array-of-records *)
  VarRVec(grv);
  IF (grv[0].a # 7) OR (grv[1].b # 8) THEN SYSTEM.Halt(13) END

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Passarr.
