MODULE TADRP;
(* Regression / feature test for SYSTEM.ADDRESS as a "smart pointer to CHAR"
   (2026-06-29).  SYSTEM.ADDRESS behaves like POINTER TO CHAR with byte
   addressing, plus offset-only pointer arithmetic:

     p^            reads the CHAR at the address
     p^[i]         reads the CHAR at address + i
     p^[i] := c    writes through the address
     INC(p)/DEC(p) / INC(p,n)/DEC(p,n)   advance/retreat the OFFSET word only
     p := p + e / p := p - e             offset-only arithmetic in expressions
     LONGINT(p)    cast ADDRESS -> LONGINT (4-byte, segment preserved)
     SYSTEM.ADDRESS(L)  cast LONGINT -> ADDRESS (4-byte, segment preserved)

   MATH RULE: all arithmetic touches the offset word only; on overflow the
   segment word is left untouched (no carry into the segment). *)

IMPORT Test;

VAR buf: ARRAY 600 OF CHAR;   (* module-level so the data segment is stable *)

PROCEDURE InitBuf;
  VAR i: INTEGER;
BEGIN
  i := 0; WHILE i < 600 DO buf[i] := CHR(i MOD 256); INC(i) END
END InitBuf;

(* ---- deref and indexed deref ---- *)
PROCEDURE TDeref*;
  VAR p: SYSTEM.ADDRESS; c: CHAR;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  c := p^;
  Test.AssertInt(0, ORD(c), "p^ reads buf[0]");
  c := p^[10];
  Test.AssertInt(10, ORD(c), "p^[10] reads buf[10]");
  c := p^[255];
  Test.AssertInt(255, ORD(c), "p^[255] reads buf[255]")
END TDeref;

(* ---- indexed deref with a runtime (non-const) index ---- *)
PROCEDURE TDerefVarIdx*;
  VAR p: SYSTEM.ADDRESS; c: CHAR; i: INTEGER;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  i := 100;
  c := p^[i];
  Test.AssertInt(100, ORD(c), "p^[i] runtime index");
  i := 257;                       (* wraps the byte value: 257 MOD 256 = 1 *)
  c := p^[i];
  Test.AssertInt(1, ORD(c), "p^[i] i=257 -> buf[257]=CHR(1)")
END TDerefVarIdx;

(* ---- write through p^[i] ---- *)
PROCEDURE TWriteThrough*;
  VAR p: SYSTEM.ADDRESS;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  p^[50] := "Z";
  Test.AssertInt(ORD("Z"), ORD(buf[50]), "p^[50] := 'Z' lands in buf[50]");
  Test.AssertInt(49, ORD(buf[49]), "neighbour buf[49] untouched");
  Test.AssertInt(51, ORD(buf[51]), "neighbour buf[51] untouched")
END TWriteThrough;

(* ---- INC / DEC by 1 and by N ---- *)
PROCEDURE TIncDec*;
  VAR p: SYSTEM.ADDRESS; c: CHAR;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  INC(p);          c := p^; Test.AssertInt(1,   ORD(c), "INC(p) -> buf[1]");
  INC(p, 200);     c := p^; Test.AssertInt(201, ORD(c), "INC(p,200) -> buf[201]");
  DEC(p);          c := p^; Test.AssertInt(200, ORD(c), "DEC(p) -> buf[200]");
  DEC(p, 150);     c := p^; Test.AssertInt(50,  ORD(c), "DEC(p,150) -> buf[50]")
END TIncDec;

(* ---- + / - in expressions ---- *)
PROCEDURE TArith*;
  VAR p, q: SYSTEM.ADDRESS; c: CHAR; n: INTEGER;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  q := p + 60;     c := q^; Test.AssertInt(60, ORD(c), "p + 60");
  q := q - 5;      c := q^; Test.AssertInt(55, ORD(c), "q - 5");
  n := 33;
  q := p + n;      c := q^; Test.AssertInt(33, ORD(c), "p + n (runtime)");
  q := q - n;      c := q^; Test.AssertInt(0,  ORD(c), "q - n back to base")
END TArith;

(* ---- offset arithmetic must NOT carry into the segment ----
   ADR(buf[0]) + (something that wraps the 16-bit offset) keeps the SAME
   segment; reading the wrapped address is undefined, but the SEGMENT half of
   the cast-to-LONGINT value must be identical before and after a wrapping add.
   We check the segment word (high 16 bits of LONGINT(p)) is unchanged. *)
PROCEDURE SegOf(p: SYSTEM.ADDRESS): INTEGER;
BEGIN
  RETURN INTEGER(SYSTEM.LSR(LONGINT(p), 16))
END SegOf;

PROCEDURE TSegUntouched*;
  VAR p, q: SYSTEM.ADDRESS; seg0: INTEGER;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[0]);
  seg0 := SegOf(p);
  q := p + 100;
  Test.AssertInt(seg0, SegOf(q), "p+100: segment unchanged");
  q := p - 100;
  Test.AssertInt(seg0, SegOf(q), "p-100: segment unchanged");
  INC(p, 40000);
  Test.AssertInt(seg0, SegOf(p), "INC(p,40000): no carry into segment");
  INC(p, 40000);   (* now 80000 > 65535: offset wraps, segment STILL unchanged *)
  Test.AssertInt(seg0, SegOf(p), "INC past 64K: segment still unchanged")
END TSegUntouched;

(* ---- LONGINT <-> ADDRESS round-trip cast ---- *)
PROCEDURE TCast*;
  VAR p, q: SYSTEM.ADDRESS; L: LONGINT; c: CHAR;
BEGIN
  InitBuf;
  p := SYSTEM.ADR(buf[5]);
  L := LONGINT(p);
  q := SYSTEM.ADDRESS(L);
  Test.AssertLong(LONGINT(p), LONGINT(q), "LONGINT/ADDRESS round-trip equal");
  c := q^;
  Test.AssertInt(5, ORD(c), "cast round-trip dereferences buf[5]")
END TCast;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TDeref,        "TADRP/deref");
  Test.AddTest(TDerefVarIdx,  "TADRP/derefVarIdx");
  Test.AddTest(TWriteThrough, "TADRP/writeThrough");
  Test.AddTest(TIncDec,       "TADRP/incDec");
  Test.AddTest(TArith,        "TADRP/arith");
  Test.AddTest(TSegUntouched, "TADRP/segUntouched");
  Test.AddTest(TCast,         "TADRP/cast");
  Test.RunTests
END RunAllTests;

END TADRP.
