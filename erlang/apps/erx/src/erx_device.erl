%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A driver's view of its device (docs/design-runtime.md, "The device NIF").
%% Registers and fields go by name, as tools/gen_hw.rb's table has them from the
%% CMSIS-SVD source, lower-cased: no address or offset exists here, and a name the table
%% lacks is badarg, as is anything the table does not allow. read/2, write/3,
%% read_field/3, write_field/4, field/4, irq_ack/2 and command/2 are BIFs in ERTS (beam/bif.tab), since a
%% driver makes them one at a time; the clauses below stand for them only in xref and
%% documentation. open/1, irq_bind/2, irq_bind_owner/2, irq_holder/2, the queue calls, region/3 and framebuffer/0 are NIFs.
%%
%% A read or a write is one volatile access and never waits. write_field/4 on an ordinary
%% field reads the word and writes it back, so a field's update is not atomic against
%% another process using the device; a device has one driver. On a one-to-clear field it
%% is one write. It is badarg where a read has a side effect: such a register is written
%% whole with write/3. Both are badarg for a register the NIF owns, which the SVD source
%% marks `ownedByNif` (virtio's status, features, queue setup, doorbell and ring
%% addresses; SDHCI's DMA addresses and command register): only the NIF's own sequences
%% write those, negotiate/2, post/4 and command/2.
%%
%% command/2 issues one SD command: the one 32-bit write of Word to an SD host
%% controller's command register, cmdtm (docs/design-runtime.md, "Issuing an SD command").
%% It is badarg for a record whose peripheral is not sdhci and for a word that sets a bit
%% no field of cmdtm holds or enables DMA, since no ADMA2 queue is ever armed. Only the
%% block driver's write path, erx_blk_write, calls it (tools/lib/erx/chokepoint_rules/device.rb).
%%
%% irq_bind/2 makes the calling process the receiver of `{erx_irq, Dev, Line}`, once per
%% fire of the line, at the next safe point. A level-sensitive line stays masked until
%% irq_ack/2. A delivery is a reason to look at the device: it can be spurious. The
%% process's exit unbinds the line unless another process has bound it since. A line two
%% devices of the unit name is shared, as the record marks it, and is bound only by its
%% owner, with irq_bind_owner/2 (docs/design-shared-devices.md, "Lines inside a domain");
%% erx_irq_line alone calls the binds and irq_ack/2.

-module(erx_device).

-export([open/1]).
-export([read/2, write/3, read_field/3, write_field/4, field/4, command/2]).
-export([irq_bind/2, irq_bind_owner/2, irq_holder/2, irq_ack/2]).
-export([queue_create/4, negotiate/2, post/4, complete/2, region/3, framebuffer/0]).
-export([stand_in_fire/2, stand_in_used/3, stand_in_transmitted/1, stand_in_receive/2]).

-export_type([device/0, register_name/0, spec/0, queue/0, region/0, framebuffer/0, segment/0]).

-on_load(init/0).

-opaque device() :: non_neg_integer().
-type register_name() :: atom() | {atom(), non_neg_integer()}.
-type window() :: {object, Window :: non_neg_integer(), Offset :: non_neg_integer(), Size :: non_neg_integer()}
                | {physical, Base :: non_neg_integer(), Size :: non_neg_integer()} | stand_in.
-type line() :: {object, Irq :: non_neg_integer()} | non_neg_integer().
%% A line another device of the unit names too, marked by the record's writer.
-type marked_line() :: line() | {shared, line()}.
-type spec() :: #{peripheral := atom(), window := window(), lines := [marked_line()],
                  memory => {object, Memory :: non_neg_integer(), Bytes :: pos_integer()},
                  clock => Hertz :: non_neg_integer(), coherent => boolean()}.
-opaque queue() :: non_neg_integer().
-opaque region() :: non_neg_integer().
-opaque framebuffer() :: non_neg_integer().
-type segment() :: {out, binary()} | {out, {region, region()}} | {in, pos_integer()}.

init() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% The device's record, for the boot: a second open of a window names the same device, so
%% a restarted driver finds what its predecessor had, and the same window with anything
%% else is `{error, ebusy}`, as is a memory object another device's record holds. Records
%% share what their unit shares: a window in the pages another record's window covers uses
%% that run's one mapping, and one whose pages meet that run without being it is
%% `{error, ebusy}`; records naming one line share its IRQ object, and a record that marks
%% the line otherwise than the first, or names a direct line another record names, is
%% `{error, ebusy}`. Spec is what erx_device_record finds for a
%% driver, which does not look inside it: the peripheral's name in the SVD source, and either
%% a given device's objects (`{object, Window, Offset, Size}`, `{object, Irq}` lines and
%% `memory => {object, Memory, Bytes}` for a device that does DMA, whose queues are carved
%% from that one memory, `{error, erange}` past its end) or a physical device's window and
%% line selectors, a UART's, which has no queue (`{error, enotsup}` from queue_create/4).
%% A record's `clock`, the device's clock in hertz, is for its driver: open/1 does
%% not read it. `coherent => true` marks a device whose DMA is cache-coherent, as the device
%% tree says; without it the device is taken as not coherent and has no region/3. Every device that does DMA is given, in the system domain too, whose root gives itself
%% the devices it holds. A hosted runtime has no devices, so either form is an
%% error there, and `stand_in` gives plain memory and software lines for tests; natively
%% `stand_in` is `{error, enotsup}`.
-spec open(spec()) -> {ok, device()} | {error, atom() | {status, integer()}}.
open(_Spec) ->
    erlang:nif_error(undef).

-spec read(device(), register_name()) -> non_neg_integer().
read(_Dev, _Register) ->
    erlang:nif_error(undef).

-spec write(device(), register_name(), non_neg_integer()) -> ok.
write(_Dev, _Register, _Value) ->
    erlang:nif_error(undef).

-spec read_field(device(), register_name(), atom()) -> non_neg_integer().
read_field(_Dev, _Register, _Field) ->
    erlang:nif_error(undef).

-spec write_field(device(), register_name(), atom(), non_neg_integer()) -> ok.
write_field(_Dev, _Register, _Field, _Value) ->
    erlang:nif_error(undef).

%% The field of a word already read from the register, without touching the device. A driver
%% reads DR once, which pops a byte, and decodes the data and error bits of that word.
-spec field(device(), register_name(), atom(), non_neg_integer()) -> non_neg_integer().
field(_Dev, _Register, _Field, _Word) ->
    erlang:nif_error(undef).

%% One SD command (above): ok, or badarg before any access.
-spec command(device(), non_neg_integer()) -> ok.
command(_Dev, _Word) ->
    erlang:nif_error(undef).

%% Line is the index in the spec's `lines`. A bind through the record the line is bound
%% through moves the line to the caller; through another record of the line it is
%% `{error, ebusy}`. `{error, shared}` for a shared line, which only its owner binds. An
%% error from the line's first acknowledgement leaves the process bound.
-spec irq_bind(device(), non_neg_integer()) -> ok | {error, atom() | {status, integer()}}.
irq_bind(_Dev, _Line) ->
    erlang:nif_error(undef).

%% The owner's bind of a shared line, as irq_bind/2 binds a direct one; `{error, direct}`
%% for a direct line.
-spec irq_bind_owner(device(), non_neg_integer()) -> ok | {error, atom() | {status, integer()}}.
irq_bind_owner(_Dev, _Line) ->
    erlang:nif_error(undef).

%% The process the line is bound to, through whichever record of the line bound it.
-spec irq_holder(device(), non_neg_integer()) -> {ok, pid()} | {error, unbound}.
irq_holder(_Dev, _Line) ->
    erlang:nif_error(undef).

-spec irq_ack(device(), non_neg_integer()) -> ok.
irq_ack(_Dev, _Line) ->
    erlang:nif_error(undef).

