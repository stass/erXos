%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_start_table).
-moduledoc """
The pure decisions of the start table (docs/design-apps.md, "The start
table"): what `rc.conf` sets, how its settings merge over the manifest's
`start` rows, what a write to the `apps` tree's `ctl` file asks for, and
how a command's settings are written back into `rc.conf`. The start
service reads the manifest and the file and hands them in as plain terms,
so every decision is tested with made-up manifests.

* **Rows.** A manifest row is a map `#{principal, enable, display,
  restarts, period}`: the principal's manifest name, whether the row is
  enabled, its display (a `windows` service's name, or `none`), and its
  intensity, more than `restarts` ends within `period` seconds (the
  manifest's `restart_period_s`). Names are binaries that erx_ident:new/1
  takes, the system's identifiers.
* **rc.conf.** parse_rc_conf/1 reads the file, which is untrusted: at most
  64 KiB, one `NAME_FIELD=VALUE` per line in rc.conf(5)'s form, the value
  bare, in double quotes or in single quotes, and nothing expanded. The
  variable's name splits at its last `_`, so `a_b_enable` is `enable` of
  the row `a_b`; FIELD is `enable`, `display`, `restarts` or `period`.
  `enable` takes FreeBSD's checkyesno values in any case, and
  `display=""` clears the row's display. Blank lines and `#` comments say
  nothing; any other line that does not parse is `{skipped, Line, Reason}`
  and the rest of the file stands.
* **Merge.** merge/3 applies the settings to the manifest's rows, later
  lines over earlier ones, and never adds a row: a setting for a name with
  no row is skipped as `{undeclared, Name}`. It then takes the enabled
  rows in the manifest's order and refuses one whose display its
  principal's template is not granted, `{no_grant, Display}`, or one whose
  display an earlier admitted row holds, `{display_held, Name}`.
* **Ctl.** parse_ctl/1 reads one write to `ctl`, a line of at most 4,096
  bytes: `enable NAME [display=D] [restarts=N] [period=S]`, `disable NAME`,
  `start NAME [display=D]` or `stop NAME`.
* **Writing.** set/3 writes a row's settings into the file's text as
  sysrc(8) does: the first line that assigns each variable is replaced,
  later ones are dropped, a variable not yet assigned is appended, and
  every other line is kept as written.
* **Commands.** apply_ctl/4 decides what a parsed command does: `enable`
  and `disable` become rc.conf's new text, refused when the row they
  write would be refused, or when any other enabled row would become
  refused, which names that row: a command never displaces another row
  from its display. `start` and `stop` act on the running table and
  change no setting.
* **Keeping the table.** reconcile/2 and changes/2 say which rows' keepers
  stop and which start when the table is first made, against the rows
  the keepers' branch already holds, and when it changes.

No reason, value or name made from input is an atom: every atom here is
a literal of this module.
""".

-export([parse_rc_conf/1, merge/3, parse_ctl/1, set/3]).
-export([apply_ctl/4, reconcile/2, changes/2, rc_conf_limit/0]).

-export_type([row/0, field/0, value/0, local/0, merged/0, command/0, action/0]).

%% The largest rc.conf read or written (design-apps.md, "Where the file is").
-define(MAX_RC_CONF, 65536).
%% The longest write ctl reads (design-apps.md, "Interfaces").
-define(MAX_CTL, 4096).
%% restarts and period are u32 fields of the manifest's start row.
-define(MAX_U32, 16#FFFFFFFF).
-define(MAX_DIGITS, 10).
%% A row's fields in the order set/3 appends them.
-define(FIELDS, [enable, display, restarts, period]).

-type name() :: binary().
-type field() :: enable | display | restarts | period.
-type value() :: boolean() | none | name() | non_neg_integer().
-type row() :: #{principal := name(), enable := boolean(),
                 display := none | name(),
                 restarts := non_neg_integer(), period := pos_integer()}.
%% Why a line of rc.conf is skipped: a closed set, so the start service shows
%% each as it is; the one name in it has passed erx_ident:new/1.
-type reason() :: not_an_assignment | bad_quoting | trailing_text | bad_variable
                | {bad_value, field()} | {undeclared, name()}.
