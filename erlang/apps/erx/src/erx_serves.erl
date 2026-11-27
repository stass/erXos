%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_serves).
-moduledoc """
The declaration of the services this domain serves (docs/design-system.md,
"The declaration"): the `-erx_serves NAME INTERFACE ... --` words the packer
derives from the manifest's `service` rows into every configured domain's
start arguments and the system domain's. This module alone reads them.

declared/0 answers the declaration as `{Name, Interface}` pairs, each name a
binary and each interface its abi/services number, which the words give in
decimal, in the packer's order. It reads init's occurrences of the flag once
and keeps the result, which no later call changes, for the domain's life.
The words make no atom. Anything but exactly one occurrence of name and
interface pairs raises `{bad_serves, Detail}`, so a domain that cannot read
its declaration fails its start rather than mint by guess: a missing flag is
`missing`, a second occurrence, as an `erx.arg=-erx_serves` word makes,
`duplicate`, an odd count of words `odd`, and an interface word that is no
decimal number `{interface, Word}`. The words are the packer's, which took
each interface from its row, so they are not checked again here.

The declaration grants nothing. The domain service checks every mint a
ready report names against the manifest itself, so a domain that ignores
its declaration only has its report refused.
""".

-export([declared/0, find/1, parse/1]).

-export_type([declaration/0]).

-type declaration() :: [{Name :: binary(), Interface :: non_neg_integer()}].

-doc "The declaration of this domain's services, read once and kept.".
-spec declared() -> declaration().
declared() ->
    case persistent_term:get(?MODULE, undefined) of
        undefined ->
            Declaration = parse(init:get_argument(erx_serves)),
            persistent_term:put(?MODULE, Declaration),
            Declaration;
        Declaration ->
            Declaration
    end.

-doc """
The interface number the declaration gives the service `Name`, a binary, or
`error` when it gives none. A domain started with no declaration, a session
or a domain created at run time, declares nothing, so it finds no name; a
malformed declaration raises as declared/0 does.
""".
-spec find(binary()) -> {ok, non_neg_integer()} | error.
find(Name) when is_binary(Name) ->
    try lists:keyfind(Name, 1, declared()) of
        {Name, Interface} -> {ok, Interface};
        false -> error
    catch
        error:{bad_serves, missing} -> error
    end.

-doc """
The declaration init's answer for `erx_serves` gives, `{ok, Occurrences}` or
`error`, each occurrence a list of words; raises `{bad_serves, Detail}` for
any other.
""".
-spec parse({ok, [[string()]]} | error) -> declaration().
parse({ok, [Words]}) -> pairs(Words);
parse({ok, [_, _ | _]}) -> error({bad_serves, duplicate});
parse(_) -> error({bad_serves, missing}).

pairs([]) ->
    [];
pairs([Name, Interface | Rest]) ->
    [{list_to_binary(Name), interface(Interface)} | pairs(Rest)];
pairs([_]) ->
    error({bad_serves, odd}).

%% The interface number a word gives in decimal.
interface(Word) ->
    try
        list_to_integer(Word)
    catch
        error:badarg -> error({bad_serves, {interface, Word}})
    end.
