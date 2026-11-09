%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_ident).
-moduledoc """
System identifiers (docs/design-system.md, "Identifiers"): the names of
principals, domains, services, facets and releases. An identifier matches
[a-z0-9][a-z0-9_-]* and is 1 to 63 bytes long, so it is ASCII by
construction. Nothing is normalised: two identifiers are equal exactly when
their bytes are. new/1 is the one constructor of t(); every record that holds
a name holds a t(), so no name reaches one unchecked.
""".

-export([new/1, to_binary/1]).
-export_type([t/0]).

-opaque t() :: {erx_ident, binary()}.

-define(MAX_BYTES, 63).

-doc "Bin as an identifier, or {error, bad_identifier}.".
-spec new(term()) -> t() | {error, bad_identifier}.
new(<<First, Rest/binary>> = Bin) when byte_size(Bin) =< ?MAX_BYTES ->
    case lead(First) andalso tail(Rest) of
        true -> {erx_ident, Bin};
        false -> {error, bad_identifier}
    end;
new(_) ->
    {error, bad_identifier}.

-doc "The identifier's bytes.".
-spec to_binary(t()) -> binary().
to_binary({erx_ident, Bin}) ->
    Bin.

lead(C) -> (C >= $a andalso C =< $z) orelse (C >= $0 andalso C =< $9).

tail(<<C, Rest/binary>>) ->
    (lead(C) orelse C =:= $_ orelse C =:= $-) andalso tail(Rest);
tail(<<>>) ->
    true.
