%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_login_core).
-moduledoc """
The login service's decisions (docs/design-login.md, "A row's states"), pure:
the table of logins, one row per owner, the front end's process a request
came from, and the transitions of the design's table, each answering the next
table and the effects erx_login carries out. The core reads no clock, makes
no reference and sends nothing.

A row is in one of three states:

* cookie, an outstanding cookie and the step of its grace;
* pending, a login whose one outstanding step, the check, the session's start
  or the line's mint, is named by its step id; it keeps the facet's reply
  address, the state to return to on a failed check, none or the cookie, and
  the session once it has started;
* logged in, holding the session, which is final: the row goes only with its
  owner.

Every row belongs to the grant it was taken under, and only a request of that
grant acts on it, so no grant reaches another's rows (G1). A grant holds at
most its `logins` rows: a row is taken before any effect and refused past the
bound (G3). A pending or logged-in row refuses every operation `badarg`, so an
owner has at most one login in progress and logs in once in its life.

Each asynchronous step is named by a step id, `{step, N}`, from the table's
own counter, so an answer, or a grace, whose id no row holds is dropped: a
late answer for an owner that has gone, or the grace of a replaced cookie.

The core never keeps a passphrase or an exchange input: a passphrase passes
straight into the check effect, and a key login's signature is verified by
the service before the request reaches the core, which takes only the
verdict.
""".

-export([new/0, step/2, rows/1, count/2]).
-export_type([table/0, grant/0, event/0, effect/0, step_id/0]).

-doc """
A grant, as erx_login_facet forwards it: the facet, which names the grant and
which the session ends with; the grantee's domain id, for whom the line is
minted; the line the grant mints; its bound on rows; and the holder's name in
the manifest, which makes its terminals its own.
""".
-type grant() :: #{facet := pid(), grantee := pos_integer(), line := atom(),
                   logins := pos_integer(), holder := binary()}.

-opaque step_id() :: {step, non_neg_integer()}.

-type from() :: term().

-doc "A request the facet admitted, its arguments already bounded.".
-type request() :: {cookie, {ok, binary()} | error}
                 | {key_ok, User :: binary(), KeyBlob :: binary()}
                 | {login_key, User :: binary(), KeyBlob :: binary(), verified | not_verified}
                 | {login_passphrase, User :: binary(), Passphrase :: binary(), Peer :: binary()}.

-doc """
What the core reacts to: a request of an owner through a grant, the answer
to a step, a grace's end, and an owner's end. A check answers `{match,
Principal}`, `no_match`, `limited` or `unavailable`; a key lookup `{found,
Principal}` or `not_found`; a start `{ok, Session}` or `{error, Reason}`; a mint
`{ok, Line}` or `{error, Reason}`.
""".
-type event() :: {request, Owner :: pid(), grant(), from(), request()}
               | {answer, step_id(), term()}
               | {grace, step_id()}
               | {down, Owner :: pid()}.

-doc """
What erx_login carries out: a reply to the facet; a monitor or its removal for
an owner; a grace to arm; the passphrase check, at the grant's terminal; the
lookup of a key among a principal's login keys; a key_ok query; a session's
start, ending with the owner and the facet; a line's mint; a session's stop;
and a log line of a closed reason.
""".
-type effect() :: {reply, from(), term()}
                | {monitor, pid()}
                | {demonitor, pid()}
                | {arm_grace, step_id()}
                | {check, step_id(), User :: binary(), Passphrase :: binary(), network,
                   Terminal :: {binary(), binary()}}
                | {find_key, step_id(), User :: binary(), KeyBlob :: binary()}
                | {key_ok, from(), User :: binary(), KeyBlob :: binary()}
                | {start, step_id(), Principal :: pos_integer(), erx_domain:start()}
                | {mint, step_id(), Line :: atom(), Session :: term(), Grantee :: pos_integer(), Facet :: pid()}
                | {stop, Session :: term()}
                | {log, start_refused | mint_refused, Reason :: term()}.

-type back() :: none | {cookie, binary(), step_id()}.
-type row() :: #{state := cookie, grant := grant(), cookie := binary(), grace := step_id()}
             | #{state := pending, grant := grant(), phase := checking | starting | minting,
                 step := step_id(), from := from(), back := back(), session => term()}
             | #{state := logged_in, grant := grant(), session := term()}.

