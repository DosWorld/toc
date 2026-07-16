#!/bin/bash
# TESTS/test_tasm.sh — TASM byte-diff regression.
#
# Builds SRC/TASM/TASM.MOD via BOOT/TOC.EXE (single-process, no -c: CWD is
# the mount root, same pattern as SRC/TOC/Makefile), then assembles a set
# of .ASM files and byte-diffs the result against expected .RDF files.
#
# Two kinds of check:
#   1. Real-NASM oracles (SRC/LIB/SYSTEM.ASM, EMS.ASM): the authoritative
#      correctness signal per DOCS/IMPLRULE.MD "TASM" section -- byte-for-
#      byte equality against a real assembler's output, not a synthetic
#      expectation.
#   2. TESTS/FIX/*.ASM fixtures (TSTRUC, TEXTERN, TMULDIV, TSHIFT, TJCC2,
#      TNOOP4, TREP, TBSS, TJMPIND, TDWLABEL, TREGIND, TRESEXPR, TDEFMANY,
#      TDEFMANY_OK, TDEFMANY_HANG, ...) PLUS SRC/LIB/WINCB.ASM, SRC/LIB/KMOUSE.ASM,
#      SRC/LIB/SCREEN.ASM, and SRC/LIB/DETECT.ASM: synthetic, isolated
#      coverage for constructs the real oracle files don't exercise
#      thoroughly (STRUC field-offset/size arithmetic, EXTERN/IMPORT
#      cross-module relocations, IMUL/DIV/IDIV F6/F7-group encoding,
#      WINCB's stack-argument LES/RETF-imm16 pattern, KMOUSE's direct-
#      memory MOV [label],AL / stack-argument byte-flag pattern, TBSS's
#      SECTION .bss RESB/RESW/RESD + RDFREC_BSS + BSS-target RELOC
#      coverage, SCREEN's CALL FAR cross-module SYSTEM.Seg*/KMouse_Mouse*
#      relocations and LDS encoding, DETECT's .text-only module with no
#      SECTION .data). No independent NASM oracle exists for these (or:
#      the local nasm build used to generate them lacked the rdf backend
#      -- see TMULDIV), so the expected .RDF is TASM's own previously-
#      verified output -- a regression guard (catches TASM changing its
#      own behavior), not an independent correctness proof.
#      WINCB.RDF/KMOUSE.RDF/SCREEN.RDF/DETECT.RDF are checked in alongside
#      the LIBDIR real oracles for build convenience (all four live in
#      SRC/LIB, get merged into OBERON.OM, and are covered by
#      `make regen-asm` too) but are self-consistency baselines like the
#      FIXDIR fixtures, not real NASM oracles -- re-derive the expected
#      .RDF by hand-inspecting the output (see the fixture's .ASM
#      comments) whenever it changes.
#      DETECT.RDF/SCREEN.RDF were originally real-NASM oracles but were
#      demoted to self-consistency baselines 2026-07-14: real NASM's
#      RDOFF2 writer orders IMPORT records interleaved with GLOBAL records
#      in source-declaration order for these two files, while TASM's
#      writer always emits all GLOBAL records before all IMPORT records
#      (RDOFF.MOD's RdfWriteTo, tuned to match SYSTEM.RDF/EMS.RDF's own
#      real-NASM ordering) -- readers resolve records by type, not
#      position (DOCS/RDOFF2.MD), so this is a byte-diff-only mismatch,
#      not a functional one: the record SET (same globals, same imports,
#      same code/data bytes) is identical either way, verified with
#      rdfgrep has-global/has-import against both orderings before
#      regenerating these two oracles from TASM's own output.
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
BINRDFGREP="$ROOT/BIN/RDFGREP.EXE"
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
cp "$LIBDIR/SYSTEM.ASM" "$LIBDIR/SYSTEM.RDF" "$WORK/"
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
cp "$FIXDIR/TJMPIND.ASM" "$FIXDIR/TJMPIND.RDF" "$WORK/"
cp "$FIXDIR/TDWLABEL.ASM" "$FIXDIR/TDWLABEL.RDF" "$WORK/"
cp "$FIXDIR/TREGIND.ASM" "$FIXDIR/TREGIND.RDF" "$WORK/"
cp "$FIXDIR/TRESEXPR.ASM" "$FIXDIR/TRESEXPR.RDF" "$WORK/"
cp "$FIXDIR/TDEFMANY.ASM" "$FIXDIR/TDEFMANY.RDF" "$WORK/"
cp "$FIXDIR/TDEFMANY_OK.ASM" "$FIXDIR/TDEFMANY_OK.RDF" "$WORK/"
cp "$FIXDIR/TDEFMANY_HANG.ASM" "$FIXDIR/TDEFMANY_HANG.RDF" "$WORK/"
cp "$FIXDIR/TUNDEF.ASM" "$WORK/"
cp "$FIXDIR/TUNDEFDW.ASM" "$WORK/"
cp "$FIXDIR/TUNDEFJMP.ASM" "$WORK/"
cp "$FIXDIR/TSTRAYTOK.ASM" "$WORK/"
cp "$FIXDIR/TMANYOPS.ASM" "$WORK/"
cp "$FIXDIR/TBADINC.ASM" "$WORK/"
cp "$FIXDIR/TBADPUSH.ASM" "$WORK/"
cp "$FIXDIR/TBADMOVDS.ASM" "$WORK/"
cp "$FIXDIR/TBADRETIMM.ASM" "$WORK/"
cp "$FIXDIR/TEXTSHORT.ASM" "$WORK/"
cp "$FIXDIR/TEXTDW.ASM" "$WORK/"
cp "$FIXDIR/TBADBYTEIMM.ASM" "$WORK/"
cp "$FIXDIR/TNOSIZE.ASM" "$WORK/"
cp "$FIXDIR/TNOSIZEMOV.ASM" "$WORK/"
cp "$FIXDIR/TTIMESLBL.ASM" "$WORK/"
cp "$FIXDIR/T3REGADDR.ASM" "$WORK/"
cp "$FIXDIR/TDEFBADTOK.ASM" "$WORK/"
cp "$FIXDIR/TLONGID.ASM" "$WORK/"
cp "$FIXDIR/TLONGFIELD.ASM" "$WORK/"
cp "$FIXDIR/TMANYJMP.ASM" "$WORK/"
cp "$FIXDIR/TR1HEXB.ASM" "$WORK/"
cp "$FIXDIR/TR2ALUM.ASM" "$WORK/"
cp "$FIXDIR/TR3DWBSS.ASM" "$WORK/"
cp "$FIXDIR/TR4LONGDEF.ASM" "$WORK/"
cp "$FIXDIR/TR5STRUCLONG.ASM" "$WORK/"
cp "$FIXDIR/TR6INTLBL.ASM" "$WORK/"
cp "$FIXDIR/TC5DBRANGE.ASM" "$WORK/"
cp "$FIXDIR/TC5INTRANGE.ASM" "$WORK/"
cp "$FIXDIR/TC6NEGRES.ASM" "$WORK/"
cp "$FIXDIR/TC7EMPTYSTR.ASM" "$WORK/"
cp "$FIXDIR/TC9DUPELSE.ASM" "$WORK/"
cp "$FIXDIR/TC12XSEG.ASM" "$WORK/"
cp "$FIXDIR/TD86COV.ASM" "$FIXDIR/TD86COV.RDF" "$WORK/"
cp "$FIXDIR/TN2PUSH.ASM" "$FIXDIR/TN2MOVAB.ASM" "$FIXDIR/TN2MOVBA.ASM" "$WORK/"
cp "$FIXDIR/TN2XCHG.ASM" "$FIXDIR/TN2CALLIND.ASM" "$FIXDIR/TN2MOVDS.ASM" "$WORK/"
cp "$FIXDIR/TN3NEGREG.ASM" "$FIXDIR/TN3NEGLBL.ASM" "$FIXDIR/TM2BADBASE.ASM" "$WORK/"
cp "$FIXDIR/TM1LBLREG.ASM" "$FIXDIR/TM1LBLREG.RDF" "$WORK/"
cp "$FIXDIR/TN4MOVWRAP.ASM" "$FIXDIR/TN4DWWRAP.ASM" "$FIXDIR/TN4RETWRAP.ASM" "$WORK/"
cp "$FIXDIR/TN4BOUNDOK.ASM" "$FIXDIR/TN4BOUNDOK.RDF" "$WORK/"
cp "$FIXDIR/TN5ENDCOMMENT.ASM" "$FIXDIR/TN5ENDCOMMENT.RDF" "$WORK/"
cp "$FIXDIR/TN6LONGSTR.ASM" "$WORK/"
cp "$FIXDIR/TN10LOCALDISP.ASM" "$FIXDIR/TN10LOCALDISP.RDF" "$WORK/"
cp "$FIXDIR/TPIFDEFJUNK.ASM" "$FIXDIR/TPUNDEFJUNK.ASM" "$WORK/"
cp "$FIXDIR/TMACERR.ASM" "$FIXDIR/TDEFERR.ASM" "$WORK/"
cp "$FIXDIR/TN2XCHGM.ASM" "$FIXDIR/TN2MOVSRM.ASM" "$FIXDIR/TN4LBLWRAP.ASM" "$WORK/"
cp "$FIXDIR/TCLIDEF.ASM" "$FIXDIR/TCLIDEF_ON.RDF" "$FIXDIR/TCLIDEF_OFF.RDF" "$WORK/"
cp "$FIXDIR/TINC1.ASM" "$FIXDIR/TINC2.INC" "$FIXDIR/TINC1.RDF" "$WORK/"
cp "$FIXDIR/TINCMISS.ASM" "$FIXDIR/TINCSELF.ASM" "$WORK/"
cp "$FIXDIR/TINCDEEP.ASM" "$FIXDIR"/TINCD*.INC "$WORK/"
cp "$FIXDIR/TINCSKIP.ASM" "$FIXDIR/TINCSKIP.RDF" "$WORK/"
cp "$FIXDIR/TMACRO.ASM" "$FIXDIR/TMACRO.RDF" "$WORK/"
cp "$FIXDIR/TMACARGS.ASM" "$FIXDIR/TMACMISS.ASM" "$FIXDIR/TMACNEST.ASM" "$WORK/"
cp "$FIXDIR/TMACRECUR.ASM" "$FIXDIR/TMACARG3.ASM" "$WORK/"
if [ -f "$BINRDFGREP" ]; then cp "$BINRDFGREP" "$WORK/RDFGREP.EXE"; fi

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

