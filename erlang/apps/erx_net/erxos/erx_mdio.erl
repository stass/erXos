%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_mdio).
-moduledoc """
The Raspberry Pi 4 Ethernet controller's MDIO command register as pure
decisions (docs/design-platforms.md, "Raspberry Pi 4 Model B"): the word that
asks for a clause 22 read or write of a PHY register, the word that starts it,
and what each poll of the register means. The transport writes `command/1`'s
word, then `start/1`'s, then reads the register and calls `poll/3`, first
with `Polls` 1, until it answers anything but `{wait, Next}`, polling again
with `Next` after `poll_interval_us/0`. The count comes back from `poll/3`,
so the bound holds as long as the transport passes back what it returned.

The register's fields are MDIO_CMD's in hw/svd/genet/genet.svd (FreeBSD
975e3605ebb1, `sys/arm64/broadcom/genet/if_genetreg.h:101-110`), through the
generated erx_hw_genet.hrl: busy and start, read failed, read, write, the PHY
address, the register and the data. The controller clears busy when the
operation ends. A read whose read-failed bit is set returns an
error, where FreeBSD returns 0 (`if_genet.c:1687-1688`); a poll still busy
after `max_polls/0` polls, FreeBSD's bound of 1,000 polls 10 us apart
(`if_genet.c:1669, 1684-1692`), returns `timeout`.
""".

-export([max_polls/0, poll_interval_us/0]).
-export([command/1, start/1, poll/3, decode/1]).
-export_type([op/0, phy/0, reg/0, value/0, word/0, fields/0]).

-include("generated/erx_hw_genet.hrl").

-define(BUSY, ?ERX_HW_GENET_MDIO_CMD_START_BUSY_MASK).
-define(READ_FAILED, ?ERX_HW_GENET_MDIO_CMD_READ_FAILED_MASK).
-define(READ, ?ERX_HW_GENET_MDIO_CMD_READ_MASK).
-define(WRITE, ?ERX_HW_GENET_MDIO_CMD_WRITE_MASK).
-define(MAX_POLLS, 1000).
-define(POLL_INTERVAL_US, 10).

-define(IS_U32(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ffffffff)).

-type phy() :: 0..31.
-type reg() :: 0..31.
-type value() :: 0..16#ffff.
-doc "The command register's 32-bit word.".
-type word() :: 0..16#ffffffff.
-doc "One clause 22 operation on one PHY's register.".
-type op() :: {read, phy(), reg()} | {write, phy(), reg(), value()}.
-type fields() :: #{busy := boolean(), read_failed := boolean(),
                    read := boolean(), write := boolean(),
                    phy := phy(), reg := reg(), data := value()}.

-doc "The polls of one operation before it times out.".
-spec max_polls() -> pos_integer().
max_polls() -> ?MAX_POLLS.

-doc "The microseconds between two polls.".
-spec poll_interval_us() -> pos_integer().
poll_interval_us() -> ?POLL_INTERVAL_US.

-doc "The command word of an operation, busy clear.".
-spec command(op()) -> word().
command({read, Phy, Reg}) when ?ERX_HW_GENET_MDIO_CMD_PMD_FITS(Phy), ?ERX_HW_GENET_MDIO_CMD_REG_FITS(Reg) ->
    ?READ bor ?ERX_HW_GENET_MDIO_CMD_PMD_PUT(Phy) bor ?ERX_HW_GENET_MDIO_CMD_REG_PUT(Reg);
command({write, Phy, Reg, Value}) when ?ERX_HW_GENET_MDIO_CMD_PMD_FITS(Phy), ?ERX_HW_GENET_MDIO_CMD_REG_FITS(Reg),
                                       ?ERX_HW_GENET_MDIO_CMD_VALUE_FITS(Value) ->
    ?WRITE bor ?ERX_HW_GENET_MDIO_CMD_PMD_PUT(Phy) bor ?ERX_HW_GENET_MDIO_CMD_REG_PUT(Reg)
        bor ?ERX_HW_GENET_MDIO_CMD_VALUE_PUT(Value).

-doc """
The word that starts the operation a command word names: the command word
with busy set. FreeBSD instead sets busy in a read-back of the register
(`if_genet.c:1680-1683`); whether the two differ on the board is unverified.
""".
-spec start(word()) -> word().
start(Word) when ?IS_U32(Word) -> Word bor ?BUSY.

-doc """
What the `Polls`-th poll of operation `Op`, which read `Word`, means:
`{wait, Next}` to poll again as poll `Next` after `poll_interval_us/0`,
`{ok, Value}` for a read's data, `ok` for a write's end, or an error.
""".
-spec poll(op(), word(), pos_integer()) ->
          {wait, pos_integer()} | ok | {ok, value()} | {error, timeout | read_failed}.
poll(Op, Word, Polls) when ?IS_U32(Word), is_integer(Polls), Polls >= 1 ->
    case {Word band ?BUSY =/= 0, Op} of
        {true, _} when Polls < ?MAX_POLLS -> {wait, Polls + 1};
        {true, _} -> {error, timeout};
        {false, {read, _, _}} when Word band ?READ_FAILED =/= 0 -> {error, read_failed};
        {false, {read, _, _}} -> {ok, ?ERX_HW_GENET_MDIO_CMD_VALUE_GET(Word)};
        {false, {write, _, _, _}} -> ok
    end.

-doc "Every field of a command word.".
-spec decode(word()) -> fields().
decode(Word) when ?IS_U32(Word) ->
    #{busy => Word band ?BUSY =/= 0,
      read_failed => Word band ?READ_FAILED =/= 0,
      read => Word band ?READ =/= 0,
      write => Word band ?WRITE =/= 0,
      phy => ?ERX_HW_GENET_MDIO_CMD_PMD_GET(Word),
      reg => ?ERX_HW_GENET_MDIO_CMD_REG_GET(Word),
      data => ?ERX_HW_GENET_MDIO_CMD_VALUE_GET(Word)}.
