%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(etf_oracle).
-moduledoc """
Stock OTP's side of test/integration/etf_oracle_test.rb, which compares
the host tool's codec (tools/lib/erx/etf.rb) with term_to_binary/1 and
binary_to_term/2. Each line of the request file is one request, its
arguments hex-encoded; each line of the answer file answers the request on
the same line:

  encode Source       term_to_binary of the Erlang expression Source
  bytes Source        the binary that Source evaluates to
  check Source Bytes  same | different | refused: binary_to_term(Bytes,
                      [safe]) compared with Source by exact equality
  decode Bytes        term_to_binary(binary_to_term(Bytes, [safe])), or
                      refused
  refuse Bytes        refused when binary_to_term(Bytes) refuses it, in
                      unsafe mode, so an unknown atom is no reason
""".

-export([main/1]).

-doc "Answers the requests of the first file into the second, then halts.".
-spec main([string()]) -> no_return().
main([Requests, Answers]) ->
    {ok, Text} = file:read_file(Requests),
    Lines = [Line || Line <- binary:split(Text, <<"\n">>, [global]),
                     Line =/= <<>>],
    Out = [[answer(binary:split(Line, <<" ">>, [global])), $\n]
           || Line <- Lines],
    ok = file:write_file(Answers, Out),
    halt(0).

answer([<<"encode">>, Source]) ->
    binary:encode_hex(term_to_binary(eval(Source)));
answer([<<"bytes">>, Source]) ->
    Bytes = eval(Source),
    true = is_binary(Bytes),
    binary:encode_hex(Bytes);
answer([<<"check">>, Source, Bytes]) ->
    case decode(Bytes) of
        refused -> <<"refused">>;
        {ok, Term} ->
            case Term =:= eval(Source) of
                true -> <<"same">>;
                false -> <<"different">>
            end
    end;
answer([<<"refuse">>, Bytes]) ->
    try binary_to_term(binary:decode_hex(Bytes)) of
        _ -> <<"accepted">>
    catch
        error:badarg -> <<"refused">>
    end;
answer([<<"decode">>, Bytes]) ->
    case decode(Bytes) of
        refused -> <<"refused">>;
        {ok, Term} -> binary:encode_hex(term_to_binary(Term))
    end.

decode(Hex) ->
    try
        {ok, binary_to_term(binary:decode_hex(Hex), [safe])}
    catch
        error:badarg -> refused
    end.

eval(Hex) ->
    Text = unicode:characters_to_list(binary:decode_hex(Hex)),
    {ok, Tokens, _} = erl_scan:string(Text ++ "."),
    {ok, Exprs} = erl_parse:parse_exprs(Tokens),
    {value, Value, _} = erl_eval:exprs(Exprs, erl_eval:new_bindings()),
    Value.
