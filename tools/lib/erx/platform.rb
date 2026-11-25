# frozen_string_literal: true

require_relative 'error'
require_relative 'pin_table'
require_relative 'json_input'
require_relative 'manifest_edit'

module Erx
  # A board's platform record (config/platforms/NAME.json) and its development manifest, the
  # common part (config/manifest/development.txt) followed by the board's
  # (config/manifest/NAME-development.txt), with the website's made from it: what every tool that builds or
  # boots an image takes as a parameter in place of one board's constants
  # (docs/design-fiasco.md, "The Raspberry Pi 4"). The record states the board's RAM, its
  # first address (ram_first) and size (ram_bytes, the development machine's RAM, ProductionImage::Machine.development), the
  # part of it Fiasco keeps (fiasco_reserve), what the boot keeps besides from the rest
  # (root_withheld, in bytes, which the packer's archive check reads), and its device units,
  # which Pack's manifest check reads, and, for a board the website boots, the configured
  # domains its site manifest leaves out (site_leaves_out). A record without one of these
  # numbers, with a RAM number that is not a whole number of MiB, with a root_withheld that
  # is not a positive number of bytes, or with a site_leaves_out that is not a list of
  # domain names, is refused when it is loaded, before any tool uses it. A board's header
  # map, the record's pins, is checked as the record loads too (PinTable); pins is the
  # checked map, nil for a board without one. A board whose cards hold one ARM clock names it
  # in whole megahertz (arm_clock_hz, BoardClock).
  Platform = Data.define(:name, :record, :pins)
  class Platform
    # The board the QEMU harnesses and `tools/erx` build for when no caller names another:
    # QEMU's virt machine, the development target.
    DEVELOPMENT_NAME = 'qemu-virt'

    def self.load(root:, name:)
      raise Error, "a platform name is lower-case letters, digits and dashes, not #{name.inspect}" unless
        name.is_a?(String) && name.match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)

      path = File.join(root, record_path(name))
      record = JsonInput.parse(File.binread(path), max_bytes: 65_536, label: "platform record #{record_path(name)}")
      new(name: name, record: record)
    rescue Errno::ENOENT
      raise Error, "no platform record #{record_path(name)}"
    end

    def self.development(root) = load(root: root, name: DEVELOPMENT_NAME)

    def self.record_path(name) = "config/platforms/#{name}.json"

    # The part of RAM Fiasco keeps as its kernel memory on erXos's build (64-bit,
    # CONFIG_KMEM_SIZE_AUTO, no -kmemsize option): 6% of the free memory it counts, at
    # most 3328 MiB (fiasco/kernel/src/kern/config.cpp, Config::kmem_size with the 64bit
    # kmem_per_cent and kmem_max), rounded up to the 2 MiB superpage
    # (kern/kmem_alloc.cpp, Kmem_alloc::determine_kmem_alloc_size, which
    # arm/kmem_alloc-arm.cpp's Kmem_alloc::Kmem_alloc calls with SUPERPAGE_SIZE). Fiasco
    # counts less than all of RAM free, so on ram_bytes this bounds what it takes. A record's
    # fiasco_reserve is checked equal to it, and every other machine derives its own from it.
    FIASCO_KMEM_PER_CENT = 6
    FIASCO_KMEM_MAX = 3328 << 20
    FIASCO_SUPERPAGE = 2 << 20

    def self.fiasco_reserve(ram_bytes)
      kmem = [ram_bytes / 100 * FIASCO_KMEM_PER_CENT, FIASCO_KMEM_MAX].min
      (kmem + FIASCO_SUPERPAGE - 1) / FIASCO_SUPERPAGE * FIASCO_SUPERPAGE
    end

    # Every key a record may hold; a key outside this list, a stale or a misspelled one, is
    # refused, since the reader would otherwise go on without what the key was meant to say.
    KEYS = %w[arm_clock_hz console cpuset fiasco_reserve firmware_requests hostlink msi_frame name pins ram_bytes ram_first
              root_withheld site_leaves_out units].freeze

    # The record's fields in whole MiB, each checked at construction.
    MIB_FIELDS = { 'ram_first' => 0.., 'ram_bytes' => 1.., 'fiasco_reserve' => 1.. }.freeze

    def initialize(name:, record:)
      raise Error, "#{self.class.record_path(name)}: a platform record is a JSON object" unless record.is_a?(Hash)
      raise Error, "#{self.class.record_path(name)}: names #{record['name'].inspect}, not #{name}" unless record['name'] == name
      raise Error, "#{self.class.record_path(name)}: units must be a list" unless record['units'].is_a?(Array)
      unknown = record.keys - KEYS
      raise Error, "#{self.class.record_path(name)}: unknown key #{unknown.first.inspect}" unless unknown.empty?

      clock = record['arm_clock_hz']
      raise Error, "#{self.class.record_path(name)}: arm_clock_hz must be a positive whole number of megahertz" unless
        clock.nil? || (clock.is_a?(Integer) && clock.positive? && (clock % 1_000_000).zero?)

      MIB_FIELDS.each do |field, mib|
        bytes = record.fetch(field) { raise Error, "#{self.class.record_path(name)}: no #{field}" }
        raise Error, "#{self.class.record_path(name)}: #{field} must be a whole number of MiB in #{mib}" unless
          bytes.is_a?(Integer) && (bytes % (1 << 20)).zero? && mib.cover?(bytes >> 20)
      end
      reserve = self.class.fiasco_reserve(record.fetch('ram_bytes'))
      raise Error, "#{self.class.record_path(name)}: fiasco_reserve must be Fiasco's kernel memory on ram_bytes, " \
                   "#{reserve >> 20} MiB" unless record.fetch('fiasco_reserve') == reserve
      withheld = record.fetch('root_withheld') { raise Error, "#{self.class.record_path(name)}: no root_withheld" }
      raise Error, "#{self.class.record_path(name)}: root_withheld must be a positive number of bytes" unless
        withheld.is_a?(Integer) && withheld.positive?
      leaves_out = record['site_leaves_out']
      raise Error, "#{self.class.record_path(name)}: site_leaves_out must be a list of distinct domain names" unless
        !record.key?('site_leaves_out') ||
        (leaves_out.is_a?(Array) && !leaves_out.empty? && leaves_out.uniq.size == leaves_out.size &&
         leaves_out.all? { |domain| domain.is_a?(String) && domain.match?(/\A[a-z0-9][a-z0-9_-]{0,62}\z/) })

      pins = begin
        PinTable.read(record)
      rescue Error => e
        raise Error, "#{self.class.record_path(name)}: pins: #{e.message}"
      end
      super(name: name, record: record, pins: pins)
    end

    # The records every board's development manifest takes.
    COMMON_MANIFEST_PATH = 'config/manifest/development.txt'

    def record_path = self.class.record_path(name)
    # The board's part of its development manifest: what it does not share with the
    # other boards (its machine record, its system principal's memory, its own devices'
    # units and windows and the domains whose rows name them), which is no manifest alone.
    def manifest_path = "config/manifest/#{name}-development.txt"
    # The board's development manifest, the one text the packer accepts and the board
    # boots: the common part, then the board's (docs/design-fiasco.md, "The Phase 1
    # manifest check"). The encoder sorts every table, so the order of the two parts
    # does not reach the image.
    def manifest_source(root) = [COMMON_MANIFEST_PATH, manifest_path].map { |path| File.binread(File.join(root, path)) }.join
    # The website's manifest, which only a board the website boots has: the development
    # manifest without its apps row (Manifest::Edit.without_apps; docs/design-packaging.md,
    # "The apps row": the site has no room for the row's memory, nor always a display for
    # its services to name) and without the domains the record's site_leaves_out names,
    # each taken out with the room it took (Manifest::Edit.without_domain), which `tools/erx boot
    # --without-web` builds the site's image from (InteractiveBoot) and the medium boots
    # start from (MediumBoot). It is made from the development manifest each time it is
    # read, so it never differs from it in anything but those domains and the apps row,
    # which it leaves out with its budget and its domains (Manifest::Edit.without_apps), so the
    # website's image takes no package (docs/design-packaging.md, "The shipped
    # manifests"). keep names domains
    # of site_leaves_out a harness keeps in, as the display suite keeps the display domain.
    # A board whose record has no site_leaves_out is refused on use, never handed its
    # development manifest.
    def site_manifest_source(root, keep: [])
      leaves_out = record.fetch('site_leaves_out') do
        raise Error, "the #{name} board's record #{record_path} has no site_leaves_out, so no website image or medium boot"
      end
      raise Error, "the site manifest leaves out no #{(keep - leaves_out).join(', ')} to keep" unless (keep - leaves_out).empty?

      (leaves_out - keep).reduce(Manifest::Edit.without_apps(manifest_source(root))) do |source, domain|
        Manifest::Edit.without_domain(source, domain, units: record.fetch('units'))
      end
    end

    # RAM's first address, where the root's place is counted from (ProductionImage::Machine).
    def ram_first = record.fetch('ram_first')
    def memory_mib = record.fetch('ram_bytes') >> 20
    # What a boot keeps from RAM less fiasco_reserve besides the archive and the pool's
    # page index, in bytes (Manifest::RootStartup.boot_kept).
    def root_withheld = record.fetch('root_withheld')
  end
end
