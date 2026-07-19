# Makefile for the self-hosted TASM assembler (SRC/TASM/)
# Builds tasm.exe (DOS MZ): NASM-subset assembler -> RDOFF2 .rdf writer.
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
#   make          — compile all modules + link tasm.exe (auto-named TASM.exe)
#   make install  — copy TASM.exe to BIN/TASM.EXE
#   make clean    — remove .om files, TASM.exe, and local setup files

BIN_OC  = ../../BIN/TOC.EXE
BIN_OM   = ../../BIN/OBERON.OM
XT       = xt

# No -c: xt uses process CWD (SRC/TASM/) as the C:\ mount root, matching
# SRC/TOC/Makefile's own rationale — the stdlib OBERON.OM lives outside
# this dir, so it's copied locally rather than reached via a DOS path.
XTRUN  = $(XT) run --max=300000000
OC = TOC.EXE

# Every TASM source — dep-scan (TOC.MOD's FindSrc, CWD-only) resolves
# these to each other automatically; Rdoff/LogErr/Strings/Files/etc. are
# stdlib, resolved via the copied OBERON.OM only (never found as local
# source, so treated as .OM-only imports, same as every other tool).
TASM_SRCS = SCAN.MOD SYM.MOD ENC.MOD DIR.MOD PARSE.MOD TASM.MOD

all: TASM.exe

$(OC): $(BIN_OC)
	cp $(BIN_OC) $(OC)

OBERON.OM: $(BIN_OM)
	cp $(BIN_OM) OBERON.OM

TASM.exe: $(TASM_SRCS) $(OC) OBERON.OM
	time $(XTRUN) $(OC) /ENTRY=Run TASM.MOD /M

install: TASM.exe
	mkdir -p ../../BIN
	cp TASM.exe ../../BIN/TASM.EXE

clean:
	rm -f *.om *.OM *.rdf *.RDF *.def *.DEF *.TMP TASM.exe TASM.EXE $(OC) OBERON.OM

.PHONY: all install clean
