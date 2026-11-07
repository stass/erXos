%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_kernel_records' pure core over constructed reports (docs/design-live.md,
%% "Inspection tests"): one case per row of the collector's table, a partial
%% bit on an attribute with no stopgap, an attribute the layout has no field
%% for, a derived attribute over a partial input, and each kind of refusal,
%% ERX_ERANGE ending a listing among them. Each case is paired with a seed that
%% flips one bit or the status and must change the attribute.
-module(erx_kernel_records_tests).

-include_lib("eunit/include/eunit.hrl").
-include("../../erlang/apps/erx/include/generated/erx_abi.hrl").

-define(BUDGET_PATH, [domains, 4, budget]).
-define(KIND, ?ERX_INFO_BUDGET_REPORTED_KIND).
-define(GUARANTEE, ?ERX_INFO_BUDGET_REPORTED_GUARANTEE).
-define(CAP, ?ERX_INFO_BUDGET_REPORTED_CAP).
-define(USED, ?ERX_INFO_BUDGET_REPORTED_USED).
-define(CARVED, ?ERX_INFO_BUDGET_REPORTED_CARVED).
-define(LENT, ?ERX_INFO_BUDGET_REPORTED_LENT).

%% A budget report in erx_info_budget's layout: guarantee 100, cap 400,
%% used 30, carved 20, lent 10, threshold 0.
budget(Reported) ->
    <<0:32/little, Reported:32/little, 100:64/little, 400:64/little, 30:64/little,
      20:64/little, 10:64/little, 0:64/little>>.

