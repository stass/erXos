%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bt_window).
-moduledoc """
The pairing window and the pairing wait, a pure state machine (docs/design-bluetooth.md,
"The pairing window", "The link's messages", "A pairing's outcome has one ordering
point"). `erx_bt_fs` runs it: `step(Input, Now, Core) -> {Actions, Core}` takes one
input at monotonic time `Now`, in milliseconds, and `next_deadline/1` is the instant the
core next wants an `expired` step, or `infinity`.

**A window** is an open of the control tree's `pair` file, named by the `Id` the process
gives each open. While one is open, or while the pairing a closed window admitted has no
outcome, `open` answers `ebusy`, so at most one pairing is awaited; while the store is
`unknown` since its start, which refuses every change, `eio`. The core takes the store's
state at its start (`erx_bt_store:known/0`): it leaves `unknown` since its start only by
`forget all`, which a grant of the control tree asks of the store through `ctl`, then
telling the process the confirmed answer as `{store, read}`; it enters that state only at the store's
start, which restarts this process. After an unconfirmed put the store reads before the
next change, so a window opens, and the store's outcome tells what came of its
pairing. The opener's first write, `display` or
`nodisplay`, starts the window's `bt_pair_window_s`; later writes are `einval`. A window
then moves through these phases:

- `{reserved, Id}`: opened, no mode written; every `admit` is answered `closed`;
- `{admitting, Id, Mode, Deadline, Announced}`: the first `admit` answered `open`
  takes the window, and one during the pairing wait is answered `waiting` and leaves
  it as it is; at `Deadline` the window writes `closed timeout` and ends.
  `Announced` says whether `waiting` is written yet;
- `{pairing, Id}`: the window took a pairing and waits for its outcome, however long
  the pairing runs.

**The pairing** awaited is `{Link, Tag, Address, Stage}`: the link's pid, the number of
its Pairing Request and the phone's address, `running` from the `open` verdict, when
the core monitors the link, and `keeping` from the link's `keeping`, when it drops the
monitor and the store's outcome alone decides. Before `keeping` the link's failure or
its `'DOWN'`, `disconnected`, decides; the store's outcome is taken in either stage,
since the store's message and the link's `keeping` come from two processes and a link
sends `keeping` or a failure, never both. Closing
a window while its pairing runs sends the link `{withdraw, Tag}`, and the pairing stays
awaited, without a window, until its outcome. Every message is matched by its link and
tag, so a late one changes nothing.

**The pairing wait** belongs to the core, not to a window. The first failure since the
start imposes `bt_pair_wait_min_s`; every later one imposes twice the wait the last
failure imposed, halved for each whole `bt_pair_wait_decay_s` since that failure, kept
between `bt_pair_wait_min_s` and `bt_pair_wait_max_s`. The core keeps the last failure's
instant and its wait, so it needs no timer of its own. A success leaves the wait as it is.

**The lines** each open reads are ASCII that `erx_bt_pair:format/1` composes from numbers,
addresses and words of closed sets alone, so nothing a radio peer sends reaches them as
text and they need no escaping: `wait N`, `waiting`, `passkey NNNNNN ADDR`, `bonded BOND
ADDR TYPE LEVEL`, `failed ADDR REASON` and `closed timeout`. A line is composed only for
an open whose lines go on, so a pairing withdrawn by its window's close, whose
`withdrawn` no line gives, writes none. After the last three the open's lines end;
`take/3` gives what is left, then `eof`. A closed window's open keeps its unread lines
until its clunk.

The state holds a passkey while its line is unread; `facts/1` shows the core without it.
""".

-include("generated/erx_abi.hrl").

-export([new/1, step/3, take/3, next_deadline/1, opens/1, facts/1, parse/1]).
-export_type([core/0, input/0, action/0, id/0]).

-type id() :: term().
-type link() :: pid().
-type tag() :: erx_smp_core:tag().
-type mode() :: display | nodisplay.
-doc """
What the core takes: from the file side, an open, the opener's mode and a clunk; from a
link, its messages to the window; from the store, its answer to a pairing's `keep`, and
`read` when it has confirmed a `forget`; a monitored link's end; and `expired`, when the
deadline is due.
""".
-type input() :: {open, id()} | {write, id(), mode()} | {clunk, id()}
               | {link, link(), erx_bt_link_core:to_window()}
               | {store, {outcome, link(), tag(), {bonded, erx_bt_pair:bond()} | {failed, atom()}}}
               | {store, read}
               | {down, link()}
               | expired.
