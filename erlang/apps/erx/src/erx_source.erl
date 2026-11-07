%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_source).
-moduledoc """
From a process, or a function, to the lines of source it is at
(docs/design-live.md, "From a process to its source"): what `erx:source/1`
prints in the shell.

A process's current location names its module, function, arity, file and
line. The module's source is found by the file's base name in the `src`
or `include` directory beside the `ebin` directory the module was loaded
from, and only when the source can be shown truthfully; otherwise the
answer is `{error, unsupported}`, never a line from another file or
another version of the module:

* the module must be loaded from a file `.../ebin/Name.beam` at an
  absolute path, which a release's modules are and a module loaded from
  the host (named by its hash, with no directory) is not;
* the loaded code must be the code of that file, by its MD5, so a module
  replaced in memory is not shown with the release's source;
* the process must not be running the module's old code, which a reload
  left behind;
* the line must be in the file.

The release ships no `src` directories, so its modules answer
`unsupported`; a module compiled into a directory tree of that shape, on
the machine or in an image that carries sources, shows its lines.

A pid of another runtime is answered `{error, unsupported}`: its source is
reached only through the inspector, which this module does not ask. A
local pid that names no live process is answered `{error, scope}`, the
inspector's answer for a path that names nothing. A function's first line
is the line the loaded beam gives its entry, read by beam_disasm from the
file whose MD5 matches the code in memory, so it names a function the
module has and creates no atom; a module that is not loaded is not loaded
for this, and answers `unsupported`.

The decisions are pure (`candidates/2`, `entry_location/3`, `excerpt/2`,
`render/1`); `lines/1` gathers the facts they decide on: the process's
location, the module's file, its MD5, its disassembly and the source's
bytes. Every text of the source, the location's names included, is shown
only through erx_text's line escape: the bytes of a source file and the
names in a loaded module's line table are untrusted, and so are the lines
of an excerpt for any other renderer.
""".

-include_lib("kernel/include/file.hrl").

-export([print/1, lines/1, render/1]).
-export([candidates/2, entry_location/3, excerpt/2]).
-export_type([excerpt/0, reason/0]).

%% Lines shown on each side of the location's line.
-define(CONTEXT, 5).
%% The largest source file read, in bytes.
-define(MAX_SOURCE_BYTES, 16#400000).
-define(TAB_STOP, 8).

-doc """
The lines around a location: where it is, the number of the first line
shown, and the lines' bytes as the file holds them, without their line
ends.
""".
-type excerpt() :: #{location := {module(), atom(), arity(), file:filename(), pos_integer()},
                     first := pos_integer(),
                     lines := [binary()]}.

-type reason() :: unsupported | scope.

-doc """
Prints the source lines around `Target`'s location: a process's current
location, or a function's first line. Answers what `lines/1` refuses with.
""".
-spec print(pid() | mfa()) -> ok | {error, reason()}.
print(Target) ->
    case lines(Target) of
        {ok, Excerpt} -> io:put_chars(render(Excerpt));
        {error, _} = Refused -> Refused
    end.

-doc """
The source lines around a process's current location, or around a
function's first line. A target that is neither a pid nor a
`{Module, Function, Arity}` fails with `badarg`.
""".
-spec lines(pid() | mfa()) -> {ok, excerpt()} | {error, reason()}.
lines(Pid) when is_pid(Pid) ->
    maybe
        {ok, {Module, _, _, File, _} = Location} ?= location(Pid),
        {ok, Version} ?= current_code(Pid, Module),
        {ok, Loaded} ?= loaded_file(Module, Version),
        {ok, Text} ?= module_source(Loaded, File),
        {ok, Version} ?= current_code(Pid, Module),
        excerpt(Location, Text)
    else
        {ok, _Reloaded} -> {error, unsupported};
        {error, _} = Refused -> Refused
    end;
lines({Module, Function, Arity}) when is_atom(Module), is_atom(Function),
                                      is_integer(Arity), Arity >= 0 ->
    maybe
        {ok, Version} ?= loaded_version(Module),
        {ok, Loaded} ?= loaded_file(Module, Version),
        {ok, {File, Line}} ?= entry(Loaded, Function, Arity),
        {ok, Text} ?= module_source(Loaded, File),
        excerpt({Module, Function, Arity, File, Line}, Text)
    end;
lines(Target) ->
    error(badarg, [Target]).

