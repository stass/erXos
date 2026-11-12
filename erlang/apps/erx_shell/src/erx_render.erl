%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_render).
-moduledoc """
The one renderer of a record's values as text (docs/design-shell.md,
"Pipelines"; docs/design-live.md, "Inspection records"). A value is an
`attr()`, a reporter and a value with its status: an `ok` value prints
bare, and every other status prints as itself, `[partial]`, `[unknown]`,
`[unsupported]`, `[timeout N]` or `[error]`, so no status reads as a
value.

Values are attributed text, which a reporter names (a process's name, a
file's name, a count), so every value and name passes through the line
escape, erx_text:escape_line/1, on its way to the terminal. The command
shell's commands print text as FreeBSD's do and never come here; this is
the Erlang shell's view of the inspector, erx:i/1 and erx:ps/0, and the
value text `/proc` writes (erx_procfs_core).
""".

-export([value/1]).
-export([record/2, overview/2]).

-export_type([attr/0]).

%% An inspector value with its reporter, a stopgap reporter by the name the
%% inspection schema declares.
-type attr() :: {kernel | service | runtime | {stopgap, atom()},
                 {ok, term()} | {partial, term()} | unknown | unsupported
                 | {timeout, pos_integer()} | {error, term()}}.

-define(GAP, <<"  ">>).

-doc "An attribute's text: the value when it is `ok`, its status otherwise.".
-spec value(attr()) -> binary().
value({_Reporter, {ok, Value}}) -> text(Value);
value({_Reporter, {partial, _}}) -> <<"[partial]">>;
value({_Reporter, unknown}) -> <<"[unknown]">>;
value({_Reporter, unsupported}) -> <<"[unsupported]">>;
value({_Reporter, {timeout, Ms}}) -> <<"[timeout ", (integer_to_binary(Ms))/binary, "]">>;
value({_Reporter, {error, _}}) -> <<"[error]">>.

transpose([[] | _]) -> [];
transpose(Rows) -> [[Cell || [Cell | _] <- Rows] | transpose([Rest || [_ | Rest] <- Rows])].

%% A column is as wide as its widest cell, the header's name among them,
%% and aligned right when its values include an integer and no other `ok`
%% value; a name is not a value, so it does not decide the alignment.
column(Cells) ->
    Kinds = [Kind || {_, Kind} <- Cells],
    Align = case lists:member(integer, Kinds) andalso not lists:member(text, Kinds) of
                true -> right;
                false -> left
            end,
    {lists:max([width(Text) || {Text, _} <- Cells]), Align}.

%% A row of one cell, the only row a line of data makes, is its text and a
%% newline, never measured or padded, so a data cell's bytes need not be
%% UTF-8. A wider row's cells are joined by the gap, each padded to its
%% column; the last is not padded on its right, so no line ends in spaces.
row([{Text, _Kind}], _Columns) ->
    [Text, $\n];
row(Cells, Columns) ->
    Last = length(Cells),
    Padded = [pad(Text, Column, Index =:= Last)
              || {Index, {Text, _}, Column} <- lists:zip3(lists:seq(1, Last), Cells, Columns)],
    [lists:join(?GAP, Padded), $\n].

pad(Text, {Width, Align}, Last) ->
    Fill = binary:copy(<<" ">>, max(0, Width - width(Text))),
    case {Align, Last} of
        {right, _} -> [Fill, Text];
        {left, true} -> Text;
        {left, false} -> [Text, Fill]
    end.

%% The columns an escaped text takes: one for each character it shows.
width(Text) -> string:length(Text).

cell(Attr) -> {erx_text:escape_line(value(Attr)), kind(Attr)}.

kind({_Reporter, {ok, Value}}) when is_integer(Value) -> integer;
kind({_Reporter, {ok, _}}) -> text;
kind(_Attr) -> status.

text(Value) when is_binary(Value) -> Value;
text(Value) when is_integer(Value) -> integer_to_binary(Value);
text(Value) when is_atom(Value) -> atom_to_binary(Value);
%% A process as data, its proc_id(), prints as its pid's text <D.N.S>, alone
%% or as a list of them.
text({pid, D, N, S}) when is_integer(D), is_integer(N), is_integer(S) ->
    iolist_to_binary([$<, integer_to_binary(D), $., integer_to_binary(N), $., integer_to_binary(S), $>]);
text([{pid, _, _, _} | _] = ProcIds) ->
    iolist_to_binary([$[, lists:join($,, [text(ProcId) || ProcId <- ProcIds]), $]]);
%% An inspected location, {Module, Function, Arity, File, Line}, the file
%% and line shown when it has a source position.
text({Module, Function, Arity, <<>>, 0})
  when is_binary(Module), is_binary(Function), is_integer(Arity) ->
    function(Module, Function, Arity);
