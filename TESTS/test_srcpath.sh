#!/bin/bash
# TESTS/test_srcpath.sh — the split driver must accept a source given with a
# DIRECTORY PATH, not just a bare filename in the CWD.
#
# Regression (found + fixed 2026-09-05).  TOC.EXE is only a driver: it execs
# TOCC.EXE to compile, then locates the <stem>.LNK control file TOCC wrote and
# execs TOCL.EXE on it.  The two halves derived that name differently:
#
#   TOCC (TocMain.WriteLinkFile) names it after its OUTPUT image, and outExe
#        defaults to the root module's own name with no directory part -- so
#        `toc /ENTRY=Run SUB/FOO.MOD` writes FOO.LNK/FOO.OM/FOO.EXE in the CWD.
#   TOC  (LnkName) derived it from the SOURCE path with Dos.FSplit+PathJoin,
#        which kept the "SUB/" prefix.
#
# So the driver looked for SUB/FOO.LNK, never found it, and aborted with
#   toc: compiler produced no link file SUB/FOO.LNK
# before ever running the linker -- i.e. EVERY source passed with a directory
# path compiled fine but silently failed to link.  Compiling from the CWD (the
# only shape the MANIFEST.TSV runner can produce, since it copies each fixture
# into a flat work dir) never exercised this, which is why the manifest stayed
# green.  Hence a shell test rather than a manifest row.
#
# Also covers backslash ("SUB\FOO.MOD") and nested ("DEEP/A/FOO.MOD") paths,
# because Dos.FSplit recognises only "\" and ":" as separators while
# TocMain.BaseStem -- the code that actually picks the output name -- accepts
# "/", "\" and ":" alike.  LnkName must match BaseStem, not FSplit.
#
# Pre-requisites:
#   - BIN/TOC.EXE, BIN/TOCC.EXE, BIN/TOCL.EXE  (the three-binary toolchain)
#   - BIN/OBERON.OM, BIN/TRUBO.OM
#   - xt emulator in PATH or $XT
#
# Run from oberonc/:  bash TESTS/test_srcpath.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

XT=${XT:-xt}
if ! command -v "$XT" >/dev/null 2>&1; then
    echo "[srcpath] xt not found -- skipping"
    exit 0
fi
for f in BIN/TOC.EXE BIN/TOCC.EXE BIN/TOCL.EXE BIN/OBERON.OM BIN/TRUBO.OM; do
    [ -f "$f" ] || { echo "[srcpath] missing $f -- skipping"; exit 0; }
done

WD=$(mktemp -d "$ROOT/TMP/srcpath.XXXXXX")
trap 'rm -rf "$WD"' EXIT

mkdir -p "$WD/SUB" "$WD/DEEP/A"
cp BIN/TOC.EXE BIN/TOCC.EXE BIN/TOCL.EXE BIN/OBERON.OM BIN/TRUBO.OM "$WD/"

for d in . SUB DEEP/A; do
    cat > "$WD/$d/PATHMOD.MOD" <<'EOF'
MODULE PATHMOD;
IMPORT Out;
PROCEDURE Run*;
BEGIN Out.String("pathmod ok"); Out.Ln
END Run;
END PATHMOD.
EOF
done

PASS=0; FAIL=0
run_case () {                      # $1 = label, $2 = source arg, $3 = extra flags
    local label="$1" src="$2" flags="${3:-}"
    ( cd "$WD" && rm -f PATHMOD.EXE PATHMOD.LNK PATHMOD.OM )
    local out
    out=$( cd "$WD" && $XT run --max=300000000 --memkb=640 \
             -e "OBERON_LIB=TRUBO.OM" TOC.EXE /CD $flags /ENTRY=Run "$src" /M 2>&1 ) || true
    if [ -s "$WD/PATHMOD.EXE" ]; then
        echo "PASS: $label"; PASS=$((PASS+1))
    else
        echo "FAIL: $label -- no .EXE produced"
        echo "$out" | grep -aiE "no link file|ERROR" | head -2 | sed 's/^/        /'
        FAIL=$((FAIL+1))
    fi
}

run_case "bare filename in CWD"        "PATHMOD.MOD"
run_case "forward-slash directory"     "SUB/PATHMOD.MOD"
run_case "backslash directory"         'SUB\PATHMOD.MOD'
run_case "nested directory"            "DEEP/A/PATHMOD.MOD"
run_case "directory path, /CP (NE)"    "SUB/PATHMOD.MOD" "/CP"

# The /CD image must actually run, not merely link.
( cd "$WD" && rm -f PATHMOD.EXE PATHMOD.LNK PATHMOD.OM )
( cd "$WD" && $XT run --max=300000000 --memkb=640 -e "OBERON_LIB=TRUBO.OM" \
      TOC.EXE /CD /ENTRY=Run SUB/PATHMOD.MOD /M >/dev/null 2>&1 ) || true
if [ -s "$WD/PATHMOD.EXE" ] && \
   ( cd "$WD" && $XT run --max=300000000 PATHMOD.EXE 2>&1 ) | grep -q "pathmod ok"; then
    echo "PASS: EXE linked from a directory path runs correctly"; PASS=$((PASS+1))
else
    echo "FAIL: EXE linked from a directory path did not run"; FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
