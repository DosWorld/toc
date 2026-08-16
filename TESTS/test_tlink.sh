#!/bin/bash
# TESTS/test_tlink.sh — tlink.exe (SRC/TLINK/) regression: all five /T=
# output modes (com, texe, exe, sys, bgi2) linked from TASM-assembled
# fixtures and, where the mode is a runnable program, executed under xt
# with its stdout checked.  bgi2 (Borland BGI v2.0 graphics driver, see
# DOCS/BGI.MD) is checked structurally instead (magic/header blocks/name/
# 'CB' signature) since a driver file isn't itself directly runnable.
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
MAX=500000000

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
cp "$TLINKDIR/TLINK.MOD" "$TLINKDIR/TEXE.MOD" "$TLINKDIR/BGI2.MOD" "$TLINKDIR/BIN.MOD" "$WORK/"
cp "$FIXDIR/TLINKHI.ASM" "$FIXDIR/TLINKDRV.ASM" "$FIXDIR/TLKMAIN.ASM" "$FIXDIR/TLKMOD2.ASM" \
   "$FIXDIR/TLKNOSTART.ASM" "$FIXDIR/TLKUNRES.ASM" "$FIXDIR/TLKDUPA.ASM" "$FIXDIR/TLKDUPB.ASM" \
   "$FIXDIR/TLKJMPCOM.ASM" "$FIXDIR/TLKBGI.ASM" "$FIXDIR/TLKDD.ASM" "$WORK/"

PASS=0; FAIL=0

echo "[tlink] building TASM.exe via BOOT/TOC.EXE ..."
( cd "$WORK" && "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TASM.MOD >build-tasm.log 2>&1 ) \
    || { echo "FAIL: TASM.exe did not build"; cat "$WORK/build-tasm.log"; exit 1; }
[ -f "$WORK/TASM.exe" ] || { echo "FAIL: TASM.exe not produced"; cat "$WORK/build-tasm.log"; exit 1; }

echo "[tlink] building TLINK.exe via BOOT/TOC.EXE ..."
( cd "$WORK" && "$XT" run --max=$MAX --memkb=640 -e "OBERON_LIB=TRUBO.OM" TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TLINK.MOD >build-tlink.log 2>&1 ) \
    || { echo "FAIL: TLINK.exe did not build"; cat "$WORK/build-tlink.log"; exit 1; }
[ -f "$WORK/TLINK.exe" ] || { echo "FAIL: TLINK.exe not produced"; cat "$WORK/build-tlink.log"; exit 1; }

echo "[tlink] assembling fixtures ..."
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLINKHI.ASM >assemble-hi.log 2>&1 ) \
    || { echo "FAIL: TLINKHI.ASM did not assemble"; cat "$WORK/assemble-hi.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLINKDRV.ASM >assemble-drv.log 2>&1 ) \
    || { echo "FAIL: TLINKDRV.ASM did not assemble"; cat "$WORK/assemble-drv.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKNOSTART.ASM >assemble-nostart.log 2>&1 ) \
    || { echo "FAIL: TLKNOSTART.ASM did not assemble"; cat "$WORK/assemble-nostart.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKUNRES.ASM >assemble-unres.log 2>&1 ) \
    || { echo "FAIL: TLKUNRES.ASM did not assemble"; cat "$WORK/assemble-unres.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKDUPA.ASM >assemble-dupa.log 2>&1 ) \
    || { echo "FAIL: TLKDUPA.ASM did not assemble"; cat "$WORK/assemble-dupa.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKDUPB.ASM >assemble-dupb.log 2>&1 ) \
    || { echo "FAIL: TLKDUPB.ASM did not assemble"; cat "$WORK/assemble-dupb.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKJMPCOM.ASM >assemble-jmpcom.log 2>&1 ) \
    || { echo "FAIL: TLKJMPCOM.ASM did not assemble"; cat "$WORK/assemble-jmpcom.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKBGI.ASM >assemble-bgi.log 2>&1 ) \
    || { echo "FAIL: TLKBGI.ASM did not assemble"; cat "$WORK/assemble-bgi.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKMOD2.ASM >assemble-mod2-early.log 2>&1 ) \
    || { echo "FAIL: TLKMOD2.ASM did not assemble"; cat "$WORK/assemble-mod2-early.log"; exit 1; }
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKDD.ASM >assemble-dd.log 2>&1 ) \
    || { echo "FAIL: TLKDD.ASM did not assemble"; cat "$WORK/assemble-dd.log"; exit 1; }

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

