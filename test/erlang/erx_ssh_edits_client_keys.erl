%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The client's key callback for erx_ssh_edits_tests: it trusts every host
%% key, as the test's daemon makes a new one per case, and offers the one
%% Ed25519 user key under `conf` in key_cb_private.
-module(erx_ssh_edits_client_keys).
-behaviour(ssh_client_key_api).

-export([add_host_key/4, is_host_key/4, is_host_key/5, user_key/2]).

add_host_key(_Host, _Port, _Key, _Opts) -> ok.

is_host_key(_Key, _Host, _Alg, _Opts) -> true.

is_host_key(_Key, _Host, _Port, _Alg, _Opts) -> true.

user_key('ssh-ed25519', Opts) ->
    {ok, proplists:get_value(conf, proplists:get_value(key_cb_private, Opts))};
user_key(_Alg, _Opts) ->
    {error, "no key"}.