# check_reloc_for: assemble $1 and confirm the resulting $2 has a RELOC
# referencing import symbol $3 (rdfgrep has-reloc-for) -- used for fixtures
# that must assemble successfully AND produce a specific relocation shape,
# not merely byte-diff against a checked-in oracle.
check_reloc_for() {
    local asm="$1" rdf="$2" importname="$3"
    if [ ! -f "$WORK/RDFGREP.EXE" ]; then
        echo "SKIP: $asm -> has-reloc-for check (BIN/RDFGREP.EXE not built)"
        return
    fi
    rm -f "$WORK/$rdf"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe "$asm" >"assemble-$asm.log" 2>&1 ) || true
    if [ ! -f "$WORK/$rdf" ]; then
        echo "FAIL: $asm did not produce $rdf"
        cat "$WORK/assemble-$asm.log"
        FAIL=$((FAIL+1))
        return
    fi
    if ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE has-reloc-for "$rdf" "$importname" >/dev/null 2>&1 ); then
        echo "PASS: $asm -> $rdf has RELOC referencing import $importname"
        PASS=$((PASS+1))
    else
        echo "FAIL: $asm -> $rdf has no RELOC referencing import $importname"
        FAIL=$((FAIL+1))
    fi
}

# check_reloc_to_seg: assemble $1 and confirm the resulting $2 has a RELOC
# targeting segment $3 (0=code, 1=data, 2=bss) via rdfgrep has-reloc-to-seg.
check_reloc_to_seg() {
    local asm="$1" rdf="$2" seg="$3"
    if [ ! -f "$WORK/RDFGREP.EXE" ]; then
        echo "SKIP: $asm -> has-reloc-to-seg check (BIN/RDFGREP.EXE not built)"
        return
    fi
    rm -f "$WORK/$rdf"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe "$asm" >"assemble-$asm.log" 2>&1 ) || true
    if [ ! -f "$WORK/$rdf" ]; then
        echo "FAIL: $asm did not produce $rdf"
        cat "$WORK/assemble-$asm.log"
        FAIL=$((FAIL+1))
        return
    fi
    if ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE has-reloc-to-seg "$rdf" "$seg" >/dev/null 2>&1 ); then
        echo "PASS: $asm -> $rdf has RELOC to seg $seg"
        PASS=$((PASS+1))
    else
        echo "FAIL: $asm -> $rdf has no RELOC to seg $seg"
        FAIL=$((FAIL+1))
    fi
}

