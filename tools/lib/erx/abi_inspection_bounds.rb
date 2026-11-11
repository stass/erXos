# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

module Erx
  module ABI
    # What the inspection schema allows an answer of the inspect service to
    # be (docs/design-live.md, "The inspect service"), computed from the
    # resolved schema alone, as upper bounds:
    #
    # * funnel_depth, the deepest nesting of any answer as it reaches a
    #   receiver's funnel, which abi/services/inspect.txt's receivers carry as
    #   their funnel_depth floor (inspect_funnel_depth_min);
    # * oversized_records, the paths whose largest record without entries
    #   passes the answer bound inspect_reply_max, which the inspector could
    #   only send by cutting it, so the build refuses them.
    #
    # Both follow the record shape of design-live.md's "Inspection records":
    # a map of schema, path, kind, id, attrs and children, and entries on a
    # path marked with them. Every attribute is counted at its largest value,
    # every attribute of the kind present, development-build ones included.
    module InspectionBounds
      # An {error, Reason} value's reason is an atom: at most 255 bytes.
      MAX_ATOM = 255
      U32_MAX = 0xffffffff

      module_function

      # The funnel counts the containers open outside tail positions
      # (include/erx/etf.h). This counts every element of a container as
      # nested, the last one too, so the bound holds whatever order a map's
      # entries travel in. Outermost is the facet's reply as the grantee's
      # funnel takes it, {[alias | Alias], {partial, [Record]}}, which nests
      # a record no less deep than the agent's {Alias, Answer} to the query
      # worker: the outer tuple, {partial, _} and the list.
      def funnel_depth(schema)
        3 + schema.paths.map { |path| record_depth(schema, path) }.max.to_i
      end

      # [[path, kind, bytes]] for each path whose largest record, without entries
      # and inside the larger of its answers, entries' {partial, [Record]}, encodes
      # past REPLY_MAX.
      def oversized_records(schema, reply_max)
        schema.paths.filter_map do |path|
          bytes = 1 + tuple_size(atom_size('partial'), list_size([record_size(schema, path)]))
          [path, path.kind, bytes] if bytes > reply_max
        end
      end

      # A path as the schema writes it, for a diagnostic.
      def path_text(path)
        path.segments.map { |segment| segment.literal || "*#{segment.type}" }.join(' ')
      end

      def record_depth(schema, path)
        attrs = attributes(schema, path).map { |attr| 2 + value_depth(schema, attr.type) }
        entries = path.entries ? 3 + value_depth(schema, path.entries.first) : 0
        segment = path.segments.filter_map { |item| item.type && value_depth(schema, item.type) }.max || 0
        child = path.variable_child ? value_depth(schema, path.variable_child) : 0
        # attrs map; path list of segments; children {partial, [Segment]}.
        fields = { 'attrs' => 1 + (attrs.max || 0), 'path' => 1 + segment, 'children' => 2 + child,
                   'id' => segment, 'entries' => entries }
        1 + fields.values.max
      end

      def value_depth(schema, reference)
        type = schema.types.fetch(reference)
        case type.form
        when 'integer', 'text', 'atoms', 'boolean' then 0
        when 'flags', 'proc_id' then 1
        when 'list' then 1 + value_depth(schema, type.element)
        when 'tuple' then 1 + type.elements.map { |element| value_depth(schema, element) }.max
        end
      end

      # The record map without entries: its children are the literal names
      # alone, since a listing's variable children are cut by bytes as
      # entries are.
      def record_size(schema, path)
        segments = path.segments.map { |segment| segment_size(schema, segment) }
        attrs = attributes(schema, path).sum do |attr|
          atom_size(attr.key) + tuple_size(reporter_size(schema, attr), status_size(value_size(schema, attr.type)))
        end
        children = list_size(path.literal_children.map { |name| atom_size(name) })
        fields = { 'schema' => integer_size(schema.version), 'path' => list_size(segments),
                   'kind' => atom_size(path.kind), 'id' => (segments + [proc_id_size]).max,
                   'attrs' => 5 + attrs, 'children' => [tuple_size(atom_size('partial'), children), atom_size('unknown')].max }
        5 + fields.sum { |key, size| atom_size(key) + size }
      end

      def attributes(schema, path) = schema.kinds.fetch(path.kind, [])

      def segment_size(schema, segment)
        segment.literal ? atom_size(segment.literal) : value_size(schema, segment.type)
      end

      def reporter_size(schema, attr)
        attr.reporters.map do |name|
          schema.stopgaps.key?(name) ? tuple_size(atom_size('stopgap'), atom_size(name)) : atom_size(name)
        end.max
      end

      # A tagged value: {ok, V}, {partial, V}, {timeout, Ms}, {error, Reason},
      # unknown or unsupported.
      def status_size(value)
        [tuple_size(atom_size('partial'), value), tuple_size(atom_size('timeout'), integer_size(U32_MAX)),
         tuple_size(atom_size('error'), 2 + MAX_ATOM), atom_size('unsupported')].max
      end

      def value_size(schema, reference)
        type = schema.types.fetch(reference)
        case type.form
        when 'integer' then [type.minimum, type.maximum].map { |bound| integer_size(bound) }.max
        when 'text' then 5 + type.maximum
        when 'atoms' then type.atoms.map { |atom| atom_size(atom) }.max
        when 'flags' then list_size(type.atoms.map { |atom| atom_size(atom) })
        when 'boolean' then atom_size('false')
        when 'proc_id' then proc_id_size
        when 'list' then list_size(Array.new(type.maximum, value_size(schema, type.element)))
        when 'tuple' then tuple_size(*type.elements.map { |element| value_size(schema, element) })
        end
      end

      # The external term format's sizes (erts/doc/src/erl_ext_dist.xml):
      # SMALL_ATOM_UTF8_EXT, SMALL_INTEGER_EXT, INTEGER_EXT, SMALL_BIG_EXT,
      # SMALL_TUPLE_EXT, LIST_EXT with its NIL_EXT tail, and NIL_EXT alone.
      def atom_size(name) = 2 + name.to_s.bytesize

      def integer_size(value)
        return 2 if value.between?(0, 255)
        return 5 if value.between?(-(1 << 31), (1 << 31) - 1)

        3 + ((value.abs.bit_length + 7) / 8)
      end

      def tuple_size(*elements) = 2 + elements.sum

      def list_size(elements) = elements.empty? ? 1 : 5 + elements.sum + 1

      # {pid, Domain, Number, Serial}, each below 2^32.
      def proc_id_size = tuple_size(atom_size('pid'), *Array.new(3, integer_size(U32_MAX)))
    end
  end
end
