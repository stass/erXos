%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The fuzz target of the controller's line (docs/design-bluetooth.md, "Fuzz targets"):
%% erx_h4:split/1, erx_hci:event/2 and erx_hci:return/2, the readers of every byte a
%% controller sends, which is hostile, and erx_bt_patch:parse/1, the reader of the patch
%% file, whose bytes are untrusted too. A round takes one of them and an input this
%% module writes from the specification's layouts (Core 6.3 Vol 4 Part A, section 2;
%% Part E, sections 5.4 and 7), used as written, cut, mutated, given a reserved handle,
%% or replaced by random bytes. Whatever arrives, no reader makes an atom or raises, and
%% each answer is checked against what this module knows independently:
%%
%% * split/1 gives packets whose encodings, then the rest, are the input byte for byte;
%%   no ACL packet longer than 251 octets (bt_acl_rx_max); a rest that is one
%%   incomplete packet, by its own header; a written stream back as written, cut
%%   anywhere; and an ACL length past the bound refused at its header, whatever data
%%   follow it.
%% * event/2 decodes a written event to the term written, and an event written with a
%%   reserved handle (0xF00 to 0xFFF) as malformed; any event it decodes has exactly its
%%   layout's length and handles from 0x000 to 0xEFF; malformed only for a code it
%%   decodes, unknown only for one it does not.
%% * return/2 answers a failed status as failed, and a success as decoded exactly when
%%   it has its command's layout's length, the values read back as written, but for a
%%   Long Term Key reply's return naming a reserved handle, which is malformed.
%% * parse/1 gives records whose encodings are the file byte for byte, each of Write
%%   RAM or Launch RAM; a written patch back as written; a patch whose last record is
%%   cut refused as truncated at that record; and a refusal's offset and opcode as the
%%   file has them.
%%
%% Every number is written out here, apart from erx_hci's code, so a layout misread
%% there disagrees with this module. The seed comes from make check-fuzz.

-module(erx_bt_hci_fuzz).
-export([run/1]).

