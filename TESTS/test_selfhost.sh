#!/bin/bash
# Self-hosting regression for the SPLIT toolchain.
#
#   BIN/{TOC,TOCC,TOCL}.EXE  --(rebuild themselves)-->  gen2
#   gen2                     --(rebuild themselves)-->  gen3
#   require gen2 == gen3, byte-for-byte, for ALL THREE binaries.
#
# Why all three, not just the compiler: each generation's TOCC.EXE and
# TOCL.EXE are what build the next one.  A drifting linker would silently
# change every later image even with a byte-stable compiler, so a check that
# only compared TOC.EXE (or only the .om files) would miss it.
#
# Why gen3 vs gen4 rather than gen1 vs gen2: gen1 is produced by whatever is
# in BIN/, which may predate the current sources -- a gen1 != gen2 difference
# is the normal one-generation lag after any codegen change, not a defect.
#
# TWO generations of lag are possible, which is why this compares gen3 vs gen4
# and not gen2 vs gen3.  `make test` rebuilds BIN/ from BOOT/ before running
# this script, so after a codegen change that BOOT/ predates, BOTH gen1 (built
# by BOOT) and gen2 (built by gen1, which still contains the old codegen) are
# pre-convergence; the new codegen first appears in gen3.  Comparing gen2 vs
# gen3 then reports a spurious failure on a perfectly stable compiler -- seen
# 2026-09-09 with the RETURN-widening fix, where gen2=262768 and
# gen3=gen4=262544.  gen3 == gen4 is correct whether the lag is one generation
# or two.
#
# Each generation goes through the REAL split path: TOCC compiles and emits a
# .LNK control file, TOCL links from it.  That exercises the handoff, not just
# the compiler.
#
# Requires: BIN/{TOC,TOCC,TOCL}.EXE, BIN/OBERON.OM, BIN/TRUBO.OM, xt.

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BINDIR="$ROOT/BIN"
OCDIR="$ROOT/SRC/TOC"
MAX=40000000000
XT="${XT:-/Users/admin/bin/xt}"
if ! [ -x "$XT" ]; then XT="$(command -v xt || true)"; fi

if [ -z "$XT" ] || ! [ -x "$XT" ]; then
    echo "SKIP: xt emulator not found — set XT=/path/to/xt to enable self-host test"
    exit 0
fi

for f in TOC.EXE TOCC.EXE TOCL.EXE OBERON.OM TRUBO.OM; do
    [ -s "$BINDIR/$f" ] || { echo "SKIP: $BINDIR/$f missing — run make first"; exit 0; }
done

mkdir -p "$ROOT/TMP"
G1="$(mktemp -d "$ROOT/TMP/selfhost-g1.XXXXXX")"
G2="$(mktemp -d "$ROOT/TMP/selfhost-g2.XXXXXX")"
G3="$(mktemp -d "$ROOT/TMP/selfhost-g3.XXXXXX")"
G4="$(mktemp -d "$ROOT/TMP/selfhost-g4.XXXXXX")"
trap 'rm -rf "$G1" "$G2" "$G3" "$G4"' EXIT

# Build the three binaries in $2, using the TOCC/TOCL found in $1.
# Each is compiled (producing a .LNK) and then linked, i.e. the same two-step
# path a real build takes.
generation() {
    local FROM="$1" TO="$2"
    cp "$OCDIR"/*.MOD "$OCDIR/NESTAB.RDF" "$TO/" 2>/dev/null || true
    cp "$BINDIR/OBERON.OM" "$BINDIR/TRUBO.OM" "$TO/"
    # Copy under distinct names: on a case-insensitive host filesystem the
    # running TOCC.EXE and the TOCC.EXE being linked are the SAME path, so a
    # self-compile would overwrite the running binary mid-link.
    cp "$FROM/TOCC.EXE" "$TO/SELFC.EXE"
    cp "$FROM/TOCL.EXE" "$TO/SELFL.EXE"
    # Report a failing compile/link HERE, where the cause is still visible.
    # These used to be plain `|| true` with output discarded, so a generation
    # that errored was noticed only later, as an unexplained byte-identity
    # "differs" -- which is exactly how a truncated gen2 TOCC.EXE presented
    # itself (see TESTS/test_linkfail.sh for that bug).  The step still does
    # not abort the run: gen1 legitimately may not reproduce the current
    # sources, and only gen2 vs gen3 is asserted.
    ( cd "$TO"
      for m in TOCC TOCL TOC; do
          rm -f "$m.EXE" "$m.LNK"
          if ! "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" -c . \
                   SELFC.EXE /ENTRY=Run "$m.MOD" >"$m.clog" 2>&1; then
              echo "[selfhost]   WARNING: compiling $m.MOD failed in $(basename "$TO"):"
              grep -aiE "error|leak" "$m.clog" | head -3 | sed 's/^/[selfhost]     /'
          fi
          if [ -s "$m.LNK" ]; then
              if ! "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" -c . \
                       SELFL.EXE "$m.LNK" >"$m.llog" 2>&1; then
                  echo "[selfhost]   WARNING: linking $m failed in $(basename "$TO"):"
                  grep -aiE "error|leak" "$m.llog" | head -3 | sed 's/^/[selfhost]     /'
              fi
          else
              echo "[selfhost]   WARNING: $m.LNK not produced in $(basename "$TO")"
          fi
      done )
}

echo "[selfhost] gen1: rebuilding the toolchain with BIN/ ..."
cp "$BINDIR/TOCC.EXE" "$G1/TOCC.EXE"
cp "$BINDIR/TOCL.EXE" "$G1/TOCL.EXE"

echo "[selfhost] gen2: rebuilding with gen1 ..."
generation "$G1" "$G2"
for e in TOC.EXE TOCC.EXE TOCL.EXE; do
    [ -s "$G2/$e" ] || { echo "FAIL: gen2 $e not produced"; exit 1; }
done

echo "[selfhost] gen3: rebuilding with gen2 ..."
generation "$G2" "$G3"
for e in TOC.EXE TOCC.EXE TOCL.EXE; do
    [ -s "$G3/$e" ] || { echo "FAIL: gen3 $e not produced"; exit 1; }
done

echo "[selfhost] gen4: rebuilding with gen3 ..."
generation "$G3" "$G4"
for e in TOC.EXE TOCC.EXE TOCL.EXE; do
    [ -s "$G4/$e" ] || { echo "FAIL: gen4 $e not produced"; exit 1; }
done

echo "[selfhost] comparing gen3 vs gen4 (all three binaries) ..."
PASS=0; FAIL=0
for e in TOC.EXE TOCC.EXE TOCL.EXE; do
    if cmp -s "$G3/$e" "$G4/$e"; then
        echo "PASS: $e byte-identical (gen3 == gen4)"
        PASS=$((PASS+1))
    else
        echo "FAIL: $e differs ($(cmp -l "$G3/$e" "$G4/$e" | wc -l | tr -d ' ') bytes)"
        FAIL=$((FAIL+1))
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
