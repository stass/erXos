%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ssh_dev).
-moduledoc """
SSH's first stage (docs/design-ssh.md, "Stages"): in a development build,
start(Port) run in root's session starts OTP's ssh daemon in that session,
through root's own `net` grant, whose session channels each run the command
shell or a command on a tty of the session, or a command as a job of the
session when the client asked for no tty (erx_ssh_dev_channel). It is a principal
running a daemon in its own session with its own authority, and needs no
facet of its own. start/1 starts nothing unless the build facts of this
runtime's release name a development configuration
(erx_build:development_facts/1): the image build writes them into every
release, a session domain's included, and facts it cannot read count as a
release build's. Root's session runs boot/1 at boot, as the development manifest's
`-eval` asks, which starts the daemon once the session holds the facets it
needs, registers it as `erx_ssh_dev`, and then imports root's keys.

Who may log in is `root`, with a key of root's: a line of root's home copy,
HOME_KEYS, FreeBSD's `.ssh/authorized_keys` in root's home, or the
development login key, whose public half the image build writes into each
release of a development image at abi/erx_abi.txt's `ssh_authorized_keys_path`
under the release's root (docs/design-ssh.md, "Login keys"). Both files are
read at each login, for at most one byte past erx_boot_keys:file_max/0, and
decoded by erx_boot_keys:decode/1, so a line with options or of another key
type is no key and a longer file admits none of its keys; a file that does
not read admits none, and nothing else stands in for it. This module is the
daemon's key callback: it admits those keys for the user `root` and no other
name, where OTP's `ssh_file` would read a second file beside the development
one for every user name, and it offers public keys as the only method, with
at most MAX_AUTH_TRIES failed attempts a connection, FreeBSD's `MaxAuthTries`.

**The import** (docs/design-ssh.md, "Root's login keys on the medium") is
the first boot's: the user writes `authorized_keys` on the medium's FAT
volume, as on Raspberry Pi OS, and the storage domain serves its keys as the
`login_keys` tree, one file `root` of 51-byte key blobs, read-only. import/2
writes them into the home copy only while there is none: a home copy that is
there, whatever it holds, is never read for the import or replaced, so
deleting it imports the medium's keys again at the next boot. With no home
copy it reads `root` for at most MEDIUM_READ bytes, one past the blobs of
ssh_authorized_keys_max (abi/formats/ssh.txt) keys, once the session holds
its `home` and `login_keys` facets; a step that fails with `eagain`, while
the storage domain's reader runs, or `eio` writes nothing and is tried again
within ten minutes of the daemon's start, any other failure writes nothing
and ends the import, and an answer of no key, of no whole
number of blobs within that count, or of blobs that are no Ed25519 key,
writes nothing at all, so no empty home copy shuts the medium's keys out. The keys
are written one canonical line each, `ssh-ed25519` and the blob's base64,
whole and synced under a name of their own and renamed into place, so the
home copy is either absent or whole. Root's session can write the home copy,
so whatever runs in it can add a login: a limitation of the development
builds before the vault.

The host key, Ed25519, is root's own, in HOST_DIR on root's data volume,
in OpenSSH's private key format. start/1 makes it when the file is missing
and refuses to start when the file does not decode, so the key a client
pinned never changes silently; removing the file asks for a new one. A key
it makes is written as the import writes the home copy, readable by its
owner alone where the file system keeps modes.

What keeps the development key out of a release build is that its image
carries no login-key file and that start/1 refuses it. Only boot/1, start/1
and the key callback are exported, so no entry of the module as the build compiles
it names another keys file; the host tests compile it with TEST defined to
reach daemon/2 and import/2, which do. The session's own authority is not
narrowed by that: any code it runs may start OTP's daemon with keys of its choosing.
""".

-behaviour(ssh_server_key_api).

-include("generated/erx_abi.hrl").

-export([boot/1, start/1]).
-export([host_key/2, is_auth_key/3]).

-ifdef(TEST).
-export([boot/2, daemon/2, import/2]).
-endif.

