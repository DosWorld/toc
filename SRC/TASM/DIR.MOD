MODULE Dir;
(*
  TASM directive handling: BITS/CPU/SECTION/GLOBAL/STRUC/ENDSTRUC/
  %DEFINE/%UNDEF/%IFDEF/%ELSE/%ENDIF/DB/DW/TIMES.

  STRUC/ENDSTRUC field offsets and the computed NAME_size constant are
  stored as %define-style text substitutions in Sym (each field access in
  source is written "STRUCNAME.field", e.g. TRegisters._AX or
  MEMHEADER.Prev -- Parse.MOD's operand parser recognizes a
  qualident-shaped token pair "IDENT '.' IDENT" and asks Dir/Sym to resolve
  it to a numeric constant the same way it resolves a %define).
*)
IMPORT Sym, LogErr, Strings;

CONST
  MaxFields = 32;

TYPE
  StrucState* = RECORD
    active*: BOOLEAN;
    name*:   ARRAY Sym.MaxName OF CHAR;
    ofs*:    LONGINT
  END;

VAR
  curStruc: StrucState;

PROCEDURE Init*;
BEGIN curStruc.active := FALSE
END Init;

PROCEDURE InStruc*(): BOOLEAN;
BEGIN RETURN curStruc.active
END InStruc;

PROCEDURE BeginStruc*(name: ARRAY OF CHAR; fname: ARRAY OF CHAR; line: LONGINT);
BEGIN
  IF curStruc.active THEN
    LogErr.ErrorInFile(fname, line, "nested STRUC not supported"); RETURN
  END;
  curStruc.active := TRUE;
  Strings.Copy(name, curStruc.name);
  curStruc.ofs := LONGINT(0)
END BeginStruc;

(* AddField: field is stored as a %define "STRUCNAME.field" -> decimal
   offset text, so Parse.MOD's existing %define-expansion lookup resolves
   "STRUCNAME.field" tokens (scanned as IDENT DOT IDENT, rejoined by
   Parse.MOD before the Sym.Expand lookup) transparently, without ENC.MOD
   or Parse.MOD needing a second lookup mechanism. size is in bytes
   (resb=1, resw=2, resd=4) times count. *)
PROCEDURE AddField*(field: ARRAY OF CHAR; sizeBytes, count: LONGINT; fname: ARRAY OF CHAR; line: LONGINT);
  VAR key: ARRAY 80 OF CHAR; val: ARRAY 16 OF CHAR;
BEGIN
  IF ~curStruc.active THEN
    LogErr.ErrorInFile(fname, line, "field declaration outside STRUC"); RETURN
  END;
  Strings.Copy(curStruc.name, key);
  Strings.Append(".", key);
  Strings.Append(field, key);
  Strings.Str(curStruc.ofs, val);
  Sym.Define(key, val);
  curStruc.ofs := curStruc.ofs + sizeBytes * count
END AddField;

(* Upper: uppercase a string in place (ASCII a..z only) -- used only for
   the STRUCNAME_size key below, to match how it's actually looked up. *)
PROCEDURE Upper(VAR s: ARRAY OF CHAR);
  VAR i: INTEGER;
BEGIN
  i := 0;
  WHILE s[i] # 0X DO s[i] := SYSTEM.UCASE(s[i]); INC(i) END
END Upper;

(* EndStruc: define STRUCNAME_size = total byte size.  Unlike AddField's
   "STRUCT.field" keys (only ever looked up via TryResolveField using
   original case, consistently on both sides), STRUCNAME_size is used as
   a BARE identifier in source (e.g. "mov cx, TPoint_size") and resolved
   by Parse.MOD's TokNext via the generic Sym.Expand(tId, ...) path, which
   always looks up the UPPERCASED scanned identifier -- so the key must be
   stored uppercase here too, or the two never match (found via a real
   TESTS/FIX/TSTRUC.ASM fixture: "TPoint_size" stored mixed-case, looked
   up as "TPOINT_SIZE", silently resolved to 0 instead of erroring). *)
PROCEDURE EndStruc*(fname: ARRAY OF CHAR; line: LONGINT);
  VAR key: ARRAY 80 OF CHAR; val: ARRAY 16 OF CHAR;
BEGIN
  IF ~curStruc.active THEN
    LogErr.ErrorInFile(fname, line, "ENDSTRUC without STRUC"); RETURN
  END;
  Strings.Copy(curStruc.name, key);
  Strings.Append("_size", key);
  Upper(key);
  Strings.Str(curStruc.ofs, val);
  Sym.Define(key, val);
  curStruc.active := FALSE
END EndStruc;

(* ParseDecimal: minimal unsigned-decimal parser for the digit strings
   this module itself wrote via Strings.Str (AddField/EndStruc) -- never
   needs to handle hex/sign, so it stays deliberately simple rather than
   reusing Strings.Val's typeless-VAR pointer-walking signature. *)
PROCEDURE ParseDecimal(s: ARRAY OF CHAR): LONGINT;
  VAR i: INTEGER; v: LONGINT;
BEGIN
  v := LONGINT(0); i := 0;
  WHILE (s[i] >= "0") & (s[i] <= "9") DO
    v := v * 10 + LONGINT(ORD(s[i]) - ORD("0")); INC(i)
  END;
  RETURN v
END ParseDecimal;

(* TryResolveField: "NAME.field" as a single dotted token pair -- looks up
   the %define Sym.Define stored by AddField/EndStruc.  Returns TRUE and
   the numeric value if found. *)
PROCEDURE TryResolveField*(structName, field: ARRAY OF CHAR; VAR value: LONGINT): BOOLEAN;
  VAR key: ARRAY 80 OF CHAR; val: ARRAY 16 OF CHAR;
BEGIN
  Strings.Copy(structName, key);
  Strings.Append(".", key);
  Strings.Append(field, key);
  IF Sym.Expand(key, val) THEN
    value := ParseDecimal(val);
    RETURN TRUE
  END;
  RETURN FALSE
END TryResolveField;

END Dir.
