%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_facets).
-moduledoc """
The domain's facet registry (docs/design-system.md, "Facets a configured
domain serves"): every facet the domain holds, by name, as facet/0 states
it. This module is the registry's one owner: it alone reads and writes the
persistent term that holds it, so the shape of a facet is known here and
nowhere else, and the build's `facet-registry` chokepoint refuses the term's
key in any other module.

install/1 is the one writer, and the domain's connection agent
(erx_connections) its one caller, in every domain: in the system domain the
domain service installs through the agent (erx_connections:grant/1). The
`facet-registry-writers` chokepoint refuses any other caller of install/1,
and the system domain's agent takes erx_connections:grant/1 only from the
domain service.

The registry's value carries a generation, a count that each installation
raises, an empty one included, so a process can wait for the next one
(docs/design-system.md, "Waiting for a grant"): await/3 waits for a facet of a
name, and changed/1 asks the agent, which writes every installation and
answers its waiters after each, for word of one past a generation.

The readers read the registry at use:

* find/1 and pids/0 answer `erx:cap/1` and `erx:caps/0`;
* table/1 puts the grant beneath each facet's entry of a namespace table at
  each resolution, so a re-grant serves the next lookup, and program_table/1
  does the same for a program's table, less every facet of the `windows`
  interface. A program's table is a program/0 value, which program/1 makes
  and only program_table/1 reads, and table/1 takes only a list, so no
  resolution of a program's path by its handler reaches a display;
* file_grant/2,3 is the one maker of a file client's handle on a files facet's
  grant. A caller that keeps the handle, as an image mount keeps the grant
  it opened its file on, keeps that grant until it lets it go.

No reader gives an entry or a handle more rights than the facet's grant
carries.

It is preloaded beside prim_file and erx_path, since every resolution of a
path reads it, the code loader's included.
""".

-export([find/1, pids/0, install/1, generation/0, await/3, changed/1, is_name/1, is_interface/1, is_facet/1,
         files/2, table/1, program/1, program_table/1, file_grant/2, file_grant/3]).
-export_type([name/0, interface/0, facet/0, program/0]).

-include("generated/erx_abi.hrl").

%% The registry's persistent term, which no other module names: {Generation, Facets},
%% the count of installations and each facet by name as {Interface, Facet}.
-define(REGISTRY, {erx, facets}).

%% A program's table as program/1 wraps it; only program_table/1 takes it apart.
-record(program, {mounts :: erx_path:table()}).

-doc """
A program's table, as its handler holds it for each resolution of the
program's paths (program/1). It is not a table: table/1 refuses it, and
program_table/1 alone turns it into the entries a resolution walks.
""".
-opaque program() :: #program{}.

-doc """
A facet as the registry holds it: its pid, or for a facet of a files service
its pid with its grant's rights, as the manifest's facet row states them
(files/2), the rights table/1 puts beneath each entry of the facet
(docs/design-files.md, "Rights beneath an entry").
""".
-type facet() :: pid() | {pid(), erx_abi_enums:files_rights()}.

-doc """
The name a facet is held under: its service's name, or for a drive's grant
its installed name, `{drive, N}`, N the drive window row's number
(docs/design-drives.md, "How the grant reaches the media domain"), so the
several drives of one serving domain are held apart.
""".
-type name() :: atom() | {drive, non_neg_integer()}.

-doc """
The interface number of a facet's service (abi/services), which the system
domain sets with the facet, from the manifest's row or from a re-grant's
source, and which no server's reply sets: what keeps a facet of the
`windows` interface from the domain's programs (program_table/1;
docs/design-files.md, "Narrowing for a program").
""".
-type interface() :: pos_integer().

-doc """
The pid of the facet named `Name` that the domain holds, or `undefined` when
it holds none of that name. A facet whose server ended is a dead pid until
the server's next incarnation installs another.
""".
-spec find(name()) -> pid() | undefined.
find(Name) ->
    case registry() of
        #{Name := {_Interface, Facet}} -> pid(Facet);
        #{} -> undefined
    end.

-doc "The pid of every facet the domain holds, by name, each as find/1 answers it.".
-spec pids() -> #{name() => pid()}.
pids() ->
    #{Name => pid(Facet) || Name := {_Interface, Facet} <- registry()}.

