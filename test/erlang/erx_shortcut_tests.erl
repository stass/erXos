%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The collision test of erXos's shell shortcuts (docs/design-live.md,
%% "Erlang, in every domain"), run on stock OTP's emulator. The shell's
%% commands come from stock's shell:local_func/0, which the shell matches
%% by name before it consults shell_default, and OTP's own shell_default
%% exports from stock's shell_default; erXos's shell_default is the beam
%% at ERX_SHELL_DEFAULT_BEAM, compiled from otp/lib/stdlib/src.
-module(erx_shortcut_tests).
-include_lib("eunit/include/eunit.hrl").

%% The shortcuts this build exports, each over an erx function it has.
-define(SHORTCUTS, [{i, 1}, {source, 1}, {trace, 1}, {trace_stop, 1}]).
%% The design's other shortcuts, whose erx functions come with later milestones of
%% docs/plan.md: ps/0 and domains/0 with the inspector's domain listings, attach/1
%% with sessions in their own domains. Their names are kept free already.
-define(PENDING, [{ps, 0}, {domains, 0}, {attach, 1}]).

shortcuts_collide_with_nothing_test() ->
    ?assertEqual([], collisions(?SHORTCUTS ++ ?PENDING, shell:local_func(), stock_exports())).

%% erXos's shell_default keeps all of OTP's exports and adds exactly the shortcuts
%% this build has.
shell_default_adds_exactly_the_shortcuts_test() ->
    Ours = erxos_exports(),
    ?assertEqual([], stock_exports() -- Ours),
    ?assertEqual(lists:sort(?SHORTCUTS), lists:sort(Ours -- stock_exports())).

%% The check catches each kind of collision: a shell command's name at any
%% arity, and the name and arity of one of OTP's exports.
collisions_are_caught_test() ->
    Commands = shell:local_func(),
    Stock = stock_exports(),
    ?assertEqual([{h, 2}], collisions([{h, 2}], Commands, Stock)),
    ?assertEqual([{history, 0}], collisions([{history, 0}], Commands, Stock)),
    ?assertEqual([{i, 0}], collisions([{i, 0}, {i, 1}], Commands, Stock)),
    ?assertEqual([{i, 3}], collisions([{i, 3}], Commands, Stock)).

collisions(Shortcuts, Commands, Stock) ->
    [{Name, Arity} || {Name, Arity} <- Shortcuts,
                      lists:member(Name, Commands) orelse lists:member({Name, Arity}, Stock)].

stock_exports() ->
    shell_default:module_info(exports) -- [{module_info, 0}, {module_info, 1}].

erxos_exports() ->
    {ok, {shell_default, [{exports, Exports}]}} =
        beam_lib:chunks(os:getenv("ERX_SHELL_DEFAULT_BEAM"), [exports]),
    Exports -- [{module_info, 0}, {module_info, 1}].
