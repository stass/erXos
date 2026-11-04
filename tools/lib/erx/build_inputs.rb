# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require_relative 'bounded_file'
require_relative 'origin'
require_relative 'import_notices'

module Erx
  # Only trusted build/import owners construct catalogs. Artifact JSON can
  # reference these immutable observations, but cannot register another path.
  # Roots locate names; the exact catalog entries grant the content reads.
  class BuildInputs
    MAX_FILE_BYTES = 512 * 1024 * 1024

    def self.capture(root:, paths:, within: nil)
      root = File.realpath(root)
      entries = {}
      aliases = {}
      paths.each do |value|
        expanded = File.expand_path(value, root)
        canonical = File.realpath(expanded)
        if within && !canonical.start_with?(File.realpath(within) + '/')
          raise Error, 'imported input escapes its registered source tree'
        end
        hash = Digest::SHA256.new
        size = nil
        File.open(canonical, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
          unless input.stat.file? && input.size <= MAX_FILE_BYTES
            raise Error, 'build input must be a bounded ordinary file'
          end
          size = input.size
          remaining = size
          while remaining.positive?
            bytes = input.read([remaining, 65_536].min)
            raise Error, 'build input changed during capture' if bytes.nil? || bytes.empty?
            hash.update(bytes)
            remaining -= bytes.bytesize
          end
          raise Error, 'build input changed during capture' unless input.size == size
        end
        entry = { 'path' => canonical.freeze, 'size' => size, 'sha256' => hash.hexdigest.freeze }.freeze
        raise Error, 'build input changed between observations' if entries.key?(canonical) && entries.fetch(canonical) != entry
        entries[canonical] = entry
        aliases[expanded.freeze] = canonical
        aliases[canonical] = canonical
      end
      new(root: root, entries: entries, aliases: aliases, imports: {})
    rescue SystemCallError, IOError => error
      raise Error, "cannot capture build inputs: #{error.class}"
    end

    # Origin#check walks the whole tree and refuses a file that is neither an
    # inventory row nor an erXos addition, so a catalog comes back only when
    # every file it records has passed that one check.
    def self.imported(root:)
      root = File.realpath(root)
      metadata = capture(root: root, paths: ['ORIGIN.md'])
      entries = metadata.instance_variable_get(:@entries).dup
      aliases = metadata.instance_variable_get(:@aliases).dup
      checked = Origin.new(root: root, read_bytes: lambda do |path|
        canonical = File.realpath(path)
        raise Error, 'imported input escapes its registered tree' unless canonical.start_with?(root + '/')
        bytes = BoundedFile.read(canonical, maximum: MAX_FILE_BYTES)
        entry = { 'path' => canonical.freeze, 'size' => bytes.bytesize,
                  'sha256' => Digest::SHA256.hexdigest(bytes).freeze }.freeze
        raise Error, 'imported input changed during checking' if entries.key?(canonical) && entries.fetch(canonical) != entry
        entries[canonical] = entry
        aliases[File.expand_path(path, root).freeze] = canonical
        aliases[canonical] = canonical
        bytes
      end).check
      new(root: root, entries: entries, aliases: aliases, imports: { root => freeze_value(checked) })
    end

    # Immutable input-tree owners may hand off their actual open/read/hash
    # observations and checked Origin inventories. This is a trusted producer
    # API, never a decoder for receipt/report data. The owner has verified the
    # complete read-only tree, including links, so no per-file realpath walk or
    # second whole-tree hash is needed here.
    def self.observed(root:, entries:, aliases:, imports:)
      root = File.realpath(root)
      unless entries.is_a?(Hash) && aliases.is_a?(Hash) && imports.is_a?(Hash)
        raise Error, 'invalid owned input observations'
      end
      entries.each do |path, entry|
        unless path.is_a?(String) && path.start_with?(root + '/') && File.expand_path(path) == path &&
               entry.is_a?(Hash) && entry.keys.sort == %w[path sha256 size] && entry['path'] == path &&
               entry['size'].is_a?(Integer) && entry['size'].between?(0, MAX_FILE_BYTES) &&
               entry['sha256'].is_a?(String) && entry['sha256'].match?(/\A[0-9a-f]{64}\z/)
          raise Error, 'invalid owned file observation'
        end
      end
      aliases.each do |path, target|
        unless path.is_a?(String) && path.start_with?(root + '/') && File.expand_path(path) == path && entries.key?(target)
          raise Error, 'owned alias does not name an observed file'
        end
      end
      imports.each_key do |path|
        unless path.is_a?(String) && (path == root || path.start_with?(root + '/'))
          raise Error, 'checked import is outside its input owner'
        end
      end
      canonical_aliases = entries.keys.to_h { |path| [path, path] }.merge(aliases)
      new(root: root, entries: copy_value(entries), aliases: copy_value(canonical_aliases), imports: copy_value(imports))
    end

    def self.copy_value(value)
      case value
      when Hash then value.to_h { |key, member| [copy_value(key), copy_value(member)] }.freeze
      when Array then value.map { |member| copy_value(member) }.freeze
      when String then value.dup.freeze
      when Integer, TrueClass, FalseClass, NilClass then value
      else raise Error, 'unsupported owned observation value'
      end
    end
    private_class_method :copy_value

    # Fixed project licence/profile inputs are selected by the pack builder,
    # not by receipt fields. Every additional document is an explicit reviewed
    # profile reference whose hash must agree before the catalog is returned.
    def self.pack(root:, paths:)
      root = File.realpath(root)
      profile_path = File.join(root, 'config/provenance/import-notices.json')
      support = [File.join(root, 'LICENSE')]
      support << profile_path if File.file?(profile_path)
      catalog = capture(root: root, paths: paths + support)
      if support.include?(profile_path)
        profile = ImportNotices.parse(catalog.read(profile_path, maximum: 1024 * 1024))
        documents = ImportNotices.documents(profile)
        catalog = catalog.merge(capture(root: root, paths: documents.map { |document| document.fetch('path') }))
        documents.each { |document| catalog.authorize(document.fetch('path'), expected: document.fetch('sha256')) }
      end
      catalog
    end

    def self.freeze_value(value)
      case value
      when Hash then value.each { |key, member| freeze_value(key); freeze_value(member) }
      when Array then value.each { |member| freeze_value(member) }
      end
      value.freeze
    end
    private_class_method :freeze_value

    def initialize(root:, entries:, aliases:, imports:)
      @root = root.freeze
      @entries = entries.freeze
      @aliases = aliases.freeze
      @imports = imports.freeze
      freeze
    end
    private_class_method :new

    def merge(other)
      raise Error, 'build inputs can merge only another checked catalog' unless other.is_a?(BuildInputs)
      entries = @entries.merge(other.instance_variable_get(:@entries)) do |_path, left, right|
        raise Error, 'conflicting checked build input' unless left == right
        left
      end
      aliases = @aliases.merge(other.instance_variable_get(:@aliases)) do |_path, left, right|
        raise Error, 'conflicting checked input alias' unless left == right
        left
      end
      imports = @imports.merge(other.instance_variable_get(:@imports)) do |_root, left, right|
        raise Error, 'conflicting checked import inventory' unless left == right
        left
      end
      self.class.send(:new, root: @root, entries: entries, aliases: aliases, imports: imports)
    end

    def authorize(value, expected: nil)
      unless value.is_a?(String) && value.bytesize.between?(1, 4096) && !value.include?("\0")
        raise Error, 'invalid build input path'
      end
      expanded = File.expand_path(value, @root)
      canonical = @aliases[expanded]
      resolved = File.realpath(expanded)
      if canonical
        raise Error, 'checked build input alias changed' unless resolved == canonical
      elsif @entries.key?(resolved)
        canonical = resolved
      else
        raise Error, 'build record path is not authorized by its input catalog'
      end
      entry = @entries.fetch(canonical)
      if expected && entry.fetch('sha256') != expected
        raise Error, 'build record hash differs from its checked input catalog'
      end
      canonical
    rescue SystemCallError => error
      raise Error, "checked build input is unavailable: #{error.class}"
    end

    def entry(path)
      @entries.fetch(authorize(path))
    end

    def include_path?(path)
      expanded = File.expand_path(path, @root)
      @aliases.key?(expanded) || @entries.key?(expanded)
    end

    def find_import(root)
      @imports[File.realpath(root)]
    end

    def read(path, maximum:)
      canonical = authorize(path)
      expected = @entries.fetch(canonical)
      raise Error, 'checked input exceeds its read bound' if expected.fetch('size') > maximum
      bytes = BoundedFile.read(canonical, maximum: maximum)
      unless bytes.bytesize == expected.fetch('size') && Digest::SHA256.hexdigest(bytes) == expected.fetch('sha256')
        raise Error, 'checked build input changed after capture'
      end
      bytes
    end

    def verify(path)
      canonical = authorize(path)
      expected = @entries.fetch(canonical)
      hash = Digest::SHA256.new
      File.open(canonical, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |input|
        unless input.stat.file? && input.size == expected.fetch('size')
          raise Error, 'checked build input type or size changed'
        end
        remaining = expected.fetch('size')
        while remaining.positive?
          bytes = input.read([remaining, 65_536].min)
          raise Error, 'checked build input was truncated' if bytes.nil? || bytes.empty?
          hash.update(bytes)
          remaining -= bytes.bytesize
        end
        unless input.size == expected.fetch('size') && hash.hexdigest == expected.fetch('sha256')
          raise Error, 'checked build input changed after capture'
        end
      end
      expected
    rescue SystemCallError, IOError => error
      raise Error, "cannot verify checked build input: #{error.class}"
    end

    def verify_all
      @aliases.each_key { |path| authorize(path) }
      @entries.each_key { |path| verify(path) }
      self
    end
  end
end
