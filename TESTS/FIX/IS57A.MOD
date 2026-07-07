MODULE Is57a;
TYPE
  Base  = RECORD x: INTEGER END;
  Ext   = RECORD (Base) y: INTEGER END;
  PBase = POINTER TO Base;
  PExt  = POINTER TO Ext;
VAR p: PExt; b: BOOLEAN;
BEGIN
  b := p IS Base;
END Is57a.
