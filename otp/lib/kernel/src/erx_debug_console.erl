%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The native boot's console driver until the PL011's (docs/design-runtime.md, "The
%% console and standard I/O"): output only, through standard output and so the debug
%% log, in the driver's messages that erx_console documents. Nothing is ever read.

-module(erx_debug_console).

-export([start_link/1]).
-export([init/1]).

-spec start_link(Console :: pid()) -> {ok, pid(), Terminal :: boolean()}.
start_link(Console) ->
    proc_lib:start_link(?MODULE, init, [Console]).

-spec init(pid()) -> no_return().
init(Console) ->
    proc_lib:init_ack({ok, self(), false}),
    loop(Console).

loop(Console) ->
    receive
        {erx_console_output, From, Bytes} ->
            %% display_string takes characters and writes them as UTF-8 again, so bytes
            %% of a text leave as they came, and anything else as latin-1.
            Text = case unicode:characters_to_list(Bytes) of
                       Characters when is_list(Characters) -> Characters;
                       _ -> binary_to_list(Bytes)
                   end,
            true = erlang:display_string(stdout, Text),
            Console ! {erx_console_written, From},
            loop(Console);
        _Ignored ->
            loop(Console)
    end.
