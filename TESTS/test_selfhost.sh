#!/bin/bash
# TESTS/test_selfhost.sh — self-hosting byte-identity regression.
#
# Verifies that the compiler can reproduce itself:
#   BOOT/TOC.EXE →  SRC/TOC/*.om  →  toc1.exe
#   toc1.exe     →  SRC/TOC/*.om  →  toc2.exe   (must be byte-identical to toc1.exe)
#
# toc1==toc2 fails by DESIGN whenever a real compiler/linker BEHAVIOR change
# lands (codegen, linker layout/grouping, etc.): BOOT/TOC.EXE still runs the
# OLD behavior when producing toc1.exe, but toc1.exe itself was compiled from
# the NEW source, so it runs the NEW behavior when producing toc2.exe — a
# one-generation lag, not a real fixpoint failure.  The true self-hosting
# question in that case is whether the NEW behavior is stable across a
# generation that no longer involves the stale bootstrap: toc2.exe (built
# under the new behavior) must reproduce itself byte-for-byte as toc3.exe
# (also built under the new behavior).  Step 6 below performs exactly that
# check whenever toc1 != toc2, so a genuine behavior change is not
# misreported as a self-hosting regression.
#
# Module layout:
#   SRC/TOC/     Scan Syms Cgen Def Import PExpr PStmt Parser Link TOC
#   SRC/LIB/     Rdoff Tar (moved here 2026-07-11) — stdlib modules merged
#                into OBERON.OM, NOT part of this script's per-module
#                recompile set: they're built once by `make lib` (outside
#                this script) and consumed here purely via OBERON.OM,
#                exactly like Strings/Files/IO always were.
#   SRC/TRUBO/   LogErr StrTab — merged into TRUBO.OM the same way, resolved
#                via -e OBERON_LIB=TRUBO.OM (see below).
#
# Pre-requisites:
#   - BOOT/TOC.EXE             (bootstrap DOS binary, immutable)
#   - BIN/OBERON.OM            (runtime library archive)
#   - BIN/TRUBO.OM             (supplies LogErr/StrTab)
#   - xt emulator in PATH or $XT
#
# Run from oberonc/:  bash TESTS/test_selfhost.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.
#
# REQUIRES a BOOT/TOC.EXE that can build SRC/TOC (step 1 runs `make`, which uses
# BOOT/TOC.EXE).  If boot predates the BUG 2 fix it stops at
# "error: cannot write Parser.rdf"; refresh BOOT/TOC.EXE from a known-good
# BIN/TOC.EXE first.  The shipped BOOT/TOC.EXE already carries the fix.

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BOOTOC="$ROOT/BOOT/TOC.EXE"
BINDIR="$ROOT/BIN"
OCDIR="$ROOT/SRC/TOC"
XT="${XT:-/Users/admin/bin/xt}"
if ! [ -x "$XT" ]; then XT="$(command -v xt || true)"; fi

if [ -z "$XT" ] || ! [ -x "$XT" ]; then
    echo "SKIP: xt emulator not found — set XT=/path/to/xt to enable self-host test"
    exit 0
fi

# All modules in SRC/TOC/ in dependency order (Rdoff/Tar live in SRC/LIB,
# LogErr/StrTab live in SRC/TRUBO — resolved via OBERON.OM/TRUBO.OM, see above)
ALL_MODS="Scan Syms Cgen Def Import PExpr PStmt Parser Link TOC"

# Scratch dirs live under the project TMP/ (not the system tmpfs).
mkdir -p "$ROOT/TMP"
REFDIR="$(mktemp -d "$ROOT/TMP/selfhost-ref.XXXXXX")"
WORK="$(mktemp -d "$ROOT/TMP/selfhost-work.XXXXXX")"
cleanup() { rm -rf "$REFDIR" "$WORK"; }
trap cleanup EXIT

# The per-module recompiles finish well under a billion instructions, but the
# final single-process TOC link (`/ENTRY=Run TOC.MOD`) of the whole compiler image
# needs the same budget the real build uses (SRC/TOC/Makefile runs it at 4e10).
# A too-small cap silently truncates that step so toc2.exe is never produced.
MAX=40000000000

# ── 1. Build toc1.exe via BOOT/TOC.EXE ──────────────────────────────────
echo "[selfhost] building toc1.exe via BOOT/TOC.EXE ..."
( cd "$OCDIR" && make clean >/dev/null 2>&1 && make >/dev/null 2>&1 )

