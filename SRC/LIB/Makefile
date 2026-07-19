BOOT_OC = ../../BOOT/TOC.EXE
BOOT_TASM = ../../BOOT/TASM.EXE
OC = TOC.EXE
OCFLAGS = /LOG=debug
XT      = xt

# xt mounts the current directory (SRC/LIB) as C:\, so the compiler, the .MOD
# sources and SYSTEM.RDF are all found in the CWD and compiled .OM files land here.
# Host-side cp paths reach the repo root via ../../ (this dir is SRC/LIB).
# EMS is left enabled: BOOT/TOC.EXE carries the EMS-backend fixes (correct
# EMS.MOD MoveDesc layout + the unified Files.MOD buffered EMS path,
# 2026-06-26), so it builds correctly under xt's EMS emulation without --noems.
XTRUN = $(XT) run

STDLIB_OMS = SYSTEM.OM OUT.OM OUT87.OM IN.OM STRINGS.OM FILES.OM \
             CRT.OM DOS.OM IO.OM RDFLOAD.OM MATH.OM TEST.OM EMS.OM TIME.OM \
             LOGERR.OM RDOFF.OM TAR.OM DETECT.OM WINCB.OM KMOUSE.OM SCREEN.OM BASE64.OM

all: $(STDLIB_OMS)

install: all
	cp ../../BOOT/TOLIB.EXE TOLIB.EXE
	ls *.OM 2>/dev/null | grep -iv "OBERON\|TOLIB\|TOC\.EXE" > oberon.lst
	$(XTRUN) TOLIB.EXE merge OBERON.OM @oberon.lst
	mkdir -p ../../BIN
	cp OBERON.OM ../../BIN/OBERON.OM
	rm -f oberon.lst

$(OC): $(BOOT_OC)
	cp $(BOOT_OC) $(OC)

# SYSTEM is special: /SYSTEM flag, no dep-scan.
# (*$L SYSTEM.RDF*) inside SYSTEM.MOD is resolved from the CWD (this dir).
# SYSTEM.RDF itself is a CHECKED-IN binary, same discipline as BOOT/TOC.EXE:
# it is the tool of record's OUTPUT, not rebuilt as part of `make all`
# (TASM needs a fully-built OBERON.OM -- Files/Strings/LogErr/Rdoff/Out/Dos
# -- to run at all, and OBERON.OM's own SYSTEM.OM is built FROM SYSTEM.RDF, so
# TASM cannot be a hard prerequisite here without a circular dependency).
# BOOT/TASM.EXE (an immutable bootstrap binary, same status as
# BOOT/TOC.EXE/BOOT/TOLIB.EXE) is the tool of record for SYSTEM.ASM->SYSTEM.RDF,
# EMS.ASM->EMS.RDF, DETECT.ASM->DETECT.RDF, WINCB.ASM->WINCB.RDF,
# KMOUSE.ASM->KMOUSE.RDF, and SCREEN.ASM->SCREEN.RDF: run `make regen-asm`
# after editing any .ASM file, verify TESTS/test_tasm.sh still agrees,
# then commit the regenerated .RDF alongside the .ASM change.
SYSTEM.OM: SYSTEM.RDF SYSTEM.MOD $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) /SYSTEM SYSTEM.MOD

# regen-asm: rebuild SYSTEM.RDF/EMS.RDF/DETECT.RDF/WINCB.RDF/KMOUSE.RDF from
# their .ASM sources via BOOT/TASM.EXE, overwriting the checked-in files.
# Not part of `all`/`install` (see the SYSTEM.OM comment above for why) --
# run manually after editing any .ASM file, then re-run `make all` to pick
# up the regenerated .RDF and TESTS/test_tasm.sh to confirm TASM's own
# output still agrees with itself.
regen-asm:
	cp $(BOOT_TASM) TASM.EXE
	$(XTRUN) TASM.EXE $(OCFLAGS) SYSTEM.ASM
	$(XTRUN) TASM.EXE $(OCFLAGS) EMS.ASM
	$(XTRUN) TASM.EXE $(OCFLAGS) DETECT.ASM
	$(XTRUN) TASM.EXE $(OCFLAGS) WINCB.ASM
	$(XTRUN) TASM.EXE $(OCFLAGS) KMOUSE.ASM
	$(XTRUN) TASM.EXE $(OCFLAGS) SCREEN.ASM
	rm -f TASM.EXE

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

# (*$L EMS.RDF*) inside EMS.MOD is resolved from the CWD (this dir) --
# same pattern as SYSTEM.OM + SYSTEM.RDF.  EMS.RDF is a checked-in binary
# for the same circular-dependency reason as SYSTEM.RDF (see SYSTEM.OM's
# comment above) -- regenerate it via `make regen-asm`, not this rule.
EMS.OM: EMS.RDF EMS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) EMS.MOD

FILES.OM: FILES.MOD EMS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) FILES.MOD

STRINGS.OM: STRINGS.MOD SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) STRINGS.MOD

BASE64.OM: BASE64.MOD STRINGS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) BASE64.MOD

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

# (*$L DETECT.RDF*) inside DETECT.MOD is resolved from the CWD (this dir)
# -- same pattern as SYSTEM.OM + SYSTEM.RDF.  DETECT.RDF is a checked-in
# binary for the same circular-dependency reason as SYSTEM.RDF (see
# SYSTEM.OM's comment above) -- regenerate it via `make regen-asm`, not
# this rule.
DETECT.OM: DETECT.MOD DETECT.RDF SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) DETECT.MOD

# (*$L WINCB.RDF*) inside WINCB.MOD is resolved from the CWD (this dir) --
# same pattern as SYSTEM.OM + SYSTEM.RDF.  WINCB.RDF is a checked-in binary
# for the same circular-dependency reason as SYSTEM.RDF (see SYSTEM.OM's
# comment above) -- regenerate it via `make regen-asm`, not this rule.
WINCB.OM: WINCB.MOD WINCB.RDF SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) WINCB.MOD

# (*$L KMOUSE.RDF*) inside KMOUSE.MOD is resolved from the CWD (this dir)
# -- same pattern as SYSTEM.OM + SYSTEM.RDF.  KMOUSE.RDF is a checked-in
# binary for the same circular-dependency reason as SYSTEM.RDF (see
# SYSTEM.OM's comment above) -- regenerate it via `make regen-asm`, not
# this rule.
KMOUSE.OM: KMOUSE.MOD KMOUSE.RDF SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) KMOUSE.MOD

# (*$L SCREEN.RDF*) inside SCREEN.MOD is resolved from the CWD (this dir)
# -- same pattern as SYSTEM.OM + SYSTEM.RDF.  SCREEN.RDF is a checked-in
# binary for the same circular-dependency reason as SYSTEM.RDF (see
# SYSTEM.OM's comment above) -- regenerate it via `make regen-asm`, not
# this rule.
SCREEN.OM: SCREEN.MOD SCREEN.RDF DETECT.OM KMOUSE.OM DOS.OM SYSTEM.OM $(OC)
	$(XTRUN) $(OC) $(OCFLAGS) SCREEN.MOD

clean:
	rm -f *.EXE *.OM OUTPUT.LOG

.PHONY: all install clean regen-asm
