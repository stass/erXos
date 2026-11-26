%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_pair).
-moduledoc """
The grammar of the Bluetooth control tree's lines, both ways, and the bounded reading of
them (docs/design-bluetooth.md, "The client", "The pairing window"). The window and the
`bonds` file compose their lines with `format/1` and `format_bond/1`; a reader in another
domain takes them only through `next/1` and turns each into a term with `parse/1` or
`parse_bond/1`. To that reader the lines are another domain's bytes, so parsing accepts
exactly what the formatters make, from closed sets of words, makes no atom and never
raises; anything else is `invalid`.

**One bond record**, `#{id, address, type, level}`, is the text `BOND ADDRESS TYPE LEVEL`:
the bond's id as its 32 lower-case hexadecimal digits, the identity address most
significant octet first as `AA:BB:CC:DD:EE:FF`, `public` or `random`, and
`authenticated` or `unauthenticated`. A line of `bonds` is a record, and a window's
`bonded` line is the word `bonded` and a record, made and read by the same two functions.

**The window's lines** are `wait N`, `waiting`, `passkey NNNNNN ADDRESS`, `bonded RECORD`,
`failed ADDRESS REASON` and `closed timeout`; `format/1` and `parse/1` take and give them
without their newline.

**Bounded reading.** `reader/1` wraps a file opened for reading in binary mode, and
`next/1` gives its next line without the newline. Each read asks for at most
`bt_pair_line_max + 1` octets less what the reader holds, so it never holds more than
that many octets that end no line; holding that many with no newline it answers
`overlong` and reads no more. A read must give at least one octet and no more than it
asked, or `next/1` answers `{error, einval}`, so the bound holds whatever the file
gives. A file that ends inside a line answers
`{error, truncated}`. `bonds/1` reads a whole `bonds` file the same way and refuses one
of more than `bt_bonds_max` records as `overlong`. After any answer but a line, the
caller closes the file. A reader, and a line it yields, may hold a passkey: a caller
keeps them out of what its crash reports and logs show, as the window does.
""".

-include("generated/erx_abi.hrl").

-export([format_bond/1, parse_bond/1, format/1, parse/1, reader/1, next/1, bonds/1]).
-export_type([address/0, bond/0, bond_id/0, line/0, reason/0, reader/0]).

%% An address as erx_hci decodes it, most significant octet first.
-type address() :: <<_:48>>.
%% A bond's id, its 32 lower-case hexadecimal digits.
-type bond_id() :: <<_:256>>.
-type bond() :: #{id := bond_id(), address := address(), type := public | random,
                  level := authenticated | unauthenticated}.
%% One of ?REASONS, the one list of them.
-type reason() :: atom().
%% A passkey is its six decimal digits.
-type line() :: {wait, 1..?ERX_BT_PAIR_WAIT_MAX_S} | waiting | {passkey, <<_:48>>, address()}
              | {bonded, bond()} | {failed, address(), reason()} | {closed, timeout}.

%% The file, and the octets read from it that no line has taken yet.
-record(reader, {file :: file:io_device(), held = <<>> :: binary()}).
-opaque reader() :: #reader{}.

%% A failed pairing's reasons (docs/design-bluetooth.md, "Refusals and error results"):
%% SMP's, each mapped from one Pairing Failed code or one event, and the store's.
-define(REASONS, [secure_connections_required, key_size, method, confirm, dhkey, bonding,
                  invalid, unexpected, peer, timeout, already_bonded, bonds_full,
                  unavailable, disconnected]).

%% ---------------------------------------------------------------------------
%% One bond record
%% ---------------------------------------------------------------------------

