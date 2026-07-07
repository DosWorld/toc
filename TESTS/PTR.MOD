MODULE PTR;
IMPORT Test;

TYPE
  PnPRec  = POINTER TO RECORD a, b: INTEGER END;
  PnPArr  = POINTER TO ARRAY 10 OF INTEGER;
  PnPChar = POINTER TO ARRAY 16 OF CHAR;
  PnNode  = POINTER TO RECORD
    val:  INTEGER;
  Pnnext: PnNode
  END;
  VpPRec = POINTER TO RECORD a, b: INTEGER END;
  VpNode = POINTER TO RECORD val: INTEGER; next: VpNode END;
  DyNode* = POINTER TO RECORD val: INTEGER; next: DyNode END;
  DyTreeNode* = POINTER TO RECORD key: INTEGER; left, right: DyTreeNode END;

VAR
  Pngp: PnPRec;
  Pngn: PnNode;
  Vpg: VpPRec;
  VpgList: VpNode;

PROCEDURE PnTNilCheck*;
VAR p: PnPRec;
BEGIN
  p := NIL;
  Test.AssertNil(p, "p = NIL before NEW");
  NEW(p);
  Test.AssertNotNil(p, "p # NIL after NEW");
  DISPOSE(p);
  p := NIL;
  Test.AssertNil(p, "p = NIL after dispose+assign");
  Test.AssertNil(SYSTEM.PTR(0, 0), "0:0 = NIL");
  Test.AssertNotNil(SYSTEM.PTR(0, 1), "0:1 # NIL");
  Test.AssertNotNil(SYSTEM.PTR(1, 0), "1:0 # NIL");
  Test.AssertNotNil(SYSTEM.PTR(1, 2), "1:2 # NIL");
  Test.AssertNotNil(SYSTEM.ADR(PnTNilCheck), "SYSTEM.ADR(PnTNilCheck) # NIL")
END PnTNilCheck;

PROCEDURE PnTPtrRecord*;
VAR p: PnPRec;
BEGIN
  NEW(p);
  p^.a := 11; p^.b := 22;
  Test.AssertInt(11, p^.a, "a");
  Test.AssertInt(22, p^.b, "b");
  p^.a := p^.a + p^.b;
  Test.AssertInt(33, p^.a, "a+b");
  Test.AssertInt(22, p^.b, "b unchanged");
  DISPOSE(p)
END PnTPtrRecord;

PROCEDURE PnTPtrArray*;
VAR pa: PnPArr; i, sum: INTEGER;
BEGIN
  NEW(pa);
  FOR i := 0 TO 9 DO pa^[i] := i * 3 END;
  Test.AssertInt(0,  pa^[0], "pa[0]");
  Test.AssertInt(15, pa^[5], "pa[5]");
  Test.AssertInt(27, pa^[9], "pa[9]");
  sum := 0;
  FOR i := 0 TO 9 DO sum := sum + pa^[i] END;
  Test.AssertInt(135, sum, "sum 0..9 *3");
  DISPOSE(pa)
END PnTPtrArray;

PROCEDURE PnTPtrCharArray*;
VAR pc: PnPChar;
BEGIN
  NEW(pc);
  pc^[0] := "H"; pc^[1] := "i"; pc^[2] := CHR(0);
  Test.AssertTrue(pc^[0] = "H",     "pc[0]='H'");
  Test.AssertTrue(pc^[1] = "i",     "pc[1]='i'");
  Test.AssertInt(0, ORD(pc^[2]),     "pc[2]=NUL");
  pc^[0] := CHR(ORD(pc^[0]) + 1);
  Test.AssertTrue(pc^[0] = "I",     "pc[0]='I'");
  DISPOSE(pc)
END PnTPtrCharArray;

