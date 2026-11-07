# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require_relative '../lib/erx/declaration_files'
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

  # The native fuzz targets: kernel cores and liberx parsers, fed what a
  # domain, a device or the host link controls. Each is two files in this
  # directory, its libFuzzer entry KIND_fuzz.c and its declaration
  # KIND_target.rb (sources, include paths, seeds), which this module
  # discovers in sorted order. A new target needs no entry here, and an entry
  # without its declaration, a declaration without its entry, or a malformed
  # declaration stops the run instead of shrinking it.
  module PackFuzz
    module_function

    # The include paths of a target that declares none of its own.
    INCLUDES = %w[include kernel/core build/gen/kernel/generated kernel/crypto].freeze
    # Each kind's compile and run deadlines, in seconds.
    COMPILE_DEADLINE = 90
    RUN_DEADLINE = 120
    # A seed's name becomes a file name in the target's corpus.
    SEED_NAME = /\A[a-z0-9-]+\z/
    Target = Data.define(:kind, :sources, :includes, :seeds)
    TARGET_FILES = DeclarationFiles.new('native fuzz targets')
    private_constant :TARGET_FILES

    # Each tools/fuzz/KIND_target.rb calls this exactly once. seeds maps a
    # name to the bytes of one corpus file.
    def declare_target(sources:, seeds:, includes: INCLUDES)
      unless relative_paths?(sources) && relative_paths?(includes)
        raise Error, 'native fuzz targets: sources and includes are non-empty lists of relative paths'
      end
      unless seeds.is_a?(Hash) && !seeds.empty? &&
             seeds.all? { |name, bytes| name.is_a?(String) && SEED_NAME.match?(name) && bytes.is_a?(String) }
        raise Error, 'native fuzz targets: seeds are a non-empty map of plain names to bytes'
      end

      TARGET_FILES.declare({ sources: sources, includes: includes, seeds: seeds })
    end

    # The targets declared in directory, sorted by kind. Public so the tests
    # can feed it malformed directories.
    def load_targets(directory)
      declared = TARGET_FILES.load_all(directory, suffix: '_target.rb')
      entries = Dir.glob('*_fuzz.c', base: directory).map { |file| file.delete_suffix('_fuzz.c') }
      unmatched = (entries - declared.keys) | (declared.keys - entries)
      unless unmatched.empty?
        raise Error, "native fuzz targets: #{unmatched.join(', ')} needs both KIND_fuzz.c and KIND_target.rb"
      end

      declared.map { |kind, declaration| Target.new(kind: kind, **declaration) }.freeze
    end

    def targets = (@targets ||= load_targets(__dir__))

    # The command that builds target's fuzz program into program, public so a
    # target's own test builds it as the gate does. Every program links the
    # generated ABI reader, so the generated tree's directories (build/gen,
    # then build/gen/include) and include come with it whatever paths the
    # target declares, the generated ones first.
    def compile_command(target, root:, compiler:, program:)
      [compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
       '-fsanitize=fuzzer,address,undefined', '-fno-omit-frame-pointer',
       *['build/gen', 'build/gen/include', *target.includes, 'include'].uniq.flat_map { |path| ['-I', File.join(root, path)] },
       *[*target.sources, 'build/gen/liberx/generated/abi_reader.c'].uniq.map { |source| File.join(root, source) },
       File.join(root, "tools/fuzz/#{target.kind}_fuzz.c"), '-o', program]
    end

    # The whole run's deadline, which allows every kind both in full.
    def deadline = targets.size * (COMPILE_DEADLINE + RUN_DEADLINE)

    def run(root:, runner:, compiler: 'clang', runs: 20_000)
      unless runs.is_a?(Integer) && runs.between?(1, 10_000_000)
        raise Error, 'invalid pack fuzz run bound'
      end
      FuzzWorkspace.run(root: root, name: 'pack', maximum_input: 32_768) do |directory, artifacts|
        targets.map do |target|
          kind = target.kind
          corpus = File.join(directory, "#{kind}-corpus")
          Dir.mkdir(corpus, 0o700)
          target.seeds.each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
          program = File.join(directory, "#{kind}-fuzz")
          runner.run(compile_command(target, root: root, compiler: compiler, program: program),
                     name: "compile-#{kind}-fuzz", deadline: COMPILE_DEADLINE)
          runner.run([program, "-runs=#{runs}", '-max_len=32768', '-timeout=5',
                      "-artifact_prefix=#{artifacts}/", corpus],
                     name: "#{kind}-fuzz", deadline: RUN_DEADLINE)
        end
      end
    end

    # The whole of a valid wire format and every prefix of its header: each
    # prefix reaches a different truncation boundary, so mutations start from
    # both accepted and rejected seeds.
    def prefix_seeds(bytes)
      prefixes = [0, 1, 7, 31, 55, 63, 127, 511, 4095].to_h do |length|
        ["prefix-#{length}", bytes.byteslice(0, length)]
      end
      { 'valid' => bytes }.merge(prefixes)
    end

    # Values named by their position.
    def indexed_seeds(values) = values.each_with_index.to_h { |value, index| ["seed-#{index}", value.b] }

    def relative_paths?(paths)
      paths.is_a?(Array) && !paths.empty? && paths.all? do |path|
        path.is_a?(String) && !path.empty? && !path.start_with?('/') && !path.split('/').include?('..')
      end
    end
    private_class_method :relative_paths?
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs/pack-fuzz'))
  Erx::PackFuzz.run(root: root, runner: runner,
                   compiler: ENV.fetch('CC', 'clang'), runs: Integer(ENV.fetch('RUNS', '20000'), 10))
end
