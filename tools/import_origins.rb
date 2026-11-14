#!/usr/bin/env ruby
# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'optparse'
require_relative 'lib/erx/asn1_specifications'
require_relative 'lib/erx/bounded_file'
require_relative 'lib/erx/dependencies'
require_relative 'lib/erx/json_input'
require_relative 'lib/erx/origin'

module Erx
  # These are reviewed rules for the pinned imports, not a license detector
  # for arbitrary packages. Actual file SPDX notices always take precedence.
  module ImportOrigins
    MAX_PROFILE_BYTES = 1024 * 1024
    COMPONENTS = %w[otp musl openssl].freeze
    CHECKED_IN_PROFILES = %w[otp openssl].freeze
    # What the ASN.1 compiler writes into an application's src for each module its
    # specifications make: the Erlang, its header (for a module that declares a
    # record) and the type database.
    ASN1_OUTPUTS = %w[erl hrl asn1db].freeze
    module_function

    def musl_license_rules(root)
      rules = Dir.glob(File.join(root, '**/*')).each_with_object([]) do |absolute, selected|
        next unless File.file?(absolute) && !File.symlink?(absolute)
        path = absolute.delete_prefix(root + '/')
        next if path == 'ORIGIN.md'
        bytes = File.binread(absolute)
        next if bytes.include?("\0")
        normalized = bytes.gsub(/^[ \t]*\*[ \t]?/n, '').gsub(/\s+/n, ' ')
        licenses = []
        if normalized.include?('software is freely granted, provided that this notice is preserved')
          licenses << 'SunPro'
        end
        if normalized.include?('purpose with or without fee is hereby granted')
          licenses << 'ISC'
        end
        if normalized.include?('Redistribution and use in source and binary forms')
          licenses << (normalized.include?('Neither the name') ? 'BSD-3-Clause' : 'BSD-2-Clause')
        end
        next if licenses.empty?
        selected << { 'pattern' => path, 'license' => licenses.uniq.join(' AND '),
                      'evidence' => "reviewed license grant in #{path}; musl COPYRIGHT identifies this exception family" }
      end
      explicit = {
        'src/crypt/crypt_blowfish.c' => 'LicenseRef-musl-Solar-Designer',
        'src/crypt/crypt_md5.c' => 'LicenseRef-musl-public-domain AND BSD-2-Clause',
        'src/crypt/crypt_sha256.c' => 'LicenseRef-musl-public-domain',
        'src/crypt/crypt_sha512.c' => 'LicenseRef-musl-public-domain',
        'src/misc/fmtmsg.c' => 'LicenseRef-musl-public-domain'
      }
      explicit.map do |path, license|
        { 'pattern' => path, 'license' => license,
          'evidence' => "reviewed explicit public-domain dedication or fallback grant in #{path}; full notice retained" }
      end + rules
    end

    def write(root:, component:, dependencies: Dependencies, sources: Sources)
      raise Error, 'unsupported import component' unless COMPONENTS.include?(component)
      project = File.expand_path(root)
      directory = OutputDirectory.check(root: project, path: File.join(project, component))
      runner = Runner.new(owner_root: project, log_dir: File.join(project, 'build/logs'))
      declaration, archive = dependencies.new(root: project, runner: runner).archive_for(component)
      if File.exist?(File.join(directory, 'ORIGIN.md')) || File.symlink?(directory)
        raise Error, 'import already has an origin or is a symlink'
      end

      Dir.mktmpdir(".#{component}-origin-", project) do |temporary|
        extracted = File.join(temporary, 'unpacked')
        sources.unpack(archive: archive, sha256: declaration.fetch('sha256'),
                       destination: extracted, owner_root: temporary,
                       source_directory: declaration.fetch('directory'), runner: runner)
        selected = extracted
        verify_original_files(directory, original: selected)
        profile = import_profile(project, component: component, source: selected)
        exclusions = remove_exclusions(selected, profile: profile, component: component)
        Origin.new(root: selected).write(repository: profile.fetch('repository'),
                                         revision: profile.fetch('revision'),
                                         archive_sha256: declaration.fetch('sha256'),
                                         review: profile, exclusions: exclusions)
        publish_musl_profile(profile, root: project) if component == 'musl'
        publish_import(selected, destination: directory)
      end
    end

    # OTP's and OpenSSL's profiles are checked in; musl's is derived from its
    # notices and published beside them.
    def import_profile(project, component:, source:)
      if CHECKED_IN_PROFILES.include?(component)
        bytes = BoundedFile.read(File.join(project, "config/imports/#{component}.json"), maximum: MAX_PROFILE_BYTES)
        return JsonInput.parse(bytes, max_bytes: MAX_PROFILE_BYTES, label: "#{component} import profile")
      end

      { 'repository' => 'https://git.musl-libc.org/musl', 'revision' => 'v1.2.6',
        'default_license' => 'MIT', 'default_evidence' => 'reviewed musl COPYRIGHT package grant and no-notice original-file clause',
        'rules' => musl_license_rules(source), 'exclusions' => [] }
    end

    def publish_musl_profile(profile, root:)
      bytes = JSON.pretty_generate(profile) + "\n"
      directory = OutputDirectory.prepare(root: root, path: File.join(root, 'config/imports'))
      Dir.mktmpdir('.musl-profile-', directory) do |temporary|
        path = File.join(temporary, 'musl.json')
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o644) do |file|
          file.binmode
          file.write(bytes)
          file.flush
          file.fsync
        end
        File.rename(path, File.join(directory, 'musl.json'))
      end
    end
    private_class_method :publish_musl_profile

    def publish_import(prepared, destination:)
      # Keep the old tree outside automatic temporary-directory cleanup until
      # publication succeeds. A failed restore leaves a recoverable backup.
      backup = destination + ".origin-backup-#{Random.bytes(8).unpack1('H*')}"
      published = false
      begin
        File.rename(destination, backup)
        File.rename(prepared, destination)
        published = true
      ensure
        unless published
          begin
            File.rename(backup, destination) if File.exist?(backup) && !File.exist?(destination)
          rescue SystemCallError => error
            Terminal.puts("import restore failed; original retained at #{backup}: #{error.message}")
          end
        end
      end
      FileUtils.remove_entry(backup)
    end

    # What the import removes from the unpacked tree, each path with its reason, as
    # the origin record keeps them: the profile's exclusions, and for OTP alone two
    # more. Each application outside the profile's set goes first, so that an
    # exclusion beneath one finds nothing to take, and the ASN.1 compiler's output
    # in each application that stays goes last. The record lists the profile's
    # exclusions, the applications, then the compiler's output.
    def remove_exclusions(root, profile:, component:)
      exclude = -> { profile.fetch('exclusions').flat_map { |exclusion| remove_profile_exclusion(root, exclusion) } }
      return exclude.call unless component == 'otp'

      applications = select_otp_applications(root, applications: profile.fetch('applications'))
      exclude.call + applications + remove_asn1_outputs(root)
    end

    # OTP's archive carries the ASN.1 compiler's output prebuilt: ASN1_OUTPUTS for each
    # module the specifications in lib/<application>/asn1 make (Asn1Specifications).
    # erXos's runtime build generates it on the host, so what the archive holds of it
    # leaves, and a new specification needs no row in the profile.
    def remove_asn1_outputs(root)
      Dir.glob('lib/*/asn1', base: root).sort.flat_map do |asn1|
        directory = reach(root, asn1)
        unless File.directory?(directory) && !File.symlink?(directory)
          raise Error, "#{asn1} is something other than a directory of the archive"
        end

        source = File.join(File.dirname(asn1), 'src')
        Asn1Specifications.modules(directory).product(ASN1_OUTPUTS).filter_map do |name, extension|
          path = "#{source}/#{name}.#{extension}"
          next unless remove_exclusion(root, path)

          { 'path' => path,
            'reason' => "generated by OTP's ASN.1 compiler from #{asn1}; erXos's runtime build generates it on the host" }
        end
      end
    end
    private_class_method :remove_asn1_outputs

    # A profile exclusion names a path that leaves whole, or, with keep, a directory
    # each of whose entries leaves but those keep names, so the origin record lists
    # each entry that went. A whole path is recorded even where the archive lacks it;
    # a directory with keep must hold each name it keeps, unless the archive, or the
    # pruning of OTP's applications, lacks a directory above it.
    def remove_profile_exclusion(root, exclusion)
      case exclusion.is_a?(Hash) && exclusion.keys.sort
      when %w[path reason]
        remove_exclusion(root, exclusion.fetch('path'))
        [exclusion]
      when %w[keep path reason]
        remove_all_but(root, path: exclusion.fetch('path'), keep: exclusion.fetch('keep'), reason: exclusion.fetch('reason'))
      else
        raise Error, "invalid import exclusion #{exclusion.inspect}"
      end
    end
    private_class_method :remove_profile_exclusion

    def remove_all_but(root, path:, keep:, reason:)
      unless keep.is_a?(Array) && keep.all? { |name| name.is_a?(String) && !name.include?('/') }
        raise Error, "import exclusion #{path} keeps something other than names in it"
      end
      directory = reach(root, path)
      return [] unless directory
      unless File.directory?(directory) && !File.symlink?(directory)
        raise Error, "import exclusion #{path} keeps names in something other than a directory of the archive"
      end
      entries = Dir.children(directory).sort
      missing = keep - entries
      raise Error, "import exclusion #{path} keeps #{missing.join(', ')}, which the archive lacks" unless missing.empty?

      (entries - keep).map do |name|
        remove_exclusion(root, "#{path}/#{name}")
        { 'path' => "#{path}/#{name}", 'reason' => reason }
      end
    end
    private_class_method :remove_all_but

    # An excluded path leaves the unpacked tree whole, file or directory, so the
    # origin record lists nothing beneath it; a link at the end goes itself. True when
    # the archive held the path.
    def remove_exclusion(root, relative)
      path = reach(root, relative)
      return false unless path && present?(path)

      FileUtils.remove_entry(path)
      true
    end
    private_class_method :remove_exclusion

    # The place a profile path names: inside root and through no link the archive
    # holds, though the profile is checked in; nil when the archive lacks a
    # directory on the way.
    def reach(root, relative)
      if !relative.is_a?(String) || relative.start_with?('/') ||
         relative.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
        raise Error, "invalid import exclusion #{relative.inspect}"
      end

      parts = relative.split('/')
      parents = parts[0...-1].each_index.map { |index| File.join(root, *parts[0..index]) }
      parents.each do |parent|
        return nil unless present?(parent)
        next if File.directory?(parent) && !File.symlink?(parent)

        raise Error, "import exclusion #{relative} passes through a link or a file in the archive"
      end
      File.join(root, relative)
    end
    private_class_method :reach

    # A path the archive holds, a link to nowhere included.
    def present?(path) = File.exist?(path) || File.symlink?(path)
    private_class_method :present?

    def select_otp_applications(root, applications:)
      library = File.join(root, 'lib')
      Dir.children(library).sort.each_with_object([]) do |name, excluded|
        path = File.join(library, name)
        next unless File.directory?(path) && !applications.include?(name)
        FileUtils.remove_entry(path)
        excluded << { 'path' => "lib/#{name}",
                      'reason' => 'outside the shipped OTP application set in the runtime design' }
      end
    end

    def payload_paths(root)
      Dir.glob(File.join(root, '**/*'), File::FNM_DOTMATCH).each_with_object([]) do |path, selected|
        next unless File.file?(path) || File.symlink?(path)
        selected << path.delete_prefix(root + '/')
      end.sort
    end

    def verify_original_files(root, original:)
      paths = payload_paths(root)
      unless paths == payload_paths(original)
        raise Error, 'import source path set differs from the pinned release'
      end
      paths.each do |relative|
        path = File.join(root, relative)
        baseline = File.join(original, relative)
        same = if File.symlink?(path)
                 File.symlink?(baseline) && File.readlink(path) == File.readlink(baseline)
               else
                 !File.symlink?(baseline) &&
                   Digest::SHA256.file(path).hexdigest == Digest::SHA256.file(baseline).hexdigest
               end
        raise Error, "import differs from pinned original before attribution: #{relative}" unless same
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = { root: File.expand_path('..', __dir__) }
  parser = OptionParser.new do |arguments|
    arguments.banner = 'usage: ruby tools/import_origins.rb --component otp|musl|openssl [--root DIRECTORY]'
    arguments.on('--component NAME', Erx::ImportOrigins::COMPONENTS) { |value| options[:component] = value }
    arguments.on('--root DIRECTORY') { |value| options[:root] = value }
  end
  begin
    remaining = parser.parse(ARGV)
    raise OptionParser::MissingArgument, '--component' unless options[:component]
    raise OptionParser::InvalidArgument, remaining.join(' ') unless remaining.empty?
    Erx::ImportOrigins.write(**options)
    Erx::Terminal.puts("recorded #{options.fetch(:component)} origin")
  rescue OptionParser::ParseError => error
    Erx::Terminal.puts(error.message)
    exit 2
  rescue Erx::Error, SystemCallError => error
    Erx::Terminal.puts(error.message)
    exit 1
  end
end