-doc """
The excerpt as lines for a display: a header naming the location, then
each line numbered, the location's line marked with `>`, its tabs
expanded to stops of eight columns, and everything through erx_text's
line escape.
""".
-spec render(excerpt()) -> unicode:unicode_binary().
render(#{location := {Module, Function, Arity, File, LocationLine},
         first := First, lines := Lines}) ->
    Header = io_lib:format("~ts:~w in ~tw:~tw/~w",
                           [File, LocationLine, Module, Function, Arity]),
    Last = First + length(Lines) - 1,
    Width = length(integer_to_list(Last)),
    Numbered = lists:zip(lists:seq(First, Last), Lines),
    iolist_to_binary(
      [erx_text:escape_line(Header), $\n
       | [[marker(Number, LocationLine), pad(Number, Width), "  ",
           erx_text:escape_line(expand_tabs(LineBytes)), $\n]
          || {Number, LineBytes} <- Numbered]]).

-doc """
The paths at which a module's source may be found, the `src` directory
first: `Loaded` is the file the module was loaded from, which must be
`.../ebin/Name.beam` at an absolute path, and `File` is the file the
location names, of which only the base name counts. `unsupported` when
either is not of that shape, so no name in a location reaches a file
outside those two directories.
""".
-spec candidates(Loaded :: term(), File :: term()) -> {ok, [file:filename()]} | unsupported.
candidates(Loaded, File) ->
    case {loaded_root(Loaded), base_name(File)} of
        {{ok, Root}, {ok, Base}} ->
            {ok, [filename:join([Root, "src", Base]), filename:join([Root, "include", Base])]};
        _ ->
            unsupported
    end.

-doc """
The file and line of `Function/Arity`'s entry in `Code`, the code of
beam_disasm's disassembly: the line instruction before the function's
`func_info`. `{error, unsupported}` when the module has no such function
or the compiler gave its entry no line.
""".
-spec entry_location(list(), atom(), arity()) ->
    {ok, {string(), pos_integer()}} | {error, unsupported}.
entry_location(Code, Function, Arity) ->
    case [Body || {function, F, A, _Entry, Body} <- Code, F =:= Function, A =:= Arity] of
        [Body] -> entry_line(Body, Function, Arity);
        _ -> {error, unsupported}
    end.

-doc """
The lines of `Text` around the location's line, at most five on each
side. `{error, unsupported}` when the file has no such line, which means
it is not the file the module was compiled from.
""".
-spec excerpt({module(), atom(), arity(), file:filename(), pos_integer()}, binary()) ->
    {ok, excerpt()} | {error, unsupported}.
excerpt({_Module, _Function, _Arity, _File, Line} = Location, Text) ->
    All = file_lines(Text),
    case is_integer(Line) andalso Line >= 1 andalso Line =< length(All) of
        true ->
            First = max(1, Line - ?CONTEXT),
            Last = min(length(All), Line + ?CONTEXT),
            {ok, #{location => Location, first => First,
                   lines => lists:sublist(All, First, Last - First + 1)}};
        false ->
            {error, unsupported}
    end.

%% The facts, gathered from the runtime and the file system.

%% A pid of another runtime makes process_info fail with badarg.
location(Pid) ->
    try erlang:process_info(Pid, current_location) of
        undefined -> {error, scope};
        {current_location, {Module, Function, Arity, Info}} ->
            location(Module, Function, Arity, Info)
    catch
        error:badarg -> {error, unsupported}
    end.

location(Module, Function, Arity, Info) ->
    case {proplists:get_value(file, Info), proplists:get_value(line, Info)} of
        {File, Line} when is_list(File), is_integer(Line), Line > 0 ->
            {ok, {Module, Function, Arity, File, Line}};
        _ ->
            {error, unsupported}
    end.

%% The version of the module's current code, when the process is not
%% running the module's old code, which a reload left behind. lines/1 asks
%% before and after reading the source, so a reload between the two is
%% refused rather than shown against the other version's text.
current_code(Pid, Module) ->
    case erlang:check_process_code(Pid, Module) of
        false -> loaded_version(Module);
        true -> {error, unsupported}
    end.

%% The MD5 of the module's current code, without loading it.
loaded_version(Module) ->
    try erlang:get_module_info(Module, md5) of
        Version -> {ok, Version}
    catch
        error:badarg -> {error, unsupported}
    end.

%% The file the module was loaded from, when the code in memory is still
%% that file's code.
loaded_file(Module, Version) ->
    case code:is_loaded(Module) of
        {file, Loaded} when is_list(Loaded) ->
            case beam_lib:md5(Loaded) of
                {ok, {Module, Version}} -> {ok, Loaded};
                _ -> {error, unsupported}
            end;
        _ ->
            {error, unsupported}
    end.

