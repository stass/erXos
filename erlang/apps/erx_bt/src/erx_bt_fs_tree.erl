%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_fs_tree).
-moduledoc """
The Bluetooth domain's control tree (docs/design-bluetooth.md, "The pairing window",
"Bonds and the store"): the `erx_fs` callback module whose grant's argument is the file
service, `erx_bt_fs`, which keeps the window and the tree's waiting reads. The tree holds
`pair` and `ctl`.

* **pair** opens for reading and writing, and each open is a window: the callback asks
  the file service, which answers `ebusy` while another window is open or the pairing a
  closed one took has no outcome, and `eio` while the store is `unknown` since its start.
  The first write, parsed by `erx_bt_window:parse/1`, is the window's mode; a read waits
  for the window's next line as a waiting request the file service keeps
  (docs/design-files.md, "Waiting requests"), and reads the end of the file once the
  lines have ended. Offsets are ignored: `pair` is a stream. Clunking the open closes
  the window, and withdraws a pairing it took that the link still runs.
* **ctl** opens for writing only; an open for reading is refused with `eacces`.
  parse/1 takes `forget ADDRESS TYPE` and `forget all` and refuses anything else with
  `einval`. The callback asks the store to forget (`erx_bt_store:forget/1`), which
  answers `enoent` when no bond has that identity and `eio` when it stays `unknown` or
  its put is unconfirmed. A confirmed forget leaves the store `read`, and the callback
  tells the file service so, which ends the window's refusal since the store's start.

Opens by create, which a client's `[write]` open sends with `O_TRUNC`, open the file
named and ignore `O_TRUNC`; the tree makes nothing.

Every callback does bounded work (docs/design-files.md, "Waiting requests"): a call of
the file service, which answers without waiting for an event; a read handed to it; or
ctl's forget, a write of the store's medium, which waits for the requests queued at
the store and then a read and a put, each bounded by `bt_store_timeout_ms`; the grant's
other answers, a `pair` line among them, wait with it.
""".
-behaviour(erx_fs).

-include("generated/erx_abi.hrl").

-export([parse/1]).
-export([init/1, root/1, walk/3, getattr/2, open/3, read/4, write/4, make/4, readdir/4,
         statfs/1, clunk/2]).

-type node_() :: root | pair | ctl.

-define(TREE, <<"bt">>).
-define(FILES, [{pair, <<"pair">>}, {ctl, <<"ctl">>}]).

-doc """
What one ctl write Bytes asks: `{forget, all}` for `forget all`, or `{forget, {Type,
Octets}}` for `forget AA:BB:CC:DD:EE:FF TYPE`, a bond's identity as the `pair` file's
`bonded` line shows it: the address most significant octet first, in hex digits of
either case, then one space and its type, `public` or `random`; each with at most one
trailing newline. Any other bytes are `{error, einval}`.
""".
-spec parse(binary()) -> {ok, {forget, all | erx_smp_crypto:address()}} | {error, einval}.
parse(<<"forget all">>) -> {ok, {forget, all}};
parse(<<"forget all\n">>) -> {ok, {forget, all}};
parse(<<"forget ", Address:17/binary, " public">>) -> forget_identity(public, Address);
parse(<<"forget ", Address:17/binary, " public\n">>) -> forget_identity(public, Address);
parse(<<"forget ", Address:17/binary, " random">>) -> forget_identity(random, Address);
parse(<<"forget ", Address:17/binary, " random\n">>) -> forget_identity(random, Address);
parse(Bytes) when is_binary(Bytes) -> {error, einval}.

%% Six pairs of hex digits split by colons, which the 17 bytes leave no room around.
forget_identity(Type, Address) ->
    Pairs = binary:split(Address, <<":">>, [global]),
    case length(Pairs) =:= 6 andalso lists:all(fun hex_pair/1, Pairs) of
        true -> {ok, {forget, {Type, << <<(binary_to_integer(Pair, 16))>> || Pair <- Pairs >>}}};
        false -> {error, einval}
    end.

