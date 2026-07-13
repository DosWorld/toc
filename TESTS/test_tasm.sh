#!/bin/bash
# TESTS/test_tasm.sh — TASM byte-diff regression.
#
# Builds SRC/TASM/TASM.MOD via BOOT/TOC.EXE (single-process, no -c: CWD is
# the mount root, same pattern as SRC/TOC/Makefile), then assembles a set
# of .ASM files and byte-diffs the result against expected .RDF files.
#
# Two kinds of check:
#   1. Real-NASM oracles (SRC/LIB/SYS.ASM, EMS.ASM, DETECT.ASM): the
#      authoritative correctness signal per DOCS/TASM_PLAN.MD -- byte-for-
#      byte equality against a real assembler's output, not a synthetic
#      expectation. DETECT.ASM is the only .text-only oracle (no SECTION
#      .data) -- it caught a real bug (SRC/LIB/RDOFF.MOD's RdfWriteTo
#      skipped the .data segment header entirely when dataLen=0, but real
#      NASM always emits it) that SYS.ASM/EMS.ASM's real .data sections
#      never exercised.
#   2. TESTS/FIX/*.ASM fixtures (TSTRUC, TEXTERN, TMULDIV, TSHIFT, TJCC2,
#      TNOOP4, TREP, TBSS, ...) PLUS SRC/LIB/WINCB.ASM, SRC/LIB/KMOUSE.ASM,
#      and SRC/LIB/SCREEN.ASM: synthetic, isolated coverage for constructs
#      the real oracle files don't exercise thoroughly (STRUC field-offset/
#      size arithmetic, EXTERN/IMPORT cross-module relocations, IMUL/DIV/
#      IDIV F6/F7-group encoding, WINCB's stack-argument LES/RETF-imm16
#      pattern, KMOUSE's direct-memory MOV [label],AL / stack-argument
#      byte-flag pattern, TBSS's SECTION .bss RESB/RESW/RESD + RDFREC_BSS
#      + BSS-target RELOC coverage, SCREEN's CALL FAR cross-module
#      SYSTEM.Seg*/KMouse_Mouse* relocations and LDS encoding). No
#      independent NASM oracle exists for these (or: the local nasm build
#      used to generate them lacked the rdf backend -- see TMULDIV), so the
#      expected .RDF is TASM's own previously-verified output -- a
#      regression guard (catches TASM changing its own behavior), not an
#      independent correctness proof. WINCB.RDF/KMOUSE.RDF/SCREEN.RDF are
#      checked in alongside the LIBDIR real oracles for build convenience
#      (all three live in SRC/LIB, get merged into OBERON.OM, and are
#      covered by `make regen-asm` too) but are self-consistency baselines
#      like the FIXDIR fixtures, not real NASM oracles -- re-derive the
#      expected .RDF by hand-inspecting the output (see the fixture's .ASM
#      comments) whenever it changes.
#
# Pre-requisites:
#   - BOOT/TOC.EXE      (bootstrap DOS binary, immutable)
#   - BIN/OBERON.OM     (runtime library archive, supplies Rdoff/LogErr/etc.)
#   - xt emulator in PATH or $XT
#
# Run from oberonc/:  bash TESTS/test_tasm.sh
# Exits 0 on success, 1 on failure.  Skips if xt is unavailable.

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$(pwd)"
BOOTOC="$ROOT/BOOT/TOC.EXE"
BINOM="$ROOT/BIN/OBERON.OM"
TASMDIR="$ROOT/SRC/TASM"
LIBDIR="$ROOT/SRC/LIB"
FIXDIR="$ROOT/TESTS/FIX"
XT="${XT:-xt}"
MAX=300000000

if ! command -v "$XT" >/dev/null 2>&1; then
    echo "SKIP: xt emulator not found — set XT=/path/to/xt to enable the TASM test"
    exit 0
fi

