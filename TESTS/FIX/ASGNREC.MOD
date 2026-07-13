MODULE Asgnrec;
(* Regression for the 2026-07-13 record-assignment codegen bug (see
   DOCS/IMPLRULE.MD "Record assignment: two missing far-source (MReg)
   cases"): `dest := arr[i]` (or `n^.arr[i]` through a pointer) silently
   copied only the record's first field when dest was a plain local/global
   OR a VAR record parameter -- every other field kept whatever garbage
   was already there. Each check SYSTEM.Halt(N)s on failure; fall-through
   = errorlevel 0. *)

TYPE
  Rec4 = RECORD a, b, c, d: INTEGER END;
  Node = POINTER TO NodeDesc;
  NodeDesc = RECORD arr: ARRAY 4 OF Rec4 END;

VAR
  garr: ARRAY 4 OF Rec4;
  n: Node;

PROCEDURE AssignFromGlobalArr(VAR dst: Rec4; idx: INTEGER);
(* shape 1: dst is plain local/global, source is a plain global array elem *)
  VAR local: Rec4;
BEGIN
  local := garr[idx];
  dst := local
END AssignFromGlobalArr;

PROCEDURE AssignFromPtrArrDirect(VAR dst: Rec4; idx: INTEGER);
(* shape 2: dst is a VAR RECORD parameter, source is an array-of-record
   element read through a POINTER (n.arr[idx]) -- the exact pattern that
   surfaced while implementing SRC/TLINK's ImpFind *)
BEGIN
  dst := n.arr[idx]
END AssignFromPtrArrDirect;

PROCEDURE Run*;
  VAR local: Rec4; e: Rec4;
BEGIN
  garr[0].a := 11; garr[0].b := 22; garr[0].c := 33; garr[0].d := 44;
  garr[1].a := 111; garr[1].b := 222; garr[1].c := 333; garr[1].d := 444;

  (* shape 1a: plain local dest := plain global array element *)
  local := garr[0];
  IF (local.a # 11) OR (local.b # 22) OR (local.c # 33) OR (local.d # 44) THEN
    SYSTEM.Halt(1)
  END;
  local := garr[1];
  IF (local.a # 111) OR (local.b # 222) OR (local.c # 333) OR (local.d # 444) THEN
    SYSTEM.Halt(2)
  END;

  (* shape 1b: VAR RECORD dest := plain global array element (via helper) *)
  e.a := 0; e.b := 0; e.c := 0; e.d := 0;
  AssignFromGlobalArr(e, 1);
  IF (e.a # 111) OR (e.b # 222) OR (e.c # 333) OR (e.d # 444) THEN SYSTEM.Halt(3) END;

  (* shape 2: VAR RECORD dest := array-of-record element through a POINTER *)
  NEW(n);
  IF n = NIL THEN SYSTEM.Halt(4) END;
  n.arr[0].a := 55; n.arr[0].b := 66; n.arr[0].c := 77; n.arr[0].d := 88;
  n.arr[1].a := 155; n.arr[1].b := 166; n.arr[1].c := 177; n.arr[1].d := 188;

  e.a := 0; e.b := 0; e.c := 0; e.d := 0;
  AssignFromPtrArrDirect(e, 0);
  IF (e.a # 55) OR (e.b # 66) OR (e.c # 77) OR (e.d # 88) THEN SYSTEM.Halt(5) END;

  e.a := 0; e.b := 0; e.c := 0; e.d := 0;
  AssignFromPtrArrDirect(e, 1);
  IF (e.a # 155) OR (e.b # 166) OR (e.c # 177) OR (e.d # 188) THEN SYSTEM.Halt(6) END;

  (* neighbour intact: element 0 unaffected by reading element 1 *)
  IF (n.arr[0].a # 55) OR (n.arr[0].b # 66) OR (n.arr[0].c # 77) OR (n.arr[0].d # 88) THEN
    SYSTEM.Halt(7)
  END

  (* fall through: errorlevel 0 = all passed *)
END Run;
END Asgnrec.
