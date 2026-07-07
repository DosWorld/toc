MODULE ProcNil;
(* Regression: far proc value compared with NIL must compare all 4 bytes
   (seg:ofs).  Bug: TFProc missing from PExpr's far-compare branch, so only
   the offset word was compared — a proc at code offset 0 (like Cb below,
   the FIRST proc in the module) looked equal to NIL and callback guards
   like Tar.ListTar's `onMember # NIL` never fired.  Exit code = failures. *)

TYPE MP = PROCEDURE(x: INTEGER);

VAR g: MP; fails: INTEGER; hit: INTEGER;

PROCEDURE Cb(x: INTEGER); FAR;
BEGIN hit := hit + x
END Cb;

PROCEDURE Call(p: MP);
BEGIN
  IF p # NIL THEN p(1) ELSE fails := fails + 1 END
END Call;

PROCEDURE CallNil(p: MP);
BEGIN
  IF p = NIL THEN hit := hit + 1 ELSE fails := fails + 1 END
END CallNil;

PROCEDURE Run*;
  VAR v: MP;
BEGIN
  fails := 0; hit := 0;
  Call(Cb);                                    (* proc constant as actual *)
  v := Cb; Call(v);                            (* local proc var *)
  g := Cb; Call(g);                            (* global proc var *)
  IF v = NIL THEN fails := fails + 1 END;      (* direct compare, non-NIL *)
  v := NIL; CallNil(v);                        (* NIL still equals NIL *)
  IF hit # 4 THEN fails := fails + 1 END;
  SYSTEM.Halt(fails)
END Run;

END ProcNil.