# no-jmp-to-next: /T=com must OMIT the 3-byte "E9 rel16" JMP stub when
# 'start' already sits at code offset 0 (TLINKHI.ASM: 'start' is the very
# first label, so a JMP to the next instruction would be a pure no-op) and
# must still EMIT it when 'start' is not first (TLKJMPCOM.ASM: a 'helper'
# label precedes it).  check_run above already proved HELLO.COM runs
# correctly; this checks the actual byte layout both ways.
check_no_jmp_when_start_first() {
    local out="NOJMP.COM"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=com TLINKHI.RDF "$out" >"link-nojmp.log" 2>&1 ) \
        || { echo "FAIL: /T=com (no-jmp case) link failed"; cat "$WORK/link-nojmp.log"; FAIL=$((FAIL+1)); return; }
    local firstbyte
    firstbyte="$(od -An -tx1 -N1 "$WORK/$out" | tr -d ' ')"
    if [ "$firstbyte" = "e9" ]; then
        echo "FAIL: /T=com still emits JMP stub when start is at offset 0 (first byte E9)"
        FAIL=$((FAIL+1))
    else
        echo "PASS: /T=com omits JMP stub when start is at offset 0 (first byte $firstbyte)"
        PASS=$((PASS+1))
    fi
}

check_jmp_when_start_not_first() {
    local out="JMPCOM.COM"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=com TLKJMPCOM.RDF "$out" >"link-jmpcom.log" 2>&1 ) \
        || { echo "FAIL: /T=com (jmp-needed case) link failed"; cat "$WORK/link-jmpcom.log"; FAIL=$((FAIL+1)); return; }
    local firstbyte
    firstbyte="$(od -An -tx1 -N1 "$WORK/$out" | tr -d ' ')"
    if [ "$firstbyte" != "e9" ]; then
        echo "FAIL: /T=com omits JMP stub when start is NOT at offset 0 (first byte $firstbyte, want e9)"
        FAIL=$((FAIL+1))
        return
    fi
    local got
    got="$( cd "$WORK" && "$XT" run --max=5000000 "$out" 2>/dev/null | grep -vE '^Maximum instructions limit|^DOS conventional memory' )" || true
    local want=$'Hi from tlink!\r'
    if [ "$got" = "$want" ]; then
        echo "PASS: /T=com emits JMP stub when start is not at offset 0, and it runs correctly"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=com (jmp-needed case) output mismatch: got '$got'"
        FAIL=$((FAIL+1))
    fi
}

check_no_jmp_when_start_first
check_jmp_when_start_not_first