-define(HOST_DIR, "/data/ssh").
-define(HOST_KEY, "ssh_host_ed25519_key").
-define(HOME_KEYS, "/root/.ssh/authorized_keys").
-define(USER, "root").
-define(MAX_AUTH_TRIES, 6).
%% The version banner, SSH-2.0-erXos_<release>: the softwareversion of RFC 4253, section 4.2,
%% printable US-ASCII without spaces or minus signs. The system name and the release
%% number are abi/erx_abi.txt's `uname_sysname` and `uname_release`, and the case
%% erx_ssh_dev_tests:the_banner_names_erxos checks the line against those limits.
-define(ID_STRING, binary_to_list(<<?ERX_UNAME_SYSNAME_BYTES/binary, "_", ?ERX_UNAME_RELEASE_BYTES/binary>>)).
-define(MEDIUM_READ, (?ERX_SSH_AUTHORIZED_KEYS_MAX * erx_boot_keys:blob_size() + 1)).
%% How long boot/1 waits for the session's net and data facets from the boot, and the
%% import for its home and login_keys facets and the medium's answer from the daemon's
%% start: ten minutes each, after which it stops. A medium that answers eagain or eio
%% is read again every MEDIUM_RETRY_MS within the import's ten minutes.
-define(GRANT_WAIT_MS, 600_000).
-define(MEDIUM_RETRY_MS, 500).

%% What the daemon is given: keys, the file of the development login key, and home,
%% root's home copy, each of `authorized_keys` lines; host, the directory of the host
%% key, made there when missing; open, the opener of a channel's tty; and job, the
%% starter of a channel's job relay (erx_ssh_dev_channel).
-type options() :: #{keys := file:filename(), home := file:filename(), host := file:filename(),
                     open := fun((pid(), erx_session_tty:channel(), fun((term()) -> term())) ->
                                        {ok, pid()} | {error, term()}),
                     job := fun((binary()) -> {pid(), erx_ssh_job:tag()})}.
%% The reader of the `login_keys` tree's `root`, the medium's key blobs.
-type medium() :: fun(() -> {ok, binary()} | {error, term()}).
%% What one import did: wrote N keys, found a home copy and kept it, found no key on
%% the medium, or wrote nothing, for the reason it names.
-type import() :: {imported, pos_integer()} | kept | no_keys | {retry, term()}.
%% A deadline as erx_facets:await/3 takes it, in erlang:monotonic_time(millisecond).
-type deadline() :: {abs, integer()}.

-doc """
Starts the daemon on Port at the session's boot (docs/design-ssh.md,
"Stages"), in a process of its own, and returns at once. The daemon listens
through the session's `net` facet and keeps its host key under `/data`,
through its `data` facet, and their domains install both some time after the
session is ready (erx:cap/1), so the process waits for the two through the
registry wait (erx_facets:await/3) for at most GRANT_WAIT_MS from the boot,
and then calls start/1. A daemon that started is registered as `erx_ssh_dev`
(named/1), so the name lives exactly as long as the daemon and a tool that sees
it sees a running daemon, and the process then imports root's keys from
the medium once the session holds its `home` and `login_keys` facets, within
GRANT_WAIT_MS of the daemon's start; each step logs one line.
""".
-spec boot(inet:port_number()) -> ok.
boot(Port) ->
    boot(Port, fun start/1).

-doc """
boot/1 with Start in place of start/1, so a host test sees when the daemon would
start. Exported only to the host tests (TEST).
""".
-spec boot(inet:port_number(), fun((inet:port_number()) -> {ok, pid()} | {error, term()})) -> ok.
boot(Port, Start) ->
    Deadline = deadline(),
    _ = spawn(fun() -> booted(Port, start_when_granted(Port, Start, Deadline)) end),
    ok.

start_when_granted(Port, Start, Deadline) ->
    case installed([net, data], Deadline) of
        ok -> Start(Port);
        {error, _} = Missing -> Missing
    end.

