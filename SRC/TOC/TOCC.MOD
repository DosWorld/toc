(*$M 26000, 64000, 650000*)
(*$D-,R-,A-*)
MODULE TOCC;
(*
  COMPILE half of the compile/link process split (TOCC.EXE).

  The compiler entry point proper.  It does NOT call SetupOvr:
  no $O+ overlays anywhere in the prototype, so there is no .OVR payload to
  map and, more importantly, no Overlay.OvrSetBuf2(65500, 24000) grabbing
  87 KB of heap at startup.  That buffer is charged to every run of the
  current all-in-one TOC.EXE -- including runs that only link -- and
  dropping it is a large part of what the split is meant to buy.

  Import.CacheOberonLib is still called first.  Its ENV-BUG.MD workaround
  exists because SetupOvr's file I/O corrupts a later Dos.GetEnv, which no
  longer applies here, but caching costs nothing and keeps this entry point
  behaviourally identical to TOC.MOD's for the comparison.

  $M: stack 26000 (the parser recurses deeply), min-heap cut 160000 ->
  64000.  The old all-in-one figure had to cover compiling AND linking;
  this half never allocates the linker's symbol table or its 65000-byte
  code/data buffers.
*)
IMPORT TocMain, Import;

PROCEDURE Run*;
BEGIN
  Import.CacheOberonLib;
  TocMain.Run
END Run;

END TOCC.
