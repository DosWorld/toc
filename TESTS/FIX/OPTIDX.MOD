MODULE OPTIDX;
(* Fixture for array-index power-of-two scaling (opt.md E).
   Indexing an ARRAY OF LONGINT (element size 4) must scale the index with
   SHL AX,2 (C1 E0 02), NOT IMUL CX (F7 E9). *)
VAR a*: ARRAY 8 OF LONGINT;
PROCEDURE Get*(i: INTEGER): LONGINT;
BEGIN RETURN a[i] END Get;
END OPTIDX.
