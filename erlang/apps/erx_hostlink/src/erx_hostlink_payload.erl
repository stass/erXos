%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_payload).
-moduledoc """
Phase 1's check of a control payload from the host (docs/design-live.md,
"The host link", "Decoding"), behind the interface that `liberx`'s
`erx_etf` check with the host grammar fills once it exists.

`measure/1` stands where that check stands: before the session reserves
anything for a payload, it gives the payload's decoded size or refuses it.
Until `erx_etf` exists it is a size bound, `binary_to_term/2` in safe mode,
which creates no atom and no external fun, and a walk of the decoded term
for the types the host grammar leaves out. A payload passes when:

* it is at most 16 MiB, the session's message limit;
* it is not compressed (tag 80 after the version byte), whose declared
  size the bound above would not bound;
* it decodes in safe mode with no bytes after the term;
* the term holds no pid, reference, port or fun, so a host cannot turn a
  name it saw in a reply back into a process or reference of the system
  domain, nor hand over code to run.

Its decoded size is the term's flat size in bytes plus the payload's own
size, which bounds the bytes of every binary in the term, since a decoded
binary is never longer than its encoding, and stands for the payload,
which is held until the call ends. What the check is not: the term is
built on the heap before its size is known, up to about sixteen times the
payload's bytes (a list of empty lists). `decode/1` gives the term itself,
under the same checks. Neither raises on any input.
""".

-include("generated/erx_abi.hrl").

-export([measure/1, decode/1]).
-export_type([reason/0]).

-define(ETF_VERSION, 131).
-define(ETF_COMPRESSED, 80).

-type reason() :: too_large | compressed | badarg | type.

-doc "The decoded size of `Payload` in bytes, or why it is refused.".
-spec measure(binary()) -> {ok, non_neg_integer()} | {error, reason()}.
measure(Payload) when is_binary(Payload) ->
    case decode(Payload) of
        {ok, Term} ->
            {ok, byte_size(Payload) + erts_debug:flat_size(Term) * erlang:system_info(wordsize)};
        {error, Reason} ->
            {error, Reason}
    end.

-doc "The term `Payload` encodes, if it passes the checks above.".
-spec decode(binary()) -> {ok, term()} | {error, reason()}.
decode(Payload) when is_binary(Payload), byte_size(Payload) > ?ERX_HOSTLINK_MESSAGE_MAX ->
    {error, too_large};
decode(<<?ETF_VERSION, ?ETF_COMPRESSED, _/binary>>) ->
    {error, compressed};
decode(Payload) when is_binary(Payload) ->
    Size = byte_size(Payload),
    try binary_to_term(Payload, [safe, used]) of
        {Term, Size} -> typed(Term);
        {_Term, _Used} -> {error, badarg}
    catch
        error:badarg -> {error, badarg}
    end.

%% The term, if it holds only the host grammar's types: no pid, reference,
%% port or fun anywhere. The walk keeps its own list of terms still to see,
%% so a deeply nested term needs no deep recursion.
typed(Term) ->
    case plain([Term]) of
        true -> {ok, Term};
        false -> {error, type}
    end.

plain([]) -> true;
plain([[Head | Tail] | Rest]) -> plain([Head, Tail | Rest]);
plain([Tuple | Rest]) when is_tuple(Tuple) -> plain(tuple_to_list(Tuple) ++ Rest);
plain([Map | Rest]) when is_map(Map) -> plain(maps:keys(Map) ++ maps:values(Map) ++ Rest);
plain([Other | _Rest])
  when is_pid(Other); is_reference(Other); is_port(Other); is_function(Other) -> false;
plain([_Leaf | Rest]) -> plain(Rest).