# /T=bgi2: link TLKBGI.RDF into a BGI v2.0 driver file and verify the
# byte-exact header structure per DOCS/BGI.MD §3 (magic, header blocks,
# name, 'CB' signature at image+0x0C) rather than just "it links".
check_bgi2() {
    local out="TLKBGI.BGI"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bgi2 /D=Test/1x1 TLKBGI.RDF "$out" >"link-bgi2.log" 2>&1 ) \
        || { echo "FAIL: /T=bgi2 link failed"; cat "$WORK/link-bgi2.log"; FAIL=$((FAIL+1)); return; }
    if [ ! -f "$WORK/$out" ]; then
        echo "FAIL: /T=bgi2 did not produce $out"
        cat "$WORK/link-bgi2.log"
        FAIL=$((FAIL+1))
        return
    fi
    local magic namelen name cb
    magic="$(od -An -tx1 -N4 "$WORK/$out" | tr -d ' ')"
    namelen="$(od -An -tu1 -j0x8A -N1 "$WORK/$out" | tr -d ' ')"
    name="$(dd if="$WORK/$out" bs=1 skip=139 count=6 2>/dev/null)"
    cb="$(od -An -tx1 -j0xAC -N2 "$WORK/$out" | tr -d ' ')"
    if [ "$magic" != "706b0808" ]; then
        echo "FAIL: /T=bgi2 wrong magic at offset 0 (got $magic, want 706b0808 = 'pk',08,08)"
        FAIL=$((FAIL+1))
    elif [ "$namelen" != "6" ]; then
        echo "FAIL: /T=bgi2 wrong namelen byte at 0x8A (got $namelen, want 6)"
        FAIL=$((FAIL+1))
    elif [ "$name" != "TLKBGI" ]; then
        echo "FAIL: /T=bgi2 wrong driver name at 0x8B (got '$name', want 'TLKBGI')"
        FAIL=$((FAIL+1))
    elif [ "$cb" != "4342" ]; then
        echo "FAIL: /T=bgi2 missing 'CB' signature at image+0x0C (file offset 0xAC; got $cb, want 4342)"
        FAIL=$((FAIL+1))
    else
        echo "PASS: /T=bgi2 -> TLKBGI.BGI has correct magic, header blocks, name, and CB signature"
        PASS=$((PASS+1))
    fi
}

check_bgi2

# /T=bgi2 requires no 'start' entry symbol at all (unlike /T=com/exe):
# TLKJMPCOM.RDF has no exported 'start' reachable the way /T=com needs it
# -- SmartLink links every module unconditionally in this mode -- so this
# must succeed, not fail.
check_bgi2_no_start_required() {
    local out="NOENTRY.BGI"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bgi2 TLKJMPCOM.RDF "$out" >"link-bgi2-noentry.log" 2>&1 ) \
        || { echo "FAIL: /T=bgi2 requires no start, but link failed"; cat "$WORK/link-bgi2-noentry.log"; FAIL=$((FAIL+1)); return; }
    if [ -f "$WORK/$out" ]; then
        echo "PASS: /T=bgi2 links successfully with no 'start' entry symbol"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=bgi2 (no start) did not produce $out"
        FAIL=$((FAIL+1))
    fi
}

check_bgi2_no_start_required

# /T=bin: like /T=com but no JMP stub ever, and no 'start' required at
# all.  TLKMOD2.RDF exports only 'getmsg' (no 'start'), which /T=com
# rejects but /T=bin must accept.  Checks the output has no stub (starts
# directly with TLKMOD2's own first instruction, not E9) and that /ORG=
# controls the absolute-address bias (default 0, vs /T=com's hardcoded
# 0x100) by comparing /T=bin /ORG=100 against /T=com byte-for-byte on
# TLINKHI.RDF (both put 'start' at offset 0, so /T=com also omits its
# stub -- the two outputs must then be identical).
check_bin_no_start_required() {
    local out="TLKMOD2.BIN"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bin TLKMOD2.RDF "$out" >"link-bin-noentry.log" 2>&1 ) \
        || { echo "FAIL: /T=bin requires no start, but link failed"; cat "$WORK/link-bin-noentry.log"; FAIL=$((FAIL+1)); return; }
    if [ ! -f "$WORK/$out" ]; then
        echo "FAIL: /T=bin (no start) did not produce $out"
        FAIL=$((FAIL+1))
        return
    fi
    local firstbyte
    firstbyte="$(od -An -tx1 -N1 "$WORK/$out" | tr -d ' ')"
    if [ "$firstbyte" = "e9" ]; then
        echo "FAIL: /T=bin emitted a JMP stub (first byte E9) -- /T=bin must never emit one"
        FAIL=$((FAIL+1))
    else
        echo "PASS: /T=bin links successfully with no 'start' entry symbol, no JMP stub"
        PASS=$((PASS+1))
    fi
}

