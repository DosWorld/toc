# Overlay support — design, format, and implementation

**Everything about this project's overlay feature lives here**: why it
exists, the on-disk `.OVR` format, the call-site trampoline mechanism,
the compiler/linker responsibilities, the runtime library
(`SRC/LIB/OVERLAY.MOD`/`OVERLAY.ASM`), and current implementation status.
This is this project's own scheme, designed and built for this
toolchain — the `$O+` directive and the `Overlay` module's public
interface are original to this project, not a port of any external
tool's ABI.

---

## 1. The problem overlays solve

MS-DOS real mode gives a program roughly 640 KB total, and every loaded
procedure's code occupies memory for the program's whole lifetime whether
or not it's currently running. **Overlays** let infrequently-used code
(a help screen, a rarely-used report generator, …) live on disk (or in
expanded memory) and be loaded into a shared buffer **only while it's
executing**, evicting other overlaid code as needed. The tradeoff is a
runtime cost (loading a swapped-out module takes disk/EMS I/O) in exchange
for a much smaller resident footprint.

This is fundamentally different from ordinary linking: an overlay's code
does not have a fixed load address. **Every call into overlay code must
go through an indirection that can load the code first if it isn't
already resident.**

## 2. Scope

**`/CD` (real-mode MZ) only.** `/CP` (DPMI16) is unaffected: a single
flag, `Link.State.targetCP`, makes `Link.CalculateLayout` clear every
module's `isOverlay` to `FALSE` unconditionally when linking `/CP`, so
every overlay-aware branch in `LINK.MOD` (the core shared by both
targets) is dead code on that path regardless of any `$O+` in the source
— confirmed by rebuilding `TOC286.EXE` (self-hosted, `/CP`) clean with no
overlay-related effect. `LinkNE.MOD` itself is untouched; only
`LinkMZ.MOD`/`LINKOVR.MOD` ever act on `isOverlay=TRUE`.

