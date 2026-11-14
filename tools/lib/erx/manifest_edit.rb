# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'manifest'

module Erx
  module Manifest
    # How a harness changes a manifest: a number of a named record read, grown or set, or
    # a configured domain taken out with the records only it uses (without_domain). Each
    # reads the text with the manifest's own reader (Frontend.read), changes the records
    # it read, and writes them with its one printer (Frontend.render), so an edit reaches
    # a field only through its record and the result is a manifest the reader takes, but
    # its comments are gone. A record is named by its first line, "machine",
    # "principal system" or "limits display"; one that is not there, a field it does not
    # have, or a value that is not one decimal number is refused, so an edit is never
    # silently lost.
    module Edit
      DECIMAL = /\A[0-9]+\z/.freeze

      module_function

      # text with each [record, field] of growth grown by its number; a negative number
      # shrinks it.
      def grow(text, growth) = Frontend.render(changed(Frontend.read(text), growth) { |value, added| value + added })

      # text with each [record, field] of values set to its number.
      def set(text, values) = Frontend.render(changed(Frontend.read(text), values) { |_value, given| given })

      # The number of field in the record named record.
      def value(text, record:, field:) = decimal(named(Frontend.read(text), record), field)

      # text without the configured domain called name, as if it had never been written in.
      #
      # Taken out: the domain's record; the units it holds; the services it serves, each
      # with its display record and the facets that grant it; and its limits, then the
      # share and runtime limits they name, each unless a record left in still names it
      # (limits first, so limits another domain keeps keep their share too).
      #
      # Given back, where the manifest reckons the room: the domain's principal loses its
      # limits' memory and outer budget and one domain of its quota; the machine loses the
      # same budgets and its units' DMA memory from root_memory (each a device's dma_memory
      # in units, the platform record's units, which the domain library charges to the
      # system's budget), one domain from max_domains, and the domain's system connection
      # from max_connections (which the manifest reckons in its comments, one per
      # configured domain).
      #
      # Refused: a domain that is not there; one whose service a session or another domain
      # is granted, since what such a grant takes of max_connections and its server's
      # connections is the manifest's own reckoning, in its comments; a removal that leaves
      # a record naming a record it took out (a facet granted to the domain, an
      # introduction, a start row on its display); and a unit placed on no unit of units.
      def without_domain(text, name, units:)
        source = Frontend.read(text)
        all = source.records.values.flatten
        domain = defined_by(all, "@domain.#{name}")
        principal = defined_by(all, reference(domain, 'principal'))
        limits = defined_by(all, reference(domain, 'limits'))
        held = all.select { |record| %w[unit service].include?(record.kind) && names?(record, reference_of(domain)) }
        services = held.select { |record| record.kind == 'service' }
        facets = all.select { |record| record.kind == 'facet' && services.any? { |service| names?(record, reference_of(service)) } }
        displays = all.select { |record| record.kind == 'display' && services.any? { |service| service.name == record.name } }
        foreign = facets.find { |facet| reference(facet, 'grantee') != 'system' }
        raise Error, "domain #{name}'s service is granted by facet #{foreign.name}, not to the system domain alone" if foreign

        definitions = [limits, defined_by(all, reference(limits, 'grant')), defined_by(all, reference(limits, 'runtime_limits'))]
        removed = with_unused_definitions([source.machine, *all], [domain, *held, *facets, *displays], definitions)
        kept = all.reject { |record| removed.any? { |gone| gone.equal?(record) } }
        # The machine names records too (system_share, native_limits, ...), and is never taken.
        dangling = [source.machine, *kept].find { |record| removed.any? { |gone| names?(record, reference_of(gone)) } }
        raise Error, "the manifest's #{header(dangling)} names a record domain #{name} takes with it" if dangling

        budget = %w[memory outer].sum { |field| decimal(limits, field) }
        dma = held.select { |record| record.kind == 'unit' }.sum { |unit| unit_dma(unit, units) }
        principal_header = header(principal)
        changes = { [principal_header, 'memory'] => -budget, [principal_header, 'domains'] => -1,
                    %w[machine root_memory] => -(budget + dma), %w[machine max_domains] => -1,
                    %w[machine max_connections] => -1 }
        remaining = Source.new(version: source.version, machine: source.machine,
                               records: kept.group_by(&:kind).transform_values(&:freeze).freeze).freeze
        Frontend.render(changed(remaining, changes) { |value, added| value + added })
      end

      # source with each [record, field] of changes replaced by what the block returns for
      # the field's value and the change's number, changed in order.
      def changed(source, changes)
        changes.reduce(source) do |current, ((name, field), change)|
          record = named(current, name)
          result = yield decimal(record, field), change
          raise Error, "the manifest's #{name} #{field} would be #{result}" unless result.is_a?(Integer) && !result.negative?

          token = ABI::Token.new(value: result.to_s.freeze, quoted: false).freeze
          replaced(current, record, Record.new(**record.to_h, properties: record.properties.merge(field => [token].freeze).freeze).freeze)
        end
      end

      # source with record, which it holds, replaced by replacement in its place.
      def replaced(source, record, replacement)
        return Source.new(**source.to_h, machine: replacement).freeze if record.equal?(source.machine)

        records = source.records.merge(record.kind => source.records.fetch(record.kind).map do |each|
          each.equal?(record) ? replacement : each
        end.freeze)
        Source.new(**source.to_h, records: records.freeze).freeze
      end

      # The record of source whose first line is name ("machine", "principal system").
      def named(source, name)
        kind, alias_name = name.split(' ', 2)
        found = kind == 'machine' && alias_name.nil? ? source.machine : source.records.fetch(kind, []).find { |record| record.name == alias_name }
        found or raise Error, "the manifest has no #{name} record"
      end

      # The one record reference (@kind.name) names among records.
      def defined_by(records, reference)
        records.find { |record| reference_of(record) == reference } or
          raise Error, "the manifest has no record #{reference.inspect}"
      end

      # removed with each of definitions that no record outside removed still names.
      def with_unused_definitions(records, removed, definitions)
        definitions.reduce(removed) do |gone, definition|
          others = records.reject { |record| (gone + [definition]).any? { |each| each.equal?(record) } }
          others.any? { |record| names?(record, reference_of(definition)) } ? gone : gone + [definition]
        end
      end

      # The record's first line, its kind then its name or a directive's arguments.
      def header(record) = [record.kind, record.name || record.properties['targets']&.map(&:value)&.join(' ')].compact.join(' ')

      # How a record names this one in a field: @kind.name.
      def reference_of(record) = "@#{record.kind}.#{record.name}"

      # Whether one of record's unquoted tokens, a field's, a directive's or a facet
      # parameter's, is reference.
      def names?(record, reference)
        [*record.properties.values, *record.parameters].flatten.any? { |token| !token.quoted && token.value == reference }
      end

      # The one unquoted token of field in record, as a string.
      def reference(record, field)
        tokens = record.properties.fetch(field, [])
        raise Error, "the manifest's #{header(record)} #{field} is not one reference" unless tokens.size == 1 && !tokens.first.quoted

        tokens.first.value
      end

      # The DMA memory of the platform unit unit is placed on, in bytes.
      def unit_dma(unit, units)
        key = record_string(unit, 'placement')
        platform_unit = units.find { |row| row.is_a?(Hash) && row['key'] == key && row['devices'].is_a?(Array) } or
          raise Error, "the manifest's unit #{unit.name} is placed on #{key.inspect}, which the platform has no unit of"
        platform_unit.fetch('devices').sum do |device|
          bytes = device['dma_memory']
          raise Error, "the platform unit #{key}'s device has no whole dma_memory" unless bytes.is_a?(Integer) && !bytes.negative?

          bytes
        end
      end

      # The one quoted token of field in record.
      def record_string(record, field)
        tokens = record.properties.fetch(field, [])
        raise Error, "the manifest's #{header(record)} #{field} is not one string" unless tokens.size == 1 && tokens.first.quoted

        tokens.first.value
      end

      # The decimal number of field in record.
      def decimal(record, field)
        tokens = record.properties.fetch(field) { raise Error, "the manifest's #{header(record)} record has no #{field} field" }
        raise Error, "the manifest's #{header(record)} #{field} is not a decimal number" unless
          tokens.size == 1 && !tokens.first.quoted && tokens.first.value.match?(DECIMAL)

        Integer(tokens.first.value, 10)
      end
      private_class_method :changed, :replaced, :named, :defined_by, :with_unused_definitions, :header, :reference_of,
                           :names?, :reference, :unit_dma, :record_string, :decimal
    end
  end
end
