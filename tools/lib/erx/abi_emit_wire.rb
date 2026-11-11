# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_erlang'
require_relative 'abi_emit_protocol'

module Erx
  module ABI
    # Emits the codec of a protocol's 9P2000.L bytes, named after the protocol
    # (erx_9p for "protocol erx_9p"): decode/2 turns one message's bytes into a
    # term and encode/2 a term into one message's bytes
    # (docs/design-files.md#the-codec). Its terms are the grammar's, with two
    # differences that the wire forces: an alias is the u16 tag 9P2000.L
    # carries, which a bridge maps to an alias, and a local field is not on the
    # wire, so it decodes as its atom. The kind checks are the grammar's own,
    # rendered by ProtocolEmitter from the same table, so the codec accepts
    # exactly the field values the grammar does. Decoding reads every length
    # and count against the bytes that remain, through binary matches that
    # cannot read past them, and makes no atom.
    class WireEmitter < ProtocolEmitter
      OUTPUT_DIRECTORY = 'erlang/apps/erx/src/generated'
      HEADER_BYTES = 7
      WIDTHS = { 'u8' => 8, 'u16' => 16, 'u32' => 32, 'u64' => 64 }.freeze
      # A field variable sits beside only the BinN variables of a chain of reads.
      CODE_VARIABLES = /\ABin\d+\z/

      def self.outputs(schema)
        schema.protocols.select { |protocol| protocol.key?(:operations) }.to_h do |protocol|
          ["#{OUTPUT_DIRECTORY}/#{protocol.fetch(:name)}.erl", new(protocol).emit]
        end.freeze
      end

      def initialize(protocol)
        super
        @kinds.each do |kind_name, kind|
          next unless kind[:atom] && !kind[:local]

          raise SchemaError, "kind #{kind_name} has no 9P2000.L form for #{kind[:atom]}: mark it local"
        end
        @kinds.each do |kind_name, kind|
          inner = [*kind.fetch(:elements, []), kind[:element], *kind.fetch(:fields, []).map(&:last)].compact
          local = inner.find { |item| @kinds.dig(item, :local) }
          raise SchemaError, "kind #{kind_name} holds the local kind #{local}, which the wire drops" if local
          next unless kind[:form] == 'list' && !kind[:packed] && kind.dig(:max, :value) > 65_535

          raise SchemaError, "list #{kind_name} counts its elements in a u16: max at most 65535"
        end
        fields = @operations.flat_map { |operation| operation.fetch(:request) + (operation.fetch(:reply) || []) } +
                 @kinds.values.flat_map { |kind| kind.fetch(:fields, []) }
        clash = fields.map { |field, _| variable(field) }.find { |name| name.match?(CODE_VARIABLES) }
        raise SchemaError, "field variable #{clash} clashes with the codec's own" if clash
      end

      def emit
        [ErlangEmitter::NOTICE.chomp, header, wire_macros, decode, messages, encode, bodies,
         fid_fields, operation_check, errors, getters, putters, kind_checks, helpers, wire_helpers].join("\n\n") + "\n"
      end

      private

      def header
        <<~ERLANG.chomp
          %% The #{name} frame profile's 9P2000.L codec (docs/design-files.md#the-codec), from
          %% "protocol #{name}" in #{@protocol.fetch(:source)}, for the edges where 9P2000.L's
          %% bytes cross: the host link, virtio-9p and the network.
          %%
          %% decode(Bytes, Msize) takes the bytes of one message, size[4] type[1] tag[2] and
          %% its fields, and returns {ok, Tag, Message} or {error, Reason}: msize when the size
          %% field exceeds Msize, size when it is not the number of bytes given, and
          %% {malformed, Tag} when the type is no message of the table or a field runs past
          %% the message, leaves bytes over or fails its kind's check, so that a bridge can
          %% answer that one tag. encode(Tag, Message) returns the bytes of one message and
          %% raises badarg for a term of any other shape; encode(Tag, Message, Msize) also
          %% refuses a message larger than Msize, as {error, msize}.
          %%
          %% A request Message is the grammar's request term (#{name}_grammar), except that an
          %% alias field is the u16 tag 9P2000.L carries, which the bridge maps to an alias.
          %% A reply Message is {reply, Operation, Reply}, Reply the grammar's reply term, and
          %% Rlerror decodes as {reply, error, {error, Posix}}, since its bytes name no
          %% operation; encoding writes Rlerror for {reply, Operation, {error, Posix}} of any
          %% operation. A field the table marks local is not on the wire: encoding drops it
          %% and decoding gives its atom. Decoding makes no atom; an error number of no error
          %% of the table decodes as eio (docs/design-files.md#errors).
          %%
          %% fids(Request) lists a request's fids, each with what the table says it names
          %% (directory, node, or new for a fid the request makes), and map_fids(Fun, Request)
          %% replaces each with Fun(Fid), so a bridge renames an edge's fids to its own from
          %% the table rather than from a list of its own.

          -module(#{name}).

          -export([decode/2, encode/2, encode/3, fids/1, map_fids/2]).
        ERLANG
      end

      def wire_macros
        numbers = @kinds.values.flat_map { |kind| [kind[:max], kind[:except], *kind.fetch(:values, [])] }
        defines = numbers.compact.select { |number| number.fetch(:constant) }.uniq
                         .sort_by { |number| number.fetch(:constant) }
                         .map { |number| "-define(#{macro(number)}, #{number.fetch(:value)})." }
        (["%% size[4] type[1] tag[2]\n-define(HEADER, #{HEADER_BYTES}).",
          "-define(ERROR_TYPE, #{@protocol.fetch(:error_type)})."] + defines).join("\n")
      end

      def decode
        <<~ERLANG.chomp
          -spec decode(binary(), #{HEADER_BYTES}..16#ffffffff) ->
              {ok, 0..16#ffff, tuple()} | {error, msize | size | {malformed, 0..16#ffff}}.
          decode(Bytes, Msize) when is_binary(Bytes), is_integer(Msize), Msize >= ?HEADER,
                                    Msize =< 16#ffffffff ->
              case Bytes of
                  <<Size:32/little, _/binary>> when Size > Msize ->
                      {error, msize};
                  <<Size:32/little, Type:8, Tag:16/little, Body/binary>> when Size =:= byte_size(Bytes) ->
                      case message(Type, Body) of
                          {ok, Message} -> {ok, Tag, Message};
                          error -> {error, {malformed, Tag}}
                      end;
                  _ ->
                      {error, size}
              end.
        ERLANG
      end

      # One clause for each request and each reply the table has, and one for Rlerror.
      def messages
        clauses = @operations.flat_map do |operation|
          request = message_clause(operation.fetch(:type), operation.fetch(:request),
                                   ->(values) { pattern(operation.fetch(:name), values) })
          reply = operation.fetch(:reply)
          next [request] unless reply

          [request, message_clause(operation.fetch(:type) + 1, reply,
                                   ->(values) { "{reply, #{operation.fetch(:name)}, #{reply_term(values)}}" })]
        end
        "%% The fields of each message type, in 9P2000.L's order.\n" +
          (clauses + ["message(?ERROR_TYPE, <<Number:32/little>>) ->\n    {ok, {reply, error, {error, posix(Number)}}}",
                      "message(_, _) ->\n    error."]).join(";\n")
      end

      def message_clause(type, fields, term)
        values = fields.map { |field, _| variable(field) }
        return "message(#{type}, <<>>) ->\n    {ok, #{term.call(values)}}" if fields.empty?

        "message(#{type}, Bin0) ->\n" + chain(fields.map(&:last), values, "{ok, #{term.call(values)}}", whole: true) +
          "\n    else\n        _ -> error\n    end"
      end

      # A maybe expression that reads a value of each kind in turn into values,
      # from Bin0 on, and then gives result. When whole, the last read must leave
      # no bytes, as a message's last field must; otherwise the bytes after the
      # last read are BinN, for result to hand back.
      def chain(kinds, values, result, whole:)
        steps = kinds.each_with_index.map do |kind, index|
          rest = whole && index == kinds.size - 1 ? '<<>>' : "Bin#{index + 1}"
          "        {ok, #{values[index]}, #{rest}} ?= #{getter(kind)}(Bin#{index})"
        end
        "    maybe\n" + (steps + ["        #{result}"]).join(",\n")
      end

      def reply_term(values)
        values.empty? ? 'ok' : "{#{(['ok'] + values).join(', ')}}"
      end

      def encode
        <<~ERLANG.chomp
          -spec encode(0..16#ffff, tuple()) -> binary().
          encode(Tag, Message) when is_integer(Tag), Tag >= 0, Tag =< 16#ffff ->
              case body(Message) of
                  {Type, Body} ->
                      Size = ?HEADER + byte_size(Body),
                      <<Size:32/little, Type:8, Tag:16/little, Body/binary>>;
                  invalid ->
                      erlang:error(badarg, [Tag, Message])
              end;
          encode(Tag, Message) ->
              erlang:error(badarg, [Tag, Message]).

          -spec encode(0..16#ffff, tuple(), #{HEADER_BYTES}..16#ffffffff) -> {ok, binary()} | {error, msize}.
          encode(Tag, Message, Msize) when is_integer(Msize), Msize >= ?HEADER, Msize =< 16#ffffffff ->
              Bytes = encode(Tag, Message),
              case byte_size(Bytes) =< Msize of
                  true -> {ok, Bytes};
                  false -> {error, msize}
              end;
          encode(Tag, Message, Msize) ->
              erlang:error(badarg, [Tag, Message, Msize]).
        ERLANG
      end

      # {Type, Fields} for a valid message, Fields its bytes, and invalid for any
      # other term. Every field is checked before any is written, so no value is
      # truncated to its width.
      def bodies
        error = "body({reply, Operation, {error, Posix}}) ->\n" \
                "    case known_operation(Operation) andalso errno(Posix) of\n" \
                "        Number when is_integer(Number) -> {?ERROR_TYPE, <<Number:32/little>>};\n" \
                "        _ -> invalid\n    end"
        clauses = @operations.flat_map do |operation|
          op = operation.fetch(:name)
          request = body_clause(operation.fetch(:type), operation.fetch(:request),
                                ->(values) { pattern(op, values) })
          reply = operation.fetch(:reply)
          next [request] unless reply

          [request,
           body_clause(operation.fetch(:type) + 1, reply, ->(values) { "{reply, #{op}, #{reply_term(values)}}" })]
        end
        "%% The message type and fields of a message term, or invalid.\n" +
          ([error] + clauses + ["body(_) ->\n    invalid."]).join(";\n")
      end

      def body_clause(type, fields, term)
        values = fields.map { |field, _| variable(field) }
        return "body(#{term.call(values)}) ->\n    {#{type}, <<>>}" if fields.empty?

        segments = fields.zip(values).filter_map { |(_, kind), value| segment(kind, value) }
        checks = fields.zip(values).map { |(_, kind), value| "#{check(kind)}(#{value})" }
        "body(#{term.call(values)}) ->\n    case #{conjunction(checks).gsub("\n", "\n    ")} of\n" \
          "        true ->\n            {#{type}, #{binary(segments, 13)}};\n        false ->\n            invalid\n    end"
      end

      # fids/1 and map_fids/2: a clause for each request of the table and none for any
      # other term, so a request the table adds lists its own fids and never falls through.
      def fid_fields
        listed = ->(operation) { operation.fetch(:fids).to_h }
        listing = @operations.map do |operation|
          fids = listed.call(operation)
          names = operation.fetch(:request).map { |field, _| fids.key?(field) ? variable(field) : '_' }
          "fids(#{pattern(operation.fetch(:name), names)}) ->\n    " \
            "[#{fids.map { |field, role| "{#{role}, #{variable(field)}}" }.join(', ')}]"
        end
        mapping = @operations.map do |operation|
          fids = listed.call(operation)
          names = operation.fetch(:request).map { |field, _| variable(field) }
          mapped = operation.fetch(:request).map { |field, _| fids.key?(field) ? "Fun(#{variable(field)})" : variable(field) }
          "map_fids(#{fids.empty? ? "_Fun" : "Fun"}, #{pattern(operation.fetch(:name), names)}) ->\n    #{pattern(operation.fetch(:name), mapped)}"
        end
        "%% The fids of a request term, in request order, each with what it names.\n" \
          "-spec fids(tuple()) -> [{directory | node | new, non_neg_integer()}].\n" + listing.join(";\n") + ".\n\n" \
          "%% A request term with each of its fids replaced by Fun(Fid).\n" \
          "-spec map_fids(fun((non_neg_integer()) -> non_neg_integer()), tuple()) -> tuple().\n" +
          mapping.join(";\n") + '.'
      end

      def operation_check
        names = ['error'] + @operations.map { |operation| operation.fetch(:name) }
        "%% Whether Operation is an operation of the table, or error: an error reply may\n" \
          "%% answer any operation.\n" \
          "known_operation(Operation) ->\n    lists:member(Operation, [#{wrap(names, 29)}])."
      end

      def errors
        numbers = @protocol.fetch(:error_numbers)
        to_number = numbers.map { |atom, number| "errno(#{atom}) ->\n    #{number}" }
        to_atom = numbers.map { |atom, number| "posix(#{number}) ->\n    #{atom}" }
        "%% Linux's number of each error of the table, which Rlerror carries, and none for any\n" \
          "%% other term.\n" + (to_number + ["errno(_) ->\n    none."]).join(";\n") + "\n\n" \
          "%% The error of a number Rlerror carries; a number of no error of the table, as a\n" \
          "%% server answers in another system's numbering, reads as eio.\n" +
          (to_atom + ["posix(_) ->\n    eio."]).join(";\n")
      end

      # get_KIND(Bin) returns {ok, Value, Rest} or error, for each base kind a
      # field, element or member names and each kind of the table.
      def getters
        bases = used_wire_bases.map do |base|
          "get_#{base}(<<Value:#{width(base)}, Rest/binary>>) ->\n    {ok, Value, Rest};\nget_#{base}(_) ->\n    error."
        end
        "%% Each kind read from the front of the bytes: {ok, Value, Rest} or error.\n" +
          (bases + @kinds.map { |kind_name, kind| kind_getter(kind_name, kind) }).join("\n\n")
      end

      def kind_getter(kind_name, kind)
        get = "get_#{kind_name}"
        case kind.fetch(:form)
        when 'integer'
          return "#{get}(Bin0) ->\n    {ok, #{kind.fetch(:atom)}, Bin0}." if kind[:local]

          "#{get}(<<Value:#{width(kind.fetch(:base))}, Rest/binary>>) ->\n    checked(is_#{kind_name}(Value), Value, Rest);\n" \
            "#{get}(_) ->\n    error."
        when 'text'
          "#{get}(<<Size:#{width(kind.fetch(:length))}, Value:Size/binary, Rest/binary>>) ->\n" \
            "    checked(is_#{kind_name}(Value), Value, Rest);\n#{get}(_) ->\n    error."
        when 'tuple'
          values = kind.fetch(:elements).each_index.map { |index| "E#{index + 1}" }
          "#{get}(Bin0) ->\n" + chain(kind.fetch(:elements), values, "{ok, {#{values.join(', ')}}, Bin#{values.size}}",
                                      whole: false) + "\n    end."
        when 'map'
          fields = kind.fetch(:fields)
          values = fields.map { |field, _| variable(field) }
          map = wrap(fields.zip(values).map { |(field, _), value| "#{field} => #{value}" }, 15)
          "#{get}(Bin0) ->\n" + chain(fields.map(&:last), values, "{ok, \#{#{map}},\n         Bin#{values.size}}",
                                      whole: false) + "\n    end."
        when 'list' then list_getter(get, kind)
        end
      end

      def list_getter(get, kind)
        element = "fun #{getter(kind.fetch(:element))}/1"
        if kind[:packed]
          "#{get}(<<Size:32/little, Packed:Size/binary, Rest/binary>>) ->\n" \
            "    case packed_elements(#{element}, Packed, #{literal(kind.fetch(:max))}, []) of\n" \
            "        {ok, Values} -> {ok, Values, Rest};\n        error -> error\n    end;\n#{get}(_) ->\n    error."
        else
          "#{get}(<<Size:16/little, Rest/binary>>) when Size =< #{literal(kind.fetch(:max))} ->\n" \
            "    elements(#{element}, Size, Rest, []);\n#{get}(_) ->\n    error."
        end
      end

      # put_KIND(Value) returns the bytes of a valid value of each tuple, map and
      # list kind; integers and texts are segments of the binary that holds them.
      def putters
        compound = @kinds.select { |_, kind| %w[tuple map list].include?(kind.fetch(:form)) }
        "%% Each compound kind's bytes, for a value its kind check accepts.\n" +
          compound.map { |kind_name, kind| kind_putter(kind_name, kind) }.join("\n\n")
      end

      def kind_putter(kind_name, kind)
        put = "put_#{kind_name}"
        case kind.fetch(:form)
        when 'tuple'
          values = kind.fetch(:elements).each_index.map { |index| "E#{index + 1}" }
          segments = kind.fetch(:elements).zip(values).filter_map { |element, value| segment(element, value) }
          "#{put}({#{values.join(', ')}}) ->\n    #{binary(segments, 6)}."
        when 'map'
          fields = kind.fetch(:fields)
          keys = wrap(fields.map { |field, _| "#{field} := #{variable(field)}" }, put.size + 3)
          segments = fields.filter_map { |field, item| segment(item, variable(field)) }
          "#{put}(\#{#{keys}}) ->\n    #{binary(segments, 6)}."
        when 'list'
          element = segment(kind.fetch(:element), 'Value')
          if kind[:packed]
            "#{put}(Values) ->\n    Packed = << <<#{element}>> || Value <- Values >>,\n" \
              "    <<(byte_size(Packed)):32/little, Packed/binary>>."
          else
            "#{put}(Values) ->\n    <<(length(Values)):16/little,\n      (<< <<#{element}>> || Value <- Values >>)/binary>>."
          end
        end
      end

      # The segments that write value as kind in a binary expression, or nil for a
      # local field, which the wire does not carry.
      def segment(kind, value)
        definition = @kinds[kind]
        return "#{value}:#{width(base_kind(kind))}" unless definition

        case definition.fetch(:form)
        when 'integer' then definition[:local] ? nil : "#{value}:#{width(definition.fetch(:base))}"
        when 'text' then "(byte_size(#{value})):#{width(definition.fetch(:length))}, #{value}/binary"
        else "(put_#{kind}(#{value}))/binary"
        end
      end

      # A binary expression of segments, its lines wrapped to start at column indent + 2.
      def binary(segments, indent) = "<<#{wrap(segments, indent + 2)}>>"

      def width(base) = base == 'u8' ? '8' : "#{WIDTHS.fetch(base)}/little"

      def getter(kind) = @kinds.key?(kind) ? "get_#{kind}" : "get_#{base_kind(kind)}"

      def check(kind) = "is_#{base_kind(kind)}"

      # The codec sizes a packed list from the bytes, so it needs no packed_KIND/1.
      def list_check(kind_name, kind) = super(kind_name, kind.except(:packed))

      # On the wire an alias is the u16 tag it stands for.
      def base_kind(kind) = kind == 'alias' ? 'u16' : kind

      def used_wire_bases
        named = @operations.flat_map { |operation| (operation.fetch(:request) + (operation.fetch(:reply) || [])).map(&:last) } +
                @kinds.values.flat_map { |kind| [*kind.fetch(:elements, []), kind[:element], *kind.fetch(:fields, []).map(&:last)] }
        named.compact.map { |kind| base_kind(kind) }.uniq.select { |kind| WIDTHS.key?(kind) }
             .sort_by { |kind| WIDTHS.fetch(kind) }
      end

      CHECKED = <<~ERLANG.chomp
        %% A value read from the bytes, kept when its kind's check accepts it.
        checked(true, Value, Rest) ->
            {ok, Value, Rest};
        checked(false, _, _) ->
            error.
      ERLANG
      ELEMENTS = <<~ERLANG.chomp
        %% Count elements read one after another.
        elements(_, 0, Rest, Values) ->
            {ok, lists:reverse(Values), Rest};
        elements(Get, Count, Bin0, Values) ->
            case Get(Bin0) of
                {ok, Value, Rest} -> elements(Get, Count - 1, Rest, [Value | Values]);
                error -> error
            end.
      ERLANG
      PACKED_ELEMENTS = <<~ERLANG.chomp
        %% Elements read until the packed bytes end exactly, at most Left of them.
        packed_elements(_, <<>>, _, Values) ->
            {ok, lists:reverse(Values)};
        packed_elements(Get, Bin0, Left, Values) when Left > 0 ->
            case Get(Bin0) of
                {ok, Value, Rest} -> packed_elements(Get, Rest, Left - 1, [Value | Values]);
                error -> error
            end;
        packed_elements(_, _, _, _) ->
            error.
      ERLANG

      # The helpers the getters call: checked/3 from the getter of every text and
      # of every integer kind that is on the wire, elements/4 from an unpacked
      # list's, packed_elements/4 from a packed list's. Only those used are
      # emitted, since the module compiles with warnings as errors.
      def wire_helpers
        kinds = @kinds.values
        lists = kinds.select { |kind| kind.fetch(:form) == 'list' }
        { CHECKED => kinds.any? { |kind| %w[text integer].include?(kind.fetch(:form)) && !kind[:local] },
          ELEMENTS => lists.any? { |kind| !kind[:packed] },
          PACKED_ELEMENTS => lists.any? { |kind| kind[:packed] } }.select { |_, used| used }.keys.join("\n\n")
      end
    end
  end
end
