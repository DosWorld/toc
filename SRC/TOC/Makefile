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
# (TOOLS/ also copies BIN/OBERON.OM into its `-c ../../` mount root rather
# than using OBERON_LIB: this xt build's `-e`/`--env=` flags do not actually
# populate the child DOS process's environment block -- confirmed empirically
# 2026-07-16, see SRC/TASM/TASM.MD §K -- so an OBERON_LIB env var is never a
# working option here regardless of quoting/slash convention.)
XTRUN  = $(XT) run --max=40000000000
OCBOOT = toc_boot.exe

# Every compiler source — the single-process build scans, compiles and links the
# whole image in ONE call, so TOC.exe depends on the sources directly (no
# module-by-module .om prerequisites).  Building each module separately in this
# cluttered mount dir fragments the heap and breaks the largest module's .rdf
# allocation ("cannot write Parser.rdf"); the single-process driver keeps the
# module graph in a temp file (not the heap) and so links the full image cleanly.
#
# Rdoff/Tar/LogErr (2026-07-11: moved from SRC/TOC to SRC/LIB, LogErr renamed
# from Err) are NOT listed here even though TOC.MOD/CGEN.MOD/LINK.MOD/etc.
# `IMPORT` them: they are stdlib modules now, merged into OBERON.OM (copied
# into this dir below), exactly like Strings/Files/IO always were.  The
# compiler's own dep-scanner (TOC.MOD's FindSrc) only searches the CWD with
# no OBERON_LIB entry here, so it will not find RDOFF.MOD/TAR.MOD/LOGERR.MOD
# as source and will correctly treat them as .OM-only dependencies (same
# path every other stdlib import already takes during self-host).
OC_SRCS = \
    SCAN.MOD STRTAB.MOD SYMS.MOD CGEN.MOD DEF.MOD IMPORT.MOD \
    PEXPR.MOD PSTMT.MOD PARSER.MOD LINK.MOD TOC.MOD

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
