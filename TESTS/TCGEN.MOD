MODULE TCGEN;
(* Unit tests for Cgen.
   Each test resets the code generator, emits a sequence, and asserts the
   exact byte pattern via Rdoff.PeekCodeByte. *)

IMPORT Test, Syms, Rdoff, Cgen;

(* ---- helpers ---- *)

PROCEDURE reset;
BEGIN
  Syms.SymInit();
  Cgen.CgFree();
  Cgen.CgInit()
END reset;

PROCEDURE peekB(at: LONGINT): INTEGER;
BEGIN
  RETURN INTEGER(Rdoff.PeekCodeByte(Cgen.CgObj, at))
END peekB;

PROCEDURE eqByte(at: LONGINT; expected: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  Test.AssertInt(expected, peekB(at), msg)
END eqByte;

PROCEDURE eq2(at: LONGINT; b0, b1: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg)
END eq2;

PROCEDURE eq3(at: LONGINT; b0, b1, b2: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg)
END eq3;

PROCEDURE eq4(at: LONGINT; b0, b1, b2, b3: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg);
  eqByte(at + 3, b3, msg)
END eq4;

PROCEDURE eq5(at: LONGINT; b0, b1, b2, b3, b4: INTEGER; msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg);
  eqByte(at + 3, b3, msg);
  eqByte(at + 4, b4, msg)
END eq5;

PROCEDURE eq6(at: LONGINT; b0, b1, b2, b3, b4, b5: INTEGER;
              msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg);
  eqByte(at + 3, b3, msg);
  eqByte(at + 4, b4, msg);
  eqByte(at + 5, b5, msg)
END eq6;

PROCEDURE eq7(at: LONGINT; b0, b1, b2, b3, b4, b5, b6: INTEGER;
              msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg);
  eqByte(at + 3, b3, msg);
  eqByte(at + 4, b4, msg);
  eqByte(at + 5, b5, msg);
  eqByte(at + 6, b6, msg)
END eq7;

PROCEDURE eq9(at: LONGINT; b0, b1, b2, b3, b4, b5, b6, b7, b8: INTEGER;
              msg: ARRAY OF CHAR);
BEGIN
  eqByte(at,     b0, msg);
  eqByte(at + 1, b1, msg);
  eqByte(at + 2, b2, msg);
  eqByte(at + 3, b3, msg);
  eqByte(at + 4, b4, msg);
  eqByte(at + 5, b5, msg);
  eqByte(at + 6, b6, msg);
  eqByte(at + 7, b7, msg);
  eqByte(at + 8, b8, msg)
END eq9;

PROCEDURE nthReloc(n: INTEGER): Rdoff.RelocNode;
  VAR r: Rdoff.RelocNode;
BEGIN
  r := Cgen.CgObj^.relocHead;
  WHILE (r # NIL) & (n > 0) DO r := r^.next; DEC(n) END;
  RETURN r
END nthReloc;

(* ---- prologue / epilogue ---- *)

PROCEDURE TPrologueEpilogue*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgPrologue(0);
  eq7(at, 055H, 08BH, 0ECH, 081H, 0ECH, 0, 0, "prologue/0 bytes");
  Test.AssertLong(7, Cgen.CgPc() - at, "prologue/0 len");

  reset; at := Cgen.CgPc(); Cgen.CgPrologue(4);
  eq7(at, 055H, 08BH, 0ECH, 081H, 0ECH, 4, 0, "prologue/4 bytes");

  reset; at := Cgen.CgPc(); Cgen.CgEpilogue(0);
  eq4(at, 08BH, 0E5H, 05DH, 0C3H, "epilogue/near 0");

  reset; at := Cgen.CgPc(); Cgen.CgEpilogue(4);
  eq6(at, 08BH, 0E5H, 05DH, 0C2H, 4, 0, "epilogue/near 4");

  reset; at := Cgen.CgPc(); Cgen.CgEpilogueFar(0);
  eq4(at, 08BH, 0E5H, 05DH, 0CBH, "epilogue/far 0");

  reset; at := Cgen.CgPc(); Cgen.CgEpilogueFar(4);
  eq6(at, 08BH, 0E5H, 05DH, 0CAH, 4, 0, "epilogue/far 4")
END TPrologueEpilogue;

(* ---- load immediate ---- *)

PROCEDURE TLoadImm*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgLoadImm(0);
  eq2(at, 033H, 0C0H, "load-imm/0 XOR AX,AX");

  reset; at := Cgen.CgPc(); Cgen.CgLoadImm(1);
  eq3(at, 0B8H, 1, 0, "load-imm/1");

  reset; at := Cgen.CgPc(); Cgen.CgLoadImm(-1);
  eq3(at, 0B8H, 0FFH, 0FFH, "load-imm/-1");

  reset; at := Cgen.CgPc(); Cgen.CgLoadImm(1234H);
  eq3(at, 0B8H, 034H, 012H, "load-imm/1234H")
END TLoadImm;

(* ---- load / store via BP ---- *)

PROCEDURE TBp*;
  VAR at: LONGINT;
BEGIN
  (* disp8 path *)
  reset; at := Cgen.CgPc(); Cgen.CgLoadBp(-2);
  eq3(at, 08BH, 046H, 0FEH, "bp/load disp8");

  reset; at := Cgen.CgPc(); Cgen.CgStoreBp(-2);
  eq3(at, 089H, 046H, 0FEH, "bp/store disp8");

  (* disp16 path *)
  reset; at := Cgen.CgPc(); Cgen.CgLoadBp(-130);
  eq4(at, 08BH, 086H, 07EH, 0FFH, "bp/load disp16");

  reset; at := Cgen.CgPc(); Cgen.CgStoreBp(-130);
  eq4(at, 089H, 086H, 07EH, 0FFH, "bp/store disp16");

  (* byte load/store *)
  reset; at := Cgen.CgPc(); Cgen.CgLoadByteBp(-2);
  eq3(at, 08AH, 046H, 0FEH, "bp/load byte disp8");
  eq2(at + 3, 030H, 0E4H, "bp/load byte XOR AH,AH");

  reset; at := Cgen.CgPc(); Cgen.CgStoreByteBp(-2);
  eq3(at, 088H, 046H, 0FEH, "bp/store byte disp8");

  reset; at := Cgen.CgPc(); Cgen.CgLoadByteBp(-130);
  eq4(at, 08AH, 086H, 07EH, 0FFH, "bp/load byte disp16");
  eq2(at + 4, 030H, 0E4H, "bp/load byte disp16 XOR AH,AH");

  reset; at := Cgen.CgPc(); Cgen.CgStoreByteBp(-130);
  eq4(at, 088H, 086H, 07EH, 0FFH, "bp/store byte disp16")
END TBp;

(* ---- load / store via data segment ---- *)

PROCEDURE TMem*;
  VAR at: LONGINT; r: Rdoff.RelocNode;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgLoadMem(0);
  eq3(at, 0A1H, 0, 0, "mem/load");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "mem/load reloc count");
  r := nthReloc(0);
  Test.AssertNotNil(r, "mem/load reloc node");
  IF r # NIL THEN
    Test.AssertLong(at + 1, r^.offset, "mem/load reloc offset");
    Test.AssertInt(Rdoff.SegData, r^.rseg, "mem/load reloc rseg")
  END;

  reset; at := Cgen.CgPc(); Cgen.CgStoreMem(0);
  eq3(at, 0A3H, 0, 0, "mem/store");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "mem/store reloc count");

  reset; at := Cgen.CgPc(); Cgen.CgLoadByteMem(0);
  eq3(at, 0A0H, 0, 0, "mem/load byte");
  eq2(at + 3, 030H, 0E4H, "mem/load byte XOR AH,AH");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "mem/load byte reloc count");

  reset; at := Cgen.CgPc(); Cgen.CgStoreByteMem(0);
  eq3(at, 0A2H, 0, 0, "mem/store byte");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "mem/store byte reloc count");

  reset; at := Cgen.CgPc(); Cgen.CgLoadAddrMem(0);
  eq4(at, 08DH, 006H, 0, 0, "mem/load addr");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "mem/load addr reloc count")
