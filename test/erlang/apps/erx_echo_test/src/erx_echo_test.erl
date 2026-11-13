%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_echo_test).
-moduledoc """
The echo service of the test-only application erx_echo_test: its mint, and the
erx_facet callback of each facet the mint starts. The mint acts only on a mint
request in the system domain's envelope, {erx_origin, 4, {erx_facet_mint, Tag,
echo, Grantee, Principal, Limits}} (erx_facet:provide/2): it starts a facet bound to
Grantee within Limits, ending with the mint, and replies with it, or with the
reason start/3 failed. Anything else it drops. A facet answers {echo, Term}
with {echo, Term} and refuses every other request.
""".
-export([mint/0]).
%% erx_facet's callbacks; erx_facet is not on this application's compile path.
-export([init/1, admit/3]).

-define(SYSTEM_ID, 4).

-spec mint() -> no_return().
mint() ->
    receive
        {erx_origin, ?SYSTEM_ID, {erx_facet_mint, Tag, echo, Grantee, Principal, Limits}}
          when is_integer(Tag), Tag > 0, is_integer(Grantee), Grantee > 0, is_binary(Principal),
               is_map(Limits) ->
            Grant = Limits#{grantee => Grantee, ends_with => [self()]},
            ok = erx_facet:minted(Tag, erx_facet:start(?MODULE, Grant, #{})),
            mint();
        _Other ->
            mint()
    end.

init(_Grant) ->
    {ok, none}.

admit({echo, Term}, _From, State) ->
    {reply, {echo, Term}, State};
admit(_Request, _From, State) ->
    {refuse, badarg, State}.
