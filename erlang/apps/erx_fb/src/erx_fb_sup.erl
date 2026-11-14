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
%% variable unset, empty or no service name, no window system starts. The window system
%% runs the window manager of the policy the domain's display_policy variable names, a
%% member of mf_display_policy, which the manifest check holds it to; policy/1 maps each
%% member to its window manager and has no clause for anything else, so a member with no
%% window manager fails this supervisor's start. Then the display
%% driver, registered as erx_fb, then erx_screen over it: erx_virtio_gpu over the domain's
%% `gpu virtio_mmio` device record (QEMU virt), or erx_firmware_fb over its framebuffer
%% record, the framebuffer a board's firmware set up (the Raspberry Pi). A driver's end
%% restarts both, so the screen's start, which repaints, follows each new bring-up of the
%% device. Without a record there is no driver or screen, with one line in the kernel log,
%% and a driver whose start finds no device, or fails one step, starts no process, after
%% which erx_screen starts none either: a failure during the bring-up leaves the domain
%% without a screen. A record is the root's, from the unit the manifest gives the domain,
%% and a manifest gives a domain at most one display device, so more than one record, or a
%% malformed one, starts nothing, as no record does.
%%
%% Then one virtio-input driver for each of the domain's `input virtio_input` records, the
%% keyboard and the tablet on QEMU virt, each sending its device's records to the window
%% system (erx_virtio_input). They come last, so an input driver's end restarts only the
%% input drivers after it, never the display driver or the screen; its ends count toward
%% the supervisor's one restart intensity all the same (TODO.md). A malformed input record
%% starts no input driver, with one line in the kernel log; no record starts none, silently.
%%
%% erx_screen is a module of erx_display, a library application that starts no process,
%% so the driver's supervisor starts it behind the driver, and no screen runs before a
%% driver does.

-module(erx_fb_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).
%% For the host test of the window system's start (test/erlang/erx_winfs_tests.erl).
-export([winfs/2]).

-include("generated/erx_abi.hrl").

%% A driver or screen that ends a fourth time within a minute is not restarted: the
%% application, and with it the domain, ends.
-define(INTENSITY, 3).
-define(PERIOD_S, 60).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Display = display(erx_device_record:find(gpu, virtio_mmio), erx_device_record:framebuffers()),
    Winfs = winfs(os:getenv(binary_to_list(?ERX_DISPLAY_KEY_BYTES)),
                  os:getenv(binary_to_list(?ERX_DISPLAY_POLICY_KEY_BYTES))),
    Inputs = inputs(erx_device_record:find(input, virtio_input)),
    {ok, {#{strategy => rest_for_one, intensity => ?INTENSITY, period => ?PERIOD_S,
            auto_shutdown => any_significant}, Winfs ++ Display ++ Inputs}}.

%% The window system's child for Display and Policy, the values of the domain's display
%% and display_policy variables: the mint of the service Display names under Policy's
%% window manager, or none, with a debug line, when Display names no service. The
%% display variable comes from the trusted manifest, an identifier of at most
%% ERX_IDENTIFIER_MAX bytes, and is made an atom with list_to_atom/1, one atom per start
%% of the domain: the service's atom need not exist in the display domain before, so
%% list_to_existing_atom/1 would refuse a real display's name.
-spec winfs(string() | false, string() | false) -> [supervisor:child_spec()].
winfs(Display, Policy) when is_list(Display), Display =/= [], length(Display) =< ?ERX_IDENTIFIER_MAX ->
    {Wm, _} = Manager = policy(Policy),
    [#{id => erx_winfs,
       start => {erx_winfs, start_link, [list_to_atom(Display), Manager]},
       restart => temporary,
       significant => true,
       shutdown => 2000,
       type => worker,
       modules => [erx_winfs, erx_window, Wm]}];
winfs(_Display, _Policy) ->
    _ = erx_log:debug(["erx_fb: no display variable names the display's service; no window system"]),
    [].

%% The window manager and its configuration of each mf_display_policy member, by its name.
policy("single") -> {erx_wm_single, #{}}.

%% The driver and screen of the domain's display record, the virtio-gpu's or the firmware
%% framebuffer's, or none, with a line saying why.
display({ok, [Spec]}, {ok, []}) ->
    [driver(erx_virtio_gpu, Spec, [erx_virtio_gpu, erx_virtio_gpu_core]), screen(erx_virtio_gpu)];
display({ok, []}, {ok, [Record]}) ->
    [driver(erx_firmware_fb, Record, [erx_firmware_fb, erx_firmware_fb_core]), screen(erx_firmware_fb)];
display({ok, []}, {ok, []}) ->
    _ = erx_log:debug(["erx_fb: no display device record; no screen"]),
    [];
display({ok, _Gpus}, {ok, _Framebuffers}) ->
    _ = erx_log:debug(["erx_fb: more than one display device record"]),
    [];
display(_Gpus, _Framebuffers) ->
    _ = erx_log:debug(["erx_fb: the display device record is malformed"]),
    [].

%% One input driver for each input record, each child named by its record's path.
inputs({ok, Specs}) ->
    [#{id => {erx_virtio_input, Path},
       start => {erx_virtio_input, start_link, [Spec]},
       restart => permanent,
       shutdown => 2000,
       type => worker,
       modules => [erx_virtio_input, erx_virtio_input_core]} || #{path := Path} = Spec <- Specs];
inputs(_Malformed) ->
    _ = erx_log:debug(["erx_fb: an input device record is malformed; no input"]),
    [].

driver(Module, Record, Modules) ->
    #{id => erx_fb,
      start => {Module, start_link, [Record]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => Modules}.

screen(Driver) ->
    #{id => erx_screen,
      start => {erx_screen, start_link, [{Driver, erx_fb}]},
      restart => permanent,
      shutdown => 2000,
      type => worker,
      modules => [erx_screen, erx_screen_core]}.
