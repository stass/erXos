%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The display domain's driver and screen (docs/design-display.md, "The display device"
%% and "The screen and its one path to the device"), rest_for_one with the driver first:
%% the virtio-gpu driver erx_virtio_gpu over the domain's `gpu virtio_mmio` device record,
%% registered as erx_fb, then erx_screen over it. A driver's end restarts both, so the
%% screen's start, which repaints, follows each new bring-up of the device. Without a
%% record there are no children, and a driver whose start finds no device, or fails one
%% step, starts no process, after which erx_screen starts none either: a failure during
%% the bring-up leaves the domain without a screen. A record is the root's, from the
%% unit the manifest gives the domain, and a manifest gives a domain at most one, so
%% more than one record starts nothing, as no record does.
%%
%% erx_screen belongs to the display side of erx_display, which this release only loads,
%% so the driver's supervisor starts it while the split of erx_display into a client-side
%% and a display-side application is undecided (TODO.md, "The display domain: split
%% erlang/apps/erx_display").

-module(erx_fb_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%% A driver or screen that ends a fourth time within a minute is not restarted: the
%% application, and with it the domain, ends.
-define(INTENSITY, 3).
-define(PERIOD_S, 60).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = case erx_device_record:find(gpu, virtio_mmio) of
                   {ok, [Spec]} -> [driver(Spec), screen()];
                   {ok, [_, _ | _]} ->
                       _ = erx_log:debug(["erx_fb: more than one display device record"]),
                       [];
                   {ok, []} -> [];
                   {error, {bad_device_record, _Text}} ->
                       _ = erx_log:debug(["erx_fb: the display device record is malformed"]),
                       []
               end,
    {ok, {#{strategy => rest_for_one, intensity => ?INTENSITY, period => ?PERIOD_S}, Children}}.

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
