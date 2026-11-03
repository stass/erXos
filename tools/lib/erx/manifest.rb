# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'abi_binary'

module Erx
  module Manifest
    class Invalid < Erx::Error
      attr_reader :property, :field

      def initialize(message, property:, field:)
        @property = property
        @field = field.freeze
        super("manifest #{property} #{field}: #{message}")
      end
    end
    class Unsupported < Invalid; end

    module Snapshot
      module_function

      def copy(value, depth: 0)
        raise Invalid.new('context nesting exceeds 64', property: 'context', field: 'input') if depth > 64
        case value
        when Hash
          unless value.keys.all? { |key| key.is_a?(String) }
            raise Invalid.new('context keys must be strings', property: 'context', field: 'input')
          end
          value.sort_by { |key, _item| key.b }.to_h do |key, item|
            [key.dup.freeze, copy(item, depth: depth + 1)]
          end.freeze
        when Array
          value.map { |item| copy(item, depth: depth + 1) }.freeze
        when String
          value.dup.freeze
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise Invalid.new('context contains an unsupported value', property: 'context', field: 'input')
        end
      end

      # Length framing preserves arbitrary original notice/path bytes without
      # treating a binary notice as JSON text or relying on hash insertion order.
      def digest(value)
        hash = Digest::SHA256.new
        append(hash, value)
        hash.hexdigest.freeze
      end

      def append(hash, value)
        case value
        when Hash
          hash << "h#{value.size}:"
          value.sort_by { |key, _item| key.b }.each do |key, item|
            append(hash, key)
            append(hash, item)
          end
        when Array
          hash << "a#{value.size}:"
          value.each { |item| append(hash, item) }
        when String
          hash << "s#{value.bytesize}:" << value.b
        when Integer
          hash << "i#{value};"
        when TrueClass then hash << 't'
        when FalseClass then hash << 'f'
        when NilClass then hash << 'n'
        end
      end
    end

    # Context is supplied by the build's checked artifact/platform boundaries,
    # never read from configuration text. Its catalog includes the reserved
    # manifest and NOTICES rows before any numeric entry index is assigned.
    class Context
      attr_reader :build_kind, :platform, :catalog, :root_entry, :artifacts,
                  :provenance, :sizing, :fingerprint

      def initialize(build_kind:, platform:, catalog:, root_entry:, artifacts:,
                     provenance:, sizing: nil)
        unless %w[development release].include?(build_kind)
          raise Invalid.new('unknown checked build kind', property: 'context', field: 'build_kind')
        end
        unless platform.is_a?(Hash) && catalog.is_a?(Array) && artifacts.is_a?(Hash) &&
               provenance.is_a?(Array) && root_entry.is_a?(Integer) && root_entry.between?(0, catalog.size - 1)
          raise Invalid.new('incomplete checked context', property: 'context', field: 'input')
        end
        notices = provenance.map do |record|
          unless record.is_a?(Hash)
            raise Invalid.new('invalid provenance record', property: 'context', field: 'provenance')
          end
          normalized = record.reject { |key, _value| key == 'notice' }
          if record.key?('notice')
            notice = record.fetch('notice')
            unless notice.is_a?(String)
              raise Invalid.new('notice must be bytes', property: 'context', field: 'provenance')
            end
            normalized = normalized.merge('notice_sha256' => Digest::SHA256.hexdigest(notice))
          end
          normalized
        end
        @build_kind = build_kind.dup.freeze
        @platform = Snapshot.copy(platform)
        @catalog = Snapshot.copy(catalog)
        @root_entry = root_entry
        @artifacts = Snapshot.copy(artifacts)
        @provenance = Snapshot.copy(notices)
        @sizing = Snapshot.copy(sizing)
        validate_catalog_shape
        @fingerprint = Snapshot.digest('build_kind' => @build_kind, 'platform' => @platform,
                                        'catalog' => @catalog, 'root_entry' => @root_entry,
                                        'artifacts' => @artifacts, 'provenance' => @provenance,
                                        'sizing' => @sizing)
        freeze
      end

      private

      def validate_catalog_shape
        previous = nil
        @catalog.each do |row|
          unless row.is_a?(Hash) && (row.keys - %w[path kind flags source image]).empty? &&
                 row['path'].is_a?(String) && row['kind'].is_a?(Integer) &&
                 row['flags'].is_a?(Integer) && row['source'].is_a?(Hash)
            raise Invalid.new('invalid catalog row', property: 'context', field: 'catalog')
          end
          path = row.fetch('path').b
          if previous && previous >= path
            raise Invalid.new('catalog paths must ascend strictly', property: 'context', field: 'catalog')
          end
          previous = path
          source = row.fetch('source')
          case source['kind']
          when 'artifact'
            unless source.keys.sort == %w[id kind sha256] && source['id'].is_a?(String) &&
                   source['sha256'].is_a?(String) && source['sha256'].match?(/\A[0-9a-f]{64}\z/)
              raise Invalid.new('invalid artifact identity', property: 'context', field: 'catalog.source')
            end
          when 'generated'
            unless source.keys.sort == %w[kind producer] && %w[manifest notices].include?(source['producer'])
              raise Invalid.new('unknown generated artifact', property: 'context', field: 'catalog.source')
            end
          else
            raise Invalid.new('unknown catalog origin', property: 'context', field: 'catalog.source')
          end
        end
      end
    end

    Record = Struct.new(:kind, :name, :properties, :parameters, :line, keyword_init: true)
    Source = Struct.new(:version, :machine, :records, keyword_init: true)

    module Frontend
      FIELDS = {
        'machine' => %w[flags host console hostlink platform root_memory system_baseline system_share users_share system_principal max_domains max_connections system_lane system_queue peer_held system_reserve sealing system_runtime_limits native_limits],
        'share' => %w[quota_ns period_ns cpuset capacity_mcpu capacity_first slice_us grace_us base ceiling flags],
        'principal' => %w[memory grant domains names default_limits ceiling_limits],
        'runtime_limits' => %w[max_frame max_message_heap funnel_depth exports tmp overlay atoms foreign_atoms processes],
        'limits' => %w[memory outer grant spaces lane connections crash flags runtime_limits peer_held peer_held_total],
        'lane_class' => %w[lane],
        'domain' => %w[principal limits kind flags runtime release restarts restart_period_s args env],
        'unit' => %w[placement holder],
        'window' => %w[holder device role partition rights image],
        'service' => %w[name server interface],
        'facet' => %w[name grantee service operations max_request in_flight reductions period_ns max_heap_size queue],
        'image' => %w[device input salt],
        'partial_boot' => %w[image]
      }.freeze
      OPTIONAL = { 'domain' => %w[args env], 'service' => %w[name],
                   'facet' => %w[name queue], 'image' => %w[salt] }.freeze
      DIRECTIVES = { 'introduce' => 2, 'liveness' => 1, 'shell_principal' => 1 }.freeze
      IDENTIFIER = /\A[a-z0-9][a-z0-9._-]{0,62}\z/.freeze
      module_function

      def parse(bytes, version:)
        declarations = ABI::Syntax.parse(bytes, path: 'config/manifest')
        headers = declarations.select { |item| item.kind == 'manifest' }
        unless headers.size == 1 && headers.first.args.size == 1 && headers.first.members.empty? &&
               ABI::Syntax.integer(headers.first.args.first, line: headers.first.line) == version
          raise Invalid.new('one supported manifest version is required', property: 'source', field: 'version')
        end
        records = Hash.new { |hash, key| hash[key] = [] }
        declarations.each do |declaration|
          next if declaration.kind == 'manifest'
          kind = declaration.kind
          if DIRECTIVES.key?(kind)
            unless declaration.args.size == DIRECTIVES.fetch(kind) && declaration.members.empty?
              declaration.fail!('invalid manifest directive')
            end
            records[kind] << Record.new(kind: kind, name: nil,
                                        properties: { 'targets' => declaration.line.tokens.drop(1).freeze }.freeze,
                                        parameters: [].freeze, line: declaration.line).freeze
            next
          end
          fields = FIELDS[kind] || declaration.fail!('unknown manifest declaration')
          if kind == 'machine'
            declaration.fail!('machine has no source alias') unless declaration.args.empty?
            name = nil
          else
            declaration.fail!('named declaration needs one identifier') unless declaration.args.size == 1 && declaration.args.first.match?(IDENTIFIER)
            name = declaration.args.first
          end
          properties = {}
          parameters = []
          declaration.members.each do |line|
            line.fail!('manifest properties have two-space indentation') unless line.indent == 2
            key = line.words.first
            if kind == 'facet' && key == 'parameter'
              line.fail!('parameter needs a key and value') unless line.tokens.size == 3
              parameters << line.tokens.drop(1).freeze
              next
            end
            line.fail!('unknown or duplicate manifest property') unless fields.include?(key) && !properties.key?(key)
            properties[key] = line.tokens.drop(1).freeze
          end
          required = fields - OPTIONAL.fetch(kind, [])
          declaration.fail!('missing required manifest property') unless (required - properties.keys).empty?
          records[kind] << Record.new(kind: kind, name: name, properties: properties.freeze,
                                      parameters: parameters.freeze, line: declaration.line).freeze
        end
        raise Invalid.new('one machine declaration is required', property: 'source', field: 'machine') unless records['machine'].size == 1
        records.each do |kind, list|
          next if kind == 'machine' || DIRECTIVES.key?(kind)
          unless list.map(&:name).uniq.size == list.size
            raise Invalid.new('duplicate source alias', property: 'source', field: kind)
          end
        end
        machine = records.delete('machine').first
        Source.new(version: version, machine: machine,
                   records: records.to_h.transform_values { |list| list.freeze }.freeze).freeze
      end
    end

    # Structural fixtures exercise canonical bytes without claiming that an
    # initial-root startup or a machine configuration has been admitted.
    class StructuralFixture
      attr_reader :bytes, :report

      def self.prepare(source:, codec:, context:, planner: nil, consumers: {})
        raise Invalid.new('checked context required', property: 'context', field: 'input') unless context.is_a?(Context)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = EmptyNative.new(parsed, codec: codec, context: context,
                                  planner: planner, consumers: consumers)
        normalized, report = checker.check
        bytes = Encoder.new(codec).encode(normalized)
        codec.open('manifest', bytes)
        new(bytes: bytes, report: report, context: context)
      end

      def initialize(bytes:, report:, context:)
        @bytes = bytes.freeze
        @report = Snapshot.copy(report)
        @fingerprint = context.fingerprint
        freeze
      end
      private_class_method :new

      def matches?(context)
        context.is_a?(Context) && context.fingerprint == @fingerprint
      end
    end

    # Initial-root feasibility requires the production bootstrap planner.
    # Source-declared costs and structural fixtures cannot mint this private
    # publication token when that evidence is unavailable.
    class Admitted
      attr_reader :bytes, :report

      def self.admit(source:, codec:, context:, planner: nil, consumers: {})
        StructuralFixture.prepare(source: source, codec: codec, context: context,
                                  planner: planner, consumers: consumers)
        raise Unsupported.new('production initial-root startup feasibility is unavailable',
                              property: 4, field: 'root_startup')
      end

      def matches?(context)
        context.is_a?(Context) && context.fingerprint == @fingerprint
      end

      private_class_method :new
    end

    def self.admit(source:, codec:, context:, planner: nil, consumers: {})
      Admitted.admit(source: source, codec: codec, context: context,
                    planner: planner, consumers: consumers)
    end

    def self.structural_fixture(source:, codec:, context:)
      StructuralFixture.prepare(source: source, codec: codec, context: context)
    end

    class EmptyNative
      TABLES = { 'principal' => 'principals', 'limits' => 'limits',
                 'runtime_limits' => 'runtime_limits', 'lane_class' => 'lane_classes' }.freeze

      def initialize(source, codec:, context:, planner:, consumers:)
        @source = source
        @codec = codec
        @context = context
        @planner = planner
        @consumers = consumers
        @reader = codec.schema.readers.find { |item| item.name == 'manifest' }
        @shares = records('share').to_h { |record| [record.name, share_record(record)] }
        @indices = TABLES.keys.to_h do |kind|
          [kind, records(kind).map(&:name).sort.each_with_index.to_h]
        end
      end

      def check
        machine = @source.machine
        flags = flags(machine, 'flags', 'manifest_flags')
        development = (flags & @codec.member('manifest_flags', 'development')) != 0
        unless development == (@context.build_kind == 'development')
          invalid('configuration conflicts with checked build kind', 9, 'machine.flags')
        end
        partial = (flags & @codec.member('manifest_flags', 'partial_boot')) != 0
        invalid('partial boot requires development mode', 9, 'machine.flags') if partial && !development
        unless partial
          unsupported('full boot needs the production sizing, planner and service consumers', 'mode')
        end
        %w[domain partial_boot].each do |kind|
          unsupported('child domain planning is unavailable', kind) unless records(kind).empty?
        end
        %w[window service facet introduce image liveness].each do |kind|
          invalid('empty native boot has no service or child assignments', 9, kind) unless records(kind).empty?
        end
        check_catalog
        platform_name = text(machine, 'platform')
        invalid('configuration names a different checked platform', 1, 'machine.platform') unless platform_name == @context.platform['name']
        parent_cpus = @context.platform['cpuset']
        unless parent_cpus.is_a?(Integer) && parent_cpus.between?(1, (1 << 64) - 1)
          invalid('checked platform requires a nonempty CPU set', 'context', 'platform.cpuset')
        end
        system_share = share(machine, 'system_share')
        users_share = share(machine, 'users_share')
        system_cpus, system_rate = effective_share(system_share, parent_cpus)
        users_cpus, users_rate = effective_share(users_share, parent_cpus)
        invalid('system grant has no execution capacity', 4, 'machine.system_share') unless system_rate.positive?
        invalid('system and users exceed the root CPU rate', 4, 'machine.shares') if system_rate + users_rate > population(parent_cpus)
        root_memory = number(machine, 'root_memory')
        baseline = number(machine, 'system_baseline')
        page = @codec.constant('page_size')
        invalid('root memory must be positive and page-aligned', 4, 'machine.root_memory') unless root_memory.positive? && (root_memory % page).zero?
        invalid('system baseline must be positive', 4, 'machine.system_baseline') unless baseline.positive?
        if baseline < @root_private_bytes
          invalid('baseline is smaller than the checked private image memory', 4, 'machine.system_baseline')
        end
        rows = @reader.tables.keys.to_h { |name| [name, []] }
        normalize_profiles(rows)
        principals = normalize_principals(rows, users_cpus, users_rate)
        invalid('principal budgets and system baseline exceed root memory', 4, 'principals.memory') if principals.sum { |row| row.fetch('memory') } + baseline > root_memory
        max_domains = number(machine, 'max_domains')
        invalid('principal domain quotas exceed max_domains', 4, 'principals.domains') if principals.sum { |row| row.fetch('domains') } > max_domains
        normalize_units(rows)
        console = text(machine, 'console')
        hostlink = text(machine, 'hostlink')
        check_uarts(rows, console, hostlink)
        unless enum(machine, 'sealing', 'seal') == @codec.member('seal', 'none')
          invalid('empty native boot has no sealing service', 7, 'machine.sealing')
        end
        shell = records('shell_principal').map do |record|
          { 'principal' => reference_token(record.properties.fetch('targets').first, 'principal', record.line) }
        end
        invalid('duplicate shell principal', 5, 'shell_principals') unless shell.map { |row| row.fetch('principal') }.uniq.size == shell.size
        rows['shell_principals'] = shell.sort_by { |row| row.fetch('principal') }
        header = {
          'magic' => @codec.constant('manifest_magic'), 'version' => @codec.constant('manifest_version'),
          'flags' => flags, 'host' => text(machine, 'host'), 'console' => console,
          'hostlink' => hostlink, 'platform' => platform_name, 'root_memory' => root_memory,
          'system_baseline' => baseline, 'system_reservation' => 0,
          'system_share' => system_share, 'users_share' => users_share,
          'system_principal' => reference(machine, 'system_principal', 'principal'),
          'max_domains' => max_domains, 'max_connections' => number(machine, 'max_connections'),
          'system_lane' => number(machine, 'system_lane'), 'system_queue' => number(machine, 'system_queue'),
          'peer_held' => number(machine, 'peer_held'), 'system_reserve' => number(machine, 'system_reserve'),
          'sealing' => @codec.member('seal', 'none'),
          'system_runtime_limits' => reference(machine, 'system_runtime_limits', 'runtime_limits'),
          'native_limits' => reference(machine, 'native_limits', 'limits')
        }
        check_lane(header.fetch('system_lane'), 'machine.system_lane')
        %w[system_queue peer_held].each do |key|
          invalid('limit must be positive', 4, "machine.#{key}") unless header.fetch(key).positive?
        end
        report = { 'mode' => 'empty_native', 'structure' => 'validated',
                   'executable' => 'supplied_catalog', 'provenance' => 'supplied_context',
                   'root_startup' => 'unsupported', 'policy_admission' => 'unsupported',
                   'child_plan_instances' => 0, 'dynamic_domain_reservation' => 0,
                   'root_image_private_bytes' => @root_private_bytes,
                   'effective_system_cpuset' => system_cpus,
                   'effective_users_cpuset' => users_cpus,
                   'context_sha256' => @context.fingerprint }
        [{ 'header' => header, 'tables' => rows }, report]
      end

      private

      def invalid(message, property, field)
        raise Invalid.new(message, property: property, field: field)
      end

      def unsupported(message, field)
        raise Unsupported.new(message, property: 'unsupported', field: field)
      end

      def records(kind)
        @source.records.fetch(kind, [])
      end

      def one(record, key)
        tokens = record.properties[key]
        record.line.fail!("#{key} requires one value") unless tokens && tokens.size == 1
        tokens.first
      end

      def text(record, key)
        token = one(record, key)
        return token.value.b if token.quoted
        if token.value.start_with?('hex:') && token.value.delete_prefix('hex:').match?(/\A(?:[0-9a-fA-F]{2})*\z/)
          return [token.value.delete_prefix('hex:')].pack('H*')
        end
        record.line.fail!("#{key} requires quoted or hexadecimal bytes")
      end

      def number(record, key)
        token = one(record, key)
        record.line.fail!("#{key} requires an integer") if token.quoted
        value = ABI::Syntax.integer(token.value, line: record.line)
        invalid('value is outside unsigned 64-bit range', 'source', key) unless value.between?(0, (1 << 64) - 1)
        value
      end

      def flags(record, key, type)
        token = one(record, key)
        record.line.fail!('flag list cannot be quoted') if token.quoted
        return 0 if token.value == 'none'
        names = token.value.split(',', -1)
        invalid('duplicate flag', 'source', key) unless names.uniq.size == names.size
        names.reduce(0) { |mask, name| mask | @codec.member(type, name) }
      end

      def enum(record, key, type)
        token = one(record, key)
        record.line.fail!('enumeration value cannot be quoted') if token.quoted
        @codec.member(type, token.value)
      end

      def reference(record, key, kind)
        reference_token(one(record, key), kind, record.line)
      end

      def reference_token(token, kind, line)
        prefix = "@#{kind}."
        line.fail!('reference has the wrong kind') if token.quoted || !token.value.start_with?(prefix)
        name = token.value.delete_prefix(prefix)
        @indices.fetch(kind).fetch(name) { line.fail!('undefined source reference') }
      end

      def share(record, key)
        token = one(record, key)
        record.line.fail!('share requires a share reference') if token.quoted || !token.value.start_with?('@share.')
        @shares.fetch(token.value.delete_prefix('@share.')) { record.line.fail!('undefined share') }
      end

      def share_record(record)
        values = @codec.schema.types.fetch('erx_share').fields.to_h do |field|
          value = if field.name == 'flags'
                    flags(record, field.name, 'group_flags')
                  elsif field.name == 'quota_ns' && one(record, field.name).value == 'uncapped'
                    @codec.constant('quota_none')
                  else
                    number(record, field.name)
                  end
          [field.name, value]
        end
        checks = { 'period_ns' => %w[period_min period_max], 'slice_us' => %w[slice_min_us slice_max_us],
                   'grace_us' => %w[grace_min_us grace_max_us] }
        checks.each do |field, bounds|
          unless values.fetch(field).between?(*bounds.map { |name| @codec.constant(name) })
            invalid('grant value requires kernel clamping', 4, "share.#{field}")
          end
        end
        unless values.fetch('base') <= values.fetch('ceiling') && values.fetch('ceiling') <= @codec.constant('urgency_max')
          invalid('invalid urgency bounds', 4, 'share.urgency')
        end
        @codec.encode_layout('erx_share', values)
        values.freeze
      end

      def population(mask)
        mask.to_s(2).count('1')
      end

      def effective_share(share, parent)
        cpuset = share.fetch('cpuset') & parent
        cpuset = parent if cpuset.zero?
        rate = if share.fetch('quota_ns') == @codec.constant('quota_none')
                 Rational(population(cpuset), 1)
               else
                 Rational(share.fetch('quota_ns'), share.fetch('period_ns'))
               end
        [cpuset, rate]
      end

      def normalize_profiles(rows)
        rows['runtime_limits'] = records('runtime_limits').sort_by(&:name).map do |record|
          { 'name' => record.name }.merge(Frontend::FIELDS.fetch('runtime_limits').to_h { |key| [key, number(record, key)] })
        end
        rows['limits'] = records('limits').sort_by(&:name).map do |record|
          values = { 'name' => record.name }
          %w[memory outer lane connections crash peer_held peer_held_total].each { |key| values[key] = number(record, key) }
          values['grant'] = share(record, 'grant')
          values['flags'] = flags(record, 'flags', 'mf_limits_flags')
          values['runtime_limits'] = reference(record, 'runtime_limits', 'runtime_limits')
          spaces = one(record, 'spaces')
          enabled = (values.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          if spaces.value == 'none' && !spaces.quoted
            invalid('enabled sub-spaces need a grant', 4, 'limits.spaces') if enabled
            values['spaces'] = @codec.schema.types.fetch('erx_share').fields.to_h { |field| [field.name, 0] }
          else
            invalid('disabled sub-spaces must have no grant', 4, 'limits.spaces') unless enabled
            values['spaces'] = share(record, 'spaces')
          end
          check_lane(values.fetch('lane'), 'limits.lane')
          values
        end
        rows['lane_classes'] = records('lane_class').sort_by(&:name).map do |record|
          lane = number(record, 'lane')
          check_lane(lane, 'lane_classes.lane')
          { 'name' => record.name, 'lane' => lane }
        end
      end

      def normalize_principals(rows, parent_cpus, parent_rate)
        result = records('principal').sort_by(&:name).map do |record|
          grant = share(record, 'grant')
          cpus, rate = effective_share(grant, parent_cpus)
          invalid('principal grant exceeds users', 4, 'principal.grant') if rate > parent_rate
          values = { 'name' => record.name, 'memory' => number(record, 'memory'), 'grant' => grant,
                     'domains' => number(record, 'domains'), 'names' => number(record, 'names'),
                     'default_limits' => reference(record, 'default_limits', 'limits'),
                     'ceiling_limits' => reference(record, 'ceiling_limits', 'limits') }
          pooled = "#{record.name}.#{values.fetch('names')}"
          invalid('name pool exceeds identifier bound', 5, 'principal.names') unless pooled.bytesize <= 63
          defaults = rows.fetch('limits').fetch(values.fetch('default_limits'))
          ceilings = rows.fetch('limits').fetch(values.fetch('ceiling_limits'))
          check_limits(defaults, ceilings, cpus, rate, rows.fetch('runtime_limits'))
          values
        end
        total = result.sum { |row| effective_share(row.fetch('grant'), parent_cpus).last }
        invalid('principal grants exceed users', 4, 'principals.grant') if total > parent_rate
        rows['principals'] = result
      end

      def check_limits(defaults, ceilings, cpus, parent_rate, runtime_limits)
        %w[memory outer lane connections crash peer_held peer_held_total].each do |field|
          invalid('default exceeds principal ceiling', 4, "limits.#{field}") if defaults.fetch(field) > ceilings.fetch(field)
        end
        invalid('default flags exceed principal ceiling', 4, 'limits.flags') unless (defaults.fetch('flags') & ~ceilings.fetch('flags')).zero?
        default_cpus, default_rate = effective_share(defaults.fetch('grant'), cpus)
        ceiling_cpus, ceiling_rate = effective_share(ceilings.fetch('grant'), cpus)
        if default_rate > ceiling_rate || ceiling_rate > parent_rate || (default_cpus & ~ceiling_cpus) != 0 ||
           defaults.fetch('grant').fetch('ceiling') > ceilings.fetch('grant').fetch('ceiling')
          invalid('default CPU grant exceeds principal ceiling', 4, 'limits.grant')
        end
        if (defaults.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          _, child_rate = effective_share(defaults.fetch('spaces'), default_cpus)
          invalid('sub-space grant exceeds domain', 4, 'limits.spaces') if child_rate > default_rate
        end
        left = runtime_limits.fetch(defaults.fetch('runtime_limits'))
        right = runtime_limits.fetch(ceilings.fetch('runtime_limits'))
        Frontend::FIELDS.fetch('runtime_limits').each do |field|
          invalid('runtime default exceeds ceiling', 4, "runtime_limits.#{field}") if left.fetch(field) > right.fetch(field)
        end
      end

      def normalize_units(rows)
        units = @context.platform['units']
        invalid('checked platform needs a unit roster', 'context', 'platform.units') unless units.is_a?(Array)
        by_key = {}
        units.each do |unit|
          unless unit.is_a?(Hash) && unit['key'].is_a?(String) && unit['devices'].is_a?(Array) && !by_key.key?(unit['key'])
            invalid('invalid checked platform unit', 'context', 'platform.units')
          end
          by_key[unit.fetch('key')] = unit
        end
        placed = []
        records('unit').sort_by(&:name).each do |record|
          key = text(record, 'placement')
          unit = by_key[key] || invalid('unit is absent from checked placement', 1, 'unit.placement')
          invalid('unit is assigned more than once', 1, 'unit.placement') if placed.include?(key)
          placed << key
          holder = one(record, 'holder')
          invalid('empty native units belong to the system domain', 1, 'unit.holder') unless !holder.quoted && holder.value == 'system'
          first = rows.fetch('devices').size
          invalid('platform unit has no devices', 'context', 'platform.units') if unit.fetch('devices').empty?
          unit.fetch('devices').sort_by { |device| device.fetch('placement_key').b }.each do |device|
            unless device.is_a?(Hash)
              invalid('invalid checked device row', 'context', 'platform.devices')
            end
            normalized = device.dup
            %w[selector role dma].each do |field|
              type = { 'selector' => 'mf_selector', 'role' => 'mf_device_role', 'dma' => 'mf_dma' }.fetch(field)
              normalized[field] = @codec.member(type, normalized.fetch(field)) if normalized[field].is_a?(String)
            end
            normalized['flags'] = normalized.fetch('flags', 0)
            normalized['dma_memory'] = normalized.fetch('dma_memory', 0)
            unsupported('device allocation needs a checked sizing provider', 'devices.dma') unless normalized.fetch('dma') == @codec.member('mf_dma', 'none')
            invalid('non-DMA device has a DMA reservation', 4, 'devices.dma_memory') unless normalized.fetch('dma_memory').zero?
            rows.fetch('devices') << normalized
          end
          rows.fetch('units') << { 'name' => record.name, 'holder' => @codec.constant('mf_none'),
                                   'devices' => { 'table' => 'devices', 'first' => first, 'count' => rows.fetch('devices').size - first } }
        end
      end

      def check_uarts(rows, console, hostlink)
        invalid('console and host link must differ', 8, 'machine.hostlink') if !hostlink.empty? && hostlink == console
        paths = rows.fetch('devices').select do |device|
          device.fetch('selector') == @codec.member('mf_selector', 'dt') && device.fetch('role') == @codec.member('mf_device_role', 'uart')
        end.map { |device| device.fetch('path') }
        [console, hostlink].reject(&:empty?).each do |path|
          invalid('UART is not assigned to the system domain', 8, 'machine.console') unless paths.include?(path)
        end
        unless @context.platform['console'] == console && (@context.platform.fetch('hostlink', '') == hostlink)
          invalid('UART paths disagree with checked platform', 8, 'machine.console')
        end
      end

      def check_lane(value, field)
        unless value.between?(@codec.constant('lane_min'), @codec.constant('lane_max')) && (value & (value - 1)).zero?
          invalid('lane must be a bounded power of two', 4, field)
        end
      end

      def check_catalog
        path = @codec.fixed_bytes('system_manifest_path')
        entries = @context.catalog.select { |row| row.fetch('path') == path }
        unless entries.size == 1 && entries.first.fetch('kind') == @codec.member('entry_kind', 'file') &&
               entries.first.fetch('flags') == @codec.member('entry_flags', 'system') &&
               entries.first.fetch('source') == { 'kind' => 'generated', 'producer' => 'manifest' }
          invalid('reserved manifest path must have its generated system-file row', 1, 'catalog.manifest')
        end
        root = @context.catalog.fetch(@context.root_entry)
        unless root.fetch('kind') == @codec.member('entry_kind', 'image') &&
               (root.fetch('flags') & @codec.member('entry_flags', 'system')) != 0 && root['image'].is_a?(Hash)
          invalid('root is not a system executable', 6, 'catalog.root')
        end
        image = root.fetch('image')
        unless image['magic'] == @codec.constant('image_magic') && image['version'] == @codec.constant('image_version') &&
               image['abi_version'] == @codec.abi_version &&
               image['flags'].is_a?(Integer) && (image.fetch('flags') & @codec.member('image_flags', 'jit')).zero?
          invalid('root image has incompatible ABI or JIT authority', 6, 'catalog.root')
        end
        @codec.encode_layout('erx_image_manifest', image)
        page = @codec.constant('page_size')
        @root_private_bytes = image.fetch('segments').sum do |segment|
          if segment.fetch('prot') == @codec.member('prot', 'rw')
            bytes = segment.fetch('mem_size')
            invalid('root writable segment exceeds its bound', 6, 'catalog.root') if bytes > @codec.constant('image_writable_max')
            ((bytes + page - 1) / page) * page
          else
            0
          end
        end
      end
    end

    # Physical positions are derived once from the final table plan. String
    # references are assigned in field traversal order, with no interning or
    # data-dependent map ordering. No bytes escape before the reader pass.
    class Encoder
      def initialize(codec)
        @codec = codec
        @reader = codec.schema.readers.find { |item| item.name == 'manifest' }
      end

      def encode(configuration)
        rows = configuration.fetch('tables')
        cursor = @reader.root.size
        positions = {}
        @reader.order.each do |name|
          next unless @reader.tables.key?(name)
          table = @reader.tables.fetch(name)
          count = rows.fetch(name).size
          raise Invalid.new('table exceeds bound', property: 'encoding', field: name) if count > table.fetch(:maximum)
          cursor += (table.fetch(:alignment) - cursor % table.fetch(:alignment)) % table.fetch(:alignment)
          positions[name] = { 'offset' => cursor, 'count' => count }
          cursor += count * table.fetch(:type).size
        end
        raise Invalid.new('tables exceed manifest byte bound', property: 'encoding', field: 'length') if cursor > @reader.maximum
        strings = +''.b
        string_budget = [@codec.constant('manifest_strings_max'), @reader.maximum - cursor].min
        header = configuration.fetch('header').merge('length' => 0, 'header_size' => @reader.root.size,
                                                    'strings' => { 'offset' => cursor, 'count' => 0 }).merge(positions)
        header = materialize(@reader.root, header, positions, strings, string_budget)
        encoded = {}
        @reader.tables.each do |name, table|
          encoded[name] = rows.fetch(name).map do |row|
            values = materialize(table.fetch(:type), row, positions, strings, string_budget)
            @codec.encode_layout(table.fetch(:type).name, values)
          end
        end
        header['strings'] = { 'offset' => cursor, 'count' => strings.bytesize }
        header['length'] = cursor + strings.bytesize
        result = "\0".b * cursor
        result[0, @reader.root.size] = @codec.encode_layout(@reader.root.name, header)
        encoded.each do |name, records|
          offset = positions.fetch(name).fetch('offset')
          records.each do |record|
            result[offset, record.bytesize] = record
            offset += record.bytesize
          end
        end
        (result << strings).freeze
      end

      private

      def materialize(type, values, positions, strings, budget)
        unless (values.keys - type.fields.map(&:name)).empty?
          raise Invalid.new('unknown normalized field', property: 'encoding', field: type.name)
        end
        type.fields.each_with_object({}) do |field, result|
          key = field.name
          next unless values.key?(key)
          value = values.fetch(key)
          if field.type.name == 'erx_mf_str'
            unless value.is_a?(String) && value.bytesize <= budget - strings.bytesize
              raise Invalid.new('string table exceeds bound', property: 'encoding', field: key)
            end
            result[key] = { 'offset' => value.empty? ? 0 : strings.bytesize, 'length' => value.bytesize }
            strings << value.b
          elsif field.type.name == 'erx_mf_span' && value.key?('table')
            table = @reader.tables.fetch(value.fetch('table'))
            extent = positions.fetch(value.fetch('table'))
            first = value.fetch('first')
            count = value.fetch('count')
            unless first.between?(0, extent.fetch('count')) && count.between?(0, extent.fetch('count') - first)
              raise Invalid.new('normalized slice is outside its table', property: 'encoding', field: key)
            end
            result[key] = { 'offset' => extent.fetch('offset') + first * table.fetch(:type).size, 'count' => count }
          else
            result[key] = value
          end
        end
      end
    end
  end
end
