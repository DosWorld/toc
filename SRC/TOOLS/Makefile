PDIR      = ../..
BIN_DIR   = $(PDIR)/BIN
TESTDIR   = $(PDIR)/TESTS
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TOC_OPTS  = /CD /LOG=debug
XT        = xt
XTRUN     = $(XT) run --max=200000000 --memkb=640

all: TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE OBJ2RDF.EXE

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

# The toolchain is three binaries: TOC.EXE is only a driver and execs
# TOCC.EXE/TOCL.EXE from its OWN directory, so all three must be staged
# here together -- staging the driver alone gives "toc: cannot exec
# TOCC.EXE" on the first compile.
$(TOC): $(BIN_DIR)/$(TOC) $(BIN_DIR)/TOCC.EXE $(BIN_DIR)/TOCL.EXE
	cp $(BIN_DIR)/$(TOC) $(TOC)
	cp $(BIN_DIR)/TOCC.EXE TOCC.EXE
	cp $(BIN_DIR)/TOCL.EXE TOCL.EXE

# ── rdfgrep ────────────────────────────────────────────────────────────
# toc.exe auto-names the output from the module name: RDFGREP.MOD → RDFGREP.exe
# With -c ../../, the file lands in the repo root; we then install it to BIN/.
RDFGREP.EXE: RDFGREP.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run RDFGREP.MOD

# ── testall ────────────────────────────────────────────────────────────
TESTALL.EXE: TESTALL.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run TESTALL.MOD

# ── tdinfo ─────────────────────────────────────────────────────────────
# TDS/TDINFO debug-block inspector (oracle for the /g debug-info feature).
TDINFO.EXE: TDINFO.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run TDINFO.MOD

# ── tostrip ────────────────────────────────────────────────────────────
# Strips debug info from a linked .EXE (TDS/TDINFO block) or a compiler
# .OM archive (zeros the .DBG member); format auto-detected from content.
TOSTRIP.EXE: TOSTRIP.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run TOSTRIP.MOD

# ── tolib ──────────────────────────────────────────────────────────────
# .OM archive manager: list/extract/create/merge. Uses the shared Tar module.
TOLIB.EXE: TOLIB.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run TOLIB.MOD

# ── obj2rdf ────────────────────────────────────────────────────────────
# Converts a 16-bit Microsoft/Intel OMF .OBJ file to RDOFF2 .rdf, so
# legacy Turbo Assembler/MASM-era object code can be linked by toc/Link.
OBJ2RDF.EXE: OBJ2RDF.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) $(TOC_OPTS) /ENTRY=Run OBJ2RDF.MOD

install: TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE OBJ2RDF.EXE
	cp TOLIB.EXE TOSTRIP.EXE TDINFO.EXE TESTALL.EXE RDFGREP.EXE OBJ2RDF.EXE $(BIN_DIR)/

clean:
	rm -f *.EXE *.OM *.OVR *.LNK

.PHONY: all clean
