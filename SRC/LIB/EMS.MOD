(*$D-*)
MODULE EMS;

CONST
  VER35* = 035H;
  VER40* = 040H;

(* Present: test whether a LIM EMS 4.0 driver was detected at module init.
   Result: TRUE if an EMM driver is present and a page frame was obtained. *)
PROCEDURE Present*(): BOOLEAN; EXTERNAL;
(* GetError: read the LIM EMS error code from the most recent EMS operation.
   Result: 0 if that operation succeeded, else the driver's AH error code. *)
PROCEDURE GetError*(): WORD; EXTERNAL;
(* Alloc: allocate an EMS handle with at least sizeKB of backing storage
   (rounded up to 16 KB pages).
   Parameters: sizeKB — requested size in kilobytes (0 rounds up to one
   16 KB page); handle — receives the new EMS handle on success.
   Result: TRUE if the allocation succeeded. *)
PROCEDURE Alloc*(sizeKB: WORD; VAR handle: WORD): BOOLEAN; EXTERNAL;
(* Free: release an EMS handle and all its pages.
   Parameters: handle — the EMS handle to free.
   Result: TRUE if the handle was freed successfully. *)
PROCEDURE Free*(handle: WORD): BOOLEAN; EXTERNAL;
(* Realloc: resize an existing EMS handle's backing storage, rounded up to
   16 KB pages.  A no-op (returns TRUE without a driver call) if the new
   size already matches the current page count.
   Parameters: handle — the EMS handle to resize (never changes value: LIM
   EMS reallocation always keeps the same handle); newSizeKB — requested
   new size in kilobytes.
   Result: TRUE if the resize succeeded (or was already the right size). *)
PROCEDURE Realloc*(VAR handle: WORD; newSizeKB: WORD): BOOLEAN; EXTERNAL;
(* CopyToEMS: copy bytes from conventional memory into an EMS handle's
   backing storage (LIM EMS 4.0 Move Memory Region).
   Parameters: dosBuf — source buffer in conventional memory; handle — target
   EMS handle; emsOffset — flat byte offset within the handle's storage to
   copy to; size — number of bytes to copy (0 is a no-op, returns TRUE).
   Result: TRUE if the copy succeeded. *)
PROCEDURE CopyToEMS*(VAR dosBuf; handle: WORD; emsOffset: LONGINT; size: WORD): BOOLEAN; EXTERNAL;
(* CopyToDos: copy bytes from an EMS handle's backing storage into
   conventional memory (LIM EMS 4.0 Move Memory Region).
   Parameters: handle — source EMS handle; emsOffset — flat byte offset
   within the handle's storage to copy from; dosBuf — destination buffer in
   conventional memory; size — number of bytes to copy (0 is a no-op,
   returns TRUE).
   Result: TRUE if the copy succeeded. *)
PROCEDURE CopyToDos*(handle: WORD; emsOffset: LONGINT; VAR dosBuf; size: WORD): BOOLEAN; EXTERNAL;
(* Version: query the EMM driver's version number.
   Result: BCD-encoded version byte (e.g. 40H for version 4.0), or 0 if no
   driver is present or the query failed. *)
PROCEDURE Version*(): BYTE; EXTERNAL;
(* RequireVersion: disable EMS support (as seen by Present) if the detected
   driver's version is below the given minimum.
   Parameters: ver — minimum required BCD-encoded version (see VER35/VER40).
   Result: none. *)
PROCEDURE RequireVersion*(ver: BYTE); EXTERNAL;
(* MapPage: map one 16 KB logical page of an EMS handle into one of the
   page frame's physical window slots, making it addressable via
   conventional memory (LIM EMS 4.0 Map Handle Page).
   Parameters: handle — the EMS handle owning the page; logicalPage —
   0-based logical page number within that handle; physicalPage — which
   page-frame window to map into (0..MaxPhysicalPages-1).
   Result: TRUE if the mapping succeeded. *)
PROCEDURE MapPage*(handle: WORD; logicalPage: WORD; physicalPage: WORD): BOOLEAN; EXTERNAL;
(* UnmapPage: clear one of the page frame's physical window slots.
   Parameters: physicalPage — which page-frame window to unmap
   (0..MaxPhysicalPages-1).
   Result: TRUE if the unmap succeeded. *)
PROCEDURE UnmapPage*(physicalPage: WORD): BOOLEAN; EXTERNAL;
(* MapPtr: map the EMS page containing a given flat offset into a physical
   window and return a conventional-memory pointer to that offset.
   Parameters: handle — the EMS handle; emsOffset — flat byte offset within
   the handle's storage; physWin — which page-frame window to use.
   Result: far pointer usable to read/write that offset directly, or NIL if
   the mapping failed. *)
PROCEDURE MapPtr*(handle: WORD; emsOffset: LONGINT; physWin: WORD): SYSTEM.ADDRESS; EXTERNAL;

PROCEDURE Detect(); FAR; EXTERNAL;

(*$L EMSAPI.RDF*)

BEGIN
  Detect;
END EMS.
