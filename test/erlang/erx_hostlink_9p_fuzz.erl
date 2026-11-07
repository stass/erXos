%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_9p_fuzz).
-moduledoc """
The fuzz target of the host link's 9P bridge core, `erx_hostlink_9p`, run by
tools/fuzz/erx_hostlink_9p.rb on stock's emulator.

Each round drives a fresh bridge, with a pool of three fids and two stand-in
grants, through a run of events: 9P2000.L requests as a host sends them, with
random fids, tags and fields, some with their bytes flipped, cut or replaced
by random bytes; replies of the grants, well formed or not, to the aliases
the bridge used and to aliases it never made; and grants that end. After
every step it checks what the bridge promises: it never crashes, every
message it sends the host is one 9P2000.L reply within the stream's msize,
every request it sends a grant passes the grammar, and its fid table, tags
and pending requests stay within their bounds.
""".

-export([run/1]).

-define(MSIZE, 8192).
-define(POOL, 3).
-define(ROUNDS, 400).
-define(STEPS, 300).
-define(NOFID, 16#ffffffff).

run([Seed]) ->
    rand:seed(exsss, {9, 4, list_to_integer(Seed)}),
    A = spawn(fun() -> receive stop -> ok end end),
    B = spawn(fun() -> receive stop -> ok end end),
    Trees = fun(<<"a">>) -> {ok, A}; (<<"b">>) -> {ok, B}; (_) -> error end,
    lists:foreach(fun(_) -> round(erx_hostlink_9p:new(#{trees => Trees, pool => ?POOL}), [A, B]) end,
                  lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~b rounds ok~n", [?ROUNDS]).

round(Bridge, Grants) ->
    Open = {host, erx_9p:encode(0, {version, ?MSIZE, <<"9P2000.L">>}), make_ref(), 0},
    {Opened, _} = erx_hostlink_9p:step(Open, Bridge),
    lists:foldl(fun(_, {Br, Aliases}) -> step(Br, Aliases, Grants) end, {Opened, []}, lists:seq(1, ?STEPS)).

step(Bridge, Aliases, Grants) ->
    Event = case rand:uniform(40) of
                N when N =< 24 -> {host, host_bytes(), make_ref(), rand:uniform(1000000)};
                N when N =< 39, Aliases =/= [] -> {reply, pick(Aliases), reply()};
                N when N =< 39 -> {reply, make_ref(), reply()};
                40 -> {grant_down, pick(Grants)}
            end,
    {Bridge1, Effects} = erx_hostlink_9p:step(Event, Bridge),
    lists:foreach(fun check_effect/1, Effects),
    check_bounds(erx_hostlink_9p:info(Bridge1)),
    Sent = [Alias || {grant, _, Alias, _} <- Effects],
    Answered = case Event of {reply, Replied, _} -> [Replied]; _ -> [] end,
    {Bridge1, lists:sublist(Sent ++ (Aliases -- Answered), 64)}.

check_effect({host, Bytes}) ->
    case erx_9p:decode(Bytes, ?MSIZE) of
        {ok, _, {reply, _, _}} -> ok;
        Other -> erlang:error({not_a_reply, Other, Bytes})
    end;
check_effect({grant, Grant, Alias, Request}) when is_pid(Grant), is_reference(Alias) ->
    case erx_9p_grammar:decode_request(Request) of
        {ok, _} -> ok;
        {error, _} -> erlang:error({invalid_request_to_grant, Request})
    end;
check_effect({monitor, Grant}) when is_pid(Grant) -> ok;
check_effect({clunk, Grant, Fid}) when is_pid(Grant), is_integer(Fid) -> ok;
check_effect({unalias, Alias}) when is_reference(Alias) -> ok;
check_effect(Effect) -> erlang:error({unknown_effect, Effect}).

check_bounds(#{fids := Fids, tags := Tags, requests := Requests} = Info) ->
    case Fids =< ?POOL andalso Tags =< 64 andalso Requests >= 0 andalso Requests =< 32
        andalso Requests =< Tags of
        true -> ok;
        false -> erlang:error({out_of_bounds, Info})
    end.

%% A request's bytes, valid or damaged.
host_bytes() ->
    Tag = rand:uniform(80) - 1,
    %% A field the codec refuses, such as a name of "..", has no bytes to send.
    Valid = try erx_9p:encode(Tag, request())
            catch error:badarg -> erx_9p:encode(Tag, {clunk, 1})
            end,
    case rand:uniform(8) of
        1 -> rand:bytes(rand:uniform(40));
        2 -> flip(Valid);
        3 -> binary:part(Valid, 0, rand:uniform(byte_size(Valid)));
        _ -> Valid
    end.

flip(Bytes) ->
    At = rand:uniform(byte_size(Bytes)) - 1,
    <<Head:At/binary, Byte, Tail/binary>> = Bytes,
    <<Head/binary, (Byte bxor rand:uniform(255)), Tail/binary>>.

request() ->
    Fid = fun() -> rand:uniform(12) - 1 end,
    Name = fun() -> pick([<<"a">>, <<"f">>, <<"..">>, <<"x">>]) end,
    Version = fun() -> {version, pick([4095, 4096, 8192, 65560]), pick([<<"9P2000.L">>, <<"9P2000">>])} end,
    Requests = [          fun() -> {auth, Fid(), <<"u">>, <<"a">>, 0} end,
          fun() -> {attach, Fid(), pick([?NOFID, 3]), <<"u">>, pick([<<"a">>, <<"b">>, <<"c">>]), 0} end,
          fun() -> {walk, Fid(), Fid(), [Name() || _ <- lists:seq(1, rand:uniform(4) - 1)]} end,
          fun() -> {lopen, Fid(), pick([0, 1, 2])} end,
          fun() -> {read, Fid(), rand:uniform(100), pick([1, 100, 8192, 65536])} end,
          fun() -> {readdir, Fid(), 0, pick([1, 8192, 65536])} end,
          fun() -> {write, Fid(), 0, rand:bytes(rand:uniform(64))} end,
          fun() -> {clunk, Fid()} end,
          fun() -> {remove, Fid()} end,
          fun() -> {flush, rand:uniform(80) - 1} end,
          fun() -> {renameat, Fid(), Name(), Fid(), Name()} end,
          fun() -> {xattrwalk, Fid(), Fid(), <<>>} end,
          fun() -> {getattr, Fid(), 16#3fff} end,
          fun() -> {lcreate, Fid(), Name(), 2, 8#644, 0} end],
    %% A version resets the session, so it comes once in about 60 requests.
    case rand:uniform(60) of
        1 -> Version();
        _ -> (pick(Requests))()
    end.

reply() ->
    Qid = {pick([0, 16#80]), 0, rand:uniform(100)},
    pick([ok, {error, enoent}, {error, emfile}, {error, nonsense}, {ok, Qid}, {ok, [Qid]},
          {ok, [Qid, Qid, Qid]}, {ok, lists:duplicate(17, Qid)}, {ok, <<"abc">>},
          {ok, rand:bytes(9000)}, {ok, Qid, 65536}, {ok, 3, 0}, {ok, 3, unknown}, junk,
          {ok, [{Qid, 1, 4, <<"f">>}]}, {ok, 7}, {ok, not_a_qid, 4}]).

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
