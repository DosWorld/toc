# Project History

This is the dated changelog of resolved work items for the Oberon-07
compiler project — moved out of `CLAUDE.md` to keep that file focused on
current-state operating instructions. Entries are in roughly chronological
order (oldest first). Durable technical knowledge referenced from these
entries lives in `DOCS/IMPLRULE.MD`, `DOCS/OBERLANG.MD`, and the other
`DOCS/*.MD` files — this file is the narrative record of *when* and *why*
things changed, not the canonical description of current behavior.

---

* ~~Path escaping (DOS backslash paths in `-c` / `OBERON_LIB`).~~
**INVESTIGATED + DOCUMENTED (2026-06-22).**  The idea is **true**: an *unquoted*
backslash DOS path is mangled by the **shell** (the backslash is its escape
char), so `-c \123\DIR` reaches xt as `123DIR` and `OBERON_LIB=C:\lib` becomes
`C:lib` → the library is not found and the compile fails silently.  Verified both
in the shell and end-to-end in xt.  **It is a shell-quoting issue, not an xt or
compiler bug.**  The existing build already sidesteps it by using forward-slash
host paths for `-c` (`../../`, `$wd`) and single-quoting `OBERON_LIB`.
**STRONG RULE: always single-quote (or `\\`-double) any DOS path containing a
backslash in build/test scripts.**  Documented in
[DOCS/XT.MD](XT.MD) §"Filesystem and path conventions" and
[DOCS/IMPLRULE.MD](IMPLRULE.MD) §"Path handling".
  **No makefile fix was warranted** — every `-c` value uses forward-slash host
  paths and every `OBERON_LIB` is already single-quoted, so the build is safe.
  `SRC/TOC/Makefile` gained an explanatory comment about *why* it must copy
  `BIN/OBERON.OM` into its CWD (it is the `-c` mount root, so the real
  `BIN/OBERON.OM` is outside the mount and unreachable by DOS path; `olib`/`tools`
  instead mount the repo root with `-c ../../` + a quoted forward-slash
  `OBERON_LIB`).  The note's hoped-for "simplify build / remove OBERON.OM-location
  problems" does NOT apply: that copy is required by the mount model, not a path-
  escaping artifact.  (Separately, `make testall` has its own pre-existing harness
  bugs — `libDir` points at `\lib` instead of `\bin`, plus an `rdf extract` path
  issue — but those are unrelated to path escaping and are left for a dedicated
  "fix testall" task.)
* Change all makefiles: compiler must make self via one call `toc /ENTRY=Run TOC.MOD` without
makeing module-by module and final-linking.
* Building .om: File names for .om must be in uppercase always. Module names must be case-sensetive, but filenames (.mod files also) - uppercase.
* ~~Purge docs: fold mk_bug.md + opt.md into main docs and remove them.~~
**DONE (2026-06-22).**  Both files deleted; durable knowledge lives in
[DOCS/IMPLRULE.MD](IMPLRULE.MD) (§"Compile→link
defrag" + dead ends; §"Strength reduction & peephole optimizations" incl. the
deferred list).
* ~~Need compile self without make.~~  **DONE (2026-06-17).**
`toc /ENTRY=Run TOC.MOD` (whole compiler in one process) now completes and is
byte-identical across generations (toc2 == toc3).  Root cause was the per-module
heap leak (BUG 2): `PARSER.MOD` leaked one `IdentNode` per
declared identifier; `IdListFree` now frees those lists, dropping the
persistent per-module leak to 0 paragraphs so the 12-deep import tree fits in
one process.  The shipped `BOOT/TOC.EXE` carries this fix, so the `make` path
rebuilds `SRC/TOC` cleanly.
* ~~Zero leaks + byte-stable single-process self-host.~~  **DONE (2026-06-22).**
The link of the large TOC image no longer corrupts under heap fragmentation:
`ModEntryDefrag` (in `TOC.MOD`, between compile and link) frees the long-lived
dep-scan graph so the arena is contiguous for the linker.  `toc /ENTRY=Run
TOC.MOD` reports 0 leaked paragraphs at every phase and genA == genB == genC
byte-for-byte.
* Folder TESTS/ contains many modules which looks like abadoned. This is old stanalone tests
which need became to running test. You can detect this module - they import Test.
* ~~Fix a bug: constant can be INTEGER (LONGINT/WORD/BYTE) type only. No strings/sets/records/arrays etc — must produce a fatal error.~~
**DONE (2026-06-22).**  `Parser.ParseConstDecl` rejects any CONST whose value is
not INTEGER/LONGINT/WORD/BYTE (`CONST must be an integer … value`); CHAR/BOOLEAN/
REAL/LONGREAL/SET and string/array/record/pointer consts are fatal.  Affected
test fixtures rewritten (CHAR/string consts → VAR-init or inline literal; REAL
consts inlined in FLOAT.MOD).  See [DOCS/OBERLANG.MD](OBERLANG.MD)
§"CONST declarations are integer-only" and the EBNF `ConstDecl` note.
* ~~Need code refactoring: SYSTEM.HALT must be called only one time (TOC.MOD at end of Run). All files must be closed, also in error-cases.~~
**DONE (2026-06-26).**  Every failure now funnels to the **single** `SYSTEM.Halt`
in `OC.Run` (after the idempotent `OC.Cleanup`, which closes the module-graph
temp, symbol/type temps and the code-gen `RDFCODE`/`RDFDATA` temps).  No module
below `TOC` aborts the process: fallible procs report errors via a `VAR err:
BOOLEAN` out-param (`RdfInit`/`RdfWrite`, `CgInit`/`CgFinish`, `SymInit`,
`LoadExplicitImport`, the `TOC` helpers) or a module-level latch on hot/callback
paths (`Rdoff.rdfErr`, `Tar.tarErr`, `Link.linkErr`).  `olib` got the same shape
(`TOLib.RunBody(): INTEGER` + one `Halt`).  This also fixes the leak-on-error case
(temps/heap freed on every exit path).  Test: `import/unresolved-import-fails`
manifest row.  See [DOCS/IMPLRULE.MD](IMPLRULE.MD)
§"Single `SYSTEM.Halt` + error-return convention".
* ~~Check, fix and write tests: array and record assignment must work (via copy memory).~~
**VERIFIED (2026-06-27).**  Whole-array and whole-record assignment deep-copies
memory (REP MOVSB; not aliased) — covered by the PASSREC/PASSARR runtime fixtures.
* ~~Check, fix and write tests: passing parameters by-value and by-reference (VAR) must works.~~
**DONE (2026-06-27).**  Found + fixed a real codegen bug: a by-value RECORD/fixed
ARRAY arg pushed only 2 bytes while `argSize` reserved SIZE → SP imbalance →
"Invalid opcode" crash.  Fix = caller copies the whole aggregate onto the stack
(2-byte aligned, `Cgen.CgPushAggrValue`); callee reads it in place.  Open arrays
keep the 6-byte ref ABI.  Aggregate RETURN types are now rejected (result must be
scalar/pointer/proc).  Also fixed the `SYSTEM.UPSTR`/`LOSTR` INLINE off-by-2 jump
bug (proc body is 28 bytes; jumps targeted +30) and restored their
`(VAR s: ARRAY OF CHAR)` open-array signature.  Tests: PASSREC/PASSARR/PASSOPEN/
ASGNPARM/UPSTR/RETARR/RETREC.  See [DOCS/OBERLANG.MD](OBERLANG.MD)
§"By-value aggregate parameters" and §"INLINE + VAR / open-array params".
  **NOTE — multi-dim OPEN arrays (`ARRAY OF ARRAY OF`) are still rejected** by the
  type checker (a separate, pre-existing limitation; fixed multi-dim works).
