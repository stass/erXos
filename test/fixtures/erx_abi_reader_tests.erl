%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_abi_reader_tests).
-moduledoc "Stock-OTP tests and byte-only inspection of generated ABI readers.".
-include_lib("eunit/include/eunit.hrl").
-include("erx_abi.hrl").
-export([run/0, inspect/0, fuzz/0]).

-doc "Run the independent byte-fixture tests in the host oracle VM.".
-spec run() -> no_return().
run() ->
    verify_oracle(),
    case eunit:test(?MODULE, [verbose]) of
        ok -> halt(0);
        error -> halt(1)
    end.

-doc "Print a bounded JSON projection with binary data represented as hex.".
-spec inspect() -> no_return().
inspect() ->
    verify_oracle(),
    [Path] = init:get_plain_arguments(),
    {ok, Bytes} = file:read_file(Path),
    Result = case erx_manifest:read(Bytes) of
        {ok, View} ->
            {ok, Header} = erx_manifest:header(View),
            {ok, Principal} = erx_manifest:fetch(View, principals, 0),
            {ok, Name} = erx_manifest:string(View, maps:get(name, Principal)),
            #{status => <<"ok">>, header => Header, principal => Principal,
              principal_name => Name};
        {error, Error} ->
            #{status => <<"error">>, error => Error}
    end,
    io:put_chars(json:encode(json_value(Result))),
    io:put_chars("\n"),
    halt(0).

