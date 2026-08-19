BIN_DIR   = ../../BIN
BOOT_DIR  = ../../BOOT
OBERON_OM = OBERON.OM
TRUBO_OM  = TRUBO.OM
TOC       = TOC.EXE
TASM      = TASM.EXE
TASM_OVR  = TASM.OVR
TA2NASM   = TA2NASM.EXE
TA2NASM_OVR= TA2NASM.OVR
SPHO      = SPHO.EXE
SPHO_OVR  = SPHO.OVR
XT        = xt
XTRUN     = $(XT) run --max=2000000000 --memkb=640

TASM_SRCS = SCAN.MOD SYM.MOD ENC.MOD DIR.MOD PARSE.MOD TASM.MOD

all: $(TASM) $(TA2NASM) $(SPHO)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

$(TRUBO_OM): $(BIN_DIR)/$(TRUBO_OM)
	cp $(BIN_DIR)/$(TRUBO_OM) $(TRUBO_OM)

$(TOC):  $(BIN_DIR)/$(TOC)
	cp  $(BIN_DIR)/$(TOC) $(TOC)

$(TASM): $(TASM_SRCS) $(TOC) $(OBERON_OM) $(TRUBO_OM)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /ENTRY=Run TASM.MOD /M
	[ -f $(TASM_OVR) ] && cat $(TASM_OVR) >>$(TASM) || (echo "$(TASM_OVR) not found")

$(TA2NASM): TA2NASM.MOD TURBO.MOD TURBODIR.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /ENTRY=Run TA2NASM.MOD /M
	[ -f $(TA2NASM_OVR) ] && cat $(TA2NASM_OVR) >>$(TA2NASM) || (echo "$(TA2NASM_OVR) not found")

$(SPHO): SPHO.MOD SPHOLEX.MOD LEX.MOD $(TOC) $(OBERON_OM) $(TRUBO_OM)
	time $(XTRUN) -e "OBERON_LIB=$(TRUBO_OM)" $(TOC) /CD /ENTRY=Run SPHO.MOD /M
	[ -f $(SPHO_OVR) ] && cat $(SPHO_OVR) >>$(SPHO) || (echo "$(SPHO_OVR) not found")

install: $(TASM) $(TA2NASM) $(SPHO)
	mkdir -p $(BIN_DIR)
	cp $(TASM) $(BIN_DIR)/$(TASM)
	cp $(TA2NASM) $(BIN_DIR)/$(TA2NASM)
	cp $(SPHO) $(BIN_DIR)/$(SPHO)

clean:
	rm -f *.OM *.EXE *.OVR

.PHONY: all install clean
