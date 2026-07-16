MODULE Ptruse;
(* Regression for PTR.MD: VAR parameter of a bare POINTER TO ARRAY type,
   used across a module boundary, used to fail with a spurious "type
   mismatch in actual parameter" because Def.WriteType had no way to name
   the array's anonymous base type and wrote "POINTER VOID" into the
   .def, losing the array shape.  errorlevel 0 means Fill compiled,
   linked, and NEW+index-store through the VAR param ran correctly. *)
IMPORT Ptrlib;
VAR x: Ptrlib.ItemArr;
PROCEDURE Run*;
BEGIN
  Ptrlib.Fill(x);
  IF x[0].a # 42 THEN SYSTEM.Halt(1) END
END Run;
END Ptruse.
