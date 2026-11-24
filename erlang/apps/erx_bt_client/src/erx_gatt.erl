%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt).
-moduledoc """
The client of the `ble` facet (docs/design-bluetooth.md, "The `ble` facet" and "The
client"): the operations an app makes through the facet its domain holds, `erx:cap(ble)`,
and the one reader of the events the Bluetooth domain's registry sends a handler.

**Operations.** Each calls the facet and answers its answer, checked against the
operation's shape (answer/2) since the facet is another domain's: an answer of another
shape is `{error, badarg}`. A domain that holds no `ble` facet is answered
`{error, not_granted}`, as a grant that names no service is. attach/1 does not pass on
`{error, attached}` at once: a previous handler's end, in an ended session, may not yet
have reached the registry, so it asks again every `bt_attach_retry_ms` until
`bt_attach_wait_ms` has passed since its first ask. set/3, notify/4 and indicate/4 exit
the caller with `{not_attached, Service}` at `{error, not_attached}`: the caller is no
longer the service's handler, and only a new attach, which
its supervisor's restart makes, makes it one again. Each waits with the timeout
`infinity`, since an indication waits on the phone's confirmation; the call's monitor
ends the wait when the facet ends.

**Events.** The registry is in the Bluetooth domain, so each event arrives in that
domain's envelope, `{erx_origin, D, Event}` (docs/design-domains.md, "The funnel").
event/2 takes the envelope off only when `D` is the facet's owner and the event has one
of the shapes the design lists, each field of its type; every other message is
`unknown`, so an event another domain wrote never reaches the app as an event. event/2
and answer/2 are total over any term and make no atom.
""".

-include("generated/erx_abi.hrl").

-export([attach/1, set/3, notify/4, indicate/4, reply/2]).
-export([facet/0, event/2, answer/2]).
-export_type([table/0, event/0, answer/0, address/0]).

-doc "A Bluetooth device address: its type and its 48 bits.".
-type address() :: {public | random, <<_:48>>}.

-doc "A service's characteristics as attach answers them: each one's maximum and accesses.".
-type table() :: #{atom() => #{max := 0..512, access := #{atom() => atom()}}}.

-doc "A handler's answer to a write: ok, an ATT Application Error, or Value Not Allowed.".
-type answer() :: ok | {error, ?ERX_ATT_APPLICATION_ERROR_MIN..?ERX_ATT_APPLICATION_ERROR_MAX | value_not_allowed}.

