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

(* CallFar: invoke an arbitrary far procedure with a caller-supplied register
   set, then copy the CPU's actual registers back into Regs on return.
   Parameters: ProcPtr — far address of the procedure to call; Regs — the
   register values to load before the call, overwritten with the values
   the callee left on return.
   Result: none (output is via the Regs VAR parameter). *)
PROCEDURE CallFar*(ProcPtr: ADDRESS; VAR Regs:Registers);EXTERNAL;
(* Intr: issue a real-mode software interrupt (INT n) with a caller-supplied
   register set, then copy the CPU's actual registers back into Regs.
   Parameters: IntNo — the interrupt number to invoke (e.g. 21H for DOS);
   Regs — register values to load before the interrupt, overwritten with
   the callee's return values (including Flags, so callers can test CF).
   Result: none (output is via the Regs VAR parameter). *)
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
(* SetExitProc: install a far-proc hook to run automatically at program exit.
   Parameters: proc — far address of the handler to install (see the chaining
   discussion above), or NIL to clear the hook.
   Result: none. *)
PROCEDURE SetExitProc*(proc : ADDRESS); EXTERNAL;
(* GetExitProc: read the currently-installed exit-proc hook.
   Result: far address of the current handler, or NIL if none is installed. *)
PROCEDURE GetExitProc* : ADDRESS; EXTERNAL;
(* Halt: terminate the program immediately (runs the exit-proc chain first,
   then returns to DOS via INT 21h/AH=4Ch).  Must be called exactly once, at
   the end of the program's Run procedure — never from an arbitrary error path.
   Parameters: ErrCode — the DOS exit code the process returns to its caller.
   Result: does not return. *)
PROCEDURE Halt*(ErrCode: BYTE); EXTERNAL;


(* Alloc: allocate a block from the heap.
   Parameters: sizeInBytes — requested block size in bytes.
   Result: far pointer to the allocated block, or NIL if the heap has no
   free block large enough. *)
PROCEDURE Alloc*(sizeInBytes : WORD) : ADDRESS;EXTERNAL;
(* Free: release a block previously returned by Alloc.
   Parameters: p — far pointer to the block to free.
   Result: none. *)
