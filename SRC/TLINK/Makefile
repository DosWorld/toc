BIN_DIR   = ../../BIN
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TASM      = TASM.EXE
TLINK     = TLINK.EXE
OVR       = TLINK.OVR
XT        = xt
XTRUN     = $(XT) run --max=2000000000 --memkb=640

all: $(TLINK)

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

$(TASM): $(BIN_DIR)/$(TASM)
	cp $(BIN_DIR)/$(TASM) $(TASM)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

NESTAB.RDF: NESTAB.BIN $(TASM)
	$(XTRUN) $(TASM) /BIN=code /NAME=NE_NESTAB NESTAB.BIN

$(TLINK): TLINK.MOD TEXE.MOD BGI2.MOD BIN.MOD NE.MOD NESTAB.RDF $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /LOG=debug /ENTRY=Run TLINK.MOD /M
	[ -f $(OVR) ] && cat $(OVR) >>$(TLINK) || (echo "$(OVR) not found")

install: TLINK.EXE
	mkdir -p $(BIN_DIR)
	cp $(TLINK) $(BIN_DIR)/$(TLINK)

clean:
	rm -f *.OM *.EXE $(OVR)

.PHONY: all install clean
