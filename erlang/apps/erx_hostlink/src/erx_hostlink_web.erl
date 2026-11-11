%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_hostlink_web).

-moduledoc """
The `web` facet the host link's root opens for the host tool's front end
(docs/design-web.md, "The host tool's front end"): it relays the browser
connections `tools/erx web` carries to the web domain, which runs a
connection core for each, and relays what the web domain sends back to the
host. The system domain decodes no protocol message: bytes pass through in
both directions.

The host's calls are `{connect, C}`, `{data, C, Bytes}` and `{close, C}`,
for a connection number `C` the host chose. The facet hands each to the web
domain's relay, the facet `web` the system domain holds of the web domain's
service (erx_web_relay), as a call made from this process; a connect also
names whose connection it is, `root`'s in a development build, as `erx
console` reaches it, and the machine's build, which the connection's
`welcome` reports (docs/design-web.md, "Logging in and the line"). As the
caller, this process is the connection's sink: the web domain
sends it, for connection `C`, `{web, C, Bytes}` for each message to the browser and
`{web_closed, C, Reason}` when the connection ends. Those arrive in the
envelope of the web domain, and are handed to the host link's process as
casts on this facet's number (erx_hostlink_session, "Facet casts"). A
message of any other shape or domain is dropped.

The web domain parses a browser's bytes, so what it sends is checked here
before the host sees it: a connection number within u32, bytes within the
protocol's message limit and a reason that is an atom (cast_of/2). A reply
of the relay is passed on only as `ok` or `{error, Atom}`.

Calls are taken one at a time in the order the host link's workers hand them
over, and the host waits for each reply before its next call on a
connection, so a connection's messages reach the web domain in order.

The facet ends with the host link's process, as the install facet does, and
with the web domain's relay: a web domain that ended took its connections
with it, and the host opens the facet again.
""".

-export([open/1, open/4, start/4, cast_of/2]).
-export([init/4]).

-include("generated/erx_abi.hrl").

%% How long a call on the relay may take. The relay only starts, feeds or
%% stops a connection's process, so this is a bound on a stuck web domain.
-define(RELAY_MS, 5000).
-define(U32_MAX, 16#FFFFFFFF).
%% The principal whose session a development build's host front end reaches:
%% the system principal, whose sessions are root's (docs/design-domains.md,
%% "Principals, sessions and quotas").
-define(PRINCIPAL, <<"root">>).

-type line() :: #{principal := binary(), build := binary()}.

-doc """
The root's answer to `{open, web}`, with the facets it opened. The facet
opens, and ends with `Link`, when all three hold:

* the system manifest's development flag is set, since the host's front
  end logs every browser in as `root`, which only a development build's
  host may do (docs/design-web.md, "The host tool's front end");
* this domain holds the web domain's relay, the facet of service `web`
  that the manifest grants the system domain where it configures a web
  domain;
* the build's identifier is known, for the connections' `welcome`.

Otherwise, a release build or a manifest that cannot be read included,
the answer is `{error, unsupported}` and no facet starts.
""".
-spec open(pid()) -> {{ok, pid()} | {error, unsupported}, [pid()]}.
open(Link) ->
    open(Link, erx:cap(web), erx_build:id(), erx_hostlink_files:build_flags()).

-doc "open/1 on the relay, build identifier and manifest flags given. For the tests.".
-spec open(pid(), pid() | undefined, {ok, binary()} | {error, term()}, non_neg_integer() | unknown) ->
          {{ok, pid()} | {error, unsupported}, [pid()]}.
open(Link, Relay, {ok, Build}, Flags)
  when is_pid(Relay), is_integer(Flags), Flags band ?ERX_MANIFEST_DEVELOPMENT =/= 0 ->
    {ok, Facet} = start(Link, Relay, erx:owner(Relay), #{principal => ?PRINCIPAL, build => Build}),
    {{ok, Facet}, [Facet]};
open(_Link, _Relay, _Build, _Flags) ->
    {{error, unsupported}, []}.

-doc """
Starts a facet that relays to `Relay`, the web domain's relay facet, whose
domain is `Web`, binding each connection to `Line`, and ends when `Link` or
`Relay` does.
""".
-spec start(pid(), pid(), pos_integer(), line()) -> {ok, pid()}.
start(Link, Relay, Web, Line) ->
    proc_lib:start(?MODULE, init, [Link, Relay, Web, Line]).

-doc """
The payload of the cast to the host for a message the web domain sent, or
`drop` for one of any other shape. Pure, for the tests.
""".
-spec cast_of(term(), pos_integer()) -> {ok, binary()} | drop.
cast_of({erx_origin, Web, {web, C, Bytes} = Message}, Web)
  when is_integer(C), C >= 0, C =< ?U32_MAX, is_binary(Bytes), byte_size(Bytes) =< ?ERX_WEB_MESSAGE_MAX ->
    {ok, term_to_binary(Message)};
cast_of({erx_origin, Web, {web_closed, C, Reason} = Message}, Web)
  when is_integer(C), C >= 0, C =< ?U32_MAX, is_atom(Reason) ->
    {ok, term_to_binary(Message)};
cast_of(_Message, _Web) ->
    drop.

-doc false.
-spec init(pid(), pid(), pos_integer(), line()) -> no_return().
init(Link, Relay, Web, Line) ->
    Watches = [erlang:monitor(process, Link), erlang:monitor(process, Relay)],
    proc_lib:init_ack({ok, self()}),
    loop(#{link => Link, relay => Relay, web => Web, line => Line, watches => Watches}).

loop(#{link := Link, relay := Relay, web := Web, line := Line, watches := Watches} = State) ->
    receive
        {hostlink_call, From, Ref, Request} ->
            From ! {Ref, relay(Request, Relay, Line)};
        {'DOWN', Watch, process, _Pid, _Reason} ->
            case lists:member(Watch, Watches) of
                true -> exit(shutdown);
                false -> ok
            end;
        Message ->
            case cast_of(Message, Web) of
                {ok, Payload} -> Link ! {facet_cast, self(), Payload};
                drop -> ok
            end
    end,
    loop(State).

%% The relay's answer to a host's request of a known shape, `{error, badarg}`
%% for any other, and `{error, unavailable}` when the relay did not answer.
relay(Request, Relay, Line) ->
    case well_formed(Request) of
        true ->
            try gen_server:call(Relay, relayed(Request, Line), ?RELAY_MS) of
                ok -> ok;
                {error, Reason} when is_atom(Reason) -> {error, Reason};
                _Other -> {error, failed}
            catch
                exit:_ -> {error, unavailable}
            end;
        false ->
            {error, badarg}
    end.

%% What the relay is asked for a request: a connect names its line.
relayed({connect, C}, Line) -> {connect, C, Line};
relayed(Request, _Line) -> Request.

well_formed({connect, C}) -> number(C);
well_formed({data, C, Bytes}) -> number(C) andalso is_binary(Bytes) andalso byte_size(Bytes) =< ?ERX_WEB_MESSAGE_MAX;
well_formed({close, C}) -> number(C);
well_formed(_Request) -> false.

number(C) -> is_integer(C) andalso C >= 0 andalso C =< ?U32_MAX.
