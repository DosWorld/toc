(*$R-*)(*$D-*)
MODULE Math;
(*
  8087-based math primitives, implemented as INLINE byte patterns.

  Each procedure receives its REAL argument on the CPU stack (caller
  emitted FSTP dword [BX] to push the float).  The body must:
    1. Load the input from the stack into ST(0)
    2. Compute the result
    3. Balance the stack (ADD SP, 4)
    4. Leave the result in ST(0) for REAL/LONGREAL return, or AX for INTEGER

  All sequences are pure 8087 — no 287+ instructions.

  Procedures NOT implemented here (require multi-step tricks beyond what
  fits in a single inline block): Sin, Cos (need range-reduced FPTAN with
  octant tracking), Exp, Ln (need F2XM1/FYL2X with range reduction), Frac
  (Int + subtract).

  Tan and ArcTan ARE implemented but with restrictions on strict 8087:
    Tan(x)    only valid for |x| < pi/4
    ArcTan(x) handles the full real line via the identity
              arctan(x) = pi/2 - arctan(1/x) for |x| > 1, and a sign flip.
*)

VAR
  PI : REAL;

(*
  Abs(x): |x|
  FABS clears the sign bit of ST(0).

  Inline:
    MOV BX, SP            89 E3
    SS: FLD dword [BX]    36 D9 07
    FABS                  D9 E1
    ADD SP, 4             83 C4 04
*)
PROCEDURE Abs*(x: REAL): REAL;
  INLINE(089H, 0E3H, 036H, 0D9H, 007H, 0D9H, 0E1H, 083H, 0C4H, 004H);

(*
  Sqr(x): x*x
  Use FMUL ST(0), ST(0) (D8 C8) to square in place.

  Inline:
    MOV BX, SP            89 E3
    SS: FLD dword [BX]    36 D9 07
    FMUL ST(0), ST(0)     D8 C8
    ADD SP, 4             83 C4 04
*)
PROCEDURE Sqr*(x: REAL): REAL;
  INLINE(089H, 0E3H, 036H, 0D9H, 007H, 0D8H, 0C8H, 083H, 0C4H, 004H);

(*
  Sqrt(x): sqrt(x)
  FSQRT computes the square root of ST(0) in place.
  Result is +inf or NaN for x < 0 (8087 raises IE).

  Inline:
    MOV BX, SP            89 E3
    SS: FLD dword [BX]    36 D9 07
    FSQRT                 D9 FA
    ADD SP, 4             83 C4 04
*)
PROCEDURE Sqrt*(x: REAL): REAL;
  INLINE(089H, 0E3H, 036H, 0D9H, 007H, 0D9H, 0FAH, 083H, 0C4H, 004H);