PROCEDURE PnTPtrEquality*;
VAR p, q, r: PnPRec;
BEGIN
  NEW(p); NEW(q);
  Test.AssertTrue(p # q, "p # q (different objects)");
  Test.AssertTrue(p = p, "p = p (self)");
  r := p;
  Test.AssertTrue(r = p, "r = p (alias)");
  Test.AssertTrue(r # q, "r # q");
  DISPOSE(p); DISPOSE(q);
  p := NIL; q := NIL;
  Test.AssertTrue(p = q, "nil = nil");
  p := NIL; q := SYSTEM.PTR(0, 0);
  Test.AssertTrue(p = q, "nil = 0:0");
  p := SYSTEM.PTR(1,2);
  q := SYSTEM.PTR(1,3);
  Test.AssertTrue(p # q, "1:2 # 1:3");
  p := SYSTEM.PTR(1,2);
  q := SYSTEM.PTR(3,2);
  Test.AssertTrue(p # q, "1:2 # 3:2");
  p := SYSTEM.PTR(4,5);
  q := SYSTEM.PTR(3,6);
  Test.AssertTrue(p # q, "4:5 # 3:6");
  p := SYSTEM.PTR(1,2);
  q := SYSTEM.PTR(1,2);
  Test.AssertTrue(p = q, "1:2 = 1:2");
END PnTPtrEquality;

PROCEDURE PnTMultiAlloc*;
VAR p1, p2, p3: PnPRec;
BEGIN
  NEW(p1); NEW(p2); NEW(p3);
  p1^.a := 100; p2^.a := 200; p3^.a := 300;
  Test.AssertInt(100, p1^.a, "p1.a");
  Test.AssertInt(200, p2^.a, "p2.a");
  Test.AssertInt(300, p3^.a, "p3.a");
  p2^.a := 999;
  Test.AssertInt(100, p1^.a, "p1.a still 100");
  Test.AssertInt(300, p3^.a, "p3.a still 300");
  DISPOSE(p1); DISPOSE(p2); DISPOSE(p3)
END PnTMultiAlloc;

PROCEDURE PnTGlobalPointer*;
BEGIN
  Pngp := NIL;
  Test.AssertNil(Pngp, "Pngp = NIL initially");
  NEW(Pngp);
  Test.AssertNotNil(Pngp, "Pngp # NIL after NEW");
  Pngp^.a := 42; Pngp^.b := -7;
  Test.AssertInt(42, Pngp^.a, "Pngp.a");
  Test.AssertInt(-7, Pngp^.b, "Pngp.b");
  DISPOSE(Pngp);
  Pngp := NIL
END PnTGlobalPointer;

PROCEDURE PnReadThroughPtr(p: PnPRec): INTEGER;
BEGIN RETURN p^.a + p^.b END PnReadThroughPtr;

PROCEDURE PnTPtrValueParam*;
VAR p: PnPRec;
BEGIN
  NEW(p); p^.a := 5; p^.b := 7;
  Test.AssertInt(12, PnReadThroughPtr(p), "a+b via ptr param");
  DISPOSE(p)
END PnTPtrValueParam;

PROCEDURE PnNewAndInit(VAR p: PnPRec; av, bv: INTEGER);
BEGIN NEW(p); p^.a := av; p^.b := bv END PnNewAndInit;

PROCEDURE PnTPtrVarParam*;
VAR p: PnPRec;
BEGIN
  p := NIL;
  PnNewAndInit(p, 8, 9);
  Test.AssertNotNil(p, "p # NIL after PnNewAndInit");
  Test.AssertInt(8, p^.a, "a");
  Test.AssertInt(9, p^.b, "b");
  DISPOSE(p)
END PnTPtrVarParam;

PROCEDURE PnTPtrChain*;
VAR a, b, c, cur: PnNode; sum, count: INTEGER;
BEGIN
  NEW(a); NEW(b); NEW(c);
  a^.val := 1; a^.Pnnext := b;
  b^.val := 2; b^.Pnnext := c;
  c^.val := 3; c^.Pnnext := NIL;
  sum := 0; count := 0;
  cur := a;
  WHILE cur # NIL DO
    sum := sum + cur^.val;
    INC(count);
    cur := cur^.Pnnext
  END;
  Test.AssertInt(3, count, "count");
  Test.AssertInt(6, sum,   "sum");
  Test.AssertInt(2, a^.Pnnext^.val,       "a->b.val");
  Test.AssertInt(3, a^.Pnnext^.Pnnext^.val, "a->b->c.val");
  Test.AssertNil(c^.Pnnext, "c.Pnnext = NIL");
  DISPOSE(a); DISPOSE(b); DISPOSE(c)
END PnTPtrChain;

PROCEDURE PnTNilField*;
VAR p, q: PnNode;
BEGIN
  NEW(p);
  p^.val := 7; p^.Pnnext := NIL;
  Test.AssertNil(p^.Pnnext, "p.Pnnext = NIL");
  NEW(q);
  q^.val := 8; q^.Pnnext := p;
  Test.AssertNotNil(q^.Pnnext, "q.Pnnext # NIL");
  Test.AssertInt(7, q^.Pnnext^.val, "q.Pnnext.val");
  DISPOSE(p); DISPOSE(q)
END PnTNilField;

PROCEDURE PnTPtrReuse*;
VAR p: PnPRec;
BEGIN
  NEW(p); p^.a := 111; p^.b := 222;
  DISPOSE(p);
  NEW(p); p^.a := 333; p^.b := 444;
  Test.AssertInt(333, p^.a, "new a");
  Test.AssertInt(444, p^.b, "new b");
  DISPOSE(p)
END PnTPtrReuse;

PROCEDURE PnTSelfRef*;
VAR root, n2, n3: PnNode; cur: PnNode; depth: INTEGER;
BEGIN
  NEW(root); NEW(n2); NEW(n3);
  root^.val := 10; root^.Pnnext := n2;
  n2^.val   := 20; n2^.Pnnext   := n3;
  n3^.val   := 30; n3^.Pnnext   := NIL;
  depth := 0; cur := root;
  WHILE cur # NIL DO INC(depth); cur := cur^.Pnnext END;
  Test.AssertInt(3, depth, "depth");
  Test.AssertInt(30, root^.Pnnext^.Pnnext^.val, "root->n2->n3.val");
  DISPOSE(root); DISPOSE(n2); DISPOSE(n3)
END PnTSelfRef;

PROCEDURE PnTLargeArrayPtr*;
TYPE BigArr = POINTER TO ARRAY 50 OF INTEGER;
VAR pa: BigArr; i, sum: INTEGER;
BEGIN
  NEW(pa);
  FOR i := 0 TO 49 DO pa^[i] := i + 1 END;
  sum := 0;
  FOR i := 0 TO 49 DO sum := sum + pa^[i] END;
  Test.AssertInt(1275, sum, "sum 1..50");
  Test.AssertInt(1,    pa^[0],  "pa[0]");
  Test.AssertInt(50,   pa^[49], "pa[49]");
  DISPOSE(pa)
END PnTLargeArrayPtr;

PROCEDURE PnBuildGlobalList(n: INTEGER);
VAR i: INTEGER; p: PnNode;
BEGIN
  Pngn := NIL;
  FOR i := 1 TO n DO
    NEW(p); p^.val := i; p^.Pnnext := Pngn; Pngn := p
  END
END PnBuildGlobalList;

PROCEDURE PnFreeGlobalList;
VAR p: PnNode;
BEGIN
  WHILE Pngn # NIL DO p := Pngn^.Pnnext; DISPOSE(Pngn); Pngn := p END
END PnFreeGlobalList;

PROCEDURE PnSumGlobalList(): INTEGER;
VAR s: INTEGER; p: PnNode;
BEGIN
  s := 0; p := Pngn;
  WHILE p # NIL DO s := s + p^.val; p := p^.Pnnext END;
  RETURN s
END PnSumGlobalList;

PROCEDURE PnTGlobalList*;
BEGIN
  PnBuildGlobalList(5);
  Test.AssertInt(15, PnSumGlobalList(), "sum 1..5");
  PnFreeGlobalList;
  Test.AssertNil(Pngn, "Pngn = NIL after free")
END PnTGlobalList;

PROCEDURE VpNewPRec(VAR p: VpPRec; av, bv: INTEGER);
BEGIN NEW(p); p^.a := av; p^.b := bv END VpNewPRec;

PROCEDURE VpBuildList(VAR head: VpNode; n: INTEGER);
VAR p: VpNode; i: INTEGER;
BEGIN
  head := NIL;
  FOR i := n TO 1 BY -1 DO
    NEW(p); p^.val := i; p^.next := head; head := p
  END
END VpBuildList;

PROCEDURE VpSumList(VAR head: VpNode): INTEGER;
VAR s: INTEGER; p: VpNode;
BEGIN
  s := 0; p := head;
  WHILE p # NIL DO s := s + p^.val; p := p^.next END;
  RETURN s
END VpSumList;

PROCEDURE VpTLocal*;
VAR p: VpPRec;
BEGIN
  p := NIL;
  VpNewPRec(p, 11, 22);
  Test.AssertInt(11, p^.a, "local p^.a");
  Test.AssertInt(22, p^.b, "local p^.b");
  DISPOSE(p)
END VpTLocal;

PROCEDURE VpTGlobal*;
BEGIN
  Vpg := NIL;
  VpNewPRec(Vpg, 33, 44);
  Test.AssertInt(33, Vpg^.a, "global Vpg^.a");
  Test.AssertInt(44, Vpg^.b, "global Vpg^.b");
  DISPOSE(Vpg)
END VpTGlobal;

PROCEDURE VpTList*;
VAR head: VpNode; n, last: INTEGER;
BEGIN
  head := NIL;
  VpBuildList(head, 5);
  Test.AssertInt(15, VpSumList(head), "sumList 1..5");
  last := 0;
  WHILE head # NIL DO
    last := head^.val;
    head := head^.next
  END;
  Test.AssertInt(5, last, "last node val")
END VpTList;

PROCEDURE VpTGlobalList*;
BEGIN
  VpBuildList(VpgList, 3);
  Test.AssertInt(6, VpSumList(VpgList), "sum VpgList 1..3");
  VpgList := NIL
END VpTGlobalList;

PROCEDURE DyListPush(head: DyNode; v: INTEGER): DyNode;
VAR n: DyNode;
BEGIN NEW(n); n^.val := v; n^.next := head; RETURN n END DyListPush;

PROCEDURE DyListLen(head: DyNode): INTEGER;
VAR cnt: INTEGER;
BEGIN
  cnt := 0;
  WHILE head # NIL DO INC(cnt); head := head^.next END;
  RETURN cnt
END DyListLen;

PROCEDURE DyListSum(head: DyNode): INTEGER;
VAR s: INTEGER;
BEGIN
  s := 0;
  WHILE head # NIL DO s := s + head^.val; head := head^.next END;
  RETURN s
END DyListSum;

PROCEDURE DyListFind(head: DyNode; v: INTEGER): BOOLEAN;
VAR found: BOOLEAN;
BEGIN
  found := FALSE;
  WHILE (head # NIL) & ~found DO
    IF head^.val = v THEN found := TRUE END;
    head := head^.next
  END;
  RETURN found
END DyListFind;

PROCEDURE DyListRemove(head: DyNode; v: INTEGER): DyNode;
VAR prev, cur: DyNode;
BEGIN
  IF head = NIL THEN RETURN NIL END;
  IF head^.val = v THEN
    cur := head^.next;
    DISPOSE(head);
    RETURN cur
  END;
  prev := head; cur := head^.next;
  WHILE cur # NIL DO
    IF cur^.val = v THEN
      prev^.next := cur^.next;
      DISPOSE(cur);
      RETURN head
    END;
    prev := cur; cur := cur^.next
  END;
  RETURN head
END DyListRemove;

PROCEDURE DyListFree(head: DyNode);
VAR nxt: DyNode;
BEGIN
  WHILE head # NIL DO nxt := head^.next; DISPOSE(head); head := nxt END
END DyListFree;

PROCEDURE DyListReverse(head: DyNode): DyNode;
VAR prev, cur, nxt: DyNode;
BEGIN
  prev := NIL; cur := head;
  WHILE cur # NIL DO
    nxt := cur^.next; cur^.next := prev;
    prev := cur; cur := nxt
  END;
  RETURN prev
END DyListReverse;

PROCEDURE DyListNth(head: DyNode; n: INTEGER): INTEGER;
VAR i: INTEGER;
BEGIN
  IF n < 0 THEN RETURN -1 END;
  i := 0;
  WHILE (head # NIL) & (i < n) DO head := head^.next; INC(i) END;
  IF head = NIL THEN RETURN -1 END;
  RETURN head^.val
END DyListNth;

PROCEDURE DyTListBuildAndTraverse*;
VAR head: DyNode; i: INTEGER;
BEGIN
  head := NIL;
  FOR i := 1 TO 5 DO head := DyListPush(head, i) END;
  Test.AssertInt(5,  DyListLen(head), "len 5");
  Test.AssertInt(15, DyListSum(head), "sum 15");
  DyListFree(head)
END DyTListBuildAndTraverse;

PROCEDURE DyTListFind*;
VAR head: DyNode; i: INTEGER;
BEGIN
  head := NIL;
  FOR i := 1 TO 5 DO head := DyListPush(head, i * 10) END;
  Test.AssertTrue (DyListFind(head, 10), "find 10");
  Test.AssertTrue (DyListFind(head, 50), "find 50");
  Test.AssertFalse(DyListFind(head,  0), "absent 0");
  Test.AssertFalse(DyListFind(head, 60), "absent 60");
  DyListFree(head)
END DyTListFind;

PROCEDURE DyTListRemove*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 3);
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  head := DyListRemove(head, 2);
  Test.AssertInt(2, DyListLen(head), "len after rm 2");
  Test.AssertTrue (DyListFind(head, 1), "find 1");
  Test.AssertFalse(DyListFind(head, 2), "absent 2");
  Test.AssertTrue (DyListFind(head, 3), "find 3");
  head := DyListRemove(head, 1);
  Test.AssertInt(1, DyListLen(head), "len after rm 1");
  Test.AssertFalse(DyListFind(head, 1), "absent 1");
  head := DyListRemove(head, 3);
  Test.AssertNil(head, "head NIL")
END DyTListRemove;

PROCEDURE DyTListReverse*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 3);
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  head := DyListReverse(head);
  Test.AssertInt(3, DyListNth(head, 0), "rev[0]");
  Test.AssertInt(2, DyListNth(head, 1), "rev[1]");
  Test.AssertInt(1, DyListNth(head, 2), "rev[2]");
  Test.AssertInt(3, DyListLen(head),    "rev len");
  DyListFree(head)
END DyTListReverse;

PROCEDURE DyTListEmpty*;
VAR head: DyNode;
BEGIN
  head := NIL;
  Test.AssertInt(0,  DyListLen(head),   "empty len");
  Test.AssertInt(0,  DyListSum(head),   "empty sum");
  Test.AssertFalse(DyListFind(head, 1), "empty find");
  head := DyListRemove(head, 1);
  Test.AssertNil(head, "rm empty");
  head := DyListReverse(head);
  Test.AssertNil(head, "rev empty");
  Test.AssertInt(-1, DyListNth(head, 0), "Nth empty")
END DyTListEmpty;

PROCEDURE DyTListNthEdge*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 3);
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  Test.AssertInt( 1, DyListNth(head,  0), "Nth 0");
  Test.AssertInt( 3, DyListNth(head,  2), "Nth 2");
  Test.AssertInt(-1, DyListNth(head,  3), "Nth 3 (beyond)");
  Test.AssertInt(-1, DyListNth(head, -1), "Nth neg");
  DyListFree(head)
END DyTListNthEdge;

PROCEDURE DyTListRemoveNonExistent*;
VAR head, newHead: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  newHead := DyListRemove(head, 99);
  Test.AssertTrue(newHead = head, "rm absent ret same");
  Test.AssertInt(2, DyListLen(head), "len unchanged");
  Test.AssertTrue(DyListFind(head, 1), "still has 1");
  Test.AssertTrue(DyListFind(head, 2), "still has 2");
  DyListFree(head)
END DyTListRemoveNonExistent;

PROCEDURE DyTListRemoveTail*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 3);
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  head := DyListRemove(head, 3);
  Test.AssertInt(2, DyListLen(head), "len 2");
  Test.AssertInt(1, DyListNth(head, 0), "head 1");
  Test.AssertInt(2, DyListNth(head, 1), "second 2");
  Test.AssertFalse(DyListFind(head, 3), "absent 3");
  DyListFree(head)
END DyTListRemoveTail;

PROCEDURE DyTListRemoveDuplicateFirst*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  head := DyListPush(head, 2);
  head := DyListPush(head, 1);
  head := DyListRemove(head, 1);
  Test.AssertInt(3, DyListLen(head),  "len 3");
  Test.AssertInt(2, DyListNth(head, 0), "[0]=2");
  Test.AssertInt(1, DyListNth(head, 1), "[1]=1");
  Test.AssertInt(2, DyListNth(head, 2), "[2]=2");
  DyListFree(head)
END DyTListRemoveDuplicateFirst;

PROCEDURE DyTListReverseSingle*;
VAR head, rev: DyNode;
BEGIN
  head := DyListPush(NIL, 42);
  rev := DyListReverse(head);
  Test.AssertInt(42, DyListNth(rev, 0), "rev single 42");
  Test.AssertNil(rev^.next, "rev^.next NIL");
  DyListFree(rev)
END DyTListReverseSingle;

PROCEDURE DyTListReverseTwo*;
VAR head, rev: DyNode;
BEGIN
  head := DyListPush(NIL, 2);
  head := DyListPush(head, 1);
  rev := DyListReverse(head);
  Test.AssertInt(2, DyListLen(rev),    "rev2 len");
  Test.AssertInt(2, DyListNth(rev, 0), "rev2[0]");
  Test.AssertInt(1, DyListNth(rev, 1), "rev2[1]");
  DyListFree(rev)
END DyTListReverseTwo;

PROCEDURE DyTListSumOverflow*;
VAR head: DyNode;
BEGIN
  head := NIL;
  head := DyListPush(head, 20000);
  head := DyListPush(head, 20000);
  Test.AssertInt(-25536, DyListSum(head), "16-bit wrap");
  DyListFree(head)
END DyTListSumOverflow;

PROCEDURE DyTreeInsert(root: DyTreeNode; k: INTEGER): DyTreeNode;
VAR n: DyTreeNode;
BEGIN
  IF root = NIL THEN
    NEW(n); n^.key := k; n^.left := NIL; n^.right := NIL;
    RETURN n
  ELSIF k < root^.key THEN root^.left  := DyTreeInsert(root^.left,  k)
  ELSIF k > root^.key THEN root^.right := DyTreeInsert(root^.right, k)
  END;
  RETURN root
END DyTreeInsert;

PROCEDURE DyTreeFind(root: DyTreeNode; k: INTEGER): BOOLEAN;
BEGIN
  IF root = NIL THEN RETURN FALSE
  ELSIF k < root^.key THEN RETURN DyTreeFind(root^.left,  k)
  ELSIF k > root^.key THEN RETURN DyTreeFind(root^.right, k)
  ELSE RETURN TRUE END
END DyTreeFind;

PROCEDURE DyTreeSize(root: DyTreeNode): INTEGER;
BEGIN
  IF root = NIL THEN RETURN 0 END;
  RETURN 1 + DyTreeSize(root^.left) + DyTreeSize(root^.right)
END DyTreeSize;

PROCEDURE DyTreeHeight(root: DyTreeNode): INTEGER;
VAR lh, rh: INTEGER;
BEGIN
  IF root = NIL THEN RETURN 0 END;
  lh := DyTreeHeight(root^.left);
  rh := DyTreeHeight(root^.right);
  IF lh > rh THEN RETURN lh + 1 ELSE RETURN rh + 1 END
END DyTreeHeight;

PROCEDURE DyTreeInorderSum(root: DyTreeNode): INTEGER;
BEGIN
  IF root = NIL THEN RETURN 0 END;
  RETURN DyTreeInorderSum(root^.left) + root^.key + DyTreeInorderSum(root^.right)
END DyTreeInorderSum;

PROCEDURE DyTreeMin(root: DyTreeNode): INTEGER;
BEGIN
  IF root = NIL THEN RETURN -1 END;
  IF root^.left = NIL THEN RETURN root^.key END;
  RETURN DyTreeMin(root^.left)
END DyTreeMin;

PROCEDURE DyTreeMax(root: DyTreeNode): INTEGER;
BEGIN
  IF root = NIL THEN RETURN -1 END;
  IF root^.right = NIL THEN RETURN root^.key END;
  RETURN DyTreeMax(root^.right)
END DyTreeMax;

PROCEDURE DyTreeFree(root: DyTreeNode);
BEGIN
  IF root = NIL THEN RETURN END;
  DyTreeFree(root^.left); DyTreeFree(root^.right); DISPOSE(root)
END DyTreeFree;

PROCEDURE DyTTreeInsertFind*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root, 5); root := DyTreeInsert(root, 3);
  root := DyTreeInsert(root, 7); root := DyTreeInsert(root, 1);
  root := DyTreeInsert(root, 4); root := DyTreeInsert(root, 6);
  root := DyTreeInsert(root, 9);
  Test.AssertInt(7, DyTreeSize(root), "size 7");
  Test.AssertTrue (DyTreeFind(root, 5), "find 5");
  Test.AssertTrue (DyTreeFind(root, 1), "find 1");
  Test.AssertTrue (DyTreeFind(root, 9), "find 9");
  Test.AssertFalse(DyTreeFind(root, 0), "absent 0");
  Test.AssertFalse(DyTreeFind(root, 8), "absent 8");
  DyTreeFree(root)
END DyTTreeInsertFind;

PROCEDURE DyTTreeMinMax*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root, 5); root := DyTreeInsert(root, 3);
  root := DyTreeInsert(root, 7); root := DyTreeInsert(root, 1);
  root := DyTreeInsert(root, 9);
  Test.AssertInt(1, DyTreeMin(root), "min");
  Test.AssertInt(9, DyTreeMax(root), "max");
  DyTreeFree(root)
END DyTTreeMinMax;

PROCEDURE DyTTreeHeight*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  Test.AssertInt(0, DyTreeHeight(root), "h empty");
  root := DyTreeInsert(root, 5);
  Test.AssertInt(1, DyTreeHeight(root), "h 1");
  root := DyTreeInsert(root, 3); root := DyTreeInsert(root, 7);
  Test.AssertInt(2, DyTreeHeight(root), "h 2");
  root := DyTreeInsert(root, 1);
  Test.AssertInt(3, DyTreeHeight(root), "h 3");
  DyTreeFree(root)
END DyTTreeHeight;

PROCEDURE DyTTreeInorderSum*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root,  5); root := DyTreeInsert(root,  3);
  root := DyTreeInsert(root,  8); root := DyTreeInsert(root,  1);
  root := DyTreeInsert(root,  4); root := DyTreeInsert(root,  7);
  root := DyTreeInsert(root, 10); root := DyTreeInsert(root,  2);
  root := DyTreeInsert(root,  6); root := DyTreeInsert(root,  9);
  Test.AssertInt(10, DyTreeSize(root), "size 10");
  Test.AssertInt(55, DyTreeInorderSum(root), "sum 1..10");
  DyTreeFree(root)
