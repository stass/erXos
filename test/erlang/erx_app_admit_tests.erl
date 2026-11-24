%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_app_admit_tests).
-moduledoc """
EUnit cases of admission, `erx_app_admit` (docs/design-packaging.md,
"Admission"). The package files come from test/host/erx_app_admit_test.rb,
which writes them through the ABI codec into the directory `ERX_ADMIT_CASES`
names: each case's first bytes in NAME.bin, and cases.term,
`{Name, Length, Signer, Context, Expected}` for each. A case decodes its file
through `erx_pkg_header:decode/2`, names the signer the file check would,
and admits the header against the manifest and registry `Context` names.
An admitted package carries that signer, so `Expected` leaves it out and the
case adds it.
""".

-include_lib("eunit/include/eunit.hrl").
-include("generated/erx_abi.hrl").

-define(MIB, 1048576).

admission_test_() ->
    Directory = os:getenv("ERX_ADMIT_CASES"),
    {ok, Cases} = file:consult(filename:join(Directory, "cases.term")),
    [{Name, fun() -> check_case(Directory, Name, Length, Signer, Context, Expected) end}
     || {Name, Length, Signer, Context, Expected} <- Cases].

check_case(Directory, Name, Length, Signer, Context, Expected) ->
    {ok, Bytes} = file:read_file(filename:join(Directory, Name ++ ".bin")),
    {ok, Decoded} = erx_pkg_header:decode(Length, Bytes),
    Answer = case Expected of
                 {ok, Admitted} -> {ok, Admitted#{signer => Signer}};
                 {error, _} -> Expected
             end,
    ?assertEqual(Answer, erx_app_admit:admit(checked(Decoded, Signer), manifest(Context),
                                             registry(Context), held(Context))).

%% The file check's answer for a header and its signer, with the two fields
%% admission does not read, the header's SHA-256 and extent, left out.
checked(Header, Signer) ->
    #{header => Header, signer => Signer}.

%% The facts of a manifest whose apps row offers two windows services and
%% one data service to at most four apps sharing 128 MiB, whose template's
%% ble row offers the GATT services hrm and nus, and whose image carries the
%% package kiosk; with no_ble, the row offers no ble. The row indices are those
%% test/host/erx_app_admit_test.rb names: packages 7, display 8, data 9,
%% panel 10, system 11 and ble 12. Its system principal is system, as the shipped manifests'.
manifest(no_apps) ->
    (manifest(base))#{apps := none};
manifest(no_ble) ->
    #{apps := Apps} = Manifest = manifest(base),
    Manifest#{apps := Apps#{ble := none}};
manifest(_) ->
    #{apps => #{memory => 128 * ?MIB, max => 4, packages_row => 7, system_row => 11,
                services => [#{name => <<"display">>, windows => true, row => 8},
                             #{name => <<"data">>, windows => false, row => 9},
                             #{name => <<"panel">>, windows => true, row => 10}],
                ble => #{row => 12, gatt => [<<"hrm">>, <<"nus">>]}},
      reserved => [<<"system">>, <<"alice">>, <<"storage">>, <<"display">>,
                   <<"data">>, <<"panel">>, <<"net">>, <<"files">>],
      packages => [<<"kiosk">>]}.

%% The boot's app principals: clock and chess, installed by the signer
%% vendor, in entries 0 and 2; and, when full, every entry held.
registry(full) ->
    maps:merge(registry(base),
               #{<<"kiosk">> => #{entry => 1, signer => image},
                 <<"notes">> => #{entry => 3, signer => development}});
registry(_) ->
    #{<<"clock">> => #{entry => 0, signer => <<"vendor">>},
      <<"chess">> => #{entry => 2, signer => <<"vendor">>}}.

%% The GATT services the admitted packages hold: clock's package holds hrm.
%% chess, which the registry holds, holds none, as a removed app's package
%% holds nothing, whatever the registry keeps.
held(_) ->
    #{<<"clock">> => [<<"hrm">>]}.

%% The entry rule registration takes its entry by: a new name takes the
%% lowest entry no name holds, below a held one too; a held name keeps its own.
entry_rule_test_() ->
    [?_assertEqual({ok, 1}, erx_app_admit:entry(<<"notes">>, development, 4, registry(base))),
     ?_assertEqual({ok, 2}, erx_app_admit:entry(<<"chess">>, <<"vendor">>, 4, registry(base)))].

%% Check 5 refuses a declared memory that is not a whole number of pages,
%% which the domain library's plan of the app's session would refuse.
unaligned_memory_test_() ->
    Header = #{name => <<"pager">>, abi_version => ?ERX_ABI_VERSION,
               arch => ?ERX_ARCH_MACHINE_ARCH_BYTES, needs => [], gatt => []},
    Admit = fun(Memory) ->
                    erx_app_admit:admit(checked(Header#{memory => Memory}, development),
                                        manifest(base), registry(base), held(base))
            end,
    [?_assertEqual({error, {memory, 64 * ?MIB + 1}}, Admit(64 * ?MIB + 1)),
     ?_assertEqual({error, {memory, 64 * ?MIB + ?ERX_PAGE_SIZE div 2}},
                   Admit(64 * ?MIB + ?ERX_PAGE_SIZE div 2)),
     ?_assertMatch({ok, #{memory := Memory}} when Memory =:= 64 * ?MIB + ?ERX_PAGE_SIZE,
                   Admit(64 * ?MIB + ?ERX_PAGE_SIZE))].

%% Names that are no identifier, each refused by check 3 whatever its
%% length. The package reader refuses them in a file (its name field is an
%% identifier), so these headers are written here rather than decoded.
bad_names_test_() ->
    Header = #{abi_version => ?ERX_ABI_VERSION, arch => ?ERX_ARCH_MACHINE_ARCH_BYTES,
               memory => 64 * ?MIB, needs => [], gatt => []},
    [?_assertEqual({error, {bad_name, Name}},
                   erx_app_admit:admit(checked(Header#{name => Name}, development),
                                       manifest(base), registry(base), held(base)))
     || Name <- [<<"Clock">>, <<"a/b">>, <<"a.b">>, <<"-ab">>, <<"_ab">>, <<"a", 1, "b">>, <<>>]].
