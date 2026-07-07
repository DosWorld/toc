MODULE Noimport;
(* Imports a module that does not exist anywhere on the search path.
   Exercises Import.LoadExplicitImport's error-return path (formerly a
   SYSTEM.Halt): the compile must fail cleanly (errorlevel 1, no .om, no
   leftover temp files) and funnel the error to TOC.Run's single Halt. *)
IMPORT NoSuchMod;
END Noimport.
