%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The virtio-input driver's pure core (docs/design-display.md, "The display device"):
%% the parse of every byte the device writes, its event records and its configuration
%% space, and the identification of the device as a keyboard, a mouse or a tablet from
%% that configuration. Every value and size comes from abi/formats/virtio.txt through the
%% generated erx_abi.hrl (OASIS Virtio 1.2, section 5.8; evdev's values from FreeBSD's
%% sys/dev/evdev at release/14.1.0); the bit syntax lays each layout out field by field,
%% and a compile-time check below fails the build if the generated offsets ever disagree
%% with it.
%%
%% Everything here reads bytes a device wrote, so it is untrusted input. Each parse
%% matches the exact layout or answers with a tagged reason; none of them raises on any
%% binary, which test/erlang/erx_virtio_input_core_fuzz.erl checks.
%%
%% event/1 reads one buffer of the event queue. An event the driver uses becomes one of
%% the closed set event() names, so the driver's next stage matches named atoms and never
%% a raw code; an event it does not use is dropped with its reason, as section 5.8.6.1
%% asks ("A driver SHOULD ignore eventq input events it does not recognize"). A record of
%% the wrong length is an error: the device broke the layout.
%%
%% config/3 reads the configuration space after the driver wrote select and subsel
%% (section 5.8.4); bits/1 and absinfo/1 read its data as a bitmap or one axis. queries/0
%% is the list of reads identify/1 needs, which the driver performs in any order and hands
%% back as a map from each query to the bytes it read.

-module(erx_virtio_input_core).

-export([event/1, config/3, bits/1, absinfo/1, queries/0, identify/1]).

-export_type([event/0, drop/0, query/0, axis/0, class/0, unidentified/0]).

-include("generated/erx_abi.hrl").

%% The generated layouts, as the bit syntax below lays them out.
-if(?ERX_VIRTIO_INPUT_EVENT_OFF_CODE =/= 2 orelse ?ERX_VIRTIO_INPUT_EVENT_OFF_VALUE =/= 4
    orelse ?ERX_VIRTIO_INPUT_EVENT_SIZE =/= 8
    orelse ?ERX_VIRTIO_INPUT_CONFIG_OFF_SUBSEL =/= 1 orelse ?ERX_VIRTIO_INPUT_CONFIG_OFF_SIZE =/= 2
    orelse ?ERX_VIRTIO_INPUT_CONFIG_OFF_DATA =/= 8 orelse ?ERX_VIRTIO_INPUT_CONFIG_SIZE =/= 136
    orelse ?ERX_VIRTIO_INPUT_CONFIG_OFF_DATA + ?ERX_VIRTIO_INPUT_CONFIG_DATA_MAX =/= ?ERX_VIRTIO_INPUT_CONFIG_SIZE
    orelse ?ERX_VIRTIO_INPUT_ABSINFO_OFF_MAX =/= 4 orelse ?ERX_VIRTIO_INPUT_ABSINFO_OFF_FUZZ =/= 8
    orelse ?ERX_VIRTIO_INPUT_ABSINFO_OFF_FLAT =/= 12 orelse ?ERX_VIRTIO_INPUT_ABSINFO_OFF_RES =/= 16
    orelse ?ERX_VIRTIO_INPUT_ABSINFO_SIZE =/= 20).
-error("erx_virtio_input_core's bit syntax disagrees with abi/formats/virtio.txt").
-endif.

