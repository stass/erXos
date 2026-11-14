%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A host test's erx_log, compiled in place of erlang/apps/erx/src/erx_log.erl, whose NIF
%% stock's emulator cannot load. take/0 asks the process registered as erx_log_standin
%% for what to answer, so a test both programs the ring's lines and sees which process
%% took them and when; with no such process the ring is empty. The other calls take
%% their record and keep nothing.
-module(erx_log).

-export([debug/1, debug_text/1, read/1, take/0]).
-export_type([lines/0]).

-type lines() :: {ok | corrupt, Next :: non_neg_integer(), Lost :: non_neg_integer(), [binary()]}
               | {error, integer()}.

-spec debug(iodata()) -> ok.
debug(_Bytes) ->
    ok.

-spec debug_text(iodata()) -> ok.
debug_text(_Bytes) ->
    ok.

-spec read(non_neg_integer()) -> lines().
read(Cursor) ->
    {ok, Cursor, 0, []}.

-spec take() -> lines().
take() ->
    case whereis(erx_log_standin) of
        undefined ->
            {ok, 0, 0, []};
        Recorder ->
            Ref = make_ref(),
            Recorder ! {take, self(), Ref},
            receive
                {Ref, Lines} -> Lines
            after 1000 ->
                {ok, 0, 0, []}
            end
    end.