check_bin_no_start_required

check_bin_org_default_zero() {
    local out1="ORGDEF.BIN" out2="ORG100.BIN" out3="ASCOM.COM"
    rm -f "$WORK/$out1" "$WORK/$out2" "$WORK/$out3"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bin TLINKHI.RDF "$out1" >/dev/null 2>&1 ) \
        || { echo "FAIL: /T=bin (default org) link failed"; FAIL=$((FAIL+1)); return; }
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bin /ORG=100 TLINKHI.RDF "$out2" >/dev/null 2>&1 ) \
        || { echo "FAIL: /T=bin /ORG=100 link failed"; FAIL=$((FAIL+1)); return; }
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=com TLINKHI.RDF "$out3" >/dev/null 2>&1 ) \
        || { echo "FAIL: /T=com (for comparison) link failed"; FAIL=$((FAIL+1)); return; }
    if cmp -s "$WORK/$out1" "$WORK/$out2"; then
        echo "FAIL: /T=bin default org produced the same output as /ORG=100 (should differ)"
        FAIL=$((FAIL+1))
    elif cmp -s "$WORK/$out2" "$WORK/$out3"; then
        echo "PASS: /T=bin /ORG=100 matches /T=com byte-for-byte (org defaults to 0, /ORG= overrides)"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=bin /ORG=100 does not match /T=com output"
        FAIL=$((FAIL+1))
    fi
}

check_bin_org_default_zero

# PatchMem4 (width=4 relocation) regression: TASM's 'dd target' emits a
# width=4 RELOC; TLINK must patch all 4 bytes as a real 32-bit sum
# (/ORG=100 + target's own nonzero in-module offset), not silently
# truncate to width=2 (PatchMem previously had no width=4 branch at all).
check_dd_width4_reloc() {
    local out="TLKDD.BIN"
    rm -f "$WORK/$out"
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=bin /ORG=100 TLKDD.RDF "$out" >"link-dd.log" 2>&1 ) \
        || { echo "FAIL: /T=bin (dd width=4 reloc) link failed"; cat "$WORK/link-dd.log"; FAIL=$((FAIL+1)); return; }
    if [ ! -f "$WORK/$out" ]; then
        echo "FAIL: /T=bin (dd width=4 reloc) did not produce $out"
        FAIL=$((FAIL+1))
        return
    fi
    local dword
    dword="$(od -An -tx1 -j7 -N4 "$WORK/$out" | tr -d ' ')"
    if [ "$dword" = "06010000" ]; then
        echo "PASS: TLINK patches a width=4 (DD-label) relocation correctly (0x100+6=0x106)"
        PASS=$((PASS+1))
    else
        echo "FAIL: TLINK width=4 relocation patched wrong (got $dword, want 06010000)"
        FAIL=$((FAIL+1))
    fi
}

check_dd_width4_reloc

# check_fail: link $1 with /T=com into $2, expecting tlink to exit nonzero,
# print $3 to its log, and produce NO output file -- guards against a
# symbol-resolution failure silently producing a broken binary instead of
# a fatal error.
check_fail() {
    local rdf="$1" out="$2" wantmsg="$3"
    rm -f "$WORK/$out"
    local rc=0
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=com "$rdf" "$out" >"link-$out.log" 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: linking $rdf was expected to fail but tlink exited 0"
        cat "$WORK/link-$out.log"
        FAIL=$((FAIL+1))
        return
    fi
    if [ -f "$WORK/$out" ]; then
        echo "FAIL: linking $rdf exited nonzero but still produced $out"
        FAIL=$((FAIL+1))
        return
    fi
    if ! grep -qF "$wantmsg" "$WORK/link-$out.log"; then
        echo "FAIL: linking $rdf did not report expected error '$wantmsg'"
        cat "$WORK/link-$out.log"
        FAIL=$((FAIL+1))
        return
    fi
    echo "PASS: linking $rdf fails cleanly ($wantmsg)"
    PASS=$((PASS+1))
}

