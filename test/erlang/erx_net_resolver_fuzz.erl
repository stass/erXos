%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_resolver_fuzz).
-moduledoc """
The fuzz target of name resolution's untrusted inputs
(docs/design-network-stack.md, "Name resolution"), driven by
tools/fuzz/erx_net_resolver.rb. Three targets:

* `config`: erx_inet:resolver_config/1 on terms near the grant's answer,
  which comes from another domain; what it takes must be this module's
  own reading of the answer (at most three `{IPv4, 53}`, at most six
  search entries, each kept only when, without one trailing dot, it is 1
  to 253 bytes in labels of 1 to 63 letters, digits and hyphens that
  begin and end with a letter or digit). A fault prints
  `config_accepted_bad`.
* `dns`: inet_dns:decode/1 on valid replies cut, flipped and spliced, as
  any host on the path can send them; it must answer `{ok, _}` or
  `{error, _}` and never raise. A fault prints `decode_raised`.
* `host`: erx_cmd_host:answer_lines/1 on the answer records of those
  replies and on records with names of random bytes; no line may hold a
  control character but its final newline, or invalid UTF-8. A fault
  prints `host_unescaped`.

Prints `fuzz: N inputs ok` when every input passed.
""".

-export([run/1]).

-define(INPUTS, 4000).

run([Target, Seed]) ->
    _ = rand:seed(exsss, {list_to_integer(Seed), 7, 13}),
    Check = check(list_to_atom(Target)),
    Failures = lists:filtermap(fun(_) -> Check() end, lists:seq(1, ?INPUTS)),
    case Failures of
        [] -> io:format("fuzz: ~b inputs ok~n", [?INPUTS]);
        [First | _] -> io:format("fuzz: ~b failed, first ~p~n", [length(Failures), First])
    end.

check(config) -> fun() -> config(answer()) end;
check(dns) -> fun() -> decode(reply()) end;
check(host) -> fun() -> host(records()) end.

%% --- config ----------------------------------------------------------------------

config(Answer) ->
    case erx_inet:resolver_config(Answer) of
        {error, badarg} -> false;
        {ok, Config} -> case expected(Answer) of
                            {ok, Config} -> false;
                            _ -> {true, {config_accepted_bad, Answer, Config}}
                        end
    end.

%% This module's own reading of an answer: its shape whole, then each search domain alone,
%% a bad one dropped and one trailing dot taken off a good one.
expected(#{nameservers := Ns, search := Search} = Answer) when map_size(Answer) =:= 2 ->
    case is_list(Ns) andalso length(Ns) =< 3 andalso lists:all(fun valid_server/1, Ns) andalso
             is_list(Search) andalso length(Search) =< 6 of
        true -> {ok, #{nameservers => Ns,
                       search => [binary_to_list(Bare) || Name <- Search, is_binary(Name),
                                                          Bare <- [bare(Name)], valid_name(Bare)]}};
        false -> error
    end;
expected(_) ->
    error.

bare(Name) ->
    case binary:last(<<0, Name/binary>>) of
        $. -> binary:part(Name, 0, byte_size(Name) - 1);
        _ -> Name
    end.

valid_server({{A, B, C, D}, 53}) -> lists:all(fun(X) -> is_integer(X) andalso X >= 0 andalso X =< 255 end, [A, B, C, D]);
valid_server(_) -> false.

valid_name(Name) when byte_size(Name) >= 1, byte_size(Name) =< 253 ->
    Edge = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    lists:all(fun(L) -> length(L) >= 1 andalso length(L) =< 63 andalso
                            lists:member(hd(L), Edge) andalso lists:member(lists:last(L), Edge) andalso
                            lists:all(fun(C) -> lists:member(C, [$- | Edge]) end, L)
              end, string:split(binary_to_list(Name), ".", all));
valid_name(_) ->
    false.

answer() ->
    Base = #{nameservers => [server() || _ <- lists:seq(1, rand:uniform(5) - 1)],
             search => [domain() || _ <- lists:seq(1, rand:uniform(8) - 1)]},
    case rand:uniform(10) of
        1 -> Base#{extra => 1};
        2 -> maps:remove(search, Base);
        3 -> Base#{search := [pick([<<"a">>, "a", a, 1, <<>>]) | maps:get(search, Base)]};
        _ -> Base
    end.

server() ->
    pick([{{rand:uniform(256) - 1, 0, 2, 3}, 53}, {{10, 0, 2, 3}, 53}, {{10, 0, 2, 3}, pick([53, 54, 0])},
          {{256, 0, 0, 1}, 53}, {{-1, 0, 0, 1}, 53}, {{1, 2, 3}, 53}, {{0, 0, 0, 0, 0, 0, 0, 1}, 53}, x]).

domain() ->
    Labels = [label() || _ <- lists:seq(1, rand:uniform(3))],
    Name = iolist_to_binary(lists:join(<<".">>, Labels)),
    case rand:uniform(8) of
        1 -> <<Name/binary, ".">>;
        2 -> binary:copy(<<"a.">>, 120 + rand:uniform(20));
        _ -> Name
    end.

