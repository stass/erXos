%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg).
-moduledoc """
The package process (docs/design-packaging.md, "The package lifetime" and
"Boot and recovery"). One run of it is a lifetime: it begins with the
recovery, which reconciles the image's packages and the data partition's
`packages/` directory into each package's state, the path table and the
package set, and publishes the set to the start service.

`init/1` returns at once and the recovery runs after it, one action of the
plan per `step` message the process sends itself, so a recovery that
crashes is a restart within erx_pkg_sup's intensity, never a failed start
of the start service's application, and a call taken between two actions,
`packages/0`'s, waits for one action, never for the whole recovery. The
recovery's decisions are erx_pkg_plan's; this process carries out each
action it gives: every request on the packages through erx_pkg_io, named
by this pid as its lifetime, admission through `erx_app_admit:admit/4`,
registration through `erx_principal:register_app/1`, and the publication
through `erx_starter:packages/2`. A failed change stops the process, which
ends the lifetime: erx_pkg_io refuses every later request of it, and the
next lifetime's recovery starts again.

Every action of the recovery waits for the domain service's answer that the
system domain's namespace is in place (`erx_domain:system_namespace/0`), as
the start table's first read of `rc.conf` does, so the `packages` grant the
listing reads and the `system` grant an image package is read through are
installed before it when the storage domain made them in time. The request
goes out as the process starts; an error answer, a domain service that
ended, carries the recovery on all the same.

`packages/0` answers the scan and each package's record, which
`/proc/packages` shows; until the recovery is done the scan is `unknown`
and no package is listed.
""".
-behaviour(gen_server).

-export([start_link/1, packages/0, system_config/0, system_config/2]).
-export_type([config/0]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-doc """
The recovery's inputs: erx_pkg_plan's config and the manifest that
admission reads.
""".
-type config() :: #{images := [{binary(), <<_:256>>}],
                    signers := [{erx_pkg_header:signer(), <<_:256>>}],
                    max := pos_integer(),
                    manifest := erx_app_admit:manifest()}.

-doc "Start a lifetime of the package process.".
-spec start_link(config()) -> gen_server:start_ret().
start_link(Config) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).

-doc "The scan of `packages/` and each listed package's record.".
-spec packages() -> #{scan := erx_pkg_plan:scan(),
                      packages := #{{system | installed, binary()} => erx_pkg_plan:package_record()}}.
packages() ->
    gen_server:call(?MODULE, packages).

-doc """
The recovery's config from the domain library's app entries and the
system manifest, `system_config/2` of `erx_domain_lib:apps/0` and
`erx_build:system_manifest/0`.
""".
-spec system_config() -> config() | none.
system_config() ->
    system_config(erx_domain_lib:apps(), erx_build:system_manifest()).

-doc """
The recovery's config from `Apps`, the domain library's app entries, and
`Manifest`, the system manifest's bytes as read.

The answer is `none`, and the machine takes no packages and runs no
package process, when there is no library (a domain's runtime and a hosted
one), when the library places no app entries (its manifest has no `apps`
row), and when the manifest read here gives no config: it cannot be read,
is refused, or has no `apps` row. The last is a broken image, which is
logged; it costs the packages alone, never the start service, whose
supervisor builds its children from this answer.

Otherwise the images are the manifest's packages, each its file `NAME.app`
and header hash; the signers are its `signer` rows, then the `development`
signer when it holds the development key, which only a development
manifest does; and `max` is the library's, the one source of max
(docs/design-packaging.md, "An app's principal"), which admission's `apps`
row takes too.
""".
-spec system_config({ok, none | erx_domain_lib:apps()} | erx_domain_lib:error(),
                    {ok, binary()} | {error, term()}) -> config() | none.