check_fail TLKNOSTART.RDF NOSTART.COM "entry point 'start' not found"
check_fail TLKUNRES.RDF UNRES.COM "unresolved external: missing_symbol"

# check_fail_dup: link both TLKDUPA.RDF and TLKDUPB.RDF (both export 'start')
# with /T=com, expecting tlink to reject the duplicate GLOBAL symbol instead
# of silently linking whichever module was scanned first.
check_fail_dup() {
    local out="DUP.COM"
    rm -f "$WORK/$out"
    local rc=0
    ( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=com TLKDUPA.RDF TLKDUPB.RDF "$out" >"link-dup.log" 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: linking TLKDUPA.RDF+TLKDUPB.RDF was expected to fail but tlink exited 0"
        cat "$WORK/link-dup.log"
        FAIL=$((FAIL+1))
        return
    fi
    if [ -f "$WORK/$out" ]; then
        echo "FAIL: linking TLKDUPA.RDF+TLKDUPB.RDF exited nonzero but still produced $out"
        FAIL=$((FAIL+1))
        return
    fi
    if ! grep -qF "duplicate symbol 'start'" "$WORK/link-dup.log"; then
        echo "FAIL: linking TLKDUPA.RDF+TLKDUPB.RDF did not report a duplicate-symbol error"
        cat "$WORK/link-dup.log"
        FAIL=$((FAIL+1))
        return
    fi
    echo "PASS: linking duplicate 'start' definitions fails cleanly"
    PASS=$((PASS+1))
}

check_fail_dup

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

# --- multi-module /T=exe (small model) ---------------------------------------
# Exercises the paths a single-module link never does: CalculateLayoutSmall's
# Align16 (module 2 lands after module 1's non-paragraph-aligned code), a
# cross-module OFFS relocation into module 2's data, and TLINK's own DS-setup
# startup stub (the program does NOT set DS — the linker does).  Regression for
# the Align16 bug (v=17 -> 31 instead of 32) and the missing DS-setup stub.
echo "[tlink] linking /T=exe (multi-module small model) ..."
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKMAIN.ASM >assemble-main.log 2>&1 ) \
    && ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TLKMOD2.ASM >assemble-mod2.log 2>&1 ) \
    || { echo "FAIL: TLKMAIN/TLKMOD2 did not assemble"; FAIL=$((FAIL+1)); }
rm -f "$WORK/TLKTEST.EXE"
( cd "$WORK" && "$XT" run --max=$MAX TLINK.exe /T=exe TLKMAIN.RDF TLKMOD2.RDF TLKTEST.EXE >link-exe.log 2>&1 ) \
    || { echo "FAIL: /T=exe multi-module link failed"; cat "$WORK/link-exe.log"; FAIL=$((FAIL+1)); }
if [ -f "$WORK/TLKTEST.EXE" ]; then
    got="$( cd "$WORK" && "$XT" run --max=5000000 TLKTEST.EXE 2>/dev/null | grep -vE '^Maximum instructions limit|^DOS conventional memory' )" || true
    want=$'tlink-multi-ok\r'
    if [ "$got" = "$want" ]; then
        echo "PASS: /T=exe -> multi-module cross-reference + DS-setup runs correctly"
        PASS=$((PASS+1))
    else
        echo "FAIL: /T=exe -> multi-module output mismatch: got '$got'"
        FAIL=$((FAIL+1))
    fi
else
    echo "FAIL: /T=exe did not produce TLKTEST.EXE"
    FAIL=$((FAIL+1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
