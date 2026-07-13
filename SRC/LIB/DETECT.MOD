MODULE Detect;

CONST
CPU86*  = 0;
CPU286* = 1;
CPU386* = 2;

(* IsEga returns TRUE if an EGA or later video adapter is installed.
   No parameters. Uses INT 10h AH=12h BL=10h (get EGA info); if the
   returned CX (feature bits) is 0FFFFh before the probe, INC CX wraps to
   0 -- no EGA/VGA present -- so the result is FALSE. *)
PROCEDURE IsEga* : BOOLEAN; EXTERNAL;

(* IsVga returns TRUE if a VGA adapter is installed.
   No parameters. Uses INT 10h AX=1A00h (get display combination code);
   requires AL=1Ah on return (function supported) and BL in [7..0FEh]
   (a recognized VGA-class active-display code). *)
PROCEDURE IsVga* : BOOLEAN; EXTERNAL;

(* IsMonochrome returns TRUE if the current video mode is monochrome.
   No parameters. Reads the BIOS data area byte at 0040h:0065h (current
   video mode / CRT_MODE_SET) and tests bit 2. *)
PROCEDURE IsMonochrome* : BOOLEAN; EXTERNAL;

(* IsInputRedirected returns TRUE if standard input (handle 0) has been
   redirected from a file or pipe rather than being the console.
   No parameters. Uses INT 21h AX=4400h (IOCTL get device info) on
   handle 0 and tests the device bit (bit 7 clear = file, not device). *)
PROCEDURE IsInputRedirected* : BOOLEAN; EXTERNAL;

(* IsOutputRedirected returns TRUE if standard output (handle 1) has been
   redirected to a file or pipe rather than being the console.
   No parameters. Uses INT 21h AX=4400h (IOCTL get device info) on
   handle 1, same test as IsInputRedirected. *)
PROCEDURE IsOutputRedirected* : BOOLEAN; EXTERNAL;

(* IsAnsiSys returns TRUE if an ANSI.SYS-compatible console driver is
   loaded (so ANSI escape sequences written to the console will be
   interpreted). No parameters. Uses INT 2Fh AX=1A00h (ANSI.SYS
   installation check); TRUE iff AL=0FFh on return. *)
PROCEDURE IsAnsiSys* : BOOLEAN; EXTERNAL;

(* IsFreeDos returns TRUE if running under FreeDOS (detected via the
   OEM identifier byte returned by the "set/get DOS version" call).
   No parameters. Uses INT 21h AX=3000h with BX=0 (request OEM ID in
   BH); TRUE iff BH=0FDh (FreeDOS's registered OEM ID). *)
PROCEDURE IsFreeDos* : BOOLEAN; EXTERNAL;

(* GetFreeDosVer returns the FreeDOS kernel version as a packed value:
   AX = build/version info, DX = revision (per INT 21h AX=33FFh, FreeDOS's
   extended "get true version" call). No parameters. Returns 0 (both
   words zero) if DX=0 on return, i.e. the call is not supported (not
   running under FreeDOS, or an older kernel). Only meaningful when
   IsFreeDos() is TRUE. *)
PROCEDURE GetFreeDosVer* : SYSTEM.ADDRESS; EXTERNAL;

(* Cpu returns the detected CPU class as one of CPU86/CPU286/CPU386
   (see the CONST declarations above). No parameters. Probes for FLAGS
   bits 12-15 behavior: on 8086/8088/80186/80188 those bits always read
   back as 1 (CPU86); on 80286 bits 12-15 can be cleared but not set
   (CPU286); on 80386+ they can be both set and cleared freely (CPU386).
   Does not distinguish 80386 from later CPUs -- CPU386 is the ceiling. *)
PROCEDURE Cpu* : WORD; EXTERNAL;

(*$L DETECT.RDF*)

(* IsAT returns TRUE if the machine identifies itself as an AT-class (or
   later) system rather than a PC/XT. No parameters. Reads the BIOS ROM
   machine-ID byte at F000h:FFFEh (SYSTEM.PTR builds that far address
   directly, bypassing DS) and tests for 0FCh, the AT/286+ ID byte
   (0FFh/0FEh/0FDh mark the original PC, PC/XT, and PCjr respectively). *)
PROCEDURE IsAT* : BOOLEAN;
VAR p : SYSTEM.ADDRESS;
BEGIN
  p := SYSTEM.PTR(0F000H, 0FFFEH);
  RETURN p^ = 0FCX;
END IsAT;

END Detect.
