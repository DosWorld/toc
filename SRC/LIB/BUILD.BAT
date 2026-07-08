@echo off

toc /SYSTEM SYSTEM.MOD
toc OUT.MOD
toc OUT87.MOD
toc IN.MOD
toc EMS.MOD
toc FILES.MOD
toc STRINGS.MOD
toc DOS.MOD
toc CRT.MOD
toc TIME.MOD
toc MATH.MOD
toc IO.MOD
toc RDFLOAD.MOD
toc TEST.MOD

echo SYSTEM.MOD > oberon.lst
echo OUT.MOD >> oberon.lst
echo OUT87.MOD >> oberon.lst
echo IN.MOD >> oberon.lst
echo EMS.MOD >> oberon.lst
echo FILES.MOD >> oberon.lst
echo STRINGS.MOD >> oberon.lst
echo DOS.MOD >> oberon.lst
echo CRT.MOD >> oberon.lst
echo TIME.MOD >> oberon.lst
echo MATH.MOD >> oberon.lst
echo IO.MOD >> oberon.lst
echo RDFLOAD.MOD >> oberon.lst
echo TEST.MOD >> oberon.lst

del OBERON.OM
tolib.exe merge OBERON.OM @oberon.lst
del oberon.lst

copy OBERON.OM ..\BIN\

