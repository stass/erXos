%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_uname).
-moduledoc """
`uname [-abmnoprsv]`: writes what system this is, as FreeBSD's uname does
(usr.bin/uname/uname.c): the fields the flags select, in FreeBSD's order
and layout, so a script written for FreeBSD or macOS reads it the same way.

Flags. `-s` and `-o` select the system's name, `-n` the machine's host
name, `-r` the release, `-v` the version, `-m` the machine type, `-p` the
processor architecture and `-b` the boot image's build identifier. `-a`
is `-mnrsv`, as on FreeBSD, and no flag at all is `-s`. An argument after
the flags is a usage error, as on FreeBSD.

Output. The selected fields on one line, separated by one space, in
FreeBSD's order whatever the order of the flags: name, host name,
release, version, machine type, processor, build identifier.

Where each value comes from (docs/design-shell.md, "Text commands"):

* the name and the release are abi/erx_abi.txt's `uname_sysname` and
  `uname_release`, and the machine type and processor are the
  architecture's `arch_machine` and `arch_machine_arch`
  (abi/arch/<arch>.txt), read here from the generated erx_abi.hrl; the
  runtime's os:type/0 and os:version/0 derive from the same two;
* the host name is the host part of the node name liberx gives the
  runtime, `Name@Host` with the system manifest's `host`
  (docs/design-system.md, "Identifiers"): node() when distribution runs,
  and otherwise the `-sname` or `-name` word liberx appends to init's
  arguments, which the system release starts with even though it runs
  no distribution;
* the build identifier is the one init's `-erx build` carries (erx_build);
* the version is the name, the release and the build identifier.

A value this domain cannot know, the host name of a runtime given no node
name or the build identifier of a runtime whose init was given none, is
written `unknown`, as GNU's uname writes a field it cannot tell, never a
guess. The host name is a system identifier, which the manifest's reader
checks, so the line needs no escaping; it is the command's own output, as
`echo`'s is.

The selection, the host part of a node name and the line are a pure core,
fields/1, host/1 and line/2, which the tests drive directly; run/2
gathers the two values that live in the running system and writes the
line.
""".

-behaviour(erx_cmd).
-erx_command(uname).
-erx_usage("uname [-abmnoprsv]").

-include("generated/erx_abi.hrl").

-export([run/2]).
-export([fields/1, host/1, line/2]).

-export_type([field/0, facts/0]).

-type field() :: sysname | nodename | release | version | machine | processor | build.

-doc "The two values the running system supplies, each `unknown` when this domain cannot tell.".
-type facts() :: #{nodename := binary() | unknown, build := binary() | unknown}.

%% FreeBSD's order of the fields on the line, which is also print_uname's.
-define(ORDER, [sysname, nodename, release, version, machine, processor, build]).

%%% The command

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "abmnoprsv") of
        {ok, Flags, []} ->
            erx_cmd:write(Ctx, line(fields(Flags), #{nodename => nodename(), build => build()}));
        {ok, _Flags, [_ | _]} ->
            {error, usage};
        {error, usage} ->
            {error, usage}
    end.

%% The host part of the runtime's node name, the machine's host name.
nodename() ->
    case erlang:is_alive() of
        true -> host(atom_to_binary(node()));
        false -> host(given_node_name())
    end.

%% The node name liberx appended to init's arguments, or none. It adds one
%% `-sname` or `-name` after the manifest's own arguments, so the last such
%% flag, in the order init:get_arguments/0 keeps, is its.
given_node_name() ->
    Words = [Word || {Flag, [Word | _]} <- init:get_arguments(), Flag =:= sname orelse Flag =:= name],
    case Words of
        [] -> none;
        _ -> unicode:characters_to_binary(lists:last(Words))
    end.

build() ->
    case erx_build:id() of
        {ok, Id} -> Id;
        {error, _} -> unknown
    end.

%%% The core

-doc "The fields a list of flag letters selects, in FreeBSD's order; none selects the name.".
-spec fields([char()]) -> [field()].
fields(Flags) ->
    Selected = lists:flatmap(fun selects/1, Flags),
    case [Field || Field <- ?ORDER, lists:member(Field, Selected)] of
        [] -> [sysname];
        Fields -> Fields
    end.

selects($a) -> lists:flatmap(fun selects/1, "mnrsv");
selects($b) -> [build];
selects($m) -> [machine];
selects($n) -> [nodename];
selects($o) -> [sysname];
selects($p) -> [processor];
selects($r) -> [release];
selects($s) -> [sysname];
selects($v) -> [version].

-doc """
The host part of a node name, `Name@Host`, or `unknown` for none, for one
not of that form and for `nonode@nohost`, the name of a runtime that is not
a node: no host is made up.
""".
-spec host(binary() | none) -> binary() | unknown.
host(<<"nonode@nohost">>) -> unknown;
host(Node) when is_binary(Node) ->
    case binary:split(Node, <<"@">>, [global]) of
        [Name, Host] when Name =/= <<>>, Host =/= <<>> -> Host;
        _ -> unknown
    end;
host(none) -> unknown.

-doc "The line uname writes for those fields, given what the running system supplied.".
-spec line([field()], facts()) -> iodata().
line(Fields, Facts) ->
    [lists:join($\s, [value(Field, Facts) || Field <- Fields]), $\n].

value(sysname, _Facts) -> ?ERX_UNAME_SYSNAME_BYTES;
value(nodename, #{nodename := Host}) -> known(Host);
value(release, _Facts) -> ?ERX_UNAME_RELEASE_BYTES;
value(version, #{build := Build}) ->
    [?ERX_UNAME_SYSNAME_BYTES, $\s, ?ERX_UNAME_RELEASE_BYTES, <<" build ">>, known(Build)];
value(machine, _Facts) -> ?ERX_ARCH_MACHINE_BYTES;
value(processor, _Facts) -> ?ERX_ARCH_MACHINE_ARCH_BYTES;
value(build, #{build := Build}) -> known(Build).

known(unknown) -> <<"unknown">>;
known(Value) when is_binary(Value) -> Value.