* ~~Need fix bug: remove memory leaks in case errors. This is mean: all allocated memory must be free, opened files - must be closed.~~
**DONE (2026-06-26)** — same change as the single-Halt refactor above:
`OC.Cleanup` runs on every error path and closes all temps + frees heap, and the
error-return/latch convention means an aborting module can never skip it.
* ~~Extend Files module: temporary files via EMS + FS (`ReWriteTemp`).~~
**DONE.**  `Files.ReWriteTemp(VAR f): BOOLEAN` added with two backends:
`BkEms` (EMS-resident, allocated via `EMS.Alloc`, freed on `Close`) and `BkDisk`
(hidden auto-named `<nnnnnnnn>.TMP`, delete-on-close).  `BlockRead`/`BlockWrite`/
`Seek`/`Truncate`/`Close` work transparently on both because **both backends
share the same 8 KB `F.buf` and the same `BufFetch`/`BufFlush` path** (EMS just
swaps `DOSRead`/`DOSWrite` for `EMS.CopyToDos`/`EMS.CopyToEMS`); `BUFSIZE`=8192
is even so every EMM move is 2-byte-aligned.  **EMS is live under `xt`** (its
EMM emulation is spec-correct as of 2026-06-25), so the compiler runs under xt
*without* `--noems`.  (Earlier a separate EMS staging path in `Files.MOD` was
the cause of the "compiles but writes nothing under EMS" bug, now fixed.)
* ~~Small record memory optimization (chunk small value-records).~~
**DONE.**  `FwdNode`/`InlineNode`, `RDOFF.MOD` `RelocNode` (256/chunk, parallel
`physSeg/offset/width/rseg`) and `LINK.MOD` `MZReloc` (256/chunk, one BlockWrite
per chunk) now pack N entries per node (`payload: ARRAY N OF …; count; next`).
**STRONG RULE documented** in
[DOCS/IMPLRULE.MD](IMPLRULE.MD) §"Chunk small
records" (incl. the rule that every reader — *including `SRC/TOOLS/RDFGREP.MOD`* —
must iterate the chunk, not read a scalar).
* Need refactor compiler/linker/olib code: remove all wrappers for modules Files, Strings, Dos, IO.
* ~~Need reactor error handling: use new module Err (ERR.MOD) - this one source for
all errors/warns. Need remove procs like Fatal and err variable from other modules.~~
**DONE (2026-07-02).**  Module **Err** (`SRC/TOC/ERR.MOD`) is now the single error
state and the single place any message is printed for the whole toolchain.
Removed: `Rdoff.rdfErr`/`Rdoff.Fatal`, `Tar.tarErr`/`Tar.Fatal`, `Link.linkErr`,
`PExpr.errors`, `Parser.parserErrors`, `Scan.errCount`, and every `VAR err:
BOOLEAN` out-param (`RdfInit`/`RdfWriteTo`/`RdfWrite`, `CgInit`, `SymInit`,
`LoadExplicitImport`); callers now test `Err.HaveErr()`.  **Fail-fast:** the first
`Err.Error` latches and aborts the whole run (no `Err.Reset`).  Routing:
ERROR→stderr (latches); WARN/INFO/DEBUG→stdout; positional diagnostics use the
`*InFile` variants (`Err.ErrorInFile`/`WarnInFile`) so every message carries
`filename(line):`.  **Logging:** `Err.Open`/`Err.Close` (called in every tool's
`Run`: oc, olib, rdfgrep, testall) write `output.log` (all messages) and
`error.log` (errors only).  olib/rdfgrep keep genuine tool DATA on stdout; their
diagnostics go via Err.  testall prints via Err and is itself fail-fast (FAIL via
`Err.Error`).  See [DOCS/IMPLRULE.MD](IMPLRULE.MD)
§"Error handling: module Err".
* ~~Need check codegeneration for INC/DEC (1 and 2 parameter): if address is computable at
complie time, need generate "INC [memory_addr]" or "ADD [memory_addr], ???" instead
LOAD+INC|DEC+STORE. Need carryfull handle different types (BYTE,CHAR,INTEGER,WORD,LONGINT,SYSTEM.ADDRESS)~~
**DONE (2026-07-02).**  `INC`/`DEC` on a fixed-displacement variable now emits
a memory-destination op instead of LOAD+op+STORE.  Covers near vars (`FF 06`/
`FE 06`/`ADD [x],N`/`ADC` for LONGINT carry / offset-only for ADDRESS) AND far
refs `p^`/far `VAR` param (`26`-prefixed `[ES:BX]` forms, ES:BX loaded once).
All types + step-1/const/runtime + INC/DEC verified by `TESTS/TINCDEC.MOD`.
byte-stable fixpoint (toc2 == toc3); the stock `oc1 == oc2` self-host check lags
one generation until `BOOT/TOC.EXE` is refreshed.  See
[DOCS/IMPLRULE.MD](IMPLRULE.MD) §"INC/DEC
memory-destination fast path".
* ~~Need refactor data/code flow: Tempfile (code) Tempfile (data)
 -> Tempfile (full rdf) -> File (tar/om)~~
