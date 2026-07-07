MODULE Retrec;
(* A procedure may not return a record — must be a fatal compile error. *)
TYPE Rec = RECORD x: INTEGER END;
PROCEDURE F(): Rec;
  VAR r: Rec;
BEGIN RETURN r END F;
END Retrec.
