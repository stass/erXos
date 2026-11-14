%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_log_facet).
-moduledoc """
The decoder of a request a log facet admits (docs/design-log.md, "The log
facet"): the one reader of the records another domain sends the system
log, pure, so its fuzz target (test/erlang/erx_log_facet_fuzz.erl) runs it
alone.

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
""".

-export([decode/1]).

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

%% A proper list of at most ?ERX_LOG_WRITE_MAX records, walked no further than that.
records([], _Count) ->
    true;
records([Record | Rest], Count) when Count < ?ERX_LOG_WRITE_MAX ->
    record(Record) andalso records(Rest, Count + 1);
records(_Records, _Count) ->
    false.

record({Level, Text}) when is_binary(Text), byte_size(Text) =< ?ERX_LOG_WRITE_TEXT_MAX ->
    level(Level);
record(_Record) ->
    false.

%% The logger's eight levels (logger:level()).
level(emergency) -> true;
level(alert) -> true;
level(critical) -> true;
level(error) -> true;
level(warning) -> true;
level(notice) -> true;
level(info) -> true;
level(debug) -> true;
level(_Level) -> false.
