%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_cmd_load).
-moduledoc """
`load (-s | -d DOMAIN) [-v] FILE.beam ...` and
`load (-s | -d DOMAIN) [-v] -m MODULE[:BYTES] ...`: loads compiled modules as one
batch (docs/design-live.md, "One load, three routes", `load`). `-s` loads into the
system domain through the context's `install` facet, and `-d DOMAIN` into the domain
named by its id or name through its `code` facet; exactly one is given, and without
the facet its flag needs, `load` fails before it reads anything.

The first form reads each file through the session's namespace and names each module
by its file's base name without `.beam`, as `erlc` names its output. The second reads
the modules from standard input one after another, as `tools/erx load --ssh` sends
them: `-m MODULE:BYTES` takes exactly BYTES bytes and `-m MODULE` the rest of the input,
so only the last `-m` may leave out its size, and input that ends early or goes on past
the last module loads nothing. Either way every module is read whole, at most
code_load_bytes_max bytes in all (abi/services/code.txt), and hashed before the
exchange runs once: `missing` with the hashes, a `put` for each piece of each blob the
store lacks, then `load` with the manifest, so the bytes hashed are the bytes sent and
either every module is current afterwards or none changed.

Everything on standard input and in the arguments is the caller's: parse/1 and split/2
are the one reader of them, pure, and bound every size before anything is read, so the
input read never passes the sizes the arguments give, or the load bound. A module name
stays a binary here; the code service's reader decides whether it names a module.

`load` prints nothing on success; `-v` prints each module with its hash and whether its
blob was sent. Each failure goes to standard error as `load: NAME: REASON`, NAME the
file or the module, and makes the status 1; a refusal of the whole batch names every
module of it. Every failure takes one route: the step that meets it throws the lines it
writes, and run/2 writes them and answers the status. A request is held within
code_request_max before it is sent, the bound of the install facet's row, so the facet
never drops one unanswered and the wait for its answer, which has no deadline, ends.
""".

-behaviour(erx_cmd).
-erx_command(load).
-erx_usage("load (-s | -d domain) [-v] file.beam ... | load (-s | -d domain) [-v] -m module[:bytes] ...").

-export([run/2, parse/1, split/2]).
-export_type([plan/0, spec/0]).

-include("generated/erx_abi.hrl").

%% Where a load goes: the system domain, or the domain an id or a name names.
-type target() :: system | {domain, binary()}.
%% A module read from standard input: its name and its size, or `rest` for the input left.
-type spec() :: {binary(), pos_integer() | rest}.
-type plan() :: #{target := target(), verbose := boolean(), source := {files, [binary()]} | {input, [spec()]}}.

-doc false.
run(Args, Ctx) ->
    case parse(Args) of
        {ok, #{target := Target, verbose := Verbose, source := Source}} ->
            try
                Facet = facet(Ctx, Target),
                exchange(Ctx, Facet, Target, Verbose, read(Ctx, Source))
            catch
                throw:{failed, Lines} ->
                    erx_cmd:say(Ctx, Lines),
                    {error, {reported, <<"1">>}}
            end;
        {error, usage} ->
            {error, usage}
    end.

%%% The reader of the arguments and of standard input.

-doc """
The plan of a load from its arguments, or `{error, usage}`: exactly one of `-s` and
`-d DOMAIN`, and either 1 to code_modules_max files or as many `-m` specs, never both;
every spec but the last is `MODULE:BYTES`, BYTES a decimal count from 1, the last may
also be `MODULE` alone, and the sizes are within code_load_bytes_max in all.
""".
-spec parse([binary()]) -> {ok, plan()} | {error, usage}.
parse(Args) ->
    maybe
        {ok, Flags, Files} ?= erx_cmd:getopt(Args, "sd:vm:"),
        {ok, Target} ?= target([Flag || Flag <- Flags, Flag =:= $s orelse element(1, Flag) =:= $d]),
        {ok, Source} ?= source([Spec || {$m, Spec} <- Flags], Files),
        {ok, #{target => Target, verbose => lists:member($v, Flags), source => Source}}
    else
        _ -> {error, usage}
    end.

target([$s]) -> {ok, system};
target([{$d, Domain}]) when Domain =/= <<>> -> {ok, {domain, Domain}};
target(_Flags) -> {error, usage}.

source([], Files) when Files =/= [], length(Files) =< ?ERX_CODE_MODULES_MAX ->
    {ok, {files, Files}};
source(Specs, []) when Specs =/= [], length(Specs) =< ?ERX_CODE_MODULES_MAX ->
    {Init, [Last]} = lists:split(length(Specs) - 1, Specs),
    Sized = [spec(Spec) || Spec <- Init],
    Final = case spec(Last) of
                {Name, none} when Name =/= <<>> -> {Name, rest};
                Other -> Other
            end,
    All = Sized ++ [Final],
    case lists:all(fun valid/1, All)
        andalso lists:sum([Size || {_, Size} <- All, is_integer(Size)]) =< ?ERX_CODE_LOAD_BYTES_MAX of
        true -> {ok, {input, All}};
        false -> {error, usage}
    end;
source(_Specs, _Files) ->
    {error, usage}.

%% A spec splits at its last colon, so the size is what follows it; `none` without one.
spec(Spec) ->
    case string:split(Spec, ":", trailing) of
        [Name] -> {Name, none};
        [Name, Digits] -> {Name, count(Digits)}
    end.

valid({Name, Size}) -> Name =/= <<>> andalso (is_integer(Size) orelse Size =:= rest).

%% A decimal count of 1 to 9 digits from 1, so no bignum is ever built from the input;
%% `bad` for anything else.
count(Digits) when byte_size(Digits) >= 1, byte_size(Digits) =< 9 ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Digits)) of
        true when binary_part(Digits, 0, 1) =/= <<"0">> -> binary_to_integer(Digits);
        _ -> bad
    end;
