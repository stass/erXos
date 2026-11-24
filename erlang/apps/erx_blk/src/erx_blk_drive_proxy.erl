%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_blk_drive_proxy).
-moduledoc """
A window proxy (docs/design-drives.md, "How the grant reaches the media domain",
item 3): a process of the serving domain, started by a drive's facet
(erx_blk_drive_facet) for one `window` ask, that acts for the facet's grantee alone,
as every process a facet starts does (docs/design-domains.md, "Facets", "Processes a
facet starts").

It takes the facet's forward of the ask, and only the facet's, and asks the drive's
grant for the window. On `{ok, Window}` it monitors the window, exports itself toward
the grantee with `send` alone and answers `{ok, Proxy}`, its own pid; any other answer
it passes on and ends, and if the grant ends first the proxy ends with it, which the
facet answers `{error, failed}`.

From then it takes the window's requests, `{read, Sector, Count}`,
`{write, Sector, Bytes}`, `flush` and `info`, through the facet's admission path
(erx_facet:admitted/2): a call of the grantee's within `max_request`, whose reply goes
to a name of the grantee's, or it is dropped unanswered. A call that names none of
the four is answered `{error, einval}`, and one past `in_flight` requests forwarded and
unanswered `{error, busy}`. Each admitted request goes to its window, the one the
grant answered it, and to no other, and the window's answer goes back to its caller.

It ends when its window ends, when the facet ends, even while it waits on the grant's
answer, both of which it monitors, when the facet ends it for the next ask, or when it
passes the grant's `max_heap_size`, off-heap binaries counted; its end ends nothing of
the window or the medium. Its charge of the facet's
account and its pause while the share is spent wait on erx_facet's account
(docs/todo-storage.md, the erx_media item).
""".

-export([start/2]).

%% The facet's grant's limits, the grant record's alone, and the facet.
-type limits() :: #{grantee := pos_integer(), max_request := pos_integer(), in_flight := pos_integer(),
                    max_heap_size := pos_integer(), exports := module(), facet := pid()}.

-doc """
Starts a proxy of Grant's window for the facet and grantee Limits name, which waits
for the facet's forward of `window`, under the grant's `max_heap_size` in words.
Unlinked: the proxy monitors the facet instead.
""".
-spec start(pid(), limits()) -> pid().
start(Grant, #{facet := Facet, max_heap_size := Words} = Limits)
  when is_pid(Grant), is_pid(Facet), is_integer(Words), Words > 0 ->
    Heap = #{size => Words, kill => true, error_logger => false, include_shared_binaries => true},
    spawn_opt(fun() -> init(Grant, Limits) end, [{max_heap_size, Heap}]).

init(Grant, #{facet := Facet} = Limits) ->
    FacetMonitor = monitor(process, Facet),
    receive
        {'$gen_call', {Facet, _Tag} = From, window} ->
            window(Grant, From, Limits#{facet_monitor => FacetMonitor});
        {'DOWN', FacetMonitor, process, Facet, _Reason} ->
            exit(normal)
    end.

%% The grant's answer to the facet's ask passed on, and on a window the proxy serves it.
window(Grant, From, #{grantee := Grantee, exports := Exports} = Limits) ->
    case grant_answer(Grant, Limits) of
        {ok, Window} when is_pid(Window) ->
            WindowMonitor = monitor(process, Window),
            ok = Exports:export(self(), [send], Grantee),
            gen:reply(From, {ok, self()}),
            loop(Limits#{window => Window, window_monitor => WindowMonitor, outstanding => #{}});
        Answer ->
            gen:reply(From, Answer)
    end.

%% The grant's answer to `window`, waited on together with the facet's end: a grant
%% may hold the ask until a medium ends, and a facet that ends meanwhile, or a grant
%% that ends before it answers, ends the proxy unexported. The facet answers the
%% grant's end, as any forward's, `{error, failed}`.
grant_answer(Grant, #{facet_monitor := FacetMonitor}) ->
    Alias = monitor(process, Grant, [{alias, demonitor}]),
    Grant ! {'$gen_call', {self(), [alias | Alias]}, window},
    receive
        {[alias | Alias], Answer} ->
            demonitor(Alias, [flush]),
            Answer;
        {'DOWN', Alias, process, Grant, _Reason} ->
            exit(normal);
        {'DOWN', FacetMonitor, process, _Facet, _Reason} ->
            exit(normal)
    end.

loop(#{window := Window, window_monitor := WindowMonitor, facet_monitor := FacetMonitor,
       outstanding := Outstanding} = State) ->
    receive
        {[alias | Alias], Reply} when is_map_key(Alias, Outstanding) ->
            loop(replied(Alias, Reply, State));
        {'DOWN', Alias, process, Window, _Reason} when is_map_key(Alias, Outstanding) ->
            loop(replied(Alias, {error, failed}, State));
        {'DOWN', WindowMonitor, process, Window, _Reason} ->
            exit(normal);
        {'DOWN', FacetMonitor, process, _Facet, _Reason} ->
            exit(normal);
        Message ->
            loop(request(erx_facet:admitted(Message, State), State))
    end.

request({call, From, Request}, #{window := Window, in_flight := InFlight, outstanding := Outstanding} = State) ->
    case is_window_request(Request) of
        false ->
            gen:reply(From, {error, einval}),
            State;
        true when map_size(Outstanding) >= InFlight ->
            gen:reply(From, {error, busy}),
            State;
        true ->
            Alias = monitor(process, Window, [{alias, demonitor}]),
            Window ! {'$gen_call', {self(), [alias | Alias]}, Request},
            State#{outstanding := Outstanding#{Alias => From}}
    end;
%% A message in no call's shape, or one the admission path drops: no answer.
request(_Dropped, State) ->
    State.

replied(Alias, Reply, #{outstanding := Outstanding} = State) ->
    {From, Rest} = maps:take(Alias, Outstanding),
    demonitor(Alias, [flush]),
    gen:reply(From, Reply),
    State#{outstanding := Rest}.

%% The window's four requests (docs/design-storage.md, "Data model"); the window checks
%% their ranges.
is_window_request({read, Sector, Count}) -> is_integer(Sector) andalso is_integer(Count);
is_window_request({write, Sector, Bytes}) -> is_integer(Sector) andalso is_binary(Bytes);
is_window_request(flush) -> true;
is_window_request(info) -> true;
is_window_request(_Other) -> false.
