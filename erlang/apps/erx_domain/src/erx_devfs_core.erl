%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_devfs_core).
-moduledoc """
The pure decisions of `/dev` (docs/design-system.md, "The /dev tree"): which
devices the tree shows and under which names, what a device's `status`
file holds, what a write to its `ctl` file asks for, which facet acts on
it, and what the facet's answer reads as at the file. erx_devfs reads the
catalogue and the manifest's services and hands them in, so every decision
is tested with made-up catalogues.

* **Devices.** The tree shows the catalogue's block devices.
* **Names.** A device's directory is its catalogue index and its kind's
  compatible string, `12-virtio,mmio`, the compatible string encoded as
  `/proc` encodes text (erx_schema:segment_text/1); a device without one is
  its index alone. find/2 reads the name a walk hands in, which is
  untrusted, by comparing it whole with each shown device's name/1, so a
  name is never parsed, has one spelling and makes no atom.
* **Status.** status/1 writes one `name TAB value` line per field, each
  through erx_text:escape_field/1 as `/proc` writes its fields: the unit's
  manifest name, the compatible string (`none` without one), the register
  window as `0xFIRST-0xLAST` (`[unknown]` for a PCIe function), the
  interrupt lines separated by spaces, whether the device is confined, the
  holder (a domain id, `system` or `none`) and the driver process, which
  is `[unknown]`: no facet answers which process drives a unit.
* **Ctl.** command/1 reads one write to `ctl`: `stop`, `start` or `reset`,
  ended by one newline or not, at most 16 bytes; anything else is `einval`.
  `reset` is the facet's `restart`.
* **Facet.** facet/2 finds the holder's driver-control facet by interface:
  the service of the `driver_control` interface whose server is the
  configured row the device is placed on, and only while a domain of that
  row holds the device. answer/1 reads the facet's answer as a write's.
""".

-include("generated/erx_abi.hrl").

-export([shown/1, name/1, find/2, status/1, command/1, facet/2, answer/1]).

%% The longest write ctl reads (design-system.md, The /dev tree).
-define(MAX_CTL, 16).

-doc "The devices the tree shows, in the catalogue's order.".
-spec shown([erx_domain_lib:device()]) -> [erx_domain_lib:device()].
shown(Devices) ->
    [Device || #{role := block} = Device <- Devices].

-doc "The directory name of Device.".
-spec name(erx_domain_lib:device()) -> binary().
name(#{index := Index, compatible := none}) ->
    integer_to_binary(Index);
name(#{index := Index, compatible := Compatible}) ->
    <<(integer_to_binary(Index))/binary, $-, (erx_schema:segment_text(Compatible))/binary>>.

-doc "The shown device that Name, a walk's untrusted name, names, or error.".
-spec find(binary(), [erx_domain_lib:device()]) -> {ok, erx_domain_lib:device()} | error.
find(Name, Devices) when is_binary(Name) ->
    case [Device || Device <- shown(Devices), name(Device) =:= Name] of
        [Device] -> {ok, Device};
        _None -> error
    end.

-doc "The text of Device's status file.".
-spec status(erx_domain_lib:device()) -> binary().
status(#{unit_name := Unit, compatible := Compatible, registers := Registers, lines := Lines,
         confined := Confined, holder := Holder}) ->
    Fields = [{<<"unit">>, Unit},
              {<<"compatible">>, value(Compatible)},
              {<<"registers">>, registers(Registers)},
              {<<"lines">>, iolist_to_binary(lists:join($\s, [integer_to_binary(Line) || Line <- Lines]))},
              {<<"confined">>, atom_to_binary(Confined)},
              {<<"holder">>, value(Holder)},
              {<<"driver">>, <<"[unknown]">>}],
    iolist_to_binary([[erx_text:escape_field(Key), $\t, erx_text:escape_field(Value), $\n]
                      || {Key, Value} <- Fields]).

value(Value) when is_binary(Value) -> Value;
value(Value) when is_integer(Value) -> integer_to_binary(Value);
value(Value) when is_atom(Value) -> atom_to_binary(Value).

registers({Address, Bytes}) ->
    iolist_to_binary(io_lib:format("0x~.16b-0x~.16b", [Address, Address + Bytes - 1]));
registers(unknown) ->
    <<"[unknown]">>.

-doc """
The operation one write to ctl asks for, from its untrusted bytes:
`{ok, stop | start | restart}`, or `{error, einval}`.
""".
-spec command(binary()) -> {ok, stop | start | restart} | {error, einval}.
command(Bytes) when is_binary(Bytes), byte_size(Bytes) =< ?MAX_CTL ->
    case Bytes of
        <<"stop">> -> {ok, stop};
        <<"stop\n">> -> {ok, stop};
        <<"start">> -> {ok, start};
        <<"start\n">> -> {ok, start};
        <<"reset">> -> {ok, restart};
        <<"reset\n">> -> {ok, restart};
        _Other -> {error, einval}
    end;
command(_Bytes) ->
    {error, einval}.

-doc """
The name of the holder's driver-control facet for Device, from the
manifest's services, `{ServerRow, Name, Interface}` as
erx_domain_lib:configured/0 gives them; `{error, enxio}` when no domain of
a configured row holds the device or that row serves no such facet.
""".
-spec facet(erx_domain_lib:device(), [{non_neg_integer(), atom(), non_neg_integer()}]) ->
          {ok, atom()} | {error, enxio}.
facet(#{row := Row, holder := Holder}, Services) when is_integer(Row), is_integer(Holder) ->
    case [Name || {Server, Name, ?ERX_SERVICE_DRIVER_CONTROL} <- Services, Server =:= Row] of
        [Name | _] -> {ok, Name};
        [] -> {error, enxio}
    end;
facet(_Device, _Services) ->
    {error, enxio}.

-doc """
What a ctl write answers for the facet's Answer: ok; `ebusy` for a start of
a running driver; `enxio` for a unit the holder does not drive; `eio` for a
driver that did not start or stop, and for a call that did not complete.
""".
-spec answer(term()) -> ok | {error, ebusy | enxio | eio}.
answer(ok) -> ok;
answer({error, running}) -> {error, ebusy};
answer({error, badarg}) -> {error, enxio};
answer(_Failed) -> {error, eio}.