count(_Digits) ->
    bad.

-doc """
The modules of Input, cut by Specs in order: each sized spec takes exactly its bytes and
a last `rest` spec the remaining ones, at least one. `{error, {Name, short}}` names the
module the input ends inside, or before, and `{error, {Name, long}}` the last module
when bytes are left past it.
""".
-spec split([spec()], binary()) -> {ok, [{binary(), binary()}]} | {error, {binary(), short | long}}.
split([_ | _] = Specs, Input) when is_binary(Input) ->
    split(Specs, Input, []).

split([{Name, rest}], <<>>, _Acc) ->
    {error, {Name, short}};
split([{Name, rest}], Input, Acc) ->
    {ok, lists:reverse(Acc, [{Name, Input}])};
split([{Name, Size} | Rest], Input, Acc) when byte_size(Input) >= Size ->
    <<Bytes:Size/binary, More/binary>> = Input,
    split(Rest, More, [{Name, Bytes} | Acc]);
split([{Name, _Size} | _Rest], _Input, _Acc) ->
    {error, {Name, short}};
split([], <<>>, Acc) ->
    {ok, lists:reverse(Acc)};
split([], _More, [{Name, _} | _]) ->
    {error, {Name, long}}.

%%% Effects: the facet, the reads and the exchange. Each failure throws its lines.

facet(Ctx, system) -> facet(Ctx, install, <<"no install facet">>);
facet(Ctx, {domain, _}) -> facet(Ctx, code, <<"no code facet">>).

facet(Ctx, Name, Missing) ->
    case erx_cmd:facet(Ctx, Name) of
        {ok, Facet} -> Facet;
        {error, no_facet} -> throw({failed, [<<"load: ">>, Missing, $\n]})
    end.

read(Ctx, {input, Specs}) ->
    %% Sized specs take exactly their sum, so a byte past it is input past the last
    %% module; a last spec without a size takes the rest, up to the load bound.
    {Limit, Over} = case lists:last(Specs) of
                        {Last, rest} -> {?ERX_CODE_LOAD_BYTES_MAX, {Last, efbig}};
                        {Last, _} -> {lists:sum([Size || {_, Size} <- Specs]), {Last, long}}
                    end,
    Cut = case read_input(Ctx, Limit, <<>>) of
              {ok, Input} -> split(Specs, Input);
              over -> {error, Over}
          end,
    case Cut of
        {ok, Modules} -> Modules;
        {error, {Name, short}} -> fail([Name], <<"input ends early">>);
        {error, {Name, long}} -> fail([Name], <<"input goes on past the last module">>);
        {error, {Name, efbig}} -> fail([Name], efbig)
    end;
read(Ctx, {files, Files}) ->
    {Modules, _Total} = lists:mapfoldl(fun(File, Total) -> read_file(Ctx, File, Total) end, 0, Files),
    Modules.

%% Standard input until its end, in one binary that appends grow in place, or `over`
%% once it passes Limit bytes.
read_input(Ctx, Limit, Acc) ->
    case erx_cmd:read(Ctx) of
        eof -> {ok, Acc};
        Bytes when byte_size(Acc) + byte_size(Bytes) > Limit -> over;
        Bytes -> read_input(Ctx, Limit, <<Acc/binary, Bytes/binary>>)
    end.

