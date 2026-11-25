%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_file_description).
-moduledoc """
A stand-in for erx_file_description in erx_prog_handler's tests, whose
stock emulator has no erXos prim_file: the namespace is the table the
test puts under the persistent term {erx_file_description, table}, or the
release slice alone, and an open answers the handler at once with this stand-in's
answer, enoent, so no description runs. Each open is told to the process
persistent_term names under erx_win, if any, as `{erx_win, {open, Path, Table}}`.
""".

-export([table/0, open/6, read/3, write/3, pread/4, pwrite/4, seek/4, getattr/2, clunk/2]).

table() ->
    persistent_term:get({erx_file_description, table},
                        [#{point => [], provider => release, root => [], rights => ro}]).

open(Slot, Path, _Flags, _Mode, Table, _Cwd) ->
    case persistent_term:get(erx_win, undefined) of
        Test when is_pid(Test) -> Test ! {erx_win, {open, Path, Table}};
        undefined -> ok
    end,
    self() ! {erx_file_opened, Slot, {error, enoent}},
    self().

read(_Description, _Slot, _Count) -> ok.
write(_Description, _Slot, _Bytes) -> ok.
pread(_Description, _Slot, _Offset, _Count) -> ok.
pwrite(_Description, _Slot, _Offset, _Bytes) -> ok.
seek(_Description, _Slot, _Offset, _Whence) -> ok.
getattr(_Description, _Slot) -> ok.
clunk(_Description, _Slot) -> ok.
