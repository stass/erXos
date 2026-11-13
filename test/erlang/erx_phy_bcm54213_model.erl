%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A reference model of the Raspberry Pi 4's PHY, the BCM54213PE, as clause 22
%% describes it, written from FreeBSD 975e3605ebb1's register facts and not from
%% erx_phy_c22: mii.h for the control, status, advertisement and 1000BASE-T
%% control registers, brgphyreg.h:294-313 for the two shadow encodings and
%% brgphyreg.h:208-229 for the auxiliary status register's resolution, and IEEE
%% 802.3 Annex 28B.3 for the priority of the highest common mode. It carries
%% out one erx_phy_c22 request at a time and keeps a log of every write.
%%
%% What it models: a reset that holds the control register's reset bit for a
%% set number of reads and returns every register to its default; the status
%% register's link bit latching low (any drop clears it, a read returns it and
%% sets it to the link's state now); a link that is up when the cable is
%% connected, autonegotiation has been started, and the advertisements share a
%% mode; and shadow 7 of the auxiliary control register and the 32 functions of
%% shadow register 0x1C, each read only through its select. A read of a shadow
%% through a select the driver did not make returns a poison value.

-module(erx_phy_bcm54213_model).
-export([new/1, exec/2, cable/2, bounce/1, misc/1, clock/1, writes/1, link_up/1]).

