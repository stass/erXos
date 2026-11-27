%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_abi_reader).
-moduledoc """
The one bounded structural reader over immutable ABI bytes, shared by every
reader module that `tools/gen_abi.rb` generates from a `reader` declaration
of the ABI sources (`erx_manifest`, `erx_pkg_reader`). Policy admission is
separate.

A generated reader module holds only its spec, constant data the generator
derives (`tools/lib/erx/abi_emit_erlang.rb`, `spec_data`), and thin calls
that hand it to the functions here. The spec, `spec()` below, names the
root layout, the input's byte bound, the tables in file order, the rules,
and every type the reader reaches by name; `schema` is the generated module
itself, which a view records so that one reader's view is refused by
another. Each generated `spec/0` is typed `spec()`, so Dialyzer checks the
generator's data against the shapes this module reads.

The bytes are untrusted: every offset, length and count read from them is
bounded before it is used, through `slice/4` and the table and rule checks,
and a malformed input is an `error()` naming the reason, the field and its
byte offset. Only those explicit parse errors are translated: an
implementation bug stays an exception for the tests and the fuzz targets
to see.
""".

-export([open/2, open_prefix/2, header/2, count/3, fetch/4, span/5, string/3, fold/5]).
-export_type([spec/0, view/0, error/0]).

-record(view, {schema :: module(), bytes :: binary()}).
-opaque view() :: #view{}.
-type error() :: #{reason := atom(), field := binary(), offset := non_neg_integer()}.
%% A generated reader module's constant data: the module that owns its
%% views, the root layout, the input's byte bound, the extent field that
%% names the input's length, the role whose input masks apply, the tables
%% and string tables in file order, the rules, and every type by name.
-type spec() :: #{schema := module(),
                  root := atom(),
                  maximum := non_neg_integer(),
                  extent := path() | none,
                  source_role := atom(),
                  order := [atom()],
                  tables := #{atom() => table()},
                  strings := #{atom() => table()},
                  rules := [rule()],
                  types := #{atom() => type_def()}}.
%% A field reached from a record: `scope` is `root` for the header or the
%% table whose row holds it, `fields` the field names down to it, `offset`
%% its byte offset in that record, `size` its width and `label` its name
%% in errors.
-type path() :: #{scope := atom(), fields := [atom()], offset := non_neg_integer(),
                  size := pos_integer(), label := binary()}.
%% A table: the header fields giving its byte offset and its count, the
%% most rows it may hold, its alignment, and its row type and stride
%% (`bytes` and 1 for a string table).
-type table() :: #{offset := path(), count := path(), maximum := non_neg_integer(),
                   alignment := pos_integer(), type := atom(), size := pos_integer()}.
%% A type by kind. A scalar or enum is read as its integer base; a layout's
%% padding is its [Offset, Length] runs, which must be zero.
-type type_def() ::
          #{kind := integer, size := pos_integer(), signed := boolean()}
        | #{kind := scalar, size := pos_integer(), base := atom(), minimum := integer(),
            maximum := integer(), multiple := pos_integer()}
        | #{kind := enum, size := pos_integer(), base := atom(), flags := boolean(),
            mask := non_neg_integer(), values := [integer()], allowed := [integer()] | none}
        | #{kind := bytes, size := pos_integer(), fixed := binary() | none}
        | #{kind := layout, size := pos_integer(), fields := [field()],
            padding := [[non_neg_integer()]]}.
%% A layout's field: `count` is `scalar` or an array's length; `zero` the
%% bits that must be clear; `input_masks` the bits each role may set.
-type field() :: #{name := atom(), type := atom(), offset := non_neg_integer(),
                   count := scalar | pos_integer(), zero := non_neg_integer(),
                   input_masks := #{atom() => non_neg_integer()}}.
%% A rule by kind, checked on every record of its path's scope; a rule
%% with a guard applies only where the guard's tag field holds its value.
-type rule() ::
          #{kind := value | range, path := path(), values := [integer()], guard => guard()}
        | #{kind := index, path := path(), table := atom(), absent := integer() | none,
            guard => guard()}
        | #{kind := slice | partition, offset := path(), count := path(), table := atom(),
            field := atom(), guard => guard()}
        | #{kind := string, offset := path(), count := path(), table := atom(),
            class := atom(), maximum := non_neg_integer(), empty := boolean(),
            guard => guard()}
        | #{kind := optional, path := path(), flags := path(), mask := non_neg_integer(),
            guard => guard()}
        | #{kind := choice, tag := path(), fields := [path()], cases := #{integer() => [path()]},
            guard => guard()}.
