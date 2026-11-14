%%
%% %CopyrightBegin%
%%
%% SPDX-License-Identifier: Apache-2.0
%%
%% Copyright Ericsson AB 2011-2025. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% %CopyrightEnd%
%%
%% Modified by erXos: the optional callbacks kex_cookie/1, verify_user/6 and sign/3,
%% and host_key/2 may answer {ok, {ssh2_pubkey, Blob}}.

-module(ssh_server_key_api).
-moduledoc """
\-behaviour(ssh_server_key_api).

Behaviour describing the API for public key handling of an SSH server. By
implementing the callbacks defined in this behavior, the public key handling of
an SSH server can be customized. By default the SSH application implements this
behavior with help of the standard OpenSSH files, see the [ssh](ssh_app.md)
application manual.
""".
-moduledoc(#{since => "OTP R16B"}).

-include_lib("public_key/include/public_key.hrl").
-include("ssh.hrl").

-export_type([daemon_key_cb_options/1]).

%%%****************************************************************
%%% The option key_cb_private is to pass options needed by other
%%% callback modules than the default ssh_file.erl
%%%
%%% If ssh:daemon(n, [ {key_cb_private, {hi,{there}}} ]
%%% is called, the term() will be {hi,{there}}

-doc """
Options provided to [ssh:daemon/2,3](`ssh:daemon/2`).

The option list given in the [`key_cb`](`t:ssh:key_cb_common_option/0`) option
is available with the key `key_cb_private`.
""".
-type daemon_key_cb_options(T) :: [{key_cb_private,[T]} | ssh:daemon_option()].


%%%****************************************************************
%%% Fetch the host's private key that is of type Algorithm.

-doc """
Fetches the private key of the host, or the public key blob of a host key the
callback module holds and signs with in [`Module:sign/3`](`c:sign/3`).
""".
-doc(#{since => <<"OTP R16B">>}).
-callback host_key(Algorithm :: ssh:pubkey_alg(),
		   DaemonOptions :: daemon_key_cb_options(any())
                  ) ->
    {ok, PrivateKey :: public_key:private_key()} |
    {ok, {ssh2_pubkey, PubKeyBlob :: binary()}} |
    {error, term()}.

%%%****************************************************************
%%% Check that PublicKey is known to be a public key for the User

-doc "Checks if the user key is authorized.".
-doc(#{since => <<"OTP R16B">>}).
-callback is_auth_key(PublicKey :: public_key:public_key(),
		      User :: string(),
		      DaemonOptions :: daemon_key_cb_options(any())
                     ) ->
    boolean().

%%%****************************************************************
%%% erXos's hooks: a host key the module holds, and a login decided
%%% outside the daemon from the first key exchange it did itself.

-doc """
Signs the exchange hash `SigData` with the _private_ key of the host key whose
public blob [`Module:host_key/2`](`c:host_key/2`) answered, and returns the
bare signature.
""".
-callback sign(PubKeyBlob :: binary(),
               SigData :: binary(),
               DaemonOptions :: daemon_key_cb_options(any())) ->
    Signature :: binary().

-doc """
Answers the 16-byte cookie of the server's first `SSH_MSG_KEXINIT` on a
connection. Any other answer, or an exception, ends the connection before its
key exchange. A rekeying takes a random cookie without asking.
""".
-callback kex_cookie(DaemonOptions :: daemon_key_cb_options(any())) ->
    Cookie :: <<_:128>>.

-doc """
Checks a `publickey` signature that the daemon's own check has accepted.
`KexInput` is the hash input of the connection's first key exchange, whose
hash is the session identifier, and `SigBlob` the signature blob of RFC 4252,
the algorithm name and the signature, each a length-prefixed string. Only
`true` admits the attempt.
""".
-callback verify_user(User :: string(),
                      Algorithm :: string(),
                      PubKeyBlob :: binary(),
                      KexInput :: binary(),
                      SigBlob :: binary(),
                      DaemonOptions :: daemon_key_cb_options(any())) ->
    boolean().

-optional_callbacks([sign/3, kex_cookie/1, verify_user/6]).
