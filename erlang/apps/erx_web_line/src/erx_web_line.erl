%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_web_line).

-moduledoc """
The session's line to the web domain (docs/design-web.md, "Views on the
line"): the process through which the web domain opens views of this
session, each a process of this domain that queries the inspector at the
line's scope: the session's own until the system domain exports the line to
the web domain, and `all` from then on, the scope the design gives root's
session in a development build (docs/design-live.md, "Scopes"; export/2),
which its inspect facet does not carry yet (TODO.md).

The line serves one peer, the web domain it was exported to, and none
until then. The session names the line to the domain service in its ready
report (erx_web_line_app), and the system domain, when the host opens its
`web` facet, introduces the two domains and calls the line with
`{export, Web}`: the line exports itself to domain Web with send and serves
Web from then on, in place of any peer before it. The line takes that call
only in the system domain's envelope, so no other domain, and no process
of the session, chooses who reaches it (erx_domain:web_line/2).

From its peer it takes a request only as a call in the peer's envelope whose
caller and alias are names of the peer's (as erx_facet checks a grantee's
calls), so a reply never goes to a third domain, and a view takes `next`
and `stop` only in the peer's envelope; anything else from another domain
is dropped. A process of this session may call the line and its views
without an envelope, since it acts with the session's authority anyway.

* `{open, Target}` starts a view and answers `{ok, View}`, the view's pid,
  which the reply hands out to the peer with send alone
  (docs/design-domains.md, "Exports"); `{error, busy}` past ?VIEWS views,
  and `{error, unsupported}` for a target this line does not serve. The
  line serves the record view of `{path, Names}`: Names are /proc entry
  names, read into the inspector's path one at a time as /proc reads them
  (erx_procfs_core:child/2), and names that name nothing are answered
  `{error, scope}`, as a path outside the scope is, so the open tells no
  more than the view would (docs/design-web.md, "URLs"). Which paths the
  view reaches is the inspector's to decide, at the line's scope.
* A view belongs to the process that opened it, the caller of the open:
  it answers that process alone and ends when that process ends.

A view is one process with one query at a time. The open asks its first
update and each `next` one more: the view queries the inspector, projects
the record with erx_web_value and sends `{web_view, View, {record, Wire}}`
when the projection differs from the last one it sent, the first always;
otherwise it queries again after ?REQUERY_MS. A record that does not fit
one update, and a query the inspector refuses, end the view with
`{web_view_ended, View, Reason}`, Reason `too_large`, `scope`,
`unsupported` or `failed`. `stop` ends it. A view's crash ends that view
alone, which the web domain sees through its monitor.

The line holds one entry per open view; a view holds its last projection,
at most one update of 64 KiB (W8).
""".

-export([start_link/1]).
-export([line_init/2, view_init/1]).

-export_type([config/0]).

%% peer is the web domain's id, none until the system domain has the line
%% exported, and system the system domain's. scope is the scope views read at:
%% own, the session's own inspect scope (erx_facets:domain/0), read at each
%% query, which costs a lookup and keeps no state of the line's, until the
%% export makes it all (export/2). inspect answers a path's record at a scope,
%% erx_inspector:inspect/2 or a host test's stand-in. exports answers export/3
%% and owner/1, erx_dist or a host test's stand-in.
-type config() :: #{peer => pos_integer() | none, system => pos_integer(),
                    scope => own | erx_inspector:scope(),
                    inspect => fun((list(), erx_inspector:scope()) -> erx_inspector:answer()),
                    exports => module()}.

%% The views one line holds at once (docs/design-web.md, "Views on the line").
-define(VIEWS, 64).
%% How long a view that found nothing new waits before it queries again.
-define(REQUERY_MS, 2000).

-doc "Starts the line for Config, linked to the caller.".
-spec start_link(config()) -> {ok, pid()}.
start_link(Config) when is_map(Config) ->
    Defaults = #{peer => none, scope => own, inspect => fun erx_inspector:inspect/2, exports => erx_dist},
    proc_lib:start_link(?MODULE, line_init, [self(), maps:merge(Defaults, Config)]).

%% The scope a view reads at, from the line's.
scope(own) ->
    #{inspect := Scope} = erx_facets:domain(),
    Scope;
scope(Scope) ->
    Scope.

