# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require_relative 'dependencies'
require_relative 'runner'
require_relative 'sources'
require_relative 'json_input'
require_relative 'bounded_file'

module Erx
  # Each flavour owns a writable copy of stock OTP. Target imports never
  # participate in oracle builds, and no build step fetches its own sources.
  class Oracle
    FLAVOURS = %w[emu jit].freeze
    SUITES = %w[emulator kernel stdlib compiler].freeze
    OPTIONAL_APPS = %w[--without-wx --without-javac --without-odbc].freeze
    CLEAN_ERLANG_ENV = {
      'ERL_FLAGS' => nil, 'ERL_AFLAGS' => nil, 'ERL_ZFLAGS' => nil,
      'ERL_LIBS' => nil, 'ERL_COMPILER_OPTIONS' => nil,
      'ERL_TOP' => nil, 'ERL_ROOTDIR' => nil, 'MAKEFLAGS' => nil, 'CONFIG_SITE' => nil,
      'ERL_EPMD_ADDRESS' => nil, 'ERL_EPMD_PORT' => nil,
      'ERL_EPMD_RELAXED_COMMAND_CHECK' => nil,
      'CC' => nil, 'CXX' => nil, 'CPP' => nil, 'CXXCPP' => nil,
      'AR' => nil, 'RANLIB' => nil, 'LD' => nil,
      'CFLAGS' => nil, 'CXXFLAGS' => nil, 'CPPFLAGS' => nil, 'LDFLAGS' => nil
    }.freeze

    def initialize(root:, runner: nil, json: JsonInput)
      @json = json
      @root = File.realpath(root)
      @runner = runner || Runner.new(owner_root: @root, log_dir: File.join(@root, 'build/logs'))
      @build = File.join(@root, 'build/oracle')
      @dependencies = Dependencies.new(root: @root, runner: @runner)
    end

    def build(flavours: FLAVOURS, jobs: 4, clean: false)
      validate_jobs(jobs)
      flavours.each { |flavour| build_flavour(flavour, jobs: jobs, clean: clean) }
    end

    def source_path(flavour)
      validate_flavour(flavour)
      OutputDirectory.check(root: @root, path: File.join(@build, flavour, 'source'))
    end

    def erl_path(flavour)
      validate_flavour(flavour)
      parent = OutputDirectory.check(root: @root, path: File.join(@build, flavour, 'install/bin'))
      File.join(parent, 'erl')
    end

    def verify(flavour)
      validate_flavour(flavour)
      OutputDirectory.check(root: @root, path: File.join(@build, flavour))
      receipt = File.join(@build, flavour, 'build.json')
      unless File.file?(receipt) && !File.symlink?(receipt)
        raise Error, "oracle #{flavour} has no completed build receipt"
      end
      report = @json.parse(BoundedFile.read(receipt, maximum: 1024 * 1024), label: 'native oracle build receipt')
      expected_source = @dependencies.sources.find { |source| source.fetch('id') == 'otp' }
      unless report.is_a?(Hash) && report['state'] == 'ready' &&
             report['version'] == '29.1.2' && report['flavour'] == flavour &&
             report['source_sha256'] == expected_source.fetch('sha256')
        raise Error, "oracle #{flavour} build receipt does not identify the stock oracle"
      end
      verify_installation(flavour)
    end

    def run(suite, flavour: 'emu', deadline: 14_400, test_suite: nil, testcase: nil, jobs: 4)
      raise Error, 'full oracle suites require the isolated Linux container backend'
    end

    def with_runtime(flavour)
      validate_flavour(flavour)
      directory = OutputDirectory.check(root: @root, path: File.join(@build, flavour))
      raise Error, "oracle #{flavour} is not built" unless File.directory?(directory) && !File.symlink?(directory)
      File.open(File.join(directory, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        raise Error, "oracle #{flavour} is already in use" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        verify(flavour)
        yield({ 'erl' => erl_path(flavour), 'erlc' => File.join(directory, 'install/bin/erlc'),
                'build' => @json.parse(BoundedFile.read(File.join(directory, 'build.json'), maximum: 1024 * 1024), label: 'native oracle build receipt') })
      end
    end

    private

    def verify_installation(flavour)
      executable = erl_path(flavour)
      raise Error, "oracle #{flavour} is not built; run tools/erx oracle build" unless File.executable?(executable)

      expression = 'Root = code:root_dir(), ' \
                   'Release = erlang:system_info(otp_release), ' \
                   '{ok, Version} = file:read_file(filename:join([Root,"releases",Release,"OTP_VERSION"])), ' \
                   'io:format("ERX_ORACLE ~s ~s~n", [string:trim(Version), erlang:system_info(emu_flavor)]), halt().'
      # Installation names the selected primary emulator beam.smp. Its
      # runtime-reported flavour, rather than its installed filename, decides.
      result = @runner.run([executable, '-noshell', '-noinput', '-boot', 'no_dot_erlang',
                            '-eval', expression], name: "oracle-verify-#{flavour}",
                           deadline: 30, env: CLEAN_ERLANG_ENV)
      expected = "ERX_ORACLE 29.1.2 #{flavour}\n"
      unless BoundedFile.read(result.fetch('log'), maximum: 1024 * 1024).lines.include?(expected)
        raise Error, "oracle version or execution flavour mismatch; log: #{result.fetch('log')}"
      end
      result
    end

    def validate_flavour(flavour)
      raise Error, "unsupported oracle flavour: #{flavour}" unless FLAVOURS.include?(flavour)
    end

    def validate_jobs(jobs)
      unless jobs.is_a?(Integer) && jobs.between?(1, 64)
        raise Error, 'oracle jobs must be between 1 and 64'
      end
    end

    def build_flavour(flavour, jobs:, clean:)
      validate_flavour(flavour)
      directory = OutputDirectory.prepare(root: @root, path: File.join(@build, flavour))
      File.open(File.join(directory, '.lock'), File::RDWR | File::CREAT, 0o600) do |lock|
        raise Error, "oracle #{flavour} is already in use" unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        build_locked(flavour, jobs: jobs, clean: clean)
      end
    end

    def build_locked(flavour, jobs:, clean:)
      source, archive = @dependencies.archive_for('otp')
      directory = File.join(@build, flavour)
      prepare_build_directory(directory, clean: clean)
      plan = build_plan(flavour, source: source)
      prepare_source(flavour, source: source, archive: archive, plan: plan)
      environment = CLEAN_ERLANG_ENV.merge(plan.fetch('build_environment'))
      configure = [File.join(source_path(flavour), 'configure'), *plan.fetch('configure')]
      @runner.run(configure, name: "oracle-configure-#{flavour}", deadline: 300,
                  chdir: source_path(flavour), env: environment)
      compilation = @runner.run([plan.fetch('make').fetch('path'), "-j#{jobs}",
                                 "FLAVOR=#{flavour}", 'V=1'],
                                name: "oracle-build-#{flavour}", deadline: 1800,
                                chdir: source_path(flavour), env: environment)
      @runner.run([plan.fetch('make').fetch('path'), 'install', "FLAVOR=#{flavour}"],
                  name: "oracle-install-#{flavour}", deadline: 300,
                  chdir: source_path(flavour), env: environment)
      verification = verify_installation(flavour)
      report = plan.merge('state' => 'ready', 'verification' => verification,
                          'compilation' => compilation)
      File.write(File.join(directory, 'build.json'), JSON.pretty_generate(report) + "\n")
    end

    def build_plan(flavour, source:)
      configure = ["--prefix=#{File.join(@build, flavour, 'install')}",
                   flavour == 'jit' ? '--enable-jit' : '--disable-jit', *OPTIONAL_APPS]
      compiler = tool_identity('clang')
      cxx = tool_identity('clang++')
      make = tool_identity('gmake')
      environment = { 'CC' => compiler.fetch('path'), 'CXX' => cxx.fetch('path'),
                      'MAKE' => make.fetch('path'), 'CFLAGS' => '-O2',
                      'CXXFLAGS' => '-O2', 'CPPFLAGS' => '', 'LDFLAGS' => '' }
      { 'version' => source.fetch('version'), 'source_sha256' => source.fetch('sha256'),
        'flavour' => flavour, 'configure' => configure,
        'compiler' => compiler, 'cxx' => cxx, 'make' => make,
        'build_environment' => environment,
        'host' => tool_identity('uname', arguments: ['-a']) }
    end

    def tool_identity(program, arguments: ['--version'])
      path = ENV.fetch('PATH').split(File::PATH_SEPARATOR)
                .map { |directory| File.join(directory, program) }
                .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      raise Error, "missing oracle tool: #{program}" unless path
      path = File.realpath(path)
      result = @runner.run([path, *arguments], name: "oracle-tool-#{program.tr('+', 'x')}", deadline: 10)
      { 'path' => path, 'identity' => BoundedFile.read(result.fetch('log'), maximum: 1024 * 1024).lines.first.to_s.strip }
    end

    def prepare_build_directory(directory, clean:)
      contents = Dir.children(directory).reject { |name| name == '.lock' }
      if !clean && !contents.empty?
        raise Error, "oracle build exists; use --clean to re-create #{directory} from stock sources"
      end
      contents.each { |name| FileUtils.remove_entry(File.join(directory, name)) } if clean
    end

    def prepare_source(flavour, source:, archive:, plan:)
      directory = File.join(@build, flavour)
      marker = File.join(directory, 'source.json')
      if File.exist?(marker) || File.symlink?(marker) ||
         File.exist?(source_path(flavour)) || File.symlink?(source_path(flavour))
        raise Error, "oracle source has no build identity: #{source_path(flavour)}"
      end

      Dir.mktmpdir('.oracle-source-', directory) do |temporary|
        extracted = File.join(temporary, 'unpacked')
        Sources.unpack(archive: archive, sha256: source.fetch('sha256'),
                       destination: extracted, owner_root: temporary,
                       source_directory: source.fetch('directory'), runner: @runner)
        File.rename(extracted, source_path(flavour))
      end
      File.write(marker, JSON.pretty_generate(plan) + "\n")
    end
  end
end
