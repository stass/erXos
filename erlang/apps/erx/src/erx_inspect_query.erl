%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspect_query).
-moduledoc """
The decoder of a request an inspect facet admits (docs/design-live.md, "The
inspect service", Bounds): the one reader of what another domain asks the
inspector, pure, so its fuzz target (test/erlang/erx_inspect_query_fuzz.erl)
runs it alone.

A request is the term the funnel decoded from the grantee's frame, in safe
mode, so every atom in it already existed. It is one of the interface's two
operations:

* `{inspect, Path, Options}`, where Options is a map holding at most
  `offset`, a sequence number below 2^64, and `limit`, a page of 1 to
  1,000 entries;
* `{entries, Path}`.

Path is a proper list of at most 16 segments, each an atom that is a
literal of a path abi/inspection.txt declares, an integer below 2^64, a
`proc_id()` `{pid, D, N, S}` of three integers each below 2^32, or a
binary of at most 765 bytes, the longest encoded entry name. Anything else
is `{error, badarg}`: a scope, or any other key, in the options, an extra
element, or a segment of another shape. So nothing a holder sends names a
scope, and the facet's own is the only one a query runs at. decode/1
creates no atom and walks at most the 16 segments it accepts.
""".

-export([decode/1]).
-export_type([query/0]).

-type query() :: erx_inspect_worker:query().

-include("generated/erx_abi.hrl").

%% docs/design-live.md, "The inspect service", Bounds: abi/services/inspect.txt's limits.
-define(U32, 16#100000000).
-define(U64, 16#10000000000000000).

-doc "The query Request asks, or `{error, badarg}` for anything the interface does not take.".
-spec decode(term()) -> {ok, query()} | {error, badarg}.
decode({inspect, Path, Options}) ->
    case path(Path, 0, literals()) andalso options(Options) of
        true -> {ok, {inspect, Path, Options}};
        false -> {error, badarg}
    end;
decode({entries, Path}) ->
    case path(Path, 0, literals()) of
        true -> {ok, {entries, Path}};
        false -> {error, badarg}
    end;
decode(_Request) ->
    {error, badarg}.

%% A proper list of at most ?ERX_INSPECT_PATH_MAX segments, walked no further than that.
path([], _Count, _Literals) ->
    true;
path([Segment | Rest], Count, Literals) when Count < ?ERX_INSPECT_PATH_MAX ->
    segment(Segment, Literals) andalso path(Rest, Count + 1, Literals);
path(_Path, _Count, _Literals) ->
    false.

segment(Atom, Literals) when is_atom(Atom) ->
    lists:member(Atom, Literals);
segment(Integer, _Literals) when is_integer(Integer) ->
    Integer >= 0 andalso Integer < ?U64;
segment({pid, D, N, S}, _Literals) ->
    lists:all(fun(Part) -> is_integer(Part) andalso Part >= 0 andalso Part < ?U32 end, [D, N, S]);
segment(Text, _Literals) when is_binary(Text) ->
    byte_size(Text) =< ?ERX_INSPECT_NAME_MAX;
segment(_Segment, _Literals) ->
    false.

%% The literal segments of the paths the schema declares: the atoms a path
%% may hold, gathered once for each request.
literals() ->
    lists:usort([Atom || #{pattern := Pattern} <- erx_schema:declarations(), Atom <- Pattern, is_atom(Atom)]).

options(Options) when is_map(Options) ->
    map_size(maps:without([offset, limit], Options)) =:= 0 andalso
        offset(maps:get(offset, Options, 0)) andalso limit(maps:get(limit, Options, ?ERX_INSPECT_PAGE_MAX));
options(_Options) ->
    false.

offset(Offset) -> is_integer(Offset) andalso Offset >= 0 andalso Offset < ?U64.

limit(Limit) -> is_integer(Limit) andalso Limit >= 1 andalso Limit =< ?ERX_INSPECT_PAGE_MAX.