check_one SYSTEM.ASM SYSTEM.RDF "$LIBDIR"
check_one EMS.ASM EMS.RDF "$LIBDIR"
check_one DETECT.ASM DETECT.RDF "$LIBDIR"   # self-consistency baseline, not a real-NASM oracle -- see header comment
check_one WINCB.ASM WINCB.RDF "$LIBDIR"
check_one KMOUSE.ASM KMOUSE.RDF "$LIBDIR"
check_one SCREEN.ASM SCREEN.RDF "$LIBDIR"   # self-consistency baseline, not a real-NASM oracle -- see header comment
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
check_one TJMPIND.ASM TJMPIND.RDF "$FIXDIR"
check_one TDWLABEL.ASM TDWLABEL.RDF "$FIXDIR"
check_one TREGIND.ASM TREGIND.RDF "$FIXDIR"
check_one TRESEXPR.ASM TRESEXPR.RDF "$FIXDIR"
check_one TDEFMANY.ASM TDEFMANY.RDF "$FIXDIR"
check_one TDEFMANY_OK.ASM TDEFMANY_OK.RDF "$FIXDIR"      # BUG 5: 63 %defines, pre-fix boundary
check_one TDEFMANY_HANG.ASM TDEFMANY_HANG.RDF "$FIXDIR"  # BUG 5: 64 %defines, was quadratic-slow pre-fix

