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
        'machine' => %w[flags host console hostlink platform root_memory system_baseline system_share users_share system_principal max_domains max_connections system_lane system_queue peer_held system_reserve sealing system_runtime_limits native_limits system_args],
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
      OPTIONAL = { 'machine' => %w[system_args], 'domain' => %w[args env], 'service' => %w[name],
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

    # The root startup rule: a declared sanity check, not a proof. It compares
    # the manifest's numbers with the platform record's, so a wrong
    # fiasco_reserve shows at boot, when the root's pool falls short. A report
    # therefore says root_startup: declared, never validated.
    module RootStartup
      module_function

      # The platform's declared memory. Without it no rule can be stated, so
      # nothing is admitted.
      def declared(platform)
        ram, reserve = platform.values_at('ram_bytes', 'fiasco_reserve')
        unless ram.is_a?(Integer) && reserve.is_a?(Integer) && reserve.positive? && reserve < ram
          raise Unsupported.new('the platform record states no RAM size and fiasco_reserve to check root startup against',
                                property: 4, field: 'root_startup')
        end
        { 'ram_bytes' => ram, 'fiasco_reserve' => reserve }.freeze
      end

      def check(loadable:, baseline:, root_memory:, platform:)
        memory = declared(platform)
        if loadable + baseline > root_memory
          raise Invalid.new("the root's loadable segments and system_baseline exceed root_memory",
                            property: 4, field: 'root_startup')
        end
        if root_memory > memory.fetch('ram_bytes') - memory.fetch('fiasco_reserve')
          raise Invalid.new('root_memory exceeds RAM less fiasco_reserve', property: 4, field: 'root_startup')
        end
      end
    end

    # Phase 1's admission: SystemOnly over a manifest with the system domain
    # alone, and the declared root startup rule. This factory alone mints the
    # private publication token, so a structural fixture cannot pass for it.
    class Admitted
      attr_reader :bytes, :report

      def self.admit(source:, codec:, context:, planner: nil, consumers: {})
        raise Invalid.new('checked context required', property: 'context', field: 'input') unless context.is_a?(Context)
        RootStartup.declared(context.platform)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = SystemOnly.new(parsed, codec: codec, context: context,
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

    def self.admit(source:, codec:, context:, planner: nil, consumers: {})
      Admitted.admit(source: source, codec: codec, context: context,
                    planner: planner, consumers: consumers)
    end

    def self.structural_fixture(source:, codec:, context:)
      StructuralFixture.prepare(source: source, codec: codec, context: context)
    end

    # The readers and the normalization of a manifest with no child domains:
    # every holder is the system domain and nothing is reserved for a child. A subclass
    # states which modes and records it takes (check_mode), what it allows of a
    # platform device (check_device), what else it places (check_and_place)
    # and what its report claims (claims).
    class SystemDomainCheck
      TABLES = { 'principal' => 'principals', 'limits' => 'limits',
                 'runtime_limits' => 'runtime_limits', 'lane_class' => 'lane_classes',
                 'image' => 'images' }.freeze

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
        check_mode(development: development, partial: partial)
        root_private_bytes = check_catalog
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
        if baseline < root_private_bytes
          invalid('baseline is smaller than the checked private image memory', 4, 'machine.system_baseline')
        end
        rows = @reader.tables.keys.to_h { |name| [name, []] }
        normalize_profiles(rows)
        principals = normalize_principals(rows, users_cpus, users_rate)
        max_domains = number(machine, 'max_domains')
        invalid('principal domain quotas exceed max_domains', 4, 'principals.domains') if principals.sum { |row| row.fetch('domains') } > max_domains
        normalize_units(rows)
        device_memory = rows.fetch('devices').sum { |device| device.fetch('dma_memory') }
        if principals.sum { |row| row.fetch('memory') } + baseline + device_memory > root_memory
          invalid('principal budgets, system baseline and device memory exceed root memory', 4, 'principals.memory')
        end
        console = text(machine, 'console')
        hostlink = text(machine, 'hostlink')
        check_uarts(rows, console, hostlink)
        unless enum(machine, 'sealing', 'seal') == @codec.member('seal', 'none')
          invalid('no sealing service exists to hold a sealing secret', 7, 'machine.sealing')
        end
        shell = records('shell_principal').map do |record|
          { 'principal' => reference_token(record.properties.fetch('targets').first, 'principal', record.line) }
        end
        invalid('duplicate shell principal', 5, 'shell_principals') unless shell.map { |row| row.fetch('principal') }.uniq.size == shell.size
        rows['shell_principals'] = shell.sort_by { |row| row.fetch('principal') }
        check_and_place(rows, root_memory: root_memory, baseline: baseline, max_domains: max_domains)
        header = {
          'magic' => @codec.constant('manifest_magic'), 'version' => @codec.constant('manifest_version'),
          'flags' => flags, 'host' => text(machine, 'host'), 'system_args' => words(machine, 'system_args'),
          'console' => console,
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
        report = { 'structure' => 'validated',
                   'executable' => 'supplied_catalog', 'provenance' => 'supplied_context',
                   'policy_admission' => 'unsupported',
                   'child_plan_instances' => 0, 'dynamic_domain_reservation' => 0,
                   'root_image_private_bytes' => root_private_bytes,
                   'effective_system_cpuset' => system_cpus,
                   'effective_users_cpuset' => users_cpus,
                   'context_sha256' => @context.fingerprint }.merge(claims)
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

      # A word list as the page holds it, each word ended by a NUL. A source writes it
      # quoted, with its words separated by spaces, since the arguments it holds have no
      # empty word and no space.
      def words(record, key)
        return ''.b unless record.properties.key?(key)

        token = one(record, key)
        return text(record, key) unless token.quoted

        token.value.b.split(' ').map { |word| "#{word}\0" }.join
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
          invalid('units belong to the system domain', 1, 'unit.holder') unless !holder.quoted && holder.value == 'system'
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
            normalized.merge!(device_window(normalized))
            check_device(normalized)
            rows.fetch('devices') << normalized
          end
          rows.fetch('units') << { 'name' => record.name, 'holder' => @codec.constant('mf_none'),
                                   'devices' => { 'table' => 'devices', 'first' => first, 'count' => rows.fetch('devices').size - first } }
        end
      end

      # A device-tree device's register window and interrupt line, which the platform record
      # must carry (docs/design-abi.md, "Devices and partition windows"); a PCIe function's
      # come from configuration space and are zero here.
      def device_window(device)
        fields = %w[base size line]
        unless device.fetch('selector') == @codec.member('mf_selector', 'dt')
          invalid('a PCIe function carries a window or line', 'context', 'platform.devices') if fields.any? { |field| device.fetch(field, 0) != 0 }
          return fields.to_h { |field| [field, 0] }
        end

        missing = fields.reject { |field| device[field].is_a?(Integer) }
        invalid("device-tree device lacks #{missing.join(', ')}", 'context', 'platform.devices') unless missing.empty?
        invalid('device-tree device has an empty window', 'context', 'platform.devices') if device.fetch('size').zero?
        device.slice(*fields)
      end

      def check_uarts(rows, console, hostlink)
        invalid('console and host link must differ', 8, 'machine.hostlink') if !hostlink.empty? && hostlink == console
        paths = rows.fetch('devices').select do |device|
          device.fetch('selector') == @codec.member('mf_selector', 'dt') && device.fetch('role') == @codec.member('mf_device_role', 'uart')
        end.map { |device| device.fetch('path') }
        [console, hostlink].reject(&:empty?).each do |path|
          invalid('UART is not assigned to the system domain', 8, path == console ? 'machine.console' : 'machine.hostlink') unless paths.include?(path)
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
        image.fetch('segments').sum do |segment|
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

    # M0's structural fixtures: a partial boot with no services or children.
    class EmptyNative < SystemDomainCheck
      private

      def check_mode(development:, partial:)
        unless partial
          unsupported('full boot needs the production sizing, planner and service consumers', 'mode')
        end
        %w[domain partial_boot].each do |kind|
          unsupported('child domain planning is unavailable', kind) unless records(kind).empty?
        end
        %w[window service facet introduce image liveness].each do |kind|
          invalid('empty native boot has no service or child assignments', 9, kind) unless records(kind).empty?
        end
      end

      def check_device(device)
        unsupported('device allocation needs a checked sizing provider', 'devices.dma') unless device.fetch('dma') == @codec.member('mf_dma', 'none')
        invalid('non-DMA device has a DMA reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').zero?
      end

      def check_and_place(_rows, root_memory:, baseline:, max_domains:) = nil

      def claims = { 'mode' => 'empty_native', 'root_startup' => 'unsupported' }
    end

    # Phase 1's check (docs/design-stopgap.md, "The Phase 1 manifest check"): a
    # development manifest, full or partial boot, with the system domain alone.
    # Every holder and server is the system domain, so properties 10 to 13 have
    # nothing to check and what would bring them is refused here.
    class SystemOnly < SystemDomainCheck
      REFUSED = {
        'domain' => 'configured domains arrive at M5',
        'partial_boot' => 'child domains of a partial boot arrive at M5',
        'introduce' => 'introductions connect configured domains, which arrive at M5',
        'liveness' => 'the system domain\'s watchdog pets without reading liveness records, which a later milestone brings'
      }.freeze

      private

      def check_mode(development:, partial:)
        unless development
          raise Unsupported.new('a release build needs the confinement check that M11 brings', property: 9, field: 'machine.flags')
        end
        REFUSED.each { |kind, reason| unsupported(reason, kind) unless records(kind).empty? }
        return unless partial
        %w[service facet liveness].each do |kind|
          invalid('a partial boot runs no services', 2, kind) unless records(kind).empty?
        end
      end

      def check_device(device)
        invalid('no domain holds a PCIe function until M9', 3, 'devices.selector') if device.fetch('selector') == @codec.member('mf_selector', 'pci')
        role = device.fetch('role')
        invalid('no domain holds PCIe configuration space until M9', 3, 'devices.role') if role == device_role('configuration')
        invalid('no domain holds a network device until M9', 8, 'devices.role') if role == device_role('network')
        invalid('no domain holds a TPM until M11', 7, 'devices.role') if role == device_role('tpm')
        case device.fetch('dma')
        when @codec.member('mf_dma', 'confined')
          unsupported('a confined device needs a DMA window, which M9 brings', 'devices.dma')
        when @codec.member('mf_dma', 'unconfined')
          invalid('an unconfined device needs a memory reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').positive?
        else
          invalid('non-DMA device has a DMA reservation', 4, 'devices.dma_memory') unless device.fetch('dma_memory').zero?
        end
      end

      def check_and_place(rows, root_memory:, baseline:, max_domains:)
        check_system_domain_alone(rows.fetch('devices'), max_domains)
        services = records('service').sort_by { |record| service_name(record).b }
        rows['services'] = normalize_services(services)
        check_facets(services)
        rows['liveness'] = normalize_liveness(services)
        rows['images'], rows['extents'] = normalize_images(rows.fetch('devices'))
        rows['windows'] = normalize_windows(rows.fetch('devices'), rows.fetch('images'))
        RootStartup.check(loadable: root_loadable_bytes, baseline: baseline,
                          root_memory: root_memory, platform: @context.platform)
      end

      def claims
        { 'mode' => 'system_only', 'root_startup' => 'declared',
          'root_image_loadable_bytes' => root_loadable_bytes }.merge(RootStartup.declared(@context.platform))
      end

      def check_system_domain_alone(devices, max_domains)
        invalid('no domains are configured until M5, so max_domains is 0', 4, 'machine.max_domains') unless max_domains.zero?
        invalid('host name is not a system identifier', 5, 'machine.host') unless text(@source.machine, 'host').match?(Frontend::IDENTIFIER)
        check_one_holder(devices)
        check_no_sealed_entry
      end

      def root_loadable_bytes
        page = @codec.constant('page_size')
        @context.catalog.fetch(@context.root_entry).fetch('image').fetch('segments').sum do |segment|
          ((segment.fetch('mem_size') + page - 1) / page) * page
        end
      end

      def service_name(record) = record.properties.key?('name') ? text(record, 'name') : record.name.b

      def device_role(name) = @codec.member('mf_device_role', name)

      def check_one_holder(devices)
        paths = devices.filter_map { |device| device['path'] }
        invalid('a device appears in more than one unit', 1, 'devices.path') unless paths.uniq.size == paths.size
      end

      def check_no_sealed_entry
        seal = @codec.member('entry_flags', 'seal')
        return if @context.catalog.none? { |row| (row.fetch('flags') & seal) != 0 }
        invalid('no entry carries the sealing secret until the vault at M11', 7, 'catalog.flags')
      end

      def normalize_services(services)
        rows = services.map do |record|
          server = one(record, 'server')
          invalid('every service runs in the system domain until M5', 2, 'service.server') unless !server.quoted && server.value == 'system'
          name = service_name(record)
          invalid('service name is not a system identifier', 5, 'service.name') unless name.match?(Frontend::IDENTIFIER)
          { 'name' => name, 'server' => @codec.constant('mf_none'), 'interface' => number(record, 'interface') }
        end
        invalid('two services share a name', 5, 'service.name') unless rows.map { |row| row.fetch('name') }.uniq.size == rows.size
        rows
      end

      # The reader's facet grantee is a domain and the system domain has no
      # row, so a facet that names its service has still no holder before M5.
      def check_facets(services)
        records('facet').each do |record|
          token = one(record, 'service')
          known = !token.quoted && services.any? { |service| "@service.#{service.name}" == token.value }
          invalid('facet names a service the manifest does not contain', 2, 'facet.service') unless known
          unsupported('a facet is granted to a configured domain, and those arrive at M5', 'facet')
        end
      end

      def normalize_liveness(services)
        rows = records('liveness').map do |record|
          token = record.properties.fetch('targets').first
          index = services.index { |service| !token.quoted && "@service.#{service.name}" == token.value }
          invalid('liveness names a service the manifest does not contain', 2, 'liveness') unless index
          { 'service' => index }
        end
        invalid('a service is watched twice', 2, 'liveness') unless rows.uniq.size == rows.size
        rows.sort_by { |row| row.fetch('service') }
      end

      def normalize_windows(devices, images)
        rows = records('window').map do |record|
          holder = one(record, 'holder')
          invalid('the system domain holds every window until the storage domain at M9', 8, 'window.holder') unless !holder.quoted && holder.value == 'system'
          role = window_role(record)
          { 'holder' => @codec.constant('mf_none'), 'device' => window_device(record, devices),
            'role' => role, 'partition' => window_partition(record, role),
            'rights' => window_rights(record, role), 'image' => window_image(record, role) }
                 .tap { |row| check_image_device(row, images) }
        end
        placed = rows.map { |row| row.values_at('device', 'role', 'partition', 'image') }
        invalid('two windows name one role and partition', 8, 'window.partition') unless placed.uniq.size == placed.size
        rows.sort_by { |row| row.values_at('holder', 'device', 'role', 'partition', 'image') }
      end

      # design-abi.md: fixed-medium roles have partition 0, because the medium
      # layout determines their sectors; FAT names a primary partition.
      def window_partition(record, role)
        partition = number(record, 'partition')
        allowed = role == @codec.member('mf_window_role', 'fat') ? (1..4) : (0..0)
        invalid('a fixed role has partition 0 and FAT a primary partition, 1 to 4', 8, 'window.partition') unless allowed.cover?(partition)
        partition
      end

      def window_rights(record, role)
        rights = flags(record, 'rights', 'mf_window_rights')
        read = @codec.member('mf_window_rights', 'read')
        invalid('a window grants at least read', 8, 'window.rights') if (rights & read).zero?
        invalid('a verified-image window is read-only', 8, 'window.rights') if role == image_role && rights != read
        rights
      end

      def window_device(record, devices)
        path = text(record, 'device')
        index = devices.index { |device| device['path'] == path && device.fetch('role') == device_role('block') }
        index || invalid('window names no block device the system domain holds', 8, 'window.device')
      end

      def window_role(record)
        role = enum(record, 'role', 'mf_window_role')
        invalid('no vault partition until M11', 8, 'window.role') if role == @codec.member('mf_window_role', 'vault')
        role
      end

      # design-abi.md: a verified-image window names an image-table index, and every
      # other role names none.
      def window_image(record, role)
        token = one(record, 'image')
        absent = !token.quoted && token.value == 'none'
        if role == image_role
          invalid('a verified-image window names its image', 8, 'window.image') if absent
          reference_token(token, 'image', record.line)
        else
          invalid('only a verified-image window names an image', 8, 'window.image') unless absent
          @codec.constant('mf_none')
        end
      end

      # A verified-image window lies on the device its image lies on, since the image's
      # extents are places on that device.
      def check_image_device(row, images)
        return if row.fetch('role') != image_role || images.fetch(row.fetch('image')).fetch('device') == row.fetch('device')

        invalid("a verified-image window names its image's device", 8, 'window.device')
      end

      # An image's tree fields when the packer writes no tree.
      NO_TREE = { 'hash_block_size' => 0, 'hash_offset' => 0, 'hash_bytes' => 0, 'salt_length' => 0,
                  'hash_algorithm' => 0, 'salt' => Array.new(32, 0), 'root_hash' => Array.new(32, 0) }.freeze

      def image_role = @codec.member('mf_window_role', 'verified_image')

      # The image table and its extents (docs/design-stopgap.md, "The Phase 1 manifest
      # check"): each image is format erofs_unchecked, since the packer writes no hash
      # tree, so its record holds its data's length and extents, taken from the built
      # image its input artifact describes, and zeros for every tree field.
      def normalize_images(devices)
        block_size = @codec.constant('page_size')
        records('image').sort_by { |record| record.name.b }.each_with_object([[], []]) do |record, (images, extents)|
          invalid('image name is not a system identifier', 5, 'image.name') unless record.name.match?(Frontend::IDENTIFIER)
          invalid('an image without a hash tree takes no salt', 8, 'image.salt') if record.properties.key?('salt')
          placed = checked_extents(image_artifact(record))
          bytes = placed.sum { |extent| extent.fetch('length') }
          invalid('an image is whole blocks', 8, 'image.input') unless (bytes % block_size).zero?
          device = devices.index { |row| row['path'] == text(record, 'device') && row.fetch('role') == device_role('block') }
          invalid('image names no block device the system domain holds', 8, 'image.device') unless device
          images << { 'name' => record.name.b, 'device' => device,
                      'format' => @codec.member('mf_image_format', 'erofs_unchecked'),
                      'extents' => { 'table' => 'extents', 'first' => extents.size, 'count' => placed.size },
                      'data_bytes' => bytes, 'data_block_size' => block_size, 'data_blocks' => bytes / block_size }
                    .merge(NO_TREE)
          extents.concat(placed)
        end
      end

      # The artifact an image's input names, which the packer derived from the built image.
      def image_artifact(record)
        token = one(record, 'input')
        named = !token.quoted && token.value.start_with?('@artifact.')
        artifact = named ? @context.artifacts[token.value.delete_prefix('@artifact.')] : nil
        invalid('image input names no image artifact of this pack', 8, 'image.input') unless artifact.is_a?(Hash) && artifact['kind'] == 'erofs_image'
        artifact
      end

      # design-abi.md: nonempty, sorted and disjoint whole sectors, relative to the slot's
      # start and inside it.
      def checked_extents(artifact)
        sector = @codec.constant('mbr_sector_size')
        slot = @codec.constant('medium_slot_sectors') * sector
        extents = artifact['extents']
        invalid('an image has at least one extent', 8, 'image.input') unless extents.is_a?(Array) && !extents.empty?
        extents.each_with_object([]) do |extent, placed|
          offset, length = extent.values_at('slot_offset', 'length') if extent.is_a?(Hash)
          floor = placed.empty? ? 0 : placed.last.fetch('slot_offset') + placed.last.fetch('length')
          unless offset.is_a?(Integer) && length.is_a?(Integer) && length.positive? && offset >= floor &&
                 (offset % sector).zero? && (length % sector).zero? && offset + length <= slot
            invalid('image extents are sorted, disjoint whole sectors inside a slot', 8, 'image.input')
          end
          placed << { 'slot_offset' => offset, 'length' => length }
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
