%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% Arbitrary terms through erx_9p_grammar, the one decoder of the file protocol's terms:
%% random terms, valid requests with one field replaced, and random replies to valid
%% requests. Whatever arrives, decoding returns and never raises; a request it accepts is
%% the term it was given, its builder accepts exactly what decoding accepts, and its frame
%% decodes the same way; a reply it accepts is rebuilt by its operation's builder. A
%% name in a name field is also classified by reference_name/1, which shares no code with
%% the grammar, and the two must agree. The seed comes from make check-fuzz.

-module(erx_9p_grammar_fuzz).
-export([run/1]).

-define(G, erx_9p_grammar).
-define(ROUNDS, 20000).
-define(DEPTH, 3).

run([Seed]) ->
    rand:seed(exsss, {9, 2000, list_to_integer(Seed)}),
    Valid = valid_requests(),
    lists:foreach(fun(_) ->
                          request_round(random_term(?DEPTH)),
                          request_round(mutated(pick(Valid))),
                          name_round(random_name()),
                          reply_round(pick(Valid), random_reply())
                  end, lists:seq(1, ?ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

request_round(Term) ->
    Alias = make_ref(),
    case ?G:decode_request(Term) of
        {ok, Term} ->
            true = is_boolean(?G:writes(Term)),
            Term = build(Term),
            {ok, Alias, _, Term} = ?G:decode_request_frame({erx_9p, Alias, self(), Term});
        {error, einval} ->
            refused = build(Term),
            {error, Alias, einval} = ?G:decode_request_frame({erx_9p, Alias, self(), Term});
        Other ->
            error({unexpected_decode, Term, Other})
    end.

%% The builder of Term's operation, when Term is a tuple whose first element names one.
build(Term) when is_tuple(Term), tuple_size(Term) >= 1 ->
    [Op | Fields] = tuple_to_list(Term),
    case is_atom(Op) andalso lists:member(Op, ?G:operations()) of
        true ->
            Builder = list_to_existing_atom(atom_to_list(Op) ++ "_request"),
            case erlang:function_exported(?G, Builder, length(Fields)) of
                true ->
                    try apply(?G, Builder, Fields)
                    catch error:badarg -> refused
                    end;
                false -> refused
            end;
        false -> refused
    end;
build(_) ->
    refused.

name_round(Name) ->
    Request = {mkdir, 1, Name, 8#755, 0},
    Decoded = element(1, ?G:decode_request(Request)) =:= ok,
    case Decoded =:= reference_name(Name) of
        true -> ok;
        false -> error({disagrees_with_reference, Name, Decoded})
    end.

%% A name as docs/design-files.md#bounds states it: 1 to 255 bytes of UTF-8 without NUL or
%% "/", and neither "." nor "..", which a server never makes.
reference_name(Name) when is_binary(Name) ->
    Size = byte_size(Name),
    Size >= 1 andalso Size =< 255
        andalso Name =/= <<".">> andalso Name =/= <<"..">>
        andalso not lists:member(0, binary_to_list(Name))
        andalso not lists:member($/, binary_to_list(Name))
        andalso unicode:characters_to_binary(Name, utf8, utf8) =:= Name;
reference_name(_) ->
    false.

reply_round(Request, Reply) ->
    case ?G:decode_reply(Request, Reply) of
        {ok, Reply} -> Reply = rebuilt(element(1, Request), Reply);
        {error, eio} -> ok;
        Other -> error({unexpected_reply_decode, Request, Reply, Other})
    end.

%% An accepted reply has its operation's shape: the operation's reply builder, or
%% error_reply/1, rebuilds it from its fields.
rebuilt(_, {error, Posix}) ->
    ?G:error_reply(Posix);
rebuilt(Op, Reply) ->
    Fields = case Reply of
                 ok -> [];
                 _ -> tl(tuple_to_list(Reply))
             end,
    apply(?G, list_to_existing_atom(atom_to_list(Op) ++ "_reply"), Fields).

valid_requests() ->
    [{version, 65560, <<"9P2000.L">>}, {auth, 16#ffffffff, <<"u">>, <<"tmp">>, 0},
     {attach, 1, 16#ffffffff, <<"u">>, <<"tmp">>, 0}, {walk, 1, 2, [<<"a">>, <<"..">>]},
     {lopen, 1, 2}, {lcreate, 1, <<"f">>, 2, 8#644, 0}, {read, 1, 0, 64}, {write, 1, 0, <<"abc">>},
     {readdir, 1, 0, 128}, {getattr, 1, 16#3fff},
     {setattr, 1, #{valid => 1, mode => 0, uid => 0, gid => 0, size => 0, atime_sec => 0,
                    atime_nsec => 0, mtime_sec => 0, mtime_nsec => 0}},
     {mkdir, 1, <<"d">>, 8#755, 0}, {symlink, 1, <<"l">>, <<"t">>, 0}, {link, 1, 2, <<"h">>},
     {readlink, 1}, {unlinkat, 1, <<"f">>, 0}, {renameat, 1, <<"a">>, 2, <<"b">>}, {statfs, 1},
     {fsync, 1, 0}, {flush, make_ref()}, {clunk, 1}, {mknod, 1, <<"n">>, 0, 0, 0, 0},
     {xattrwalk, 1, 2, <<>>}, {xattrcreate, 1, <<"a">>, 0, 0},
     {lock, 1, 1, 0, 0, 0, 1, <<"h">>}, {getlock, 1, 0, 0, 0, 1, <<"h">>}, {remove, 1}].

mutated(Request) ->
    Index = 1 + rand:uniform(tuple_size(Request) - 1),
    setelement(Index, Request, random_field()).

random_reply() ->
    case rand:uniform(6) of
        1 -> ok;
        2 -> {error, pick([enoent, eio, ebusy, enolck, 2, "eio"])};
        3 -> {ok, random_field()};
        4 -> {ok, random_field(), random_field()};
        5 -> {ok, random_field(), random_field(), random_field(), random_field(), random_field()};
        6 -> random_term(?DEPTH)
    end.

%% A field near some bound of the table, or anything at all.
random_field() ->
    case rand:uniform(8) of
        1 -> boundary_integer();
        2 -> random_name();
        3 -> random_bytes(pick([0, 1, 255, 256, 4095, 4096, 65536, 65537]));
        4 -> [random_name() || _ <- lists:seq(1, pick([0, 1, 16, 17]))];
        5 -> {rand:uniform(256) - 1, boundary_integer(), boundary_integer()};
        6 -> [{{0, 0, 1}, 0, 4, random_name()} || _ <- lists:seq(1, rand:uniform(4))];
        7 -> make_ref();
        8 -> random_term(1)
    end.

boundary_integer() ->
    Base = pick([0, 1, 3, 16#200, 255, 4095, 65536, 16#ffffffff, 16#ffffffffffffffff]),
    Base + pick([-1, 0, 1]).

random_name() ->
    case rand:uniform(4) of
        1 -> pick([<<>>, <<".">>, <<"..">>, <<"...">>, <<"a/b">>, <<"a", 0>>,
                   <<16#ed, 16#a0, 16#80>>, <<16#c0, 16#80>>, <<"caf", 16#c3, 16#a9>>]);
        2 -> binary:copy(<<"n">>, 250 + rand:uniform(10));
        3 -> random_bytes(rand:uniform(8));
        4 -> unicode:characters_to_binary([rand:uniform(16#7ff) || _ <- lists:seq(1, rand:uniform(6))])
    end.

random_term(0) ->
    pick([make_ref(), self(), 1.5, -1, ok, error, <<>>, []]);
random_term(Depth) ->
    case rand:uniform(7) of
        1 -> boundary_integer();
        2 -> pick(?G:operations() ++ [erx_9p, unknown, ok, error, enoent]);
        3 -> random_name();
        4 -> list_to_tuple([random_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(9) - 1)]);
        5 -> [random_term(Depth - 1) || _ <- lists:seq(1, rand:uniform(5) - 1)];
        6 -> list_to_tuple([pick(?G:operations()) | [random_field() || _ <- lists:seq(1, rand:uniform(8) - 1)]]);
        7 -> maps:from_list([{pick([valid, mode, size, qid, x]), random_term(Depth - 1)}])
    end.

random_bytes(Size) ->
    << <<(rand:uniform(256) - 1)>> || _ <- lists:seq(1, Size) >>.

pick(List) ->
    lists:nth(rand:uniform(length(List)), List).