-define(ROUNDS, 20000).
-define(ACL_MAX, 251).
-define(HANDLE_MAX, 16#EFF).
-define(SUCCESS, 16#00).
%% The events erx_hci decodes, and the LE Meta subevents among them.
-define(EVENTS, [16#05, 16#08, 16#0E, 16#0F, 16#10, 16#13, 16#30, 16#3E]).
-define(LE_SUBEVENTS, [16#01, 16#03, 16#05]).
%% The events this module writes, those with a handle first.
-define(HANDLED, [disconnection_complete, encryption_change, encryption_key_refresh_complete,
                  number_of_completed_packets, le_connection_complete, le_connection_update_complete,
                  le_long_term_key_request]).
-define(UNHANDLED, [command_complete, command_status, hardware_error, no_completed_packets, other_le_meta]).
%% Each command named to return/2 and the length of its Command Complete's return
%% parameters, status included (7.4.1, 7.4.2, 7.8.3, 7.4.6, 7.8.2, 7.4.5, 7.8.25, 7.8.26;
%% the rest return their status alone).
-define(RETURNS, [{read_local_version, 9}, {read_local_commands, 65}, {le_read_features, 9}, {read_bd_addr, 7},
                  {le_read_buffer_size, 4}, {read_buffer_size, 8}, {reset, 1}, {set_event_mask, 1},
                  {host_buffer_size, 1}, {le_set_event_mask, 1}, {le_set_random_address, 1},
                  {le_set_advertising_parameters, 1}, {le_set_advertising_data, 1},
                  {le_set_scan_response_data, 1}, {le_set_advertising_enable, 1}, {disconnect, 1},
                  {vendor, 1}, {le_long_term_key_request_reply, 3}, {le_long_term_key_request_negative_reply, 3}]).
%% The returns that carry a Connection_Handle (7.8.25, 7.8.26).
-define(IS_HANDLE_RETURN(Name), (Name =:= le_long_term_key_request_reply orelse
                                 Name =:= le_long_term_key_request_negative_reply)).

run([Seed]) ->
    rand:seed(exsss, {20, 26, list_to_integer(Seed)}),
    %% Loading a module makes atoms; a round must not, so every module the rounds reach is loaded first.
    ok = erx_fuzz_warm:closure(?MODULE),
    Readers = [split, event, return, patch],
    Outcomes = lists:foldl(fun(_, Tally) -> maps:update_with(round_of(pick(Readers)), fun(N) -> N + 1 end, 1, Tally) end,
                           #{}, lists:seq(1, ?ROUNDS)),
    Accepted = [{Reader, maps:get(Reader, Outcomes, 0)} || Reader <- Readers],
    case lists:all(fun({_, N}) -> N >= ?ROUNDS div 10 end, Accepted) of
        true -> io:format("fuzz: ~p rounds ok, ~p split, ~p events decoded, ~p returns decoded, ~p patches read~n",
                          [?ROUNDS | [N || {_, N} <- Accepted]]);
        false -> error({too_few_accepted, Accepted})
    end.

%% One round of one reader: the reader's name when it accepted the input, `refused`
%% when it did not.
round_of(split) ->
    {Input, Expected} = stream_case(),
    Said = no_atoms(Input, fun() -> erx_h4:split(Input) end),
    check_split(Input, Said),
    case Expected of
        {packets, Packets} -> split_back(Input, Packets, Said);
        {acl_too_long, Length} -> Said =:= {error, {acl_too_long, Length}} orelse error({acl_over_bound, Input, Said});
        none -> ok
    end,
    accepted(split, Said);
round_of(event) ->
    {Code, Parameters, Expected} = event_case(),
    Said = no_atoms({Code, Parameters}, fun() -> erx_hci:event(Code, Parameters) end),
    check_event(Code, Parameters, Said),
    Expected =:= none orelse Said =:= Expected orelse error({decoded_wrongly, Code, Parameters, Said}),
    accepted(event, Said);
round_of(return) ->
    {Name, Return, Expected} = return_case(),
    Said = no_atoms({Name, Return}, fun() -> erx_hci:return(Name, Return) end),
    check_return(Name, Return, Said),
    Expected =:= none orelse Said =:= Expected orelse error({decoded_wrongly, Name, Return, Said}),
    accepted(return, Said);
round_of(patch) ->
    {Input, Expected} = patch_case(),
    Said = no_atoms(Input, fun() -> erx_bt_patch:parse(Input) end),
    check_patch(Input, Said),
    Expected =:= none orelse Said =:= Expected orelse error({patch_read_wrongly, Input, Said}),
    accepted(patch, Said).

%% A patch of Write RAM and Launch RAM records, as written, with its last record cut
%% short, mutated, or replaced by random bytes.
patch_case() ->
    Records = [{pick([16#FC4C, 16#FC4E]), bytes(rand:uniform(256) - 1)} || _ <- lists:seq(1, rand:uniform(6))],
    File = encode_patch(Records),
    case rand:uniform(6) of
        N when N =< 3 -> {File, {ok, Records}};
        4 ->
            {_, Last} = lists:last(Records),
            Start = byte_size(File) - 3 - byte_size(Last),
            Cut = rand:uniform(2 + byte_size(Last)),
            {binary:part(File, 0, byte_size(File) - Cut), {error, {truncated, Start}}};
        5 -> {mutate(File), none};
        6 -> {bytes(rand:uniform(64) - 1), none}
    end.

encode_patch(Records) ->
    iolist_to_binary([<<Opcode:16/little, (byte_size(Payload)), Payload/binary>> || {Opcode, Payload} <- Records]).

check_patch(Input, {ok, Records}) ->
    Known = lists:all(fun({Opcode, _}) -> Opcode =:= 16#FC4C orelse Opcode =:= 16#FC4E end, Records),
    Known andalso encode_patch(Records) =:= Input orelse error({patch_accepted_wrongly, Input, Records});
check_patch(<<>>, {error, empty}) ->
    ok;
check_patch(Input, {error, {truncated, Offset}}) when Offset < byte_size(Input) ->
    ok;
check_patch(Input, {error, {foreign_opcode, Offset, Opcode}}) ->
    case Input of
        <<_:Offset/binary, Opcode:16/little, _/binary>> when Opcode =/= 16#FC4C, Opcode =/= 16#FC4E -> ok;
        _ -> error({patch_refused_wrongly, Input, Offset, Opcode})
    end;
check_patch(Input, Said) ->
    error({patch_refused_wrongly, Input, Said}).

no_atoms(Input, Read) ->
    Atoms = erlang:system_info(atom_count),
    Said = Read(),
    erlang:system_info(atom_count) =:= Atoms orelse error({atoms_made, Input}),
    Said.

accepted(_Reader, {error, _}) -> refused;
accepted(_Reader, malformed) -> refused;
accepted(_Reader, {unknown, _}) -> refused;
accepted(Reader, _) -> Reader.

%% H4: a written stream as it is ({packets, P}); with an ACL header past the bound at
%% its end and any part of its data ({acl_too_long, L}); mutated or random (none).
stream_case() ->
    Packets = [packet() || _ <- lists:seq(1, rand:uniform(7) - 1)],
    Stream = iolist_to_binary([encode(Packet) || Packet <- Packets]),
    case rand:uniform(6) of
        N when N =< 2 -> {Stream, {packets, Packets}};
        3 ->
            Length = ?ACL_MAX + rand:uniform(300),
            {<<Stream/binary, 2, (word(rand:uniform(16#1000) - 1, 0, 0)):16/little, Length:16/little,
               (bytes(rand:uniform(Length + 8) - 1))/binary>>, {acl_too_long, Length}};
        N when N =< 5 -> {mutate(Stream), none};
        6 -> {bytes(rand:uniform(64) - 1), none}
    end.

packet() ->
    case rand:uniform(2) of
        1 -> {event, byte(), bytes(rand:uniform(256) - 1)};
        2 -> {acl, rand:uniform(16#1000) - 1, rand:uniform(4) - 1, rand:uniform(4) - 1, bytes(rand:uniform(?ACL_MAX + 1) - 1)}
    end.

%% Part A, section 2, and Part E, sections 5.4.2 and 5.4.4.
encode({event, Code, Parameters}) -> <<4, Code, (byte_size(Parameters)), Parameters/binary>>;
encode({acl, Handle, Boundary, Broadcast, Data}) ->
    <<2, (word(Handle, Boundary, Broadcast)):16/little, (byte_size(Data)):16/little, Data/binary>>.

word(Handle, Boundary, Broadcast) -> Handle bor (Boundary bsl 12) bor (Broadcast bsl 14).

check_split(Input, {Packets, Rest}) when is_list(Packets), is_binary(Rest) ->
    lists:foreach(fun check_packet/1, Packets),
    iolist_to_binary([[encode(Packet) || Packet <- Packets], Rest]) =:= Input orelse error({not_the_input, Input}),
    incomplete(Rest) orelse error({rest_not_incomplete, Input, Rest});
check_split(_Input, {error, {bad_indicator, Byte}}) when Byte =/= 2, Byte =/= 4 ->
    ok;
check_split(_Input, {error, {acl_too_long, Length}}) when Length > ?ACL_MAX ->
    ok;
check_split(Input, Said) ->
    error({split_answer, Input, Said}).

%% One packet that has not all arrived, read by its own header: an event's parameters
%% short of its length, or an ACL packet's data short of its length. An ACL header past
%% the bound left waiting for its data is the bound not checked at the header.
incomplete(<<>>) -> true;
incomplete(<<4, _Code, Length, Parameters/binary>>) -> byte_size(Parameters) < Length;
incomplete(<<4, _/binary>> = Head) -> byte_size(Head) < 3;
incomplete(<<2, _Word:16, Length:16/little, _/binary>> = Rest) when Length > ?ACL_MAX -> error({acl_over_bound, Rest});
incomplete(<<2, _Word:16, Length:16/little, Data/binary>>) -> byte_size(Data) < Length;
incomplete(<<2, _/binary>> = Head) -> byte_size(Head) < 5;
incomplete(_Rest) -> false.

check_packet({event, Code, Parameters}) when Code >= 0, Code =< 255, byte_size(Parameters) =< 255 ->
    ok;
check_packet({acl, _Handle, _Boundary, _Broadcast, Data} = Packet) when byte_size(Data) > ?ACL_MAX ->
    error({acl_over_bound, Packet});
check_packet({acl, Handle, Boundary, Broadcast, Data}) when Handle >= 0, Handle =< 16#FFF, Boundary >= 0,
                                                           Boundary =< 3, Broadcast >= 0, Broadcast =< 3,
                                                           is_binary(Data) ->
    ok;
check_packet(Packet) ->
    error({ill_formed_packet, Packet}).

%% A written stream reads back as written, whole and cut at any byte.
split_back(Input, Packets, Said) ->
    Said =:= {Packets, <<>>} orelse error({split_wrongly, Input, Said}),
    Cut = rand:uniform(byte_size(Input) + 1) - 1,
    <<Head:Cut/binary, Tail/binary>> = Input,
    {First, Rest} = erx_h4:split(Head),
    case erx_h4:split(<<Rest/binary, Tail/binary>>) of
        {Second, <<>>} -> First ++ Second =:= Packets orelse error({cut_splits_differently, Input, Cut});
        Second -> error({cut_splits_differently, Input, Cut, Second})
    end.

%% HCI events: {Code, Parameters, Term} for a written one, malformed for one written
%% with a reserved handle (but a failed LE Connection Complete, whose handle is never
%% read), none for one mutated or random.
event_case() ->
    Live = rand:uniform(?HANDLE_MAX + 1) - 1,
    case rand:uniform(6) of
        N when N =< 2 -> written_event(pick(?HANDLED ++ ?UNHANDLED), Live);
        N when N =< 4 -> {Code, Parameters, _} = written_event(pick(?HANDLED ++ ?UNHANDLED), Live),
                         {Code, mutate(Parameters), none};
        5 -> {Code, Parameters, Term} = written_event(pick(?HANDLED), ?HANDLE_MAX + rand:uniform(16#FFF - ?HANDLE_MAX)),
             {Code, Parameters, reserved(Term)};
        6 -> {byte(), bytes(rand:uniform(32) - 1), none}
    end.

%% Each event of Part E, 7.7, from random fields, with the term it decodes to; the
%% handle word's upper four bits are flags the decoder ignores.
written_event(Kind, Handle) ->
    Word = Handle bor ((rand:uniform(16) - 1) bsl 12),
    Status = byte(),
    case Kind of
        command_complete ->
            {Allowed, Opcode, Return} = {byte(), rand:uniform(16#10000) - 1, bytes(rand:uniform(253) - 1)},
            {16#0E, <<Allowed, Opcode:16/little, Return/binary>>, {command_complete, Allowed, Opcode, Return}};
        command_status ->
            {Allowed, Opcode} = {byte(), rand:uniform(16#10000) - 1},
            {16#0F, <<Status, Allowed, Opcode:16/little>>, {command_status, Status, Allowed, Opcode}};
        disconnection_complete ->
            Reason = byte(),
            {16#05, <<Status, Word:16/little, Reason>>, {disconnection_complete, Status, Handle, Reason}};
        encryption_change ->
            Enabled = byte(),
            {16#08, <<Status, Word:16/little, Enabled>>, {encryption_change, Status, Handle, Enabled}};
        encryption_key_refresh_complete ->
            {16#30, <<Status, Word:16/little>>, {encryption_key_refresh_complete, Status, Handle}};
        hardware_error ->
            {16#10, <<Status>>, {hardware_error, Status}};
        number_of_completed_packets ->
            %% The round's handle first; at most 63 pairs, so the parameters fit in 255
            %% octets.
            Others = [rand:uniform(?HANDLE_MAX + 1) - 1 || _ <- lists:seq(1, rand:uniform(63) - 1)],
            Counts = [rand:uniform(16#10000) - 1 || _ <- [Handle | Others]],
            Written = lists:zip([Word | Others], Counts),
            {16#13, <<(length(Written)), << <<W:16/little, C:16/little>> || {W, C} <- Written >>/binary>>,
             {number_of_completed_packets, lists:zip([Handle | Others], Counts)}};
        no_completed_packets ->
            {16#13, <<0>>, {number_of_completed_packets, []}};
        le_connection_complete ->
            %% Success half the time, so the peer's address type is read; a type of 0 or
            %% 1 mostly, else a reserved one.
            Connected = pick([?SUCCESS, Status]),
            PeerType = pick([16#00, 16#01, byte()]),
            [Role, Accuracy] = [byte() || _ <- [role, accuracy]],
            Peer = bytes(6),
            {16#3E, <<16#01, Connected, Word:16/little, Role, PeerType, (reverse(Peer))/binary, (bytes(6))/binary,
                      Accuracy>>,
             connection(Connected, Handle, PeerType, Peer)};
        le_connection_update_complete ->
            {16#3E, <<16#03, Status, Word:16/little, (bytes(6))/binary>>, {le_connection_update_complete, Status, Handle}};
        le_long_term_key_request ->
            {Random, Ediv} = {bytes(8), rand:uniform(16#10000) - 1},
            {16#3E, <<16#05, Word:16/little, Random/binary, Ediv:16/little>>, {le_long_term_key_request, Handle, Random, Ediv}};
        other_le_meta ->
            Subevent = pick([S || S <- lists:seq(0, 255), not lists:member(S, ?LE_SUBEVENTS)]),
            {16#3E, <<Subevent, (bytes(rand:uniform(20) - 1))/binary>>, {unknown, {le_meta, Subevent}}}
    end.

%% LE Connection Complete as decoded (7.7.65.1): a failed one from its Status alone (4.5.1,
%% Table 4.1), whatever the rest holds; a successful one with its handle and its peer's
%% address, malformed for a reserved handle or Peer_Address_Type.
connection(Status, _Handle, _PeerType, _Peer) when Status =/= ?SUCCESS -> {le_connection_complete, {failed, Status}};
connection(_Success, Handle, _PeerType, _Peer) when Handle > ?HANDLE_MAX -> malformed;
connection(_Success, Handle, 16#00, Peer) -> {le_connection_complete, Handle, {public, Peer}};
connection(_Success, Handle, 16#01, Peer) -> {le_connection_complete, Handle, {random, Peer}};
connection(_Success, _Handle, _Reserved, _Peer) -> malformed.

%% A written event's term once its handle is reserved: malformed, but for a failed LE
%% Connection Complete, whose handle is never read.
reserved({le_connection_complete, {failed, _}} = Failed) -> Failed;
reserved(_Term) -> malformed.

check_event(Code, Parameters, malformed) ->
    lists:member(Code, ?EVENTS) orelse error({malformed_unknown_code, Code, Parameters}),
    not failed_connection(Code, Parameters) orelse error({failed_connection_malformed, Parameters});
check_event(Code, Parameters, {unknown, {le_meta, Subevent}}) ->
    Code =:= 16#3E andalso not lists:member(Subevent, ?LE_SUBEVENTS) andalso binary:first(Parameters) =:= Subevent
        orelse error({unknown_subevent_wrongly, Parameters});
check_event(Code, _Parameters, {unknown, Code}) ->
    not lists:member(Code, ?EVENTS) orelse error({known_code_unknown, Code});
check_event(Code, Parameters, Term) ->
    layout(Term) =:= Code orelse error({wrong_kind, Code, Term}),
    byte_size(Parameters) =:= length_of(Code, Parameters) orelse error({length_disagrees, Code, Parameters, Term}),
    lists:all(fun(Handle) -> Handle >= 0 andalso Handle =< ?HANDLE_MAX end, handles(Term))
        orelse error({reserved_handle, Code, Parameters, Term}),
    case Term of
        {le_connection_complete, _, {Type, <<_:48>>}} when Type =:= public; Type =:= random -> ok;
        {le_connection_complete, _, Peer} -> error({reserved_peer_type, Parameters, Peer});
        _ -> ok
    end.

%% The code each decoded term comes from.
layout({command_complete, _, _, _}) -> 16#0E;
layout({command_status, _, _, _}) -> 16#0F;
layout({disconnection_complete, _, _, _}) -> 16#05;
layout({encryption_change, _, _, _}) -> 16#08;
layout({encryption_key_refresh_complete, _, _}) -> 16#30;
layout({hardware_error, _}) -> 16#10;
layout({number_of_completed_packets, _}) -> 16#13;
layout({le_connection_complete, _, _}) -> 16#3E;
layout({le_connection_complete, {failed, _}}) -> 16#3E;
layout({le_connection_update_complete, _, _}) -> 16#3E;
layout({le_long_term_key_request, _, _, _}) -> 16#3E;
layout(Term) -> error({not_an_event, Term}).

%% Each layout's length (7.7.5, 7.7.8, 7.7.14, 7.7.15, 7.7.16, 7.7.19, 7.7.39, 7.7.65.1,
%% 7.7.65.3, 7.7.65.5); Command Complete's return parameters take whatever follows, and
%% so do a failed LE Connection Complete's octets after its Status.
length_of(16#05, _) -> 4;
length_of(16#08, _) -> 4;
length_of(16#0E, Parameters) -> max(3, byte_size(Parameters));
length_of(16#0F, _) -> 4;
length_of(16#10, _) -> 1;
length_of(16#13, <<Count, _/binary>>) -> 1 + 4 * Count;
length_of(16#30, _) -> 3;
length_of(16#3E, <<16#01, Status, _/binary>> = Parameters) when Status =/= ?SUCCESS -> byte_size(Parameters);
length_of(16#3E, <<16#01, _/binary>>) -> 19;
length_of(16#3E, <<16#03, _/binary>>) -> 10;
length_of(16#3E, <<16#05, _/binary>>) -> 13;
length_of(Code, Parameters) -> error({no_layout, Code, Parameters}).

handles({number_of_completed_packets, Pairs}) -> [Handle || {Handle, _} <- Pairs];
handles({Kind, _, Handle, _}) when Kind =:= disconnection_complete; Kind =:= encryption_change -> [Handle];
handles({le_connection_complete, Handle, _Peer}) when is_integer(Handle) -> [Handle];
handles({Kind, _, Handle}) when Kind =:= encryption_key_refresh_complete;
                                Kind =:= le_connection_update_complete -> [Handle];
handles({le_long_term_key_request, Handle, _, _}) -> [Handle];
handles(_) -> [].

%% Whether the parameters are those of a failed LE Connection Complete, which is never
%% malformed: nothing after its Status is read.
failed_connection(16#3E, <<16#01, Status, _/binary>>) -> Status =/= ?SUCCESS;
failed_connection(_Code, _Parameters) -> false.

%% Command Complete returns: {Name, Return, Decoded} for a success written in its
%% layout or a failure; {Name, Return, none} for a success of any other length.
return_case() ->
    {Name, Length} = pick(?RETURNS),
    case rand:uniform(3) of
        1 -> Fields = bytes(Length - 1), {Name, <<0, Fields/binary>>, success(Name, Fields)};
        2 -> Status = rand:uniform(255), {Name, <<Status, (bytes(rand:uniform(70) - 1))/binary>>, {failed, Status}};
        3 -> {Name, success_of_length(rand:uniform(72) - 1), none}
    end.

%% A success's answer: the handle of a reply's return, malformed when it is reserved (its
%% word's upper four bits are flags), else the values its fields give.
success(Name, <<Word:16/little>>) when ?IS_HANDLE_RETURN(Name) ->
    case Word band 16#FFF of
        Handle when Handle =< ?HANDLE_MAX -> {ok, Handle};
        _Reserved -> malformed
    end;
success(Name, Fields) ->
    {ok, value(Name, Fields)}.

%% The values a success returns, read from its fields as the sections lay them out.
value(read_local_version, <<HciVersion, HciSubversion:16/little, LmpVersion, Company:16/little, LmpSubversion:16/little>>) ->
    #{hci_version => HciVersion, hci_subversion => HciSubversion, lmp_version => LmpVersion, company => Company,
      lmp_subversion => LmpSubversion};
value(read_local_commands, Commands) -> Commands;
value(le_read_features, Features) -> Features;
value(read_bd_addr, Address) -> reverse(Address);
value(le_read_buffer_size, <<Length:16/little, Packets>>) -> {Length, Packets};
value(read_buffer_size, <<Length:16/little, _, Packets:16/little, _:16>>) -> {Length, Packets};
value(_StatusOnly, <<>>) -> done.

%% A status of success then random bytes, Length in all.
success_of_length(0) -> <<>>;
success_of_length(Length) -> <<0, (bytes(Length - 1))/binary>>.

check_return(_Name, <<>>, malformed) ->
    ok;
check_return(_Name, <<Status, _/binary>>, {failed, Status}) when Status =/= 0 ->
    ok;
check_return(Name, <<0, Fields:2/binary>>, Said) when ?IS_HANDLE_RETURN(Name) ->
    Said =:= success(Name, Fields) orelse error({return_handle_disagrees, Name, Fields, Said});
check_return(Name, <<0, _/binary>> = Return, Said) ->
    {Name, Length} = lists:keyfind(Name, 1, ?RETURNS),
    case Said of
        {ok, _} when byte_size(Return) =:= Length -> ok;
        malformed when byte_size(Return) =/= Length -> ok;
        _ -> error({return_length_disagrees, Name, Return, Said})
    end;
check_return(Name, Return, Said) ->
    error({return_answer, Name, Return, Said}).

reverse(Bytes) -> list_to_binary(lists:reverse(binary_to_list(Bytes))).

%% Damage at one place: a byte removed, inserted or replaced, the first byte replaced
%% (a count or a subevent), or the input cut short.
mutate(<<>>) ->
    bytes(rand:uniform(8));
mutate(Input) ->
    At = rand:uniform(byte_size(Input)) - 1,
    <<Before:At/binary, Byte, After/binary>> = Input,
    case rand:uniform(5) of
        1 -> <<Before/binary, After/binary>>;
        2 -> <<Before/binary, (byte()), Byte, After/binary>>;
        3 -> <<Before/binary, (byte()), After/binary>>;
        4 -> <<_, Tail/binary>> = Input, <<(byte()), Tail/binary>>;
        5 -> Before
    end.

byte() -> rand:uniform(256) - 1.

bytes(Count) -> << <<(byte())>> || _ <- lists:seq(1, Count) >>.

pick(List) -> lists:nth(rand:uniform(length(List)), List).
