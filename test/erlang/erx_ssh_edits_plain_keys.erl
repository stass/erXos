%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A daemon key callback written for stock OTP: it exports none of the
%% hooks erXos's ssh adds, so the daemon must treat it as stock's does
%% (docs/design-ssh.md, "Edits to OTP's ssh", "Stock behaviour kept").
%% Its configuration is erx_ssh_edits_keys's, less the cookie; a `blob`
%% host key without sign/3 is a key the daemon cannot use.
-module(erx_ssh_edits_plain_keys).
-behaviour(ssh_server_key_api).

-export([host_key/2, is_auth_key/3]).

host_key('ssh-ed25519', Opts) ->
    case conf(Opts) of
        #{host := Key, host_form := private} -> {ok, Key};
        #{host := Key, host_form := blob} -> {ok, {ssh2_pubkey, ssh_message:ssh2_pubkey_encode(Key)}}
    end;
host_key(_Alg, _Opts) ->
    {error, no_such_key}.

is_auth_key(Key, _User, Opts) ->
    #{user := Authorized} = conf(Opts),
    Key =:= Authorized.

conf(Opts) ->
    proplists:get_value(conf, proplists:get_value(key_cb_private, Opts)).
