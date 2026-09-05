BIN_DIR   = ../../BIN
BOOT_DIR  = ../../BOOT
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TOLIB     = TOLIB.EXE
XT        = xt
XTRUN     = $(XT) run --max=40000000000

TRUBO_SRCS = STRTAB.MOD LOGERR.MOD RDOFF.MOD TAR.MOD

all: $(TRUBO_OM)

# The toolchain is three binaries: TOC.EXE is only a driver and execs
# TOCC.EXE/TOCL.EXE from its OWN directory, so all three must be staged
# here together -- staging the driver alone gives "toc: cannot exec
# TOCC.EXE" on the first compile.
$(TOC): $(BOOT_DIR)/$(TOC) $(BOOT_DIR)/TOCC.EXE $(BOOT_DIR)/TOCL.EXE
	cp $(BOOT_DIR)/$(TOC) $(TOC)
	cp $(BOOT_DIR)/TOCC.EXE TOCC.EXE
	cp $(BOOT_DIR)/TOCL.EXE TOCL.EXE

$(TOLIB): $(BOOT_DIR)/$(TOLIB)
	cp $(BOOT_DIR)/$(TOLIB) $(TOLIB)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

$(TRUBO_OM): $(TRUBO_SRCS) $(TOC) $(TOLIB) $(OBERON_OM)
	$(XTRUN) $(TOC) LOGERR.MOD
	$(XTRUN) $(TOC) STRTAB.MOD
	$(XTRUN) $(TOC) RDOFF.MOD
	$(XTRUN) $(TOC) TAR.MOD
	rm -f $(TRUBO_OM)
	$(XTRUN) $(TOLIB) merge $(TRUBO_OM) LOGERR.OM STRTAB.OM RDOFF.OM TAR.OM

install: $(TRUBO_OM)
	mkdir -p $(BIN_DIR)
	cp $(TRUBO_OM) $(BIN_DIR)/$(TRUBO_OM)

clean:
	rm -f *.OM *.EXE

.PHONY: all install clean
