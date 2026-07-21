# Makefile for Trubo Link (SRC/TLINK/)
# Builds tlink.exe (DOS MZ): merged RDOFF2 linker for tiny-model .COM/.SYS
# and small-model .EXE output (see TLINK.MOD's header comment for details).
#
# Bootstrap: BOOT/TOC.EXE (MS-DOS MZ) — copied locally so xt can find it
# in the CWD.  BOOT/TOC.EXE is NEVER modified by the build.
#
# Not part of the top-level `make all` build graph: tlink is a standalone
# leaf tool (same status as tasm), built and installed on demand.
#
# Usage:
#   make          — compile + link tlink.exe (auto-named TLINK.exe)
#   make install  — copy TLINK.exe to BIN/TLINK.EXE
#   make clean    — remove .om files, TLINK.exe, and local setup files

BIN_TOC = ../../BIN/TOC.EXE
BIN_OM  = ../../BIN/OBERON.OM
BIN_TRUBO_OM = ../../BIN/TRUBO.OM
XT      = xt

# No -c: xt uses process CWD (SRC/TLINK/) as the C:\ mount root, same
# rationale as SRC/TASM/Makefile — the stdlib OBERON.OM lives outside this
# dir, so it's copied locally rather than reached via a DOS path.
XTRUN  = $(XT) run --max=300000000
TOC = TOC.EXE

all: TLINK.EXE

TRUBO.OM: $(BIN_TRUBO_OM)
	cp $(BIN_TRUBO_OM) TRUBO.OM

$(TOC): $(BIN_TOC)
	cp $(BIN_TOC) $(TOC)

OBERON.OM: $(BIN_OM)
	cp $(BIN_OM) OBERON.OM

TLINK.EXE: TLINK.MOD TEXE.MOD $(TOC) OBERON.OM TRUBO.OM
	$(XTRUN) -e "OBERON_LIB=TRUBO.OM" $(TOC) /LOG=debug /ENTRY=Run TLINK.MOD /M

install: TLINK.EXE
	mkdir -p ../../BIN
	cp TLINK.EXE ../../BIN/TLINK.EXE

clean:
	rm -f *.OM *.EXE OUTPUT.LOG

.PHONY: all install clean
