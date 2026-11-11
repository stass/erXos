%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erx_devices hands on the boot view's catalogue unchanged: the same entries, in
%% the library's order (here not sorted by index, so a sort would show), and the
%% library's error as it came.
-module(erx_devices_tests).

-include_lib("eunit/include/eunit.hrl").

catalogue_is_the_views_unchanged_test() ->
    Entries = [#{index => 3, unit => 1, row => 0, role => net, holder => 5},
               #{index => 0, unit => 0, row => system, role => block, holder => system},
               #{index => 1, unit => 2, row => 1, role => none, holder => none}],
    ?assertEqual({ok, Entries}, erx_devices:catalogue(fun() -> {ok, Entries} end)),
    ?assertEqual({ok, []}, erx_devices:catalogue(fun() -> {ok, []} end)).

catalogue_passes_the_librarys_error_test() ->
    ?assertEqual({error, enotsup}, erx_devices:catalogue(fun() -> {error, enotsup} end)).
