%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A daemon key callback that exports every hook erXos's ssh adds
%% (docs/design-ssh.md, "Edits to OTP's ssh"), for erx_ssh_edits_tests.
%% It plays the login facet's part on the host: kex_cookie/1 answers the
%% cookie the test configured, and verify_user/6 takes the SHA-256 of the
%% exchange input it is given as the session identifier, builds RFC 4252's
%% signed data from it and checks the signature inside the signature blob
%% with public_key, as the facet's check does. Each call is reported to the
%% test process with the caller's pid, which is the connection's handler.
%%
%% The configuration is the map under `conf` in key_cb_private:
%% `test` (the pid told of each call), `host` (the host's private key),
%% `host_form` (`private`, `blob`, or `padded`, a blob with a byte after it:
%% what host_key/2 returns), `user` (the
%% one authorized public key) and `cookie` (what kex_cookie/1 answers).
-module(erx_ssh_edits_keys).
-behaviour(ssh_server_key_api).

-export([host_key/2, is_auth_key/3, kex_cookie/1, verify_user/6, sign/3]).
-export([signed_data/4]).

host_key('ssh-ed25519', Opts) ->
    case conf(Opts) of
        #{host := Key, host_form := private} -> {ok, Key};
        #{host := Key, host_form := blob} -> {ok, {ssh2_pubkey, ssh_message:ssh2_pubkey_encode(Key)}};
        #{host := Key, host_form := padded} -> {ok, {ssh2_pubkey, <<(ssh_message:ssh2_pubkey_encode(Key))/binary, 0>>}}
    end;
host_key(_Alg, _Opts) ->
    {error, no_such_key}.

is_auth_key(Key, _User, Opts) ->
    #{user := Authorized} = conf(Opts),
    Key =:= Authorized.

kex_cookie(Opts) ->
    #{test := Test, cookie := Cookie} = conf(Opts),
    Test ! {kex_cookie, self(), Cookie},
    Cookie.

sign(Blob, Data, Opts) ->
    #{test := Test, host := Key} = conf(Opts),
    Blob = ssh_message:ssh2_pubkey_encode(Key),
    Test ! {sign, self(), Data},
    public_key:sign(Data, none, Key).

verify_user(User, Alg, KeyBlob, Input, AlgSig, Opts) ->
    #{test := Test} = conf(Opts),
    Test ! {verify_user, self(), Input, AlgSig},
    case AlgSig of
        <<11:32, "ssh-ed25519", 64:32, Sig:64/binary>> when Alg =:= "ssh-ed25519" ->
            Data = signed_data(crypto:hash(sha256, Input), User, Alg, KeyBlob),
            public_key:verify(Data, none, Sig, ssh_message:ssh2_pubkey_decode(KeyBlob));
        _ ->
            false
    end.

%% RFC 4252, section 7: what a publickey signature covers.
signed_data(SessionId, User, Alg, KeyBlob) ->
    iolist_to_binary([string(SessionId), 50, string(unicode:characters_to_binary(User)),
                      string(<<"ssh-connection">>), string(<<"publickey">>), 1,
                      string(list_to_binary(Alg)), string(KeyBlob)]).

string(Bin) -> <<(byte_size(Bin)):32, Bin/binary>>.

conf(Opts) ->
    proplists:get_value(conf, proplists:get_value(key_cb_private, Opts)).
