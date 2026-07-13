# RESOLVED (2026-07-11): "implicit SYSTEM import lost" + self-host hang + gen1→gen2 failures

**Status: CLOSED — root-caused and fixed.**  Original report 2026-07-09
("SYSTEM/Out undefined after compiling an intermediate module"), extended
2026-07-10 (HASBODY hang, gen1→gen2 `Files.om` dep-scan
failure).  All three symptom families were traced on 2026-07-11 to **three
independent bugs**, every one a downstream consequence of the `$M`-loss
(syscomment clobber) era.  Summary: CLAUDE.md's "Self-hosting RESTORED"
changelog entry and the three STRONG RULEs in DOCS/IMPLRULE.MD (stack
frames, fatal NEW, jump-range discipline).

## The three root causes

1. **`Files.BlockCopy` 8 KB stack buffer + 8192-byte stack → SP wrap.**
   With the default stack (SP init 0x1FFE), entering BlockCopy's 8 KB frame
   wraps SP past 0 → the buffer lands at `SS:0xE000`-ish = **~56 KB above SS,
   inside the DOS heap block**.  Every `Tar.TarExtract` then sprayed the
   copied `.def` bytes over live heap objects (StrTab's interned text — the
   observed `"SYSTEM"` → `"Time_DateTime RECORD 12"` overwrite — or Files
   buffers of other open files).  This was THE "corruption inside
   `Files.BlockCopy`" localized by the 2026-07-10 instrumentation.
   *Fix:* `FILES.MOD` BlockCopy staging buffer 8192 → 512 bytes (`CopyChunk`).

2. **Silent heap exhaustion (unchecked `NEW`).**  `$M`-less binaries also got
   the default heap (max 256 KB); compiling today's PARSER.MOD needs more.
   `NEW` returns NIL, `Parser.IdListAppend`/`Syms.SymOpenScope` continued
   silently (NIL far writes land in the IVT under xt) → declared identifiers
   silently vanished → deterministic `undefined identifier` cascades (the
   `Parser.MOD(836): undefined identifier 's'` failure).
   *Fix:* both sites now latch `Err.Error("out of memory ...")` (fail-fast).

3. **Short-circuit `&`/`OR` used short (rel8) jumps over an unbounded RHS.**
   `PExpr.ParseAndTail`/`ParseOrTail` (tier 1.1, landed 2026-07-09) skipped
   the RHS with `CgCondShort`; the RHS of one `&`/`OR` can emit arbitrarily
   much code.  A >127-byte span wraps the rel8 **backward into mid-instruction**
   — the compiler's own `PStmt.ParseStatement` assignment type-check chain
   spans 142 bytes, so ANY compiler built with this codegen executed a wild
   jump on the first statement it compiled (the HASBODY.MOD "hang"/invalid
   opcode at CS:2453).  This is why `BOOT/TOC.EXE`'s gen1 hung while old
   `BOOT/TOC1.EXE` (pre-tier-1.1) gen1 did not.
   *Fix:* `ParseAndTail`/`ParseOrTail` use `CgCondNear`/`CgPatchNear`; and
   `Cgen.CgPatchShort` now latches a fatal
   `"internal: short jump out of range"` on any displacement outside
   −128..127, so this whole bug class can never be silent again.

## Why every bootstrap lineage failed differently

- `BOOT/TOC1.EXE` (pre-tier-1.1): correct codegen, but **drops `$M`** (single
  pending-syscomment clobber) → its gen1 ran with 8192 stack + 256 KB heap →
  bugs 1+2 at runtime (SYSTEM/Out undefined, `Files.om` not found at scale).
- `BOOT/TOC.EXE` / `TOC.EXE.PREV` (tier-1.1 era): carry bug 3 in their
  codegen → their gen1 executes a wild jump in ParseStatement → hang on any
  compile (HASBODY).
- The corruption "moved between builds" because the SP-wrap blast zone and
  the OOM point depend on binary layout — classic for wild writes; the
  July StrTab/Syms RAM-arena work moved live symbol data into the blast zone,
  which is why a months-old latent bug surfaced then.

## Verification (2026-07-11)

- Generation ladder seeded from `BOOT/TOC1.EXE` (gen1 header-patched to `$M`
  sizes since TOC1 drops the directive): gen2 ≠ gen3 (expected one-generation
  lag), **gen3 == gen4 byte-identical** — self-hosting fixpoint restored.
- MIN3.MOD (the minimal repro below) and HASBODY.MOD compile cleanly with the
  fixpoint compiler.
- Regression rows: `shortcircuit/long-chain-near-jumps` (LONGBOOL.MOD, >127
  byte spans), `stack/stacked-syscomments-keep-M` (STKQUEUE.MOD, stacked
  `(*$M*)(*$D+*)` must keep the `$M` → mz-sp 32766), plus the pre-existing
  SHORTCIR.MOD row.

## Historical minimal repro (kept for reference)

```oberon
MODULE Min3;
IMPORT Time;
PROCEDURE F(): LONGINT;
BEGIN
  RETURN SYSTEM.FSIZE(0)
END F;
END Min3.
```

Compiled by a `$M`-less self-built toc, `IMPORT Time` re-extracts `TIME.DEF`
via `TarExtract` → BlockCopy SP-wrap overwrote the interned `"SYSTEM"` text →
`undefined identifier 'SYSTEM'`.  With the fixes this compiles cleanly even
in a `$M`-less binary.

**Build trap (still true):** `SRC/TOC/Makefile`'s `OBERON.OM` target is a
plain copy; when bypassing `make` (direct `xt run ... TOC.MOD /M`), refresh
`SRC/TOC/OBERON.OM` manually after any `SRC/LIB` rebuild, or the build links
the stale library.
