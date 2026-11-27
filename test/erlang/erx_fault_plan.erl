%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fault_plan).
-moduledoc """
The one fault vocabulary of the host stand-ins (docs/design-recovery.md,
"Fault injection and tests", layer 2): a plan of `{Match, Fault}` rules a
stand-in asks at each exchange it serves, doing what the answer says.

An exchange has a kind, a term the stand-in names it by (a BOT stick's
`data_in` or `csw`, a window's `read`). A rule's `Match` is a kind, taken by
the next exchange of that kind, or `{nth, Kind, N}`, taken by the Nth
exchange of that kind counted from the plan's creation. The first rule in
order whose match fits is taken and leaves the plan; no rule fits, and the
answer is `pass`, the stand-in's own behaviour.

The five faults, as the stand-in acts them:

* `silent`: the exchange is never answered, and the device's state does not
  move, as a device that stopped listening;
* `{late, Ms}`: the right answer, Ms milliseconds late; its effect on the
  device lands when it completes, even after a cancel, a deadline or the
  caller's answer, as a write still on the wire;
* `{error, Reason}`: the exchange fails with Reason, in the stand-in's own
  form of a failure;
* `{wrong_once, Answer}`: one wrong answer in place of the right one:
  Answer itself, or, when Answer is a fun, Answer applied to the right
  answer (wrong_answer/2);
* `gone`: the device has left: this exchange and every later one, of any
  kind, answer `gone`.

A plan is a value; a stand-in keeps it in its own state. An empty plan
answers `pass` to every exchange, so a stand-in over one behaves as it did
without it.
""".

-export([new/1, add/2, ask/2, wrong_answer/2]).
-export_type([plan/0, rule/0, fault/0]).

-type fault() :: silent | {late, non_neg_integer()} | {error, term()} | {wrong_once, term()} | gone.
-type rule() :: {Match :: term(), fault()}.
-opaque plan() :: #{rules := [rule()], seen := #{term() => pos_integer()}, gone := boolean()}.

-doc "A plan of Rules, taken in order.".
-spec new([rule()]) -> plan().
new(Rules) ->
    lists:foldl(fun add/2, #{rules => [], seen => #{}, gone => false}, Rules).

-doc "Plan with Rule after its other rules; a rule that is not one is refused.".
-spec add(rule(), plan()) -> plan().
add(Rule = {_Match, Fault}, Plan = #{rules := Rules}) ->
    fault(Fault) orelse error({not_a_fault, Fault}),
    Plan#{rules := Rules ++ [Rule]}.

-doc "What an exchange of Kind meets: `pass` or the fault of the rule it takes, with the plan after it.".
-spec ask(term(), plan()) -> {pass | fault(), plan()}.
ask(_Kind, Plan = #{gone := true}) ->
    {gone, Plan};
ask(Kind, Plan = #{rules := Rules, seen := Seen}) ->
    N = maps:get(Kind, Seen, 0) + 1,
    Counted = Plan#{seen := Seen#{Kind => N}},
    case lists:splitwith(fun({Match, _Fault}) -> not fits(Match, Kind, N) end, Rules) of
        {_All, []} -> {pass, Counted};
        {Before, [{_Match, gone} | After]} -> {gone, Counted#{rules := Before ++ After, gone := true}};
        {Before, [{_Match, Fault} | After]} -> {Fault, Counted#{rules := Before ++ After}}
    end.

-doc "The answer a `{wrong_once, Answer}` gives in place of Right.".
-spec wrong_answer(term(), term()) -> term().
wrong_answer(Answer, Right) when is_function(Answer, 1) -> Answer(Right);
wrong_answer(Answer, _Right) -> Answer.

fits({nth, Kind, N}, Kind, N) -> true;
fits({nth, _Kind, _N}, _Other, _Count) -> false;
fits(Kind, Kind, _Count) -> true;
fits(_Match, _Kind, _Count) -> false.

fault(silent) -> true;
fault({late, Ms}) -> is_integer(Ms) andalso Ms >= 0;
fault({error, _Reason}) -> true;
fault({wrong_once, _Answer}) -> true;
fault(gone) -> true;
fault(_Other) -> false.
