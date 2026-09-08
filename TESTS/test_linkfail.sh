#!/bin/bash
# TESTS/test_linkfail.sh — a FAILED link must not leave an .EXE behind.
#
# Regression (found + fixed 2026-09-05).  Every link step in
# TOCL.LinkFromFile is guarded by ~LogErr.HaveErr(), and LinkMZ.WriteExe
# detects a flush/disk-full error and latches it (its Files.Ok check) -- but
# nothing REMOVED the output file, so after a failed link the directory still
# held either a truncated image or, worse, the previous run's complete-but-now-
# stale .EXE.  Any build step that tests for the output by existence then
# treats the link as successful.
#
# That is what produced a short gen2 TOCC.EXE inside test_selfhost.sh, which
# surfaced only much later, and very confusingly, as "FAIL: TOCC.EXE differs"
# -- a byte-identity failure standing in for a link that had actually errored.
# test_selfhost.sh discards compiler output (>/dev/null 2>&1 || true) and only
# checks the result is non-empty, so a partial file slips straight through.
#
# The old in-process TocMain.LinkAll deleted the output on HaveErr;
# LINKMZ.MOD's Files.Ok comment still refers to that deletion.  The split
# linker lost it.  Restored in TOCL.LinkFromFile.
#
# Pre-requisites:
#   - BIN/TOC.EXE, BIN/TOCC.EXE, BIN/TOCL.EXE
#   - BIN/OBERON.OM, BIN/TRUBO.OM
#   - xt emulator in PATH or $XT
#
# Run from oberonc/:  bash TESTS/test_linkfail.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

XT=${XT:-xt}
if ! command -v "$XT" >/dev/null 2>&1; then
    echo "[linkfail] xt not found -- skipping"
    exit 0
fi
for f in BIN/TOC.EXE BIN/TOCC.EXE BIN/TOCL.EXE BIN/OBERON.OM BIN/TRUBO.OM; do
    [ -f "$f" ] || { echo "[linkfail] missing $f -- skipping"; exit 0; }
done

WD=$(mktemp -d "$ROOT/TMP/linkfail.XXXXXX")
trap 'rm -rf "$WD"' EXIT
cp BIN/TOC.EXE BIN/TOCC.EXE BIN/TOCL.EXE BIN/OBERON.OM BIN/TRUBO.OM "$WD/"

cat > "$WD/LNKFAIL.MOD" <<'EOF'
MODULE LNKFAIL;
IMPORT Out;
PROCEDURE Run*;
BEGIN Out.String("lnkfail ok"); Out.Ln
END Run;
END LNKFAIL.
EOF

PASS=0; FAIL=0
check () { if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
           else echo "FAIL: $1 (got '$2', want '$3')"; FAIL=$((FAIL+1)); fi; }

# A good link first: gives us both a reference image and a valid .LNK to corrupt.
( cd "$WD" && $XT run --max=300000000 --memkb=640 -e "OBERON_LIB=TRUBO.OM" \
      TOC.EXE /CD /ENTRY=Run LNKFAIL.MOD /M >/dev/null 2>&1 ) || true
[ -s "$WD/LNKFAIL.EXE" ] || { echo "FAIL: baseline link produced no .EXE"; exit 1; }
check "successful link produces an .EXE" "present" "present"
cp "$WD/LNKFAIL.EXE" "$WD/REF.BIN"

# The failing link names an .om that does not exist.  Critically, a COMPLETE
# .EXE from the previous run is sitting there: the bug kept it, so an
# existence check would call the failed link a success.
sed 's/^OM .*/OM NOSUCH.OM/' "$WD/LNKFAIL.LNK" > "$WD/BAD.LNK"

rc=0
( cd "$WD" && $XT run --max=300000000 --memkb=640 TOCL.EXE BAD.LNK TRUBO.OM >/dev/null 2>&1 ) || rc=$?
check "failed link exits non-zero" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "failed link leaves no .EXE" \
      "$([ -f "$WD/LNKFAIL.EXE" ] && echo present || echo absent)" "absent"

# And the fix must not delete the output of a link that SUCCEEDS.
( cd "$WD" && $XT run --max=300000000 --memkb=640 TOCL.EXE LNKFAIL.LNK TRUBO.OM >/dev/null 2>&1 ) || true
check "successful link keeps its .EXE" \
      "$([ -s "$WD/LNKFAIL.EXE" ] && echo present || echo absent)" "present"
check "relinked .EXE is byte-identical to the reference" \
      "$(cmp -s "$WD/LNKFAIL.EXE" "$WD/REF.BIN" && echo same || echo differs)" "same"
check "relinked .EXE runs" \
      "$( ( cd "$WD" && $XT run --max=300000000 LNKFAIL.EXE 2>&1 ) | grep -q 'lnkfail ok' && echo ok || echo broken)" "ok"

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
