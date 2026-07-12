#!/bin/bash
# Clean rebuild helper for iterating on TASM during development.
# Always fully cleans (both .OM and .om, case-insensitive-fs safe) before
# rebuilding with /M, to avoid stale-.om confusion seen during bring-up.
# Does NOT touch TOC_BOOT.EXE (the bootstrap) or OBERON.OM (the stdlib).
set -e
cd "$(dirname "$0")"
rm -f LEX.OM SCAN.OM SYM.OM ENC.OM DIR.OM PARSE.OM TASM.OM \
      lex.om scan.om sym.om enc.om dir.om parse.om tasm.om \
      TASM.exe TASM.EXE
xt run --max=200000000 TOC_BOOT.EXE /LOG=debug /M /ENTRY=Run TASM.MOD
