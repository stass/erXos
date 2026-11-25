# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_model'
require_relative 'abi_emit_erlang'

module Erx
  module ABI
    # Emits the Erlang grammar of a frame protocol (docs/design-abi.md,
    # "Program protocol"): check_FRAME/1 for each frame (check_FRAME/2 for a
    # reply frame, taking Busy, the request case each busy slot holds),
    # check_from_program/1 and check_to_program/2 over the channel's frames,
    # those tagged with the protocol's own name, each answering ok or
    # {error, {Reason, Kind}}, and a builder per frame. Each kind becomes k_KIND(Value, Acc), which
    # answers {ok, Acc} or the refusal; Acc carries what the frame-wide rules
    # need (the sums of each total, the unique values seen, the values each
    # refers names and the keys it may name), judged once the walk ends. The
    # checks call only BIFs, make no atom (every atom they compare with is a
    # literal here, so it exists before any frame is decoded), walk no list
    # past its maximum and answer any term. The model is closed
    # (abi_profile.rb), so this file only renders.
    class FrameGrammarEmitter
      OUTPUT_DIRECTORY = 'otp/erts/preloaded/src'
      BASE_MAX = { 'u8' => 0xff, 'u16' => 0xffff, 'u32' => 0xffff_ffff, 'u64' => 0xffff_ffff_ffff_ffff }.freeze
      PLAIN_ATOM = /\A[a-z][a-zA-Z0-9_@]*\z/

      def initialize(protocol, frame_max:)
        @protocol = protocol
        @kinds = protocol.fetch(:kinds)
        @frames = protocol.fetch(:frames)
        @frame_max = frame_max
        @targets = protocol.fetch(:refers).to_h { |item| [item.fetch(:list), item] }
      end

      def emit
        [ErlangEmitter::NOTICE.chomp, header, exports, macros, frames, dispatch, finish, builders,
         kind_checks, sorters, helpers].join("\n\n") + "\n"
      end

      private

      def name = @protocol.fetch(:name)

      def header
        <<~ERLANG.chomp
          %% The #{name} frame profile's term grammar (docs/design-abi.md#program-protocol), from
          %% "protocol #{name}" in #{@protocol.fetch(:source)}. check_FRAME/1 judges a whole frame
          %% and answers ok or {error, {Reason, Kind}}, Kind the profile's name of what was
          %% judged; liberx's C check names the same refusals. Every check is total: any term is
          %% answered, never raised on, no atom is made and no list is walked past its maximum.
          %% Each builder sorts the ascending lists, checks the frame and its encoded size, and
          %% answers {ok, Frame} or the refusal.

          -module(#{@protocol.fetch(:module)}).
        ERLANG
      end

      def exports
        checks = @frames.map { |frame| "check_#{frame.fetch(:name)}/#{reply?(frame) ? 2 : 1}" }
        builds = @frames.flat_map do |frame|
          arity = builder_args(frame).size
          ["frame_#{frame.fetch(:name)}/#{arity}", "build_#{frame.fetch(:name)}/#{arity}"]
        end
        "-export([#{(checks + %w[check_from_program/1 check_to_program/2] + builds).join(', ')}])."
      end

      def macros
        numbers = @kinds.values.flat_map do |kind|
          [kind[:min], kind[:max], kind[:except], *kind.fetch(:values, [])]
        end + @protocol.fetch(:totals).values + [@frame_max]
        defines = numbers.compact.select { |number| number.fetch(:constant) }.uniq { |number| number.fetch(:constant) }
                         .sort_by { |number| number.fetch(:constant) }
                         .map { |number| "-define(#{number.fetch(:constant).upcase}, #{number.fetch(:value)})." }
        (defines + ["-define(VERSION, #{@protocol.fetch(:version)})."]).join("\n")
      end

      def reply?(frame) = frame.key?(:replies)

      # The envelope {Tag, Version, [Slot,] Value}: another shape or tag is
      # shape, another version version, both of the frame's own name. A reply
      # frame's check takes Busy too, a map from each busy slot to the request
      # case it holds, and judges its value by that case's reply kind.
      def frames
        @frames.map do |frame|
          frame_name = frame.fetch(:name)
          tag = atom(frame.fetch(:tag))
          busy = reply?(frame) ? ['Busy'] : []
          ignored = reply?(frame) ? ['_'] : []
          head = frame.fetch(:slot) ? "{#{tag}, ?VERSION, Slot, Value}" : "{#{tag}, ?VERSION, Value}"
          value = ->(acc) { reply?(frame) ? "#{frame_name}_value(Busy, Slot, Value, #{acc})" : "k_#{frame.fetch(:kind)}(Value, #{acc})" }
          body = "finish(#{value.call('acc()')})"
          body = "case k_slot(Slot, acc()) of\n        {ok, Acc} -> finish(#{value.call('Acc')});\n" \
                 "        Error -> Error\n    end" if frame.fetch(:slot)
          other = frame.fetch(:slot) ? "{#{tag}, _, _, _}" : "{#{tag}, _, _}"
          check = "%% The #{frame_name} frame, #{frame.fetch(:direction)} the program.\n" \
                  "-spec check_#{frame_name}(#{(['term()'] * (1 + busy.size)).join(', ')}) -> ok | {error, {atom(), atom()}}.\n" \
                  "check_#{frame_name}(#{[head, *busy].join(', ')}) ->\n    #{body};\n" \
                  "check_#{frame_name}(#{[other, *ignored].join(', ')}) ->\n    {error, {version, #{atom(frame_name)}}};\n" \
                  "check_#{frame_name}(#{['_', *ignored].join(', ')}) ->\n    {error, {shape, #{atom(frame_name)}}}."
          reply?(frame) ? "#{check}\n\n#{reply_value(frame)}" : check
        end.join("\n\n")
      end

      # FRAME_value(Busy, Slot, Value, Acc): Value judged as the reply the
      # request case Busy holds on Slot takes. A slot Busy holds no case on is
      # idle, and a reply on it is refused as a range of slot.
      def reply_value(frame)
        function = "#{frame.fetch(:name)}_value"
        clauses = frame.fetch(:replies).map do |request, reply|
          "#{function}(#{atom(request)}, Value, Acc) ->\n    k_#{reply}(Value, Acc)"
        end
        "#{function}(Busy, Slot, Value, Acc) ->\n    case Busy of\n" \
          "        \#{Slot := Request} -> #{function}(Request, Value, Acc);\n" \
          "        _ -> {error, {range, slot}}\n    end.\n\n" +
          (clauses + ["#{function}(_, _, _) ->\n    {error, {range, slot}}"]).join(";\n") + '.'
      end

      # A channel's frame of each direction, one tagged with the protocol's
      # own name, goes to the check its tag and arity select; any other term
      # is refused by the direction's first such frame. A frame of another
      # tag, the startup message, has its own check alone.
      def dispatch
        %w[from to].map do |direction|
          function = direction == 'from' ? 'check_from_program' : 'check_to_program'
          frames = @frames.select { |frame| frame.fetch(:direction) == direction && frame.fetch(:tag) == name }
          # The to direction's dispatch takes Busy, which only a reply frame's check reads.
          busy = ->(frame) { direction == 'to' ? [frame && reply?(frame) ? 'Busy' : '_'] : [] }
          call = ->(frame) { "check_#{frame.fetch(:name)}(#{['Frame', *(reply?(frame) ? ['Busy'] : [])].join(', ')})" }
          clauses = frames.map do |frame|
            envelope = "{#{atom(frame.fetch(:tag))}#{', _' * (frame.fetch(:slot) ? 3 : 2)}} = Frame"
            "#{function}(#{[envelope, *busy.call(frame)].join(', ')}) ->\n    #{call.call(frame)}"
          end
          first = frames.first
          fallback = first ? call.call(first) : '{error, {shape, frame}}'
          # One frame takes every term, so its clause is the fallback alone.
          clauses = [] if frames.size == 1
          note = direction == 'to' ? "\n%% Busy maps each busy slot to the request case it holds." : ''
          "%% A frame #{direction} the program.#{note}\n" \
            "-spec #{function}(#{direction == 'from' ? 'term()' : 'term(), term()'}) -> ok | {error, {atom(), atom()}}.\n" +
            (clauses + ["#{function}(#{['Frame', *busy.call(first)].join(', ')}) ->\n    #{fallback}"]).join(";\n") + '.'
        end.join("\n\n")
      end

      # The frame-wide rules, once the walk ends: each total, then each
      # refers. A unique value is refused as soon as it repeats.
      def finish
        totals = @protocol.fetch(:totals)
        refers = @protocol.fetch(:refers).map { |item| atom(item.fetch(:kind)) }
        rules = totals.map { |total, max| "fun(A) -> total(#{atom(total)}, #{literal(max)}, A) end" } +
                refers.map { |item| "fun(A) -> refers(#{item}, A) end" }
        sums = totals.keys.map { |total| "#{atom(total)} => 0" }.join(', ')
        "acc() ->\n    \#{sums => \#{#{sums}}, unique => \#{}, refers => 0,\n" \
          "      referred => \#{#{refers.map { |item| "#{item} => []" }.join(', ')}},\n" \
          "      targets => \#{#{refers.map { |item| "#{item} => \#{}" }.join(', ')}}}.\n\n" \
          "finish({ok, Acc}) ->\n    rules([#{rules.join(",\n           ")}], Acc);\n" \
          "finish(Error) ->\n    Error."
      end

      # A reply frame's builder takes first the request case its slot holds.
      # frame_FRAME makes the frame and checks nothing, for a sender whose
      # values are all its own, which the grammar would only re-validate;
      # build_FRAME makes the same frame and checks it, for values from beyond
      # the sender.
      def builders
        @frames.map do |frame|
          frame_name = frame.fetch(:name)
          tag = atom(frame.fetch(:tag))
          args = builder_args(frame).join(', ')
          spec_args = (['term()'] * builder_args(frame).size).join(', ')
          term = frame.fetch(:slot) ? "{#{tag}, ?VERSION, Slot, #{sorted(frame)}}" : "{#{tag}, ?VERSION, #{sorted(frame)}}"
          check = reply?(frame) ? "check_#{frame_name}(Frame, \#{Slot => Request})" : "check_#{frame_name}(Frame)"
          "%% The #{frame_name} frame of Value, its ascending lists sorted, unchecked.\n" \
            "-spec frame_#{frame_name}(#{spec_args}) -> tuple().\n" \
            "frame_#{frame_name}(#{args}) ->\n    #{term}.\n\n" \
            "%% The #{frame_name} frame of Value, its ascending lists sorted (a repeated key is kept, so\n" \
            "%% the check refuses it), or the refusal: the check's, or size past #{literal(@frame_max)} bytes.\n" \
            "-spec build_#{frame_name}(#{spec_args}) -> {ok, tuple()} | {error, {atom(), atom()}}.\n" \
            "build_#{frame_name}(#{args}) ->\n    Frame = frame_#{frame_name}(#{args}),\n" \
            "    case #{check} of\n" \
            "        ok ->\n            case byte_size(term_to_binary(Frame)) =< #{literal(@frame_max)} of\n" \
            "                true -> {ok, Frame};\n                false -> {error, {size, #{atom(frame_name)}}}\n" \
            "            end;\n        Error ->\n            Error\n    end."
        end.join("\n\n")
      end

      # A builder's arguments: the request case for a reply frame, the slot for a
      # frame that has one, and the value.
      def builder_args(frame) = [*(reply?(frame) ? ['Request'] : []), *(frame.fetch(:slot) ? ['Slot'] : []), 'Value']

      # Value with the ascending lists of the frame's kind sorted; for a reply
      # frame, of the reply kind its request case takes.
      def sorted(frame)
        return sorts?(frame.fetch(:kind)) ? "sort_#{frame.fetch(:kind)}(Value)" : 'Value' unless reply?(frame)

        sorting = frame.fetch(:replies).select { |_, reply| sorts?(reply) }
        return 'Value' if sorting.empty?

        arms = sorting.map { |request, reply| "#{atom(request)} -> sort_#{reply}(Value)" } + ['_ -> Value']
        "case Request of #{arms.join('; ')} end"
      end

      def kind_checks
        builtins = Protocols::FRAME_BUILTINS.select { |builtin| used?(builtin) }
        bases = BASE_MAX.keys.select { |base| used?(base) }
        slot = @frames.any? { |frame| frame.fetch(:slot) }
        parts = @kinds.map { |kind_name, kind| "%% #{kind_name}\n#{kind_check(kind_name, kind)}" }
        parts += bases.map { |base| "k_#{base}(V, Acc) when is_integer(V) ->\n    range(V >= 0 andalso V =< #{BASE_MAX.fetch(base)}, #{base}, Acc);\nk_#{base}(_, _) ->\n    {error, {shape, #{base}}}." }
        parts << "k_slot(V, Acc) when is_integer(V) ->\n    range(V >= 0 andalso V =< #{Protocols::Profile::SLOTS - 1}, slot, Acc);\nk_slot(_, _) ->\n    {error, {shape, slot}}." if slot
        parts << "k_boolean(V, Acc) when is_boolean(V) ->\n    {ok, Acc};\nk_boolean(_, _) ->\n    {error, {shape, boolean}}." if builtins.include?('boolean')
        parts += @protocol.fetch(:named).map { |word, rows| named_check(word, rows) }
        parts.join("\n\n")
      end

      def used?(kind_name)
        @kinds.values.any? do |kind|
          [*kind.fetch(:elements, []), kind[:element], *kind.fetch(:fields, []).map(&:last),
           *kind.fetch(:cases, []).flat_map { |item| item.fetch(:fields) }].include?(kind_name)
        end || @frames.any? { |frame| Protocols::Profile.frame_kinds(frame).include?(kind_name) }
      end

      def kind_check(kind_name, kind)
        case kind.fetch(:form)
        when 'integer' then integer_check(kind_name, kind)
        when 'text' then text_check(kind_name, kind)
        when 'tuple'
          elements = kind.fetch(:elements).each_index.map { |index| "E#{index + 1}" }
          "k_#{kind_name}({#{elements.join(', ')}}, Acc) ->\n    all([#{pairs(kind.fetch(:elements), elements)}], Acc);\n" \
            "k_#{kind_name}(_, _) ->\n    {error, {shape, #{atom(kind_name)}}}."
        when 'list' then list_check(kind_name, kind)
        when 'map' then map_check(kind_name, kind)
        when 'union' then union_check(kind_name, kind)
        end
      end

      def integer_check(kind_name, kind)
        tests = ["V >= #{kind[:min] ? literal(kind[:min]) : 0}",
                 "V =< #{kind[:max] ? literal(kind[:max]) : BASE_MAX.fetch(kind.fetch(:base))}"]
        tests = ["V >= 0", "V =< #{BASE_MAX.fetch(kind.fetch(:base))}",
                 "(#{kind[:values].map { |value| "V =:= #{literal(value)}" }.join(' orelse ')})"] if kind[:values]
        tests << "V =/= #{literal(kind[:except])}" if kind[:except]
        accept = if kind[:unique] then "unique(V, #{atom(kind_name)}, Acc)"
                 elsif kind[:refers] then "refer(V, #{atom(kind_name)}, Acc)"
                 else 'Acc'
                 end
        "k_#{kind_name}(V, Acc) when is_integer(V) ->\n    case #{tests.join(' andalso ')} of\n" \
          "        true -> #{kind[:unique] ? accept : "{ok, #{accept}}"};\n        false -> {error, {range, #{atom(kind_name)}}}\n    end;\n" \
          "k_#{kind_name}(_, _) ->\n    {error, {shape, #{atom(kind_name)}}}."
      end

      def text_check(kind_name, kind)
        rules = [kind.fetch(:utf8) ? 'utf8' : nil, kind.fetch(:refuse).include?('nul') ? 'nul' : nil,
                 kind.fetch(:assign) ? 'assign' : nil, kind.fetch(:path) ? 'path' : nil].compact
        accept = kind[:sum] ? "{ok, sum(#{atom(kind[:sum])}, byte_size(V) + 1, Acc)}" : '{ok, Acc}'
        "k_#{kind_name}(V, Acc) ->\n    case text(V, #{literal(kind.fetch(:max))}, [#{rules.join(', ')}], #{atom(kind_name)}) of\n" \
          "        ok -> #{accept};\n        Error -> Error\n    end."
      end

      def list_check(kind_name, kind)
        target = @targets[kind_name] ? atom(@targets.fetch(kind_name).fetch(:kind)) : 'none'
        "k_#{kind_name}(V, Acc) ->\n    list(fun k_#{kind.fetch(:element)}/2, V, #{literal(kind.fetch(:max))}, " \
          "#{kind.fetch(:ascending)}, #{target}, #{atom(kind_name)}, none, Acc)."
      end

      def map_check(kind_name, kind)
        optional = kind.fetch(:optional)
        required = kind.fetch(:fields).reject { |field, _| optional.include?(field) }
        variables = kind.fetch(:fields).to_h { |field, _| [field, variable(field)] }
        pattern = required.map { |field, _| "#{atom(field)} := #{variables.fetch(field)}" }.join(', ')
        optionals = kind.fetch(:fields).select { |field, _| optional.include?(field) }.map do |field, field_kind|
          "        case V of \#{#{atom(field)} := #{variables.fetch(field)}} -> [{fun k_#{field_kind}/2, #{variables.fetch(field)}}]; _ -> [] end"
        end
        list = "[#{pairs(required.map(&:last), required.map { |field, _| variables.fetch(field) })}]"
        checks = optionals.empty? ? list : "#{list} ++\n#{optionals.join(" ++\n")}"
        "k_#{kind_name}(\#{#{pattern}} = V, Acc) ->\n    Checks = #{checks},\n" \
          "    case map_size(V) =:= length(Checks) of\n        true -> all(Checks, Acc);\n" \
          "        false -> {error, {key, #{atom(kind_name)}}}\n    end;\n" \
          "k_#{kind_name}(V, _) when is_map(V) ->\n    {error, {key, #{atom(kind_name)}}};\n" \
          "k_#{kind_name}(_, _) ->\n    {error, {shape, #{atom(kind_name)}}}."
      end

      def union_check(kind_name, kind)
        clauses = kind.fetch(:cases).map do |item|
          atoms = item.fetch(:atoms).map { |word| atom(word) }
          fields = item.fetch(:fields)
          if fields.empty?
            "k_#{kind_name}(#{atoms.first}, Acc) ->\n    {ok, Acc}"
          else
            variables = fields.each_index.map { |index| "F#{index + 1}" }
            "k_#{kind_name}({#{(atoms + variables).join(', ')}}, Acc) ->\n    all([#{pairs(fields, variables)}], Acc)"
          end
        end
        (clauses + ["k_#{kind_name}(V, _) when is_atom(V); is_tuple(V) ->\n    {error, {no_case, #{atom(kind_name)}}}",
                    "k_#{kind_name}(_, _) ->\n    {error, {shape, #{atom(kind_name)}}}"]).join(";\n") + '.'
      end

      # A named number by its protocol name, the names its table's generated module lists.
      def named_check(word, rows)
        "%% A #{word} by its protocol name, the names #{Protocols::NAMED_NUMBERS.fetch(word).module} lists.\n" \
          "k_#{word}(V, Acc) when is_atom(V) ->\n    range(is_#{word}(V), #{word}, Acc);\n" \
          "k_#{word}(_, _) ->\n    {error, {shape, #{word}}}.\n\n" +
          (rows.map { |row_name, _| "is_#{word}(#{atom(row_name)}) -> true" } + ["is_#{word}(_) -> false"]).join(";\n") + '.'
      end

      # sort_KIND(Value) for each kind that holds an ascending list: the value
      # with each such list sorted, and any value of another shape unchanged.
      def sorters
        @kinds.map do |kind_name, kind|
          next unless sorts?(kind_name)

          case kind.fetch(:form)
          when 'list'
            sort = kind.fetch(:ascending) ? 'true' : 'false'
            element = sorts?(kind.fetch(:element)) ? "fun sort_#{kind.fetch(:element)}/1" : 'fun(E) -> E end'
            "sort_#{kind_name}(V) ->\n    sort_list(#{element}, #{sort}, V, V, [])."
          when 'tuple'
            elements = kind.fetch(:elements).each_index.map { |index| "E#{index + 1}" }
            sorted = kind.fetch(:elements).zip(elements).map { |element, item| sorts?(element) ? "sort_#{element}(#{item})" : item }
            "sort_#{kind_name}({#{elements.join(', ')}}) ->\n    {#{sorted.join(', ')}};\nsort_#{kind_name}(V) ->\n    V."
          when 'map'
            steps = kind.fetch(:fields).select { |_, field_kind| sorts?(field_kind) }
            body = steps.reduce('V') { |inner, (field, field_kind)| "sort_key(#{atom(field)}, fun sort_#{field_kind}/1, #{inner})" }
            "sort_#{kind_name}(V) ->\n    #{body}."
          when 'union'
            clauses = kind.fetch(:cases).reject { |item| item.fetch(:fields).empty? }.map do |item|
              atoms = item.fetch(:atoms).map { |word| atom(word) }
              variables = item.fetch(:fields).each_index.map { |index| "F#{index + 1}" }
              sorted = item.fetch(:fields).zip(variables).map { |field, var| sorts?(field) ? "sort_#{field}(#{var})" : var }
              "sort_#{kind_name}({#{(atoms + variables).join(', ')}}) ->\n    {#{(atoms + sorted).join(', ')}}"
            end
            (clauses + ["sort_#{kind_name}(V) ->\n    V"]).join(";\n") + '.'
          end
        end.compact.join("\n\n")
      end

      def sorts?(kind_name, seen = [])
        kind = @kinds[kind_name]
        return false unless kind && !seen.include?(kind_name)

        inner = [*kind.fetch(:elements, []), kind[:element], *kind.fetch(:fields, []).map(&:last),
                 *kind.fetch(:cases, []).flat_map { |item| item.fetch(:fields) }].compact
        kind[:ascending] || inner.any? { |item| sorts?(item, seen + [kind_name]) }
      end

      def helpers
        <<~'ERLANG'.chomp
          %% Applies each check to its value in turn, threading Acc; the first refusal ends it.
          all([], Acc) ->
              {ok, Acc};
          all([{Check, V} | Rest], Acc) ->
              case Check(V, Acc) of
                  {ok, Acc1} -> all(Rest, Acc1);
                  Error -> Error
              end.

          range(true, _, Acc) ->
              {ok, Acc};
          range(false, Kind, _) ->
              {error, {range, Kind}}.

          %% A proper list of at most Left elements, each passing Check; Ascending, each key
          %% (an element, or a tuple's first field) above the last. Target names the refers
          %% whose keys this list's elements give: an element that took no refers value
          %% becomes a key a reference may name.
          list(_, [], _, _, _, _, _, Acc) ->
              {ok, Acc};
          list(_, [_ | _], 0, _, _, Kind, _, _) ->
              {error, {length, Kind}};
          list(Check, [E | Es], Left, Ascending, Target, Kind, Last, #{refers := Before} = Acc) ->
              case Check(E, Acc) of
                  {ok, Acc1} ->
                      Key = key(E),
                      case Ascending andalso Last =/= none andalso not (Last < Key) of
                          true -> {error, {order, Kind}};
                          false -> list(Check, Es, Left - 1, Ascending, Target, Kind, Key, target(Target, Key, Before, Acc1))
                      end;
                  Error ->
                      Error
              end;
          list(_, _, _, _, _, Kind, _, _) ->
              {error, {shape, Kind}}.

          key(E) when is_tuple(E), tuple_size(E) > 0 -> {element(1, E)};
          key(E) -> {E}.

          target(none, _, _, Acc) ->
              Acc;
          target(Refers, {Key}, Before, #{refers := Before, targets := Targets} = Acc) ->
              Keys = map_get(Refers, Targets),
              Acc#{targets := Targets#{Refers := Keys#{Key => true}}};
          target(_, _, _, Acc) ->
              Acc.

          refer(V, Refers, #{referred := Referred, refers := Count} = Acc) ->
              Acc#{referred := Referred#{Refers := [V | map_get(Refers, Referred)]}, refers := Count + 1}.

          rules([], _) ->
              ok;
          rules([Rule | Rules], Acc) ->
              case Rule(Acc) of
                  ok -> rules(Rules, Acc);
                  Error -> Error
              end.

          total(Total, Max, #{sums := Sums}) ->
              case map_get(Total, Sums) > Max of
                  true -> {error, {total, Total}};
                  false -> ok
              end.

          refers(Refers, #{referred := Referred, targets := Targets}) ->
              refers_held(map_get(Refers, Referred), map_get(Refers, Targets), Refers).

          refers_held([], _, _) ->
              ok;
          refers_held([V | Vs], Targets, Refers) ->
              case is_map_key(V, Targets) of
                  true -> refers_held(Vs, Targets, Refers);
                  false -> {error, {refers, Refers}}
              end.

          unique(V, Kind, #{unique := Seen} = Acc) ->
              case is_map_key(V, Seen) of
                  true -> {error, {unique, Kind}};
                  false -> {ok, Acc#{unique := Seen#{V => true}}}
              end.

          sum(Total, N, #{sums := Sums} = Acc) ->
              Acc#{sums := Sums#{Total := map_get(Total, Sums) + N}}.

          %% A binary of at most Max bytes, then its rules in order.
          text(V, Max, Rules, Kind) when is_binary(V) ->
              case byte_size(V) =< Max of
                  true -> text_rules(V, Rules, Kind);
                  false -> {error, {length, Kind}}
              end;
          text(_, _, _, Kind) ->
              {error, {shape, Kind}}.

          text_rules(_, [], _) ->
              ok;
          text_rules(V, [utf8 | Rules], Kind) ->
              rule(is_utf8(V), utf8, V, Rules, Kind);
          text_rules(V, [nul | Rules], Kind) ->
              rule(binary:match(V, <<0>>) =:= nomatch, text, V, Rules, Kind);
          text_rules(V, [assign | Rules], Kind) ->
              rule(is_assign(V), text, V, Rules, Kind);
          text_rules(V, [path | Rules], Kind) ->
              rule(is_path(V), text, V, Rules, Kind).

          rule(true, _, V, Rules, Kind) ->
              text_rules(V, Rules, Kind);
          rule(false, Reason, _, _, Kind) ->
              {error, {Reason, Kind}}.

          %% UTF-8 as the binary syntax matches it: no overlong form, surrogate or code point
          %% past 16#10ffff.
          is_utf8(<<_/utf8, Rest/binary>>) ->
              is_utf8(Rest);
          is_utf8(<<>>) ->
              true;
          is_utf8(_) ->
              false.

          %% At least one byte before the first =.
          is_assign(V) ->
              case binary:match(V, <<"=">>) of
                  {Position, _} -> Position > 0;
                  nomatch -> false
              end.

          %% Absolute and normalised: a leading /, no empty, . or .. component, and a
          %% trailing / only in / itself.
          is_path(<<"/">>) ->
              true;
          is_path(<<"/", Rest/binary>>) ->
              is_components(binary:split(Rest, <<"/">>, [global]));
          is_path(_) ->
              false.

          is_components([]) ->
              true;
          is_components([C | Cs]) ->
              C =/= <<>> andalso C =/= <<".">> andalso C =/= <<"..">> andalso is_components(Cs).

          %% Builders only: Sort applied to Key's value when V is a map holding it.
          sort_key(Key, Sort, V) when is_map(V) ->
              case V of
                  #{Key := Field} -> V#{Key := Sort(Field)};
                  _ -> V
              end;
          sort_key(_, _, V) ->
              V.

          %% Builders only: each element of a proper list sorted within, and the list sorted
          %% when Ascending; any other term unchanged.
          sort_list(Sort, Ascending, [E | Es], Original, Done) ->
              sort_list(Sort, Ascending, Es, Original, [Sort(E) | Done]);
          sort_list(_, true, [], _, Done) ->
              lists:sort(Done);
          sort_list(_, false, [], _, Done) ->
              lists:reverse(Done);
          sort_list(_, _, _, Original, _) ->
              Original.
        ERLANG
      end

      def pairs(kinds, variables)
        kinds.zip(variables).map { |kind, variable| "{fun k_#{kind}/2, #{variable}}" }.join(', ')
      end

      def variable(field) = field.split('_').map(&:capitalize).join

      def literal(number)
        number.fetch(:constant) ? "?#{number.fetch(:constant).upcase}" : number.fetch(:value).to_s
      end

      def atom(word)
        return word if word.match?(PLAIN_ATOM) && !Protocols::ERLANG_RESERVED.include?(word)

        "'#{word.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")}'"
      end
    end
  end
end
