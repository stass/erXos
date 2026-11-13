%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_phy_c22).
-moduledoc """
The Raspberry Pi 4's Ethernet PHY, a Broadcom BCM54213PE on MDIO, as a pure
state machine over clause 22 registers (docs/design-platforms.md, "Raspberry
Pi 4 Model B"). It asks for one operation at a time and takes its result; the
transport carries each request out through `erx_mdio` at the PHY's address,
feeds the result back to `step/2`, and acts on the reports: configure the MAC
for a speed at `{link, up, Speed}`, stop sending at `{link, down}`, and end the
driver, which its supervisor restarts, at `{failed, Reason}`.

The sequence, after `start/0`:

1. **Reset.** Write the control register's reset bit, then read the control
   register until the PHY clears it, up to `reset_polls/0` reads 1 ms apart.
2. **Identify.** Read both ID registers. Anything but the BCM54213PE (OUI
   `0x18c086`, model `0x0a`, any revision) is refused with
   `{unknown_phy, Id}`, so a different board's PHY is never configured as
   this one.
3. **RGMII clocks.** The board's device tree wires the PHY `rgmii-rxid`
   (unverified: no source read for this module states it): the PHY delays
   the receive clock and not the transmit clock. Set `RGMII_SKEW_EN` in the
   auxiliary control register's shadow 7 and clear `GTXCLK_EN` in shadow
   register `0x1C`'s clock alignment control, each a select, a read and a
   write that keeps the other data bits.
4. **Advertise and autonegotiate.** Advertise full duplex only, 10 and
   100 Mb/s in the advertisement register and 1000 Mb/s in the 1000BASE-T
   control register, since the controller's command register has a speed
   field and no duplex field (`if_genetreg.h:75-92`; unverified on the
   board); then enable and restart autonegotiation.
5. **Poll the link,** every `link_poll_ms/0`. The status register's link bit
   latches low: the first read says whether the link dropped since the last
   one, the second whether it is up now. A drop while the link was up is
   reported as `{link, down}` even when the second read finds it up again. A
   speed change without a drop, which only a faulty PHY reports, comes as
   `{link, up, Speed}` alone, so the transport configures the MAC at every
   `up`. A link up with autonegotiation complete is resolved from the
   auxiliary status register's highest common mode, if that register's own
   link bit is set too; only a full-duplex mode is a speed, and a half-duplex
   or 100BASE-T4 resolution, which only parallel detection of a partner that
   does not autonegotiate can produce, is reported as the link down.

Any MDIO error, or a result that does not answer the request, ends the
machine with `{failed, Reason}` and the request `stop`.

Register facts are from FreeBSD 975e3605ebb1, `sys/dev/mii/`: the clause 22
registers and bits (`mii.h:50-190`), the ID decoding (`miivar.h:303-305`,
`mii.c:620-640`) and the BCM54213PE's ID (`miidevs:54, 202`); the reset and
its 100 polls 1 ms apart (`brgphy.c:947-955`); the clock delays
(`brgphy.c:871-898`, applied to this PHY at `brgphy.c:416-419`), with the
shadow encodings of `brgphyreg.h:294-316`; the double read of the status
register (`brgphy.c:500`); and the auxiliary status resolution, taken only
with its link bit set (`brgphyreg.h:208-229`, `brgphy.c:524-527`).
""".

-export([reset_polls/0, link_poll_ms/0]).
-export([start/0, step/2, link/1]).
-export([identify/2, resolution/1]).
-export_type([state/0, reg/0, request/0, input/0, report/0, link/0, speed/0]).

