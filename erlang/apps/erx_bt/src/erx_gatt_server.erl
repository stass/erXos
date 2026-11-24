%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_server).
-moduledoc """
The ATT server of one link (docs/design-bluetooth.md, "The ATT server"): a pure state
machine over the attribute table and the link's ATT bearer, from the Bluetooth Core
Specification 6.3, Vol 3 Part F (ATT) and Part G (GATT).

`request/3` takes one PDU from the phone and `reply/4` a handler's answer to the write it
was given; each returns the actions the link performs and the next bearer. It answers
Exchange MTU with `erx_l2cap:att_mtu/0`, Find Information, Find By Type Value, Read By Type,
Read, Read Blob, Read By Group Type, Write Request, Prepare Write and Execute Write, and
takes Write Command and Handle Value Confirmation; every other request is Request Not
Supported, every other command is ignored, and a request whose length is wrong, or longer
than the bearer's MTU, is Invalid PDU (3.3). The gate decides every read and write of a
characteristic value or descriptor; `notify/5` asks it before a notification or an
indication too.

A write of a characteristic value goes to its handler as `{write, Ref, Key, Value}`, `Ref`
numbering the bearer's writes, and the bearer waits for the answer to that `Ref`, so an
answer that comes after its write timed out is dropped rather than taken for the next
write; and a handler sees one write of a link at a time, as ATT's
sequential protocol has them (3.3.2). What arrives meanwhile waits in the bearer in order:
at most one request, since a second request before the first's response ends the link,
and at most `bt_write_queue` write commands, past which a command ends the link
(docs/design-bluetooth.md, "What a radio peer can make the domain spend"): ATT would let
it be discarded (3.3.2), but a discarded write is a silent gap in a handler's stream. A
prepared write is one per link, to one characteristic, at most its maximum; a
Prepare Write past that, or to another characteristic, is Prepare Queue Full. Its parts
are joined as they arrive, from an empty value, so the bearer holds at most the maximum
and the handler receives the whole value at Execute Write, which answers Invalid Offset
for a part placed past what the parts before it wrote (3.4.6.1, 3.4.6.3). One indication
is in flight at a time (3.4.7.2).

A write of a Client Characteristic Configuration that changes it awaits an answer the same
way, as `{configure, Ref, Key, Subscription}`: the link answers it at once, or once the
store has kept a bonded link's new configuration (docs/design-bluetooth.md, "Bonds and the
store"), and the configuration changes, and the handlers hear `subscribed`, only at the
answer `ok`; any other answer is Unlikely Error and leaves it as it was. A write that
changes nothing is answered at once. A Write Command to the descriptor changes the
configuration where the gate allows a write of it, through the same answer, and is
ignored otherwise.
""".

-include("generated/erx_abi.hrl").

-export([new/0, request/3, reply/4, notify/5, mtu/1, subscriptions/1, restore/3]).
-export_type([bearer/0, server/0, action/0, subscription/0, ref/0]).

-type key() :: erx_gatt_db:key().
-type subscription() :: none | notify | indicate.
-doc "The number of a write the bearer gave a handler, which its answer names.".
-type ref() :: pos_integer().
-doc "What a step reads: the table, the values the handlers last set and the link's security.".
-type server() :: #{table := erx_gatt_db:table(), values := #{key() => binary()},
                    security := erx_gatt_gate:link_security()}.
-doc """
What the link does: sends a PDU on the ATT channel; gives a write to the characteristic's
handler, or a change of a configuration to whatever decides it, and passes the answer to
`reply/4`; tells the handlers of a subscription, a new MTU or a confirmed indication;
or ends the link.
""".
-type action() :: {send, binary()} | {write, ref(), key(), binary()} | {configure, ref(), key(), subscription()}
                | {subscribed, key(), subscription()} | {mtu, pos_integer()} | {confirmed, key()}
                | {close, request_outstanding | write_queue_full}.

