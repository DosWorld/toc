(*$R-*)(*$D-*)
MODULE SYSTEM;

CONST
FCarry*     = 1;
FParity*    = 4;
FAuxiliary* = 16;
FZero*      = 64;
FSign*      = 128;
FOverflow*  = 2048;

TYPE
ADDRESS* = ADDRESS;

Registers* = RECORD
  AX*, BX*, CX*, DX*, SI*, DI*, DS*, ES*, Flags* : INTEGER
END;

PROCEDURE CallFar*(ProcPtr: ADDRESS; VAR Regs:Registers);EXTERNAL;
PROCEDURE Intr*(IntNo: BYTE;VAR Regs : Registers);EXTERNAL;

(* SetExitProc/GetExitProc: a single global far-proc hook, run automatically
   by SYSTEM_DONE just before the program terminates (normal exit or Halt).
   Semantics mirror Turbo Pascal's ExitProc variable: there is exactly one
   slot, not a list, so a well-behaved handler that wants to chain to a
   previously-installed one must save GetExitProc() BEFORE calling
   SetExitProc() to install itself, and — critically — restore that saved
   value as the FIRST action inside its own handler, before doing any other
   cleanup work:

     PROCEDURE MyExit;
     BEGIN
       SYSTEM.SetExitProc(prevExitProc);  (* restore first: prevents SYSTEM_DONE
                                              from re-invoking this same handler,
                                              and lets the previous handler run
                                              next *)
       ... actual cleanup ...
     END MyExit;
     ...
     prevExitProc := SYSTEM.GetExitProc();
     SYSTEM.SetExitProc(SYSTEM.ADR(MyExit));

   SYSTEM_DONE calls the installed handler in a loop, re-reading the (now
   possibly-updated) hook after each call and stopping when it reads NIL —
   so a chain of handlers, each restoring its predecessor first, runs
   outermost-installed-last-added first, exactly like nested Pascal
   ExitProc chains. A handler that does NOT restore the previous value
   first will be called repeatedly forever (SYSTEM_DONE never sees it
   change), so this restore-first order is not optional. *)
PROCEDURE SetExitProc*(proc : ADDRESS); EXTERNAL;
PROCEDURE GetExitProc* : ADDRESS; EXTERNAL;
PROCEDURE Halt*(ErrCode: BYTE); EXTERNAL;


PROCEDURE Alloc*(sizeInBytes : WORD) : ADDRESS;EXTERNAL;
PROCEDURE Free*(p : ADDRESS) ; EXTERNAL;
PROCEDURE MemAvail*() : WORD; EXTERNAL;     (* total free heap, in paragraphs *)
PROCEDURE MemMaxAvail*() : WORD; EXTERNAL;  (* largest free block, in paragraphs *)

PROCEDURE S32MUL*(a, b :LONGINT):LONGINT;EXTERNAL;
PROCEDURE S32DIV*(a, b :LONGINT):LONGINT;EXTERNAL;
PROCEDURE S32MOD*(a, b :LONGINT):LONGINT;EXTERNAL;

(* ADR(VAR v): ADDRESS
   Returns the full far address (segment:offset) of variable v.
   Caller pushes v's far address: segment first (deepest), then offset.
   Stack on entry (POP order): offset, segment.
   POP AX=offset; POP DX=segment. Result: DX:AX = far pointer. SP balanced.
   Note: v must be a variable (local, global, VAR param, array element, pointer deref).
         Procedure names are not supported (use a procedure variable instead). *)
PROCEDURE ADR*(VAR v): ADDRESS;
  INLINE(058H, 05AH);

(* SEG(VAR v): WORD
   Returns the segment of variable v (SS for locals/params, DS for globals, heap seg for p^).
   Stack on entry (POP order): offset, segment.
   POP AX (=offset, discard); POP AX (=segment). Result: AX = segment. SP balanced. *)
PROCEDURE SEG*(VAR v): WORD;
  INLINE(058H, 058H);

(* OFS(VAR v): WORD
   Returns the offset of variable v within its segment.
   Stack on entry (POP order): offset, segment.
   POP AX (=offset); POP CX (=segment, discard). Result: AX = offset. SP balanced. *)
