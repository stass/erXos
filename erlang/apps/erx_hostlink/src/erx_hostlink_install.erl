%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_install).

-moduledoc """
The install facet the host link's root opens for the host
(docs/design-live.md, "Code from the host"): a process whose calls are the
code service's requests, handed to `erx_code:call/1` as the host sent them,
so erx_code_store's reader is the one check of their shape.

A facet is a process so that the session's table can name it, monitor it
and close it: one session's facets die with the session, and each ends with
the host link's process, which it monitors, so none outlives the link that
handed it out. It takes no casts. Its calls arrive as erx_hostlink's
`facet_call/2` sends them, and it always answers, within the code service's
own deadline (erx_code:call/1).
""".

-export([start/1]).
-export([init/1]).

-doc "Starts a facet that ends when `Link` does.".
-spec start(pid()) -> {ok, pid()}.
start(Link) ->
    proc_lib:start(?MODULE, init, [Link]).

-doc false.
-spec init(pid()) -> no_return().
init(Link) ->
    Watch = erlang:monitor(process, Link),
    proc_lib:init_ack({ok, self()}),
    loop(Watch).

loop(Watch) ->
    receive
        {hostlink_call, From, Ref, Request} ->
            From ! {Ref, serve(Request)},
            loop(Watch);
        {'DOWN', Watch, process, _Link, _Reason} ->
            exit(shutdown);
        _Other ->
            loop(Watch)
    end.

%% erx_code's answer, or {error, unknown} when the service did not answer
%% within its deadline or ended: a load may then have happened or not.
serve(Request) ->
    try
        erx_code:call(Request)
    catch
        exit:_ -> {error, unknown}
    end.