%% Clause 22 registers (mii.h) and Broadcom's own (brgphyreg.h).
-define(BMCR, 16#00).
-define(BMSR, 16#01).
-define(PHYIDR1, 16#02).
-define(PHYIDR2, 16#03).
-define(ANAR, 16#04).
-define(GTCR, 16#09).
-define(AUXCTL, 16#18).
-define(AUXSTS, 16#19).
-define(SHADOW_1C, 16#1c).

-define(BMCR_RESET, 16#8000).
-define(BMCR_AUTOEN, 16#1000).
-define(BMCR_STARTNEG, 16#0200).
-define(BMSR_ACOMP, 16#0020).
-define(BMSR_LINK, 16#0004).
-define(ANAR_TX_FD, 16#0100).
-define(ANAR_10_FD, 16#0040).
-define(ANAR_CSMA, 16#0001).
-define(GTCR_ADV_1000TFDX, 16#0200).

-define(IDR2_MODEL, 16#03f0).
-define(IDR2_REV, 16#000f).
-define(OUI_BROADCOM4, 16#18c086).
-define(MODEL_BCM54213PE, 16#0a).

%% Auxiliary control, shadow 7 (miscellaneous control): bits 2:0 select it, bits
%% 14:12 select the shadow a read returns, bit 15 makes the write a write.
-define(AUXCTL_SHADOW_MISC, 16#0007).
-define(AUXCTL_MISC_READ_SHIFT, 12).
-define(AUXCTL_MISC_WRITE_EN, 16#8000).
-define(AUXCTL_MISC_DATA_MASK, 16#7ff8).
-define(AUXCTL_MISC_RGMII_SKEW_EN, 16#0200).
%% Shadow 0x1C: bits 14:10 select the function, bit 15 makes the write a write.
-define(SHADOW_1C_WRITE_EN, 16#8000).
-define(SHADOW_1C_DATA_MASK, 16#03ff).
-define(SHADOW_1C_CLK_CTRL, (16#03 bsl 10)).
-define(SHADOW_1C_GTXCLK_EN, 16#0200).

-define(AUXSTS_AN_RES, 16#0700).
-define(AUXSTS_LINK, 16#0004).
-define(RES_1000FD, 16#0700).
-define(RES_100FD, 16#0500).
-define(RES_10FD, 16#0200).

-define(RESET_POLLS, 100).
-define(RESET_POLL_MS, 1).
-define(LINK_POLL_MS, 1000).

-define(IS_WORD(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ffff)).

-type reg() :: 0..31.
-type word() :: 0..16#ffff.
-type speed() :: 10 | 100 | 1000.
-type link() :: down | {up, speed()}.
-doc """
The next thing to do: an MDIO operation on the PHY, a pause before the next
step, or nothing more, after a failure.
""".
-type request() :: {read, reg()} | {write, reg(), word()} | {wait, pos_integer()} | stop.
-doc """
The result of the last request: `{ok, Value}` for a read, `ok` for a write or
a pause, `{error, Reason}` for an MDIO operation that failed.
""".
-type input() :: {ok, word()} | ok | {error, term()}.
-type report() :: {link, down} | {link, up, speed()} | {failed, term()}.
-type id() :: #{oui := 0..16#ffffff, model := 0..16#3f, rev := 0..16#f}.

%% Each phase names the request whose result step/2 waits for.
-type phase() :: reset
               | {reset_check, pos_integer()}
               | {reset_wait, pos_integer()}
               | id1
               | {id2, word()}
               | skew_select | skew_read | skew_write
               | clock_select | clock_read | clock_write
               | advertise | advertise_1000 | autoneg
               | link_latched
               | {link_now, word()}
               | resolve
               | link_wait
               | failed.

-record(phy, {phase = reset :: phase(), link = down :: link()}).
-opaque state() :: #phy{}.

-doc "The reads of the control register before a reset times out.".
-spec reset_polls() -> pos_integer().
reset_polls() -> ?RESET_POLLS.

-doc "The milliseconds between two polls of the link.".
-spec link_poll_ms() -> pos_integer().
link_poll_ms() -> ?LINK_POLL_MS.

-doc "A machine before anything is done, the link down, and its first request.".
-spec start() -> {state(), request()}.
start() ->
    {#phy{phase = reset}, {write, ?BMCR, ?BMCR_RESET}}.

-doc "The link the machine last reported.".
-spec link(state()) -> link().
link(#phy{link = Link}) -> Link.

-doc """
The machine after the result of its last request: its next state, its next
request and what it reports, in order.
""".
-spec step(state(), input()) -> {state(), request(), [report()]}.
step(#phy{phase = failed} = Phy, _Input) ->
    {Phy, stop, []};
step(#phy{} = Phy, {error, Reason}) ->
    fail(Phy, {mdio, Reason});
step(#phy{phase = Phase} = Phy, Input) ->
    case {Phase, Input} of
        {reset, ok} ->
            next(Phy, {reset_check, 1}, {read, ?BMCR});
        {{reset_check, _}, {ok, Bmcr}} when ?IS_WORD(Bmcr), Bmcr band ?BMCR_RESET =:= 0 ->
            next(Phy, id1, {read, ?PHYIDR1});
        {{reset_check, Reads}, {ok, Bmcr}} when ?IS_WORD(Bmcr), Reads < ?RESET_POLLS ->
            next(Phy, {reset_wait, Reads}, {wait, ?RESET_POLL_MS});
        {{reset_check, _}, {ok, Bmcr}} when ?IS_WORD(Bmcr) ->
            fail(Phy, reset_timeout);
        {{reset_wait, Reads}, ok} ->
            next(Phy, {reset_check, Reads + 1}, {read, ?BMCR});
        {id1, {ok, Id1}} when ?IS_WORD(Id1) ->
            next(Phy, {id2, Id1}, {read, ?PHYIDR2});
        {{id2, Id1}, {ok, Id2}} when ?IS_WORD(Id2) ->
            identified(Phy, identify(Id1, Id2));
        {skew_select, ok} ->
            next(Phy, skew_read, {read, ?AUXCTL});
        {skew_read, {ok, Misc}} when ?IS_WORD(Misc) ->
            Data = (Misc band ?AUXCTL_MISC_DATA_MASK) bor ?AUXCTL_MISC_RGMII_SKEW_EN,
            Write = ?AUXCTL_MISC_WRITE_EN bor ?AUXCTL_SHADOW_MISC bor Data,
            next(Phy, skew_write, {write, ?AUXCTL, Write});
        {skew_write, ok} ->
            next(Phy, clock_select, {write, ?SHADOW_1C, ?SHADOW_1C_CLK_CTRL});
        {clock_select, ok} ->
            next(Phy, clock_read, {read, ?SHADOW_1C});
        {clock_read, {ok, Clock}} when ?IS_WORD(Clock) ->
            Data = Clock band ?SHADOW_1C_DATA_MASK band bnot ?SHADOW_1C_GTXCLK_EN,
            Write = ?SHADOW_1C_WRITE_EN bor ?SHADOW_1C_CLK_CTRL bor Data,
            next(Phy, clock_write, {write, ?SHADOW_1C, Write});
        {clock_write, ok} ->
            next(Phy, advertise, {write, ?ANAR, ?ANAR_TX_FD bor ?ANAR_10_FD bor ?ANAR_CSMA});
        {advertise, ok} ->
            next(Phy, advertise_1000, {write, ?GTCR, ?GTCR_ADV_1000TFDX});
        {advertise_1000, ok} ->
            next(Phy, autoneg, {write, ?BMCR, ?BMCR_AUTOEN bor ?BMCR_STARTNEG});
        {autoneg, ok} ->
            next(Phy, link_latched, {read, ?BMSR});
        {link_wait, ok} ->
            next(Phy, link_latched, {read, ?BMSR});
        {link_latched, {ok, Latched}} when ?IS_WORD(Latched) ->
            next(Phy, {link_now, Latched}, {read, ?BMSR});
        {{link_now, Latched}, {ok, Now}} when ?IS_WORD(Now) ->
            link_status(Phy, Latched, Now);
        {resolve, {ok, Aux}} when ?IS_WORD(Aux) ->
            resolved(Phy, resolution(Aux));
        _ ->
            fail(Phy, {unexpected, Phase, Input})
    end.

-doc """
A PHY's identity from its two ID registers, as FreeBSD's `mii_oui` derives
it: the OUI's 22 bits are ID 1 and the top six bits of ID 2, each of the three
bytes bit-reversed into the OUI's canonical form.
""".
-spec identify(word(), word()) -> id().
identify(Id1, Id2) when ?IS_WORD(Id1), ?IS_WORD(Id2) ->
    H = (Id1 bsl 6) bor (Id2 bsr 10),
    Oui = (reverse_byte(H bsr 16) bsl 16) bor (reverse_byte((H bsr 8) band 16#ff) bsl 8)
        bor reverse_byte(H band 16#ff),
    #{oui => Oui, model => (Id2 band ?IDR2_MODEL) bsr 4, rev => Id2 band ?IDR2_REV}.

-doc """
The speed of the auxiliary status register's highest common mode, or
`none` when the register's link bit is clear or the mode is no full-duplex
mode.
""".
-spec resolution(word()) -> speed() | none.
resolution(Aux) when ?IS_WORD(Aux), Aux band ?AUXSTS_LINK =:= 0 ->
    none;
resolution(Aux) when ?IS_WORD(Aux) ->
    case Aux band ?AUXSTS_AN_RES of
        ?RES_1000FD -> 1000;
        ?RES_100FD -> 100;
        ?RES_10FD -> 10;
        _ -> none
    end.

identified(Phy, #{oui := ?OUI_BROADCOM4, model := ?MODEL_BCM54213PE}) ->
    Select = ?AUXCTL_SHADOW_MISC bor (?AUXCTL_SHADOW_MISC bsl ?AUXCTL_MISC_READ_SHIFT),
    next(Phy, skew_select, {write, ?AUXCTL, Select});
identified(Phy, Id) ->
    fail(Phy, {unknown_phy, Id}).

%% Latched is the first read of the status register, Now the second. A link up
%% now is resolved before it is reported; a drop since the last poll ends the
%% link reported up first.
link_status(#phy{link = Link} = Phy, Latched, Now) ->
    Dropped = Latched band ?BMSR_LINK =:= 0,
    Up = Now band ?BMSR_LINK =/= 0 andalso Now band ?BMSR_ACOMP =/= 0,
    {Link1, Reports} = case Link of
                           {up, _} when Dropped; not Up -> {down, [{link, down}]};
                           _ -> {Link, []}
                       end,
    Phy1 = Phy#phy{link = Link1},
    case Up of
        true -> {Phy1#phy{phase = resolve}, {read, ?AUXSTS}, Reports};
        false -> {Phy1#phy{phase = link_wait}, {wait, ?LINK_POLL_MS}, Reports}
    end.

%% The link after a resolution: a change is reported, a repeat is not.
resolved(#phy{link = Link} = Phy, Speed) ->
    {Link1, Reports} = case {Link, Speed} of
                           {down, none} -> {down, []};
                           {{up, _}, none} -> {down, [{link, down}]};
                           {{up, Same}, Same} -> {Link, []};
                           {_, _} -> {{up, Speed}, [{link, up, Speed}]}
                       end,
    {Phy#phy{phase = link_wait, link = Link1}, {wait, ?LINK_POLL_MS}, Reports}.

next(Phy, Phase, Request) ->
    {Phy#phy{phase = Phase}, Request, []}.

fail(Phy, Reason) ->
    {Phy#phy{phase = failed}, stop, [{failed, Reason}]}.

reverse_byte(Byte) ->
    <<B0:1, B1:1, B2:1, B3:1, B4:1, B5:1, B6:1, B7:1>> = <<Byte:8>>,
    <<Reversed:8>> = <<B7:1, B6:1, B5:1, B4:1, B3:1, B2:1, B1:1, B0:1>>,
    Reversed.
