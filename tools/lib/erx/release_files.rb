# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'erlang_apps'
require_relative 'error'
require_relative 'manifest'
require_relative 'oracle'
require_relative 'runtime'

module Erx
  # The system release's files as entries for Pack#build: the beams, application files
  # and headers of the OTP applications the runtime builds (Runtime::APPLICATIONS) and of
  # erXos's own (ErlangApps), with a start.boot of their own that starts them, as
  # docs/design-runtime.md's Configuration does, or only loads them (LOAD_ONLY). The
  # headers ship so that code compiled on erXos finds them through include_lib, as on
  # stock. The hosted archive (Release) and the native one (ProductionImage) both take
  # their files from here, each from its own build of the applications, and
  # `+deterministic` makes those builds the same bytes. The one domain release (domain)
  # is laid out the same way under domains/erxos/, from the same builds, without the
  # system mark: each file of the applications its boot scripts name, once, and a boot
  # script bin/<name>.boot for each name (domain_boot), whose release file lists only
  # that script's applications.
  class ReleaseFiles
    # In the release file's order, each after the applications it depends on.
    APPLICATIONS = [*Runtime::APPLICATIONS, *ErlangApps::APPLICATIONS].freeze
    # Loaded, not started: the release file gives them start type load, so the boot
    # script loads their .app files and puts them on the code path, and the shell has
    # c:c and dbg, but nothing of theirs runs at boot. Started, runtime_tools would
    # start runtime_tools_sup and its ttb_autostart.
    LOAD_ONLY = %w[compiler runtime_tools].freeze
    # A name here that the release does not ship would leave that application started.
    raise Error, "LOAD_ONLY names what the release does not ship: #{LOAD_ONLY - APPLICATIONS}" unless
      (LOAD_ONLY - APPLICATIONS).empty?
    # Started with start type temporary, so that their end is reported and the system
    # domain goes on. The network stack parses network input, and it runs in the system
    # domain until the network domain exists (docs/design-stopgap.md), so a crash loop in
    # it ends the stack, never the system domain.
    TEMPORARY = %w[erx_net].freeze
    # A domain's own applications: the system release ships them, so that a domain
    # boot script can take them, and every release only loads them, so that none runs in the
    # system domain and none starts before its domain's facets: the session template's
    # arguments start erx_session with -eval, which runs once init has them
    # (docs/design-runtime.md, edit 65).
    DOMAIN_ONLY = %w[erx_session].freeze
    raise Error, "DOMAIN_ONLY names what the release does not ship: #{DOMAIN_ONLY - APPLICATIONS}" unless
      (DOMAIN_ONLY - APPLICATIONS).empty?
    raise Error, "TEMPORARY names what the release does not ship: #{TEMPORARY - APPLICATIONS}" unless
      (TEMPORARY - APPLICATIONS).empty?

    NAME = 'erxos'
    BOOT_DEADLINE = 120
    # A file of the release: its path in the archive, the built file and what it came from.
    ReleaseFile = Data.define(:path, :artifact, :sources)

    # Which release the files are: its name in its release files, the prefix its paths
    # take in the archive, its applications in the release file's order, whether its
    # files carry the system mark, which only the system release's do
    # (docs/design-kernel.md, "The boot image"), and its boot scripts: for each name,
    # bin/<name>.boot, whose release file names the applications given, in that order.
    Release = Data.define(:name, :prefix, :applications, :system, :boots)
    SYSTEM = Release.new(name: NAME, prefix: 'system/', applications: APPLICATIONS, system: true,
                         boots: { 'start' => APPLICATIONS }.freeze)
    # Where the one domain release lies: domains/erxos/, which sorts after boot/ and
    # before system/, so it is one run of whole entries that does not split the system
    # run (docs/design-stopgap.md, "The production image").
    DOMAINS_PREFIX = 'domains/'
    DOMAIN_PREFIX = "#{DOMAINS_PREFIX}#{NAME}/".freeze
    # What every domain boots: kernel and stdlib, which a release boots through, and erx
    # and erx_files, whose processes erXos's kernel_sup and kernel_safe_sup start in every
    # domain (its watchdog's child, its namespace table, /tmp and /proc).
    DOMAIN_BASE = %w[kernel stdlib erx erx_files].freeze

    # One boot script of the domain release: its name, which a domain row's
    # `release @artifact.NAME` names, the applications it boots, and whether it is a test
    # image's, which alone may boot a test-only application (ErlangApps::TEST_ONLY).
    DomainBoot = Data.define(:name, :applications, :test) do
      def initialize(name:, applications:, test: false) = super
    end
    # Every application a test image's domain boot script may take, in release order.
    TEST_APPLICATIONS = [*APPLICATIONS, *ErlangApps::TEST_ONLY].freeze

    # The boot script named name, of applications, which the system release ships too,
    # DOMAIN_BASE among them, since a release boots through it. A name is a manifest
    # identifier, so a domain row's @artifact.NAME names the script, and it is one path
    # component. Only a test script, test true, which only a test image carries
    # (ProductionImage's test entry point), boots a test-only application.
    def self.domain_boot(name, applications:, test: false)
      raise Error, "a domain boot script's name is an identifier, not #{name.inspect}" unless
        name.is_a?(String) && name.match?(Manifest::Frontend::IDENTIFIER) && !name.include?('/')
      tests = applications & ErlangApps::TEST_ONLY
      raise Error, "only a test image's domain boot script boots a test-only application: #{tests.join(', ')}" unless
        test || tests.empty?
      unknown = applications - TEST_APPLICATIONS
      raise Error, "a domain boot script boots only applications the runtime builds, not #{unknown.join(', ')}" unless unknown.empty?
      missing = DOMAIN_BASE - applications
      raise Error, "a domain boot script boots what every domain's kernel starts: #{missing.join(', ')}" unless missing.empty?

      DomainBoot.new(name: name, applications: (TEST_APPLICATIONS & applications).freeze, test: test)
    end

    # The one domain release: each file of boots' applications once, and a boot script
    # for each of boots, so a domain boots only its own script's applications while the
    # archive stores what the scripts share once. Each of boots is one domain_boot made,
    # and two of one name are refused.
    def self.domain(boots)
      raise Error, 'a domain release has a boot script' if boots.empty?
      raise Error, 'a domain boot script is one ReleaseFiles.domain_boot made' unless
        boots.all? { |boot| boot.is_a?(DomainBoot) && boot == domain_boot(boot.name, applications: boot.applications, test: boot.test) }
      raise Error, 'two domain boot scripts share a name' unless boots.map(&:name).uniq.size == boots.size

      Release.new(name: NAME, prefix: DOMAIN_PREFIX, applications: (TEST_APPLICATIONS & boots.flat_map(&:applications)).freeze,
                  system: false, boots: boots.sort_by(&:name).to_h { |boot| [boot.name, boot.applications] }.freeze)
    end

    # What a domain row's release names in an archive's sorted paths: each boot script
    # of the domain release, domains/erxos/bin/<name>.boot, as artifact <name>, which is
    # the release's whole run of entries (the index of its first entry and its count of
    # files), so every name gives the one slice and a row's name picks only its script.
    # The paths ascend strictly, so the release is one run; a list out of order is
    # refused, and so is a file under domains/ outside the release or a release with no
    # boot script.
    def self.domain_runs(paths)
      raise Error, 'archive paths must ascend strictly' unless paths.each_cons(2).all? { |left, right| left.b < right.b }

      run = paths.each_index.select { |index| paths[index].b.start_with?(DOMAINS_PREFIX) }
      stray = run.map { |index| paths[index] }.find { |path| !path.b.start_with?(DOMAIN_PREFIX) }
      raise Error, "#{stray} is not in the domain release" if stray
      return {}.freeze if run.empty?

      slice = { 'kind' => 'release', 'entry' => run.first, 'files' => run.size }.freeze
      names = run.filter_map { |index| paths[index].b[%r{\A#{DOMAIN_PREFIX}bin/([^/]+)\.boot\z}o, 1] }
      raise Error, 'the domain release has no boot script' if names.empty?

      names.to_h { |name| [name, slice] }.freeze
    end

    # otp is the built OTP copy; directory is where each boot script, under
    # boot/<name>/, and the receipts go;
    # release is which release they are, the system release unless a domain's is asked.
    def initialize(root:, otp:, directory:, runner:, codec:, oracle: Oracle.new(root: root, runner: runner), release: SYSTEM)
      raise Error, 'a release is a ReleaseFiles::Release' unless release.is_a?(Release)

      @root = root
      @otp = otp
      @directory = directory
      @runner = runner
      @codec = codec
      @oracle = oracle
      @release = release
    end

    # Each file as an entry for Pack#build, with its receipt written.
    def entries
      FileUtils.mkdir_p(@directory)
      [*application_files, *boot_files].map { |file| file_entry(file) }
    end

    # The files a pack's build inputs must name for these entries: each built file and its
    # receipt, and the sources the receipts name in erXos's own applications among
    # applications, the release's, test-only ones included. OTP's sources are in its
    # imported tree's catalog already.
    def self.inputs_of(entries, root:, applications: ErlangApps::APPLICATIONS)
      own = applications.select { |application| ErlangApps.own?(application) }
      [*entries.flat_map { |entry| [entry.fetch('artifact'), entry.fetch('receipt')] }, *ErlangApps.sources(root: root, applications: own)]
    end

    # What one application ships, as paths under its directory to the files they copy:
    # its beams and .app from the build at otp, no .appup since an update replaces a whole
    # slot, and its headers (headers). The release and the oracle's hosted tree both lay
    # an application out from here.
    def self.application_layout(root:, otp:, application:)
      ebin = File.join(otp, 'lib', application, 'ebin')
      built = Dir.glob('*.{beam,app}', base: ebin).sort.map { |name| ["ebin/#{name}", File.join(ebin, name)] }
      [*built, *headers(root: root, application: application).map { |header| ["include/#{File.basename(header)}", header] }]
    end

    # An application's headers: the plain files include/*.hrl at the top of its include/
    # in the tree. Nothing builds them, so each ships as it is and is its own source. A
    # subdirectory does not ship, nor does a generated header, which is in build/gen; a
    # link is refused, so no header ships another file's bytes under its name.
    def self.headers(root:, application:)
      include = File.join(root, source_directory(application), 'include')
      Dir.glob('*.hrl', base: include).sort.map do |name|
        path = File.join(include, name)
        raise Error, "#{path} is not a plain file" unless File.lstat(path).file?

        path
      end
    end

    # Where an application's sources are, relative to the root: OTP's own under otp/lib.
    def self.source_directory(application)
      return ErlangApps.source(application) if ErlangApps.own?(application)

      File.join('otp/lib', application)
    end

    # The version an application's .app file in ebin names.
    def self.app_version(ebin, application)
      text = File.read(File.join(ebin, "#{application}.app"))
      text[/\{vsn,\s*"([^"]+)"\}/, 1] or raise Error, "#{application}.app names no version"
    end

    # The ERTS version of the OTP build at otp.
    def self.erts_version(otp)
      File.read(File.join(otp, 'erts/vsn.mk'))[/^VSN\s*=\s*(\S+)/, 1] or raise Error, 'erts/vsn.mk names no version'
    end

    # OTP's own generator: systools:make_script, run by the stock emulator at `erl`,
    # writes start.script and start.boot into `directory` from `release`, a release
    # file's text, and the .app files of the applications it names, found in `paths` and
    # then on the stock emulator's own code path; the result is the boot script's path.
    # `layout: :build` writes each application's code path as $ROOT/lib/<name>/ebin, as
    # OTP's own build tree and bootstrap scripts lay applications out (systools' internal
    # otp_build flag); the default is a release's $ROOT/lib/<name>-<version>/ebin.
    # `dot_erlang: true` keeps the boot's read of .erlang, as stock's start_clean does.
    # systools takes `*` in a path as a wildcard, so a path holding one is refused. The
    # generator itself boots without reading the developer's .erlang.
    def self.make_boot_script(erl:, directory:, release:, paths:, runner:, layout: :release, dot_erlang: false)
      wild = paths.select { |path| path.include?('*') }
      raise Error, "systools would take * in #{wild.join(', ')} as a wildcard" unless wild.empty?

      File.write(File.join(directory, 'start.rel'), release)
      name = File.join(directory, 'start')
      flags = [*{ release: [], build: ['otp_build'] }.fetch(layout), *('no_dot_erlang' unless dot_erlang), 'no_warn_sasl']
      options = ["{path,[#{paths.map { |path| erlang_string(path) }.join(',')}]}", *flags]
      expression = "ok=systools:make_script(#{erlang_string(name)},[#{options.join(',')}]),halt()."
      runner.run([erl, '-boot', 'no_dot_erlang', '-noshell', '-noinput', '-eval', expression],
                 name: 'release-boot-script', deadline: BOOT_DEADLINE, chdir: directory, env: Oracle::CLEAN_ERLANG_ENV)
      "#{name}.boot"
    end

    # A text as an Erlang string literal, its backslashes and quotes escaped.
    def self.erlang_string(text) = "\"#{text.gsub(/[\\"]/) { |character| "\\#{character}" }}\""

    private

    # A header is its own source; a built file names the one it is compiled from.
    def application_files
      @release.applications.flat_map do |application|
        directory = "#{@release.prefix}lib/#{application}-#{version(application)}"
        self.class.application_layout(root: @root, otp: @otp, application: application).map do |path, artifact|
          sources = path.start_with?('include/') ? [artifact] : sources_of(application, File.basename(path))
          ReleaseFile.new(path: "#{directory}/#{path}", artifact: artifact, sources: sources)
        end
      end
    end

    # The source a built file is compiled from: for erXos's applications one of the
    # modules ErlangApps compiles, generated ones included. A file with none named is a
    # failure, so no file reaches the archive without its licence.
    def sources_of(application, name)
      source = File.join(@root, self.class.source_directory(application), 'src')
      base = File.basename(name, '.*')
      return [File.join(source, "#{base}.app.src")] if name.end_with?('.app')

      found = ErlangApps.own?(application) ? erxos_source(application, base) : otp_source(application, base)
      raise Error, "no source in #{self.class.source_directory(application)} for #{name}" unless found

      [found]
    end

    def erxos_source(application, base)
      module_path = ErlangApps.modules(root: @root, application: application).find { |path| File.basename(path, '.erl') == base }
      module_path && File.join(@root, module_path)
    end

    def otp_source(application, base)
      directory = File.join(@root, self.class.source_directory(application))
      %w[erl yrl xrl].map { |extension| File.join(directory, 'src', "#{base}.#{extension}") }.find { |path| File.file?(path) } ||
        Dir.glob(File.join(directory, '**', "#{base}.erl")).min
    end

    def version(application) = self.class.app_version(File.join(@otp, 'lib', application, 'ebin'), application)

    def erts_version = self.class.erts_version(@otp)

    # The release's boot scripts, bin/<name>.boot each: a script's release file names
    # its own applications, and the stock host build's systools writes the script from
    # it (ReleaseFiles.make_boot_script), each in a directory of its own. A domain
    # script's release is named after the script, so init:script_id() in a domain names
    # the script it booted; the system release's one script keeps the release's name.
    def boot_files
      @release.boots.map do |name, applications|
        directory = File.join(@directory, 'boot', name)
        FileUtils.mkdir_p(directory)
        boot = self.class.make_boot_script(
          erl: @oracle.erl_path(Runtime::HOST_OTP_FLAVOUR), directory: directory, runner: @runner,
          paths: applications.map { |application| File.join(@otp, 'lib', application, 'ebin') },
          release: "{release,{\"#{@release.system ? @release.name : name}\",\"1\"},{erts,\"#{erts_version}\"}," \
                   "[#{applications.map { |application| release_entry(application) }.join(',')}]}.\n"
        )
        sources = applications.map { |application| File.join(@root, self.class.source_directory(application), 'src', "#{application}.app.src") }
        ReleaseFile.new(path: "#{@release.prefix}bin/#{name}.boot", artifact: boot, sources: sources)
      end
    end

    # An application's term in the release file: its name and version, and the start
    # type load for one only loaded, DOMAIN_ONLY's among them in every release,
    # and temporary for TEMPORARY's; the others take systools' default, permanent.
    def release_entry(application)
      term = "#{application},\"#{version(application)}\""
      if LOAD_ONLY.include?(application) || DOMAIN_ONLY.include?(application)
        "{#{term},load}"
      elsif TEMPORARY.include?(application) then "{#{term},temporary}"
      else "{#{term}}"
      end
    end

    def file_entry(file)
      receipt = File.join(@directory, 'receipts', "#{file.path.tr('/', '_')}.json")
      FileUtils.mkdir_p(File.dirname(receipt))
      File.write(receipt, JSON.pretty_generate('version' => 1, 'kind' => 'compiled', 'artifact' => reference(file.artifact),
                                               'sources' => file.sources.map { |source| reference(source) }))
      { 'path' => file.path, 'kind' => @codec.member('entry_kind', 'file'), 'flags' => @release.system ? @codec.member('entry_flags', 'system') : 0,
        'id' => file.path, 'artifact' => file.artifact, 'receipt' => receipt }
    end

    def reference(path)
      { 'path' => path.delete_prefix("#{@root}/"), 'sha256' => Digest::SHA256.file(path).hexdigest }
    end
  end
end
