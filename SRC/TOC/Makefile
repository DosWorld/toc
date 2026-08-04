PDIR      = ../..
BIN_DIR   = $(PDIR)/BIN
BOOT_DIR  = $(PDIR)/BOOT
OBERON_ON = OBERON.OM
TRUBO_OM  = TRUBO.OM
TASM      = TASM.EXE
TTOC      = _TOC.EXE
TOC       = TOC.EXE
TOC286    = TOC286.EXE
TOC_OPTS  = /CD /LOG=debug
XT        = xt
XTRUN     = $(XT) run --max=40000000000 --memkb=544

OC_SRCS = \
    SCAN.MOD SYMS.MOD CGEN.MOD DEF.MOD IMPORT.MOD \
    PEXPR.MOD PSTMT.MOD PARSER.MOD LINK.MOD LINKMZ.MOD LINKNE.MOD TOC.MOD

# TOC286.EXE (DPMI16/NE, /CP) is an ADDITIVE build: same compiler, just
# linked as an NE binary via TOC286.MOD (a thin `IMPORT TOC; Run* = TOC.Run`
# entry point).  `all`/`install`/`test` keep using TOC.EXE (/CD) exactly as
# before -- build TOC286.EXE explicitly via `make toc286`.
all: $(TOC)

$(TOC286): $(OC_SRCS) TOC286.MOD $(TTOC) $(OBERON_ON) $(TRUBO_OM) NESTAB.RDF
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TTOC) $(TOC_OPTS) /CP /ENTRY=Run TOC286.MOD /M

toc286: $(TOC286)
	mkdir -p $(BIN_DIR)
	cp $(TOC286) $(BIN_DIR)/$(TOC286)

$(TTOC): $(BOOT_DIR)/$(TOC)
	cp $(BOOT_DIR)/$(TOC) $(TTOC)

$(OBERON_ON): $(BIN_DIR)/$(OBERON_ON)
	cp $(BIN_DIR)/$(OBERON_ON) $(OBERON_ON)

$(TASM): $(BIN_DIR)/$(TASM)
	cp $(BIN_DIR)/$(TASM) $(TASM)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

NESTAB.RDF: NESTAB.BIN $(TASM)
	$(XTRUN) $(TASM) /BIN=code /NAME=LinkNE_NESTAB NESTAB.BIN

$(TOC): $(OC_SRCS) $(TTOC) $(OBERON_ON) $(TRUBO_OM) NESTAB.RDF
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TTOC) $(TOC_OPTS) /CD /ENTRY=Run TOC.MOD /M

install: $(TOC) $(TOC286)
	mkdir -p $(BIN_DIR)
	cp $(TOC) $(BIN_DIR)/$(TOC)
	cp $(TOC286) $(BIN_DIR)/$(TOC286)

clean:
	rm -f *.OM *.EXE

.PHONY: all install clean toc286
