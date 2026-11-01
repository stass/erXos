# Generated interfaces and representations

Ruby generators turn erXos's interface declarations into readable C17,
Erlang, Ruby and reference tables. A fact shared across languages or
consumers is declared once: its names, types, bounds, identifiers and
representations are derived together. Policy, resource admission,
ownership transitions and recovery decisions remain handwritten pure
cores under [Protocol verification](design-verification.md).

This document owns the generation rules. The subsystem designs own the
meaning of their interfaces. Generated reference sections describe the
declarations; architectural explanations and their rationale remain
handwritten in those designs.

## Sources and outputs

`abi/erx_abi.txt` is the root of the architecture-neutral declarations.
It explicitly includes `abi/inspection.txt` and `abi/services/<name>.txt`
as fragments of one declaration model, with shared types and
identifiers declared only once. These fragments hold inspection records
and service operations. Existing ABI and inspection version fields remain
declared in that model; splitting files introduces no new format or version.
Includes stay within `abi/`, have no cycles and resolve to a unique
definition of every qualified name.
Operations are qualified by service; generated names include that service,
so two services can both declare `read` without sharing an operation id.
The architecture file adds only architecture-specific declarations. Device
registers and terminal character classes retain their existing sources.

| Source | Generated outputs | Contract owner |
| --- | --- | --- |
| ABI calls, layouts, rights, limits and architecture binding | C headers and accessors, call stubs for every backend, decoders, Erlang/Ruby representations, field offsets and sizes, compile-time layout assertions | [kernel](design-kernel.md#the-abi-file) |
| Service operation fragments | client stubs, server behaviour declarations and dispatch, bounded request and reply validation, operation identifiers, scoped-handle helpers, error types and reference tables | [domains](design-domains.md#authority) |
| Inspection fragment | C record builders, Erlang types and `erx_schema`, Ruby types and validators, path/field descriptors, shell/host renderers and `/proc` projections | [live machine](design-live.md#inspection-records) |
| ABI status, errno, signal and fault declarations | context-specific status/error translations, diagnostic names and descriptions, signal defaults and fault-to-exit mappings | [programs](design-programs.md#the-posix-lite-personality) |
| ABI log and trace event declarations | typed emitters, bounded record readers, field-name/unit tables and decoders for the inspector and host tools | [kernel](design-kernel.md#trace-ring), [live machine](design-live.md#tracing) |
| Protocol fields, bounds and operation declarations | codecs, per-operation reply checks, valid-input builders, boundary mutations, fuzz entry points and reference tables | [files](design-files.md#the-file-protocol), [programs](design-programs.md#the-program-protocol) |
| Checked system manifest and platform placement records | packed boot-order and configured-domain/device/facet descriptors, watchdog liveness roster, and a host-readable configuration report | [system](design-system.md#the-manifest) |
| Release command metadata and program list | command lookup/help/required-facet catalogs, declared record-field descriptors and callback checks | [shell](design-shell.md#interfaces) |
| SVD and system-register specifications | typed accessors, device descriptor helpers and register-field decoding tables | [hardware sources](design.md#one-source-for-the-abi-and-the-hardware) |
| Terminal rules and OTP's pinned Unicode data | C/Erlang/Ruby escaping and terminal allowlist tables | [terminal rules](design-live.md#terminal-filter-rules) |

Existing declarations are extended for these outputs; a generator never
keeps another copy of a layout or operation list. Protocol-specific
frontends feed a common validated declaration model where they share
types and bounds. They do not require a general programming language in
the schema or a general runtime RPC framework.

## Service interfaces

Each service operation declares its request and result variants, bounds
on bytes, counts and nesting, its declared errors, and the authority each
target needs. Bounded opaque bytes remain opaque; a decoder does not
interpret them as terms or create atoms from received names. Input-derived
lengths and offsets use checked arithmetic before allocation or access.
An unbounded or unsupported declaration fails generation.

Generated C and Erlang clients construct and validate requests and check
replies against the operation and outstanding request. Ruby clients are
emitted for services exposed through the host link. The stubs use the
existing connection, facet, alias and program-channel contracts: they
introduce no transport, retry policy or implicit reconnection. They never
retry an operation merely because its reply was lost.

The generated server behaviour has one serving path. It preserves the
facet's classification of replies, signals and requests, authenticates
origin from the receiving lane, validates the request and reply target,
and applies the live grant's scope and rate limits before the callback.
Handwritten policy decides scope membership and mutable preconditions;
generated code calls that policy at admission and mints only handles
justified by its result. The resulting action follows the core's existing
locking, reservation or generation-validation rule, so a changed scope or
target cannot invalidate an unchecked admission before its effect.
Handlers receive validated data and scoped
handles. Authority-consuming effects are callable only through the
generated helpers, enforced by the existing build checks. A declared
right, a client stub or a pid is never authority by itself.

Callbacks perform pure decisions and explicit effects; a schema does not
choose grant policy, scheduling or resource lifetimes. Reply validation
enforces the declared shape and bound before publication. Native programs
continue to speak only to their handlers, which use generated service
clients with the session's authority. Generated dispatch never gives a
program another domain's capabilities or facets.

## Inspection and diagnostics

Each inspection kind declares its paths and attribute keys, value types,
units, bounds, permitted reporter categories and visibility requirements.
Builders and validators preserve the existing tagged statuses, including
`partial`, `unknown`, `unsupported`, `timeout` and `error`, without filling
missing observations with successful defaults. C declarations describe the
bounded kernel representation; Erlang and Ruby projections represent the
same information rather than copying native structures onto the wire.

The inspector authenticates who supplied a record and applies the caller's
facet scope before rendering or projecting it. Reporter tags do not
authenticate a source. Runtime assertions remain marked as runtime reports.
Generated path dispatch calls handwritten scope checks and data collectors;
it does not enumerate restricted objects before authorizing the query.
Unknown field names are refused without making atoms. Adding a schema field
does not expose it automatically: its visibility rule and each public
projection must be declared. The previous-boot crash record retains its
system-shell requirement regardless of an inspect facet's scope.

Shell, host and `/proc` output share generated field order, unit labels
and status/reporter formatting. Dynamic names and values still pass through
the sink's one escaper; `/proc` names use its injective encoding and values
use its tab/newline/backslash framing. Schema formatting cannot bypass
either operation. Error descriptions contain no raw request data.

Error translations are explicit directed mappings, not reversible aliases.
Where one kernel status has different POSIX meanings, the declaration
names the operation or translation context. Every declared status and
protocol error has a mapping or an explicit "not exposed here" result for
each consumer that needs one. A missing case fails generation; there is
no catch-all success or `EIO`. Unknown untrusted error codes follow the
owning protocol's specified diagnostic/fallback rule. POSIX numbers are
checked against the selected musl headers and 9P's Linux numbering;
generation never redefines those external interfaces.

Log and trace emitters accept the fields an event declares, with types,
units, bounds and sensitivity marks. Per-build projections explicitly
select fields: a release record cannot acquire a development-only field
merely because its type contains one. Dynamic text goes through the
existing log or terminal escaper. Snapshot accessors retain one-load
semantics; generation does not make shared data trustworthy or atomic.

## Configuration and command catalogs

The packer validates the system manifest and then emits its ordered
descriptor arrays into that same packed manifest. Root-task and Erlang
readers obtain startup, device assignment, configured facets and liveness
targets from those arrays. There is no parallel compiled configuration
table and no generated C function that performs domain creation without
the domain library's whole-plan validation. The host report is a derived
artifact and cannot configure a boot. Equal dependency choices use a
stable name order so equivalent inputs produce identical images.

The release build extracts command names, help, required facets and
declared output fields from module metadata, and native commands from the
image's program list. It generates the lookup catalog and validates
callbacks against their declarations without executing target modules.
Lookup retains the shell's precedence rules and reports conflicting
Erlang names with both origins instead of silently choosing one.
Sessions construct their namespace from the catalogs of the releases
they actually hold; a catalog never installs authority or makes an absent
program available. Live-loaded command modules pass the same metadata
validation before their catalog entries are published. Each runtime entry
binds its metadata to the module's verified blob hash and a local entry
fun created by that code version. The generated module accessor returns
the local fun and its metadata together; the code server associates them
with the verified loaded artifact. Dispatch checks the current binding
and never resolves an old entry through an external fun that follows the
latest module. The local entry fun keeps a load racing a start from
substituting a different version after that check.

Before replacing a command module, its code server makes the affected
entries unavailable to new starts. It validates the candidate's metadata
before loading and publishes the matching bindings after the local load
succeeds. Failure or unknown completion leaves the entries unavailable
until reconciled against the code actually loaded, independently of the
overlay published for restart. A job already started keeps its entry's
metadata; normal OTP code-purge semantics still apply. This provides no
rollback of application state or external effects. User functions,
jobs, executable bodies and the shell parser remain ordinary code/state.

## Reference tables and tests

Generation emits the factual parts of API documentation: signatures,
operation identifiers, fields, variants, units, bounds, declared rights
and error mappings. These are delimited generated sections in the owning
design/reference documents, checked for drift. Handwritten examples and
architectural rationale are separate from those sections. A reference
table does not become another input to the generator.

Each generated parser lands with input builders and a fuzz entry point
that calls the production decoder. Deterministic boundary cases cover
empty and maximum values, one past the bound, truncation, invalid tags,
and checked-arithmetic failures. Mutation helpers change fields and lengths
without repairing them through the encoder. Round trips and generated
cases supplement independently constructed fixtures and external oracles;
matching encoder/decoder mistakes must have an independent place to fail.

Generator tests seed invalid declarations: duplicate identifiers, undefined
types, missing mappings, unbounded messages, absent visibility rules and
authority declarations that cannot reach a checked helper. Catalog tests
race starts with module replacement and inject failure before and after
code load and catalog publication, with changed facet requirements, fields
and callbacks. No start may pair one version's metadata with another's
entry code. Independent
hostile tests exercise unauthorized origins, stale handles, restricted
inspection fields and mismatched replies. TLA+/TLC properties remain
independent specifications rather than outputs of these generators.

## Build contract

Generators are Ruby tools with a pure parse/validate/derive core. They
validate the complete input and output plan before publishing any output.
They run offline, with pinned third-party data, deterministic ordering
and explicit input/output inventories. A schema change regenerates all
affected language bindings, documentation and fixtures in one change.
Generated source is ASCII-only, readable and subject to the normal style,
stack, sanitizer and chokepoint checks. C code uses typed loads/accessors
and checked arithmetic rather than packed-structure casts or unchecked
pointer arithmetic over input. Data tables contain no new function-pointer
escape from the kernel's listed call targets.

`make check` regenerates into a temporary tree and compares output paths
and bytes with the declared generated artifacts, catching stale, missing
and orphaned outputs. Every generated artifact identifies its source and
generator. Schema parsers reject unknown declarations; targets refuse
unsupported ABI/schema versions with a diagnostic. No generator emits
migration code or readers for old erXos formats.

The roadmap introduces each schema extension with its first consumer.
Generation does not delay the usable slice to build machinery for services
or protocols that slice does not need.

## References

* [OTP 29.1.2 fun semantics](https://www.erlang.org/doc/apps/erts/erlang.html#fun_info/1):
  local funs call the code version that created them; external funs follow
  the latest module version.