-type item() :: {request, erx_att:request()} | {write_command, erx_att:handle(), binary()}
              | {unsupported, 0..16#FF} | {invalid, 0..16#FF}.
-record(bearer, {
    mtu = ?ERX_ATT_MTU_DEFAULT :: pos_integer(),
    exchanged = false :: boolean(),
    writes = 0 :: non_neg_integer(),                         % the writes given so far, the last one's ref
    %% The write whose answer the bearer waits for: what answers it, and the change of a
    %% configuration it makes at `ok`.
    awaiting = none :: none | {ref(), command | {request, Opcode :: 0..16#FF, erx_att:handle()},
                               none | {key(), subscription()}},
    waiting = queue:new() :: queue:queue(item()),            % what arrived while a handler answers
    %% The prepared write: its value so far, joined part by part, and whether every part
    %% landed within what the parts before it wrote; so it never holds more than the maximum.
    prepared = none :: none | {erx_att:handle(), key(), Value :: binary(), Placed :: boolean()},
    subscriptions = #{} :: #{key() => subscription()},
    indication = none :: none | key()
}).
-opaque bearer() :: #bearer{}.

%% A request's error, thrown to step/3, which sends it; and a response sent at once.
-define(ERROR(Opcode, Handle, Error), throw({respond, {error, Opcode, Handle, Error}})).
-define(SEND(Response, Bearer), {[{send, erx_att:encode(Response)}], Bearer}).

-doc "A new link's bearer: MTU 23, nothing outstanding, nothing subscribed.".
-spec new() -> bearer().
new() -> #bearer{}.

-doc "The bearer's ATT_MTU.".
-spec mtu(bearer()) -> pos_integer().
mtu(#bearer{mtu = Mtu}) -> Mtu.

-doc "The link's configuration of each characteristic the phone has written, which a bond keeps.".
-spec subscriptions(bearer()) -> #{key() => subscription()}.
subscriptions(#bearer{subscriptions = Subscriptions}) -> Subscriptions.

-doc """
Takes on a bond's kept configuration when the link is encrypted with the bond's key
(docs/design-bluetooth.md, "A link is its bond's only from its encryption"): each
subscription whose characteristic `Table` still declares with that kind, the others left
out, since the table may have changed since the bond kept them. Answers what it took.
""".
-spec restore(#{key() => subscription()}, erx_gatt_db:table(), bearer()) ->
          {#{key() => subscription()}, bearer()}.
restore(Kept, Table, Bearer) ->
    Restored = maps:filter(fun(Key, Kind) -> declared(Key, Kind, Table) end, Kept),
    {Restored, Bearer#bearer{subscriptions = Restored}}.

declared(Key, Kind, Table) when Kind =:= notify; Kind =:= indicate ->
    case erx_gatt_db:characteristic(Key, Table) of
        {ok, #{configuration := Handle} = Info} when Handle =/= none -> maps:get(Kind, Info) =/= none;
        _ -> false
    end;
declared(_Key, _Kind, _Table) ->
    false.

-doc "Takes one PDU from the phone.".
-spec request(binary(), server(), bearer()) -> {[action()], bearer()}.
request(Pdu, Server, #bearer{mtu = Mtu} = Bearer) ->
    case erx_att:decode(Pdu) of
        confirmation -> confirmed(Bearer);
        ignored -> {[], Bearer};
        {write_command, _, _} when byte_size(Pdu) > Mtu -> {[], Bearer};
        {request, _} when byte_size(Pdu) > Mtu -> arrive({invalid, binary:first(Pdu)}, Server, Bearer);
        Item -> arrive(Item, Server, Bearer)
    end.

-doc """
Takes the answer to the write `Ref`: `ok`, or `{error, Code}` with an Application Error
code or `value_not_allowed`. Any other answer, a timeout among them, is Unlikely Error. A
change of a configuration is made at `ok` alone. The answer to a write command sends
nothing, and an answer to a write the bearer no longer waits on changes nothing.
""".
-spec reply(ref(), term(), server(), bearer()) -> {[action()], bearer()}.
reply(Ref, Answer, Server, #bearer{awaiting = {Ref, Answered, Change}} = Bearer) ->
    {Changed, Next} = change(Answer, Change, Bearer#bearer{awaiting = none}),
    drain(response(Answered, Answer) ++ Changed, Server, Next);
reply(_Ref, _Answer, _Server, Bearer) ->
    {[], Bearer}.

%% The response to a write request at its answer; a write command has none.
response(command, _Answer) ->
    [];
response({request, Opcode, Handle}, Answer) ->
    Response = case Answer of
                   ok when Opcode =:= ?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ -> execute_write;
                   ok -> write;
                   {error, Code} when is_integer(Code), Code >= ?ERX_ATT_APPLICATION_ERROR_MIN,
                                      Code =< ?ERX_ATT_APPLICATION_ERROR_MAX -> {error, Opcode, Handle, Code};
                   {error, value_not_allowed} -> {error, Opcode, Handle, value_not_allowed};
                   _ -> {error, Opcode, Handle, unlikely_error}
               end,
    [{send, erx_att:encode(Response)}].

%% A configuration's change, made only at the answer `ok`.
change(ok, {Key, Kind}, #bearer{subscriptions = Subscriptions} = Bearer) ->
    {[{subscribed, Key, Kind}], Bearer#bearer{subscriptions = Subscriptions#{Key => Kind}}};
change(_Answer, _Change, Bearer) ->
    {[], Bearer}.

-doc """
A notification or an indication of `Value` for the characteristic `Key`: `{ok, Pdu,
Bearer}`, the PDU to send, or why it may not be sent. An indication is in flight until the
phone confirms it.
""".
-spec notify(notify | indicate, key(), binary(), server(), bearer()) ->
          {ok, binary(), bearer()} | {error, not_allowed | insufficient_security | not_subscribed | too_long | busy}.
notify(Kind, Key, Value, #{table := Table, security := Security}, #bearer{mtu = Mtu} = Bearer) ->
    case erx_gatt_db:characteristic(Key, Table) of
        {ok, #{Kind := Level, value := Handle}} when Level =/= none ->
            Subscribed = maps:get(Key, Bearer#bearer.subscriptions, none),
            case erx_gatt_gate:check(Level, Security) of
                {error, _} -> {error, insufficient_security};
                ok when Subscribed =/= Kind -> {error, not_subscribed};
                ok when byte_size(Value) > Mtu - 3 -> {error, too_long};
                ok when Kind =:= notify -> {ok, erx_att:encode({notification, Handle, Value}), Bearer};
                ok when Bearer#bearer.indication =/= none -> {error, busy};
                ok -> {ok, erx_att:encode({indication, Handle, Value}), Bearer#bearer{indication = Key}}
            end;
        _ ->
            {error, not_allowed}
    end.

%% A confirmation ends the indication in flight; one with none in flight is dropped.
confirmed(#bearer{indication = none} = Bearer) -> {[], Bearer};
confirmed(#bearer{indication = Key} = Bearer) -> {[{confirmed, Key}], Bearer#bearer{indication = none}}.

%% An item taken at once, or waiting behind the handler's answer.
arrive(Item, Server, #bearer{awaiting = none} = Bearer) ->
    drain(step(Item, Server, Bearer), Server);
arrive(Item, _Server, #bearer{awaiting = {_Ref, Awaited, _Change}, waiting = Waiting} = Bearer) ->
    Requests = [I || I <- queue:to_list(Waiting), is_request(I)],
    Commands = queue:len(Waiting) - length(Requests),
    case is_request(Item) of
        true when Requests =/= []; Awaited =/= command -> {[{close, request_outstanding}], Bearer};
        true -> {[], Bearer#bearer{waiting = queue:in(Item, Waiting)}};
        false when Commands >= ?ERX_BT_WRITE_QUEUE -> {[{close, write_queue_full}], Bearer};
        false -> {[], Bearer#bearer{waiting = queue:in(Item, Waiting)}}
    end.

is_request({write_command, _, _}) -> false;
is_request(_Item) -> true.

%% Steps through what waits while no handler is answering.
drain({Actions, Bearer}, Server) -> drain(Actions, Server, Bearer).

drain(Actions, Server, #bearer{awaiting = none, waiting = Waiting} = Bearer) ->
    case queue:out(Waiting) of
        {{value, Item}, Rest} ->
            {More, Next} = step(Item, Server, Bearer#bearer{waiting = Rest}),
            drain(Actions ++ More, Server, Next);
        {empty, _} ->
            {Actions, Bearer}
    end;
drain(Actions, _Server, Bearer) ->
    {Actions, Bearer}.

%% One item, while no handler is answering. A request's error is thrown to here.
step({request, Request}, Server, Bearer) ->
    try respond(Request, Server, Bearer)
    catch throw:{respond, Error} -> {[{send, erx_att:encode(Error)}], clear(Request, Bearer)}
    end;
step({write_command, Handle, Value}, Server, Bearer) ->
    command(Handle, Value, Server, Bearer);
step({unsupported, Opcode}, _Server, Bearer) ->
    {[{send, erx_att:encode({error, Opcode, 0, request_not_supported})}], Bearer};
step({invalid, Opcode}, _Server, Bearer) ->
    {[{send, erx_att:encode({error, Opcode, 0, invalid_pdu})}], Bearer}.

%% A failed Execute Write discards the prepared write (3.4.6.3); no other error changes the bearer.
clear({execute_write, _}, Bearer) -> Bearer#bearer{prepared = none};
clear(_Request, Bearer) -> Bearer.

respond({exchange_mtu, Client}, _Server, #bearer{exchanged = false, mtu = Old} = Bearer) ->
    Mtu = case Client < ?ERX_ATT_MTU_DEFAULT of
              true -> ?ERX_ATT_MTU_DEFAULT;
              false -> min(Client, erx_l2cap:att_mtu())
          end,
    {[{send, erx_att:encode({exchange_mtu, erx_l2cap:att_mtu()})} | [{mtu, Mtu} || Mtu =/= Old]],
     Bearer#bearer{mtu = Mtu, exchanged = true}};
respond({exchange_mtu, _Client}, _Server, Bearer) ->
    ?SEND({exchange_mtu, erx_l2cap:att_mtu()}, Bearer);
respond({find_information, Start, End}, #{table := Table}, #bearer{mtu = Mtu} = Bearer) ->
    [#{type := First} | _] = Found = found(?ERX_ATT_OPCODE_FIND_INFORMATION_REQ, Start, End, Table, fun(_) -> true end),
    Pairs = [{H, T} || #{handle := H, type := T} <- lists:takewhile(fun(#{type := T}) -> byte_size(T) =:= byte_size(First) end,
                                                                    Found)],
    ?SEND({find_information, fit(Pairs, 2 + byte_size(First), Mtu - 2)}, Bearer);
respond({find_by_type_value, Start, End, Type, Value}, Server, #bearer{mtu = Mtu} = Bearer) ->
    #{table := Table} = Server,
    Matches = fun(#{type := T} = A) ->
                      same_type(T, Type) andalso readable(A, Server, Bearer) =:= ok
                          andalso value(A, Server, Bearer) =:= Value
              end,
    Found = found(?ERX_ATT_OPCODE_FIND_BY_TYPE_VALUE_REQ, Start, End, Table, Matches),
    ?SEND({find_by_type_value, fit([{H, E} || #{handle := H, group_end := E} <- Found], 4, Mtu - 1)}, Bearer);
respond({read_by_type, Start, End, Type}, Server, #bearer{mtu = Mtu} = Bearer) ->
    #{table := Table} = Server,
    Found = found(?ERX_ATT_OPCODE_READ_BY_TYPE_REQ, Start, End, Table, fun(#{type := T}) -> same_type(T, Type) end),
    Values = readable_values(?ERX_ATT_OPCODE_READ_BY_TYPE_REQ, Found, Server, Bearer,
                             min(Mtu - 4, ?ERX_ATT_READ_BY_TYPE_VALUE_MAX)),
    Pairs = [{H, V} || {#{handle := H}, V} <- Values],
    ?SEND({read_by_type, fit(Pairs, 2 + byte_size(element(2, hd(Pairs))), Mtu - 2)}, Bearer);
respond({read_by_group_type, Start, End, Type}, Server, #bearer{mtu = Mtu} = Bearer) ->
    #{table := Table} = Server,
    Opcode = ?ERX_ATT_OPCODE_READ_BY_GROUP_TYPE_REQ,
    valid_range(Opcode, Start, End),
    same_type(Type, <<?ERX_GATT_UUID_PRIMARY_SERVICE:16/little>>)
        orelse same_type(Type, <<?ERX_GATT_UUID_SECONDARY_SERVICE:16/little>>)
        orelse ?ERROR(Opcode, Start, unsupported_group_type),
    Found = found(Opcode, Start, End, Table, fun(#{type := T}) -> same_type(T, Type) end),
    Values = readable_values(Opcode, Found, Server, Bearer, min(Mtu - 6, ?ERX_ATT_READ_BY_GROUP_TYPE_VALUE_MAX)),
    Groups = [{H, E, V} || {#{handle := H, group_end := E}, V} <- Values],
    ?SEND({read_by_group_type, fit(Groups, 4 + byte_size(element(3, hd(Groups))), Mtu - 2)}, Bearer);
respond({read, Handle}, Server, #bearer{mtu = Mtu} = Bearer) ->
    Value = read(?ERX_ATT_OPCODE_READ_REQ, Handle, Server, Bearer),
    ?SEND({read, binary:part(Value, 0, min(byte_size(Value), Mtu - 1))}, Bearer);
respond({read_blob, Handle, Offset}, Server, #bearer{mtu = Mtu} = Bearer) ->
    Value = read(?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle, Server, Bearer),
    Offset =< byte_size(Value) orelse ?ERROR(?ERX_ATT_OPCODE_READ_BLOB_REQ, Handle, invalid_offset),
    ?SEND({read_blob, binary:part(Value, Offset, min(byte_size(Value) - Offset, Mtu - 1))}, Bearer);
respond({write, Handle, Value}, Server, Bearer) ->
    Opcode = ?ERX_ATT_OPCODE_WRITE_REQ,
    #{source := Source, max := Max} = writable(Opcode, Handle, Server),
    byte_size(Value) =< Max orelse ?ERROR(Opcode, Handle, invalid_attribute_value_length),
    case Source of
        {value, Key, _} -> give(Key, Value, {request, Opcode, Handle}, Bearer);
        {configuration, Key} -> subscribe(Handle, Key, Value, Server, Bearer)
    end;
respond({prepare_write, Handle, Offset, Part}, Server, #bearer{prepared = Prepared} = Bearer) ->
    Opcode = ?ERX_ATT_OPCODE_PREPARE_WRITE_REQ,
    #{source := Source, max := Max} = writable(Opcode, Handle, Server),
    Key = case Source of
              {value, K, _} -> K;
              _ -> ?ERROR(Opcode, Handle, write_not_permitted)
          end,
    {Sofar, Placed} = case Prepared of
                          none -> {<<>>, true};
                          {Handle, _, V, P} -> {V, P};
                          _ -> ?ERROR(Opcode, Handle, prepare_queue_full)
                      end,
    %% A part past what the parts before it wrote spoils the value; Execute Write reports it.
    {Joined, Ok} = case Placed andalso Offset =< byte_size(Sofar) of
                       true -> {overwrite(Sofar, Offset, Part), true};
                       false -> {Sofar, false}
                   end,
    byte_size(Joined) =< Max orelse ?ERROR(Opcode, Handle, prepare_queue_full),
    ?SEND({prepare_write, Handle, Offset, Part}, Bearer#bearer{prepared = {Handle, Key, Joined, Ok}});
respond({execute_write, cancel}, _Server, Bearer) ->
    ?SEND(execute_write, Bearer#bearer{prepared = none});
respond({execute_write, write}, _Server, #bearer{prepared = none} = Bearer) ->
    ?SEND(execute_write, Bearer);
respond({execute_write, write}, _Server, #bearer{prepared = {Handle, _Key, _Value, false}}) ->
    ?ERROR(?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, Handle, invalid_offset);
respond({execute_write, write}, _Server, #bearer{prepared = {Handle, Key, Value, true}} = Bearer) ->
    give(Key, Value, {request, ?ERX_ATT_OPCODE_EXECUTE_WRITE_REQ, Handle}, Bearer#bearer{prepared = none}).

%% Gives a write to the characteristic's handler under the next ref, and waits for its answer.
give(Key, Value, Answered, #bearer{writes = Writes} = Bearer) ->
    Ref = Writes + 1,
    {[{write, Ref, Key, Value}], Bearer#bearer{writes = Ref, awaiting = {Ref, Answered, none}}}.

%% A write of a configuration (Part G, 3.3.3.3): answered at once when it changes nothing,
%% otherwise given under the next ref, the change made at its answer.
configure(Key, Kind, Answered, #bearer{subscriptions = Subscriptions, writes = Writes} = Bearer) ->
    case maps:get(Key, Subscriptions, none) of
        Kind ->
            {response(Answered, ok), Bearer};
        _ ->
            Ref = Writes + 1,
            {[{configure, Ref, Key, Kind}], Bearer#bearer{writes = Ref, awaiting = {Ref, Answered, {Key, Kind}}}}
    end.

%% A write command: given to the handler, or a configuration changed, when a Write Request
%% would be, and otherwise ignored (3.4.5.3).
command(Handle, Value, #{table := Table, security := Security}, Bearer) ->
    case erx_gatt_db:lookup(Handle, Table) of
        {ok, #{command := Level, source := {value, Key, _}, max := Max}}
          when Level =/= none, byte_size(Value) =< Max ->
            case erx_gatt_gate:check(Level, Security) of
                ok -> give(Key, Value, command, Bearer);
                {error, _} -> {[], Bearer}
            end;
        {ok, #{write := Level, source := {configuration, Key} = Source}} when Level =/= none ->
            case {erx_gatt_gate:check(write_level(Source, Level, Security), Security),
                  subscription(Key, Value, Table)} of
                {ok, {ok, Kind}} -> configure(Key, Kind, command, Bearer);
                _ -> {[], Bearer}
            end;
        _ ->
            {[], Bearer}
    end.

%% A Write Request of a configuration, with its errors.
subscribe(Handle, Key, Value, #{table := Table}, Bearer) ->
    case subscription(Key, Value, Table) of
        {ok, Kind} -> configure(Key, Kind, {request, ?ERX_ATT_OPCODE_WRITE_REQ, Handle}, Bearer);
        {error, Error} -> ?ERROR(?ERX_ATT_OPCODE_WRITE_REQ, Handle, Error)
    end.

%% The subscription a configuration's value asks for (Part G, 3.3.3.3): two octets, whose
%% notification or indication bit only a characteristic that allows it may set, and not both.
subscription(_Key, Value, _Table) when byte_size(Value) =/= 2 ->
    {error, invalid_attribute_value_length};
subscription(Key, <<Bits:16/little>>, Table) ->
    {ok, Info} = erx_gatt_db:characteristic(Key, Table),
    case Bits band (?ERX_GATT_CONFIGURATION_NOTIFY bor ?ERX_GATT_CONFIGURATION_INDICATE) of
        0 -> {ok, none};
        ?ERX_GATT_CONFIGURATION_NOTIFY when map_get(notify, Info) =/= none -> {ok, notify};
        ?ERX_GATT_CONFIGURATION_INDICATE when map_get(indicate, Info) =/= none -> {ok, indicate};
        _ -> {error, value_not_allowed}
    end.

%% A range request's handles (3.4.3.1 and the like): Invalid Handle unless 0 < Start =< End.
valid_range(Opcode, Start, End) when Start =:= 0; Start > End -> ?ERROR(Opcode, Start, invalid_handle);
valid_range(_Opcode, _Start, _End) -> ok.

%% The attributes of a range that `Matches` keeps, Attribute Not Found if there are none.
found(Opcode, Start, End, Table, Matches) ->
    valid_range(Opcode, Start, End),
    case lists:filter(Matches, erx_gatt_db:range(Start, End, Table)) of
        [] -> ?ERROR(Opcode, Start, attribute_not_found);
        Found -> Found
    end.

%% Read By Type's and Read By Group Type's rule (3.4.4.1, 3.4.4.9): the first attribute's
%% error is the answer; otherwise the attributes up to the first that cannot be read, each
%% value cut to `Cut`, as many as have the first's length.
readable_values(Opcode, [#{handle := First} = A | _] = Found, Server, Bearer, Cut) ->
    case readable(A, Server, Bearer) of
        {error, Error} -> ?ERROR(Opcode, First, Error);
        ok -> ok
    end,
    Values = [{F, cut(value(F, Server, Bearer), Cut)}
              || F <- lists:takewhile(fun(F) -> readable(F, Server, Bearer) =:= ok end, Found)],
    [{_, V} | _] = Values,
    lists:takewhile(fun({_, W}) -> byte_size(W) =:= byte_size(V) end, Values).

%% A read of one attribute's value, with its errors.
read(Opcode, Handle, #{table := Table} = Server, Bearer) ->
    case erx_gatt_db:lookup(Handle, Table) of
        error -> ?ERROR(Opcode, Handle, invalid_handle);
        {ok, Attribute} ->
            case readable(Attribute, Server, Bearer) of
                ok -> value(Attribute, Server, Bearer);
                {error, Error} -> ?ERROR(Opcode, Handle, Error)
            end
    end.

readable(#{read := none}, _Server, _Bearer) -> {error, read_not_permitted};
readable(#{read := Level}, #{security := Security}, _Bearer) -> erx_gatt_gate:check(Level, Security).

%% The attribute `Handle` when a write of it is allowed, with its errors.
writable(Opcode, Handle, #{table := Table, security := Security}) ->
    case erx_gatt_db:lookup(Handle, Table) of
        error -> ?ERROR(Opcode, Handle, invalid_handle);
        {ok, #{write := none}} -> ?ERROR(Opcode, Handle, write_not_permitted);
        {ok, #{write := Level, source := Source} = Attribute} ->
            case erx_gatt_gate:check(write_level(Source, Level, Security), Security) of
                ok -> Attribute;
                {error, Error} -> ?ERROR(Opcode, Handle, Error)
            end
    end.

%% A configuration write is a write of the state a bond keeps, which the server may guard
%% (Part G, 3.3.3.3): on a link that holds a key it requires at least `encrypted`, so until
%% the link is encrypted with that key it is Insufficient Encryption and the configuration
%% stays the link's default (docs/design-bluetooth.md, "A link is its bond's only from its
%% encryption").
write_level({configuration, _Key}, open, #{key := Key}) when Key =/= none -> encrypted;
write_level(_Source, Level, _Security) -> Level.

value(#{source := {constant, Value}}, _Server, _Bearer) ->
    Value;
value(#{source := {value, Key, Initial}}, #{values := Values}, _Bearer) ->
    maps:get(Key, Values, Initial);
value(#{source := {configuration, Key}}, _Server, #bearer{subscriptions = Subscriptions}) ->
    Bits = case maps:get(Key, Subscriptions, none) of
               none -> 0;
               notify -> ?ERX_GATT_CONFIGURATION_NOTIFY;
               indicate -> ?ERX_GATT_CONFIGURATION_INDICATE
           end,
    <<Bits:16/little>>.

%% ATT compares types as 128-bit UUIDs (3.4.4.1).
same_type(A, B) -> erx_att:uuid128(A) =:= erx_att:uuid128(B).

cut(Value, Max) -> binary:part(Value, 0, min(byte_size(Value), Max)).

%% The leading entries of `Size` octets each that fit in `Budget`; one always fits.
fit(Entries, Size, Budget) -> lists:sublist(Entries, max(1, Budget div Size)).

%% `Acc` with `Part` written at `Offset`, which is at most its length.
overwrite(Acc, Offset, Part) ->
    End = Offset + byte_size(Part),
    <<(binary:part(Acc, 0, Offset))/binary, Part/binary,
      (binary:part(Acc, min(End, byte_size(Acc)), max(0, byte_size(Acc) - End)))/binary>>.
