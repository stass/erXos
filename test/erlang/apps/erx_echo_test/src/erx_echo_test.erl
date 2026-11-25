%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_echo_test).
-moduledoc """
The echo service of the test-only application erx_echo_test: its mint, and the
erx_facet callback of each facet the mint starts. The mint acts only on a mint
request in the system domain's envelope, {erx_origin, S, {erx_facet_mint, Tag,
echo, Grantee, Principal, Limits}}, S the system domain's id
(erx_facet:provide/2): it starts a facet bound to Grantee within Limits, ending with the mint, and replies with it, or with the
reason start/3 failed. Anything else it drops. A facet answers {echo, Term}
with {echo, Term} and refuses every other request.

foreign_atoms/1, for the system domain suite, names atoms the system domain
lacks: spawned here by the system domain, it first asks to spawn a process of a
module named by an atom made here on To's node, the system domain's, and sends
To `{foreign_spawn, Why}` with the error the request failed with, then a
message holding an atom made here, then `foreign_after`, and exits with a
reason that is an atom made here. The system domain serves no spawn, so this
runtime answers the request itself with `noconnection` and writes nothing
(docs/design-domains.md, "The system domain serves no spawn"). The
system domain decodes each frame in safe mode (edit 9 of
docs/design-runtime.md), so the message is dropped and the reason arrives as
`{erx_foreign_reason, Bin}`.
""".
-export([mint/0, foreign_atoms/1]).
%% erx_facet's callbacks; erx_facet is not on this application's compile path.
-export([init/1, admit/3]).

-include("generated/erx_abi.hrl").

-spec mint() -> no_return().
mint() ->
    receive
        {erx_origin, ?ERX_SYSTEM_DOMAIN_ID, {erx_facet_mint, Tag, echo, Grantee, Principal, Limits}}
          when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal),
               is_map(Limits) ->
            Grant = Limits#{grantee => Grantee, ends_with => [self()]},
            ok = erx_facet:minted(Tag, erx_facet:start(?MODULE, Grant, #{})),
            mint();
        _Other ->
            mint()
    end.

-spec foreign_atoms(pid()) -> no_return().
foreign_atoms(To) ->
    Spawn = erlang:spawn_request(node(To), list_to_atom("erx_foreign_atom_module"), f, [],
                                 [{reply, error_only}]),
    Why = receive {spawn_reply, Spawn, error, Error} -> Error after 10000 -> timeout end,
    To ! {foreign_spawn, Why},
    To ! {foreign, list_to_atom("erx_foreign_atom_message")},
    To ! foreign_after,
    exit(list_to_atom("erx_foreign_atom_reason")).

init(_Grant) ->
    {ok, none}.

admit({echo, Term}, _From, State) ->
    {reply, {echo, Term}, State};
admit(_Request, _From, State) ->
    {refuse, badarg, State}.