text({Module, Function, Arity, File, Line})
  when is_binary(Module), is_binary(Function), is_integer(Arity), is_binary(File), is_integer(Line) ->
    iolist_to_binary([function(Module, Function, Arity), " (", File, $:, integer_to_binary(Line), $)]);
text(Value) -> iolist_to_binary(io_lib:format("~0tp", [Value])).

function(Module, Function, Arity) ->
    iolist_to_binary([Module, $:, Function, $/, integer_to_binary(Arity)]).

%%% Inspection records

-doc """
An inspection record toward the terminal, as erx:i/1 prints it
(docs/design-live.md, "Inspection"): a title line of its path and kind,
then a line for each attribute it holds that the shell projection shows
in Build, in the schema's order, with its name, its reporter and its
value; then its children; then the scope of each stopgap reporter it
names. Nothing is cut.
""".
-spec record(erx_schema:record(), release | development) -> iodata().
record(#{children := Children} = Record, Build) ->
    [block(Record, Build, infinity,
           [[{<<"children">>, name}, {<<>>, name}, {children(Children), text}]]),
     notes([Record])].

-doc """
What erx:i/0 prints, from erx_inspector:overview/0's sections: each under
its path, a record as erx:i/1 shows it but without its children, each CPU
as such a record, and threads and processes as tables of a row each,
with a line under the header (`by`) naming each column's reporter; a cell
whose reporter is not its column's starts with its own in parentheses. A
path the inspector does not answer shows its status. Below them, the
scope of each stopgap reporter named. Lines are kept within 80 columns,
counted as characters: a text column other than the last is cut at 20
columns and the last at what is left, the end of a cut value shown as
`...`, as FreeBSD's ps cuts its last column; a status and an integer are
never cut, so a row of very wide integers may pass 80. erx:i/1 shows any record whole.
""".
-spec overview([{[erx_schema:segment()], erx_inspector:answer() | erx_inspector:entries()}],
               release | development) -> iodata().
overview(Sections, Build) ->
    [[section(Path, Answer, Build) || {Path, Answer} <- Sections],
     notes(lists:append([section_records(Answer) || {_Path, Answer} <- Sections]))].

%% The screen erx:i/0 fits, and how wide a cut column may be.
-define(SCREEN, 80).
-define(CUT_COLUMN, 20).
-define(MORE, <<"...">>).

section(_Path, {ok, Record}, Build) when is_map(Record) ->
    block(Record, Build, ?SCREEN, []);
section(Path, {error, Reason}, _Build) ->
    [title(Path), ?GAP, error_status(Reason), $\n];
section(Path, {Status, Records}, Build) ->
    Count = [integer_to_binary(length(Records)), <<" entries">>,
             case Status of partial -> <<" [partial]">>; ok -> <<>> end],
    [title(Path), ?GAP, Count, $\n, entries(Records, Build)].

error_status(unsupported) -> <<"[unsupported]">>;
error_status(_Reason) -> <<"[error]">>.

section_records({ok, Record}) when is_map(Record) -> [Record];
section_records({Status, Records}) when Status =:= ok; Status =:= partial -> Records;
section_records(_Error) -> [].

%% A listing's entries: a thread or a process a row each, anything else a
%% record each.
entries([#{kind := thread} | _] = Records, _Build) ->
    rows(Records, <<"thread">>, [{state, <<"state">>}, {wait, <<"wait">>}]);
entries([#{kind := process} | _] = Records, _Build) ->
    rows(Records, <<"pid">>, [{state, <<"state">>}, {reductions, <<"reductions">>},
                              {message_queue_len, <<"queue">>}, {registered_name, <<"name">>},
                              {location, <<"current">>}]);
entries(Records, Build) ->
    [block(Record, Build, ?SCREEN, []) || Record <- Records].

%% A record's title and a line per attribute: name, reporter, value; then
%% the Extra lines, aligned with them.
block(#{path := Path, kind := Kind, attrs := Attrs}, Build, Width, Extra) ->
    Keys = case erx_schema:fields(Kind, shell, Build) of
               {ok, Fields} -> [Key || Key <- Fields, is_map_key(Key, Attrs)];
               error -> []
           end,
    Lines = [[{escaped(atom_to_binary(Key)), name}, {reporter(maps:get(Key, Attrs)), name},
              cell(maps:get(Key, Attrs))] || Key <- Keys],
    [title(Path), ?GAP, escaped(atom_to_binary(Kind)), $\n, layout(Lines ++ Extra, Width)].

%% A table of a row per record: the id, then a cell for each column, under
%% a header and a line of each column's reporter, the first record's.
rows([#{attrs := First} | _] = Records, IdLabel, Columns) ->
    Reporters = [case maps:find(Key, First) of
                     {ok, {Reporter, _}} -> Reporter;
                     error -> none
                 end || {Key, _Label} <- Columns],
    Header = [{IdLabel, name} | [{Label, name} || {_Key, Label} <- Columns]],
    By = [{<<"by">>, name} | [{reporter_label(Reporter), name} || Reporter <- Reporters]],
    Rows = [[{escaped(text(Id)), text}
             | [row_cell(maps:find(Key, Attrs), Reporter)
                || {{Key, _Label}, Reporter} <- lists:zip(Columns, Reporters)]]
            || #{id := Id, attrs := Attrs} <- Records],
    layout([Header, By | Rows], ?SCREEN).

%% A row's cell: the value, a location by its function alone, after its
%% reporter when that is not its column's, so a cut never takes the
%% reporter; an attribute the record does not hold is an empty cell.
row_cell({ok, {Reporter, _} = Attr}, Reporter) ->
    cell(brief(Attr));
row_cell({ok, {Reporter, _} = Attr}, _Column) ->
    {Text, Kind} = cell(brief(Attr)),
    {<<"(", (reporter_label(Reporter))/binary, ") ", Text/binary>>, Kind};
row_cell(error, _Column) ->
    {<<>>, text}.

brief({Reporter, {ok, {Module, Function, Arity, File, Line}}})
  when is_binary(Module), is_binary(Function), is_integer(Arity), is_binary(File), is_integer(Line) ->
    {Reporter, {ok, function(Module, Function, Arity)}};
brief(Attr) ->
    Attr.

reporter({Reporter, _Value}) -> reporter_label(Reporter).

reporter_label(none) -> <<>>;
reporter_label(Reporter) ->
    case erx_schema:reporter_label(Reporter) of
        {ok, Label} -> escaped(Label);
        error -> <<"[invalid]">>
    end.

%% Lines of cells, indented, aligned and joined by the gap. Toward a screen
%% each text cell but the last is cut at ?CUT_COLUMN and the last at what
%% the screen has left; an integer is never cut.
layout([], _Width) ->
    [];
layout(Lines, infinity) ->
    Columns = [column(Cells) || Cells <- transpose(Lines)],
    [[?GAP, row(Cells, Columns)] || Cells <- Lines];
layout(Lines, Width) ->
    Cut = [[cut(Cell, ?CUT_COLUMN) || Cell <- lists:droplast(Cells)] ++ [lists:last(Cells)]
           || Cells <- Lines],
    Leading = [column(Cells) || Cells <- lists:droplast(transpose(Cut))],
    Room = Width - byte_size(?GAP) * (length(Leading) + 1)
        - lists:sum([W || {W, _} <- Leading]),
    Fitted = [lists:droplast(Cells) ++ [cut(lists:last(Cells), max(Room, byte_size(?MORE)))]
              || Cells <- Cut],
    layout(Fitted, infinity).

cut({_Text, Kind} = Cell, _Width) when Kind =:= integer; Kind =:= status ->
    Cell;
cut({Text, Kind} = Cell, Width) ->
    case width(Text) > Width of
        true -> {iolist_to_binary([string:slice(Text, 0, Width - width(?MORE)), ?MORE]), Kind};
        false -> Cell
    end.

children(unknown) -> <<"[unknown]">>;
children({partial, _Segments}) -> <<"[partial]">>;
children(Segments) -> escaped(lists:join(<<" ">>, [segment(Segment) || Segment <- Segments])).

%% A path as /proc writes it, each segment escaped.
title(Path) ->
    escaped([$/ | lists:join($/, [segment(Segment) || Segment <- Path])]).

segment(Segment) when is_binary(Segment) -> Segment;
segment({pid, _D, _N, _S} = ProcId) -> erx_schema:segment_text(ProcId);
segment(Segment) -> text(Segment).

escaped(Text) -> erx_text:escape_line(Text).

%% Below a table, the scope of each stopgap reporter it names, wrapped to
%% the screen.
notes(Records) ->
    Stopgaps = lists:usort([Name || #{attrs := Attrs} <- Records,
                                    {{stopgap, Name}, _Value} <- maps:values(Attrs)]),
    [note(Name) || Name <- Stopgaps].

note(Name) ->
    case erx_schema:stopgap(Name) of
        {ok, #{label := Label, scope := Scope}} ->
            wrap(string:lexemes(escaped([Label, <<": ">>, Scope]), " "), <<>>);
        error ->
            []
    end.

wrap([], Line) ->
    [Line, $\n];
wrap([Word | Words], <<>>) ->
    wrap(Words, Word);
wrap([Word | Words], Line) ->
    case width(Line) + 1 + width(Word) > ?SCREEN of
        true -> [Line, $\n | wrap(Words, <<"  ", Word/binary>>)];
        false -> wrap(Words, <<Line/binary, " ", Word/binary>>)
    end.
