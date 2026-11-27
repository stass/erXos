%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_machine_fs).
-moduledoc """
The `machine` tree (docs/design-system.md, "A session's request"): the
`erx_fs` callback module the domain service serves `/svc/machine/ctl` with,
which a session whose template holds the `machine` grant finds at
`/svc/machine`, and the system domain mounts there its own grant of it.

* **Serving.** start_link/0 starts the tree's grants (erx_fs_grants) and
  names them the process behind the system domain's `machine` service
  (erx_facet:serve/2). The domain service asks it, in each grantee's ready
  answer, for one erx_fs grant bound to that session and ending with it,
  and starts the grant with the grantee's user name as the grant's own
  argument, which it computes at the mint. One more grant, for the system
  domain itself and with the system principal's user name, root, is mounted at
  `/svc/machine` in the system domain's namespace (erx_ns:mount_own/2), so
  the system shell's `reboot` and `halt` write the path a session's do
  (docs/design-shell.md, "Interfaces").
* **ctl.** Write-only, mode `0200`; an open for reading is refused with
  `eacces`. A write is one end, whatever its offset: parse/1 takes `reset`
  or `off` with at most one trailing newline and refuses any other bytes
  with `einval`. The end goes to the coordinator's one entry,
  erx_machine:request/2, with the grant's user name; the request carries
  nothing else. The write succeeds once the coordinator accepted the
  request, answers `ebusy` once an earlier request was accepted, and `eio`
  when the coordinator ended before it answered.
* **Who may write ctl.** Whoever holds the grant: holding the grant is the
  right to end the machine, and the tree does not check who a writer is.

Every decision is a pure function of a node, the open flags, the written
bytes or the coordinator's answer. The one effect is the call to the
coordinator, which a test stands in for.
""".

-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([start_link/0, parse/1, errno/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2]).

%% The service's name in the manifest, and the tree's name, which root/1 answers, the
%% mint's reply carries and attach's Aname names.
-define(SERVICE, machine).
-define(TREE, <<"machine">>).

-type node_() :: root | ctl.
-type errno() :: einval | ebusy | eio.

-doc """
Starts the tree's grants, linked to the caller, erx_domain_sup, names them
the process behind the `machine` service, and mounts the system domain's
own grant at `/svc/machine`.
""".
-spec start_link() -> {ok, pid()}.
start_link() ->
    {ok, Grants} = erx_fs_grants:start_link(?MODULE),
    ok = erx_facet:serve(?SERVICE, Grants),
    {ok, Own} = erx_fs_grants:own(Grants, erx_domain_core:system_user()),
    ok = erx_ns:mount_own(?SERVICE, Own),
    {ok, Grants}.

-doc """
The end one ctl write Bytes asks for: `reset` or `off`, with at most one
trailing newline, or `{error, einval}` for any other bytes, `trial` and an
empty write included.
""".
-spec parse(binary()) -> {ok, erx_machine:'end'()} | {error, einval}.
parse(<<"reset">>) -> {ok, reset};
parse(<<"reset\n">>) -> {ok, reset};
parse(<<"off">>) -> {ok, off};
parse(<<"off\n">>) -> {ok, off};
parse(Bytes) when is_binary(Bytes) -> {error, einval}.

-doc """
The errno a ctl write answers for the coordinator's Answer: none for `ok`,
`ebusy` for `busy`, and `eio` for a coordinator that ended before it
answered.
""".
-spec errno(ok | busy | ended) -> ok | {error, errno()}.
errno(ok) -> ok;
errno(busy) -> {error, ebusy};
errno(ended) -> {error, eio}.

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

%% Each grant's argument is its grantee's user name, which the domain service computed
%% at the mint, root for the system domain's own grant; a test hands a map with a
%% stand-in for the coordinator.
-doc false.
init(Principal) when is_binary(Principal) ->
    {ok, #{principal => Principal, request => fun erx_machine:request/2}};
init(#{principal := _, request := Request} = Fs) when is_function(Request, 2) ->
    {ok, Fs}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, <<"ctl">>, _Fs) -> {ok, ctl, qid(ctl)};
walk(root, _Name, _Fs) -> {error, enoent};
walk(ctl, _Name, _Fs) -> {error, enotdir}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr(ctl, _Fs) -> erx_fs_node:attr(qid(ctl), file, 8#200).

%% ctl opens for writing only, the root for reading only.
-doc false.
open(ctl, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_WRONLY -> {ok, ctl};
        _ -> {error, eacces}
    end;
open(root, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, erx_fs_node:listing([{qid(ctl), ?ERX_P9_DT_REG, <<"ctl">>}])};
        _ -> {error, eisdir}
    end.

-doc false.
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir};
read(ctl, _Offset, _Count, _Fs) ->
    {error, eacces}.

-doc false.
write(ctl, Offset, Bytes, Fs) ->
    case parse(Bytes) of
        {ok, End} ->
            case errno(request(End, Fs)) of
                ok -> {ok, byte_size(Bytes), Offset};
                {error, _} = Refused -> Refused
            end;
        {error, einval} = Refused ->
            Refused
    end;
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% The coordinator's answer; one that ended during the call answers nothing.
request(End, #{principal := Principal, request := Request}) ->
    try Request(End, Principal)
    catch exit:_ -> ended
    end.

%% A create of ctl opens it (erx_fs_node:open_by_create/4); the tree makes nothing else.
-doc false.
make(root, <<"ctl">>, {file, _Mode, Flags}, Fs) ->
    erx_fs_node:open_by_create(ctl, qid(ctl), Flags, fun(F) -> open(ctl, F, Fs) end);
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk(_Handle, _Fs) ->
    ok.


%% A node's qid is fixed, the same in every grant: the tree has two nodes.
-spec qid(node_()) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 1};
qid(ctl) -> {0, 0, 2}.
