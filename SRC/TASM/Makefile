BIN_DIR   = ../../BIN
BOOT_DIR  = ../../BOOT
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TASM      = TASM.EXE
TASM_OVR  = TASM.OVR
TA2NASM   = TA2NASM.EXE
TA2NASM_OVR= TA2NASM.OVR
XT        = xt
XTRUN     = $(XT) run --max=2000000000 --memkb=640

TASM_SRCS = SCAN.MOD SYM.MOD ENC.MOD DIR.MOD PARSE.MOD TASM.MOD

all: $(TASM) $(TA2NASM)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

# The toolchain is three binaries: TOC.EXE is only a driver and execs
# TOCC.EXE/TOCL.EXE from its OWN directory, so all three must be staged
# here together.
$(TOC): $(BIN_DIR)/$(TOC) $(BIN_DIR)/TOCC.EXE $(BIN_DIR)/TOCL.EXE
	cp $(BIN_DIR)/$(TOC) $(TOC)
	cp $(BIN_DIR)/TOCC.EXE TOCC.EXE
	cp $(BIN_DIR)/TOCL.EXE TOCL.EXE

$(TASM): $(TASM_SRCS) $(TOC) $(OBERON_OM) $(TRUBO_OM)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /ENTRY=Run TASM.MOD /M
	[ -f $(TASM_OVR) ] && cat $(TASM_OVR) >>$(TASM) || (echo "$(TASM_OVR) not found")

$(TA2NASM): TA2NASM.MOD TURBO.MOD TURBODIR.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /ENTRY=Run TA2NASM.MOD /M
	[ -f $(TA2NASM_OVR) ] && cat $(TA2NASM_OVR) >>$(TA2NASM) || (echo "$(TA2NASM_OVR) not found")

install: $(TASM) $(TA2NASM)
	mkdir -p $(BIN_DIR)
	cp $(TASM) $(BIN_DIR)/$(TASM)
	cp $(TA2NASM) $(BIN_DIR)/$(TA2NASM)

clean:
	rm -f *.OM *.EXE *.OVR *.LNK

.PHONY: all install clean
