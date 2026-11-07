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
every request it sends a grant passes the grammar, and its fid table, tags,
pending and draining requests stay within their bounds.

It also checks the order of the answers as a host sees them: it keeps the
tags the host has in use, from each request the bridge admitted (one it did
not count as discarded) until its answer, and a version frees them all. An
answer on a tag not in use fails, and so does an answer on a tag after the
`Rflush` of a flush that named it, until the host uses the tag again: the
host may reuse a tag once a flush of it is answered (flush(5)).
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
    lists:foldl(fun(_, {Br, Aliases, Host}) -> step(Br, Aliases, Host, Grants) end, {Opened, [], #{}},
                lists:seq(1, ?STEPS)).

step(Bridge, Aliases, Host, Grants) ->
    Event = case rand:uniform(40) of
                N when N =< 24 -> {host, host_bytes(Host), make_ref(), rand:uniform(1000000)};
                N when N =< 30, Aliases =/= [] -> {reply, pick(Aliases), reply()};
                N when N =< 39 -> {reply, make_ref(), reply()};
                40 -> {grant_down, pick(Grants)}
            end,
    {Bridge1, Effects} = erx_hostlink_9p:step(Event, Bridge),
    lists:foreach(fun check_effect/1, Effects),
    check_bounds(erx_hostlink_9p:info(Bridge1)),
    Sent = [Alias || {grant, _, Alias, _} <- Effects],
    Answered = case Event of {reply, Replied, _} -> [Replied]; _ -> [] end,
    Host1 = admitted(Event, Bridge, Bridge1, Host),
    Host2 = lists:foldl(fun answered/2, Host1, [Bytes || {host, Bytes} <- Effects]),
    %% The aliases a grant may still answer: what the bridge sent, less what
    %% was answered or forgotten, so what a version forgot drains in time.
    Forgotten = [Alias || {unalias, Alias} <- Effects],
    {Bridge1, Sent ++ ((Aliases -- Answered) -- Forgotten), Host2}.

%% The host's tags in use once the bridge took Event: a request it admitted
%% enters, with a reference of its own and, for a flush, the reference of the
%% request in use on the tag it names; a version the bridge serves frees
%% every tag first, and one whose msize it refuses frees none.
admitted({host, Bytes, _, _}, Before, After, Host) ->
    Discarded = maps:get(counts, erx_hostlink_9p:info(Before)) =/= maps:get(counts, erx_hostlink_9p:info(After)),
    case erx_9p:decode(Bytes, ?MSIZE) of
        {ok, _, {reply, _, _}} -> Host;
        {ok, _, _} when Discarded -> Host;
        {ok, Tag, {version, Msize, _}} when Msize >= 4096 -> #{Tag => {make_ref(), version}};
        {ok, Tag, {flush, Old}} -> Host#{Tag => {make_ref(), {flush, Old, in_use(Old, Host)}}};
        {ok, Tag, _} -> Host#{Tag => {make_ref(), request}};
        {error, _} -> Host
    end;
admitted(_Event, _Before, _After, Host) ->
    Host.

in_use(Tag, Host) ->
    case Host of
        #{Tag := {Ref, _}} -> Ref;
        #{} -> none
    end.

%% One answer to the host: its tag must be in use; a flush's answer frees the
%% tag it named too, when the request it flushed is still in use there.
answered(Bytes, Host) ->
    {ok, Tag, {reply, _, _}} = erx_9p:decode(Bytes, ?MSIZE),
    case maps:take(Tag, Host) of
        {{_, {flush, Old, Ref}}, Rest} when Ref =/= none ->
            case Rest of
                #{Old := {Ref, _}} -> maps:remove(Old, Rest);
                #{} -> Rest
            end;
        {_, Rest} ->
            Rest;
        error ->
            erlang:error({answer_out_of_order, Tag, Host})
    end.

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

check_bounds(#{fids := Fids, tags := Tags, draining := Draining, requests := Requests} = Info) ->
    case Fids =< ?POOL andalso Tags + Draining =< 64 andalso Requests >= 0 andalso Requests =< 32
        andalso Requests =< Tags + Draining of
        true -> ok;
        false -> erlang:error({out_of_bounds, Info})
    end.

%% A request's bytes, valid or damaged.
host_bytes(Host) ->
    Tag = rand:uniform(80) - 1,
    %% A field the codec refuses, such as a name of "..", has no bytes to send.
    Valid = try erx_9p:encode(Tag, request(Host))
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

request(Host) ->
    Fid = fun() -> rand:uniform(6) - 1 end,
    Name = fun() -> pick([<<"a">>, <<"f">>, <<"..">>, <<"x">>]) end,
    Version = fun() -> {version, pick([4095, 4096, 8192, 65560]), pick([<<"9P2000.L">>, <<"9P2000">>])} end,
    %% Requests that make fids come three times as often, so the fid table fills.
    Attach = fun() -> {attach, Fid(), pick([?NOFID, 3]), <<"u">>, pick([<<"a">>, <<"b">>, <<"c">>]), 0} end,
    Walk = fun() -> {walk, Fid(), Fid(), [Name() || _ <- lists:seq(1, rand:uniform(4) - 1)]} end,
    Requests = [Attach, Attach, Attach, Walk, Walk, Walk,
          fun() -> {auth, Fid(), <<"u">>, <<"a">>, 0} end,
          fun() -> {lopen, Fid(), pick([0, 1, 2])} end,
          fun() -> {read, Fid(), rand:uniform(100), pick([1, 100, 8192, 65536])} end,
          fun() -> {readdir, Fid(), 0, pick([1, 8192, 65536])} end,
          fun() -> {write, Fid(), 0, rand:bytes(rand:uniform(64))} end,
          fun() -> {clunk, Fid()} end,
          fun() -> {remove, Fid()} end,
          fun() -> {flush, flushed_tag(Host)} end,
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

%% The tag a flush names: half of them a tag the host has in use, so a flush
%% of a pending flush comes up; the rest any tag, in use or not.
flushed_tag(Host) ->
    case rand:uniform(2) of
        1 when map_size(Host) > 0 -> pick(maps:keys(Host));
        _ -> rand:uniform(80) - 1
    end.
