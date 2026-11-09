%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause
%% The fuzz target of erx_web_proto:decode/2, the decoder of every message a
%% browser sends the web domain (docs/design-web.md, "Verification and
%% testing"). Each round takes a random message of either union from
%% erx_web_proto_tests:random_message/1, or random bytes, and decodes it whole
%% or broken (bytes flipped, inserted, cut, or a length word set near a
%% bound), as either union. The decoder must return ok or a refusal and never
%% raise, and every message it accepts must encode back to the bytes it came
%% from: the encoder refuses whatever passes a bound, so that shows each
%% accepted message within its bounds.
-module(erx_web_proto_fuzz).
-export([run/1]).

-define(ROUNDS, 50000).

run([Seed]) ->
    rand:seed(exsss, {list_to_integer(Seed), 17, 19}),
    try
        lists:foreach(fun(_) -> round() end, lists:seq(1, ?ROUNDS)),
        io:format("fuzz: ~b rounds ok~n", [?ROUNDS])
    catch
        Class:Reason:Stack ->
            io:format("fuzz failed: ~p:~P~n~P~n", [Class, Reason, 40, Stack, 20]),
            halt(1)
    end.

round() ->
    Messages = erx_web_proto:messages(),
    {Message, Bytes} = erx_web_proto_tests:random_message(Messages),
    Input = case rand:uniform(4) of
                1 -> rand:bytes(rand:uniform(64) - 1);
                2 -> Bytes;
                _ -> mutate(Bytes, rand:uniform(4))
            end,
    As = case rand:uniform(4) of
             1 -> lists:nth(rand:uniform(length(Messages)), Messages);
             _ -> Message
         end,
    check(As, Input).

check(Message, Input) ->
    case erx_web_proto:decode(Message, Input) of
        {ok, Term} ->
            case erx_web_proto:encode(Message, Term) of
                {ok, Input} -> ok;
                Other -> error({accepted_but_encoded, Message, Input, Other})
            end;
        {error, {Reason, Type}} when is_atom(Reason), is_atom(Type) ->
            ok
    end.

mutate(Bytes, 0) ->
    Bytes;
mutate(Bytes, Count) ->
    At = rand:uniform(byte_size(Bytes) + 1) - 1,
    <<Head:At/binary, Tail/binary>> = Bytes,
    Next = case {rand:uniform(4), Tail} of
               {1, <<_, Rest/binary>>} -> <<Head/binary, (rand:uniform(256) - 1), Rest/binary>>;
               {2, _} -> <<Head/binary, (rand:uniform(256) - 1), Tail/binary>>;
               {3, _} -> <<Head/binary, (drop(Tail, rand:uniform(8)))/binary>>;
               {_, _} -> <<Head/binary, (rand:uniform(1100)):32/little, (drop(Tail, 4))/binary>>
           end,
    mutate(Next, Count - 1).

drop(Bytes, Count) when byte_size(Bytes) =< Count -> <<>>;
drop(Bytes, Count) -> binary:part(Bytes, Count, byte_size(Bytes) - Count).