# Collect reference .om files
for m in $ALL_MODS; do
    f="$OCDIR/$m.om"
    [ -f "$f" ] || f="$OCDIR/$(echo "$m" | tr a-z A-Z).OM"
    cp "$f" "$REFDIR/$m.om"
done
cp "$OCDIR/TOC.EXE" "$REFDIR/toc1.exe"

# ── 2. Stage flat workdir for xt ─────────────────────────────────────────
# Everything in $WORK/: stdlib OBERON.OM, toc .om, toc .MOD sources, toc1.exe
if [ -f "$BINDIR/OBERON.OM" ]; then cp "$BINDIR/OBERON.OM" "$WORK/"; fi
if [ -f "$BINDIR/TRUBO.OM" ]; then cp "$BINDIR/TRUBO.OM" "$WORK/"; fi
for m in $ALL_MODS; do cp "$REFDIR/$m.om" "$WORK/"; done
# Stage the gen-1 compiler under a name that does NOT collide with its own
# output module (TOC).  On a case-insensitive host filesystem (macOS) `toc.exe`
# and the compiler's `TOC.exe` output are the SAME path, so a self-compile would
# overwrite the running binary mid-link and corrupt gen-2.  Use SELFTOC.EXE.
cp "$REFDIR/toc1.exe" "$WORK/SELFTOC.EXE"
cp "$OCDIR"/*.MOD "$WORK/"

# ── 3. Recompile every module under xt with toc1.exe ─────────────────────
echo "[selfhost] recompiling modules under xt with toc1.exe ..."

recompile_mod() {
    local m="$1"
    local src="$(echo "$m" | tr a-z A-Z).MOD"
    local out_upper="$(echo "$m" | tr a-z A-Z).OM"
    rm -f "$WORK/$out_upper" "$WORK/$m.om"
    "$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" -c "$WORK" SELFTOC.EXE "$src" >/dev/null 2>&1
    [ -s "$WORK/$out_upper" ] || [ -s "$WORK/$m.om" ]
}

for m in Scan Syms Cgen Def Import PExpr PStmt Parser Link; do
    echo "  - $m"
    recompile_mod "$m" || { echo "FAIL: $m.om not produced"; exit 1; }
done

echo "  - TOC (/ENTRY=Run)"
rm -f "$WORK/TOC.OM" "$WORK/TOC.om" "$WORK/TOC.exe" "$WORK/TOC.EXE"
"$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" -c "$WORK" SELFTOC.EXE /ENTRY=Run TOC.MOD >/dev/null 2>&1 || true

# ── 4. Per-module byte-identity check ────────────────────────────────────
PASS=0; FAIL=0

check_mod() {
    local m="$1"
    local REF="$REFDIR/$m.om"
    local U="$(echo "$m" | tr a-z A-Z).OM"
    local GEN="$WORK/$U"
    [ -f "$GEN" ] || GEN="$WORK/$m.om"
    if cmp -s "$REF" "$GEN"; then
        echo "PASS: $m.om byte-identical"
        PASS=$((PASS+1))
    else
        local D
        D=$(cmp -l "$REF" "$GEN" 2>&1 | wc -l | tr -d ' ' || true)
        echo "FAIL: $m.om differs ($D bytes differ)"
        FAIL=$((FAIL+1))
    fi
}

for m in $ALL_MODS; do check_mod "$m"; done

# ── 5. toc1.exe == toc2.exe ──────────────────────────────────────────────
TOC2="$WORK/TOC.exe"
[ -f "$TOC2" ] || TOC2="$WORK/TOC.EXE"
TOC1_EQ_TOC2=0
if [ -f "$TOC2" ] && cmp -s "$REFDIR/toc1.exe" "$TOC2"; then
    echo "PASS: toc1.exe == toc2.exe (self-hosting confirmed)"
    PASS=$((PASS+1))
    TOC1_EQ_TOC2=1
else
    if [ ! -f "$TOC2" ]; then
        echo "FAIL: toc2.exe not produced"
    else
        D=$(cmp -l "$REFDIR/toc1.exe" "$TOC2" 2>&1 | wc -l | tr -d ' ' || true)
        echo "FAIL: toc1.exe != toc2.exe ($D bytes differ) — checking gen2==gen3 fixpoint instead (see step 6)"
    fi
fi

# ── 6. gen2 == gen3 fixpoint check (only run when toc1 != toc2) ──────────
# toc1 != toc2 by itself is not a self-hosting regression whenever it's
# caused by a genuine compiler/linker behavior change (the stale
# BOOT/TOC.EXE bootstrap still runs the OLD behavior for toc1; toc1.exe
# itself already runs the NEW behavior).  The real question is whether the
# NEW behavior is a stable fixpoint: recompile the same sources once more,
# this time under toc2.exe (which already runs the new behavior throughout),
# and require toc2.exe == toc3.exe.
if [ "$TOC1_EQ_TOC2" -eq 0 ] && [ -f "$TOC2" ]; then
    echo "[selfhost] toc1 != toc2 — verifying gen2==gen3 fixpoint instead ..."
    GEN2DIR="$(mktemp -d "$ROOT/TMP/selfhost-gen2.XXXXXX")"
    WORK3="$(mktemp -d "$ROOT/TMP/selfhost-work3.XXXXXX")"
    cleanup3() { rm -rf "$GEN2DIR" "$WORK3"; }
    trap 'cleanup3; cleanup' EXIT

    for m in $ALL_MODS; do
        f="$WORK/$(echo "$m" | tr a-z A-Z).OM"
        [ -f "$f" ] || f="$WORK/$m.om"
        cp "$f" "$GEN2DIR/$m.om"
    done
    cp "$TOC2" "$GEN2DIR/toc2.exe"

    if [ -f "$BINDIR/OBERON.OM" ]; then cp "$BINDIR/OBERON.OM" "$WORK3/"; fi
    if [ -f "$BINDIR/TRUBO.OM" ]; then cp "$BINDIR/TRUBO.OM" "$WORK3/"; fi
    for m in $ALL_MODS; do cp "$GEN2DIR/$m.om" "$WORK3/"; done
    cp "$GEN2DIR/toc2.exe" "$WORK3/SELFTOC.EXE"
    cp "$OCDIR"/*.MOD "$WORK3/"

    recompile_gen3() {
        local m="$1"
        local src="$(echo "$m" | tr a-z A-Z).MOD"
        local out_upper="$(echo "$m" | tr a-z A-Z).OM"
        rm -f "$WORK3/$out_upper" "$WORK3/$m.om"
        "$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" -c "$WORK3" SELFTOC.EXE "$src" >/dev/null 2>&1
        [ -s "$WORK3/$out_upper" ] || [ -s "$WORK3/$m.om" ]
    }

    for m in Scan Syms Cgen Def Import PExpr PStmt Parser Link; do
        echo "  - $m (gen3)"
        recompile_gen3 "$m" || { echo "FAIL: gen3 $m.om not produced"; FAIL=$((FAIL+1)); }
    done

    echo "  - TOC (gen3, /ENTRY=Run)"
    rm -f "$WORK3/TOC.OM" "$WORK3/TOC.om" "$WORK3/TOC.exe" "$WORK3/TOC.EXE"
    "$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" -c "$WORK3" SELFTOC.EXE /ENTRY=Run TOC.MOD >/dev/null 2>&1 || true

    for m in $ALL_MODS; do
        REF="$GEN2DIR/$m.om"
        U="$WORK3/$(echo "$m" | tr a-z A-Z).OM"
        GEN3="$U"; [ -f "$GEN3" ] || GEN3="$WORK3/$m.om"
        if cmp -s "$REF" "$GEN3"; then
            echo "PASS: gen2==gen3 $m.om byte-identical"
            PASS=$((PASS+1))
        else
            D=$(cmp -l "$REF" "$GEN3" 2>&1 | wc -l | tr -d ' ' || true)
            echo "FAIL: gen2==gen3 $m.om differs ($D bytes differ)"
            FAIL=$((FAIL+1))
        fi
    done

    TOC3="$WORK3/TOC.exe"
    [ -f "$TOC3" ] || TOC3="$WORK3/TOC.EXE"
    if [ -f "$TOC3" ] && cmp -s "$TOC2" "$TOC3"; then
        echo "PASS: toc2.exe == toc3.exe (behavior-change fixpoint confirmed)"
        PASS=$((PASS+1))
    else
        if [ ! -f "$TOC3" ]; then
            echo "FAIL: toc3.exe not produced"
        else
            D=$(cmp -l "$TOC2" "$TOC3" 2>&1 | wc -l | tr -d ' ' || true)
            echo "FAIL: toc2.exe != toc3.exe ($D bytes differ) — not a stable fixpoint, real regression"
        fi
        FAIL=$((FAIL+1))
    fi

    cleanup3
    trap cleanup EXIT
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