(*
  Round(x): nearest INTEGER (banker's rounding under 8087 default CW)
  Loads x into ST(0), then FISTP word stores the rounded integer using
  whatever rounding mode is currently active.  The 8087 default CW has
  RC=00 (round to nearest even), matching Oberon's ENTIER/ROUND semantics
  closely enough for typical use.

  The 2-byte int output reuses the low word of the 4-byte input slot;
  the upper 2 bytes are left untouched and discarded by ADD SP, 4.

  Inline:
    MOV BX, SP            89 E3
    SS: FLD dword [BX]    36 D9 07
    SS: FISTP word [BX]   36 DF 1F
    SS: MOV AX, [BX]      36 8B 07
    ADD SP, 4             83 C4 04
*)
PROCEDURE Round*(x: REAL): INTEGER;
  INLINE(089H, 0E3H, 036H, 0D9H, 007H, 036H, 0DFH, 01FH, 036H, 08BH, 007H, 083H, 0C4H, 004H);

(*
  Trunc(x): truncate toward zero, return INTEGER.
  8087 has no truncating-store opcode; we temporarily switch the FPU
  rounding mode to RC=11 (toward zero) around FISTP, then restore.

  Stack layout during the body:
    on entry:           [BX+0..3] = input REAL (4 bytes)
    after SUB SP,4:     [BX+0..1] = saved CW
                        [BX+2..3] = new CW (RC=11)
                        [BX+4..7] = input REAL
    FISTP overwrites    [BX+4..5] with the result word
    ADD SP, 8 cleans both regions.

  Inline:
    SUB SP, 4             83 EC 04          (alloc CW save area)
    MOV BX, SP            89 E3
    SS: FSTCW [BX]        36 D9 3F          (save current CW at [BX+0..1])
    SS: MOV AX, [BX]      36 8B 07
    OR  AX, 0C00H         0D 00 0C          (set RC=11)
    SS: MOV [BX+2], AX    36 89 47 02       (write new CW)
    SS: FLDCW [BX+2]      36 D9 6F 02       (activate truncation mode)
    SS: FLD dword [BX+4]  36 D9 47 04       (load input REAL)
    SS: FISTP word [BX+4] 36 DF 5F 04       (truncate, store as word)
    SS: FLDCW [BX]        36 D9 2F          (restore CW)
    SS: MOV AX, [BX+4]    36 8B 47 04       (get integer result)
    ADD SP, 8             83 C4 08          (release CW area + input)
*)
PROCEDURE Trunc*(x: REAL): INTEGER;
  INLINE(083H, 0ECH, 004H, 089H, 0E3H,
         036H, 0D9H, 03FH,
         036H, 08BH, 007H,
         00DH, 000H, 00CH,
         036H, 089H, 047H, 002H,
         036H, 0D9H, 06FH, 002H,
         036H, 0D9H, 047H, 004H,
         036H, 0DFH, 05FH, 004H,
         036H, 0D9H, 02FH,
         036H, 08BH, 047H, 004H,
         083H, 0C4H, 008H);

(*
  Int(x): truncate toward zero, return REAL.
  Same control-word trick as Trunc, but use FRNDINT to keep the result
  on the FPU stack (no FISTP, no AX).

  Inline:
    SUB SP, 4             83 EC 04         (alloc CW save area)
    MOV BX, SP            89 E3
    SS: FSTCW [BX]        36 D9 3F         (save current CW)
    SS: MOV AX, [BX]      36 8B 07
    OR  AX, 0C00H         0D 00 0C         (RC=11)
    SS: MOV [BX+2], AX    36 89 47 02
    SS: FLDCW [BX+2]      36 D9 6F 02
    SS: FLD dword [BX+4]  36 D9 47 04      (load REAL)
    FRNDINT               D9 FC            (truncate, stays in ST(0))
    SS: FLDCW [BX]        36 D9 2F         (restore CW)
    ADD SP, 8             83 C4 08         (release CW + input)
*)
(*
  Tan(x): tan(x), for |x| < pi/4 on a strict 8087.
  8087 FPTAN: takes ST(0), replaces it with tan(ST(0)), then pushes 1.0
  on top — so the tangent ends up in ST(1) and ST(0) = 1.0.  We pop the
  1.0 with FSTP ST(0) (DD D8) to leave the tangent at ST(0).

  Inline:
    MOV BX, SP            89 E3
    SS: FLD dword [BX]    36 D9 07        (load x into ST(0))
    FPTAN                 D9 F2           (ST(0)=1.0, ST(1)=tan(x))
    FSTP ST(0)            DD D8           (pop the 1.0; ST(0)=tan(x))
    ADD SP, 4             83 C4 04
*)
PROCEDURE Tan*(x: REAL): REAL;
  INLINE(089H, 0E3H, 036H, 0D9H, 007H, 0D9H, 0F2H, 0DDH, 0D8H, 083H, 0C4H, 004H);

PROCEDURE Int*(x: REAL): REAL;
  INLINE(083H, 0ECH, 004H, 089H, 0E3H,
         036H, 0D9H, 03FH,
         036H, 08BH, 007H,
         00DH, 000H, 00CH,
         036H, 089H, 047H, 002H,
         036H, 0D9H, 06FH, 002H,
         036H, 0D9H, 047H, 004H,
         0D9H, 0FCH,
         036H, 0D9H, 02FH,
         083H, 0C4H, 008H);

(*
  ArcTan(x): arctan(x), the inverse tangent, valid for any REAL x.

  8087 FPATAN computes arctan(ST(1)/ST(0)) but only when
    0 <= ST(1) <= ST(0).
  To cover the full range we use:
    a) sign symmetry: arctan(-x) = -arctan(x)
    b) reciprocal identity: for |x| > 1,
         arctan(x) = pi/2 - arctan(1/x).

  Algorithm:
    1. Save the original x (for the final sign flip).
    2. Compute |x| and compare to 1.
    3. If |x| <= 1: feed (ST(1)=|x|, ST(0)=1) to FPATAN → arctan(|x|).
       Else:        feed (ST(1)=1, ST(0)=|x|) to FPATAN → arctan(1/|x|),
                    then subtract from pi/2.
    4. Flip sign if the original x was negative.

  pi/2 is built as FLDPI then FSCALE by -1 (multiply by 2^-1).

  Inline byte map (offsets shown so the rel8 jump targets line up):

    00:  89 E3            MOV BX, SP
    02:  36 D9 07         SS: FLD dword [BX]      ST0 = x
    05:  D9 C0            FLD ST(0)               ST0 = x, ST1 = x  (save)
    07:  D9 E1            FABS                    ST0 = |x|
    09:  D9 E8            FLD1                    ST0 = 1, ST1 = |x|, ST2 = x
    11:  D8 D1            FCOM ST(1)              compare 1 vs |x|
    13:  DF E0            FSTSW AX
    15:  9E               SAHF                    CF = 1 iff 1 < |x|
    16:  73 16            JNB +22 → 40 (le_one branch when |x| <= 1)
    18:  D9 C9            FXCH ST(1)              |x|>1: ST0=|x|, ST1=1
    20:  D9 F3            FPATAN                  arctan(1/|x|); pops; ST0=atan
    22:  D9 EB            FLDPI                   ST0=pi, ST1=atan
    24:  D9 E8            FLD1                    ST0=1, ST1=pi, ST2=atan
    26:  D9 E0            FCHS                    ST0=-1
    28:  D9 C9            FXCH ST(1)              ST0=pi, ST1=-1
    30:  D9 FD            FSCALE                  ST0=pi*2^-1 = pi/2, ST1=-1
    32:  DD D9            FSTP ST(1)              drop -1; ST0=pi/2, ST1=atan
    34:  D8 E1            FSUB ST, ST(1)          ST0 = pi/2 - atan
    36:  DD D9            FSTP ST(1)              drop atan slot; ST0=result, ST1=x
    38:  EB 02            JMP +2 → 42 (do_sign)
    40:  D9 F3            FPATAN  (le_one)        arctan(|x|/1); ST0=atan, ST1=x
    42:  D9 C9            FXCH ST(1)  (do_sign)   ST0=x, ST1=|result|
    44:  D9 E4            FTST                    set flags from x
    46:  DF E0            FSTSW AX
    48:  DD D8            FSTP ST(0)              drop x; ST0=|result|
    50:  9E               SAHF                    CF=1 iff x < 0
    51:  73 02            JNB +2 → 55 (done)
    53:  D9 E0            FCHS                    negate result
    55:  83 C4 04         ADD SP, 4               (done)  pop input REAL
