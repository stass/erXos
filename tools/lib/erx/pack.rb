# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require 'fileutils'
require_relative 'elf_plan'
require_relative 'pack_provenance'
require_relative 'pack_wire'

module Erx
  # Owns the full build transaction. Input snapshots, source attribution and
  # whole-manifest admission precede publication; an invalid result never
  # replaces a previously published image. ELF parsing stays in erx_elf_plan.
  # domain_planner is the manifest check's DomainPlanner, which a manifest with
  # configured domains needs; without one such a manifest fails closed.
  class Pack
    DEFAULT_BUDGET = 256 * 1024 * 1024

    def initialize(root:, output_root:, codec:, planner:, checker:, hasher:, runner:, provenance:, domain_planner: nil)
      @root = File.realpath(root)
      @output_root = File.realpath(output_root)
      @codec = codec
      @planner = planner
      @domain_planner = domain_planner
      unless checker.is_a?(PackTools::Helper) && checker.tool == 'checker'
        raise Error, 'pack checking requires a helper owned by PackTools.build'
      end
      @checker = checker
      unless hasher.is_a?(PackTools::Helper) && hasher.tool == 'hasher'
        raise Error, 'pack hashing requires a helper owned by PackTools.build'
      end
      @hasher = PackHasher.new(helper: hasher, runner: runner)
      @runner = runner
      @provenance = provenance
    end

    # An entry names an artifact plus its trusted build receipt. Generated
    # manifest and notices entries belong to this funnel and cannot be supplied.
    # test_code marks the archive a test image (PackWire#write).
    def build(entries:, root_path:, build_kind:, platform:, artifacts:,
              manifest_source:, output:, budget: DEFAULT_BUDGET, test_code: false)
      require_relative 'manifest'
      unless budget.is_a?(Integer) && budget.between?(1, 512 * 1024 * 1024)
        raise Error, 'invalid pack host budget'
      end
      raise Error, 'invalid pack build kind' unless %w[development release].include?(build_kind)
      raise Error, 'invalid pack test-code mark' unless [true, false].include?(test_code)
      destination = File.expand_path(output)
      directory = OutputDirectory.prepare(root: @output_root, path: File.dirname(destination))
      destination = File.join(directory, File.basename(destination))
      Dir.mktmpdir('.erx-pack-', File.dirname(destination)) do |workspace|
        rows, records = snapshot(entries, workspace: workspace, budget: budget, build_kind: build_kind)
        generated_path = @codec.fixed_bytes('system_manifest_path')
        notices_path = 'system/NOTICES'.b
        if rows.any? { |row| [generated_path, notices_path].include?(row.fetch('path')) }
          raise Error, 'artifact conflicts with a reserved generated path'
        end
        system = @codec.member('entry_flags', 'system')
        file_kind = @codec.member('entry_kind', 'file')
        rows << { 'path' => generated_path, 'kind' => file_kind, 'flags' => system,
                  'source' => { 'kind' => 'generated', 'producer' => 'manifest' } }
        rows << { 'path' => notices_path, 'kind' => file_kind, 'flags' => system,
                  'source' => { 'kind' => 'generated', 'producer' => 'notices' } }
        rows.sort_by! { |row| row.fetch('path').b }
        validate_paths(rows)
        root_entry = rows.index { |row| row.fetch('path') == root_path.b }
        raise Error, 'root image is absent from the pack' unless root_entry
        catalog = rows.map { |row| row.reject { |key, _| %w[snapshot size plan].include?(key) }.freeze }.freeze
        context = Manifest::Context.new(build_kind: build_kind, platform: platform,
                                        catalog: catalog, root_entry: root_entry,
                                        artifacts: artifacts, provenance: records)
        admitted = Manifest.admit(source: manifest_source, codec: @codec, context: context, planner: @domain_planner)
        unless admitted.is_a?(Manifest::Admitted) && admitted.matches?(context)
          raise Error, 'system manifest is not admitted for this pack'
        end
        generated = { generated_path => admitted.bytes, notices_path => @provenance.notices(records, budget: budget) }
        rows.each do |row|
          next unless row.fetch('source').fetch('kind') == 'generated'
          path = File.join(workspace, row.fetch('source').fetch('producer'))
          File.binwrite(path, generated.fetch(row.fetch('path')))
          row['snapshot'] = path
          row['size'] = File.size(path)
        end
        temporary = File.join(workspace, 'image.pack')
        write(rows, root_entry: root_entry, build_kind: build_kind,
              path: temporary, budget: budget, test_code: test_code)
        # Bootstrap reserves the archive in whole pages, which sigma0 then never offers.
        Manifest::RootStartup.check_archive(archive_bytes: round_page(File.size(temporary)),
                                            root_memory: admitted.report.fetch('root_memory'),
                                            **Manifest::RootStartup.archive_machine(platform))
        @checker.run([temporary], runner: @runner, name: 'pack-check', deadline: 300)
        hash = Digest::SHA256.file(temporary).hexdigest
        size = File.size(temporary)
        File.rename(temporary, destination)
        return { 'path' => destination, 'sha256' => hash, 'size' => size,
                 'entries' => rows.size, 'manifest' => admitted.report,
                 'provenance' => context.provenance }.freeze
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOSPC, Errno::EISDIR => error
      raise Error, "cannot build pack: #{error.message}"
    end

    private

    def snapshot(entries, workspace:, budget:, build_kind:)
      unless entries.is_a?(Array) && entries.size.between?(1, @codec.constant('pack_entries_max') - 2)
        raise Error, 'invalid pack entry count'
      end
      records = {}
      total = 0
      staged_bytes = 0
      rows = entries.each_with_index.map do |entry, index|
        next directory_row(entry) if entry.is_a?(Hash) && entry['kind'] == @codec.member('entry_kind', 'directory')
        unless entry.is_a?(Hash) && (entry.keys - %w[path kind flags artifact receipt id jit]).empty? &&
               [nil, true].include?(entry['jit'])
          raise Error, 'invalid pack artifact fields'
        end
        raise Error, 'only an image entry makes JIT objects' if entry.key?('jit') && entry['kind'] != @codec.member('entry_kind', 'image')
        if entry.key?('jit') && entry['flags'].is_a?(Integer) && entry['flags'].anybits?(@codec.member('entry_flags', 'system'))
          raise Error, "the system domain's image makes no JIT objects"
        end

        path = entry.fetch('path')
        raise Error, 'invalid pack artifact path' unless path.is_a?(String)
        original = File.expand_path(entry.fetch('artifact'), @root)
        closure = @provenance.resolve(receipt: entry.fetch('receipt'), artifact: original,
                                      build_kind: build_kind, notice_budget: budget)
        closure.each do |record|
          key = record.fetch('path')
          raise Error, 'conflicting artifact provenance' if records.key?(key) && records[key] != record
          records[key] = record
        end
        target = File.join(workspace, "artifact-#{index}")
        File.open(original, File::RDONLY | File::NONBLOCK) do |source|
          raise Error, 'pack artifact must be a regular file' unless source.stat.file?
          remaining = budget - staged_bytes
          raise Error, 'pack source staging exceeds host budget' if source.size > remaining
          File.open(target, 'wb', 0o600) do |destination|
            copied = IO.copy_stream(source, destination, remaining + 1)
            raise Error, 'pack source staging exceeds host budget' if copied > remaining
            staged_bytes += copied
          end
        end
        hash = Digest::SHA256.file(target).hexdigest
        unless hash == @provenance.artifact_hash(original)
          raise Error, 'artifact changed during its snapshot'
        end
        # Recheck receipt binding to the immutable bytes actually consumed.
        unless closure == @provenance.resolve(receipt: entry.fetch('receipt'), artifact: original,
                                              build_kind: build_kind, notice_budget: budget)
          raise Error, 'artifact provenance changed during its snapshot'
        end
        row = { 'path' => path.b.freeze, 'kind' => entry.fetch('kind'), 'flags' => entry.fetch('flags'),
                'source' => { 'kind' => 'artifact', 'id' => entry.fetch('id'), 'sha256' => hash }.freeze,
                'snapshot' => target }
        if row.fetch('kind') == @codec.member('entry_kind', 'image')
          plan = @planner.call(target, budget: budget - total)
          row['image'] = image_manifest(plan, jit: entry.fetch('jit', false))
          row['size'] = plan.fetch('output_size')
          row['plan'] = plan
        elsif row.fetch('kind') == @codec.member('entry_kind', 'file')
          row['size'] = File.size(target)
        else
          raise Error, 'unknown pack entry kind'
        end
        total += round_page(row.fetch('size'))
        raise Error, 'pack payload exceeds host budget' if total > budget
        row
      end
      [rows, records.values.sort_by { |record| record.fetch('path').b }.freeze]
    rescue KeyError => error
      raise Error, "missing pack artifact field: #{error.key}"
    end

    # An empty directory, a mount point with nothing under it in the archive: a path, a
    # kind and flags, and no artifact, since it has no contents to build or attribute.
    def directory_row(entry)
      unless entry.keys.sort == %w[flags kind path] && entry['path'].is_a?(String) && entry['flags'].is_a?(Integer)
        raise Error, 'an empty directory entry is its path, kind and flags'
      end
      { 'path' => entry.fetch('path').b.freeze, 'kind' => entry.fetch('kind'), 'flags' => entry.fetch('flags'),
        'source' => { 'kind' => 'directory' }.freeze, 'size' => 0 }
    end

    # An entry that declares jit is an image the build makes JIT objects with, the
    # BeamAsm runtime image, and its manifest alone carries ERX_IMAGE_JIT
    # (docs/design-kernel.md, "Image manifests"); the planner never sets it.
    def image_manifest(plan, jit:)
      flags = plan.fetch('flags') | (jit ? @codec.member('image_flags', 'jit') : 0)
      PackWire.new(codec: @codec).image_manifest(plan.merge('flags' => flags))
    end

    def validate_paths(rows)
      pending = []
      previous = nil
      strings_size = 0
      rows.each do |row|
        path = row.fetch('path')
        text = path.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding? && path.bytesize.between?(1, @codec.constant('pack_path_max')) &&
               path.bytes.none? { |byte| byte < 32 || byte == 127 } &&
               path.split('/', -1).none? { |part| ['', '.', '..'].include?(part) }
          raise Error, 'invalid pack path'
        end
        raise Error, 'duplicate pack path' if previous && previous >= path
        pending.pop while !pending.empty? && !path.start_with?(pending.last)
        raise Error, 'pack file is a path prefix' if !pending.empty? && path.start_with?(pending.last + '/')
        pending << path
        previous = path
        strings_size += path.bytesize
      end
      raise Error, 'pack strings exceed their bound' if strings_size > @codec.constant('pack_strings_max')
    end

    def write(rows, root_entry:, build_kind:, path:, budget:, test_code:)
      File.open(path, 'w+b', 0o600) do |output|
        PackWire.new(codec: @codec, hasher: @hasher).write(rows: rows, root_entry: root_entry, build_kind: build_kind,
                                                         output: output, budget: budget, test_code: test_code)
        output.flush
        output.fsync
      end
    end

    def round_page(value)
      page = @codec.constant('page_size')
      ((value + page - 1) / page) * page
    end
  end
end
