%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases of erx_web_conn (docs/design-web.md, "The connection core"):
%% the W8 bounds at their limit, `bye protocol` before `hello`, pull
%% sampling, and every input sequence of a small alphabet to a fixed depth,
%% checked against a model of what the browser asked for.
-module(erx_web_conn_tests).
-include_lib("eunit/include/eunit.hrl").

-define(LAST_VIEW, 16#FFFFFFFF).
-define(DEPTH, 64).

conn() ->
    {ok, State} = erx_web_conn:new(#{principal => <<"alice">>, build => <<"build-1">>}),
    State.

in(Message) ->
    {ok, Bytes} = erx_web_proto:encode(browser, Message),
    {in, Bytes}.

hello() -> in({hello, erx_web_proto:hash()}).

%% Feeds INPUTS in turn and returns the actions of the last and the state.
run(Inputs, State) ->
    lists:foldl(fun(Input, {_Actions, Now}) -> erx_web_conn:step(Input, Now) end, {[], State}, Inputs).

greeted() -> element(2, run([hello()], conn())).

pid(N) -> list_to_pid("<0." ++ integer_to_list(N) ++ ".0>").

%% The actions with each sent message decoded.
readable(Actions) ->
    [case Action of
         {send, Bytes} -> {ok, Message} = erx_web_proto:decode(machine, Bytes), {send, Message};
         _ -> Action
     end || Action <- Actions].

bye(Reason) -> [{send, {bye, Reason}}, {close, Reason}].

record(Text) ->
    {record, #{path => [], kind => <<"k">>, id => {int, <<"1">>},
               attrs => [{<<"v">>, kernel, ok, {text, Text}}], children => {complete, []}}}.

%% W8 and the protocol's own bounds.

anything_before_hello_closes_with_bye_protocol_test() ->
    Early = [in({open, 1, uis}), in({next, 1}), in({close, 1}), {in, <<255>>}, {text, <<"hello">>}],
    [?assertEqual(bye(protocol), readable(element(1, erx_web_conn:step(Input, conn())))) || Input <- Early],
    ?assertEqual(bye(mismatch), readable(element(1, erx_web_conn:step(in({hello, <<0:256>>}), conn())))),
    ?assertEqual([{send, {welcome, <<"alice">>, <<"build-1">>}}],
                 readable(element(1, erx_web_conn:step(hello(), conn())))).

the_seventeenth_view_is_busy_and_uses_its_number_test() ->
    {_, Sixteen} = run([in({open, View, uis}) || View <- lists:seq(1, 16)], greeted()),
    {Busy, Full} = erx_web_conn:step(in({open, 17, uis}), Sixteen),
    ?assertEqual([{send, {ended, 17, <<"busy">>}}], readable(Busy)),
    ?assertEqual({[], Full}, erx_web_conn:step(in({next, 17}), Full)),
    ?assertEqual(bye(protocol), readable(element(1, erx_web_conn:step(in({open, 17, uis}), Full)))).

a_reused_or_lower_view_number_closes_with_bye_protocol_test() ->
    {_, Closed} = run([in({open, 5, uis}), in({close, 5})], greeted()),
    ?assertEqual(bye(protocol), readable(element(1, erx_web_conn:step(in({open, 5, uis}), Closed)))),
    ?assertEqual(bye(protocol), readable(element(1, erx_web_conn:step(in({open, 3, uis}), Closed)))).

a_second_next_before_its_answer_closes_with_bye_protocol_test() ->
    {_, Asked} = run([in({open, 1, uis}), {opened, 1, pid(101)}, {update, 1, {uis, []}}, in({next, 1})], greeted()),
    ?assertEqual([{stop, pid(101)} | bye(protocol)], readable(element(1, erx_web_conn:step(in({next, 1}), Asked)))),
    %% The open asks for the first update, so a next before it is a second request too.
    {_, Opening} = run([in({open, 1, uis})], greeted()),
    ?assertEqual(bye(protocol), readable(element(1, erx_web_conn:step(in({next, 1}), Opening)))).

the_last_view_number_closes_with_bye_limit_before_the_wrap_test() ->
    {Opened, Below} = run([in({open, ?LAST_VIEW - 1, uis})], greeted()),
    ?assertEqual([{open, ?LAST_VIEW - 1, uis}], Opened),
    ?assertEqual(bye(limit), readable(element(1, erx_web_conn:step(in({open, ?LAST_VIEW, uis}), Below)))).

%% Too large as a whole, one text over its own bound, and a list over its
%% count all end the view too_large.
a_record_over_one_message_ends_its_view_too_large_test() ->
    {_, Open} = run([in({open, 1, {path, [<<"a">>]}}), {opened, 1, pid(101)}], greeted()),
    Many = {entries, lists:duplicate(1001, {gap, 1})},
    [?assertEqual([{stop, pid(101)}, {send, {ended, 1, <<"too_large">>}}],
                  readable(element(1, erx_web_conn:step({update, 1, Body}, Open))))
     || Body <- [record(binary:copy(<<"x">>, 65536)), record(binary:copy(<<"x">>, 70000)), Many]].

a_reason_that_is_no_name_is_sent_as_closed_test() ->
    {_, Open} = run([in({open, 1, uis}), {opened, 1, pid(101)}], greeted()),
    {Actions, _} = erx_web_conn:step({ended, 1, {shutdown, x}}, Open),
    ?assertEqual([{stop, pid(101)}, {send, {ended, 1, <<"closed">>}}], readable(Actions)).

%% Pull sampling: a view that answers 100 times while the browser is
%% paused has one of them sent, and the connection keeps none of the rest;
%% the next `next` asks the view again and sends only what it answers.
a_paused_browser_is_sent_one_update_and_the_core_keeps_none_test() ->
    Big = binary:copy(<<"x">>, 30000),
    {_, Open} = run([in({open, 1, {path, [<<"a">>]}}), {opened, 1, pid(101)}], greeted()),
    {First, Answered} = erx_web_conn:step({update, 1, record(<<"change 1">>)}, Open),
    ?assertEqual([{send, {update, 1, record(<<"change 1">>)}}], readable(First)),
    Changes = [{update, 1, record(<<Big/binary, (integer_to_binary(N))/binary>>)} || N <- lists:seq(2, 100)],
    {Dropped, Paused} = run(Changes, Answered),
    ?assertEqual([], Dropped),
    ?assertEqual(Answered, Paused),
    ?assert(byte_size(term_to_binary(Paused)) < 1024),
    {Next, Asked} = erx_web_conn:step(in({next, 1}), Paused),
    ?assertEqual([{next, pid(101)}], Next),
    {Last, _} = erx_web_conn:step({update, 1, record(<<"change 100">>)}, Asked),
    ?assertEqual([{send, {update, 1, record(<<"change 100">>)}}], readable(Last)).

%% Every input sequence from a small alphabet, explored breadth first over
%% distinct states until no step reaches a new one (a fixpoint, not a
%% depth; ?DEPTH only stops a runaway), each step checked against a model
%% that knows only what the browser asked for and which pids it was given.
%% Three views of each target kind; 4 is a number never opened.

every_input_sequence_keeps_the_model_test_() ->
    {timeout, 120, fun() -> ?assert(explore() > 5000) end}.

alphabet() ->
    Record = <<1:32/little, 0>>,
    Browser = [{hello, erx_web_proto:hash()}, {hello, <<0:256>>},
               {open, 1, {path, [<<"a">>]}}, {open, 2, {ui, 7}}, {open, 3, {trace, [], false, true}},
               {open, ?LAST_VIEW, uis}, {next, 1}, {next, 2}, {next, 3}, {next, 4},
               {close, 1}, {close, 2}, {close, 3}, {event, 1, Record}, {event, 2, Record}, {event, 3, Record}],
    Views = [{opened, 1, pid(101)}, {opened, 2, pid(102)}, {opened, 3, pid(103)},
             {update, 1, record(<<"r">>)}, {update, 1, record(binary:copy(<<"x">>, 65536))},
             {update, 2, {ui, [Record]}}, {update, 3, {entries, [{gap, 5}]}},
             {ended, 1, scope}, {ended, 2, closed}, {ended, 3, no_facet}],
    [in(Message) || Message <- Browser] ++ [{in, <<255>>}, {text, <<"x">>}, tick | Views].

-record(model, {hello = false, closed = false,
                opened = [],     % views the browser opened that are not gone
                owed = #{},      % view => updates the browser asked for and has not had
                asks = #{},      % view => requests of the browser the core has not passed on
                live = #{},      % pid => view, given and neither stopped nor ended
                reported = [],   % views whose pid was given
                gone = [],       % views the browser closed or heard ended
                ui = []}).       % views the browser opened as a UI

explore() ->
    Alphabet = alphabet(),
    explore([{conn(), #model{}}], #{}, Alphabet, ?DEPTH).

explore([], Seen, _Alphabet, _Depth) ->
    map_size(Seen);
explore(Frontier, Seen, Alphabet, Depth) when Depth > 0 ->
    Next = [{Core, Model} || {Before, Was} <- Frontier, Input <- Alphabet, applies(Input, Was),
                             {Core, Model} <- [checked_step(Input, Before, Was)]],
    Fresh = lists:usort([Node || Node <- Next, not is_map_key(Node, Seen)]),
    explore(Fresh, maps:merge(Seen, maps:from_keys(Fresh, true)), Alphabet, Depth - 1).

%% The front end reports each view's pid once.
applies({opened, View, _Pid}, #model{reported = Reported}) -> not lists:member(View, Reported);
applies(_Input, _Model) -> true.

checked_step(Input, Core, Model) ->
    {Actions, Next} = erx_web_conn:step(Input, Core),
    try check(Input, readable(Actions), Model) of
        #model{} = Checked -> {Next, Checked}
    catch
        throw:Violation -> erlang:error({violation, Violation, Input, Actions, Model})
    end.

check(_Input, Actions, #model{closed = true} = Model) ->
    [throw(after_close) || Action <- Actions, element(1, Action) =/= stop],
    after_actions(Actions, Model);
check(Input, Actions, #model{hello = false} = Model) ->
    case {Input =:= hello(), Actions} of
        {true, [{send, {welcome, _, _}}]} -> Model#model{hello = true};
        {true, _} -> throw({no_welcome, Actions});
        {false, _} -> before_hello(Input, Actions, Model)
    end;
check(Input, Actions, Model) ->
    after_actions(Actions, lists:foldl(fun action/2, asked(Input, Model), Actions)).

%% Before hello the core says only bye, with mismatch for another hash,
%% and stops a pid it is given.
before_hello(Input, Actions, Model) ->
    Expected = case Input of
                   {in, Bytes} ->
                       case erx_web_proto:decode(browser, Bytes) of
                           {ok, {hello, _}} -> bye(mismatch);
                           _ -> bye(protocol)
                       end;
                   {text, _} -> bye(protocol);
                   tick -> [{close, idle}];
                   {opened, _, Pid} -> [{stop, Pid}];
                   _ -> []
               end,
    Expected =:= Actions orelse throw({before_hello, Expected}),
    after_actions(Actions, Model#model{closed = lists:keymember(close, 1, Actions)}).

%% What the input itself tells the model: the browser's requests and
%% closes, a pid given, a view's own end.
asked({in, Bytes}, Model) ->
    case erx_web_proto:decode(browser, Bytes) of
        {ok, {open, View, Target}} -> request(View, opened_view(View, Target, Model));
        {ok, {next, View}} -> request(View, Model);
        {ok, {close, View}} -> gone(View, Model);
        _ -> Model
    end;
asked({opened, View, Pid}, #model{live = Live, reported = Reported} = Model) ->
    Model#model{live = Live#{Pid => View}, reported = lists:usort([View | Reported])};
asked({ended, View, _}, #model{live = Live} = Model) ->
    Model#model{live = maps:filter(fun(_Pid, Of) -> Of =/= View end, Live)};
asked(_Input, Model) ->
    Model.

opened_view(View, {ui, _Number}, #model{ui = Ui} = Model) ->
    opened_view(View, ui_opened, Model#model{ui = lists:usort([View | Ui])});
opened_view(View, _Target, #model{opened = Opened} = Model) ->
    Model#model{opened = lists:usort([View | Opened])}.

%% A request counts for a view the browser opened that is not gone; the
%% core drops the others or closes on them.
request(View, #model{opened = Opened} = Model) ->
    case lists:member(View, Opened) of
        true -> Model#model{owed = bump(View, 1, Model#model.owed), asks = bump(View, 1, Model#model.asks)};
        false -> Model
    end.

gone(View, #model{opened = Opened, owed = Owed, asks = Asks, gone = Gone} = Model) ->
    Model#model{opened = lists:delete(View, Opened), owed = maps:remove(View, Owed),
                asks = maps:remove(View, Asks), gone = lists:usort([View | Gone])}.

bump(View, By, Counts) ->
    case maps:get(View, Counts, 0) + By of
        Negative when Negative < 0 -> throw({unasked, View});
        0 -> maps:remove(View, Counts);
        N -> Counts#{View => N}
    end.

%% Each action against the model, in order.
action(_Action, #model{closed = true}) ->
    throw(action_after_close);
action({send, {update, View, _}}, Model) ->
    not_gone(View, Model),
    Model#model{owed = bump(View, -1, Model#model.owed)};
action({send, {ended, View, _}}, Model) ->
    not_gone(View, Model),
    gone(View, Model);
action({send, {bye, _}}, Model) ->
    Model;
action({close, _}, Model) ->
    Model#model{closed = true};
action({open, View, _}, Model) ->
    not_gone(View, Model),
    Model#model{asks = bump(View, -1, Model#model.asks)};
action({next, Pid}, Model) ->
    View = live_view(Pid, Model),
    Model#model{asks = bump(View, -1, Model#model.asks)};
action({event, Pid, _}, #model{ui = Ui} = Model) ->
    lists:member(live_view(Pid, Model), Ui) orelse throw({event_to_no_ui, Pid}),
    Model;
action({stop, Pid}, #model{live = Live} = Model) ->
    Model#model{live = maps:remove(Pid, Live)};
action(Action, _Model) ->
    throw({unexpected, Action}).

not_gone(View, #model{gone = Gone}) ->
    lists:member(View, Gone) andalso throw({gone, View}).

live_view(Pid, #model{live = Live, gone = Gone}) ->
    case Live of
        #{Pid := View} -> not_gone(View, #model{gone = Gone}), View;
        #{} -> throw({not_live, Pid})
    end.

%% After every step no pid is left running for a view that is over, and
%% none at all once the connection closed; every request of the browser
%% for a view whose pid is known has been passed on; a bye is followed by
%% the close.
after_actions(Actions, #model{live = Live, gone = Gone, closed = Closed, asks = Asks} = Model) ->
    [throw({leaked, Pid}) || Pid := View <- Live, Closed orelse lists:member(View, Gone)],
    [throw({not_passed_on, View}) || _Pid := View <- Live, is_map_key(View, Asks)],
    case lists:keyfind(bye, 1, [Message || {send, Message} <- Actions]) of
        false -> ok;
        {bye, Reason} -> {close, Reason} = lists:last(Actions)
    end,
    Model.
