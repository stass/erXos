%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_pkg_plan).
-moduledoc """
The package process's recovery as a pure state machine
(docs/design-packaging.md, "Boot and recovery"). `recover(start, Config)`
gives the first action; `recover(Answer, Plan)` takes the answer of the last
action and gives the next. erx_pkg carries each action out, through
erx_pkg_io for every request on the packages, and feeds the answer back, so
every decision of the recovery is here and every effect there.

The recovery, in order:

1. begins the lifetime at erx_pkg_io, which empties the path table;
2. for each image package, in name order: reads its header, runs the file
   check under its `package` row's hash, admits it beside the GATT services
   of the packages committed before it, sends its path entry and registers
   its principal;
3. reads the listing of `packages/`, at most `ERX_PKG_SCAN_MAX` entries; a
   listing with more is `overflow` and nothing in it is acted on, and a
   listing not yet readable, before the packages grant is in place, or one
   that fails leaves the scan `unknown`;
4. deletes every temporary file, then judges each installed package, in name
   order, as in step 2 but under the trusted signer keys;
5. publishes the package set: the admitted image packages, then the
   admitted installed ones, each group in name order.

A failed begin, deletion, path entry, registration or publication stops the
plan: the lifetime ends and the next one's recovery starts again. A failed
header read refuses that package alone. A package the file check refuses
gets a path entry with no header hash, so the tree lists it and serves none
of its bytes; one admission refuses keeps its authenticated header's entry.
""".

-export([recover/2, listing/3, package_file/1]).
-export_type([config/0, action/0, plan/0, package_record/0, entry/0, scan/0, published/0]).

-type place() :: system | installed.

-doc """
What the recovery starts from: the image's packages, each its file name and
the header hash its `package` row records; the trusted signer keys; and the
`apps` row's `max`, the most temporary files and installed packages a
lifetime writes.
""".
-type config() :: #{images := [{binary(), <<_:256>>}],
                    signers := [{erx_pkg_header:signer(), <<_:256>>}],
                    max := pos_integer()}.

-doc """
A path table entry: the header's SHA-256, its length and its extent for a
package the file check accepted, or `refused`, which lists the file and
serves no byte of it.
""".
-type entry() :: {accepted, <<_:256>>, pos_integer(), pos_integer()} | refused.

-doc """
A package the plan has committed, the one type erx_principal:register_app/1
registers and the start table publishes: its name, where it lies, its checked
header and its admission, whose signer is `checked`'s, since admission copies it.
""".
-type published() :: #{name := binary(), place := place(),
                       checked := erx_pkg_header:checked(),
                       admitted := erx_app_admit:admitted()}.

-doc """
One package's state as `/proc/packages` shows it. A package the file check
refused has no authenticated header, so its declared fields are `unknown`.
""".
-type package_record() :: #{place := place(),
                    state := admitted | refused,
                    reason := term(),
                    signer := erx_pkg_header:authenticator() | unknown,
                    version := pos_integer() | unknown,
                    memory := non_neg_integer() | unknown,
                    needs := [binary()] | unknown,
                    license := binary() | unknown}.

-doc """
The listing's scan: `unknown` until it is read, then the entries read and
whether that was all of them.
""".
-type scan() :: unknown | {ok, non_neg_integer()} | {overflow, non_neg_integer()}.

-type summary() :: #{scan := scan(), packages := #{{place(), binary()} => package_record()}}.

-type action() :: begin_lifetime
                | {header, place(), binary()}
                | {admit, erx_pkg_header:checked(), erx_app_admit:held()}
                | {path_entry, place(), binary(), entry()}
                | {register, published()}
                | list
                | {delete, binary()}
                | {publish, [published()]}
                | {done, summary()}
                | {stop, {failed, action(), term()}}.

-type task() :: begin_lifetime | {image, binary(), <<_:256>>} | list
              | {delete, binary()} | {installed, binary()} | publish.

-opaque plan() :: #{config := config(),
                    tasks := [task()],
                    last := action(),
                    after_entry := [action()],
                    judged := {place(), binary(), erx_pkg_header:checked()} | none,
                    records := #{{place(), binary()} => package_record()},
                    published := [published()],
                    scan := scan()}.

-doc "The first action, from `start`, or the next one, from the last one's answer.".
-spec recover(start, config()) -> {action(), plan()};
             (term(), plan()) -> {action(), plan()}.
