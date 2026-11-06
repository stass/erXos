%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_oracle_events).
-moduledoc """
Records Common Test completion and partial-run evidence for the host oracle.

Each event is appended to the file named by `ERX_ORACLE_EVENTS` and, as it
happens, written to standard output as the raw bytes of one frame:
`erx-oracle-event `, the JSON's length in bytes, its CRC-32 as eight hex
digits, the JSON, and a newline, each separated by one space. A newline
comes first, so the frame starts a line even after a suite's own
unterminated print. The host skips and counts a line whose length or
checksum is wrong. The bytes go through `erlang:display_string/2`, one
write per event, not through the io server, so no encoding of the output
device can refuse them.
""".
-behaviour(gen_event).

-include("ct_event.hrl").

-export([init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

-doc "Opens the report path supplied by the host oracle command.".
-spec init(term()) -> {ok, file:io_device()} | {error, term()}.
init(_Arguments) ->
    case os:getenv("ERX_ORACLE_EVENTS") of
        false -> {error, missing_oracle_event_path};
        Path -> file:open(Path, [append, raw, binary])
    end.

-doc "Records supported Common Test events without changing their result.".
-spec handle_event(term(), file:io_device()) -> {ok, file:io_device()}.
handle_event(Event, Device) ->
    case event_record(Event) of
        ignore -> ok;
        Record ->
            Bytes = iolist_to_binary(json:encode(Record)),
            true = byte_size(Bytes) < 32768,
            ok = file:write(Device, [Bytes, $\n]),
            true = erlang:display_string(stdout, frame(Bytes))
    end,
    {ok, Device}.

%% One event on standard output. The prefix is the twin of EVENT_PREFIX in
%% tools/lib/erx/oracle_comparison.rb, which finds and checks the frame.
-spec frame(binary()) -> binary().
frame(Json) ->
    Crc = io_lib:format("~8.16.0b", [erlang:crc32(Json)]),
    iolist_to_binary([$\n, "erx-oracle-event ", integer_to_list(byte_size(Json)), $\s, Crc, $\s, Json, $\n]).

-doc "Acknowledges controller observations after writing their complete record.".
-spec handle_call(term(), file:io_device()) ->
    {ok, ok | {error, unsupported}, file:io_device()}.
handle_call({case_fact, Event}, Device) ->
    {ok, Device} = handle_event(Event, Device),
    {ok, ok, Device};
handle_call(_Request, Device) ->
    {ok, {error, unsupported}, Device}.

-doc "Ignores unrelated process messages.".
-spec handle_info(term(), file:io_device()) -> {ok, file:io_device()}.
handle_info(_Message, Device) ->
    {ok, Device}.

-doc "Closes the event report when Common Test removes the handler.".
-spec terminate(term(), file:io_device()) -> ok | {error, term()}.
terminate(_Reason, Device) ->
    file:close(Device).

-doc "Preserves the open report across a code change.".
-spec code_change(term(), file:io_device(), term()) -> {ok, file:io_device()}.
code_change(_OldVersion, Device, _Extra) ->
    {ok, Device}.

event_record(#event{name = erx_selection_begin, data = Id}) ->
    #{event => <<"selection_begin">>, id => reference_text(Id)};
event_record(#event{name = erx_selection_seal, data = {Id, Count}}) ->
    #{event => <<"selection_seal">>, id => reference_text(Id), count => Count};
event_record(#event{name = erx_selection_close, data = {Id, Normal}}) ->
    #{event => <<"selection_close">>, id => reference_text(Id), normal => Normal};
event_record(#event{name = erx_selection_error, data = Id}) ->
    #{event => <<"selection_error">>, id => reference_text(Id)};
event_record(#event{name = erx_job_selected, data = {Selection, Id, Name}}) ->
    #{event => <<"job_selected">>, selection => reference_text(Selection),
      id => reference_text(Id), name => Name};
event_record(#event{name = erx_job_admitted, data = Id}) ->
    #{event => <<"job_admitted">>, id => reference_text(Id)};
event_record(#event{name = erx_job_worker, data = {Id, Worker}}) ->
    #{event => <<"job_worker">>, id => reference_text(Id), worker => worker_text(Worker)};
event_record(#event{name = erx_job_traversed, data = Worker}) ->
    #{event => <<"job_traversed">>, worker => worker_text(Worker)};
event_record(#event{name = erx_job_exit, data = {Id, Worker, Normal}}) ->
    #{event => <<"job_exit">>, id => reference_text(Id), worker => worker_text(Worker), normal => Normal};
event_record(#event{name = erx_case_start,
                    data = {Token, Worker, Suite, Case, Groups, Log}}) ->
    #{event => <<"case_start">>, id => reference_text(Token),
      worker => worker_text(Worker),
      suite => atom_to_binary(Suite, utf8), testcase => atom_to_binary(Case, utf8),
      groups => [group_record(Group) || Group <- Groups],
      log => optional_text(Log)};
event_record(#event{name = erx_case_finish,
                    data = {Token, Status, Number}}) ->
    #{event => <<"case_finish">>, id => reference_text(Token),
      status => observed_status(Status), number => Number,
      detail => <<"detail retained in raw Common Test log">>};
event_record(#event{name = test_start}) ->
    #{event => <<"test_start">>};
event_record(#event{name = test_done}) ->
    #{event => <<"test_done">>};
event_record(#event{name = test_stats, data = {Passed, Failed, {User, Auto}}}) ->
    #{event => <<"test_stats">>, passed => Passed, failed => Failed,
      user_skip => User, auto_skip => Auto};
event_record(#event{name = tc_start, data = {Suite, Case}}) ->
    (case_record(Suite, Case))#{event => <<"tc_start">>};
event_record(#event{name = tc_done, data = {Suite, Case, Result}}) ->
    (case_record(Suite, Case))#{event => <<"tc_done">>,
                              result => result_status(Result),
                              detail => bounded_term(Result)};
event_record(#event{name = Kind, data = {Suite, Case, Reason}})
  when Kind =:= tc_user_skip; Kind =:= tc_auto_skip ->
    (case_record(Suite, Case))#{event => atom_to_binary(Kind, utf8),
                              detail => bounded_term(Reason)};
event_record(_Event) ->
    ignore.

case_record(Suite, Case) when is_atom(Case) ->
    #{suite => atom_to_binary(Suite, utf8), testcase => atom_to_binary(Case, utf8),
      group => null};
case_record(Suite, {Case, Group}) when is_atom(Case), is_atom(Group) ->
    #{suite => atom_to_binary(Suite, utf8), testcase => atom_to_binary(Case, utf8),
      group => atom_to_binary(Group, utf8)};
case_record(Suite, {Case, Group, _Properties}) ->
    case_record(Suite, {Case, Group}).

result_status(ok) -> <<"passed">>;
result_status({failed, _}) -> <<"failed">>;
result_status({auto_skipped, _}) -> <<"auto_skip">>;
result_status({skipped, _}) -> <<"skipped">>;
result_status(_Result) -> <<"error">>.

bounded_term(_Term) ->
    %% Testcase reasons may contain arbitrary terms or invalid UTF-8. They
    %% stay in Common Test's raw logs, never a soft-limited pretty printer.
    <<"detail retained in raw Common Test log">>.

reference_text(Reference) when is_reference(Reference) ->
    list_to_binary(ref_to_list(Reference)).

worker_text(Pid) when is_pid(Pid) -> list_to_binary(pid_to_list(Pid)).

group_record({Reference, Name}) ->
    #{id => reference_text(Reference),
      name => optional_text(Name)}.

optional_text(undefined) -> null;
optional_text(Text) when is_atom(Text) -> atom_to_binary(Text, utf8);
optional_text(Text) -> unicode:characters_to_binary(Text).

observed_status(ok) -> <<"passed">>;
observed_status(failed) -> <<"failed">>;
observed_status(skip) -> <<"user_skip">>;
observed_status(user) -> <<"user_skip">>;
observed_status(auto_skip) -> <<"auto_skip">>;
observed_status(auto) -> <<"auto_skip">>.