-type guard() :: #{tag := path(), value := integer()}.

-doc "Validate structure, references and declared constraints; not policy admission.".
-spec open(spec(), binary()) -> {ok, view()} | {error, error()}.
open(Spec, Bytes) ->
    attempt(fun() ->
        Header = checked_header(Spec, Bytes),
        Tables = maps:get(tables, Spec),
        lists:foreach(fun(Name) ->
            case maps:find(Name, Tables) of
                {ok, Table} ->
                    check_records(Name, Table, Bytes, Header, Spec, 0);
                error ->
                    ok
            end
        end, maps:get(order, Spec)),
        check_partitions(Spec, Header, Bytes),
        #view{schema = maps:get(schema, Spec), bytes = Bytes}
    end).

-doc """
Validate the input at the front of a longer binary: the root's extent
field names its length, and the bytes up to it, or as many as there are,
are opened as open/2 opens them. Only a spec that declares an extent is
read this way.
""".
-spec open_prefix(spec(), binary()) -> {ok, view()} | {error, error()}.
open_prefix(Spec, Bytes) when is_binary(Bytes) ->
    Root = attempt(fun() ->
        decode(maps:get(types, Spec), maps:get(root, Spec), Bytes, 0, <<"root">>)
    end),
    case Root of
        {ok, Header} ->
            Length = path_value(maps:get(extent, Spec), Header, Header),
            open(Spec, binary:part(Bytes, 0, min(Length, byte_size(Bytes))));
        {error, _} = Error ->
            Error
    end;
open_prefix(_Spec, _) ->
    {error, error_value(length, <<"root">>, 0)}.

-doc "Return the checked header of a view from open/2.".
-spec header(spec(), view()) -> {ok, map()} | {error, error()}.
header(Spec, View) ->
    attempt(fun() ->
        {_Bytes, Header} = view_data(Spec, View),
        Header
    end).

-doc "Count records in a statically named table.".
-spec count(spec(), view(), atom()) -> {ok, non_neg_integer()} | {error, error()}.
count(Spec, View, Name) ->
    attempt(fun() ->
        {_Bytes, Header} = view_data(Spec, View),
        Table = record_table(Name, Spec),
        path_value(maps:get(count, Table), Header, Header)
    end).

-doc "Fetch one checked record; out-of-range indices are errors.".
-spec fetch(spec(), view(), atom(), non_neg_integer()) -> {ok, map()} | {error, error()}.
fetch(Spec, View, Name, Index) ->
    attempt(fun() ->
        {Bytes, Header} = view_data(Spec, View),
        {_Base, Record} = indexed_record(Name, Index, Bytes, Header, Spec),
        Record
    end).

-doc """
The checked rows that span field `Field` of row `Index` of table
`Owner` names, in the table that span's slice or partition rule
gives. An `Owner` and `Field` pair that no such rule names is an
unknown_span error; an `Index` outside `Owner` is an index error.
""".
-spec span(spec(), view(), atom(), non_neg_integer(), atom()) ->
    {ok, [map()]} | {error, error()}.
span(Spec, View, Owner, Index, Field) ->
    attempt(fun() ->
        {Bytes, Header} = view_data(Spec, View),
        Rule = span_rule(Owner, Field, Spec),
        {Base, Record} = indexed_record(Owner, Index, Bytes, Header, Spec),
        {First, Count} = span_rows(Rule, Record, Header, Base, Spec),
        TargetName = maps:get(table, Rule),
        Target = record_table(TargetName, Spec),
        [record_at(TargetName, Target, Row, Bytes, Header, Spec)
         || Row <- lists:seq(First, First + Count - 1)]
    end).

