%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A driver's view of its device (docs/design-runtime.md, "The device NIF").
%% Registers and fields go by name, as tools/gen_hw.rb's table has them from the
%% CMSIS-SVD source, lower-cased: no address or offset exists here, and a name the table
%% lacks is badarg, as is anything the table does not allow. read/2, write/3,
%% read_field/3, write_field/4, field/4 and irq_ack/2 are BIFs in ERTS (beam/bif.tab), since a
%% driver makes them one at a time; the clauses below stand for them only in xref and
%% documentation. open/1, irq_bind/2 and the queue calls are NIFs.
%%
%% A read or a write is one volatile access and never waits. write_field/4 on an ordinary
%% field reads the word and writes it back, so a field's update is not atomic against
%% another process using the device; a device has one driver. On a one-to-clear field it
%% is one write. It is badarg where a read has a side effect: such a register is written
%% whole with write/3. Both are badarg for a register the NIF owns, which the SVD source
%% marks `ownedByNif` (virtio's status, features, queue setup, doorbell and ring
%% addresses): only the NIF's own sequences write those, negotiate/2 and post/4.
%%
%% irq_bind/2 makes the calling process the receiver of `{erx_irq, Dev, Line}`, once per
%% fire of the line, at the next safe point. A level-sensitive line stays masked until
%% irq_ack/2. A delivery is a reason to look at the device: it can be spurious. The
%% process's exit unbinds the line unless another process has bound it since.

-module(erx_device).

-export([open/1]).
-export([read/2, write/3, read_field/3, write_field/4, field/4]).
-export([irq_bind/2, irq_ack/2]).
-export([queue_create/4, negotiate/2, post/4, complete/2]).
-export([stand_in_fire/2]).

-export_type([device/0, register_name/0, spec/0, queue/0, segment/0]).

-on_load(init/0).

-opaque device() :: non_neg_integer().
-type register_name() :: atom() | {atom(), non_neg_integer()}.
-type window() :: {physical, Base :: non_neg_integer(), Size :: non_neg_integer()} | stand_in.
-type spec() :: #{peripheral := atom(), window := window(), lines := [non_neg_integer()],
                  dma_memory => non_neg_integer()}.
-opaque queue() :: non_neg_integer().
-type segment() :: {out, binary()} | {in, pos_integer()}.

init() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% The device's record, for the boot: a second open of a window names the same device, so
%% a restarted driver finds what its predecessor had, and the same window with anything
%% else is `{error, ebusy}`, as is a window in a page another device's window holds. Spec is what the device service
%% hands a driver, which does not look inside it: the peripheral's name in the SVD source,
%% its register window and its lines' selectors, and for a device that does DMA the bytes of
%% memory the boot reserves for it (erx_device_record). A hosted runtime has no devices, so
%% `{physical, _, _}` is `{error, enotsup}` there, and `stand_in` gives plain memory and
%% software lines for tests; natively `stand_in` is `{error, enotsup}`.
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

%% Line is the index in the spec's `lines`. An error from the line's first acknowledgement
%% leaves the process bound.
-spec irq_bind(device(), non_neg_integer()) -> ok | {error, atom() | {status, integer()}}.
irq_bind(_Dev, _Line) ->
    erlang:nif_error(undef).

-spec irq_ack(device(), non_neg_integer()) -> ok.
irq_ack(_Dev, _Line) ->
    erlang:nif_error(undef).

%% The device's queue Index, of Size entries, a power of two up to 256, and as many buffers
%% of BufferSize bytes, up to 65536, the pool at most 1 MiB; anything else is badarg. Its
%% rings and buffers are memory of the device's record for the boot, whose addresses never
%% reach Erlang. The same queue again is that queue again, so a restarted driver finds it;
%% the same Index with another geometry is `{error, ebusy}`. A device that is not
%% virtio-mmio version 2 is `{error, enotsup}`, as any queue is on a hosted runtime. The
%% device takes the queue at the next negotiate/2.
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

%% Posts one request of 1 to 4 segments, every `out` before every `in`, laid end to end in
%% a free buffer of the queue: the out bytes are copied in, the device writes the in
%% lengths. There is no buffer to take or fill first, so none is ever held and not posted.
%% Tag, below 2^64, comes back with the completion. `{error, full}` when the queue has too
%% few free descriptors, so the driver waits for completions; `{error, broken}` when the
%% queue needs negotiate/2; badarg for segments longer than a buffer, empty or out of
%% order.
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
