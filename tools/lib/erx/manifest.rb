# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'abi_binary'
require_relative 'build_kind'
require_relative 'device_kinds'
require_relative 'pin_table'
require_relative 'generated_abi'
require_relative 'manifest_frontend'
require_relative 'package_key'
require_relative 'domain_startup'

module Erx
  module Manifest
    # A manifest that asks for what the check does not support, which its message says.
    class Unsupported < Invalid
      def initialize(message, field:) = super("not supported: #{message}", field: field)
    end

    # A deep, frozen copy of the build's context, string keys in sorted order, so nothing
    # the build changes after making the context changes what was checked.
    module Snapshot
      module_function

      def copy(value, depth: 0)
        raise Invalid.new('context nesting exceeds 64', field: 'context.input') if depth > 64
        case value
        when Hash
          unless value.keys.all? { |key| key.is_a?(String) }
            raise Invalid.new('context keys must be strings', field: 'context.input')
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
          raise Invalid.new('context contains an unsupported value', field: 'context.input')
        end
      end
    end

    # Context is supplied by the build's checked artifact/platform boundaries,
    # never read from configuration text. Its catalog includes the reserved
    # manifest and NOTICES rows before any numeric entry index is assigned. Its
    # device_kinds are the rows of erx/device_kinds.h's two tables, each a hash of role,
    # compatible, role_word, peripheral and clocked (DeviceKinds.context_rows). Its
    # development_key is the public half of the builder's development package key, or
    # nil: never a manifest row, so no board source can name it, and the check accepts it
    # only in a development build (docs/design-packaging.md, "The SDK"). Its gatt_services
    # are the names of the services abi/gatt declares (GattDecl.services), which a ble
    # grant's services are drawn from (check_ble_grants).
    class Context
      attr_reader :build_kind, :platform, :catalog, :root_entry, :artifacts,
                  :provenance, :device_kinds, :gatt_services, :development_key

      def initialize(build_kind:, platform:, catalog:, root_entry:, artifacts:,
                     provenance:, device_kinds:, gatt_services:, development_key: nil)
        build_kind = BuildKind.fetch(build_kind)
        unless platform.is_a?(Hash) && catalog.is_a?(Array) && artifacts.is_a?(Hash) &&
               provenance.is_a?(Array) && root_entry.is_a?(Integer) && root_entry.between?(0, catalog.size - 1) &&
               device_kinds.is_a?(Array) && !device_kinds.empty? && device_kinds.all? { |kind| device_kind?(kind) } &&
               gatt_services.is_a?(Array) && gatt_services.all?(String) &&
               artifacts.values.all? { |artifact| started_recorded?(artifact) }
          raise Invalid.new('incomplete checked context', field: 'context.input')
        end
        unless development_key.nil? || (development_key.is_a?(String) && BuildKind.development?(build_kind))
          raise Invalid.new('only a development build trusts a development package key', field: 'context.development_key')
        end
        notices = provenance.map do |record|
          unless record.is_a?(Hash)
            raise Invalid.new('invalid provenance record', field: 'context.provenance')
          end
          normalized = record.reject { |key, _value| key == 'notice' }
          if record.key?('notice')
            notice = record.fetch('notice')
            unless notice.is_a?(String)
              raise Invalid.new('notice must be bytes', field: 'context.provenance')
            end
            normalized = normalized.merge('notice_sha256' => Digest::SHA256.hexdigest(notice))
          end
          normalized
        end
        @build_kind = build_kind
        @platform = Snapshot.copy(platform)
        @catalog = Snapshot.copy(catalog)
        @root_entry = root_entry
        @artifacts = Snapshot.copy(artifacts)
        @provenance = Snapshot.copy(notices)
        @device_kinds = Snapshot.copy(device_kinds)
        @gatt_services = Snapshot.copy(gatt_services)
        @development_key = development_key&.b&.freeze
        validate_catalog_shape
        freeze
      end

      private

      # A kind row's fields, DeviceKinds::Kind's members by name (DeviceKinds.context_rows).
      DEVICE_KIND_FIELDS = DeviceKinds::Kind.members.map(&:to_s).sort.freeze

      def device_kind?(kind)
        kind.is_a?(Hash) && kind.keys.sort == DEVICE_KIND_FIELDS && [true, false].include?(kind['clocked']) &&
          kind.values_at('compatible', 'peripheral', 'role', 'role_word').all?(String)
      end

      # Whether an artifact that is a domain release's boot script records the
      # applications the script starts (ReleaseFiles.domain_artifacts), which property 18
      # reads; an artifact of another kind records none.
      def started_recorded?(artifact)
        !(artifact.is_a?(Hash) && artifact['kind'] == 'release') ||
          (artifact['started'].is_a?(Array) && artifact['started'].all?(String))
      end

      def validate_catalog_shape
        previous = nil
        @catalog.each do |row|
          unless row.is_a?(Hash) && (row.keys - %w[path kind flags source image]).empty? &&
                 row['path'].is_a?(String) && row['kind'].is_a?(Integer) &&
                 row['flags'].is_a?(Integer) && row['source'].is_a?(Hash)
            raise Invalid.new('invalid catalog row', field: 'context.catalog')
          end
          path = row.fetch('path').b
          if previous && previous >= path
            raise Invalid.new('catalog paths must ascend strictly', field: 'context.catalog')
          end
          previous = path
          source = row.fetch('source')
          case source['kind']
          when 'artifact'
            unless source.keys.sort == %w[id kind sha256] && source['id'].is_a?(String) &&
                   source['sha256'].is_a?(String) && source['sha256'].match?(/\A[0-9a-f]{64}\z/)
              raise Invalid.new('invalid artifact identity', field: 'context.catalog.source')
            end
          when 'generated'
            unless source.keys.sort == %w[kind producer] && %w[manifest notices].include?(source['producer'])
              raise Invalid.new('unknown generated artifact', field: 'context.catalog.source')
            end
          when 'directory'
            unless source.keys == %w[kind]
              raise Invalid.new('invalid empty directory', field: 'context.catalog.source')
            end
          else
            raise Invalid.new('unknown catalog origin', field: 'context.catalog.source')
          end
        end
      end
    end


    # The root startup rule on Fiasco: a declared sanity check, not a proof. It compares
    # the manifest's numbers with the platform record's, so a wrong
    # fiasco_reserve shows at boot, when the root's pool falls short.
    module RootStartup
      module_function

      # The platform's declared memory. Without it no rule can be stated, so
      # nothing passes.
      def declared(platform)
        ram, reserve = platform.values_at('ram_bytes', 'fiasco_reserve')
        unless ram.is_a?(Integer) && reserve.is_a?(Integer) && reserve.positive? && reserve < ram
          raise Unsupported.new('the platform record states no RAM size and fiasco_reserve to check root startup against',
                                field: 'root_startup')
        end
        { 'ram_bytes' => ram, 'fiasco_reserve' => reserve }.freeze
      end

      def check(loadable:, baseline:, root_memory:, platform:)
        memory = declared(platform)
        if loadable + baseline > root_memory
          raise Invalid.new("the root's loadable segments and system_baseline exceed root_memory",
                            field: 'root_startup')
        end
        if root_memory > memory.fetch('ram_bytes') - memory.fetch('fiasco_reserve')
          raise Invalid.new('root_memory exceeds RAM less fiasco_reserve', field: 'root_startup')
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
      # memory the manifest declares (dma_memory in the check's report). The estimate
      # errs high by a few hundred KiB (docs/design-fiasco.md, "The root startup
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
                          field: 'root_startup')
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
      # how much of it the manifest's budgets promise (promised_memory in the check's
      # report); and what the boot keeps.
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
                                field: 'root_startup')
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
      # (page_size, fiasco_contig_order_min and fiasco_contig_order_max). The other is
      # liberx's own and copied: sizeof(erx_backend_vm_page_t)
      # (liberx/backend/core/vm_table.h, which vm_table.c asserts).
      PAGE_BYTES = ABI::Generated.constant('page_size')
      PAGE_INDEX_SLOT_BYTES = 16
      CONTIGUOUS_POOL_MIN_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_min')
      CONTIGUOUS_POOL_MAX_BYTES = 1 << ABI::Generated.constant('fiasco_contig_order_max')

      # erx_backend_vm_layout (liberx/backend/core/vm_table.c) sizes the index over the
      # pool's window alone: a table over a run, device registers, the contiguous pool or
      # the archive, takes no entry. The window lies in RAM less fiasco_reserve and the
      # archive, so sizing it over all of those pages never comes out smaller. Its loop doubles from one page of
      # slots to the smallest power of two at least twice the pages covered; the shift
      # finds that power directly.
      def page_index_bytes(pages_free)
        slots = 1 << ((2 * pages_free) - 1).bit_length
        [slots, PAGE_BYTES / PAGE_INDEX_SLOT_BYTES].max * PAGE_INDEX_SLOT_BYTES
      end

      def mib(bytes) = format('%.2f MiB', bytes / 1_048_576.0)
    end

    # Phase 1's manifest check: Check over a manifest with the system domain and
    # its configured domains, and the declared root startup rule. Its constructor is private,
    # so only this factory makes one.
    class Admitted
      attr_reader :bytes, :report

      def self.admit(source:, codec:, context:, planner: nil)
        raise Invalid.new('checked context required', field: 'context.input') unless context.is_a?(Context)
        RootStartup.declared(context.platform)
        parsed = Frontend.parse(source, version: codec.constant('manifest_version'))
        checker = Check.new(parsed, codec: codec, context: context, planner: planner)
        normalized, report = checker.check
        bytes = Encoder.new(codec).encode(normalized)
        codec.open('manifest', bytes)
        checker.check_plans(bytes, normalized)
        new(bytes: bytes, report: report)
      end

      def initialize(bytes:, report:)
        @bytes = bytes.freeze
        @report = Snapshot.copy(report)
        freeze
      end
      private_class_method :new
    end

    def self.admit(source:, codec:, context:, planner: nil)
      Admitted.admit(source: source, codec: codec, context: context, planner: planner)
    end

    # The artifact names the source's domain rows and session templates give as
    # releases, and the app template's (DomainStartup::APP_TEMPLATE) when the source has
    # an apps row, from which the check derives it, sorted and once each, read before any check so a build can make what
    # they name. A reference of another form names nothing here; the check refuses it
    # (Check#artifact).
    def self.release_names(source:, codec:)
      records = Frontend.parse(source, version: codec.constant('manifest_version')).records
      records.values_at('domain', 'session').compact.flatten.filter_map { |record| release_reference(record) }
             .then { |names| records.key?('apps') ? [*names, DomainStartup::APP_TEMPLATE.release] : names }.uniq.sort
    end

    # The <name> of a row's `release @artifact.<name>`, nil for a release of another form.
    def self.release_reference(record)
      word(record, 'release')&.then { |value| value.delete_prefix('@artifact.') if value.start_with?('@artifact.') }
    end

    # A record's field when it is one unquoted token, nil when it is anything else.
    def self.word(record, field)
      tokens = record.properties.fetch(field, [])
      tokens.first.value if tokens.size == 1 && !tokens.first.quoted
    end
    private_class_method :release_reference, :word

    # The manifest check (docs/design-fiasco.md, "The Phase 1 manifest check"): a
    # development manifest, full or partial boot, with the system domain and its
    # configured domains; test fixtures go through it too. A unit's holder or a service's
    # server is the system domain or a configured domain, nothing is reserved for a child,
    # and a grantee is one of those or a session template; a domain row's runtime and
    # release name artifacts of this pack;
    # the configured domains are ordered (10), checked against the rescue configuration
    # (11), planned by the domain library's host build (12) and held to the headroom in
    # system (13). What Phase 1 does not bring is refused here.
    class Check
      TABLES = { 'principal' => 'principals', 'limits' => 'limits',
                 'runtime_limits' => 'runtime_limits', 'lane_class' => 'lane_classes',
                 'image' => 'images', 'domain' => 'domains' }.freeze
      # What a framebuffer row names (docs/design-device-tree.md, "The framebuffer record"):
      # the node whose children the root searches, and the compatible string the one child
      # it takes must carry.
      FRAMEBUFFER_PATH = '/chosen'
      FRAMEBUFFER_COMPATIBLE = 'simple-framebuffer'
      # A device-tree node path as erx_boot_node_path_valid (include/erx/core/boot_handoff.h)
      # has it: '/' and the characters the specification allows in names.
      NODE_PATH = %r{\A/[A-Za-z0-9,._+@/-]*\z}
      # The apps row (docs/design-packaging.md, "The apps row"), its defaults applied:
      # the budget all apps share, the names of the services an app may take, and max,
      # how many apps a boot holds, and gatt, the GATT services apps may handle, which the
      # app template's derived ble row names (docs/design-bluetooth.md, "Who holds
      # `ble`"). Every sum that counts a principal counts max apps,
      # each a principal with a domains quota of one holding every service of services,
      # and adds memory once (property 19's second clause). A manifest without the row
      # has NO_APPS, which takes no packages and adds nothing to any sum, so each sum
      # counts the row the same way whether or not the manifest has one.
      AppsRow = Data.define(:memory, :services, :max, :gatt)
      NO_APPS = AppsRow.new(memory: 0, services: [].freeze, max: 0, gatt: [].freeze)
      # A package row of the image, bound to its package artifact (check_packages): its
      # app's name, its header's SHA-256 in hexadecimal, whether its row is enabled and
      # the memory its declaration asks.
      Package = Data.define(:name, :sha256, :enabled, :memory)
      # The name the machine gives the build's development package key
      # (erx_pkg_header:signer/0), which no signer row may take.
      DEVELOPMENT_SIGNER = 'development'

      REFUSED = {
        'partial_boot' => 'child domains of a partial boot arrive at M5',
        'liveness' => 'the system domain\'s watchdog pets without reading liveness records, which a later milestone brings'
      }.freeze

      # A well-known service any grantee may hold, but whose rows never state rights rx,
      # and why, which completes the refusal "grants NAME rx, whose ...": nothing runs
      # from its tree (abi/services/files.txt, F6).
      NeverRuns = Data.define(:why)

      # Who may hold a granted facet row of a well-known service (check_granted_rows), and
      # why: the system domain, and root's session template, the system principal's,
      # always (root :always) or only in a development build (root :development); with
      # read_only, every such row states rights ro, a row that states none being rw
      # (abi/services/files.txt). why completes the refusal "grants NAME, whose ...".
      SourceGrants = Data.define(:root, :read_only, :why) do
        def initialize(root:, read_only:, why:)
          raise Erx::Error, "SourceGrants root #{root.inspect} is not :always or :development" unless
            %i[always development].include?(root)
          raise Erx::Error, "SourceGrants read_only #{read_only.inspect} is not a boolean" unless [true, false].include?(read_only)

          super
        end
      end

      # A row the build derives of a well-known service: its grantee, :system (the system
      # domain), :app_template or :user_templates (every session template but the app
      # template), and its parameter values.
      Derived = Data.define(:grantee, :values) do
        def initialize(grantee:, values:)
          raise Erx::Error, "Derived grantee #{grantee.inspect} is not one derived_grantees names" unless
            %i[system app_template user_templates].include?(grantee)

          super
        end
      end

      # A service of the files interface that the machine knows by a fixed name, and what
      # the manifest check requires of it beyond what it requires of every service:
      #
      # * constant, the abi/manifest.txt constant that holds its name;
      # * needs, what makes the manifest hold exactly one service of the name, of the
      #   files interface, and the build derive its rows: an apps row (:apps), the name
      #   being served at all (:served), or nothing (nil), when it derives none;
      # * window, the window role whose holder serves it, when one does: a manifest with
      #   that window holds exactly one service of the name, of the files interface,
      #   served by the holder of every window of the role, and one without it holds
      #   none, so an apps row
      #   that needs the service needs the window too;
      # * derived, the Derived rows the build derives of it. An apps row names no service
      #   with an :app_template row, since every app holds that grant already; the apps
      #   row packs the template's packages and system rows in fields of their own
      #   (apps_rows), so a new service with such a row needs a field there too;
      # * source, which granted rows (check_granted_rows) may grant it: :any, :none (only
      #   the derived rows do), a SourceGrants, or a NeverRuns.
      #
      # A row with neither needs nor window is not checked to be of the files interface.
      WellKnown = Data.define(:constant, :needs, :window, :derived, :source) do
        def initialize(constant:, needs:, window:, derived:, source:)
          raise Erx::Error, "WellKnown #{constant} needs #{needs.inspect}" unless [:apps, :served, nil].include?(needs)
          raise Erx::Error, "WellKnown #{constant} source #{source.inspect}" unless
            [:any, :none].include?(source) || source.is_a?(SourceGrants) || source.is_a?(NeverRuns)
          raise Erx::Error, "WellKnown #{constant} derives rows that are not Derived" unless derived.all?(Derived)
          raise Erx::Error, "WellKnown #{constant} derives rows it never needs" unless needs || derived.empty?

          super
        end
      end

      # The well-known services, one row each (docs/design-packaging.md, "The apps row"
      # and "The build's check"; docs/design-files.md, "A user's home";
      # docs/design-ssh.md, "Who publishes it").
      WELL_KNOWN = Ractor.make_shareable([
        # Property 19's first clause and "The apps row": the system domain's grant rw at
        # the tree's root, and the app template's rx, rooted at installed/, where no upload
        # in progress lies: an app's session mounts its installed package at /app through
        # it (design-files.md F6: an rx mount only through an rx grant).
        WellKnown.new(constant: 'packages_service', needs: :apps, window: nil,
                      derived: [Derived.new(grantee: :system, values: { 'rights' => 'rw' }),
                                Derived.new(grantee: :app_template, values: { 'rights' => 'rx', 'tree' => 'installed' })],
                      source: :any),
        # Property 19's eighth clause: served by the system window's holder, the domain
        # whose block driver serves the system partition; the app template's rx grant
        # mounts an image package at /app.
        WellKnown.new(constant: 'system_service', needs: :apps, window: 'system',
                      derived: [Derived.new(grantee: :system, values: { 'rights' => 'ro' }),
                                Derived.new(grantee: :app_template, values: { 'rights' => 'rx' })],
                      source: :none),
        # Property 19's seventh clause: every user's template is granted its user's home.
        WellKnown.new(constant: 'home_service', needs: :served, window: nil,
                      derived: [Derived.new(grantee: :user_templates, values: { 'rights' => 'rw', 'tree' => 'home' })],
                      source: :none),
        # Property 19's tenth clause: a user's one place on the data volume is its home,
        # so a grant that reaches the whole volume is the system domain's, or root's in
        # development.
        WellKnown.new(constant: 'data_service', needs: nil, window: nil, derived: [],
                      source: SourceGrants.new(root: :development, read_only: false,
                                               why: 'grants state no tree and so reach the whole volume')),
        # Property 8's: the system domain and the import of SSH's stage 1 in root's
        # sessions read root's login keys, and nothing writes them (docs/design-ssh.md,
        # "Invariants", H8).
        WellKnown.new(constant: 'login_keys_service', needs: nil, window: 'record_volume', derived: [],
                      source: SourceGrants.new(root: :always, read_only: true, why: 'tree holds root\'s login keys')),
        # Property 8's drive clauses (docs/design-drives.md, "Manifest rows" and "Links and
        # rights"): the media domain, the server of every drive window, serves every
        # drive's volumes, and no grant runs what a drive holds.
        WellKnown.new(constant: 'media_service', needs: nil, window: 'drive', derived: [],
                      source: NeverRuns.new(why: 'volumes are a stranger\'s bytes'))
      ])

      # The interface, and the name, of the facet the domain service grants every session
      # by its own policy, with no facet row (docs/design-system.md, "The code_objects
      # facet"): it serves the facet under its interface's name.
      CODE_OBJECTS = 'code_objects'

      def initialize(source, codec:, context:, planner:)
        @source = source
        @codec = codec
        @context = context
        @planner = planner
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
        unless development == BuildKind.development?(@context.build_kind)
          invalid('configuration conflicts with checked build kind', 'machine.flags')
        end
        partial = (flags & @codec.member('manifest_flags', 'partial_boot')) != 0
        invalid('partial boot requires development mode', 'machine.flags') if partial && !development
        check_mode(development: development, partial: partial)
        @apps = apps_row
        root_private_bytes = check_catalog
        platform_name = text(machine, 'platform')
        invalid('configuration names a different checked platform', 'machine.platform') unless platform_name == @context.platform['name']
        parent_cpus = @context.platform['cpuset']
        unless parent_cpus.is_a?(Integer) && parent_cpus.between?(1, (1 << 64) - 1)
          invalid('checked platform requires a nonempty CPU set', 'context.platform.cpuset')
        end
        system_share = share(machine, 'system_share')
        users_share = share(machine, 'users_share')
        system_cpus, system_rate = effective_share(system_share, parent_cpus)
        users_cpus, users_rate = effective_share(users_share, parent_cpus)
        invalid('system grant has no execution capacity', 'machine.system_share') unless system_rate.positive?
        invalid('system and users exceed the root CPU rate', 'machine.shares') if system_rate + users_rate > population(parent_cpus)
        root_memory = number(machine, 'root_memory')
        baseline = number(machine, 'system_baseline')
        page = @codec.constant('page_size')
        invalid('root memory must be positive and page-aligned', 'machine.root_memory') unless root_memory.positive? && (root_memory % page).zero?
        invalid('system baseline must be positive', 'machine.system_baseline') unless baseline.positive?
        if baseline < root_private_bytes
          invalid('baseline is smaller than the checked private image memory', 'machine.system_baseline')
        end
        rows = @reader.tables.keys.to_h { |name| [name, []] }
        normalize_profiles(rows)
        principals = normalize_principals(rows, users_cpus, users_rate)
        max_domains = number(machine, 'max_domains')
        # Every living domain, configured or requested, is one of its principal's quota,
        # and every app is a principal with a quota of one (property 19's second clause).
        if principals.sum { |row| row.fetch('domains') } + @apps.max > max_domains
          invalid('principal domain quotas and the apps row\'s max exceed max_domains', 'principals.domains')
        end
        normalize_units(rows)
        rows['firmware_requests'] = firmware_requests(rows.fetch('devices'))
        device_memory = rows.fetch('devices').sum { |device| device.fetch('dma_memory') }
        # The Fiasco backend's contiguous pool holds every device's memory at once (RootStartup.contiguous_pool_bytes).
        if device_memory > RootStartup::CONTIGUOUS_POOL_MAX_BYTES
          invalid("device memory exceeds the #{RootStartup::CONTIGUOUS_POOL_MAX_BYTES >> 20} MiB contiguous pool", 'devices.dma_memory')
        end
        # The apps budget is carved from root_memory as a principal's is (property 19).
        promised = principals.sum { |row| row.fetch('memory') } + @apps.memory + baseline + device_memory
        if promised > root_memory
          invalid('principal budgets, the apps budget, system baseline and device memory exceed root memory', 'principals.memory')
        end
        console = text(machine, 'console')
        hostlink = text(machine, 'hostlink')
        check_uarts(rows, console, hostlink)
        unless enum(machine, 'sealing', 'seal') == @codec.member('seal', 'none')
          invalid('no sealing service exists to hold a sealing secret', 'machine.sealing')
        end
        shell = records('shell_principal').map do |record|
          { 'principal' => reference_token(record.properties.fetch('targets').first, 'principal', record.line) }
        end
        invalid('duplicate shell principal', 'shell_principals') unless shell.map { |row| row.fetch('principal') }.uniq.size == shell.size
        rows['shell_principals'] = shell.sort_by { |row| row.fetch('principal') }
        check_and_place(rows, root_memory: root_memory, baseline: baseline)
        check_pin_controller(rows)
        system_principal = reference(machine, 'system_principal', 'principal')
        # The system principal's sessions are root_N (erx_domain_core:session_prefix/3),
        # so a principal named root must be the system principal.
        root = @indices.fetch('principal').fetch('root', system_principal)
        invalid('only the system principal may be named root', 'principal.name') unless root == system_principal
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
          'native_limits' => reference(machine, 'native_limits', 'limits'),
          'boot_timeout_s' => boot_timeout(machine),
          'msi_frame' => msi_frame
        }
        check_lane(header.fetch('system_lane'), 'machine.system_lane')
        %w[system_queue peer_held].each do |key|
          invalid('limit must be positive', "machine.#{key}") unless header.fetch(key).positive?
        end
        report = { 'root_image_private_bytes' => root_private_bytes, 'root_memory' => root_memory,
                   'dma_memory' => device_memory, 'promised_memory' => promised,
                   'effective_system_cpuset' => system_cpus,
                   'effective_users_cpuset' => users_cpus, 'boot_pin_rows' => boot_pin_rows(rows) }.merge(placed_report)
        [{ 'header' => header, 'tables' => rows }, report]
      end

      private

      # The seconds every domain's init has to report ready unless its request sets its
      # own: the machine's boot_timeout_s, or boot_timeout_default_s where the machine
      # states none, from 1 to boot_timeout_max_s, the reader's bound (abi/manifest.txt).
      def boot_timeout(machine)
        seconds = if machine.properties.key?('boot_timeout_s')
                    number(machine, 'boot_timeout_s')
                  else
                    @codec.constant('boot_timeout_default_s')
                  end
        maximum = @codec.constant('boot_timeout_max_s')
        return seconds if seconds.between?(1, maximum)

        invalid("the machine's boot timeout of #{seconds} s is outside 1 to #{maximum} s", 'machine.boot_timeout_s')
      end

      # The platform record's MSI frame, copied whole, or zeros for a platform without
      # one (abi/manifest.txt, erx_mf_msi_frame). Its lines lie below
      # msi_frame_lines_max, the reader's bound.
      def msi_frame
        frame = @context.platform['msi_frame']
        return { 'base' => 0, 'first' => 0, 'count' => 0 } if frame.nil?

        maximum = @codec.constant('msi_frame_lines_max')
        fields = frame.is_a?(Hash) && frame.keys.sort == %w[base count first] ? frame.slice('base', 'first', 'count') : {}
        base, first, count = fields.values_at('base', 'first', 'count')
        return fields if [base, first, count].all?(Integer) && base.between?(1, (1 << 64) - 1) &&
                         !first.negative? && count.positive? && first + count <= maximum

        invalid("the platform's msi_frame needs a base, and lines from first to first + count at most #{maximum}",
                'context.platform.msi_frame')
      end

      def check_mode(development:, partial:)
        unless development
          raise Unsupported.new('a release build needs the confinement check that M11 brings', field: 'machine.flags')
        end
        REFUSED.each { |kind, reason| unsupported(reason, kind) unless records(kind).empty? }
        return unless partial

        invalid('a partial boot configures no domains', 'domain') unless records('domain').empty?
        invalid('a partial boot makes no sessions', 'session') unless records('session').empty?
        invalid('a partial boot starts no row', 'start') unless records('start').empty?
        %w[apps package signer].each do |kind|
          invalid('a partial boot takes no packages', kind) unless records(kind).empty?
        end
        %w[service facet introduce liveness display].each do |kind|
          invalid('a partial boot runs no services', kind) unless records(kind).empty?
        end
        invalid('a partial boot has no domain to hold the system partition', 'system_image') unless records('system_image').empty?
      end

      def check_device(device)
        invalid('no domain holds a TPM until M11', 'devices.role') if device.fetch('role') == device_role('tpm')
        case device.fetch('dma')
        when @codec.member('mf_dma', 'confined')
          unsupported('a confined device needs a DMA window, which M9 brings', 'devices.dma')
        when @codec.member('mf_dma', 'unconfined')
          invalid('an unconfined device needs a memory reservation', 'devices.dma_memory') unless device.fetch('dma_memory').positive?
          # The domain library gives it as one contiguous object.
          if device.fetch('dma_memory') > @codec.constant('mem_contiguous_max')
            invalid('a device memory reservation exceeds mem_contiguous_max', 'devices.dma_memory')
          end
        else
          invalid('non-DMA device has a DMA reservation', 'devices.dma_memory') unless device.fetch('dma_memory').zero?
        end
      end

      def check_and_place(rows, root_memory:, baseline:)
        check_identity(rows.fetch('devices'))
        rows['domains'] = normalize_domains(rows)
        rows['sessions'] = normalize_sessions(rows)
        services = records('service').map { |record| [record, normalize_service(record)] }
                                     .sort_by { |_record, row| [row.fetch('name'), row.fetch('server')] }
        rows['services'] = services.map(&:last)
        invalid('two services of one server share a name', 'service.name') unless
          rows['services'].map { |row| row.values_at('server', 'name') }.uniq.size == services.size
        rows['introductions'] = normalize_introductions
        app_services = check_apps(rows)
        rows['facets'], rows['facet_operations'], rows['facet_parameters'], facet_values =
          normalize_facets(services.map(&:first), rows, app_services)
        rows['pins'] = pins(rows, facet_values)
        rows['starts'] = normalize_starts(services.map(&:first), rows)
        rows['apps'], rows['app_services'] = apps_rows(app_services, rows)
        check_app_start_rows
        rows['signers'] = signer_rows
        rows['development_key'] = @development_key = development_key_rows
        @packages = check_packages
        rows['packages'] = @packages.map { |package| package_row(package) }
        rows['displays'] = normalize_displays(services.map(&:first), rows, facet_values)
        edges = boot_edges(rows['facets'], rows['services'])
        rows['boot_order'] = boot_order(rows['domains'], edges)
        check_rescue(rows['domains'], edges)
        check_facets_supported(rows)
        rows['images'], rows['extents'] = normalize_images(rows.fetch('devices'))
        rows['system_image'] = system_image_rows
        rows['windows'] = normalize_windows(rows)
        check_pcie(rows)
        check_window_services(rows)
        check_drive_domains(rows)
        RootStartup.check(loadable: root_loadable_bytes, baseline: baseline,
                          root_memory: root_memory, platform: @context.platform)
      end

      # The report's numbers of what check_and_place placed: the configured domains,
      # the root image, the packages and the keys the image trusts.
      def placed_report
        { 'child_plan_instances' => records('domain').size,
          'root_image_loadable_bytes' => root_loadable_bytes,
          'packages' => @packages.map { |package| package.to_h.except(:memory).transform_keys(&:to_s) },
          'signers' => records('signer').map(&:name).sort,
          'development_key' => !@development_key.empty? }.merge(RootStartup.declared(@context.platform))
      end

      def invalid(message, field)
        raise Invalid.new(message, field: field)
      end

      def unsupported(message, field)
        raise Unsupported.new(message, field: field)
      end

      def records(kind)
        @source.records.fetch(kind, [])
      end

      # The manifest's apps row, or NO_APPS. Its memory is a whole number of pages, as
      # root_memory is; its max is 1 to apps_max_limit; its services are distinct
      # identifiers, which Check#check_apps resolves against the services, as are its
      # gatt, which check_apps holds to the ble row's bound.
      def apps_row
        record = records('apps').first
        return NO_APPS unless record

        memory = number(record, 'memory')
        invalid('the apps budget must be positive and page-aligned', 'apps.memory') unless
          memory.positive? && (memory % @codec.constant('page_size')).zero?
        max = record.properties.key?('max') ? number(record, 'max') : @codec.constant('apps_max_default')
        limit = @codec.constant('apps_max_limit')
        invalid("max is outside 1 to #{limit}", 'apps.max') unless max.between?(1, limit)
        services, gatt = %w[services gatt].map do |key|
          names = record.properties.fetch(key, []).map do |token|
            record.line.fail!("#{key} requires service names") if token.quoted || !token.value.match?(Frontend::IDENTIFIER)
            token.value
          end
          invalid("#{key} names a service twice", "apps.#{key}") unless names.uniq.size == names.size
          names.freeze
        end
        AppsRow.new(memory: memory, services: services, max: max, gatt: gatt)
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
        invalid('value is outside unsigned 64-bit range', key) unless value.between?(0, (1 << 64) - 1)
        value
      end

      def flags(record, key, type)
        token = one(record, key)
        record.line.fail!('flag list cannot be quoted') if token.quoted
        return 0 if token.value == 'none'
        names = token.value.split(',', -1)
        invalid('duplicate flag', key) unless names.uniq.size == names.size
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
      def holder_index(token, field:)
        return @codec.constant('mf_none') if !token.quoted && token.value == 'system'

        domain_index(token) || invalid('names neither the system domain nor a configured domain', field)
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
            invalid('grant value requires kernel clamping', "share.#{field}")
          end
        end
        unless values.fetch('base') <= values.fetch('ceiling') && values.fetch('ceiling') <= @codec.constant('urgency_max')
          invalid('invalid urgency bounds', 'share.urgency')
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
          values['band'] = enum(record, 'band', 'band')
          spaces = one(record, 'spaces')
          enabled = (values.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          if spaces.value == 'none' && !spaces.quoted
            invalid('enabled sub-spaces need a grant', 'limits.spaces') if enabled
            values['spaces'] = @codec.schema.types.fetch('erx_share').fields.to_h { |field| [field.name, 0] }
          else
            invalid('disabled sub-spaces must have no grant', 'limits.spaces') unless enabled
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
          invalid('principal grant exceeds users', 'principal.grant') if rate > parent_rate
          values = { 'name' => record.name, 'memory' => number(record, 'memory'), 'grant' => grant,
                     'domains' => number(record, 'domains'), 'names' => number(record, 'names'),
                     'default_limits' => reference(record, 'default_limits', 'limits'),
                     'ceiling_limits' => reference(record, 'ceiling_limits', 'limits') }
          pooled = "#{record.name}_#{values.fetch('names')}"
          invalid('name pool exceeds identifier bound', 'principal.names') unless pooled.bytesize <= 63
          defaults = rows.fetch('limits').fetch(values.fetch('default_limits'))
          ceilings = rows.fetch('limits').fetch(values.fetch('ceiling_limits'))
          check_limits(defaults, ceilings, cpus, rate, rows.fetch('runtime_limits'))
          values
        end
        rows['principals'] = result
      end

      def check_limits(defaults, ceilings, cpus, parent_rate, runtime_limits)
        %w[memory outer lane connections crash peer_held peer_held_total].each do |field|
          invalid('default exceeds principal ceiling', "limits.#{field}") if defaults.fetch(field) > ceilings.fetch(field)
        end
        invalid('default flags exceed principal ceiling', 'limits.flags') unless (defaults.fetch('flags') & ~ceilings.fetch('flags')).zero?
        default_cpus, default_rate = effective_share(defaults.fetch('grant'), cpus)
        ceiling_cpus, ceiling_rate = effective_share(ceilings.fetch('grant'), cpus)
        if default_rate > ceiling_rate || ceiling_rate > parent_rate || (default_cpus & ~ceiling_cpus) != 0 ||
           defaults.fetch('grant').fetch('ceiling') > ceilings.fetch('grant').fetch('ceiling')
          invalid('default CPU grant exceeds principal ceiling', 'limits.grant')
        end
        if (defaults.fetch('flags') & @codec.member('mf_limits_flags', 'spaces')) != 0
          _, child_rate = effective_share(defaults.fetch('spaces'), default_cpus)
          invalid('sub-space grant exceeds domain', 'limits.spaces') if child_rate > default_rate
        end
        left = runtime_limits.fetch(defaults.fetch('runtime_limits'))
        right = runtime_limits.fetch(ceilings.fetch('runtime_limits'))
        Frontend::FIELDS.fetch('runtime_limits').each do |field|
          invalid('runtime default exceeds ceiling', "runtime_limits.#{field}") if left.fetch(field) > right.fetch(field)
        end
      end

      def normalize_units(rows)
        units = @context.platform['units']
        invalid('checked platform needs a unit roster', 'context.platform.units') unless units.is_a?(Array)
        by_key = {}
        units.each do |unit|
          unless unit.is_a?(Hash) && unit['key'].is_a?(String) && unit['devices'].is_a?(Array) && !by_key.key?(unit['key'])
            invalid('invalid checked platform unit', 'context.platform.units')
          end
          by_key[unit.fetch('key')] = unit
        end
        placed = []
        roster = by_key.values.flat_map { |unit| unit.fetch('devices') }.map { |device| platform_device(device) }
        bridges = roster.select { |device| pcie_bridge?(device) }.group_by { |device| device.fetch('path') }.transform_values do |rows|
          invalid("the platform record lists two PCIe bridges at #{rows.first.fetch('path')}", 'context.platform.devices') if rows.size > 1
          rows.first
        end
        records('unit').sort_by(&:name).each do |record|
          key = text(record, 'placement')
          unit = by_key[key] || invalid('unit is absent from checked placement', 'unit.placement')
          invalid('unit is assigned more than once', 'unit.placement') if placed.include?(key)
          placed << key
          holder = holder_index(one(record, 'holder'), field: 'unit.holder')
          first = rows.fetch('devices').size
          invalid('platform unit has no devices', 'context.platform.units') if unit.fetch('devices').empty?
          unit.fetch('devices').sort_by { |device| device.fetch('placement_key').b }.each do |device|
            normalized = behind_bridge(platform_device(device), bridges)
            normalized['clock'] = device_clock(normalized)
            normalized['power_off_ms'], normalized['power_on_ms'] = device_power(normalized)
            check_device(normalized)
            places = normalized.fetch('places')
            normalized['places'] = { 'table' => 'places', 'first' => rows.fetch('places').size, 'count' => places.size }
            rows.fetch('places').concat(places)
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
          invalid("a framebuffer row names #{FRAMEBUFFER_PATH} and #{FRAMEBUFFER_COMPATIBLE}", 'context.platform.devices')
        end
        unless device.fetch('dma') == @codec.member('mf_dma', 'none') && device.fetch('line').zero? && device.fetch('flags').zero?
          invalid('a framebuffer row has no DMA, line or flags', 'context.platform.devices')
        end
        page = @codec.constant('page_size')
        return if (device.fetch('base') % page).zero? && (device.fetch('size') % page).zero?

        invalid('a framebuffer window is whole pages', 'context.platform.devices')
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
          invalid('a framebuffer window meets the platform\'s RAM', 'devices.base') if meets_ram?(base, limit)
          devices.each do |device|
            next if device.fetch('role') == framebuffer || device.fetch('selector') != device_tree
            next unless device.fetch('base') < limit && base < device.fetch('base') + device.fetch('size')

            invalid("a framebuffer window meets #{device['path']}'s registers", 'devices.base')
          end
        end
      end

      # Whether [base, limit) meets the RAM the platform record states.
      def meets_ram?(base, limit)
        first, bytes = @context.platform.values_at('ram_first', 'ram_bytes')
        invalid('checked platform needs its RAM', 'context.platform.ram_first') unless
          first.is_a?(Integer) && bytes.is_a?(Integer)
        base < first + bytes && first < limit
      end

      # A platform record's device row as the device table holds it: its selector, role and
      # DMA kind as the codec's numbers, each flags field as its number whether the record
      # writes it so or as a list of its bits' names, flags, DMA memory and DMA limit
      # defaulted to 0, a closed bridge's places checked (bridge_places), and a device-tree
      # row's window and line checked integers (device_window).
      def platform_device(device)
        invalid('invalid checked device row', 'context.platform.devices') unless device.is_a?(Hash)
        normalized = device.dup
        { 'selector' => 'mf_selector', 'role' => 'mf_device_role', 'dma' => 'mf_dma' }.each do |field, type|
          normalized[field] = @codec.member(type, normalized.fetch(field)) if normalized[field].is_a?(String)
        end
        @codec.flags_fields('erx_mf_device').each do |field, type|
          normalized[field] = @codec.flag_value(type, normalized.fetch(field)) if normalized[field].is_a?(Array)
        end
        normalized['flags'] = normalized.fetch('flags', 0)
        normalized['dma_memory'] = normalized.fetch('dma_memory', 0)
        normalized['dma_limit'] = bridge_dma_limit(normalized)
        normalized['places'] = bridge_places(normalized)
        normalized.merge(device_window(normalized))
      end

      def closed?(device) = (device.fetch('flags') & @codec.member('mf_device_flags', 'closed')) != 0

      # A PCIe bridge's DMA limit (docs/design-pcie.md, "DMA"): a CPU address, exclusive,
      # 0 for none, which only a bridge's row states; the packer copies it into each function
      # behind the bridge (behind_bridge).
      def bridge_dma_limit(device)
        limit = device.fetch('dma_limit', 0)
        invalid('a DMA limit is an unsigned 64-bit CPU address', 'context.platform.devices') unless
          limit.is_a?(Integer) && limit.between?(0, (1 << 64) - 1)
        invalid('only a PCIe bridge row states a DMA limit', 'context.platform.devices') unless limit.zero? || pcie_bridge?(device)
        limit
      end

      # The platform record's firmware requests (docs/design-abi.md, "Devices and partition
      # windows"; docs/design-bluetooth.md, "The power line"), in the record's order. A
      # request row is a unique name, the node path of a device of the record's roster, a tag
      # of vc_property.txt's closed set fw_tag and its arguments, as many words as the tag's
      # request: a notify_xhci_reset row names a PCIe bridge, and its one word is one place's
      # address, bus << 20 | device << 15 | function << 12; a set_gpio_state row is refused,
      # since that tag's rows come only from a power row. A power row names a UART device of
      # the roster, which no other row names, a power line of the closed set fw_power_line and
      # its off and on times in milliseconds, which the line service waits; it becomes the
      # device's rows, one per phase of the closed set fw_power_phase at the phase's value,
      # each set_gpio_state with the line's pin and its state in that phase, named after the
      # line (bt_power gives bt_off and bt_on). Every row carries vc_row_words argument words, 0 past the tag's request. A
      # row is packed when the manifest places its device, with that device's row, so its
      # index among its device's rows is the record's; a row of a device the manifest leaves
      # out is not packed, since no request can name it.
      FIRMWARE_REQUEST_FIELDS = %w[arguments device name tag].freeze
      FIRMWARE_POWER_FIELDS = %w[device off_ms on_ms power_line].freeze
      FIRMWARE_FIELD = 'context.platform.firmware_requests'

      def firmware_requests(devices)
        rows = @context.platform.fetch('firmware_requests', [])
        invalid('the platform\'s firmware_requests is not a list', FIRMWARE_FIELD) unless rows.is_a?(Array)
        roster = @context.platform.fetch('units').flat_map { |unit| unit.fetch('devices') }.map { |device| platform_device(device) }
                         .to_h { |device| [device.fetch('path'), device] }
        expanded = rows.flat_map { |row| firmware_rows(row, roster) }
        named = rows.map { |row| row.fetch('device') }
        rows.select { |row| row.key?('power_line') }.each do |row|
          invalid("the power row's device #{row.fetch('device')} is named by another firmware request", FIRMWARE_FIELD) unless
            named.count(row.fetch('device')) == 1
        end
        names = expanded.map { |row| row.fetch('name') }
        invalid('two firmware requests share a name', FIRMWARE_FIELD) unless names.uniq.size == names.size
        tags = @codec.schema.types.fetch('fw_tag').members
        expanded.filter_map do |row|
          device = devices.index { |placed| placed.fetch('path') == row.fetch('device') }
          next unless device

          row.merge('device' => device, 'tag' => tags.fetch(row.fetch('tag')))
        end
      end

      # One record row's rows, each a name, a device path, a tag and vc_row_words argument words.
      def firmware_rows(row, roster)
        invalid('a firmware request is not an object', FIRMWARE_FIELD) unless row.is_a?(Hash)
        case row.keys.sort
        when FIRMWARE_REQUEST_FIELDS then [firmware_request_row(row, roster)]
        when FIRMWARE_POWER_FIELDS then firmware_power_rows(row, roster)
        else invalid("a firmware request is neither a request row (#{FIRMWARE_REQUEST_FIELDS.join(', ')}) " \
                     "nor a power row (#{FIRMWARE_POWER_FIELDS.join(', ')})", FIRMWARE_FIELD)
        end
      end

      def firmware_request_row(row, roster)
        name, path, tag, arguments = row.values_at('name', 'device', 'tag', 'arguments')
        unless name.is_a?(String) && name.match?(Frontend::IDENTIFIER) && arguments.is_a?(Array) &&
               firmware_record_row?(tag, roster[path], arguments)
          invalid('a firmware request is not a name, a tag of fw_tag a record row may name (notify_xhci_reset), ' \
                  "the PCIe bridge of the platform's roster it notifies and the address of one of the bridge's places", FIRMWARE_FIELD)
        end
        { 'name' => name, 'device' => path, 'tag' => tag, 'arguments' => firmware_words(tag, arguments) }
      end

      # Whether a record row may send tag to device with arguments: only notify_xhci_reset, to
      # a PCIe bridge, for one of its places. set_gpio_state's rows come only from a power row,
      # and any other word is no tag of fw_tag.
      def firmware_record_row?(tag, device, arguments)
        case tag
        when 'notify_xhci_reset'
          !device.nil? && pcie_bridge?(device) && arguments.size == firmware_request_words(tag) &&
            place_addresses(device).include?(arguments.first)
        else false
        end
      end

      # A power line's two rows. Its pin word is never 0, so a buffer the firmware left
      # untouched, which keeps the pin, is never read as performed (erx_vc_answer).
      def firmware_power_rows(row, roster)
        line, path, off_ms, on_ms = row.values_at('power_line', 'device', 'off_ms', 'on_ms')
        lines = @codec.schema.types.fetch('fw_power_line').members
        device = roster[path]
        unless lines.key?(line) && device && device.fetch('selector') == @codec.member('mf_selector', 'dt') &&
               device.fetch('role') == device_role('uart') && [off_ms, on_ms].all? { |ms| ms.is_a?(Integer) && ms.positive? }
          invalid("a power row is not a power line of fw_power_line (#{lines.keys.join(', ')}), " \
                  "a UART of the platform's roster and positive off and on times in milliseconds", FIRMWARE_FIELD)
        end
        pin = @codec.constant("vc_#{line}_pin")
        invalid("the power line #{line} has pin word 0, which an untouched buffer would read as performed", FIRMWARE_FIELD) if pin.zero?
        stem = line.delete_suffix('_power')
        # Each phase's row at its value, the index the device service asks for it by.
        phases = @codec.schema.types.fetch('fw_power_phase').members.sort_by { |_phase, value| value }
        unless phases.each_with_index.all? { |(_phase, value), index| value == index }
          invalid("fw_power_phase's values are not 0 and up, so a phase's row cannot sit at its value", FIRMWARE_FIELD)
        end
        phases.map do |state, _value|
          { 'name' => "#{stem}_#{state}", 'device' => path, 'tag' => 'set_gpio_state',
            'arguments' => firmware_words('set_gpio_state', [pin, @codec.constant("vc_#{line}_#{state}")]) }
        end
      end

      # The pin table's rows (abi/manifest.txt, erx_mf_pin; docs/design-pinctrl.md, "What is
      # generated from it"): for each controller entry, each row of a device the manifest
      # places in each of its device's states, spelled out, and each gpio row, in pin order.
      # The firmware's rows and reserved rows give none, so no row names the console's or
      # JTAG's pins, and nor does a device the manifest does not place, which no one uses.
      # An entry with rows to give needs its controller placed, since its holder applies
      # them. A record without a table has none.
      def pins(tables, facet_values)
        table = PinTable.read(@context.platform)
        return [] if table.nil?

        devices = tables.fetch('devices')
        placed = ->(path) { devices.index { |device| device.fetch('path') == path } }
        uses = pin_uses(tables, facet_values)
        table.controllers.flat_map do |entry|
          rows = entry.rows.select { |row| row.owner == :gpio || (row.device? && placed.call(row.use)) }
          next [] if rows.empty?

          controller = placed.call(entry.devices.first) ||
                       invalid("pin controller #{entry.name}'s device #{entry.devices.first} is not placed, so no one " \
                               'would apply its rows', 'context.platform.pins')
          rows.flat_map do |row|
            owner = row.device? ? placed.call(row.use) : @codec.constant('mf_none')
            states = row.device? ? entry.states_of(row.use) : [PinTable::DEFAULT]
            states.map do |state|
              pin_row(entry: entry, row: row, state: state, owner: owner, controller: controller,
                      uses: states.size == 1 && row.device? ? uses.call(owner) : 'none')
            end
          end
        end
      end

      def pin_row(entry:, row:, state:, owner:, controller:, uses:)
        setting = row.setting_in(state) if row.device?
        { 'controller' => entry.name, 'state' => state, 'pin' => row.gpio, 'owner' => owner, 'device' => controller,
          'function' => @codec.member('pin_function', pin_function(setting)), 'alternate' => setting&.alternate || 0,
          'pull' => @codec.member('pin_pull', setting&.pull&.to_s || 'keep'), 'level' => setting&.level || 0,
          'uses' => @codec.member('pin_uses', uses) }
      end

      # Which configurations use a placed device with default alone (docs/design-pinctrl.md,
      # "At start"), by its row: the device is for the configured domain that holds it, for
      # the domain a line grant names it for when the system domain holds it, or else for
      # the system release itself. The system release and the domains marked for rescue run
      # in both configurations, so their devices are rescue's; the others' are normal's.
      def pin_uses(tables, facet_values)
        system = @codec.constant('mf_none')
        rescue_flag = @codec.member('mf_domain_flags', 'rescue')
        line_grantee = tables.fetch('facets').zip(facet_values).filter_map do |facet, given|
          service = tables.fetch('services').fetch(facet.fetch('service'))
          [given.fetch('device'), facet.fetch('grantee')] if grant_checker(service.fetch('interface')) == 'line_grant'
        end.to_h
        lambda do |device|
          holder = unit_holder(tables, tables.fetch('devices').fetch(device).fetch('path'))
          domain = holder == system ? line_grantee.fetch(device, system) : holder
          rescued = domain == system || (tables.fetch('domains').fetch(domain).fetch('flags') & rescue_flag) != 0
          rescued ? 'rescue' : 'normal'
        end
      end

      # How many pins rows the root writes at boot, which the boot's checkpoint expects
      # (ProductionImage::Run.onboard_pins_points): the rows of a controller the system domain
      # holds, of an on-board pin, banks 1 and 2, that set a device's pin to a signal in its
      # default state, as liberx/backend/core/boot_manifest.c's erx_boot_pin_rows takes them.
      def boot_pin_rows(tables)
        alternate = @codec.member('pin_function', 'alternate')
        system = @codec.constant('mf_none')
        tables.fetch('pins').count do |row|
          row.fetch('function') == alternate && row.fetch('state') == PinTable::DEFAULT &&
            row.fetch('pin') >= Pins::BANK0_PIN_COUNT &&
            unit_holder(tables, tables.fetch('devices').fetch(row.fetch('device')).fetch('path')) == system
        end
      end

      def pin_function(setting)
        case setting&.function
        in nil then 'plain'
        in 'in' then 'input'
        in 'out' then 'output'
        in String then 'alternate'
        end
      end

      # The words of a tag's request (abi/formats/vc_property.txt).
      def firmware_request_words(tag) = @codec.constant("vc_#{tag}_request") / 4

      # A row's argument words as the manifest record carries them, vc_row_words of them, 0 past
      # the tag's request; a tag whose request is longer than a row carries is refused.
      def firmware_words(tag, arguments)
        row_words = @codec.constant('vc_row_words')
        invalid("the tag #{tag} has a longer request than a firmware request row carries", FIRMWARE_FIELD) if
          firmware_request_words(tag) > row_words
        Array.new(row_words) { |at| arguments.fetch(at, 0) }
      end

      # The addresses NOTIFY_XHCI_RESET names for a bridge's listed places; none for no bridge.
      def place_addresses(bridge)
        return [] unless bridge

        bridge.fetch('places', []).map { |place| (place.fetch('bus') << 20) | (place.fetch('device') << 15) | (place.fetch('function') << 12) }
      end

      # A closed bridge's listed places (docs/design-pcie.md, "The closed bus"), each spelled
      # in erx_pcie_place's fields: only a PCIe bridge row marked closed lists them, one to
      # pcie_closed_max of them, none twice, each below its root port (bus 1 up), a device
      # and function within the PCI ranges, and a pin INTA (1) to INTD (4). That they lie
      # within the bridge's bus range is the tree's fact, which the boot reads.
      def bridge_places(device)
        places = device.fetch('places', [])
        invalid('a closed bridge lists its places, and only a closed PCIe bridge', 'context.platform.devices') unless
          places.is_a?(Array) && (closed?(device) ? pcie_bridge?(device) && places.size.between?(1, @codec.constant('pcie_closed_max')) : places.empty?)
        places.each do |place|
          unless place.is_a?(Hash) && place.keys.sort == PLACE_FIELDS.sort && place.values.all?(Integer) &&
                 place.fetch('bus').between?(1, 255) && place.fetch('device').between?(0, @codec.constant('pcie_device_max')) &&
                 place.fetch('function').between?(0, @codec.constant('pcie_function_max')) &&
                 place.fetch('pin').between?(1, @codec.constant('pcie_pin_max'))
            invalid("a closed bridge's place is not a bus from 1, a device, a function and a pin from 1 to 4", 'context.platform.devices')
          end
        end
        positions = places.map { |place| place.values_at('bus', 'device', 'function') }
        invalid('a closed bridge lists a place twice', 'context.platform.devices') unless positions.uniq.size == positions.size
        places
      end

      PLACE_FIELDS = %w[bus device function pin].freeze

      # A PCIe function's row as its bridge, a PCIe bridge row of the platform record at its
      # bridge path, completes it (docs/design-pcie.md, "DMA" and "The closed bus"): it takes
      # the bridge's DMA limit, and behind a closed bridge it lies at one of the bridge's
      # listed places and names that place's line, the interrupt id the bridge's
      # interrupt-map routes for its pin, while elsewhere it names no line. Every other row,
      # and a function whose bridge the record lacks, which check_pcie refuses, is unchanged.
      def behind_bridge(device, bridges)
        bridge = bridges[device['bridge']]
        return device if device.fetch('selector') != @codec.member('mf_selector', 'pci') || bridge.nil?

        position = device.values_at('bus', 'device', 'function')
        if closed?(bridge)
          invalid("a PCIe function behind the closed bridge #{bridge.fetch('path')} is at none of its listed places", 'devices.place') unless
            bridge.fetch('places').any? { |place| place.values_at('bus', 'device', 'function') == position }
          invalid("a PCIe function at a closed bridge's place names its place's line", 'context.platform.devices') if device.fetch('line').zero?
        elsif !device.fetch('line').zero?
          invalid("a PCIe function names a line only at a closed bridge's place", 'context.platform.devices')
        end
        device.merge('dma_limit' => bridge.fetch('dma_limit'))
      end

      # A device-tree device's register window and interrupt line, which the platform record
      # must carry (docs/design-abi.md, "Devices and partition windows"); a PCIe function's
      # window comes from configuration space and is zero here, and its line is checked
      # against its bridge (behind_bridge).
      def device_window(device)
        fields = %w[base size line]
        unless device.fetch('selector') == @codec.member('mf_selector', 'dt')
          invalid('a PCIe function carries a window', 'context.platform.devices') if %w[base size].any? { |field| device.fetch(field, 0) != 0 }
          line = device.fetch('line', 0)
          invalid('a PCIe function names its line as an integer', 'context.platform.devices') unless line.is_a?(Integer)
          return { 'base' => 0, 'size' => 0, 'line' => line }
        end

        missing = fields.reject { |field| device[field].is_a?(Integer) }
        invalid("device-tree device lacks #{missing.join(', ')}", 'context.platform.devices') unless missing.empty?
        invalid('device-tree device has an empty window', 'context.platform.devices') if device.fetch('size').zero?
        # Line 0 is no line (docs/design-abi.md, "Devices and partition windows"), so only a
        # row no driver binds a line for carries it: of the ordinary role, which no device
        # kind has, a framebuffer's, or a PCIe bridge's whose node raises none of its own, as
        # QEMU virt's ECAM node does not; a bridge that raises lines, as the BCM2711's, carries
        # its first, which joins its unit (docs/design-platforms.md, "PCIe bridges").
        no_line = %w[ordinary framebuffer configuration].map { |role| device_role(role) }
        if device.fetch('line').zero? && !no_line.include?(device.fetch('role'))
          invalid('a driven device-tree device names no interrupt line', 'context.platform.devices')
        end
        unless device_path?(device['path'])
          invalid("device-tree device's path is not a node path of at most #{@codec.constant('device_path_max')} bytes", 'context.platform.devices')
        end
        device.slice(*fields)
      end

      # A device-tree row's path, which its device record carries as PATH, the device's name
      # to its driver (docs/design-fiasco.md, "Device records"): a node path of at most the
      # ABI's device_path_max bytes, as erx_boot_device_path_valid accepts it.
      def device_path?(path) = path.is_a?(String) && path.match?(NODE_PATH) && path.bytesize <= @codec.constant('device_path_max')

      # The frequency in hertz of the clock a device's driver divides rates from, the first
      # entry of its device-tree node's `clocks` (docs/design-abi.md, "Devices and partition
      # windows"). Whether a driver reads one is a fact of its device's kind, the clocked
      # column of erx/device_kinds.h, and only the board knows the rate, so a row of a clocked
      # kind carries a positive integer and every other row's is 0, absent or written so. The
      # codec holds the value to the row's 32 bits.
      def device_clock(device)
        clock = device.fetch('clock', 0)
        named = "#{device['compatible']} device #{device['path'].inspect}"
        if clocked?(device)
          invalid("#{named} lacks its clock in hertz", 'context.platform.devices') unless clock.is_a?(Integer) && clock.positive?
        else
          invalid("#{named} carries a clock, which no driver of its kind reads", 'context.platform.devices') unless clock == 0
        end
        clock
      end

      # A device row's power line times (docs/design-bluetooth.md, "The power line"): the off
      # and on milliseconds of the power row naming the device, 0 and 0 for a device no power row
      # names. firmware_requests checks the row and refuses a time that is not positive;
      # erx_mf_device's u16 fields bound it, so the codec refuses a time they cannot hold.
      def device_power(device)
        row = Array(@context.platform.fetch('firmware_requests', [])).find do |request|
          request.is_a?(Hash) && request.key?('power_line') && request['device'] == device.fetch('path')
        end
        row ? row.values_at('off_ms', 'on_ms') : [0, 0]
      end

      # Whether device, a normalized platform row, is of a kind whose row carries a clock: a
      # kind of its role and compatible string, as the root and the domain library match them.
      def clocked?(device)
        @context.device_kinds.any? do |kind|
          kind.fetch('clocked') && kind.fetch('compatible') == device['compatible'] &&
            @codec.member('mf_device_role', kind.fetch('role')) == device['role']
        end
      end

      def check_uarts(rows, console, hostlink)
        invalid('console and host link must differ', 'machine.hostlink') if !hostlink.empty? && hostlink == console
        paths = rows.fetch('devices').select do |device|
          device.fetch('selector') == @codec.member('mf_selector', 'dt') && device.fetch('role') == @codec.member('mf_device_role', 'uart')
        end.map { |device| device.fetch('path') }
        [console, hostlink].reject(&:empty?).each do |path|
          field = path == console ? 'machine.console' : 'machine.hostlink'
          invalid('UART is not placed', field) unless paths.include?(path)
          invalid('UART is not assigned to the system domain', field) unless unit_holder(rows, path) == @codec.constant('mf_none')
        end
        check_console_kind(rows, console)
        unless @context.platform['console'] == console && (@context.platform.fetch('hostlink', '') == hostlink)
          invalid('UART paths disagree with checked platform', 'machine.console')
        end
        check_uart_lines(rows, console, hostlink.empty? ? {} : { hostlink => 'machine.hostlink' })
      end

      # Property 8's pin controller clause (docs/design-header-io.md, "The pin controller and
      # the console"): whoever holds the pin controller's register page sets the function of
      # every pin, the console's and host link's among them, which every pin table gives rows
      # (PinTable's driven-rows rule), so a unit with a device-tree row on that page is held by
      # the system domain or by a domain of its own, which no manifest row names but those
      # units, the services of the interfaces they back and the boot order (pin_domain_row?);
      # an unplaced unit has no row. A session
      # template holds nothing, since holder_index resolves every holder through the domain
      # table. The units are found by the page, not by the controller's path, so a second row
      # on the page under another path is caught too. A record without a pin table states no
      # pin, and the clause is empty. It runs once every row is placed, so it sees each one that names the
      # holder.
      def check_pin_controller(rows)
        PinTable.read(@context.platform)&.controllers&.each do |entry|
          entry.devices.each { |controller| check_pin_controller_unit(rows, controller) }
        end
      end

      # The clause for one device of a pin controller entry.
      def check_pin_controller_unit(rows, controller)
        device_tree = @codec.member('mf_selector', 'dt')
        row = platform_device(record_device(controller))
        invalid("pin controller #{controller.inspect} is no device-tree row", 'context.platform.pins') unless
          row.fetch('selector') == device_tree
        page = register_pages(row)
        controlling = lambda do |unit|
          unit_devices(rows.fetch('devices'), unit).any? do |device|
            pages = register_pages(device)
            device.fetch('selector') == device_tree && pages.begin < page.end && page.begin < pages.end
          end
        end
        rows.fetch('units').select(&controlling).each do |unit|
          holder = unit.fetch('holder')
          next if holder == @codec.constant('mf_none')

          table, other = domain_references(rows, holder).find { |name, row| !pin_domain_row?(name, row, controlling) }
          next if other.nil?

          domain = @indices.fetch('domain').key(holder)
          invalid("unit #{unit.fetch('name')} reaches pin controller #{controller}'s registers, which set the console's " \
                  "and host link's pins, so its holder domain #{domain} is a domain of its own, but a row of #{table}" \
                  "#{" (#{other.fetch('name')})" if other.key?('name')} names it", 'unit.holder')
        end
      end

      # The interfaces whose trees the pin controller's units back (docs/design-header-io.md,
      # "Holding and granting": each tree is a service of its holder), resolved against
      # abi/services, which declares them once run-time GPIO is built.
      PIN_CONTROLLER_INTERFACES = %w[gpio].freeze

      # Whether a row naming the pin controller's holder is one the clause accepts: a unit
      # on the controller's page, a service of an interface those units back, or the boot
      # order, which names every domain. Facets of those services name the service, not
      # the holder, so grants to other domains pass without a row here.
      def pin_domain_row?(table, row, controlling)
        case table
        when 'units' then controlling.call(row)
        when 'services' then pin_controller_interfaces.include?(row.fetch('interface'))
        when 'boot_order' then true
        else false
        end
      end

      # PIN_CONTROLLER_INTERFACES' numbers, of those abi/services declares.
      def pin_controller_interfaces = PIN_CONTROLLER_INTERFACES.filter_map { |name| find_interface(name) }

      # An interface's number, or nil when abi/services declares none of that name.
      def find_interface(name) = @codec.schema.services.find { |service| service.fetch(:name) == name }&.fetch(:number)

      # Every row that names the domain at index, as [table, row] pairs. The manifest
      # reader's index rules into the domains table (abi/manifest.txt) list each field that
      # holds a domain, with the tag that makes it one, so a field the ABI adds is scanned
      # without an edit here, and a clause that accepts only some rows refuses a new one.
      def domain_references(rows, index)
        @reader.rules.select { |rule| rule.fetch(:kind) == 'index' && rule.fetch(:table) == 'domains' }.flat_map do |rule|
          path = rule.fetch(:path)
          guard = rule[:guard]
          rows.fetch(path.scope).select do |row|
            row.dig(*path.fields) == index && (guard.nil? || row.dig(*guard.fetch(:tag).fields) == guard.fetch(:value))
          end.map { |row| [path.scope, row] }
        end
      end

      # The checked platform's device row at path, placed or not.
      def record_device(path)
        @context.platform.fetch('units').flat_map { |unit| unit.fetch('devices') }.find { |device| device['path'] == path } ||
          invalid("pin controller #{path} is no device of the checked platform", 'context.platform.pins')
      end

      # The whole pages a normalized row's register window [base, base + size) lies in, as a
      # half-open range.
      def register_pages(device)
        size = @codec.constant('page_size')
        first = device.fetch('base') / size * size
        first...((device.fetch('base') + device.fetch('size') + size - 1) / size * size)
      end

      # The rows of unit's devices.
      def unit_devices(devices, unit)
        span = unit.fetch('devices')
        devices.slice(span.fetch('first'), span.fetch('count'))
      end

      # The console's record names the PERIPHERAL of its UART's row of erx/device_kinds.h's
      # erx_uart_kinds, and a UART of no row gets no record, so its console would start no
      # driver. The console is a placed UART (check_uarts).
      def check_console_kind(rows, console)
        return if console.empty?

        compatible = rows.fetch('devices').find { |device| device['path'] == console }.fetch('compatible')
        return if @context.device_kinds.any? { |kind| kind.fetch('role') == 'uart' && kind.fetch('compatible') == compatible }

        invalid("console UART #{console} is #{compatible}, which no UART kind of #{DeviceKinds::SOURCE} names",
                'machine.console')
      end

      # Property 8's interrupt-line clause (docs/design-shared-devices.md, "Lines inside a
      # domain"): the console starts its own UART's driver, and the owner of its line when
      # the line is shared, and a line has one binder, so no other UART, the host link's or
      # a line grant's, of others by path with the field that names it, is on the console's
      # line; those UARTs may share lines with each other. Every UART here is a placed
      # device-tree device (check_uarts, parameter_value).
      def check_uart_lines(rows, console, others)
        return if console.empty?

        line_of = ->(path) { rows.fetch('devices').find { |device| device['path'] == path }.fetch('line') }
        others.each do |path, field|
          next unless line_of.call(path) == line_of.call(console)

          invalid("console #{console} and UART #{path} share interrupt line #{line_of.call(console)}", field)
        end
      end

      # The holder of the unit whose devices include the device at path.
      def unit_holder(rows, path)
        rows.fetch('units').find do |unit|
          unit_devices(rows.fetch('devices'), unit).any? { |device| device['path'] == path }
        end.fetch('holder')
      end

      def check_lane(value, field)
        unless value.between?(@codec.constant('lane_min'), @codec.constant('lane_max')) && (value & (value - 1)).zero?
          invalid('lane must be a bounded power of two', field)
        end
      end

      def check_catalog
        path = @codec.fixed_bytes('system_manifest_path')
        entries = @context.catalog.select { |row| row.fetch('path') == path }
        unless entries.size == 1 && entries.first.fetch('kind') == @codec.member('entry_kind', 'file') &&
               entries.first.fetch('flags') == @codec.member('entry_flags', 'system') &&
               entries.first.fetch('source') == { 'kind' => 'generated', 'producer' => 'manifest' }
          invalid('reserved manifest path must have its generated system-file row', 'catalog.manifest')
        end
        root = @context.catalog.fetch(@context.root_entry)
        unless root.fetch('kind') == @codec.member('entry_kind', 'image') &&
               (root.fetch('flags') & @codec.member('entry_flags', 'system')) != 0 && root['image'].is_a?(Hash)
          invalid('root is not a system executable', 'catalog.root')
        end
        image = root.fetch('image')
        unless image['magic'] == @codec.constant('image_magic') && image['version'] == @codec.constant('image_version') &&
               image['abi_version'] == @codec.abi_version &&
               image['flags'].is_a?(Integer) && (image.fetch('flags') & @codec.member('image_flags', 'jit')).zero?
          invalid('root image has incompatible ABI or JIT authority', 'catalog.root')
        end
        @codec.encode_layout('erx_image_manifest', image)
        page = @codec.constant('page_size')
        image.fetch('segments').sum do |segment|
          if segment.fetch('prot') == @codec.member('prot', 'rw')
            bytes = segment.fetch('mem_size')
            invalid('root writable segment exceeds its bound', 'catalog.root') if bytes > @codec.constant('image_writable_max')
            ((bytes + page - 1) / page) * page
          else
            0
          end
        end
      end

      def check_identity(devices)
        invalid('host name is not a system identifier', 'machine.host') unless text(@source.machine, 'host').match?(Frontend::IDENTIFIER)
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

      # Property 1: a device is one unit's, a device-tree device named by its path and a
      # PCIe function by its place, its bridge, bus, device and function.
      def check_one_holder(devices)
        tree, functions = devices.partition { |device| device.fetch('selector') == @codec.member('mf_selector', 'dt') }
        { 'devices.path' => tree.map { |device| device.fetch('path') },
          'devices.place' => functions.map { |device| device.values_at('bridge', 'bus', 'device', 'function') } }.each do |field, names|
          invalid('a device appears in more than one unit', field) unless names.uniq.size == names.size
        end
      end

      def check_no_sealed_entry
        seal = @codec.member('entry_flags', 'seal')
        return if @context.catalog.none? { |row| (row.fetch('flags') & seal) != 0 }
        invalid('no entry carries the sealing secret until the vault at M11', 'catalog.flags')
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
          invalid('a configured domain\'s name has a pooled name\'s form', 'domain.name') if pooled&.[](:stem)&.match?(Frontend::IDENTIFIER)
          invalid('a configured domain shares a principal\'s name', 'domain.name') if principals.include?(record.name)
          invalid('the system domain\'s name is not a configured domain\'s', 'domain.name') if record.name == 'system'
          args = boot_args(record, field: 'domain.args')
          strings = args.bytesize + words(record, 'env').bytesize
          invalid('arguments and environment exceed the boot page\'s strings', 'domain.args') if
            strings > @codec.constant('boot_strings_max')
          kind = enum(record, 'kind', 'mf_kind')
          invalid('no secret domain until the vault at M11', 'domain.kind') unless kind == @codec.member('mf_kind', 'service')
          runtime = artifact(record, 'runtime', 'executable', field: 'domain.runtime')
          release = artifact(record, 'release', 'release', field: 'domain.release')
          { 'name' => record.name, 'principal' => reference(record, 'principal', 'principal'), 'kind' => kind,
            'flags' => flags(record, 'flags', 'mf_domain_flags'), 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'limits' => reference(record, 'limits', 'limits'), 'restarts' => number(record, 'restarts'),
            'restart_period_s' => number(record, 'restart_period_s'),
            'args' => args, 'env' => words(record, 'env') }
        end
      end

      # Property 14: each session template, keyed by its principal, from which the
      # domain service makes every session of that principal on request
      # (docs/design-system.md, "The manifest"). A template is not a domain row,
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
        templates = records('session').map do |record|
          principal = @indices.fetch('principal')[record.name] ||
                      invalid('a session template names no principal', 'session.name')
          limits = reference(record, 'limits', 'limits')
          invalid('a session template\'s limits do not enable SPACES', 'session.limits') if
            (rows.fetch('limits').fetch(limits).fetch('flags') & spaces).zero?
          args = boot_args(record, field: 'session.args')
          invalid('arguments and environment exceed the boot page\'s strings', 'session.args') if
            args.bytesize + words(record, 'env').bytesize > @codec.constant('boot_strings_max')
          runtime = artifact(record, 'runtime', 'executable', field: 'session.runtime')
          release = artifact(record, 'release', 'release', field: 'session.release')
          { 'principal' => principal, 'limits' => limits, 'runtime' => runtime.fetch('entry'),
            'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
            'args' => args, 'env' => words(record, 'env') }
        end.sort_by { |row| row.fetch('principal') }
        @apps == NO_APPS ? templates : [*templates, app_template(rows)]
      end

      # The app template (docs/design-packaging.md, "The apps row"), derived from the
      # apps row and DomainStartup::APP_TEMPLATE, never from a source row: it names no
      # principal, so it sorts last and no source facet's @session.NAME reaches it, and
      # its limits are the manifest's `limits session` record, a session's defaults,
      # which must enable SPACES as every template's do.
      def app_template(rows)
        recipe = DomainStartup::APP_TEMPLATE
        limits = @indices.fetch('limits')['session'] ||
                 invalid('the apps row needs the limits session record its template takes', 'apps')
        invalid('the limits session record the app template takes does not enable SPACES', 'apps') if
          (rows.fetch('limits').fetch(limits).fetch('flags') & @codec.member('mf_limits_flags', 'spaces')).zero?
        runtime = named_artifact(recipe.runtime, 'executable', field: 'apps')
        release = named_artifact(recipe.release, 'release', field: 'apps')
        { 'principal' => @codec.constant('mf_none'), 'limits' => limits, 'runtime' => runtime.fetch('entry'),
          'release' => release.fetch('entry'), 'release_files' => release.fetch('files'),
          'args' => boot_page_args(recipe.args.split(' '), recipe.release), 'env' => recipe.env.b }
      end

      # Whether a facet row is granted to the app template.
      def app_template?(facet, tables)
        facet.fetch('grantee_kind') == grantee_kind('session') &&
          app_session?(tables.fetch('sessions').fetch(facet.fetch('grantee')))
      end

      # Whether a session row is the app template, the one naming no principal.
      def app_session?(session) = session.fetch('principal') == @codec.constant('mf_none')

      # The app template's index among the sessions, nil in a manifest without one.
      def app_template_index(tables) = tables.fetch('sessions').index { |session| app_session?(session) }

      # A domain row's or session template's arguments as its boot page holds them: its
      # emulator flags (the words before the first --), then -- -boot /bin/<name> --,
      # then its init arguments (the words after that --). /bin/<name> is the boot
      # script of the domain release that its `release @artifact.<name>` names
      # (docs/design-fiasco.md, "The production image"). The binding is init's first
      # flag and the second -- closes its value, so no later word (-extra, a final -S)
      # can make it a plain argument and leave init to its default script. Its own
      # arguments naming -boot are refused, since its release names the script.
      # erx_domain_srv:boot_args/2 binds a created domain's the same way.
      def boot_args(record, field:)
        args = words(record, 'args').split("\0")
        invalid('the arguments name -boot, which the release sets', field) if args.include?('-boot')
        boot_page_args(args, release_name(record, field: field.sub('args', 'release')))
      end

      # A word list bound to the boot script of the release named name, as boot_args
      # describes.
      def boot_page_args(args, name)
        emulator, init = args.index('--').then { |at| at ? [args[0...at], args[at + 1..]] : [args, []] }
        [*emulator, '--', '-boot', "/bin/#{name}", '--', *init].map { |word| "#{word}\0" }.join.b
      end

      # The <name> of a record's `release @artifact.<name>`, once artifact has checked that
      # it names a release.
      def release_name(record, field:)
        artifact(record, 'release', 'release', field: field)
        one(record, 'release').value.delete_prefix('@artifact.')
      end

      # The artifact a record's key names, of the kind the packer recorded for it.
      def artifact(record, key, kind, field:)
        token = one(record, key)
        named = !token.quoted && token.value.start_with?('@artifact.')
        artifact = named ? @context.artifacts[token.value.delete_prefix('@artifact.')] : nil
        invalid("#{key} names no #{kind} artifact of this pack", field) unless artifact.is_a?(Hash) && artifact['kind'] == kind
        artifact
      end

      # The artifact of this pack named name, of the kind the packer recorded for it.
      def named_artifact(name, kind, field:)
        artifact = @context.artifacts[name]
        invalid("no #{kind} artifact #{name} in this pack", field) unless artifact.is_a?(Hash) && artifact['kind'] == kind
        artifact
      end

      def normalize_service(record)
        name = service_name(record)
        invalid('service name is not a system identifier', 'service.name') unless name.match?(Frontend::IDENTIFIER)
        { 'name' => name, 'server' => holder_index(one(record, 'server'), field: 'service.server'),
          'interface' => interface_number(record) }
      end

      # A service's interface number: the name of an interface abi/services declares, as
      # design-abi.md writes it, or a number, which the check also takes for an
      # interface no fragment declares yet. The row holds the number either way, so a
      # check that reasons from a declared interface (property 8's driver control) sees
      # both spellings.
      def interface_number(record)
        token = one(record, 'interface')
        return number(record, 'interface') if token.quoted || token.value.match?(/\A[0-9]/)

        find_interface(token.value) || record.line.fail!('interface names no service abi/services declares')
      end

      # An interface a check reasons from, which the ABI must declare.
      def fetch_interface(name) = find_interface(name) || raise(Erx::Error, "abi/services declares no interface #{name}")

      # The services an app may never take, whatever the apps row says, by name
      # (docs/design-packaging.md, "The build's check", property 19's first clause): the
      # well-known services the build derives the app template a row of, which every app
      # holds already, and those that
      # would let an app command the start table, install packages, rewrite
      # the start table's settings or end the machine.
      def app_services_refused
        held = WELL_KNOWN.select { |known| known.derived.any? { |grant| grant.grantee == :app_template } }
        held.to_h { |known| [@codec.fixed_bytes(known.constant), 'every app holds its grant already, which the build derives'] }.merge(
          'start'.b => 'it would let an app command the start table',
          'apps'.b => 'it would let an app install packages',
          'etc'.b => 'it would let an app rewrite /etc/rc.conf',
          'machine'.b => 'it would let an app end the machine')
      end

      # Property 19's first and seventh clauses; answers the index of each service of the
      # apps row's services, the services the board's sums count max apps holding. No
      # source facet carries a tree, which only a derived row may. Each name is the
      # name of exactly one service of the manifest, none of app_services_refused, of an
      # interface an ABI file declares, which gives every parameter a default (an optional
      # parameter), since an app's row is granted with no parameter stated, and every
      # quantity (derived_quantities). A service of the inspect interface is refused until
      # the scope an app principal gets is checked to be its own, never all, and one of
      # the files interface until the storage service's `tree apps` roots its grant at
      # the app's own directory, by interface, whatever its name.
      def check_apps(tables)
        invalid('a facet of the source carries a tree, which only the rows the build derives may', 'facet.parameter') if
          records('facet').any? { |record| record.parameters.any? { |key, _value| key.value == 'tree' } }
        service_rows = tables.fetch('services')
        refused = app_services_refused
        indices = @apps.services.map do |name|
          reason = refused[name.b]
          invalid("services names #{name}: #{reason}", 'apps.services') if reason
          matching = service_rows.each_index.select { |index| service_rows.fetch(index).fetch('name') == name.b }
          invalid("services names #{name}, which is not the name of one service of the manifest", 'apps.services') unless
            matching.size == 1
          interface = service_rows.fetch(matching.first).fetch('interface')
          unsupported("services names #{name}, of the inspect interface, whose scope for an app is not checked", 'apps.services') if
            interface == fetch_interface('inspect')
          unsupported("services names #{name}, of the files interface, whose grant no tree apps roots yet", 'apps.services') if
            interface == fetch_interface('files')
          declared = declared_parameters(interface) ||
                     invalid("services names #{name}, whose interface no ABI file declares", 'apps.services')
          required = declared.select { |_key, parameter| parameter.fetch(:cardinality) == 'one' }.keys
          invalid("services names #{name}, whose interface gives #{required.join(', ')} no default", 'apps.services') unless
            required.empty?
          derived_quantities(interface, name)
          matching.first
        end
        check_apps_gatt(indices.any? { |index| ble_service?(service_rows.fetch(index)) })
        indices.freeze
      end

      # Property 19's first clause on gatt (docs/design-packaging.md, "The build's
      # check"): stated exactly when services names the ble service, offered, so no row
      # offers apps a ble grant that names nothing and no gatt is written that no row
      # carries; and within the ble interface's services count, which the app template's
      # derived row takes from it (app_service_facets) without resolve_parameters, which
      # holds a source row's set to it. apps_row holds each name to an identifier, within
      # the parameter's 63 bytes, and ble_grant judges the names as any ble row's.
      def check_apps_gatt(offered)
        invalid('services names ble, so the row states gatt, the services apps may handle', 'apps.gatt') if
          offered && @apps.gatt.empty?
        invalid('gatt is stated, so services names ble, whose grant carries it', 'apps.gatt') if !offered && @apps.gatt.any?
        return unless offered

        parameter = declared_parameters(fetch_interface('ble')).fetch('services')
        invalid("gatt names over #{parameter.fetch(:maximum_count)} services", 'apps.gatt') if
          @apps.gatt.size > parameter.fetch(:maximum_count)
      end

      # Whether a service row is of the ble interface, which ble_grant holds to the one
      # service named ble.
      def ble_service?(service_row) = service_row.fetch('interface') == fetch_interface('ble')

      # The quantities of a facet row the build derives for a service of interface: those
      # its ABI file's quantity lines give (docs/design-abi.md, "Services, facets and their
      # parameter schemas"), every one of them required, and queue, which resolves to
      # system_queue as a source row's does when it states none.
      def derived_quantities(interface, name)
        declared = @codec.schema.services.find { |service| service.fetch(:number) == interface }&.fetch(:quantities) || {}
        missing = ABI::Contracts::FACET_QUANTITIES - declared.keys
        invalid("services names #{name}, whose interface declares no #{missing.join(', ')}", 'apps.services') unless
          missing.empty?
        declared.merge('queue' => number(@source.machine, 'system_queue'))
      end

      # The well-known services' derived rows (docs/design-packaging.md, "The apps row";
      # docs/design-files.md, "A user's home"): those of each service whose needs call
      # for them, in WELL_KNOWN's order. Each is named as its service is and takes
      # derived_quantities. Answers each row with its resolved parameter values, as
      # normalize_facets builds a source row's.
      def well_known_facets(tables)
        service_rows = tables.fetch('services')
        WELL_KNOWN.select { |known| derives?(known, service_rows) }.flat_map do |known|
          required_by = known.needs == :apps ? 'an apps row' : "a #{name_of(known)} service"
          service = fetch_well_known(service_rows, known, required_by: required_by)
          known.derived.flat_map do |grant|
            derived_grantees(grant.grantee, tables).map { |grantee| derived_facet(service_rows, grantee, service, grant.values) }
          end
        end
      end

      # The rows an apps row asks for (docs/design-packaging.md, "The apps row"): the app
      # template's grant of each service of app_services, which states no parameter but
      # the ble service's, whose services are the apps row's gatt, sorted as a set's
      # values are (pack_parameters); none without an apps row. Answers each row as
      # well_known_facets does.
      def app_service_facets(tables, app_services)
        return [] if @apps == NO_APPS

        service_rows = tables.fetch('services')
        template = [grantee_kind('session'), app_template_index(tables)]
        app_services.map do |service|
          values = ble_service?(service_rows.fetch(service)) ? { 'services' => @apps.gatt.map(&:b).sort.freeze } : {}
          derived_facet(service_rows, template, service, values)
        end
      end

      # Whether the build derives the rows of the well-known service known, and the
      # manifest must hold it: with an apps row, for one an apps row needs, and whenever
      # it is served, for one its being served needs.
      def derives?(known, service_rows)
        case known.needs
        in :apps then @apps != NO_APPS
        in :served then service_rows.any? { |service| service.fetch('name') == name_of(known) }
        in nil then false
        end
      end

      # The grantees, each [kind, index], that a derived row's grantee names.
      def derived_grantees(grantee, tables)
        sessions = tables.fetch('sessions')
        case grantee
        in :system then [[grantee_kind('system'), 0]]
        in :app_template then [[grantee_kind('session'), app_template_index(tables)]]
        in :user_templates
          sessions.each_index.reject { |template| app_session?(sessions.fetch(template)) }
                  .map { |template| [grantee_kind('session'), template] }
        end
      end

      # The name of the well-known service known, its machine constant's bytes.
      def name_of(known) = @codec.fixed_bytes(known.constant)

      # The well-known services' source clauses, over granted: every facet row but the
      # well-known services' own derived rows, that is the board's source rows and the
      # rows an apps row asks for. Each row of a well-known service meets that service's
      # source rule (check_granted_row). values holds each row's resolved parameter
      # values, in granted's order.
      def check_granted_rows(granted, values, tables)
        service_rows = tables.fetch('services')
        WELL_KNOWN.each do |known|
          granted.zip(values).each do |row, stated|
            check_granted_row(known, row, stated, tables) if service_rows.fetch(row.fetch('service')).fetch('name') == name_of(known)
          end
        end
      end

      # One granted row of the well-known service known, with its resolved parameter
      # values: refused for a service whose rows only the build derives, and for one with
      # SourceGrants unless its grantee is the system domain or a template its root
      # setting accepts and, for a read_only one, it states ro, and for one with NeverRuns
      # when it states rx.
      def check_granted_row(known, row, stated, tables)
        name = name_of(known)
        case known.source
        in :any then nil
        in :none
          invalid("facet #{row.fetch('name')} grants the #{name} service: only the derived #{name} rows do", 'facet.service')
        in SourceGrants(root:, read_only:, why:)
          grantee = row.values_at('grantee_kind', 'grantee')
          root_may, holders = case root
                              in :always then [root_template?(*grantee, tables), "the system domain or root's session template"]
                              in :development
                                [development_root?(*grantee, tables),
                                 "the system domain or, in a development manifest, root's session template"]
                              end
          invalid("facet #{row.fetch('name')} grants #{name}, whose #{why}, to another grantee than #{holders}", 'facet.grantee') unless grantee.first == grantee_kind('system') || root_may
          invalid("facet #{row.fetch('name')} grants #{name} other than read-only", 'facet.parameter') if
            read_only && stated.fetch('rights', 'rw') != 'ro'
        in NeverRuns(why:)
          invalid("facet #{row.fetch('name')} grants #{name} rx, whose #{why}", 'facet.parameter') if
            stated.fetch('rights', 'rw') == 'rx'
        end
      end

      # One row the build derives: the grant of service to grantee, [kind, index], named
      # as its service is, with no operation and derived_quantities, paired with its
      # parameter values.
      def derived_facet(service_rows, (kind, grantee), service, values)
        row = service_rows.fetch(service)
        facet = { 'name' => row.fetch('name'), 'grantee_kind' => kind, 'grantee' => grantee, 'service' => service,
                  'operations' => { 'table' => 'facet_operations', 'first' => 0, 'count' => 0 },
                  **derived_quantities(row.fetch('interface'), row.fetch('name')) }
        [facet, values.freeze]
      end

      # The index of the one service named as the well-known service known is, of the
      # files interface, which a manifest holds when known's needs or window call for it,
      # required_by naming which, or known's property refuses it.
      def fetch_well_known(service_rows, known, required_by:)
        name = name_of(known)
        named = service_rows.each_index.select { |index| service_rows.fetch(index).fetch('name') == name }
        invalid("a manifest with #{required_by} holds one service named #{name}", 'service.name') unless
          named.size == 1
        invalid("the service named #{name} is of the files interface", 'service.interface') unless
          service_rows.fetch(named.first).fetch('interface') == fetch_interface('files')
        named.first
      end

      # The well-known services' window clauses, those of property 19's eighth and of
      # docs/design-ssh.md, "Who publishes it": for each service with a window, a manifest
      # with the window holds exactly one service of its name, of the files interface,
      # served by the holder of every window of the role, so the domain that mints the
      # tree's grants is the one its windows reach (for drive windows, the media domain,
      # which drives no device); and one without the window holds
      # none, nor an apps row that needs the service.
      def check_window_services(tables)
        service_rows = tables.fetch('services')
        WELL_KNOWN.select(&:window).each do |known|
          name = name_of(known)
          role = known.window
          windows = tables.fetch('windows').select { |row| row.fetch('role') == @codec.member('mf_window_role', role) }
          if windows.empty?
            invalid("an apps row needs a #{role} window, whose holder serves #{name}", 'apps') if
              known.needs == :apps && derives?(known, service_rows)
            invalid("a manifest without a #{role} window holds no service named #{name}", 'service.name') if
              service_rows.any? { |row| row.fetch('name') == name }
            next
          end

          service = service_rows.fetch(fetch_well_known(service_rows, known, required_by: "a #{role} window"))
          invalid("the service named #{name} is served by the holder of every #{role} window",
                  'service.server') unless windows.all? { |row| row.fetch('holder') == service.fetch('server') }
        end
      end

      # Property 19's third clause: the start rows and every app's row fit the start table.
      def check_app_start_rows
        rows_max = @codec.constant('start_rows_max')
        invalid("the start rows and the apps row's max pass start_rows_max, #{rows_max}", 'apps.max') if
          records('start').size + @apps.max > rows_max
      end

      # The packed apps row and its app_services rows: none without an apps row, and
      # otherwise the row, with the indices of the app template (app_template_index),
      # and of its packages and system facet rows, and its services, the indices check_apps resolved,
      # ascending, each with the index of the facet row granted to the template for it.
      # The rows are the ones derived_facets derived, found by grantee and service, each
      # service the one of its name, which derived_facets fetched; no source row shares
      # them: no source row names the template.
      def apps_rows(service_indices, tables)
        return [[], []] if @apps == NO_APPS

        template = app_template_index(tables)
        facets = tables.fetch('facets')
        tree = ->(constant) { tables.fetch('services').index { |row| row.fetch('name') == @codec.fixed_bytes(constant) } }
        granted = lambda do |service|
          facets.index do |facet|
            facet.fetch('grantee_kind') == grantee_kind('session') && facet.fetch('grantee') == template &&
              facet.fetch('service') == service
          end
        end
        services = service_indices.sort.map { |index| { 'service' => index, 'facet' => granted.call(index) } }
        [[{ 'memory' => @apps.memory, 'max' => @apps.max, 'app_template' => template,
            'packages_facet' => granted.call(tree.call('packages_service')),
            'system_facet' => granted.call(tree.call('system_service')),
            'services' => { 'table' => 'app_services', 'first' => 0, 'count' => services.size } }], services]
      end

      # Property 19's sixth clause, and the signer rows it packs, sorted by name: every
      # signer row holds an Ed25519 public key of signer_key_bytes, written hex: and its
      # digits, never quoted, and none is named development, the name the machine gives
      # the build's development package key (development_key_rows), so no source row
      # stands in for it, and none holds the published package key (PackageKey.published?), which
      # is never a trust root. The frontend keeps the rows' names unique.
      def signer_rows
        size = @codec.constant('signer_key_bytes')
        records('signer').sort_by { |record| record.name.b }.map do |record|
          invalid("signer #{DEVELOPMENT_SIGNER} is the build's development package key, never a row", 'signer.name') if
            record.name == DEVELOPMENT_SIGNER
          record.line.fail!('key requires hexadecimal bytes, hex:...') if one(record, 'key').quoted
          key = text(record, 'key')
          invalid("signer #{record.name}'s key is not #{size} bytes", 'signer.key') unless key.bytesize == size
          invalid("signer #{record.name}'s key is the published package key, which nothing trusts", 'signer.key') if
            PackageKey.published?(key)
          { 'name' => record.name, 'key' => key.bytes }
        end
      end

      # The build's development package key, packed as its own record, which only a
      # development manifest holds (docs/design-packaging.md, "The SDK"; Context accepts
      # it only in a development build): none when the build context carries none or the
      # manifest has no apps row, whose machine takes no packages and so trusts no key, and
      # refused when it is not an Ed25519 public key of signer_key_bytes or is the published
      # package key (PackageKey.published?). A build therefore hands every development check its
      # key, whatever the manifest's mode.
      def development_key_rows
        key = @context.development_key
        return [] if key.nil? || @apps == NO_APPS

        size = @codec.constant('signer_key_bytes')
        invalid("the development package key is not #{size} bytes", 'context.development_key') unless key.bytesize == size
        invalid('the development package key is the published package key, which nothing trusts',
                'context.development_key') if PackageKey.published?(key)
        [{ 'key' => key.bytes }]
      end


      # The booted slot's system partition (docs/design-fiasco.md, "The booted slot"),
      # packed as its one system_image record from the erofs_image artifact the nameless
      # system_image row's input names, as ReleaseMedium.image records it: the image one
      # extent from the partition's start (checked_extents keeps it inside the partition),
      # and its tree, whole blocks from where the image ends and inside the partition,
      # with a salt of 1 to 32 bytes and a 32-byte root hash in lowercase hex. None
      # without the row.
      def system_image_rows
        record = records('system_image').first
        return [] unless record

        artifact = artifact(record, 'input', 'erofs_image', field: 'system_image.input')
        extents = checked_extents(artifact, field: 'system_image.input')
        invalid('the system image is one extent at its partition\'s start', 'system_image.input') unless
          extents.size == 1 && extents.first.fetch('slot_offset').zero?
        length = extents.first.fetch('length')
        tree = artifact['tree']
        case tree.is_a?(Hash) && tree.values_at('offset', 'length', 'salt', 'root_hash')
        in [Integer => offset, Integer => bytes, /\A(?:[0-9a-f]{2}){1,32}\z/ => salt, /\A[0-9a-f]{64}\z/ => root]
          partition = @codec.constant('medium_system_sectors') * @codec.constant('mbr_sector_size')
          invalid('the system image\'s tree is whole blocks from the image\'s end, inside the partition', 'system_image.input') unless
            offset == length && !bytes.negative? && (bytes % @codec.constant('page_size')).zero? && offset + bytes <= partition
        else
          invalid('the system image\'s tree names its offset, length, salt and root hash', 'system_image.input')
        end
        salt = [salt].pack('H*')
        [{ 'image_length' => length, 'tree_offset' => offset, 'tree_length' => bytes, 'salt_length' => salt.bytesize,
           'reserved' => 0, 'salt' => salt.ljust(32, "\0").bytes, 'root_hash' => [root].pack('H*').bytes }]
      end

      # A package row as the manifest packs it (erx_mf_package).
      def package_row(package)
        { 'name' => package.name, 'flags' => package.enabled ? @codec.member('mf_package_flags', 'enabled') : 0,
          'sha256' => [package.sha256].pack('H*').bytes }
      end

      # Property 19's fifth clause on the package rows the image builder adds
      # (Erx::ImageApps), as far as the host can judge it without the manifest check: each row's
      # input is a package artifact of this pack, which the build's file check decoded
      # under the row's own name; the rows number at most the apps row's max, so none
      # without an apps row; and the declared memory of the enabled ones sums within the
      # apps budget. Answers each row as a Package, sorted by name.
      def check_packages
        packages = records('package').sort_by { |record| record.name.b }
        invalid("the package rows pass the apps row's max, #{@apps.max}", 'package') if packages.size > @apps.max
        rows = packages.map do |record|
          package = artifact(record, 'input', 'package', field: 'package.input')
          invalid("package #{record.name}'s input is the package of #{package['name']}", 'package.input') unless
            package['name'] == record.name
          enabled = record.properties.key?('enable') && start_flags(record).positive?
          Package.new(name: record.name, sha256: package.fetch('sha256'), enabled: enabled, memory: package.fetch('memory'))
        end
        memory = rows.select(&:enabled).sum(&:memory)
        invalid("the enabled packages declare #{memory} bytes, past the apps budget of #{@apps.memory}", 'package.enable') if
          memory > @apps.memory
        rows.freeze
      end

      # The ABI file's declaration of interface, or nil when no ABI file declares it.
      def service_declaration(interface) = @codec.schema.services.find { |service| service.fetch(:number) == interface }

      # The parameters an ABI file declares for interface, by key, or nil when no ABI
      # file declares the interface.
      def declared_parameters(interface) = service_declaration(interface)&.fetch(:parameters)

      # The grant checker the service of interface names in its parameters' checked_by,
      # one for all of them (abi_contracts.rb), or nil for a service with no parameter.
      def grant_checker(interface) = service_declaration(interface)&.fetch(:checked_by)

      # The manifest's start rows, sorted by their principal's index, each with its
      # defaults applied: enabled, no display and start_restarts_default ends in
      # start_period_default_s seconds (abi/manifest.txt). Property 17's structural clauses: a row is keyed
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
        invalid('two enabled start rows name one display', 'start.display') unless displays.uniq.size == displays.size
        rows.reject { |row| row.fetch('display') == none }.each { |row| check_start_display(row, tables) }
        rows.sort_by { |row| row.fetch('principal') }
      end

      # One start row: its principal's index, which must have a session template, and
      # each field the record states or its default. The period is at least a second,
      # since the row's supervisor takes it as its own, and neither field is past its
      # ceiling in abi/manifest.txt, which the reader and the start table also hold to.
      def start_row(record, services, sessions)
        principal = @indices.fetch('principal')[record.name] || invalid('a start row names no principal', 'start.name')
        invalid('a start row\'s principal has no session template', 'start.name') unless
          sessions.any? { |row| row.fetch('principal') == principal }
        stated = ->(key, default, &value) { record.properties.key?(key) ? value.call(key) : default }
        row = { 'principal' => principal,
                'flags' => stated.call('enable', @codec.member('mf_start_flags', 'enabled')) { start_flags(record) },
                'display' => stated.call('display', @codec.constant('mf_none')) { start_display(record, services) },
                'restarts' => stated.call('restarts', @codec.constant('start_restarts_default')) { |key| number(record, key) },
                'restart_period_s' => stated.call('restart_period_s', @codec.constant('start_period_default_s')) { |key| number(record, key) } }
        invalid('a start row\'s restart period is under a second', 'start.restart_period_s') if row.fetch('restart_period_s').zero?
        check_start_ceiling(row, 'restarts', 'start_restarts_max')
        check_start_ceiling(row, 'restart_period_s', 'start_period_max_s')
        row
      end

      # A start row's field Key is at most the ABI's limit Limit.
      def check_start_ceiling(row, key, limit)
        ceiling = @codec.constant(limit)
        invalid("a start row's #{key} is over #{ceiling}", "start.#{key}") if row.fetch(key) > ceiling
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
          invalid('a start row\'s display names a service the manifest does not contain', 'start.display')
      end

      # A row's display: a service of the windows interface, granted to the row's
      # principal's session template by a facet row.
      def check_start_display(row, tables)
        windows = find_interface('windows') ||
                  invalid('a start row names a display, and abi/services declares no windows interface', 'start.display')
        display = row.fetch('display')
        invalid('a start row\'s display is not a windows service', 'start.display') unless
          tables.fetch('services').fetch(display).fetch('interface') == windows
        session = tables.fetch('sessions').index { |template| template.fetch('principal') == row.fetch('principal') }
        grant = [grantee_kind('session'), session, display]
        invalid('a start row\'s display is not granted to its principal\'s session template', 'start.display') unless
          tables.fetch('facets').any? { |facet| facet.values_at('grantee_kind', 'grantee', 'service') == grant }
      end

      # design-abi.md: an introduction joins two different configured domains and is
      # unique as an unordered pair, so each is written with the lower index first.
      def normalize_introductions
        rows = records('introduce').map do |record|
          pair = record.properties.fetch('targets').map do |token|
            domain_index(token) || invalid('introduction names no configured domain', 'introduce')
          end
          invalid('an introduction joins two different domains', 'introduce') unless pair.uniq.size == 2
          { 'from' => pair.min, 'to' => pair.max }
        end
        invalid('two introductions join one pair', 'introduce') unless rows.uniq.size == rows.size
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
      # system domain holds one (property 8), and a facet of the input interface reads every
      # key pressed on its devices, so only a display domain holds one (check_input_grants);
      # the network's facets are property 15's
      # (check_network_grants), and the files, inspect and code receivers' floors property
      # 16's (check_files_grants, check_inspect_grants, check_code_grants). Each facet's parameters are resolved
      # against its service's declarations (facet_parameters), and its operations against
      # its interface's (facet_operations). Answers the sorted rows, each with its
      # operations and parameters spans, the facet_operations and facet_parameters tables
      # and each row's resolved parameter values, by key name, in the rows' order.
      def normalize_facets(services, tables, app_services)
        service_rows = tables.fetch('services')
        sources = records('facet').map do |record|
          token = one(record, 'service')
          index = services.index { |service| !token.quoted && "@service.#{service.name}" == token.value }
          invalid('facet names a service the manifest does not contain', 'facet.service') unless index
          facet_row(record, index, tables.fetch('sessions'))
        end
        known = well_known_facets(tables)
        asked = app_service_facets(tables, app_services)
        derived = known + asked
        rows = sources + derived.map(&:first)
        packed = records('facet').zip(sources).map { |record, row| facet_parameters(record, row, tables) } +
                 derived.map { |row, values| pack_parameters(values, granted_parameters(row, tables)) }
        # Every row but the well-known services' own derived rows, before the name checks,
        # which a source row of a service the build derives a row of for the same grantee
        # would trip first.
        values = packed.map(&:first)
        check_granted_rows(sources + asked.map(&:first),
                           values.first(sources.size) + values.last(asked.size), tables)
        grantee = ->(row) { row.values_at('grantee_kind', 'grantee') }
        server = ->(row) { service_rows.fetch(row.fetch('service')).fetch('server') }
        none = @codec.constant('mf_none')
        invalid('two facets of one grantee share a name', 'facet.name') unless
          rows.map { |row| [grantee.call(row), row.fetch('name')] }.uniq.size == rows.size
        invalid('the system domain takes no facet of its own service', 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') == grantee_kind('system') && server.call(row) == none }
        control = fetch_interface('driver_control')
        invalid('only the system domain holds a driver-control facet', 'facet.grantee') if
          rows.any? { |row| row.fetch('grantee_kind') != grantee_kind('system') && service_rows.fetch(row.fetch('service')).fetch('interface') == control }
        # The domain service grants every session its code_objects facet by its own policy
        # (docs/design-system.md, "The code_objects facet"), so no row grants one: not to a
        # configured domain, and not to a template, whose limits would replace the service's.
        invalid("no facet row grants #{CODE_OBJECTS}, which the domain service grants every session", 'facet.service') unless
          facets_of(rows, CODE_OBJECTS, tables).empty?
        check_code_objects_service(service_rows)
        check_no_line_services(service_rows)
        check_network_grants(rows, packed.map(&:first), tables)
        check_files_grants(rows, tables)
        check_inspect_grants(rows, tables)
        check_code_grants(rows, tables)
        check_line_grants(rows, packed.map(&:first), tables)
        check_ble_grants(rows, packed.map(&:first), tables)
        check_input_grants(rows, tables)
        operations = records('facet').zip(sources).map { |record, row| facet_operations(record, row, service_rows) } +
                     derived.map { [] }
        order = rows.each_index.sort_by { |at| [rows.fetch(at).fetch('name'), *grantee.call(rows.fetch(at))] }
        facets = order.zip(spans(order.map { |at| operations.fetch(at) }, 'facet_operations'),
                           spans(order.map { |at| packed.fetch(at).last }, 'facet_parameters')).map do |at, named, stated|
          rows.fetch(at).merge('operations' => named, 'parameters' => stated)
        end
        [facets, order.flat_map { |at| operations.fetch(at) }.map { |number| { 'operation' => number } },
         order.flat_map { |at| packed.fetch(at).last }, order.map { |at| packed.fetch(at).first }]
      end

      # One span of table per list, each list's rows following the last's from row 0.
      def spans(lists, table)
        lists.each_with_object([]) do |list, result|
          first = result.empty? ? 0 : result.last.fetch('first') + result.last.fetch('count')
          result << { 'table' => table, 'first' => first, 'count' => list.size }
        end
      end

      # A facet record's operations, `none` or a comma-separated list of the names its
      # service's interface declares, each once (property 2), as their numbers in ascending
      # order, the facet_operations rows its span takes (docs/design-abi.md, "Services,
      # facets and their parameter schemas"). Which rows the check can honour on Fiasco is
      # check_facets_supported's.
      def facet_operations(record, row, service_rows)
        token = one(record, 'operations')
        return [] if !token.quoted && token.value == 'none'

        declared = service_declaration(service_rows.fetch(row.fetch('service')).fetch('interface'))&.fetch(:operations) || {}
        record.line.fail!('operations requires none or unquoted operation names') if token.quoted
        names = token.value.split(',', -1)
        numbers = names.map { |name| declared[name] }
        invalid("facet #{row.fetch('name')}'s operations name an operation its interface does not declare", 'facet.operations') if
          names.empty? || numbers.include?(nil)
        invalid("facet #{row.fetch('name')}'s operations name one twice", 'facet.operations') unless names.uniq.size == names.size
        numbers.sort
      end

      # The checkers that consume a service's declared parameters, by the name its
      # declarations give in checked_by, each with the keys it consumes (docs/design-abi.md,
      # "Services, facets and their parameter schemas"): windows_grant is property 18,
      # check_display_grants, which reads pixels, session and front, and range-checks windows and
      # clipboard as their declarations bound them. line_grant is property 8's line clause,
      # check_line_grants, which reads device, rate and flow and range-checks rate. ble_grant is
      # check_ble_grants, which reads services. net_grant is
      # property 15's parameter clause, check_net_ports, which reads a net facet's ports and
      # listen; its sockets and buffers their declarations alone bound, and the grant
      # enforces all four at run time (abi/services/net.txt). files_grant takes a files
      # facet's rights and tree, whose member kinds alone bound them to their members, and
      # which the grant applies at run time; property 19 lets only a derived row state a
      # tree. A service declaring a parameter that no checker here consumes is unusable: no
      # facet of it is accepted, since nothing would check what it grants. Each checker
      # takes the facets of the services that name it (grant_checker), whatever their
      # interface.
      GRANT_CHECKERS = { 'windows_grant' => %w[windows pixels clipboard session front].freeze,
                         'line_grant' => %w[device rate flow].freeze,
                         'ble_grant' => %w[services].freeze,
                         'net_grant' => %w[sockets buffers ports listen].freeze,
                         'files_grant' => %w[rights tree].freeze }.freeze

      # A facet record's parameters resolved against its service's declarations: every
      # stated key is declared, appears once and has a value of its declared kind within
      # its bound, and every key declared one is stated. Answers the values, by key name,
      # and their packed facet_parameters rows in key order.
      def facet_parameters(record, row, tables)
        declared = granted_parameters(row, tables)
        pack_parameters(resolve_parameters(record, declared, tables.fetch('devices')), declared)
      end

      # The parameters a facet row's service declares, by key, each consumed by a grant
      # checker of GRANT_CHECKERS, or the row is refused as unsupported.
      def granted_parameters(row, tables)
        declared = declared_parameters(tables.fetch('services').fetch(row.fetch('service')).fetch('interface')) || {}
        return declared if declared.all? { |key, parameter| GRANT_CHECKERS.fetch(parameter.fetch(:helper), []).include?(key) }

        unsupported("facet #{row.fetch('name')}'s service declares a parameter no grant checker consumes", 'facet.parameter')
      end

      # Resolved parameter values, by key, and their packed facet_parameters rows in key
      # order, a set's one row an element, in strictly ascending order of its elements: a
      # u64 by its scalar, an identifier by its bytes, which String#<=> compares as unsigned
      # bytes, a name before every longer name it begins. A source row's set states no element
      # twice (resolve_parameters) and a derived row's values are the build's own, so no two
      # rows tie and the order is total.
      def pack_parameters(values, declared)
        rows = values.flat_map do |key, value|
          parameter = declared.fetch(key)
          parameter.fetch(:cardinality) == 'set' ? value.map { |item| parameter_row(parameter, item) } : [parameter_row(parameter, value)]
        end
        [values.freeze, rows.sort_by { |item| item.values_at('key', 'scalar', 'bytes') }]
      end

      # A facet record's parameter lines, KEY VALUE, as a map from key to value, a device
      # reference resolved against devices, the placed device rows. A set's lines, one an
      # element, come in any order and give it the array of their values sorted into the
      # order its packed rows take (pack_parameters): at most its MAX_COUNT of them, and
      # none twice (docs/design-abi.md, "Services, facets and their parameter schemas").
      # Every other key is stated at most once.
      def resolve_parameters(record, declared, devices)
        values = record.parameters.each_with_object({}) do |(key_token, value_token), result|
          key = key_token.value
          parameter = (!key_token.quoted && declared[key]) ||
                      invalid("facet parameter #{key} is not declared by its service", 'facet.parameter')
          value = parameter_value(key, parameter, value_token, record.line, devices)
          if parameter.fetch(:cardinality) == 'set'
            set = result.fetch(key, [])
            invalid("facet parameter #{key} states #{value.inspect} twice", 'facet.parameter') if set.include?(value)
            invalid("facet parameter #{key} states over #{parameter.fetch(:maximum_count)} values", 'facet.parameter') if
              set.size == parameter.fetch(:maximum_count)
            result[key] = (set + [value]).sort.freeze
          else
            invalid("facet parameter #{key} is stated twice", 'facet.parameter') if result.key?(key)
            result[key] = value
          end
        end
        declared.each do |key, parameter|
          invalid("facet parameter #{key} is required", 'facet.parameter') if parameter.fetch(:cardinality) == 'one' && !values.key?(key)
        end
        values
      end

      # One value of its declared kind: an integer within its range, yes or no for a
      # boolean, quoted bytes within their bound, the bare name of one of a member kind's
      # members, which is the value, or for a device reference the index in devices of the
      # row the quoted name names (named_device), which its grant checker judges
      # (docs/design-abi.md, "Services, facets and their parameter schemas"); a set's
      # element is one value of its kind, which is u64 or identifier (the ABI reader
      # refuses a set of another). The domain and principal references are refused while no service
      # declares one, so nothing here guesses their spelling.
      def parameter_value(key, parameter, token, line, devices)
        kind = parameter.fetch(:kind)
        case kind
        when 'u64', 'i64'
          line.fail!("parameter #{key} requires an integer") if token.quoted
          value = ABI::Syntax.integer(token.value, line: line)
          low, high = parameter.fetch(:bound).drop(1).map { |word| ABI::Syntax.integer(word, line: line) }
          invalid("facet parameter #{key} is outside #{low} to #{high}", 'facet.parameter') unless value.between?(low, high)
          value
        when 'boolean'
          line.fail!("parameter #{key} is yes or no") if token.quoted || !%w[yes no].include?(token.value)
          token.value == 'yes'
        when 'identifier', 'namespace_path', 'bytes'
          line.fail!("parameter #{key} requires quoted bytes") unless token.quoted
          value = token.value.b
          maximum = Integer(parameter.fetch(:bound).last)
          invalid("facet parameter #{key} is empty or over #{maximum} bytes", 'facet.parameter') unless
            value.bytesize.between?(kind == 'bytes' ? 0 : 1, maximum)
          value
        when 'member'
          members = parameter.fetch(:members)
          line.fail!("parameter #{key} is one of #{members.join(', ')}") if token.quoted || !members.include?(token.value)
          token.value
        when 'device'
          line.fail!("parameter #{key} requires a quoted device path or PCIe place") unless token.quoted
          named_device(token.value, devices) || invalid("facet parameter #{key} names no placed device", 'facet.parameter')
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
        when 'member' then row.merge('scalar' => parameter.fetch(:minimum) + parameter.fetch(:members).index(value))
        when 'device' then row.merge('index' => value)
        else row.merge('bytes' => value)
        end
      end

      # Property 8's clause for the line interface (docs/design-system.md, "The manifest";
      # docs/design-bluetooth.md, "The controller's line"). The system domain serves every
      # line service. Of its services, the one named line is exactly the one of the line
      # interface, so the name the Erlang side keys on (erx_uart_sup:line_grants/1, the
      # serve call, the facet-names check, erx_ns:place/1) and the interface the root keys
      # on (boot_manifest.c) pick the same service. Each grant of a line service, of facets
      # with values, their resolved parameters in the same order, names by its device a
      # line's device, a UART or a virtio console (role serial), whose unit the system
      # domain holds, which is neither the console's nor the host link's, is not on the
      # console's interrupt line (check_uart_lines) and which no other grant names. A UART's
      # grant states rate and flow, flow none or rts_cts, and any other device's states
      # neither: a virtio port's queues are its flow control. Every placed serial device is
      # some grant's (check_serial_devices), so the root, which writes a serial device's
      # record by its kind row, writes it only for the granted one. The grantee is a configured
      # domain, which mounts the tree its application start reads. The manifest grants the
      # interface at most once, since one line service serves one line (TODO.md, the line's
      # service side); the duplicate check runs first, so it holds once that limit is lifted.
      def check_line_grants(facets, values, tables)
        line = ->(service) { grant_checker(service.fetch('interface')) == 'line_grant' }
        system = @codec.constant('mf_none')
        if tables.fetch('services').any? { |row| line.call(row) && row.fetch('server') != system }
          invalid('only the system domain serves the line interface', 'service.server')
        end
        interface = find_interface('line')
        misnamed = tables.fetch('services').find do |row|
          row.fetch('server') == system && (row.fetch('interface') == interface) != (row.fetch('name') == 'line')
        end
        if misnamed
          invalid("the system domain's service #{misnamed.fetch('name')} is named line exactly when it is of the line " \
                  'interface', 'service.name')
        end
        grants = facets.zip(values).select { |row, _| line.call(tables.fetch('services').fetch(row.fetch('service'))) }
        console = @context.platform['console']
        reserved = [console, @context.platform.fetch('hostlink', '')]
        named_devices = grants.map do |row, given|
          named = "line grant #{row.fetch('name')}"
          invalid("#{named} is granted to no configured domain", 'facet.grantee') unless row.fetch('grantee_kind') == grantee_kind('domain')
          device = tables.fetch('devices').fetch(given.fetch('device'))
          path = device.fetch('path')
          check_line_device(named, device, given)
          invalid("#{named}'s device #{path} is the console's or the host link's", 'facet.parameter') if reserved.include?(path)
          unless unit_holder(tables, path) == @codec.constant('mf_none')
            invalid("#{named}'s device #{path} is not the system domain's", 'facet.parameter')
          end
          given.fetch('device')
        end
        check_uart_lines(tables, console, named_devices.to_h { |index| [tables.fetch('devices').fetch(index).fetch('path'), 'facet.parameter'] })
        invalid('two line grants name one device', 'facet.parameter') unless named_devices.uniq.size == named_devices.size
        invalid('a manifest holds at most one line grant', 'facet.service') if grants.size > 1
        check_serial_devices(tables.fetch('devices'), named_devices)
      end

      # ble_grant, the clause for the ble interface (docs/design-bluetooth.md, "Declarations:
      # `abi/gatt`" and "The `ble` facet"). A service is named ble exactly when it is of the
      # ble interface, as the line service is named line, so the name the Bluetooth domain's
      # mint provides and the interface the check reasons from pick the same service. Every
      # service whose checker is ble_grant is served by a configured domain, the Bluetooth
      # domain, and no grant of one goes to the system domain, whose handler would take a
      # phone's bytes into the trusted base (B8), or to a session template, which every
      # session made from it would hold, so two sessions would contend for one service's
      # handler, as line_grant refuses one. The one template row it takes is the app
      # template's, which the build derives from the apps row's gatt and no source row
      # can name (the template names no principal), and which a session of an app keeps
      # only when admission kept its package's gatt, narrowed to those services, an app
      # running one session at a time
      # ("Who holds `ble`"). facets and values are parallel arrays, each
      # facet row beside its resolved parameters; each grant's services are services
      # abi/gatt declares (Context#gatt_services), so every served set is a subset of the
      # declarations, and no service is named by two grants, so each has at most one
      # grantee that can handle it, and the apps row's gatt never offers apps a service a
      # configured domain handles (docs/design-packaging.md, PK13).
      def check_ble_grants(facets, values, tables)
        checked = ->(service) { grant_checker(service.fetch('interface')) == 'ble_grant' }
        system = @codec.constant('mf_none')
        interface = fetch_interface('ble')
        misnamed = tables.fetch('services').find do |row|
          (row.fetch('interface') == interface) != (row.fetch('name') == 'ble')
        end
        invalid("service #{misnamed.fetch('name')} is named ble exactly when it is of the ble interface", 'service.name') if misnamed
        unserved = tables.fetch('services').find { |row| checked.call(row) && row.fetch('server') == system }
        invalid("service #{unserved.fetch('name')} is served by no configured domain", 'service.server') if unserved
        declared = @context.gatt_services
        grants = facets.zip(values).select { |row, _given| checked.call(tables.fetch('services').fetch(row.fetch('service'))) }
        grants.each do |row, given|
          named = ble_grant_named(row, tables)
          invalid("#{named} is granted to the system domain, which takes no phone's bytes", 'facet.grantee') if
            row.fetch('grantee_kind') == grantee_kind('system')
          invalid("#{named} is granted to a session template, whose every session would hold it", 'facet.grantee') if
            row.fetch('grantee_kind') == grantee_kind('session') && !app_template?(row, tables)
          undeclared = given.fetch('services', []).reject { |name| declared.include?(name) }
          invalid("#{named} names #{undeclared.map(&:inspect).join(', ')}, which abi/gatt does not declare", 'facet.parameter') unless
            undeclared.empty?
        end
        holders = grants.flat_map { |row, given| given.fetch('services', []).map { |name| [name, row] } }.group_by(&:first)
        name, shared = holders.find { |_name, held| held.size > 1 }
        invalid("#{shared.map { |_name, row| ble_grant_named(row, tables) }.join(' and ')} both name #{name.inspect}",
                'facet.parameter') if shared
      end

      # A ble grant as a refusal names it: the app template's row by the apps row's gatt,
      # which its services come from, since no source line states the row.
      def ble_grant_named(row, tables) = app_template?(row, tables) ? "the apps row's gatt" : "ble grant #{row.fetch('name')}"

      # A line grant's device by its role: a UART's grant states rate, which its
      # declaration holds to 115200, and flow, none or rts_cts; a virtio console's states
      # neither; a device of any other role is no line's.
      def check_line_device(named, device, given)
        path = device.fetch('path')
        case device.fetch('role')
        when device_role('uart')
          invalid("#{named}'s UART #{path} states no rate", 'facet.parameter') unless given.key?('rate')
          invalid("#{named}'s flow is none or rts_cts", 'facet.parameter') unless %w[none rts_cts].include?(given['flow'])
        when device_role('serial')
          invalid("#{named}'s device #{path} is no UART, so it states no rate or flow", 'facet.parameter') if given.key?('rate') || given.key?('flow')
        else
          invalid("#{named}'s device #{path} names no UART or serial device", 'facet.parameter')
        end
      end

      # Rule serial-device-granted (property 8): every placed serial device is the device of
      # a line grant. The root writes a record for a device of the serial kind row wherever
      # it is placed, so a serial device no grant names would be a line nothing serves, its
      # DMA memory reserved for nothing.
      def check_serial_devices(devices, named)
        devices.each_with_index do |device, index|
          next unless device.fetch('role') == device_role('serial') && !named.include?(index)

          invalid("serial device #{device.fetch('path')} is named by no line grant", 'devices.role')
        end
      end

      # Property 8's clause for the input interface (docs/design-system.md, "The manifest";
      # abi/services/input.txt). A facet of an input tree reads every key pressed on the
      # devices behind it, whatever window has the keyboard, so only a display domain, a
      # configured domain that serves a service checked by windows_grant, holds one: a
      # session or another domain holding one would read the user's typing past the
      # display's focus. Its grants are read-only by construction: the interface declares
      # no rights parameter, so facet_parameters refuses a row that states one.
      def check_input_grants(facets, tables)
        services = tables.fetch('services')
        input = fetch_interface('input')
        displays = services.select { |service| grant_checker(service.fetch('interface')) == 'windows_grant' }
                           .map { |service| service.fetch('server') }
        facets.each do |row|
          next unless services.fetch(row.fetch('service')).fetch('interface') == input
          next if row.fetch('grantee_kind') == grantee_kind('domain') && displays.include?(row.fetch('grantee'))

          invalid("input facet #{row.fetch('name')} is granted to no display domain", 'facet.grantee')
        end
      end

      # The displays (docs/design-display.md, "A display's session"), sorted by their
      # service's index; facet_values holds each facet row's resolved parameters, by the
      # facet table's index. A display record is keyed by its service's source alias, so
      # a service has at most one. Property 18: every service whose parameters name
      # windows_grant (grant_checker), of the windows interface or another, has a record and
      # every record names one; a display domain serves one display, so no domain pays
      # for two displays' grants out of one outer budget; and each display's grants pass
      # check_display_grants.
      def normalize_displays(services, tables, facet_values)
        display = ->(service) { grant_checker(service.fetch('interface')) == 'windows_grant' }
        rows = records('display').map do |record|
          index = services.index { |service| service.name == record.name } ||
                  invalid('a display record names a service the manifest does not contain', 'display.name')
          invalid('a display record names a service whose parameters are not checked by windows_grant', 'display.name') unless
            display.call(tables.fetch('services').fetch(index))
          display_row(record, index)
        end
        tables.fetch('services').each_with_index do |service, index|
          next unless display.call(service)
          invalid("service #{service.fetch('name')}, checked by windows_grant, has no display record", 'display.name') unless
            rows.any? { |row| row.fetch('service') == index }
        end
        servers = rows.map { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('server') }
        invalid('one domain serves two displays', 'display.name') unless servers.uniq.size == servers.size
        rows.each { |row| check_display_grants(row, tables, facet_values) }
        rows.sort_by { |row| row.fetch('service') }
      end

      # One display record: its service's index, its policy, its idle times, of which a
      # nonzero time to turn the panel off comes no sooner than the time to dim it, and its
      # palette, the first of mf_display_palette when the record names none.
      def display_row(record, service)
        palette = record.properties.key?('palette') ? enum(record, 'palette', 'mf_display_palette') : @codec.schema.types.fetch('mf_display_palette').members.values.min
        row = { 'service' => service, 'policy' => enum(record, 'policy', 'mf_display_policy'), 'palette' => palette }
        %w[idle_dim_s idle_off_s].each do |key|
          row[key] = number(record, key)
          invalid("a display's #{key} is over #{(1 << 32) - 1}", "display.#{key}") if row.fetch(key) >= (1 << 32)
        end
        invalid('a display turns its panel off before it dims it', 'display.idle_off_s') unless
          row.fetch('idle_off_s').zero? || row.fetch('idle_off_s') >= row.fetch('idle_dim_s')
        row
      end

      # The environment keys a display domain takes from its display record, which its own
      # row may not set (abi/manifest.txt, display_key and the keys after it).
      def display_keys = %w[display_key display_policy_key display_idle_dim_key display_idle_off_key display_palette_key]
                         .map { |name| @codec.fixed_bytes(name) }

      # Property 18's clauses on one display's grants: its server is a configured
      # domain whose row sets none of display_keys, no facet row of its service grants it to the system domain, whose
      # connections no introduction makes and so carry no pixel area, no facet row of
      # its service sets session, only a row granting it to the system principal's session
      # template, root's, sets front, and only in a development build, since the newest
      # window of a front grant takes a single display's screen, every grant's holder boots
      # a script that starts the client side (check_display_client), and the grants' costs
      # fit the display domain's outer budget. Each grant costs its pixel area, its pixels or
      # windows_pixels_default, and the side the display reads for it, the display's own
      # lane, each rounded up to pages; a session template's grant costs that once for
      # each session its principal's domains quota lets live at once, a configured
      # domain's once. When the apps row's services name the display, its apps hold max
      # grants more, each of the parameters' defaults (property 19's second clause).
      def check_display_grants(display, tables, facet_values)
        service = tables.fetch('services').fetch(display.fetch('service'))
        server = service.fetch('server')
        invalid("display #{service.fetch('name')} is served by the system domain, not a display domain", 'display.name') if
          server == @codec.constant('mf_none')
        domain = tables.fetch('domains').fetch(server)
        invalid("display #{service.fetch('name')}'s domain sets a key its display record gives it", 'domain.env') if
          domain.fetch('env').split("\0").any? { |word| display_keys.include?(word.partition('=').first) }
        limits = tables.fetch('limits').fetch(domain.fetch('limits'))
        grants = tables.fetch('facets').zip(facet_values).select { |facet, _values| facet.fetch('service') == display.fetch('service') }
        counted = grants.map do |facet, values|
          invalid("facet #{facet.fetch('name')} grants a display to the system domain, whose connections carry no pixel area",
                  'facet.grantee') if facet.fetch('grantee_kind') == grantee_kind('system')
          invalid("facet #{facet.fetch('name')} sets session, which the domain service alone sets", 'facet.parameter') if
            values.key?('session')
          invalid("facet #{facet.fetch('name')} sets front, which only root's template's grant takes, in a development build", 'facet.parameter') if values.key?('front') && !front_grantee?(facet, tables)
          check_display_client(facet, tables)
          [grant_instances(facet, tables), values]
        end
        apps = grants.any? { |facet, _values| app_template?(facet, tables) }
        cost = counted.sum do |instances, values|
          pixels = values.fetch('pixels') { @codec.constant('windows_pixels_default') }
          instances * (pages(pixels) + pages(limits.fetch('lane')))
        end
        return if cost <= limits.fetch('outer')

        invalid("display #{service.fetch('name')}'s grants#{' and the apps row\'s max apps' if apps} cost #{cost} bytes, " \
                "past its domain's outer budget of #{limits.fetch('outer')}", apps ? 'apps.max' : 'facet.parameter')
      end

      # Property 18's client clause: the release script a display grant's holder boots, a
      # configured domain's or a session template's, the app template's among them, starts
      # the client side of the display (DomainStartup::DISPLAY_CLIENT), as the checked
      # context records what each script starts. Every domain boots in interactive mode, so
      # any can load erx_win, but only one whose script starts it runs the allocator that a
      # program's first open of /dev/draw takes its window's buffer from; without it that
      # open fails with ENODEV (docs/design-display.md, "The pixel area").
      def check_display_client(facet, tables)
        release = grantee_release(facet, tables)
        missing = DomainStartup::DISPLAY_CLIENT - @context.artifacts.fetch(release).fetch('started')
        return if missing.empty?

        invalid("facet #{facet.fetch('name')} grants a display to a holder whose release #{release} does not start " \
                "#{missing.join(', ')}", app_template?(facet, tables) ? 'apps.services' : 'facet.grantee')
      end

      # The release artifact a facet row's grantee boots, a configured domain or a session
      # template, never the system domain, whose grant check_display_grants refuses first:
      # the app template's recipe's, or the `release @artifact.NAME` of the source record
      # the row was normalized from, a domain's by its name and a template's by its
      # principal's.
      def grantee_release(facet, tables)
        return DomainStartup::APP_TEMPLATE.release if app_template?(facet, tables)

        grantee = facet.fetch('grantee')
        kind, name = case facet.fetch('grantee_kind')
                     when grantee_kind('domain') then ['domain', tables.fetch('domains').fetch(grantee).fetch('name')]
                     when grantee_kind('session')
                       principal = tables.fetch('sessions').fetch(grantee).fetch('principal')
                       ['session', tables.fetch('principals').fetch(principal).fetch('name')]
                     end
        release_name(records(kind).find { |record| record.name == name }, field: "#{kind}.release")
      end

      # Whether a facet row may set front: a development build's row granting the display to
      # the system principal's session template, root's, and no other template's or domain's.
      def front_grantee?(facet, tables) = development_root?(*facet.values_at('grantee_kind', 'grantee'), tables)

      # Whether the grantee kind and index name root's session template, the system
      # principal's.
      def root_template?(kind, index, tables)
        kind == grantee_kind('session') &&
          tables.fetch('sessions').fetch(index).fetch('principal') == reference(@source.machine, 'system_principal', 'principal')
      end

      # Whether the grantee is root's session template in a development build, the one
      # build whose root's template a few grants (front, the whole data volume) may reach.
      def development_root?(kind, index, tables) = BuildKind.development?(@context.build_kind) && root_template?(kind, index, tables)

      # How many grants a facet row makes at once: one for a domain, for the app template
      # the apps row's max, each app a principal with a domains quota of one (property
      # 19's second clause), and for another session template its principal's domains
      # quota, the sessions of it that can live at once.
      def grant_instances(facet, tables)
        return 1 unless facet.fetch('grantee_kind') == grantee_kind('session')
        return @apps.max if app_template?(facet, tables)

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
      # every grant there is. The grants' ports are its parameter clause (check_net_ports).
      def check_network_grants(facets, values, tables)
        net, netadmin = fetch_interface('net'), fetch_interface('netadmin')
        interface = ->(row) { tables.fetch('services').fetch(row.fetch('service')).fetch('interface') }
        facets.each do |row|
          next unless row.fetch('grantee_kind') == grantee_kind('system') && [net, netadmin].include?(interface.call(row))

          invalid("facet #{row.fetch('name')} grants the system domain a network interface, which it never holds", 'facet.grantee')
        end
        floor = @codec.constant('net_max_frame_min')
        facets_of(facets, 'net', tables).each { |row| check_receiver_floors(row, tables, 'net', { 'max_frame' => floor }) }
        check_net_ports(facets.zip(values).select { |row, _| interface.call(row) == net }, tables)
      end

      # Property 15's parameter clause, over each net grant and its resolved parameters
      # (abi/services/net.txt): every listen port is one of the grant's ports, those it
      # lists or by default net_unprivileged_port to 65535, so no listen line is void; and a
      # privileged port, below net_unprivileged_port, which a grant binds only when it lists it,
      # is listed by one grant of its network domain alone, to a configured domain. That
      # domain's stack binds a port for the first grant to claim it (erx_net_bind), so a
      # second grant listing it could take it first, and a session template's grant is
      # every session's made from it.
      def check_net_ports(grants, tables)
        unprivileged = @codec.constant('net_unprivileged_port')
        privileged = grants.flat_map do |row, stated|
          server = tables.fetch('services').fetch(row.fetch('service')).fetch('server')
          ports = stated['ports']
          unbound = stated.fetch('listen', []).reject { |port| ports ? ports.include?(port) : port >= unprivileged }
          invalid("facet #{row.fetch('name')} listens on #{unbound.join(', ')}, none of its ports", 'facet.parameter') unless
            unbound.empty?
          low = (ports || []).select { |port| port < unprivileged }
          invalid("facet #{row.fetch('name')} grants privileged ports to a session template", 'facet.grantee') if
            !low.empty? && row.fetch('grantee_kind') != grantee_kind('domain')
          low.map { |port| [[server, port], row.fetch('name')] }
        end
        shared = privileged.group_by(&:first).select { |_held, holders| holders.size > 1 }
        shared.each do |(_server, port), holders|
          invalid("privileged port #{port} is listed by facets #{holders.map(&:last).join(', ')} of one network domain", 'facet.parameter')
        end
      end

      # Property 16: every domain that receives the files protocol of a facet of an
      # interface abi/services declares served_as tree (files, windows, line), its
      # grantee (the system domain, a configured domain or a session template) and its
      # server, takes frames of at least files_max_frame_min bytes under its own runtime
      # limits, and the facet's max_request admits a request that long, since a read reply
      # or a write request of the client's 64 KiB transfer unit arrives in one frame, and
      # the funnel drops a longer frame and the facet a longer request.
      def check_files_grants(facets, tables)
        floor = @codec.constant('files_max_frame_min')
        trees = @codec.schema.services.select { |service| service.fetch(:served_as) == 'tree' }
        trees.each do |service|
          facets_of(facets, service.fetch(:name), tables).each do |row|
            if row.fetch('max_request') < floor
              invalid("facet #{row.fetch('name')}'s max_request #{row.fetch('max_request')} is below " \
                      "#{service.fetch(:name)}'s floor of #{floor}", 'facet.max_request')
            end
            check_receiver_floors(row, tables, service.fetch(:name), { 'max_frame' => floor })
          end
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
          invalid('only the system domain serves the inspect interface', 'service.server')
        end
        facets_of(facets, 'inspect', tables).each { |row| check_receiver_floors(row, tables, 'inspect', floors) }
      end

      # The code protocol's floors (docs/design-live.md, "The code server", Floors),
      # computed from abi/services/code.txt (tools/lib/erx/abi_code_bounds.rb): for each
      # set of receivers, the ABI constant that floors each runtime_limits field.
      CODE_FLOORS = {
        load: { 'max_frame' => 'code_load_max_frame_min',
                'max_message_heap' => 'code_load_message_heap_min',
                'funnel_depth' => 'code_load_funnel_depth_min' }.freeze,
        answer: { 'max_frame' => 'code_answer_max_frame_min',
                  'max_message_heap' => 'code_answer_message_heap_min',
                  'funnel_depth' => 'code_answer_funnel_depth_min' }.freeze,
        facet: { 'max_frame' => 'code_facet_max_frame_min',
                 'max_message_heap' => 'code_facet_message_heap_min',
                 'funnel_depth' => 'code_facet_funnel_depth_min' }.freeze
      }.freeze

      # Property 16 for code: every configured domain and session template, each of
      # which erx_code's loads reach whatever it is granted, runs with at least the
      # load floors, and the system domain, which takes the answers, with the answer
      # floors, so no receiver's funnel drops a message of a load; and every facet of the
      # code interface passes check_code_facets.
      def check_code_grants(facets, tables)
        check_code_facets(facets, tables)
        loads = %w[domain session].flat_map do |kind|
          table = kind == 'domain' ? 'domains' : 'sessions'
          tables.fetch(table).each_index.map { |index| receiver_limits(grantee_kind(kind), index, tables) }
        end
        loads.uniq.each { |profile| check_code_floors(profile, :load) }
        check_code_floors(receiver_limits(grantee_kind('system'), nil, tables), :answer)
      end

      # Every facet of the code interface admits code_request_max, the longest request
      # load sends, which a smaller max_request would drop unanswered, and its grantee
      # and server, which take its requests and replies, run with the facet floors.
      def check_code_facets(facets, tables)
        bound = @codec.constant('code_request_max')
        facets_of(facets, 'code', tables).each do |row|
          if row.fetch('max_request') < bound
            invalid("facet #{row.fetch('name')}'s max_request #{row.fetch('max_request')} " \
                    "is below code_request_max #{bound}", 'facet.max_request')
          end
          check_receiver_floors(row, tables, 'code', code_floors(:facet))
        end
      end

      # The code protocol's floors for RECEIVERS, a key of CODE_FLOORS, keyed by the
      # runtime_limits field each binds.
      def code_floors(receivers) = CODE_FLOORS.fetch(receivers).transform_values { |name| @codec.constant(name) }

      # Refuses PROFILE, a runtime_limits row, when one of its three funnel limits is
      # below the code protocol's floor for its RECEIVERS.
      def check_code_floors(profile, receivers)
        code_floors(receivers).each do |field, floor|
          next if profile.fetch(field) >= floor

          invalid("runtime limits #{profile.fetch('name')} run with #{field} " \
                  "#{profile.fetch(field)}, below the code protocol's #{receivers} " \
                  "floor of #{floor}", "runtime_limits.#{field}")
        end
      end

      # At most one service of the code_objects interface, named code_objects and served by
      # the system domain, the name and server the domain service grants every session's
      # facet under (docs/design-system.md, "The code_objects facet").
      def check_code_objects_service(service_rows)
        interface = fetch_interface(CODE_OBJECTS)
        system = @codec.constant('mf_none')
        found = service_rows.select { |row| row.fetch('interface') == interface }
        return if found.empty?
        return if found.size == 1 && found.first.fetch('name') == CODE_OBJECTS.b && found.first.fetch('server') == system

        invalid("the manifest serves #{CODE_OBJECTS} once, by that name, from the system domain", 'service.interface')
      end

      # No service row is of an interface abi/services declares served_by session, a
      # session's line, whose grant the domain service mints only for the grantee the system
      # domain names (docs/design-system.md, "A session's lines"), so no facet row grants
      # one either: a facet row names a service row.
      def check_no_line_services(service_rows)
        lines = @codec.schema.session_lines.to_h { |service| [service.fetch(:number), service.fetch(:name)] }
        service_rows.each do |row|
          line = lines[row.fetch('interface')]
          next unless line

          invalid("service #{row.fetch('name')} is of #{line}, a session's line, which no manifest row grants",
                  'service.interface')
        end
      end

      # The facet rows of the interface abi/services declares as NAME, compared by number.
      def facets_of(facets, name, tables)
        interface = fetch_interface(name)
        facets.select { |row| tables.fetch('services').fetch(row.fetch('service')).fetch('interface') == interface }
      end

      # Refuses, as PROPERTY, a facet whose grantee or server runs a runtime limit below
      # the interface's floor for it (docs/design-domains.md, "Floors from a protocol": a
      # floor binds both receivers). FLOORS maps a runtime_limits field to its floor.
      def check_receiver_floors(row, tables, interface, floors)
        server = tables.fetch('services').fetch(row.fetch('service')).fetch('server')
        server_kind = server == @codec.constant('mf_none') ? grantee_kind('system') : grantee_kind('domain')
        receivers = { 'grantee' => receiver_limits(row.fetch('grantee_kind'), row.fetch('grantee'), tables),
                      'server' => receiver_limits(server_kind, server, tables) }
        receivers.each do |role, limits|
          floors.each do |field, floor|
            next if limits.fetch(field) >= floor

            invalid("facet #{row.fetch('name')}'s #{role} runs with #{field} #{limits.fetch(field)}, " \
                    "below #{interface}'s floor of #{floor}", "runtime_limits.#{field}")
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

        invalid('names neither the system domain, a configured domain nor a session template', 'facet.grantee')
      end

      # A session template's index, or nil when the token names none.
      def session_index(token, sessions)
        return nil if token.quoted || !token.value.start_with?('@session.')

        principal = @indices.fetch('principal')[token.value.delete_prefix('@session.')]
        principal && sessions.index { |row| row.fetch('principal') == principal }
      end

      def facet_row(record, service, sessions)
        name = record.properties.key?('name') ? text(record, 'name') : record.name.b
        invalid('facet name is not a system identifier', 'facet.name') unless name.match?(Frontend::IDENTIFIER)
        queue = record.properties.key?('queue') ? number(record, 'queue') : number(@source.machine, 'system_queue')
        kind, index = facet_grantee(one(record, 'grantee'), sessions)
        { 'name' => name, 'grantee_kind' => kind, 'grantee' => index,
          'service' => service,
          'operations' => { 'table' => 'facet_operations', 'first' => 0, 'count' => 0 },
          'queue' => queue }.merge(ABI::Contracts::FACET_QUANTITIES.to_h { |key| [key, number(record, key)] })
      end

      # What the check cannot honour on Fiasco, refused once properties 2, 10 and 11 hold
      # (docs/design-time.md, "On Fiasco"): a facet that names operations of a service a
      # configured domain serves, since only the system domain's erx_facet checks a
      # grant's operations, so the row would grant every operation. A tree's interface
      # declares none (facet_operations). Its parameters are resolved (facet_parameters).
      def check_facets_supported(rows)
        none = @codec.constant('mf_none')
        rows.fetch('facets').each do |facet|
          next if facet.fetch('operations').fetch('count').zero?

          service = rows.fetch('services').fetch(facet.fetch('service'))
          unsupported("facet #{facet.fetch('name')} names operations of a service a configured domain serves, " \
                      'which nothing checks on Fiasco', 'facet.operations') unless service.fetch('server') == none
        end
      end

      # Property 10: every server before its clients, ties broken by name order, which
      # the domains' indices follow. A domain is ready once every configured domain
      # its facets name is placed; none ready means the facets lead back to one.
      def boot_order(domains, edges)
        servers = edges.group_by(&:first).transform_values { |pairs| pairs.map(&:last) - [@codec.constant('mf_none')] }
        domains.each_index.each_with_object([]) do |_step, placed|
          ready = (domains.each_index.to_a - placed).find { |domain| (servers.fetch(domain, []) - placed).empty? }
          invalid('a configured domain\'s facets lead back to it', 'facet.service') unless ready
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

          invalid('a rescue domain names a service of a domain the rescue configuration does not start', 'facet.service')
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
                                field: 'planner')
        end

        order = rows.fetch('boot_order').map { |step| step.fetch('domain') }
        statuses = @planner.call(plan_view(bytes, rows, order: order,
                                           templates: sessions.map { |session| session.fetch('template') }))
        invalid("the domain library refuses the manifest's view: #{statuses.fetch('refused').delete_prefix('manifest: ')}", 'view') if statuses.key?('refused')
        order.zip(statuses.fetch('domains')).each do |index, status|
          refuse_plan(status, "configured domain #{domains.fetch(index).fetch('name')}", 'domain')
        end
        rows.fetch('introductions').zip(statuses.fetch('introductions')).each do |row, status|
          names = row.values_at('from', 'to').map { |index| domains.fetch(index).fetch('name') }
          refuse_plan(status, "the introduction of #{names.join(' and ')}", 'introduce')
        end
        sessions.each_with_index do |session, index|
          refuse_plan(statuses.fetch('sessions').fetch(index), session.fetch('what'), session.fetch('field'))
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
      def refuse_plan(status, what, field)
        return if status.zero?

        name = (@codec.schema.statuses || {}).key(status) || status
        invalid("the domain library refuses #{what} with #{name}", field)
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

      # Property 3 as Phase 1 keeps it (docs/design-fiasco.md, "The Phase 1 manifest check";
      # docs/design-usb.md, "The Phase 1 part"). A PCIe bridge is a device-tree row of the
      # configuration role. Its unit is held by the configured domain pcie, which can turn on
      # any function's bus mastering and so holds nothing else: every record that names pcie
      # is one of an allow-list (pcie_reference?), so a table the ABI adds later is refused
      # until it is allowed. A placed PCIe function is
      # unconfined, held by a configured domain and behind a bridge the manifest places,
      # which pcie then drives. A function names a line only at a closed bridge's place
      # (behind_bridge), and the boot view keeps that line in its unit.
      def check_pcie(tables)
        devices = tables.fetch('devices')
        pcie = @indices.fetch('domain')['pcie']
        units = tables.fetch('units').map { |unit| [unit.fetch('holder'), unit_devices(devices, unit)] }
        bridges = units.flat_map { |_holder, rows| rows.select { |device| pcie_bridge?(device) } }.map { |device| device.fetch('path') }
        units.each do |holder, rows|
          held = !pcie.nil? && holder == pcie
          invalid("only the domain pcie holds a PCIe bridge's unit", 'unit.holder') if rows.any? { |device| pcie_bridge?(device) } && !held
          invalid("the domain pcie holds only PCIe bridges' units", 'unit.holder') if held && !rows.all? { |device| pcie_bridge?(device) }
          rows.select { |device| device.fetch('selector') == @codec.member('mf_selector', 'pci') }.each { |function| check_function(function, holder, bridges) }
        end
        check_pcie_parties(tables, pcie, units)
        return if pcie.nil?

        holds_only(tables, pcie, "the domain pcie holds nothing but PCIe bridges' units") { |scope, row| pcie_reference?(scope, row, tables) }
      end

      # Refuses the first row that names the domain at index and that the block does not
      # admit, with what as the refusal's start: the allow-list form of a domain that holds
      # nothing else (check_pcie, check_drive_domains), under which a table the ABI adds
      # later names the domain only once the block admits it.
      def holds_only(tables, index, what)
        scope, = domain_references(tables, index).find { |found, row| !yield(found, row) }
        invalid("#{what}, and its #{scope} row names it", scope) if scope
      end

      # Whether a row naming the domain pcie is one of the allow-list's (check_pcie): its
      # bridges' units, its place in the boot order, its service of pcie and its pci_bus
      # facet. Every other table is refused until allowed.
      def pcie_reference?(scope, row, tables)
        case scope
        when 'units', 'boot_order' then true
        when 'services' then row.fetch('interface') == fetch_interface('pcie')
        when 'facets' then facets_of([row], 'pci_bus', tables).any?
        else false
        end
      end

      # The parties of the three PCIe interfaces (docs/design-pcie.md, "Facets" and "The
      # manifest"). The system domain's device service serves pci_bus and pci and the domain
      # pcie serves pcie. Only pcie holds pci_bus: another holder could report functions and
      # take settings, and a pci_bus of another server would direct which functions the
      # enumerator raises. Only the system domain holds pcie, whose set raises any function
      # without a holder's request. A configured domain holds a pci facet exactly when its
      # units hold a pci device: the device service matches a request's place against the
      # grantee's own rows, so a facet without one opens nothing, and a holder without one
      # cannot open its function. The system domain picks a facet's callback and the process
      # behind it by the service's name (erx_domain_srv:system_facet/4, served/2), so each
      # service of the three is named by its interface and a service of one of those names
      # is of that interface: a service named pci_bus of another interface would otherwise
      # hand its grantees the device service's pci_bus surface.
      def check_pcie_parties(tables, pcie, units)
        system = @codec.constant('mf_none')
        { 'pci_bus' => [system, 'the system domain'], 'pci' => [system, 'the system domain'],
          'pcie' => [pcie, 'the domain pcie'] }.each do |name, (server, label)|
          interface = fetch_interface(name)
          named = tables.fetch('services').select { |service| service.fetch('interface') == interface || service.fetch('name') == name.b }
          invalid("a #{name} service is named #{name}, is of interface #{name} and is served by #{label} alone", 'service.server') unless
            named.all? { |service| service.fetch('interface') == interface && service.fetch('name') == name.b && service.fetch('server') == server }
        end
        grantees = ->(name) { facets_of(tables.fetch('facets'), name, tables).map { |row| row.values_at('grantee_kind', 'grantee') } }
        invalid('only the domain pcie holds a pci_bus facet', 'facet.grantee') unless
          grantees.call('pci_bus').all? { |grantee| grantee == [grantee_kind('domain'), pcie] }
        invalid('only the system domain holds a pcie facet', 'facet.grantee') unless
          grantees.call('pcie').all? { |kind, _| kind == grantee_kind('system') }
        holders = units.select { |_holder, rows| rows.any? { |device| device.fetch('selector') == @codec.member('mf_selector', 'pci') } }
                       .map { |holder, _rows| [grantee_kind('domain'), holder] }
        invalid('a configured domain holds a pci facet exactly when it holds a pci device', 'facet.grantee') unless
          grantees.call('pci').sort == holders.uniq.sort
      end

      def pcie_bridge?(device)
        device.fetch('selector') == @codec.member('mf_selector', 'dt') && device.fetch('role') == device_role('configuration')
      end

      def check_function(function, holder, bridges)
        invalid('a PCIe function is held by a configured domain', 'unit.holder') if holder == @codec.constant('mf_none')
        invalid('a PCIe function is unconfined in Phase 1', 'devices.dma') unless function.fetch('dma') == @codec.member('mf_dma', 'unconfined')
        return if bridges.include?(function['bridge'])

        invalid("a PCIe function's bridge #{function['bridge'].inspect} names no PCIe bridge the manifest places", 'devices.bridge')
      end

      # Property 8's windows (docs/design-abi.md, "Devices and partition windows"; PW1 of
      # docs/design-storage.md): a role abi/manifest.txt does not mark configured is the
      # slot writer's, the system domain's alone in Phase 1, and the one system window is
      # read-only and held by its block device's holder, the storage domain whose block
      # driver serves it, since the driver hands a window only to its own domain
      # (docs/design-fiasco.md, "The booted slot").
      def normalize_windows(tables)
        devices = tables.fetch('devices')
        rows = records('window').map do |record|
          role = window_role(record)
          slot_writer = !@codec.attribute?('mf_window_role', role, 'configured')
          invalid('only the system domain, the slot writer, holds the slot windows', 'window.holder') if
            slot_writer && !(one(record, 'holder').value == 'system' && !one(record, 'holder').quoted)
          device = window_device(record, devices)
          { 'holder' => holder_index(one(record, 'holder'), field: 'window.holder'),
            'device' => device, 'role' => role, 'partition' => window_partition(record, role),
            'rights' => window_rights(record, role), 'image' => window_image(record, role),
            'drive' => window_drive(record, role, devices.fetch(device)) }
            .tap { |row| check_image_device(row, tables.fetch('images')) }
        end
        check_system_window(rows, tables)
        check_record_volume_window(rows)
        check_drives(rows, tables)
        placed = rows.map { |row| row.values_at('device', 'role', 'partition', 'image', 'drive') }
        invalid('two windows name one role, partition and drive of a device', 'window.partition') unless placed.uniq.size == placed.size
        rows.sort_by { |row| row.values_at('holder', 'device', 'role', 'partition', 'image', 'drive') }
      end

      # Property 8's drive clause (docs/design-drives.md, "Manifest rows"): a drive window
      # names its drive, disk and its decimal number below mf_none, packed as the number;
      # every other window names none, packed as mf_none; and every window on a USB
      # controller is a drive window. A window lies on a block device or a USB controller
      # (window_device); which drives the windows name, and who holds them, is
      # check_drives', check_window_services' and check_drive_domains'.
      def window_drive(record, role, device)
        drive = role == drive_role
        invalid('a drive window names its drive, and no window of another role names one', 'window.drive') unless
          record.properties.key?('drive') == drive
        invalid('a window on a USB controller is a drive window', 'window.role') if
          device.fetch('role') == device_role('usb') && !drive
        return @codec.constant('mf_none') unless drive

        token = one(record, 'drive')
        none = @codec.constant('mf_none')
        number = token.value[/\Adisk(0|[1-9][0-9]*)\z/, 1]&.to_i unless token.quoted
        return number if number && number < none

        invalid("a drive is disk and a decimal number below #{none}", 'window.drive')
      end

      # Property 8's drive clauses (docs/design-drives.md, "Manifest rows"; docs/design-usb.md,
      # "Media and drives"): a drive number names one drive across the machine, so no two
      # windows name one; a block device's drive is the device's one window, the medium
      # its driver's domain serves whole; and the drive windows on all of one USB domain's
      # controllers name at most usb_drives_max drives, the media that domain serves at once.
      def check_drives(rows, tables)
        drives = rows.select { |row| row.fetch('role') == drive_role }
        twice, = drives.group_by { |row| row.fetch('drive') }.find { |_drive, named| named.size > 1 }
        invalid("drive disk#{twice} is named by two windows", 'window.drive') if twice
        on_block, on_usb = drives.map { |row| row.fetch('device') }
                                 .partition { |device| tables.fetch('devices').fetch(device).fetch('role') == device_role('block') }
        invalid('a block device with a drive window has no other window', 'window.device') if
          on_block.any? { |device| rows.count { |row| row.fetch('device') == device } > 1 }
        most = @codec.constant('usb_drives_max')
        invalid("a USB domain's controllers name more than #{most} drives", 'window.drive') if
          on_usb.group_by { |device| device_holder(tables, device) }.any? { |_holder, devices| devices.size > most }
      end

      # The domains a drive reaches (docs/design-drives.md, "Manifest rows" and "A drive and
      # its medium"), each held to an allow-list (holds_only), so that what parses a medium
      # never sits with a device or a stored file, and what drives a medium's device parses
      # nothing. The media domain, the configured domain that serves the service named
      # media, is named by nothing but its drive windows, its log facets and that service:
      # its drives' grants come through the windows, by introduction. The holder of a block
      # device's drive, a configured domain, is named by nothing but the unit that places
      # that device alone, its driver-control service, its pci facet and its log facets
      # (check_block_drive_holder). That every drive window is the media
      # domain's, and that a manifest with one holds one media service, is
      # check_window_services'.
      def check_drive_domains(tables)
        media_name = @codec.fixed_bytes('media_service')
        tables.fetch('services').select { |service| service.fetch('name') == media_name }.each do |media|
          domain = media.fetch('server')
          invalid('the media service is served by a configured domain', 'service.server') if domain == @codec.constant('mf_none')
          what = "the media domain, #{domain_name(tables, domain)}, holds nothing but drive windows, log facets and the media service"
          holds_only(tables, domain, what) do |scope, row|
            case scope
            when 'windows' then row.fetch('role') == drive_role
            when 'services' then row.equal?(media)
            else drive_domain_reference?(scope, row, tables)
            end
          end
        end
        tables.fetch('windows').select { |row| row.fetch('role') == drive_role }.each { |window| check_block_drive_holder(window, tables) }
      end

      # The holder of a block device's drive (check_drive_domains); a drive window on a USB
      # controller is the USB domain's, whose drives check_drives counts. Besides its
      # device's unit and its log facets, the holder serves one driver-control service,
      # the one every unit holder serves (docs/design-system.md, "The holder's
      # driver-control facet"), whose facets only the system domain holds
      # (normalize_facets), and holds a pci facet, of the system domain's service pci
      # (check_pcie_parties). That check admits a pci facet exactly when its grantee's
      # units hold a PCIe function, and this holder's units hold the drive's device
      # alone, so it holds one only when that device is a PCIe function, as an NVMe or a
      # virtio-blk-pci drive is.
      def check_block_drive_holder(window, tables)
        devices = tables.fetch('devices')
        device = devices.fetch(window.fetch('device'))
        return unless device.fetch('role') == device_role('block')

        label = "drive disk#{window.fetch('drive')}"
        holder = device_holder(tables, window.fetch('device'))
        invalid("the device of #{label} is held by a configured domain", 'unit.holder') if holder == @codec.constant('mf_none')
        control = fetch_interface('driver_control')
        controls = tables.fetch('services').select { |service| service.fetch('server') == holder && service.fetch('interface') == control }
        what = "the holder of #{label}, #{domain_name(tables, holder)}, holds nothing but its device's unit, " \
               'one driver-control service, a pci facet and log facets'
        holds_only(tables, holder, what) do |scope, row|
          case scope
          when 'units' then unit_devices(devices, row) == [device]
          when 'services' then row.equal?(controls.first)
          when 'facets' then facets_of([row], 'pci', tables).any? || drive_domain_reference?(scope, row, tables)
          else drive_domain_reference?(scope, row, tables)
          end
        end
      end

      # What either drive domain's allow-list admits besides its own rows: its place in
      # the boot order and its log facets, each of the service named log, of the log
      # interface and served by the system domain (docs/design-log.md, "The log facet"),
      # since the system domain picks a facet's callback by the service's name.
      def drive_domain_reference?(scope, row, tables)
        case scope
        when 'boot_order' then true
        when 'facets'
          service = tables.fetch('services').fetch(row.fetch('service'))
          service.values_at('name', 'interface', 'server') == ['log'.b, fetch_interface('log'), @codec.constant('mf_none')]
        else false
        end
      end

      def domain_name(tables, index) = tables.fetch('domains').fetch(index).fetch('name')

      # The holder of the unit that placed the device row at index.
      def device_holder(tables, index)
        device = tables.fetch('devices').fetch(index)
        tables.fetch('units').find { |unit| unit_devices(tables.fetch('devices'), unit).any? { |row| row.equal?(device) } }
              .fetch('holder')
      end

      # design-abi.md: a drive window names no partition, packed as mf_none, since it
      # covers whatever medium its drive holds, whole; every other role is a fixed-medium
      # role, whose window names partition 0, because the medium layout determines its
      # sectors.
      def window_partition(record, role)
        if role == drive_role
          invalid('a drive window names no partition', 'window.partition') if record.properties.key?('partition')
          return @codec.constant('mf_none')
        end
        invalid('a window of a fixed role names partition 0', 'window.partition') unless number(record, 'partition').zero?
        0
      end

      def window_rights(record, role)
        rights = flags(record, 'rights', 'mf_window_rights')
        read = @codec.member('mf_window_rights', 'read')
        invalid('a window grants at least read', 'window.rights') if (rights & read).zero?
        writable = @codec.attribute?('mf_window_role', role, 'writable')
        invalid('a window of a role not marked writable grants read alone', 'window.rights') if !writable && rights != read
        rights
      end

      # The system window is held by a storage domain, the configured domain that holds
      # the window's block device (docs/design-fiasco.md, "The booted slot"). How many
      # system windows there are, that one comes with its system_image row and that its
      # holder is a configured domain are the boot view's to judge (property 12).
      def check_system_window(rows, tables)
        rows.select { |row| row.fetch('role') == system_role }.each do |row|
          device = tables.fetch('devices').fetch(row.fetch('device')).fetch('path')
          invalid('a system window is held by the configured domain that holds its block device', 'window.holder') unless
            row.fetch('holder') == unit_holder(tables, device)
        end
      end

      # Root's login keys on the medium (docs/design-ssh.md, "Who publishes it"): the
      # record_volume window lies on the system window's block device, so the domain that
      # reads the record partition is the one whose block driver serves it. That there is
      # at most one, held by the system window's holder, is the boot view's to judge.
      def check_record_volume_window(rows)
        system = rows.find { |row| row.fetch('role') == system_role }
        invalid('the record_volume window lies on the system window\'s block device', 'window.device') if
          system && rows.any? { |row| row.fetch('role') == record_volume_role && row.fetch('device') != system.fetch('device') }
      end

      # A window lies on a block device, or on a USB controller, whose drives it names.
      def window_device(record, devices)
        named_device(text(record, 'device'), devices, roles: %w[block usb]) ||
          invalid('window names no block or USB device the manifest places', 'window.device')
      end

      # The index of the placed device a window, an image or a device-valued facet parameter
      # names (docs/design-abi.md, "Devices and partition windows"), of one of roles, or of
      # any role when roles is nil; nil when none. A device-tree device is named by its node
      # path and a PCIe function by its place, its host bridge's node path, bus, device and
      # function joined by colons, "/pcie@10000000:0:2:0", which no node path can be, since
      # a node path has no colon.
      def named_device(name, devices, roles: nil)
        place = PCI_PLACE.match(name)
        key = place ? [place[:bridge], *%i[bus device function].map { |part| Integer(place[part], 10) }] : name
        devices.index do |device|
          (roles.nil? || roles.any? { |role| device.fetch('role') == device_role(role) }) &&
            if place
              device.fetch('selector') == @codec.member('mf_selector', 'pci') && device.values_at('bridge', 'bus', 'device', 'function') == key
            else
              device.fetch('selector') == @codec.member('mf_selector', 'dt') && device['path'] == key
            end
        end
      end

      PCI_PLACE = /\A(?<bridge>[^:]+):(?<bus>0|[1-9][0-9]{0,2}):(?<device>0|[1-9][0-9]?):(?<function>[0-7])\z/

      def window_role(record)
        role = enum(record, 'role', 'mf_window_role')
        invalid('no vault partition until M11', 'window.role') if role == @codec.member('mf_window_role', 'vault')
        role
      end

      # design-abi.md: a verified-image window names an image-table index, and every
      # other role names none.
      def window_image(record, role)
        token = one(record, 'image')
        absent = !token.quoted && token.value == 'none'
        if role == image_role
          invalid('a verified-image window names its image', 'window.image') if absent
          reference_token(token, 'image', record.line)
        else
          invalid('only a verified-image window names an image', 'window.image') unless absent
          @codec.constant('mf_none')
        end
      end

      # A verified-image window lies on the device its image lies on, since the image's
      # extents are places on that device.
      def check_image_device(row, images)
        return if row.fetch('role') != image_role || images.fetch(row.fetch('image')).fetch('device') == row.fetch('device')

        invalid("a verified-image window names its image's device", 'window.device')
      end

      # An image's tree fields when the packer writes no tree.
      NO_TREE = { 'hash_block_size' => 0, 'hash_offset' => 0, 'hash_bytes' => 0, 'salt_length' => 0,
                  'hash_algorithm' => 0, 'salt' => Array.new(32, 0), 'root_hash' => Array.new(32, 0) }.freeze

      def image_role = @codec.member('mf_window_role', 'verified_image')

      def system_role = @codec.member('mf_window_role', 'system')
      def record_volume_role = @codec.member('mf_window_role', 'record_volume')
      def drive_role = @codec.member('mf_window_role', 'drive')

      # The image table and its extents (docs/design-fiasco.md, "The Phase 1 manifest
      # check"): each image is format erofs_unchecked, since the packer writes no hash
      # tree, so its record holds its data's length and extents, taken from the built
      # image its input artifact describes, and zeros for every tree field.
      def normalize_images(devices)
        block_size = @codec.constant('page_size')
        records('image').sort_by { |record| record.name.b }.each_with_object([[], []]) do |record, (images, extents)|
          invalid('image name is not a system identifier', 'image.name') unless record.name.match?(Frontend::IDENTIFIER)
          invalid('an image without a hash tree takes no salt', 'image.salt') if record.properties.key?('salt')
          placed = checked_extents(artifact(record, 'input', 'erofs_image', field: 'image.input'), field: 'image.input')
          bytes = placed.sum { |extent| extent.fetch('length') }
          invalid('an image is whole blocks', 'image.input') unless (bytes % block_size).zero?
          device = named_device(text(record, 'device'), devices, roles: %w[block]) || invalid('image names no block device the manifest places', 'image.device')
          images << { 'name' => record.name.b, 'device' => device,
                      'format' => @codec.member('mf_image_format', 'erofs_unchecked'),
                      'extents' => { 'table' => 'extents', 'first' => extents.size, 'count' => placed.size },
                      'data_bytes' => bytes, 'data_block_size' => block_size, 'data_blocks' => bytes / block_size }
                    .merge(NO_TREE)
          extents.concat(placed)
        end
      end

      # design-abi.md: nonempty, sorted and disjoint whole sectors, relative to the start of
      # the slot's system partition and inside it.
      def checked_extents(artifact, field:)
        sector = @codec.constant('mbr_sector_size')
        slot = @codec.constant('medium_system_sectors') * sector
        extents = artifact['extents']
        invalid('an image has at least one extent', field) unless extents.is_a?(Array) && !extents.empty?
        extents.each_with_object([]) do |extent, placed|
          offset, length = extent.values_at('slot_offset', 'length') if extent.is_a?(Hash)
          floor = placed.empty? ? 0 : placed.last.fetch('slot_offset') + placed.last.fetch('length')
          unless offset.is_a?(Integer) && length.is_a?(Integer) && length.positive? && offset >= floor &&
                 (offset % sector).zero? && (length % sector).zero? && offset + length <= slot
            invalid('image extents are sorted, disjoint whole sectors inside a slot', field)
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
          raise Invalid.new('table exceeds bound', field: name) if count > table.fetch(:maximum)
          cursor += (table.fetch(:alignment) - cursor % table.fetch(:alignment)) % table.fetch(:alignment)
          positions[name] = { 'offset' => cursor, 'count' => count }
          cursor += count * table.fetch(:type).size
        end
        raise Invalid.new('tables exceed manifest byte bound', field: 'length') if cursor > @reader.maximum
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
          raise Invalid.new('unknown normalized field', field: type.name)
        end
        type.fields.each_with_object({}) do |field, result|
          key = field.name
          next unless values.key?(key)
          value = values.fetch(key)
          if field.type.name == 'erx_mf_str'
            unless value.is_a?(String) && value.bytesize <= budget - strings.bytesize
              raise Invalid.new('string table exceeds bound', field: key)
            end
            result[key] = { 'offset' => value.empty? ? 0 : strings.bytesize, 'length' => value.bytesize }
            strings << value.b
          elsif field.type.name == 'erx_mf_span' && value.key?('table')
            table = @reader.tables.fetch(value.fetch('table'))
            extent = positions.fetch(value.fetch('table'))
            first = value.fetch('first')
            count = value.fetch('count')
            unless first.between?(0, extent.fetch('count')) && count.between?(0, extent.fetch('count') - first)
              raise Invalid.new('normalized slice is outside its table', field: key)
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
