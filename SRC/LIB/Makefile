BOOT_OC = ../../BOOT/TOC.EXE
OC = toc.exe
OCFLAGS = /LOG=debug
XT      = xt

# xt mounts the current directory (SRC/LIB) as C:\, so the compiler, the .MOD
# sources and SYS.RDF are all found in the CWD and compiled .OM files land here.
# Host-side cp paths reach the repo root via ../../ (this dir is SRC/LIB).
# EMS is left enabled: BOOT/TOC.EXE carries the EMS-backend fixes (correct
# EMS.MOD MoveDesc layout + the unified Files.MOD buffered EMS path,
# 2026-06-26), so it builds correctly under xt's EMS emulation without --noems.
XTRUN = $(XT) run

STDLIB_OMS = SYSTEM.OM OUT.OM OUT87.OM IN.OM STRINGS.OM FILES.OM \
             CRT.OM DOS.OM IO.OM RDFLOAD.OM MATH.OM TEST.OM EMS.OM TIME.OM \
             LOGERR.OM RDOFF.OM TAR.OM

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
	$(XTRUN) $(OC) $(OCFLAGS) /SYSTEM SYSTEM.MOD

RDFLOAD.OM: RDFLOAD.MOD FILES.OM STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) RDFLOAD.MOD

TEST.OM: TEST.MOD OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) TEST.MOD

OUT.OM: OUT.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) OUT.MOD

OUT87.OM: OUT87.MOD OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) OUT87.MOD

IN.OM: IN.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) IN.MOD

# (*$L EMSAPI.RDF*) inside EMS.MOD is resolved from the CWD (this dir) --
# same pattern as SYSTEM.OM + SYS.RDF.  EMSAPI.RDF is a checked-in binary,
# same as SYS.RDF: no rule here to rebuild it from EMSAPI.ASM.
EMS.OM: EMSAPI.RDF EMS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) EMS.MOD

FILES.OM: FILES.MOD EMS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) FILES.MOD

STRINGS.OM: STRINGS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) STRINGS.MOD

DOS.OM: DOS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) DOS.MOD

CRT.OM: CRT.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) CRT.MOD

IO.OM: IO.MOD FILES.OM OUT.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) IO.MOD

TIME.OM: TIME.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) TIME.MOD

MATH.OM: MATH.MOD $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) MATH.MOD

# Err/Rdoff/Tar were moved here from SRC/TOC (2026-07-11) -- previously
# compiler-internal, now merged into OBERON.OM like every other stdlib
# module so toc.exe and any tool (RDFGREP, TOLIB, TOSTRIP, TASM, ...) can
# `IMPORT LogErr`/`IMPORT Rdoff`/`IMPORT Tar` with no OBERON_LIB entry
# needed.  Err was renamed to LogErr (ERR.MOD -> LOGERR.MOD) in the same move.
LOGERR.OM: LOGERR.MOD IO.OM FILES.OM STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) LOGERR.MOD

RDOFF.OM: RDOFF.MOD FILES.OM LOGERR.OM STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) RDOFF.MOD

TAR.OM: TAR.MOD FILES.OM LOGERR.OM STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) TAR.MOD

clean:
	rm -f $(STDLIB_OMS) ../../BIN/OBERON.OM

.PHONY: all install clean
