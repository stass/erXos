%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_fat_entry).
-moduledoc """
FAT's 32-byte directory entry (docs/design-storage.md, "Removable media: FAT"; the
FAT specification, sections 6 and 7), pure: the one codec of the short entry and
the long-name entry, which the read path and the ownership check (erx_fat), the
names (erx_fat_name) and the directory changes (erx_fat_dir) share.

* **decode/1** reads an entry as the end marker (first byte 0), a deleted one
  (first byte 0xE5), a long-name entry (attributes 0x0F under mask 0x3F), whose
  type and first cluster must be 0 or it is `bad_long`, or a short entry, short().
* **A short entry** keeps every field, so encode/1 of what decode/1 answers gives
  its bytes back; first/2 reads its first cluster, the high half only on FAT32.
* **A long-name entry** carries its order number, whether it is the name's last
  part, the short entry's checksum and 13 UTF-16 code units, 26 bytes.
* **Times** are UNIX seconds read and written as UTC with FAT's two-second
  resolution; a date or time no calendar holds reads as FAT's first time, and one
  outside FAT's range is written clamped to it.
""".

-export([decode/1, encode/1, long/4, deleted/1, new/5, first/2, with_first/2, kind/1, read_only/1, mtime/1]).
-export_type([entry/0, short/0]).

-include("erx_fat_entry.hrl").