PROCEDURE Free*(p : ADDRESS) ; EXTERNAL;
(* MemAvail: total free heap memory.
   Result: sum of all free blocks' sizes, in paragraphs (16-byte units). *)
PROCEDURE MemAvail*() : WORD; EXTERNAL;     (* total free heap, in paragraphs *)
(* MemMaxAvail: largest single free heap block.
   Result: size of the largest contiguous free block, in paragraphs. *)
PROCEDURE MemMaxAvail*() : WORD; EXTERNAL;  (* largest free block, in paragraphs *)

(* S32MUL: 32-bit signed multiply (the runtime backing for Oberon's `*` on
   LONGINT operands).
   Parameters: a, b — the two operands.
   Result: a * b, truncated to 32 bits on overflow. *)
PROCEDURE S32MUL*(a, b :LONGINT):LONGINT;EXTERNAL;
(* S32DIV: 32-bit signed floored division (the runtime backing for Oberon's
   `DIV` on LONGINT operands — quotient rounds toward -infinity, not zero).
   Parameters: a — dividend; b — divisor.
   Result: floor(a / b). *)
PROCEDURE S32DIV*(a, b :LONGINT):LONGINT;EXTERNAL;
(* S32MOD: 32-bit signed floored remainder (the runtime backing for Oberon's
   `MOD` on LONGINT operands — result takes the divisor's sign).
   Parameters: a — dividend; b — divisor.
   Result: a MOD b (floored semantics, matching S32DIV's quotient). *)
PROCEDURE S32MOD*(a, b :LONGINT):LONGINT;EXTERNAL;

(* ADR(VAR v): ADDRESS
   Returns the full far address (segment:offset) of variable v.
   Caller pushes v's far address: segment first (deepest), then offset.
   Stack on entry (POP order): offset, segment.
   POP AX=offset; POP DX=segment. Result: DX:AX = far pointer. SP balanced.
   Note: v must be a variable (local, global, VAR param, array element, pointer deref).
         Procedure names are not supported (use a procedure variable instead).
   Parameters: v — the variable whose address is wanted.
   Result: the far address (segment:offset) of v. *)
PROCEDURE ADR*(VAR v): ADDRESS;
  INLINE(058H, 05AH);

(* SEG(VAR v): WORD
   Returns the segment of variable v (SS for locals/params, DS for globals, heap seg for p^).
   Stack on entry (POP order): offset, segment.
   POP AX (=offset, discard); POP AX (=segment). Result: AX = segment. SP balanced.
   Parameters: v — the variable whose segment is wanted.
   Result: the segment portion of v's far address. *)
PROCEDURE SEG*(VAR v): WORD;
  INLINE(058H, 058H);

(* OFS(VAR v): WORD
   Returns the offset of variable v within its segment.
   Stack on entry (POP order): offset, segment.
   POP AX (=offset); POP CX (=segment, discard). Result: AX = offset. SP balanced.
   Parameters: v — the variable whose offset is wanted.
   Result: the offset portion of v's far address. *)
PROCEDURE OFS*(VAR v): WORD;
  INLINE(058H, 059H);

(* PTR(s, o: WORD): ADDRESS
   Constructs a far pointer from segment s and offset o.
   Caller pushes s first (deepest), then o.
   Stack on entry (POP order): o, s.
   POP AX=o (offset); POP DX=s (segment). Result: DX:AX = far pointer. SP balanced.
   Parameters: s — segment; o — offset within that segment.
   Result: the far pointer {s, o}. *)
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
   POP DS — SP balanced.
   Parameters: src — source buffer; dst — destination buffer; n — number of
   bytes to copy.  Result: none. *)
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
   SHR CX,1; REP STOSW; ADC CX,CX; REP STOSB — SP balanced.
   Parameters: dst — buffer to fill; n — number of bytes to fill; b — fill
   byte value.  Result: none. *)
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
   SP balanced.
   Parameters: buf — buffer to scan; b — byte value to find; maxLen — number
   of bytes to scan starting at buf.
   Result: 0-based offset of the first match, or maxLen if not found. *)
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
     fail: DEC AX; done: POP DS
   Parameters: Mem1, Mem2 — the two buffers to compare; len — number of
   bytes to compare.
   Result: TRUE if the first len bytes of Mem1 and Mem2 are identical. *)
PROCEDURE COMPARE*(VAR Mem1, Mem2; len: WORD): BOOLEAN;
  INLINE(059H,05FH,007H,05EH,058H,01EH,08EH,0D8H,0FCH,0B8H,001H,000H,
         089H,0CAH,083H,0E2H,001H,0D1H,0E9H,
         0E3H,004H,0F3H,0A7H,075H,007H,
         089H,0D1H,0E3H,004H,0A6H,074H,001H,
         048H,01FH);

(* MAX: larger of two INTEGERs.
   Parameters: a, b — the two values to compare.
   Result: a if a > b, else b.
   POP BX; POP AX; CMP AX, BX; JG done; MOV AX, BX; done: *)
PROCEDURE MAX*(a, b: INTEGER): INTEGER;
  INLINE(05BH, 058H, 03BH, 0C3H, 07FH, 002H, 089H, 0D8H);

(* MIN: smaller of two INTEGERs.
   Parameters: a, b — the two values to compare.
   Result: a if a < b, else b.
   POP BX; POP AX; CMP AX, BX; JL done; MOV AX, BX; done: *)
PROCEDURE MIN*(a, b: INTEGER): INTEGER;
  INLINE(05BH, 058H, 03BH, 0C3H, 07CH, 002H, 089H, 0D8H);

(* LENGTH: length of a NUL-terminated open-array string (the primitive
   Strings.Length is built on).
   Parameters: s — the string to measure.
   Result: number of characters before the terminating 0X.
   POP DI; POP ES; POP CX; MOV DX, CX; JCXZ done; XOR AL, AL; CLD; REPNZ SCASB;
   JNZ skip; DEC DX; skip: SUB DX, CX; done: MOV AX, DX *)
PROCEDURE LENGTH*(s: ARRAY OF CHAR): WORD;
  INLINE(05FH, 007H, 059H, 089H, 0CAH, 0E3H, 00AH, 032H, 0C0H, 0FCH, 0F2H, 0AEH, 075H, 001H, 04AH, 029H, 0CAH, 089H, 0D0H);

(* UCASE: convert a single CHAR to uppercase (ASCII a..z only).
   Parameters: c — the character to convert.
   Result: c uppercased if c was 'a'..'z', else c unchanged.
   POP AX; CMP AL, 61H; JB done; CMP AL, 7AH; JA done; SUB AL, 20H; done: *)
PROCEDURE UCASE*(c: CHAR): CHAR;
  INLINE(058H, 03CH, 061H, 072H, 006H, 03CH, 07AH, 077H, 002H, 02CH, 020H);

(* LCASE: convert a single CHAR to lowercase (ASCII A..Z only).
   Parameters: c — the character to convert.
   Result: c lowercased if c was 'A'..'Z', else c unchanged.
   POP AX; CMP AL, 41H; JB done; CMP AL, 5AH; JA done; ADD AL, 20H; done: *)
PROCEDURE LCASE*(c: CHAR): CHAR;
  INLINE(058H, 03CH, 041H, 072H, 006H, 03CH, 05AH, 077H, 002H, 004H, 020H);

(* ISDIGIT: test whether c is an ASCII decimal digit '0'..'9'.
   Parameters: c — the character to test.
   Result: TRUE if c is '0'..'9'.
   POP AX; SUB AL, 30H; CMP AL, 0AH; SBB AX, AX; NEG AX *)
PROCEDURE ISDIGIT*(c: CHAR): BOOLEAN;
  INLINE(058H, 02CH, 030H, 03CH, 00AH, 019H, 0C0H, 0F7H, 0D8H);

(* ISALPHA: test whether c is an ASCII letter (case-insensitive).
   Parameters: c — the character to test.
   Result: TRUE if c is 'A'..'Z' or 'a'..'z'.
   POP AX; OR AL, 20H; SUB AL, 61H; CMP AL, 1AH; SBB AX, AX; NEG AX *)
PROCEDURE ISALPHA*(c: CHAR): BOOLEAN;
  INLINE(058H, 00CH, 020H, 02CH, 061H, 03CH, 01AH, 019H, 0C0H, 0F7H, 0D8H);

(* ISSPACE: test whether c is a space or one of the low control characters
   immediately below it (0x01..0x20, since the test is DEC AL; CMP AL,0x20).
   Parameters: c — the character to test.
   Result: TRUE if ORD(c) is in 1..32.
   POP AX; DEC AL; CMP AL, 20H; SBB AX, AX; NEG AX *)
PROCEDURE ISSPACE*(c: CHAR): BOOLEAN;
  INLINE(058H, 0FEH, 0C8H, 03CH, 020H, 019H, 0C0H, 0F7H, 0D8H);

(* ISHEX: test whether c is an ASCII hex digit (case-insensitive).
   Parameters: c — the character to test.
   Result: TRUE if c is '0'..'9', 'A'..'F', or 'a'..'f'.
   POP AX; OR AL, 20H; SUB AL, 30H; CMP AL, 0AH; JB ok; SUB AL, 31H; CMP AL, 06H; ok: SBB AX, AX; NEG AX *)
PROCEDURE ISHEX*(c: CHAR): BOOLEAN;
  INLINE(058H, 00CH, 020H, 02CH, 030H, 03CH, 00AH, 072H, 004H, 02CH, 031H, 03CH, 006H, 019H, 0C0H, 0F7H, 0D8H);

(* UPSTR: uppercase a string in place (ASCII a..z only).
   s MUST be an open array (ARRAY OF CHAR): the INLINE pops the 6-byte open-array
   slot {ofs, seg, LEN} as BX, ES, CX.  A typeless `VAR s` pushes only {ofs, seg}
   (no LEN), so POP CX would read garbage and the loop would run over wrong memory
   — corrupting the heap and crashing the compiler.  Keep the typed signature.
   Parameters: s — the string to uppercase, modified in place.
   Result: none.
   POP BX; POP ES; POP CX; JCXZ done; loop: MOV AL, ES:[BX]; OR AL, AL; JZ done;
   CMP AL, 61H; JB skip; CMP AL, 7AH; JA skip; SUB AL, 20H; MOV ES:[BX], AL;
   skip: INC BX; LOOP loop; done: *)
  (* JCXZ/JZ offsets fixed: the proc body is 28 bytes, so `done` is at +28.  The
     original E3 19 / 74 12 targeted +30 (2 bytes past the end), jumping into the
     following code and crashing.  Correct: JCXZ +17H (done), JZ +10H (done). *)
PROCEDURE UPSTR*(VAR s: ARRAY OF CHAR);
  INLINE(05BH, 007H, 059H, 0E3H, 017H, 026H, 08AH, 007H, 008H, 0C0H, 074H, 010H, 03CH, 061H, 072H, 009H, 03CH, 07AH, 077H, 005H, 02CH, 020H, 026H, 088H, 007H, 043H, 0E2H, 0E9H);

(* LOSTR: lowercase a string in place (ASCII A..Z only). Same open-array
   requirement as UPSTR.
   Parameters: s — the string to lowercase, modified in place.
   Result: none.
   POP BX; POP ES; POP CX; JCXZ done; loop: MOV AL, ES:[BX]; OR AL, AL; JZ done;
   CMP AL, 41H; JB skip; CMP AL, 5AH; JA skip; ADD AL, 20H; MOV ES:[BX], AL;
   skip: INC BX; LOOP loop; done: *)
  (* JCXZ/JZ offsets fixed (same off-by-2 bug as UPSTR): JCXZ +17H, JZ +10H. *)
PROCEDURE LOSTR*(VAR s: ARRAY OF CHAR);
  INLINE(05BH, 007H, 059H, 0E3H, 017H, 026H, 08AH, 007H, 008H, 0C0H, 074H, 010H, 3CH, 41H, 72H, 09H, 3CH, 5AH, 77H, 05H, 04H, 20H, 26H, 88H, 07H, 43H, 0E2H, 0E9H);

(* BLOCKWRITE: raw DOS write to an open file handle (INT 21h/AH=40h).
   Parameters: h — DOS file handle; buf — buffer to write from; len — number
   of bytes to write.
   Result: number of bytes actually written, or 0 on a DOS error.
   POP CX; POP DX; POP AX; POP BX; PUSH DS; MOV DS, AX; MOV AH, 40H;
   INT 21H; JNC done; XOR AX, AX; done: POP DS *)
PROCEDURE BLOCKWRITE*(h: INTEGER; VAR buf; len: WORD): WORD;
  INLINE(059H, 05AH, 058H, 05BH, 01EH, 08EH, 0D8H, 0B4H, 040H, 0CDH, 021H, 073H, 002H, 031H, 0C0H, 01FH);

(* BLOCKREAD: raw DOS read from an open file handle (INT 21h/AH=3Fh).
   Parameters: h — DOS file handle; buf — buffer to read into; len — number
   of bytes to read.
   Result: number of bytes actually read (0 at EOF), or 0 on a DOS error.
   POP CX; POP DX; POP AX; POP BX; PUSH DS; MOV DS, AX; MOV AH, 3FH;
   INT 21H; JNC done; XOR AX, AX; done: POP DS *)
PROCEDURE BLOCKREAD*(h: INTEGER; VAR buf; len: WORD): WORD;
  INLINE(059H, 05AH, 058H, 05BH, 01EH, 08EH, 0D8H, 0B4H, 03FH, 0CDH, 021H, 073H, 002H, 031H, 0C0H, 01FH);

(* FCLOSE: close a DOS file handle (INT 21h/AH=3Eh).
   Parameters: h — DOS file handle to close.
   Result: none.
   POP BX; MOV AH, 3EH; INT 21H *)
PROCEDURE FCLOSE*(h: INTEGER);
  INLINE(05BH, 0B4H, 03EH, 0CDH, 021H);

(* FPOS: current seek position of an open file handle (INT 21h/AH=42h,
   AL=1, ofs=0 — seek-relative-to-current-position by zero bytes, which
   reports the position without moving it).
   Parameters: h — DOS file handle.
   Result: current byte offset from the start of the file, or -1 on a DOS
   error.
   POP BX; XOR CX, CX; XOR DX, DX; MOV AX, 4201H; INT 21H; JNC ok; MOV AX, 0FFFFH; MOV DX, AX; ok: *)
PROCEDURE FPOS*(h: INTEGER): LONGINT;
  INLINE(05BH, 031H, 0C9H, 031H, 0D2H, 0B8H, 001H, 042H, 0CDH, 021H, 073H, 005H, 0B8H, 0FFH, 0FFH, 089H, 0C2H);

(* FSIZE: total size of an open file, determined by seeking to end-of-file
   (INT 21h/AH=42h, AL=2) and back to the original position (AL=0) so the
   handle's seek position is left unchanged.
   Parameters: h — DOS file handle.
   Result: file size in bytes.
   POP BX; PUSH SI; PUSH DI; XOR CX, CX; XOR DX, DX; MOV AX, 4201H; INT 21H;
   PUSH DX; PUSH AX; XOR CX, CX; XOR DX, DX; MOV AX, 4202H; INT 21H;
   MOV SI, AX; MOV DI, DX; POP DX; POP CX; MOV AX, 4200H; INT 21H;
   MOV AX, SI; MOV DX, DI; POP DI; POP SI *)
PROCEDURE FSIZE*(h: INTEGER): LONGINT;
  INLINE(05BH, 056H, 057H, 031H, 0C9H, 031H, 0D2H, 0B8H, 001H, 042H, 0CDH, 021H, 052H, 050H, 031H, 0C9H, 031H, 0D2H, 0B8H, 002H, 042H, 0CDH, 021H, 089H, 0C6H, 089H, 0D7H, 05AH, 059H, 0B8H, 000H, 042H, 0CDH, 021H, 089H, 0F0H, 089H, 0FAH, 05FH, 05EH);

(* FSEEK: set the absolute seek position of an open file handle
   (INT 21h/AH=42h, AL=0 — seek-from-start).
   Parameters: h — DOS file handle; ofs — absolute byte offset to seek to.
   Result: none.
   POP AX; POP CX; POP BX; MOV DX, AX; MOV AX, 4200H; INT 21H *)
PROCEDURE FSEEK*(h: INTEGER; ofs: LONGINT);
  INLINE(058H, 059H, 05BH, 089H, 0C2H, 0B8H, 000H, 042H, 0CDH, 021H);

(* PORTOUT: write a byte to an I/O port (OUT DX, AL).
   Parameters: port — I/O port number; b — byte value to write.
   Result: none. *)
PROCEDURE PORTOUT*(port : INTEGER; b: BYTE);
  INLINE(058H,05AH,0EEH);

(* PORTIN: read a byte from an I/O port (IN AL, DX).
   Parameters: port — I/O port number.
   Result: the byte read. *)
PROCEDURE PORTIN*(port : INTEGER) : BYTE;
  INLINE(05AH,0ECH);

(* DOSCHAR: write a single character to standard output (INT 21h/AH=02h).
   Parameters: c — the character to write.
   Result: none.
   POP DX; MOV AH, 02H; INT 21H *)
PROCEDURE DOSCHAR*(c: CHAR);
  INLINE(05AH, 0B4H, 002H, 0CDH, 021H);

(* DOSMESSAGE: write a '$'-terminated string to standard output
   (INT 21h/AH=09h — the classic DOS string-print call).
   Parameters: msg — '$'-terminated message string.
   Result: none.
   POP DX; POP AX; POP CX; PUSH DS; MOV DS, AX; MOV AH, 09H; INT 21H; POP DS *)
PROCEDURE DOSMESSAGE*(msg: ARRAY OF CHAR);
  INLINE(05AH, 058H, 059H, 01EH, 08EH, 0D8H, 0B4H, 009H, 0CDH, 021H, 01FH);

(* VIDEOMODE: set the BIOS text/graphics video mode (INT 10h/AH=00h).
   Parameters: mode — BIOS video mode number (e.g. 3 = 80x25 color text).
   Result: none.
   POP AX; MOV AH, 00H; INT 10H *)
PROCEDURE VIDEOMODE*(mode: BYTE);
  INLINE(058H, 0B4H, 000H, 0CDH, 010H);

PROCEDURE Error(errCode : INTEGER; msg : ARRAY OF CHAR);
BEGIN
    DOSMESSAGE("Run-time error $");
    DOSMESSAGE(msg);
    Halt(errCode)
END Error;

(* ErrDivisionByZero: runtime trap handler invoked by compiler-generated
   code when a DIV/MOD divisor is zero.  Prints an error message and halts
   with exit code 200.
   Parameters: none.  Result: does not return. *)
PROCEDURE ErrDivisionByZero*;
BEGIN
    Error(200, "200: Division by zero$");
END ErrDivisionByZero;

(* ErrIndexOutOfBounds: runtime trap handler invoked by compiler-generated
   bounds-check code ($R+) when an array index is out of range.  Prints an
   error message and halts with exit code 201.
   Parameters: none.  Result: does not return. *)
PROCEDURE ErrIndexOutOfBounds*;
BEGIN
    Error(201, "201: Array index out of bounds$");
END ErrIndexOutOfBounds;

(* ErrStackOverflow: runtime trap handler invoked when the program's stack
   is exhausted.  Prints an error message and halts with exit code 202.
   Parameters: none.  Result: does not return. *)
PROCEDURE ErrStackOverflow*;
BEGIN
    Error(202, "202: Stack overflow$");
END ErrStackOverflow;

(* ErrInvalidPointerOperation: runtime trap handler invoked by
   compiler-generated code on an invalid pointer operation (e.g. a NIL
   dereference caught at runtime).  Prints an error message and halts with
   exit code 204.
   Parameters: none.  Result: does not return. *)
PROCEDURE ErrInvalidPointerOperation*;
BEGIN
    Error(204, "204: Invalid pointer operation$");
END ErrInvalidPointerOperation;

PROCEDURE Seg0040*:WORD; EXTERNAL;
PROCEDURE SegB000*:WORD; EXTERNAL;
PROCEDURE SegB800*:WORD; EXTERNAL;
PROCEDURE SegA000*:WORD; EXTERNAL;

(*$L SYSTEM.RDF*)

END SYSTEM.