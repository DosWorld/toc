MODULE Tvarinc;
(* Runtime test: INC/DEC on a typeless VAR (SYSTEM.ADDRESS) formal parameter
   must advance the parameter's own far-pointer slot, not the byte it points
   at.  Regression for STRVAL.MD: CgStoreItem's MLocal/MGlobal branches had
   no isRef&isAddr special case (unlike CgLoadItem's), so `INC(s)` inside a
   procedure taking `VAR s` (typeless) stored the incremented pointer VALUE
   back through the pointer itself instead of into s's own slot -- s never
   advanced, and the target byte was clobbered with pointer garbage on every
   iteration, hanging any loop like Strings.Val's digit scan.  Reproduced
   only when the actual is a plain global variable (MGlobal); a local actual
   (MLocal, still reachable via a different vstore.mode) is unaffected. *)
VAR buf: ARRAY 8 OF CHAR;

(* CountUp: typeless VAR param p, walks p^ forward with INC(p) (implicit
   step 1, no explicit ",step") until a NUL, returning the count.  Mirrors
   Strings.Val's WHILE SYSTEM.ISDIGIT(s^) DO ... INC(s) END loop shape. *)
PROCEDURE CountUp(VAR p): INTEGER;
  VAR n: INTEGER;
BEGIN
  n := 0;
  WHILE p^ # 0X DO
    INC(n); INC(p)
  END;
  RETURN n
END CountUp;

PROCEDURE Run*;
  VAR n: INTEGER;
BEGIN
  buf[0] := "1"; buf[1] := "2"; buf[2] := "3"; buf[3] := 0X;
  n := CountUp(buf);
  IF n # 3 THEN SYSTEM.Halt(1) END

  (* fall through: errorlevel 0 means the pointer advanced correctly *)
END Run;

END Tvarinc.