END DyTTreeInorderSum;

PROCEDURE DyTTreeDuplicate*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root, 5);
  root := DyTreeInsert(root, 5);
  root := DyTreeInsert(root, 5);
  Test.AssertInt(1, DyTreeSize(root), "dup ignored");
  DyTreeFree(root)
END DyTTreeDuplicate;

PROCEDURE DyTTreeEmpty*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  Test.AssertInt(0,  DyTreeSize(root),        "size 0");
  Test.AssertInt(0,  DyTreeHeight(root),      "h 0");
  Test.AssertInt(0,  DyTreeInorderSum(root),  "sum 0");
  Test.AssertInt(-1, DyTreeMin(root),         "min -1");
  Test.AssertInt(-1, DyTreeMax(root),         "max -1");
  Test.AssertFalse(DyTreeFind(root, 0),       "find 0 false")
END DyTTreeEmpty;

PROCEDURE DyTTreeNegativeKeys*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root, -5);  root := DyTreeInsert(root, -10);
  root := DyTreeInsert(root, -3);  root := DyTreeInsert(root, -7);
  Test.AssertInt(4,   DyTreeSize(root), "size 4");
  Test.AssertInt(-10, DyTreeMin(root),  "min -10");
  Test.AssertInt(-3,  DyTreeMax(root),  "max -3");
  Test.AssertTrue (DyTreeFind(root, -5),  "find -5");
  Test.AssertTrue (DyTreeFind(root, -10), "find -10");
  Test.AssertTrue (DyTreeFind(root, -3),  "find -3");
  Test.AssertFalse(DyTreeFind(root, 0),   "absent 0");
  DyTreeFree(root)
