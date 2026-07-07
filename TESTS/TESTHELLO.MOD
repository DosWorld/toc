MODULE TestHello;

IMPORT Dos, Out;

PROCEDURE RunAllTests*;
VAR i : INTEGER;
    p : ARRAY 127 OF CHAR;
BEGIN
    i := 1;
    WHILE i <= Dos.ParamCount() DO
        Dos.ParamStr(i, p);
        IF i # 1 THEN
            Out.Char(' ')
        END;
        Out.String(p);
        INC(i)
    END;
    Out.Ln
END RunAllTests;

END TestHello.
