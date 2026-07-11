# Makefile for the all-in-one Oberon compiler/linker/build-driver (SRC/TOC/)
# Builds toc.exe (DOS MZ): compiler + smart linker + dep-scan in one tool.
#
# Bootstrap: BOOT/TOC.EXE (MS-DOS MZ) — copied locally so xt can find it
# in the CWD.  BOOT/TOC.EXE is NEVER modified by the build.
#
# Usage:
#   make          — compile all modules + link toc.exe (auto-named TOC.exe)
#   make install  — copy TOC.exe to BIN/TOC.EXE
#   make clean    — remove .om files, TOC.exe, and local setup files

BOOT_OC  = ../../BOOT/TOC.EXE
BIN_OM   = ../../BIN/OBERON.OM
XT       = xt

# No -c: xt uses process CWD (SRC/TOC/) as the C:\ mount root, so the stdlib
# OBERON.OM (which lives OUTSIDE this dir, in BIN/) is not reachable via a DOS
# path — anything above the -c mount root is invisible.  We therefore copy
# BIN/OBERON.OM into the CWD and let the compiler find it via the CWD search.
# (TOOLS/ instead mounts the repo root with `-c ../../` and points a
# single-quoted OBERON_LIB at BIN/OBERON.OM with forward slashes — see those
# makefiles and DOCS/XT.MD §"Filesystem and path conventions" for the quoting
# rule that keeps such paths safe.)
XTRUN  = $(XT) run --max=40000000000
OCBOOT = toc_boot.exe

# Every compiler source — the single-process build scans, compiles and links the
# whole image in ONE call, so TOC.exe depends on the sources directly (no
# module-by-module .om prerequisites).  Building each module separately in this
# cluttered mount dir fragments the heap and breaks the largest module's .rdf
# allocation ("cannot write Parser.rdf"); the single-process driver keeps the
# module graph in a temp file (not the heap) and so links the full image cleanly.
OC_SRCS = \
    RDOFF.MOD TAR.MOD SCAN.MOD STRTAB.MOD SYMS.MOD CGEN.MOD DEF.MOD IMPORT.MOD \
    PEXPR.MOD PSTMT.MOD PARSER.MOD LINK.MOD ERR.MOD TOC.MOD

all: TOC.exe

$(OCBOOT): $(BOOT_OC)
	cp $(BOOT_OC) $(OCBOOT)

OBERON.OM: $(BIN_OM)
	cp $(BIN_OM) OBERON.OM

# Single-command self-host: toc /ENTRY=Run TOC.MOD scans deps, compiles every
# stale module and links TOC.exe in one process.
TOC.exe: $(OC_SRCS) $(OCBOOT) OBERON.OM
	time $(XTRUN) $(OCBOOT) /LOG=debug /ENTRY=Run TOC.MOD /M

install: TOC.exe
	mkdir -p ../../BIN
	cp TOC.exe ../../BIN/TOC.EXE

clean:
	rm -f *.om *.OM *.rdf *.RDF *.def *.DEF *.TMP TOC.exe TOC.EXE MAIN.RDF $(OCBOOT) OBERON.OM

.PHONY: all install clean