-doc """
An event the registry sends a handler, its envelope off. No `connected` carries a bond's
identity address: `address` is the one the phone connected from.
""".
-type event() :: {connected, Conn :: reference(), #{address := address(), level := atom(), bonded := boolean()}}
               | {mtu, Conn :: reference(), Mtu :: pos_integer()}
               | {subscribed, Conn :: reference(), Char :: atom(), none | notify | indicate}
               | {write, Req :: reference(), Conn :: reference(), Char :: atom(), Value :: binary()}
               | {disconnected, Conn :: reference()}.

-doc """
Makes the caller the handler of `Service`: answers each of its characteristics' maximum
and accesses. The caller then hears, for each live link, `connected` and the link's `mtu`
when it changed, when it handles no other service yet, and a `subscribed` for each of the
service's characteristics the phone configured, then every later event of its services.
""".
-spec attach(atom()) -> {ok, table()} | {error, atom()}.
attach(Service) ->
    attach(Service, erlang:monotonic_time(millisecond) + ?ERX_BT_ATTACH_WAIT_MS).

attach(Service, Deadline) ->
    case call({attach, Service}) of
        {error, attached} = Refusal ->
            case erlang:monotonic_time(millisecond) + ?ERX_BT_ATTACH_RETRY_MS =< Deadline of
                true ->
                    timer:sleep(?ERX_BT_ATTACH_RETRY_MS),
                    attach(Service, Deadline);
                false ->
                    Refusal
            end;
        Answer ->
            Answer
    end.

-doc "Sets the value reads of `Service`'s `Char` return from now on.".
-spec set(atom(), atom(), binary()) -> ok | {error, atom()}.
set(Service, Char, Value) ->
    attached(Service, call({set, Service, Char, Value})).

-doc """
Notifies the phone of link `Conn` of `Service`'s `Char`: `ok` once queued for the link,
`{error, busy}` when its queue is full, `{error, gone}` when the link has ended.
""".
-spec notify(reference(), atom(), atom(), binary()) -> ok | {error, atom()}.
notify(Conn, Service, Char, Value) ->
    attached(Service, call({notify, Conn, Service, Char, Value})).

-doc "Indicates `Service`'s `Char` to the phone of link `Conn`: `ok` once the phone confirms.".
-spec indicate(reference(), atom(), atom(), binary()) -> ok | {error, atom()}.
indicate(Conn, Service, Char, Value) ->
    attached(Service, call({indicate, Conn, Service, Char, Value})).

-doc """
Answers the write the registry named `Req`. The registry takes the answer only from the
handler the write went to, once, and drops any other, so this answers `ok` for those too.
""".
-spec reply(reference(), answer()) -> ok | {error, atom()}.
reply(Req, Answer) ->
    call({reply, Req, Answer}).

-doc """
The facet this domain holds and its owner, the Bluetooth domain whose envelope its
events arrive in, or `none` when the domain holds no `ble` facet.
""".
-spec facet() -> {pid(), non_neg_integer()} | none.
facet() ->
    case erx:cap(ble) of
        undefined -> none;
        Facet -> {Facet, erx:owner(Facet)}
    end.

-doc """
The event `Message` carries when it arrived in the envelope of `Origin`, the facet's
owner, or `unknown`.
""".
-spec event(non_neg_integer(), term()) -> {ok, event()} | unknown.
event(Origin, {erx_origin, Origin, Event}) ->
    case is_event(Event) of
        true -> {ok, Event};
        false -> unknown
    end;
event(_Origin, _Message) ->
    unknown.

-doc """
The facet's answer `Answer` to an operation of kind `Kind` if it has that operation's
shape, or `{error, badarg}`: an attach's table, each characteristic's maximum a byte
count of at most 512 and its accesses atoms; `ok`; or a refusal `{error, Reason}` with
`Reason` an atom.
""".
-spec answer(attach | set | notify | indicate | reply, term()) -> {ok, table()} | ok | {error, atom()}.
answer(attach, {ok, Table} = Answer) when is_map(Table) ->
    case lists:all(fun is_characteristic/1, maps:to_list(Table)) of
        true -> Answer;
        false -> {error, badarg}
    end;
answer(Kind, ok) when Kind =/= attach -> ok;
answer(_Kind, {error, Reason} = Refusal) when is_atom(Reason) -> Refusal;
answer(_Kind, _Answer) -> {error, badarg}.

%% ---- internal ----

call(Request) ->
    case facet() of
        none -> {error, not_granted};
        {Facet, _Origin} -> answer(element(1, Request), gen_server:call(Facet, Request, infinity))
    end.

%% The caller is no longer Service's handler: it exits, for its supervisor to attach anew.
attached(Service, {error, not_attached}) -> exit({not_attached, Service});
attached(_Service, Answer) -> Answer.

is_characteristic({Char, #{max := Max, access := Access} = Limits}) ->
    is_atom(Char) andalso map_size(Limits) =:= 2 andalso is_integer(Max) andalso Max >= 0 andalso Max =< 512
        andalso is_map(Access) andalso lists:all(fun({A, L}) -> is_atom(A) andalso is_atom(L) end, maps:to_list(Access));
is_characteristic(_Characteristic) ->
    false.

is_event({connected, Conn, #{address := Address, bonded := Bonded, level := Level} = Info})
  when map_size(Info) =:= 3 ->
    is_reference(Conn) andalso is_address(Address) andalso is_boolean(Bonded) andalso is_atom(Level);
is_event({mtu, Conn, Mtu}) ->
    is_reference(Conn) andalso is_integer(Mtu) andalso Mtu >= ?ERX_ATT_MTU_DEFAULT;
is_event({subscribed, Conn, Char, Kind}) ->
    is_reference(Conn) andalso is_atom(Char) andalso lists:member(Kind, [none, notify, indicate]);
is_event({write, Req, Conn, Char, Value}) ->
    is_reference(Req) andalso is_reference(Conn) andalso is_atom(Char) andalso is_binary(Value);
is_event({disconnected, Conn}) ->
    is_reference(Conn);
is_event(_Event) ->
    false.

is_address({Type, <<_:48>>}) -> Type =:= public orelse Type =:= random;
is_address(_Address) -> false.
