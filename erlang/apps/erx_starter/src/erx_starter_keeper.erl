%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_starter_keeper).
-moduledoc """
A keeper (docs/design-apps.md, "Keeping a session"): one process that
holds one session. It asks the domain service for its principal's session
with erx_domain:start_session/2 and links to the session's domain pid.
The link is both halves of the keeper's contract:

* the session's end is the domain pid's end with {domain_down, Id, Info},
  which ends the keeper with that reason, so its supervisor counts it;
* the keeper's end, for any reason, a kill included, is an exit signal to
  the domain pid, which stops the domain (erx_domain_pid), so the session
  ends with its keeper and none outlives the row that kept it.

A start the service refuses ends the keeper with {shutdown, {refused,
Reason}}, an end its supervisor counts and proc_lib reports no crash for.

The start itself runs in a helper, which traps exits and links to the
keeper, so a keeper stopped while the service is still starting its
session leaves no session behind: the helper holds the new session by a
link of its own until the keeper has linked to it, and stops it if the
keeper ended first.

Start is what the table made: #{}, #{display => D} or
#{default_display => D}, D a service name the merge or the command check
found granted to the principal's template. The domain service takes the
name as the atom of a service it knows, so a name with no atom is no
service it serves and is refused without making one.
""".

-export([start_link/2]).
-export([keep/2]).

-spec start_link(pos_integer(), #{display => binary(), default_display => binary()}) -> {ok, pid()}.
start_link(Principal, Start) ->
    {ok, proc_lib:spawn_link(?MODULE, keep, [Principal, Start])}.

-doc false.
keep(Principal, Start) ->
    Keeper = self(),
    Helper = spawn_link(fun() -> start(Keeper, Principal, Start) end),
    receive
        {Helper, {ok, Domain}} ->
            %% A session that ended before the keeper took it is an end too.
            try link(erx_domain:pid(Domain))
            catch error:noproc -> exit({shutdown, {ended, erx_domain:id(Domain)}})
            end,
            Helper ! {Keeper, taken},
            %% The link ends the keeper when the session ends.
            receive after infinity -> ok end;
        {Helper, {error, Reason}} ->
            exit({shutdown, {refused, Reason}})
    end.

%% The helper: the start, held by a link until the keeper takes it.
start(Keeper, Principal, Start) ->
    process_flag(trap_exit, true),
    case start_session(Principal, Start) of
        {ok, Domain} = Started ->
            Pid = erx_domain:pid(Domain),
            link(Pid),
            Keeper ! {self(), Started},
            receive
                {Keeper, taken} -> unlink(Pid);
                {'EXIT', Keeper, _} -> exit(Pid, abandoned)
            end;
        {error, _} = Refused ->
            Keeper ! {self(), Refused}
    end.

start_session(Principal, Start) ->
    try erx_domain:start_session(Principal, maps:map(fun(_Key, Name) -> binary_to_existing_atom(Name) end, Start))
    catch
        error:badarg -> {error, no_service};
        exit:{Reason, {gen_server, call, _}} -> {error, Reason}
    end.