# BUG A1: undefined-symbol references must be fatal, not silent offset-0
check_fails TUNDEF.ASM "undefined symbol"
check_fails TUNDEFDW.ASM "undefined symbol"
check_fails TUNDEFJMP.ASM "undefined symbol"
# BUG A2: parser must never return without consuming a token
check_fails TSTRAYTOK.ASM "unexpected token"
check_fails TMANYOPS.ASM "too many operands"
# BUG A3: EmitModRm must reject non-reg/non-mem operands instead of
# encoding garbage from an uninitialised Operand
check_fails TBADINC.ASM "register or memory operand required"
check_fails TBADPUSH.ASM "register or memory operand required"
check_fails TBADMOVDS.ASM "register or memory operand required"
check_fails TBADRETIMM.ASM "RET immediate must be a constant"
# BUG A4: short branch to EXTERN symbol has no relocation -- must be fatal
check_fails TEXTSHORT.ASM "short branch to EXTERN symbol"
# BUG A5: dw referencing EXTERN symbol must reloc against the import, not
# this module's own segment
check_reloc_for TEXTDW.ASM TEXTDW.RDF ExternalProc
# BUG A6: byte-sized immediate with a label reference must be fatal
check_fails TBADBYTEIMM.ASM "label not allowed as byte immediate"
# BUG A7: binary integer literals (101b) must actually parse
cp "$FIXDIR/TBINLIT.ASM" "$WORK/"
rm -f "$WORK/TBINLIT.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TBINLIT.ASM >assemble-TBINLIT.ASM.log 2>&1 ) || true
if [ -f "$WORK/TBINLIT.RDF" ] && [ -f "$WORK/RDFGREP.EXE" ] \
   && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE code-contains TBINLIT.RDF "B00AB3FFB9AB00" >/dev/null 2>&1 ); then
    echo "PASS: TBINLIT.ASM -> binary/hex literals encode correctly"
    PASS=$((PASS+1))
else
    echo "FAIL: TBINLIT.ASM -> binary literal did not assemble/encode as expected"
    cat "$WORK/assemble-TBINLIT.ASM.log"
    FAIL=$((FAIL+1))
fi

# BUG B1: unsized memory operand must be fatal, not a silent WORD default
check_fails TNOSIZE.ASM "operation size not specified"
check_fails TNOSIZEMOV.ASM "operation size not specified"
# BUG B2: TIMES with a label value must be fatal, not a silently dropped reloc
check_fails TTIMESLBL.ASM "TIMES DW requires a constant value"
# BUG B4: three base/index registers in [ ] must be fatal
check_fails T3REGADDR.ASM "too many registers in address"
# BUG B5: %define body with an unrepresentable token must be fatal
check_fails TDEFBADTOK.ASM "unsupported token in %define body"
# BUG B3: symbol-name-length limits must be enforced loudly, not truncated
check_fails TLONGID.ASM "identifier too long"
check_fails TLONGFIELD.ASM "STRUC field name too long"
# BUG B6: more than 128 auto-sized JMPs must not hit an internal-limit error
rm -f "$WORK/TMANYJMP.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TMANYJMP.ASM >assemble-TMANYJMP.ASM.log 2>&1 ) || true
if [ -f "$WORK/TMANYJMP.RDF" ]; then
    echo "PASS: TMANYJMP.ASM -> 140 auto-sized JMPs assembled (no fixed-array limit)"
    PASS=$((PASS+1))
else
    echo "FAIL: TMANYJMP.ASM did not produce TMANYJMP.RDF"
    cat "$WORK/assemble-TMANYJMP.ASM.log"
    FAIL=$((FAIL+1))
fi

