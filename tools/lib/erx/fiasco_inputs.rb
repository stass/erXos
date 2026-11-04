# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'find'
require 'tmpdir'
require 'set'
require_relative 'bounded_file'
require_relative 'json_input'
require_relative 'output_directory'

module Erx
  # One owner for the bytes consumed by kernel and user builds. The record
  # describes the private copy, never a later view of repository contents.
  class FiascoInputs
    # The inherited parts and their configuration, and the erXos sources the
    # stopgap kernel links: the C17 cores, their headers and the stack
    # proof's declarations (CoreArchive).
    ERXOS_ROOTS = %w[kernel include liberx].freeze
    ROOTS = (%w[fiasco config/fiasco] + ERXOS_ROOTS).freeze
    # The inputs only the kernel build reads; every other input is the user
    # build's. A change to one of them discards that build's outputs.
    KERNEL_INPUTS = %w[fiasco/kernel config/fiasco/kernel.defconfig kernel include].freeze
    MAX_FILE = 64 * 1024 * 1024
    MAX_TOTAL = 1024 * 1024 * 1024
    MAX_FILES = 100_000

    def initialize(root:)
      @project = File.realpath(root)
      @build = File.join(@project, 'build/fiasco')
      @directory = File.join(@build, 'inputs')
    end

    def prepare
      @verified = false
      prepare_build_directory
      current = inventory(@project)
      if File.exist?(@directory) || File.symlink?(@directory)
        record = checked_record
        verify_copy(record)
        return record if record.fetch('files') == current
      end
      Dir.mktmpdir('.inputs-', @build) do |temporary|
        staged = File.join(temporary, 'tree')
        FileUtils.mkdir_p(staged)
        File.chmod(0o700, staged)
        copied = inventory(@project, destination: staged)
        raise Error, 'Fiasco sources changed while capturing build inputs' unless copied == inventory(@project)
        record = { 'version' => 1, 'files' => copied, 'sha256' => identity(copied) }
        File.write(File.join(staged, 'RECORD.json'), JSON.generate(record) + "\n")
        File.chmod(0o444, File.join(staged, 'RECORD.json'))
        previous = File.join(temporary, 'previous')
        File.rename(@directory, previous) if File.exist?(@directory)
        begin
          File.rename(staged, @directory)
        rescue SystemCallError
          File.rename(previous, @directory) if File.exist?(previous)
          raise
        end
        record
      end
    rescue SystemCallError => error
      raise Error, "cannot capture Fiasco inputs: #{error.message}"
    end

    def verify
      @verified = false
      record = checked_record
      verify_copy(record)
      unless inventory(@project) == record.fetch('files')
        raise Error, 'Fiasco repository sources differ from the recorded build inputs; rebuild the image'
      end
      @snapshot_content.freeze
      @observations.freeze
      @aliases.freeze
      @verified = true
      record
    rescue SystemCallError => error
      raise Error, "cannot verify Fiasco inputs: #{error.message}"
    end

    # The private copy's root, laid out as the repository is, which the
    # cores' archive builds from.
    def tree
      @directory
    end

    def part(name)
      path('fiasco/' + name)
    end

    def configuration(name)
      path('config/fiasco/' + name)
    end

    def path(relative)
      unless relative.is_a?(String) && ROOTS.any? { |prefix| relative == prefix || relative.start_with?(prefix + '/') } &&
             relative.split('/').none? { |component| %w[. ..].include?(component) }
        raise Error, 'invalid Fiasco input path'
      end
      File.join(@directory, relative)
    end

    def reference
      bytes = BoundedFile.read(File.join(@directory, 'RECORD.json'), maximum: MAX_FILE)
      { 'path' => 'build/fiasco/inputs/RECORD.json', 'sha256' => Digest::SHA256.hexdigest(bytes) }
    end

    def read(path, maximum: MAX_FILE)
      raise Error, 'Fiasco inputs have not been checked' unless @verified
      canonical = @aliases[File.expand_path(path)]
      raise Error, 'file is absent from captured Fiasco inputs' unless canonical
      bytes = @snapshot_content.fetch(canonical)
      raise Error, 'captured Fiasco input exceeds its read limit' if bytes.bytesize > maximum
      bytes
    end

    def observations
      raise Error, 'Fiasco inputs have not been checked' unless @verified
      { 'entries' => @observations, 'aliases' => @aliases }.freeze
    end

    def authorize(path)
      raise Error, 'Fiasco inputs have not been checked' unless @verified
      expanded = File.expand_path(path)
      relative = expanded.delete_prefix(@directory + '/')
      unless expanded.start_with?(@directory + '/') && @snapshot_paths.include?(relative)
        raise Error, 'path is absent from captured Fiasco inputs'
      end
      expanded
    end

    def verified_hash(path)
      authorize(path)
      canonical = find_captured_path(path)
      raise Error, 'captured Fiasco input is not an ordinary file' unless canonical
      @observations.fetch(canonical).fetch('sha256')
    end

    def find_captured_path(path)
      return nil unless @verified
      @aliases[File.expand_path(path)]
    end

    def component_id(record, component:)
      selected = record.fetch('files').select do |relative, _entry|
        kernel = KERNEL_INPUTS.any? { |input| relative == input || relative.start_with?(input + '/') }
        component == 'kernel' ? kernel : !kernel
      end
      identity(selected)
    end

    private

    def prepare_build_directory
      OutputDirectory.prepare(root: @project, path: @build)
    end

    def checked_record
      raise Error, 'Fiasco input tree is a symlink' if File.symlink?(@directory)
      path = File.join(@directory, 'RECORD.json')
      unless File.realpath(@directory) == @directory && !File.symlink?(path)
        raise Error, 'Fiasco input record is linked'
      end
      bytes = BoundedFile.read(path, maximum: MAX_FILE)
      record = JsonInput.parse(bytes, max_bytes: MAX_FILE, label: 'Fiasco input record')
      unless record.is_a?(Hash) && record.keys.sort == %w[files sha256 version] && record['version'] == 1 &&
             record['files'].is_a?(Hash) && record['sha256'] == identity(record.fetch('files'))
        raise Error, 'invalid Fiasco input record'
      end
      record
    end

    def verify_copy(record)
      actual = inventory(@directory, snapshot: true)
      unless actual == record.fetch('files')
        raise Error, 'private Fiasco inputs differ from their build record; recreate the build directory'
      end
      @snapshot_paths = actual.keys.to_set.freeze
    end

    def identity(files)
      Digest::SHA256.hexdigest(JSON.generate(files))
    end

    def inventory(base, destination: nil, snapshot: false)
      bytes = 0
      selected = {}
      if snapshot
        @snapshot_content = {}
        @observations = {}
        @aliases = {}
      end
      roots = snapshot ? [''] : ROOTS
      roots.each do |relative_root|
        start = relative_root.empty? ? base : File.join(base, relative_root)
        unless File.directory?(start) && !File.symlink?(start) && File.realpath(start) == start
          raise Error, "missing or linked Fiasco input directory: #{relative_root}"
        end
        if !snapshot && relative_root.include?('/')
          parent = File.dirname(relative_root)
          selected[parent] = { 'kind' => 'directory' }
          FileUtils.mkdir_p(File.join(destination, parent)) if destination
        end
        Find.find(start) do |absolute|
          next if snapshot && absolute == base
          relative = absolute.delete_prefix(base + '/')
          next if snapshot && relative == 'RECORD.json'
          stat = File.lstat(absolute)
          target = destination && File.join(destination, relative)
          if stat.symlink?
            link = File.readlink(absolute)
            resolved = File.realpath(absolute)
            unless !link.start_with?('/') && resolved.start_with?(start + '/')
              raise Error, "Fiasco input link leaves its source tree: #{relative}"
            end
            selected[relative] = { 'kind' => 'symlink', 'target' => link }
            @aliases[absolute.freeze] = resolved.freeze if snapshot && File.file?(resolved)
            if target
              FileUtils.mkdir_p(File.dirname(target))
              File.symlink(link, target)
            end
          elsif stat.file?
            content = BoundedFile.read(absolute, maximum: MAX_FILE)
            bytes += content.bytesize
            raise Error, 'Fiasco build inputs exceed their byte limit' if bytes > MAX_TOTAL
            selected[relative] = { 'kind' => 'file', 'sha256' => Digest::SHA256.hexdigest(content),
                                   'executable' => stat.mode & 0o111 }
            if snapshot
              canonical = absolute.freeze
              @snapshot_content[canonical] = content
              @observations[canonical] = { 'path' => canonical, 'size' => content.bytesize,
                                          'sha256' => selected.fetch(relative).fetch('sha256').freeze }.freeze
              @aliases[canonical] = canonical
            end
            if target
              FileUtils.mkdir_p(File.dirname(target))
              File.binwrite(target, content)
              File.chmod(0o444 | (stat.mode & 0o111), target)
              File.utime(stat.atime, stat.mtime, target)
            end
          elsif stat.directory?
            selected[relative] = { 'kind' => 'directory' }
            FileUtils.mkdir_p(target) if target
          else
            raise Error, "unsupported Fiasco build input type: #{relative}"
          end
          raise Error, 'too many Fiasco build inputs' if selected.size > MAX_FILES
        end
      end
      selected.sort.to_h
    end
  end
end