booted(Port, {ok, Daemon}) ->
    true = named(Daemon),
    logger:notice("erx_ssh_dev: the daemon listens on port ~b", [Port]),
    imported(import_when_ready(deadline()));
booted(Port, {error, Reason}) ->
    logger:notice("erx_ssh_dev: no daemon on port ~b: ~0p", [Port, Reason]).

%% Registers Daemon as erx_ssh_dev. OTP's ssh declares ssh:daemon_ref() opaque over
%% the pid of the daemon's supervisor (otp/lib/ssh/src/ssh.erl), which register/2
%% takes, and no other interface of ssh's gives a process whose life is the daemon's,
%% so this one function reads the reference as the pid it is.
-dialyzer({no_opaque, named/1}).
named(Daemon) ->
    register(?MODULE, Daemon).

%% GRANT_WAIT_MS from now, as erx_facets:await/3 takes a deadline.
deadline() ->
    {abs, erlang:monotonic_time(millisecond) + ?GRANT_WAIT_MS}.

%% ok once the registry holds a facet of each of Names, or the first name it holds none
%% of when Deadline passes, or when the runtime is no node and no agent writes it.
-spec installed([atom()], deadline()) -> ok | {error, {no_grant, atom()}}.
installed([], _Deadline) ->
    ok;
installed([Name | Names], Deadline) ->
    case erx_facets:await(Name, none, Deadline) of
        {ok, _Facet} -> installed(Names, Deadline);
        Missing when Missing =:= timeout; Missing =:= {error, noproc} -> {error, {no_grant, Name}}
    end.

%% The home copy lies on the session's `home` facet, mounted at /root, and the medium's
%% keys on its `login_keys` facet, so the import waits for both, and then for the
%% medium's answer.
-spec import_when_ready(deadline()) -> import().
import_when_ready(Deadline) ->
    case installed([home, login_keys], Deadline) of
        ok -> import_by(Deadline);
        {error, Reason} -> {retry, Reason}
    end.

%% One import, tried again every MEDIUM_RETRY_MS while a step of it fails with eagain or
%% eio, the medium's reader not yet answering, until Deadline.
-spec import_by(deadline()) -> import().
import_by({abs, At} = Deadline) ->
    case import(?HOME_KEYS, fun medium_file/0) of
        {retry, Reason} when Reason =:= eagain; Reason =:= eio ->
            case erlang:monotonic_time(millisecond) + ?MEDIUM_RETRY_MS < At of
                true -> timer:sleep(?MEDIUM_RETRY_MS), import_by(Deadline);
                false -> {retry, {Reason, "no answer within ten minutes"}}
            end;
        Done ->
            Done
    end.

imported({imported, Count}) ->
    logger:notice("erx_ssh_dev: ~b login keys of the medium imported into ~s", [Count, ?HOME_KEYS]);
imported(kept) ->
    ok;
imported(no_keys) ->
    logger:notice("erx_ssh_dev: no login key on the medium to import into ~s", [?HOME_KEYS]);
imported({retry, Why}) ->
    logger:notice("erx_ssh_dev: no login keys imported into ~s: ~0p", [?HOME_KEYS, Why]).

-doc """
Starts the daemon on Port with root's login keys and host key, in a
development build; in any other it starts nothing and answers
`{error, {not_development, Why}}`.
""".
-spec start(inet:port_number()) -> {ok, ssh:daemon_ref()} | {error, term()}.
start(Port) ->
    case erx_build:development_facts(erx_build:facts()) of
        true ->
            Keys = filename:join(code:root_dir(), binary_to_list(?ERX_SSH_AUTHORIZED_KEYS_PATH_BYTES)),
            daemon(Port, #{keys => Keys, home => ?HOME_KEYS, host => ?HOST_DIR,
                           open => fun erx_session_tty:open_channel/3,
                           job => fun erx_session_tty:open_job/1});
        false ->
            {error, {not_development, "the release's build facts name no development build"}}
    end.

