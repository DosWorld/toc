BIN_TOC = ../../BIN/TOC.EXE
TESTDIR = ../../TESTS
BINDIR  = ../../BIN

TOC = TOC.EXE
XT  = xt

XTRUN = $(XT) run --max=200000000

all: TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE

OBERON.OM: $(BINDIR)/OBERON.OM
	cp $(BINDIR)/OBERON.OM OBERON.OM

$(TOC): $(BIN_TOC)
	cp $(BIN_TOC) $(TOC)

# ── rdfgrep ────────────────────────────────────────────────────────────
# toc.exe auto-names the output from the module name: RDFGREP.MOD → RDFGREP.exe
# With -c ../../, the file lands in the repo root; we then install it to BIN/.
RDFGREP.EXE: RDFGREP.MOD $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /ENTRY=Run RDFGREP.MOD

# ── testall ────────────────────────────────────────────────────────────
TESTALL.EXE: TESTALL.MOD $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /ENTRY=Run TESTALL.MOD

# ── tdinfo ─────────────────────────────────────────────────────────────
# TDS/TDINFO debug-block inspector (oracle for the /g debug-info feature).
TDINFO.EXE: TDINFO.MOD $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /LOG=debug /ENTRY=Run TDINFO.MOD

# ── tostrip ────────────────────────────────────────────────────────────
# Strips debug info from a linked .EXE (TDS/TDINFO block) or a compiler
# .OM archive (zeros the .DBG member); format auto-detected from content.
TOSTRIP.EXE: TOSTRIP.MOD $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /LOG=debug /ENTRY=Run TOSTRIP.MOD

# ── tolib ──────────────────────────────────────────────────────────────
# .OM archive manager: list/extract/create/merge. Uses the shared Tar module.
TOLIB.EXE: TOLIB.MOD $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /LOG=debug /ENTRY=Run TOLIB.MOD

install: TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE
	cp TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE $(BINDIR)/

clean:
	rm -f *.EXE *.OM OUTPUT.LOG

.PHONY: all clean
