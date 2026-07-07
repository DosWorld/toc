#!/bin/bash
# TESTS/test_dbg.sh — TDS/TDINFO debug-info (/G) regression.
#
# Verifies the invariants of the debug-info feature (dbg.md §8):
#   1. Pure-append: the non-/G .exe is an exact byte prefix of the /G .exe
#      (same MZ header, code, data — only the trailing TDS block differs),
#      and the /G .exe still runs with the same exit code.
#   2. Round-trip: BIN/TDINFO.EXE parses the /G .exe and reports the expected
#      module, source file, symbols and a line table.
#   3. Always-present .DBG member: a $D+ module's .om carries a non-empty
#      MODNAME.DBG; a module without $D carries a 0-byte MODNAME.DBG.
#   4. Mixed build: only the $D+ module contributes records (modules:1).
#
# Pre-requisites: BIN/TOC.EXE BIN/TOLIB.EXE BIN/TDINFO.EXE BIN/OBERON.OM, xt.
# Run from oberonc/:  bash TESTS/test_dbg.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

XT="${XT:-/Users/admin/bin/xt}"
if ! [ -x "$XT" ]; then XT="$(command -v xt || true)"; fi
if [ -z "$XT" ] || ! [ -x "$XT" ]; then
    echo "SKIP: xt emulator not found — set XT=/path/to/xt to enable debug-info test"
    exit 0
fi

for f in BIN/TOC.EXE BIN/TOLIB.EXE BIN/TDINFO.EXE BIN/OBERON.OM; do
    [ -f "$ROOT/$f" ] || { echo "FAIL: missing $f — run make"; exit 1; }
done

mkdir -p "$ROOT/TMP"
WD="$(mktemp -d "$ROOT/TMP/dbg.XXXXXX")"
trap 'rm -rf "$WD"' EXIT

cp "$ROOT/TESTS/FIX/DBGINFO.MOD" "$ROOT/TESTS/FIX/DBGOFF.MOD" "$WD/"
cp "$ROOT/BIN/TOC.EXE"     "$WD/TOC.EXE"
cp "$ROOT/BIN/TOLIB.EXE"   "$WD/TOLIB.EXE"
cp "$ROOT/BIN/TDINFO.EXE" "$WD/TDINFO.EXE"
cp "$ROOT/BIN/OBERON.OM"  "$WD/OBERON.OM"

run() { (cd "$WD" && "$XT" run --max=200000000 -c "$WD" "$@" 2>&1); }

fail() { echo "FAIL: $1"; exit 1; }

# ---- build without /G ----
run TOC.EXE /ENTRY=Run DBGINFO.MOD >/dev/null || fail "compile+link (no /G)"
[ -f "$WD/DBGINFO.EXE" ] || fail "DBGINFO.EXE not produced (no /G)"
mv "$WD/DBGINFO.EXE" "$WD/OFF.EXE"

# ---- build with /G (force recompile so MAIN.RDF/.om are rebuilt identically) ----
rm -f "$WD/DBGINFO.OM"
run TOC.EXE /G /ENTRY=Run DBGINFO.MOD >/dev/null || fail "compile+link (/G)"
[ -f "$WD/DBGINFO.EXE" ] || fail "DBGINFO.EXE not produced (/G)"

# ---- 1. pure-append prefix identity + exe still runs ----
off_size=$(wc -c < "$WD/OFF.EXE" | tr -d ' ')
g_size=$(wc -c < "$WD/DBGINFO.EXE" | tr -d ' ')
[ "$g_size" -gt "$off_size" ] || fail "/G exe not larger (off=$off_size g=$g_size)"
cmp -n "$off_size" "$WD/OFF.EXE" "$WD/DBGINFO.EXE" \
    || fail "non-/G exe is not a byte prefix of the /G exe"
run DBGINFO.EXE >/dev/null || fail "/G exe exited non-zero"

# ---- 2 + 4. tdinfo round-trip on the /G exe ----
dump="$(run TDINFO.EXE DBGINFO.EXE)" || fail "tdinfo could not parse the /G exe"
for want in "modules:1" "DbgInfo" "DBGINFO.MOD" "counter" "flag" "Bump" "Run" \
            "=== Line numbers (" "Point" "origin" "TYPEDEF" "STRUCT"; do
    echo "$dump" | grep -qF "$want" || fail "tdinfo output lacks '$want'"
done
# origin (a Point) must carry a non-zero type index, proving S-line type
# rebasing worked end to end.
echo "$dump" | grep -E "origin.*type=[1-9]" >/dev/null \
    || fail "tdinfo: 'origin' symbol has no non-zero type index"

# Run's local 'fails' must appear as an AUTO symbol, and exactly TWO
# SCOPE_RECORDs must exist: Run's own (fails) and nested Inner's (x, doubled).
# (Bump has no locals -> no scope for it.)
echo "$dump" | grep -E "fails.*class=AUTO" >/dev/null \
    || fail "tdinfo: 'fails' local not present as class=AUTO"
echo "$dump" | grep -E "doubled.*class=AUTO" >/dev/null \
    || fail "tdinfo: 'doubled' (Inner's local) not present as class=AUTO"
echo "$dump" | grep -qF "=== Scopes (2)" \
    || fail "tdinfo: expected exactly 2 scopes (Run's + nested Inner's), got a different count"
# Each scope's func must resolve to the RIGHT owning procedure — this is the
# nested-scope regression check: a scope's func must NOT all collapse onto
# the innermost procedure (that was the bug: the linker tracked "most recent
# P" as a flat scalar, so Inner's own P clobbered Run's tracking before
# Run's own scope-end was reached).
check_scope_func() {
    local scope_idx="$1" want_name="$2"
    local scope_line func_idx sym_line
    scope_line="$(echo "$dump" | grep -E "^\s*\[\s*$scope_idx\s*\] sym_first=")"
    func_idx="$(echo "$scope_line" | sed -E 's/.*func=([0-9]+).*/\1/')"
    sym_line="$(echo "$dump" | grep -E "^\s*\[\s*$((func_idx - 1))\s*\]")"
    echo "$sym_line" | grep -qF "$want_name" \
        || fail "tdinfo: scope [$scope_idx]'s func does not resolve to '$want_name' (got: $sym_line)"
}
check_scope_func 0 "Inner"
check_scope_func 1 "Run"

# ---- 3. always-present .DBG member (non-empty for $D+, 0-byte for $D-) ----
lst="$(run TOLIB.EXE list DBGINFO.OM)"
echo "$lst" | grep -qE "DBGINFO\.DBG +[1-9][0-9]*" \
    || fail "DBGINFO.OM lacks a non-empty DBGINFO.DBG member"

run TOC.EXE DBGOFF.MOD >/dev/null || fail "compile DBGOFF"
lst="$(run TOLIB.EXE list DBGOFF.OM)"
echo "$lst" | grep -qE "DBGOFF\.DBG +0\b" \
    || fail "DBGOFF.OM lacks a 0-byte DBGOFF.DBG member"

echo "PASS: debug-info (/G) regression"
exit 0
