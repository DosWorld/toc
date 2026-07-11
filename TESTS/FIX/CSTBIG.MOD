MODULE Cstbig;
(* Exports a CONST outside signed INTEGER range (-32768..32767), for
   cross-module .def round-trip testing (finding 2.2: DefRead used to
   retype every imported CONST as INTEGER regardless of its actual
   magnitude, silently truncating values like this one). *)
CONST
  Big* = 100000;
END Cstbig.
