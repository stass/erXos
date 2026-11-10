%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A run, as the frame layer hands it to a driver (docs/design-network-fastpath.md, "A run"):
%% consecutive TCP segments of one connection that differ only in the sequence number, the
%% lengths, the checksums, and PSH and FIN, which only the last frame carries. Frame i of a
%% run whose payload holds P bytes carries the payload bytes from i * seg to
%% min(P, (i + 1) * seg) and the sequence number seq + i * seg modulo 2^32; a run with no
%% payload is one frame. erx_net_frame:cut/1 gives its frames; a transport that cuts a run
%% itself gives the same bytes.
-record(run, {link = <<>> :: binary(),       % the link header; <<>> above the link
              template :: binary(),          % the IP and TCP headers, erx_net_frame:template/2
              seq :: 0..16#ffffffff,         % the first frame's sequence number
              ack :: 0..16#ffffffff,
              flags :: 0..16#fff,            % the last frame's; the others clear PSH and FIN
              win :: 0..16#ffff,
              ts :: none | {TsVal :: 0..16#ffffffff, TsEcr :: 0..16#ffffffff},
              seg :: pos_integer(),          % the payload bytes of each frame but the last
              payload :: [binary()]}).       % sub-binaries of the send buffer, at most RUN_PIECES

%% The binaries a run's payload may lie in: ERX_TCP_CUT_PIECES_MAX, the bound the C that cuts
%% a run walks (c_src/erx_tcp_cut.h). Output ends a run where they end, and the frame layer
%% sends a run of more as its segments.
-define(RUN_PIECES, 64).