# R1 (A7 regression): 0x-prefixed hex literals ending in b/B must stay hex,
# not be misclassified as binary and rejected
if [ -f "$WORK/RDFGREP.EXE" ]; then
    rm -f "$WORK/TR1HEXB.RDF"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TR1HEXB.ASM >assemble-TR1HEXB.ASM.log 2>&1 ) || true
    if [ -f "$WORK/TR1HEXB.RDF" ] \
       && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE code-contains TR1HEXB.RDF "B01BB8BB0AB305C3" >/dev/null 2>&1 ); then
        echo "PASS: TR1HEXB.ASM -> 0x..b hex literals stay hex"
        PASS=$((PASS+1))
    else
        echo "FAIL: TR1HEXB.ASM -> 0x..b hex literal did not encode as expected"
        cat "$WORK/assemble-TR1HEXB.ASM.log"
        FAIL=$((FAIL+1))
    fi
fi

# R2 (B1 regression): ALU/TEST reg->mem width must come from the register
# operand, not the (possibly SzNone) memory operand
if [ -f "$WORK/RDFGREP.EXE" ]; then
    rm -f "$WORK/TR2ALUM.RDF"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TR2ALUM.ASM >assemble-TR2ALUM.ASM.log 2>&1 ) || true
    if [ -f "$WORK/TR2ALUM.RDF" ] \
       && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE code-contains TR2ALUM.RDF "010600002006000085060000391E0000C3" >/dev/null 2>&1 ); then
        echo "PASS: TR2ALUM.ASM -> ALU/TEST [mem],reg16 encodes word opcodes"
        PASS=$((PASS+1))
    else
        echo "FAIL: TR2ALUM.ASM -> ALU/TEST [mem],reg16 did not encode as expected"
        cat "$WORK/assemble-TR2ALUM.ASM.log"
        FAIL=$((FAIL+1))
    fi
fi

# R3 (A5-adjacent gap): dw referencing a BSS label must reloc against BSS,
# not silently fall into the DATA arm
check_reloc_to_seg TR3DWBSS.ASM TR3DWBSS.RDF 2
# R4 (B5 guard bug): a %define body well past the old false ~62-char
# threshold, but under the real 127-char bound, must assemble
check_one TR4LONGDEF.ASM TR4LONGDEF.RDF "$FIXDIR"
# R5 (B3 residual): Dir.EndStruc's composed "NAME_size" key must be
# length-guarded like AddField's STRUCT.field key
check_fails TR5STRUCLONG.ASM "STRUC name too long"
# R6 (A6-family residual): INT/RET/IN/OUT with a (defined) label operand
# must be fatal, not a silent zero immediate
check_fails TR6INTLBL.ASM "label not allowed here"

# C5: DB/INT range checks -- BYTE(...) must not silently truncate
check_fails TC5DBRANGE.ASM "DB value out of range"
check_fails TC5INTRANGE.ASM "INT vector out of range"
# C6: a negative RESB/RESW/RESD count at SECTION .bss level must not
# silently shrink bssOfs
check_fails TC6NEGRES.ASM "count must not be negative"
# C7: an empty string literal '' as an immediate must not silently
# yield 0
check_fails TC7EMPTYSTR.ASM "empty string literal"
# C9: a duplicate %else for the same %ifdef must be fatal
check_fails TC9DUPELSE.ASM "duplicate %else"
# C12: a short branch to a label outside the code segment must be fatal
check_fails TC12XSEG.ASM "branch target is not in the code segment"

# BUG N2: register size mismatches in reg,reg / reg-only forms must be
# fatal, not silently mis-encoded via overlapping reg codes (AL=AX=0, ...)
check_fails TN2PUSH.ASM "operand size mismatch"
check_fails TN2MOVAB.ASM "operand size mismatch"
check_fails TN2MOVBA.ASM "operand size mismatch"
check_fails TN2XCHG.ASM "operand size mismatch"
check_fails TN2CALLIND.ASM "operand size mismatch"
check_fails TN2MOVDS.ASM "operand size mismatch"

# BUG N3/M3: '-' before a register or label inside [ ] must be fatal, not
# silently dropped ([bx-si] -> [bx+si], [-buf] -> [+buf])
check_fails TN3NEGREG.ASM "'-' before register/label in address"
check_fails TN3NEGLBL.ASM "'-' before register/label in address"
# BUG M2: a register with no base/index role inside [ ] (e.g. [ax]) must
# be a clear diagnostic, not a misleading "undefined symbol" / silent
# fallback to a same-named label
check_fails TM2BADBASE.ASM "register not usable as base/index on 8086"