END DyTTreeNegativeKeys;

PROCEDURE DyTTreeDegenerateHeight*;
VAR root: DyTreeNode; i: INTEGER;
BEGIN
  root := NIL;
  FOR i := 1 TO 10 DO root := DyTreeInsert(root, i) END;
  Test.AssertInt(10, DyTreeHeight(root), "h 10");
  Test.AssertInt(10, DyTreeSize(root),   "size 10");
  DyTreeFree(root)
END DyTTreeDegenerateHeight;

PROCEDURE DyTTreeInorderSumNegative*;
VAR root: DyTreeNode;
BEGIN
  root := NIL;
  root := DyTreeInsert(root, -5);  root := DyTreeInsert(root, -10);
  root := DyTreeInsert(root,  3);  root := DyTreeInsert(root,  7);
  Test.AssertInt(-5, DyTreeInorderSum(root), "sum negative");
  DyTreeFree(root)
END DyTTreeInorderSumNegative;

PROCEDURE DyTOfsOnPtrDeref*;
VAR p: DyNode; o1, o2: INTEGER;
BEGIN
  NEW(p);
  o1 := SYSTEM.OFS(p^);
  o2 := SYSTEM.OFS(p^);
  Test.AssertInt(o1, o2, "OFS stable");
  DISPOSE(p)
