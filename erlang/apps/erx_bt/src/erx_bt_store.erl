%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_store).
-moduledoc """
The Bluetooth domain's store (docs/design-bluetooth.md, "The identity address" and "Bonds
and the store"): the one owner of erXos's identity address on the air and of the bonds.
It sits first in `erx_bt_sup`, so it outlives every link, the window and the controller
group.

**One seam, every call under a deadline.** It keeps the whole state, encoded by
`erx_bt_state`, through a backend of two calls, `get() -> {ok, Generation, Blob | none}
| {error, unavailable}` and `put(Generation, Blob) -> ok | {error, too_large |
unavailable}`: in development builds `erx_bt_state_file` over the directory the
application's `state_dir` names. Each call runs in a short-lived process the store
monitors and kills at `bt_store_timeout_ms`; a `get` not answered by then is
`unavailable` and a `put` unconfirmed. The store waits on nothing else, so it answers
every request it takes within a read and a put.

**A late put never wins.** A put killed at its deadline may still complete inside the
storage domain, after a later put. So every put names a generation one above the highest
the store has read or put (`generation`), the backend's `get` answers the blob of the
highest generation put and the highest generation it has seen, and a put of an older
generation that lands late lands below the newer state and is never read. `forget all`
reads that generation first, since it may follow a start that could not.

**It changes only a state it has read.** The store is in one of three states: `read`;
`unknown` since its start; or `unknown` since a `put` it could not confirm. At its start
it reads: `none` is an empty state under an address made now; a blob that decodes is the
state; anything else leaves it `unknown` with an address made for this start only, and
then every change is refused until `forget all` or the next start. After an unconfirmed
`put` it keeps what it had and reads before the next change, which goes on only if that
read gives a state. Every change
but `forget all`, a pairing's `keep`, a bonded link's `subscriptions` and `served`, and
`forget` of one bond, goes through `change/2`: the state last read, the edit, one `put` of the
whole result, and the new bonds only at `ok`. After every confirmed change and every
read, each link it monitors whose bond is gone is sent `forgotten` (`adopt/2`).

**A bond's id is drawn.** A pairing's `keep` draws the bond's id, 16 octets of
`crypto:strong_rand_bytes/1`, in the edit that admits it, against the bonds that edit
starts from, and draws again while a kept bond has it (docs/design-bluetooth.md, "A bond's
name is made with its key"). It is written as 32 lower-case hexadecimal digits wherever
it names the bond, to the link's `kept`, to the window's outcome, in `resolve/1` and to
`forget/1`; it owes nothing to the address or to a count.

**Links.** A link reaches the store by `resolve/1` at its start and by `{erx_bt_link,
Link, Message}`. The store monitors a link from a `resolve` it answers with a bond or a
`keep` it answers `{ok, Id}`, finds the bond of `subscriptions` and `served` by that monitor,
and drops the link at its `'DOWN'`. It answers a `keep` to the link and tells the window
(`erx_bt_fs`) the outcome whether or not the link still lives.

**Secrets stay here.** `resolve/1` answers a bond without its IRK; `format_status/1` shows
`facts/1`, which holds no key, and each message as its kind; and a raise in a callback
ends the process with `{shutdown, {raised, Class, Facts}}`, a reason built from the facts
alone, so neither the raise's terms nor a queued `keep` reach a crash report.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").
-include_lib("kernel/include/logger.hrl").

-export([start_link/0, start_link/1, address/0, known/0, resolve/1, forget/1, bonds/0, facts/0, static_address/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, format_status/1]).
-export_type([backend/0, known/0]).

-doc "The two calls of the store's seam, each run under the store's deadline.".
-type backend() :: #{get := fun(() -> {ok, generation(), binary() | none} | {error, unavailable}),
                     put := fun((pos_integer(), binary()) -> ok | {error, too_large | unavailable})}.
-doc """
The store's state (docs/design-bluetooth.md, "Bonds and the store"): `read`; `unknown`
since its start, whose read gave no state, which refuses every change until `forget
all`; or `unknown` since a put it could not confirm, which reads before the next change.
""".
-type known() :: read | {unknown, start | put}.
-type generation() :: erx_bt_state_file:generation().
-type bond() :: erx_bt_state:bond().
-type identity() :: erx_smp_crypto:address().
-type id() :: erx_bt_state:id().

-record(store, {
    address :: <<_:48>>,
    known :: known(),
    reason = none :: none | store_unavailable | store_unreadable,
    bonds = [] :: [bond()],                                % secret: never shown, see format_status/1
    links = #{} :: #{reference() => {pid(), id()}},        % the links it monitors, by monitor, with their bond
    generation = 0 :: generation(),                        % the highest read or put, confirmed or not
    backend :: backend(),
    timeout :: pos_integer(),
    id_source :: fun(() -> <<_:128>>)                     % crypto:strong_rand_bytes(16) unless a test gives one
}).

-doc """
Starts the store, registered as `erx_bt_store`, over the development file in the
application's `state_dir` (default `/data/bt`), and reads it.
""".
-spec start_link() -> gen_server:start_ret().
start_link() ->
    Dir = application:get_env(erx_bt, state_dir, "/data/bt"),
    start_link(#{backend => #{get => fun() -> erx_bt_state_file:get(Dir) end,
                              put => fun(Generation, Blob) -> erx_bt_state_file:put(Dir, Generation, Blob) end}}).

-doc """
Starts the store over `backend`; `timeout` is `bt_store_timeout_ms` unless given, and
`id_source`, which draws a bond's id, is `crypto:strong_rand_bytes(16)` unless given.
""".
-spec start_link(#{backend := backend(), timeout => pos_integer(), id_source => fun(() -> <<_:128>>)}) ->
          gen_server:start_ret().
start_link(Options) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Options, []).

-doc "The identity address, most significant octet first.".
-spec address() -> <<_:48>>.
address() ->
    gen_server:call(?MODULE, address, infinity).

-doc """
The store's state, which the window takes at its start (docs/design-bluetooth.md, "The
pairing window"). The store answers after the requests queued before it, each within a read and a put.
""".
-spec known() -> known().
known() ->
    gen_server:call(?MODULE, known, infinity).

-doc """
The one bond a link's phone address names, without its IRK, or `none`
(docs/design-bluetooth.md, "The link's start"): an identity address by equality, a
resolvable private address by `ah` with each bond's IRK. A store `unknown` since its
start holds no bonds and answers `none`; after an unconfirmed put it answers from the
bonds it holds, so kept bonds work on a trial boot, whose every put fails. The caller, a link at its start, is monitored when a bond is answered.
""".
-spec resolve(identity()) -> none | erx_bt_link_core:resolved().
resolve(Address) ->
    gen_server:call(?MODULE, {resolve, Address}).

-doc """
Forgets the bond with that id, the whole id and nothing less, or every bond (the control
tree's `forget`): `enoent` when no bond has it, `eio` when the store stays `unknown` or
the `put` is unconfirmed. The store bounds the wait itself, by a read and a put.
""".
-spec forget(id() | all) -> ok | {error, enoent | eio}.
forget(Target) ->
    gen_server:call(?MODULE, {forget, Target}, infinity).

-doc """
Every kept bond's record, without a key, in the order of their ids (the control tree's
`bonds`): from the state last read or confirmed, so after an unconfirmed put the bonds the
store holds, and `eio` while the store is `unknown` since its start, which holds none it
could name. The store answers after the requests queued before it, each within a read
and a put.
""".
-spec bonds() -> {ok, [erx_bt_pair:bond()]} | {error, eio}.
bonds() ->
    gen_server:call(?MODULE, bonds, infinity).

-doc "What the store shows (docs/design-bluetooth.md, \"Inspection\"): never a key.".
-spec facts() -> map().
facts() ->
    gen_server:call(?MODULE, facts, infinity).

-doc """
The static random address of six random octets, most significant first: the top two bits
set over their lower 46, or `retry` when that is not a static random address
(`erx_smp_crypto:static_random/1`).
""".
-spec static_address(<<_:48>>) -> {ok, <<_:48>>} | retry.
static_address(<<_:2, Random:46>>) ->
    Address = <<2#11:2, Random:46>>,
    case erx_smp_crypto:static_random(Address) of
        true -> {ok, Address};
        false -> retry
    end.

%% The start's read (docs/design-bluetooth.md, "Bonds and the store", its table).
init(#{backend := Backend} = Options) ->
    Store = #store{address = make_address(), known = {unknown, start}, backend = Backend,
                   timeout = maps:get(timeout, Options, ?ERX_BT_STORE_TIMEOUT_MS),
                   id_source = maps:get(id_source, Options, fun() -> crypto:strong_rand_bytes(16) end)},
    {ok, case read(Store) of
             {{ok, none}, Read} -> Read#store{known = read};
             {{ok, #{address := Address, bonds := Bonds}}, Read} -> Read#store{known = read, address = Address, bonds = Bonds};
             {{error, Reason}, Read} -> Read#store{reason = Reason}
         end}.

make_address() ->
    case static_address(erx_bytes:entropy(6)) of
        {ok, Address} -> Address;
        retry -> make_address()
    end.

handle_call(Request, From, Store) ->
    guarded(fun() -> call(Request, From, Store) end, Store).

handle_cast(_Message, Store) ->
    {noreply, Store}.

handle_info(Message, Store) ->
    guarded(fun() -> info(Message, Store) end, Store).

%% A raise ends the store with the facts alone: the raise's terms and the message queue,
%% which a crash report would show, may hold a bond's keys. `{shutdown, _}` keeps
%% proc_lib's crash report, which lists the queue, from being written, and the
%% supervisor still restarts the store and ends what follows it.
guarded(Fun, Store) ->
    try
        Fun()
    catch
        Class:_ -> {stop, {shutdown, {raised, Class, facts(Store)}}, Store}
    end.

call(address, _From, #store{address = Address} = Store) ->
    {reply, Address, Store};
call(known, _From, #store{known = Known} = Store) ->
    {reply, Known, Store};
call({resolve, Address}, {Link, _}, #store{bonds = Bonds} = Store) ->
    case find(Address, Bonds) of
        none -> {reply, none, Store};
        #{id := Id} = Bond -> {reply, resolved(Bond), watch(Link, Id, Store)}
    end;
call({forget, all}, _From, Store) ->
    {Answer, Next} = forget_all(Store),
    {reply, Answer, Next};
call({forget, <<_:256>> = Id}, _From, Store) ->
    Edit = fun(Bonds) ->
                   case [Bond || #{id := Other} = Bond <- Bonds, Other =/= Id] of
                       Bonds -> {error, enoent};
                       Kept -> {ok, Kept}
                   end
           end,
    case change(Edit, Store) of
        {ok, Next} -> {reply, ok, Next};
        {error, enoent, Next} -> {reply, {error, enoent}, Next};
        {error, _, Next} -> {reply, {error, eio}, Next}
    end;
call(bonds, _From, #store{known = {unknown, start}} = Store) ->
    {reply, {error, eio}, Store};
call(bonds, _From, #store{bonds = Bonds} = Store) ->
    {reply, {ok, [record(Bond) || Bond <- lists:sort(fun(#{id := A}, #{id := B}) -> A =< B end, Bonds)]}, Store};
call(facts, _From, Store) ->
    {reply, facts(Store), Store}.

%% A bond as the control tree names it (erx_bt_pair:bond()): its id, identity and level,
%% and no key.
record(#{id := Id, identity := {Type, Address}, level := Level}) ->
    #{id => Id, address => Address, type => Type, level => Level}.

%% A pairing's `keep`, its one ordering point (docs/design-bluetooth.md, "The link's
%% messages"): answered to the link, and its outcome told to the window, whatever became
%% of the link. A bond is kept with no table hash, since `keep` carries none, and under an
%% id drawn against the bonds the edit starts from.
info({erx_bt_link, Link, {keep, Tag, #{identity := Identity, level := Level, irk := Irk, ltk := Ltk},
                          Subscriptions}}, #store{id_source = Draw} = Store) ->
    Bond = #{identity => Identity, irk => Irk, ltk => Ltk, level => Level, hash => <<>>,
             subscriptions => by_name(Subscriptions)},
    Edit = fun(Bonds) -> admit(Bond#{id => fresh_id(Draw, Bonds)}, Bonds) end,
    {Answer, Outcome, Next} = case change(Edit, Store) of
                                  {ok, Kept} ->
                                      #{id := Id} = Bonded = kept_bond(Identity, Kept),
                                      {{ok, Id}, {bonded, record(Bonded)}, watch(Link, Id, Kept)};
                                  {error, Reason, Failed} -> {{error, Reason}, {failed, Reason}, Failed}
                              end,
    Link ! {store, {kept, Answer}},
    {erx_bt_fs, node()} ! {outcome, Link, Tag, Outcome},
    {noreply, Next};
info({erx_bt_link, Link, {subscriptions, Subscriptions}}, Store) ->
    {Answer, Next} = case bond_edit(Link, fun(Bond) -> Bond#{subscriptions := by_name(Subscriptions)} end, Store) of
                         {ok, Id, Kept} -> {{ok, Id}, Kept};
                         {error, _, Failed} -> {{error, unavailable}, Failed}
                     end,
    Link ! {store, {kept, Answer}},
    {noreply, Next};
info({erx_bt_link, Link, {served, <<_:256>> = Hash}}, Store) ->
    case bond_edit(Link, fun(Bond) -> Bond#{hash := Hash} end, Store) of
        {ok, _Id, Kept} -> {noreply, Kept};
        {error, _, Failed} -> {noreply, Failed}
    end;
info({'DOWN', Monitor, process, _Link, _Reason}, #store{links = Links} = Store) when is_map_key(Monitor, Links) ->
    {noreply, Store#store{links = maps:remove(Monitor, Links)}}.

%% The pairing's bond joins the bonds unless its identity is already kept or the bonds
%% are full (docs/design-bluetooth.md, "Pairing never replaces a bond").
admit(#{identity := Identity} = Bond, Bonds) ->
    case lists:any(fun(#{identity := Kept}) -> Kept =:= Identity end, Bonds) of
        true -> {error, already_bonded};
        false when length(Bonds) >= ?ERX_BT_BONDS_MAX -> {error, bonds_full};
        false -> {ok, Bonds ++ [Bond]}
    end.

%% A drawn id no kept bond has, in its hexadecimal form: drawn again on a clash, which a
%% draw of 128 random bits meets with a probability of at most bt_bonds_max / 2^128.
fresh_id(Draw, Bonds) ->
    <<_:128>> = Drawn = Draw(),
    Id = binary:encode_hex(Drawn, lowercase),
    case lists:any(fun(#{id := Kept}) -> Kept =:= Id end, Bonds) of
        true -> fresh_id(Draw, Bonds);
        false -> Id
    end.

%% A change to the bond of the link `Link`, which the store found by the monitor a
%% `resolve` or a `keep` gave it, answered `{ok, Id, Store}` with that bond's id; a link
%% it does not monitor has no bond to change.
bond_edit(Link, Update, #store{links = Links} = Store) ->
    case [Id || {Pid, Id} <- maps:values(Links), Pid =:= Link] of
        [Id | _] ->
            Edit = fun(Bonds) ->
                           case lists:partition(fun(#{id := Kept}) -> Kept =:= Id end, Bonds) of
                               {[Bond], Others} -> {ok, Others ++ [Update(Bond)]};
                               {[], _} -> {error, forgotten}
                           end
                   end,
            case change(Edit, Store) of
                {ok, Kept} -> {ok, Id, Kept};
                Failed -> Failed
            end;
        [] ->
            {error, forgotten, Store}
    end.

%% The bond with that identity, which `admit/2` keeps unique, under the id it drew.
kept_bond(Identity, #store{bonds = Bonds}) ->
    hd([Bond || #{identity := Other} = Bond <- Bonds, Other =:= Identity]).

%% The one route of every change but `forget all`: from the state last read or
%% confirmed, the edit, one put of the whole result, and the new bonds only at `ok`. An
%% encoding refused writes nothing, so the store stays as it was; any put not `ok` leaves
%% the store `unknown` with what it had. The answer is `{ok, Store}` or `{error, Reason,
%% Store}`.
change(Edit, Store) ->
    maybe
        {ok, #store{address = Address, bonds = Bonds} = Current} ?= current(Store),
        {ok, Edited} ?= edit(Edit(Bonds), Current),
        {ok, Blob} ?= encoded(erx_bt_state:encode(#{address => Address, bonds => Edited}), Current),
        case write(Blob, Current) of
            {ok, Written} -> {ok, adopt(Edited, Written)};
            {unconfirmed, Written} -> {error, unavailable, unconfirmed(Written)}
        end
    end.

edit({ok, Edited}, _Store) -> {ok, Edited};
edit({error, Reason}, Store) -> {error, Reason, Store}.

encoded({ok, Blob}, _Store) -> {ok, Blob};
encoded({error, _TooLargeOrDuplicateId}, Store) -> {error, unavailable, Store}.

%% One put under the next generation, which the store counts as put whatever the answer,
%% since an unconfirmed put may yet land.
write(Blob, #store{backend = #{put := Put}, generation = Previous} = Store) ->
    Generation = Previous + 1,
    Answer = case backend(fun() -> Put(Generation, Blob) end, Store) of
                 ok -> ok;
                 _Unconfirmed -> unconfirmed
             end,
    {Answer, Store#store{generation = Generation}}.

%% After a put it could not confirm the store keeps what it had and reads before its
%% next change.
unconfirmed(Store) -> Store#store{known = {unknown, put}, reason = store_unavailable}.

%% The state a change starts from: the one last read or confirmed, or after an
%% unconfirmed put a fresh read, whose bonds replace the store's.
current(#store{known = read} = Store) ->
    {ok, Store};
current(#store{known = {unknown, start}} = Store) ->
    {error, unavailable, Store};
current(#store{known = {unknown, put}} = Store) ->
    case read(Store) of
        {{ok, none}, Read} -> {ok, adopt([], Read#store{known = read, reason = none})};
        {{ok, #{bonds := Bonds}}, Read} -> {ok, adopt(Bonds, Read#store{known = read, reason = none})};
        {{error, Reason}, Read} -> {error, unavailable, Read#store{reason = Reason}}
    end.

%% `forget all`, the one write that does not start from a read state: an empty state
%% under the address in use, whatever the store holds, under a generation above the
%% medium's, which it reads first, since a start that could not read never learned it.
%% Unconfirmed after the start's read, the store stays as the start left it but for the
%% generation it put.
forget_all(#store{address = Address, known = Known} = Store) ->
    {ok, Blob} = erx_bt_state:encode(#{address => Address, bonds => []}),
    case read(Store) of
        {{error, store_unavailable}, _} ->
            {{error, eio}, Store};
        {_Read, Counted} ->
            case write(Blob, Counted) of
                {ok, Written} -> {ok, adopt([], Written#store{known = read, reason = none})};
                {unconfirmed, Unconfirmed} when Known =:= {unknown, start} -> {{error, eio}, Unconfirmed};
                {unconfirmed, Unconfirmed} -> {{error, eio}, unconfirmed(Unconfirmed)}
            end
    end.

%% The bonds become `Bonds`, and each monitored link whose bond is gone is sent
%% `forgotten` and no longer monitored.
adopt(Bonds, #store{links = Links} = Store) ->
    Ids = [Id || #{id := Id} <- Bonds],
    {Kept, Gone} = maps:fold(fun(Monitor, {_, Id} = Link, {Keep, Drop}) ->
                                     case lists:member(Id, Ids) of
                                         true -> {Keep#{Monitor => Link}, Drop};
                                         false -> {Keep, [{Monitor, Link} | Drop]}
                                     end
                             end, {#{}, []}, Links),
    [begin erlang:demonitor(Monitor, [flush]), Pid ! {store, forgotten} end || {Monitor, {Pid, _}} <- Gone],
    Store#store{bonds = Bonds, links = Kept}.

watch(Link, Id, #store{links = Links} = Store) ->
    Store#store{links = Links#{erlang:monitor(process, Link) => {Link, Id}}}.

%% The backend's state, `{ok, none}`, `{ok, State}` or the reason /proc/bt shows, and the
%% store with the generation the backend named, when it answered, counted.
read(#store{backend = #{get := Get}, generation = Generation} = Store) ->
    case backend(Get, Store) of
        {ok, Seen, Kept} when is_integer(Seen), Seen >= 0, Kept =:= none orelse is_binary(Kept) ->
            {decoded(Kept), Store#store{generation = max(Seen, Generation)}};
        _Unavailable ->
            {{error, store_unavailable}, Store}
    end.

decoded(none) -> {ok, none};
%% A blob that does not decode, one of an earlier version included, is never converted:
%% the log says why, by the decoder's reason's name alone, since a misframed blob can put
%% an octet of a key where the reason's integer is read.
decoded(Blob) ->
    case erx_bt_state:decode(Blob) of
        {ok, State} ->
            {ok, State};
        {error, Reason} ->
            ?LOG_WARNING(#{what => bt_state_unreadable, reason => erx_report:reason_name(Reason)}),
            {error, store_unreadable}
    end.

%% One call of the backend, in a process of its own, linked so that it ends with the
%% store, and killed at the deadline. It sends its answer under a fresh tag and exits
%% normally; an answer that races the kill is flushed after the 'DOWN', which follows
%% every message of the process. A raise inside the call is caught there and answers
%% `unavailable`, so its terms, which may hold the blob, reach no error report.
backend(Call, #store{timeout = Timeout}) ->
    Store = self(),
    Tag = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() -> Store ! {Tag, try Call() catch _:_ -> {error, unavailable} end} end,
                               [link, monitor]),
    receive
        {Tag, Answer} ->
            receive {'DOWN', Monitor, process, Pid, _} -> unlink(Pid), Answer end
    after Timeout ->
        unlink(Pid),
        exit(Pid, kill),
        receive {'DOWN', Monitor, process, Pid, _} -> ok end,
        receive {Tag, _} -> ok after 0 -> ok end,
        {error, unavailable}
    end.

%% A bond as `resolve/1` answers it: its id, no IRK, and its subscriptions by the table's atoms,
%% a name no atom exists for left out, since no table declares it.
resolved(#{id := Id, ltk := Ltk, level := Level, identity := Identity, hash := Hash, subscriptions := Subscriptions}) ->
    #{id => Id, ltk => Ltk, level => Level, identity => Identity, hash => Hash,
      subscriptions => #{Key => Kind || Names := Kind <- Subscriptions, {_, _} = Key <- [atoms(Names)]}}.

atoms({Service, Char}) ->
    try {binary_to_existing_atom(Service), binary_to_existing_atom(Char)}
    catch error:badarg -> none
    end.

by_name(Subscriptions) ->
    #{{atom_to_binary(Service), atom_to_binary(Char)} => Kind
      || {Service, Char} := Kind <- Subscriptions, Kind =/= none}.

%% The bond a phone's address names: an identity address by equality, else a resolvable
%% private address, top two bits 01, by ah with each bond's IRK (Vol 3 Part H 2.2.2; the
%% address's form, prand in the upper 24 bits and the hash in the lower, is Vol 6 Part B
%% 1.3.2.2's, and its resolution 1.3.2.3's). An all-zero IRK, which a phone that makes no
%% resolvable address sends (Vol 3 Part C 10.7), resolves nothing.
find(Address, Bonds) ->
    case [Bond || #{identity := Identity} = Bond <- Bonds, Identity =:= Address] of
        [Bond | _] -> Bond;
        [] -> find_private(Address, Bonds)
    end.

find_private({random, <<2#01:2, _:22, Hash:3/binary>> = Octets}, Bonds) ->
    Prand = binary:part(Octets, 0, 3),
    Resolves = fun(#{irk := Irk}) ->
                       Irk =/= <<0:128>> andalso crypto:hash_equals(erx_smp_crypto:ah(Irk, Prand), Hash)
               end,
    case lists:filter(Resolves, Bonds) of
        [Bond | _] -> Bond;
        [] -> none
    end;
find_private(_Address, _Bonds) ->
    none.

%% What the store shows: the address, its state and reason, each bond's identity and
%% level, and how many links it monitors; never a key.
facts(#store{address = Address, known = Known, reason = Reason, bonds = Bonds, links = Links}) ->
    #{address => Address, store => shown(Known), reason => Reason,
      bonds => [{Identity, Level} || #{identity := Identity, level := Level} <- Bonds],
      links => map_size(Links)}.

shown(read) -> read;
shown({unknown, _}) -> unknown.

format_status(Status) ->
    erx_report:status(Status, #{state => fun store_facts/1, message => fun message_kind/1}).

store_facts(#store{} = Store) -> facts(Store);
store_facts(_State) -> hidden.

message_kind({erx_bt_link, _, Message}) -> {erx_bt_link, erx_report:reason_name(Message)};
message_kind(Message) -> erx_report:reason_name(Message).