END TMem;

(* ---- far pointer helpers ---- *)

PROCEDURE TFarPtr*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgDerefFar();
  eq3(at, 026H, 08BH, 007H, "far/deref");

  reset; at := Cgen.CgPc(); Cgen.CgStoreDerefFar();
  eq3(at, 026H, 089H, 007H, "far/store deref");

  reset; at := Cgen.CgPc(); Cgen.CgDxaxToEsbx();
  eq4(at, 08BH, 0D8H, 08EH, 0C2H, "far/dxax->esbx");

  reset; at := Cgen.CgPc(); Cgen.CgLesBxBp(-2);
  eq3(at, 0C4H, 05EH, 0FEH, "far/les bp disp8");

  reset; at := Cgen.CgPc(); Cgen.CgLesBxBp(-130);
  eq4(at, 0C4H, 09EH, 07EH, 0FFH, "far/les bp disp16")
END TFarPtr;

(* ---- arithmetic ---- *)

PROCEDURE TArith*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgAdd();
  eq2(at, 003H, 0C1H, "arith/add");

  reset; at := Cgen.CgPc(); Cgen.CgSub();
  eq4(at, 087H, 0C1H, 02BH, 0C1H, "arith/sub");

  reset; at := Cgen.CgPc(); Cgen.CgMul();
  eq2(at, 0F7H, 0E9H, "arith/mul");

  reset; at := Cgen.CgPc(); Cgen.CgDiv();
  eq5(at, 087H, 0C1H, 099H, 0F7H, 0F9H, "arith/div");

  reset; at := Cgen.CgPc(); Cgen.CgMod();
  eq5(at,     087H, 0C1H, 099H, 0F7H, 0F9H, "arith/mod head");
  eq2(at + 5, 08BH, 0C2H, "arith/mod MOV AX,DX");

  reset; at := Cgen.CgPc(); Cgen.CgNeg();
  eq2(at, 0F7H, 0D8H, "arith/neg");

  reset; at := Cgen.CgPc(); Cgen.CgAnd();
  eq2(at, 023H, 0C1H, "arith/and");

  reset; at := Cgen.CgPc(); Cgen.CgOr();
  eq2(at, 00BH, 0C1H, "arith/or");

  reset; at := Cgen.CgPc(); Cgen.CgXor();
  eq2(at, 033H, 0C1H, "arith/xor")
