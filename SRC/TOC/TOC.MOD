(*$M 26000, 160000, 650000*)
(*$D-,R-,A-*)
MODULE TOC;

IMPORT
 Dos, TocMain, Overlay, Import;

(* SetupOvr: enable the overlay runtime for DEF.MOD/LINKNE.MOD ($O+).
   self is the running program's own path (Dos.ParamStr(0,...)) -- the
   .OVR payload is appended to TOC.EXE's own tail by the Makefile
   (DOCS/OVR.MD §12, appended-to-EXE format), matching every other
   overlay-using .EXE in this project.

   Re-enabled 2026-08-16: the third bug found chasing this (LINK.MOD's
   OnSegRelocOverlay routing a DATA-patch-site SEGRELOC through the
   CODE-only ovrXFixups table instead of the ordinary MZ AddReloc path)
   is fixed -- see DOCS/OVR.MD §16.  Overlay.WarmModuleCaches right after
   Init moves RegisterModule's own one-time per-module allocation cost
   ahead of TocMain.Run's own leak-guard baseline, so it doesn't read as
   a false-positive leak (see WarmModuleCaches's own comment).

   OvrSetBuf MUST run before WarmModuleCaches: OvrSetBuf refuses to
   (re)size the heap once ovrLoadList # NIL ("resizing an in-use buffer"
   guard), and WarmModuleCaches populates ovrLoadList via RegisterModule.
   Calling them in the wrong order left ovrHeapOrgParas/ovrHeapEndParas
   at 0 -- OvrSetBuf's call silently no-op'd via that guard -- so the
   first real LoadModule call always failed ("needParas > buffer size"
   with heapOrg=0 heapEnd=0), surfacing as SYSTEM.Halt(209). *)
PROCEDURE SetupOvr;
VAR self : ARRAY 256 OF CHAR;
BEGIN
  Dos.ParamStr(0, self);
  Overlay.Init(self);
  Overlay.OvrSetBuf(65500);
  Overlay.WarmModuleCaches
END SetupOvr;

PROCEDURE Run*;
BEGIN
  (* Read OBERON_LIB before any overlay bring-up runs -- SetupOvr's own
     Overlay.Init does a Files.Reset/Files.Close cycle to open TOC.EXE's
     appended .OVR payload, which reliably corrupts the next
     Dos.GetEnv("OBERON_LIB", ...) read (root cause not yet found past
     SYSTEM.FCLOSE -- see ENV-BUG.MD).  Caching it first, before that file
     I/O ever runs, works around it; Import.FindImportFile/
     LoadExplicitImport read the cached copy instead of calling
     Dos.GetEnv again themselves. *)
  Import.CacheOberonLib;
  SetupOvr;
  TocMain.Run
END Run;

END TOC.