-doc """
One event the driver uses: the end of one update (`report`) or the device's word that it
dropped events since the last one (`dropped`); a key or button by its evdev code going up,
down or repeating; a move of a relative axis; a position on an absolute axis.
""".
-type event() :: {syn, report | dropped}
               | {key, Code :: 0..?ERX_EVDEV_KEY_MAX, up | down | repeat}
               | {rel, x | y | wheel, Delta :: -16#80000000..16#7fffffff}
               | {abs, x | y, Value :: -16#80000000..16#7fffffff}.
-doc "Why event/1 dropped a well-formed record: its type, or its code or value within the type.".
-type drop() :: {type, 0..16#ffff}
              | {syn, Code :: 0..16#ffff}
              | {key, Code :: 0..16#ffff, Value :: integer()}
              | {rel, Code :: 0..16#ffff}
              | {abs, Code :: 0..16#ffff}.
-doc "One read of the configuration space: the select and subsel the driver writes.".
-type query() :: {Select :: 0..255, Subsel :: 0..255}.
-doc "One absolute axis, as VIRTIO_INPUT_CFG_ABS_INFO answers it, with min below max.".
-type axis() :: #{min := integer(), max := integer(), fuzz := integer(), flat := integer(),
                  res := integer()}.
-doc "What the device is: a keyboard, a mouse, or a tablet with its two axes.".
-type class() :: keyboard | mouse | {tablet, X :: axis(), Y :: axis()}.
-doc """
Why identify/1 could not say what the device is: a query it was not handed, a read that
did not parse, or codes that make no class, as the three bitmaps' codes.
""".
-type unidentified() :: {missing, query()}
                      | {query(), term()}
                      | {class, Key :: [non_neg_integer()], Rel :: [non_neg_integer()],
                         Abs :: [non_neg_integer()]}.

-doc """
The event in one buffer of the event queue, Bytes being what the device wrote (the used
ring's length of it). The driver posts each buffer at exactly one event's size, so another
length means the device broke the layout. A record of another length than the layout's is `{error, {length,
N}}`; a well-formed record the driver does not use is `{drop, Why}`.
""".
-spec event(binary()) -> {ok, event()} | {drop, drop()} | {error, {length, non_neg_integer()}}.
event(<<Type:16/little, Code:16/little, Value:32/little-signed>>) -> typed(Type, Code, Value);
event(Bytes) -> {error, {length, byte_size(Bytes)}}.

typed(?ERX_EVDEV_EV_SYN, ?ERX_EVDEV_SYN_REPORT, _) -> {ok, {syn, report}};
typed(?ERX_EVDEV_EV_SYN, ?ERX_EVDEV_SYN_DROPPED, _) -> {ok, {syn, dropped}};
typed(?ERX_EVDEV_EV_SYN, Code, _) -> {drop, {syn, Code}};
typed(?ERX_EVDEV_EV_KEY, Code, Value) when Code =< ?ERX_EVDEV_KEY_MAX ->
    %% The key values are FreeBSD's enum evdev_key_events, sys/dev/evdev/evdev_private.h.
    case Value of
        0 -> {ok, {key, Code, up}};
        1 -> {ok, {key, Code, down}};
        2 -> {ok, {key, Code, repeat}};
        _ -> {drop, {key, Code, Value}}
    end;
typed(?ERX_EVDEV_EV_KEY, Code, Value) -> {drop, {key, Code, Value}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_X, Delta) -> {ok, {rel, x, Delta}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_Y, Delta) -> {ok, {rel, y, Delta}};
typed(?ERX_EVDEV_EV_REL, ?ERX_EVDEV_REL_WHEEL, Delta) -> {ok, {rel, wheel, Delta}};
typed(?ERX_EVDEV_EV_REL, Code, _) -> {drop, {rel, Code}};
typed(?ERX_EVDEV_EV_ABS, ?ERX_EVDEV_ABS_X, Value) -> {ok, {abs, x, Value}};
typed(?ERX_EVDEV_EV_ABS, ?ERX_EVDEV_ABS_Y, Value) -> {ok, {abs, y, Value}};
typed(?ERX_EVDEV_EV_ABS, Code, _) -> {drop, {abs, Code}};
typed(Type, _, _) -> {drop, {type, Type}}.

-doc """
The data of the configuration space Bytes, read whole after the driver wrote Select and
Subsel: the first `size` bytes after the header, empty when the device has nothing for
that query (section 5.8.5.2). The header must still name the query, and `size` must fit
the data area.
""".
-spec config(0..255, 0..255, binary()) ->
          {ok, binary()}
        | {error, {length, non_neg_integer()} | {query, query()} | {size, 0..255}}.
%% Select and Subsel are already bound, so this clause takes only a read whose header
%% names the query asked.
config(Select, Subsel, <<Select:8, Subsel:8, Size:8, _:5/binary, Data:?ERX_VIRTIO_INPUT_CONFIG_DATA_MAX/binary>>) ->
    case Size =< ?ERX_VIRTIO_INPUT_CONFIG_DATA_MAX of
        true -> {ok, binary:part(Data, 0, Size)};
        false -> {error, {size, Size}}
    end;
config(_Select, _Subsel, <<SaidSelect:8, SaidSubsel:8, _/binary>> = Bytes)
  when byte_size(Bytes) =:= ?ERX_VIRTIO_INPUT_CONFIG_SIZE ->
    {error, {query, {SaidSelect, SaidSubsel}}};
config(_Select, _Subsel, Bytes) -> {error, {length, byte_size(Bytes)}}.

-doc """
The codes a bitmap answer sets, in order: bit N of the bitmap is bit N rem 8 of byte
N div 8, the bytes of FreeBSD's bitstring(3) words (sys/sys/bitstring.h) on a
little-endian machine, which its EVIOCGBIT copies out (sys/dev/evdev/cdev.c).
""".
-spec bits(binary()) -> ordsets:ordset(non_neg_integer()).
bits(Data) ->
    [Index * 8 + Bit || {Index, Byte} <- lists:enumerate(0, binary_to_list(Data)),
                        Bit <- lists:seq(0, 7), Byte band (1 bsl Bit) =/= 0].

-doc "One axis from an ABS_INFO answer, which must hold the whole layout and min below max.".
-spec absinfo(binary()) -> {ok, axis()} | {error, {absinfo, binary()}}.
absinfo(<<Min:32/little-signed, Max:32/little-signed, Fuzz:32/little-signed, Flat:32/little-signed,
          Res:32/little-signed, _/binary>>) when Min < Max ->
    {ok, #{min => Min, max => Max, fuzz => Fuzz, flat => Flat, res => Res}};
absinfo(Data) -> {error, {absinfo, Data}}.

-doc "The configuration reads identify/1 needs, as the driver writes select and subsel.".
-spec queries() -> [query()].
queries() ->
    [{?ERX_VIRTIO_INPUT_CFG_EV_BITS, ?ERX_EVDEV_EV_KEY}, {?ERX_VIRTIO_INPUT_CFG_EV_BITS, ?ERX_EVDEV_EV_REL},
     {?ERX_VIRTIO_INPUT_CFG_EV_BITS, ?ERX_EVDEV_EV_ABS}, {?ERX_VIRTIO_INPUT_CFG_ABS_INFO, ?ERX_EVDEV_ABS_X},
     {?ERX_VIRTIO_INPUT_CFG_ABS_INFO, ?ERX_EVDEV_ABS_Y}].

-doc """
What the device is, from the configuration bytes read for each of queries/0. A device
with both absolute axes and a pointer's button (BTN_LEFT or BTN_TOUCH; a joystick has
neither) is a tablet, one with both relative axes a mouse, and one with a
key below the buttons (a code below BTN_MISC, other than KEY_RESERVED) a keyboard, in that
order, so a pointer with keys is a pointer. Anything else, or a read that does not parse,
is an error naming the query.
""".
-spec identify(#{query() => binary()}) -> {ok, class()} | {error, unidentified()}.
identify(Read) ->
    maybe
        {ok, Key} ?= ev_bits(?ERX_EVDEV_EV_KEY, Read),
        {ok, Rel} ?= ev_bits(?ERX_EVDEV_EV_REL, Read),
        {ok, Abs} ?= ev_bits(?ERX_EVDEV_EV_ABS, Read),
        class(Key, Rel, Abs, Read)
    end.

class(Key, Rel, Abs, Read) ->
    Button = lists:member(?ERX_EVDEV_BTN_LEFT, Key) orelse lists:member(?ERX_EVDEV_BTN_TOUCH, Key),
    Tablet = Button andalso both(?ERX_EVDEV_ABS_X, ?ERX_EVDEV_ABS_Y, Abs),
    Mouse = both(?ERX_EVDEV_REL_X, ?ERX_EVDEV_REL_Y, Rel),
    Keyboard = lists:any(fun(Code) -> Code > 0 andalso Code < ?ERX_EVDEV_BTN_MISC end, Key),
    if
        Tablet ->
            maybe
                {ok, X} ?= axis(?ERX_EVDEV_ABS_X, Read),
                {ok, Y} ?= axis(?ERX_EVDEV_ABS_Y, Read),
                {ok, {tablet, X, Y}}
            end;
        Mouse -> {ok, mouse};
        Keyboard -> {ok, keyboard};
        true -> {error, {class, Key, Rel, Abs}}
    end.

both(A, B, Codes) -> lists:member(A, Codes) andalso lists:member(B, Codes).

ev_bits(Type, Read) ->
    maybe
        {ok, Data} ?= answer({?ERX_VIRTIO_INPUT_CFG_EV_BITS, Type}, Read),
        {ok, bits(Data)}
    end.

axis(Code, Read) ->
    Query = {?ERX_VIRTIO_INPUT_CFG_ABS_INFO, Code},
    maybe
        {ok, Data} ?= answer(Query, Read),
        {ok, _} ?= tagged(Query, absinfo(Data))
    end.

%% The data of one query's read, or the error naming that query.
answer({Select, Subsel} = Query, Read) ->
    case Read of
        #{Query := Bytes} -> tagged(Query, config(Select, Subsel, Bytes));
        #{} -> {error, {missing, Query}}
    end.

tagged(_Query, {ok, _} = Ok) -> Ok;
tagged(Query, {error, Reason}) -> {error, {Query, Reason}}.
