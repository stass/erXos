%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_clock_test).
-moduledoc """
The report of the apps suite's app (tools/lib/erx/apps.rb): a session a start
row keeps, which holds its template's grants and nothing of the person who
started the machine (docs/design-apps.md, AP-R2).

report/0 logs `erx_clock_test: started`, waits until erx_session has started,
which mounts /data and, for a template granted apps, /apps, and the `data` grant
has arrived, which the storage domain mints once the session has reported ready,
and then logs one notice, a record the console prints under the session's name:

    erx_clock_test: {clock_report,Node,Grants,AppsCap,AppsInfo,DataListed}

Node is the session's node, Grants the sorted names of every facet it holds
(erx:caps/0), AppsCap whether erx:cap(apps) is undefined, AppsInfo what
file:read_file_info/1 of /apps answers and DataListed the first element of
file:list_dir/1 of /data, `ok` when the namespace serves /data, so that
AppsInfo's `{error, enoent}` means the namespace holds no /apps rather than no
namespace at all. A wait that does not end within ?POLLS polls logs `timeout`
in place of the record. The process then waits for ever.
""".

-export([report/0]).

-define(POLLS, 600).
-define(POLL_MS, 500).

-spec report() -> no_return().
report() ->
    logger:notice("erx_clock_test: started"),
    Report = case wait(?POLLS) of
                 ready ->
                     {clock_report, node(), lists:sort(maps:keys(erx:caps())), erx:cap(apps) =:= undefined,
                      file:read_file_info("/apps"), element(1, file:list_dir("/data"))};
                 timeout ->
                     {clock_report, node(), timeout}
             end,
    logger:notice("erx_clock_test: ~0p", [Report]),
    receive after infinity -> ok end.

%% Ends: each step lowers the finite count.
wait(0) ->
    timeout;
wait(N) ->
    Started = lists:keymember(erx_session, 1, application:which_applications()),
    case Started andalso is_pid(erx:cap(data)) of
        true -> ready;
        false -> timer:sleep(?POLL_MS), wait(N - 1)
    end.