END TArith;

(* ---- inc / dec / cmp ---- *)

PROCEDURE TIncDecCmp*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgIncAx();
  eqByte(at, 040H, "inc-ax");
  Test.AssertLong(1, Cgen.CgPc() - at, "inc-ax len");

  reset; at := Cgen.CgPc(); Cgen.CgDecAx();
  eqByte(at, 048H, "dec-ax");
  Test.AssertLong(1, Cgen.CgPc() - at, "dec-ax len");

  reset; at := Cgen.CgPc(); Cgen.CgCmp();
  eq2(at, 03BH, 0C8H, "cmp/CMP CX,AX")
END TIncDecCmp;

(* ---- setcc ---- *)

PROCEDURE TSetcc*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgSetcc(074H);
  eq9(at, 074H, 4, 033H, 0C0H, 0EBH, 3, 0B8H, 1, 0, "setcc/bytes");
  Test.AssertLong(9, Cgen.CgPc() - at, "setcc/len 9")
END TSetcc;

(* ---- FAR call ---- *)

PROCEDURE TFarCall*;
  VAR at: LONGINT; id: INTEGER; r: Rdoff.RelocNode;
BEGIN
  reset;
  id := Rdoff.RdfAddImport(Cgen.CgObj, "FOO");
  at := Cgen.CgPc();
  Cgen.CgCallFar(id);
  eqByte(at, 09AH, "far-call opcode");
  Test.AssertLong(5, Cgen.CgPc() - at, "far-call len 5");
  Test.AssertInt(2, Cgen.CgObj^.nRelocs, "far-call two relocs");
  r := nthReloc(0);
  IF r # NIL THEN Test.AssertInt(id, r^.rseg, "far-call reloc rseg") END;
  r := nthReloc(1);
  IF r # NIL THEN
    Test.AssertTrue(SYSTEM.AND(INTEGER(r^.physSeg), 080H) # 0,
                    "far-call segreloc sentinel")
  END
END TFarCall;

(* ---- forward conditional jump ---- *)

PROCEDURE TCondNear*;
  VAR at: LONGINT; bp: Cgen.Backpatch;
BEGIN
  reset; at := Cgen.CgPc();
  Cgen.CgCondNear(074H, bp);  (* JZ ⇒ JNZ +3 / JMP near *)
  eqByte(at,     075H, "cond-near inv opcode");
  eqByte(at + 1, 003H, "cond-near skip 3");
  eqByte(at + 2, 0E9H, "cond-near JMP");
  Test.AssertLong(5, Cgen.CgPc() - at, "cond-near len 5");

  Cgen.CgPatchNear(bp);
  eqByte(at + 3, 0, "cond-near patch lo");
  eqByte(at + 4, 0, "cond-near patch hi")
