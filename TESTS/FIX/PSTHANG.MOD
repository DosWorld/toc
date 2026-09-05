MODULE Psthang;
(* OVR-BUG.MD "Bug 5" minimal repro: with PSTMT.MOD marked $O+ (its own
   $O+ attempt, reverted -- see OVR-BUG.MD), compiling THIS single
   statement hangs the compiler at well past 100 MILLION xt instructions
   (confirmed via xt trace: a genuine loop, not just slow -- the
   compiled-code trace shows the SAME 227/291-instruction segment-
   alternation pattern the original SRC/TASM/SCAN.MOD repro showed,
   isolated here to a single IF-with-function-call-condition statement).

   Narrowed via a systematic minimization pass (see OVR-BUG.MD "Bug 5"
   for the full investigation):
     - A bare statement-level call `Foo(a);` (NOT inside a condition)
       compiles FINE even with PSTMT.MOD $O+ -- confirms the trigger is
       specifically the CONDITION-FUSED parsing path (PStmt.ParseIf ->
       PExpr.ParseCondExpr/ParseCondFactor -> PExpr.ParseFactorHook ->
       PExpr2.ParseFactor -- the "2.1 condition-context fusion"
       machinery, DOCS/CODEGEN-SIZE.MD/PEXPR.MOD's own header comments),
       not plain designator/call parsing.
     - WHILE Foo(a) DO ... END reproduces the identical hang -- confirms
       it is the condition-fusion path in general, not IF specifically.
     - A condition with NO function call (a bare BOOLEAN variable) does
       NOT reproduce this same hang (it fails differently and much
       faster -- a separate, not-yet-investigated crash: "Unexpected
       value: 6" from xt -- out of scope for this fixture, which targets
       ONLY the hang).

   This file is NOT part of the normal make test suite -- it can only
   be exercised by hand-building a TOC.EXE with PSTMT.MOD temporarily
   marked $O+ (the shipped TOC.EXE always has PSTMT.MOD resident, so
   this file compiles perfectly normally, instantly, against every
   TOC.EXE this project actually ships). Kept here as a ready-to-use
   regression fixture for whoever picks up OVR-BUG.MD's "Bug 5" --
   compile it with a PSTMT.MOD-$O+ TOC.EXE and confirm it no longer
   hangs once the real fix lands.

   UPDATE (2026-08-25): this exact minimal repro is FIXED by the
   ObstructionEnd/skip-forward change in SRC/LIB/OVERLAY.MOD's
   TryLoadIntoBlock (see OVR-BUG.MD's "Bug 5" STATUS UPDATE) -- compiles
   and links cleanly (exit=0) against a PSTMT.MOD-$O+ TOC.EXE carrying
   that fix.

   UPDATE (2026-08-25/26): Bug 5 is now FULLY CLOSED. ObstructionEnd was
   superseded by FindFreeSpot (a full block-wide free-gap scan), which
   also fixes the larger-scale bump-allocator fragmentation case found
   compiling the FULL SRC/TASM/TASM.MOD (~2500 lines) -- that build now
   completes cleanly too (exit=0, zero heap leaks). PSTMT.MOD ships
   (*$D-,O+*) in BIN/TOC.EXE. See OVR-BUG.MD's "Bug 5" section, "FINAL
   STATUS" note, for the full story. This fixture stays as a permanent
   regression check -- re-run it (and ideally a real SRC/TASM/TASM.MOD
   build) after any future change to SRC/LIB/OVERLAY.MOD. *)
IMPORT Out;

VAR a, b: INTEGER;

PROCEDURE Foo(x: INTEGER): BOOLEAN;
BEGIN
  RETURN x > 0
END Foo;

PROCEDURE Run*;
BEGIN
  IF Foo(a) THEN a := b END
END Run;

END Psthang.
