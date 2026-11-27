%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% EUnit cases for erx_serves, the reader of a domain's declaration of the services it
%% serves, and for its consumer, the storage domain's littlefs, which starts the mint of
%% a tree only where the declaration names it (docs/design-system.md, "The declaration").
%% test/host/erx_serves_test.rb compiles and runs them.
-module(erx_serves_tests).

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-export([owner/1]).

-define(STORAGE, 0).

files() -> integer_to_list(?ERX_SERVICE_FILES).

%% The words of one occurrence, as init:get_argument/1 answers them.
one(Words) -> {ok, [Words]}.

the_declaration_is_its_name_and_interface_pairs_in_order_test() ->
    Control = integer_to_list(?ERX_SERVICE_DRIVER_CONTROL),
    ?assertEqual([{<<"data">>, ?ERX_SERVICE_FILES}, {<<"storage_ctl">>, ?ERX_SERVICE_DRIVER_CONTROL}],
                 erx_serves:parse(one(["data", files(), "storage_ctl", Control]))),
    ?assertEqual([], erx_serves:parse(one([]))).

anything_but_one_occurrence_fails_the_start_test() ->
    ?assertError({bad_serves, missing}, erx_serves:parse(error)),
    ?assertError({bad_serves, missing}, erx_serves:parse({ok, []})),
    %% erx.arg=-erx_serves on the kernel command line makes a second occurrence.
    ?assertError({bad_serves, duplicate}, erx_serves:parse({ok, [["data", files()], ["home", files()]]})),
    ?assertError({bad_serves, duplicate}, erx_serves:parse({ok, [["data", files()], []]})).

malformed_words_fail_the_start_test() ->
    ?assertError({bad_serves, odd}, erx_serves:parse(one(["data", files(), "home"]))),
    lists:foreach(fun(Word) ->
                          ?assertError({bad_serves, {interface, Word}}, erx_serves:parse(one(["data", Word])))
                  end, ["files", "", "5x", "0x5"]).

%% The storage domain's littlefs starts the mint of each of its trees its declaration
%% names a files service, and no other: a row lacking home gets no home mint, and a tree
%% named under another interface gets none.
littlefs_mints_only_the_declared_trees_test() ->
    Files = ?ERX_SERVICE_FILES,
    ?assertEqual([data, packages, home],
                 erx_lfs_sup:minted([{<<"data">>, Files}, {<<"home">>, Files}, {<<"packages">>, Files},
                                     {<<"storage_ctl">>, ?ERX_SERVICE_DRIVER_CONTROL}])),
    ?assertEqual([data, packages], erx_lfs_sup:minted([{<<"data">>, Files}, {<<"packages">>, Files}])),
    ?assertEqual([data], erx_lfs_sup:minted([{<<"data">>, Files}, {<<"home">>, ?ERX_SERVICE_DRIVER_CONTROL}])),
    ?assertEqual([], erx_lfs_sup:minted([])).

%% A storage row that declares data and packages but not home: the ready report of the
%% mints littlefs starts for that declaration is accepted whole, where one that also
%% names a home mint, as littlefs started before it read the declaration, is refused
%% whole as oversized, its data and packages mints with it.
a_storage_row_lacking_home_keeps_its_other_providers_test() ->
    Declaration = [{<<"data">>, ?ERX_SERVICE_FILES}, {<<"packages">>, ?ERX_SERVICE_FILES}],
    Mints = maps:from_list([{Tree, mint(5)} || Tree <- erx_lfs_sup:minted(Declaration)]),
    ?assertEqual([], refusals(Mints)),
    ?assertMatch([{refused, oversized, _}], refusals(Mints#{home => mint(5)})).

%% The refusals of the storage row's ready report providing Mints, under a manifest whose
%% storage row declares data and packages.
refusals(Mints) ->
    Config = #{services => [{?STORAGE, data}, {?STORAGE, packages}], grants => [],
               interfaces => #{{?STORAGE, data} => ?ERX_SERVICE_FILES, {?STORAGE, packages} => ?ERX_SERVICE_FILES},
               owner => fun ?MODULE:owner/1, deadline => 10000},
    {_State, Actions} = erx_domain_mints:step({ready, ?STORAGE, 5, node_of(5), Mints}, erx_domain_mints:new(Config)),
    [Action || {refused, _, _} = Action <- Actions].

owner(Pid) ->
    <<131, 88, 119, Length, _Node:Length/binary, _Id:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation.

node_of(Domain) -> list_to_atom("d" ++ integer_to_list(Domain) ++ "@h").

mint(Domain) ->
    Name = atom_to_binary(node_of(Domain)),
    binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary, 1:32, 0:32, Domain:32>>).
