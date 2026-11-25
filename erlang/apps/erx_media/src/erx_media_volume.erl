%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_volume).
-moduledoc """
A volume's process (docs/design-drives.md, "Volumes"): a temporary child of its
medium's supervisor (erx_media_medium), and the volume's mount, which is made when it
starts and ends when it ends. It runs under the memory bound of "Time and memory",
`max_heap_size` of `media_volume_bytes` in words, with `kill` and
`include_shared_binaries`, so a volume whose heap, stack and the binaries it holds
pass the bound at a collection is ended alone.

It reads its volume through the window proxy alone, each sector placed by
erx_media_table:place/3, so no request reaches a sector outside the volume. Before
it answers anything it probes the volume (erx_media_probe:format/3), mounts the
selected format if it serves it, and applies the writable rule (writable/4), so a
call made while it mounts waits for the mount. Its outcome is what `sN_mount` shows:

* `rw`;
* `{ro, Reason}`, the writable rule's first condition that does not hold: `format`,
  `{also, Name}`, `flush` (the medium cannot flush) or `dirty`;
* `{none, Reason}`, no files: `format` for a format not served, FAT12 among them,
  `unknown`, `{flush, Reason}` for a flush that answered neither `ok` nor `enotsup`,
  or `{failed, Why}` for a probe whose read failed or a mount the format refused.

The formats served are FAT16 and FAT32, through the FAT server (erx_fat); no other
format falls back to another. Every byte of the volume is untrusted, and its label
reaches no sink here: the media tree shows it through the field escape.
""".

-behaviour(gen_server).

-export([start_link/2, outcome/1, writable/4]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).
-export_type([outcome/0, mount/0]).

%% The formats the media domain writes on a drive: FAT alone, the format table's one
%% row that writes and is served here (docs/design-drives.md, "The writable rule").
-define(WRITTEN, [msdosfs]).

-type mount() :: rw
               | {ro, format | {also, erx_media_probe:name()} | flush | dirty}
               | {none, format | unknown | {flush, atom()} | {failed, term()}}.
-type outcome() :: #{format := erx_media_probe:name() | unknown, mount := mount(),
                     fat => erx_fat_read:fat_type(), label => binary() | none,
                     serial => non_neg_integer() | none}.

-doc """
Starts the process of Volume, an entry erx_media_table:read/2 answered, over the
window proxy Proxy, linked to the caller, the medium's supervisor.
""".
-spec start_link(pid(), erx_media_table:volume()) -> {ok, pid()}.
start_link(Proxy, #{first := _, length := _} = Volume) when is_pid(Proxy) ->
    gen_server:start_link(?MODULE, {Proxy, Volume}, []).

-doc "The volume's outcome, once its probe and mount are done.".
-spec outcome(pid()) -> outcome().
outcome(Pid) ->
    gen_server:call(Pid, outcome, infinity).

-doc """
The writable rule (docs/design-drives.md, "The writable rule") for a volume of the
selected format Format, on which the probe also found the written formats Also, and
whose format's own state is Clean: `rw` when every condition holds, else
`{ro, Reason}` for the first that does not, or `{none, {flush, Reason}}` for a flush
that answered anything but `ok` or `enotsup`, which refuses the mount with nothing
written. Flush sends the mount's one flush; it is called only once the first two
conditions hold, and before anything is written.
""".
-spec writable(erx_media_probe:name(), [erx_media_probe:name()], fun(() -> ok | {error, term()}),
               boolean()) -> mount().
writable(Format, Also, Flush, Clean) ->
    case {lists:member(Format, ?WRITTEN), Also} of
        {false, _} -> {ro, format};
        {true, [Name | _]} -> {ro, {also, Name}};
        {true, []} -> flushed(Flush(), Clean)
    end.

flushed(ok, true) -> rw;
flushed(ok, false) -> {ro, dirty};
flushed({error, enotsup}, _Clean) -> {ro, flush};
flushed({error, Reason}, _Clean) when is_atom(Reason) -> {none, {flush, Reason}};
flushed(_Malformed, _Clean) -> {none, {flush, eio}}.

%% The process ---------------------------------------------------------------------

-doc false.
init({Proxy, Volume}) ->
    process_flag(max_heap_size, erx_media_medium:memory_bound()),
    {ok, #{proxy => Proxy, volume => Volume}, {continue, mount}}.

-doc false.
handle_continue(mount, #{proxy := Proxy, volume := #{length := Length} = Volume} = State) ->
    Read = fun(Sector) -> read_sector(Proxy, Volume, Sector) end,
    {Outcome, Fat} = mounted(erx_media_probe:format(Read, Length, ?WRITTEN), Read, Length, Proxy),
    {noreply, State#{outcome => Outcome, fat => Fat}}.

-doc false.
handle_call(outcome, _From, #{outcome := Outcome} = State) ->
    {reply, Outcome, State};
handle_call(_Other, _From, State) ->
    {reply, {error, einval}, State}.

-doc false.
handle_cast(_Other, State) ->
    {noreply, State}.

-doc false.
handle_info(_Other, State) ->
    {noreply, State}.

%% The mount --------------------------------------------------------------------

%% The outcome of the probe's answer, and the FAT server's mount when it serves the
%% volume (none otherwise). Only FAT16 and FAT32 are served; the selected format is the
%% volume's one reading, and the FAT type shown is the one the mount read, since the
%% medium answers each read afresh.
mounted({error, Why}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, {failed, Why}}}, none};
mounted({ok, #{format := msdosfs, also := Also, fat := Type}}, Read, Length, Proxy)
  when Type =:= 16; Type =:= 32 ->
    case erx_fat:mount(Read, Length) of
        {ok, Fat} ->
            #{type := Mounted, label := Label, serial := Serial, clean := Clean} = erx_fat:info(Fat),
            Mount = writable(msdosfs, Also, fun() -> erx_media_medium:window(Proxy, flush) end, Clean),
            {#{format => msdosfs, fat => Mounted, label => Label, serial => Serial, mount => Mount}, Fat};
        {error, Finding} ->
            {#{format => msdosfs, fat => Type, mount => {none, {failed, Finding}}}, none}
    end;
mounted({ok, #{format := msdosfs, fat := Type}}, _Read, _Length, _Proxy) ->
    {#{format => msdosfs, fat => Type, mount => {none, format}}, none};
mounted({ok, #{format := unknown}}, _Read, _Length, _Proxy) ->
    {#{format => unknown, mount => {none, unknown}}, none};
mounted({ok, #{format := Format}}, _Read, _Length, _Proxy) ->
    {#{format => Format, mount => {none, format}}, none}.

%% The volume's sector Sector, read through the proxy at its place on the medium.
read_sector(Proxy, Volume, Sector) ->
    case erx_media_table:place(Volume, Sector, 1) of
        {ok, Lba} -> erx_media_medium:window(Proxy, {read, Lba, 1});
        {error, erange} = Refused -> Refused
    end.