%% The entry of a function in the loaded file's disassembly. The file's
%% MD5 is the code in memory's, so every atom it names already exists.
entry(Loaded, Function, Arity) ->
    case beam_disasm:file(Loaded) of
        {beam_file, _Module, _Exports, _Attributes, _Compile, Code} ->
            entry_location(Code, Function, Arity);
        {error, beam_lib, _} ->
            {error, unsupported}
    end.

%% The source beside the loaded file, by the base name of `File`.
module_source(Loaded, File) ->
    maybe
        {ok, Paths} ?= candidates(Loaded, File),
        {ok, _Text} ?= first_readable(Paths)
    else
        _ -> {error, unsupported}
    end.

first_readable([]) ->
    unsupported;
first_readable([Path | Paths]) ->
    case read_source(Path) of
        {ok, Text} -> {ok, Text};
        error -> first_readable(Paths)
    end.

read_source(Path) ->
    maybe
        {ok, #file_info{type = regular, size = Size}} ?= file:read_file_info(Path),
        true ?= Size =< ?MAX_SOURCE_BYTES,
        {ok, Text} ?= file:read_file(Path),
        true ?= byte_size(Text) =< ?MAX_SOURCE_BYTES,
        {ok, Text}
    else
        _ -> error
    end.

%% The pure decisions.

loaded_root(Loaded) when is_list(Loaded) ->
    Ebin = filename:dirname(Loaded),
    case filename:pathtype(Loaded) =:= absolute andalso filename:basename(Ebin) =:= "ebin" andalso
         filename:extension(Loaded) =:= ".beam" of
        true -> {ok, filename:dirname(Ebin)};
        false -> error
    end;
loaded_root(_Loaded) ->
    error.

%% A location's file is a character list; its base name must name a file
%% in the directory it is joined to.
base_name(File) when is_list(File) ->
    case io_lib:char_list(File) andalso lists:all(fun is_name_character/1, File) of
        true ->
            case filename:basename(File) of
                Base when Base =:= ""; Base =:= "."; Base =:= ".." -> error;
                Base -> {ok, Base}
            end;
        false ->
            error
    end;
base_name(_File) ->
    error.

is_name_character(C) ->
    is_integer(C) andalso C > 0 andalso C =< 16#10FFFF.

entry_line([{line, [{location, File, Line}]}, {func_info, _, {atom, Function}, Arity} | _],
           Function, Arity) when is_list(File), is_integer(Line), Line > 0 ->
    {ok, {File, Line}};
entry_line([_Instruction | Body], Function, Arity) ->
    entry_line(Body, Function, Arity);
entry_line([], _Function, _Arity) ->
    {error, unsupported}.

%% A file's lines without their line ends, LF or CR LF; a last line
%% without a line end is a line, and the empty text after a final line
%% end is not.
file_lines(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    Complete = case lists:last(Lines) of
                   <<>> -> lists:droplast(Lines);
                   _ -> Lines
               end,
    [strip_cr(Line) || Line <- Complete].

strip_cr(Line) ->
    case Line of
        <<Body:(byte_size(Line) - 1)/binary, $\r>> -> Body;
        _ -> Line
    end.

marker(Number, LocationLine) when Number =:= LocationLine -> "> ";
marker(_Number, _LocationLine) -> "  ".

pad(Number, Width) ->
    string:pad(integer_to_list(Number), Width, leading).

%% Tabs become spaces to the next stop before the line escape, which would
%% show each as a token; spaces are safe, and no UTF-8 sequence is split.
%% A column is a character, counted as a byte that does not continue a
%% UTF-8 sequence; columns after a character the escape renders drift.
expand_tabs(Text) ->
    expand_tabs(Text, 0, []).

expand_tabs(<<>>, _Column, Acc) ->
    iolist_to_binary(lists:reverse(Acc));
expand_tabs(<<$\t, Rest/binary>>, Column, Acc) ->
    Spaces = ?TAB_STOP - Column rem ?TAB_STOP,
    expand_tabs(Rest, Column + Spaces, [binary:copy(<<" ">>, Spaces) | Acc]);
expand_tabs(<<Byte, Rest/binary>>, Column, Acc) when Byte >= 16#80, Byte =< 16#BF ->
    expand_tabs(Rest, Column, [Byte | Acc]);
expand_tabs(<<Byte, Rest/binary>>, Column, Acc) ->
    expand_tabs(Rest, Column + 1, [Byte | Acc]).