**DONE (2026-06-27).**  The full `.rdf`, the `.def` and `MAIN.RDF` are now all
**temp files** (`Files.ReWriteTemp`, auto-deleted on `Close`) — none is ever
materialised as a named file on disk; each is streamed straight into the `.om`.
Flow is now: Tempfile(code)+Tempfile(data) → Tempfile(full rdf) +
Tempfile(.def) → File(.om/tar).  Mechanism: `Rdoff.RdfWrite` was split into
`RdfWriteTo*(obj, VAR f, VAR err)` (serialises into a caller-owned, rewound
file) plus a thin named-file wrapper; `Parser` writes the per-module .rdf/.def
into temps and `TarAddFromFile`s them (tar MEMBER names stay `MODNAME.RDF`/
`.DEF`, so archive bytes are unchanged); `TOC` builds `MAIN.RDF` into a temp owned
by `CompileModule` (opened+streamed+closed inside ONE LeakGuard window so the
open 8 KB buffer never trips the zero-leak check; closed on every path incl.
GenEntryStub/RepackOm failure).  The unused `Cgen.CgFinish` wrapper was removed.
Verified 265/0 manifest + self-host 13/0 byte-identical + 0 leaks.
* Need analyze source code of compiler (and linker), generated code and compiler architecture.
CODE IS UNACCEPTABLE SLOW. So, need find a way how to optimize it. My ideas:
- reduce using slow LONGINT (use fast WORD instead).
- May be add module "string table" (it allow store stringId: WORD instead ARRAY OF CHAR's and compare id's),
- pass arrays/records by ref instead by value (identifier's names etc).
- reduce reading Syms (pass by ref into child calls, where possible)
- reduce slow FAR calls. Example:
PROCEDURE Emit1*(b: BYTE);
BEGIN
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b)
END Emit1;

PROCEDURE Emit2*(b0, b1: BYTE);
BEGIN
  Emit1(b0); Emit1(b1)
END Emit2;

can be refactored to:

PROCEDURE Emit2*(b0, b1: BYTE);
BEGIN
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b0)
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b1)
END Emit2;

but calls for both (Emit1/Emit2) can be replaced into source to direct call
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b)
and
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b0)
  Rdoff.EmitByte(CgObj, Rdoff.SegCode, b1)
- Pass aggregate types by ref. By value is slow.

Find more other ways. Remember about DOS memory limits.
In fact, this compiler could be implemented in 1-2k lines, but we have a huge codebase.
So, problem in architecture, also.
Prepare big plan for radical optimization and store it into bigopt.md.

**DONE.** Two successive optimization rounds (both plan documents folded into
this file and `DOCS/IMPLRULE.MD` once complete, then removed — same pattern
as the earlier `mk_bug.md`/`opt.md` fold noted above).

**Round 1 (2026-06-28, small "Quick Wins" pass, plan was `bigopt.md`):**
QW1 = `RDOFF` `codeLen`/`dataLen` → WORD (output-neutral); QW2 = by-`VAR`
aggregate params (found ALREADY satisfied); QW3 = NEAR-ize 10 `Cgen`-internal
procs. **KEY LEARNING:** Metric A (xt instruction count) is blind to
NEAR-vs-FAR call savings and WORD-increment wins — those are code-size/
real-cycle wins, tracked via binary size, not instruction count.

**Round 2 (2026-07-08/09, full 10-batch plan, plan was `opt.md`) — every
batch executed, every item resolved (landed or explicitly skipped):**

*Landed:* G1 (`XCHG AX,CX`); G2 (array-index base-add collapse); G3a/b/c
(`CgCondNear`→`CgCondShort`); G4 (FOR-loop `CgCmpAxBp`); G5 (CASE
`ReloadCase` hoist); G6 (ASSERT const-fold); **G7 CASE jump-table dispatch**
(the plan's riskiest item — needed new infrastructure beyond the original
estimate: `Scan.Mark`/`Scan.Restore` scanner-rewind primitive, five new
`Cgen` codegen primitives, a side-effect-free label pre-scanner
(`PreScanLabel`/`SkipArmBody`/`PreScanCase`), and the table-building codegen
(`ParseCaseTable`) in `PSTMT.MOD`; new test
`TESTS/TCASETBL.MOD`, 7 cases, also runnable standalone
via `toc /ENTRY=RunAllTests TCASETBL.MOD` — bypasses `make testall`'s
unrelated pre-existing harness bugs); S1 (33 emit-series merges across
CGEN/PEXPR/PSTMT, incl. 8 safety-critical INC/DEC carry/borrow paths); S2
(premise didn't hold for this codebase — landed as dead-code removal instead:
`Cgen.Emit4`, `Cgen.CgIncDecEsbx`, `Rdoff.EmitByte4`, plus a doc-accuracy
fix); S4, S7, S8-S10, S12-S17, S18, S19, S21-S26, S25 (assorted source-size
reductions across PEXPR/PARSER/DEF/RDOFF/LINK/TOC — table-driven `Def`
serializers, shared ident-list/param-list parsing, `Link.FindFile` reuse,
`PatchBuf` merge, `SYSTEM.FILL` in `NewModule`, etc.).

