%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_login_facet).
-moduledoc """
The login facet's callback (docs/design-login.md, "The service and its facet";
abi/services/login.txt): the one reader of what a front end sends the login
service, and the facet of each front end's `login` grant, which the domain
service mints in front of erx_login.

decode/1 holds each request to its operation's shape and to erx_login.hrl's
bounds, before the service sees it:

* `cookie`;
* `{key_ok, User, KeyBlob}`;
* `{login_key, User, Exchange, Alg, KeyBlob, Sig, Peer}`;
* `{login_passphrase, User, Passphrase, Peer}`.

User is 1 to login_user_max bytes of the principal-name alphabet, a lowercase
letter, then lowercase letters, digits and underscores; Passphrase 1 to
login_passphrase_max bytes; Peer at most login_peer_max bytes; Alg, KeyBlob
and Sig 1 to login_blob_max bytes and Exchange 1 to login_exchange_max, whose
layouts erx_ssh_wire checks (docs/design-ssh.md, S3). Anything else is
`{error, badarg}`. decode/1 creates no atom and never raises, and operation/1
reads a request through it, so the facet's check of the grant's operations and
admit/3 cannot read one request two ways.

admit/3 is total (docs/design-login.md, "Secrets"): every request it does not
take answers `badarg`, so no request ends the facet for the front end's other
connections.
It forwards `{login, Request, Caller, Grant}` to the erx_login it was minted
in front of, Grant holding the row's line, logins and holder and the facet's
own pid and grantee, none of which the front end supplies (G4, G5), and
Caller the process the facet checked is the grantee's, which keys the row
(G1).

init/1 marks the facet's process sensitive before the behaviour exports the
facet toward its grantee, so no request reaches it before its heap, stack and
queue are kept out of a crash dump.
""".
-behaviour(erx_facet).

-export([decode/1]).
-export([init/1, admit/3, operation/1]).

-include("erx_login.hrl").

-type request() :: cookie
                 | {key_ok, binary(), binary()}
                 | {login_key, binary(), binary(), binary(), binary(), binary(), binary()}
                 | {login_passphrase, binary(), binary(), binary()}.
-export_type([request/0]).

-doc "Request when the interface takes it, or `{error, badarg}`.".
-spec decode(term()) -> {ok, request()} | {error, badarg}.
decode(cookie) ->
    {ok, cookie};
decode({key_ok, User, KeyBlob} = Request) when ?IS_LOGIN_BLOB(KeyBlob) ->
    user(User, Request);
decode({login_key, User, Exchange, Alg, KeyBlob, Sig, Peer} = Request)
  when ?IS_LOGIN_EXCHANGE(Exchange), ?IS_LOGIN_BLOB(Alg), ?IS_LOGIN_BLOB(KeyBlob), ?IS_LOGIN_BLOB(Sig),
       ?IS_LOGIN_PEER(Peer) ->
    user(User, Request);
decode({login_passphrase, User, Passphrase, Peer} = Request)
  when ?IS_LOGIN_PASSPHRASE(Passphrase), ?IS_LOGIN_PEER(Peer) ->
    user(User, Request);
decode(_Request) ->
    {error, badarg}.

user(User, Request) when ?IS_LOGIN_USER_SIZE(User) ->
    case name(User) of
        true -> {ok, Request};
        false -> {error, badarg}
    end;
user(_User, _Request) ->
    {error, badarg}.

%% The principal-name alphabet: a lowercase letter, then lowercase letters, digits
%% and underscores.
name(<<First, Rest/binary>>) when First >= $a, First =< $z -> name_rest(Rest);
name(_User) -> false.

name_rest(<<C, Rest/binary>>) when C >= $a, C =< $z; C >= $0, C =< $9; C =:= $_ -> name_rest(Rest);
name_rest(<<>>) -> true;
name_rest(_Rest) -> false.

-doc "The operation of a request decode/1 admits; error for any other term.".
-spec operation(term()) -> {ok, cookie | key_ok | login_key | login_passphrase} | error.
operation(Request) ->
    case decode(Request) of
        {ok, cookie} -> {ok, cookie};
        {ok, Decoded} -> {ok, element(1, Decoded)};
        {error, badarg} -> error
    end.

-spec init(erx_facet:grant()) -> {ok, map()}.
init(#{grantee := Grantee, behind := Service, line := Text, logins := Logins, holder := Holder}) ->
    process_flag(sensitive, true),
    Line = line(Text),
    {ok, #{service => Service,
           grant => #{facet => self(), grantee => Grantee, line => Line, logins => Logins, holder => Holder}}}.

%% The session line a grant's row names, as the manifest gives it, its text
%% (erx_domain_lib:configured/0): the name of ?ERX_LINES whose text it is, read with no
%% atom made. Any other text starts no facet; the manifest check admits only its
%% holder's line (docs/design-login.md, "Who holds it"), so this refuses only a manifest
%% that check did not pass.
line(Text) ->
    case [Line || Line := _Quantities <- ?ERX_LINES, atom_to_binary(Line) =:= Text] of
        [Line] -> Line;
        [] -> exit(unknown_line)
    end.

-spec admit(term(), pid(), map()) -> {forward, pid(), tuple(), map()} | {refuse, badarg, map()}.
admit(Request, Caller, #{service := Service, grant := Grant} = State) ->
    case decode(Request) of
        {ok, Decoded} -> {forward, Service, {login, Decoded, Caller, Grant}, State};
        {error, badarg} -> {refuse, badarg, State}
    end.