END TCondNear;

(* ---- forward jmp_near / backward jmp_back ---- *)

PROCEDURE TJumps*;
  VAR at: LONGINT; bp: Cgen.Backpatch; i: INTEGER;
BEGIN
  reset; at := Cgen.CgPc();
  Cgen.CgJmpNear(bp);
  Cgen.Emit2(090H, 090H);
  Cgen.CgPatchNear(bp);
  eqByte(at,     0E9H, "jmp-near opcode");
  eqByte(at + 1, 2,    "jmp-near rel lo");
  eqByte(at + 2, 0,    "jmp-near rel hi");
  Test.AssertLong(5, Cgen.CgPc() - at, "jmp-near total 5");

  reset;
  FOR i := 0 TO 9 DO Cgen.Emit1(090H) END;
  Cgen.CgJmpBack(0);
  eqByte(10, 0EBH, "jmp-back opcode");
  eqByte(11, 0F4H, "jmp-back rel -12")
END TJumps;

(* ---- cond_back ---- *)

PROCEDURE TCondBack*;
  VAR i: INTEGER; rel16: INTEGER;
BEGIN
  reset;
  FOR i := 0 TO 9 DO Cgen.Emit1(090H) END;
  Cgen.CgCondBack(074H, 0);
  eqByte(10, 074H, "cond-back short opcode");
  eqByte(11, 0F4H, "cond-back short rel -12");
  Test.AssertLong(12, Cgen.CgPc(), "cond-back short size 2");

  reset;
  FOR i := 0 TO 199 DO Cgen.Emit1(090H) END;
  Cgen.CgCondBack(074H, 0);
  eqByte(200, 075H, "cond-back near inv opcode");
  eqByte(201, 003H, "cond-back near skip 3");
  eqByte(202, 0E9H, "cond-back near JMP NEAR");
  rel16 := -205;
  eqByte(203, SYSTEM.AND(rel16, 0FFH),       "cond-back near rel16 lo");
  eqByte(204, SYSTEM.AND(SYSTEM.LSR(rel16, 8), 0FFH), "cond-back near rel16 hi");
  Test.AssertLong(205, Cgen.CgPc(), "cond-back near size 5")
END TCondBack;

(* ---- call_local / call_near ---- *)

PROCEDURE TCalls*;
  VAR at: LONGINT; id: INTEGER; r: Rdoff.RelocNode;
BEGIN
  reset; at := Cgen.CgPc();
  Cgen.CgCallLocal(10);
  eqByte(at,     0E8H, "call-local opcode");
  eqByte(at + 1, 7,    "call-local rel lo 7");
  eqByte(at + 2, 0,    "call-local rel hi");
  Test.AssertInt(0, Cgen.CgObj^.nRelocs, "call-local no reloc");

  reset;
  id := Rdoff.RdfAddImport(Cgen.CgObj, "TestSym");
  at := Cgen.CgPc();
  Cgen.CgCallNear(id);
  eqByte(at, 0E8H, "call-near opcode");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "call-near reloc added");
  r := nthReloc(0);
  IF r # NIL THEN
    Test.AssertInt(id, r^.rseg, "call-near reloc rseg");
    Test.AssertTrue(SYSTEM.AND(INTEGER(r^.physSeg), 040H) # 0,
                    "call-near reloc relative");
    Test.AssertInt(2, INTEGER(r^.width), "call-near reloc width 2");
    Test.AssertLong(at + 1, r^.offset, "call-near reloc at patch")
  END
END TCalls;

(* ---- call_local_far ---- *)

PROCEDURE TCallLocalFar*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc();
  Cgen.CgCallLocalFar(0);
  eqByte(at,     00EH, "call-local-far PUSH CS");
  eqByte(at + 1, 0E8H, "call-local-far CALL near opcode");
  Test.AssertLong(4, Cgen.CgPc() - at, "call-local-far len 4");
  Test.AssertInt(0, Cgen.CgObj^.nRelocs, "call-local-far no reloc")
END TCallLocalFar;

(* ---- invert_jcc ---- *)

