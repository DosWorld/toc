#!/bin/bash
# TESTS/test_selfhost.sh — self-hosting byte-identity regression.
#
# Verifies that the compiler can reproduce itself:
#   BOOT/TOC.EXE →  SRC/TOC/*.om  →  toc1.exe
#   toc1.exe     →  SRC/TOC/*.om  →  toc2.exe   (must be byte-identical to toc1.exe)
#
# Module layout:
#   SRC/TOC/     Scan StrTab Syms Cgen Def Import PExpr PStmt Parser Link TOC
#   SRC/LIB/     Rdoff Tar LogErr (moved here 2026-07-11, renamed from Err) —
#                stdlib modules merged into OBERON.OM, NOT part of this
#                script's per-module recompile set: they're built once by
#                `make lib` (outside this script) and consumed here purely
#                via OBERON.OM, exactly like Strings/Files/IO always were.
#
# Pre-requisites:
#   - BOOT/TOC.EXE             (bootstrap DOS binary, immutable)
#   - BIN/OBERON.OM            (runtime library archive)
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

# All modules in SRC/TOC/ in dependency order (Rdoff/Tar/LogErr excluded —
# they live in SRC/LIB now and are resolved purely via OBERON.OM, see above)
ALL_MODS="Scan StrTab Syms Cgen Def Import PExpr PStmt Parser Link TOC"

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
    "$XT" run --max=$MAX -c "$WORK" SELFTOC.EXE "$src" >/dev/null 2>&1
    [ -s "$WORK/$out_upper" ] || [ -s "$WORK/$m.om" ]
}

for m in Scan StrTab Syms Cgen Def Import PExpr PStmt Parser Link; do
    echo "  - $m"
    recompile_mod "$m" || { echo "FAIL: $m.om not produced"; exit 1; }
done

echo "  - TOC (/ENTRY=Run)"
rm -f "$WORK/TOC.OM" "$WORK/TOC.om" "$WORK/TOC.exe" "$WORK/TOC.EXE"
"$XT" run --max=$MAX -c "$WORK" SELFTOC.EXE /ENTRY=Run TOC.MOD >/dev/null 2>&1 || true

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
if [ -f "$TOC2" ] && cmp -s "$REFDIR/toc1.exe" "$TOC2"; then
    echo "PASS: toc1.exe == toc2.exe (self-hosting confirmed)"
    PASS=$((PASS+1))
else
    if [ ! -f "$TOC2" ]; then
        echo "FAIL: toc2.exe not produced"
    else
        D=$(cmp -l "$REFDIR/toc1.exe" "$TOC2" 2>&1 | wc -l | tr -d ' ' || true)
        echo "FAIL: toc1.exe != toc2.exe ($D bytes differ)"
    fi
    FAIL=$((FAIL+1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
