BIN_DIR   = ../../BIN
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
XT        = xt
XTRUN     = $(XT) run --max=300000000

all: TLINK.EXE

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

$(TOC): $(BIN_DIR)/$(TOC)
	cp $(BIN_DIR)/$(TOC) $(TOC)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

TLINK.EXE: TLINK.MOD TEXE.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /LOG=debug /ENTRY=Run TLINK.MOD /M

install: TLINK.EXE
	mkdir -p $(BIN_DIR)
	cp TLINK.EXE $(BIN_DIR)/TLINK.EXE

clean:
	rm -f *.OM *.EXE

.PHONY: all install clean