%% A label of the bytes a name admits, hyphens only inside, at most and just over the
%% bound, now and then with one byte it does not admit first, a hyphen or an underscore
%% included, or with none at all.
label() ->
    Length = pick([rand:uniform(8), rand:uniform(8), 63, 64, 0]),
    Label = << <<(pick(if I =:= 1; I =:= Length -> "abz09AZ"; true -> "abz09AZ-" end))>>
               || I <- lists:seq(1, Length) >>,
    case rand:uniform(10) of
        1 when Length > 0 -> <<(pick([0, 27, $\s, $/, 128, 255, $-, $_])), (binary:part(Label, 1, Length - 1))/binary>>;
        _ -> Label
    end.

%% --- dns -------------------------------------------------------------------------

decode(Packet) ->
    try inet_dns:decode(Packet) of
        {ok, _} -> false;
        {error, _} -> false;
        Other -> {true, {decode_answered, Other, Packet}}
    catch
        Class:Reason -> {true, {decode_raised, Class, Reason, Packet}}
    end.

reply() ->
    mutate(valid_reply(), rand:uniform(4)).

valid_reply() ->
    Names = [binary_to_list(domain_bytes()) || _ <- lists:seq(1, 3)],
    Records = [inet_dns:make_rr([{domain, pick(Names)}, {type, Type}, {class, in}, {ttl, 60},
                                 {data, data(Type, Names)}])
               || Type <- [pick([a, aaaa, cname, ptr, mx, txt]) || _ <- lists:seq(1, rand:uniform(4))]],
    Header = inet_dns:make_header([{id, rand:uniform(65535)}, {qr, true}, {rcode, pick([0, 0, 3, 2])}]),
    Query = inet_dns:make_dns_query([{domain, hd(Names)}, {type, a}, {class, in}]),
    inet_dns:encode(inet_dns:make_msg([{header, Header}, {qdlist, [Query]}, {anlist, Records}])).

data(a, _Names) -> {192, 0, 2, rand:uniform(255)};
data(aaaa, _Names) -> {16#2001, 16#db8, 0, 0, 0, 0, 0, rand:uniform(255)};
data(mx, Names) -> {10, pick(Names)};
data(txt, _Names) -> ["text"];
data(_Alias, Names) -> pick(Names).

domain_bytes() ->
    iolist_to_binary(lists:join(<<".">>, [pick([<<"www">>, <<"erxos">>, <<"test">>, <<"x\e[2J">>,
                                                <<16#c2, 16#9b>>, <<16#ff>>, <<"a\nb">>])
                                          || _ <- lists:seq(1, rand:uniform(3))])).

mutate(Packet, 0) ->
    Packet;
mutate(Packet, N) ->
    Size = byte_size(Packet),
    At = rand:uniform(max(Size, 1)) - 1,
    Next = case rand:uniform(4) of
               1 -> binary:part(Packet, 0, At);
               2 when Size > 0 ->
                   <<Head:At/binary, _, Tail/binary>> = Packet,
                   <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
               3 ->
                   <<Head:At/binary, Tail/binary>> = Packet,
                   <<Head/binary, 16#c0, (rand:uniform(256) - 1), Tail/binary>>;
               _ ->
                   <<Head:At/binary, Tail/binary>> = Packet,
                   <<Head/binary, (crypto:strong_rand_bytes(rand:uniform(8)))/binary, Tail/binary>>
           end,
    mutate(Next, N - 1).

%% --- host ------------------------------------------------------------------------

host(Records) ->
    case [Line || Line <- erx_cmd_host:answer_lines(Records), not escaped(Line)] of
        [] -> false;
        [Bad | _] -> {true, {host_unescaped, Bad}}
    end.

records() ->
    case rand:uniform(2) of
        1 ->
            case inet_dns:decode(reply()) of
                {ok, Msg} -> [{inet_dns:rr(RR, type), inet_dns:rr(RR, domain), inet_dns:rr(RR, data)}
                              || RR <- inet_dns:msg(Msg, anlist)];
                {error, _} -> []
            end;
        2 ->
            Name = fun() -> binary_to_list(crypto:strong_rand_bytes(rand:uniform(12))) end,
            [{pick([cname, ptr]), Name(), Name()}, {a, Name(), {192, 0, 2, 1}}]
    end.

%% A line is escaped when it is valid UTF-8 and its one control character is its final newline.
escaped(Line) ->
    Body = binary:part(Line, 0, byte_size(Line) - 1),
    binary:last(Line) =:= $\n andalso
        case unicode:characters_to_list(Body) of
            Chars when is_list(Chars) -> not lists:any(fun(C) -> C < 16#20 orelse (C >= 16#7f andalso C =< 16#9f) end, Chars);
            _ -> false
        end.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
