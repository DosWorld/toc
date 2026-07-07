MODULE Asgnparm;
(* Runtime test: whole-array / whole-record ASSIGNMENT copies memory (deep, not
   alias), and parameter passing is by-value (callee gets a copy; caller
   unchanged) vs by-reference (VAR: callee mutates the caller's variable).

   Each check SYSTEM.Halt(N)s on failure; falling through = errorlevel 0 = all
   passed.  N is unique per check so a failure pinpoints the broken semantic. *)

TYPE
  Vec = ARRAY 4 OF INTEGER;
  Inner = RECORD a, b: INTEGER END;
  Outer = RECORD
    x: INTEGER;
    in: Inner;          (* nested record — assignment must copy it too *)
    v: ARRAY 3 OF INTEGER
  END;

VAR
  ga, gb: Vec;
  gr, gs: Outer;

(* ---- value vs VAR for scalars ---- *)
PROCEDURE ByValScalar(n: INTEGER);
BEGIN n := 999 END ByValScalar;          (* must NOT affect caller *)

PROCEDURE ByVarScalar(VAR n: INTEGER);
BEGIN n := 999 END ByVarScalar;          (* must affect caller *)

(* ---- value vs VAR for arrays (fixed) ---- *)
PROCEDURE ByValArr(p: Vec);
BEGIN p[0] := 999 END ByValArr;          (* copy: caller unchanged *)

PROCEDURE ByVarArr(VAR p: Vec);
BEGIN p[0] := 999 END ByVarArr;          (* caller mutated *)

(* ---- value vs VAR for records (with nested record + array field) ---- *)
PROCEDURE ByValRec(r: Outer);
BEGIN r.x := 999; r.in.a := 999; r.v[0] := 999 END ByValRec;

PROCEDURE ByVarRec(VAR r: Outer);
BEGIN r.x := 999; r.in.a := 999; r.v[0] := 999 END ByVarRec;

(* ---- open-array VAR param: write back through the reference ---- *)
PROCEDURE BumpOpen(VAR p: ARRAY OF INTEGER);
  VAR i: INTEGER;
BEGIN i := 0; WHILE i < LEN(p) DO p[i] := p[i] + 1; INC(i) END END BumpOpen;

PROCEDURE Run*;
  VAR i: INTEGER; n: INTEGER;
BEGIN
  (* 1. whole-array assignment copies element-by-element *)
  ga[0] := 10; ga[1] := 20; ga[2] := 30; ga[3] := 40;
  gb := ga;                              (* must deep-copy *)
  i := 0; WHILE i < 4 DO
    IF gb[i] # ga[i] THEN SYSTEM.Halt(1) END; INC(i)
  END;
  (* 2. it is a COPY, not an alias: mutating source must not change dest *)
  ga[0] := 777;
  IF gb[0] # 10 THEN SYSTEM.Halt(2) END;

  (* 3. whole-record assignment copies all fields incl. nested + array *)
  gr.x := 1; gr.in.a := 2; gr.in.b := 3; gr.v[0] := 4; gr.v[1] := 5; gr.v[2] := 6;
  gs := gr;
  IF gs.x # 1 THEN SYSTEM.Halt(3) END;
  IF (gs.in.a # 2) OR (gs.in.b # 3) THEN SYSTEM.Halt(4) END;
  IF (gs.v[0] # 4) OR (gs.v[1] # 5) OR (gs.v[2] # 6) THEN SYSTEM.Halt(5) END;
  (* 4. record copy is not an alias *)
  gr.x := 888; gr.in.a := 888; gr.v[0] := 888;
  IF gs.x # 1 THEN SYSTEM.Halt(6) END;
  IF gs.in.a # 2 THEN SYSTEM.Halt(7) END;
  IF gs.v[0] # 4 THEN SYSTEM.Halt(8) END;

  (* 5. by-value scalar: caller unchanged *)
  n := 5; ByValScalar(n);
  IF n # 5 THEN SYSTEM.Halt(9) END;
  (* 6. by-VAR scalar: caller mutated *)
  ByVarScalar(n);
  IF n # 999 THEN SYSTEM.Halt(10) END;

  (* 7. by-value array: caller unchanged (callee got a copy) *)
  ga[0] := 1; ga[1] := 2; ga[2] := 3; ga[3] := 4;
  ByValArr(ga);
  IF ga[0] # 1 THEN SYSTEM.Halt(11) END;
  (* 8. by-VAR array: caller mutated *)
  ByVarArr(ga);
  IF ga[0] # 999 THEN SYSTEM.Halt(12) END;

  (* 9. by-value record: caller unchanged (deep copy incl nested/array) *)
  gr.x := 1; gr.in.a := 2; gr.v[0] := 3;
  ByValRec(gr);
  IF gr.x # 1 THEN SYSTEM.Halt(13) END;
  IF gr.in.a # 2 THEN SYSTEM.Halt(14) END;
  IF gr.v[0] # 3 THEN SYSTEM.Halt(15) END;
  (* 10. by-VAR record: caller mutated *)
  ByVarRec(gr);
  IF gr.x # 999 THEN SYSTEM.Halt(16) END;
  IF gr.in.a # 999 THEN SYSTEM.Halt(17) END;
  IF gr.v[0] # 999 THEN SYSTEM.Halt(18) END;

  (* 11. open-array VAR param writes back through the reference *)
  ga[0] := 1; ga[1] := 2; ga[2] := 3; ga[3] := 4;
  BumpOpen(ga);
  IF (ga[0] # 2) OR (ga[1] # 3) OR (ga[2] # 4) OR (ga[3] # 5) THEN SYSTEM.Halt(19) END

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Asgnparm.