*Skipped, each for a documented reason (not oversights):* **S3** (unify the
VAR-param and open-array far-address push ladders in `ParseActualParameters`)
— real semantic differences (extra `MProc`/`MImport` branches, `DS`-vs-`DX`
fallback register choice) made unification too risky for ~30 source lines.
**S6** (`FormOf` accessor helper) — directly contradicts the project's own
"No accessor wrappers" rule (`DOCS/IMPLRULE.MD` §"Symbol table: RAM
pointer-record arena" — that exact kind of helper was deliberately removed
from `Syms` on 2026-07-05). **S11** (LONGINT INC/DEC step-combine factoring)
— deferred as its own dedicated single-item batch; the plan itself flags it
"most safety-critical recent codegen." **S20** (`ScanTar`/`ListTar` merge) —
the "strict subset" premise didn't hold (incompatible callback signatures,
real re-entrancy risk from bridging via module state for ~15 duplicated
lines).

**4 real bugs found and fixed during implementation** (not pre-existing, all
caught before landing): a `Files.File` value-copy bug (S17 draft — copying
the value-type file record instead of writing through the original silently
drops buffered output); a module-init-ordering bug (S8 draft — `Def`'s
module BEGIN block runs before `Syms.SymInit` sets `Syms.TypeXxx`, so a
cached type-pointer table would have held stale values, fixed with a live
`PrimTypeOf` dispatch instead); a `LOOP`/`EXIT`-not-supported compile error
(G7 draft — this dialect has neither keyword at all); and a CASE
out-of-range dispatch bug (G7 draft — the "default" landing point had no
actual jump past the arm bodies, so out-of-range values silently fell into
arm 1's body — caught by the new `TCASETBL.MOD` test, not by `make test`,
fixed with an explicit `defaultJmp` backpatch).

**Verification discipline held for every single item:** `make test`
(272/272 manifest) + either `toc1==toc2` (source-only, no codegen change) or
self-host `gen2==gen3` (codegen changes) + 0 heap leaks on every round.
**Trap hit twice: never run two `make test`/self-host builds concurrently in
the same tree** — several apparent regressions during the session turned out
to be exactly this race, not real bugs.

**Compiler Code segment** (self-hosted binary, `TOC.EXE`): 242,864 (original
baseline) → 239,840 (final) bytes — a net reduction despite G7 alone growing
the binary by ~3 KB for its new dispatch machinery (that cost buys
per-compiled-*program* dispatch speed on dense `CASE` statements elsewhere,
not a self-hosting size win).

**2026-07-09 deep bug/code-smell review (plan document was a second,
unrelated `opt.md`, folded into this file and deleted 2026-07-11 —
same pattern as Round 1/2 above):** full static read of `SRC/TOC/*.MOD` +
`FILES.MOD`/`STRINGS.MOD` found 12 critical/major bugs, 20 minor bugs, and
16 code smells. Ten of the twelve critical/major findings were fixed and
verified the same session (`make test` + self-host byte-identity each time):
non-short-circuit `&`/`OR` (spec violation, silent NIL/DIV hazards), a
global-VAR->32K silent data-corruption bug, three-way inconsistent `DIV`/`MOD`
semantics (const-fold vs strength-reduce vs runtime disagreed on negative
operands), `LONGINT:=WORD` sign-extending instead of zero-extending, missing
FOR-loop control-variable kind checks (KConst/KVarParam silently corrupted
memory), an `Files.Reset`-failure path that could free a live EMS handle,
unbounded `Strings.Append` (reachable stack-smash via `Err.Emit`), scanner
comment-recursion stack overflow, and I/O-failure-reported-as-success bugs in
`RdfWriteTo`/`ParseModule`. Fixing 1.1 (`&`/`OR` short-circuit) then
triggered a genuine self-hosting crisis — traced over the following two
sessions (2026-07-10/11) to three unrelated root causes (`Files.BlockCopy`
stack-wrap, silent-OOM, and the short-circuit codegen's own rel8 jump
overflow — see "Self-hosting RESTORED" in `DOCS/IMPLRULE.MD` and the three
STRONG RULEs there). Full narrative kept in
`TESTS/FIX/BUGREPRO.md` and `TESTS/FIX/SYSCOMMENT_STACK_BUG.md`.

