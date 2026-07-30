(*
  Tetris for CGA (mode 4, 320x200 4-colour)

  The game logic is pure Oberon.  Only the per-frame CGA sprite blitter is
  in assembly (TETRIS.ASM -> TETRIS.RDF, linked via the $L directive).

  Controls: Left/Right = move, Up/Down = rotate, Space = drop,
            P = pause, M = toggle sound, Esc = quit.

  Now, I (and you) saw something new: cga-camo.
*)
MODULE Tetris;

IMPORT Random;

(* Cell values held in screen/field/figureField: each byte is a sprite
   index (0..9) into spr.  This dialect has only integer CONSTs, so these
   are INTEGER byte-values and the grids are ARRAY OF BYTE. *)
CONST
  ChVL    = 05H;   (* vertical border   *)
  ChHL    = 06H;   (* horizontal border *)
  ChLC    = 07H;   (* left  corner *)
  ChRC    = 08H;   (* right corner *)
  ChDot   = 04H;   (* empty-cell dot *)
  ChEmpty = 00H;
  ChRB    = 01H;   (* falling-figure block *)
  ChGB    = 02H;   (* settled block *)
  ChFull  = 09H;   (* full-row flash *)
  ChSkip  = 0FFH;  (* sentinel: cell unchanged since last frame -> Draw skips it *)

(* BIOS keyboard scan codes (high byte of INT 16h AH=0), used by Game. *)
  ScEsc   = 01H;   (* quit *)
  ScP     = 19H;   (* pause *)
  ScM     = 32H;   (* toggle sound *)
  ScSpace = 39H;   (* drop *)
  ScLeft  = 4BH;   (* move left *)
  ScRight = 4DH;   (* move right *)
  ScUp    = 48H;   (* rotate clockwise *)
  ScDown  = 50H;   (* rotate counter-clockwise *)

(* Sprite table: 10 sprites x 16 bytes (one 4x8 CGA cell each). *)
VAR spr: ARRAY 10, 16 OF BYTE;

(* Figure shapes: 8 pieces, 3 rows x 4 cols packed as 12 chars. *)
VAR figures: ARRAY 8, 13 OF CHAR;

