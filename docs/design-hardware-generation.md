# Hardware and terminal generation

The hardware sources and their consumers follow
[the kernel contract](design-kernel.md#hardware-register-sources).
The generator reads complete inputs, validates a typed immutable model,
and constructs the complete path/byte output plan before publishing.
Unknown semantics fail; a source is never partially interpreted.

## Register inputs

CMSIS-SVD supplies peripheral register names, offsets, widths, access,
fields and enumerated values. The input profile uses bounded XML with
no document types, entities or external references. Unsupported arrays,
inheritance or access-sequence extensions fail until their semantic
consumer is implemented. Registers fit their address block and cannot
overlap. Fields fit their register, cannot overlap, and every enumerated
value fits its field. Names and generated symbols are unique.

Read accessors perform one volatile access of the declared width. Write
accessors refuse values outside writable bits. A read with side effects
has no read-modify-write accessor; a one-to-clear field has a clear
operation rather than a setter. Field extraction and insertion are pure
unsigned operations, including full-width fields without undefined shifts.
Whole-register read-modify-write is emitted only when every writable field
uses ordinary replacement semantics; a side-effect field excludes that
operation for all its siblings too.
The supported SVD profile rejects a register mixing ordinary writable
fields with one-to-clear fields: clearing one field cannot silently replace
the ordinary siblings. Such a device needs an explicit access sequence.
Hardware access remains an effect owned by the device shim or the
kernel's early-console writer, as their separate chokepoints require.

The system-register extractor consumes the pinned Arm register package
and a checked selection/attribute file. Encodings, widths and field ranges
come only from that package. erXos declares allowed read/write operations,
side effects and required synchronization beside those facts. The
extractor rejects missing, ambiguous and unsupported selected records;
it never picks the first alternative field layout. The derived JSON keeps
Arm's notice and exact source identity. The generator uses that checked-in
JSON offline; the extraction check recreates it from the pinned input.

## Terminal rules

`abi/terminal.txt` declares the unsafe character classes and terminal
sequence allowlist. Pinned OTP Unicode data supplies category and
default-ignorable ranges. The generator emits C, Erlang and Ruby tables
from one normalized interval set. Input-derived names never become atoms.
The table consumer escapes invalid UTF-8, controls and unsafe formatting
characters before host or target terminal output. A conservative ASCII
host sink can escape additional printable characters without admitting
anything the generated policy refuses.

## Output checks

Each frontend owns an explicit output inventory. Drift checking compares
paths and bytes, including missing and orphaned artifacts, in a private
temporary directory. Generated code is ASCII and carries source provenance.
Independent fixtures exercise mask boundaries, side effects and malformed
inputs; fuzz targets call production readers. Cross-compilation checks
system-register instruction encodings against independent expected words.
Architecture terms and hardware instructions stay in their binding layers.
The vocabulary gate reads literal word and prefix declarations from
`hw/arch_terms/`. It checks erXos's generic kernel, library and system
sources and architecture-neutral design documents; architecture, platform
and hardware binding directories and their binding documents own the
concrete names. Underscores delimit terms too, so embedding a mode name
inside a C identifier does not hide it from the gate.