%% A line of rc.conf as merge/3 takes it, by its line number.
-type local() :: {set, pos_integer(), name(), field(), value()}
               | {skipped, pos_integer(), reason()}.
-type status() :: disabled | enabled
                | {refused, {no_grant, name()} | {display_held, name()}}.
%% A merged row: the manifest's row with the settings applied, which fields
%% rc.conf set, and whether the table takes it.
-type merged() :: #{principal := name(), enable := boolean(),
                    display := none | name(),
                    restarts := non_neg_integer(), period := pos_integer(),
                    from_rc_conf := [field()], status := status()}.
-type command() :: {enable | disable | start | stop, name(), #{field() => value()}}.
%% What a command does (apply_ctl/4): write rc.conf's new text, start an
%% enabled row's keeper, start one session no supervisor keeps, with the
%% display it names as its default, or stop what keeps a row's session.
-type action() :: {rc_conf, binary()} | {start_row, name()}
                | {start_once, name(), #{default_display => name()}} | {stop, name()}.
-type ctl_error() :: {undeclared, name()} | {no_grant, name()} | {display_held, name()}
                   | enabled | too_large | bad_setting.

%% ---------------------------------------------------------------------------
%% rc.conf

-doc "Reads rc.conf's text into its settings and skipped lines, in file order.".
-spec parse_rc_conf(binary()) -> {ok, [local()]} | {error, too_large}.
parse_rc_conf(Text) when byte_size(Text) > ?MAX_RC_CONF ->
    {error, too_large};
parse_rc_conf(Text) when is_binary(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    {ok, lists:append(lists:zipwith(fun rc_line/2, lists:seq(1, length(Lines)), Lines))}.

rc_line(Number, Line) ->
    case assignment(skip_blanks(Line)) of
        blank -> [];
        {ok, Variable, Raw} -> [setting(Number, Variable, Raw)];
        {error, Reason} -> [{skipped, Number, Reason}]
    end.

%% A line's variable and raw value, or blank for a blank line or a comment.
assignment(<<>>) -> blank;
assignment(<<$#, _/binary>>) -> blank;
assignment(Line) ->
    case binary:split(Line, <<"=">>) of
        [Variable, Rest] -> raw_value(Variable, Rest);
        [_] -> {error, not_an_assignment}
    end.

%% The value's text as sh would read it without expansion: quoted text, or a
%% bare word of plain bytes; after it, only blanks and a comment. Inside
%% double quotes sh would expand `\`, `$` and backquotes, so they are refused.
raw_value(Variable, <<$", Rest/binary>>) -> closed(Variable, Rest, $", "\\$`");
raw_value(Variable, <<$', Rest/binary>>) -> closed(Variable, Rest, $', "");
raw_value(Variable, Rest) ->
    [Word | _] = binary:split(Rest, [<<" ">>, <<"\t">>]),
    Tail = binary:part(Rest, byte_size(Word), byte_size(Rest) - byte_size(Word)),
    case lists:all(fun bare_byte/1, binary_to_list(Word)) of
        true -> ended(Variable, Word, Tail);
        false -> {error, bad_quoting}
    end.

%% The text up to the closing Quote, all printable bytes that are not among
%% Expanded, the bytes sh would expand inside that quote.
closed(Variable, Rest, Quote, Expanded) ->
    case binary:split(Rest, <<Quote>>) of
        [Value, Tail] ->
            Plain = fun(Byte) -> printable(Byte) andalso not lists:member(Byte, Expanded) end,
            case lists:all(Plain, binary_to_list(Value)) of
                true -> ended(Variable, Value, Tail);
                false -> {error, bad_quoting}
            end;
        [_] -> {error, bad_quoting}
    end.

ended(Variable, Value, Tail) ->
    case skip_blanks(Tail) of
        <<>> -> {ok, Variable, Value};
        <<$#, _/binary>> -> {ok, Variable, Value};
        _ -> {error, trailing_text}
    end.

setting(Number, Variable, Raw) ->
    case split_variable(Variable) of
        {ok, Name, Field} ->
            case value(Field, Raw) of
                {ok, Value} -> {set, Number, Name, Field, Value};
                error -> {skipped, Number, {bad_value, Field}}
            end;
        error ->
            {skipped, Number, bad_variable}
    end.

%% NAME_FIELD split at its last `_`, since a principal's name may hold `_`.
split_variable(Variable) ->
    case binary:matches(Variable, <<"_">>) of
        [] ->
            error;
        Underscores ->
            {At, 1} = lists:last(Underscores),
            Name = binary:part(Variable, 0, At),
            Suffix = binary:part(Variable, At + 1, byte_size(Variable) - At - 1),
            case {valid_name(Name), field(Suffix)} of
                {true, {ok, Field}} -> {ok, Name, Field};
                _ -> error
            end
    end.

field(<<"enable">>) -> {ok, enable};
field(<<"display">>) -> {ok, display};
field(<<"restarts">>) -> {ok, restarts};
field(<<"period">>) -> {ok, period};
field(_) -> error.

%% A field's value from its text: checkyesno for enable, an identifier or
%% nothing for display, a decimal u32 for the intensity.
value(enable, Raw) when byte_size(Raw) =< 5 ->
    case << <<(lower(Byte))>> || <<Byte>> <= Raw >> of
        <<"yes">> -> {ok, true};
        <<"true">> -> {ok, true};
        <<"on">> -> {ok, true};
        <<"1">> -> {ok, true};
        <<"no">> -> {ok, false};
        <<"false">> -> {ok, false};
        <<"off">> -> {ok, false};
        <<"0">> -> {ok, false};
        _ -> error
    end;
value(enable, _Raw) -> error;
value(display, <<>>) -> {ok, none};
value(display, Raw) ->
    case valid_name(Raw) of
        true -> {ok, Raw};
        false -> error
    end;
value(restarts, Raw) -> decimal(Raw, 0);
value(period, Raw) -> decimal(Raw, 1).

decimal(Raw, Least) when byte_size(Raw) >= 1, byte_size(Raw) =< ?MAX_DIGITS ->
    Digit = fun(Byte) -> Byte >= $0 andalso Byte =< $9 end,
    case lists:all(Digit, binary_to_list(Raw)) of
        true ->
            case binary_to_integer(Raw) of
                N when N >= Least, N =< ?MAX_U32 -> {ok, N};
                _ -> error
            end;
        false -> error
    end;
decimal(_Raw, _Least) -> error.

%% ---------------------------------------------------------------------------
%% Merge

-doc """
The start table: Rows, the manifest's start rows in its order, with Local,
parse_rc_conf/1's entries, applied over them, each row's status, and the
lines skipped. Grants maps a principal to the displays its template is
granted.
""".
-spec merge([row()], [local()], #{name() => [name()]}) ->
          {[merged()], [local()]}.
merge(Rows, Local, Grants) ->
    Declared = [Row#{from_rc_conf => []} || Row <- Rows],
    {Set, Skipped} = lists:foldl(fun apply_local/2, {Declared, []}, Local),
    Admit = fun(Row, Held) -> admit(Row, Held, Grants) end,
    {Merged, _Held} = lists:mapfoldl(Admit, #{}, Set),
    {Merged, lists:reverse(Skipped)}.

apply_local({skipped, _, _} = Skip, {Rows, Skipped}) ->
    {Rows, [Skip | Skipped]};
apply_local({set, Line, Name, Field, Value}, {Rows, Skipped}) ->
    Declares = fun(#{principal := Principal}) -> Principal =:= Name end,
    case lists:any(Declares, Rows) of
        true -> {[set_field(Name, Field, Value, Row) || Row <- Rows], Skipped};
        false -> {Rows, [{skipped, Line, {undeclared, Name}} | Skipped]}
    end.

set_field(Name, Field, Value, #{principal := Name, from_rc_conf := Set} = Row) ->
    Row#{Field := Value, from_rc_conf := lists:usort([Field | Set])};
set_field(_Name, _Field, _Value, Row) ->
    Row.

%% Held maps each display to the admitted row that holds it.
admit(#{enable := false} = Row, Held, _Grants) ->
    {Row#{status => disabled}, Held};
admit(#{display := none} = Row, Held, _Grants) ->
    {Row#{status => enabled}, Held};
admit(#{principal := Principal, display := Display} = Row, Held, Grants) ->
    Granted = lists:member(Display, maps:get(Principal, Grants, [])),
    case {Granted, maps:find(Display, Held)} of
        {false, _} -> {Row#{status => {refused, {no_grant, Display}}}, Held};
        {true, {ok, Holder}} ->
            {Row#{status => {refused, {display_held, Holder}}}, Held};
        {true, error} -> {Row#{status => enabled}, Held#{Display => Principal}}
    end.

%% ---------------------------------------------------------------------------
%% ctl

-doc """
One write to ctl as a command, or why it is refused; the start service
answers every refusal `einval`. One trailing newline is allowed.
""".
-spec parse_ctl(binary()) -> {ok, command()} | {error, atom()}.
parse_ctl(Write) when byte_size(Write) > ?MAX_CTL ->
    {error, too_long};
parse_ctl(Write) when is_binary(Write) ->
    Line = without_newline(Write),
    OneLine = fun(Byte) -> printable(Byte) orelse Byte =:= $\t end,
    case lists:all(OneLine, binary_to_list(Line)) of
        true -> command(binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all]));
        false -> {error, not_one_line}
    end.

without_newline(Write) ->
    Size = byte_size(Write),
    case Size > 0 andalso binary:last(Write) =:= $\n of
        true -> binary:part(Write, 0, Size - 1);
        false -> Write
    end.

command([]) ->
    {error, empty};
command([Verb | Words]) ->
    case {verb(Verb), Words} of
        {error, _} -> {error, unknown_command};
        {{ok, _, _}, []} -> {error, no_name};
        {{ok, Command, Allowed}, [Name | Settings]} ->
            case valid_name(Name) of
                true -> settings(Settings, Allowed, Command, Name, #{});
                false -> {error, bad_name}
            end
    end.

%% Each verb and the settings it takes.
verb(<<"enable">>) -> {ok, enable, [display, restarts, period]};
verb(<<"disable">>) -> {ok, disable, []};
verb(<<"start">>) -> {ok, start, [display]};
verb(<<"stop">>) -> {ok, stop, []};
verb(_) -> error.

settings([], _Allowed, Command, Name, Settings) ->
    {ok, {Command, Name, Settings}};
settings([Word | Words], Allowed, Command, Name, Settings) ->
    case binary:split(Word, <<"=">>) of
        [Key, Raw] ->
            case field(Key) of
                {ok, Field} ->
                    Taken = {lists:member(Field, Allowed), maps:is_key(Field, Settings)},
                    case {Taken, value(Field, Raw)} of
                        {{false, _}, _} -> {error, setting_not_allowed};
                        {{true, true}, _} -> {error, duplicate_setting};
                        {{true, false}, error} -> {error, bad_setting};
                        {{true, false}, {ok, Value}} ->
                            settings(Words, Allowed, Command, Name,
                                     Settings#{Field => Value})
                    end;
                error -> {error, bad_setting}
            end;
        [_] -> {error, bad_setting}
    end.

%% ---------------------------------------------------------------------------
%% Commands

-doc """
What Command, from parse_ctl/1, does to the table that Text, rc.conf's text,
makes over Rows with Grants, as merge/3 takes them. `enable NAME` and
`disable NAME` write the row's settings and its flag ({rc_conf, NewText}),
refused when the row they write is refused, with its reason, and when any
other row enabled before is refused after, as `{display_held, Other}`
naming the row that would lose its display. `start NAME` starts an
enabled row ({start_row, NAME}, refused with `enabled` when it names a
display, which only the row's settings give), and for a row that is not
enabled one session no supervisor keeps ({start_once, ...}, its display
a default the template must be granted). `stop NAME` stops what keeps the
row's session. A name with no row is refused `{undeclared, NAME}`.
""".
-spec apply_ctl(command(), binary(), [row()], #{name() => [name()]}) -> action() | {error, ctl_error()}.
apply_ctl({_Verb, Name, _Settings} = Command, Text, Rows, Grants) ->
    case lists:any(fun(#{principal := Principal}) -> Principal =:= Name end, Rows) of
        true -> command(Command, Text, Rows, Grants);
        false -> {error, {undeclared, Name}}
    end.

command({Verb, Name, Settings}, Text, Rows, Grants) when Verb =:= enable; Verb =:= disable ->
    maybe
        {ok, Written} ?= set(Text, Name, Settings#{enable => Verb =:= enable}),
        Before = table(Text, Rows, Grants),
        After = table(Written, Rows, Grants),
        ok ?= admitted(status(Name, After)),
        [] ?= [Other || {#{principal := Other, status := enabled}, #{status := {refused, _}}}
                            <- lists:zip(Before, After), Other =/= Name],
        {rc_conf, Written}
    else
        [Displaced | _] -> {error, {display_held, Displaced}};
        {error, _} = Refused -> Refused
    end;
command({start, Name, Settings}, Text, Rows, Grants) ->
    case {status(Name, table(Text, Rows, Grants)), Settings} of
        {enabled, #{display := Display}} when is_binary(Display) -> {error, enabled};
        {enabled, _} -> {start_row, Name};
        {{refused, Reason}, _} -> {error, Reason};
        {disabled, #{display := Display}} when is_binary(Display) ->
            case lists:member(Display, maps:get(Name, Grants, [])) of
                true -> {start_once, Name, #{default_display => Display}};
                false -> {error, {no_grant, Display}}
            end;
        {disabled, _} -> {start_once, Name, #{}}
    end;
command({stop, Name, _Settings}, _Text, _Rows, _Grants) ->
    {stop, Name}.

%% The merged rows rc.conf's Text makes; text past the bound sets nothing.
table(Text, Rows, Grants) ->
    Local = case parse_rc_conf(Text) of
                {ok, Parsed} -> Parsed;
                {error, too_large} -> []
            end,
    element(1, merge(Rows, Local, Grants)).

status(Name, Merged) ->
    [Status] = [Status || #{principal := Principal, status := Status} <- Merged, Principal =:= Name],
    Status.

admitted({refused, Reason}) -> {error, Reason};
admitted(_Status) -> ok.

%% ---------------------------------------------------------------------------
%% Keeping the table

-doc """
The keepers to stop and to start when the table is first made as Merged,
while the keepers' branch holds Held, the rows it holds a supervisor for,
running or down: a held row that is not enabled stops, and an enabled row
not held starts. A held enabled row is left as it is, so a row that is
down stays down when the table's process restarts.
""".
-spec reconcile([name()], [merged()]) -> {Stop :: [name()], Start :: [name()]}.
reconcile(Held, Merged) ->
    Enabled = [Principal || #{principal := Principal, status := enabled} <- Merged],
    {[Name || Name <- Held, not lists:member(Name, Enabled)],
     [Name || Name <- Enabled, not lists:member(Name, Held)]}.

-doc """
The keepers to stop and to start when the table changes from Before to
After: a row enabled before stops when it is not enabled after or keeps
its session differently (its display or its intensity changed), and a row
enabled after starts when it was not enabled before or changed. A row
enabled and unchanged in both is left alone, running or down.
""".
-spec changes([merged()], [merged()]) -> {Stop :: [name()], Start :: [name()]}.
changes(Before, After) ->
    Was = kept(Before),
    Is = kept(After),
    Order = [Principal || #{principal := Principal} <- After],
    {[Name || Name <- Order, maps:is_key(Name, Was), maps:find(Name, Is) =/= {ok, map_get(Name, Was)}],
     [Name || Name <- Order, maps:is_key(Name, Is), maps:find(Name, Was) =/= {ok, map_get(Name, Is)}]}.

%% Each enabled row's fields its keeper and supervisor are made from.
kept(Merged) ->
    #{Principal => maps:with([display, restarts, period], Row)
      || #{principal := Principal, status := enabled} = Row <- Merged}.

-doc "The largest rc.conf the table reads, in bytes; a longer file sets nothing.".
-spec rc_conf_limit() -> pos_integer().
rc_conf_limit() -> ?MAX_RC_CONF.

%% ---------------------------------------------------------------------------
%% Writing rc.conf

-doc """
rc.conf's text with the row Name's Settings written, each as
`NAME_FIELD="VALUE"`, and every line that assigns no variable of them as
it was; refused when the text read or the text written is over 64 KiB.
""".
-spec set(binary(), name(), #{field() => value()}) ->
          {ok, binary()} | {error, too_large | bad_setting}.
set(Text, _Name, _Settings) when byte_size(Text) > ?MAX_RC_CONF ->
    {error, too_large};
set(Text, Name, Settings) when is_binary(Text) ->
    case valid_name(Name) andalso valid_settings(Settings) of
        true ->
            Lines = binary:split(Text, <<"\n">>, [global]),
            Assign = fun(Field, Acc) -> assign(Acc, Name, Field, maps:get(Field, Settings)) end,
            Fields = [Field || Field <- ?FIELDS, maps:is_key(Field, Settings)],
            Written = lists:foldl(Assign, Lines, Fields),
            case iolist_to_binary(lists:join(<<"\n">>, Written)) of
                Out when byte_size(Out) > ?MAX_RC_CONF -> {error, too_large};
                Out -> {ok, Out}
            end;
        false ->
            {error, bad_setting}
    end.

valid_settings(Settings) when is_map(Settings) ->
    Valid = fun({Field, Value}) ->
                    lists:member(Field, ?FIELDS) andalso valid_value(Field, Value)
            end,
    lists:all(Valid, maps:to_list(Settings));
valid_settings(_) ->
    false.

valid_value(enable, Value) -> is_boolean(Value);
valid_value(display, none) -> true;
valid_value(display, Value) -> is_binary(Value) andalso valid_name(Value);
valid_value(restarts, Value) -> is_integer(Value) andalso Value >= 0 andalso Value =< ?MAX_U32;
valid_value(period, Value) -> is_integer(Value) andalso Value >= 1 andalso Value =< ?MAX_U32.

%% Lines is the text split at each newline, so a text that ends in a newline
%% ends in an empty element. The first line that assigns the variable takes
%% the new assignment and later ones go; with none, the assignment is
%% appended as the last line, which then ends in a newline.
assign(Lines, Name, Field, Value) ->
    Variable = <<Name/binary, $_, (atom_to_binary(Field))/binary>>,
    New = <<Variable/binary, "=\"", (written(Value))/binary, "\"">>,
    case lists:splitwith(fun(Line) -> not assigns(Line, Variable) end, Lines) of
        {Before, [_ | After]} ->
            Before ++ [New | [Line || Line <- After, not assigns(Line, Variable)]];
        {_, []} -> appended(Lines, New)
    end.

appended(Lines, New) ->
    case lists:reverse(Lines) of
        [<<>> | Earlier] -> lists:reverse(Earlier, [New, <<>>]);
        _ -> Lines ++ [New, <<>>]
    end.

assigns(Line, Variable) ->
    Size = byte_size(Variable),
    case skip_blanks(Line) of
        <<Variable:Size/binary, $=, _/binary>> -> true;
        _ -> false
    end.

written(true) -> <<"YES">>;
written(false) -> <<"NO">>;
written(none) -> <<>>;
written(Value) when is_integer(Value) -> integer_to_binary(Value);
written(Value) when is_binary(Value) -> Value.

%% ---------------------------------------------------------------------------
%% Bytes

%% A system identifier, as the manifest and the domain service read one.
valid_name(Name) ->
    case erx_ident:new(Name) of
        {error, bad_identifier} -> false;
        _ -> true
    end.

lower_alnum(Byte) -> (Byte >= $a andalso Byte =< $z) orelse (Byte >= $0 andalso Byte =< $9).

%% What a bare word may hold: nothing sh would read as quoting, expansion,
%% an operator or a comment.
bare_byte(Byte) ->
    lower_alnum(Byte) orelse (Byte >= $A andalso Byte =< $Z)
        orelse lists:member(Byte, "_-.,:/+@%").

printable(Byte) -> Byte >= 16#20 andalso Byte =< 16#7e.

lower(Byte) when Byte >= $A, Byte =< $Z -> Byte + 32;
lower(Byte) -> Byte.

skip_blanks(<<Blank, Rest/binary>>) when Blank =:= $\s; Blank =:= $\t -> skip_blanks(Rest);
skip_blanks(Rest) -> Rest.