-doc false.
line_init(Parent, Config) ->
    process_flag(trap_exit, true),
    System = case Config of
                 #{system := Id} -> Id;
                 #{} -> erx_kernel_records:system_domain()
             end,
    proc_lib:init_ack(Parent, {ok, self()}),
    line(Parent, Config#{system => System}, #{}).

line(Parent, #{peer := Peer, system := System, exports := Exports} = Config, Views) ->
    receive
        {erx_origin, System, {'$gen_call', From, {export, Web}}} when is_integer(Web), Web > 0, Web =/= System ->
            {Reply, Next} = export(Web, Config),
            gen:reply(From, Reply),
            line(Parent, Next, Views);
        {erx_origin, Peer, {'$gen_call', {Caller, [alias | Alias]} = From, Request}} when is_pid(Caller), is_reference(Alias) ->
            case Exports:owner(Caller) =:= Peer andalso Exports:owner(Alias) =:= Peer of
                true -> line(Parent, Config, call(From, Request, Config, Views));
                false -> line(Parent, Config, Views)
            end;
        {'$gen_call', {Caller, _Tag} = From, Request} when is_pid(Caller), node(Caller) =:= node() ->
            line(Parent, Config, call(From, Request, Config, Views));
        {'EXIT', Parent, Reason} ->
            exit(Reason);
        {'EXIT', View, _Reason} ->
            line(Parent, Config, maps:remove(View, Views));
        _Other ->
            line(Parent, Config, Views)
    end.

%% The system domain's request to serve Web: the line exports itself to Web
%% with send alone, as encoding its name in a frame for Web would, and serves Web
%% from then on. A refused export leaves the peer as it was.
%%
%% From the export on, the line's views read at scope `all`, the scope the design
%% gives root's session in a development build (docs/design-live.md, "Scopes"):
%% the system domain exports only the line of the session the console logged root
%% in at, and only in a development build (erx_hostlink_web), so no other session's
%% line reaches it. That the line widens on the export rather than through the
%% session's inspect facet, and what a browser reads at `all`, is a security
%% residual in TODO.md.
export(Web, #{exports := Exports} = Config) ->
    case Exports:export(self(), [send], Web) of
        ok -> {ok, Config#{peer := Web, scope := all}};
        {error, Reason} -> {{error, Reason}, Config}
    end.

call({Caller, _Tag} = From, Request, Config, Views) ->
    {Reply, Next} = open(Request, Caller, Config, Views),
    gen:reply(From, Reply),
    Next.

%% A request: what it is answered and the views the line then holds.
open({open, _Target}, _Caller, _Config, Views) when map_size(Views) >= ?VIEWS ->
    {{error, busy}, Views};
open({open, {path, Names}}, Caller, Config, Views) ->
    case inspector_path([], Names) of
        {ok, Path} ->
            View = proc_lib:spawn_link(?MODULE, view_init, [Config#{conn => Caller, path => Path, last => none}]),
            {{ok, View}, Views#{View => Path}};
        error ->
            {{error, scope}, Views}
    end;
open({open, _Target}, _Caller, _Config, Views) ->
    {{error, unsupported}, Views};
open(_Request, _Caller, _Config, Views) ->
    {{error, badarg}, Views}.

%% Reads Names, untrusted /proc entry names, one at a time into the inspector's
%% path below Path; `error` at the first name that names nothing there, or when
%% Names is not a proper list of binaries. erx_procfs_core bounds each name before
%% it reads it and makes no atom, and the schema's bound on a path's segments ends
%% the walk.
inspector_path(Path, []) ->
    {ok, Path};
inspector_path(Path, [Name | Names]) ->
    case erx_procfs_core:child(Path, Name) of
        {ok, Child} -> inspector_path(Child, Names);
        error -> error
    end;
inspector_path(_Path, _Names) ->
    error.

%%% A record view.

-doc false.
view_init(#{conn := Conn} = View) ->
    _ = erlang:monitor(process, Conn),
    %% The open is the first request.
    view(answer(View)).

view(View) ->
    receive
        Message ->
            case request(Message, View) of
                next -> view(answer(View));
                stop -> exit(normal);
                other -> view(View)
            end
    end.

%% What a message asks of the view: one more update, its end, or nothing.
request({erx_origin, Peer, next}, #{peer := Peer}) -> next;
request(next, #{}) -> next;
request({erx_origin, Peer, stop}, #{peer := Peer}) -> stop;
request(stop, #{}) -> stop;
request({'DOWN', _Ref, process, Conn, _Reason}, #{conn := Conn}) -> stop;
request(_Message, #{}) -> other.

%% Queries until there is something new to send, sends it and returns the view
%% with it as the last answer; ends the view when the query cannot be answered.
%% While it waits to query again it takes only its end.
answer(#{conn := Conn, path := Path, scope := Scope, inspect := Inspect, last := Last} = View) ->
    case body(Inspect(Path, scope(Scope))) of
        {ok, Last} ->
            wait(erlang:start_timer(?REQUERY_MS, self(), requery), View);
        {ok, Body} ->
            Conn ! {web_view, self(), Body},
            View#{last := Body};
        {error, Reason} ->
            Conn ! {web_view_ended, self(), Reason},
            exit(normal)
    end.

wait(Timer, View) ->
    receive
        {timeout, Timer, requery} ->
            answer(View);
        Message ->
            case request(Message, View) of
                stop -> exit(normal);
                _ -> wait(Timer, View)
            end
    end.

%% The update body of an inspector's answer, or why the view ends.
body({ok, Record}) ->
    case erx_web_value:project(Record) of
        {ok, Wire} -> {ok, {record, Wire}};
        {error, too_large} -> {error, too_large}
    end;
body({error, Reason}) when Reason =:= scope; Reason =:= unsupported ->
    {error, Reason};
body({error, _Reason}) ->
    {error, failed}.
