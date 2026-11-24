%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_gatt_gate).
-moduledoc """
The gate (docs/design-bluetooth.md, "One table, one gate"): the one function that decides
whether an access at a declared level may pass on a link, by GAP's Table 10.2 (Vol 3
Part C, 10.3.1) for the levels erXos uses, 1, 2 and 4 of 10.2.1, whose columns are the key
the server has for the peer, not whether that key is kept. The ATT server asks it for every
read and write of a characteristic value or a descriptor, and the link before every
notification and indication; nothing else decides access. One level is erXos's own,
`bonded`: level 4 on a link whose key is a kept bond's, so no access at it passes on a
pairing link before the store has kept its bond.
""".

-export([check/2]).
-export_type([level/0, link_security/0]).

-doc "The level an access requires: GAP 10.2.1's levels 1, 2 and 4, and `bonded`.".
-type level() :: open | encrypted | authenticated | bonded.
-doc """
A link's one key, by its level, whether the controller has encrypted the link with it, and
whether that key is a kept bond's.
""".
-type link_security() :: #{key := none | encrypted | authenticated, encrypted := boolean(), bonded := boolean()}.

-doc """
`ok` when an access at `Level` may pass on a link of `Security`; otherwise the ATT error
it is answered: Insufficient Authentication on a link with no key, Insufficient Encryption
on one whose key is not yet in use, Insufficient Authentication for an `authenticated` or
`bonded` access on a link encrypted with an unauthenticated key, and Insufficient
Authentication for a `bonded` access on a link whose key is no kept bond's.
""".
-spec check(level(), link_security()) -> ok | {error, insufficient_authentication | insufficient_encryption}.
check(open, _Security) -> ok;
check(_Level, #{key := none}) -> {error, insufficient_authentication};
check(_Level, #{encrypted := false}) -> {error, insufficient_encryption};
check(encrypted, _Security) -> ok;
check(_Level, #{key := encrypted}) -> {error, insufficient_authentication};
check(authenticated, _Security) -> ok;
check(bonded, #{bonded := true}) -> ok;
check(bonded, _Security) -> {error, insufficient_authentication}.
