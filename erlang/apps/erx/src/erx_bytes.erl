%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The per-byte primitives (docs/design-runtime.md, "Per-byte primitives"): the work done once
%% per byte is C, behind these calls. A call takes at most 64 KiB, so it stays within a
%% reduction slice; the caller streams longer inputs, passing each result as the next call's
%% first argument.

-module(erx_bytes).

-export([crc32c/2]).

-nifs([crc32c_nif/2]).
-on_load(on_load/0).

-spec on_load() -> ok | {error, term()}.
on_load() ->
    erlang:load_nif(atom_to_list(?MODULE), #{}).

%% CRC-32C (Castagnoli, as RFC 3720 uses it) of Data, continuing from Crc, the value of the
%% bytes before it (0 for none). crc32c(crc32c(0, A), B) is crc32c(0, <<A/binary, B/binary>>).
%% The size is checked here, before the NIF can copy a misaligned binary.
%% Fails with badarg unless Crc is in 0..16#FFFFFFFF and Data is a binary of at most 65536 bytes.
-spec crc32c(Crc :: 0..16#FFFFFFFF, Data :: binary()) -> 0..16#FFFFFFFF.
crc32c(Crc, Data)
  when is_integer(Crc), Crc >= 0, Crc =< 16#FFFFFFFF, is_binary(Data), byte_size(Data) =< 65536 ->
    crc32c_nif(Crc, Data);
crc32c(_Crc, _Data) ->
    erlang:error(badarg).

crc32c_nif(_Crc, _Data) ->
    erlang:nif_error(undef).
