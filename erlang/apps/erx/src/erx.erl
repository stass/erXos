%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx).
-moduledoc """
erXos's functions for a person at an Erlang shell in any domain
(docs/design-live.md, "Erlang, in every domain"). Each is a thin entry
to the module that does the work, with that module's authority and no
authority of its own.
""".

-export([i/0, i/1, source/1, trace/1, trace_stop/1, export/3, exports/1, owner/1, cap/1]).

%%% Source lines: erx:source/1.

-doc """
Prints the source lines around a process's current location, or around a
function's first line (erx_source). `{error, unsupported}` when the
module's source cannot be shown, `{error, scope}` for a pid that names no
live process, and `{error, unsupported}` for a pid of another runtime,
whose source only the inspector reaches.
""".
-spec source(pid() | mfa()) -> ok | {error, erx_source:reason()}.
source(Target) ->
    erx_source:print(Target).

%%% The inspector: erx:i/0,1.

-doc """
Prints the machine (erx_inspector:overview/1): the machine's record, the
CPUs, the system domain's group, budget and threads, and the processes,
each value with its reporter, at most 80 columns wide.
""".
-spec i() -> ok.
i() ->
    Sections = erx_inspector:overview(inspect_scope()),
    io:put_chars(erx_render:overview(Sections, build(Sections))).

-doc """
Prints the record of Path, a path of abi/inspection.txt such as
`[processes, Pid]` or `[domains, 4, budget]`, each value with its
reporter; `{error, scope}` for a path that names nothing the caller may
see, `{error, unsupported}` for one the inspector cannot collect.
""".
-spec i([erx_schema:segment()]) -> ok | {error, scope | unsupported}.
i(Path) ->
    case erx_inspector:inspect(Path, inspect_scope()) of
        {ok, Record} ->
            {ok, Machine} = erx_inspector:inspect([], inspect_scope()),
            io:put_chars(erx_render:record(Record, build([{[], {ok, Machine}}])));
        {error, _Reason} = Error ->
            Error
    end.

%% The scope of the session's inspect facet, the facet's own value. In
%% Phase 1 the Erlang shell runs only in the system domain's session, whose
%% facets erx_shell_script:session_facets/0 gives; nothing yet hands the
%% Erlang shell the facets of the session that started it (TODO.md).
inspect_scope() ->
    #{inspect := Scope} = erx_shell_script:session_facets(),
    Scope.

%% Which build's projection to show: development only when the kernel
%% reports the machine as a development build.
build(Sections) ->
    case lists:keyfind([], 1, Sections) of
        {[], {ok, #{attrs := #{development := {kernel, {ok, true}}}}}} -> development;
        _ -> release
    end.

%%% The tracer: erx:trace/1 and erx:trace_stop/1.

%% The scope of the caller's trace facet. In Phase 1 every shell runs in the system
%% domain, whose facet is the system shell's, of scope `all`; a session's own facet
%% replaces it when sessions run in their domains.
-define(TRACE_SCOPE, all).

-doc """
Starts a trace of processes, frames or kernel events (erx_trace) that prints one
line per event in the shell, `Spec` as in docs/design-live.md, "Tracing";
`{error, badarg}`, `{error, no_facet}` or `{error, scope}` when it is refused, and
`{error, {failed, Why}}` when the trace process ends before it starts the trace.
""".
-spec trace(term()) -> {ok, reference()} | {error, badarg | no_facet | scope | {failed, term()}}.
trace(Spec) ->
    erx_trace:print(Spec, ?TRACE_SCOPE).

-doc "Ends the trace that erx:trace/1 returned Ref for.".
-spec trace_stop(reference()) -> ok.
trace_stop(Ref) ->
    erx_trace:stop(Ref).

%%% The export table (erx_dist, docs/design-domains.md, "Exports").

-doc """
Sets what the domain `Peer` holds on `Name`, one of this domain's own names
(a live local pid, or the domain's name `{domain, Id}`), to exactly `Rights`:
`send`, `link`, `exit` and `introduce` for a pid, `spawn` for the domain.
`[]` ends the hold. Returns `{error, badarg}` for any other name, a process
that has exited or a malformed argument, and `{error, system_limit}` when the
export table is full.
""".
-spec export(pid() | {domain, pos_integer()}, [atom()], pos_integer()) ->
    ok | {error, badarg | system_limit}.
export(Name, Rights, Peer) ->
    erx_dist:export(Name, Rights, Peer).

-doc "The peers holding one of this domain's own names, and what each holds.".
-spec exports(pid() | {domain, pos_integer()}) -> [{pos_integer(), [atom()]}].
exports(Name) ->
    erx_dist:exports(Name).

-doc """
The domain id that `Name`, a pid, reference or port, claims: this domain's own
for a local name, and for one from another domain the id its sender wrote into
it, which nothing checks. A message from another domain arrives as
`{erx_origin, D, Msg}`, `D` set by the connection, not by the sender; a message
whose `D` equals the owner of a name the receiver holds came from the domain
that name claims, so a reply sent to a forged name goes to no third domain.
""".
-spec owner(pid() | reference() | port()) -> non_neg_integer().
owner(Name) ->
    erx_dist:owner(Name).

%%% Facets (docs/design-domains.md, "Facets").

-doc """
The facet named `Name` that the domain service minted for this domain when
it started, as its spec's `facets` named it, or `undefined` when the domain
holds none of that name. The domain's init waits for them after its ready
report, before any `-eval`, `-s` or `-run`, and keeps them (edit 65); the
system domain, which reports nothing, holds none.
""".
-spec cap(atom()) -> pid() | undefined.
cap(Name) when is_atom(Name) ->
    maps:get(Name, persistent_term:get({erx, facets}, #{}), undefined).
