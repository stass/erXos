# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_erlang'

module Erx
  module ABI
    # Emits one Erlang grammar module for each protocol declaration: a
    # validating decoder of request and reply terms, the reply checks, the
    # read-only refusal set and checked builders. Every check it emits is a
    # total boolean function: a term of any other shape answers false, no
    # atom is created and no list is walked past its declared maximum. The
    # model is already closed (abi_protocol.rb), so this file only renders.
    class ProtocolEmitter
      BASE_CHECKS = {
        'u8' => 'is_integer(Value) andalso Value >= 0 andalso Value =< 16#ff',
        'u16' => 'is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffff',
        'u32' => 'is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffffffff',
        'u64' => 'is_integer(Value) andalso Value >= 0 andalso Value =< 16#ffffffffffffffff'
      }.freeze
      # Preloaded, so that erx_file_remote, a preloaded client, checks its requests and
      # replies with it: what this file emits calls only BIFs.
      OUTPUT_DIRECTORY = 'otp/erts/preloaded/src'
      REFUSAL_TESTS = {
        'empty' => 'Value =/= <<>>', 'dot' => 'Value =/= <<".">>', 'dotdot' => 'Value =/= <<"..">>'
      }.freeze
      REFUSAL_WORDS = { 'nul' => 'NUL', 'slash' => '"/"', 'empty' => 'empty', 'dot' => '"."',
                        'dotdot' => '".."' }.freeze

      def self.outputs(schema)
        schema.protocols.to_h do |protocol|
          ["#{OUTPUT_DIRECTORY}/#{protocol.fetch(:module)}.erl", new(protocol).emit]
        end.freeze
      end

      def initialize(protocol)
        @protocol = protocol
        @kinds = protocol.fetch(:kinds)
        @operations = protocol.fetch(:operations)
        @operations.each { |operation| distinct_variables!(operation) }
      end

      def emit
        [ErlangEmitter::NOTICE.chomp, header, exports, macros, decoding, requests, replies, checks,
         writes, directories, catalog, builders, kind_checks, helpers].join("\n\n") + "\n"
      end

      private

      def header
        <<~ERLANG.chomp
          %% The #{name} frame profile's term grammar (docs/design-files.md#the-file-protocol),
          %% from "protocol #{name}" in #{@protocol.fetch(:source)}. decode_request/1 checks a request
          %% term and decode_reply/2 a reply term against the request it answers. Every check is
          %% total: a term of any other shape is refused, never raised on, no atom is made and
          %% no list is walked past its declared maximum. The builders return a valid term or
          %% raise badarg.

          -module(#{@protocol.fetch(:module)}).
        ERLANG
      end

      def name = @protocol.fetch(:name)

      def exports
        builders = @operations.map { |operation| "#{operation.fetch(:name)}_request/#{operation.fetch(:request).size}" } +
                   @operations.select { |operation| operation.fetch(:reply) }
                              .map { |operation| "#{operation.fetch(:name)}_reply/#{operation.fetch(:reply).size}" } +
                   ['error_reply/1']
        # A server fitting a reply to a request's byte count sizes it as the wire would.
        packed = @kinds.select { |_, kind| kind[:packed] }.map { |kind_name, _| "packed_#{kind_name}/1" }
        ["-export([decode_request/1, decode_request_frame/1, decode_reply/2, writes/1,\n" \
         '         directory_fids/1, operations/0, message_type/1]).',
         export_list(packed + builders)].join("\n")
      end

      def export_list(functions)
        lines = functions.each_slice(4).map { |slice| slice.join(', ') }
        "-export([#{lines.join(",\n         ")}])."
      end

      # Every limit the table names becomes a macro of the same name.
      def macros
        numbers = @kinds.values.flat_map { |kind| [kind[:max], kind[:except], kind[:packed], *kind.fetch(:in, [])] } +
                  @operations.filter_map { |operation| operation[:writes] }
                             .flat_map { |rule| [rule[:value], *rule.fetch(:masks, [])] }
        defines = numbers.compact.select { |number| number.fetch(:constant) }.uniq
                         .sort_by { |number| number.fetch(:constant) }
                         .map { |number| "-define(#{macro(number)}, #{number.fetch(:value)})." }
        (defines + ["-define(ERRORS, [#{wrap(@protocol.fetch(:errors), 15)}])."]).join("\n")
      end

      def decoding
        <<~ERLANG.chomp
          %% {ok, Request} for a request of the table, {error, einval} for any other term.
          -spec decode_request(term()) -> {ok, tuple()} | {error, einval}.
          decode_request(Request) ->
              case valid_request(Request) of
                  true -> {ok, Request};
                  false -> {error, einval}
              end.

          %% A request as it travels, {#{name}, Alias, Owner, Request}: an invalid request is
          %% answered to its alias, and a frame without an alias has no one to answer.
          -spec decode_request_frame(term()) ->
              {ok, reference(), pid(), tuple()} | {error, reference(), einval} | error.
          decode_request_frame({#{name}, Alias, Owner, Request}) when is_reference(Alias) ->
              case is_pid(Owner) andalso valid_request(Request) of
                  true -> {ok, Alias, Owner, Request};
                  false -> {error, Alias, einval}
              end;
          decode_request_frame(_) ->
              error.

          %% {ok, Reply} for a reply of Request's operation that its checks hold to Request,
          %% {error, eio} for any other term. Request is the caller's own and must be valid.
          -spec decode_reply(tuple(), term()) -> {ok, term()} | {error, eio}.
          decode_reply(Request, Reply) ->
              case valid_request(Request) of
                  false -> erlang:error(badarg, [Request, Reply]);
                  true ->
                      case reply_shape(element(1, Request), Reply) andalso held_to(Request, Reply) of
                          true -> {ok, Reply};
                          false -> {error, eio}
                      end
              end.
        ERLANG
      end

      def requests
        clauses = @operations.map do |operation|
          fields = operation.fetch(:request)
          "valid_request(#{pattern(operation.fetch(:name), fields.map { |field, _| variable(field) })}) ->\n    " +
            conjunction(fields.map { |field, kind| "#{check(kind)}(#{variable(field)})" })
        end
        "%% Each operation's request, field by field in 9P2000.L's order.\n" +
          (clauses + ["valid_request(_) ->\n    false."]).join(";\n")
      end

      def replies
        clauses = @operations.select { |operation| operation.fetch(:reply) }.map do |operation|
          fields = operation.fetch(:reply)
          body = fields.empty? ? 'true' : conjunction(fields.map { |field, kind| "#{check(kind)}(#{variable(field)})" })
          shape = fields.empty? ? 'ok' : "{#{(['ok'] + fields.map { |field, _| variable(field) }).join(', ')}}"
          "reply_shape(#{operation.fetch(:name)}, #{shape}) ->\n    #{body}"
        end
        "%% A reply is an error the protocol names or the operation's own reply; an operation\n" \
          "%% the table marks refused has no reply but an error.\n" +
          (["reply_shape(_, {error, Posix}) ->\n    lists:member(Posix, ?ERRORS)"] + clauses +
           ["reply_shape(_, _) ->\n    false."]).join(";\n")
      end

      # Each check names a reply field and a request field; a variable the
      # check does not read is '_', and a reply variable that shares a request
      # variable's name takes the prefix Reply.
      def checks
        clauses = @operations.reject { |operation| operation.fetch(:checks).empty? }.map do |operation|
          read_request = operation.fetch(:checks).map { |item| item.dig(:request, :field) }
          read_reply = operation.fetch(:checks).map { |item| item.dig(:reply, :field) }
          request_names = operation.fetch(:request).map { |field, _| read_request.include?(field) ? variable(field) : '_' }
          reply_variable = lambda do |field|
            base = variable(field)
            request_names.include?(base) ? "Reply#{base}" : base
          end
          reply_names = operation.fetch(:reply).map { |field, _| read_reply.include?(field) ? reply_variable.call(field) : '_' }
          tests = operation.fetch(:checks).map do |item|
            relation(measure(item.fetch(:reply), reply_variable.call(item.dig(:reply, :field))),
                     item.fetch(:relation),
                     measure(item.fetch(:request), variable(item.dig(:request, :field))))
          end
          "held_to(#{pattern(operation.fetch(:name), request_names)}, {#{(['ok'] + reply_names).join(', ')}}) ->\n    " +
            conjunction(tests)
        end
        "%% A reply is held to its request (docs/design-files.md#bounds); an error reply and an\n" \
          "%% operation without checks hold.\n" + (clauses + ["held_to(_, _) ->\n    true."]).join(";\n")
      end

      def writes
        clauses = @operations.map do |operation|
          fields = operation.fetch(:request)
          rule = operation.fetch(:writes)
          field = rule && rule[:field]
          names = fields.map { |item, _| item == field ? variable(item) : '_' }
          body = case rule
                 in nil then 'false'
                 in { rule: 'always' } then 'true'
                 in { rule: 'any', masks: }
                   masks.map { |mask| "#{variable(field)} band #{literal(mask)} =/= 0" }.join(' orelse ')
                 in { rule: 'equal', value: } then "#{variable(field)} =:= #{literal(value)}"
                 end
          "writes(#{pattern(operation.fetch(:name), names)}) ->\n    #{body}"
        end
        "%% Whether a read-only grant refuses Request before any callback (F5). Request must\n" \
          "%% have passed decode_request/1.\n" \
          "-spec writes(tuple()) -> boolean().\n" + clauses.join(";\n") + '.'
      end

      # A clause for each operation and none for any other term, so an operation the
      # table adds answers its own list, empty or not, and never falls through.
      def directories
        clauses = @operations.map do |operation|
          listed = operation.fetch(:directories)
          pattern_names = operation.fetch(:request).map { |item, _| listed.include?(item) ? variable(item) : '_' }
          "directory_fids(#{pattern(operation.fetch(:name), pattern_names)}) ->\n    " \
            "[#{listed.map { |item| variable(item) }.join(', ')}]"
        end
        "%% The fids of Request that must name a directory (\"directory\" in the table), in\n" \
          "%% request order. Request must have passed decode_request/1.\n" \
          "-spec directory_fids(tuple()) -> [non_neg_integer()].\n" + clauses.join(";\n") + '.'
      end

      def catalog
        names = @operations.map { |operation| operation.fetch(:name) }
        types = @operations.map { |operation| "message_type(#{operation.fetch(:name)}) ->\n    #{operation.fetch(:type)}" }
        "%% The operations of the table and their 9P2000.L request message types.\n" \
          "-spec operations() -> [atom()].\noperations() ->\n    [#{wrap(names, 5)}].\n\n" \
          "-spec message_type(atom()) -> 0..255.\n" + types.join(";\n") + '.'
      end

      def builders
        requests = @operations.map do |operation|
          arguments = operation.fetch(:request).map { |field, _| variable(field) }
          "#{operation.fetch(:name)}_request(#{arguments.join(', ')}) ->\n" \
            "    checked_request(#{pattern(operation.fetch(:name), arguments)})."
        end
        replies = @operations.select { |operation| operation.fetch(:reply) }.map do |operation|
          arguments = operation.fetch(:reply).map { |field, _| variable(field) }
          term = arguments.empty? ? 'ok' : "{#{(['ok'] + arguments).join(', ')}}"
          "#{operation.fetch(:name)}_reply(#{arguments.join(', ')}) ->\n" \
            "    checked_reply(#{operation.fetch(:name)}, #{term})."
        end
        (["%% Builders: each returns the term it names when every field is valid, and raises\n" \
          "%% badarg otherwise. A reply builder checks the reply's shape; decode_reply/2 also\n" \
          '%% holds it to its request.'] + requests + replies +
         ["error_reply(Posix) ->\n    checked_reply(error, {error, Posix}).",
          "checked_request(Request) ->\n    case valid_request(Request) of\n" \
          "        true -> Request;\n        false -> erlang:error(badarg, [Request])\n    end.",
          "checked_reply(Operation, Reply) ->\n    case reply_shape(Operation, Reply) of\n" \
          "        true -> Reply;\n        false -> erlang:error(badarg, [Operation, Reply])\n    end."]).join("\n\n")
      end

      def kind_checks
        used_bases = (@kinds.values.flat_map { |kind| [kind[:base], *kind.fetch(:elements, []), kind[:element],
                                                       *kind.fetch(:fields, []).map(&:last)] } +
                      @operations.flat_map { |operation| (operation.fetch(:request) + (operation.fetch(:reply) || [])).map(&:last) })
                     .compact.uniq.select { |kind| BASE_CHECKS.key?(kind) }
        bases = BASE_CHECKS.select { |kind, _| used_bases.include?(kind) }
                           .map { |kind, test| "is_#{kind}(Value) ->\n    #{test}." }
        "%% The field kinds of the table.\n" +
          (bases + @kinds.map { |kind_name, kind| kind_check(kind_name, kind) }).join("\n\n")
      end

      def kind_check(kind_name, kind)
        "%% #{kind_name}: #{summary(kind)}.\n" + kind_body(kind_name, kind)
      end

      def summary(kind)
        case kind.fetch(:form)
        when 'integer' then integer_summary(kind)
        when 'text'
          refusals = kind.fetch(:refuse).map { |item| REFUSAL_WORDS.fetch(item) }
          ["at most #{literal(kind.fetch(:max))} bytes", kind.fetch(:utf8) ? 'of UTF-8' : nil].compact.join(' ') +
            (refusals.empty? ? '' : "; refuses #{refusals.join(', ')}")
        when 'tuple' then "{#{kind.fetch(:elements).join(', ')}}"
        when 'list' then "a list of at most #{literal(kind.fetch(:max))} #{kind.fetch(:element)}"
        when 'map'
          "a map of exactly the keys\n%%   #{wrap(kind.fetch(:fields).map(&:first), 5).gsub("\n     ", "\n%%   ")}"
        end
      end

      def integer_summary(kind)
        base = "a #{kind.fetch(:base)}"
        if kind[:max] then "#{base} of at most #{literal(kind[:max])}"
        elsif kind[:except] then "#{base} other than #{literal(kind[:except])}"
        elsif kind[:in] then kind[:in].map { |value| literal(value) }.join(' or ')
        else "#{base} or #{kind.fetch(:atom)}"
        end
      end

      def kind_body(kind_name, kind)
        case kind.fetch(:form)
        when 'integer' then integer_check(kind_name, kind)
        when 'text' then text_check(kind_name, kind)
        when 'tuple'
          elements = kind.fetch(:elements).each_index.map { |index| "E#{index + 1}" }
          "is_#{kind_name}({#{elements.join(', ')}}) ->\n    " +
            conjunction(kind.fetch(:elements).zip(elements).map { |element, item| "#{check(element)}(#{item})" }) +
            ";\nis_#{kind_name}(_) ->\n    false."
        when 'list' then list_check(kind_name, kind)
        when 'map'
          fields = kind.fetch(:fields)
          head = "is_#{kind_name}(\#{"
          keys = fields.map { |field, _| "#{field} := #{variable(field)}" }
                       .each_slice(4).map { |line| line.join(', ') }.join(",\n#{' ' * head.size}")
          "is_#{kind_name}(\#{#{keys}} = Value) when map_size(Value) =:= #{fields.size} ->\n    " +
            conjunction(fields.map { |field, item| "#{check(item)}(#{variable(field)})" }) +
            ";\nis_#{kind_name}(_) ->\n    false."
        end
      end

      def integer_check(kind_name, kind)
        base = "is_#{kind.fetch(:base)}(Value)"
        body = if kind[:max] then "#{base} andalso Value =< #{literal(kind[:max])}"
               elsif kind[:except] then "#{base} andalso Value =/= #{literal(kind[:except])}"
               elsif kind[:in] then kind[:in].map { |value| "Value =:= #{literal(value)}" }.join(' orelse ')
               else "Value =:= #{kind.fetch(:atom)} orelse #{base}"
               end
        "is_#{kind_name}(Value) ->\n    #{body}."
      end

      def text_check(kind_name, kind)
        refuse = kind.fetch(:refuse)
        searched = %w[nul slash].select { |item| refuse.include?(item) }
                                .map { |item| item == 'nul' ? '<<0>>' : '<<"/">>' }
        tests = ['is_binary(Value)', "byte_size(Value) =< #{literal(kind.fetch(:max))}"] +
                refuse.filter_map { |item| REFUSAL_TESTS[item] }
        tests << "binary:match(Value, [#{searched.join(', ')}]) =:= nomatch" unless searched.empty?
        tests << 'is_utf8(Value)' if kind.fetch(:utf8)
        "is_#{kind_name}(Value) ->\n    #{conjunction(tests)}."
      end

      def list_check(kind_name, kind)
        text = "is_#{kind_name}(Value) ->\n    is_list_of(fun #{check(kind.fetch(:element))}/1, Value, #{literal(kind.fetch(:max))})."
        return text unless kind[:packed]

        arity = @kinds.fetch(kind.fetch(:element)).fetch(:elements).size
        elements = (['_'] * (arity - 1) + ['Name']).join(', ')
        text + "\n\n%% #{kind_name} as 9P2000.L packs them: #{literal(kind[:packed])} bytes for each, and its text's.\n" \
               "packed_#{kind_name}(Entries) ->\n    packed_#{kind_name}(Entries, 0).\n\n" \
               "packed_#{kind_name}([{#{elements}} | Entries], Sum) ->\n" \
               "    packed_#{kind_name}(Entries, Sum + #{literal(kind[:packed])} + byte_size(Name));\n" \
               "packed_#{kind_name}([], Sum) ->\n    Sum."
      end

      def helpers
        lists = @kinds.values.any? { |kind| kind.fetch(:form) == 'list' }
        utf8 = @kinds.values.any? { |kind| kind[:utf8] }
        [lists ? "%% Walks at most Left elements of a proper list, and refuses any other term.\n" \
                 "is_list_of(_, [], _) ->\n    true;\n" \
                 "is_list_of(Check, [Head | Tail], Left) when Left > 0 ->\n" \
                 "    Check(Head) andalso is_list_of(Check, Tail, Left - 1);\n" \
                 "is_list_of(_, _, _) ->\n    false." : nil,
         utf8 ? "%% UTF-8 as the binary syntax matches it: no overlong form, surrogate or code point\n" \
                "%% past 16#10ffff.\nis_utf8(<<_/utf8, Rest/binary>>) ->\n    is_utf8(Rest);\n" \
                "is_utf8(<<>>) ->\n    true;\nis_utf8(_) ->\n    false." : nil].compact.join("\n\n")
      end

      def check(kind)
        kind == 'alias' ? 'is_reference' : "is_#{kind}"
      end

      def measure(item, variable)
        case item.fetch(:measure)
        when 'value' then variable
        when 'bytes' then "byte_size(#{variable})"
        when 'length' then "length(#{variable})"
        when 'packed' then "packed_#{item.fetch(:kind)}(#{variable})"
        end
      end

      def relation(left, relation, right)
        return "#{left} =< #{right}" if relation == 'le'

        "#{left} =< #{right} andalso (#{right} =:= 0 orelse #{left} >= 1)"
      end

      def pattern(operation, variables)
        "{#{([operation] + variables).join(', ')}}"
      end

      def conjunction(tests)
        tests.empty? ? 'true' : tests.join("\n        andalso ")
      end

      def variable(field)
        field.split('_').map(&:capitalize).join
      end

      # Two fields that would share a variable would make a pattern require
      # them equal, so the table may not hold them.
      def distinct_variables!(operation)
        request = operation.fetch(:request).map { |field, _| variable(field) }
        reply = (operation.fetch(:reply) || []).map { |field, _| variable(field) }
        prefixed = reply.map { |item| request.include?(item) ? "Reply#{item}" : item }
        return if [request, reply, request + prefixed].all? { |names| names.uniq.size == names.size }

        raise SchemaError, "operation #{operation.fetch(:name)} has fields that share an Erlang variable"
      end

      def macro(number)
        number.fetch(:constant).upcase
      end

      def literal(number)
        number.fetch(:constant) ? "?#{macro(number)}" : number.fetch(:value).to_s
      end

      # Joins items with ", " into lines of at most 92 columns after indent.
      def wrap(items, indent)
        lines = items.each_with_object([]) do |item, result|
          if result.empty? || result.last.size + item.size + 2 > 92 - indent
            result << item.dup
          else
            result.last << ', ' << item
          end
        end
        lines.join(",\n" + ' ' * indent)
      end
    end
  end
end