PROCEDURE OFS*(VAR v): WORD;
  INLINE(058H, 059H);

(* PTR(s, o: WORD): ADDRESS
   Constructs a far pointer from segment s and offset o.
   Caller pushes s first (deepest), then o.
   Stack on entry (POP order): o, s.
   POP AX=o (offset); POP DX=s (segment). Result: DX:AX = far pointer. SP balanced. *)
PROCEDURE PTR*(s, o: WORD): ADDRESS;
  INLINE(058H, 05AH);

(* MOVE(VAR src, dst; n: WORD)
   Copies n bytes forward from src to dst using word moves: n DIV 2 words via
   REP MOVSW, then the odd trailing byte via REP MOVSB (CF from SHR CX,1
   survives REP MOVSW — string ops do not touch flags — and ADC CX,CX turns it
   into the 0/1 byte count).  ~25-30 % faster than REP MOVSB on 8086 for the
   same forward-copy semantics; regions are expected to be non-overlapping.
   Caller pushes address of src (seg+ofs, 4 bytes), address of dst (4 bytes), n (2 bytes).
   Stack on entry (POP order): n, dst_ofs, dst_seg, src_ofs, src_seg.
   POP CX=n; POP DI=dst_ofs; POP ES=dst_seg; POP SI=src_ofs; POP AX=src_seg;
   PUSH DS; MOV DS,AX; CLD; SHR CX,1; REP MOVSW; ADC CX,CX; REP MOVSB;
   POP DS — SP balanced. *)
PROCEDURE MOVE*(VAR src, dst; n: WORD);
  INLINE(059H,05FH,007H,05EH,058H,01EH,08EH,0D8H,0FCH,
         0D1H,0E9H,0F3H,0A5H,013H,0C9H,0F3H,0A4H,01FH);

(* FILL(VAR dst; n: INTEGER; b: BYTE)
   Fills n bytes at dst with byte b using word stores: b is duplicated into AH
   (MOV AH,AL), n DIV 2 words via REP STOSW, then the odd trailing byte via
   REP STOSB (CF from SHR CX,1 survives REP STOSW; ADC CX,CX -> 0/1).
   Caller pushes address of dst (seg+ofs, 4 bytes), n (2 bytes), b (2 bytes).
   Stack on entry (POP order): b, n, dst_ofs, dst_seg.
   POP AX=b; POP CX=n; POP DI=dst_ofs; POP ES=dst_seg; MOV AH,AL; CLD;
   SHR CX,1; REP STOSW; ADC CX,CX; REP STOSB — SP balanced. *)
PROCEDURE FILL*(VAR dst; n: WORD; b: BYTE);
  INLINE(058H,059H,05FH,007H,08AH,0E0H,0FCH,
         0D1H,0E9H,0F3H,0ABH,013H,0C9H,0F3H,0AAH);

(* FINDBYTE(VAR buf; b: BYTE; maxLen: WORD): WORD
   Scans up to maxLen bytes at buf for byte b using REPNE SCASB; returns the
   0-based offset of the first match, or maxLen if not found.  Does not use
   JCXZ/LOOP (project rule — both are slow on real 8086 hardware): the
   zero-length guard uses OR CX,CX / JZ instead of JCXZ.
   Caller pushes address of buf (seg+ofs, 4 bytes), b (2 bytes), maxLen (2 bytes).
   Stack on entry (POP order): maxLen, b, buf_ofs, buf_seg.
   POP CX=maxLen; POP AX=b; POP DI=buf_ofs; POP ES=buf_seg; MOV DX,CX (save
   maxLen); CLD; OR CX,CX; JZ done (maxLen=0 -> AX:=DX=0); REPNE SCASB;
   JNZ done (not found -> AX:=DX=maxLen); INC CX (undo the match's own
   decrement); SUB DX,CX (DX := index of match); done: MOV AX,DX —
   SP balanced. *)