recover(start, #{images := Images, signers := _, max := Max} = Config)
  when is_integer(Max), Max > 0 ->
    Tasks = [begin_lifetime]
            ++ [{image, File, Hash} || {File, Hash} <- by_name(Images)]
            ++ [list, publish],
    next(#{config => Config, tasks => Tasks, last => begin_lifetime, after_entry => [],
           judged => none, records => #{}, published => [], scan => unknown});
recover(Answer, #{last := Last} = Plan) ->
    step(Last, Answer, Plan).

-doc """
The listing of `packages/` sorted into what the recovery acts on: the
temporary files `tmp.K` of a slot `K` below `Max`, the packages `NAME.app`
with NAME an identifier, in name order, and every other entry but `image`,
which the recovery leaves as it is. `More`, more entries than were read,
makes the listing `overflow` with the count read.
""".
-spec listing([binary()], boolean(), pos_integer()) ->
    {overflow, non_neg_integer()}
  | {ok, #{temporaries := [binary()], packages := [binary()], unknown := [binary()]}}.
listing(Names, true, _Max) ->
    {overflow, length(Names)};
listing(Names, false, Max) ->
    Sorted = lists:foldr(fun(Name, Acc) -> sort_entry(Name, Max, Acc) end,
                         #{temporaries => [], packages => [], unknown => []}, Names),
    {ok, Sorted#{packages := by_name(maps:get(packages, Sorted))}}.

sort_entry(<<"image">>, _Max, Acc) ->
    Acc;
sort_entry(Name, Max, Acc) ->
    case {app_name(Name), Name} of
        {{ok, _}, _} -> prepend(packages, Name, Acc);
        {error, <<"tmp.", Slot/binary>>} -> sort_temporary(slot(Slot, Max), Name, Acc);
        {error, _} -> prepend(unknown, Name, Acc)
    end.

%% A package name is tried first, so an app named `tmp` is a package.
sort_temporary(true, Name, Acc) -> prepend(temporaries, Name, Acc);
sort_temporary(false, Name, Acc) -> prepend(unknown, Name, Acc).

prepend(Key, Name, Acc) ->
    maps:update_with(Key, fun(Names) -> [Name | Names] end, Acc).

%% A slot is a decimal number below Max with no leading zero, so each slot
%% has one file name.
slot(<<"0">>, _Max) -> true;
slot(<<First, _/binary>> = Digits, Max) when First >= $1, First =< $9 ->
    try binary_to_integer(Digits) < Max catch error:badarg -> false end;
slot(_, _Max) -> false.

-doc "Whether a file name is `NAME.app` with NAME an identifier.".
-spec package_file(binary()) -> boolean().
package_file(Name) ->
    app_name(Name) =/= error.

%% NAME of a file name NAME.app, when NAME is an identifier.
app_name(Name) ->
    Size = byte_size(Name) - 4,
    case Name of
        <<Stem:Size/binary, ".app">> when Size > 0 ->
            case erx_ident:new(Stem) of
                {error, bad_identifier} -> error;
                _ -> {ok, Stem}
            end;
        _ ->
            error
    end.

%% File names NAME.app in the order of their NAMEs, so `a.app` comes before
%% `a-b.app` as `a` comes before `a-b`.
by_name(Items) ->
    lists:sort(fun(A, B) -> stem(A) =< stem(B) end, Items).

stem({File, _Hash}) -> stem(File);
stem(File) -> binary:part(File, 0, max(byte_size(File) - 4, 0)).

%% The answer to each action.

step(begin_lifetime, ok, Plan) ->
    next(Plan);
step({header, Place, File}, {ok, Length, Bytes}, Plan)
  when is_integer(Length), is_binary(Bytes) ->
    case erx_pkg_header:check_file({File, Length, Bytes}, authority(Place, File, Plan)) of
        {ok, Checked} ->
            emit({admit, Checked, held(Plan)}, Plan#{judged := {Place, File, Checked}});
        {error, Reason} ->
            entry(Place, File, refused, unauthenticated(Place, {file, Reason}), [], Plan)
    end;
step({header, Place, File}, {error, Reason}, Plan) ->
    entry(Place, File, refused, unauthenticated(Place, {read, Reason}), [], Plan);
step({admit, Checked, _Held}, {ok, Admitted}, #{judged := {Place, File, Checked}} = Plan) ->
    #{header := #{name := Name}} = Checked,
    entry(Place, File, accepted(Checked), authenticated(Place, Checked, admitted, none),
          [{register, #{name => Name, place => Place, checked => Checked, admitted => Admitted}}],
          publishing(Place, Checked, Admitted, Plan#{judged := none}));
step({admit, Checked, _Held}, {error, Reason}, #{judged := {Place, File, Checked}} = Plan) ->
    entry(Place, File, accepted(Checked), authenticated(Place, Checked, refused, Reason), [],
          Plan#{judged := none});
step({path_entry, _, _, _}, ok, #{after_entry := [Register]} = Plan) ->
    emit(Register, Plan#{after_entry := []});
step({path_entry, _, _, _}, ok, #{after_entry := []} = Plan) ->
    next(Plan);
step({register, _}, ok, Plan) ->
    next(Plan);
step(list, {ok, Names, More}, #{config := #{max := Max}, tasks := Tasks} = Plan)
  when is_list(Names), is_boolean(More) ->
    case listing(Names, More, Max) of
        {overflow, Count} ->
            next(Plan#{scan := {overflow, Count}});
        {ok, #{temporaries := Temporaries, packages := Packages}} ->
            Work = [{delete, Name} || Name <- Temporaries]
                   ++ [{installed, Name} || Name <- Packages],
            next(Plan#{scan := {ok, length(Names)}, tasks := Work ++ Tasks})
    end;
%% A listing that fails, the grant absent or the storage domain's error, leaves
%% the scan unknown: the image's packages are published without the installed ones,
%% as before the grant is in place, rather than the lifetime stopping on it.
step(list, {error, _}, Plan) ->
    next(Plan);
step({delete, _}, ok, Plan) ->
    next(Plan);
step({publish, _}, ok, #{scan := Scan, records := Records} = Plan) ->
    {{done, #{scan => Scan, packages => Records}}, Plan};
step(Last, Answer, Plan) ->
    {{stop, {failed, Last, Answer}}, Plan}.

next(#{tasks := []} = Plan) ->
    {{stop, {failed, none, no_task}}, Plan};
next(#{tasks := [Task | Rest]} = Plan) ->
    emit(action(Task, Plan), Plan#{tasks := Rest}).

action(begin_lifetime, _Plan) -> begin_lifetime;
action({image, File, _Hash}, _Plan) -> {header, system, File};
action(list, _Plan) -> list;
action({delete, File}, _Plan) -> {delete, File};
action({installed, File}, _Plan) -> {header, installed, File};
action(publish, #{published := Published}) ->
    {Images, Installed} = lists:partition(fun(#{place := Place}) -> Place =:= system end,
                                          lists:reverse(Published)),
    {publish, Images ++ Installed}.

emit(Action, Plan) ->
    {Action, Plan#{last := Action}}.

%% The path entry of a header the file check accepted.
accepted(#{sha256 := Sha256, extent := Extent, header := #{header_length := HeaderLength}}) ->
    {accepted, Sha256, HeaderLength, Extent}.

%% A package's path entry, its record and what follows the entry.
entry(Place, File, Entry, Record, AfterEntry, #{records := Records} = Plan) ->
    emit({path_entry, Place, File, Entry},
         Plan#{records := Records#{{Place, File} => Record}, after_entry := AfterEntry}).

%% What step 8 of admission judges a package by (erx_app_admit:held/0): the GATT
%% services of each package the plan has committed, in the recovery's order the
%% image's packages before the installed ones, so a service goes to the first
%% package judged that declares it. A package refused, or not yet judged, holds none.
held(#{published := Published}) ->
    #{Name => Gatt || #{name := Name, admitted := #{ble := #{gatt := Gatt}}} <- Published}.

publishing(Place, #{header := #{name := Name}} = Checked, Admitted,
           #{published := Published} = Plan) ->
    Plan#{published := [#{name => Name, place => Place, checked => Checked,
                          admitted => Admitted} | Published]}.

authority(system, File, #{config := #{images := Images}}) ->
    {File, Hash} = lists:keyfind(File, 1, Images),
    {hash, Hash};
authority(installed, _File, #{config := #{signers := Keys}}) ->
    {signers, Keys}.

authenticated(Place, #{header := Header, signer := Signer}, State, Reason) ->
    #{place => Place, state => State, reason => Reason, signer => Signer,
      version => maps:get(version, Header), memory => maps:get(memory, Header),
      needs => maps:get(needs, Header), license => maps:get(license, Header)}.

unauthenticated(Place, Reason) ->
    #{place => Place, state => refused, reason => Reason, signer => unknown,
      version => unknown, memory => unknown, needs => unknown, license => unknown}.
