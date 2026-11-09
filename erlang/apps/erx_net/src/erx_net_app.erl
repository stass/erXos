%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_app).
-moduledoc """
The application's start (docs/design-network-stack.md, "Two places, four seams"): the
stack's supervisor over the application's keys.

* `interfaces`: the interfaces, a list as erx_net_sup takes it, or a `{Module, Function,
  Args}` called once at start that returns that list, for a node whose interfaces are
  found at boot, as erXos's are by `{erx_virtio_net, interfaces, []}`. A module the build
  does not hold stops the start with `{error, {seam, interfaces, Module}}`. None when
  absent.
* `clock`: `monotonic` when absent.
* `runtime`: the runtime seam's module, `erx_net_local` when absent.
""".

-behaviour(application).

-export([start/2, stop/1]).

-doc false.
start(_Type, _Args) ->
    maybe
        {ok, Interfaces} ?= interfaces(application:get_env(erx_net, interfaces, [])),
        Config = #{interfaces => Interfaces,
                   clock => application:get_env(erx_net, clock, monotonic),
                   runtime => application:get_env(erx_net, runtime, erx_net_local)},
        erx_net_sup:start_link(Config)
    end.

-doc false.
stop(_State) ->
    ok.

interfaces(List) when is_list(List) ->
    {ok, List};
interfaces({Module, Function, Args}) when is_atom(Module), is_atom(Function), is_list(Args) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> {ok, apply(Module, Function, Args)};
        {error, _} -> {error, {seam, interfaces, Module}}
    end;
interfaces(Other) ->
    {error, {interfaces, Other}}.
