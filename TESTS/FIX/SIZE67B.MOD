MODULE Size67b;
TYPE
  Pt   = RECORD x, y: INTEGER END;
  Vec  = ARRAY 10 OF INTEGER;
  Node = POINTER TO NodeDesc;
  NodeDesc = RECORD val: INTEGER; next: Node END;
CONST
  PtS   = SIZE(Pt);
  VecS  = SIZE(Vec);
  NodeS = SIZE(Node);
  RecS  = SIZE(NodeDesc);
VAR x: INTEGER;
BEGIN x := PtS; x := VecS; x := NodeS; x := RecS
END Size67b.