-doc "Exercise production open/fetch paths over a deterministic mutation corpus.".
-spec fuzz() -> no_return().
fuzz() ->
    verify_oracle(),
    [Directory] = init:get_plain_arguments(),
    Files = lists:sort(filelib:wildcard(filename:join(Directory, "*.bin"))),
    case Files of [] -> halt(2); _ -> ok end,
    try
        lists:foreach(fun(Path) ->
            {ok, Bytes} = file:read_file(Path),
            case erx_manifest:fuzz(Bytes) of
                {ok, View} ->
                    {ok, _} = erx_manifest:header(View),
                    {ok, _} = erx_manifest:count(View, principals),
                    {error, _} = erx_manifest:fetch(View, principals, -1);
                {error, #{reason := Reason, field := Field, offset := Offset}}
                  when is_atom(Reason), is_binary(Field), is_integer(Offset) ->
                    ok
            end
        end, Files),
        io:format("checked ~B reader inputs~n", [length(Files)]),
        halt(0)
    catch
        Class:_Reason:_Stacktrace ->
            %% Do not render malformed input through an exception argument list.
            io:format("reader implementation exception: ~p~n", [Class]),
            halt(1)
    end.

verify_oracle() ->
    Release = erlang:system_info(otp_release),
    Path = filename:join([code:root_dir(), "releases", Release, "OTP_VERSION"]),
    {ok, Version} = file:read_file(Path),
    <<"29.1.2">> = string:trim(Version),
    jit = erlang:system_info(emu_flavor),
    ok.

fixture() ->
    fixture("valid.bin").

fixture(Name) ->
    [Directory] = init:get_plain_arguments(),
    {ok, Bytes} = file:read_file(filename:join(Directory, Name)),
    Bytes.

set_u16(Bytes, Offset, Value) ->
    <<Before:Offset/binary, _:16, After/binary>> = Bytes,
    <<Before/binary, Value:16/little-unsigned, After/binary>>.

set_u32(Bytes, Offset, Value) ->
    <<Before:Offset/binary, _:32, After/binary>> = Bytes,
    <<Before/binary, Value:32/little-unsigned, After/binary>>.

complete_fixture_test() ->
    ?assertEqual(1, ?ERX_ABI_VERSION),
    ?assertEqual(376, ?ERX_MANIFEST_SIZE),
    ?assertEqual((1 bsl 64) - 1, ?ERX_TIME_PAGE_SEQ_TERMINAL),
    ?assertEqual(-7, ?ERX_TIME_PAGE_SEQ_EXHAUSTION),
    {ok, View} = erx_manifest:open(fixture()),
    {ok, Header} = erx_manifest:header(View),
    ?assertEqual(3, maps:get(flags, Header)),
    ?assertEqual({ok, 1}, erx_manifest:count(View, principals)),
    ?assertEqual({ok, 0}, erx_manifest:count(View, partial_boot)),
    {ok, Principal} = erx_manifest:fetch(View, principals, 0),
    ?assertEqual({ok, <<"root">>}, erx_manifest:string(View, maps:get(name, Principal))),
    ?assertEqual({ok, 1}, erx_manifest:fold(View, principals,
                                         fun(_Row, Count) -> Count + 1 end, 0)).

unknown_lookup_test() ->
    {ok, View} = erx_manifest:open(fixture()),
    ?assertMatch({error, #{reason := unknown_table}}, erx_manifest:count(View, absent)),
    ?assertMatch({error, #{reason := index}}, erx_manifest:fetch(View, principals, 1)),
    ?assertMatch({error, #{reason := view}}, erx_manifest:header(not_a_view)),
    ?assertMatch({error, #{reason := string_range}},
                 erx_manifest:string(View, #{offset => 16#ffffffff, length => 1})).

length_and_flag_errors_test() ->
    Bytes = fixture(),
    ?assertMatch({error, #{reason := length, field := <<"root.length">>}},
                 erx_manifest:read(set_u32(Bytes, 8, byte_size(Bytes) - 1))),
    ?assertMatch({error, #{reason := flags, field := <<"root.flags">>}},
                 erx_manifest:read(set_u16(Bytes, 6, 2))),
    ?assertMatch({error, #{reason := value, field := <<"root.version">>}},
                 erx_manifest:read(set_u16(Bytes, 4, 2))).

all_prefix_truncations_test() ->
    Bytes = fixture(),
    lists:foreach(fun(Length) ->
        ?assertMatch({error, _}, erx_manifest:read(binary:part(Bytes, 0, Length)))
    end, lists:seq(0, byte_size(Bytes) - 1)).

references_and_inactive_payload_test() ->
    Bytes = fixture(),
    ?assertMatch({error, #{reason := string_range,
                          field := <<"principals[].name.offset">>}},
                 erx_manifest:read(set_u32(Bytes, 376, 16#ffffffff))),
    ?assertMatch({error, #{reason := inactive, field := <<"limits[].spaces">>}},
                 erx_manifest:read(set_u32(Bytes, 528, 1))),
    ?assertMatch({error, #{reason := index, field := <<"root.native_limits">>}},
                 erx_manifest:read(set_u32(Bytes, 204, 1))).

callback_exceptions_are_not_parse_failures_test() ->
    {ok, View} = erx_manifest:open(fixture()),
    ?assertThrow({abi_error, callback_abort, <<"callback">>, 0},
                  erx_manifest:fold(View, principals,
                      fun(_, _) -> throw({abi_error, callback_abort, <<"callback">>, 0}) end,
                      undefined)).

input_names_do_not_create_atoms_test() ->
    Bytes = fixture(),
    _ = erx_manifest:read(Bytes),
    Bad = set_u32(Bytes, 0, 0),
    _ = erx_manifest:read(Bad),
    Before = erlang:system_info(atom_count),
    lists:foreach(fun(_) ->
        {ok, _} = erx_manifest:read(Bytes),
        {error, _} = erx_manifest:read(Bad)
    end, lists:seq(1, 100)),
    ?assertEqual(Before, erlang:system_info(atom_count)).

ordered_partition_test() ->
    {ok, _} = erx_manifest:read(fixture("partition_valid.bin")),
    ?assertMatch({error, #{reason := partition,
                          field := <<"units[].devices.offset">>}},
                 erx_manifest:read(fixture("partition_overlap.bin"))),
    ?assertMatch({error, #{reason := partition}},
                 erx_manifest:read(fixture("partition_gap.bin"))),
    ?assertMatch({error, #{reason := partition}},
                 erx_manifest:read(fixture("partition_orphan.bin"))).

tagged_parameter_checks_test() ->
    {ok, _} = erx_manifest:read(fixture("bool_valid.bin")),
    ?assertMatch({error, #{reason := range,
                          field := <<"facet_parameters[].scalar">>}},
                 erx_manifest:read(fixture("bool_invalid.bin"))),
    {ok, _} = erx_manifest:read(fixture("domain_valid.bin")),
    ?assertMatch({error, #{reason := index,
                          field := <<"facet_parameters[].index">>}},
                 erx_manifest:read(fixture("domain_invalid.bin"))),
    {ok, _} = erx_manifest:read(fixture("name_valid.bin")),
    ?assertMatch({error, #{reason := string_class}},
                 erx_manifest:read(fixture("name_invalid.bin"))),
    {ok, _} = erx_manifest:read(fixture("path_valid.bin")),
    ?assertMatch({error, #{reason := string_class}},
                 erx_manifest:read(fixture("path_invalid.bin"))),
    {ok, _} = erx_manifest:read(fixture("opaque_bytes.bin")).

json_value(Value) when is_map(Value) ->
    maps:from_list([{atom_to_binary(Key, utf8), json_value(Item)}
                   || {Key, Item} <- maps:to_list(Value)]);
json_value(Value) when is_binary(Value) ->
    #{<<"bytes">> => hex(Value)};
json_value(Value) when is_list(Value) ->
    [json_value(Item) || Item <- Value];
json_value(Value) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
json_value(Value) when is_integer(Value) -> Value.

hex(Bytes) ->
    << <<(hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
       || <<Byte>> <= Bytes >>.

hex_digit(Value) when Value < 10 -> $0 + Value;
hex_digit(Value) -> $a + Value - 10.
