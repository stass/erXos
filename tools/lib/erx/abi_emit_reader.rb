# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'abi_emit_c'

module Erx
  module ABI
    module CReaderEmitter
      module_function

      def source(schema)
        return '' if schema.readers.empty?
        out = [helpers]
        schema.readers.each do |reader|
          out.concat(reader_source(reader))
        end
        out.join("\n")
      end

      def helpers
        <<~'C'
          static bool erx_abi_fail(erx_abi_error_t *, const char *, const char *, size_t) ERX_UNUSED;
          static bool erx_abi_zero(const uint8_t *, size_t) ERX_UNUSED;
          static bool erx_abi_utf8(const uint8_t *, size_t, bool) ERX_UNUSED;
          static bool erx_abi_identifier(const uint8_t *, size_t) ERX_UNUSED;
          static bool erx_abi_path(const uint8_t *, size_t, bool) ERX_UNUSED;
          static bool erx_abi_vector(const uint8_t *, size_t, bool) ERX_UNUSED;

          static bool
          erx_abi_fail(erx_abi_error_t *error, const char *reason,
              const char *field, size_t offset)
          {
          	if (error != NULL) {
          		error->reason = reason;
          		error->field = field;
          		error->offset = offset;
          	}
          	return (false);
          }

          static bool
          erx_abi_zero(const uint8_t *bytes, size_t length)
          {
          	for (size_t index = 0; index < length; index++) {
          		if (bytes[index] != 0)
          			return (false);
          	}
          	return (true);
          }

          /* Decode each scalar once, rejecting overlong forms and surrogates. */
          static bool
          erx_abi_utf8(const uint8_t *bytes, size_t length, bool clean)
          {
          	size_t cursor, continuation;
          	uint32_t point, minimum;
          	uint8_t first, next;

          	cursor = 0;
          	while (cursor < length) {
          		first = bytes[cursor++];
          		if (first < 0x80) {
          			point = first;
          			continuation = 0;
          			minimum = 0;
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
          		if (clean && (point < 0x20 ||
          		    (point >= 0x7f && point <= 0x9f)))
          			return (false);
          	}
          	return (true);
          }

          static bool
          erx_abi_identifier(const uint8_t *bytes, size_t length)
          {
          	uint8_t byte;
          	bool alnum;

          	if (length == 0 || length > 63)
          		return (false);
          	for (size_t index = 0; index < length; index++) {
          		byte = bytes[index];
          		alnum = (byte >= 'a' && byte <= 'z') ||
          		    (byte >= '0' && byte <= '9');
          		if (!alnum && (index == 0 ||
          		    (byte != '.' && byte != '_' && byte != '-')))
          			return (false);
          	}
          	return (true);
          }

          static bool
          erx_abi_path(const uint8_t *bytes, size_t length, bool device_tree)
          {
          	size_t start, component;

          	if (length == 0 || bytes[0] != '/')
          		return (false);
          	if (!erx_abi_utf8(bytes, length, device_tree))
          		return (false);
          	if (length == 1)
          		return (true);
          	start = 1;
          	for (size_t cursor = 1; cursor <= length; cursor++) {
          		if (cursor < length && bytes[cursor] == 0)
          			return (false);
          		if (cursor < length && bytes[cursor] != '/')
          			continue;
          		component = cursor - start;
          		if (component == 0 || (component == 1 && bytes[start] == '.') ||
          		    (component == 2 && bytes[start] == '.' && bytes[start + 1] == '.'))
          			return (false);
          		start = cursor + 1;
          	}
          	return (true);
          }

          /* Vectors are bounded by the declaration before reaching this code. */
          static bool
          erx_abi_vector(const uint8_t *bytes, size_t length, bool environment)
          {
          	size_t start, end, equals, prior, prior_end, prior_equals, key;
          	bool same;

          	if (length == 0)
          		return (true);
          	if (bytes[length - 1] != 0)
          		return (false);
          	start = 0;
          	while (start < length) {
          		end = start;
          		while (bytes[end] != 0)
          			end++;
          		if (environment) {
          			equals = start;
          			while (equals < end && bytes[equals] != '=')
          				equals++;
          			if (equals == start || equals == end)
          				return (false);
          			prior = 0;
          			while (prior < start) {
          				prior_end = prior;
          				while (bytes[prior_end] != 0)
          					prior_end++;
          				prior_equals = prior;
          				while (prior_equals < prior_end && bytes[prior_equals] != '=')
          					prior_equals++;
          				same = equals - start == prior_equals - prior;
          				key = 0;
          				while (same && key < equals - start) {
          					same = bytes[start + key] == bytes[prior + key];
          					key++;
          				}
          				if (same)
          					return (false);
          				prior = prior_end + 1;
          			}
          		}
          		start = end + 1;
          	}
          	return (true);
          }
        C
      end

      def reader_source(reader)
        prefix = Names.c(reader.name)
        out = []
        scopes = { 'root' => reader.root }.merge(reader.tables.transform_values { |table| table.fetch(:type) })
        scopes.each do |scope, layout|
          out << "static bool #{prefix}_check_#{scope}(const uint8_t *,"
          out << "    const #{CEmitter.c_type(layout)} *, const #{CEmitter.c_type(reader.root)} *,"
          out << '    const uint8_t *, size_t, erx_abi_error_t *);'
        end
        out << ''
        scopes.each do |scope, layout|
          function = "#{prefix}_check_#{scope}"
          out.concat(['static bool', "#{function}(const uint8_t *bytes ERX_UNUSED,",
                      "    const #{CEmitter.c_type(layout)} *record ERX_UNUSED,",
                      "    const #{CEmitter.c_type(reader.root)} *header ERX_UNUSED,",
                      '    const uint8_t *file ERX_UNUSED, size_t base ERX_UNUSED,',
                      '    erx_abi_error_t *error ERX_UNUSED)', '{'])
          body = validate_scope(reader, scope, layout)
          out.concat(body)
          out.concat(["\treturn (true);", '}', ''])
        end
        out.concat(open_function(reader))
        reader.tables.each_value { |table| out.concat(table_accessor(reader, table)) }
        out
      end

      def validate_scope(reader, scope, layout)
        out = []
        pending = [[layout, 'record', [], 0]]
        until pending.empty?
          type, expression, names, offset = pending.pop
          type.padding.each do |padding_offset, length|
            check = "erx_abi_zero(bytes + #{offset + padding_offset}, #{length})"
            out.concat(fail_unless(check, reason: 'reserved', field: scoped(scope, names + ['padding']), offset: "base + #{offset + padding_offset}"))
          end
          type.fields.reverse_each do |field|
            child_names = names + [field.name]
            child_expression = names.empty? ? "record->#{field.name}" : "#{expression}.#{field.name}"
            child_offset = offset + field.offset
            if field.type.is_a?(Layout) && !field.array?
              pending << [field.type, child_expression, child_names, child_offset]
              next
            end
            path = scoped(scope, child_names)
            conditions = active_conditions(reader, scope, child_names)
            lines = validate_leaf(field, child_expression, path, child_offset, reader.source_role)
            out.concat(guard(lines, conditions))
          end
        end
        reader.rules.each do |rule|
          next unless rule_scope(rule) == scope
          conditions = rule.fetch(:kind) == 'optional' || rule.fetch(:kind) == 'choice' ? [] : active_conditions(reader, scope, rule_primary_path(rule).fields)
          if rule[:guard]
            condition = rule.fetch(:guard)
            conditions << "#{c_path(condition.fetch(:tag))} == #{CEmitter.literal(condition.fetch(:value), condition.fetch(:tag).type.integer)}"
          end
          out.concat(guard(rule_lines(rule, reader), conditions))
        end
        out
      end

      def scoped(scope, fields)
        ([scope == 'root' ? 'root' : "#{scope}[]"] + fields).join('.')
      end

      def c_path(path, root: false)
        base = root || path.scope == 'root' ? 'header' : 'record'
        field_expression(path, prefix: base + '->')
      end

      def field_expression(path, prefix:)
        prefix + path.fields.join('.') + (path.type.strong? ? '.raw' : '')
      end

      def relative_path(fields)
        'record->' + fields.join('.')
      end

      def ancestor?(prefix, fields)
        fields.take(prefix.size) == prefix
      end

      def active_conditions(reader, scope, fields)
        reader.rules.each_with_object([]) do |rule, result|
          next unless rule_scope(rule) == scope
          case rule.fetch(:kind)
          when 'optional'
            next unless ancestor?(rule.fetch(:path).fields, fields)
            result << "(#{c_path(rule.fetch(:flags))} & UINT64_C(#{rule.fetch(:mask)})) != 0"
          when 'choice'
            selected = rule.fetch(:fields).find { |path| ancestor?(path.fields, fields) }
            next unless selected
            tags = rule.fetch(:cases).select { |_tag, active| active.any? { |path| path.name == selected.name } }.keys
            result << '(' + tags.map { |tag| "#{c_path(rule.fetch(:tag))} == UINT64_C(#{tag})" }.join(' || ') + ')'
          end
        end
      end

      def guard(lines, conditions)
        return lines if conditions.empty? || lines.empty?
        ["\tif (#{conditions.join(' && ')}) {"] + lines.map { |line| "\t#{line}" } + ["\t}"]
      end

      def fail_unless(condition, reason:, field:, offset:)
        ["\tif (!(#{condition}))", "\t\treturn (erx_abi_fail(error, #{reason.dump},", "\t\t    #{field.dump}, #{offset}));"]
      end

      def validate_leaf(field, expression, path, offset, source_role)
        return [] if field.type.is_a?(Layout)
        if field.array?
          element = field.dup
          element.count = nil
          lines = validate_leaf(element.freeze, "#{expression}[index]", path,
                                "#{offset} + index * #{field.type.size}", source_role)
          return [] if lines.empty?
          return ["\tfor (size_t index = 0; index < #{field.count}; index++) {"] + lines.map { |line| "\t#{line}" } + ["\t}"]
        end
        type = field.type
        out = []
        raw = type.strong? ? expression + '.raw' : expression
        if type.is_a?(BytesType)
          if type.fixed
            type.fixed.bytes.each_with_index do |byte, index|
              out.concat(fail_unless("#{expression}[#{index}] == #{byte}", reason: 'value', field: path, offset: "base + #{offset} + #{index}"))
            end
          end
          if field.zero_mask != 0
            out.concat(fail_unless("erx_abi_zero(#{expression}, #{type.size})", reason: 'reserved', field: path, offset: "base + #{offset}"))
          end
          return out
        end
        if type.is_a?(ScalarType)
          conditions = []
          conditions << "#{raw} >= #{CEmitter.literal(type.minimum, type.base)}" if type.minimum != type.base.minimum
          conditions << "#{raw} <= #{CEmitter.literal(type.maximum, type.base)}" if type.maximum != type.base.maximum
          conditions << "#{raw} % #{type.multiple} == 0" if type.multiple != 1
          out.concat(fail_unless(conditions.join(' && '), reason: 'range', field: path, offset: "base + #{offset}")) unless conditions.empty?
        elsif type.is_a?(EnumType)
          condition = if type.allowed
                        type.allowed.map { |value| "#{raw} == #{CEmitter.literal(value, type.base)}" }.join(' || ')
                      elsif type.flags
                        "((uint64_t)#{raw} & UINT64_C(#{type.base.maximum ^ type.mask})) == 0"
                      else
                        type.members.values.map { |value| "#{raw} == #{CEmitter.literal(value, type.base)}" }.join(' || ')
                      end
          out.concat(fail_unless(condition, reason: type.flags ? 'flags' : 'tag', field: path, offset: "base + #{offset}"))
        end
        if field.zero_mask != 0
          out.concat(fail_unless("((uint64_t)#{raw} & UINT64_C(#{field.zero_mask})) == 0", reason: 'reserved', field: path, offset: "base + #{offset}"))
        end
        if source_role && field.input_masks.key?(source_role)
          mask = ((1 << (type.size * 8)) - 1) ^ field.input_masks.fetch(source_role)
          out.concat(fail_unless("((uint64_t)#{raw} & UINT64_C(#{mask})) == 0", reason: 'ownership', field: path, offset: "base + #{offset}"))
        end
        out
      end

      def rule_scope(rule)
        rule_primary_path(rule).scope
      end

      def rule_primary_path(rule)
        rule[:path] || rule[:offset] || rule.fetch(:tag)
      end

      def rule_lines(rule, reader)
        kind = rule.fetch(:kind)
        path = rule_primary_path(rule)
        offset = "base + #{path.offset}"
        value = c_path(path)
        case kind
        when 'value'
          fail_unless("#{value} == #{CEmitter.literal(rule.fetch(:values).first, path.type.integer)}", reason: 'value', field: path.name, offset: offset)
        when 'range'
          low, high = rule.fetch(:values)
          condition = []
          condition << "#{value} >= #{CEmitter.literal(low, path.type.integer)}" unless low == path.type.integer.minimum
          condition << "#{value} <= #{CEmitter.literal(high, path.type.integer)}" unless high == path.type.integer.maximum
          condition.empty? ? [] : fail_unless(condition.join(' && '), reason: 'range', field: path.name, offset: offset)
        when 'index'
          table = reader.tables.fetch(rule.fetch(:table))
          condition = "#{value} < #{c_path(table.fetch(:count_path), root: true)}"
          condition += " || #{value} == UINT64_C(#{rule.fetch(:absent)})" if rule[:absent]
          fail_unless(condition, reason: 'index', field: path.name, offset: offset)
        when 'slice', 'partition'
          table = reader.tables.fetch(rule.fetch(:table))
          table_offset = c_path(table.fetch(:offset_path), root: true)
          table_count = c_path(table.fetch(:count_path), root: true)
          count = c_path(rule.fetch(:count))
          stride = table.fetch(:type).size
          condition = "#{value} >= #{table_offset} && " \
                      "((uint64_t)#{value} - #{table_offset}) % #{stride} == 0 && " \
                      "((uint64_t)#{value} - #{table_offset}) / #{stride} <= #{table_count} && " \
                      "#{count} <= #{table_count} - ((uint64_t)#{value} - #{table_offset}) / #{stride}"
          fail_unless(condition, reason: 'slice', field: path.name, offset: offset)
        when 'string'
          string_rule(rule, reader)
        when 'optional'
          condition = "(#{c_path(rule.fetch(:flags))} & UINT64_C(#{rule.fetch(:mask)})) != 0 || " \
                      "erx_abi_zero(bytes + #{path.offset}, #{path.field.size})"
          fail_unless(condition, reason: 'inactive', field: path.name, offset: offset)
        when 'choice'
          out = ["\tswitch (#{value}) {"]
          rule.fetch(:cases).sort.each do |tag, active|
            out << "\tcase #{tag}:"
            inactive = rule.fetch(:fields).reject { |field| active.any? { |selected| field.name == selected.name } }
            inactive.each do |field|
              out.concat(fail_unless("erx_abi_zero(bytes + #{field.offset}, #{field.field.size})", reason: 'inactive', field: field.name, offset: "base + #{field.offset}").map { |line| "\t#{line}" })
            end
            out << "\t\tbreak;"
          end
          out.concat(["\tdefault:", "\t\treturn (erx_abi_fail(error, \"tag\", #{path.name.dump}, #{offset}));", "\t}"])
          out
        else
          raise SchemaError, "cannot emit reader rule #{kind}"
        end
      end

      def string_rule(rule, reader)
        path = rule.fetch(:offset)
        table = reader.strings.fetch(rule.fetch(:table))
        offset = c_path(path)
        length = c_path(rule.fetch(:count))
        table_length = c_path(table.fetch(:count_path), root: true)
        table_offset = c_path(table.fetch(:offset_path), root: true)
        bounds = "#{offset} <= #{table_length} && " \
                 "#{length} <= #{table_length} - #{offset} && " \
                 "#{length} <= UINT64_C(#{rule.fetch(:maximum)})"
        bounds += " && #{length} != 0" unless rule.fetch(:empty)
        out = fail_unless(bounds, reason: 'string_range', field: path.name, offset: "base + #{path.offset}")
        bytes = "file + (size_t)#{table_offset} + (size_t)#{offset}"
        count = "(size_t)#{length}"
        check = case rule.fetch(:class)
                when 'identifier' then "erx_abi_identifier(#{bytes}, #{count})"
                when 'dt_path' then "erx_abi_path(#{bytes}, #{count}, true)"
                when 'namespace_path' then "erx_abi_path(#{bytes}, #{count}, false)"
                when 'utf8' then "erx_abi_utf8(#{bytes}, #{count}, true)"
                when 'args' then "erx_abi_vector(#{bytes}, #{count}, false)"
                when 'env' then "erx_abi_vector(#{bytes}, #{count}, true)"
                when 'bytes' then nil
                end
        if check
          check = "#{length} == 0 || #{check}" if rule.fetch(:empty)
          out.concat(fail_unless(check, reason: 'string_class', field: path.name, offset: "base + #{path.offset}"))
        end
        out
      end

      def open_function(reader)
        prefix = Names.c(reader.name)
        root_type = CEmitter.c_type(reader.root)
        out = ['bool', "#{prefix}_open(const uint8_t *bytes, size_t length,",
               "    #{prefix}_view_t *result, erx_abi_error_t *error)", '{',
               "\t#{root_type} header;", reader.order.empty? ? "\tsize_t cursor;" : "\tsize_t cursor, padding;", '',
               "\tif (bytes == NULL || result == NULL || length > UINT64_C(#{reader.maximum}))",
               "\t\treturn (erx_abi_fail(error, \"length\", \"root\", 0));",
               "\tif (!#{CEmitter.name(reader.root.name)}_decode(bytes, length, &header))",
               "\t\treturn (erx_abi_fail(error, \"truncated\", \"root\", 0));", '',
               "\tcursor = #{reader.root.size};"]
        if reader.extent
          field = field_expression(reader.extent, prefix: 'header.')
          out.concat(["\tif (#{field} != length)",
                      "\t\treturn (erx_abi_fail(error, \"length\",",
                      "\t\t    #{reader.extent.name.dump}, #{reader.extent.offset}));", ''])
        end
        reader.order.each do |table_name|
          table = reader.tables[table_name] || reader.strings.fetch(table_name)
          alignment = table.fetch(:alignment)
          stride = table[:type] ? table.fetch(:type).size : 1
          table_offset = field_expression(table.fetch(:offset_path), prefix: 'header.')
          count = field_expression(table.fetch(:count_path), prefix: 'header.')
          out.concat(["\tpadding = (#{alignment} - cursor % #{alignment}) % #{alignment};",
                      "\tif (padding > length - cursor)",
                      "\t\treturn (erx_abi_fail(error, \"truncated\", #{table_name.dump}, cursor));",
                      "\tif (!erx_abi_zero(bytes + cursor, padding))",
                      "\t\treturn (erx_abi_fail(error, \"padding\", #{table_name.dump}, cursor));",
                      "\tcursor += padding;",
                      "\tif (#{table_offset} != cursor)",
                      "\t\treturn (erx_abi_fail(error, \"order\", #{table_name.dump}, cursor));",
                      "\tif (#{count} > UINT64_C(#{table.fetch(:maximum)}) ||",
                      "\t    #{count} > (length - cursor) / #{stride})",
                      "\t\treturn (erx_abi_fail(error, \"extent\", #{table_name.dump}, cursor));",
                      "\tcursor += (size_t)#{count} * #{stride};", ''])
        end
        out.concat(["\tif (cursor != length)", "\t\treturn (erx_abi_fail(error, \"trailing\", \"root\", cursor));",
                    "\tif (!#{prefix}_check_root(bytes, &header, &header, bytes, 0, error))", "\t\treturn (false);", ''])
        out.concat(partition_checks(reader))
        reader.tables.each_value do |table|
          table_name = table.fetch(:name)
          type = table.fetch(:type)
          offset = field_expression(table.fetch(:offset_path), prefix: 'header.')
          count = field_expression(table.fetch(:count_path), prefix: 'header.')
          out.concat(["\tfor (size_t index = 0; index < #{count}; index++) {",
                      "\t\t#{CEmitter.c_type(type)} record;", "\t\tsize_t offset;", '',
                      "\t\toffset = (size_t)#{offset} + index * #{type.size};",
                      "\t\tif (!#{CEmitter.name(type.name)}_decode(bytes + offset, #{type.size}, &record))",
                      "\t\t\treturn (erx_abi_fail(error, \"truncated\", #{table_name.dump}, offset));",
                      "\t\tif (!#{prefix}_check_#{table_name}(bytes + offset, &record,",
                      "\t\t    &header, bytes, offset, error))", "\t\t\treturn (false);", "\t}", ''])
        end
        out.concat(["\tresult->bytes = bytes;", "\tresult->length = length;", "\tresult->header = header;",
                    "\tif (error != NULL)", "\t\t*error = (erx_abi_error_t){0};",
                    "\treturn (true);", '}', ''])
        out
      end

      def partition_checks(reader)
        reader.rules.select { |rule| rule.fetch(:kind) == 'partition' }.flat_map do |rule|
          path = rule.fetch(:offset)
          owners = reader.tables.fetch(path.scope)
          target = reader.tables.fetch(rule.fetch(:table))
          owner_type = owners.fetch(:type)
          owner_start = field_expression(owners.fetch(:offset_path), prefix: 'header.')
          owner_count = field_expression(owners.fetch(:count_path), prefix: 'header.')
          target_start = field_expression(target.fetch(:offset_path), prefix: 'header.')
          target_count = field_expression(target.fetch(:count_path), prefix: 'header.')
          span_offset = field_expression(path, prefix: 'record.')
          span_count = field_expression(rule.fetch(:count), prefix: 'record.')
          ["\t{", "\t\tsize_t covered;", '', "\t\tcovered = 0;",
           "\t\tfor (size_t index = 0; index < #{owner_count}; index++) {",
           "\t\t\t#{CEmitter.c_type(owner_type)} record;", "\t\t\tsize_t base;", '',
           "\t\t\tbase = (size_t)#{owner_start} + index * #{owner_type.size};",
           "\t\t\tif (!#{CEmitter.name(owner_type.name)}_decode(bytes + base,",
           "\t\t\t    #{owner_type.size}, &record))",
           "\t\t\t\treturn (erx_abi_fail(error, \"truncated\", #{path.name.dump}, base));",
           "\t\t\tif (#{span_offset} != (size_t)#{target_start} + covered * #{target.fetch(:type).size} ||",
           "\t\t\t    #{span_count} > #{target_count} - covered)",
           "\t\t\t\treturn (erx_abi_fail(error, \"partition\", #{path.name.dump},",
           "\t\t\t\t    base + #{path.offset}));",
           "\t\t\tcovered += (size_t)#{span_count};", "\t\t}",
           "\t\tif (covered != #{target_count})",
           "\t\t\treturn (erx_abi_fail(error, \"partition\", #{path.name.dump},",
           "\t\t\t    (size_t)#{target_start} + covered * #{target.fetch(:type).size}));",
           "\t}", '']
        end
      end

      def table_accessor(reader, table)
        prefix = Names.c(reader.name)
        type = table.fetch(:type)
        offset = field_expression(table.fetch(:offset_path), prefix: 'view->header.')
        count = field_expression(table.fetch(:count_path), prefix: 'view->header.')
        ['bool', "#{prefix}_#{table.fetch(:name)}_at(const #{prefix}_view_t *view,",
         "    size_t index, #{CEmitter.c_type(type)} *result)", '{',
         "\tif (view == NULL || view->bytes == NULL || result == NULL)", "\t\treturn (false);",
         "\tif (#{offset} > view->length || index >= #{count})", "\t\treturn (false);",
         "\tif (#{count} > (view->length - #{offset}) / #{type.size})", "\t\treturn (false);",
         "\treturn (#{CEmitter.name(type.name)}_decode(view->bytes +",
         "\t    (size_t)#{offset} + index * #{type.size}, #{type.size}, result));", '}', '']
      end
    end
  end
end
