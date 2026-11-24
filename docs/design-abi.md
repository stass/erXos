# ABI declarations and binary readers

This document defines the declaration language, its validated model, and
the byte representations shared by the kernel, `liberx`, runtimes and host
tools. [Generated interfaces](design-generation.md) owns the wider
generation contract; the subsystem designs own the meaning of each call
and record. `abi/erx_abi.txt`, its explicit fragments and the selected
architecture file are the only machine-readable sources; what each file
holds is listed in [Sources and outputs](design-generation.md#sources-and-outputs).
This document says how the language and its readers are shaped and why;
the declarations themselves, every field, offset and value, are in
those files and in the generated reference, never restated here.

## Contract and ownership

The generator has three pure stages: parse source bytes into declarations
with source locations; resolve and validate the complete declaration set;
derive an immutable output plan containing every output path and byte.
Filesystem reads and publication surround these stages. An invalid
declaration produces a diagnostic with its file, line, qualified name and
rule, and publishes nothing. Publication errors fail the command; a
partial publication leaves a tree that fails its stamp, so the next build
regenerates it.

The model describes representation and structural validation. It does not
decide whether to create a domain, admit a grant, transfer authority or
retry a request. Those decisions remain in the subsystem's handwritten
pure core. A structurally valid manifest is not a checked configuration:
the packer obtains bytes to publish only from the complete manifest check.

Generated C readers accept a byte span and return either a validated view
or a typed diagnostic. A view borrows the input, which its owner keeps
immutable for the view's lifetime. No partial view escapes on failure.
The kernel's boot-image view borrows the image that boot protects against
writes. Readers of peer-writable memory instead take one snapshot through
the generated shared-field accessors and validate that snapshot. A
zero-copy view does not make mutable input safe.

## Source grammar

Sources are ASCII, with LF line endings and an optional final LF. A line
is empty, a comment, or a keyword followed by space-separated tokens.
`#` begins a comment outside a quoted string. Indentation is zero, two or
four spaces, according to declaration, member or bit-field depth; tabs and
other indentation fail. Quoted strings admit only `\\`, `\"` and `\xHH`
escapes. A decoded source string remains ASCII; a byte literal is an even
number of hexadecimal digits and can represent arbitrary bytes. No
expression evaluation, interpolation, executable Ruby or implicit include
search exists.

The source reader caps a file at 16 MiB, the resolved input set at
64 MiB and 1,024 files, an include chain at 64 files, and a source line
at 8,192 bytes. It refuses a bound before extending its retained input.
The by-value type graph has at most 64 levels; declarations which exceed
that bound fail before any recursive host codec or emitted nesting runs.
An iterative include walk uses the bounded explicit stack; include depth
does not become host-language recursion. These tooling bounds do not
change any target ABI limit.

Identifiers match `[a-z][a-z0-9_]*` and have at most 63 bytes. A qualified
name has at most 255 bytes and consists of identifiers
separated by `.`; a service member's qualified name includes its service.
The model has one namespace for qualified definitions, with separate
member namespaces inside records and enumerations. Generated symbol names
are derived injectively; two source names that would yield the same C,
Erlang or Ruby name fail validation. Keywords and generated helper names
are reserved in the language that emits them.

Integers are decimal or `0x` hexadecimal, with an optional minus only
where the declaration permits a signed value. There are no suffixes,
arithmetic expressions or implicit numeric assignments. A reference is
`@qualified_name`; references resolve after the complete input is read.
Every keyword has a fixed argument grammar. Duplicate properties, surplus
tokens, unsupported properties and unknown keywords fail.

The root contains exactly one `abi VERSION`. An architecture file begins
with exactly one `arch NAME`. `include PATH` is relative to the containing
file, resolves beneath `abi/`, and names an ordinary source file; absolute
paths, `..`, symlink escapes, repeated inclusion and cycles fail. Neutral
fragments cannot select an architecture or declare architecture bindings.
An architecture file cannot redefine a neutral name. The root explicitly
includes `inspection.txt` and each service fragment it uses; an empty
fragment declares no interface and creates no claim of support.

The declaration forms are:

| Form | Required contents |
| --- | --- |
| `limit NAME TYPE VALUE` | an integer type and a value within it |
| `scalar NAME TYPE` | a fixed-width base integer; optional inclusive `range MIN MAX` and `align POWER_OF_TWO` constraints |
| `enum NAME TYPE` | indented `value NAME INTEGER [ATTRIBUTE...]` members; every value explicit and distinct. Indented `attribute NAME` lines declare the closed set of attributes the member lines may name after their value, each a boolean fact of the members that carry it: a name no `attribute` line declares, a declaration repeated, an attribute named twice on one member, or one no member carries fails the run. Each language gets the member set and a predicate per attribute |
| `flags NAME TYPE` | indented `bit NAME POSITION` members; every position explicit and distinct |
| `bytes NAME LENGTH` | a fixed byte count, with an optional `value HEX_BYTES` constraint |
| `layout NAME STORAGE ALIGN SIZE` | ordered fields; `STORAGE` is `wire_le`, `shared`, `native`, `packed_le` or `packed_be` ([Packed layouts](#packed-layouts)); alignment and fixed prefix size are explicit |
| `elements NAME STORAGE TAG_ENUM LENGTH_TYPE [end MEMBER]` | tag, length and body records repeated to the end of their bytes or an end marker, with indented `element MEMBER REPEAT BODY` members ([Element sequences](#element-sequences)) |
| `variant NAME PREFIX TAG_FIELD TAG_ENUM MAX_BYTES` | a fixed prefix containing the tag and indented `case TAG BODY_LAYOUT` members; each body begins after the prefix |
| `status NAME INTEGER DESCRIPTION` | a signed 32-bit result; zero is success and every error is negative |
| `signal NAME NUMBER ACTION [alias NAME] "DESCRIPTION"` | a signal of the [signal table](design-programs.md#signal-numbers), in `signals.txt`: its name without `SIG` in lower case, a distinct number 1 through 128, its default action, `terminate`, `ignore`, `stop` or `continue`, or `reserved` for a number the C library keeps, and its description, FreeBSD's `sys_siglist` text, quoted and last, which a reserved one lacks. The table is the one source of the C lookups, musl's `bits/signum.h` (a reserved name only under `_BSD_SOURCE` or `_GNU_SOURCE`, with `_NSIG` 128) and the protocol names of the signals a program may name |
| `reserved_signal NUMBER` | a distinct number the C library keeps that has no name, as `reserved` on a `signal` line marks one that has: no constant, `erx_sig_name` gives `NULL`, `erx_sig_action` `ERX_SIG_ACTION_RESERVED`, and `erx_sig_valid` refuses it |
| `realtime FIRST LAST ACTION` | the real-time signals `FIRST` to `LAST`, named as `sig2str` names them: `rtmin`, `rtmin+1` up to the middle of the range, then `rtmax-N` down to `rtmax`; at most one |
| `signal_set NAME SIGNAL...` | a named set of signals, in `signals.txt`: a distinct set name and at least one member, each a signal a program may name, none twice |
| `fault KIND SIGNAL` | a row of the fault table, in `erx_abi.txt` beside `exit_kind` ([A program's end](design-programs.md#a-programs-end)): the signal, by its name in `signals.txt`, a program may name, that ends a program whose thread faults with the `fault_kind` `KIND`; every kind but `exit`, which marks an exit record, has exactly one row, or generation fails; C's `erx_fault_signal` and Erlang's `erx_prog:status/1` read a program's end through it, a status 0 to 255 being a halt and `ERX_EXIT_SIGNAL` (256) plus `N` an end by signal `N` |
| `errno NAME NUMBER [alias NAME]` | an errno of the [errno table](design-programs.md#the-posix-lite-personality), in `errno.txt`: its C name in lower case, `einval`, which is its name in a reply of the program protocol, and its number, distinct and 1 through 4095, FreeBSD's in `sys/sys/errno.h`, against which a test compares the table; an alias is a second C name of the same number, `ewouldblock` of `eagain`, and never a protocol name, so one error has one name in a reply; no name or alias comes twice. musl's generated `bits/errno.h` defines each name and alias, so musl's errno values and its `strerror` table are FreeBSD's |
| `termios FIELD` | a part of the termios table, in `termios.txt` ([The tty](design-live.md#the-tty)): `iflag`, `oflag`, `cflag` or `lflag` with indented `flag NAME BIT` and `size NAME MASK FIRST` members, `cc COUNT UNNAMED` with `char NAME INDEX` members, or `speed` with `rate SPEED` members, each rate distinct and 32-bit; the file's header states the forms |
| `right NAME POSITION DESCRIPTION` | a distinct position 0 through 31 within the kernel's 32-bit `erx_rights_t` word |
| `type NAME INTEGER` | explicit `rights` and `pass` lists, including an explicit empty pass list |
| `kind NAME INTEGER TYPE` | a creation kind of an object type: its `default` list, within the type's rights, and for a carved kind `carves KIND`, the kind it is carved from, whose default it does not exceed but by `destroy`; `reserved_space` and `reserved_thread` state what the reserved values `cap_self` and `cap_self_thread` carry, and no call creates them |
| `cap NAME SLOT KIND [optional]` | a well-known root slot and the creation kind its capability is installed as, which fixes its object type and rights; `optional` when the boot may leave the slot null. Slots run from 1 without a gap, and the generator derives the layout `erx_boot_root_extension` from these lines, one `cap` field per slot |
| `call NAME NUMBER` | the call metadata and members described below |
| `reader NAME ROOT_LAYOUT MAX_BYTES` | bounded tables and references described below |
| `target NAME cpu\|device [needs_binding]` | a structure a DMA region may hold and its writer, in a format file of `abi/formats` ([What the formats say](design-device-dma.md#what-the-formats-say)) |
| `translation NAME SOURCE TARGET` | a directed mapping for one named consumer context, from a closed enum or a base integer type to a closed enum; `erx_abi_translations` gives each as a function of its name from a source value to its target's value, or `none` |
| `service NAME NUMBER` | a named interface, its operation identifiers and its typed manifest-parameter declarations; callable operations retain the admission contract of the service design |
| `inspection SCHEMA` | the inspection schema, with its units, value types, backend reporters, kinds and paths as members described in [Inspection schema](#inspection-schema); exactly one, in `inspection.txt` |
| `trap OPCODE IMMEDIATE` | the architecture's trap operation and its immediate, checked by its binding |
| `reg ROLE REGISTERS` | the comma-separated architecture registers for `number`, `args`, `results` or `preserved`; no duplicate within a role |

The base integer types are `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`
and `i64`. A record field is `field NAME TYPE OFFSET`; a fixed array adds
`count COUNT`, a number or a `@limit`, or the name of an enum whose
members number the array's elements: an index enum, not a flags type,
whose values run from 0 without a gap. The model then derives the array's
length from the enum's members, so adding a member without growing the
record fails the extent check below, and the C record sizes the array by
the members' count, a constant the generator emits for each index enum
under the enum's constant prefix (`ERX_CPU_ID_WORD_COUNT` for
`cpu_id_word`). An index enum has no member named `count`.
A `padding OFFSET LENGTH` member represents every gap and
requires zero bytes in a wire encoding. Tail padding is explicit too.
Nested records have no pointers and form an acyclic by-value type graph.
A record's fields, including padding, cover its fixed prefix exactly.
Each field is aligned for its type, and the record alignment covers every
member. The model computes sizes and offsets and checks the declared
ones; it never accepts an emitter's native layout as the source of truth.
An optional `allow VALUE_LIST` member of a flags declaration restricts
accepted combinations to that explicit comma-separated set. Every value
uses only declared bits; without this member all subsets are allowed.

A final `tail NAME TYPE COUNT_FIELD MAX_COUNT` describes a bounded array
after the fixed prefix. It is the last member, uses an unsigned count in
the prefix, and has no implicit terminator. Its extent is checked before
any element is read. A variable-length member cannot be embedded by value
in another layout. A sequence of different tails uses named reader
tables, not nested flexible arrays.

An integer field can have indented `bits NAME LOW HIGH` members, with an
optional `shift COUNT` for an address stored without low zero bits. Both
ends are inclusive. A `field` line of one unsigned integer with no bits,
or a `bits` line, may end in `device_address`: the place holds an address
a device follows into memory
([design-device-dma.md](design-device-dma.md#what-the-formats-say)). The generator rejects overlap, out-of-range shifts
and ranges outside the field. A setter accepts the unshifted semantic
value, checks its alignment and range, and preserves unrelated bits.
Field visibility, allowed-zero bits and caller/kernel ownership are
declared separately from bit extraction: generating a getter does not
make a reserved bit legal input.

A variant has exactly one case for every admitted tag and no other case.
Its prefix and body have the same storage class; the prefix size aligns
each body, and every case has a finite maximum extent within `MAX_BYTES`.
A variant cannot be embedded by value or used as a fixed-table element.
Its reader returns the selected typed view, and the bytes for no other
case are read. This represents a brief/full crash record without treating
a missing full body as a valid full record.

A layout member `private OWNER` keeps a layout's members to the one
source file that owns it, OWNER being that file's path from the
repository root (`private kernel/core/cap.c`). `include/erx/abi.h` then
declares only the layout's tag (`typedef struct erx_NAME erx_NAME_t;`),
its `_SIZE` and its `_ALIGN`, which a caller needs to allocate one, so
everywhere else the layout is an incomplete type, and a member, an offset
or an accessor of it does not compile. Its record, assertions and
operations go to its own header, `kernel/generated/NAME_impl.h`. From the
same declaration the chokepoint rules build one rule per private layout,
`NAME-private` ([Chokepoint checks](design-kernel.md#chokepoint-checks)):
only OWNER and OWNER's host tests include the header, and no other file
defines the record. OWNER's host tests are the files named after it in
the two host-only trees, `test/fixtures/` and `tools/fuzz/`; neither tree
is built into the kernel or an image, so the rule widens to a new test of
the owner without an edit and never to kernel code. A wire layout is a byte format another
party decodes, so it never has a single owner and cannot be private; a
shared layout that user mode reads cannot be private either, and marking
one so fails the build of the code that reads it. No other layout embeds
a private one, as a field or as a tail, and no projection shows one. The
Erlang header carries only its size and alignment, and the generated
reference names its owner and its private header. The capability slot is
private to `kernel/core/cap.c` this way (K1).

Shared fields additionally declare their atomic width and each permitted
load/store order. The declared width equals the representation's width.
Sequence-counted layouts name their sequence field, terminal retirement
value, exhausted-reader result and recovery transition. Missing metadata
fails generation. Generated accessors perform one load or one store;
snapshot retry and the writer's ownership remain the caller's protocol.
Wire layouts cannot contain atomic fields, and shared layouts cannot be
decoded by casting an untrusted byte span to an atomic object.

The exact layout metadata forms, at two-space indentation, are:

| Member | Meaning |
| --- | --- |
| `atomic FIELD load ORDER store ORDER` | FIELD is one signed or unsigned fixed-width integer; `FIELD[]` selects each element of a bounded scalar array; load order is `relaxed`, `acquire` or `seq_cst`; store order is `relaxed`, `release`, `seq_cst` or `none` |
| `owner FIELD ROLE MASK` | ROLE owns these writable bits; MASK is an unsigned literal or `all`; multiple owners have disjoint masks |
| `writer FIELD ROLE` | one serialization owner performs every store to this shared scalar, including updates to logically distinct owner masks |
| `zero FIELD MASK` | these reserved bits are zero; an opaque `bytes` value uses `all`, while `FIELD[]` on a scalar array uses an element-width mask |
| `input_mask FIELD ROLE MASK` | the reader for this input role accepts only these set bits; reserved-zero bits are excluded |
| `visibility FIELD CLASS` | CLASS is `internal`, `release` or `development`; the declaration does not itself expose the field |
| `private` | the layout's record, offsets and operations go only to its private header, described above |
| `sequence FIELD terminal VALUE exhaustion STATUS recovery RECOVERY` | FIELD is an atomic unsigned sequence counter; VALUE fits it; STATUS names a declared failure result; RECOVERY is `none`, `new_object` or `new_incarnation` |

A layout that a device reads or writes as a record may also carry the
DMA marks, `meaning`, `selects`, `fixed`, `refers`, `activates`, `derived`,
`states`, `releases` and `reach`, and its format file `target` lines; their forms, checks and
the encoders generated from them are in
[design-device-dma.md](design-device-dma.md#what-the-formats-say).

`ROLE` is an identifier local to the layout, not a received name or an
authenticated identity. Owner masks and reserved masks cover a field
without gaps or overlaps when ownership is declared. An input mask is
bounded by the nonreserved bits. A shared scalar has explicit atomic,
owner, writer and visibility metadata; an immutable shared scalar declares
`store none`, and its constructor remains its only writer. A wire field
does not become atomic through this metadata. An atomic declaration's
width is the field's base width, not another independently stated number.
Arrays and nested structures cannot be declared atomic as one operation.
Disjoint logical masks do not authorize concurrent load/modify/store
writers: the single writer serializes those updates so one mask's update
cannot overwrite another. The declaration does not synthesize an unsafe
read/modify/write helper for independently owned masks.

For a scalar array declared with `count COUNT` or a bounded `tail`,
`atomic values[] load acquire store release` applies to every element.
The same `values[]` selector is used by its `owner`, `zero`,
`input_mask` and `visibility` metadata. Omitting the brackets for an
array, adding them to a scalar, indexing a single element in metadata,
or applying this form to an array of records fails generation. A nested
record declares its atomic fields in its own layout. No declaration or
accessor performs an aggregate atomic array load or store.

Element accessors take an index and check it before forming an element
address. Fixed arrays use their declared count; bounded tails use the
count and extent captured in the validated view, within the declared
maximum. An out-of-range access fails without a load or store. Each
successful call performs exactly one typed atomic element access; a
whole-array snapshot still needs its owning protocol's sequence check.
Input-controlled counts do not become unchecked loops or allocations.

Signed fields retain their signed type in storage and in atomic loads
and stores. Mask checks, extraction and shifts operate only on the
same-width unsigned value: signed-to-unsigned conversion is the defined
conversion modulo 2 to that width. When a masked result becomes signed,
the generator decodes it with representable arithmetic, not an
out-of-range unsigned-to-signed cast or signed shift: values at most the
signed maximum convert directly; others are `-1 - (unsigned_max - raw)`,
with the parenthesized difference converted only after it is in the
signed range. This preserves the declared signed representation without
aliasing an atomic signed object through an unsigned pointer.

The sequence recovery names describe a required change of the owning
object or record identity before reuse, never permission to reset a
live sequence counter in place. The subsystem supplies and verifies the
identity transition; the generator emits the terminal check and the
declared exhaustion result. It does not generate a recovery protocol.

`projection NAME LAYOUT BUILD` is a top-level declaration; BUILD is
`release` or `development`. Its two-space members are `show FIELD` or
`omit FIELD`, exactly one for every leaf field of LAYOUT. `internal`
fields are always omitted, and a release projection cannot show a
`development` field. A projection's consumer still performs its scope
and sink-escaping checks. This closes projection selection without
adding a service-execution language.

### Packed layouts

A layout of a packed storage is a record of a medium whose fields sit
at any byte offset: F2FS's superblock has a 64-bit `block_count` at
offset 36 ([design-f2fs.md](design-f2fs.md#reading-the-medium)). The
storage's name carries the record's byte order, the one way two packed
layouts differ: `packed_le` is little-endian, as F2FS is, and
`packed_be` big-endian, as Broadcom's event message and IEEE 802.11's
EAPOL-Key frame are ([design-wifi.md](design-wifi.md)). A packed layout
embeds only packed layouts of its own storage, so a record has one byte
order throughout.
Its fields still cover it exactly and the model still checks every
declared offset against the widths before it; only the alignment rule is
lifted, so a packed layout declares alignment 1. It holds nothing but
fields and padding: no tail, sequence, bit ranges, metadata or `names`
line, and no private owner; each field is an unsigned integer, a `bytes`
type without a fixed value or another packed layout, alone or in a fixed
array, and only a packed layout embeds one. C reads no record in place
whose fields may be misaligned, so `include/erx/abi.h` declares nothing
for a packed layout, and every other storage keeps the alignment rule:
a layout C reads can never be packed. Erlang alone reads and writes it,
by bit-syntax matching: `erx_abi.hrl` gives its size and offsets as for
any layout, and the generated module `erx_abi_packed` gives `decode/2`, a
layout's bytes, exactly its size, to a map of its fields, and `encode/2`,
the map back to bytes, refusing a value wider than its field. An integer
field is an integer, a byte array or a `bytes` field a binary, a packed
layout a map, and any other array a list. Neither function checks a value
against more than its width: the bounds are its reader's, such as
`erx_f2fs_codec`'s.

### Layouts in Erlang

A record that Erlang holds as a map, one of a fixed `wire_le` layout,
comes from one generated module, `erx_abi_layout`, in the shape of
`erx_abi_packed`: one clause of a binary pattern of exactly the layout's
size per layout, and one of the encoder. A module that only matches
bytes may match against the generated macros instead. Each layout is also a `-type` of its map, field
for field under its declared names, nothing renamed or dropped, so a
module that holds a record names its type rather than declaring the
fields again. An integer field is an integer, even one whose values have
names elsewhere (a header type, a sentinel); an enum field is its
member's atom; a flags field is the ordset of its bit names; a nested
layout is a map and an array of layouts a list of maps; an unsigned byte
array or a `bytes` field is a binary, and any other array a list.
`erx_abi_enums` owns the translation between names and integers:
`name/2` and `value/2` for every enum and flags type, and a type of the
ordset for each flags type. Every atom comes from the ABI file, so no
input creates one.

`decode/2` returns `{ok, Map}` or `{error, Error}`: `{size, Layout}` for
bytes of another size, `{padding, Layout}` for a padding byte that is not
zero, and `{Type, Value}` for an enum value no member holds, a flags
value with a bit its type does not declare, a combination its `allow`
line does not list, a scalar outside its range, or bytes that differ from
their type's fixed value. Each refusal is one throw out of the clause that
finds it, caught once in `decode/2`. `encode/2` is its inverse, so
`encode(decode(B))` is `B` for every `B` it accepts, and a value wider
than its field, a value its type does not admit, or a name its type does
not have, is an error. Neither
interprets a sentinel, such as an unused slot of zeros: what it means is
the reader's, which reads it in one module (`erx_pcie` for the PCIe
records).

### Element sequences

An element sequence is records of a tag, a length and a body of that
many bytes, repeated to the end of a buffer: IEEE 802.11's information
elements, and the key data elements of an EAPOL-Key frame
([design-wifi.md](design-wifi.md)). `elements NAME STORAGE TAG_ENUM
LENGTH_TYPE [end MEMBER]` declares one:

* `STORAGE` is `packed_le` or `packed_be`, the byte order of the tag and
  the length, and the storage of every layout a body names.
* `TAG_ENUM` is an `enum` over an unsigned integer, whose base is the
  tag's width. Its members are the sequence's known tags, exactly: each
  has one `element` line, in ascending tag order, so the closed set is
  the enumeration's and the spec has one sorted form.
* `LENGTH_TYPE` is an unsigned base integer, `u8` to `u64`, the length's
  width. The length counts the body's bytes alone.
* `end MEMBER`, when present, names the end marker: a header of
  MEMBER's tag with length zero, or MEMBER's tag alone as the last bytes,
  ends the sequence, and nothing after it is read. It is how a sender
  pads a sequence to a block size, as the padding of an EAPOL-Key
  frame's encrypted key data does (0xdd, then zero bytes); the encoder
  writes no marker, and a sender appends its padding itself. MEMBER's
  element has a body of at least one byte, which the model checks, so a
  header of length zero is never also an element.

Each member is `element MEMBER REPEAT LAYOUT` or `element MEMBER REPEAT
bytes MIN MAX`. `REPEAT` is `once`, for an element that appears at most
once, or `many`. A body is exactly a packed layout of the sequence's
storage, or `MIN` to `MAX` bytes; either way it is no longer than the
length type can count, which the model checks. An element of a tag
outside the enumeration is skipped: the sequence states what its reader
understands, not everything a sender may write.

The generated module `erx_abi_packed` gives `decode_elements/2`, a
sequence's bytes to `{ok, Elements}`, its known elements in order as
`{Name, Body}`, a body a binary or its layout's map, and
`encode_elements/2`, such a list back to bytes. The decoder is total
over any binary. Each step stops at the end marker, if the sequence has
one, and otherwise reads one tag and length, refuses
`truncated` when the bytes end inside them and `overrun` when the
length exceeds the bytes that remain, and only then forms the body; a
known element's body outside its bounds is `{length, Name}`, and a
second element that appears once `{duplicate, Name}`. Every step
consumes at least the header and every call is a tail call, so the walk
ends within its bytes in constant stack whatever they hold, and it
creates no atom: a name is one of the enumeration's. The encoder refuses
an unknown name, a body outside its bounds and a second element that
appears once. A body's own contents are its reader's to check, as for a
packed layout. C reads no element sequence.

### Kernel calls and bindings

Each call declares `waits yes|no`, `executor allow|refuse|private ARG`, a
nonempty `bound` list of named work units and their limits,
`effects reads|changes`, and `charges none|ARGUMENT`. A variable bound
references a declared finite limit or a named, documented kernel work unit
such as the mapping edge; free-form expressions are not bounds. Argument
and result members name their types and their location, either a numbered
argument/result register or a message word of the declared `erx_utcb`
layout. The architecture binding supplies the registers, trap and
preserved-register set.

The executor rule is the dispatch's class check, and it applies only
before a wait. A call that does not wait declares `executor allow`; one
that an executor may not use in some form, as `erx_ipc_reply` or
`erx_vcpu_control`, fails in its handler with that call's own status. A
call that may wait declares `refuse`, which the generated dispatch answers
with `ERX_EWOULDBLOCK` before it decodes anything; `allow`, which admits
an executor, as `erx_park` does; or `private ARG`, which admits an
executor whose word, the `u64` register argument `ARG`, lies in the caller's own
private memory: the generated shape carries an `executor` flag, and the
handler refuses an executor with `ERX_EWOULDBLOCK` once the word's key
names a shared object, as `erx_umtx_wait` does. A test pins the shipped
waiting calls that admit an executor to exactly those two.

A call marked `retry` may ask the dispatch to run it again from its
capability lookup with the same arguments, as a send woken at an unbound
gate does. Only such a call's generated handler prototype takes the
`erx_sys_action_t` out-parameter that asks for it, so no other handler can,
and the action is never a status or a result register. Only a call that
may wait and takes a capability can be marked `retry`.

A capability argument names an object type and its required rights. The
`exists` property names the argument whose existence lock the dispatch
holds across the handler; a call declares at most one, and a result none.
A call that needs two existence locks marks neither, and its handler takes
both as its first act. The generated admission
plan lists a call's capability arguments in the order the dispatch takes
them, the existence-locked one first, then the rest in declaration
order, with each one's object type and required rights; the admission
core, `kernel/core/admit.c`, turns the plan into lookups and locks
([System-call dispatch](design-kernel.md#system-call-dispatch)), and
`ERX_SYS_POSITION_CALL_ARGUMENT` names each argument's place in that
order. A capability is an argument of its own: an aggregate argument
cannot carry one, since the plan could not list it. A memory-window
argument names its memory capability, offset, length, maximum and
read/write direction; its capability carries the right of that direction
and holds no existence lock, since the window's checks run at its lookup.
A call that may wait has no memory window. Only a call marked `effects reads` may write a window; that mark
permits its output window and its caller's UTCB/register results, and no
other state change. A raw user pointer is not a type. Address-valued
types such as a mapping address or a umtx word retain their distinct
meaning and never become a C pointer parameter.

Registers hold at most six argument words and two result words in
addition to status; the limit counts register parameters, each one integer
word, and a parameter in the UTCB takes no register. A register's
parameter is unique and its type fits the word. A UTCB parameter starts at
a message word and owns every word its type touches, all inside the
declared 63 message words, and no two arguments, or two results, share a
word; an argument and a result may. Its type is an integer, fixed bytes without a fixed value or
an aggregate, a fixed `wire_le` layout without a tail, sequence, atomic
field or input mask. Byte `OFFSET` of a parameter's words is byte
`OFFSET % 8` of word `OFFSET / 8`, least significant first, on both sides
of the trap. The kernel loads each owned word once into kernel memory and
decodes only that copy, checking each field as it checks a register
argument and refusing a nonzero byte that no field covers; it stores a
UTCB result's words once each. The declaration does not silently spill a
seventh argument or infer an ABI from a C prototype. The model
validates every right against the capability's type, every charged
argument against the owning budget contract, and every backend's complete
declaration set before deriving stubs or handler tables.

The architecture's result-register list starts with status. Argument and
result roles can share registers; a preserved register cannot also be a
written result. The architecture's binding defines the available
register names and widths, so a spelling that the selected architecture
does not define fails generation.

The native trap wrapper, Fiasco backend declaration and hosted backend
declaration share a generated typed signature, which passes an integer
argument by value, an aggregate or fixed bytes by pointer and each result
through an out pointer; the native wrapper reaches the calling thread's
UTCB through `erx_utcb_self`, which the `erx` backend provides. A declaration does not
supply an implementation or fabricate success for an unsupported call.
Raw wrappers return kernel status and do not set `errno`.

Call members use these exact token forms, at two-space indentation:
`waits VALUE`, `executor allow`, `executor refuse`, `executor private ARG`,
`retry`, `effects VALUE`, `charges VALUE`,
`bound UNIT LIMIT`, `arg NAME TYPE register INDEX`,
`arg NAME TYPE utcb mr[INDEX]`, `result NAME TYPE register INDEX` and
`result NAME TYPE utcb mr[INDEX]`, where `INDEX` is a decimal message-word
index without leading zeros. A capability argument replaces `TYPE`
with `cap OBJECT_TYPE RIGHTS`, where rights are a comma-separated list
of declared rights or `none`; optional `exists` follows its location.
`window NAME CAP_ARG OFFSET_ARG LENGTH_ARG DIRECTION MAXIMUM` relates
already declared argument values. Bound units are unique within a call.
`type` declarations use one `rights LIST` and one `pass LIST` member,
and `kind` declarations one `default LIST` member, with the same list
syntax. Root capabilities have a namespace of their own, as the
`root_slot_NAME` constants they produce do. A translation from an enum
has one `map SOURCE_VALUE TARGET_VALUE` or `omit SOURCE_VALUE REASON`
member per source value; the reason is a quoted note for the reader of
the source, and an omitted value has no target. An unlisted exposed
source value fails. A translation from a base integer type, such as
HID's keyboard usages to evdev codes in `formats/hid.txt`, has `map`
members only, each an integer within the type, and a value it does not
list has no target.

### Structural readers

Reader declarations bind layout members to their containing byte span:

* `value FIELD LITERAL` and `range FIELD MIN MAX` impose a fixed value
  or inclusive bounds beyond the member's type; an impossible constraint
  fails generation.
* `source ROLE` selects a declared input role; each `input_mask` for that
  role is checked on the snapshotted field. A reader of a layout that
  declares input masks must choose a role with a complete mask set.
* `optional FIELD FLAGS_FIELD BIT` requires zero bytes when the named
  flag is absent and validates the field's declared type when it is
  present. The flag is a declared member of that flag type.
* `choice TAG_FIELD TAG_ENUM FIELD_LIST` has four-space-indented
  `case TAG ACTIVE_FIELDS` members. Every tag has exactly one case;
  listed fields outside that case's active set are zero. Common fields
  are outside `FIELD_LIST`. This validates a fixed-size tagged record
  such as a facet parameter without an unchecked C union cast.
* `table NAME TYPE OFFSET_FIELD COUNT_FIELD MAX_COUNT ALIGNMENT` declares
  a fixed-record array. The offset is from the start of the file, never
  from a native pointer.
* `string_table NAME OFFSET_FIELD LENGTH_FIELD MAX_BYTES` declares bytes
  referenced by string members.
* `index FIELD TABLE` checks a record index. An optional absent value is
  explicit and outside the accepted index range.
* `slice OFFSET_FIELD COUNT_FIELD TABLE` references a contiguous run of
  records; the offset is a file offset to the first record, consistent
  with `erx_mf_span_t`, and must fall on a record boundary in that table.
* `partition OFFSET_FIELD COUNT_FIELD TABLE` adds exclusive, complete
  ownership to a slice. In owner-table order, each span starts at the end
  of its predecessor and the spans cover the entire target table. This
  admits neither overlapping owners nor unowned records.
* `string OFFSET_FIELD LENGTH_FIELD TABLE CLASS MAX_BYTES` references a
  string. Its offset is relative to the named string table. Classes are
  a closed set of separately tested validators: system identifier,
  device-tree path, namespace path, relative path (plain names joined by
  `/`, so it stays below where it is resolved), UTF-8 text, opaque bytes,
  NUL-separated arguments, and NUL-separated environment entries. Empty
  is a distinct declared option.
* `order TABLE...` requires the header followed by the named record and
  string tables in that order, each at the first boundary of its declared
  alignment, the last ending the input. Padding is zero. An empty
  table has its canonical current offset and a zero count.
* `extent FIELD` requires an unsigned root length field to equal the
  complete input byte length.

Every member above is at two-space indentation within a `reader`.
Field paths have exact grammar `root.FIELD[.FIELD...]` or
`TABLE[].FIELD[.FIELD...]`. Nested components name by-value record
members. `TABLE[]` means each element of the named reader table; it is
not an index expression. There is no implicit current record, array
index arithmetic or arbitrary path traversal. The offsets/counts which
define a top-level table or string table must be `root` fields. In a
string, slice, choice or index rule on table elements, all referenced
record fields share the same `TABLE[]` prefix; its table argument names
the independently declared target table. Rules on a tail use its
declared tail name in the same `TABLE[]` form. A nonexistent field,
mixed element scopes, traversal through a scalar or a dependency cycle
fails generation.

Empty permission is written by appending `empty yes` or `empty no` to
`string`; an optional index appends `absent VALUE` to `index`; omission
means empty strings and absent indices are refused. `FIELD_LIST` and
`ACTIVE_FIELDS` are comma-separated paths, or `none` for an empty active
set. A choice's four-space `case` members follow its two-space `choice`
line immediately; every other reader member ends that choice block.

A `value`, `range`, `index` or `string` rule may append
`when TAG_FIELD MEMBER`. The tag is a scalar closed enumeration in the
same record scope, and `MEMBER` is one of its declared members. The rule
applies exactly when that tag equals the member. This supplies the
boolean range, referenced table and string class of a tagged facet
parameter; it does not select storage or replace the choice's inactive
zero checks. There are no arbitrary condition expressions.

Every referenced field exists and belongs to the record the declaration
names. Extents, offsets, counts and indices have unsigned types wide
enough for their bounds. Values and ranges also accept signed scalar
payload fields, and nested active payload records keep their declared
types. Every table has
a finite byte/count bound. Table and field-validation dependencies are
acyclic and resolve before dependent members are examined. Extents use
`count <= remaining / element_size` and `offset <= length`, then subtraction, before a
pointer or sub-binary is formed. Alignment checks precede access.

Generated readers check the complete structure before returning a view:
version, fixed values, reserved bits and padding, table extents and order,
all indices, slices, strings, and declared scalar ranges. Tagged variants
declare a closed tag enumeration and exactly one layout per tag; an
unknown tag is refused, never decoded as a default variant. Cross-record
security and resource properties remain in the manifest checker and are
not expressed as a general constraint language.

The C, Erlang and Ruby readers produce equivalent values and diagnostic
classes. Erlang names and map keys are compile-time atoms; input strings
remain binaries, and readers never create atoms. Ruby readers return
immutable records or raise a typed error under `Erx::Error`. C readers
use explicit little-endian loads into typed values, without packed
structure casts, unaligned dereferences or host-endian assumptions.
Each fixed `wire_le` layout also has a C encoder, its decoder's inverse,
which stores every field the same way and zeroes the padding, so a
record C holds reaches Erlang as the bytes `erx_abi_layout` decodes, as
the domain library hands the PCIe catalogue to the device service
([design-pcie.md](design-pcie.md#the-catalogue-and-gives)). The device
records are the exception: every layout of a descriptor format, a
format file that holds a layout with DMA marks, is a record of a ring
or table a device follows or payload a driver posts in a buffer. The
reader gives none an encoder, so a device record's only C encoder is
the one its marks give it in `erx/abi.h`, a report has none, and a build
check keeps every caller but the sequencer off those encoders
([design-device-dma.md](design-device-dma.md#descriptions)).

A reader whose input is the front of a larger file, such as a package's
header ([design-packaging.md](design-packaging.md#the-package)), declares
an `extent`, and its Erlang module also exports `open_prefix/1`: it
decodes the root to read the extent field, cuts the binary to that
length or to the bytes there are, and opens that as `open/1` does, so
the unchecked root never reaches the caller and a field naming more
bytes than there are is refused as `open/1` refuses it. C reaches the
same through the root layout's decoder and Ruby through `decode_layout`
with `prefix: true`.

### Inspection schema

`inspection.txt` holds the one `inspection SCHEMA` declaration, SCHEMA
being the `schema` number every inspection record carries
([design-live.md](design-live.md#inspection-records)). Its members, at
two-space indentation, declare units, value types, backend reporters,
trace rows, kinds and paths; a kind's attributes and a path's marks are at four
spaces beneath it. The members have one namespace of their own. A member
refers to another member by its bare name, and to a root `limit`,
`scalar`, `enum` or `flags` by `@name`. A name is declared once, and a
unit, a value type or a kind that no member uses fails. Members may
appear in any order; a kind's attributes are in field order. Kinds,
attributes and reporters carry no numbers: generated code names each by
its name, never by its position, so adding a member renumbers nothing.

| Member | Meaning |
| --- | --- |
| `unit NAME LABEL` | a unit, and the quoted label a renderer prints after a value of it |
| `integer NAME MIN MAX [unit UNIT]` | an integer within the inclusive bounds, each a literal or a `@limit` |
| `text NAME MAX [utf8]` | bytes as reported, at most MAX of them; `utf8` refuses bytes that are not valid UTF-8 |
| `atoms NAME ATOM...` | one atom of a closed set |
| `list NAME TYPE MAX` | at most MAX values of TYPE, MAX at most 1,000 |
| `tuple NAME TYPE...` | two to 16 values of the listed types, in order |
| `backend NAME CATEGORY LABEL SCOPE` | a reporter that stands in for the reporter category CATEGORY, `kernel`, `service` or `runtime`; LABEL is the quoted name renderers print for it and SCOPE the quoted statement of what it can see |
| `trace ROW REPORTER` | a row of `erx:trace`'s stream ([design-live.md](design-live.md#tracing)) and the one reporter, a category or a backend, that its collector assigns to every event of the row; ROW names a namespace of its own, so the `kernel` row may share the category's name, and becomes an atom of `erx_schema` |
| `kind NAME` | an inspection kind; its `attr` members follow at four spaces |
| `attr KEY TYPE reporters LIST visible CLASS build BUILD projections LIST` | an attribute of the kind, described below |
| `path KIND SEGMENT...` | a path and the kind of its record, described below, with its marks at four spaces |

A value type is a member type, `boolean`, `proc_id` (a process as the
`proc_id()` `{pid, D, N, S}` of three numbers, never a live pid:
[design-live.md](design-live.md#inspection-records)), `rights` (a set of the
root's `right` names), `object_type` (one of the root's `type` names),
`status` (one of the root's `status` names), or a `@` reference to a root
`scalar`, which is an integer within its range, an `enum`, which is one
of its member names as an atom, or a `flags`, which is the set of its bit
names. No type admits an arbitrary term or an atom from the input: names
a domain reports are `text`. The generator refuses a type nested more
than eight deep, as the web's `datum()` is
([design-web.md](design-web.md#values)). Kinds, attribute keys, backend
reporter names, statuses and the atoms of `atoms`, `enum`, `flags` and
the root-backed types become atoms of `erx_schema`, so a reader of a
record refuses an unknown one without making it. A reported value
outside its type, such as a text longer than its MAX, becomes `{error,
invalid}` for that attribute alone.

An attribute names its KEY and TYPE and four required properties, so
adding one never exposes it by default:

* `reporters`, a comma-separated list of the categories `kernel`,
  `service` and `runtime` and the backend reporters that may report it.
  A backend reporter is listed by its name, only on the attributes it
  answers, so a validator refuses it anywhere else, and always beside
  the category it stands in for, so removing Fiasco leaves the
  attribute declared for that category; a backend that no attribute
  and no `trace` row lists fails;
* `visible`, the inspect facets that see it: `any`, every inspect facet;
  `owner`, a facet whose scope covers the path's owner, which for a path
  the machine owns is a facet of scope `all`; `all`, a facet of scope
  `all`; `system_shell`, only a call presenting the system-shell
  facet; or `display`, decided by the caller's principal and by no
  scope, `all` included: a caller whose principal is the path's owning
  domain's, or that of the session of the display the path's window is
  on ([design-display.md](design-display.md#the-widget-server)); the
  generator refuses it on an attribute of a path outside
  `[domains, Id, uis]`;
* `build`, `all` or `development`; a release build's inspector omits a
  `development` attribute from the record, as if it were not declared;
* `projections`, a comma-separated list of `shell`, `host`, `proc` and
  `web`, or `none`: the renderings that show it. A rendering shows no
  attribute that does not list it.

An optional fifth property, `derived INPUTS`, a comma-separated list of
the kind's other attributes, marks an attribute the inspector computes
from those inputs ([design-live.md](design-live.md#inspection-records)),
as a budget's spending is computed from `used`, `carved` and `lent`; no
report layout has a field for it, and each input is an attribute that is
not itself `derived`.

A kind's attributes appear in its records, in shell and host tables, in
`/proc` `status` files and on the web in declaration order, which is the
schema's field order.

A path's SEGMENTs are literal segments, identifiers that become atoms of
`erx_schema`, and variable segments `*TYPE`, each one segment holding a
value of TYPE, which is an integer, text or `proc_id` type; a path has at
most 16 segments and a text segment type a MAX of at most 256, the web's
bounds ([design-web.md](design-web.md#the-protocol)). `path machine`,
with no segments, declares the root `[]`. The built-in kind `listing` has
no attributes: its records, such as `[cpus]`'s, only list their children.
Every proper prefix of a declared path is declared, no path is declared
twice, and each declared path is extended either by literal segments or
by one variable segment, never both, so each path a query names, as a
term or as text, resolves to exactly one declaration or is refused. A
path's variable segment has the type of its prefix's at that position,
and no variable segment holds the empty text, which a path's text cannot
write. A path's text is its segments joined by `/`, with an optional
leading `/`: a `proc_id()` as `D.N.S`, an integer in canonical decimal and a
text in `/proc`'s name encoding
([design-live.md](design-live.md#the-proc-tree)); `erx_schema` reads only
that spelling of each path, with or without the leading `/`, and has a fuzz target, since the text
comes from `/proc` and the host. A record's children are derived from the declarations: the literal
segments by which a declared path extends its path by one, or the values
the collector of its variable segment reports.

A path's marks, at four spaces:

* `entries TYPE MAX`: the record is a sequence of at most MAX entries of
  TYPE, beside the kind's attributes, which a query pages through with
  `offset` and `limit`, as the domain's threads, its export table, its
  crash dump and a module's source lines are; `/proc` shows such a path
  as a file of one entry per line;
* `append_only`, on a path with `entries`: the sequence only grows at
  its end, and each entry carries its sequence number beside its value
  ([design-live.md](design-live.md#paths));
* `visible CLASS`: the facets that reach the path and every path below
  it, of the attribute classes; any other caller gets `{error, scope}`,
  so the schema, not a list in the collector, refuses the machine-wide
  paths and the crash record. A path's visibility is its own mark and
  every mark on its prefixes, each of which a caller must meet;
* `present NAME`: the path is the presentation type NAME
  ([Presentations](design-display.md#presentations)). Its value is the
  path's variable segments, one segment's value or the tuple of several
  in order; its canonical text is those segments in the path's text,
  joined by `/`; its grammar is that of the path's text; and it names
  this path. A path carries at least one variable segment and at most
  one `present` mark.

Presentation names are a namespace of their own, as trace rows are, so
`domain` may name a kind and a presentation, and they become atoms of
`erx_present`. A presentation's name is the link grammar's `type`, at
most 32 bytes. The generator refuses a presentation named `accept`, the
input context's URI ([Links and the input
context](design-display.md#links-and-the-input-context)), `proc`, `ui`,
`trace`, `login` or `ws`, the web's fixed routes
([URLs](design-web.md#urls)), or `kernel`, `service` or `runtime`, which
lead a widget value's attribute pair
([Widget trees](design-display.md#widget-trees)); a presentation declared
twice; two presentations of one variable segment over the same type,
since an attribute of that type is shown as that presentation; and a
presentation whose longest canonical text exceeds 4,096 bytes, the
widget format's bound for it, or whose longest link, after the OSC 8
string's `8;;`, exceeds that string's 4 KiB.

A backend reporter appears in a record as `{backend, NAME}`. Its label
and scope come from the schema, so a record carries no free text about
who reported it, and a domain cannot invent a reporter. LABEL and SCOPE,
like a unit's label, are printable ASCII, a label at most 255 bytes and a
scope at most 1,024, and the generator refuses a label equal to a
category's name or to another backend's label. A member's name is
neither a category's, a built-in type's, `listing` nor `none`; a text's
MAX is at most 65,536, a record's bound, and an `entries` MAX at most
2^32 - 1. A backend reporter stands
for a component behind an interface that does the kernel's, a service's or a
runtime's work in its place, such as the Fiasco backend of `liberx`
counting a budget's pages in the kernel's place
([design-fiasco.md](design-fiasco.md#reporting-a-budget)); replacing
the component removes its declaration, and the attributes it reported
come from the category it stood in for. An attribute lists at most one
backend reporter for each category.

**Kernel reports.** `erx_object_info` writes one report layout per
topic ([design-kernel.md](design-kernel.md#failure-handling-diagnostics-and-debuggability)).
A topic the inspector shows is named after the kind it reports
(`machine`, `cpu`, `group`, `budget`, `thread`), and its layout is
`erx_info_<kind>`. Every field of that layout other than `reported`,
and `id` in a topic whose `index` counts entries (`thread`), is an
attribute field, named after an attribute of the kind that lists
`kernel` and is not `derived`. `reported` is a `flags` field with one
bit for each attribute field, named after it: a set bit says the kernel
interface reports the field with the attribute's full meaning, and a
clear bit says it does not, so the field's value means nothing to a
reader that knows no more. The generator checks these names, so the
collector maps fields and bits to attributes by name and keeps no table
of its own; an attribute that lists `kernel`, is not `derived` and has
no field in the layout reads as a clear bit. A field that holds an
enum value is a plain integer, its enum named in a comment, so that a
reader never refuses a report over a value its clear bit disowns. The
generated decoder turns such a field into its enum's atom when the
attribute's type is that enum, and leaves a number the enum does not
name a number, which the attribute's validator refuses only when the
field's bit is set; a byte array whose attribute is `text` and not
`utf8` becomes its
lower-case hexadecimal, as the build identifier is written everywhere.
Neither rule applies to an array of wider integers, which stays a list. No
report layout names a
reporter or a `partial` status. A field that a backend counts
only partly has its `reported` bit clear, and that backend names it
through `liberx` in the inspector's own domain; its reporter is the one
backend the attribute lists for `kernel`
([design-live.md](design-live.md#inspection-records)). The topic enum,
the `flags` and the layouts are ordinary root declarations of
`erx_abi.txt` and need no grammar of their own; the `call
erx_object_info` declaration alone waits on the call grammar's
capability argument of any type
([Kernel calls and bindings](#kernel-calls-and-bindings)).

### Widget format

`formats/ui.txt` holds the one `ui VERSION` declaration of the display's
widget trees ([Widget trees](design-display.md#widget-trees)) and of
their binary form. Its members, at two-space indentation, declare value
types, image types, properties, kinds, the records of the binary form
and an input record's forms; the properties a kind takes, and the fields
of a record or an input form, are at four spaces beneath it. Value types
and image types share one namespace, properties have one and kinds one,
each apart from the root's, so the property `image` and the kind `image`
are two names; a member refers to another by its bare name and to a root
`limit` or `enum` by `@name`. Every wire number is literal in the source.

| Member | Meaning |
| --- | --- |
| `integer NAME MIN MAX` | an integer within the inclusive bounds, which lie within a signed 32-bit integer |
| `text NAME MAX utf8` | at most MAX bytes of valid UTF-8, MAX at most 65,536 |
| `bytes NAME MAX` | at most MAX bytes, MAX at most 65,536 |
| `list NAME ELEMENT MAX [none]` | at most MAX values of ELEMENT, a text type, an integer type or a root `@enum`, MAX at most 1,000; with `none`, the atom `none` is also a value, and only for an integer type that does not hold -2^31 |
| `image NAME NUMBER CONTENT_TYPE` | an image type: its atom, its number from 1 to 255, and the quoted media type the browser is given |
| `prop NAME NUMBER TYPE [common] [status] [default VALUE] [detail state]` | a property, NUMBER from 1 to 255 |
| `kind NAME NUMBER [children]` | a kind, NUMBER from 1 to 255, which takes children when marked |
| `prop NAME [state] [fixed] [within LOW HIGH] [index LIST] [hides PROP] [parallel LIST]` | at four spaces: the kind takes the property, with these marks |
| `record NAME TAG [short REASON]` | a record the server writes to a renderer, TAG from 1 to 255; a fixed field cut short is refused for REASON, `short_record` unless marked |
| `input NAME NUMBER` | a form of an input record's event, NUMBER from 1 to 255 |
| `field NAME TYPE` | at four spaces beneath a record or an input form: its next field in wire order |
| `report NAME TAG` | a record a renderer writes back, whose tag no record shares |

A property's TYPE is a member type, a root `@enum` of type `u8` whose
member names are the atoms, `boolean`, `image` (one of the image
types), `key`, `event` or `presentation`. `key` is an integer, an atom
or a binary of at most 255 bytes, and only the property `key` has it;
`event` is any term the application chooses; `presentation` is a
presentation name of the inspection schema and a value of it. `common`
makes every kind take the property. `status` lets the value also be an
`attr()` carrying one ([design-live.md](design-live.md#inspection-records)).
`default` states what the property's absence means. `detail state`
marks an event whose detail is the kind's state value; any other event
has none. On a property's line beneath a kind, `state` marks the value
the user changes, `fixed` a property that is part of the node's
identity, `within LOW HIGH` an integer, or each value but `none` of a
list of integers, that lies between two integer properties of the kind,
`index LIST` an integer that indexes a list property of the kind, `hides
PROP` a fixed boolean under which PROP is refused in a tree, never kept,
and handed to the application as `{erx_secret, V}`, and `parallel LIST`
a list exactly as long as the list property LIST, an absent LIST
counting as empty; the validator refuses a value against any mark with
`bad_value`.

A field's TYPE is `u8`, `u16` or `u32`, any unsigned value; `i8`, a
signed byte; `node`, a `u32` other than 0; `kind`, a declared kind's
number; `direction`, a key's down 1 or up 0; `rune`, a Unicode scalar
value or 0xffffffff for none; `props`, a property list; `removals`, a
set's removed property numbers; or `input`, an input form's number and
its fields. A field name has one type in every record and input form,
since a native renderer's record keeps one member per name, and a record
has at most one field each of `props`, `removals` and `input`. The
readers and writers in all three languages follow from these lines: a
reader reads and checks each field in wire order, and the first that
fails gives the reason. The reasons are one list in the generator
(`UI::REFUSALS` in `tools/lib/erx/abi_ui.rb`), not in the declaration,
since each is given by a check of the generator's code for a field type
or for the framing, and a reason declared without such a check would
mean nothing. A report's fields are the generator's fixed code.

Generation refuses a declaration whose marks cannot hold: a `within`,
`index`, `hides` or `parallel` naming a property the kind does not take
or of the wrong type, a `within` bound without a `default` (so a tree
that omits it still has a range), a `detail state` event on a kind
without exactly one `state` property, `none` on an element type that
holds -2^31 (the value that stands for `none` on the wire), an image
content type outside `image/` or `image/svg+xml`, and a kind whose
largest `insert`, every property it takes at its bound, exceeds
`web_ui_op_max`, the room one web update leaves for an operation
([Web protocol](#web-protocol)). `ui_children`, the most children one
node has, bounds the difference of two trees and keeps every `insert`'s
and `move`'s index within its `u16`.

**The binary form.** The binary form follows from the declaration, as
9P2000.L's bytes follow from the protocol's kinds: little-endian
integers, each message a `u32` length (its tag and fields, never 0, at
most `web_ui_op_max`), a tag and the record's fields. The records that
build and change a tree (`insert` to `commit`) and `event` travel on
the web protocol too; `screen`, `input`, `repaint`, `presented` and
`damage` travel only on a native renderer's pipes
([The widget server](design-display.md#the-widget-server)), and the web
readers refuse their tags. No message carries pixels: a native renderer
draws into its window's buffer, which its session mapped into it
([The pixel area](design-display.md#the-pixel-area)), reports what it
drew in one `damage` message for each refresh, and draws again only
after the `presented` that answers it. Whether a `damage` report's size
is the window's is decided by the process that consumes the report,
which knows the window.

A property list is a `u8` count and, for each property, its number and
its value: a boolean as a `u8` of 0 or 1, an integer as a signed 32-bit
value, an enum or an image type as its `u8` number, a text or bytes as
a `u32` length and the bytes, a list as a `u16` count and each element
in its own encoding with `none` as -2^31, a presentation as its name
(a `u8` length, at most 63 bytes) and its canonical text; an event
property is its number alone, saying the node takes it, and a `key`
property is never written. A `status` property begins with its status
block, the generator's fixed code in `tools/lib/erx/abi_ui.rb`: the
status and the reporter as `u8` numbers, a backend's name (empty unless
the reporter is a backend) and a timeout in milliseconds (0 unless the
status is `timeout`); the value follows only for `ok` and `partial`, and
a status other than `ok` from the application's own reporter is
refused, since the application's own value is a plain value. A reader refuses an unknown tag, kind, property,
image type or enum value, a value outside its type, a property twice in
one list, a backend name the inspection schema does not declare, node 0
where a node is named, and bytes left over in a message. It keeps no
state between messages and nothing it decodes depends on a node's kind,
so whether a node exists, takes a property or an event, or fits its
parent is decided by the renderer's `apply_ops` and by `hit/4`, never by
the reader. A reader also refuses an event's text detail (a `u32`
length and that many bytes, bounded by the message) or a presentation
name or text that is not valid UTF-8, a timeout of 0 with `timeout` or
a nonzero one with any other status, and a `damage` count of 0 or above
`ui_damage_rects`, a rectangle of no width or height, or one outside
the size the report names. The C writer writes a record into the
caller's buffer and refuses it whole when it does not fit or breaks a
rule a reader checks.

The generator emits `erx_ui_wire` (Erlang), `web/src/generated/ui_wire.ts`
(TypeScript, whose reader hands every text out as a `MachineText`,
[The client](design-web.md#the-client)) and `erx/ui_wire.h` with its
freestanding C source, the reader of the server's records and writer of
`event` and `damage` that a native renderer links. The C code allocates
nothing: texts point into the caller's buffer and a list's values are
read from its encoded bytes. The encoder takes the canonical text of a
`present` value as a function, `erx_present:text/2`, so the generated
module depends on no presentation table. Its `encode/2` writes every
text through the line escape, `erx_text:escape_line/2`, since a native
renderer shows the bytes it reads ([design-display.md,
G5](design-display.md#invariants)), and cuts an escaped text longer than
its bound at a whole escape token; `encode_raw/2` writes texts as they
are, for the browser, which escapes each text itself, and only the sites
of the chokepoint `ui-raw-texts` call it. A name read from input makes
no atom. The readers of the server's records in Erlang, C and TypeScript
give the same reasons for the same refusals, so one parity test feeds a
corpus and its mutants to all three.

### Draw format

`formats/draw.txt` holds the one `draw VERSION` declaration of the draw
protocol's messages ([Draw messages](design-display.md#draw-messages)).
Its members, at two-space indentation, are the messages; the fields of a
message are at four spaces beneath it, in wire order after the letter.
Message names have one namespace and letters another; field names have
one per message, and a field refers to an earlier one of its message by
its bare name.

| Member | Meaning |
| --- | --- |
| `message NAME LETTER` | a message: its name, the tag of its decoded term, and its letter, one printable ASCII byte |
| `field NAME TYPE` | a fixed field: `u8`, `u16`, `u32`, `i32`, `id` (a u32 image id), `point` (two signed 32-bit coordinates) or `rect` (four) |
| `field NAME points COUNT` | COUNT + 1 coded points, COUNT an earlier `u16` field |
| `field NAME indices COUNT` | COUNT u16 glyph indices, COUNT an earlier `u16` field |
| `field NAME pixels ID RECT` | raw pixels: `bytesperline(RECT, depth)` times Dy(RECT) bytes, depth that of the image ID names |
| `field NAME compressed ID RECT` | image(6)'s compressed pixels for RECT at ID's depth, ending at the code that completes the last row |

All integers are little-endian. A `u16` that a `points` or `indices`
field names is a count: it counts exactly one field, is not part of the
decoded term, and the encoder writes it from that field's items. A
`pixels` or `compressed` field names an earlier `id` and `rect` field of
its message.

The generator emits from the declaration one table of every message's
fields, and the one walk over it in each language reads every message:
`erx_draw_codec` in Erlang, with `decode/2`, `encode/1`, `layout/1` and
`letter/1`, and its C twin, `erx_draw_decode` of `erx/draw_codec.h`, a
host test tool that the fuzz target and the differential test link. A
message decodes to `{Name, Field...}` with its fields in wire order,
counts left out, or to the bare `Name` when it has no field; a point is
`{X, Y}` and a rectangle `{X0, Y0, X1, Y1}`; points are a list of
points with absolute coordinates, indices a list of integers, and the
pixels of either kind a binary of the rectangle's bytes, a `compressed`
field's decoded by `erx_draw_image`. A field type is a closed set whose
walk code is the generator's, so a message adds no code. A failed
decode gives the errno and the offset, from the message's letter, of the
field that failed, or 0 for an empty input or an unknown letter: a
field that runs past the end, an empty or inverted rectangle, and codes
that cross a row's end or stop short are `einval`; an id the depth
function answers `none` for is `enoent`. The C twin frames a
`compressed` field with a function the program that links it provides,
`erx_draw_cload_frame`, which is `cloadmemimage`'s walk.

Generation fails for a second `draw` declaration or one outside
`formats/draw.txt`, a member other than `message`, a field outside a
message, a duplicate message name, letter or field name, a letter that
is not one printable byte, an unknown field type, a reference to a
field that is not an earlier one of the named type, and a count that
counts two fields.

### Theme

`theme.txt` holds the one `theme VERSION` declaration of the desktop's
visual facts ([The theme](design-desktop-programs.md#the-theme-one-declaration)):
the spacing unit and hairline, the fonts and the code points rasterised
from each, the type roles, the spacing scale, corner radii, shadows, the
colours of each palette (one value for each member of the manifest's
`mf_display_palette`), contrast requirements, the icons and their sizes,
and one transition for each member of `ui_transition`
([Motion](design-desktop-programs.md#motion)). Its members, all at
two-space indentation, are rows of these families; each family's names
have one namespace, a name is a lower-case letter followed by at most 62
lower-case letters, digits or underscores, and no member takes a quoted
token. `unit`, `hairline`, `space`, `radius` and `icons` appear exactly
once, `font`, `role`, `color` and `shadow` at least once. Every length
(`PIXELS` below) is in logical pixels, which a renderer multiplies by
the window's scale.

| Member | Meaning |
| --- | --- |
| `unit PIXELS` | the spacing unit, on whose grid every role's line height lies |
| `hairline PIXELS` | a separator's width |
| `font NAME DIRECTORY WEIGHT FILE...` | a font: its directory beneath the root, and the TrueType file of each weight it has, `regular`, `medium` or `semibold`, each at most once |
| `range FONT LOW-HIGH...` | the code points the glyph step rasterises from FONT, in upper-case hexadecimal, ascending and disjoint; each font has exactly one |
| `role NAME KEY VALUE...` | a type role, exactly one for each member of `ui_role` (`formats/ui.txt`), so every role a widget's text takes has a face and no row names one it cannot take: `font`, a declared font; `size` and `line`, pixels; `weight`, one the font has; optionally `figures`, `tabular` or `proportional` (the default), and `color`, a declared colour (`text` by default) |
| `space NAME UNITS...` | the spacing scale, in whole units, none wider than 4,096 pixels |
| `radius NAME PIXELS...` | corner radii; `window` is declared and 0 |
| `shadow NAME X Y BLUR PERCENT` | a shadow: its offset and blur in pixels and the opacity of its black in percent |
| `color NAME RRGGBB...` | an sRGB colour in each palette, in six upper-case hexadecimal digits, in the value order of `mf_display_palette` |
| `contrast FOREGROUND on BACKGROUND... RATIO` | the least contrast ratio, one decimal from 1.0 to 21.0, that FOREGROUND has on each BACKGROUND, in every palette |
| `icons PATH sizes SIZE...` | the icons' definition file and the pixel sizes they are rasterised at, ascending |
| `transition NAME MILLISECONDS CURVE` | a member of `ui_transition` (`press`, `state` and `reveal`, each started by the change Motion names), its duration, 1 to 250, and its curve, `linear` or `ease_out` |

A `contrast FOREGROUND on BACKGROUND... RATIO` row is a check, not an
output: the generator computes each pair's ratio in every palette by
WCAG 2.2's definitions of "contrast ratio" and "relative luminance" (W3C
Recommendation 12 December 2024,
`https://www.w3.org/TR/2024/REC-WCAG22-20241212/`), and a pair below its
ratio fails generation with both names and the ratio measured. Fonts,
ranges and icons are the glyph step's inputs; none of them is emitted.

The generator emits the same constants for each renderer, in its own
form: `erx_theme` in `erx_memdraw` for the Erlang renderer, `erx/theme.h`
for the display and `erx-lvgl`, and `theme.ts`, CSS custom properties,
for the web client. Each family is a set, listed in name order in every
output, so the order of the rows changes no byte. Generation refuses
anything outside the families' forms and bounds: a family missing or
repeated against its declared count, a name declared twice, a reference
to an undeclared font or colour, a line height off the unit's grid, a
`radius window` other than 0, a transition for a name outside
`ui_transition` or a member without one, and a contrast that does not
hold.

### Input records

`formats/input.txt` holds the one `input` declaration: the binary form
of a driver's record, `record()` of [Input
events](design-display.md#input-events), in which a driver in another
domain serves its device's records as a file and the display's reader
of that file reads them ([The display
device](design-display.md#the-display-device)). Its members, at
two-space indentation, are the kinds of record; the fields of a kind are
at four spaces beneath it, in wire order after its tag.

| Member | Meaning |
| --- | --- |
| `record NAME TAG [WORD...]` | a kind: its tag, one byte from 1 to 255, and its term, `{NAME, WORD..., Field...}`, or the bare `NAME` when it has no word and no field |
| `field NAME @TYPE` | a field: a root `scalar` or `enum`, whose base integer is its width and signedness on the wire, and whose range or members are what it admits |

Every record is the same size, one byte for the tag and the fields of
the largest kind, so a stream of records splits into records by length
alone and a bad record of the right length never moves the next; a
writer that loses or adds a byte shifts every record after it, which
only the serving domain can do and which gives it no reach beyond the
records it may send anyway. A record is its tag, its fields in order,
little-endian, an enum field as its member's number, and zero bytes to
the size. The fields' types are scalars and enums in the same file
whose ranges name the `input_` limits, so a bound has one home, and a
limit widened past a scalar's wire width is refused. The term rules are
those of the program protocol's `union` and the tag those of the web
protocol's; the form is a declaration of its own because neither
grammar has a fixed-size encoding or fields typed by root scalars.

The generator emits `erx_input_codec`, in the `erx` application, so a
driver of any domain writes the form and the display reads it: the one
type of a record, the bounds check every record is held to, the encoder
and a stream decoder that keeps a trailing partial record for the next
read, and the clamps a driver applies to its device's values before it
makes a record (`rel/1`, `wheel/1`, and `axis/3`, which spreads a device
axis's range across `input_axis`), so no driver restates the bounds. A
record whose tag no kind has, whose padding is not zero, or whose field
is outside its type's range or members is dropped and counted, never
decoded; the decoder makes no atom.

### Web protocol

`protocols/web.txt` holds the one `web VERSION` declaration of the web
protocol ([design-web.md](design-web.md#the-protocol)) and the root
limits named `web_*`, its bounds. Each member declares one type:
`integer NAME u8|u16|u32 [min N]`; `bytes NAME MAX [exact]` and
`text NAME MAX`, a `u32` length and the bytes, which TypeScript reads as
a `Uint8Array` and as a `MachineText`; `digits NAME MAX`, a decimal
integer in its one canonical form (`0`, or digits without a leading zero
after an optional minus), which TypeScript reads as a `bigint`;
`backend NAME`, the name of a backend reporter the inspection schema
declares; `ui_record NAME MAX`, one record of the widget format's binary
form, its `u32` length word included, which the widget format's own
readers decode; `list NAME ELEMENT MAX`, a `u32` count and the elements;
`tuple NAME FIELD:TYPE...` and `map NAME FIELD:TYPE...`, the fields in
order; and `union NAME [depth N] [message MAX]`, a `u8` tag and its
case's fields, with one `case NAME TAG [FIELD:TYPE...]` line beneath it
per member, tags from 1 to 255. `boolean`, a `u8` of 0 or 1, needs no
declaration. A MAX is a limit's name or a number from 1 to the largest
`u32`. Validation refuses an unresolved type, a field named `tag` (the
TypeScript discriminant), a type named after an Erlang built-in type, a
cycle of types that passes through no depth union, more than one depth
union, a depth above 8, a depth union whose every case nests, and a
message union that another type names.

A union with `depth N` names itself through its cases' fields. Rather
than expanding the union into N copies, both codecs carry the level as
an argument: a whole message starts at level 1, a recursive case's
fields are a level deeper, and at level N a recursive case's tag is an
unknown tag. A union with `message MAX` is a whole message: at most MAX
bytes, and no byte after its fields.

The generator emits `erx_web_proto` and `web/src/generated/proto.ts`.
Each is a fixed interpreter over a generated table of the declaration's
types, `type/1` in Erlang and `TYPES` in TypeScript, so the two agree on
every layout and bound because they read one table. In Erlang a map is a
map with the fields as keys, a tuple a tuple, a case without fields its
atom and one with fields `{Case, Field...}`; every text is a binary, and
the decoder creates no atom, since each it returns is a literal of the
table. In TypeScript a tuple or map is a frozen object with camelCase
fields, a union of cases without fields a string, and any other union an
object discriminated by `tag`. Both decoders return a value or a
refusal, `{error, {Reason, Type}}` and `{ ok: false, reason }` with the
same reason and type, and never raise on their input; both encoders
refuse whatever their decoder would refuse; the Erlang encoder counts
the message's room as it writes, so a term that shares subterms is
refused at the bound, not after it has been written out. The generated
TypeScript modules share `web/src/wire.ts`, the cursor, refusal and
UTF-8 check, which is a source of its own because it holds no table of
any ABI source. A text decodes as `web/src/text.ts`'s `MachineText`,
whose one outlet is the line escape; the codec keeps the bytes of each
text it makes in a private map, so its encoder writes back only texts
it made, through its decoder or `machineText()`, and no outlet on
`MachineText` is needed.

Both codecs carry the protocol hash: SHA-256 over one line per source,
`PATH SHA256\n`, for `web.txt`, `ui.txt`, `inspection.txt`,
`terminal.txt` and the Unicode data files `terminal.txt` names, in that
order. The generation plan records terminal.txt and its Unicode data among its inputs, so
a change to any of them regenerates both codecs.

### Program protocol

The program protocol itself, its frames, requests, replies, reports and
notices and what each does, is
[design-programs.md](design-programs.md#the-program-protocol)'s, with
the startup message in
[The startup message](design-programs.md#the-startup-message) and the
pipe frames in [design-pipes.md](design-pipes.md#the-program-protocol).
This section owns the declaration language its frame profile is written
in and the two checks generated from it.

`protocols/prog.txt` holds `protocol erx_prog`, the frame profile of a
program's channel, and the root limits named `prog_*`, its bounds. It is
written in the declaration language of `protocols/9p.txt`, the file
protocol's profile, and `tools/lib/erx/abi_protocol.rb` reads both into
one model. Two fixed checks read the one table: `liberx`'s C check,
which a program runs on every frame from its handler, the startup
message first, and the Erlang grammar `erx_prog_grammar`, which the
handler runs on every frame from its program and the command image on
its startup message. Each takes a whole frame and accepts it or names
one refusal; no field of a frame is read before its check has accepted
all of it.

| Member | Meaning |
| --- | --- |
| `version N` | the version every frame carries as its second element |
| `reader c` | the generator also emits the C check and accessors; the members that describe 9P2000.L's bytes (`length`, `packed`, `local`, `errors`, `operation`, `writes`, `check`) fail in such a protocol |
| `frame NAME to\|from TAG [slot] KIND` | a frame to the program or from it: `{TAG, Version, Value}`, or `{TAG, Version, Slot, Value}` with `slot`, `Slot` from 0 to 15 |
| `frame NAME to TAG slot reply REQUEST` | the reply frame, `{TAG, Version, Slot, Value}`: `REQUEST` names the slotted frame from the program, and `Value` is of the reply kind of the request case `Slot` holds; a reply on an idle slot is refused as `range` of `slot`. Every slotted frame to the program is a reply frame |
| `integer NAME BASE [in MIN MAX \| values N...] [except N] [unique] [refers LIST]` | an integer of `u8`, `u16`, `u32` or `u64` within the range or among the values given; `unique`: no two values of the kind in one frame are equal, for a kind that is never itself a list's element; `refers LIST`: the value is the first field of an element of the frame's `LIST` that holds no `refers` value itself |
| `capability NAME` | a capability handle: a `u64` other than `cap_null`, unique as an integer marked `unique` is. A protocol declares at most one unique kind, so one capability kind, used wherever a capability appears, and refuses every other `u64` and an `integer` excepting `cap_null`: a handle has no other spelling to escape the capability walk. A file protocol takes none |
| `offset NAME [in MIN MAX]` | a file offset, FreeBSD's `off_t`: 0 to 2^63 - 1, or within the signed range given when the call takes a negative one, as `lseek`'s relative offset does. Its C value is `int64_t`, never `erx_cap_t`, and it keys no `ascending` list; a file protocol takes none |
| `time NAME` | a time in whole seconds since the epoch, FreeBSD's `time_t`: any signed 64-bit integer. Its C value is `erx_profile_time_t`, a struct that converts to and from no integer, so a time is never passed as an offset or a capability, nor either as a time. It keys no `ascending` list, and a file protocol takes none |
| `text NAME max N [utf8] [refuse nul] [assign] [path] [sum TOTAL]` | a binary of at most N bytes; `utf8`, valid UTF-8 as RFC 3629 defines it; `refuse nul`, no zero byte; `assign`, at least one byte before its first `=`; `path`, absolute and normalised: a leading `/`, no empty, `.` or `..` component, and a trailing `/` only in `/` itself; `sum TOTAL`, its length plus one counts towards `TOTAL` |
| `total NAME MAX` | at most MAX in one frame over the texts marked `sum NAME`: for `argv` and `env`, their bytes with the NUL that C adds to each, as FreeBSD counts `ARG_MAX` |
| `tuple NAME KIND...` | a tuple of the kinds in order |
| `list NAME KIND max N [ascending]` | a proper list of at most N elements; `ascending`, strictly increasing in Erlang's term order of each element, or of its first field when it is a tuple, which is an integer or an atom |
| `map NAME`, with `field NAME KIND` and `optional NAME KIND` beneath | a map whose keys are the atoms named: each `field` present, each `optional` present or absent, no other key |
| `union NAME`, with `case ATOM [=ATOM...] [KIND...]` beneath | a case without fields is its atom; one with fields is a tuple of its atom, its literal atoms (`=ATOM`) and its fields; a tuple's arity and leading atoms select its case, whose C name joins its atoms with `_` |
| `reply KIND`, beneath a case after its `case` line | the union of the replies to that request case, which generation refuses unless it is a union, so the capability walk reads its cases. Each case of the union a reply frame's request carries has exactly one; no other union has one |
| `boolean`, `signal`, `errno` | built in: `true` or `false`; a signal's protocol name ([design-programs.md](design-programs.md#signal-numbers)), `sig` and its name in `abi/signals.txt`, for each signal a program may name, never an alias or a reserved number; an error's name in `abi/errno.txt`, never an alias. Each named number is an atom read as its number, an `int32_t` in C, and the C check reads the names from the profile's `tables` |

A bound is a number or a limit's name. A descriptor number, a signal of
a set, a read end's index and a write end's number appear at most once
because each list that names them is `ascending`: no uniqueness rule and
no table of seen keys is needed, and the generated builders, which sort
those lists, keep the session from having to. Only a capability value,
which appears in many places of one frame, needs `unique`, and only
`{dup, Fd}` needs `refers`, which refuses a `dup` of a `dup` and a `dup`
of a number the message lacks. A request's reply is typed by the
request on its slot, so two requests may reply with cases of the same
atom and arity.

Generation fails for a cycle among a protocol's kinds or a nesting
deeper than 16, the C check's stack; two cases of one union that the
same arity and leading atoms select, or whose C names collide; an
`ascending` list whose elements have no integer or atom key; a `unique`
kind that is a list's element; a `refers` to a list whose elements are
not tuples, whose key ranges over more than 4,096 values, or which can
occur twice in one frame; a range outside its base or with MIN above
MAX; a repeated value of `values`; a `sum` that names no `total`; and
two frames of one direction that the same tag and slot form select. A
new member of the language, or a use of one that generation refuses,
joins only with the first frame that needs it, with its C and Erlang
checks, a boundary mutation and a seeded fault, as each member above
has, and, when the scratch holds what it adds, the bound in input bytes
that keeps `erx_prog_scratch_bytes` sufficient.

**Encodings.** Both checks judge the value, not its encoding, within the
channel's wire grammar: the tags of the funnel's grammar
([design-domains.md](design-domains.md#the-funnel)), which `erx_etf_next`
reads, so a frame has no compressed term and its atoms are in UTF-8
only. Within that grammar the C check accepts every encoding that
`binary_to_term/1` decodes to the same term, and the Erlang grammar sees
only the decoded term. A frame is at most `prog_frame_max` bytes, a
bound which the C check, the port driver's copy and the builders hold to
the encoded bytes. Two list encodings do not follow the nesting of the
term they decode to, and the C check and every iterator read them as
ERTS's decoder does: an empty `LIST_EXT` is its tail, taken in a loop
without a level of the stack, so wrappers change neither the term nor
its depth; and one proper list may span `LIST_EXT` and `STRING_EXT`
segments, whose length and `ascending` order count across all of them.

**The C check.** `liberx/erx_profile.c`, with `include/erx/profile.h`,
is the one interpreter of the tables the generator emits for a protocol
with `reader c`. From `prog.txt` the generator emits the table and the
typed functions over it (`include/erx/prog_profile.h`,
`liberx/generated/prog_profile.c`): a check per frame from the handler,
`erx_prog_check_start` for the startup message and
`erx_prog_check_to_program` for every later frame, which takes the
request case each slot holds (`busy[S]`), tells a report from a reply by
its envelope and checks a reply against the reply union of its slot's
request (the startup message has its own check alone, so a later
startup message is refused); the scratch bound `erx_prog_scratch_bytes`; and a struct per
frame with an iterator per list.

The check walks the frame once with `erx_etf_next`, never recursing: its
stack is a fixed array of the profile's depth, which the generator
computes from the acyclic table. The scratch holds only the values of
`unique` kinds, sorted once the walk ends, and two bitmaps over the key
range of each `refers`. Its size grows with the frame, not with the
worst case, and always suffices, because a `unique` kind is never a
list's element, so each value is an item of at least two bytes.
`erx_prog_scratch_bytes(len)` computes it with checked arithmetic and
answers `SIZE_MAX` when it overflows, as `erx_etf_scratch_bytes` does;
with less, the check refuses with `scratch` and writes nothing past it. The
check is pure: it reads only its arguments and writes only the scratch
and its outputs, so it builds and is tested on the host.

On acceptance the check fills the frame's struct: each scalar in its C
type, a union of atoms or a signal as its generated enumeration or
number, a text as a pointer into the frame and a length, never
NUL-terminated, an `optional` key with a `has_` flag. A list stays a
view, read through an iterator whose type is its list's own, so one
list's iterator handed to another list's `next` does not compile, and
each `next` checks at run time that the view is its list's. The structs
are small and fixed whatever the frame holds, and since every iterator
comes from a struct the check filled, a read never meets a byte the
check has not accepted. Each view borrows the frame, which `liberx`'s
private copy keeps unchanged while it is used. The generated table holds
static asserts that the check's fixed bounds in `erx/profile.h` hold it,
so a table the check cannot walk does not build.

A capability is `erx_cap_t` in these structs: the strong scalar wrapper
`include/erx/abi.h` makes of `scalar cap`, a struct of one member that
converts to and from no integer. liberx's capability calls take
`erx_cap_t`, so a handle passes from a frame to a call unchanged, and a
handle held as an integer fails to build wherever it is used as a
capability; an explicit `(erx_cap_t){ .raw = value }` is written only at
a boundary where handles arrive as integers. For each union a frame to
the program carries whose cases hold capabilities, the generator emits
the most capabilities one case holds and the walk that names them, so
the executor closes what a report names without a hand-written switch a
new case could miss; a capability nested inside another kind of a case
fails generation, since the walk reads a case's own fields.

**The Erlang grammar.** `tools/lib/erx/abi_emit_protocol.rb` emits
`erx_prog_grammar` as it emits `erx_9p_grammar`, preloaded and calling
only BIFs: a check per direction and frame, total over any term, making
no atom and walking no list past its maximum, the reply check taking a
map from each busy slot to the request case it holds; and a builder per
frame, which sorts each `ascending` list, keeping a repeated key so the
check still refuses it, then checks the frame and its encoded size. A
spawn's planner answers `E2BIG` for every refusal of a startup message
that the strings' size causes (`size`; `length` of an `arg`, an
`env_var` or a list of them; `total` of `args`), and builds the startup message with every capability value
at its longest encoding, so its verdict depends on the spec alone and
the message built later is never larger than the one it checked.

**Refusals.** Both checks name a refusal by the same `Reason` and
`Kind`, the kind being the profile's name of the type being checked:
`size`, `shape`, `version`, `range`, `length`, `utf8`, `text`, `key`,
`no_case`, `order`, `unique`, `refers` and `total`. The C check adds
`malformed`, bytes that are no term of the wire grammar, and `scratch`,
and gives the byte offset of the item it stopped at. What a refusal does
to the program, a status 127 for a frame from the handler and `SIGSYS`
for a frame from the program, is the program protocol's
([design-programs.md](design-programs.md#the-program-protocol),
[A program's end](design-programs.md#a-programs-end)); the one line a
refused later frame writes to standard error,
`erx: FRAME frame refused: REASON in KIND at byte N`, is made of the
table's names and a number only, so no byte of the frame reaches a
terminal, and a refused startup message writes none, since no
descriptor of it was accepted.

**Atoms.** A frame from a program becomes a term in one place: the port
driver `erx_program`'s input task, after the funnel's channel mode, by
ERTS's decoder `erts_decode_ext` with `ERTS_DIST_EXT_BTT_SAFE`, which
refuses an atom the runtime does not hold
([design-runtime.md](design-runtime.md#programs-as-ports)). Every atom
the profile names is a literal of the preloaded grammar module, so it
exists in every runtime image and a frame in the grammar always decodes;
the grammar refuses an atom the runtime holds but the profile does not
name. The chokepoint is the safe decode, since `erx_etf_check` cannot
know the runtime's atom table: a rule of
`tools/lib/erx/chokepoint_rules/` allows `erts_decode_ext` in erXos's
ERTS sources only in the driver's one decode function and only with the
safe flag named in the call.

**Verification.** A differential test runs both checks over one corpus:
frames the builders make up to every bound, mutations generated from
the protocol's model (one for each rule of each kind, each meeting its
rule first in stream order) and hand-written boundary mutations; the
Erlang side decodes with `binary_to_term(Bytes, [safe, used])` and
requires `Used` to be the frame's size. Verdicts agree on every input,
and `Reason` and `Kind` on every single-rule mutation. A host round trip
reads each accepted frame through every generated accessor and writes it
again; hand-encoded fixtures cover each encoding above, segmented lists
and wrappers deeper than the profile's depth. Fuzz targets: the C check
(`tools/fuzz/erx_prog_fuzz.c`, under ASan and UBSan, with the promised
scratch and with half of it) and `erx_prog_grammar` (as
`erx_9p_grammar`'s, checking that the atom count is unchanged). A
translation unit handing one list's iterator to another's `next`, and
the table against a header whose depth bound is one less, must fail to
compile. Seeded faults, each of which must fail its test: a table bound
raised or lowered by one in either check, the grammar without its
`ascending` test, the Erlang side ignoring `Used`, the C check reading
another slot's reply kind, the grammar taking a reply on an idle slot,
the C table naming an errno alias, a check that refuses a big integer, an
iterator that ends a list at its first segment, a `next` without its
kind check, `liberx` skipping the startup check, a planner mapping only
`size` to `E2BIG`, and the port driver without the safe flag.

## Numeric assignment and versions

The declaration source contains every assignment literally. Generation
never renumbers a symbol because a declaration moves or another symbol
appears. Zero is the null capability, success status and an absent value
only where the owning field explicitly gives it that meaning. Calls and
object kinds start above zero; bit positions start at zero. Separate
enumerations can reuse numbers; names and numbers are unique within the
namespace whose decoder interprets them.

Existing normative assignments in a subsystem contract are preserved.
An unassigned value is chosen once in the declaration, using the lowest
available value in its namespace unless the architecture or an external
protocol specifies it. Gaps carry no compatibility promise. External
values, including POSIX errno, signals, ELF and hardware values, come
from their pinned authoritative source and are checked against it.

Capability rights, default/pass sets and transfer masks use the kernel's
32-bit `erx_rights_t`; a bit position above 31 or a mask outside that
width fails generation. A wider call register carries its zero-extended
value, and decoding rejects nonzero upper bits instead of silently
truncating them. This does not change the 64-bit capability value, which
holds a slot and generation rather than a rights word.

The boot formats' magics, versions, flags and kinds are declared in
`erx_abi.txt` beside their layouts, and the root slots and reserved
capability values (`cap_self`, `cap_self_thread`,
[Objects and capabilities](design-kernel.md#objects-and-capabilities))
in `kernel.txt`. `pack_version` names the index and file hash, BLAKE3
with a 32-byte output. A root slot number is not a capability value: the
root extension of the boot information page, derived from the `cap`
lines, supplies each value with its generation, and the optional
previous-crash capability is null when no record exists. The machine
page's layout is in [The root task](design-kernel.md#the-root-task), and
the device-secret page's in
[Device secrets](design-platforms.md#device-secrets); the public HMAC
labels that derive the device and sealing secrets are `bytes`
declarations of `kernel.txt`, without a terminating NUL.

A versioned record's version is one `limit` constant whose name ends in
`_version`, such as `pack_version` or `crash_version`; its writer stores
that constant in the record's `version` field. A `layout` line has no
version of its own. Each versioned reader accepts its exact supported
version, with a diagnostic on any other value. An ABI or format change
replaces the declarations and all consumers together; it adds no
migration path or reader for an earlier erXos encoding.

## Boot-image representations

The pack header, its entries, the boot locator and the image manifest
are `wire_le` layouts of `erx_abi.txt`; their widths and limits are
those of [the boot-image contract](design-kernel.md#the-boot-image). A
hash field is a byte array holding BLAKE3's output in its own byte
order, never an integer.

The canonical index is the header, the entry array immediately after
it, then the string table immediately after that array. File data
starts at the first 4,096-byte boundary after the strings, where the
index run ends, which the index hash covers with its own field read as
zeros. Each file run, which its entry's file hash covers, is the file's
data followed by zeros to the next page boundary. The entry count
determines the entry array's size, and the offsets must equal these
derived values, so no legal data offset can overlap either index table.
The archive ends at the first page boundary at or after the last
entry's data. Padding bytes are zero, and the writer orders paths by
their unsigned bytes without locale or Unicode normalization.

The boot locator's place in the first stage is the architecture
binding's ([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)),
and its rules are those of
[the bootable file](design-kernel.md#the-bootable-file).

An image manifest's base alignment is a power of two at least one page:
a position-independent image uses the maximum of the page size and its
ELF load-segment alignments, representable in `u32`; a fixed image uses
the page size. The normalized origin of a position-independent image is
its first load address rounded down to this alignment, so an equally
aligned mapped base preserves every segment's load-bias constraint. A
fixed image keeps its original addresses. Its segment array immediately
follows the prefix. An image protection encodes read, write and execute
at bits 0, 1 and 2, but the field accepts only read, read/write and
read/execute. Counts, ranges, protections and mapping policy follow
[image manifests](design-kernel.md#image-manifests); generated structural
readers do not replace that image validator.

### File-prefix exclusion

Strict byte sorting and an adjacent-prefix comparison do not alone
exclude a file used as a directory, or an empty directory with an entry
under it: `a`, `a-foo`, `a/b` are strictly
sorted. The validator uses a bounded stack of candidate entry paths, of every kind,
represented by their entry indices into the immutable archive.

For each validated current path, compare it with the top candidate. If
the candidate is a prefix and the following byte is `/`, refuse the
archive. If the candidate is a prefix and the following byte is below
`/`, keep it: a descendant can still appear later in byte order. In every
other case pop it, because sorted order has passed the entire interval
of its possible descendants, and repeat. Push the current entry after
these comparisons. The strict-order check already excludes equality.

Every retained candidate is a strict byte prefix of the next one, so the
stack has at most the maximum path length, 4,096, entries. Each entry is
pushed and popped at most once. Comparing a popped entry costs at most
that entry's path length; a retained comparison costs at most the current
path's length. Total comparison work is linear in the sum of path
lengths. The 16 KiB of index scratch is supplied explicitly by the caller,
never placed on the kernel stack or sized from an unchecked count. The
validator allocates nothing and performs no recursion.

## System-manifest representation

The system manifest's complete meaning is
[the system configuration contract](design-system.md#the-manifest);
`abi/manifest.txt` declares its byte representation, every record's
fields, offsets and closed values, and the `manifest` reader over them.
This section states the rules that representation keeps.

The manifest is a fixed header, fixed-record arrays and a final string
table, in little-endian integers. Arrays are named by file-relative
spans (`erx_mf_span_t`, an offset and a count) and strings by
string-table-relative references (`erx_mf_str_t`, an offset and a byte
length). Indices refer to the named top-level table, never to a native
address, and a nested span identifies complete records within its named
top-level array, not an independently serialized duplicate.

The source describes every record a reader can return, every array's
maximum count, and every string's required class. A reader has no
opaque fallback for an unknown principal, device, facet, image or grant
record. The absence of a declaration is not an empty implementation of
that feature. Every configuration field in the system contract has one
represented location before the packer can claim to serialize the
configuration. The generated host report reads that same validated model
and cannot supply configuration to a boot.

Structural decoding and policy checking have different error classes.
An out-of-range span is a decoding error. A well-formed assignment of
one device to two holders is a configuration error. The latter cannot
produce a packed manifest merely because all record offsets fit.

### Types, limits and references

`erx_share_t` is the wire representation of `erx_grant_t`, not a
percentage, weight or second scheduling mechanism: the exact quota and
period in nanoseconds and CPU set which the kernel enforces, with the
scheduling hints and urgency bounds the scheduler contract defines.
`ERX_QUOTA_NONE` is no quota and zero quota means no CPU time. Period,
CPU-set, capacity, urgency and flag validation use the scheduler's
declared limits. Resource comparisons use exact integer rationals; no
floating-point calculation rounds an overcommit down. A disabled
sub-space grant is all-zero bytes and is legal only when its enclosing
limits record does not enable sub-spaces.

The manifest's size, its string table's and each record table's counts
have declared ceilings. These are decoding ceilings, not resource
grants: the configuration's `max_domains`, quotas and byte-budget checks
impose their own limits, and no decoder allocates from a count before
checking both its table ceiling and the complete file extent. The file
length equals the end of its string table; there are no hidden trailing
records, and padding is zero. Strings have no implicit NUL. A domain's
argument and environment strings together fit the boot-information
page's string budget after its node and peer names. NUL-separated
vectors end each element with NUL, contain no empty environment name,
and use the empty byte string for an empty vector; environment names
are unique. Argument bytes stay inert until the runtime consumes them,
and are escaped where they are displayed under their source.

`mf_none`, `0xffffffff`, in a domain-reference field names the system
domain; other values index the configured-domain table. This is a
manifest reference, never a kernel capability or a live domain id. An
absent optional index uses the same value only in fields whose type
permits absence, and a field cannot use both meanings. Every other index
is zero-based and names a present record. Index values are assigned
after canonical ordering.

### Machine header

The header holds the machine-wide values and a span for each table; the
tables are packed in their declared order, each at its first alignment
boundary after the one before, with `strings` last. `root_memory` is
nonzero and page-aligned. Table capacities are 1 through 65,536, except
that `max_domains` may be 0 when no domains are configured, and
`system_reserve` is 1 through 1,000. The system grant has a positive rate and a
nonempty CPU set, the lane is a power of two within the lane contract,
and queue, peer-held and baseline limits are positive and satisfy their
admission constraints. The selected platform must provide every CPU and
unit the configuration requires. A root configuration that cannot
create and run its own threads fails the complete plan, even if no
configured domain is present.

Every system-domain thread runs in the runtime group `system`. The
kernel creates it uncapped and starts the first root worker there; the
root entry applies `system_share` before starting other threads and
creates `users` from `users_share`. The root worker never changes group.
Service domains have child groups under `system`, whose direct runtime
threads share the aggregate grant without an independent cap.
`system_reserve` limits the normalized share assigned to those child
groups; it is configuration headroom, not CPU supply promised within a
time window.

The baseline is the system runtime's own fixed memory requirement,
including its queues shared across clients. The reservation is derived
by the production admission planner from the capacities, the bounded
per-domain state, connection-control state and configured facets; it is
not trusted because source text names a number. Their sum, the root's
objects and tables, principals' budgets and permanent device
reservations must fit `root_memory`. Dynamic admissions and later facet
grants still recompute their incremental charges before changing state.
A system runtime's total peer-held limit is checked from `max_domains`
and `peer_held`, within that reservation, rather than borrowed from a
user's runtime defaults.

### Principal, domain and limit records

Every name is a system identifier. A principal's `default_limits` and
`ceiling_limits`, and a domain's `limits`, index the domain-limits
table, whose `runtime_limits` indexes the runtime-limits table. Named
limit records let several domains share an explicit configuration
without packing a second copy of its grant or retaining a hidden runtime
default. A source override produces a complete named record; readers do
not apply inheritance or merge maps. Lane-class records supply
configured defaults when policy constructs a new specification; each
packed domain-limits record already has its resolved lane size. They
cannot change a configured domain at runtime.

`threads`, `objects`, `mappings` and `band` are Fiasco's
([design-fiasco.md](design-fiasco.md#memory-and-budgets), FD14 and
FD15). `band` is one of `driver`, `interactive` and `app`; the bands
above them belong to the root task's own threads and have no name here
([design-fiasco.md](design-fiasco.md#bands)). The domain library hands
the four, with the grant's `cpuset` and `slice_us` and the band of the
domain's sub-spaces, to the root in the Fiasco backend's root-only form of the
domain's space create, and the root bounds by them what the domain can
make it hold and starts the domain's threads at the band's base
within the `cpuset`, so the CPU set has one source on both kernels. They
live in the limits record, not the configured-domain row, so that a
session takes them from its template's limits as it takes every other
limit, an app's session from the manifest's `limits session` record,
except its band: the domain library plans an app's session in the `app`
band whatever that record names, as it plans it with the `memory` of the
app's entry, so an app's untrusted code never runs above an interactive
domain. Nothing above the domain
library reads them, and they leave the record with Fiasco, since erXos's
kernel bounds a domain by its budget and its grant alone.

Defaults and ceilings have different purposes. Omitted request fields
take their default value; an explicit request may exceed a default but
cannot exceed its ceiling. The complete default record itself must fit
the ceiling. Memory sizes, counts, queue bounds and runtime-limit fields
are compared in their declared units; enabled domain flags must be a
subset of the ceiling's flags. Grants use their typed attenuation
predicate: CPU-set containment, rate and urgency ceilings, permitted
features and valid placement, rather than treating a period or CPU
position as an ordinary monotonically increasing bound. Configured
service CPU grants use their manifest placement under `system`, not the
principal's user CPU ceiling; the principal still bounds their memory
and other per-domain limits. The principal's total budget and quota
checks apply in addition to every per-domain ceiling.

### Runtime-limit projection

`erx_runtime_limits_t` is embedded by value in both `erx_dom_spec_t` and
`erx_boot_info_t`. For a requested or configured domain, normalization
takes its values from its resolved runtime-limits record, and the
peer-held and aggregate limits from its domain-limits record, dropping
the manifest's profile name and indices. For the system domain it takes
them from `system_runtime_limits`, `peer_held` from the header and the
aggregate limit from the checked admission calculation. This is a
generated projection from those declarations, not a second
independently defined set of defaults. The planner verifies the entire
resulting value and places it in the boot-page plan before the first
thread is started.

Native runtimes receive the same record and validate its
representation; they do not claim to run an Erlang funnel they do not
implement. The boot-page reader checks this record together with every
other page field. ERTS installs it as one immutable startup value before
creating its bounded runtime structures or accepting peer input. A
missing limit is an invalid page, not an unknown value interpreted as
unlimited. The system manifest remains private to the system domain;
another runtime learns only its own projected limits through its
read-only boot page.

### Domain identity and placement

A domain is a `service` or the `secret` domain. A session template is no
domain row: the `sessions` table holds one record per template, in
principal order and at most one per principal, with its principal and
limits, its runtime and release as a domain row has them, and its
arguments and environment (property 14 of
[design-system.md](design-system.md#the-manifest)). Nothing in the boot
order, a unit, window, service, facet or introduction indexes it, and a
partial boot has none. A domain-limits record that enables `SPACES`
supplies the sub-space group's grant; the rights remain installed by the
domain library's plan, not by a reader.

`runtime` is an executable boot-image entry. `release` and
`release_files` identify a nonempty contiguous run in that image. All
indices and the sum defining the run are checked against the already
validated boot image before policy checking. The secret domain has no
crash area and is the unique domain whose run carries the seal mark.

The principal grant describes its CPU cap within `users`. Configured
service domains receive their CPU grants under `system`, while their
memory budgets remain charged to their principal, as the system contract
specifies; a principal record does not move a service's group under
`users`. The domain plan derives its typed CPU-parent selection from the
authenticated creation origin: configured-manifest row, admitted
principal request or native partial-boot row. The
[domain-specification contract](design-system.md#the-domain-library)
binds that origin to the checked row, carries it into the domain record
and makes application use the parent the plan selected. An external
creation request cannot supply origin or parent fields.

### Devices and partition windows

A unit's `holder` is a domain reference. Its device span names a
nonempty run in the device table, and the unit spans cover that table
once, in order, without a gap or shared record: device ownership exists
in the unit alone, and a device record carries no second holder field.
The checked platform placement record supplies the unit, selector,
role, compatible string, confinement and hostile mark. The source
configuration assigns the unit to a holder; it cannot override those
platform facts. Roles are platform-declared facts for manifest checks,
not a kernel driver dispatch. `compatible` and `placement_key` are
nonempty UTF-8 strings without NUL or control characters, the placement
key resolving to the selected platform's immutable record.

A device-tree device's `base` and `size` are the physical address and
length of its node's first `reg` entry, and `line` is its first
interrupt, numbered as the platform's interrupt controller numbers the
lines a device raises. Line 0 is no line: a node that raises no
interrupt, as the Raspberry Pi 4's RNG200 does, has `line` 0 and shares
no line with any device. The platform record carries all three for every
device-tree device, and the image suites check them against the device
tree QEMU builds and the board's tree. A framebuffer row is the
exception: its path names the node under which the firmware adds its
framebuffer, `/chosen`, its `line` is zero, and its page-aligned `base`
and `size` are the window the framebuffer must lie in, which the
manifest check refuses where it overlaps another row's register window;
the firmware's device tree supplies where in the window the framebuffer
lies, and its geometry, at boot
([design-device-tree.md](design-device-tree.md#facts-into-records)).

`clock` is the frequency in hertz of the clock the device's driver
divides rates from, the rate of the first entry of its node's `clocks`
(a fixed clock's `clock-frequency`, or for a clock the firmware sets,
the rate the board's firmware configuration fixes). Whether a device has
one is a fact of its kind, the `clocked` column of
`include/erx/device_kinds.h`: a PL011 divides its baud rate from it, and
an I2C or SPI controller of the BCM2711 its bus clock from the core
clock ([design-header-io.md](design-header-io.md#clocks)). Only the board
knows the rate, so a row of a clocked kind carries a nonzero clock,
every other row's clock is 0, and the manifest check refuses a row that
disagrees.

A PCIe function, selector 2, names its host bridge by device-tree path
and its bus, device and function. `base`, `size` and `line` belong to
the selector's `dt` case and are inactive for a function, since
configuration space gives them, except `line` at a place a closed
bridge's platform record lists, where it is the INTx line the bridge's
`interrupt-map` routes for that place's pin
([design-pcie.md](design-pcie.md#the-closed-bus)), and a function behind
a closed bridge lies at one of its listed places, which the manifest
check proves. A host bridge's row carries the closed flag when its
platform record lists every place on it, and then those places, each a
bus, device, function and pin: its `places` span names them in the
manifest's `places` table of `erx_pcie_place` rows, and every other
row's span is empty. The platform record spells them in the record's
own shape, `"flags": ["closed"]` and `"places": [{"bus": 1, "device":
0, "function": 0, "pin": 1}]`; any flags field of a platform row may be
written as a list of its bits' names or as their number. A listed place
lies below the root port, on bus 1 or above, with a pin INTA (1) to
INTD (4), and no place is listed twice; that the places lie within the
bridge's bus range is the tree's fact, which the boot reads. A
device's `dma_limit` is a CPU address, exclusive, 0 for none, which
the packer copies from a bridge's unit into each `pci` row behind it, and
the function's DMA facts are cut at it
([design-pcie.md](design-pcie.md#dma)). A device's `power_off_ms` and
`power_on_ms` are the off and on times of the platform record's power row
that names it, 16 bits each, 0 and 0 for a device no power row names, which
the root writes into the device's physical record
([design-bluetooth.md](design-bluetooth.md#the-power-line)). On a platform with an MSI frame,
QEMU `virt` and the Raspberry Pi 5, the manifest's platform part
carries `msi_frame`: the frame's base, the interrupt id of its first
line, the count, the row of the bridge it serves, its doorbell
register's CPU address, the first line's data and its start writes, for
the backend that may not read the frame's own registers; the doorbell's
bus address is the tree's fact, which the root derives at boot
([design-pcie.md](design-pcie.md#the-msi-frame-on-fiasco)).

A platform's firmware requests reach the system domain in the manifest
beside the device records, each as a record of its name, its belonging
(a device row, or the machine), its tag and its argument words, in the order of
the platform record's `firmware_requests`, so a row's index is its
position among those of its device or the machine; the generator derives
a machine row's tag and argument from its reading, and a device's off
and on rows from its power row's power line, and checks every device
row against its tag's declaration in `abi/formats/vc_property.txt`
([design-board-sensors.md](design-board-sensors.md#the-requests)).

Only an unconfined DMA device has nonzero `dma_memory`; its size is
page-aligned and is reserved for that device for the boot. A device's
coherence and DMA range are not in its row: the root reads them at boot
from the device tree the firmware hands over
([design-device-tree.md](design-device-tree.md),
[design-device-dma.md](design-device-dma.md#device-addresses-and-reach)).
The packed marks do not establish actual confinement: the device service
still verifies the machine before assigning the unit.

A window, an image and a device-valued facet parameter name a placed
device in one spelling: a device-tree device by its node path,
`"/virtio_mmio@a003e00"`, and a PCIe function by its place, its host
bridge's node path and its bus, device and function joined by colons,
`"/pcie@10000000:0:2:0"`, which no node path can be, since a node path
has no colon. One resolver in the manifest check reads both, and the
packed row names the device-row index either way.

A window grants its holder one partition of a medium. `abi/manifest.txt`
marks each window role a configured domain may hold `configured` and
each role whose window grants write `writable`; the manifest check
reads `configured` and the block driver `writable`. A window row states
no rights: the block driver serves a window of a `writable` role read
and write and any other read alone, so the role is the one source of a
window's writability. Both fail closed: a role that carries neither is
the slot writer's and read-only. A
fixed-medium role's sectors come from the medium layout (`medium.txt`),
and a `system` window's are those of the system partition of the slot
that the boot value names, so an `unknown` boot gives none. A `drive`
window names no partition: it lies on a `usb` or a `block` device's row,
its `drive` names a drive, `diskN`, numbered across the machine, and it
covers whatever medium the drive holds, whole; every other window names
no drive, `mf_none`
([design-drives.md](design-drives.md#manifest-rows)).
A manifest has at most one `system` window. No
record contains a caller-selected sector range. Role/holder checks
restrict boot partitions, system A and B and the records to the slot
writer, the `system` window to the storage domain that serves `system`
and the server of the service named `system_service`
([design-storage.md](design-storage.md#the-system-tree)), and data and
FAT to their storage holders. These are private grants, not a global
device namespace.

### Services, facets and their parameter schemas

A service's `server` is a domain reference: a configured domain's
index, or `mf_none` for the system domain. A facet's grantee is a choice
on `grantee_kind`: `system`; `domain`, a configured domain's index; or
`session`, a session template's index, written `@session.PRINCIPAL` in
the source. A service's interface number names a declaration in
`abi/services/`; the packer checks the selected server's verified
release catalog actually supplies that interface, so the manifest cannot
invent a service by giving it a plausible name. A service's public name
is scoped to its server and a facet's to its grantee. Source aliases are
unique within their record kind and references use those aliases; an
optional `name` property supplies the public name, defaulting to the
alias, so two servers may each serve a `files` while `@service.ALIAS`
stays unambiguous. An introduction joins two different configured
domains and is unique as an unordered pair; it creates the existing
connection, with no additional capabilities or transitive authority.

Within `service NAME NUMBER`, the members are `operation NAME NUMBER`,
`liveness OPERATION_NAME`, `served_as message|tree`, `served_by
session`, `quantity KEY VALUE` and `parameter NAME NUMBER KIND CARDINALITY BOUND checked_by
HELPER`.

* `served_as` is stated by every interface, so no interface is served
  one way by omission. `tree` marks an interface whose grants are
  `erx_fs` grants of one tree, which the grantee mounts and speaks
  9P2000.L to (`files`, `windows`, `line` and `input`); `message` one served as a
  message facet. It is the one source of that fact: the generator lists
  the `tree` interfaces for Erlang as `?ERX_TREE_SERVICES`, from which
  the domain service serves the system domain's such services as
  `erx_fs` grants ([design-system.md](design-system.md#facets-a-configured-domain-serves)),
  and the manifest check holds every receiver of such a facet to
  `files_max_frame_min` (property 16 of design-system.md).
* A facet row's operations are explicit operation numbers of its
  interface, strictly ascending; a schema revision does not add newly
  declared operations to an existing grant. A tree service's row names
  no operations, since its protocol's messages are its operations, and
  configures its grant by parameters instead.
* A `parameter` declares a typed scope or option value: its KIND, one of
  `u64`, `i64`, `boolean`, `identifier`, `namespace_path`, `domain`,
  `principal`, `device`, `bytes` and `member`; its cardinality, `one`,
  `optional` or `set MAX_COUNT` (a set of `u64` or of `identifier`,
  MAX_COUNT at least 2); its BOUND, `range MIN
  MAX` for an integer, `bytes MAX_BYTES` for text and bytes, `boolean`,
  `member ENUM` naming a gapless enum the ABI declares, or `target
  TABLE` for a reference, with `system yes|no` on a domain reference;
  and the checked helper that consumes it. A set is packed one row per
  element in strictly ascending order: numeric for `u64`, and for
  `identifier` lexicographic over unsigned bytes, a name before every
  longer name it begins. So no element appears twice: the packer sorts
  a set's lines, given in any order, into that order and refuses an
  element twice or past its MAX_COUNT, and the boot view refuses a
  packed set out of order, with an element twice or past its MAX_COUNT.
  The `ble` interface's `parameter
  services 1 identifier set 8 bytes 63 checked_by ble_grant`
  ([design-bluetooth.md](design-bluetooth.md#the-ble-facet)) is one.
  A member value is spelled as
  the member's bare name in the source and reaches the domain service as
  that atom. Inactive fields are zero. Opaque bytes are legal only where
  the service contract defines them as opaque; they cannot encode an
  unchecked scope or nested configuration. There is no term decoder,
  recursive value language or raw function name in the manifest.
* The helper is a qualified symbol of the service's manifest-grant
  checker, resolved against its checked consumer inventory; naming it
  in untrusted configuration creates no helper or authority, and the
  service is unusable by the packer unless that checker is available.
  All of one service's parameters name one helper, and the manifest
  check hands each facet to the checker its service names, never to one
  that picks facets by interface. A missing required parameter, an
  unknown key or kind, a duplicate scalar key, an unsorted or duplicate
  set, an excessive bound, or a parameter without its checked consumer
  fails validation.
* A `liveness` marker names one declared operation. Its request and
  response signature belongs to the service contract and is verified
  against the service's checked consumer descriptor before admission;
  this metadata does not let the watchdog invoke an arbitrary operation
  by number. Liveness records name services whose interface declares
  its liveness operation; all use the kernel watchdog's period and
  cannot extend its deadline.
* A `quantity KEY VALUE` line gives one of a facet row's quantities
  (`max_request`, `in_flight`, `reductions`, `period_ns`,
  `max_heap_size`), positive and at most once each, for the facet rows
  the build derives rather than a source states: an app's rows, which
  [design-packaging.md](design-packaging.md#the-apps-row) derives from
  the `apps` row, take each quantity from their service's declaration,
  and the manifest check refuses an `apps` row naming a service whose
  interface leaves one out; and a session's line, whose grant no row
  states, takes all five from its interface, which must declare them. A
  source's own facet rows state every
  quantity themselves; no declared quantity fills a field a source row
  leaves out.
* `served_by session`, at most once, marks a message interface that a
  session serves as its line to a front end, which the domain service
  grants only on a request naming the grantee and no manifest row grants
  ([design-system.md](design-system.md#a-sessions-lines)). It is the one
  source of which services are lines: the generator lists them, each
  with its quantities, for Erlang as `?ERX_LINES`; the facet-name check
  takes their names as lines; and the manifest check refuses a `service`
  or `facet` row of one. An interface without it is served by the holder
  its manifest `service` row names.

`max_request` is a byte ceiling, `in_flight` a count, `reductions` a
positive share per positive `period_ns`, `max_heap_size` the grant
process's heap bound in words of the grantee's runtime, as OTP's
`max_heap_size` process flag counts it, off-heap binaries included, and
`queue` the resolved byte quota; the packer resolves an omitted queue to
`system_queue`, and no zero sentinel changes its meaning at runtime. The
manifest checker includes each facet's charge in its grantee's admission
reservation.

These declarations supply manifest metadata and validation, not request
execution or a service's callback implementation. The records carry an
operation set and the service's declared scope parameters; the
handwritten scope checker still decides membership and the generated
serving path still authenticates the lane and live grant. No generic
interpretation of a path, pid or parameter mints authority.
Service-specific declarations land with the service contract and are
required before a manifest can name that service.

### Ordering and partial boots

Boot order is the complete permutation of the configured-domain
indices, with servers before clients. The packer uses a topological
order whose ready set is ordered by domain-name bytes. It rejects a
cycle and never emits a partial order. The shell-principal list is a
strictly increasing, duplicate-free list of principal indices, and a
liveness list names each configured target at most once.

A console line's `secure` attribute has no table of its own: the two
fixed lines, the UART that `console` names and the host link, carry it
in the header's flags (`ERX_MANIFEST_CONSOLE_SECURE`, bit 2, and
`ERX_MANIFEST_HOSTLINK_SECURE`, bit 3; the source's `console_secure`
and `hostlink_secure`), set by default and cleared by the source's
`machine` flags; the host link's is set only when `hostlink` names a
path. The console has no other line.

A display record describes one service of the `windows` interface, by
the service's index, so the display's name is the service's
([design-display.md](design-display.md#a-displays-session)). Every
`windows` service has exactly one, whose server is a configured domain
(property 18 of [design-system.md](design-system.md#the-manifest)). Its
policy is a member of `mf_display_policy`, which has a member only for a
window manager the display domain has, so a manifest names no policy its
display cannot start. `idle_dim_s` and `idle_off_s` are the idle times
after which `erx_screen` dims the panel and turns it off, 0 meaning
never, and `idle_off_s` is 0 or at least `idle_dim_s`. The record names
no session, application or renderer, and the reserved chord has no
field here: it belongs to the login design
([design-display.md](design-display.md#risks-and-decisions), 14). The
packed table `windows` holds a medium's partition windows and is
unrelated to the `windows` service interface.

Partial boot is a development mode which replaces configured domains, as
the system contract specifies. Its programs have system-identifier names
and executable image indices; all use the machine's default native
limits and the system principal, and receive no connections. The
partial-boot flag selects it independently of the program list's length
and requires the development flag; `domains`, services, facets,
introductions, liveness and boot order are empty, while the header,
principals, limits and system-owned console units remain checked. A
release manifest refuses the flag, even with an empty list, and without
it a nonempty list is invalid. A partial boot may have zero programs; it
follows the ordinary completion path with all programs already ended. A
full boot runs the complete configuration check, including the unique
vault requirement; the native-program mode does not pretend to start the
absent services.

### Canonical source, packing and checking

`config/<name>.txt` uses the same ASCII token, comment and quoted-string
rules as ABI declarations. It begins `manifest 1`; each declaration
starts at column zero with one of the forms below and ends at the next
declaration. Its two-space-indented properties are unordered, and their
names and types are their record's fields except where the table says
otherwise. References are `@KIND.NAME`, resolved
within this configuration, and `@artifact.NAME`, resolved only against
the packer's verified build-input inventory; literal `system` names the
root domain. String and byte values are a quoted ASCII literal or
`hex:HEX_BYTES`, which carries UTF-8 or opaque bytes while the source
stays ASCII, and the field's validator checks the decoded bytes against
its declared text class and bound. A `share` is a source value expanded
by value into the records that name it, not another packed table. A
facet's `parameter KEY VALUE` resolves KEY against its service's
parameter schema, and repetition is legal only for a declared set.
Numeric operation, key and kind values are derived. Flag and operation
lists are comma-separated declared names or `none`. `args VALUE...` and
`env VALUE...` hold zero or more quoted or hex values without an
embedded NUL; normalization appends a NUL per element and checks
environment keys and the boot page's aggregate bound, and an empty
property line is an empty vector. An executable reference names one
executable entry, a release reference its verified contiguous run, and
an image input a built EROFS artifact; an omitted image salt is empty,
and the fixed EROFS, dm-verity and SHA-256 profile determines the
image's format.

| Source form | Accepted properties and value forms |
| --- | --- |
| `machine` | `flags` flag list; `host`, `console`, `hostlink`, `platform` strings; `root_memory`, `system_baseline`, `max_domains`, `max_connections`, `system_lane`, `system_queue`, `peer_held`, `system_reserve` integers; `system_share`, `users_share` share references; `system_principal` principal reference; `system_runtime_limits` runtime-limits reference; `native_limits` limits reference; `sealing none\|device\|tpm`; `boot_timeout_s` integer, 1 to `boot_timeout_max_s` (3,600), `boot_timeout_default_s` (60) when absent; `system_args` vector |
| `share NAME` | exactly `quota_ns`, `period_ns`, `cpuset`, `capacity_mcpu`, `capacity_first`, `slice_us`, `grace_us`, `base`, `ceiling`, `flags`; integers except quota's optional `uncapped` literal and the flag list |
| `principal NAME` | `memory`, `domains`, `names` integers; `grant` share reference; `default_limits`, `ceiling_limits` limits references |
| `runtime_limits NAME` | exactly the nine non-name, non-reserved fields of the packed runtime-limits record, each an integer |
| `limits NAME` | its packed scalar fields except name, reserved and runtime index; `grant` share reference; `spaces` share reference or `none`; `runtime_limits` runtime-limits reference; `flags` flag list |
| `lane_class NAME` | `lane` integer |
| `domain NAME` | `principal`, `limits` references; `kind service\|secret`; `flags` flag list; `runtime`, `release` artifact references; `restarts`, `restart_period_s` integers; `args`, `env` vectors |
| `session PRINCIPAL` | the session template of the principal its name names, so a principal has one; `limits` reference; `runtime`, `release` artifact references; `args`, `env` vectors |
| `unit NAME` | `placement` string naming a complete checked platform unit; `holder` domain reference or `system` |
| `window NAME` | `holder` domain reference; `device` checked platform-device string; `role` declared role name; `partition` integer; `image` image reference or `none`; `drive` integer |
| `service NAME` | `server` domain reference or `system`; `interface` qualified ABI service name |
| `facet NAME` | `grantee`, `service` references; `operations` list; repeated `parameter KEY VALUE`; `max_request`, `in_flight`, `reductions`, `period_ns`, `max_heap_size`, `queue` integers |
| `introduce FROM TO` | two domain references on the declaration line; no properties |
| `liveness SERVICE` | one service reference on the declaration line; no properties |
| `shell_principal PRINCIPAL` | one principal reference on the declaration line; no properties |
| `partial_boot NAME` | `image` artifact reference |
| `display NAME` | the display of the service whose source alias is NAME, a service of the `windows` interface; exactly `policy`, a member of `mf_display_policy`, and `idle_dim_s` and `idle_off_s` integers |

A `share` is a source value expanded by value, not another packed table


Every required property occurs exactly once. Unknown properties,
duplicates, unbounded values and references outside the selected
configuration fail. An optional source property is optional only where
the owning contract declares a default; normalization resolves that
default before validation. References neither open arbitrary host paths
nor execute commands, and a wrong artifact kind fails. The source cannot
set derived fields: packed offsets, indices and counts, boot-image
indices, platform facts, boot order, hash-tree fields (`root_hash`,
`data_blocks`, `extent`) or admission charges (`system_reservation`)
fail as properties even when their values match what would be derived.
The packer resolves them from the validated boot-image plan, platform
placement records, verified release metadata and its image builder, and
forms one immutable normalized configuration before applying any rule
or writing a byte.

Top-level named tables are sorted by name bytes; service names are
qualified by their server and facet names by their grantee. Unit devices
follow their units, in selector order. Facet operations and parameters
follow their facets, with operation/key/value order inside each facet.
Windows sort by holder, device, role and partition; introductions by
their canonical endpoint pair. Auxiliary order lists follow their stated
ordering. Strings are appended in header/table/record/field traversal
order, without deduplication, so equal source configurations have equal
bytes without depending on a hash table's iteration order. An empty
string is offset zero and length zero and appends no bytes, the same
representation as a zeroed inactive string field.

The checker evaluates every system-manifest property of
[design-system.md](design-system.md#the-manifest), with its property
number in diagnostics. Resource sums include exact principal budgets,
device reservations, table sizes and the system's baseline and worst
admitted-domain reservation. The domain planner is the production
`erx_dom_plan_configured` pure core built for the host; a different
implementation or a placeholder success is not its oracle. Property 12
invokes it for each configured-domain or partial-boot child
specification, in boot order, against a view in which every earlier plan
is recorded, and `erx_dom_plan_connect` likewise for each introduction;
with no child specifications it makes zero calls. Initial-root startup
remains a separate required plan under the resource check, including its
private image memory, stack, UTCB and boot objects; a declared baseline
cannot replace that plan or its charge evidence. If a specification
requires planning and that planner is unavailable, packing fails as
unsupported; a host report can show that unresolved result, but it
cannot turn it into a bootable manifest. The same rule applies to an
unavailable service scope checker or missing image provenance.

The root entry's non-JIT property, the system and seal release runs,
device placement, grants, role restrictions, rescue closure and domain
creation feasibility are checked before the packer's sole publication
path receives bytes. Runtime readers revalidate the complete binary
structure and its relationship to the validated boot image before
returning a view. Configuration authority still comes from the checked
system-release file; a boot argument or a separately compiled descriptor
array cannot supply missing data.

## Verification

Invalid-schema tests exercise duplicate names and ids, include escapes
and cycles, unknown declarations, undefined or cyclic types, generated
symbol collisions, integer overflow, misalignment, holes and overlapping
fields, invalid bits and shifts, unbounded tails, bad references, missing
pass sets, illegal rights, missing call bounds, invalid window effects,
register/UTCB overflow, incomplete mappings, and incomplete sequence
metadata, and in the inspection schema a report layout field or a
`reported` bit named after no attribute of its kind that lists `kernel`,
a field for a `derived` attribute, a `derived` input that names no
attribute of the kind or a `derived` one, and an attribute that lists
two backend reporters for one category. Each
test expects its specific diagnostic and unchanged output files. Parsing arbitrary declaration bytes has its own bounded fuzz entry
point and cannot publish files.

Reader tests use independent byte fixtures for exact field values and
offsets, then compare C, Erlang and Ruby results and error classes. They
cover every prefix truncation, empty and maximum counts, one past each
bound, arithmetic overflow, misalignment, invalid versions/tags, reserved
bits, overlapping/out-of-order tables, invalid references and each string
class. Mutation helpers alter encoded fields without re-encoding or
repairing them. Generated builders and round trips supplement these
fixtures; they are never their sole oracle.

Every production reader has a fuzz entry point in the language of that
reader. C readers run under ASan and UBSan. Shared-field accessors have
separate concurrency tests and do not inherit confidence from wire-reader
round trips. The pack validator tests prefix intervals against an
independent all-pairs path-prefix oracle over bounded corpora, including
punctuation around `/`, maximum-length names and the deepest candidate
stack. Canonical-index tests deliberately move each table into the header,
the other table and file data. Fuzz targets exercise those same production
entry points.

Drift tests edit a generated file, delete one and add an orphan, each of
which must fail the generated tree's stamp. Reordering independent
declarations does not change bytes; changing a numeric assignment changes
all of its consumers. Generated C layouts compile for each supported host
and target, and their `_Static_assert` checks bind the native representation
to the declared offsets. Mapping tests compare external error and signal
numbers against the pinned headers and keep unknown values explicit.

### A complete declaration example

This source describes a sixteen-byte header, a bounded array of two-field
records and a string table. Its explicitly included `inspection.txt` is
an empty ordinary fixture file. It is complete for generation; its reader
checks every record's string reference against the named table.

```text
abi 1
include inspection.txt
layout demo_header wire_le 4 16
  field rows_off u32 0
  field rows_count u32 4
  field text_off u32 8
  field text_length u32 12
layout demo_row wire_le 4 8
  field name_off u32 0
  field name_length u32 4
reader demo demo_header 1024
  table rows demo_row root.rows_off root.rows_count 16 4
  string_table text root.text_off root.text_length 512
  string rows[].name_off rows[].name_length text identifier 63 empty no
  order rows text
```

For one row named `a`, the independently described accepted bytes are
the four little-endian header words `16, 1, 24, 1`, the row words `0, 1`,
and byte `0x61`. The decoded record's name is the binary `a`. Changing
the row's offset to 1 must fail the string extent check. Changing the
schema path to `rows[].missing`, or mixing `rows[].name_off` with
`root.text_length` in that string rule, fails generation before an output
exists. The primitive string-class spellings are `identifier`,
`dt_path`, `namespace_path`, `relative_path` (plain names joined by `/`, none
empty, `.` or `..`, in UTF-8 without C0 or C1 controls), `utf8`, `bytes`, `args` and `env`.

Shared metadata can be exercised independently with this complete layout
inside the same declaration set:

```text
status retired -1 "the record has retired"
layout demo_snapshot shared 4 8
  field seq u32 0
  field value u32 4
  atomic seq load acquire store release
  atomic value load acquire store release
  owner seq producer all
  owner value producer all
  visibility seq internal
  visibility value release
  sequence seq terminal 4294967295 exhaustion @retired recovery new_object
projection demo_snapshot_public demo_snapshot release
  omit seq
  show value
layout demo_elements shared 8 24
  field wall_delta i64 0
  field ready u64 8 count 2
  atomic wall_delta load acquire store release
  atomic ready[] load acquire store release
  owner wall_delta producer all
  owner ready[] producer all
  visibility wall_delta internal
  visibility ready[] internal
```

`atomic seq load release store acquire`, a second overlapping owner of
`value`, a terminal value of `4294967296`, a nonexistent exhaustion
status, or showing a development-only value in the release projection
each fails its specific schema rule. These examples exercise grammar
and representation; they do not substitute for the independent snapshot
protocol tests.
