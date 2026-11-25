%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The warm-up of a fuzz target that counts atoms. A round must make no atom, and loading
%% a module makes some, so a target loads the modules its rounds can reach before the
%% first round: erx_fuzz_warm:closure(?MODULE) loads the target, the module it tests and
%% every module a remote call in either names, and every module those name in turn. What
%% a module calls is read from the imports of its compiled file, so the set follows the
%% code and the target keeps no list of its own. A module with no file to load (one the
%% fuzz driver did not compile) is left to fail with undef in the round that calls it,
%% which names it. A module reached only through a literal fun M:F/A is not in the
%% imports and is not followed.

-module(erx_fuzz_warm).
-export([closure/1]).

-spec closure(module()) -> ok.
closure(Module) ->
    {module, Module} = code:ensure_loaded(Module),
    load(imports(Module), #{Module => true}).

load([], _Loaded) ->
    ok;
load([Module | Rest], Loaded) when is_map_key(Module, Loaded) ->
    load(Rest, Loaded);
load([Module | Rest], Loaded) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> load(imports(Module) ++ Rest, Loaded#{Module => true});
        {error, _} -> load(Rest, Loaded#{Module => true})
    end.

%% The modules the compiled file of Module calls; a preloaded module has no file to read.
imports(Module) ->
    case code:which(Module) of
        File when is_list(File) ->
            {ok, {Module, [{imports, Calls}]}} = beam_lib:chunks(File, [imports]),
            lists:usort([Callee || {Callee, _Function, _Arity} <- Calls]);
        _Preloaded ->
            []
    end.
