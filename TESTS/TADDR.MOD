MODULE TADDR;
(* Regression test for the typeless-VAR-param codegen bug (P0, 2026-06-13).

   A typeless `VAR x` parameter is a by-reference parameter whose slot holds a
   4-byte far address; its *value* IS that address.  Assigning it to a pointer
   (`dest := x`) must load the address, NOT dereference it.  The pre-fix compiler
   wrongly emitted an extra far-dereference (LES BX,[x]; MOV AX,ES:[BX]; ...),
   so `dest` pointed at garbage and writes through it corrupted memory.

   This is exactly the `Files.BlockRead` idiom `dest := x` that broke self-host. *)

IMPORT Test;

TYPE
  ByteArr = ARRAY 8 OF BYTE;
  ByteArrPtr = POINTER TO ARRAY OF BYTE;

(* x is a typeless VAR param (the actual is an ARRAY OF BYTE).  Assign it to a
   far pointer and write through that pointer — must land in the caller's array. *)
PROCEDURE WriteThrough(VAR x; idx, val: INTEGER);
  VAR dest: ByteArrPtr;
BEGIN
  dest := x;                       (* <-- the bug site: load address, no deref *)
  dest^[idx] := BYTE(val)
END WriteThrough;

(* Read back through the same idiom. *)
PROCEDURE ReadThrough(VAR x; idx: INTEGER): INTEGER;
  VAR src: ByteArrPtr;
BEGIN
  src := x;
  RETURN INTEGER(src^[idx])
END ReadThrough;

PROCEDURE TAssignTypelessToPtr*;
  VAR a: ByteArr; i: INTEGER;
BEGIN
  i := 0; WHILE i < 8 DO a[i] := BYTE(0); INC(i) END;

  WriteThrough(a, 0, 0AAH);
  WriteThrough(a, 3, 055H);
  WriteThrough(a, 7, 0FFH);

  (* If `dest := x` dereferenced instead of taking the address, these writes
     went to garbage and a[] is still zero (or the program already crashed). *)
  Test.AssertInt(0AAH, INTEGER(a[0]), "typeless/write a[0]");
  Test.AssertInt(000H, INTEGER(a[1]), "typeless/write a[1] untouched");
  Test.AssertInt(055H, INTEGER(a[3]), "typeless/write a[3]");
  Test.AssertInt(0FFH, INTEGER(a[7]), "typeless/write a[7]");

  Test.AssertInt(0AAH, ReadThrough(a, 0), "typeless/read a[0]");
  Test.AssertInt(055H, ReadThrough(a, 3), "typeless/read a[3]")
END TAssignTypelessToPtr;

(* Cross-check: the address loaded must equal SYSTEM.ADR of the actual. *)
PROCEDURE AddrOf(VAR x): SYSTEM.ADDRESS;
  VAR p: ByteArrPtr;
BEGIN
  p := x; RETURN SYSTEM.ADR(p^[0])
END AddrOf;

PROCEDURE TAddrMatches*;
  VAR a: ByteArr;
BEGIN
  Test.AssertTrue(AddrOf(a) = SYSTEM.ADR(a[0]), "typeless/addr == ADR(actual)")
END TAddrMatches;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TAssignTypelessToPtr, "TADDR/assignTypelessToPtr");
  Test.AddTest(TAddrMatches,         "TADDR/addrMatches");
  Test.RunTests
END RunAllTests;

END TADDR.
