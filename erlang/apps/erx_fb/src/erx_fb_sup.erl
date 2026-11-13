%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display domain's window system, driver and screen (docs/design-display.md, "The
%% display device", "Windows and the window system" and "The screen and its one path to
%% the device"), rest_for_one in that order. erx_winfs, the mint of the display's service
%% and the window table, comes first, so the service is named before the domain's ready
%% report; it is temporary and significant, and the supervisor shuts down when it ends
%% (auto_shutdown any_significant), which ends the domain. The service is the one the
%% domain's environment variable display names, which the domain service sets from the
%% display's manifest entry (docs/design-display.md, "A display's session"); with the
%% variable unset, empty or no service name, no window system starts. Then the virtio-gpu
%% driver erx_virtio_gpu over the domain's `gpu virtio_mmio` device record, registered
%% as erx_fb, then erx_screen over it. A driver's end restarts both, so the screen's
%% start, which repaints, follows each new bring-up of the device. Without a record
%% there is no driver or screen, and a driver whose start finds no device, or fails one
%% step, starts no process, after which erx_screen starts none either: a failure during
%% the bring-up leaves the domain without a screen. A record is the root's, from the
%% unit the manifest gives the domain, and a manifest gives a domain at most one, so
%% more than one record starts nothing, as no record does.
%%
%% erx_screen is a module of erx_display, a library application that starts no process,
%% so the driver's supervisor starts it behind the driver, and no screen runs before a
%% driver does.

-module(erx_fb_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
%% For the host test of the window system's start (test/erlang/erx_winfs_tests.erl).
-export([winfs/1]).

%% A driver or screen that ends a fourth time within a minute is not restarted: the
%% application, and with it the domain, ends.
-define(INTENSITY, 3).
-define(PERIOD_S, 60).
%% A service's name, an identifier (docs/design-system.md, "Identifiers"): 1 to this many bytes.
-define(SERVICE_NAME_MAX, 63).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Display = case erx_device_record:find(gpu, virtio_mmio) of
                   {ok, [Spec]} -> [driver(Spec), screen()];
                   {ok, [_, _ | _]} ->
                       _ = erx_log:debug(["erx_fb: more than one display device record"]),
                       [];
                   {ok, []} -> [];
                   {error, {bad_device_record, _Text}} ->
                       _ = erx_log:debug(["erx_fb: the display device record is malformed"]),
                       []
               end,
    {ok, {#{strategy => rest_for_one, intensity => ?INTENSITY, period => ?PERIOD_S,
            auto_shutdown => any_significant}, winfs(os:getenv("display")) ++ Display}}.

%% The window system's child for Display, the value of the domain's display variable: the
%% mint of the service it names, or none, with a debug line, when it names none. The
%% variable comes from the trusted manifest, a name of at most SERVICE_NAME_MAX bytes,
%% and is made an atom with list_to_atom/1, one atom per start of the domain: the
%% service's atom need not exist in the display domain before, so list_to_existing_atom/1
%% would refuse a real display's name.
-spec winfs(string() | false) -> [supervisor:child_spec()].
winfs(Display) when is_list(Display), Display =/= [], length(Display) =< ?SERVICE_NAME_MAX ->
    [#{id => erx_winfs,
       start => {erx_winfs, start_link, [list_to_atom(Display)]},
       restart => temporary,
       significant => true,
       shutdown => 2000,
       type => worker,
       modules => [erx_winfs, erx_window, erx_wm_single]}];
winfs(_Display) ->
    _ = erx_log:debug(["erx_fb: no display variable names the display's service; no window system"]),
    [].

driver(Spec) ->
    #{id => erx_fb,
      start => {erx_virtio_gpu, start_link, [Spec]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_virtio_gpu, erx_virtio_gpu_core]}.

screen() ->
    #{id => erx_screen,
      start => {erx_screen, start_link, [{erx_virtio_gpu, erx_fb}]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_screen, erx_screen_core]}.