-doc "A bond's record as the `bonds` file lists it and a `bonded` line ends.".
-spec format_bond(bond()) -> binary().
format_bond(#{id := <<_:256>> = Id, address := Address, type := Type, level := Level})
  when (Type =:= public orelse Type =:= random),
       (Level =:= authenticated orelse Level =:= unauthenticated) ->
    iolist_to_binary([Id, $\s, address_text(Address), $\s, atom_to_binary(Type), $\s,
                      atom_to_binary(Level)]).

-doc "The bond a record names, or `invalid` for any text `format_bond/1` does not make.".
-spec parse_bond(binary()) -> bond() | invalid.
parse_bond(Text) when is_binary(Text) ->
    try parse_record(Text) catch throw:invalid -> invalid end.

%% ---------------------------------------------------------------------------
%% The window's lines
%% ---------------------------------------------------------------------------

-doc "A window's line, without its newline.".
-spec format(line()) -> binary().
format({wait, N}) when is_integer(N), N > 0, N =< ?ERX_BT_PAIR_WAIT_MAX_S ->
    <<"wait ", (integer_to_binary(N))/binary>>;
format(waiting) -> <<"waiting">>;
format({passkey, <<_:6/binary>> = Digits, Address}) ->
    iolist_to_binary(["passkey ", Digits, $\s, address_text(Address)]);
format({bonded, Bond}) -> <<"bonded ", (format_bond(Bond))/binary>>;
format({failed, Address, Reason}) ->
    true = lists:member(Reason, ?REASONS),
    iolist_to_binary(["failed ", address_text(Address), $\s, atom_to_binary(Reason)]);
format({closed, timeout}) -> <<"closed timeout">>.

-doc "The term a window's line holds, or `invalid` for any line `format/1` does not make.".
-spec parse(binary()) -> line() | invalid.
parse(Line) when is_binary(Line) ->
    try parse_line(Line) catch throw:invalid -> invalid end.

%% ---------------------------------------------------------------------------
%% Bounded reading
%% ---------------------------------------------------------------------------

-doc "A reader of File, opened for reading in binary mode, holding nothing yet.".
-spec reader(file:io_device()) -> reader().
reader(File) -> #reader{file = File}.

-doc """
The next line without its newline, `eof` at the end of the file, `overlong` when
`bt_pair_line_max + 1` octets hold no newline, `{error, truncated}` when the file ends
inside a line, or the read's own error.
""".
-spec next(reader()) ->
          {line, binary(), reader()} | eof | overlong | {error, term()}.
next(#reader{held = Held} = Reader) ->
    case binary:split(Held, <<"\n">>) of
        [Line, Rest] -> {line, Line, Reader#reader{held = Rest}};
        [_] when byte_size(Held) > ?ERX_BT_PAIR_LINE_MAX -> overlong;
        [_] -> read(Reader, ?ERX_BT_PAIR_LINE_MAX + 1 - byte_size(Held))
    end.

-doc """
Every record of a `bonds` file, read through `next/1`: `invalid` for a line that is no
record, and `overlong` for more than `bt_bonds_max` records as for a line past the bound.
""".
-spec bonds(file:io_device()) ->
          {ok, [bond()]} | invalid | overlong | {error, term()}.
bonds(File) -> bonds(reader(File), []).

%% ---------------------------------------------------------------------------
%% Internal
%% ---------------------------------------------------------------------------

read(#reader{file = File, held = Held} = Reader, Count) ->
    case file:read(File, Count) of
        {ok, Data} when is_binary(Data), byte_size(Data) > 0, byte_size(Data) =< Count ->
            next(Reader#reader{held = <<Held/binary, Data/binary>>});
        {ok, _} -> {error, einval};
        eof when Held =:= <<>> -> eof;
        eof -> {error, truncated};
        {error, _} = Error -> Error
    end.

bonds(Reader, Bonds) ->
    case next(Reader) of
        {line, _, _} when length(Bonds) =:= ?ERX_BT_BONDS_MAX -> overlong;
        {line, Line, Next} ->
            case parse_bond(Line) of
                invalid -> invalid;
                Bond -> bonds(Next, [Bond | Bonds])
            end;
        eof -> {ok, lists:reverse(Bonds)};
        Refused -> Refused
    end.

%% The parsers below throw `invalid` at their first mismatch, which parse/1 and
%% parse_bond/1 catch.
parse_line(<<"wait ", N/binary>>) -> {wait, seconds(N)};
parse_line(<<"waiting">>) -> waiting;
parse_line(<<"passkey ", Digits:6/binary, $\s, Address/binary>>) ->
    {passkey, digits(Digits), address(Address)};
parse_line(<<"bonded ", Bond/binary>>) -> {bonded, parse_record(Bond)};
parse_line(<<"failed ", Address:17/binary, $\s, Reason/binary>>) ->
    {failed, address(Address), word(Reason, ?REASONS)};
parse_line(<<"closed timeout">>) -> {closed, timeout};
parse_line(_) -> throw(invalid).

parse_record(<<Id:32/binary, $\s, Address:17/binary, $\s, Rest/binary>>) ->
    case binary:split(Rest, <<" ">>) of
        [Type, Level] ->
            #{id => bond_id(Id), address => address(Address), type => word(Type, [public, random]),
              level => word(Level, [authenticated, unauthenticated])};
        [_] ->
            throw(invalid)
    end;
parse_record(_) ->
    throw(invalid).

%% The atom among Words whose text is Word, so no atom is made from input.
word(Word, Words) ->
    case [Atom || Atom <- Words, atom_to_binary(Atom) =:= Word] of
        [Atom] -> Atom;
        [] -> throw(invalid)
    end.

%% The seconds of a wait: decimal, no leading zero, from 1 to bt_pair_wait_max_s.
seconds(<<First, _/binary>> = N) when First >= $1, First =< $9,
                                     byte_size(N) =< 3 ->
    case binary_to_integer(digits(N)) of
        Seconds when Seconds =< ?ERX_BT_PAIR_WAIT_MAX_S -> Seconds;
        _ -> throw(invalid)
    end;
seconds(_) -> throw(invalid).

digits(Digits) -> only(fun(C) -> C >= $0 andalso C =< $9 end, Digits).

bond_id(Id) -> only(fun(C) -> C >= $0 andalso C =< $9 orelse C >= $a andalso C =< $f end, Id).

%% Text, when Allowed holds for each of its octets.
only(Allowed, Text) ->
    case lists:all(Allowed, binary_to_list(Text)) of
        true -> Text;
        false -> throw(invalid)
    end.

%% Six pairs of upper-case hexadecimal digits joined by colons.
address(Text) ->
    case binary:split(Text, <<":">>, [global]) of
        [_, _, _, _, _, _] = Pairs -> << <<(octet(Pair))>> || Pair <- Pairs >>;
        _ -> throw(invalid)
    end.

octet(<<High, Low>>) -> upper_hex(High) * 16 + upper_hex(Low);
octet(_) -> throw(invalid).

upper_hex(C) when C >= $0, C =< $9 -> C - $0;
upper_hex(C) when C >= $A, C =< $F -> C - $A + 10;
upper_hex(_) -> throw(invalid).

address_text(<<_:48>> = Octets) ->
    lists:join($:, [binary:encode_hex(<<Octet>>) || <<Octet>> <= Octets]).
