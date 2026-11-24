%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of erx_tty_link, the tty's side of the messages between a
%% session's tty and its master (docs/design-live.md, "Between domains"): random
%% runs of writes, timer ends, master messages, the master's well-formed ones
%% at and past their bounds among arbitrary terms, and the line discipline's
%% flush, stop and start are fed to one tty, each step ending in send/1 as
%% its owner ends one. After every step the tty holds at most 4 KiB, room/1
%% is what is free, the outstanding output and output stopped, and no new
%% output is sent while output is stopped; a flush drops what was not sent;
%% each output is a binary of at most 4 KiB, numbered one past the last, or the outstanding one again empty; each
%% input is a binary of 1 to 4,096 bytes and each size within 1 to 65,535; after
%% a hangup nothing is sent; and the bytes sent are, in order, a prefix of the
%% bytes written and not dropped. At the end of a run, with every output taken,
%% every write has been answered once.
%%
%% The SSH line's requests (erx_tty_line_core:request/4, docs/design-ssh.md,
%% "Sessions, ttys and shells") are fed the same way: open_tty in its shape at
%% and past every bound among arbitrary terms, from the peer's channel, a third
%% domain's and a pid of no domain, to a line holding 0 to 11 channels. Every
%% answer is an open, `limited` or `badarg`, and never a crash; an open names a
%% channel of the peer's, a line holding fewer than ten, `shell` or a command of
%% 1 to 32 KiB holding no NUL, and the size asked for, a side of zero taken as
%% 24 rows or 80 columns. A failure raises {fuzz_failure, What, Detail}, What
%% naming the property.
-module(erx_tty_link_fuzz).
-export([run/1]).

-define(ROUNDS, 1500).
-define(MAX_HELD, 4096).
-define(MAX_INPUT, 4096).
-define(MAX_SIDE, 65535).
-define(REQUEST_ROUNDS, 4000).
-define(MAX_CHANNELS, 10).
-define(MAX_COMMAND, 32768).
-define(PEER, 7).

%% What the run has seen: the tty, the bytes written and not dropped, the bytes
%% sent, the last output number, the writes not yet answered by writer, whether
%% the line has hung up, whether output is stopped, and the output the tty has
%% outstanding, {N, Size} or none.
-record(run, {link, written = <<>>, sent = <<>>, last = -1, unanswered = #{},
              hung_up = false, stopped = false, outstanding = none, steps = []}).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    lists:foreach(fun(_) -> round_of() end, lists:seq(1, ?ROUNDS)),
    lists:foreach(fun(_) -> request_round() end, lists:seq(1, ?REQUEST_ROUNDS)),
    io:format("fuzz: ~p rounds ok~n", [?ROUNDS]).

round_of() ->
    Run = lists:foldl(fun(_, R) -> step(event(R), R) end, #run{link = erx_tty_link:new(present)},
                      lists:seq(1, rand:uniform(60))),
    drained(drain(Run, 1000)).

