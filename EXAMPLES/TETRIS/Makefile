# Makefile for the CGA Tetris example (EXAMPLES/TETRIS/).
#
# Builds TETRIS.EXE (DOS MZ, real-mode CGA mode 4) from:
#   TETRIS.ASM  -- CGA sprite blitter  -> TETRIS.RDF (assembled by TASM)
#   TETRIS.MOD  -- game logic (Oberon) -> compiled + linked, pulls in
#                  TETRIS.RDF via the (*$L TETRIS.RDF*) directive.
#
# The stdlib (SYSTEM) lives in OBERON.OM, and TOC.EXE / TASM.EXE are copied
# locally so xt finds them in the CWD (same rationale as SRC/TASM/Makefile:
# no -c, xt uses the process CWD as the C:\ mount root).
#
# Usage:
#   make          -- assemble + compile + link -> TETRIS.EXE
#   make run      -- build then run under xt
#   make clean    -- remove build products and local tool copies

BIN_DIR  = ../../BIN
BIN_TOC  = $(BIN_DIR)/TOC.EXE
BIN_OM   = $(BIN_DIR)/OBERON.OM

XT     = xt
XTRUN  = $(XT) run --max=300000000
TOC    = TOC.EXE
TASM   = TASM.EXE
TA2NASM = TA2NASM.EXE
OBERON_OM = OBERON.OM

all: TETRIS.EXE TET286.EXE

# The toolchain is three binaries: TOC.EXE is only a driver and execs
# TOCC.EXE/TOCL.EXE from its OWN directory, so all three must be staged
# here together.
$(TOC): $(BIN_TOC) $(BIN_DIR)/TOCC.EXE $(BIN_DIR)/TOCL.EXE
	cp $(BIN_TOC) $(TOC)
	cp $(BIN_DIR)/TOCC.EXE TOCC.EXE
	cp $(BIN_DIR)/TOCL.EXE TOCL.EXE

$(TASM): $(BIN_DIR)/$(TASM)
	cp $(BIN_DIR)/$(TASM) $(TASM)

$(TA2NASM): $(BIN_DIR)/$(TA2NASM)
	cp $(BIN_DIR)/$(TA2NASM) $(TA2NASM)

$(OBERON_OM): $(BIN_DIR)/$(OBERON_OM)
	cp $(BIN_DIR)/$(OBERON_OM) $(OBERON_OM)

# CGA blitter -> RDOFF2 object, consumed by TETRIS.MOD's $L directive.
TETRIS.RDF: TETRIS.ASM $(TASM) $(TA2NASM)
	$(XTRUN) $(TA2NASM) TETRIS.ASM
	$(XTRUN) $(TASM) TETRIS.NAS
	rm TETRIS.NAS

TETRIS.EXE: TETRIS.MOD TETRIS.RDF $(TOC) $(OBERON_OM)
	$(XTRUN) $(TOC) /G /CD /ENTRY=Run TETRIS.MOD /M

TET286.EXE: TET286.MOD TETRIS.MOD TETRIS.RDF $(TOC) OBERON.OM
	$(XTRUN) $(TOC) /G /CP /ENTRY=Run TET286.MOD /M

run: TETRIS.EXE
	$(XTRUN) TETRIS.EXE

clean:
	rm -f *.OM *.EXE *.RDF *.DEF *.LNK

.PHONY: all run clean
