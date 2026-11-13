%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_driver_ctl).
-moduledoc """
The driver-control facet (docs/design-system.md, "The holder's driver-control
facet"): what lets the system domain stop, start or restart the driver process of a
unit that another domain holds. The domain that holds the unit serves the facet under
a service of the ABI's driver_control interface (abi/services/driver_control.txt),
which the manifest grants to the system domain alone (property 8), and the facet acts
on the driver process under that domain's own driver supervisor.

The grantee's side is stop/2, start/2 and restart/2: a call of {Operation, Unit} to
the facet, as the system shell makes it, for example
`erx_driver_ctl:restart(erx:cap(storage_ctl), block)`. Each answers ok, or
{error, running} for a start of a driver that runs, or {error, failed} when the
operation did not take: the driver did not start, which its own log line explains, or
the holder's driver supervisor does not have the driver or has ended. The facet
refuses a unit the holder does not name, and any request of another shape, with
{error, badarg}.

A stopped driver serves nothing until it starts again, and a request it was serving
fails, as at its crash; what a client of the driver does with that failure is the
client's (littlefs over the block driver: docs/design-system.md, "The holder's
driver-control facet").

The holder's side is start_mint/2, a child of the holder's supervisor: it names
itself the service's mint (erx_facet:provide/2) and starts a facet for each mint
request in the system domain's envelope that names the system domain as grantee
(mint_request/3). It refuses one for any other grantee, so a manifest row that
property 8's check missed still grants nothing. Its units map each unit name, as the
manifest names the unit, to the supervisor and child id of the unit's driver process;
a unit name from a request is only a key looked up in that map, so no request makes
an atom or names a process.

The facet acts within the grantee's call: the supervisor's terminate_child/2 and
restart_child/2. The grantee waits at most CALL_MS, and then exits; the facet waits
for the driver's shutdown, bounded by its child spec, and for its start, which is not
bounded, and takes no other request meanwhile. A request
arrives only from the grantee, in its envelope; erx_facet drops every other.
""".

-export([stop/2, start/2, restart/2]).
-export([start_mint/2, mint_request/3]).
%% The erx_facet callback of each facet the mint starts.
-export([init/1, admit/3]).
-export([mint_init/3]).

-export_type([units/0]).

%% Each unit the holder drives, by its manifest name, mapped to the supervisor and child
%% id of its driver process.
-type units() :: #{atom() => {Supervisor :: atom(), Child :: term()}}.
-type operation() :: stop | start | restart.
-type result() :: ok | {error, running | failed | badarg}.

%% How long the grantee waits for an operation: a driver's shutdown (2 s for erx_blk)
%% and its start, which resets the device.
-define(CALL_MS, 30000).

-doc "Stops the driver process of Unit, which then stays stopped until start/2.".
-spec stop(pid(), atom()) -> result().
stop(Facet, Unit) -> call(Facet, {stop, Unit}).

-doc "Starts the driver process of Unit, which must be stopped.".
-spec start(pid(), atom()) -> result().
start(Facet, Unit) -> call(Facet, {start, Unit}).

-doc "Stops the driver process of Unit, if it runs, and starts it again.".
-spec restart(pid(), atom()) -> result().
restart(Facet, Unit) -> call(Facet, {restart, Unit}).

call(Facet, Request) when is_pid(Facet) ->
    gen_server:call(Facet, Request, ?CALL_MS).

-doc """
Starts the mint of the driver-control service Name for Units, linked to the caller, a
supervisor of the holder's: start it while the holder's application starts, before
init's ready report (erx_facet:provide/2). The mint must live as long as its domain,
so its supervisor gives up at its end.
""".
-spec start_mint(atom(), units()) -> {ok, pid()}.
start_mint(Name, Units) when is_atom(Name), is_map(Units) ->
    proc_lib:start_link(?MODULE, mint_init, [self(), Name, Units]).

-doc false.
mint_init(Parent, Name, Units) ->
    ok = erx_facet:provide(Name, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    mint(erx_kernel_records:system_domain(), Name, Units).

mint(System, Name, Units) ->
    receive
        Message ->
            _ = case mint_request(System, Name, Message) of
                    {grant, Tag, Limits} ->
                        Grant = Limits#{grantee => System, ends_with => [self()], units => Units},
                        erx_facet:minted(Tag, erx_facet:start(?MODULE, Grant, #{}));
                    {refuse, Tag} ->
                        erx_facet:minted(Tag, {error, eperm});
                    unknown ->
                        ok
                end,
            mint(System, Name, Units)
    end.

-doc """
What the mint of the service Name, in a domain whose system domain's id is System, does
with Message: a mint request in the system domain's envelope is granted when its
grantee is the system domain and refused for any other; anything else is unknown and
dropped.
""".
-spec mint_request(pos_integer(), atom(), term()) ->
          {grant, pos_integer(), map()} | {refuse, pos_integer()} | unknown.
mint_request(System, Name, {erx_origin, System, {erx_facet_mint, Tag, Name, Grantee, Principal, Limits}})
  when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal), is_map(Limits) ->
    case Grantee of
        System -> {grant, Tag, Limits};
        _Other -> {refuse, Tag}
    end;
mint_request(_System, _Name, _Message) ->
    unknown.

-doc false.
init(#{units := Units}) ->
    {ok, Units}.

-doc false.
admit({Operation, Unit}, _From, Units)
  when Operation =:= stop; Operation =:= start; Operation =:= restart ->
    case Units of
        #{Unit := {Supervisor, Child}} -> {reply, act(Operation, Supervisor, Child), Units};
        #{} -> {refuse, badarg, Units}
    end;
admit(_Request, _From, Units) ->
    {refuse, badarg, Units}.

%% Operation on the driver process Child of Supervisor. Every outcome but ok and a start
%% of a running driver is failed: a start the driver ignored, a child the supervisor does
%% not have (the holder's units name it wrongly), and a supervisor that has ended, whose
%% domain is ending with it.
-spec act(operation(), atom(), term()) -> ok | {error, running | failed}.
act(stop, Supervisor, Child) ->
    case supervise(fun() -> supervisor:terminate_child(Supervisor, Child) end) of
        ok -> ok;
        _NotFound -> {error, failed}
    end;
act(start, Supervisor, Child) ->
    case supervise(fun() -> supervisor:restart_child(Supervisor, Child) end) of
        {ok, Pid} when is_pid(Pid) -> ok;
        {ok, Pid, _Info} when is_pid(Pid) -> ok;
        {error, running} -> {error, running};
        _NotStarted -> {error, failed}
    end;
act(restart, Supervisor, Child) ->
    case act(stop, Supervisor, Child) of
        ok -> act(start, Supervisor, Child);
        Error -> Error
    end.

%% A supervisor call, with a supervisor that is not running, or that ends during the call
%% (its domain is ending), taken as its answer, so the facet outlives it and answers the
%% grantee.
supervise(Call) ->
    try Call() catch exit:Reason -> {error, {ended, Reason}} end.
