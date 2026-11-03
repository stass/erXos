#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/origin'
require_relative 'lib/erx/fiasco'
require_relative 'import_origins'

module Erx
  # Attribution for the frozen stopgap pins. Publisher package declarations
  # cover files without their own notice; explicit per-file grants win.
  module FiascoOrigins
    module_function

    def package_rules(directory)
      declarations = File.read(File.join(directory, 'LICENSE.spdx')).split(/^PackageName: /)
      declarations.each_with_object([]) do |declaration, rules|
        path = declaration[/^PackageFileName: \.\/(.+)$/, 1]
        license = declaration[/^PackageLicenseConcluded: (.+)$/, 1]
        next unless path && license && File.exist?(File.join(directory, path))
        rules << { 'pattern' => "#{path}/**/*", 'license' => license,
                   'evidence' => "reviewed LICENSE.spdx package declaration for #{path}" }
      end.sort_by { |rule| -rule.fetch('pattern').bytesize }
    end

    def explicit_grant_rules(directory)
      Dir.glob(File.join(directory, '**/*'), File::FNM_DOTMATCH).each_with_object([]) do |absolute, rules|
        next unless File.file?(absolute) && !File.symlink?(absolute)
        path = absolute.delete_prefix(directory + '/')
        next if path == 'ORIGIN.md'
        bytes = File.binread(absolute)
        next if bytes.include?("\0")
        normalized = bytes.byteslice(0, 16_384).gsub(/^[ \t]*\*[ \t]?/n, '').gsub(/\s+/n, ' ')
        license = if normalized.include?('Copying and distribution of this file') &&
                        normalized.include?('without royalty') && normalized.include?('this notice are preserved')
                    'FSFAP'
                  elsif normalized.include?('This file is subject to the terms and conditions of the GNU General Public License 2.')
                    'GPL-2.0-only'
                  elsif normalized.include?('This file is distributed under the terms of the GNU General Public License, version 2.') &&
                        normalized.include?('COPYING-GPL-2 file for details.')
                    'GPL-2.0-only'
                  elsif normalized.include?('GCC Runtime Library Exception') &&
                        normalized.include?('GNU General Public License')
                    'GPL-3.0-or-later WITH GCC-exception-3.1'
                  end
        next unless license
        rules << { 'pattern' => path, 'license' => license,
                   'evidence' => "reviewed explicit grant in #{path}; complete notice retained" }
      end
    end

    def profile(directory, part:)
      corrections = [
        ['GPL-2.0-only or License-Ref-kk-custom', 'GPL-2.0-only'],
        ['GPL-2.0-only OR License-Ref-kk-custom', 'GPL-2.0-only'],
        ['GPL-2.0', 'GPL-2.0-only'],
        ['GPL-2.0+', 'GPL-2.0-or-later'],
        ['GPL-2.0 WITH Linux-syscall-note', 'GPL-2.0-only WITH Linux-syscall-note']
      ].map do |declared, selected|
        { 'pattern' => '**/*', 'declared_license' => declared, 'license' => selected,
          'evidence' => 'reviewed exact header declaration; standard GPL version selected; no custom grant asserted' }
      end
      rules = corrections + explicit_grant_rules(directory)
      if part == 'l4re-core'
        nested = File.join(directory, 'libc/musl/contrib/musl')
        rules.concat(ImportOrigins.musl_license_rules(nested).map do |rule|
          rule.merge('pattern' => 'libc/musl/contrib/musl/' + rule.fetch('pattern'),
                     'evidence' => "reviewed musl 1.2.5 grant: #{rule.fetch('evidence')}")
        end)
        rules << { 'pattern' => 'libc/musl/**/*', 'license' => 'MIT',
                   'evidence' => 'reviewed embedded musl COPYRIGHT and original-file MIT grant; specific exceptions precede this rule' }
      end
      rules.concat(package_rules(directory))
      rules.unshift('pattern' => 'LICENSE.spdx', 'license' => 'CC0-1.0',
                    'evidence' => 'LICENSE.spdx DataLicense: CC0-1.0')
      { 'default_license' => 'MIT',
        'default_evidence' => 'reviewed LICENSE.spdx root package declaration; specific file and package grants take precedence',
        'rules' => rules }
    end

    def write(root:, kernel_archive:, core_archive:, cache:, part: nil)
      project = File.expand_path(root)
      source_root = OutputDirectory.check(root: project, path: File.join(project, 'fiasco'))
      facts = JsonInput.parse(BoundedFile.read(File.join(source_root, 'IMPORTS.json'), maximum: 1_048_576),
                              max_bytes: 1_048_576, label: 'Fiasco import records')
      validate_identities(facts)
      runner = Runner.new(owner_root: project, log_dir: File.join(project, 'build/logs'))
      facts.each do |fact|
        name = fact.fetch('part')
        next if part && part != name
        directory = OutputDirectory.check(root: project, path: File.join(source_root, name))
        raise Error, "external source part: #{name}" if File.symlink?(directory)
        output = File.join(directory, 'ORIGIN.md')
        raise Error, "origin already exists: #{name}" if File.exist?(output) || File.symlink?(output)
        archive = case name
                  when 'kernel' then File.expand_path(kernel_archive)
                  when 'l4re-core' then File.expand_path(core_archive)
                  else cached_archive(cache, fact: fact)
                  end
        parent = OutputDirectory.prepare(root: project, path: File.join(project, 'build'))
        Dir.mktmpdir('.fiasco-origin-', parent) do |temporary|
          unpacked = File.join(temporary, 'original')
          Sources.unpack(archive: archive, sha256: fact.fetch('archive_sha256'),
                         destination: unpacked, owner_root: temporary,
                         source_directory: %w[kernel l4re-core].include?(name) ? '.' : "#{name}-#{fact.fetch('revision')}",
                         runner: runner)
          original = unpacked
          excluded = project_selection(original, current: directory)
          prepare_origin(original, fact: fact, exclusions: excluded)
          File.link(File.join(original, 'ORIGIN.md'), output)
        end
        origin = Origin.new(root: directory)
        begin
          origin.check
        rescue Error
          File.unlink(output)
          raise
        end
      end
    rescue JSON::ParserError => error
      raise Error, "invalid Fiasco import identities: #{error.message}"
    end

    def prepare_origin(directory, fact:, exclusions:)
      Origin.new(root: directory).write(repository: fact.fetch('repository'),
                                         revision: fact.fetch('revision'),
                                         archive_sha256: fact.fetch('archive_sha256'),
                                         review: profile(directory, part: fact.fetch('part')),
                                         exclusions: exclusions)
    end

    def cached_archive(cache, fact:)
      filename = "#{fact.fetch('part')}-#{fact.fetch('revision')}.tar.gz"
      paths = Dir.glob(File.join(File.expand_path(cache), '**', filename))
      raise Error, "expected one pinned archive for #{fact.fetch('part')}" unless paths.size == 1
      paths.first
    end

    # Build the baseline from verified upstream bytes, keeping exactly the
    # selected path set. Current edits cannot silently become the baseline.
    def project_selection(original, current:)
      current_paths = ImportOrigins.payload_paths(current).reject { |path| path == 'ORIGIN.md' }
      original_paths = ImportOrigins.payload_paths(original)
      unknown = current_paths - original_paths
      raise Error, "new file in initial Fiasco import: #{unknown.first}" unless unknown.empty?
      excluded = original_paths - current_paths
      excluded.each { |path| File.unlink(File.join(original, path)) }
      directories = Dir.glob(File.join(original, '**/*'), File::FNM_DOTMATCH)
                       .select { |path| File.directory?(path) && !File.symlink?(path) }
                       .reject { |path| ['.', '..'].include?(File.basename(path)) }
      directories.sort_by(&:bytesize).reverse_each { |path| Dir.rmdir(path) if Dir.empty?(path) }
      excluded.map { |path| { 'path' => path, 'reason' => 'outside the frozen bootstrap, sigma0 and kernel source selection' } }
    end

    def validate_identities(facts)
      expected = {
        'kernel' => [Fiasco::KERNEL_COMMIT, Fiasco::KERNEL_SHA256],
        'l4re-core' => [Fiasco::CORE_COMMIT, Fiasco::CORE_SHA256]
      }.merge(Fiasco::ARCHIVES.transform_values { |pin| [pin.fetch('commit'), pin.fetch('sha256')] })
      unless facts.is_a?(Array) && facts.size == expected.size &&
             facts.all? { |fact| fact.is_a?(Hash) && fact.keys.sort == %w[archive_sha256 part repository revision] }
        raise Error, 'invalid frozen Fiasco import identities'
      end
      actual = facts.to_h { |fact| [fact.fetch('part'), [fact.fetch('revision'), fact.fetch('archive_sha256')]] }
      raise Error, 'frozen Fiasco import identity mismatch' unless actual == expected
      facts.each do |fact|
        repository = fact.fetch('part') == 'kernel' ? 'fiasco' : fact.fetch('part')
        unless fact.fetch('repository') == "https://github.com/kernkonzept/#{repository}"
          raise Error, 'frozen Fiasco repository mismatch'
        end
      end
    end

  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path('..', __dir__) }
  parser = OptionParser.new do |arguments|
    arguments.banner = 'usage: ruby tools/fiasco_origins.rb --kernel-archive FILE --core-archive FILE --cache DIRECTORY'
    arguments.on('--kernel-archive FILE') { |value| options[:kernel_archive] = value }
    arguments.on('--core-archive FILE') { |value| options[:core_archive] = value }
    arguments.on('--cache DIRECTORY') { |value| options[:cache] = value }
    arguments.on('--root DIRECTORY') { |value| options[:root] = value }
    arguments.on('--part NAME', %w[kernel l4re-core mk bootstrap libfdt drivers-frst]) { |value| options[:part] = value }
  end
  begin
    remaining = parser.parse(ARGV)
    %i[kernel_archive core_archive cache].each do |name|
      raise OptionParser::MissingArgument, "--#{name.to_s.tr('_', '-')}" unless options[name]
    end
    raise OptionParser::InvalidArgument, remaining.join(' ') unless remaining.empty?
    Erx::FiascoOrigins.write(**options)
    Erx::Terminal.puts('recorded frozen Fiasco origins')
  rescue OptionParser::ParseError => error
    Erx::Terminal.puts(error.message)
    exit 2
  rescue Erx::Error, SystemCallError, KeyError => error
    Erx::Terminal.puts(error.message)
    exit 1
  end
end
