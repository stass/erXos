%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% erXos's erx_dist as the host tests of a protocol owner that checks a frame's origin
%% see it on stock's emulator: owner/1 answers the creation a pid or reference carries,
%% as the BIF erx_dist:owner/1 does, so a name a test builds for another node is that
%% domain's. Stock delivers every message bare, so a test plays the connection and puts
%% a frame of another domain in the envelope of edit 16 itself.

-module(erx_dist).

-export([owner/1]).

-spec owner(pid() | reference()) -> non_neg_integer().
owner(Pid) when is_pid(Pid) ->
    %% NEW_PID_EXT behind its node's SMALL_ATOM_UTF8_EXT, as stock writes it.
    <<131, 88, 119, Length, _Node:Length/binary, _Id:32, _Serial:32, Creation:32>> = term_to_binary(Pid),
    Creation;
owner(Ref) when is_reference(Ref) ->
    %% NEWER_REFERENCE_EXT, likewise.
    <<131, 90, _Count:16, 119, Length, _Node:Length/binary, Creation:32, _Ids/binary>> = term_to_binary(Ref),
    Creation.
