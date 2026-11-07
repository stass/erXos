%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The collision test of erXos's shell shortcuts (docs/design-live.md,
%% "Erlang, in every domain"), run on stock OTP's emulator. The shell's
%% commands come from stock's shell:local_func/0, which the shell matches
%% by name before it consults shell_default, and OTP's own shell_default
%% exports from stock's shell_default beam. erXos's shell_default and
%% edlin_expand are the beams in ERX_STDLIB_EBIN, compiled from
%% otp/lib/stdlib/src; the resolution test loads them in place of stock's for
%% its own run and loads stock's back after it, so the emulator runs with
%% -nostick.
-module(erx_shortcut_tests).
-include_lib("eunit/include/eunit.hrl").

%% The shortcuts this build exports, each over an erx function it has.
-define(SHORTCUTS, [{i, 1}, {source, 1}, {trace, 1}, {trace_stop, 1}]).
%% The design's other shortcuts: ps/0 and domains/0, whose erx functions come with the
%% inspector's domain listings, and attach/1, with sessions in their own domains (later
%% milestones of docs/plan.md). Their names are kept free.
-define(PENDING, [{ps, 0}, {domains, 0}, {attach, 1}]).
%% The modules of erXos's stdlib that the resolution test swaps in.
-define(SWAPPED, [shell_default, edlin_expand]).
%% Argument completion at the prompt, by name alone, of names stock knows or
%% leaves to the user: each must complete as on stock. A shortcut's own name,
%% such as source, completes to the shortcut's signature, which stock lacks.
-define(COMPLETIONS, ["trace(", "spawn(", "i(", "memory(", "self(", "ps(",
                      "erx_undefined_name("]).

shortcuts_collide_with_nothing_test() ->
    ?assertEqual([], collisions(?SHORTCUTS ++ ?PENDING, shell:local_func(), stock_exports())).

%% erXos's shell_default keeps all of OTP's exports and adds exactly the shortcuts
%% this build has, which its erx_shortcuts attribute lists for edlin_expand.
shell_default_adds_exactly_the_shortcuts_test() ->
    Ours = erxos_exports(),
    ?assertEqual([], stock_exports() -- Ours),
    ?assertEqual(lists:sort(?SHORTCUTS), lists:sort(Ours -- stock_exports())),
    ?assertEqual(lists:sort(?SHORTCUTS), lists:sort(erxos_shortcut_attribute())).

%% A function defined at the prompt has each of its calls resolved by
%% edlin_expand:shell_default_or_bif/2, by name and arity (shell.erl,
%% reconstruct1/3, and the check that refuses a definition), and argument
%% completion by edlin_expand:shell_default_or_bif/1, by name alone. Stock
%% resolves both by name alone. erXos's must answer as stock's does for every
%% name stock knows, at every arity, except a shortcut's own name and arity,
%% which erXos answers shell_default.
resolution_matches_stock_test() ->
    Names = names(),
    Arities = lists:seq(0, max_arity() + 1),
    Stock = [{Name, edlin_expand:shell_default_or_bif(Name)} || Name <- Names],
    StockCompletions = completions(),
    {OursByName, OursByArity, OursCompletions} =
        with_erxos_stdlib(
          fun() ->
                  {[{Name, edlin_expand:shell_default_or_bif(Name)} || Name <- Names],
                   [{{Name, Arity}, edlin_expand:shell_default_or_bif(Name, Arity)}
                    || Name <- Names, Arity <- Arities],
                   completions()}
          end),
    ?assertEqual(Stock, OursByName),
    ?assertEqual(StockCompletions, OursCompletions),
    Expected = [{{Name, Arity}, expected(Name, Arity, Answer)}
                || {Name, Answer} <- Stock, Arity <- Arities],
    ?assertEqual(Expected, OursByArity),
    %% The checks are not vacuous: trace/3 is erlang's, trace/1 the shortcut,
    %% and trace( completes to erlang:trace/3's arguments.
    ?assertEqual("erlang", proplists:get_value({trace, 3}, OursByArity)),
    ?assertEqual("shell_default", proplists:get_value({trace, 1}, OursByArity)),
    ?assertMatch({_, _, ["erlang:trace(" ++ _]}, proplists:get_value("trace(", OursCompletions)).

expected(Name, Arity, StockAnswer) ->
    case lists:member({Name, Arity}, ?SHORTCUTS) of
        true -> "shell_default";
        false -> StockAnswer
    end.

%% Every name the shell resolves specially: OTP's shell_default exports,
%% erlang's exports (auto-imported BIFs among them), the shell's commands,
%% the shortcuts and a name nothing defines.
names() ->
    lists:usort([Name || {Name, _} <- stock_exports() ++ erlang:module_info(exports)
                             ++ ?SHORTCUTS ++ ?PENDING]
                ++ shell:local_func() ++ [erx_undefined_name]).

max_arity() ->
    lists:max([Arity || {_, Arity} <- stock_exports() ++ erlang:module_info(exports)]).

completions() ->
    [{Line, edlin_expand:expand(lists:reverse(Line))} || Line <- ?COMPLETIONS].

with_erxos_stdlib(Fun) ->
    Ours = os:getenv("ERX_STDLIB_EBIN"),
    try
        lists:foreach(fun(Module) -> load(Ours, Module) end, ?SWAPPED),
        Fun()
    after
        lists:foreach(fun(Module) -> load(stock_ebin(), Module) end, ?SWAPPED)
    end.

load(Dir, Module) ->
    _ = code:purge(Module),
    {module, Module} = code:load_abs(filename:join(Dir, atom_to_list(Module))).

%% The check catches each kind of collision: a shell command's name at any
%% arity, and the name and arity of one of OTP's exports or of an
%% auto-imported BIF, which the prompt calls before shell_default.
collisions_are_caught_test() ->
    Commands = shell:local_func(),
    Stock = stock_exports(),
    ?assertEqual([{self, 0}], collisions([{self, 0}], Commands, Stock)),
    ?assertEqual([{h, 2}], collisions([{h, 2}], Commands, Stock)),
    ?assertEqual([{history, 0}], collisions([{history, 0}], Commands, Stock)),
    ?assertEqual([{i, 0}], collisions([{i, 0}, {i, 1}], Commands, Stock)),
    ?assertEqual([{i, 3}], collisions([{i, 3}], Commands, Stock)).

collisions(Shortcuts, Commands, Stock) ->
    [{Name, Arity} || {Name, Arity} <- Shortcuts,
                      lists:member(Name, Commands) orelse lists:member({Name, Arity}, Stock)
                          orelse erl_internal:bif(Name, Arity)].

stock_ebin() ->
    filename:join(code:lib_dir(stdlib), "ebin").

stock_exports() ->
    beam_exports(stock_ebin()).

erxos_exports() ->
    beam_exports(os:getenv("ERX_STDLIB_EBIN")).

beam_exports(Dir) ->
    {ok, {shell_default, [{exports, Exports}]}} =
        beam_lib:chunks(filename:join(Dir, "shell_default.beam"), [exports]),
    Exports -- [{module_info, 0}, {module_info, 1}].

erxos_shortcut_attribute() ->
    {ok, {shell_default, [{attributes, Attributes}]}} =
        beam_lib:chunks(filename:join(os:getenv("ERX_STDLIB_EBIN"), "shell_default.beam"),
                        [attributes]),
    [Shortcut || {erx_shortcuts, Shortcuts} <- Attributes, Shortcut <- Shortcuts].
