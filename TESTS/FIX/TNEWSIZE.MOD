MODULE Tnewsize;
TYPE Node = RECORD x: INTEGER END;
TYPE PNode = POINTER TO Node;
VAR p: PNode; n: INTEGER;
BEGIN n := 10; NEW(p, n) END Tnewsize.
