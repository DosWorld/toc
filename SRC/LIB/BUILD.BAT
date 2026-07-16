@echo off

del *.om

..\..\BIN\toc /SYSTEM SYSTEM.MOD
..\..\BIN\toc OUT.MOD
..\..\BIN\toc OUT87.MOD
..\..\BIN\toc IN.MOD
..\..\BIN\toc EMS.MOD
..\..\BIN\toc FILES.MOD
..\..\BIN\toc STRINGS.MOD
..\..\BIN\toc DOS.MOD
..\..\BIN\toc CRT.MOD
..\..\BIN\toc TIME.MOD
..\..\BIN\toc MATH.MOD
..\..\BIN\toc IO.MOD
..\..\BIN\toc RDFLOAD.MOD
..\..\BIN\toc TEST.MOD
..\..\BIN\toc LOGERR.MOD
..\..\BIN\toc RDOFF.MOD
..\..\BIN\toc TAR.MOD
..\..\BIN\toc DETECT.MOD
..\..\BIN\toc KMOUSE.MOD
..\..\BIN\toc WINCB.MOD
..\..\BIN\toc SCREEN.MOD

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
echo RDOFF.MOD >> oberon.lst
echo TAR.MOD >> oberon.lst
echo LOGERR.MOD >> oberon.lst
echo TEST.MOD >> oberon.lst
echo DETECT.MOD >> oberon.lst
echo KMOUSE.MOD >> oberon.lst
echo WINCB.MOD >> oberon.lst
echo SCREEN.MOD >> oberon.lst

del OBERON.OM
..\..\BIN\tolib.exe merge OBERON.OM @oberon.lst
del oberon.lst

copy OBERON.OM ..\BIN\

