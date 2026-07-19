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

BIN_OC = ../../BIN/TOC.EXE
BIN_OM  = ../../BIN/OBERON.OM
XT      = xt

# No -c: xt uses process CWD (SRC/TLINK/) as the C:\ mount root, same
# rationale as SRC/TASM/Makefile — the stdlib OBERON.OM lives outside this
# dir, so it's copied locally rather than reached via a DOS path.
XTRUN  = $(XT) run --max=300000000
OC = TOC.EXE

all: TLINK.exe

$(OC): $(BIN_OC)
	cp $(BIN_OC) $(OC)

OBERON.OM: $(BIN_OM)
	cp $(BIN_OM) OBERON.OM

TLINK.exe: TLINK.MOD $(OC) OBERON.OM
	$(XTRUN) $(OC) /LOG=debug /ENTRY=Run TLINK.MOD /M

install: TLINK.exe
	mkdir -p ../../BIN
	cp TLINK.exe ../../BIN/TLINK.EXE

clean:
	rm -f *.om *.OM *.rdf *.RDF *.def *.DEF *.TMP TLINK.exe TLINK.EXE $(OC) OBERON.OM

.PHONY: all install clean
