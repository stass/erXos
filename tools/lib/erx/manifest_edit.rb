# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'error'
require_relative 'manifest'

module Erx
  module Manifest
    # How a harness changes a manifest: a number of a named record read, grown or set, the
    # record a reference names read (referenced), a reference pointed elsewhere, named records taken out (without), a facet's parameter
    # taken out (without_parameter), the session templates taken out (without_sessions), the apps row taken out with the room it took
    # (without_apps), or a configured domain taken out with the records only it uses
    # (without_domain). Each reads the text with the manifest's own
    # reader (Frontend.read), changes the records it read, and writes them with its one
    # printer (Frontend.render), so an edit reaches a field only through its record and
    # the result is a manifest the reader takes, but its comments are gone. A record is
    # named by its first line, "machine", "principal system" or "limits display"; one
    # that is not there, a field it does not have, or a value of another form than the
    # edit's is refused, and so is a removal that leaves a record naming one it took, so
    # an edit is never silently lost. The one exception: set states a field the record
    # leaves out where its kind may leave it out.
    module Edit
      module_function

      # text with each [record, field] of growth grown by its number; a negative number
      # shrinks it.
      def grow(text, growth) = Frontend.render(grown(Frontend.read(text), growth))

      # text with each [record, field] of values set to its number. A field the record
      # leaves out is stated only where its kind may leave it out (Frontend::OPTIONAL), as
      # the website's machine states its boot timeout (InteractiveBoot).
      def set(text, values)
        Frontend.render(changed(Frontend.read(text), values) do |record, field, given|
          settable!(record, field)
          given
        end)
      end

      # The number of field in the record named record.
      def value(text, record:, field:) = named(Frontend.read(text), record).decimal(field)

      # The record that field of the record named record refers to, such as the share
      # that "principal system"'s grant names.
      def referenced(text, record:, field:)
        source = Frontend.read(text)
        defined_by(source.records.values.flatten, named(source, record).reference(field))
      end

      # text with field of the record named record, which must be the one reference
      # from, made the reference to: an edit of a row that no longer reads from is
      # refused rather than applied to whatever it reads now.
      def repoint(text, record:, field:, from:, to:)
        source = Frontend.read(text)
        found = named(source, record)
        raise Error, "the manifest's #{record} #{field} is #{found.reference(field)}, not #{from}" unless
          found.reference(field) == from

        token = ABI::Token.new(value: to.dup.freeze, quoted: false).freeze
        Frontend.render(replaced(source, found, with_field(found, field, token)))
      end

      # text without the records records names, each by its first line ("domain network",
      # "unit net"); nothing else changes, so what they took of a budget stays counted.
      def without(text, records)
        source = Frontend.read(text)
        Frontend.render(removed(source, records.map { |name| named(source, name) }))
      end

      # text with the parameter key of the facet named record taken out, which the facet
      # must set, so an edit of a row that no longer sets it is refused rather than lost.
      def without_parameter(text, record:, key:)
        source = Frontend.read(text)
        found = named(source, record)
        kept = found.parameters.reject { |name, _value| name.value == key }
        raise Error, "the manifest's #{record} sets no parameter #{key}" if kept.size == found.parameters.size

        Frontend.render(replaced(source, found, Record.new(**found.to_h, parameters: kept.freeze).freeze))
      end

      # text with no session template: every session record, and every facet granted to
      # one, which would name a template no longer there.
      def without_sessions(text)
        source = Frontend.read(text)
        sessions = source.records.fetch('session', [])
        facets = source.records.fetch('facet', []).select do |facet|
          sessions.any? { |session| facet.reference('grantee') == reference_of(session) }
        end
        Frontend.render(removed(source, sessions + facets))
      end

      # text without the configured domain called name, as if it had never been written in.
      #
      # Taken out: the domain's record; the units and windows it holds, and every drive
      # window that lies on a device of a unit it holds, another domain's too; the services it
      # serves, each with its display record and the facets that grant it; the facets that
      # grant it a service the system domain serves, which its system connection carries;
      # and its limits, then the share and runtime limits they name, each unless a record
      # left in still names it (limits first, so limits another domain keeps keep their
      # share too). A window takes no budget, so it gives back no room.
      #
      # Given back, where the manifest reckons the room: the domain's principal loses its
      # limits' memory and outer budget and one domain of its quota; the machine loses the
      # same budgets and its units' DMA memory from root_memory (each a device's dma_memory
      # in units, the platform record's units, which the domain library charges to the
      # system's budget), one domain from max_domains, and the domain's system connection
      # from max_connections (which the manifest reckons in its comments, one per
      # configured domain); and when root's template, the system principal's, is granted
      # one of its services, two of max_connections, its session's one connection to the
      # domain and the one a replacement session makes beside it, as the manifest reckons
      # root's display_root; and for each other configured domain joined to it by a facet,
      # one of its services granted to that domain or one of that domain's granted to it,
      # as usb_input joins the USB and display domains, one of max_connections and one of
      # the other domain's limits' connections: their one connection, however many facets
      # it carries, a drive window counting as such a grant: one it holds on a unit of the
      # other domain's, or the other's on one of its units (docs/design-drives.md, "How the
      # grant reaches the media domain").
      #
      # Refused: a domain that is not there; one whose service another principal's
      # template is granted; a removal that
      # leaves a record naming a record it took out (an introduction, a start row on its
      # display); and a unit placed on no unit of units.
      def without_domain(text, name, units:)
        source = Frontend.read(text)
        all = source.records.values.flatten
        domain = defined_by(all, "@domain.#{name}")
        principal = defined_by(all, domain.reference('principal'))
        limits = defined_by(all, domain.reference('limits'))
        held = all.select { |record| %w[unit window service].include?(record.kind) && names?(record, reference_of(domain)) }
        on_units = windows_on(all, held.select { |record| record.kind == 'unit' }, units)
                   .select { |window| window.reference('role') == 'drive' }
        joined = [*on_units, *held.select { |record| record.kind == 'window' }].flat_map do |window|
          window.reference('role') == 'drive' ? drive_holders(all, window, units) : []
        end
        services = held.select { |record| record.kind == 'service' }
        facets = all.select { |record| record.kind == 'facet' && services.any? { |service| names?(record, reference_of(service)) } }
        displays = all.select { |record| record.kind == 'display' && services.any? { |service| service.name == record.name } }
        peers = facets.select { |facet| facet.reference('grantee').start_with?('@domain.') }
        foreign = (facets - peers).find { |facet| !%w[system @session.system].include?(facet.reference('grantee')) }
        raise Error, "domain #{name}'s service is granted by facet #{foreign.name}, not to the system domain or root" if foreign

        held_facets = all.select { |record| record.kind == 'facet' && record.reference('grantee') == reference_of(domain) }
        servers = held_facets.map { |facet| defined_by(all, facet.reference('service')).reference('server') } - ['system']
        others = (peers.map { |facet| facet.reference('grantee') } + servers + joined).uniq - [reference_of(domain)]

        root = facets.any? { |facet| facet.reference('grantee') == '@session.system' } ? 1 : 0

        definitions = [limits, defined_by(all, limits.reference('grant')), defined_by(all, limits.reference('runtime_limits'))]
        remaining = removed(source, with_unused_definitions([source.machine, *all], [domain, *held, *on_units, *facets, *held_facets, *displays].uniq, definitions))

        budget = %w[memory outer].sum { |field| limits.decimal(field) }
        dma = held.select { |record| record.kind == 'unit' }.sum { |unit| unit_dma(unit, units) }
        connections = others.map { |other| [defined_by(all, defined_by(all, other).reference('limits')).header, 'connections'] }
                            .tally.transform_values(&:-@)
        changes = { [principal.header, 'memory'] => -budget, [principal.header, 'domains'] => -1,
                    %w[machine root_memory] => -(budget + dma), %w[machine max_domains] => -1,
                    %w[machine max_connections] => -1 - (2 * root) - others.size }.merge(connections)
        Frontend.render(grown(remaining, changes))
      end

      # text with the platform unit key of units placed on holder and root_memory grown by
      # the unit's DMA memory, as the manifest check counts it: the inverse of what
      # without_domain does for each unit it takes out. Refused: a key units has no unit of.
      def with_unit(text, key, holder:, units:)
        record = "unit #{key}\n  placement \"#{key}\"\n  holder #{holder}\n"
        unit = Frontend.records(record, path: 'with_unit').first
        grow(text, { %w[machine root_memory] => unit_dma(unit, units) }) + record
      end

      # text without its apps row, as if it had never been written in, or text itself when
      # it has none (docs/design-packaging.md, "The apps row"). Given back: the row's
      # memory from root_memory, its max apps from max_domains, each app a principal with
      # a domains quota of one, and from max_connections each app's system connection, its
      # packages connection and one for each service of its services, which the manifest
      # reckons in its comments (TODO.md: property 19's second clause should count them).
      # The row must state max: what it takes is reckoned from the number written. What
      # the row's services took of their servers stays: a server's limits are shared
      # records, and a site that leaves the server out gives its room back with it.
      def without_apps(text)
        source = Frontend.read(text)
        apps = source.records.fetch('apps', []).first
        return text unless apps

        max = apps.decimal('max')
        services = apps.properties.fetch('services', []).size
        changes = { %w[machine root_memory] => -apps.decimal('memory'), %w[machine max_domains] => -max,
                    %w[machine max_connections] => -max * (2 + services) }
        Frontend.render(grown(removed(source, [apps]), changes))
      end

      # source with each [record, field] of growth grown by its number.
      def grown(source, growth) = changed(source, growth) { |record, field, added| record.decimal(field) + added }

      # source with each [record, field] of changes replaced by what the block returns for
      # the record, the field and the change's number, changed in order.
      def changed(source, changes)
        changes.reduce(source) do |current, ((name, field), change)|
          record = named(current, name)
          result = yield record, field, change
          raise Error, "the manifest's #{name} #{field} would be #{result}" unless result.is_a?(Integer) && !result.negative?

          token = ABI::Token.new(value: result.to_s.freeze, quoted: false).freeze
          replaced(current, record, with_field(record, field, token))
        end
      end

      # Refuses to set field of record unless the record holds a number there or leaves it
      # out where its kind may (Frontend::OPTIONAL). A stated field's form is the manifest
      # check's to judge, as every other field's is.
      def settable!(record, field)
        return if !record.properties.key?(field) && Frontend::OPTIONAL.fetch(record.kind, []).include?(field)

        record.decimal(field) # raises unless the record holds one decimal number there
      end

      # record with field holding token alone.
      def with_field(record, field, token)
        Record.new(**record.to_h, properties: record.properties.merge(field => [token].freeze).freeze).freeze
      end

      # source with record, which it holds, replaced by replacement in its place.
      def replaced(source, record, replacement)
        return Source.new(**source.to_h, machine: replacement).freeze if record.equal?(source.machine)

        records = source.records.merge(record.kind => source.records.fetch(record.kind).map do |each|
          each.equal?(record) ? replacement : each
        end.freeze)
        Source.new(**source.to_h, records: records.freeze).freeze
      end

      # source without gone, records it holds, refused when a record left in names one of
      # them. The machine names records too (system_share, native_limits, ...), and is
      # never taken.
      def removed(source, gone)
        raise Error, "the manifest's machine record cannot be taken out" if gone.any? { |record| record.equal?(source.machine) }

        kept = source.records.values.flatten.reject { |record| gone.any? { |each| each.equal?(record) } }
        [source.machine, *kept].each do |record|
          taken = gone.find { |each| names?(record, reference_of(each)) }
          raise Error, "the manifest's #{record.header} names a record the edit takes out, #{reference_of(taken)}" if taken
        end
        Source.new(version: source.version, machine: source.machine,
                   records: kept.group_by(&:kind).transform_values(&:freeze).freeze).freeze
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

      # How a record names this one in a field: @kind.name.
      def reference_of(record) = "@#{record.kind}.#{record.name}"

      # Whether one of record's unquoted tokens, a field's, a directive's or a facet
      # parameter's, is reference.
      def names?(record, reference)
        [*record.properties.values, *record.parameters].flatten.any? { |token| !token.quoted && token.value == reference }
      end

      # The DMA memory of the platform unit unit is placed on, in bytes.
      def unit_dma(unit, units)
        platform_unit(unit, units).fetch('devices').sum do |device|
          bytes = device['dma_memory']
          raise Error, "the platform unit #{unit.string('placement')}'s device has no whole dma_memory" unless bytes.is_a?(Integer) && !bytes.negative?

          bytes
        end
      end

      # The record of units, the platform's, that the manifest's unit is placed on.
      # Refused: a placement units has no unit of.
      def platform_unit(unit, units)
        key = unit.string('placement')
        units.find { |row| placed_unit?(row) && row['key'] == key } or
          raise Error, "the manifest's unit #{unit.name} is placed on #{key.inspect}, which the platform has no unit of"
      end

      def placed_unit?(row) = row.is_a?(Hash) && row['devices'].is_a?(Array)

      # The windows of records that lie on a device of one of the units taken.
      def windows_on(records, taken, units)
        names = taken.flat_map { |unit| device_names(platform_unit(unit, units)) }
        records.select { |record| record.kind == 'window' && names.include?(record.string('device')) }
      end

      # The holders of a drive window and of the unit its device lies on, when they are two
      # configured domains, which its drive grant joins by one connection; none otherwise.
      def drive_holders(records, window, units)
        placed = units.find { |row| placed_unit?(row) && device_names(row).include?(window.string('device')) }
        unit = placed && records.find { |record| record.kind == 'unit' && record.string('placement') == placed['key'] }
        holders = [window.reference('holder'), unit&.reference('holder')].compact.uniq - ['system']
        holders.size == 2 ? holders : []
      end

      # The names windows give the devices of platform_unit (Manifest.device_name).
      # Refused: a device that is neither a device-tree node nor a whole PCIe place.
      def device_names(platform_unit)
        platform_unit.fetch('devices').map do |device|
          Manifest.device_name(device, pci: device.is_a?(Hash) && device['selector'] == 'pci') or
            raise Error, "the platform unit #{platform_unit['key']} has a device with no name a window can give"
        end
      end
      private_class_method :changed, :with_field, :replaced, :removed, :named, :defined_by, :with_unused_definitions,
                           :reference_of, :names?, :unit_dma, :platform_unit, :placed_unit?, :windows_on,
                           :drive_holders, :device_names
    end
  end
end
