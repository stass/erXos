# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_ui'

module Erx
  module ABI
    # The code of the server's records in ui.txt's binary form, emitted from
    # their `record` and `input` declarations (docs/design-abi.md, "Widget
    # format"): what each field type reads, checks and writes in Erlang, C
    # and TypeScript. A record's layout is its declaration; this module holds
    # one row per field type, so the six readers and writers agree on every
    # record by construction, and adding a record touches only ui.txt.
    #
    # A reader reads and checks each field in wire order, and the first that
    # fails gives the reason: a fixed field cut short the record's short
    # reason, and a value outside its type the type's own refusal.
    module UIFields
      # One field type's code. ERLANG_READ is the reader helper taking the
      # bytes and the short reason, or, with ERLANG_SHORT false, the bytes
      # alone; ERLANG_SEGMENT the encoder's binary segment, or with
      # ERLANG_CALL its iolist call; ERLANG_GUARD the encoder's guard;
      # ERLANG_TYPE the value's type; @v stands for the field's variable.
      # C_TYPE is the record member's type, nil for a list's, and C_READ the
      # statements reading into the member @m with the short reason @s, or
      # for a list or an input the call returning a reason, @n a list's
      # count. TS_TYPE, TS_READ and TS_WRITE are the TypeScript record
      # field's type, the reader's expression with @s, and the writer's
      # statement for the value @f.
      Code = Data.define(:erlang_read, :erlang_short, :erlang_segment, :erlang_call, :erlang_guard, :erlang_type,
                         :c_type, :c_read, :ts_type, :ts_read, :ts_write)

      def self.unsigned(bits)
        Code.new(erlang_read: "u#{bits}", erlang_short: true,
                 erlang_segment: bits == 8 ? '@v' : "@v:#{bits}/little", erlang_call: false,
                 erlang_guard: "?IS_U#{bits}(@v)", erlang_type: "0..#{bits == 32 ? '16#ffffffff' : (1 << bits) - 1}",
                 c_type: "uint#{bits}_t", c_read: ["if (!erx_ui_u#{bits}(cursor, &@m))", "\treturn (@s);"],
                 ts_type: 'number', ts_read: "cursor.u#{bits}(@s)", ts_write: "writeUnsigned(writer, #{bits / 8}, @f);")
      end

      CODE = {
        'u8' => unsigned(8),
        'u16' => unsigned(16),
        'u32' => unsigned(32),
        'i8' => Code.new(erlang_read: 'i8', erlang_short: true, erlang_segment: '@v:8/signed', erlang_call: false,
                         erlang_guard: '?IS_I8(@v)', erlang_type: '-128..127',
                         c_type: 'int8_t',
                         c_read: ['if (!erx_ui_u8(cursor, &byte))', "\treturn (@s);",
                                  '@m = (int8_t)(byte <= INT8_MAX ? byte : byte - 256);'],
                         ts_type: 'number', ts_read: '(cursor.u8(@s) << 24) >> 24', ts_write: 'writeSigned8(writer, @f);'),
        'node' => Code.new(erlang_read: 'node_id', erlang_short: true, erlang_segment: '@v:32/little', erlang_call: false,
                           erlang_guard: '?IS_NODE(@v)', erlang_type: 'node_id()',
                           c_type: 'uint32_t',
                           c_read: ['if (!erx_ui_u32(cursor, &@m))', "\treturn (@s);",
                                    'if (@m == 0)', "\treturn (ERX_UI_REFUSAL_BAD_NODE);"],
                           ts_type: 'number', ts_read: 'nodeId(cursor.u32(@s))', ts_write: 'writeNode(writer, @f);'),
        'kind' => Code.new(erlang_read: 'known_kind', erlang_short: true, erlang_segment: '(kind_number(@v))',
                           erlang_call: false, erlang_guard: nil, erlang_type: 'atom()',
                           c_type: 'uint8_t',
                           c_read: ['if (!erx_ui_u8(cursor, &@m))', "\treturn (@s);",
                                    'if (!erx_ui_kinds[@m])', "\treturn (ERX_UI_REFUSAL_UNKNOWN_KIND);"],
                           ts_type: 'string', ts_read: 'kindName(cursor.u8(@s))',
                           ts_write: 'writer.integer(1, KINDS.get(@f) ?? refuse(REFUSAL.unknownKind));'),
        'direction' => Code.new(erlang_read: 'read_direction', erlang_short: true, erlang_segment: '(direction_byte(@v))',
                                erlang_call: false, erlang_guard: '?IS_DIRECTION(@v)', erlang_type: 'down | up',
                                c_type: 'bool',
                                c_read: ['if (!erx_ui_u8(cursor, &byte))', "\treturn (@s);",
                                         'if (byte > 1)', "\treturn (ERX_UI_REFUSAL_BAD_KEY_DIRECTION);",
                                         '@m = byte == 1;'],
                                ts_type: 'boolean', ts_read: 'direction(cursor.u8(@s))',
                                ts_write: 'writer.integer(1, @f ? 1 : 0);'),
        'rune' => Code.new(erlang_read: 'read_rune', erlang_short: true, erlang_segment: '(rune(@v)):32/little',
                           erlang_call: false, erlang_guard: nil, erlang_type: '0..16#10ffff | none',
                           c_type: 'uint32_t',
                           c_read: ['if (!erx_ui_u32(cursor, &@m))', "\treturn (@s);",
                                    'if (@m != ERX_UI_RUNE_NONE &&', '    (@m > 0x10ffff ||',
                                    '    (@m >= 0xd800 && @m <= 0xdfff)))',
                                    "\treturn (ERX_UI_REFUSAL_BAD_RUNE);"],
                           ts_type: 'number | null', ts_read: 'rune(cursor.u32(@s))', ts_write: 'writeRune(writer, @f);'),
        'props' => Code.new(erlang_read: 'read_props', erlang_short: false, erlang_segment: 'props(@v, Present)',
                            erlang_call: true, erlang_guard: 'is_map(@v)', erlang_type: 'map()',
                            c_type: nil, c_read: 'erx_ui_props(cursor, @m, &@n)',
                            ts_type: 'readonly Prop<T>[]', ts_read: 'readProps(cursor)', ts_write: 'writeProps(writer, @f);'),
        'removals' => Code.new(erlang_read: 'read_removed', erlang_short: false, erlang_segment: 'removals(@v)',
                               erlang_call: true, erlang_guard: 'is_list(@v)', erlang_type: '[atom()]',
                               c_type: nil, c_read: 'erx_ui_removed(cursor, @m, &@n)',
                               ts_type: 'readonly string[]', ts_read: 'readRemoved(cursor)',
                               ts_write: 'writeRemoved(writer, @f);'),
        'input' => Code.new(erlang_read: 'read_input', erlang_short: true, erlang_segment: 'input(@v)',
                            erlang_call: true, erlang_guard: nil, erlang_type: 'input()',
                            c_type: 'uint8_t', c_read: 'erx_ui_input(cursor, record, &@m, @s)',
                            ts_type: 'Input', ts_read: 'readInput(cursor, @s)', ts_write: 'writeInput(writer, @f);')
      }.freeze

      # The Erlang reader helpers of the types the declaration uses beyond u8,
      # u16 and u32, emitted only when used, since an unused one fails -Werror.
      ERLANG_READERS = {
        'i8' => <<~'ERLANG',
          i8(<<Value:8/signed, Rest/binary>>, _Short) -> {Value, Rest};
          i8(_Bytes, Short) -> refuse(Short).
        ERLANG
        'node' => <<~'ERLANG',
          %% A node's number, never 0.
          node_id(Bytes, Short) ->
              case u32(Bytes, Short) of
                  {0, _Rest} -> refuse(bad_node);
                  Read -> Read
              end.
        ERLANG
        'kind' => <<~'ERLANG',
          known_kind(Bytes, Short) ->
              {Number, Rest} = u8(Bytes, Short),
              case kind_name(Number) of
                  error -> refuse(unknown_kind);
                  Kind -> {Kind, Rest}
              end.
        ERLANG
        'direction' => <<~'ERLANG',
          read_direction(Bytes, Short) ->
              case u8(Bytes, Short) of
                  {1, Rest} -> {down, Rest};
                  {0, Rest} -> {up, Rest};
                  _ -> refuse(bad_key_direction)
              end.
        ERLANG
        'rune' => <<~'ERLANG'
          %% A Unicode scalar value, or none for 0xffffffff.
          read_rune(Bytes, Short) ->
              case u32(Bytes, Short) of
                  {16#ffffffff, Rest} -> {none, Rest};
                  {Rune, Rest} when Rune =< 16#10ffff, (Rune < 16#d800 orelse Rune > 16#dfff) -> {Rune, Rest};
                  _ -> refuse(bad_rune)
              end.
        ERLANG
      }.freeze

      # The encoder's helpers of the types, emitted only when used.
      ERLANG_WRITERS = {
        'direction' => "direction_byte(down) -> 1;\ndirection_byte(up) -> 0.\n",
        'rune' => <<~'ERLANG',
          rune(none) -> 16#ffffffff;
          rune(Rune) when is_integer(Rune), Rune >= 0, Rune =< 16#10ffff, (Rune < 16#d800 orelse Rune > 16#dfff) -> Rune;
          rune(Rune) -> error({bad_value, Rune}).
        ERLANG
        'removals' => <<~'ERLANG'
          %% A set's removals: a u8 count, then each number once, in number order.
          removals(Removed) ->
              Numbers = lists:usort([number(Name) || Name <- Removed, Name =/= key]),
              [length(Numbers) | Numbers].
        ERLANG
      }.freeze

      module_function

      def code(field) = CODE.fetch(field.type)

      # The types the records and input forms use, in declaration order.
      def types(ui) = (ui.records + ui.inputs).flat_map(&:fields).map(&:type).uniq

      def erlang_var(name) = name.split('_').map(&:capitalize).join

      def ts_name(name) = name.split('_').each_with_index.map { |part, index| index.zero? ? part : part.capitalize }.join

      # The refusal's name in C and TypeScript: Erlang's atom with spaces.
      def reason_text(reason) = reason.tr('_', ' ')

      def c_refusal(reason) = "ERX_UI_REFUSAL_#{reason.upcase}"

      def ts_refusal(reason) = "REFUSAL.#{ts_name(reason)}"

      def tuple(name, values) = values.empty? ? name : "{#{[name, *values].join(', ')}}"

      # --- Erlang ---------------------------------------------------------------

      # A record's or input form's term: the name, then each field's value.
      def erlang_term(owner, typed: false)
        tuple(owner.name, owner.fields.map do |field|
          typed ? "#{erlang_var(field.name)} :: #{code(field).erlang_type}" : erlang_var(field.name)
        end)
      end

      # The reads of FIELDS from R<FROM> on, each binding its value and the
      # rest, and the last rest's name.
      def erlang_reads(fields, short, from: 0)
        lines = fields.each_with_index.map do |field, index|
          entry = code(field)
          rest = "R#{from + index}"
          arguments = entry.erlang_short ? "#{rest}, #{short}" : rest
          "{#{erlang_var(field.name)}, R#{from + index + 1}} = #{entry.erlang_read}(#{arguments}),"
        end
        [lines, "R#{from + fields.size}"]
      end

      def erlang_server_fields(ui)
        clauses = ui.records.map do |record|
          reads, rest = erlang_reads(record.fields, record.short)
          body = [*reads, "{#{erlang_term(record)}, #{rest}}"].map { |line| "    #{line}" }.join("\n")
          "server_fields(<<#{record.tag}, R0/binary>>) ->\n#{body};\n"
        end
        <<~ERLANG
          %% The fields after the tag, by the tag, in the order ui.txt declares them;
          %% the reports go the other way.
          #{clauses.join}server_fields(_Body) ->
              refuse(unknown_tag).
        ERLANG
      end

      def erlang_read_input(ui)
        return '' if ui.inputs.empty?

        forms = ui.inputs.map do |form|
          reads, rest = erlang_reads(form.fields, 'Short', from: 1)
          body = [*reads, "{#{erlang_term(form)}, #{rest}};"].map { |line| "            #{line}" }.join("\n")
          "        {#{form.number}, R1} ->\n#{body}\n"
        end
        <<~ERLANG
          %% An input record's event: its form, and the form's fields.
          read_input(R0, Short) ->
              case u8(R0, Short) of
          #{forms.join}        {_Form, _Rest} ->
                      refuse(unknown_input_form)
              end.
        ERLANG
      end

      def erlang_readers(ui) = types(ui).filter_map { |type| ERLANG_READERS[type] }.join("\n")

      # An encoder clause: the guards on the fields, then the tag and the
      # fields' segments, runs of fixed fields in one binary.
      def erlang_encode(head, prefix, owner)
        guards = owner.fields.filter_map do |field|
          code(field).erlang_guard&.gsub('@v', erlang_var(field.name))
        end
        present = owner.fields.any? { |field| field.type == 'props' } ? 'Present' : '_Present'
        segments = owner.fields.each_with_object([[prefix]]) do |field, parts|
          segment = code(field).erlang_segment.gsub('@v', erlang_var(field.name))
          if code(field).erlang_call
            parts << segment << []
          else
            parts.last << segment
          end
        end
        segments = segments.reject(&:empty?).map { |part| part.is_a?(Array) ? "<<#{part.join(', ')}>>" : part }
        body = segments.size == 1 ? segments.first : "[#{segments.join(', ')}]"
        clause_head = head.call(erlang_term(owner), present)
        unless guards.empty?
          guard = "when #{guards.join(', ')}"
          clause_head += clause_head.size + guard.size < 96 ? " #{guard}" : "\n  #{guard}"
        end
        "#{clause_head} ->\n    #{body};\n"
      end

      def erlang_body_clauses(ui)
        ui.records.map do |record|
          erlang_encode(->(term, present) { "body(#{term}, #{present})" }, record.tag.to_s, record)
        end.join
      end

      def erlang_input_encoder(ui)
        return '' if ui.inputs.empty?

        clauses = ui.inputs.map { |form| erlang_encode(->(term, _) { "input(#{term})" }, form.number.to_s, form) }
        "%% An input record's event: its form's number and its fields.\n#{clauses.join}input(Input) ->\n" \
          "    error({bad_value, Input}).\n"
      end

      def erlang_writers(ui) = types(ui).filter_map { |type| ERLANG_WRITERS[type] }.join("\n")

      def erlang_types(ui)
        records = ui.records.map { |record| erlang_term(record, typed: true) }
        inputs = ui.inputs.map { |form| erlang_term(form, typed: true) }
        { records: records, input: inputs.join("\n               | ") }
      end

      # The refusal() type's members, five to a line.
      def erlang_refusals = UI::REFUSALS.each_slice(5).map { |names| names.join(' | ') }.join("\n                 | ")

      # --- C --------------------------------------------------------------------

      # The record's members of the declared fields, one per name: the lists'
      # arrays and counts, then the fixed fields widest first.
      def c_members(ui)
        fields = (ui.records + ui.inputs).flat_map(&:fields).uniq(&:name)
        lists, fixed = fields.partition { |field| code(field).c_type.nil? }
        members = lists.flat_map do |field|
          element = field.type == 'props' ? 'erx_ui_prop_t' : 'uint8_t'
          [[element, "#{field.name}[ERX_UI_PROPERTY_MAX]"], ['uint8_t', "n#{field.name}"]]
        end
        members + fixed.sort_by.with_index { |field, index| [-c_size(code(field).c_type), index] }
                       .map { |field| [code(field).c_type, field.name] }
      end

      def c_size(type) = { 'uint32_t' => 4, 'uint16_t' => 2 }.fetch(type, 1)

      def c_member_line(type, name) = "\t#{type}#{type.size < 8 ? "\t\t" : "\t"} #{name};"

      # Whether a field's C reader is a call returning a reason, which the
      # props, removals and input fields' are.
      def c_call?(field) = code(field).c_read.is_a?(String)

      # The statements reading FIELDS into their members of the record, at two
      # tabs, with the short reason SHORT: each fixed field read and checked,
      # each call's reason returned, and NULL after the last fixed field.
      def c_reads(fields, short)
        lines = fields.each_with_index.flat_map do |field, index|
          member = "record->#{field.name}"
          read = code(field).c_read
          next read.map { |line| line.gsub('@m', member).gsub('@s', short) } unless c_call?(field)

          call = read.gsub('@n', "record->n#{field.name}").gsub('@m', member).gsub('@s', short)
          next [c_wrap("return (#{call});")] if index == fields.size - 1

          [c_wrap("reason = #{call};"), 'if (reason != NULL)', "\treturn (reason);"]
        end
        fields.last && c_call?(fields.last) ? lines : lines + ['return (NULL);']
      end

      # A statement at two tabs, broken after its last comma that keeps it
      # within 80 columns, its continuation indented four spaces more.
      def c_wrap(line)
        return line if 16 + line.size <= 80

        at = line.rindex(', ', 80 - 16 - 2) or return line
        "#{line[0..at]}\n\t\t    #{line[(at + 2)..]}"
      end

      # The locals the reads of FIELDS use: a reason for a call before the
      # last field, a byte for a field read before it is converted.
      def c_locals(fields)
        reason = fields[0...-1].any? { |field| c_call?(field) }
        byte = fields.any? { |field| %w[i8 direction].include?(field.type) }
        [("\tconst char *reason;" if reason), ("\tuint8_t byte;" if byte)].compact
      end

      def c_case(name, lines) = "\tcase #{name}:\n#{lines.map { |line| "\t\t#{line}" }.join("\n")}\n"

      def c_fields(ui)
        cases = ui.records.map do |record|
          c_case("ERX_UI_#{record.name.upcase}", c_reads(record.fields, c_refusal(record.short)))
        end
        locals = ui.records.flat_map { |record| c_locals(record.fields) }.uniq
        <<~C
          /* The fields of one record whose tag is in, by tag, as ui.txt declares them. */
          static const char *
          erx_ui_fields(erx_ui_cursor_t *cursor, erx_ui_record_t *record)
          {
          #{locals.map { |line| "#{line}\n" }.join}#{locals.empty? ? '' : "\n"}	switch (record->tag) {
          #{cases.join}	default:
          		/* The reports go the other way; a renderer refuses them. */
          		return (ERX_UI_REFUSAL_UNKNOWN_TAG);
          	}
          }
        C
      end

      def c_input(ui)
        return '' if ui.inputs.empty?

        cases = ui.inputs.map { |form| c_case("ERX_UI_INPUT_#{form.name.upcase}", c_reads(form.fields, 'cut')) }
        locals = ui.inputs.flat_map { |form| c_locals(form.fields) }.uniq
        <<~C
          /* An input record's event: its form, and the form's fields into record. */
          static const char *
          erx_ui_input(erx_ui_cursor_t *cursor, erx_ui_record_t *record, uint8_t *form,
              const char *cut)
          {
          #{locals.map { |line| "#{line}\n" }.join}#{locals.empty? ? '' : "\n"}	if (!erx_ui_u8(cursor, form))
          		return (cut);
          	switch (*form) {
          #{cases.join}	default:
          		return (ERX_UI_REFUSAL_UNKNOWN_INPUT_FORM);
          	}
          }
        C
      end

      def c_refusal_defines
        UI::REFUSALS.map { |reason| "#define #{c_refusal(reason).ljust(36)}\"#{reason_text(reason)}\"" }.join("\n")
      end

      # --- TypeScript -----------------------------------------------------------

      def ts_object(discriminant, owner)
        fields = owner.fields.map { |field| "readonly #{ts_name(field.name)}: #{code(field).ts_type}" }
        "{ #{["readonly #{discriminant}: '#{owner.name}'", *fields].join('; ')} }"
      end

      def ts_types(ui)
        { records: ui.records.map { |record| ts_object('tag', record) },
          input: ui.inputs.map { |form| ts_object('form', form) } }
      end

      def ts_literal(discriminant, owner, short)
        values = owner.fields.map { |field| "#{ts_name(field.name)}: #{code(field).ts_read.gsub('@s', short)}" }
        "{ #{["#{discriminant}: '#{owner.name}'", *values].join(', ')} }"
      end

      # The reader's cases: an object literal evaluates its values in order,
      # so each field is read and checked in wire order.
      def ts_read_cases(ui)
        ui.records.map do |record|
          "    case TAG.#{record.name}:\n      return #{ts_literal('tag', record, ts_refusal(record.short))};\n"
        end.join
      end

      def ts_input_cases(ui)
        ui.inputs.map do |form|
          "    case INPUT.#{form.name}:\n      return #{ts_literal('form', form, 'cut')};\n"
        end.join
      end

      def ts_writes(owner, value)
        owner.fields.map { |field| code(field).ts_write.gsub('@f', "#{value}.#{ts_name(field.name)}") }
      end

      def ts_write_cases(ui)
        ui.records.map do |record|
          ["    case '#{record.name}':", *ts_writes(record, 'record').map { |line| "      #{line}" }, '      return;'].join("\n")
        end.join("\n")
      end

      def ts_input_write_cases(ui)
        ui.inputs.map do |form|
          ["    case '#{form.name}':", "      writer.integer(1, INPUT.#{form.name});",
           *ts_writes(form, 'input').map { |line| "      #{line}" }, '      return;'].join("\n")
        end.join("\n")
      end

      def ts_refusals
        pairs = UI::REFUSALS.map { |reason| "#{ts_name(reason)}: '#{reason_text(reason)}'" }
        "/* The reasons read() refuses a record for, those of the C and Erlang readers. */\n" \
          "const REFUSAL = Object.freeze({ #{pairs.join(', ')} });\n"
      end
    end
  end
end