-doc """
Installs each of `Facets` under its name with its service's interface number,
replacing an older facet of the name and keeping every other. The caller is the registry's writer in its
domain, the one process whose installations are serialized, so none is lost
to another write that read the registry before it.
""".
-spec install(#{name() => {interface(), facet()}}) -> ok.
install(Facets) ->
    {Generation, Held} = value(),
    persistent_term:put(?REGISTRY, {Generation + 1, maps:merge(Held, Facets)}).

-doc """
The registry's generation: how many installations it has taken, 0 before the
first. A waiter reads it first, then what it decides on (erx:granted/0,1, the
facets), and names it in changed/1, so no installation after its read is missed.
""".
-spec generation() -> non_neg_integer().
generation() ->
    element(1, value()).

-doc """
The pid of the facet the registry holds under `Name`, once it holds one whose pid
is not `Seen`: `none` for a first wait, or the pid of a facet the caller followed
and whose server has ended, so a re-grant's successor answers. `timeout` when
`Timeout` passes first: milliseconds, `infinity` or `{abs, Deadline}` in
erlang:monotonic_time(millisecond), one deadline over every read. `{error, noproc}`
when the runtime is no node, so no agent writes the registry.

It runs in the caller: it reads the generation and then the facets, answers at
once when they hold such a facet, and otherwise asks the agent for word of a
generation past the one it read (changed/1) and reads again. A grant that failed
never reaches the registry, so a failure shows here as `timeout`. The answer says
what the registry holds, not that the server lives: a waiter that must hear of
the server's end monitors the pid, and waits again with it as `Seen`.
""".
-spec await(atom(), pid() | none, timeout() | {abs, integer()}) -> {ok, pid()} | timeout | {error, noproc}.
await(Name, Seen, Timeout) when is_integer(Timeout) ->
    await(Name, Seen, {abs, erlang:monotonic_time(millisecond) + Timeout});
await(Name, Seen, Timeout) ->
    Generation = generation(),
    case find(Name) of
        Pid when is_pid(Pid), Pid =/= Seen ->
            {ok, Pid};
        _ ->
            case changed(Generation) of
                {error, noproc} = NoAgent ->
                    NoAgent;
                Request ->
                    case gen:receive_response(Request, Timeout) of
                        {reply, ok} -> await(Name, Seen, Timeout);
                        timeout -> timeout;
                        %% The agent's end, which ends the runtime too.
                        {error, {_Reason, _Agent}} -> {error, noproc}
                    end
            end
    end.

-doc """
Asks the domain's connection agent for word of an installation past
`Generation`, and returns the request's id. The agent answers `ok` once the
registry's generation is past it, at once when it already is, and also when the
same process asks again, which answers its older request: so `ok` says to read
again, not that the registry changed. A process therefore keeps at most one
request outstanding, one for every fact it waits on, since two would answer each
other in turn with no installation. A process that takes its own messages, as a
gen_server does, takes the answer with gen_server:check_response/2; any other with
gen_server:receive_response/2, which drops a late answer once its timeout has
passed. `{error, noproc}` when the runtime is no node and runs no agent; the agent
answers `{error, badarg}` for a generation that is no non-negative integer.
""".
-spec changed(non_neg_integer()) -> gen:request_id() | {error, noproc}.
changed(Generation) ->
    case whereis(erx_connections) of
        undefined -> {error, noproc};
        Agent -> gen:send_request(Agent, '$gen_call', {changed, Generation})
    end.

-doc "Whether `Term` is a name as the system domain sends one, name/0's.".
-spec is_name(term()) -> boolean().
is_name({drive, N}) -> is_integer(N) andalso N >= 0;
is_name(Name) -> is_atom(Name).

-doc "Whether `Term` is an interface as the system domain sends one, interface/0's.".
-spec is_interface(term()) -> boolean().
is_interface(Interface) -> is_integer(Interface) andalso Interface > 0.

-doc """
Whether `Term` is a facet as the system domain sends it: a pid, or a pid with
a member of `files_rights`. The connection agent installs nothing else.
""".
-spec is_facet(term()) -> boolean().
is_facet({Pid, Rights}) -> is_pid(Pid) andalso lists:keymember(Rights, 1, ?ERX_FILES_RIGHTS_MEMBERS);
is_facet(Facet) -> is_pid(Facet).

-doc """
The facet of the files service grant `Pid` that serves `Rights`, the rights of
its facet row, which the domain service takes from the manifest and no reply
of the server's sets.
""".
-spec files(pid(), erx_abi_enums:files_rights()) -> facet().
files(Pid, Rights) ->
    {Pid, Rights}.

-doc """
The namespace table a resolution walks, made from `Mounts` as it starts. For
each entry whose provider is `{facet, Name, Tree}`, binds of one included:

* when the registry holds a files facet for `Name`, the entry is on its
  grant, provider `{grant, Pid, Tree}`, with the lesser of the rights its
  mount asked and those the facet carries (erx_path:lesser/2);
* otherwise, or when the two rights have no lesser, the entry is `ended`,
  which answers `eio`.

So a facet entry's rights never exceed its grant's, as an EROFS entry's and a
grant pid's do. A facet's mount names the facet, never a pid, so a re-grant
serves the next lookup and nothing has to follow the registry. Every other
entry is as `Mounts` holds it, except that

* every entry of the media tree, a drive's volumes, carries the `nofollow`
  mark: an entry whose provider names the facet `media`, whatever tree it
  asks, or a grant's tree named `media`, the tree of the facet's name, which
  a mount of a media grant by its pid names (`erx_ns:mount_own(media, _)`'s
  among them). So a mount of the facet, a bind of one, a program's table
  taken from one, and a mount by pid alike carry it, whether or not the
  registry holds the facet. The mark is derived here, from those names at
  each resolution, and stored in no table, so no writer of a table has to
  keep it, and the resolver follows no link a stranger's stick holds
  (erx_path; docs/design-drives.md, "Links and rights").
""".
-spec table(erx_path:table()) -> erx_path:table().
table(Mounts) when is_list(Mounts) ->
    Registry = registry(),
    [marked(Provider, resolved(Entry, Registry)) || #{provider := Provider} = Entry <- Mounts].

-doc """
A table a program's path resolves over, `Mounts`, as the one value
program_table/1 resolves: the program's own table as its handler's core
narrowed it, or for its image the starter's table.
""".
-spec program(erx_path:table()) -> program().
program(Mounts) when is_list(Mounts) ->
    #program{mounts = Mounts}.

-doc """
The table a resolution of a program's path walks, made from `Mounts`, the
program's table (program/1), as it starts (docs/design-files.md, "Narrowing for a
program"): table/1's, less every entry on a facet the registry holds as one
of the `windows` interface, as if `Mounts` had no entry there. The handler
calls it at every resolution, so a display's facet installed after the
program started, a display's facet that replaced a files facet of the same
name, and a display under any name or bound anywhere are left out as soon
as the registry holds them: a bind keeps its source's facet name, and the
interface comes with the facet from the system domain, never from a server
or a tree's name.
""".
-spec program_table(program()) -> erx_path:table().
program_table(#program{mounts = Mounts}) ->
    Registry = registry(),
    [marked(Provider, resolved(Entry, Registry))
     || #{provider := Provider} = Entry <- Mounts, not on_display(Provider, Registry)].

%% Whether Provider names a facet the registry holds as one of the windows interface.
on_display({facet, Name, _Tree}, Registry) ->
    case Registry of
        #{Name := {?ERX_SERVICE_WINDOWS, _Facet}} -> true;
        #{} -> false
    end;
on_display(_Provider, _Registry) ->
    false.

resolved(#{provider := {facet, Name, Tree}, rights := Asked} = Entry, Registry) ->
    case Registry of
        #{Name := {_Interface, {Pid, Rights}}} when is_pid(Pid) ->
            on_grant(Entry, Pid, Tree, erx_path:lesser(Asked, Rights));
        _ ->
            Entry#{provider := ended}
    end;
resolved(Entry, _Registry) ->
    Entry.

%% A facet's entry on the grant Pid with Rights, or ended for rights erx_path:lesser/2
%% does not order.
on_grant(Entry, _Pid, _Tree, none) -> Entry#{provider := ended};
on_grant(Entry, Pid, Tree, Rights) -> Entry#{provider := {grant, Pid, Tree}, rights := Rights}.

%% The resolved Entry of a mount whose provider was Provider, marked nofollow when that
%% provider lies in the media tree.
marked({facet, media, _Tree}, Entry) -> Entry#{nofollow => true};
marked({grant, _Pid, <<"media">>}, Entry) -> Entry#{nofollow => true};
marked(_Provider, Entry) -> Entry.

-doc """
A file client's handle on the grant of the files facet `Name`, read-only, on
the tree of the facet's name, for a mount or a read of rights `Rights`: `ro`
through a grant of any rights, and `rx`, a program image's, only through an
`rx` grant, which writes nothing (F5, F6). `{error, eacces}` for an `rx` use
of any other grant, and `{error, enoent}` when the registry holds no files
facet of the name. So no handle carries more than its grant's rights.
""".
-spec file_grant(atom(), ro | rx) -> {ok, {pid(), binary(), ro}} | {error, eacces | enoent}.
file_grant(Name, Rights) ->
    file_grant(Name, Rights, atom_to_binary(Name)).

-doc """
The handle file_grant/2 makes, on the tree named `Tree` instead of the
facet's name: for a facet of an interface whose tree has one name whatever
the service is called, as an input tree's is `input_tree`
(abi/services/input.txt).
""".
-spec file_grant(atom(), ro | rx, binary()) -> {ok, {pid(), binary(), ro}} | {error, eacces | enoent}.
file_grant(Name, Rights, Tree) ->
    case registry() of
        #{Name := {_Interface, {Pid, Granted}}}
          when is_pid(Pid), (Rights =:= ro orelse (Rights =:= rx andalso Granted =:= rx)) ->
            {ok, {Pid, Tree, ro}};
        #{Name := {_Interface, {Pid, _Granted}}} when is_pid(Pid) ->
            {error, eacces};
        #{} ->
            {error, enoent}
    end.

%% The facets, by name.
registry() ->
    element(2, value()).

value() ->
    persistent_term:get(?REGISTRY, {0, #{}}).

-spec pid(facet()) -> pid().
pid({Pid, _Rights}) -> Pid;
pid(Pid) -> Pid.