WORK="$(mktemp -d "$ROOT/TMP/tasm-work.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$ROOT/TMP"
cp "$BOOTOC" "$WORK/TOC_BOOT.EXE"
cp "$BINOM" "$WORK/OBERON.OM"
cp "$TASMDIR"/*.MOD "$WORK/"
cp "$LIBDIR/SYS.ASM" "$LIBDIR/SYS.RDF" "$WORK/"
cp "$LIBDIR/EMS.ASM" "$LIBDIR/EMS.RDF" "$WORK/"
cp "$LIBDIR/DETECT.ASM" "$LIBDIR/DETECT.RDF" "$WORK/"
cp "$LIBDIR/WINCB.ASM" "$LIBDIR/WINCB.RDF" "$WORK/"
cp "$LIBDIR/KMOUSE.ASM" "$LIBDIR/KMOUSE.RDF" "$WORK/"
cp "$LIBDIR/SCREEN.ASM" "$LIBDIR/SCREEN.RDF" "$WORK/"
cp "$FIXDIR/TSTRUC.ASM" "$FIXDIR/TSTRUC.RDF" "$WORK/"
cp "$FIXDIR/TEXTERN.ASM" "$FIXDIR/TEXTERN.RDF" "$WORK/"
cp "$FIXDIR/TMULDIV.ASM" "$FIXDIR/TMULDIV.RDF" "$WORK/"
cp "$FIXDIR/TSHIFT.ASM" "$FIXDIR/TSHIFT.RDF" "$WORK/"
cp "$FIXDIR/TJCC2.ASM" "$FIXDIR/TJCC2.RDF" "$WORK/"
cp "$FIXDIR/TNOOP4.ASM" "$FIXDIR/TNOOP4.RDF" "$WORK/"
cp "$FIXDIR/TREP.ASM" "$FIXDIR/TREP.RDF" "$WORK/"
cp "$FIXDIR/TBADIF.ASM" "$WORK/"
cp "$FIXDIR/TBSS.ASM" "$FIXDIR/TBSS.RDF" "$WORK/"
cp "$FIXDIR/TBADRES.ASM" "$WORK/"

echo "[tasm] building TASM.exe via BOOT/TOC.EXE ..."
( cd "$WORK" && "$XT" run --max=$MAX TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TASM.MOD >build.log 2>&1 ) \
    || { echo "FAIL: TASM.exe did not build"; cat "$WORK/build.log"; exit 1; }
[ -f "$WORK/TASM.exe" ] || { echo "FAIL: TASM.exe not produced"; cat "$WORK/build.log"; exit 1; }

PASS=0; FAIL=0

# check_one: assemble $1 (an .asm already staged in $WORK) and byte-diff
# the result against $2, an expected .rdf resolved from $3 (the directory
# the expectation file lives in -- LIBDIR for the real-NASM oracles,
# FIXDIR for the synthetic TASM-self-consistency fixtures).
check_one() {
    local asm="$1" rdf="$2" expectdir="$3"
    rm -f "$WORK/$rdf"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe "$asm" >"assemble-$asm.log" 2>&1 ) || true
    if [ ! -f "$WORK/$rdf" ]; then
        echo "FAIL: $asm did not produce $rdf"
        cat "$WORK/assemble-$asm.log"
        FAIL=$((FAIL+1))
        return
    fi
    if cmp -s "$WORK/$rdf" "$expectdir/$rdf"; then
        echo "PASS: $asm -> $rdf byte-identical to expected"
        PASS=$((PASS+1))
    else
        local d
        d=$(cmp -l "$WORK/$rdf" "$expectdir/$rdf" 2>&1 | wc -l | tr -d ' ' || true)
        echo "FAIL: $asm -> $rdf differs from expected ($d bytes differ)"
        FAIL=$((FAIL+1))
    fi
}

# check_fails: assemble $1 and expect a NON-zero exit plus the diagnostic
# substring $2 in its log -- for fixtures that must be a fatal error, not
# a byte-diff (malformed-input hardening: a missing diagnostic here means
# TASM silently accepted bad input instead of rejecting it).
check_fails() {
    local asm="$1" substr="$2" rc=0
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe "$asm" >"assemble-$asm.log" 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $asm assembled successfully, expected a fatal error"
        FAIL=$((FAIL+1))
    elif grep -q -- "$substr" "$WORK/assemble-$asm.log"; then
        echo "PASS: $asm -> fatal error as expected ('$substr')"
        PASS=$((PASS+1))
    else
        echo "FAIL: $asm failed but diagnostic lacks '$substr'"
        cat "$WORK/assemble-$asm.log"
        FAIL=$((FAIL+1))
    fi
}

check_one SYS.ASM SYS.RDF "$LIBDIR"
check_one EMS.ASM EMS.RDF "$LIBDIR"
check_one DETECT.ASM DETECT.RDF "$LIBDIR"
check_one WINCB.ASM WINCB.RDF "$LIBDIR"
check_one KMOUSE.ASM KMOUSE.RDF "$LIBDIR"
check_one SCREEN.ASM SCREEN.RDF "$LIBDIR"
check_one TSTRUC.ASM TSTRUC.RDF "$FIXDIR"
check_one TEXTERN.ASM TEXTERN.RDF "$FIXDIR"
check_one TMULDIV.ASM TMULDIV.RDF "$FIXDIR"
check_one TSHIFT.ASM TSHIFT.RDF "$FIXDIR"
check_one TJCC2.ASM TJCC2.RDF "$FIXDIR"
check_one TNOOP4.ASM TNOOP4.RDF "$FIXDIR"
check_one TREP.ASM TREP.RDF "$FIXDIR"
check_fails TBADIF.ASM "%ifdef without matching %endif"
check_one TBSS.ASM TBSS.RDF "$FIXDIR"
check_fails TBADRES.ASM "RESB/RESW/RESD only valid in SECTION .bss"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
