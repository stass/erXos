# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'

module Erx
  # How a harness reads or changes a manifest's text: a number of a named record read,
  # grown or set, or a configured domain taken out with the records only it uses
  # (without_domain), every other byte of the text, comments included, unchanged. A record starts
  # at a line of its own at the left margin ("machine", "principal system",
  # "runtime_limits system") and its fields are the two-space-indented lines below it,
  # each a name and a value, up to the first line that is not so indented (a blank or
  # comment line ends a record); the edit reaches a field only through its record, so a
  # field of the same name in another record is never touched. A record that is not in
  # the text exactly once, a field that is not in its record exactly once, or a value
  # that is not a decimal number is refused, so an edit is never silently lost.
  module ManifestText
    # One record of a manifest: its kind and name, from its first line ("limits web" is
    # kind limits, name web; "machine" has no name; a directive's name is its arguments,
    # "introduce @domain.a @domain.b"), the range of its lines, and its fields, each
    # [name, value], the value the rest of the line after the name. A record names a
    # reference ("@limits.web") that is one of its fields' values or of its directive's arguments.
    Record = Data.define(:kind, :name, :lines, :fields) do
      def reference = "@#{kind}.#{name}"
      def field(name) = fields.find { |field, _value| field == name }&.last
      def names?(reference) = [*name.to_s.split(' '), *fields.map(&:last)].include?(reference)
    end

    module_function

    # source without the configured domain called name, as if it had never been written in.
    #
    # Taken out: the domain's record; the units it holds; the services it serves, each
    # with its display record and the facets that grant it; and its limits, then the
    # share and runtime limits they name, each unless a record left in the text still
    # names it (limits first, so limits another domain keeps keep their share too).
    #
    # Given back, where the manifest reckons the room: the domain's principal loses its
    # limits' memory and outer budget and one domain of its quota; the machine loses the
    # same budgets and its units' DMA memory from root_memory (each a device's dma_memory
    # in units, the platform record's units, which the domain library charges to the
    # system's budget), one domain from max_domains, and the domain's system connection
    # from max_connections (which the manifest reckons in its comments, one per
    # configured domain).
    #
    # Refused: a domain that is not there once; one whose service a session or another
    # domain is granted, since what such a grant takes of max_connections and its
    # server's connections is the manifest's own reckoning, in its comments; a removal
    # that leaves a record naming a record it took out (a facet granted to the domain, an
    # introduction, a start row on its display); a unit placed on no unit of units; and
    # a text records cannot read whole (see records).
    def without_domain(source, name, units:)
      lines = source.lines
      all = records(lines)
      domain = defined_by(all, "@domain.#{name}")
      principal = defined_by(all, domain.field('principal'))
      limits = defined_by(all, domain.field('limits'))
      held = all.select { |record| %w[unit service].include?(record.kind) && record.names?(domain.reference) }
      services = held.select { |record| record.kind == 'service' }
      facets = all.select { |record| record.kind == 'facet' && services.any? { |service| record.names?(service.reference) } }
      displays = all.select { |record| record.kind == 'display' && services.any? { |service| service.name == record.name } }
      foreign = facets.reject { |facet| facet.field('grantee') == 'system' }
      raise Error, "domain #{name}'s service is granted by facet #{foreign.first.name}, not to the system domain alone" if foreign.any?

      definitions = [limits, defined_by(all, limits.field('grant')), defined_by(all, limits.field('runtime_limits'))]
      removed = with_unused_definitions(all, [domain, *held, *facets, *displays], definitions)
      dangling = (all - removed).find { |record| removed.any? { |gone| record.names?(gone.reference) } }
      raise Error, "the manifest's #{dangling.kind} #{dangling.name} names a record domain #{name} takes with it" if dangling

      budget = %w[memory outer].sum { |field| decimal(limits, field) }
      dma = held.select { |record| record.kind == 'unit' }.sum { |unit| unit_dma(unit, units) }
      header = "#{principal.kind} #{principal.name}"
      kept = lines.each_index.reject { |index| removed.any? { |record| record.lines.cover?(index) } }
      grow(kept.map { |index| lines[index] }.join,
           { [header, 'memory'] => -budget, [header, 'domains'] => -1, %w[machine root_memory] => -(budget + dma),
             %w[machine max_domains] => -1, %w[machine max_connections] => -1 })
    end

    # The records of a manifest's lines, in order: each starts at a line at the left
    # margin and holds the two-space-indented lines below it. The manifest's own reader
    # skips blank and comment lines inside a record, which this reading does not, so a
    # field after such a line is refused rather than left behind on the record before it
    # when that record goes.
    def records(lines)
      starts = lines.each_index.select { |index| lines[index].match?(/\A[a-z]/) }
      found = starts.map do |first|
        body = (first + 1...lines.size).take_while { |index| lines[index].start_with?('  ') }
        kind, name = lines[first].chomp.split(' ', 2)
        Record.new(kind: kind, name: name, lines: first..(body.last || first),
                   fields: body.map { |index| lines[index].strip.split(' ', 2) })
      end
      stray = lines.each_index.find { |index| lines[index].start_with?('  ') && found.none? { |record| record.lines.cover?(index) } }
      raise Error, "the manifest's line #{stray + 1} is a field outside a record ManifestText can read" if stray

      found
    end

    # The one record reference (@kind.name) names in records.
    def defined_by(records, reference)
      found = records.select { |record| record.reference == reference }
      raise Error, "the manifest does not have exactly one record #{reference}" unless found.size == 1

      found.first
    end

    # removed with each of definitions that no record outside removed still names.
    def with_unused_definitions(records, removed, definitions)
      definitions.reduce(removed) do |gone, definition|
        used = (records - gone - [definition]).any? { |record| record.names?(definition.reference) }
        used ? gone : gone + [definition]
      end
    end

    # The DMA memory of the platform unit unit is placed on, in bytes.
    def unit_dma(unit, units)
      key = unit.field('placement').to_s.delete_prefix('"').delete_suffix('"')
      platform_unit = units.find { |row| row.is_a?(Hash) && row['key'] == key && row['devices'].is_a?(Array) } or
        raise Error, "the manifest's unit #{unit.name} is placed on #{key.inspect}, which the platform has no unit of"
      platform_unit.fetch('devices').sum do |device|
        bytes = device['dma_memory']
        raise Error, "the platform unit #{key}'s device has no whole dma_memory" unless bytes.is_a?(Integer) && !bytes.negative?

        bytes
      end
    end

    # The decimal number of field in record.
    def decimal(record, field)
      value = record.field(field).to_s
      raise Error, "the manifest's #{record.kind} #{record.name} #{field} is not a decimal number" unless value.match?(/\A[0-9]+\z/)

      Integer(value, 10)
    end

    # source with each [record, field] of growth grown by its number; a negative number
    # shrinks it.
    def grow(source, growth) = edit(source, growth) { |value, added| value + added }

    # The number of field in the one record named record, refused as an edit is.
    def value(source, record:, field:)
      lines = source.lines
      number(lines, field_index(lines, record: record, field: field), record: record, field: field)
    end

    # source with each [record, field] of values set to its number.
    def set(source, values) = edit(source, values) { |_value, given| given }

    # source with each [record, field] of changes replaced by what the block returns
    # for the field's value and the change's number, edited in order.
    def edit(source, changes)
      changes.reduce(source.lines) do |lines, ((record, field), change)|
        index = field_index(lines, record: record, field: field)
        result = yield number(lines, index, record: record, field: field), change
        raise Error, "the manifest's #{record} #{field} would be #{result}" unless result.is_a?(Integer) && !result.negative?

        lines.dup.tap { |edited| edited[index] = "  #{field} #{result}#{lines[index][/\n\z/]}" }
      end.join
    end

    # The index in lines of the one line of field in the one record named record.
    def field_index(lines, record:, field:)
      starts = lines.each_index.select { |index| lines[index].chomp == record }
      raise Error, "the manifest does not have exactly one #{record} record" unless starts.size == 1

      body = (starts.first + 1...lines.size).take_while { |index| lines[index].start_with?('  ') }
      found = body.select { |index| lines[index].start_with?("  #{field} ") }
      raise Error, "the manifest's #{record} record does not have exactly one #{field} field" unless found.size == 1

      found.first
    end

    # The decimal number on the line at index, field's line in record.
    def number(lines, index, record:, field:)
      value = lines[index].chomp.delete_prefix("  #{field} ")
      raise Error, "the manifest's #{record} #{field} is not a decimal number" unless value.match?(/\A[0-9]+\z/)

      Integer(value, 10)
    end
    private_class_method :field_index, :number, :records, :defined_by, :with_unused_definitions, :unit_dma, :decimal
  end
end