PROCEDURE TInvertJcc*;
BEGIN
  Test.AssertInt(075H, Cgen.InvertJcc(074H), "inv/JZ->JNZ");
  Test.AssertInt(074H, Cgen.InvertJcc(075H), "inv/JNZ->JZ");
  Test.AssertInt(07DH, Cgen.InvertJcc(07CH), "inv/JL->JGE");
  Test.AssertInt(07CH, Cgen.InvertJcc(07DH), "inv/JGE->JL");
  Test.AssertInt(07FH, Cgen.InvertJcc(07EH), "inv/JLE->JG");
  Test.AssertInt(07EH, Cgen.InvertJcc(07FH), "inv/JG->JLE");
  Test.AssertInt(073H, Cgen.InvertJcc(072H), "inv/JB->JAE");
  Test.AssertInt(072H, Cgen.InvertJcc(073H), "inv/JAE->JB")
END TInvertJcc;

(* ---- shifts / rotates ---- *)

PROCEDURE TShifts*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgShlImm(1);
  eq2(at, 0D1H, 0E0H, "shl-imm 1 bytes");
  Test.AssertLong(2, Cgen.CgPc() - at, "shl-imm 1 len");

  reset; at := Cgen.CgPc(); Cgen.CgShlImm(3);
  eq4(at, 0B1H, 003H, 0D3H, 0E0H, "shl-imm 3 bytes");
  Test.AssertLong(4, Cgen.CgPc() - at, "shl-imm 3 len");

  reset; at := Cgen.CgPc(); Cgen.CgSarImm(1);
  eq2(at, 0D1H, 0F8H, "sar-imm 1 bytes");

  reset; at := Cgen.CgPc(); Cgen.CgSarImm(2);
  eq4(at, 0B1H, 002H, 0D3H, 0F8H, "sar-imm 2 bytes");

  reset; at := Cgen.CgPc(); Cgen.CgRorImm(1);
  eq2(at, 0D1H, 0C8H, "ror-imm 1 bytes");

  reset; at := Cgen.CgPc(); Cgen.CgRorImm(4);
  eq4(at, 0B1H, 004H, 0D3H, 0C8H, "ror-imm 4 bytes");

  reset; at := Cgen.CgPc(); Cgen.CgShlCl();
  eq2(at, 0D3H, 0E0H, "shl-cl bytes");

  reset; at := Cgen.CgPc(); Cgen.CgSarCl();
  eq2(at, 0D3H, 0F8H, "sar-cl bytes");

  reset; at := Cgen.CgPc(); Cgen.CgRorCl();
  eq2(at, 0D3H, 0C8H, "ror-cl bytes")
END TShifts;

(* ---- cg_load_import_addr ---- *)

PROCEDURE TLoadImportAddr*;
  VAR at: LONGINT; id: INTEGER; r: Rdoff.RelocNode;
BEGIN
  reset;
  id := Rdoff.RdfAddImport(Cgen.CgObj, "FOO");
  at := Cgen.CgPc();
  Cgen.CgLoadImportAddr(id);
  Test.AssertLong(6, Cgen.CgPc() - at, "load-import-addr len 6");
  eq3(at,     0B8H, 0, 0, "load-import-addr MOV AX,imm");
  eq3(at + 3, 0BAH, 0, 0, "load-import-addr MOV DX,imm");
  Test.AssertInt(2, Cgen.CgObj^.nRelocs, "load-import-addr 2 relocs");
  r := nthReloc(0);
  IF r # NIL THEN Test.AssertInt(id, r^.rseg, "load-import-addr reloc0 rseg") END;
  r := nthReloc(1);
  IF r # NIL THEN
    Test.AssertTrue(SYSTEM.AND(INTEGER(r^.physSeg), 080H) # 0,
                    "load-import-addr reloc1 segreloc sentinel")
  END
END TLoadImportAddr;

(* ---- cg_call_proc_var_* ---- *)

PROCEDURE TCallProcVar*;
  VAR at: LONGINT;