hex_pair(<<High, Low>>) -> hex(High) andalso hex(Low);
hex_pair(_) -> false.

hex(C) ->
    (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F).

%% ---------------------------------------------------------------------------
%% The erx_fs callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(Fs) when is_pid(Fs) ->
    {ok, Fs}.

-doc false.
root(_Fs) ->
    {ok, ?TREE, root, qid(root)}.

-doc false.
walk(root, Name, _Fs) ->
    case lists:keyfind(Name, 2, ?FILES) of
        {File, Name} -> {ok, File, qid(File)};
        false -> {error, enoent}
    end;
walk(_File, _Name, _Fs) -> {error, enotdir}.

-doc false.
getattr(root, _Fs) -> erx_fs_node:attr(qid(root), dir, 8#555);
getattr(pair, _Fs) -> erx_fs_node:attr(qid(pair), file, 8#600);
getattr(ctl, _Fs) -> erx_fs_node:attr(qid(ctl), file, 8#200).

%% The opener writes its mode and reads the window's lines through the one open.
-doc false.
open(root, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        0 -> {ok, erx_fs_node:listing([{qid(File), ?ERX_P9_DT_REG, Name} || {File, Name} <- ?FILES])};
        _ -> {error, eisdir}
    end;
open(pair, Flags, Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_RDWR ->
            case gen_server:call(Fs, {open, self()}) of
                {ok, Id} -> {ok, {pair, Id}};
                {error, _} = Refused -> Refused
            end;
        _ ->
            {error, eacces}
    end;
open(ctl, Flags, _Fs) ->
    case Flags band ?ERX_P9_O_ACCMODE of
        ?ERX_P9_O_WRONLY -> {ok, ctl};
        _ -> {error, eacces}
    end.

-doc false.
read({pair, Id}, _Offset, Count, Fs) ->
    {wait, Fs, {read, Id, Count}};
read(ctl, _Offset, _Count, _Fs) ->
    {error, eacces};
read({entries, _}, _Offset, _Count, _Fs) ->
    {error, eisdir}.

-doc false.
write({pair, Id}, Offset, Bytes, Fs) ->
    case erx_bt_window:parse(Bytes) of
        {ok, Mode} ->
            case gen_server:call(Fs, {write, Id, Mode}) of
                ok -> {ok, byte_size(Bytes), Offset};
                {error, _} = Refused -> Refused
            end;
        {error, einval} = Refused ->
            Refused
    end;
write(ctl, Offset, Bytes, Fs) ->
    maybe
        {ok, {forget, Target}} ?= parse(Bytes),
        ok ?= erx_bt_store:forget(Target),
        ok = gen_server:call(Fs, {store, read}),
        {ok, byte_size(Bytes), Offset}
    end;
write(_Handle, _Offset, _Bytes, _Fs) ->
    {error, ebadf}.

%% A create of pair or ctl opens it (erx_fs_node:open_by_create/4).
-doc false.
make(root, Name, {file, _Mode, Flags}, Fs) ->
    case walk(root, Name, Fs) of
        {ok, File, Qid} -> erx_fs_node:open_by_create(File, Qid, Flags, fun(F) -> open(File, F, Fs) end);
        {error, enoent} -> {error, eacces}
    end;
make(_Dir, _Name, _What, _Fs) ->
    {error, eacces}.

-doc false.
readdir(Handle, Offset, Max, _Fs) ->
    erx_fs_node:readdir(Handle, Offset, Max).

-doc false.
statfs(_Fs) ->
    erx_fs_node:statfs(?ERX_P9_MAGIC_RAMFS).

-doc false.
clunk({pair, Id}, Fs) ->
    gen_server:call(Fs, {clunk, Id});
clunk(_Handle, _Fs) ->
    ok.

%% A node's qid is fixed, the same in every grant; the root's path is 0, pair's 1, ctl's 2.
-spec qid(node_()) -> erx_fs:qid().
qid(root) -> {?ERX_P9_QTDIR, 0, 0};
qid(pair) -> {0, 0, 1};
qid(ctl) -> {0, 0, 2}.
