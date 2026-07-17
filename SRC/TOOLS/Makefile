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

# Mount oberonc/ root at C:  (trailing backslash removed from this comment --
# a backslash at end of a Makefile comment line is STILL a line-continuation
# to GNU Make, which was silently swallowing the XTRUN assignment below into
# this comment, leaving XTRUN empty and producing the bogus `e 'OBERON_LIB=...'`
# command seen when a stray leading `-` was lost along with the rest of XTRUN)
#
# OBERON_LIB via `-e`/`--env=` was ALSO tried here at one point and found not
# to work: this xt build does not actually populate the child DOS process's
# environment block from `-e KEY=VALUE` (confirmed empirically -- a minimal
# Oberon program calling Dos.GetEnv("OBERON_LIB", ...) sees an empty string
# regardless of `-e`/`--env=`, with no error from xt either). Since
# IMPORT.MOD's search order already tries `OBERON.OM` in the current
# directory (mount root, i.e. repo root under `-c ../../`) BEFORE falling
# back to OBERON_LIB, the fix is to put a copy of OBERON.OM there instead of
# relying on the environment variable at all -- exactly how
# TESTS/test_tasm.sh's own build step already works.
XTRUN = $(XT) run --max=200000000 -c ../../

TOOLS = $(BINDIR)/RDFGREP.EXE $(BINDIR)/TESTALL.EXE $(BINDIR)/TDINFO.EXE $(BINDIR)/TOSTRIP.EXE $(BINDIR)/TOLIB.EXE

all: $(TOOLS)

# ── rdfgrep ────────────────────────────────────────────────────────────
# toc.exe auto-names the output from the module name: RDFGREP.MOD → RDFGREP.exe
# With -c ../../, the file lands in the repo root; we then install it to BIN/.
$(BINDIR)/RDFGREP.EXE: RDFGREP.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	cp $(BINDIR)/OBERON.OM ../../OBERON.OM
	$(XTRUN) $(BIN_OC) /ENTRY=Run SRC/TOOLS/RDFGREP.MOD
	rm -f ../../OBERON.OM
	mv ../../RDFGREP.exe $(BINDIR)/RDFGREP.EXE

# ── testall ────────────────────────────────────────────────────────────
$(BINDIR)/TESTALL.EXE: $(TESTDIR)/TESTALL.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	cp $(BINDIR)/OBERON.OM ../../OBERON.OM
	$(XTRUN) $(BIN_OC) /ENTRY=Run TESTS/TESTALL.MOD
	rm -f ../../OBERON.OM
	mv ../../TESTALL.exe $(BINDIR)/TESTALL.EXE

# ── tdinfo ─────────────────────────────────────────────────────────────
# TDS/TDINFO debug-block inspector (oracle for the /g debug-info feature).
$(BINDIR)/TDINFO.EXE: TDINFO.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	cp $(BINDIR)/OBERON.OM ../../OBERON.OM
	$(XTRUN) $(BIN_OC) /LOG=debug /ENTRY=Run SRC/TOOLS/TDINFO.MOD
	rm -f ../../OBERON.OM
	mv ../../TDINFO.exe $(BINDIR)/TDINFO.EXE


# ── tostrip ────────────────────────────────────────────────────────────
# Strips debug info from a linked .EXE (TDS/TDINFO block) or a compiler
# .OM archive (zeros the .DBG member); format auto-detected from content.
$(BINDIR)/TOSTRIP.EXE: TOSTRIP.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	cp $(BINDIR)/OBERON.OM ../../OBERON.OM
	$(XTRUN) $(BIN_OC) /LOG=debug /ENTRY=Run SRC/TOOLS/TOSTRIP.MOD
	rm -f ../../OBERON.OM
	mv ../../TOSTRIP.exe $(BINDIR)/TOSTRIP.EXE

# ── tolib ──────────────────────────────────────────────────────────────
# .OM archive manager: list/extract/create/merge. Uses the shared Tar module.
$(BINDIR)/TOLIB.EXE: TOLIB.MOD $(BIN_OC)
	mkdir -p $(BINDIR)
	cp $(BINDIR)/OBERON.OM ../../OBERON.OM
	$(XTRUN) $(BIN_OC) /LOG=debug /ENTRY=Run SRC/TOOLS/TOLIB.MOD
	rm -f ../../OBERON.OM
	mv ../../TOLIB.exe $(BINDIR)/TOLIB.EXE

clean:
	rm -f $(BINDIR)/RDFGREP.EXE $(BINDIR)/TESTALL.EXE $(BINDIR)/TDINFO.EXE $(BINDIR)/TOSTRIP.EXE $(BINDIR)/TOLIB.EXE

.PHONY: all clean
