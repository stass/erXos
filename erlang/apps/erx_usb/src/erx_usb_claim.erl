%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_claim).
-moduledoc """
Which interfaces of a configured device the USB domain drives, and the
parameters of each pipe it claims (docs/design-usb.md, "What the USB
domain claims" and "Descriptors"). functions/3 is the claim table, one
pure function of the device's speed and its device and configuration
descriptors as `erx_usb_desc` decodes them; parameters/2 derives the
four values an endpoint context takes from one bulk or interrupt
endpoint descriptor, the only kinds a function claims, and the device's
speed.

The table names an interface by its alternate setting 0. A hub is a
device of device class 09h, as FreeBSD's `uhub_probe` matches it
(sys/dev/usb/usb_hub.c:1134-1136, release/15.1.0, 95719d8a), and gets one
function, on interface 0, the interface `uhub_attach` selects a setting
of (:1252-1253): at full or high speed it takes that interface's first
interrupt-IN endpoint, in alternate setting 1 when the device protocol is
the multi-TT hub's (:1252-1258) and in 0 otherwise, whatever the
interface's own class; at SuperSpeed it runs none. An interface of class
09h on a device of another class is not a hub. Otherwise HID (class 03h)
takes its first interrupt-IN endpoint, and mass storage over SCSI and
Bulk-Only (08h, 06h, 50h) its first bulk-IN and first bulk-OUT endpoint;
a device whose quirks (`erx_usb_quirks`, design-usb.md, "Device quirks")
force SCSI or Bulk-Only has that interface taken as such whatever its
subclass or protocol, and with both forced whatever its class, as
FreeBSD's `umass_probe_proto` takes it (sys/dev/usb/storage/umass.c:862-898,
release/15.1.0). Every function carries the device's quirks, which the
mass-storage function alone reads.
Every other interface runs no function, and so does one whose
selected setting lacks an endpoint its function needs. A setting the table
selects that the configuration lacks refuses it (`missing_setting`); so
does, at SuperSpeed, an endpoint descriptor of any setting without its
companion (`missing_companion`), an endpoint address that appears twice
among the claimed settings (`duplicate_endpoint`), so no two functions
share a pipe, and more claimed pipes than `usb_endpoints_max` holds
with EP0 (`too_many_endpoints`).

An endpoint's parameters, by its type and the device's speed:

* the packet size, bits 10:0 of `wMaxPacketSize` through FreeBSD's filter
  of standard sizes (`usbd_get_std_packet_size`,
  sys/dev/usb/usb_transfer.c:3525-3591, applied at :569-592). The bits
  are taken at every speed, where FreeBSD masks them only at high and
  SuperSpeed (:517). A size of 0 is refused (`zero_interval_payload`)
  on every endpoint: FreeBSD raises it to the controller's largest
  packet first (:563-567), a guess this module does not make;
* the burst, zero-based: the companion's `bMaxBurst` at SuperSpeed, at
  most `usb_burst_max`; bits 12:11 of `wMaxPacketSize` on a high-speed
  interrupt endpoint, at most `usb_packet_extra_max`, where FreeBSD
  clamps 3 to 2 (:502-513); 0 otherwise. A value past either bound is one
  the device cannot mean, and refuses the device (`malformed_descriptor`);
* the payload of one service interval: the packet size times the burst
  plus one, except on a SuperSpeed interrupt endpoint, where it is the
  companion's `wBytesPerInterval`, refused (`endpoint_too_large`) above
  that product or `usb_ss_interrupt_payload_max`. A payload of 0 is
  refused (`zero_interval_payload`), and one past the buffer of the queue
  block the endpoint's type takes is refused (`endpoint_too_large`);
* the interval exponent, xHCI's Interval field (xHCI 1.2, 6.2.3.6 and
  Table 6-12, p. 456): on an interrupt endpoint at low and full speed,
  where `bInterval` counts milliseconds, the base-2 logarithm of
  `bInterval` times 8 rounded down; at high and SuperSpeed `bInterval`
  less one. A `bInterval` outside the table's range, 0 at any speed or
  above 16 at high and SuperSpeed, refuses the device
  (`malformed_descriptor`). A bulk endpoint's is 0, as FreeBSD sets the
  field only for periodic endpoints (sys/dev/usb/controller/xhci.c:2463-2470).

Every bound comes from `abi/formats/usb.txt` and `abi/formats/xhci.txt`.
Both entries answer `{ok, Value}` or `{error, Reason}`; every refusal
leaves through one `throw` caught in claimed/1.
""".

