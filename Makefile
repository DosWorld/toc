.PHONY: all lib toc tools tasm tlink clean test testall trubo

XT      = xt
BOOTOC  = BOOT/TOC.EXE
BOOTOLIB = BOOT/TOLIB.EXE

# ── Full build ───────────────────────────────────────────────────────────
# 1. Compile stdlib → BIN/OBERON.OM  (using BOOT/TOC.EXE + BOOT/TOLIB.EXE)
# 2. Build BIN/TOC.EXE  (using BOOT/TOC.EXE, OBERON_LIB=BIN/OBERON.OM)
# 3. Build tools incl. BIN/TOLIB.EXE (using BIN/TOC.EXE)
all: lib toc tasm tlink tools trubo

# ── Standard library → BIN/OBERON.OM ─────────────────────────────────────
# BOOT/TOC.EXE compiles each module; BOOT/TOLIB.EXE merges into OBERON.OM.
lib:
	$(MAKE) -C SRC/LIB clean
	$(MAKE) -C SRC/LIB install

trubo:
	$(MAKE) -C SRC/TRUBO clean
	$(MAKE) -C SRC/TRUBO install

# ── Compiler → BIN/TOC.EXE ───────────────────────────────────────────────
# BOOT/TOC.EXE compiles all modules; links toc.exe (auto-named TOC.exe).
toc: lib trubo
	$(MAKE) -C SRC/TOC clean
	$(MAKE) -C SRC/TOC install

tasm: lib toc trubo
	$(MAKE) -C SRC/TASM clean
	$(MAKE) -C SRC/TASM install

tlink: lib toc trubo
	$(MAKE) -C SRC/TLINK clean
	$(MAKE) -C SRC/TLINK install

# ── Auxiliary tools → BIN/ ───────────────────────────────────────────────
# RDFGREP.EXE, TESTALL.EXE, TDINFO.EXE, TOSTRIP.EXE and TOLIB.EXE are all
# compiled by BIN/TOC.EXE.
tools: toc trubo
	$(MAKE) -C SRC/TOOLS clean
	$(MAKE) -C SRC/TOOLS install

# ── Testing ──────────────────────────────────────────────────────────────

test:
	$(MAKE) clean
	$(MAKE) all
	make -f TESTS/Makefile.man test
	bash TESTS/test_tasm.sh
	bash TESTS/test_tlink.sh

testall: tools
	cp BIN/TOC.EXE TOC.EXE
	cp BIN/TESTALL.EXE TESTALL.EXE
	$(XT) run TESTALL.EXE .
	rm -f TOC.EXE TESTALL.EXE

# ── Clean ────────────────────────────────────────────────────────────────
clean:
	$(MAKE) -C SRC/LIB clean
	$(MAKE) -C SRC/TRUBO clean
	$(MAKE) -C SRC/TOC clean
	$(MAKE) -C SRC/TASM clean
	$(MAKE) -C SRC/TLINK clean
	$(MAKE) -C SRC/TOOLS clean
	rm -f BIN/OBERON.OM
	rm -f BIN/TOC.EXE BIN/TOLIB.EXE BIN/RDFGREP.EXE BIN/TESTALL.EXE BIN/TDINFO.EXE BIN/TOSTRIP.EXE
