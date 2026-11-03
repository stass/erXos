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

  module PackFuzz
    module_function

    def run(root:, runner:, compiler: 'clang', runs: 20_000)
      unless runs.is_a?(Integer) && runs.between?(1, 10_000_000)
        raise Error, 'invalid pack fuzz run bound'
      end
      FuzzWorkspace.run(root: root, name: 'pack', maximum_input: 32_768) do |directory, artifacts|
        %w[pack elf].map do |kind|
          corpus = File.join(directory, "#{kind}-corpus")
          Dir.mkdir(corpus, 0o700)
          bytes = kind == 'pack' ? PackFixture.valid : ElfFixture.valid
          File.binwrite(File.join(corpus, 'valid'), bytes)
          # Every prefix of a valid wire header reaches a different truncation
          # boundary; mutations then start from both accepted and rejected seeds.
          [0, 1, 7, 31, 55, 63, 127, 511, 4095].each do |length|
            File.binwrite(File.join(corpus, "prefix-#{length}"), bytes.byteslice(0, length))
          end
          program = File.join(directory, "#{kind}-fuzz")
          source = kind == 'pack' ? 'kernel/core/pack.c' : 'liberx/elf_plan.c'
          runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                      '-fsanitize=fuzzer,address,undefined', '-fno-omit-frame-pointer',
                      '-I', File.join(root, 'include'), File.join(root, source),
                      File.join(root, 'liberx/generated/abi_reader.c'),
                      File.join(root, "tools/fuzz/#{kind}_fuzz.c"), '-o', program],
                     name: "compile-#{kind}-fuzz", deadline: 90)
          runner.run([program, "-runs=#{runs}", '-max_len=32768', '-timeout=5',
                      "-artifact_prefix=#{artifacts}/", corpus],
                     name: "#{kind}-fuzz", deadline: 120)
        end
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs/pack-fuzz'))
  Erx::PackFuzz.run(root: root, runner: runner,
                   compiler: ENV.fetch('CC', 'clang'), runs: Integer(ENV.fetch('RUNS', '20000'), 10))
end
