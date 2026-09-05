PDIR      = ../..
BIN_DIR   = $(PDIR)/BIN
BOOT_DIR  = $(PDIR)/BOOT
OBERON_ON = OBERON.OM
TRUBO_OM  = TRUBO.OM
TASM      = TASM.EXE
TTOC      = _TOC.EXE
TTOCC     = _TOCC.EXE
TTOCL     = _TOCL.EXE
TOC       = TOC.EXE
TOCC      = TOCC.EXE
TOCL      = TOCL.EXE
TOC_OPTS  = /LOG=debug
XT        = xt
XTRUN     = $(XT) run --max=40000000000 --memkb=640

# Shared compiler/linker sources.  Both the split halves and the monolith
# are built from exactly these -- only the entry module differs.
OC_SRCS = \
    SCAN.MOD SYMS.MOD CGEN.MOD DEF.MOD IMPORT.MOD TDBG.MOD \
    PEXPR.MOD PEXPR2.MOD PSTMT.MOD PARSER.MOD LINK.MOD LINKMZ.MOD LINKNE.MOD \
    TOCMAIN.MOD

# The toolchain is SPLIT into three binaries (2026-09-05):
#
#   TOC.EXE    tiny driver: parses the command line and runs the two halves
#              in turn via Dos.Exec.  Holds no compiler and no linker code.
#   TOCC.EXE   compile half: dep-scan + compile -> .om files, plus a .LNK
#              control file naming them in topological order.
#   TOCL.EXE   link half: reads that .LNK and writes the .exe.
#
# Neither half carries the other's code, and none of the three uses $O+
# overlays -- so no binary pays Overlay.OvrSetBuf2's unconditional 87 KB
# heap buffer.  That is the point of the split: the DOS memory floor is
# max(TOCC, TOCL) rather than the sum, because the phases never run at once.
#
all: $(TOC) $(TOCC) $(TOCL)

# Stage the bootstrap toolchain under UNDERSCORE names.
# BOOT/TOC.EXE is now a DRIVER: it execs TOCC.EXE/TOCL.EXE from its own
# directory.  Copied here under their real names they would collide with --
# and be overwritten by -- the very binaries this makefile is building, so
# the running compiler would be replaced mid-build.  Renaming the staged
# copies keeps bootstrap and output completely separate.
# _TOC.EXE execs _TOCC.EXE/_TOCL.EXE: TOC.MOD's ChildPath derives the
# children from its OWN basename prefix, so the staged driver never reaches
# for the plain-named outputs beside it.  All three are staged together.
$(TTOC): $(BOOT_DIR)/$(TOC) $(BOOT_DIR)/$(TOCC) $(BOOT_DIR)/$(TOCL)
	cp $(BOOT_DIR)/$(TOC)  $(TTOC)
	cp $(BOOT_DIR)/$(TOCC) $(TTOCC)
	cp $(BOOT_DIR)/$(TOCL) $(TTOCL)

$(OBERON_ON): $(BIN_DIR)/$(OBERON_ON)
	cp $(BIN_DIR)/$(OBERON_ON) $(OBERON_ON)

$(TASM): $(BIN_DIR)/$(TASM)
	cp $(BIN_DIR)/$(TASM) $(TASM)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

NESTAB.RDF: NESTAB.BIN $(TASM)
	$(XTRUN) $(TASM) /BIN=code /NAME=LinkNE_NESTAB NESTAB.BIN

# Bootstrap note: BOOT/TOC.EXE is the OLD all-in-one compiler, so it both
# compiles and links in one step -- that is why these rules can use /ENTRY=
# directly.  Once the split binaries are installed into BOOT/, TOC.EXE there
# is a driver and the same command still works: it execs TOCC then TOCL.
$(TOCC): $(OC_SRCS) TOCC.MOD $(TTOC) $(OBERON_ON) $(TRUBO_OM) NESTAB.RDF
	find . -maxdepth 1 -name "*.OM" ! -name "$(OBERON_ON)" ! -name "$(TRUBO_OM)" -delete
	rm -f $(TOCC)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TTOC) $(TOC_OPTS) /CD /ENTRY=Run TOCC.MOD /M

$(TOCL): $(OC_SRCS) TOCL.MOD $(TTOC) $(OBERON_ON) $(TRUBO_OM) NESTAB.RDF
	find . -maxdepth 1 -name "*.OM" ! -name "$(OBERON_ON)" ! -name "$(TRUBO_OM)" -delete
	rm -f $(TOCL)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TTOC) $(TOC_OPTS) /CD /ENTRY=Run TOCL.MOD /M

$(TOC): TOC.MOD $(TTOC) $(OBERON_ON) $(TRUBO_OM)
	rm -f $(TOC)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TTOC) $(TOC_OPTS) /CD /ENTRY=Run TOC.MOD /M

# Self-host check: rebuild the split toolchain with ITSELF, twice, and require
# all THREE binaries to be byte-identical across the last two generations.
# All three matter: each generation's TOCC and TOCL are what build the next,
# so a drifting linker would silently change every later image.
shost: $(TOC) $(TOCC) $(TOCL)
	cp $(TOCC) G1C.EXE
	cp $(TOCL) G1L.EXE
	find . -maxdepth 1 -name "*.OM" ! -name "$(OBERON_ON)" ! -name "$(TRUBO_OM)" -delete
	rm -f $(TOC) $(TOCC) $(TOCL) $(TTOC)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1C.EXE $(TOC_OPTS) TOCC.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1C.EXE $(TOC_OPTS) /ENTRY=Run TOCC.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1L.EXE TOCC.LNK
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1C.EXE $(TOC_OPTS) /ENTRY=Run TOCL.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1L.EXE TOCL.LNK
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1C.EXE $(TOC_OPTS) /ENTRY=Run TOC.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G1L.EXE TOC.LNK
	cp $(TOCC) G2C.EXE
	cp $(TOCL) G2L.EXE
	cp $(TOC)  G2D.EXE
	find . -maxdepth 1 -name "*.OM" ! -name "$(OBERON_ON)" ! -name "$(TRUBO_OM)" -delete
	rm -f $(TOC) $(TOCC) $(TOCL)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2C.EXE $(TOC_OPTS) /ENTRY=Run TOCC.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2L.EXE TOCC.LNK
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2C.EXE $(TOC_OPTS) /ENTRY=Run TOCL.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2L.EXE TOCL.LNK
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2C.EXE $(TOC_OPTS) /ENTRY=Run TOC.MOD
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" G2L.EXE TOC.LNK
	cmp -s G2C.EXE $(TOCC) && echo "self-host TOCC PASS (g2=g3)" || echo "self-host TOCC FAIL"
	cmp -s G2L.EXE $(TOCL) && echo "self-host TOCL PASS (g2=g3)" || echo "self-host TOCL FAIL"
	cmp -s G2D.EXE $(TOC)  && echo "self-host TOC  PASS (g2=g3)" || echo "self-host TOC  FAIL"

install: all
	mkdir -p $(BIN_DIR)
	cp $(TOC)    $(BIN_DIR)/$(TOC)
	cp $(TOCC)   $(BIN_DIR)/$(TOCC)
	cp $(TOCL)   $(BIN_DIR)/$(TOCL)

clean:
	rm -f *.OM *.EXE *.LNK

.PHONY: all install clean shost
