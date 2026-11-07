%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The trace rings' reader and the clock pair of erx:trace (docs/design-live.md, "Tracing").
%% Both functions are BIFs of ERTS (nifs/erxos/erx_trace_ring_bif.c); the bodies below run
%% only where the BIFs are absent, as on stock OTP.

-module(erx_trace_ring).
-moduledoc "The trace rings' reader and the clock pair that converts ERTS's monotonic time.".

-export([read/3, clocks/0]).
-export_type([source/0, cursor/0, ring_record/0]).

-type source() :: backend | {kernel, Cpu :: 0..16#ffffffff}.
-type cursor() :: present | 0..16#fffffffffffffffe.
%% The erx_trace_record fields after seq, as integers: erx_tracer names them with
%% erx_abi_events.
-type ring_record() :: {TimeNs :: non_neg_integer(), Event :: non_neg_integer(),
                   Cpu :: non_neg_integer(), Flags :: non_neg_integer(),
                   Thread :: non_neg_integer(), Space :: non_neg_integer(),
                   {non_neg_integer(), non_neg_integer(), non_neg_integer()}}.

-doc "Reads at most Max (1 to 512) records of Source's ring from Cursor; badarg otherwise.".
-spec read(source(), cursor(), 1..512) ->
          {ok, [ring_record()], Next :: non_neg_integer(), Overwritten :: non_neg_integer()}
        | {error, unsupported | atom()}.
read(_Source, _Cursor, _Max) ->
    erlang:nif_error(undef).

-doc "{erlang:monotonic_time(nanosecond), erx_clock_ns}, read back to back.".
-spec clocks() -> {integer(), non_neg_integer()}.
clocks() ->
    erlang:nif_error(undef).
