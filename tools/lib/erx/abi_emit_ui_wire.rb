# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_ui'
require_relative 'abi_emit_inspection'
require_relative 'abi_emit_ui_fields'

module Erx
  module ABI
    # Emits the readers and writers of ui.txt's binary form (docs/design-abi.md,
    # "Widget format") from the `ui` declaration: erx_ui_wire, the Erlang
    # encoder of every record and reader of a renderer's records, and the C
    # reader of the server's records and writer of a renderer's that a native
    # renderer links. The tables (kinds, properties and their types, enums,
    # image types, stopgaps) and the server's records come from the
    # declaration, the records' code through UIFields; the framing, the
    # per-form code and the reports' fields are fixed text. The Erlang module is
    # erx_ui's, the widget toolkit's, so the display domain's release holds no widget
    # codec (docs/design-display.md, G9).
    module UIWireEmitter
      ERLANG_PATH = 'erlang/apps/erx_ui/src/erx_ui_wire.erl'
      C_HEADER_PATH = 'include/erx/ui_wire.h'
      C_SOURCE_PATH = 'display/generated/erx_ui_wire.c'
      # The status block's codes and the reporters' (docs/design-abi.md).
      STATUSES = %w[ok partial unknown unsupported timeout error].freeze
      REPORTERS = %w[own kernel service runtime stopgap].freeze
      FORMS = %w[boolean integer enum image text bytes list event presentation].freeze
      # The longest stopgap and presentation name and the longest canonical text,
      # the sizes abi_ui.rb's insert bound counts.
      NAME_MAX = 63
      PRESENT_MAX = 4096
      DETAILS = %w[none boolean integer text].freeze
      # An event's tag, node, number, detail tag and text length: what an
      # event record holds besides its text.
      EVENT_TEXT_FIELDS = 1 + 4 + 1 + 1 + 4

      module_function

      def outputs(schema)
        return {} unless schema.ui

        stopgaps = schema.inspection.stopgaps.keys
        raise SchemaError, 'the ui wire reader needs at least one stopgap reporter' if stopgaps.empty?
        stopgaps.each { |name| raise SchemaError, "stopgap #{name} exceeds #{NAME_MAX} bytes" if name.bytesize > NAME_MAX }
        enums = enums(schema.ui)
        if enums.any? { |type| type.numbers.size > 255 }
          raise SchemaError, 'a ui enum of 256 members does not fit the reader member count'
        end
        { ERLANG_PATH => erlang(schema.ui, stopgaps: stopgaps),
          C_HEADER_PATH => c_header(schema.ui, enums: enums),
          C_SOURCE_PATH => c_source(schema.ui, stopgaps: stopgaps, enums: enums) }.freeze
      end

      # The properties a record may carry: every one but the key, never written.
      # erx_ui_takes(): whether a kind takes a property, the rule a renderer
      # applies to every record, since the reader decides nothing by kind.
      def kind_takes(ui)
        common = wire_properties(ui).select(&:common).map { |property| "\tcase #{macro('ui_prop', property.name)}:" }
        listed = wire_properties(ui).reject(&:common)
        own = ui.kinds.filter_map do |kind|
          properties = kind.takes.map(&:property).select { |property| listed.include?(property) }
          next if properties.empty?

          tests = properties.map { |property| "prop == #{macro('ui_prop', property.name)}" }
          "\tcase #{macro('ui_kind', kind.name)}:\n\t\treturn (#{tests.join(" ||\n\t\t    ")});"
        end
        <<~C
          bool
          erx_ui_takes(uint8_t kind, uint8_t prop)
          {
          	if (!erx_ui_kinds[kind])
          		return (false);
          	switch (prop) {
          #{common.join("\n")}
          		return (true);
          	default:
          		break;
          	}
          	switch (kind) {
          #{own.join("\n")}
          	default:
          		return (false);
          	}
          }
        C
      end

      def wire_properties(ui) = ui.properties.reject { |property| property.type.form == 'key' }

      # The root enums the properties name, each once, by name.
      def enums(ui)
        ui.properties.map(&:type).select { |type| type.form == 'enum' }.uniq(&:name)
      end

      def atom(name) = InspectionEmitter.atom(name)

      # Every record's name and tag, the server's and the reports', in tag order.
      def tags(ui) = (ui.records + ui.reports).sort_by(&:tag).map { |record| [record.name, record.tag] }

      def report_tag(ui, name) = ui.reports.find { |report| report.name == name }&.tag ||
                                 raise(SchemaError, "ui.txt declares no report #{name}")

      # --- Erlang --------------------------------------------------------------

      def erlang(ui, stopgaps:)
        [erlang_head(ui), erlang_encoder(ui), erlang_tables(ui, stopgaps), erlang_reader, erlang_server_reader(ui)]
          .join("\n")
      end

      def erlang_head(ui)
        <<~ERLANG
          %% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
          %% SPDX-License-Identifier: BSD-2-Clause
          %% Generated by tools/gen_abi.rb from abi/formats/ui.txt.
          %% Do not edit this file.

          -module(erx_ui_wire).
          -moduledoc """
          ui.txt's binary form (docs/design-abi.md, "Widget format"). encode/2 writes
          any record; read/1 reads the records a renderer sends the server, event and
          damage, and refuses every other tag; read_server/1 reads the records the
          server sends a renderer, insert to commit, screen, input, repaint and
          presented, and refuses event and damage. A record is a u32 length, which counts the tag
          and the fields, then a u8 tag and the fields; integers are little-endian.
          The readers keep no state between records, decide nothing that depends on
          a node's kind and make no atom: every name they return comes from the
          declaration's tables.
          """.
          -export([encode/2, read/1, read_server/1]).
          -export_type([wire_record/0, present/0, reason/0, refusal/0]).

          -define(OP_MAX, #{ui.op_max}).
          -define(NAME_MAX, #{NAME_MAX}).
          -define(PRESENT_MAX, #{PRESENT_MAX}).
          -define(DAMAGE_MAX, #{ui.damage_max}).
          -define(PROPERTY_MAX, #{wire_properties(ui).size}).
          -define(EVENT, #{report_tag(ui, 'event')}).
          -define(DAMAGE, #{report_tag(ui, 'damage')}).
          -define(IS_I8(V), (is_integer(V) andalso V >= -128 andalso V =< 127)).
          -define(IS_DIRECTION(V), (V =:= down orelse V =:= up)).
          -define(IS_U8(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ff)).
          -define(IS_U16(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ffff)).
          -define(IS_U32(V), (is_integer(V) andalso V >= 0 andalso V =< 16#ffffffff)).
          -define(IS_NODE(V), (is_integer(V) andalso V >= 1 andalso V =< 16#ffffffff)).

          -type node_id() :: 1..16#ffffffff.
          -type input() :: #{UIFields.erlang_types(ui).fetch(:input)}.
          -type detail() :: none | boolean() | integer() | binary().
          %% erx_ui_model's diff_op()s, then the records of a native renderer's pipes.
          -type wire_record() :: #{UIFields.erlang_types(ui).fetch(:records).join("\n                     | ")}
                               | {event, node_id(), Event :: atom(), detail()}
                               | {damage, Width :: 0..65535, Height :: 0..65535, [rect(), ...]}.
          %% A damage report's rectangle: its top left corner, its width and its height,
          %% within the width and height the report was drawn at.
          -type rect() :: {X :: 0..65535, Y :: 0..65535, Width :: 1..65535, Height :: 1..65535}.
          %% A present property's canonical text, erx_present:text/2.
          -type present() :: fun((Type :: atom(), Value :: term()) -> binary()).
          -type reason() :: bad_length | bad_tag | bad_node | bad_event | bad_detail | bad_body.
          %% read_server/1's reasons, those of the C reader erx/ui_wire.h declares.
          -type refusal() :: #{UIFields.erlang_refusals}.
        ERLANG
      end

      def erlang_encoder(ui)
        [ENCODER_HEAD + UIFields.erlang_body_clauses(ui) + ENCODER_REPORTS, ENCODER_VALUES,
         UIFields.erlang_input_encoder(ui), UIFields.erlang_writers(ui)].join("\n")
      end

      # encode/2, then the clauses of body/2: the server's records', from the
      # declaration, and the reports'.
      ENCODER_HEAD = <<~'ERLANG'
          -doc """
          The record's bytes. Props and removals come from a tree erx_ui_schema
          accepted; a value that does not fit its field raises
          {bad_value, Property} rather than being truncated, and a record longer
          than its limit raises {too_long, Size}.
          """.
          -spec encode(wire_record(), present()) -> binary().
          encode(Record, Present) ->
              Body = iolist_to_binary(body(Record, Present)),
              Size = byte_size(Body),
              Size =< ?OP_MAX orelse error({too_long, Size}),
              <<Size:32/little, Body/binary>>.

      ERLANG

      ENCODER_REPORTS = <<~'ERLANG'
          body({event, Node, Event, Detail}, _Present) when ?IS_NODE(Node) ->
              [<<?EVENT, Node:32/little, (event_number(Event))>> | detail(Detail)];
          body({damage, Width, Height, Rects}, _Present)
            when ?IS_U16(Width), ?IS_U16(Height), is_list(Rects), length(Rects) >= 1, length(Rects) =< ?DAMAGE_MAX ->
              [<<?DAMAGE, Width:16/little, Height:16/little, (length(Rects))>>
               | [rect(Rect, Width, Height) || Rect <- Rects]];
          body(Record, _Present) ->
              error({bad_record, Record}).

          %% A damage report's rectangle; one of no width or height, or not within
          %% the report's ScreenWidth and ScreenHeight, raises {bad_rect, Rect}.
          rect({X, Y, Width, Height} = Rect, ScreenWidth, ScreenHeight) ->
              ?IS_U16(X) andalso ?IS_U16(Y) andalso ?IS_U16(Width) andalso ?IS_U16(Height)
                  andalso Width > 0 andalso Height > 0
                  andalso X + Width =< ScreenWidth andalso Y + Height =< ScreenHeight
                  orelse error({bad_rect, Rect}),
              <<X:16/little, Y:16/little, Width:16/little, Height:16/little>>;
          rect(Rect, _ScreenWidth, _ScreenHeight) ->
              error({bad_rect, Rect}).
        ERLANG

      ENCODER_VALUES = <<~'ERLANG'
          %% A u8 count, then each property in number order: its number and value.
          props(Props, Present) ->
              Fields = lists:sort([{number(Name), Name, Value} || Name := Value <- Props, Name =/= key]),
              [length(Fields) | [[Number | value(Name, Value, Present)] || {Number, Name, Value} <- Fields]].

          %% A status property begins with its status block: status, reporter, the
          %% stopgap's name and the timeout. A two-tuple whose first element is a
          %% reporter is an attr(); anything else is the application's own value.
          status({Reporter, Carried}, Name, Present) when Reporter =:= kernel; Reporter =:= service; Reporter =:= runtime ->
              carried(Carried, case Reporter of kernel -> 1; service -> 2; runtime -> 3 end, <<>>, Name, Present);
          status({{stopgap, Stopgap}, Carried}, Name, Present) ->
              stopgap(Stopgap) orelse error({bad_value, Name}),
              carried(Carried, 4, atom_to_binary(Stopgap), Name, Present);
          status(Value, Name, Present) ->
              [block(0, 0, <<>>, 0) | plain(Name, Value, Present)].

          carried({ok, Value}, Reporter, Stopgap, Name, Present) ->
              [block(0, Reporter, Stopgap, 0) | plain(Name, Value, Present)];
          carried({partial, Value}, Reporter, Stopgap, Name, Present) ->
              [block(1, Reporter, Stopgap, 0) | plain(Name, Value, Present)];
          carried(unknown, Reporter, Stopgap, _Name, _Present) ->
              block(2, Reporter, Stopgap, 0);
          carried(unsupported, Reporter, Stopgap, _Name, _Present) ->
              block(3, Reporter, Stopgap, 0);
          carried({timeout, Ms}, Reporter, Stopgap, _Name, _Present) when is_integer(Ms), Ms >= 1, Ms =< 16#ffffffff ->
              block(4, Reporter, Stopgap, Ms);
          carried({error, _Reason}, Reporter, Stopgap, _Name, _Present) ->
              block(5, Reporter, Stopgap, 0);
          carried(_Carried, _Reporter, _Stopgap, Name, _Present) ->
              error({bad_value, Name}).

          block(Status, Reporter, Stopgap, Ms) ->
              <<Status, Reporter, (byte_size(Stopgap)), Stopgap/binary, Ms:32/little>>.

          integer(Value, Min, Max, _Name) when is_integer(Value), Value >= Min, Value =< Max -> <<Value:32/little-signed>>;
          integer(_Value, _Min, _Max, Name) -> error({bad_value, Name}).

          boolean(true, _Name) -> <<1>>;
          boolean(false, _Name) -> <<0>>;
          boolean(_Value, Name) -> error({bad_value, Name}).

          member(Value, Members, Name) ->
              case lists:keyfind(Value, 1, Members) of
                  {_, Number} -> <<Number>>;
                  false -> error({bad_value, Name})
              end.

          %% A text or bytes as a u32 length and the bytes.
          bytes(Value, Max, _Name) when is_binary(Value), byte_size(Value) =< Max -> [<<(byte_size(Value)):32/little>> | Value];
          bytes(_Value, _Max, Name) -> error({bad_value, Name}).

          list(Value, TextMax, Max, Name) when is_list(Value), length(Value) =< Max ->
              [<<(length(Value)):16/little>> | [bytes(Text, TextMax, Name) || Text <- Value]];
          list(_Value, _TextMax, _Max, Name) -> error({bad_value, Name}).

          %% A presentation's name as a u8 length and at most 63 bytes, then its
          %% canonical text as a text of at most 4,096 bytes. erx_present:text/2
          %% returns valid UTF-8 within that bound.
          presentation({Type, Value}, Present, Name) when is_atom(Type) ->
              TypeName = atom_to_binary(Type),
              byte_size(TypeName) =< ?NAME_MAX orelse error({bad_value, Name}),
              [byte_size(TypeName), TypeName | bytes(Present(Type, Value), ?PRESENT_MAX, Name)];
          presentation(_Value, _Present, Name) -> error({bad_value, Name}).

          detail(none) -> <<0>>;
          detail(true) -> <<1, 1>>;
          detail(false) -> <<1, 0>>;
          detail(Value) when is_integer(Value), Value >= -16#80000000, Value =< 16#7fffffff -> <<2, Value:32/little-signed>>;
          detail(Value) when is_binary(Value) -> [<<3, (byte_size(Value)):32/little>> | Value];
          detail(Value) -> error({bad_value, Value}).
        ERLANG

      def erlang_tables(ui, stopgaps)
        properties = wire_properties(ui)
        events = properties.select { |property| property.type.form == 'event' }
        status = properties.select(&:status)
        [
          clauses('kind_number', ui.kinds.map { |kind| [atom(kind.name), kind.number.to_s] },
                  fallback: "kind_number(Kind) -> error({bad_kind, Kind}).",
                  comment: 'Each kind, property and event by name, and each event by number.'),
          clauses('number', properties.map { |property| [atom(property.name), property.number.to_s] },
                  fallback: 'number(Name) -> error({bad_property, Name}).'),
          clauses('event_number', events.map { |property| [atom(property.name), property.number.to_s] },
                  fallback: 'event_number(Name) -> error({bad_event, Name}).'),
          clauses('event_name', events.map { |property| [property.number.to_s, atom(property.name)] },
                  fallback: 'event_name(_Number) -> error.'),
          "stopgap(Name) -> lists:member(Name, [#{stopgaps.map { |name| atom(name) }.join(', ')}]).\n",
          clauses('kind_name', ui.kinds.map { |kind| [kind.number.to_s, atom(kind.name)] },
                  fallback: 'kind_name(_Number) -> error.',
                  comment: "The reader's tables: each kind and property by number, each stopgap by name."),
          clauses('property', properties.map { |property| [property.number.to_s, reader_entry(property)] },
                  fallback: 'property(_Number) -> error.'),
          clauses('stopgap_name', stopgaps.map { |name| ["<<\"#{name}\">>", atom(name)] },
                  fallback: 'stopgap_name(_Name) -> error.'),
          value_clauses(status),
          "%% A value of the property's own type.\n" +
            properties.map { |property| plain_clause(property) }.join(";\n") + ".\n"
        ].join("\n")
      end

      # A property's entry in the reader's table: its name, whether a status
      # block precedes its value, and what read_value/2 reads.
      def reader_entry(property)
        type = property.type
        read =
          case type.form
          when 'integer' then "{integer, #{type.minimum}, #{type.maximum}}"
          when 'boolean', 'event', 'presentation' then type.form
          when 'enum', 'image'
            "{member, [#{type.numbers.zip(type.atoms).map { |number, member| "{#{number}, #{atom(member)}}" }.join(', ')}]}"
          when 'text', 'bytes' then "{#{type.form}, #{type.maximum}}"
          when 'list' then "{list, #{type.element.maximum}, #{type.maximum}}"
          end
        "{#{atom(property.name)}, #{property.status}, #{read}}"
      end

      def clauses(name, pairs, fallback:, comment: nil)
        lines = pairs.map { |argument, result| "#{name}(#{argument}) -> #{result};\n" }
        "#{comment ? "%% #{comment}\n" : ''}#{lines.join}#{fallback}\n"
      end

      def value_clauses(status)
        lines = status.map { |property| "value(#{atom(property.name)}, Value, Present) -> status(Value, #{atom(property.name)}, Present);\n" }
        "#{lines.join}value(Name, Value, Present) -> plain(Name, Value, Present).\n"
      end

      def plain_clause(property)
        name = atom(property.name)
        type = property.type
        body =
          case type.form
          when 'integer' then "integer(Value, #{type.minimum}, #{type.maximum}, #{name})"
          when 'boolean' then "boolean(Value, #{name})"
          when 'enum', 'image'
            "member(Value, [#{type.atoms.zip(type.numbers).map { |member, number| "{#{atom(member)}, #{number}}" }.join(', ')}], #{name})"
          when 'text', 'bytes' then "bytes(Value, #{type.maximum}, #{name})"
          when 'list' then "list(Value, #{type.element.maximum}, #{type.maximum}, #{name})"
          when 'event' then '<<>>'
          when 'presentation' then "presentation(Value, Present, #{name})"
          end
        value = type.form == 'event' ? '_Value' : 'Value'
        present = type.form == 'presentation' ? 'Present' : '_Present'
        "plain(#{name}, #{value}, #{present}) ->\n    #{body}"
      end

      def erlang_reader
        <<~'ERLANG'
          -doc """
          The first record of Bytes, an event or a damage report, and the bytes
          after it; more when Bytes holds no whole record yet. A record longer
          than web_ui_op_max is refused as soon as its length is in, so a stream
          never buffers more than that and the length for one record. A damage
          report names the width and height it was drawn at; its count lies in
          1..ui_damage_rects and each rectangle has some width and height and lies
          within that size. Whether the size is the window's is for the process
          that knows the window to decide.
          """.
          -spec read(binary()) -> {ok, wire_record(), Rest :: binary()} | more | {error, reason()}.
          read(<<0:32, _/binary>>) ->
              {error, bad_length};
          read(<<Length:32/little, _/binary>>) when Length > ?OP_MAX ->
              {error, bad_length};
          read(<<Length:32/little, Body:Length/binary, Rest/binary>>) ->
              case read_body(Body) of
                  {ok, Record} -> {ok, Record, Rest};
                  {error, _Reason} = Error -> Error
              end;
          read(Bytes) when is_binary(Bytes) ->
              more.

          read_body(<<?EVENT, Node:32/little, Number, Detail/binary>>) ->
              case {Node, event_name(Number), read_detail(Detail)} of
                  {0, _, _} -> {error, bad_node};
                  {_, error, _} -> {error, bad_event};
                  {_, _, error} -> {error, bad_detail};
                  {_, Event, {ok, Value}} -> {ok, {event, Node, Event, Value}}
              end;
          read_body(<<?DAMAGE, Width:16/little, Height:16/little, Count, Rects/binary>>)
            when Count >= 1, Count =< ?DAMAGE_MAX, byte_size(Rects) =:= Count * 8 ->
              read_rects(Rects, {Width, Height}, []);
          read_body(<<Tag, _/binary>>) when Tag =:= ?EVENT; Tag =:= ?DAMAGE ->
              {error, bad_body};
          read_body(_Body) ->
              {error, bad_tag}.

          %% A damage report's rectangles, each of some width and height and within
          %% the size the report was drawn at.
          read_rects(<<>>, {ScreenWidth, ScreenHeight}, Rects) ->
              {ok, {damage, ScreenWidth, ScreenHeight, lists:reverse(Rects)}};
          read_rects(<<X:16/little, Y:16/little, Width:16/little, Height:16/little, Rest/binary>>,
                     {ScreenWidth, ScreenHeight} = Size, Rects)
            when Width > 0, Height > 0, X + Width =< ScreenWidth, Y + Height =< ScreenHeight ->
              read_rects(Rest, Size, [{X, Y, Width, Height} | Rects]);
          read_rects(_Bytes, _Size, _Rects) ->
              {error, bad_body}.

          %% An event's detail: none, a boolean, a signed 32-bit integer or a text.
          read_detail(<<0>>) -> {ok, none};
          read_detail(<<1, Flag>>) when Flag =< 1 -> {ok, Flag =:= 1};
          read_detail(<<2, Value:32/little-signed>>) -> {ok, Value};
          read_detail(<<3, Length:32/little, Text:Length/binary>>) ->
              case utf8(Text) of
                  true -> {ok, Text};
                  false -> error
              end;
          read_detail(_Detail) -> error.

          utf8(<<>>) -> true;
          utf8(<<_Character/utf8, Rest/binary>>) -> utf8(Rest);
          utf8(_Bytes) -> false.
        ERLANG
      end

      # The reader of the server's records, the Erlang twin of the C reader:
      # the same fields read in the same order and refused for the same
      # reasons, so the parity test compares the three readers record by record.
      def erlang_server_reader(ui)
        [SERVER_READER, UIFields.erlang_server_fields(ui), UIFields.erlang_read_input(ui),
         UIFields.erlang_readers(ui), SERVER_VALUES].join("\n")
      end

      SERVER_READER = <<~'ERLANG'
          -doc """
          The first record of Bytes that the server sends a renderer, and the bytes
          after it; more when Bytes holds no whole record yet. A length of 0 or above
          ui_op_max is refused before the record's bytes arrive.

          A record reads as encode/2 takes it, with what the binary form carries of
          each value: an event property as true, the node taking it; a presentation
          as {Name, Text}, its type's name and canonical text, both binaries of valid
          UTF-8, for the name read from input makes no atom; and an error status as
          the atom error, whose reason the form does not carry. A set's removals are
          in the order the record lists them.
          """.
          -spec read_server(binary()) -> {ok, wire_record(), Rest :: binary()} | more | {error, refusal()}.
          read_server(<<Length:32/little, _/binary>>) when Length =:= 0; Length > ?OP_MAX ->
              {error, bad_length};
          read_server(<<Length:32/little, Body:Length/binary, Rest/binary>>) ->
              try server_fields(Body) of
                  {Record, <<>>} -> {ok, Record, Rest};
                  {_Record, _Left} -> {error, bytes_left_over}
              catch
                  throw:{?MODULE, Reason} -> {error, Reason}
              end;
          read_server(Bytes) when is_binary(Bytes) ->
              more.

          %% A refusal ends the read of one record: thrown from the field that
          %% breaks a rule, caught by read_server/1 alone.
          refuse(Reason) -> throw({?MODULE, Reason}).

          %% A field and the bytes after it, or a refusal for Reason when it is
          %% cut short: the reason the C reader gives for that field, so an insert's
          %% parent cut short is bad_node and a screen's width short_record.
          u8(<<Value, Rest/binary>>, _Reason) -> {Value, Rest};
          u8(_Bytes, Reason) -> refuse(Reason).

          u16(<<Value:16/little, Rest/binary>>, _Reason) -> {Value, Rest};
          u16(_Bytes, Reason) -> refuse(Reason).

          u32(<<Value:32/little, Rest/binary>>, _Reason) -> {Value, Rest};
          u32(_Bytes, Reason) -> refuse(Reason).

          %% A length of 1 or 4 bytes, at most Max, and that many bytes of valid UTF-8.
          text(Bytes, Width, Max, Reason) ->
              {Length, Rest} = case Width of 1 -> u8(Bytes, Reason); 4 -> u32(Bytes, Reason) end,
              Length =< Max orelse refuse(Reason),
              case Rest of
                  <<Text:Length/binary, After/binary>> ->
                      utf8(Text) orelse refuse(Reason),
                      {Text, After};
                  _ -> refuse(Reason)
              end.

        ERLANG

      SERVER_VALUES = <<~'ERLANG'
          %% A u8 count and each property: a known number, once, and its value.
          read_props(Bytes) ->
              {Count, Rest} = u8(Bytes, short_record),
              Count =< ?PROPERTY_MAX orelse refuse(too_many_properties),
              read_props(Count, Rest, #{}).

          read_props(0, Rest, Props) ->
              {Props, Rest};
          read_props(Count, Bytes, Props) ->
              {Number, R1} = u8(Bytes, short_record),
              {Name, Status, Type} = case property(Number) of error -> refuse(unknown_property); Entry -> Entry end,
              is_map_key(Name, Props) andalso refuse(property_twice),
              {Value, R2} = case Status of
                                true -> read_status(R1, Type);
                                false -> read_value(R1, Type)
                            end,
              read_props(Count - 1, R2, Props#{Name => Value}).

          %% A set's removals: a u8 count of known property numbers, each once.
          read_removed(Bytes) ->
              {Count, Rest} = u8(Bytes, short_record),
              Count =< ?PROPERTY_MAX orelse refuse(too_many_properties),
              read_removed(Count, Rest, []).

          read_removed(0, Rest, Names) ->
              {lists:reverse(Names), Rest};
          read_removed(Count, Bytes, Names) ->
              {Number, Rest} = u8(Bytes, short_record),
              {Name, _Status, _Type} = case property(Number) of error -> refuse(unknown_property); Entry -> Entry end,
              lists:member(Name, Names) andalso refuse(property_twice),
              read_removed(Count - 1, Rest, [Name | Names]).

          %% The status block: a status and a reporter within their codes, a
          %% stopgap's name that is a declared stopgap exactly when the reporter is
          %% a stopgap, and a timeout set exactly when the status is timeout. The
          %% application's own value is always ok, and reads as the plain value.
          read_status(Bytes, Type) ->
              {StatusCode, R1} = u8(Bytes, bad_status),
              {ReporterCode, R2} = u8(R1, bad_status),
              {StopgapName, R3} = text(R2, 1, ?NAME_MAX, bad_status),
              {Ms, R4} = u32(R3, bad_status),
              (StatusCode =< 5 andalso ReporterCode =< 4) orelse refuse(bad_status),
              (ReporterCode =:= 0 andalso StatusCode =/= 0) andalso refuse(bad_status),
              (StatusCode =:= 4) =:= (Ms =/= 0) orelse refuse(bad_status),
              Reporter = reporter(ReporterCode, StopgapName),
              case StatusCode of
                  0 when Reporter =:= own -> read_value(R4, Type);
                  0 -> carried(ok, Reporter, read_value(R4, Type));
                  1 -> carried(partial, Reporter, read_value(R4, Type));
                  2 -> {{Reporter, unknown}, R4};
                  3 -> {{Reporter, unsupported}, R4};
                  4 -> {{Reporter, {timeout, Ms}}, R4};
                  5 -> {{Reporter, error}, R4}
              end.

          carried(Status, Reporter, {Value, Rest}) -> {{Reporter, {Status, Value}}, Rest}.

          reporter(0, <<>>) -> own;
          reporter(1, <<>>) -> kernel;
          reporter(2, <<>>) -> service;
          reporter(3, <<>>) -> runtime;
          reporter(4, Name) ->
              case stopgap_name(Name) of
                  error -> refuse(bad_status);
                  Stopgap -> {stopgap, Stopgap}
              end;
          reporter(_Code, _Name) -> refuse(bad_status).

          %% A value of the property's type, bounded by the type and by what remains.
          read_value(Bytes, {integer, Min, Max}) ->
              case Bytes of
                  <<Value:32/little-signed, Rest/binary>> when Value >= Min, Value =< Max -> {Value, Rest};
                  _ -> refuse(bad_value)
              end;
          read_value(<<0, Rest/binary>>, boolean) -> {false, Rest};
          read_value(<<1, Rest/binary>>, boolean) -> {true, Rest};
          read_value(<<Number, Rest/binary>>, {member, Members}) ->
              case lists:keyfind(Number, 1, Members) of
                  {Number, Member} -> {Member, Rest};
                  false -> refuse(bad_value)
              end;
          read_value(Bytes, {text, Max}) ->
              text(Bytes, 4, Max, bad_value);
          read_value(<<Length:32/little, Value:Length/binary, Rest/binary>>, {bytes, Max}) when Length =< Max ->
              {Value, Rest};
          read_value(<<Count:16/little, Rest/binary>>, {list, TextMax, Max}) when Count =< Max ->
              read_list(Count, Rest, TextMax, []);
          read_value(Rest, event) ->
              {true, Rest};
          read_value(Bytes, presentation) ->
              {Name, R1} = text(Bytes, 1, ?NAME_MAX, bad_value),
              {Text, R2} = text(R1, 4, ?PRESENT_MAX, bad_value),
              {{Name, Text}, R2};
          read_value(_Bytes, _Type) ->
              refuse(bad_value).

          read_list(0, Rest, _TextMax, Texts) ->
              {lists:reverse(Texts), Rest};
          read_list(Count, Bytes, TextMax, Texts) ->
              {Text, Rest} = text(Bytes, 4, TextMax, bad_value),
              read_list(Count - 1, Rest, TextMax, [Text | Texts]).
        ERLANG

      # --- C -------------------------------------------------------------------

      def macro(*parts) = "ERX_#{parts.join('_').upcase}"

      def c_header(ui, enums:)
        properties = wire_properties(ui)
        defines = [
          ['ERX_UI_VERSION', ui.version, "ui.txt's version"],
          ['ERX_UI_OP_MAX', ui.op_max, 'the longest record, its tag and fields'],
          ['ERX_UI_DAMAGE_MAX', ui.damage_max, 'the most rectangles one damage report carries'],
          ['ERX_UI_DAMAGE_RECORD_MAX', 4 + 1 + 4 + 1 + (4 * 2 * ui.damage_max), 'the longest damage record, its length word counted'],
          ['ERX_UI_EVENT_TEXT_MAX', ui.op_max - EVENT_TEXT_FIELDS, 'the longest text detail of an event'],
          ['ERX_UI_PROPERTY_MAX', properties.size, 'the most properties one record carries, each at most once'],
          ['ERX_UI_RUNE_NONE', '0xffffffffU', "a key's rune when it has none"],
          ['ERX_UI_NAME_MAX', NAME_MAX, 'the longest stopgap or presentation name'],
          ['ERX_UI_PRESENT_MAX', PRESENT_MAX, "the longest presentation's canonical text"]
        ]
        groups = [
          ['Record tags.', tags(ui).map { |name, tag| [macro('ui', name), tag] }],
          ['Kinds.', ui.kinds.map { |kind| [macro('ui_kind', kind.name), kind.number] }],
          ['Properties.', properties.map { |property| [macro('ui_prop', property.name), property.number] }],
          ['Image types.', ui.images.map { |image| [macro('ui_image', image.name), image.number] }],
          *enums.map { |type| ["The root enum #{type.name.delete_prefix('@')}.", type.atoms.zip(type.numbers).map { |member, number| [macro(type.name.delete_prefix('@'), member), number] }] },
          ["A property's form, which says which fields of its erx_ui_prop_t hold its value.",
           FORMS.each_with_index.map { |name, index| [macro('ui_form', name), index + 1] }],
          ['A status block: the status and the reporter.',
           STATUSES.each_with_index.map { |name, index| [macro('ui_status', name), index] } +
             REPORTERS.each_with_index.map { |name, index| [macro('ui_reporter', name), index] }],
          ["An input record's forms.", ui.inputs.map { |form| [macro('ui_input', form.name), form.number] }],
          ["An event's detail.", DETAILS.each_with_index.map { |name, index| [macro('ui_detail', name), index] }]
        ]
        <<~C
          /*
           * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
           * SPDX-License-Identifier: BSD-2-Clause
           * Generated by tools/gen_abi.rb from abi/formats/ui.txt.
           * Do not edit this file.
           *
           * The reader of the records the widget server writes to a native
           * renderer in ui.txt's binary form (docs/design-abi.md, "Widget
           * format"): insert, remove, set, move, commit, screen, input and
           * repaint and presented; and the writer of the records a renderer
           * writes back: event and damage. A record is a u32 length, which counts the tag
           * and the fields, then a u8 tag and the fields; integers are
           * little-endian. Neither allocates: the reader copies no bytes, and
           * texts point into the caller's buffer; the writer writes into the
           * caller's buffer and nothing past its size.
           */

          #ifndef ERX_UI_WIRE_H
          #define ERX_UI_WIRE_H

          #include <stdbool.h>
          #include <stddef.h>
          #include <stdint.h>

          #{defines.map { |name, value, comment| "#define #{name.ljust(26)}#{value}\t/* #{comment} */" }.join("\n")}

          #{groups.map { |comment, pairs| enum_block(comment, pairs) }.join("\n")}
          /* The reasons erx_ui_read() refuses a record for, those of the Erlang and TypeScript readers. */
          #{UIFields.c_refusal_defines}

          typedef enum erx_ui_result {
          	ERX_UI_READ_OK,		/* one whole record read */
          	ERX_UI_READ_MORE,	/* the buffer holds no whole record yet */
          	ERX_UI_READ_BAD		/* the record is refused; reason says why */
          } erx_ui_result_t;

          /*
           * A pointer and a length: bytes inside the buffer handed to
           * erx_ui_read(), or bytes the caller hands a writer.
           */
          typedef struct erx_ui_bytes erx_ui_bytes_t;
          struct erx_ui_bytes {
          	const uint8_t	*data;
          	uint32_t	 length;
          };

          /*
           * One property of an insert or a set. A boolean, integer, enum or image
           * value is in integer; a text or bytes in bytes; a list's count in count
           * and its encoded texts in bytes, walked with erx_ui_list_next(); a
           * presentation's name in name and its canonical text in bytes. An event
           * has no value, nor has a status property whose status is neither ok nor
           * partial: has_value is false for both. Status, reporter, stopgap and
           * timeout_ms are the status block of a status property, and ok, own,
           * empty and 0 for any other.
           */
          typedef struct erx_ui_prop erx_ui_prop_t;
          struct erx_ui_prop {
          	erx_ui_bytes_t	 bytes;
          	erx_ui_bytes_t	 name;
          	erx_ui_bytes_t	 stopgap;
          	uint32_t	 timeout_ms;
          	int32_t		 integer;
          	uint16_t	 count;
          	uint8_t		 number;
          	uint8_t		 form;
          	uint8_t		 status;
          	uint8_t		 reporter;
          	bool		 has_value;
          };

          /*
           * One record. Tag says which fields are set: node for insert, remove, set
           * and move; parent, index and kind for insert; index for move; props for
           * insert and set; removed for set; width, height and chan for screen;
           * input and its fields for input. Reason is set when a record is refused.
           */
          typedef struct erx_ui_record erx_ui_record_t;
          struct erx_ui_record {
          	const char	*reason;
          #{UIFields.c_members(ui).map { |type, name| UIFields.c_member_line(type, name) }.join("\n")}
          	uint8_t		 tag;
          };

          /*
           * Read the first record of buffer[0..length) into record. On
           * ERX_UI_READ_OK, used is the record's size, its length word included.
           * A record whose length exceeds ERX_UI_OP_MAX is refused before its
           * bytes arrive, so a caller never buffers more than ERX_UI_OP_MAX + 4.
           */
          erx_ui_result_t erx_ui_read(const uint8_t *buffer, size_t length,
              erx_ui_record_t *record, size_t *used);

          /*
           * The next text of a list property read by erx_ui_read(), starting from
           * *cursor 0; false after the last. The reader has checked every text.
           */
          bool erx_ui_list_next(const erx_ui_prop_t *list, uint32_t *cursor,
              erx_ui_bytes_t *text);

          /*
           * Whether a node of kind takes property prop: every property marked
           * common and those listed beneath the kind. The reader decides nothing
           * by kind, so a renderer refuses with this a property its node does not
           * take.
           */
          bool erx_ui_takes(uint8_t kind, uint8_t prop);

          /*
           * An event's detail: tag is an ERX_UI_DETAIL_* value; a boolean's 0 or 1,
           * or an integer, is in integer; a text, valid UTF-8 of at most
           * ERX_UI_EVENT_TEXT_MAX bytes, in text.
           */
          typedef struct erx_ui_detail erx_ui_detail_t;
          struct erx_ui_detail {
          	erx_ui_bytes_t	 text;
          	int32_t		 integer;
          	uint8_t		 tag;
          };

          /*
           * Write an event record, its length word included, to buffer[0..size):
           * that node's event property number event fired with detail, whose
           * text must not overlap the buffer. Return
           * the bytes written, or 0, with nothing written, when the record is
           * refused: node 0, a number that is not an event property, a detail
           * outside its tag's values or text that is not valid UTF-8, or a
           * buffer too small for the record.
           */
          size_t erx_ui_write_event(uint8_t *buffer, size_t size, uint32_t node,
              uint8_t event, const erx_ui_detail_t *detail);

          /* A rectangle of a damage report: its top left corner and its size. */
          typedef struct erx_ui_rect erx_ui_rect_t;
          struct erx_ui_rect {
          	uint16_t	 x;
          	uint16_t	 y;
          	uint16_t	 width;
          	uint16_t	 height;
          };

          /*
           * Write a damage record, its length word included, to buffer[0..size):
           * the width and height the frame was drawn at, then the count
           * rectangles at rects, which must not overlap the buffer. Return the
           * bytes written, or 0, with nothing written, when the record is
           * refused: a count of 0 or above ERX_UI_DAMAGE_MAX, a rectangle of no
           * width or height or not within width and height, or a buffer too
           * small for the record.
           */
          size_t erx_ui_write_damage(uint8_t *buffer, size_t size, uint16_t width,
              uint16_t height, const erx_ui_rect_t *rects, size_t count);

          #endif /* !ERX_UI_WIRE_H */
        C
      end

      def enum_block(comment, pairs)
        width = pairs.map { |name, _| name.size }.max
        "/* #{comment} */\nenum {\n#{pairs.map { |name, value| "\t#{name.ljust(width)} = #{value}" }.join(",\n")}\n};\n"
      end

      def c_source(ui, stopgaps:, enums:)
        properties = wire_properties(ui)
        <<~C
          /*
           * Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
           * SPDX-License-Identifier: BSD-2-Clause
           * Generated by tools/gen_abi.rb from abi/formats/ui.txt.
           * Do not edit this file.
           *
           * The reader of the server's records and the writer of a renderer's
           * in ui.txt's binary form; see erx/ui_wire.h. Freestanding: it calls
           * nothing but the memset and memcpy the compiler emits to zero and
           * copy a record. Every count and length read from a record
           * is checked against what remains of it before it is used, and every
           * record written is checked against the caller's size before a byte
           * of it is.
           */

          #include <erx/ui_wire.h>

          /* What remains of one record's fields. */
          typedef struct erx_ui_cursor erx_ui_cursor_t;
          struct erx_ui_cursor {
          	const uint8_t	*next;
          	size_t		 left;
          };

          /*
           * A property's type: its form, an integer's bounds, a text's, bytes' or a
           * list's most bytes or entries, a list text's most bytes, an enum's or
           * image's members, and whether it carries a status block. Form 0 is a
           * number no property has on the wire, the key's included.
           */
          typedef struct erx_ui_type erx_ui_type_t;
          struct erx_ui_type {
          	const uint8_t	*members;
          	int32_t		 minimum;
          	int32_t		 maximum;
          	uint32_t	 limit;
          	uint32_t	 element_limit;
          	uint8_t		 nmembers;
          	uint8_t		 form;
          	bool		 status;
          };

          #{member_arrays(ui, enums)}
          static const erx_ui_type_t erx_ui_types[256] = {
          #{properties.map { |property| type_initializer(property) }.join(",\n")}
          };

          static const bool erx_ui_kinds[256] = {
          #{ui.kinds.map { |kind| "\t[#{macro('ui_kind', kind.name)}] = true" }.join(",\n")}
          };

          /* The inspection schema's stopgap reporters, the names a status may carry. */
          static const erx_ui_bytes_t erx_ui_stopgaps[] = {
          #{stopgaps.map { |name| "\t{ (const uint8_t *)\"#{name}\", #{name.bytesize} }" }.join(",\n")}
          };

          #{C_READER}
          #{UIFields.c_input(ui)}
          #{UIFields.c_fields(ui)}
          #{C_READ}
          #{kind_takes(ui)}
          #{C_WRITER}
        C
      end

      def member_arrays(ui, enums)
        arrays = enums.map { |type| [member_array_name(type), type.numbers] }
        arrays << ['erx_ui_image_members', ui.images.map(&:number).sort] unless ui.images.empty?
        arrays.map { |name, numbers| "static const uint8_t #{name}[] = { #{numbers.join(', ')} };\n" }.join
      end

      def member_array_name(type) = "erx_#{type.name.delete_prefix('@')}_members"

      def type_initializer(property)
        type = property.type
        fields = { 'form' => macro('ui_form', type.form) }
        case type.form
        when 'integer' then fields.merge!('minimum' => c_int32(type.minimum), 'maximum' => c_int32(type.maximum))
        when 'text', 'bytes' then fields['limit'] = type.maximum
        when 'list' then fields.merge!('limit' => type.maximum, 'element_limit' => type.element.maximum)
        when 'enum', 'image'
          array = type.form == 'image' ? 'erx_ui_image_members' : member_array_name(type)
          fields.merge!('members' => array, 'nmembers' => "sizeof(#{array})")
        end
        fields['status'] = 'true' if property.status
        "\t[#{macro('ui_prop', property.name)}] = { #{fields.map { |key, value| ".#{key} = #{value}" }.join(', ')} }"
      end

      # INT32_MIN is not a literal in C: write it as an expression.
      def c_int32(value) = value == -(1 << 31) ? '(-2147483647 - 1)' : value.to_s

      C_READER = <<~'C'
        static bool erx_ui_take(erx_ui_cursor_t *, size_t, const uint8_t **);
        static bool erx_ui_u8(erx_ui_cursor_t *, uint8_t *);
        static bool erx_ui_u16(erx_ui_cursor_t *, uint16_t *);
        static bool erx_ui_u32(erx_ui_cursor_t *, uint32_t *);
        static bool erx_ui_utf8(const uint8_t *, size_t);
        static bool erx_ui_text(erx_ui_cursor_t *, uint8_t, uint32_t,
            erx_ui_bytes_t *);
        static bool erx_ui_status(erx_ui_cursor_t *, erx_ui_prop_t *);
        static bool erx_ui_value(erx_ui_cursor_t *, const erx_ui_type_t *,
            erx_ui_prop_t *);
        static const char *erx_ui_props(erx_ui_cursor_t *, erx_ui_prop_t *,
            uint8_t *);
        static const char *erx_ui_removed(erx_ui_cursor_t *, uint8_t *, uint8_t *);

        static bool
        erx_ui_take(erx_ui_cursor_t *cursor, size_t count, const uint8_t **bytes)
        {
        	if (count > cursor->left)
        		return (false);
        	*bytes = cursor->next;
        	cursor->next += count;
        	cursor->left -= count;
        	return (true);
        }

        static bool
        erx_ui_u8(erx_ui_cursor_t *cursor, uint8_t *value)
        {
        	const uint8_t *bytes;

        	if (!erx_ui_take(cursor, 1, &bytes))
        		return (false);
        	*value = bytes[0];
        	return (true);
        }

        static bool
        erx_ui_u16(erx_ui_cursor_t *cursor, uint16_t *value)
        {
        	const uint8_t *bytes;

        	if (!erx_ui_take(cursor, 2, &bytes))
        		return (false);
        	*value = (uint16_t)(bytes[0] | (bytes[1] << 8));
        	return (true);
        }

        static bool
        erx_ui_u32(erx_ui_cursor_t *cursor, uint32_t *value)
        {
        	const uint8_t *bytes;

        	if (!erx_ui_take(cursor, 4, &bytes))
        		return (false);
        	*value = (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        	    ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
        	return (true);
        }

        /* Decode each scalar once, refusing overlong forms and surrogates. */
        static bool
        erx_ui_utf8(const uint8_t *bytes, size_t length)
        {
        	size_t continuation, cursor;
        	uint32_t minimum, point;
        	uint8_t first, next;

        	cursor = 0;
        	while (cursor < length) {
        		first = bytes[cursor++];
        		if (first < 0x80) {
        			continue;
        		} else if (first >= 0xc2 && first <= 0xdf) {
        			point = first & 0x1f;
        			continuation = 1;
        			minimum = 0x80;
        		} else if (first >= 0xe0 && first <= 0xef) {
        			point = first & 0x0f;
        			continuation = 2;
        			minimum = 0x800;
        		} else if (first >= 0xf0 && first <= 0xf4) {
        			point = first & 0x07;
        			continuation = 3;
        			minimum = 0x10000;
        		} else {
        			return (false);
        		}
        		if (continuation > length - cursor)
        			return (false);
        		for (size_t index = 0; index < continuation; index++) {
        			next = bytes[cursor++];
        			if ((next & 0xc0) != 0x80)
        				return (false);
        			point = (point << 6) | (next & 0x3f);
        		}
        		if (point < minimum || point > 0x10ffff ||
        		    (point >= 0xd800 && point <= 0xdfff))
        			return (false);
        	}
        	return (true);
        }

        /*
         * A length of width 1 or 4 bytes, at most limit, then that many bytes of
         * valid UTF-8.
         */
        static bool
        erx_ui_text(erx_ui_cursor_t *cursor, uint8_t width, uint32_t limit,
            erx_ui_bytes_t *text)
        {
        	uint32_t length;
        	uint8_t short_length;

        	if (width == 1) {
        		if (!erx_ui_u8(cursor, &short_length))
        			return (false);
        		length = short_length;
        	} else if (!erx_ui_u32(cursor, &length)) {
        		return (false);
        	}
        	if (length > limit || !erx_ui_take(cursor, length, &text->data))
        		return (false);
        	text->length = length;
        	return (erx_ui_utf8(text->data, length));
        }

        /*
         * The status block: a status and a reporter within their codes, a
         * stopgap's name that is a declared stopgap exactly when the reporter is
         * a stopgap, and a timeout that is set exactly when the status is
         * timeout. The application's own value is always ok.
         */
        static bool
        erx_ui_status(erx_ui_cursor_t *cursor, erx_ui_prop_t *prop)
        {
        	const erx_ui_bytes_t *known;
        	bool declared;

        	if (!erx_ui_u8(cursor, &prop->status) ||
        	    !erx_ui_u8(cursor, &prop->reporter) ||
        	    !erx_ui_text(cursor, 1, ERX_UI_NAME_MAX, &prop->stopgap) ||
        	    !erx_ui_u32(cursor, &prop->timeout_ms))
        		return (false);
        	if (prop->status > ERX_UI_STATUS_ERROR ||
        	    prop->reporter > ERX_UI_REPORTER_STOPGAP)
        		return (false);
        	if (prop->reporter == ERX_UI_REPORTER_OWN &&
        	    prop->status != ERX_UI_STATUS_OK)
        		return (false);
        	if ((prop->status == ERX_UI_STATUS_TIMEOUT) != (prop->timeout_ms != 0))
        		return (false);
        	declared = false;
        	for (size_t index = 0; index < sizeof(erx_ui_stopgaps) /
        	    sizeof(erx_ui_stopgaps[0]); index++) {
        		known = &erx_ui_stopgaps[index];
        		if (known->length != prop->stopgap.length)
        			continue;
        		declared = true;
        		for (uint32_t at = 0; at < known->length; at++) {
        			if (known->data[at] != prop->stopgap.data[at]) {
        				declared = false;
        				break;
        			}
        		}
        		if (declared)
        			break;
        	}
        	if (prop->reporter == ERX_UI_REPORTER_STOPGAP)
        		return (declared);
        	return (prop->stopgap.length == 0);
        }

        /* A value of TYPE, bounded by the type and by what remains. */
        static bool
        erx_ui_value(erx_ui_cursor_t *cursor, const erx_ui_type_t *type,
            erx_ui_prop_t *prop)
        {
        	erx_ui_bytes_t text;
        	uint32_t raw;
        	const uint8_t *start;
        	uint8_t small;
        	bool member;

        	prop->has_value = type->form != ERX_UI_FORM_EVENT;
        	switch (type->form) {
        	case ERX_UI_FORM_BOOLEAN:
        		if (!erx_ui_u8(cursor, &small) || small > 1)
        			return (false);
        		prop->integer = small;
        		return (true);
        	case ERX_UI_FORM_INTEGER:
        		if (!erx_ui_u32(cursor, &raw))
        			return (false);
        		/* Two's complement, read without an implementation-defined cast. */
        		prop->integer = raw <= INT32_MAX ? (int32_t)raw :
        		    (int32_t)(raw - 0x80000000U) - INT32_MAX - 1;
        		return (prop->integer >= type->minimum &&
        		    prop->integer <= type->maximum);
        	case ERX_UI_FORM_ENUM:
        	case ERX_UI_FORM_IMAGE:
        		if (!erx_ui_u8(cursor, &small))
        			return (false);
        		member = false;
        		for (uint8_t index = 0; index < type->nmembers; index++)
        			member = member || type->members[index] == small;
        		prop->integer = small;
        		return (member);
        	case ERX_UI_FORM_TEXT:
        		return (erx_ui_text(cursor, 4, type->limit, &prop->bytes));
        	case ERX_UI_FORM_BYTES:
        		if (!erx_ui_u32(cursor, &raw) || raw > type->limit)
        			return (false);
        		prop->bytes.length = raw;
        		return (erx_ui_take(cursor, raw, &prop->bytes.data));
        	case ERX_UI_FORM_LIST:
        		if (!erx_ui_u16(cursor, &prop->count) ||
        		    prop->count > type->limit)
        			return (false);
        		start = cursor->next;
        		for (uint16_t index = 0; index < prop->count; index++) {
        			if (!erx_ui_text(cursor, 4, type->element_limit, &text))
        				return (false);
        		}
        		prop->bytes.data = start;
        		/* Within one record, so below ERX_UI_OP_MAX. */
        		prop->bytes.length = (uint32_t)(cursor->next - start);
        		return (true);
        	case ERX_UI_FORM_EVENT:
        		return (true);
        	case ERX_UI_FORM_PRESENTATION:
        		return (erx_ui_text(cursor, 1, ERX_UI_NAME_MAX, &prop->name) &&
        		    erx_ui_text(cursor, 4, ERX_UI_PRESENT_MAX, &prop->bytes));
        	default:
        		return (false);
        	}
        }

        /* A u8 count and each property: a known number, once, and its value. */
        static const char *
        erx_ui_props(erx_ui_cursor_t *cursor, erx_ui_prop_t *props, uint8_t *nprops)
        {
        	const erx_ui_type_t *type;
        	erx_ui_prop_t *prop;
        	bool seen[256] = { false };
        	uint8_t count;

        	if (!erx_ui_u8(cursor, &count))
        		return (ERX_UI_REFUSAL_SHORT_RECORD);
        	if (count > ERX_UI_PROPERTY_MAX)
        		return (ERX_UI_REFUSAL_TOO_MANY_PROPERTIES);
        	for (uint8_t index = 0; index < count; index++) {
        		prop = &props[index];
        		*prop = (erx_ui_prop_t){ .status = ERX_UI_STATUS_OK };
        		if (!erx_ui_u8(cursor, &prop->number))
        			return (ERX_UI_REFUSAL_SHORT_RECORD);
        		type = &erx_ui_types[prop->number];
        		if (type->form == 0)
        			return (ERX_UI_REFUSAL_UNKNOWN_PROPERTY);
        		if (seen[prop->number])
        			return (ERX_UI_REFUSAL_PROPERTY_TWICE);
        		seen[prop->number] = true;
        		prop->form = type->form;
        		if (type->status && !erx_ui_status(cursor, prop))
        			return (ERX_UI_REFUSAL_BAD_STATUS);
        		if ((!type->status || prop->status <= ERX_UI_STATUS_PARTIAL) &&
        		    !erx_ui_value(cursor, type, prop))
        			return (ERX_UI_REFUSAL_BAD_VALUE);
        		*nprops = (uint8_t)(index + 1);
        	}
        	return (NULL);
        }

        /* A set's removals: a u8 count of known property numbers, each once. */
        static const char *
        erx_ui_removed(erx_ui_cursor_t *cursor, uint8_t *removed, uint8_t *nremoved)
        {
        	bool seen[256] = { false };
        	uint8_t count, number;

        	if (!erx_ui_u8(cursor, &count))
        		return (ERX_UI_REFUSAL_SHORT_RECORD);
        	if (count > ERX_UI_PROPERTY_MAX)
        		return (ERX_UI_REFUSAL_TOO_MANY_PROPERTIES);
        	for (uint8_t index = 0; index < count; index++) {
        		if (!erx_ui_u8(cursor, &number))
        			return (ERX_UI_REFUSAL_SHORT_RECORD);
        		if (erx_ui_types[number].form == 0)
        			return (ERX_UI_REFUSAL_UNKNOWN_PROPERTY);
        		if (seen[number])
        			return (ERX_UI_REFUSAL_PROPERTY_TWICE);
        		seen[number] = true;
        		removed[index] = number;
        		*nremoved = (uint8_t)(index + 1);
        	}
        	return (NULL);
        }

      C

      C_READ = <<~'C'
        erx_ui_result_t
        erx_ui_read(const uint8_t *buffer, size_t length, erx_ui_record_t *record,
            size_t *used)
        {
        	erx_ui_cursor_t cursor;
        	const char *reason;
        	uint32_t size;

        	*record = (erx_ui_record_t){ .reason = NULL };
        	if (length < 4)
        		return (ERX_UI_READ_MORE);
        	cursor = (erx_ui_cursor_t){ .next = buffer, .left = length };
        	(void)erx_ui_u32(&cursor, &size);
        	if (size == 0 || size > ERX_UI_OP_MAX) {
        		record->reason = ERX_UI_REFUSAL_BAD_LENGTH;
        		return (ERX_UI_READ_BAD);
        	}
        	if (size > cursor.left)
        		return (ERX_UI_READ_MORE);
        	cursor.left = size;
        	(void)erx_ui_u8(&cursor, &record->tag);
        	reason = erx_ui_fields(&cursor, record);
        	if (reason == NULL && cursor.left != 0)
        		reason = ERX_UI_REFUSAL_BYTES_LEFT_OVER;
        	if (reason != NULL) {
        		record->reason = reason;
        		return (ERX_UI_READ_BAD);
        	}
        	*used = 4 + (size_t)size;
        	return (ERX_UI_READ_OK);
        }

        bool
        erx_ui_list_next(const erx_ui_prop_t *list, uint32_t *cursor,
            erx_ui_bytes_t *text)
        {
        	const uint8_t *at;
        	uint32_t length;

        	if (*cursor > list->bytes.length || list->bytes.length - *cursor < 4)
        		return (false);
        	at = list->bytes.data + *cursor;
        	length = (uint32_t)at[0] | ((uint32_t)at[1] << 8) |
        	    ((uint32_t)at[2] << 16) | ((uint32_t)at[3] << 24);
        	if (length > list->bytes.length - *cursor - 4)
        		return (false);
        	text->data = at + 4;
        	text->length = length;
        	*cursor += 4 + length;
        	return (true);
        }
      C

      C_WRITER = <<~'C'
        static void erx_ui_put16(uint8_t *, uint16_t);
        static void erx_ui_put32(uint8_t *, uint32_t);

        static void
        erx_ui_put16(uint8_t *at, uint16_t value)
        {
        	at[0] = (uint8_t)value;
        	at[1] = (uint8_t)(value >> 8);
        }

        static void
        erx_ui_put32(uint8_t *at, uint32_t value)
        {
        	at[0] = (uint8_t)value;
        	at[1] = (uint8_t)(value >> 8);
        	at[2] = (uint8_t)(value >> 16);
        	at[3] = (uint8_t)(value >> 24);
        }

        /* An event record's tag, node, number and detail tag, before the value. */
        #define ERX_UI_EVENT_HEAD	(1 + 4 + 1 + 1)

        /*
         * The record is checked whole, then written: length word, the head,
         * and the detail's value, a u8 for a boolean, a signed u32 for an
         * integer, a u32 length and the bytes for a text.
         */
        size_t
        erx_ui_write_event(uint8_t *buffer, size_t size, uint32_t node,
            uint8_t event, const erx_ui_detail_t *detail)
        {
        	uint8_t *at;
        	uint32_t record, value;

        	if (node == 0 || erx_ui_types[event].form != ERX_UI_FORM_EVENT)
        		return (0);
        	switch (detail->tag) {
        	case ERX_UI_DETAIL_NONE:
        		value = 0;
        		break;
        	case ERX_UI_DETAIL_BOOLEAN:
        		if (detail->integer != 0 && detail->integer != 1)
        			return (0);
        		value = 1;
        		break;
        	case ERX_UI_DETAIL_INTEGER:
        		value = 4;
        		break;
        	case ERX_UI_DETAIL_TEXT:
        		if (detail->text.length > ERX_UI_EVENT_TEXT_MAX ||
        		    !erx_ui_utf8(detail->text.data, detail->text.length))
        			return (0);
        		value = 4 + detail->text.length;
        		break;
        	default:
        		return (0);
        	}
        	record = ERX_UI_EVENT_HEAD + value;
        	if (size < 4 || size - 4 < record)
        		return (0);
        	at = buffer;
        	erx_ui_put32(at, record);
        	at[4] = ERX_UI_EVENT;
        	erx_ui_put32(at + 5, node);
        	at[9] = event;
        	at[10] = detail->tag;
        	at += 4 + ERX_UI_EVENT_HEAD;
        	switch (detail->tag) {
        	case ERX_UI_DETAIL_BOOLEAN:
        		at[0] = (uint8_t)detail->integer;
        		break;
        	case ERX_UI_DETAIL_INTEGER:
        		erx_ui_put32(at, (uint32_t)detail->integer);
        		break;
        	case ERX_UI_DETAIL_TEXT:
        		erx_ui_put32(at, detail->text.length);
        		for (uint32_t index = 0; index < detail->text.length; index++)
        			at[4 + index] = detail->text.data[index];
        		break;
        	}
        	return (4 + (size_t)record);
        }

        size_t
        erx_ui_write_damage(uint8_t *buffer, size_t size, uint16_t width,
            uint16_t height, const erx_ui_rect_t *rects, size_t count)
        {
        	uint8_t *at;
        	uint32_t record;

        	if (count == 0 || count > ERX_UI_DAMAGE_MAX)
        		return (0);
        	for (size_t index = 0; index < count; index++)
        		if (rects[index].width == 0 || rects[index].height == 0 ||
        		    (uint32_t)rects[index].x + rects[index].width > width ||
        		    (uint32_t)rects[index].y + rects[index].height > height)
        			return (0);
        	/* The tag, the size, the count, and x, y, width and height of each. */
        	record = 1 + 2 * 2 + 1 + 4 * 2 * (uint32_t)count;
        	if (size < 4 || size - 4 < record)
        		return (0);
        	erx_ui_put32(buffer, record);
        	buffer[4] = ERX_UI_DAMAGE;
        	erx_ui_put16(buffer + 5, width);
        	erx_ui_put16(buffer + 7, height);
        	buffer[9] = (uint8_t)count;
        	at = buffer + 10;
        	for (size_t index = 0; index < count; index++, at += 4 * 2) {
        		erx_ui_put16(at, rects[index].x);
        		erx_ui_put16(at + 2, rects[index].y);
        		erx_ui_put16(at + 4, rects[index].width);
        		erx_ui_put16(at + 6, rects[index].height);
        	}
        	return (4 + (size_t)record);
        }
      C
    end
  end
end
