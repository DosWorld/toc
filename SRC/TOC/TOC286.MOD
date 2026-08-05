(*$M 64500, 160000, 650000*)
MODULE TOC286;
(* Entry point for the DPMI16/NE (/CP) build of the compiler.  Identical
   compiler to TOC.EXE (module TOC) -- this just gives it a distinct
   module/binary name so `toc /CP /ENTRY=Run TOC286.MOD` links an NE
   (DPMI16 protected-mode) TOC286.EXE alongside the MZ (/CD) TOC.EXE.
   Stack size mirrors TOC.MOD's own $M directive: the linker takes the
   stack size from the ENTRY module, which is TOC286 here, not TOC. *)
IMPORT TOC;

PROCEDURE Run*;
BEGIN
  TOC.Run
END Run;

END TOC286.
