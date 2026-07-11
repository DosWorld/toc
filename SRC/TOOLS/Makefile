# Makefile for SRC/TOOLS — auxiliary Oberon-native tools.
#
# Builds:
#   rdfgrep.exe    RDOFF/.om introspection CLI
#   testall.exe    Phase-4 unified test driver
#   tdinfo.exe     TDS/TDINFO debug-block inspector
#   tostrip.exe    strip debug info from .exe/.om files
#   tolib.exe      .OM archive manager (list/extract/create/merge)
#
# Uses BIN/TOC.EXE (built from SRC/TOC) via xt.
# OBERON_LIB points to OBERON.OM, which supplies the whole stdlib including
# Rdoff/Tar/LogErr (moved into SRC/LIB and merged into OBERON.OM, 2026-07-11;
# LogErr was renamed from Err) — no separate .OM entries needed for them.
#
# Usage:
#   make           — build all tools, install into ../../BIN/
#   make clean     — remove the BIN/ binaries

BIN_OC  = ../../BIN/TOC.EXE
TESTDIR = ../../TESTS
BINDIR  = ../../BIN
XT      = xt

# Mount oberonc/ root at C:\
XTRUN = $(XT) run --max=200000000 -c ../../
OBERON_LIB = BIN/OBERON.OM

TOOLS = $(BINDIR)/RDFGREP.EXE $(BINDIR)/TESTALL.EXE $(BINDIR)/TDINFO.EXE $(BINDIR)/TOSTRIP.EXE $(BINDIR)/TOLIB.EXE

all: $(TOOLS)

# ── rdfgrep ────────────────────────────────────────────────────────────
# toc.exe auto-names the output from the module name: RDFGREP.MOD → RDFGREP.exe
# With -c ../../, the file lands in the repo root; we then install it to BIN/.
$(BINDIR)/RDFGREP.EXE: RDFGREP.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	$(XTRUN) -e 'OBERON_LIB=$(OBERON_LIB)' $(BIN_OC) \
	    /LOG=debug /ENTRY=Run SRC/TOOLS/RDFGREP.MOD
	mv ../../RDFGREP.exe $(BINDIR)/RDFGREP.EXE

# ── testall ────────────────────────────────────────────────────────────
$(BINDIR)/TESTALL.EXE: $(TESTDIR)/TESTALL.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	$(XTRUN) -e 'OBERON_LIB=$(OBERON_LIB)' $(BIN_OC) \
	    /LOG=debug /ENTRY=Run TESTS/TESTALL.MOD
	mv ../../TESTALL.exe $(BINDIR)/TESTALL.EXE

# ── tdinfo ─────────────────────────────────────────────────────────────
# TDS/TDINFO debug-block inspector (oracle for the /g debug-info feature).
$(BINDIR)/TDINFO.EXE: TDINFO.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	$(XTRUN) -e 'OBERON_LIB=$(OBERON_LIB)' $(BIN_OC) \
	    /LOG=debug /ENTRY=Run SRC/TOOLS/TDINFO.MOD
	mv ../../TDINFO.exe $(BINDIR)/TDINFO.EXE


# ── tostrip ────────────────────────────────────────────────────────────
# Strips debug info from a linked .EXE (TDS/TDINFO block) or a compiler
# .OM archive (zeros the .DBG member); format auto-detected from content.
$(BINDIR)/TOSTRIP.EXE: TOSTRIP.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	$(XTRUN) -e 'OBERON_LIB=$(OBERON_LIB)' $(BIN_OC) \
	    /LOG=debug /ENTRY=Run SRC/TOOLS/TOSTRIP.MOD
	mv ../../TOSTRIP.exe $(BINDIR)/TOSTRIP.EXE

# ── tolib ──────────────────────────────────────────────────────────────
# .OM archive manager: list/extract/create/merge. Uses the shared Tar module.
$(BINDIR)/TOLIB.EXE: TOLIB.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	$(XTRUN) -e 'OBERON_LIB=$(OBERON_LIB)' $(BIN_OC) \
	    /LOG=debug /ENTRY=Run SRC/TOOLS/TOLIB.MOD
	mv ../../TOLIB.exe $(BINDIR)/TOLIB.EXE

clean:
	rm -f $(BINDIR)/RDFGREP.EXE $(BINDIR)/TESTALL.EXE $(BINDIR)/TDINFO.EXE $(BINDIR)/TOSTRIP.EXE $(BINDIR)/TOLIB.EXE

.PHONY: all clean
