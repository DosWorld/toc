#!/bin/bash
# TESTS/test_tlink.sh — tlink.exe (SRC/TLINK/) regression: all four /T=
# output modes (com, texe, exe, sys) linked from TASM-assembled fixtures
# and, where the mode is a runnable program, executed under xt with its
# stdout checked.
#
# texe (/T=texe) is a tiny-model .COM-equivalent wrapped in an MZ header
# (DS=CS=SS=PSP, no on-disk JMP stub, entry IP set directly) instead of a
# raw .COM image -- see TLINK.MOD's TExe import and SRC/TLINK/TEXE.MOD's
# header comment.  Both /T=com and /T=texe share TLINK.MOD's OnReloc PSP
# (CS:100h) address bias for absolute in-image references -- this test
# catches the exact regression found while implementing texe: the bias
# was simply missing (msg's absolute address encoded as a 0-based image
# offset instead of PSP+0x100-relative), which produced .COM output that
# ran but printed garbage/looped forever, not just an obviously-broken
# texe.
#
# Pre-requisites:
#   - BOOT/TOC.EXE      (bootstrap DOS binary, immutable)
#   - BIN/OBERON.OM     (runtime library archive)
#   - BIN/TRUBO.OM      (supplies LogErr/StrTab)
#   - xt emulator in PATH or $XT
#
# Run from oberonc/:  bash TESTS/test_tlink.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BOOTOC="$ROOT/BOOT/TOC.EXE"
BINOM="$ROOT/BIN/OBERON.OM"
BINTRUBOOM="$ROOT/BIN/TRUBO.OM"
TASMDIR="$ROOT/SRC/TASM"
TLINKDIR="$ROOT/SRC/TLINK"
FIXDIR="$ROOT/TESTS/FIX"
XT="${XT:-xt}"
MAX=300000000

if ! command -v "$XT" >/dev/null 2>&1; then
    echo "SKIP: xt emulator not found — set XT=/path/to/xt to enable the TLINK test"
    exit 0
fi

WORK="$(mktemp -d "$ROOT/TMP/tlink-work.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$ROOT/TMP"
cp "$BOOTOC" "$WORK/TOC_BOOT.EXE"
cp "$BINOM" "$WORK/OBERON.OM"
cp "$BINTRUBOOM" "$WORK/TRUBO.OM"
cp "$TASMDIR"/*.MOD "$WORK/"
cp "$TLINKDIR/TLINK.MOD" "$TLINKDIR/TEXE.MOD" "$WORK/"
cp "$FIXDIR/TLINKHI.ASM" "$FIXDIR/TLINKDRV.ASM" "$WORK/"

PASS=0; FAIL=0

echo "[tlink] building TASM.exe via BOOT/TOC.EXE ..."
( cd "$WORK" && "$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TASM.MOD >build-tasm.log 2>&1 ) \
    || { echo "FAIL: TASM.exe did not build"; cat "$WORK/build-tasm.log"; exit 1; }
[ -f "$WORK/TASM.exe" ] || { echo "FAIL: TASM.exe not produced"; cat "$WORK/build-tasm.log"; exit 1; }

echo "[tlink] building TLINK.exe via BOOT/TOC.EXE ..."
( cd "$WORK" && "$XT" run --max=$MAX -e "OBERON_LIB=TRUBO.OM" TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TLINK.MOD >build-tlink.log 2>&1 ) \
    || { echo "FAIL: TLINK.exe did not build"; cat "$WORK/build-tlink.log"; exit 1; }
[ -f "$WORK/TLINK.exe" ] || { echo "FAIL: TLINK.exe not produced"; cat "$WORK/build-tlink.log"; exit 1; }

echo "[tlink] assembling fixtures ..."
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLINKHI.ASM >assemble-hi.log 2>&1 ) \
    || { echo "FAIL: TLINKHI.ASM did not assemble"; cat "$WORK/assemble-hi.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLINKDRV.ASM >assemble-drv.log 2>&1 ) \
    || { echo "FAIL: TLINKDRV.ASM did not assemble"; cat "$WORK/assemble-drv.log"; exit 1; }

# check_run: link TLINKHI.RDF with mode $1 into output $2, run it under xt,
# and confirm stdout equals the expected greeting exactly (byte-for-byte,
# not just a substring match -- catches both wrong data AND runaway output
# from a missing/incorrect PSP-relative address bias).
check_run() {
    local mode="$1" out="$2"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe "/T=$mode" TLINKHI.RDF "$out" >"link-$mode.log" 2>&1 ) \
        || { echo "FAIL: /T=$mode link failed"; cat "$WORK/link-$mode.log"; FAIL=$((FAIL+1)); return; }
    if [ ! -f "$WORK/$out" ]; then
        echo "FAIL: /T=$mode did not produce $out"
        cat "$WORK/link-$mode.log"
        FAIL=$((FAIL+1))
        return
    fi
    local got
    got="$( cd "$WORK" && "$XT" run --max=5000000 "$out" 2>/dev/null | grep -vE '^Maximum instructions limit|^DOS conventional memory' )" || true
    local want=$'Hi from tlink!\r'
    if [ "$got" = "$want" ]; then
        echo "PASS: /T=$mode -> $out runs and prints the expected greeting"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=$mode -> $out output mismatch: got '$got'"
        FAIL=$((FAIL+1))
    fi
}

check_run com HELLO.COM
check_run texe HELLO.EXE

echo "[tlink] linking /T=sys (device driver header, header-field check only) ..."
rm -f "$WORK/DRV.SYS"
( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=sys /N=TESTDRV TLINKDRV.RDF DRV.SYS >link-sys.log 2>&1 ) \
    || { echo "FAIL: /T=sys link failed"; cat "$WORK/link-sys.log"; FAIL=$((FAIL+1)); }
if [ -f "$WORK/DRV.SYS" ]; then
    # header: next(-1)[4] attr[2] strategy[2] interrupt[2] name[8]
    hdr="$(xxd -p -l 18 "$WORK/DRV.SYS")"
    if [[ "$hdr" == ffffffff0000* ]]; then
        echo "PASS: /T=sys -> DRV.SYS header starts with next=-1, attr=0"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=sys -> DRV.SYS header malformed: $hdr"
        FAIL=$((FAIL+1))
    fi
else
    echo "FAIL: /T=sys did not produce DRV.SYS"
    FAIL=$((FAIL+1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
