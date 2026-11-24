%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_serial).
-moduledoc """
The serial service (docs/design-bluetooth.md, "Stage 3: the serial service", "For
apps" and "The console"): the handler of one declared service of the serial shape, a
characteristic `rx` a phone writes and `tx` the machine notifies, such as `nus`
(abi/gatt/nus.txt) or the phone console's `console`. It is an erx_gatt_service
registered under this module's name, so a domain runs one, which turns its service,
and no other, into a byte stream for each phone.

* Each write of `rx` is answered `ok` at once and becomes `{serial, Conn, Bytes}` to the
  owner, while the owner's queue holds fewer than `bt_write_queue` messages; past that
  the write is answered the Application Error `?OWNER_BUSY` and its bytes are dropped,
  so a phone that writes faster than the owner reads cannot grow the owner's queue
  without bound, and the owner is sent `{serial_lost, Conn}` in their place, once for each
  run of drops, so it always knows where its stream has a gap. The owner also hears
  `{connected, Conn, Info}`, `Info` as erx_gatt's `connected` event gives it,
  `{subscribed, Conn, Char, Kind}`, dropped while the owner's queue is past
  `bt_write_queue` as a write's bytes are, and `{disconnected, Conn}`.
* send/2 cuts its bytes into notifications of `tx` of at most `Mtu - 3` octets each,
  `Mtu` the link's bearer MTU as its last `mtu` event gave it, 23 until one comes, and
  returns once all are queued for the link, in order. A notification refused `busy`, the
  link's queue being full, is asked again every `?BUSY_RETRY_MS` until the queue takes it,
  for at most `bt_handler_timeout_ms`; past that send/2 answers `{error, busy}` and the
  rest of the bytes are not sent. `{error, gone}` answers a link that has ended.

The stream never loses bytes without saying so: a gap is a `serial_lost` or the stream's
end, since a phone whose write commands outrun its link loses the link past the link's
own `bt_write_queue` (docs/design-bluetooth.md, "For apps"). The handler ends with its
owner.
""".

-behaviour(erx_gatt_service).

-include("generated/erx_abi.hrl").

-export([start_link/2, send/2]).
-export([init/2, handle_write/4, handle_event/2, handle_call/3, handle_info/2]).

%% How often a notification the link's full queue refused is asked again.
-define(BUSY_RETRY_MS, 5).
%% The Application Error a write of rx is answered while the owner is behind.
-define(OWNER_BUSY, ?ERX_ATT_APPLICATION_ERROR_MIN).

