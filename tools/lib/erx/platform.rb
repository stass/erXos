# frozen_string_literal: true

require_relative 'error'
require_relative 'json_input'

module Erx
  # A board's platform record (config/platforms/NAME.json) and the manifests beside it
  # (config/manifest/NAME-development.txt, NAME-site.txt): what every tool that builds or
  # boots an image takes as a parameter in place of one board's constants
  # (docs/design-stopgap.md, "The Raspberry Pi 4"). The record states the board's RAM, its
  # first address (ram_first) and size (ram_bytes, the smallest RAM the port boots on), the
  # part of it Fiasco keeps (fiasco_reserve), and its device units, which Pack's manifest
  # check reads. A record without one of these numbers, or with one that is not a whole
  # number of MiB, is refused when it is loaded, before any tool uses it.
  Platform = Data.define(:name, :record)
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

    # The record's fields in whole MiB, each checked at construction.
    MIB_FIELDS = { 'ram_first' => 0.., 'ram_bytes' => 1.., 'fiasco_reserve' => 1.. }.freeze

    def initialize(name:, record:)
      raise Error, "#{self.class.record_path(name)}: a platform record is a JSON object" unless record.is_a?(Hash)
      raise Error, "#{self.class.record_path(name)}: names #{record['name'].inspect}, not #{name}" unless record['name'] == name
      raise Error, "#{self.class.record_path(name)}: units must be a list" unless record['units'].is_a?(Array)

      MIB_FIELDS.each do |field, mib|
        bytes = record.fetch(field) { raise Error, "#{self.class.record_path(name)}: no #{field}" }
        raise Error, "#{self.class.record_path(name)}: #{field} must be a whole number of MiB in #{mib}" unless
          bytes.is_a?(Integer) && (bytes % (1 << 20)).zero? && mib.cover?(bytes >> 20)
      end
      raise Error, "#{self.class.record_path(name)}: fiasco_reserve must be less than ram_bytes" unless
        record.fetch('fiasco_reserve') < record.fetch('ram_bytes')

      super
    end

    def record_path = self.class.record_path(name)
    def manifest_path = "config/manifest/#{name}-development.txt"
    # The website's manifest: the development manifest without its web domain, which
    # `tools/erx boot --without-web` builds the site's image from (InteractiveBoot).
    def site_manifest_path = "config/manifest/#{name}-site.txt"
    def manifest_source(root) = File.binread(File.join(root, manifest_path))

    # RAM's first address, where the root's place is counted from (ProductionImage::Machine).
    def ram_first = record.fetch('ram_first')
    def memory_mib = record.fetch('ram_bytes') >> 20
    def fiasco_reserve_mib = record.fetch('fiasco_reserve') >> 20
  end
end
