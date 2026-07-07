MODULE Passrec;
(* Stability-critical: by-VALUE vs by-VAR passing of RECORDS.
   By-value = callee gets a deep copy (caller unchanged).
   By-VAR   = callee mutates the caller's record.
   Covers: flat, nested, record-with-array-field, odd-sized (2-byte align),
   array-of-records element, and MIXED value/ref params in one signature.
   Each check SYSTEM.Halt(N)s on failure; fall-through = errorlevel 0. *)

TYPE
  Flat  = RECORD a, b: INTEGER END;
  Nest  = RECORD x: INTEGER; in: Flat END;
  WithA = RECORD k: INTEGER; v: ARRAY 3 OF INTEGER END;
  Odd   = RECORD c: CHAR; n: INTEGER END;     (* size 3 -> padded to 4 on stack *)
  RArr  = ARRAY 2 OF Flat;

VAR
  gf: Flat; gn: Nest; gw: WithA; go: Odd; gra: RArr;

(* ---- by-value: must NOT change caller ---- *)
PROCEDURE ValFlat(r: Flat): INTEGER;
BEGIN r.a := 111; r.b := 222; RETURN r.a + r.b END ValFlat;

PROCEDURE ValNest(r: Nest): INTEGER;
BEGIN r.x := 1; r.in.a := 2; r.in.b := 3; RETURN r.x + r.in.a + r.in.b END ValNest;

PROCEDURE ValWithA(r: WithA): INTEGER;
BEGIN r.k := 9; r.v[0] := 9; r.v[1] := 9; r.v[2] := 9; RETURN r.v[2] END ValWithA;

PROCEDURE ValOdd(r: Odd): INTEGER;
BEGIN r.c := "Z"; r.n := 555; RETURN r.n END ValOdd;

(* ---- by-VAR: must change caller ---- *)
PROCEDURE VarFlat(VAR r: Flat);
BEGIN r.a := 111; r.b := 222 END VarFlat;

PROCEDURE VarNest(VAR r: Nest);
BEGIN r.x := 1; r.in.a := 2; r.in.b := 3 END VarNest;

PROCEDURE VarWithA(VAR r: WithA);
BEGIN r.k := 9; r.v[0] := 8; r.v[2] := 7 END VarWithA;

PROCEDURE VarOdd(VAR r: Odd);
BEGIN r.c := "Z"; r.n := 555 END VarOdd;

(* ---- MIXED value + VAR records in one signature ---- *)
PROCEDURE Mixed(src: Flat; VAR dst: Flat; k: INTEGER; VAR out: INTEGER);
BEGIN dst.a := src.a + k; dst.b := src.b + k; out := src.a END Mixed;

PROCEDURE Run*;
  VAR t: INTEGER; e: Flat; d: Flat;
BEGIN
  (* by-value flat: copy used inside, caller unchanged *)
  gf.a := 10; gf.b := 20;
  t := ValFlat(gf);
  IF t # 333 THEN SYSTEM.Halt(1) END;         (* callee saw its own 111+222 *)
  IF (gf.a # 10) OR (gf.b # 20) THEN SYSTEM.Halt(2) END;

  (* by-value nested *)
  gn.x := 100; gn.in.a := 5; gn.in.b := 6;
  t := ValNest(gn);
  IF t # 6 THEN SYSTEM.Halt(3) END;
  IF (gn.x # 100) OR (gn.in.a # 5) OR (gn.in.b # 6) THEN SYSTEM.Halt(4) END;

  (* by-value record-with-array-field *)
  gw.k := 1; gw.v[0] := 2; gw.v[1] := 3; gw.v[2] := 4;
  t := ValWithA(gw);
  IF t # 9 THEN SYSTEM.Halt(5) END;
  IF (gw.k # 1) OR (gw.v[0] # 2) OR (gw.v[2] # 4) THEN SYSTEM.Halt(6) END;

  (* by-value odd-sized (2-byte alignment must keep stack balanced) *)
  go.c := "A"; go.n := 42;
  t := ValOdd(go);
  IF t # 555 THEN SYSTEM.Halt(7) END;
  IF (go.c # "A") OR (go.n # 42) THEN SYSTEM.Halt(8) END;

  (* by-VAR flat: caller mutated *)
  gf.a := 0; gf.b := 0; VarFlat(gf);
  IF (gf.a # 111) OR (gf.b # 222) THEN SYSTEM.Halt(9) END;

  (* by-VAR nested *)
  VarNest(gn);
  IF (gn.x # 1) OR (gn.in.a # 2) OR (gn.in.b # 3) THEN SYSTEM.Halt(10) END;

  (* by-VAR record-with-array-field *)
  VarWithA(gw);
  IF (gw.k # 9) OR (gw.v[0] # 8) OR (gw.v[2] # 7) THEN SYSTEM.Halt(11) END;

  (* by-VAR odd-sized *)
  VarOdd(go);
  IF (go.c # "Z") OR (go.n # 555) THEN SYSTEM.Halt(12) END;

  (* array-of-records element passed by value, then by VAR *)
  gra[0].a := 1; gra[0].b := 2; gra[1].a := 3; gra[1].b := 4;
  t := ValFlat(gra[1]);
  IF t # 333 THEN SYSTEM.Halt(13) END;
  IF (gra[1].a # 3) OR (gra[1].b # 4) THEN SYSTEM.Halt(14) END;   (* element unchanged *)
  VarFlat(gra[0]);
  IF (gra[0].a # 111) OR (gra[0].b # 222) THEN SYSTEM.Halt(15) END;
  IF (gra[1].a # 3) OR (gra[1].b # 4) THEN SYSTEM.Halt(16) END;   (* neighbour intact *)

  (* MIXED value + VAR in one call *)
  e.a := 50; e.b := 60; d.a := 0; d.b := 0;
  Mixed(e, d, 5, t);
  IF (d.a # 55) OR (d.b # 65) THEN SYSTEM.Halt(17) END;
  IF t # 50 THEN SYSTEM.Halt(18) END;
  IF (e.a # 50) OR (e.b # 60) THEN SYSTEM.Halt(19) END           (* value src unchanged *)

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Passrec.