%% A whole file within the load bound left, read a piece at a time, so a larger file is
%% refused with efbig without being held; an empty file is no module.
read_file(Ctx, File, Total) ->
    Result = case file:open(erx_cmd:path(Ctx, File), [read, raw, binary]) of
                 {ok, Fd} -> try read_pieces(Fd, ?ERX_CODE_LOAD_BYTES_MAX - Total, <<>>) after file:close(Fd) end;
                 {error, _} = Error -> Error
             end,
    case Result of
        {ok, <<>>} -> fail([File], <<"empty file">>);
        {ok, Bytes} -> {{filename:basename(File, <<".beam">>), Bytes}, Total + byte_size(Bytes)};
        {error, Reason} -> fail([File], Reason)
    end.

read_pieces(Fd, Room, Acc) ->
    case file:read(Fd, ?ERX_CODE_PIECE_MAX) of
        {ok, Bytes} when byte_size(Acc) + byte_size(Bytes) > Room -> {error, efbig};
        {ok, Bytes} -> read_pieces(Fd, Room, <<Acc/binary, Bytes/binary>>);
        eof -> {ok, Acc};
        {error, _} = Error -> Error
    end.

exchange(Ctx, Facet, Target, Verbose, Modules) ->
    Hashed = [{Name, erx_bytes:sha256(Bytes), Bytes} || {Name, Bytes} <- Modules],
    Names = [Name || {Name, _, _} <- Hashed],
    Lacking = case call(Facet, {missing, [Hash || {_, Hash, _} <- Hashed]}, Names) of
                  {ok, Hashes} when is_list(Hashes) -> Hashes;
                  Refused -> refused(Names, Refused)
              end,
    [put_blob(Facet, Name, Hash, Bytes, 0) || {Name, Hash, Bytes} <- Hashed, lists:member(Hash, Lacking)],
    case call(Facet, load_request(Target, [{Name, Hash} || {Name, Hash, _} <- Hashed]), Names) of
        ok -> ok;
        {error, {not_loaded, [_ | _] = Failed}} -> throw({failed, [line(Name, What) || {Name, What} <- Failed]});
        Refused2 -> refused(Names, Refused2)
    end,
    case Verbose of
        true -> erx_cmd:write(Ctx, [[Name, $\s, binary:encode_hex(Hash, lowercase), $\s,
                                     sent(lists:member(Hash, Lacking)), $\n] || {Name, Hash, _} <- Hashed]);
        false -> ok
    end.

sent(true) -> <<"sent">>;
sent(false) -> <<"not sent">>.

load_request(system, Manifest) -> {load, Manifest};
load_request({domain, Domain}, Manifest) -> {load, Domain, Manifest}.

%% The pieces of one blob in order; the store asks for the next where a piece ends, and
%% answers `stored` once it holds the blob, which may be early when another load stored
%% it meanwhile.
put_blob(Facet, Name, Hash, Bytes, Offset) ->
    Size = byte_size(Bytes),
    Piece = binary:part(Bytes, Offset, min(?ERX_CODE_PIECE_MAX, Size - Offset)),
    Ends = Offset + byte_size(Piece),
    case call(Facet, {put, Hash, Size, Offset, Piece}, [Name]) of
        {ok, stored} -> ok;
        {ok, {next, Ends}} when Ends < Size -> put_blob(Facet, Name, Hash, Bytes, Ends);
        Refused -> refused([Name], Refused)
    end.

-spec refused([binary()], term()) -> no_return().
refused(Names, {error, Why}) -> fail(Names, Why);
refused(Names, Other) -> fail(Names, {unexpected, Other}).

-spec fail([binary()], term()) -> no_return().
fail(Names, Reason) ->
    throw({failed, [line(Name, Reason) || Name <- Names]}).

line(Name, Reason) when is_atom(Name) -> line(atom_to_binary(Name), Reason);
line(Name, Reason) -> [<<"load: ">>, Name, <<": ">>, erx_cmd:format_error(Reason), $\n].

%% One request of the exchange, held to code_request_max as the facet measures it, a
%% gen_server call's envelope included, and refused for Names past it. A facet of
%% another domain is waited on with no deadline of its own, since the code service
%% answers every request it is sent; `local`, in the system domain's own shell, is the
%% service itself. An exit carries no request bytes into what is written.
%% gen's reply tag [alias | Ref] is an improper list by its protocol.
-dialyzer({no_improper_lists, call/3}).
call(Facet, Request, Names) ->
    Envelope = {'$gen_call', {self(), [alias | make_ref()]}, Request},
    erlang:external_size(Envelope) =< ?ERX_CODE_REQUEST_MAX orelse fail(Names, <<"request too large">>),
    try
        case Facet of
            local -> erx_code:call(Request);
            _ when is_pid(Facet) -> gen_server:call(Facet, Request, infinity)
        end
    catch
        exit:{noproc, _} -> {error, unavailable};
        exit:{timeout, _} -> {error, timeout};
        exit:_ -> {error, failed}
    end.