PROCEDURE FINDBYTE*(VAR buf; b: BYTE; maxLen: WORD): WORD;
  INLINE(059H,058H,05FH,007H,089H,0CAH,0FCH,009H,0C9H,074H,007H,
         0F2H,0AEH,075H,003H,041H,029H,0CAH,089H,0D0H);

(* COMPARE(VAR Mem1, Mem2; len: WORD): BOOLEAN
   Word-compare variant: len DIV 2 words via REPE CMPSW, then the odd trailing
   byte via CMPSB.  Unlike MOVE/FILL, CMPSW clobbers CF, so the odd bit is
   parked in DX (AND DX,1) instead of the ADC CX,CX trick.
     POP CX=len; POP DI; POP ES (Mem2); POP SI; POP AX (Mem1 seg);
     PUSH DS; MOV DS,AX; CLD; MOV AX,1;
     MOV DX,CX; AND DX,1; SHR CX,1;
     JCXZ tail; REPE CMPSW; JNZ fail;
     tail: MOV CX,DX; JCXZ done; CMPSB; JZ done;
     fail: DEC AX; done: POP DS *)
PROCEDURE COMPARE*(VAR Mem1, Mem2; len: WORD): BOOLEAN;
  INLINE(059H,05FH,007H,05EH,058H,01EH,08EH,0D8H,0FCH,0B8H,001H,000H,
         089H,0CAH,083H,0E2H,001H,0D1H,0E9H,
         0E3H,004H,0F3H,0A7H,075H,007H,
         089H,0D1H,0E3H,004H,0A6H,074H,001H,
         048H,01FH);

PROCEDURE MAX*(a, b: INTEGER): INTEGER;
  (* POP BX; POP AX; CMP AX, BX; JG done; MOV AX, BX; done: *)
  INLINE(05BH, 058H, 03BH, 0C3H, 07FH, 002H, 089H, 0D8H);

PROCEDURE MIN*(a, b: INTEGER): INTEGER;
  (* POP BX; POP AX; CMP AX, BX; JL done; MOV AX, BX; done: *)
  INLINE(05BH, 058H, 03BH, 0C3H, 07CH, 002H, 089H, 0D8H);

PROCEDURE LENGTH*(s: ARRAY OF CHAR): WORD;
  (* POP DI; POP ES; POP CX; MOV DX, CX; JCXZ done; XOR AL, AL; CLD; REPNZ SCASB;
     JNZ skip; DEC DX; skip: SUB DX, CX; done: MOV AX, DX *)
  INLINE(05FH, 007H, 059H, 089H, 0CAH, 0E3H, 00AH, 032H, 0C0H, 0FCH, 0F2H, 0AEH, 075H, 001H, 04AH, 029H, 0CAH, 089H, 0D0H);

PROCEDURE UCASE*(c: CHAR): CHAR;
  (* POP AX; CMP AL, 61H; JB done; CMP AL, 7AH; JA done; SUB AL, 20H; done: *)
  INLINE(058H, 03CH, 061H, 072H, 006H, 03CH, 07AH, 077H, 002H, 02CH, 020H);

PROCEDURE LCASE*(c: CHAR): CHAR;
  (* POP AX; CMP AL, 41H; JB done; CMP AL, 5AH; JA done; ADD AL, 20H; done: *)
  INLINE(058H, 03CH, 041H, 072H, 006H, 03CH, 05AH, 077H, 002H, 004H, 020H);

PROCEDURE ISDIGIT*(c: CHAR): BOOLEAN;
  (* POP AX; SUB AL, 30H; CMP AL, 0AH; SBB AX, AX; NEG AX *)
  INLINE(058H, 02CH, 030H, 03CH, 00AH, 019H, 0C0H, 0F7H, 0D8H);

PROCEDURE ISALPHA*(c: CHAR): BOOLEAN;
  (* POP AX; OR AL, 20H; SUB AL, 61H; CMP AL, 1AH; SBB AX, AX; NEG AX *)
  INLINE(058H, 00CH, 020H, 02CH, 061H, 03CH, 01AH, 019H, 0C0H, 0F7H, 0D8H);