%% lost: the links whose last write was dropped, so the owner has heard of the run of
%% drops it began.
-record(serial, {service :: atom(), owner :: pid(), mtus = #{} :: #{reference() => pos_integer()},
                 lost = #{} :: #{reference() => true}}).

-doc """
Starts the handler of `Service`, linked to the caller, for `Owner`, which hears the
stream. The facet refuses a service its grant does not name, and the start refuses
`{not_serial, Service}` a service without the serial shape: an `rx` a phone writes, with or
without a response, and a `tx` the machine notifies.
""".
-spec start_link(atom(), pid()) -> gen_server:start_ret().
start_link(Service, Owner) when is_atom(Service), is_pid(Owner) ->
    erx_gatt_service:start_link({local, ?MODULE}, Service, ?MODULE, {Service, Owner}).

-doc """
Sends `Bytes` to the phone of link `Conn` as notifications of `tx`. A handler that is
not running, or ends during the send, answers `{error, gone}`, so the caller's exit
never carries the bytes.
""".
-spec send(reference(), binary()) -> ok | {error, busy | gone | atom()}.
send(Conn, Bytes) when is_reference(Conn), is_binary(Bytes) ->
    try erx_gatt_service:call(?MODULE, {send, Conn, Bytes})
    catch exit:_ -> {error, gone}
    end.

-doc false.
init({Service, Owner}, Table) ->
    case serial_shape(Table) of
        true ->
            erlang:monitor(process, Owner),
            {ok, #{}, #serial{service = Service, owner = Owner}};
        false ->
            {error, {not_serial, Service}}
    end.

%% Whether the attached characteristics are a serial line's: rx and tx alone, rx taking a
%% write of either kind and tx a notification and no write, so every write a phone can
%% make is one of rx.
serial_shape(#{rx := #{access := Rx}, tx := #{access := Tx}} = Table) when map_size(Table) =:= 2 ->
    (is_map_key(write, Rx) orelse is_map_key(write_without_response, Rx)) andalso is_map_key(notify, Tx)
        andalso not (is_map_key(write, Tx) orelse is_map_key(write_without_response, Tx));
serial_shape(_Table) ->
    false.

-doc false.
handle_write(Conn, rx, Bytes, #serial{owner = Owner, lost = Lost} = Serial) ->
    case keeps_up(Owner) of
        true ->
            Owner ! {serial, Conn, Bytes},
            {ok, Serial#serial{lost = maps:remove(Conn, Lost)}};
        _Behind when is_map_key(Conn, Lost) ->
            {{error, ?OWNER_BUSY}, Serial};
        _Behind ->
            Owner ! {serial_lost, Conn},
            {{error, ?OWNER_BUSY}, Serial#serial{lost = Lost#{Conn => true}}}
    end.

-doc false.
handle_event({connected, Conn, Info}, #serial{owner = Owner} = Serial) ->
    Owner ! {connected, Conn, Info},
    {ok, Serial};
handle_event({mtu, Conn, Mtu}, #serial{mtus = Mtus} = Serial) ->
    {ok, Serial#serial{mtus = Mtus#{Conn => Mtu}}};
handle_event({disconnected, Conn}, #serial{owner = Owner, mtus = Mtus, lost = Lost} = Serial) ->
    Owner ! {disconnected, Conn},
    {ok, Serial#serial{mtus = maps:remove(Conn, Mtus), lost = maps:remove(Conn, Lost)}};
handle_event({subscribed, _Conn, _Char, _Kind} = Subscribed, #serial{owner = Owner} = Serial) ->
    _ = keeps_up(Owner) andalso (Owner ! Subscribed),
    {ok, Serial}.

%% Whether the owner's queue holds fewer than bt_write_queue messages, so what a phone
%% sends cannot grow it without bound.
keeps_up(Owner) ->
    case process_info(Owner, message_queue_len) of
        {message_queue_len, Queued} -> Queued < ?ERX_BT_WRITE_QUEUE;
        undefined -> false
    end.

-doc false.
handle_call({send, Conn, Bytes}, _From, #serial{service = Service, mtus = Mtus} = Serial) ->
    Room = maps:get(Conn, Mtus, ?ERX_ATT_MTU_DEFAULT) - 3,
    Deadline = erlang:monotonic_time(millisecond) + ?ERX_BT_HANDLER_TIMEOUT_MS,
    {reply, notify_all(Conn, Service, Bytes, Room, Deadline), Serial}.

-doc false.
handle_info({'DOWN', _Monitor, process, Owner, _Reason}, #serial{owner = Owner}) ->
    exit(normal);
handle_info(_Info, Serial) ->
    {ok, Serial}.

%% Notifies Bytes on tx of link Conn's Service in pieces of at most Room octets, each
%% once the link's queue takes it.
notify_all(_Conn, _Service, <<>>, _Room, _Deadline) ->
    ok;
notify_all(Conn, Service, Bytes, Room, Deadline) ->
    Size = min(Room, byte_size(Bytes)),
    <<Piece:Size/binary, Rest/binary>> = Bytes,
    case notify(Conn, Service, Piece, Deadline) of
        ok -> notify_all(Conn, Service, Rest, Room, Deadline);
        {error, _} = Refusal -> Refusal
    end.

notify(Conn, Service, Piece, Deadline) ->
    case erx_gatt:notify(Conn, Service, tx, Piece) of
        {error, busy} = Busy ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(?BUSY_RETRY_MS), notify(Conn, Service, Piece, Deadline);
                false -> Busy
            end;
        Answer ->
            Answer
    end.