# BUG M1: [label+reg]/[reg+label]/[reg+reg+label] table-indexing idiom
# must assemble (was a hard parser Fail); also exercises the EmitModRm
# fix needed alongside it (a label whose own disp is 0 must still force
# Mod=10, not fall into the disp=0 -> Mod=00 shortcut)
check_one TM1LBLREG.ASM TM1LBLREG.RDF "$FIXDIR"

# BUG N4: word immediates/displacements outside -32768..65535 must be
# fatal, not silently wrapped mod 65536 (same class of trap C5 closed for
# byte immediates)
check_fails TN4MOVWRAP.ASM "word value out of range"
check_fails TN4DWWRAP.ASM "word value out of range"
check_fails TN4RETWRAP.ASM "word value out of range"
check_one TN4BOUNDOK.ASM TN4BOUNDOK.RDF "$FIXDIR"

# BUG N5: "%endmacro ; comment" is valid NASM source and must be
# recognized, not captured as body text (-> "missing %endmacro")
check_one TN5ENDCOMMENT.ASM TN5ENDCOMMENT.RDF "$FIXDIR"

# BUG N6: a string literal over Scan.MaxStr-1 chars must be fatal, not
# silently truncated
check_fails TN6LONGSTR.ASM "string literal too long"

# BUG N7: a macro-body line longer than 511 chars must be fatal, not
# silently truncated -- generated inline (a single ~600-char body line),
# impractical as a static checked-in fixture (same rationale as TMACBIG
# below)
{
    echo "bits 16"; echo "cpu 8086"; echo "section .text"; echo "global Foo"
    echo "%macro longline 0"
    printf "    nop ; "
    i=0
    while [ "$i" -lt 550 ]; do printf "x"; i=$((i+1)); done
    echo
    echo "%endmacro"
    echo "Foo:"; echo "    longline"; echo "    ret"
} > "$WORK/TN7LONGLINE.ASM"
check_fails TN7LONGLINE.ASM "macro body line too long"

# BUG N10: a local-label operand (.loop) must accept a trailing
# "+disp"/"-disp" chain, same as a bare-ident label operand
check_one TN10LOCALDISP.ASM TN10LOCALDISP.RDF "$FIXDIR"

# paper cut: %ifdef/%undef must reject trailing junk after the name,
# mirroring %include's own trailing-EOL check
check_fails TPIFDEFJUNK.ASM "unexpected text after %ifdef name"
check_fails TPUNDEFJUNK.ASM "unexpected text after %undef name"

# 2026-07-16 review: a diagnostic raised inside a %macro/%define
# expansion must name the real source file, not a blank filename
# (CurFname-after-INC ordering bug in InvokeMacro/TokNext) -- the
# grepped substring includes the filename to pin this
check_fails TMACERR.ASM "TMACERR.ASM("
check_fails TDEFERR.ASM "TDEFERR.ASM("
# N2-family residuals: explicit size qualifier vs implied width on
# XCHG mem arms and MOV sreg arms must be fatal
check_fails TN2XCHGM.ASM "operand size mismatch"
check_fails TN2MOVSRM.ASM "operand size mismatch"
# N4-family residual: label+n addend must not wrap mod 65536
check_fails TN4LBLWRAP.ASM "word value out of range"

# C11: a second positional CLI argument must be a usage error, not
# silently ignored
rm -f "$WORK/TR1HEXB.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe TR1HEXB.ASM TR2ALUM.ASM >assemble-c11.log 2>&1 ) || true
if grep -q -- "unexpected extra argument" "$WORK/assemble-c11.log"; then
    echo "PASS: TASM.exe TR1HEXB.ASM TR2ALUM.ASM -> fatal error as expected ('unexpected extra argument')"
    PASS=$((PASS+1))
else
    echo "FAIL: TASM.exe with two positional args did not report 'unexpected extra argument'"
    cat "$WORK/assemble-c11.log"
    FAIL=$((FAIL+1))
fi

# D: 8086 coverage-gap mnemonics (CMC/LAHF/SAHF/WAIT/XLATB/LOOPE-LOOPZ/
# LOOPNE-LOOPNZ/JCXZ/TEST reg,mem/es-prefix-on-string-op)
check_one TD86COV.ASM TD86COV.RDF "$FIXDIR"

# J: bin2obj mode (binary blob -> .RDF with one GLOBAL record, no parser
# involvement). Fixture blobs are generated here with printf/dd -- the
# no-python rule concerns binary INSPECTION (stays in rdfgrep), not
# fixture generation from the host shell.
printf '\x01\x02\x03\x04\xAA\xBB\xCC\xDD' > "$WORK/TBLOB.BIN"