-export([functions/3, parameters/2]).

-export_type([speed/0, driver/0, pipe/0, function_/0, reason/0]).

-include("generated/erx_abi.hrl").

-doc "The device's speed, as its port reports it.".
-type speed() :: low | full | high | super.

-doc "The module that runs a claimed function.".
-type driver() :: erx_usb_hid | erx_usb_bot | erx_usb_hub.

-doc """
One pipe a function claims: its endpoint's address and type, its packet
size, zero-based burst, payload of one service interval, and the base-2
exponent of that interval in 125 us units.
""".
-type pipe() :: #{address := byte(),
                  type := bulk | interrupt,
                  packet_size := 1..?ERX_USB_BULK_PACKET_SUPER,
                  burst := 0..?ERX_USB_BURST_MAX,
                  payload := 1..?ERX_XHCI_BULK_BUFFER_SIZE,
                  interval_exponent := 0..(?ERX_XHCI_INTERVAL_BINTERVAL_MAX - 1)}.

-doc "One claimed function: its driver, the interface and setting it runs on, that setting, its pipes in the order its driver needs them, and its device's quirks.".
-type function_() :: #{driver := driver(),
                       interface := byte(),
                       alternate := byte(),
                       setting := erx_usb_desc:setting(),
                       pipes := [pipe()],
                       quirks := [erx_usb_quirks:kind()]}.

-type reason() :: missing_setting | missing_companion | duplicate_endpoint | too_many_endpoints
                | malformed_descriptor | endpoint_too_large | zero_interval_payload.

-type need() :: {bulk | interrupt, in | out}.

-doc "The functions the device runs, in interface order, or the reason its configuration is refused.".
-spec functions(speed(), erx_usb_desc:device(), erx_usb_desc:configuration()) ->
          {ok, [function_()]} | {error, reason()}.
