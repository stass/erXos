%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_net_tx).
-moduledoc """
The transmit edge every socket shares (docs/design-network-stack.md, "Transmitting"):
packets built over a path (erx_net_frame) leave through the path's interface, addressed
from the next hop's neighbour row.

* With a row they go to the driver as one `{transmit, Frames}` against its transmit credit,
  and a stale row is hinted to its interface by the first transmitter that uses it, so one
  hint is in flight per row.
* Without one they go to the interface to resolve, `{resolve, NextHop, Src, Packets}`
  against its sender credit.

`hand/2` reaches the path's interface with any other message against the same credit (a
connection's RST, `charge_rst`). A full credit answers `full`; the caller counts or reports
it, since nothing here waits.
""".

-export([send/2, hand/2]).

-doc "Sends Packets over Path, to the driver or to the interface to resolve.".
-spec send(erx_net_frame:path(), [erx_net_frame:packet()]) -> ok | full.
send(#{link := Link, next_hop := NextHop, src := Src,
       iface := #{pid := If, driver := Driver, driver_credit := Tx, credit := IfCredit}} = Path,
     Packets) ->
    Neighbour = case Link of
                    neighbour -> erx_net_tables:neighbour(If, NextHop);
                    {fixed, _} -> none
                end,
    case erx_net_frame:address(Path, Neighbour, Packets) of
        {send, Frames} ->
            ok = hint(Neighbour, If, NextHop),
            erx_net_credit:hand(Driver, Tx, erx_net_frame:units(Frames), {transmit, Frames});
        {resolve, Unaddressed} ->
            erx_net_credit:hand(If, IfCredit, 1, {resolve, NextHop, Src, Unaddressed})
    end.

-doc "Hands Msg to the interface of Path against its sender credit.".
-spec hand(erx_net_frame:path(), term()) -> ok | full.
hand(#{iface := #{pid := If, credit := IfCredit}}, Msg) ->
    erx_net_credit:hand(If, IfCredit, 1, Msg).

hint({_, stale}, If, NextHop) ->
    case erx_net_tables:first_hint(If, NextHop) of
        true -> If ! {hint, NextHop}, ok;
        false -> ok
    end;
hint(_Neighbour, _If, _NextHop) ->
    ok.
