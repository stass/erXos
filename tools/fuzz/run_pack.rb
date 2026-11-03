# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative '../../test/fixtures/pack_fixture'
require_relative '../../test/fixtures/elf_fixture'
require_relative '../lib/erx/runner'
require_relative '../lib/erx/output_directory'

module Erx
  # Each native fuzz run owns fresh work and artifact directories. Only small
  # regular crash inputs survive a failure; command logs live with the runner.
  module FuzzWorkspace
    module_function

    def run(root:, name:, maximum_input:)
      unless %w[abi pack].include?(name) && [32_768, 65_536].include?(maximum_input)
        raise Error, 'invalid native fuzz workspace'
      end
      parent = OutputDirectory.prepare(root: root, path: File.join(root, 'build/fuzz', name))
      directory = Dir.mktmpdir('run-', parent)
      work = File.join(directory, 'work')
      artifacts = File.join(directory, 'artifacts')
      completed = false
      begin
        Dir.mkdir(work, 0o700)
        Dir.mkdir(artifacts, 0o700)
        result = yield(work, artifacts)
        completed = true
        result
      ensure
        original_error = $!
        begin
          if completed
            FileUtils.remove_entry(directory)
          else
            FileUtils.remove_entry(work) if File.exist?(work) || File.symlink?(work)
            kept, discarded = retain_crashes(artifacts, maximum_input: maximum_input)
            Terminal.puts("native fuzz failure: #{kept} crash inputs retained in #{artifacts}, " \
                          "#{discarded} artifacts discarded; command logs retained")
          end
        rescue SystemCallError, IOError, Error => cleanup_error
          raise Error, "native fuzz cleanup failed: #{cleanup_error.message}" unless original_error
          Terminal.puts("native fuzz cleanup failed: #{cleanup_error.message}")
        end
      end
    end

    def retain_crashes(directory, maximum_input:)
      unless File.lstat(directory).directory?
        FileUtils.remove_entry(directory)
        Dir.mkdir(directory, 0o700)
      end
      kept = 0
      discarded = 0
      Dir.each_child(directory) do |name|
        path = File.join(directory, name)
        stat = File.lstat(path)
        if stat.file? && stat.nlink == 1 && stat.size <= maximum_input && kept < 8
          kept += 1
        else
          FileUtils.remove_entry(path)
          discarded += 1
        end
      end
      [kept, discarded]
    end
    private_class_method :retain_crashes
  end

  # The native boot-path parsers, each built from its own source with its
  # libFuzzer entry in tools/fuzz/KIND_fuzz.c: the ERXPACK boot image, ELF
  # executable headers and the erx.watchdog= boot argument; and the
  # capability core over the values, masks and counts a domain controls.
  module PackFuzz
    module_function

    SOURCES = { 'pack' => 'kernel/core/pack.c', 'elf' => 'liberx/elf_plan.c',
                'watchdog' => 'kernel/core/watchdog.c', 'cap' => 'kernel/core/cap.c' }.freeze
    # Accepted values at the bounds and one of each refusal, so mutations
    # start on both sides of every check.
    WATCHDOG_SEEDS = %w[1,5,60 60,120,600 1,2,2 0,5,60 1,1,60 1,5,4 1,5 1,5,60,
                        4294967296,5,60 1,,60 off].freeze
    # Installs, then a lookup, a clear, a reservation and a pass of
    # what was installed, so mutations start inside the tables.
    CAP_SEEDS = ["\x00\x00\x07\xff\xff\xff\xff\x01\x00",
                 "\x00\x00\x07\xff\xff\xff\xff\x01\x00\x00\x02\x01\x00\x00\x00\x00\x00\x00",
                 "\x00\x00\x0b\xff\xff\xff\xff\x05\x00\x01\x03\x02\x00\x05\x00\x01\x01\x01\x01\x02\xff\xff\xff\xff\x00\x00",
                 "\x00\x00\x06\xff\xff\xff\xff\x09\x00\x00\x01\x01\x01\x00\x07"].freeze

    def run(root:, runner:, compiler: 'clang', runs: 20_000)
      unless runs.is_a?(Integer) && runs.between?(1, 10_000_000)
        raise Error, 'invalid pack fuzz run bound'
      end
      FuzzWorkspace.run(root: root, name: 'pack', maximum_input: 32_768) do |directory, artifacts|
        SOURCES.map do |kind, source|
          corpus = File.join(directory, "#{kind}-corpus")
          Dir.mkdir(corpus, 0o700)
          seeds(kind).each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
          program = File.join(directory, "#{kind}-fuzz")
          runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                      '-fsanitize=fuzzer,address,undefined', '-fno-omit-frame-pointer',
                      '-I', File.join(root, 'include'), '-I', File.join(root, 'kernel/core'),
                      '-I', File.join(root, 'kernel/generated'),
                      File.join(root, source),
                      File.join(root, 'liberx/generated/abi_reader.c'),
                      File.join(root, "tools/fuzz/#{kind}_fuzz.c"), '-o', program],
                     name: "compile-#{kind}-fuzz", deadline: 90)
          runner.run([program, "-runs=#{runs}", '-max_len=32768', '-timeout=5',
                      "-artifact_prefix=#{artifacts}/", corpus],
                     name: "#{kind}-fuzz", deadline: 120)
        end
      end
    end

    def seeds(kind)
      return WATCHDOG_SEEDS.each_with_index.to_h { |value, index| ["seed-#{index}", value] } if kind == 'watchdog'
      return CAP_SEEDS.each_with_index.to_h { |value, index| ["seed-#{index}", value.b] } if kind == 'cap'

      bytes = kind == 'pack' ? PackFixture.valid : ElfFixture.valid
      # Every prefix of a valid wire header reaches a different truncation
      # boundary; mutations then start from both accepted and rejected seeds.
      prefixes = [0, 1, 7, 31, 55, 63, 127, 511, 4095].to_h do |length|
        ["prefix-#{length}", bytes.byteslice(0, length)]
      end
      { 'valid' => bytes }.merge(prefixes)
    end
    private_class_method :seeds
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs/pack-fuzz'))
  Erx::PackFuzz.run(root: root, runner: runner,
                   compiler: ENV.fetch('CC', 'clang'), runs: Integer(ENV.fetch('RUNS', '20000'), 10))
end