-doc """
What the process does, in order: answer the file request it stepped; send a link an
`open` verdict in this mode, to which the process adds the pairing's fresh values, or
another verdict, a withdrawal or the wait; take or drop a monitor of a link; log a
pairing's outcome: its address, the phone's identity for a bond, and the bond's id and
level or the failure's reason.
""".
-type action() :: {answer, ok | {error, ebusy | eio | einval}}
                | {open, link(), tag(), mode()}
                | {send, link(), erx_bt_link_core:from_window()}
                | {monitor, link()} | {demonitor, link()}
                | {log, #{address := erx_smp_crypto:address(),
                          outcome := {bonded, erx_bt_pair:bond_id(), authenticated | unauthenticated}
                                   | {failed, erx_smp_core:reason() | atom()}}}.

-type phase() :: none | {reserved, id()} | {admitting, id(), mode(), integer(), boolean()} | {pairing, id()}.
-type pairing() :: none | {link(), tag(), erx_smp_crypto:address(), running | keeping}.

-record(core, {
    refusing :: boolean(),                                % the store is `unknown` since its start
    window = none :: phase(),
    pairing = none :: pairing(),
    last_failure = none :: none | {integer(), pos_integer()},  % its instant and the wait it imposed
    lines = #{} :: #{id() => {binary(), open | ended}}    % each open's unread lines
}).
-opaque core() :: #core{}.

-doc "A core with no window and no wait, over the store's state at this start.".
-spec new(erx_bt_store:known()) -> core().
new(read) -> #core{refusing = false};
new({unknown, start}) -> #core{refusing = true};
new({unknown, put}) -> #core{refusing = false}.

-doc """
What the opener's first write asks: `display` or `nodisplay`, each with at most one
trailing newline, or `{error, einval}` for anything else, a write longer than
`bt_pair_write_max` included.
""".
-spec parse(binary()) -> {ok, mode()} | {error, einval}.
parse(Bytes) when byte_size(Bytes) > ?ERX_BT_PAIR_WRITE_MAX -> {error, einval};
parse(<<"display">>) -> {ok, display};
parse(<<"display\n">>) -> {ok, display};
parse(<<"nodisplay">>) -> {ok, nodisplay};
parse(<<"nodisplay\n">>) -> {ok, nodisplay};
parse(Bytes) when is_binary(Bytes) -> {error, einval}.

-doc """
Steps one input at `Now`. The window's own time is applied first, `waiting` written
and a window past its deadline closed, so `expired` is that alone.
""".
-spec step(input(), integer(), core()) -> {[action()], core()}.
step(Input, Now, Core) ->
    input(Input, Now, tick(Now, Core)).