-define(POISON, 16#dead).
-define(ID1, 16#600d).
-define(ID2, 16#84a2).

%% The modes a link partner can advertise, in Annex 28B.3's priority order, each
%% with the auxiliary status code brgphyreg.h:223-229 gives it.
-define(MODES, [{'1000fd', 16#0700}, {'1000hd', 16#0600}, {'100fd', 16#0500},
                {'100hd', 16#0300}, {'10fd', 16#0200}, {'10hd', 16#0100}]).

%% Options: misc, the data bits (14:3) shadow 7 resets to; clock, the data bits
%% (9:0) shadow 0x1C's clock alignment control resets to; reset_reads, the reads
%% that still see the reset bit; partner, the modes the link partner advertises;
%% cable, up or down; id, the two ID registers.
new(Options) ->
    Model = #{misc_default => maps:get(misc, Options, 16#0000),
              clock_default => maps:get(clock, Options, 16#0200),
              reset_reads => maps:get(reset_reads, Options, 3),
              partner => maps:get(partner, Options, [M || {M, _} <- ?MODES]),
              cable => maps:get(cable, Options, up),
              id => maps:get(id, Options, {?ID1, ?ID2}),
              writes => []},
    reset(Model).

misc(#{misc := Misc}) -> Misc.
clock(#{shadow_1c := Shadows}) -> maps:get(3, Shadows).
writes(#{writes := Writes}) -> lists:reverse(Writes).

cable(Model, up) -> Model#{cable := up};
cable(Model, down) -> Model#{cable := down, latch := false}.

%% The cable pulled and reconnected between two polls: the latch remembers it.
bounce(Model) -> cable(cable(Model, down), up).

link_up(#{cable := up, autoneg := true} = Model) -> hcd(Model) =/= none;
link_up(_) -> false.

exec(Model, {wait, _}) -> {Model, ok};
exec(Model, {write, Reg, Value}) ->
    {write(Model#{writes := [{Reg, Value} | maps:get(writes, Model)]}, Reg, Value), ok};
exec(Model, {read, Reg}) ->
    {Model1, Value} = read(Model, Reg),
    {Model1, {ok, Value}}.

reset(Model) ->
    Model#{bmcr => 16#1140, anar => 16#01e1, gtcr => 16#0300, autoneg => false,
           reset_left => maps:get(reset_reads, Model), latch => false,
           misc => maps:get(misc_default, Model), aux_select => 0,
           shadow_1c => (maps:from_list([{S, 0} || S <- lists:seq(0, 31)]))#{3 => maps:get(clock_default, Model)},
           select_1c => 0}.

write(Model, 16#00, Value) when Value band 16#8000 =/= 0 -> reset(Model);
write(Model, 16#00, Value) ->
    Started = Value band 16#1000 =/= 0 andalso Value band 16#0200 =/= 0,
    Model#{bmcr := Value band bnot 16#0200, autoneg := Started orelse maps:get(autoneg, Model)};
write(Model, 16#04, Value) -> Model#{anar := Value};
write(Model, 16#09, Value) -> Model#{gtcr := Value};
%% Auxiliary control: bits 2:0 select the shadow; for shadow 7 bit 15 writes its
%% data bits 14:3, and without it bits 14:12 select the shadow a read returns.
write(Model, 16#18, Value) when Value band 16#7 =:= 7, Value band 16#8000 =/= 0 ->
    Model#{misc := Value band 16#7ff8};
write(Model, 16#18, Value) when Value band 16#7 =:= 7 ->
    Model#{aux_select := (Value bsr 12) band 7};
write(Model, 16#18, _Value) -> Model#{aux_select := other};
%% Shadow 0x1C: bits 14:10 select the function, bit 15 writes its data bits 9:0.
write(Model, 16#1c, Value) when Value band 16#8000 =/= 0 ->
    Shadows = maps:get(shadow_1c, Model),
    Model#{shadow_1c := Shadows#{(Value bsr 10) band 16#1f => Value band 16#3ff}};
write(Model, 16#1c, Value) -> Model#{select_1c := (Value bsr 10) band 16#1f};
write(Model, _Reg, _Value) -> Model.

read(#{reset_left := Left} = Model, 16#00) when Left > 0 ->
    {Model#{reset_left := Left - 1}, 16#8000 bor maps:get(bmcr, Model)};
read(Model, 16#00) -> {Model, maps:get(bmcr, Model)};
read(Model, 16#01) ->
    Up = link_up(Model),
    Link = case maps:get(latch, Model) of true -> 16#0004; false -> 0 end,
    Acomp = case Up of true -> 16#0020; false -> 0 end,
    {Model#{latch := Up}, 16#7949 bor Link bor Acomp};
read(#{id := {Id1, _}} = Model, 16#02) -> {Model, Id1};
read(#{id := {_, Id2}} = Model, 16#03) -> {Model, Id2};
read(Model, 16#04) -> {Model, maps:get(anar, Model)};
read(Model, 16#09) -> {Model, maps:get(gtcr, Model)};
read(#{aux_select := 7, misc := Misc} = Model, 16#18) -> {Model, Misc bor 16#7};
read(Model, 16#18) -> {Model, ?POISON};
read(Model, 16#19) ->
    case link_up(Model) of
        true -> {Model, 16#8000 bor code(hcd(Model)) bor 16#0004};
        false -> {Model, 0}
    end;
read(#{select_1c := Select, shadow_1c := Shadows} = Model, 16#1c) ->
    {Model, (Select bsl 10) bor maps:get(Select, Shadows)};
read(Model, _Reg) -> {Model, 0}.

%% The highest-priority mode both ends advertise, or none.
hcd(Model) ->
    Ours = advertised(maps:get(anar, Model), maps:get(gtcr, Model)),
    Theirs = maps:get(partner, Model),
    case [M || {M, _} <- ?MODES, lists:member(M, Ours), lists:member(M, Theirs)] of
        [Best | _] -> Best;
        [] -> none
    end.

advertised(Anar, Gtcr) ->
    Bits = [{Gtcr, 16#0200, '1000fd'}, {Gtcr, 16#0100, '1000hd'}, {Anar, 16#0100, '100fd'},
            {Anar, 16#0080, '100hd'}, {Anar, 16#0040, '10fd'}, {Anar, 16#0020, '10hd'}],
    [Mode || {Reg, Bit, Mode} <- Bits, Reg band Bit =/= 0].

code(Mode) -> proplists:get_value(Mode, ?MODES).
