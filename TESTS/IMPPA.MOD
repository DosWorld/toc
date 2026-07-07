MODULE IMPPA;

TYPE
  Node* = POINTER TO NodeDesc;
  NodeDesc* = RECORD
    value*: INTEGER;
    next*: Node
  END;

VAR
  Head*: Node;

PROCEDURE Init*;
BEGIN
  NEW(Head);
  Head^.value := 42;
  Head^.next := NIL
END Init;

END IMPPA.
