%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_log_facet).
-moduledoc """
The decoder of a request a log facet admits (docs/design-log.md, "The log
facet"): the one reader of the records another domain sends the system
log, pure, and so is the one question it asks of erx_syslog_core, whether an
atom is a level (is_level/1): its fuzz target
(test/erlang/erx_log_facet_fuzz.erl) runs the two modules alone.

A request is the term the funnel decoded from the grantee's frame, in safe
mode, so every atom in it already existed, and erx_facet has already held
its encoding to the grant's max_request. The interface has one operation:

* `{write, Records}`, where Records is a proper list of at most
  log_write_max (16) records, each a pair `{Level, Text}` of one of the
  logger's eight levels and a binary of at most log_write_text_max (4096)
  bytes.

decode/1 answers the records, as erx_syslog_core:write/4 takes them, or
`{error, badarg}` for anything else: another operation, an extra element,
an improper or longer list, a record of another shape, a level that is
not one of the eight, or a text that is not a binary or is longer. The
request names no source: who wrote the records is the facet's to say, so
a domain can lie only in its own text. decode/1 creates no atom, never
raises, and walks at most the log_write_max records it accepts.

It is also the log facet's erx_facet callback, which the domain service
mints for each grantee of `log` in front of erx_syslog_sup. admit/3 decodes
the request and forwards its records as `{write, Grantee, Records}`, with the
grantee the facet was minted for, to the erx_syslog registered at that
moment, so a facet outlives the service's restarts; with none registered it
refuses with `{error, unavailable}`.
""".
-behaviour(erx_facet).

-export([decode/1]).
-export([init/1, admit/3]).

-include("generated/erx_abi.hrl").

-doc "The records Request carries, or `{error, badarg}` for anything the interface does not take.".
-spec decode(term()) -> {ok, [erx_syslog_core:log_record()]} | {error, badarg}.
decode({write, Records}) ->
    case records(Records, 0) of
        true -> {ok, Records};
        false -> {error, badarg}
    end;
decode(_Request) ->
    {error, badarg}.

-spec init(erx_facet:grant()) -> {ok, #{grantee := pos_integer()}}.
init(#{grantee := Grantee}) ->
    {ok, #{grantee => Grantee}}.

-spec admit(term(), pid(), #{grantee := pos_integer()}) ->
          {forward, pid(), {write, pos_integer(), [erx_syslog_core:log_record()]}, map()}
        | {refuse, badarg | unavailable, map()}.
admit(Request, _From, #{grantee := Grantee} = State) ->
    case decode(Request) of
        {ok, Records} ->
            case whereis(erx_syslog) of
                undefined -> {refuse, unavailable, State};
                Service -> {forward, Service, {write, Grantee, Records}, State}
            end;
        {error, badarg} ->
            {refuse, badarg, State}
    end.

%% A proper list of at most ?ERX_LOG_WRITE_MAX records, walked no further than that.
records([], _Count) ->
    true;
records([Record | Rest], Count) when Count < ?ERX_LOG_WRITE_MAX ->
    record(Record) andalso records(Rest, Count + 1);
records(_Records, _Count) ->
    false.

record({Level, Text}) when is_binary(Text), byte_size(Text) =< ?ERX_LOG_WRITE_TEXT_MAX ->
    erx_syslog_core:is_level(Level);
record(_Record) ->
    false.