PROCEDURE ISSPACE*(c: CHAR): BOOLEAN;
  (* POP AX; DEC AL; CMP AL, 20H; SBB AX, AX; NEG AX *)
  INLINE(058H, 0FEH, 0C8H, 03CH, 020H, 019H, 0C0H, 0F7H, 0D8H);

PROCEDURE ISHEX*(c: CHAR): BOOLEAN;
  (* POP AX; OR AL, 20H; SUB AL, 30H; CMP AL, 0AH; JB ok; SUB AL, 31H; CMP AL, 06H; ok: SBB AX, AX; NEG AX *)
  INLINE(058H, 00CH, 020H, 02CH, 030H, 03CH, 00AH, 072H, 004H, 02CH, 031H, 03CH, 006H, 019H, 0C0H, 0F7H, 0D8H);

(* s MUST be an open array (ARRAY OF CHAR): the INLINE pops the 6-byte open-array
   slot {ofs, seg, LEN} as BX, ES, CX.  A typeless `VAR s` pushes only {ofs, seg}
   (no LEN), so POP CX would read garbage and the loop would run over wrong memory
   — corrupting the heap and crashing the compiler.  Keep the typed signature. *)
PROCEDURE UPSTR*(VAR s: ARRAY OF CHAR);
  (* POP BX; POP ES; POP CX; JCXZ done; loop: MOV AL, ES:[BX]; OR AL, AL; JZ done;
     CMP AL, 61H; JB skip; CMP AL, 7AH; JA skip; SUB AL, 20H; MOV ES:[BX], AL;
     skip: INC BX; LOOP loop; done: *)
  (* JCXZ/JZ offsets fixed: the proc body is 28 bytes, so `done` is at +28.  The
     original E3 19 / 74 12 targeted +30 (2 bytes past the end), jumping into the
     following code and crashing.  Correct: JCXZ +17H (done), JZ +10H (done). *)
  INLINE(05BH, 007H, 059H, 0E3H, 017H, 026H, 08AH, 007H, 008H, 0C0H, 074H, 010H, 03CH, 061H, 072H, 009H, 03CH, 07AH, 077H, 005H, 02CH, 020H, 026H, 088H, 007H, 043H, 0E2H, 0E9H);

PROCEDURE LOSTR*(VAR s: ARRAY OF CHAR);
  (* POP BX; POP ES; POP CX; JCXZ done; loop: MOV AL, ES:[BX]; OR AL, AL; JZ done;
     CMP AL, 41H; JB skip; CMP AL, 5AH; JA skip; ADD AL, 20H; MOV ES:[BX], AL;
     skip: INC BX; LOOP loop; done: *)
  (* JCXZ/JZ offsets fixed (same off-by-2 bug as UPSTR): JCXZ +17H, JZ +10H. *)
  INLINE(05BH, 007H, 059H, 0E3H, 017H, 026H, 08AH, 007H, 008H, 0C0H, 074H, 010H, 3CH, 41H, 72H, 09H, 3CH, 5AH, 77H, 05H, 04H, 20H, 26H, 88H, 07H, 43H, 0E2H, 0E9H);

PROCEDURE BLOCKWRITE*(h: INTEGER; VAR buf; len: WORD): WORD;
  (* POP CX; POP DX; POP AX; POP BX; PUSH DS; MOV DS, AX; MOV AH, 40H;
     INT 21H; JNC done; XOR AX, AX; done: POP DS *)
  INLINE(059H, 05AH, 058H, 05BH, 01EH, 08EH, 0D8H, 0B4H, 040H, 0CDH, 021H, 073H, 002H, 031H, 0C0H, 01FH);

PROCEDURE BLOCKREAD*(h: INTEGER; VAR buf; len: WORD): WORD;
  (* POP CX; POP DX; POP AX; POP BX; PUSH DS; MOV DS, AX; MOV AH, 3FH;
     INT 21H; JNC done; XOR AX, AX; done: POP DS *)
  INLINE(059H, 05AH, 058H, 05BH, 01EH, 08EH, 0D8H, 0B4H, 03FH, 0CDH, 021H, 073H, 002H, 031H, 0C0H, 01FH);

