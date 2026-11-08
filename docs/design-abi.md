# ABI declarations and binary readers

This document defines the declaration language, its validated model, and
the byte representations shared by the kernel, `liberx`, runtimes and host
tools. [Generated interfaces](design-generation.md) owns the wider
generation contract; the subsystem designs own the meaning of each call
and record. `abi/erx_abi.txt`, its explicit fragments and the selected
architecture file are the only machine-readable sources. Tables here
describe that source and are generated once their declarations exist.

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
| `enum NAME TYPE` | indented `value NAME INTEGER` members; every value explicit and distinct |
| `flags NAME TYPE` | indented `bit NAME POSITION` members; every position explicit and distinct |
| `bytes NAME LENGTH` | a fixed byte count, with an optional `value HEX_BYTES` constraint |
| `layout NAME STORAGE ALIGN SIZE` | ordered fields; `STORAGE` is `wire_le`, `shared` or `native`; alignment and fixed prefix size are explicit |
| `variant NAME PREFIX TAG_FIELD TAG_ENUM MAX_BYTES` | a fixed prefix containing the tag and indented `case TAG BODY_LAYOUT` members; each body begins after the prefix |
| `status NAME INTEGER DESCRIPTION` | a signed 32-bit result; zero is success and every error is negative |
| `right NAME POSITION DESCRIPTION` | a distinct position 0 through 31 within the kernel's 32-bit `erx_rights_t` word |
| `type NAME INTEGER` | explicit `rights` and `pass` lists, including an explicit empty pass list |
| `kind NAME INTEGER TYPE` | a creation kind of an object type: its `default` list, within the type's rights, and for a carved kind `carves KIND`, the kind it is carved from, whose default it does not exceed but by `destroy`; `reserved_space` and `reserved_thread` state what the reserved values `cap_self` and `cap_self_thread` carry, and no call creates them |
| `cap NAME SLOT KIND [optional]` | a well-known root slot and the creation kind its capability is installed as, which fixes its object type and rights; `optional` when the boot may leave the slot null. Slots run from 1 without a gap, and the generator derives the layout `erx_boot_root_extension` from these lines, one `cap` field per slot |
| `call NAME NUMBER` | the call metadata and members described below |
| `reader NAME ROOT_LAYOUT MAX_BYTES` | bounded tables and references described below |
| `translation NAME SOURCE TARGET` | a complete directed mapping for one named consumer context |
| `service NAME NUMBER` | a named interface, its operation identifiers and its typed manifest-parameter declarations; callable operations retain the admission contract of the service design |
| `inspection SCHEMA` | the inspection schema, with its units, value types, stopgap reporters, kinds and paths as members described in [Inspection schema](#inspection-schema); exactly one, in `inspection.txt` |
| `trap OPCODE IMMEDIATE` | the architecture's trap operation and its immediate, checked by its binding |
| `reg ROLE REGISTERS` | the comma-separated architecture registers for `number`, `args`, `results` or `preserved`; no duplicate within a role |

The base integer types are `u8`, `u16`, `u32`, `u64`, `i8`, `i16`, `i32`
and `i64`. A record field is `field NAME TYPE OFFSET`; a fixed array adds
`count COUNT`. A `padding OFFSET LENGTH` member represents every gap and
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
ends are inclusive. The generator rejects overlap, out-of-range shifts
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
or an accessor of it does not compile. Its offsets, its record with the
size, alignment and offset assertions, and its field, atomic and sequence
operations go to its own header, `kernel/generated/NAME_impl.h`, NAME
being the layout's name without its `erx_` prefix, which includes
`include/erx/abi.h`. The model derives that path from the name in one
place. From the same declaration the chokepoint rules build one rule per
private layout, `NAME-private` with NAME's underscores as hyphens
([Chokepoint checks](design-kernel.md#chokepoint-checks)): only OWNER
and OWNER's host tests include the header, and no other file defines the
record. OWNER's host tests are the files named after it in the two
host-only trees, `test/fixtures/STEM_*.c` and `tools/fuzz/STEM_fuzz.c`,
STEM being OWNER's base name without `.c`; neither tree is built into the
kernel or an image, so the rule widens to a new test of the owner without
an edit and never to kernel code. A wire layout is a byte format another
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
`root_slot_NAME` constants they produce do. A translation has one
`map SOURCE_VALUE TARGET_VALUE` or `omit SOURCE_VALUE REASON` member per
source value; the reason is a quoted diagnostic and the context decides
whether omission is legal. An unlisted exposed source value fails.

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
  device-tree path, namespace path, UTF-8 text, opaque bytes,
  NUL-separated arguments, and NUL-separated environment entries. Empty
  is a distinct declared option.
* `order TABLE... STRING_TABLE` requires the header followed by those
  tables in that order, each at the first boundary of its declared
  alignment, followed by the string table. Padding is zero. An empty
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

### Inspection schema

`inspection.txt` holds the one `inspection SCHEMA` declaration, SCHEMA
being the `schema` number every inspection record carries
([design-live.md](design-live.md#inspection-records)). Its members, at
two-space indentation, declare units, value types, stopgap reporters,
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
| `stopgap NAME CATEGORY LABEL SCOPE` | a reporter that stands in for the reporter category CATEGORY, `kernel`, `service` or `runtime`; LABEL is the quoted name renderers print for it and SCOPE the quoted statement of what it can see |
| `trace ROW REPORTER` | a row of `erx:trace`'s stream ([design-live.md](design-live.md#tracing)) and the one reporter, a category or a stopgap, that its collector assigns to every event of the row; ROW names a namespace of its own, so the `kernel` row may share the category's name, and becomes an atom of `erx_schema` |
| `kind NAME` | an inspection kind; its `attr` members follow at four spaces |
| `attr KEY TYPE reporters LIST visible CLASS build BUILD projections LIST` | an attribute of the kind, described below |
| `path KIND SEGMENT...` | a path and the kind of its record, described below, with its marks at four spaces |

A value type is a member type, `boolean`, `pid`, `rights` (a set of the
root's `right` names), `object_type` (one of the root's `type` names),
`status` (one of the root's `status` names), or a `@` reference to a root
`scalar`, which is an integer within its range, an `enum`, which is one
of its member names as an atom, or a `flags`, which is the set of its bit
names. No type admits an arbitrary term or an atom from the input: names
a domain reports are `text`. The generator refuses a type nested more
than eight deep, as the web's `datum()` is
([design-web.md](design-web.md#values)). Kinds, attribute keys, stopgap
reporter names, statuses and the atoms of `atoms`, `enum`, `flags` and
the root-backed types become atoms of `erx_schema`, so a reader of a
record refuses an unknown one without making it. A reported value
outside its type, such as a text longer than its MAX, becomes `{error,
invalid}` for that attribute alone.

An attribute names its KEY and TYPE and four required properties, so
adding one never exposes it by default:

* `reporters`, a comma-separated list of the categories `kernel`,
  `service` and `runtime` and the stopgap reporters that may report it.
  A stopgap reporter is listed by its name, only on the attributes it
  answers, so a validator refuses it anywhere else, and always beside
  the category it stands in for, so removing the stopgap leaves the
  attribute declared for that category; a stopgap that no attribute
  and no `trace` row lists fails;
* `visible`, the inspect facets that see it: `any`, every inspect facet;
  `owner`, a facet whose scope covers the path's owner, which for a path
  the machine owns is a facet of scope `all`; `all`, a facet of scope
  `all`; or `system_shell`, only a call presenting the system-shell
  facet;
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
value of TYPE, which is an integer, text or `pid` type; a path has at
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
leading `/`: a pid as `D.N.S`, an integer in canonical decimal and a
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
`erx_schema`. The generator refuses a presentation named `accept`, the
input context's URI ([Presentations in a
terminal](design-display.md#terminal-windows)), or `proc`, `ui`,
`trace`, `login` or `ws`, the web's fixed routes
([URLs](design-web.md#urls)); a presentation declared twice; and two
presentations of one variable segment over the same type, since an
attribute of that type is shown as that presentation.

A stopgap reporter appears in a record as `{stopgap, NAME}`. Its label
and scope come from the schema, so a record carries no free text about
who reported it, and a domain cannot invent a reporter. LABEL and SCOPE,
like a unit's label, are printable ASCII, a label at most 255 bytes and a
scope at most 1,024, and the generator refuses a label equal to a
category's name or to another stopgap's label. A member's name is
neither a category's, a built-in type's, `listing` nor `none`; a text's
MAX is at most 65,536, a record's bound, and an `entries` MAX at most
2^32 - 1. A stopgap reporter stands
for a stopgap component that does the kernel's, a service's or a
runtime's work in its place, such as the Phase 1 backend of `liberx`
counting a budget's pages in the kernel's place
([design-stopgap.md](design-stopgap.md#reporting-a-budget)); replacing
the component removes its declaration, and the attributes it reported
come from the category it stood in for. An attribute lists at most one
stopgap reporter for each category.

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
reader never refuses a report over a value its clear bit disowns. No
report layout names a
reporter or a `partial` status. A field that a stopgap backend counts
only partly has its `reported` bit clear, and that backend names it
through `liberx` in the inspector's own domain; its reporter is the one
stopgap the attribute lists for `kernel`
([design-live.md](design-live.md#inspection-records)). The topic enum,
the `flags` and the layouts are ordinary root declarations of
`erx_abi.txt` and need no grammar of their own; the `call
erx_object_info` declaration alone waits on the call grammar's
capability argument of any type
([Kernel calls and bindings](#kernel-calls-and-bindings)).

```text
inspection 1
  unit pages "pages"
  integer page_count 0 0xffffffffffffffff unit pages
  integer budget_id 1 0xffffffff
  stopgap liberx_pool kernel "liberx pool" "pages committed through liberx; not kernel objects, page tables or mapping records"
  stopgap liberx_trace kernel "liberx trace" "the root's parks, wakes, IRQ deliveries and task starts and ends; not test tasks' parks or the kernel's events"
  trace backend liberx_trace
  trace kernel kernel
  kind budget
    attr kind @budget_kind reporters kernel visible owner build all projections shell,host,proc,web
    attr used page_count reporters kernel,liberx_pool visible owner build all projections shell,host,proc,web
  path listing budgets
    visible all
  path budget budgets *budget_id
    present budget
```

### Widget format

`formats/ui.txt` holds the one `ui VERSION` declaration of the display's
widget trees ([Widget trees](design-display.md#widget-trees)). Its
members, at two-space indentation, declare value types, image types,
properties and kinds; the properties a kind takes are at four spaces
beneath it. Members have one namespace of their own; a member refers to
another by its bare name and to a root `limit` or `enum` by `@name`.
Every wire number is literal in the source.

| Member | Meaning |
| --- | --- |
| `integer NAME MIN MAX` | an integer within the inclusive bounds, which lie within a signed 32-bit integer |
| `text NAME MAX utf8` | at most MAX bytes of valid UTF-8, MAX at most 65,536 |
| `bytes NAME MAX` | at most MAX bytes, MAX at most 65,536 |
| `list NAME TEXT MAX` | at most MAX values of the text type TEXT, MAX at most 1,000 |
| `image NAME NUMBER CONTENT_TYPE` | an image type: its atom, its number from 1 to 255, and the quoted media type the browser is given |
| `prop NAME NUMBER TYPE [common] [status] [default VALUE] [detail state]` | a property, NUMBER from 1 to 255 |
| `kind NAME NUMBER [children]` | a kind, NUMBER from 1 to 255, which takes children when marked |
| `prop NAME [state] [fixed] [within LOW HIGH] [index LIST] [hides PROP]` | at four spaces: the kind takes the property, with these marks |

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
has none. On a property's line beneath a kind, `state` marks the value the user changes,
`fixed` a property that is part of the node's identity, `within LOW
HIGH` an integer that lies between two integer properties of the kind,
`index LIST` an integer that indexes a list property of the kind, and
`hides PROP` a fixed boolean under which PROP is refused in a tree,
never kept, and handed to the application as `{erx_secret, V}`.

The generator refuses a number or a name used twice in its namespace; a
kind that takes an event marked `detail state` without exactly one
`state` property; a `within`, `index` or `hides` naming a property the
kind does not take or of the wrong type; a content type other than an
`image/` type, and `image/svg+xml`; and a kind whose largest `insert`,
every property it takes at its bound, exceeds `web_ui_op_max`, the room
one web update leaves for an operation
([design-web.md](design-web.md#the-protocol)).

```text
ui 1
  integer size 0 16384
  integer bound -2147483648 2147483647
  text caption 4096 utf8
  image png 1 "image/png"
  prop key 1 key common
  prop width 2 size common
  prop visible 7 boolean common default true
  prop present 9 presentation common status
  prop on_select 10 event common
  prop text 11 caption status
  prop secret 13 boolean default false
  prop min 15 bound default 0
  prop max 16 bound default 100
  prop value 17 bound
  prop on_change 26 event detail state
  prop on_submit 27 event detail state
  kind column 1 children
  kind slider 9
    prop min
    prop max
    prop value state within min max
    prop on_change
  kind input 10
    prop text state
    prop secret fixed hides text
    prop on_change
    prop on_submit
```

The binary form follows from the declaration, as 9P2000.L's bytes follow
from the protocol's kinds. Integers are little-endian. Each message is a
`u32` length, at most `web_ui_op_max`, and then:

| Message | Fields |
| --- | --- |
| `insert`, tag 1 | node `u32`, parent `u32` (0 for the root), index `u16`, kind `u8`, properties |
| `remove`, tag 2 | node `u32` |
| `set`, tag 3 | node `u32`, properties, then a `u8` count and that many property numbers removed |
| `move`, tag 4 | node `u32`, index `u16` |
| `commit`, tag 5 | none |
| `event`, tag 6 | node `u32`, the event property's number `u8`, and a detail: a `u8` tag, none 0, boolean 1, integer 2 and text 3, and its value |

Properties are a `u8` count and, for each, its number and its value: a
boolean as a `u8` of 0 or 1; an integer as a signed 32-bit value; an enum or an
image type as its `u8` number; a text or bytes as a `u32` length and the
bytes; a list as a `u16` count and its texts; an event as nothing, the
number alone saying that the node takes it; a presentation as its name,
a `u8` length and at most 63 bytes, and its canonical text, a text of at
most 4,096 bytes. A `status` property begins with its status block: the
status as a `u8` (`ok` 0, `partial` 1, `unknown` 2, `unsupported` 3,
`timeout` 4, `error` 5), the reporter as a `u8` (the application's own
value 0, `kernel` 1, `service` 2, `runtime` 3, a stopgap 4), the
stopgap's name as a `u8` length and at most 63 bytes, empty unless the
reporter is a stopgap, and the timeout in milliseconds as a `u32`, 0
unless the status is `timeout`; the value follows only for `ok` and
`partial`. A `key` property is never written. A reader refuses an
unknown tag, kind, property, image type or enum value; a value outside
its type; a property twice in one list; a stopgap name the inspection
schema does not declare; and bytes left over in a message. It keeps no
state between messages, and nothing it decodes depends on a node's kind,
so whether a node exists, takes a property or an event, or fits its
parent is decided by the renderer's `apply_ops` and by `hit/4`, never by
the reader.

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
existing 32-bit `erx_rights_t`; a bit position above 31 or a mask outside
that width fails generation. A wider call register carries its
zero-extended value, and decoding rejects nonzero upper bits instead of
silently truncating them. This does not change the 64-bit capability
value, which holds a slot and generation rather than a rights word.

The boot formats use these assignments:

| Declaration | Value |
| --- | --- |
| ABI version; image and manifest versions; boot-locator version | `1` |
| pack version | `2`, which names BLAKE3 with a 32-byte output as the index and file hash |
| pack magic | bytes `45 52 58 50 41 43 4b 00` (`ERXPACK` and NUL) |
| boot-locator magic | bytes `45 52 58 42 4f 4f 54 00` (`ERXBOOT` and NUL) |
| image magic | `0x49585245`, bytes `ERXI` |
| system-manifest magic | `0x4d585245`, bytes `ERXM` |
| pack flags | development bit 0; unconfined-DMA bit 1 |
| entry kinds | file 1; executable image 2 |
| entry flags | system bit 0; seal bit 1 |
| image flags | fixed bit 0; JIT bit 1 |
| image-segment flags | guarded bit 0 |
| image protections | read 1; read/write 3; read/execute 5 |
| system-manifest flags | development bit 0; partial boot bit 1 |

The image-protection values encode read, write and execute at bits 0, 1
and 2, but the manifest field accepts only the three listed combinations.
An unnamed bit is zero. A versioned record's version is one `limit`
constant whose name ends in `_version`, such as `pack_version` or
`crash_version`; its writer stores that constant in the record's
`version` field. A `layout` line has no version of its own. Each
versioned reader accepts its exact supported version, with a diagnostic
on any other value. An ABI or format change
replaces the declarations and all consumers together; it adds no migration
path or reader for an earlier erXos encoding.

The root slot assignments are root budget 1, root group 2, system group
3, root resource 4, boot image 5, time page 6, own space 7, own thread
8, device-secret page 9, machine page 10 and previous-crash record 11.
These are slot numbers, not complete capability
values: the root extension of the boot information page, derived from them,
supplies each value with its generation, slot N at offset 8 x (N - 1). The
optional previous-crash capability is null when no record exists.

The reserved capability values are `cap_self`, `0xffffff`, and
`cap_self_thread`, `0xfffffe`, generation 0 and slot bits above `caps_max`
([Objects and capabilities](design-kernel.md#objects-and-capabilities)).

The machine page's layout is in [The root
task](design-kernel.md#the-root-task), and the device-secret page's in [Device
secrets](design-platforms.md#device-secrets). The public HMAC messages are
`device_secret_label`, the ASCII text `erXos device secret`, which HMAC-SHA-256
keyed by the board's key turns into the device secret, and
`sealing_secret_label`, the ASCII text `erXos sealing secret`, which it keyed by
the device secret turns into the sealing secret, neither with a terminating NUL.

## Boot-image representations

The pack header is 96 bytes, aligned to 8. Its field offsets are magic 0,
version 8, flags 12, total size 16, entry count 24, entry size 28, entry
offset 32, string offset 40, string size 48, root entry 52, build id 56
and index hash 64, 32 bytes. An entry is 64 bytes, aligned to 8: path
offset 0, path length 4, kind 6, flags 7, data offset 8, data size 16,
image-manifest offset 24 and file hash 32, 32 bytes. The field widths and
limits are those of
[the boot-image contract](design-kernel.md#the-boot-image). A hash field
is a byte array holding BLAKE3's output in its own byte order, never an
integer.

The canonical index is the header, the entry array starting at byte 96,
then the string table starting immediately after that array. File data
starts at the first 4,096-byte boundary after the strings, where the
index run ends, which the index hash covers with its own field read as
zeros. Each file run, which its entry's file hash covers, is the file's
data followed by zeros to the next page boundary. The entry
count determines the entry array's size; the offsets must equal these
derived values. Thus no legal data offset can overlap either index
table. The archive ends at the first page boundary at or after the last
entry's data. Padding bytes are zero, and the writer orders paths by their
unsigned bytes without locale or Unicode normalization.

The boot locator is 32 bytes, aligned to 8: magic 0, version 8, a zero
word 12, archive offset 16 and archive size 24. Its place in the first
stage is the architecture binding's
([design-arch-aarch64.md](design-arch-aarch64.md#boot-entry)), and its
rules are those of
[the bootable file](design-kernel.md#the-bootable-file).

An image-manifest fixed prefix is 56 bytes, aligned to 8: magic 0,
version 4, segment count 6, ABI version 8, flags 12, span 16, fixed base
24, entry offset 32, program-header offset 40, program-header count 48
and base alignment 52. Base alignment is a power of two at least one
page: a position-independent image uses the maximum of the page size
and its ELF load-segment alignments, representable in `u32`; a fixed
image uses the page size. The normalized origin of a position-independent
image is its first load address rounded down to this alignment, so an
equally aligned mapped base preserves every segment's load-bias
constraint. A fixed image keeps its original addresses. Its segment
array immediately follows the prefix. Each segment
is 40 bytes, aligned to 8: file offset 0, memory offset 8, file size 16,
memory size 24, protection 32 and flags 36. Counts, ranges, protections
and mapping policy follow
[image manifests](design-kernel.md#image-manifests); generated structural
readers do not replace that image validator.

### File-prefix exclusion

Strict byte sorting and an adjacent-prefix comparison do not alone
exclude a file used as a directory: `a`, `a-foo`, `a/b` are strictly
sorted. The validator uses a bounded stack of candidate file paths,
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
[the system configuration contract](design-system.md#the-manifest).
Its byte representation consists of a fixed header, fixed-record arrays
in declaration order and a final string table. It uses little-endian
integers, file-relative array spans and string-table-relative string
references. `erx_mf_span_t` is two `u32` fields, offset and count;
`erx_mf_str_t` is two `u32` fields, offset and byte length. Each is 8
bytes with alignment 4. Indices refer to the named top-level table, never
to a native address. A nested span identifies complete records within
its named top-level array, not an independently serialized duplicate.

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
percentage, weight or second scheduling mechanism. It contains the exact
quota in nanoseconds, period in nanoseconds and CPU set which the kernel
enforces, with the scheduling hints and urgency bounds that the scheduler
contract already defines. Its size is 48 bytes and alignment is 8:

| Offset | Field | Type |
| --- | --- | --- |
| 0, 8, 16 | `quota_ns`, `period_ns`, `cpuset` | three `u64` |
| 24, 28, 32, 36 | `capacity_mcpu`, `capacity_first`, `slice_us`, `grace_us` | four `u32` |
| 40, 41, 42 | `base`, `ceiling`, `flags` | two `erx_urgency_t`, each a `u8`, and `u16` |
| 44 | zero padding | four bytes |

`UINT64_MAX` encodes `ERX_QUOTA_NONE`; zero quota means no CPU time.
The flag positions are hints 0, defer 1, status 2 and placement 3. Other
bits are zero. Period, CPU-set, capacity, urgency and flag validation use
the scheduler's declared limits. Resource comparisons use exact integer
rationals; no floating-point calculation rounds an overcommit down. A
disabled sub-space grant is represented by all-zero bytes and is legal
only when its enclosing limits record does not enable sub-spaces.

A manifest has at most 16 MiB, its string table at most 4 MiB, and each
record table at most 65,536 elements. These are decoding ceilings, not
resource grants. The configuration's `max_domains`, quotas and
byte-budget checks impose their additional limits. No decoder allocates
from a count before checking both its table ceiling and the complete
file extent. The source declares these ceilings as `limit` values.

All record tables use 8-byte alignment and explicit zero tail padding
where their fields require it. An array of plain `u32` indices uses
4-byte alignment. The file length equals the end of its string table;
there are no hidden trailing records. Strings have no implicit NUL.
System identifiers have their existing 63-byte maximum; paths are at
most 4,096 bytes. A domain's argument and environment strings together
fit the boot-information page's existing 2,048-byte string budget after
its node and peer names. NUL-separated vectors end each element with
NUL, contain no empty environment name, and use the empty byte string
for an empty vector. Environment entries have one name before the first
`=`, and names are unique. Arbitrary argument bytes remain inert bytes
until the runtime consumes them, and are escaped where they are displayed
under their source.

The domain-reference value `0xffffffff` names the system domain; other
values index the configured-domain table. This is a manifest reference,
never a kernel capability or a live domain id. An absent optional index
uses `0xffffffff` only in fields whose type permits absence. A field
cannot use both meanings. Every other index is zero-based and must name
a present record. Index values are assigned after canonical ordering.

The record notation below lists `offset: name type`. `str` means
`erx_mf_str_t`, `span` means `erx_mf_span_t`, and `share` means
`erx_share_t`. A sequence of fields at successive offsets is written
explicitly; reserved fields and padding are zero. The source contains
these exact offsets and sizes.

### Machine header

The header is 368 bytes with alignment 8. Its fields are:

| Offset | Field | Type and meaning |
| --- | --- | --- |
| 0, 4, 6 | `magic`, `version`, `flags` | `u32`, `u16`, `u16`; magic/version above; development at flag bit 0, partial boot at bit 1, the UART console line secure at bit 2 and the host-link line secure at bit 3, all other bits zero |
| 8, 12 | `length`, `header_size` | `u32`, `u32`; complete file length and exactly 368 |
| 16, 24, 32, 40 | `host`, `console`, `hostlink`, `platform` | four string references; system identifier, absolute device-tree path, optional device-tree path and platform identifier |
| 48, 56, 64 | `root_memory`, `system_baseline`, `system_reservation` | three `u64` byte counts; the root assumption, configured baseline and checked admission reservation |
| 72, 120 | `system_share`, `users_share` | two shares, for `system` and `users` |
| 168, 172, 176 | `system_principal`, `max_domains`, `max_connections` | three `u32`; principal index and domain-library table capacities |
| 180, 184, 188 | `system_lane`, `system_queue`, `peer_held` | three `u32` byte limits with their system-contract meanings |
| 192, 196 | `system_reserve`, `sealing` | two `u32`; unallocated system-rate headroom in thousandths, and none 0, device 1 or TPM 2 |
| 200, 204 | `system_runtime_limits`, `native_limits` | two `u32` indices; the system runtime's limits and a partial boot's complete native-domain limits |
| 208 through 360 | table spans | twenty `span` values, in the order below |

The spans are `principals`, `domains`, `limits`, `runtime_limits`,
`lane_classes`, `units`, `devices`, `windows`, `services`, `facets`,
`facet_operations`, `facet_parameters`, `introductions`, `images`,
`extents`, `boot_order`, `liveness`, `shell_principals`, `partial_boot`
and `strings`, at offsets 208, 216 and so on through 360. Each table
starts at its first required alignment boundary after the preceding
table. The final span's count is bytes. This is the sole packed order.

`root_memory` is nonzero and page-aligned. Table capacities are 1 through
65,536, except that `max_domains` may be 0 when no domains are configured, `system_reserve` is 1 through 1,000, and the system grant has a
positive rate and nonempty allowed CPU set. The lane is a
power of two within the lane contract. Queue, peer-held and baseline
limits are positive and satisfy their existing admission constraints.
The selected platform must provide every CPU and unit the configuration
requires. A root configuration that cannot create and run its own
threads fails the complete plan, even if no configured domain is present.

The runtime group of every system-domain thread is `system`. The kernel
creates it uncapped and starts the first root worker there; the root
entry applies `system_share` before starting other threads and creates
`users` from `users_share`. The root worker never changes group. Service
domains have child groups under `system`; its direct runtime threads
share the aggregate grant without an independent cap. `system_reserve`
limits the normalized share assigned to those child groups; it is
configuration headroom, not CPU supply promised within a time window.

The baseline is the system runtime's own fixed memory requirement,
including its queues shared across clients. The reservation is derived
by the production admission planner from the capacities, the bounded
per-domain state, connection-control state and configured facets; it is
not trusted because source text names a number. Their sum, the root's
objects and tables, principals' budgets and permanent device reservations
must fit `root_memory`. Dynamic admissions and later facet grants still
recompute their incremental charges before changing state. A system
runtime's total peer-held limit is checked from `max_domains` and
`peer_held`, within that reservation, rather than borrowed from a user's
runtime defaults.

### Principal, domain and limit records

| Record and size | Fields |
| --- | --- |
| principal, 80 | `0: name str`; `8: memory u64`; `16: grant share`; `64: domains u32`; `68: names u32`; `72: default_limits u32`; `76: ceiling_limits u32` |
| configured domain, 64 | `0: name str`; `8: principal u32`; `12: kind u32`; `16: flags u32`; `20: runtime u32`; `24: release u32`; `28: release_files u32`; `32: limits u32`; `36: restarts u32`; `40: restart_period_s u32`; `44: reserved u32`; `48: args str`; `56: env str` |
| domain limits, 160 | `0: name str`; `8: memory u64`; `16: outer u64`; `24: grant share`; `72: spaces share`; `120: lane u32`; `124: connections u32`; `128: crash u32`; `132: flags u32`; `136: runtime_limits u32`; `140: reserved u32`; `144: peer_held u64`; `152: peer_held_total u64` |
| runtime limits, 56 | `0: name str`; `8: max_frame u32`; `12: max_message_heap u32`; `16: funnel_depth u32`; `20: exports u32`; `24: tmp u64`; `32: overlay u64`; `40: atoms u32`; `44: foreign_atoms u32`; `48: processes u32`; `52: reserved u32` |
| lane class, 16 | `0: name str`; `8: lane u32`; `12: reserved u32` |

Every name is a system identifier. A principal's `default_limits` and
`ceiling_limits`, and a domain's `limits`, index the domain-limits table, whose `runtime_limits`
indexes the runtime-limits table. Named limit records let several domains
share an explicit configuration without packing a second copy of its
grant or retaining a hidden runtime default. A source override produces
a complete named record; readers do not apply inheritance or merge maps.
Lane-class records supply configured defaults when policy constructs a
new specification; each packed domain-limits record already has its
resolved lane size. They cannot change a configured domain at runtime.

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

`erx_runtime_limits_t`, embedded by value in both `erx_dom_spec_t` and
`erx_boot_info_t`, is a 64-byte record with alignment 8:

| Offset | Field | Type |
| --- | --- | --- |
| 0, 4, 8, 12 | `max_frame`, `max_message_heap`, `funnel_depth`, `exports` | four `u32` |
| 16, 24 | `tmp`, `overlay` | two `u64` byte limits |
| 32, 36, 40, 44 | `atoms`, `foreign_atoms`, `processes`, `reserved` | four `u32`; reserved is zero |
| 48, 56 | `peer_held`, `peer_held_total` | two `u64` byte limits |

For a requested or configured domain, normalization takes the first nine
values from its resolved runtime-limits record and the final two from
its domain-limits record. It removes the manifest's profile name and
indices. For the system domain it takes the first nine values from
`system_runtime_limits`, `peer_held` from the header and the aggregate
limit from the checked admission calculation. This is a generated
projection from those declarations, not a second independently defined
set of defaults. The planner verifies the entire resulting value and
places it in the boot-page plan before the first thread is started.
Native runtimes receive the same record and validate its representation;
they do not claim to run an Erlang funnel they do not implement.

The boot-page reader checks this record together with every other page
field. ERTS installs it as one immutable startup value before creating
its bounded runtime structures or accepting peer input. A missing limit
is an invalid page, not an unknown value interpreted as unlimited. The
system manifest remains private to the system domain; another runtime
learns only its own projected limits through its read-only boot page.

### Domain identity and placement

Domain kind 1 is `service` and 2 is `secret`. Domain flags have required
at bit 0 and rescue at bit 1. Domain-limits flag bit 0 enables `SPACES`;
the enabled record supplies the sub-space group's grant. The rights
remain installed by the domain library's existing plan, not by a reader.
`runtime` is an executable boot-image entry. `release` and
`release_files` identify a nonempty contiguous run in that image. All
indices and the sum defining the run are checked against the already
validated boot image before policy checking. The secret domain has no
crash area and is the unique domain whose run carries the seal mark.

The principal grant describes its share of `users`. Configured service
domains receive their CPU grants under `system`, while their memory
budgets remain charged to their principal, as the system contract
specifies. A principal record therefore does not move a service's group
under `users`. The domain plan derives its typed CPU-parent selection
from the authenticated creation origin: configured-manifest row,
admitted principal request or native partial-boot row. The
[domain-specification contract](design-system.md#the-domain-library)
binds that origin to the checked row, carries it into the domain record
and makes application use the parent the plan selected. An external
creation request cannot supply origin or parent fields.

### Devices and partition windows

| Record and size | Fields |
| --- | --- |
| unit, 24 | `0: name str`; `8: holder u32`; `12: devices span`; `20: reserved u32` |
| device, 80 | `0: selector u32`; `4: role u32`; `8: path str`; `16: bridge str`; `24: compatible str`; `32: bus u16`; `34: device u8`; `35: function u8`; `36: dma u32`; `40: flags u32`; `44: line u32`; `48: dma_memory u64`; `56: placement_key str`; `64: base u64`; `72: size u64` |
| partition window, 32 | `0: holder u32`; `4: device u32`; `8: role u32`; `12: partition u32`; `16: rights u32`; `20: image u32`; `24: reserved u64` |

A unit's `holder` is a domain reference. Its device span names a
nonempty run in the device table. The unit spans cover that table once,
in order, without a gap or shared record. Device ownership exists in the
unit alone; a device record carries no second holder field. The checked
platform placement record supplies the unit, selector, role, compatible
string, confinement and hostile mark. The source configuration assigns
the unit to a holder; it cannot override those platform facts.

Selector 1 is a device-tree path: `path` is nonempty, `bridge` and the
bus/function fields are zero, and `base`, `size` and `line` are the
device's register window and interrupt from its node: `base` and `size`
are the physical address and length of the node's first `reg` entry, and
`line` is its first interrupt, numbered as the platform's interrupt
controller numbers the lines a device raises. The platform record carries
all three for every device-tree device, and the production image suite
checks them against the device tree QEMU builds. Selector 2 is a PCIe function: `bridge`
names its host bridge by device-tree path, `path` is empty, bus is at
most 255, device at most 31 and function at most 7; its `base`, `size`
and `line` are zero, since configuration space gives them. Role values are
ordinary 1, UART 2, configuration space 3, network 4, block 5 and TPM 6.
These classification values are platform-declared facts for manifest
checks, not a kernel driver dispatch. `compatible` and `placement_key`
are nonempty UTF-8 strings without NUL or control characters, with the
placement key resolving to the selected platform's immutable record.

DMA values are none 0, confined 1 and unconfined 2. Flag bit 0 is
hostile. Only an unconfined device has nonzero `dma_memory`; its size is
page-aligned and is reserved for that device for the boot. All other
flag bits are zero. The packed marks do not establish actual confinement:
the device service still verifies the machine before assigning the unit.

Window roles are slot A 1, slot B 2, boot-selection record 3, reset
count 4, vault 5, data 6, FAT 7 and verified image 8. Fixed-medium roles
have `partition = 0`; the ABI medium layout determines their sectors.
FAT names a primary partition numbered 1 through 4 on the selected
removable device. A verified-image window names an image-table index;
every other role has absent `image`. Rights are read bit 0 and write
bit 1, at least read; a verified-image window is read-only. No record
contains a caller-selected sector range. Role/holder checks still
restrict slots and records to the slot writer, and data and FAT to
their storage holders. These are private grants, not a global device
namespace.

### Services, facets and their parameter schemas

| Record and size | Fields |
| --- | --- |
| service, 24 | `0: name str`; `8: server u32`; `12: interface u32`; `16: reserved u64` |
| facet, 80 | `0: name str`; `8: grantee u32`; `12: service u32`; `16: operations span`; `24: parameters span`; `32: max_request u32`; `36: in_flight u32`; `40: reductions u64`; `48: period_ns u64`; `56: max_heap_size u64`; `64: queue u64`; `72: reserved u64` |
| facet operation, 4 | `0: operation u32` |
| facet parameter, 32 | `0: key u32`; `4: kind u32`; `8: scalar u64`; `16: bytes str`; `24: index u32`; `28: reserved u32` |
| introduction, 8 | `0: from u32`; `4: to u32` |
| liveness target, 4 | `0: service u32` |

A service's `server` is a domain reference. Its interface number names
a declaration in `abi/services/`; the packer checks the selected
server's verified release catalog actually supplies that interface.
The manifest cannot invent a service by giving it a plausible name.
The service's public symbolic name is a system identifier scoped to its
server. A facet's public identifier is scoped to its grantee. Source
aliases are globally unique within their record kind and references use
those aliases; an optional `name` property supplies the public name,
defaulting to the alias. For example, `service storage_a` with
`name "files"` on one server and `service storage_b` with `name "files"`
on another are distinct, and `@service.storage_a` is unambiguous.
Repeating an alias fails even when its public scopes differ. An introduction joins two
different configured domains and is unique as an unordered pair; it
creates the existing connection, with no additional capabilities or
transitive authority.

The operations span contains explicit operation numbers of that
interface, strictly ascending and without duplicates. A schema revision
does not implicitly add newly declared operations to an existing grant.
The parameters span contains typed scope and option values which the
same service fragment declares with `parameter NAME NUMBER KIND
CARDINALITY BOUND`. Cardinality is `one`, `optional` or `set MAX_COUNT`.
Each declaration also identifies the checked scope/admission helper that
consumes it. A missing required parameter, an unknown key or kind, a
duplicate scalar key, an unsorted/duplicate set, an excessive bound, or a
parameter without that checked consumer fails validation.

Within `service NAME NUMBER`, the exact metadata members are
`operation NAME NUMBER`, `liveness OPERATION_NAME` and `parameter NAME NUMBER KIND CARDINALITY
BOUND checked_by HELPER`. For integer kinds, BOUND is `range MIN MAX`;
for identifier, path or bytes it is `bytes MAX_BYTES`; boolean uses
`boolean`; a reference kind uses `target TABLE`, with `domains`,
`principals` or `devices` as appropriate. A domain reference additionally
spells `system yes|no`. The helper is a qualified symbol of the service's
manifest-grant checker, resolved against its checked consumer inventory;
naming it in untrusted configuration creates no helper or authority.
The service is unusable by the packer unless that checker is available.
These declarations supply manifest metadata and validation, not request
execution or a future service's callback implementation.
The closed KIND tokens are `u64`, `i64`, `boolean`, `identifier`,
`namespace_path`, `domain`, `principal`, `device` and `bytes`. A liveness
marker names one declared operation. Its request and response signature
belongs to the service contract and is verified against that service's
checked consumer descriptor before admission; an absent or incompatible
descriptor fails. This metadata does not invent a callable signature or
permit the watchdog to invoke an arbitrary operation by number.

Parameter kinds are unsigned integer 1, signed integer 2, boolean 3,
identifier 4, namespace path 5, domain reference 6, principal index 7,
device index 8 and bounded bytes 9. Integer and boolean values use
`scalar`; signed values use the declared 64-bit signed representation,
and booleans are 0 or 1. Text and bounded bytes use `bytes`; references
use `index`. All inactive fields are zero. A parameter's maximum length,
range and allowed reference category come from its declaration. Opaque
bytes are legal only for a field whose service contract defines them as
opaque; they cannot encode an unchecked scope or nested configuration.
There is no term decoder, recursive value language or raw function name
in the manifest.

These records carry an operation set and the service's declared scope
parameters; the handwritten scope checker still decides membership and
the generated serving path still authenticates the lane and live grant.
No generic interpretation of a path, pid or parameter mints authority.
Service-specific declarations land with the service contract and are
required before a manifest can name that service. This permits complete
structural readers without implementing future service callbacks.

`max_request` is a byte ceiling, `in_flight` a count, `reductions` a
positive share per positive `period_ns`, `max_heap_size` a byte limit
including off-heap binaries, and `queue` the resolved byte quota. The
packer resolves an omitted queue to `system_queue`; no zero sentinel
changes its meaning at runtime. Conversion to a runtime's heap-word
limit is checked and rounds down. The manifest checker includes each
facet's charge in its grantee's admission reservation. Liveness records
name services whose interface declares its liveness operation; all use
the kernel watchdog's period and cannot extend its deadline.

### Read-only images, ordering and partial boots

| Record and size | Fields |
| --- | --- |
| image, 136 | `0: name str`; `8: device u32`; `12: format u32`; `16: extents span`; `24: data_bytes u64`; `32: data_block_size u32`; `36: hash_block_size u32`; `40: data_blocks u64`; `48: hash_offset u64`; `56: hash_bytes u64`; `64: salt_length u32`; `68: hash_algorithm u32`; `72: salt bytes[32]`; `104: root_hash bytes[32]` |
| image extent, 16 | `0: slot_offset u64`; `8: length u64` |
| boot-order entry, 4 | `0: domain u32` |
| system-shell principal, 4 | `0: principal u32` |
| partial-boot program, 16 | `0: name str`; `8: image u32`; `12: reserved u32` |

Image format 1 denotes EROFS protected by the storage contract's
dm-verity version 1 tree; hash algorithm 1 is SHA-256. Salt length is
0 through 32 and unused salt bytes are zero. Both block sizes are
positive powers of two accepted by that format. Extents are nonempty,
sector-aligned, sorted, disjoint byte ranges relative to a slot's start,
not the medium's start. Concatenating their bytes produces the image
window: its data starts at zero and its tree starts at `hash_offset`.
The extents cover that entire window, including the hash tree. All
size/block-count/tree calculations are checked against the storage
format, and all slot extents fit the ABI's slot extent. The packer
derives these fields and hashes from the built image; source text
cannot supply an unchecked root hash or extent. At boot the device
service adds the currently named slot's base after checking the boot
value; `unknown` supplies no such window.

Image format 2, `erofs_unchecked`, is an EROFS image with no tree,
which only a development manifest admits: its window is its data alone,
`data_bytes` long, its hash algorithm is 0, none, and every tree field,
the salt and the root hash are zero, so the hash-checking reader opens it
`unchecked` and no record claims a check that nothing makes
([design-stopgap.md](design-stopgap.md#the-phase-1-manifest-check)).

Boot order is the complete permutation of the configured-domain
indices, with servers before clients. The packer uses a topological
order whose ready set is ordered by domain-name bytes. It rejects a
cycle and never emits a partial order. The shell-principal list is a
strictly increasing, duplicate-free list of principal indices. A
liveness list likewise names each configured target at most once.

A console line's `secure` attribute has no table of its own. The two
fixed lines carry it in the header's flags:
`ERX_MANIFEST_CONSOLE_SECURE`, bit 2, for the UART that `console` names,
and `ERX_MANIFEST_HOSTLINK_SECURE`, bit 3, for the host link, which is
set only when `hostlink` names a path; the source names them as the
`machine` flags `console_secure` and `hostlink_secure`, which a
manifest's source sets by default and may clear. A display
domain's terminal windows carry theirs in its `console_line`, which
packs as an ordinary facet record: a facet of the console service
granted to the display domain, whose operation set holds `offer_line`
and whose parameters hold the console contract's boolean `secure`
parameter, once, for every window that display offers
(`abi/services/console.txt`). The checker refuses a release manifest in
which any such facet has `secure` 1, and the console service reads the
attribute of a window's line from the facet that offered it, never from
the display.

Partial-boot programs have system-identifier names and executable image
indices. All use the machine's declared default native limits and the
system principal, and receive no connections. `ERX_MANIFEST_PARTIAL_BOOT`
selects partial boot independently of the program-list length and
requires `ERX_MANIFEST_DEVELOPMENT`. It is a development mode which
replaces configured domains, as the system
contract specifies: `domains`, services, facets, introductions,
liveness and boot order are empty. The common header, principals,
limits and system-owned console units remain checked. A release
manifest refuses the partial-boot flag, even with an empty list. Without
that flag, a nonempty partial-boot list is invalid. A partial boot may
have zero programs; it follows the ordinary completion path with all
programs already ended. A full boot runs the
complete configuration check, including the unique vault requirement;
the native-program mode does not pretend to start the absent services.

### Canonical source, packing and checking

`config/<name>.txt` uses the same ASCII token, comment and quoted-string
rules as ABI declarations. It begins `manifest 1`; declaration keywords
are `machine`, `share`, `principal`, `domain`, `limits`, `runtime_limits`,
`lane_class`, `unit`, `window`, `service`, `facet`, `introduce`, `image`,
`liveness`, `shell_principal` and `partial_boot`. Named declarations
have two-space-indented properties whose names and types are their
record's fields. References use source identifiers, not numeric indices.
String and byte values accept either a quoted ASCII literal or
`hex:HEX_BYTES`; the latter carries UTF-8 or opaque argument bytes while
the source stays ASCII. The field's validator still checks the decoded
bytes against its declared text class and bound.
Every required property occurs exactly once. Unknown properties,
duplicates, unbounded values and references outside the selected
configuration fail. An optional source property is optional only where
the owning contract declares a default; normalization resolves that
default before validation.

The exact source forms are below. A named record starts `KIND NAME` at
column zero and ends at the next declaration. Its two-space properties
are unordered; list elements follow their declared type's ordering.
References are `@KIND.NAME`, resolved within this configuration; literal
`system` names the root domain. No packed offset, index, count, reserved
field or computed charge is an accepted property.

| Source form | Accepted properties and value forms |
| --- | --- |
| `machine` | `flags` flag list; `host`, `console`, `hostlink`, `platform` strings; `root_memory`, `system_baseline`, `max_domains`, `max_connections`, `system_lane`, `system_queue`, `peer_held`, `system_reserve` integers; `system_share`, `users_share` share references; `system_principal` principal reference; `system_runtime_limits` runtime-limits reference; `native_limits` limits reference; `sealing none\|device\|tpm` |
| `share NAME` | exactly `quota_ns`, `period_ns`, `cpuset`, `capacity_mcpu`, `capacity_first`, `slice_us`, `grace_us`, `base`, `ceiling`, `flags`; integers except quota's optional `uncapped` literal and the flag list |
| `principal NAME` | `memory`, `domains`, `names` integers; `grant` share reference; `default_limits`, `ceiling_limits` limits references |
| `runtime_limits NAME` | exactly the nine non-name, non-reserved fields of the packed runtime-limits record, each an integer |
| `limits NAME` | its packed scalar fields except name, reserved and runtime index; `grant` share reference; `spaces` share reference or `none`; `runtime_limits` runtime-limits reference; `flags` flag list |
| `lane_class NAME` | `lane` integer |
| `domain NAME` | `principal`, `limits` references; `kind service\|secret`; `flags` flag list; `runtime`, `release` artifact references; `restarts`, `restart_period_s` integers; `args`, `env` vectors |
| `unit NAME` | `placement` string naming a complete checked platform unit; `holder` domain reference or `system` |
| `window NAME` | `holder` domain reference; `device` checked platform-device string; `role` declared role name; `partition` integer; `rights` flag list; `image` image reference or `none` |
| `service NAME` | `server` domain reference or `system`; `interface` qualified ABI service name |
| `facet NAME` | `grantee`, `service` references; `operations` list; repeated `parameter KEY VALUE`; `max_request`, `in_flight`, `reductions`, `period_ns`, `max_heap_size`, `queue` integers |
| `introduce FROM TO` | two domain references on the declaration line; no properties |
| `image NAME` | `device` checked platform-device string; `input` artifact reference; optional `salt` byte literal, bounded to 32 bytes |
| `liveness SERVICE` | one service reference on the declaration line; no properties |
| `shell_principal PRINCIPAL` | one principal reference on the declaration line; no properties |
| `partial_boot NAME` | `image` artifact reference |

A `share` is a source value expanded by value, not another packed table
or runtime object. Every share field is required. Flag and operation
lists are comma-separated declared names or `none`. A facet's
`parameter KEY VALUE` resolves KEY against its service's parameter
schema; VALUE has that key's declared scalar, string, byte or reference
type. Repetition is legal only for a declared set, within its bound.
Numeric operation, key and kind values are derived. For example:

```text
facet storage_read
  grantee @domain.client
  service @service.storage
  operations read,stat
  parameter root "/public"
  max_request 4096
  in_flight 2
  reductions 100000
  period_ns 10000000
  max_heap_size 65536
  queue 16384
```

This block requires that service's `read`, `stat` and single
namespace-path parameter `root`; its grant checker still decides scope.
An unknown operation, `parameter root 3`, or a second `root` line fails
normalization. This adds no service callback or execution schema.

`args VALUE...` and `env VALUE...` contain zero or more quoted or hex
byte values without embedded NUL. Normalization appends a NUL per
element and checks environment keys and the aggregate boot-page bound.
An empty property line means an empty vector. An artifact reference is
`@artifact.NAME`, resolved only against the packer's verified build-input
inventory: executable references name one executable entry, release
references its verified contiguous run, and image inputs a built EROFS
artifact. Wrong artifact kinds fail. References neither open arbitrary
host paths nor execute commands. Omitted image salt is empty; the fixed
EROFS/dm-verity/SHA-256 profile determines its format. The builder derives
extents, lengths, counts and hashes. Source `root_hash`, `data_blocks`,
`extent` or `system_reservation` properties fail even when their values
match what would be derived.

The following is a complete native partial-boot source for grammar and
normalization. Its explicit input inventory supplies executable
`@artifact.probe`; platform `fixture` supplies CPU 0 and UART unit
`uart0` at `/uart@0`, without DMA. Those fixtures, root-image provenance
and the production resource planner are independent prerequisites for
accepting a boot image.

```text
manifest 1
share system
  quota_ns 2000000
  period_ns 10000000
  cpuset 1
  capacity_mcpu 200
  capacity_first 0
  slice_us 1000
  grace_us 5
  base 24
  ceiling 47
  flags none
share users
  quota_ns 8000000
  period_ns 10000000
  cpuset 1
  capacity_mcpu 800
  capacity_first 0
  slice_us 1000
  grace_us 5
  base 16
  ceiling 31
  flags none
runtime_limits native
  max_frame 4096
  max_message_heap 8192
  funnel_depth 64
  exports 64
  tmp 0
  overlay 0
  atoms 1024
  foreign_atoms 64
  processes 64
limits native
  memory 16777216
  outer 1048576
  grant @share.users
  spaces none
  lane 4096
  connections 0
  crash 0
  flags none
  runtime_limits @runtime_limits.native
  peer_held 4096
  peer_held_total 4096
principal root
  memory 268435456
  grant @share.users
  domains 4
  names 4
  default_limits @limits.native
  ceiling_limits @limits.native
machine
  flags development,partial_boot
  host "fixture"
  console "/uart@0"
  hostlink ""
  platform "fixture"
  root_memory 1073741824
  system_baseline 67108864
  system_share @share.system
  users_share @share.users
  system_principal @principal.root
  max_domains 4
  max_connections 4
  system_lane 4096
  system_queue 16384
  peer_held 4096
  system_reserve 250
  sealing none
  system_runtime_limits @runtime_limits.native
  native_limits @limits.native
unit console
  placement "uart0"
  holder system
partial_boot probe
  image @artifact.probe
```

Normalization assigns the sole principal and each sole limits record
index 0; it produces one unit, one device and one partial-boot row, with
zero configured domains, services and facets. Shares produce no table;
their values fill the header, principal and limits records. A reference
to `@share.missing` fails as undefined; `data_off 4096` in the program
fails as an unknown property; an absent domain as the UART holder fails
before policy checking. C, Erlang and Ruby readers of the packed fixture
recover the same values and table counts.

The source names image inputs and platform units. It cannot set derived
fields: packed offsets and counts, boot-image indices, platform facts,
boot order, hash-tree fields or admission charges. The packer resolves
them from the validated boot-image plan, platform placement records,
verified release metadata and its image builder. It forms one immutable
normalized configuration before applying any rule or writing a byte.

Top-level named tables are sorted by name bytes; service names are
qualified by their server and facet names by their grantee. Unit devices
follow their units, in selector order. Facet operations and parameters
follow their facets, with operation/key/value order inside each facet.
Image extents follow their images. Windows sort by holder, device,
role and partition; introductions by their canonical endpoint pair.
Auxiliary order lists follow their stated ordering. Strings are appended
in header/table/record/field traversal order, without deduplication; equal
source configurations therefore have equal byte representations without
depending on a hash table's iteration order.
An empty string encodes offset zero and length zero and appends no bytes;
the same representation satisfies zeroed inactive string fields.

The checker evaluates all thirteen system-manifest properties, with
their property numbers in diagnostics. Resource sums include exact
principal budgets, device reservations, table sizes and the system's
baseline and worst admitted-domain reservation. The domain planner is
the production `erx_dom_plan_configured` pure core built for the host; a
different implementation or a placeholder success is not its oracle.
Property 12 invokes it for each configured-domain or partial-boot child
specification, in boot order, against a view in which every earlier plan
is recorded, and `erx_dom_plan_connect` likewise for each introduction.
With no child specifications it makes zero calls; that
universal check holds over the empty set, without pretending a planner
ran. Initial-root startup remains a separate required plan under the
resource check, including its private image memory, stack, UTCB and boot
objects. A declared positive baseline cannot replace that plan or its
backend/ABI-bound charge evidence. If any specification requires planning and that planner is
unavailable, packing fails as unsupported. A host report can show that
unresolved result, but it cannot turn it into a
bootable manifest. The same rule applies to an unavailable service scope
checker or missing image provenance.

The root entry's non-JIT property, the system and seal release runs,
device placement, grants, role restrictions, rescue closure and domain
creation feasibility are checked before the packer's sole publication
path receives bytes. Runtime readers revalidate the complete binary
structure and its relationship to the validated boot image before
returning a view. Configuration authority still comes from the checked
system-release file; a boot argument or a separately compiled descriptor
array cannot supply missing data.

## Output inventory and publication

One immutable inventory lists the resolved input paths and all derived
output paths. Paths are normalized relative paths, without traversal or
symlinks, and name inputs below the repository root and outputs below the
build's generated tree, `build/gen/`, which mirrors repository-relative
paths. No output is checked in. Output bytes depend only on source
bytes and the generator, never wall-clock time, locale, filesystem
enumeration order or absolute checkout path. Declarations keep their
declared field order; unordered sets and documentation tables use
qualified-name byte order. Every artifact names its sources and generator
and carries the project's BSD-2-Clause notice and copyright for
Stanislav Sedov <stas@deglitch.com>.

The output families have explicit locations, shown relative to `build/gen/`:

| Location | Contents |
| --- | --- |
| `include/erx/abi.h` | constants, strong scalar wrappers, typed layouts, size/offset assertions and field operations |
| `include/erx/abi_reader.h`, `liberx/generated/abi_reader.c` | bounded structural readers and diagnostic types |
| `kernel/generated/abi_calls.h`, `kernel/generated/abi_decode.c` | typed handler declarations, argument validation, closed dispatch/executor metadata and each call's admission plan |
| `kernel/generated/NAME_impl.h` | a private layout's offsets, record and operations |
| `liberx/generated/calls.h` | backend-independent call signatures |
| `liberx/backend/<backend>/generated/` | the backend's declarations or native trap wrappers, with architecture-specific files inside its architecture directory |
| `erlang/apps/erx/include/generated/erx_abi.hrl`, `erlang/apps/erx/src/generated/erx_manifest.erl` | constants and the generated manifest reader |
| `tools/generated/abi.rb` | immutable values, source-driven packer encodings and host readers |
| `fuzz/generated/` | entry points invoking production readers |
| `web/src/generated/` | the web client's TypeScript: `web.txt`'s types, codec, limits and hash; `ui.txt`'s tables and the reader and writer of its binary form; the inspection schema's kinds, attribute names, units, stopgap reporters and `present` marks ([design-web.md](design-web.md#the-client)) |
| `docs/generated/abi-reference.md` | signatures, assignments, fields, bounds and mapping tables |

Independent raw-byte fixtures live in `test/fixtures/` and do not derive
their expected bytes from the generator. Test builders use the generated
host codec where their purpose is constructing inputs rather than
serving as an independent oracle. Direct boundary mutations exercise
the production reader entrypoints in each generated language.

The inventory enumerates individual paths rather than accepting arbitrary
files below those directories. The generated tree is regenerated whole,
so an output the inventory no longer lists does not survive, and a file
edited or added by hand fails the tree's stamp. The determinism test
and the ASCII refusal of `Erx::Generated` ([Generation](design-build.md#generation))
hold the byte-for-byte and ASCII properties.

All outputs are derived and validated before any publication. The tree is
staged beside `build/gen/` and moved into place by rename, so a process or
filesystem failure leaves the earlier tree or none, and the command fails.
A failed schema check does not reach this effect stage.

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
two stopgap reporters for one category. Each
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

Drift tests change an artifact, delete one, add an orphan and change a
document delimiter, each expecting failure. Reordering independent
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
`dt_path`, `namespace_path`, `utf8`, `bytes`, `args` and `env`.

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

The signed accessor accepts `-1` and the declared signed minimum without
overflow; array access succeeds at indices 0 and 1 and refuses 2 before
an atomic access. `atomic ready load acquire store release`, a signed
sequence counter, an unbounded array and right position 32 are invalid
declarations. An array's owner masks are checked in each element's
unsigned width, never as a mask for the aggregate byte range.
