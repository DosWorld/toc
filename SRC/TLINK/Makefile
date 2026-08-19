BIN_DIR   = ../../BIN
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TLINK     = TLINK.EXE
OVR       = TLINK.OVR
XT        = xt
XTRUN     = $(XT) run --max=300000000 --memkb=640

all: $(TLINK)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

$(TOC): $(BIN_DIR)/$(TOC)
	cp $(BIN_DIR)/$(TOC) $(TOC)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

$(TLINK): TLINK.MOD TEXE.MOD BGI2.MOD BIN.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	$(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /LOG=debug /ENTRY=Run TLINK.MOD /M
	[ -f $(OVR) ] && cat $(OVR) >>$(TLINK) || (echo "$(OVR) not found")

install: TLINK.EXE
	mkdir -p $(BIN_DIR)
	cp $(TLINK) $(BIN_DIR)/$(TLINK)

clean:
	rm -f *.OM *.EXE $(OVR)

.PHONY: all install clean