VAR
  screen      : ARRAY 25, 40 OF BYTE;
  prev        : ARRAY 25, 40 OF BYTE;   (* last frame's rendered cells (for dirty-cell diff) *)
  field       : ARRAY 20, 10 OF BYTE;
  figureField : ARRAY 4, 4 OF BYTE;
  figI, figN  : INTEGER;
  figX, figY  : INTEGER;
  figA        : INTEGER;
  figW, figH  : INTEGER;
  pause       : INTEGER;
  lines       : INTEGER;
  muted       : BOOLEAN;

(* --- assembly (TETRIS.ASM, linked via $L) ------------------------------- *)
(* All FAR (Pascal call convention: args pushed left-to-right, callee pops
   the stack).  Function results come back in AX. *)

(* CGA sprite blitter *)
PROCEDURE Draw(VAR buf; VAR sprites); FAR; EXTERNAL;
(* dirty-cell diff: mask unchanged cells 0FFH *)
PROCEDURE CalcDiff(VAR scr; VAR prv); FAR; EXTERNAL;

PROCEDURE GraphMode; FAR; EXTERNAL;             (* set CGA mode 4 *)
PROCEDURE TextMode; FAR; EXTERNAL;              (* set 80x25 text *)
PROCEDURE GetKey(): WORD; FAR; EXTERNAL;        (* INT 16h AH=0, blocking *)
PROCEDURE HasKey(): BOOLEAN; FAR; EXTERNAL;     (* INT 16h AH=1 peek *)
PROCEDURE Scan(key: WORD): BYTE; FAR; EXTERNAL; (* scan code = hi(key) *)
PROCEDURE Delay(ms: INTEGER); FAR; EXTERNAL;    (* BIOS wait, INT 15h AH=86h *)
PROCEDURE Sound(hz: INTEGER); FAR; EXTERNAL;    (* PC-speaker tone on *)
PROCEDURE NoSound; FAR; EXTERNAL;               (* PC-speaker off *)
(* drain the keyboard buffer, then block for one keypress (result discarded) *)
PROCEDURE WaitKey; FAR; EXTERNAL;

(*$L TETRIS.RDF*)

PROCEDURE MkAnimDown(x, y, width, heigh : INTEGER);
VAR dy : INTEGER;
BEGIN
  dy := 0;
  WHILE dy < heigh DO
     SYSTEM.FILL(screen[y+dy,x], width, ChFull);
     IF dy # 0 THEN SYSTEM.FILL(screen[y + dy - 1, x], width, ChGB) END;
     Delay(15);
     INC(dy);
     CalcDiff(screen, prev);
     Draw(screen, spr)
  END;
END MkAnimDown;

PROCEDURE MkAnimUp(x, y, width, heigh : INTEGER; Empty : BYTE);
VAR dy : INTEGER;
BEGIN
  dy := heigh - 1;
  WHILE dy >= 0 DO
     SYSTEM.FILL(screen[y+dy,x], width, ChFull);
     IF dy < heigh - 1 THEN SYSTEM.FILL(screen[y + dy + 1, x], width, Empty) END;
     Delay(15);
     DEC(dy);
     CalcDiff(screen, prev);
     Draw(screen, spr)
  END;
END MkAnimUp;

(* --- game logic --------------------------------------------------------- *)

PROCEDURE IsFigLineEmpty(line: INTEGER): BOOLEAN;
  VAR x: INTEGER;
BEGIN
  FOR x := 0 TO 3 DO
    IF figureField[line, x] # ChEmpty THEN RETURN FALSE END
  END;
  RETURN TRUE
END IsFigLineEmpty;

PROCEDURE IsFigColEmpty(col: INTEGER): BOOLEAN;
  VAR y: INTEGER;
BEGIN
  FOR y := 0 TO 3 DO
    IF figureField[y, col] # ChEmpty THEN RETURN FALSE END
  END;
  RETURN TRUE
END IsFigColEmpty;

PROCEDURE LoadFigure;
  VAR x, y: INTEGER;
BEGIN
  (* NB: index the 2D `figures` directly.  Copying a row into a local
     ARRAY 13 OF CHAR (`figure := figures[figI]`) does not work in this
     dialect -- it yields an all-NUL array, so every cell read as non-space
     and the shapes came out solid. *)
  SYSTEM.FILL(figureField[0,0], 16, ChEmpty);
  IF figA = 0 THEN
    FOR y := 0 TO 2 DO FOR x := 0 TO 3 DO
      IF figures[figI, y * 4 + x] # " " THEN figureField[y, x] := ChRB END
    END END
  ELSIF figA = 1 THEN
    FOR y := 0 TO 2 DO FOR x := 0 TO 3 DO
      IF figures[figI, y * 4 + x] # " " THEN figureField[3 - x, y] := ChRB END
    END END
  ELSIF figA = 2 THEN
    FOR y := 0 TO 2 DO FOR x := 0 TO 3 DO
      IF figures[figI, y * 4 + x] # " " THEN figureField[3 - y, 3 - x] := ChRB END
    END END
  ELSIF figA = 3 THEN
    FOR y := 0 TO 2 DO FOR x := 0 TO 3 DO
      IF figures[figI, y * 4 + x] # " " THEN figureField[x, 3 - y] := ChRB END
    END END
  END;

  WHILE IsFigLineEmpty(0) DO
    FOR y := 1 TO 3 DO
      SYSTEM.MOVE(figureField[y, 0],
                  figureField[y - 1, 0], 4)
    END;
    SYSTEM.FILL(figureField[3, 0], 4, ChEmpty)
  END;
  WHILE IsFigColEmpty(0) DO
    FOR y := 0 TO 3 DO
      SYSTEM.MOVE(figureField[y, 1],
                  figureField[y, 0], 4)
    END;
    FOR y := 0 TO 3 DO figureField[y, 3] := ChEmpty END
  END;
  figW := 4;
  WHILE (figW > 0) & IsFigColEmpty(figW - 1) DO figW := figW - 1 END;
  figH := 4;
  WHILE (figH > 0) & IsFigLineEmpty(figH - 1) DO figH := figH - 1 END;
  IF figW + figX > 10 THEN figX := 10 - figW END
END LoadFigure;

PROCEDURE ReDraw;
  VAR x, y: INTEGER;
      c: BYTE;
BEGIN
  FOR y := 0 TO 19 DO
    SYSTEM.FILL(screen[y + 1, 16], 10, ChDot);
    FOR x := 0 TO 9 DO
      c := field[y, x];
      IF c # ChEmpty THEN screen[y + 1, x + 16] := c END
    END
  END;
  FOR y := 0 TO 3 DO FOR x := 0 TO 3 DO
    c := figureField[y, x];
    IF c # ChEmpty THEN screen[1 + figY + y, 16 + figX + x] := c END
  END END;
  FOR y := 0 TO 2 DO FOR x := 0 TO 3 DO
    IF figures[figN, y * 4 + x] = " " THEN screen[y + 1, x + 29] := ChEmpty
    ELSE screen[y + 1, x + 29] := ChGB END
  END END;
  (* Dirty-cell diff: keep only cells that changed since the previous frame;
     mask the rest with ChSkip so Draw leaves their CGA area untouched.  `prev`
     holds the real (unmasked) rendered value of each cell for next time. *)
  CalcDiff(screen, prev);
  Draw(screen, spr)
END ReDraw;

PROCEDURE CanMoveLeft(): BOOLEAN;
  VAR x, y: INTEGER;
BEGIN
  IF figX = 0 THEN RETURN FALSE END;
  FOR y := 0 TO 3 DO FOR x := 0 TO 3 DO
    IF (figureField[y, x] # ChEmpty)
       & (field[figY + y, figX + x - 1] # ChEmpty) THEN RETURN FALSE END
  END END;
  RETURN TRUE
END CanMoveLeft;

PROCEDURE CanMoveRight(): BOOLEAN;
  VAR x, y: INTEGER;
BEGIN
  IF figX + figW >= 10 THEN RETURN FALSE END;
  FOR y := 0 TO 3 DO FOR x := 0 TO 3 DO
    IF (figureField[y, x] # ChEmpty)
       & (field[figY + y, figX + x + 1] # ChEmpty) THEN RETURN FALSE END
  END END;
  RETURN TRUE
END CanMoveRight;

PROCEDURE CanDoStepDown(): BOOLEAN;
  VAR x, y: INTEGER;
BEGIN
  FOR y := 0 TO 3 DO FOR x := 0 TO 3 DO
    IF (figureField[y, x] # ChEmpty)
       & (field[figY + y + 1, figX + x] # ChEmpty) THEN RETURN FALSE END
  END END;
  RETURN TRUE
END CanDoStepDown;

PROCEDURE FigureMerge;
  VAR x, y: INTEGER;
BEGIN
  FOR y := 0 TO 3 DO FOR x := 0 TO 3 DO
    IF figureField[y, x] # ChEmpty THEN field[figY + y, figX + x] := ChGB END
  END END
END FigureMerge;

PROCEDURE RemoveRows;
  VAR x, y, row: INTEGER;
      candel: BOOLEAN;
BEGIN
  y := 19;
  WHILE y > 0 DO
    candel := TRUE;
    FOR x := 0 TO 9 DO IF field[y, x] = ChEmpty THEN candel := FALSE END END;
    IF candel THEN
      SYSTEM.FILL(field[y, 0], 10, ChFull);
      ReDraw;
      IF ~muted THEN Sound(100) END;
      Delay(200);
      (* Shift rows 0..y-1 down by one into 1..y.  This overlaps downward, so
         SYSTEM.MOVE's forward REP MOVSB would corrupt a single whole-block
         copy (leaving row y still full -> infinite loop, endless beeps).
         Copy row-by-row from the bottom up: each 10-byte row move is
         non-overlapping and the bottom-up order preserves the sources. *)
      FOR row := y - 1 TO 0 BY -1 DO
        SYSTEM.MOVE(field[row, 0], field[row + 1, 0], 10)
      END;
      SYSTEM.FILL(field[0,0], 10, ChEmpty);
      lines := lines + 1;
      (* Speed up every 20 lines: pause is the per-frame gravity delay in
         BIOS ticks (Delay(pause*55) ms).  Derive it from the running line
         count (level = lines DIV 20) so the ramp can't be skipped by a
         multi-line clear, and floor at 1 so the fall never becomes instant. *)
      pause := 7 - (lines DIV 20);
      IF pause < 1 THEN pause := 1 END;
      IF ~muted THEN NoSound END
    ELSE y := y - 1 END
  END
END RemoveRows;

PROCEDURE NextFigure;
BEGIN
  IF ~muted THEN Sound(60) END;
  figA := 0;
  figX := 4;
  figY := 0;
  figI := figN;
  figN := INTEGER(Random.Value(8));
  Delay(50);
  LoadFigure;
  IF ~muted THEN NoSound END
END NextFigure;

PROCEDURE FigureIsDown(): BOOLEAN;
BEGIN RETURN (figY + figH - 1) = 19
END FigureIsDown;

(* HandleKeys: drain every key currently in the buffer.  Called once per
   frame so input stays responsive even though the frame itself is paced by
   a BIOS Delay.  Sets quit/fall via VAR params. *)
PROCEDURE HandleKeys(VAR needRedraw, fall, quit: BOOLEAN);
  VAR key: WORD; keyScan: BYTE;
BEGIN
  WHILE HasKey() DO
    key := GetKey();
    keyScan := Scan(key);
    CASE keyScan OF
      ScEsc:                                              (* quit *)
        quit := TRUE
    | ScLeft:
        IF CanMoveLeft() THEN figX := figX - 1; needRedraw := TRUE END
    | ScRight:
        IF CanMoveRight() THEN figX := figX + 1; needRedraw := TRUE END
    | ScUp:                                               (* rotate clockwise *)
        figA := SYSTEM.AND(figA + 1, 3); LoadFigure; needRedraw := TRUE
    | ScDown:                                             (* rotate counter-cw *)
        figA := SYSTEM.AND(figA - 1, 3); LoadFigure; needRedraw := TRUE
    | ScP:                                                (* pause: block until next key *)
        MkAnimDown(16, 1, 10, 20);
        key := GetKey();
        MkAnimUp(16, 1, 10, 20, ChDot)
    | ScSpace:                                            (* drop *)
        fall := TRUE
    | ScM:                                                (* toggle sound *)
        muted := ~muted
    ELSE
    END
  END
END HandleKeys;

(* WaitStep: wait out one gravity interval (pause ticks ~= pause*55 ms)
   while STAYING responsive -- the wait is sliced into short Delays, and
   between slices keys are handled and the board redrawn.  Returns early if
   the player hard-drops (fall), quits, or a key moved the piece so it must
   be redrawn.  This is what makes controls feel live during the fall. *)
PROCEDURE WaitStep(VAR needRedraw, fall, quit: BOOLEAN);
  CONST Slice = 15;                            (* ms per poll slice *)
  VAR waited, target: WORD;
BEGIN
  target := pause * 55;
  waited := 0;
  WHILE (waited < target) & ~fall & ~quit DO
    HandleKeys(needRedraw, fall, quit);
    IF needRedraw THEN ReDraw; needRedraw := FALSE END;
    Delay(Slice);
    waited := waited + Slice
  END
END WaitStep;

PROCEDURE Game;
  VAR needRedraw: BOOLEAN;
      steps: WORD;
      y : INTEGER;
      fall, quit: BOOLEAN;
BEGIN
  SYSTEM.FILL(field[0,0], 20 * 10, ChEmpty);
  (* Force a full first-frame paint: no cell can match ChSkip, which is never
     a real sprite index, so every cell is treated as changed. *)
  SYSTEM.FILL(prev[0,0], 25 * 40, ChSkip);
  SYSTEM.FILL(screen[0,0], 25 * 40, ChEmpty);
  FOR y := 1 TO 21 DO
    screen[y, 15] := ChVL;
    screen[y, 26] := ChVL
  END;
  SYSTEM.FILL(screen[21, 15], 12, ChHL);
  screen[21, 15] := ChLC;
  screen[21, 26] := ChRC;
  MkAnimUp(16, 1, 10, 20, ChDot);
  muted := FALSE;
  figN := Random.Value(8);
  NextFigure;
  lines := 0;
  pause := 7;
  needRedraw := TRUE;
  steps := 0;
  fall := FALSE;
  quit := FALSE;
  (* One drop per gravity interval.  The interval is spent in WaitStep,
     which polls keys and redraws in small slices so moves/rotations happen
     immediately instead of only once per drop.  Space (fall) skips the wait
     and drops fast. *)
  WHILE ~quit DO
    IF needRedraw THEN ReDraw; needRedraw := FALSE END;
    IF ~CanDoStepDown() OR FigureIsDown() THEN
      HandleKeys(needRedraw, fall, quit);      (* still let keys act at rest *)
      IF ~quit THEN
        IF steps = 0 THEN
          quit := TRUE                         (* new piece can't move: game over *)
        ELSE
          FigureMerge;
          NextFigure;
          RemoveRows;
          steps := 0;
          fall := FALSE;
          needRedraw := TRUE
        END
      END
    ELSE
      IF ~fall THEN WaitStep(needRedraw, fall, quit) END;
      IF ~quit THEN
        IF needRedraw THEN ReDraw; needRedraw := FALSE END;
        IF ~muted THEN Sound(80) END;
        figY := figY + 1;
        needRedraw := TRUE;
        steps := steps + 1;
        IF ~muted THEN NoSound END
      END
    END
  END
END Game;

(* Welcome screen: render "TETRIS" centred on the board in a 3x5 block font
   (3 cells wide, 5 cells tall per glyph, 1 blank cell between letters), each
   letter a random block colour, then wait for any key.  Each glyph is 5 bytes,
   one per row; the low 3 bits of a byte are the 3 columns, bit 2 = leftmost. *)
PROCEDURE Welcome;
  CONST GlyphW = 3; GlyphH = 5; Gap = 1; NLetters = 6;
  VAR font: ARRAY NLetters, GlyphH OF BYTE;
      i, gx, gy, x0, y0, col: INTEGER;
      row: BYTE;
BEGIN
  (* glyph rows: low 3 bits = 3 columns, bit 2 = leftmost pixel *)
  font[0,0]:=07H; font[0,1]:=02H; font[0,2]:=02H; font[0,3]:=02H; font[0,4]:=02H; (* T *)
  font[1,0]:=07H; font[1,1]:=04H; font[1,2]:=06H; font[1,3]:=04H; font[1,4]:=07H; (* E *)
  font[2,0]:=07H; font[2,1]:=02H; font[2,2]:=02H; font[2,3]:=02H; font[2,4]:=02H; (* T *)
  font[3,0]:=06H; font[3,1]:=05H; font[3,2]:=06H; font[3,3]:=05H; font[3,4]:=05H; (* R *)
  font[4,0]:=07H; font[4,1]:=02H; font[4,2]:=02H; font[4,3]:=02H; font[4,4]:=07H; (* I *)
  font[5,0]:=07H; font[5,1]:=04H; font[5,2]:=07H; font[5,3]:=01H; font[5,4]:=07H; (* S *)
  (* prev is uninitialised before the first Game; force a full paint so no
     title cell is masked away by a stale ChSkip match. *)
  SYSTEM.FILL(prev[0,0], 25 * 40, ChSkip);
  SYSTEM.FILL(screen[0,0], 25 * 40, ChDot);
  FOR gy := 0 TO 24 DO FOR gx := 0 TO 39 DO
          CASE Random.Value(3) OF
          0: col := ChGB;
          | 1: col := ChRB;
          | 2: col := ChFull;
          END;
          screen[gy, gx] := col
  END END;

  SYSTEM.FILL(screen[3, 5], 30, ChDot);
  FOR gy := 4 TO 20 DO SYSTEM.FILL(screen[gy, 3], 34, ChDot) END;
  SYSTEM.FILL(screen[21, 5], 30, ChDot);

  (* total width = NLetters glyphs + (NLetters-1) gaps *)
  x0 := (40 - (NLetters * GlyphW + (NLetters - 1) * Gap)) DIV 2;
  y0 := (25 - GlyphH) DIV 2;
  FOR i := 0 TO NLetters - 1 DO
    FOR gy := 0 TO GlyphH - 1 DO
      row := font[i, gy];
      FOR gx := 0 TO GlyphW - 1 DO
        (* bit (GlyphW-1-gx) set -> column gx lit (bit 2 = leftmost) *)
        IF SYSTEM.AND(row, SYSTEM.LSL(1, GlyphW - 1 - gx)) # 0 THEN
          CASE Random.Value(3) OF
          0: col := ChGB;
          | 1: col := ChRB;
          | 2: col := ChFull;
          END;
          screen[y0 + gy, x0 + i * (GlyphW + Gap) + gx] := col
        END
      END
    END
  END;
  CalcDiff(screen, prev);
  Draw(screen, spr);
  WaitKey
END Welcome;

(* --- static data init (runtime does NOT zero/const-init) ---------------- *)

PROCEDURE PutSpr(i: INTEGER; b0,b1,b2,b3,b4,b5,b6,b7,
                            b8,b9,b10,b11,b12,b13,b14,b15: INTEGER);
BEGIN
  spr[i,0]:=b0;  spr[i,1]:=b1;  spr[i,2]:=b2;  spr[i,3]:=b3;
  spr[i,4]:=b4;  spr[i,5]:=b5;  spr[i,6]:=b6;  spr[i,7]:=b7;
  spr[i,8]:=b8;  spr[i,9]:=b9;  spr[i,10]:=b10;spr[i,11]:=b11;
  spr[i,12]:=b12;spr[i,13]:=b13;spr[i,14]:=b14;spr[i,15]:=b15
END PutSpr;

PROCEDURE InitData;
BEGIN
  (* sprite table (10 x 16 bytes) *)
  PutSpr(0, 000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H);
  PutSpr(1, 0FFH,0FFH,0EAH,0AAH,0EAH,0AAH,0EAH,0AAH,0EAH,0AAH,0EAH,0AAH,0EAH,0AAH,0EAH,0AAH);
  PutSpr(2, 0FFH,0FFH,0D5H,055H,0D5H,055H,0D5H,055H,0D5H,055H,0D5H,055H,0D5H,055H,0D5H,055H);
  PutSpr(3, 000H,000H,03FH,0FFH,03FH,0FFH,03FH,0FFH,03FH,0FFH,03FH,0FFH,03FH,0FFH,03FH,0FFH);
  PutSpr(4, 000H,000H,000H,000H,001H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H,000H);
  PutSpr(5, 003H,030H,003H,030H,003H,030H,003H,030H,003H,030H,003H,030H,003H,030H,003H,030H);
  PutSpr(6, 000H,000H,000H,000H,0FFH,0FFH,000H,000H,0FFH,0FFH,000H,000H,000H,000H,000H,000H);
  PutSpr(7, 003H,030H,003H,030H,003H,03FH,003H,000H,003H,0FFH,000H,000H,000H,000H,000H,000H);
  PutSpr(8, 003H,030H,003H,030H,0FFH,030H,000H,030H,0FFH,0F0H,000H,000H,000H,000H,000H,000H);
  PutSpr(9, 0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH,0FFH);

  (* figure shapes (8 x 12 chars) *)
  figures[0] := "  *  ***    ";
  figures[1] := " ***  *     ";
  figures[2] := "****        ";
  figures[3] := " **   **    ";
  figures[4] := "**   **     ";
  figures[5] := "**  **      ";
  figures[6] := "    ***   * ";
  figures[7] := "  * ***     "
END InitData;

PROCEDURE Run*;
BEGIN
  InitData;
  GraphMode;
  Welcome;
  MkAnimDown(0, 0, 40, 25);
  Game;
  MkAnimDown(16, 1, 10, 20);
  MkAnimUp(0, 0, 40, 25, ChEmpty);
  TextMode;
  SYSTEM.Halt(0)
END Run;

END Tetris.
