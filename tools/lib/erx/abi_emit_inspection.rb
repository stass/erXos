# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_inspection'

module Erx
  module ABI
    # Emits the inspection schema's bindings: erx_schema, the Erlang module of
    # kinds, attributes, stopgap reporters, value types and paths with their
    # validators and resolvers, and the host tool's Ruby table of the same
    # declarations. Every atom of erx_schema comes from the checked schema,
    # so a reader of a record or a path refuses an unknown name without
    # making an atom. C builders for erXos's kernel are not emitted here:
    # their consumer is that kernel.
    module InspectionEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_schema.erl'
      RUBY_PATH = 'tools/generated/abi_inspection.rb'
      ERLANG_RESERVED = %w[after and andalso band begin bnot bor bsl bsr bxor case catch cond
                           div else end fun if let maybe not of or orelse receive rem try when
                           xor].freeze

      # The validators, resolvers and path-text decoder are the same for every
      # schema; only the data clauses above them are generated.
      ERLANG_CODE = <<~'ERLANG'
        %% The attribute Reporter reports: Value checked against its type, every
        %% status and the reporter kept. The collector of a source passes the
        %% reporter it assigns, so a report never names its own. A reporter the
        %% attribute does not list is refused; a value outside its type, an error
        %% whose reason is not an atom and a timeout beyond 32 bits of
        %% milliseconds become {error, invalid}.
        -spec validate_attr(atom(), atom(), reporter(), term()) ->
                  {ok, attr()} | {error, unknown_attribute | reporter}.
        validate_attr(Kind, Key, Reporter, Value) ->
            case attribute(Kind, Key) of
                {ok, #{reporters := Reporters, type := Type}} ->
                    case lists:member(Reporter, Reporters) of
                        true -> {ok, {Reporter, checked(Type, Value)}};
                        false -> {error, reporter}
                    end;
                error ->
                    {error, unknown_attribute}
            end.

        checked(Type, {ok, Term} = Value) -> keep_if(valid(Type, Term), Value);
        checked(Type, {partial, Term} = Value) -> keep_if(valid(Type, Term), Value);
        checked(_Type, unknown) -> unknown;
        checked(_Type, unsupported) -> unsupported;
        checked(_Type, {timeout, Milliseconds} = Value)
          when is_integer(Milliseconds), Milliseconds > 0, Milliseconds =< ?U32 -> Value;
        checked(_Type, {error, Reason} = Value) when is_atom(Reason) -> Value;
        checked(_Type, _Value) -> {error, invalid}.

        keep_if(true, Value) -> Value;
        keep_if(false, _Value) -> {error, invalid}.

        %% A whole record: its path resolves to a declaration of its kind, each
        %% attribute passes validate_attr/4 under the reporter the record gives
        %% it, which the inspector assigned, each child is a distinct segment
        %% the declaration admits, and its entries, where it has them, pass
        %% valid_entries/2. The first refusal is the answer.
        -spec validate_record(term()) -> {ok, record()} | {error, atom()}.
        validate_record(#{schema := Schema, path := Path, kind := Kind, id := _Id,
                          attrs := Attrs, children := Children} = Record)
          when is_map(Attrs), map_size(Record) =:= 6 orelse
                              (map_size(Record) =:= 7 andalso is_map_key(entries, Record)) ->
            case {Schema =:= schema(), resolve(Path)} of
                {false, _} ->
                    {error, schema};
                {true, {ok, #{kind := Kind} = Declaration}} ->
                    case validate_attrs(Kind, maps:to_list(Attrs), #{}) of
                        {ok, Checked} ->
                            case {valid_children(Declaration, Children),
                                  valid_entries(Declaration, maps:get(entries, Record, none))} of
                                {true, true} -> {ok, Record#{attrs := Checked}};
                                {false, _} -> {error, children};
                                {true, false} -> {error, entries}
                            end;
                        {error, _Reason} = Error ->
                            Error
                    end;
                {true, {ok, _Declaration}} ->
                    {error, kind};
                {true, {error, _Reason} = Error} ->
                    Error
            end;
        validate_record(_Record) ->
            {error, malformed}.

        validate_attrs(_Kind, [], Checked) ->
            {ok, Checked};
        validate_attrs(Kind, [{Key, {Reporter, Value}} | Rest], Checked) ->
            case validate_attr(Kind, Key, Reporter, Value) of
                {ok, Valid} -> validate_attrs(Kind, Rest, Checked#{Key => Valid});
                {error, _Reason} = Error -> Error
            end;
        validate_attrs(_Kind, _Attrs, _Checked) ->
            {error, malformed}.

        valid_children(_Declaration, unknown) -> true;
        valid_children(Declaration, {partial, Segments}) -> distinct_children(Declaration, Segments);
        valid_children(Declaration, Segments) -> distinct_children(Declaration, Segments).

        %% The walk is bounded first, so the count of distinct children runs only
        %% over a proper list of at most a page.
        distinct_children(Declaration, Segments) ->
            valid_children(Declaration, Segments, ?PAGE)
                andalso length(lists:usort(Segments)) =:= length(Segments).

        valid_children(_Declaration, [], _Room) ->
            true;
        valid_children(#{children := Children} = Declaration, [Segment | Rest], Room) when Room > 0 ->
            valid_child(Children, Segment) andalso valid_children(Declaration, Rest, Room - 1);
        valid_children(_Declaration, _Segments, _Room) ->
            false.

        valid_child({literals, Literals}, Segment) -> is_atom(Segment) andalso lists:member(Segment, Literals);
        valid_child({variable, Type}, Segment) -> valid_segment(Type, Segment).

        %% A record's entries, which only a path the schema marks with entries
        %% may carry: {ok | partial, Next, [{Sequence, Value}]}, at most a page
        %% of values of the path's entry type, each with its sequence number,
        %% the numbers increasing and each below Next, the number a query
        %% continues from; partial when entries remain from Next on. A number
        %% the entries skip names an entry the query did not get.
        valid_entries(_Declaration, none) ->
            true;
        valid_entries(#{entries := {Type, Maximum}}, {Status, Next, Items})
          when Status =:= ok orelse Status =:= partial, is_integer(Next), Next >= 0, Next =< ?U64 ->
            valid_entries(Type, Items, -1, Next, min(Maximum, ?PAGE));
        valid_entries(_Declaration, _Entries) ->
            false.

        valid_entries(_Type, [], _Previous, _Next, _Room) ->
            true;
        valid_entries(Type, [{Sequence, Value} | Rest], Previous, Next, Room)
          when is_integer(Sequence), Sequence > Previous, Sequence < Next, Room > 0 ->
            valid(Type, Value) andalso valid_entries(Type, Rest, Sequence, Next, Room - 1);
        valid_entries(_Type, _Items, _Previous, _Next, _Room) ->
            false.

        %% Whether Value is of the type a descriptor describes. Descriptors come
        %% from this module's own clauses; anything else is not a type.
        -spec valid(descriptor(), term()) -> boolean().
        valid({type, Name}, Value) ->
            case type(Name) of
                {ok, Descriptor} -> valid(Descriptor, Value);
                error -> false
            end;
        valid({integer, Minimum, Maximum, Multiple}, Value) when is_integer(Multiple), Multiple > 0 ->
            is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum
                andalso Value rem Multiple =:= 0;
        valid({text, Maximum, bytes}, Value) when is_integer(Maximum) ->
            is_binary(Value) andalso byte_size(Value) =< Maximum;
        valid({text, Maximum, utf8}, Value) when is_integer(Maximum) ->
            is_binary(Value) andalso byte_size(Value) =< Maximum andalso utf8(Value);
        valid({atoms, Atoms}, Value) when is_list(Atoms) ->
            is_atom(Value) andalso lists:member(Value, Atoms);
        valid({flags, Names}, Value) when is_list(Names) ->
            flag_set(Value, Names, []);
        valid({list, Element, Maximum}, Value) ->
            bounded_list(Value, Element, Maximum);
        valid({tuple, Elements}, Value) when is_list(Elements) ->
            is_tuple(Value) andalso tuple_size(Value) =:= length(Elements)
                andalso lists:all(fun({Element, Item}) -> valid(Element, Item) end,
                                  lists:zip(Elements, tuple_to_list(Value)));
        valid(boolean, Value) ->
            is_boolean(Value);
        valid(pid, Value) ->
            is_pid(Value);
        valid(_Descriptor, _Value) ->
            false.

        %% Erlang's UTF-8 matching refuses overlong forms, surrogates and code
        %% points above U+10FFFF.
        utf8(<<>>) -> true;
        utf8(<<_Character/utf8, Rest/binary>>) -> utf8(Rest);
        utf8(_Bytes) -> false.

        %% A set of bit names: a proper list of distinct declared names.
        flag_set([], _Names, _Seen) ->
            true;
        flag_set([Name | Rest], Names, Seen) when is_atom(Name) ->
            lists:member(Name, Names) andalso not lists:member(Name, Seen)
                andalso flag_set(Rest, Names, [Name | Seen]);
        flag_set(_Value, _Names, _Seen) ->
            false.

        %% A proper list of at most Room values, walked no further than Room.
        bounded_list([], _Element, _Room) ->
            true;
        bounded_list([Item | Rest], Element, Room) when is_integer(Room), Room > 0 ->
            valid(Element, Item) andalso bounded_list(Rest, Element, Room - 1);
        bounded_list(_Value, _Element, _Room) ->
            false.

        %% The one declaration a path term names. Siblings are all literal or one
        %% variable, so at most one declaration matches.
        -spec resolve(term()) -> {ok, declaration()} | {error, unknown_path}.
        resolve(Path) ->
            resolve(Path, declarations()).

        resolve(Path, [#{pattern := Pattern} = Declaration | Rest]) ->
            case matches(Pattern, Path) of
                true -> {ok, Declaration};
                false -> resolve(Path, Rest)
            end;
        resolve(_Path, []) ->
            {error, unknown_path}.

        matches([], []) -> true;
        matches([{variable, Type} | Pattern], [Segment | Path]) -> valid_segment(Type, Segment) andalso matches(Pattern, Path);
        matches([Literal | Pattern], [Segment | Path]) when is_atom(Literal) -> Literal =:= Segment andalso matches(Pattern, Path);
        matches(_Pattern, _Path) -> false.

        %% A variable segment: a value of its type, and never the empty text, which
        %% a path's text cannot hold, so a path term and its text agree.
        valid_segment(_Type, <<>>) -> false;
        valid_segment(Type, Segment) -> valid(Type, Segment).

        %% A path as /proc and the host write it: segments separated by "/", with
        %% an optional leading "/"; a pid as D.N.S; a text segment in /proc's
        %% injective name encoding, every byte outside A-Z, a-z, 0-9 and _+,:=@-
        %% written as % and two upper-case hexadecimal digits. Only the canonical
        %% spelling of a path is accepted, so each path has one spelling up to the
        %% leading "/". The text is untrusted: it is bounded before it is split,
        %% and no atom is made.
        -spec resolve_text(term()) -> {ok, [segment()], declaration()} | {error, bad_path | unknown_path}.
        resolve_text(Text) when is_binary(Text), byte_size(Text) =< ?MAX_PATH_TEXT ->
            case split(Text) of
                {ok, Parts} -> resolve_parts(Parts, declarations());
                error -> {error, bad_path}
            end;
        resolve_text(_Text) ->
            {error, bad_path}.

        split(<<>>) -> {ok, []};
        split(<<"/">>) -> {ok, []};
        split(<<"/", Rest/binary>>) -> parts(Rest);
        split(Text) -> parts(Text).

        parts(Text) ->
            Parts = binary:split(Text, <<"/">>, [global]),
            case length(Parts) =< ?MAX_SEGMENTS andalso not lists:member(<<>>, Parts) of
                true -> {ok, Parts};
                false -> error
            end.

        resolve_parts(Parts, [#{pattern := Pattern} = Declaration | Rest]) ->
            case decode(Pattern, Parts, []) of
                {ok, Path} -> {ok, Path, Declaration};
                error -> resolve_parts(Parts, Rest)
            end;
        resolve_parts(_Parts, []) ->
            {error, unknown_path}.

        decode([], [], Path) ->
            {ok, lists:reverse(Path)};
        decode([{variable, Type} | Pattern], [Part | Parts], Path) ->
            case segment(Type, Part) of
                {ok, Segment} -> decode(Pattern, Parts, [Segment | Path]);
                error -> error
            end;
        decode([Literal | Pattern], [Part | Parts], Path) when is_atom(Literal) ->
            case atom_to_binary(Literal) =:= Part of
                true -> decode(Pattern, Parts, [Literal | Path]);
                false -> error
            end;
        decode(_Pattern, _Parts, _Path) ->
            error.

        segment({type, Name}, Part) ->
            case type(Name) of
                {ok, Descriptor} -> segment(Descriptor, Part);
                error -> error
            end;
        segment({integer, _Minimum, _Maximum, _Multiple} = Type, Part) ->
            typed(Type, decimal(Part));
        segment({text, _Maximum, _Encoding} = Type, Part) ->
            typed(Type, unescape(Part, <<>>));
        segment(pid, Part) ->
            pid_text(Part);
        segment(_Type, _Part) ->
            error.

        typed(Type, {ok, Value}) ->
            case valid_segment(Type, Value) of
                true -> {ok, Value};
                false -> error
            end;
        typed(_Type, error) ->
            error.

        %% A canonical decimal: no sign but a minus, no leading zero, and at most
        %% 20 digits, checked before the conversion.
        decimal(<<"0">>) ->
            {ok, 0};
        decimal(<<"-", Digits/binary>>) ->
            case magnitude(Digits) of
                {ok, Magnitude} -> {ok, -Magnitude};
                error -> error
            end;
        decimal(Digits) ->
            magnitude(Digits).

        magnitude(<<First, _/binary>> = Digits) when First >= $1, First =< $9, byte_size(Digits) =< 20 ->
            case lists:all(fun(Digit) -> Digit >= $0 andalso Digit =< $9 end, binary_to_list(Digits)) of
                true -> {ok, binary_to_integer(Digits)};
                false -> error
            end;
        magnitude(_Digits) ->
            error.

        unescape(<<>>, Name) ->
            {ok, Name};
        unescape(<<$%, High, Low, Rest/binary>>, Name) ->
            case {hex(High), hex(Low)} of
                {{ok, H}, {ok, L}} ->
                    Byte = H * 16 + L,
                    case plain(Byte) of
                        false -> unescape(Rest, <<Name/binary, Byte>>);
                        true -> error
                    end;
                _ ->
                    error
            end;
        unescape(<<Byte, Rest/binary>>, Name) ->
            case plain(Byte) of
                true -> unescape(Rest, <<Name/binary, Byte>>);
                false -> error
            end.

        hex(Digit) when Digit >= $0, Digit =< $9 -> {ok, Digit - $0};
        hex(Digit) when Digit >= $A, Digit =< $F -> {ok, Digit - $A + 10};
        hex(_Digit) -> error.

        plain(Byte) when Byte >= $A, Byte =< $Z -> true;
        plain(Byte) when Byte >= $a, Byte =< $z -> true;
        plain(Byte) when Byte >= $0, Byte =< $9 -> true;
        plain(Byte) -> lists:member(Byte, "_+,:=@-").

        %% D.N.S, each a canonical decimal of at most 32 bits, made a pid by the
        %% runtime's own list_to_pid/1, which refuses one it cannot name: on erXos
        %% a pid of a domain this runtime is not connected to. The inspector answers
        %% such an unknown path as it answers a path outside the caller's scope. The
        %% pid is kept only when the runtime writes it back as the same text, since
        %% stock OTP on a node that is not distributed takes any D as its own node,
        %% which would give a pid a second spelling.
        pid_text(Part) ->
            case [decimal(Number) || Number <- binary:split(Part, <<".">>, [global])] of
                [{ok, D}, {ok, N}, {ok, S}] when D >= 0, D =< ?U32, N >= 0, N =< ?U32, S >= 0, S =< ?U32 ->
                    Text = "<" ++ integer_to_list(D) ++ "." ++ integer_to_list(N) ++ "."
                        ++ integer_to_list(S) ++ ">",
                    try list_to_pid(Text) of
                        Pid ->
                            case pid_to_list(Pid) =:= Text of
                                true -> {ok, Pid};
                                false -> error
                            end
                    catch error:badarg -> error
                    end;
                _ ->
                    error
            end.

        %% The text of one path segment, the spelling resolve_text/1 reads back as
        %% it: a literal as itself, an integer in decimal, a pid as D.N.S and a
        %% text with every byte that plain/1 refuses written as %XX.
        -spec segment_text(segment()) -> binary().
        segment_text(Segment) when is_atom(Segment) ->
            atom_to_binary(Segment);
        segment_text(Segment) when is_integer(Segment) ->
            integer_to_binary(Segment);
        segment_text(Segment) when is_pid(Segment) ->
            %% "<D.N.S>" without its brackets, so a shell needs no quoting.
            Text = list_to_binary(pid_to_list(Segment)),
            binary:part(Text, 1, byte_size(Text) - 2);
        segment_text(Segment) when is_binary(Segment) ->
            << <<(escaped(Byte))/binary>> || <<Byte>> <= Segment >>.

        escaped(Byte) ->
            case plain(Byte) of
                true -> <<Byte>>;
                false -> <<$%, (hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
            end.

        hex_digit(Digit) when Digit < 10 -> $0 + Digit;
        hex_digit(Digit) -> $A + Digit - 10.

        %% The attributes of Kind that the rendering Projection shows in a Build
        %% (release or development), in field order.
        -spec fields(atom(), atom(), release | development) -> {ok, [atom()]} | error.
        fields(Kind, Projection, Build) when Build =:= release; Build =:= development ->
            case attributes(Kind) of
                {ok, Keys} -> {ok, [Key || Key <- Keys, shown(Kind, Key, Projection, Build)]};
                error -> error
            end;
        fields(_Kind, _Projection, _Build) ->
            error.

        shown(Kind, Key, Projection, Build) ->
            {ok, #{projections := Projections, build := Built}} = attribute(Kind, Key),
            lists:member(Projection, Projections) andalso (Built =:= all orelse Build =:= development).
      ERLANG

      module_function

      def outputs(schema)
        inspection = schema.inspection || raise(SchemaError, 'the ABI root includes no inspection schema')
        { ERLANG_PATH => erlang(inspection, schema), RUBY_PATH => ruby(inspection) }.freeze
      end

      def erlang(inspection, schema)
        kinds = inspection.kinds.keys + ['listing']
        [erlang_head(inspection, kinds), erlang_data(inspection, kinds), report_functions(inspection, schema.types),
         status_function(schema.constants),
         ERLANG_CODE].join("\n")
      end

      def erlang_head(inspection, kinds)
        reporters = Inspection::CATEGORIES + inspection.stopgaps.keys.map { |name| "{stopgap, #{atom(name)}}" }
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from abi/inspection.txt.
          %% Do not edit this file.

          -module(erx_schema).
          -moduledoc "The inspection schema: kinds, attributes, reporters, types and paths, with their validators.".
          -export([schema/0, kinds/0, attributes/1, attribute/2, fields/3, stopgaps/0, stopgap/1,
                   trace_rows/0, trace_row/1,
                   reporter_label/1, unit_label/1, type/1, declarations/0, valid/2, validate_attr/4,
                   validate_record/1, resolve/1, resolve_text/1, segment_text/1, report_layout/1, decode_report/2,
                   status_name/1]).
          -export_type([record/0, attr/0, reporter/0, value/0, segment/0, descriptor/0, declaration/0]).
          %% record() is the inspection record's name in docs/design-live.md.
          -compile({nowarn_redefined_builtin_type, [{record, 0}]}).

          -define(PAGE, #{Inspection::MAX_LIST}).
          -define(MAX_SEGMENTS, #{Inspection::MAX_SEGMENTS}).
          %% Sixteen segments of the longest text, each byte encoded as three.
          -define(MAX_PATH_TEXT, #{Inspection::MAX_SEGMENTS * (Inspection::MAX_SEGMENT_TEXT * 3 + 1)}).
          -define(U32, 16#ffffffff).
          -define(U64, 16#ffffffffffffffff).

          -type kind() :: #{union(kinds.map { |name| atom(name) })}.
          -type reporter() :: #{union(reporters)}.
          -type value() :: {ok, term()} | {partial, term()} | unknown | unsupported
                         | {timeout, pos_integer()} | {error, term()}.
          -type attr() :: {reporter(), value()}.
          -type segment() :: atom() | integer() | binary() | pid().
          -type record() :: \#{schema := #{inspection.version}, path := [segment()], kind := kind(), id := term(),
                              attrs := \#{atom() => attr()},
                              children := [segment()] | {partial, [segment()]} | unknown,
                              entries => {ok | partial, non_neg_integer(), [{non_neg_integer(), term()}]}}.
          -type class() :: #{union(Inspection::VISIBILITY.map { |name| atom(name) })}.
          -type descriptor() :: {type, atom()} | {integer, integer(), integer(), pos_integer()}
                              | {text, pos_integer(), bytes | utf8} | {atoms, [atom()]} | {flags, [atom()]}
                              | {list, descriptor(), pos_integer()} | {tuple, [descriptor()]} | boolean | pid.
          -type declaration() :: \#{kind := kind(), pattern := [atom() | {variable, descriptor()}],
                                   visible := [class()], entries := none | {descriptor(), pos_integer()},
                                   append_only := boolean(),
                                   children := {literals, [atom()]} | {variable, descriptor()}}.
        ERLANG
      end

      def union(items)
        items.join(' | ')
      end

      def erlang_data(inspection, kinds)
        sections = [
          "schema() -> #{inspection.version}.",
          "kinds() ->\n    #{list(kinds.map { |name| atom(name) }, 4)}.",
          attributes_function(inspection),
          attribute_function(inspection),
          stopgap_functions(inspection),
          trace_row_functions(inspection),
          label_functions(inspection),
          type_function(inspection),
          declarations_function(inspection)
        ]
        sections.join("\n\n") + "\n"
      end

      def attributes_function(inspection)
        clauses = inspection.kinds.map do |kind, attrs|
          "attributes(#{atom(kind)}) ->\n    {ok, #{list(attrs.map { |attr| atom(attr.key) }, 9)}}"
        end
        clauses << "attributes(listing) ->\n    {ok, []}" << "attributes(_Kind) ->\n    error"
        "%% A kind's attribute keys in field order.\n" + clauses.join(";\n") + '.'
      end

      def attribute_function(inspection)
        clauses = inspection.kinds.flat_map do |kind, attrs|
          attrs.map do |attr|
            fields = {
              'type' => descriptor(inspection, attr.type),
              'unit' => unit_of(inspection, attr.type),
              'reporters' => list(attr.reporters.map { |name| reporter(inspection, name) }, 24),
              'visible' => atom(attr.visible),
              'build' => atom(attr.build),
              'projections' => list(attr.projections.map { |name| atom(name) }, 26),
              'derived' => list(attr.derived.map { |name| atom(name) }, 22)
            }
            "attribute(#{atom(kind)}, #{atom(attr.key)}) ->\n    {ok, #{map(fields, 9)}}"
          end
        end
        clauses << "attribute(_Kind, _Key) ->\n    error"
        "%% An attribute's declaration: type, unit label, reporters, visibility,\n" \
          "%% build, projections and the inputs it is derived from.\n" + clauses.join(";\n") + '.'
      end

      def stopgap_functions(inspection)
        names = "stopgaps() ->\n    #{list(inspection.stopgaps.keys.map { |name| atom(name) }, 4)}."
        clauses = inspection.stopgaps.values.map do |stopgap|
          fields = { 'category' => atom(stopgap.category), 'label' => binary(stopgap.label),
                     'scope' => binary(stopgap.scope) }
          "stopgap(#{atom(stopgap.name)}) ->\n    {ok, #{map(fields, 9)}}"
        end
        clauses << "stopgap(_Name) ->\n    error"
        "%% The stopgap reporters, each with the category it stands in for, its\n" \
          "%% label and the scope of what it sees.\n#{names}\n\n" + clauses.join(";\n") + '.'
      end

      def trace_row_functions(inspection)
        names = "trace_rows() ->\n    #{list(inspection.trace_rows.keys.map { |name| atom(name) }, 4)}."
        clauses = inspection.trace_rows.values.map do |row|
          "trace_row(#{atom(row.name)}) ->\n    {ok, #{reporter(inspection, row.reporter)}}"
        end
        clauses << "trace_row(_Row) ->\n    error"
        "%% The trace rows of docs/design-live.md, \"Tracing\", each with the reporter\n" \
          "%% its collector assigns to its events.\n#{names}\n\n" + clauses.join(";\n") + '.'
      end

      def label_functions(inspection)
        reporters = Inspection::CATEGORIES.map { |name| "reporter_label(#{name}) -> {ok, #{binary(name)}}" } +
                    inspection.stopgaps.values.map do |stopgap|
                      "reporter_label({stopgap, #{atom(stopgap.name)}}) -> {ok, #{binary(stopgap.label)}}"
                    end
        reporters << 'reporter_label(_Reporter) -> error'
        units = inspection.units.map { |name, label| "unit_label(#{atom(name)}) -> {ok, #{binary(label)}}" }
        units << 'unit_label(_Unit) -> error'
        "%% The name a renderer prints for a reporter.\n" + reporters.join(";\n") + ".\n\n" \
          "%% The label a renderer prints after a value of a unit.\n" + units.join(";\n") + '.'
      end

      def type_function(inspection)
        clauses = inspection.member_types.map do |name|
          "type(#{atom(name)}) -> {ok, #{member_descriptor(inspection, inspection.types.fetch(name))}}"
        end
        clauses << 'type(_Name) -> error'
        "%% The schema's value types.\n" + clauses.join(";\n") + '.'
      end

      def declarations_function(inspection)
        entries = inspection.paths.map do |path|
          pattern = path.segments.map do |segment|
            segment.variable? ? "{variable, #{descriptor(inspection, segment.type)}}" : atom(segment.literal)
          end
          children = if path.variable_child
                       "{variable, #{descriptor(inspection, path.variable_child)}}"
                     else
                       "{literals, #{list(path.literal_children.map { |name| atom(name) }, 30)}}"
                     end
          entries = path.entries ? "{#{descriptor(inspection, path.entries.first)}, #{path.entries.last}}" : 'none'
          map({ 'kind' => atom(path.kind), 'pattern' => list(pattern, 18),
                'visible' => list(path.visibility.map { |name| atom(name) }, 18), 'entries' => entries,
                'append_only' => path.append_only.to_s, 'children' => children }, 5)
        end
        "%% The declared paths, in declaration order.\ndeclarations() ->\n    [" +
          entries.join(",\n     ") + '].'
      end

      # A member type by name; a built-in or a root type inline.
      def descriptor(inspection, reference)
        type = inspection.types.fetch(reference)
        type.member ? "{type, #{atom(reference)}}" : inline_descriptor(type)
      end

      def member_descriptor(inspection, type)
        case type.form
        when 'text' then "{text, #{type.maximum}, #{type.utf8 ? 'utf8' : 'bytes'}}"
        when 'list' then "{list, #{descriptor(inspection, type.element)}, #{type.maximum}}"
        when 'tuple' then "{tuple, #{list(type.elements.map { |item| descriptor(inspection, item) }, 31)}}"
        else inline_descriptor(type)
        end
      end

      def inline_descriptor(type)
        case type.form
        when 'integer' then "{integer, #{type.minimum}, #{type.maximum}, #{type.multiple}}"
        when 'atoms', 'flags' then "{#{type.form}, #{list(type.atoms.map { |name| atom(name) }, 18)}}"
        else type.form
        end
      end

      def unit_of(inspection, reference)
        unit = inspection.types.fetch(reference).unit
        unit ? binary(inspection.units.fetch(unit)) : 'none'
      end

      def reporter(inspection, name)
        inspection.stopgaps.key?(name) ? "{stopgap, #{atom(name)}}" : atom(name)
      end

      def atom(name)
        raise SchemaError, "generated atom #{name} exceeds 255 bytes" if name.bytesize > 255
        return name if name.match?(/\A[a-z][a-zA-Z0-9_]*\z/) && !ERLANG_RESERVED.include?(name)

        "'#{name.gsub(/[\\']/) { |character| "\\#{character}" }}'"
      end

      def binary(text)
        raise SchemaError, 'generated text is not printable ASCII' unless text.bytes.all? { |byte| byte.between?(32, 126) }

        "<<\"#{text.gsub(/[\\"]/) { |character| "\\#{character}" }}\">>"
      end

      # A list whose "[" stands at column COLUMN: on one line when it fits in
      # 80 columns, else one element a line, aligned under the first.
      def list(items, column)
        single = "[#{items.join(', ')}]"
        return single if single.bytesize + column <= 80 && !single.include?("\n")

        "[#{items.join(",\n#{' ' * (column + 1)}")}]"
      end

      # A map whose "#{" stands at column COLUMN, one key a line.
      def map(fields, column)
        pad = ' ' * (column + 2)
        '#{' + fields.map { |key, value| "#{key} => #{value}" }.join(",\n#{pad}") + '}'
      end

      # Each report layout erx_info_<kind> (docs/design-abi.md, "Kernel
      # reports") as two functions. report_layout(Kind) gives the topic that
      # writes it, its size and the reported bit of each attribute field;
      # decode_report(Kind, Bytes) takes exactly that many bytes apart into
      # {ok, Reported, Fields}, Fields a map of every field but reported, so
      # the collector maps fields and bits to attributes by name. The model's
      # report check has tied every name to the kind before this runs.
      def report_functions(inspection, types)
        topics = types[Inspection::TOPICS]
        reports = inspection.kinds.keys.filter_map do |kind|
          layout = types["erx_info_#{kind}"]
          [kind, layout] if layout.is_a?(Layout)
        end
        layouts = reports.map { |kind, layout| report_layout_clause(kind, layout, topics) }
        decoders = reports.map { |kind, layout| decode_report_clause(inspection, kind, layout) }
        "%% A kernel report's topic, size and reported bit of each field.\n" \
          "-spec report_layout(atom()) ->\n" \
          "          {ok, \#{topic := non_neg_integer(), size := pos_integer(), bits := \#{atom() => pos_integer()}}}\n" \
          "          | error.\n" +
          (layouts + ["report_layout(_Kind) ->\n    error"]).join(";\n") + ".\n\n" \
          "%% A kernel report of Kind taken apart: exactly its layout's bytes, or error.\n" \
          "-spec decode_report(atom(), binary()) -> {ok, non_neg_integer(), \#{atom() => term()}} | error.\n" +
          (decoders + ["decode_report(_Kind, _Bytes) ->\n    error"]).join(";\n") + ".\n"
      end

      # The ABI's error statuses by name, for a record's {error, S}: the status
      # constants are the ones the model gives a description.
      def status_function(constants)
        clauses = constants.values.select { |constant| constant.description && constant.value.negative? }
                           .sort_by(&:value).reverse
                           .map { |constant| "status_name(#{constant.value}) -> {ok, #{atom(constant.name)}}" }
        "%% An error status's name, as erx_abi.txt declares it.\n" \
          "-spec status_name(integer()) -> {ok, atom()} | error.\n" +
          (clauses + ['status_name(_Status) -> error']).join(";\n") + ".\n"
      end

      def report_layout_clause(kind, layout, topics)
        bits = layout.fetch_field(Inspection::REPORTED).type.members.map { |name, mask| [atom(name), mask] }
        fields = [['topic', topics.members.fetch(kind)], ['size', layout.size], ['bits', map(bits, 19)]]
        "report_layout(#{atom(kind)}) ->\n    {ok, #{map(fields, 9)}}"
      end

      # One binary segment for each field in offset order, a skipped segment
      # for each gap, and a value bound to F<n> for the field at position n.
      def decode_report_clause(inspection, kind, layout)
        fields = layout.fields.sort_by(&:offset)
        ends = [0] + fields.map { |field| field.offset + field.size }
        segments = fields.each_with_index.flat_map do |field, index|
          gap = field.offset - ends[index]
          [*(gap.positive? ? ["_:#{gap}/binary"] : []), report_segment(field, "F#{index}")]
        end
        segments << "_:#{layout.size - ends.last}/binary" if layout.size > ends.last
        reported = fields.index { |field| field.name == Inspection::REPORTED }
        values = fields.each_with_index.filter_map do |field, index|
          [atom(field.name), report_value(field, "F#{index}", attribute_type(inspection, kind, field.name))] unless index == reported
        end
        "decode_report(#{atom(kind)},\n              <<#{segments.join(",\n                ")}>>) ->\n" \
          "    {ok, F#{reported}, #{map(values, 12 + reported.to_s.size)}}"
      end

      def report_segment(field, variable)
        return "#{variable}:#{field.size}/binary" if field.array?

        "#{variable}:#{field.type.integer.bits}/#{field.type.integer.signed ? 'little-signed' : 'little'}"
      end

      # The type of the kind's attribute FIELD_NAME, or nil for a field no
      # attribute names.
      def attribute_type(inspection, kind, field_name)
        attribute = inspection.kinds.fetch(kind).find { |attr| attr.key == field_name }
        attribute && inspection.types.fetch(attribute.type)
      end

      # The value of a field for an attribute of TYPE. A scalar ABI enum's
      # number becomes its atom, and a number the enum does not name stays a number,
      # which the attribute's validator refuses. An array of bytes stays a
      # binary, written in lower-case hexadecimal for a text attribute that is not
      # UTF-8, as the
      # build identifier is written everywhere; any wider array becomes a list.
      def report_value(field, variable, type)
        integer = field.type.integer
        if type&.numbers && !field.array?
          members = type.numbers.sort_by { |_name, number| number }.map { |name, number| "#{number} => #{atom(name)}" }
          return "maps:get(#{variable}, \#{#{members.join(', ')}}, #{variable})"
        end
        return variable unless field.array?
        return (type&.form == 'text' && !type.utf8 ? "binary:encode_hex(#{variable}, lowercase)" : variable) if integer.size == 1

        "[X || <<X:#{integer.bits}/#{integer.signed ? 'little-signed' : 'little'}>> <= #{variable}]"
      end

      def ruby(inspection)
        table = {
          'UNITS' => inspection.units,
          'STOPGAPS' => inspection.stopgaps.transform_values do |stopgap|
            { category: stopgap.category, label: stopgap.label, scope: stopgap.scope }
          end,
          'TYPES' => inspection.types.transform_values { |type| ruby_type(type) },
          'KINDS' => (inspection.kinds.transform_values { |attrs| attrs.map { |attr| ruby_attribute(inspection, attr) } })
                       .merge('listing' => []),
          'PATHS' => inspection.paths.map { |path| ruby_path(path) },
          'TRACE_ROWS' => inspection.trace_rows.transform_values(&:reporter)
        }
        constants = ["        SCHEMA = #{inspection.version}"] +
                    table.map { |name, value| "        #{name} = Model.freeze_value(#{ruby_literal(value, 8)})" }
        <<~RUBY
          # Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          # SPDX-License-Identifier: BSD-2-Clause
          # frozen_string_literal: true
          # Generated by tools/gen_abi.rb from abi/inspection.txt.
          # Do not edit this file. Loaded through
          # tools/lib/erx/generated_abi_inspection.rb, which loads abi_model.rb first.

          module Erx
            module ABI
              module Generated
                # The inspection schema for the host tool: units, stopgap reporters,
                # value types by reference, kinds with their attributes in field
                # order, and paths in declaration order.
                module Inspection
          #{constants.join("\n")}
                end
              end
            end
          end
        RUBY
      end

      def ruby_type(type)
        type.to_h.except(:name).compact
      end

      def ruby_attribute(inspection, attr)
        unit = inspection.types.fetch(attr.type).unit
        attr.to_h.merge(unit: unit && inspection.units.fetch(unit))
      end

      def ruby_path(path)
        path.to_h.merge(segments: path.segments.map { |segment| segment.literal || { type: segment.type } })
      end

      def ruby_literal(value, indent)
        case value
        when Hash
          return '{}' if value.empty?

          pad = ' ' * (indent + 2)
          pairs = value.map do |key, item|
            name = key.is_a?(Symbol) ? "#{key}:" : "#{ruby_literal(key, indent)} =>"
            "#{pad}#{name} #{ruby_literal(item, indent + 2)}"
          end
          "{\n#{pairs.join(",\n")}\n#{' ' * indent}}"
        when Array
          single = "[#{value.map { |item| ruby_literal(item, indent) }.join(', ')}]"
          return single if single.bytesize + indent <= 80 && !single.include?("\n")

          pad = ' ' * (indent + 2)
          "[\n#{value.map { |item| pad + ruby_literal(item, indent + 2) }.join(",\n")}\n#{' ' * indent}]"
        when String then value.match?(/\A[ -&(-\[\]-~]*\z/) ? "'#{value}'" : value.dump
        when Integer, TrueClass, FalseClass then value.to_s
        when NilClass then 'nil'
        else raise SchemaError, "no Ruby literal for #{value.class}"
        end
      end
    end
  end
end