-define(END_OF_DIRECTORY, 16#00).
-define(DELETED, 16#e5).
-define(READ_ONLY, 16#01).
-define(VOLUME_ID, 16#08).
-define(DIRECTORY, 16#10).
-define(ARCHIVE, 16#20).
-define(LONG_NAME, 16#0f).
-define(LONG_NAME_MASK, 16#3f).
-define(ORDER_MASK, 16#3f).
-define(LAST_LONG_ENTRY, 16#40).
%% FAT's times run from 1980-01-01 to 2107-12-31T23:59:58 (section 6.1), in UNIX seconds.
-define(TIME_FIRST, 315532800).
-define(TIME_LAST, 4354819198).
-define(UNIX_EPOCH_GREGORIAN, 62167219200).

%% A short entry's fields (section 6): the name's 11 bytes, attributes, case flags,
%% the creation time's 5 bytes, the access date, the first cluster's two halves,
%% the modification time and date, and the size.
-type short() :: #{name := <<_:88>>, attributes := byte(), flags := byte(), created := <<_:40>>,
                   accessed := 0..16#ffff, high := 0..16#ffff, time := 0..16#ffff, date := 0..16#ffff,
                   low := 0..16#ffff, size := non_neg_integer()}.
-type entry() :: end_of_directory | deleted | bad_long | {short, short()}
               | {long, Order :: byte(), Last :: boolean(), Sum :: byte(), Units :: <<_:208>>}.

-doc """
What a 32-byte entry is (see the module's doc). A long-name entry's order number
loses the last-part flag, and on the last part the reserved bits too, as the
specification masks it (section 7.1).
""".
-spec decode(<<_:256>>) -> entry().
decode(<<?END_OF_DIRECTORY, _:31/binary>>) ->
    end_of_directory;
decode(<<?DELETED, _:31/binary>>) ->
    deleted;
decode(<<Order, Part1:10/binary, Attributes, Type, Sum, Part2:12/binary, Cluster:16/little, Part3:4/binary>>)
  when Attributes band ?LONG_NAME_MASK =:= ?LONG_NAME ->
    case {Type, Cluster, Order band ?LAST_LONG_ENTRY =/= 0} of
        {0, 0, true} -> {long, Order band ?ORDER_MASK, true, Sum, <<Part1/binary, Part2/binary, Part3/binary>>};
        {0, 0, false} -> {long, Order, false, Sum, <<Part1/binary, Part2/binary, Part3/binary>>};
        _ -> bad_long
    end;
decode(<<Name:11/binary, Attributes, Flags, Created:5/binary, Accessed:16/little, High:16/little,
         Time:16/little, Date:16/little, Low:16/little, Size:32/little>>) ->
    {short, #{name => Name, attributes => Attributes, flags => Flags, created => Created, accessed => Accessed,
              high => High, time => Time, date => Date, low => Low, size => Size}}.

-doc "A short entry's 32 bytes.".
-spec encode(short()) -> <<_:256>>.
encode(#{name := Name, attributes := Attributes, flags := Flags, created := Created, accessed := Accessed,
         high := High, time := Time, date := Date, low := Low, size := Size}) ->
    <<Name/binary, Attributes, Flags, Created/binary, Accessed:16/little, High:16/little, Time:16/little,
      Date:16/little, Low:16/little, Size:32/little>>.

-doc "A long-name entry: order number Order, the last part when Last, checksum Sum, 26 bytes of Units.".
-spec long(1..20, boolean(), byte(), <<_:208>>) -> <<_:256>>.
long(Order, Last, Sum, <<Part1:10/binary, Part2:12/binary, Part3:4/binary>>) ->
    Flag = case Last of true -> ?LAST_LONG_ENTRY; false -> 0 end,
    <<(Order bor Flag), Part1/binary, ?LONG_NAME, 0, Sum, Part2/binary, 0:16, Part3/binary>>.

-doc "Entry Bytes marked deleted, its other bytes kept.".
-spec deleted(<<_:256>>) -> <<_:256>>.
deleted(<<_, Rest:31/binary>>) -> <<?DELETED, Rest/binary>>.

-doc """
A new short entry: name Name with case flags Flags, a file (archive) or a directory,
first cluster First, size 0, created, accessed and modified at Time (UNIX seconds).
""".
-spec new(<<_:88>>, byte(), file | dir, non_neg_integer(), integer()) -> short().
new(Name, Flags, Kind, First, Time) ->
    {Date, Clock} = fat_time(Time),
    Attributes = case Kind of file -> ?ARCHIVE; dir -> ?DIRECTORY end,
    with_first(#{name => Name, attributes => Attributes, flags => Flags, created => <<0, Clock:16/little, Date:16/little>>,
                 accessed => Date, high => 0, time => Clock, date => Date, low => 0, size => 0}, First).

-doc "A short entry's first cluster on a FAT16 or FAT32 volume.".
-spec first(short(), 16 | 32) -> non_neg_integer().
first(#{high := High, low := Low}, 32) -> (High bsl 16) bor Low;
first(#{low := Low}, 16) -> Low.

-doc "Short entry Short naming first cluster Cluster.".
-spec with_first(short(), non_neg_integer()) -> short().
with_first(Short, Cluster) -> Short#{high := Cluster bsr 16, low := Cluster band 16#ffff}.

-doc "What a short entry names: a volume label, a directory or a file.".
-spec kind(short()) -> label | dir | file.
kind(#{attributes := A}) when A band ?VOLUME_ID =/= 0 -> label;
kind(#{attributes := A}) when A band ?DIRECTORY =/= 0 -> dir;
kind(#{}) -> file.

-doc "Whether a short entry carries the read-only attribute.".
-spec read_only(short()) -> boolean().
read_only(#{attributes := A}) -> A band ?READ_ONLY =/= 0.

-doc "A short entry's modification time in UNIX seconds (see the module's doc).".
-spec mtime(short()) -> non_neg_integer().
mtime(#{date := Date, time := Time}) ->
    Day = {1980 + (Date bsr 9), (Date bsr 5) band 16#0f, Date band 16#1f},
    {Hour, Minute, Second} = Clock = {Time bsr 11, (Time bsr 5) band 16#3f, (Time band 16#1f) * 2},
    case calendar:valid_date(Day) andalso Hour < 24 andalso Minute < 60 andalso Second < 60 of
        true -> calendar:datetime_to_gregorian_seconds({Day, Clock}) - ?UNIX_EPOCH_GREGORIAN;
        false -> ?TIME_FIRST
    end.

%% UNIX seconds Time as FAT's date and time, clamped to the times FAT holds.
fat_time(Time) ->
    Clamped = min(max(Time, ?TIME_FIRST), ?TIME_LAST),
    {{Year, Month, Day}, {Hour, Minute, Second}} =
        calendar:gregorian_seconds_to_datetime(Clamped + ?UNIX_EPOCH_GREGORIAN),
    {((Year - 1980) bsl 9) bor (Month bsl 5) bor Day, (Hour bsl 11) bor (Minute bsl 5) bor (Second div 2)}.
