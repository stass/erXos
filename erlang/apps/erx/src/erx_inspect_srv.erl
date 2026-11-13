%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_inspect_srv).
-moduledoc """
The process behind every inspect facet (docs/design-live.md, "The inspect
service"), in the system domain only: it names itself with
erx_facet:serve(inspect, Pid), so the domain service mints each grantee's
inspect facet (erx_inspect_facet) in front of it, and each facet ends with
it. The facets run every request in a query worker of their own and forward
nothing here, so it refuses every call with `{error, badarg}` and drops
every other message. kernel's safe supervisor starts it before the domain
service, which reads the name when it mints.
""".

-export([start_link/0, init/1]).

-doc """
Starts the process in the system domain, the erXos runtime whose boot page
names the system domain's id and no system connection, read from
erx_dist:boot/0; `ignore` in every other runtime, which serves no facet.
""".
-spec start_link() -> {ok, pid()} | ignore.
start_link() ->
    case system_domain() of
        true -> proc_lib:start_link(?MODULE, init, [self()]);
        false -> ignore
    end.

system_domain() ->
    erlang:system_info(os_type) =:= {unix, erxos} andalso
        erx_dist:boot() =:= {erx_kernel_records:system_domain(), none}.

-doc false.
init(Parent) ->
    ok = erx_facet:serve(inspect, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop().

loop() ->
    receive
        {'$gen_call', From, _Request} -> gen:reply(From, {error, badarg});
        _Dropped -> ok
    end,
    loop().