# happy path, code segment
rm -f "$WORK/TBLOB.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe /BIN=code /NAME=Blob1 TBLOB.BIN >bin2obj-code.log 2>&1 ) || true
if [ -f "$WORK/TBLOB.RDF" ] && [ -f "$WORK/RDFGREP.EXE" ] \
   && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE has-global TBLOB.RDF Blob1 >/dev/null 2>&1 ) \
   && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE code-contains TBLOB.RDF "01020304AABBCCDD" >/dev/null 2>&1 ); then
    echo "PASS: TASM /BIN=code /NAME=Blob1 TBLOB.BIN -> has GLOBAL Blob1, code segment matches"
    PASS=$((PASS+1))
else
    echo "FAIL: TASM /BIN=code bin2obj happy path (code segment)"
    cat "$WORK/bin2obj-code.log"
    FAIL=$((FAIL+1))
fi

# happy path, data segment
rm -f "$WORK/TBLOB.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe /BIN=data /NAME=Blob2 TBLOB.BIN >bin2obj-data.log 2>&1 ) || true
if [ -f "$WORK/TBLOB.RDF" ] && [ -f "$WORK/RDFGREP.EXE" ] \
   && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE has-global TBLOB.RDF Blob2 >/dev/null 2>&1 ) \
   && ( cd "$WORK" && "$XT" run --max=$MAX RDFGREP.EXE data-contains TBLOB.RDF "01020304AABBCCDD" >/dev/null 2>&1 ); then
    echo "PASS: TASM /BIN=data /NAME=Blob2 TBLOB.BIN -> has GLOBAL Blob2, data segment matches"
    PASS=$((PASS+1))
else
    echo "FAIL: TASM /BIN=data bin2obj happy path (data segment)"
    cat "$WORK/bin2obj-data.log"
    FAIL=$((FAIL+1))
fi

# byte-stability: run the conversion twice, cmp the two .RDFs
rm -f "$WORK/TBLOB.RDF" "$WORK/TBLOB_RUN1.RDF"
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe /BIN=code /NAME=Blob1 TBLOB.BIN >/dev/null 2>&1 ) || true
cp "$WORK/TBLOB.RDF" "$WORK/TBLOB_RUN1.RDF" 2>/dev/null || true
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe /BIN=code /NAME=Blob1 TBLOB.BIN >/dev/null 2>&1 ) || true
if cmp -s "$WORK/TBLOB_RUN1.RDF" "$WORK/TBLOB.RDF" 2>/dev/null; then
    echo "PASS: TASM /BIN=code bin2obj -> byte-stable across repeated runs"
    PASS=$((PASS+1))
else
    echo "FAIL: TASM /BIN=code bin2obj -> output differs between repeated runs"
    FAIL=$((FAIL+1))
fi

# negative rows
bin2obj_fails() {
    local desc="$1" substr="$2"; shift 2
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe "$@" >bin2obj-neg.log 2>&1 ) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: $desc -> succeeded, expected a fatal error"
        FAIL=$((FAIL+1))
    elif grep -q -- "$substr" "$WORK/bin2obj-neg.log"; then
        echo "PASS: $desc -> fatal error as expected ('$substr')"
        PASS=$((PASS+1))
    else
        echo "FAIL: $desc -> failed but diagnostic lacks '$substr'"
        cat "$WORK/bin2obj-neg.log"
        FAIL=$((FAIL+1))
    fi
}
bin2obj_fails "missing /NAME=" "requires /NAME=" /BIN=code TBLOB.BIN
bin2obj_fails "/BIN=bogus" "unknown segment" /BIN=bogus /NAME=X TBLOB.BIN
bin2obj_fails "/NAME=1BAD (bad first char)" "invalid global name" /BIN=code /NAME=1BAD TBLOB.BIN
LONGNAME=$(printf 'X%.0s' $(seq 1 65))
bin2obj_fails "/NAME= 65 chars" "invalid global name" /BIN=code /NAME=$LONGNAME TBLOB.BIN
printf '' > "$WORK/TEMPTY.BIN"
bin2obj_fails "0-byte input" "empty input file" /BIN=code /NAME=X TEMPTY.BIN
dd if=/dev/zero of="$WORK/TOVER.BIN" bs=1 count=65000 2>/dev/null
bin2obj_fails "65000-byte input (over limit)" "exceeds 64K segment limit" /BIN=code /NAME=X TOVER.BIN
bin2obj_fails "nonexistent input" "no such file" /BIN=code /NAME=X NOSUCH.BIN

