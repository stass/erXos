# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'error'
require_relative 'oracle'
require_relative 'runtime'

module Erx
  # The system release's files as entries for Pack#build: `kernel` and `stdlib`'s beams
  # and application files with a start.boot of their own, as docs/design-runtime.md's
  # Configuration starts them. The hosted archive (Release) and the native one
  # (ProductionImage) both take their files from here, each from its own build of the
  # two applications, and `+deterministic` makes those builds the same bytes.
  class ReleaseFiles
    APPLICATIONS = %w[kernel stdlib].freeze
    NAME = 'erxos'
    BOOT_DEADLINE = 120
    # A file of the release: its path in the archive, the built file and what it came from.
    ReleaseFile = Data.define(:path, :artifact, :sources)

    # otp is the built OTP copy; directory is where start.boot and the receipts go.
    def initialize(root:, otp:, directory:, runner:, codec:, oracle: Oracle.new(root: root, runner: runner))
      @root = root
      @otp = otp
      @directory = directory
      @runner = runner
      @codec = codec
      @oracle = oracle
    end

    # Each file as an entry for Pack#build, with its receipt written.
    def entries
      FileUtils.mkdir_p(@directory)
      [*application_files, boot_file].map { |file| file_entry(file) }
    end

    # The files a pack's build inputs must name for these entries.
    def self.inputs_of(entries) = entries.flat_map { |entry| [entry.fetch('artifact'), entry.fetch('receipt')] }

    private

    def application_files
      APPLICATIONS.flat_map do |application|
        ebin = File.join(@otp, 'lib', application, 'ebin')
        directory = "system/lib/#{application}-#{version(application)}/ebin"
        Dir.glob('*.{beam,app}', base: ebin).sort.map do |name|
          ReleaseFile.new(path: "#{directory}/#{name}", artifact: File.join(ebin, name), sources: sources_of(application, name))
        end
      end
    end

    # The source a built file is compiled from. A file with none named is a failure, so
    # no file reaches the archive without its licence.
    def sources_of(application, name)
      source = File.join(@root, 'otp/lib', application, 'src')
      base = File.basename(name, '.*')
      return [File.join(source, "#{base}.app.src")] if name.end_with?('.app')

      found = %w[erl yrl xrl].map { |extension| File.join(source, "#{base}.#{extension}") }.find { |path| File.file?(path) } ||
              Dir.glob(File.join(@root, 'otp/lib', application, '**', "#{base}.erl")).min
      raise Error, "no source in otp/lib/#{application} for #{name}" unless found

      [found]
    end

    def version(application)
      text = File.read(File.join(@otp, 'lib', application, 'ebin', "#{application}.app"))
      text[/\{vsn,\s*"([^"]+)"\}/, 1] or raise Error, "#{application}.app names no version"
    end

    def erts_version
      File.read(File.join(@otp, 'erts/vsn.mk'))[/^VSN\s*=\s*(\S+)/, 1] or raise Error, 'erts/vsn.mk names no version'
    end

    # OTP's own generator: systools on the stock host build of the same release, which
    # writes the boot script from the release file and the applications' own .app files.
    def boot_file
      release = File.join(@directory, 'start.rel')
      applications = APPLICATIONS.map { |application| "{#{application},\"#{version(application)}\"}" }.join(',')
      File.write(release, "{release,{\"#{NAME}\",\"1\"},{erts,\"#{erts_version}\"},[#{applications}]}.\n")
      paths = APPLICATIONS.map { |application| "\"#{File.join(@otp, 'lib', application, 'ebin')}\"" }.join(',')
      name = File.join(@directory, 'start')
      expression = "ok=systools:make_script(\"#{name}\",[{path,[#{paths}]},no_dot_erlang,no_warn_sasl]),halt()."
      @runner.run([@oracle.erl_path(Runtime::HOST_OTP_FLAVOUR), '-noshell', '-noinput', '-eval', expression],
                  name: 'release-boot-script', deadline: BOOT_DEADLINE, chdir: @directory, env: Oracle::CLEAN_ERLANG_ENV)
      ReleaseFile.new(path: 'system/bin/start.boot', artifact: "#{name}.boot",
                      sources: APPLICATIONS.map { |application| File.join(@root, 'otp/lib', application, 'src', "#{application}.app.src") })
    end

    def file_entry(file)
      receipt = File.join(@directory, 'receipts', "#{file.path.tr('/', '_')}.json")
      FileUtils.mkdir_p(File.dirname(receipt))
      File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(file.artifact),
                                               'sources' => file.sources.map { |source| reference(source) }))
      { 'path' => file.path, 'kind' => @codec.member('entry_kind', 'file'), 'flags' => @codec.member('entry_flags', 'system'),
        'id' => file.path, 'artifact' => file.artifact, 'receipt' => receipt }
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
