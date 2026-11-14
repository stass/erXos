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
%% runs the policy the domain's display_policy variable names, and single is the one
%% policy built: any other value, rio included, or none, is refused with one line in the
%% kernel log and starts no window system, so a display never boots a policy its manifest
%% did not name. Then the display
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
    {ok, {#{strategy => rest_for_one, intensity => ?INTENSITY, period => ?PERIOD_S,
            auto_shutdown => any_significant}, Winfs ++ Display}}.

%% The window system's child for Display and Policy, the values of the domain's display
%% and display_policy variables: the mint of the service Display names under the single
%% policy, or none, with a debug line, when Display names no service or Policy is not
%% single. The
%% variable comes from the trusted manifest, an identifier of at most ERX_IDENTIFIER_MAX bytes,
%% and is made an atom with list_to_atom/1, one atom per start of the domain: the
%% service's atom need not exist in the display domain before, so list_to_existing_atom/1
%% would refuse a real display's name.
-spec winfs(string() | false, string() | false) -> [supervisor:child_spec()].
winfs(Display, "single") when is_list(Display), Display =/= [], length(Display) =< ?ERX_IDENTIFIER_MAX ->
    [#{id => erx_winfs,
       start => {erx_winfs, start_link, [list_to_atom(Display)]},
       restart => temporary,
       significant => true,
       shutdown => 2000,
       type => worker,
       modules => [erx_winfs, erx_window, erx_wm_single]}];
winfs(Display, Policy) when is_list(Display), Display =/= [], length(Display) =< ?ERX_IDENTIFIER_MAX ->
    _ = erx_log:debug(["erx_fb: the display's policy ", policy_text(Policy),
                       " is not one this display domain has (single); no window system"]),
    [];
winfs(_Display, _Policy) ->
    _ = erx_log:debug(["erx_fb: no display variable names the display's service; no window system"]),
    [].

%% The policy's value as the log line shows it: the manifest's word, which the manifest
%% check holds to an mf_display_policy member, or unset.
policy_text(false) -> "unset";
policy_text(Policy) -> Policy.

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
