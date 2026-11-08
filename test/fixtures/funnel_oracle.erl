%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(funnel_oracle).
-moduledoc """
Stock OTP's side of test/integration/erx_funnel_oracle_test.rb, which
compares liberx's funnel grammar with ERTS. Each line of the request file
is one request, its arguments hex-encoded; each line of the answer file
answers the request on the same line:

  control Bytes Text  same | different Got | refused: binary_to_term(Bytes)
                      compared by exact equality with the Erlang term Text,
                      after its atoms become binaries of their UTF-8 bytes,
                      its pids {pid, Node, Id, Serial, Creation}, its
                      references {ref, Node, Creation, Words} and a spawn
                      request's option list the atom options
  words Bytes         words N: the heap words ERTS's own size pass
                      (decoded_size in beam/external.c) charges for the
                      payload Bytes, measured on ERTS's distribution input

The node must be alive (-sname). For the words requests it opens a
distribution channel from the node web@erxos with itself as the channel's
controller, and puts on it, for each payload, the frame
{SEND_SENDER, FromPid, Receiver} followed by the payload. Receiver never
receives, so each message stays in its queue undecoded, and
process_info(Receiver, memory) charges an undecoded distribution message
its ErtsMessage and the words of the size pass
(erts_msg_attached_data_size_aux in beam/erl_message.c); a message whose
payload is the atom a, which takes no heap, measures the ErtsMessage.
Only payloads that erx_etf accepted are sent: ERTS ends the channel on a
payload its size pass refuses.
""".

-include_lib("kernel/include/dist.hrl").

-export([main/1]).
%% The node runs with -epmd_module funnel_oracle and -dist_listen false: it
%% is alive without epmd, and nobody can connect to it.
-export([start_link/0, register_node/2, register_node/3, port_please/2,
         port_please/3, names/1, address_please/3, listen_port_please/2]).

-define(PEER, 'web@erxos').
-define(PASS_THROUGH, 112).
-define(SEND_SENDER, 22).

-doc "Answers the requests of the first file into the second, then halts.".
-spec main([string()]) -> no_return().
main([Requests, Answers]) ->
    {ok, Text} = file:read_file(Requests),
    Lines = [binary:split(Line, <<" ">>, [global])
             || Line <- binary:split(Text, <<"\n">>, [global]), Line =/= <<>>],
    Channel = case lists:any(fun([K | _]) -> K =:= <<"words">> end, Lines) of
                  true -> open_channel();
                  false -> none
              end,
    Out = [[answer(Line, Channel), $\n] || Line <- Lines],
    ok = file:write_file(Answers, Out),
    halt(0).

answer([<<"control">>, Bytes, Text], _) ->
    control(binary:decode_hex(Bytes), binary:decode_hex(Text));
answer([<<"words">>, Bytes], Channel) ->
    io_lib:format("words ~w", [words(Channel, binary:decode_hex(Bytes))]).

control(Bytes, Text) ->
    try binary_to_term(Bytes) of
        Term ->
            {ok, Tokens, _} = erl_scan:string(binary_to_list(Text) ++ "."),
            {ok, Expected} = erl_parse:parse_term(Tokens),
            case normal_control(Term) of
                Expected -> "same";
                Got -> io_lib:format("different ~w", [Got])
            end
    catch
        error:badarg -> "refused"
    end.

normal_control(Term) when element(1, Term) =:= 29 ->
    setelement(6, normal(Term), options);
normal_control(Term) ->
    normal(Term).

normal(Pid) when is_pid(Pid) ->
    <<131, 88, Rest/binary>> = term_to_binary(Pid),
    {Node, <<Id:32, Serial:32, Creation:32>>} = node_name(Rest),
    {pid, Node, Id, Serial, Creation};
normal(Ref) when is_reference(Ref) ->
    <<131, 90, _:16, Rest/binary>> = term_to_binary(Ref),
    {Node, <<Creation:32, Words/binary>>} = node_name(Rest),
    {ref, Node, Creation, [W || <<W:32>> <= Words]};
normal(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
normal(Tuple) when is_tuple(Tuple) ->
    list_to_tuple([normal(E) || E <- tuple_to_list(Tuple)]);
normal(Other) ->
    Other.

node_name(<<119, Len, Node:Len/binary, Rest/binary>>) -> {Node, Rest};
node_name(<<118, Len:16, Node:Len/binary, Rest/binary>>) -> {Node, Rest}.

%% The channel from ?PEER, the process that never receives, the frame's
%% control term, and the bytes an ErtsMessage costs.
open_channel() ->
    true = is_alive(),
    Flags = ?DFLAGS_MANDATORY
        bor ?DFLAG_DIST_MONITOR bor ?DFLAG_DIST_MONITOR_NAME
        bor ?DFLAG_EXIT_PAYLOAD bor ?DFLAG_SEND_SENDER bor ?DFLAG_SPAWN
        bor ?DFLAG_ALIAS bor ?DFLAG_UNICODE_IO,
    _ = erts_internal:new_connection(?PEER),
    Handle = erlang:setnode(?PEER, self(), {Flags, 1}),
    Receiver = spawn(fun() -> receive after infinity -> ok end end),
    Name = atom_to_binary(?PEER, utf8),
    From = binary_to_term(<<131, 88, 119, (byte_size(Name)), Name/binary,
                            1:32, 0:32, 1:32>>),
    Control = term_to_binary({?SEND_SENDER, From, Receiver}),
    Channel = {Handle, Receiver, Control, 0},
    {Handle, Receiver, Control, message_bytes(Channel, term_to_binary(a))}.

words({_, _, _, Message} = Channel, Payload) ->
    (message_bytes(Channel, Payload) - Message) div erlang:system_info(wordsize).

message_bytes({Handle, Receiver, Control, _}, Payload) ->
    {memory, Before} = process_info(Receiver, memory),
    ok = erlang:dist_ctrl_put_data(Handle,
                                   <<?PASS_THROUGH, Control/binary, Payload/binary>>),
    {memory, After} = process_info(Receiver, memory),
    After - Before.

-doc "No epmd: the node registers nowhere and looks nobody up.".
start_link() -> ignore.
register_node(_Name, _Port) -> {ok, 1}.
register_node(_Name, _Port, _Family) -> {ok, 1}.
port_please(_Name, _Host) -> noport.
port_please(_Name, _Host, _Timeout) -> noport.
names(_Host) -> {error, address}.
address_please(_Name, _Host, _Family) -> {error, nxdomain}.
listen_port_please(_Name, _Host) -> {ok, 0}.
