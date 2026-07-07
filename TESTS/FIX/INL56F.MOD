MODULE Inl56f;
VAR gval: INTEGER;
PROCEDURE LoadWord*(VAR x: INTEGER): INTEGER;
  INLINE(08BH, 006H, x);
PROCEDURE StoreWord*(VAR x: INTEGER);
  INLINE(089H, 006H, x);
PROCEDURE Test*;
VAR n: INTEGER;
BEGIN
  gval := 123;
  n := LoadWord(gval);
  StoreWord(gval);
END Test;
END Inl56f.