-doc """
Takes at most `Count` bytes of the lines of open `Id`: `{ok, Bytes}`, `none` while
there is no line yet, or `eof` once its lines have ended and been read.
""".
-spec take(id(), pos_integer(), core()) -> {{ok, binary()} | none | eof, core()}.
take(Id, Count, #core{lines = Lines} = Core) ->
    case Lines of
        #{Id := {<<>>, open}} -> {none, Core};
        #{Id := {<<>>, ended}} -> {eof, Core};
        #{Id := {Text, State}} ->
            Size = min(Count, byte_size(Text)),
            <<Taken:Size/binary, Rest/binary>> = Text,
            {{ok, Taken}, Core#core{lines = Lines#{Id := {Rest, State}}}};
        #{} -> {eof, Core}
    end.

-doc "The instant of the next `expired` step: the window's deadline or its wait's end.".
-spec next_deadline(core()) -> integer() | infinity.
next_deadline(#core{window = {admitting, _, _, Deadline, false}, last_failure = {At, Wait}}) ->
    min(Deadline, At + Wait);
next_deadline(#core{window = {admitting, _, _, Deadline, _}}) -> Deadline;
next_deadline(#core{}) -> infinity.

-doc "The opens the core knows, the window's and closed windows' with unread lines.".
-spec opens(core()) -> [id()].
opens(#core{lines = Lines}) -> maps:keys(Lines).

-doc "The core without its lines, which may hold a passkey: for crash reports and status.".
-spec facts(core()) -> map().
facts(#core{refusing = Refusing, window = Window, pairing = Pairing, last_failure = Last} = Core) ->
    #{refusing => Refusing, window => Window,
      pairing => case Pairing of none -> none; {Link, Tag, _, Stage} -> {Link, Tag, Stage} end,
      last_failure => case Last of none -> none; {At, _} -> At end,
      last_wait_ms => case Last of none -> none; {_, Wait} -> Wait end,
      wait_until => case Last of none -> none; _ -> until(Core) end}.

%% ---------------------------------------------------------------------------
%% Time
%% ---------------------------------------------------------------------------

tick(Now, #core{window = {admitting, Id, _, Deadline, _}} = Core) when Now >= Deadline ->
    finish(Id, {closed, timeout}, Core#core{window = none});
tick(Now, #core{window = {admitting, Id, Mode, Deadline, false}} = Core) ->
    case left(Now, Core) of
        0 -> write(Id, waiting, Core#core{window = {admitting, Id, Mode, Deadline, true}});
        _ -> Core
    end;
tick(_Now, Core) ->
    Core.

%% ---------------------------------------------------------------------------
%% The file side
%% ---------------------------------------------------------------------------

input({open, _Id}, _Now, #core{refusing = true} = Core) ->
    {[{answer, {error, eio}}], Core};
input({open, Id}, _Now, #core{window = none, pairing = none, lines = Lines} = Core) ->
    {[{answer, ok}], Core#core{window = {reserved, Id}, lines = Lines#{Id => {<<>>, open}}}};
input({open, _Id}, _Now, Core) ->
    {[{answer, {error, ebusy}}], Core};
input({write, Id, Mode}, Now, #core{window = {reserved, Id}} = Core) ->
    Deadline = Now + ?ERX_BT_PAIR_WINDOW_S * 1000,
    Opened = Core#core{window = {admitting, Id, Mode, Deadline, false}},
    {[{answer, ok}], announce(Id, Now, Opened)};
input({write, _Id, _Mode}, _Now, Core) ->
    {[{answer, {error, einval}}], Core};
input({clunk, Id}, _Now, #core{lines = Lines} = Core) ->
    close(Id, Core#core{lines = maps:remove(Id, Lines)});
%% ---------------------------------------------------------------------------
%% The links
%% ---------------------------------------------------------------------------
input({link, Link, {admit, Tag, Address}}, Now, #core{window = {admitting, Id, Mode, _, _}, pairing = none} = Core) ->
    case left(Now, Core) of
        0 ->
            {[{open, Link, Tag, Mode}, {monitor, Link}],
             Core#core{window = {pairing, Id}, pairing = {Link, Tag, Address, running}}};
        _ ->
            {[{send, Link, {admission, Tag, waiting}}], Core}
    end;
input({link, Link, {admit, Tag, _Address}}, _Now, Core) ->
    {[{send, Link, {admission, Tag, closed}}], Core};
input({link, Link, {passkey, Tag, Passkey}}, _Now,
      #core{window = {pairing, Id}, pairing = {Link, Tag, {_Type, Octets}, running}} = Core) ->
    Digits = iolist_to_binary(io_lib:format("~6..0B", [Passkey])),
    {[], write(Id, {passkey, Digits, Octets}, Core)};
input({link, Link, {outcome, Tag, {failed, Reason}}}, Now, #core{pairing = {Link, Tag, Address, running}} = Core) ->
    {Actions, Failed} = failure(Address, Reason, Now, Core),
    {[{demonitor, Link} | Actions], Failed};
input({link, Link, {keeping, Tag}}, _Now, #core{pairing = {Link, Tag, Address, running}} = Core) ->
    {[{demonitor, Link}], Core#core{pairing = {Link, Tag, Address, keeping}}};
input({link, Link, wait}, Now, Core) ->
    {[{send, Link, {wait, left(Now, Core)}}], Core};
input({link, _Link, _Late}, _Now, Core) ->
    {[], Core};
input({down, Link}, Now, #core{pairing = {Link, _Tag, Address, running}} = Core) ->
    failure(Address, disconnected, Now, Core);
input({down, _Link}, _Now, Core) ->
    {[], Core};
%% ---------------------------------------------------------------------------
%% The store
%% ---------------------------------------------------------------------------
input({store, {outcome, Link, Tag, Outcome}}, Now, #core{pairing = {Link, Tag, Address, Stage}} = Core) ->
    Demonitor = [{demonitor, Link} || Stage =:= running],
    case Outcome of
        {bonded, #{id := Id, address := Octets, type := Type, level := Level}} ->
            Log = #{address => {Type, Octets}, outcome => {bonded, Id, Level}},
            {Demonitor ++ [{log, Log}], ended(Outcome, Core)};
        {failed, Reason} ->
            {Actions, Failed} = failure(Address, Reason, Now, Core),
            {Demonitor ++ Actions, Failed}
    end;
input({store, {outcome, _Link, _Tag, _Outcome}}, _Now, Core) ->
    {[], Core};
%% A confirmed `forget` takes the store out of `unknown` since its start, which it enters
%% again only by a restart that restarts this process too, so a late one is never wrong.
input({store, read}, _Now, Core) ->
    {[], Core#core{refusing = false}};
input(expired, _Now, Core) ->
    {[], Core}.

%% The first lines of a window: the wait left to run, or `waiting` at once.
announce(Id, Now, Core) ->
    case left(Now, Core) of
        0 -> tick(Now, Core);
        Left -> write(Id, {wait, (Left + 999) div 1000}, Core)
    end.

%% The milliseconds the pairing wait has left to run at Now, 0 once it has passed, and
%% the instant it passes.
left(_Now, #core{last_failure = none}) -> 0;
left(Now, Core) -> max(0, until(Core) - Now).

until(#core{last_failure = {At, Wait}}) -> At + Wait.

%% Closing an open: the window ends, and a pairing it took that the link still runs is
%% withdrawn; one at `keeping` is the store's already.
close(Id, #core{window = {pairing, Id}, pairing = {Link, Tag, _, running}} = Core) ->
    {[{send, Link, {withdraw, Tag}}], Core#core{window = none}};
close(Id, #core{window = {reserved, Id}} = Core) ->
    {[], Core#core{window = none}};
close(Id, #core{window = {admitting, Id, _, _, _}} = Core) ->
    {[], Core#core{window = none}};
close(Id, #core{window = {pairing, Id}} = Core) ->
    {[], Core#core{window = none}};
close(_Id, Core) ->
    {[], Core}.

%% The pairing's outcome: the window, if it still has its opener, writes its last line,
%% and the pairing is no longer awaited.
ended(Line, #core{window = {pairing, Id}} = Core) ->
    finish(Id, Line, Core#core{window = none, pairing = none});
ended(_Line, Core) ->
    Core#core{pairing = none}.

%% The awaited pairing failed: its log record, its `failed` line if the window still has
%% its opener, and the pairing wait it starts.
failure({_Type, Octets} = Address, Reason, Now, Core) ->
    {[{log, #{address => Address, outcome => {failed, Reason}}}],
     ended({failed, Octets, Reason}, wait_from(Now, Core))}.

%% A failure at Now starts the wait it imposes: the minimum for the first, else twice the
%% last failure's wait halved for each whole decay period since it, within the minimum
%% and the maximum (docs/design-bluetooth.md, "The pairing window").
wait_from(Now, #core{last_failure = Last} = Core) ->
    Core#core{last_failure = {Now, imposed(Now, Last)}}.

imposed(_Now, none) ->
    ?ERX_BT_PAIR_WAIT_MIN_S * 1000;
imposed(Now, {At, Wait}) ->
    Halvings = (Now - At) div (?ERX_BT_PAIR_WAIT_DECAY_S * 1000),
    max(?ERX_BT_PAIR_WAIT_MIN_S * 1000, min(?ERX_BT_PAIR_WAIT_MAX_S * 1000, (2 * Wait) bsr Halvings)).

%% Line, an erx_bt_pair:line() but for a failure's reason as the link or the store gives
%% it, joins the lines of open Id while they go on, and only then is it composed.
write(Id, Line, #core{lines = Lines} = Core) ->
    case Lines of
        #{Id := {Text, open}} -> Core#core{lines = Lines#{Id := {<<Text/binary, (text(Line))/binary>>, open}}};
        #{} -> Core
    end.

text({failed, Octets, Reason}) -> <<(erx_bt_pair:format({failed, Octets, erx_bt_pair:reason(Reason)}))/binary, $\n>>;
text(Line) -> <<(erx_bt_pair:format(Line))/binary, $\n>>.

finish(Id, Line, Core) ->
    #core{lines = Lines} = Written = write(Id, Line, Core),
    case Lines of
        #{Id := {Text, open}} -> Written#core{lines = Lines#{Id := {Text, ended}}};
        #{} -> Written
    end.