functions(Speed, Device, #{settings := Settings}) ->
    claimed(fun() -> admitted(claim(Speed, Device, Settings), Speed, Settings) end).

-doc "The parameters of one bulk or interrupt endpoint of a device at Speed, or the reason it is refused.".
-spec parameters(speed(), erx_usb_desc:endpoint()) -> {ok, pipe()} | {error, reason()}.
parameters(Speed, Endpoint) ->
    claimed(fun() -> pipe(Speed, Endpoint) end).

-spec claimed(fun(() -> Value)) -> {ok, Value} | {error, reason()}.
claimed(Claim) ->
    try
        {ok, Claim()}
    catch
        throw:{?MODULE, Reason} -> {error, Reason}
    end.

-spec refuse(reason()) -> no_return().
refuse(Reason) -> throw({?MODULE, Reason}).

check(true, _Reason) -> ok;
check(false, Reason) -> refuse(Reason).

%% The configuration-wide rules over the functions claimed: companions at
%% SuperSpeed, one claimant per endpoint address, and the endpoint bound.
admitted(Functions, Speed, Settings) ->
    check(Speed =/= super orelse
              lists:all(fun(#{companion := C}) -> C =/= none end,
                        [E || #{endpoints := Es} <- maps:values(Settings), E <- Es]),
          missing_companion),
    Addresses = [A || #{setting := #{endpoints := Es}} <- Functions, #{address := A} <- Es],
    check(length(Addresses) =:= map_size(maps:from_keys(Addresses, [])), duplicate_endpoint),
    Pipes = [P || #{pipes := Ps} <- Functions, P <- Ps],
    check(length(Pipes) + 1 =< ?ERX_USB_ENDPOINTS_MAX, too_many_endpoints),
    Functions.

claim(Speed, Device = #{vendor := Vendor, product := Product, release := Release}, Settings) ->
    Interfaces = lists:usort([Number || {Number, 0} <- maps:keys(Settings)]),
    Quirks = erx_usb_quirks:lookup(Vendor, Product, Release),
    [Function || Number <- Interfaces,
                 Function <- interface_function(Speed, Device, Quirks, Number, Settings)].

%% The table, then the setting it selects and the endpoints its driver needs.
interface_function(Speed, Device, Quirks, Number, Settings) ->
    case driver(Speed, Device, Quirks, Number, map_get({Number, 0}, Settings)) of
        none ->
            [];
        {Driver, Alternate, Needs} ->
            Setting = selected(maps:find({Number, Alternate}, Settings)),
            case endpoints(Needs, Setting) of
                none ->
                    [];
                Endpoints ->
                    [#{driver => Driver, interface => Number, alternate => Alternate,
                       setting => Setting, pipes => [pipe(Speed, E) || E <- Endpoints], quirks => Quirks}]
            end
    end.

selected({ok, Setting}) -> Setting;
selected(error) -> refuse(missing_setting).

%% A hub device's interface 0 by the device's class alone; every other
%% interface by its alternate setting 0.
-spec driver(speed(), erx_usb_desc:device(), [erx_usb_quirks:kind()], byte(), erx_usb_desc:setting()) ->
          none | {driver(), byte(), [need()]}.
driver(Speed, #{class := ?ERX_USB_CLASS_HUB, protocol := Protocol}, _Quirks, 0, _Setting) ->
    hub(Speed, Protocol);
driver(_Speed, _Device, _Quirks, _Number, #{class := ?ERX_USB_CLASS_HID}) ->
    {erx_usb_hid, 0, [{interrupt, in}]};
driver(_Speed, _Device, Quirks, _Number, Setting) ->
    case {speaks(scsi, Setting, Quirks), speaks(bulk_only, Setting, Quirks)} of
        {true, true} -> {erx_usb_bot, 0, [{bulk, in}, {bulk, out}]};
        _NotBoth -> none
    end.

%% Whether a mass-storage interface speaks SCSI, by its subclass, or Bulk-Only, by its
%% protocol, or the device's quirks force it to.
speaks(scsi, Setting, Quirks) ->
    erx_usb_quirks:has(force_scsi, Quirks) orelse
        maps:with([class, subclass], Setting) =:= #{class => ?ERX_USB_CLASS_MASS_STORAGE,
                                                    subclass => ?ERX_USB_SUBCLASS_SCSI};
speaks(bulk_only, Setting, Quirks) ->
    erx_usb_quirks:has(force_bot, Quirks) orelse
        maps:with([class, protocol], Setting) =:= #{class => ?ERX_USB_CLASS_MASS_STORAGE,
                                                    protocol => ?ERX_USB_PROTOCOL_BULK_ONLY}.

hub(Speed, ?ERX_USB_HUB_PROTOCOL_MULTI_TT) when Speed =:= full; Speed =:= high ->
    {erx_usb_hub, ?ERX_USB_HUB_MULTI_TT_ALTERNATE, [{interrupt, in}]};
hub(Speed, _Protocol) when Speed =:= full; Speed =:= high ->
    {erx_usb_hub, 0, [{interrupt, in}]};
hub(_Speed, _Protocol) ->
    none.

%% The first endpoint of each needed type and direction, or none when one is missing.
endpoints(Needs, #{endpoints := Endpoints}) ->
    Found = [lists:search(fun(E) -> meets(Need, E) end, Endpoints) || Need <- Needs],
    case lists:member(false, Found) of
        true -> none;
        false -> [E || {value, E} <- Found]
    end.

meets({Type, Direction}, #{type := Type, address := Address}) ->
    Direction =:= case Address band ?ERX_USB_ENDPOINT_DIR_IN of
                      0 -> out;
                      _ -> in
                  end;
meets(_Need, _Endpoint) ->
    false.

pipe(Speed, #{address := Address, type := Type, max_packet := MaxPacket, interval := Interval,
              companion := Companion}) when Type =:= bulk; Type =:= interrupt ->
    Size = MaxPacket band ?ERX_USB_PACKET_SIZE_MASK,
    check(Size =/= 0, zero_interval_payload),
    PacketSize = packet_size(Type, Speed, Size),
    Burst = burst(Type, Speed, MaxPacket, Companion),
    Payload = payload(Type, Speed, PacketSize * (Burst + 1), Companion),
    check(Payload >= 1, zero_interval_payload),
    check(Payload =< buffer(Type), endpoint_too_large),
    #{address => Address, type => Type, packet_size => PacketSize, burst => Burst,
      payload => Payload, interval_exponent => interval_exponent(Type, Speed, Interval)}.

packet_size(interrupt, low, Size) -> min(Size, ?ERX_USB_INTERRUPT_PACKET_LOW);
packet_size(interrupt, full, Size) -> min(Size, ?ERX_USB_INTERRUPT_PACKET_FULL);
packet_size(interrupt, high, Size) -> min(Size, ?ERX_USB_INTERRUPT_PACKET_HIGH);
packet_size(interrupt, super, Size) -> min(Size, ?ERX_USB_INTERRUPT_PACKET_SUPER);
packet_size(bulk, low, _Size) -> ?ERX_USB_BULK_PACKET_LOW;
packet_size(bulk, full, Size) -> full_speed_bulk(?ERX_USB_BULK_PACKET_FULL_MAX, Size);
packet_size(bulk, high, _Size) -> ?ERX_USB_BULK_PACKET_HIGH;
packet_size(bulk, super, _Size) -> ?ERX_USB_BULK_PACKET_SUPER.

%% The largest of the powers of two from the minimum to Candidate that Size reaches,
%% and the minimum when it reaches none.
full_speed_bulk(Candidate, Size)
  when Candidate =< Size; Candidate =:= ?ERX_USB_BULK_PACKET_FULL_MIN ->
    Candidate;
full_speed_bulk(Candidate, Size) ->
    full_speed_bulk(Candidate div 2, Size).

burst(_Type, super, _MaxPacket, none) ->
    refuse(missing_companion);
burst(_Type, super, _MaxPacket, #{max_burst := MaxBurst}) ->
    check(MaxBurst =< ?ERX_USB_BURST_MAX, malformed_descriptor),
    MaxBurst;
burst(interrupt, high, MaxPacket, _Companion) ->
    Extra = (MaxPacket bsr ?ERX_USB_PACKET_EXTRA_SHIFT) band ?ERX_USB_PACKET_EXTRA_MASK,
    check(Extra =< ?ERX_USB_PACKET_EXTRA_MAX, malformed_descriptor),
    Extra;
burst(_Type, _Speed, _MaxPacket, _Companion) ->
    0.

%% Product is the packet size times the burst plus one, what the endpoint's
%% transfers can carry in one service interval.
payload(interrupt, super, Product, #{bytes_per_interval := Declared}) ->
    check(Declared =< Product andalso Declared =< ?ERX_USB_SS_INTERRUPT_PAYLOAD_MAX,
          endpoint_too_large),
    Declared;
payload(_Type, _Speed, Product, _Companion) ->
    Product.

%% Milliseconds at low and full speed, rounded down to a power of two of
%% 125 us; 2^(bInterval-1) microframes above.
interval_exponent(bulk, _Speed, _Interval) ->
    0;
interval_exponent(interrupt, Speed, Interval) when Speed =:= low; Speed =:= full ->
    check(Interval >= 1, malformed_descriptor),
    ?ERX_XHCI_INTERVAL_FRAME_SHIFT + floor_log2(Interval);
interval_exponent(interrupt, _Speed, Interval) ->
    check(Interval >= 1 andalso Interval =< ?ERX_XHCI_INTERVAL_BINTERVAL_MAX, malformed_descriptor),
    Interval - 1.

floor_log2(1) -> 0;
floor_log2(N) -> 1 + floor_log2(N bsr 1).

buffer(interrupt) -> ?ERX_XHCI_INTERRUPT_BUFFER_SIZE;
buffer(bulk) -> ?ERX_XHCI_BULK_BUFFER_SIZE.
