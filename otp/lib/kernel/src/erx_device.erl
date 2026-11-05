%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A driver's view of its device (docs/design-runtime.md, "The device NIF").
%% Registers and fields go by name, as tools/gen_hw.rb's table has them from the
%% CMSIS-SVD source, lower-cased: no address or offset exists here, and a name the table
%% lacks is badarg, as is anything the table does not allow. read/2, write/3,
%% read_field/3, write_field/4 and irq_ack/2 are BIFs in ERTS (beam/bif.tab), since a
%% driver makes them one at a time; the clauses below stand for them only in xref and
%% documentation. open/1 and irq_bind/2 are NIFs.
%%
%% A read or a write is one volatile access and never waits. write_field/4 on an ordinary
%% field reads the word and writes it back, so a field's update is not atomic against
%% another process using the device; a device has one driver. On a one-to-clear field it
%% is one write. It is badarg where a read has a side effect: such a register is written
%% whole with write/3.
%%
%% irq_bind/2 makes the calling process the receiver of `{erx_irq, Dev, Line}`, once per
%% fire of the line, at the next safe point. A level-sensitive line stays masked until
%% irq_ack/2. A delivery is a reason to look at the device: it can be spurious. The
%% process's exit unbinds the line unless another process has bound it since.

-module(erx_device).

-export([open/1]).
-export([read/2, write/3, read_field/3, write_field/4]).
-export([irq_bind/2, irq_ack/2]).
-export([stand_in_fire/2]).

-export_type([device/0, register_name/0]).

-on_load(init/0).

-opaque device() :: non_neg_integer().
-type register_name() :: atom() | {atom(), non_neg_integer()}.
-type window() :: {physical, Base :: non_neg_integer(), Size :: non_neg_integer()} | stand_in.
-type spec() :: #{peripheral := atom(), window := window(), lines := [non_neg_integer()]}.

init() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% The device's record, for the boot: a second open of a window names the same device, so
%% a restarted driver finds what its predecessor had, and the same window with anything
%% else is `{error, ebusy}`. Spec is what the device service
%% hands a driver, which does not look inside it: the peripheral's name in the SVD source,
%% its register window and its lines' selectors. A hosted runtime has no devices, so
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

%% Line is the index in the spec's `lines`. An error from the line's first acknowledgement
%% leaves the process bound.
-spec irq_bind(device(), non_neg_integer()) -> ok | {error, atom() | {status, integer()}}.
irq_bind(_Dev, _Line) ->
    erlang:nif_error(undef).

-spec irq_ack(device(), non_neg_integer()) -> ok.
irq_ack(_Dev, _Line) ->
    erlang:nif_error(undef).

%% Hosted only: fires a stand-in's line, as a device would. Natively this stays undef.
-spec stand_in_fire(device(), non_neg_integer()) -> ok.
stand_in_fire(_Dev, _Line) ->
    erlang:nif_error(undef).
