BOOT_OC = ../../BOOT/TOC.EXE
OC = toc.exe
XT      = xt

# xt mounts the current directory (SRC/LIB) as C:\, so the compiler, the .MOD
# sources and SYS.RDF are all found in the CWD and compiled .OM files land here.
# Host-side cp paths reach the repo root via ../../ (this dir is SRC/LIB).
# EMS is left enabled: BOOT/TOC.EXE carries the EMS-backend fixes (correct
# EMS.MOD MoveDesc layout + the unified Files.MOD buffered EMS path,
# 2026-06-26), so it builds correctly under xt's EMS emulation without --noems.
XTRUN = $(XT) run

STDLIB_OMS = SYSTEM.OM OUT.OM OUT87.OM IN.OM STRINGS.OM FILES.OM \
             CRT.OM DOS.OM IO.OM RDFLOAD.OM MATH.OM TEST.OM EMS.OM TIME.OM

all: $(STDLIB_OMS)

install: all
	cp ../../BOOT/TOLIB.EXE tolib.exe
	ls *.OM 2>/dev/null | grep -iv "oberon\|tolib\|toc\.exe" > oberon.lst
	$(XTRUN) tolib.exe merge OBERON.OM @oberon.lst
	mkdir -p ../../BIN
	cp OBERON.OM ../../BIN/OBERON.OM
	rm -f oberon.lst OBERON.OM tolib.exe toc.exe

$(OC): $(BOOT_OC)
	cp $(BOOT_OC) $(OC)

# SYSTEM is special: /SYSTEM flag, no dep-scan.
# (*$L SYS.RDF*) inside SYSTEM.MOD is resolved from the CWD (this dir).
SYSTEM.OM: SYS.RDF SYSTEM.MOD $(OC)
	$(XTRUN) $(OC) /SYSTEM SYSTEM.MOD

RDFLOAD.OM: RDFLOAD.MOD FILES.OM STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) RDFLOAD.MOD

TEST.OM: TEST.MOD OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) TEST.MOD

OUT.OM: OUT.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) OUT.MOD

OUT87.OM: OUT87.MOD OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) OUT87.MOD

IN.OM: IN.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) IN.MOD

EMS.OM: EMS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) EMS.MOD

FILES.OM: FILES.MOD EMS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) FILES.MOD

STRINGS.OM: STRINGS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) STRINGS.MOD

DOS.OM: DOS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) DOS.MOD

CRT.OM: CRT.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) CRT.MOD

IO.OM: IO.MOD FILES.OM OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) IO.MOD

TIME.OM: TIME.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) TIME.MOD

MATH.OM: MATH.MOD $(OC)
	$(XTRUN) $(OC) MATH.MOD

clean:
	rm -f $(STDLIB_OMS) ../../BIN/OBERON.OM

.PHONY: all install clean