END DyTOfsOnPtrDeref;

PROCEDURE DyTSegOnPtrDeref*;
VAR p: DyNode; s1, s2: INTEGER;
BEGIN
  NEW(p);
  s1 := SYSTEM.SEG(p^);
  s2 := SYSTEM.SEG(p^);
  Test.AssertInt(s1, s2, "SEG stable");
  Test.AssertTrue(s1 # 0, "SEG # 0");
  DISPOSE(p)
END DyTSegOnPtrDeref;

PROCEDURE DyTAdrOnPtrDeref*;
VAR p, q: DyNode; adr: SYSTEM.ADDRESS;
BEGIN
  NEW(p);
  p^.val := 42;
  adr := SYSTEM.ADR(p^);
  q := adr;
  Test.AssertTrue(q = p, "ADR round-trip");
  Test.AssertInt(42, q^.val, "q^.val=42");
  DISPOSE(p)
END DyTAdrOnPtrDeref;

PROCEDURE DyTSegOfsOnPtrDeref*;
VAR p: DyNode;
BEGIN
  p := SYSTEM.PTR(123H, 456H);
  Test.AssertInt(123H, SYSTEM.SEG(p^), "SEG = 123H");
  Test.AssertInt(456H, SYSTEM.OFS(p^), "OFS = 456H")
END DyTSegOfsOnPtrDeref;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(PnTNilCheck, "Pn/nilCheck");
  Test.AddTest(PnTPtrRecord, "Pn/record");
  Test.AddTest(PnTPtrArray, "Pn/array");
  Test.AddTest(PnTPtrCharArray, "Pn/charArray");
  Test.AddTest(PnTPtrEquality, "Pn/equality");
  Test.AddTest(PnTMultiAlloc, "Pn/multiAlloc");
  Test.AddTest(PnTGlobalPointer, "Pn/global");
  Test.AddTest(PnTPtrValueParam, "Pn/valueParam");
  Test.AddTest(PnTPtrVarParam, "Pn/varParam");
  Test.AddTest(PnTPtrChain, "Pn/chain");
  Test.AddTest(PnTNilField, "Pn/nilField");
  Test.AddTest(PnTPtrReuse, "Pn/reuse");
  Test.AddTest(PnTSelfRef, "Pn/selfRef");
  Test.AddTest(PnTLargeArrayPtr, "Pn/largeArray");
  Test.AddTest(PnTGlobalList, "Pn/globalList");
  Test.AddTest(VpTLocal, "Vp/local");
  Test.AddTest(VpTGlobal, "Vp/global");
  Test.AddTest(VpTList, "Vp/list");
  Test.AddTest(VpTGlobalList, "Vp/globalList");
  Test.AddTest(DyTListBuildAndTraverse, "Dy/listBuild");
  Test.AddTest(DyTListFind, "Dy/listFind");
  Test.AddTest(DyTListRemove, "Dy/listRemove");
  Test.AddTest(DyTListReverse, "Dy/listReverse");
  Test.AddTest(DyTListEmpty, "Dy/listEmpty");
  Test.AddTest(DyTListNthEdge, "Dy/listNth");
  Test.AddTest(DyTListRemoveNonExistent, "Dy/listRmAbsent");
  Test.AddTest(DyTListRemoveTail, "Dy/listRmTail");
  Test.AddTest(DyTListRemoveDuplicateFirst, "Dy/listRmDupFirst");
  Test.AddTest(DyTListReverseSingle, "Dy/listRevSingle");
  Test.AddTest(DyTListReverseTwo, "Dy/listRevTwo");
  Test.AddTest(DyTListSumOverflow, "Dy/listOverflow");
  Test.AddTest(DyTTreeInsertFind, "Dy/treeInsFind");
  Test.AddTest(DyTTreeMinMax, "Dy/treeMinMax");
  Test.AddTest(DyTTreeHeight, "Dy/treeHeight");
  Test.AddTest(DyTTreeInorderSum, "Dy/treeInorder");
  Test.AddTest(DyTTreeDuplicate, "Dy/treeDup");
  Test.AddTest(DyTTreeEmpty, "Dy/treeEmpty");
  Test.AddTest(DyTTreeNegativeKeys, "Dy/treeNeg");
  Test.AddTest(DyTTreeDegenerateHeight, "Dy/treeDegHeight");
  Test.AddTest(DyTTreeInorderSumNegative, "Dy/treeNegSum");
  Test.AddTest(DyTOfsOnPtrDeref, "Dy/ofs");
  Test.AddTest(DyTSegOnPtrDeref, "Dy/seg");
  Test.AddTest(DyTAdrOnPtrDeref, "Dy/adr");
  Test.AddTest(DyTSegOfsOnPtrDeref, "Dy/segOfs");
  Test.RunTests
END RunAllTests;

END PTR.