BEGIN
  (* FAR: FF 5E imm8 (disp8) *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarBp(4);
  eq3(at, 0FFH, 05EH, 4, "call-proc-var bp disp8");
  Test.AssertLong(3, Cgen.CgPc() - at, "call-proc-var bp disp8 len");

  (* FAR: FF 9E lo hi (disp16) *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarBp(1234H);
  eq4(at, 0FFH, 09EH, 34H, 12H, "call-proc-var bp disp16");
  Test.AssertLong(4, Cgen.CgPc() - at, "call-proc-var bp disp16 len");

  (* FAR: FF 1E lo hi *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarMem(03412H);
  eq4(at, 0FFH, 01EH, 012H, 034H, "call-proc-var mem");
  Test.AssertLong(4, Cgen.CgPc() - at, "call-proc-var mem len");

  (* FAR: 26 FF 1F *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarEsbx();
  eq3(at, 026H, 0FFH, 01FH, "call-proc-var esbx");
  Test.AssertLong(3, Cgen.CgPc() - at, "call-proc-var esbx len");

  (* NEAR: FF 56 FC (BP-4 disp8) *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarNearBp(-4);
  eq3(at, 0FFH, 056H, 0FCH, "call-proc-var near bp disp8");
  Test.AssertLong(3, Cgen.CgPc() - at, "call-proc-var near bp disp8 len");

  (* NEAR: FF 16 lo hi *)
  reset; at := Cgen.CgPc(); Cgen.CgCallProcVarNearMem(04243H);
  eq4(at, 0FFH, 016H, 043H, 042H, "call-proc-var near mem");
  Test.AssertLong(4, Cgen.CgPc() - at, "call-proc-var near mem len")
END TCallProcVar;

(* ---- cg_les_bx_* ---- *)

PROCEDURE TLesBx*;
  VAR at: LONGINT;
BEGIN
  (* C4 5E imm8 (BP disp8) *)
  reset; at := Cgen.CgPc(); Cgen.CgLesBxBp(4);
  eq3(at, 0C4H, 05EH, 4, "les-bx bp disp8");
  Test.AssertLong(3, Cgen.CgPc() - at, "les-bx bp disp8 len");

  (* C4 9E lo hi (BP disp16) *)
  reset; at := Cgen.CgPc(); Cgen.CgLesBxBp(1234H);
  eq4(at, 0C4H, 09EH, 34H, 12H, "les-bx bp disp16");

  (* C4 1E lo hi + DATA reloc *)
  reset; at := Cgen.CgPc(); Cgen.CgLesBxMem(010H);
  eq4(at, 0C4H, 01EH, 010H, 0, "les-bx mem");
  Test.AssertInt(1, Cgen.CgObj^.nRelocs, "les-bx mem one reloc");

  (* CgLesBxItem dispatch *)
  reset; at := Cgen.CgPc(); Cgen.CgLesBxItem(Cgen.MLocal, 4);
  eq3(at, 0C4H, 05EH, 4, "les-bx item local");

  reset; at := Cgen.CgPc(); Cgen.CgLesBxItem(Cgen.MGlobal, 010H);
  eq4(at, 0C4H, 01EH, 010H, 0, "les-bx item global")
END TLesBx;

(* ---- cg_es_from_mode ---- *)

PROCEDURE TEsFromMode*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgEsFromMode(Cgen.MLocal);
  eq4(at, 08CH, 0D2H, 08EH, 0C2H, "es-from-mode local");
  Test.AssertLong(4, Cgen.CgPc() - at, "es-from-mode local len");

  reset; at := Cgen.CgPc(); Cgen.CgEsFromMode(Cgen.MGlobal);
  eq4(at, 08CH, 0DAH, 08EH, 0C2H, "es-from-mode global")
END TEsFromMode;

(* ---- cg_rep_movsb ---- *)

PROCEDURE TRepMovsb*;
  VAR at: LONGINT;
BEGIN
  (* count=4 no-prefix: B8 04 00 / 8B C8 / FC / F3 A4 = 8 bytes *)
  reset; at := Cgen.CgPc(); Cgen.CgRepMovsb(4, FALSE);
  Test.AssertLong(8, Cgen.CgPc() - at, "rep-movsb nopref len 8");
  eq3(at,     0B8H, 4, 0,    "rep-movsb nopref load");
  eq2(at + 3, 08BH, 0C8H,    "rep-movsb nopref MOV CX,AX");
  eq3(at + 5, 0FCH, 0F3H, 0A4H, "rep-movsb nopref CLD REP");

  (* count=4 SS prefix: inserts 36 — 9 bytes total *)
  reset; at := Cgen.CgPc(); Cgen.CgRepMovsb(4, TRUE);
  Test.AssertLong(9, Cgen.CgPc() - at, "rep-movsb sspref len 9");
  eq4(at + 5, 0FCH, 036H, 0F3H, 0A4H, "rep-movsb sspref CLD SS REP");

  (* count=0 -> XOR AX,AX (2 bytes) + 5 = 7 *)
  reset; at := Cgen.CgPc(); Cgen.CgRepMovsb(0, FALSE);
  Test.AssertLong(7, Cgen.CgPc() - at, "rep-movsb zero len 7");
  eq2(at, 033H, 0C0H, "rep-movsb zero XOR AX,AX")
END TRepMovsb;

(* ---- cg_dxax_to_esbx ---- *)

PROCEDURE TDxaxToEsbx*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgDxaxToEsbx();
  eq4(at, 08BH, 0D8H, 08EH, 0C2H, "dxax-to-esbx bytes");
  Test.AssertLong(4, Cgen.CgPc() - at, "dxax-to-esbx len 4")
END TDxaxToEsbx;

(* ---- cg_store_word_esbx_imm ---- *)

PROCEDURE TStoreWordEsbxImm*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgStoreWordEsbxImm(01234H);
  eq5(at, 026H, 0C7H, 07H, 034H, 012H, "store-word-esbx imm bytes");
  Test.AssertLong(5, Cgen.CgPc() - at, "store-word-esbx imm len 5")
END TStoreWordEsbxImm;

(* ---- cg_add_bx_imm ---- *)

PROCEDURE TAddBxImm*;
  VAR at: LONGINT;
BEGIN
  (* imm=0 → no bytes *)
  reset; at := Cgen.CgPc(); Cgen.CgAddBxImm(0);
  Test.AssertLong(0, Cgen.CgPc() - at, "add-bx-imm zero no-emit");

  (* imm<=127 → 83 C3 imm8 *)
  reset; at := Cgen.CgPc(); Cgen.CgAddBxImm(8);
  eq3(at, 083H, 0C3H, 8, "add-bx-imm disp8");
  Test.AssertLong(3, Cgen.CgPc() - at, "add-bx-imm disp8 len");

  (* imm>127 → 81 C3 lo hi *)
  reset; at := Cgen.CgPc(); Cgen.CgAddBxImm(0100H);
  eq4(at, 081H, 0C3H, 0, 1, "add-bx-imm disp16");
  Test.AssertLong(4, Cgen.CgPc() - at, "add-bx-imm disp16 len")
END TAddBxImm;

(* ---- cg_push_dxax / cg_pop_cxbx ---- *)

PROCEDURE TPushPop*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgPushDxax();
  eq2(at, 052H, 050H, "push-dxax bytes");
  Test.AssertLong(2, Cgen.CgPc() - at, "push-dxax len 2");

  reset; at := Cgen.CgPc(); Cgen.CgPopCxbx();
  eq2(at, 05BH, 059H, "pop-cxbx bytes");
  Test.AssertLong(2, Cgen.CgPc() - at, "pop-cxbx len 2")
END TPushPop;

(* ---- cg_ptr_cmp_eq ---- *)

PROCEDURE TPtrCmpEq*;
  VAR at: LONGINT;
BEGIN
  reset; at := Cgen.CgPc(); Cgen.CgPtrCmpEq();
  Test.AssertLong(10, Cgen.CgPc() - at, "ptr-cmp-eq len 10");
  eq3(at,     059H, 033H, 0C1H, "ptr-cmp-eq POP CX XOR AX,CX");
  eq3(at + 3, 05BH, 033H, 0D3H, "ptr-cmp-eq POP BX XOR DX,BX");
  eq4(at + 6, 00BH, 0C2H, 085H, 0C0H, "ptr-cmp-eq OR AX,DX TEST AX,AX")
END TPtrCmpEq;

(* ---- emit_data_string ---- *)

PROCEDURE TEmitDataString*;
  VAR start: LONGINT;
BEGIN
  reset;
  start := LONGINT(Cgen.CgObj^.dataLen);
  Cgen.EmitDataString("Hi");
  Test.AssertLong(3, LONGINT(Cgen.CgObj^.dataLen) - start, "emit-data-string len 3");
  Test.AssertInt(ORD("H"), INTEGER(Rdoff.PeekDataByte(Cgen.CgObj, start)),
                 "emit-data-string H");
  Test.AssertInt(ORD("i"), INTEGER(Rdoff.PeekDataByte(Cgen.CgObj, start + 1)),
                 "emit-data-string i");
  Test.AssertInt(0, INTEGER(Rdoff.PeekDataByte(Cgen.CgObj, start + 2)),
                 "emit-data-string nul")
END TEmitDataString;

(* Regression: CgFree must release the ObjFile struct, not just its node lists.
   Pre-fix (2026-05-22) CgFree called RdfFree which DISPOSEd interior linked
   lists but left the ObjFile struct allocated by NEW(CgObj) leaked.  After
   the 27 reset cycles in the other TCGEN tests plus enough fresh leaks,
   the cumulative leak exhausts the 128 KiB heap (the $M default); subsequent
   NEW(CgObj) returns stale memory and PeekCodeByte reads unrelated bytes —
   typically 0x90 (NOP) left over from prior emits in TJumps/TCondBack.

   Performs 5 reset cycles after the 27 main tests have already taxed the
   heap, asserting after each that a freshly-emitted distinctive byte
   (0x55 = PUSH BP) is what we read back.  With the leak fixed, all cycles
   read 0x55.  With the leak, the failure shows up in the wider suite
   (TCallLocalFar onward fail with stale 0x90 NOP bytes) — this dedicated
   test sits at the end of RunAllTests to give a clean post-condition
   check: if the heap is still healthy after the suite, this passes; if
   the leak is still present, this fails too.  Iteration count is bounded
   to keep xt's --max=80000000 instruction budget in test_src.sh happy. *)
PROCEDURE TResetLeak*;
  VAR i: INTEGER; at: LONGINT;
BEGIN
  FOR i := 0 TO 4 DO
    reset;
    at := Cgen.CgPc();
    Cgen.Emit1(BYTE(055H));   (* PUSH BP — distinctive, not 0x90 NOP *)
    Test.AssertInt(055H, INTEGER(Rdoff.PeekCodeByte(Cgen.CgObj, at)),
                   "reset-leak/emit-after-many-cycles")
  END
END TResetLeak;

PROCEDURE RunAllTests*;
BEGIN
  Test.AddTest(TPrologueEpilogue, "Cgen/prologue-epilogue");
  Test.AddTest(TLoadImm,          "Cgen/load-imm");
  Test.AddTest(TBp,               "Cgen/bp");
  Test.AddTest(TMem,              "Cgen/mem");
  Test.AddTest(TFarPtr,           "Cgen/far-ptr");
  Test.AddTest(TArith,            "Cgen/arith");
  Test.AddTest(TIncDecCmp,        "Cgen/inc-dec-cmp");
  Test.AddTest(TSetcc,            "Cgen/setcc");
  Test.AddTest(TFarCall,          "Cgen/far-call");
  Test.AddTest(TCondNear,         "Cgen/cond-near");
  Test.AddTest(TJumps,            "Cgen/jumps");
  Test.AddTest(TCondBack,         "Cgen/cond-back");
  Test.AddTest(TCalls,            "Cgen/calls");
  Test.AddTest(TCallLocalFar,     "Cgen/call-local-far");
  Test.AddTest(TInvertJcc,        "Cgen/invert-jcc");
  Test.AddTest(TShifts,           "Cgen/shifts");
  Test.AddTest(TLoadImportAddr,   "Cgen/load-import-addr");
  Test.AddTest(TCallProcVar,      "Cgen/call-proc-var");
  Test.AddTest(TLesBx,            "Cgen/les-bx");
  Test.AddTest(TEsFromMode,       "Cgen/es-from-mode");
  Test.AddTest(TRepMovsb,         "Cgen/rep-movsb");
  Test.AddTest(TDxaxToEsbx,       "Cgen/dxax-to-esbx");
  Test.AddTest(TStoreWordEsbxImm, "Cgen/store-word-esbx-imm");
  Test.AddTest(TAddBxImm,         "Cgen/add-bx-imm");
  Test.AddTest(TPushPop,          "Cgen/push-pop");
  Test.AddTest(TPtrCmpEq,         "Cgen/ptr-cmp-eq");
  Test.AddTest(TEmitDataString,   "Cgen/emit-data-string");
  Test.AddTest(TResetLeak,        "Cgen/reset-leak");
  Test.RunTests
END RunAllTests;

END TCGEN.