PROCEDURE FCLOSE*(h: INTEGER);
  (* POP BX; MOV AH, 3EH; INT 21H *)
  INLINE(05BH, 0B4H, 03EH, 0CDH, 021H);

PROCEDURE FPOS*(h: INTEGER): LONGINT;
  (* POP BX; XOR CX, CX; XOR DX, DX; MOV AX, 4201H; INT 21H; JNC ok; MOV AX, 0FFFFH; MOV DX, AX; ok: *)
  INLINE(05BH, 031H, 0C9H, 031H, 0D2H, 0B8H, 001H, 042H, 0CDH, 021H, 073H, 005H, 0B8H, 0FFH, 0FFH, 089H, 0C2H);

PROCEDURE FSIZE*(h: INTEGER): LONGINT;
  (* POP BX; PUSH SI; PUSH DI; XOR CX, CX; XOR DX, DX; MOV AX, 4201H; INT 21H;
     PUSH DX; PUSH AX; XOR CX, CX; XOR DX, DX; MOV AX, 4202H; INT 21H;
     MOV SI, AX; MOV DI, DX; POP DX; POP CX; MOV AX, 4200H; INT 21H;
     MOV AX, SI; MOV DX, DI; POP DI; POP SI *)
  INLINE(05BH, 056H, 057H, 031H, 0C9H, 031H, 0D2H, 0B8H, 001H, 042H, 0CDH, 021H, 052H, 050H, 031H, 0C9H, 031H, 0D2H, 0B8H, 002H, 042H, 0CDH, 021H, 089H, 0C6H, 089H, 0D7H, 05AH, 059H, 0B8H, 000H, 042H, 0CDH, 021H, 089H, 0F0H, 089H, 0FAH, 05FH, 05EH);

PROCEDURE FSEEK*(h: INTEGER; ofs: LONGINT);
  (* POP AX; POP CX; POP BX; MOV DX, AX; MOV AX, 4200H; INT 21H *)
  INLINE(058H, 059H, 05BH, 089H, 0C2H, 0B8H, 000H, 042H, 0CDH, 021H);

PROCEDURE PORTOUT*(port : INTEGER; b: BYTE);
  INLINE(058H,05AH,0EEH);

PROCEDURE PORTIN*(port : INTEGER) : BYTE;
  INLINE(05AH,0ECH);

PROCEDURE DOSCHAR*(c: CHAR);
  (* POP DX; MOV AH, 02H; INT 21H *)
  INLINE(05AH, 0B4H, 002H, 0CDH, 021H);

PROCEDURE DOSMESSAGE*(msg: ARRAY OF CHAR);
  (* POP DX; POP AX; POP CX; PUSH DS; MOV DS, AX; MOV AH, 09H; INT 21H; POP DS *)
  INLINE(05AH, 058H, 059H, 01EH, 08EH, 0D8H, 0B4H, 009H, 0CDH, 021H, 01FH);

PROCEDURE VIDEOMODE*(mode: BYTE);
  (* POP AX; MOV AH, 00H; INT 10H *)
  INLINE(058H, 0B4H, 000H, 0CDH, 010H);

PROCEDURE Error(errCode : INTEGER; msg : ARRAY OF CHAR);
BEGIN
    DOSMESSAGE("Run-time error $");
    DOSMESSAGE(msg);
    Halt(errCode)
END Error;

PROCEDURE ErrDivisionByZero*;
BEGIN
    Error(200, "200: Division by zero$");
END ErrDivisionByZero;

PROCEDURE ErrIndexOutOfBounds*;
BEGIN
    Error(201, "201: Array index out of bounds$");
END ErrIndexOutOfBounds;

PROCEDURE ErrStackOverflow*;
BEGIN
    Error(202, "202: Stack overflow$");
END ErrStackOverflow;

PROCEDURE ErrInvalidPointerOperation*;
BEGIN
    Error(204, "204: Invalid pointer operation$");
END ErrInvalidPointerOperation;

(*$L SYS.RDF*)

END SYSTEM.