%% Starts output, then takes every outstanding output until none is left, so
%% every write still waiting gets its room.
drain(Run = #run{stopped = true}, Left) ->
    drain(step(start, Run), Left);
drain(Run, 0) ->
    Run;
drain(Run = #run{last = Last}, Left) ->
    case step({master, {tty_taken, Last}}, Run) of
        Run1 = #run{last = Last} -> Run1;
        Run1 -> drain(Run1, Left - 1)
    end.

drained(Run = #run{unanswered = Unanswered, link = Link, hung_up = HungUp}) ->
    erx_tty_link:held(Link) =:= 0 orelse fail(held_after_drain, history(Run)),
    HungUp orelse Run#run.sent =:= Run#run.written orelse fail(bytes_left, history(Run)),
    case maps:filter(fun(_Writer, Count) -> Count =/= 0 end, Unanswered) of
        Waiting when map_size(Waiting) =:= 0 -> ok;
        Waiting -> fail(write_unanswered, {Waiting, history(Run)})
    end.

%%% One step: the event, its actions, and the checks on them

step(Event, Run0 = #run{link = Link0, steps = Steps}) ->
    Run = Run0#run{steps = [Event | Steps]},
    {Actions, Link} = try ended(apply_event(Event, Link0))
                      catch Class:Reason -> fail(crashed, {Class, Reason, history(Run)})
                      end,
    Dropped = dropped(Link0, Link),
    Written = case Event of
                  {write, Writer, Bytes} when not Run#run.hung_up, not Dropped ->
                      written(Writer, Bytes, Run);
                  {write, Writer, _Bytes} ->
                      answered_at_once(Writer, Run);
                  flush ->
                      Run#run{written = Run#run.sent};
                  {master, {tty_taken, N}} when not Run#run.hung_up ->
                      Run#run{outstanding = taken(N, Run#run.outstanding)};
                  stop ->
                      Run#run{stopped = true};
                  start ->
                      Run#run{stopped = false};
                  _ ->
                      Run
              end,
    held_within(Written#run{link = Link}),
    Acted = lists:foldl(fun(Action, R) -> action(Action, R) end, Written#run{link = Link},
                        Actions),
    room_right(Acted),
    Acted.

apply_event({write, Writer, Bytes}, Link) -> erx_tty_link:write(Writer, Bytes, Link);
apply_event({master, Message}, Link) -> erx_tty_link:master(Message, Link);
apply_event({timeout, N}, Link) -> erx_tty_link:timeout(N, Link);
apply_event(flush, Link) -> erx_tty_link:flush(Link);
apply_event(stop, Link) -> {[], erx_tty_link:stop(Link)};
apply_event(start, Link) -> {[], erx_tty_link:start(Link)}.

taken(N, {N, _Size}) -> none;
taken(_N, Outstanding) -> Outstanding.

%% The end of the step, as the owner ends it.
ended({Actions, Link}) ->
    {Sent, Link1} = erx_tty_link:send(Link),
    {Actions ++ Sent, Link1}.

%% A write nobody waits on that the tty dropped, past its bound.
dropped(Before, After) ->
    maps:get(output_dropped, erx_tty_link:counts(After)) > maps:get(output_dropped, erx_tty_link:counts(Before)).

written(Writer, Bytes, Run = #run{written = Written}) ->
    expect_answer(Writer, Run#run{written = <<Written/binary, Bytes/binary>>}).

%% A write after the hangup, or a dropped one, is answered but sends nothing.
answered_at_once(Writer, Run) ->
    expect_answer(Writer, Run).

expect_answer(none, Run) ->
    Run;
expect_answer(Writer, Run = #run{unanswered = Unanswered}) ->
    Run#run{unanswered = maps:update_with(Writer, fun(Count) -> Count + 1 end, 1, Unanswered)}.

action({output, _N, _Bytes}, Run = #run{hung_up = true}) ->
    fail(output_after_hangup, history(Run));
action({output, N, <<>>}, Run = #run{last = N}) ->
    Run;
action({output, _N, _Bytes}, Run = #run{stopped = true}) ->
    fail(output_while_stopped, history(Run));
action({output, N, Bytes}, Run = #run{last = Last, sent = Sent, written = Written})
  when is_binary(Bytes), byte_size(Bytes) =< ?MAX_HELD ->
    N =:= Last + 1 orelse fail(numbering, {N, Last, history(Run)}),
    All = <<Sent/binary, Bytes/binary>>,
    binary:longest_common_prefix([All, Written]) =:= byte_size(All)
        orelse fail(sent_not_written, {All, Written, history(Run)}),
    Run#run{last = N, sent = All, outstanding = {N, byte_size(Bytes)}};
action({output, N, Bytes}, Run) ->
    fail(output_over_bound, {N, Bytes, history(Run)});
action({input, Bytes}, Run) when is_binary(Bytes), byte_size(Bytes) >= 1, byte_size(Bytes) =< ?MAX_INPUT ->
    Run;
action({input, Bytes}, Run) ->
    fail(input_over_bound, {Bytes, history(Run)});
action({size, Rows, Columns}, Run) when is_integer(Rows), Rows >= 1, Rows =< ?MAX_SIDE,
                                        is_integer(Columns), Columns >= 1, Columns =< ?MAX_SIDE ->
    Run;
action({size, Rows, Columns}, Run) ->
    fail(size_out_of_range, {Rows, Columns, history(Run)});
action({done, Writer}, Run = #run{unanswered = Unanswered}) ->
    case maps:get(Writer, Unanswered, 0) of
        0 -> fail(answered_twice, {Writer, history(Run)});
        Count -> Run#run{unanswered = Unanswered#{Writer := Count - 1}}
    end;
action(hangup, Run = #run{hung_up = true}) ->
    fail(hangup_twice, history(Run));
action(hangup, Run) ->
    Run#run{hung_up = true, outstanding = none};
action(open, Run) ->
    Run;
action({resend_after, _N}, Run) ->
    Run;
action(Other, Run) ->
    fail(unknown_action, {Other, history(Run)}).

held_within(Run = #run{link = Link}) ->
    erx_tty_link:held(Link) =< ?MAX_HELD orelse fail(held_over_bound, history(Run)).

%% room/1 as it follows from what is held: what is free, the outstanding
%% output, which is the last sent or none, and output stopped.
room_right(Run = #run{link = Link, stopped = Stopped}) ->
    Held = erx_tty_link:held(Link),
    {Free, Kept, Stopped1} = erx_tty_link:room(Link),
    Free =:= ?MAX_HELD - Held andalso Kept =:= outstanding_size(Run#run.outstanding)
        andalso Stopped1 =:= Stopped andalso erx_tty_link:stopped(Link) =:= Stopped
        orelse fail(room_wrong, {{Free, Kept, Stopped1}, Held, history(Run)}).

outstanding_size(none) -> 0;
outstanding_size({_N, Size}) -> Size.

history(#run{steps = Steps}) -> lists:reverse(Steps).

fail(What, Detail) -> error({fuzz_failure, What, Detail}).

%%% The events

event(#run{last = Last}) ->
    case rand:uniform(12) of
        N when N =< 4 -> {write, writer(), bytes(rand:uniform(3))};
        5 -> {timeout, pick([Last, Last + 1, max(0, Last - 1)])};
        6 -> {master, {tty_taken, pick([Last, Last, Last + 1, max(0, Last - 1)])}};
        7 -> pick([flush, stop, start]);
        _ -> {master, message()}
    end.

writer() -> pick([none, none, {w, 1}, {w, 2}, {w, 3}]).

%% Sizes around the tty's bounds: small, near 4 KiB, and past it.
bytes(1) -> rand:bytes(rand:uniform(64) - 1);
bytes(2) -> rand:bytes(?MAX_HELD - 8 + rand:uniform(16));
bytes(3) -> rand:bytes(rand:uniform(3 * ?MAX_HELD)).

%% The master's messages: well-formed ones at and past their bounds, and
%% arbitrary terms that only look like them.
message() ->
    case rand:uniform(9) of
        1 -> {tty_input, rand:bytes(pick([0, 1, ?MAX_INPUT - 1, ?MAX_INPUT, ?MAX_INPUT + 1,
                                          rand:uniform(2 * ?MAX_INPUT)]))};
        2 -> {tty_input, pick([[], "text", 42, <<1:3>>, {<<"a">>}])};
        3 -> {tty_size, side(), side()};
        4 -> {tty_size, pick([1.0, "24", undefined, -1]), side()};
        5 -> tty_hangup;
        6 -> {tty_taken, pick([-1, 1.5, undefined, 1 bsl 70])};
        7 -> pick([{tty_input}, {tty_input, <<"a">>, <<"b">>}, {tty_size, 24}, tty_open, {tty_open, self()}]);
        8 -> {tty_output, rand:uniform(5), rand:bytes(8)};
        9 -> pick([ok, <<"tty_hangup">>, {tty_hangup}, [tty_hangup], make_ref()])
    end.

side() -> pick([0, 1, 2, 24, 80, ?MAX_SIDE - 1, ?MAX_SIDE, ?MAX_SIDE + 1, -1, 1 bsl 64]).

pick(Choices) -> lists:nth(rand:uniform(length(Choices)), Choices).

%%% The SSH line's requests

%% One request from ?PEER to a line that holds Held channels, and its answer checked
%% against the request.
request_round() ->
    Held = rand:uniform(?MAX_CHANNELS + 2) - 1,
    Core = lists:foldl(fun(N, C) -> erx_tty_line_core:opened(pid(1000 + N), self(), C) end,
                       erx_tty_line_core:new(), lists:seq(1, Held)),
    Request = request(),
    Answer = try erx_tty_line_core:request(Request, ?PEER, fun owner/1, Core)
             catch Class:Reason -> fail(request_crashed, {Request, Class, Reason})
             end,
    answered(Request, Held, Answer).

answered({open_tty, Channel, Run, _Term, Rows, Columns} = Request, Held, {open_tty, Channel, #{run := Run, size := Size}}) ->
    [fail(over_limit, {Held, Request}) || Held >= ?MAX_CHANNELS],
    [fail(foreign_channel, Request) || owner(Channel) =/= ?PEER],
    [fail(bad_run, Request) || not valid_run(Run)],
    {R, C} = Size,
    [fail(size_out_of_range, {Request, Size}) || not (side_ok(R) andalso side_ok(C))],
    [fail(size_not_kept, {Request, Size}) || Size =/= {asked(Rows, 24), asked(Columns, 80)}];
answered(Request, _Held, {open_tty, _, _} = Answer) ->
    fail(open_not_asked, {Request, Answer});
answered(_Request, _Held, {error, limited}) -> ok;
answered(_Request, _Held, {error, badarg}) -> ok;
answered(Request, _Held, Answer) ->
    fail(unexpected_answer, {Request, Answer}).

valid_run(shell) -> true;
valid_run({exec, Command}) when is_binary(Command) ->
    byte_size(Command) >= 1 andalso byte_size(Command) =< ?MAX_COMMAND andalso binary:match(Command, <<0>>) =:= nomatch;
valid_run(_Run) -> false.

side_ok(Side) -> is_integer(Side) andalso Side >= 1 andalso Side =< ?MAX_SIDE.

asked(0, Default) -> Default;
asked(Side, _Default) -> Side.

%% The peer's channel is this process; pid 2 is of a third domain, any other of none.
owner(Pid) when Pid =:= self() -> ?PEER;
owner(Pid) when is_pid(Pid) -> case Pid =:= pid(2) of true -> 9; false -> 0 end.

pid(N) -> list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

request() ->
    case rand:uniform(6) of
        N when N =< 3 -> {open_tty, channel(), run(), term(), side_asked(), side_asked()};
        4 -> {open_tty, channel(), run(), pick([<<"xterm">>, <<>>, rand:bytes(64), rand:bytes(65), "vt100", 42]),
              side_asked(), side_asked()};
        5 -> pick([{open_tty}, {open_tty, self(), shell}, {open_job, self(), shell},
                   {open_tty, self(), shell, <<"vt100">>, 24, 80, extra}, ok, make_ref(), [open_tty]]);
        6 -> {open_tty, self(), {exec, command()}, <<"vt100">>, side_asked(), side_asked()}
    end.

channel() -> pick([self(), self(), pid(2), pid(3), not_a_pid, 1]).

run() -> pick([shell, shell, {exec, command()}, {exec, <<>>}, {exec, <<"a", 0, "b">>}, {exec, "ls"}, exec,
               {exec, <<"a">>, x}, {shell}]).

command() ->
    Bytes = rand:bytes(pick([1, 2, 64, ?MAX_COMMAND - 1, ?MAX_COMMAND, ?MAX_COMMAND + 1])),
    pick([Bytes, binary:replace(Bytes, <<0>>, <<"x">>, [global])]).

term() -> pick([<<"vt100">>, <<"xterm-256color">>]).

side_asked() -> pick([0, 0, 1, 24, 80, ?MAX_SIDE, ?MAX_SIDE + 1, -1, 1.0, undefined]).
