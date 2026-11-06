%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A queued message whose term is a literal and whose seq_trace token lives
%% on the receiver's heap, carried through the collection of the literal's
%% area and a garbage collection. The collection copies the literal into a
%% fragment of the message's own; the token must come along, or the next
%% garbage collection leaves it pointing into a freed heap.
%%
%% main/0 prints one line and halts with 0 when every round's receiver got
%% its token back intact, with 1 when one did not, and with 2 when a round
%% could not be run. A token read from freed memory may also end the
%% runtime with a signal or an abort.
-module(literal_token_probe).
-export([main/0]).

-define(ROUNDS, 20).
%% A round in which the collector had not yet taken the area when the
%% receiver looked tested nothing, and is run again, up to this many times.
-define(ATTEMPTS, 5).
-define(LABEL, 4711).

main() ->
    try [checked_round(?ATTEMPTS) || _ <- lists:seq(1, ?ROUNDS)] of
        Results ->
            case [Bad || {bad_token, _} = Bad <- Results] of
                [] ->
                    io:format("literal token probe: ~b rounds, token intact~n", [?ROUNDS]),
                    erlang:halt(0);
                Bad ->
                    io:format("literal token probe: ~P~n", [Bad, 20]),
                    erlang:halt(1)
            end
    catch
        Class:Reason ->
            io:format("literal token probe: no result: ~p:~P~n", [Class, Reason, 20]),
            erlang:halt(2)
    end.

checked_round(0) ->
    error(area_never_collected_in_time);
checked_round(Attempts) ->
    case round() of
        {literal_still_shared, _Token, _Message} -> checked_round(Attempts - 1);
        {copied, {label, {?LABEL, Message}}, Message} -> intact;
        {copied, Token, _Message} -> {bad_token, Token}
    end.

%% One receiver: it queues the literal to itself under a token whose label
%% holds the literal too, the literal's area is collected while the message
%% waits, and the receiver then collects its heap and receives the message.
round() ->
    Key = {?MODULE, make_ref()},
    persistent_term:put(Key, {literal, make_ref()}),
    Parent = self(),
    {Receiver, Monitor} = spawn_opt(fun () -> receiver(Key, Parent) end,
                                    [monitor, {message_queue_data, on_heap}]),
    receive
        {Receiver, queued} -> ok;
        {'DOWN', Monitor, process, Receiver, Early} -> error({receiver_down, Early})
    end,
    persistent_term:erase(Key),
    wait_until_idle(literal_area_collector()),
    Receiver ! go,
    receive
        {Receiver, Result} -> erlang:demonitor(Monitor, [flush]), Result;
        {'DOWN', Monitor, process, Receiver, Late} -> error({receiver_down, Late})
    end.

receiver(Key, Parent) ->
    send_literal_to_self(Key),
    Parent ! {self(), queued},
    receive go -> ok end,
    erlang:garbage_collect(),
    receive {literal, _} = Message -> ok end,
    Token = seq_trace:get_token(label),
    seq_trace:set_token([]),
    %% A term the collection copied is no longer a literal, so it has a size.
    Collected = case erts_debug:size_shared(Message) of
                    0 -> literal_still_shared;
                    _ -> copied
                end,
    Parent ! {self(), {Collected, Token, Message}}.

%% A process sending to itself holds its own main lock, so the message and
%% its copy of the token go on its own heap, and the term stays a reference
%% into the literal area. Kept out of receiver/2 so that no variable of the
%% receiver holds the literal: the message is then its only reference.
send_literal_to_self(Key) ->
    Literal = persistent_term:get(Key),
    seq_trace:set_token(label, {?LABEL, Literal}),
    self() ! Literal,
    seq_trace:set_token([]),
    ok.

literal_area_collector() ->
    [Pid] = [P || P <- processes(),
                  process_info(P, initial_call)
                      =:= {initial_call, {erts_literal_area_collector, start, 0}}],
    Pid.

%% The collector is idle once every process has answered for the area.
wait_until_idle(Collector) ->
    Ref = make_ref(),
    Alias = alias(),
    Collector ! {get_status, Ref, Alias},
    receive
        {Ref, idle} ->
            unalias(Alias);
        {Ref, _Busy} ->
            unalias(Alias),
            receive after 10 -> ok end,
            wait_until_idle(Collector)
    end.
