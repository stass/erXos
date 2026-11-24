%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The bounds of a login's arguments (docs/design-login.md, "Operations";
%% abi/services/login.txt), the one header erx_login_facet and every front end's
%% prompt include, so a prompt refuses what the facet would. Each is a guard
%% expression; the limits are the ABI's. A user name is a principal's name, a
%% system identifier, which erx_ident:new/1 alone checks.

-ifndef(ERX_LOGIN_HRL).
-define(ERX_LOGIN_HRL, true).

-include("generated/erx_abi.hrl").

-define(IS_LOGIN_BYTES(B, Min, Max),
        (is_binary(B) andalso byte_size(B) >= Min andalso byte_size(B) =< Max)).
-define(IS_LOGIN_PASSPHRASE(P), ?IS_LOGIN_BYTES(P, 1, ?ERX_LOGIN_PASSPHRASE_MAX)).
-define(IS_LOGIN_PEER(P), ?IS_LOGIN_BYTES(P, 0, ?ERX_LOGIN_PEER_MAX)).
-define(IS_LOGIN_BLOB(B), ?IS_LOGIN_BYTES(B, 1, ?ERX_LOGIN_BLOB_MAX)).
-define(IS_LOGIN_EXCHANGE(E), ?IS_LOGIN_BYTES(E, 1, ?ERX_LOGIN_EXCHANGE_MAX)).

-endif.