%% Starts the daemon on Port with Options (options()). Exported only to the host
%% tests (TEST), which name every option. Session channels are
%% erx_ssh_dev_channel's, and no subsystem is offered.
-spec daemon(inet:port_number(), options()) -> {ok, ssh:daemon_ref()} | {error, term()}.
daemon(Port, #{keys := Keys, home := Home, host := Host, open := Open, job := Job}) ->
    maybe
        ok ?= host_key_file(Host),
        {ok, _} ?= application:ensure_all_started(ssh),
        ssh:daemon(Port, [{system_dir, Host},
                          {key_cb, {?MODULE, [{keys, [Home, Keys]}]}},
                          {auth_methods, "publickey"},
                          {max_auth_tries, ?MAX_AUTH_TRIES},
                          {id_string, ?ID_STRING},
                          {ssh_cli, {erx_ssh_dev_channel, [Open, Job]}},
                          {subsystems, []}])
    end.

-doc "The host key, as `ssh_file` reads it from the daemon's `system_dir`.".
host_key(Algorithm, Options) ->
    ssh_file:host_key(Algorithm, Options).

-doc """
Whether Key is one of root's login keys and User is `root`: any other user
name has none. The keys are those erx_boot_keys decodes from exactly the home
copy and the development file daemon/2 was given, each blob compared whole
with the offered key's encoding, so no second file beside them adds one and
nothing here writes either.
""".
is_auth_key(Key, ?USER, Options) ->
    [{keys, Files}] = proplists:get_value(key_cb_private, Options),
    Blob = ssh_file:encode(Key, ssh2_pubkey),
    lists:any(fun(File) -> lists:member(Blob, file_keys(File)) end, Files);
is_auth_key(_Key, _User, _Options) ->
    false.

%% The key blobs of the authorized_keys file at Path: none when it does not read or
%% erx_boot_keys refuses it. One byte past the decoder's bound is enough for it to
%% refuse a longer file, so no more is read.
file_keys(Path) ->
    maybe
        {ok, Fd} ?= file:open(Path, [read, binary]),
        {ok, Bytes} ?= try read_at_most(Fd, erx_boot_keys:file_max() + 1, []) after file:close(Fd) end,
        {ok, Blobs, _Findings} ?= erx_boot_keys:decode(Bytes),
        Blobs
    else
        _ -> []
    end.

-doc """
Imports the medium's keys into the home copy at Home, reading the medium with
Medium only when Home is absent (the module's documentation, "The import").
Exported only to the host tests (TEST).
""".
-spec import(file:filename(), medium()) -> import().
import(Home, Medium) ->
    case file:read_file_info(Home) of
        {ok, _} -> kept;
        {error, enoent} -> import_keys(Home, Medium());
        {error, Reason} -> {retry, Reason}
    end.

import_keys(_Home, {error, Reason}) ->
    {retry, Reason};
import_keys(Home, {ok, Bytes}) ->
    case canonical(medium_keys(Bytes)) of
        {_Text, 0} ->
            no_keys;
        {Text, Count} ->
            case install(filename:dirname(Home), Home, Text) of
                ok -> {imported, Count};
                {error, Reason} -> {retry, Reason}
            end
    end.

%% The medium's key blobs in Bytes, the bytes of the tree's `root`: none when they
%% are no whole number of blobs within ssh_authorized_keys_max.
medium_keys(Bytes) ->
    Size = erx_boot_keys:blob_size(),
    case byte_size(Bytes) rem Size =:= 0 andalso byte_size(Bytes) =< ?ERX_SSH_AUTHORIZED_KEYS_MAX * Size of
        true -> [Blob || <<Blob:Size/binary>> <= Bytes];
        false -> []
    end.

%% The home copy's text for Blobs, one `ssh-ed25519 BASE64` line each, and its count
%% of keys: the lines are decoded as a login reads them and only the keys that decode
%% are written, so a blob of the medium's that is no Ed25519 key is dropped.
canonical(Blobs) ->
    Lines = [[<<"ssh-ed25519 ">>, base64:encode(Blob), <<"\n">>] || Blob <- Blobs],
    {ok, Keys, _Findings} = erx_boot_keys:decode(iolist_to_binary(Lines)),
    {iolist_to_binary([[<<"ssh-ed25519 ">>, base64:encode(Key), <<"\n">>] || Key <- Keys]), length(Keys)}.

%% The tree's `root` through the session's grant of login_keys, read from its start
%% for at most MEDIUM_READ bytes, without read-ahead.
medium_file() ->
    case erx_facets:file_grant(login_keys, ro) of
        {ok, Grant} ->
            case erx_file_remote:open(Grant, {target, [<<"root">>]}, [read, binary]) of
                {ok, Fd} ->
                    try read_at_most(Fd, ?MEDIUM_READ, []) after file:close(Fd) end;
                {resume, _, _} -> {error, einval};
                {error, _} = Error ->
                    Error
            end;
        {error, _} ->
            {error, no_grant}
    end.

read_at_most(_Fd, 0, Read) ->
    {ok, iolist_to_binary(lists:reverse(Read))};
read_at_most(Fd, Left, Read) ->
    case file:read(Fd, Left) of
        {ok, Bytes} -> read_at_most(Fd, Left - byte_size(Bytes), [Bytes | Read]);
        eof -> {ok, iolist_to_binary(lists:reverse(Read))};
        {error, _} = Error -> Error
    end.

%% The host key file in Dir: one that decodes is kept, a missing one is made,
%% and one that does not decode stops the start. It is read as the daemon reads
%% it, through ssh_file.
host_key_file(Dir) ->
    Path = filename:join(Dir, ?HOST_KEY),
    case file:read_file_info(Path) of
        {ok, _} ->
            case ssh_file:host_key('ssh-ed25519', [{system_dir, Dir}]) of
                {ok, _Key} -> ok;
                {error, _} -> {error, {host_key, Path, "does not decode; remove it to make a new one"}}
            end;
        {error, enoent} ->
            make_host_key(Dir, Path);
        {error, Reason} ->
            {error, {host_key, Path, Reason}}
    end.

%% A new key, installed at Path. Two starts racing on a missing key each make one,
%% and the later rename wins.
make_host_key(Dir, Path) ->
    Key = public_key:generate_key({namedCurve, ed25519}),
    case install(Dir, Path, ssh_file:encode([{[{Key, <<>>}], []}], openssh_key_v1)) of
        ok -> ok;
        {error, Reason} -> {error, {host_key, Path, Reason}}
    end.

%% Bytes written whole and synced under a name of its own beside Path, then renamed
%% to Path, so a write that fails or stops part way leaves no file at Path, and a
%% failed one deletes its file. Dir is made when missing, and it is 0700 and the file
%% 0600 before any byte is written, where the file system keeps modes.
install(Dir, Path, Bytes) ->
    New = Path ++ ".new." ++ integer_to_list(erlang:unique_integer([positive])),
    maybe
        ok ?= owner_only_dir(Dir),
        ok ?= write_owner_only(New, Bytes),
        file:rename(New, Path)
    else
        {error, _} = Error ->
            _ = file:delete(New),
            Error
    end.

owner_only_dir(Dir) ->
    case file:make_dir(Dir) of
        Made when Made =:= ok; Made =:= {error, eexist} -> kept_modes(file:change_mode(Dir, 8#700));
        {error, _} = Error -> Error
    end.

%% The file is closed whatever happens, and the first error is the answer.
write_owner_only(Path, Bytes) ->
    maybe
        {ok, Device} ?= file:open(Path, [write, binary]),
        Written = maybe
                      ok ?= kept_modes(file:change_mode(Path, 8#600)),
                      ok ?= file:write(Device, Bytes),
                      file:sync(Device)
                  end,
        Closed = file:close(Device),
        ok ?= Written,
        Closed
    end.

%% A file server that keeps no modes may refuse a change of them with enotsup
%% (littlefs's file server accepts one and keeps nothing); its files have no
%% modes to narrow.
kept_modes(ok) -> ok;
kept_modes({error, enotsup}) -> ok;
kept_modes({error, _} = Error) -> Error.
