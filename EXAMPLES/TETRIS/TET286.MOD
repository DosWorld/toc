(*$D-*)(*
  Tetris for CGA (mode 4, 320x200 4-colour)

  The game logic is pure Oberon.  Only the per-frame CGA sprite blitter is
  in assembly (TETRIS.ASM -> TETRIS.RDF, linked via the $L directive).

  Controls: Left/Right = move, Up/Down = rotate, Space = drop,
            P = pause, M = toggle sound, Esc = quit.

  Now, I (and you) saw something new: cga-camo.
*)
MODULE Tet286;

IMPORT Tetris;

PROCEDURE Run*;
BEGIN
  Tetris.Run;
END Run;

END Tet286.
