%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_log_facet).
-moduledoc """
The kernel log facet: how root's session in a development build reads the
kernel log, which on the stopgap kernel only the system domain, the root
task, can read (docs/design-live.md, "Scopes" and "The /proc tree"). The
design gives that session an inspect facet of scope `all`, which reaches
`[kernel, log]`; this facet is the part of it the session's own inspector
cannot answer by itself.

The system domain's side:

* start_reader/0, in the console, starts the reader, which answers a call
  of `{read, Cursor}` with erx_log:read(Cursor), one read of the log from
  Cursor that moves no cursor the console or another reader holds, and
  `{error, ERX_EINVAL}` to any other request; a plain message the facet
  forwards is refused with `{error, badarg}`. One read answers the lines of
  the records in the log NIF's one window, four of the longest records'
  bytes, about 8.5 KiB, so an answer is tens of KiB at most. It takes calls only from processes of its
  own node, and ends with the console.
* grant/2 is the facet the console hands each session it starts, beside
  its console facet: a facet named `log` in front of the reader in a
  development build, and none in any other. The console starts only its
  line's principal's sessions, root's (erx_console), so only root's
  session in a development build holds one. The domain service mints it
  (erx_domain_facet), so the session's calls arrive at the reader only
  through the facet, which takes the envelope off and admits only the
  grantee's calls, at most 16 in flight.

The session's side is read_fun/1, the read erx_log_records pages the log
with: erx_log:read/1 in a domain that holds no `log` facet, which is the
system domain (erx_facets gives it none) and any domain the console did
not start, where the stopgap answers ERX_ENOTSUP; and a call through the
facet where the domain holds one. answer/1 checks the system domain's
answer whole before the pager sees it.

The lines are the log core's renderings, each byte already escaped, and
reach a terminal only through the field escape of `/proc/kernel/log`
(erx_procfs_core) or a view's renderer, as in the system domain.
""".

-export([start_reader/0, grant/2, build_flags/0]).
-export([read_fun/1, answer/1]).
-export([reader_init/1]).

-include("generated/erx_abi.hrl").

-define(U64, 16#ffffffffffffffff).
%% The longest line a read answers: the schema's log_line (abi/inspection.txt).
-define(LINE_MAX, 65536).
%% How long a session waits for one read through the facet.
-define(CALL_MS, 5000).

%%% The system domain's side.

-doc "Starts the reader, which ends when the caller does.".
-spec start_reader() -> pid().
start_reader() ->
    proc_lib:spawn(?MODULE, reader_init, [self()]).

-doc false.
reader_init(Owner) ->
    serve_loop(Owner, monitor(process, Owner)).

serve_loop(Owner, Monitor) ->
    receive
        {'$gen_call', {Caller, _Tag} = From, Request} when is_pid(Caller), node(Caller) =:= node() ->
            gen:reply(From, serve(Request));
        %% A plain message the grantee sent, which the facet forwards and counts in flight
        %% until it is answered: refused, so it never holds one of the facet's slots.
        {'$erx_facet_message', {Facet, _Tag} = From, _Domain, _Message} when is_pid(Facet), node(Facet) =:= node() ->
            gen:reply(From, {error, badarg});
        {'DOWN', Monitor, process, Owner, Reason} ->
            exit(Reason);
        _Other ->
            ok
    end,
    serve_loop(Owner, Monitor).

serve({read, Cursor}) when is_integer(Cursor), Cursor >= 0, Cursor =< ?U64 ->
    erx_log:read(Cursor);
serve(_Request) ->
    {error, ?ERX_EINVAL}.

-doc """
The facets the console hands a session beside its console facet, for a
build whose system manifest has Flags (build_flags/0): `log`, in front of
Reader with erx_facet's default limits, in a development build, and none
in a release build or one whose manifest could not be read.
""".
-spec grant(non_neg_integer() | unknown, pid() | none) -> #{log => {pid(), #{}}}.
grant(Flags, Reader) when is_integer(Flags), Flags band ?ERX_MANIFEST_DEVELOPMENT =/= 0, is_pid(Reader) ->
    #{log => {Reader, #{}}};
grant(_Flags, _Reader) ->
    #{}.

-doc """
The flags of this build's system manifest, or `unknown` when it cannot be
read: its development flag is the build's kind, which the image build
checks against the kind it builds. Read in the system domain, where the
system release's tree is the root.
""".
-spec build_flags() -> non_neg_integer() | unknown.
build_flags() ->
    <<"system/", Path/binary>> = ?ERX_SYSTEM_MANIFEST_PATH_BYTES,
    maybe
        {ok, Manifest} ?= file:read_file(<<"/", Path/binary>>),
        {ok, View} ?= erx_manifest:open(Manifest),
        {ok, #{flags := Flags}} ?= erx_manifest:header(View),
        Flags
    else
        _ -> unknown
    end.

%%% The session's side.

-doc """
The read of the kernel log for a domain whose `log` facet is Facet:
erx_log:read/1 for `undefined`, and a call through the facet otherwise,
whose answer answer/1 checks. A facet that is gone answers ERX_EDEAD, one
that does not answer within 5 s ERX_ETIMEDOUT.
""".
-spec read_fun(pid() | undefined) -> erx_log_records:read().
read_fun(undefined) ->
    fun erx_log:read/1;
read_fun(Facet) when is_pid(Facet) ->
    fun(Cursor) -> call(Facet, Cursor) end.

call(Facet, Cursor) ->
    try gen_server:call(Facet, {read, Cursor}, ?CALL_MS) of
        Answer -> answer(Answer)
    catch
        exit:{timeout, _} -> {error, ?ERX_ETIMEDOUT};
        exit:_Gone -> {error, ?ERX_EDEAD}
    end.

-doc """
The system domain's answer to a read as erx_log:read/1 answers it: a read's
lines, or its refusal with a negative status. An answer of any other
shape, an improper list of lines, a line that is not a binary or is longer than the schema's
log_line, is `{error, ERX_ECORRUPT}`, an answer that failed the reader's
checks, which erx_log_records reports as failed.
""".
-spec answer(term()) -> erx_log:lines().
answer({Whole, Next, Lost, Lines} = Answer)
  when Whole =:= ok orelse Whole =:= corrupt, is_integer(Next), Next >= 0, Next =< ?U64,
       is_integer(Lost), Lost >= 0, is_list(Lines) ->
    case lines(Lines) of
        true -> Answer;
        false -> {error, ?ERX_ECORRUPT}
    end;
answer({error, Status} = Answer) when is_integer(Status), Status < 0 ->
    Answer;
answer(_Answer) ->
    {error, ?ERX_ECORRUPT}.

%% Whether Lines is a proper list of binaries, each at most the schema's log_line.
lines([Line | Rest]) when is_binary(Line), byte_size(Line) =< ?LINE_MAX -> lines(Rest);
lines([]) -> true;
lines(_Lines) -> false.