budget_attr(Key, Answer, Partial) ->
    {ok, #{attrs := Attrs}} = erx_kernel_records:record(budget, ?BUDGET_PATH, 0, Answer, Partial),
    maps:get(Key, Attrs).

machine_attr(Key, Answer) ->
    {ok, #{attrs := Attrs}} = erx_kernel_records:record(machine, [], 0, Answer, 0),
    maps:get(Key, Attrs).

machine(CpusOnline, Reported) ->
    <<0:64, 0:32, CpusOnline:32/little, 0:64, 0:64, 0:64, 0:32, Reported:32/little>>.

reported_clear_partial_clear_is_unsupported_test() ->
    ?assertEqual({kernel, unsupported}, budget_attr(guarantee, {ok, budget(0)}, 0)),
    ?assertNotEqual({kernel, unsupported}, budget_attr(guarantee, {ok, budget(?GUARANTEE)}, 0)).

reported_set_partial_clear_is_ok_test() ->
    Reported = ?ERX_INFO_MACHINE_REPORTED_CPUS_ONLINE,
    ?assertEqual({kernel, {ok, 4}}, machine_attr(cpus_online, {ok, machine(4, Reported)})),
    ?assertEqual({kernel, unsupported}, machine_attr(cpus_online, {ok, machine(4, 0)})).

partial_set_reported_clear_is_the_stopgaps_test() ->
    ?assertEqual({{stopgap, liberx_pool}, {partial, 30}}, budget_attr(used, {ok, budget(0)}, ?USED)),
    ?assertEqual({kernel, unsupported}, budget_attr(used, {ok, budget(0)}, 0)).

both_bits_set_is_a_fault_test() ->
    ?assertEqual({kernel, {error, invalid}}, budget_attr(used, {ok, budget(?USED)}, ?USED)),
    ?assertEqual({kernel, {ok, 30}}, budget_attr(used, {ok, budget(?USED)}, 0)).

partial_bit_without_a_stopgap_is_a_fault_test() ->
    ?assertEqual({kernel, {error, invalid}}, budget_attr(guarantee, {ok, budget(0)}, ?GUARANTEE)),
    ?assertEqual({kernel, unsupported}, budget_attr(guarantee, {ok, budget(0)}, 0)).

attribute_without_a_field_is_unsupported_test() ->
    %% pinned is a kernel attribute erx_info_budget has no field for: no bit
    %% of either mask can make it anything but unsupported.
    ?assertEqual({kernel, unsupported}, budget_attr(pinned, {ok, budget(16#7f)}, 16#7f)),
    ?assertEqual({kernel, unsupported}, budget_attr(pinned, {ok, budget(0)}, 0)).

derived_over_a_partial_input_is_never_ok_test() ->
    Exact = ?USED bor ?CARVED bor ?LENT,
    ?assertEqual({kernel, {ok, 60}}, budget_attr(spending, {ok, budget(Exact)}, 0)),
    ?assertEqual({{stopgap, liberx_pool}, unknown},
                 budget_attr(spending, {ok, budget(?CARVED bor ?LENT)}, ?USED)),
    ?assertEqual({kernel, unsupported}, budget_attr(spending, {ok, budget(?CARVED)}, ?USED)).

derived_values_never_wrap_test() ->
    All = ?KIND bor ?GUARANTEE bor ?CAP bor ?USED bor ?CARVED bor ?LENT,
    Over = <<0:32/little, All:32/little, 100:64/little, 40:64/little, 30:64/little,
             20:64/little, 10:64/little, 0:64/little>>,
    ?assertEqual({kernel, {ok, 0}}, budget_attr(room, {ok, Over}, 0)),
    ?assertEqual({kernel, {ok, 20}}, budget_attr(deficit, {ok, Over}, 0)),
    ?assertEqual({kernel, {ok, 0}}, budget_attr(borrowing, {ok, Over}, 0)),
    %% give_back needs pinned, which no report carries.
    ?assertEqual({kernel, unsupported}, budget_attr(give_back, {ok, Over}, 0)).

enotsup_makes_every_attribute_unsupported_test() ->
    {ok, #{attrs := Attrs}} = erx_kernel_records:record(budget, ?BUDGET_PATH, 0, {error, ?ERX_ENOTSUP}, ?USED),
    ?assertEqual([{kernel, unsupported}], lists:usort(maps:values(Attrs))),
    ?assertNotEqual({kernel, unsupported}, budget_attr(used, {error, ?ERX_EINVAL}, ?USED)).

other_refusal_is_an_error_named_by_status_test() ->
    ?assertEqual({kernel, {error, einval}}, budget_attr(used, {error, ?ERX_EINVAL}, ?USED)),
    ?assertEqual({kernel, {error, estale}}, budget_attr(used, {error, ?ERX_ESTALE}, ?USED)),
    ?assertEqual({kernel, {error, invalid}}, budget_attr(used, {error, -9999}, ?USED)).

a_short_report_is_invalid_test() ->
    <<Short:55/binary, _/binary>> = budget(?USED),
    ?assertEqual({kernel, {error, invalid}}, budget_attr(used, {ok, Short}, 0)).

erange_ends_a_listing_test() ->
    Thread = fun(Id) -> {ok, <<Id:64/little, 0:32, 0:32, 0:32/little, 0:32>>} end,
    Answers = fun(Index) when Index < 3 -> Thread(Index * 2 + 10);
                 (_) -> {error, ?ERX_ERANGE}
              end,
    {ok, Records} = erx_kernel_records:listing(thread, Answers, 0, 128),
    %% A thread's id and path are the report's id, not the listing's index.
    ?assertEqual([{[domains, 4, threads, 10], 10}, {[domains, 4, threads, 12], 12},
                  {[domains, 4, threads, 14], 14}],
                 [{Path, Id} || #{path := Path, id := Id} <- Records]),
    ?assertEqual([{kernel, unsupported}], lists:usort([Attr || #{attrs := Attrs} <- Records,
                                                              Attr <- maps:values(Attrs)])),
    %% The seed: an ERX_ENOTSUP where ERX_ERANGE stood ends the listing
    %% short, and makes no record for the index it refused.
    Refusing = fun(Index) when Index < 3 -> Thread(Index + 10);
                  (_) -> {error, ?ERX_ENOTSUP}
               end,
    ?assertMatch({partial, [_, _, _]}, erx_kernel_records:listing(thread, Refusing, 0, 128)),
    ?assertMatch({partial, [_, _]}, erx_kernel_records:listing(thread, Answers, 0, 2)).

cpu_listing_paths_test() ->
    Cpu = fun(0) -> {ok, <<0:(288 * 8)>>};
             (_) -> {error, ?ERX_ERANGE}
          end,
    ?assertMatch({ok, [#{path := [cpus, 0], kind := cpu}]}, erx_kernel_records:listing(cpu, Cpu, 0, 64)),
    ?assertMatch({partial, []}, erx_kernel_records:listing(cpu, fun(_) -> {error, ?ERX_ENOTSUP} end, 0, 64)).

every_record_validates_test() ->
    ?assertMatch({ok, #{kind := group}},
                 erx_kernel_records:record(group, [domains, 4, group], 0,
                                           {ok, <<5:64/little, 0:64, 0:32, 1:32/little, 2:32/little,
                                                  25:32/little>>}, 0)).
