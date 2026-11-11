%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_uname).
-moduledoc """
`uname [-abiKmnoprsv]`: writes what system this is, as FreeBSD's uname
does (usr.bin/uname/uname.c): the fields the flags select, in FreeBSD's
order and layout, so a script written for FreeBSD or macOS finds each
field where it looks. The values are erXos's own: `-K`, for one, names
the kernel rather than FreeBSD's `__FreeBSD_version` number.

Flags. `-s` and `-o` select the system's name, `-n` the machine's host
name, `-r` the release, `-v` the version, `-m` the machine type, `-p` the
processor architecture, `-i` the configuration (FreeBSD's kernel ident),
`-K` the kernel (FreeBSD's kernel version) and `-b` the boot image's build
identifier. `-a` is `-mnrsv`, as on FreeBSD, and no flag at all is `-s`.
An argument after the flags is a usage error, as on FreeBSD.

Output. The selected fields on one line, separated by one space, in
FreeBSD's order whatever the order of the flags: name, host name,
release, version, machine type, processor, configuration, kernel, build
identifier. The version is four words, the source revision, its commit's
date, the configuration and the kernel:

    n1234-5e45e725588e Sun Nov  8 18:02:11 UTC 2026 qemu-virt/development fiasco-50bbe8a98119

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
* the source revision, its date, the configuration and the kernel are
  the build facts the image build wrote into this domain's release
  (erx_build:facts/0). The date is the commit's, in UTC, in the layout of
  macOS's `date`, so an image's bytes do not depend on when it was built.

A value this domain cannot know, the host name of a runtime given no node
name, the build identifier of a runtime whose init was given none, or a
build fact of a release without the file or of a build that could not
tell it, is written `unknown`, as GNU's uname writes a field it cannot
tell, never a guess. The host name is a system identifier, which the
manifest's reader checks. The build facts are read from a file, so each
passes the field escape (erx_text:escape_field/1) on its way to the line,
although erx_build admits only printable characters.

The selection, the host part of a node name, the date and the line are a
pure core, fields/1, host/1, date/1 and line/2, which the tests drive
directly; run/2 gathers the values that live in the running system and
writes the line.
""".

-behaviour(erx_cmd).
-erx_command(uname).
-erx_usage("uname [-abiKmnoprsv]").

-include("generated/erx_abi.hrl").

-export([run/2]).
-export([fields/1, host/1, date/1, line/2]).

-export_type([field/0, facts/0]).

-type field() :: sysname | nodename | release | version | machine | processor | configuration | kernel | build.

-doc "The values the running system supplies, each `unknown` when this domain cannot tell.".
-type facts() :: #{nodename := binary() | unknown,
                   build := binary() | unknown,
                   revision := binary() | unknown,
                   date := non_neg_integer() | unknown,
                   configuration := binary() | unknown,
                   kernel := binary() | unknown}.

%% FreeBSD's order of the fields on the line, which is also print_uname's.
-define(ORDER, [sysname, nodename, release, version, machine, processor, configuration, kernel, build]).

%%% The command

run(Args, Ctx) ->
    case erx_cmd:getopt(Args, "abiKmnoprsv") of
        {ok, Flags, []} ->
            Facts = maps:merge(#{nodename => nodename(), build => build()}, build_facts()),
            erx_cmd:write(Ctx, line(fields(Flags), Facts));
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

%% The build facts, or every one unknown for a release without them or with a
%% file that does not parse.
build_facts() ->
    case erx_build:facts() of
        {ok, Facts} -> Facts;
        {error, _} -> #{revision => unknown, date => unknown, configuration => unknown, kernel => unknown}
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
selects($i) -> [configuration];
selects($K) -> [kernel];
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

-doc """
A time in seconds since the epoch as macOS's `date` writes it in UTC,
`%a %b %e %H:%M:%S %Z %Y`: `Sun Nov  8 18:02:11 UTC 2026`, the day of the
month padded with a space to two places.
""".
-spec date(non_neg_integer()) -> binary().
date(Seconds) ->
    {{Year, Month, Day} = Date, {Hour, Minute, Second}} = calendar:system_time_to_universal_time(Seconds, second),
    WeekDay = element(calendar:day_of_the_week(Date), {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    MonthName = element(Month, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}),
    iolist_to_binary(io_lib:format("~s ~s ~2w ~2..0w:~2..0w:~2..0w UTC ~w",
                                   [WeekDay, MonthName, Day, Hour, Minute, Second, Year])).

-doc "The line uname writes for those fields, given what the running system supplied.".
-spec line([field()], facts()) -> iodata().
line(Fields, Facts) ->
    [lists:join($\s, [value(Field, Facts) || Field <- Fields]), $\n].

value(sysname, _Facts) -> ?ERX_UNAME_SYSNAME_BYTES;
value(nodename, #{nodename := Host}) -> known(Host);
value(release, _Facts) -> ?ERX_UNAME_RELEASE_BYTES;
value(version, #{revision := Revision, date := Date} = Facts) ->
    lists:join($\s, [escaped(Revision), date_word(Date), value(configuration, Facts), value(kernel, Facts)]);
value(machine, _Facts) -> ?ERX_ARCH_MACHINE_BYTES;
value(processor, _Facts) -> ?ERX_ARCH_MACHINE_ARCH_BYTES;
value(configuration, #{configuration := Configuration}) -> escaped(Configuration);
value(kernel, #{kernel := Kernel}) -> escaped(Kernel);
value(build, #{build := Build}) -> known(Build).

date_word(unknown) -> <<"unknown">>;
date_word(Seconds) -> date(Seconds).

known(unknown) -> <<"unknown">>;
known(Value) when is_binary(Value) -> Value.

%% A build fact, read from a file of the release, through the field escape.
escaped(unknown) -> <<"unknown">>;
escaped(Value) when is_binary(Value) -> erx_text:escape_field(Value).
