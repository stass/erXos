# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_inspection'

module Erx
  module ABI
    # Emits erx_present, the presentation types of the inspection schema
    # (docs/design-display.md, "Presentations"). A presentation is a path
    # marked `present`, so the only generated data is the table of names and
    # marked paths; the value, canonical text, grammar and inspector path of
    # each follow from erx_schema's path writer and reader, which the code
    # below calls rather than repeats.
    module PresentEmitter
      ERLANG_PATH = 'erlang/apps/erx/src/generated/erx_present.erl'

      # Everything but the table is the same for every schema.
      ERLANG_CODE = <<~'ERLANG'
        %% The marked path of a presentation, or error for a name that is none.
        pattern(Type) ->
            case lists:keyfind(Type, 1, marks()) of
                {Type, Pattern} -> {ok, Pattern};
                false -> error
            end.

        -doc """
        The inspector path a value of Type names: the marked path with the
        value in its variable positions, one segment's value or the tuple of
        several in order. A value outside the segments' types, or a Type that
        is no presentation, raises badarg: the value comes from the code that
        holds it, never from input.
        """.
        -spec path(atom(), term()) -> [erx_schema:segment()].
        path(Type, Value) ->
            case checked_path(Type, Value) of
                {ok, Path, _Pattern} -> Path;
                error -> error(badarg, [Type, Value])
            end.

        checked_path(Type, Value) ->
            maybe
                {ok, Pattern} ?= pattern(Type),
                {ok, Values} ?= values(variables(Pattern), Value),
                Path = fill(Pattern, Values),
                %% Pattern is bound: the path resolves to this presentation's own
                %% declaration, not merely to some declaration.
                {ok, #{pattern := Pattern}} ?= erx_schema:resolve(Path),
                {ok, Path, Pattern}
            else
                _ -> error
            end.

        values(1, Value) -> {ok, [Value]};
        values(Count, Value) when is_tuple(Value), tuple_size(Value) =:= Count -> {ok, tuple_to_list(Value)};
        values(_Count, _Value) -> error.

        variables(Pattern) -> length([variable || {variable, _Type} <- Pattern]).

        %% Pattern with its variable positions taken from Values, in order.
        fill([{variable, _Type} | Pattern], [Value | Values]) -> [Value | fill(Pattern, Values)];
        fill([Literal | Pattern], Values) when is_atom(Literal) -> [Literal | fill(Pattern, Values)];
        fill([], []) -> [].

        %% The segments of Path at Pattern's variable positions.
        segments(Pattern, Path) ->
            [Segment || {{variable, _Type}, Segment} <- lists:zip(Pattern, Path)].

        value([Segment]) -> Segment;
        value(Segments) -> list_to_tuple(Segments).

        -doc """
        The canonical text of a value of Type: its segments as a path's text
        writes them (erx_schema:segment_text/1), joined by "/". It is ASCII and
        at most 4,096 bytes. Raises badarg as path/2 does.
        """.
        -spec text(atom(), term()) -> binary().
        text(Type, Value) ->
            case checked_path(Type, Value) of
                {ok, Path, Pattern} ->
                    iolist_to_binary(lists:join($/, [erx_schema:segment_text(Segment)
                                                     || Segment <- segments(Pattern, Path)]));
                error ->
                    error(badarg, [Type, Value])
            end.

        -doc """
        The value of Type that Text is the canonical text of, or error. Text is
        untrusted: it is bounded, then read by erx_schema:resolve_text/1 as the
        marked path's text with Text's parts in the variable positions, so a
        presentation has the grammar of its path and exactly the spelling
        text/2 writes. No atom is made.
        """.
        -spec parse(atom(), term()) -> {ok, term()} | error.
        parse(Type, Text) when is_binary(Text), byte_size(Text) =< ?MAX_TEXT ->
            Parts = binary:split(Text, <<"/">>, [global]),
            maybe
                {ok, Pattern} ?= pattern(Type),
                true ?= length(Parts) =:= variables(Pattern) andalso not lists:member(<<>>, Parts),
                Full = lists:join($/, [part(Segment) || Segment <- fill(Pattern, Parts)]),
                %% Pattern is bound, as in checked_path/2.
                {ok, Path, #{pattern := Pattern}} ?= erx_schema:resolve_text(iolist_to_binary(Full)),
                {ok, value(segments(Pattern, Path))}
            else
                _ -> error
            end;
        parse(_Type, _Text) ->
            error.

        part(Literal) when is_atom(Literal) -> atom_to_binary(Literal);
        part(Text) -> Text.

        -doc """
        The link of a value, `erx:TYPE/TEXT`: its canonical text with every
        byte outside A-Z a-z 0-9 _ + , : = @ - . / written as % and two
        upper-case hexadecimal digits, so the link is ASCII, holds no control
        character, and keeps the text's "." and "/" as a browser's address does.
        Raises badarg as path/2 does.
        """.
        -spec uri(atom(), term()) -> binary().
        uri(Type, Value) ->
            Text = text(Type, Value),
            <<"erx:", (atom_to_binary(Type))/binary, "/",
              << <<(uri_escaped(Byte))/binary>> || <<Byte>> <= Text >>/binary>>.

        uri_escaped(Byte) ->
            case uri_plain(Byte) of
                true -> <<Byte>>;
                false -> <<$%, (hex_digit(Byte bsr 4)), (hex_digit(Byte band 15))>>
            end.

        uri_plain(Byte) when Byte >= $A, Byte =< $Z -> true;
        uri_plain(Byte) when Byte >= $a, Byte =< $z -> true;
        uri_plain(Byte) when Byte >= $0, Byte =< $9 -> true;
        uri_plain(Byte) -> lists:member(Byte, "_+,:=@-./").

        hex_digit(Digit) when Digit < 10 -> $0 + Digit;
        hex_digit(Digit) -> $A + Digit - 10.

        -doc """
        The presentation and value a link names, read back from the spelling
        uri/2 writes and no other, or error. Link is untrusted: it is bounded,
        its type is read by type/1 and its text by parse/2, and no atom is made.
        """.
        -spec parse_uri(term()) -> {ok, atom(), term()} | error.
        parse_uri(<<"erx:", Rest/binary>>) when byte_size(Rest) =< ?MAX_LINK ->
            maybe
                [Name, Escaped] ?= binary:split(Rest, <<"/">>),
                {ok, Type} ?= type(Name),
                {ok, Text} ?= uri_unescaped(Escaped, <<>>),
                {ok, Value} ?= parse(Type, Text),
                {ok, Type, Value}
            else
                _ -> error
            end;
        parse_uri(_Link) ->
            error.

        %% Only the escapes uri_escaped/1 writes: upper-case digits, and only
        %% for a byte uri_plain/1 refuses.
        uri_unescaped(<<>>, Text) ->
            {ok, Text};
        uri_unescaped(<<$%, High, Low, Rest/binary>>, Text) ->
            maybe
                {ok, H} ?= hex(High),
                {ok, L} ?= hex(Low),
                Byte = H * 16 + L,
                false ?= uri_plain(Byte),
                uri_unescaped(Rest, <<Text/binary, Byte>>)
            else
                _ -> error
            end;
        uri_unescaped(<<Byte, Rest/binary>>, Text) ->
            case uri_plain(Byte) of
                true -> uri_unescaped(Rest, <<Text/binary, Byte>>);
                false -> error
            end.

        hex(Digit) when Digit >= $0, Digit =< $9 -> {ok, Digit - $0};
        hex(Digit) when Digit >= $A, Digit =< $F -> {ok, Digit - $A + 10};
        hex(_Digit) -> error.
      ERLANG

      module_function

      def outputs(schema)
        inspection = schema.inspection || raise(SchemaError, 'the ABI root includes no inspection schema')
        { ERLANG_PATH => erlang(inspection) }.freeze
      end

      def erlang(inspection)
        marked = inspection.paths.select(&:present)
        [head, marks_function(inspection, marked), type_function(marked), ERLANG_CODE].join("\n")
      end

      def head
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from abi/inspection.txt.
          %% Do not edit this file.

          -module(erx_present).
          -moduledoc """
          The presentation types (docs/design-display.md, "Presentations"). Each
          is an inspector path that abi/inspection.txt marks `present`: its value
          is the path's variable segments, its canonical text those segments as
          the path's text writes them, its grammar the path's, and it names that
          path. text/2, path/2 and uri/2 write; parse/2, parse_uri/1 and type/1
          read untrusted text and make no atom.
          """.
          -export([marks/0, type/1, path/2, text/2, parse/2, uri/2, parse_uri/1]).

          %% The longest canonical text, which the generator checks every
          %% presentation's within, and the longest link text after "erx:": a
          %% name and every byte of the text escaped.
          -define(MAX_TEXT, #{Inspection::MAX_PRESENT_TEXT}).
          -define(MAX_LINK, (32 + 1 + 3 * ?MAX_TEXT)).

          -type pattern() :: [atom() | {variable, erx_schema:descriptor()}].
        ERLANG
      end

      def marks_function(inspection, marked)
        entries = marked.map do |path|
          pattern = path.segments.map do |segment|
            if segment.variable?
              "{variable, #{InspectionEmitter.descriptor(inspection, segment.type)}}"
            else
              InspectionEmitter.atom(segment.literal)
            end
          end
          "{#{InspectionEmitter.atom(path.present)}, [#{pattern.join(', ')}]}"
        end
        <<~ERLANG
          -doc "Each presentation and its marked path, in declaration order.".
          -spec marks() -> [{atom(), pattern()}].
          marks() ->
              [#{entries.join(",\n     ")}].
        ERLANG
      end

      def type_function(marked)
        clauses = marked.map { |path| "type(<<\"#{path.present}\">>) -> {ok, #{InspectionEmitter.atom(path.present)}};" }
        <<~ERLANG
          -doc "The presentation a name read from input names, or error; no atom is made.".
          -spec type(term()) -> {ok, atom()} | error.
          #{clauses.join("\n")}
          type(_Name) -> error.
        ERLANG
      end
    end
  end
end
