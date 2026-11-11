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
        'domain' => %w[principal limits kind flags runtime release restarts restart_period_s boot_timeout_s args env],
        'session' => %w[limits runtime release args env],
        'unit' => %w[placement holder],
        'window' => %w[holder device role partition rights image],
        'service' => %w[name server interface],
        'facet' => %w[name grantee service operations max_request in_flight reductions period_ns max_heap_size queue],
        'image' => %w[device input salt],
        'partial_boot' => %w[image]
      }.freeze
      OPTIONAL = { 'machine' => %w[system_args], 'domain' => %w[boot_timeout_s args env], 'session' => %w[args env], 'service' => %w[name],
                   'facet' => %w[name queue], 'image' => %w[salt] }.freeze
      DIRECTIVES = { 'introduce' => 2, 'liveness' => 1, 'shell_principal' => 1 }.freeze
      IDENTIFIER = /\A[a-z0-9][a-z0-9_-]{0,62}\z/.freeze
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

    # Phase 1's admission: Stopgap over a manifest with the system domain and
    # its configured domains, and the declared root startup rule. This factory alone mints the
    # private publication token, so a structural fixture cannot pass for it.
    class Admitted
      attr_reader :bytes, :report

      def self.admit(source:, codec:, context:, planner: nil, consumers: {})
        raise Invalid.new('checked context required', property: 'context', field: 'input') unless context.is_a?(Context)
        RootStartup.declared(context.platform)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = Stopgap.new(parsed, codec: codec, context: context,
                              planner: planner, consumers: consumers)
        normalized, report = checker.check
        bytes = Encoder.new(codec).encode(normalized)
        codec.open('manifest', bytes)
        checker.check_plans(bytes, normalized.fetch('tables'))
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

    # The artifact names the source's domain rows and session templates give as
    # releases, sorted and once each, read before any check so a build can make what
    # they name. A reference of another form names nothing here; admission refuses it
    # (Stopgap#artifact).
    def self.release_names(source:, codec:)
      records = Frontend.parse(source, version: codec.constant('manifest_version')).records
      records.values_at('domain', 'session').compact.flatten.filter_map do |record|
        tokens = record.properties.fetch('release')
        token = tokens.first if tokens.size == 1
        token.value.delete_prefix('@artifact.') if token && !token.quoted && token.value.start_with?('@artifact.')
      end.uniq.sort
    end

    def self.structural_fixture(source:, codec:, context:)
      StructuralFixture.prepare(source: source, codec: codec, context: context)
    end

    # The readers and the normalization every check shares. A unit's holder is the
    # system domain or a configured domain, and nothing is reserved for a child. A subclass
    # states which modes and records it takes (check_mode), what it allows of a
    # platform device (check_device), what else it places (check_and_place)
    # and what its report claims (claims).
    class SystemDomainCheck
      TABLES = { 'principal' => 'principals', 'limits' => 'limits',
                 'runtime_limits' => 'runtime_limits', 'lane_class' => 'lane_classes',
                 'image' => 'images', 'domain' => 'domains' }.freeze

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
        # Every living domain, configured or requested, is one of its principal's quota.
        if principals.sum { |row| row.fetch('domains') } > max_domains
          invalid('principal domain quotas exceed max_domains', 4, 'principals.domains')
        end
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

      # A holder or server: literal system, the system domain, or @domain.NAME, a
      # configured domain's index.
      def holder_index(token, property:, field:)
        return @codec.constant('mf_none') if !token.quoted && token.value == 'system'

        domain_index(token) || invalid('names neither the system domain nor a configured domain', property, field)
      end

      # A configured domain's index, or nil when the token names none.
      def domain_index(token)
        return nil if token.quoted || !token.value.start_with?('@domain.')

        @indices.fetch('domain')[token.value.delete_prefix('@domain.')]
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
          pooled = "#{record.name}_#{values.fetch('names')}"
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
          holder = holder_index(one(record, 'holder'), property: 1, field: 'unit.holder')
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
          rows.fetch('units') << { 'name' => record.name, 'holder' => holder,
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
          field = path == console ? 'machine.console' : 'machine.hostlink'
          invalid('UART is not placed', 8, field) unless paths.include?(path)
          invalid('UART is not assigned to the system domain', 8, field) unless unit_holder(rows, path) == @codec.constant('mf_none')
        end
        unless @context.platform['console'] == console && (@context.platform.fetch('hostlink', '') == hostlink)
          invalid('UART paths disagree with checked platform', 8, 'machine.console')
        end
      end

      # The holder of the unit whose devices include the device at path.
      def unit_holder(rows, path)
        index = rows.fetch('devices').index { |device| device['path'] == path }
        rows.fetch('units').find do |unit|
          span = unit.fetch('devices')
          index.between?(span.fetch('first'), span.fetch('first') + span.fetch('count') - 1)
        end.fetch('holder')
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
        %w[domain session partial_boot].each do |kind|
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
    # development manifest, full or partial boot, with the system domain and its
    # configured domains. A holder or server is the system domain or a configured
    # domain, and a grantee one of those or a session template; a domain row's runtime and release name artifacts of this
    # pack; the configured domains are ordered (10), checked against the rescue
    # configuration (11), planned by the domain library's host build (12) and held to
    # the headroom in system (13). What Phase 1 does not bring is refused here.
    class Stopgap < SystemDomainCheck
      REFUSED = {
        'partial_boot' => 'child domains of a partial boot arrive at M5',
        'liveness' => 'the system domain\'s watchdog pets without reading liveness records, which a later milestone brings'
      }.freeze

      private

      def check_mode(development:, partial:)
        unless development
          raise Unsupported.new('a release build needs the confinement check that M11 brings', property: 9, field: 'machine.flags')
        end
        REFUSED.each { |kind, reason| unsupported(reason, kind) unless records(kind).empty? }
        return unless partial

        invalid('a partial boot configures no domains', 12, 'domain') unless records('domain').empty?
        invalid('a partial boot makes no sessions', 14, 'session') unless records('session').empty?
        %w[service facet introduce liveness].each do |kind|
          invalid('a partial boot runs no services', 2, kind) unless records(kind).empty?
        end
      end

      def check_device(device)
        invalid('no domain holds a PCIe function until M9', 3, 'devices.selector') if device.fetch('selector') == @codec.member('mf_selector', 'pci')
        role = device.fetch('role')
        invalid('no domain holds PCIe configuration space until M9', 3, 'devices.role') if role == device_role('configuration')
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
        check_identity(rows.fetch('devices'))
        rows['domains'] = normalize_domains(rows)
        rows['sessions'] = normalize_sessions(rows)
        services = records('service').map { |record| [record, normalize_service(record)] }
                                     .sort_by { |_record, row| [row.fetch('name'), row.fetch('server')] }
        rows['services'] = services.map(&:last)
        invalid('two services of one server share a name', 5, 'service.name') unless
          rows['services'].map { |row| row.values_at('server', 'name') }.uniq.size == services.size
        rows['introductions'] = normalize_introductions
        rows['facets'] = normalize_facets(services.map(&:first), rows)
        edges = boot_edges(rows['facets'], rows['services'])
        rows['boot_order'] = boot_order(rows['domains'], edges)
        check_rescue(rows['domains'], edges)
        check_facets_supported
        rows['images'], rows['extents'] = normalize_images(rows.fetch('devices'))
        rows['windows'] = normalize_windows(rows.fetch('devices'), rows.fetch('images'))
        RootStartup.check(loadable: root_loadable_bytes, baseline: baseline,
                          root_memory: root_memory, platform: @context.platform)
      end

      def claims
        { 'mode' => 'stopgap', 'root_startup' => 'declared', 'child_plan_instances' => records('domain').size,
          'root_image_loadable_bytes' => root_loadable_bytes }.merge(RootStartup.declared(@context.platform))
      end

      def check_identity(devices)
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

      # A pooled name: an identifier, an underscore and decimal digits (docs/design-system.md,
      # "Identifiers").
      POOLED = /\A(?<stem>.+)_[0-9]+\z/.freeze

      # The configured domains in name order, which their references' indices follow.
      # A domain's runtime and release are artifacts of this pack: the runtime an
      # executable entry, the release a domain release's run of entries.
      def normalize_domains(rows)
        principals = rows.fetch('principals').map { |row| row.fetch('name') }
        records('domain').sort_by(&:name).map do |record|
          pooled = record.name.match(POOLED)
          invalid('a configured domain\'s name has a pooled name\'s form', 5, 'domain.name') if pooled&.[](:stem)&.match?(Frontend::IDENTIFIER)
          invalid('a configured domain shares a principal\'s name', 5, 'domain.name') if principals.include?(record.name)
          invalid('the system domain\'s name is not a configured domain\'s', 5, 'domain.name') if record.name == 'system'
          args = boot_args(record, property: 12, field: 'domain.args')
          strings = args.bytesize + words(record, 'env').bytesize
          invalid('arguments and environment exceed the boot page\'s strings', 12, 'domain.args') if
            strings > @codec.constant('boot_strings_max')
          kind = enum(record, 'kind', 'mf_kind')
          invalid('no secret domain until the vault at M11', 7, 'domain.kind') unless kind == @codec.member('mf_kind', 'service')
          runtime = artifact(record, 'runtime', 'executable', property: 12, field: 'domain.runtime')
          release = artifact(record, 'release', 'release', property: 12, field: 'domain.release')
          { 'name' => record.name, 'principal' => reference(record, 'principal', 'principal'), 'kind' => kind,
            'flags' => flags(record, 'flags', 'mf_domain_flags'), 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'limits' => reference(record, 'limits', 'limits'), 'restarts' => number(record, 'restarts'),
            'restart_period_s' => number(record, 'restart_period_s'), 'boot_timeout_s' => boot_timeout(record),
            'args' => args, 'env' => words(record, 'env') }
        end
      end

      # The seconds a configured domain's init has to report ready: its row's own, or
      # boot_timeout_default_s where the row states none, from 1 to boot_timeout_max_s,
      # the reader's bound (abi/manifest.txt).
      def boot_timeout(record)
        seconds = if record.properties.key?('boot_timeout_s')
                    number(record, 'boot_timeout_s')
                  else
                    @codec.constant('boot_timeout_default_s')
                  end
        maximum = @codec.constant('boot_timeout_max_s')
        return seconds if seconds.between?(1, maximum)

        invalid("a configured domain's boot timeout of #{seconds} s is outside 1 to #{maximum} s", 'source',
                'domain.boot_timeout_s')
      end

      # Property 14: each session template, keyed by its principal, from which the
      # domain service makes every session of that principal on request
      # (docs/design-system.md, "The system manifest"). A template is not a domain row,
      # so the boot order, the plans and every holder, server and introduction, which
      # resolve through the domain table, never reach one; a facet alone may name it as
      # its grantee (facet_grantee). A `session NAME`
      # record's NAME is its principal's, so a principal has one by the source's own
      # key, and the rows are written in principal order. Its domain makes its
      # programs as sub-spaces, so its limits enable SPACES; the limits are judged
      # against the principal's ceilings, budget and quota when a session is made,
      # on the request path.
      def normalize_sessions(rows)
        spaces = @codec.member('mf_limits_flags', 'spaces')
        records('session').map do |record|
          principal = @indices.fetch('principal')[record.name] ||
                      invalid('a session template names no principal', 14, 'session.name')
          limits = reference(record, 'limits', 'limits')
          invalid('a session template\'s limits do not enable SPACES', 14, 'session.limits') if
            (rows.fetch('limits').fetch(limits).fetch('flags') & spaces).zero?
          args = boot_args(record, property: 14, field: 'session.args')
          invalid('arguments and environment exceed the boot page\'s strings', 14, 'session.args') if
            args.bytesize + words(record, 'env').bytesize > @codec.constant('boot_strings_max')
          runtime = artifact(record, 'runtime', 'executable', property: 14, field: 'session.runtime')
          release = artifact(record, 'release', 'release', property: 14, field: 'session.release')
          { 'principal' => principal, 'limits' => limits, 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'args' => args, 'env' => words(record, 'env') }
        end.sort_by { |row| row.fetch('principal') }
      end

      # A domain row's or session template's arguments as its boot page holds them: its
      # emulator flags (the words before the first --), then -- -boot /bin/<name> --,
      # then its init arguments (the words after that --). /bin/<name> is the boot
      # script of the domain release that its `release @artifact.<name>` names
      # (docs/design-stopgap.md, "The production image"). The binding is init's first
      # flag and the second -- closes its value, so no later word (-extra, a final -S)
      # can make it a plain argument and leave init to its default script. Its own
      # arguments naming -boot are refused, since its release names the script.
      # erx_domain_srv:boot_args/2 binds a created domain's the same way.
      def boot_args(record, property:, field:)
        args = words(record, 'args').split("\0")
        invalid('the arguments name -boot, which the release sets', property, field) if args.include?('-boot')
        name = release_name(record, property: property, field: field.sub('args', 'release'))
        emulator, init = args.index('--').then { |at| at ? [args[0...at], args[at + 1..]] : [args, []] }
        [*emulator, '--', '-boot', "/bin/#{name}", '--', *init].map { |word| "#{word}\0" }.join.b
      end

      # The <name> of a record's `release @artifact.<name>`, once artifact has checked that
      # it names a release.
      def release_name(record, property:, field:)
        artifact(record, 'release', 'release', property: property, field: field)
        one(record, 'release').value.delete_prefix('@artifact.')
      end

      # The artifact a record's key names, of the kind the packer recorded for it.
      def artifact(record, key, kind, property:, field:)
        token = one(record, key)
        named = !token.quoted && token.value.start_with?('@artifact.')
        artifact = named ? @context.artifacts[token.value.delete_prefix('@artifact.')] : nil
        invalid("#{key} names no #{kind} artifact of this pack", property, field) unless artifact.is_a?(Hash) && artifact['kind'] == kind
        artifact
      end

      def normalize_service(record)
        name = service_name(record)
        invalid('service name is not a system identifier', 5, 'service.name') unless name.match?(Frontend::IDENTIFIER)
        { 'name' => name, 'server' => holder_index(one(record, 'server'), property: 2, field: 'service.server'),
          'interface' => interface_number(record) }
      end

      # A service's interface number: the name of an interface abi/services declares, as
      # design-abi.md writes it, or a number, which the stopgap also takes for an
      # interface no fragment declares yet. The row holds the number either way, so a
      # check that reasons from a declared interface (property 8's driver control) sees
      # both spellings.
      def interface_number(record)
        token = one(record, 'interface')
        return number(record, 'interface') if token.quoted || token.value.match?(/\A[0-9]/)

        find_interface(token.value) || record.line.fail!('interface names no service abi/services declares')
      end

      def find_interface(name) = @codec.schema.services.find { |service| service.fetch(:name) == name }&.fetch(:number)

      # An interface a check reasons from, which the ABI must declare.
      def fetch_interface(name) = find_interface(name) || raise(Erx::Error, "abi/services declares no interface #{name}")

      # design-abi.md: an introduction joins two different configured domains and is
      # unique as an unordered pair, so each is written with the lower index first.
      def normalize_introductions
        rows = records('introduce').map do |record|
          pair = record.properties.fetch('targets').map do |token|
            domain_index(token) || invalid('introduction names no configured domain', 2, 'introduce')
          end
          invalid('an introduction joins two different domains', 2, 'introduce') unless pair.uniq.size == 2
          { 'from' => pair.min, 'to' => pair.max }
        end
        invalid('two introductions join one pair', 2, 'introduce') unless rows.uniq.size == rows.size
        rows.sort_by { |row| row.values_at('from', 'to') }
      end

      # Each facet row, sorted by name qualified by its grantee: its grantee (facet_grantee),
      # its service's index in the sorted service table and the grant's limits, an omitted
      # queue resolved to system_queue. A facet is installed in its grantee's registry
      # under its service's name (docs/design-system.md, "Facets a configured domain
      # serves"), so a grantee takes at most one facet of a service name, whichever domain
      # serves it (property 2); the system domain takes no facet of its own service; and a
      # session template takes facets of configured domains' services alone, which the
      # server grants the session directly. A facet of the driver-control interface stops
      # and starts another domain's drivers, so only the system domain holds one
      # (property 8); the network's facets are property 15's (check_network_grants).
      def normalize_facets(services, tables)
        service_rows = tables.fetch('services')
        rows = records('facet').map do |record|
          token = one(record, 'service')
          index = services.index { |service| !token.quoted && "@service.#{service.name}" == token.value }
          invalid('facet names a service the manifest does not contain', 2, 'facet.service') unless index
          facet_row(record, index, tables.fetch('sessions'))
        end
        grantee = ->(row) { row.values_at('grantee_kind', 'grantee') }
        server = ->(row) { service_rows.fetch(row.fetch('service')).fetch('server') }
        none = @codec.constant('mf_none')
        invalid('two facets of one grantee share a name', 5, 'facet.name') unless
          rows.map { |row| [grantee.call(row), row.fetch('name')] }.uniq.size == rows.size
        taken = rows.map { |row| [grantee.call(row), service_rows.fetch(row.fetch('service')).fetch('name')] }
        invalid('a grantee takes two facets of one service name', 2, 'facet.service') unless taken.uniq.size == taken.size
        invalid('the system domain takes no facet of its own service', 2, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') == grantee_kind('system') && server.call(row) == none }
        invalid('a session template takes facets of configured domains\' services alone', 2, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') == grantee_kind('session') && server.call(row) == none }
        control = fetch_interface('driver_control')
        invalid('only the system domain holds a driver-control facet', 8, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') != grantee_kind('system') && service_rows.fetch(row.fetch('service')).fetch('interface') == control }
        check_network_grants(rows, tables)
        rows.sort_by { |row| [row.fetch('name'), *grantee.call(row)] }
      end

      # Property 15: the system domain holds no facet of the network domain's net or
      # netadmin interface, compared by number, however the service row spells it. Each
      # grantee of net, a configured domain or a session template, takes frames of at
      # least net_max_frame_min bytes under its own runtime limits, since the socket
      # protocol's piece and its envelope arrive in one frame. The manifest is the only
      # source of a net grant, since no requested create carries one, so this holds for
      # every grant there is.
      def check_network_grants(facets, tables)
        net, netadmin = fetch_interface('net'), fetch_interface('netadmin')
        interface = ->(row) { tables.fetch('services').fetch(row.fetch('service')).fetch('interface') }
        facets.each do |row|
          next unless row.fetch('grantee_kind') == grantee_kind('system') && [net, netadmin].include?(interface.call(row))

          invalid("facet #{row.fetch('name')} grants the system domain a network interface, which it never holds", 15, 'facet.grantee')
        end
        floor = @codec.constant('net_max_frame_min')
        facets.select { |row| interface.call(row) == net }.each do |row|
          max_frame = grantee_max_frame(row, tables)
          next if max_frame >= floor

          invalid("facet #{row.fetch('name')}'s grantee takes frames of at most #{max_frame} bytes, below net's floor of #{floor}",
                  15, 'runtime_limits.max_frame')
        end
      end

      # The max_frame of a configured domain's or a session template's runtime limits.
      def grantee_max_frame(row, tables)
        table = case row.fetch('grantee_kind')
                when grantee_kind('domain') then 'domains'
                when grantee_kind('session') then 'sessions'
                else raise Erx::Error, 'the system domain has no grantee runtime limits here'
                end
        limits = tables.fetch('limits').fetch(tables.fetch(table).fetch(row.fetch('grantee')).fetch('limits'))
        tables.fetch('runtime_limits').fetch(limits.fetch('runtime_limits')).fetch('max_frame')
      end

      # The facets' edges from each configured or system grantee to its service's server,
      # mf_none for the system domain, which the boot order and the rescue configuration
      # follow. A session template is never started at boot, so its grants are no edge.
      def boot_edges(facets, services)
        none = @codec.constant('mf_none')
        facets.filter_map do |row|
          client = case row.fetch('grantee_kind')
                   when grantee_kind('domain') then row.fetch('grantee')
                   when grantee_kind('system') then none
                   end
          [client, services.fetch(row.fetch('service')).fetch('server')] if client
        end
      end

      def grantee_kind(name) = @codec.member('mf_grantee', name)

      # A facet's grantee as its kind and index: the system domain, written system, with
      # index 0; a configured domain, @domain.NAME, by its index; or a session template,
      # @session.PRINCIPAL, by its index in the sessions table.
      def facet_grantee(token, sessions)
        return [grantee_kind('system'), 0] if !token.quoted && token.value == 'system'

        domain = domain_index(token)
        return [grantee_kind('domain'), domain] if domain

        session = session_index(token, sessions)
        return [grantee_kind('session'), session] if session

        invalid('names neither the system domain, a configured domain nor a session template', 2, 'facet.grantee')
      end

      # A session template's index, or nil when the token names none.
      def session_index(token, sessions)
        return nil if token.quoted || !token.value.start_with?('@session.')

        principal = @indices.fetch('principal')[token.value.delete_prefix('@session.')]
        principal && sessions.index { |row| row.fetch('principal') == principal }
      end

      def facet_row(record, service, sessions)
        name = record.properties.key?('name') ? text(record, 'name') : record.name.b
        invalid('facet name is not a system identifier', 5, 'facet.name') unless name.match?(Frontend::IDENTIFIER)
        queue = record.properties.key?('queue') ? number(record, 'queue') : number(@source.machine, 'system_queue')
        kind, index = facet_grantee(one(record, 'grantee'), sessions)
        { 'name' => name, 'grantee_kind' => kind, 'grantee' => index,
          'service' => service,
          'operations' => { 'table' => 'facet_operations', 'first' => 0, 'count' => 0 },
          'parameters' => { 'table' => 'facet_parameters', 'first' => 0, 'count' => 0 },
          'queue' => queue }.merge(%w[max_request in_flight reductions period_ns max_heap_size].to_h { |key| [key, number(record, key)] })
      end

      # What the stopgap cannot honour, refused once properties 2, 10 and 11 hold: a
      # facet that names an operation or a parameter, which resolve against its
      # service's generated declarations and grant checker at M5, so the row would
      # grant every operation.
      def check_facets_supported
        records('facet').each do |record|
          operations = one(record, 'operations')
          next if record.parameters.empty? && !operations.quoted && operations.value == 'none'

          unsupported('a facet resolves its operations and parameters against its service\'s generated declarations and grant checker, which M5 brings', 'facet')
        end
      end

      # Property 10: every server before its clients, ties broken by name order, which
      # the domains' indices follow. A domain is ready once every configured domain
      # its facets name is placed; none ready means the facets lead back to one.
      def boot_order(domains, edges)
        servers = edges.group_by(&:first).transform_values { |pairs| pairs.map(&:last) - [@codec.constant('mf_none')] }
        domains.each_index.each_with_object([]) do |_step, placed|
          ready = (domains.each_index.to_a - placed).find { |domain| (servers.fetch(domain, []) - placed).empty? }
          invalid('a configured domain\'s facets lead back to it', 10, 'facet.service') unless ready
          placed << ready
        end.map { |domain| { 'domain' => domain } }
      end

      # Property 11: a domain the rescue configuration starts takes facets only of
      # the system domain and of other domains it starts.
      def check_rescue(domains, edges)
        rescue_flag = @codec.member('mf_domain_flags', 'rescue')
        rescued = ->(index) { (domains.fetch(index).fetch('flags') & rescue_flag) != 0 }
        none = @codec.constant('mf_none')
        edges.each do |client, server|
          next unless client != none && server != none && rescued.call(client) && !rescued.call(server)

          invalid('a rescue domain names a service of a domain the rescue configuration does not start', 11, 'facet.service')
        end
      end

      public

      # Property 12: the domain library's host build, given the packed manifest, builds
      # the boot's view with the root's own builder, so each principal passes
      # erx_dom_principal_check, then plans every configured domain in boot order and
      # every introduction against a model machine that records each plan as the boot
      # does. So the configured domains' share of properties 4 and 13 (each principal's
      # domain quota and budget, each grant within system and the service grants within
      # its reserve) and the connection rows are the library's own judgment, in its own
      # arithmetic. A build passes a planner always; without one, a manifest with no
      # domains is not planned, and one with some fails closed.
      def check_plans(bytes, rows)
        domains = rows.fetch('domains')
        unless @planner
          return if domains.empty?

          raise Unsupported.new('configured domains need the domain library\'s host planner', property: 12, field: 'planner')
        end

        order = rows.fetch('boot_order').map { |step| step.fetch('domain') }
        statuses = @planner.call(plan_view(bytes, rows, order: order))
        invalid("the domain library refuses the manifest's view: #{statuses.fetch('refused').delete_prefix('manifest: ')}", 12, 'view') if statuses.key?('refused')
        order.zip(statuses.fetch('domains')).each do |index, status|
          refuse_plan(status, "configured domain #{domains.fetch(index).fetch('name')}", 'domain')
        end
        rows.fetch('introductions').zip(statuses.fetch('introductions')).each do |row, status|
          names = row.values_at('from', 'to').map { |index| domains.fetch(index).fetch('name') }
          refuse_plan(status, "the introduction of #{names.join(' and ')}", 'introduce')
        end
      end

      private

      # Refuses the manifest naming what the library refused; status 0 passes.
      def refuse_plan(status, what, field)
        return if status.zero?

        name = (@codec.schema.statuses || {}).key(status) || status
        invalid("the domain library refuses #{what} with #{name}", 12, field)
      end

      # The planner's view (DomainPlanner#call): the packed manifest, each archive entry
      # with the bytes it will start with, the configured rows in boot order and each
      # introduction's parties their places in it.
      def plan_view(bytes, rows, order:)
        place = order.each_with_index.to_h
        introductions = rows.fetch('introductions').map do |row|
          { 'a' => place.fetch(row.fetch('from')), 'b' => place.fetch(row.fetch('to')) }
        end
        { 'manifest' => bytes, 'files' => @context.catalog.map { |row| plan_file(row) }, 'order' => order,
          'introductions' => introductions }
      end

      # A boot-image entry as the archive will hold it: an image starts with its image
      # manifest, which the packer encodes so (PackWire#write_image); the library judges it.
      def plan_file(row)
        head = row['image'].is_a?(Hash) ? @codec.encode_layout('erx_image_manifest', row.fetch('image')) : ''.b
        { 'kind' => row.fetch('kind'), 'flags' => row.fetch('flags'), 'head' => head }
      end

      # The slot writer's roles: in Phase 1 the system domain writes the slots.
      SLOT_WRITER_ROLES = %w[slot_a slot_b boot_selection reset_count].freeze

      def normalize_windows(devices, images)
        rows = records('window').map do |record|
          role = window_role(record)
          slot_writer = SLOT_WRITER_ROLES.any? { |name| role == @codec.member('mf_window_role', name) }
          invalid('only the system domain, the slot writer, holds the slot windows', 8, 'window.holder') if
            slot_writer && !(one(record, 'holder').value == 'system' && !one(record, 'holder').quoted)
          { 'holder' => holder_index(one(record, 'holder'), property: 8, field: 'window.holder'),
            'device' => window_device(record, devices), 'role' => role, 'partition' => window_partition(record, role),
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
        block_device(text(record, 'device'), devices) || invalid('window names no block device the manifest places', 8, 'window.device')
      end

      def block_device(path, devices) = devices.index { |device| device['path'] == path && device.fetch('role') == device_role('block') }

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
          placed = checked_extents(artifact(record, 'input', 'erofs_image', property: 8, field: 'image.input'))
          bytes = placed.sum { |extent| extent.fetch('length') }
          invalid('an image is whole blocks', 8, 'image.input') unless (bytes % block_size).zero?
          device = block_device(text(record, 'device'), devices) || invalid('image names no block device the manifest places', 8, 'image.device')
          images << { 'name' => record.name.b, 'device' => device,
                      'format' => @codec.member('mf_image_format', 'erofs_unchecked'),
                      'extents' => { 'table' => 'extents', 'first' => extents.size, 'count' => placed.size },
                      'data_bytes' => bytes, 'data_block_size' => block_size, 'data_blocks' => bytes / block_size }
                    .merge(NO_TREE)
          extents.concat(placed)
        end
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
