%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_drive_facet).
-moduledoc """
The erx_facet callback of a drive's facet (docs/design-drives.md, "How the grant
reaches the media domain", item 2): the one process of the serving domain that the
media domain's registry names `{drive, N}`. The mint, erx_blk_drive:start_mint/1,
starts it bound to the media domain's incarnation and ending with its connection. Its
interface lists one operation, `window`, and the behaviour refuses every other request
before admit/3 sees it, so the holder reaches neither the drive's grant nor another
drive: the facet is bound to one drive number, and the grant's own calls, occupy/2 and
serve/3, are no operation of the interface.

At each `window` the facet ends the proxy it has, if any, finds the drive's grant as it
is at that ask (the mint's Find), and starts a window proxy, erx_blk_drive_proxy, for
it, to which it forwards the ask; the proxy answers `{ok, Proxy}` or the grant's answer.
While the drive has no grant the facet answers `{error, no_medium}` and starts nothing.
It never keeps a grant's pid between asks, so a grant's restart changes nothing here.
It monitors the proxy it has, and ends it at the next ask only while the monitor stands,
so it never signals a pid that has ended. The proxy's limits are the grant record's,
which must name each of them: a grant without `max_heap_size` starts no facet, so no
proxy runs unbounded.
""".

-behaviour(erx_facet).

-export([init/1, admit/3, operation/1]).

-doc false.
init(#{find := Find, max_request := _, in_flight := _, max_heap_size := _} = Grant) when is_function(Find, 0) ->
    Limits = maps:with([grantee, exports, max_request, in_flight, max_heap_size], Grant),
    {ok, #{find => Find, proxy => none, limits => Limits}}.

-doc false.
operation(window) -> {ok, window};
operation(_Request) -> error.

-doc false.
admit(window, _From, #{find := Find, proxy := Proxy, limits := Limits} = State) ->
    ok = end_proxy(Proxy),
    case Find() of
        {ok, Grant} ->
            Next = erx_blk_drive_proxy:start(Grant, Limits#{facet => self()}),
            {forward, Next, window, State#{proxy := {Next, monitor(process, Next)}}};
        _NoGrant ->
            {reply, {error, no_medium}, State#{proxy := none}}
    end.

%% Ends the proxy of the ask before, unless its monitor has fired: a removed monitor says
%% the proxy was alive; the 'DOWN' of one that ended, the facet's loop drops.
end_proxy(none) ->
    ok;
end_proxy({Pid, Monitor}) ->
    _ = demonitor(Monitor, [info]) andalso exit(Pid, shutdown),
    ok.