-opaque table() :: #{rows := #{pid() => row()}, counts := #{pid() => pos_integer()},
                     next := non_neg_integer()}.

-doc "An empty table.".
-spec new() -> table().
new() -> #{rows => #{}, counts => #{}, next => 0}.

-doc "Each owner's row by its state, for the service's status view and the tests.".
-spec rows(table()) -> #{pid() => cookie | pending | logged_in}.
rows(#{rows := Rows}) -> maps:map(fun(_Owner, #{state := State}) -> State end, Rows).

-doc "How many rows the grant of Facet holds.".
-spec count(pid(), table()) -> non_neg_integer().
count(Facet, #{counts := Counts}) -> maps:get(Facet, Counts, 0).

-doc "The next table and the effects of Event, in the order they are carried out.".
-spec step(event(), table()) -> {table(), [effect()]}.
step({request, Owner, #{facet := Facet} = Grant, From, Request}, #{rows := Rows} = T) ->
    case Rows of
        #{Owner := #{grant := #{facet := Facet}} = Row} -> request(Owner, Row, Grant, From, Request, T);
        #{Owner := _OfAnotherGrant} -> {T, [{reply, From, {error, badarg}}]};
        #{} -> request(Owner, none, Grant, From, Request, T)
    end;
step({answer, Step, Answer}, #{rows := Rows} = T) ->
    case [{Owner, Row} || Owner := #{state := pending, step := S} = Row <- Rows, S =:= Step] of
        [{Owner, Row}] -> answer(Owner, Row, Answer, T);
        [] -> {T, []}
    end;
step({grace, Step}, #{rows := Rows} = T) ->
    case [{Owner, Row} || Owner := Row <- Rows, grace_of(Row) =:= Step] of
        [{Owner, #{state := cookie}}] -> {free(Owner, T), [{demonitor, Owner}]};
        [{Owner, #{state := pending} = Row}] -> {put_row(Owner, Row#{back := none}, T), []};
        [] -> {T, []}
    end;
step({down, Owner}, #{rows := Rows} = T) ->
    case Rows of
        %% A pending row answers its facet, which frees the forward's slot in flight;
        %% the answer goes to a caller that has ended.
        #{Owner := #{state := pending, from := From}} -> {free(Owner, T), [{reply, From, {error, unavailable}}]};
        #{Owner := _Row} -> {free(Owner, T), []};
        #{} -> {T, []}
    end.

%% A request of Owner, whose row is Row or none.
request(_Owner, #{state := State}, _Grant, From, _Request, T) when State =:= pending; State =:= logged_in ->
    {T, [{reply, From, {error, badarg}}]};
request(Owner, Row, Grant, From, {cookie, Drawn}, T) ->
    case {taken(Owner, Row, Grant, T), Drawn} of
        {{ok, T1, Monitor}, {ok, Cookie}} ->
            {Grace, T2} = next_step(T1),
            {put_row(Owner, #{state => cookie, grant => Grant, cookie => Cookie, grace => Grace}, T2),
             Monitor ++ [{arm_grace, Grace}, {reply, From, {ok, Cookie}}]};
        _FullOrNoEntropy ->
            {T, [{reply, From, {error, unavailable}}]}
    end;
request(_Owner, _Row, _Grant, From, {key_ok, User, KeyBlob}, T) ->
    {T, [{key_ok, From, User, KeyBlob}]};
request(_Owner, none, _Grant, From, {login_key, _User, _KeyBlob, _Verdict}, T) ->
    {T, [{reply, From, {error, no_match}}]};
request(_Owner, #{state := cookie}, _Grant, From, {login_key, _User, _KeyBlob, not_verified}, T) ->
    {T, [{reply, From, {error, no_match}}]};
request(Owner, #{state := cookie, cookie := Cookie, grace := Grace}, Grant, From,
        {login_key, User, KeyBlob, verified}, T) ->
    {Step, T1} = next_step(T),
    {put_row(Owner, pending(Grant, checking, Step, From, {cookie, Cookie, Grace}), T1),
     [{find_key, Step, User, KeyBlob}]};
request(Owner, Row, #{holder := Holder} = Grant, From, {login_passphrase, User, Passphrase, Peer}, T) ->
    case taken(Owner, Row, Grant, T) of
        {ok, T1, Monitor} ->
            {Step, T2} = next_step(T1),
            {put_row(Owner, pending(Grant, checking, Step, From, back(Row)), T2),
             Monitor ++ [{check, Step, User, Passphrase, network, {Holder, Peer}}]};
        full ->
            {T, [{reply, From, {error, unavailable}}]}
    end.

%% The answer to a pending row's one outstanding step.
answer(Owner, #{phase := checking, grant := Grant} = Row, Answer, T)
  when element(1, Answer) =:= match; element(1, Answer) =:= found ->
    {Step, T1} = next_step(T),
    {put_row(Owner, Row#{phase := starting, step := Step, back := none}, T1),
     [{start, Step, element(2, Answer), start(Owner, Grant)}]};
answer(Owner, #{phase := checking, from := From, back := Back} = Row, Answer, T) ->
    Refusal = case Answer of
                  not_found -> no_match;
                  no_match -> no_match;
                  limited -> limited;
                  _Unavailable -> unavailable
              end,
    case Back of
        none ->
            {free(Owner, T), [{demonitor, Owner}, {reply, From, {error, Refusal}}]};
        {cookie, Cookie, Grace} ->
            #{grant := Grant} = Row,
            {put_row(Owner, #{state => cookie, grant => Grant, cookie => Cookie, grace => Grace}, T),
             [{reply, From, {error, Refusal}}]}
    end;
answer(Owner, #{phase := starting, grant := Grant} = Row, {ok, Session}, T) ->
    #{line := Line, grantee := Grantee, facet := Facet} = Grant,
    {Step, T1} = next_step(T),
    {put_row(Owner, Row#{phase := minting, step := Step, session => Session}, T1),
     [{mint, Step, Line, Session, Grantee, Facet}]};
answer(Owner, #{phase := starting, from := From}, Refused, T) ->
    {free(Owner, T), [{log, start_refused, Refused}, {demonitor, Owner}, {reply, From, {error, unavailable}}]};
answer(Owner, #{phase := minting, from := From, grant := Grant, session := Session}, {ok, Line}, T) ->
    {put_row(Owner, #{state => logged_in, grant => Grant, session => Session}, T), [{reply, From, {ok, Line}}]};
answer(Owner, #{phase := minting, from := From, session := Session}, Refused, T) ->
    {free(Owner, T),
     [{log, mint_refused, Refused}, {stop, Session}, {demonitor, Owner}, {reply, From, {error, unavailable}}]}.

%% The session's start: its ends_with names the owner and the facet, and a
%% web_line's session has the web display (docs/design-login.md, "Operations").
start(Owner, #{facet := Facet, line := web_line}) -> #{ends_with => [Owner, Facet], display => web};
start(Owner, #{facet := Facet}) -> #{ends_with => [Owner, Facet]}.

pending(Grant, Phase, Step, From, Back) ->
    #{state => pending, grant => Grant, phase => Phase, step => Step, from => From, back => Back}.

back(#{state := cookie, cookie := Cookie, grace := Grace}) -> {cookie, Cookie, Grace};
back(none) -> none.

grace_of(#{state := cookie, grace := Grace}) -> Grace;
grace_of(#{state := pending, back := {cookie, _Cookie, Grace}}) -> Grace;
grace_of(_Row) -> none.

%% A row for Owner under Grant: the one it holds, or a new one within the grant's
%% bound, with the owner's monitor; full past the bound.
taken(_Owner, #{} = _Held, _Grant, T) ->
    {ok, T, []};
taken(Owner, none, #{facet := Facet, logins := Logins}, #{counts := Counts} = T) ->
    case maps:get(Facet, Counts, 0) of
        Held when Held < Logins -> {ok, T#{counts := Counts#{Facet => Held + 1}}, [{monitor, Owner}]};
        _Full -> full
    end.

put_row(Owner, Row, #{rows := Rows} = T) -> T#{rows := Rows#{Owner => Row}}.

free(Owner, #{rows := Rows, counts := Counts} = T) ->
    #{Owner := #{grant := #{facet := Facet}}} = Rows,
    Counts1 = case maps:get(Facet, Counts) of
                  1 -> maps:remove(Facet, Counts);
                  N -> Counts#{Facet := N - 1}
              end,
    T#{rows := maps:remove(Owner, Rows), counts := Counts1}.

next_step(#{next := N} = T) -> {{step, N}, T#{next := N + 1}}.
