# Makefile for the self-hosted TASM assembler (SRC/TASM/)
# Builds three binaries:
#   TASM.EXE    NASM-subset assembler -> RDOFF2 .rdf writer
#   TA2NASM.EXE standalone Turbo Assembler 5.0 (MASM/Ideal) -> NASM-subset
#               preprocessor -- moved out of TASM.EXE 2026-08-11, see
#               TA2NASM.MOD's own header comment for why
#   SPHO.EXE    SPHINX Oberon dialect (DOCS/SPHINX.MD) -> NASM-subset
#               translator -- see DOCS/SPHO.MD
#
# Bootstrap: BOOT/TOC.EXE (MS-DOS MZ) — copied locally so xt can find it
# in the CWD.  BOOT/TOC.EXE is NEVER modified by the build.
#
# Not part of the top-level `make all` build graph: TASM is a standalone
# leaf tool, not yet trusted to replace the checked-in SYSTEM.RDF/EMS.RDF
# (see DOCS/IMPLRULE.MD's TASM section).  Byte-diff regression lives in
# TESTS/test_tasm.sh, run as an extra step of the top-level `make test`.
#
# Usage:
#   make          — compile all modules + link TASM/TA2NASM/SPHO.exe
#   make install  — copy all three .exe to BIN/
#   make clean    — remove .om files, all .exe, and local setup files
BIN_DIR  = ../../BIN
BOOT_DIR = ../../BOOT
BIN_TOC  = $(BOOT_DIR)/TOC.EXE
BIN_OM   = $(BIN_DIR)/OBERON.OM
BIN_TRUBO_OM = $(BIN_DIR)/TRUBO.OM
XT       = xt

# No -c: xt uses process CWD (SRC/TASM/) as the C:\ mount root, matching
# SRC/TOC/Makefile's own rationale — the stdlib OBERON.OM lives outside
# this dir, so it's copied locally rather than reached via a DOS path.
# TURBO.MOD/TURBODIR.MOD (Turbo Assembler 5.0 -> NASM syntax converter)
# need a much bigger instruction budget to compile than the rest of
# TASM's sources.
XTRUN  = $(XT) run --max=2000000000 --memkb=580
TOC     = TOC.EXE
TASM    = TASM.EXE
TA2NASM = TA2NASM.EXE
SPHO    = SPHO.EXE

# TASM.EXE's own sources — dep-scan (TOC.MOD's FindSrc, CWD-only) resolves
# these to each other automatically; Rdoff/LogErr/Strings/Files/etc. are
# stdlib, resolved via the copied OBERON.OM only (never found as local
# source, so treated as .OM-only imports, same as every other tool).
# TURBO.MOD/TURBODIR.MOD are NOT built into TASM.EXE (moved to TA2NASM.EXE
# below) -- TASM.EXE accepts NASM-subset source only.
TASM_SRCS = SCAN.MOD SYM.MOD ENC.MOD DIR.MOD PARSE.MOD TASM.MOD

all: $(TASM) $(TA2NASM) $(SPHO)

TRUBO.OM: $(BIN_TRUBO_OM)
	cp $(BIN_TRUBO_OM) TRUBO.OM

$(TOC): $(BIN_TOC)
	cp $(BIN_TOC) $(TOC)

OBERON.OM: $(BIN_OM)
	cp $(BIN_OM) OBERON.OM

$(TASM): $(TASM_SRCS) $(TOC) OBERON.OM TRUBO.OM
	time $(XTRUN) -e "OBERON_LIB=TRUBO.OM" $(TOC) /CD /ENTRY=Run TASM.MOD /M

# TA2NASM.EXE: standalone Turbo-dialect preprocessor.  TA2NASM.MOD only
# imports Turbo (which imports TurboDir, plus whatever further split
# TurboDir itself is broken into -- see TURBODIR.MOD's own header
# comment) -- dep-scan resolves the whole chain automatically the same
# way it does for TASM.EXE above.
$(TA2NASM): TA2NASM.MOD $(TOC) OBERON.OM TRUBO.OM
	time $(XTRUN) -e "OBERON_LIB=TRUBO.OM" $(TOC) /CD /ENTRY=Run TA2NASM.MOD /M

# SPHO.EXE: SPHINX Oberon -> NASM-subset translator, standalone (own
# lexer/parser, no TASM pipeline sharing) -- see DOCS/SPHO.MD.
$(SPHO): SPHO.MOD $(TOC) OBERON.OM TRUBO.OM
	time $(XTRUN) -e "OBERON_LIB=TRUBO.OM" $(TOC) /CD /ENTRY=Run SPHO.MOD /M

install: $(TASM) $(TA2NASM) $(SPHO)
	mkdir -p $(BIN_DIR)
	cp $(TASM) $(BIN_DIR)/$(TASM)
	cp $(TA2NASM) $(BIN_DIR)/$(TA2NASM)
	cp $(SPHO) $(BIN_DIR)/$(SPHO)

clean:
	rm -f *.OM *.EXE

.PHONY: all install clean
