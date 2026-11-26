%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_media_medium).
-moduledoc """
A medium's supervisor and its reader (docs/design-drives.md, "Reading a medium",
"Concurrency" and "Failure handling"). The drive process starts the supervisor,
linked to it, for the medium it holds, and ends it at the medium's end, which ends
every volume of the medium with it. Every child is temporary, so nothing of a medium
restarts on its own: a volume that crashes or passes its memory bound ends alone,
and the medium mounts afresh only at the next window.

read/2 starts the reader, a child of the supervisor, and waits for it. The reader
asks the window proxy for the medium's capacity, reads one sector a request for each
sector erx_media_table:read/2 asks for, until the table answers, starts one volume
process, erx_media_volume, for each entry the table serves, and ends. Its answer is
the table:

* `{Scheme, Volumes, Unserved}`: `mbr`, `gpt` or `none`; each served or extended
  entry, in entry order, with its volume's pid or `extended`; and how many entries
  past `media_volumes_max` the table lists;
* `{refused, Finding}`, a table refused whole, with no volume started;
* `{failed, Why}`: a capacity or a sector the window did not answer, or the reader's
  own end, past its memory bound among them. Volumes the reader started before it
  failed may still run, so the caller ends the supervisor, as the drive process does
  at the medium's end.

The reader and every volume run under one memory bound, memory_bound/0: a
`max_heap_size` of `media_volume_bytes` in words, with `kill` and
`include_shared_binaries` ("Time and memory").
""".

-behaviour(supervisor).

-include("generated/erx_abi.hrl").

-export([start_link/0, read/2, memory_bound/0, window/2]).
-export([init/1, start_reader/3]).
-export_type([table/0]).

-type table() :: {mbr | gpt | none, [{erx_media_table:volume(), pid() | extended}], non_neg_integer()}
               | {refused, erx_media_table:finding()}
               | {failed, term()}.

-doc "Starts a medium's supervisor, with no child, linked to the caller.".
-spec start_link() -> {ok, pid()}.
start_link() ->
    supervisor:start_link(?MODULE, []).

-doc """
The table of the medium behind the window proxy Proxy, read by a reader under the
medium's supervisor Sup, with the volume processes it started there.
""".
-spec read(pid(), pid()) -> table().
read(Sup, Proxy) when is_pid(Sup), is_pid(Proxy) ->
    Alias = alias([reply]),
    Spec = #{id => reader, start => {?MODULE, start_reader, [Sup, Proxy, Alias]}, restart => temporary},
    case supervisor:start_child(Sup, Spec) of
        {ok, Reader} ->
            Monitor = monitor(process, Reader),
            receive
                {Alias, Table} -> demonitor(Monitor, [flush]), Table;
                {'DOWN', Monitor, process, Reader, Why} -> unalias(Alias), {failed, Why}
            end;
        {error, Why} ->
            unalias(Alias),
            {failed, Why}
    end.

-doc "The memory bound of the reader and of each volume's process, as process_flag/2 takes it.".
-spec memory_bound() -> #{size := pos_integer(), kill := true, include_shared_binaries := true}.
memory_bound() ->
    #{size => ?ERX_MEDIA_VOLUME_BYTES div erlang:system_info(wordsize), kill => true,
      include_shared_binaries => true}.

-doc false.
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 1}, []}}.

-doc false.
start_reader(Sup, Proxy, Alias) ->
    {ok, proc_lib:spawn_link(fun() ->
                                     process_flag(max_heap_size, memory_bound()),
                                     Alias ! {Alias, table(Sup, Proxy)}
                             end)}.

%% The reader --------------------------------------------------------------------

%% The table of the medium, its served entries' volumes started; every failure leaves
%% through one throw, {?MODULE, Why}.
table(Sup, Proxy) ->
    try
        Capacity = capacity(window(Proxy, info)),
        started(sectors(erx_media_table:read(Capacity, #{}), Capacity, #{}, Proxy), Sup, Proxy)
    catch
        throw:{?MODULE, Why} -> {failed, Why}
    end.

capacity({ok, #{sectors := Capacity}}) when is_integer(Capacity), Capacity >= 0 -> Capacity;
capacity(Answer) -> throw({?MODULE, {info, Answer}}).

%% Reads the sectors the table asks for, one request each, until it answers.
sectors({need, Lbas}, Capacity, Sectors, Proxy) ->
    Read = maps:from_list([{Lba, sector(Lba, Proxy)} || Lba <- Lbas]),
    Added = maps:merge(Sectors, Read),
    sectors(erx_media_table:read(Capacity, Added), Capacity, Added, Proxy);
sectors(Answer, _Capacity, _Sectors, _Proxy) ->
    Answer.

sector(Lba, Proxy) ->
    case window(Proxy, {read, Lba, 1}) of
        {ok, <<_:512/binary>> = Sector} -> Sector;
        Answer -> throw({?MODULE, {read, Lba, Answer}})
    end.

%% A table that lists volumes has each it serves started under Sup.
started({refused, _Finding} = Refused, _Sup, _Proxy) ->
    Refused;
started({Scheme, Volumes}, Sup, Proxy) ->
    Listed = [{Volume, volume(Volume, Sup, Proxy)} || #{serve := Serve} = Volume <- Volumes, Serve =/= over_bound],
    {Scheme, Listed, length([over || #{serve := over_bound} <- Volumes])}.

volume(#{serve := extended}, _Sup, _Proxy) ->
    extended;
volume(#{serve := yes, number := Number} = Volume, Sup, Proxy) ->
    Spec = #{id => {volume, Number}, start => {erx_media_volume, start_link, [Proxy, Volume]},
             restart => temporary},
    case supervisor:start_child(Sup, Spec) of
        {ok, Pid} -> Pid;
        {error, Why} -> throw({?MODULE, {volume, Number, Why}})
    end.

-doc """
A window request through the proxy Proxy, for the reader and the volumes: the
window answers within its own deadline, so the call needs no timer of its own, and
a proxy that has ended answers `{error, eio}`.
""".
-spec window(pid(), {read, non_neg_integer(), pos_integer()} | {write, non_neg_integer(), binary()}
                    | flush | info) -> term().
window(Proxy, Request) ->
    try
        gen_server:call(Proxy, Request, infinity)
    catch
        exit:_Ended -> {error, eio}
    end.