%% The device's queue Index, of Size entries, a power of two up to 256, and as many buffers
%% of BufferSize bytes, up to 65536, the pool at most 1 MiB; anything else is badarg. Its
%% rings and buffers are memory of the device's record for the boot, whose addresses never
%% reach Erlang. The same queue again is that queue again, so a restarted driver finds it;
%% the same Index with another geometry is `{error, ebusy}`. A device that is not
%% virtio-mmio version 2 is `{error, enotsup}`, as is every queue on a hosted runtime but a
%% stand-in's. The device takes the queue at the next negotiate/2.
-spec queue_create(device(), non_neg_integer(), pos_integer(), pos_integer()) ->
          {ok, queue()} | {error, atom() | {status, integer()}}.
queue_create(_Dev, _Index, _Size, _BufferSize) ->
    erlang:nif_error(undef).

%% Virtio's initialisation, whole, which a driver calls at its start and at every restart,
%% after queue_create/4 for each of its queues: the NIF resets the device and reads the
%% features it offers. Of those it accepts the device type's own bits that Wanted (below
%% 2^64) names, VERSION_1 and an offered ACCESS_PLATFORM always, and never a bit that
%% changes the ring or the transport; it has the device confirm them, installs every queue
%% of the device and sets DRIVER_OK. Installing a queue forgets what was posted on it,
%% returns its buffers to its pool and zeroes its rings, so no descriptor the device held
%% before the reset is used again.
%% `{ok, Accepted}` with the features the device runs with. `{error, enotsup}` for a device
%% that is not virtio-mmio version 2, offers no VERSION_1 or refuses the features;
%% `{error, ebusy}` when the device's status does not read 0 after the reset or it still
%% has a queue ready; `{error, erange}` for a queue larger than the device offers. A
%% failure after the reset leaves the device FAILED, and any failure every queue's post/4 and complete/2
%% `{error, broken}` until a later negotiate/2 succeeds.
-spec negotiate(device(), non_neg_integer()) -> {ok, non_neg_integer()} | {error, atom() | {status, integer()}}.
negotiate(_Dev, _Wanted) ->
    erlang:nif_error(undef).

%% The device's region Index (docs/design-runtime.md, "Regions"): Bytes rounded up to whole
%% pages of the memory the device's record holds, taken where its queues are, at the first
%% page no queue or region took, so a restarted driver that repeats its calls gets the same
%% region. A new region's bytes are zero. It is kept for the boot and never posted: the
%% device reads it whenever a request names it, by the segment `{out, {region, R}}`, which
%% the NIF writes as the region's device address and length, so no address reaches Erlang.
%% Erlang writes it only through an erx_memdraw:wrap/4 image over R. The same Index with
%% the same Bytes is that region again; with other Bytes, or no Bytes, badarg. `{error,
%% erange}`, taking nothing, for a region past the end of the device's memory;
%% `{error, enotsup}` for a device whose record does not mark it coherent, since nothing
%% would clean the region before the device reads it, and on a hosted runtime but a
%% stand-in's; `{error, elimit}` past the runtime's four regions. R names the region in
%% the whole runtime, so post/4 checks that it is the posting device's.
-spec region(device(), non_neg_integer(), pos_integer()) -> {ok, region()} | {error, atom() | {status, integer()}}.
region(_Dev, _Index, _Bytes) ->
    erlang:nif_error(undef).

%% The domain's own framebuffer: the NIF reads the window of the domain's framebuffer record
%% from the boot page itself (erx_device_record:framebuffers/0 reads the same record), so no
%% handle Erlang names is ever mapped. That window is the pages of the object the root made
%% over the memory the board's firmware set up, mapped as device memory and kept for the boot
%% (docs/design-runtime.md, "The framebuffer"). Fb names it for erx_memdraw:store/4, the one
%% way Erlang writes it, with aligned 32-bit stores; no image is ever made over it and no
%% address reaches Erlang. A second call is that framebuffer again, so a restarted driver gets
%% the same mapping. `{error, enoent}` for a domain without exactly one well-formed record,
%% a hosted runtime's among them; `{error, enotsup}` from a hosted runtime given a record.
-spec framebuffer() -> {ok, framebuffer()} | {error, atom() | {status, integer()}}.
framebuffer() ->
    erlang:nif_error(undef).

