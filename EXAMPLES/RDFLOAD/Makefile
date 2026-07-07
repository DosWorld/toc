OC  = ../../bin/toc.exe
XT  = xt
XTRUN = $(XT) run --max=40000000 -c ../..

all: MAIN.EXE

MAIN.EXE: MAIN.MOD $(OC)
	$(XTRUN) $(OC) /ENTRY=Run examples\\RDFLOAD\\MAIN.MOD

TEST.RDF: TEST.ASM
	nasm -f rdf TEST.ASM

clean:
	del *.bak
	del *.exe
	del *.om
