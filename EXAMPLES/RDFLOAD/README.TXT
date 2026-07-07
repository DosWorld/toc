# RDFLOAD Example for Oberon.

This example shows how to load an RDF as an external dynamic library
and call an exported RDF procedure.

  MAIN.MOD   - host that loads TEST.RDF and calls its print_msg
  TEST.ASM   - NASM source for TEST.RDF; defines print_msg ("Hello world")
  RDFLOAD.MOD - copy of src-lib/RdfLoad.mod, the loader

The loader (`RdfLoad` module in src-lib) supports:

* `LoadLibrary(fileName)`       — open an RDF and resolve IMPORTs against
                                  the built-in table (SYSTEM, Files, Strings).
                                  Use this when the RDF only depends on the
                                  standard runtime.

* `LoadLibraryWith(fileName, resolver)` — same, but tries the caller's
                                  resolver FIRST, then falls back to the
                                  built-in table.  Use this when the RDF
                                  imports symbols your host owns
                                  (application-specific procedures).

* `GetProcAddress(module, name)` — fetch an exported (GLOBAL) symbol's
                                   far address.  Returns NIL if not found.

* `FreeLibrary(module)`         — release heap blocks and the linked
                                   exports/imports lists.

## How import resolution works

When an RDF emits a `CALL FAR Sym` it leaves both the offset and segment
words of the `9A imm:imm` instruction as placeholders, and writes a RELOC
record (offset word) + SEGRELOC record (segment word) referring to a
unique IMPORT ID.  RdfLoad parses every IMPORT record in pass 1, calls
the resolver (user-supplied first, then the built-in table) to map each
name to a far address, and stores the result in `mod.imports`.  In pass 2
when ApplyRecords sees a RELOC/SEGRELOC with `RSEG > 2` it looks up the
import id and patches the placeholder bytes with the resolved address —
its low word for RELOC, its high word for SEGRELOC.

Unresolved imports leave the placeholders at zero, so the call jumps to
0000:0000 at runtime.

## Built-in resolver table

`BuiltinResolve` handles all FAR procedures from the SYSTEM,
Files, and Strings runtime modules — i.e. every symbol the compiler emits
as an implicit import for these modules.  See `RDFLOAD.MOD` for the
complete list.

## Building TEST.RDF

NASM 2.x (with `-f rdf`) used to ship with the RDOFF object writer.
Recent releases (3.x) dropped it.  The bundled TEST.RDF was built with an
older NASM; the corresponding TEST.ASM is included so the source matches.
