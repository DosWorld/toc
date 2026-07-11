(*D+*)
MODULE StrTab;
(*
  Interned string table (opt.md §12 Layer 1).

  Every identifier/name in the symbol table is stored here exactly once; a
  name is identified by a WORD id (1-based; 0 = "no string").  Two names are
  equal iff their ids are equal, so symbol lookup is a WORD compare — no
  string comparison, no hash pre-filter file.

  Storage is RAM-resident and chunked:
    - text chunks: the name characters, 0X-terminated, appended densely;
    - entry chunks: per id {hash, text chunk#, text ofs, hash-chain next};
    - 256 hash buckets of id heads for Intern/Find.
  All chunks are DISPOSEd by Reset (zero-leak rule); the module body performs
  the raw first-time init explicitly (the runtime does NOT zero globals).
*)
IMPORT Strings, LogErr;

CONST
  TextSize = 8*1024; (* chars per text chunk *)
  MaxText  = 24;      (* up to 192 KB of distinct name text *)
  EntBits  = 8;
  EntPer   = 256;     (* entries per entry chunk (2 KB/chunk) *)
  MaxEnt   = 32;      (* up to 8192 distinct names *)
  Buckets  = 256;

TYPE
  TextChunk = POINTER TO TextChunkDesc;
  TextChunkDesc = RECORD
    ch: ARRAY TextSize OF CHAR
  END;

  EntRec = RECORD
    hash:   WORD;     (* Strings.HashCode of the name *)
    tchunk: INTEGER;  (* index into textDir *)
    tofs:   WORD;     (* offset of the 0X-terminated text in that chunk *)
    hnext:  WORD      (* next id in the same hash bucket; 0 = end *)
  END;

  EntChunk = POINTER TO EntChunkDesc;
  EntChunkDesc = RECORD
    e: ARRAY EntPer OF EntRec
  END;

VAR
  textDir:  ARRAY MaxText OF TextChunk;
  entDir:   ARRAY MaxEnt OF EntChunk;
  nText:    INTEGER;   (* text chunks allocated *)
  textUsed: WORD;      (* used chars in textDir[nText-1] *)
  count:    WORD;      (* ids issued: 1..count *)
  buckets:  ARRAY Buckets OF WORD;
  bi:       INTEGER;   (* module-body init loop counter *)

PROCEDURE Count*(): WORD;
BEGIN
  RETURN count
END Count;

(* Heap bytes currently allocated by the table (text chunks + entry chunks);
   for Syms.StatsDump reporting. *)
PROCEDURE MemBytes*(): LONGINT;
  VAR nEnt: INTEGER;
BEGIN
  nEnt := INTEGER(SYSTEM.LSR(count + WORD(EntPer - 1), EntBits));
  RETURN LONGINT(nText) * LONGINT(TextSize) +
         LONGINT(nEnt) * LONGINT(SIZE(EntChunkDesc))
END MemBytes;

(* Copy the text of id into dst (id 0 or out of range -> empty string). *)
PROCEDURE Get*(id: WORD; VAR dst: ARRAY OF CHAR);
  VAR ec: EntChunk; tc: TextChunk; k, o: WORD; i: INTEGER;
BEGIN
  IF (id = 0) OR (id > count) THEN dst[0] := 0X; RETURN END;
  ec := entDir[SYSTEM.LSR(id - 1, EntBits)];
  k  := SYSTEM.AND(id - 1, EntPer - 1);
  tc := textDir[ec^.e[k].tchunk];
  o  := ec^.e[k].tofs;
  i  := 0;
  WHILE (tc^.ch[o] # 0X) & (i < LEN(dst) - 1) DO
    dst[i] := tc^.ch[o]; INC(i); INC(o)
  END;
  dst[i] := 0X
END Get;

(* Bucket-chain lookup with the hash already computed. *)
PROCEDURE FindH(VAR name: ARRAY OF CHAR; h: WORD): WORD;
  VAR lenh, id, k: WORD; ec: EntChunk; tc: TextChunk;
BEGIN
  id := buckets[SYSTEM.AND(h, Buckets - 1)];
  lenh := SYSTEM.LENGTH(name) + 1;
  WHILE id # 0 DO
    ec := entDir[SYSTEM.LSR(id - 1, EntBits)];
    k  := SYSTEM.AND(id - 1, EntPer - 1);
    IF ec^.e[k].hash = h THEN
      tc := textDir[ec^.e[k].tchunk];
      IF SYSTEM.COMPARE(name[0], tc^.ch[ec^.e[k].tofs],
                        lenh) THEN
        RETURN id
      END
    END;
    id := ec^.e[k].hnext
  END;
  RETURN 0
END FindH;

(* Id of name, or 0 when the name was never interned (=> cannot be any
   symbol's name).  Never allocates. *)
PROCEDURE Find*(VAR name: ARRAY OF CHAR): WORD;
BEGIN
  RETURN FindH(name, Strings.HashCode(name))
END Find;

(* Id of name, interning it on first sight.  `name` is BY VALUE on purpose:
   Intern is called with string LITERALS ("SYSTEM", "INTEGER", ...). *)
PROCEDURE Intern*(name: ARRAY OF CHAR): WORD;
  VAR h, id, k, b: WORD; len: INTEGER; tc: TextChunk; ec: EntChunk;
BEGIN
  h  := Strings.HashCode(name);
  id := FindH(name, h);
  IF id # 0 THEN RETURN id END;

  len := Strings.Length(name);
  (* text space (fresh chunk when the current one cannot hold len+1 chars) *)
  IF (nText = 0) OR (WORD(len) + 1 > WORD(TextSize) - textUsed) THEN
    IF nText >= MaxText THEN
      LogErr.Error("StrTab: name text overflow"); RETURN 0
    END;
    NEW(textDir[nText]);
    IF textDir[nText] = NIL THEN
      LogErr.Error("StrTab: out of memory (text)"); RETURN 0
    END;
    INC(nText); textUsed := 0
  END;
  (* entry slot (fresh entry chunk every EntPer ids) *)
  IF SYSTEM.AND(count, EntPer - 1) = 0 THEN
    k := SYSTEM.LSR(count, EntBits);
    IF k >= WORD(MaxEnt) THEN
      LogErr.Error("StrTab: too many names"); RETURN 0
    END;
    NEW(entDir[k]);
    IF entDir[k] = NIL THEN
      LogErr.Error("StrTab: out of memory (entries)"); RETURN 0
    END
  END;

  INC(count); id := count;
  tc := textDir[nText - 1];
  SYSTEM.MOVE(name[0], tc^.ch[textUsed], WORD(len + 1));
  ec := entDir[SYSTEM.LSR(id - 1, EntBits)];
  k  := SYSTEM.AND(id - 1, EntPer - 1);
  ec^.e[k].hash   := h;
  ec^.e[k].tchunk := nText - 1;
  ec^.e[k].tofs   := textUsed;
  b := SYSTEM.AND(h, Buckets - 1);
  ec^.e[k].hnext := buckets[b];
  buckets[b] := id;
  INC(textUsed, WORD(len + 1));
  RETURN id
END Intern;

(* Release every chunk and empty the table (all ids become invalid).
   Called by Syms.OpenStores (fresh table per compile) and Syms.SymsFree
   (zero-leak rule: every chunk DISPOSEd). *)
PROCEDURE Reset*;
  VAR k: INTEGER;
BEGIN
  k := 0;
  WHILE k < MaxText DO
    IF textDir[k] # NIL THEN DISPOSE(textDir[k]); textDir[k] := NIL END;
    INC(k)
  END;
  k := 0;
  WHILE k < MaxEnt DO
    IF entDir[k] # NIL THEN DISPOSE(entDir[k]); entDir[k] := NIL END;
    INC(k)
  END;
  k := 0;
  WHILE k < Buckets DO buckets[k] := 0; INC(k) END;
  nText := 0; textUsed := 0; count := 0
END Reset;

BEGIN
  (* raw first-time init — the runtime does NOT zero module globals *)
  nText := 0; textUsed := 0; count := 0;
  bi := 0; WHILE bi < MaxText  DO textDir[bi] := NIL; INC(bi) END;
  bi := 0; WHILE bi < MaxEnt   DO entDir[bi]  := NIL; INC(bi) END;
  bi := 0; WHILE bi < Buckets  DO buckets[bi] := 0;   INC(bi) END
END StrTab.