%% Posts one request of 1 to 4 segments, every `out` before every `in`, laid end to end in
%% a free buffer of the queue: the out bytes are copied in, the device writes the in
%% lengths. An out segment `{region, R}` is the entry of the device's region R, its device
%% address and length in the layout the device's requests use (virtio-gpu's mem_entry).
%% There is no buffer to take or fill first, so none is ever held and not posted.
%% Tag, below 2^64, comes back with the completion. `{error, full}` when the queue has too
%% few free descriptors, so the driver waits for completions; `{error, broken}` when the
%% queue needs negotiate/2; badarg for segments longer than a buffer, empty or out of
%% order, and for a region that is not the device's.
-spec post(device(), queue(), non_neg_integer(), [segment()]) ->
          ok | {error, full | broken}.
post(_Dev, _Queue, _Tag, _Segments) ->
    erlang:nif_error(undef).

%% What the device has returned, in order, as `{Tag, Bytes}`: Bytes is a fresh binary of
%% what the device wrote into the request's in segments, end to end, cut at the length it
%% reported. One call copies at most 64 KiB and one buffer, so a driver calls again until it gets
%% `{ok, []}`. A device's malformed entry breaks the queue: what came before it is
%% returned, and the next call is `{error, broken}` until negotiate/2.
-spec complete(device(), queue()) -> {ok, [{non_neg_integer(), binary()}]} | {error, broken}.
complete(_Dev, _Queue) ->
    erlang:nif_error(undef).

%% Hosted only: fires a stand-in's line, as a device would. Natively this stays undef.
-spec stand_in_fire(device(), non_neg_integer()) -> ok.
stand_in_fire(_Dev, _Line) ->
    erlang:nif_error(undef).

%% Hosted only: a virtio stand-in's device returns entries on its queue Queue, as a device
%% would, honest or hostile, for complete/2 to judge. Each `{Head, Length}` goes into the
%% next slot of the used ring. Head is `next`, the head the driver made available next, or
%% any id at all. The used index then moves past them all, so returning more entries than
%% are posted is an index ahead. badarg for a device that is not a stand-in, a queue that is
%% not the device's or not installed, or more entries than the queue has. Natively this
%% stays undef.
-spec stand_in_used(device(), queue(), [{next | non_neg_integer(), non_neg_integer()}]) -> ok.
stand_in_used(_Dev, _Queue, _Entries) ->
    erlang:nif_error(undef).

%% Hosted only: a stand-in GENET sends what its transmit ring holds, as its engine would,
%% reading each descriptor and the buffer its address names: the frames posted since the last
%% call, oldest first, without their frame check sequence, and none while its DMA is stopped.
%% `{error, broken}` for a descriptor that is not a whole frame with its CRC, is longer than a
%% buffer, or whose address does not reach its bytes; the frames before it are gone. badarg
%% for a device that is not a stand-in GENET with its rings installed. Natively this stays
%% undef.
-spec stand_in_transmitted(device()) -> [binary()] | {error, broken}.
stand_in_transmitted(_Dev) ->
    erlang:nif_error(undef).

%% Hosted only: a stand-in GENET takes frames off its wire into free receive buffers, in
%% order, each after the padding the driver configured, with its descriptor's status and the
%% producer index set as the controller sets them; the answer is how many fit, at most a
%% ring's worth from the front of Frames, and none while its DMA is stopped. It fires no line:
%% the test fires it with stand_in_fire/2. badarg as for stand_in_transmitted/1, for a frame
%% longer than a buffer takes, or while RBUF_CTRL asks for the 64-byte status block. Natively
%% this stays undef.
-spec stand_in_receive(device(), [binary()]) -> non_neg_integer() | {error, broken}.
stand_in_receive(_Dev, _Frames) ->
    erlang:nif_error(undef).