**2026-07-11 (later same day) follow-up stability sweep — 4 of 5 open items
resolved, verified via `make test` (277/277, 0 FAIL, 0 leaks) after each
change:**
- **4.1 DONE** — hardened all ~15 remaining unchecked `NEW` sites across
  `Tar`/`TOC`/`PStmt`/`TDbg`/`Import` (beyond the two from the 07-11 OOM fix).
  Each now checks for `NIL` and latches `Err.Error` instead of risking a NIL
  far write into the IVT. Two new module-init static fallback nodes
  (`PStmt.bpOomNode`, matching the existing pattern) needed for call sites
  that dereference the returned pointer with no room for a per-call-site
  bailout (`BpPush`'s backpatch-chain callers).
- **2.8 DONE** — `Syms.AllocSym`/`AllocType`'s OOM fallback ("return the most
  recent record") underflowed `symCount-1`/`typeCount-1` to 65535 on the very
  first allocation failure (`symCount=0`), reading `symDir[255]` 8x past the
  32-entry directory. Fixed with two static fallback nodes (`Syms.symOom`/
  `typeOom`) used only for the `count=0` edge case.
- **2.9 DONE** — `PEXPR.MOD EmitInlineCall`'s `argAdr`/`argGlobal ARRAY 32`
  read-side guard checked `idx < nArgs` but not `idx < 32`; an INLINE call
  with ≥32 actual args let `nArgs` exceed 32 while `idx` stayed in range,
  reading past both arrays. Fixed: added a fatal `Error` when `nArgs >= 32`
  at parse time, and the read-side guard now also checks `idx < 32`. (Full
  arity/type checking for INLINE calls — a separate, non-crash correctness
  gap the same finding also noted — was left out as scope creep beyond the
  memory-safety fix.)
- **2.5 PARTIAL** — `SCAN.MOD ScanNumber`'s decimal-literal accumulation now
  overflow-checks before each `v*10+d` (fatal `"numeric literal too large"`
  on true LONGINT overflow, clamped to `MaxLongint`) — landed and verified.
  The other half (type literals 32768..65535 as LONGINT instead of INTEGER
  in `PEXPR.MOD ParseFactor`) was **implemented, then reverted** after it
  broke self-hosting: `RDOFF.MOD`'s own `CONST SegLimit* = 65530` sits in
  that range, and retyping it (via `Parser.ParseConstDecl`'s local-decl path,
  not `DefRead`) rippled into a real regression — a freshly self-hosted
  `TOC.EXE` rejected `Halt(code: INTEGER)` called with a same-module INTEGER
  CONST actual (`Syms.TypeParamCompat`'s pointer-identity check for value
  params apparently resolves a different `TypeInteger` somewhere downstream).
  Root cause not fully traced. The threshold stays at 65536 (matching WORD's
  actual range); see the comment at the `ParseFactor` TInt case.
- **2.7 residual — INVESTIGATED, NOT REPRODUCIBLE, no change made.** Static
  trace of `RDOFF.MOD`'s `Rs`/`RdfLoad`/`ScanHeader` against current source
  found the claimed infinite-loop-on-truncated-input does not occur:
  `Files.ReadByte`/`ReadWord`/`ReadDWord` (`SRC/LIB/FILES.MOD`) already
  zero-fill their output on EOF failure, and that zero happens to coincide
  with each loop's own terminating sentinel (`Rs`'s `c=0`, `RdfLoad`'s
  `segType=0`); `RdfLoad`'s header-record loop is independently bounded by an
  unconditionally-incremented counter regardless of read success; `ScanHeader`
  already explicitly checks `ReadByte`'s BOOLEAN result and both its loops are
  bounded by arithmetic, not a read-dependent sentinel. Likely fixed or never
  quite as described by the time of this follow-up — re-verify with an actual
  truncated-`.om` fixture (needs custom binary construction, not just a
  manifest row) before spending more time here.
- **1.5 DONE** — `RDOFF.MOD`'s `emitN`/`EmitWord`/`EmitBlock`/`EmitZero` now
  guard the WORD `codeLen`/`dataLen` counters against silent wrap before it
  happens (compare in LONGINT before the `INC`), instead of relying solely on
  `RdfWriteTo`'s one-shot `>= SegLimit` check which a wrapped counter could
  slip past with a falsely-small value.
- **2.1 DONE** — `PEXPR.MOD`'s generic relop path now rejects `ARRAY OF CHAR`
  operands at compile time (fatal, except the pre-existing `s = ""` byte-mask
  special case) instead of silently falling through to a 2-byte word compare
  of the first two characters. Regression tests `TESTS/FIX/ARRCMP1.MOD`
  (rejected) / `ARRCMP2.MOD` (still accepted).