*)
PROCEDURE ArcTan*(x: REAL): REAL;
  INLINE(089H, 0E3H,
         036H, 0D9H, 007H,
         0D9H, 0C0H,
         0D9H, 0E1H,
         0D9H, 0E8H,
         0D8H, 0D1H,
         0DFH, 0E0H,
         09EH,
         073H, 016H,
         0D9H, 0C9H,
         0D9H, 0F3H,
         0D9H, 0EBH,
         0D9H, 0E8H,
         0D9H, 0E0H,
         0D9H, 0C9H,
         0D9H, 0FDH,
         0DDH, 0D9H,
         0D8H, 0E1H,
         0DDH, 0D9H,
         0EBH, 002H,
         0D9H, 0F3H,
         0D9H, 0C9H,
         0D9H, 0E4H,
         0DFH, 0E0H,
         0DDH, 0D8H,
         09EH,
         073H, 002H,
         0D9H, 0E0H,
         083H, 0C4H, 004H);

PROCEDURE Mod(x, y : REAL) : REAL;
VAR n : REAL;
BEGIN
    IF y = 0.0 THEN RETURN 0.0 END;
    n := x / y;
    RETURN x - Int(n) * y
END Mod;

PROCEDURE Sin*(x: REAL): REAL;
VAR twoPi, xr, sign, t: REAL;
BEGIN
    twoPi := 2.0 * PI;
    xr := Mod(x, twoPi);
    IF xr < 0.0 THEN
        xr := xr + twoPi
    END;
    sign := 1.0;
    IF xr > PI THEN
        sign := -1.0;
        xr := twoPi - xr   (* sin(2pi - x) = -sin x *)
    END;
    IF xr > PI / 2.0 THEN
        xr := PI - xr      (* sin(pi - x) = sin x *)
    END;
    t := Tan(xr / 2.0);
    RETURN sign * (2.0 * t) / (1.0 + Sqr(t))
END Sin;

PROCEDURE Cos*(x: REAL): REAL;
BEGIN
    RETURN Sin(PI / 2.0 - x)
END Cos;

PROCEDURE ArcSin*(x: REAL): REAL;
BEGIN
    IF (x < -1.0) OR (x > 1.0) THEN
	RETURN 0.0
    END;
    IF x = 1.0 THEN
        RETURN PI / 2.0
    END;
    IF x = -1.0 THEN
        RETURN -PI / 2.0
    END;
    (* arcsin x = arctan( x / sqrt(1 - x^2) ) *)
    RETURN ArcTan(x / Sqrt(1.0 - Sqr(x)))
END ArcSin;

PROCEDURE ArcCos*(x: REAL): REAL;
BEGIN
    IF (x < -1.0) OR (x > 1.0) THEN
        RETURN 0.0
    END;
    RETURN PI / 2.0 - ArcSin(x)
END ArcCos;

BEGIN
    PI := 4.0 * ArcTan(1.0);
END Math.