system_config({ok, #{max := Max}}, {ok, Bytes}) ->
    case erx_pkg_manifest:system_config(Bytes) of
        {ok, #{apps := #{} = Apps, packages := Packages, signers := Signers,
               development := Development} = Read} ->
            #{images => [{<<Name/binary, ".app">>, Sha256} || #{name := Name, sha256 := Sha256} <- Packages],
              signers => Signers ++ development_signer(Development),
              max => Max,
              manifest => erx_pkg_manifest:admission(Read#{apps := Apps#{max := Max}})};
        {ok, #{apps := none}} ->
            broken_image(no_apps);
        {error, Reason} ->
            broken_image(Reason)
    end;
system_config({ok, #{}}, {error, Reason}) ->
    broken_image(Reason);
system_config({ok, none}, _Manifest) ->
    none;
system_config({error, _NoLibrary}, _Manifest) ->
    none.

%% The library placed app entries from a manifest that gives no config here.
broken_image(Reason) ->
    logger:error("packages: the system manifest gives no package config: ~0tp", [Reason]),
    none.

development_signer(none) -> [];
development_signer(Key) -> [{development, Key}].

init(Config) ->
    {ok, #{config => Config, scan => unknown, packages => #{}, namespace => erx_domain:system_namespace()},
     {continue, recover}}.

handle_continue(recover, #{config := Config} = State) ->
    PlanConfig = maps:with([images, signers, max], Config),
    recover(erx_pkg_plan:recover(start, PlanConfig), State).

handle_call(packages, _From, #{scan := Scan, packages := Packages} = State) ->
    {reply, #{scan => Scan, packages => Packages}, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

%% The plan's next action, carried out in a message of its own.
handle_info(step, #{action := Action, plan := Plan} = State) ->
    Answer = effect(Action, State),
    recover(erx_pkg_plan:recover(Answer, Plan), State);
handle_info(Message, #{namespace := Request} = State) when Request =/= settled ->
    case gen_server:check_response(Message, Request) of
        no_reply -> {noreply, State};
        Answer -> namespace_settled(Answer, State#{namespace := settled})
    end;
handle_info(_Message, State) ->
    {noreply, State}.

%% The namespace's answer: the action that waits for it is carried out now.
namespace_settled(Answer, State) ->
    case Answer of
        {reply, ok} -> ok;
        {error, {Why, _Server}} ->
            logger:warning("packages: no answer to the wait for the system domain's namespace: ~0P", [Why, 8])
    end,
    case State of
        #{action := _} -> self() ! step;
        #{} -> ok
    end,
    {noreply, State}.

recover({{done, #{scan := Scan, packages := Packages}}, _Plan}, State) ->
    {noreply, maps:without([action, plan], State#{scan := Scan, packages := Packages})};
recover({{stop, Reason}, _Plan}, State) ->
    logger:error("packages: the recovery stops: ~0tp", [Reason]),
    {stop, {recovery, Reason}, State};
%% Every action waits for the namespace (namespace_settled/2): the listing reads
%% /packages and a header of an image package the system grant, both in place only
%% once it has settled. Every action is otherwise carried out in the next message.
recover({Action, Plan}, #{namespace := Request} = State) when Request =/= settled ->
    {noreply, State#{action => Action, plan => Plan}};
recover({Action, Plan}, State) ->
    self() ! step,
    {noreply, State#{action => Action, plan => Plan}}.

%% Each action of the plan, carried out; its answer goes back to the plan.
effect(begin_lifetime, _State) ->
    erx_pkg_io:request({begin_lifetime, self()});
effect({header, Place, File}, _State) ->
    erx_pkg_io:request({header, self(), Place, File});
effect(list, _State) ->
    erx_pkg_io:request({list, self()});
effect({delete, File}, _State) ->
    erx_pkg_io:request({delete, self(), File});
effect({path_entry, Place, File, Entry}, _State) ->
    erx_pkg_io:request({path_entry, self(), Place, File, Entry});
effect({admit, #{header := #{name := Name}} = Checked, Held}, #{config := #{manifest := Manifest}}) ->
    case erx_app_admit:admit(Checked, Manifest, erx_principal:app_registry(), Held) of
        {ok, _} = Admitted ->
            logger:notice("packages: admitted ~ts", [Name]),
            Admitted;
        {error, Reason} = Refused ->
            logger:notice("packages: refused ~ts: ~0P", [Name, Reason, 8]),
            Refused
    end;
effect({register, Package}, _State) ->
    erx_principal:register_app(Package);
effect({publish, Set}, _State) ->
    erx_starter:packages(self(), Set).