Extending to DPMI16 would need its own vector-hooking mechanism (a
real-mode `INT` vector isn't directly reachable from protected mode the
way `IntrDpmi`'s `INT 31h/AX=0300h` "simulate real mode interrupt" is) —
not planned unless a concrete need arises.

## 3. The three cooperating pieces

| Piece | Responsibility |
|---|---|
| **Compiler** | Marks which procedures/modules are overlaid; at every call site into overlay code, emits a **patchable trampoline** (fixed-size, in-place-rewritable bytes) instead of an ordinary call |
| **Linker** | Lays out overlay modules in the special **overlay file format** (a standalone `.OVR` file) instead of placing them in the main executable image; resolves the header records' offsets |
| **Runtime library** (`SRC/LIB/OVERLAY.MOD`/`OVERLAY.ASM`) | Owns the shared overlay buffer, the interrupt-trap handler that intercepts a trampoline hit, the load/evict/patch logic, and (optionally) EMS-backed storage instead of disk |

None of column 3 works without columns 1 and 2 already agreeing on the
trampoline shape and the file format — both are specified below.

### Why this compiler's model needs less machinery than a general scheme

Two structural facts about this compiler make some overlay-support
machinery unnecessary here:

**A far call and a resident trampoline are the same size.** `CgCallFar`
(`CGEN.MOD`) emits `9A imm16 imm16` — `CALL FAR seg:ofs`, 5 bytes. The
trampoline's resident form (§5) is `EA imm16 imm16` — `JMP FAR`, also 5
bytes. So an overlay call site needs no extra reserved space beyond what
an ordinary far call already has.

**No FAR-forcing mechanism is needed.** A scheme where NEAR calls are
possible on the call stack would need to force every such procedure to
FAR, because a NEAR return address can go stale if an *intervening*
module's code segment moves. This compiler's model sidesteps the whole
category: every module compiles into its own, separate CODE segment, and
a NEAR call/return pair is only ever emitted for a same-module target
(`PEXPR.MOD`'s call-dispatch logic — an imported symbol is always
exported, and export already forces FAR). An overlay swap only ever
replaces a *different* module's segment, so a NEAR pair's only
correctness requirement — "CS is unchanged between call and return" —
holds by construction. No build-wide flag, no call-graph pass.

Module data (`VAR`s) already survives a code swap for free: BSS is one
combined, permanently-laid-out region separate from CODE (`DOCS/RDOFF2.MD`
§5.1/§6.1) — evicting and reloading a module's CODE never touches it.

## 4. `$O+` — marking a module overlay-eligible

- **`{$O+}` on a module** marks it overlay-*eligible* at compile time.
  This is the `"O"` case of `PARSER.MOD`'s existing
  `ApplyToggle`/`ProcessToggleChain` directive machinery (the same
  mechanism `$D`/`$R` already use), tracked via `PExpr.overlayMode`.
  Module-level granularity, matching this compiler's one-module-one-`.rdf`
  model.
- **This compiler currently collapses eligibility and actual-overlay
  selection into one fact**: any `$O+` module that is `used` by a given
  link is unconditionally routed into the `.OVR` file. There is no
  separate per-link opt-in selection list — a module compiled `$O+`
  cannot currently be linked resident in one program and overlaid in
  another. `Link.CalculateLayout` reads `Module.isOverlay` straight from
  the `.om`'s own `.OVR` member.

**An `$O+` module may not have a `BEGIN` block — this is a compile-time
error, not a convention.** A module's own init body, if it has one, would
be called through the SAME `INT 3Fh` trampoline mechanism as any other
overlay entry point — not specially exempted — and doing so before
`Init` has run would crash. Giving an `$O+` module no init code at all
removes that failure class by construction: with no body, an `$O+`
module has no init code any caller could ever reach before `Init` runs,
regardless of import order. The program calls
`Overlay.Init`/`OvrSetBuf` explicitly, wherever its own author chooses —
no dedicated init-only module or import-ordering convention is needed.

Every RESIDENT module's own init — including one reachable only
transitively through an `$O+` module's own imports, never named by the
entry program itself — still runs eagerly at program startup, exactly
once regardless of how many places import it. This compiler achieves
that by walking the full transitive import graph from the entry module
(`TOC.MOD`'s existing dependency scan, `ScanDeps`, already builds this
graph for build-ordering purposes), recursing through `$O+` nodes
without calling them but still descending into their own imports,
collecting every resident module name reached. That flat list is merged
into the entry module's own `__init`-call codegen (`Parser.
parserExtraInits`, appended onto `PARSER.MOD`'s existing `initImpsHead`
list right after the entry module's own IMPORT clause is parsed) — the
existing `CgCallFar` loop then calls each one exactly as it already does
for a direct import. No new codegen path, no new file format. A name
reached more than once is harmless — the callee's own guard word absorbs
the redundant call. A non-entry module's own `__init` is unchanged: it
still only calls its own direct imports, skipping any import that is
itself `$O+` (which has none).

`EXAMPLES/OVRDEMO/OVRMAIN.MOD` calls `Overlay.Init`/`OvrSetBuf`
directly in its own body.

## 5. The call-site trampoline

At an ordinary call site, the compiler emits a normal `CALL FAR`. At a
call site into overlay code, it instead emits a **5-byte patchable
slot**, which starts life as:

```
CD 3F  id  entryOfs:WORD     ; INT 3Fh ; db id ; dw entryOfs
```

- `CD 3F` — `INT 3Fh`, hooked once at `Init` time via `SYSTEM.ASM`-style
  interrupt-install machinery.
- `id` — a 1-byte **global entry id**, resolved (via the `.OVR` file's
  own directory, §7.1) to the **segment**: which overlay module owns the
  call target, and where that module's on-disk header lives. It is a
  lookup key, not the call target's address — the address isn't known
  yet, because the module isn't loaded. Resolving `id` is what tells the
  runtime WHICH module to load/make resident.
- `entryOfs` — the **offset** where the specific entry point starts
  inside that module's own loaded code blob (a module's code is one
  contiguous region; different exported entry points do not all start
  at offset 0 within it). The linker writes the entry's real in-module
  offset here at link time (`Link.PatchOverlayCallSite` in
  `SRC/TOC/LINK.MOD`), so resolving a trapped trampoline is always a
  direct two-step segment:offset lookup, never a separate table read.

Once the interrupt handler has loaded the target module and it becomes
resident, the SAME 5 bytes are **rewritten in place** to:

```
EA  offset:WORD  segment:WORD   ; JMP FAR immediate seg:off
```

— a direct far jump straight to the now-loaded code, so every
*subsequent* call to that same overlay entry point (from this call site)
costs nothing: no trap, no lookup, just the jump. If the module is later
evicted to make room for another one, the runtime rewrites the site back
to the `INT 3Fh` form so the next call re-triggers loading. This is why
the compiler reserves exactly 5 bytes at every such call site (enough
for the `JMP FAR` form) even though the swappable form only needs 2.

**A trampoline is also installed at a call's own RETURN address, not
only at the call site — see §9, "Cross-overlay calls."** When an
overlay module's code is evicted while it is still active on the call
stack (a nested call into a different overlay module needed the space),
the return address the evicted module's caller left behind must itself be
a real, independently loadable overlay entry point with its own
distinct global id — not a raw code address, which would fault if the
caller's module isn't currently resident when the callee returns.

**A call site that compiles like any other far call.** A call site that
might target an overlay procedure compiles exactly like any other far
call (`Cgen.CgCallFar`, unchanged) — no new codegen entry point, no new
RDOFF2 record type (`RDFREC_RELOC` already carries an `importId`). The
new work is entirely in the linker: when a reloc's target module is
`.OVR`-eligible, `Link.OnReloc` overwrites the full 5-byte call site
(`9A` → `CD 3F id entryOfs`) instead of patching the two operand words
the normal way (`Link.PatchOverlayCallSite`). `IsInitTarget` excludes
calls to `__init` from this rewrite — moot in practice now that an `$O+`
module has no `__init` to call in the first place, but still relevant
for an ordinary FAR call to another module's `__init` (from the
dep-init chain) not being mistaken for an overlay entry-point call.

**The SEGRELOC paired with every `CALL FAR`'s segment operand must be
suppressed for a rewritten call site.** `CgCallFar` always emits both a
`RELOC` (offset word) and a `SEGRELOC` (segment word) for the same call.
When `Link.OnReloc` rewrites the site into a trampoline, the paired
SEGRELOC — arriving separately, unaware of the rewrite — must not patch
over the `entryOfs` bytes the rewrite just wrote. `Link.IsOverlayImport*`
(mirroring `OnReloc`'s own overlay-call test) lets `LinkMZ.OnSegReloc`
recognize and skip that specific SEGRELOC.

Marking which exported procedures are real overlay entry points (vs.
ordinary internal helpers) falls out of `$O+` plus export-star at each
`PROCEDURE` declaration — the resulting list goes into the module's `.OVR`
member, link-time bookkeeping that never touches `.def`.

## 6. The per-segment header record

Every overlay module, as stored in the overlay file, begins with a small
fixed header, immediately before that module's code. The on-disk header is
8 bytes.

| Offset | Size | Meaning |
|---|---|---|
| `+0x00` | WORD | Byte length of this module's *internal* fixup table (§7) |
| `+0x02` | WORD | Byte length of this module's *cross-module* fixup table (§7) |
| `+0x04` | WORD | Byte length of this module's code, as stored on disk/EMS |
| `+0x06` | WORD | Count of entries in the call-site patch table (§8) |
| `+0x0E` | WORD | Runtime-only: segment this module is currently loaded at, or 0 if not resident (not stored on disk) |
| `+0x10` | WORD | Runtime-only: nonzero while a call into this module is actively in progress (prevents eviction mid-call) |
| `+0x12` | WORD | Runtime-only: next-pointer, linking all currently-resident modules into one list |

## 7. Fixup tables (self- and cross-module relocation)

A module's code is compiled assuming *some* load segment, but the actual
segment it lands at varies from run to run (whatever's free in the
shared buffer at the time). The **internal fixup table** is a list of
2-byte offsets *within the module's own code* where a segment-sized value
needs adjusting by adding the module's own actual load segment — applied
by the overlay loader at runtime, not by the main linker at link time.

**A second table is needed beyond the internal one.** Every reference an
overlay module's code makes to a RESIDENT module — a call to an imported
procedure, a load of that module's own data segment — is baked by the
linker as a paragraph number relative to the WHOLE PROGRAM's own load
segment, exactly like any ordinary main-image reference. For a
main-image call site, the DOS MZ loader's own relocation table adds the
real load segment automatically, once, at program load. **A standalone
`.OVR` file is never touched by that loader at all** — nothing else was
ever adding that correction, so without a fix every such reference
silently pointed short of its real target, landing wherever happened to
be at that wrong address. The **cross-module fixup table** is the
runtime-applied fix: the same offset-list shape as the internal table,
but each entry gets the PROGRAM's own load segment
(`Overlay.LoadSegment()`) added instead of the module's own — a different
addend, so a separate table (`Overlay.ApplyXFixups`, paired with the
existing `Overlay.ApplyFixups` for the internal table).

## 8. Call-site patch table

A list of **far addresses to patch**, one per external call site that
targets an entry point inside this module. This is what lets the loader
find and rewrite every call site pointing at a module, both when making it
resident (patch to `JMP FAR`) and when evicting it (patch back to
`INT 3Fh`).

## 9. Cross-overlay calls

**The problem.** The trap handler's `inUse` field (`ModuleHeader.inUse`)
exists so the eviction loop never evicts a module mid-call. If module A
(resident, running) calls module B (also overlaid, not resident), B's own
trap fires as an ordinary nested call from A's point of view — nothing
distinguishes "the caller is itself an overlay module," so naive eviction
could throw out A while it's still on the stack waiting for B to return.

**Design requirement.** A caller whose code is evicted mid-call needs to
be reloadable and resumable correctly: the return address left on the
stack must itself be a real, independently loadable overlay entry point
— not a raw code address, which would fault if the caller's module weren't
resident when the callee returns. This calls for installing a SECOND
trampoline at the call's own RETURN ADDRESS, with its own distinct
global entry id, separate from the module's normal public entry points.

**What was built:**

1. **Call-site owner tagging (`Link.OvrSiteNodeRec.ownerGlobalId`).**
   `AddOvrSite` tags every call-site record with `OvrNoOwner` (site
   lives in the main resident image, `siteFileOfs` absolute from the
   program's own load segment — the ordinary case) or the CALLING module's
   own `ovrEntryIdBase` (site lives inside another `.OVR` module's own
   code, `siteFileOfs` relative to that module's own code origin).
   `Overlay.PatchSitesForModule` resolves the owner via
   `DirEntry`/`RegisterModule` at patch time to find the current
   `residentSeg` for a non-main-image site.
2. **Return-address trampoline emission (`Link.AddOvrReturnTrampoline`).**
   For a call site living INSIDE overlay code (`lnkMod^.isOverlay`),
   `OnReloc`'s existing call-site rewrite is followed by installing a
   SECOND `INT 3Fh` trampoline under a FRESH global entry id at the byte
   range immediately after the call site's own 5 bytes — new code, not a
   reuse of the caller's own entry-id assignment (`Module.ovrEntryIdBase`),
   since a return-address id must be independently loadable and resolve
   to "resume the caller's own module," not to any of the caller's own
   real public entry points.
3. **Reserved padding, not clobbered caller code
   (`Cgen.CgCallFarOvr`).** `PEXPR.MOD`/`PSTMT.MOD`'s far-call codegen
   (both statement-level AND expression-level call sites, see the
   `PSTMT.MOD` note below) reserves 5 bytes of `NOP` padding immediately
   after any imported far call made from `$O+` code, via
   `Cgen.CgCallFarOvr` (codegen can't know yet whether the call's target
   will resolve to an overlay module — only the linker knows that, much
   later — so the padding is reserved unconditionally and stays dead NOP
   if the call turns out to target a resident procedure).
   `AddOvrReturnTrampoline` installs its trampoline into that padding
   and records the jump target as `retOfs+5` (one past the padding,
   where the caller's real, untouched continuation code begins), not
   `retOfs` itself.
4. **`.OVR` format: resume table.** Each module's on-disk layout has a
   `resumeCount` header field and a resume-point table (6-byte records:
   `ofs, globalId, calleeGlobalId` — §11), alongside the existing
   call-site table. `Overlay.ResumeCallee` looks up a trapped id against
   a module's own resume table to distinguish "this is a real public entry
   point" (start a fresh call) from "this is a synthetic return-address
   resume point" (continue the caller's own code, and `DEC` the
   returning callee's `inUse`).
5. **ASM-side resume-vs-call branch (`OVERLAY.ASM`).** `Overlay.
   OvrDispatch` has a third `VAR isResumeOut: WORD` out-parameter so
   `Ovr_TrapEntry` can tell the two cases apart. An ordinary call trap
   synthesizes a CALL-FAR-shaped return frame (site+5) before jumping to
   the resolved target. A resume trap does NOT — it is not itself a call
   site standing in for anything; the callee's own `RETF` already
   consumed its real return frame before landing on the resume
   trampoline's bytes, so the stack is ALREADY in "ready to continue
   straight-line execution" shape. `Ovr_TrapEntry`'s resume branch
   discards its own interrupt frame (FLAGS/CS/IP — nothing downstream
   ever returns there) and does a plain far jump to the resolved target;
   pushing a synthetic return frame on top (the ordinary-call codepath's
   behavior) would insert a bogus return address underneath the real
   caller's own frame, corrupting the stack the first time the resumed
   code's own eventual `RETF` fires.

**A real bug found and fixed getting here (`PSTMT.MOD` gap).**
`PEXPR.MOD` (`ParseFactor`) and `PSTMT.MOD` (bare-statement procedure
calls, e.g. `Ovrdemo2.Run;` with no assignment/expression context) are
TWO separate far-call codegen sites — only `PEXPR.MOD`'s was gated on
`overlayMode` at first. A call reached only through `PSTMT.MOD`'s own
path got NO padding, so its resume trampoline silently clobbered real
caller code again despite the padding mechanism existing. Found via
byte-level inspection of the resumed code showing execution landing
mid-instruction (skipping a `PUSH` the true statement needed). Fixed by
mirroring the identical `isImp & isFr & overlayMode` gate in
`PSTMT.MOD`.

Verified end-to-end against `EXAMPLES/OVRDEMO/OVRMAIN.EXE`: `Ovrmain` →
`Ovrdemo.Run` → `Ovrdemo2.Run` → resume back into `Ovrdemo`, correct
output, exit 0.

## 10. `inUse` and eviction-pressure — real per-call nesting

**The gap.** `OvrDispatch` originally did `INC(u^.inUse)` on every
ORDINARY entry trap and only ever `DEC` it from the matching resume trap
— a module's `inUse` flag stayed set for its ENTIRE activation, from the
moment it's called until the moment its own call returns. Combined with
"never evict a module whose `inUse≠0`," this meant a module could never be
evicted while it had an outgoing call in flight, by construction — the
exact window the return-address trampoline mechanism exists to handle.
This was a genuine gap in the eviction policy: a caller idle on the call
stack, waiting for a nested call to return, should be a safe eviction
candidate too.

**Design chosen: real per-call `inUse` nesting.** `OvrDispatch`'s
ordinary-entry path DECrements the CALLING module's own `inUse` (found via
`FindSiteOwner`, reading the same `ownerGlobalId` `Link.AddOvrSite`
already writes into every call-site record) the moment a fresh call
traps — modeling "caller goes idle the instant it makes an outgoing
call, not for its whole activation." The resume path re-INCrements
`u^.inUse` directly. This makes an idle caller genuinely evictable while
its own outgoing call is in flight.

An alternative considered was a stack-frame-walking approach: at
eviction time, scan the live call-stack frame chain for a frame whose
saved return segment matches the segment about to be reused, and patch
that frame's own return offset in place. This was rejected: (1)
unconditional stack-walking via `[bp]` is fragile; (2) it depends on
reusing the same segment NUMBER in place for an evicted-and-reloaded
module, which this project's bump/ring allocator does not guarantee (each
load can land at a different segment); (3) mutating live stack memory
from inside the trap handler is exactly the risk class `CLAUDE.md`'s "no
write access to `[cs:xxx]`" caution exists to flag. The simpler,
self-contained per-call `inUse` nesting design was implemented instead.

**A deeper bug this exposed, also fixed (resident redirect table).**
Once an idle caller became evictable, `Ovr_TrapEntry`'s baked hardware
return address (`site_seg:site_ofs+5`, `site_seg` being the caller's
resident segment AT CALL TIME) could go stale — confirmed via a 3-module
A→B→C regression where A was evicted while idle, C loaded into A's old
segment, and B's eventual return to A landed inside C's code instead.
Fixed with a small, PERMANENTLY RESIDENT `resumeTrapTable` (256 × 5-byte
`INT 3Fh <id> 00 00` slots) in `OVERLAY.ASM`/`OVERLAY.MOD`:
`AddOvrReturnTrampoline` (`SRC/TOC/LINK.MOD`) no longer patches physical
bytes into the caller's own overlay code — it only allocates a global id
and records `(ofs, globalId, calleeGlobalId)` on disk. `OvrDispatch`
computes `retSegOut`/`retOfsOut` (two VAR out-params, threaded through
`Ovr_DispatchStub`/`Ovr_TrapEntry` in `OVERLAY.ASM`), defaulting to the
old `site_seg:site_ofs+5` (unchanged for resident-caller calls) but
overridden to the resident table's own `seg:slot(resumeGlobalId)` for
cross-overlay calls (found via `FindResumeGlobalId`, the inverse of
`ResumeCallee`). When the callee's `RETF` lands on that resident slot,
it re-traps via `INT 3Fh`, and `OvrDispatch` re-resolves the caller's
CURRENT resident segment fresh every time — it can never go stale, since
the resident table's own segment never moves. `PatchTrampoline` is
skipped entirely for resume traps, since the resident slot must stay a
permanent `INT 3Fh` (patching it to `JMP FAR` would break every FUTURE
resume through that slot, since the caller's segment can differ call to
call).

**Three more real bugs found and fixed while bringing this up:** a
linear-address (not field-by-field) comparison bug in `FindSiteOwner`
(real-mode seg:ofs pairs are non-unique per physical address — comparing
seg/ofs fields directly can miss a match that's the same physical
byte); a resident-table offset-0 assumption bug (`resumeTrapTable` does
not start at offset 0 of its segment — `installed`/`savedOfs`/
`savedSeg` precede it — fixed by adding `Overlay_ResumeTrapTableOfs`
alongside `Overlay_ResumeTrapTableSeg`); and a resume-offset-always-zero
bug (`ResumeCallee` never read back the resume record's own on-disk
`ofs` field, so every resume re-executed its caller from the start
instead of resuming mid-body — fixed by adding a `VAR resumeOfs: WORD`
out-param).

**A separate, unrelated bug found while setting up eviction-pressure
testing:** `LoadModule`'s ring-buffer wraparound reset the bump pointer to
`ovrHeapOrgParas` and treated that alone as "room found," without
checking whether a still-resident module already occupied that region —
confirmed silently overlapping live memory. Fixed with a new
`RegionFree` check (`OVERLAY.MOD`) that verifies genuine non-overlap
against every resident module's own occupied paragraph range, not just
the buffer's own outer end-of-buffer bound; `LoadModule`'s room-finding
loop now keeps evicting until BOTH the end-of-buffer bound and
`RegionFree` hold.

**Verification.** A 3-module eviction-pressure fixture
(`EXAMPLES/OVRDEMO/OVRA3.MOD` → `OVRB3.MOD` → `OVRDEMO3.MOD`, driven by
`OVRMAIN3.MOD`, `make run-eviction`) forces `Ovra3` to be evicted while
idle and `Ovrdemo3` to load into `Ovra3`'s exact old segment, then
confirms both `Ovrb3` and `Ovra3` correctly resume mid-body afterward.
The `inUse` gap is closed: eviction-and-reload-to-a-different-segment
works correctly for both the evicted module's own resume and any
further-nested caller's resume.

**Accepted trade-off, not reclaimed:** `Cgen.CgCallFarOvr`'s 5-byte
padding reservation after each overlay call site is now dead space for
its original purpose (the trampoline it used to reserve room for is no
longer patched there) but was deliberately left in place rather than
reverting that codegen change — reclaiming it would be a separate,
unrelated codegen change.

**A second real bug found while testing repeated evict/reload cycles
(2026-08-09, via `EXAMPLES/OVRDEMO/OVRMAINX.MOD`, `make run-clearbuf`):**
`Overlay_PatchTrampoline`'s resident-form write (`JMP FAR`, bytes
`+1..+4` = offset:segment) unconditionally overwrites bytes `+2..+4` —
the SAME bytes the swappable form uses for the entry id (`+2`) and the
entry's own in-module code offset (`+3..+4`, `ReadTrampolineEntryOfs`).
Once a site had been patched resident even ONCE, its original link-time
id/entryOfs bytes were gone for good: the next unpatch-then-reload cycle
(`OvrClearBuf`, or any ordinary eviction) read back garbage instead of
the real entryOfs, computing a bogus jump target and crashing (confirmed
via `xt trace`: `RETF` landed at `CS:IP` equal to the stack segment
value, i.e. it jumped using leftover `targetSeg`/`targetOfs` bytes from
the PRIOR resident patch, decoded as an entry offset). Every other
fixture in this directory only ever loads each module ONCE per run, so
this was invisible until a test deliberately exercised a second
load/evict cycle on the same site.

Fixed with a small per-module cache (`OVERLAY.MOD`'s `EntryOfsNodeRec`,
chunked per CLAUDE.md's "Chunk small records" rule): the first time
`PatchSitesForModule` patches a given `entryId` to resident form, it reads
`entryOfs` from the (still-pristine) trampoline bytes as before, but
also caches `(entryId, entryOfs)` on the `ModuleHeader`; every later patch
of any site sharing that `entryId` — resident OR swappable-restore —
uses the cached value instead of re-reading the trampoline bytes, which
can no longer be trusted once any resident patch has touched them.
`Overlay_PatchTrampoline`'s swappable branch was also changed to WRITE
the full 5 bytes explicitly (`INT 3Fh`, entry id, entryOfs) rather than
writing only bytes `0`/`1` and assuming `2..4` survived untouched — the
Oberon side now passes `(entryId, entryOfs)` through the same two
parameter slots the resident branch uses for `(targetSeg, targetOfs)`.
Verified via all six `EXAMPLES/OVRDEMO` fixtures (§18) passing from a
genuinely clean rebuild, including the new `OVRMAINX.MOD` regression
this bug was found through.

## 11. The overlay file format

This project's own `.OVR` file format — a standalone file written by the
linker, produced only for `/CD` links.

### 11.1 The `.OVR` directory format

The **contract** between the compiler/linker (`LINK.MOD`'s opcode-rewrite
+ table-emission machinery, `SRC/TOC/LINKOVR.MOD`'s writer) and the
runtime (`OVERLAY.MOD`'s reader). Both sides must agree on it exactly;
this section is the authoritative description, and `LINKOVR.MOD`'s own
header comment mirrors it.

**Entry ids are GLOBAL, not per-module.** §5's trampoline carries a single
id byte, and the trap handler has no second byte identifying *which
module* — so ids must be unique across the whole program. The linker
assigns them as one running counter over every overlaid module's own
entry points, in link order. This bounds a program to **at most 256
overlay entry points in total** (a direct consequence of the 1-byte
trampoline id field) — the linker reports a fatal error if that's
exceeded.

**`codeLen` widened from WORD to LONGINT (2026-08-11).** A single
overlay module's compiled code was originally capped at 65535 bytes by
this field's own width, with **no overflow check anywhere in the
linker** — a module whose real code exceeded that limit had its
`codeLen` silently truncated at link time, so the runtime copied only
the truncated byte count while the module's actual (larger) code still
ran, off the end of what was actually loaded, into whatever memory
happened to follow — a garbage jump / infinite loop with no diagnostic
at all. Found via `SRC/TASM/TURBODIR.MOD` (the largest `$O+` module
built so far, ~2600 lines, already at the ordinary 65000-byte
`Rdoff.SegLimit` ceiling once split out of `TURBO.MOD`) hanging under a
real workload. `codeLen` is now a 4-byte field (module header grows from
10 to 12 bytes, see below); `Files.BlockRead`/`EMS.CopyToDos`'s own
single-call length parameters stay `WORD` (a genuine DOS/EMS API limit)
and are narrowed explicitly at the call site — safe because
`Rdoff.SegLimit` already keeps any one module's real code under 65535
bytes, so this widening is a robustness fix (a genuine overflow now
fails loudly via `Files.BlockRead`'s own short-read check) rather than
something that raises the practical per-module code ceiling.

```
Offset 0:  "DW" + 6 reserved bytes           (OvrHeaderSize=8)
Offset 8:  entryIdCount: WORD                (one past the highest global id used)
Offset 10: directory[entryIdCount]: LONGINT  (each slot: byte offset of
                                               the OWNING module's header,
                                               indexed directly by GLOBAL
                                               entry id -- every entry id
                                               belonging to the same module
                                               repeats that module's own
                                               header offset)

Then, back-to-back, one per module (each written once, regardless of how
many of its own entry ids point at it):

  module header (12 bytes -- the on-disk subset of section 6's fields; the
               three runtime-only WORDs at +0x12/+0x14/+0x16 are never
               stored, since they have no meaning until a real load
               happens):
    +0x00 WORD    fixupLen   (byte length of the internal fixup table below)
    +0x02 WORD    xfixupLen  (byte length of the cross-module fixup table
                              below, section 7)
    +0x04 LONGINT codeLen    (byte length of the code -- widened from
                              WORD 2026-08-11, see below)
    +0x08 WORD    siteCount  (entry count of the call-site table below)
  fixup table:     fixupLen/2 WORDs (each an in-code byte offset, section 7:
                    internal/self-referencing entries, this module's own
                    load segment added)
  xfixup table:    xfixupLen/2 WORDs (each an in-code byte offset, section
                    7: cross-module entries, the PROGRAM's own load
                    segment added)
  call-site table: siteCount * (siteFileOfs: LONGINT, entryId: WORD,
                    ownerGlobalId: WORD) -- 8 bytes/entry; entryId is the
                    GLOBAL id, matching the trampoline's own id byte.
                    ownerGlobalId = 0xFFFF (no owner): siteFileOfs is the
                    5-byte trampoline site's byte offset within the final
                    .exe's load image, relative to the start of the CODE
                    region (not counting the MZ header's own bytes) -- the
                    ordinary case, a resident module's own call site.
                    ownerGlobalId = some other module's own first entry id
                    (section 9's "cross-overlay calls" -- the call site
                    itself lives inside THAT module's own code):
                    siteFileOfs is instead relative to the owning module's
                    own code origin, and the runtime resolves ownerGlobalId
                    back to a ModuleHeader (the same directory lookup an
                    ordinary trampoline hit already does) to find its
                    current load segment before adding siteFileOfs
  resumeCount:     WORD, count of entries in the resume table below
  resume table:    resumeCount * (ofs: WORD, globalId: WORD,
                    calleeGlobalId: WORD) -- 6 bytes/entry, section 9's
                    cross-overlay-call resume points
  code:            codeLen bytes

[... repeated per module ...]

Trailing (at end of file, after the last module's code):
  totalLength: DWORD   -- the WHOLE .OVR payload's own byte length,
                          INCLUDING this trailing field itself (so
                          fileSize - totalLength = the payload's own
                          start offset -- 0 for a standalone file, the
                          appended-to-EXE offset when appended, section 12)
```

Every field the runtime needs to identify a trapped call site's target
module is reachable in two direct table lookups: `directory[globalId]`
gives the module's header offset; the header there gives
`codeLen`/`fixupLen`/`xfixupLen`/`siteCount` to read the rest. The
trailing length field lets `DetectFormat` locate the payload by seeking
backward from end-of-file, working identically whether the file is a
standalone `.OVR` or an overlay payload appended to an `.EXE`'s own tail
(§12).

### 11.2 `.OVR` archive member (`MODNAME.OVR`)

A `key=value` text file living inside the `.om` archive alongside the
module's `.RDF`/`.DEF`/`.DBG` members (8.3 uppercase), `;`-comments
allowed:

```
OVERLAY=1
ENTRYCOUNT=3
ENTRY0=OvrDemoInit
ENTRY1=OvrDemoRun
ENTRY2=OvrDemoDone
```

Written by `PARSER.MOD` at the point an `$O+` module finishes compiling.
Read by `LINK.MOD` wherever it resolves a reloc's target symbol, to
decide whether that symbol's owning module is overlaid. Carries
module-level facts only (eligibility, entry points); deliberately kept
out of `.def`, which every import resolution depends on and has no need
to see a link-time-only fact.

## 12. Appended-to-EXE overlay file format

The linker itself only ever writes the standalone `.OVR` file
(`LinkOvr.WriteOvrFile`) — appending it onto an `.EXE`'s own tail is a
manual step the USER performs afterward (e.g. DOS
`copy /b PROG.EXE+PROG.OVR PROG.EXE` — see `EXAMPLES/OVRDEMO/Makefile`'s
own `OVRAPPT.EXE` target for the automated equivalent), not a linker
switch or automatic behavior.

`OVERLAY.MOD`'s `DetectFormat` ALWAYS locates the payload backward from
end-of-file: seek to EOF-4, read the trailing self-length DWORD
`LinkOvr.WriteOvrFile` already writes (§11.1 — the whole payload's own
byte length, including that field itself), seek back that many bytes
from EOF, and validate the `"DW"` header found there. This is the exact
same procedure whether `ovrDosHandle` is a standalone `.OVR` file
(payload starts at byte 0) or an `.EXE` with that same payload
concatenated onto its own tail (payload starts wherever the trailing
length says) — no format-detection branching needed between the two
cases.

A module variable `ovrPayloadStart` tracks where the payload actually
begins in the real, opened file. `DirEntry`'s returned directory values
are relative to the PAYLOAD's own byte 0 (matching `LinkOvr.
WriteOvrFile`'s own write order, which always starts counting from its
own byte 0 regardless of where that payload later ends up) — `DirEntry`
adds `ovrPayloadStart` to turn that into a real `Files.Seek` target, so
every downstream consumer of `hdrFileOfs` (`ReadModuleHeader8`,
`codeFileOfs`, the resume-trampoline lookups, …) needs no change of its
own.

**Verified end-to-end**: `EXAMPLES/OVRDEMO/OVRAPPT.MOD` (`make
run-appended`) is byte-for-byte the same demo as `OVRMAIN.MOD` except it
opens its own `.EXE`'s name instead of a standalone `.OVR` file; the
Makefile appends `OVRAPPT.OVR` onto `OVRAPPT.EXE`'s own tail after
linking, and it runs with the exact same output as the standalone form,
confirming both code paths (`ovrPayloadStart = 0` and
`ovrPayloadStart > 0`) work through the identical logic.

**`/G` TDS debug info + an appended `.OVR` payload together: not
addressed, untested.** TDS's own reader (`SRC/TOOLS/TDINFO.MOD`) locates
its block by computing FORWARD from the MZ header's own image-size field
(it assumes it is the first thing right after the MZ image), not
backward-from-EOF like `.OVR`'s own reader. Appending an `.OVR` payload
AFTER a `/G`-built `.EXE`'s own TDS block (the only order that keeps
TDS's own forward-locate working at all) should be compatible in
principle — `.OVR`'s own reader always finds its payload via the true
EOF regardless of what precedes it — but nothing currently prevents,
warns against, or has been tested for this combination.

## 13. Runtime algorithm

### 13.1 `Init(FileName)`
Try opening `FileName` three ways (as given; searching each `PATH=`
directory; relative to the running program's own directory), stopping at
the first success. Read the file's own header (§11), store the DOS
handle. `OvrReadBuf` (a pluggable function pointer) is left pointing at
the plain-disk reader.

### 13.2 `OvrSetBuf(Size)`
Carves out `Size` bytes (clamped to at least some minimum) for the
overlay buffer. This toolchain's Oberon runtime has no "shrink the heap
ceiling" primitive a library module can call, so the overlay buffer is a
plain `SYSTEM.Alloc` block tracked independently (§14). Can only be
called before any overlay has actually been loaded.

### 13.3 The interrupt-trap handler (`INT 3Fh`)
1. Reads the return address off the interrupt stack frame to identify
   which trampoline slot fired, hence which module/entry-point was
   requested.
2. If that module is already resident (header `+0x10` ≠ 0): just mark it
   in-use (`+0x12`) and fall through to step 5.
3. Otherwise: run the **eviction loop** — walk the resident-module list,
   evicting not-currently-in-use modules (§13.4) until enough contiguous
   space is free for the new module.
4. Call `OvrReadBuf` to load the module's raw bytes into the freed space,
   apply its internal AND cross-module fixup tables (§7), then patch
   every call site in its call-site table (§8) from `INT 3Fh` to direct
   `JMP FAR` (§5), including the site that just trapped.
5. Return control directly to the resolved target. The handler resolves
   the target address itself (§14) — but does NOT simply `IRET` into it:
   `INT` pushes three words (FLAGS, CS, IP) where the trampoline's own
   `CALL FAR` would have pushed only two (CS, IP), so an `IRET` straight
   into the target leaves the stack one word short of what the target's
   own eventual `RETF` expects, popping garbage instead of a real return
   address. The handler instead synthesizes a genuine `CALL FAR`-shaped
   return frame (the real return address: the trampoline's own site,
   plus 5, i.e. the caller's next instruction) and reaches the target
   via `RETF` used as an indirect far jump (push target seg:ofs, `RETF`
   into it) — functionally equivalent to the target having been reached
   by an ordinary `CALL FAR` at the original site, so its own `RETF`
   returns straight to the real caller.

### 13.4 Eviction
Un-patch the evicted module's call sites back to `INT 3Fh` form, mark its
header `+0x10 := 0`, unlink it from the resident list, reclaim its heap
space. Never evicts a module whose `+0x12` in-use flag is set — a module
still active on the call stack, needing eviction to make room for a
nested call into a different module, is correctly reloaded and resumed
once space is available again, with no corruption (§10).

### 13.5 `OvrClearBuf`
Evicts everything, resets the overlay heap to empty. Requires `Init`
to have run.

### 13.6 `InitEMS`
Optional upgrade after `Init`: detects an EMS driver, computes total
overlay-file size by summing the (already-loaded) module headers, allocates
that many EMS pages, and swaps `OvrReadBuf` to point at an EMS-backed
reader instead of the disk reader. Everything in §13.3–§13.5 is
unchanged; only *how bytes get from storage into the overlay buffer*
differs. Also hooks the exit-procedure chain so the EMS pages are always
freed on program exit.

### 13.7 EMS-backed `OvrReadBuf`
Copies a module's bytes out of EMS a page at a time, maintaining a
persistent (page, offset) cursor per-module so a read that spans multiple
calls resumes correctly.

## 14. The runtime library (`SRC/LIB/OVERLAY.MOD`/`OVERLAY.ASM`)

`Overlay` is a normal stdlib module, built into `OBERON.OM` alongside
`Files`/`Out`/`EMS`/etc. — any program imports it with a plain
`IMPORT Overlay`.

Exported surface: seven procedures, seven `ovr*` constants, nothing
more: `Init`, `InitEMS`, `OvrSetBuf`, `OvrGetBuf`, `OvrSetRetry`,
`OvrGetRetry`, `OvrClearBuf`; `ovrOk`, `ovrError`, `ovrNotFound`,
`ovrNoMemory`, `ovrIOError`, `ovrNoEMSDriver`, `ovrNoEMSMemory`.

- **File-format detection and the three-way search** (§13.1) — `PATH`-
  searched, and relative to the running program's own directory.
- **`OvrSetBuf`/`OvrGetBuf`** (§13.2) — this toolchain's runtime has no
  "shrink the heap ceiling" primitive a library module can call, so the
  overlay buffer is a plain `SYSTEM.Alloc` block tracked independently
  rather than carved from a language heap. A second `OvrSetBuf` call
  (before any overlay is ever loaded) frees the previous block instead
  of leaking it; program exit frees it too.
- **`OvrClearBuf`** (§13.5) — walks the real resident-module list and
  correctly unpatches every site.
- **`InitEMS`/EMS-backed reads** (§13.6/§13.7) — built on `EMS.MOD`'s own
  page-mapped block copy, so no manual page-at-a-time loop or resume
  cursor is needed. The disk-to-EMS scratch buffer is 1 KB, not the
  16 KB EMS page size — a 16 KB stack local would overflow this
  project's 8 KB default `$M` stack.
- **Trampoline byte forms and vector install/remove** (§5, §13.3) —
  `Init` calls `OVERLAY.ASM`'s `Overlay_InstallHandler` to hook
  `INT 3Fh`, and installs a single exit-procedure hook that removes the
  trap handler and frees any EMS allocation.
- **Real per-module dispatch** (§13.3) — `Ovr_TrapEntry` (`OVERLAY.ASM`)
  identifies the trapped call site, calls `Overlay.OvrDispatch*`
  (Oberon), which reads the `.OVR` directory, registers/loads/evicts
  `ModuleHeader` records, applies both fixup tables (§7), and patches every
  call site targeting the loaded module — then `Ovr_TrapEntry` reaches the
  resolved target via a synthesized `CALL FAR`-shaped return frame and
  `RETF` (§13.3 step 5).
- **Eviction under real buffer pressure** — `TryEvictOne`/`LoadModule`
  implement "never evict a module whose `inUse≠0`" (§13.4), a deliberately
  simple eviction policy — sufficient for correctness, not a
  full-featured LRU/probation cache-replacement scheme. `inUse` tracks
  real per-call nesting (§10): a module is idle, hence evictable, the
  instant it makes an outgoing call, not for its whole activation.

**A same-module ASM-to-Oberon call.** `Ovr_DispatchStub` (`OVERLAY.ASM`)
calls `Overlay.OvrDispatch*` (Oberon) directly — a same-module extern
call, a supported pattern confirmed by the maintainer, not the
cross-`.rdf`-blob symbol-resolution limitation `EMS.ASM`'s own header
comment discusses for a different scenario.

**Why `OVERLAY.ASM` must be assembly, not Oberon.** An interrupt
handler's entry state (arbitrary caller registers/DS/stack, no prologue
run yet) cannot be expressed as an Oberon PROCEDURE — same reason
`SYSTEM.ASM`'s own `IntrReal`/`IntrDpmi` handlers are hand-written. The
trampoline patch write is a self-modifying-code write to a CALLER's
code, not this module's own — still bound by `CLAUDE.md`'s "no write
access to `[cs:xxx]`" rule: `Ovr_PatchTrampoline` writes through the
caller-supplied seg:ofs via an ordinary ES-relative store, never through
CS, so it is unaffected by that rule regardless of which segment happens
to hold the call site.

**Real-mode only.** No DPMI16 story exists (§2). If overlay support is
ever wanted under DPMI16, the vector-install/restore pair would need the
DPMI "Simulate Real Mode Interrupt"-adjacent `INT 31h` services for
hooking a REAL-mode vector from protected mode (`DPMI09.HTM` section 9,
"raw mode switch" / real-mode interrupt vector get-set, `AX=0200h`/
`0201h`) — a different mechanism than `IntrDpmi`'s own `AX=0300h`
"simulate a real-mode interrupt," which calls OUT to real mode rather
than hooking a vector for real-mode code to call IN through.

## 15. What this project already had that this design builds on

- `SYSTEM.Intr`/`SYSTEM_Intr` (`SRC/LIB/SYSTEM.ASM`) — the interrupt
  dispatch mechanism §13.3's trap handler needs.
- `EMS.MOD` (`SRC/LIB/EMS.MOD`) — `Alloc`/`Free`/`CopyToDos`/`MapPtr` at
  a higher level than raw `INT 67h`; §13.6/§13.7's EMS logic sits on top
  of this rather than reimplementing it.
- `RDOFF.MOD`'s `RDFREC_SEGRELOC` — conceptually the same self-relocation
  idea as §7's internal fixup table, just applied at link time instead
  of overlay-load time.
- `LINKMZ.MOD`'s pattern of appending the `/G` TDS debug block after the
  MZ image — the same append-past-the-image technique the appended-to-EXE
  overlay variant (§12) uses.

## 16. Implementation status

**Compiler/linker: done.** `$O+` directive parsing, the `.OVR` archive
member, the link-time opcode-rewrite path, per-module
header/fixup-table/call-site-table/resume-table emission, the
standalone `.OVR` file writer, and the entry-module
transitive-init-call generation (§4) are all implemented in
`SRC/TOC/LINK.MOD`/`LINKOVR.MOD`/`PARSER.MOD`/`TOCMAIN.MOD`.

**Runtime (`SRC/LIB/OVERLAY.MOD`/`OVERLAY.ASM`): done and verified
end-to-end** against all six `EXAMPLES/OVRDEMO` fixtures (§18) under
`xt` — real dispatch, load, fixup application (both tables, §7),
call-site patching, cross-overlay calls (§9), real eviction of an idle
caller mid-call including repeated evict/reload cycles on the same site
(§10), EMS-backed storage (§13.6/§13.7), `OvrClearBuf` mid-run (§13.5),
and the appended-to-EXE overlay file format (§12) all confirmed working,
correct output, clean exit, zero heap leaks. **Also verified on the
compiler's own real, non-fixture use** — `$O+` on `DEF.MOD`/`LINKNE.MOD`,
see below.

**Not implemented:**
- **DPMI16 (`/CP`)** — overlays are `/CD`-only (§2, §14).
- Whether this dialect's actual-parameter passing has a hazard analogous
  to "a string/set constant passed by pointer from code-segment-resident
  storage across an `$O+`-to-`$O+` call" is not yet audited against
  `PEXPR.MOD`'s literal-actual codegen path.
- ~~`$O+` on the compiler's own `DEF.MOD`/`LINKNE.MOD`~~ **DONE
  (2026-08-16) — see below.** Three rounds of investigation,
  2026-08-14 through 2026-08-16, the last two resolving what earlier
  looked like an `OVERLAY.ASM`-level bug:

  **Round 1 (2026-08-14/15): performance.** An initial apparent second
  crash ("bug #5") turned out to be a self-hosting bootstrap-generation
  lag, not a real bug — bug #4's fix (the `rseg = SegCode` guard in
  `LINK.MOD`'s `OnSegRelocOverlay`) is correct. But a real performance
  bug was found and fixed: `OVERLAY.MOD`'s `FindSiteOwner` did an
  unconditional `Files.Seek`+per-entry `Files.BlockRead` disk scan of a
  module's whole call-site table on every dispatch, even for calls that
  can never be cross-overlay. Fixed with a one-line in-memory range
  check (a cross-overlay call site's `siteSeg` can only fall inside the
  shared overlay heap buffer) — landed permanently.

  **Round 2 (2026-08-15/16): the SAME performance bug, more completely.**
  The round-1 fix did not fully resolve the issue — dispatch cost still
  scaled with table size (`O(dispatches × siteCount)`), just via a
  different mechanism: `FindSiteOwner`, `PatchSitesForModule`,
  `ResumeCallee`, and `FindResumeGlobalId` all independently re-read a
  module's call-site/resume tables from disk on every dispatch, not just
  the cross-overlay-match case. Fixed by caching both tables in memory
  once, at `RegisterModule` time: `SiteNode`/`ResumeNode` chunked records
  (mirroring the existing `EntryOfsNodeRec` pattern, CLAUDE.md "Chunk
  small records"), populated by new `LoadSiteCache`/`LoadResumeCache`
  procedures, with all four consumers above switched to read the
  in-memory copy. Verified via isolated `xt` reproducers: a 30-call-site
  module's dispatch cost dropped from ~8-9M instructions per 300 calls to
  ~2.5-3M, and scaling to 3000 calls stayed linear (~20-30M) rather than
  compounding — confirming the fix, not just moving the constant. Also
  fixed a related pre-existing leak while touching this code:
  `FreeModuleList` never disposed `entryOfsCache`'s (or the two new
  caches') own chunk chains, only the top-level `ModuleHeaderDesc`.
  **This fix is landed and is real** — `SRC/LIB/OVERLAY.MOD`'s
  `LoadSiteCache`/`LoadResumeCache`/updated `FindSiteOwner`/
  `PatchSitesForModule`/`ResumeCallee`/`FindResumeGlobalId`/
  `FreeModuleList`.

  **A second, independent correctness bug found and fixed the same
  round:** `Def.DefWrite`'s own `WHILE sym # Syms.NoSym DO` symbol-table
  walk hung forever (not slow — a genuine infinite loop over garbage
  memory) the first time `$O+` was actually exercised end-to-end via real
  self-hosting (as opposed to the small `EXAMPLES/OVRDEMO/` fixtures,
  none of which exercise a resident module reading another resident
  module's exported VAR from inside `$O+` code). Root cause: `Def`'s
  reference to `Syms.NoSym` (an exported VAR in the resident `Syms`
  module, read as a comparison sentinel) needs a SEGRELOC to resolve
  `Syms`'s own DATA segment at runtime. `LINK.MOD`'s `OnSegRelocOverlay`
  — used only for overlay modules' own relocations — patched the
  correct, link-time-fixed *value* into `Def`'s DATA image (via
  `PatchDataFile`) but never registered the ordinary MZ loader-relocation
  entry that value still needs, unlike `LinkMZ.OnSegReloc`'s identical
  case for a *resident* module's same reference, which does call
  `AddReloc` unconditionally. Since `Def`'s own DATA (unlike its CODE)
  stays in the main image and IS covered by the DOS loader's own
  relocation table (§3's "module data already survives a code swap, for
  free" foundation), skipping that registration left the baked segment
  value permanently un-adjusted by the real load segment — `Syms.NoSym`
  resolved to a non-NIL, effectively random value from `Def`'s own
  compiled code, so the loop's own termination check
  (`sym # Syms.NoSym`) never matched, looping forever over whatever
  garbage the wrong address happened to hold.  **Fixed** in `LINK.MOD`:
  `ProcessOverlayModule` now threads the real target's `segRelocProc`
  (`LinkMZ.OnSegReloc` for `/CD` — overlays are `/CD`-only regardless)
  through to `OnSegRelocOverlay`, which delegates to it whenever the
  patch site is in the module's own DATA (not overlay CODE) and the
  reference target isn't the module's own overlay CODE either (that one
  remaining case has no real link-time segment at all and correctly
  keeps the internal-fixup-table path). A locally-declared `PROCEDURE`
  type was needed for the `VAR`-held `segRelocProc` value, since
  `Rdoff.RelocProc` loses its formal parameter list crossing the `.def`
  boundary (`.def`'s `TYPE ... PROC` record carries no signature) —
  confirmed directly via `RDFGREP.EXE om-extract` on the compiled
  `.def`; an ordinary PARAMETER of the same type works fine since its
  signature comes from the current file's own fresh parse, never
  round-tripped through a `.def`.

  **Round 3 (2026-08-16): RESOLVED — two real bugs, neither in
  `OVERLAY.ASM`.** The session that first isolated Round 3's crash to
  `OVERLAY.ASM`'s `Ovr_TrapEntry`/`Ovr_DispatchStub` (see the git history
  for that investigation's own detailed notes — the crash signature,
  canary probes, and manual push/pop re-derivation described there were
  all real observations) never got to a hardware-level debugger or
  maintainer sign-off on `OVERLAY.ASM` before the actual root causes
  were found completely outside that file, by re-verifying the whole
  bootstrap methodology from scratch:

  1. **`TOC.MOD`'s `SetupOvr` called `Overlay.WarmModuleCaches` BEFORE
     `Overlay.OvrSetBuf`.** `OvrSetBuf` refuses to (re)size the overlay
     heap buffer once `ovrLoadList # NIL` (its own "don't resize an
     in-use buffer" guard — see `OvrSetBuf`'s header comment) —
     `WarmModuleCaches` populates `ovrLoadList` via `RegisterModule`, so
     calling them in this order left `ovrHeapOrgParas`/`ovrHeapEndParas`
     at `0` for the whole run: `OvrSetBuf`'s own call silently no-op'd
     through that guard. The first real `LoadModule` call then always
     failed its own `needParas > buffer size` check (with
     `heapOrg=0 heapEnd=0`), surfacing as `SYSTEM.Halt(209)` — a
     different, cleaner failure than Round 3's "Invalid opcode" crash,
     which is what first exposed that the two investigations had never
     actually been testing the same binary (see point 3). **Fixed** by
     swapping the two calls' order in `SetupOvr`.
  2. **`Overlay.OvrDispatch` called `CacheEntryOfs` unconditionally on
     every dispatch, with no dedup.** `CacheEntryOfs` itself has no
     "already cached" check — it always appends a fresh
     `(entryId, entryOfs)` slot (see `EntryOfsNodeRec`, `EntryOfsChunk`
     = 8 entries/chunk). A module called repeatedly through the same
     entry point (this file's own §9 already documents the
     "`Def.DefWrite` once per compiled module — structurally a loop"
     case) therefore grew `entryOfsCache` by one entry per dispatch,
     forever, for the life of the process — a real unbounded heap leak,
     not a false-positive leak-guard artifact. Confirmed via direct
     instrumentation: self-hosting reported "heap leak ... in
     Cgen.CgFree() (5 paragraphs)" on whichever source file happened to
     be compiling when the 9th (then 17th, ...) chunk-overflow `NEW`
     landed. **Fixed** by gating the call on the existing
     `CachedEntryOfs` lookup first — `IF ~CachedEntryOfs(...) THEN
     CacheEntryOfs(...) END` — restoring the cache to its intended
     "each distinct entryId costs one node, once" shape. (A companion
     fix moved `RegisterModule`'s own one-time `entryOfsCache` chunk
     `NEW` to registration time instead of on-first-`CacheEntryOfs`,
     mirroring the existing `WarmModuleCaches`-before-baseline pattern
     for `siteCache`/`resumeCache` — otherwise a module's FIRST dispatch
     still paid that one-time cost inside whatever source file's
     leak-guard window happened to be open, the exact "WHEN, not IF"
     false-positive `WarmModuleCaches`'s own header comment already
     describes for the module-list-registration cost.)
  3. **The real methodology bug that let Round 3's crash go unexplained:
     the two-generation bootstrap this feature needs was not being
     followed consistently.** Enabling `$O+` on `Def`/`LinkNE` requires
     building in two passes — gen1 with `Def`/`LinkNE` at `$O-` and
     `SetupOvr`'s call to `Overlay.Init` commented out (so `_TOC.EXE`,
     the binary that does the compiling, is itself safe to run and
     behaves as a pure linker), then gen2 from that `_TOC.EXE` with
     `$O+`/`SetupOvr` restored, producing the real `TOC.EXE`+`TOC.OVR`
     under test. Multiple times during this investigation, `_TOC.EXE`
     was found to be nothing more than an unmodified copy of
     `BOOT/TOC.EXE` — meaning a "fixed" source tree was still being
     exercised through the OLD, unfixed linker logic. This was only
     caught by adding a throw-away debug print inside `LINK.MOD`'s own
     overlay-relocation handler and observing it never fired across
     several supposedly-fixed test runs.
  4. **A genuine DOS conventional-memory shortfall, once the above three
     were fixed.** Enabling real `$O+` overlay code inside `TOC.EXE`
     itself measurably grew the compiler's own runtime memory
     footprint — several build/test scripts that invoke the
     overlay-carrying `TOC.EXE` (or, for the compiler's own build step,
     `_TOC.EXE` compiling the larger `LINK.MOD`/`OVERLAY.MOD`-aware
     source) at the default or `--memkb=580` budget started failing
     with `oc: cannot create .def temp` / `oc: cannot create .dbg temp`
     — DOS out of handles/heap for the compiler's own temp-file
     machinery, not a compiler or overlay bug. **Fixed** by raising
     every affected `xt run --memkb=` to `640` (the real DOS
     conventional-memory ceiling): `SRC/TOC/Makefile`,
     `SRC/TASM/Makefile`, `SRC/TLINK/Makefile`, `SRC/TOOLS/Makefile`,
     `SRC/MD/Makefile`, `TESTS/Makefile.man`, `TESTS/test_tasm.sh`,
     `TESTS/test_tlink.sh`, `TESTS/test_selfhost_debug.sh`
     (`TESTS/test_selfhost.sh` already used 640 throughout).

  **`OVERLAY.ASM` was NOT the bug.** While investigating, `OVERLAY.ASM`
  was refactored to add `%define`/`%undef` symbolic BP-relative offsets
  to every procedure's parameters/locals (Pascal calling-convention
  clarity, at the maintainer's own request) and one genuine
  pre-existing-but-latent bug was fixed in passing —
  `Overlay_ReadTrampolineId` referenced undefined `ri_siteSeg`/
  `ri_siteOfs` symbols (never actually reassembled since whatever change
  first introduced that reference). The reassembled `OVERLAY.RDF` was
  verified **byte-for-byte identical** to the checked-in one (`make
  regen-asm` + `cmp`), proving the refactor changed no behavior and the
  calling convention itself was always correct — confirming Round 3's
  crash could never have been an `OVERLAY.ASM` bug in the first place.

  **Status: DONE.** `Def`/`LinkNE` are `$O+`, `TOC.MOD`'s `SetupOvr` is
  active (calls `Overlay.Init`, then `Overlay.OvrSetBuf`, then
  `Overlay.WarmModuleCaches`, in that order), and a full clean
  `make test` from `BOOT/TOC.EXE` (two consecutive independent runs)
  came back **311/311 manifest, 116/116 TASM, 14/14 TLINK, zero
  FAIL/ERROR lines, zero heap leaks** with this overlay code live
  throughout the entire build (`BOOT/TOC.EXE` bootstraps `TOC.EXE`
  itself, which then bootstraps every other tool). A full self-hosting
  compile+link+append cycle (`toc.exe /ENTRY=Run TOC.MOD /M` compiling
  its own ~26 modules) was independently verified gen2==gen3
  byte-identical for `TOC.EXE`, `TOC.OVR`, and every individual `.OM`.

Every implemented piece is independently testable and leaves
non-overlaid programs untouched — a program with no `$O+` module makes
every overlay-aware code path a complete no-op, so the existing manifest
and self-hosting byte-stability checks remain the regression gate.

## 17. Deliberate simplifications

- **No ring-buffer/probation/reprieve eviction algorithm** — this
  project's eviction rule is "never evict `inUse≠0`" (with real per-call
  nesting, §10), a simple and correct policy, deliberately not a more
  sophisticated LRU-with-probation buffer manager. `OvrSetRetry`/
  `OvrGetRetry` are present in `OVERLAY.MOD`'s exported surface but are
  currently no-ops against the simpler rule.
- **No `OvrReadBuf` hook, `OvrFileMode`, `OvrLoadCount`, `OvrTrapCount`**
  exposed as public variables — this project's own exported interface is
  deliberately minimal and keeps this internal.
- **No FAR-forcing mechanism** — not a simplification but a genuine
  architectural consequence of this compiler's own design (§3): its
  one-module-one-CODE-segment layout makes a whole caller-chain-wide FAR
  requirement moot.

## 18. Example programs and tests

`EXAMPLES/OVRDEMO/` — build/run harness (`Makefile`) plus fixtures:

- `OVRMAIN.MOD`/`OVRDEMO.MOD`/`OVRDEMO2.MOD` — 2-module standalone `.OVR`
  demo, `Ovrmain` → `Ovrdemo.Run` → `Ovrdemo2.Run` → resume (§9). `make
  run`.
- `OVRAPPT.MOD` — byte-for-byte the same demo as `OVRMAIN.MOD` except it
  opens its own `.EXE`'s tail instead of a standalone `.OVR` (§12). `make
  run-appended`.
- `OVRA3.MOD`/`OVRB3.MOD`/`OVRDEMO3.MOD`/`OVRMAIN3.MOD` — 3-module
  eviction-pressure regression (§10): forces `Ovra3` to be evicted while
  idle, waiting on the call stack for `Ovrb3.Run` to return, and a third
  module loads into its exact old segment. `make run-eviction`.
- `OVRMAINE.MOD` — byte-for-byte the same demo as `OVRMAIN.MOD` except it
  calls `Overlay.InitEMS` right after `Init`/`OvrSetBuf`, exercising the
  EMS-backed `OvrReadBuf` path (§13.6/§13.7) instead of the always-disk
  path every other fixture uses. `make run-ems`.
- `OVRMAINX.MOD` — calls `Ovrdemo.Run`, then `Overlay.OvrClearBuf`, then
  `Ovrdemo.Run` again, proving the second call re-traps and reloads
  correctly after a full evict-everything-and-unpatch (§13.5) — this is
  the fixture that found the entry-id/entryOfs corruption bug documented
  under §10. `make run-clearbuf`.
- `OVRA4.MOD`/`OVRB4.MOD`/`OVRC4.MOD`/`OVRD4.MOD`/`OVRMAIN4.MOD` — 4-module
  deep-chain eviction regression, combined with the appended-to-EXE
  format (§12): forces evicting TWO simultaneously-idle callers (`Ovra4`
  AND `Ovrb4`) to make room for `Ovrd4`, one level deeper than the
  3-module fixture's single idle caller. `make run-deepchain`.

See `DOCS/TESTS.MD` for how these fit into the wider test suite and for
additional overlay-specific test scenarios.