-doc "Resolve a bounded reference into the manifest's string table.".
-spec string(spec(), view(), #{offset := non_neg_integer(), length := non_neg_integer()}) ->
    {ok, binary()} | {error, error()}.
string(Spec, View, Reference) ->
    attempt(fun() ->
        {Bytes, Header} = view_data(Spec, View),
        case Reference of
            #{offset := Offset, length := Length}
              when is_integer(Offset), Offset >= 0,
                   is_integer(Length), Length >= 0 ->
                Table = string_table(strings, Spec),
                Count = path_value(maps:get(count, Table), Header, Header),
                ensure(Offset =< Count andalso Length =< Count - Offset,
                       string_range, <<"strings">>, 0),
                Start = path_value(maps:get(offset, Table), Header, Header),
                slice(Bytes, Start + Offset, Length, <<"strings">>);
            _ ->
                fail(string_reference, <<"strings">>, 0)
        end
    end).

-doc "Fold a validated table without retaining every decoded record.".
-spec fold(spec(), view(), atom(), fun((map(), term()) -> term()), term()) ->
    {ok, term()} | {error, error()}.
fold(Spec, View, Name, Function, Initial) when is_function(Function, 2) ->
    Prepared = attempt(fun() ->
        {Bytes, Header} = view_data(Spec, View),
        {Bytes, Header, record_table(Name, Spec)}
    end),
    case Prepared of
        {ok, {Bytes, Header, Table}} ->
            fold_records(Name, Table, Bytes, Header, Spec,
                         Function, Initial, 0);
        {error, _} = Error ->
            Error
    end;
fold(_Spec, _, _, _, _) ->
    {error, error_value(callback, <<"table">>, 0)}.

%% The byte offset of the record at Index of table Name, and the record;
%% an index outside the table is an error.
indexed_record(Name, Index, Bytes, Header, Spec) ->
    Table = record_table(Name, Spec),
    Count = path_value(maps:get(count, Table), Header, Header),
    ensure(is_integer(Index) andalso Index >= 0 andalso Index < Count,
           index, <<"table">>, 0),
    {record_base(Table, Index, Header), record_at(Name, Table, Index, Bytes, Header, Spec)}.

%% The byte offset of the record at Index of Table.
record_base(Table, Index, Header) ->
    path_value(maps:get(offset, Table), Header, Header) + Index * maps:get(size, Table).

%% The record at Index of Table, which the caller bounded.
record_at(Name, Table, Index, Bytes, Header, Spec) ->
    Offset = record_base(Table, Index, Header),
    Type = maps:get(type, Table),
    Record = decode(maps:get(types, Spec), Type, Bytes, Offset, <<"table">>),
    check_scope(Name, Type, Record, Bytes, Offset, Header, Spec),
    Record.

%% Only our explicit parse errors are translated. An implementation bug
%% remains an exception for tests/fuzzing instead of becoming bad input.
attempt(Function) ->
    try Function() of
        Value -> {ok, Value}
    catch
        throw:{abi_error, Reason, Field, Offset}:_Stacktrace ->
            {error, error_value(Reason, Field, Offset)}
    end.

error_value(Reason, Field, Offset) ->
    #{reason => Reason, field => Field, offset => Offset}.

fail(Reason, Field, Offset) ->
    throw({abi_error, Reason, Field, Offset}).

ensure(true, _Reason, _Field, _Offset) -> ok;
ensure(false, Reason, Field, Offset) -> fail(Reason, Field, Offset).

%% A view stores no independently mutable copy of offsets or counts.
%% Accessors recheck the small header/table directory, not every row.
%% A view that another reader opened is refused.
view_data(#{schema := Schema} = Spec, #view{schema = Schema, bytes = Bytes})
  when is_binary(Bytes) ->
    {Bytes, checked_header(Spec, Bytes)};
view_data(_Spec, _) ->
    fail(view, <<"view">>, 0).

checked_header(Spec, Bytes) when is_binary(Bytes) ->
    ensure(byte_size(Bytes) =< maps:get(maximum, Spec),
           length, <<"root">>, 0),
    Types = maps:get(types, Spec),
    RootType = maps:get(root, Spec),
    Header = decode(Types, RootType, Bytes, 0, <<"root">>),
    case maps:get(extent, Spec) of
        none -> ok;
        Extent ->
            ensure(path_value(Extent, Header, Header) =:= byte_size(Bytes),
                   length, maps:get(label, Extent), maps:get(offset, Extent))
    end,
    End = check_tables(maps:get(order, Spec), Spec, Header,
                       Bytes, maps:get(size, type(RootType, Types))),
    ensure(End =:= byte_size(Bytes), trailing, <<"root">>, End),
    check_scope(root, RootType, Header, Bytes, 0, Header, Spec),
    Header;
checked_header(_Spec, _) ->
    fail(length, <<"root">>, 0).

%% A type the spec reaches by name; the generator emits every one it
%% reaches, so a missing one is a spec this reader does not support.
type(Name, Types) ->
    case maps:find(Name, Types) of
        {ok, Type} -> Type;
        error -> fail(unsupported, <<"schema">>, 0)
    end.

record_table(Name, Spec) ->
    case maps:find(Name, maps:get(tables, Spec)) of
        {ok, Table} -> Table;
        error -> fail(unknown_table, <<"table">>, 0)
    end.

string_table(Name, Spec) ->
    case maps:find(Name, maps:get(strings, Spec)) of
        {ok, Table} -> Table;
        error -> fail(unknown_string_table, <<"strings">>, 0)
    end.

table(Name, Spec) ->
    case maps:find(Name, maps:get(tables, Spec)) of
        {ok, Table} -> Table;
        error -> string_table(Name, Spec)
    end.

check_tables([], _Spec, _Header, _Bytes, Cursor) -> Cursor;
check_tables([Name | Rest], Spec, Header, Bytes, Cursor) ->
    Table = table(Name, Spec),
    Alignment = maps:get(alignment, Table),
    Padding = (Alignment - Cursor rem Alignment) rem Alignment,
    Label = atom_to_binary(Name, utf8),
    ensure(Padding =< byte_size(Bytes) - Cursor,
           truncated, Label, Cursor),
    ensure(zero(slice(Bytes, Cursor, Padding, Label)),
           padding, Label, Cursor),
    Start = Cursor + Padding,
    Offset = path_value(maps:get(offset, Table), Header, Header),
    Count = path_value(maps:get(count, Table), Header, Header),
    Stride = maps:get(size, Table),
    ensure(Offset =:= Start, order, Label, Start),
    ensure(Count =< maps:get(maximum, Table) andalso
           Count =< (byte_size(Bytes) - Start) div Stride,
           extent, Label, Start),
    check_tables(Rest, Spec, Header, Bytes, Start + Count * Stride).

check_records(Name, Table, Bytes, Header, Spec, Index) ->
    Count = path_value(maps:get(count, Table), Header, Header),
    case Index < Count of
        false -> ok;
        true ->
            Offset = record_base(Table, Index, Header),
            Type = maps:get(type, Table),
            Record = decode(maps:get(types, Spec), Type, Bytes, Offset,
                            atom_to_binary(Name, utf8)),
            check_scope(Name, Type, Record, Bytes, Offset, Header, Spec),
            check_records(Name, Table, Bytes, Header, Spec, Index + 1)
    end.

%% An owner span partitions one target table. Progress is measured in
%% target records, so an offset never multiplies an unchecked count.
check_partitions(Spec, Header, Bytes) ->
    lists:foreach(fun(Rule) ->
        case maps:get(kind, Rule) of
            partition ->
                Path = maps:get(offset, Rule),
                Owner = record_table(maps:get(scope, Path), Spec),
                Target = record_table(maps:get(table, Rule), Spec),
                partition_rows(Rule, Owner, Target, Header, Bytes, Spec, 0, 0);
            _ -> ok
        end
    end, maps:get(rules, Spec)).

partition_rows(Rule, Owner, Target, Header, Bytes, Spec, Index, Covered) ->
    OwnerCount = path_value(maps:get(count, Owner), Header, Header),
    TargetCount = path_value(maps:get(count, Target), Header, Header),
    TargetOffset = path_value(maps:get(offset, Target), Header, Header),
    Stride = maps:get(size, Target),
    Path = maps:get(offset, Rule),
    case Index < OwnerCount of
        false ->
            ensure(Covered =:= TargetCount, partition,
                   maps:get(label, Path), TargetOffset + Covered * Stride);
        true ->
            OwnerBase = record_base(Owner, Index, Header),
            Record = decode(maps:get(types, Spec), maps:get(type, Owner), Bytes,
                            OwnerBase, maps:get(label, Path)),
            Offset = path_value(Path, Record, Header),
            Count = path_value(maps:get(count, Rule), Record, Header),
            ensure(Offset =:= TargetOffset + Covered * Stride andalso
                   Covered =< TargetCount andalso
                   Count =< TargetCount - Covered,
                   partition, maps:get(label, Path),
                   OwnerBase + maps:get(offset, Path)),
            partition_rows(Rule, Owner, Target, Header, Bytes, Spec,
                           Index + 1, Covered + Count)
    end.

%% The first row and the count of the rows of a slice or partition
%% rule's table that the rule's span in Record, the record at byte Base,
%% names. The span's offset is the byte offset of its first row; a span
%% that does not fall whole on the table's rows is an error at that
%% offset field. The open check and span/5 both locate a span here.
span_rows(#{offset := Path, count := CountPath, table := Name}, Record, Header, Base, Spec) ->
    Table = record_table(Name, Spec),
    Total = path_value(maps:get(count, Table), Header, Header),
    Stride = maps:get(size, Table),
    Relative = path_value(Path, Record, Header) - path_value(maps:get(offset, Table), Header, Header),
    Count = path_value(CountPath, Record, Header),
    ensure(Relative >= 0 andalso Relative rem Stride =:= 0 andalso
           Relative div Stride =< Total andalso
           Count =< Total - Relative div Stride,
           slice, maps:get(label, Path), Base + maps:get(offset, Path)),
    {Relative div Stride, Count}.

%% The slice or partition rule of span field Field of table Owner's rows.
span_rule(Owner, Field, Spec) ->
    Rules = [Rule || #{field := RuleField, offset := #{scope := RuleOwner}} = Rule
                         <- maps:get(rules, Spec),
                     RuleOwner =:= Owner, RuleField =:= Field],
    case Rules of
        [Rule | _] -> Rule;
        [] -> fail(unknown_span, <<"span">>, 0)
    end.

fold_records(Name, Table, Bytes, Header, Spec, Function, Accumulator, Index) ->
    Count = path_value(maps:get(count, Table), Header, Header),
    case Index < Count of
        false -> {ok, Accumulator};
        true ->
            Parsed = attempt(fun() ->
                record_at(Name, Table, Index, Bytes, Header, Spec)
            end),
            case Parsed of
                {ok, Record} ->
                    Next = Function(Record, Accumulator),
                    fold_records(Name, Table, Bytes, Header, Spec,
                                 Function, Next, Index + 1);
                {error, _} = Error -> Error
            end
    end.

slice(Bytes, Offset, Length, Label) ->
    ensure(is_integer(Offset) andalso Offset >= 0 andalso
           is_integer(Length) andalso Length >= 0 andalso
           Offset =< byte_size(Bytes) andalso
           Length =< byte_size(Bytes) - Offset,
           truncated, Label, Offset),
    binary:part(Bytes, Offset, Length).

decode(Types, Name, Bytes, Offset, Label) ->
    Type = type(Name, Types),
    Size = maps:get(size, Type),
    _ = slice(Bytes, Offset, Size, Label),
    case maps:get(kind, Type) of
        integer ->
            Bits = Size * 8,
            case maps:get(signed, Type) of
                true ->
                    <<Value:Bits/little-signed-integer>> =
                        binary:part(Bytes, Offset, Size),
                    Value;
                false ->
                    <<Value:Bits/little-unsigned-integer>> =
                        binary:part(Bytes, Offset, Size),
                    Value
            end;
        scalar -> decode(Types, maps:get(base, Type), Bytes, Offset, Label);
        enum -> decode(Types, maps:get(base, Type), Bytes, Offset, Label);
        bytes -> binary:part(Bytes, Offset, Size);
        layout ->
            maps:from_list([decode_field(Types, Field, Bytes, Offset, Label)
                            || Field <- maps:get(fields, Type)])
    end.

decode_field(Types, Field, Bytes, Base, Label) ->
    Name = maps:get(name, Field),
    Type = maps:get(type, Field),
    Offset = Base + maps:get(offset, Field),
    Value = case {maps:get(count, Field), Type} of
        {scalar, _} -> decode(Types, Type, Bytes, Offset, Label);
        {Count, u8} -> slice(Bytes, Offset, Count, Label);
        {Count, _} -> decode_array(Types, Type, Count, Bytes, Offset, Label, [])
    end,
    {Name, Value}.

decode_array(_Types, _Type, 0, _Bytes, _Offset, _Label, Result) ->
    lists:reverse(Result);
decode_array(Types, Type, Count, Bytes, Offset, Label, Result) ->
    Value = decode(Types, Type, Bytes, Offset, Label),
    decode_array(Types, Type, Count - 1, Bytes,
                 Offset + maps:get(size, type(Type, Types)), Label, [Value | Result]).

check_scope(Scope, Type, Record, Bytes, Base, Header, Spec) ->
    Rules = maps:get(rules, Spec),
    check_layout(Type, Record, Bytes, Base, Scope, [], Record, Header, Spec),
    lists:foreach(fun(Rule) ->
        Path = rule_path(Rule),
        case maps:get(scope, Path) =:= Scope of
            false -> ok;
            true ->
                Kind = maps:get(kind, Rule),
                StorageActive = Kind =:= optional orelse Kind =:= choice orelse
                                active(Rules, Scope, maps:get(fields, Path),
                                       Record, Header),
                Enabled = StorageActive andalso rule_enabled(Rule, Record, Header),
                case Enabled of
                    true -> check_rule(Rule, Record, Header, Bytes, Base, Spec);
                    false -> ok
                end
        end
    end, Rules).

check_layout(Name, Value, Bytes, Base, Scope, Prefix, Record, Header, Spec) ->
    Types = maps:get(types, Spec),
    Layout = type(Name, Types),
    lists:foreach(fun([Offset, Length]) ->
        Label = field_label(Scope, Prefix ++ [padding]),
        ensure(zero(slice(Bytes, Base + Offset, Length, Label)),
               reserved, Label, Base + Offset)
    end, maps:get(padding, Layout)),
    lists:foreach(fun(Field) ->
        FieldName = maps:get(name, Field),
        Fields = Prefix ++ [FieldName],
        FieldValue = maps:get(FieldName, Value),
        Offset = Base + maps:get(offset, Field),
        TypeName = maps:get(type, Field),
        FieldType = type(TypeName, Types),
        case {maps:get(kind, FieldType), maps:get(count, Field)} of
            {layout, scalar} ->
                check_layout(TypeName, FieldValue, Bytes, Offset, Scope,
                             Fields, Record, Header, Spec);
            _ ->
                case active(maps:get(rules, Spec), Scope, Fields, Record, Header) of
                    false -> ok;
                    true ->
                        Label = field_label(Scope, Fields),
                        check_field(Field, FieldValue, Label, Offset,
                                    maps:get(source_role, Spec), Types)
                end
        end
    end, maps:get(fields, Layout)).

check_field(#{count := scalar} = Field, Value, Label, Offset, Role, Types) ->
    check_leaf(Field, Value, Label, Offset, Role, Types);
check_field(Field, Values, Label, Offset, Role, Types) when is_binary(Values) ->
    check_array(Field, binary_to_list(Values), Label, Offset, Role, Types);
check_field(Field, Values, Label, Offset, Role, Types) ->
    check_array(Field, Values, Label, Offset, Role, Types).

check_array(_Field, [], _Label, _Offset, _Role, _Types) -> ok;
check_array(Field, [Value | Rest], Label, Offset, Role, Types) ->
    check_leaf(Field, Value, Label, Offset, Role, Types),
    check_array(Field, Rest, Label,
                Offset + maps:get(size, type(maps:get(type, Field), Types)), Role, Types).

check_leaf(Field, Value, Label, Offset, Role, Types) ->
    Type = type(maps:get(type, Field), Types),
    case maps:get(kind, Type) of
        bytes ->
            case maps:get(fixed, Type) of
                none -> ok;
                Fixed -> ensure(Value =:= Fixed, value, Label, Offset)
            end,
            ensure(maps:get(zero, Field) =:= 0 orelse zero(Value),
                   reserved, Label, Offset);
        _ ->
            check_integer_type(Type, Value, Label, Offset),
            WidthMask = (1 bsl (maps:get(size, Type) * 8)) - 1,
            Unsigned = Value band WidthMask,
            ensure((Unsigned band maps:get(zero, Field)) =:= 0,
                   reserved, Label, Offset),
            case maps:find(Role, maps:get(input_masks, Field)) of
                {ok, Mask} ->
                    ensure((Unsigned band bnot Mask) =:= 0,
                           ownership, Label, Offset);
                error -> ok
            end
    end.

check_integer_type(#{kind := integer}, _Value, _Label, _Offset) -> ok;
check_integer_type(#{kind := scalar} = Type, Value, Label, Offset) ->
    ensure(Value >= maps:get(minimum, Type) andalso
           Value =< maps:get(maximum, Type) andalso
           Value rem maps:get(multiple, Type) =:= 0,
           range, Label, Offset);
check_integer_type(#{kind := enum} = Type, Value, Label, Offset) ->
    Valid = case maps:get(allowed, Type) of
        none ->
            case maps:get(flags, Type) of
                true -> (Value band bnot maps:get(mask, Type)) =:= 0;
                false -> lists:member(Value, maps:get(values, Type))
            end;
        Allowed -> lists:member(Value, Allowed)
    end,
    Reason = case maps:get(flags, Type) of true -> flags; false -> tag end,
    ensure(Valid, Reason, Label, Offset).

active(Rules, Scope, Fields, Record, Header) ->
    lists:all(fun(Rule) ->
        case maps:get(kind, Rule) of
            optional ->
                Path = maps:get(path, Rule),
                Applies = maps:get(scope, Path) =:= Scope andalso
                          lists:prefix(maps:get(fields, Path), Fields),
                not Applies orelse
                    (path_value(maps:get(flags, Rule), Record, Header)
                     band maps:get(mask, Rule)) =/= 0;
            choice ->
                Tag = maps:get(tag, Rule),
                Candidates = [Path || Path <- maps:get(fields, Rule),
                    lists:prefix(maps:get(fields, Path), Fields)],
                case {maps:get(scope, Tag) =:= Scope, Candidates} of
                    {true, [Selected]} ->
                        Value = path_value(Tag, Record, Header),
                        Active = maps:get(Value, maps:get(cases, Rule), []),
                        lists:member(Selected, Active);
                    _ -> true
                end;
            _ -> true
        end
    end, Rules).

rule_path(#{path := Path}) -> Path;
rule_path(#{offset := Path}) -> Path;
rule_path(#{tag := Path}) -> Path.

rule_enabled(#{guard := #{tag := Tag, value := Expected}}, Record, Header) ->
    path_value(Tag, Record, Header) =:= Expected;
rule_enabled(_Rule, _Record, _Header) -> true.

path_value(#{scope := root, fields := Fields}, _Record, Header) ->
    field_value(Fields, Header);
path_value(#{fields := Fields}, Record, _Header) ->
    field_value(Fields, Record).

field_value([], Value) -> Value;
field_value([Field | Rest], Value) ->
    field_value(Rest, maps:get(Field, Value)).

field_label(Scope, Fields) ->
    Prefix = case Scope of
        root -> <<"root">>;
        _ -> <<(atom_to_binary(Scope, utf8))/binary, "[]">>
    end,
    iolist_to_binary([Prefix | [[<<".">>, atom_to_binary(Field, utf8)]
                               || Field <- Fields]]).

check_rule(#{kind := value, path := Path, values := [Expected]},
           Record, Header, _Bytes, Base, _Spec) ->
    ensure(path_value(Path, Record, Header) =:= Expected,
           value, maps:get(label, Path), Base + maps:get(offset, Path));
check_rule(#{kind := range, path := Path, values := [Minimum, Maximum]},
           Record, Header, _Bytes, Base, _Spec) ->
    Value = path_value(Path, Record, Header),
    ensure(Value >= Minimum andalso Value =< Maximum,
           range, maps:get(label, Path), Base + maps:get(offset, Path));
check_rule(#{kind := index, path := Path, table := Name, absent := Absent},
           Record, Header, _Bytes, Base, Spec) ->
    Value = path_value(Path, Record, Header),
    Table = record_table(Name, Spec),
    Count = path_value(maps:get(count, Table), Header, Header),
    ensure(Value < Count orelse Value =:= Absent,
           index, maps:get(label, Path), Base + maps:get(offset, Path));
check_rule(#{kind := Kind} = Rule, Record, Header, _Bytes, Base, Spec)
  when Kind =:= slice; Kind =:= partition ->
    {_First, _Count} = span_rows(Rule, Record, Header, Base, Spec),
    ok;
check_rule(#{kind := string} = Rule, Record, Header, Bytes, Base, Spec) ->
    check_string(Rule, Record, Header, Bytes, Base, Spec);
check_rule(#{kind := optional, path := Path, flags := Flags, mask := Mask},
           Record, Header, Bytes, Base, _Spec) ->
    Present = (path_value(Flags, Record, Header) band Mask) =/= 0,
    Offset = Base + maps:get(offset, Path),
    ensure(Present orelse zero(slice(Bytes, Offset, maps:get(size, Path),
                                     maps:get(label, Path))),
           inactive, maps:get(label, Path), Offset);
check_rule(#{kind := choice, tag := Tag, cases := Cases, fields := Fields},
           Record, Header, Bytes, Base, _Spec) ->
    Value = path_value(Tag, Record, Header),
    case maps:find(Value, Cases) of
        error ->
            fail(tag, maps:get(label, Tag), Base + maps:get(offset, Tag));
        {ok, Active} ->
            lists:foreach(fun(Path) ->
                Offset = Base + maps:get(offset, Path),
                ensure(lists:member(Path, Active) orelse
                       zero(slice(Bytes, Offset, maps:get(size, Path),
                                  maps:get(label, Path))),
                       inactive, maps:get(label, Path), Offset)
            end, Fields)
    end.

check_string(Rule, Record, Header, Bytes, Base, Spec) ->
    Path = maps:get(offset, Rule),
    Offset = path_value(Path, Record, Header),
    Length = path_value(maps:get(count, Rule), Record, Header),
    Table = string_table(maps:get(table, Rule), Spec),
    Total = path_value(maps:get(count, Table), Header, Header),
    Label = maps:get(label, Path),
    Location = Base + maps:get(offset, Path),
    ensure(Offset =< Total andalso Length =< Total - Offset andalso
           Length =< maps:get(maximum, Rule) andalso
           (maps:get(empty, Rule) orelse Length > 0),
           string_range, Label, Location),
    case Length =:= 0 andalso maps:get(empty, Rule) of
        true -> ok;
        false ->
            Start = path_value(maps:get(offset, Table), Header, Header),
            Text = slice(Bytes, Start + Offset, Length, Label),
            ensure(valid_string(maps:get(class, Rule), Text),
                   string_class, Label, Location)
    end.

zero(<<>>) -> true;
zero(<<0, Rest/binary>>) -> zero(Rest);
zero(_) -> false.

valid_string(bytes, _Bytes) -> true;
valid_string(identifier, Bytes) ->
    byte_size(Bytes) >= 1 andalso byte_size(Bytes) =< 63 andalso
        identifier(Bytes, first);
valid_string(utf8, Bytes) -> valid_utf8(Bytes, true);
valid_string(dt_path, Bytes) -> valid_path(Bytes, true);
valid_string(namespace_path, Bytes) -> valid_path(Bytes, false);
valid_string(relative_path, Bytes) ->
    Bytes =/= <<>> andalso valid_path(<<$/, Bytes/binary>>, true);
valid_string(args, <<>>) -> true;
valid_string(args, Bytes) -> binary:last(Bytes) =:= 0;
valid_string(env, Bytes) -> environment(Bytes, #{}).

identifier(<<>>, _Position) -> true;
identifier(<<Byte, Rest/binary>>, Position) ->
    AlphaNumeric = (Byte >= $a andalso Byte =< $z) orelse
                   (Byte >= $0 andalso Byte =< $9),
    Valid = AlphaNumeric orelse (Position =:= rest andalso
             (Byte =:= $_ orelse Byte =:= $-)),
    Valid andalso identifier(Rest, rest).

valid_utf8(<<>>, _Clean) -> true;
valid_utf8(<<Point/utf8, Rest/binary>>, Clean) ->
    Safe = not Clean orelse
           (Point >= 16#20 andalso not (Point >= 16#7f andalso Point =< 16#9f)),
    Safe andalso valid_utf8(Rest, Clean);
valid_utf8(_, _) -> false.

valid_path(<<$/, Rest/binary>> = Bytes, Clean) ->
    valid_utf8(Bytes, Clean) andalso
        (Rest =:= <<>> orelse path_component(Rest, 0, true));
valid_path(_, _) -> false.

path_component(<<>>, Length, Dots) ->
    Length > 0 andalso not (Dots andalso Length =< 2);
path_component(<<0, _/binary>>, _Length, _Dots) -> false;
path_component(<<$/, Rest/binary>>, Length, Dots) ->
    Length > 0 andalso not (Dots andalso Length =< 2) andalso
        path_component(Rest, 0, true);
path_component(<<Byte, Rest/binary>>, Length, Dots) ->
    path_component(Rest, Length + 1, Dots andalso Byte =:= $.).

environment(<<>>, _Seen) -> true;
environment(Bytes, Seen) ->
    case binary:match(Bytes, <<0>>) of
        nomatch -> false;
        {End, 1} ->
            Entry = binary:part(Bytes, 0, End),
            case binary:match(Entry, <<$=>>) of
                {At, 1} when At > 0 ->
                    Key = binary:part(Entry, 0, At),
                    not maps:is_key(Key, Seen) andalso
                        environment(binary:part(Bytes, End + 1,
                                               byte_size(Bytes) - End - 1),
                                    maps:put(Key, true, Seen));
                _ -> false
            end
    end.