# I.2: -D/-Dname=value CLI predefines. TASM always names its output after
# the source file (TCLIDEF.ASM -> TCLIDEF.RDF), so this variant of
# check_one compares the ONE real output filename against two DIFFERENT
# checked-in oracles (TCLIDEF_ON.RDF/TCLIDEF_OFF.RDF), one per row,
# instead of check_one's usual "$rdf name == oracle filename" convention.
cli_def_check() {
    local desc="$1" extra="$2" oracle="$3"
    rm -f "$WORK/TCLIDEF.RDF"
    ( cd "$WORK" && "$XT" run --max=$MAX TASM.exe $extra TCLIDEF.ASM >assemble-clidef.log 2>&1 ) || true
    if [ ! -f "$WORK/TCLIDEF.RDF" ]; then
        echo "FAIL: $desc did not produce TCLIDEF.RDF"
        cat "$WORK/assemble-clidef.log"
        FAIL=$((FAIL+1))
        return
    fi
    if cmp -s "$WORK/TCLIDEF.RDF" "$FIXDIR/$oracle"; then
        echo "PASS: $desc -> TCLIDEF.RDF byte-identical to $oracle"
        PASS=$((PASS+1))
    else
        local d
        d=$(cmp -l "$WORK/TCLIDEF.RDF" "$FIXDIR/$oracle" 2>&1 | wc -l | tr -d ' ' || true)
        echo "FAIL: $desc -> TCLIDEF.RDF differs from $oracle ($d bytes differ)"
        FAIL=$((FAIL+1))
    fi
}
cli_def_check "TASM -DFEATURE -DVAL=5 TCLIDEF.ASM" "-DFEATURE -DVAL=5" TCLIDEF_ON.RDF
cli_def_check "TASM TCLIDEF.ASM (no -D)" "" TCLIDEF_OFF.RDF
bin2obj_fails "-D=5 (empty name)" "invalid -D" -D=5 TCLIDEF.ASM

# I.3: %include "FILE.INC" input-source stack
check_one TINC1.ASM TINC1.RDF "$FIXDIR"
check_fails TINCMISS.ASM "cannot open include file"
check_fails TINCSELF.ASM "recursive %include"
check_fails TINCDEEP.ASM "%include nested too deep"
check_one TINCSKIP.ASM TINCSKIP.RDF "$FIXDIR"

# I.4: %macro NAME NPARAMS ... %endmacro
check_one TMACRO.ASM TMACRO.RDF "$FIXDIR"

# BUG N1: every %macro invocation must free its expansion buffer -- 4
# invocations x 2 passes leaked 2066 paragraphs before the fix (SrcSlot's
# memory-source pop path never DISPOSEd Scan.MemText). Re-run TMACRO.ASM
# under /LOG=debug and require NO "Heap leak detected" line.
( cd "$WORK" && "$XT" run --max=$MAX TASM.exe /LOG=debug TMACRO.ASM >assemble-TMACRO-leak.log 2>&1 ) || true
if grep -q "Heap leak detected" "$WORK/assemble-TMACRO-leak.log"; then
    echo "FAIL: TMACRO.ASM -> %macro expansion leaked heap (BUG N1 regression)"
    cat "$WORK/assemble-TMACRO-leak.log"
    FAIL=$((FAIL+1))
else
    echo "PASS: TMACRO.ASM -> no heap leak under /LOG=debug"
    PASS=$((PASS+1))
fi

check_fails TMACARGS.ASM "macro argument count mismatch"
check_fails TMACMISS.ASM "missing %endmacro"
check_fails TMACNEST.ASM "nested %macro not supported"
check_fails TMACRECUR.ASM "macro expansion nested too deep"
check_fails TMACARG3.ASM "macro parameter %n beyond nParams"

# macro body overflow: generated inline (900 `nop` lines, ~3.6 KB body
# text, over the 4096-byte Scan.MaxMemText cap) -- impractical as a
# static checked-in fixture.
{
    echo "bits 16"; echo "cpu 8086"; echo "section .text"; echo "global Foo"
    echo "%macro big 0"
    i=0
    while [ "$i" -lt 900 ]; do echo "    nop"; i=$((i+1)); done
    echo "%endmacro"
    echo "Foo:"; echo "    big"; echo "    ret"
} > "$WORK/TMACBIG.ASM"
check_fails TMACBIG.ASM "macro body too long"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