- **2.2 DONE** — `DEF.MOD DefRead`'s CONST branch now infers LONGINT for an
  imported value outside signed INTEGER range (-32768..32767) instead of
  always typing INTEGER; the `.def` line format is unchanged (reader-only
  change), so no `TDEF.MOD`/format update needed. Regression test:
  `TESTS/FIX/USEBIG.MOD`+`CSTBIG.OM`. (This is the import-side analogue of
  the reverted 2.5 half above — it stayed safe because it only affects
  symbols read back through `DefRead`, never a module's own local CONST
  declarations, so it can't retype something like `Rdoff.SegLimit` from the
  declaring module's own perspective.)
- Lower-priority items not restated here (2.11/2.12 DOS 3.x LFN/temp-name
  portability, the full §3 minor-bug list, the full §4 code-smell list) are
  no longer tracked in a standalone document — re-derive from source review
  if picked up again.

**2026-07-11 (later same day, second follow-up) — `/LOG=` switch, `SegBuf`
type change, array-relop audit, `SYSTEM.FINDBYTE`, `Strings`/`Files` speedups
— verified via clean self-host + `make test` (280/280 pass, 0 FAIL) after
every round, candidate staged as `TOC_CANDIDATE.EXE`:**
- **`/LOG=` (or `/log=`) CLI switch DONE** — `toc.exe` now accepts
  `/LOG=debug|info|warn|error` (case-insensitive), calling `Err.SetLevel`
  only from inside that argument-parsing branch in `TOC.MOD` — `Err.MOD`'s
  own default level and `TOC.MOD`'s unconditional startup behavior are
  deliberately left untouched (both were tried and explicitly reverted per
  maintainer instruction: don't change the default, use the flag instead).
  Wired into every Makefile invocation of `toc.exe` (`SRC/LIB/Makefile`,
  `SRC/TOC/Makefile`, `SRC/TOOLS/Makefile`) as `/LOG=debug` so dead-code
  warnings show up in normal builds without changing any module's default.
- **`RDOFF.MOD SegBuf*` changed to `SYSTEM.ADDRESS`** (was `POINTER TO ARRAY
  65535 OF BYTE`) per maintainer request. Verified via an isolated test that
  `SYSTEM.ADDRESS` supports `p^[i]` indexed read/write, `NEW(p,n)`, and
  `DISPOSE(p)` identically to `POINTER TO ARRAY` — so `RDOFF.MOD`'s
  `ReadSeg`/`ReadCode`/`ReadData` needed zero changes, and `LINK.MOD` needed
  only two call sites updated (`NEW(ls^.dataBuf, Rdoff.SegLimit)` /
  `NEW(ls^.codeBuf, Rdoff.SegLimit)` — explicit size now required).
- **Array-of-CHAR relop anti-pattern — full-tree audit DONE.** Beyond the
  five `PARSER.MOD` sites fixed under 2.1 above, self-hosting the compiler
  under its own new fatal-error rule (2.1) surfaced the compiler's *own*
  source violating it: `iname = "SYSTEM"` / `iname # "SYSTEM"` in `TOC.MOD`,
  and — found only via a live self-hosting compile failure, one at a time —
  `Parser.MOD(737)` (`PExpr.sc.id # name`, a procedure-END-name-mismatch
  check) and `Parser.MOD(1135)` (`PExpr.sc.id # modName`, the module-END-name
  check). All converted to `Strings.Equal`/`~Strings.Equal`. Fixture breakage
  found the same way: `TESTS/FIX/UPSTR.MOD` (`s # "HELLO.MOD"`) and
  `TESTS/TPRSR.MOD` (`Parser.parserModName = "Prsr01"`), both rewritten to use
  `Strings.Equal`. A full grep sweep of `SRC/TOC/*.MOD`, `SRC/LIB/*.MOD`,
  `SRC/TOOLS/*.MOD`, `TESTS/*.MOD` for both literal-vs-array and
  identifier-vs-array relop patterns found no further violations — all
  remaining `#`/`=` hits against name-like arrays are element-wise CHAR
  comparisons (`name[j] # 0X`, `imp^.name[j] # modName[j]`), which are safe.
  See the **STRONG RULE** block in [DOCS/OBERLANG.MD](OBERLANG.MD)'s
  "Known limitations" section for the full incident narrative and the audit
  grep pattern.
- **`SYSTEM.FINDBYTE(VAR buf; b: BYTE; maxLen: WORD): WORD` — new INLINE
  intrinsic DONE.** Added to `SRC/LIB/SYSTEM.MOD` following the existing
  `MOVE`/`FILL` typeless-`VAR`-POP-based pattern (SYSTEM intrinsics beyond
  the compiler-built-in set — `NEW/INC/DEC/LEN/ODD/ABS/ASSERT/COPY/ORD/CHR/
  FLOOR/ENTIER/DISPOSE/SIZE/LSL/LSR/ASR/ROR/AND/IOR/XOR`, registered in
  `SYMS.MOD SymInit` — are ordinary library `INLINE(...)` procedure
  declarations, not compiler dispatch cases; `ADR/SEG/OFS/PTR/MOVE/FILL/
  PORTOUT/PORTIN` all live in `SYSTEM.MOD` this same way). Implemented via
  `REPNE SCASB`; the zero-length guard deliberately uses `OR CX,CX`/`JZ`
  instead of `JCXZ` per the project's no-`JCXZ`/`LOOP` rule (both are slow on
  real 8086 hardware). Returns the 0-based offset of the first match, or
  `maxLen` if not found. Documented in
  [DOCS/OBERLANG.MD](OBERLANG.MD), `DOCS/OBERON07.EBN`, and
  `MANUAL.MD`. Test: `TESTS/TSYSMV.MOD TFindByte` (start/end/middle/
  not-found/zero-length/odd-offset/match-beyond-window cases).
- **`Strings.MOD` speedups DONE.** `Insert`/`Delete`/`Replace`/`Extract`
  rewritten to use `SYSTEM.MOVE` wherever the access pattern is provably
  non-overlapping: `Delete` (shift-left, dst addr < src addr — forward
  `REP MOVSB` never reads overwritten data), `Extract`/`Replace` (dst is
  always a separate array or `src` is a value param, so never aliased with
  `dst`). `Insert`'s shift-*right* portion is kept as a manual backward loop
  (`SYSTEM.MOVE` is forward-only — `CLD`/`REP MOVSB` — and would corrupt
  overlapping backward-shift data), but the subsequent copy-into-gap step
  uses `SYSTEM.MOVE` (safe: `src` is a value param). `Strings.Pos` gained a
  `SYSTEM.FINDBYTE` fast path for single-character patterns (`REPNE SCASB`
  instead of the general double-loop substring search). Test:
  `TESTS/TSYSMV.MOD TStringsPos`.
- **`Files.MOD` speedups DONE.** Audited every procedure for manual
  byte-copy/scan loops; two real candidates found and rewritten:
  `CopyName` (`SYSTEM.LENGTH` + `SYSTEM.MOVE`, safe because `name` is a value
  param at both call sites — `Reset`/`ReWrite` — so it can never alias
  `F.name`) and `ReplaceExt` (the four-way dot/separator scan stays a manual
  loop — it tests 4 distinct byte values per position, not a FINDBYTE
  candidate — but both straight-line copies afterward now use
  `SYSTEM.MOVE`). Everything else checked and left alone: `BlockRead`/
  `BlockWrite` already used `SYSTEM.MOVE` for their page-chunk copies;
  `BlockCopy` is disk-I/O-bound (`BlockRead`/`BlockWrite` calls, not memory
  copies) and deliberately untouched per the existing `Files.BlockCopy`
  8 KB-stack-buffer STRONG RULE; `MakeTempName` computes digits (division),
  not a copy; `ReadAsciizString`/`ReadLine` are byte-at-a-time from disk I/O,
  no batch copy possible; the DOS `Intr`-register-based procs
  (`FileExists`/`GetFTime`/`SetFTime`/etc.) have no memory copy loops at all.
- Manifest is now **280 rows** (was 272/277 at earlier points in the
  session — new regression rows added: `arrcmp/general-case-rejected`,
  `arrcmp/empty-string-still-ok`, `constimp/big-const-not-truncated`, plus
  `/LOG=debug` added to the 11 `dead/*` rows' oc-flags column so dead-code
  warnings are exercised under the new default-off-unless-flagged behavior).
  **`TOC_CANDIDATE.EXE` staged at repo root, not yet installed into
  `BOOT/TOC.EXE`** as of this entry — install manually after review, per the
  established discipline (never install directly from an agent session).

**2026-07-11 (later same day, third follow-up) — `Rdoff`/`Tar`/`Err` moved
from `SRC/TOC` to `SRC/LIB`; `Err` renamed to `LogErr`:**
- **Move DONE.** `RDOFF.MOD`, `TAR.MOD`, `ERR.MOD` relocated from `SRC/TOC/`
  to `SRC/LIB/` — no longer compiler-internal, now ordinary stdlib modules
  merged into `OBERON.OM` (per maintainer decision: implicitly available via
  plain `IMPORT`, same as `Strings`/`Files`, rather than kept as separate
  unmerged `.OM` files requiring an explicit `OBERON_LIB` entry).
- **Rename DONE.** `Err` → `LogErr` (`ERR.MOD` → `LOGERR.MOD`) everywhere:
  `MODULE`/`END` lines, all `IMPORT` lists, all `Err.*` call sites across
  13 compiler modules (`CGEN`/`DEF`/`IMPORT`/`LINK`/`PARSER`/`PEXPR`/`PSTMT`/
  `SCAN`/`STRTAB`/`SYMS`/`TDBG`/`TOC`, plus `RDOFF`/`TAR` themselves), 4
  `SRC/TOOLS` modules (`RDFGREP`/`TDINFO`/`TOLIB`/`TOSTRIP`), and
  `TESTS/TESTALL.MOD` — 260 total substitutions, done via a whole-word
  (`\bErr\b`) regex sweep, verified to not collide with the unrelated
  lowercase `err` local-variable identifier used throughout `LOGERR.MOD`
  itself.
- **Build graph simplified.** `SRC/TOC/Makefile`'s `OC_SRCS` no longer lists
  `RDOFF.MOD`/`TAR.MOD`/`ERR.MOD` — the compiler's self-host dep-scanner
  (`TOC.MOD`'s `FindSrc`) simply won't find them in the CWD-only mount,
  which is correct: `ScanDeps` already treats any import it can't resolve to
  a local source as `.OM`-only (the same path `Strings`/`Files`/`IO` already
  took during self-host before this change) — no mount/`OBERON_LIB` changes
  needed in `SRC/TOC/Makefile` at all.  `SRC/TOOLS/Makefile`'s
  `OBERON_LIB` simplified from `BIN/OBERON.OM;SRC/TOC/RDOFF.OM;SRC/TOC/TAR.OM;
  SRC/TOC/ERR.OM` down to just `BIN/OBERON.OM`, since the merge makes the
  three extra entries redundant.  `SRC/LIB/Makefile` gained three new build
  rules (`ERR.OM`/`RDOFF.OM`/`TAR.OM`, in that dependency order) and all
  three were added to `STDLIB_OMS` so `make install`'s `tolib.exe merge`
  step picks them up automatically.
- **Motivation:** paves the way for `SRC/TASM/` (planned at the time,
  since implemented) to reuse `Rdoff`'s RDOFF2-writing API and `LogErr`'s
  diagnostic/single-Halt convention via a plain stdlib `IMPORT`, with no
  special-case `OBERON_LIB` wiring — consistent with how every other tool in
  the repo already depends on the stdlib.
- **Verification:** full clean `make test` — see the entry immediately
  following this one for pass/fail counts.

**2026-07-13 — Trubo Link (`SRC/TLINK/`), a second linker for tiny/small
memory models, plus two real bugs found and fixed along the way:**
- **`SRC/TLINK/TLINK.MOD`** merges two Turbo Pascal linker programs,
   (tiny model: `.COM`/`.SYS`, single contiguous code+data+bss
  segment, no relocation table) and (small model: `.EXE` with
  an MZ relocation table), which shared ~90% of their logic (module/symbol
  scanning, RDOFF2/RDLIB2/TAR auto-detection, smart-link marking from an
  entry symbol) — kept once, branching only at layout/output time on a
  `/T=com|sys|exe` mode switch. Reuses `Rdoff.ScanHeader`/`ScanRelocs`/
  `ReadCode`/`ReadData` (the same primitives `SRC/TOC/LINK.MOD` uses for
  `toc.exe`'s own embedded linker) instead of re-parsing RDOFF2 records by
  hand; RDLIB2 scanning is new (no prior reader existed). AR (`.a`) archive
  support from the originals was dropped as unneeded. Follows the project's
  standing conventions: `LogErr`/single-`Halt`/`/LOG=` (matching
  `toc.exe`/`tasm.exe`), chunked `Symbol`/`Import` records (small-record
  rule), and a `LeakGuard` window around the per-module import-scan phase.
  Built via `SRC/TLINK/Makefile` (same shape as `SRC/TASM/Makefile`) →
  `BIN/TLINK.EXE`; not part of `make all` (standalone leaf tool).
- **Real bug #1 (compiler codegen, `SRC/TOC/PSTMT.MOD`)**: whole-record
  `:=` assignment silently transferred only the first WORD field —
  corrupting every other field — for two shapes the existing branches
  never covered: `plainDest := arrayElem` and `varParamDest := arrayElem`
  (both have the array-element source as `Cgen.MReg`, a shape
  `Cgen.CgLesBxItem` mishandled by treating it as a BP-relative local).
  Found while implementing `TLink.ImpFind`'s `e := n.sym[i]` (an
  array-of-RECORD element read through a chunked-node pointer, assigned to
  a `VAR` out-parameter). Fixed by extending both branches to recognize
  `rhs.mode = Cgen.MReg` and use the already-computed ES:BX far address
  directly instead of re-loading it. See
  [DOCS/IMPLRULE.MD](IMPLRULE.MD) §"Record assignment: two missing
  far-source (`MReg`) cases". Regression: `TESTS/FIX/ASGNREC.MOD`.
- **Real bug #2 (stdlib, `SRC/LIB/STRINGS.MOD`)**: `Strings.Append`'s
  truncation-clamp formula folded the source's NUL terminator into the
  same `MIN` as the character count, so appending to a destination with
  **exactly 1 byte of room left** silently dropped the character entirely
  (the single copied byte was immediately overwritten by the terminator
  write at the same index) — an infinite loop for any caller padding a
  fixed-width field via `WHILE Length(d) < N DO Append(" ", d) END`
  (`TLink`'s `/N:` 8-char device-name padding). Fixed by separating the
  character-count clamp from the terminator write. See
  [DOCS/IMPLRULE.MD](IMPLRULE.MD) §"`Strings.Append` truncation
  off-by-one".
- **Verification:** both fixes landed together, verified via full clean
  `make test` (281/281 manifest — one new row, `asgnrec/array-elem-record-
  assign` — 0 fail) and the single-command self-host fixpoint (`gen2 ==
  gen3` byte-identical). `TOC_CANDIDATE.EXE` staged at repo root, not yet
  installed into `BOOT/TOC.EXE` as of this entry.
- Manifest grew from 280 to **281 rows**.

---

## 2026-07-14 — SYS.ASM/SYS.RDF renamed to SYSTEM.ASM/SYSTEM.RDF

- `SRC/LIB/SYS.ASM` -> `SRC/LIB/SYSTEM.ASM` and `SRC/LIB/SYS.RDF` ->
  `SRC/LIB/SYSTEM.RDF` (matching their module, `SYSTEM.MOD`). All
  references updated: `SYSTEM.MOD`'s `(*$L SYSTEM.RDF*)` directive,
  `SRC/LIB/Makefile` (SYSTEM.OM rule + `regen-asm`), `TESTS/test_tasm.sh`
  oracle rows, and every doc/comment mention (README, MANUAL, CLAUDE.md,
  DOCS/BUILD/TESTS/IMPLRULE/PORTING, RDOFF/RDFLOAD/DOS/PEXPR/TASM
  sources). No collision inside `SYSTEM.OM`: `$L` members are stored
  under a `MODNAME/` prefix (`SYSTEM/SYSTEM.RDF`), distinct from the
  compiled `SYSTEM.RDF` member. The `.RDF` content is byte-identical
  (TASM embeds no source filename), so generated code is unchanged;
  verified with a full clean `make test`.

---

## 2026-07-21 — `tlink /T=texe` (tiny-model MZ `.EXE`) added

- New `/T=texe` mode: the same tiny-model layout as `/T=com` (contiguous
  code+data+bss, no relocation table, `DS=CS=SS=PSP` at runtime) but
  wrapped in a minimal MZ header instead of relying on DOS's `.COM`-loader
  convention — no on-disk `JMP` stub, header `CS=SS=-1` paragraph (PSP
  segment), `IP=entry+0x100`, `SP=0xFFFE`, `MinAlloc=MaxAlloc` sized to
  reserve the rest of the 64K PSP segment. New module
  `SRC/TLINK/TEXE.MOD` (`TExe`) holds the writer; `TLINK.MOD` gained
  `ModeTExe` and dispatch to it.
- **Real bug found and fixed** while validating `texe` end-to-end:
  `TLINK.MOD`'s `OnReloc` never applied the PSP (`CS:100h`) address bias to
  *absolute* in-image references — only relative (`call`/`jmp`) fixups
  worked, since the bias cancels out on both sides of that subtraction.
  This had been silently broken in `/T=com` since tiny-model linking was
  first added: any `.COM` output taking an absolute address of code/data
  (e.g. `mov dx, msg`) resolved to the wrong byte and either printed
  garbage or looped forever (`INT 21h AH=9`'s `$`-terminated string scan
  reading unrelated memory) instead of failing loudly, so it went
  unnoticed until `texe` needed the identical bias and a byte-exact stdout
  test caught it. Fixed by adding `+0x100` to `OnReloc`'s absolute-fixup
  path, gated on `ModeCom OR ModeTExe` (never `ModeSys`, which has no PSP).
  See [DOCS/IMPLRULE.MD](IMPLRULE.MD) §"Bug found and fixed while adding
  `/T=texe`".
- New regression test `TESTS/test_tlink.sh` (fixtures
  `TESTS/FIX/TLINKHI.ASM`, `TESTS/FIX/TLINKDRV.ASM`): links `/T=com` and
  `/T=texe` outputs and runs each under `xt`, checking stdout matches the
  expected greeting byte-for-byte (catches both wrong data and runaway
  output); checks `/T=sys`'s device-driver header fields. Wired into
  `make test` alongside `test_tasm.sh`. See
  [DOCS/TESTS.MD](TESTS.MD) §"TLINK linker regression test".
- `DOCS/BUILD.MD`, `DOCS/PORTING.MD`, and `CLAUDE.md`'s directory layout
  updated for the new mode/module/test.
