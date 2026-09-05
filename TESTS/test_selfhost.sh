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
# Why gen2 vs gen3 rather than gen1 vs gen2: gen1 is produced by whatever is
# in BIN/, which may predate the current sources -- a gen1 != gen2 difference
# is the normal one-generation lag after any codegen change, not a defect.
# gen2 == gen3 is the real fixpoint.
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
trap 'rm -rf "$G1" "$G2" "$G3"' EXIT

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
    ( cd "$TO"
      for m in TOCC TOCL TOC; do
          rm -f "$m.EXE" "$m.LNK"
          "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" -c . \
              SELFC.EXE /ENTRY=Run "$m.MOD" >/dev/null 2>&1 || true
          if [ -s "$m.LNK" ]; then
              "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" -c . \
                  SELFL.EXE "$m.LNK" >/dev/null 2>&1 || true
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

echo "[selfhost] comparing gen2 vs gen3 (all three binaries) ..."
PASS=0; FAIL=0
for e in TOC.EXE TOCC.EXE TOCL.EXE; do
    if cmp -s "$G2/$e" "$G3/$e"; then
        echo "PASS: $e byte-identical (gen2 == gen3)"
        PASS=$((PASS+1))
    else
        echo "FAIL: $e differs ($(cmp -l "$G2/$e" "$G3/$e" | wc -l | tr -d ' ') bytes)"
        FAIL=$((FAIL+1))
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
