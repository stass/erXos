# Hardware and terminal generation

The hardware sources and their consumers follow
[the kernel contract](design-kernel.md#hardware-register-sources).
The generator reads complete inputs, validates a typed immutable model,
and constructs the complete path/byte output plan before publishing.
Unknown semantics fail; a source is never partially interpreted.

## Register inputs

CMSIS-SVD supplies peripheral register names, offsets, widths, access,
fields and enumerated values. The input profile uses bounded XML with
no document types, entities or external references. A register array is
`NAME[%s]` with `dim` and `dimIncrement`. Each register carries the profile's
one extension, `ownedByNif`, saying whether the device NIF owns it and writes it
only in sequences of its own (a ring's base address, a queue's setup, the
device's status and features); `erx/hw/device_owned.h` names each owned register
by its index in the table, for `erx_device.c` alone;
a register without it is refused. A register is 8, 16, 32 or 64 bits wide, at an
offset aligned to its width, and every access to it is one access of that width,
as the virtio specification asks of a device's configuration fields (OASIS
Virtio 1.2, sections 4.2.2.2 and 4.1.3.1).

One file may describe several peripherals. A group of registers several
peripherals share is written once, as a `cluster` leading one peripheral, and each
other peripheral copies it with a cluster `derivedFrom="PERIPHERAL.CLUSTER"` as its
own first element, at the same offset and adding nothing, then declares registers
of its own. That is CMSIS-SVD's derivation (svd-spec v1.3.9,
`doxygen/src/svd_schema.txt`, the cluster element): a derived section copies its
source, and anything it restates overrides what it inherits; the specification
defines no merge of a peripheral's register list, so derivation is of a cluster,
never of a peripheral that then adds registers. The profile has one cluster level,
no cluster arrays and no derivation from a derived peripheral, and a cluster's
registers keep their own names. The copied registers lead both tables at the same
indices, and the table records the peripheral a kind derives from, so the device NIF
treats every kind as its transport. The virtio-mmio transport is such a cluster, and
each device kind a peripheral that copies it and adds its configuration fields
(`hw/svd/virtio_mmio/virtio_mmio.svd`). Other inheritance or access-sequence
extensions fail until their semantic consumer is implemented. Registers fit their address block and cannot
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

An SVD that a vendor publishes enters the tree as an import: `hw/svd/<device>/ORIGIN.md` records its
repository, release and SHA-256, and lists each edit the profile needed, which
a script under `tools/` makes again from the pinned upstream file. The file keeps the
vendor's license notice and descriptions, and only the peripheral erXos drives
enters the tree. The PL011's is the Raspberry Pi Pico SDK's UART0.

The same model produces the table `erx_device` resolves Erlang's register
names through ([design-runtime.md](design-runtime.md#the-device-nif)):
`include/erx/hw/device_types.h` its shapes, `device_table.h` each peripheral's
registers and fields, lower-cased, with window, offset, width, array shape,
access, masks, the device-address mark, whether a field may be replaced by
a read and a write, and the peripheral a kind derives from; `device_access.h` the one volatile load and store of each
width. No peripheral may take one of those names. A bit the source does not declare
is written as zero, by a field's update too, so a register's source declares every bit
the hardware implements.

An Erlang driver takes its peripheral's fields from the same model, so it never
packs a register's bits by hand or copies a mask:
`erlang/apps/erx/include/generated/erx_hw_<peripheral>.hrl`, which a module
includes as `-include("generated/erx_hw_<peripheral>.hrl")`, defines for each
field of each register, as `ERX_HW_<PERIPHERAL>_<REGISTER>_<FIELD>_*`, its shift,
width and mask in place, a macro taking the field from a word, a guard that a
value fits it, a macro placing a value in a word, which fails with `badfield`
on a value that does not fit rather than spilling into the neighbouring
fields, and each value the source names for it. These are arithmetic on a
word only: a driver still reads and writes a register through `erx_device` by
name, which refuses what the register does not allow. The macro names share
one namespace, read from the headers themselves and checked like the C
symbols, so a value named for a macro suffix or two paths meeting at one name
are refused.

The system-register extractor consumes the pinned Arm register package
and a checked selection/attribute file. Encodings, widths and field ranges
come only from that package. erXos declares allowed read/write operations,
side effects and required synchronization beside those facts. The
extractor rejects missing, ambiguous and unsupported selected records;
it never picks the first alternative field layout. The derived JSON keeps
Arm's notice and exact source identity. The generator uses that checked-in
JSON offline; the extraction check recreates it from the pinned input.

## Escape rules

`abi/terminal.txt` declares the unsafe character classes. Pinned OTP Unicode
data supplies category and default-ignorable ranges. The generator emits C,
Erlang and Ruby tables from one normalized interval set. Input-derived names
never become atoms. The table consumer escapes invalid UTF-8, controls and
unsafe formatting characters in text labelled with its source before it is
displayed on the host or the target. A conservative ASCII host sink can escape
additional printable characters without admitting anything the generated
policy refuses.

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
