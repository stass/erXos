# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'abi_binary'
require_relative 'generated_abi'

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
          when 'directory'
            unless source.keys == %w[kind]
              raise Invalid.new('invalid empty directory', property: 'context', field: 'catalog.source')
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
        'partial_boot' => %w[image],
        'start' => %w[enable display restarts restart_period_s],
        'display' => %w[policy idle_dim_s idle_off_s]
      }.freeze
      OPTIONAL = { 'machine' => %w[system_args], 'domain' => %w[boot_timeout_s args env], 'session' => %w[args env], 'service' => %w[name],
                   'facet' => %w[name queue], 'image' => %w[salt],
                   'start' => %w[enable display restarts restart_period_s] }.freeze
      DIRECTIVES = { 'introduce' => 2, 'liveness' => 1, 'shell_principal' => 1 }.freeze
      IDENTIFIER = /\A[a-z0-9][a-z0-9_-]{0,62}\z/.freeze
      module_function

      # The manifest bytes declare, refused unless it is version.
      def parse(bytes, version:) = read(bytes, version: version)

      # The manifest bytes declare. With version, a header naming another is refused
      # before any record is read; without, the header names it: what a harness edits
      # (Manifest::Edit) before the edited text is admitted, which checks it (parse).
      def read(bytes, version: nil)
        declarations = ABI::Syntax.parse(bytes, path: 'config/manifest')
        headers = declarations.select { |item| item.kind == 'manifest' }
        header = headers.first if headers.size == 1 && headers.first.args.size == 1 && headers.first.members.empty?
        declared = header && ABI::Syntax.integer(header.args.first, line: header.line)
        unless declared && (version.nil? || declared == version)
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
        Source.new(version: declared, machine: machine,
                   records: records.to_h.transform_values { |list| list.freeze }.freeze).freeze
      end

      # The manifest text of source, which read reads back to the same records: the
      # header, the machine, then every other record, kind by kind in the order read
      # found them, each with its properties and then its facet parameters. Comments are
      # not kept; the encoder sorts every table, so the order of records is not the
      # manifest's either.
      def render(source)
        ["manifest #{source.version}\n", record_text(source.machine),
         *source.records.values.flatten.map { |record| record_text(record) }].join
      end

      def record_text(record)
        return "#{[record.kind, *record.properties.fetch('targets').map { |token| token_text(token) }].join(' ')}\n" if
          DIRECTIVES.key?(record.kind)

        members = [*record.properties.map { |key, tokens| [key, *tokens] },
                   *record.parameters.map { |tokens| ['parameter', *tokens] }]
        lines = [[record.kind, record.name].compact.join(' '),
                 *members.map { |key, *tokens| "  #{[key, *tokens.map { |token| token_text(token) }].join(' ')}" }]
        "#{lines.join("\n")}\n"
      end

      # A token as ABI::Syntax reads it back: a quoted one with its quote and backslash
      # escaped, and any byte outside printable ASCII as \xNN.
      def token_text(token)
        return token.value unless token.quoted

        escaped = token.value.each_byte.map do |byte|
          case byte
          when 34, 92 then "\\#{byte.chr}"
          when 32..126 then byte.chr
          else format('\\x%02x', byte)
          end
        end
        "\"#{escaped.join}\""
      end
      private_class_method :record_text, :token_text
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

      # The archive rule, which the packer applies once it has written the archive. At
      # boot the root refuses unless the pool's free pages and its own image hold
      # root_memory (root_memory_fits in liberx/backend/fiasco/root.c). What sigma0 gives
      # the root is RAM less fiasco_reserve, less the archive, which bootstrap reserves
      # whole, less what the boot keeps besides (boot_kept). So the packer checks the
      # same inequality,
      #
      #   archive + root_memory <= RAM - fiasco_reserve - boot_kept,
      #
      # with boot_kept estimated from the platform record, the archive and the devices'
      # memory the manifest declares (dma_memory, the admission report's). The estimate
      # errs high by a few hundred KiB (docs/design-stopgap.md, "The root startup
      # rule"), so an image this refuses fails at boot or comes within that margin of
      # failing. Every figure is in bytes; the platform's come from archive_machine.
      # An archive that fits returns the figures the rule derived (ArchiveRoom), which
      # the packer reports, so no comment has to copy them.
      def check_archive(archive_bytes:, root_memory:, dma_memory:, ram_bytes:, fiasco_reserve:, root_withheld:)
        kept = boot_kept(ram_bytes: ram_bytes, fiasco_reserve: fiasco_reserve, archive_bytes: archive_bytes,
                         root_withheld: root_withheld, dma_memory: dma_memory)
        room = ram_bytes - fiasco_reserve - kept
        short = archive_bytes + root_memory - room
        unless short.positive?
          return ArchiveRoom.new(archive_bytes: archive_bytes, root_memory: root_memory, kept_bytes: kept,
                                 archive_max_bytes: room - root_memory)
        end

        raise Invalid.new("the archive (#{mib(archive_bytes)}) and root_memory (#{mib(root_memory)}) exceed the " \
                          "#{mib(room)} this machine leaves them (RAM less fiasco_reserve and the #{mib(kept)} " \
                          "the boot keeps) by #{(short + 1023) / 1024} KiB",
                          property: 4, field: 'root_startup')
      end

      # What check_archive derived for an archive that fits, in bytes: the archive, the
      # manifest's root_memory, what the boot keeps besides (boot_kept), and the largest
      # archive this root_memory leaves room for on the machine. The packer's report
      # carries it as a hash of those names.
      ArchiveRoom = Data.define(:archive_bytes, :root_memory, :kept_bytes, :archive_max_bytes) do
        def to_h = super.transform_keys(&:to_s)
      end

      # The line the image build prints for a pack's report: the archive; the room
      # root_memory leaves it on the machine (the report's ArchiveRoom); root_memory and
      # how much of it the manifest's budgets promise (the admission report's
      # promised_memory); and what the boot keeps.
      def room_line(report)
        room = report.fetch('archive_room')
        promised = report.fetch('manifest').fetch('promised_memory')
        "archive #{mib(room.fetch('archive_bytes'))}, room for #{mib(room.fetch('archive_max_bytes'))} " \
          "beside root_memory #{mib(room.fetch('root_memory'))}, of which budgets promise #{mib(promised)}; " \
          "the boot keeps #{mib(room.fetch('kept_bytes'))}"
      end

      # The boot's side of check_archive. The root reports the pool's free pages and its
      # own image, what root_memory_fits counted; RAM less fiasco_reserve, the archive and
      # those is what this boot kept besides. Once a boot keeps more than boot_kept
      # estimates, the packer can pass an archive the root refuses, so the production
      # image suite holds its boots to the estimate. A report that leaves the boot keeping
      # less than the page index alone is no measurement, and is refused too. archive_bytes
      # is the archive in whole pages, as bootstrap reserves it, and dma_memory the
      # manifest's devices' memory, which sized the boot's contiguous pool. The failure is the
      # platform record's or the boot's, not the manifest's, so it is a plain Error.
      def check_boot(archive_bytes:, pool_pages:, image_bytes:, dma_memory:, ram_bytes:, fiasco_reserve:, root_withheld:)
        kept = ram_bytes - fiasco_reserve - archive_bytes - (pool_pages * PAGE_BYTES) - image_bytes
        estimate = boot_kept(ram_bytes: ram_bytes, fiasco_reserve: fiasco_reserve, archive_bytes: archive_bytes,
                             root_withheld: root_withheld, dma_memory: dma_memory)
        index = page_index_bytes((ram_bytes - fiasco_reserve - archive_bytes) / PAGE_BYTES)
        raise Error, "the root's report leaves the boot #{kept} bytes, less than the #{index} of the page index" if kept < index
        return if kept <= estimate

        raise Error, "the boot kept #{kept} bytes besides the archive, #{kept - estimate} more than the #{estimate} " \
                     "the packer counts: the platform record's root_withheld #{root_withheld} is too small, " \
                     'or Fiasco or liberx keeps more than it was measured to'
      end

      # The platform's figures check_archive and check_boot take, from the record as Pack
      # receives it (Erx::Platform#record, or a ProductionImage::Machine's, which states
      # that machine's RAM and fiasco_reserve): RAM, fiasco_reserve and root_withheld.
      # Erx::Platform refuses a record without root_withheld when it loads it; a record
      # that reaches here some other way without one packs no image.
      def archive_machine(platform)
        memory = declared(platform)
        withheld = platform['root_withheld']
        unless withheld.is_a?(Integer) && withheld.positive?
          raise Unsupported.new('the platform record states no root_withheld to check the archive against',
                                property: 4, field: 'root_startup')
        end
        { ram_bytes: memory.fetch('ram_bytes'), fiasco_reserve: memory.fetch('fiasco_reserve'),
          root_withheld: withheld }
      end

      # What a boot keeps from RAM less fiasco_reserve besides the archive: the platform
      # record's root_withheld (Fiasco's and sigma0's images, the device tree, the
      # handoff page, and the pool's object table, the root's range table and its
      # thread table), liberx's contiguous pool for the devices' memory the manifest
      # declares, and the pool's page index.
      def boot_kept(ram_bytes:, fiasco_reserve:, archive_bytes:, root_withheld:, dma_memory:)
        root_withheld + contiguous_pool_bytes(dma_memory) +
          page_index_bytes((ram_bytes - fiasco_reserve - archive_bytes) / PAGE_BYTES)
      end

      # The contiguous pool the root takes for dma_memory bytes of devices' memory, as
      # erx_fiasco_contig_order (liberx/backend/fiasco/page_pool.c) sizes it: the
      # smallest power of two that holds them, at least CONTIGUOUS_POOL_MIN_BYTES. The
      # manifest check refuses more than CONTIGUOUS_POOL_MAX_BYTES, so a total past it
      # is the caller's error.
      def contiguous_pool_bytes(dma_memory)
        raise Error, "no contiguous pool holds #{dma_memory} bytes" unless
          dma_memory.between?(0, CONTIGUOUS_POOL_MAX_BYTES)

        [CONTIGUOUS_POOL_MIN_BYTES, 1 << (dma_memory - 1).bit_length].max
      end

      # A page and the contiguous pool's smallest and largest sizes, from the ABI
      # (page_size, fiasco_contig_order_min and fiasco_contig_order_max). The other two
      # are liberx's own and copied: sizeof(erx_backend_vm_page_t)
      # (liberx/backend/core/vm_table.h, which vm_table.c asserts) and VM_DEVICE_PAGES
      # (liberx/backend/fiasco/vm.c).
      PAGE_BYTES = ABI::Generated.constant('page_size')
      PAGE_INDEX_SLOT_BYTES = 16
      DEVICE_PAGES = 4096
      CONTIGUOUS_POOL_MIN_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_min')
      CONTIGUOUS_POOL_MAX_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_max')

      # erx_backend_vm_layout (liberx/backend/core/vm_table.c) sizes the index over the
      # pool's window, its contiguous pool and the device pages. The window and the
      # contiguous pool lie in RAM less fiasco_reserve and the archive, so sizing it over
      # all of those pages never comes out smaller. Its loop doubles from one page of
      # slots to the smallest power of two at least twice the pages covered; the shift
      # finds that power directly.
      def page_index_bytes(pages_free)
        covered = pages_free + DEVICE_PAGES
        slots = 1 << ((2 * covered) - 1).bit_length
        [slots, PAGE_BYTES / PAGE_INDEX_SLOT_BYTES].max * PAGE_INDEX_SLOT_BYTES
      end

      def mib(bytes) = format('%.2f MiB', bytes / 1_048_576.0)
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
        checker.check_plans(bytes, normalized)
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
      # The compatible string of the one device whose row carries a clock (device_clock).
      PL011_COMPATIBLE = 'arm,pl011'
      # What a framebuffer row names (docs/design-device-tree.md, "The framebuffer record"):
      # the node whose children the root searches, and the compatible string the one child
      # it takes must carry.
      FRAMEBUFFER_PATH = '/chosen'
      FRAMEBUFFER_COMPATIBLE = 'simple-framebuffer'
      # A device-tree node path as erx_boot_node_path_valid (include/erx/core/boot_handoff.h)
      # has it: '/' and the characters the specification allows in names.
      NODE_PATH = %r{\A/[A-Za-z0-9,._+@/-]*\z}

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
        # The stopgap's contiguous pool holds every device's memory at once (RootStartup.contiguous_pool_bytes).
        if device_memory > RootStartup::CONTIGUOUS_POOL_MAX_BYTES
          invalid("device memory exceeds the #{RootStartup::CONTIGUOUS_POOL_MAX_BYTES >> 20} MiB contiguous pool", 4, 'devices.dma_memory')
        end
        promised = principals.sum { |row| row.fetch('memory') } + baseline + device_memory
        if promised > root_memory
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
        system_principal = reference(machine, 'system_principal', 'principal')
        # The system principal's sessions are root_N (erx_domain_core:session_prefix/3),
        # so a principal named root must be the system principal.
        root = @indices.fetch('principal').fetch('root', system_principal)
        invalid('only the system principal may be named root', 5, 'principal.name') unless root == system_principal
        header = {
          'magic' => @codec.constant('manifest_magic'), 'version' => @codec.constant('manifest_version'),
          'flags' => flags, 'host' => text(machine, 'host'), 'system_args' => words(machine, 'system_args'),
          'console' => console,
          'hostlink' => hostlink, 'platform' => platform_name, 'root_memory' => root_memory,
          'system_baseline' => baseline, 'system_reservation' => 0,
          'system_share' => system_share, 'users_share' => users_share,
          'system_principal' => system_principal,
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
                   'root_image_private_bytes' => root_private_bytes, 'root_memory' => root_memory,
                   'dma_memory' => device_memory, 'promised_memory' => promised,
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
        names.reduce(0) { |mask, name| mask | member(record.line, key, type, name) }
      end

      def enum(record, key, type)
        token = one(record, key)
        record.line.fail!('enumeration value cannot be quoted') if token.quoted
        member(record.line, key, type, token.value)
      end

      # The value of the member of enumeration or flag set type that a source word names,
      # refused on its line when type has no such member.
      def member(line, key, type, name)
        members = @codec.schema.types.fetch(type).members
        members.fetch(name) { line.fail!("#{key} names no member of #{type}: #{members.keys.join(', ')}") }
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
            normalized = platform_device(device)
            normalized['clock'] = device_clock(normalized)
            check_device(normalized)
            rows.fetch('devices') << normalized
          end
          rows.fetch('units') << { 'name' => record.name, 'holder' => holder,
                                   'devices' => { 'table' => 'devices', 'first' => first, 'count' => rows.fetch('devices').size - first } }
        end
        check_framebuffer_windows(by_key.values.flat_map { |unit| unit.fetch('devices') })
      end

      # A framebuffer row's shape (docs/design-device-tree.md, "The framebuffer record"): a
      # device-tree row at FRAMEBUFFER_PATH for FRAMEBUFFER_COMPATIBLE's node, with no DMA, no
      # line and no flags, whose base and size are its window, whole pages, since the root maps
      # the framebuffer by the page and the tree chooses where in the window it lies.
      def check_framebuffer(device)
        return unless device.fetch('role') == @codec.member('mf_device_role', 'framebuffer')

        unless device.fetch('selector') == @codec.member('mf_selector', 'dt') && device['path'] == FRAMEBUFFER_PATH &&
               device['compatible'] == FRAMEBUFFER_COMPATIBLE
          invalid("a framebuffer row names #{FRAMEBUFFER_PATH} and #{FRAMEBUFFER_COMPATIBLE}", 'context', 'platform.devices')
        end
        unless device.fetch('dma') == @codec.member('mf_dma', 'none') && device.fetch('line').zero? && device.fetch('flags').zero?
          invalid('a framebuffer row has no DMA, line or flags', 'context', 'platform.devices')
        end
        page = @codec.constant('page_size')
        return if (device.fetch('base') % page).zero? && (device.fetch('size') % page).zero?

        invalid('a framebuffer window is whole pages', 'context', 'platform.devices')
      end

      # Property 1 for a framebuffer's window: the root maps for the window's holder whatever
      # pages of it the firmware's tree names, so a window that meets another device-tree
      # device's register window of the platform, placed or not, would let the tree hand that
      # holder another device's registers, and one that meets the platform's RAM would let it
      # hand over memory the root allocates. Every framebuffer row of roster, the platform
      # record's every device, is checked, placed or not, so a wrong window fails before a
      # manifest places it; each row is read as a placed one is (platform_device), so a field
      # the record writes as the codec's number compares as its name does. Windows are
      # half-open ranges, [base, limit).
      def check_framebuffer_windows(roster)
        devices = roster.map { |device| platform_device(device) }
        framebuffer = @codec.member('mf_device_role', 'framebuffer')
        device_tree = @codec.member('mf_selector', 'dt')
        devices.select { |device| device.fetch('role') == framebuffer }.each do |row|
          check_framebuffer(row)
          base = row.fetch('base')
          limit = base + row.fetch('size')
          invalid('a framebuffer window meets the platform\'s RAM', 1, 'devices.base') if meets_ram?(base, limit)
          devices.each do |device|
            next if device.fetch('role') == framebuffer || device.fetch('selector') != device_tree
            next unless device.fetch('base') < limit && base < device.fetch('base') + device.fetch('size')

            invalid("a framebuffer window meets #{device['path']}'s registers", 1, 'devices.base')
          end
        end
      end

      # Whether [base, limit) meets the RAM the platform record states.
      def meets_ram?(base, limit)
        first, bytes = @context.platform.values_at('ram_first', 'ram_bytes')
        invalid('checked platform needs its RAM', 'context', 'platform.ram_first') unless
          first.is_a?(Integer) && bytes.is_a?(Integer)
        base < first + bytes && first < limit
      end

      # A platform record's device row as the device table holds it: its selector, role and
      # DMA kind as the codec's numbers, flags and DMA memory defaulted to 0, and a
      # device-tree row's window and line checked integers (device_window).
      def platform_device(device)
        invalid('invalid checked device row', 'context', 'platform.devices') unless device.is_a?(Hash)
        normalized = device.dup
        { 'selector' => 'mf_selector', 'role' => 'mf_device_role', 'dma' => 'mf_dma' }.each do |field, type|
          normalized[field] = @codec.member(type, normalized.fetch(field)) if normalized[field].is_a?(String)
        end
        normalized['flags'] = normalized.fetch('flags', 0)
        normalized['dma_memory'] = normalized.fetch('dma_memory', 0)
        normalized.merge(device_window(normalized))
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
        unless device_path?(device['path'])
          invalid("device-tree device's path is not a node path of at most #{@codec.constant('device_path_max')} bytes",
                  'context', 'platform.devices')
        end
        device.slice(*fields)
      end

      # A device-tree row's path, which its device record carries as PATH, the device's name
      # to its driver (docs/design-stopgap.md, "Device records"): a node path of at most the
      # ABI's device_path_max bytes, as erx_boot_device_path_valid admits it.
      def device_path?(path) = path.is_a?(String) && path.match?(NODE_PATH) && path.bytesize <= @codec.constant('device_path_max')

      # The frequency in hertz of the clock a device's driver divides rates from, the first
      # entry of its device-tree node's `clocks` (docs/design-abi.md, "Devices and partition
      # windows"). A PL011's driver times its characters and divides its baud rate from it,
      # and only the board knows it, so a PL011 row carries a positive integer; no other
      # device's driver reads one, so every other row's is 0, absent or written so. The
      # codec holds the value to the row's 32 bits.
      def device_clock(device)
        clock = device.fetch('clock', 0)
        if device['compatible'] == PL011_COMPATIBLE
          invalid('a PL011 row lacks its clock in hertz', 'context', 'platform.devices') unless clock.is_a?(Integer) && clock.positive?
        else
          invalid('only a PL011 row carries a clock', 'context', 'platform.devices') unless clock == 0
        end
        clock
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
        check_uart_lines(rows, console, hostlink)
      end

      # Property 8's line clause (docs/design-shared-devices.md, "Lines inside a domain"):
      # the console and the host link each start their own UART's driver, and the owner of
      # its line when the line is shared, and a line has one binder, so the two UARTs must
      # not name one line. Both UARTs are placed device-tree devices (check_uarts).
      def check_uart_lines(rows, console, hostlink)
        return if hostlink.empty?

        console_line, hostlink_line = [console, hostlink].map do |path|
          rows.fetch('devices').find { |device| device['path'] == path }.fetch('line')
        end
        return unless console_line == hostlink_line

        invalid("console #{console} and host link #{hostlink} UARTs share interrupt line #{console_line}", 8,
                'machine.hostlink')
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
        %w[window service facet introduce image liveness display].each do |kind|
          invalid('empty native boot has no service or child assignments', 9, kind) unless records(kind).empty?
        end
        invalid('a partial boot starts no row', 17, 'start') unless records('start').empty?
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
        invalid('a partial boot starts no row', 17, 'start') unless records('start').empty?
        %w[service facet introduce liveness display].each do |kind|
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
          # The domain library gives it as one contiguous object.
          if device.fetch('dma_memory') > @codec.constant('mem_contiguous_max')
            invalid('a device memory reservation exceeds mem_contiguous_max', 4, 'devices.dma_memory')
          end
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
        rows['facets'], rows['facet_parameters'], facet_values = normalize_facets(services.map(&:first), rows)
        rows['starts'] = normalize_starts(services.map(&:first), rows)
        rows['displays'] = normalize_displays(services.map(&:first), rows, facet_values)
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

      # A start row's restart intensity where its source states none: more than
      # START_RESTARTS ends within START_RESTART_PERIOD_S seconds leave the row down
      # (docs/design-apps.md, "The start table").
      START_RESTARTS = 5
      START_RESTART_PERIOD_S = 600

      # The manifest's start rows, sorted by their principal's index, each with its
      # defaults applied: enabled, no display and START_RESTARTS ends in
      # START_RESTART_PERIOD_S seconds. Property 17's structural clauses: a row is keyed
      # by its principal's name, so the frontend gives a principal at most one, and that
      # principal has a session template; no two enabled rows name one display; and a
      # display is a service of the windows interface that a facet row grants the
      # principal's template. Property 17's last
      # clause, that the enabled rows' sessions fit beside the configured domains, is the
      # domain library's judgment, in check_plans.
      def normalize_starts(services, tables)
        rows = records('start').map { |record| start_row(record, services, tables.fetch('sessions')) }
        enabled = @codec.member('mf_start_flags', 'enabled')
        none = @codec.constant('mf_none')
        displays = rows.select { |row| (row.fetch('flags') & enabled) != 0 }.map { |row| row.fetch('display') } - [none]
        invalid('two enabled start rows name one display', 17, 'start.display') unless displays.uniq.size == displays.size
        rows.reject { |row| row.fetch('display') == none }.each { |row| check_start_display(row, tables) }
        rows.sort_by { |row| row.fetch('principal') }
      end

      # One start row: its principal's index, which must have a session template, and
      # each field the record states or its default. The period is at least a second,
      # since the row's supervisor takes it as its own, and neither field is past its
      # ceiling in abi/manifest.txt, which the reader and the start table also hold to.
      def start_row(record, services, sessions)
        principal = @indices.fetch('principal')[record.name] || invalid('a start row names no principal', 17, 'start.name')
        invalid('a start row\'s principal has no session template', 17, 'start.name') unless
          sessions.any? { |row| row.fetch('principal') == principal }
        stated = ->(key, default, &value) { record.properties.key?(key) ? value.call(key) : default }
        row = { 'principal' => principal,
                'flags' => stated.call('enable', @codec.member('mf_start_flags', 'enabled')) { start_flags(record) },
                'display' => stated.call('display', @codec.constant('mf_none')) { start_display(record, services) },
                'restarts' => stated.call('restarts', START_RESTARTS) { |key| number(record, key) },
                'restart_period_s' => stated.call('restart_period_s', START_RESTART_PERIOD_S) { |key| number(record, key) } }
        invalid('a start row\'s restart period is under a second', 17, 'start.restart_period_s') if row.fetch('restart_period_s').zero?
        check_start_ceiling(row, 'restarts', 'start_restarts_max')
        check_start_ceiling(row, 'restart_period_s', 'start_period_max_s')
        row
      end

      # A start row's field Key is at most the ABI's limit Limit.
      def check_start_ceiling(row, key, limit)
        ceiling = @codec.constant(limit)
        invalid("a start row's #{key} is over #{ceiling}", 17, "start.#{key}") if row.fetch(key) > ceiling
      end

      # A row's enable: YES or NO, as rc.conf(5) writes it.
      def start_flags(record)
        token = one(record, 'enable')
        record.line.fail!('enable is YES or NO') if token.quoted || !%w[YES NO].include?(token.value)
        token.value == 'YES' ? @codec.member('mf_start_flags', 'enabled') : 0
      end

      # A row's display, @service.NAME, as the service's index in the sorted service table.
      def start_display(record, services)
        token = one(record, 'display')
        services.index { |service| !token.quoted && "@service.#{service.name}" == token.value } ||
          invalid('a start row\'s display names a service the manifest does not contain', 17, 'start.display')
      end

      # A row's display: a service of the windows interface, granted to the row's
      # principal's session template by a facet row.
      def check_start_display(row, tables)
        windows = find_interface('windows') ||
                  invalid('a start row names a display, and abi/services declares no windows interface', 17, 'start.display')
        display = row.fetch('display')
        invalid('a start row\'s display is not a windows service', 17, 'start.display') unless
          tables.fetch('services').fetch(display).fetch('interface') == windows
        session = tables.fetch('sessions').index { |template| template.fetch('principal') == row.fetch('principal') }
        grant = [grantee_kind('session'), session, display]
        invalid('a start row\'s display is not granted to its principal\'s session template', 17, 'start.display') unless
          tables.fetch('facets').any? { |facet| facet.values_at('grantee_kind', 'grantee', 'service') == grant }
      end

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
      # serves it (property 2); and the system domain takes no facet of its own service. A
      # session template may take a facet of a configured domain's service, which the
      # server grants each session made from it, or of a system-served one, which the
      # domain service starts for each such session (property 14). A facet of the
      # driver-control interface stops and starts another domain's drivers, so only the
      # system domain holds one (property 8); the network's facets are property 15's
      # (check_network_grants), and the files and inspect receivers' floors property 16's
      # (check_files_grants, check_inspect_grants). Each facet's parameters are resolved
      # against its service's declarations (facet_parameters). Answers the sorted rows, each
      # with its parameters span, the facet_parameters table and each row's resolved
      # parameter values, by key name, in the rows' order.
      def normalize_facets(services, tables)
        service_rows = tables.fetch('services')
        rows = records('facet').map do |record|
          token = one(record, 'service')
          index = services.index { |service| !token.quoted && "@service.#{service.name}" == token.value }
          invalid('facet names a service the manifest does not contain', 2, 'facet.service') unless index
          facet_row(record, index, tables.fetch('sessions'))
        end
        packed = records('facet').zip(rows).map { |record, row| facet_parameters(record, row, tables) }
        grantee = ->(row) { row.values_at('grantee_kind', 'grantee') }
        server = ->(row) { service_rows.fetch(row.fetch('service')).fetch('server') }
        none = @codec.constant('mf_none')
        invalid('two facets of one grantee share a name', 5, 'facet.name') unless
          rows.map { |row| [grantee.call(row), row.fetch('name')] }.uniq.size == rows.size
        taken = rows.map { |row| [grantee.call(row), service_rows.fetch(row.fetch('service')).fetch('name')] }
        invalid('a grantee takes two facets of one service name', 2, 'facet.service') unless taken.uniq.size == taken.size
        invalid('the system domain takes no facet of its own service', 2, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') == grantee_kind('system') && server.call(row) == none }
        control = fetch_interface('driver_control')
        invalid('only the system domain holds a driver-control facet', 8, 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') != grantee_kind('system') && service_rows.fetch(row.fetch('service')).fetch('interface') == control }
        check_network_grants(rows, tables)
        check_files_grants(rows, tables)
        check_inspect_grants(rows, tables)
        order = rows.each_index.sort_by { |at| [rows.fetch(at).fetch('name'), *grantee.call(rows.fetch(at))] }
        first = 0
        facets = order.map do |at|
          count = packed.fetch(at).last.size
          span = { 'table' => 'facet_parameters', 'first' => first, 'count' => count }
          first += count
          rows.fetch(at).merge('parameters' => span)
        end
        [facets, order.flat_map { |at| packed.fetch(at).last }, order.map { |at| packed.fetch(at).first }]
      end

      # The checkers that consume a service's declared parameters, by the name its
      # declarations give in checked_by, each with the keys it consumes (docs/design-abi.md,
      # "Services, facets and their parameter schemas"): windows_grant is property 18,
      # check_display_grants, which reads pixels and session, and range-checks windows and
      # snarf as their declarations bound them. A service declaring a parameter that no
      # checker here consumes is unusable: no facet of it is admitted, since nothing would
      # check what it grants.
      GRANT_CHECKERS = { 'windows_grant' => %w[windows pixels snarf session].freeze }.freeze

      # A facet record's parameters resolved against its service's declarations: every
      # stated key is declared, appears once and has a value of its declared kind within
      # its bound, and every key declared one is stated. Answers the values, by key name,
      # and their packed facet_parameters rows in key order.
      def facet_parameters(record, row, tables)
        interface = tables.fetch('services').fetch(row.fetch('service')).fetch('interface')
        declared = @codec.schema.services.find { |service| service.fetch(:number) == interface }&.fetch(:parameters) || {}
        unless declared.all? { |key, parameter| GRANT_CHECKERS.fetch(parameter.fetch(:helper), []).include?(key) }
          unsupported("facet #{row.fetch('name')}'s service declares a parameter no grant checker consumes", 'facet.parameter')
        end
        values = resolve_parameters(record, declared)
        [values.freeze, values.map { |key, value| parameter_row(declared.fetch(key), value) }.sort_by { |item| item.fetch('key') }]
      end

      # A facet record's parameter lines, KEY VALUE, as a map from key to value.
      def resolve_parameters(record, declared)
        values = record.parameters.each_with_object({}) do |(key_token, value_token), result|
          key = key_token.value
          parameter = (!key_token.quoted && declared[key]) ||
                      invalid("facet parameter #{key} is not declared by its service", 2, 'facet.parameter')
          invalid("facet parameter #{key} is stated twice", 2, 'facet.parameter') if result.key?(key)
          result[key] = parameter_value(key, parameter, value_token, record.line)
        end
        declared.each do |key, parameter|
          invalid("facet parameter #{key} is required", 2, 'facet.parameter') if parameter.fetch(:cardinality) == 'one' && !values.key?(key)
        end
        values
      end

      # One value of its declared kind: an integer within its range, yes or no for a
      # boolean, or quoted bytes within their bound. A set and the reference kinds are
      # refused while no service declares one, so nothing here guesses their spelling.
      def parameter_value(key, parameter, token, line)
        kind = parameter.fetch(:kind)
        unsupported("facet parameter #{key} is a set, which no service declares", 'facet.parameter') if
          parameter.fetch(:cardinality) == 'set'
        case kind
        when 'u64', 'i64'
          line.fail!("parameter #{key} requires an integer") if token.quoted
          value = ABI::Syntax.integer(token.value, line: line)
          low, high = parameter.fetch(:bound).drop(1).map { |word| ABI::Syntax.integer(word, line: line) }
          invalid("facet parameter #{key} is outside #{low} to #{high}", 2, 'facet.parameter') unless value.between?(low, high)
          value
        when 'boolean'
          line.fail!("parameter #{key} is yes or no") if token.quoted || !%w[yes no].include?(token.value)
          token.value == 'yes'
        when 'identifier', 'namespace_path', 'bytes'
          line.fail!("parameter #{key} requires quoted bytes") unless token.quoted
          value = token.value.b
          maximum = Integer(parameter.fetch(:bound).last)
          invalid("facet parameter #{key} is empty or over #{maximum} bytes", 2, 'facet.parameter') unless
            value.bytesize.between?(kind == 'bytes' ? 0 : 1, maximum)
          value
        else
          unsupported("facet parameter #{key} is a #{kind} reference, which no service declares", 'facet.parameter')
        end
      end

      # A resolved value as its packed facet_parameters row, every inactive field zero.
      def parameter_row(parameter, value)
        kind = parameter.fetch(:kind)
        row = { 'key' => parameter.fetch(:number), 'kind' => @codec.member('mf_parameter_kind', kind),
                'scalar' => 0, 'bytes' => ''.b, 'index' => 0, 'reserved' => 0 }
        case kind
        when 'u64' then row.merge('scalar' => value)
        when 'i64' then row.merge('scalar' => value & ((1 << 64) - 1))
        when 'boolean' then row.merge('scalar' => value ? 1 : 0)
        else row.merge('bytes' => value)
        end
      end

      # The displays (docs/design-display.md, "A display's session"), sorted by their
      # service's index; facet_values holds each facet row's resolved parameters, by the
      # facet table's index. A display record is keyed by its service's source alias, so
      # a service has at most one. Property 18: every windows service has a record and
      # every record names one; a display domain serves one display, so no domain pays
      # for two displays' grants out of one outer budget; and each display's grants pass
      # check_display_grants.
      def normalize_displays(services, tables, facet_values)
        windows = find_interface('windows')
        rows = records('display').map do |record|
          index = services.index { |service| service.name == record.name } ||
                  invalid('a display record names a service the manifest does not contain', 18, 'display.name')
          invalid('a display record names a service that is not of the windows interface', 18, 'display.name') unless
            tables.fetch('services').fetch(index).fetch('interface') == windows
          display_row(record, index)
        end
        tables.fetch('services').each_with_index do |service, index|
          next unless service.fetch('interface') == windows
          invalid("service #{service.fetch('name')} of the windows interface has no display record", 18, 'display.name') unless
            rows.any? { |row| row.fetch('service') == index }
        end
        servers = rows.map { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('server') }
        invalid('one domain serves two displays', 18, 'display.name') unless servers.uniq.size == servers.size
        rows.each { |row| check_display_grants(row, tables, facet_values) }
        rows.sort_by { |row| row.fetch('service') }
      end

      # One display record: its service's index, its policy and its idle times, of
      # which a nonzero time to turn the panel off comes no sooner than the time to dim it.
      def display_row(record, service)
        row = { 'service' => service, 'policy' => enum(record, 'policy', 'mf_display_policy') }
        %w[idle_dim_s idle_off_s].each do |key|
          row[key] = number(record, key)
          invalid("a display's #{key} is over #{(1 << 32) - 1}", 18, "display.#{key}") if row.fetch(key) >= (1 << 32)
        end
        invalid('a display turns its panel off before it dims it', 18, 'display.idle_off_s') unless
          row.fetch('idle_off_s').zero? || row.fetch('idle_off_s') >= row.fetch('idle_dim_s')
        row
      end

      # The environment keys a display domain takes from its display record, which its own
      # row may not set (abi/manifest.txt, display_key and the keys after it).
      def display_keys = %w[display_key display_policy_key display_idle_dim_key display_idle_off_key]
                         .map { |name| @codec.fixed_bytes(name) }

      # Property 18's clauses on one display's grants: its server is a configured
      # domain whose row sets none of display_keys, no facet row of its service grants it to the system domain, whose
      # connections no introduction makes and so carry no pixel area, no facet row of
      # its service sets session, and the grants' costs fit the
      # display domain's outer budget. Each grant costs its pixel area, its pixels or
      # windows_pixels_default, and the side the display reads for it, the display's own
      # lane, each rounded up to pages; a session template's grant costs that once for
      # each session its principal's domains quota lets live at once, a configured
      # domain's once.
      def check_display_grants(display, tables, facet_values)
        service = tables.fetch('services').fetch(display.fetch('service'))
        server = service.fetch('server')
        invalid("display #{service.fetch('name')} is served by the system domain, not a display domain", 18, 'display.name') if
          server == @codec.constant('mf_none')
        domain = tables.fetch('domains').fetch(server)
        invalid("display #{service.fetch('name')}'s domain sets a key its display record gives it", 18, 'domain.env') if
          domain.fetch('env').split("\0").any? { |word| display_keys.include?(word.partition('=').first) }
        limits = tables.fetch('limits').fetch(domain.fetch('limits'))
        grants = tables.fetch('facets').zip(facet_values).select { |facet, _values| facet.fetch('service') == display.fetch('service') }
        cost = grants.sum do |facet, values|
          invalid("facet #{facet.fetch('name')} grants a display to the system domain, whose connections carry no pixel area", 18,
                  'facet.grantee') if facet.fetch('grantee_kind') == grantee_kind('system')
          invalid("facet #{facet.fetch('name')} sets session, which the domain service alone sets", 18, 'facet.parameter') if
            values.key?('session')
          pixels = values.fetch('pixels') { @codec.constant('windows_pixels_default') }
          grant_instances(facet, tables) * (pages(pixels) + pages(limits.fetch('lane')))
        end
        return if cost <= limits.fetch('outer')

        invalid("display #{service.fetch('name')}'s grants cost #{cost} bytes, past its domain's outer budget of " \
                "#{limits.fetch('outer')}", 18, 'facet.parameter')
      end

      # How many grants a facet row makes at once: one for a domain, and for a session
      # template its principal's domains quota, the sessions of it that can live at once.
      def grant_instances(facet, tables)
        return 1 unless facet.fetch('grantee_kind') == grantee_kind('session')

        principal = tables.fetch('sessions').fetch(facet.fetch('grantee')).fetch('principal')
        tables.fetch('principals').fetch(principal).fetch('domains')
      end

      # Bytes rounded up to whole pages.
      def pages(bytes)
        page = @codec.constant('page_size')
        (bytes + page - 1) / page * page
      end

      # Property 15: the system domain holds no facet of the network domain's net or
      # netadmin interface, compared by number, however the service row spells it. Each
      # grantee of net, a configured domain or a session template, and its server take
      # frames of at least net_max_frame_min bytes under their own runtime limits, since
      # the socket protocol's piece and its envelope arrive in one frame. The manifest is the only
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
        facets_of(facets, 'net', tables).each { |row| check_receiver_floors(row, tables, 'net', { 'max_frame' => floor }, property: 15) }
      end

      # Property 16: every domain that receives the files protocol of a files facet, its
      # grantee (the system domain, a configured domain or a session template) and its
      # server, takes frames of at least files_max_frame_min bytes under its own runtime
      # limits, and the facet's max_request admits a request that long, since a read reply
      # or a write request of the client's 64 KiB transfer unit arrives in one frame, and
      # the funnel drops a longer frame and the facet a longer request.
      def check_files_grants(facets, tables)
        floor = @codec.constant('files_max_frame_min')
        facets_of(facets, 'files', tables).each do |row|
          if row.fetch('max_request') < floor
            invalid("facet #{row.fetch('name')}'s max_request #{row.fetch('max_request')} is below files' floor of #{floor}",
                    16, 'facet.max_request')
          end
          check_receiver_floors(row, tables, 'files', { 'max_frame' => floor }, property: 16)
        end
      end

      # Property 16 for inspect: every grantee of an inspect facet and its server, the
      # system domain, which also takes the runtime agents' answers of the same bound,
      # carry the interface's floor on each of the three limits the funnel applies to a
      # frame, so no receiver's funnel drops a valid answer (docs/design-live.md, "The
      # inspect service"). inspect_funnel_depth_min is computed from the inspection
      # schema (tools/lib/erx/abi_inspection_bounds.rb). Only the system domain serves
      # inspect, since it alone validates and scopes the answers a grantee reads.
      def check_inspect_grants(facets, tables)
        floors = { 'max_frame' => @codec.constant('inspect_max_frame_min'),
                   'max_message_heap' => @codec.constant('inspect_message_heap_min'),
                   'funnel_depth' => @codec.constant('inspect_funnel_depth_min') }
        inspect = fetch_interface('inspect')
        if tables.fetch('services').any? { |row| row.fetch('interface') == inspect && row.fetch('server') != @codec.constant('mf_none') }
          invalid('only the system domain serves the inspect interface', 16, 'service.server')
        end
        facets_of(facets, 'inspect', tables).each { |row| check_receiver_floors(row, tables, 'inspect', floors, property: 16) }
      end

      # The facet rows of the interface abi/services declares as NAME, compared by number.
      def facets_of(facets, name, tables)
        interface = fetch_interface(name)
        facets.select { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('interface') == interface }
      end

      # Refuses, as PROPERTY, a facet whose grantee or server runs a runtime limit below
      # the interface's floor for it (docs/design-domains.md, "Floors from a protocol": a
      # floor binds both receivers). FLOORS maps a runtime_limits field to its floor.
      def check_receiver_floors(row, tables, interface, floors, property:)
        server = tables.fetch('services').fetch(row.fetch('service')).fetch('server')
        server_kind = server == @codec.constant('mf_none') ? grantee_kind('system') : grantee_kind('domain')
        receivers = { 'grantee' => receiver_limits(row.fetch('grantee_kind'), row.fetch('grantee'), tables),
                      'server' => receiver_limits(server_kind, server, tables) }
        receivers.each do |role, limits|
          floors.each do |field, floor|
            next if limits.fetch(field) >= floor

            invalid("facet #{row.fetch('name')}'s #{role} runs with #{field} #{limits.fetch(field)}, " \
                    "below #{interface}'s floor of #{floor}", property, "runtime_limits.#{field}")
          end
        end
      end

      # The runtime limits of a receiver of a protocol: the system domain's, the machine's
      # system runtime limits, or a configured domain's or a session template's.
      def receiver_limits(kind, index, tables)
        runtime_limits = tables.fetch('runtime_limits')
        return runtime_limits.fetch(reference(@source.machine, 'system_runtime_limits', 'runtime_limits')) if
          kind == grantee_kind('system')

        table = kind == grantee_kind('domain') ? 'domains' : 'sessions'
        runtime_limits.fetch(tables.fetch('limits').fetch(tables.fetch(table).fetch(index).fetch('limits')).fetch('runtime_limits'))
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
          'queue' => queue }.merge(%w[max_request in_flight reductions period_ns max_heap_size].to_h { |key| [key, number(record, key)] })
      end

      # What the stopgap cannot honour, refused once properties 2, 10 and 11 hold: a
      # facet that names an operation, which resolves against its service's generated
      # declarations at M5, so the row would grant every operation. Its parameters are
      # resolved (facet_parameters).
      def check_facets_supported
        records('facet').each do |record|
          operations = one(record, 'operations')
          next if !operations.quoted && operations.value == 'none'

          unsupported('a facet resolves its operations against its service\'s generated declarations, which M5 brings', 'facet')
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
      # arithmetic. Then, property 17's planning clause, it plans the sessions the boot
      # starts after them, in the boot's order (planned_sessions): root's console
      # session, and then each enabled start row's. So an enabled row whose principal
      # cannot hold its session beside the configured domains and the sessions before it
      # fails the build, and so does a system principal that cannot hold root's console
      # session. A build passes a planner always; without one, a manifest with no domains
      # and no session to plan is not planned, and any other fails closed.
      def check_plans(bytes, normalized)
        rows = normalized.fetch('tables')
        domains = rows.fetch('domains')
        sessions = planned_sessions(rows, normalized.fetch('header').fetch('system_principal'))
        unless @planner
          return if domains.empty? && sessions.empty?

          raise Unsupported.new('configured domains and sessions need the domain library\'s host planner',
                                property: 12, field: 'planner')
        end

        order = rows.fetch('boot_order').map { |step| step.fetch('domain') }
        statuses = @planner.call(plan_view(bytes, rows, order: order,
                                           templates: sessions.map { |session| session.fetch('template') }))
        invalid("the domain library refuses the manifest's view: #{statuses.fetch('refused').delete_prefix('manifest: ')}", 12, 'view') if statuses.key?('refused')
        order.zip(statuses.fetch('domains')).each do |index, status|
          refuse_plan(status, "configured domain #{domains.fetch(index).fetch('name')}", 'domain')
        end
        rows.fetch('introductions').zip(statuses.fetch('introductions')).each do |row, status|
          names = row.values_at('from', 'to').map { |index| domains.fetch(index).fetch('name') }
          refuse_plan(status, "the introduction of #{names.join(' and ')}", 'introduce')
        end
        sessions.each_with_index do |session, index|
          refuse_plan(statuses.fetch('sessions').fetch(index), session.fetch('what'), session.fetch('field'), property: 17)
        end
      end

      private

      # The sessions the boot starts, in its order, each its template's index in the
      # session table and how a refusal names it. First root's console session, from
      # the system principal's template: the reader requires a console line, which
      # logs root in at boot in a development build and must let root log in in any
      # build, so it is planned whenever that template exists; a system principal with
      # none gives the console no session to count. Then each enabled start row's.
      def planned_sessions(rows, system_principal)
        principals = rows.fetch('principals')
        console = rows.fetch('sessions').each_index.select do |index|
          rows.fetch('sessions').fetch(index).fetch('principal') == system_principal
        end
        console.map { |template| { 'template' => template, 'what' => "the console's session of root", 'field' => 'machine.console' } } +
          enabled_starts(rows).map do |start|
            name = principals.fetch(start.fetch('principal')).fetch('name')
            { 'template' => start.fetch('template'), 'what' => "the session of start row #{name}", 'field' => 'start' }
          end
      end

      # The enabled start rows, in the start table's order, each its principal's index
      # and the index of that principal's session template, which property 17's
      # structural clauses make exist and the session table holds one per principal.
      def enabled_starts(rows)
        enabled = @codec.member('mf_start_flags', 'enabled')
        template = rows.fetch('sessions').each_with_index.to_h { |row, index| [row.fetch('principal'), index] }
        rows.fetch('starts').select { |row| (row.fetch('flags') & enabled) != 0 }.map do |row|
          { 'principal' => row.fetch('principal'), 'template' => template.fetch(row.fetch('principal')) }
        end
      end

      # Refuses the manifest naming what the library refused; status 0 passes.
      def refuse_plan(status, what, field, property: 12)
        return if status.zero?

        name = (@codec.schema.statuses || {}).key(status) || status
        invalid("the domain library refuses #{what} with #{name}", property, field)
      end

      # The planner's view (DomainPlanner#call): the packed manifest, each archive entry
      # with the bytes it will start with, the configured rows in boot order, each
      # introduction's parties their places in it, and the session template of each
      # session to plan, in the order the boot starts them.
      def plan_view(bytes, rows, order:, templates:)
        place = order.each_with_index.to_h
        introductions = rows.fetch('introductions').map do |row|
          { 'a' => place.fetch(row.fetch('from')), 'b' => place.fetch(row.fetch('to')) }
        end
        { 'manifest' => bytes, 'files' => @context.catalog.map { |row| plan_file(row) }, 'order' => order,
          'introductions' => introductions, 'sessions' => templates }
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
