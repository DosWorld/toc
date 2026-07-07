MODULE Is57b;
TYPE
  Base  = RECORD x: INTEGER END;
  Ext   = RECORD (Base) y: INTEGER END;
  PBase = POINTER TO Base;
VAR p: PBase; b: BOOLEAN;
BEGIN
  b := p IS Ext;
END Is57b.
