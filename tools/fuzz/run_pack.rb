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

  # The native kernel cores, each built from its own sources with its
  # libFuzzer entry in tools/fuzz/KIND_fuzz.c: the boot-path parsers of the
  # ERXPACK boot image, ELF executable headers and the erx.watchdog= boot
  # argument; the capability core, fed the values, masks and counts a
  # domain controls; SHA-256, ChaCha20 and the entropy generator built on
  # them; and BLAKE3.
  module PackFuzz
    module_function

    SHA256 = 'kernel/crypto/sha2/sha256c.c'
    CHACHA20 = 'kernel/crypto/chacha20/chacha.c'
    SOURCES = { 'pack' => ['kernel/core/pack.c'], 'elf' => ['liberx/elf_plan.c'],
                'watchdog' => ['kernel/core/watchdog.c'], 'cap' => ['kernel/core/cap.c'],
                'sha256' => [SHA256], 'chacha20' => [CHACHA20],
                'rng' => ['kernel/core/rng.c', CHACHA20, SHA256],
                'blake3' => ['kernel/crypto/blake3/blake3.c', 'kernel/crypto/blake3/blake3_portable.c'] }.freeze
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
    # A key, a nonce and a little-endian counter, then data: from counter 0
    # and from the counter's last block, with data across block boundaries.
    CHACHA20_HEADERS = { 'start' => ("\x01" * 44 + "\x00\x00\x00\x00").b,
                         'last' => ("\x02" * 44 + "\xff\xff\xff\xff").b }.freeze
    # Generator programs (op 0 read, 1 mix, 2 clear, 3 init): reads before
    # any init, at and past the bound, mixes, and a clear with what follows.
    RNG_SEEDS = { 'unseeded' => "\x00\x20\x00\x01\x01z", 'read-bound' => "\x03\x01s\x00\x00\x01",
                  'read-past' => "\x03\x01s\x00\x01\x01", 'read-empty' => "\x03\x00\x00\x00\x00",
                  'mix' => "\x03\x00\x01\x05abcde\x00\x20\x00",
                  'reset' => "\x03\x01x\x02\x00\x08\x00\x01\x01y\x03\x00\x00\x08\x00" }.freeze

    def run(root:, runner:, compiler: 'clang', runs: 20_000)
      unless runs.is_a?(Integer) && runs.between?(1, 10_000_000)
        raise Error, 'invalid pack fuzz run bound'
      end
      FuzzWorkspace.run(root: root, name: 'pack', maximum_input: 32_768) do |directory, artifacts|
        SOURCES.map do |kind, sources|
          corpus = File.join(directory, "#{kind}-corpus")
          Dir.mkdir(corpus, 0o700)
          seeds(kind).each { |name, bytes| File.binwrite(File.join(corpus, name), bytes) }
          program = File.join(directory, "#{kind}-fuzz")
          runner.run([compiler, '-std=c17', '-Wall', '-Wextra', '-Werror', '-pedantic', '-O1', '-g',
                      '-fsanitize=fuzzer,address,undefined', '-fno-omit-frame-pointer',
                      '-I', File.join(root, 'include'), '-I', File.join(root, 'kernel/core'),
                      '-I', File.join(root, 'kernel/generated'), '-I', File.join(root, 'kernel/crypto'),
                      *sources.map { |source| File.join(root, source) },
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
      return primitive_seeds(kind) if %w[sha256 chacha20 rng].include?(kind)
      return blake3_seeds if kind == 'blake3'

      bytes = case kind
              when 'pack' then PackFixture.valid
              when 'elf' then ElfFixture.valid
              else raise Error, "no seeds for fuzz kind #{kind}"
              end
      # Every prefix of a valid wire header reaches a different truncation
      # boundary; mutations then start from both accepted and rejected seeds.
      prefixes = [0, 1, 7, 31, 55, 63, 127, 511, 4095].to_h do |length|
        ["prefix-#{length}", bytes.byteslice(0, length)]
      end
      { 'valid' => bytes }.merge(prefixes)
    end
    private_class_method :seeds

    # Messages across block and padding boundaries for SHA-256, streams
    # across block boundaries for ChaCha20, and generator programs.
    def primitive_seeds(kind)
      lengths = [0, 1, 55, 56, 63, 64, 65, 200]
      case kind
      when 'sha256'
        lengths.to_h { |length| ["length-#{length}", ([length % 7].pack('C') + 'a' * length).b] }
      when 'chacha20'
        CHACHA20_HEADERS.flat_map do |name, header|
          lengths.map { |length| ["#{name}-#{length}", header + ("\x5a" * length).b] }
        end.to_h
      else
        RNG_SEEDS.transform_values(&:b)
      end
    end
    private_class_method :primitive_seeds

    # A cut seed byte, then messages ending at and around the block and
    # chunk boundaries, up to a little over four chunks.
    def blake3_seeds
      [0, 1, 63, 64, 65, 1023, 1024, 1025, 2048, 4097].to_h do |length|
        ["length-#{length}", ([length % 251].pack('C') + Array.new(length) { |index| index % 251 }.pack('C*')).b]
      end
    end
    private_class_method :blake3_seeds
  end
end

if $PROGRAM_NAME == __FILE__
  root = File.expand_path('../..', __dir__)
  runner = Erx::Runner.new(owner_root: root, log_dir: File.join(root, 'build/logs/pack-fuzz'))
  Erx::PackFuzz.run(root: root, runner: runner,
                   compiler: ENV.fetch('CC', 'clang'), runs: Integer(ENV.fetch('RUNS', '20000'), 10))
end
